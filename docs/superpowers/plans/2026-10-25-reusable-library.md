# Reusable library flake (others run their own Pi) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan milestone by milestone. Steps use checkbox (`- [ ]`) syntax. Every task starts at status `[ ]` (todo).

**Goal:** The repo becomes a library flake: `lib.mkPi` hides nvmd + hybrid inputs + home-manager + image, every Pi-specific value is an `rpi.*` option (or an `mkDefault`) with a sensible default, our Pi `neptun` is one host module with an unchanged system derivation, a `nix flake init -t` template gives others a working host, and CI is a host matrix that stays green without a cache.

**Architecture:** First the flake moves from `nixos/` to the root (pure move, drvPath-identical). A scaffold milestone adds the refactor-invariant tool, host discovery in `rpi-lib.sh`, the `rpi-ci` package and an extracted workflow-lint script, so three milestones can then run in parallel worktrees on disjoint files: library modules + `mkPi` + `hosts/neptun` (M2), host tooling `rpi-deploy` (M3), CI (M4). Template (M5), qemu smokes (M6) and docs/acceptance (M7) follow.

**Tech stack:** Nix 2.34.8 flakes, NixOS 26.05 module system, nvmd `nixos-raspberrypi` (develop), home-manager master + nix-terminal, bash + shellcheck, jq, cachix CLI, GitHub Actions (`ubuntu-24.04-arm`, install-nix-action, upload/download-artifact), actionlint, devenv 2.4 + SecretSpec, qemu `raspi3b`.

**Spec:** `docs/superpowers/specs/2026-10-25-reusable-library-design.md` (read fully). Builds on `2026-10-19-image-push-deploy-design.md` and `2026-10-23-ci-pull-updates-design.md` (their mechanics stay unless changed). Previous plans (structure, gotchas, binding amendments A1–A13): `docs/superpowers/plans/2026-10-19-image-push-deploy.md`, `docs/superpowers/plans/2026-10-23-ci-pull-updates.md`. State: `HANDOFF.md`.

## Global Constraints (from the spec, verbatim values)

- Entry point `lib.mkPi { modules; specialArgs ? {}; }` → `nixosSystem … // { rpiHost = true; }`; CI discovers hosts by `attrNames` filtered on `rpiHost`.
- Outputs: `nixosModules.default`, `nixosModules.rpiBuildHost`, `homeModules.rpiBuildHost` (unchanged), `templates.default`, `packages.<system>.rpi-deploy`, `packages.<system>.rpi-ci`, `nixosConfigurations.neptun = lib.mkPi { modules = [ ./hosts/neptun ]; }`, `rpi` alias for one release, `checks`, `apps.x86_64-linux.nixos-rebuild` (unchanged).
- Options and defaults: `rpi.admin.user = "pi"`; `rpi.admin.sshKeys` none → assertion; `rpi.ssh.port = 22` (password auth off, root `prohibit-password`); `rpi.network.mode = "dhcp"` | `"static"` with `rpi.network.static.{address (CIDR), gateway, dns ? []}`; `rpi.wifi.enable = false`; `rpi.wifi.networks = {}` (SSID → PSK variable name); `rpi.wifi.secretsFile = "/var/lib/rpi/wireless.env"` (root 0600); `rpi.bluetooth.enable = false`; `rpi.headless.enable = true` (gpu_mem 16, no KMS, audio, camera/display detection; no longer touches Wi-Fi/Bluetooth); `rpi.profiles.terminal.enable = false`; `rpi.pull.repo = null`, `rpi.pull.branch = "main"`, pointer `https://raw.githubusercontent.com/<repo>/<branch>/deploy/<hostName>.json`; `rpi.pull.cache = null` → `{ name; publicKey; }`; `rpi.pull.enable` on when pointer + cache are set; `rpi.deploy.target = "root@<hostName>"`; `rpi.sdWear.*`, `rpi.storage.external.*` unchanged.
- `mkDefault`s: `networking.hostName = "rpi"`, `time.timeZone = "UTC"`, `i18n.defaultLocale`, zram 50 %, weekly GC (21 d), extlinux limit 5, no channels, `nixpkgs.flake` registry/NIX_PATH, `security.sudo.wheelNeedsPassword = false`, `documentation.enable = false`, `boot.tmp.cleanOnBoot`, nix `max-jobs`/`cores` 3, `allowUnfree`.
- `hosts/neptun` sets: its key, `rpi.ssh.port = 2222`, static `192.168.100.20/24` via `.1`, `networking.hostName = "neptun"`, Europe/Berlin, `neo`, terminal profile on (+ `hosts/neptun/home.nix`), `rpi.pull.repo = "GRBurst/nix-raspi"`, neovim, screen, sysctl, `docker`/`video` groups.
- Wi-Fi PSKs never in the store; CI secrets `CACHIX_AUTH_TOKEN`, `CACHIX_SIGNING_KEY` only as GitHub Actions secrets; consumers do not `follows` our inputs; the template's input is named `rpi`.
- CI: `nix run --inputs-from . rpi#rpi-ci -- <cmd>` (consumer), `nix run .#rpi-ci -- <cmd>` (here); subcommands `hosts|build|publish|pointer|commit`; weekly cron, push to `main`, dispatch with `update-lock`; main only; SHA-pinned actions + dependabot; no cache → `::notice::` "no cache configured for <host>: built and tested, not published", job green; cache set but a secret missing → `::error::` naming the secret, job fails; one `commit` job; step summaries and annotations only when `GITHUB_ACTIONS=true`.
- `rpi-deploy`: `--host NAME`, default `$RPI_HOST`, else the only Pi host, ambiguous → exit 2 with the list; target/port from `config.rpi.deploy.target`/`config.rpi.ssh.port`, `RPI_TARGET`/`RPI_PORT` override; `flash --wifi-env`; `secrets` (`install -m 600` over ssh, then `systemctl try-restart`); missing PSK variable → exit 2 naming it; values never printed or on a command line.
- Migration: `git mv nixos/* .`; pointer `deploy/neptun.json`; refactor invariant by `nix-store -qR <drv>` before/after with a listed set of expected differences.
- Out of scope: Pi models other than 3, our cache as a default substituter for others, separate locale options, sops-nix/agenix.

## Review Focus (likely to bite; each has a test in its owning task)

1. **A template user forgets the key** (`rpi.admin.sshKeys = [ ]`): evaluation must fail with a message naming `rpi.admin.sshKeys`, not build a locked-out image. Test: `eval-identity` "empty sshKeys fails an assertion naming the option"; `eval-template` "without a key the assertion fires" (T2.2, T5.1).
2. **Host attribute name ≠ hostname** (`nixosConfigurations.garden` with default hostname `rpi`): the pointer file, pin and the Pi's pointer URL must agree. Expected: everything keys on `config.system.name`. Test: `rpi-ci-unit` pt4 (pointer file named by `name=` of build) (T4.4); `eval-pull-update` URL table row with hostName ≠ attr (T2.5).
3. **A fork with our `rpi.pull.cache` but no secrets / a repo without a cache**: error naming the secret vs. green with a notice. Tests: `rpi-ci-unit` pb1–pb3 (T4.3).
4. **A PSK variable missing or containing a newline** when running `secrets` / `flash --wifi-env`: exit 2 naming the variable, nothing written, the value never in argv. Tests: `rpi-deploy-unit` sc3–sc6, fw2 (T3.3, T3.4).
5. **Two Pi hosts and a lock update**: both pointers must refer to one committed lock. Expected: `rpi-ci commit` refuses differing locks. Test: `rpi-ci-unit` k2 (T4.5).

---

## 0. Ground rules and environment (every implementer)

**Helper** (created in T0.1; gitignored, main tree; replaces `nixos/.scratch/ci-env.sh`):

```bash
# /home/pallon/projects/raspberry-pi/.scratch/ci-env.sh — usage: . <this> [TREE]   (TREE: worktree root; default main tree)
MAIN=/home/pallon/projects/raspberry-pi
cd "${1:-$MAIN}" || return 1
export XDG_CACHE_HOME=$MAIN/nixos/.cache-nix NIXPKGS_CONFIG=$MAIN/nixos/.nixcache/nixpkgs-config.nix  # untracked, stay in nixos/
export GIT_CONFIG_GLOBAL=/dev/null XDG_CONFIG_HOME=/tmp/nogit
export GIT_AUTHOR_NAME=GRBurst GIT_AUTHOR_EMAIL=GRBurst@protonmail.com GIT_COMMITTER_NAME=GRBurst GIT_COMMITTER_EMAIL=GRBurst@protonmail.com
S=$MAIN/.scratch/lib; mkdir -p "$S"/{baseline,snap,expect,logs}
G()    { git -c core.excludesFile=/dev/null -c commit.gpgsign=false -c user.name=GRBurst -c user.email=GRBurst@protonmail.com "$@"; }
chk()  { nix build --accept-flake-config --no-link -L ".#checks.x86_64-linux.$1"; }
ev()   { nix eval --accept-flake-config "$@"; }
unit() { bash "tests/$1.sh"; }
N=.#nixosConfigurations.neptun                        # exists before and after the refactor
top()  { ev --raw "$N.config.system.build.toplevel.drvPath"; }   # yazi IFD warm-up before `nix flake check --no-build`
CK="lib-invariant.cachix.org-1:$(printf 'A%.0s' $(seq 43))="
CACHE_T="{ name = \"lib-invariant\"; publicKey = \"$CK\"; }"
I1='c: c.config.system.build.toplevel.drvPath'
I2_OLD="c: (c.extendModules { modules = [ { _module.args.rpiKeys = c.config._module.args.rpiKeys // { cache = $CACHE_T; }; } ]; }).config.system.build.toplevel.drvPath"
I2_NEW="c: (c.extendModules { modules = [ { rpi.pull.cache = $CACHE_T; } ]; }).config.system.build.toplevel.drvPath"
snap() { local n=$1 f=${2:-$I1} d; d=$(ev --raw "$N" --apply "$f") || return 1
  echo "$d" >"$S/snap/$n.drv"; nix-store -qR "$d" | sort >"$S/snap/$n.closure"; nix derivation show -r "$d" >"$S/snap/$n.json"; }
snap2() { snap "$1-I1" && if [ -e keys.nix ]; then snap "$1-I2" "$I2_OLD"; else snap "$1-I2" "$I2_NEW"; fi; }
inv()  { local v rc=0; for v in I1 I2; do bash tests/drv-diff.sh "$S/snap/B0-$v.json" "$S/snap/$1-$v.json" "$S/expect/$v.txt" || rc=1; done; return $rc; }
```

