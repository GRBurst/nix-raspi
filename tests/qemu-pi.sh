# shellcheck shell=bash
#
# qemu-pi.sh — shared helpers to boot the exact SD image in qemu's Raspberry
# Pi 3B model (-M raspi3b), without root and without touching a card. Sourced
# by boot-smoke.sh, deploy-smoke.sh and pull-smoke.sh; defines functions only.
#
#   qp_need TOOL...           exit 2 unless every TOOL is on the PATH
#   qp_find_qemu              set QEMU (RPI_QEMU, PATH, or the store); 1 if none
#   qp_free_port              print an unused TCP port on 127.0.0.1
#   qp_unpack IMG.zst WORK    unpack the image to WORK/card.img (8 GiB), extract
#                             WORK/{Image,initrd,bcm2710-rpi-3-b.dtb}; sets APPEND
#   qp_boot WORK [FWD_PORT]   start qemu in the background (QPID, QP_MONPORT);
#                             with FWD_PORT the guest gets a usb-net NIC whose
#                             sshd (RPI_SMOKE_GUEST_IP, RPI_SMOKE_GUEST_SSH_PORT)
#                             is forwarded to 127.0.0.1:FWD_PORT, without it
#                             no network at all
#   qp_wait_serial RE SECS    wait for RE in WORK/serial.log (0 found, 1 timeout,
#                             2 qemu exited, 3 kernel panic; reason in QP_WHY)
#   qp_wait_ssh_banner PORT SECS
#                             wait for "SSH-2.0" on 127.0.0.1:PORT (0 / 1 timeout /
#                             2 qemu exited; banner in QP_BANNER)
#   qp_screenshot FILE        framebuffer screendump through the qemu monitor
#   qp_stop                   kill qemu
#
# Direct kernel boot differs from the real Pi in one respect: the firmware's
# device-tree fixups are missing, and the Pi 3's PL011 UART is claimed by
# Bluetooth, so kernel output is only visible through the early console
# (earlycon=pl011); qp_unpack rewrites the kernel command line accordingly.
# What qemu cannot cover: the GPU firmware / U-Boot stage, real hardware.
#
# Env: RPI_QEMU (qemu-system-aarch64 with -M raspi3b),
#      RPI_SMOKE_GUEST_SSH_PORT (guest sshd port behind the forward, default
#      2222 = neptun; set it wrong on purpose to see the SSH checks fail),
#      RPI_SMOKE_GUEST_IP (guest address the forward targets, default
#      192.168.100.20 = neptun's static address in qemu's 192.168.100.0/24;
#      set but empty: the first DHCP lease of qemu's user-net, for a guest in
#      DHCP mode such as the template's default host).
#
# NOTE for callers talking to the guest with ssh: the host's system
# ssh_config may include files owned by other uids in this sandbox ("Bad
# owner or permissions", E3). Use `ssh -F /dev/null`.

# Globals (read by the sourcing scripts, hence the SC2034 waiver).
# shellcheck disable=SC2034
QEMU="${QEMU:-}" QPID="" QP_MONPORT="" QP_WORK="" QP_WHY="" QP_BANNER="" APPEND=""

qp_need() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || { echo "error: missing tool: $t" >&2; exit 2; }
  done
}

# qemu-system-aarch64 with the Pi 3B machine: RPI_QEMU, then PATH, then any in the store.
qp_find_qemu() {
  local c
  QEMU="${RPI_QEMU:-}"
  if [[ -z "$QEMU" ]]; then
    for c in "$(command -v qemu-system-aarch64 || true)" /nix/store/*-qemu-*/bin/qemu-system-aarch64; do
      if [[ -x "$c" ]] && "$c" -M help 2>/dev/null | grep -q '^raspi3b'; then QEMU="$c"; break; fi
    done
  fi
  [[ -n "$QEMU" ]]
}

qp_free_port() {
  local p
  while :; do
    p=$((20000 + RANDOM % 20000))
    # a successful connect means something listens there
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then echo "$p"; return 0; fi
  done
}

