#!/usr/bin/env bash
#
# Unit tests for tests/drv-diff.sh (check `rpi-drv-diff-unit`).
#
#   DD=tests/drv-diff.sh bash tests/drv-diff-unit.sh
#
# The derivation closures are synthetic `nix derivation show -r` JSON
# (format v4: basename keys, `inputs.drvs`/`inputs.srcs`, output paths in
# `env.<output>` and `outputs.<output>.path`) written with `jq -n`. Every
# changed derivation also gets a new output path, as in real closures.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DD="${DD:-$HERE/drv-diff.sh}"

# shellcheck source=tests/harness.sh
source "$HERE/harness.sh"

# jq prelude: d(H; NAME; ENV; INPUTS) is one derivation entry keyed by its
# basename "<32 x H>-NAME.drv"; i(H; NAME) is that basename (an input).
PRE='
def i($h; $n): "\($h * 32)-\($n).drv";
def d($h; $n; $env; $ins): {(i($h; $n)): {
  name: $n, system: "x86_64-linux", version: 4, structuredAttrs: null,
  builder: "/nix/store/\("b" * 32)-bash/bin/bash", args: ["-e", "builder.sh"],
  env: ({out: "/nix/store/\($h * 32)-\($n)"} + $env),
  outputs: {out: {path: "\($h * 32)-\($n)"}},
  inputs: {drvs: ($ins | map({key: ., value: {dynamicOutputs: {}, outputs: ["out"]}}) | from_entries),
           srcs: ["\("s" * 32)-builder.sh"]}}};