- **Commits:** always through `G` (`G add …`, `G commit …`). One task = one commit unless stated. Unsigned; the user re-signs.
- **Linear history.** Each milestone: `G worktree add .worktrees/lib-mN -b lib/mN main`, `. $MAIN/.scratch/ci-env.sh $MAIN/.worktrees/lib-mN`. The orchestrator integrates with `G cherry-pick` onto `main` (main tree has the user's uncommitted `README.md`: never touch it; a cherry-pick that touches README is only done in M7 after Q1). Never `git merge`.
- **New files are invisible to the flake until staged** (`G add -N` right after creating them).
- **Eval:** ~1 GB RSS per `neptun` evaluation; `nix flake check --no-build` needs `top` first. Run at most one `[expensive]` step at a time across all worktrees (orchestrator serialises).
- **Long runs from a clean worktree** (edits change the flake source mid-run). Never `path:` on the repo root (copies `.worktrees/`, `.scratch/`, `.devenv/`): scratch flakes use `git+file://<root>`.
- **Never** ssh to the real Pi (192.168.100.20), push, or fetch `origin`. `ssh -F /dev/null` in sandboxed tests. python3 is not on PATH.
- **Cost classes.** `[cheap]` ≤ 2 min (eval, eval checks, unit tests). `[mid]` 2–15 min (`snap`, `nix flake check --no-build`, spikes). `[expensive]` > 15 min (image builds, qemu, full flake check incl. `rpi-host-vm`), never inside a RED/GREEN loop.
- **One failing check at a time.** Every RED names the check and the text it must print. Planted violations (§9): tick only after the red was seen.

## 1. Motivation

Others should be able to run this on their own Raspberry Pi 3 without editing our values (spec §1). Today hostname, keys, IP, port, timezone, keymap, the pull repo and the workflow are hardcoded, Wi-Fi/Bluetooth are not configurable (headless disables both), the NixOS boilerplate lives in our `flake.nix`, and CI fails without a cache (`ci/cache-name.sh` exits 1 on `cache = null`). The library keeps every mechanic of the two earlier specs, moves per-machine values into a committed host module, exposes one entry point, gives a template, and turns CI into a host matrix with visible, non-failing skips.

## 2. Approach (shape of the diff)

- **Moved:** every tracked `nixos/**` → root (M0); `configuration.nix` → `hosts/neptun/default.nix`, `home.nix` → `hosts/neptun/home.nix` (T2.7); `.github/workflows/neptun.yml` → `.github/workflows/pi.yml` (T4.7).
- **Removed:** `keys.nix` (T2.7), `ci/cache-name.sh` + its tests (T4.7), the old module list in `flake.nix` (T2.7), `rpi-deploy` defaults `rpi`/`root@neptun`/`2222` (T3.1/T3.2), `cachix/cachix-action` (T4.7).
- **New library:** `lib/mkPi.nix`; `modules/default.nix`, `modules/{base,identity,network,wifi,bluetooth}.nix`, `modules/profiles/terminal.nix`; options in `modules/pull-update.nix` (`repo`, `branch`, `cache`); `modules/headless.nix` stops setting the two overlays.
- **New tooling:** `tests/drv-diff.sh` (refactor invariant), `rl_hosts`/`rl_host_info` in `rpi-lib.sh`, `ci/rpi-ci.sh` (dispatcher), `ci/hosts.sh`, `ci/gh.sh` (annotations/summary), `ci/package.nix`, `tests/workflows-lint.sh`, `tests/personal-values.sh`; `rpi-deploy --host`, `secrets`, `flash --wifi-env`; `rpi-ci commit --artifacts`.
- **New content:** `hosts/neptun/`, `templates/default/` (flake, `hosts/rpi.nix`, workflow, dependabot, devenv files, README), `secretspec.toml`, `devenv.local.nix.example`.
- **New checks** (auto-discovered unless noted): `eval-{lib,identity,defaults,network,wifi,bluetooth,terminal,template}`, `rpi-{drv-diff,lib}-unit`, `personal-values` (flake.nix hunk, M7). No existing check is removed.

## 3. Decisions

| # | Decision | Rationale | Rejected alternative (why) |
|---|---|---|---|
| D1 | Root move first, one commit: `G mv nixos/<entry> <entry>` for each tracked top-level entry, with all path fixups and the pointer location (`deploy/neptun.json`). Untracked `nixos/` leftovers (`.scratch`, `.cache-nix`, `.nixcache`, `result`) stay. | Every later milestone edits root paths only; history follows renames; drvPath provably unchanged. | Move last (every branch rebased over a full-tree rename); moving the untracked caches (breaks the old helper mid-flight, no gain). |
| D2 | Refactor invariant = root-cause ("leaf") diff of `nix derivation show -r` JSON (`tests/drv-diff.sh`) against baseline B0 taken before the move; `nix-store -qR` lists kept as records. Two probes: I1 = neptun as committed (pull off), I2 = neptun + test cache (pull on). | A raw closure diff lists every ancestor; leaves name the cause. JSON survives GC. | `nix-diff` only (needs B0 `.drv` files alive in the store; usable ad hoc). |
| D3 | Library modules are built and tested against a fixture host through `self.lib.mkPi` while neptun stays on the old module list; neptun switches in one task (T2.7). | Incremental import into the old config would merge e.g. ports `[22 2222]` and break the invariant mid-way. | Incremental switch. |
| D4 | `modules/base.nix` holds the kept `mkDefault`s, plus today's `nix.daemonIOSchedPriority = 7`, `i18n.defaultLocale = "en_US.UTF-8"`, `networking.useNetworkd = true`, `security.sudo.enable = true`. | `modules/default.nix` stays an import list; neptun's values come from base unchanged. | Inline in `default.nix`. |
| D5 | `nixosModules.default` = rpi.* modules **without** the terminal profile; `nixosModules.terminal` = the profile; `mkPi` imports both + home-manager. | The profile defines `home-manager.*`; without HM that is "option does not exist" even under `mkIf false`. | `default` importing HM (double import for users who already have HM). |
| D6 | `mkPi` module order: nvmd `raspberry-pi-3.base`, `nixosModules.default`, `nixosModules.terminal`, user `modules`, HM module, HM block (useGlobalPkgs, useUserPackages, `extraSpecialArgs = { inherit inputs; }`, `sharedModules = [ nix-terminal.homeModules.default ]`). `modules/default.nix` imports `sd-image sd-wear headless external-storage pull-update base identity network wifi bluetooth` in this order. | Mirrors today's order (Pi modules, configuration.nix, HM) so list options merge identically (I1 = ∅). | Any other order (order-only drv diffs in `system-path`, users). |
| D7 | `specialArgs = { inherit inputs; } // specialArgs` (library inputs; consumers may override). Library modules never read `inputs`. | Parity for `hosts/neptun/home.nix`; consumers keep control. | Library modules depending on `inputs` (break when a consumer overrides it). |
| D8 | Static network keeps today's `systemd.network.networks."10-lan-static"` (`matchConfig.Type = "ether"`, `Address`, `Gateway`, `DNS` only if non-empty). DHCP mode defines no network: NixOS's default DHCP network for `ether` (useNetworkd + useDHCP default) applies, and its wlan default covers Wi-Fi. | Identical neptun unit; no duplicate DHCP network. | Own DHCP network file. |
| D9 | Wi-Fi: `networking.wireless.enable`, `secretsFile = cfg.secretsFile` (type `str`, never a Nix path), `networks.<ssid>.pskRaw = "ext:<VAR>"`; firmware `hardware.firmware = lib.mkOverride 49 [ <Pi 3 wireless firmware, S8> ]` (beats sd-wear's `mkForce [ ]`); tmpfiles `d /var/lib/rpi 0700 root root -`. Bluetooth: `hardware.bluetooth.enable` + the same firmware at priority 49; overlay absent. | Keeps PSKs out of the store; overlays exactly as headless set them while off. | `psk` (store); iwd (no `ext:` secrets). |
| D10 | Host discovery and host info are two Nix expressions in `rpi-lib.sh` (`RL_HOSTS_EXPR`, `RL_HOST_INFO_EXPR`), shared by `rpi-deploy` and `rpi-ci`; `nixosConfigurations.rpi = neptun // { rpiHost = false; }`. | One definition, one eval per invocation; the alias is not built twice. | Separate expressions per tool. |
| D11 | Pointer file, pin name and `--host` of `rpi-ci pointer` key on `config.system.name` (= hostName), reported by `rpi-ci build` as `name=`. | The Pi's pointer URL and rpi-pull's regex use the hostname, not the attr name. | Attr name (silent mismatch, Review focus 2). |
| D12 | `rpi-ci` = `ci/rpi-ci.sh` dispatcher over the existing scripts; every CI script defaults `--flake` to `$PWD`; package layout `$out/libexec/rpi-ci/{ci/*.sh,rpi-lib.sh,rpi-fp.sh}`, wrapper `--suffix PATH` with `git jq coreutils gnugrep gnused findutils util-linux cachix` (nix is the runner's). | Scripts keep finding siblings via `$HERE/..`; the store copy has no flake next to it. | Default `$HERE/..` (points into the store). |
| D13 | CI substitutes from the host's cache via `--option extra-substituters https://<name>.cachix.org --option extra-trusted-public-keys <key>` in `rpi-ci build` when `rpi.pull.cache` is set; `cachix/cachix-action` is dropped. | The cache name is per host and only known after evaluation; one fewer pinned action. Risk R3. | cachix-action with a per-host name output (needs an extra eval step before it). |
| D14 | Each matrix job updates the lock itself when requested; `rpi-ci commit --artifacts DIR` requires all `DIR/*/flake.lock` byte-identical, else `::error::` and no commit. The commit job runs only when every build succeeded. | Spec "build: lock update if requested; one commit"; no silent lock/pointer mismatch. | Lock update in the hosts job (spec places it in build); committing the first lock. |
| D15 | Build jobs `permissions: contents: read`; only the commit job has `contents: write`. | The jobs holding the signing key cannot push. | Workflow-wide write. |
| D16 | `rpi-ci build` also builds every `checks.<currentSystem>` attribute of the built flake (none → notice), after the toplevel, before printing outputs. | Spec "run the aarch64 unit checks" generically (ours: syntax + unit checks; consumers: their own). | A fixed check list in the workflow (consumer repos lack our checks). |
| D17 | `ci/gh.sh`: `gh_notice MSG`, `gh_warning MSG`, `gh_error MSG [FILE [LINE]]`, `gh_group TITLE` / `gh_endgroup`, `gh_summary` (stdin → `$GITHUB_STEP_SUMMARY`). With `GITHUB_ACTIONS != true`: notice/warning/error print `rpi-ci: <level>: MSG` on stderr, groups and summary do nothing. Messages escape `%`→`%25`, CR→`%0D`, LF→`%0A`. | One place for the gating rule. | Inline `echo ::…` in every script. |
| D18 | The pointer gains `"bootFp": "<sha256 of rl_fp_local TOP>"`; the pointer summary compares it with the previous pointer's (`unchanged → switch`, `changed → reboot`, `unknown`). rpi-pull ignores unknown fields (pinned). | Spec summary "whether the boot fingerprint changed"; the previous toplevel is not on the runner. | Realising the previous system on the runner. |
| D19 | Ours `.github/workflows/pi.yml` = template's with `nix run --inputs-from . rpi#rpi-ci` replaced by `nix run .#rpi-ci`; asserted textually. | "Same shape" becomes a checked property. | Two hand-maintained workflows. |
| D20 | Push trigger `paths-ignore: ["deploy/**", "docs/**", "**.md"]` (was `nixos/**` minus `nixos/deploy/**`). | Root flake: everything but docs/pointers affects the build. | `paths:` allowlist (misses new dirs). |
| D21 | PSKs reach `rpi-deploy` as env vars, e.g. `secretspec run -- rpi-deploy secrets`; content goes to the remote through stdin (`ssh … install -m 600 /dev/stdin FILE`) and, for `flash --wifi-env`, through `sudo install -D -m 600 /dev/stdin <mnt>/FILE` after `sudo mount <dev>2`. | No temp file, no argv, no store. | devenv's secretspec→`env.*` (S4: may land in the shell derivation). |
| D22 | Template host `hosts/rpi.nix`, `nixosConfigurations.rpi`; the template flake re-exports `inherit (rpi) apps packages;` and copies our `nixConfig` (nvmd cache). Minimal `devenv.nix`, `devenv.yaml`, `.gitignore`, `secretspec.toml` in the template. | `rpi-deploy` runs the deployed flake's pinned `nixos-rebuild` app; `nix run .#rpi-deploy` works; the nvmd cache must be trusted per flake. | Template without apps (deploy breaks), without devenv (the example file would be orphaned). See Q2. |
| D23 | `personal-values` check scans library paths only (`lib/ modules/ templates/ ci/ .github/ rpi-*.sh devenv.nix devenv.yaml secretspec.toml devenv.local.nix.example`) plus `flake.nix` with a line allowlist; the library URL `github:GRBurst/nix-raspi` is allowed. | Spec AC1 exempts hosts/neptun, README example, fixtures; docs/HANDOFF are history. | Whole-tree grep with section markers in README (fragile). |
| D24 | The `actionlint` check body moves verbatim into `tests/workflows-lint.sh` (M1). | M4 then edits no `flake.nix`. | M4 editing the inline check (conflicts with M2). |
| D25 | `eval-template` evaluates the real `templates/default/flake.nix` outputs with our flake as the `rpi` input. | "Template evaluates with the local library" without network or a lock. | A separate fixture copy of the template host. |

## 4. Gate (no principles document in the repo; spec intents)

| Row | Invariant | Result | Enforced by |
|---|---|---|---|
| G1 | Nothing personal in library code | PASS | `personal-values` (T7.1) |
| G2 | Every Pi-specific value is an option with a default | PASS | `eval-defaults`, `eval-identity`, `eval-network` (T2.2–T2.3) |
| G3 | Boilerplate behind one entry point; all NixOS options overridable | PASS | `eval-lib`, `eval-defaults` P3 (T2.1–T2.2) |
| G4 | neptun keeps its CI build, pull and cache path; derivation unchanged except listed | PASS | `inv` (T2.7, T7.4), pull-smoke (T6.2) |
| G5 | CI green for forks and cache-less repos | PASS ([M]) + manual AC4 | `rpi-ci-unit` pb1–pb4, lint (M4) |
| G6 | PSKs never in the store or argv | PASS | `eval-wifi` P6, `rpi-deploy-unit` sc*/fw* P8 |
| G7 | Shell scripts stay shellchecked | PASS | `rpi-deploy-syntax` auto-discovery covers new `ci/*.sh`; pre-commit hook covers `tests/` |
| G8 | Spec file list | VIOLATION (extra files) | C1–C6 |
| G9 | Spec CI "cachix" handling | VIOLATION (cachix-action dropped, D13) | C7 |
| G10 | Spec §5 "devenv: secretspec.toml" | PASS (declared; transport via `secretspec run`, D21) | `eval-template` T5.2 |

| Complexity row | Need | Simpler alternative rejected |
|---|---|---|
| C1 `tests/drv-diff.sh` | explain diffs by cause (AC3) | eyeballing `comm` of closures |
| C2 `modules/base.nix` | home for kept defaults | inline in `default.nix` |
| C3 `nixosModules.terminal` split | HM-less users of `default` | one module requiring HM |
| C4 `bootFp` pointer field | summary "switch vs reboot" | dropping that summary line (Q7) |
| C5 `ci/gh.sh`, `ci/hosts.sh`, `ci/rpi-ci.sh`, `tests/workflows-lint.sh`, `tests/personal-values.sh` | gating rule, matrix, single entry, parallel milestones, AC1 | inline YAML/flake code |
| C6 template devenv files | the spec's `devenv.local.nix.example` needs a devenv | orphaned example (Q2) |
| C7 extra substituter flags | per-host cache unknown before eval | conditional cachix-action |

## 5. Files to read first (list only; read at the start of your milestone)

- Everyone: the spec, this plan §0–§4, §12–§15 and your milestone; `HANDOFF.md` §3, §6.
- M0: `nixos/flake.nix` (checks, `actionlint`), `devenv.nix`, `.github/workflows/neptun.yml`, `nixos/tests/{ci,deploy}-unit.sh` (repo fixtures), `nixos/tests/{deploy,pull}-smoke.sh` (scratch flake).
- M1: `rpi-lib.sh`, `ci/*.sh`, `tests/harness.sh`, `tests/ci-unit.sh` (mocks), `flake.nix` (`mkRpiDeploy`, `packages`, `actionlint`), `tests/eval/{default,tools}.nix`.
- M2: `flake.nix` (`nixosConfigurations`, eval args), `configuration.nix`, `home.nix`, `keys.nix`, `modules/*.nix`, `tests/eval/*.nix`; nixpkgs `nixos/modules/services/networking/wpa_supplicant.nix`, `nixos/modules/tasks/network-interfaces-systemd.nix`; nvmd `modules/` (Pi 3 firmware/bluetooth).
- M3: `rpi-deploy.sh`, `rpi-lib.sh` (`rl_hosts`, `rl_host_info`), `tests/deploy-unit.sh` (mocks, flash tests).
- M4: `ci/*.sh`, `tests/ci-unit.sh`, `tests/pull-unit.sh` (pointer parsing cases), `.github/workflows/neptun.yml`, `.github/dependabot.yml`, `tests/workflows-lint.sh`, `rpi-fp.sh`.
- M5: `flake.nix` (`nixConfig`, outputs), `hosts/neptun/default.nix`, `devenv.nix`, `.gitignore`; devenv SecretSpec docs.
- M6: `tests/{boot,deploy,pull}-smoke.sh`, `tests/qemu-pi.sh`.
- M7: `README.md` (incl. the user's change), `HANDOFF.md`, the spec §8–§10.

## 6. Type-checking strategy

| Checker | When | Expected rejections |
|---|---|---|
| NixOS module system | every `ev`/`chk`/`snap` | `rpi.network.mode = "wifi"` (`enum [ "dhcp" "static" ]`); `rpi.network.static.address = "192.168.1.20"` (`strMatching "[0-9]{1,3}(\\.[0-9]{1,3}){3}/[0-9]{1,2}"`); `rpi.ssh.port = 70000` (`types.port`); `rpi.admin.user = "Pi User"` (`strMatching "[a-z_][a-z0-9_-]*"`); `rpi.wifi.networks.x = "my-var"` (`attrsOf (strMatching "[A-Za-z_][A-Za-z0-9_]*")`); `rpi.wifi.secretsFile = ./x` (`strMatching "/.+"`, a path is not a string); `rpi.pull.cache = { name = "x"; }` (submodule, `publicKey` required, `strMatching "[^:]+:[A-Za-z0-9+/]{43}="`); `rpi.pull.repo = "https://github.com/o/r"` (`nullOr (strMatching "[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")`); assertions: empty `sshKeys`, static without address/gateway. |
| Not caught by types | — | a cache that does not exist, a wrong PSK, a repo without the pointer → first real run (§10). |
| `bash -n` + `shellcheck -x -P SCRIPTDIR -S warning` | `chk rpi-deploy-syntax` (non-test `*.sh`); `shellcheck …` by hand on new `tests/*.sh` | unquoted expansions, unset vars, unresolvable `source`. |
| actionlint (+ shellcheck on `run:`) | `chk actionlint` | unknown keys/contexts, `steps.x.outputs.y` typos, matrix `fromJSON` misuse, bad cron. |
| `builtins.fromTOML` / `jq -e` | `eval-template` / runtime | malformed `secretspec.toml`; pointer and host-info JSON of the wrong shape. |

## 7. Testing strategy per layer

| Layer | Covers | Needs | Cost |
|---|---|---|---|
| L1 eval checks `eval-*` | options, defaults, assertions, derived values, template outputs, neptun values (`eval-pi-config`), packages (`eval-tools`) | flake eval; never force `toplevel` | cheap |
| L2 unit `rpi-drv-diff-unit` | leaf algorithm, expect matching, format normalisation | jq, synthetic JSON | cheap |
| L2 unit `rpi-lib-unit` | `rl_hosts`, `rl_host_info` argv/output | nix mock | cheap |
| L2 unit `rpi-deploy-unit` | host selection, target/port precedence, `secrets`, `flash --wifi-env` | mocks (nix, ssh, sudo, mount, dd) | cheap |
| L2 unit `rpi-ci-unit` | dispatcher, hosts, build substituters/checks/summary, publish skip/error, pointer bootFp/name, commit artifacts, GH gating | mocks (nix, cachix), real git + bare origin | cheap |
| L2 unit `rpi-pull-unit` | +1 case: extra pointer fields ignored | existing | cheap |
| L3 lint | `rpi-deploy-syntax`, `actionlint` (both workflows, shape, order, pins, permissions), `personal-values` | shellcheck, actionlint, grep | cheap |
| L4 refactor invariant | neptun I1/I2 vs B0 | `snap` (eval ~1 GB) | mid |
| L5 spikes S1–S8 | unknowns (§13) | network for flake init, devenv | mid |
| L6 qemu | boot-smoke (template default host, DHCP, port 22), deploy-smoke, pull-smoke (neptun) | qemu raspi3b, image builds | expensive (§M6) |
| L7 VM `rpi-host-vm` | build-host module (unchanged) | KVM/TCG | expensive, once in T7.4 |
| L8 real GitHub / Pi | AC4, Wi-Fi/Bluetooth on hardware | user | manual (§10) |

## 8. Properties (derive expectations from the system under test; literals only where they are the criterion)

- P1 Invariant: `leaves(B0-Ix, now-Ix) = E(Ix)` for x ∈ {1, 2} (§12); strong form for I1: `drv(now-I1) = drv(B0-I1)`.
- P2 Personal values: ∀ f ∈ library files, ∀ p ∈ patterns: `¬ grep -E p f` (allowlisted lines excepted).
- P3 Overridable: ∀ (opt, v) ∈ kept defaults: a host defining `opt = v' ≠ v` plainly yields `config.opt = v'`.
- P4 Pointer URL: `pointerUrl = "https://raw.githubusercontent.com/${repo}/${branch}/deploy/${hostName}.json"` over the table {(o/r, main, rpi), (o/r, dev, garden), (a-b/c.d, main, neptun)}; `repo = null ⇒ pointerUrl = null`.
- P5 Enable: `pull.enable = (pointerUrl ≠ null ∧ cache ≠ null)`; with the derived default this is `repo ≠ null ∧ cache ≠ null`, checked over the 4 combinations.
- P6 Wi-Fi: ∀ (ssid, var) ∈ networks: `wireless.networks.${ssid}.pskRaw = "ext:${var}" ∧ psk = null`; `secretsFile` is a string not under `builtins.storeDir`.
- P7 Hosts: `hosts = sort (filter (n: cs.${n}.rpiHost or false) (attrNames cs))`; `rpi ∉ hosts` ∧ `neptun ∈ hosts`.
- P8 Secrets content: lines = sort { "VAR=" + env(VAR) | VAR ∈ values(networks) } (unique); the remote/target file gets exactly those bytes, mode 600; `count(argv lines containing any PSK value) = 0`.
- P9 GH gating: `GITHUB_ACTIONS ≠ true ⇒ count(^::) = 0 ∧ ¬exists(summary)`; `= true ⇒` each subcommand appends a `## <host>: <step>` section.
- P10 Same shape: `sed 's#nix run --inputs-from \. rpi\#rpi-ci#nix run .\#rpi-ci#g' template.yml = ours.yml` byte-for-byte.
- P11 Commit: one new commit whose changed paths ⊆ {flake.lock} ∪ {deploy/<name>.json | published} and ⊇ the published pointers.
- P12 Publish: `cache = null ⇒ rc 0 ∧ published=false ∧ 0 cachix calls`; `cache ≠ null ∧ secret missing ⇒ rc 1 ∧ error names the secret ∧ 0 cachix calls`.
- P13 Template defaults: `cfg.rpi.ssh.port = 22 ∧ cfg.services.openssh.ports = [ cfg.rpi.ssh.port ] ∧ cfg.rpi.network.mode = "dhcp" ∧ ¬wifi ∧ ¬bt ∧ hostName = "rpi"` (literals are AC2's criterion).
- P14 Checks preserved: `names(checks before) ⊆ names(checks after)`; per unit/eval check, assertion count after ≥ before, except tasks that state a removal.

Pinned literals (user-facing): `no cache configured for <host>: built and tested, not published`; `CACHIX_AUTH_TOKEN is not set`, `CACHIX_SIGNING_KEY is not set`; `several Pi hosts: <list>; pick one with --host or RPI_HOST`; `no Pi host (lib.mkPi) in <flake>`; `missing PSK variable <VAR>`; `rpi.wifi is disabled for <host>`; `rpi.admin.sshKeys is empty`; `lock differs between hosts`.

## 9. Planted violations (tick after seeing red; revert after)

| Check | Plant | Must FAIL with | Seen |
|---|---|---|---|
| move fixups (T0.2) | flake.nix `fileset = ../.github` | `chk actionlint` evaluation error | [ ] |
| `rpi-drv-diff-unit` | drv-diff reports every changed drv (no leaf filter) | `FAIL: dd2 only the leaf is reported` | [ ] |
| `inv` (T2.7) | `rpi.ssh.port = 22;` in hosts/neptun | `UNEXPECTED:` lines for I1 and I2 | [ ] |
| `rpi-lib-unit` | `rl_host_info` without host-name validation | `FAIL: lh4 invalid host name -> exit 2, no nix call` | [ ] |
| `eval-tools` | rpi-ci package without `rpi-fp.sh` | `FAIL: rpi-ci package ships ci/*.sh, rpi-lib.sh and rpi-fp.sh` | [ ] |
| `rpi-ci-unit` r3 | hosts.sh prints names unquoted | `FAIL: r3 hosts= is a JSON array` | [ ] |
| `actionlint` (T1.4) | pointer step above publish | `FAIL: pointer is written after push + pin` | [ ] |
| `eval-lib` | mkPi without `// { rpiHost = true; }` | `FAIL: mkPi returns a nixosSystem marked rpiHost` | [ ] |
| `eval-identity` | drop the sshKeys assertion | `FAIL: empty rpi.admin.sshKeys fails an assertion naming the option` | [ ] |
| `eval-defaults` | base.nix `documentation.enable = false;` (plain) | `FAIL: a host overrides every kept default` | [ ] |
| `eval-network` | static network without `Gateway` | `FAIL: static: 10-lan-static with Address and Gateway` | [ ] |
| `eval-wifi` | `psk = "$VAR"` instead of `pskRaw = "ext:…"` | `FAIL: every network uses ext:<VAR>, never psk` | [ ] |
| `eval-bluetooth` | headless still sets `disable-bt` | `FAIL: bluetooth on: disable-bt overlay gone` | [ ] |
| `eval-pull-update` | pointer path `…/nixos/deploy/…` | `FAIL: pointer URL derives from repo, branch and hostName` | [ ] |
| `eval-terminal` | profile hardcodes user `pi` | `FAIL: terminal profile follows rpi.admin.user` | [ ] |
| `rpi-deploy-unit` hs3 | ambiguous hosts pick the first | `FAIL: hs3 several hosts -> exit 2 with the list` | [ ] |
| `rpi-deploy-unit` tp2 | env vars ignored (info always wins) | `FAIL: tp2 RPI_TARGET/RPI_PORT override the host config` | [ ] |
| `rpi-deploy-unit` sc4 | PSK passed as an ssh argument | `FAIL: sc4 PSK values never in argv` | [ ] |
| `rpi-deploy-unit` fw2 | `--wifi-env` checks variables after dd | `FAIL: fw2 missing PSK -> exit 2 before dd` | [ ] |
| `rpi-ci-unit` gh1 | gh_notice ignores `GITHUB_ACTIONS` | `FAIL: gh1 no :: lines outside GitHub Actions` | [ ] |
| `rpi-ci-unit` pb1 | publish exits 1 without a cache | `FAIL: pb1 no cache -> notice, published=false, rc 0` | [ ] |
| `rpi-ci-unit` pb2 | publish pushes without a token | `FAIL: pb2 missing CACHIX_AUTH_TOKEN -> error naming it` | [ ] |
| `rpi-ci-unit` k2 | commit takes the first lock | `FAIL: k2 differing locks -> no commit` | [ ] |
| `rpi-pull-unit` px1 | rpi-pull rejects unknown keys | `FAIL: px1 extra pointer fields are ignored` | [ ] |
| `actionlint` P10 | an extra step only in ours | `FAIL: pi.yml is not the template's workflow with the local rpi-ci` | [ ] |
| `actionlint` D15 | `contents: write` at workflow level | `FAIL: only the commit job may write` | [ ] |
| `eval-template` | template host sets `rpi.ssh.port = 2222` | `FAIL: template default: DHCP, port 22, Wi-Fi and Bluetooth off` | [ ] |
| `personal-values` | `# neptun` comment in `modules/base.nix` | `FAIL: personal value in library code:` + `modules/base.nix:<n>` | [ ] |
| boot-smoke [expensive] | `RPI_SMOKE_GUEST_SSH_PORT=2222` for the template host | `FAIL` at the SSH reachability step | [ ] |

## 10. Coverage gap (manual, with reasons)

1. **AC4, a real GitHub run** (matrix, artifacts, `GITHUB_TOKEN` push from the commit job, annotations rendering, step summary, extra-substituter flags as runner user R3). User pushes and watches; checklist in HANDOFF (T7.3).
2. **Wi-Fi and Bluetooth on hardware** (firmware, `ext:` PSK in wpa_supplicant, BT UART attach): qemu has neither radio. Manual checklist: `rpi.wifi.enable` + `rpi-deploy secrets` → `iw dev wlan0 link`; BT → `bluetoothctl show`.
3. **`nix flake init -t github:GRBurst/nix-raspi`** from GitHub (S2 covers the local path only); first public use after the push.
4. **SecretSpec providers** other than dotenv/env (keyring, 1Password): user environment.
5. **README quality** (§8 order, consumer-first): human review in T7.5.
6. Tests/README/HANDOFF/`hosts/neptun` are excluded from `personal-values` by design; `G grep -n -E 'neptun|2222|192\.168\.100\.' -- tests` is reviewed by hand in T7.1 (only neptun-specific tests may name neptun).

## 11. Scenario coverage (spec → the one check that executes it)

| Spec scenario | Check |
|---|---|
| §7 defaults: DHCP, Wi-Fi/BT overlays off, port 22, hostname rpi, no HM users | `eval-defaults` (T2.2–T2.6) |
| §7 static network | `eval-network` (T2.3) |
| §7 Wi-Fi on: overlay gone, secrets file path, no PSK in the store | `eval-wifi` (T2.4) |
| §7 Bluetooth on | `eval-bluetooth` (T2.4) |
| §7 assertion without keys | `eval-identity` (T2.2) |
| §7 derived pointer URL; `rpi.pull.enable` only with repo + cache | `eval-pull-update` (T2.5) |
| §7 `rpi.deploy.target` | `eval-identity` (T2.2) |
| §7 template host evaluates through `lib.mkPi` with the local library | `eval-template` (T5.1) |
| §3 `lib.mkPi`, `rpiHost`, `nixosModules.default` | `eval-lib` (T2.1, T2.7) |
| §4 terminal profile | `eval-terminal` (T2.6) |
| §4 neptun values | `eval-pi-config` (T2.7) |
| §7 unit: `rpi-deploy` host selection / overrides | `rpi-deploy-unit` hs*, tp* (T3.1–T3.2) |
| §7 unit: `secrets`, `flash --wifi-env` | `rpi-deploy-unit` sc*, fw* (T3.3–T3.4) |
| §7 unit: `rpi-ci` hosts/matrix | `rpi-ci-unit` r3–r4, hs1 (T1.3, T4.6) |
| §7 unit: cache-less skip, missing secret error | `rpi-ci-unit` pb1–pb3 (T4.3) |
| §7 unit: single commit job | `rpi-ci-unit` k1–k4 (T4.5) + `actionlint` job graph (T4.7) |
| §7 unit: summary/annotations only under `GITHUB_ACTIONS=true` | `rpi-ci-unit` gh1–gh3, b-sum, pb-sum, pt2 (T4.1–T4.4) |
| §7 actionlint for both workflows | `actionlint` (T4.7) |
| §7 qemu boot-smoke on a template default host | `tests/boot-smoke.sh` (T6.1) |
| §7 deploy-smoke, pull-smoke on neptun | `tests/{deploy,pull}-smoke.sh` (T6.2) |
| §7 refactor invariant | `inv` (T2.7, T7.4) |
| §5 `RPI_FLAKE` = root, `devenv.local.nix` example/gitignore, `secretspec.toml` | T0.2 verify; `eval-template` devenv rows (T5.2) |
| §6 step summary content, group blocks, job names with host | `rpi-ci-unit` b-sum/pb-sum/pt2; `actionlint` (`name: build ${{ matrix.host }}`) |

| §9 AC | Evidence |
|---|---|
| 1 `nix flake check` at the root; no personal value outside allowed places | T7.4 full `nix flake check`; `personal-values` (T7.1) |
| 2 template instance evaluates and builds its image unedited; default DHCP, 22, radios off | `eval-template` (T5.1), S2/S3 (T5.3), boot-smoke image build (T6.1) |
| 3 neptun drv diff = expected list | `inv` T2.7 and T7.4 |
| 4 CI green on GitHub without a cache, summary + notice | user (§10.1); locally `rpi-ci-unit` + T4.7 manual run |
| 5 boot-smoke (template), deploy-smoke, pull-smoke | T6.1, T6.2 |
| 6 README per §8 | T7.2 + review T7.5 |

## 12. Refactor invariant: baseline, tool, expected differences

**Baseline B0** (T0.1, before the move, clean detached worktree of `main`): `$S/baseline/commit`, `$S/snap/B0-I1.{drv,closure,json}`, `$S/snap/B0-I2.{drv,closure,json}`, `$S/baseline/{checks.json,units.txt,evals.txt,S1.md}`. Scratch is gitignored (`.scratch/`).

**Tool** `tests/drv-diff.sh BEFORE.json AFTER.json [EXPECT]` (T1.1):
```
input   `nix derivation show -r` JSON; top object = (.derivations // .); keys and inputDrvs keys normalised to basenames
name(p) = basename(p) minus "<32 chars>-" and ".drv"
B, A    = key sets; leaves = { d ∈ A∖B | ∀ i ∈ inputDrvs(d): i ∈ B }
per leaf d: c = argmin over { c ∈ B∖A | name(c) = name(d) } of |kinds(c,d)|; none → kind "new"
kinds(c,d) = env:<k> for each key with differing value (union of keys) ∪ inputSrcs (set differs)
           ∪ inputDrvs:+<name> / inputDrvs:-<name> ∪ builder ∪ args ∪ system ∪ outputs
stdout  sorted lines "<name>\t<kind>"; without EXPECT exit 0
EXPECT  file of such lines; exit 0 iff equal as sets; else stderr "UNEXPECTED: …"/"MISSING: …", exit 1
exit 2  usage or unreadable/invalid JSON
```

**Expected-difference list E** (vs B0):

| Probe | E | Reason |
|---|---|---|
| I1 neptun as committed (`rpi.pull` off: `cache = null`) | ∅ (drvPath identical) | no intended change reaches a disabled pull; all moved values are equal; module order preserved (D6) |
| I2 neptun + `rpi.pull.cache = lib-invariant` (pull on) | `unit-rpi-pull.service<TAB>env:<K>` | `--pointer-url` `…/GRBurst/nix-raspi/main/nixos/deploy/neptun.json` → `…/main/deploy/neptun.json` (T0.2); K = the env key holding the unit text, recorded by S1 (expected `text`) |

Every other changed derivation must be an ancestor of a listed leaf (automatic). An unlisted leaf is a defect: fix it (typically list order: module position or `lib.mkBefore`), never extend E silently. A leaf that is intended and unavoidable is reported to the orchestrator with the drv-diff output; main decides, then E and this table are amended.

When it is checked: T0.2 (I1 strong form), T1.1 (both, retroactively for M0), T2.1–T2.6 (`cmp` of drvPaths vs the previous snapshot: neptun untouched), T2.7 (`inv`), T7.4 (`inv` on the integrated main).

## 13. Spikes, risks, unknowns

| # | Unknown | Spike (where, cost) | Fallback |
|---|---|---|---|
| S1 | `nix derivation show -r` JSON shape in 2.34.8 (path or basename keys, inputDrvs shape, unit text env key); eval determinism | T0.1 [mid]: snap twice, `cmp`; record shape and K in `$S/baseline/S1.md` | adapt the normaliser in drv-diff.sh |
| S2 | `nix flake init -t git+file://<root>` with a local template; `nix flake lock --override-input rpi git+file://<root>`; eval of the instance | T5.3 [mid] | `path:` copy of `templates/default` |
| S3 | `nix run --inputs-from . rpi#rpi-ci -- hosts` resolves the locked `rpi` input (git+file) | T5.3 [cheap] | template workflow uses `nix run .#rpi-ci` (re-exported packages; Q2) |
| S4 | SecretSpec: `secretspec` CLI in devenv 2.4 / nixpkgs 26.05; `secretspec.toml` schema; `secretspec run -- env` exports a dotenv value; whether devenv's integration would put values into the store | T5.2 [cheap] | docs use `export VAR=…` / dotenv + `secretspec run` |
| S5 | Firmware attr for Pi 3 Wi-Fi/BT (nvmd or `pkgs.raspberrypiWirelessFirmware`), BT UART needs (nvmd bluetooth module?) | T2.4 Step 0 [cheap]: grep nvmd source (`ev --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.nixos-raspberrypi.outPath'`) | firmware attr from nvmd; BT hardware gap documented |
| S6 | qemu slirp DHCP forward for a DHCP guest (port 22) in `qemu-pi.sh` | T6.1 [expensive] | static test IP via the scratch flake (still template-based) |
| S7 | `mkOverride 49` on `hardware.firmware` vs sd-wear `mkForce [ ]` | T2.4 eval row [cheap] | change sd-wear to `mkDefault [ ]` + check neptun I1 |
| S8 | `actions/upload-artifact` / `download-artifact` commit SHAs | T4.7 [cheap]: `git ls-remote https://github.com/actions/<name> 'refs/tags/v*'` (as in the final review S4) | — |

Risks: R1 root move touches every path (mitigated by P1 strong form + P14). R2 invariant may surface order-only diffs (D6; fix by order). R3 runner may not accept `--option extra-substituters` (not trusted) → builds still succeed from upstream caches, only slower; user verifies AC4. R4 `--inputs-from .` requires the input named `rpi` (template fixes it; README). R5 parallel evals (~1 GB each) in three worktrees; serialise `[mid]` snaps if RAM is short. R6 the user's README change conflicts with M7 (Q1).

## 14. Milestones, dependencies, ownership

```
M0 baseline + root move (serial, first)
 └─ M1 scaffold: drv-diff, rl_hosts/rl_host_info, rpi-ci package + hosts, workflow-lint extraction (serial)
     ├─ M2 library: mkPi, rpi.* modules, hosts/neptun (serial chain T2.1→T2.7) ─┐
     ├─ M3 rpi-deploy host tooling ─────────────────────────────────────────────┤  M2 ∥ M3 ∥ M4 (worktrees)
     └─ M4 CI: rpi-ci, gh, workflows (ours + template) ─────────────────────────┤
                 M5 template + devenv/secretspec (after M2; ∥ M3, M4) ──────────┤
                 M6 qemu smokes (after M2, M3, M4, M5) ─────────────────────────┤
                 M7 docs, personal-values, acceptance, review (after all; Q1) ──┘
```

| M | Owns (creates / modifies / deletes) | Depends | Parallel with |
|---|---|---|---|
| M0 | every tracked `nixos/**` (moved), `flake.nix` (actionlint paths), `configuration.nix` (pointerUrl), `modules/pull-update.nix` (comment/example), `rpi-pull.sh` (comment), `ci/*.sh` (messages), `tests/{ci,deploy}-unit.sh` (repo layout), `tests/{deploy,pull}-smoke.sh` (flake URL), `tests/eval/pull-update.nix` (URLs), `.github/workflows/neptun.yml`, `devenv.nix`, `devenv.yaml` | — | none |
| M1 | `tests/drv-diff.sh`, `tests/drv-diff-unit.sh`, `rpi-lib.sh` (+2 functions), `tests/lib-unit.sh`, `ci/rpi-ci.sh`, `ci/hosts.sh`, `ci/package.nix`, `ci/*.sh` (`--flake` default), `tests/ci-unit.sh`, `flake.nix` (`packages.rpi-ci`, actionlint body → script), `tests/workflows-lint.sh`, `tests/eval/tools.nix` | M0 | none |
| M2 | `lib/**`, `modules/**`, `hosts/**`, `configuration.nix`/`home.nix`/`keys.nix` (moved/deleted), `flake.nix` (`lib`, `nixosModules`, `nixosConfigurations`, eval args), `tests/eval/*` (except tools, template), `tests/fixtures/hosts/**` | M1 | M3, M4 |
| M3 | `rpi-deploy.sh`, `tests/deploy-unit.sh` | M1 | M2, M4, M5 |
| M4 | `ci/**` (incl. deleting `cache-name.sh`), `tests/ci-unit.sh`, `tests/pull-unit.sh` (px1), `rpi-pull.sh` (only if px1 is red), `tests/workflows-lint.sh`, `.github/**`, `templates/default/.github/**` | M1 | M2, M3, M5 |
| M5 | `templates/default/` (except `.github/`), `flake.nix` (`templates`, eval arg `rpiFlake`), `tests/eval/template.nix`, `secretspec.toml`, `devenv.local.nix.example`, `devenv.nix` (secretspec package) | M2 | M3, M4 |
| M6 | `tests/{boot,deploy,pull}-smoke.sh`, `tests/qemu-pi.sh` | M2–M5 | none |
| M7 | `README.md`, `HANDOFF.md`, `flake.nix` (`personal-values`), `tests/personal-values.sh`, leftovers it finds, `devenv.nix` (`rpi-check`, generic) | all | none |

Integration order: M0, M1, then **M2 first** of the parallel group (M3/M4 real evals need its options; `ci/cache-name.sh` reads `keys.nix` until M4 deletes it), then M3/M4 in any order, M5, M6, M7. After each cherry-pick the orchestrator runs `top && nix flake check --no-build --accept-flake-config` `[mid]`.

## 15. Shared interfaces

**`lib.mkPi` (M2; consumed by M5, M6, the template).**
```nix
# lib/mkPi.nix — called in flake.nix as: lib.mkPi = import ./lib/mkPi.nix { inherit inputs; };
{ inputs }: { modules, specialArgs ? { } }:
(inputs.nixos-raspberrypi.lib.nixosSystem {
  inherit (inputs) nixpkgs;
  specialArgs = { inherit inputs; } // specialArgs;
  modules = [ inputs.nixos-raspberrypi.nixosModules.raspberry-pi-3.base
              inputs.self.nixosModules.default inputs.self.nixosModules.terminal ]
    ++ modules
    ++ [ inputs.home-manager.nixosModules.home-manager <HM block, D6> ];
}) // { rpiHost = true; }
```
`nixosModules.default = ./modules/default.nix; nixosModules.terminal = ./modules/profiles/terminal.nix;` `nixosConfigurations.neptun = self.lib.mkPi { modules = [ ./hosts/neptun ]; }; nixosConfigurations.rpi = self.nixosConfigurations.neptun // { rpiHost = false; };` (alias for one release).

**Options (M2).** As in Global Constraints; types in §6. `rpi.pull.cache = lib.mkOption { type = nullOr (submodule { options = { name = mkOption { type = strMatching "[a-z0-9][a-z0-9-]*"; }; publicKey = mkOption { type = strMatching "[^:]+:[A-Za-z0-9+/]{43}="; }; }; }); default = null; }`; it sets `cacheUrl = "https://${name}.cachix.org"`, `cachePublicKey = publicKey` (both `mkDefault`); `pointerUrl` default derived (P4), `defaultText` given. `rpi.deploy.target` `defaultText = literalExpression ''"root@''${config.networking.hostName}"''`.

**Host discovery (M1; consumed by M3, M4).** In `rpi-lib.sh`:
```bash
RL_HOSTS_EXPR='cs: builtins.filter (n: (cs.${n}.rpiHost or false) == true) (builtins.attrNames cs)'
RL_HOST_INFO_EXPR='c: { name = c.config.system.name; target = c.config.rpi.deploy.target; port = c.config.rpi.ssh.port; cache = c.config.rpi.pull.cache; wifi = { inherit (c.config.rpi.wifi) enable networks secretsFile; }; }'
rl_hosts FLAKE          # nix eval --accept-flake-config --json "FLAKE#nixosConfigurations" --apply "$RL_HOSTS_EXPR" | jq -r '.[]' | sort; rc≠0 on eval error
rl_host_info FLAKE HOST # HOST =~ ^[A-Za-z0-9_-]+$ else stderr "invalid host name", return 2 (no nix call);
                        # nix eval --accept-flake-config --json "FLAKE#nixosConfigurations.HOST" --apply "$RL_HOST_INFO_EXPR" (one line JSON)
```

**`rpi-deploy` CLI (M3).**
```
rpi-deploy image   [--out DIR] [--flake DIR] [--host NAME] [--max-builds N]
rpi-deploy flash   IMAGE DEVICE [--wifi-env] [--flake DIR] [--host NAME]
rpi-deploy deploy  [switch|boot|test] [--host NAME] [--target USER@HOST] [--port N] [--flake DIR] [--max-builds N] [--force]
rpi-deploy status  [--host NAME] [--target USER@HOST] [--port N] [--flake DIR]
rpi-deploy secrets [--host NAME] [--target USER@HOST] [--port N] [--flake DIR]
--attr NAME = deprecated alias of --host (stderr "rpi-deploy: --attr is deprecated, use --host")
host:   --host/--attr > $RPI_HOST > the only rl_hosts entry; 0 → exit 2 "no Pi host (lib.mkPi) in FLAKE"; >1 → exit 2 "several Pi hosts: a b; pick one with --host or RPI_HOST"
target: --target > $RPI_TARGET > info.target ;  port: --port > $RPI_PORT > info.port  (rl_host_info only when something is missing or Wi-Fi is needed)
wifi:   info.wifi.enable false → exit 2 "rpi.wifi is disabled for HOST"; networks {} → exit 2 "rpi.wifi.networks is empty for HOST";
        ∀ VAR: unset/empty → exit 2 "missing PSK variable VAR (rpi.wifi.networks.\"SSID\")"; contains LF → exit 2 "VAR contains a newline"
secrets: content on stdin of: ssh -p PORT TARGET "install -d -m 700 $(dirname FILE) && install -m 600 /dev/stdin FILE && systemctl try-restart wpa_supplicant.service"
flash --wifi-env: variables checked before dd; after the read-back verify: part = DEVICE + ("p2" if DEVICE ends in a digit else "2"),
        sudo mount PART MNT (mktemp -d) ; sudo install -D -m 600 -o root -g root /dev/stdin MNT/FILE <content ; sudo umount MNT (also on failure)
```

**`rpi-ci` (M1 dispatcher, M4 behaviour).** Each: `set -euo pipefail`, logs and annotations on stderr, `key=value` on stdout, `--help`, `--flake DIR` default `$PWD`.
```
rpi-ci hosts   [--flake DIR]                                              → hosts=<JSON array>
rpi-ci build   --host H [--flake DIR] [--event NAME] [--update-lock] [--max-builds 500]
                                                                          → top=<path>, name=<system.name> (printed last, after checks)
rpi-ci publish --host H --top TOP [--flake DIR]                           → published=true|false
rpi-ci pointer --host NAME --seq N --rev SHA --file deploy/NAME.json TOP  → changed=true|false   (pointer gains "bootFp")
rpi-ci commit  --message MSG [--artifacts DIR] [PATH...]                  → pushed=true|false
```
Workflow (`.github/workflows/pi.yml`, template identical up to P10):
```yaml
name: pi
on:
  schedule: [{ cron: "17 0 * * 0" }]
  push: { branches: [main], paths-ignore: ["deploy/**", "docs/**", "**.md"] }
  workflow_dispatch: { inputs: { update-lock: { type: boolean, default: false, description: "…" } } }
permissions: { contents: read }
concurrency: { group: pi, cancel-in-progress: false }
jobs:
  hosts:   if main; ubuntu-24.04-arm; checkout(ref: main); install-nix; id: hosts → `nix run .#rpi-ci -- hosts >> "$GITHUB_OUTPUT"`; outputs.hosts
  build:   needs: hosts; if: needs.hosts.outputs.hosts != '[]'; name: build ${{ matrix.host }}; strategy: { fail-fast: false, matrix: { host: ${{ fromJSON(needs.hosts.outputs.hosts) }} } }
           timeout-minutes: 300; steps: checkout(ref: main, fetch-depth: 0); install-nix (nvmd substituter, accept-flake-config);
           id: build → rpi-ci build --host "$HOST" --event "$GITHUB_EVENT_NAME" [--update-lock];
           id: publish (env CACHIX_AUTH_TOKEN, CACHIX_SIGNING_KEY from secrets) → rpi-ci publish --host "$HOST" --top "$TOP";
           id: pointer, if: steps.publish.outputs.published == 'true' → git fetch origin +refs/heads/main:refs/remotes/origin/main >&2; rpi-ci pointer --host "$NAME" --seq "$SEQ" --rev "$(git rev-parse HEAD)" --file "deploy/$NAME.json" "$TOP";
           upload-artifact (name: pi-${{ matrix.host }}, path: flake.lock + deploy/${{ steps.build.outputs.name }}.json, if-no-files-found: ignore)
  commit:  needs: [hosts, build]; if main; permissions: { contents: write }; checkout(ref: main, fetch-depth: 0); download-artifact (path: artifacts);
           install-nix; rpi-ci commit --artifacts artifacts --message "pi: build $SEQ ($GITHUB_EVENT_NAME)"
```
All `uses:` SHA-pinned `@<40 hex> # <tag>`; no `signingKey`/`authToken` under `with:`; `.github/dependabot.yml` (both) updates `github-actions` weekly. Template prefix: `nix run --inputs-from . rpi#rpi-ci --`.

**Pointer (M4).** `{ seq, storePath, narHash, rev, built, bootFp }`; `bootFp` = the 64 hex chars of `rl_fp_local TOP | sha256sum`. rpi-pull reads only its known fields (px1).

---

## 16. Tasks

### M0 — Baseline + root move (serial, first)

#### Task 0.1: Helper and baseline B0 (no commit) `[ ]`
- [ ] Write `/home/pallon/projects/raspberry-pi/.scratch/ci-env.sh` (§0).
- [ ] `. …/ci-env.sh; G worktree add --detach .worktrees/lib-baseline main; G -C .worktrees/lib-baseline rev-parse HEAD > $S/baseline/commit; . …/ci-env.sh $MAIN/.worktrees/lib-baseline/nixos`.
- [ ] S1 `[mid]`: `snap B0-I1 && cp $S/snap/B0-I1.drv $S/baseline/first.drv && snap B0-I1 && cmp $S/baseline/first.drv $S/snap/B0-I1.drv` (determinism); `snap B0-I2 "$I2_OLD"`; record in `$S/baseline/S1.md`: `jq -r 'keys[0]'`, the field names of one entry, the inputDrvs shape, and K = the env keys of the `unit-rpi-pull.service` entry in `B0-I2.json` that contain `--pointer-url`.
- [ ] `ev .#checks.x86_64-linux --apply builtins.attrNames --json > $S/baseline/checks.json`; `for t in tests/*-unit.sh; do echo "$t $(bash $t 2>&1 | tail -n1)"; done > $S/baseline/units.txt`; per `eval-*`: `chk eval-X 2>&1 | grep -o '[0-9]* assertions passed'` → `$S/baseline/evals.txt`.
- [ ] `: > $S/expect/I1.txt; printf 'unit-rpi-pull.service\tenv:%s\n' "$K" > $S/expect/I2.txt`.
- [ ] Done when: all files exist, B0-I1 reproducible, K recorded. Keep the worktree until T7.4.

#### Task 0.2: Move the flake to the root `[ ]`
**Files:** see M0 row (§14).
- [ ] `G worktree add .worktrees/lib-m0 -b lib/m0 main; . …/ci-env.sh $MAIN/.worktrees/lib-m0`.
- [ ] `for e in $(G ls-files nixos | cut -d/ -f2 | sort -u); do G mv "nixos/$e" "$e"; done`; `G ls-files nixos` prints nothing.
- [ ] RED `[cheap]`: `chk actionlint` → evaluation error (`../.github` is outside the flake). Fix, then run the next item; one red at a time in this order: actionlint → `unit ci-unit` → `unit deploy-unit` → `chk eval-pull-update`.
- [ ] GREEN (all fixups, nothing else):
  1. `flake.nix`: actionlint `root = ./.; fileset = ./.github;`.
  2. Pointer location: `configuration.nix` `pointerUrl = "https://raw.githubusercontent.com/GRBurst/nix-raspi/main/deploy/neptun.json"`; `modules/pull-update.nix` comment + `example` → `…/main/deploy/<host>.json`; `rpi-pull.sh` comment `deploy/<host>.json`; `tests/eval/pull-update.nix` URLs `…/main/deploy/neptun.json`.
  3. `ci/*.sh` messages/comments: `nixos/keys.nix` → `keys.nix`, `(nixos/)` → `(the repository root)`. `tests/ci-unit.sh`: seed repo at the root (`$T/seed/flake.lock`, `$T/seed/keys.nix`, `deploy/neptun.json`; every `nixos/` segment removed; c1 greps `keys.nix`). Existing tests change only because the real layout changed; assertions and counts unchanged.
  4. `tests/deploy-unit.sh`: the fixture flake is the repo root (`flake.lock` at top level); same reason, same assertions.
  5. `tests/{deploy,pull}-smoke.sh`: `NIXOS_DIR` → `FLAKE_DIR`; require `FLAKE_DIR` = git toplevel (else exit 2 "run from the repository root"); `inputs.rpi.url = "git+file://$REPO";` (no `?dir=`); pull-smoke calls `$FLAKE_DIR/ci/pointer.sh`.
  6. `.github/workflows/neptun.yml`: delete `defaults.run.working-directory`; `push:` → `branches: [main]`, `paths-ignore: ["deploy/**", "docs/**", "**.md"]`.
  7. `devenv.nix`: `env.RPI_FLAKE = config.devenv.root;`, `$DEVENV_ROOT/rpi-deploy.sh`, `cd "$DEVENV_ROOT"`, `excludes = ["^tests/fixtures/"]`, comments; `devenv.yaml` comment (`flake.nix`).
  8. Remaining hits of `G grep -nE '(^|[^a-z/.])nixos/' -- . ':!docs' ':!README.md' ':!HANDOFF.md'` that name our directory (nixpkgs paths `nixos/modules/…`, `/boot/nixos/`, manual URLs stay).
- [ ] Verify `[mid]`: `G add -A`; `top >/dev/null`; `snap M0-I1 && cmp $S/snap/{B0,M0}-I1.drv` (P1 strong form); `snap M0-I2 "$I2_OLD"` (differs by design; leaves checked in T1.1); `ev .#checks.x86_64-linux --apply builtins.attrNames --json | diff - $S/baseline/checks.json`; unit last lines equal `$S/baseline/units.txt` (paths without `nixos/`); `nix flake check --no-build --accept-flake-config`; `chk actionlint && chk rpi-deploy-syntax && chk rpi-deploy-unit && chk rpi-ci-unit && chk rpi-pull-unit && chk eval-pull-update`; `nix run --accept-flake-config .#rpi-deploy -- --help`.
- [ ] Planted (§9 row 1) seen.
- [ ] Commit "Move the flake from nixos/ to the repository root"; `G show -M --stat HEAD` lists renames.

**M0 acceptance:** I1 drvPath identical, check names and unit counts equal, `nix flake check --no-build` rc 0. Orchestrator cherry-picks; main tree `G status` = ` M README.md` + untracked `nixos/` leftovers.

### M1 — Scaffold (serial)

#### Task 1.1: `tests/drv-diff.sh` + unit test `[ ]`
- [ ] RED: `tests/drv-diff-unit.sh` (harness; synthetic JSON written with `jq -n`; `DD=${DD:-$HERE/drv-diff.sh}`):
  - dd1 identical files → rc 0, empty stdout
  - dd2 chain `unit-x.service → system-units → etc → top`, unit `env.text` changed → stdout exactly `unit-x.service	env:text` (`dd2 only the leaf is reported`)
  - dd3 a new drv `neovim` added as input of `system-path` → `neovim	new`
  - dd4 input `screen` dropped from `system-path` → `system-path	inputDrvs:-screen`
  - dd5 EXPECT equal → rc 0; extra leaf → rc 1 + `UNEXPECTED: …`; expected line absent → rc 1 + `MISSING: …`
  - dd6 two `source` drvs in B∖A, the leaf matches the one with fewer differing keys
  - dd7 path-keyed and basename-keyed inputs (and a `{derivations: …}` wrapper) give the same output
  - dd8 non-JSON input → rc 2
  `unit drv-diff-unit` → fails (script missing).
- [ ] GREEN: `tests/drv-diff.sh` per §12 (one `jq -n --slurpfile` program + bash wrapper).
- [ ] Verify: `unit drv-diff-unit`; `shellcheck -x -P SCRIPTDIR -S warning tests/drv-diff{,-unit}.sh`; `G add`; `chk rpi-drv-diff-unit`.
- [ ] M0 evidence: `bash tests/drv-diff.sh $S/snap/B0-I1.json $S/snap/M0-I1.json $S/expect/I1.txt && bash tests/drv-diff.sh $S/snap/B0-I2.json $S/snap/M0-I2.json $S/expect/I2.txt` rc 0 → `$S/logs/m0-invariant.txt`. If I2 shows another leaf: stop, report (E is wrong or the move leaked).
- [ ] Planted dd2 seen. Commit "tests: drv-diff, root-cause diff of derivation closures (refactor invariant)".

#### Task 1.2: `rl_hosts`, `rl_host_info` `[ ]`
- [ ] RED `tests/lib-unit.sh` (harness, nix mock logging argv, printing `$MOCK_NIX_OUT`, rc `$MOCK_NIX_RC`):
  - lh1 mock `["b","a"]` → stdout `a\nb`; argv has `--json`, `F#nixosConfigurations`, `--apply`, and `rpiHost or false`
  - lh2 `MOCK_NIX_RC=1` → rc ≠ 0, nix's stderr passed through
  - lh3 `rl_host_info F h1` → stdout = mock JSON; argv has `F#nixosConfigurations.h1` and each of `system.name rpi.deploy.target rpi.ssh.port rpi.pull.cache rpi.wifi`
  - lh4 host ∈ {`a.b`, `a b`, `` , `x;y`} → rc 2, stderr `invalid host name`, 0 nix calls
  `unit lib-unit` → `rl_hosts: command not found`.
- [ ] GREEN: §15 functions in `rpi-lib.sh` (after `rl_conf_ref`).
- [ ] Verify: `unit lib-unit`; `chk rpi-lib-unit && chk rpi-deploy-unit && chk rpi-deploy-syntax`. Planted lh4 seen. Commit "rpi-lib: host discovery and host info (rl_hosts, rl_host_info)".

#### Task 1.3: `rpi-ci` package, dispatcher, `hosts` `[ ]`
- [ ] RED:
  - `tests/eval/tools.nix` (`p = packages.x86_64-linux.rpi-ci`): "rpi-ci package ships ci/*.sh, rpi-lib.sh and rpi-fp.sh" (`p.installPhase` hasInfix `libexec/rpi-ci`, `rpi-lib.sh`, `rpi-fp.sh`, and `ci/build.sh` ∈ `p.src` files via `builtins.pathExists (p.src + "/ci/build.sh")`); "rpi-ci wraps cachix, jq and git on PATH" (`p.installPhase` hasInfix `${cachix}/bin`, `${jq}/bin`, `${git}/bin` of x86 pkgs; compare via `builtins.unsafeDiscardStringContext` if `hasInfix` objects to string context).
  - `tests/ci-unit.sh`: r1 `rpi-ci.sh --help` lists `hosts build publish pointer commit`; r2 unknown subcommand → 2; r3 `hosts --flake F` with `rl_hosts` mocked output `neptun` → stdout exactly `hosts=["neptun"]` (`r3 hosts= is a JSON array`); r4 none → `hosts=[]`; r5 `rpi-ci.sh build --x` execs `build.sh --x` (mock log); r6 every CI script without `--flake` uses `$PWD` (run from `$T/repo`).
  `chk eval-tools` red first, then `unit ci-unit`.
- [ ] GREEN: `ci/rpi-ci.sh` (case → `exec bash "$HERE/<script>.sh" "$@"`; `commit` → `commit-push.sh`; `cache-name` kept until T4.7); `ci/hosts.sh` (`rl_hosts` → `jq -Rcs 'split("\n")|map(select(. != ""))'`); defaults `dir=$PWD` in every CI script (tests that relied on `$HERE/..` now pass `--flake` or `cd`: stated in the test comment); `ci/package.nix` `{ lib, stdenvNoCC, makeWrapper, git, jq, coreutils, gnugrep, gnused, findutils, util-linux, cachix }:` with `src = lib.fileset.toSource { root = ../.; fileset = lib.fileset.unions [ ./. ../rpi-lib.sh ../rpi-fp.sh ]; }`; flake `packages.<sys>.rpi-ci = (pkgsFor system).callPackage ./ci/package.nix { };`.
- [ ] Verify `[cheap]`: `chk eval-tools && chk rpi-ci-unit && chk rpi-deploy-syntax`; `nix run --accept-flake-config .#rpi-ci -- hosts` → `hosts=[]` (no mkPi host yet). Planted r3 + eval-tools seen. Commit "rpi-ci: package and dispatcher (hosts|build|publish|pointer|commit)".

#### Task 1.4: Extract the workflow lint (refactor) `[ ]`
- [ ] Before: `chk actionlint` passes; `grep -c 'FAIL:' flake.nix` noted.
- [ ] Change: body verbatim into `tests/workflows-lint.sh` (`w=.github/workflows/neptun.yml` stays); check `src = lib.fileset.toSource { root = ./.; fileset = lib.fileset.unions [ ./.github ./tests/workflows-lint.sh (lib.fileset.maybeMissing ./templates) ]; }`, body `cd $src; bash tests/workflows-lint.sh; touch $out`.
- [ ] After: `chk actionlint` passes; the same FAIL literals are in the script; planted (§9 actionlint T1.4) seen.
- [ ] Commit "flake: actionlint check runs tests/workflows-lint.sh".

**M1 acceptance `[mid]`:** `top && nix flake check --no-build --accept-flake-config`; `snap M1-I1 && cmp $S/snap/{M0,M1}-I1.drv`.

### M2 — Library modules, `mkPi`, `hosts/neptun` (worktree `lib/m2`; serial chain)

Fixtures: `tests/fixtures/hosts/minimal.nix` = `{ rpi.admin.sshKeys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEvalOnlyTestKeyEvalOnlyTestKeyEvalOnly00 eval@test" ]; system.stateVersion = "26.05"; }`. Eval args gain `rpiLib = self.lib; nixosModules = self.nixosModules; fixtures = ./tests/fixtures;`. In each eval file: `t = rpiLib.mkPi { modules = [ (fixtures + "/hosts/minimal.nix") ] ++ extra; }`, `cfg = t.config`, `failedAssertion = sys: s: lib.any (a: !a.assertion && lib.hasInfix s a.message) sys.config.assertions`, `rejects = v: !(builtins.tryEval (builtins.deepSeq v v)).success`. After each task: `snap T2N-I1 && cmp` with the previous I1 drv (neptun untouched until T2.7).

#### Task 2.1: `lib.mkPi`, `nixosModules`, module skeleton `[ ]`
- [ ] RED `tests/eval/lib.nix`: "mkPi returns a nixosSystem marked rpiHost" (`t.rpiHost == true && t ? extendModules`); "mkPi keeps nvmd's kernel (hybrid inputs)" (`cfg.boot.kernelPackages.kernel.outPath == rpi.config.boot.kernelPackages.kernel.outPath`); "mkPi passes specialArgs to modules" (`mkPi { modules = [ minimal ({ marker, ... }: { environment.etc.m.text = marker; }) ]; specialArgs.marker = "x"; }` → `"x"`); "mkPi imports the rpi.* modules" (`t.options.rpi ? headless && t.options.rpi ? pull && t.options.rpi ? sdWear`); "home-manager is wired, no HM users by default" (`t.options ? home-manager && cfg.home-manager.users == { }`); "nixosModules.default and .terminal exist". `chk eval-lib` → evaluation error.
- [ ] GREEN: `lib/mkPi.nix` (§15), `modules/default.nix` (D6 order), stubs `modules/{base,identity,network,wifi,bluetooth}.nix` and `modules/profiles/terminal.nix` = `{ ... }: { }`, flake outputs `lib.mkPi`, `nixosModules.{default,terminal}`, eval args; `G add -N` new files.
- [ ] Verify: `chk eval-lib`; neptun I1 unchanged. Planted (eval-lib) seen. Commit "lib.mkPi and nixosModules.default (library entry point)".

#### Task 2.2: `base.nix`, `identity.nix` `[ ]`
- [ ] RED `tests/eval/identity.nix`: "admin user: normal, wheel, key-only" (isNormalUser, `wheel ∈ extraGroups`, keys = `cfg.rpi.admin.sshKeys`, no password/hashedPassword); "root has exactly the admin keys"; "sshd: rpi.ssh.port only, no passwords, root prohibit-password" (ports = `[ cfg.rpi.ssh.port ]`, also with port 2200); "rpi.admin.user renames the admin" (alice; no `pi` user defined by us); "empty rpi.admin.sshKeys fails an assertion naming the option" (message contains `rpi.admin.sshKeys is empty`); "deploy target follows the hostname" (`root@rpi`; hostName `garden` → `root@garden`; explicit wins); "rpi.ssh.port rejects 0 and 70000".
  `tests/eval/defaults.nix`: "hostname rpi, time zone UTC" ; "kept defaults" (zram 50, gc weekly `--delete-older-than 21d`, extlinux 5, `nix.channel.enable == false`, registry + NIX_PATH, `wheelNeedsPassword == false`, `documentation.enable == false`, `boot.tmp.cleanOnBoot`, `max-jobs == 3`, `cores == 3`, allowUnfree, `daemonIOSchedPriority == 7`, `useNetworkd`); "a host overrides every kept default" (P3: fixture module defining another value for each, plainly; row = `(builtins.tryEval (builtins.deepSeq vs vs)).success && vs == wanted`, so a conflicting plain definition in base prints the FAIL line instead of aborting).
  `chk eval-identity` red first, then `chk eval-defaults`.
- [ ] GREEN: options §6/§15; identity config always on (no enable); base = `lib.mkDefault` for each (if `nixpkgs.config.allowUnfree` rejects `mkDefault`, set `nixpkgs.config = lib.mkDefault { allowUnfree = true; }` and note it).
- [ ] Verify; planted (identity, defaults) seen. Commit "modules: identity (admin, ssh, deploy target) and base defaults".

#### Task 2.3: `network.nix` `[ ]`
- [ ] RED `tests/eval/network.nix`: "dhcp (default): no 10-lan-static; networkd; some network matches ether with DHCP" (property over `attrValues cfg.systemd.network.networks`, not a name); "static: 10-lan-static with Address and Gateway" (`matchConfig.Type == "ether"`, Address = `static.address`, Gateway = `static.gateway`, no `DNS` key); "static with dns sets DNS"; "static without address fails an assertion naming rpi.network.static.address"; "address must be CIDR"; "mode accepts dhcp or static only". `eval-defaults` += "default network is DHCP".
- [ ] GREEN per D8. Verify; planted seen. Commit "modules: network (dhcp default, static)".

#### Task 2.4: `wifi.nix`, `bluetooth.nix`; headless stops touching radios `[ ]`
- [ ] Step 0 (S5, S7) `[cheap]`: find the Pi 3 wireless/BT firmware attr and any nvmd bluetooth module; note in `$S/logs/s5.md`.
- [ ] RED `tests/eval/wifi.nix`: "off: disable-wifi overlay on, no wpa_supplicant, firmware list empty"; "on: overlay gone, wpa_supplicant on, secretsFile /var/lib/rpi/wireless.env"; "every network uses ext:<VAR>, never psk" (P6 over `{ "Home Net" = "RPI_WIFI_HOME"; Lab = "RPI_WIFI_LAB"; }`); "secretsFile is a string outside the store"; "on: Pi 3 wireless firmware despite rpi.sdWear"; "/var/lib/rpi is a 0700 root dir"; "network values must be variable names". `tests/eval/bluetooth.nix`: "off: disable-bt overlay on, bluetooth off"; "bluetooth on: disable-bt overlay gone, hardware.bluetooth on, firmware". `tests/eval/headless.nix`: rows asserting the two overlays move here (stated why: spec §4 headless no longer touches radios); new "headless leaves disable-wifi/disable-bt to rpi.wifi/rpi.bluetooth" (headless on + wifi on → no `disable-wifi`). `eval-defaults` += "Wi-Fi and Bluetooth overlays off".
- [ ] GREEN per D9; overlay definitions copied verbatim from `headless.nix` (`disable-wifi.enable = true`, `disable-bt.enable = true`) under `mkIf (!cfg.enable)`; move the PL011/UART comment to `bluetooth.nix`; **add `./modules/wifi.nix ./modules/bluetooth.nix` to the old `rpi` module list** (after `headless.nix`) so neptun keeps both overlays.
- [ ] Verify: the four eval checks; neptun I1 `cmp` unchanged (the overlay moved modules, config.txt identical). Planted (wifi, bluetooth) seen. Commit "modules: rpi.wifi and rpi.bluetooth (off by default); headless no longer disables radios".

#### Task 2.5: `rpi.pull.repo`, `branch`, `cache` `[ ]`
- [ ] RED `tests/eval/pull-update.nix` (new rows on fixture hosts): "pointer URL derives from repo, branch and hostName" (P4 table incl. hostName ≠ attr); "explicit pointerUrl wins"; "cache sets cacheUrl and cachePublicKey"; "enabled iff repo and cache are set" (P5); "repo must be owner/name".
- [ ] GREEN: options in `modules/pull-update.nix`; `configuration.nix`: `rpi.pull = { repo = "GRBurst/nix-raspi"; cache = keys.cache or null; };` (drop the literal URL and the cacheUrl/key `mkIf`).
- [ ] Verify: `chk eval-pull-update`; `snap2 T25 && cmp $S/snap/{M0,T25}-I1.drv && cmp $S/snap/{M0,T25}-I2.drv`. Planted seen. Commit "pull-update: rpi.pull.repo/branch/cache derive pointer and cache".

#### Task 2.6: Terminal profile `[ ]`
- [ ] RED `tests/eval/terminal.nix` (profile on): "HM user is rpi.admin.user with zsh login shell" (`users.users.${u}.shell` is zsh, `programs.zsh.enable`, `home-manager.users ? ${u}`); "terminal profile follows rpi.admin.user" (alice); "terminalKit on with Pi defaults (osc52, dev packages off, release check off, fzf nushell off)" (HM option values only; never force packages). `eval-defaults` += "no HM users by default".
- [ ] GREEN `modules/profiles/terminal.nix`: option `rpi.profiles.terminal.enable`; `mkIf`: shell, zsh, `home-manager.users.${u} = { programs.terminalKit = { enable = mkDefault true; clipboard = mkDefault "osc52"; packages.dev.enable = mkDefault false; }; home.enableNixpkgsReleaseCheck = mkDefault false; programs.fzf.enableNushellIntegration = mkDefault false; programs.home-manager.enable = mkDefault true; home.stateVersion = mkDefault "26.05"; }`.
- [ ] Verify; planted seen. Commit "modules: rpi.profiles.terminal (home-manager + nix-terminal)".

#### Task 2.7: neptun through `mkPi` (the refactor) `[ ]`
- [ ] RED `tests/eval/lib.nix`: "Pi hosts: neptun only (rpi is an alias)" (P7 over `nixosConfigurations`) → `FAIL` (`[ ]`).
- [ ] GREEN:
  - `G mv configuration.nix hosts/neptun/default.nix; G mv home.nix hosts/neptun/home.nix; G rm keys.nix`.
  - `hosts/neptun/default.nix` = neptun values only (Global Constraints list + EDITOR/SUDO_EDITOR, `programs.screen`, `boot.kernel.sysctl`, `extraGroups = [ "docker" "video" ]`, `rpi.admin.sshKeys = [ "<the key from keys.nix>" ]`, `rpi.pull = { repo = "GRBurst/nix-raspi"; cache = null; }` with the cache comment, `home-manager.users.pi = import ./home.nix;`, `system.stateVersion = "26.05";`); everything now provided by library modules deleted.
  - `flake.nix`: `neptun` via `self.lib.mkPi`, `rpi` alias (§15), old module list removed, eval arg `rpi = self.nixosConfigurations.neptun`.
  - `tests/eval/pi-config.nix`: rows reading `keys.nix` now read `rpi.config.rpi.admin.sshKeys` (stated why: keys.nix removed by spec §7); add "neptun: port 2222, static 192.168.100.20/24 via .1, Europe/Berlin, neo, terminal on, target root@neptun". `tests/eval/pull-update.nix`: `_module.args.rpiKeys` overrides → `rpi.pull.cache = testCache` (same assertions).
- [ ] Invariant `[mid]`: `snap2 T27 && inv T27` rc 0 (I1 drvPath = B0; I2 leaves = E). Otherwise fix order (D6) and repeat; unexplained leaf → stop and report.
- [ ] Verify: `bash -c '. rpi-lib.sh; rl_hosts .'` → `neptun`; all `eval-*`; `nix run .#rpi-ci -- hosts` → `hosts=["neptun"]`; `top && nix flake check --no-build --accept-flake-config`. Planted (`inv`) seen.
- [ ] Commit "neptun: a host module through lib.mkPi (keys.nix and configuration.nix retired)"; save `$S/logs/t27-invariant.txt`.

**M2 acceptance:** all eval checks, `inv T27`, P14 for eval counts.

### M3 — `rpi-deploy` host tooling (worktree `lib/m3`; ∥ M2, M4)

Mocks: `nix` answers `rl_hosts` (`$MOCK_HOSTS`, default `["rpi"]` so existing tests keep `.#nixosConfigurations.rpi`; stated in the mock) and `rl_host_info` (`$MOCK_INFO`, default `{"name":"rpi","target":"root@rpi","port":22,"cache":null,"wifi":{"enable":false,"networks":{},"secretsFile":"/var/lib/rpi/wireless.env"}}`); `sudo` runs its argv; `mount`/`umount` log; `install` mock copies stdin into `$T/root/<path>` and logs mode; `ssh` logs argv and saves stdin to `$T/ssh.stdin`.

#### Task 3.1: Host selection `[ ]`
- [ ] RED: hs1 one host `["neptun"]` → `nixosConfigurations.neptun` in build argv; hs2 `RPI_HOST=b` with hosts `["a","b"]` → b, 0 host listing calls; hs3 hosts `["a","b"]` → exit 2, stderr `several Pi hosts: a b; pick one with --host or RPI_HOST`; hs4 `[]` → exit 2 `no Pi host (lib.mkPi) in`; hs5 `--host x` overrides `RPI_HOST`, no listing; hs6 `--attr x` = `--host x` + deprecation line; hs7 `RPI_HOST=` (empty) → falls back to listing. Existing tests with `--attr` keep passing.
- [ ] GREEN: `resolve_host` (§15). Commit "rpi-deploy: --host / RPI_HOST / the only Pi host".

#### Task 3.2: Target and port from the host `[ ]`
- [ ] RED: tp1 no flags/env → `root@rpi` port 22 from `$MOCK_INFO` (ssh argv `-p 22 root@rpi`); tp2 `RPI_TARGET`/`RPI_PORT` win over info; tp3 flags win over env; tp4 both env set and no Wi-Fi need → 0 `rpi.deploy.target` eval calls; tp5 `RPI_PORT=abc` → exit 2; tp6 usage text no longer names `neptun` or `2222`. Existing status/deploy tests: expectations derive target/port from the mock (stated why: defaults moved into the host config).
- [ ] GREEN. Planted tp2 (§9) seen. Commit "rpi-deploy: target and port from rpi.deploy.target / rpi.ssh.port".

#### Task 3.3: `secrets` `[ ]`
- [ ] RED: sc1 wifi on, networks `{"Home Net":"RPI_WIFI_HOME","Lab":"RPI_WIFI_LAB"}`, both set → `$T/ssh.stdin` = `RPI_WIFI_HOME=…\nRPI_WIFI_LAB=…\n` (P8, sorted), remote command contains `install -m 600 /dev/stdin /var/lib/rpi/wireless.env` and `systemctl try-restart wpa_supplicant.service`; sc2 wifi off → exit 2 `rpi.wifi is disabled for rpi`; sc3 `RPI_WIFI_LAB` unset → exit 2 `missing PSK variable RPI_WIFI_LAB`, 0 ssh; sc4 no PSK value in `$MOCK_LOG` (`sc4 PSK values never in argv`) and none on stdout/stderr; sc5 value with LF → exit 2 `contains a newline`; sc6 empty networks → exit 2.
- [ ] GREEN: `wifi_env_content HOSTINFO` (stdout = content; used by T3.4), `do_secrets`. Planted sc4 seen. Commit "rpi-deploy secrets: Wi-Fi PSKs from the environment to the Pi".

#### Task 3.4: `flash --wifi-env` `[ ]`
- [ ] RED: fw1 success → after the verify: `sudo mount <dev>2`, `install -D -m 600 -o root -g root /dev/stdin <mnt>/var/lib/rpi/wireless.env` with content = P8, `umount`; `mmcblk0` → `mmcblk0p2`; fw2 missing variable → exit 2 before any `dd` (`fw2 missing PSK -> exit 2 before dd`); fw3 install fails → `umount` still called, exit ≠ 0; fw4 without `--wifi-env` → no mount (existing flash tests unchanged); fw5 PSKs never in argv.
- [ ] GREEN. Planted fw2 seen. Commit "rpi-deploy flash --wifi-env: Wi-Fi secrets onto the card".

**M3 acceptance `[cheap]`:** `unit deploy-unit && chk rpi-deploy-unit && chk rpi-deploy-syntax`; after M2 is on main: `nix run .#rpi-deploy -- status --help` and `RPI_TARGET=x RPI_PORT=1 …` paths sanity.

### M4 — CI (worktree `lib/m4`; ∥ M2, M3)

#### Task 4.1: `ci/gh.sh` `[ ]`
- [ ] RED ci-unit: gh1 `GITHUB_ACTIONS` unset: each helper → no `^::` line on stdout/stderr, `$GITHUB_STEP_SUMMARY` file not created, notice prints `rpi-ci: notice: m` (`gh1 no :: lines outside GitHub Actions`); gh2 `=true`: `::notice::m`, `::warning::m`, `::error file=f,line=3::m`, `::group::t`…`::endgroup::`, `gh_summary <<<'x'` appends; gh3 escaping of `%`, CR, LF.
- [ ] GREEN per D17. Commit "ci: GitHub annotations and step summaries (only under GitHub Actions)".

#### Task 4.2: `rpi-ci build --host` `[ ]`
- [ ] RED: b-host `--host` required (exit 2); `RL_ATTR` = host in guard and build argv; outputs `top=` then `name=` (from host info) as the last stdout lines; b-sub cache set → build argv has `--option extra-substituters https://<n>.cachix.org` and `--option extra-trusted-public-keys <k>`, none when null; b-chk checks `["x","y"]` for the current system → `nix build …#checks.<sys>.x` and `.y` after the toplevel; a failing check → rc ≠ 0 and no `top=`; no checks → notice `no checks for <sys>`; b-sum (`GITHUB_ACTIONS=true`) summary has `## <host>: build`, nixpkgs and nixos-raspberrypi revs, `toplevel`, `closure`; with `--update-lock` and a changed lock `lock: updated` + old→new revs; guard failure → `::error` line; b-grp the toplevel build's log lies between `::group::build <host>` and `::endgroup::`. Existing b1–b7 adapted to `--host` (stated why).
- [ ] GREEN. Commit "rpi-ci build: per host, own cache as substituter, flake checks, summary".

#### Task 4.3: `rpi-ci publish` `[ ]`
- [ ] RED: pb1 cache null → rc 0, stdout `published=false`, notice `no cache configured for <host>: built and tested, not published`, 0 cachix (`pb1 …`); pb2 cache set, `CACHIX_AUTH_TOKEN` unset → rc 1, `::error::CACHIX_AUTH_TOKEN is not set` (with `GITHUB_ACTIONS=true`), 0 cachix; pb3 same for `CACHIX_SIGNING_KEY`; pb4 both set → `cachix push <n> TOP` then `cachix pin <n> <name> TOP --keep-revisions 4`, `published=true`; pb5 push fails → no pin, rc ≠ 0; pb-sum summary `## <host>: publish` with cache and closure size or `skipped: no cache configured (rpi.pull.cache)`. Old u1–u3 replaced by pb4/pb5 (CLI changed from positional `CACHE TOP`).
- [ ] GREEN. Planted pb1, pb2 seen. Commit "rpi-ci publish: cache from rpi.pull.cache; notice without, error on missing secrets".

#### Task 4.4: `rpi-ci pointer` (`--host` required, `bootFp`) `[ ]`
- [ ] RED: pt1 pointer has `bootFp` = sha256 of `rl_fp_local TOP` (fixture toplevel via `make_sys`); pt2 summary `boot: unchanged → the Pi switches` / `changed → the Pi reboots at rpi.pull.rebootTime` / `unknown (no previous pointer)` vs the origin/main pointer; pt3 no `--host` → exit 2; pt4 workflow-style call `--host garden --file deploy/garden.json` with a `nixos-system-garden-…` TOP → file `deploy/garden.json`. pull-unit px1 pointer with `bootFp` and `x` → applies (`px1 extra pointer fields are ignored`); if red, make rpi-pull ignore unknown keys (only that change).
- [ ] GREEN. Commit "rpi-ci pointer: host required, boot fingerprint in the pointer and summary".

#### Task 4.5: `rpi-ci commit --artifacts` `[ ]`
- [ ] RED (real git, bare origin): k1 artifacts `a/` (lock L, `deploy/a.json`) and `b/` (lock L, `deploy/b.json`) → one commit on origin main changing exactly `deploy/a.json deploy/b.json` (+ `flake.lock` if L differs from HEAD), `pushed=true` (P11); k2 locks differ → rc 1, `lock differs between hosts`, origin unchanged (`k2 …`); k3 empty dir → `pushed=false`; k4 artifact with only a lock (cache-less host, updated lock) → commit of `flake.lock` only. g1–g5 unchanged.
- [ ] GREEN. Planted k2 seen. Commit "rpi-ci commit: one commit of the lock and all pointers".

#### Task 4.6: `rpi-ci hosts` notice `[ ]`
- [ ] RED hs1 `hosts=[]` → notice `no Pi hosts (lib.mkPi) in nixosConfigurations`. GREEN. Commit "rpi-ci hosts: notice when there is nothing to build" (may be folded into T4.1's commit if trivial).

#### Task 4.7: Workflows, template workflow, lint, cleanup `[ ]`
- [ ] RED `tests/workflows-lint.sh` for `W=(.github/workflows/pi.yml templates/default/.github/workflows/pi.yml)`: actionlint both; P10 `FAIL: pi.yml is not the template's workflow with the local rpi-ci`; build job order `rpi-ci -- build` < `rpi-ci -- publish` < `rpi-ci -- pointer` < `upload-artifact`; commit job `download-artifact` < `rpi-ci -- commit` and `needs:` contains `build`; `if: github.ref == 'refs/heads/main'` on `hosts` and `commit`; workflow `permissions` `contents: read` and `contents: write` only in `commit` (`FAIL: only the commit job may write`); `name: build ${{ matrix.host }}`; pointer step `if: steps.publish.outputs.published == 'true'`; SHA pins + `# tag`; no `signingKey|authToken`; dependabot github-actions in both; no `working-directory`. With `G mv .github/workflows/neptun.yml .github/workflows/pi.yml` alone → `chk actionlint` red.
- [ ] GREEN: both workflows (§15), template `.github/dependabot.yml`, SHAs via S8; `G rm ci/cache-name.sh`, drop c1/c2 (stated why: the cache is per host in `rpi.pull.cache`; covered by pb*); dispatcher drops `cache-name`.
- [ ] Manual `[cheap]` (after M2 on main): `GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY=$S/logs/sum.md nix run .#rpi-ci -- publish --host neptun --top /nix/store/$(printf 'a%.0s' $(seq 32))-nixos-system-neptun-x` → notice line, `published=false`, rc 0, summary section.
- [ ] Planted P10, D15 seen. Commit "ci: host-matrix workflow pi.yml (ours and the template's), one commit job".

**M4 acceptance `[cheap]`:** `unit ci-unit && unit pull-unit && chk rpi-ci-unit && chk rpi-pull-unit && chk actionlint && chk rpi-deploy-syntax`.

### M5 — Template and devenv (worktree `lib/m5`; after M2)

#### Task 5.1: `templates/default` + `eval-template` `[ ]`
- [ ] RED `tests/eval/template.nix` with `tf = import ../../templates/default/flake.nix; tpl = tf.outputs { self = tpl; rpi = rpiFlake; }; h = tpl.nixosConfigurations.rpi; hk = h.extendModules { modules = [ (fixtures + "/hosts/minimal.nix") ]; };` (eval arg `rpiFlake = self`): "template input is rpi = github:GRBurst/nix-raspi"; "template nixConfig equals ours (nvmd cache)"; "template host is a Pi host through lib.mkPi"; "template default: DHCP, port 22, Wi-Fi and Bluetooth off, hostname rpi, pull off" (P13 on `hk`); "with a key, no failed assertion"; "without a key the sshKeys assertion fires" (`h`); "template re-exports apps and packages of rpi"; "templates.default points at templates/default with a description".
- [ ] GREEN: `templates/default/flake.nix` (inputs.rpi, nixConfig, outputs per D22), `hosts/rpi.nix` (sshKeys `[ ]` + comments for every option, `system.stateVersion = "26.05"`), `README.md` (short: init, fill key, `nix run .#rpi-deploy -- image|flash|deploy`, pointer to the main README); flake `templates.default = { path = ./templates/default; description = "Raspberry Pi 3 host on the nix-raspi library"; welcomeText = …; }`.
- [ ] Verify `chk eval-template`; `nix flake check --no-build` (checks `templates`). Planted seen. Commit "templates.default: a Pi host on lib.mkPi".

#### Task 5.2: devenv, SecretSpec `[ ]`
- [ ] Step 0 S4 `[cheap]`: record in `$S/logs/s4.md`.
- [ ] RED rows (`eval-template`): "secretspec.toml declares RPI_WIFI_HOME (optional), root and template" (`fromTOML`); "devenv.local.nix is gitignored (root, template)"; "devenv.local.nix.example sets RPI_HOST and shows RPI_TARGET, RPI_PORT (root, template)" (import → function; `(f { }).env ? RPI_HOST`; `hasInfix "RPI_TARGET"` and `"RPI_PORT"` in the text).
- [ ] GREEN: root `secretspec.toml`, `devenv.local.nix.example`; template copies + `devenv.nix` (`env.RPI_FLAKE = config.devenv.root;` `scripts.rpi-deploy.exec = ''nix run "$DEVENV_ROOT#rpi-deploy" -- "$@"'';`), `devenv.yaml` (nixos-26.05), `.gitignore` (`devenv.local.nix`, `.devenv*`, `result*`); root `devenv.nix` gains `secretspec` if S4 found it in nixpkgs.
- [ ] Commit "devenv: secretspec.toml and devenv.local.nix.example (root and template)".

#### Task 5.3: Spikes S2/S3 (no commit unless a fix in owned files) `[ ]`
- [ ] `[mid]` in `$S/tpl` (fresh): `nix flake init -t "git+file://$MAIN/.worktrees/lib-m5"`; `git init`; key into `hosts/rpi.nix`; `G add -A`; `nix flake lock --override-input rpi "git+file://$MAIN/.worktrees/lib-m5"`; `nix eval --raw .#nixosConfigurations.rpi.config.system.build.toplevel.drvPath` rc 0; `nix run --inputs-from . rpi#rpi-ci -- hosts` → `hosts=["rpi"]`; `nix run .#rpi-deploy -- --help` rc 0. Log `$S/logs/s2-s3.md`. Failure → apply the §13 fallback, record as an assumption change.

### M6 — qemu smokes (after M2–M5; clean worktree `lib/m6`)

#### Task 6.1: boot-smoke on the template default host `[ ]`
- [ ] Change `tests/boot-smoke.sh`: build a template instance in `$WORK/tpl` exactly as T5.3 (key = the smoke key), image via `rpi-deploy image --flake "git+file://$WORK/tpl" --host rpi`; guest SSH port 22, login prompt `rpi login:`; `tests/qemu-pi.sh`: `RPI_SMOKE_GUEST_IP` (default `192.168.100.20`; empty → slirp's first DHCP lease, S6).
- [ ] RED `[expensive ~40 min cold]`: planted `RPI_SMOKE_GUEST_SSH_PORT=2222` → FAIL at SSH. GREEN: PASS (login prompt + SSH banner on 22). Commit "tests: boot-smoke boots the template's default host (DHCP, port 22)".

#### Task 6.2: deploy-smoke, pull-smoke on neptun `[ ]`
- [ ] Change: `--attr` → `--host`; `rpi.nixosConfigurations.rpi` → `.neptun`; pointer via `bash "$FLAKE_DIR/ci/pointer.sh" --host neptun …`. `[expensive ~20 + ~30 min]` both PASS (pull-smoke also RED with `RPI_PULL_SMOKE_PLANT=1` as before). Commit "tests: deploy-smoke and pull-smoke on the library".

### M7 — Docs, personal values, acceptance, review (after all)

#### Task 7.1: `personal-values` check `[ ]`
- [ ] RED: `tests/personal-values.sh` (patterns `neptun`, `\b2222\b`, `192\.168\.100\.`, `GRBurst/nix-raspi` minus `github:GRBurst/nix-raspi`, `Europe/Berlin`, `"neo"`, the key's base64 prefix, `pallon`, `andromeda`; output `FAIL: personal value in library code:` + `file:line:text`; `flake.nix` allowlist: lines matching `nixosConfigurations\.neptun|neptun = |\./hosts/neptun`); flake check `personal-values` (x86_64, src = D23 fileset with `maybeMissing`). Planted (§9) red.
- [ ] GREEN: fix every real hit (comments in `rpi-deploy.sh`, `ci/*.sh`, `modules/*.nix`, `flake.nix`; if `rpi-pull.sh` defaults `--host` to `neptun`, the option becomes required and `tests/pull-unit.sh` passes it explicitly, stated why: the module always passes `config.system.name`); review `G grep -n -E 'neptun|2222|192\.168\.100\.' -- tests` (only neptun-specific tests). Commit "checks: no personal values in library code".

#### Task 7.2: README (consumer first) `[ ]`
- [ ] Precondition Q1 (the user's README change is committed or handed over). Rewrite in the §8 order: what it is → quick start (`nix flake init -t github:GRBurst/nix-raspi`, host file, `rpi-deploy image`/`flash`, first boot, `deploy`) → configuration (`rpi.*` table = Global Constraints; Wi-Fi + `secretspec run -- rpi-deploy secrets`) → updates (push vs pull; cache + CI secrets; `rpi.pull.repo`/`cache`) → caching (§8 content verbatim facts: nvmd cache, cache.nixos.org, ~16 derivations, overlays, 1.1 GB eval, trusting our key is opt-in) → troubleshooting → our neptun (example section) → development (devenv, tests, layout, `.scratch` helper) last. Note for build-host users: `rpi.buildHost.flakePath` → the repo root.
- [ ] Commit "README: consumer first (library, template, options, updates, caching)".

#### Task 7.3: HANDOFF, devenv leftovers `[ ]`
- [ ] `devenv.nix` `rpi-check` warms up every Pi host generically (`for h in $(bash -c '. ./rpi-lib.sh; rl_hosts .'); do nix eval --raw --accept-flake-config ".#nixosConfigurations.$h.config.system.build.toplevel.drvPath" >/dev/null; done`; no host name in devenv.nix, `personal-values` stays green); HANDOFF: header (this spec/plan), status table M0–M7, decisions D1–D25 short, user actions (spec §10 + push + AC4 checklist + `flakePath` + optional removal of `nixos/` leftovers + Wi-Fi/BT hardware checklist §10.2), gotchas (new helper). Commit "HANDOFF: reusable library".

#### Task 7.4: Final acceptance `[ ]`
- [ ] AC1 `[expensive]`: `top && nix flake check --accept-flake-config -L 2>&1 | tee $S/logs/flake-check.log` rc 0; P14 vs `$S/baseline`.
- [ ] AC3 `[mid]`: on integrated main `snap2 FINAL && inv FINAL` rc 0 → `$S/logs/final-invariant.txt`.
- [ ] AC2/AC5: T5.3, T6.1, T6.2 logs. `G log --merges <M0 base>..main` empty. HANDOFF acceptance table filled; remove `.worktrees/lib-baseline`. Commit "HANDOFF: acceptance of the reusable library".

#### Task 7.5: Final whole-branch review `[ ]`
- [ ] Review required: `review` card, Opus (`model: "anthropic/claude-opus-5-5"`), diff `<M0 base>..main`, with the spec, this plan §3, §4, §8, §9, §12, and the Review Focus list; README against §8. Findings: one commit each, test first; unfixed ones to HANDOFF with a reason.

---

## 17. Assumptions (simplest reading where the spec is silent or ambiguous)

A1 Root move = tracked `nixos/**` only; untracked `nixos/` caches/evidence stay, the helper uses them by absolute path (D1). A2 Pointer moves to `deploy/neptun.json` in the move commit (it is relative to the flake/workflow dir). A3 I1 expected list is empty; the spec's "at least the pointer URL" only shows with pull on (I2), because `cache = null` disables pull. A4 `modules/base.nix` added; `daemonIOSchedPriority = 7` and `i18n.defaultLocale` are library defaults (D4). A5 `system.stateVersion` is set by hosts/template, not the library. A6 `nixosModules.default` excludes the terminal profile (D5). A7 DHCP mode relies on NixOS's default DHCP network (D8). A8 Wi-Fi/BT firmware added at priority 49 over sd-wear (D9); BT UART attach on hardware is unverified. A9 Pointer/pin keyed on `system.name` (D11). A10 CI: cachix-action dropped (D13); lock update per matrix job + equality check (D14); commit only when all builds succeed; checks of the flake inside `build` (D16); `bootFp` pointer field (D18). A11 Template: `hosts/rpi.nix`, re-exports `apps`/`packages`, minimal devenv files (D22). A12 `personal-values` scope (D23). A13 `rpi` alias marked `rpiHost = false`; removal is a later release. A14 `--attr` kept as a deprecated alias of `--host`. A15 Secrets file uses the env variable names as keys; `wpa_supplicant.service` is restarted. A16 Workflow trigger `paths-ignore` (D20). A17 Our `secretspec.toml` declares `RPI_WIFI_HOME` (the template example's variable), since neptun has Wi-Fi off.

## 18. Open questions (defaults used if unanswered)

1. **Q1 README.** The user's uncommitted `README.md` change blocks M7's cherry-pick. Default: the orchestrator asks the user to commit it (or hand it over) before T7.2; M7 builds on it.
2. **Q2 Template devenv.** The spec lists only `devenv.local.nix.example`; the plan adds `devenv.nix`, `devenv.yaml`, `.gitignore`, `secretspec.toml` to the template. Default: yes (minimal).
3. **Q3 `nixosModules.terminal` split** (D5). Default: yes.
4. **Q4 cachix-action dropped**, our cache via `--option extra-substituters` (D13, R3). Default: yes; fallback a conditional cachix-action.
5. **Q5 Matrix lock handling** (D14): per-job update + equality check; no commit if any host fails. Default: yes.
6. **Q6 Pointer `bootFp` field** (D18) vs dropping the "fingerprint changed" summary line. Default: add the field.
7. **Q7 Names from `system.name`** for pointer file and pin (D11). Default: yes.
8. **Q8 `personal-values` scope** (D23): library paths + flake.nix allowlist; tests checked by hand. Default: yes.
9. **Q9 SecretSpec transport** `secretspec run -- rpi-deploy …` rather than devenv's `env.*` integration (D21, S4). Default: yes.
10. **Q10 Template host name** `rpi` (`hosts/rpi.nix`). Default: yes.
