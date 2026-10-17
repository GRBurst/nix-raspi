# rpi — Raspberry Pi 3 Model B (V1.2) NixOS flake + build host

Headless NixOS system (no graphics server) for a Raspberry Pi 3 Model B V1.2,
plus everything needed on the x86_64 build host: a NixOS / Home Manager module
for aarch64 emulation and the `rpi-install` script that builds the system from
a checkout and installs it onto an SD card.

- Hostname `neptun`, system `aarch64-linux`, NixOS 26.11 (nixos-unstable).
- Hardware module: `nixos-hardware` `raspberry-pi-3`. Its custom `linux-rpi`
  kernel (vendor defconfig) is used; see the build notes below — it compiles
  locally, once per kernel pin.
- User `pi` (wheel, docker, video groups), login shell zsh.
- User environment: the [nix-terminal](https://github.com/grburst/nix-terminal)
  kit (zsh + nvim + yazi, terminal theme, OSC 52 clipboard — no display
  server required) plus tools: btop, atop, wget, curl, git, tig, netcat,
  nmap, psmisc, tree, ncdu.
- SSH only: port 2222, key authentication (no password auth).
- `system.autoUpgrade` runs daily at 03:30.
- 512 MiB zram swap (see "Client evaluation").

## Repo layout

```
flake.nix           pi system config + build-host outputs
configuration.nix   the pi NixOS config
home.nix            the pi home-manager config
modules/
  build-host.nix        NixOS module: aarch64 build host (rpi.buildHost)
  build-host-home.nix   Home Manager module: rpi-install on the PATH
tests/build-host.nix    x86_64 test system for the build-host module
install.sh          rpi-install: build / install / show / all
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
    # optional: pre-sets RPI_FLAKE so `rpi-install` needs no --flake
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
- `rpi-install` on the PATH (in `environment.systemPackages`), optionally
  wrapped so `RPI_FLAKE` is preset.

Verify with:

```sh
nix build .#nixosConfigurations.rpiBuildHostTest.config.system.build.toplevel  # module test system
rpi-install show                                                                # preflight overview
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
configuration or graphics problem). `rpi-install build` refuses to start in
that case.

## Building and installing

The SD card is only needed at install time. `build` runs entirely from a
local checkout of this repo, so the pi can keep running (card not mounted)
while the build happens — including the multi-hour kernel build.

```sh
rpi-install build                  # build from the checkout, record the result
rpi-install show                   # last build record + emulation preflight
# ... later, with the card mounted at /media/nixos:
rpi-install install                # install the recorded build (minutes)
rpi-install install /media/nixos   # same, with an explicit target system root
rpi-install all                    # build + install in one go (old behaviour)
```

Usage: `rpi-install [build|install|all|show] [TARGET] [OPTIONS]`. `TARGET` is the
root of the target NixOS system (default `/media/nixos`; same as `--mount`).

Options: `--flake PATH` (default `$RPI_FLAKE` or `$PWD`), `--mount DIR`
(default `/media/nixos`), `--attr NAME` (default `rpi`), `--from STOREPATH`
(install a specific system), `--dry-run`.

`build` writes a record to `<checkout>/.rpi-build/last` (gitignored):

```
flake=...  attr=rpi  rev=<git HEAD>  dirty=clean|dirty  sys=<store path>  drv=<drv path>  built=<utc>
```

`install` then:

1. copies the recorded system + toplevel drv into the card's store
   (`sudo nix copy --no-check-sigs --to <mount>`),
2. runs `sudo nixos-install --root <mount> --flake <checkout>#rpi` — pointed at
   the **host checkout**, so the evaluation matches the recorded build
   bit-for-bit and **nothing is rebuilt**,
3. verifies the paths exist in the target store.

The record carries the git revision; if the checkout HEAD or the working tree
has changed since the build, `install` warns that the target may rebuild.

> **Why not just `nixos-install`?** It does not build in the host store: it
> compiles the whole closure (kernel included) directly into the card's
> `/nix/store`, as root, with build temp files on the SD. That is slow, wears
> the card, and repeats in full after every re-flash. Building in the host
> store once and copying over makes re-flashing a matter of minutes.

### What the build does, in detail

Everything is fetched from `cache.nixos.org` **except the kernel**: nixpkgs
no longer builds Raspberry Pi kernels ("linux-rpi series has been removed,
please change to use nixos-hardware"), so the `nixos-hardware` `linux-rpi`
kernel is compiled locally, under qemu user-mode emulation — expect several
hours (observed: ~8 h on a 16-core x86_64 host; the nixos-hardware defconfig
is very large), once per kernel pin. A `nixos-hardware` update rotates the
pin and triggers another one-time build; until then, repeated builds are fast
(host `/nix/store` cache).

## Pi (client) configuration

Notes on the client side, evaluated and applied:

- **Deprecated options fixed** (nixos-unstable 26.11):
  `boot.cleanTmpDir` → `boot.tmp.cleanOnBoot`, `nix.maxJobs`/`nix.buildCores`
  → `nix.settings.max-jobs`/`cores`, `nix.daemonIONiceLevel` →
  `nix.daemonIOSchedPriority`, `services.openssh.{permitRootLogin,
  passwordAuthentication}` → `services.openssh.settings.*`,
  `networking.wireless.userControlled.enable` → `userControlled`,
  `i18n.consoleKeyMap` → `console.keyMap`. The build log is now free of
  "Obsolete option" warnings.
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
  `nixos-hardware` would try to build the kernel on the 1 GiB pi. Keep
  hardware/kernel pins moving from the build host (or accept occasional
  failed autoUpgrades — the pi then just runs the old system).
- **Deploy key**: `users.users.pi.openssh.authorizedKeys.keys` is empty; add
  the host's public key to enable the remote-install follow-up below.

## Follow-up: remote install (no card mount)

Possible once a deploy key is in place: run
`nixos-rebuild build --flake <host-checkout>#rpi` on the host and push the
result to the pi over SSH (`nix copy --to` + `nixos-rebuild switch --flake`
with the store pre-populated, or `devenv`/`deploy-rs`). Not implemented here;
the current `rpi-install install` flow is the card-based baseline that it
replaces.

## Testing

Three layers, all wired into `nix flake check`:

```sh
nix flake check                                   # everything below
nix build .#checks.x86_64-linux.rpi-install-unit  # 59 unit tests for install.sh
nix build .#checks.x86_64-linux.rpi-host-vm       # boots a real VM (qemu), ~1-16 min
nix build .#nixosConfigurations.rpiBuildHostTest.config.system.build.toplevel  # host module, eval-only proof
```

1. **`rpi-install-syntax`** (both systems) — `bash -n` of the script.
2. **`rpi-install-unit`** (`tests/install-unit.sh`, x86_64) — 59 unit tests
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
   under emulation, the installed `rpi-install` is the `RPI_FLAKE` wrapper
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
nix build .#packages.x86_64-linux.rpi-install     # the script as a package
```

## Notes

- Scratch files used while building (`.nixcache/`, `result`,
  `.rpi-build.log`, `.rpi-build/`) are gitignored and safe to delete; they
  only speed up re-evaluation.
- The kit is headless by design: `clipboard = "osc52"` copies through the
  terminal's OSC 52 sequence, so nothing X/Wayland-related is installed.
- The Pi has 1 GB RAM; the kit's optional heavy dev set is disabled
  (`packages.dev.enable = false`).
