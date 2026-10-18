# HANDOFF — Raspberry Pi 3 NixOS + `rpi-deploy`

> **Maintain this file.** Update it at the end of every work step: status,
> decisions, open problems, what was verified vs. assumed. A new session should
> be able to start from this file alone. Last updated: end of session 1
> (HEAD `9f59d77` plus uncommitted work, see "Uncommitted").

Legend: **[V]** verified by running it · **[M]** only verified against mocks /
unit tests · **[?]** assumption or guess, not verified.

---

## 1. Goal

Build a NixOS system for a **Raspberry Pi 3 B** (hostname `neptun`, aarch64) on
an **x86_64 NixOS host** (user `pallon`, LUKS nvme, card reader exposes the SD
card as `/dev/mmcblk0`, 28.9 GiB), then put it on an SD card with one script,
`rpi-deploy`, with good UX (prepare card, build without the card, install,
copy config, eject).

Hard constraints from the user:
- The kernel must NOT be compiled locally (a previous attempt ran 16 h under
  qemu and was stopped). Hence **nvmd/nixos-raspberrypi + its cachix cache**.
- Building must work without the card inserted.
- The old card content may be destroyed freely.

## 2. Repo layout (`/home/pallon/projects/raspberry-pi/nixos`)

| file | what |
|---|---|
| `flake.nix` | inputs (nixos-raspberrypi, nixpkgs *follows* it, home-manager master, nix-terminal), `nixosConfigurations.rpi` (+ alias `neptun`), host-test config, `packages.rpi-deploy`, `packages.x86_64-linux.rpi-binfmt`, checks |
| `configuration.nix` | the Pi system (U-Boot, labels, wifi via `secrets/wireless.env`, ssh on port 2222, networkd static ip, zram, ...) |
| `home.nix` | Home Manager for user `pi` |
| `rpi-deploy.sh` | the tool (~1130 lines bash). Packaged as `rpi-deploy` (flake package wraps PATH for card tools) |
| `tests/deploy-unit.sh` | 307 unit tests with mocked `nix`, `sudo`, `lsblk`, `chroot`, ... Run: `RPI_DEPLOY_SRC=$PWD/rpi-deploy.sh bash tests/deploy-unit.sh`; also as `nix build .#checks.x86_64-linux.rpi-deploy-unit` |
| `tests/build-host.nix`, `modules/build-host*.nix` | NixOS / Home-Manager module for "a host that can build aarch64" (binfmt, cache, wrapper) |
| `README.md` | user documentation (card layout, flow, cache/pins, notes) |
| `secrets/wireless.env` | gitignored, `MY_WIFI_PASSWORD=...` |
| `.rpi-build/last` | build record written by `rpi-deploy build` (gitignored) |

Git: commits are made **unsigned** (`--no-gpg-sign`), the sandbox cannot sign.

## 3. Architecture decisions taken

1. **nvmd/nixos-raspberrypi** instead of nixos-hardware: provides vendor kernel
   `linuxPackages_rpi3` prebuilt in `nixos-raspberrypi.cachix.org`, U-Boot,
   firmware, declarative `config.txt`. **[V]** kernel shows as "will be
   fetched" in `nix build --dry-run`; full system built in ~20 min.
2. **`nixpkgs.follows = "nixos-raspberrypi/nixpkgs"`** (nixos-26.05). Any other
   nixpkgs changes the kernel derivation hash → cache miss → 16 h build. Do not
   add `nixpkgs.url`. Update with `nix flake update nixos-raspberrypi`.
3. **Home Manager = master**, not release-26.05, because nix-terminal needs
   `programs.devenv`. Workarounds in `home.nix`: `enableNixpkgsReleaseCheck =
   false`, `programs.fzf.enableNushellIntegration = false`.
