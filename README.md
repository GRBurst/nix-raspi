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

### Quick path: `./install.sh`

```sh
sudo mkdir -p /media/nixos && sudo mount /dev/sdXn /media/nixos   # mount the SD root partition
cd /media/nixos/etc/nixos
tmux new -s rpi   # the first build takes hours — don't let a closed terminal kill it
./install.sh            # add --mount DIR if the card is mounted elsewhere
```

`install.sh` (run as a regular user; it re-execs under sudo only where
needed, so the build never runs as root) does, in order:

1. **Preflight** — checks the flake location, active aarch64 binfmt/qemu
   emulation, and the sandbox `extra-sandbox-paths`, with actionable errors
   instead of obscure 255s.
2. **Build** the system in the **host store** (`nix build
   .#nixosConfigurations.rpi.config.system.build.toplevel`). On failure it
   prints the relevant log tail plus hints for the known failure modes.
3. **Copy** the built closure (system path + toplevel drv + flake sources)
   onto the card: `nix copy --from /nix --to <mount>`.
4. **Install**: `sudo nixos-install --root <mount> --flake <mount>/etc/nixos#rpi`
   — with the target store pre-populated, no cross builds happen here.
5. **Verify** the result (`etc/NIXOS`, store path count, `boot/kernel8.img`).

The script is idempotent — re-run it after config changes; the build step is
a fast no-op when nothing changed.

> **Why not just `nixos-install`?** It does not build in the host store: it
> runs `nix build ... --store <mount>`, i.e. it compiles the whole closure
> (kernel included) directly into the card's `/nix/store`, as root, with build
> temp files on the SD. That is slow, wears the card, and repeats in full
> after every re-flash. Building in the host store once and copying over
> makes re-flashing a matter of minutes.

### What the build does, in detail

Everything is fetched from `cache.nixos.org` **except the kernel**: nixpkgs
no longer builds Raspberry Pi kernels ("linux-rpi series has been removed,
please change to use nixos-hardware"), so the `nixos-hardware` `linux-rpi`
kernel is compiled locally, under qemu user-mode emulation — expect several
hours (observed: ~8 h on a 16-core x86_64 host; the nixos-hardware defconfig
is very large), once per kernel pin. A `nixos-hardware` update rotates the
pin and triggers another one-time build; until then, repeated builds are fast
(host `/nix/store` cache).

### Manual equivalent (for troubleshooting)

1. Build in the host store:

   ```sh
   cd /media/nixos/etc/nixos
   nix build .#nixosConfigurations.rpi.config.system.build.toplevel --print-build-logs 2>&1 | tee .rpi-build.log
   ```

2. Copy the closure **and the toplevel drv** (the drv pulls the flake
   sources into the target store, so the install doesn't re-fetch them):

   ```sh
   sys=$(nix build .#nixosConfigurations.rpi.config.system.build.toplevel --print-out-paths)
   drv=$(nix eval --raw .#nixosConfigurations.rpi.config.system.build.toplevel.drvPath)
   sudo nix copy --from /nix --to /media/nixos "$sys" "$drv"
   ```

3. Install (no cross builds happen):

   ```sh
   sudo nixos-install --root /media/nixos --flake /media/nixos/etc/nixos#rpi
   ```

4. Boot the Pi and sanity-check:

   ```sh
   ssh -p 2222 pi@<pi-address>   # zsh + nix-terminal prompt
   ```

   Commit the flake once that works, so the commit records what is installed
   (`nixos-install --flake` builds from the **working tree**, not the commit —
   the `Git tree is dirty` warning refers to that).

### Notes

- Scratch files used while building (`/media/nixos/etc/nixos/.nixcache/`,
  `result`, build logs) are gitignored and safe to delete; they only speed up
  re-evaluation.
- The kit is headless by design: `clipboard = "osc52"` copies through the
  terminal's OSC 52 sequence, so nothing X/Wayland-related is installed.
- The Pi has 1 GB RAM; the kit's optional heavy dev set is disabled
  (`packages.dev.enable = false`).
