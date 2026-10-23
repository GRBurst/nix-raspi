# CI builds, the Pi pulls (replaces host auto-update) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan milestone by milestone. Steps use checkbox (`- [ ]`) syntax for tracking. Every task starts at status `[ ]` (todo).

**Goal:** Weekly security updates reach the Pi 3B "neptun" without the host (andromeda) and without the Pi evaluating the flake: GitHub Actions (arm64) builds the `rpi` toplevel, pushes it to our self-signed Cachix cache and commits a pointer; a Pi timer (`rpi-pull`) verifies and activates it. The host auto-update is removed; manual `rpi-deploy` keeps working.

**Architecture:** CI shell steps are repo scripts (`nixos/ci/*.sh`) that reuse `rpi-lib.sh` (`rl_guard`). The boot-fingerprint code moves from `rpi-lib.sh` into a pure-bash `rpi-fp.sh`, sourced by `rpi-lib.sh` on the host and shipped alone with `rpi-pull.sh` on the Pi. The NixOS module `modules/pull-update.nix` packages `rpi-pull` and runs it as a oneshot timer job. Test plumbing (unit checks, shellcheck) becomes auto-discovered so parallel milestones do not edit `flake.nix`.

**Tech stack:** Nix 2.34 flakes, NixOS 26.05 modules, bash + shellcheck, jq, curl, Cachix (`cachix push`/`pin`), GitHub Actions (`ubuntu-24.04-arm`, `cachix/install-nix-action@v31`, `cachix/cachix-action@v17`), actionlint 1.7.12, qemu `raspi3b`.

**Spec:** `docs/superpowers/specs/2026-10-23-ci-pull-updates-design.md` (the addendum, read fully), which amends `docs/superpowers/specs/2026-10-19-image-push-deploy-design.md` §3.3, §3.4, §5, §8, §10. Evidence: `nixos/.scratch/s7/REPORT.md`, `nixos/.scratch/s8/REPORT.md`. Previous plan (structure, shared interfaces): `docs/superpowers/plans/2026-10-19-image-push-deploy.md`.

---

## 0. Ground rules and environment gotchas (every implementer)

```bash
cd /home/pallon/projects/raspberry-pi/nixos
export XDG_CACHE_HOME=$PWD/.cache-nix NIXPKGS_CONFIG=$PWD/.nixcache/nixpkgs-config.nix
export GIT_CONFIG_GLOBAL=/dev/null XDG_CONFIG_HOME=/tmp/nogit   # ~/.config/git/ignore is unreadable here
chk()  { nix build --accept-flake-config --no-link -L ".#checks.x86_64-linux.$1"; }   # one check
ev()   { nix eval  --accept-flake-config "$@"; }
unit() { bash "tests/$1.sh"; }                                   # fast loop, outside nix
R=.#nixosConfigurations.rpi.config
commit() { git -c core.excludesFile=/dev/null commit --no-gpg-sign "$@"; }
mkdir -p .scratch/ci   # scratch output (gitignored); /tmp is not writable for some paths
```

