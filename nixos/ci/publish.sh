#!/usr/bin/env bash
#
# ci/publish.sh — push the toplevel's closure to our Cachix cache, then pin
# it as `neptun` (the last 4 revisions are kept safe from LRU eviction).
#
#   ci/publish.sh CACHE TOP
#
# cachix reads CACHIX_AUTH_TOKEN and CACHIX_SIGNING_KEY (self-signed cache)
# from the environment. A failed push never pins. stdout: nothing (cachix
# output goes to stderr). Exit: 0 | 2 usage | cachix's exit code.
set -euo pipefail

usage() { echo "usage: ci/publish.sh CACHE TOP"; }

case "${1:-}" in -h | --help) usage; exit 0 ;; esac
if (($# != 2)); then
    usage >&2
    exit 2
fi
cache="$1" top="$2"

cachix push "$cache" "$top" >&2
cachix pin "$cache" neptun "$top" --keep-revisions 4 >&2
