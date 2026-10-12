#!/usr/bin/env bash
#
# install.sh — build this NixOS flake on the build host and install it onto
# a mounted SD card.
#
# Why this script (details in README.md):
#   * `nixos-install --root X` builds the entire closure into the *target*
#     store (X/nix/store, i.e. on the SD card, as root). The one-time
#     aarch64 kernel build takes hours; doing it for the SD is slow and
#     repeats after every re-flash of the card.
#   * This script instead:
#       1. builds the system in the HOST store (as a regular user; resumable,
#          reusable — the expensive kernel build happens once per kernel pin),
#       2. copies the built closure onto the card (a few minutes),
#       3. runs nixos-install, which then has nothing left to build.
#
# Usage:
#   ./install.sh [--mount DIR] [--attr NAME]
#
#   --mount DIR   mount point of the SD card root partition (default: /media/nixos)
#   --attr NAME   nixosConfigurations key (default: rpi)
#
# Run as a regular user with sudo rights. If started via `sudo`, the script
# re-execs itself as the original user — the long build must not run as root.
# Run it inside tmux/screen: the first build takes hours.

set -euo pipefail

MOUNT="/media/nixos"
ATTR="rpi"
STEP="startup"
LOG=""

banner() { printf '\n\033[1;36m==== %s ====\033[0m\n' "$*"; }
info()   { printf '  \033[36m*\033[0m %s\n' "$*"; }
warn()   { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
die()    { printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

on_error() {
  printf '\n\033[31m✗ failed in step "%s" (line %s)\033[0m\n' "$STEP" "$1" >&2
  if [[ "$STEP" == build* && -n "$LOG" ]]; then
    echo "  last 30 lines of the build log ($LOG):" >&2
    tail -30 "$LOG" | sed 's/^/  | /' >&2
  fi
  exit 1
}
trap 'on_error $LINENO' ERR

# ------------------------------------------------------------- arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mount) MOUNT="${2:?--mount needs a value}"; shift 2 ;;
    --attr)  ATTR="${2:?--attr needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

FLAKE="$MOUNT/etc/nixos"
FLAKE_BUILD="$FLAKE#nixosConfigurations.$ATTR.config.system.build.toplevel"

# ----------------------------------------- the build must not run as root --
if [[ $EUID -eq 0 ]]; then
  [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] \
    || die "refusing to run as root without a sudo user — start this script as a regular user (or via sudo)"
  info "re-executing as '$SUDO_USER' (build as regular user; sudo only for copy/install)"
  exec sudo -u "$SUDO_USER" env "PATH=$PATH" "$0" --mount "$MOUNT" --attr "$ATTR"
fi

# --------------------------------------------------------------- preflight --
STEP="preflight"
banner "preflight"
command -v nix >/dev/null || die "nix not found in PATH"
[[ -f "$FLAKE/flake.nix" ]] \
  || die "no flake at $FLAKE/flake.nix — wrong --mount? Expecting the SD root partition mounted there, containing etc/nixos/flake.nix"

if [[ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
  die "aarch64 emulation is not active on this host (no /proc/sys/fs/binfmt_misc/qemu-aarch64).
Enable it in the host's NixOS configuration:
    boot.binfmt.emulatedSystems = [ \"aarch64-linux\" ];
then 'nixos-rebuild switch' (and: sudo systemctl restart systemd-binfmt)."
fi
info "aarch64 emulation (qemu/binfmt): active"

if ! grep -h "extra-sandbox-paths" /etc/nix/nix.conf "${XDG_CONFIG_HOME:-$HOME/.config}/nix/nix.conf" 2>/dev/null | grep -q "qemu"; then
  warn "no 'extra-sandbox-paths' with the qemu handler found in the nix configuration — sandboxed aarch64 builds may fail with 'builder failed with exit code 255'."
else
  info "sandbox extra-sandbox-paths (qemu handler): found"
fi

if ! git -C "$FLAKE" diff --quiet 2>/dev/null || ! git -C "$FLAKE" diff --cached --quiet 2>/dev/null; then
  warn "git tree at $FLAKE is dirty — the build uses the working tree. Commit after the install to record what landed on the card."
fi

# ----------------------------------------------------------------- build ---
STEP="build (host store)"
banner "building in the host store"
info "building: $FLAKE_BUILD"
info "first run: hours (aarch64 kernel under qemu); later runs: fast (host /nix/store cache)"
info "if this is the first run, keep it alive: run install.sh inside tmux/screen"

LOG="$(mktemp "${TMPDIR:-/tmp}/rpi-install-build.XXXXXX")"
if ! nix build "$FLAKE_BUILD" --print-build-logs 2>&1 | tee "$LOG"; then
  echo "  --- last 30 lines of the build log ---" >&2
  tail -30 "$LOG" | sed 's/^/  | /' >&2
  echo "  ----------------------------------------" >&2
  if grep -q "builder failed with exit code 255" "$LOG"; then
    warn "hint: 'builder failed with exit code 255' = the aarch64 builder could not be exec'd under qemu — re-check binfmt/emulation and extra-sandbox-paths"
  elif grep -qiE "\bkilled\b|out of memory" "$LOG"; then
    warn "hint: build process killed — likely out of memory; an emulated kernel build needs a lot of RAM"
  fi
  die "build failed (full log: $LOG)"
fi

sys_path="$(nix build "$FLAKE_BUILD" --print-out-paths)"
drv_path="$(nix eval --raw "$FLAKE_BUILD.drvPath")"
info "built system: $sys_path"

# ----------------------------------------------------------------- copy ----
STEP="copy closure to target store"
banner "copying the closure onto the SD card"
host_store="$(dirname "$(dirname "$sys_path")")"
info "copying $sys_path (+ toplevel drv and flake sources) from $host_store to $MOUNT — a few minutes"
sudo -v
sudo nix copy --from "$host_store" --to "$MOUNT" "$sys_path" "$drv_path"

# --------------------------------------------------------------- install ---
STEP="nixos-install"
banner "installing onto $MOUNT"
info "nixos-install --root $MOUNT --flake $FLAKE#$ATTR"
info "everything is already in the target store — no cross builds happen here"
sudo -v
sudo nixos-install --root "$MOUNT" --flake "$FLAKE#$ATTR"

# --------------------------------------------------------------- verify ----
STEP="verify"
banner "verifying the result"
[[ -e "$MOUNT/etc/NIXOS" ]] \
  && info "target is marked as a NixOS system (etc/NIXOS)" \
  || warn "missing $MOUNT/etc/NIXOS — the install may be incomplete"

store_count="$(ls "$MOUNT/nix/store" 2>/dev/null | wc -l)"
info "target store: $store_count paths"

[[ -e "$MOUNT/boot/kernel8.img" ]] \
  && info "boot kernel present (boot/kernel8.img)" \
  || warn "no boot/kernel8.img — check the boot partition before booting"

banner "done"
info "system:  $sys_path"
info "target:  $MOUNT"
info "next:    boot the Pi, then  ssh -p 2222 pi@<pi-address>"
info "later:   re-run ./install.sh after config changes (fast), or nixos-rebuild switch on the Pi"
info "log:     $LOG (safe to delete)"
