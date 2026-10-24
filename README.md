# rpi — Raspberry Pi 3 Model B (V1.2) NixOS: build here, flash once, CI builds, the Pi pulls

Headless NixOS system (no display server) for a Raspberry Pi 3 Model B V1.2
(hostname `neptun`, `aarch64-linux`, 1 GiB RAM, SD card, wired LAN only), plus
everything the x86_64 NixOS build host needs for it (aarch64 emulation and the
`rpi-deploy` tool). Security updates are built by GitHub Actions and pulled by
the Pi itself, so they arrive without the host being on.

```
host (x86_64, binfmt aarch64, caches)                Pi 3B (aarch64)
 flake nixos/  ──eval+build──► toplevel ──┬─ image ─► .img.zst ─flash─► SD (once)
                                          └─ push ─► nixos-rebuild 26.05 --target-host root@neptun   (manual)

GitHub Actions (arm64): cron | push to main | manual
 └─ [cron] lock update ─ guard ─ build toplevel ─► our Cachix cache (self-signed) + pin
 └─ pointer nixos/deploy/neptun.json ─ commit to main
                                   │ HTTPS (raw.githubusercontent.com)
Pi: rpi-pull.timer (daily 05:00): fetch pointer ─ verify ─ realise ─ narHash ─ switch | boot+reboot at 04:30
```

- **One definition.** `nixosConfigurations.rpi` (alias `neptun`) is both the
  flashed image (`config.system.build.sdImage`) and every later update, manual
  or from CI.
- **The Pi never evaluates the flake** (eval needs ~1.08 GB RSS). No
  `/etc/nixos`, no `autoUpgrade`, no wifi secrets. The system is built on the
  host (pushed over SSH) or by CI (pulled as a prebuilt closure, section 4).
