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
  rpi-deploy image [--out DIR] [--flake DIR] [--host NAME] [--max-builds N]
  rpi-deploy flash IMAGE DEVICE [--wifi-env] [--flake DIR] [--host NAME]
  rpi-deploy deploy [switch|boot|test] [--host NAME] [--target USER@HOST] [--port N] [--flake DIR] [--max-builds N] [--force]
  rpi-deploy status [--host NAME] [--target USER@HOST] [--port N] [--flake DIR]
  rpi-deploy secrets [--host NAME] [--target USER@HOST] [--port N] [--flake DIR]

  image    build config.system.build.sdImage of the flake's Pi system (after
           the cache and build guards) and print the image path and size
  flash    write IMAGE (.img.zst) to the removable DEVICE with sudo dd, after
           you type the device name; then read it back and compare hashes;
           --wifi-env: then also write the host's Wi-Fi secrets file (see
           secrets) into the card's root partition; the PSK variables are
           checked before anything is written
  deploy   push the system to the Pi with the flake's pinned nixos-rebuild
           (default action: switch; boot = activate on next reboot; test =
           activate without making it the boot default), then sync on
           the Pi; refuses when origin/main's flake.lock pins a
           newer nixpkgs or nixos-raspberrypi than the working tree's
           (git pull first; or a lock is unreadable) unless --force
  status   current, booted and boot-default generation on the Pi, and whether
           a reboot is pending (the boot default is not running, or its
           kernel, initrd, modules, dtbs, kernel-params or NIXOS_BOOT
           firmware/config.txt/U-Boot differ from the booted system's); then the
           pull state: the applied pointer seq and its age, and the last
           rpi-pull run (result, exit code, time) from /var/lib/rpi-pull
  secrets  write the host's Wi-Fi secrets file (rpi.wifi.secretsFile, mode
           600, handed to the wpa_supplicant user by the host's tmpfiles
           rule) on the Pi over ssh, then restart wpa_supplicant if it runs:
           one VAR=PSK line per variable named in rpi.wifi.networks, the
           values from the environment (e.g. secretspec run -- rpi-deploy
           secrets); a value is never printed or put on a command line

Host: --host NAME selects the flake's nixosConfigurations.NAME; default
  $RPI_HOST, else the flake's only Pi host (built with lib.mkPi); none or
  several -> exit 2. --attr NAME is a deprecated alias of --host.
Target: --target > $RPI_TARGET > the host's rpi.deploy.target; port: --port >
  $RPI_PORT > the host's rpi.ssh.port (the host is evaluated only when one of
  the two is missing).
Defaults: --flake $RPI_FLAKE or the current directory, --max-builds 500,
  --out the current directory.
Environment: RPI_FLAKE (default flake dir), RPI_HOST (default host),
  RPI_TARGET, RPI_PORT (default target and port), RPI_SSH_OPTS (extra ssh
  options),
  RPI_NIXOS_REBUILD (nixos-rebuild to use instead of the flake's pinned one),
  RPI_LIB (path of rpi-lib.sh); test hooks RPI_ALLOW_NONBLOCK=1, RPI_SYSFS,
  RPI_PART_WAIT (seconds to wait for the card's root partition, 10).
Exit codes: 2 usage, 10 kernel not cached, 11 forbidden local build,
  12 too many local builds, 13 build/eval failed, 14 deploy/secrets failed,
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

# --- host selection ----------------------------------------------------------
# resolve_host: RL_ATTR = --host/--attr, else $RPI_HOST, else the flake's only
# Pi host (rl_hosts); none or several -> exit 2 (usage), no listing when a
# name is given. The name must be a plain attribute name.
resolve_host() {
    local hosts
    local -a list=()
    [[ -n "$RL_ATTR" ]] || RL_ATTR="${RPI_HOST:-}"
    if [[ -z "$RL_ATTR" ]]; then
        hosts="$(rl_hosts "$RL_FLAKE")" ||
            die_rc "$RL_E_BUILD" "cannot list the Pi hosts of $RL_FLAKE"
        [[ -z "$hosts" ]] || mapfile -t list <<<"$hosts"
        case ${#list[@]} in
        0) die_rc "$RL_E_USAGE" "no Pi host (lib.mkPi) in $RL_FLAKE" ;;
        1) RL_ATTR="${list[0]}" ;;
        *) die_rc "$RL_E_USAGE" "several Pi hosts: ${list[*]}; pick one with --host or RPI_HOST" ;;
        esac
        log "host: $RL_ATTR (the only Pi host in $RL_FLAKE)"
    fi
    [[ "$RL_ATTR" =~ ^[A-Za-z0-9_-]+$ ]] ||
        die_rc "$RL_E_USAGE" "invalid host name: '$RL_ATTR'"
}

