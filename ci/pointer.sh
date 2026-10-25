#!/usr/bin/env bash
#
# ci/pointer.sh — write the deploy pointer the Pi's rpi-pull reads:
#   { "seq": N, "storePath": TOP, "narHash": "sha256-…", "rev": SHA,
#     "built": "<UTC ISO>", "bootFp": "<64 hex>" }
#
#   ci/pointer.sh --host NAME --seq N --rev SHA --file PATH TOP
#
# - NAME is the host's system.name (rpi-ci build's name=, D11): TOP must be
#   a nixos-system-NAME-… toplevel in the store (RL_STORE_DIR, default
#   /nix/store; the tests use a fake one).
# - TOP already in PATH (or in PATH's copy on origin/main, see below) →
#   nothing written, `changed=false` (same system: no pointer commit).
# - Otherwise N must be newer than the seq of every existing pointer for a
#   different path: PATH itself and, when PATH lies in a git checkout with
#   refs/remotes/origin/main, PATH's copy on origin/main (CI fetches it
#   first), so a stale checkout or a re-run of an older run never moves the
#   pointer backwards.
# - narHash = SRI of `nix-store --query --hash TOP` (TOP must be in the
#   local store). Written via a temp file + mv; `changed=true`.
# - bootFp = sha256 of TOP's boot fingerprint (rpi-fp.sh rl_fp_local: what
#   decides switch vs reboot on the Pi; D18). rpi-pull ignores the field;
#   the step summary compares it with the previous pointer's (origin/main's
#   copy, else PATH): unchanged → the Pi switches, changed → it reboots at
#   rpi.pull.rebootTime, unknown without a previous bootFp.
#
# stdout: `changed=true|false` (for $GITHUB_OUTPUT); logs on stderr. Under
# GitHub Actions also annotations and a step summary section (ci/gh.sh).
# Exit: 0 | 1 invalid N/TOP/--host, invalid existing pointer, N not newer,
# narHash or boot fingerprint failed | 2 usage.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gh.sh
source "$HERE/gh.sh"
# shellcheck source=../rpi-fp.sh
source "${RL_FP_LIB:-$HERE/../rpi-fp.sh}"

usage() {
    cat <<'EOF2'
usage: ci/pointer.sh --host NAME --seq N --rev SHA --file PATH TOP

  --host NAME  the host's system.name (rpi-ci build's name=); TOP must be
               a nixos-system-NAME-… toplevel
  --seq N      pointer sequence number (github.run_number), 1..9999999999
  --rev SHA    git revision the system was built from
  --file PATH  pointer file (created with its directory if missing),
               conventionally deploy/NAME.json

stdout: changed=true|false
EOF2
}
die() { gh_error "$*"; exit 1; }
die_usage() { echo "ci/pointer.sh: $1" >&2; usage >&2; exit 2; }

unset host seq rev file top
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
for v in host seq rev file; do
    [[ -n "${!v+x}" ]] || die_usage "missing --$v"
done
[[ -n "${top+x}" ]] || die_usage "missing TOP"

seq_re='^[1-9][0-9]{0,9}$'
store="${RL_STORE_DIR:-/nix/store}"
[[ "$host" =~ ^[A-Za-z0-9_-]+$ ]] || die "--host must be a plain name: '$host'"
[[ "$seq" =~ $seq_re ]] || die "--seq must be an integer 1..9999999999: '$seq'"
[[ -n "$rev" && "$rev" != *[[:cntrl:]]* ]] || die "--rev must be a non-empty single line"
[[ "$top" =~ ^"$store"/[0-9a-df-np-sv-z]{32}-nixos-system-"$host"-[A-Za-z0-9+._?=-]+$ ]] ||
    die "not a nixos-system-$host toplevel in $store: '$top'"

# summary LINE...: this step's summary section (GitHub Actions only)
summary() { { echo "## $host: pointer"; echo; printf '%s\n' "$@"; echo; } | gh_summary; }

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

# previous LABEL JSON: exit with changed=false if JSON already names TOP;
# otherwise JSON becomes the previous pointer (the later one wins).
prev=""
previous() {
    local rc=0
    check_newer "$1" "$2" || rc=$?
    if ((rc == 3)); then
        echo "ci/pointer.sh: $1 already points at $top" >&2
        summary "- unchanged: $1 already points at \`$top\` (no new pointer)"
        echo "changed=false"
        exit 0
    fi
    prev="$2"
}

if [[ -e "$file" ]]; then
    previous "$file" "$(cat "$file")"
fi
remote=refs/remotes/origin/main
if git -C "$dir" rev-parse -q --verify "$remote" >/dev/null 2>&1 &&
    git -C "$dir" cat-file -e "$remote:./$base" 2>/dev/null; then
    previous "origin/main:$base" "$(git -C "$dir" show "$remote:./$base")"
fi

h="$(nix-store --query --hash "$top")" || die "cannot query the narHash of $top"
nar="$(nix hash convert --to sri "$h")" || die "cannot convert narHash '$h'"
[[ "$nar" =~ ^sha256-[A-Za-z0-9+/]{43}=$ ]] || die "unexpected narHash '$nar'"
fp="$(rl_fp_local "$top" | sha256sum)" || die "cannot compute the boot fingerprint of $top"
boot_fp="${fp%% *}"
[[ "$boot_fp" =~ ^[0-9a-f]{64}$ ]] || die "unexpected boot fingerprint hash '$boot_fp'"
built="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# boot: what the Pi will do, from the previous pointer's bootFp
prev_fp=""
[[ -z "$prev" ]] || prev_fp="$(jq -r '.bootFp // empty | strings' <<<"$prev")"
if [[ -z "$prev" ]]; then
    boot="boot: unknown (no previous pointer)"
elif [[ -z "$prev_fp" ]]; then
    boot="boot: unknown (the previous pointer has no bootFp)"
elif [[ "$prev_fp" == "$boot_fp" ]]; then
    boot="boot: unchanged → the Pi switches"
else
    boot="boot: changed → the Pi reboots at rpi.pull.rebootTime"
fi

tmp="$(mktemp "$dir/.$base.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
jq -n --argjson seq "$seq" --arg storePath "$top" --arg narHash "$nar" \
    --arg rev "$rev" --arg built "$built" --arg bootFp "$boot_fp" \
    '{seq: $seq, storePath: $storePath, narHash: $narHash, rev: $rev, built: $built,
      bootFp: $bootFp}' >"$tmp"
chmod 644 "$tmp"
mv -f "$tmp" "$file"
echo "ci/pointer.sh: $file: seq $seq -> $top ($boot)" >&2
summary "- $file: seq $seq → \`$top\`" "- $boot"
echo "changed=true"
