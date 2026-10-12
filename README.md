# rpi — Raspberry Pi 3 Model B (V1.2) NixOS flake

Headless NixOS system (no graphics server) for a Raspberry Pi 3 Model B V1.2.

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

## Building / installing from a different host (x86_64)

The system is `aarch64-linux`, so all builds run under qemu. **The build host
must have aarch64 emulation enabled** — on NixOS:

```nix
boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
```

Without it, every aarch64 derivation fails with
`builder failed with exit code 255` (that is an emulation problem, not a
configuration or graphics problem).

### Steps

1. Mount the SD card (standard NixOS layout: FAT/ESP boot partition + ext4
   root partition containing this flake under `etc/nixos`):

   ```sh
   sudo mkdir -p /media/nixos && sudo mount /dev/sdXn /media/nixos
   ```

2. Commit any configuration changes first — `nixos-install --flake` builds
   from the **working tree**, not the commit (the `Git tree is dirty` warning
   refers to that), so the commit should record what you are installing.

3. (Recommended) Build the system closure first, so the long part happens
   before the install and can be resumed/retried independently:

   ```sh
   nix build /media/nixos/etc/nixos#nixosConfigurations.rpi.config.system.build.toplevel
   ```

   Everything is fetched from `cache.nixos.org` **except the kernel**: nixpkgs
   no longer builds Raspberry Pi kernels ("linux-rpi series has been removed,
   please change to use nixos-hardware"), so the `nixos-hardware`
   `linux-rpi` kernel is compiled locally, under qemu user-mode emulation —
   expect several hours (observed: ~8 h on a 16-core x86_64 host; the
   nixos-hardware defconfig is very large), once per kernel pin. A
   `nixos-hardware` update rotates the pin and triggers another one-time
   build; until then, repeated builds are fast (host `/nix/store` cache).

4. Install (reuses step 3's results; only final assembly remains):

   ```sh
   sudo nixos-install --root /media/nixos --flake /media/nixos/etc/nixos#rpi
   ```

5. Boot the Pi and sanity-check:

   ```sh
   ssh -p 2222 pi@<pi-address>   # zsh + nix-terminal prompt
   sudo nixos-rebuild switch     # only if the flake changed after the install
   ```

### Notes

- Scratch files used while building (`/media/nixos/etc/nixos/.nixcache/`,
  `result`, build logs) are gitignored and safe to delete; they only speed up
  re-evaluation.
- The kit is headless by design: `clipboard = "osc52"` copies through the
  terminal's OSC 52 sequence, so nothing X/Wayland-related is installed.
- The Pi has 1 GB RAM; the kit's optional heavy dev set is disabled
  (`packages.dev.enable = false`).
