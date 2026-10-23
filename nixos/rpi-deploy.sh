#!/usr/bin/env bash
#
# rpi-deploy — build the Raspberry Pi SD image, write it to a card once, and
# push every later change from this host (see README).
#
# The guards (kernel in nvmd's cache, no kernel/toolchain build, at most
# --max-builds local builds), the ssh helpers and the reboot decision live in
# rpi-lib.sh, shared with rpi-autoupdate.

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
           activate without making it the boot default); refuses to deploy
           a checkout behind branch auto-update unless --force
  status   current and booted generation on the Pi, and whether a reboot is
           pending (booted kernel/initrd/modules differ from current)

Defaults: --flake $RPI_FLAKE or the current directory, --attr rpi,
  --target root@neptun, --port 2222, --max-builds 500, --out the current
  directory.
Environment: RPI_FLAKE (default flake dir), RPI_SSH_OPTS (extra ssh options),
  RPI_NIXOS_REBUILD (nixos-rebuild to use instead of the flake's pinned one),
  RPI_LIB (path of rpi-lib.sh); test hook RPI_ALLOW_NONBLOCK=1.
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
do_flash() { die "not implemented"; }
do_deploy() { die "not implemented"; }
do_status() { die "not implemented"; }

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
