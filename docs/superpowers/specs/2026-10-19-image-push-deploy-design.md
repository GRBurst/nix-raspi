# Design: build here, flash once, push updates (Raspberry Pi 3B "neptun")

Date: 2026-10-19 · Status: approved direction (user, 2026-10-19), spec for planning
Evidence: `nixos/.scratch/research-landscape.md`, `nixos/.scratch/{e2,e3,s5,s6}/REPORT.md`
(untracked experiment reports; key numbers are copied below).

## 1. Intent

The Pi 3B (1 GiB RAM, SD card) is a best-effort, unreliable home server on
wired LAN only. It runs Pi services and lightweight development tooling
(nix-terminal stays). The x86_64 NixOS host (andromeda) builds everything.
Success means:

- A card is produced by building one image and writing it once; no chroot,
  no root-owned mounts, no binfmt tricks during install.
- Configuration changes and security updates reach the Pi by push from the
  host; the Pi never evaluates the flake (eval needs ~1.08 GB RSS).
- Security updates happen automatically (weekly), never trigger a local
  kernel build, and leave the Pi untouched when anything goes wrong.
- SD-card writes are reduced where evidence shows benefit; an external USB
  disk can be added later by configuration only, SD stays the boot device.

Downtime and loss of logs/volatile state on power cut are acceptable; an
unbootable system or a corrupt store are not.

## 2. Evidence summary

| Question | Result |
|---|---|
| Emulated native (`system = aarch64-linux` + binfmt) vs cross (`buildPlatform`) | native: 0 builds (all cached); cross: 1474 builds + 8 GiB (E1) |
| SD image boots | qemu raspi3b reaches login, first-boot expansion works (HANDOFF §10, E3) |
| Image build time | 527 s all-aarch64; 225 s with x86 image step (E2) — not adopted (§9) |
| Push deploy | `nixos-rebuild` 26.05 `--no-reexec --target-host root@…` works incl. nvmd bootloader update of /boot + /boot/firmware: 78–159 s. Host's 26.11 nixos-rebuild fails half-way (`systemd-run --output=cat`) (E3) |
| Non-root deploy | fails without `trusted-users` and sudo password (E3) |
| On-Pi update (`autoUpgrade`, comin) | eval RSS 1.08 GB on a 1 GiB Pi; currently also broken (flakes off, no /etc/nixos) (E4, E3) |
| Newer nixpkgs without kernel rebuild | "hybrid" inputs (own nixpkgs, nvmd keeps its pin, passed via `nixos-raspberrypi.lib.nixosSystem { inherit nixpkgs; }`): kernel hash == nvmd's, cached; ~377 small builds (s5) |
| nvmd cache cadence | cachix CI on every push; `develop` lock bumps weekly; `main` only at releases (last 2026-08-01, kernel 6.18.34 vs develop 6.18.52) (s5) |
| What writes the SD | closure 4.0 GiB/1015 paths; linux-firmware 770 MiB, nixpkgs source 479 MB, home-manager-path 2.4 GiB (kept by decision) (s6, verified) |

## 3. Architecture

```
host (x86_64, binfmt aarch64, caches)                Pi 3B (aarch64)
 flake nixos/  ──eval+build──► toplevel ──┬─ image ─► .img.zst ─flash─► SD (once)
                                          └─ push ─► nixos-rebuild 26.05 --target-host root@neptun
 systemd timer rpi-autoupdate (weekly): lock update ─ guard ─ build ─ boot/switch ─ reboot if kernel changed
```

One NixOS configuration describes the Pi: `nixosConfigurations.rpi`
(alias `neptun`). The image is a build output of that same configuration
(`config.system.build.sdImage`), so the flashed system and later deploys
share one definition. Separate `rpi-image`/`rpi-image-nvmd` outputs go away.

### 3.1 Flake inputs ("hybrid")

- `nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05"` — own input, no
  `follows` to nvmd. Userspace security fixes track the release branch head.
