#!/usr/bin/env bash
#
# rpi-deploy — build the Raspberry Pi SD image, write it to a card once, and
# push every later change from this host (see README).
#
# The guards (kernel in nvmd's cache, no kernel/toolchain build, at most
# --max-builds local builds), the ssh helpers and the reboot decision live in
# rpi-lib.sh (rpi-pull on the Pi shares rpi-fp.sh).

set -euo pipefail

RPI_LIB="${RPI_LIB:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/rpi-lib.sh}"
# shellcheck source=rpi-lib.sh
source "$RPI_LIB"

usage() {
    cat <<'EOF'
Usage:
  rpi-deploy image [--out DIR] [--flake DIR] [--attr NAME] [--max-builds N]
  rpi-deploy flash IMAGE DEVICE
  rpi-deploy deploy [switch|boot|test] [--target USER@HOST] [--port N] [--flake DIR] [--attr NAME] [--max-builds N] [--force]
  rpi-deploy status [--target USER@HOST] [--port N]

  image    build config.system.build.sdImage of the flake's Pi system (after
           the cache and build guards) and print the image path and size
  flash    write IMAGE (.img.zst) to the removable DEVICE with sudo dd, after
           you type the device name; then read it back and compare hashes
  deploy   push the system to the Pi with the flake's pinned nixos-rebuild
           (default action: switch; boot = activate on next reboot; test =
           activate without making it the boot default), then sync on
           the Pi; refuses when origin/main's flake.lock pins a
           newer nixpkgs or nixos-raspberrypi than the working tree's
           (git pull first; or a lock is unreadable) unless --force
  status   current, booted and boot-default generation on the Pi, and whether
           a reboot is pending (the boot default is not running, or its
           kernel, initrd, modules, dtbs, kernel-params or NIXOS_BOOT
           firmware/config.txt/U-Boot differ from the booted system's)

Defaults: --flake $RPI_FLAKE or the current directory, --attr rpi,
  --target root@neptun, --port 2222, --max-builds 500, --out the current
  directory.
Environment: RPI_FLAKE (default flake dir), RPI_SSH_OPTS (extra ssh options),
  RPI_NIXOS_REBUILD (nixos-rebuild to use instead of the flake's pinned one),
  RPI_LIB (path of rpi-lib.sh); test hooks RPI_ALLOW_NONBLOCK=1, RPI_SYSFS.
Exit codes: 2 usage, 10 kernel not cached, 11 forbidden local build,
  12 too many local builds, 13 build/eval failed, 14 deploy failed,
  15 would downgrade, 16 device refused, 17 verify failed.
EOF
}

log() { printf '==> %s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { die_rc 1 "$@"; }
die_rc() {
    local rc="$1"
    shift
    printf 'rpi-deploy: error: %s\n' "$*" >&2
    exit "$rc"
}
usage_error() {
    printf 'rpi-deploy: %s\n' "$*" >&2
    echo "Run 'rpi-deploy --help' for usage." >&2
    exit "$RL_E_USAGE"
}

# --- subcommands -----------------------------------------------------------
# image: guards, then build the SD image of the very system later deploys use.
do_image() {
    mkdir -p "$OUT_DIR"
    OUT_DIR="$(cd "$OUT_DIR" && pwd)"
    log "guards: $(rl_conf_ref) (sdImage, at most $MAX_BUILDS local builds)"
    rl_guard sdImage "$MAX_BUILDS" || die_rc $? "guard failed; nothing was built"
    log "building the SD image"
    nix build --accept-flake-config --out-link "$OUT_DIR/result-rpi-image" \
        "$(rl_conf_ref).config.system.build.sdImage" ||
        die_rc "$RL_E_BUILD" "image build failed"
    local -a imgs
    shopt -s nullglob
    imgs=("$OUT_DIR"/result-rpi-image/sd-image/*.img.zst)
    shopt -u nullglob
    [[ ${#imgs[@]} -eq 1 ]] || die_rc "$RL_E_BUILD" "no single *.img.zst in $OUT_DIR/result-rpi-image/sd-image"
    echo "image: ${imgs[0]}"
    echo "size:  $(du -h --apparent-size "${imgs[0]}" | cut -f1) (zstd)"
    echo "next:  rpi-deploy flash ${imgs[0]} /dev/sdX"
}

# blk PROP DEV: one lsblk property of DEV itself (not its partitions), trimmed.
blk() {
    local v
    v="$(lsblk -dno "$1" -- "$2" 2>/dev/null)" || v=""
    v="${v#"${v%%[![:space:]]*}"}"
    printf '%s\n' "${v%"${v##*[![:space:]]}"}"
}

# is_sd_card NAME: NAME is an mmcblkN whose card is an SD card (not eMMC).
# RPI_SYSFS (default /sys) is a test hook.
is_sd_card() {
    local t=""
    [[ "$1" =~ ^mmcblk[0-9]+$ ]] || return 1
    read -r t <"${RPI_SYSFS:-/sys}/block/$1/device/type" 2>/dev/null || true
    [[ "$t" == SD ]]
}

# flash_check_device DEV: refuse anything but an unmounted, removable whole
# disk (or SD card in a built-in reader) that does not hold the host's /.
flash_check_device() {
    local dev="$1" name type rm root mounts
    if [[ ! -b "$dev" ]] && ! [[ "${RPI_ALLOW_NONBLOCK:-0}" == 1 && -f "$dev" ]]; then
        die_rc "$RL_E_DEVICE" "$dev is not a block device"
    fi
    name="$(basename "$dev")"
    type="$(blk TYPE "$dev")"
    [[ "$type" == disk ]] ||
        die_rc "$RL_E_DEVICE" "$dev is a '${type:-unknown}', not a whole disk (give e.g. /dev/sdb, not /dev/sdb1)"
    # MMC/SD block devices never carry the removable flag (linux
    # drivers/mmc/core/block.c: the medium is removable, not the device), so
    # an SD card in a built-in reader (mmcblkN, RM=0, sysfs device/type
    # "SD") counts as removable; eMMC (type "MMC", soldered in) does not.
    rm="$(blk RM "$dev")"
    if [[ "$rm" != 1 ]] && ! is_sd_card "$name"; then
        die_rc "$RL_E_DEVICE" "$dev is not removable (RM=${rm:-?}); refusing to overwrite it"
    fi
    root="$(findmnt -nro SOURCE --mountpoint / 2>/dev/null)" || root=""
    root="${root%%\[*}" # btrfs subvolume suffix: /dev/sda2[/@]
    if [[ -n "$root" ]] && lsblk -nlso NAME -- "$root" 2>/dev/null | grep -qxF -- "$name"; then
        die_rc "$RL_E_DEVICE" "$dev holds the host's / ($root); refusing"
    fi
    # fail closed: unknown mount points count as mounted
    mounts="$(lsblk -nlo MOUNTPOINTS -- "$dev")" ||
        die_rc "$RL_E_DEVICE" "cannot list the mount points of $dev (lsblk failed); refusing"
    mounts="$(printf '%s\n' "$mounts" | grep -v '^[[:space:]]*$' | tr '\n' ' ')" || true
    [[ -z "$mounts" ]] ||
        die_rc "$RL_E_DEVICE" "$dev has mounted partitions (${mounts% }); unmount them first"
}

# flash_confirm DEV [AS_GIVEN]: show the device and read the typed name.
flash_confirm() {
    local dev="$1" given="${2:-$1}" name answer model
    name="$(basename "$dev")"
    model="$(blk MODEL "$dev")"
    echo "device: $dev"
    echo "model:  ${model:-unknown}"
    echo "size:   $(blk SIZE "$dev")"
    echo "ALL DATA ON $dev WILL BE LOST."
    printf 'To write the image, type the device name (%s): ' "$name"
    IFS= read -r answer || answer=""
    echo
    [[ -n "$answer" && ( "$answer" == "$name" || "$answer" == "$dev" || "$answer" == "$given" ) ]] ||
        die_rc "$RL_E_DEVICE" "confirmation '$answer' does not match '$name'; nothing written"
}

# flash_write IMG DEV: the only privileged write.
flash_write() {
    zstdcat "$1" | sudo dd of="$2" bs=4M conv=fsync oflag=direct status=progress iflag=fullblock
}

# flash_verify IMG DEV: read back the written length, compare sha256.
flash_verify() {
    local img="$1" dev="$2" len want got
    len="$(zstdcat "$img" | wc -c)"
    want="$(zstdcat "$img" | sha256sum | cut -d' ' -f1)"
    got="$(sudo head -c "$len" "$dev" | sha256sum | cut -d' ' -f1)" ||
        die_rc "$RL_E_VERIFY" "verify failed: cannot read $dev back"
    [[ "$want" == "$got" ]] ||
        die_rc "$RL_E_VERIFY" "verify failed: the first $len bytes of $dev differ from the image (sha256 $got, want $want)"
    echo "verified: $len bytes, sha256 $want"
}

# flash IMAGE DEVICE
do_flash() {
    local img="$1" dev
    [[ -f "$img" ]] || usage_error "flash: no such image file: $img"
    dev="$(readlink -f -- "$2")" || dev="$2"
    flash_check_device "$dev"
    flash_confirm "$dev" "$2"
    log "writing $img to $dev (sudo dd)"
    flash_write "$img" "$dev" || die "writing $dev failed"
    log "reading $dev back (sudo)"
    flash_verify "$img" "$dev"
    echo "done: the card can be removed"
}

# Root inputs whose lock decides whether a checkout is behind origin/main.
DOWNGRADE_INPUTS=(nixpkgs nixos-raspberrypi)

# lock_last_modified INPUT < flake.lock: locked.lastModified of root input
# INPUT ('' when the lock has no such input); non-zero when unparsable.
lock_last_modified() {
    local v
    v="$(jq -r --arg i "$1" \
        '(.nodes[.root].inputs[$i] // empty) as $k | .nodes[$k].locked.lastModified // empty' 2>/dev/null)" ||
        return 1
    [[ -z "$v" || "$v" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$v"
}

# check_downgrade: refuse (unless --force) when the local ref origin/main of
# the flake's git repo (never fetched here) locks a newer nixpkgs or
# nixos-raspberrypi (by locked.lastModified) than the working tree's
# flake.lock: deploying would roll the Pi back from what CI already committed.
# Compares lock content, not ancestry, so squash/cherry-pick merges and a
# `nix flake update` on main count. Fails closed when a lock cannot be read.
# Skipped outside git, without an origin remote or refs/remotes/origin/main,
# and without a lock for this flake on it.
check_downgrade() {
    local om_lock wt_lock input om wt newer=() problem=""
    git -C "$RL_FLAKE" rev-parse --git-dir >/dev/null 2>&1 || return 0
    git -C "$RL_FLAKE" remote get-url origin >/dev/null 2>&1 || return 0
    git -C "$RL_FLAKE" rev-parse -q --verify refs/remotes/origin/main >/dev/null || return 0
    om_lock="$(git -C "$RL_FLAKE" show refs/remotes/origin/main:./flake.lock 2>/dev/null)" || return 0
    if ! wt_lock="$(cat "$RL_FLAKE/flake.lock" 2>/dev/null)"; then
        problem="cannot compare: $RL_FLAKE/flake.lock is missing"
    else
        for input in "${DOWNGRADE_INPUTS[@]}"; do
            if ! om="$(lock_last_modified "$input" <<<"$om_lock")"; then
                problem="cannot compare: the flake.lock of origin/main is unreadable"
                break
            fi
            if ! wt="$(lock_last_modified "$input" <<<"$wt_lock")"; then
                problem="cannot compare: $RL_FLAKE/flake.lock is unreadable"
                break
            fi
            [[ -n "$om" && -n "$wt" ]] && ((om > wt)) &&
                newer+=("$input ($(date -u -d "@$om" +%F) > $(date -u -d "@$wt" +%F))")
        done
        [[ ${#newer[@]} -eq 0 ]] || problem="origin/main locks a newer ${newer[*]}"
    fi
    [[ -n "$problem" ]] || return 0
    if [[ "$FORCE" -eq 1 ]]; then
        warn "$problem (vs origin/main); deploying anyway (--force)"
        return 0
    fi
    die_rc "$RL_E_DOWNGRADE" "would downgrade: $problem;" \
        "run 'git pull' first, or deploy anyway with --force"
}

# deploy [switch|boot|test]: downgrade check, guards, pinned nixos-rebuild.
do_deploy() {
    check_downgrade
    log "guards: $(rl_conf_ref) (toplevel, at most $MAX_BUILDS local builds)"
    rl_guard toplevel "$MAX_BUILDS" || die_rc $? "guard failed; the Pi was not touched"
    log "nixos-rebuild $ACTION --target-host $RL_TARGET (port $RL_SSH_PORT)"
    local rc=0
    rl_nixos_rebuild "$ACTION" --no-reexec --flake "$RL_FLAKE#$RL_ATTR" --target-host "$RL_TARGET" || rc=$?
    # switch/boot rewrite the vfat NIXOS_BOOT, and switch-to-configuration
    # only syncs the store's filesystem: flush the Pi's caches now (after a
    # failure too -- the bootloader may already be installed).
    rl_ssh sync || warn "sync on $RL_TARGET failed: run 'sync' there before cutting its power"
    ((rc == 0)) || die_rc "$RL_E_DEPLOY" "nixos-rebuild $ACTION failed"
    case "$ACTION" in
    switch) (do_status) || warn "deployed, but the status query failed" ;;
    boot) log "the new generation becomes active after the next reboot (see: rpi-deploy status)" ;;
    test) log "activated until the next reboot (boot default unchanged)" ;;
    esac
}

# status: the running, booted and boot-default systems, and whether a reboot
# would change the running system: the boot default is not running (after
# `deploy boot`/`test`), or its boot fingerprint (rl_fp_*: kernel, initrd,
# modules, dtbs, kernel-params, NIXOS_BOOT inputs) differs from the booted
# system's (after a switch to a new kernel or firmware).
do_status() {
    local systems fp_booted fp_default
    systems="$(rl_ssh readlink -e /run/current-system /run/booted-system /nix/var/nix/profiles/system)" &&
        fp_booted="$(rl_fp_remote /run/booted-system)" &&
        fp_default="$(rl_fp_remote /nix/var/nix/profiles/system)" ||
        die "cannot reach $RL_TARGET (port $RL_SSH_PORT)"
    local -a s reasons=()
    mapfile -t s <<<"$systems"
    echo "current: ${s[0]:-?}"
    echo "booted: ${s[1]:-?}"
    echo "default: ${s[2]:-?}"
    [[ "${s[2]:-}" == "${s[0]:-}" ]] || reasons+=("the boot default is not the running system")
    if rl_needs_reboot "$fp_default" "$fp_booted"; then
        reasons+=("changed since boot: $(rl_fp_changed "$fp_booted" "$fp_default")")
    fi
    if ((${#reasons[@]} == 0)); then
        echo "reboot pending: no"
    elif ((${#reasons[@]} == 1)); then
        echo "reboot pending: yes (${reasons[0]})"
    else
        echo "reboot pending: yes (${reasons[0]}; ${reasons[1]})"
    fi
}

# --- argument parsing --------------------------------------------------------
SUBCOMMAND=""
OUT_DIR="$PWD"
MAX_BUILDS=500
FORCE=0
ACTION=""
POSITIONAL=()
RL_FLAKE="${RPI_FLAKE:-$PWD}"
RL_ATTR=rpi
RL_TARGET=root@neptun
RL_SSH_PORT=2222

# Options each subcommand accepts.
declare -A ALLOWED=(
    [image]=" --out --flake --attr --max-builds "
    [flash]=" "
    [deploy]=" --target --port --flake --attr --max-builds --force "
    [status]=" --target --port "
)

parse_args() {
    if [[ $# -eq 0 ]]; then
        usage >&2
        exit "$RL_E_USAGE"
    fi
    case "$1" in
    -h | --help)
        usage
        exit 0
        ;;
    image | flash | deploy | status) SUBCOMMAND="$1" ;;
    *) usage_error "unknown subcommand: $1" ;;
    esac
    shift
    local opt
    while [[ $# -gt 0 ]]; do
        opt="$1"
        case "$opt" in
        -h | --help)
            usage
            exit 0
            ;;
        --) shift; POSITIONAL+=("$@"); break ;;
        -*)
            [[ "${ALLOWED[$SUBCOMMAND]}" == *" $opt "* ]] ||
                usage_error "$SUBCOMMAND: unknown option: $opt"
            if [[ "$opt" == --force ]]; then
                FORCE=1
                shift
                continue
            fi
            [[ $# -ge 2 ]] || usage_error "$opt needs a value"
            case "$opt" in
            --out) OUT_DIR="$2" ;;
            --flake) RL_FLAKE="$2" ;;
            --attr) RL_ATTR="$2" ;;
            --target) RL_TARGET="$2" ;;
            --port | --max-builds)
                [[ "$2" =~ ^[0-9]+$ ]] || usage_error "$opt needs a number, got '$2'"
                if [[ "$opt" == --port ]]; then RL_SSH_PORT="$2"; else MAX_BUILDS="$2"; fi
                ;;
            esac
            shift 2
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
        esac
    done
    case "$SUBCOMMAND" in
    flash)
        [[ ${#POSITIONAL[@]} -eq 2 ]] || usage_error "flash needs IMAGE and DEVICE"
        ;;
    deploy)
        [[ ${#POSITIONAL[@]} -le 1 ]] || usage_error "deploy takes at most one action"
        ACTION="${POSITIONAL[0]:-switch}"
        case "$ACTION" in
        switch | boot | test) ;;
        *) usage_error "deploy: unknown action '$ACTION' (switch, boot or test)" ;;
        esac
        ;;
    *)
        [[ ${#POSITIONAL[@]} -eq 0 ]] || usage_error "$SUBCOMMAND: unexpected argument: ${POSITIONAL[0]}"
        ;;
    esac
}

main() {
    parse_args "$@"
    case "$SUBCOMMAND" in
    image) do_image ;;
    flash) do_flash "${POSITIONAL[0]}" "${POSITIONAL[1]}" ;;
    deploy) do_deploy ;;
    status) do_status ;;
    esac
}

main "$@"
