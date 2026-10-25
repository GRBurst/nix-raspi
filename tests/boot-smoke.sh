#!/usr/bin/env bash
#
# boot-smoke.sh — boot what a new user of the library gets: a Pi host made
# from the flake template, with defaults only (DHCP, sshd on port 22, radios
# off), in qemu's Raspberry Pi 3B model. No root, no real Pi, no real card.
#
#   tests/boot-smoke.sh [IMAGE.img.zst] [--wait SECONDS] [--keep]
#
# Without IMAGE the script builds one (all under RPI_SMOKE_DIR, default
# ./.scratch/smoke):
#   1. ssh-keygen a throwaway ed25519 key (kept in the work dir: a re-run
#      reuses it and so the cached image).
#   2. `nix flake init -t git+file://<this checkout>` in <work>/tpl, the
#      throwaway key as the ONLY entry of rpi.admin.sshKeys (the one edit a
#      user must make), `nix flake lock --override-input rpi <this checkout>`,
#      committed to its own git repo: the template's host `rpi`, nothing else.
#   3. `rpi-deploy image --flake git+file://<work>/tpl --host rpi` builds the
#      SD image (cache and build guards included).
# With IMAGE (a host you built yourself) the build and the login (step 3
# below) are skipped; tell the script where that host's sshd listens
# (RPI_SMOKE_GUEST_SSH_PORT, RPI_SMOKE_GUEST_IP).
#
# What it proves, in this order:
#   1. the vendor kernel boots, the initrd finds the root file system by label,
#      stage-2 systemd runs and the first-boot partition expansion works;
#   2. userspace is up and reachable: sshd answers with an "SSH-2.0" banner
#      through a usb-net NIC behind qemu's user-net within 600 s of the
#      expansion. The template host is in DHCP mode, so qemu's DHCP server
#      gives it the first lease and the forward targets that (qemu-pi.sh,
#      RPI_SMOKE_GUEST_IP empty), on the default port 22;
#   3. (built image only) the admin user `pi` logs in with the throwaway key
#      (the key the user adds in hosts/rpi.nix): host name `rpi`, the DHCP
#      lease (192.168.100.15/24) on the NIC, systemd settled, and getty@tty1
#      active, the service that shows the "rpi login:" prompt;
#   4. a framebuffer screenshot (qemu monitor) is saved, informational: it
#      shows "rpi login:". The prompt is only on the framebuffer, not on the
#      serial console, because the Pi 3's PL011 UART is claimed by Bluetooth
#      (so step 3 asks systemd instead of reading a log). qemu emulates a
#      framebuffer the real Pi lacks.
# What it can NOT cover: the GPU firmware / U-Boot stage, config.txt, real
# hardware (qemu has no VideoCore). The push-deploy login path on neptun
# (static address, port 2222) is tests/deploy-smoke.sh.
#
# Helpers are in tests/qemu-pi.sh (shared with deploy-smoke.sh and
# pull-smoke.sh). Direct kernel boot skips U-Boot, and the Pi 3's PL011 UART
# is claimed by Bluetooth, so kernel output is only visible through the early
# console (earlycon=pl011).
#
# Takes ~3-8 min with the image cached, ~10-15 min with a cold image build (the
# closure comes from the caches; measured: image 5.6 min, boot to sshd 0.5-4 min
# depending on the load of the host; qemu TCG is ~5x slower than a real Pi 3).
# Needs network for the guards (live nixos-raspberrypi cachix). Not part of
# `nix flake check`.
#
# Env: RPI_SMOKE_DIR (work dir), RPI_QEMU, RPI_DEPLOY (command used for
#      rpi-deploy, default: nix run this checkout's .#rpi-deploy),
#      RPI_SMOKE_SSH_WAIT (banner timeout, default 600),
#      RPI_SMOKE_GUEST_SSH_PORT (guest sshd port, default 22; set it wrong on
#      purpose, e.g. 2222, to see the SSH check fail),
#      RPI_SMOKE_GUEST_IP (default empty: the first DHCP lease).
# Exit status: 0 = expansion seen, SSH reachable, login worked,
#              1 = failed / timed out, 2 = usage or missing tool.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLAKE_DIR="$(dirname "$HERE")"
# shellcheck source=qemu-pi.sh
source "$HERE/qemu-pi.sh"

WAIT=420
KEEP=0
IMG_ZST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait) WAIT="$2"; shift ;;
    --keep) KEEP=1 ;;
    -h|--help) sed -n '2,/^$/p' "$0"; exit 0 ;;
    -*) echo "error: unknown argument: $1" >&2; exit 2 ;;
    *) IMG_ZST="$1" ;;
  esac
  shift
