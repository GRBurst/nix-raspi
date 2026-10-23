# HANDOFF — Raspberry Pi 3 NixOS: build here, flash once, push updates

> **Maintain this file.** Update it at the end of every work step: status,
> decisions, open problems, what was verified vs. assumed. A new session should
> be able to start from this file alone.
> Last updated: milestone M7 (final acceptance). Full docs: `README.md`.
> Spec: `docs/superpowers/specs/2026-10-19-image-push-deploy-design.md`.
> Plan: `docs/superpowers/plans/2026-10-19-image-push-deploy.md`.

Legend: **[V]** verified by running it · **[M]** verified against mocks / unit
tests / eval only · **[?]** assumption, not verified (needs the real Pi).

---

## 1. Goal

One NixOS configuration (`nixosConfigurations.rpi`, alias `neptun`) yields both
the SD image for the Raspberry Pi 3B "neptun" (flashed once) and every later
push deploy from the x86_64 NixOS host "andromeda". A weekly host timer pushes
security updates without ever compiling a kernel and leaves the Pi untouched
when anything goes wrong. Hard constraints: the kernel is never built locally
(nvmd's cachix), the Pi never evaluates the flake (1 GiB RAM), no chroot and no
binfmt tricks during install.

## 2. Status

All milestones are implemented on branches `feat/m1` … `feat/m7`, merged
through `feat/image-push-deploy` (commits are unsigned: re-sign when merging).

| milestone | content | state |
|---|---|---|
| M1 | hybrid inputs (own nixpkgs 26.05, nvmd `develop`), `rpi` builds its own `sdImage`, kernel check | done, **[V]** |
| M2 | `configuration.nix`: key-only root, `keys.nix`, removals (autoUpgrade, wifi, secrets), extlinux limit 5, GC | done, **[M]** eval checks |
| M3 | `rpi.sdWear`, `rpi.headless` | done, **[M]** eval checks; effect on hardware **[?]** |
| M4 | `rpi.storage.external` (off by default) | done, **[M]** eval checks; real disk **[?]** |
| M5 | `rpi-deploy` rewrite (`image`, `flash`, `deploy`, `status`), `rpi-lib.sh`, pinned `nixos-rebuild` | done, **[M]** unit tests; guards also run live **[V]** |
| M6 | build-host cleanup, `rpi.buildHost.autoUpdate`, `rpi-autoupdate` | done, **[M]** unit tests + NixOS VM |
| M7 | smoke tests (`qemu-pi.sh`, `boot-smoke.sh`, `deploy-smoke.sh`), docs, final acceptance | done, results below |

### Acceptance (spec §8)

Run on the M7 tree (2026-10-23, andromeda). Logs: `nixos/.scratch/m7/` (untracked),
details in `nixos/.scratch/m7/REPORT.md`.

| # | criterion | result | evidence |
|---|---|---|---|
| 1 | `nix flake check` | **[V] pass**, rc 0, 97 s on the committed tree, all checks built fresh (12 x86_64 checks: `rpi-deploy-syntax`, `rpi-deploy-unit` 204 assertions, `autoupdate-unit` 126, `rpi-host-vm`, 8 × `eval-*` with 91 assertions). An earlier run on the dirty tree (78 s) and `nix build --rebuild` of each check also passed. | `flake-check-final.log`, `flake-check.log`, `rebuild-*.log` |
| 2 | `rpi-deploy image` builds without a kernel compile; boots in boot-smoke with SSH | **[V] pass**. Cold image build 2011 s (379 local builds, guards passed, 0 builds of `linux_rpi-*`/`linux-config-*`), 1.28 GiB zst / 4.18 GiB raw. boot-smoke: expansion after 85–135 s, `SSH-2.0-OpenSSH_10.5` on the usb-net forward 85 s later, screenshot shows `neptun login:`. Planted `RPI_SMOKE_GUEST_SSH_PORT=2223` → `FAIL: no SSH banner`. The refactor onto `qemu-pi.sh` is output-identical to the old script (diff of the `==>/PASS/FAIL` lines empty). | `image.log`, `smoke-before.log`, `smoke-after.log`, `smoke-ssh-green.log`, `smoke-ssh-red.log`, `smoke-final.log`, `smoke-after/shot.png` |
| 3 | closure ≤ 3.3 GiB | **[V] pass: 3,376,732,952 B = 3.144 GiB** (limit 3,543,348,019 B; was 3.97 GiB). 1006 paths; no `linux-firmware`. | `closure.json` |
| 4 | `rpi-deploy deploy switch` applies a change in qemu | **[V] pass** (`tests/deploy-smoke.sh`, 908 s total with the image cached): marker `/etc/rpi-smoke-marker` = `next`, `/run/current-system` = smoke-next's toplevel, `rpi-deploy status` → `reboot pending: no`, and `nixos-rebuild switch --rollback --target-host` restores the image's system (README's rollback command). Deploy phases: guards 23 s, build+copy 43 s, FAT firmware copy 137 s, extlinux 6 s, activation 56 s (276 s). Planted marker `wrong` → `FAIL: marker: expected 'wrong', the guest says 'next'`. | `deploy-smoke-green.log`, `deploy-smoke-red.log`, `ds-green/deploy-*.log` |
| 5 | `rpi-autoupdate --no-deploy` | **[V] pass** against a temp clone (the real repo untouched: same refs and status): with `nixpkgs` pinned to an older nixos-26.05 rev on the clone's `main`, the run updated it to `da6dc0e7b2`, passed both guards, built, deployed nothing, force-pushed `auto-update` (`auto-update: flake.lock 2026-10-23`, author `rpi-autoupdate`); `main` and the clone's worktree unchanged. With the real lock the job correctly did nothing (upstream heads equal the locked revs). | `au/run.log`, `au/*.before*` |
| 6 | real hardware | **open, manual**: checklist in section 5 | |

Findings during acceptance (not fixed, outside M7's files):

- `rl_nixos_rebuild` (rpi-lib.sh, M5) does not pass `--accept-flake-config`:
  nixos-rebuild's own `nix build` then asks about (or, in a sandbox with a
  read-only `~/.local/share/nix`, fails on) the flake's `nixConfig`. `deploy-smoke.sh`
  works around it with `NIX_CONFIG='accept-flake-config = true'`. On the real
  host the nvmd cache is in `nix.conf` (`rpi.buildHost`), so only the prompt remains;
  adding `--accept-flake-config` to the nixos-rebuild argv would make the tool
  consistent with its guards.
- qemu's sdhost model reads synchronously: a stalled host shows up as `PIO read
  timeout` / `EXT4-fs error` in the guest (seen once in 7 runs of
  deploy-smoke while other heavy jobs ran on the host). `deploy-smoke.sh` prints a note
  when it sees that; re-run on an idle host.
- After the first boot every ssh connection crawls under TCG for ~5 min
  (store registration, resize); `deploy-smoke.sh` waits for `is-system-running`.
  `degraded` with only `session-1.scope` failed is the script's own killed
  login attempt, not a fault.


## 3. Decisions (short; the full table is plan §3)

- **Image flow, not `nixos-install`.** The old flow (nixos-install in a chroot
  through qemu-user and binfmt F flags) failed at the host/kernel boundary three
  times and could not be tested. The image is a build output of `rpi` itself
  (`modules/sd-image.nix`), flashed with `dd`; later changes are pushed with
  `nixos-rebuild --target-host` (native activation on the Pi).
- **Hybrid inputs.** `nixos-raspberrypi` (`develop`, own nixpkgs pin) gives the
  cached kernel/firmware; our `nixpkgs` (`nixos-26.05`) drives userspace. No
  `follows` between them (checked by `eval-kernel`, plan P1/P2). Guards: kernel
  and modules must be in nvmd's cachix, the dry run must not list a
  kernel/linux-config/gcc/llvm/rustc/ghc/nodejs build, ≤ 500 local builds.
- **Pinned deploy tool.** The flake exposes nixos-rebuild-ng 26.05; the host's
  newer one half-applies (`systemd-run --output=cat`, E3). Always `--no-reexec`.
- **Access.** `PermitRootLogin = prohibit-password`, root gets the user key plus
  the auto-update key with `from="192.168.100.115"`; `pi` has no password and
  `wheelNeedsPassword = false` (flagged for review, spec §10).
- **Auto-update branch.** The job force-pushes `main` + one lock commit to
  `auto-update`; unsigned commits (`rpi-autoupdate`); the user merges. The job
  deploys `main` + lock, so manual deploys of unmerged branches are replaced by
  the next weekly run (README section 4).
- **`flash` accepts `mmcblkN` with `RM=0`** (Linux never sets the removable flag
  on MMC; the user's reader is `/dev/mmcblk0`); root-disk, mounted, partition
  and typed-confirmation checks still apply. One line in `rpi-deploy.sh`
  (`flash_check_device`) if you want it stricter.
- **Deploy to the real Pi = re-flash** (the installed Pi allows neither root nor
  passwordless sudo).
- **Rejected**: cross-compilation, nixos-anywhere (no kexec on Pi kernels),
  systemd-repart, on-Pi updates (autoUpgrade, comin: eval RAM), deploy-rs,
  cachix-deploy, nvmd `main` (kernels only at releases), trimming nix-terminal,
  f2fs/btrfs root, `discard`, `auto-optimise-store`, `fsync-metadata=false`.

## 4. What to do next (user)

1. **Hardware acceptance (AC6), checklist below.** Nothing in the repo can
   replace it: U-Boot, the GPU firmware, a real card and the LAN are outside
   qemu.
2. **Auto-update key**: `ssh-keygen -t ed25519 -N '' -C rpi-autoupdate@andromeda -f ~/.ssh/rpi-autoupdate`,
   paste the `.pub` into `nixos/keys.nix` (`autoUpdate`), add the `Host neptun`
   entry to `~/.ssh/config` (`HostName 192.168.100.20`, `Port 2222`), enable
   `rpi.buildHost.autoUpdate` (README section 4).
3. **Merge**: the milestone branches (unsigned commits: re-sign), then
   `auto-update` whenever the job pushed one.
4. **Local leftovers**: `.rpi-build/` and `.rpi-build.log` at the repo root are
   artifacts of the old flow; delete them and drop their two `.gitignore` lines.
5. **Review flags**: `wheelNeedsPassword = false` for `pi`; `hardware.enableAllHardware`
   kept for parity with the E3-tested image (initrd carries every module);
   closure/size numbers in the acceptance table.

## 5. Hardware acceptance checklist (AC6, manual, ~1 h)

Needs the Pi, a card ≥ 8 GiB, the LAN cable, ideally a 3.3 V USB-UART on GPIO
14/15. Tick in this file when done and note surprises.

- [ ] `rpi-deploy image` then `rpi-deploy flash <image> /dev/<card>`: the typed
      confirmation is asked, the read-back prints `verified: … sha256 …`.
- [ ] Boot the Pi. Within ~2 min: `ssh -p 2222 root@neptun true` **and**
      `ssh -p 2222 pi@neptun true` work with your key (neither has a password).
      `ssh-keygen -R '[192.168.100.20]:2222'` first if the old Pi's key is cached.
- [ ] Headless config.txt took effect: `vcgencmd get_mem gpu` → `gpu=16M`;
      `dmesg | grep -i -E 'brcmfmac|hci_uart'` is empty; the serial console
      (GPIO UART, 115200 8N1) shows kernel messages and a login prompt.
- [ ] Root fs expanded to the card (`df -h /`), `findmnt /` shows
      `noatime,lazytime,commit=60`, `/tmp` is tmpfs, `free -m` shows 512 MiB zram.
- [ ] `rpi-deploy status` → `reboot pending: no`.
- [ ] `rpi-deploy deploy switch` with a one-line change (e.g. an
      `environment.etc` marker): applies in a few minutes (qemu: 276 s), `status` still `reboot pending: no`.
- [ ] `rpi-deploy deploy boot` with a boot-affecting change (e.g.
      `boot.kernelParams = [ "rpi_marker=1" ]`), then `ssh -p 2222 root@neptun reboot`.
      After the reboot `cat /proc/cmdline` contains `rpi_marker=1` (U-Boot read
      the new extlinux entry: the part qemu cannot show). Before the reboot
      `rpi-deploy status` says `reboot pending: yes (the boot default is not the
      running system; changed since boot: kernel-params)`, after it `no`.
- [ ] Reboot-pending detection (optional): `rpi-deploy deploy switch` with an
      initrd change (e.g. `boot.initrd.supportedFilesystems = [ "btrfs" ]`) →
      `status` says `reboot pending: yes`; after a reboot → `no`.
- [ ] Rollback: `NIX_SSHOPTS='-p 2222' nix run .#nixos-rebuild -- switch --rollback --no-reexec --target-host root@neptun`
      returns to the previous generation (verified in qemu by `deploy-smoke.sh`).
- [ ] Recovery drill (recommended once, with the serial console): reboot, stop
      U-Boot's countdown, boot an older `nixos-N-default` entry; or edit `DEFAULT`
      in `/boot/extlinux/extlinux.conf` on the card from the host (README section 5).
- [ ] Optional write-volume measurement (s6 §6): `cat /sys/block/mmcblk0/stat`
      before/after a day of idling.
- [ ] Weekly job once by hand: `sudo systemctl start rpi-autoupdate`, watch
      `journalctl -fu rpi-autoupdate`; after a kernel change expect
      `shutdown -r 04:30` on the Pi (`ssh … shutdown -c` cancels it), check
      `git log -1 auto-update`.
- [ ] External disk (only when you want it): README section 6.

Recovery if the new kernel or firmware does not boot: README section 5 (serial menu,
`DEFAULT` edit in `/boot/extlinux/extlinux.conf` from the host, or restoring
NIXOS_BOOT from the host).

## 6. Environment and sandbox gotchas

- The agent sandbox has **no sudo**, cannot flash devices, must never ssh to
  the real Pi (192.168.100.20). Commits need `--no-gpg-sign`.
- Env for nix: `export XDG_CACHE_HOME=<repo>/nixos/.cache-nix NIXPKGS_CONFIG=<repo>/nixos/.nixcache/nixpkgs-config.nix`,
  `--accept-flake-config`. `/tmp` is not writable for some paths; scratch goes
  to `nixos/.scratch/` (gitignored).
- New files are invisible to the flake until `git add` (flake source is `git+file`).
- `nix flake check --no-build` may need a prior
  `nix eval --raw .#nixosConfigurations.rpi.config.system.build.toplevel.drvPath`
  (yazi IFD).
- `cache.nixos.org` drops long transfers on this network (curl rc 56 after
  ~60 MB): retry with `--option download-attempts 10`, or mirror the NARs into
  a local `file://` binary cache (`.scratch/m1/fetch-nars.sh`).
- The host's system `ssh_config` includes files plain `ssh` rejects in the
  sandbox (`Bad owner or permissions`): use `ssh -F /dev/null` (the smoke tests do).
- qemu raspi3b is ~5x slower than a real Pi 3 (TCG); usb-net works with the
  vendor kernel (`cdc_ether`, harmless `usbnet: failed control transaction`
  lines). Direct kernel boot skips U-Boot and the GPU firmware.
- Bash test gotchas: the nix sandbox has no `pgrep`/`pkill`; stdenv *sources*
  every file in `nativeBuildInputs` (scripts must come in as `src`).

## 7. History

Sessions 1–2 built a 1130-line `rpi-deploy` (`prepare`/`build`/`install`) around
`nixos-install` in a chroot; three real failures at the binfmt/chroot boundary
and an image-flow spike (qemu boot-smoke reached the login prompt; closure
3.97 GiB, image 2.07 GiB zst) led to the decision in section 3. The old
README/HANDOFF text is in git history (before the M7 commit). Experiment
reports (untracked, `nixos/.scratch/`): `e2` (native vs cross), `e3`
(flash once + `nixos-rebuild --target-host` in qemu), `s5` (hybrid inputs),
`s6` (SD wear), `m1`–`m7` (milestone reports).