def w: {version: 4, derivations: (add // {})};
'
# mk FILE JQ: write [entries...] | w (the {derivations: ...} wrapper) to $T/FILE
mk() { jq -n "$PRE [$2] | w" >"$T/$1"; }
# dd NAME FILES...: run drv-diff on $T/FILES
dd() { local n=$1 a=() f; shift; for f in "$@"; do a+=("$T/$f"); done; run_cmd "$n" -- bash "$DD" "${a[@]}"; }

TAB=$'\t'

# Baseline closure B: top -> etc -> system-units -> unit-x.service;
# top -> system-path -> screen.
BASE='
  d("u"; "unit-x.service"; {text: "old"}; []),
  d("v"; "system-units"; {}; [i("u"; "unit-x.service")]),
  d("e"; "etc"; {}; [i("v"; "system-units")]),
  d("c"; "screen"; {}; []),
  d("p"; "system-path"; {paths: "screen"}; [i("c"; "screen")]),
  d("t"; "top"; {}; [i("e"; "etc"), i("p"; "system-path")])'
mk B.json "$BASE"

# --- dd1: identical closures -> rc 0, nothing reported
dd dd1 B.json B.json
expect_exit "dd1 identical closures -> exit 0" 0
expect_eq "dd1 identical closures -> no output" "" "$(cat "$OUT")"

# --- dd2: the unit text changes; every ancestor changes with it
mk A2.json '
  d("1"; "unit-x.service"; {text: "new"}; []),
  d("2"; "system-units"; {}; [i("1"; "unit-x.service")]),
  d("3"; "etc"; {}; [i("2"; "system-units")]),
  d("c"; "screen"; {}; []),
  d("p"; "system-path"; {paths: "screen"}; [i("c"; "screen")]),
  d("4"; "top"; {}; [i("3"; "etc"), i("p"; "system-path")])'
dd dd2 B.json A2.json
expect_exit "dd2 changed unit -> exit 0 (no EXPECT)" 0
expect_eq "dd2 only the leaf is reported" "unit-x.service${TAB}env:text" "$(cat "$OUT")"

# --- dd3: a new derivation neovim becomes an input of system-path
mk A3.json '
  d("u"; "unit-x.service"; {text: "old"}; []),
  d("v"; "system-units"; {}; [i("u"; "unit-x.service")]),
  d("e"; "etc"; {}; [i("v"; "system-units")]),
  d("c"; "screen"; {}; []),
  d("n"; "neovim"; {}; []),
  d("5"; "system-path"; {paths: "screen"}; [i("c"; "screen"), i("n"; "neovim")]),
  d("6"; "top"; {}; [i("e"; "etc"), i("5"; "system-path")])'
dd dd3 B.json A3.json
expect_eq "dd3 a new input is reported as new (its parent is no leaf)" "neovim${TAB}new" "$(cat "$OUT")"

# --- dd4: screen is dropped from system-path
mk A4.json '
  d("u"; "unit-x.service"; {text: "old"}; []),
  d("v"; "system-units"; {}; [i("u"; "unit-x.service")]),
  d("e"; "etc"; {}; [i("v"; "system-units")]),
  d("7"; "system-path"; {paths: "screen"}; []),
  d("8"; "top"; {}; [i("e"; "etc"), i("7"; "system-path")])'
dd dd4 B.json A4.json
expect_eq "dd4 a dropped input is reported on its parent" "system-path${TAB}inputDrvs:-screen" "$(cat "$OUT")"

# --- dd5: EXPECT (lines "<name>\t<kind>", compared as sets)
printf 'unit-x.service\tenv:text\n' >"$T/E-ok.txt"
dd dd5a B.json A2.json E-ok.txt
expect_exit "dd5 EXPECT equal -> exit 0" 0
: >"$T/E-empty.txt"
dd dd5b B.json A2.json E-empty.txt
expect_exit "dd5 extra leaf -> exit 1" 1
expect_grepf "dd5 extra leaf -> UNEXPECTED: on stderr" "UNEXPECTED: unit-x.service${TAB}env:text" "$ERR"
printf 'unit-x.service\tenv:text\nfoo\tenv:x\n' >"$T/E-more.txt"
dd dd5c B.json A2.json E-more.txt
expect_exit "dd5 expected line absent -> exit 1" 1
expect_grepf "dd5 expected line absent -> MISSING: on stderr" "MISSING: foo${TAB}env:x" "$ERR"
expect_not_grep "dd5 a matched line is not UNEXPECTED" "UNEXPECTED" "$ERR"

# --- dd6: two old `source` derivations; the leaf is compared with the closer
# one (listed and sorted last, so "the first candidate" would be wrong)
mk B6.json '
  d("a"; "source"; {url: "a", rev: "1"}; []),
  d("q"; "source"; {url: "b", rev: "2"}; []),
  d("t"; "top"; {}; [i("a"; "source"), i("q"; "source")])'
mk A6.json '
  d("r"; "source"; {url: "b", rev: "3"}; []),
  d("9"; "top"; {}; [i("r"; "source")])'
dd dd6 B6.json A6.json
expect_eq "dd6 the leaf matches the candidate with fewer differing keys" "source${TAB}env:rev" "$(cat "$OUT")"

# --- dd7: path keys, old-style inputDrvs/inputSrcs, no wrapper -> same result
# old FILE NEW: rewrite $T/FILE (v4, wrapped) as unwrapped, path-keyed JSON
# with top-level inputDrvs (path -> [outputs]) and inputSrcs (paths)
old() {
    jq '.derivations | with_entries(.key |= "/nix/store/" + .) | map_values(
          .inputDrvs = (.inputs.drvs | with_entries(.key |= "/nix/store/" + . | .value |= .outputs))
        | .inputSrcs = (.inputs.srcs | map("/nix/store/" + .)) | del(.inputs))' "$T/$1" >"$T/$2"
}
old B.json B-old.json
old A2.json A2-old.json
dd dd7a B-old.json A2-old.json
expect_eq "dd7 path-keyed, unwrapped input gives the same output" "unit-x.service${TAB}env:text" "$(cat "$OUT")"
dd dd7b B.json A2-old.json
expect_eq "dd7 mixed formats give the same output" "unit-x.service${TAB}env:text" "$(cat "$OUT")"
old A4.json A4-old.json
dd dd7c B-old.json A4-old.json
expect_eq "dd7 path-keyed inputDrvs are named by basename" "system-path${TAB}inputDrvs:-screen" "$(cat "$OUT")"

# --- dd8: invalid input -> exit 2
printf 'not json\n' >"$T/bad.json"
dd dd8a B.json bad.json
expect_exit "dd8 non-JSON input -> exit 2" 2
dd dd8b B.json missing.json
expect_exit "dd8 unreadable input -> exit 2" 2
run_cmd dd8c -- bash "$DD" "$T/B.json"
expect_exit "dd8 one argument -> usage, exit 2" 2
expect_grepf "dd8 usage on stderr" "usage:" "$ERR"

# --- dd9: __structuredAttrs derivations keep their attributes in .structuredAttrs
mk B9.json 'd("x"; "sa"; {}; []) | map_values(.structuredAttrs = {text: "old", outputs: ["out"]})'
mk A9.json 'd("y"; "sa"; {}; []) | map_values(.structuredAttrs = {text: "new", outputs: ["out"]})'
dd dd9 B9.json A9.json
expect_eq "dd9 a structuredAttrs change is named" "sa${TAB}structuredAttrs:text" "$(cat "$OUT")"

# --- dd10: a leaf whose difference has no kind of its own is still reported
mk A10.json '
  d("u"; "unit-x.service"; {text: "old"}; []),
  d("v"; "system-units"; {}; [i("u"; "unit-x.service")]),
  d("e"; "etc"; {}; [i("v"; "system-units")]),
  d("c"; "screen"; {}; []),
  d("0"; "system-path"; {paths: "screen"}; [i("c"; "screen")])
    | map_values(.inputs.drvs[] .outputs = ["out", "man"]),
  d("x"; "top"; {}; [i("e"; "etc"), i("0"; "system-path")])'
dd dd10 B.json A10.json
expect_eq "dd10 an otherwise unnamed difference is reported as other" "system-path${TAB}other" "$(cat "$OUT")"

summary