4. **Card layout (MBR, 2 partitions), by label:** p1 256 MiB FAT32
   `NIXOS_BOOT` → `/boot/firmware` (firmware, config.txt, U-Boot); p2 ext4
   `NIXOS_SD` → `/` (system, `/boot` with kernel/initrd/extlinux). 256 MiB is
   enough with U-Boot (firmware ≤ ~80 MB; kernels live on p2). Labels instead of
   fixed UUIDs (card is made on the host; duplicates are detected and refused).
5. **Build in host store, then copy** (`nix copy --no-check-sigs --to <mount>`),
   then `nixos-install --root <mount> --flake <checkout>#rpi` which should
   rebuild nothing (the script verifies the checkout still evaluates to the
   recorded derivation).
6. **Config copied to `<mount>/etc/nixos`** (tar, incl. `.git` and `secrets/`)
   because `nixos-install --flake` does not do it and the Pi needs
   `/etc/nixos/secrets/wireless.env`.
7. `rpi-deploy` subcommands: `prepare [DEVICE] [--format]`, `build`, `install`,
   `config`, `eject`, `all`, `show`, `devices`. `--dry-run`, `-y/--yes`.
   Positional TARGET (default `/media/nixos`) = `--mount`.
8. UX: asks before compiling the kernel locally, before installing without any
   ssh login, before installing a changed config; sudo password once up front +
   keepalive; every install step is idempotent / re-runnable.

## 4. Current status (what works / what does not)

- **[V]** `rpi-deploy build` works end to end (cache detected, kernel from
  cache, system recorded). Record: `sys=/nix/store/w0mmiy4f…-nixos-system-neptun-26.05.20260724.597283a`,
  `drv=…x2dq6h0m…`.
- **[V]** `rpi-deploy prepare` mounts the card by label at `/media/nixos` and
  `/media/nixos/boot/firmware` (user ran it). Formatting path **[M]** only.
- **[V]** The copy step is correct: on the card the profile link
  `/nix/var/nix/profiles/system -> system-1-link -> <recorded system>` exists,
  the system path and `sw/bin/bash` exist. I reproduced the copy +
  `nix build --store` in a scratch store as a normal user: identical system
  path, 1015 closure paths, `activate` present.
- **[V] BLOCKED: `nixos-install` fails in the chroot step.** Errors seen by the
  user, in order:
  1. `chroot: failed to run command '/nix/var/nix/profiles/system/activate': No such file or directory`
  2. after my symlink "bridge": `activate: line N: …/bin/mkdir: cannot execute: required file not found`
     (many programs) and again `chroot: failed to run command '…/sw/bin/bash'`.
- **Not yet reached / unverified:** bootloader install into `/boot/firmware`
  (U-Boot, config.txt), first boot of the Pi, wifi, ssh on port 2222.
  I cannot read the card's store from the sandbox, so I do not know what the
  half-finished `nixos-install` left on the card (re-running is safe).

## 5. The blocking problem — everything known

**Diagnosis [V for the registration, ? for the full mechanism].**
`nixos-install` runs the new system's `activate` and `switch-to-configuration
boot` through `nixos-enter`: `unshare --mount`, bind-mount /dev,/sys,/proc,
`chroot <root> …`. All those programs are **aarch64**, run on the x86 host via
qemu-user + binfmt_misc. The user's host registration, as reported by the
script's own read in the user's pasted output (I never saw the raw file;
`/proc/sys/fs/binfmt_misc` is unreadable from my sandbox): interpreter `/run/binfmt/aarch64-linux`, flags **`P`** (no `F`).
Without the `F` (fix-binary) flag the kernel resolves the interpreter path at
exec time *inside the chroot*, where `/run/binfmt/aarch64-linux` does not exist
→ "required file not found". With `F` the kernel opens the interpreter once at
registration, independent of chroot/namespace.

**What I tried:**
1. Detect missing F, **symlink** the host's interpreter into the card
   (`<mount>/run/binfmt/…`) and copy its store closure. **[V it was
   insufficient]**: the first exec worked, but programs spawned by activate and
   the later nixos-enter step still failed. **[?] I do not know why** (candidates:
   `nixos-enter` mounts a new tmpfs over `/run`? the interpreter is a
   dynamic/shell wrapper whose own dependencies are not resolvable in the
   chroot; the symlink was removed between steps — none of this was checked).
2. **Temporary F-flag handler** (commit `9f59d77`): build flake package
   `.#rpi-binfmt` (a registration line using nixpkgs' *static* qemu,
   `qemu-user-static-x86_64-unknown-linux-musl-10.2.4`), write it to
   `/proc/sys/fs/binfmt_misc/register`, test the chroot, remove it on exit.
   **[M]** logic and cleanup tested with mocks; **[V NOT]** never ran for real.