- **Commits.** Always `git -c core.excludesFile=/dev/null commit --no-gpg-sign …` (signing is unavailable; the user re-signs when merging). One task = one commit.
- **Linear history, no merge commits.**
  - Sequential milestones (M1, M2, M6, M8, M9) commit directly on `feat/image-push-deploy`.
  - Parallel milestones (M3, M4, M5, M7) each work in a worktree on their own branch: `git worktree add ../.worktrees/ci-mN -b ci/mN feat/image-push-deploy` (run from `nixos/`; the repo's `.worktrees/` dir).
  - The orchestrator integrates each finished branch: in the worktree `git rebase feat/image-push-deploy`, then in the main tree `git merge --ff-only ci/mN` (or `git cherry-pick` the commits). Never `git merge` without `--ff-only`.
- **Unit tests** need `GIT_CONFIG_GLOBAL=/dev/null XDG_CONFIG_HOME=/tmp/nogit` (exported above); the harness also sets them.
- **`nix flake check --no-build`** needs a prior `ev --raw $R.system.build.toplevel.drvPath` (yazi IFD in home-manager), otherwise it fails on the IFD.
- **New files are invisible to the flake until staged** (`git add` or `git add -N` right after creating them). A check that "passes" on a missing file proves nothing.
- **qemu SD ext4 corruption** (`PIO read timeout` / `EXT4-fs error` in the guest serial log) is a known flake under host I/O load: re-run the smoke test once on an idle host before debugging.
- `ssh` to the guest: always `-F /dev/null` (host ssh_config is unreadable in the sandbox). Never ssh to the real Pi (192.168.100.20).
- **Cost classes.** `[cheap]` ≤ 2 min (eval, eval checks, bash unit tests). `[expensive]` = aarch64 build, VM test or qemu run, duration stated. Never in a RED/GREEN loop; run once at the stated point.
- **One failing check at a time.** Every RED names the single check and the text it must print.
- **Planted violations (§11):** tick a box only after the red was seen.

## 1. Motivation

The Pi 3B cannot evaluate its flake (1.10 GB RSS, ~700 MB live heap vs ~869 MiB usable, s7), so updates must arrive as prebuilt closures. Today the host's weekly timer (`rpi-autoupdate`) pushes them, which requires andromeda to be on. The addendum moves the build to GitHub Actions on a free arm64 runner, publishes the closure to our own self-signed Cachix cache, and lets the Pi pull it: fetch a pointer from git over HTTPS, verify it (our signing key only, system name, monotonic `seq`, narHash), realise with 2 substitution jobs (76 MB RSS, s8), then switch or boot+reboot by the same boot fingerprint the host uses. Manual push deploys stay.

## 2. Approach (shape of the diff)

- **Removed:** `rpi.buildHost.autoUpdate` (options, timer, service), `rpi-autoupdate.sh`, `tests/autoupdate-unit.sh`, the `autoupdate-unit` check, the VM test's auto-update lines, `keys.autoUpdate`/`hostAddress` and the `from=…,restrict` root key.
- **Changed:**
  - `rpi-deploy deploy` downgrade check compares against `refs/remotes/origin/main` instead of branch `auto-update`; `rpi-deploy status` prints the pull state.
  - `modules/sd-image.nix` drops the `sd-card` tag → toplevel `nixos-system-neptun-<version>`.
  - `flake.nix`: shellcheck auto-discovers `*.sh` outside `tests/`; unit checks auto-discover `tests/<n>-unit.sh` → `checks.x86_64-linux.rpi-<n>-unit`; new `actionlint` check; `rpi` imports `modules/pull-update.nix`.
- **New:**
  - `nixos/rpi-fp.sh` (extracted from `rpi-lib.sh`: `RL_FP_SCRIPT`, `rl_fp_local`, `rl_needs_reboot`, `rl_fp_changed`).
  - `nixos/rpi-pull.sh` + `tests/pull-unit.sh`.
  - `nixos/modules/pull-update.nix` (`rpi.pull.*`, package, timer, service, substituter/key) + `tests/eval/pull-update.nix`; `keys.nix` gets `cache = null` (user fills it).
  - `nixos/ci/{cache-name,build,publish,pointer,commit-push}.sh` + `tests/ci-unit.sh`; `.github/workflows/neptun.yml`.
  - `tests/pull-smoke.sh` (qemu, local signed cache over HTTP).
  - README/HANDOFF rewritten for the new flow.

## 3. Decisions

| # | Decision | Rationale | Rejected alternative (why) |
|---|---|---|---|
| D1 | Fingerprint code moves to `nixos/rpi-fp.sh` (pure bash + readlink; no nix/ssh/git). `rpi-lib.sh` sources it from its own directory (`RL_FP_LIB`); `rl_fp_remote` stays in `rpi-lib.sh`. The Pi package ships `rpi-pull` + `rpi-fp.sh` only. | One implementation of the fingerprint on both sides; the Pi never carries host-only code (guards, ssh, nixos-rebuild). | Pi sources all of `rpi-lib.sh` (host code on the Pi); a copy in `rpi-pull.sh` (two fingerprints drift → wrong reboot decisions). |
| D2 | Unit checks auto-discovered: `tests/<n>-unit.sh` → `checks.x86_64-linux.rpi-<n>-unit` (`deploy-unit.sh` keeps the name `rpi-deploy-unit`). Shellcheck (`rpi-deploy-syntax`) covers every tracked `*.sh` outside `tests/` (incl. `ci/`). | M5 and M7 add tests and scripts without touching `flake.nix` (same reasoning as old D3). | One flake hunk per new script/test (rebase conflicts between parallel milestones). |
| D3 | M1 creates the stub `modules/pull-update.nix` (`{ ... }: { }`) and imports it in `rpi`. | M6 fills only its own file. | M6 editing the module list in flake.nix. |
| D4 | One shared unit-check environment: `git zstd gnugrep gnused gawk jq findutils util-linux coreutils`. | `rpi-pull` needs real `flock`. Mocks in `$BIN` come first on PATH, so `deploy-unit`'s `lsblk`/`findmnt` stay mocked (behaviour-neutral for existing tests). | Per-test input lists (flake edits per test). |
| D5 | narHash on both sides = `nix-store --query --hash P` → `nix hash convert --to sri`. | Nix 2.34 deprecates `--json` without `--json-format` (observed warning); the legacy query is stable on CI and Pi (Pi nix 2.34.9). Spec intent (compare narHash) kept. | `nix path-info --json` (format/flag churn). |
| D6 | Every `nix` (new CLI) call on the Pi passes `--extra-experimental-features nix-command`. | The Pi's `nix.settings.experimental-features` is unset (observed). | Enabling nix-command system-wide (unrequested config change). |
| D7 | `rpi-pull` decides switch vs boot **before** `nix-env --set` (fingerprint of the realised path vs `/run/booted-system`). | Read-only, so a fingerprint failure leaves the profile untouched (spec: failures before step 5 leave the Pi untouched). | Fingerprint after step 5 (spec order; a failure would leave a half-applied boot default). |
| D8 | Pointer HTTP 404 → exit 0 "no pointer published yet"; `seq == last` → exit 0 "up to date"; `seq < last` → exit 31 (visible failure). | Spec "no pointer file yet → nothing"; an older seq is a rollback attempt or a repo reset and must show up in `systemctl status`. | Silent no-op for older seq (hides attacks). See Q4. |
| D9 | `pointerUrl`/`cacheUrl` accept `https?://`; an `http://` pointer adds a module `warnings` entry. curl uses `--proto-redir =https`. | The spec's pull-smoke serves the pointer over HTTP; production URLs are HTTPS (raw.githubusercontent.com). See Q2. | https-only + TLS in qemu (cert plumbing in the smoke image). |
| D10 | CI lock update keeps the old fallback: on a kernel cache miss restore `flake.lock`, update `nixpkgs` only, guard again. | A week where nvmd `develop` is uncached must not block userspace security fixes (behaviour of the removed job). See Q3. | Fail the run (no update that week). |
| D11 | CI scripts print `key=value` lines on stdout for `$GITHUB_OUTPUT` (`name=`, `top=`, `changed=`, `pushed=`); all logs go to stderr. | Workflow steps stay one-liners (`ci/x.sh … >> "$GITHUB_OUTPUT"`), scripts stay unit-testable. | Inline shell in YAML (untestable). |
| D12 | The cache name is read from `nixos/keys.nix` (`ci/cache-name.sh`). | Single source (spec §6: user puts name/key into keys.nix). | Repository variable or a literal in the workflow (two places). See Q9. |
| D13 | Pointer `rev` = the commit the build started from (`GITHUB_SHA`). | The lock commit that carries the pointer cannot name itself. | Second commit just for `rev` (noise). |
| D14 | `rpi-deploy`'s downgrade check reads the local `refs/remotes/origin/main` and never fetches; no `origin` remote or no such ref → skipped. | No network/credential prompts in `deploy`; message says `git pull` first. See Q7. | Auto `git fetch` (side effects). |
| D15 | Service: `Type=oneshot`, `restartIfChanged = false`, `X-StopOnRemoval = false`, `MemoryMax=384M`, `Nice=19`, `IOSchedulingClass=idle`, `CPUSchedulingPolicy=idle`, `TimeoutStartSec=2h`, `StateDirectory=rpi-pull`, `HOME=/root`. Timer: `OnCalendar` option, `Persistent=true`, `RandomizedDelaySec=30m`. | `switch-to-configuration` must not stop the unit that runs it (s8 risk); 384M ≈ 2× the measured 180 MB worst case. | Defaults (unbounded; the unit can kill itself mid-switch). |
| D16 | `system.nixos.tags = lib.mkForce [ ]` in `modules/sd-image.nix`. | nixpkgs `sd-image.nix:275` sets `[ "sd-card" ]`; no other tags exist. | Filtering the list (not expressible without recursion). |
| D17 | `pull-smoke` writes its pointer with the real `ci/pointer.sh` and serves `www/` with `python3 -m http.server` on a fixed port (`RPI_PULL_SMOKE_HTTP_PORT`, default 18080) reached from the guest at `192.168.100.1` (slirp host). The cache holds only the closure difference to the image (`nix copy --no-recursive`, signed via `?secret-key=`). | End-to-end CI writer → Pi reader; small cache; no root needed for signing. | Full 3 GiB closure copy (fallback if `--no-recursive` is refused). |
| D18 | CI commit identity `github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>`, `-c commit.gpgsign=false`; push `HEAD:main`, on failure `git pull --rebase origin main` once and push again. | Spec "rebases once and retries"; unattended job cannot sign. | Force push (loses user commits). |

## 4. Gate (spec invariants; no principles document in the repo)

| Row | Invariant | Result | Enforced by |
|---|---|---|---|
| G1 | The Pi never evaluates or builds (only realises store paths) | PASS | `rpi-pull-unit` p19 (0 `nix eval`/`nix build`/`nixos-rebuild` in the mock log), D6 |
| G2 | No local kernel/toolchain build in CI; ≤ 500 builds | PASS | `ci/build.sh` → `rl_guard toplevel 500`; `rpi-ci-unit` b4/b5 |
| G3 | Failures before `nix-env --set` leave the Pi untouched | PASS | `rpi-pull-unit` P1 over p3–p13 |
| G4 | Trust = our key only + name regex + monotonic seq + narHash | PASS | `rpi-pull-unit` p5–p10, p13; `pull-smoke` tamper path |
| G5 | Pointer written only after a successful push + pin; any failing step leaves it unchanged | PASS | workflow step order asserted by the `actionlint` check; `rpi-ci-unit` u2/u3, w3 |
| G6 | Manual `rpi-deploy deploy` keeps working; pull applies only newer seq | PASS | `rpi-deploy-unit` (unchanged d1–d14 except the downgrade source), p6 |
| G7 | Host auto-update fully removed | PASS | `eval-build-host` row, grep in T1.1 verify |
| G8 | Simplicity: no new tools beyond Cachix/GitHub Actions/actionlint | PASS | review |
| G9 | Spec option set `rpi.pull = { enable; pointerUrl; cacheUrl; cachePublicKey; onCalendar; rebootTime }` | PASS (no extra options; `--host` comes from `config.system.name`) | `eval-pull-update` |
| G10 | Spec step order of the Pi run | VIOLATION (D7: decision before `nix-env`) | complexity row C1 |
| G11 | Spec "compare `nix path-info --json` narHash" | VIOLATION (D5) | C2 |
| G12 | Spec "HTTPS from GitHub" for the pointer | PASS with D9 warning for http (smoke only) | `eval-pull-update` warning row |

| Complexity row | Need | Simpler alternative rejected |
|---|---|---|
| C1 decision before profile change | fail-safe if the fingerprint cannot be read | spec order (half-applied boot default on failure) |
| C2 `nix-store -q --hash` + `nix hash convert` | stable across Nix versions | `path-info --json` (deprecated form) |
| C3 `rpi-fp.sh` split | Pi must not carry host code | Pi sources `rpi-lib.sh` |
| C4 auto-discovered checks | parallel milestones without flake.nix conflicts | per-check flake hunks |
| C5 test hooks `RPI_PULL_ROOT`, `RPI_PULL_STORE` | unit tests without root and a real store | none (a real Pi) |

## 5. Global constraints (verbatim from the spec)

- Pointer `nixos/deploy/neptun.json`: `{ "seq": <int>, "storePath": "/nix/store/…-nixos-system-neptun-…", "narHash": "sha256-…", "rev": "<git sha of the built tree>", "built": "<ISO time>" }`; `seq` = `github.run_number`.
- storePath regex: `^/nix/store/[a-z0-9]{32}-nixos-system-neptun-[^/]*$`.
- Signature check: `nix store verify --no-contents --store <cacheUrl> --trusted-public-keys <ours> <storePath>`.
- Realise: `nix-store -r <storePath>` with `max-substitution-jobs = 2`; profile: `nix-env -p /nix/var/nix/profiles/system --set <storePath>`; state in `/var/lib/rpi-pull/`.
- Options `rpi.pull = { enable; pointerUrl; cacheUrl; cachePublicKey; onCalendar = "Sun 05:00"; rebootTime = "04:30"; }`; enabled by default once `keys.cache` and the pointer URL are set. Timer `Persistent=true`, `RandomizedDelaySec=30m`; `MemoryMax` bounded; nice/ionice idle.
- `keys.nix`: `cache = { name; publicKey; }` → Pi `nix.settings.substituters` + `trusted-public-keys`.
- Workflow `.github/workflows/neptun.yml`: `schedule` Sun 01:00 UTC, `push` to `main` (paths `nixos/**`, excluding `nixos/deploy/**`), `workflow_dispatch`; `ubuntu-24.04-arm`; `cachix/install-nix-action@v31`, `cachix/cachix-action@v17` (`skipPush: true`), nvmd cachix as extra substituter; `concurrency: neptun`.
- CI steps: (cron) lock update → `rl_guard toplevel 500` → build → `df -h` logged → push closure → `cachix pin <cache> neptun <top> --keep-revisions 4` → pointer → commit + push (rebase once on non-fast-forward).
- Secrets `CACHIX_AUTH_TOKEN`, `CACHIX_SIGNING_KEY`. Self-signed cache.
- Toplevel name `nixos-system-neptun-<version>` (no `sd-card` tag).
- Downgrade check: lock content (`nixpkgs`, `nixos-raspberrypi` `locked.lastModified`) vs `origin/main`; skipped without `origin`; tell the user to `git pull`; `--force` overrides.
- `rpi-deploy status` shows the pull state (last seq, last run result via `systemctl show rpi-pull`).

## 6. Review focus (most likely to bite; each has a test in its owning task)

1. **A freshly flashed Pi (no `/var/lib/rpi-pull/seq`) applies the published pointer at its first timer run**, even if the flashed image is newer (built locally, not yet pushed). Pinned by `rpi-pull-unit` p20 (behaviour as spec'd) and documented in README (T9.1); see Q1.
2. **Cache eviction / Cachix outage between pointer and pull** (`nix-store -r` fails). Expected: exit 33, profile and seq untouched, retried next week. Test: p12.
3. **The user pushes to `main` while CI runs** (non-fast-forward). Expected: one rebase, push succeeds, history linear; a conflicting lock edit fails the job without a pointer change. Tests: g3, g4.
4. **`switch-to-configuration` stops the service that runs it** when the new system changes `rpi-pull.service`. Expected: no restart/stop (`restartIfChanged = false`, `X-StopOnRemoval = false`). Test: `eval-pull-update` service row; pull-smoke switch path changes the unit (new ExecStart store path) and must still finish.
5. **A stale local checkout deploys over a CI update** (`origin/main` lock newer). Expected: `would downgrade … git pull`, exit 15; `--force` overrides. Tests: d6/d7 (adapted).

## 7. Files to read first (list only; read at the start of your milestone)

- Everyone: the addendum spec, this plan §0–§6, your milestone; `HANDOFF.md` §6.
- M1: `nixos/flake.nix` (checks, mkRpiDeploy, rpi-host-vm), `nixos/modules/build-host.nix`, `nixos/tests/eval/{default,build-host,tools}.nix`, `nixos/tests/harness.sh`.
- M2: `nixos/rpi-lib.sh` (lines 128–244: `RL_FP_SCRIPT` … `rl_fp_changed`), `nixos/tests/deploy-unit.sh` lines 170–258, `nixos/tests/make-sys.sh`.
- M3: `nixos/keys.nix`, `nixos/configuration.nix`, `nixos/modules/sd-image.nix`, `nixos/tests/eval/{pi-config,image}.nix`; nixpkgs `nixos/modules/misc/label.nix`, `installer/sd-card/sd-image.nix:275` (`ev --raw $R.nixpkgs.flake.source` or `.#nixosConfigurations.rpi.pkgs.path`).
- M4: `nixos/rpi-deploy.sh` (`check_downgrade`, `do_status`, usage), `nixos/tests/deploy-unit.sh` lines 515–835.
- M5: `nixos/rpi-fp.sh` (after M2), `nixos/tests/{harness,make-sys}.sh`, `nixos/tests/deploy-unit.sh` (mock style), `nixos/.scratch/s8/REPORT.md` §3, §5, §6, `nixos/.scratch/s7/thoughtfull_system-pull.bash` if present.
- M6: `nixos/modules/build-host.nix` (option/unit style, `utils.escapeSystemdExecArgs`), `nixos/tests/eval/build-host.nix` (ExecStart property helper), `nixos/configuration.nix`, nixpkgs `nixos/modules/tasks/auto-upgrade.nix` (service flags).
- M7: `nixos/rpi-lib.sh` (`rl_guard`, exit codes), `nixos/.scratch/s8/REPORT.md` §4 (workflow sketch), `nixos/tests/deploy-unit.sh` lines 1–80 (nix mock).
- M8: `nixos/tests/deploy-smoke.sh`, `nixos/tests/qemu-pi.sh`.
- M9: `README.md`, `HANDOFF.md`, both specs.

## 8. Type-checking strategy

| Checker | When | Expected rejections |
|---|---|---|
| NixOS module system | every `ev`/`chk`, `nix flake check --no-build` | `pointerUrl = "ftp://…"` / `"raw.github…"` (no scheme) against `nullOr (strMatching "https?://.+")`; `cachePublicKey` without `name:` prefix or wrong base64 length; `rebootTime = "24:00"`; defining `rpi.buildHost.autoUpdate` after M1 ("option does not exist"); `rpi.pull.enable = true` with a null URL/key (assertion). |
| *Not* caught by types | — | a pointer URL that 404s, a cache name that does not exist, a public key of another cache → covered by pull-smoke and the first real run (§12). |
| `bash -n` + `shellcheck -x -P SCRIPTDIR -S warning` (`rpi-deploy-syntax`) | after every script edit (`chk rpi-deploy-syntax`, or `shellcheck -x -P SCRIPTDIR -S warning <file>` locally) | unset/unused variables, SC2155, unquoted expansions, unresolvable `source` (`# shellcheck source=…`). |
| `actionlint` (+ shellcheck on inline `run:`) | `chk actionlint` after editing the workflow | unknown keys, bad expressions/contexts, unknown `steps.<id>` outputs, invalid cron, shell issues in `run:`. |
| `jq -e` with type predicates (runtime) | inside `rpi-pull.sh` / `ci/pointer.sh` | pointer fields of the wrong JSON type. |

## 9. Testing strategy per layer

| Layer | Covers | Needs | Cost |
|---|---|---|---|
| L1 eval checks `eval-*` | `eval-build-host` (removal), `eval-pi-config` (root keys), `eval-image` (no tag), `eval-tools` (packaged `rpi-fp.sh`), `eval-pull-update` (options, defaults, units, substituter/key, warning) | flake eval only; never force `toplevel` | cheap |
| L2 bash unit `rpi-deploy-unit` | fingerprint refactor parity, `origin/main` downgrade, status pull lines | mocks (nix, ssh, …), real git | cheap |
| L2 bash unit `rpi-pull-unit` | every `rpi-pull` path: fetch/parse/validate/verify/current/realise/narHash/profile/decision/state/lock | mocks curl, nix, nix-store, nix-env, shutdown, sync; fake toplevels (`make_sys`) with a real fake-store bash for `switch-to-configuration` | cheap |
| L2 bash unit `rpi-ci-unit` | `ci/*.sh`: event → lock update, fallback, guards, outputs, publish order, pointer write/idempotence/monotonic, commit + rebase-once | mocks nix, nix-store, cachix; real git with a bare `origin` | cheap |
| L3 lint | `rpi-deploy-syntax` (all `*.sh` outside `tests/`), `actionlint` (+ step order) | shellcheck, actionlint | cheap |
| L4 NixOS VM `rpi-host-vm` | build-host still works without autoUpdate | KVM | expensive, 1–16 min (once, M1) |
| L5 qemu `pull-smoke` | real `rpi-pull` + module on the image: switch path; foreign-key pointer refused; status pull lines | qemu raspi3b, python3, network for the guards | expensive, 30–50 min |
| L6 qemu `deploy-smoke` / `boot-smoke` | regression of push deploy / boot after the tag and status changes | as before | expensive, optional (M9) |
| L7 real GitHub + Cachix + Pi | first workflow run, pin, pointer commit, Pi timer run | user setup (spec §6) | manual |

## 10. Properties (assert over values; literals only where the literal is the criterion)

- P1 Failure safety: ∀ s ∈ {fetch error, invalid JSON, bad seq, bad path, bad narHash format, untrusted, realise error, narHash mismatch}: `readlink profile` unchanged ∧ `count(nix-env|stc|shutdown) = 0` ∧ `$STATE/seq` unchanged.
- P2 Order on success: `verify < realise < nix-env < stc < sync < state write` (mock-log line numbers; state write observed by mtime/presence after sync line).
- P3 Decision: `stc boot ∧ shutdown -r T ⇔ rl_needs_reboot(fp(new), fp(booted))`, else `stc switch ∧ ¬shutdown`; varied over each part ∈ {kernel, initrd, modules, dtbs, params, fw, cfg, uboot} (boot) and {ext} (switch).
- P4 Trust argv: the verify call contains `--trusted-public-keys <key>` and `--store <cacheUrl>` and `--no-contents`, and never `--extra-trusted-public-keys`.
- P5 Seq monotonic: `seq ≤ last ⇒ count(verify|realise|nix-env|stc) = 0`.
- P6 Name: `valid(p) ⇔ p =~ ^<store>/[a-z0-9]{32}-nixos-system-<host>-[^/]*$` checked on a table of good/bad paths.
- P7 Pointer round trip: `jq .seq` is a number = N, `.storePath` = TOP, `.narHash` = `sri(nix-store -q --hash TOP)`, `.built` matches `^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$`.
- P8 Pointer idempotence: same TOP ⇒ file bytes unchanged ∧ `changed=false`.
- P9 Name compatibility: `"nixos-system-${system.name}-${system.nixos.label}"` matches the rpi-pull regex ∧ `label = system.nixos.version` (no tags).
- P10 ExecStart passes every option: ∀(flag, value) ∈ {(--pointer-url, pointerUrl), (--cache-url, cacheUrl), (--cache-key, cachePublicKey), (--host, system.name), (--reboot-time, rebootTime), (--state-dir, /var/lib/rpi-pull)}: `escapeSystemdExecArgs [flag value]` ⊂ ExecStart.
- P11 Enable rule: `enable = (pointerUrl ≠ null ∧ cacheUrl ≠ null ∧ cachePublicKey ≠ null)` on the real `rpi` (stays true after the user fills `keys.nix`).
- P12 Fingerprint parity: `rpi-deploy-unit` assertion count and results identical before/after the `rpi-fp.sh` extraction; `rpi-fp.sh` alone defines `rl_fp_local rl_needs_reboot rl_fp_changed` and no `rl_ssh`/`rl_guard`.

Pinned literals (user-facing): `pull: disabled`, `pull applied: seq <N> <path>`, `pull applied: none`, `pull last run: <Result> (exit <N>) at <ts>`, `pull last run: never`, `pull: unknown`, `would downgrade`, `git pull`, `no pointer published yet`, `up to date`, `older than applied`, `untrusted`, `narHash mismatch`; exit codes §15.1.

## 11. Planted violations (tick after seeing red)

| Check | Plant (temporary) | Must FAIL with | Seen |
|---|---|---|---|
| `eval-build-host` | keep `options.rpi.buildHost.autoUpdate.enable` declared | `FAIL: no autoUpdate option or units` | [ ] |
| unit auto-discovery | `tests/zz-unit.sh` = `echo FAIL: planted; exit 1` (git add -N) | `chk rpi-zz-unit` fails with `FAIL: planted` | [ ] |
| syntax auto-discovery | `ci/zz.sh` = `echo $undefined_planted` (git add -N) | `chk rpi-deploy-syntax` → SC2154 | [ ] |
| `rpi-deploy-unit` x1 | `rpi-fp.sh` defines `rl_ssh() { :; }` | `FAIL: x1 rpi-fp.sh defines no host functions` | [ ] |
| `eval-tools` | drop the `cp … rpi-fp.sh` line from mkRpiDeploy | `FAIL: rpi-deploy package ships rpi-fp.sh next to rpi-lib.sh` | [ ] |
| `eval-pi-config` | configuration.nix root keys `++ [ "ssh-ed25519 AAAAplanted x" ]` | `FAIL: root has exactly the user key` | [ ] |
| `eval-image` | delete the `system.nixos.tags` line | `FAIL: no sd-card tag: toplevel is nixos-system-neptun-<version>` | [ ] |
| `rpi-deploy-unit` d6 | `check_downgrade` reads `refs/heads/auto-update` again | `FAIL: d6 origin/main locks a newer nixpkgs -> RL_E_DOWNGRADE` | [ ] |
| `rpi-deploy-unit` s5 | `do_status` skips the pull query | `FAIL: s5 status shows the applied pull seq` | [ ] |
| `rpi-pull-unit` p10 | verify with `--extra-trusted-public-keys` | `FAIL: p10 verify uses --trusted-public-keys only` | [ ] |
| `rpi-pull-unit` p7 | compare `seq >= last` as newer | `FAIL: p7 older seq refused` | [ ] |
| `rpi-pull-unit` p13 | skip the narHash comparison | `FAIL: p13 narHash mismatch -> exit 34` | [ ] |
| `rpi-pull-unit` p15 | swap the `switch`/`boot` branches | `FAIL: p15 kernel change -> boot + shutdown -r 04:30` | [ ] |
| `eval-pull-update` | `restartIfChanged = true` | `FAIL: service: oneshot, idle, bounded, never restarted by a switch` | [ ] |
| `eval-pull-update` | enable default `true` | `FAIL: disabled without cache key or pointer URL (no units)` | [ ] |
| `rpi-ci-unit` b2 | `build.sh` ignores `--event schedule` | `FAIL: b2 schedule updates nixpkgs and nixos-raspberrypi` | [ ] |
| `rpi-ci-unit` u2 | `publish.sh` pins before pushing | `FAIL: u2 push failure -> no pin` | [ ] |
| `rpi-ci-unit` w3 | `pointer.sh` writes without the seq comparison | `FAIL: w3 non-increasing seq refused` | [ ] |
| `rpi-ci-unit` g3 | `commit-push.sh` without the rebase retry | `FAIL: g3 non-fast-forward -> rebase once, pushed` | [ ] |
| `actionlint` | `steps.bild.outputs.top` typo in the workflow | actionlint `property "bild" is not defined` | [ ] |
| `actionlint` (order) | move the pointer step above the publish step | `FAIL: pointer is written after push + pin` | [ ] |
| pull-smoke [expensive] | `RPI_PULL_SMOKE_PLANT=1` (smoke-next signed by the foreign key) | `FAIL: rpi-pull did not apply smoke-next` | [ ] |

## 12. Coverage gap (manual, with reasons)

Not reached by the automated layers:

1. A real GitHub Actions run: runner disk (14 GB), `cachix-action` with a self-signed key, `GITHUB_TOKEN` push permission, cron timing, raw.githubusercontent.com CDN lag (≤ 5 min). → spec AC3 after the user's setup (`workflow_dispatch`).
2. Real Cachix: pin semantics, LRU eviction, `cachix push` skipping cache.nixos.org paths (upload size ~341 MiB first, ~150 MiB weekly per s8).
3. The real Pi: RAM under `MemoryMax=384M` with the full weekly delta, SD wear of the realise, `shutdown -r 04:30` and a reboot into a new kernel via U-Boot (qemu skips U-Boot).
4. Timing between CI (Sun 01:00 UTC) and the Pi (Sun 05:00 local + ≤ 30 min): a CI run longer than ~3 h is applied a week later.
5. `ci/cache-name.sh` against real `nix eval` of `keys.nix` (unit test mocks nix) → one manual `[cheap]` run in T7.2.

Manual checklist (README + HANDOFF, T9.1): after the user's setup run the workflow by hand → pointer commit on `main` with `seq` = run number → `cachix pin` visible in Cachix UI → deploy the Pi once with `rpi.pull` enabled (`rpi-deploy deploy switch`) → `ssh -p 2222 root@neptun systemctl start rpi-pull` → `rpi-deploy status` shows `pull applied: seq <N>` and `pull last run: success (exit 0)`.

## 13. Scenario coverage (spec → the one check that executes it)

| Spec scenario | Check |
|---|---|
| §3.5 remove `rpi.buildHost.autoUpdate`, script, tests, eval rows | `eval-build-host` (T1.1) |
| §3.5 remove `keys.autoUpdate`/`hostAddress` | `eval-pi-config` (T3.1) |
| §3.5 downgrade vs `origin/main`, skip without origin, `git pull` hint, `--force` | `rpi-deploy-unit` d6/d7/d11/d16–d20 (T4.1) |
| §3.5 toplevel without `sd-card` | `eval-image` (T3.2) |
| §3.1 `keys.cache` → substituter + trusted key | `eval-pull-update` (T6.2/T6.3) |
| §3.4 options, defaults, enabled once key + URL set | `eval-pull-update` (T6.1, T6.3) |
| §3.4 timer/service properties | `eval-pull-update` (T6.2) |
| §3.4 step 1 fetch (timeout, retries), 404 | `rpi-pull-unit` p2/p3 |
| §3.4 step 2 seq / regex / signature | `rpi-pull-unit` p5–p10 |
| §3.4 step 3 already current | `rpi-pull-unit` p11 |
| §3.4 step 4 realise (2 jobs), narHash | `rpi-pull-unit` p12/p13 |
| §3.4 steps 5–7 profile, fingerprint decision, sync, state | `rpi-pull-unit` p14–p17 |
| §3.4 fingerprint shared, Pi variant | `rpi-deploy-unit` x1 + existing fp tests (T2.1); `rpi-pull-unit` p15 |
| §3.4 status shows pull state | `rpi-deploy-unit` s5–s7 (T4.2) |
| §3.3 cron lock update, guard, build, df | `rpi-ci-unit` b1–b7 |
| §3.3 push closure + pin keep 4 | `rpi-ci-unit` u1–u3 |
| §3.2 pointer fields, written only when storePath changed | `rpi-ci-unit` w1–w5 |
| §3.2 commit to main, rebase once, fail → unchanged | `rpi-ci-unit` g1–g5 |
| §3.3 triggers, actions, concurrency, step order | `actionlint` check (T7.5) |
| §4 pull-smoke switch + refused tamper | `tests/pull-smoke.sh` (T8.1) |
| AC1 `nix flake check` | T9.2 |
| AC2 pull-smoke | T9.2 |
| AC3 real CI + Pi | manual (§12) |

---

## 14. Milestones, dependencies, file ownership

```
M1 remove host auto-update + test plumbing (serial)
 └─ M2 extract rpi-fp.sh (serial, refactor)
     ├─ M3 Pi config: root keys, no sd-card tag ──────────────┐
     ├─ M4 rpi-deploy: origin/main downgrade, pull status ─────┤   M3 ∥ M4 ∥ M5 ∥ M7
     ├─ M5 rpi-pull script + unit tests ──────────────────────┤   (worktrees, disjoint files)
     └─ M7 CI scripts + workflow + actionlint ────────────────┤
                       M6 pull module (after M3, M5) ─────────┤
                       M8 pull-smoke (after M4, M6, M7) ──────┤
                       M9 docs, final acceptance, final review (after all)
```

| Milestone | Owns (creates/modifies/deletes) | Depends on | Parallel with |
|---|---|---|---|
| M1 | `flake.nix` (mkRpiDeploy, checks, rpi-host-vm, rpi module list), `modules/build-host.nix`, `rpi-autoupdate.sh` (rm), `tests/autoupdate-unit.sh` (rm), `tests/eval/build-host.nix`, `tests/eval/tools.nix` (comment), `tests/harness.sh` (comment), `modules/pull-update.nix` (stub) | — | none |
| M2 | `rpi-fp.sh` (new), `rpi-lib.sh`, `flake.nix` (mkRpiDeploy: one `cp` line), `tests/eval/tools.nix`, `tests/deploy-unit.sh` (x1 only) | M1 | none |
| M3 | `keys.nix` (remove autoUpdate/hostAddress), `configuration.nix` (root keys, comments), `modules/sd-image.nix`, `tests/eval/pi-config.nix`, `tests/eval/image.nix` | M2 | M4, M5, M7 |
| M4 | `rpi-deploy.sh`, `tests/deploy-unit.sh` | M2 | M3, M5, M7 |
| M5 | `rpi-pull.sh` (new), `tests/pull-unit.sh` (new) | M2 | M3, M4, M7 |
| M6 | `modules/pull-update.nix` (fill), `tests/eval/pull-update.nix` (new), `keys.nix` (`cache`), `configuration.nix` (cache wiring) | M3, M5 | M4, M7 (if still running) |
| M7 | `ci/{cache-name,build,publish,pointer,commit-push}.sh` (new), `tests/ci-unit.sh` (new), `../.github/workflows/neptun.yml` (new), `flake.nix` (`actionlint` check only, placed after `rpi-host-vm`) | M2 | M3, M4, M5, M6 |
| M8 | `tests/pull-smoke.sh` (new) | M4, M6, M7 | none |
| M9 | `../README.md`, `../HANDOFF.md` | all | none |

Each parallel milestone runs its own checks only (`chk …`); the full `nix flake check` runs in M9. Integration order of the parallel group is free (disjoint files); after each `merge --ff-only` the orchestrator runs `nix flake check --no-build --accept-flake-config` once.

---

## 15. Tasks

### 15.1 Shared interfaces

**`rpi-fp.sh` (M2 produces; `rpi-lib.sh`, M5 consume).** Sourced, pure bash + coreutils `readlink`; no side effects.

```bash
RL_FP_SCRIPT='…'          # moved verbatim from rpi-lib.sh
rl_fp_local SYSTEM        # fingerprint of a local toplevel; store = ${RL_STORE_DIR:-/nix/store}
rl_needs_reboot FP_A FP_B # 0 iff different
rl_fp_changed FP_A FP_B   # "kernel, fat"
```
`rpi-lib.sh` gains, before the fingerprint section: `RL_FP_LIB=${RL_FP_LIB:-$(dirname "${BASH_SOURCE[0]}")/rpi-fp.sh}`; `# shellcheck source=rpi-fp.sh`; `source "$RL_FP_LIB" || return 1`. `rl_fp_remote` stays and uses `$RL_FP_SCRIPT`.

**`rpi-pull` (M5 produces; M6, M8 consume).**

```
rpi-pull --pointer-url URL --cache-url URL --cache-key KEY [--host neptun] [--state-dir /var/lib/rpi-pull] [--reboot-time 04:30]
env: RPI_FP_LIB (default: rpi-fp.sh next to the script)
test hooks: RPI_PULL_ROOT (prefix of /run/{current,booted}-system and /nix/var/nix/profiles/system; default "")
            RPI_PULL_STORE (store dir used in the regex and as RL_STORE_DIR; default /nix/store)
state: $STATE/seq, $STATE/store-path (written via tmp + mv, after sync), $STATE/lock (flock -n)
exit: 0 applied | up to date | already current | no pointer published yet
      2 usage | 30 fetch | 31 pointer invalid or older | 32 untrusted | 33 realise | 34 narHash mismatch
      35 profile | 36 activation (stc / shutdown) | 37 busy
logs: stderr, prefix "rpi-pull: "
```

Run algorithm (exit on the first failure with its code):
```
mkdir -p STATE; exec {fd}>STATE/lock; flock -n fd || exit 37
last = content of STATE/seq, or 0
code = curl -sS --proto-redir =https --max-time 60 --retry 3 --retry-delay 20 -o TMP -w '%{http_code}' URL
   curl rc≠0 → 30 | code 404 → log "no pointer published yet", exit 0 | code≠200 → 30
jq -e: .seq integer ≥ 1, .storePath string, .narHash string → else 31   (sets P_SEQ P_PATH P_NAR)
P_SEQ == last → log "up to date (seq N)", exit 0 ;  P_SEQ < last → 31 "pointer seq N is older than applied seq M"
P_PATH =~ ^STORE/[a-z0-9]{32}-nixos-system-HOST-[^/]*$ else 31 ; P_NAR =~ ^sha256-[A-Za-z0-9+/]{43}=$ else 31
nix --extra-experimental-features nix-command store verify --no-contents --store CACHE --trusted-public-keys KEY P_PATH  else 32 ("untrusted")
readlink -f ROOT/run/current-system == P_PATH → record; log "already current"; exit 0
nix-store --realise P_PATH --option max-substitution-jobs 2 else 33
sri(nix-store --query --hash P_PATH) == P_NAR else 34 ("narHash mismatch")        # sri = nix … hash convert --to sri
fp_new = rl_fp_local P_PATH ; fp_boot = rl_fp_local ROOT/run/booted-system  else 36   (RL_STORE_DIR=STORE)
nix-env -p ROOT/nix/var/nix/profiles/system --set P_PATH else 35
if rl_needs_reboot fp_new fp_boot: P_PATH/bin/switch-to-configuration boot ; shutdown -r REBOOT_TIME
else: P_PATH/bin/switch-to-configuration switch
sync (always after stc) ; stc/shutdown failure → 36 (seq not recorded)
record: STATE/seq ← P_SEQ, STATE/store-path ← P_PATH ; log "applied seq N (switch|boot, reboot at T)"
```

**CI scripts (M7 produces; workflow, M8 consume).** Each: `set -euo pipefail`, logs on stderr, `key=value` on stdout, `--help`.

```
ci/cache-name.sh [--flake DIR]                  → name=<cache>   ; exit 1 "set cache = { name; publicKey; } in nixos/keys.nix" if null
ci/build.sh [--event NAME] [--flake DIR] [--max-builds 500]
                                                → top=<storePath> ; exit RL_E_* (rpi-lib.sh)
   NAME (default $GITHUB_EVENT_NAME) == schedule → nix flake update nixpkgs nixos-raspberrypi, then guard;
   RL_E_CACHE after an update → git -C DIR checkout -- flake.lock; nix flake update nixpkgs; guard again (D10)
   then nix build --no-link --print-out-paths <conf>.config.system.build.toplevel; df -h / >&2
ci/publish.sh CACHE TOP                         → cachix push CACHE TOP && cachix pin CACHE neptun TOP --keep-revisions 4
ci/pointer.sh --seq N --rev SHA --file PATH [--host neptun] TOP
                                                → changed=true|false ; exit 1 on bad N/TOP or N ≤ existing seq (different path)
ci/commit-push.sh --message MSG PATH...         → pushed=true|false ; exit 1 when the retry fails
```
`DIR` defaults to the script's `../` (the `nixos/` flake). All scripts source `../rpi-lib.sh` only where needed (`build.sh`); `RPI_LIB` overrides the path.

**Unit-test harness (`tests/harness.sh`, existing, unchanged API):** `mock`, `run_cmd`, `expect_*`, `log_count`, `reset_log`, `summary`, `make_sys`, `$T $BIN $MOCK_LOG $FX_STORE`.

---

### M1 — Remove host auto-update; test plumbing (serial, first)

**Risk:** low-medium (VM test and contract asserts must still hold).

#### Task 1.1: Remove `rpi.buildHost.autoUpdate` and `rpi-autoupdate`  `[ ]`

**Files:** `modules/build-host.nix`, `flake.nix`, `tests/eval/build-host.nix`, `tests/eval/tools.nix` (comment), `tests/harness.sh` (comment), delete `rpi-autoupdate.sh`, `tests/autoupdate-unit.sh`.

- [ ] RED `[cheap]`: in `tests/eval/build-host.nix` delete every "Task 6.2" row and its helpers (`enabled`, `au`, `svc`, `timer`, `passes`, `failedAssertion` if unused); existing tests change because spec §3.5 removes the feature. Add:
  - `"no autoUpdate option or units"` = `!(hostTestSystem.options.rpi.buildHost ? autoUpdate) && !(cfg.systemd.services ? rpi-autoupdate) && !(cfg.systemd.timers ? rpi-autoupdate)`

  `chk eval-build-host` → exactly `FAIL: no autoUpdate option or units`.
- [ ] GREEN:
  - `build-host.nix`: delete `options.rpi.buildHost.autoUpdate`, both `mkIf au.enable` / `mkIf (cfg.enable && au.enable)` blocks, `au`, the now-unused `utils` argument; header comment: "rpi-deploy image/flash/deploy/status" only; wrapper comment ("the package's other tools") stays generic.
  - `flake.nix`: mkRpiDeploy installs only `rpi-deploy` + `rpi-lib.sh` (drop `rpi-autoupdate` and the loop; keep the wrapper flags incl. `jq util-linux`); delete the `autoupdate-unit` check; `rpi-deploy-syntax` fileset/loop without `rpi-autoupdate.sh`; `rpi-host-vm`: drop `users.users.alice`, `rpi.buildHost.autoUpdate`, and the five auto-update `testScript` lines; fix comments mentioning `rpi-autoupdate`.
  - `git rm rpi-autoupdate.sh tests/autoupdate-unit.sh`; comments in `tests/harness.sh` and `tests/eval/tools.nix` (util-linux stays: `lsblk`/`findmnt` for flash).
- [ ] Verify `[cheap]`: `chk eval-build-host && chk eval-tools && chk rpi-deploy-unit && chk rpi-deploy-syntax`; `ev --raw $R.system.build.toplevel.drvPath >/dev/null && nix flake check --no-build --accept-flake-config`; `grep -rn -i 'autoupdate\|auto-update' --include='*.nix' --include='*.sh' .` → hits only in `keys.nix`, `configuration.nix`, `tests/eval/pi-config.nix`, `rpi-deploy.sh`, `tests/deploy-unit.sh` (owned by M3/M4).
- [ ] Planted: `eval-build-host` row (§11) → seen red → reverted.
- [ ] `[expensive, 1–16 min]` `chk rpi-host-vm` → passes.
- [ ] Commit: "Remove host auto-update (rpi.buildHost.autoUpdate, rpi-autoupdate, autoupdate-unit)".

#### Task 1.2: Auto-discovered unit and syntax checks; stub pull module (refactor)  `[ ]`

**Files:** `flake.nix`, `modules/pull-update.nix` (new stub).

- [ ] Before evidence `[cheap]`: `ev .#checks.x86_64-linux --apply builtins.attrNames --json > .scratch/ci/checks-before.json`; `chk rpi-deploy-unit 2>&1 | grep -E '^[0-9]+ passed' > .scratch/ci/unit-before.txt`; `ev --raw $R.system.build.toplevel.drvPath > .scratch/ci/drv-before.txt`.
- [ ] Change:
  - `rpi-deploy-syntax` (both systems): `src = lib.fileset.toSource { root = ./.; fileset = lib.fileset.difference (lib.fileset.fileFilter (f: f.hasExt "sh") ./.) ./tests; }`; script: `cd $src; mapfile -t fs < <(find . -name '*.sh' | sort); for f in "${fs[@]}"; do bash -n "$f"; done; shellcheck -x -P SCRIPTDIR -S warning "${fs[@]}"`.
  - Replace the `rpi-deploy-unit` attribute with `// unitChecks` where
    ```nix
    # tests/<n>-unit.sh -> checks.x86_64-linux.rpi-<n>-unit (D2, D4)
    unitChecks = lib.mapAttrs' (file: _:
      let n = lib.removeSuffix ".sh" file; in
      lib.nameValuePair "rpi-${n}" (x86Pkgs.runCommand "rpi-${n}-check" {
        src = lib.fileset.toSource { root = ./.; fileset = lib.fileset.unions [
          (lib.fileset.fileFilter (f: f.hasExt "sh") ./.) ./tests/fixtures ]; };
        nativeBuildInputs = with x86Pkgs; [ git zstd gnugrep gnused gawk jq findutils util-linux coreutils ];
      } ''FIXTURES=$src/tests/fixtures ${x86Pkgs.bash}/bin/bash $src/tests/${file}; touch $out''))
      (lib.filterAttrs (f: t: t == "regular" && lib.hasSuffix "-unit.sh" f) (builtins.readDir ./tests));
    ```
    (`util-linux` is now present for `deploy-unit` too; its `lsblk`/`findmnt` mocks are first on PATH, so behaviour is unchanged — this is the only reason the existing check's inputs change.)
  - `modules/pull-update.nix` = `{ ... }: { }` (comment: "filled by M6"); import it in `rpi` after `./modules/external-storage.nix`. `git add` it.
- [ ] After evidence: same three commands into `*-after.*`; `diff` of check names and unit counts empty; `drv-before == drv-after` (the stub changes nothing).
- [ ] Planted: both auto-discovery rows (§11) → seen red → files deleted.
- [ ] Commit: "flake: auto-discover unit tests and shell scripts; stub pull-update module".

**M1 acceptance `[cheap]`:** `chk eval-build-host && chk eval-tools && chk rpi-deploy-unit && chk rpi-deploy-syntax && nix flake check --no-build --accept-flake-config` (+ `rpi-host-vm` from T1.1).

---

### M2 — Extract `rpi-fp.sh` (serial, refactor)

#### Task 2.1: Move the fingerprint into `rpi-fp.sh`; package it  `[ ]`

**Files:** `rpi-fp.sh` (new), `rpi-lib.sh`, `flake.nix` (one line), `tests/eval/tools.nix`, `tests/deploy-unit.sh` (x1 only).

- [ ] Before evidence: `unit deploy-unit | tail -1 > .scratch/ci/fp-before.txt` (e.g. `204 passed, 0 failed`).
- [ ] RED tests:
  - `tests/eval/tools.nix`: `"rpi-deploy package ships rpi-fp.sh next to rpi-lib.sh"` = `lib.hasInfix "$out/libexec/rpi-deploy/rpi-fp.sh" install`.
  - `tests/deploy-unit.sh` (new block after T5.3): `x1 rpi-fp.sh alone defines the fingerprint functions` (`bash -c 'source "$1"; declare -F rl_fp_local rl_needs_reboot rl_fp_changed' _ "$RPI_FP_LIB"`) and `x1 rpi-fp.sh defines no host functions` (same, `! declare -F rl_ssh rl_guard rl_nixos_rebuild rl_fp_remote`). `RPI_FP_LIB` defaults to `$HERE/../rpi-fp.sh`.

  `unit deploy-unit` → fails at x1 (file missing); `chk eval-tools` → the new row fails. Fix one at a time: deploy-unit first.
- [ ] GREEN: move `RL_FP_SCRIPT`, `rl_fp_local`, `rl_needs_reboot`, `rl_fp_changed` with their comments verbatim into `rpi-fp.sh` (`# shellcheck shell=bash`, header: "pure bash, runs on the Pi and the host; no nix/ssh/git"); `rpi-lib.sh` sources it (§15.1). mkRpiDeploy: `cp ${./rpi-fp.sh} $out/libexec/rpi-deploy/rpi-fp.sh`.
- [ ] After evidence: `unit deploy-unit | tail -1` = before + 2 assertions, 0 failed (P12); `chk rpi-deploy-unit && chk rpi-deploy-syntax && chk eval-tools`.
- [ ] `[cheap]` `nix run --accept-flake-config .#rpi-deploy -- --help` exits 0 (packaged lib finds `rpi-fp.sh`).
- [ ] Planted: x1 and eval-tools rows → seen red → reverted.
- [ ] Commit: "Extract the boot fingerprint into rpi-fp.sh (shared with the Pi)".

---

### M3 — Pi config: root keys, no `sd-card` tag (parallel, worktree `ci/m3`)

#### Task 3.1: Root has exactly the user key  `[ ]`

**Files:** `keys.nix`, `configuration.nix`, `tests/eval/pi-config.nix`.

- [ ] RED: in `pi-config.nix` replace the rows `"every non-user root key is from= restricted"`, `"auto-update key line is from=...,restrict"` and `"an auto-update key needs hostAddress"` (spec §3.5 removes the key) with:
  - `"root has exactly the user key"` = `rootKeys == [ keys.user ]`
  - `"keys.nix has no auto-update key or host address"` = `!(keys ? autoUpdate) && !(keys ? hostAddress)`

  `chk eval-pi-config` → `FAIL: keys.nix has no auto-update key or host address`.
- [ ] GREEN: `keys.nix` = `{ user = "<unchanged>"; }` with the header comment reduced to `user`; `configuration.nix`: `users.users.root.openssh.authorizedKeys.keys = [ keys.user ];`, comments: "root: key-only; used by `rpi-deploy deploy`" (no rpi-autoupdate).
- [ ] Planted: `eval-pi-config` row (§11) → seen red → reverted.
- [ ] Commit: "Pi: drop the auto-update root key (keys.autoUpdate, hostAddress)".

#### Task 3.2: Toplevel name without the `sd-card` tag  `[ ]`

**Files:** `modules/sd-image.nix`, `tests/eval/image.nix`.

- [ ] RED: `tests/eval/image.nix` row (P9):
  - `"no sd-card tag: toplevel is nixos-system-neptun-<version>"` = `cfg.system.nixos.tags == [ ] && cfg.system.nixos.label == cfg.system.nixos.version && cfg.system.name == "neptun" && builtins.match "nixos-system-neptun-[^/]*" "nixos-system-${cfg.system.name}-${cfg.system.nixos.label}" != null`

  `chk eval-image` → that FAIL line only.
- [ ] GREEN: `modules/sd-image.nix`: `system.nixos.tags = lib.mkForce [ ];` with a comment (nixpkgs sd-image.nix adds `sd-card`; the pulled toplevel must be `nixos-system-neptun-<version>`, addendum §3.5).
- [ ] Verify `[cheap, IFD ~1–3 min]`: `ev --raw $R.system.build.toplevel.name` → `nixos-system-neptun-26.05.<date>.<rev>`; `chk eval-image && chk eval-kernel`.
- [ ] Planted: `eval-image` row → seen red → reverted.
- [ ] Commit: "Pi: toplevel name without the sd-card tag".

**M3 acceptance `[cheap]`:** `chk eval-pi-config && chk eval-image && chk eval-kernel`.

---

### M4 — `rpi-deploy`: `origin/main` downgrade check, pull status (parallel, worktree `ci/m4`)

#### Task 4.1: Downgrade check against `origin/main`  `[ ]`

**Files:** `rpi-deploy.sh`, `tests/deploy-unit.sh`.

- [ ] RED (existing d6/d7/d11/d16/d17 change because spec §3.5 moves the reference from branch `auto-update` to `origin/main`):
  - Rename helpers `set_auto_update_raw`/`set_auto_update` → `set_origin_main_raw`/`set_origin_main`: build the commit as today, then `git -C "$REPO" update-ref refs/remotes/origin/main "$c"`; once at setup `git -C "$REPO" remote add origin "$T/origin.git"` (URL need not exist: no fetch). Resetting = `update-ref refs/remotes/origin/main main`.
  - d6/d7/d11/d16/d17: same assertions with `origin/main` in place of `auto-update` in names and greps; d6 additionally `expect_grepf "d6 tells the user to git pull" "git pull" "$ERR"`.
  - New: d18 `git remote remove origin` (ref kept) → deploys, exit 0 (no origin remote ⇒ skipped); d19 origin remote present, no `refs/remotes/origin/main` → deploys; d20 a local branch `auto-update` with a newer lock and `origin/main == main` → deploys (branch no longer consulted).

  `unit deploy-unit` → first failure `FAIL: d6 origin/main locks a newer nixpkgs -> RL_E_DOWNGRADE`.
- [ ] GREEN: `check_downgrade`: `git -C "$RL_FLAKE" remote get-url origin >/dev/null 2>&1 || return 0`; ref `refs/remotes/origin/main` (`rev-parse -q --verify`, `show refs/remotes/origin/main:./flake.lock`); messages: problem text `origin/main locks a newer …`; die text `would downgrade: <problem>; run 'git pull' first, or deploy anyway with --force`; `--force` warning names `origin/main`. Usage text: "refuses when origin/main's flake.lock pins a newer nixpkgs or nixos-raspberrypi than the working tree's (git pull first) …".
- [ ] Verify: `unit deploy-unit` then `chk rpi-deploy-unit && chk rpi-deploy-syntax`.
- [ ] Planted: d6 row → seen red → reverted.
- [ ] Commit: "rpi-deploy: downgrade check against origin/main (CI commits lock updates)".

#### Task 4.2: `status` shows the pull state  `[ ]`

- [ ] RED tests (extend the `ssh` mock: `*" systemctl show -p LoadState -p Result -p ExecMainStatus -p ExecMainExitTimestamp rpi-pull.service "` → print `$MOCK_PULL_SHOW` (default `LoadState=not-found` + empty fields); `*" cat /var/lib/rpi-pull/seq /var/lib/rpi-pull/store-path "` → print `$MOCK_PULL_STATE` lines or exit 1 when empty):
  - s5 `MOCK_PULL_SHOW=$'LoadState=loaded\nResult=success\nExecMainStatus=0\nExecMainExitTimestamp=Sun 2026-10-25 05:12:03 CET'`, state `7` + `/nix/store/…-nixos-system-neptun-x` → lines `pull applied: seq 7 /nix/store/…` and `pull last run: success (exit 0) at Sun 2026-10-25 05:12:03 CET`
  - s6 loaded, no state file, empty timestamp → `pull applied: none`, `pull last run: never`
  - s7 `LoadState=not-found` → exactly one pull line `pull: disabled`
  - s8 pull query fails (mock exits 1 for systemctl) → `pull: unknown (cannot query rpi-pull on root@neptun)`, exit 0, `current:`/`reboot pending:` still printed
  - existing s1–s4, d13 unchanged (pull lines come after `reboot pending:`).

  `unit deploy-unit` → `FAIL: s5 status shows the applied pull seq`.
- [ ] GREEN: `status_pull` in `rpi-deploy.sh`, called at the end of `do_status`; parses `key=value` lines; never fails `status`.
- [ ] Planted: s5 row → seen red.
- [ ] Commit: "rpi-deploy status: show the Pi's pull state".

**M4 acceptance `[cheap]`:** `chk rpi-deploy-unit && chk rpi-deploy-syntax`.

---

### M5 — `rpi-pull` + unit tests (parallel, worktree `ci/m5`)

**Files:** `rpi-pull.sh` (new), `tests/pull-unit.sh` (new; auto-discovered as `rpi-pull-unit`). Expected size: script ≈ 170 lines; if > 200, split helpers into `rp_*` functions.

Test fixture (top of `tests/pull-unit.sh`; sources `harness.sh`; `RPI_PULL_SRC=${RPI_PULL_SRC:-$HERE/../rpi-pull.sh}`, `RPI_FP_LIB=${RPI_FP_LIB:-$HERE/../rpi-fp.sh}`):
- `RPI_PULL_ROOT=$T/pi`, `RPI_PULL_STORE=$FX_STORE`, `STATE=$T/state`, key `KEY=neptun-test.cachix.org-1:<43 chars>=`, `CACHE=https://neptun-test.cachix.org`.
- `ln -s "$BASH_BIN" "$FX_STORE/fx-bash/bin/bash"` (mkdir -p first) so the fake toplevels' `bin/switch-to-configuration` wrapper runs.
- `psys NAME [PART=TAG…]`: `h=$(printf %s "$NAME" | sha256sum | cut -c1-32)`; `make_sys "$FX_STORE/$h-nixos-system-neptun-26.05.$NAME" PART…`; write `bin/.switch-to-configuration-wrapped` that logs `stc $OUT $*` and exits `${MOCK_STC_RC:-0}`; echo the path.
- `pi CURRENT BOOTED PROFILE`: symlinks under `$T/pi/run/{current,booted}-system`, `$T/pi/nix/var/nix/profiles/system`.
- `pointer SEQ PATH [NAR]` → writes `$T/pointer.json` (jq -n). `NAR` default `$GOOD_NAR`.
- Mocks: `curl` (writes `$MOCK_BODY` file to `-o`, prints `${MOCK_HTTP:-200}` for `-w`, exits `${MOCK_CURL_RC:-0}`); `nix` (`store verify`: rc 0 iff `$MOCK_SIGNER == ours` and argv has `--trusted-public-keys $KEY`, else print `path '…' is untrusted` rc 2; `hash convert`: print `${MOCK_NAR:-$GOOD_NAR}`); `nix-store` (`--realise`: rc `${MOCK_REALISE_RC:-0}`; `--query --hash`: print `sha256:0000…`); `nix-env` (`-p P --set X` → `ln -sfn X P`); `shutdown`, `sync` (log, rc 0; `MOCK_SHUTDOWN_RC`).
- `rp ARGS…` = `bash "$RPI_PULL_SRC" --pointer-url https://x/neptun.json --cache-url "$CACHE" --cache-key "$KEY" --state-dir "$STATE" ARGS…`.
- `untouched NAME` asserts P1: profile link equals its pre-run target, `log_count '^(nix-env|stc|shutdown) '` = 0, `$STATE/seq` unchanged.

#### Task 5.1: CLI, fetch, parse, validate  `[ ]`
- [ ] RED tests:
  - p1 `--help` → 0 and usage names `--pointer-url --cache-url --cache-key`; missing `--cache-key` → 2
  - p2 `MOCK_HTTP=404` → 0, `no pointer published yet`, `log_count '^nix'` = 0
  - p3 `MOCK_CURL_RC=6` → 30; `MOCK_HTTP=500` → 30; curl argv has `--max-time 60`, `--retry 3`, `--proto-redir =https`; P1
  - p4 body `not json` → 31; P1
  - p5 seq ∈ {missing, `"5"`, `0`, `-1`, `1.5`} → 31 each
  - p6 state seq 5, pointer seq 5 → 0, `up to date`, 0 `nix store verify` lines
  - p7 state seq 5, pointer seq 4 → 31, `older than applied`; P1
  - p8 storePath ∈ {`…-nixos-system-mars-26.05`, `<valid>/../x`, `/tmp/<32>-nixos-system-neptun-1`, 31-char hash, `…-hello-1.0`, `<valid>/`} → 31 each
  - p9 narHash `sha256:abc` → 31
  - p18 a second run while `$STATE/lock` is held (`flock` in a background subshell) → 37

  Assertion names used by §11: `p7 older seq refused`. `unit pull-unit` → `rpi-pull.sh` missing.
- [ ] GREEN: argument parsing, lock, `rp_fetch`, `rp_parse` (one `jq -e` with `(.seq|type=="number" and .==floor and .>=1)`), seq rule, regex, narHash format. Until T5.2–T5.5 exist, a valid pointer stops after validation with `exit 1 "not implemented"` (no test reaches it yet).

#### Task 5.2: Signature by our key only  `[ ]`
- [ ] RED: p10 (`p10 verify uses --trusted-public-keys only`) `MOCK_SIGNER=other` → 32, stderr `untrusted`, P1; argv `store verify --no-contents --store $CACHE --trusted-public-keys $KEY <path>` and `log_count -- '--extra-trusted-public-keys'` = 0 (P4); verify line precedes any `nix-store` line.
- [ ] GREEN: `rp_verify_sig` (D6 flag).

#### Task 5.3: Already current  `[ ]`
- [ ] RED: p11 current = pointer path → 0, `already current`, `$STATE/seq` = pointer seq, `$STATE/store-path` = path, 0 `nix-store --realise`/`nix-env`/`stc` lines.
- [ ] GREEN: current check + `rp_record` (tmp + `mv`).

#### Task 5.4: Realise + narHash  `[ ]`
- [ ] RED: p12 `MOCK_REALISE_RC=1` → 33, P1; argv `--realise <path> --option max-substitution-jobs 2`. p13 (`p13 narHash mismatch -> exit 34`) `MOCK_NAR=sha256-<other>` → 34, `narHash mismatch`, P1.
- [ ] GREEN: `rp_realise`, `rp_nar_hash` (D5).

#### Task 5.5: Decision, profile, activation, state  `[ ]`
- [ ] RED:
  - p14 userspace-only change (new system = `psys next` with all default parts, booted `psys a`): `nix-env -p $T/pi/nix/var/nix/profiles/system --set <next>`, `stc <next> switch`, 0 `shutdown`, one `sync` after stc, state = (seq, path); order P2 via `first_line`
  - p15 (`p15 kernel change -> boot + shutdown -r 04:30`, one name per part) ∀ part ∈ {kernel initrd modules dtbs params fw cfg uboot}: new `psys "n-$part" "$part=2"` → `stc … boot` then `shutdown -r 04:30`, 0 `switch`; one run with `--reboot-time 03:15` → `shutdown -r 03:15`
  - p16 `ext=2` only → `switch`
  - p17 `MOCK_STC_RC=1` → 36, `sync` still logged, `$STATE/seq` unchanged; booted-system unreadable (dangling link) → 36 with 0 `nix-env` lines (D7)
  - p19 across the whole file: `log_count '^nix (eval|build)|nixos-rebuild'` = 0 (G1)
  - p20 no state dir, valid pointer seq 1 → applies, `$STATE/seq` = 1 (pins Q1 behaviour)
- [ ] GREEN: fingerprints via `rpi-fp.sh` (`RL_STORE_DIR=$RPI_PULL_STORE`), `nix-env`, stc, `shutdown`, `sync`, record.
- [ ] Planted: p7, p10, p13, p15 rows (§11) → seen red → reverted.

**M5 acceptance `[cheap]`:** `unit pull-unit` then `chk rpi-pull-unit && chk rpi-deploy-syntax`. Commit per task: "rpi-pull: …".

---

### M6 — `modules/pull-update.nix` (after M3, M5)

**Files:** `modules/pull-update.nix`, `tests/eval/pull-update.nix` (new), `keys.nix`, `configuration.nix`.

Options (exact):
```nix
options.rpi.pull = {
  enable = lib.mkOption { type = lib.types.bool;
    default = cfg.pointerUrl != null && cfg.cacheUrl != null && cfg.cachePublicKey != null;
    defaultText = lib.literalMD "`true` once `pointerUrl`, `cacheUrl` and `cachePublicKey` are set"; };
  pointerUrl     = lib.mkOption { type = lib.types.nullOr (lib.types.strMatching "https?://.+"); default = null; };
  cacheUrl       = lib.mkOption { type = lib.types.nullOr (lib.types.strMatching "https?://.+"); default = null; };
  cachePublicKey = lib.mkOption { type = lib.types.nullOr (lib.types.strMatching "[^:]+:[A-Za-z0-9+/]{43}="); default = null; };
  onCalendar     = lib.mkOption { type = lib.types.str; default = "Sun 05:00"; };
  rebootTime     = lib.mkOption { type = lib.types.strMatching "([01][0-9]|2[0-3]):[0-5][0-9]"; default = "04:30"; };
};
```
Test configs in `tests/eval/pull-update.nix` (`keys = import ../../keys.nix`, `testCache = { name = "neptun-test"; publicKey = "neptun-test.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="; }`):
- `off = rpi.extendModules { modules = [ { _module.args.rpiKeys = keys // { cache = null; }; rpi.pull.pointerUrl = lib.mkForce null; } ]; }`
- `on = rpi.extendModules { modules = [ { _module.args.rpiKeys = keys // { cache = testCache; }; rpi.pull.pointerUrl = "https://raw.githubusercontent.com/o/r/main/nixos/deploy/neptun.json"; } ]; }`
- `onHttp` = `on.extendModules { modules = [ { rpi.pull.pointerUrl = lib.mkForce "http://192.168.100.1:18080/neptun.json"; } ]; }`

(`_module.args.rpiKeys` plain: configuration.nix defines it with `mkDefault`, as `tests/eval/pi-config.nix` already relies on.)

#### Task 6.1: Options, disabled by default  `[ ]`
- [ ] RED rows:
  - `"disabled without cache key or pointer URL (no units)"` = `!off.config.rpi.pull.enable && !(off.config.systemd.services ? rpi-pull) && !(off.config.systemd.timers ? rpi-pull)`
  - `"enable follows pointerUrl, cacheUrl and cachePublicKey"` (P11 on the real `rpi`)
  - `"rebootTime accepts 00:00-23:59 only"` (as in the old build-host row)

  `chk eval-pull-update` → evaluation error (options missing) = red.
- [ ] GREEN: the options above; `config = lib.mkIf cfg.enable { assertions = [ … all three set … ]; }`.

#### Task 6.2: Units, package, substituter  `[ ]`
- [ ] RED rows (on `on` unless stated):
  - `"enabled once the cache key and the pointer URL are set"`
  - `"our cache is a substituter with its key; cache.nixos.org stays"` (`elem cacheUrl substituters ∧ elem publicKey trusted-public-keys ∧ elem "https://cache.nixos.org/" substituters`)
  - `"timer Sun 05:00, Persistent, 30m jitter, in timers.target"`
  - `"service: oneshot, idle, bounded, never restarted by a switch"` (`Type = "oneshot"`, `restartIfChanged == false`, `unitConfig.X-StopOnRemoval == false`, `Nice == 19`, `IOSchedulingClass == "idle"`, `MemoryMax == "384M"`, `TimeoutStartSec == "2h"`, `StateDirectory == "rpi-pull"`, `environment.HOME == "/root"`, `network-online.target` in after+wants)
  - `"ExecStart passes every option"` (P10, helper copied from `tests/eval/build-host.nix`: `noCtx`, `esc = rpi._module.args.utils.escapeSystemdExecArgs`)
  - `"package ships rpi-fp.sh next to rpi-pull"` = `lib.hasInfix "--set RPI_FP_LIB $out/libexec/rpi-pull/rpi-fp.sh" on.config.system.build.rpiPull.installPhase` (the module exposes its package as `system.build.rpiPull`)
  - `"http pointer URL warns"` (`lib.any (lib.hasInfix "rpi.pull.pointerUrl") onHttp.config.warnings`) and `"https pointer URL does not warn"`
- [ ] GREEN in `pull-update.nix` under `mkIf cfg.enable`: `system.build.rpiPull` = `pkgs.stdenvNoCC.mkDerivation` (`dontUnpack`, `nativeBuildInputs = [ pkgs.makeWrapper ]`, install `${../rpi-pull.sh}` → `$out/bin/rpi-pull`, `${../rpi-fp.sh}` → `$out/libexec/rpi-pull/rpi-fp.sh`, `wrapProgram … --set RPI_FP_LIB … --prefix PATH : makeBinPath [ config.nix.package pkgs.curl pkgs.jq pkgs.coreutils pkgs.util-linux config.systemd.package pkgs.gnugrep ]`); `nix.settings.substituters = [ cfg.cacheUrl ]; nix.settings.trusted-public-keys = [ cfg.cachePublicKey ];`; timer/service per D15 with `ExecStart = "${rpiPull}/bin/rpi-pull " + utils.escapeSystemdExecArgs [ "--pointer-url" cfg.pointerUrl "--cache-url" cfg.cacheUrl "--cache-key" cfg.cachePublicKey "--host" config.system.name "--reboot-time" cfg.rebootTime "--state-dir" "/var/lib/rpi-pull" ]`; `warnings = lib.optional (lib.hasPrefix "http://" cfg.pointerUrl) "rpi.pull.pointerUrl uses plain HTTP: the pointer is not authenticated (use HTTPS outside tests)"`.
- [ ] Planted: both `eval-pull-update` rows (§11) → seen red → reverted.

#### Task 6.3: `keys.cache` → `rpi.pull`  `[ ]`
- [ ] RED row: `"cacheUrl and key come from keys.nix cache"` = `on.config.rpi.pull.cacheUrl == "https://neptun-test.cachix.org" && on.config.rpi.pull.cachePublicKey == testCache.publicKey`.
- [ ] GREEN: `keys.nix` adds `cache = null;` with the comment `# Own self-signed Cachix cache (addendum §3.1, §6): cache = { name = "<cache>"; publicKey = "<cache>.cachix.org-1:…"; };`; `configuration.nix`: `rpi.pull = lib.mkIf ((keys.cache or null) != null) { cacheUrl = "https://${keys.cache.name}.cachix.org"; cachePublicKey = keys.cache.publicKey; };` (`or null`: test overrides of `rpiKeys` may lack the attribute) and a commented `# rpi.pull.pointerUrl = "https://raw.githubusercontent.com/<owner>/<repo>/main/nixos/deploy/neptun.json";`.
- [ ] Verify `[cheap]`: `chk eval-pull-update && chk eval-pi-config && chk eval-image && chk eval-kernel`; `ev --raw $R.system.build.toplevel.drvPath` unchanged versus M3's (module disabled ⇒ no closure change).
- [ ] Commit per task: "pull-update: …".

**M6 acceptance `[cheap]`:** as T6.3 verify + `nix flake check --no-build --accept-flake-config`.

---

### M7 — CI scripts, workflow, actionlint (parallel, worktree `ci/m7`)

**Files:** `ci/*.sh`, `tests/ci-unit.sh` (auto-discovered as `rpi-ci-unit`), `../.github/workflows/neptun.yml`, `flake.nix` (actionlint check only).

`tests/ci-unit.sh` fixture: harness; `CI_DIR=${CI_DIR:-$HERE/../ci}`; `RPI_LIB=$HERE/../rpi-lib.sh`; a work repo `$T/repo` (git init -b main, `nixos/flake.lock`, `nixos/keys.nix`, `nixos/deploy/`) cloned from a bare `$T/origin.git`; mocks `nix` (kernel eval, `path-info` per `MOCK_CACHE ∈ {hit, full-miss, always-miss}` where full-miss misses only after an nvmd update, `build --dry-run` → cat `$MOCK_DRY`, `build --print-out-paths` → `$MOCK_TOP` or rc `MOCK_BUILD_RC`, `flake update …` → append `$*` to `flake.lock`, `eval --impure --raw --expr …` → `${MOCK_CACHE_NAME-}`, `hash convert` → `sha256-<44>`), `nix-store` (`--query --hash`), `cachix` (log; `MOCK_PUSH_RC`, `MOCK_PIN_RC`). `TOP=/nix/store/<32×a>-nixos-system-neptun-26.05.20261021.da6dc0e`.

#### Task 7.1: `ci/build.sh`  `[ ]`
- [ ] RED: b1 `--event push` → no `flake update`; log order path-info → `build --dry-run` → `build … --print-out-paths …config.system.build.toplevel`; stdout is exactly `top=$TOP`. b2 `--event schedule` → `flake update --accept-flake-config --flake <dir> nixpkgs nixos-raspberrypi` precedes the guard. b3 schedule + `full-miss` → `git checkout -- flake.lock` effect (lock bytes = committed + one nixpkgs-only update), second update has `nixpkgs` only, then build. b4 `always-miss` → exit 10, 0 `--print-out-paths` lines. b5 kernel fixture → 11; hybrid fixture with `--max-builds 300` → 12. b6 `MOCK_BUILD_RC=1` → 13. b7 stderr contains `Filesystem` (df header). Also `--event workflow_dispatch` behaves like push.
- [ ] GREEN: `ci/build.sh` per §15.1.

#### Task 7.2: `ci/cache-name.sh`, `ci/publish.sh`  `[ ]`
- [ ] RED: c1 `MOCK_CACHE_NAME=` → exit 1, stderr names `nixos/keys.nix`; c2 `MOCK_CACHE_NAME=neptun-x` → stdout `name=neptun-x`; argv has `--impure --raw --expr`. u1 `publish.sh c $TOP` → `cachix push c $TOP` then `cachix pin c neptun $TOP --keep-revisions 4`; u2 `MOCK_PUSH_RC=1` → non-zero, 0 `cachix pin`; u3 `MOCK_PIN_RC=1` → non-zero.
- [ ] GREEN: `cache-name.sh` = `nix eval --impure --raw --expr "let k = import $DIR/keys.nix; in if (k.cache or null) == null then \"\" else k.cache.name"`, empty → error; `publish.sh` two commands.
- [ ] Manual `[cheap]` (real nix): `bash ci/cache-name.sh` → exit 1 with the keys.nix message (cache is null today).

#### Task 7.3: `ci/pointer.sh`  `[ ]`
- [ ] RED: w1 new file → valid JSON with exactly the keys `seq storePath narHash rev built`, P7, stdout `changed=true`. w2 same TOP again → bytes unchanged, `changed=false`. w3 existing seq 9 / different path, `--seq 9` or `--seq 3` → exit 1, file unchanged. w4 TOP ∈ {`/nix/store/<32>-nixos-system-mars-1`, `/tmp/x`} → exit 1. w5 narHash = mocked `hash convert` output of `nix-store --query --hash TOP`.
- [ ] GREEN: `pointer.sh` (`jq -n --argjson seq …`, tmp + `mv`, `mkdir -p "$(dirname PATH)"`).

#### Task 7.4: `ci/commit-push.sh`  `[ ]`
- [ ] RED (real git, bare origin): g1 nothing changed → `pushed=false`, origin `main` unchanged. g2 lock + pointer changed → one new commit on origin `main` touching exactly those paths, author `github-actions[bot]`, `pushed=true`; a non-existent PATH is skipped. g3 another clone pushed a non-conflicting commit first → exit 0, origin `main`'s first parent is that commit (linear: `git rev-list --merges` empty). g4 the other commit changed `nixos/flake.lock` conflictingly → non-zero, origin `main` = the other commit, work tree left clean (`git rebase --abort`). g5 `git config commit.gpgsign true` in the work repo → still commits (no gpg).
- [ ] GREEN: `commit-push.sh` per D18.

#### Task 7.5: Workflow + `actionlint` check  `[ ]`
- [ ] RED: add to `flake.nix` checks.x86_64-linux, after `rpi-host-vm`:
  ```nix
  # actionlint (+ shellcheck on run: blocks) on the CI workflow, and the
  # order invariant: the pointer is written only after push + pin.
  actionlint = x86Pkgs.runCommand "actionlint-check" {
    src = lib.fileset.toSource { root = ../.; fileset = ../.github/workflows; };
    nativeBuildInputs = [ x86Pkgs.actionlint x86Pkgs.shellcheck ];
  } ''
    cd $src
    actionlint -no-color .github/workflows/neptun.yml
    l() { grep -n -m1 -F -- "$1" .github/workflows/neptun.yml | cut -d: -f1; }
    [ "$(l ci/publish.sh)" -lt "$(l ci/pointer.sh)" ] && [ "$(l ci/pointer.sh)" -lt "$(l ci/commit-push.sh)" ] \
      || { echo "FAIL: pointer is written after push + pin"; exit 1; }
    touch $out
  '';
  ```
  With an empty `neptun.yml` (`git add -N`) → `chk actionlint` fails.
- [ ] GREEN: `.github/workflows/neptun.yml`:
  ```yaml
  name: neptun
  on:
    schedule:
      - cron: "0 1 * * 0"            # Sun 01:00 UTC: lock update + build
    push:
      branches: [main]
      paths: ["nixos/**", "!nixos/deploy/**"]
    workflow_dispatch:
  permissions:
    contents: write
  concurrency:
    group: neptun
    cancel-in-progress: false
  jobs:
    build:
      runs-on: ubuntu-24.04-arm
      timeout-minutes: 300
      defaults:
        run:
          working-directory: nixos
      steps:
        - uses: actions/checkout@v7
          with:
            fetch-depth: 0
        - uses: cachix/install-nix-action@v31
          with:
            extra_nix_config: |
              accept-flake-config = true
              extra-substituters = https://nixos-raspberrypi.cachix.org
              extra-trusted-public-keys = nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI=
        - id: cache
          run: ci/cache-name.sh >> "$GITHUB_OUTPUT"
        - uses: cachix/cachix-action@v17
          with:
            name: ${{ steps.cache.outputs.name }}
            authToken: ${{ secrets.CACHIX_AUTH_TOKEN }}
            signingKey: ${{ secrets.CACHIX_SIGNING_KEY }}
            skipPush: true
        - id: build
          run: ci/build.sh --event "$GITHUB_EVENT_NAME" >> "$GITHUB_OUTPUT"
        - name: push closure and pin
          env:
            CACHE: ${{ steps.cache.outputs.name }}
            TOP: ${{ steps.build.outputs.top }}
            CACHIX_AUTH_TOKEN: ${{ secrets.CACHIX_AUTH_TOKEN }}
            CACHIX_SIGNING_KEY: ${{ secrets.CACHIX_SIGNING_KEY }}
          run: ci/publish.sh "$CACHE" "$TOP"
        - id: pointer
          env:
            TOP: ${{ steps.build.outputs.top }}
            SEQ: ${{ github.run_number }}
          run: ci/pointer.sh --seq "$SEQ" --rev "$GITHUB_SHA" --file deploy/neptun.json "$TOP" >> "$GITHUB_OUTPUT"
        - name: commit lock and pointer
          env:
            SEQ: ${{ github.run_number }}
          run: ci/commit-push.sh --message "neptun: build $SEQ ($GITHUB_EVENT_NAME)" flake.lock deploy/neptun.json
  ```
  `git add` it and `chmod +x ci/*.sh` (git records the mode; the runner executes them directly).
- [ ] Planted: both actionlint rows (§11) → seen red → reverted.

**M7 acceptance `[cheap]`:** `unit ci-unit` then `chk rpi-ci-unit && chk actionlint && chk rpi-deploy-syntax && nix flake check --no-build --accept-flake-config`. Commit per task: "ci: …".

---

### M8 — `tests/pull-smoke.sh` (after M4, M6, M7)

#### Task 8.1: qemu pull smoke (switch path + refused tamper)  `[ ]`

**Files:** `tests/pull-smoke.sh` (new; not part of `nix flake check`). Header in the style of `deploy-smoke.sh` (purpose, steps, durations, env, exit 0/1/2).

Script (sources `qemu-pi.sh`; `WORK=${RPI_SMOKE_DIR:-$PWD/.scratch/pull-smoke}`, `PORT=${RPI_PULL_SMOKE_HTTP_PORT:-18080}`):
1. `qp_need zstd sfdisk debugfs mcopy ssh ssh-keygen nix git jq python3`; `qp_find_qemu`.
2. Keys reused across runs: ssh `$WORK/key`; `nix key generate-secret --key-name pull-smoke-1 > $WORK/cache.sec` + `convert-secret-to-public` → `cache.pub`; same for `evil` (`pull-smoke-evil-1`).
3. Scratch flake (`path:`) as in deploy-smoke with `smoke-image` = `rpi` + root key `mkForce [ key.pub ]` + `rpi.pull = { pointerUrl = "http://192.168.100.1:${PORT}/neptun.json"; cacheUrl = "http://192.168.100.1:${PORT}/cache"; cachePublicKey = "<cache.pub>"; onCalendar = "yearly"; }`; `smoke-next` / `smoke-evil` = `smoke-image` + `environment.etc."rpi-smoke-marker".text = "next\n"` / `"evil\n"`; `apps`/`packages` from `rpi`.
4. `rpi-deploy image --flake path:… --attr smoke-image --out $WORK` (guards). Build `NEXT`, `EVIL` toplevels (`--no-link --print-out-paths`); `IMG_TOP` = smoke-image toplevel outPath.
5. Cache: `rm -rf $WORK/www; mkdir -p $WORK/www/cache`; `nix copy --no-recursive --to "file://$WORK/www/cache?secret-key=$WORK/cache.sec" $(comm -13 <(nix path-info -r IMG_TOP|sort) <(nix path-info -r NEXT|sort))`; same for EVIL with `evil.sec` (D17; if nix refuses `--no-recursive`, drop it). Ensure `Priority: 10` in `www/cache/nix-cache-info`. `RPI_PULL_SMOKE_PLANT=1` signs NEXT with `evil.sec` instead.
6. `bash ci/pointer.sh --seq 1 --rev smoke --file $WORK/www/neptun.json "$NEXT"`; start `python3 -m http.server "$PORT" --bind 127.0.0.1 --directory $WORK/www` in the background (trap kills it; fail fast if the port is taken).
7. Boot: `qp_unpack`, `qp_boot $WORK/vm $FWD`, banner, login loop and settle loop copied from deploy-smoke.sh (same timeouts).
8. Switch path: `gssh timeout 1800 systemctl start rpi-pull.service` → rc 0; assert `readlink /run/current-system` = NEXT, marker = `next`, `/var/lib/rpi-pull/seq` = `1`, `readlink -f /nix/var/nix/profiles/system` = NEXT; `rpi-deploy status --target root@127.0.0.1 --port $FWD` has `pull applied: seq 1` and `reboot pending: no`. Else `FAIL: rpi-pull did not apply smoke-next`.
9. Tamper path: pointer seq 2 → EVIL; `systemctl start rpi-pull.service` → rc ≠ 0; `systemctl show -p ExecMainStatus --value rpi-pull` = `32`; current-system, profile = NEXT; seq = `1`; `nix-store -q --hash EVIL` on the guest fails (never realised). Else `FAIL: tampered pointer was not refused`.
10. `PASS (pull applied seq 1 by switch; foreign-key pointer refused with exit 32; <s>s total)`.

- [ ] Write the script; `bash -n` and `shellcheck -x -P SCRIPTDIR -S warning tests/pull-smoke.sh` clean.
- [ ] RED `[expensive ~30–50 min cold, ~15 warm]`: `RPI_PULL_SMOKE_PLANT=1 bash tests/pull-smoke.sh 2>&1 | tee .scratch/ci/pull-smoke-red.log` → `FAIL: rpi-pull did not apply smoke-next` (the guest journal shows `untrusted`).
- [ ] GREEN: `bash tests/pull-smoke.sh 2>&1 | tee .scratch/ci/pull-smoke-green.log` → `PASS`. On `EXT4-fs error`/`PIO read timeout` re-run once (§0).
- [ ] Commit: "tests: pull-smoke (qemu, signed local cache over HTTP)".

---

### M9 — Docs, final acceptance, final review (after all)

#### Task 9.1: README and HANDOFF  `[ ]`
- [ ] `README.md`:
  - Intro diagram and repo layout: `ci/`, `deploy/` (pointer, written by CI), `rpi-pull.sh`, `rpi-fp.sh`, `modules/pull-update.nix`, `.github/workflows/neptun.yml`; drop `rpi-autoupdate.sh`, the auto-update key in `keys.nix`.
  - §1 build host: no `autoUpdate`, no `rpi-autoupdate` on PATH.
  - §3: downgrade protection now against `origin/main` (`git pull` first, `--force`); `status` pull lines (§10 literals).
  - §4 rewritten "Automatic updates: CI builds, the Pi pulls": architecture; user setup (spec §6: public GitHub repo; Cachix cache created self-signed, signing key generated by the user and stored only as `CACHIX_SIGNING_KEY`; `CACHIX_AUTH_TOKEN`; `keys.nix` `cache = { name; publicKey; }`; `rpi.pull.pointerUrl`; one manual `rpi-deploy deploy switch` to enable the timer); operating (`workflow_dispatch`, `journalctl -u rpi-pull`, `systemctl start rpi-pull`, `rpi-deploy status`); semantics (manual deploys persist until the next CI build; a freshly flashed Pi applies the current pointer at its first run; a pointer older than the applied seq fails the unit; CI/Pi timing).
  - §5 recovery: after a rollback the same seq is not re-applied (persists until the next CI build).
  - §7 re-flash: drop the known_hosts/auto-update steps.
  - §10 testing: checks `rpi-pull-unit`, `rpi-ci-unit`, `actionlint`, `eval-pull-update`; `tests/pull-smoke.sh` with duration.
- [ ] `HANDOFF.md`: header (addendum spec + this plan), §1 goal, §2 status table for M1–M9 and an acceptance table for addendum §5 (filled in T9.2), §3 decisions (D1–D18 short), §4 next steps = user actions (spec §6) + AC3, §5 checklist: replace the weekly-job item with the pull checklist (§12), §6 gotchas (+ commit recipe, `GIT_CONFIG_GLOBAL`, linear history), §7 history line.
- [ ] Commit: "docs: CI builds, the Pi pulls".

#### Task 9.2: Final acceptance  `[ ]`
- [ ] AC1 `[expensive: incl. rpi-host-vm]`: `ev --raw $R.system.build.toplevel.drvPath >/dev/null && nix flake check --accept-flake-config -L 2>&1 | tee .scratch/ci/flake-check.log` → rc 0; record the check list and assertion counts.
- [ ] AC2: T8.1 green log.
- [ ] Optional regression `[expensive ~15–20 min]`: `bash tests/deploy-smoke.sh` → `PASS` (status gained pull lines, the toplevel name changed).
- [ ] `git log --merges feat/image-push-deploy ^aae02b2` is empty (linear history).
- [ ] HANDOFF acceptance table filled; commit "HANDOFF: acceptance of the CI pull addendum".

#### Task 9.3: Final whole-branch review  `[ ]`
- [ ] Review required: spawn a `review` card (Opus reviewer, `model: "anthropic/claude-opus-5-5"`) over `git diff aae02b2..HEAD` with: the addendum, this plan §3–§6 and §11, the trust model (s8 §3), and the instruction to check every Review-focus line and every Gate row.
- [ ] Each finding: fix in its own commit on `feat/image-push-deploy` (TDD: failing test first), re-run the owning check, note it in HANDOFF; findings not fixed go to HANDOFF §4 with a reason.

---

## 16. Open questions (defaults used if unanswered)

1. **Q1 Fresh flash.** A Pi without `/var/lib/rpi-pull/seq` applies the current pointer at its first timer run, even if the flashed image is newer. Default: as spec (apply), documented; p20 pins it.
2. **Q2 HTTP pointer.** The spec's pull-smoke serves the pointer over HTTP, so the option accepts `http://` with an eval warning (D9). Alternative: https-only and TLS in the smoke test. Default: D9.
3. **Q3 CI fallback.** Keep the removed job's nixpkgs-only fallback when nvmd's kernel is not cached (D10)? Default: yes.
4. **Q4 Older seq.** `seq < last` fails the unit (exit 31); `seq == last` and HTTP 404 are silent no-ops (D8). Default: as stated.
5. **Q5 narHash method.** `nix-store --query --hash` + `nix hash convert` instead of `nix path-info --json` (D5). Default: yes.
6. **Q6 Decision order.** Fingerprint decision before `nix-env --set` (D7, deviates from spec step order). Default: yes.
7. **Q7 Downgrade check fetch.** Compare against the local `origin/main` ref without fetching (D14). Default: no fetch.
8. **Q8 `rev` field.** = `GITHUB_SHA` (commit the build started from), not the lock commit (D13). Default: yes.
9. **Q9 Cache name source.** Read from `keys.nix` by `ci/cache-name.sh` (D12). Default: yes.
10. **Q10 Service limits.** `MemoryMax=384M`, `TimeoutStartSec=2h`, idle CPU/IO (D15). Default: yes.
11. **Q11 Action pins.** Tags `@v7`/`@v31`/`@v17` (checkout v7 per s8) rather than commit SHAs (nvmd pins SHAs). Default: tags.
12. **Q12 Timing.** CI Sun 01:00 UTC vs Pi Sun 05:00 local + ≤ 30 min: a CI run over ~3 h is applied a week later. Acceptable? Default: yes (documented).
13. **Q13 Spec file state.** The addendum has uncommitted edits in the working tree (§3.5 downgrade wording); this plan follows the working-tree text. The orchestrator should commit the spec.
