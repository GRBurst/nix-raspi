# shellcheck shell=bash
#
# rpi-lib.sh — guards, ssh helpers and the reboot decision shared by
# rpi-deploy (image/deploy/status) and rpi-autoupdate (the weekly job).
#
# Sourced; defines variables and functions only (no side effects when
# sourced). Functions never call `exit` and do not rely on `set -e`: they
# return the RL_E_* codes below and print their diagnostics on stderr.
#
# Globals (set before sourcing or before calling; defaults shown):
#   RL_FLAKE      flake directory or ref              ($PWD)
#   RL_ATTR       nixosConfigurations attribute       (rpi)
#   RL_TARGET     ssh target of the Pi                (root@neptun)
#   RL_SSH_PORT   sshd port of the Pi                 (2222)
#   RL_SSH_OPTS   extra ssh options, word-split       ($RPI_SSH_OPTS)
#   RL_CACHE_URL  cache that must hold the kernel     ($RPI_CACHE_URL or nvmd's cachix)
#   RPI_NIXOS_REBUILD  nixos-rebuild executable; default: the flake's
#                      pinned one (`nix run FLAKE#nixos-rebuild --`)

RL_FLAKE=${RL_FLAKE:-$PWD}
RL_ATTR=${RL_ATTR:-rpi}
RL_TARGET=${RL_TARGET:-root@neptun}
RL_SSH_PORT=${RL_SSH_PORT:-2222}
RL_SSH_OPTS=${RL_SSH_OPTS:-${RPI_SSH_OPTS:-}}
RL_CACHE_URL=${RL_CACHE_URL:-${RPI_CACHE_URL:-https://nixos-raspberrypi.cachix.org}}

# Derivation names (store hash and .drv stripped) that must never be built
# locally: the kernel and its configs, and the big toolchains. Applied to the
# "will be built" section of a dry run only, never to fetched paths.
# Allowed on purpose: initrd-linux_rpi-*, linux_rpi-*-modules(-shrunk),
# installkernel (cheap wrappers around the cached kernel).
RL_FORBIDDEN_RE='^(linux_rpi-.*[0-9]|linux-[0-9].*|linux-config-.*|kernel-intermediate-config.*|(gcc|llvm|rustc|ghc|nodejs)-[0-9].*)$'

# Exit codes (pinned; used by the sourcing scripts).
# shellcheck disable=SC2034
RL_E_USAGE=2 RL_E_CACHE=10 RL_E_FORBIDDEN=11 RL_E_TOO_MANY=12 RL_E_BUILD=13 \
    RL_E_DEPLOY=14 RL_E_DOWNGRADE=15 RL_E_DEVICE=16 RL_E_VERIFY=17

# rl_built_names < DRY_RUN_OUTPUT
# Prints the names of the derivations in the "will be built:" section(s)
# (plural or singular header), one per line. A section ends at the first line
# that does not start with whitespace; everything else is ignored.
rl_built_names() {
    awk '/will be built:$/ { s = 1; next } s && /^[[:space:]]/ { print; next } { s = 0 }' |
        sed -E 's|^[[:space:]]+||; s|^/nix/store/||; s|^[0-9a-z]{32}-||; s|\.drv$||'
}

# rl_check_builds FILE MAX: FILE holds `nix build --dry-run` output.
# -> 0 | RL_E_FORBIDDEN (offending names on stderr) | RL_E_TOO_MANY ("N > MAX")
rl_check_builds() {
    local file="$1" max="$2" names bad n
    names="$(rl_built_names <"$file")" || return "$RL_E_BUILD"
    bad="$(printf '%s\n' "$names" | grep -E -- "$RL_FORBIDDEN_RE")"
    if [[ -n "$bad" ]]; then
        {
            echo "guard: refusing, these would be built locally (kernel/toolchain):"
            printf '%s\n' "$bad" | sed 's/^/  /'
        } >&2
        return "$RL_E_FORBIDDEN"
    fi
    n="$(printf '%s' "$names" | grep -c .)"
    if ((n > max)); then
        echo "guard: refusing, too many local builds: $n > $max" >&2
        return "$RL_E_TOO_MANY"
    fi
    return 0
}
