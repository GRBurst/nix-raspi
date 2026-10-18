#!/usr/bin/env bash
#
# rpi-deploy — prepare an SD card, build the pi NixOS flake and install it.
#
# The key property: `build` works entirely from a local checkout of this
# repo, so the SD card does NOT have to be mounted (the pi can keep running)
# while a kernel/system build is in flight. `install` then takes the last
# built system and puts it onto the card.
#
# Card layout (2 partitions, MBR) — what `prepare --format` creates:
#
#   p1  256 MiB  FAT32  label NIXOS_BOOT  -> /boot/firmware  Pi firmware, config.txt, U-Boot
#   p2  rest     ext4   label NIXOS_SD    -> /               system, /boot (kernel, initrd, extlinux)
#
#   prepare    mount the card at <mount> (by label); with DEVICE --format:
#              partition + format a new card first (DESTROYS the device)
#   build      build from the local checkout, record the result
#   install    install the last recorded build + copy the config to
#              <mount>/etc/nixos (card must be prepared)
#   config     only copy the config checkout to <mount>/etc/nixos
#   eject      sync and unmount the card
#   all        build + install (default when no subcommand is given)
#   devices    list removable disks (candidates for prepare DEVICE) and card status
#   show       show the last build record and host/card status
#
# Usage: rpi-deploy.sh prepare [DEVICE] [--format] [-y|--yes] [--boot-size SIZE]
#        rpi-deploy.sh [build|install|config|eject|all|show|devices] [TARGET] [OPTIONS]
#   TARGET         root of the target NixOS system (default: /media/nixos)
#
# Options:
#   --flake PATH   path to the flake checkout (default: $RPI_FLAKE or $PWD)
#   --mount DIR    SD card mount point (default: /media/nixos)
#   --attr NAME    nixosConfigurations attribute (default: rpi)
#   --from PATH    (install) use this store path instead of the last build
#   --format       (prepare) partition + format DEVICE (destroys all data)
#   --boot-size S  (prepare --format) FAT partition size (default: 256MiB)
#   -y, --yes      answer yes to every confirmation: formatting, building the
#                  kernel locally, installing without any way to log in
#   --dry-run      print the heavy commands instead of executing them
#   -h, --help     show this help
#
# A build record is written to <flake>/.rpi-build/last so that a build
# performed while the card is absent can be installed later.

set -euo pipefail

# --- defaults ---------------------------------------------------------------
SUBCOMMAND=""
FLAKE="${RPI_FLAKE:-$PWD}"
MOUNT="/media/nixos"
MOUNT_SET=0
ATTR="rpi"
FROM=""
DEVICE=""
LABELS_CHANGED=0
DEV_MOUNTS=()
PART_SCRIPT=""
LOGIN_CONFIRMED=0
FORMAT=0
ASSUME_YES=0
BOOT_SIZE="256MiB"
POSITIONAL=()
DRY_RUN=0
# The card store and nixos-install need root; the build itself never does.
SUDO="sudo"; [[ "$EUID" -eq 0 ]] && SUDO=""
# Locations of binfmt registration state. Overridable via RPI_BINMFT_* so the
# preflight logic is unit-testable without real qemu/binfmt setup.
BINMFT_DIR="${RPI_BINMFT_DIR:-/proc/sys/fs/binfmt_misc}"
BINMFT_RUN="${RPI_BINMFT_RUN:-/run/binfmt}"
# Overridable so the firmware-partition check is unit-testable.
MOUNTPOINT_CMD="${RPI_MOUNTPOINT_CMD:-mountpoint -q}"
# More test hooks: where the by-label links live and whether DEVICE must be a
# real block device.
BYLABEL_DIR="${RPI_BYLABEL_DIR:-/dev/disk/by-label}"
ALLOW_NONBLOCK="${RPI_ALLOW_NONBLOCK:-0}"

usage() {
  cat <<'USAGE_EOF'
Usage: rpi-deploy prepare [DEVICE] [--format] [-y|--yes] [--boot-size SIZE]
       rpi-deploy [build|install|config|eject|all|show|devices] [TARGET] [OPTIONS]

  TARGET     root of the target NixOS system, e.g. /media/nixos
             (default: /media/nixos; same as --mount)

  prepare    mount the card at TARGET (found by its labels NIXOS_SD /
             NIXOS_BOOT). `prepare DEVICE --format` first creates the
             2-partition layout on a new card — DESTROYS everything on DEVICE.
             Without --format, DEVICE only gets its labels repaired:
               p1 256MiB FAT32 NIXOS_BOOT -> TARGET/boot/firmware
               p2 rest   ext4  NIXOS_SD   -> TARGET
  build      build from the local checkout (no SD card needed)
  install    install the last recorded build and copy the config checkout to
             TARGET/etc/nixos (card must be prepared)
  config     only copy the config checkout to TARGET/etc/nixos
  eject      sync and unmount the card
  all        build + install (default when no subcommand is given)
  devices    list removable disks (candidates for prepare DEVICE) and card status
  show       show the last build record and host/card status

Options:
  --flake PATH   path to the flake checkout (default: $RPI_FLAKE or $PWD)
  --mount DIR    SD card mount point (default: /media/nixos)
  --attr NAME    nixosConfigurations attribute (default: rpi)
  --from PATH    (install) use this store path instead of the last build
  --format       (prepare) partition + format DEVICE (destroys all data)
  --boot-size S  (prepare --format) FAT partition size (default: 256MiB)
  -y, --yes      answer yes to every confirmation: formatting, building the
                 kernel locally, installing without any way to log in
  --dry-run      print the heavy commands instead of executing them
  -h, --help     show this help
USAGE_EOF
}

# --- argument parsing -------------------------------------------------------
ORIG_ARGS=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    prepare|build|install|config|eject|all|show|devices)
      [[ -n "$SUBCOMMAND" ]] && { echo "error: multiple subcommands ($SUBCOMMAND, $1)" >&2; exit 2; }
      SUBCOMMAND="$1"
      ;;
    --flake) FLAKE="$2"; shift ;;
    --mount) MOUNT="$2"; MOUNT_SET=1; shift ;;
    --attr) ATTR="$2"; shift ;;
    --from) FROM="$2"; shift ;;
    --boot-size) BOOT_SIZE="$2"; shift ;;
    --format) FORMAT=1 ;;
    -y|--yes) ASSUME_YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    *) POSITIONAL+=("$1") ;;
  esac
  shift
done
[[ -z "$SUBCOMMAND" ]] && SUBCOMMAND="all"

