#!/usr/bin/env bash
#
# ci/rpi-ci.sh — the CI entry point (package rpi-ci): runs the script of a
# subcommand, which sits next to this file.
#
#   rpi-ci <command> [ARGS...]      (`rpi-ci <command> --help` for its usage)
#
# Here: `nix run .#rpi-ci -- <command>`; in a flake that uses this one as
# input `rpi`: `nix run --inputs-from . rpi#rpi-ci -- <command>`.
# Every command logs on stderr and prints key=value lines on stdout (for
# $GITHUB_OUTPUT). Exit: the command's | 2 usage.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
usage: rpi-ci <command> [ARGS...]

commands:
  hosts    the Pi hosts (lib.mkPi) of the flake     -> hosts=<JSON array>
  build    lock update, guards, build of a host's system, the flake's checks
                                                    -> top=<store path>, name=<system.name>
  publish  push and pin the closure to the host's cache -> published=true|false
  pointer  write the host's deploy pointer           -> changed=true|false
  commit   commit and push the lock and pointers     -> pushed=true|false

`rpi-ci <command> --help` shows a command's arguments.
EOF
}

case "${1:-}" in
hosts | build | publish | pointer) script="$1" ;;
commit) script=commit-push ;;
-h | --help) usage; exit 0 ;;
"") usage >&2; exit 2 ;;
*) echo "rpi-ci: unknown command '$1'" >&2; usage >&2; exit 2 ;;
esac
shift
exec bash "$HERE/$script.sh" "$@"
