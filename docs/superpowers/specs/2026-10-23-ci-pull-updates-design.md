# Design addendum: CI builds, the Pi pulls (replaces host auto-update)

Date: 2026-10-23 · Status: approved design (user, 2026-10-23), spec for planning
Amends: `2026-10-19-image-push-deploy-design.md` §3.3 (host side), §3.4
(automatic security updates), §5, §8, §10. Everything else there stays.
Evidence: `nixos/.scratch/s7/REPORT.md` (community, autoUpgrade),
`nixos/.scratch/s8/REPORT.md` (Cachix sizes, pin API, trust, Pi RAM).

## 1. Intent

Security updates must reach the Pi without this host (andromeda) being on,
and without the Pi evaluating the flake. Manual push deploys from the host
remain possible.

## 2. Evidence

| Question | Result |
|---|---|
| autoUpgrade on the Pi | eval peaks 1.10 GB RSS, live heap floor ~700 MB (`GC_MAXIMUM_HEAP_SIZE` 650M → OOM); Pi 3 has ~869 MiB usable. Community/maintainers: deploy remotely (s7) |
| Prior art for pull | thoughtfull-nix/nixfiles PR #182 (2026-05): GH Actions arm64 → signed cache → pointer → Pi timer `nix-store -r` + `nix-env --set` + `switch-to-configuration`; Mic92 niks3 wiki; Cachix Deploy (SaaS) (s7) |
| Upload size to own Cachix | cache.nixos.org paths skipped, nvmd paths not: first push ~341 MiB, weekly ~150 MiB; free tier 5 GB, LRU (s8) |
| Pi RAM to pull | `nix-store -r` of the full closure peaks 180 MB; 76 MB with `max-substitution-jobs = 2` (+20 % time) (s8) |
| Trust | "signed by any trusted key" is insufficient (any NixOS system on cache.nixos.org would pass); require our own key + name + monotonic seq (s8) |
| CI runners | public repo: free `ubuntu-24.04-arm` 4 vCPU/16 GB, 14 GB disk documented; dry run: ~287 small builds, no kernel (s7, s8) |

## 3. Architecture

```
GitHub Actions (ubuntu-24.04-arm, public repo)
  cron weekly | push to main | manual
   └─ [cron] nix flake update nixpkgs nixos-raspberrypi
   └─ guards (rpi-lib.sh rl_guard) ─ build rpi toplevel
   └─ cachix push <toplevel closure> ; cachix pin neptun --keep-revisions 4
   └─ write nixos/deploy/neptun.json ; commit lock + pointer to main
                     │ HTTPS (raw.githubusercontent.com)
Pi (rpi-pull.timer, weekly after CI)
   fetch pointer ─ verify ─ nix-store -r ─ narHash check ─ nix-env --set
   ─ boot fingerprint: same → switch | differs → boot + reboot at 04:30 ─ sync ─ record seq
host (andromeda): rpi-deploy image|flash|deploy|status (manual, unchanged)
```

### 3.1 Cache

- Own Cachix cache `<cache>`, created **self-signed** (signing key generated
  by the user; Cachix never holds it). Public read.
- Secrets in GitHub: `CACHIX_AUTH_TOKEN` (push/pin), `CACHIX_SIGNING_KEY`.
- Public key in the flake (`nixos/keys.nix`: `cache = { name; publicKey; }`)
  → Pi `nix.settings.substituters` + `trusted-public-keys`.
- Pin `neptun` with `--keep-revisions 4` protects recent systems from LRU.

### 3.2 Pointer `nixos/deploy/neptun.json`

`{ "seq": <int>, "storePath": "/nix/store/…-nixos-system-neptun-…", "narHash": "sha256-…", "rev": "<git sha of the built tree>", "built": "<ISO time>" }`

- `seq` = `github.run_number` (monotonic per workflow).
- Committed to `main` in the same commit as the lock (cron) or alone
  (push builds). Pushes by `GITHUB_TOKEN` do not trigger workflows (no loop).
  On a non-fast-forward push the job rebases once and retries; still failing
  → job fails, pointer unchanged.
- Written only after a successful push + pin.
- Not separately signed (decision: HTTPS from GitHub; writing the pointer
  requires repo write access, the same domain as the secrets).
- No pointer file in the repo yet → Pi job does nothing.

### 3.3 CI workflow `.github/workflows/neptun.yml`

- Triggers: `schedule` (Sun 01:00 UTC), `push` to `main` (paths `nixos/**`,
  excluding `nixos/deploy/**`), `workflow_dispatch`.
- Actions: `cachix/install-nix-action@v31`, `cachix/cachix-action@v17`
  (`skipPush: true`; explicit `cachix push`), nvmd cachix as extra
  substituter; `concurrency: neptun` (no parallel runs).