# A positional argument is the DEVICE for `prepare`, the target root otherwise.
if [[ "$SUBCOMMAND" == "prepare" ]]; then
  [[ ${#POSITIONAL[@]} -le 1 ]] || { echo "error: multiple devices (${POSITIONAL[*]})" >&2; exit 2; }
  DEVICE="${POSITIONAL[0]:-}"
else
  for p in ${POSITIONAL[@]+"${POSITIONAL[@]}"}; do
    [[ "$MOUNT_SET" -eq 1 ]] && { echo "error: multiple target paths ($MOUNT, $p)" >&2; exit 2; }
    MOUNT="$p"; MOUNT_SET=1
  done
fi
[[ "$FORMAT" -eq 0 || "$SUBCOMMAND" == "prepare" ]] || { echo "error: --format only applies to 'prepare'" >&2; exit 2; }
[[ "$FORMAT" -eq 0 || -n "$DEVICE" ]] || { echo "error: --format needs a DEVICE, e.g.: rpi-deploy prepare /dev/sdX --format (list candidates: rpi-deploy devices)" >&2; exit 2; }

# The long build must not run as root (root-owned results, .rpi-build state).
# If started via sudo, re-exec as the invoking user; sudo is used only for the
# card copy and nixos-install.
if [[ "$EUID" -eq 0 && -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
  echo "==> re-executing as '$SUDO_USER' (build as regular user; sudo only for copy/install)" >&2
  exec sudo -u "$SUDO_USER" env "PATH=$PATH" "$0" "${ORIG_ARGS[@]}"
fi

FLAKE="$(cd "$FLAKE" 2>/dev/null && pwd)" || { echo "error: flake path does not exist: ${FLAKE}" >&2; exit 1; }
STATE="$FLAKE/.rpi-build"
LAST="$STATE/last"
TOPOLEVEL="#nixosConfigurations.${ATTR}.config.system.build.toplevel"

# Colours only on a terminal (and not with NO_COLOR), so logs stay clean.
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_BLUE=$'\033[1;34m'; C_YEL=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_OFF=$'\033[0m'
else
  C_BLUE=""; C_YEL=""; C_RED=""; C_OFF=""
fi
log()  { printf '%s==> %s%s\n' "$C_BLUE" "$*" "$C_OFF"; }
warn() { printf '%swarning: %s%s\n' "$C_YEL" "$*" "$C_OFF" >&2; }
die()  { printf '%serror: %s%s\n' "$C_RED" "$*" "$C_OFF" >&2; exit 1; }

# human_secs N: 754 -> 12m34s
human_secs() {
  local s="$1"
  if (( s >= 3600 )); then printf '%dh%02dm%02ds' $((s/3600)) $((s%3600/60)) $((s%60))
  elif (( s >= 60 )); then printf '%dm%02ds' $((s/60)) $((s%60))
  else printf '%ds' "$s"; fi
}

# human_bytes N: 1536 -> 1.5 KiB
human_bytes() {
  awk -v b="$1" 'BEGIN { split("B KiB MiB GiB TiB", u, " "); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ } printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }'
}

# run <cmd...>: executes the command, or just prints it in dry-run mode.
# Only for commands whose stdout is not captured.
run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'dry-run: %s\n' "$*"
  else
    "$@"
  fi
}

# --- preflights -------------------------------------------------------------
require_nix() {
  command -v nix >/dev/null 2>&1 || die "nix not found in PATH"
  command -v git >/dev/null 2>&1 || warn "git not found; will not record git revision"
}

check_binfmt() {
  # aarch64 binfmt registration (NixOS: boot.binfmt.emulatedSystems).
  # The handler is named "aarch64-linux" by current NixOS (older setups:
  # "qemu-aarch64"), and /run/binfmt holds the emulators either way.
  if [[ -e "$BINMFT_DIR/aarch64-linux" || -e "$BINMFT_DIR/qemu-aarch64" || -e "$BINMFT_RUN" ]]; then
    echo "aarch64 binfmt  : present"
  else
    echo "aarch64 binfmt  : NOT FOUND (cross build will fail with 255)"
  fi
}

# Full emulation preflight; exits non-zero if the build would fail.
check_emulation() {
  local ok=1
  if [[ ! -e "$BINMFT_DIR/aarch64-linux" && ! -e "$BINMFT_DIR/qemu-aarch64" && ! -e "$BINMFT_RUN" ]]; then
    warn "no aarch64 binfmt handler found ($BINMFT_DIR/{aarch64-linux,qemu-aarch64} or $BINMFT_RUN)"
    ok=0
  fi
  if ! nix show-config 2>/dev/null | grep -q 'extra-platforms.*aarch64-linux'; then
    warn "nix extra-platforms does not include aarch64-linux"
    ok=0
  fi
  if [[ "$ok" -eq 1 ]]; then
    log "emulation preflight ok"
  else
    cat >&2 <<'EOF'
aarch64 emulation is not set up. On a NixOS host, import the build-host
module (see README "Build host setup"); manually:

  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];  # registers binfmt + nix sandbox paths
  nix.settings.extra-platforms = [ "aarch64-linux" ];
EOF
  fi
  return $(( 1 - ok ))
}

# Best effort: if a card with our labels is present but not (fully) mounted
# yet, mount it exactly like `rpi-deploy prepare` would. Convenience, so a
# plain `rpi-deploy install` works right after inserting the card.
auto_mount() {
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  [[ -e "$BYLABEL_DIR/NIXOS_SD" && -e "$BYLABEL_DIR/NIXOS_BOOT" ]] || return 0
  log "mounting the card found by its labels (same as: rpi-deploy prepare)"
  mount_card
}

# The card root must be a real mount (not an empty directory on the host disk).
require_card_root() {
  $MOUNTPOINT_CMD "$MOUNT" >/dev/null 2>&1 || auto_mount
  if [[ ! -d "$MOUNT" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then warn "mount point does not exist: $MOUNT"; return; fi
    die "mount point does not exist: $MOUNT (run: rpi-deploy prepare)"
  fi
  if ! $MOUNTPOINT_CMD "$MOUNT" >/dev/null 2>&1; then
    if [[ "$DRY_RUN" -eq 1 ]]; then warn "$MOUNT is not a mount point"; return; fi
    die "$MOUNT is not a mount point (run: rpi-deploy prepare)"
  fi
}

require_card() {
  require_card_root
  # The firmware partition (fileSystems."/boot/firmware" in configuration.nix)
  # must be mounted under the target root: the nixos-raspberrypi bootloader
  # installer writes the Pi firmware, config.txt and U-Boot there during
  # nixos-install. Unmounted, it would land on the root fs and the Pi would
  # not boot.
  $MOUNTPOINT_CMD "$MOUNT/boot/firmware" >/dev/null 2>&1 || auto_mount
  if ! $MOUNTPOINT_CMD "$MOUNT/boot/firmware" >/dev/null 2>&1; then
    if [[ "$DRY_RUN" -eq 1 ]]; then warn "$MOUNT/boot/firmware is not a mount point"; return; fi
    die "$MOUNT/boot/firmware is not a mount point (run: rpi-deploy prepare)"
  fi
}

# confirm QUESTION: ask y/N. --yes answers yes. In dry-run nothing is asked
# (answer: yes). Without a terminal and without --yes the answer is no.
# (RPI_ASSUME_TTY=1 lets tests feed answers on stdin.)
confirm() {
  local ans
  if [[ "$DRY_RUN" -eq 1 ]]; then return 0; fi
  if [[ "$ASSUME_YES" -eq 1 ]]; then warn "continuing because of --yes: $1"; return 0; fi
  if [[ ! -t 0 && "${RPI_ASSUME_TTY:-0}" != 1 ]]; then return 1; fi
  printf '%s [y/N] ' "$1" >&2
  read -r ans || { echo >&2; return 1; }
  [[ "$ans" =~ ^[yY]([eE][sS])?$ ]]
}

# Reports how the nixos-raspberrypi binary cache gets enabled on this host.
# The flake's nixConfig (extra-substituters) only takes effect for *trusted*
# nix users, or when the host's nix.conf lists the cache itself. (A plain
# `nix show-config` never shows a flake's nixConfig, so it cannot be used to
# decide; the authoritative test is check_kernel_cached below.)
check_cache() {
  local subs trusted t u ok=0
  subs="$(nix config show substituters 2>/dev/null || true)"
  if [[ "$subs" == *nixos-raspberrypi.cachix.org* ]]; then
    log "binary cache: nixos-raspberrypi.cachix.org is configured on this host"
    return 0
  fi
  u="$(id -un)"
  trusted="$(nix config show trusted-users 2>/dev/null || true)"
  [[ "$EUID" -eq 0 ]] && ok=1
  for t in $trusted; do
    case "$t" in
      "$u"|'*') ok=1 ;;
      @*) id -Gn | tr ' ' '\n' | grep -qx "${t#@}" && ok=1 ;;
    esac
  done
  if [[ "$ok" -eq 1 ]]; then
    log "binary cache: nixos-raspberrypi.cachix.org is enabled through the flake (you are a trusted nix user)"
  else
    warn "'$u' is not a trusted nix user, so nix ignores the flake's binary cache setting (nixos-raspberrypi.cachix.org). Fix on NixOS: nix.settings.trusted-users = [ \"$u\" ]; or enable the cache host-wide with rpi.buildHost.enable = true (or nix.settings.extra-substituters + extra-trusted-public-keys, see flake.nix nixConfig). Elsewhere: add 'trusted-users = $u' to /etc/nix/nix.conf and restart nix-daemon."
  fi
}

# The authoritative cache test: ask nix (dry-run, nothing is built) whether the
# vendor kernel would be fetched or compiled. Compiling it locally under qemu
# takes 16+ hours, so ask before starting that.
check_kernel_cached() {
  local out building
  log "checking that the vendor kernel comes from the binary cache"
  out="$(cd "$FLAKE" && nix build --dry-run --accept-flake-config "$TOPOLEVEL" 2>&1)" || {
    warn "could not evaluate the build plan; skipping the kernel cache check"; return 0; }
  building="$(printf '%s\n' "$out" | awk '/will be built/ { f = 1; next } /^[^ ]/ { f = 0 } f' | grep -E 'linux[-_]rpi' | sed 's|/nix/store/[a-z0-9]*-||' | sort -u || true)"
  if [[ -z "$building" ]]; then
    log "vendor kernel: available from the binary cache (will not be compiled)"
    return 0
  fi
  warn "the vendor kernel is NOT in any enabled binary cache and would be compiled locally under qemu (16+ hours):"
  printf '    %s\n' $building >&2
  warn "likely causes: you are not a trusted nix user (see above), nixpkgs no longer follows nixos-raspberrypi/nixpkgs, or nvmd has not built the current pin yet"
  confirm "Compile the kernel locally anyway?" \
    || die "aborted. Fix the cache setup, or pass --yes to build anyway"
}

git_head() {
  if command -v git >/dev/null 2>&1 && git -C "$FLAKE" rev-parse HEAD >/dev/null 2>&1; then
    git -C "$FLAKE" rev-parse HEAD
  else
    echo "unknown"
  fi
}

git_dirty() {
  command -v git >/dev/null 2>&1 \
    && git -C "$FLAKE" rev-parse HEAD >/dev/null 2>&1 \
    && [[ -n "$(git -C "$FLAKE" status --porcelain)" ]]
}

# need_cmd <cmd...>: fail early (or just warn in dry-run) if a tool is missing.
need_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 && continue
    if [[ "$DRY_RUN" -eq 1 ]]; then warn "required command not found: $c"; else die "required command not found: $c"; fi
  done
}

# mnt_source DIR: the device mounted exactly at DIR ("" if nothing is).
mnt_source() { findmnt -rno SOURCE --mountpoint "$1" 2>/dev/null || true; }

# part_dev DEVICE N: partition N of DEVICE (mmcblk0 -> mmcblk0p1, sdb -> sdb1).
part_dev() {
  if [[ "$1" =~ [0-9]$ ]]; then printf '%sp%s\n' "$1" "$2"; else printf '%s%s\n' "$1" "$2"; fi
}

# --- devices ------------------------------------------------------------------
# Lists removable / MMC disks so the user can pick the DEVICE for `prepare`.
list_devices() {
  command -v lsblk >/dev/null 2>&1 || return 0
  local out
  out="$(lsblk -dnP -o PATH,SIZE,TRAN,RM,MODEL 2>/dev/null \
    | awk -F'"' '$8 == "1" || $2 ~ /mmcblk/ { printf "  %-14s %8s  %-5s %s\n", $2, $4, $6, $10 }')"
  if [[ -n "$out" ]]; then
    echo "removable / MMC disks (candidates for DEVICE):"
    echo "$out"
  else
    echo "no removable or MMC disk found; insert the card (see: lsblk)"
  fi
}

do_devices() {
  list_devices
  echo
  if [[ -e "$BYLABEL_DIR/NIXOS_SD" && -e "$BYLABEL_DIR/NIXOS_BOOT" ]]; then
    echo "a card with the labels NIXOS_SD / NIXOS_BOOT is present:"
    echo "  root     $(readlink -f "$BYLABEL_DIR/NIXOS_SD")"
    echo "  firmware $(readlink -f "$BYLABEL_DIR/NIXOS_BOOT")"
    echo "  -> rpi-deploy prepare  (mount it)  /  rpi-deploy install"
  else
    echo "no card with the labels NIXOS_SD / NIXOS_BOOT"
    echo "  -> new card: rpi-deploy prepare /dev/sdX --format"
  fi
}

# --- prepare ------------------------------------------------------------------
# Refuse to touch a disk the host itself runs from.
refuse_host_disk() {
  local dev name p src
  name="$(basename "$(readlink -f "$DEVICE")")"
  for p in / /boot /nix /home /usr /var; do
    src="$(findmnt -no SOURCE -T "$p" 2>/dev/null || true)"
    [[ -n "$src" ]] || continue
    # lsblk -s lists the device and all its parents (partition -> disk)
    if lsblk -nlso NAME "$src" 2>/dev/null | grep -qx "$name"; then
      die "$DEVICE holds the host's $p ($src); refusing to touch it"
    fi
  done
}

format_card() {
  need_cmd lsblk findmnt wipefs sfdisk mkfs.vfat mkfs.ext4 udevadm
  if [[ "$ALLOW_NONBLOCK" -ne 1 ]]; then
    [[ -b "$DEVICE" ]] || die "$DEVICE is not a block device"
  fi
  [[ "$(lsblk -dno TYPE "$DEVICE" 2>/dev/null)" == "disk" ]] \
    || die "$DEVICE is not a whole disk (give e.g. /dev/sdb or /dev/mmcblk0, not a partition)"
  [[ "$BOOT_SIZE" =~ ^[0-9]+(MiB|GiB)$ ]] || die "--boot-size must look like 256MiB or 1GiB (got: $BOOT_SIZE)"
  refuse_host_disk

  # Mount points of the device (and its partitions) that must go before it
  # can be repartitioned: our own card mount, or e.g. a desktop automount.
  # They are unmounted after the confirmation below.
  local mp
  DEV_MOUNTS=()
  while IFS= read -r mp; do
    [[ -n "$mp" ]] && DEV_MOUNTS+=("$mp")
  done < <(lsblk -nlo MOUNTPOINT "$DEVICE" 2>/dev/null | awk '!seen[$0]++')

  local p1 p2
  p1="$(part_dev "$DEVICE" 1)"; p2="$(part_dev "$DEVICE" 2)"
  echo "About to DESTROY ALL DATA on $DEVICE and create:" >&2
  printf '  %s  %-8s %-6s %-11s (-> %s)\n' "$p1" "$BOOT_SIZE" FAT32 NIXOS_BOOT "$MOUNT/boot/firmware" >&2
  printf '  %s  %-8s %-6s %-11s (-> %s)\n' "$p2" rest ext4 NIXOS_SD "$MOUNT" >&2
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MODEL "$DEVICE" >&2 || true
  if [[ ${#DEV_MOUNTS[@]} -gt 0 ]]; then
    echo "  currently mounted (will be unmounted): ${DEV_MOUNTS[*]}" >&2
  fi
  # (built-in SD readers, mmcblk*, report RM=0 although the card is removable)
  if [[ "$DEVICE" != */mmcblk* && "$(lsblk -dno RM "$DEVICE" 2>/dev/null | tr -d ' ')" == "0" ]]; then
    warn "$DEVICE is not a removable device; make sure it really is the SD card"
  fi
  if [[ "$DRY_RUN" -eq 0 && "$ASSUME_YES" -eq 0 ]]; then
    [[ -t 0 ]] || die "not interactive: pass --yes to confirm formatting $DEVICE"
    local ans
    read -r -p "Type the device path ($DEVICE) to confirm: " ans
    [[ "$ans" == "$DEVICE" ]] || die "confirmation did not match; nothing was changed"
  fi

  # Anything of this device that desktop automounters (udisks) or an earlier
  # run left mounted would make sfdisk refuse ("disk is currently in use").
  # The user has just confirmed the destruction, so unmount it.
  local m
  for m in "${DEV_MOUNTS[@]}"; do
    [[ "$m" == "[SWAP]" ]] && die "$DEVICE is used as swap; run: sudo swapoff -a (or the right device) first"
    log "unmounting $m"
    run $SUDO umount -R "$m"
  done

  log "partitioning $DEVICE"
  run $SUDO wipefs -a "$DEVICE"
  run $SUDO udevadm settle
  [[ "$DRY_RUN" -eq 1 ]] && echo "dry-run: sfdisk script: label: dos; ,$BOOT_SIZE,c,* (FAT32 LBA, bootable); ,,83 (Linux, rest)"
  PART_SCRIPT="$(printf 'label: dos\n,%s,c,*\n,,83\n' "$BOOT_SIZE")"
  retry 5 "partitioning $DEVICE" apply_partition_table
  wait_for_nodes "$p1" "$p2"
  log "creating file systems"
  retry 5 "formatting $p1" run $SUDO mkfs.vfat -F 32 -n NIXOS_BOOT "$p1"
  retry 5 "formatting $p2" run $SUDO mkfs.ext4 -q -F -L NIXOS_SD "$p2"
  run $SUDO udevadm settle
}

# Writes $PART_SCRIPT as the partition table. flock takes the exclusive lock
# udev honours, so udev's own probe of the freshly wiped disk cannot race us.
apply_partition_table() {
  run $SUDO flock "$DEVICE" sfdisk --quiet "$DEVICE" <<< "$PART_SCRIPT"
}

# retry N WHAT CMD...: a device that was just wiped/partitioned is briefly
# busy (udev, automounters); retry a few times before giving up.
retry() {
  local n="$1" what="$2" i; shift 2
  for (( i = 1; i <= n; i++ )); do
    "$@" && return 0
    if (( i < n )); then
      warn "$what failed (device busy?); retrying ($i/$n)"
      [[ "$DRY_RUN" -eq 1 ]] || { sleep 1; $SUDO udevadm settle || true; }
    fi
  done
  die "$what failed after $n attempts (is something using $DEVICE? check: lsblk $DEVICE; sudo fuser -vm $DEVICE)"
}

# wait_for_nodes DEV...: the kernel/udev create partition nodes asynchronously.
wait_for_nodes() {
  [[ "$DRY_RUN" -eq 1 || "$ALLOW_NONBLOCK" -eq 1 ]] && return 0
  local d i
  $SUDO udevadm settle || true
  for d in "$@"; do
    for (( i = 0; i < 50; i++ )); do [[ -b "$d" ]] && break; sleep 0.2; done
    [[ -b "$d" ]] || die "partition node $d did not appear after partitioning"
  done
}

# blk_prop LSBLK_COLUMN BLKID_TAG DEV: a file-system property, from the udev
# database (lsblk) and, if that has nothing (no udev, stale), from the device
# itself (blkid, needs root; skipped in dry-run).
blk_prop() {
  local v
  v="$(lsblk -no "$1" "$3" 2>/dev/null | head -n1 || true)"
  if [[ -z "$v" && "$DRY_RUN" -eq 0 ]] && command -v blkid >/dev/null 2>&1; then
    v="$($SUDO blkid -o value -s "$2" "$3" 2>/dev/null | head -n1 || true)"
  fi
  printf '%s\n' "$v"
}

# ensure_label PARTITION FSTYPE LABEL SETTER: verify PARTITION holds FSTYPE and
# carries LABEL; fix a wrong/missing label in place (non-destructive). A
# partition with another file system is never touched.
ensure_label() {
  local part="$1" want_fs="$2" want_label="$3" setter="$4" fs label mnt
  fs="$(blk_prop FSTYPE TYPE "$part")"
  if [[ -z "$fs" && "$DRY_RUN" -eq 1 ]]; then
    warn "cannot read the file system of $part (dry-run, no udev data); assuming $want_fs"
    fs="$want_fs"
  fi
  [[ "$fs" == "$want_fs" ]] \
    || die "$part is '${fs:-unformatted}', expected $want_fs. Not a card made by this kit? Run: rpi-deploy prepare $DEVICE --format"
  label="$(blk_prop LABEL LABEL "$part")"
  [[ "$label" == "$want_label" ]] && return 0
  mnt="$(lsblk -no MOUNTPOINT "$part" 2>/dev/null | head -n1 || true)"
  [[ -z "$mnt" ]] || die "$part has label '${label:-<none>}' (want $want_label) but is mounted at $mnt; unmount it first"
  log "setting label of $part: '${label:-<none>}' -> $want_label"
  case "$setter" in
    fat) run $SUDO fatlabel "$part" "$want_label" ;;
    ext) run $SUDO e2label "$part" "$want_label" ;;
  esac
  LABELS_CHANGED=1
}

# Make the card findable by label (what configuration.nix mounts by):
# p1 = FAT32 NIXOS_BOOT, p2 = ext4 NIXOS_SD.
ensure_labels() {
  need_cmd lsblk fatlabel e2label udevadm
  LABELS_CHANGED=0
  ensure_label "$1" vfat NIXOS_BOOT fat
  ensure_label "$2" ext4 NIXOS_SD ext
  if [[ "$LABELS_CHANGED" -eq 1 ]]; then
    # let udev refresh /dev/disk/by-label before it is consulted
    run $SUDO udevadm trigger --action=change --settle "$1" "$2"
  fi
}

# duplicate_labels: "LABEL: /dev/a /dev/b" lines for NIXOS_SD / NIXOS_BOOT
# labels that more than one partition carries (e.g. an old and a new card in
# two readers). /dev/disk/by-label then points at an arbitrary one of them.
duplicate_labels() {
  lsblk -nlo PATH,LABEL 2>/dev/null | awk '
    $2 == "NIXOS_SD" || $2 == "NIXOS_BOOT" { c[$2]++; p[$2] = p[$2] " " $1 }
    END { for (l in c) if (c[l] > 1) print l ":" p[l] }'
}

# Mounts root at $MOUNT and the FAT partition at $MOUNT/boot/firmware.
mount_card() {
  need_cmd findmnt
  local root_dev boot_dev cur
  if [[ -n "$DEVICE" ]]; then
    root_dev="$(part_dev "$DEVICE" 2)"; boot_dev="$(part_dev "$DEVICE" 1)"
    # a fresh --format has just created the labels (mkfs -n / -L); otherwise
    # repair missing/wrong ones on an existing NIXOS-style card
    [[ "$FORMAT" -eq 1 ]] || ensure_labels "$boot_dev" "$root_dev"
    # (a fresh --format has just set the labels; in dry-run nothing exists yet)
    if [[ "$DRY_RUN" -eq 0 ]]; then
      [[ "$(readlink -f "$BYLABEL_DIR/NIXOS_SD" 2>/dev/null)" == "$(readlink -f "$root_dev")" \
         && "$(readlink -f "$BYLABEL_DIR/NIXOS_BOOT" 2>/dev/null)" == "$(readlink -f "$boot_dev")" ]] \
        || die "$DEVICE does not have the expected layout/labels (NIXOS_BOOT on $boot_dev, NIXOS_SD on $root_dev). New or foreign card? Run: rpi-deploy prepare $DEVICE --format. If another card with the same labels is connected, unplug it (labels are then ambiguous): $(duplicate_labels | tr '\n' ';')"
    fi
  else
    local dups
    dups="$(duplicate_labels)"
    if [[ -n "$dups" ]]; then
      echo "$dups" >&2
      die "several partitions carry the NIXOS_SD / NIXOS_BOOT labels (two cards connected?), so the label is ambiguous. Unplug the other card, or name the device: rpi-deploy prepare /dev/sdX"
    fi
    root_dev="$(readlink -f "$BYLABEL_DIR/NIXOS_SD" 2>/dev/null || true)"
    boot_dev="$(readlink -f "$BYLABEL_DIR/NIXOS_BOOT" 2>/dev/null || true)"
    if [[ ! -e "$root_dev" || ! -e "$boot_dev" ]]; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "no card with labels NIXOS_SD / NIXOS_BOOT found"; root_dev="<NIXOS_SD>"; boot_dev="<NIXOS_BOOT>"
      else
        list_devices >&2
        die "no card with labels NIXOS_SD / NIXOS_BOOT found. New card? Run: rpi-deploy prepare /dev/sdX --format"
      fi
    fi
  fi

  # Old layout (FAT mounted at <mount>/boot): remount it below boot/firmware.
  cur="$(mnt_source "$MOUNT/boot")"
  if [[ -n "$cur" && "$cur" == "$boot_dev" ]]; then
    log "old layout: unmounting the FAT partition from $MOUNT/boot"
    run $SUDO umount "$MOUNT/boot"
  fi

  cur="$(mnt_source "$MOUNT")"
  if [[ -z "$cur" ]]; then
    run $SUDO mkdir -p "$MOUNT"
    run $SUDO mount "$root_dev" "$MOUNT"
  elif [[ "$cur" != "$root_dev" ]]; then
    die "$MOUNT is already mounted from $cur, not from $root_dev"
  else
    log "$MOUNT already mounted ($root_dev)"
  fi

  run $SUDO mkdir -p "$MOUNT/boot/firmware"
  cur="$(mnt_source "$MOUNT/boot/firmware")"
  if [[ -z "$cur" ]]; then
    run $SUDO mount "$boot_dev" "$MOUNT/boot/firmware"
  elif [[ "$cur" != "$boot_dev" ]]; then
    die "$MOUNT/boot/firmware is already mounted from $cur, not from $boot_dev"
  else
    log "$MOUNT/boot/firmware already mounted ($boot_dev)"
  fi
  log "card ready: $root_dev -> $MOUNT, $boot_dev -> $MOUNT/boot/firmware"
}

do_prepare() {
  if [[ "$FORMAT" -eq 1 ]]; then
    format_card
  fi
  mount_card
}

# --- eject --------------------------------------------------------------------
do_eject() {
  if ! $MOUNTPOINT_CMD "$MOUNT" >/dev/null 2>&1; then
    log "$MOUNT is not mounted; nothing to do"
    return
  fi
  run sync
  run $SUDO umount -R "$MOUNT"
  log "card unmounted; safe to remove"
}

# --- config copy --------------------------------------------------------------
# Mirrors the config checkout to <mount>/etc/nixos. nixos-install --flake does
# NOT put the configuration on the target, but the pi needs it there: the
# secrets file referenced by the config lives at /etc/nixos/secrets/, and it is
# what `nixos-rebuild` / autoUpgrade on the pi work from.
sync_config() {
  need_cmd tar find
  [[ -f "$FLAKE/secrets/wireless.env" ]] \
    || warn "$FLAKE/secrets/wireless.env is missing; wifi will not connect on the pi (see secrets/wireless.env.example)"
  [[ -e "$FLAKE/.git" ]] \
    || warn "$FLAKE is not a git checkout; on the pi the flake would be a path: flake and secrets/ would be copied into the world-readable nix store"
  log "copying configuration $FLAKE -> $MOUNT/etc/nixos"
  run $SUDO mkdir -p "$MOUNT/etc/nixos"
  # Mirror: clear the old copy, then unpack the checkout (owned by root).
  # tar instead of rsync: present on every host, nothing extra to install.
  local excl=( --exclude=./.rpi-build --exclude=./.rpi-build.log --exclude=./result
               --exclude='./result-*' --exclude=./.nixcache --exclude=./.direnv )
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'dry-run: sudo find %s -mindepth 1 -xdev -delete\n' "$MOUNT/etc/nixos"
    printf 'dry-run: tar -C %s --anchored --owner=0 --group=0 -cf - . | sudo tar -C %s -xpf -\n' "$FLAKE" "$MOUNT/etc/nixos"
  else
    $SUDO find "$MOUNT/etc/nixos" -mindepth 1 -xdev -delete
    tar -C "$FLAKE" --anchored --owner=0 --group=0 --numeric-owner "${excl[@]}" -cf - . \
      | $SUDO tar -C "$MOUNT/etc/nixos" -xpf -
  fi
}

do_config() {
  require_card_root
  sync_config
}

# --- build ------------------------------------------------------------------
# Builds the toplevel from the local checkout. No SD card involved.
do_build() {
  require_nix
  [[ -f "$FLAKE/flake.nix" ]] || die "no flake.nix in $FLAKE"

  check_emulation || die "aarch64 emulation preflight failed (see hints above)"
  check_cache
  check_kernel_cached
  # Ask about the missing ssh key now, not after hours of building.
  check_login

  log "building $FLAKE$TOPOLEVEL (this takes a while for kernel changes)"
  mkdir -p "$STATE"
  local t0=$SECONDS

  local drv=""
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'dry-run: nix eval --raw %s%s.drvPath --accept-flake-config\n' "$FLAKE" "$TOPOLEVEL"
    printf 'dry-run: nix build --accept-flake-config --print-build-logs %s%s  (log: %s)\n' "$FLAKE" "$TOPOLEVEL" "$STATE/build.log"
  else
    drv="$(nix eval --raw --accept-flake-config "$FLAKE$TOPOLEVEL.drvPath")"
    [[ -n "$drv" ]] || die "could not evaluate the toplevel drvPath"
    log "toplevel drv: $drv"

    # --print-build-logs streams the build; a second call is a fast no-op that
    # just reports the output path.
    local sys
    if ! ( cd "$FLAKE" && nix build --accept-flake-config "$TOPOLEVEL" --print-build-logs ) 2>&1 | tee "$STATE/build.log"; then
      echo "--- last 30 lines of the build log ($STATE/build.log) ---" >&2
      tail -30 "$STATE/build.log" | sed 's/^/  | /' >&2
      if grep -q "failed with exit code 255" "$STATE/build.log"; then
        warn "hint: exit code 255 = the aarch64 builder could not be exec'd under qemu; re-check binfmt and extra-sandbox-paths"
      elif grep -qiE '\bkilled\b|out of memory' "$STATE/build.log"; then
        warn "hint: build process killed, likely out of memory (an emulated kernel build needs a lot of RAM)"
      fi
      die "build failed (full log: $STATE/build.log)"
    fi
    sys="$(cd "$FLAKE" && nix build --accept-flake-config "$TOPOLEVEL" --print-out-paths)"
    [[ -n "$sys" && -d "$sys" ]] || die "build did not produce an output"

    local rev dirty
    rev="$(git_head)"
    if git_dirty; then dirty=dirty; else dirty=clean; fi

    cat > "$LAST" <<EOF
flake=$FLAKE
attr=$ATTR
rev=$rev
dirty=$dirty
sys=$sys
drv=$drv
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
    log "recorded build: $sys (built in $(human_secs $((SECONDS - t0))))"
    if [[ "$SUBCOMMAND" == "build" ]]; then
      log "next: insert the SD card (new card: rpi-deploy prepare /dev/sdX --format), then: rpi-deploy install"
    fi
  fi
}

# Reads "key=value" records; prints the value of $1, or nothing if the
# record is missing/incomplete. Non-fatal on purpose: this is used inside
# command substitutions, where a die/exit would kill the subshell before
# any `|| fallback` could run.
read_record() {
  [[ -f "$LAST" ]] || return 0
  local v
  v="$(sed -n "s/^$1=//p" "$LAST" | tail -1)"
  [[ -n "$v" ]] || return 0
  printf '%s\n' "$v"
}

# --- emulation inside the card chroot -------------------------------------------
# nixos-install runs the new system's `activate` and the bootloader installer
# through nixos-enter: a chroot of the card in a fresh mount namespace. Those
# are aarch64 binaries, run on this host via qemu-user/binfmt_misc. A handler
# registered WITHOUT the F (fix-binary) flag is resolved at exec time, inside
# that chroot, where /run/binfmt/aarch64-linux does not exist: everything
# fails with "cannot execute: required file not found" / "chroot: failed to run
# command ...: No such file or directory". With F the kernel opens the
# interpreter once, at registration time, so it works in any chroot/namespace.
# (A symlink bridged into the card was tried; it only helps the first exec.)
BINFMT_TEMP_NAME="rpi-deploy-aarch64"
BINFMT_TEMP_ACTIVE=0

# binfmt_entry: path of the registered aarch64 handler, if readable.
binfmt_entry() {
  local n
  for n in aarch64-linux qemu-aarch64; do
    if [[ -r "$BINMFT_DIR/$n" ]]; then printf '%s\n' "$BINMFT_DIR/$n"; return 0; fi
  done
  return 1
}

# binfmt_field ENTRY KEY: "interpreter" -> /run/binfmt/..., "flags" -> P / PF
binfmt_field() { sed -n "s/^$2:\\? *//p" "$1" | head -n1; }

# Removes the temporary handler again (binfmt_misc: writing -1 unregisters).
unregister_binfmt_f() {
  [[ "$BINFMT_TEMP_ACTIVE" -eq 1 ]] || return 0
  BINFMT_TEMP_ACTIVE=0
  if [[ -e "$BINMFT_DIR/$BINFMT_TEMP_NAME" ]]; then
    printf '%s\n' "-1" | run $SUDO tee "$BINMFT_DIR/$BINFMT_TEMP_NAME" >/dev/null || true
  fi
}

# Registers a temporary aarch64 handler with the F flag, using the static qemu
# the build-host module would use (flake package rpi-binfmt carries the
# registration line). It takes precedence over the existing handler (the
# kernel searches the newest registration first) and is removed afterwards.
register_binfmt_f() {
  local out line
  if [[ ! -d "$BINMFT_DIR" && "$DRY_RUN" -eq 0 ]]; then
    die "binfmt_misc is not mounted at $BINMFT_DIR; run: sudo mount -t binfmt_misc binfmt_misc $BINMFT_DIR"
  fi
  log "registering a temporary aarch64 binfmt handler with the F flag (removed after the install)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'dry-run: nix build --accept-flake-config --no-link --print-out-paths %s#rpi-binfmt\n' "$FLAKE"
    printf 'dry-run: sudo tee %s/register <<< <line from rpi-binfmt>\n' "$BINMFT_DIR"
    return 0
  fi
  out="$(cd "$FLAKE" && nix build --accept-flake-config --no-link --print-out-paths ".#rpi-binfmt" 2>&1 | tail -n1)" \
    && [[ -f "$out" ]] \
    || die "could not build the binfmt registration (.#rpi-binfmt; it fetches a static qemu, ~100 MiB, check the network): $out"
  line="$(cat "$out")"
  [[ "$line" == :"$BINFMT_TEMP_NAME":* ]] || die "unexpected binfmt registration line in $out: $line"
  if [[ -e "$BINMFT_DIR/$BINFMT_TEMP_NAME" ]]; then   # left over from a crashed run
    printf '%s\n' "-1" | $SUDO tee "$BINMFT_DIR/$BINFMT_TEMP_NAME" >/dev/null || true
  fi
  printf '%s\n' "$line" | $SUDO tee "$BINMFT_DIR/register" >/dev/null \
    || die "could not register the binfmt handler (is binfmt_misc mounted rw at $BINMFT_DIR?)"
  BINFMT_TEMP_ACTIVE=1
}

# chroot_works SYSTEM: can aarch64 programs run inside a chroot of the card,
# including programs started BY an emulated program (this is what activate
# does, and what failed first when the interpreter was only bridged)?
chroot_works() {
  $SUDO chroot "$MOUNT" "$1/sw/bin/bash" -c "$1/sw/bin/true && $1/sw/bin/true" >/dev/null 2>&1
}

# Facts needed to understand a failing chroot, printed instead of guessing.
chroot_diagnostics() {
  local sys="$1" entry n
  {
    echo "  system        : $sys"
    echo "  bash on card  : $(ls -l "$MOUNT$sys/sw/bin/bash" 2>&1 | cut -c1-200)"
    for n in aarch64-linux qemu-aarch64 "$BINFMT_TEMP_NAME"; do
      entry="$BINMFT_DIR/$n"
      if [[ -r "$entry" ]]; then
        echo "  binfmt entry  : $entry"
        sed 's/^/    | /' "$entry"
      fi
    done
    [[ -r "$BINMFT_DIR/aarch64-linux" || -r "$BINMFT_DIR/qemu-aarch64" || -r "$BINMFT_DIR/$BINFMT_TEMP_NAME" ]] \
      || echo "  binfmt entry  : none readable under $BINMFT_DIR (is binfmt_misc mounted? is the aarch64 handler registered?)"
    echo "  chroot output : $($SUDO chroot "$MOUNT" "$sys/sw/bin/bash" -c "$sys/sw/bin/true && $sys/sw/bin/true" 2>&1 | head -n 3 | tr '\n' ' ')"
  } >&2
}

# Called before nixos-install, with the system store path. Makes sure aarch64
# programs run inside the card chroot; if not, registers a temporary F-flag
# handler and tests again; refuses to continue (instead of running a doomed
# nixos-install) if it still does not work.
prepare_chroot_emulation() {
  local sys="$1" entry flags
  [[ "$(uname -m)" == "aarch64" && -z "${RPI_FORCE_EMULATION_CHECK:-}" ]] && return 0

  if [[ "$DRY_RUN" -eq 0 ]]; then
    if chroot_works "$sys"; then
      log "card chroot: aarch64 programs run (emulation works inside the chroot)"
      return 0
    fi
    warn "aarch64 programs do not run inside a chroot of the card (nixos-install would fail with 'cannot execute: required file not found' / 'chroot: failed to run command ...')"
  fi

  if entry="$(binfmt_entry)"; then
    flags="$(binfmt_field "$entry" flags)"
    if [[ "$flags" == *F* ]]; then
      warn "the host's aarch64 binfmt handler has the F flag already; registering a second one anyway"
    else
      warn "the host's aarch64 binfmt handler (flags '${flags:-none}') has no F flag, so the kernel looks for its interpreter inside the card chroot, where it does not exist"
    fi
  fi
  warn "permanent fix on the host: boot.binfmt.preferStaticEmulators = true; (the build-host module sets it)"
  register_binfmt_f

  if [[ "$DRY_RUN" -eq 0 ]]; then
    if chroot_works "$sys"; then
      log "card chroot: aarch64 programs run now (temporary F-flag handler)"
    else
      chroot_diagnostics "$sys"
      unregister_binfmt_f
      die "aarch64 programs still do not run inside the card chroot, so nixos-install would fail. Nothing was installed; see the facts above, enable the permanent fix (boot.binfmt.emulatedSystems = [ \"aarch64-linux\" ]; boot.binfmt.preferStaticEmulators = true; then nixos-rebuild switch) and re-run: rpi-deploy install"
    fi
  fi
}

# --- sudo -------------------------------------------------------------------------
# The card copy of a few GiB can outlast sudo's password timeout (the next sudo
# then prompts again, and times out if you are away). Authenticate once up
# front and keep the ticket fresh for the duration of this run.
SUDO_KEEPALIVE_PID=""
stop_sudo() {
  [[ -n "$SUDO_KEEPALIVE_PID" ]] || return 0
  kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  SUDO_KEEPALIVE_PID=""
}
start_sudo() {
  [[ -n "$SUDO" && "$DRY_RUN" -eq 0 ]] || return 0
  log "root access is needed (card, nixos-install): asking for the sudo password once"
  $SUDO -v || die "sudo authentication failed (sudo needs a terminal here)"
  local parent=$$
  ( while kill -0 "$parent" 2>/dev/null; do sleep 50; $SUDO -n -v 2>/dev/null || exit 0; done ) &
  SUDO_KEEPALIVE_PID=$!
  : # cleanup is handled by the EXIT trap (cleanup_all)
}

# --- install checks ---------------------------------------------------------
# Prints which card is about to be written (device, size, free space).
card_summary() {
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  local dev size avail
  dev="$(mnt_source "$MOUNT")"
  read -r size avail < <(df -B1 --output=size,avail "$MOUNT" 2>/dev/null | tail -n1) || true
  if [[ "${size:-}" =~ ^[0-9]+$ && "${avail:-}" =~ ^[0-9]+$ ]]; then
    log "target card: ${dev:-$MOUNT} at $MOUNT, $(human_bytes "$size") total, $(human_bytes "$avail") free"
  fi
}

# check_space SYSTEM_PATH: does the system closure fit on the card? Dies only
# if it cannot fit at all; warns if it exceeds the free space (it may still be
# fine when most paths are already on the card from an earlier install).
check_space() {
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  local need size avail
  need="$(nix path-info -S "$1" 2>/dev/null | awk 'END { print $NF }')"
  [[ "$need" =~ ^[0-9]+$ ]] || return 0
  read -r size avail < <(df -B1 --output=size,avail "$MOUNT" 2>/dev/null | tail -n1) || return 0
  [[ "$size" =~ ^[0-9]+$ && "$avail" =~ ^[0-9]+$ ]] || return 0
  if (( need + need / 10 > size )); then
    die "the system closure ($(human_bytes "$need")) does not fit on the card ($(human_bytes "$size")); use a larger card"
  elif (( need > avail )); then
    warn "the system closure is $(human_bytes "$need") but only $(human_bytes "$avail") are free on the card; fine if most of it is already there, otherwise the copy will run out of space"
  fi
}

# Warns when nobody could log in: the pi is headless, so a system without an
# ssh key or password for a normal user is unreachable after boot.
check_login() {
  [[ "$DRY_RUN" -eq 1 || "$LOGIN_CONFIRMED" -eq 1 ]] && return 0
  local out name keys pw any=0
  out="$(nix eval --raw --accept-flake-config "$FLAKE#nixosConfigurations.$ATTR.config.users.users" --apply '
    us: builtins.concatStringsSep "\n" (map (u:
      "${u.name} ${toString (builtins.length u.openssh.authorizedKeys.keys + builtins.length u.openssh.authorizedKeys.keyFiles)} ${
        if (u.hashedPassword != null || u.initialHashedPassword != null || u.hashedPasswordFile != null
            || u.password != null || u.initialPassword != null) then "1" else "0"}")
      (builtins.filter (u: u.isNormalUser) (builtins.attrValues us)))' 2>/dev/null)" || return 0
  [[ -n "$out" ]] || return 0
  while read -r name keys pw; do
    [[ "$keys" =~ ^[0-9]+$ ]] || return 0   # unexpected output: stay silent
    if (( keys > 0 )) || [[ "$pw" == 1 ]]; then any=1; fi
  done <<< "$out"
  if (( any == 0 )); then
    warn "no normal user in the config has an ssh key or a password, so you could not log in to the pi (password ssh is off)"
    echo "  Add users.users.<name>.openssh.authorizedKeys.keys in configuration.nix first." >&2
    confirm "Continue without any way to log in?" \
      || die "aborted: add an ssh key to configuration.nix (then: rpi-deploy build && rpi-deploy install), or pass --yes to continue anyway"
  fi
  LOGIN_CONFIRMED=1
}

# --- install ----------------------------------------------------------------
# Copies the last built system into the card's store and runs nixos-install.
# nixos-install is pointed at the *host checkout* (not the card copy), so the
# evaluation matches the recorded build bit-for-bit and nothing is rebuilt.
do_install() {
  require_nix
  require_card
  local t0=$SECONDS
  card_summary

  local sys="" drv=""
  if [[ -n "$FROM" ]]; then
    sys="$FROM"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf 'dry-run: nix eval --raw %s%s.drvPath\n' "$FLAKE" "$TOPOLEVEL"
    else
      drv="$(nix eval --raw "$FLAKE$TOPOLEVEL.drvPath" 2>/dev/null || true)"
      [[ -n "$drv" ]] || drv="$(read_record drv)"
      [[ -n "$drv" ]] || die "could not determine the drv for --from (no build record either)"
    fi
  else
    sys="$(read_record sys)"
    drv="$(read_record drv)"
    if [[ -z "$sys" || -z "$drv" ]]; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "no build record yet — run: rpi-deploy build (dry-run continues with placeholders)"
        sys="${sys:-<last recorded build: run rpi-deploy build>}"
        drv="${drv:-<last recorded drv>}"
      else
        die "no build record at $LAST — run: rpi-deploy build"
      fi
    fi
    local rec_attr
    rec_attr="$(read_record attr)"
    [[ -z "$rec_attr" || "$rec_attr" == "$ATTR" ]] \
      || die "recorded build is for attr '$rec_attr', not '$ATTR' (use --attr $rec_attr or --from)"
  fi
  if [[ -n "$sys" && ! -d "$sys" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      warn "system path not in local store: $sys"
    else
      die "system path not in local store: $sys (run ./rpi-deploy.sh build or nix build it)"
    fi
  fi

  # nixos-install re-evaluates the checkout. If that is not the recorded system
  # any more, it rebuilds the difference inside the card's store (slow, wears
  # the card). The authoritative test is the derivation; git revisions are only
  # a cheap hint (dry-run, or when evaluation is not possible).
  local rev rec_rev cur_drv=""
  if [[ "$DRY_RUN" -eq 0 && -z "$FROM" ]]; then
    cur_drv="$(nix eval --raw --accept-flake-config "$FLAKE$TOPOLEVEL.drvPath" 2>/dev/null || true)"
  fi
  if [[ -n "$cur_drv" && "$cur_drv" == "$drv" ]]; then
    log "the checkout still evaluates to the recorded system: nothing is rebuilt on the card"
  elif [[ -n "$cur_drv" ]]; then
    warn "the configuration changed since the recorded build ($drv -> $cur_drv): nixos-install would rebuild the difference inside the card's store"
    confirm "Install anyway (slow)? 'No' lets you run 'rpi-deploy build' first." \
      || die "aborted: run 'rpi-deploy build', then 'rpi-deploy install' (or pass --yes to install anyway)"
  else
    rev="$(git_head)"
    rec_rev="$(read_record rev)"
    if [[ -n "$rev" && "$rev" != "unknown" && -n "$rec_rev" && "$rec_rev" != "unknown" && "$rev" != "$rec_rev" ]]; then
      warn "checkout HEAD ($rev) differs from recorded build ($rec_rev); the target may rebuild"
    fi
    if git_dirty; then
      warn "checkout has uncommitted changes; the installed config will reflect them (possible rebuild on target)"
    fi
  fi

  check_space "$sys"
  check_login

  log "copying system into $MOUNT/nix store"
  # Paths built as a regular user are unsigned, hence --no-check-sigs; the
  # card store is root-owned, hence sudo (verified on real hardware).
  run $SUDO nix copy --no-check-sigs --to "$MOUNT" "$sys" "$drv"
  if [[ "$DRY_RUN" -eq 0 && ! -x "$MOUNT/nix/store/$(basename "$sys")/activate" ]]; then
    die "verification failed: the system was not copied completely ($MOUNT/nix/store/$(basename "$sys")/activate is missing). Re-run: rpi-deploy install"
  fi

  prepare_chroot_emulation "$sys"

  log "running nixos-install (root: $MOUNT, flake: $FLAKE#$ATTR)"
  # accept-flake-config: the flake's nixConfig (nvmd binary cache) is applied
  # without an interactive prompt, as root.
  local rc=0
  run $SUDO nixos-install --root "$MOUNT" --flake "$FLAKE#$ATTR" --option accept-flake-config true || rc=$?
  unregister_binfmt_f
  if [[ "$rc" -ne 0 ]]; then
    warn "nixos-install failed (exit $rc). Nothing is lost: fix the cause and re-run 'rpi-deploy install'; store paths that are already on the card are skipped, nothing is rebuilt."
    warn "'chroot: failed to run command ... No such file or directory' means the aarch64 emulator is not usable inside the card chroot. Check: cat /proc/sys/fs/binfmt_misc/aarch64-linux  (the flags line needs an F; host fix: boot.binfmt.preferStaticEmulators = true)"
    die "nixos-install failed"
  fi

  sync_config

  if [[ "$DRY_RUN" -eq 0 ]]; then
    local sysname drvname
    sysname="$(basename "$sys")"
    drvname="$(basename "$drv")"
    [[ -d "$MOUNT/nix/store/$sysname" && -d "$MOUNT/nix/store/$drvname" ]] \
      || die "verification failed: system or drv not found in target store"
    [[ -e "$MOUNT/etc/NIXOS" ]] || warn "missing $MOUNT/etc/NIXOS; the install may be incomplete"
    [[ -e "$MOUNT/boot/firmware/config.txt" ]] || warn "no $MOUNT/boot/firmware/config.txt; the firmware partition was not populated, check before booting"
    [[ -e "$MOUNT/boot/firmware/u-boot-rpi-arm64.bin" ]] || warn "no $MOUNT/boot/firmware/u-boot-rpi-arm64.bin; U-Boot missing, the Pi will not boot"
    [[ -f "$MOUNT/etc/nixos/flake.nix" ]] || warn "no $MOUNT/etc/nixos/flake.nix; the configuration was not copied to the card"
    log "installed $sysname onto $MOUNT in $(human_secs $((SECONDS - t0)))"
    log "next: rpi-deploy eject, put the card into the pi and power it on, then ssh in (port and user: see configuration.nix)"
  fi
}

# --- show -------------------------------------------------------------------
do_show() {
  require_nix
  echo "flake   : $FLAKE"
  echo "attr    : $ATTR"
  echo "mount   : $MOUNT"
  echo "git head: $(git_head)$(git_dirty && echo ' (dirty)')"
  check_binfmt
  local be bflags
  if be="$(binfmt_entry)"; then
    bflags="$(binfmt_field "$be" flags)"
    if [[ "$bflags" == *F* ]]; then
      echo "chroot emu      : ok (binfmt flags '$bflags' include F)"
    else
      echo "chroot emu      : a temporary F-flag handler is registered during install (host binfmt flags '${bflags:-none}' lack F; host fix: boot.binfmt.preferStaticEmulators = true)"
    fi
  fi
  if $MOUNTPOINT_CMD "$MOUNT" >/dev/null 2>&1; then
    echo "card    : mounted at $MOUNT ($(mnt_source "$MOUNT"))"
    if $MOUNTPOINT_CMD "$MOUNT/boot/firmware" >/dev/null 2>&1; then
      echo "firmware: mounted at $MOUNT/boot/firmware"
    else
      echo "firmware: NOT mounted at $MOUNT/boot/firmware (run: rpi-deploy prepare)"
    fi
  else
    echo "card    : not mounted (run: rpi-deploy prepare)"
  fi
  echo
  do_devices
  echo
  if [[ -f "$LAST" ]]; then
    echo "last build record ($LAST):"
    cat "$LAST"
  else
    echo "no build record yet — run: rpi-deploy build"
  fi
}

# --- dispatch ----------------------------------------------------------------
# Whatever happens (success, failure, Ctrl-C): remove the temporary binfmt
# handler (needs the sudo ticket, so before the keepalive stops) and stop the
# sudo keepalive.
cleanup_all() {
  unregister_binfmt_f
  stop_sudo
}
trap cleanup_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Everything that touches the card needs root; ask for the password once, at
# the start (for `all`: before the long build, so that you can walk away).
case "$SUBCOMMAND" in prepare|config|eject|install|all) start_sudo ;; esac

case "$SUBCOMMAND" in
  prepare) do_prepare ;;
  config)  do_config ;;
  eject)   do_eject ;;
  build)   do_build ;;
  install) do_install ;;
  all)     do_build; do_install ;;
  show)    do_show ;;
  devices) do_devices ;;
esac
