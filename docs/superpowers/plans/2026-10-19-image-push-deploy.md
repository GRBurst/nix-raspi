# Image-push deploy (Pi 3B "neptun") Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan milestone by milestone. Steps use checkbox (`- [ ]`) syntax for tracking. Every task starts at status `[ ]` (todo).

**Goal:** One NixOS configuration `rpi` yields both the SD image (flashed once) and every later push deploy from the x86_64 host. A weekly host timer pushes security updates without ever compiling a kernel.

**Architecture:** The flake uses "hybrid" inputs. Our `nixpkgs` (nixos-26.05 head) drives userspace. nvmd (`develop`) keeps its own nixpkgs pin, so kernel and firmware hit nvmd's cachix. `config.system.build.sdImage` comes from `rpi` itself. The host-side bash tool `rpi-deploy` (image/flash/deploy/status) and `rpi-autoupdate` share the guard library `rpi-lib.sh`, and both run the flake-pinned `nixos-rebuild` 26.05 with `--no-reexec`. The Pi config gets small modules: `sd-wear`, `headless`, `external-storage`.

**Tech stack:** Nix flakes (Nix 2.34.8), NixOS 26.05 module system, nvmd/nixos-raspberrypi, home-manager, bash + shellcheck, `nixos-rebuild-ng` 26.05, qemu `raspi3b` (smoke tests).

**Spec:** `docs/superpowers/specs/2026-10-19-image-push-deploy-design.md` (read it fully). Evidence: `nixos/.scratch/{e2,e3,s5,s6}/REPORT.md`.

---

## 0. Ground rules for every implementer

```bash
# Every command in this plan assumes:
cd /home/pallon/projects/raspberry-pi/nixos
export XDG_CACHE_HOME=$PWD/.cache-nix NIXPKGS_CONFIG=$PWD/.nixcache/nixpkgs-config.nix
chk() { nix build --accept-flake-config --no-link -L ".#checks.x86_64-linux.$1"; }   # build one check
ev()  { nix eval  --accept-flake-config "$@"; }
R=.#nixosConfigurations.rpi.config
mkdir -p .scratch/plan   # scratch output; /tmp is not writable for some paths in this sandbox
```

- **New files are invisible to the flake until staged.** The flake is `git+file`, so run `git add <file>` (or `git add -N`) right after you create a file. If you skip this, `nix` reports "path does not exist", or worse, a check silently runs without your file.
- **Commits fail in this sandbox** (gpg signing). Every "Commit" step means `git add` the listed files and leave the commit to the user. Do not bypass signing.
- **Cost classes.** `[cheap]` takes ≤ 2 min (eval, eval checks, bash unit tests, `--dry-run`). `[expensive]` is an aarch64 build or a qemu run, with its duration stated. Never put an expensive step in a RED/GREEN loop. Run it once, at the stated acceptance point.
- **One failing check at a time.** Each RED names the single check that must fail and the text it must print.
- **Planted violations.** Every new check is made to fail once on purpose (§11). Tick the box only after you have seen the red.

## 1. Motivation

The Pi 3B (1 GiB RAM, SD card) cannot evaluate its own flake (1.08 GB RSS). Today it is installed through a chroot/binfmt `nixos-install` flow that needs root mounts and an F-flag handler. The spec replaces that flow:

- Build one SD image on the host and write it once.
- After that, push every change from the host with the `nixos-rebuild` that matches the Pi's release.
- Apply security updates weekly and automatically, guarded so that no kernel is ever compiled and the Pi is never touched when something fails.
- Reduce SD writes where the evidence shows a benefit, and allow a USB data disk to be added later by configuration only.

## 2. Approach (shape of the diff)

- `flake.nix`:
  - `nixpkgs` becomes its own input. nvmd moves to `develop` without `follows`. `rpi` is built with `nixos-raspberrypi.lib.nixosSystem { inherit nixpkgs; … }`.
  - `rpi` imports `modules/sd-image.nix` (the former `rpi-image` inline module), `modules/{sd-wear,headless,external-storage}.nix` and `configuration.nix`.
  - The outputs `rpi-image` and `rpi-image-nvmd` are removed. `neptun` stays an alias of `rpi`.
  - Eval-level checks are auto-discovered from `tests/eval/*.nix`. Each file is an attrset `"<message>" = <bool>` and becomes the check `eval-<file>`.
  - New outputs: `apps/packages.x86_64-linux.nixos-rebuild` (pinned, 26.05). The `rpi-deploy` package ships `rpi-deploy`, `rpi-autoupdate` and `rpi-lib.sh`. `rpi-binfmt` and the F-flag contract are removed.
- `configuration.nix`:
  - root login becomes key-only, and `sudo` no longer asks `pi` for a password.
  - Removed: autoUpgrade, wifi, iwd, firmware lines, `cma`, the dead journald block, the duplicated fileSystems and the commented `/external` block.
  - Added: extlinux `configurationLimit = 5`, GC weekly/21d, `nix.channel.enable = false`.
  - Keys move into `keys.nix`.
- New Pi modules. Each is enabled by default except `external-storage`, which is disabled by default:
  - `rpi.sdWear.enable`
  - `rpi.headless.enable`
  - `rpi.storage.external.*`
- Scripts move into `nixos/`:
  - `rpi-deploy.sh` is a rewrite, about 300 lines.
  - `rpi-lib.sh` holds the guards, the ssh helpers and the reboot decision.
  - `rpi-autoupdate.sh` is the timer job.
  - Tests: `tests/harness.sh`, `tests/deploy-unit.sh` (replaced), `tests/autoupdate-unit.sh`, and real `nix build --dry-run` fixtures from s5.
- `modules/build-host.nix` drops the static-emulator default and gains `rpi.buildHost.autoUpdate` (a systemd timer and a oneshot service).
- `tests/qemu-pi.sh` is extracted from `boot-smoke.sh`. `boot-smoke.sh` gains an SSH check over usb-net, and `tests/deploy-smoke.sh` is new. README and HANDOFF are rewritten for the new flow.

## 3. Decisions

