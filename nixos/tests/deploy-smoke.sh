#!/usr/bin/env bash
#
# deploy-smoke.sh — prove the whole push-deploy path in qemu's raspi3b: build
# the Pi image with a THROWAWAY root key, boot it with a usb-net NIC, run
# `rpi-deploy deploy switch` against it and check that the new generation is
# the one running. No root, no real Pi, no real card.
#
#   tests/deploy-smoke.sh [--keep] [--boot-wait SECONDS]
#
# What it does (all under RPI_SMOKE_DIR, default ./.scratch/deploy-smoke):
#   1. ssh-keygen a throwaway ed25519 key (kept in the work dir: a re-run reuses
#      it and so the cached image).
#   2. A scratch flake (path:) on top of this checkout adds two systems:
#        smoke-image = rpi with the throwaway key as root's ONLY key
#        smoke-next  = smoke-image + /etc/rpi-smoke-marker ("next")
#      Both share the kernel, so the cache guard and the build guard behave
#      exactly as for the real Pi. The user's keys are not touched.
#   3. `rpi-deploy image` builds smoke-image's SD image (guards included).
#   4. Boot it (tests/qemu-pi.sh), wait for sshd behind the usb-net forward.
#   5. `rpi-deploy deploy switch --attr smoke-next --target root@127.0.0.1
#      --port <fwd>` with the flake's pinned nixos-rebuild.
#   6. Assert: the marker file reads "next", /run/current-system is smoke-next's
#      toplevel, and `rpi-deploy status` says "reboot pending: no".
#   7. `nixos-rebuild switch --rollback --target-host` (README section 5) brings
#      the image's system back and the marker disappears.
#
# The guards talk to the live nixos-raspberrypi cachix, so this needs network.
# The deploy output is timestamped (eval / build / copy / activation phases).
# Takes ~15-20 min warm (image cached), ~25-30 min with a cold image build
# (image ~10 min, boot to ssh ~2-4 min, first login until the guest has settled
# ~5 min, switch ~4 min, rollback ~3 min; qemu TCG is ~5x slower than a real
# Pi 3). Not part of `nix flake check`.
#
# Env: RPI_SMOKE_DIR, RPI_QEMU, RPI_DEPLOY (command used for rpi-deploy,
#      default: nix run this checkout's .#rpi-deploy), RPI_SMOKE_GUEST_SSH_PORT.
# Exit status: 0 = PASS, 1 = a check failed, 2 = usage or missing tool.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIXOS_DIR="$(dirname "$HERE")"
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

qp_need zstd sfdisk debugfs mcopy ssh ssh-keygen nix git
qp_find_qemu || { echo "error: no qemu-system-aarch64 with -M raspi3b (set RPI_QEMU, or: nix shell nixpkgs#qemu)" >&2; exit 2; }
REPO="$(git -C "$NIXOS_DIR" rev-parse --show-toplevel)" || { echo "error: $NIXOS_DIR is not in a git checkout" >&2; exit 2; }
SUBDIR="${NIXOS_DIR#"$REPO"/}"

WORK="${RPI_SMOKE_DIR:-$PWD/.scratch/deploy-smoke}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
FLAKE="$WORK/flake"
rm -rf "$FLAKE" "$WORK/known_hosts" "$WORK"/deploy*.log
mkdir -p "$FLAKE"

# nixos-rebuild runs its own `nix build` without --accept-flake-config; accept the
# flake's nixConfig (the nvmd cache) the same way the guards do. Without it nix
# asks (or, where ~/.local/share/nix is read-only, fails) about trusting it.
export NIX_CONFIG="accept-flake-config = true"

T0=$SECONDS
stage() { printf '==> [%4ds] %s\n' $((SECONDS - T0)) "$*"; }
fail() {
  echo "FAIL: $*" >&2
  # qemu's sdhost model reads synchronously: a stalled host (heavy disk I/O) shows up
  # as a guest-side "PIO read timeout" and a corrupted guest ext4, not as a bug of the tool
  if grep -qE 'I/O error, dev mmcblk0|EXT4-fs error' "$WORK/vm/serial.log" 2>/dev/null; then
    echo "note: the guest logged SD I/O errors (see $WORK/vm/serial.log): qemu under host I/O load; re-run on an idle host" >&2
  fi
  exit 1
}
# ts: prefix every line with the seconds since this stage started
ts() { local s=$SECONDS l; while IFS= read -r l; do printf '[%4ds] %s\n' $((SECONDS - s)) "$l"; done; }

trap 'qp_stop; [[ "$KEEP" -eq 1 ]] || rm -f "$WORK/vm/card.img" "$WORK/vm/Image" "$WORK/vm/initrd"' EXIT

