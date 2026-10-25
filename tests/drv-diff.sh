#!/usr/bin/env bash
#
# tests/drv-diff.sh BEFORE.json AFTER.json [EXPECT]
#
# Root-cause diff of two derivation closures (`nix derivation show -r DRV`),
# the refactor invariant's tool (plan §12). A changed derivation changes
# every ancestor, so only the LEAVES are reported: derivations of AFTER that
# are not in BEFORE and whose input derivations all are. Each leaf is
# compared with the BEFORE-only derivation of the same name that differs in
# the fewest kinds (none: kind "new"):
#
#   env:<key>                an env value differs (output paths ignored)
#   structuredAttrs:<key>    a __structuredAttrs attribute differs
#   inputSrcs                the source set differs
#   inputDrvs:+<n> / :-<n>   an input derivation was added / removed
#   builder, args, system    those differ
#   outputs                  output names, hashes or methods differ
#   other                    none of the above (e.g. an input's output set)
#
# Output paths (env.<output>, outputs.<output>.path) are ignored: they change
# with every input. Keys and input keys may be store paths or basenames; the
# input may be wrapped in {"derivations": ...} (format v4: inputs.drvs and
# inputs.srcs) or not (older: inputDrvs and inputSrcs).
#
# stdout: sorted lines "<name>\t<kind>"; exit 0.
# With EXPECT (a file of such lines): exit 0 iff the lines are equal as sets,
# else "UNEXPECTED: <line>" / "MISSING: <line>" on stderr and exit 1.
# Exit 2: usage, an unreadable file or invalid JSON.

set -euo pipefail

usage() { echo "usage: drv-diff.sh BEFORE.json AFTER.json [EXPECT]" >&2; exit 2; }
[[ $# -eq 2 || $# -eq 3 ]] || usage
for f in "$@"; do
    [[ -f "$f" && -r "$f" ]] || { echo "drv-diff: cannot read $f" >&2; exit 2; }
done

# shellcheck disable=SC2016 # a jq program, not a shell string
PROG='
def bn: sub("^.*/"; "");
def name: bn | sub("^[0-9a-z]{32}-"; "") | sub("\\.drv$"; "");
def norm: (.derivations // .) | with_entries(.key |= bn) | map_values(
  ((.outputs // {}) | keys) as $outs
  | { env: ((.env // {}) | with_entries(select(.key as $k | $outs | any(. == $k) | not))),
      sa: (.structuredAttrs // {}),
      srcs: ((.inputs.srcs // .inputSrcs // []) | map(bn) | sort),
      drvs: ((.inputs.drvs // .inputDrvs // {}) | with_entries(.key |= bn)),
      builder, args, system,
      outputs: ((.outputs // {}) | map_values(del(.path))) });
def differing($x; $y): [($x | keys) + ($y | keys) | unique[] | select($x[.] != $y[.])];
def kinds($c; $d):
    [ differing($c.env; $d.env)[] | "env:" + . ]
  + [ differing($c.sa; $d.sa)[] | "structuredAttrs:" + . ]
  + (if $c.srcs != $d.srcs then ["inputSrcs"] else [] end)
  + [ $d.drvs | keys[] | select(. as $i | $c.drvs | has($i) | not) | "inputDrvs:+" + name ]
  + [ $c.drvs | keys[] | select(. as $i | $d.drvs | has($i) | not) | "inputDrvs:-" + name ]
  + [ ("builder", "args", "system", "outputs") as $f | select($c[$f] != $d[$f]) | $f ]
  | unique;
($b[0] | norm) as $B | ($a[0] | norm) as $A
| ([$B | to_entries[] | select(.key as $k | $A | has($k) | not)]
   | reduce .[] as $e ({}; .[$e.key | name] += [$e.value])) as $gone
| $A | to_entries[]
| select((.key as $k | $B | has($k) | not) and all(.value.drvs | keys[]; . as $i | $B | has($i)))
| (.key | name) as $n | .value as $d
| (if $gone[$n] then ($gone[$n] | map(kinds(.; $d)) | min_by(length))
   else ["new"] end) as $k
| (if $k == [] then ["other"] else $k end)[]
| "\($n)\t\(.)"
'

got=$(jq -nr --slurpfile b "$1" --slurpfile a "$2" "$PROG") \
    || { echo "drv-diff: invalid derivation JSON in $1 or $2" >&2; exit 2; }
got=$(printf '%s\n' "$got" | LC_ALL=C sort -u | grep -v '^$' || true)
[[ -z "$got" ]] || printf '%s\n' "$got"

[[ $# -eq 3 ]] || exit 0
want=$(LC_ALL=C sort -u "$3" | grep -v '^$' || true)
# lines: the non-empty lines of $1 (an empty variable has none)
lines() { [[ -z "$1" ]] || printf '%s\n' "$1"; }
extra=$(LC_ALL=C comm -23 <(lines "$got") <(lines "$want"))
missing=$(LC_ALL=C comm -13 <(lines "$got") <(lines "$want"))
lines "$extra" | sed 's/^/UNEXPECTED: /' >&2
lines "$missing" | sed 's/^/MISSING: /' >&2
[[ -z "$extra" && -z "$missing" ]]