# qp_unpack IMG_ZST WORK
qp_unpack() {
  local img="$1" o1 o2 p1 p2 k i
  mkdir -p "$2"
  QP_WORK="$(cd "$2" && pwd)"
  rm -f "$QP_WORK/card.img" "$QP_WORK/serial.log" "$QP_WORK/shot.png" "$QP_WORK/qemu.pid"

  echo "==> unpacking $img (sparse)"
  zstd -d -q -f --sparse "$img" -o "$QP_WORK/card.img"
  chmod u+w "$QP_WORK/card.img"

  # partition geometry (sectors of 512 B)
  read -r p1 p2 < <(sfdisk -d "$QP_WORK/card.img" | awk '/start=/ { sub(",", "", $4); print $4 }' | paste -sd' ')
  o1=$((p1 * 512)); o2=$((p2 * 512))

  echo "==> extracting kernel, initrd, dtb and the kernel command line from the image"
  k="$(debugfs -R 'ls /boot/nixos' "$QP_WORK/card.img?offset=$o2" 2>/dev/null | grep -o '[a-z0-9]*-linux_rpi[^ ]*-Image' | head -n1)"
  i="$(debugfs -R 'ls /boot/nixos' "$QP_WORK/card.img?offset=$o2" 2>/dev/null | grep -o '[a-z0-9]*-initrd-linux_rpi[^ ]*-initrd' | head -n1)"
  [[ -n "$k" && -n "$i" ]] || { echo "FAIL: no kernel/initrd under /boot/nixos in the image" >&2; exit 1; }
  debugfs -R "dump /boot/nixos/$k $QP_WORK/Image" "$QP_WORK/card.img?offset=$o2" >/dev/null 2>&1
  debugfs -R "dump /boot/nixos/$i $QP_WORK/initrd" "$QP_WORK/card.img?offset=$o2" >/dev/null 2>&1
  mcopy -i "$QP_WORK/card.img@@$o1" ::bcm2710-rpi-3-b.dtb "$QP_WORK/bcm2710-rpi-3-b.dtb"
  APPEND="$(debugfs -R 'cat /boot/extlinux/extlinux.conf' "$QP_WORK/card.img?offset=$o2" 2>/dev/null | sed -n 's/^  APPEND //p' | head -n1)"
  [[ -n "$APPEND" ]] || { echo "FAIL: no APPEND line in extlinux.conf" >&2; exit 1; }
  APPEND="$(printf '%s' "$APPEND" | sed 's/console=serial0,115200n8 console=tty1/console=ttyAMA0,115200n8 earlycon=pl011,0x3f201000/')"

  # qemu's SD model needs a power-of-two size; also exercises the first-boot expansion
  truncate -s 8G "$QP_WORK/card.img"
}

# qp_boot WORK [FWD_PORT]
qp_boot() {
  local work fwd="${2:-}" gip="${RPI_SMOKE_GUEST_IP-192.168.100.20}" fwdspec netdev
  local -a net
  work="$(cd "$1" && pwd)"
  QP_WORK="$work"
  QP_MONPORT="$(qp_free_port)"
  if [[ -n "$fwd" ]]; then
    # an empty guest address makes slirp forward to its first DHCP lease (192.168.100.15)
    fwdspec="tcp:127.0.0.1:$fwd-$gip:${RPI_SMOKE_GUEST_SSH_PORT:-2222}"
    netdev="user,id=n0,net=192.168.100.0/24,host=192.168.100.1,hostfwd=$fwdspec"
    net=(-netdev "$netdev" -device "usb-net,netdev=n0")
  else
    net=(-nic none)
  fi
  rm -f "$work/serial.log"
  echo "==> booting in qemu raspi3b ($QEMU), monitor on tcp:$QP_MONPORT${fwd:+, guest sshd forwarded to 127.0.0.1:$fwd}"
  "$QEMU" -M raspi3b -kernel "$work/Image" -initrd "$work/initrd" -dtb "$work/bcm2710-rpi-3-b.dtb" \
    -drive "file=$work/card.img,if=sd,format=raw" -append "$APPEND" \
    -display none -monitor "tcp:127.0.0.1:$QP_MONPORT,server,nowait" \
    -serial "file:$work/serial.log" -serial null "${net[@]}" >"$work/qemu.out" 2>&1 &
  QPID=$!
  echo "$QPID" >"$work/qemu.pid"
}

qp_stop() {
  [[ -z "$QPID" ]] || kill "$QPID" 2>/dev/null || true
}

# qp_wait_serial REGEX SECONDS
qp_wait_serial() {
  local re="$1" secs="$2" start=$SECONDS
  while ((SECONDS - start < secs)); do
    if ! kill -0 "$QPID" 2>/dev/null; then QP_WHY="qemu exited early"; return 2; fi
    if grep -q -- "$re" "$QP_WORK/serial.log" 2>/dev/null; then return 0; fi
    if grep -q 'Kernel panic' "$QP_WORK/serial.log" 2>/dev/null; then
      QP_WHY="kernel panic (see $QP_WORK/serial.log)"; return 3
    fi
    sleep 5
  done
  QP_WHY="'$re' not seen within ${secs}s (see $QP_WORK/serial.log)"
  return 1
}

# qp_wait_ssh_banner PORT SECONDS: reads the banner with bash's /dev/tcp, no
# ssh client involved. qemu accepts the forwarded connection before the guest
# listens and then drops it, so only a line starting with SSH-2.0 counts.
qp_wait_ssh_banner() {
  local port="$1" secs="$2" start=$SECONDS line
  while ((SECONDS - start < secs)); do
    if ! kill -0 "$QPID" 2>/dev/null; then QP_WHY="qemu exited early"; return 2; fi
    line="$(timeout 8 bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1"; IFS= read -r -t 6 l <&3; printf "%s" "$l"' _ "$port" 2>/dev/null || true)"
    if [[ "$line" == SSH-2.0-* ]]; then QP_BANNER="${line%$'\r'}"; return 0; fi
    sleep 3
  done
  QP_WHY="no SSH banner on 127.0.0.1:$port within ${secs}s (see $QP_WORK/serial.log)"
  return 1
}

# qp_screenshot FILE
qp_screenshot() {
  timeout 15 bash -c "exec 3<>/dev/tcp/127.0.0.1/$QP_MONPORT; printf 'screendump $1 -f png\n' >&3; sleep 3" || true
  [[ -s "$1" ]]
}