# load_info: HOST_INFO = rl_host_info of the selected host (evaluated once).
load_info() {
    [[ -z "$HOST_INFO" ]] || return 0
    resolve_host
    HOST_INFO="$(rl_host_info "$RL_FLAKE" "$RL_ATTR")" ||
        die_rc "$RL_E_BUILD" "cannot evaluate the host config of $(rl_conf_ref)" \
            "(rpi.deploy.target, rpi.ssh.port, rpi.wifi); give --target and --port" \
            "or set RPI_TARGET and RPI_PORT"
}

# info FILTER: a jq -r FILTER of HOST_INFO ('' for null/missing).
info() { jq -r "($1) // empty" <<<"$HOST_INFO"; }

# resolve_target: RL_TARGET = --target > $RPI_TARGET > rpi.deploy.target,
# RL_SSH_PORT = --port > $RPI_PORT > rpi.ssh.port; the host info is evaluated
# only when one of them is still missing.
resolve_target() {
    RL_TARGET="${TARGET_OPT:-${RPI_TARGET:-}}"
    RL_SSH_PORT="${PORT_OPT:-${RPI_PORT:-}}"
    [[ -n "$RL_TARGET" && -n "$RL_SSH_PORT" ]] && return 0
    load_info
    if [[ -z "$RL_TARGET" ]]; then
        RL_TARGET="$(info .target)" && [[ -n "$RL_TARGET" ]] ||
            die_rc "$RL_E_BUILD" "no rpi.deploy.target in the host config of $(rl_conf_ref)"
    fi
    if [[ -z "$RL_SSH_PORT" ]]; then
        RL_SSH_PORT="$(info .port)" && [[ "$RL_SSH_PORT" =~ ^[0-9]+$ ]] ||
            die_rc "$RL_E_BUILD" "no valid rpi.ssh.port in the host config of $(rl_conf_ref)"
    fi
}

