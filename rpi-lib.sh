# shellcheck shell=bash
#
# rpi-lib.sh — guards, host discovery, ssh helpers and the reboot decision
# shared by rpi-deploy (image/deploy/status) and rpi-ci (hosts).
#
# Sourced; defines variables and functions only (no side effects when
# sourced). Functions never call `exit` and do not rely on `set -e`: they
# return the RL_E_* codes below and print their diagnostics on stderr.
#
# Globals (set before sourcing or before calling; defaults shown):
#   RL_FLAKE      flake directory or ref              ($PWD)
#   RL_ATTR       nixosConfigurations attribute       (rpi: the template host)
#   RL_TARGET     ssh target of the Pi                (root@rpi: rpi.deploy.target default)
#   RL_SSH_PORT   sshd port of the Pi                 (22: rpi.ssh.port default)
#   RL_SSH_OPTS   extra ssh options, word-split       ($RPI_SSH_OPTS)
#   RL_CACHE_URL  cache that must hold the kernel     ($RPI_CACHE_URL or nvmd's cachix)
#   RPI_NIXOS_REBUILD  nixos-rebuild executable; default: the flake's
#                      pinned one (`nix run FLAKE#nixos-rebuild --`)

RL_FLAKE=${RL_FLAKE:-$PWD}
RL_ATTR=${RL_ATTR:-rpi}
RL_TARGET=${RL_TARGET:-root@rpi}
RL_SSH_PORT=${RL_SSH_PORT:-22}
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

# rl_conf_ref: flake reference of the Pi's nixosConfiguration.
rl_conf_ref() { echo "$RL_FLAKE#nixosConfigurations.$RL_ATTR"; }

# Host discovery: the Pi hosts of a flake are its nixosConfigurations built
# with lib.mkPi (marked `rpiHost = true`); the info is what rpi-deploy and
# rpi-ci need of one host.
# shellcheck disable=SC2016 # nix expressions, not shell strings
RL_HOSTS_EXPR='cs: builtins.filter (n: (cs.${n}.rpiHost or false) == true) (builtins.attrNames cs)'
# shellcheck disable=SC2016
RL_HOST_INFO_EXPR='c: { name = c.config.system.name; target = c.config.rpi.deploy.target; port = c.config.rpi.ssh.port; cache = c.config.rpi.pull.cache; wifi = { inherit (c.config.rpi.wifi) enable networks secretsFile; }; }'

# rl_hosts FLAKE: the Pi hosts of FLAKE, sorted, one per line (none: no
# output). -> 0 | RL_E_BUILD (eval error; nix's stderr passed through)
rl_hosts() {
    local json names
    json="$(nix eval --accept-flake-config --json "$1#nixosConfigurations" \
        --apply "$RL_HOSTS_EXPR")" || return "$RL_E_BUILD"
    names="$(jq -r '.[]' <<<"$json")" || return "$RL_E_BUILD"
    [[ -z "$names" ]] || LC_ALL=C sort <<<"$names"
}

