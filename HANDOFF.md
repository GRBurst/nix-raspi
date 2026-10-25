# HANDOFF — nix-raspi: a reusable library for the Raspberry Pi 3 (mkPi, template, rpi-deploy, rpi-ci)

> **Maintain this file.** Update it at the end of every work step: status,
> decisions, open problems, what was verified vs. assumed. A new session should
> be able to start from this file alone.
> Last updated: M7 docs (README consumer first, this file, `personal-values`
> check, generic `rpi-check`). The final acceptance (plan T7.4) and the final
> whole-branch review (T7.5) follow. Full docs: `README.md`.
> Spec: `docs/superpowers/specs/2026-10-25-reusable-library-design.md`; plan:
> `docs/superpowers/plans/2026-10-25-reusable-library.md` (§3 decisions D1–D25,
> §9 planted violations, §12 refactor invariant, §15 interfaces).
> It builds on `2026-10-19-image-push-deploy-design.md` and the addendum
> `2026-10-23-ci-pull-updates-design.md` (same directory) and their plans
> `docs/superpowers/plans/2026-10-19-image-push-deploy.md` and
> `docs/superpowers/plans/2026-10-23-ci-pull-updates.md` (§17 amendments A1–A13
> are binding where the library spec is silent).

Legend: **[V]** verified by running it · **[M]** verified against mocks / unit
tests / eval only · **[?]** assumption, not verified (needs the real Pi, GitHub or Cachix).

---

## 1. Goal

The repository is a library flake that others use to run their own Raspberry
Pi 3: `lib.mkPi { modules; }` hides nvmd's `nixos-raspberrypi`, the hybrid
inputs, home-manager and the SD image; every Pi-specific value is an `rpi.*`
option or an `mkDefault`; `nix flake init -t github:GRBurst/nix-raspi` gives a
working host; CI is a host matrix (`rpi-ci hosts|build|publish|pointer|commit`)
that stays green without a cache. Our own Pi, **neptun** (`hosts/neptun`, one
host module on `lib.mkPi`), keeps its system derivation unchanged (checked by
the refactor invariant, §2). The flake lives at the repository root (it moved
from `nixos/`); the pointer is `deploy/neptun.json`.