# --- Wi-Fi secrets -----------------------------------------------------------
# wifi_secrets_file: rpi.wifi.secretsFile of the host, checked: it is put on a
# remote command line and below a mount point, so only a plain absolute path.
wifi_secrets_file() {
    local f
    f="$(info .wifi.secretsFile)" || die_rc "$RL_E_BUILD" "cannot read rpi.wifi.secretsFile of $RL_ATTR"
    [[ "$f" =~ ^/[A-Za-z0-9._/-]*[A-Za-z0-9._-]$ && "/$f/" != */../* ]] ||
        die_rc "$RL_E_USAGE" "rpi.wifi.secretsFile of $RL_ATTR must be a plain absolute file path, got '$f'"
    printf '%s\n' "$f"
}

# wifi_env_content: the host's Wi-Fi secrets file on stdout: one VAR=value
# line per PSK variable named in rpi.wifi.networks (SSID -> VAR), values from
# the environment; lines sorted (LC_ALL=C) and unique (P8). Wi-Fi off, no
# networks, an invalid name, an unset/empty value or a value with a newline
# -> exit 2 naming the variable (never its value), before any output. Values
# only ever pass through printf (a builtin): never argv, never a file.
wifi_env_content() {
    local _w_rows _w_var _w_ssid
    local -a _w_vars _w_problems=()
    local -A _w_ssid_of=()
    [[ "$(info .wifi.enable)" == true ]] || die_rc "$RL_E_USAGE" "rpi.wifi is disabled for $RL_ATTR"
    _w_rows="$(jq -r '.wifi.networks // {} | to_entries[] | [.value, .key] | @tsv' <<<"$HOST_INFO")" ||
        die_rc "$RL_E_BUILD" "cannot read rpi.wifi.networks of $RL_ATTR"
    [[ -n "$_w_rows" ]] || die_rc "$RL_E_USAGE" "rpi.wifi.networks is empty for $RL_ATTR"
    while IFS=$'\t' read -r _w_var _w_ssid; do
        if [[ ! "$_w_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            _w_problems+=("invalid PSK variable name '$_w_var' (rpi.wifi.networks.\"$_w_ssid\")")
        elif [[ -z "${_w_ssid_of[$_w_var]+set}" ]]; then
            _w_ssid_of[$_w_var]="$_w_ssid"
        fi
    done <<<"$_w_rows"
    # sorting "VAR=" orders exactly like sorting the "VAR=value" lines
    mapfile -t _w_vars < <(printf '%s=\n' "${!_w_ssid_of[@]}" | LC_ALL=C sort | sed 's/=$//')
    for _w_var in "${_w_vars[@]}"; do
        [[ -n "$_w_var" ]] || continue
        if [[ -z "${!_w_var:-}" ]]; then
            _w_problems+=("missing PSK variable $_w_var (rpi.wifi.networks.\"${_w_ssid_of[$_w_var]}\")")
        elif [[ "${!_w_var}" == *$'\n'* ]]; then
            _w_problems+=("$_w_var contains a newline")
        fi
    done
    if ((${#_w_problems[@]} > 0)); then
        printf 'rpi-deploy: error: %s\n' "${_w_problems[@]}" >&2
        exit "$RL_E_USAGE"
    fi
    for _w_var in "${_w_vars[@]}"; do
        printf '%s=%s\n' "$_w_var" "${!_w_var}"
    done
}

# secrets: the Wi-Fi secrets file onto the Pi through ssh's stdin. The
# directory is created 0700 only when missing (install -d would chmod an
# existing one, e.g. /etc). The file is written root 0600, then the
# module's tmpfiles rule (z FILE 0600 wpa_supplicant ...) hands it to the
# daemon's user; without Wi-Fi deployed yet there is no rule (and no such
# user) and the next switch applies it. try-restart leaves a stopped unit
# stopped.
do_secrets() {
    local file content
    load_info
    file="$(wifi_secrets_file)" || exit
    content="$(wifi_env_content)" || exit
    resolve_target
    log "writing $file (600) on $RL_TARGET (port $RL_SSH_PORT)"
    # \n: $(...) dropped the last line's newline
    printf '%s\n' "$content" |
        rl_ssh "mkdir -p -m 700 ${file%/*} && install -m 600 /dev/stdin $file && systemd-tmpfiles --create --prefix=$file && systemctl try-restart wpa_supplicant.service" ||
        die_rc "$RL_E_DEPLOY" "writing $file on $RL_TARGET failed"
    echo "secrets: $file written on $RL_TARGET; wpa_supplicant restarted if it was running"
}

# --- subcommands -----------------------------------------------------------
# image: guards, then build the SD image of the very system later deploys use.
do_image() {
    resolve_host
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

# flash_present PATH: PATH is a block device (a regular file with
# RPI_ALLOW_NONBLOCK=1, the test hook of flash_check_device).
flash_present() {
    [[ -b "$1" ]] || [[ "${RPI_ALLOW_NONBLOCK:-0}" == 1 && -f "$1" ]]
}

# flash_umount: unmount FLASH_MNT (once; also the EXIT trap while mounted)
# and remove the mount point.
FLASH_MNT=""
flash_umount() {
    [[ -n "$FLASH_MNT" ]] || return 0
    local m="$FLASH_MNT"
    FLASH_MNT=""
    if ! sudo umount "$m"; then
        warn "cannot unmount $m: unmount it (sudo umount $m) before removing the card"
        return 1
    fi
    rmdir "$m" 2>/dev/null || true
}

# flash_wifi DEV FILE CONTENT: after the verify, write CONTENT (the Wi-Fi
# secrets file) as FILE (root:root 600; the card has no wpa_supplicant
# user yet: the module's tmpfiles rule hands the file to it at the first
# boot, before wpa_supplicant starts) into DEV's root partition 2
# (/dev/sdb -> /dev/sdb2, /dev/mmcblk0 -> /dev/mmcblk0p2). udev re-reads
# the partition table when dd closes the device; wait for the node. CONTENT
# reaches install through its stdin only. The card is unmounted on failure.
flash_wifi() {
    local dev="$1" file="$2" content="$3" part mnt rc=0 urc=0 i wait="${RPI_PART_WAIT:-10}"
    [[ "$wait" =~ ^[0-9]+$ ]] || wait=10
    if [[ "$dev" =~ [0-9]$ ]]; then part="${dev}p2"; else part="${dev}2"; fi
    for ((i = 0; i < wait; i++)); do
        flash_present "$part" && break
        sleep 1
    done
    flash_present "$part" ||
        die "the root partition $part did not appear; the Wi-Fi secrets were not written"
    mnt="$(mktemp -d)" || die "cannot create a mount point; the Wi-Fi secrets were not written"
    log "writing $file (600) onto $part (sudo mount)"
    if ! sudo mount "$part" "$mnt"; then
        rmdir "$mnt"
        die "cannot mount $part; the Wi-Fi secrets were not written"
    fi
    FLASH_MNT="$mnt"
    trap flash_umount EXIT
    # \n: $(...) dropped the last line's newline
    printf '%s\n' "$content" |
        sudo install -D -m 600 -o root -g root /dev/stdin "$mnt$file" || rc=$?
    flash_umount || urc=$?
    trap - EXIT
    ((rc == 0)) || die "writing $file onto $part failed; the Wi-Fi secrets were not written"
    ((urc == 0)) || die "$file was written onto $part, but the card is still mounted"
    echo "wifi: $file written onto $part (root 0600; the first boot hands it to wpa_supplicant)"
}

# flash IMAGE DEVICE [--wifi-env]
do_flash() {
    local img="$1" dev file="" content=""
    [[ -f "$img" ]] || usage_error "flash: no such image file: $img"
    if ((WIFI_ENV)); then # every PSK problem before the card is touched
        load_info
        file="$(wifi_secrets_file)" || exit
        content="$(wifi_env_content)" || exit
    fi
    dev="$(readlink -f -- "$2")" || dev="$2"
    flash_check_device "$dev"
    flash_confirm "$dev" "$2"
    log "writing $img to $dev (sudo dd)"
    flash_write "$img" "$dev" || die "writing $dev failed"
    log "reading $dev back (sudo)"
    flash_verify "$img" "$dev"
    ((WIFI_ENV == 0)) || flash_wifi "$dev" "$file" "$content"
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
    resolve_host
    resolve_target
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

# The pull state on the Pi, one ssh round trip: the unit's load state and the
# state files rpi-pull writes (seq, store-path, last-run), plus the age in
# seconds of seq (= when the pointer was applied). key=value lines.
RL_PULL_QUERY='systemctl show -p LoadState rpi-pull.service
d=/var/lib/rpi-pull
for f in seq store-path last-run; do
    [ -r "$d/$f" ] && { printf "%s=" "$f"; head -n 1 "$d/$f"; }
done
[ -r "$d/seq" ] && echo "age=$(( $(date +%s) - $(stat -c %Y "$d/seq") ))"
exit 0'

# fmt_age SECONDS: 90 -> 1m, 7200 -> 2h, 172800 -> 2d
fmt_age() {
    local s="$1"
    if ((s < 3600)); then
        echo "$((s / 60))m"
    elif ((s < 172800)); then
        echo "$((s / 3600))h"
    else
        echo "$((s / 86400))d"
    fi
}

# status_pull: the pull state (rpi-pull) as the last lines of status: what was
# applied (seq, store path, age) and the last run (result, exit, time). Never
# fails status: an unanswerable query prints "pull: unknown".
status_pull() {
    local out line key val load="" seq="" path="" age="" last=""
    if ! out="$(rl_ssh "$RL_PULL_QUERY" 2>/dev/null)"; then
        echo "pull: unknown (cannot query rpi-pull on $RL_TARGET)"
        return 0
    fi
    while IFS= read -r line; do
        key="${line%%=*}" val="${line#*=}"
        case "$key" in
        LoadState) load="$val" ;;
        seq) seq="$val" ;;
        store-path) path="$val" ;;
        age) age="$val" ;;
        last-run) last="$val" ;;
        esac
    done <<<"$out"
    if [[ "$load" == not-found ]]; then
        echo "pull: disabled"
        return 0
    fi
    if [[ "$seq" =~ ^[0-9]+$ ]]; then
        [[ "$age" =~ ^[0-9]+$ ]] && age=" ($(fmt_age "$age") ago)" || age=""
        echo "pull applied: seq $seq $path$age"
    else
        echo "pull applied: none"
    fi
    if [[ "$last" =~ ^time=(.*)\ exit=([0-9]+)\ result=(.*)$ ]]; then
        echo "pull last run: ${BASH_REMATCH[3]} (exit ${BASH_REMATCH[2]}) at ${BASH_REMATCH[1]}"
    else
        echo "pull last run: never"
    fi
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
    status_pull
}

# --- argument parsing --------------------------------------------------------
SUBCOMMAND=""
OUT_DIR="$PWD"
MAX_BUILDS=500
FORCE=0
WIFI_ENV=0
ACTION=""
POSITIONAL=()
RL_FLAKE="${RPI_FLAKE:-$PWD}"
RL_ATTR="" # resolve_host
RL_TARGET="" RL_SSH_PORT="" # resolve_target
TARGET_OPT="" PORT_OPT=""     # --target, --port
HOST_INFO=""                  # load_info

# Options each subcommand accepts.
declare -A ALLOWED=(
    [image]=" --out --flake --host --attr --max-builds "
    [flash]=" --wifi-env --flake --host --attr "
    [deploy]=" --target --port --flake --host --attr --max-builds --force "
    [status]=" --target --port --flake --host --attr "
    [secrets]=" --target --port --flake --host --attr "
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
    image | flash | deploy | status | secrets) SUBCOMMAND="$1" ;;
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
            if [[ "$opt" == --force || "$opt" == --wifi-env ]]; then
                if [[ "$opt" == --force ]]; then FORCE=1; else WIFI_ENV=1; fi
                shift
                continue
            fi
            [[ $# -ge 2 ]] || usage_error "$opt needs a value"
            case "$opt" in
            --out) OUT_DIR="$2" ;;
            --flake) RL_FLAKE="$2" ;;
            --host) RL_ATTR="$2" ;;
            --attr)
                echo "rpi-deploy: --attr is deprecated, use --host" >&2
                RL_ATTR="$2"
                ;;
            --target) TARGET_OPT="$2" ;;
            --port | --max-builds)
                [[ "$2" =~ ^[0-9]+$ ]] || usage_error "$opt needs a number, got '$2'"
                if [[ "$opt" == --port ]]; then PORT_OPT="$2"; else MAX_BUILDS="$2"; fi
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
    if [[ "${ALLOWED[$SUBCOMMAND]}" == *" --port "* && -z "$PORT_OPT" ]] &&
        [[ -n "${RPI_PORT:-}" && ! "$RPI_PORT" =~ ^[0-9]+$ ]]; then
        usage_error "RPI_PORT needs a number, got '$RPI_PORT'"
    fi
}

main() {
    parse_args "$@"
    case "$SUBCOMMAND" in
    image) do_image ;;
    flash) do_flash "${POSITIONAL[0]}" "${POSITIONAL[1]}" ;;
    deploy) do_deploy ;;
    status)
        resolve_target
        do_status
        ;;
    secrets) do_secrets ;;
    esac
}

main "$@"