- Steps: (cron) lock update → `rl_guard toplevel 500` (same lib as host) →
  build → `df -h` logged → push closure → pin → pointer → commit + push.
- Any failing step: no pointer change, Pi untouched. A cron run whose
  lock did not change still rebuilds/pushes nothing new and leaves the
  pointer as is (same storePath → no commit).

### 3.4 Pi: `rpi-pull` (module `modules/pull-update.nix`, enabled by default once `keys.cache` and the pointer URL are set)

Options `rpi.pull = { enable; pointerUrl; cacheUrl; cachePublicKey; onCalendar = "Sun 05:00"; rebootTime = "04:30" (next day window: reboot scheduled via `shutdown -r`); }`.

Run (systemd oneshot, `Persistent=true`, `RandomizedDelaySec=30m`,
`MemoryMax` generous but bounded, nice/ionice idle; state in
`/var/lib/rpi-pull/`):
1. Fetch pointer (curl, HTTPS, timeout, retries). Parse with jq.
2. Validate: `seq` > last applied seq; `storePath` matches
   `^/nix/store/[a-z0-9]{32}-nixos-system-neptun-[^/]*$`;
   `nix store verify --no-contents --store <cacheUrl> --trusted-public-keys <ours> <storePath>` succeeds
   (signature by our key only).
3. If `storePath` == `/run/current-system` → record seq, stop.
4. `nix-store -r <storePath>` with `max-substitution-jobs = 2`;
   compare `nix path-info --json` narHash with the pointer.
5. `nix-env -p /nix/var/nix/profiles/system --set <storePath>`.
6. Boot fingerprint (shared shell lib, Pi variant of `rl_fingerprint`):
   new vs `/run/booted-system`. Same → `switch-to-configuration switch`;
   differs → `switch-to-configuration boot` + `shutdown -r <rebootTime>`.
7. `sync`; write seq + storePath to state.
Failures before step 5 leave the Pi untouched; after step 5 the new
generation may be the boot default (same caveat as push deploys).

Manual deploys: `rpi-deploy deploy` keeps working. The pull job applies a
pointer only if its seq is newer than the last one applied, so a manual
deploy persists until the next CI build. `rpi-deploy status` also shows the
pull state (last seq, last run result via `systemctl show rpi-pull`).

### 3.5 Removed / changed

- Remove `rpi.buildHost.autoUpdate`, `rpi-autoupdate.sh`,
  `tests/autoupdate-unit.sh`, `eval-build-host` autoUpdate rows, the
  restricted auto-update key (`keys.autoUpdate`, `hostAddress`) and the
  `auto-update` branch logic in `rpi-deploy` (downgrade check now compares
  the working tree lock with `main`'s lock? → simplified: warn when the
  working tree lock is older than `origin/main`'s, if a remote exists).
- System name: drop the `sd-card` tag so the toplevel is
  `nixos-system-neptun-<version>` (spec §3 "one configuration" parity).

## 4. Testing

- Unit tests (mocked curl/nix/systemctl) for `rpi-pull`: invalid JSON, seq
  not newer, wrong name, signature by another key, narHash mismatch,
  already current, switch vs boot+reboot decision, failure leaves profile
  untouched.
- Eval tests: Pi module defaults (timer, substituter, key, disabled without
  key/URL), toplevel name without `sd-card`.
- `actionlint` on the workflow (flake check); the workflow's shell steps call
  scripts in the repo (`nixos/ci/*.sh`) so they are unit-testable locally.
- `tests/pull-smoke.sh` (qemu, slow): local signed `file://` binary cache
  served over HTTP + pointer file → boot image → run `rpi-pull` → new
  generation active; tampered pointer (foreign key) refused.
- Real CI: first workflow run after the user creates repo + cache.

## 5. Acceptance

1. `nix flake check` passes (incl. actionlint, unit tests, eval tests).
2. pull-smoke passes: switch path and refused-tamper path.
3. After user setup: a `workflow_dispatch` run pushes, pins, commits the
   pointer; the Pi applies it at its next timer run (manual on hardware).

## 6. User actions (cannot be done by the agent)

Create the public GitHub repo and push; create the self-signed Cachix
cache; add `CACHIX_AUTH_TOKEN` and `CACHIX_SIGNING_KEY` secrets; put the
cache name/public key into `nixos/keys.nix`; set `rpi.pull.pointerUrl`.

## 7. Risks

- GitHub account/secrets compromise = deploy to the Pi (same level as the
  root SSH key today).
- Cachix SaaS dependency; free tier LRU (pins mitigate).
- Undocumented pin API is not used by the Pi (pointer comes from git).
- Unbootable kernel: as before, no automatic fallback.
