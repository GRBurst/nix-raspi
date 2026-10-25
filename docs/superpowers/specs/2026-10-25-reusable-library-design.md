# Design: reusable library flake (others can run their own Pi)

Date: 2026-10-25 · Status: draft for user review
Builds on: `2026-10-19-image-push-deploy-design.md`,
`2026-10-23-ci-pull-updates-design.md` (mechanics of image, push deploy,
CI build, pointer, `rpi-pull` stay as specified there unless changed here).

## 1. Intent

Others can use this repo for their own Raspberry Pi 3 without editing our
values: nothing personal is hardcoded in library code, every Pi-specific value
is an option with a sensible default, and the NixOS boilerplate (nvmd base,
hybrid inputs, home-manager, image) is hidden behind one entry point while all
NixOS options stay overridable. Our own Pi (`neptun`) becomes one example host
that keeps its tailored CI build and Cachix cache. CI is green for forks and
for repos without a cache.

What the user said: configurable options instead of hardcoded hostname/keys;
CI values through GitHub Actions variables/secrets; a gitignored local devenv
file plus a committed example; Wi-Fi/Bluetooth configurable with defaults off;
a module so the boilerplate moves out of the config; use GitHub annotations
and step summaries; README consumer-first; shell scripts stay shellchecked.

## 2. Evidence

| Question | Result |
|---|---|
| Current CI failure | both runs (push e592084, schedule 924a53d) fail in step `ci/cache-name.sh`: `keys.nix` has `cache = null` → exit 1 |
| Gitignored/untracked files in a git flake | experiment: `builtins.pathExists ./local.nix` is `false` for gitignored and for untracked files; only a `path:` flake ref sees them (drops git filtering) or `--impure` env reads. Either makes CI and local builds differ |
| Cache reuse across configs | experiment: neptun vs. a variant with other hostname, SSH keys, timezone, static IP: 16 of 5166 derivations differ (etc, hosts, authorized_keys, system-units, the .network unit, activate, initrd, toplevel); kernel, firmware, all packages identical |
| Wi-Fi/Bluetooth today | not separately configurable: `rpi.headless` disables both overlays together with GPU/audio/camera; the wireless config and secrets file were removed in the image/push design |
| Hardcoded personal values | hostname `neptun`, SSH port 2222, 192.168.100.20/.1, user `pi` + key (`keys.nix`), pointer URL `GRBurst/nix-raspi`, Europe/Berlin, keymap `neo`, nix-terminal profile, `rpi-deploy` default `root@neptun:2222`, workflow/pointer names, test fixtures |
| How others structure it | nixos-hardware, srvos, disko, nvmd/nixos-raspberrypi: library flake exporting modules (+ helper, + templates); per-machine values in the consumer's committed config. Public keys, hostnames, cache public keys are not secrets |
| On-Pi evaluation | 1.08 GB RSS for this config (Pi 3: ~869 MiB usable); independent of any cache: the Pi never evaluates, a host (push) or CI (pull) does |
| Secret store for the host | devenv integrates SecretSpec (`secretspec.toml` declares secrets; providers: keyring/Secret Service, dotenv, 1Password, env) |

## 3. Architecture

```
flake.nix                      library outputs + our instance (moved from nixos/ to the root)
modules/default.nix            imports all rpi.* modules
  identity.nix network.nix wifi.nix bluetooth.nix headless.nix
  sd-wear.nix external-storage.nix pull-update.nix sd-image.nix
  profiles/terminal.nix        home-manager + nix-terminal (off by default)
  build-host.nix build-host-home.nix   (unchanged, host side)
lib/mkPi.nix                   nvmd nixosSystem + hybrid inputs + HM module + modules/default.nix
hosts/neptun/default.nix       our values only (replaces keys.nix + configuration.nix personal parts)
hosts/neptun/home.nix          our nix-terminal settings
templates/default/             flake.nix, hosts/<name>.nix, .github/workflows/pi.yml,
                               .github/dependabot.yml, devenv.local.nix.example, README.md
deploy/<host>.json             pointer per host (written by CI)
ci/*.sh, rpi-*.sh, tests/      stay shell files (packaged unchanged, shellchecked)
.github/workflows/pi.yml       our workflow (same shape as the template's)
secretspec.toml                declared host-side secrets (Wi-Fi PSKs)
devenv.local.nix.example       committed; devenv.local.nix gitignored
```