# 1 + 2: throwaway key and the scratch flake
stage "throwaway key and scratch flake in $FLAKE"
# a key left over from an earlier run is reused: same key = same image derivation = no rebuild
[[ -f "$WORK/key" && -f "$WORK/key.pub" ]] || { rm -f "$WORK/key" "$WORK/key.pub"; ssh-keygen -q -t ed25519 -N '' -C rpi-deploy-smoke -f "$WORK/key"; }
PUB="$(cat "$WORK/key.pub")"
cat >"$FLAKE/flake.nix" <<EOF
{
  # same binary cache as the real flake (nixConfig is only read from the top flake)
  nixConfig = {
    extra-substituters = [ "https://nixos-raspberrypi.cachix.org" ];
    extra-trusted-public-keys = [ "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI=" ];
  };
  inputs.rpi.url = "git+file://$REPO?dir=$SUBDIR";
  outputs = { self, rpi }: let
    smoke-image = rpi.nixosConfigurations.rpi.extendModules {
      modules = [ ({ lib, ... }: {
        users.users.root.openssh.authorizedKeys.keys = lib.mkForce [ "$PUB" ];
      }) ];
    };
    smoke-next = smoke-image.extendModules {
      modules = [ { environment.etc."rpi-smoke-marker".text = "next\n"; } ];
    };
  in {
    nixosConfigurations = { inherit smoke-image smoke-next; };
    apps = rpi.apps;
    packages = rpi.packages;
  };
}
EOF
# path: scheme, so that untracked files in the scratch dir are visible (E3)
SF="path:$FLAKE"

if [[ -n "${RPI_DEPLOY:-}" ]]; then
  read -ra DEPLOY <<<"$RPI_DEPLOY"
else
  DEPLOY=(nix run --accept-flake-config "$NIXOS_DIR#rpi-deploy" --)
fi

# 3: build the image of smoke-image through the real tool (cache + build guards)
stage "rpi-deploy image (smoke-image)"
"${DEPLOY[@]}" image --flake "$SF" --attr smoke-image --out "$WORK" 2>&1 | ts | tee "$WORK/deploy-image.log" |
  grep -E '^\[ *[0-9]+s\] (==>|image:|size:|rpi-deploy:|guard)' || true
IMG="$(find "$WORK/result-rpi-image/sd-image/" -name '*.img.zst' 2>/dev/null | head -n1)"
[[ -n "$IMG" ]] || fail "no image was built (see $WORK/deploy-image.log)"
stage "image: $IMG"

# 4: boot with usb-net, wait for sshd
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
# make every ssh connection crawl under qemu TCG: deploy only into a settled system
state=""
for _ in $(seq 1 60); do
  state="$(timeout 150 ssh -p "$FWD" "${SSH_OPTS[@]}" root@127.0.0.1 systemctl is-system-running 2>/dev/null || true)"
  [[ "$state" == running || "$state" == degraded ]] && break
  sleep 10
done
[[ "$state" == running || "$state" == degraded ]] || fail "the guest did not settle (systemctl is-system-running: '$state')"
stage "guest settled ($state; failed units: $(timeout 150 ssh -p "$FWD" "${SSH_OPTS[@]}" root@127.0.0.1 systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd' ' || true))"
BEFORE="$(gssh readlink /run/current-system)"
gssh test ! -e /etc/rpi-smoke-marker || fail "the marker exists before the deploy"
stage "logged in; running system: $BEFORE"

# 5: deploy smoke-next with the flake's pinned nixos-rebuild
stage "rpi-deploy deploy switch (smoke-next)"
export RPI_SSH_OPTS="${SSH_OPTS[*]}"
"${DEPLOY[@]}" deploy switch --flake "$SF" --attr smoke-next --target root@127.0.0.1 --port "$FWD" \
  2>&1 | ts | tee "$WORK/deploy-switch.log" || fail "rpi-deploy deploy switch failed (see $WORK/deploy-switch.log)"
stage "deploy finished"

# 6: the new generation is the running one
WANT_MARKER="next"
GOT_MARKER="$(gssh cat /etc/rpi-smoke-marker 2>/dev/null || true)"
[[ "$GOT_MARKER" == "$WANT_MARKER" ]] || fail "marker: expected '$WANT_MARKER', the guest says '$GOT_MARKER'"
WANT_SYS="$(nix eval --accept-flake-config --raw "$SF#nixosConfigurations.smoke-next.config.system.build.toplevel.outPath")"
GOT_SYS="$(gssh readlink /run/current-system)"
[[ "$GOT_SYS" == "$WANT_SYS" ]] || fail "current system: expected $WANT_SYS, the guest runs $GOT_SYS"
[[ "$GOT_SYS" != "$BEFORE" ]] || fail "the guest still runs the image's system $BEFORE"
STATUS="$("${DEPLOY[@]}" status --target root@127.0.0.1 --port "$FWD")" || fail "rpi-deploy status failed"
printf '%s\n' "$STATUS"
grep -qx 'reboot pending: no' <<<"$STATUS" || fail "rpi-deploy status does not say 'reboot pending: no'"
stage "failed units in the guest (informational): $(gssh systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd' ' || true)"

# 7: the userspace rollback documented in the README (section 5)
stage "nixos-rebuild switch --rollback (README: userspace regression)"
NIX_SSHOPTS="-p $FWD ${SSH_OPTS[*]}" nix run --accept-flake-config "$SF#nixos-rebuild" -- \
  switch --rollback --no-reexec --target-host root@127.0.0.1 \
  2>&1 | ts | tee "$WORK/deploy-rollback.log" || fail "the rollback failed (see $WORK/deploy-rollback.log)"
GOT_SYS="$(gssh readlink /run/current-system)"
[[ "$GOT_SYS" == "$BEFORE" ]] || fail "after the rollback the guest runs $GOT_SYS, expected $BEFORE"
gssh test ! -e /etc/rpi-smoke-marker || fail "the marker survived the rollback"

echo "PASS (deploy switch applied smoke-next: marker '$GOT_MARKER', new system running, no reboot pending; rollback restored the image system; $((SECONDS - T0))s total; logs $WORK/deploy-*.log)"