| # | Decision | Rationale | Rejected alternative (why) |
|---|---|---|---|
| D1 | `boot.loader.generic-extlinux-compatible.configurationLimit = 5` | Verified in the pinned sources. nvmd's uboot path (`loader/raspberrypi/default.nix:144,557`) enables generic-extlinux and calls its `populateCmd`, which carries `-g <limit>` (nixpkgs `generic-extlinux-compatible/default.nix:108,125`). | `boot.loader.raspberry-pi.configurationLimit` (s6 #8): its description says "Used only by `kernel` bootloader!", so it has no effect with U-Boot. |
| D2 | Start M1 from the measured s5 lock: `cp .scratch/s5/devhy/flake.lock flake.lock` (nixpkgs `da6dc0e7b2`, nvmd develop `747895cf18`) | The measured result is known: 377 builds, kernel `30kd6a67…-6.18.52` returned 200 from cachix (re-verified 2026-10-22). | A fresh `nix flake update` could land on an uncached develop HEAD (the 09-20 window in s5). |
| D3 | Eval checks as files `tests/eval/<name>.nix` → `checks.x86_64-linux.eval-<name>`, auto-discovered | M2, M3, M4 and M6 add checks without touching `flake.nix`, which keeps the parallel milestones on disjoint files. | One check list inside flake.nix (every milestone would edit flake.nix). |
| D4 | M1 creates stub modules `sd-wear.nix`, `headless.nix`, `external-storage.nix` (`{ ... }: { }`) that are already imported by `rpi` | Same reason as D3: M3 and M4 then only fill in their own files. | M3/M4 edit the module list in flake.nix (conflicts). |
| D5 | Scripts flat in `nixos/`: `rpi-deploy.sh`, `rpi-lib.sh`, `rpi-autoupdate.sh` | The spec says the script "moves into nixos/", and flake.nix already references `./rpi-deploy.sh`. The shared lib serves two entry points. | `rpi-deploy autoupdate` subcommand (the spec fixes exactly 4 subcommands); duplicated guards (DRY). |
| D6 | Build guard regex applied to the **derivation name** of the "will be built" section only: `^(linux_rpi-.*[0-9]\|linux-[0-9].*\|linux-config-.*\|kernel-intermediate-config.*\|(gcc\|llvm\|rustc\|ghc\|nodejs)-[0-9].*)$` | Verified on the s5 fixtures: devhy/hy/dev pass (377/379/377 builds, none forbidden); np fails on `kernel-intermediate-config`, `linux-config-6.18.34…` and `linux_rpi-bcm2711-6.18.34…`. | The s5 sketch regex over raw lines: it false-positives on `initrd-linux_rpi-…6.18.52-unstable_20260915.drv` (built in every hybrid run), and run over the whole output it also matches fetched `gcc-15.3.0`. |
| D7 | The deploy tool is resolved at run time: `$RPI_NIXOS_REBUILD`, otherwise `nix run --accept-flake-config "$FLAKE#nixos-rebuild" --` | The tool always matches the release of the flake being deployed (E3: the host's 26.11 tool half-applies). | Baking a path into the host package (it goes stale when the flake moves to 26.11). |
| D8 | `rpi.buildHost.autoUpdate.sshPort` (default 2222) is added to the spec's option set | The Pi's sshd listens on 2222. A systemd service must not depend on the user's `~/.ssh/config`. | Relying on `~/.ssh/config` (implicit, not visible in eval). |
| D9 | Autoupdate ssh uses `-o UserKnownHostsFile=$workDir/known_hosts -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -i $sshKey` | It works unattended. After a re-flash (new host key) the user deletes one file, which README documents. | `StrictHostKeyChecking=no` (MITM). |
| D10 | The autoupdate branch is force-pushed: `git push --force origin HEAD:refs/heads/auto-update`; commits use `-c commit.gpgsign=false -c user.name=rpi-autoupdate -c user.email=rpi-autoupdate@localhost` | Each run is `main + 1 lock commit`, so the branch is not fast-forwardable between runs. An unattended job cannot sign. | Fast-forward-only push (fails after every unmerged run). See Q5. |
| D11 | `nixos/keys.nix` = `{ user; autoUpdate ? null; hostAddress ? null; }`. `root` keys are `[user] ++ optional (autoUpdate != null) ''from="${hostAddress}" ${autoUpdate}''` | The key and the address are unknown today (Q1). The eval check enforces the `from=` property for any key that is not the user key. | Hard-coding a placeholder key (an unusable key ends up on the card). |
| D12 | Keep `hardware.enableAllHardware = true`, which comes from nixpkgs `sd-image.nix` | Parity with the image that booted and deployed in E3. `mkForce false` in sd-wear already removes the firmware it implies. | `mkForce false` (initrd differs from the E3-tested image; see Q3). |
| D13 | `cma=32M` removal and the dead journald block are owned by **M2** (configuration.nix) | File ownership keeps M2 and M3 disjoint. M3's checks assert only what M3's own modules define. | M3 editing configuration.nix (parallel conflict). |
| D14 | `/boot/firmware` keeps `mkForce [ "fmask=0077" "dmask=0077" ]` (as in today's `rpi-image`) | Parity with the installed `rpi`. Without it, sd-image.nix's `noauto` would apply and nvmd's bootloader install on switch needs the partition mounted. | nvmd's automount options (untested here). |
| D15 | Flash verification compares sha256 of `zstdcat IMG` with sha256 of the first `len` bytes read back from DEVICE | This is what the spec asks for. Cost: one extra read pass, about 6 GB. | Partition-table-only check (weaker). |
| D16 | Run `shellcheck -S warning` on the new scripts inside the existing `rpi-deploy-syntax` check | This is the "type checker" layer for bash. | `bash -n` only (misses unset vars, quoting bugs). |

## 4. Gate

There is no principles document in the repo, so each spec invariant (§1, §4, §9) is a gate row.

| Row | Invariant | Result | Enforced by |
|---|---|---|---|
| G1 | The Pi never evaluates the flake (no autoUpgrade, no `/etc/nixos`, no wifi secrets file) | PASS | `eval-pi-config` |
| G2 | No local kernel build (kernel = nvmd's, cache guard, build guard) | PASS | `eval-kernel`, `rpi-deploy-unit` guard tests, `autoupdate-unit` |
| G3 | Any guard or build failure exits non-zero **before** the first ssh / nixos-rebuild call | PASS | unit tests assert 0 `ssh` / `nixos-rebuild` lines in the mock log on each failure path |
| G4 | `boot` before `switch`. Kernel/initrd/modules change ⇒ reboot instead of switch | PASS | `autoupdate-unit` call-order tests |
| G5 | One definition: image = `rpi.config.system.build.sdImage`, deploy = `.#rpi` | PASS | `eval-image` |
| G6 | The deploy tool is the flake-pinned 26.05 one. The host's `nixos-rebuild` is never called | PASS | poison `nixos-rebuild` in the mock PATH (M5 T5.7) |
| G7 | sudo is used only for the device write and the device read-back | PASS (the spec says "only privileged step"; reading a raw device also needs root, so read-back is a second sudo call) | `rpi-deploy-unit` flash tests grep the mock sudo log |
| G8 | Store/boot integrity: no `fsync-metadata=false`, `auto-optimise-store`, `nix.optimise.automatic` or `discard` | PASS | `eval-sd-wear` absence assertions |
| G9 | SD keeps `/`, `/boot` (on root) and `/boot/firmware` even with external storage | PASS | `eval-external-storage` |
| G10 | Simplicity: no new tools (deploy-rs, cachix-deploy, log2ram…) | PASS | review |
| G11 | Spec option set `rpi.buildHost.autoUpdate` | VIOLATION (adds `sshPort`) | complexity row C1 |
| G12 | Spec CLI `deploy [switch\|boot\|test] [--target …]` | VIOLATION (adds `--flake`, `--attr`, `--port`, `--max-builds`, `--force`; the spec names `--force`) | complexity row C2 |

| Complexity row | Need | Simpler alternative rejected |
|---|---|---|
| C1 `sshPort` | sshd on 2222; unattended service | user ssh config (invisible, interactive) |
| C2 extra CLI flags | deploy-smoke must target a throwaway attr on `127.0.0.1:<fwd>`; the guard limit must be testable | env vars only (undiscoverable) |
| C3 `rpi-lib.sh` | guards shared by `rpi-deploy` and `rpi-autoupdate` (spec §3.4 "same guards") | copy-paste |
| C4 `tests/qemu-pi.sh` | boot code shared by boot-smoke and deploy-smoke | ~40 duplicated lines |

## 5. Global constraints (verbatim from the spec)

- `nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05"` (own input, no follows). `nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/develop"`. home-manager and nix-terminal follow our nixpkgs. llm-agents stays as today (no follows today).
- Kernel invariant: `config.boot.kernelPackages.kernel` == nvmd's own Pi 3 kernel (same out path).
- `PermitRootLogin = "prohibit-password"`. `security.sudo.wheelNeedsPassword = false`. `nix.settings.trusted-users` unchanged (`[ "root" ]`).
- `nix.gc = { automatic = true; dates = "weekly"; options = "--delete-older-than 21d"; }`. extlinux limit 5. `setFlakeRegistry`/`setNixPath` = true. `nix.channel.enable = false`.
- sd-wear:
  - firmware: `mkForce false` / `mkForce []`
  - `/` options: `noatime lazytime commit=60`
  - tmp: tmpfs, `256M`
  - journald: `Storage=volatile`, `RuntimeMaxUse=16M`, `MaxLevelStore=info`; upload off
  - `systemd.coredump.enable = false`; `keep-derivations = false`
  - fstrim: monthly
  - zram: 50 %, `vm.swappiness = 100`, `vm.page-cluster = 0`
- headless: `gpu_mem=16`, `dtoverlay=disable-wifi`, `dtoverlay=disable-bt`, vc4-kms off, audio off, camera/display auto-detect off, drop `cma=32M`.
- external: `rpi.storage.external = { enable = false; label = "PI_DATA"; fsType = "ext4"; bind = [ "/nix" "/var" "/home" ]; swapSize = null; }`. Mount at `/external` with `neededForBoot = true` and never `nofail`.
- autoUpdate: `{ enable; user; repoPath; workDir; target = "root@neptun"; sshKey; onCalendar = "Sun 03:00"; maxBuilds = 500; rebootTime = "04:30"; }`, `Persistent=true`, `RandomizedDelaySec=30m`, build timeout 4 h.
- flash: `zstdcat | dd bs=4M conv=fsync oflag=direct status=progress` via sudo; the user must type the device name.
- Labels stay `NIXOS_BOOT` / `NIXOS_SD`. Image base name `neptun-rpi3`. Firmware partition 256 MiB, ID `0x2175794e`.

## 6. Review focus (most likely to bite; each has a test in its owning task)

1. **A flash to the wrong disk.** Covered: the device holding `/` is refused, a mounted partition on a removable disk is refused, and a confirmation typo is refused (T5.6 tests f2/f3/f5).
2. **A deploy from a stale checkout after an unmerged auto-update** (silent downgrade). Covered: T5.7 test d6.
3. **A Pi host key that changed after re-flash, which breaks the unattended job.** Covered: T6.3 test a12 asserts the known_hosts options in the ssh argv; README documents the recovery (T7.5).
4. **A cachix outage or eviction mid-run** (path-info fails with a network error instead of a 404). Covered: T5.2 test g9: any non-zero `path-info` counts as a miss → `RL_E_CACHE`, never a build.
5. **The user's checkout touched by the job** (dirty tree, other branch checked out). Covered: T6.3 test a10 (byte-identical working tree, `main` ref unchanged) and a11 (refuses when `auto-update` is checked out in the repo).

## 7. Files to read first (list only; read them at the start of your milestone)

- Everyone: the spec; this plan §0–§6 and your milestone.
- M1: `nixos/flake.nix`, `nixos/home.nix`, `.scratch/s5/REPORT.md` §1, `.scratch/s5/devhy/flake.nix` (diff it against the tracked `flake.nix`), `.scratch/e2/REPORT.md`; nvmd `lib/default.nix`, `lib/internal.nix`, `modules/raspberry-pi-3.nix` (`/nix/store/7w4nqam6n94avibp36aw17w4w5zsapfp-source`; develop pin `/nix/store/3ymh302cnmsfbdk1x52df1kq4r9pvh22-source`, whose relevant modules are identical, verified by diff); nixpkgs `nixos/modules/installer/sd-card/sd-image.nix` (`ev --raw $R.nixpkgs.flake.source` or `.#nixosConfigurations.rpi.pkgs.path`).
- M2: `nixos/configuration.nix`, `.scratch/e3/REPORT.md` §3–4, nvmd `modules/system/boot/loader/raspberrypi/default.nix:140-165,360-390,544-575`.
- M3: `.scratch/s6/REPORT.md`, `.scratch/s6/candidate.nix`, `.scratch/s6/eval.nix`, nvmd `modules/configtxt.nix`, `modules/configtxt-config.nix`.
- M4: commented `/external` block in `nixos/configuration.nix` (before M2 deletes it, or from git: `git show HEAD:nixos/configuration.nix`), nixpkgs `nixos/lib/utils.nix` (`pathsNeededForBoot`, `fsBefore`).
- M5: the old `rpi-deploy.sh` (harness ideas only), old `tests/deploy-unit.sh` lines 1–133 (mock pattern incl. `#!BASHPLACEHOLDER` shebang trick for the nix sandbox) and 282–342 (assert helpers), `.scratch/e3/REPORT.md` §2–3, `.scratch/s5/REPORT.md` sketch.
- M6: `nixos/modules/build-host.nix`, `nixos/modules/build-host-home.nix`, `nixos/tests/build-host.nix`, flake.nix `contract`/`rpi-binfmt`/`rpi-host-vm`, `.scratch/s5/REPORT.md` §3 sketch.
- M7: `nixos/tests/boot-smoke.sh`, `.scratch/e3/{REPORT.md,boot.sh,unpack.sh,flake/flake.nix,flake/test-image.nix}`, `README.md`, `HANDOFF.md`.

## 8. Type-checking strategy

| Checker | When | Expected rejections |
|---|---|---|
| NixOS module system (option types, `assertions`) | every `ev`/`chk`, `nix flake check --no-build` | typos in option names, e.g. `services.journald.settings` (does not exist in 26.05, s6 §3); wrong types (`swapSize = "1G"` against `nullOr ints.positive`, `rebootTime = "4:30"` against `strMatching "[0-2][0-9]:[0-5][0-9]"`); `autoUpdate.enable = true` without `user`/`repoPath`/`sshKey` ("used but not defined"); module assertions (bad `bind`, `sshKey` in the store). |
| *Not* caught by types | — | An **existing but ineffective** option, e.g. `boot.loader.raspberry-pi.configurationLimit` with U-Boot. Hence the property checks on the *effect* (`populateCmd` contains `-g 5`, config.txt lines). |
| `bash -n` + `shellcheck -S warning` (check `rpi-deploy-syntax`) | `chk rpi-deploy-syntax` after every script edit | syntax errors, unset/unused variables (SC2154/SC2034), `local x=$(…)` masking exit codes (SC2155), unquoted expansions in warnings |
| flake output schema (`nix flake check --no-build`) | end of each milestone | malformed `apps` (missing `type`/`program`), non-derivation checks |

## 9. Testing strategy per layer

| Layer | What it covers | Needs | Cost |
|---|---|---|---|
| L1 eval checks `eval-*` (`tests/eval/*.nix`) | option values and their *effects* in the evaluated `rpi` / host test config: kernel identity, image options, access, GC/limit, sd-wear, headless config.txt, external storage enabled variant, autoUpdate units | flake eval only (no aarch64 build, no IFD: never force `toplevel` in these files) | cheap, 20–60 s each |
| L2 bash unit tests `rpi-deploy-unit`, `autoupdate-unit` | CLI parsing, device refusal, dd/verify, guard parsing on real dry-run fixtures, cache guard, downgrade refusal, pinned tool, status, autoupdate git flow / fallback / decision / no-deploy | mocks for nix, ssh, sudo, lsblk, findmnt, dd, nixos-rebuild; real git, zstd, coreutils | cheap, ~10–30 s |
| L3 syntax/lint `rpi-deploy-syntax` | bash syntax, shellcheck | shellcheck | cheap |
| L4 NixOS VM test `rpi-host-vm` | build-host module end to end: binfmt, aarch64 `hello`, rpi-deploy on PATH, wrapper, autoupdate timer present | KVM (present: `/dev/kvm`) | expensive, 1–16 min (README) |
| L5 qemu `raspi3b` boot-smoke | exact image: kernel boots, root by label, first-boot expansion, SSH banner via usb-net | built image, qemu with `raspi3b` | expensive: image 527–648 s (E2/E3) + boot ~6–9 min |
| L6 qemu deploy-smoke | `rpi-deploy deploy switch` applies a change to a booted image | throwaway key image, ~20–25 min warm (image ~10 min, boot to ssh ~2 min, switch 78–159 s (E3)) | expensive, optional |
| L7 real hardware | U-Boot, GPU firmware reading config.txt, dd to a real card, LAN, reboot timer | the Pi, a card, serial cable | manual (§12) |
| Property/integration of guards against live cachix | `nix path-info --store https://nixos-raspberrypi.cachix.org` on the real kernel | network | cheap (M1 acceptance) |

The first `rpi` toplevel build after M1 (377 builds + 769 fetches / 2.3 GiB per s5 devhy; heaviest local build `blink-cmp-1.10.2` (Rust) under qemu-user) is **unmeasured**. Budget 30–90 min and run it once in the background (M1 T1.4, step 6).

## 10. Properties (assert over values; literals only where the literal is the criterion)

- P1 `rpi.config.boot.kernelPackages.kernel.outPath = nvmd.packages.aarch64-linux.linuxPackages_rpi3.kernel.outPath`, same for `.modules.outPath`, and `boot.loader.raspberry-pi.firmwarePackage.outPath = nvmd.packages.aarch64-linux.raspberrypifw.outPath`.
- P2 `toString rpi.pkgs.path = nixpkgs.outPath` (userspace from our input). With `r = lock.nodes.root.inputs` and `n = lock.nodes.${r.nixos-raspberrypi}.inputs`: `isString r.nixpkgs ∧ isString n.nixpkgs ∧ r.nixpkgs ≠ n.nixpkgs`. Strings are node names; a follows is a list.
  - Today: `r.nixpkgs = ["nixos-raspberrypi","nixpkgs"]` ⇒ false.
  - devhy lock: `"nixpkgs_4"` vs `"nixpkgs_3"` ⇒ true.
  - nvmd-follows-ours (s5 np) ⇒ `n.nixpkgs` is a list ⇒ false.
- P3 ∀k ∈ `users.users.root.openssh.authorizedKeys.keys`: `k = keys.user ∨ hasPrefix "from=\"" k`. And `keys.autoUpdate ≠ null ⇒ keys.hostAddress ≠ null`.
- P4 `hasInfix "-g ${toString limit} " generic-extlinux-compatible.populateCmd` with `limit = 5` (the effect, not just the value).
- P5 config.txt is a set of lines L (`lib.splitString "\n" config-generated`). `{gpu_mem=16, dtoverlay=disable-wifi, dtoverlay=disable-bt} ⊂ L`, `{dtoverlay=vc4-kms-v3d, dtparam=audio=on, camera_auto_detect=1, display_auto_detect=1} ∩ L = ∅`, and the boot-critical lines are preserved: `{arm_64bit=1, enable_uart=1, kernel=u-boot-rpi-arm64.bin} ⊂ L`.
- P6 ∀o ∈ `["noatime" "lazytime" "commit=60"]`: `o ∈ fileSystems."/".options`. `"discard" ∉` every fileSystems' options.
- P7 External enabled: ∀b ∈ `cfg.bind`: `fileSystems.${b} = { device = "/external${b}"; fsType = "none"; "bind" ∈ options; "/external" ∈ depends }`. ∀m ∈ `{"/external"} ∪ bind`: `"nofail" ∉ options`. The SD mounts are unchanged (`/` and `/boot/firmware` devices equal to the disabled config's).
- P8 The disabled module is a no-op: `attrNames fileSystems` and `swapDevices` of `rpi` are equal to those of `rpi.extendModules { rpi.storage.external.enable = false; }`, and no `/external` exists.
- P9 Dry-run parse: for each fixture, `|rl_built_names| = N` from its `these N derivations will be built:` header.
- P10 Reboot decision: `rl_needs_reboot a b ⇔ a ≠ b` over triplets (kernel, initrd, kernel-modules). Tests vary each component separately.
- P11 Failure safety: for every failing guard scenario, the mock log has `count(ssh|nixos-rebuild) = 0` and the `auto-update` ref is unchanged.
- P12 The user checkout is unchanged by autoupdate: `sha256(worktree files) ∧ git rev-parse main` are equal before and after.
- P13 autoUpdate ExecStart: ∀(flag, value) ∈ options: `"${flag} ${value}"` is in ExecStart. `sshKey` is not under `/nix/store`.

Pinned literals (user-facing): `reboot pending: yes|no`, `current:`, `booted:`, `would downgrade`, `verify failed`, `type the device name`, exit codes `RL_E_*` (§15.1).

## 11. Planted violations (tick after seeing red)

| Check | Plant (temporary) | Must FAIL with | Seen |
|---|---|---|---|
| eval harness | add `tests/eval/zz-planted.nix` = `_: { "planted violation" = false; }` (git add -N) | `chk eval-zz-planted` → `FAIL: planted violation` | [ ] |
| eval harness (vacuous) | `tests/eval/zz-empty.nix` = `_: { }` | `FAIL: no assertions` | [ ] |
| `eval-kernel` | in configuration.nix: `boot.kernelPackages = lib.mkForce pkgs.linuxPackages_rpi3;` (overlay-built from *our* nixpkgs ⇒ new hash) | `FAIL: rpi kernel is nvmd's linuxPackages_rpi3 kernel (cachix hit)` | [ ] |
| `eval-kernel` (P2) | add `nixos-raspberrypi.inputs.nixpkgs.follows = "nixpkgs";` + `nix flake lock` (back up the lock first; restore it afterwards) | `FAIL: nixpkgs and nvmd's nixpkgs are separate lock nodes (no follows either way)` | [ ] |
| `eval-image` | `sdImage.firmwarePartitionName = "FIRMWARE";` in modules/sd-image.nix | `FAIL: firmware partition label is NIXOS_BOOT` | [ ] |
| `eval-pi-config` | `PermitRootLogin = "yes"` | `FAIL: root login is key-only` | [ ] |
| `eval-pi-config` (P3) | keys.nix `autoUpdate = "ssh-ed25519 AAAAplanted x"; hostAddress = "10.0.0.1";` + configuration.nix temporarily drops the `from=` prefix | `FAIL: every non-user root key is from= restricted` | [ ] |
| `eval-pi-config` (P4) | set `boot.loader.raspberry-pi.configurationLimit = 5` *instead of* the extlinux one | `FAIL: extlinux keeps 5 generations (populateCmd -g 5)` | [ ] |
| `eval-sd-wear` | `rpi.sdWear.enable = false;` in configuration.nix | ≥ 5 FAIL lines incl. `FAIL: linux-firmware removed` | [ ] |
| `eval-headless` | `rpi.headless.enable = false;` | `FAIL: config.txt has gpu_mem=16` | [ ] |
| `eval-headless` (preservation) | headless sets `enable_uart.enable = lib.mkForce false` | `FAIL: config.txt keeps enable_uart=1` | [ ] |
| `eval-external-storage` | module adds `"nofail"` to `/external` options | `FAIL: no nofail on /external or bind mounts` | [ ] |
| `eval-external-storage` (assertion) | module assertion removed; test config `bind = [ "/boot" ]` | `FAIL: bind on /boot is rejected by an assertion` | [ ] |
| `rpi-deploy-unit` | delete the `RM=1` test in `flash_check_device` | `FAIL: f1 flash refuses non-removable disk` | [ ] |
| `rpi-deploy-unit` | remove `linux_rpi-.*[0-9]\|` from `RL_FORBIDDEN_RE` | `FAIL: g3 kernel fixture is forbidden` | [ ] |
| `rpi-deploy-unit` | `deploy` calls `nixos-rebuild` from PATH | `FAIL: d8 host nixos-rebuild never used` | [ ] |
| `rpi-deploy-syntax` | add `echo $undefined_planted` to rpi-lib.sh | shellcheck SC2154 | [ ] |
| `eval-build-host` | `Persistent = false` | `FAIL: timer is Persistent` | [ ] |
| `eval-build-host` | `sshKey` type `types.path` and value `./key` | `FAIL: sshKey is not copied into the store` | [ ] |
| `autoupdate-unit` | swap the `switch`/`shutdown -r` branches | `FAIL: a2 kernel change schedules reboot, no switch` | [ ] |
| `autoupdate-unit` | `push` before the guards | `FAIL: a5 guard failure leaves auto-update ref unchanged` | [ ] |
| `rpi-host-vm` [expensive] | node `rpi.buildHost.autoUpdate.enable = false` | `systemctl cat rpi-autoupdate.timer` fails | [ ] |
| boot-smoke SSH [expensive] | `RPI_SMOKE_GUEST_SSH_PORT=2223` | `FAIL: no SSH banner` | [ ] |
| deploy-smoke [expensive] | expect marker `wrong` | `FAIL: marker` | [ ] |

## 12. Coverage gap (manual, with reasons)

The automated layers do not reach:

1. U-Boot reading `extlinux.conf` and the GPU firmware applying `config.txt`. qemu uses direct kernel boot (E3 §5). Covered manually by AC6: `vcgencmd get_mem gpu` → `gpu=16M`, `dmesg | grep -i -E 'brcmfmac|hci_uart'` is empty, the serial console works.
2. A real `dd` to a card and the read-back over USB.
3. The LAN reality: `neptun` resolvable, `from=` matching the host address, port 2222.
4. A real weekly timer run on andromeda, `shutdown -r 04:30`, and the reboot into a kernel-changing generation (no boot counting).
5. SD write volumes (s6 §6 protocol, optional).
6. Cachix eviction behaviour. This is simulated only.

Manual checklist (T7.5, README): flash → boot → `ssh -p 2222 root@neptun true` and `pi@` → `vcgencmd get_mem gpu` → `rpi-deploy deploy switch` (one-line change) → `rpi-deploy deploy boot` with a kernel change (or `boot.kernelParams` change), reboot → `rpi-deploy status` shows `reboot pending: no`.

## 13. Scenario coverage (spec → the one check that executes it)

| Spec scenario | Check |
|---|---|
| §3.1 hybrid inputs / kernel equals nvmd (AC "flake check") | `eval-kernel` |
| §3 image is `rpi`'s sdImage; old outputs gone | `eval-image` |
| §3.2 root key-only + from= key; sudo no password | `eval-pi-config` |
| §3.2 removals (autoUpgrade, wifi, regdb, cf680211, iwd, secrets) | `eval-pi-config` (+ `git ls-files secrets` empty, T2.2) |
| §3.2 extlinux limit 5, GC weekly/21d, channel off, registry on | `eval-pi-config` |
| §3.2 sd-wear list | `eval-sd-wear` |
| §3.2 headless config.txt + no cma | `eval-headless`, `eval-pi-config` (cma) |
| §3.2 external storage (disabled default; enabled layout) | `eval-external-storage` |
| §3.3 image subcommand (guards first, prints path+size) | `rpi-deploy-unit` i1–i4 |
| §3.3 flash refusals, typed confirmation, dd flags, verify | `rpi-deploy-unit` f1–f9 |
| §3.3 deploy pinned tool, actions, downgrade refusal, `--force` | `rpi-deploy-unit` d1–d9 |
| §3.3 status current/booted/reboot pending | `rpi-deploy-unit` s1–s3 |
| §3.3 removed subcommands | `rpi-deploy-unit` c2 |
| §3.3 apps.nixos-rebuild pinned 26.05; package ships the lib | `eval-tools` (T5.9) |
| §3.3 build-host: keep binfmt/cache/rpi-deploy, drop static/F flag/rpi-binfmt | `eval-build-host` + flake `contract` + `rpi-host-vm` |
| §3.4 option set + timer/service | `eval-build-host` |
| §3.4 run steps 1–8 incl. fallback, guards, equal → stop, boot→switch / reboot, push | `autoupdate-unit` a1–a12 |
| §4 every guard failure exits before touching the Pi | `rpi-deploy-unit` d5/i2, `autoupdate-unit` a4–a8 (P11) |
| §4 rollback / extlinux DEFAULT edit | manual (README, T7.5) |
| §5 boot-smoke + usb-net SSH | `tests/boot-smoke.sh` (expensive) |
| §5 deploy-smoke | `tests/deploy-smoke.sh` (expensive) |
| AC1 `nix flake check` | T7.4 |
| AC2 image builds without kernel compile; boots | `rpi-deploy image` guard + T7.4 log grep + boot-smoke |
| AC3 closure ≤ 3.3 GiB | T7.4 `nix path-info -S` (expensive) |
| AC4 deploy smoke | T7.3 |
| AC5 autoupdate `--no-deploy` | `autoupdate-unit` a9 (mocked) + T7.4 real run (expensive) |
| AC6 hardware | manual §12 |

---

## 14. Milestones, dependencies, file ownership

```
M1 (serial, first: flake.lock + store paths change)
 ├── M2 configuration.nix/keys.nix/secrets ─┐
 ├── M3 sd-wear + headless ─────────────────┤  (M2 ∥ M3 ∥ M4 ∥ M5: disjoint files)
 ├── M4 external-storage ───────────────────┤
 └── M5 rpi-deploy rewrite ── M6 build-host + autoupdate ─┤
                                                          └── M7 smoke tests + docs + final acceptance
```

| Milestone | Owns (creates/modifies/deletes) | Depends on | Parallel with |
|---|---|---|---|
| M1 | `nixos/rpi-deploy.sh` (moved from repo root, unchanged), `flake.nix`, `flake.lock`, `home.nix` (comments), `modules/sd-image.nix`, stubs `modules/{sd-wear,headless,external-storage}.nix`, `tests/eval/{default,kernel,image}.nix` | — | none |
| M2 | `configuration.nix`, `keys.nix`, `tests/eval/pi-config.nix`, `../secrets/wireless.env.example` (rm), `../.gitignore` (secrets lines) | M1 | M3, M4, M5 |
| M3 | `modules/sd-wear.nix`, `modules/headless.nix`, `tests/eval/{sd-wear,headless}.nix` | M1 | M2, M4, M5 |
| M4 | `modules/external-storage.nix`, `tests/eval/external-storage.nix` | M1 | M2, M3, M5 |
| M5 | `rpi-deploy.sh` (rewrite), `rpi-lib.sh`, `tests/harness.sh`, `tests/deploy-unit.sh` (replace), `tests/fixtures/*`, `tests/eval/tools.nix`, `flake.nix` (package, apps, checks `rpi-deploy-unit`/`-syntax`, 2 lines of `rpi-host-vm`) | M1 | M2, M3, M4 |
| M6 | `modules/build-host.nix`, `modules/build-host-home.nix` (doc comment), `tests/build-host.nix`, `rpi-autoupdate.sh`, `tests/autoupdate-unit.sh`, `tests/eval/build-host.nix`, `flake.nix` (contract, `rpi-binfmt`, `rpi-host-vm`, package + check wiring) | M5 | M2, M3, M4 (if still running) |
| M7 | `tests/qemu-pi.sh`, `tests/boot-smoke.sh`, `tests/deploy-smoke.sh`, `../README.md`, `../HANDOFF.md`, `../.gitignore` (`.rpi-build*`) | all | none |

**Parallelism caveat.** Ownership is disjoint, but the flake evaluates every tracked file. A half-edited module in M3 therefore breaks M2's `chk` in the same working tree. Run parallel milestones in **separate worktrees** (`git worktree add ../rpi-M2 -b m2`), which requires M1 to be committed by the user first (Q8). Otherwise run M2→M3→M4→M5 in sequence in one tree. Each milestone's acceptance uses only `chk <own checks>`; the full `nix flake check` is run at M7.

---

## 15. Tasks

### 15.1 Shared interfaces (produced by M1/M5, consumed later)

**Eval check file contract (M1 produces; M2, M3, M4, M5, M6 consume):**

```nix
# tests/eval/<name>.nix  →  checks.x86_64-linux.eval-<name>
{ lib, rpi, nvmd, nixpkgs, nixosConfigurations, hostTestSystem, packages, apps, flakeLock, ... }:
{ "<human-readable property>" = <bool>; ... }   # ≥ 1 entry; NEVER force config.system.build.toplevel (IFD)
```
- `rpi` = `self.nixosConfigurations.rpi` (has `.config`, `.pkgs`, `.extendModules`)
- `nvmd` = `nixos-raspberrypi`
- `nixpkgs` = our input
- `packages`/`apps` = `self.packages`/`self.apps or { }` (`apps` exists only from M5 on)
- `flakeLock` = `lib.importJSON ./flake.lock`

**Aggregator (M1, `tests/eval/default.nix`):**

```nix
{ lib, pkgs, args }:
let
  files = lib.attrNames (lib.filterAttrs
    (n: t: t == "regular" && lib.hasSuffix ".nix" n && n != "default.nix") (builtins.readDir ./.));
  mkCheck = file:
    let
      results = import (./. + "/${file}") args;          # attrsOf bool
      failed  = lib.attrNames (lib.filterAttrs (_: ok: !ok) results);
      msg = if results == { } then [ "no assertions" ] else failed;
    in pkgs.runCommand "eval-${lib.removeSuffix ".nix" file}"
      { failures = lib.concatMapStrings (m: "FAIL: ${m}\n") msg;
        passed = toString (lib.length (lib.attrNames results)); }
      ''
        if [ -n "$failures" ]; then printf '%s' "$failures" >&2; exit 1; fi
        echo "$passed assertions passed"; touch $out
      '';
in lib.listToAttrs (map (f: lib.nameValuePair "eval-${lib.removeSuffix ".nix" f}" (mkCheck f)) files)
```
(The attribute names, i.e. the messages, carry no string context. Booleans never do. Store paths must never be interpolated into messages.)

**`rpi-lib.sh` (M5 produces; M6 consumes).** Sourced; it has no side effects at source time.

```bash
# globals (caller may set before calling; defaults shown)
RL_FLAKE=${RL_FLAKE:-$PWD}            # flake directory (or ref)
RL_ATTR=${RL_ATTR:-rpi}               # nixosConfigurations attr
RL_TARGET=${RL_TARGET:-root@neptun}
RL_SSH_PORT=${RL_SSH_PORT:-2222}
RL_SSH_OPTS=${RPI_SSH_OPTS:-}         # extra ssh options, word-split (e.g. "-F file -i key")
RL_CACHE_URL=${RPI_CACHE_URL:-https://nixos-raspberrypi.cachix.org}
RL_FORBIDDEN_RE='^(linux_rpi-.*[0-9]|linux-[0-9].*|linux-config-.*|kernel-intermediate-config.*|(gcc|llvm|rustc|ghc|nodejs)-[0-9].*)$'
RL_E_USAGE=2 RL_E_CACHE=10 RL_E_FORBIDDEN=11 RL_E_TOO_MANY=12 RL_E_BUILD=13 RL_E_DEPLOY=14 RL_E_DOWNGRADE=15 RL_E_DEVICE=16 RL_E_VERIFY=17

rl_built_names            # stdin: dry-run stderr → stdout: names (hash + ".drv" stripped) of the "will be built:" section, 1/line
rl_check_builds FILE MAX  # → 0 | RL_E_FORBIDDEN (offending names on stderr) | RL_E_TOO_MANY ("N > MAX" on stderr)
rl_conf_ref               # echo "$RL_FLAKE#nixosConfigurations.$RL_ATTR"
rl_kernel_paths           # stdout 2 lines: kernel outPath, kernel.modules outPath (nix eval --raw)
rl_cache_has PATH...      # → 0 iff `nix path-info --store "$RL_CACHE_URL" P` succeeds ∀P (any error counts as a miss)
rl_guard BUILD_ATTR MAX   # BUILD_ATTR ∈ {toplevel, sdImage}: cache guard, then dry-run of
                          #   "$(rl_conf_ref).config.system.build.$BUILD_ATTR" → 0 | RL_E_CACHE | RL_E_FORBIDDEN | RL_E_TOO_MANY | RL_E_BUILD (eval error)
rl_triplet_local DIR      # echo "$(readlink -f DIR/kernel) $(readlink -f DIR/initrd) $(readlink -f DIR/kernel-modules)"
rl_triplet_remote WHICH   # WHICH ∈ {current, booted}: same, evaluated on the target via rl_ssh
rl_needs_reboot A B       # → 0 iff "$A" != "$B"
rl_sshopts                # echo "-p $RL_SSH_PORT $RL_SSH_OPTS"
rl_ssh CMD...             # ssh -p "$RL_SSH_PORT" $RL_SSH_OPTS "$RL_TARGET" CMD...
rl_nixos_rebuild ARGS...  # NIX_SSHOPTS="$(rl_sshopts)" ${RPI_NIXOS_REBUILD:-nix run --accept-flake-config "$RL_FLAKE#nixos-rebuild" --} ARGS
```

Dry-run parse algorithm: the section starts at a line matching `will be built:$` (plural or singular) and ends at the first line that does not start with whitespace. In the section, strip `^ *`, `/nix/store/`, the 32-char hash with `-`, and the `.drv` suffix. The fixture's first line (`evaluation warning: …`) must be ignored.

**Test harness `tests/harness.sh` (M5 produces; M6 consumes).**
- `T=$(mktemp -d)`; `BIN=$T/bin` prepended to PATH; hermetic git (`GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null`).
- `mock NAME <<'EOF' … EOF`: writes `$BIN/NAME` with shebang `#!$(command -v bash)` (the sandbox has no `/usr/bin/env`) and logs `NAME $*` to `$MOCK_LOG`.
- Assert helpers ported from old `tests/deploy-unit.sh:282-342`: `run_cmd NAME -- CMD…` (captures `$OUT`, `$RC`), `expect_exit NAME RC`, `expect_grep NAME REGEX [FILE]`, `expect_grepf`, `expect_not_grep`, `expect_true`.
- `log_count REGEX`: number of matching mock-log lines.
- `summary`: prints `N passed, M failed` and exits non-zero if M > 0.

---

### M1 — Hybrid inputs, single `rpi` with sdImage, kernel check (serial, first)

**Files:** see §14. **Risk:** high. It changes `flake.lock` and almost every store path, and the hybrid mixes nvmd modules with a nixpkgs rev that nvmd CI does not build (s5 risks). Mitigation: the measured devhy lock (D2) and `eval-kernel`. The first toplevel build is unmeasured (30–90 min).

#### Task 1.1: Repair the baseline (script path)  `[ ]`
- [ ] RED `[cheap]`: `nix flake check --no-build --accept-flake-config` → fails with `error: Path 'nixos/rpi-deploy.sh' does not exist in Git repository` (observed 2026-10-22).
- [ ] GREEN: `git mv ../rpi-deploy.sh rpi-deploy.sh` (content unchanged).
- [ ] Verify `[cheap]`:
  - `nix flake check --no-build --accept-flake-config` passes evaluation.
  - `chk rpi-deploy-unit` → `rpi-deploy unit tests: 307 passed, 0 failed` (observed outside nix in 8 s).
  - `chk rpi-deploy-syntax` passes.
- [ ] Commit point: `git add -A rpi-deploy.sh ../rpi-deploy.sh` — "Move rpi-deploy.sh into nixos/ (flake path)".

#### Task 1.2: Eval-check harness + kernel/hybrid check (RED)  `[ ]`
- [ ] Create `tests/eval/default.nix` (§15.1). Wire it into flake.nix `checks.x86_64-linux` via `// import ./tests/eval { inherit lib; pkgs = x86Pkgs; args = { … }; }` (args as in §15.1). Add `flakeLock = lib.importJSON ./flake.lock`. `git add -N tests/eval/default.nix`.
- [ ] Create `tests/eval/kernel.nix` with these exact messages:
  - `"rpi kernel is nvmd's linuxPackages_rpi3 kernel (cachix hit)"` (P1 kernel)
  - `"rpi kernel modules are nvmd's"` (P1 modules)
  - `"Pi firmware package is nvmd's raspberrypifw"`
  - `"userspace nixpkgs is our own input"` (P2: `toString rpi.pkgs.path == nixpkgs.outPath`)
  - `"nixpkgs and nvmd's nixpkgs are separate lock nodes (no follows either way)"` (P2 lock property, §10)
- [ ] Planted (harness): `zz-planted.nix` and `zz-empty.nix` per §11 → seen red, then delete them.
- [ ] RED `[cheap]`: `chk eval-kernel` → exactly `FAIL: nixpkgs and nvmd's nixpkgs are separate lock nodes (no follows either way)` (today `root.inputs.nixpkgs` is the follows list `["nixos-raspberrypi","nixpkgs"]`). The other 4 assertions pass, because with follows both sides are the same nixpkgs.

#### Task 1.3: Hybrid inputs (GREEN for 1.2)  `[ ]`
- [ ] flake.nix inputs:
  - `nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/develop";`
  - `nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";`, and delete the `follows` line plus its "CRITICAL" comment (replace it with a 3-line comment on the hybrid rule: kernel/firmware from nvmd's pin; out-of-tree modules only from `config.boot.kernelPackages`).
- [ ] `rpi = nixos-raspberrypi.lib.nixosSystem { inherit nixpkgs; specialArgs = …; modules = …; }`.
- [ ] `cp .scratch/s5/devhy/flake.lock flake.lock && nix flake lock --accept-flake-config` (D2). Expected: no input changes.
- [ ] Verify `[cheap]`:
  - `chk eval-kernel` → `5 assertions passed`.
  - `jq -r '.nodes[.nodes.root.inputs.nixpkgs].locked.rev, .nodes[.nodes.root.inputs["nixos-raspberrypi"]].locked.rev' flake.lock` → `da6dc0e7b2…`, `747895cf18…`.
  - `ev --raw $R.boot.kernelPackages.kernel.outPath` → `/nix/store/30kd6a67wy5xcywzlv77l2bgvya8y0cv-linux_rpi-bcm2711-6.18.52-unstable_20260915`.
  - `nix path-info --store https://nixos-raspberrypi.cachix.org $(ev --raw $R.boot.kernelPackages.kernel.outPath) $(ev --raw $R.boot.kernelPackages.kernel.modules.outPath)` → rc 0.
- [ ] Planted: `eval-kernel` row (mkForce `pkgs.linuxPackages_rpi3`) → seen red → reverted.
- [ ] home.nix: update the two comments that say "pinned by nixos-raspberrypi" (behaviour unchanged).

#### Task 1.4: Single `rpi` builds the image (RED → GREEN)  `[ ]`
- [ ] RED: create `tests/eval/image.nix` with these messages:
  - `"rpi exposes system.build.sdImage"`
  - `"image file is neptun-rpi3.img.zst"` (`config.image.fileName`)
  - `"firmware partition label is NIXOS_BOOT"`
  - `"root label is NIXOS_SD"`
  - `"firmware partition is 256 MiB with ID 0x2175794e"`
  - `"image is compressed and expands on first boot"`
  - `"/boot/firmware mounted with fmask/dmask, not noauto"` (D14)
  - `"no separate rpi-image outputs"` (`!(nixosConfigurations ? rpi-image) && !(nixosConfigurations ? rpi-image-nvmd)`)

  `chk eval-image` → FAIL on the first and the last message.
- [ ] GREEN:
  - Move the inline module of today's `rpi-image` (flake.nix "Variant B") verbatim into `modules/sd-image.nix` and add it to `rpi`'s module list before `./configuration.nix`.
  - Delete `rpi-image` and `rpi-image-nvmd`.
  - Create the stubs `modules/{sd-wear,headless,external-storage}.nix` = `{ ... }: { }` and import them in `rpi` (D4).
  - `git add` all new files.
- [ ] Verify `[cheap]`:
  - `chk eval-image` passes and `chk eval-kernel` passes.
  - `nix flake check --no-build --accept-flake-config` passes (1–3 min; IFD builds the yazi theme for aarch64).
  - Dry-run guard, inline until M5 exists:
    ```bash
    nix build --accept-flake-config --dry-run $R.system.build.toplevel 2> .scratch/plan/dry-m1.txt
    awk '/will be built:$/{f=1;next} /^[^ ]/{f=0} f' .scratch/plan/dry-m1.txt \
      | sed -E 's#^ *(/nix/store/)?[a-z0-9]{32}-##; s#\.drv$##' > .scratch/plan/built-m1.txt
    grep -E '^(linux_rpi-.*[0-9]|linux-[0-9].*|linux-config-.*|kernel-intermediate-config.*|(gcc|llvm|rustc|ghc|nodejs)-[0-9].*)$' .scratch/plan/built-m1.txt; echo "forbidden rc=$? (want 1)"; wc -l < .scratch/plan/built-m1.txt  # want ≤ 500 (≈ 377 + sd-image units)
    ```
- [ ] Planted: `eval-image` row → seen red → reverted.
- [ ] `[expensive, recommended, background]` warm the store (reused by M2–M7): `nix build --accept-flake-config --no-link --print-out-paths $R.system.build.toplevel 2>&1 | tee .scratch/plan/build-m1.log`. **Unmeasured: budget 30–90 min.** The log must not contain `building '/nix/store/…-linux_rpi-bcm2711-6.18.52-unstable_20260915.drv'`.
- [ ] Commit point: `git add flake.nix flake.lock home.nix modules tests/eval` — "Hybrid inputs; rpi builds its own sdImage; kernel==nvmd check".

**M1 acceptance (all cheap):** `chk eval-kernel && chk eval-image && chk rpi-deploy-unit && chk rpi-deploy-syntax && nix flake check --no-build --accept-flake-config`. The inline dry-run guard is OK (≤ 500, no forbidden).

---

### M2 — Pi configuration: access, removals, GC, extlinux limit (parallel group)

**Files:** `configuration.nix`, `keys.nix` (new), `tests/eval/pi-config.nix` (new), `../secrets/wireless.env.example` (git rm), `../.gitignore`. **Risk:** medium. A wrong root key set would lock you out of the re-flashed card; mitigated by P3 and the manual first boot. `wheelNeedsPassword = false` is flagged in spec §10.

The check file is `tests/eval/pi-config.nix`. Each task appends its messages first (RED), then makes them pass. Only the newly appended messages may fail.

#### Task 2.1: Key-only root access + keys.nix  `[ ]`
- [ ] RED messages:
  - `"root login is key-only"` (`PermitRootLogin == "prohibit-password"` ∧ `PasswordAuthentication == false`)
  - `"root has the user key"`
  - `"every non-user root key is from= restricted"` (P3)
  - `"an auto-update key needs hostAddress"`
  - `"pi has exactly the user key"`
  - `"wheel needs no sudo password"`
  - `"no trusted-users change"` (`trusted-users == [ "root" ]`)

  `chk eval-pi-config` → FAIL on the first, second and sixth messages.
- [ ] GREEN:
  - `keys.nix` = `{ user = "<pi's current key, verbatim from configuration.nix>"; autoUpdate = null; hostAddress = null; }` (Q1).
  - configuration.nix: `let keys = import ./keys.nix; in`, then root and pi keys per D11, `PermitRootLogin = "prohibit-password"`, `wheelNeedsPassword = false`.
- [ ] Planted: both P3 rows of §11 → seen red → reverted.

#### Task 2.2: Removals (no on-Pi update, no wifi, no secrets)  `[ ]`
- [ ] RED messages:
  - `"autoUpgrade is off"`
  - `"wifi is off and has no networks or secrets file"` (`!networking.wireless.enable ∧ networks == {} ∧ secretsFile == null`)
  - `"no iwd override"` (`!(systemd.services ? iwd)`)
  - `"no cfg80211 modprobe line"` (`!hasInfix "cf680211" boot.extraModprobeConfig`)
  - `"no wireless-regdb firmware"` (`!any (p: hasInfix "wireless-regdb" p.name) hardware.firmware`)
- [ ] GREEN: delete the corresponding blocks from configuration.nix. `git rm ../secrets/wireless.env.example`. Delete the 3 secrets lines from `../.gitignore`. The untracked `../secrets/wireless.env` (holds a PSK) is **not** deleted; tell the user (Q7).
- [ ] Verify: `git ls-files ../secrets` prints nothing.

#### Task 2.3: Boot/GC hygiene  `[ ]`
- [ ] RED messages:
  - `"extlinux keeps 5 generations (populateCmd -g 5)"` (P4 + `configurationLimit == 5`)
  - `"nix gc weekly, older than 21d"` (`nix.gc.automatic ∧ dates == [ "weekly" ] ∧ options == "--delete-older-than 21d"`)
  - `"channels off"`
  - `"flake registry and NIX_PATH point at system nixpkgs"` (`setFlakeRegistry ∧ setNixPath`)
- [ ] GREEN: `boot.loader.generic-extlinux-compatible.configurationLimit = 5;` (D1), `nix.gc` per §5, `nix.channel.enable = false;`, and set both `nixpkgs.flake.set*` explicitly to `true`.
- [ ] Planted: P4 row (wrong option) → seen red → reverted.

#### Task 2.4: Remove dead and duplicate config (headless `cma`, journald block, fileSystems)  `[ ]`
- [ ] RED messages:
  - `"no cma=32M kernel parameter"`
  - `"no stale journald limits in configuration.nix"` (`journald.conf` text contains neither `SystemMaxUse=` nor `RuntimeMaxUse=8M`)
- [ ] GREEN: delete `boot.kernelParams = ["cma=32M"]` and its comment, and the `services.journald` block (M3 owns journald, D13).
- [ ] CLEAN (refactor, behaviour-preserving): delete configuration.nix's `fileSystems` block, which duplicates `modules/sd-image.nix`, and the commented `/external` + `swapDevices` block (replaced by M4).
  - Evidence before: `ev --json $R.fileSystems --apply 'fs: builtins.mapAttrs (n: v: { inherit (v) device fsType options; }) fs' > .scratch/plan/fs-before.json`.
  - Evidence after: the same command into `fs-after.json`. `diff` must be empty, and `chk eval-image` must pass. Also update the stale zram comment ("autoUpgrade builds").

**M2 acceptance `[cheap]`:** `chk eval-pi-config && chk eval-image && chk eval-kernel`.

---

### M3 — `modules/sd-wear.nix` + `modules/headless.nix` (parallel group)

**Files:** see §14. **Risk:**
- headless: medium. HDMI console is lost; disable-bt moves the PL011 to the GPIO serial. Covered only by manual AC6.
- sd-wear: low. AC3 margin: 4.0 GiB − 0.77 GiB ≈ 3.23 GiB against the 3.3 GiB limit, so a nixpkgs bump can eat the 70 MiB margin (T7.4).

#### Task 3.1: sd-wear gate + firmware  `[ ]`
- [ ] RED `tests/eval/sd-wear.nix` messages:
  - `"sd-wear is enabled by default"` (`rpi.config.rpi.sdWear.enable`)
  - `"linux-firmware removed"` (`!hardware.enableRedistributableFirmware ∧ hardware.firmware == []`)
  - `"disabling sd-wear restores firmware"` (`(rpi.extendModules { modules = [ { rpi.sdWear.enable = false; } ]; }).config.hardware.enableRedistributableFirmware`; this proves the gate)
- [ ] GREEN: `options.rpi.sdWear.enable = lib.mkOption { type = lib.types.bool; default = true; description = …; }`; `config = lib.mkIf cfg.enable { hardware.enableRedistributableFirmware = lib.mkForce false; hardware.firmware = lib.mkForce [ ]; }`.

#### Task 3.2: Filesystem, tmp, fstrim  `[ ]`
- [ ] RED messages:
  - `"root mounted noatime,lazytime,commit=60"` (P6)
  - `"no discard mount option anywhere"`
  - `"/tmp is a 256M tmpfs"`
  - `"fstrim monthly"`
- [ ] GREEN: `fileSystems."/".options = [ "noatime" "lazytime" "commit=60" ];` (list merge), `boot.tmp = { useTmpfs = true; tmpfsSize = "256M"; };`, `services.fstrim = { enable = true; interval = "monthly"; };`.

#### Task 3.3: journald, coredump, nix derivations  `[ ]`
- [ ] RED messages:
  - `"journald volatile, 16M runtime, info level"` (lines `Storage=volatile`, `RuntimeMaxUse=16M`, `MaxLevelStore=info` ∈ `environment.etc."systemd/journald.conf".text` lines)
  - `"journal upload off"`
  - `"no coredumps"`
  - `"keep-derivations off"`
- [ ] GREEN: `services.journald.storage = "volatile"; services.journald.extraConfig = "Compress=yes\nRuntimeMaxUse=16M\nMaxLevelStore=info\n";` (there is no `journald.settings` in 26.05), `systemd.coredump.enable = false; nix.settings.keep-derivations = false;`.

#### Task 3.4: zram tuning + rejected settings stay absent  `[ ]`
- [ ] RED messages:
  - `"zram 50% with swappiness 100, page-cluster 0"` (`zramSwap.enable ∧ memoryPercent == 50` (from configuration.nix) ∧ the sysctls)
  - `"no fsync-metadata=false, auto-optimise or optimise timer"` (G8: `(nix.settings.fsync-metadata or true) ∧ !(nix.settings.auto-optimise-store or false) ∧ !nix.optimise.automatic`)
- [ ] GREEN: `boot.kernel.sysctl = { "vm.swappiness" = 100; "vm.page-cluster" = 0; };`. The second message is already green: plant `nix.settings.auto-optimise-store = true` to see it red, then revert.
- [ ] Planted: `rpi.sdWear.enable = false` row → seen red.

#### Task 3.5: headless config.txt  `[ ]`
- [ ] RED `tests/eval/headless.nix` messages (P5 over the lines of `hardware.raspberry-pi.config-generated`):
  - `"headless is enabled by default"`
  - `"config.txt has gpu_mem=16"`
  - `"config.txt disables wifi and bt overlays"`
  - `"config.txt has no vc4-kms-v3d overlay"`
  - `"config.txt has no audio dtparam"`
  - `"config.txt has no camera/display auto-detect"`
  - `"config.txt keeps enable_uart=1"`
  - `"config.txt keeps arm_64bit=1 and u-boot kernel"`
- [ ] GREEN: options `rpi.headless.enable` (default true); under `mkIf` set `hardware.raspberry-pi.config.all` exactly as in s6 §4. Do **not** add `disable_splash`, and do not touch `max_framebuffers`, `disable_fw_kms_setup` or `disable_overscan` (not in the spec). Do **not** `mkForce` `boot.kernelParams` (that would drop `root=fstab loglevel=7 lsm=…`; `cma` is removed by M2).
  - `options = { gpu_mem = { enable = true; value = 16; }; camera_auto_detect.enable = lib.mkForce false; display_auto_detect.enable = lib.mkForce false; };`
  - `base-dt-params.audio.enable = lib.mkForce false;`
  - `dt-overlays = { vc4-kms-v3d.enable = lib.mkForce false; disable-bt.enable = true; disable-wifi.enable = true; };`
- [ ] Planted: both headless rows → seen red → reverted.

**M3 acceptance `[cheap]`:** `chk eval-sd-wear && chk eval-headless && chk eval-kernel && chk eval-image`. (AC3 closure size is measured in T7.4, expensive.)

---

### M4 — `modules/external-storage.nix` (parallel group)

**Files:** see §14. **Risk:** low while disabled. Enabling it is untested on hardware: the stage-1 bind of `/nix` and `/var` from `/external` relies on nixpkgs `pathsNeededForBoot` + `depends`. This is out of scope here and is documented as a manual migration.

Option interface:
```nix
options.rpi.storage.external = {
  enable   = lib.mkEnableOption "external USB disk for /nix, /var, /home (SD stays boot device)";
  label    = lib.mkOption { type = lib.types.strMatching "[A-Za-z0-9_-]{1,16}"; default = "PI_DATA"; };
  fsType   = lib.mkOption { type = lib.types.str; default = "ext4"; };
  bind     = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ "/nix" "/var" "/home" ]; };
  swapSize = lib.mkOption { type = lib.types.nullOr lib.types.ints.positive; default = null; description = "MiB; swapfile /external/swapfile"; };
};
```
Test configs, inside `tests/eval/external-storage.nix`:
- `on = rpi.extendModules { modules = [ { rpi.storage.external = { enable = true; swapSize = 1024; }; } ]; }`
- `bad = rpi.extendModules { modules = [ { rpi.storage.external = { enable = true; bind = [ "/boot" ]; }; } ]; }`

#### Task 4.1: Disabled by default is a no-op  `[ ]`
- [ ] RED messages:
  - `"external storage is off by default"`
  - `"disabled module adds no mounts or swap"` (P8)

  This fails first because the option does not exist yet (eval error = red).
- [ ] GREEN: the options above and `config = lib.mkIf cfg.enable { }`.

#### Task 4.2: Enabled layout  `[ ]`
- [ ] RED messages on `on`:
  - `"/external is by-label PI_DATA, ext4, neededForBoot"`
  - `"each bind entry is bind-mounted from /external after /external"` (P7)
  - `"no nofail on /external or bind mounts"`
  - `"SD keeps / and /boot/firmware"` (devices equal to `rpi`'s; `!(fileSystems ? "/boot")`)
  - `"/nix bind depends on /external, which is neededForBoot"` (nixpkgs mounts `/nix` and `/var` in stage 1 by itself via `pathsNeededForBoot`, `nixos/lib/utils.nix:57-68`; what this module must guarantee is that `/external` is neededForBoot too and that the binds depend on it)
  - `"swapfile of swapSize MiB on /external"`
- [ ] GREEN: `fileSystems."/external" = { device = "/dev/disk/by-label/${cfg.label}"; fsType = cfg.fsType; neededForBoot = true; };` and `lib.genAttrs cfg.bind (b: { device = "/external${b}"; fsType = "none"; options = [ "bind" ]; depends = [ "/external" ]; })`. `swapDevices = lib.optional (cfg.swapSize != null) { device = "/external/swapfile"; size = cfg.swapSize; };`.

#### Task 4.3: Reject binds that would move boot  `[ ]`
- [ ] RED message: `"bind on /boot is rejected by an assertion"` (`lib.any (a: !a.assertion) bad.config.assertions`)
- [ ] GREEN: `assertions = [ { assertion = lib.all (b: lib.hasPrefix "/" b && !(lib.elem b [ "/" "/boot" "/boot/firmware" "/external" ]) && !(lib.hasPrefix "/boot/" b)) cfg.bind; message = "rpi.storage.external.bind: absolute paths outside /, /boot, /boot/firmware, /external"; } ];`
- [ ] Planted: both §11 rows → seen red → reverted.

**M4 acceptance `[cheap]`:** `chk eval-external-storage && chk eval-image`.

---

### M5 — `rpi-deploy` rewrite + lib + unit tests + pinned tool (parallel group)

**Files:** see §14. **Risk:** medium. `flash` is the only destructive command; the device checks and the typed confirmation are the safety net. Existing tests are **not preserved**: `tests/deploy-unit.sh` is replaced because every subcommand it covers (`prepare/build/install/config/eject/show/devices/all`, `--from`, F-flag) is removed by spec §3.3. Two `rpi-host-vm` testScript lines that call `rpi-deploy build --dry-run` and `rpi-deploy show` are replaced for the same reason.

CLI (usage text is user-facing; `--help` prints it, exit 0):
```
rpi-deploy image  [--out DIR] [--flake DIR] [--attr NAME] [--max-builds N]
rpi-deploy flash  IMAGE DEVICE
rpi-deploy deploy [switch|boot|test] [--target USER@HOST] [--port N] [--flake DIR] [--attr NAME] [--max-builds N] [--force]
rpi-deploy status [--target USER@HOST] [--port N]
env: RPI_FLAKE (default flake dir), RPI_SSH_OPTS, RPI_NIXOS_REBUILD, RPI_LIB; test hook RPI_ALLOW_NONBLOCK=1
```
Defaults: `--flake ${RPI_FLAKE:-$PWD}`, `--attr rpi`, `--target root@neptun`, `--port 2222`, `--max-builds 500`, `--out $PWD`. Lib lookup: `RPI_LIB=${RPI_LIB:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/rpi-lib.sh}`.

Unit-test check wiring (flake.nix, replaces the current `rpi-deploy-unit`):
```nix
rpi-deploy-unit = x86Pkgs.runCommand "rpi-deploy-unit-check" {
  src = lib.fileset.toSource { root = ./.; fileset = lib.fileset.unions [
    ./rpi-deploy.sh ./rpi-lib.sh ./tests/harness.sh ./tests/deploy-unit.sh ./tests/fixtures ]; };
  nativeBuildInputs = with x86Pkgs; [ git zstd gnugrep gnused gawk ];   # NOT util-linux: lsblk/findmnt are mocks
} ''RPI_DEPLOY_SRC=$src/rpi-deploy.sh RPI_LIB=$src/rpi-lib.sh FIXTURES=$src/tests/fixtures \
     bash $src/tests/deploy-unit.sh; touch $out'';
```

#### Task 5.1: Harness + dry-run fixtures + guard parsing  `[ ]`
- [ ] Fixtures:
  - `sed -n '1,/will be fetched/p' .scratch/s5/devhy/dry.out > tests/fixtures/dry-run-hybrid.txt` (377 builds)
  - `sed -n '1,/will be fetched/p' .scratch/s5/np/dry.out > tests/fixtures/dry-run-kernel.txt` (384 builds, kernel)
  - `tests/fixtures/dry-run-single.txt` = `this derivation will be built:\n  /nix/store/<32×a>-nixos-system-neptun-26.05.drv\n`
  - `tests/fixtures/dry-run-none.txt` = empty
- [ ] Write `tests/harness.sh` (§15.1). Replace `tests/deploy-unit.sh` with the new file (sources the harness and the lib). Wire the check as above. `git add` everything.
- [ ] RED tests:
  - g1 `rl_built_names < dry-run-hybrid.txt | wc -l` = 377 (P9: equals header N)
  - g2 the hybrid fixture is allowed: `rl_check_builds hybrid 500` → 0
  - g3 the kernel fixture is forbidden: rc `RL_E_FORBIDDEN`, stderr lists `linux-config-6.18.34-unstable_20260604`, `linux_rpi-bcm2711-6.18.34-unstable_20260604` and `kernel-intermediate-config`
  - g4 `initrd-linux_rpi-…` and `linux_rpi-…-modules(-shrunk)` are not forbidden (regression for the s5 regex, D6)
  - g5 too many: `rl_check_builds hybrid 300` → `RL_E_TOO_MANY`, stderr `377 > 300`
  - g6 single fixture → 1 name `nixos-system-neptun-26.05`
  - g7 none fixture → 0 names, rc 0

  `chk rpi-deploy-unit` → fails (`rpi-lib.sh` missing).
- [ ] GREEN: `rpi-lib.sh` with globals, the exit-code constants, `rl_built_names` and `rl_check_builds` (algorithm in §15.1).

#### Task 5.2: Cache guard + `rl_guard`  `[ ]`
- [ ] RED tests (mock `nix`: `eval --raw …kernel.outPath` → `$MOCK_K`, `…modules.outPath` → `$MOCK_M`; `path-info --store URL P` → rc 0 iff P ∈ `$MOCK_CACHED`; `build --dry-run` → cat `$MOCK_DRY`):
  - g8 both cached → 0, and the log has `path-info --store https://nixos-raspberrypi.cachix.org`
  - g9 modules missing, and also path-info failing with a network error → `RL_E_CACHE`
  - g10 `rl_guard toplevel 500` order in the log is path-info → `build --dry-run …config.system.build.toplevel`
  - g11 cache miss ⇒ no dry-run line in the log
  - g12 dry-run eval error (mock rc 1) → `RL_E_BUILD`
- [ ] GREEN: `rl_conf_ref`, `rl_kernel_paths`, `rl_cache_has`, `rl_guard`.

#### Task 5.3: Reboot decision + ssh helpers  `[ ]`
- [ ] RED tests:
  - r1 equal triplets → `rl_needs_reboot` rc 1
  - r2–r4 differing kernel / initrd / modules → rc 0 (P10)
  - r5 `rl_sshopts` with port 22 and `RPI_SSH_OPTS="-F x"` → `-p 22 -F x`
  - r6 `rl_triplet_local DIR` on a temp toplevel with 3 symlinks
- [ ] GREEN: the functions in §15.1.

#### Task 5.4: New CLI skeleton (replaces the old script)  `[ ]`
- [ ] RED tests:
  - c1 `--help` exit 0, and the output contains `image`, `flash IMAGE DEVICE`, `deploy`, `status`
  - c2 each of `prepare install config eject build show all devices` → exit 2 and `unknown subcommand`
  - c3 no args → usage, exit 2
- [ ] GREEN: rewrite `rpi-deploy.sh` with arg parsing, dispatch and `die`/`log`. The subcommand bodies are stubs that `die "not implemented"`.
- [ ] Also replace the two `rpi-host-vm` testScript lines:
  - `host.succeed("rpi-deploy --help | grep -q 'flash IMAGE DEVICE'")`
  - `host.fail("rpi-deploy install")`
- [ ] Planted: shellcheck row of §11 → seen red.

#### Task 5.5: `image`  `[ ]`
- [ ] RED tests (mock nix `build` with `--out-link L` creates `L/sd-image/neptun-rpi3.img.zst` with 10 bytes):
  - i1 `image` → log order: path-info, dry-run on `…config.system.build.sdImage`, then `build … --out-link $OUT/result-rpi-image …sdImage`
  - i2 cache miss → exit `RL_E_CACHE` and no non-dry `build` line
  - i3 stdout has the image path ending `/sd-image/neptun-rpi3.img.zst` and the size
  - i4 `--out DIR` puts the out-link in DIR
- [ ] GREEN: `do_image` = `rl_guard sdImage $MAX`, then `nix build --accept-flake-config --out-link "$OUT/result-rpi-image" "$(rl_conf_ref).config.system.build.sdImage"`, then print `ls "$OUT"/result-rpi-image/sd-image/*.img.zst` and `du -h --apparent-size`.

#### Task 5.6: `flash`  `[ ]`
- [ ] RED tests. Fixture image: `printf 'NIXIMG%.0s' {1..1000} | zstd > img.zst`; device = regular file + `RPI_ALLOW_NONBLOCK=1`. Mocks: `lsblk` answers per `$MOCK_RM`, `$MOCK_TYPE`, `$MOCK_MOUNTS`, `$MOCK_PKNAME`, `MODEL/SIZE`; `findmnt` → `$MOCK_ROOTSRC`; `sudo` logs and runs; `dd` logs its argv and runs the real coreutils dd with `oflag=direct` removed (tmpfs has no O_DIRECT), flipping one byte when `MOCK_DD_CORRUPT=1`.
  - f1 `RM=0` → exit `RL_E_DEVICE`, `not removable`
  - f2 a mounted partition (`MOCK_MOUNTS=/run/media/x`) → refused
  - f3 the device is the parent of `/` → refused
  - f4 not a block device without the hook → refused
  - f5 confirmation `sdx` ≠ device basename → refused, and the device file is unchanged
  - f6 success: stdout shows model+size and `type the device name`; dd argv ⊇ `bs=4M conv=fsync oflag=direct status=progress`; `sudo dd` in the log
  - f7 success → `verified` and exit 0
  - f8 `MOCK_DD_CORRUPT=1` → `verify failed`, exit `RL_E_VERIFY`
  - f9 a missing IMAGE → exit 2
  - f10 sudo is used only for `dd` (write) and the read-back (G7)
- [ ] GREEN functions in rpi-deploy.sh: `flash_check_device DEV`, `flash_confirm DEV` (reads one line from stdin), `flash_write IMG DEV` (`zstdcat "$IMG" | sudo dd of="$DEV" bs=4M conv=fsync oflag=direct status=progress iflag=fullblock`), `flash_verify IMG DEV` (`len=$(zstdcat IMG | wc -c)`; compare `zstdcat IMG | sha256sum` with `sudo head -c "$len" DEV | sha256sum`).

#### Task 5.7: `deploy`  `[ ]`
- [ ] RED tests. Mock `nixos-rebuild` via `RPI_NIXOS_REBUILD=$BIN/nr-mock`, which logs argv and `NIX_SSHOPTS`. A **poison** `$BIN/nixos-rebuild` writes `POISON` to the log. A temp git repo is the flake.
  - d1 the default action is switch; argv == `switch --no-reexec --flake <flake>#rpi --target-host root@neptun`
  - d2 `boot` and `test` are passed through
  - d3 `dry-activate` → exit 2
  - d4 NIX_SSHOPTS starts with `-p 2222`; `--port 22 --target root@h` are honoured
  - d5 guard failure → 0 `nr-mock` lines (G3)
  - d6 a branch `auto-update` 1 commit ahead of HEAD → exit `RL_E_DOWNGRADE`, stderr `would downgrade`, 0 `nr-mock` lines
  - d7 the same with `--force` → deploys
  - d8 `log_count POISON` = 0 in every deploy test (the host's nixos-rebuild is never used)
  - d9 without `RPI_NIXOS_REBUILD` → the log has `nix run --accept-flake-config <flake>#nixos-rebuild --`
- [ ] GREEN: `do_deploy` runs the downgrade check first (only if `git -C "$FLAKE" rev-parse` succeeds and `refs/heads/auto-update` exists: `git rev-list --count HEAD..auto-update` > 0 ∧ ¬force → die), then `rl_guard toplevel $MAX`, then `rl_nixos_rebuild "$ACTION" --no-reexec --flake "$FLAKE#$ATTR" --target-host "$TARGET"`, then for `switch` it prints the status lines (T5.8).
- [ ] Planted: d8 row → seen red.

#### Task 5.8: `status`  `[ ]`
- [ ] RED tests (the mock `ssh` answers `readlink` of current/booted and their triplets per `$MOCK_*`):
  - s1 stdout lines `current: <path>` and `booted: <path>`
  - s2 equal triplets → `reboot pending: no`
  - s3 kernel differs → `reboot pending: yes`
  - s4 ssh failure → exit non-zero, `cannot reach root@neptun`
- [ ] GREEN: `do_status` uses `rl_ssh` + `rl_triplet_remote` + `rl_needs_reboot`.

#### Task 5.9: Pinned tool output + package  `[ ]`
- [ ] RED: create `tests/eval/tools.nix` with these messages:
  - `"apps.x86_64-linux.nixos-rebuild is the flake's 26.05 nixos-rebuild-ng"` (`apps…program == lib.getExe nixpkgs.legacyPackages.x86_64-linux.nixos-rebuild-ng` ∧ `lib.hasPrefix "26.05" nixos-rebuild-ng.version`)
  - `"packages.x86_64-linux.nixos-rebuild exists"`
  - `"rpi-deploy package ships rpi-lib.sh"` (`builtins.pathExists` cannot see into a derivation, so instead assert `lib.hasInfix "rpi-lib.sh" packages.x86_64-linux.rpi-deploy.installPhase`; the full check is the VM test)
- [ ] GREEN:
  - `apps.x86_64-linux.nixos-rebuild = { type = "app"; program = lib.getExe pkgs.nixos-rebuild-ng; meta.description = "nixos-rebuild pinned to the Pi's release"; };` and `packages.x86_64-linux.nixos-rebuild = pkgs.nixos-rebuild-ng;` (observed `/nix/store/fi6cb127…-nixos-rebuild-ng-26.05` today; the path will change with the M1 lock).
  - `mkRpiDeploy` installs `bin/rpi-deploy` and `libexec/rpi-deploy/rpi-lib.sh`. Use `wrapProgram … --set RPI_LIB $out/libexec/rpi-deploy/rpi-lib.sh --suffix PATH : <util-linux coreutils zstd gnugrep gnused gawk git openssh>`.
  - Remove the no-longer-needed `dosfstools e2fsprogs gnutar findutils`.
- [ ] Extend `rpi-deploy-syntax`: `bash -n` + `shellcheck -S warning` on `rpi-deploy.sh` and `rpi-lib.sh` (D16).
- [ ] Verify `[cheap]`: `nix run --accept-flake-config .#nixos-rebuild -- --help | head -1` runs. `nix run --accept-flake-config .#rpi-deploy -- --help` exits 0.

**M5 acceptance `[cheap]`:** `chk rpi-deploy-unit && chk rpi-deploy-syntax && chk eval-tools && nix flake check --no-build --accept-flake-config`. `[expensive, optional]` `chk rpi-host-vm` (1–16 min).

---

### M6 — Build-host cleanup + `rpi.buildHost.autoUpdate` + `rpi-autoupdate` (after M5)

**Files:** see §14. **Risk:** medium-high. This is unattended root access to the Pi and pushes to the user's repo. Mitigations:
- P11/P12 tests
- dedicated work clone
- `from=` key (M2)
- no push before the guards and the build succeed

#### Task 6.1: Drop the static emulator / F-flag / rpi-binfmt  `[ ]`
- [ ] RED: create `tests/eval/build-host.nix` with these messages:
  - `"module does not force static emulators"` (`!hostTestSystem.config.boot.binfmt.preferStaticEmulators`)
  - `"rpi-binfmt package removed"` (`!(packages.x86_64-linux ? rpi-binfmt)`)
  - `"aarch64 emulation and nvmd cache still configured"`
  - `"rpi-deploy on PATH"`
- [ ] GREEN:
  - build-host.nix: delete `boot.binfmt.preferStaticEmulators = lib.mkDefault true;` and its comment, and update the header comment ("rpi-deploy image/flash/deploy/status").
  - flake.nix: delete `contract.chrootEmulation` and its `assertMsg`; keep `sandboxPaths` (now satisfied by `extra-sandbox-paths`). Delete the `rpi-binfmt` package. Fix the `flakePath` descriptions (no `build`/`install`) in both host modules.
- [ ] Verify `[cheap]`: `chk eval-build-host` and `nix flake check --no-build --accept-flake-config` (contract asserts still hold).

#### Task 6.2: autoUpdate options + units  `[ ]`
Options:
```nix
options.rpi.buildHost.autoUpdate = {
  enable     = lib.mkEnableOption "weekly Pi security updates pushed from this host";
  user       = lib.mkOption { type = lib.types.str; };                      # no default: required
  repoPath   = lib.mkOption { type = lib.types.str; };                      # repo root (flake in nixos/)
  workDir    = lib.mkOption { type = lib.types.str; default = "/var/lib/rpi-autoupdate"; };
  target     = lib.mkOption { type = lib.types.str; default = "root@neptun"; };
  sshPort    = lib.mkOption { type = lib.types.port; default = 2222; };     # D8
  sshKey     = lib.mkOption { type = lib.types.str; };                      # str, NOT path (no store copy)
  onCalendar = lib.mkOption { type = lib.types.str; default = "Sun 03:00"; };
  maxBuilds  = lib.mkOption { type = lib.types.ints.positive; default = 500; };
  rebootTime = lib.mkOption { type = lib.types.strMatching "[0-2][0-9]:[0-5][0-9]"; default = "04:30"; };
};
```
- [ ] RED messages, on `au = hostTestSystem.extendModules { modules = [ { users.users.alice.isNormalUser = true; rpi.buildHost.autoUpdate = { enable = true; user = "alice"; repoPath = "/home/alice/rpi"; sshKey = "/var/lib/rpi-autoupdate/id_ed25519"; }; } ]; }`:
  - `"autoupdate is off by default"` (no `rpi-autoupdate` service in `hostTestSystem`)
  - `"timer Sun 03:00, Persistent, 30m jitter, in timers.target"`
  - `"timer is Persistent"`
  - `"service is a oneshot as the configured user"`
  - `"service start timeout exceeds the 4h build timeout"` (`TimeoutStartSec == "5h"`)
  - `"ExecStart passes every option"` (P13 over `--repo --work-dir --target --port --ssh-key --max-builds --reboot-time`)
  - `"sshKey is not copied into the store"`
  - `"workDir is created for the user"` (tmpfiles rule `d /var/lib/rpi-autoupdate 0700 alice - -`)
  - `"store-path sshKey is rejected"` (assertion fails for `sshKey = "/nix/store/x-key"`)
- [ ] GREEN, in build-host.nix under `lib.mkIf (cfg.enable && cfg.autoUpdate.enable)`:
  - `systemd.timers.rpi-autoupdate` (wantedBy `timers.target`; `OnCalendar`, `Persistent = true`, `RandomizedDelaySec = "30m"`)
  - `systemd.services.rpi-autoupdate`:
    - `after`/`wants` `network-online.target`
    - `path = [ config.nix.package pkgs.git pkgs.openssh pkgs.coreutils ]`
    - `serviceConfig = { Type = "oneshot"; User = au.user; TimeoutStartSec = "5h"; ExecStart = "${cfg.installScript}/bin/rpi-autoupdate " + lib.escapeShellArgs [ … ]; }`
  - `systemd.tmpfiles.rules`
  - `assertions`: `installScript != null`, absolute `repoPath`/`workDir`/`sshKey`, `!hasPrefix "/nix/store" sshKey`
- [ ] Planted: both build-host rows of §11 → seen red → reverted.

#### Task 6.3: `rpi-autoupdate.sh` (unit-tested)  `[ ]`
CLI: `rpi-autoupdate --repo PATH --work-dir PATH [--target root@neptun] [--port 2222] [--ssh-key PATH] [--max-builds 500] [--reboot-time 04:30] [--no-deploy]`. `--ssh-key` is required unless `--no-deploy`. Sources `rpi-lib.sh`; sets `RL_FLAKE=$WORK/repo/nixos` and `RPI_SSH_OPTS="-i KEY -o IdentitiesOnly=yes -o UserKnownHostsFile=$WORK/known_hosts -o StrictHostKeyChecking=accept-new"` (D9).

Algorithm (exit on the first failure, with the `RL_E_*` code; nothing before step 8 writes outside `$WORK`):
0. Refuse (exit 2) if `git -C REPO symbolic-ref --short HEAD` = `auto-update`. If `$WORK/repo` is missing, `git clone REPO $WORK/repo`. Then `git -C $WORK/repo fetch origin main && git -C $WORK/repo reset --hard origin/main`.
1. `nix flake update --accept-flake-config --flake $RL_FLAKE nixpkgs nixos-raspberrypi`.
2. `rl_cache_has $(rl_kernel_paths)`. On a miss: `git -C $WORK/repo checkout -- nixos/flake.lock`; `nix flake update … nixpkgs`; re-check; on a second miss exit `RL_E_CACHE`.
3. Dry-run guard: the `rl_check_builds` part of `rl_guard toplevel $MAX` (the cache part is already done).
4. `NEW=$(timeout 4h nix build --accept-flake-config --out-link $WORK/rpi-last-built --print-out-paths "$(rl_conf_ref).config.system.build.toplevel")`, else exit `RL_E_BUILD`.
5. If `--no-deploy`: go to step 8. If `rl_ssh readlink -f /run/current-system` = NEW: go to step 8.
6. `rl_nixos_rebuild boot --no-reexec --store-path "$NEW" --target-host "$RL_TARGET"`, else exit `RL_E_DEPLOY`.
7. If `rl_needs_reboot "$(rl_triplet_remote booted)" "$(rl_triplet_local "$NEW")"`: `rl_ssh shutdown -r "$REBOOT_TIME"`. Otherwise `rl_nixos_rebuild switch --no-reexec --store-path "$NEW" --target-host "$RL_TARGET"`.
8. If `git -C $WORK/repo diff --quiet -- nixos/flake.lock`: stop (nothing to commit). Otherwise `git -C $WORK/repo -c commit.gpgsign=false -c user.name=rpi-autoupdate -c user.email=rpi-autoupdate@localhost commit -m "auto-update: flake.lock $(date -I)" -- nixos/flake.lock && git -C $WORK/repo push --force origin HEAD:refs/heads/auto-update` (D10).

- [ ] Wire the check `autoupdate-unit` (same pattern as `rpi-deploy-unit`, files `rpi-autoupdate.sh rpi-lib.sh tests/harness.sh tests/autoupdate-unit.sh tests/fixtures`). Add `rpi-autoupdate.sh` to `rpi-deploy-syntax`, and install it as `bin/rpi-autoupdate` in `mkRpiDeploy` (same wrapper, `--set RPI_LIB`).
- [ ] RED tests. Fixture: a non-bare REPO with `main`, `nixos/flake.lock`, plus a dirty untracked user file. The `nix` mock: `flake update` appends `$*` to `nixos/flake.lock` in cwd/flake; `path-info` per `MOCK_CACHE ∈ {hit, full-miss, always-miss}`; `build --dry-run` cats a fixture; `build --print-out-paths` creates NEW with a kernel/initrd/kernel-modules triplet per `MOCK_NEW_K`. The `ssh` mock answers current/booted per `MOCK_CUR`/`MOCK_BOOT_K`. `nr-mock` logs.
  - a1 userspace-only change: log order `boot` → `switch`, no `shutdown`; the `auto-update` ref = work HEAD; exit 0
  - a2 kernel change: `boot` → `shutdown -r 04:30`, no `switch`
  - a3 NEW = current: 0 `nr-mock` lines; lock committed + pushed
  - a4 `full-miss`: log has `flake update … nixpkgs nixos-raspberrypi`, then `flake update … nixpkgs` (no nvmd), then proceeds
  - a5 `always-miss`: exit `RL_E_CACHE`; P11 (0 ssh/nr lines; `auto-update` ref unchanged/absent)
  - a6 kernel dry-run fixture: exit `RL_E_FORBIDDEN`; P11
  - a7 `--max-builds 300` with the hybrid fixture: exit `RL_E_TOO_MANY`; P11
  - a8 build fails: exit `RL_E_BUILD`; P11
  - a9 `--no-deploy` (AC5): lock committed, `auto-update` pushed, 0 ssh/nr lines
  - a10 P12: user checkout byte-identical (`find REPO -path REPO/.git -prune -o -type f -print0 | sort -z | xargs -0 sha256sum`) and `main` unchanged
  - a11 REPO has `auto-update` checked out → exit 2, nothing done
  - a12 every ssh/nr invocation carries `-p 2222`, `-i KEY`, `UserKnownHostsFile=$WORK/known_hosts`, `StrictHostKeyChecking=accept-new`
- [ ] GREEN: implement `rpi-autoupdate.sh` per the algorithm. Expected size ≈ 120 lines; if it grows beyond 150, split the git steps into `au_git_*` functions.
- [ ] Planted: both autoupdate rows of §11 → seen red → reverted.

#### Task 6.4: VM test adaptation  `[ ]`
- [ ] In `rpi-host-vm`, set node `users.users.alice.isNormalUser = true; rpi.buildHost.autoUpdate = { enable = true; user = "alice"; repoPath = "/tmp/repo"; sshKey = "/tmp/key"; };` and add to the testScript:
  - `host.succeed("systemctl cat rpi-autoupdate.timer | grep -q 'OnCalendar=Sun 03:00'")`
  - `host.succeed("rpi-autoupdate --help")`
  - `host.succeed("test -d /var/lib/rpi-autoupdate")`
- [ ] `[expensive]` `chk rpi-host-vm` (1–16 min). Planted VM row (§11) is optional.

**M6 acceptance:** `chk eval-build-host && chk autoupdate-unit && chk rpi-deploy-unit && chk rpi-deploy-syntax && nix flake check --no-build --accept-flake-config`, then `[expensive]` `chk rpi-host-vm`.

---

### M7 — Smoke tests, final acceptance, docs (after all)

**Files:** see §14. **Risk:** low for code. The expensive runs dominate the time; this milestone turns the "hoped for" scenarios into observed ones.

#### Task 7.1: Extract `tests/qemu-pi.sh` (refactor)  `[ ]`
- [ ] Before `[expensive ~6–9 min]`:
  - Build the image: `nix run .#rpi-deploy -- image --out .scratch/plan` (527–648 s plus any toplevel delta since M1).
  - Run `tests/boot-smoke.sh .scratch/plan/result-rpi-image/sd-image/neptun-rpi3.img.zst | tee .scratch/plan/smoke-before.log` → `PASS`.
- [ ] Move unpack/boot/wait code into sourced functions:
  - `qp_unpack IMG WORK` (sets `APPEND`)
  - `qp_boot WORK FWD_PORT|""` (starts qemu; sets `QPID`; adds `-netdev user,id=n0,net=192.168.100.0/24,host=192.168.100.1,hostfwd=tcp:127.0.0.1:$FWD-192.168.100.20:${RPI_SMOKE_GUEST_SSH_PORT:-2222} -device usb-net,netdev=n0` when FWD is set, else `-nic none`)
  - `qp_wait_serial REGEX TIMEOUT`
  - `qp_wait_ssh_banner PORT TIMEOUT` (bash `/dev/tcp`, reads `SSH-2.0`; avoids the host ssh_config gotcha from E3 §2)
- [ ] After: the same command → `PASS`. `diff <(grep -E '^(==>|PASS|FAIL)' smoke-before.log | sed 's/[0-9]*s/Ns/') <(… after …)` is empty.

#### Task 7.2: boot-smoke checks SSH over usb-net  `[ ]`
- [ ] RED `[expensive]`: add the stage "3. SSH banner within 300 s after expansion" with `FWD` set → run with `RPI_SMOKE_GUEST_SSH_PORT=2223` → `FAIL: no SSH banner` (planted row seen).
- [ ] GREEN: the default guest port 2222 → `PASS (… SSH reachable on 127.0.0.1:<port>)`. Budget: E3 boot-to-ssh ≈ 100–111 s after kernel start (first boot includes the resize). Update the header comment (headless: the screenshot may show no login prompt; SSH is now the userspace criterion).

#### Task 7.3: `tests/deploy-smoke.sh`  `[ ]`
- [ ] Write the script (from E3), `[expensive ~20–25 min warm]`:
  1. `WORK=${RPI_SMOKE_DIR:-$PWD/.scratch/deploy-smoke}`; `ssh-keygen -t ed25519 -N '' -f $WORK/key`.
  2. Generate `$WORK/flake/flake.nix`:
     - `inputs.rpi.url = "git+file://<repo>?dir=nixos";`
     - `smoke-image = rpi.nixosConfigurations.rpi.extendModules { modules = [ ({ lib, ... }: { users.users.root.openssh.authorizedKeys.keys = lib.mkForce [ "<key.pub>" ]; }) ]; };`
     - `smoke-next = smoke-image.extendModules { modules = [ { environment.etc."rpi-smoke-marker".text = "next\n"; } ]; };`
     - `apps = rpi.apps; packages = rpi.packages;`
     - Use the `path:` scheme for this flake (E3 §1).
  3. `nix build path:$WORK/flake#nixosConfigurations.smoke-image.config.system.build.sdImage`.
  4. `qp_unpack` + `qp_boot WORK $FWD` + `qp_wait_ssh_banner`.
  5. `RPI_SSH_OPTS="-i $WORK/key -o IdentitiesOnly=yes -o UserKnownHostsFile=$WORK/known_hosts -o StrictHostKeyChecking=accept-new -F /dev/null" nix run .#rpi-deploy -- deploy switch --flake $WORK/flake --attr smoke-next --target root@127.0.0.1 --port $FWD`.
  6. Assert `ssh … cat /etc/rpi-smoke-marker` = `next`, assert `readlink /run/current-system` = `nix eval --raw path:$WORK/flake#nixosConfigurations.smoke-next.config.system.build.toplevel.outPath`, and assert `rpi-deploy status …` prints `reboot pending: no`.

  Note: the guards run against live cachix; the throwaway attrs share the kernel.
- [ ] RED: the planted marker row (§11) → seen red. GREEN: `PASS` with the timings logged (eval / build / copy / activation, as in E3 `rebuild3.log`).

#### Task 7.4: Final acceptance (AC1–AC5)  `[ ]`
- [ ] AC1 `[expensive: includes rpi-host-vm]`: `nix flake check --accept-flake-config -L 2>&1 | tee .scratch/plan/flake-check.log` → rc 0.
- [ ] AC2: `nix run .#rpi-deploy -- image --out .scratch/plan 2>&1 | tee .scratch/plan/image.log`.
  - `grep -E "building '/nix/store/[a-z0-9]{32}-(linux_rpi-[^']*[0-9]|linux-config-[^']*)\.drv'" .scratch/plan/image.log` → no match.
  - boot-smoke `PASS` (T7.2).
- [ ] AC3: `nix path-info -S --json $(nix build --accept-flake-config --no-link --print-out-paths $R.system.build.toplevel) | jq '.[].closureSize'` → ≤ 3543348019 bytes (3.3 GiB). Record the value; if it fails, report it (do not trim nix-terminal; that was rejected by the user).
- [ ] AC4: T7.3 `PASS`.
- [ ] AC5 `[expensive: real lock update + build]`: `rpi-autoupdate` ships in the `rpi-deploy` package.
  - Run `nix shell --accept-flake-config .#rpi-deploy -c rpi-autoupdate --repo /home/pallon/projects/raspberry-pi --work-dir $PWD/.scratch/au-work --no-deploy`.
  - Then `git -C .. log -1 --format=%s auto-update` → `auto-update: flake.lock <date>`. `git -C .. rev-parse main` and `git -C .. status --porcelain` are unchanged from before.
  - Tell the user that branch `auto-update` now exists.

#### Task 7.5: Docs + manual hardware checklist  `[ ]`
- [ ] README.md, rewritten:
  - Repo layout, and build host setup with `autoUpdate`: key generation `ssh-keygen -t ed25519 -f /var/lib/rpi-autoupdate/id_ed25519 -N ''` (owned by `user`), then the public key goes into `nixos/keys.nix` with `hostAddress`.
  - Image → flash → first boot (no `/etc/nixos`; root and pi key-only on port 2222).
  - deploy (`switch|boot|test`, `--force` and the downgrade warning) and status.
  - Auto-update: branch `auto-update`, merge it, emergency run `systemctl start rpi-autoupdate`, logs `journalctl -u rpi-autoupdate`, and after a re-flash `rm $workDir/known_hosts`.
  - Recovery: `nixos-rebuild switch --rollback` via `nix run .#nixos-rebuild -- … --target-host`, or edit `DEFAULT` in `/boot/extlinux/extlinux.conf` on the SD from the host. No boot counting.
  - External disk migration: copy data, enable, `deploy boot`, reboot.
  - Testing: checks + durations.
  - Delete everything about prepare/install/chroot/F-flag/secrets.
- [ ] HANDOFF.md: replace §4/§8/§9 with the current status, keep the decision record, and link the spec and this plan.
- [ ] `../.gitignore`: drop `.rpi-build.log` and `.rpi-build/` only if the user agrees; the local artifacts exist (Q7).
- [ ] Manual checklist (AC6) as a section in README (§12 of this plan).

**M7 acceptance:** T7.1–T7.4 green, with the logs in `.scratch/plan/`. README renders. `git status` shows only the intended files.

---

## 16. Open questions (defaults used if unanswered)

1. **Q1 Auto-update key and host address.** What are the public key of the dedicated auto-update key and andromeda's LAN address for `from=`? Default: `keys.nix` with `autoUpdate = null; hostAddress = null;`, so only the user key is on root and the unattended job cannot log in until both are filled in.
2. **Q2 Name resolution.** Does `neptun` resolve from the host? Is a root key equal to `pi`'s current key acceptable? Default: target `root@neptun`, port 2222, the same user key for root and pi.
3. **Q3 `hardware.enableAllHardware`.** It comes from nixpkgs sd-image.nix and enlarges the initrd module set. Keep it (E3 parity), or `mkForce false` (parity with the hardware-proven `rpi`)? Default: keep (D12).
4. **Q4 `--no-deploy` builds the toplevel** (so the pushed lock is known to build). Default: yes.
5. **Q5 Unattended commits.** They are unsigned (`commit.gpgsign=false`), with identity `rpi-autoupdate <rpi-autoupdate@localhost>`, and force-pushed to `auto-update`. Acceptable? Default: yes (D10).
6. **Q6 Guard override.** Is there an escape hatch (`--no-guard`) for an intentional local kernel build? Default: none (YAGNI; plain `nix build` remains possible).
7. **Q7 Local leftovers.** The untracked `secrets/wireless.env` (contains a PSK), `.rpi-build/` and `.rpi-build.log` at the repo root: delete them, and drop their `.gitignore` lines? Default: leave the files and tell the user; drop only the secrets ignore lines.
8. **Q8 Parallel execution.** It needs worktrees, which need M1 committed (sandbox commits fail). Will the user commit after M1, or should M2–M5 run in sequence in one tree? Default: sequential unless main arranges worktrees.
9. **Q9 Spec deviation C1/C2.** OK to add `sshPort` and the extra deploy flags (`--flake --attr --port --max-builds`)? Default: yes.
10. **Q10 llm-agents.** The spec says it "follows our nixpkgs as today", but today it has no follows. Default: leave it unchanged.