- `nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/develop"` —
  keeps its own nixpkgs pin, so its kernel/firmware hashes match its cachix.
- `nixos-raspberrypi.lib.nixosSystem { inherit nixpkgs; … }` builds `rpi`.
- home-manager, nix-terminal, llm-agents follow our `nixpkgs` as today.
- Invariant (asserted by a flake check): the kernel used by `rpi`
  (`config.boot.kernelPackages.kernel`) equals the kernel of nvmd's own
  package set for the Pi 3 (same out path). Out-of-tree kernel modules must
  come from `config.boot.kernelPackages`.

### 3.2 Pi configuration changes (`configuration.nix` + new modules)

Deployment access
- root SSH login: `PermitRootLogin = "prohibit-password"`, key-only.
  root's authorized keys: the user's key (manual deploys) and a dedicated
  auto-update key restricted with `from="<host LAN address>"`.
- `pi` keeps its key; `security.sudo.wheelNeedsPassword = false` (pi has no
  password; access is key-only, equivalent trust to the root key). Flagged
  for review (§10).

Remove
- `system.autoUpgrade` (rejected: on-Pi eval).
- wifi block, `hardware.firmware = [wireless-regdb]`, `cf680211` modprobe
  line, `systemd.services.iwd` override, `secrets/` + `wireless.env*`.
- `/etc/nixos` copying expectations; the Pi needs no flake checkout.

Boot/GC hygiene
- `boot.loader.generic-extlinux-compatible.configurationLimit` (or the
  nvmd equivalent, verify name) = 5.
- `nix.gc = { automatic = true; dates = "weekly"; options = "--delete-older-than 21d"; }`.
- `nix.settings.trusted-users` unchanged (root deploys need nothing).
- Keep `nixpkgs.flake.setFlakeRegistry`/`setNixPath` = true: lightweight
  development (`nix shell nixpkgs#…`) then uses the exact system nixpkgs
  (no extra download, cache hits). `nix.channel.enable = false`.

SD-write reduction (`modules/sd-wear.nix`, enabled by default; option
names verified in s6 against the pinned nixpkgs/nvmd)
- `hardware.enableRedistributableFirmware = lib.mkForce false`,
  `hardware.firmware = lib.mkForce []` (−770 MiB; wired LAN needs none).
- root ext4 options: `noatime`, `lazytime`, `commit=60`.
- `boot.tmp.useTmpfs = true; boot.tmp.tmpfsSize = "256M";` (Nix builds use
  `/nix/var/nix/builds`, not /tmp).
- journald: `Storage=volatile`, `RuntimeMaxUse=16M`, `MaxLevelStore=info`
  (no native "RAM then periodic flush" mode; log2ram/folder2ram/asd are not
  in nixpkgs and idle writes are small — not adopted).
  Optional `services.journald.upload` to a remote collector: off by default.
- `systemd.coredump.enable = false`; `nix.settings.keep-derivations = false`.
- `services.fstrim.enable = true; services.fstrim.interval = "monthly";`
  (no `discard` mount option).
- zram: keep 50 %, `boot.kernel.sysctl."vm.swappiness" = 100`,
  `"vm.page-cluster" = 0`.

Headless profile (`modules/headless.nix`, enabled by default)
- `hardware.raspberry-pi.config.all`: `gpu_mem=16`, `dtoverlay=disable-wifi`,
  `dtoverlay=disable-bt`, vc4-kms overlay off, audio off, camera/display
  auto-detect off; drop `cma=32M` kernel param.
- Console: serial only; HDMI console is lost (accepted).
- Verification gate: boot-smoke in qemu plus one real-hardware boot (§8).

External disk (`modules/external-storage.nix`, disabled by default)
- `rpi.storage.external = { enable = false; label = "PI_DATA"; fsType = "ext4"; bind = [ "/nix" "/var" "/home" ]; swapSize = null; }`.
- When enabled: mount `/dev/disk/by-label/<label>` at `/external`
  (`neededForBoot = true`, `nofail` not allowed for /nix), bind-mount each
  `bind` entry from `/external/<name>`, optional swapfile. SD keeps
  `/boot/firmware` and `/boot` (kernels/initrd/extlinux on the SD root).