# rl_host_info FLAKE HOST: one line of JSON
# {name, target, port, cache, wifi: {enable, networks, secretsFile}}.
# HOST must be a plain attribute name (no nix call otherwise).
# -> 0 | RL_E_USAGE ("invalid host name") | RL_E_BUILD (eval error)
rl_host_info() {
    if [[ ! "$2" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo "invalid host name: '$2'" >&2
        return "$RL_E_USAGE"
    fi
    nix eval --accept-flake-config --json "$1#nixosConfigurations.$2" \
        --apply "$RL_HOST_INFO_EXPR" || return "$RL_E_BUILD"
}

# rl_kernel_paths: kernel and kernel-modules out paths, one per line.
rl_kernel_paths() {
    local k m ref
    ref="$(rl_conf_ref).config.boot.kernelPackages.kernel"
    k="$(nix eval --accept-flake-config --raw "$ref.outPath")" || return "$RL_E_BUILD"
    m="$(nix eval --accept-flake-config --raw "$ref.modules.outPath")" || return "$RL_E_BUILD"
    [[ -n "$k" && -n "$m" ]] || return "$RL_E_BUILD"
    printf '%s\n%s\n' "$k" "$m"
}

# rl_cache_has PATH...: 0 iff every PATH is in $RL_CACHE_URL. Any error
# (404, network, eviction) counts as a miss.
rl_cache_has() {
    local p
    for p in "$@"; do
        if ! nix path-info --store "$RL_CACHE_URL" "$p" >/dev/null 2>&1; then
            echo "guard: not in $RL_CACHE_URL (or the cache is unreachable): $p" >&2
            return 1
        fi
    done
}

# rl_guard BUILD_ATTR MAX (BUILD_ATTR: toplevel | sdImage)
# Cache guard (the kernel must be substitutable), then the build guard on a
# dry run of config.system.build.BUILD_ATTR. Nothing is built or copied.
# -> 0 | RL_E_CACHE | RL_E_FORBIDDEN | RL_E_TOO_MANY | RL_E_BUILD (eval error)
rl_guard() {
    local attr="$1" max="$2" paths dry
    case "$attr" in
    toplevel | sdImage) ;;
    *)
        echo "rl_guard: unknown build attribute '$attr'" >&2
        return "$RL_E_USAGE"
        ;;
    esac
    if ! paths="$(rl_kernel_paths)"; then
        echo "guard: cannot evaluate the kernel of $(rl_conf_ref)" >&2
        return "$RL_E_BUILD"
    fi
    local -a kernel_paths
    mapfile -t kernel_paths <<<"$paths"
    rl_cache_has "${kernel_paths[@]}" || return "$RL_E_CACHE"
    if ! dry="$(nix build --accept-flake-config --dry-run \
        "$(rl_conf_ref).config.system.build.$attr" 2>&1)"; then
        printf '%s\n' "$dry" >&2
        echo "guard: dry run of $(rl_conf_ref) ($attr) failed" >&2
        return "$RL_E_BUILD"
    fi
    rl_check_builds <(printf '%s\n' "$dry") "$max"
}

# The boot fingerprint (RL_FP_SCRIPT, rl_fp_local, rl_needs_reboot,
# rl_fp_changed) lives in rpi-fp.sh: pure bash, so the Pi (rpi-pull) runs
# the very same code. RL_FP_LIB overrides the path (default: next to this file).
RL_FP_LIB=${RL_FP_LIB:-$(dirname "${BASH_SOURCE[0]}")/rpi-fp.sh}
# shellcheck source=rpi-fp.sh
source "$RL_FP_LIB" || return 1

# rl_fp_remote SYSTEM: the boot fingerprint of SYSTEM on the Pi, e.g.
# /run/booted-system or /nix/var/nix/profiles/system (the boot default).
rl_fp_remote() { rl_ssh bash -s -- "$1" /nix/store <<<"$RL_FP_SCRIPT"; }

# rl_sshopts: ssh options for the Pi, also used as NIX_SSHOPTS.
rl_sshopts() { echo "-p $RL_SSH_PORT${RL_SSH_OPTS:+ $RL_SSH_OPTS}"; }

# rl_ssh CMD...: run CMD on the Pi.
rl_ssh() {
    local -a opts
    read -ra opts <<<"$RL_SSH_OPTS"
    ssh -p "$RL_SSH_PORT" "${opts[@]}" "$RL_TARGET" "$@"
}

# rl_nixos_rebuild ARGS...: the flake's pinned nixos-rebuild (never the
# host's: a newer one half-applies on the Pi, see E3), ssh options for the
# Pi in NIX_SSHOPTS.
rl_nixos_rebuild() {
    local -a tool
    if [[ -n "${RPI_NIXOS_REBUILD:-}" ]]; then
        tool=("$RPI_NIXOS_REBUILD")
    else
        tool=(nix run --accept-flake-config "$RL_FLAKE#nixos-rebuild" --)
    fi
    # accept-flake-config: nixos-rebuild's own `nix build` of the flake must
    # use its nixConfig (nvmd cachix) without an interactive prompt.
    NIX_SSHOPTS="$(rl_sshopts)" \
        NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG
}accept-flake-config = true" \
        "${tool[@]}" "$@"
}
