# nix-raspi — NixOS on a Raspberry Pi 3: library flake, template, deploy tool

Everything to run a headless NixOS system on a Raspberry Pi 3 Model B
(`aarch64-linux`, 1 GiB RAM, SD card) from a git repository of your own:
`lib.mkPi` builds the system (vendor kernel, SD image, key-only SSH, defaults
for a small Pi), every Pi-specific value is an `rpi.*` option or an
overridable default, `rpi-deploy` builds the image, flashes the card and
pushes changes, and an optional CI workflow builds security updates that the
Pi pulls by itself, so they arrive without your build host being on.
`nix flake init -t` gives you a working host. **`neptun`** (in `hosts/neptun`)
is our own Pi and the example host of this repository.

```
build host (x86_64, aarch64 emulation)              Pi 3B (aarch64)
 your repo: flake.nix + hosts/<name>.nix
   ──eval+build──► toplevel ──┬─ image ─► .img.zst ─flash─► SD card (once)
                              └─ push ──► nixos-rebuild --target-host   (rpi-deploy deploy)

GitHub Actions (arm64): cron | push to main | manual; one build job per Pi host
 └─ [cron] lock update ─ guard ─ build ─ checks ─► your Cachix cache (self-signed) + pin
 └─ pointer deploy/<host>.json ─ one commit to main
                                   │ HTTPS (raw.githubusercontent.com)
Pi: rpi-pull.timer (daily 05:00): fetch pointer ─ verify ─ realise ─ narHash ─ switch | boot + reboot at 06:30
```

- **One definition per host.** `nixosConfigurations.<name> = rpi.lib.mkPi {
  modules = [ ./hosts/<name>.nix ]; }` is both the flashed image
  (`config.system.build.sdImage`) and every later update, pushed or pulled.
- **The Pi never evaluates the flake** (evaluation needs ~1.1 GB, the Pi has
  ~870 MiB usable). No `/etc/nixos`, no `autoUpgrade`, no channels. The system
  is built on your build host (pushed over SSH) or by CI (pulled as a prebuilt
  closure), see "Changing the configuration".
