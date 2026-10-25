#!/usr/bin/env bash
#
# ci/publish.sh — push a host's toplevel closure to the host's Cachix cache
# (rpi.pull.cache), then pin it as the host's system.name (the last 4
# revisions are kept safe from LRU eviction).
#
#   ci/publish.sh --host NAME --top TOP [--flake DIR]
#
# - No cache configured (rpi.pull.cache = null): nothing to publish, a
#   notice, `published=false`, exit 0 (the build and its checks passed).
# - A cache but CACHIX_AUTH_TOKEN or CACHIX_SIGNING_KEY empty or unset (the
#   repository secrets): an error naming each, exit 1, nothing pushed.
# - Otherwise `cachix push` then `cachix pin` (cachix reads both secrets
#   from the environment); a failed push never pins. `published=true`.
#
# stdout: `published=true|false` (for $GITHUB_OUTPUT); cachix output and
# logs on stderr. Under GitHub Actions also annotations, a log group and a
# step summary section (ci/gh.sh).
# Exit: 0 | 1 missing secret, invalid cache | 2 usage | 13 evaluation error
# | cachix's exit code.
#
# DIR defaults to the working directory; RPI_LIB overrides the path of rpi-lib.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
usage: ci/publish.sh --host NAME --top TOP [--flake DIR]

  --host NAME  the Pi host (nixosConfigurations.NAME) whose rpi.pull.cache is used
  --top TOP    the host's built toplevel (rpi-ci build's top=)
  --flake DIR  flake directory (default: the working directory)

env: CACHIX_AUTH_TOKEN, CACHIX_SIGNING_KEY (needed when the host has a cache)
stdout: published=true|false
EOF
}
die_usage() { echo "ci/publish.sh: $1" >&2; usage >&2; exit 2; }

dir="$PWD" host="" top=""
while (($#)); do
    case "$1" in
    --host | --top | --flake) (($# >= 2)) || die_usage "$1 needs a value" ;;&
    --host) host="$2"; shift 2 ;;
    --top) top="$2"; shift 2 ;;
    --flake) dir="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) die_usage "unknown argument '$1'" ;;
    esac
done
[[ -n "$host" ]] || die_usage "missing --host NAME"
[[ -n "$top" ]] || die_usage "missing --top TOP"

# shellcheck source=../rpi-lib.sh
source "${RPI_LIB:-$HERE/../rpi-lib.sh}"
# shellcheck source=gh.sh
source "$HERE/gh.sh"

# summary LINE...: this step's summary section (GitHub Actions only)
summary() { { echo "## $host: publish"; echo; printf '%s\n' "$@"; echo; } | gh_summary; }

info="$(rl_host_info "$dir" "$host")" || {
    rc=$?
    gh_error "cannot evaluate the host info of $host"
    exit "$rc"
}
name="$(jq -r '.name' <<<"$info")"
cache="$(jq -r '.cache.name // empty' <<<"$info")"

if [[ -z "$cache" ]]; then
    gh_notice "no cache configured for $host: built and tested, not published"
    summary "- skipped: no cache configured (rpi.pull.cache)"
    echo "published=false"
    exit 0
fi
if ! [[ "$cache" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    gh_error "rpi.pull.cache.name of $host is not a Cachix cache name: '$cache'"
    summary "- failed: rpi.pull.cache.name is not a Cachix cache name"
    exit 1
fi
[[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || {
    gh_error "system.name of $host is not a plain name: '$name'"
    exit 1
}

missing=()
for v in CACHIX_AUTH_TOKEN CACHIX_SIGNING_KEY; do
    if [[ -z "${!v:-}" ]]; then
        gh_error "$v is not set: add it as a repository secret (Actions) for the cache $cache of $host"
        missing+=("$v")
    fi
done
if ((${#missing[@]})); then
    summary "- failed: not set: ${missing[*]} (cache \`$cache\`)"
    exit 1
fi

gh_group "push $host"
rc=0
cachix push "$cache" "$top" >&2 || rc=$?
((rc != 0)) || cachix pin "$cache" "$name" "$top" --keep-revisions 4 >&2 || rc=$?
gh_endgroup
if ((rc != 0)); then
    gh_error "publishing $host to the cache $cache failed (cachix exit $rc)"
    summary "- failed: cachix push/pin to \`$cache\` (exit $rc)"
    exit "$rc"
fi

if gh_on; then
    paths="$(nix path-info --recursive "$top" 2>/dev/null | grep -c .)" || paths="?"
    size="$(nix path-info --closure-size --human-readable "$top" 2>/dev/null | cut -f2 | sed 's/^ *//')" || true
    summary "- cache: \`$cache\` (https://$cache.cachix.org)" \
        "- pushed: \`$top\` ($paths paths, ${size:-unknown})" \
        "- pinned as \`$name\` (the last 4 revisions are kept)"
fi
echo "published=true"
