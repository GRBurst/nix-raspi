# rpi — Raspberry Pi 3 Model B (V1.2) NixOS: build here, flash once, push updates

Headless NixOS system (no display server) for a Raspberry Pi 3 Model B V1.2
(hostname `neptun`, `aarch64-linux`, 1 GiB RAM, SD card, wired LAN only), plus
everything the x86_64 NixOS build host needs: aarch64 emulation, the
`rpi-deploy` tool and a weekly security-update job.

```
host (x86_64, binfmt aarch64, caches)                Pi 3B (aarch64)
 flake nixos/  ──eval+build──► toplevel ──┬─ image ─► .img.zst ─flash─► SD (once)
                                          └─ push ─► nixos-rebuild 26.05 --target-host root@neptun
 systemd timer rpi-autoupdate (weekly): lock update ─ guard ─ build ─ boot/switch ─ reboot if kernel changed
```

- **One definition.** `nixosConfigurations.rpi` (alias `neptun`) is both the
  flashed image (`config.system.build.sdImage`) and every later deploy.
- **The Pi never evaluates the flake** (eval needs ~1.08 GB RSS). No
  `/etc/nixos`, no `autoUpgrade`, no wifi secrets. Everything is built on the
  host and pushed over SSH.
- **No local kernel build, ever.** The vendor kernel comes prebuilt from the
  [nvmd/nixos-raspberrypi](https://github.com/nvmd/nixos-raspberrypi) cachix;
  `rpi-deploy` and the weekly job refuse to run when that cannot hold.
- NixOS 26.05, user `pi` (wheel, login shell zsh from the
  [nix-terminal](https://github.com/grburst/nix-terminal) kit), SSH on port
  **2222**, key-only for `pi` and `root`, static IP `192.168.100.20/24`.
- Fewer SD writes (`rpi.sdWear`: no firmware blobs, relaxed ext4 write-back,
  volatile journal, tmpfs `/tmp`), headless `config.txt` (`rpi.headless`),
  optional USB data disk (`rpi.storage.external`, off by default).
- Design: `docs/superpowers/specs/2026-10-19-image-push-deploy-design.md`,
  plan: `docs/superpowers/plans/2026-10-19-image-push-deploy.md`, status and
  hardware checklist: `HANDOFF.md`.

## Repo layout

```
nixos/
  flake.nix            Pi system, build-host modules, rpi-deploy package, apps, checks
  flake.lock           pins: our nixpkgs + nvmd (develop) + home-manager + ...
  configuration.nix    the Pi NixOS config
  keys.nix             ssh public keys of the Pi (user, auto-update key, host address)
  home.nix             Home Manager config of user `pi`
  modules/
    sd-image.nix         the SD image as a build output of the Pi system
    sd-wear.nix          rpi.sdWear      — fewer SD writes, no firmware blobs
    headless.nix         rpi.headless    — config.txt without display/audio/wifi/bt
    external-storage.nix rpi.storage.external — optional USB data disk
    build-host.nix       NixOS module (host): aarch64 emulation, rpi-deploy, rpi.buildHost.autoUpdate
    build-host-home.nix  Home Manager module (host): rpi-deploy on the PATH only
  rpi-deploy.sh        rpi-deploy: image / flash / deploy / status
  rpi-autoupdate.sh    the weekly job (run by the systemd service)
  rpi-lib.sh           guards, ssh helpers, reboot decision (shared by both)
  tests/               unit tests, eval checks, qemu smoke tests (see "Testing")
docs/superpowers/      spec and plan
```

All commands below run in `nixos/` of your checkout unless noted; with
`rpi.buildHost.flakePath` set (below) `rpi-deploy` works from anywhere.

## 1. Build host setup

### A. NixOS build host (module)

In your host flake:

```nix
inputs.pi = {
  url = "git+file:///home/pallon/projects/raspberry-pi/nixos";
  inputs.nixpkgs.follows = "nixpkgs";   # only the module is used on the host
};
```

```nix
modules = [
  inputs.pi.nixosModules.rpiBuildHost
  {
    rpi.buildHost.enable = true;
    # optional: pre-sets RPI_FLAKE so `rpi-deploy` needs no --flake
    rpi.buildHost.flakePath = "/home/pallon/projects/raspberry-pi/nixos";
    # weekly security updates: see section 4
  }
];
```

then `nixos-rebuild switch`. That gives you:

- `boot.binfmt.emulatedSystems = [ "aarch64-linux" ]` (qemu user mode). The
  nixpkgs binfmt module also exposes the handler to the nix sandbox
  (`extra-sandbox-paths`) and adds `aarch64-linux` to `extra-platforms`, so
  aarch64 builds work out of the box. Nothing runs in a chroot any more, so no
  static emulator / binfmt F flag is needed;
- `nix` features `nix-command` and `flakes`, and the nixos-raspberrypi binary
  cache (`rpi.buildHost.nvmdCache`);
- `rpi-deploy` and `rpi-autoupdate` on the PATH;
- optionally the weekly update timer (`rpi.buildHost.autoUpdate`).

Without aarch64 emulation every aarch64 derivation fails with
`builder failed with exit code 255` (an emulation problem, not a configuration
problem).

### B. Non-NixOS host (Home Manager module)

For the script only (you manage binfmt yourself, e.g. `binfmt-support` plus
`extra-platforms = aarch64-linux` in `nix.conf`):

```nix
home-manager.users.alice = {
  imports = [ inputs.pi.homeModules.rpiBuildHost ];
  rpi.buildHost.enable = true;
  rpi.buildHost.flakePath = "/home/alice/projects/raspberry-pi/nixos";
};
```

The weekly job is a NixOS-module feature (systemd system units).

### C. ssh access to the Pi

The tools address the Pi as `root@neptun`, port 2222. Add to `~/.ssh/config`
on the host:

```
Host neptun
  HostName 192.168.100.20
  Port 2222
```

(`rpi-deploy` also passes `-p 2222` itself, `--port` changes it; the weekly
job runs as your user and reads the same file to resolve `neptun`. If you
would rather not rely on it, set `rpi.buildHost.autoUpdate.target =
"root@192.168.100.20"`.)

Your own key (`user` in `nixos/keys.nix`) logs in as `pi` and as `root`.

## 2. First install: image, flash, boot

```sh
nix run .#rpi-deploy -- image --out ~/rpi-images   # or: rpi-deploy image
rpi-deploy flash ~/rpi-images/result-rpi-image/sd-image/neptun-rpi3.img.zst /dev/sdX
```

**`image [--out DIR] [--flake DIR] [--attr NAME] [--max-builds N]`** builds
`config.system.build.sdImage` of the Pi system and prints the image path and
size. Before building it runs the guards (kernel and kernel modules are in
nvmd's cachix; the dry run lists no kernel, linux-config, gcc/llvm/rustc/ghc/
nodejs build and at most `--max-builds`, default 500, local builds). A failed
guard exits non-zero before anything is built. The first build takes ~35 min
(measured: 379 local builds, mostly cheap; `blink-cmp` compiles under qemu),
an image after a small change ~10 min. `~/rpi-images/result-rpi-image` is a GC
root.

The image: two partitions on an MBR, found by **label**, disk id `0x2175794e`.

| partition | size    | fs    | label        | mounted at       | holds                                   |
|-----------|---------|-------|--------------|------------------|-----------------------------------------|
| p1        | 256 MiB | FAT32 | `NIXOS_BOOT` | `/boot/firmware` | Pi firmware, `config.txt`, U-Boot, DTBs |
| p2        | rest    | ext4  | `NIXOS_SD`   | `/`              | system, `/boot` (kernel, initrd, extlinux) |

Kernels and initrds live on the ext4 root (U-Boot reads them there), so the
number of generations never fills the 256 MiB firmware partition. The first
boot expands p2 to the card (needs ≥ 5 GiB).

**`flash IMAGE DEVICE`** writes the image with
`zstdcat | sudo dd bs=4M conv=fsync oflag=direct status=progress` and reads it
back (`sudo head -c LEN DEVICE | sha256sum` against the image). It refuses:
anything that is not a block device, a partition instead of a whole disk, a
non-removable disk (an `mmcblkN` reader counts as removable: Linux never sets
the flag on MMC), the disk that holds the host's `/`, a device with mounted
partitions, and a missing or wrong confirmation: you must type the device name
(`type the device name (sdX):`). Writing is the only privileged step (plus the
read-back); the image is 1.3 GiB compressed, 4.2 GiB raw, ~4 min each way at
20 MB/s.

**First boot.** Insert the card, power the Pi (network cable in):

```sh
ssh -p 2222 pi@neptun        # or root@neptun: both with your key, no password
```

Expect about a minute or two (first-boot expansion, host key generation; unmeasured on hardware, ~100 s under qemu, which is ~5x slower). After a
re-flash the host key changes: `ssh-keygen -R '[192.168.100.20]:2222'` (and see
section 4 for the weekly job's `known_hosts`).

## 3. Deploying changes and `status`

```sh
rpi-deploy deploy [switch|boot|test] [--target USER@HOST] [--port N] [--flake DIR] [--attr NAME] [--max-builds N] [--force]
rpi-deploy status [--target USER@HOST] [--port N]
```

`deploy` runs the guards, then the flake's **pinned** `nixos-rebuild`
(`apps.x86_64-linux.nixos-rebuild`, nixos-rebuild-ng from our 26.05 nixpkgs:
`nix run .#nixos-rebuild -- …`) with `--no-reexec --flake .#rpi --target-host
root@neptun`. Never the host's own `nixos-rebuild`: a newer one half-applies
on the Pi (it passes a `systemd-run` flag the Pi's systemd lacks; E3).

| action   | effect |
|----------|--------|
| `switch` (default) | build, copy, make it the boot default and activate now; prints `status` afterwards |
| `boot`   | make it the boot default, activate at the next reboot (use for kernel or firmware changes; `status` then shows `reboot pending: yes`) |
| `test`   | activate now, boot default unchanged (gone after a reboot) |

After every deploy (also a failed one) the Pi runs `sync`: switch and boot
rewrite the vfat `NIXOS_BOOT` partition, and `switch-to-configuration` only
flushes the store's filesystem. A power cut before the flush can corrupt the
firmware files (section 5).

A deploy takes a few minutes: measured in qemu (TCG, ~5x slower than a Pi 3)
276 s = guards 23 s, local build + copy 43 s, firmware copy to the FAT partition
137 s (every switch rewrites all firmware files), extlinux 6 s, activation
56 s. Expect clearly less on the real Pi [?].

**Downgrade protection.** If the `flake.lock` on branch `auto-update` pins a
newer `nixpkgs` or `nixos-raspberrypi` (its `locked.lastModified`) than the
`flake.lock` in your working tree, `deploy` refuses with `would downgrade`
(the weekly job already deployed newer pins). It compares lock content, not
commits: after a squash-merge, cherry-pick or your own `nix flake update` the
lock is current and `deploy` proceeds, even though `auto-update` still has a
commit `HEAD` lacks. If a lock cannot be read it refuses too (`cannot
compare`). Merge the branch (`git merge auto-update`) or override with
`--force`.

**`status`** prints:

```
current: /nix/store/…-nixos-system-neptun-…     # running now
booted: /nix/store/…-nixos-system-neptun-…      # running since the last boot
default: /nix/store/…-nixos-system-neptun-…     # what the next boot starts
reboot pending: no
```

`reboot pending: yes (…)` means a reboot would change the running system, for
one or both reasons:

- `the boot default is not the running system`: after `deploy boot` (or
  `test`);
- `changed since boot: kernel, fat, …`: a boot-critical part of the boot
  default differs from the booted system's (after a `switch` to a new kernel or
  firmware). The parts (the *boot fingerprint*, `rl_fp_*` in `rpi-lib.sh`):
  `kernel`, `initrd`, `kernel-modules`, `dtbs`, `kernel-params`, and `fat` --
  the inputs of the `NIXOS_BOOT` partition (Pi firmware package, generated
  `config.txt`, U-Boot), read from the toplevel's bootloader installer.

Exit codes (all subcommands): 2 usage, 10 kernel not cached, 11 forbidden local
build, 12 too many local builds, 13 build/eval failed, 14 deploy failed,
15 would downgrade, 16 device refused, 17 verify failed. There is no
override for the guards (plain `nix build` stays possible if you really want a
local kernel build; expect 16+ h under qemu).

Environment: `RPI_FLAKE` (default flake dir), `RPI_SSH_OPTS` (extra ssh
options), `RPI_NIXOS_REBUILD` (use this `nixos-rebuild` instead of the pinned
one), `RPI_CACHE_URL`.

## 4. Automatic security updates (the weekly job)

Every Sunday 03:00 (`Persistent=true`, up to 30 min random delay) the host runs
`rpi-autoupdate`:

1. clone/reset a **dedicated work clone** in `workDir` to branch `main` of
   your repo (your checkout is never touched), `nix flake update nixpkgs
   nixos-raspberrypi`;
2. cache guard: the new kernel must be in nvmd's cachix, otherwise restore the
   lock and update `nixpkgs` only, check again; still failing → exit, the Pi
   is untouched;
3. build guard (no kernel/toolchain build, at most `maxBuilds`), build the
   toplevel (4 h limit), GC-rooted in `workDir`;
4. equal to what the Pi runs → nothing to deploy;
5. compare the boot fingerprint of the new system with the Pi's booted one
   (section 3, `status`): equal → `nixos-rebuild switch`, `sync`; different
   (kernel, initrd, modules, device trees, kernel parameters, firmware,
   `config.txt` or U-Boot) → `nixos-rebuild boot`, `sync`, `shutdown -r 04:30`
   on the Pi. Decided before deploying, so the bootloader is installed once;
   the reboot right after the update makes firmware breakage show up then, not
   at some later power cut;
6. commit `flake.lock` (`auto-update: flake.lock <date>`, unsigned, identity
   `rpi-autoupdate`) and **force-push it to branch `auto-update`** of your repo.

Every guard or build failure exits before the Pi is contacted; a failed run
leaves the Pi on its previous generation and nothing is pushed. There is no
automatic fallback after a bad kernel (section 5).

> **What the job deploys.** The job deploys **`main` + an updated lock**, not
> your working branch. Anything you deployed manually from an unmerged branch
> **is replaced by the next weekly run** (the job builds `main`'s config).
> Merge your work into `main` before the run you want it to survive.

### Setup (once)

1. **Key** (dedicated, passphrase-less, only usable from the host):

   ```sh
   ssh-keygen -t ed25519 -N '' -C rpi-autoupdate@andromeda -f ~/.ssh/rpi-autoupdate
   ```

2. **Public key into the Pi config.** Paste the content of
   `~/.ssh/rpi-autoupdate.pub` into `nixos/keys.nix` as `autoUpdate`:

   ```nix
   autoUpdate = "ssh-ed25519 AAAA… rpi-autoupdate@andromeda";
   hostAddress = "192.168.100.115";   # the host's LAN address, as the Pi sees it
   ```

   It lands in `root`'s authorized keys with `from="<hostAddress>"`, so the
   key only works from the host. Commit it to `main`, then install it on the
   Pi with a manual `rpi-deploy deploy switch` (or put it in before you build
   the first image). If the host's address changes, update `hostAddress` and
   deploy again.
3. **The `Host neptun` ssh_config entry** (section 1.C).
4. **The timer**, in the host's NixOS config:

   ```nix
   rpi.buildHost.autoUpdate = {
     enable = true;
     user = "pallon";
     repoPath = "/home/pallon/projects/raspberry-pi";
     sshKey = "/home/pallon/.ssh/rpi-autoupdate";   # a string: never copied into the store
     # defaults: workDir /var/lib/rpi-autoupdate, target root@neptun, sshPort 2222,
     #           onCalendar "Sun 03:00", maxBuilds 500, rebootTime "04:30"
   };
   ```

   The service needs `nix`, `git`, `ssh` (provided by the unit) and a `main`
   branch in `repoPath`.

### Operating it

| what | how |
|------|-----|
| run now | `sudo systemctl start rpi-autoupdate` (the unit runs as your user) |
| logs | `journalctl -u rpi-autoupdate` (a run takes minutes to an hour) |
| timer | `systemctl list-timers rpi-autoupdate` |
| dry run | `rpi-autoupdate --repo PATH --work-dir DIR --no-deploy` (updates the lock, guards, builds, pushes `auto-update`, never contacts the Pi) |
| after re-flashing the Pi | `rm <workDir>/known_hosts` (the job pins the Pi's host key on first contact, `StrictHostKeyChecking=accept-new`) |

**Merging the result.** The new pins arrive as one commit on branch
`auto-update` (main + lock):

```sh
git log -1 auto-update        # auto-update: flake.lock 2026-…
git merge auto-update         # or cherry-pick / fast-forward main
```

The branch is force-pushed every run (`main` + one lock commit), so it is
rewritten whenever you have not merged it. If you squash-merge or cherry-pick
it, the next run simply starts again from `main`. `rpi-deploy deploy` refuses
to deploy a working tree whose `flake.lock` pins an older `nixpkgs` or
`nixos-raspberrypi` than `auto-update`'s (see section 3).

## 5. Recovery and rollback

**Userspace regression** (the system boots, something is wrong): roll back one
generation from the host:

```sh
NIX_SSHOPTS='-p 2222' nix run .#nixos-rebuild -- switch --rollback --no-reexec --target-host root@neptun
```

**Unbootable new kernel or initrd.** There is no boot counting and no
automatic fallback: U-Boot's extlinux simply boots the default entry. Two ways
back to an older generation (the last five are kept, `configurationLimit = 5`):

- *Serial console* (3.3 V USB-UART on GPIO 14/15 = pins 8/10, 115200 8N1; with
  `disable-bt` the PL011 UART is on the header): press a key in U-Boot's
  autoboot countdown, pick `NixOS - Configuration N-default (…)` from the
  extlinux menu. Once it is up, make it permanent:
  `nix-env -p /nix/var/nix/profiles/system --switch-generation N` then
  `/nix/var/nix/profiles/system/bin/switch-to-configuration boot`.
- *From the host*: put the card in the host and edit the default entry on the
  root partition:

  ```sh
  sudo mount /dev/disk/by-label/NIXOS_SD /mnt
  grep -E '^(DEFAULT|LABEL)' /mnt/boot/extlinux/extlinux.conf      # labels nixos-default, nixos-N-default
  sudo sed -i 's/^DEFAULT .*/DEFAULT nixos-N-default/' /mnt/boot/extlinux/extlinux.conf
  sudo umount /mnt
  ```

  (The file is regenerated by the next successful switch.)

Both recoveries rely on U-Boot's extlinux handling and are not exercised on hardware yet
(the labels are as generated in the qemu-tested image; HANDOFF lists the check).

**Broken firmware, `config.txt` or U-Boot** (nothing on the screen/serial,
no U-Boot prompt). The `NIXOS_BOOT` partition is *not* generational: every
switch/boot rewrites it from the new system, and the extlinux menu cannot roll
it back. Restore it from the host, from a known-good commit (e.g. the one
before the update: `git checkout <good>`), with the card in the host (`sdX` =
the card). Either rerun the bootloader installer of the good system for the
FAT only (needs the host's aarch64 binfmt, section 1):

```sh
TOP=$(nix build --accept-flake-config --no-link --print-out-paths \
  ./nixos#nixosConfigurations.rpi.config.system.build.toplevel)
INSTALL=$(sed -n "s/^export INSTALL_BOOTLOADER='\([^ ]*\) .*/\1/p" "$TOP/bin/switch-to-configuration")
sudo mount /dev/disk/by-label/NIXOS_BOOT /mnt
sudo "$INSTALL" -f /mnt -c "$TOP"     # firmware, config.txt, U-Boot; no -b: /boot untouched
sync; sudo umount /mnt
```

or re-flash only partition 1 from an image of the good commit (same layout,
so p1 has the same size; p2 with the system and its state stays):

```sh
rpi-deploy image --out ~/rpi-images
zstd -d ~/rpi-images/result-rpi-image/sd-image/neptun-rpi3.img.zst -o /tmp/good.img
LOOP=$(sudo losetup -P -r -f --show /tmp/good.img)
sudo dd if="${LOOP}p1" of=/dev/sdX1 bs=4M conv=fsync
sudo losetup -d "$LOOP"
```

The next deploy writes the firmware of whatever it deploys again; deploy the
good commit (or fix the cause) before the next weekly run.

**Dead card or re-flash**: section 7. State on the Pi is disposable by design.

## 6. External storage (USB data disk)

`rpi.storage.external` (default off) puts `/nix`, `/var` and `/home` on a USB
disk while the SD card stays the boot device (`/`, `/boot`, `/boot/firmware`).
Options: `enable`, `label = "PI_DATA"`, `fsType = "ext4"`,
`bind = [ "/nix" "/var" "/home" ]`, `swapSize = null` (MiB, swapfile
`/external/swapfile`). The disk is mounted at `/external` with
`neededForBoot` and **never `nofail`**: a missing disk stops the boot in the
emergency shell instead of booting a half system (serial console, or pick an
older generation, section 5).

Migration (manual; the order matters, the new generation's closure must be
on the disk before the first boot with it):

1. Format the disk **on the Pi or the host**: `mkfs.ext4 -L PI_DATA /dev/sdX1`
   (DESTROYS it). Plug it into the Pi.
2. Set `rpi.storage.external.enable = true;` in `configuration.nix`, commit,
   `rpi-deploy deploy boot` (activates nothing yet).
3. On the Pi, copy the data (services that write to `/var` should be quiet;
   repeat the `rsync` right before the reboot):

   ```sh
   ssh -p 2222 root@neptun
   RSYNC=$(nix build --no-link --print-out-paths nixpkgs#rsync)/bin/rsync   # fetch it before the store goes quiet
   mkdir -p /mnt/data && mount /dev/disk/by-label/PI_DATA /mnt/data
   systemctl stop nix-daemon.socket nix-daemon.service
   for d in nix var home; do mkdir -p /mnt/data/$d; $RSYNC -aHAXx --numeric-ids /$d/ /mnt/data/$d/; done
   sync; umount /mnt/data
   ```

   For a fully consistent copy, power the Pi off and run the same `rsync`
   from the host with the card's `NIXOS_SD` and the disk mounted.
4. `ssh -p 2222 root@neptun reboot`; afterwards `findmnt /external /nix`.

The old copies of `/nix`, `/var` and `/home` stay on the SD underneath the bind
mounts (unused while the disk is attached; reclaim the space from the host if
you need it).

## 7. Re-flash the current Pi (migration from the old install)

The Pi that runs today was installed with the old `nixos-install` flow: `pi`
only, no root key, `pi` needs a sudo password, no `trusted-users`, so a push
deploy to it is impossible. Re-flash it (its state is disposable):

1. Put the auto-update key into `keys.nix` first if you already have it
   (section 4, optional: you can add it with a deploy later).
2. `rpi-deploy image`, `rpi-deploy flash … /dev/sdX`, boot (section 2).
3. `ssh-keygen -R '[192.168.100.20]:2222'`, then `ssh -p 2222 root@neptun true`
   and `ssh -p 2222 pi@neptun true`.
4. Walk through the hardware checklist in `HANDOFF.md`.
5. If the weekly job is enabled: `rm /var/lib/rpi-autoupdate/known_hosts`.

Wifi is gone for good (wired LAN only); the old `secrets/wireless.env` is not
used and not in the repo.

## 8. Binary cache and pins ("hybrid" inputs)

`nixos-raspberrypi` is on branch `develop` and **keeps its own nixpkgs pin**,
so the vendor kernel/firmware derivations hash exactly like nvmd's cachix
builds. Our `nixpkgs` (`nixos-26.05`) is a separate input that drives all
userspace (security fixes track the release branch). `rpi` is built with
`nixos-raspberrypi.lib.nixosSystem { inherit nixpkgs; … }`. Rules (enforced by
`checks.x86_64-linux.eval-kernel`):

1. Never add `follows` between `nixpkgs` and `nixos-raspberrypi/nixpkgs`.
   `config.boot.kernelPackages.kernel` must equal nvmd's own `linuxPackages_rpi3`
   kernel (same store path), otherwise the kernel compiles locally (16+ h).
   Out-of-tree kernel modules only from `config.boot.kernelPackages`.
2. The cache must be enabled on the host: `flake.nix` carries it in
   `nixConfig` (`--accept-flake-config`, which `rpi-deploy` passes, works for
   trusted nix users) and `rpi.buildHost.enable = true` adds it to `nix.conf`.
   The Pi trusts it via nixos-raspberrypi's module.
3. `nix flake update nixos-raspberrypi` can land on a `develop` HEAD whose
   kernel is not cached yet (the cadence is weekly). The guards catch that;
   the weekly job then falls back to updating `nixpkgs` only.

Check by hand:

```sh
nix build --accept-flake-config --dry-run .#nixosConfigurations.rpi.config.system.build.sdImage 2>&1 \
  | sed -n '/will be built/,/will be fetched/p' \
  | grep -E -- '/[0-9a-z]{32}-(linux_rpi-[^ ]*[0-9]|linux-config-[^ ]*)\.drv$'   # must print nothing
```

Home Manager is `master`, not release-26.05 (nix-terminal needs
`programs.devenv`); `home.nix` silences the release-mismatch warning.

## 9. Pi configuration notes

- `rpi.sdWear` (default on): `hardware.enableRedistributableFirmware = false`
  and `hardware.firmware = []` (−770 MiB, wired LAN needs no blobs), `/` with
  `noatime,lazytime,commit=60`, `/tmp` as 256M tmpfs, journald `Storage=volatile`
  (16M, level info), no coredumps, `keep-derivations = false`, monthly fstrim,
  zram swap 50 % with `vm.swappiness = 100`, `vm.page-cluster = 0`. Rejected on
  purpose: `fsync-metadata = false`, `auto-optimise-store`, the `discard`
  option, f2fs/btrfs.
- `rpi.headless` (default on): `gpu_mem=16`, `dtoverlay=disable-wifi`,
  `dtoverlay=disable-bt`, no `vc4-kms-v3d`, no audio, no camera/display
  auto-detect, no `cma=32M`. There is no HDMI console any more; the serial
  console is the UART on the GPIO header.
- Nix: `nix.gc` weekly, `--delete-older-than 21d`; extlinux keeps 5
  generations; `nix.channel.enable = false`, the flake registry and `NIX_PATH`
  point at the system's own nixpkgs, so `nix shell nixpkgs#…` on the Pi hits the
  store and the caches.
- Access: `PermitRootLogin = prohibit-password`, `PasswordAuthentication = no`,
  `security.sudo.wheelNeedsPassword = false` (`pi` has no password, the login is
  key-only; same trust as the root key). Root's keys: your key, and the
  auto-update key restricted with `from=`.
- Options follow nixos-26.05 (e.g. `services.journald.extraConfig`; the newer
  `settings` is 26.11 only).

## 10. Testing

```sh
nix flake check --accept-flake-config        # all checks incl. the VM test, ~1–5 min warm
nix build .#checks.x86_64-linux.eval-kernel  # one check
```

| layer | check | cost |
|-------|-------|------|
| eval checks (option values and their effects: kernel identity, image, access, GC/extlinux, sd-wear, headless, external storage, tools, build host) | `eval-<name>` from `tests/eval/<name>.nix` | seconds |
| unit tests, mocked nix/ssh/sudo/lsblk/dd/nixos-rebuild, real git/zstd | `rpi-deploy-unit`, `autoupdate-unit` | ~10–30 s |
| bash syntax + shellcheck | `rpi-deploy-syntax` | seconds |
| NixOS VM test of the build-host module (binfmt, aarch64 `hello`, timer) | `rpi-host-vm` | 1–16 min |
| qemu `raspi3b` boot of the real image + SSH banner over usb-net | `tests/boot-smoke.sh IMAGE.img.zst` | ~4–6 min |
| qemu deploy: boot the image, `rpi-deploy deploy switch`, verify | `tests/deploy-smoke.sh` | ~20–30 min (image build ~10 min of it, cached on re-runs) |

The smoke tests are not part of `nix flake check` (qemu TCG, minutes). Both
need `qemu-system-aarch64` with `-M raspi3b` (`nix shell nixpkgs#qemu`),
`zstd`, `sfdisk`, `debugfs` and `mcopy`, no root:

```sh
tests/boot-smoke.sh ~/rpi-images/result-rpi-image/sd-image/neptun-rpi3.img.zst
tests/deploy-smoke.sh            # builds a throwaway-key image itself
```

What qemu cannot cover: U-Boot reading `extlinux.conf`, the GPU firmware
applying `config.txt`, a real card, the LAN, the reboot timer. That is the
manual hardware checklist in `HANDOFF.md`.

The build-host module is also evaluated on every flake operation by contract
asserts (binfmt, extra-platforms, features, sandbox paths, cache, wrapper).

## Notes

- Scratch files (`.nixcache/`, `result*`, `.scratch/`) are gitignored and safe
  to delete. `.rpi-build/` and `.rpi-build.log` are leftovers of the old
  install flow: delete them, then drop their two lines from `.gitignore`.
- The kit is headless by design: `clipboard = "osc52"` copies through the
  terminal's OSC 52 sequence, nothing X/Wayland-related is installed.
- The Pi has 1 GB RAM; the kit's optional heavy dev set is disabled
  (`packages.dev.enable = false`).
- Sandbox gotcha (E3): the host's system `ssh_config` may include files that
  plain `ssh` rejects with `Bad owner or permissions`; use `ssh -F /dev/null`
  or your own config (the smoke tests do).