The hard constraints of the earlier plans stand: the kernel is never built
locally (nvmd's cachix), the Pi never evaluates the flake (1.1 GB RAM vs ~870 MiB usable),
any failure leaves the Pi untouched, PSKs never enter the store, the signing key
and the auth token exist only as GitHub Actions secrets.

## 2. Status

### The reusable library (plan M0–M7)

Linear, unsigned commits on `main`, one per task (`git log --oneline 4577aa2..main`;
re-sign when pushing; no merge commits). Plan checkboxes were not ticked.

| milestone | content | commits | state |
|---|---|---|---|
| M0 | flake moved from `nixos/` to the root (`G mv`), pointer `deploy/neptun.json`, baseline B0 (`.scratch/lib/baseline`) | `cfa4089` | done, **[V]** I1 drvPath identical to B0 |
| M1 | scaffold: `tests/drv-diff.sh`, `rl_hosts`/`rl_host_info` in `rpi-lib.sh`, `rpi-ci` package and dispatcher, `tests/workflows-lint.sh` (actionlint check body) | `64c3625`, `34b9a11`, `ad96266`, `e1dad78` | done, **[M]** |
| M2 | `lib.mkPi`, `nixosModules.default`/`terminal`, modules `base identity network wifi bluetooth profiles/terminal`, `rpi.pull.{repo,branch,cache}`, `hosts/neptun` (keys.nix and configuration.nix retired) | `40018b5` … `95277b0` (7) | done; **[V]** I1 == B0 after every task, I2 differs only by the expected leaf; 16 `eval-*` checks **[M]** |
| M3 | `rpi-deploy`: `--host`/`RPI_HOST`, target and port from `rpi.deploy.target`/`rpi.ssh.port`, `secrets`, `flash --wifi-env` | `252ac34`, `0d43b33`, `c02d6b0`, `5a4f133` | done, **[M]** 536 assertions |
| M4 | CI: `ci/gh.sh` (annotations, summaries), `rpi-ci build/publish/pointer/commit`, `.github/workflows/pi.yml` (ours and the template's), `cache-name.sh` and cachix-action removed | `003e555` … `b9090c4` (7) | done, **[M]** 403 assertions + actionlint; a real `rpi-ci build --host neptun` with `GITHUB_ACTIONS=true` and a scratch cache **[V]** (binfmt, 273 s); a real GitHub run **[?]** |
| M5 | `templates/default` (flake, `hosts/rpi.nix`, devenv files, README), `secretspec.toml`, `devenv.local.nix.example` | `68d5770`, `17de115` | done, **[M]** `eval-template` (15 rows); spikes S2/S3 **[V]** with `git+file://` of this repo |
| M6 | qemu smokes: boot-smoke on the template's default host, deploy-smoke and pull-smoke on neptun | integrated by the orchestrator | see the acceptance table (T7.4) |
| M7 | `personal-values` check, README consumer first, this file, generic `rpi-check` | `40fb9cf`, `7c92847`, the HANDOFF commit | docs done; T7.4 acceptance and T7.5 review are the orchestrator's |

### Acceptance of the library (spec §9)

Filled by T7.4; what was known when M7 was written:

| # | criterion | result | evidence |
|---|---|---|---|
| 1 | `nix flake check`; no personal value in library code | `personal-values` **[V]** green; the full `nix flake check` is T7.4 | `.scratch/lib/logs/m7-*` |
| 2 | a template instance evaluates and builds its image; default DHCP, port 22, radios off | evaluation **[M]** (`eval-template`) and spikes S2/S3 **[V]**; image and boot: boot-smoke (M6, T7.4) | `.scratch/lib/logs/s2-s3.md` |
| 3 | neptun derivation diff equals the expected list | **[V]** per task (I1 empty, I2 one leaf); the final run is T7.4. **M7 edited `rpi-pull.sh`** (`--host` is required now), which changes the expected I2 list, see below | `.scratch/lib/logs/m7-invariant.txt` |
| 4 | CI green on `main` without a cache, summary per host, notice about the skipped publish | **open, manual**: the user pushes (§4) | |
| 5 | boot-smoke (template default host), deploy-smoke, pull-smoke | M6 / T7.4 | |
| 6 | README follows spec §8 | written in that order (M7); human review in T7.5 | |

**Expected differences of the refactor invariant** (`.scratch/lib/expect/`):
I1 (neptun as committed, pull off): none. I2 (with a test cache, pull on) until
M7: `unit-rpi-pull.service\tenv:text` (the pointer URL). M7 changed `rpi-pull.sh`
(the `--host` default `neptun` is gone), so the `rpi-pull` package is now the
root cause and the unit is no longer a leaf: the I2 list for the M7 tree and
later is exactly `rpi-pull\tenv:installPhase` and `rpi-pull\tinputSrcs`
(`.scratch/lib/expect/I2.m7.txt`; I1 does not contain `rpi-pull`; the old
`I2.txt` reports `MISSING: unit-rpi-pull.service` against the M7 tree). The
pointer URL change of the unit is then checked by a diff of its text with store
hashes normalised (`.scratch/lib/logs/m7-unit-text-diff.txt`: only
`nixos/deploy/neptun.json` → `deploy/neptun.json`).

### Notes from the milestones (deviations that matter)

- **neptun leaves `rpi.pull.cache` unset** (default `null`) instead of
  `cache = null`: a `nullOr submodule` rejects a null next to a non-null
  definition, and the invariant's I2 sets the cache with `extendModules`.
- `rpi.ssh.port` is `ints.between 1 65535`; the image is named
  `<hostname>-rpi3` (was hard-coded `neptun-rpi3`; unchanged for neptun).
- `rpi-deploy secrets` creates the directory with `mkdir -p -m 700` (not
  `install -d`, which would chmod an existing directory); `RPI_PART_WAIT` is a
  test hook for `flash --wifi-env`.
- **download-artifact v8 extracts a lone artifact straight into `path`**, so
  with one host `rpi-ci commit --artifacts DIR` treats a DIR that holds
  `flake.lock` or `deploy/` as the only artifact (tests k7, k7b). The commit job
  downloads to `${{ runner.temp }}/artifacts`.
- **eval-tools quirk (M1, `tests/eval/tools.nix`):** the first
  `nix flake check --no-build` after changes in `ci/` can fail with
  `path '…-source' is not valid` (`builtins.pathExists` on a fileset source that
  is not in the store yet); it passes after `chk eval-tools`. A fix would test
  membership through `lib.fileset`.
- `nix flake init -t` needs `--accept-flake-config` inside the agent sandbox only
  (unreadable trusted-settings); devenv in nixpkgs is 2.1.2 (the plan said 2.4).
- M7: `rpi-lib.sh` defaults are the options' defaults (`rpi`, `root@rpi`, 22);
  `rpi-pull --host` has no default (the module always passes `config.system.name`);
  `personal-values` also allows `github.com/GRBurst/nix-raspi` (the template's
  README links the library); tests, README, HANDOFF and `hosts/` are excluded by
  design. Tests that name neptun on purpose (fixtures and neptun's own values):
  `tests/ci-unit.sh` and `tests/pull-unit.sh` (fixture host and store paths),
  `tests/deploy-unit.sh` (store paths, `--attr neptun`), `tests/lib-unit.sh`,
  `tests/eval/{pi-config,pull-update,image,lib}.nix`, the smoke tests (M6).

### Earlier work (before the library)

The image/push-deploy plan (M1–M7, accepted 2026-10-23) and the CI pull addendum
(M1–M9, finished 2026-10-24) are on `feat/image-push-deploy` and part of `main`.
Paths and names in this block are as they were then (`nixos/`, `keys.nix`,
`configuration.nix`, `neptun.yml`, `cache-name.sh`, the nixosConfiguration `rpi`);
untracked evidence lives under `.scratch/` (earlier `nixos/.scratch/`).

Image/push-deploy milestones M1–M7 (first plan) are done and were accepted on
2026-10-23. The addendum plan (CI pull) is implemented on
`feat/image-push-deploy` as linear, unsigned commits on top of `aae02b2`
(`git log --oneline aae02b2..HEAD`; re-sign when merging; no merge commits:
`git log --merges feat/image-push-deploy ^aae02b2` is empty).

| milestone | content | commits | state |
|---|---|---|---|
| M1 | host auto-update removed (`rpi.buildHost.autoUpdate`, `rpi-autoupdate`, `autoupdate-unit`); auto-discovered unit and shellcheck checks; stub pull module | `7041a97`, `84ac845` | done, **[M]** |
| M2 | boot fingerprint extracted into `rpi-fp.sh` (shared by host and Pi) | `14d718a` | done, **[M]** (`rpi-deploy-unit` parity) |
| M3 | root key = user key only; toplevel without the `sd-card` tag (`nixos-system-neptun-<version>`) | `b8864ef`, `5ab4848` | done, **[M]** eval checks |
| M4 | `rpi-deploy`: downgrade check against local `origin/main`; `status` shows the pull state | `1f89aaa`, `33de829` | done, **[M]**; `status` pull lines **[V]** in pull-smoke |
| M5 | `rpi-pull.sh`: fetch, validate, ours-only signature, realise + narHash, boot fingerprint decision, state, `last-run`, staleness (exit 39) | `24a9016` … `a6375f9` (7) | done, **[M]** 525 assertions; switch path and refusal **[V]** in pull-smoke; boot + reboot path **[M]** only |
| M6 | `modules/pull-update.nix` (`rpi.pull.*`), `keys.cache` → substituter and key, production pointer URL | `64f7ac3`, `d34fea6`, `79f0268` | done, **[M]** 23 assertions; unit **[V]** in pull-smoke |
| M7 | `ci/{build,cache-name,publish,pointer,commit-push}.sh`, `.github/workflows/neptun.yml`, `actionlint` check | `5596d42` … `a3e68cc` (5) | done, **[M]** 159 assertions + actionlint; a real GitHub run **[?]** |
| M8 | `tests/pull-smoke.sh` (qemu, signed local cache over HTTP) + a bug it found (`f9dc426`) | `3b84a3d`, `f9dc426` | done, **[V]** |
| M9 | README and HANDOFF; final acceptance | `8fa8299` (docs), the acceptance commit after it | docs and acceptance done (below) |
| T9.3 | final whole-branch review (`nixos/.scratch/ci/final-review.md`) and its fixes | `00eaea7` … `b4a4b47` (13), this HANDOFF commit | done except S2 (user decision), see below |

#### Final whole-branch review (plan T9.3): findings

One commit per finding, test first where a test is possible (each test of a
code fix was red before the fix; the N7 tests pin existing behaviour). Re-checked after the fixes, on `b4a4b47` (only this
HANDOFF commit follows): `nix eval` of the toplevel `drvPath` rc 0 (8 s);
`nix flake check --no-build` rc 0 (34 s); full `nix flake check` rc 0 (56 s:
the four unit/syntax checks rebuilt, every other check was the identical,
already passed derivation); `rpi-pull-unit` 608, `rpi-ci-unit` 162,
`rpi-deploy-unit` 314 assertions, `eval-pull-update` 25; the aarch64-linux unit
checks (what CI now runs) built under binfmt: rc 0, 309 s, same counts;
`nixos/.scratch/ci/final-fix/aarch64.log`. Logs: `nixos/.scratch/ci/final-fix/`
(untracked), report `nixos/.scratch/ci/final-fix-report.md`.

| finding | fix | commit |
|---|---|---|
| **S1** CA toplevel passes "our key only" (nix accepts a CA path without a signature) | before the realise `rpi-pull` reads the narinfo (`nix path-info --json --store <cache>`): content-addressed or no signature by our key name → 32, `nix store verify` with our key only → 32, narinfo narHash ≠ pointer → 34, not in the cache → 38; after the realise the local path must be input-addressed (32) and its narHash equal (34). Unit tests with mock narinfo (`ca` set: unsigned, signed by another key, by ours), real-nix check against `fr-ca` (`.scratch/ci/s1-real/results.txt`). `--help`, README, A6/A12, plan G4 | `00eaea7` |
| **S2** reboot about 23 h after the run (`rebootTime` 04:30 vs. the 05:00 run) | user chose 06:30: default `rebootTime` (module and `rpi-pull`) is now 06:30, so a boot-affecting update reboots the same morning; `eval-pull-update` and `pull-unit` p15 assert it | `2100956` |
| **S3** 404 after an applied seq exits 0 | 404 with an applied seq → exit 30 `pointer disappeared`; before any apply still 0 | `2251768` |
| **S4** actions pinned by tag; secrets handed to cachix-action | full commit SHAs with the tag as comment (resolved over HTTPS: `git ls-remote`, GitHub API); cachix-action gets no token or signing key (`skipPush`, public cache: it only runs `cachix use`); `.github/dependabot.yml` (github-actions, weekly); `actionlint` check asserts all three | `ff93e29` |
| **S5** CI publishes without running any check | step `unit tests` between build and push: `nix build .#checks.aarch64-linux.rpi-{deploy-syntax,pull-unit,ci-unit,deploy-unit}` (unit checks are now defined for both systems; sandboxed with the pinned tools, as on the host, no apt on the runner); `actionlint` check asserts build < checks < publish | `01bc0f1` |
| **N1** `time-sync.target` was a no-op | `systemd-time-wait-sync.service` installed (not enabled), `rpi-pull` wants and orders after it, `TimeoutStartSec=30min`: only rpi-pull waits for NTP, boot does not (qemu VM test `.scratch/ci/n1-vm.nix`, untracked) | `0ce554a` |
| **N2** unusable state dir exits 37 | exit 1 `state dir not writable` | `579b48b` |
| **N3** manual deploy and the pull share no lock | documented (README "Pull: CI builds, the Pi pulls", §4 below); `flock` in `rpi-deploy` deferred | `1e9f78e` |
| **N4** downgrade check freshness | documented below (intended, D14) | `5db1c22` |
| **N5** `status` age is the apply time | documented (README "Push from the build host", below) | `2a15f11` |
| **N6** publish not main-guarded | job-level `if: github.ref == 'refs/heads/main'`, asserted by the `actionlint` check | `a4f6a06` |
| **N7** pin overclaim; run_number reset; bad `$STATE/seq` | README wording (pin exempts the toplevels; closure protection unverified) and the two recoveries (README "Recovery and rollback"), pinned by ci-unit w11 and pull-unit p7 | `066c4d4` |
| **N8** `built` only refreshes with a new toplevel | documented (README "Pull: CI builds, the Pi pulls" step 7, below) | `cd171e7` |
| **N9** dependency trust (A12 residual risk) | documented (README Trust box, below) | `b4a4b47` |

#### Acceptance of the CI pull addendum (addendum §5)

Run on 2026-10-24 (andromeda), on commit `3b84a3d` (code-complete tree; the later
commits only touch `README.md` and `HANDOFF.md`): the flake check in the clean
main tree, deploy-smoke in a clean detached worktree of that commit. Logs:
`nixos/.scratch/ci/` (untracked), summary in `nixos/.scratch/ci/m9-report.md`.

| # | criterion | result | evidence |
|---|---|---|---|
| 1 | `nix flake check` passes (incl. actionlint, unit tests, eval tests) | **[V] pass**, rc 0, 131 s, every check built fresh. The toplevel `drvPath` evaluated first (rc 0). 15 x86_64 checks: `rpi-deploy-syntax`, `actionlint`, `rpi-host-vm` (VM test script 28.6 s), `rpi-deploy-unit` 314 assertions, `rpi-pull-unit` 525, `rpi-ci-unit` 159, and 9 × `eval-*` with 103 assertions (build-host 6, external-storage 14, headless 8, image 9, kernel 5, pi-config 18, pull-update 23, sd-wear 14, tools 6). aarch64-linux checks are omitted by nix as an incompatible system. | `flake-check.log`, `ac1-drvpath.txt`, `ac1-commit.txt` |
| 2 | `tests/pull-smoke.sh`: switch path and refused tamper | **[V] pass**, 1656 s total (image rebuilt ~12 min, boot and settle ~9 min, pull ~5 min, tamper ~1 min): `PASS (pull applied seq 1 by switch; foreign-key pointer refused with exit 32; …)`, with the unit-changing delta (`SMOKE=next`) switched without restarting the running unit, `pull applied: seq 1` and `reboot pending: no` in `status`, seq 2 to a foreign-key system refused (exit 32, `pull last run: untrusted (exit 32)`, the system never realised). Planted violation (`RPI_PULL_SMOKE_PLANT=1`: smoke-next signed with the foreign key) → `FAIL: rpi-pull did not apply smoke-next` (guest journal `untrusted`, ExecMainStatus 32). The first GREEN run failed with exit 36 (the `bash` PATH bug, `f9dc426`, §2). | `pull-smoke-green.log`, `pull-smoke-red.log`, `pull-smoke-red-guest.log`, `m8-report.md` |
| 3 | after user setup: `workflow_dispatch` pushes, pins, commits the pointer; the Pi applies it | **open, manual**: §4 and §5 | |
| — | regression: `tests/deploy-smoke.sh` (optional) | **[V] pass on the re-run**, 841 s (image rebuilt for the new toplevel name; deploy 147 s): `PASS (deploy switch applied smoke-next: marker 'next', new system running, no reboot pending; rollback restored the image system)`. `status` ends with `pull: disabled` (the smoke image has no cache key). The **first run failed** at 375 s of the deploy: `Failed to start local-fs.target` during the switch, and the guest serial log ends with `sdhost-bcm2835 3f202000.mmc: fsm 1, hsts 00000101`, the qemu SD flake (no `EXT4-fs error` line; the script's note did not match this variant). One re-run on an idle host passed, as the plan prescribes. | `deploy-smoke-run2.log`, `deploy-smoke-run1-fail.log`, `deploy-smoke-run1-serial.log`, `deploy-smoke-run1-switch.log` |
| — | linear history: `git log --merges feat/image-push-deploy ^aae02b2` | **[V] pass**: prints nothing; `git rev-list --min-parents=2 --count aae02b2..feat/image-push-deploy` = 0 (28 commits at the time of the check) | |

Findings during the CI pull work (the full list is in `nixos/.scratch/ci/`):

- **rpi-fp ran `bash` from PATH (fixed in `f9dc426`).** The `rpi-pull` unit's PATH
  has no `bash`, so `rl_fp_local` failed there with `rpi-fp.sh: line 86: bash:
  command not found` and the run exited 36. Unit tests missed it (their PATH has
  bash); pull-smoke's first GREEN run found it. The fingerprint now runs with the
  running bash (`${BASH:-bash}`), pinned by `rpi-deploy-unit` fp1b (a PATH with only `readlink`).
- Every evaluation of `rpi` warns `rpi.pull stays disabled: rpi.pull.cacheUrl,
  rpi.pull.cachePublicKey not set …` until `keys.nix` has `cache`. Intended: a
  partial setup must not stay silently off.
- qemu's sdhost model reads synchronously: a stalled host shows up as `PIO read
  timeout` / `EXT4-fs error` in the guest. Re-run a smoke test once on an idle
  host before debugging.
- After the first boot every ssh connection crawls under TCG for ~5 min (store
  registration, resize); the smoke tests wait for `is-system-running`. `degraded`
  with only `session-1.scope` failed is the script's own killed login attempt.

#### Previous acceptance (image-push-deploy spec §8, M7 of the first plan, 2026-10-23)

Evidence in `nixos/.scratch/m7/` (untracked). Still valid except where noted.

| # | criterion | result |
|---|---|---|
| 1 | `nix flake check` | passed then; superseded by the table above |
| 2 | `rpi-deploy image` without a kernel compile; boots with SSH | **[V]** cold image build 2011 s (379 local builds, 0 kernel builds), 1.28 GiB zst; boot-smoke: SSH banner on the usb-net forward |
| 3 | closure ≤ 3.3 GiB | **[V]** 3,376,732,952 B = 3.144 GiB (limit 3.3 GiB), 1006 paths, no `linux-firmware` (re-measure if the pull module changed it: it adds `rpi-pull` and its small deps) |
| 4 | `rpi-deploy deploy switch` applies a change in qemu | **[V]** deploy-smoke, 908 s with the image cached (deploy phases 276 s); rollback with `nixos-rebuild switch --rollback --target-host` restores the image's system |
| 5 | `rpi-autoupdate --no-deploy` | **retired**: the host auto-update was removed by the addendum |
| 6 | real hardware | **open, manual**: §5 |


## 3. Decisions (short; the full tables are plan §3 and §17 of each plan)

### The library (plan §3 D1–D25)

- **D1** The root move came first, in one commit (`G mv nixos/<entry> <entry>`, all path fixups, pointer `deploy/neptun.json`); untracked `nixos/` leftovers (`.scratch`, `.cache-nix`, `.nixcache`, `result`) stayed.
- **D2** Refactor invariant = root-cause ("leaf") diff of `nix derivation show -r` JSON (`tests/drv-diff.sh`) against baseline B0; two probes: I1 = neptun as committed (pull off), I2 = neptun with a test cache (pull on).
- **D3** The library modules were built against a fixture host through `self.lib.mkPi` while neptun stayed on the old module list; neptun switched in one task (T2.7), so no list option merged twice.
- **D4** `modules/base.nix` holds the kept `mkDefault`s (+ `daemonIOSchedPriority = 7`, `i18n.defaultLocale`, `networking.useNetworkd`, `security.sudo.enable`); `modules/default.nix` is an import list.
- **D5** `nixosModules.default` = the `rpi.*` modules without the terminal profile; `nixosModules.terminal` = the profile (it defines `home-manager.*`); `mkPi` imports both and home-manager.
- **D6** `mkPi` module order: nvmd `raspberry-pi-3.base`, `default`, `terminal`, the user's `modules`, the home-manager module and its block; `modules/default.nix` imports `sd-image sd-wear headless external-storage pull-update base identity network wifi bluetooth` in this order (list options merge like before).
- **D7** `specialArgs = { inherit inputs; } // specialArgs`; library modules never read `inputs`.
- **D8** Static network keeps `systemd.network.networks."10-lan-static"`; DHCP mode defines no network (NixOS's default DHCP network applies).
- **D9** Wi-Fi: `pskRaw = "ext:<VAR>"`, `secretsFile` is a string (never a store path), firmware `hardware.firmware = mkOverride 49 [ … ]` (beats sd-wear's `mkForce [ ]`); Bluetooth likewise.
- **D10** Host discovery and host info are two nix expressions in `rpi-lib.sh` (`RL_HOSTS_EXPR`, `RL_HOST_INFO_EXPR`) shared by `rpi-deploy` and `rpi-ci`; `nixosConfigurations.rpi` is `neptun // { rpiHost = false; }` (deprecated alias, one release).
- **D11** Pointer file, pin name and `rpi-ci pointer --host` key on `config.system.name` (the hostname), not the attribute name.
- **D12** `rpi-ci` = `ci/rpi-ci.sh` dispatcher over the scripts; every CI script defaults `--flake` to `$PWD`; package layout `$out/libexec/rpi-ci/{ci/*.sh,rpi-lib.sh,rpi-fp.sh}`.
- **D13** CI substitutes from the host's cache through `--option extra-substituters/extra-trusted-public-keys` in `rpi-ci build` (needs a trusted runner user: install-nix-action's default); `cachix-action` dropped. Risk R3, verified only locally.
- **D14** Each matrix job updates the lock itself; `rpi-ci commit --artifacts DIR` requires all locks byte-identical, else `::error::` and no commit; the commit job runs only when every build succeeded. All jobs build the hosts job's `rev`; `rpi-ci commit --base REV` refuses when main's lock differs from REV's (final review S1).
- **D15** Build jobs `permissions: contents: read`; only the commit job writes.
- **D16** `rpi-ci build` also builds every `checks.<system>` of the flake after the toplevel (none: a notice).
- **D17** `ci/gh.sh`: notices, warnings, errors, groups and summaries only under `GITHUB_ACTIONS=true` (plain `rpi-ci: <level>: …` on stderr otherwise); messages are escaped.
- **D18** The pointer gains `bootFp` (sha256 of the boot fingerprint); the summary says switch, reboot or unknown; `rpi-pull` ignores unknown fields.
- **D19** Ours `.github/workflows/pi.yml` = the template's with `.#rpi-ci` for `--inputs-from . rpi#rpi-ci`; asserted textually (`actionlint` check). Build and commit jobs build `rpi-ci` once from the committed lock (`--out-link "$RUNNER_TEMP/rpi-ci"`) before the lock update; the weekly update never moves `rpi` (`update-library` does; final review S3).
- **D20** Push trigger `paths-ignore: ["deploy/**", "docs/**", "**.md"]`.
- **D21** PSKs reach `rpi-deploy` as env variables; the content goes over stdin (`ssh … install -m 600 /dev/stdin`, `sudo install … /dev/stdin`), never a temp file or argv. The module's tmpfiles rule hands the file to the `wpa_supplicant` user (final review B1).
- **D22** Template: `hosts/rpi.nix`, `nixosConfigurations.rpi`, input named `rpi`, re-exports `apps` and `packages`, copies our `nixConfig`, minimal devenv files.
- **D23** `personal-values` scans the library paths (`lib/ modules/ templates/ ci/ .github/ rpi-*.sh devenv.nix devenv.yaml secretspec.toml devenv.local.nix.example`) and `flake.nix` minus the lines wiring neptun in; the library URL is allowed.
- **D24** The `actionlint` check body lives in `tests/workflows-lint.sh`.
- **D25** `eval-template` evaluates the real `templates/default/flake.nix` with our flake as its `rpi` input.

### Earlier decisions (image/push flow, CI pull; still valid unless noted)

(Superseded by the library: D12 below (the cache name read from `keys.nix` by `ci/cache-name.sh`) became `rpi.pull.cache` read per host by `rpi-ci` (library D13); the workflow `neptun.yml` became `pi.yml`; the `ci/*.sh` scripts are `rpi-ci` commands.)

Image/push flow (first plan):

- **Image flow, not `nixos-install`.** The image is a build output of `rpi` itself
  (`modules/sd-image.nix`), flashed with `dd`; later changes arrive with
  `nixos-rebuild --target-host` (native activation on the Pi) or by pull.
- **Hybrid inputs.** `nixos-raspberrypi` (`develop`, own nixpkgs pin) gives the
  cached kernel/firmware; our `nixpkgs` (`nixos-26.05`) drives userspace. No
  `follows` between them (`eval-kernel`). Guards: kernel and modules in nvmd's
  cachix, no kernel/linux-config/gcc/llvm/rustc/ghc/nodejs build, ≤ 500 local builds.
- **Pinned deploy tool.** The flake exposes nixos-rebuild-ng 26.05; the host's
  newer one half-applies (`systemd-run --output=cat`, E3). Always `--no-reexec`.
- **Access.** `PermitRootLogin = prohibit-password`; root has the user key only
  (the restricted auto-update key is gone); `pi` has no password and
  `wheelNeedsPassword = false` (flagged for review).
- **`flash` accepts `mmcblkN` with `RM=0`**; root-disk, mounted, partition and
  typed-confirmation checks still apply (`flash_check_device`).
- **Rejected**: cross-compilation, nixos-anywhere, systemd-repart, on-Pi evaluation
  (autoUpgrade, comin: eval RAM), deploy-rs, cachix-deploy, nvmd `main`, trimming
  nix-terminal, f2fs/btrfs root, `discard`, `auto-optimise-store`, `fsync-metadata=false`.

CI pull addendum (plan §3 D1–D18; amendments A1–A13):

- **D1** `rpi-fp.sh` (pure bash) holds the fingerprint; `rpi-lib.sh` sources it, the Pi package ships it with `rpi-pull` only.
- **D2** unit checks `tests/<n>-unit.sh` → `rpi-<n>-unit` and shellcheck of every `*.sh` outside `tests/` are auto-discovered.
- **D3** M1 created the stub module so M6 touched only its own file.
- **D4** one shared unit-check environment (`git zstd gnugrep gnused gawk jq findutils util-linux coreutils`).
- **D5** narHash = `nix-store --query --hash` → `nix hash convert --to sri` (not `path-info --json`).
- **D6** every new-CLI `nix` call on the Pi passes `--extra-experimental-features nix-command`.
- **D7** switch-vs-boot is decided **before** `nix-env --set` (a fingerprint failure leaves the profile untouched; deviates from spec order).
- **D8** pointer 404 → exit 0 `no pointer published yet` (only while no seq was applied; afterwards exit 30 `pointer disappeared`, final review S3); seq equal → `up to date`; seq older → exit 31.
- **D9** `pointerUrl`/`cacheUrl` accept `https?://`; `http://` warns (qemu smoke only); curl `--proto-redir =https`.
- **D10** CI keeps the nixpkgs-only fallback on a kernel cache miss.
- **D11** CI scripts print `key=value` on stdout for `$GITHUB_OUTPUT`, logs on stderr.
- **D12** the cache name is read from `keys.nix` by `ci/cache-name.sh` (one source).
- **D13/A4** pointer `rev` = `git rev-parse HEAD` of the build; checkout `ref: main` for all triggers; `pointer.sh` also compares seq with `origin/main`'s pointer.
- **D14** `rpi-deploy`'s downgrade check reads the local `refs/remotes/origin/main`, never fetches.
- **D15** service: `restartIfChanged=false`, `X-StopOnRemoval=false`, `MemoryMax=384M`, idle CPU/IO, `TimeoutStartSec=2h`; timer `Persistent=true`, `RandomizedDelaySec=30m`.
- **D16** `system.nixos.tags = lib.mkForce [ ]`.
- **D17** pull-smoke serves its cache and pointer with busybox httpd (A1: python3 is not on PATH), full-closure `nix copy`.
- **D18** CI commits as `github-actions[bot]`, unsigned, rebase once and retry; never force.
- **A2** seq must match `^[1-9][0-9]{0,9}$`; a non-numeric `$STATE/seq` is an error (31).
- **A3** pointer and commit steps run only on `refs/heads/main`; `commit-push.sh` refuses otherwise.
- **A5/A6** staleness alarm: `--max-age-days` (default 21, option `rpi.pull.maxAgeDays`) → exit 39; `$STATE/last-run` on every exit once the lock is held; service after `network-online.target`, `time-sync.target` and `systemd-time-wait-sync.service` (installed, not enabled: only rpi-pull waits for NTP, at most 30 min; final review N1); timer **daily 05:00**; `nix store verify` rc 2 → 32, other → 38 (since the final review S1 the narinfo is read first: content-addressed or not signed by our key → 32, narHash ≠ pointer → 34, not in the cache → 38).
- **A7** store-path regex `^STORE/[0-9a-df-np-sv-z]{32}-nixos-system-HOST-…`, `--host` `^[A-Za-z0-9_-]+$`, control characters rejected, `curl --max-filesize 65536`; `built` must be `YYYY-MM-DDTHH:MM:SSZ`.
- **A12** trust: the verify is ours-only; the load-bearing binding is the pointer's narHash compared after the realise; dependencies rely on `require-sigs` and the three trusted keys. Final review S1: nix accepts a content-addressed path without any signature, so before the realise the toplevel's narinfo must be input-addressed, name a signature by our key and carry the pointer's narHash, and after it the local path must be input-addressed too.


## 4. What to do next (user)

The agent cannot do these (spec §10; the library plan's §10 coverage gaps):

1. **Push and watch the first CI run** (agents never push). The checklist for
   acceptance criterion 4 is in §5 ("GitHub, first run of the library CI").
   Settings → Actions → General → Workflow permissions: **Read and write**; no
   branch protection or ruleset on `main` that blocks `github-actions[bot]` (or
   give it a bypass): the commit job pushes. Schedules of public repos are
   disabled after 60 days without activity; the staleness alarm (exit 39 after
   21 days) catches that. Dependabot (`.github/dependabot.yml`) opens weekly PRs
   that bump the actions' commit-SHA pins: review each, the workflow holds the
   signing key.
2. **Create the Cachix cache** with **your own signing key** (self-signed;
   `cachix generate-keypair <cache>`), secret key only as the GitHub secret
   `CACHIX_SIGNING_KEY`, a write token as `CACHIX_AUTH_TOKEN`; then set
   `rpi.pull.cache = { name = "<cache>"; publicKey = "<cache>.cachix.org-1:…"; };`
   in `hosts/neptun/default.nix` (plain assignment, not `cache = null` before),
   commit, push. Until then CI builds and tests neptun and prints the notice
   `no cache configured for neptun: built and tested, not published`; a cache
   without the two secrets fails the job with `::error::` naming the secret.
3. **First run with a cache**: Actions → `pi` → *Run workflow*, then **dispatch a
   second time and confirm it produces no pointer commit** (same storePath, A13).
   A new pointer commit on every run means the toplevel is not reproducible:
   investigate before relying on the timer. Then `git pull` and one manual
   `rpi-deploy deploy switch --host neptun` with `rpi.pull.cache` set; until
   then the Pi does not pull (the module is off).
4. **Wi-Fi PSKs** into a SecretSpec provider if a host enables Wi-Fi (neptun has
   it off; `secretspec.toml` declares the example variable `RPI_WIFI_HOME`).
5. **`rpi.buildHost.flakePath`** (host modules, README "Optional: `rpi-deploy`
   on the host's PATH"): it must now point at the repository root
   (`…/projects/raspberry-pi`), not `…/nixos`. The devenv shell sets `RPI_FLAKE`
   to the root by itself.
6. **`nix flake init -t github:GRBurst/nix-raspi`** works only after the push (the
   spikes S2/S3 used the local path); try it once from a scratch directory.
7. **Optional cleanup**: `nixos/` now holds only untracked caches (`.cache-nix`,
   `.nixcache`, `.scratch`, `result*`); the maintainer helper
   `.scratch/ci-env.sh` still points `XDG_CACHE_HOME` and `NIXPKGS_CONFIG`
   there, so move them before deleting the directory. `.rpi-build/` and
   `.rpi-build.log` at the repo root are artifacts of the old install flow:
   delete them and drop their two `.gitignore` lines. `.worktrees/lib-baseline`
   goes away after the acceptance (T7.4).
8. **Hooks**: `devenv shell` regenerates `.pre-commit-config.yaml`; the main
   tree's generated one still excludes `^nixos/tests/fixtures/` until then
   (worktrees use a copy with `^tests/fixtures/`).
9. **Merge**: the commits are unsigned; re-sign when pushing (history is linear:
   fast-forward or rebase, never a merge commit).
10. **Review flags** (earlier plans): `wheelNeedsPassword = false` for `pi` (now a
    library default, key-only login); `hardware.enableAllHardware` kept for
    parity with the tested image; re-measure the closure size (§2, earlier
    acceptance) after the library change.

Open points (documented, not fixed):

- *Wi-Fi and Bluetooth* are covered by evaluation checks only (qemu has neither
  radio); the Bluetooth UART attach on the Pi 3 (`dtparam krnbt=on`, firmware at
  priority 49) is unverified (plan A8). Checklist in §5.
- *The `rpi` alias* (`nixosConfigurations.rpi`, `rpiHost = false`) and `--attr`
  of `rpi-deploy` are deprecated and go in a later release.

- *Release bump (26.05 → 26.11)*: the pinned deploy tool is the flake's release, so
  the first deploy after the bump runs the 26.11 nixos-rebuild against the Pi's
  26.05 systemd (E3). Re-check the pinned tool then; for that one deploy set
  `RPI_NIXOS_REBUILD` to the 26.05 tool.
- *External storage* (`rpi.storage.external`) was never test-booted in qemu.
- *Root for agents*: passwordless sudo for `pi` plus nix-terminal `aiSkills.enable`
  means agents running as `pi` have root. Accepted; revisit if agents run unattended.
- *Fresh flash*: a Pi without `/var/lib/rpi-pull/seq` applies the current pointer at
  its first run, even over a newer local image (pinned by `rpi-pull-unit` p20).
- *Reboot timing* (final review S2, decided): after a boot-affecting update
  `shutdown -r 06:30` schedules the next 06:30, normally about an hour after
  the 05:00 run (a late catch-up run reboots the following morning).
  `switch-to-configuration boot` activates nothing until then; cancel with
  `shutdown -c`.
- *Pointer trust*: the pointer is not signed (HTTPS from GitHub); write access to
  the repo or the secrets means deploy access to the Pi (same level as the root key).
- *Boot + reboot path of `rpi-pull`* is covered by unit tests only; pull-smoke
  exercises the switch path (qemu skips U-Boot).
- *Manual deploy vs. a running pull* (final review N3): `rpi-deploy deploy` does
  not take `/var/lib/rpi-pull/lock`, so a manual deploy and a running `rpi-pull`
  can interleave `nix-env --set` and the pull may replace the manual deploy.
  Documented (README "Pull: CI builds, the Pi pulls": not while `rpi-pull` is active). Deferred fix:
  wrap `deploy`'s remote steps in `flock -n /var/lib/rpi-pull/lock` (refuse when
  busy), with a deploy-unit test of the busy case.
- *Downgrade check freshness* (final review N4): it is only as fresh as the last
  `git fetch` and compares only the `nixpkgs` and `nixos-raspberrypi` locks
  (D14, intended, README "Push from the build host"). A cheaper, stronger alternative if it ever
  matters: compare the local toplevel's label date (`26.05.YYYYMMDD.<rev>`) with
  the Pi's `/var/lib/rpi-pull/store-path`, which `status` already reads over
  ssh (no fetch needed).
- *`status` age* (final review N5): the age in `pull applied: seq N … (3h ago)` is
  the mtime of `$STATE/seq`, i.e. when the Pi applied it, not the pointer's age
  that A5 asked for; a stale pointer shows only as `pull last run: stale (exit
  39)`. Documented in README "Push from the build host". Deferred: `rpi-pull` records `built`
  in its state dir and `status` prints it.
- *Staleness means "no new system"* (final review N8): `ci/pointer.sh` keeps the
  pointer (and its `built`) when the toplevel is unchanged, so a lock-only
  commit or a frozen channel trips exit 39 after 21 days although CI is
  healthy. Accepted and documented (README "Pull: CI builds, the Pi pulls", step 7): after the 26.05
  end of life this is the wanted alarm. If the channel is quiet for long
  stretches, raise `rpi.pull.maxAgeDays`.
- *Dependency trust* (final review N9, accepted residual risk of A12): the
  closure's dependencies are substituted with any of the three trusted keys;
  nvmd's cache is hosted by Cachix, and if its key is Cachix-managed (not
  verified), a Cachix compromise can replace the content of dependencies not yet
  on the Pi, though not the toplevel (narHash). One sentence in the README
  Trust box.


## 5. Hardware and CI acceptance checklist (manual, ~1 h plus the CI setup)

Needs the Pi, a card ≥ 8 GiB, the LAN cable, ideally a 3.3 V USB-UART on GPIO
14/15. Tick in this file when done and note surprises.

### GitHub, first run of the library CI (acceptance criterion 4)

- [ ] Push `main`: the `pi` workflow starts (push trigger) with the jobs `hosts`
      (matrix `["neptun"]`), `build neptun` and `commit`.
- [ ] Without a cache: all green; `build neptun` shows the notice `no cache
      configured for neptun: built and tested, not published`; the step
      summaries name the host, nixpkgs/nvmd revisions, toplevel path, closure size
      and `published=false`; `commit` finds nothing to commit (`pushed=false`).
- [ ] Dispatch with `update-lock` ticked: the build job updates the lock, the
      `commit` job (the only one with `contents: write`) pushes a `flake.lock`
      commit as `github-actions[bot]` (checks the `GITHUB_TOKEN` push and the
      download-artifact layout; one host = a lone artifact, M4 note).
- [ ] With a cache and both secrets (§4 step 2): the host's cache works as an
      extra substituter for the runner user (R3: the guard dry run and the
      builds fetch from it, no "ignoring untrusted substituter" in the log);
      the pointer commit `deploy/neptun.json` follows; the pointer summary says
      `boot: unknown (no previous pointer)` the first time, later switch or reboot.
- [ ] With a cache but one secret missing (remove one temporarily): `::error::`
      naming it, `build neptun` fails, `commit` does not run.
- [ ] A scratch repo from `nix flake init -t github:GRBurst/nix-raspi`:
      `nix run --inputs-from . rpi#rpi-ci -- hosts` prints `hosts=["rpi"]` and
      its `pi` workflow is green without a cache.
      Dispatched with `update-lock`, its `flake.lock` commit changes only
      `rpi/nixpkgs` and `rpi/nixos-raspberrypi` (`rpi` keeps its rev, the
      kernel stays cached); with `update-library`, `rpi` moves (final review S3).

### Wi-Fi and Bluetooth (spec §10.2; qemu has neither radio)

- [ ] Wi-Fi: a host with `rpi.wifi.enable = true; rpi.wifi.networks = { "<ssid>" = "RPI_WIFI_HOME"; };`,
      `secretspec run -- rpi-deploy secrets` (or `flash … --wifi-env`):
      `iw dev wlan0 link` shows the association, `ip -4 addr show wlan0` an
      address, `ls -l /var/lib/rpi/wireless.env` is `-rw------- wpa_supplicant wpa_supplicant`; the PSK
      appears nowhere under `/nix/store` (`grep -r` the toplevel closure).
      `dmesg | grep -i brcmfmac` shows the firmware loading.
- [ ] Bluetooth: `rpi.bluetooth.enable = true;`: `bluetoothctl show` lists a
      controller; `dmesg | grep -i hci_uart` (the UART attach is unverified, A8).
- [ ] Both off again: no `wlan0`, no `hci0` (the overlays are back).

### A template host on the Pi

- [ ] `nix flake init -t github:GRBurst/nix-raspi` in an empty directory, a key in
      `hosts/rpi.nix`, `git init && git add -A`, `nix run .#rpi-deploy -- image`,
      flash, boot (DHCP): `ssh pi@<address>` works on port 22;
      `RPI_TARGET=root@<address> nix run .#rpi-deploy -- deploy` applies a
      one-line change.

### neptun (the earlier checklist; the commands name our host)


- [ ] `rpi-deploy image` then `rpi-deploy flash <image> /dev/<card>`: the typed
      confirmation is asked, the read-back prints `verified: … sha256 …`.
- [ ] Boot the Pi. Within ~2 min: `ssh -p 2222 root@neptun true` **and**
      `ssh -p 2222 pi@neptun true` work with your key (neither has a password).
      `ssh-keygen -R '[192.168.100.20]:2222'` first if the old Pi's key is cached.
- [ ] Headless config.txt took effect: `vcgencmd get_mem gpu` → `gpu=16M`;
      `dmesg | grep -i -E 'brcmfmac|hci_uart'` is empty; the serial console
      (GPIO UART, 115200 8N1) shows kernel messages and a login prompt.
- [ ] Root fs expanded to the card (`df -h /`), `findmnt /` shows
      `noatime,lazytime,commit=60`, `/tmp` is tmpfs, `free -m` shows 512 MiB zram.
- [ ] `rpi-deploy status` → `reboot pending: no`.
- [ ] `rpi-deploy deploy switch` with a one-line change (e.g. an
      `environment.etc` marker): applies in a few minutes (qemu: 276 s), `status` still `reboot pending: no`.
- [ ] `rpi-deploy deploy boot` with a boot-affecting change (e.g.
      `boot.kernelParams = [ "rpi_marker=1" ]`), then `ssh -p 2222 root@neptun reboot`.
      After the reboot `cat /proc/cmdline` contains `rpi_marker=1` (U-Boot read
      the new extlinux entry: the part qemu cannot show). Before the reboot
      `rpi-deploy status` says `reboot pending: yes (the boot default is not the
      running system; changed since boot: kernel-params)`, after it `no`.
- [ ] Reboot-pending detection (optional): `rpi-deploy deploy switch` with an
      initrd change (e.g. `boot.initrd.supportedFilesystems = [ "btrfs" ]`) →
      `status` says `reboot pending: yes`; after a reboot → `no`.
- [ ] Rollback: `NIX_SSHOPTS='-p 2222' nix run .#nixos-rebuild -- switch --rollback --no-reexec --target-host root@neptun`
      returns to the previous generation (verified in qemu by `deploy-smoke.sh`).
- [ ] Recovery drill (recommended once, with the serial console): reboot, stop
      U-Boot's countdown, boot an older `nixos-N-default` entry; or edit `DEFAULT`
      in `/boot/extlinux/extlinux.conf` on the card from the host (README "Recovery and rollback").
- [ ] Optional write-volume measurement (s6 §6): `cat /sys/block/mmcblk0/stat`
      before/after a day of idling.
- [ ] External disk (only when you want it): README "External storage".

CI pull (after §4 steps 1–3):

- [ ] First `workflow_dispatch` on `main`: green; a commit `pi: build <N> (workflow_dispatch)`
      by `github-actions[bot]` with `deploy/neptun.json` where `seq` = the run number
      and `built` is `YYYY-MM-DDTHH:MM:SSZ`; `cachix pin` `neptun` visible in the Cachix
      UI; runner disk (`df -h` in the log) and run time noted.
- [ ] Second dispatch: **no** new pointer commit (A13).
- [ ] `git pull`; `rpi-deploy deploy switch` once; `ssh -p 2222 root@neptun systemctl list-timers rpi-pull`
      shows the daily 05:00 timer; `rpi-deploy status` ends with `pull applied: none` and `pull last run: never`.
- [ ] `ssh -p 2222 root@neptun systemctl start rpi-pull` → exit 0 (`already-current` if
      you deployed the same system, `applied` otherwise); `rpi-deploy status` →
      `pull applied: seq <N> /nix/store/…-nixos-system-neptun-…` and
      `pull last run: applied (exit 0) at …` (or `already-current`). Read
      `journalctl -u rpi-pull` and `systemctl show rpi-pull -p MemoryPeak` (limit 384M **[?]**).
- [ ] A CI build that changes the kernel, kernel params or firmware: after the run
      `shutdown --show` lists the reboot at 06:30, `status` says `reboot pending: yes`;
      after the reboot (U-Boot, new kernel) `no` **[?]**.
- [ ] Staleness (optional): `rpi-pull --max-age-days 1 …` against an old pointer prints
      `pointer is N days old (CI stalled?)` and exits 39.
- [ ] Next day's run with no new pointer: `pull last run: up-to-date (exit 0)`.

Recovery if the new kernel or firmware does not boot: README "Recovery and rollback" (serial menu,
`DEFAULT` edit in `/boot/extlinux/extlinux.conf` from the host, or restoring
NIXOS_BOOT from the host). A rollback stays rolled back until the next CI build.


## 6. Environment and sandbox gotchas

- The agent sandbox has **no sudo**, cannot flash devices, must never ssh to
  the real Pi (192.168.100.20), never pushes or fetches from git remotes
  (`origin` = `git@github.com:GRBurst/nix-raspi.git`).
- **The helper** `.scratch/ci-env.sh` (gitignored, in the main tree; created by
  plan T0.1): `. /home/pallon/projects/raspberry-pi/.scratch/ci-env.sh [TREE]`
  `cd`s into TREE (default the main tree) and sets `XDG_CACHE_HOME` and
  `NIXPKGS_CONFIG` (the untracked caches under `nixos/`), the git identity and
  `GIT_CONFIG_GLOBAL=/dev/null XDG_CONFIG_HOME=/tmp/nogit` (the unit tests need
  them too). It defines `G` (git without the unreadable global excludes file,
  unsigned, with the identity: use it for **every** git command that writes,
  also `G worktree add`), `chk NAME` (build `checks.x86_64-linux.NAME`), `ev`,
  `unit NAME` (`bash tests/NAME.sh`), `top` (evaluates neptun's toplevel
  `drvPath`: yazi's IFD, needed before `nix flake check --no-build`), and the
  refactor-invariant functions `snap`/`snap2`/`inv` (plan §12) with the logs
  under `.scratch/lib/` (`baseline`, `snap`, `expect`, `logs`).
- **Linear history, no merge commits.** Parallel work lives in worktrees
  (`G worktree add .worktrees/lib-mN -b lib/mN main`, gitignored) and the
  orchestrator integrates with `G cherry-pick`; never `git merge`. A worktree
  needs the gitignored `.pre-commit-config.yaml` (copy it from another
  worktree; the hook runs shellcheck and actionlint).
- Always pass `--accept-flake-config` to nix (the checks and `rpi-deploy` do).
  `/tmp` is not writable for some paths; scratch goes to `.scratch/`.
- New files are invisible to the flake until `G add` (flake source is `git+file`;
  `G add -N` right after creating them), and **edits to tracked files during a
  long run change its source**: run long smoke tests from a clean worktree
  (`G worktree add --detach .worktrees/x <rev>` with `RPI_SMOKE_DIR` pointing at
  the shared scratch dir), not from a tree you keep editing. Never use `path:` on
  the repo root (it copies `.worktrees/`, `.scratch/`, `.devenv/`): scratch flakes
  use `git+file://<root>`.
- `nix flake check --no-build` needs a prior `top` (yazi IFD; `rpi-check` does it
  for every host). After changes in `ci/` run `chk eval-tools` first (the eval-tools
  quirk, §2).
- `cache.nixos.org` drops long transfers on this network (curl rc 56 after
  ~60 MB): retry with `--option download-attempts 10`, or mirror the NARs into
  a local `file://` binary cache.
- The host's system `ssh_config` includes files plain `ssh` rejects in the
  sandbox (`Bad owner or permissions`): use `ssh -F /dev/null` (the smoke tests do).
- python3 is not on PATH (use `node`, `perl`, or `nix run nixpkgs#…`); busybox comes
  from the pinned nixpkgs (`nix build --inputs-from . nixpkgs#busybox`).
- `pkill -f <script>` kills your own `bash -c` too: kill by PID.
- qemu raspi3b is ~5x slower than a real Pi 3 (TCG); usb-net works with the
  vendor kernel (`cdc_ether`, harmless `usbnet: failed control transaction`
  lines). Direct kernel boot skips U-Boot and the GPU firmware.
- Bash test gotchas: the nix sandbox has no `pgrep`/`pkill`; stdenv *sources*
  every file in `nativeBuildInputs` (scripts must come in as `src`); a unit-test
  PATH that has `bash` hides bugs of units whose PATH has none (the `f9dc426` bug).
- `tests/personal-values.sh` and the `personal-values` check list the same paths
  (the script is the source; the flake's fileset must match): a new library
  directory needs both.

## 7. History

Sessions 1–2 built a 1130-line `rpi-deploy` (`prepare`/`build`/`install`) around
`nixos-install` in a chroot; three real failures at the binfmt/chroot boundary
and an image-flow spike (qemu boot-smoke reached the login prompt; closure
3.97 GiB, image 2.07 GiB zst) led to the image flow. The first plan (M1–M7)
added a weekly host timer (`rpi-autoupdate`) that force-pushed an `auto-update`
branch; on 2026-10-23 the addendum replaced it: s7/s8 measured that the Pi
cannot evaluate its flake (1.10 GB RSS) but can realise a closure in 76–180 MB,
so GitHub Actions builds, our self-signed Cachix cache holds the closure and a
pointer in git tells the Pi what to pull (M1–M9 of the second plan, finished
2026-10-24). The old README/HANDOFF text is in git history (before the M9 docs
commit and before the M7 commit of the first plan). Experiment reports
(untracked, `nixos/.scratch/`): `e2` (native vs cross), `e3` (flash once +
`nixos-rebuild --target-host` in qemu), `s5` (hybrid inputs), `s6` (SD wear),
`s7` (community, autoUpgrade), `s8` (Cachix sizes, pin API, trust, Pi RAM),
`m1`–`m7` (first-plan milestone reports), `ci/` (second plan: `plan-review.md`,
`m8-report.md`, acceptance logs).

The library work (2026-10-25, plan M0–M7) turned the repository into a flake
others can use: the flake moved from `nixos/` to the root, `configuration.nix`
and `keys.nix` became `hosts/neptun`, every Pi-specific value an `rpi.*` option
or a default, and CI a host matrix. neptun's system derivation was held
unchanged by the refactor invariant (leaf diff against baseline B0). Evidence
and per-milestone reports (untracked): `.scratch/lib/m0-report.md` …
`m7-report.md`, logs in `.scratch/lib/logs/`.