done
if [[ -n "$IMG_ZST" && ! -f "$IMG_ZST" ]]; then
  echo "usage: $0 [IMAGE.img.zst] [--wait SECONDS] [--keep]" >&2
  exit 2
fi
BUILT=0
[[ -n "$IMG_ZST" ]] || BUILT=1

# The template's default host: DHCP (first lease of qemu's user-net), sshd on 22.
export RPI_SMOKE_GUEST_IP="${RPI_SMOKE_GUEST_IP-}"
export RPI_SMOKE_GUEST_SSH_PORT="${RPI_SMOKE_GUEST_SSH_PORT:-22}"
HOSTNAME_WANT=rpi            # networking.hostName default (the template does not set one)
LEASE_WANT="192.168.100.15/24" # slirp's first DHCP lease in net=192.168.100.0/24

qp_need zstd sfdisk debugfs mcopy
qp_find_qemu || { echo "error: no qemu-system-aarch64 with -M raspi3b (set RPI_QEMU, or: nix shell nixpkgs#qemu)" >&2; exit 2; }

WORK="${RPI_SMOKE_DIR:-$PWD/.scratch/smoke}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
VM="$WORK/vm"

T0=$SECONDS
stage() { printf '==> [%4ds] %s\n' $((SECONDS - T0)) "$*"; }
fail() {
  echo "FAIL: $*" >&2
  # the console of a booted Pi 3 is the framebuffer: keep what it shows
  if [[ -n "$QPID" ]] && qp_screenshot "$VM/fail.png"; then echo "note: the console at the time of the failure: $VM/fail.png" >&2; fi
  exit 1
}
# ts: prefix every line with the seconds since this stage started
ts() { local s=$SECONDS l; while IFS= read -r l; do printf '[%4ds] %s\n' $((SECONDS - s)) "$l"; done; }

# Build the image of the template's default host (see the header).
build_template_image() {
  local repo tpl pub
  qp_need ssh-keygen nix git
  repo="$(git -C "$FLAKE_DIR" rev-parse --show-toplevel)" || { echo "error: $FLAKE_DIR is not in a git checkout" >&2; exit 2; }
  [[ "$(cd "$FLAKE_DIR" && pwd -P)" == "$repo" ]] || { echo "error: $FLAKE_DIR is not the top of its git checkout ($repo): run from the repository root" >&2; exit 2; }
  tpl="$WORK/tpl"
  rm -rf "$tpl" "$WORK"/deploy*.log
  mkdir -p "$tpl"

  # nix flake init / lock / eval read the flake's nixConfig (the nvmd cache); accept it
  # the way the rpi-deploy guards do, or nix asks (or, where ~/.local/share/nix is
  # read-only, fails) about trusting it.
  export NIX_CONFIG="accept-flake-config = true"

  stage "throwaway key and a template instance in $tpl"
  # a key left over from an earlier run is reused: same key = same image derivation = no rebuild
  [[ -f "$WORK/key" && -f "$WORK/key.pub" ]] || { rm -f "$WORK/key" "$WORK/key.pub"; ssh-keygen -q -t ed25519 -N '' -C rpi-boot-smoke -f "$WORK/key"; }
  pub="$(cat "$WORK/key.pub")"
  (
    cd "$tpl"
    nix flake init -t "git+file://$repo" >"$WORK/tpl-init.log" 2>&1 || { cat "$WORK/tpl-init.log" >&2; exit 1; }
    [[ -f hosts/rpi.nix ]] || { echo "the template has no hosts/rpi.nix" >&2; exit 1; }
    # the one edit a user must make: the key goes into the (empty) rpi.admin.sshKeys list
    sed -i "/rpi\.admin\.sshKeys = \[/a\\    \"$pub\"" hosts/rpi.nix
    grep -qF "$pub" hosts/rpi.nix || { echo "the key did not land in hosts/rpi.nix" >&2; exit 1; }
    git init -q .
    git add -A
    # the locked rpi input is this checkout (the published input does not exist yet / is not ours to test)
    nix flake lock --override-input rpi "git+file://$repo" >"$WORK/tpl-lock.log" 2>&1 || { cat "$WORK/tpl-lock.log" >&2; exit 1; }
    git add -A
    git -c user.name=smoke -c user.email=smoke@invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m "template instance"
  ) || fail "cannot build the template instance (logs: $WORK/tpl-*.log)"

  local -a deploy
  if [[ -n "${RPI_DEPLOY:-}" ]]; then
    read -ra deploy <<<"$RPI_DEPLOY"
  else
    deploy=(nix run --accept-flake-config "$FLAKE_DIR#rpi-deploy" --)
  fi
  stage "rpi-deploy image --host rpi (the template's default host)"
  "${deploy[@]}" image --flake "git+file://$tpl" --host rpi --out "$WORK" 2>&1 | ts | tee "$WORK/deploy-image.log" |
    grep -E '^\[ *[0-9]+s\] (==>|image:|size:|rpi-deploy:|guard)' || true
  IMG_ZST="$(find "$WORK/result-rpi-image/sd-image/" -name '*.img.zst' 2>/dev/null | head -n1)"
  [[ -n "$IMG_ZST" ]] || fail "no image was built (see $WORK/deploy-image.log)"
  stage "image: $IMG_ZST"
}

