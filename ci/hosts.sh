#!/usr/bin/env bash
#
# ci/hosts.sh — the Pi hosts of the flake (its nixosConfigurations built
# with lib.mkPi), for the workflow's build matrix.
#
#   ci/hosts.sh [--flake DIR]
#
# stdout: `hosts=<JSON array of names, sorted>` (for $GITHUB_OUTPUT), e.g.
# hosts=["garden","rpi"]; no Pi host: hosts=[] and a notice (the build job is
# skipped). Logs on stderr (annotations under GitHub Actions, ci/gh.sh).
# Exit: 0 | 2 usage | 13 evaluation error (rpi-lib.sh rl_hosts).
#
# DIR defaults to the working directory; RPI_LIB overrides the path of
# rpi-lib.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
usage: ci/hosts.sh [--flake DIR]

  --flake DIR  flake directory (default: the working directory)

stdout: hosts=<JSON array of the Pi host names>
EOF
}

die_usage() { echo "ci/hosts.sh: $1" >&2; usage >&2; exit 2; }

dir="$PWD"
while (($#)); do
    case "$1" in
    --flake) (($# >= 2)) || die_usage "$1 needs a value"; dir="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) die_usage "unknown argument '$1'" ;;
    esac
done

# shellcheck source=../rpi-lib.sh
source "${RPI_LIB:-$HERE/../rpi-lib.sh}"
# shellcheck source=gh.sh
source "$HERE/gh.sh"

names="$(rl_hosts "$dir")" || exit $?
[[ -n "$names" ]] || gh_notice "no Pi hosts (lib.mkPi) in nixosConfigurations"
echo "hosts=$(jq -Rcs 'split("\n") | map(select(. != ""))' <<<"$names")"
