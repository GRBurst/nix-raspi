#!/usr/bin/env bash
#
# pull-smoke.sh — prove rpi-pull end to end in qemu's raspi3b: build the Pi
# image with a THROWAWAY root key and a throwaway cache key, serve a signed
# binary cache and a pointer over HTTP from this host, boot the image and let
# its own rpi-pull.service apply the pointer (the switch path), then show that
# a pointer to a system signed by a foreign key is refused. No root, no real
# Pi, no real card, no GitHub, no Cachix.
#
#   tests/pull-smoke.sh [--keep] [--boot-wait SECONDS]
#
# What it does (all under RPI_SMOKE_DIR, default ./.scratch/pull-smoke):
#   1. ssh-keygen a throwaway ed25519 key; `nix key generate-secret` a cache
#      key (pull-smoke-1) and a foreign one (pull-smoke-evil-1). Kept in the
#      work dir: a re-run reuses them and so the cached image.
#   2. A scratch flake (path:) on top of this checkout adds three systems:
#        smoke-image = rpi with the throwaway root key (the ONLY key) and
#                      rpi.pull pointed at http://192.168.100.1:PORT (the
#                      qemu host alias) with the throwaway cache key, timer
#                      yearly (it must not fire during the test)
#        smoke-next  = smoke-image + /etc/rpi-smoke-marker "next" + a changed
#                      rpi-pull unit (SMOKE=next): the switch must neither
#                      restart nor kill the unit that runs it
#        smoke-evil  = smoke-image + marker "evil"
#   3. `rpi-deploy image` builds smoke-image's SD image (guards included);
#      smoke-next and smoke-evil are built as toplevels.
#   4. The cache: `nix copy` of the FULL closure of smoke-next signed with the
#      cache key, then of smoke-evil signed with the foreign key (paths that
#      are already there are skipped: only smoke-evil's own paths carry the
#      foreign signature), compression none, Priority 10. The pointer is
#      ci/pointer.sh --seq 1 -> smoke-next. busybox httpd (from the flake's
#      pinned nixpkgs) serves both on 127.0.0.1:PORT.
#   5. Boot (tests/qemu-pi.sh), wait for sshd, log in, wait until it settled.
#   6. Switch path: `systemctl start rpi-pull.service` in the guest -> exit 0;
#      the guest runs smoke-next (current-system, system profile, marker,
#      seq 1, changed unit file), `rpi-deploy status` says "pull applied:
#      seq 1" and "reboot pending: no".
#   7. Tamper path: pointer seq 2 -> smoke-evil: the unit fails with exit 32
#      (untrusted), the guest still runs smoke-next, seq stays 1, smoke-evil
#      was never realised in the guest.
#
# RPI_PULL_SMOKE_PLANT=1 plants a violation: smoke-next is signed with the
# foreign key instead. The run must then FAIL at step 6 with "rpi-pull did not
# apply smoke-next" (the guest journal shows "untrusted").
#
# Needs network for the guards (live nixos-raspberrypi cachix). Disk: the
# cache is the full closure (~4 GiB NAR), removed on exit unless --keep.
# Takes ~30-50 min cold (image ~10 min, cache copy ~5 min, boot to ssh ~2-4
# min, settle ~5 min, pull ~5-15 min under qemu TCG), ~15-25 min warm. Not
# part of `nix flake check`.
#
# Env: RPI_SMOKE_DIR, RPI_QEMU, RPI_DEPLOY (command used for rpi-deploy,
#      default: nix run this checkout's .#rpi-deploy), RPI_SMOKE_GUEST_SSH_PORT,
#      RPI_PULL_SMOKE_HTTP_PORT (default 18080; part of the image),
#      RPI_PULL_SMOKE_PLANT.
# Exit status: 0 = PASS, 1 = a check failed, 2 = usage or missing tool.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLAKE_DIR="$(dirname "$HERE")"
# shellcheck source=qemu-pi.sh
source "$HERE/qemu-pi.sh"