- Migration is a documented manual procedure (copy data, enable, deploy
  with `boot`, reboot). No change to image or deploy flow.

### 3.3 Host side

`rpi-deploy` (rewritten, small) — subcommands:
- `image [--out DIR]`: `nix build .#nixosConfigurations.rpi.config.system.build.sdImage`
  after the cache guard (§3.4); prints image path and size.
- `flash IMAGE DEVICE`: refuses non-removable/mounted/system devices,
  shows device model+size and requires typing the device name; writes with
  `zstdcat | dd bs=4M conv=fsync oflag=direct status=progress` via sudo
  (only privileged step); verifies by reading back the written length and
  comparing a hash.
- `deploy [switch|boot|test] [--target root@neptun]`: runs the flake's
  pinned `nixos-rebuild` (flake app `nixos-rebuild`, from our nixpkgs) with
  `--no-reexec --flake .#rpi --target-host`. Warns and refuses if branch
  `auto-update` has commits not in HEAD (would downgrade), unless `--force`.
- `status`: current/booted generation on the Pi, and whether a reboot is
  pending (booted kernel ≠ current kernel).
- Removed: `prepare`, `install`, `config`, `eject`, build records,
  `--from`, F-flag handler, chroot checks.

Flake apps/packages: `apps.x86_64-linux.nixos-rebuild` (pinned),
`packages.x86_64-linux.rpi-deploy`. Fix: the flake currently references
`./rpi-deploy.sh` but the script sits at the repo root since the move into
`nixos/`; the script moves into `nixos/`.

Build-host module (`modules/build-host.nix`)
- Keep: `boot.binfmt.emulatedSystems = [ "aarch64-linux" ]`, nix
  features, nvmd cachix substituter + key, rpi-deploy on PATH.
- Drop: `preferStaticEmulators` requirement and the F-flag/chroot contract
  assert (no chroot anymore); `rpi-binfmt` package.
- Add `rpi.buildHost.autoUpdate` (§3.4).

### 3.4 Automatic security updates (host timer)

Option set `rpi.buildHost.autoUpdate = { enable; user; repoPath; workDir; target = "root@neptun"; sshKey; onCalendar = "Sun 03:00"; maxBuilds = 500; rebootTime = "04:30"; }`.

Lock handling: the job never touches the user's checkout. It keeps a
dedicated clone in `workDir`, each run: fetch `main` from `repoPath`,
reset to it, update the lock, commit, and push the commit to branch
`auto-update` in `repoPath` (never the checked-out branch). The user merges
`auto-update` at leisure; `rpi-deploy deploy` warns before downgrading.

Run (systemd oneshot, `Persistent=true`, `RandomizedDelaySec=30m`):
1. `nix flake update nixpkgs nixos-raspberrypi`.
2. Cache guard: kernel + kernel-modules out paths must exist in nvmd's
   cachix (`nix path-info --store https://nixos-raspberrypi.cachix.org`).
   If not: restore the lock, `nix flake update nixpkgs` only, re-check; still
   missing → exit (Pi untouched).
3. Build guard: `nix build --dry-run` must not list a kernel, linux-config,
   gcc/llvm/rustc/ghc/nodejs build and at most `maxBuilds` derivations.
4. Build toplevel (timeout 4 h); GC-root it.
5. If equal to the Pi's `/run/current-system` → commit lock, stop.
6. `nixos-rebuild boot --store-path NEW --target-host` (pinned tool).
7. If kernel/initrd/kernel-modules equal the booted ones →
   `nixos-rebuild switch --store-path NEW`; else `shutdown -r <rebootTime>`.
