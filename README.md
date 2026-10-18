# rpi — Raspberry Pi 3 Model B (V1.2) NixOS flake + build host

Headless NixOS system (no graphics server) for a Raspberry Pi 3 Model B V1.2,
plus everything needed on the x86_64 build host: a NixOS / Home Manager module
for aarch64 emulation and the `rpi-deploy` script that builds the system from
a checkout and installs it onto an SD card.

- Hostname `neptun`, system `aarch64-linux`, NixOS 26.05 (the nixpkgs pinned
  by nixos-raspberrypi).
- Hardware support: [nvmd/nixos-raspberrypi](https://github.com/nvmd/nixos-raspberrypi)
  (`raspberry-pi-3.base`): vendor kernel `linuxPackages_rpi3`, Pi firmware,
  U-Boot and a declarative `config.txt`. The kernel comes **prebuilt from the
  nixos-raspberrypi binary cache** — no local kernel build (see "Binary cache
  and pins").
- User `pi` (wheel, docker, video groups), login shell zsh.
- User environment: the [nix-terminal](https://github.com/grburst/nix-terminal)
  kit (zsh + nvim + yazi, terminal theme, OSC 52 clipboard — no display
  server required) plus tools: btop, atop, wget, curl, git, tig, netcat,
  nmap, psmisc, tree, ncdu.
- SSH only: port 2222, key authentication (no password auth).
- `system.autoUpgrade` runs daily at 03:30.
- 512 MiB zram swap (see "Pi (client) configuration").

## Repo layout

```
flake.nix           pi system config + build-host outputs
configuration.nix   the pi NixOS config
home.nix            the pi home-manager config
modules/
  build-host.nix        NixOS module: aarch64 build host (rpi.buildHost)
  build-host-home.nix   Home Manager module: rpi-deploy on the PATH
tests/build-host.nix    x86_64 test system for the build-host module
rpi-deploy.sh       rpi-deploy: prepare / build / install / config / eject / show / all
secrets/            gitignored per-machine secrets (wireless.env)
```

## Build host setup

### A. NixOS build host (module)

In your host flake:

```nix
inputs.pi = {
  url = "git+file:///home/pallon/projects/pi/nixos";
  flake = true;
  inputs.nixpkgs.follows = "nixpkgs";
};
```

```nix
modules = [
  inputs.pi.nixosModules.rpiBuildHost
  {
    rpi.buildHost.enable = true;
    # optional: pre-sets RPI_FLAKE so `rpi-deploy` needs no --flake
    rpi.buildHost.flakePath = "/home/pallon/projects/pi/nixos";
  }
];
```

then `nixos-rebuild switch --flake /etc/nixos`. That gives you:

- `boot.binfmt.emulatedSystems = [ "aarch64-linux" ]` — qemu user-mode
  emulation; the nixpkgs binfmt module also registers the handler for the nix
  sandbox (`extra-sandbox-paths`) and adds `aarch64-linux` to
  `nix.extra-platforms`, so cross builds work out of the box;
- `nix` experimental features `nix-command` and `flakes`;
- `rpi-deploy` on the PATH (in `environment.systemPackages`), optionally
  wrapped so `RPI_FLAKE` is preset.

Verify with:

```sh
nix build .#nixosConfigurations.rpiBuildHostTest.config.system.build.toplevel  # module test system
rpi-deploy show                                                                # preflight overview
```

### B. Non-NixOS build host (Home Manager module)

For the script only (e.g. a Debian/Ubuntu host where you manage binfmt
yourself, e.g. via `binfmt-support`):

```nix
home-manager.users.alice = {
  imports = [ inputs.pi.homeModules.rpiBuildHost ];
  rpi.buildHost.enable = true;
  rpi.buildHost.flakePath = "/home/alice/projects/pi/nixos";
};
```

Manual equivalent of the module (any host):

```nix
boot.binfmt.emulatedSystems = [ "aarch64-linux" ];   # NixOS
nix.settings.extra-platforms = [ "aarch64-linux" ];  # or set in nix.conf
```

Without aarch64 emulation every aarch64 derivation fails with
`builder failed with exit code 255` (that is an emulation problem, not a
configuration or graphics problem). `rpi-deploy build` refuses to start in
that case.

## Building and installing

### The SD card

Two partitions on an MBR (dos) partition table, found by their **labels**
(`configuration.nix` mounts by label, so the order/device name do not matter):

| partition | size    | fs    | label        | mounted at       | holds                                   |
|-----------|---------|-------|--------------|------------------|-----------------------------------------|
| p1        | 256 MiB | FAT32 | `NIXOS_BOOT` | `/boot/firmware` | Pi firmware, `config.txt`, U-Boot, DTBs |
| p2        | rest    | ext4  | `NIXOS_SD`   | `/`              | system, `/boot` (kernel, initrd, extlinux), `/etc/nixos` |

There is no third partition. The Pi's ROM reads p1, which starts U-Boot; U-Boot
reads `extlinux.conf` + kernel + initrd from `/boot` on p2.
`rpi-deploy prepare` creates this layout and mounts it as
`/media/nixos` + `/media/nixos/boot/firmware` (what `nixos-install` needs).

### The flow

The SD card is only needed from `prepare` on. `build` runs entirely from a local
checkout, so the pi can keep running (card not inserted) while it builds.

```sh
rpi-deploy build                      # 1. build in the host store, record the result
# ... insert the card ...
rpi-deploy prepare /dev/sdX --format  # 2a. NEW/foreign card: partition + format + mount
                                      #     (DESTROYS /dev/sdX; asks you to type the device)
rpi-deploy prepare /dev/sdX           # 2b. existing NixOS-style card: fix labels if needed, mount
rpi-deploy prepare                    # 2c. card already labelled: just mount it (by label)
rpi-deploy install                    # 3. copy system, nixos-install, copy config to etc/nixos
rpi-deploy eject                      # 4. sync + unmount; boot the pi: ssh -p 2222 pi@<address>
```

`install` also mounts a card that carries the labels but is not mounted yet, so
after inserting an already-prepared card a plain `rpi-deploy install` is enough.

Everything else: `rpi-deploy config` re-copies only the configuration to
`/etc/nixos` (no reinstall), `rpi-deploy devices` lists the removable/MMC disks (the candidates for
`prepare DEVICE`) and whether a labelled card is present, `rpi-deploy show`
prints the last build and the card/firmware mount state, `rpi-deploy all` is `build` + `install`.

`prepare --format` sets the labels while creating the file systems
(`mkfs.vfat -n NIXOS_BOOT`, `mkfs.ext4 -L NIXOS_SD`), the partition types
(`c` FAT32 LBA, `83` Linux) and the boot flag on p1, then checks that
`/dev/disk/by-label` resolves to the right partitions. `prepare /dev/sdX`
without `--format` is non-destructive: if p1 is FAT and p2 is ext4 but their
labels are missing or wrong (e.g. a card laid out by hand), it relabels them
with `fatlabel`/`e2label` and refreshes udev; a partition with any other file
system, or one that is mounted, is refused, never touched.

Find the device with `lsblk` (the card shows up as `/dev/sdX` in a USB reader or
`/dev/mmcblk0` in a built-in one). `prepare --format` refuses a disk the host
runs from (`/`, `/boot`, `/nix`, `/home`, ...), a partition instead of a whole
disk, and a device that is mounted elsewhere; without `--yes` it makes you
type the device path first. `--format` also unmounts whatever of that device is mounted (e.g. a desktop
automount) after your confirmation, takes an exclusive `flock` while writing
the partition table (udev probes a freshly wiped disk and would otherwise make
`sfdisk` fail with "disk is currently in use"), retries briefly if the device
is still busy and waits for the partition nodes. `--dry-run` prints every command without running
it.

Before copying, `install` prints the target card with its size and free space,
stops if the system closure cannot fit on the card at all (and warns if it
exceeds the free space), and warns if no normal user in the config has an ssh
key or password — the pi is headless and password ssh is off, so it would be
unreachable. Build and install report their duration and the next step;
colours are only used on a terminal (`NO_COLOR` disables them).

Usage: `rpi-deploy prepare [DEVICE] [--format] [--yes] [--boot-size SIZE]` and
`rpi-deploy [build|install|config|eject|all|show] [TARGET] [OPTIONS]`. `TARGET`
is the root of the target NixOS system (default `/media/nixos`; same as
`--mount`). Options: `--flake PATH` (default `$RPI_FLAKE` or `$PWD`),
`--mount DIR`, `--attr NAME` (default `rpi`), `--from STOREPATH` (install a
specific system), `--boot-size` (default `256MiB`), `--dry-run`.

`build` writes a record to `<checkout>/.rpi-build/last` (gitignored):

```
flake=...  attr=rpi  rev=<git HEAD>  dirty=clean|dirty  sys=<store path>  drv=<drv path>  built=<utc>
```

`install` requires the card root to be a real mount point and the FAT partition
to be mounted at `<mount>/boot/firmware` (`prepare` does both); it refuses
otherwise. It then:

1. copies the recorded system + toplevel drv into the card's store
   (`sudo nix copy --no-check-sigs --to <mount>`),
2. runs `sudo nixos-install --root <mount> --flake <checkout>#rpi` — pointed at
   the **host checkout**, so the evaluation matches the recorded build
   bit-for-bit and **nothing is rebuilt**. The bootloader step fills
   `/boot/firmware`,
3. copies the configuration checkout to `<mount>/etc/nixos` (see below),
4. verifies the paths exist in the target store and that `etc/NIXOS`,
   `boot/firmware/config.txt`, `boot/firmware/u-boot-rpi-arm64.bin` and
   `etc/nixos/flake.nix` are present.

**Configuration on the card.** `nixos-install --flake` does *not* put the
configuration on the target, but the pi needs it at `/etc/nixos`: the wifi
password file lives at `/etc/nixos/secrets/wireless.env`, and that is where you
edit and `nixos-rebuild` on the pi. `install` (and `config`) therefore mirror
the checkout there — as root, **including `.git` and `secrets/`**, excluding
`.rpi-build*`, `result*`, `.nixcache`, `.direnv`; files on the card that are not
in the checkout are removed. Keep `.git` in the copy: with it nix treats the
directory as a git flake, in which the untracked `secrets/wireless.env` is not
copied into the world-readable nix store (the script warns if there is no
`.git`, or no `secrets/wireless.env`).

The record carries the git revision; if the checkout HEAD or the working tree
has changed since the build, `install` warns that the target may rebuild.

> **Why not just `nixos-install`?** It does not build in the host store: it
> compiles the whole closure directly into the card's `/nix/store`, as root,
> with build temp files on the SD. That is slow, wears the card, and repeats in
> full after every re-flash. Building in the host store once and copying over
> makes re-flashing a matter of minutes.

### Binary cache and pins

The vendor kernel is **not** in `cache.nixos.org`; it is in the
`nixos-raspberrypi.cachix.org` cache of nvmd/nixos-raspberrypi, built for
*exactly* the nixpkgs revision that flake pins. Two rules keep it a cache hit:

1. `nixpkgs` **follows** `nixos-raspberrypi/nixpkgs` (flake.nix). Any other
   nixpkgs revision changes the kernel derivation hash and silently triggers a
   16+ hour local kernel build under qemu. Do not add `nixpkgs.url`; update
   with `nix flake update nixos-raspberrypi` (moves the nixpkgs pin along).
2. The cache must be enabled on the build host: `flake.nix` carries it in
   `nixConfig`, `rpi-deploy` passes `--accept-flake-config` (works for
   trusted nix users), and `rpi.buildHost.enable = true` adds it to the host's
   `nix.conf` (`rpi.buildHost.nvmdCache`). `rpi-deploy` warns if it is
   missing. The Pi itself trusts the cache via nixos-raspberrypi's
   `trusted-nix-caches` module.

Check that the kernel is a cache hit before a long build:

```sh
nix build --accept-flake-config --dry-run .#nixosConfigurations.rpi.config.system.build.toplevel 2>&1 \
  | grep -E 'linux_rpi'   # must be listed under "will be fetched", not "will be built"
```

Everything else still builds locally under qemu if it is not in a cache
(`nix-terminal`/nvf pieces such as `blink-cmp`, treesitter grammars, ...);
that is minutes to an hour, not the kernel.

### Manual equivalent (for troubleshooting)

Run from the checkout; this is what `rpi-deploy all` does:

```sh
T=.#nixosConfigurations.rpi.config.system.build.toplevel

# 1. build in the host store (as your user, never root)
nix build --accept-flake-config $T --print-build-logs 2>&1 | tee .rpi-build.log

# 2. copy the closure AND the toplevel drv (the drv pulls the flake sources
#    into the target store, so the install does not re-fetch them)
sys=$(nix build --accept-flake-config $T --print-out-paths)
drv=$(nix eval --raw --accept-flake-config $T.drvPath)
sudo nix copy --no-check-sigs --to /media/nixos "$sys" "$drv"

# 3. card (new card: mkfs as in "The SD card"), mounted as root + firmware
sudo mkdir -p /media/nixos && sudo mount /dev/disk/by-label/NIXOS_SD /media/nixos
sudo mkdir -p /media/nixos/boot/firmware
sudo mount /dev/disk/by-label/NIXOS_BOOT /media/nixos/boot/firmware

# 4. install (nothing is built here; the bootloader step fills /boot/firmware)
sudo nixos-install --root /media/nixos --flake .#rpi --option accept-flake-config true

# 5. configuration onto the card (incl. .git and secrets/)
sudo mkdir -p /media/nixos/etc/nixos
tar -C . --exclude=./.rpi-build --exclude=./result --exclude=./.nixcache -cf - . | sudo tar -C /media/nixos/etc/nixos -xpf -

# 6. sync, umount -R /media/nixos; boot the pi, then: ssh -p 2222 pi@<pi-address>
```

`nixos-install --flake` builds from the **working tree**, not the commit;
commit once the pi boots so the commit records what is installed.

## Pi (client) configuration

Notes on the client side, evaluated and applied:

- **Options follow nixos-26.05** (the nixpkgs of nixos-raspberrypi): e.g.
  `services.journald.storage`/`extraConfig` (the newer `journald.settings`
  is 26.11 only). No "Obsolete option" warnings.
- **Boot layout** (nixos-raspberrypi, `uboot`): `/boot/firmware` (FAT, label
  `NIXOS_BOOT`) holds the Pi firmware, `config.txt` (generated from
  `hardware.raspberry-pi.config`) and `u-boot-rpi-arm64.bin`; kernel, initrd
  and `extlinux.conf` live in `/boot` on the ext4 root `NIXOS_SD`. The
  partition labels are unchanged, so existing cards keep their layout. The
  firmware partition must be mounted at `<target>/boot/firmware` for the
  install (`rpi-deploy install` checks and refuses otherwise).
- **Home Manager is master**, not release-26.05: nix-terminal needs
  `programs.devenv`, which only exists on master. `home.nix` silences the
  release-mismatch warning and disables HM's nushell fzf integration (needs
  fzf >= 0.73, newer than 26.05).
- **zram swap enabled** (50 % of RAM = 512 MiB compressed, in RAM, no SD
  wear). Gives the 1 GiB pi headroom for the nightly autoUpgrade builds.
  Remove the `zramSwap` block if you prefer no swap.
- **Secrets**: `secrets/wireless.env` (gitignored, mode 0600) holds
  `MY_WIFI_PASSWORD=...`. It is referenced via
  `networking.wireless.secretsFile` and the `@MY_WIFI_PASSWORD@` placeholder,
  so the password never enters the flake source. `nixos-install` copies the
  checkout (including untracked files) into `/etc/nixos` on the card, which
  is how the secret lands there.

Considered but not changed:

- **mosh** (UDP 60000-61000 firewall range) — still commented out; enable in
  `configuration.nix` + router port range when needed.
- **autoUpgrade + kernel updates**: an autoUpgrade on the pi that also bumps
  `nixos-raspberrypi` would pull a new kernel/nixpkgs (a cache hit only once
  nvmd has rebuilt it; a miss would build on the 1 GiB pi). Keep the
  nixos-raspberrypi pin moving from the build host (or accept occasional
  failed autoUpgrades — the pi then just runs the old system).
- **Deploy key**: `users.users.pi.openssh.authorizedKeys.keys` is empty; add
  the host's public key to enable the remote-install follow-up below.

## Follow-up: remote install (no card mount)

Possible once a deploy key is in place: run
`nixos-rebuild build --flake <host-checkout>#rpi` on the host and push the
result to the pi over SSH (`nix copy --to` + `nixos-rebuild switch --flake`
with the store pre-populated, or `devenv`/`deploy-rs`). Not implemented here;
the current `rpi-deploy install` flow is the card-based baseline that it
replaces.

## Testing

Three layers, all wired into `nix flake check`:

```sh
nix flake check                                   # everything below
nix build .#checks.x86_64-linux.rpi-deploy-unit  # 204 unit tests for rpi-deploy.sh
nix build .#checks.x86_64-linux.rpi-host-vm       # boots a real VM (qemu), ~1-16 min
nix build .#nixosConfigurations.rpiBuildHostTest.config.system.build.toplevel  # host module, eval-only proof
```

1. **`rpi-deploy-syntax`** (both systems) — `bash -n` of the script.
2. **`rpi-deploy-unit`** (`tests/deploy-unit.sh`, x86_64) — 204 unit tests
   with mocked `nix`/`nixos-install`: preflight fail/success, build record
   round-trip (all fields), `show`, install verification incl. a failing
   store copy, `--from` with/without record, attr mismatch, HEAD-moved and
   dirty-tree warnings. binfmt locations are injectable via
   `RPI_BINMFT_DIR`/`RPI_BINMFT_RUN`.
3. **`rpi-host-vm`** (`checks.x86_64-linux.rpi-host-vm`) — boots an x86_64
   NixOS VM with the build-host module enabled and asserts the observable
   reality: `nix` accepts flakes (experimental features from the module),
   the `aarch64-linux` binfmt handler is registered in
   `/proc/sys/fs/binfmt_misc`, an **aarch64 binary actually executes**
   under emulation, the installed `rpi-deploy` is the `RPI_FLAKE` wrapper
   pointing at `rpi.buildHost.flakePath`, and the script's own dry-run
   flows (including its emulation preflight) pass inside the VM.

   Note: the VM test needs `rpi.buildHost.enable = true` set by itself —
   the exported `nixosModules.rpiBuildHost` deliberately only wires the
   module in (opt-in design).

In addition, flake evaluation enforces **contract asserts** on the host
module config (binfmt list, extra-platforms, experimental features,
sandbox paths, wrapper package present) — any drift fails every flake
operation fast.

```sh
nix build .#packages.x86_64-linux.rpi-deploy     # the script as a package
```

## Notes

- Scratch files used while building (`.nixcache/`, `result`,
  `.rpi-build.log`, `.rpi-build/`) are gitignored and safe to delete; they
  only speed up re-evaluation.
- The kit is headless by design: `clipboard = "osc52"` copies through the
  terminal's OSC 52 sequence, so nothing X/Wayland-related is installed.
- The Pi has 1 GB RAM; the kit's optional heavy dev set is disabled
  (`packages.dev.enable = false`).