KEEP=0
BOOT_WAIT=900
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) KEEP=1 ;;
    --boot-wait) BOOT_WAIT="$2"; shift ;;
    -h|--help) sed -n '2,/^$/p' "$0"; exit 0 ;;
    *) echo "usage: $0 [--keep] [--boot-wait SECONDS]" >&2; exit 2 ;;
  esac
  shift
done

qp_need zstd sfdisk debugfs mcopy ssh ssh-keygen nix git jq curl
qp_find_qemu || { echo "error: no qemu-system-aarch64 with -M raspi3b (set RPI_QEMU, or: nix shell nixpkgs#qemu)" >&2; exit 2; }
REPO="$(git -C "$FLAKE_DIR" rev-parse --show-toplevel)" || { echo "error: $FLAKE_DIR is not in a git checkout" >&2; exit 2; }
[[ "$(cd "$FLAKE_DIR" && pwd -P)" == "$REPO" ]] || { echo "error: $FLAKE_DIR is not the top of its git checkout ($REPO): run from the repository root" >&2; exit 2; }

PORT="${RPI_PULL_SMOKE_HTTP_PORT:-18080}"
PLANT="${RPI_PULL_SMOKE_PLANT:-0}"
HOST_IN_GUEST="192.168.100.1"   # qemu user-net alias of the host's 127.0.0.1