8. Commit + push lock to `auto-update`. Failures are logged to the journal;
   a failed run leaves the Pi on its previous generation.

The same guards (2–3) are used by `rpi-deploy image` and `deploy`.

## 4. Error handling

- Every guard failure exits non-zero before touching the Pi.
- `boot` before `switch`: an interrupted copy/activation never changes the
  running system; the bootloader entry only changes after the closure is
  complete.
- Unbootable kernel after reboot: no automatic fallback (U-Boot extlinux has
  no boot counting). Recovery: pick an older entry via serial console or
  edit `extlinux.conf` DEFAULT on the SD from the host. Accepted (best-effort).
- Rollback of userspace: `nixos-rebuild switch --rollback --target-host`.

## 5. Testing

- Unit tests for `rpi-deploy` (mocked nix/ssh/dd): flash device checks,
  deploy downgrade warning, guard parsing of dry-run output, autoupdate
  decision logic (switch vs reboot). Replace `tests/deploy-unit.sh`.
- `nix flake check`: syntax, unit tests, kernel-equals-nvmd assert,
  build-host VM test (adapted: no F flag), evaluation of the external-storage
  module enabled in a test config (fileSystems as expected).
- `tests/boot-smoke.sh` on the built image (qemu raspi3b): login prompt,
  expansion; extended with usb-net + SSH reachability (from E3).
- `tests/deploy-smoke.sh` (optional, slow, from E3): boot image in qemu,
  deploy a change with `rpi-deploy deploy`, verify new generation.
- Real hardware acceptance (manual, §8).

## 6. Migration of the existing Pi

The running Pi was installed with the old flow (same labels) and only
allows `pi` without sudo password or trusted-users, so a push deploy to it
is impossible. Chosen path: re-flash with the new image (state on the Pi is
disposable per "unreliable home server").

## 7. Out of scope

Netboot, USB-only boot (OTP bit), deploy-rs/colmena, secrets management
(no secrets remain after dropping wifi), remote journal collector setup,
cross-compilation, x86-native image step.

## 8. Acceptance criteria

1. `nix flake check` passes on the host.
2. `rpi-deploy image` builds without compiling a kernel; the image boots in
   boot-smoke (login prompt, SSH reachable via usb-net).
3. Closure of `rpi` toplevel ≤ 3.3 GiB (from 4.0 GiB; linux-firmware gone).
4. Deploy smoke (qemu): `rpi-deploy deploy switch` applies a change.
5. Auto-update dry run (`--no-deploy` flag) updates the lock in the work
   clone, passes guards, pushes to `auto-update`, deploys nothing.
6. Manual on hardware: flashed card boots, SSH as root and pi works, the
   headless config.txt takes effect (`vcgencmd get_mem gpu` = 16M), a
   `deploy switch` and a kernel-changing `deploy boot`+reboot work.

## 9. Decisions and rejected alternatives

- Cross-compilation: rejected (cache misses, nvmd #195).
- `nixos-install` in chroot: replaced by image (no chroot/F flag).
- x86-native image derivation: rejected by user (−5 min once per card vs
  ~60 lines duplicated from nixpkgs).
- systemd-repart image: GPT-only, no Pi variant.
- nixos-anywhere: no kexec on Pi kernels.
- On-Pi updates (autoUpgrade, comin, bento): eval RAM.
- Pull mode / cachix-deploy / deploy-rs: more moving parts, host must be up
  anyway (cache on host) or external SaaS.
- nvmd `main`: kernel only at releases (months); `develop` + cache guard
  gives timely kernels without local builds.
- Trimming nix-terminal: rejected by user (dev tooling on the Pi).
- f2fs/btrfs root, `discard`, `auto-optimise-store`, `fsync-metadata=false`:
  rejected (s6).

## 10. Open points flagged for review

- `wheelNeedsPassword = false` for `pi` (default chosen here).
- Auto-update pushes to branch `auto-update`; user merges manually.
- First deploy to the currently running Pi = re-flash (§6).