**The latest failure (this is a different problem):** step 2 never got to run:
`nix build .#rpi-binfmt` failed **[V]** because the ~102 MiB static qemu NAR
cannot be downloaded from cache.nixos.org on this machine/network:
`unable to download …13wjzqn6…nar.zst: HTTP error 206 (curl error: Failure when
receiving data from the peer)` — repeated with `download-attempts 30`, and also
earlier for the VM test (`ruff`, `qemu`). A plain `curl` of the first 2.5 MB
works (HTTP 200), nix then dies mid-stream and cannot resume. Other small/medium
downloads succeed. **[?]** Likely a flaky/throttled connection or proxy that cuts
long transfers (maybe HTTP/2 related). The script hid this: it printed only the
last line of nix output; **fixed (uncommitted)**: it now shows the nix output
tail and names the network cause.

**Things to try next (unverified):**
- Download the static qemu on a better connection, or with
  `--option http2 false --option http-connections 1 --option download-attempts 30`,
  or `curl -C - -O <nar url>` then import; then re-run `rpi-deploy install`.
- **Avoid the 100 MiB download:** register an F-flag handler pointing at the
  host's *existing* qemu (the interpreter behind `/run/binfmt/aarch64-linux`)
  and `nix copy` that interpreter's closure into the card store (it must run
  inside the chroot, whose `/nix/store` is the card's). Needs a look at what
  `/run/binfmt/aarch64-linux` actually is (shell wrapper? dynamic qemu?) —
  the sandbox cannot read `/run/binfmt` (permission denied).
- Host fix (also needs the same download): `boot.binfmt.preferStaticEmulators
  = true;` + `nixos-rebuild switch`. This is the clean, permanent fix and also
  what `modules/build-host.nix` sets (contract-checked).
- Get facts instead of guesses: run, as root on the host,
  `cat /proc/sys/fs/binfmt_misc/aarch64-linux; ls -l /run/binfmt/;
  file -L /run/binfmt/aarch64-linux` and `sudo nixos-enter --root /media/nixos
  -c 'ls -l /run/binfmt'` after the failure.

## 6. Architecture assessment (honest, for the follow-up discussion)

The user asked whether the script architecture is right or error-prone.
My view:

- **The flow is sound; the install step is the weak point.** build → copy →
  nixos-install is the standard cross-install pattern, and build/prepare/config
  are simple and mostly verified. The pain is concentrated in one thing: we run
  `nixos-install` **through qemu-user inside a chroot on a foreign architecture**.
  That is inherently fragile (binfmt flags, namespaces, interpreter lookup) and
  every workaround I added (bridge, temporary handler, chroot probe) is
  complexity around that one fragility.
- **Test coverage gives false confidence.** 307 unit tests mock `nix`, `sudo`,
  `chroot`, `lsblk`, `tee`. They verified logic and cleanup, but passed while the
  real install failed three times (duplicated `sfdisk`; the probe that accepted
  a bridge that did not really work; …). The real failures were all at the
  host/kernel boundary, which mocks cannot model. No integration test exists
  (the sandbox has no sudo/chroot/binfmt).
