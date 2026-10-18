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
#   show       show the last build record and host/card status
#
# Usage: rpi-deploy.sh prepare [DEVICE] [--format] [--yes] [--boot-size SIZE]
#        rpi-deploy.sh [build|install|config|eject|all|show] [TARGET] [OPTIONS]
#   TARGET         root of the target NixOS system (default: /media/nixos)
#
# Options:
#   --flake PATH   path to the flake checkout (default: $RPI_FLAKE or $PWD)
#   --mount DIR    SD card mount point (default: /media/nixos)
#   --attr NAME    nixosConfigurations attribute (default: rpi)
#   --from PATH    (install) use this store path instead of the last build
#   --format       (prepare) partition + format DEVICE (destroys all data)
#   --boot-size S  (prepare --format) FAT partition size (default: 256MiB)
#   --yes          (prepare --format) do not ask for confirmation
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
Usage: rpi-deploy prepare [DEVICE] [--format] [--yes] [--boot-size SIZE]
       rpi-deploy [build|install|config|eject|all|show] [TARGET] [OPTIONS]

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
  show       show the last build record and host/card status

Options:
  --flake PATH   path to the flake checkout (default: $RPI_FLAKE or $PWD)
  --mount DIR    SD card mount point (default: /media/nixos)
  --attr NAME    nixosConfigurations attribute (default: rpi)
  --from PATH    (install) use this store path instead of the last build
  --format       (prepare) partition + format DEVICE (destroys all data)
  --boot-size S  (prepare --format) FAT partition size (default: 256MiB)
  --yes          (prepare --format) do not ask for confirmation
  --dry-run      print the heavy commands instead of executing them
  -h, --help     show this help
USAGE_EOF
}

# --- argument parsing -------------------------------------------------------
ORIG_ARGS=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    prepare|build|install|config|eject|all|show)
      [[ -n "$SUBCOMMAND" ]] && { echo "error: multiple subcommands ($SUBCOMMAND, $1)" >&2; exit 2; }
      SUBCOMMAND="$1"
      ;;
    --flake) FLAKE="$2"; shift ;;
    --mount) MOUNT="$2"; MOUNT_SET=1; shift ;;
    --attr) ATTR="$2"; shift ;;
    --from) FROM="$2"; shift ;;
    --boot-size) BOOT_SIZE="$2"; shift ;;
    --format) FORMAT=1 ;;
    --yes) ASSUME_YES=1 ;;
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
[[ "$FORMAT" -eq 0 || -n "$DEVICE" ]] || { echo "error: --format needs a DEVICE, e.g.: rpi-deploy prepare /dev/sdX --format" >&2; exit 2; }

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