- **No local kernel build, ever.** The vendor kernel comes prebuilt from the
  [nvmd/nixos-raspberrypi](https://github.com/nvmd/nixos-raspberrypi) cachix;
  `rpi-deploy` and the CI build refuse to run when that cannot hold.
- **Defaults** (all overridable): NixOS 26.05, DHCP, SSH on port 22 with keys
  only, admin user `pi`, hostname `rpi`, Wi-Fi and Bluetooth off, fewer SD
  writes (`rpi.sdWear`), headless `config.txt` (`rpi.headless`), optional USB
  data disk (`rpi.storage.external`, off).
- **Outputs of this flake:**

| output                                                     | what                                                                                               |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `lib.mkPi { modules; specialArgs ? {}; }`                  | a Pi host: nvmd's base, the hybrid inputs, the `rpi.*` modules, home-manager; marked `rpiHost`     |
| `nixosModules.default`, `nixosModules.terminal`            | the `rpi.*` modules without / with the home-manager terminal profile (for wiring nvmd yourself)    |
| `nixosModules.rpiBuildHost`, `homeModules.rpiBuildHost`    | build host: aarch64 emulation and `rpi-deploy` on the PATH                                         |
| `templates.default`                                        | `nix flake init -t github:GRBurst/nix-raspi`: a repo with one host, the CI workflow, devenv files  |
| `packages.<system>.rpi-deploy`, `packages.<system>.rpi-ci` | the host tool (image, flash, deploy, status, secrets) and the CI entry point (`hosts`, `build`, …) |
| `apps.x86_64-linux.nixos-rebuild`                          | `nixos-rebuild` pinned to the Pi's release (what `rpi-deploy deploy` runs)                         |
| `nixosConfigurations.neptun`                               | our example host; `rpi` is a deprecated alias of it (one release)                                  |
| `checks`                                                   | eval, unit, lint and personal-value checks (section "Development")                                 |

- Design: `docs/superpowers/specs/2026-10-25-reusable-library-design.md`
  (this library; plan `docs/superpowers/plans/2026-10-25-reusable-library.md`),
  built on `2026-10-19-image-push-deploy-design.md` (push) and
  `2026-10-23-ci-pull-updates-design.md` (CI builds, the Pi pulls) in the same
  directories. Status and hardware checklist: `HANDOFF.md`.

## Quick start

Needs a build host with aarch64 emulation and a trusted nix user (once, see
"Build host prerequisites"), and an SD card of at least 5 GiB.

```sh
mkdir my-pi && cd my-pi
nix flake init -t github:GRBurst/nix-raspi
$EDITOR hosts/rpi.nix            # rpi.admin.sshKeys = [ "ssh-ed25519 AAAA… you@laptop" ];
git init && git add -A           # a git flake only sees tracked files
nix run .#rpi-deploy -- image    # ~35 min the first time
nix run .#rpi-deploy -- flash result-rpi-image/sd-image/*.img.zst /dev/sdX
# put the card in the Pi, plug in the network cable, power on, find its address
ssh pi@<address>                 # key only, port 22
RPI_TARGET=root@<address> nix run .#rpi-deploy -- deploy    # every later change
```

1. `hosts/rpi.nix` holds your values. Without a key evaluation fails with
   `rpi.admin.sshKeys is empty`: the library never builds a locked-out image.
2. `image` builds `config.system.build.sdImage` after the cache and build
   guards; `flash` writes it after you type the device name, then reads it
   back. Both are described under "Image and flash".
3. The defaults need no router setup: DHCP on any wired interface, hostname
   `rpi`. Look up the address in your router, or set `networking.hostName` and
   a static address (see "Configuration") and deploy again. `rpi.deploy.target`
   (default `root@<hostname>`) is where `deploy` goes; `RPI_TARGET` overrides it.
4. From then on, change `hosts/rpi.nix` and run `rpi-deploy deploy`. Other ways
   to apply a change are listed under "Changing the configuration".

### Build host prerequisites

Two things need root on the build host, once; everything else comes from the
flake (and the optional devenv shell, see "Development").

On a NixOS host, in its configuration:

```nix
boot.binfmt.emulatedSystems = [ "aarch64-linux" ];       # aarch64 emulation (qemu user mode)
nix.settings.trusted-users = [ "root" "<your user>" ];   # honour the flake's nvmd cache
```

- **aarch64 emulation.** The nixpkgs binfmt module registers the qemu handler,
  exposes it to the nix sandbox (`extra-sandbox-paths`) and adds `aarch64-linux`
  to `extra-platforms`. Without it every aarch64 derivation fails with
  `builder failed with exit code 255`.
- **Trusted nix user.** The flake declares the nixos-raspberrypi cache in its
  `nixConfig` and `rpi-deploy` accepts it, but the nix daemon honours a flake's
  substituters only for trusted users. Otherwise the kernel gets compiled
  (hours). Alternative: add the cache to the host's `nix.settings.substituters`
  and `trusted-public-keys` (the values are in `flake.nix` and in the template).

On a non-NixOS host: `binfmt-support` + `qemu-user-static`,
`extra-platforms = aarch64-linux` and `trusted-users` in `/etc/nix/nix.conf`.
`rpi-doctor` in the devenv shell checks both and prints the fix.

### Image and flash

```sh
rpi-deploy image [--out DIR] [--flake DIR] [--host NAME] [--max-builds N]
rpi-deploy flash IMAGE DEVICE [--wifi-env] [--flake DIR] [--host NAME]
```

**`image`** builds `config.system.build.sdImage` of the host (`--host`, default
`$RPI_HOST`, else the flake's only Pi host; several and none chosen: exit 2
with the list) and prints the image path and size, `<hostname>-rpi3.img.zst`
under `result-rpi-image/sd-image/` of `--out` (default the current directory).
Before building it runs the guards (kernel and kernel modules are in nvmd's
cachix; the dry run lists no kernel, linux-config, gcc/llvm/rustc/ghc/nodejs
build and at most `--max-builds`, default 500, local builds). A failed guard
exits non-zero before anything is built. Our own host needed ~35 min the first
time (379 local builds, mostly cheap; `blink-cmp` compiles under qemu) and
~10 min after a small change. `result-rpi-image` is a GC root.

The image: two partitions on an MBR, found by **label**, disk id `0x2175794e`.

| partition | size    | fs    | label        | mounted at       | holds                                      |
| --------- | ------- | ----- | ------------ | ---------------- | ------------------------------------------ |
| p1        | 256 MiB | FAT32 | `NIXOS_BOOT` | `/boot/firmware` | Pi firmware, `config.txt`, U-Boot, DTBs    |
| p2        | rest    | ext4  | `NIXOS_SD`   | `/`              | system, `/boot` (kernel, initrd, extlinux) |

Kernels and initrds live on the ext4 root (U-Boot reads them there), so the
number of generations never fills the 256 MiB firmware partition. The first
boot expands p2 to the card (needs ≥ 5 GiB).

**`flash IMAGE DEVICE`** writes the image with
`zstdcat | sudo dd bs=4M conv=fsync oflag=direct status=progress` and reads it
back (`sudo head -c LEN DEVICE | sha256sum` against the image). It refuses:
anything that is not a block device, a partition instead of a whole disk, a
non-removable disk (an SD card in a built-in `mmcblkN` reader counts as
removable, since Linux never sets the flag on MMC, but only if
`/sys/block/mmcblkN/device/type` is `SD`: eMMC is refused), the disk that
holds the host's `/`, a device with mounted partitions, and a missing or wrong confirmation: you must type the device name
(`type the device name (sdX):`). Writing is the only privileged step (plus the
read-back); the image is 1.3 GiB compressed, 4.2 GiB raw, ~4 min each way at
20 MB/s. `--wifi-env` also writes the Wi-Fi secrets file into the card, see
"Wi-Fi and secrets".

**First boot.** Insert the card, power the Pi (network cable in):

```sh
ssh pi@<address>             # or root@<address>: both with your key, no password
```

Expect about a minute or two (first-boot expansion, host key generation;
unmeasured on hardware, ~100 s under qemu, which is ~5x slower). After a
re-flash the host key changes: `ssh-keygen -R <address>` (`-R '[<address>]:2222'`
for a non-default port).

### Optional: `rpi-deploy` on the host's PATH

If you want `rpi-deploy` on the system PATH (outside the devenv shell) and the
prerequisites in one place, import the host module in your host's flake:

```nix
inputs.rpi.url = "github:GRBurst/nix-raspi";
```

```nix
modules = [
  inputs.rpi.nixosModules.rpiBuildHost
  {
    rpi.buildHost.enable = true;
    # optional: pre-sets RPI_FLAKE (the root of your repo) so `rpi-deploy` needs no --flake
    rpi.buildHost.flakePath = "/home/<you>/projects/my-pi";
  }
];
```

then `nixos-rebuild switch`. That gives you `boot.binfmt.emulatedSystems =
[ "aarch64-linux" ]`, the `nix` features `nix-command` and `flakes`, the
nixos-raspberrypi binary cache as a host substituter (`rpi.buildHost.nvmdCache`,
so no trusted user needed) and `rpi-deploy` on the PATH (the committed version
of the locked library). `rpi.buildHost.flakePath` is the root of your repo, the
directory with `flake.nix`.

On a non-NixOS host, the Home Manager module puts only the script on the PATH
(binfmt and `nix.conf` as above):

```nix
home-manager.users.alice = {
  imports = [ inputs.rpi.homeModules.rpiBuildHost ];
  rpi.buildHost.enable = true;
  rpi.buildHost.flakePath = "/home/alice/projects/my-pi";
};
```

## Configuration

Your values go into a host module, `hosts/<name>.nix` (the template's is
`hosts/rpi.nix`), which `lib.mkPi` combines with the library. Every NixOS
option stays settable there; the `rpi.*` options exist only where one option
bundles several NixOS settings or encodes Pi knowledge. Plain NixOS options
with a default from the library: `networking.hostName` (`"rpi"`),
`time.timeZone` (`"UTC"`), `i18n.defaultLocale`, `console.keyMap`.

| option                                   | default                           | effect                                                                                                          |
| ---------------------------------------- | --------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `rpi.admin.user`                         | `"pi"`                            | normal user in `wheel` (passwordless sudo), key-only login                                                      |
| `rpi.admin.sshKeys`                      | none: assertion if empty          | `authorized_keys` of the admin user and of root                                                                 |
| `rpi.ssh.port`                           | `22`                              | sshd port; password auth off; root `prohibit-password` (push deploy logs in as root)                            |
| `rpi.network.mode`                       | `"dhcp"`                          | `"dhcp"` or `"static"`; networkd, matches any wired interface                                                   |
| `rpi.network.static.address`, `gateway`  | none                              | with `mode = "static"`: address in CIDR form and gateway                                                        |
| `rpi.network.static.dns`                 | `[ ]`                             | with `mode = "static"`: DNS servers                                                                             |
| `rpi.wifi.enable`                        | `false`                           | drops the `disable-wifi` overlay, wpa_supplicant via networkd (DHCP on wlan)                                    |
| `rpi.wifi.networks`                      | `{ }`                             | SSID → name of the variable holding its PSK; PSKs come from `rpi.wifi.secretsFile`, never from the store        |
| `rpi.wifi.secretsFile`                   | `"/var/lib/rpi/wireless.env"`     | file on the Pi with the `VAR=PSK` lines, mode 0600, owned by the wpa_supplicant user                            |
| `rpi.bluetooth.enable`                   | `false`                           | drops the `disable-bt` overlay, `hardware.bluetooth.enable`                                                     |
| `rpi.headless.enable`                    | `true`                            | gpu_mem 16, no KMS, no audio, no camera/display detection (does not touch Wi-Fi/Bluetooth)                      |
| `rpi.profiles.terminal.enable`           | `false`                           | home-manager + [nix-terminal](https://github.com/grburst/nix-terminal) for `rpi.admin.user`, zsh as login shell |
| `rpi.deploy.target`                      | `"root@<hostName>"`               | where `rpi-deploy` goes (together with `rpi.ssh.port`)                                                          |
| `rpi.pull.repo`, `rpi.pull.branch`       | `null`, `"main"`                  | GitHub repo whose CI builds this host; derives the pointer URL (section "Pull: CI builds, the Pi pulls")        |
| `rpi.pull.cache`                         | `null`                            | `{ name; publicKey; }` of your Cachix cache: where CI publishes and the Pi pulls from                           |
| `rpi.pull.enable`                        | on when pointer and cache are set | the `rpi-pull` timer on the Pi                                                                                  |
| `rpi.sdWear.*`, `rpi.storage.external.*` | on / off                          | fewer SD writes; optional USB data disk (see below)                                                             |

Kept as `mkDefault`s (set the NixOS option to change them): zram swap 50 %,
weekly GC (`--delete-older-than 21d`), extlinux keeps 5 generations, no channels,
`nixpkgs.flake` registry and `NIX_PATH` pointing at the system's own nixpkgs,
`security.sudo.wheelNeedsPassword = false` (key-only login), `documentation.enable
= false`, `boot.tmp.cleanOnBoot`, nix `max-jobs` and `cores` 3, `allowUnfree`.

A host with a fixed address, another timezone and a few more settings:

```nix
{ pkgs, ... }:
{
  networking.hostName = "garden";
  time.timeZone = "Europe/Stockholm";
  rpi.admin.sshKeys = [ "ssh-ed25519 AAAA… you@laptop" ];
  rpi.network = {
    mode = "static";
    static = { address = "192.168.1.20/24"; gateway = "192.168.1.1"; dns = [ "192.168.1.1" ]; };
  };
  environment.systemPackages = with pkgs; [ screen ];
  system.stateVersion = "26.05";   # the release this Pi was first installed with: never change it
}
```

**More hosts.** Add `nixosConfigurations.<name> = rpi.lib.mkPi { modules = [
./hosts/<name>.nix ]; };` to your flake. Every `mkPi` host is discovered by
`rpi-deploy` and by CI (one build job each). `rpi-deploy --host NAME` (or
`RPI_HOST`) picks one; with a single host it is chosen for you.

**Without `mkPi`.** `nixosModules.default` (the `rpi.*` modules) and
`nixosModules.terminal` (the profile, needs the home-manager NixOS module)
can be imported into your own `nixosSystem`; you then wire nvmd's
`raspberry-pi-3.base` module and the hybrid inputs yourself (see
"Binary cache and pins"). `mkPi` does all of it.

### Wi-Fi and secrets

Wi-Fi is off by default (the `disable-wifi` overlay keeps the chip off). To
turn it on, set `rpi.wifi.enable` and map each SSID to the name of a variable
that holds its password:

```nix
rpi.wifi = {
  enable = true;
  networks = { "My SSID" = "RPI_WIFI_HOME"; };
};
```

The passwords never enter the Nix store (it is world-readable on the Pi and
goes to your cache). They live in a file on the Pi,
`rpi.wifi.secretsFile` (default `/var/lib/rpi/wireless.env`, one `VAR=PSK`
line per network), which wpa_supplicant reads (`pskRaw = "ext:VAR"`). Since
NixOS 26.05 the daemon runs as the user `wpa_supplicant`, so a tmpfiles rule
of the library makes the file `0600 wpa_supplicant:wpa_supplicant` at every
boot and switch. You give the values to `rpi-deploy` through the environment of one
command; a [SecretSpec](https://secretspec.dev) provider (keyring, dotenv,
1Password, … `secretspec config init`) is the intended source. Declare the
variable in `secretspec.toml` (the repo has one, the template too), then:

```sh
secretspec run -- rpi-deploy flash IMAGE DEVICE --wifi-env   # into the card, at flash time
secretspec run -- rpi-deploy secrets                          # later, into the running Pi
```

`secrets` writes the file over ssh (`install -m 600`, content on stdin),
applies that tmpfiles rule (`systemd-tmpfiles --create --prefix=<file>`) and
(re)starts wpa_supplicant when the Pi has it. Run it before or after the
deploy that turns Wi-Fi on: while the file is missing, wpa_supplicant is
skipped (`ConditionPathExists`), so the deploy does not fail, and `secrets`
starts it. `flash --wifi-env` writes it `root 0600`
(the card has no `wpa_supplicant` user yet); the first boot hands it over
before wpa_supplicant starts. A variable that is missing or contains a
newline fails the command with exit 2 naming the variable; nothing is written
and a value is never printed or put on a command line. With the dotenv
provider, quote values that contain spaces or `$` with single quotes:
`RPI_WIFI_HOME='my pass phrase'`. Without SecretSpec, `export
RPI_WIFI_HOME=...` before the command works as well.

Bluetooth: `rpi.bluetooth.enable = true;`. Wi-Fi and Bluetooth need the Pi 3
firmware: the library adds it back when you turn either on (`rpi.sdWear` drops
the other firmware blobs). Both are covered by evaluation checks only; the
hardware checklist is in `HANDOFF.md`.

### Pi configuration notes

- `rpi.sdWear` (default on): `hardware.enableRedistributableFirmware = false`
  and `hardware.firmware = []` (−770 MiB; wired LAN needs no blobs), `/` with
  `noatime,lazytime,commit=60`, `/tmp` as 256M tmpfs, journald `Storage=volatile`
  (16M, level info), no coredumps, `keep-derivations = false`, monthly fstrim,
  zram swap 50 % with `vm.swappiness = 100`, `vm.page-cluster = 0`. Rejected on
  purpose: `fsync-metadata = false`, `auto-optimise-store`, the `discard`
  option, f2fs/btrfs.
- `rpi.headless` (default on): `gpu_mem=16`, no `vc4-kms-v3d`, no audio, no
  camera/display auto-detect, no `cma=32M`. There is no HDMI console; the
  serial console is the UART on the GPIO header. The Wi-Fi and Bluetooth
  overlays belong to `rpi.wifi` and `rpi.bluetooth`.
- Nix: `nix.gc` weekly, `--delete-older-than 21d`; extlinux keeps 5
  generations; `nix.channel.enable = false`, the flake registry and `NIX_PATH`
  point at the system's own nixpkgs, so `nix shell nixpkgs#…` on the Pi hits the
  store and the caches.
- Access: `PermitRootLogin = prohibit-password`, `PasswordAuthentication = no`,
  `security.sudo.wheelNeedsPassword = false` (the admin user has no password,
  the login is key-only; same trust as the root key). Root's key: yours only
  (no restricted automation key; CI never logs in to the Pi, the Pi pulls).
- Options follow nixos-26.05 (e.g. `services.journald.extraConfig`; the newer
  `settings` is 26.11 only).

### External storage (USB data disk)

`rpi.storage.external` (default off) puts `/nix`, `/var` and `/home` on a USB
disk while the SD card stays the boot device (`/`, `/boot`, `/boot/firmware`).
Options: `enable`, `label = "PI_DATA"`, `fsType = "ext4"`,
`bind = [ "/nix" "/var" "/home" ]`, `swapSize = null` (MiB, swapfile
`/external/swapfile`). The disk is mounted at `/external` with
`neededForBoot` and **never `nofail`**: a missing disk stops the boot in the
emergency shell instead of booting a half system (serial console, or pick an
older generation, see "Recovery and rollback").

Migration (manual; the order matters, the new generation's closure must be
on the disk before the first boot with it):

1. Format the disk **on the Pi or the host**: `mkfs.ext4 -L PI_DATA /dev/sdX1`
   (DESTROYS it). Plug it into the Pi.

2. Set `rpi.storage.external.enable = true;` in your host module, commit,
   `rpi-deploy deploy boot` (activates nothing yet).

3. On the Pi, copy the data (services that write to `/var` should be quiet;
   repeat the `rsync` right before the reboot):

   ```sh
   ssh root@<address>
   RSYNC=$(nix build --no-link --print-out-paths nixpkgs#rsync)/bin/rsync   # fetch it before the store goes quiet
   mkdir -p /mnt/data && mount /dev/disk/by-label/PI_DATA /mnt/data
   systemctl stop nix-daemon.socket nix-daemon.service
   for d in nix var home; do mkdir -p /mnt/data/$d; $RSYNC -aHAXx --numeric-ids /$d/ /mnt/data/$d/; done
   sync; umount /mnt/data
   ```

   For a fully consistent copy, power the Pi off and run the same `rsync`
   from the host with the card's `NIXOS_SD` and the disk mounted.

4. `ssh root@<address> reboot`; afterwards `findmnt /external /nix`.

The old copies of `/nix`, `/var` and `/home` stay on the SD underneath the bind
mounts (unused while the disk is attached; reclaim the space from the host if
you need it).

## Changing the configuration

The Pi cannot evaluate its own configuration: evaluating a NixOS system takes
~1.1 GB of RAM, and the Pi has ~870 MiB usable. So there is nothing to edit on
the Pi. The source of the configuration is your repository (`hosts/<name>.nix`,
or `hosts/<name>/`); the Pi only has `/run/current-system` and its generations.
`/etc` consists of links into the store, so a hand edit of a managed file is
lost at the next deploy. State under `/var/lib` survives.

| way                      | how                                                                                                                                                                                      | needs                                                                                                     |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| push from the host       | edit the repo, then `rpi-deploy deploy` (see "Push from the build host")                                                                                                                 | a build host with aarch64 emulation; no cache of your own                                                 |
| pull                     | commit and push to `main` from anywhere, also from a clone on the Pi itself; CI builds it, the Pi applies it at the next timer run, or at once with `systemctl start rpi-pull` on the Pi | CI with your cache (see "Pull: CI builds, the Pi pulls"); a clone on the Pi also needs GitHub push access |
| temporary test on the Pi | `nix shell nixpkgs#<package>` for a tool, `systemctl start`/`stop <unit>` to try a service; gone with the shell or at the next deploy or reboot                                          | nothing                                                                                                   |
| ssh to the host          | ssh to your build host and run `rpi-deploy deploy` there                                                                                                                                 | the same as push from the host                                                                            |

A clone on the Pi only holds and edits text: it cannot evaluate it, CI does.
That is why the pull route needs the cache and the repo's CI to be set up first.

## Updates

Two ways to bring a new system to the Pi; they combine, but read "Semantics
worth knowing" in the pull section first.

|            | push from the build host                                           | pull: CI builds, the Pi pulls                                                         |
| ---------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------------------- |
| who builds | your build host (aarch64 emulation)                                | GitHub Actions on an arm64 runner                                                     |
| needs      | the build host on, ssh access to the Pi                            | CI, your own signed Cachix cache, `rpi.pull.*` set                                    |
| when       | when you run `rpi-deploy deploy`                                   | weekly (lock update), on every push to `main`, on demand; the Pi looks daily at 05:00 |
| good for   | configuration changes, kernel and firmware changes, a first deploy | security updates that arrive while your build host is off                             |

### Push from the build host

```sh
rpi-deploy deploy [switch|boot|test] [--host NAME] [--target USER@HOST] [--port N] [--flake DIR] [--max-builds N] [--force]
rpi-deploy status [--host NAME] [--target USER@HOST] [--port N] [--flake DIR]
```

`deploy` runs the guards, then the flake's **pinned** `nixos-rebuild`
(`apps.x86_64-linux.nixos-rebuild`, nixos-rebuild-ng from the library's 26.05
nixpkgs: `nix run .#nixos-rebuild -- …`) with `--no-reexec --flake .#<host>
--target-host <target>`. Never the host's own `nixos-rebuild`: a newer one
half-applies on the Pi (it passes a `systemd-run` flag the Pi's systemd lacks).

The host is `--host`, else `$RPI_HOST`, else the only Pi host. The target and
port are `--target`/`--port`, else `$RPI_TARGET`/`$RPI_PORT`, else the host's
`rpi.deploy.target` and `rpi.ssh.port` (evaluated only when one of the two is
missing). Put `RPI_HOST`, `RPI_TARGET` and `RPI_PORT` of your machine in
`devenv.local.nix` (gitignored; `devenv.local.nix.example`), for example
while a hostname does not resolve yet.

| action             | effect                                                                                                                                |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------- |
| `switch` (default) | build, copy, make it the boot default and activate now; prints `status` afterwards                                                    |
| `boot`             | make it the boot default, activate at the next reboot (use for kernel or firmware changes; `status` then shows `reboot pending: yes`) |
| `test`             | activate now, boot default unchanged (gone after a reboot)                                                                            |

After every deploy (also a failed one) the Pi runs `sync`: switch and boot
rewrite the vfat `NIXOS_BOOT` partition, and `switch-to-configuration` only
flushes the store's filesystem. A power cut before the flush can corrupt the
firmware files (see "Recovery and rollback").

A deploy takes a few minutes: measured in qemu (TCG, ~5x slower than a Pi 3)
276 s = guards 23 s, local build + copy 43 s, firmware copy to the FAT partition
137 s (every switch rewrites all firmware files), extlinux 6 s, activation
56 s. Expect clearly less on the real Pi [?].

**Downgrade protection.** CI commits lock updates to `main`. If the
`flake.lock` in your local `origin/main` ref pins a newer `nixpkgs` or
`nixos-raspberrypi` (its `locked.lastModified`) than the `flake.lock` in your
working tree, `deploy` refuses with `would downgrade … run 'git pull' first`
(CI already built newer pins). It compares lock content, not commits: after a
squash-merge, cherry-pick or your own `nix flake update` the lock is current
and `deploy` proceeds. If a lock cannot be read it refuses too (`cannot
compare`). It never fetches: it reads the `refs/remotes/origin/main` you
last fetched, so `git pull` (or `git fetch`) first; without an `origin`
remote or that ref the check is skipped. Override with `--force`.

**`status`** prints:

```
current: /nix/store/…-nixos-system-<host>-…     # running now
booted: /nix/store/…-nixos-system-<host>-…      # running since the last boot
default: /nix/store/…-nixos-system-<host>-…     # what the next boot starts
reboot pending: no
pull applied: seq 12 /nix/store/…-nixos-system-<host>-… (3h ago)
pull last run: applied (exit 0) at 2026-10-25T05:07:41Z
```

The last two lines are the pull state (see "Pull: CI builds, the Pi pulls"):
`pull applied: none` / `pull last run: never` before the first run, `pull:
disabled` when the Pi's system has no `rpi-pull` unit, `pull: unknown (…)` when
the query fails (it never fails `status`). The age in `pull applied` is how
long ago the Pi *applied* that seq (the mtime of `/var/lib/rpi-pull/seq`), not
the age of the pointer: a pointer CI stopped refreshing shows up only as `pull
last run: stale (exit 39)`. A `pull last run` with a non-zero exit and a result
like `untrusted`, `fetch-failed` or `stale` is what to look at.

`reboot pending: yes (…)` means a reboot would change the running system, for
one or both reasons:

- `the boot default is not the running system`: after `deploy boot` (or
  `test`);
- `changed since boot: kernel, fat, …`: a boot-critical part of the boot
  default differs from the booted system's (after a `switch` to a new kernel or
  firmware). The parts (the *boot fingerprint*, `rl_fp_*` in `rpi-fp.sh`, which
  `rpi-pull` uses too):
  `kernel`, `initrd`, `kernel-modules`, `dtbs`, `kernel-params`, and `fat` --
  the inputs of the `NIXOS_BOOT` partition (Pi firmware package, generated
  `config.txt`, U-Boot), read from the toplevel's bootloader installer.

**`secrets`** (`rpi-deploy secrets [--host NAME] [--target …] [--port N]`)
writes the Wi-Fi secrets file to the running Pi, see "Wi-Fi and secrets".

Exit codes (all subcommands): 2 usage, 10 kernel not cached, 11 forbidden local
build, 12 too many local builds, 13 build/eval failed, 14 deploy failed,
15 would downgrade, 16 device refused, 17 verify failed. There is no
override for the guards (plain `nix build` stays possible if you really want a
local kernel build; expect 16+ h under qemu).

Environment: `RPI_FLAKE` (default flake dir), `RPI_HOST`, `RPI_TARGET`,
`RPI_PORT`, `RPI_SSH_OPTS` (extra ssh options), `RPI_NIXOS_REBUILD` (use this
`nixos-rebuild` instead of the pinned one), `RPI_CACHE_URL`. `--attr` is a
deprecated alias of `--host`.

### Pull: CI builds, the Pi pulls

Security updates reach the Pi without the build host being on and without the
Pi evaluating the flake. GitHub Actions builds the system, a timer on the Pi
pulls it. It needs your own Cachix cache and a GitHub repository; without a
cache CI still builds and tests every host, it just publishes nothing.

**CI** (`.github/workflows/pi.yml`, `ubuntu-24.04-arm`, always on `main`; the
template ships the same workflow): runs on cron `17 0 * * 0` (Sunday 00:17
UTC), on every push to `main` except changes to `deploy/**`, `docs/**` and
`*.md`, and on `workflow_dispatch` (inputs `update-lock` and `update-library`;
dispatched on another branch the jobs are skipped: they would build `main`
anyway). One run at a time
(`concurrency: pi`). The third-party actions are pinned by full commit SHA
(tag in a trailing comment; the `actionlint` check enforces it) and get no
secrets: the signing key and the auth token only reach `rpi-ci publish`,
because together they are root on the Pi. Dependabot
(`.github/dependabot.yml`) opens weekly PRs that bump the pins: read what
changed before merging one. The jobs run `rpi-ci` of the committed lock:
`hosts` with `nix run --inputs-from . rpi#rpi-ci -- hosts` in your repo (`nix
run .#rpi-ci` in this one); the build and commit jobs build it once, before
anything updates the lock (`nix build --inputs-from . rpi#rpi-ci --out-link
"$RUNNER_TEMP/rpi-ci"`), and call only that, so the secrets never meet
library code an update brought in:

1. `hosts`: lists the flake's Pi hosts (`lib.mkPi`) as the build matrix.
2. `build` (one job per host, named `build <host>`, `contents: read` only):
   1. cron (or `update-lock`): `nix flake update` of `nixpkgs` and
      `nixos-raspberrypi`; in a repo built on the library those are the
      library's own (`rpi/nixpkgs`, `rpi/nixos-raspberrypi`), never `rpi`
      itself. Only the manual `update-library` input moves `rpi` (with the
      inputs the library locked);
   2. guards (`rl_guard`, the same code as `rpi-deploy`): the kernel must be in
      nvmd's cachix, no kernel/toolchain build, at most 500 local builds. A
      kernel cache miss after the lock update falls back to the committed lock
      plus a `nixpkgs`-only update, so an uncached nvmd `develop` HEAD does not
      hold back the userspace fixes;
   3. build the host's toplevel, then every `checks.aarch64-linux` of the
      flake (ours: shellcheck and the unit tests): a broken `rpi-pull.sh` or CI
      script is never published;
   4. `rpi-ci publish`: with `rpi.pull.cache` set, `cachix push` the closure to
      **your** cache and `cachix pin <cache> <hostname> --keep-revisions 4`
      (Cachix exempts the last four pinned store paths from garbage collection;
      that the pin also keeps their closures is not documented and not verified.
      An evicted path shows up on the Pi as exit 38 or 33, and the next CI run
      re-uploads it: `cachix push` runs on every run and uploads what is
      missing). **Without a cache:** the job stays green and prints `::notice::
      no cache configured for <host>: built and tested, not published`. **With a
      cache but without the secrets** `CACHIX_AUTH_TOKEN` or
      `CACHIX_SIGNING_KEY`: `::error::` naming the missing secret, the job fails;
   5. only after push and pin: write the pointer `deploy/<hostname>.json` and
      upload it with `flake.lock` as an artifact.
3. `commit` (one job, `contents: write`, only when every build succeeded, on
   `main` only): one commit of `flake.lock` and all pointers as
   `github-actions[bot]` (unsigned; one rebase and retry if `main` moved), so
   matrix jobs never push concurrently. The jobs' locks must be identical,
   otherwise nothing is committed. All jobs build the commit the `hosts` job
   saw; when `main`'s `flake.lock` changed since (a lock update pushed during
   the build), nothing is committed either (`::error::`), so the update is
   never reverted: the run that push started builds it. A failing job leaves
   the pointers and the Pi untouched. The same toplevel as the pointer's → no
   commit.

The job names include the host, every step writes a summary section (host,
nixpkgs/nvmd revisions and the lock diff, toplevel path, closure size, paths
pushed, pointer seq, whether the boot fingerprint changed: switch or reboot on
the Pi, skipped steps with the reason), and errors, warnings and notices are
GitHub annotations. The scripts emit these only when `GITHUB_ACTIONS=true`.

The host's own cache is added to the build as an extra substituter
(`--option extra-substituters https://<name>.cachix.org --option
extra-trusted-public-keys <key>`; the cache name is only known once the host is
evaluated). The nix daemon honours these options only for trusted users, which
the runner's user is: `cachix/install-nix-action` makes it one
(`set_as_trusted_user` defaults to `true`). Do not turn that setting off in your
workflow.

The pointer: `{ "seq": N, "storePath": "/nix/store/…-nixos-system-<host>-…",
"narHash": "sha256-…", "rev": "<git sha built>", "built": "YYYY-MM-DDTHH:MM:SSZ",
"bootFp": "<sha256 of the boot fingerprint>" }`. `seq` is the workflow's
`run_number` (a positive integer of at most ten digits); `built` must have
exactly that UTC form or the Pi rejects the pointer. `bootFp` only feeds the
CI summary; the Pi ignores it.

**The Pi** (`modules/pull-update.nix`, unit `rpi-pull`, `rpi-pull.sh`): the
timer runs **daily at 05:00** (`*-*-* 05:00`, up to 30 min random delay,
`Persistent=true`: a Pi that was off catches up at boot, once the clock is
NTP-synchronized: the unit waits for `systemd-time-wait-sync`, which only it
pulls in, so boot never waits for NTP; after 30 min without a sync it runs
anyway).
A run without a new pointer is one HTTP request. Each run:

1. fetches the pointer (HTTPS, size and time limits); HTTP 404 → `no pointer
   published yet`, exit 0, but only while no pointer was ever applied: once
   one was, a 404 is exit 30 (`pointer disappeared`: the repo was made
   private, renamed or deleted, or the pointer file removed), so the Pi
   cannot stop updating silently;
2. validates it: `seq` equal to the applied one → `up to date`, exit 0; older →
   exit 31; the store path must match `nixos-system-<hostname>-…` in `/nix/store`;
3. reads the store path's narinfo from your cache (`nix path-info --store
   <cacheUrl> --json`) *before anything is realised*: it must be
   input-addressed, name a signature by your key and carry the pointer's
   narHash; `nix store verify --no-contents --store <cacheUrl>
   --trusted-public-keys <your key>` checks that signature (exit 32
   `untrusted`, 34 narHash mismatch, 38 cache unreachable or the path not in it);
4. already the running system → record the seq and stop; otherwise
   `nix-store --realise` (two substitution jobs, ~80 MB RSS), compare the
   narHash with the pointer's and require the realised path to be
   input-addressed (exit 33 / 34 / 32);
5. compares the boot fingerprint of the new system with the booted one (the
   `status` logic), *before* touching the profile: equal →
   `nix-env --set` + `switch-to-configuration switch`; different (kernel, initrd,
   modules, device trees, kernel parameters, firmware, `config.txt` or U-Boot) →
   `switch-to-configuration boot` + `shutdown -r 06:30` (the next 06:30, normally about an hour after
   the 05:00 run; `shutdown -c` cancels it; `rebootTime` is an option). The Pi is not left half-applied by a fingerprint failure
   (exit 36 before the profile changes);
6. `sync`, record the seq and store path in `/var/lib/rpi-pull/`;
7. if the pointer was built more than `maxAgeDays` (default 21) ago: exit 39,
   `pointer is N days old (CI stalled?)` -- CI stopped publishing (also catches
   GitHub disabling the schedule after 60 days without repository activity).
   `built` is only rewritten when the toplevel changes, so a healthy CI that
   builds the same system for 21 days (a frozen channel, e.g. after the 26.05
   end of life, or only lock changes that leave the toplevel equal) trips it
   too: then the alarm means "no new system", which after the end of life is
   the reminder to bump the release.

Every run that got the lock writes `/var/lib/rpi-pull/last-run`
(`time=… exit=… result=…`); the unit fails visibly (`systemctl status
rpi-pull`) on any non-zero exit. Exit codes of `rpi-pull`: 0 ok, 1 state dir unusable,
2 usage, 30 fetch, 31 pointer invalid or older, 32 untrusted (not signed by
your key, or content-addressed), 33 realise, 34 narHash mismatch, 35 profile,
36 activation, 37 busy (another run), 38 cache unavailable or the system not
in it, 39 pointer stale. The service is `Type=oneshot` with
`restartIfChanged = false` (a switch that changes the unit must not stop the
run that performs it), `MemoryMax=384M`, nice/ionice/CPU idle, `TimeoutStartSec=2h`.

> **Trust.** Before anything is realised, the toplevel's narinfo in your cache
> must be **input-addressed, signed by *your* cache key and carry the pointer's
> narHash**. The signature check is yours-only: `--trusted-public-keys` replaces
> the Pi's configured keys, so a system signed by cache.nixos.org or nvmd's
> cachix does not pass. A content-addressed toplevel is refused (exit 32): nix
> treats a content-addressed path as valid **without any signature** (in
> `nix store verify` and when substituting), so whoever can write to the
> cache (the auth token, or Cachix itself) could otherwise publish an
> unsigned system of their own. These checks cover the toplevel path only.
> After the realise the **realised path's narHash must equal the pointer's**
> (and so the signed narinfo's), and the path must be input-addressed in the
> local store too: that binds the activated content to your signature (a
> foreign or tampered system fails with 32 or 34). The dependencies of the
> closure are substituted with `require-sigs` and the three configured keys
> (cache.nixos.org, nvmd's cachix, yours): a dependency the Pi does not have
> yet may come with any of the three signatures. Accepted residual risk: nvmd's
> cache is hosted by Cachix, and if its key is Cachix-managed (not verified), a
> Cachix compromise could replace such a dependency's content, though not the
> toplevel's (its narHash is pinned). The pointer itself is not signed:
> it is only as trustworthy as write access to the repo. A compromised GitHub
> account or secrets means a deploy to the Pi, the same level as the root SSH key.
> The monotonic `seq` refuses an older pointer (a rollback attempt).

**`rpi.pull` options** (`modules/pull-update.nix`): `repo` (`owner/name`),
`branch` (`main`), `cache` (`{ name; publicKey; }`), `pointerUrl`, `cacheUrl`,
`cachePublicKey`, `onCalendar` (`*-*-* 05:00`), `rebootTime` (`06:30`),
`maxAgeDays` (`21`), `enable`. With `repo` and `cache` set, the module derives
`pointerUrl = https://raw.githubusercontent.com/<repo>/<branch>/deploy/<hostName>.json`,
`cacheUrl = https://<name>.cachix.org` and `cachePublicKey`; each stays
overridable. `rpi.pull.enable` is on once the pointer, the cache URL and the
key are all set. With neither repo nor cache the module is simply off; with
only part of it set it **stays off with an evaluation warning** (`rpi.pull
stays disabled: … not set`). Once enabled, your cache is added to the Pi's
`substituters` and `trusted-public-keys` (cache.nixos.org and nvmd's stay).
An `http://` pointer URL is accepted for the qemu smoke test only (warning).
The pointer is keyed on `config.system.name` (the hostname), not on the name of
the `nixosConfigurations` attribute, so the file in the repo and the Pi's URL
always agree.

#### Setup (once; steps only you can do)

1. **GitHub.** A **public** repo (free arm64 runners; `raw.githubusercontent.com`
   serves the pointer): `<owner>/<repo>` as in `rpi.pull.repo`. Push `main`.
   Settings → Actions → General → Workflow permissions: **Read and write**. No
   branch protection or ruleset on `main` that blocks `github-actions[bot]` (or
   give it a bypass), because the commit job pushes the lock and pointer commit.
2. **Cachix cache, self-signed.** Create a public cache whose signing key you
   generate yourself (an advanced choice at creation; Cachix never holds the key):
   `cachix authtoken <token>`, `cachix generate-keypair <cache>` prints the
   secret key once. Store it as the GitHub secret **`CACHIX_SIGNING_KEY`**
   (nowhere in the repo), and a write token of the cache as
   **`CACHIX_AUTH_TOKEN`**. A Cachix-managed key is not enough: whoever holds the
   auth token could then sign arbitrary content. These are the only secrets CI
   needs, and they exist only as GitHub Actions secrets.
3. **Host module:** `rpi.pull.repo = "<owner>/<repo>"; rpi.pull.cache = { name =
   "<cache>"; publicKey = "<cache>.cachix.org-1:…"; };` (the public key from the
   Cachix dashboard). Commit and push to `main`.
4. **First CI run.** Actions → `pi` → *Run workflow* (`main`). The first push
   uploads ~340 MiB, later runs ~150 MiB (the free tier has 5 GB and evicts by
   LRU; the pin exempts the last four toplevels). It pushes, pins and commits
   `deploy/<hostname>.json`; `git pull` it.
5. **Dispatch a second time** and confirm that it produces **no** pointer
   commit (same store path, `pushed=false`). If it commits a new pointer every
   time, the toplevel is not reproducible between runs: find out what differs
   before relying on the timer.
6. **Enable the timer on the Pi** with one manual `rpi-deploy deploy switch`
   from a tree that has `rpi.pull.cache` (an image built then ships the timer
   already). From then on the Pi pulls on its own: it applies the pointer at its
   next 05:00 run, or at once with `ssh root@<address> systemctl start rpi-pull`
   (watch `journalctl -fu rpi-pull`).
7. **Hardware acceptance:** `rpi-deploy status` shows `pull applied: seq N …`
   and `pull last run: applied (exit 0) at …` after the first run that applied
   something (checklist in `HANDOFF.md`).

#### Operating it

| what                  | how                                                                                                                                                                                                                                                              |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| build and publish now | Actions → `pi` → *Run workflow*; tick `update-lock` to also update `nixpkgs`/`nixos-raspberrypi` (`gh workflow run pi.yml -f update-lock=true`); in a repo built on the library tick `update-library` to move the library (`rpi`) after reading its changes      |
| apply on the Pi now   | `ssh root@<address> systemctl start rpi-pull` (blocks until done; ≤ 2 h)                                                                                                                                                                                         |
| logs                  | `ssh root@<address> journalctl -u rpi-pull`                                                                                                                                                                                                                      |
| timer                 | `ssh root@<address> systemctl list-timers rpi-pull`                                                                                                                                                                                                              |
| state                 | `rpi-deploy status`: `pull applied: seq N <path> (3h ago)` (applied 3h ago) or `pull applied: none`; `pull last run: <result> (exit N) at <time>` or `never`; `pull: disabled` (no unit: the Pi runs a system without the timer); `pull: unknown` (query failed) |

(Add `-p <port>` to `ssh` when `rpi.ssh.port` is not 22.)

#### Semantics worth knowing

- *A push to `main` is a deploy.* Every push that touches more than `deploy/**`,
  `docs/**` and `*.md` builds and publishes; the Pi applies it at its next daily
  run. CI builds `main` with `ref: main` whatever started the run, so unpushed
  local changes are not in it.
- *Manual deploys persist until the next CI build.* The Pi applies a pointer
  only if its `seq` is newer than the last one applied, so `rpi-deploy deploy`
  stays in place; the next CI run replaces it with `main`'s system. Push
  before the run you want it to survive.
- *Do not deploy manually while `rpi-pull` runs* (from 05:00, up to 30 min
  delay plus the run itself, or after `systemctl start rpi-pull`; check with
  `ssh root@<address> systemctl is-active rpi-pull`). `rpi-deploy deploy`
  does not take `rpi-pull`'s lock: the two can interleave `nix-env --set`
  (`switch-to-configuration` serializes only the activation), and the pull
  may replace the manual deploy.
- *A freshly flashed Pi has no applied seq.* At its first run it applies the
  current pointer, even if the flashed image is newer (built locally, not
  pushed): push to `main` before flashing, or expect the downgrade.
- *A pointer older than the applied seq fails the unit* (exit 31): a rollback
  attempt or a reset of the repo. An equal seq is a silent `up to date`. After
  a rollback on the Pi (see "Recovery and rollback") the same seq is **not**
  re-applied; it stays rolled back until the next CI build.
- *Timing.* CI runs Sunday 00:17 UTC (a build takes minutes to a few hours,
  longer after a cold cache); the Pi looks daily at 05:00 local + ≤ 30 min, so
  a fresh pointer is applied within about a day, a needed reboot at the next 06:30.
- *Failures are loud and safe.* Cache outage between pointer and pull → exit
  33/38, profile and seq untouched, retried the next day. `rpi-pull` never
  evaluates or builds.
- *Your repo takes library changes only when you say so.* The weekly run
  updates nixpkgs and nixos-raspberrypi (in your lock: `rpi/nixpkgs`,
  `rpi/nixos-raspberrypi`) and commits the lock. The library itself (`rpi`:
  modules, `rpi-pull`, `rpi-ci`) moves only when you dispatch the workflow
  with `update-library` or run `nix flake update rpi` and push. Read the
  library's changes first: whoever can push to it is root on your
  pull-enabled Pi once you take them (your CI builds and signs it). To pin
  it, set `inputs.rpi.url` to a tag or revision.

## Binary cache and pins

What is built where, and what you download:

- The kernel and firmware come from the nvmd cache
  (`nixos-raspberrypi.cachix.org`); almost all userspace comes from
  cache.nixos.org. Both are shared by everyone on the same lock, so a host
  on the library's locked inputs builds almost nothing itself.
- Configuration changes such as hostname, keys or network rebuild only ~16
  small derivations. Adding or removing a package does not invalidate other
  packages. Overlays and overrides rebuild their dependents (and everything
  that depends on those), so keep them few.
- The Pi cannot evaluate its own configuration (~1.1 GB). A build host (push,
  needs no cache of your own) or CI (pull, needs your own signed cache, which
  stays small if you only use upstream packages) builds it.
- Using our cache would mean trusting our signing key. That is opt-in and not
  a default: this library never adds our cache to your system. Your own host
  trusts only your own key (see "Trust" above).

Consumers keep the locked inputs of the library (`rpi.url = "github:GRBurst/nix-raspi"`
and **no** `follows` on it): that inheritance is what makes the caches hit.
The weekly CI update then moves only the library's `nixpkgs` and
`nixos-raspberrypi` in your lock (`nix flake update rpi/nixpkgs
rpi/nixos-raspberrypi`); nvmd keeps its own nixpkgs pin, so its kernel stays
cached (the guards check it). `nix flake update rpi` returns to exactly the
library's lock.
`nixos-raspberrypi` is on branch `develop` and **keeps its own nixpkgs pin**,
so the vendor kernel/firmware derivations hash exactly like nvmd's cachix
builds. The library's `nixpkgs` (`nixos-26.05`) is a separate input that drives
all userspace (security fixes track the release branch). `lib.mkPi` builds the
system with `nixos-raspberrypi.lib.nixosSystem { inherit nixpkgs; … }`. Rules
(enforced by `checks.x86_64-linux.eval-kernel`):

1. Never add `follows` between `nixpkgs` and `nixos-raspberrypi/nixpkgs`.
   `config.boot.kernelPackages.kernel` must equal nvmd's own `linuxPackages_rpi3`
   kernel (same store path), otherwise the kernel compiles locally (16+ h).
   Out-of-tree kernel modules only from `config.boot.kernelPackages`.
2. The cache must be enabled on the host: the flake carries it in
   `nixConfig` (`--accept-flake-config`, which `rpi-deploy` passes, works for
   trusted nix users; the template carries the same `nixConfig`) and
   `rpi.buildHost.enable = true` adds it to `nix.conf`. The Pi trusts it via
   nixos-raspberrypi's module. In CI the workflow sets it in `extra_nix_config`.
3. `nix flake update nixos-raspberrypi` can land on a `develop` HEAD whose
   kernel is not cached yet (the cadence is weekly). The guards catch that;
   the CI build (`rpi-ci build`) then falls back to updating `nixpkgs` only.
   A manual `nix flake update` has no such fallback.

Check by hand:

```sh
nix build --accept-flake-config --dry-run .#nixosConfigurations.<host>.config.system.build.sdImage 2>&1 \
  | sed -n '/will be built/,/will be fetched/p' \
  | grep -E -- '/[0-9a-z]{32}-(linux_rpi-[^ ]*[0-9]|linux-config-[^ ]*)\.drv$'   # must print nothing
```

Home Manager is `master`, not release-26.05 (nix-terminal needs
`programs.devenv`); the terminal profile silences the release-mismatch warning.

## Troubleshooting

| symptom                                                               | cause and fix                                                                                                                                                                    |
| --------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| evaluation fails: `rpi.admin.sshKeys is empty`                        | add your public key to `rpi.admin.sshKeys` in the host module (the library refuses to build a locked-out image)                                                                  |
| `nix flake` does not see `hosts/rpi.nix` or your edit                 | a git flake only sees tracked files: `git add -A`                                                                                                                                |
| `builder failed with exit code 255`                                   | no aarch64 emulation on the build host: `boot.binfmt.emulatedSystems = [ "aarch64-linux" ];` (see "Build host prerequisites")                                                    |
| the guard stops with exit 10 or 11, or a kernel starts compiling      | the nvmd cache is not used: you are not a trusted nix user (`rpi-doctor`), or a lock update moved `nixos-raspberrypi` to an uncached HEAD (`git checkout flake.lock`)            |
| `deploy` or `status`: cannot reach the Pi                             | wrong address or port: `RPI_TARGET=root@<address>`, `RPI_PORT=<port>`, or set `rpi.deploy.target`; try `ssh -p <port> root@<address> true` first                                 |
| ssh: `REMOTE HOST IDENTIFICATION HAS CHANGED` after a re-flash        | the host key is new: `ssh-keygen -R <address>` (`'[<address>]:<port>'` for a non-default port)                                                                                   |
| ssh: `Bad owner or permissions on …` (sandboxed or odd setup)         | the system `ssh_config` includes files plain `ssh` rejects: use `RPI_SSH_OPTS='-F /dev/null'` or your own config                                                                 |
| `deploy` refuses: `would downgrade … run 'git pull' first` (exit 15)  | CI committed a newer lock to `main`: `git pull`, or `--force`                                                                                                                    |
| `rpi-deploy` exits 2: several Pi hosts                                | choose one with `--host NAME` or `RPI_HOST`                                                                                                                                      |
| `rpi-deploy secrets` / `flash --wifi-env` exits 2 naming a variable   | the PSK variable is not in the environment (`secretspec run -- …`) or contains a newline                                                                                         |
| CI: `::error::` naming `CACHIX_AUTH_TOKEN` or `CACHIX_SIGNING_KEY`    | the host sets `rpi.pull.cache` but the repository secret is missing: add it (Settings → Secrets and variables → Actions), or remove `rpi.pull.cache` to build without publishing |
| CI: `no cache configured for <host>: built and tested, not published` | a notice, not an error: the host has no `rpi.pull.cache`                                                                                                                         |
| `status`: `pull last run: … exit 38/33`                               | the cache was unreachable or evicted the path; the next CI run re-uploads it, the Pi retries the next day                                                                        |
| `status`: `pull last run: stale (exit 39)`                            | CI stopped publishing, or nothing changed for `maxAgeDays`; check the workflow runs (also after the 26.05 end of life: bump the release)                                         |
| the Pi stays on its old system after a push to `main`                 | the pointer is applied at the next daily run: `ssh root@<address> systemctl start rpi-pull`, then `journalctl -u rpi-pull`                                                       |

### Recovery and rollback

**Userspace regression** (the system boots, something is wrong): roll back one
generation from the host:

```sh
NIX_SSHOPTS='-p <port>' nix run .#nixos-rebuild -- switch --rollback --no-reexec --target-host root@<address>
```

The rollback persists against the pull: `rpi-pull` applies a pointer only if
its `seq` is newer than the last one it applied, so the system you rolled back
from is **not** re-applied at the next run. The next CI build (a push to `main`
or the Sunday run) replaces the rolled-back system again: revert or fix `main`
before that.

**Unbootable new kernel or initrd.** There is no boot counting and no
automatic fallback: U-Boot's extlinux simply boots the default entry. Two ways
back to an older generation (the last five, younger than 21 days, are kept:
`configurationLimit = 5`, weekly `nix.gc` deletes older generations; their
extlinux entries stay until the next install but no longer boot):

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
FAT only (needs the host's aarch64 binfmt):

```sh
TOP=$(nix build --accept-flake-config --no-link --print-out-paths \
  .#nixosConfigurations.<host>.config.system.build.toplevel)
INSTALL=$(sed -n "s/^export INSTALL_BOOTLOADER='\([^ ]*\) .*/\1/p" "$TOP/bin/switch-to-configuration")
sudo mount /dev/disk/by-label/NIXOS_BOOT /mnt
sudo "$INSTALL" -f /mnt -c "$TOP"     # firmware, config.txt, U-Boot; no -b: /boot untouched
sync; sudo umount /mnt
```

or re-flash only partition 1 from an image of the good commit (same layout,
so p1 has the same size; p2 with the system and its state stays):

```sh
rpi-deploy image --out ~/rpi-images
zstd -d ~/rpi-images/result-rpi-image/sd-image/<host>-rpi3.img.zst -o /tmp/good.img
LOOP=$(sudo losetup -P -r -f --show /tmp/good.img)
sudo dd if="${LOOP}p1" of=/dev/sdX1 bs=4M conv=fsync
sudo losetup -d "$LOOP"
```

The next deploy writes the firmware of whatever it deploys again; deploy the
good commit (or fix the cause on `main`) before the next CI build (a push to
`main`, or the Sunday run) is pulled.

**Pull stuck on a seq** (every run fails with exit 31):

- *The workflow's `run_number` was reset* (the workflow file was renamed, or
  the workflow or repo recreated): the new runs count from 1 again, so
  `rpi-ci pointer` refuses every run (`seq N is not newer than seq M`) until
  the counter passes the published seq, and the Pi would refuse the lower seq
  (exit 31) as well. Recovery: remove the pointer from `main` (`git rm
  deploy/<hostname>.json`, commit, push; this push does not start a run),
  reset the Pi's seq (`ssh root@<address> rm /var/lib/rpi-pull/seq`),
  then dispatch the workflow. Until the new pointer exists the Pi's runs say
  `no pointer published yet` (exit 0); afterwards it applies the new pointer
  like a freshly flashed Pi.
- *`/var/lib/rpi-pull/seq` is not a seq number* (`… is not a seq number`):
  every run exits 31 until it is removed (`rm /var/lib/rpi-pull/seq`); the next
  run applies the current pointer like a freshly flashed Pi.

**Dead card or re-flash**: flash a new image (see "Image and flash"). State on
the Pi is disposable by design; what is not in your repo (everything under
`/var/lib`, including the Wi-Fi secrets file) is gone.

## Our host: neptun

`neptun` is our own Pi 3 (`hosts/neptun/default.nix`, `hosts/neptun/home.nix`,
`nixosConfigurations.neptun`) and the example of a host built on the library.
Only its own values live there; everything else is the library's defaults:

| value                      | neptun                                                              |
| -------------------------- | ------------------------------------------------------------------- |
| hostname, timezone, keymap | `neptun`, `Europe/Berlin`, `neo`                                    |
| SSH                        | port 2222, our key for `pi` and `root`                              |
| network                    | static `192.168.100.20/24` via `192.168.100.1`, wired only          |
| user environment           | `rpi.profiles.terminal.enable` (zsh, nix-terminal) + `home.nix`     |
| updates                    | `rpi.pull.repo = "GRBurst/nix-raspi"`; pointer `deploy/neptun.json` |
| extras                     | neovim, screen, sysctl, `docker` and `video` groups                 |

Its cache is not set up yet: `rpi.pull.cache` stays unset (so pull is off, and
CI builds and tests neptun and prints the "not published" notice) until we
create the self-signed Cachix cache (steps 2 and 3 of "Setup").

Working on it from a checkout of this repository:

```sh
rpi-deploy image --host neptun --out ~/rpi-images
rpi-deploy flash ~/rpi-images/result-rpi-image/sd-image/neptun-rpi3.img.zst /dev/sdX
rpi-deploy deploy --host neptun          # target root@neptun, port 2222 from the host module
```

`ssh` needs the name and port: add to `~/.ssh/config` on the build host

```
Host neptun
  HostName 192.168.100.20
  Port 2222
```

(`rpi-deploy` passes the port itself; `--target root@192.168.100.20` avoids the
name.) After a re-flash: `ssh-keygen -R '[192.168.100.20]:2222'`.

### Re-flash the old install

The Pi that ran before the library was installed with the old `nixos-install`
flow: `pi` only, no root key, `pi` needs a sudo password, no `trusted-users`,
so a push deploy to it is impossible. Re-flash it (its state is disposable):

1. Make sure `hosts/neptun/default.nix` has our key (and, once the cache
   exists, `rpi.pull.cache`: an image built then already ships the pull timer;
   otherwise one `rpi-deploy deploy switch` adds it later).
2. `rpi-deploy image --host neptun`, `rpi-deploy flash … /dev/sdX`, boot.
3. `ssh-keygen -R '[192.168.100.20]:2222'`, then `ssh -p 2222 root@neptun true`
   and `ssh -p 2222 pi@neptun true`.
4. Walk through the hardware checklist in `HANDOFF.md`.
5. With pull set up: a freshly flashed Pi has no applied seq, so at its
   first run it applies the current pointer, even over a newer image you built
   locally. Push that state to `main` first, or expect the older system.

Wi-Fi is off on neptun (wired LAN only); the old `secrets/wireless.env` is not
used and not in the repo.

## Development

### devenv shell

`devenv shell` (or devenv's automatic activation) provides the tools this
repository's workflows need besides nix itself and checks both build host
prerequisites with `rpi-doctor`. The template has a smaller version of the same
shell.

- `rpi-deploy`: the working tree's `rpi-deploy.sh`. `RPI_FLAKE` is set to the
  repo root, so it needs no `--flake`.
- `cachix` (cache setup), `secretspec` (Wi-Fi passwords from your provider),
  `shellcheck` and `actionlint`, and the qemu smoke-test tools
  (`qemu-system-aarch64` with `raspi3b`, `debugfs`, `mcopy`, `sfdisk`, `zstd`).
- `rpi-unit` (also `devenv test`): `tests/*-unit.sh`, about 1 min.
- `rpi-check [--no-build]`: warms up every Pi host (`rl_hosts`), then
  `nix flake check` at the repo root.
- `rpi-doctor`: the prerequisite check.
- Git pre-commit hooks: shellcheck (`-x -P SCRIPTDIR -S warning`; not the
  vendored `tests/fixtures/`) and actionlint on staged files.
- `devenv.local.nix` (gitignored, copy `devenv.local.nix.example`): settings
  of your machine only: `RPI_HOST`, `RPI_TARGET`, `RPI_PORT`.

nixpkgs is `nixos-26.05`, the same release as the flake, pinned in
`devenv.lock` (`devenv update` moves it).

### Testing

```sh
nix flake check --accept-flake-config        # all checks incl. the VM test
nix build .#checks.x86_64-linux.eval-kernel  # one check
```

`nix flake check` needs the neptun toplevel evaluated once first (yazi's
import-from-derivation): `rpi-check` does that for every host, by hand:
`nix eval --raw .#nixosConfigurations.neptun.config.system.build.toplevel.drvPath`.

| layer                                                                                                                                                                                                                                            | check                                                                                                                                                   | cost                                                      |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| eval checks (option values and their effects: library entry point, identity, defaults, network, Wi-Fi, Bluetooth, terminal profile, kernel identity, image, sd-wear, headless, external storage, tools, build host, pull module, the template)   | `eval-<name>` from `tests/eval/<name>.nix` (`eval-template`: the real template evaluates through `lib.mkPi` with the local library)                     | seconds                                                   |
| unit tests, mocked nix/ssh/sudo/lsblk/dd/nixos-rebuild/curl/cachix, real git/zstd/flock                                                                                                                                                          | `rpi-deploy-unit` (host tool), `rpi-pull-unit` (every `rpi-pull` path), `rpi-ci-unit` (`ci/*.sh`), `rpi-lib-unit` (host discovery), `rpi-drv-diff-unit` | ~10–60 s each; auto-discovered from `tests/<n>-unit.sh`   |
| bash syntax + shellcheck (every `*.sh` outside `tests/`, incl. `ci/`)                                                                                                                                                                            | `rpi-deploy-syntax`                                                                                                                                     | seconds                                                   |
| the same unit tests and shellcheck for `aarch64-linux`: CI runs them before it publishes (on x86_64 `nix flake check` omits them as an incompatible system)                                                                                      | `checks.aarch64-linux.rpi-*`                                                                                                                            | ~1–3 min on the arm runner [?]                            |
| lint of both workflows (ours and the template's; + shellcheck on their `run:` steps); same shape, step order, one commit job, write permission only there, actions pinned by commit SHA, no secrets handed to an action, dependabot entry        | `actionlint`                                                                                                                                            | seconds                                                   |
| no personal value (hostname, key, IP, port, repo, timezone, keymap) in library code                                                                                                                                                              | `personal-values` (`tests/personal-values.sh`)                                                                                                          | seconds                                                   |
| NixOS VM test of the build-host module (binfmt, aarch64 `hello`, the `rpi-deploy` wrapper)                                                                                                                                                       | `rpi-host-vm`                                                                                                                                           | 1–16 min (half a minute of test script once built)        |
| qemu `raspi3b` boot of the template's default host (DHCP, port 22) + SSH banner over usb-net                                                                                                                                                     | `tests/boot-smoke.sh [IMAGE.img.zst]`                                                                                                                   | ~4–6 min                                                  |
| qemu deploy: boot neptun's image, `rpi-deploy deploy switch`, verify                                                                                                                                                                             | `tests/deploy-smoke.sh`                                                                                                                                 | ~20–30 min (image build ~10 min of it, cached on re-runs) |
| qemu pull: boot an image with a throwaway cache key, serve a signed local cache and a pointer over HTTP, let the guest's `rpi-pull.service` apply it (switch path, with a changed unit), then refuse a pointer signed by a foreign key (exit 32) | `tests/pull-smoke.sh`                                                                                                                                   | ~28 min (1656 s measured, image rebuilt)                  |

The smoke tests are not part of `nix flake check` (qemu TCG, minutes). All
need `qemu-system-aarch64` with `-M raspi3b` (`nix shell nixpkgs#qemu`),
`zstd`, `sfdisk`, `debugfs` and `mcopy`, no root:

```sh
tests/boot-smoke.sh              # builds the template's host with a throwaway key itself
tests/deploy-smoke.sh            # builds a throwaway-key image itself
tests/pull-smoke.sh              # throwaway root and cache keys, local cache on 127.0.0.1:18080
```

`pull-smoke` also needs `curl`, `jq` and network for the guards (busybox comes
from the pinned nixpkgs; the port is `RPI_PULL_SMOKE_HTTP_PORT`, default
18080, and part of the cached image). Not covered by it: the boot-and-reboot
path of `rpi-pull` (unit tests only) and the real GitHub and Cachix side.

What qemu cannot cover: U-Boot reading `extlinux.conf`, the GPU firmware
applying `config.txt`, a real card, the LAN, Wi-Fi and Bluetooth, the reboot
timer, GitHub Actions and Cachix. That is the manual hardware checklist in
`HANDOFF.md`.

The refactor invariant (the library change must not alter neptun's system):
`tests/drv-diff.sh` compares the derivation closures of neptun before and
after, leaf by leaf, against a list of expected differences (see `HANDOFF.md`).
The build-host module is also evaluated on every flake operation by contract
asserts (binfmt, extra-platforms, features, sandbox paths, cache, wrapper).

### Repo layout

```
.github/
  workflows/pi.yml     CI: a build job per Pi host, one commit job (main only); the template has the same file
  dependabot.yml       weekly PRs that bump the workflow's commit-SHA action pins
flake.nix              outputs: lib.mkPi, modules, templates, packages, apps, checks, neptun
flake.lock             pins: nixpkgs + nvmd (develop) + home-manager + nix-terminal + ...
lib/mkPi.nix           the entry point: nvmd base, hybrid inputs, rpi.* modules, home-manager
modules/
  default.nix            the rpi.* modules in one import list (nixosModules.default)
  base.nix               the kept mkDefaults (zram, GC, extlinux limit, timezone, ...)
  identity.nix           rpi.admin, rpi.ssh, rpi.deploy
  network.nix            rpi.network       — dhcp or static
  wifi.nix, bluetooth.nix  rpi.wifi, rpi.bluetooth — off by default
  sd-image.nix           the SD image as a build output of the Pi system
  sd-wear.nix            rpi.sdWear        — fewer SD writes, no firmware blobs
  headless.nix           rpi.headless      — config.txt without display/audio
  external-storage.nix   rpi.storage.external — optional USB data disk
  pull-update.nix        rpi.pull          — the rpi-pull timer and service, your cache as substituter
  profiles/terminal.nix  rpi.profiles.terminal — home-manager + nix-terminal (nixosModules.terminal)
  build-host.nix         NixOS module (host): aarch64 emulation, rpi-deploy
  build-host-home.nix    Home Manager module (host): rpi-deploy on the PATH only
hosts/neptun/          our example host: default.nix (its values), home.nix
templates/default/     what `nix flake init -t` copies: flake, hosts/rpi.nix, workflow, dependabot, devenv files, README
rpi-deploy.sh          rpi-deploy: image / flash / deploy / status / secrets (host)
rpi-pull.sh            rpi-pull: what the Pi's timer runs (pointer, verify, realise, switch or boot)
rpi-fp.sh              boot fingerprint, pure bash (rpi-deploy and rpi-pull share it)
rpi-lib.sh             guards, host discovery and ssh helpers (host; sources rpi-fp.sh)
ci/                    rpi-ci (package.nix, rpi-ci.sh) and its commands: hosts, build, publish, pointer, commit-push; gh.sh (annotations, summary)
deploy/neptun.json     neptun's pointer, written by CI (absent until a cache is set and CI ran)
secretspec.toml, devenv.local.nix.example
tests/                 unit tests, eval checks, drv-diff, personal-values, qemu smoke tests (see "Testing")
devenv.nix, devenv.yaml  local dev shell: rpi-deploy, cachix, lint tools, qemu, rpi-unit/rpi-check/rpi-doctor, git hooks
docs/superpowers/      specs and plans
```

### Notes

- Scratch files (`.nixcache/`, `result*`, `.scratch/`, `.worktrees/`) are
  gitignored and safe to delete. The maintainers keep a shell helper in
  `.scratch/` (`ci-env.sh`: cache directories, git identity, `chk`, `top`
  and the refactor-invariant functions); it is not part of the repository.
  `.rpi-build/` and `.rpi-build.log` are leftovers of the old install flow:
  delete them, then drop their two lines from `.gitignore`. A `nixos/`
  directory left over from before the move of the flake to the repo root holds
  only untracked caches and can be removed.
- The kit is headless by design: `clipboard = "osc52"` copies through the
  terminal's OSC 52 sequence, nothing X/Wayland-related is installed.
- The Pi has 1 GB RAM; the kit's optional heavy dev set is disabled
  (`packages.dev.enable = false`) in neptun's `home.nix`.
- Sandbox gotcha: the host's system `ssh_config` may include files that
  plain `ssh` rejects with `Bad owner or permissions`; use `ssh -F /dev/null`
  or your own config (the smoke tests do).
