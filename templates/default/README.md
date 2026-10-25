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
   nix run .#rpi-deploy -- flash <the image path printed above> /dev/sdX
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

## Updating the library

`nix flake update rpi` moves the library and its locked nixpkgs and nvmd
inputs; `nix flake update` moves everything.
