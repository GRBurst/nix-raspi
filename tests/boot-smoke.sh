#!/usr/bin/env bash
#
# boot-smoke.sh — boot the EXACT SD image you are about to flash in qemu's
# Raspberry Pi 3B model, without root and without touching the card.
#
#   tests/boot-smoke.sh IMAGE.img.zst [--wait SECONDS] [--keep]
#
# What it proves: the vendor kernel boots, the initrd finds the root file system
# by label, stage-2 systemd runs, the first-boot partition expansion works, and
# (screenshot) getty shows the login prompt. What it can NOT cover: the GPU
# firmware / U-Boot stage, wifi, real hardware (qemu has no VideoCore).
#
# Direct kernel boot differs from the real Pi in one respect: the firmware's
# device-tree fixups are missing, and the Pi 3's PL011 UART is claimed by
# Bluetooth, so kernel output is only visible through the early console
# (earlycon=pl011). Userspace output goes to the framebuffer, hence the
# screenshot via the qemu monitor (inspect it: expect "neptun login:").
#
# Takes ~6 min (qemu TCG is ~5x slower than a real Pi 3).
# Exit status: 0 = stage-2 reached and the card was expanded (screenshot saved),
#              1 = failed / timed out, 2 = usage or missing tool.

set -euo pipefail

WAIT=420
KEEP=0
IMG_ZST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait) WAIT="$2"; shift ;;
    --keep) KEEP=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    -*) echo "error: unknown argument: $1" >&2; exit 2 ;;
    *) IMG_ZST="$1" ;;
  esac
  shift
done
[[ -f "$IMG_ZST" ]] || { echo "usage: $0 IMAGE.img.zst [--wait SECONDS] [--keep]" >&2; exit 2; }

for t in zstd sfdisk debugfs mcopy; do
  command -v "$t" >/dev/null 2>&1 || { echo "error: missing tool: $t" >&2; exit 2; }
done

# qemu-system-aarch64 with the Pi 3B machine: PATH first, then any in the store.
QEMU="${RPI_QEMU:-}"
if [[ -z "$QEMU" ]]; then
  for c in "$(command -v qemu-system-aarch64 || true)" /nix/store/*-qemu-*/bin/qemu-system-aarch64; do
    [[ -x "$c" ]] && "$c" -M help 2>/dev/null | grep -q '^raspi3b' && { QEMU="$c"; break; }
  done
fi
[[ -n "$QEMU" ]] || { echo "error: no qemu-system-aarch64 with -M raspi3b (set RPI_QEMU, or: nix shell nixpkgs#qemu)" >&2; exit 2; }

WORK="${RPI_SMOKE_DIR:-$PWD/.scratch/smoke}"
mkdir -p "$WORK"
cd "$WORK"
rm -f card.img serial.log shot.png qemu.pid

echo "==> unpacking $IMG_ZST (sparse)"
zstd -d -q -f --sparse "$IMG_ZST" -o card.img
chmod u+w card.img

# partition geometry (sectors of 512 B)
read -r P1 P2 < <(sfdisk -d card.img | awk '/start=/ { sub(",", "", $4); print $4 }' | paste -sd' ')
O1=$((P1 * 512)); O2=$((P2 * 512))

echo "==> extracting kernel, initrd, dtb and the kernel command line from the image"
K="$(debugfs -R 'ls /boot/nixos' "card.img?offset=$O2" 2>/dev/null | grep -o '[a-z0-9]*-linux_rpi[^ ]*-Image' | head -n1)"
I="$(debugfs -R 'ls /boot/nixos' "card.img?offset=$O2" 2>/dev/null | grep -o '[a-z0-9]*-initrd-linux_rpi[^ ]*-initrd' | head -n1)"
[[ -n "$K" && -n "$I" ]] || { echo "FAIL: no kernel/initrd under /boot/nixos in the image" >&2; exit 1; }
debugfs -R "dump /boot/nixos/$K Image" "card.img?offset=$O2" >/dev/null 2>&1
debugfs -R "dump /boot/nixos/$I initrd" "card.img?offset=$O2" >/dev/null 2>&1
mcopy -i "card.img@@$O1" ::bcm2710-rpi-3-b.dtb bcm2710-rpi-3-b.dtb
APPEND="$(debugfs -R 'cat /boot/extlinux/extlinux.conf' "card.img?offset=$O2" 2>/dev/null | sed -n 's/^  APPEND //p' | head -n1)"
[[ -n "$APPEND" ]] || { echo "FAIL: no APPEND line in extlinux.conf" >&2; exit 1; }
APPEND="$(printf '%s' "$APPEND" | sed 's/console=serial0,115200n8 console=tty1/console=ttyAMA0,115200n8 earlycon=pl011,0x3f201000/')"

# qemu's SD model needs a power-of-two size; also exercises the first-boot expansion
truncate -s 8G card.img

PORT=$((20000 + RANDOM % 20000))
echo "==> booting in qemu raspi3b ($QEMU), monitor on tcp:$PORT"
"$QEMU" -M raspi3b -kernel Image -initrd initrd -dtb bcm2710-rpi-3-b.dtb \
  -drive file=card.img,if=sd,format=raw -append "$APPEND" \
  -display none -monitor "tcp:127.0.0.1:$PORT,server,nowait" \
  -serial file:serial.log -serial null -nic none &
QPID=$!
trap 'kill "$QPID" 2>/dev/null || true; [[ "$KEEP" -eq 1 ]] || rm -f card.img Image initrd' EXIT

# 1. stage 2 reached + root found by label + first-boot expansion done
START=$SECONDS; OK=0
while (( SECONDS - START < WAIT )); do
  kill -0 "$QPID" 2>/dev/null || { echo "FAIL: qemu exited early" >&2; exit 1; }
  if grep -q 'EXT4-fs (mmcblk0p2): resized filesystem' serial.log 2>/dev/null; then OK=1; break; fi
  grep -q 'Kernel panic' serial.log 2>/dev/null && { echo "FAIL: kernel panic (see $WORK/serial.log)" >&2; exit 1; }
  sleep 5
done
[[ "$OK" -eq 1 ]] || { echo "FAIL: stage 2 / first-boot expansion not seen within ${WAIT}s (see $WORK/serial.log)" >&2; exit 1; }
echo "==> root mounted by label and expanded after $((SECONDS - START))s of waiting"

# 2. give services and getty time, then take a screenshot of the console
echo "==> waiting for getty, then taking a screenshot"
sleep 120
timeout 15 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT; printf 'screendump $WORK/shot.png -f png\n' >&3; sleep 3" || true
if [[ -s shot.png ]]; then
  echo "==> screenshot: $WORK/shot.png (expected: '<<< Welcome to NixOS ... >>>' and 'neptun login:')"
else
  echo "warning: no screenshot was written" >&2
fi
echo "PASS (stage 2 reached; check the screenshot for the login prompt)"