- **The script is large (1130 lines of bash) and mixes concerns:** card
  partitioning, mounting, building, emulation hacks, UX prompts, config copy.
  Good candidate to split or simplify.
- **Alternatives worth discussing [?, none prototyped]:**
  1. **Image-based flow:** `nix build` an SD image (nixos-raspberrypi supports
     `sd-image`/installer images; check its flake outputs) and `dd`/`zstdcat` it
     to the card. No `nixos-install`, no chroot, no binfmt-in-chroot; first boot
     expands the root partition. Re-flash = one command. Loses the
     "prepare/label/mount" machinery (replaced by a single flash step) and needs
     the config copy done on first boot or by mounting the card after flashing.
  2. **Skip the chroot:** do `nix copy` + create the system profile link +
     write `/etc/NIXOS` + run the U-Boot/firmware population **natively on the
     host** (the bootloader builder is a shell script; check whether it can run
     with host tools instead of via `switch-to-configuration` in a chroot).
  3. **Install on the Pi itself:** boot a stock nixos-raspberrypi installer
     image, then `nixos-rebuild switch --target-host`/`--build-host` from the
     workstation (the build is cached, activation runs natively on the Pi).
     Removes all emulation from the install path; costs a first stock boot.
  4. **Keep the current flow but fix the host once** (`preferStaticEmulators`)
     and delete the workaround code (bridge/temporary handler/probe), leaving a
     simple, honest precondition check.
- **Recommendation to evaluate in the follow-up:** prefer 1 (or 4 for the
  smallest change). Decide by: does the user want to keep `prepare`/format?
  how important is a re-flash in minutes? is a first boot on stock image OK?

## 7. Environment / sandbox gotchas (for whoever continues)

- The assistant's sandbox (nono): **no sudo**, cannot read the card's
  `/media/nixos/nix` or `/run/binfmt`, `rsync` fails even locally, cannot run
  `chroot`/write binfmt. Anything touching the card for real must be run by the
  user; ask for the *full* output (paste tails hide causes).
- Real tool facts: `read -p` prints no prompt without a tty; `sed -i` can leave
  stray temp files (`sedXXXX`) that break `git add -A`; `$@` and `$1` inside perl
  one-liners get eaten — use the Edit tool for multi-line source edits;
  `expect_grep` in the tests uses **basic** regex (`+` is literal);
  the nix sandbox has no `pgrep`/`pkill`.
- A flaky connection to cache.nixos.org (see §5) also made the VM check
  (`checks.x86_64-linux.rpi-host-vm`) fail twice for download reasons; it has
  never completed in this environment.
- `.nixcache/` (gitignored) was briefly touched by a repo-wide `sed`; reverted
  exactly, but if nix complains about the fetcher cache, delete `.nixcache/`.
- Pi config facts: ssh on port **2222**, user `pi`, key present in
  `configuration.nix`, static ip via networkd, wifi password file at
  `/etc/nixos/secrets/wireless.env` on the Pi.

## 8. Uncommitted at the time of writing

- `rpi-deploy.sh`: when building `.#rpi-binfmt` fails, show the nix output tail
  and the network hint (log in `.rpi-build/binfmt-build.log`).
- `tests/deploy-unit.sh`: tests for that (307 pass).
- `HANDOFF.md` (this file).

## 9. Suggested next steps

1. Decide the direction (§6) with the user before adding more workarounds.
2. If staying with `nixos-install`: get the static qemu (or the host fix), run
   `./rpi-deploy.sh install`, send the full output of any failure.
3. After a successful install: `./rpi-deploy.sh eject`, boot the Pi, check
   `ssh -p 2222 pi@<ip>`, wifi, then commit and update this file.
4. Remaining nice-to-haves: VM check never completed here; consider an
   integration test that does not need sudo (e.g. nixos VM test that runs
   `rpi-deploy` against a loop device).
