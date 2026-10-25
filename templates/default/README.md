# My Raspberry Pi 3

A Raspberry Pi 3 host on the [nix-raspi](https://github.com/GRBurst/nix-raspi)
library. Your values live in `hosts/rpi.nix`; everything else (NixOS base,
SD image, SSH, deploy tooling) comes from the library, locked in `flake.lock`.

## Quick start

1. Put your SSH public key into `rpi.admin.sshKeys` in `hosts/rpi.nix`
   (evaluation fails with `rpi.admin.sshKeys is empty` until you do), then
   `git init && git add -A` (a git flake only sees tracked files).
2. Build the SD image and write it to a card:

   ```sh
   nix run .#rpi-deploy -- image
   nix run .#rpi-deploy -- flash result-rpi-image/sd-image/*.img.zst /dev/sdX
   ```

3. Boot the Pi, find its address (DHCP) and push changes:

   ```sh
   RPI_TARGET=root@<address> nix run .#rpi-deploy -- deploy
   ```

   The target defaults to `root@<hostname>` (`rpi.deploy.target`).

The defaults: DHCP, SSH on port 22 (key-only), Wi-Fi and Bluetooth off,
hostname `rpi`. See `hosts/rpi.nix` for every option and the library's
[README](https://github.com/GRBurst/nix-raspi#readme) for the full table,
Wi-Fi, updates and caching.

## Operator shell (optional)

`devenv shell` (or direnv) gives you `rpi-deploy` of the locked library,
`cachix` and `secretspec`, with `RPI_FLAKE` pointing at this repository.
Settings for this machine only go into `devenv.local.nix` (gitignored; copy
`devenv.local.nix.example`): `RPI_HOST` (when you add a second Pi),
`RPI_TARGET` and `RPI_PORT` (override the host's deploy target and SSH port).

## Wi-Fi passwords

Wi-Fi is off by default. To turn it on, set `rpi.wifi.enable` and
`rpi.wifi.networks = { "My SSID" = "RPI_WIFI_HOME"; }` in `hosts/rpi.nix`
(SSID to variable name) and declare the variable in `secretspec.toml`.
The passwords never enter the Nix store (it is world-readable on the Pi and
goes to your cache). Keep them in a [SecretSpec](https://secretspec.dev)
provider (keyring, dotenv, 1Password, ...; `secretspec config init`) and hand
them to `rpi-deploy` for one command:

```sh
secretspec run -- rpi-deploy flash result-rpi-image/sd-image/*.img.zst /dev/sdX --wifi-env
secretspec run -- rpi-deploy secrets      # later, to the running Pi
```

That is inside `devenv shell` (or direnv), where `rpi-deploy` and `secretspec`
are on PATH. Outside it: `secretspec run -- nix run .#rpi-deploy -- secrets`
(`secretspec` from your profile, or `nix shell nixpkgs#secretspec`).

With the dotenv provider, quote values that contain spaces or `$` with single
quotes: `RPI_WIFI_HOME='my pass phrase'`. Without SecretSpec, `export
RPI_WIFI_HOME=...` before the command works as well.

## Updates and trust

CI (`.github/workflows/pi.yml`) updates nixpkgs and nixos-raspberrypi every
week (in `flake.lock` they are the library's inputs `rpi/nixpkgs` and
`rpi/nixos-raspberrypi`), builds, and with a cache publishes to your Pi. The
library itself (`rpi`: modules, `rpi-pull`, `rpi-ci`) never moves on its own:
dispatch the workflow with `update-library` ticked, or run
`nix flake update rpi` and push. Read what changed in the library first:
whoever can push to it is root on your Pi once you take that update (your CI
builds and signs it). The CI steps that hold your Cachix secrets run the
`rpi-ci` of your committed lock, never a freshly updated one.

`nix flake update rpi` also resets nixpkgs and nixos-raspberrypi to the
library's lock (what its CI built); `nix flake update` moves everything,
the library included. To pin the library, set
`inputs.rpi.url = "github:GRBurst/nix-raspi/<tag or revision>"`.
