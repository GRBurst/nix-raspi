# shellcheck shell=bash
#
# rpi-fp.sh — the boot fingerprint of a NixOS system (pure bash + readlink;
# no nix, ssh or git), shared by the host (rpi-lib.sh sources it) and the Pi
# (rpi-pull ships it next to the script).
#
# Sourced; defines variables and functions only (no side effects when
# sourced).
#
#   RL_FP_SCRIPT              the fingerprint program (bash -c "$RL_FP_SCRIPT" _ SYSTEM STORE_DIR)
#   rl_fp_local SYSTEM        fingerprint of a local toplevel; store = ${RL_STORE_DIR:-/nix/store}
#   rl_needs_reboot FP_A FP_B 0 iff the fingerprints differ
#   rl_fp_changed FP_A FP_B   the differing parts, e.g. "kernel, fat"

# Boot fingerprint of a system: everything a reboot would change that a
# switch cannot -- kernel, initrd, kernel-modules, dtbs, kernel-params, and
# the inputs of the FAT partition (NIXOS_BOOT: firmware, config.txt,
# u-boot). The FAT inputs are read from the toplevel's bootloader installer
# (INSTALL_BOOTLOADER in bin/switch-to-configuration, nvmd's uboot-builder.sh
# -> firmware-builder.sh): every builder line naming a store path, except
# the interpreter, PATH, comments and the extlinux step (it writes /boot,
# whose generations roll back). Nested builders are expanded with their own
# path elided, so equal inputs give equal lines across toplevels. If the
# installer cannot be parsed, the line "fat: unknown <toplevel>" makes the
# fingerprint differ from every other system's (fail safe: reboot).
# Pure bash + readlink: it runs on the Pi as well (rl_fp_remote).
# Usage: bash -c "$RL_FP_SCRIPT" _ SYSTEM STORE_DIR
# shellcheck disable=SC2016
RL_FP_SCRIPT='
sys=$1 store=$2
top=$(readlink -e -- "$sys") && [[ -d $top ]] || { echo "no system at $sys" >&2; exit 1; }
for f in kernel initrd kernel-modules dtbs; do
    printf "%s: %s\n" "$f" "$(readlink -f -- "$top/$f")"
done
params=""
[[ -r $top/kernel-params ]] && params=$(<"$top/kernel-params")
printf "kernel-params: %s\n" "$params"

# fat_lines BUILDER DEPTH: the FAT-relevant lines of BUILDER, nested ones too
fat_lines() {
    local line t w nested
    local -a words
    [[ $2 -lt 5 && $1 == "$store"/* && -f $1 && -r $1 ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        t=${line#"${line%%[![:space:]]*}"}
        [[ $t == *"$store/"* ]] || continue
        case $t in "#"* | "export PATH="* | *"\$boottarget"*) continue ;; esac
        read -ra words <<<"$t"
        nested=""
        for w in "${words[@]}"; do
            [[ $w == "$store"/*-builder.sh ]] && { nested=$w; break; }
        done
        if [[ -n $nested ]]; then
            printf "fat: %s\n" "${t//"$nested"/<builder>}"
            fat_lines "$nested" $(($2 + 1)) || return 1
        else
            printf "fat: %s\n" "$t"
        fi
    done <"$1"
}

installer=""
if [[ -r $top/bin/switch-to-configuration ]]; then
    while IFS= read -r line; do
        case $line in "export INSTALL_BOOTLOADER="*)
            installer=${line#export INSTALL_BOOTLOADER=}
            q=${installer:0:1}
            if [[ $q != / ]]; then
                installer=${installer#"$q"}
                installer=${installer%"$q"}
            fi
            break ;;
        esac
    done <"$top/bin/switch-to-configuration"
fi
read -ra iw <<<"$installer"
if [[ ${#iw[@]} -gt 0 ]] && fat=$(fat_lines "${iw[0]}" 0) && [[ -n $fat ]]; then
    printf "fat: <builder> %s\n%s\n" "${iw[*]:1}" "$fat"
else
    printf "fat: unknown %s\n" "$top"
fi
'

# rl_fp_local SYSTEM: the boot fingerprint of a local system (a toplevel).
# RL_STORE_DIR: the local store (/nix/store; tests use a fake one).
rl_fp_local() { "${BASH:-bash}" -c "$RL_FP_SCRIPT" rl_fp "$1" "${RL_STORE_DIR:-/nix/store}"; }

# rl_needs_reboot FP_A FP_B: 0 iff the boot fingerprints differ (the change
# only takes effect after a reboot).
rl_needs_reboot() { [[ "$1" != "$2" ]]; }

# rl_fp_changed FP_A FP_B: the parts that differ, e.g. "kernel, fat".
rl_fp_changed() {
    local -A a=() b=() seen=()
    local -a parts=()
    local l k
    while IFS= read -r l; do a["$l"]=1; done <<<"$1"
    while IFS= read -r l; do b["$l"]=1; done <<<"$2"
    while IFS= read -r l; do
        [[ -n "${b["$l"]:-}" ]] && continue
        k="${l%%:*}"
        [[ -n "${seen["$k"]:-}" ]] || { seen["$k"]=1; parts+=("$k"); }
    done <<<"$1"
    while IFS= read -r l; do
        [[ -n "${a["$l"]:-}" ]] && continue
        k="${l%%:*}"
        [[ -n "${seen["$k"]:-}" ]] || { seen["$k"]=1; parts+=("$k"); }
    done <<<"$2"
    local out=""
    for k in "${parts[@]}"; do out+="${out:+, }$k"; done
    echo "$out"
}