WORK="${RPI_SMOKE_DIR:-$PWD/.scratch/pull-smoke}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
FLAKE="$WORK/flake"
WWW="$WORK/www"
rm -rf "$FLAKE" "$WWW" "$WORK/known_hosts" "$WORK"/*.log "$WORK"/pull-*.out
mkdir -p "$FLAKE"

# nixos-rebuild-style `nix build`s below run without --accept-flake-config
# otherwise; accept the flake's nixConfig (the nvmd cache) the same way the
# guards do, or nix asks (or fails) about trusting it.
export NIX_CONFIG="accept-flake-config = true"

T0=$SECONDS
HTTPD=""
stage() { printf '==> [%4ds] %s\n' $((SECONDS - T0)) "$*"; }
# guest_journal: the unit's journal and exit state, best effort (the guest may be gone)
guest_journal() {
  [[ -n "${FWD:-}" ]] || return 0
  {
    echo "--- guest: systemctl status rpi-pull (after the last run)"
    timeout 150 ssh -p "$FWD" "${SSH_OPTS[@]}" root@127.0.0.1 \
      'systemctl show -p Result,ExecMainStatus rpi-pull.service; journalctl -u rpi-pull --no-pager -o cat | tail -n 60' 2>&1 || true
  } | tee "$WORK/guest-rpi-pull.log" >&2
}
fail() {
  echo "FAIL: $*" >&2
  # qemu's sdhost model reads synchronously: a stalled host (heavy disk I/O) shows up
  # as a guest-side "PIO read timeout" and a corrupted guest ext4, not as a bug of the tool
  if grep -qE 'I/O error, dev mmcblk0|EXT4-fs error|PIO read timeout' "$WORK/vm/serial.log" 2>/dev/null; then
    echo "note: the guest logged SD I/O errors (see $WORK/vm/serial.log): qemu under host I/O load; re-run once on an idle host" >&2
  fi
  exit 1
}
# ts: prefix every line with the seconds since this stage started
ts() { local s=$SECONDS l; while IFS= read -r l; do printf '[%4ds] %s\n' $((SECONDS - s)) "$l"; done; }

cleanup() {
  qp_stop
  [[ -z "$HTTPD" ]] || kill "$HTTPD" 2>/dev/null || true
  if [[ "$KEEP" -ne 1 ]]; then
    rm -f "$WORK/vm/card.img" "$WORK/vm/Image" "$WORK/vm/initrd"
    rm -rf "$WWW"
  fi
}
trap cleanup EXIT

# 1 + 2: throwaway keys and the scratch flake
stage "throwaway keys and scratch flake in $FLAKE"
# keys left over from an earlier run are reused: same keys = same image derivation = no rebuild
[[ -f "$WORK/key" && -f "$WORK/key.pub" ]] || { rm -f "$WORK/key" "$WORK/key.pub"; ssh-keygen -q -t ed25519 -N '' -C rpi-pull-smoke -f "$WORK/key"; }
PUB="$(cat "$WORK/key.pub")"
for k in cache:pull-smoke-1 evil:pull-smoke-evil-1; do
  n="${k%%:*}"
  [[ -s "$WORK/$n.sec" && -s "$WORK/$n.pub" ]] || {
    nix key generate-secret --key-name "${k#*:}" >"$WORK/$n.sec"
    nix key convert-secret-to-public <"$WORK/$n.sec" >"$WORK/$n.pub"
  }
done
CACHE_PUB="$(cat "$WORK/cache.pub")"
cat >"$FLAKE/flake.nix" <<EOF
{
  # same binary cache as the real flake (nixConfig is only read from the top flake)
  nixConfig = {
    extra-substituters = [ "https://nixos-raspberrypi.cachix.org" ];
    extra-trusted-public-keys = [ "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI=" ];
  };
  inputs.rpi.url = "git+file://$REPO";
  outputs = { self, rpi }: let
    smoke-image = rpi.nixosConfigurations.rpi.extendModules {
      modules = [ ({ lib, ... }: {
        users.users.root.openssh.authorizedKeys.keys = lib.mkForce [ "$PUB" ];
        # configuration.nix sets the production pointer: override all of it
        rpi.pull = {
          pointerUrl = lib.mkForce "http://$HOST_IN_GUEST:$PORT/neptun.json";
          cacheUrl = lib.mkForce "http://$HOST_IN_GUEST:$PORT/cache";
          cachePublicKey = lib.mkForce "$CACHE_PUB";
          onCalendar = lib.mkForce "yearly";
        };
      }) ];
    };
    smoke-next = smoke-image.extendModules {
      modules = [ {
        environment.etc."rpi-smoke-marker".text = "next\n";
        # a unit-changing delta: restartIfChanged = false is what keeps the switch from killing rpi-pull
        systemd.services.rpi-pull.environment.SMOKE = "next";
      } ];
    };
    smoke-evil = smoke-image.extendModules {
      modules = [ { environment.etc."rpi-smoke-marker".text = "evil\n"; } ];
    };
  in {
    nixosConfigurations = { inherit smoke-image smoke-next smoke-evil; };
    apps = rpi.apps;
    packages = rpi.packages;
  };
}
EOF
# path: scheme, so that untracked files in the scratch dir are visible
SF="path:$FLAKE"

if [[ -n "${RPI_DEPLOY:-}" ]]; then
  read -ra DEPLOY <<<"$RPI_DEPLOY"
else
  DEPLOY=(nix run --accept-flake-config "$FLAKE_DIR#rpi-deploy" --)
fi

# 3: the image of smoke-image through the real tool (cache + build guards), then the toplevels
stage "rpi-deploy image (smoke-image)"
"${DEPLOY[@]}" image --flake "$SF" --attr smoke-image --out "$WORK" 2>&1 | ts | tee "$WORK/deploy-image.log" |
  grep -E '^\[ *[0-9]+s\] (==>|image:|size:|rpi-deploy:|guard)' || true
IMG="$(find "$WORK/result-rpi-image/sd-image/" -name '*.img.zst' 2>/dev/null | head -n1)"
[[ -n "$IMG" ]] || fail "no image was built (see $WORK/deploy-image.log)"
stage "image: $IMG"

toplevel() { nix build --accept-flake-config --no-link --print-out-paths "$SF#nixosConfigurations.$1.config.system.build.toplevel"; }
stage "building the toplevels of smoke-next and smoke-evil"
IMG_TOP="$(nix eval --accept-flake-config --raw "$SF#nixosConfigurations.smoke-image.config.system.build.toplevel.outPath")"
NEXT="$(toplevel smoke-next)" || fail "cannot build smoke-next"
EVIL="$(toplevel smoke-evil)" || fail "cannot build smoke-evil"
[[ "$NEXT" == /nix/store/*-nixos-system-neptun-* && "$EVIL" == /nix/store/*-nixos-system-neptun-* ]] ||
  fail "unexpected toplevels: '$NEXT' '$EVIL'"
stage "image system $IMG_TOP; next $NEXT; evil $EVIL"

# 4: the signed cache (full closures) and the pointer, served by busybox httpd
SIGN_NEXT="$WORK/cache.sec"
if [[ "$PLANT" == 1 ]]; then
  SIGN_NEXT="$WORK/evil.sec"
  stage "PLANT: smoke-next is signed with the foreign key"
fi
mkdir -p "$WWW"
stage "nix copy: closure of smoke-next -> $WWW/cache"
{ nix copy --to "file://$WWW/cache?secret-key=$SIGN_NEXT&compression=none" "$NEXT" 2>&1 | ts | tail -n 3; } ||
  fail "nix copy of smoke-next failed"
stage "nix copy: closure of smoke-evil (foreign key; existing paths are skipped)"
{ nix copy --to "file://$WWW/cache?secret-key=$WORK/evil.sec&compression=none" "$EVIL" 2>&1 | ts | tail -n 3; } ||
  fail "nix copy of smoke-evil failed"
# nix-cache-info only has StoreDir: ours must win over cache.nixos.org (40) and nvmd's cache
grep -q '^Priority:' "$WWW/cache/nix-cache-info" || echo 'Priority: 10' >>"$WWW/cache/nix-cache-info"
grep -qx 'Priority: 10' "$WWW/cache/nix-cache-info" || fail "cannot set Priority: 10 in $WWW/cache/nix-cache-info"
# the pointer: GIT_CEILING_DIRECTORIES keeps pointer.sh from consulting this checkout's origin/main
GIT_CEILING_DIRECTORIES="$WORK" bash "$FLAKE_DIR/ci/pointer.sh" --seq 1 --rev smoke --file "$WWW/neptun.json" "$NEXT" >/dev/null ||
  fail "ci/pointer.sh failed for seq 1"
jq -c . "$WWW/neptun.json"

BUSYBOX="$(nix build --accept-flake-config --no-link --print-out-paths --inputs-from "$FLAKE_DIR" nixpkgs#busybox)"
[[ -x "$BUSYBOX/bin/busybox" ]] || fail "no busybox in '$BUSYBOX'"
if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
  fail "something already listens on 127.0.0.1:$PORT (set RPI_PULL_SMOKE_HTTP_PORT; the port is part of the image)"
fi
"$BUSYBOX/bin/busybox" httpd -f -p "127.0.0.1:$PORT" -h "$WWW" >"$WORK/httpd.log" 2>&1 &
HTTPD=$!
for _ in $(seq 1 20); do
  curl -sf "http://127.0.0.1:$PORT/neptun.json" >/dev/null && break
  kill -0 "$HTTPD" 2>/dev/null || fail "busybox httpd exited (see $WORK/httpd.log)"
  sleep 0.5
done
curl -sf "http://127.0.0.1:$PORT/cache/nix-cache-info" >/dev/null || fail "busybox httpd does not serve the cache on 127.0.0.1:$PORT"
stage "serving $WWW on 127.0.0.1:$PORT (guest: http://$HOST_IN_GUEST:$PORT)"

# 5: boot with usb-net, wait for sshd, log in, wait until the guest settled
stage "unpack and boot"
qp_unpack "$IMG" "$WORK/vm"
FWD="$(qp_free_port)"
qp_boot "$WORK/vm" "$FWD"
qp_wait_ssh_banner "$FWD" "$BOOT_WAIT" || fail "$QP_WHY"
stage "sshd answers on 127.0.0.1:$FWD ($QP_BANNER)"

SSH_OPTS=(-i "$WORK/key" -o IdentitiesOnly=yes -o "UserKnownHostsFile=$WORK/known_hosts"
          -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=120 -F /dev/null)
gssh() { ssh -p "$FWD" "${SSH_OPTS[@]}" root@127.0.0.1 "$@"; }
# sshd listens long before a login works: the first login after the first boot
# takes minutes under qemu TCG (hence the per-attempt timeout, not a short one)
up=0
for _ in $(seq 1 20); do
  if [[ "$(timeout 150 ssh -p "$FWD" "${SSH_OPTS[@]}" root@127.0.0.1 cat /etc/hostname 2>/dev/null || true)" == neptun ]]; then up=1; break; fi
  sleep 5
done
[[ "$up" -eq 1 ]] || fail "cannot log in as root with the throwaway key (see $WORK/vm/serial.log)"
# the first minutes after the first boot (store registration, resize, key generation)
# make every ssh connection crawl under qemu TCG: pull only into a settled system
state=""
for _ in $(seq 1 60); do
  state="$(timeout 150 ssh -p "$FWD" "${SSH_OPTS[@]}" root@127.0.0.1 systemctl is-system-running 2>/dev/null || true)"
  [[ "$state" == running || "$state" == degraded ]] && break
  sleep 10
done
[[ "$state" == running || "$state" == degraded ]] || fail "the guest did not settle (systemctl is-system-running: '$state')"
stage "guest settled ($state; failed units: $(timeout 150 ssh -p "$FWD" "${SSH_OPTS[@]}" root@127.0.0.1 systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd' ' || true))"
BEFORE="$(gssh readlink /run/current-system)"
[[ "$BEFORE" == "$IMG_TOP" ]] || echo "note: the guest runs $BEFORE, smoke-image evaluates to $IMG_TOP" >&2
[[ "$BEFORE" != "$NEXT" ]] || fail "the guest already runs smoke-next ($NEXT)"
gssh test ! -e /etc/rpi-smoke-marker || fail "the marker exists before the pull"
gssh test ! -e /var/lib/rpi-pull/seq || fail "/var/lib/rpi-pull/seq exists before the first pull"
# the host must be reachable under its qemu alias, or every pull fails with a fetch error
REPLY="$(gssh bash -c "'exec 3<>/dev/tcp/$HOST_IN_GUEST/$PORT && printf \"GET /neptun.json HTTP/1.0\\r\\n\\r\\n\" >&3 && head -n1 <&3'" || true)"
grep -q ' 200 ' <<<"$REPLY" ||
  fail "the guest cannot fetch http://$HOST_IN_GUEST:$PORT/neptun.json (qemu user-net host alias; got '$REPLY')"
stage "logged in; running system: $BEFORE; the pointer is reachable from the guest"

export RPI_SSH_OPTS="${SSH_OPTS[*]}"

# 6: the switch path: the unit applies seq 1 = smoke-next
stage "systemctl start rpi-pull.service (seq 1 -> smoke-next, switch)"
rc=0
gssh timeout 1800 systemctl start rpi-pull.service 2>&1 | ts | tee "$WORK/pull-1.out" || rc=${PIPESTATUS[0]}
[[ "$rc" -eq 0 ]] || { guest_journal; fail "rpi-pull did not apply smoke-next (systemctl start exited $rc)"; }
want() { # want WHAT EXPECTED GOT
  [[ "$3" == "$2" ]] || { guest_journal; fail "rpi-pull did not apply smoke-next: $1: expected '$2', the guest says '$3'"; }
}
want "current system" "$NEXT" "$(gssh readlink /run/current-system)"
want "system profile" "$NEXT" "$(gssh readlink -f /nix/var/nix/profiles/system)"
want "marker" "next" "$(gssh cat /etc/rpi-smoke-marker 2>/dev/null || true)"
want "applied seq" "1" "$(gssh cat /var/lib/rpi-pull/seq 2>/dev/null || true)"
want "unit exit status" "0" "$(gssh systemctl show -p ExecMainStatus --value rpi-pull.service)"
# the switch really changed the unit (and the unit survived it: rc 0 above)
UNIT="$(gssh systemctl cat rpi-pull.service || true)"
grep -q 'SMOKE=next' <<<"$UNIT" ||
  { guest_journal; fail "rpi-pull did not apply smoke-next: the rpi-pull unit in the guest has no SMOKE=next"; }
STATUS="$("${DEPLOY[@]}" status --target root@127.0.0.1 --port "$FWD")" || fail "rpi-deploy status failed"
printf '%s\n' "$STATUS"
grep -q '^pull applied: seq 1 ' <<<"$STATUS" || { guest_journal; fail "rpi-pull did not apply smoke-next: rpi-deploy status has no 'pull applied: seq 1'"; }
grep -qx 'reboot pending: no' <<<"$STATUS" || fail "rpi-pull did not apply smoke-next: rpi-deploy status does not say 'reboot pending: no'"
stage "seq 1 applied by switch: $NEXT"

# 7: the tamper path: seq 2 points at a system signed by a foreign key
stage "pointer seq 2 -> smoke-evil (foreign key); systemctl start rpi-pull.service"
GIT_CEILING_DIRECTORIES="$WORK" bash "$FLAKE_DIR/ci/pointer.sh" --seq 2 --rev evil --file "$WWW/neptun.json" "$EVIL" >/dev/null ||
  fail "ci/pointer.sh failed for seq 2"
rc=0
gssh timeout 1800 systemctl start rpi-pull.service 2>&1 | ts | tee "$WORK/pull-2.out" || rc=${PIPESTATUS[0]}
refused() { guest_journal; fail "tampered pointer was not refused: $*"; }
[[ "$rc" -ne 0 && "$rc" -ne 255 ]] || refused "systemctl start exited $rc (wanted a unit failure)"
want_refused() { # want_refused WHAT EXPECTED GOT
  [[ "$3" == "$2" ]] || refused "$1: expected '$2', the guest says '$3'"
}
want_refused "unit exit status" "32" "$(gssh systemctl show -p ExecMainStatus --value rpi-pull.service)"
want_refused "current system" "$NEXT" "$(gssh readlink /run/current-system)"
want_refused "system profile" "$NEXT" "$(gssh readlink -f /nix/var/nix/profiles/system)"
want_refused "applied seq" "1" "$(gssh cat /var/lib/rpi-pull/seq 2>/dev/null || true)"
want_refused "marker" "next" "$(gssh cat /etc/rpi-smoke-marker 2>/dev/null || true)"
# never realised: the guest does not know the path (nix-store exits 1; 255 would be ssh itself)
rc=0
gssh nix-store -q --hash "$EVIL" >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 && "$rc" -ne 255 ]] || refused "the guest has smoke-evil in its store (nix-store -q --hash exited $rc)"
STATUS="$("${DEPLOY[@]}" status --target root@127.0.0.1 --port "$FWD")" || fail "rpi-deploy status failed"
printf '%s\n' "$STATUS"
grep -q '^pull last run: untrusted (exit 32) ' <<<"$STATUS" || refused "rpi-deploy status has no 'pull last run: untrusted (exit 32)'"
stage "seq 2 refused (exit 32, untrusted)"

echo "PASS (pull applied seq 1 by switch; foreign-key pointer refused with exit 32; $((SECONDS - T0))s total; logs $WORK/*.log, $WORK/pull-*.out)"
