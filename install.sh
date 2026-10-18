#!/usr/bin/env bash
#
# rpi-install — build and install the pi NixOS flake onto an SD card.
#
# The key property: `build` works entirely from a local checkout of this
# repo, so the SD card does NOT have to be mounted (the pi can keep running)
# while a kernel/system build is in flight. `install` then takes the last
# built system and puts it onto the card.
#
#   build      build from the local checkout, record the result
#   install    install the last recorded build (card must be mounted)
#   all        build + install (default when no subcommand is given)
#   show       show the last build record and host preflight status
#
# Usage: install.sh [build|install|all|show] [TARGET] [OPTIONS]
#   TARGET         root of the target NixOS system (default: /media/nixos)
#
# Options:
#   --flake PATH   path to the flake checkout (default: $RPI_FLAKE or $PWD)
#   --mount DIR    SD card mount point (default: /media/nixos)
#   --attr NAME    nixosConfigurations attribute (default: rpi)
#   --from PATH    (install) use this store path instead of the last build
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
DRY_RUN=0
# The card store and nixos-install need root; the build itself never does.
SUDO="sudo"; [[ "$EUID" -eq 0 ]] && SUDO=""
# Locations of binfmt registration state. Overridable via RPI_BINMFT_* so the
# preflight logic is unit-testable without real qemu/binfmt setup.
BINMFT_DIR="${RPI_BINMFT_DIR:-/proc/sys/fs/binfmt_misc}"
BINMFT_RUN="${RPI_BINMFT_RUN:-/run/binfmt}"
# Overridable so the firmware-partition check is unit-testable.
MOUNTPOINT_CMD="${RPI_MOUNTPOINT_CMD:-mountpoint -q}"

usage() {
  cat <<'EOF'
Usage: rpi-install [build|install|all|show] [TARGET] [OPTIONS]

  TARGET     root of the target NixOS system, e.g. /media/nixos
             (default: /media/nixos; same as --mount)

  build      build from the local checkout (no SD card needed)
  install    install the last recorded build (card must be mounted)
  all        build + install (default when no subcommand is given)
  show       show the last build record and host preflight status

Options:
  --flake PATH   path to the flake checkout (default: $RPI_FLAKE or $PWD)
  --mount DIR    SD card mount point (default: /media/nixos)
  --attr NAME    nixosConfigurations attribute (default: rpi)
  --from PATH    (install) use this store path instead of the last build
  --dry-run      print the heavy commands instead of executing them
  -h, --help     show this help
EOF
}

# --- argument parsing -------------------------------------------------------
ORIG_ARGS=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    build|install|all|show)
      [[ -n "$SUBCOMMAND" ]] && { echo "error: multiple subcommands ($SUBCOMMAND, $1)" >&2; exit 2; }
      SUBCOMMAND="$1"
      ;;
    --flake) FLAKE="$2"; shift ;;
    --mount) MOUNT="$2"; MOUNT_SET=1; shift ;;
    --attr) ATTR="$2"; shift ;;
    --from) FROM="$2"; shift ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    *)
      [[ "$MOUNT_SET" -eq 1 ]] && { echo "error: multiple target paths ($MOUNT, $1)" >&2; exit 2; }
      MOUNT="$1"; MOUNT_SET=1
      ;;
  esac
  shift
done
[[ -z "$SUBCOMMAND" ]] && SUBCOMMAND="all"

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

require_card() {
  if [[ ! -d "$MOUNT" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then warn "mount point does not exist: $MOUNT"; return; fi
    die "mount point does not exist: $MOUNT (mount the SD card first)"
  fi
  if [[ ! -f "$MOUNT/etc/nixos/flake.nix" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then warn "$MOUNT does not look like a NixOS flake install"; return; fi
    die "$MOUNT does not look like a NixOS flake install (missing etc/nixos/flake.nix)"
  fi
  # The firmware partition (fileSystems."/boot/firmware" in configuration.nix)
  # must be mounted under the target root: the nixos-raspberrypi bootloader
  # installer writes the Pi firmware, config.txt and U-Boot there during
  # nixos-install. Unmounted, it would land on the root fs and the Pi would
  # not boot.
  if ! $MOUNTPOINT_CMD "$MOUNT/boot/firmware" >/dev/null 2>&1; then
    if [[ "$DRY_RUN" -eq 1 ]]; then warn "$MOUNT/boot/firmware is not a mount point"; return; fi
    die "$MOUNT/boot/firmware is not a mount point. Mount the FAT firmware partition first, e.g.: sudo mkdir -p $MOUNT/boot/firmware && sudo mount /dev/disk/by-label/NIXOS_BOOT $MOUNT/boot/firmware"
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
        warn "no build record yet — run: rpi-install build (dry-run continues with placeholders)"
        sys="${sys:-<last recorded build: run rpi-install build>}"
        drv="${drv:-<last recorded drv>}"
      else
        die "no build record at $LAST — run: rpi-install build"
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
      die "system path not in local store: $sys (run ./install.sh build or nix build it)"
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

  if [[ "$DRY_RUN" -eq 0 ]]; then
    local sysname drvname
    sysname="$(basename "$sys")"
    drvname="$(basename "$drv")"
    [[ -d "$MOUNT/nix/store/$sysname" && -d "$MOUNT/nix/store/$drvname" ]] \
      || die "verification failed: system or drv not found in target store"
    [[ -e "$MOUNT/etc/NIXOS" ]] || warn "missing $MOUNT/etc/NIXOS; the install may be incomplete"
    [[ -e "$MOUNT/boot/firmware/config.txt" ]] || warn "no $MOUNT/boot/firmware/config.txt; the firmware partition was not populated, check before booting"
    [[ -e "$MOUNT/boot/firmware/u-boot-rpi-arm64.bin" ]] || warn "no $MOUNT/boot/firmware/u-boot-rpi-arm64.bin; U-Boot missing, the Pi will not boot"
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
  if [[ -d "$MOUNT" ]]; then
    echo "card    : mounted at $MOUNT"
  else
    echo "card    : not mounted"
  fi
  echo
  if [[ -f "$LAST" ]]; then
    echo "last build record ($LAST):"
    cat "$LAST"
  else
    echo "no build record yet — run: ./install.sh build"
  fi
}

# --- dispatch ----------------------------------------------------------------
case "$SUBCOMMAND" in
  build)   do_build ;;
  install) do_install ;;
  all)     do_build; do_install ;;
  show)    do_show ;;
esac
