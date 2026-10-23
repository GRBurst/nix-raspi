#!/usr/bin/env bash
#
# ci/pointer.sh — write the deploy pointer the Pi's rpi-pull reads:
#   { "seq": N, "storePath": TOP, "narHash": "sha256-…", "rev": SHA, "built": "<UTC ISO>" }
#
#   ci/pointer.sh --seq N --rev SHA --file PATH [--host neptun] TOP
#
# - TOP already in PATH (or in PATH's copy on origin/main, see below) →
#   nothing written, `changed=false` (same system: no pointer commit).
# - Otherwise N must be newer than the seq of every existing pointer for a
#   different path: PATH itself and, when PATH lies in a git checkout with
#   refs/remotes/origin/main, PATH's copy on origin/main (CI fetches it
#   first), so a stale checkout or a re-run of an older run never moves the
#   pointer backwards.
# - narHash = SRI of `nix-store --query --hash TOP` (TOP must be in the
#   local store). Written via a temp file + mv; `changed=true`.
#
# stdout: `changed=true|false` (for $GITHUB_OUTPUT); logs on stderr.
# Exit: 0 | 1 invalid N/TOP/--host, invalid existing pointer, N not newer,
# narHash query failed | 2 usage.
set -euo pipefail

usage() {
    cat <<'EOF'
usage: ci/pointer.sh --seq N --rev SHA --file PATH [--host neptun] TOP

  --seq N      pointer sequence number (github.run_number), 1..9999999999
  --rev SHA    git revision the system was built from
  --file PATH  pointer file (created with its directory if missing)
  --host NAME  system name in the toplevel (nixos-system-NAME-…; default neptun)

stdout: changed=true|false
EOF
}
die() { echo "ci/pointer.sh: $*" >&2; exit 1; }
die_usage() { echo "ci/pointer.sh: $1" >&2; usage >&2; exit 2; }

host=neptun
unset seq rev file top
while (($#)); do
    case "$1" in
    --seq | --rev | --file | --host) (($# >= 2)) || die_usage "$1 needs a value" ;;&
    --seq) seq="$2"; shift 2 ;;
    --rev) rev="$2"; shift 2 ;;
    --file) file="$2"; shift 2 ;;
    --host) host="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    -*) die_usage "unknown option '$1'" ;;
    *)
        [[ -z "${top+x}" ]] || die_usage "more than one TOP"
        top="$1"
        shift
        ;;
    esac
done
for v in seq rev file top; do
    [[ -n "${!v+x}" ]] || die_usage "missing ${v/top/TOP}"
done

seq_re='^[1-9][0-9]{0,9}$'
[[ "$host" =~ ^[A-Za-z0-9_-]+$ ]] || die "--host must be a plain name: '$host'"
[[ "$seq" =~ $seq_re ]] || die "--seq must be an integer 1..9999999999: '$seq'"
[[ -n "$rev" && "$rev" != *[[:cntrl:]]* ]] || die "--rev must be a non-empty single line"
top_re="^/nix/store/[0-9a-df-np-sv-z]{32}-nixos-system-${host}-[A-Za-z0-9+._?=-]+\$"
[[ "$top" =~ $top_re ]] || die "not a nixos-system-$host toplevel: '$top'"

dir="$(dirname "$file")" base="$(basename "$file")"
mkdir -p "$dir"

# check_newer LABEL JSON: N must be newer than JSON's seq unless JSON already
# points at TOP. Returns 0 (newer), 3 (JSON points at TOP); exits on error.
check_newer() {
    local label="$1" json="$2" e_seq e_path
    e_seq="$(jq -r '.seq|tostring' <<<"$json" 2>/dev/null)" || die "$label is not valid JSON"
    e_path="$(jq -r '.storePath|strings' <<<"$json" 2>/dev/null)" || die "$label is not valid JSON"
    [[ "$e_seq" =~ $seq_re && -n "$e_path" ]] || die "$label has no valid seq/storePath"
    [[ "$e_path" != "$top" ]] || return 3
    ((seq > e_seq)) || die "seq $seq is not newer than seq $e_seq in $label ($e_path)"
}

# unchanged LABEL JSON: exit with changed=false if JSON already names TOP.
unchanged() {
    local rc=0
    check_newer "$1" "$2" || rc=$?
    if ((rc == 3)); then
        echo "ci/pointer.sh: $1 already points at $top" >&2
        echo "changed=false"
        exit 0
    fi
}

if [[ -e "$file" ]]; then
    unchanged "$file" "$(cat "$file")"
fi
remote=refs/remotes/origin/main
if git -C "$dir" rev-parse -q --verify "$remote" >/dev/null 2>&1 &&
    git -C "$dir" cat-file -e "$remote:./$base" 2>/dev/null; then
    unchanged "origin/main:$base" "$(git -C "$dir" show "$remote:./$base")"
fi

h="$(nix-store --query --hash "$top")" || die "cannot query the narHash of $top"
nar="$(nix hash convert --to sri "$h")" || die "cannot convert narHash '$h'"
[[ "$nar" =~ ^sha256-[A-Za-z0-9+/]{43}=$ ]] || die "unexpected narHash '$nar'"
built="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

tmp="$(mktemp "$dir/.$base.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
jq -n --argjson seq "$seq" --arg storePath "$top" --arg narHash "$nar" \
    --arg rev "$rev" --arg built "$built" \
    '{seq: $seq, storePath: $storePath, narHash: $narHash, rev: $rev, built: $built}' >"$tmp"
chmod 644 "$tmp"
mv -f "$tmp" "$file"
echo "ci/pointer.sh: $file: seq $seq -> $top" >&2
echo "changed=true"
