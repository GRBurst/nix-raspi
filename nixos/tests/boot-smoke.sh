#!/usr/bin/env bash
#
# boot-smoke.sh — boot the EXACT SD image you are about to flash in qemu's
# Raspberry Pi 3B model, without root and without touching the card.
#
#   tests/boot-smoke.sh IMAGE.img.zst [--wait SECONDS] [--keep]
#
# What it proves, in this order:
#   1. the vendor kernel boots, the initrd finds the root file system by label,
#      stage-2 systemd runs and the first-boot partition expansion works;
#   2. userspace is up and reachable: sshd answers with an "SSH-2.0" banner
#      through a usb-net NIC (static 192.168.100.20, forwarded to
#      127.0.0.1:<random port>) within 300 s of the expansion. This is the
#      hard userspace criterion: the image is headless, there may be no HDMI
#      console on a real Pi and the screenshot below is informational only;
#   3. a framebuffer screenshot (qemu monitor) is saved; expect
#      "neptun login:" (qemu emulates a framebuffer the real Pi lacks).
# What it can NOT cover: the GPU firmware / U-Boot stage, config.txt, real
# hardware (qemu has no VideoCore). The banner check does not log in; the
# login path is tests/deploy-smoke.sh.
#
# Helpers are in tests/qemu-pi.sh (shared with deploy-smoke.sh). Direct kernel
# boot skips U-Boot, and the Pi 3's PL011 UART is claimed by Bluetooth, so
# kernel output is only visible through the early console (earlycon=pl011).
#
# Takes ~4-7 min (qemu TCG is ~5x slower than a real Pi 3).
# Env: RPI_SMOKE_DIR (work dir, default ./.scratch/smoke), RPI_QEMU,
#      RPI_SMOKE_SSH_WAIT (banner timeout, default 300),
#      RPI_SMOKE_GUEST_SSH_PORT (guest sshd port, default 2222).
# Exit status: 0 = expansion seen and SSH reachable (screenshot saved),
#              1 = failed / timed out, 2 = usage or missing tool.

set -euo pipefail

# shellcheck source=qemu-pi.sh
source "$(dirname "${BASH_SOURCE[0]}")/qemu-pi.sh"

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
[[ -f "$IMG_ZST" ]] || { echo "usage: $0 IMAGE.img.zst [--wait SECONDS] [--keep]" >&2; exit 2; }

qp_need zstd sfdisk debugfs mcopy
qp_find_qemu || { echo "error: no qemu-system-aarch64 with -M raspi3b (set RPI_QEMU, or: nix shell nixpkgs#qemu)" >&2; exit 2; }

WORK="${RPI_SMOKE_DIR:-$PWD/.scratch/smoke}"
FWD="$(qp_free_port)"
qp_unpack "$IMG_ZST" "$WORK"
qp_boot "$WORK" "$FWD"
trap 'qp_stop; [[ "$KEEP" -eq 1 ]] || rm -f "$WORK/card.img" "$WORK/Image" "$WORK/initrd"' EXIT

# 1. stage 2 reached + root found by label + first-boot expansion done
START=$SECONDS
qp_wait_serial 'EXT4-fs (mmcblk0p2): resized filesystem' "$WAIT" || { echo "FAIL: $QP_WHY" >&2; exit 1; }
echo "==> root mounted by label and expanded after $((SECONDS - START))s of waiting"

# 2. sshd answers behind the usb-net forward
SSH_WAIT="${RPI_SMOKE_SSH_WAIT:-300}"
echo "==> waiting up to ${SSH_WAIT}s for the SSH banner on 127.0.0.1:$FWD (usb-net)"
START=$SECONDS
qp_wait_ssh_banner "$FWD" "$SSH_WAIT" || { echo "FAIL: $QP_WHY" >&2; exit 1; }
echo "==> $QP_BANNER after $((SECONDS - START))s of waiting"

# 3. informational: the console, once getty had time to start
echo "==> taking a screenshot"
sleep 20
if qp_screenshot "$WORK/shot.png"; then
  echo "==> screenshot: $WORK/shot.png (expected: '<<< Welcome to NixOS ... >>>' and 'neptun login:')"
else
  echo "warning: no screenshot was written" >&2
fi
echo "PASS (stage 2 reached, root expanded, SSH reachable on 127.0.0.1:$FWD)"