- **No local kernel build, ever.** The vendor kernel comes prebuilt from the
  [nvmd/nixos-raspberrypi](https://github.com/nvmd/nixos-raspberrypi) cachix;
  `rpi-deploy` and the CI build refuse to run when that cannot hold.
- NixOS 26.05, user `pi` (wheel, login shell zsh from the
  [nix-terminal](https://github.com/grburst/nix-terminal) kit), SSH on port
  **2222**, key-only for `pi` and `root`, static IP `192.168.100.20/24`.
- Fewer SD writes (`rpi.sdWear`: no firmware blobs, relaxed ext4 write-back,
  volatile journal, tmpfs `/tmp`), headless `config.txt` (`rpi.headless`),
  optional USB data disk (`rpi.storage.external`, off by default).
- Design: `docs/superpowers/specs/2026-10-19-image-push-deploy-design.md` and
  the addendum `docs/superpowers/specs/2026-10-23-ci-pull-updates-design.md`
  (CI builds, the Pi pulls; replaces the host's auto-update); plans:
  `docs/superpowers/plans/2026-10-19-image-push-deploy.md` and
  `docs/superpowers/plans/2026-10-23-ci-pull-updates.md`; status and hardware
  checklist: `HANDOFF.md`.

## Repo layout

```
.github/
  workflows/neptun.yml CI: build the Pi system, push it to our cache, commit the pointer (main only)
  dependabot.yml       weekly PRs that bump the workflow's commit-SHA action pins
nixos/
  flake.nix            Pi system, build-host modules, rpi-deploy package, apps, checks
  flake.lock           pins: our nixpkgs + nvmd (develop) + home-manager + ...
  configuration.nix    the Pi NixOS config (incl. the pointer URL of rpi.pull)
  keys.nix             ssh public key of the user; `cache`: our Cachix cache (name, public key), null until set
  home.nix             Home Manager config of user `pi`
  modules/
    sd-image.nix         the SD image as a build output of the Pi system
    sd-wear.nix          rpi.sdWear      — fewer SD writes, no firmware blobs
    headless.nix         rpi.headless    — config.txt without display/audio/wifi/bt
    external-storage.nix rpi.storage.external — optional USB data disk
    pull-update.nix      rpi.pull        — the rpi-pull timer and service, our cache as substituter
    build-host.nix       NixOS module (host): aarch64 emulation, rpi-deploy
    build-host-home.nix  Home Manager module (host): rpi-deploy on the PATH only
  rpi-deploy.sh        rpi-deploy: image / flash / deploy / status (host)
  rpi-pull.sh          rpi-pull: what the Pi's timer runs (pointer, verify, realise, switch or boot)
  rpi-fp.sh            boot fingerprint, pure bash (rpi-deploy and rpi-pull share it)
  rpi-lib.sh           guards and ssh helpers (host; sources rpi-fp.sh)
  ci/                  the scripts the workflow calls: cache-name, build, publish, pointer, commit-push
  deploy/neptun.json   the pointer, written by CI (absent until the first successful run)
  tests/               unit tests, eval checks, qemu smoke tests (see "Testing")
docs/superpowers/      specs and plans
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
- `rpi-deploy` on the PATH.

The host runs no update job: security updates come from CI (section 4).

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

### C. ssh access to the Pi

The tools address the Pi as `root@neptun`, port 2222. Add to `~/.ssh/config`
on the host:

```
Host neptun
  HostName 192.168.100.20
  Port 2222
```

(`rpi-deploy` also passes `-p 2222` itself, `--port` changes it, and
`--target root@192.168.100.20` avoids the name.)

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
non-removable disk (an SD card in a built-in `mmcblkN` reader counts as
removable, since Linux never sets the flag on MMC, but only if
`/sys/block/mmcblkN/device/type` is `SD`: eMMC is refused), the disk that
holds the host's `/`, a device with mounted partitions, and a missing or wrong confirmation: you must type the device name
(`type the device name (sdX):`). Writing is the only privileged step (plus the
read-back); the image is 1.3 GiB compressed, 4.2 GiB raw, ~4 min each way at
20 MB/s.

**First boot.** Insert the card, power the Pi (network cable in):

```sh
ssh -p 2222 pi@neptun        # or root@neptun: both with your key, no password
```

Expect about a minute or two (first-boot expansion, host key generation; unmeasured on hardware, ~100 s under qemu, which is ~5x slower). After a
re-flash the host key changes: `ssh-keygen -R '[192.168.100.20]:2222'`.

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
current: /nix/store/…-nixos-system-neptun-…     # running now
booted: /nix/store/…-nixos-system-neptun-…      # running since the last boot
default: /nix/store/…-nixos-system-neptun-…     # what the next boot starts
reboot pending: no
pull applied: seq 12 /nix/store/…-nixos-system-neptun-… (3h ago)
pull last run: applied (exit 0) at 2026-10-25T05:07:41Z
```

The last two lines are the pull state (section 4): `pull applied: none` /
`pull last run: never` before the first run, `pull: disabled` when the Pi's
system has no `rpi-pull` unit, `pull: unknown (…)` when the query fails (it
never fails `status`). A `pull last run` with a non-zero exit and a result
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

Exit codes (all subcommands): 2 usage, 10 kernel not cached, 11 forbidden local
build, 12 too many local builds, 13 build/eval failed, 14 deploy failed,
15 would downgrade, 16 device refused, 17 verify failed. There is no
override for the guards (plain `nix build` stays possible if you really want a
local kernel build; expect 16+ h under qemu).

Environment: `RPI_FLAKE` (default flake dir), `RPI_SSH_OPTS` (extra ssh
options), `RPI_NIXOS_REBUILD` (use this `nixos-rebuild` instead of the pinned
one), `RPI_CACHE_URL`.

## 4. Automatic updates: CI builds, the Pi pulls

Security updates reach the Pi without the build host being on and without the
Pi evaluating the flake (eval needs ~1.1 GB RSS; the Pi has ~870 MiB usable).
GitHub Actions builds the system, a timer on the Pi pulls it.

**CI** (`.github/workflows/neptun.yml`, `ubuntu-24.04-arm`, always on `main`):
runs on cron `17 0 * * 0` (Sunday 00:17 UTC), on every push to `main` that
touches `nixos/**` (not `nixos/deploy/**`) and on `workflow_dispatch` (input
`update-lock`). One run at a time (`concurrency: neptun`). The third-party
actions are pinned by full commit SHA (tag in a trailing comment; the
`actionlint` check enforces it) and get no secrets: the signing key and the
auth token only reach `ci/publish.sh`, because together they are root on the
Pi. Dependabot (`.github/dependabot.yml`) opens weekly PRs that bump the pins:
read what changed before merging one. Steps:

1. cron (or `update-lock`): `nix flake update nixpkgs nixos-raspberrypi`;
2. guards (`rl_guard`, the same code as `rpi-deploy`): the kernel must be in
   nvmd's cachix, no kernel/toolchain build, at most 500 local builds. A kernel
   cache miss after the lock update falls back to the committed lock plus a
   `nixpkgs`-only update, so an uncached nvmd `develop` HEAD does not hold back
   the userspace fixes;
3. build the `rpi` toplevel;
4. run shellcheck and the unit tests as nix checks on the runner
   (`checks.aarch64-linux.rpi-{deploy-syntax,pull-unit,ci-unit,deploy-unit}`):
   a broken `rpi-pull.sh` or CI script is never published;
5. `cachix push` the closure to **our** cache and
   `cachix pin <cache> neptun --keep-revisions 4` (the last four systems are
   safe from LRU eviction);
6. only after push and pin, only on `main`: write the pointer
   `nixos/deploy/neptun.json`, then commit `flake.lock` and the pointer to
   `main` as `github-actions[bot]` (unsigned; one rebase and retry if `main`
   moved). A failing step leaves the pointer and the Pi untouched. Same
   toplevel as the pointer's → no commit.

The pointer: `{ "seq": N, "storePath": "/nix/store/…-nixos-system-neptun-…",
"narHash": "sha256-…", "rev": "<git sha built>", "built": "YYYY-MM-DDTHH:MM:SSZ" }`.
`seq` is the workflow's `run_number` (a positive integer of at most ten
digits); `built` must have exactly that UTC form or the Pi rejects the pointer.

**The Pi** (`modules/pull-update.nix`, unit `rpi-pull`, `rpi-pull.sh`): the
timer runs **daily at 05:00** (`*-*-* 05:00`, up to 30 min random delay,
`Persistent=true`: a Pi that was off catches up at boot, after `time-sync`).
A run without a new pointer is one HTTP request. Each run:

1. fetches the pointer (HTTPS, size and time limits); HTTP 404 → `no pointer
   published yet`, exit 0, but only while no pointer was ever applied: once
   one was, a 404 is exit 30 (`pointer disappeared`: the repo was made
   private, renamed or deleted, or the pointer file removed), so the Pi
   cannot stop updating silently;
2. validates it: `seq` equal to the applied one → `up to date`, exit 0; older →
   exit 31; the store path must match `nixos-system-neptun-…` in `/nix/store`;
3. reads the store path's narinfo from our cache (`nix path-info --store
   <cacheUrl> --json`) *before anything is realised*: it must be
   input-addressed, name a signature by our key and carry the pointer's
   narHash; `nix store verify --no-contents --store <cacheUrl>
   --trusted-public-keys <our key>` checks that signature (exit 32
   `untrusted`, 34 narHash mismatch, 38 cache unreachable or the path not in it);
4. already the running system → record the seq and stop; otherwise
   `nix-store --realise` (two substitution jobs, ~80 MB RSS), compare the
   narHash with the pointer's and require the realised path to be
   input-addressed (exit 33 / 34 / 32);
5. compares the boot fingerprint of the new system with the booted one (the
   `status` logic, section 3), *before* touching the profile: equal →
   `nix-env --set` + `switch-to-configuration switch`; different (kernel, initrd,
   modules, device trees, kernel parameters, firmware, `config.txt` or U-Boot) →
   `switch-to-configuration boot` + `shutdown -r 04:30` (the next 04:30, so
   about 23 h after the 05:00 run: `shutdown -c` cancels it; `rebootTime` is
   an option). The Pi is not left half-applied by a fingerprint failure
   (exit 36 before the profile changes);
6. `sync`, record the seq and store path in `/var/lib/rpi-pull/`;
7. if the pointer was built more than `maxAgeDays` (default 21) ago: exit 39,
   `pointer is N days old (CI stalled?)` -- CI stopped publishing (also catches
   GitHub disabling the schedule after 60 days without repository activity).

Every run that got the lock writes `/var/lib/rpi-pull/last-run`
(`time=… exit=… result=…`); the unit fails visibly (`systemctl status
rpi-pull`) on any non-zero exit. Exit codes of `rpi-pull`: 0 ok, 1 state dir,
2 usage, 30 fetch, 31 pointer invalid or older, 32 untrusted (not signed by
our key, or content-addressed), 33 realise, 34 narHash mismatch, 35 profile,
36 activation, 37 busy (another run), 38 cache unavailable or the system not
in it, 39 pointer stale. The service is `Type=oneshot` with
`restartIfChanged = false` (a switch that changes the unit must not stop the
run that performs it), `MemoryMax=384M`, nice/ionice/CPU idle, `TimeoutStartSec=2h`.

> **Trust.** Before anything is realised, the toplevel's narinfo in our cache
> must be **input-addressed, signed by *our* cache key and carry the pointer's
> narHash**. The signature check is ours-only: `--trusted-public-keys` replaces
> the Pi's configured keys, so a system signed by cache.nixos.org or nvmd's
> cachix does not pass. A content-addressed toplevel is refused (exit 32): nix
> treats a content-addressed path as valid **without any signature** (in
> `nix store verify` and when substituting), so whoever can write to the
> cache (the auth token, or Cachix itself) could otherwise publish an
> unsigned system of their own. These checks cover the toplevel path only.
> After the realise the **realised path's narHash must equal the pointer's**
> (and so the signed narinfo's), and the path must be input-addressed in the
> local store too: that binds the activated content to our signature (a
> foreign or tampered system fails with 32 or 34). The dependencies of the
> closure are substituted with `require-sigs` and the three configured keys
> (cache.nixos.org, nvmd's cachix, ours). The pointer itself is not signed:
> it is only as trustworthy as write access to the repo. A compromised GitHub
> account or secrets means a deploy to the Pi, the same level as the root SSH key.
> The monotonic `seq` refuses an older pointer (a rollback attempt).

**`rpi.pull` options** (`modules/pull-update.nix`): `pointerUrl`, `cacheUrl`,
`cachePublicKey`, `onCalendar` (`*-*-* 05:00`), `rebootTime` (`04:30`),
`maxAgeDays` (`21`), `enable`. `configuration.nix` sets `pointerUrl =
https://raw.githubusercontent.com/GRBurst/nix-raspi/main/nixos/deploy/neptun.json`
and takes `cacheUrl` (`https://<name>.cachix.org`) and `cachePublicKey` from
`keys.nix`. The module **stays off, with an evaluation warning** (`rpi.pull
stays disabled: … not set`) until all three are set: it appears on every
evaluation of `rpi` until `keys.cache` is filled in, which is intended. Once
enabled, our cache is added to the Pi's `substituters` and
`trusted-public-keys` (cache.nixos.org and nvmd's stay). An `http://` pointer
URL is accepted for the qemu smoke test only (warning).

### Setup (once; steps only you can do)

1. **GitHub.** A **public** repo (free arm64 runners; `raw.githubusercontent.com`
   serves the pointer): `GRBurst/nix-raspi`, the URL in `configuration.nix` (if
   it lives elsewhere, change `rpi.pull.pointerUrl`). Push `main`. Settings →
   Actions → General → Workflow permissions: **Read and write**. No branch
   protection or ruleset on `main` that blocks `github-actions[bot]` (or give it a
   bypass), because the job pushes the lock and pointer commit.
2. **Cachix cache, self-signed.** Create a public cache whose signing key you
   generate yourself (an advanced choice at creation; Cachix never holds the key):
   `cachix authtoken <token>`, `cachix generate-keypair <cache>` prints the
   secret key once. Store it as the GitHub secret **`CACHIX_SIGNING_KEY`**
   (nowhere in the repo), and a write token of the cache as
   **`CACHIX_AUTH_TOKEN`**. A Cachix-managed key is not enough: whoever holds the
   auth token could then sign arbitrary content.
3. **`nixos/keys.nix`:** `cache = { name = "<cache>"; publicKey =
   "<cache>.cachix.org-1:…"; };` (the public key from the Cachix dashboard).
   Commit and push to `main`. The workflow reads the cache name from here.
4. **First CI run.** Actions → `neptun` → *Run workflow* (`main`). The first push
   uploads ~340 MiB, later runs ~150 MiB (the free tier has 5 GB and evicts by
   LRU; the pin protects the last four systems). It pushes, pins and commits
   `nixos/deploy/neptun.json`; `git pull` it.
5. **Dispatch a second time** and confirm that it produces **no** pointer
   commit (same store path, `pushed=false`). If it commits a new pointer every
   time, the toplevel is not reproducible between runs: find out what differs
   before relying on the timer.
6. **Enable the timer on the Pi** with one manual `rpi-deploy deploy switch`
   from a tree that has `keys.cache` (section 3). From then on the Pi pulls on
   its own: it applies the pointer at its next 05:00 run, or at once with
   `ssh -p 2222 root@neptun systemctl start rpi-pull` (watch
   `journalctl -fu rpi-pull`).
7. **Hardware acceptance (AC3):** `rpi-deploy status` shows `pull applied: seq N …`
   and `pull last run: applied (exit 0) at …` after the first run that applied
   something (checklist in `HANDOFF.md`).

### Operating it

| what | how |
|------|-----|
| build and publish now | Actions → `neptun` → *Run workflow*; tick `update-lock` to also update `nixpkgs`/`nixos-raspberrypi` (`gh workflow run neptun.yml -f update-lock=true`) |
| apply on the Pi now | `ssh -p 2222 root@neptun systemctl start rpi-pull` (blocks until done; ≤ 2 h) |
| logs | `ssh -p 2222 root@neptun journalctl -u rpi-pull` |
| timer | `ssh -p 2222 root@neptun systemctl list-timers rpi-pull` |
| state | `rpi-deploy status`: `pull applied: seq N <path> (3h ago)` or `pull applied: none`; `pull last run: <result> (exit N) at <time>` or `never`; `pull: disabled` (no unit: the Pi runs a system without the timer); `pull: unknown` (query failed) |

**Semantics worth knowing.**

- *A push to `main` is a deploy.* Every push that touches `nixos/**` builds and
  publishes; the Pi applies it at its next daily run. CI builds `main` with
  `ref: main` whatever started the run, so unpushed local changes are not in it.
- *Manual deploys persist until the next CI build.* The Pi applies a pointer
  only if its `seq` is newer than the last one applied, so `rpi-deploy deploy`
  stays in place; the next CI run replaces it with `main`'s system. Push
  before the run you want it to survive.
- *A freshly flashed Pi has no applied seq.* At its first run it applies the
  current pointer, even if the flashed image is newer (built locally, not
  pushed): push to `main` before flashing, or expect the downgrade.
- *A pointer older than the applied seq fails the unit* (exit 31): a rollback
  attempt or a reset of the repo. An equal seq is a silent `up to date`. After
  a rollback on the Pi (section 5) the same seq is **not** re-applied; it stays
  rolled back until the next CI build.
- *Timing.* CI runs Sunday 00:17 UTC (a build takes minutes to a few hours,
  longer after a cold cache); the Pi looks daily at 05:00 local + ≤ 30 min, so
  a fresh pointer is applied within about a day, a needed reboot at the next 04:30.
- *Failures are loud and safe.* Cache outage between pointer and pull → exit
  33/38, profile and seq untouched, retried the next day. `rpi-pull` never
  evaluates or builds.

## 5. Recovery and rollback

**Userspace regression** (the system boots, something is wrong): roll back one
generation from the host:

```sh
NIX_SSHOPTS='-p 2222' nix run .#nixos-rebuild -- switch --rollback --no-reexec --target-host root@neptun
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
good commit (or fix the cause on `main`) before the next CI build (a push to
`main`, or the Sunday run) is pulled.

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

1. Make sure `keys.nix` has your key (and, once section 4's setup is done, the
   `cache`: an image built then already ships the pull timer; otherwise one
   `rpi-deploy deploy switch` adds it later).
2. `rpi-deploy image`, `rpi-deploy flash … /dev/sdX`, boot (section 2).
3. `ssh-keygen -R '[192.168.100.20]:2222'`, then `ssh -p 2222 root@neptun true`
   and `ssh -p 2222 pi@neptun true`.
4. Walk through the hardware checklist in `HANDOFF.md`.
5. With section 4 set up: a freshly flashed Pi has no applied seq, so at its
   first run it applies the current pointer, even over a newer image you built
   locally. Push that state to `main` first, or expect the older system.

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
   the CI build (`ci/build.sh`) then falls back to updating `nixpkgs` only.
   A manual `nix flake update` has no such fallback.

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
  key-only; same trust as the root key). Root's key: yours only (no restricted
  automation key; CI never logs in to the Pi, the Pi pulls).
- Options follow nixos-26.05 (e.g. `services.journald.extraConfig`; the newer
  `settings` is 26.11 only).

## 10. Testing

```sh
nix flake check --accept-flake-config        # all checks incl. the VM test, ~2 min warm (131 s, all built fresh)
nix build .#checks.x86_64-linux.eval-kernel  # one check
```

| layer | check | cost |
|-------|-------|------|
| eval checks (option values and their effects: kernel identity, image, access, GC/extlinux, sd-wear, headless, external storage, tools, build host, pull module) | `eval-<name>` from `tests/eval/<name>.nix` (`eval-pull-update`: defaults, timer, units, substituter and key, the disabled-until-set rule) | seconds |
| unit tests, mocked nix/ssh/sudo/lsblk/dd/nixos-rebuild/curl/cachix, real git/zstd/flock | `rpi-deploy-unit` (host tool), `rpi-pull-unit` (every `rpi-pull` path), `rpi-ci-unit` (`ci/*.sh`: build, publish order, pointer, commit and rebase) | ~10–60 s each; auto-discovered from `tests/<n>-unit.sh` |
| bash syntax + shellcheck (every `*.sh` outside `tests/`, incl. `ci/`) | `rpi-deploy-syntax` | seconds |
| the same unit tests and shellcheck for `aarch64-linux`: CI runs them before it publishes (on x86_64 `nix flake check` omits them as an incompatible system) | `checks.aarch64-linux.rpi-{deploy-syntax,pull-unit,ci-unit,deploy-unit}` | ~1–3 min on the arm runner [?] |
| lint of the workflow (+ shellcheck on its `run:` steps); step order build → unit checks → push + pin → pointer → commit; actions pinned by commit SHA, no secrets handed to an action, dependabot entry | `actionlint` | seconds |
| NixOS VM test of the build-host module (binfmt, aarch64 `hello`, the `rpi-deploy` wrapper) | `rpi-host-vm` | 1–16 min (half a minute of test script once built) |
| qemu `raspi3b` boot of the real image + SSH banner over usb-net | `tests/boot-smoke.sh IMAGE.img.zst` | ~4–6 min |
| qemu deploy: boot the image, `rpi-deploy deploy switch`, verify | `tests/deploy-smoke.sh` | ~20–30 min (image build ~10 min of it, cached on re-runs) |
| qemu pull: boot an image with a throwaway cache key, serve a signed local cache and a pointer over HTTP, let the guest's `rpi-pull.service` apply it (switch path, with a changed unit), then refuse a pointer signed by a foreign key (exit 32) | `tests/pull-smoke.sh` | ~28 min (1656 s measured, image rebuilt) |

The smoke tests are not part of `nix flake check` (qemu TCG, minutes). All
need `qemu-system-aarch64` with `-M raspi3b` (`nix shell nixpkgs#qemu`),
`zstd`, `sfdisk`, `debugfs` and `mcopy`, no root:

```sh
tests/boot-smoke.sh ~/rpi-images/result-rpi-image/sd-image/neptun-rpi3.img.zst
tests/deploy-smoke.sh            # builds a throwaway-key image itself
tests/pull-smoke.sh              # throwaway root and cache keys, local cache on 127.0.0.1:18080
```

`pull-smoke` also needs `curl`, `jq` and network for the guards (busybox comes
from the pinned nixpkgs; the port is `RPI_PULL_SMOKE_HTTP_PORT`, default
18080, and part of the cached image). Not covered by it: the boot-and-reboot
path of `rpi-pull` (unit tests only) and the real GitHub and Cachix side.

What qemu cannot cover: U-Boot reading `extlinux.conf`, the GPU firmware
applying `config.txt`, a real card, the LAN, the reboot timer, GitHub Actions
and Cachix. That is the
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
