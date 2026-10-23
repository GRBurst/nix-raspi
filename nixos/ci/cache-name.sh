#!/usr/bin/env bash
#
# ci/cache-name.sh — name of our Cachix cache, read from nixos/keys.nix
# (`cache = { name; publicKey; }`), so the workflow has no second copy.
#
#   ci/cache-name.sh [--flake DIR]
#
# stdout: `name=<cache>` (for $GITHUB_OUTPUT); logs on stderr.
# Exit: 0 | 1 cache not set (or not a Cachix name) | 2 usage.
# DIR defaults to the flake next to this script (nixos/).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
usage: ci/cache-name.sh [--flake DIR]

  --flake DIR  directory holding keys.nix (default: $HERE/..)

stdout: name=<cache>
EOF
}

dir="$HERE/.."
while (($#)); do
    case "$1" in
    --flake)
        (($# >= 2)) || { echo "ci/cache-name.sh: --flake needs a value" >&2; exit 2; }
        dir="$2"
        shift 2
        ;;
    -h | --help) usage; exit 0 ;;
    *) echo "ci/cache-name.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

# `./keys.nix` in --expr resolves against the working directory.
name="$(cd "$dir" && nix eval --impure --raw --expr \
    'let k = import ./keys.nix; in if (k.cache or null) == null then "" else k.cache.name')"
if [[ -z "$name" ]]; then
    echo "ci/cache-name.sh: no cache configured: set cache = { name; publicKey; } in nixos/keys.nix" >&2
    exit 1
fi
if ! [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "ci/cache-name.sh: cache.name in nixos/keys.nix is not a Cachix cache name: '$name'" >&2
    exit 1
fi
echo "name=$name"