Flake outputs:

- `lib.mkPi { modules; specialArgs ? {}; }` → a `nixosSystem` result; the
  only entry point. Returns `nixosSystem … // { rpiHost = true; }` so CI
  discovers Pi hosts (`attrNames` filtered on `rpiHost`) without evaluating
  each system's modules.
- `nixosModules.default` (the `rpi.*` modules; for users who wire nvmd
  themselves), `nixosModules.rpiBuildHost`, `homeModules.rpiBuildHost` (unchanged).
- `templates.default`.
- `packages.<system>.rpi-deploy`, `packages.<system>.rpi-ci` (the `ci/*.sh`
  scripts, wrapped with their tools).
- `nixosConfigurations.neptun = lib.mkPi { modules = [ ./hosts/neptun ]; }`;
  `rpi` stays as an alias for one release (scripts, docs), then is dropped.
- `checks` (existing + new, §7), `apps.x86_64-linux.nixos-rebuild` (unchanged).

Where values live:

| Value | Place | Why |
|---|---|---|
| Anything the Pi system depends on (keys, hostname, network, cache name + public key, pull repo) | committed host module | pure: CI and local builds are identical; none of it is secret |
| `CACHIX_AUTH_TOKEN`, `CACHIX_SIGNING_KEY` | GitHub Actions secrets | only CI publishes |
| Operator settings for this machine (deploy target/port override, `RPI_HOST`) | gitignored `devenv.local.nix` (example committed) | `rpi-deploy` runs outside the flake |
| Wi-Fi PSKs | SecretSpec provider of each user (keyring, dotenv, …) → env → `rpi-deploy` | never in the store: the store goes to a **public** cache and is world-readable on the Pi |

Consumers do not `follows` our nixpkgs/nvmd inputs in the template: inheriting
our lock is what makes the upstream and nvmd caches (and optionally ours) hit.

## 4. Option API (`rpi.*`) and defaults

Principle: an `rpi.*` option only where it bundles several NixOS settings or
encodes Pi knowledge. Everything else is an `mkDefault` on the normal NixOS
option that users set directly (`networking.hostName` default `"rpi"`,
`time.timeZone` default `"UTC"`, `i18n.defaultLocale`, `console.keyMap`).

| Option | Default | Effect |
|---|---|---|
| `rpi.admin.user` | `"pi"` | normal user in `wheel`, key-only login |
| `rpi.admin.sshKeys` | none: assertion if empty | `authorized_keys` of the admin user and of root |
| `rpi.ssh.port` | `22` | sshd port; password auth off; root `prohibit-password` (push deploy logs in as root) |
| `rpi.network.mode` | `"dhcp"` | `"static"` uses `rpi.network.static.{address (CIDR), gateway, dns ? []}`; networkd, matches any wired `ether` |
| `rpi.wifi.enable` | `false` | drops the `disable-wifi` overlay, wpa_supplicant via networkd (DHCP on wlan) |
| `rpi.wifi.networks` | `{}` | SSID → PSK variable name; PSKs from `rpi.wifi.secretsFile` (default `/var/lib/rpi/wireless.env`, 0600, owned by the `wpa_supplicant` user: amended 2026-10-25, final review B1) |
| `rpi.bluetooth.enable` | `false` | drops the `disable-bt` overlay, `hardware.bluetooth.enable` |
| `rpi.headless.enable` | `true` | gpu_mem 16, no KMS, audio, camera/display detection (no longer touches Wi-Fi/Bluetooth) |
| `rpi.profiles.terminal.enable` | `false` | home-manager + nix-terminal for `rpi.admin.user`, zsh login shell |
| `rpi.pull.repo` / `rpi.pull.branch` | `null` / `"main"` | `pointerUrl` = `https://raw.githubusercontent.com/<repo>/<branch>/deploy/<hostName>.json` (still overridable) |
| `rpi.pull.cache` | `null` | `{ name; publicKey; }` → `cacheUrl`, `cachePublicKey`, and the CI cache name |
| `rpi.pull.enable` | on when pointer + cache are set | unchanged semantics, timer/reboot settings unchanged |
| `rpi.deploy.target` | `"root@<hostName>"` | read by `rpi-deploy` together with `rpi.ssh.port` |
| `rpi.sdWear.*`, `rpi.storage.external.*` | on / off | unchanged |