log()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mwarning: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31merror: %s\033[0m\n' "$*" >&2; exit 1; }

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

# The card root must be a real mount (not an empty directory on the host disk).
require_card_root() {
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
  if ! $MOUNTPOINT_CMD "$MOUNT/boot/firmware" >/dev/null 2>&1; then
    if [[ "$DRY_RUN" -eq 1 ]]; then warn "$MOUNT/boot/firmware is not a mount point"; return; fi
    die "$MOUNT/boot/firmware is not a mount point (run: rpi-deploy prepare)"
  fi
}

# Warn (not fatal) if the nixos-raspberrypi binary cache is not configured on
# this host. The build passes --accept-flake-config, which makes a *trusted*
# nix user pick it up from the flake's nixConfig; otherwise the vendor kernel
# is compiled locally under qemu (16+ hours).
check_cache() {
  if nix show-config 2>/dev/null | grep -E '^(extra-)?substituters' | grep -q 'nixos-raspberrypi.cachix.org'; then
    log "binary cache: nixos-raspberrypi.cachix.org configured"
  else
    warn "nixos-raspberrypi.cachix.org is not in the host's nix substituters. Builds pass --accept-flake-config, which only works for trusted nix users (nix.settings.trusted-users). Otherwise the vendor kernel is compiled locally (16+ h). Fix: rpi.buildHost.enable = true (adds the cache), or add it to nix.conf."
  fi
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

  # Everything of this device that is mounted must be our own card mount.
  local mp
  while IFS= read -r mp; do
    [[ -n "$mp" ]] || continue
    if [[ "$mp" == "$MOUNT" || "$mp" == "$MOUNT"/* ]]; then
      log "unmounting $MOUNT first"
      run $SUDO umount -R "$MOUNT"
      break
    fi
    die "$DEVICE is mounted at $mp; unmount it first"
  done < <(lsblk -nlo MOUNTPOINT "$DEVICE" 2>/dev/null)

  local p1 p2
  p1="$(part_dev "$DEVICE" 1)"; p2="$(part_dev "$DEVICE" 2)"
  echo "About to DESTROY ALL DATA on $DEVICE and create:" >&2
  echo "  $p1  $BOOT_SIZE  FAT32  NIXOS_BOOT  (-> $MOUNT/boot/firmware)" >&2
  echo "  $p2  rest        ext4   NIXOS_SD    (-> $MOUNT)" >&2
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MODEL "$DEVICE" >&2 || true
  if [[ "$DRY_RUN" -eq 0 && "$ASSUME_YES" -eq 0 ]]; then
    [[ -t 0 ]] || die "not interactive: pass --yes to confirm formatting $DEVICE"
    local ans
    read -r -p "Type the device path ($DEVICE) to confirm: " ans
    [[ "$ans" == "$DEVICE" ]] || die "confirmation did not match; nothing was changed"
  fi

  log "partitioning $DEVICE"
  run $SUDO wipefs -a "$DEVICE"
  [[ "$DRY_RUN" -eq 1 ]] && echo "dry-run: sfdisk script: label: dos; ,$BOOT_SIZE,c,* (FAT32 LBA, bootable); ,,83 (Linux, rest)"
  printf 'label: dos\n,%s,c,*\n,,83\n' "$BOOT_SIZE" | run $SUDO sfdisk --quiet "$DEVICE"| run $SUDO sfdisk --quiet "$DEVICE"
  run $SUDO udevadm settle
  log "creating file systems"
  run $SUDO mkfs.vfat -F 32 -n NIXOS_BOOT "$p1"
  run $SUDO mkfs.ext4 -q -F -L NIXOS_SD "$p2"
  run $SUDO udevadm settle
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
        || die "$DEVICE does not have the expected layout/labels (NIXOS_BOOT on $boot_dev, NIXOS_SD on $root_dev). New or foreign card? Run: rpi-deploy prepare $DEVICE --format"
    fi
  else
    root_dev="$(readlink -f "$BYLABEL_DIR/NIXOS_SD" 2>/dev/null || true)"
    boot_dev="$(readlink -f "$BYLABEL_DIR/NIXOS_BOOT" 2>/dev/null || true)"
    if [[ ! -e "$root_dev" || ! -e "$boot_dev" ]]; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "no card with labels NIXOS_SD / NIXOS_BOOT found"; root_dev="<NIXOS_SD>"; boot_dev="<NIXOS_BOOT>"
      else
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

  log "building $FLAKE$TOPOLEVEL (this takes a while for kernel changes)"
  mkdir -p "$STATE"

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
    log "recorded build: $sys"
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

# --- install ----------------------------------------------------------------
# Copies the last built system into the card's store and runs nixos-install.
# nixos-install is pointed at the *host checkout* (not the card copy), so the
# evaluation matches the recorded build bit-for-bit and nothing is rebuilt.
do_install() {
  require_nix
  require_card

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

  # Warn if the tree the build was recorded from has since diverged: in that
  # case nixos-install re-evaluates and may rebuild in the card's store.
  local rev rec_rev
  rev="$(git_head)"
  rec_rev="$(read_record rev)"
  if [[ -n "$rev" && "$rev" != "unknown" && -n "$rec_rev" && "$rec_rev" != "unknown" && "$rev" != "$rec_rev" ]]; then
    warn "checkout HEAD ($rev) differs from recorded build ($rec_rev); the target may rebuild"
  fi
  if git_dirty; then
    warn "checkout has uncommitted changes; the installed config will reflect them (possible rebuild on target)"
  fi

  log "copying system into $MOUNT/nix store"
  # Paths built as a regular user are unsigned, hence --no-check-sigs; the
  # card store is root-owned, hence sudo (verified on real hardware).
  run $SUDO nix copy --no-check-sigs --to "$MOUNT" "$sys" "$drv"

  log "running nixos-install (root: $MOUNT, flake: $FLAKE#$ATTR)"
  # accept-flake-config: the flake's nixConfig (nvmd binary cache) is applied
  # without an interactive prompt, as root.
  run $SUDO nixos-install --root "$MOUNT" --flake "$FLAKE#$ATTR" --option accept-flake-config true

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
    log "installed $sysname onto $MOUNT"
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
  if [[ -f "$LAST" ]]; then
    echo "last build record ($LAST):"
    cat "$LAST"
  else
    echo "no build record yet — run: rpi-deploy build"
  fi
}

# --- dispatch ----------------------------------------------------------------
case "$SUBCOMMAND" in
  prepare) do_prepare ;;
  config)  do_config ;;
  eject)   do_eject ;;
  build)   do_build ;;
  install) do_install ;;
  all)     do_build; do_install ;;
  show)    do_show ;;
esac
