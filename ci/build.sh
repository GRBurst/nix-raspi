#!/usr/bin/env bash
#
# ci/build.sh — CI build of the Pi's system toplevel (workflow neptun.yml).
#
#   ci/build.sh [--event NAME] [--update-lock] [--flake DIR] [--max-builds N]
#
# 1. Lock update when NAME (default $GITHUB_EVENT_NAME) is `schedule` or
#    --update-lock is given: `nix flake update nixpkgs nixos-raspberrypi`.
# 2. Guards (rpi-lib.sh rl_guard): the kernel must be in the nvmd cache, no
#    kernel/toolchain build, at most N local builds (default 500).
#    A kernel cache miss right after a lock update falls back to the
#    committed lock plus a nixpkgs-only update and guards again, so an
#    uncached nvmd kernel does not hold back that week's userspace fixes.
# 3. `nix build --no-link` of nixosConfigurations.rpi's toplevel; `df -h /`.
#
# stdout: `top=<store path>` (for $GITHUB_OUTPUT); logs on stderr.
# Exit: 0 | 2 usage | rl_guard's RL_E_* (10 cache, 11 forbidden, 12 too
# many, 13 eval/build error).
#
# DIR defaults to the working directory; RPI_LIB overrides the path of rpi-lib.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
usage: ci/build.sh [--event NAME] [--update-lock] [--flake DIR] [--max-builds N]

  --event NAME    GitHub event (default \$GITHUB_EVENT_NAME); schedule updates the lock
  --update-lock   update nixpkgs and nixos-raspberrypi in flake.lock first
  --flake DIR     flake directory (default: the working directory)
  --max-builds N  build guard limit (default 500)

stdout: top=<store path of the toplevel>
EOF
}

die_usage() { echo "ci/build.sh: $1" >&2; usage >&2; exit 2; }

event="${GITHUB_EVENT_NAME:-}" update_lock=0 dir="$PWD" max=500
while (($#)); do
    case "$1" in
    --event | --flake | --max-builds) (($# >= 2)) || die_usage "$1 needs a value" ;;&
    --event) event="$2"; shift 2 ;;
    --update-lock) update_lock=1; shift ;;
    --flake) dir="$2"; shift 2 ;;
    --max-builds) max="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) die_usage "unknown argument '$1'" ;;
    esac
done
[[ "$max" =~ ^[0-9]+$ ]] || die_usage "--max-builds must be a number"
[[ "$event" == schedule ]] && update_lock=1

export RL_FLAKE="$dir" RL_ATTR=rpi
# shellcheck source=../rpi-lib.sh
source "${RPI_LIB:-$HERE/../rpi-lib.sh}"

# update INPUT...: nix flake update of the named inputs in DIR/flake.lock.
update() {
    echo "ci/build.sh: updating flake.lock: $*" >&2
    nix flake update --accept-flake-config --flake "$dir" "$@"
}

if ((update_lock)); then
    update nixpkgs nixos-raspberrypi
fi

rc=0
rl_guard toplevel "$max" || rc=$?
if ((rc == RL_E_CACHE && update_lock)); then
    echo "ci/build.sh: kernel not cached after the update; retrying with nixpkgs only" >&2
    git -C "$dir" checkout -- flake.lock
    update nixpkgs
    rc=0
    rl_guard toplevel "$max" || rc=$?
fi
((rc == 0)) || exit "$rc"

top="$(nix build --accept-flake-config --no-link --print-out-paths \
    "$(rl_conf_ref).config.system.build.toplevel")" || exit "$RL_E_BUILD"
df -h / >&2 || true
echo "top=$top"