if [[ "$BUILT" -eq 1 ]]; then build_template_image; fi

FWD="$(qp_free_port)"
qp_unpack "$IMG_ZST" "$VM"
qp_boot "$VM" "$FWD"
trap 'qp_stop; [[ "$KEEP" -eq 1 ]] || rm -f "$VM/card.img" "$VM/Image" "$VM/initrd"' EXIT

# 1. stage 2 reached + root found by label + first-boot expansion done
START=$SECONDS
qp_wait_serial 'EXT4-fs (mmcblk0p2): resized filesystem' "$WAIT" || fail "$QP_WHY"
stage "root mounted by label and expanded after $((SECONDS - START))s of waiting"

# 2. sshd answers behind the usb-net forward
SSH_WAIT="${RPI_SMOKE_SSH_WAIT:-600}"
stage "waiting up to ${SSH_WAIT}s for the SSH banner on 127.0.0.1:$FWD (usb-net -> ${RPI_SMOKE_GUEST_IP:-first DHCP lease}:$RPI_SMOKE_GUEST_SSH_PORT)"
START=$SECONDS
qp_wait_ssh_banner "$FWD" "$SSH_WAIT" || fail "$QP_WHY"
stage "$QP_BANNER after $((SECONDS - START))s of waiting"

# 3. the admin user logs in with the key the user put into hosts/rpi.nix
GOT=""
if [[ "$BUILT" -eq 1 ]]; then
  qp_need ssh
  SSH_OPTS=(-i "$WORK/key" -o IdentitiesOnly=yes -o "UserKnownHostsFile=$WORK/known_hosts" -o StrictHostKeyChecking=accept-new
            -o BatchMode=yes -o ConnectTimeout=120 -F /dev/null)
  rm -f "$WORK/known_hosts"
  # one round trip, key=value lines; `is-system-running` waits for nothing, so retry until the guest settled
  REMOTE='echo "user=$(id -un)"; echo "host=$(cat /etc/hostname)"; echo "getty=$(systemctl is-active getty@tty1.service)"
          echo "state=$(systemctl is-system-running)"; echo "addr=$(ip -4 -o addr show scope global | awk "{print \$4}" | paste -sd,)"'
  for _ in $(seq 1 20); do
    GOT="$(timeout 150 ssh -p "$FWD" "${SSH_OPTS[@]}" pi@127.0.0.1 "$REMOTE" 2>/dev/null || true)"
    grep -qE '^state=(running|degraded)$' <<<"$GOT" && break
    sleep 10
  done
  want() { # want KEY EXPECTED-REGEX
    grep -qE "^$1=($2)\$" <<<"$GOT" || fail "login as pi: $1: expected /$2/, the guest says '$(sed -n "s/^$1=//p" <<<"$GOT")' (all: $(paste -sd' ' <<<"$GOT"))"
  }
  [[ -n "$GOT" ]] || fail "cannot log in as pi with the throwaway key (see $VM/serial.log)"
  want user pi
  want host "$HOSTNAME_WANT"
  want getty active
  want state 'running|degraded'
  if [[ -z "$RPI_SMOKE_GUEST_IP" ]]; then want addr ".*${LEASE_WANT//./\\.}.*"; fi
  stage "logged in as pi ($(paste -sd' ' <<<"$GOT"))"
fi

# 4. informational: the console, once getty had time to start
stage "taking a screenshot"
sleep 20
if qp_screenshot "$VM/shot.png"; then
  stage "screenshot: $VM/shot.png (informational; expected: '<<< Welcome to NixOS ... >>>' and '$HOSTNAME_WANT login:')"
else
  echo "warning: no screenshot was written" >&2
fi
if [[ "$BUILT" -eq 1 ]]; then
  echo "PASS (stage 2 reached, root expanded, SSH banner on port $RPI_SMOKE_GUEST_SSH_PORT via 127.0.0.1:$FWD, pi logged in on the DHCP lease, getty@tty1 up; $((SECONDS - T0))s total)"
else
  echo "PASS (stage 2 reached, root expanded, SSH banner on port $RPI_SMOKE_GUEST_SSH_PORT via 127.0.0.1:$FWD; $((SECONDS - T0))s total)"
fi