Kept as `mkDefault`: zram 50 %, weekly GC (21 d), extlinux limit 5, no
channels, `nixpkgs.flake` registry/NIX_PATH, `security.sudo.wheelNeedsPassword
= false` (key-only login), `documentation.enable = false`,
`boot.tmp.cleanOnBoot`, nix `max-jobs`/`cores` 3, `allowUnfree`.

`hosts/neptun` sets: its key, `rpi.ssh.port = 2222`, static
192.168.100.20/24 via .1, `networking.hostName = "neptun"`, Europe/Berlin,
`neo`, terminal profile on (+ `hosts/neptun/home.nix`), `rpi.pull.repo =
"GRBurst/nix-raspi"`, our cache once created, neovim, screen, sysctl, the
`docker`/`video` groups.

Out of scope (YAGNI): Pi models other than 3, our cache as a default
substituter for others, separate locale options, sops-nix/agenix (needs a
pre-generated host key at flash time; possible later extension).

## 5. Host tooling

`rpi-deploy`:

- `--host NAME` selects `nixosConfigurations.NAME`; default `$RPI_HOST`, else
  the only Pi host; ambiguous → exit 2 with the list.
- Target and port from `nix eval` of `config.rpi.deploy.target` and
  `config.rpi.ssh.port`; `RPI_TARGET` / `RPI_PORT` override (typically from
  `devenv.local.nix`).
- `flash --wifi-env` writes `rpi.wifi.secretsFile` (0600) into the flashed
  root partition, built from the env variables named in `rpi.wifi.networks`.
- New `secrets` subcommand: same file, copied over ssh (`install -m 600`),
  then `systemctl try-restart` of the wpa_supplicant unit.
- Missing PSK variable → exit 2 naming the variable; values never printed or
  passed on a command line.
- *Amended 2026-10-25 (final review B1):* NixOS 26.05 runs wpa_supplicant
  as the user `wpa_supplicant` without a DAC override, so `rpi.wifi` adds a
  tmpfiles rule `z <secretsFile> 0600 wpa_supplicant wpa_supplicant`.
  `secrets` applies it right after `install` (`systemd-tmpfiles --create
  --prefix=<file>`); `flash --wifi-env` still writes root 0600 (the card has
  no such user yet) and the first boot applies the rule.
- *Amended 2026-10-25 (final review S2):* the wpa_supplicant unit(s) get
  `ConditionPathExists = <secretsFile>` (nixpkgs bind-mounts the file, so a
  missing file failed the unit and the deploy's switch); `secrets` then runs
  `systemctl restart` instead of `try-restart` (which left the skipped unit
  stopped), guarded by `systemctl cat` so a Pi without Wi-Fi deployed exits
  0. `secrets` may run before or after the deploy that enables Wi-Fi.
- *Amended 2026-10-25 (final review S4):* `RPI_TARGET`/`RPI_PORT` are only
  for the default host (`$RPI_HOST`, else the only one). With a `--host`
  other than `$RPI_HOST` (any `--host` while `RPI_HOST` is unset) they are
  ignored with a message, and that host's `rpi.deploy.target`/`rpi.ssh.port`
  apply (`--target`/`--port` still win), so `deploy --host b` never
  switches Pi a to b's system.

devenv: `secretspec.toml` declares the PSK variables of the example host;
`devenv.local.nix.example` shows `RPI_HOST`, `RPI_TARGET`, `RPI_PORT`;
`devenv.local.nix` gitignored. `RPI_FLAKE` points to the repo root.

## 6. CI

`ci/*.sh` stay shell scripts, packaged as `packages.rpi-ci` (one entry with
subcommands `hosts|build|publish|pointer|commit`). Workflows call
`nix run --inputs-from . rpi#rpi-ci -- <cmd>` in a consumer repo and
`nix run .#rpi-ci -- <cmd>` here, so template users run the locked scripts
without copying shell code. (Build and commit jobs: built once before the
lock update, see the S3 amendment in "11. Risks".)

`.github/workflows/pi.yml` (ours and the template's): weekly cron (lock
update), push to `main`, manual dispatch (`update-lock` input, and
`update-library` since S3); main only; actions SHA-pinned + dependabot (as
now).

1. `hosts`: lists Pi hosts → matrix.
2. `build` (matrix, `ubuntu-24.04-arm`): lock update if requested, build
   the toplevel, run the aarch64 unit checks, then:
   - `rpi.pull.cache` set → push closure, pin, write the pointer, upload it
     (and the lock) as an artifact;
   - not set → skip publish with a `::notice::` ("no cache configured for
     <host>: built and tested, not published"); the job stays green;
   - set but `CACHIX_AUTH_TOKEN`/`CACHIX_SIGNING_KEY` missing → `::error::`
     naming the secret, job fails.
3. `commit` (one job, after the matrix): one commit of `flake.lock` and all
   `deploy/<host>.json`, so matrix jobs never push concurrently.
   *Amended 2026-10-25 (final review S1):* `hosts` outputs the run's base
   commit, every build job checks it out, and `rpi-ci commit --base` refuses
   (`::error::`, no commit) when main's `flake.lock` differs from the base's,
   also after the rebase of a rejected push: a lock change pushed during the
   build is never reverted.

Feedback in the GitHub UI:

- Each step writes a Markdown section to `$GITHUB_STEP_SUMMARY`: host,
  nixpkgs/nvmd revisions (and lock diff when updated), toplevel path,
  closure size, paths pushed, pointer seq, whether the boot fingerprint
  changed (switch vs. reboot on the Pi), skipped steps with the reason.
- Errors and warnings as `::error file=…,line=…::` / `::warning::` /
  `::notice::` annotations (guard failures, missing secrets, skipped publish).
- Long logs in `::group::` blocks; job names include the host.
- The scripts emit these only when `GITHUB_ACTIONS=true`, so local runs and
  unit tests stay plain.

## 7. Migration and testing

Migration of this repo:

- `git mv nixos/* .` (history kept); `keys.nix` → `hosts/neptun`;
  pointer `nixos/deploy/neptun.json` → `deploy/neptun.json`. No Pi depends on
  the old URL yet (pull is off while `cache = null`).
- Refactor invariant: the `neptun` toplevel derivation closure after the
  refactor equals the one before, except for a listed set of expected
  differences (at least the pointer URL in the rpi-pull config). Checked by
  comparing `nix-store -qR <drv>` sets before/after.

Tests (TDD; existing ones keep passing, fixtures move from `neptun`-specific
values where they are not about neptun):

- Eval checks: defaults (DHCP, Wi-Fi and Bluetooth overlays off, port 22,
  hostname `rpi`, no HM users); static network; Wi-Fi on (overlay gone,
  secrets file path, no PSK in the store); Bluetooth on; assertion without
  keys; derived pointer URL; `rpi.pull.enable` only with repo + cache;
  `rpi.deploy.target`; the template's host evaluates through `lib.mkPi`
  with the local library.
- Unit: `rpi-deploy` host selection/overrides, `secrets`, `flash
  --wifi-env` (mocked); `rpi-ci` hosts/matrix, cache-less skip, missing
  secret error, single commit job, summary/annotation output only under
  `GITHUB_ACTIONS=true`; actionlint for both workflows.
- qemu: boot-smoke on a default (DHCP) host built from the template;
  deploy-smoke and pull-smoke on `neptun`.

## 8. README (consumer first)

Order: what it is (one paragraph) → quick start (`nix flake init -t
github:GRBurst/nix-raspi`, fill the host file, `rpi-deploy image`/`flash`,
first boot, `rpi-deploy deploy`) → configuration (the `rpi.*` table,
Wi-Fi + secrets) → updates (push vs. pull, setting up a cache and CI
secrets) → caching (below) → troubleshooting → our `neptun` as an example →
development (devenv, tests, repo layout) last.

Caching section content: kernel/firmware come from the nvmd cache, almost
all userspace from cache.nixos.org (both shared by everyone on the same lock);
config changes such as hostname, keys or network rebuild only ~16 small
derivations; package additions/removals do not invalidate other packages,
overlays and overrides rebuild their dependents; the Pi cannot evaluate its
own config (~1.1 GB), so a host (push, no own cache needed) or CI (pull, own
signed cache needed, small if only upstream packages are used) builds it;
using our cache means trusting our signing key (opt-in, not default).

## 9. Acceptance

1. `nix flake check` passes at the root; no personal value (key, hostname,
   IP, repo, timezone, keymap) appears outside `hosts/neptun`, the
   README's example section and test fixtures that name it explicitly.
2. A template instance (`nix flake init -t`, keys filled in) evaluates and
   builds its image without editing library files; its default system uses
   DHCP, port 22, Wi-Fi/Bluetooth off.
3. The `neptun` derivation diff matches the expected-difference list.
4. CI on GitHub is green on `main` without a cache configured, with a step
   summary per host and a notice about the skipped publish (user verifies
   after pushing).
5. boot-smoke (template default host), deploy-smoke and pull-smoke pass.
6. README follows §8.

## 10. User actions

- Push and watch the first CI run (agents cannot push).
- Create the Cachix cache, add the two secrets, set `rpi.pull.cache` in
  `hosts/neptun` (unchanged from the previous addendum).
- Put Wi-Fi PSKs in a SecretSpec provider if Wi-Fi is enabled.

## 11. Risks

- Root move touches every path: mitigated by the derivation invariant and
  the full check suite.
- `--inputs-from .` depends on the consumer's input being named `rpi`: the
  template fixes that name; documented.
- Matrix eval cost: each host evaluates once per job (~1 GB RSS, fine on the
  16 GB runner).
- Template users inherit our weekly lock bumps only when they update their
  lock; documented.
  *Amended 2026-10-25 (final review S3, user decision):* the consumer's
  weekly run updated its root input `rpi`, i.e. auto-followed our `main`
  and signed it with the consumer's key. Now `rpi-ci build` updates
  nixpkgs and nixos-raspberrypi only, in a consumer as the nested inputs
  `rpi/nixpkgs` and `rpi/nixos-raspberrypi` (`nix flake update
  rpi/nixpkgs rpi/nixos-raspberrypi`: nvmd keeps its own nixpkgs pin, so
  its kernel stays cached; spike in the fix report); `rpi` moves only via
  the manual dispatch input `update-library` (`--update-library`: `rpi`
  with the inputs it locked) or a local `nix flake update rpi`. The build
  and commit jobs build `rpi-ci` once from the committed lock (`nix build
  --inputs-from . rpi#rpi-ci --out-link "$RUNNER_TEMP/rpi-ci"`, here
  `.#rpi-ci`) before any update and call only that, so the Cachix secrets
  never meet unreviewed library code (asserted by the `actionlint` check).
  README and the template README document the trust model.
  *Amended 2026-10-25 (re-review SF1):* the update targets are each root
  input `nixpkgs`/`nixos-raspberrypi` **and** rpi's own node of it
  (`rpi/<x>`, unless it follows a root input): a consumer with a root
  `nixpkgs` of its own still moves the system's `rpi/nixpkgs`. The kernel
  fallback updates all nixpkgs targets; the build summary names the lock
  paths (`nixpkgs`, `rpi/nixpkgs`, …) that moved.
