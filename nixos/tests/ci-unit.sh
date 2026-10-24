#!/usr/bin/env bash
#
# Unit tests for the CI scripts nixos/ci/*.sh (check `rpi-ci-unit`).
#
#   CI_DIR=ci RPI_LIB=rpi-lib.sh FIXTURES=tests/fixtures bash tests/ci-unit.sh
#
# (all default to the files next to this test, so a plain
# `bash tests/ci-unit.sh` works in a checkout).
#
# nix, nix-store and cachix are mocks (see tests/harness.sh); git, jq and
# coreutils are real. Git remotes are local bare repos under the test's temp
# dir: nothing here touches the network.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_DIR="${CI_DIR:-$HERE/../ci}"
export RPI_LIB="${RPI_LIB:-$HERE/../rpi-lib.sh}"
export RPI_FP_LIB="${RPI_FP_LIB:-$HERE/../rpi-fp.sh}"
FIXTURES="${FIXTURES:-$HERE/fixtures}"

# shellcheck source=tests/harness.sh
source "$HERE/harness.sh"

# The caller's environment (a CI runner, a dev shell) must not leak in.
unset GITHUB_EVENT_NAME GITHUB_REF GITHUB_SHA GITHUB_OUTPUT CACHIX_AUTH_TOKEN \
    CACHIX_SIGNING_KEY RPI_FLAKE RPI_CACHE_URL RL_FLAKE RL_ATTR RL_CACHE_URL

# first_line ERE: line number of the first matching mock-log line (999999 if none)
first_line() { grep -nE -- "$1" "$MOCK_LOG" | head -n1 | cut -d: -f1 | grep . || echo 999999; }

# --- fixture -----------------------------------------------------------------
TOP=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-neptun-26.05.20261021.da6dc0e
export MOCK_TOP="$TOP"
export K_DEF=/nix/store/kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk-linux_rpi-bcm2711-6.18.52
export M_DEF=/nix/store/mmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmm-linux_rpi-bcm2711-6.18.52-modules
LOCK0='{ "committed": "lock" }'

# A bare origin with one commit on main (nixos/flake.lock, nixos/keys.nix);
# clone NAME gives a fresh work repo $T/NAME tracking it.
git init -q --bare -b main "$T/origin.git"
git init -q -b main "$T/seed"
mkdir -p "$T/seed/nixos"
printf '%s\n' "$LOCK0" >"$T/seed/nixos/flake.lock"
printf '{ user = "ssh-ed25519 AAAA test"; }\n' >"$T/seed/nixos/keys.nix"
printf 'readme\n' >"$T/seed/README.md"
git -C "$T/seed" add -A
git -C "$T/seed" commit -q -m init
git -C "$T/seed" push -q "$T/origin.git" main
clone() { rm -rf "${T:?}/$1"; git clone -q "$T/origin.git" "$T/$1"; }

# --- mocks -------------------------------------------------------------------
# nix: cache-name eval (${MOCK_CACHE_NAME-}), kernel/modules eval,
# path-info per MOCK_CACHE (hit | always-miss | full-miss = miss only once
# nixos-raspberrypi was updated in $MOCK_LOCK), flake update (appends its
# argv to <--flake DIR>/flake.lock), build --dry-run (cat $MOCK_DRY to
# stderr), build --print-out-paths ($MOCK_TOP, or rc MOCK_BUILD_RC),
# hash convert (a fixed SRI hash).
mock nix <<'EOF'
case " $* " in
*" eval "*" --expr "*)
    echo "nix-cwd $PWD" >>"$MOCK_LOG"
    printf '%s' "${MOCK_CACHE_NAME-}" ;;
*" eval "*".kernel.modules.outPath "*) printf '%s' "$M_DEF" ;;
*" eval "*".kernel.outPath "*) printf '%s' "$K_DEF" ;;
*" path-info "*)
    case "${MOCK_CACHE:-hit}" in
    hit) exit 0 ;;
    always-miss) exit 1 ;;
    full-miss) if grep -q nixos-raspberrypi "$MOCK_LOCK"; then exit 1; fi ;;
    esac ;;
*" flake update "*)
    prev="" dir=""
    for a in "$@"; do [[ "$prev" == --flake ]] && dir="$a"; prev="$a"; done
    printf '%s\n' "$*" >>"$dir/flake.lock" ;;
*" build "*" --dry-run "*)
    cat "${MOCK_DRY:-/dev/null}" >&2 ;;
*" build "*" --print-out-paths "*)
    if [[ -n "${MOCK_BUILD_RC:-}" ]]; then echo "error: build failed" >&2; exit "$MOCK_BUILD_RC"; fi
    echo "$MOCK_TOP" ;;
*" hash convert "*)
    echo "sha256-MOCKMOCKMOCKMOCKMOCKMOCKMOCKMOCKMOCKMOCKMOC=" ;;
esac
exit 0
EOF

# nix-store --query --hash: a fixed base32 narHash (MOCK_NSQ_RC fails it).
export NAR32=sha256:1b8m03r63zqhnjf7l5wnldhh7c134ap5vpj0850ymkq1iyzicy5s
mock nix-store <<'EOF'
case " $* " in
*" --query --hash "*)
    if [[ -n "${MOCK_NSQ_RC:-}" ]]; then echo "error: path is not valid" >&2; exit "$MOCK_NSQ_RC"; fi
    echo "$NAR32" ;;
esac
exit 0
EOF

# cachix: push/pin print on stdout (the scripts must keep it off theirs);
# MOCK_PUSH_RC / MOCK_PIN_RC fail them.
mock cachix <<'EOF'
case "$1" in
push) echo "pushing $3"; exit "${MOCK_PUSH_RC:-0}" ;;
pin) echo "pinned $3"; exit "${MOCK_PIN_RC:-0}" ;;
esac
exit 0
EOF

# =============================================================================
# T7.1 ci/build.sh
# =============================================================================
HYB="$FIXTURES/dry-run-hybrid.txt"
KER="$FIXTURES/dry-run-kernel.txt"
clone b
LOCKF="$T/b/nixos/flake.lock"
export MOCK_LOCK="$LOCKF"
build() { bash "$CI_DIR/build.sh" --flake "$T/b/nixos" "$@"; }
relock() { git -C "$T/b" checkout -q -- nixos/flake.lock; }

reset_log
MOCK_DRY="$HYB" run_cmd b1 -- build --event push
expect_exit "b1 push builds" 0
expect_eq "b1 stdout is exactly top=<toplevel>" "top=$TOP" "$(cat "$OUT")"
expect_eq "b1 push does not update the lock" 0 "$(log_count 'flake update')"
expect_eq "b1 push leaves flake.lock as committed" "$LOCK0" "$(cat "$LOCKF")"
pi=$(first_line '^nix .*path-info') dr=$(first_line '^nix .*build .*--dry-run')
bo=$(first_line '^nix .*build .*--print-out-paths .*nixosConfigurations\.rpi\.config\.system\.build\.toplevel')
expect_true "b1 order: cache guard < dry-run guard < build ($pi < $dr < $bo)" \
    test "$pi" -lt "$dr" -a "$dr" -lt "$bo" -a "$bo" -lt 999999
expect_eq "b1 build is --no-link" 1 "$(log_count '^nix .*build .*--no-link .*--print-out-paths')"

reset_log
MOCK_DRY="$HYB" run_cmd b1d -- build --event workflow_dispatch
expect_exit "b1 workflow_dispatch builds like push" 0
expect_eq "b1 workflow_dispatch does not update the lock" 0 "$(log_count 'flake update')"

reset_log
GITHUB_EVENT_NAME=push MOCK_DRY="$HYB" run_cmd b1e -- build
expect_eq "b1 event defaults to \$GITHUB_EVENT_NAME (push: no update)" 0 "$(log_count 'flake update')"

reset_log
MOCK_DRY="$HYB" run_cmd b2 -- build --event schedule
expect_exit "b2 schedule builds" 0
fu=$(first_line "^nix flake update --accept-flake-config --flake $T/b/nixos nixpkgs nixos-raspberrypi\$")
pi=$(first_line '^nix .*path-info')
expect_true "b2 schedule updates nixpkgs and nixos-raspberrypi before the guard ($fu < $pi)" \
    test "$fu" -lt "$pi" -a "$pi" -lt 999999
expect_eq "b2 one lock update" 1 "$(log_count 'flake update')"
relock

reset_log
GITHUB_EVENT_NAME=schedule MOCK_DRY="$HYB" run_cmd b2e -- build
expect_eq "b2 \$GITHUB_EVENT_NAME=schedule updates the lock" 1 "$(log_count 'flake update .* nixpkgs nixos-raspberrypi$')"
relock

reset_log
MOCK_DRY="$HYB" run_cmd b8 -- build --event workflow_dispatch --update-lock
expect_exit "b8 --update-lock builds" 0
expect_eq "b8 --update-lock updates nixpkgs and nixos-raspberrypi" 1 \
    "$(log_count "^nix flake update --accept-flake-config --flake $T/b/nixos nixpkgs nixos-raspberrypi\$")"
relock

reset_log
MOCK_CACHE=full-miss MOCK_DRY="$HYB" run_cmd b3 -- build --event schedule
expect_exit "b3 kernel miss after the nvmd update -> nixpkgs-only fallback builds" 0
expect_eq "b3 lock = committed + one nixpkgs-only update" \
    "$LOCK0"$'\n'"flake update --accept-flake-config --flake $T/b/nixos nixpkgs" "$(cat "$LOCKF")"
expect_eq "b3 second update has nixpkgs only" 1 "$(log_count 'flake update .* nixpkgs$')"
expect_grepf "b3 says why it falls back" "nixpkgs only" "$ERR"
expect_eq "b3 stdout is top=" "top=$TOP" "$(cat "$OUT")"
relock

reset_log
MOCK_CACHE=always-miss MOCK_DRY="$HYB" run_cmd b4 -- build --event push
expect_exit "b4 kernel not cached -> RL_E_CACHE" 10
expect_eq "b4 nothing built" 0 "$(log_count '--print-out-paths')"
expect_eq "b4 stdout empty" "" "$(cat "$OUT")"

reset_log
MOCK_CACHE=always-miss MOCK_DRY="$HYB" run_cmd b4s -- build --event schedule
expect_exit "b4 schedule: miss also after the fallback -> RL_E_CACHE" 10
expect_eq "b4 schedule: nothing built" 0 "$(log_count '--print-out-paths')"
relock

reset_log
MOCK_DRY="$KER" run_cmd b5 -- build --event push
expect_exit "b5 kernel build -> RL_E_FORBIDDEN" 11
expect_eq "b5 nothing built" 0 "$(log_count '--print-out-paths')"

reset_log
MOCK_DRY="$HYB" run_cmd b5m -- build --event push --max-builds 300
expect_exit "b5 377 builds > --max-builds 300 -> RL_E_TOO_MANY" 12

reset_log
MOCK_DRY="$HYB" MOCK_BUILD_RC=1 run_cmd b6 -- build --event push
expect_exit "b6 build failure -> RL_E_BUILD" 13
expect_eq "b6 stdout empty" "" "$(cat "$OUT")"

reset_log
MOCK_DRY="$HYB" run_cmd b7 -- build --event push
expect_grepf "b7 df -h is logged on stderr" "Filesystem" "$ERR"

run_cmd b9 -- build --bogus
expect_exit "b9 unknown option -> usage" 2
run_cmd b9v -- build --max-builds
expect_exit "b9 option without a value -> usage" 2
run_cmd b9n -- build --max-builds x
expect_exit "b9 non-numeric --max-builds -> usage" 2
run_cmd b9h -- build --help
expect_exit "b9 --help" 0
expect_grepf "b9 --help shows the usage" "--update-lock" "$OUT"

# =============================================================================
# T7.2 ci/cache-name.sh, ci/publish.sh
# =============================================================================
reset_log
MOCK_CACHE_NAME='' run_cmd c1 -- bash "$CI_DIR/cache-name.sh" --flake "$T/b/nixos"
expect_exit "c1 no cache in keys.nix -> exit 1" 1
expect_grepf "c1 says where to set it" "nixos/keys.nix" "$ERR"
expect_eq "c1 stdout empty" "" "$(cat "$OUT")"

reset_log
MOCK_CACHE_NAME=neptun-x run_cmd c2 -- bash "$CI_DIR/cache-name.sh" --flake "$T/b/nixos"
expect_exit "c2 cache name set" 0
expect_eq "c2 stdout is name=<cache>" "name=neptun-x" "$(cat "$OUT")"
expect_eq "c2 nix eval --impure --raw --expr" 1 "$(log_count '^nix eval --impure --raw --expr ')"
expect_eq "c2 reads keys.nix of --flake DIR" 1 "$(log_count "^nix-cwd $T/b/nixos\$")"
expect_eq "c2 the expression imports ./keys.nix" 1 "$(log_count 'import \./keys\.nix')"

reset_log
MOCK_CACHE_NAME=neptun-y run_cmd c2d -- bash "$CI_DIR/cache-name.sh"
expect_eq "c2 DIR defaults to the flake next to ci/" 1 \
    "$(log_count "^nix-cwd $(cd "$CI_DIR/.." && pwd)\$")"

MOCK_CACHE_NAME=$'evil\ntop=/nix/store/x' run_cmd c3 -- bash "$CI_DIR/cache-name.sh" --flake "$T/b/nixos"
expect_exit "c3 a name that is not a cachix name -> exit 1" 1
expect_eq "c3 stdout empty" "" "$(cat "$OUT")"

reset_log
run_cmd u1 -- bash "$CI_DIR/publish.sh" c "$TOP"
expect_exit "u1 publish" 0
expect_eq "u1 pushes the closure" 1 "$(log_count "^cachix push c $TOP\$")"
expect_eq "u1 pins neptun, keeping 4 revisions" 1 \
    "$(log_count "^cachix pin c neptun $TOP --keep-revisions 4\$")"
expect_true "u1 push before pin" \
    test "$(first_line '^cachix push')" -lt "$(first_line '^cachix pin')"
expect_eq "u1 stdout empty (cachix output goes to stderr)" "" "$(cat "$OUT")"

reset_log
MOCK_PUSH_RC=1 run_cmd u2 -- bash "$CI_DIR/publish.sh" c "$TOP"
expect_true "u2 push failure -> non-zero" test "$RC" -ne 0
expect_eq "u2 push failure -> no pin" 0 "$(log_count '^cachix pin')"

reset_log
MOCK_PIN_RC=1 run_cmd u3 -- bash "$CI_DIR/publish.sh" c "$TOP"
expect_true "u3 pin failure -> non-zero" test "$RC" -ne 0

reset_log
run_cmd u4 -- bash "$CI_DIR/publish.sh" c
expect_exit "u4 missing TOP -> usage" 2
expect_eq "u4 nothing pushed" 0 "$(log_count '^cachix')"
run_cmd u4h -- bash "$CI_DIR/publish.sh" --help
expect_exit "u4 --help" 0

# =============================================================================
# T7.3 ci/pointer.sh
# =============================================================================
SRI=sha256-MOCKMOCKMOCKMOCKMOCKMOCKMOCKMOCKMOCKMOCKMOC=
TOP2=/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-nixos-system-neptun-26.05.20261028.0123456
clone p
PF="$T/p/nixos/deploy/neptun.json"
pointer() { bash "$CI_DIR/pointer.sh" "$@"; }
# put_pointer FILE SEQ PATH: an existing pointer as CI would have written it
put_pointer() {
    mkdir -p "$(dirname "$1")"
    jq -n --argjson seq "$2" --arg p "$3" \
        '{seq: $seq, storePath: $p, narHash: "sha256-x", rev: "r", built: "b"}' >"$1"
}

reset_log
run_cmd w1 -- pointer --seq 7 --rev abc123 --file "$PF" "$TOP"
expect_exit "w1 new pointer" 0
expect_eq "w1 stdout is changed=true" "changed=true" "$(cat "$OUT")"
expect_eq "w1 keys are exactly seq storePath narHash rev built" \
    '["built","narHash","rev","seq","storePath"]' "$(jq -c 'keys' "$PF" 2>&1)"
expect_eq "w1 seq is the number N" "number 7" "$(jq -r '"\(.seq|type) \(.seq)"' "$PF" 2>&1)"
expect_eq "w1 storePath is TOP" "$TOP" "$(jq -r .storePath "$PF" 2>&1)"
expect_eq "w1 rev is --rev" "abc123" "$(jq -r .rev "$PF" 2>&1)"
expect_grep "w1 built is an ISO UTC time" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' \
    <(jq -r .built "$PF" 2>&1)
# w5
expect_eq "w5 narHash = sri(nix-store --query --hash TOP)" "$SRI" "$(jq -r .narHash "$PF" 2>&1)"
expect_eq "w5 queries the narHash of TOP" 1 "$(log_count "^nix-store --query --hash $TOP\$")"
expect_eq "w5 converts that hash to SRI" 1 "$(log_count "^nix hash convert .*--to sri .*$NAR32\$")"
expect_eq "w1 no temp file left behind" "neptun.json" "$(ls -A "$(dirname "$PF")")"

cp "$PF" "$T/w1.json"
run_cmd w2 -- pointer --seq 8 --rev def456 --file "$PF" "$TOP"
expect_exit "w2 same TOP again" 0
expect_eq "w2 stdout is changed=false" "changed=false" "$(cat "$OUT")"
expect_true "w2 file bytes unchanged" cmp -s "$T/w1.json" "$PF"
run_cmd w2b -- pointer --seq 7 --rev abc123 --file "$PF" "$TOP"
expect_eq "w2 same TOP and seq -> changed=false" "changed=false" "$(cat "$OUT")"
expect_true "w2 same TOP and seq -> bytes unchanged" cmp -s "$T/w1.json" "$PF"

put_pointer "$PF" 9 "$TOP"
cp "$PF" "$T/w3.json"
for s in 9 3; do
    run_cmd "w3-$s" -- pointer --seq "$s" --rev x --file "$PF" "$TOP2"
    expect_exit "w3 non-increasing seq refused (existing 9, new path, --seq $s)" 1
    expect_grepf "w3 --seq $s: says why" "not newer" "$ERR"
    expect_true "w3 --seq $s: file unchanged" cmp -s "$T/w3.json" "$PF"
    expect_eq "w3 --seq $s: stdout empty" "" "$(cat "$OUT")"
done
run_cmd w3ok -- pointer --seq 10 --rev x --file "$PF" "$TOP2"
expect_eq "w3 --seq 10 > 9 -> changed=true" "changed=true" "$(cat "$OUT")"
expect_eq "w3 --seq 10 -> storePath is the new path" "$TOP2" "$(jq -r .storePath "$PF")"

cp "$PF" "$T/w4.json"
for bad in /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-mars-1 /tmp/x \
    /nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-nixos-system-neptun-1 \
    "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-neptun-1 x" \
    /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-neptun-1/bin; do
    run_cmd w4 -- pointer --seq 20 --rev x --file "$PF" "$bad"
    expect_exit "w4 TOP '$bad' refused" 1
    expect_true "w4 TOP '$bad': file unchanged" cmp -s "$T/w4.json" "$PF"
done
for bad in 0 -1 1.0 1e3 01 abc 12345678901 ''; do
    run_cmd w4s -- pointer --seq "$bad" --rev x --file "$PF" "$TOP"
    expect_exit "w4 --seq '$bad' refused" 1
done
expect_true "w4 bad seqs: file unchanged" cmp -s "$T/w4.json" "$PF"
MARS=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-mars-1
run_cmd w4h -- pointer --host mars --seq 1 --rev x --file "$T/mars/p.json" "$MARS"
expect_eq "w4 --host mars accepts a mars toplevel" "changed=true" "$(cat "$OUT")"
run_cmd w4i -- pointer --host 'nep.*' --seq 1 --rev x --file "$T/mars/q.json" "$TOP"
expect_exit "w4 --host must be a plain name" 1

reset_log
MOCK_NSQ_RC=1 run_cmd w5f -- pointer --seq 30 --rev x --file "$T/w5f/p.json" "$TOP"
expect_true "w5 narHash query failure -> non-zero" test "$RC" -ne 0
expect_true "w5 narHash query failure -> no file" test ! -e "$T/w5f/p.json"

printf 'not json\n' >"$T/w9.json"
run_cmd w9 -- pointer --seq 30 --rev x --file "$T/w9.json" "$TOP"
expect_exit "w9 an existing invalid pointer is not overwritten" 1
expect_eq "w9 file unchanged" "not json" "$(cat "$T/w9.json")"

# w6 (A4): the pointer on origin/main counts too (a stale checkout or a re-run
# of an older run must not move the pointer backwards).
clone o
put_pointer "$T/o/nixos/deploy/neptun.json" 12 "$TOP"
git -C "$T/o" add -A && git -C "$T/o" commit -q -m "pointer 12" && git -C "$T/o" push -q origin main
clone q
QF="$T/q/nixos/deploy/neptun.json"
put_pointer "$QF" 5 "$TOP"
git -C "$T/q" fetch -q origin
cp "$QF" "$T/w6.json"
run_cmd w6 -- pointer --seq 10 --rev x --file "$QF" "$TOP2"
expect_exit "w6 origin/main has seq 12 -> --seq 10 refused" 1
expect_grepf "w6 names origin/main" "origin/main" "$ERR"
expect_true "w6 file unchanged" cmp -s "$T/w6.json" "$QF"
run_cmd w6ok -- pointer --seq 13 --rev x --file "$QF" "$TOP2"
expect_eq "w6 --seq 13 > 12 -> changed=true" "changed=true" "$(cat "$OUT")"
expect_eq "w6 --seq 13 written" 13 "$(jq -r .seq "$QF")"
cp "$QF" "$T/w6c.json"
run_cmd w6c -- pointer --seq 14 --rev x --file "$QF" "$TOP"
expect_eq "w6 origin/main already points at TOP -> changed=false" "changed=false" "$(cat "$OUT")"
expect_true "w6 origin/main already points at TOP -> file unchanged" cmp -s "$T/w6c.json" "$QF"

# w11 (final review N7, README section 5): the run_number-reset recovery. A
# reset counter (seq 2) is refused while origin/main has seq 12; after the
# pointer is removed from main and fetched, seq 2 is written.
clone w11
WF="$T/w11/nixos/deploy/neptun.json"
run_cmd w11a -- pointer --seq 2 --rev x --file "$WF" "$TOP2"
expect_exit "w11 reset run_number (2 < 12 on origin/main) refused" 1
git -C "$T/w11" rm -q nixos/deploy/neptun.json
git -C "$T/w11" commit -q -m "drop pointer" && git -C "$T/w11" push -q origin main
run_cmd w11b -- pointer --seq 2 --rev x --file "$WF" "$TOP2"
expect_exit "w11 pointer removed from main -> seq 2 written" 0
expect_eq "w11 seq 2 in the file" 2 "$(jq -r .seq "$WF")"
# restore origin/main's pointer 12 for the later tests
git -C "$T/o" pull -q --rebase origin main
put_pointer "$T/o/nixos/deploy/neptun.json" 12 "$TOP"
git -C "$T/o" add -A && git -C "$T/o" commit -q -m "pointer 12 again" && git -C "$T/o" push -q origin main

# w8: outside a git repo (pull-smoke writes its pointer into a web root).
run_cmd w8 -- pointer --seq 1 --rev smoke --file "$T/www/neptun.json" "$TOP"
expect_exit "w8 no git repo -> written" 0
expect_eq "w8 stdout" "changed=true" "$(cat "$OUT")"

run_cmd w10 -- pointer --seq 1 --file "$T/w10.json" "$TOP"
expect_exit "w10 missing --rev -> usage" 2
run_cmd w10b -- pointer --seq 1 --rev x "$TOP"
expect_exit "w10 missing --file -> usage" 2
run_cmd w10c -- pointer --seq 1 --rev x --file "$T/w10.json"
expect_exit "w10 missing TOP -> usage" 2
run_cmd w10h -- pointer --help
expect_exit "w10 --help" 0

# =============================================================================
# T7.4 ci/commit-push.sh (real git, bare origin)
# =============================================================================
BOT='github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>'
MSG='neptun: build 7 (push)'
origin_main() { git -C "$T/origin.git" rev-parse main; }
# cpush REPO ARGS...: run commit-push.sh in REPO/nixos like the workflow does
cpush() { local r="$1"; shift; (cd "$T/$r/nixos" && bash "$CI_DIR/commit-push.sh" "$@"); }
# change REPO: a lock update and a new pointer in REPO's work tree
change() {
    printf 'update %s\n' "$1" >>"$T/$1/nixos/flake.lock"
    put_pointer "$T/$1/nixos/deploy/neptun.json" 7 "$TOP"
}
# other NAME FILE: another clone pushes a commit changing FILE first
other() {
    clone "$1"
    printf 'other %s\n' "$1" >>"$T/$1/$2"
    git -C "$T/$1" commit -q -am "other $1"
    git -C "$T/$1" push -q origin main
}
export GITHUB_REF=refs/heads/main

clone g1
before="$(origin_main)"
run_cmd g1 -- cpush g1 --message "$MSG" flake.lock deploy/neptun.json
expect_exit "g1 nothing changed" 0
expect_eq "g1 stdout is pushed=false" "pushed=false" "$(cat "$OUT")"
expect_eq "g1 origin main unchanged" "$before" "$(origin_main)"

clone g2
before="$(origin_main)"
change g2
printf 'stray\n' >"$T/g2/nixos/stray.txt"
run_cmd g2 -- cpush g2 --message "$MSG" flake.lock deploy/neptun.json nope.json
expect_exit "g2 lock + pointer changed" 0
expect_eq "g2 stdout is pushed=true" "pushed=true" "$(cat "$OUT")"
expect_eq "g2 one new commit on origin main" "$before" "$(git -C "$T/origin.git" rev-parse main^)"
expect_eq "g2 the commit touches exactly lock + pointer" \
    "nixos/deploy/neptun.json nixos/flake.lock" \
    "$(git -C "$T/origin.git" diff-tree --no-commit-id --name-only -r main | sort | xargs)"
expect_eq "g2 author is github-actions[bot]" "$BOT" "$(git -C "$T/origin.git" log -1 --format='%an <%ae>' main)"
expect_eq "g2 committer is github-actions[bot]" "$BOT" "$(git -C "$T/origin.git" log -1 --format='%cn <%ce>' main)"
expect_eq "g2 message" "$MSG" "$(git -C "$T/origin.git" log -1 --format=%s main)"
expect_eq "g2 the work tree pointer is what origin has" "$(cat "$T/g2/nixos/deploy/neptun.json")" \
    "$(git -C "$T/origin.git" show main:nixos/deploy/neptun.json)"

clone g3
change g3
other g3o README.md
upstream="$(origin_main)"
run_cmd g3 -- cpush g3 --message "$MSG" flake.lock deploy/neptun.json
expect_exit "g3 non-fast-forward -> rebase once, pushed" 0
expect_eq "g3 stdout is pushed=true" "pushed=true" "$(cat "$OUT")"
expect_eq "g3 origin main's parent is the other commit" "$upstream" "$(git -C "$T/origin.git" rev-parse main^)"
expect_eq "g3 linear history (no merges)" "" "$(git -C "$T/origin.git" rev-list --merges main)"
expect_eq "g3 the pointer reached origin" 7 \
    "$(git -C "$T/origin.git" show main:nixos/deploy/neptun.json | jq -r .seq)"

clone g4
change g4
other g4o nixos/flake.lock
upstream="$(origin_main)"
run_cmd g4 -- cpush g4 --message "$MSG" flake.lock deploy/neptun.json
expect_true "g4 conflicting lock -> non-zero" test "$RC" -ne 0
expect_eq "g4 stdout empty" "" "$(cat "$OUT")"
expect_eq "g4 origin main = the other commit" "$upstream" "$(origin_main)"
expect_eq "g4 work tree clean" "" "$(git -C "$T/g4" status --porcelain)"
expect_true "g4 no rebase in progress" \
    test ! -d "$T/g4/.git/rebase-merge" -a ! -d "$T/g4/.git/rebase-apply"

clone g5
git -C "$T/g5" config commit.gpgsign true
change g5
other g5o README.md
run_cmd g5 -- cpush g5 --message "$MSG" flake.lock deploy/neptun.json
expect_exit "g5 commit.gpgsign=true in the repo -> still commits and rebases (unsigned)" 0
expect_eq "g5 pushed" "pushed=true" "$(cat "$OUT")"

clone g6
change g6
before="$(origin_main)" head="$(git -C "$T/g6" rev-parse HEAD)"
for ref in refs/heads/feature refs/tags/v1 ''; do
    GITHUB_REF="$ref" run_cmd g6 -- cpush g6 --message "$MSG" flake.lock deploy/neptun.json
    expect_exit "g6 GITHUB_REF='$ref' -> refused" 1
    expect_grepf "g6 GITHUB_REF='$ref': names refs/heads/main" "refs/heads/main" "$ERR"
done
(unset GITHUB_REF; run_cmd g6u -- cpush g6 --message "$MSG" flake.lock; exit "$RC")
RC=$?
expect_exit "g6 GITHUB_REF unset -> refused" 1
expect_eq "g6 origin main unchanged" "$before" "$(origin_main)"
expect_eq "g6 no local commit" "$head" "$(git -C "$T/g6" rev-parse HEAD)"

# g7 (A11): no inherited identity and git may not guess one: commit and the
# rebase of `pull --rebase` both use the bot identity.
clone g7
git -C "$T/g7" config user.useConfigOnly true
change g7
other g7o README.md
run_cmd g7 -- env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME \
    -u GIT_COMMITTER_EMAIL -u EMAIL bash -c 'cd "$1/nixos" && bash "$2/commit-push.sh" "${@:3}"' _ \
    "$T/g7" "$CI_DIR" --message "$MSG" flake.lock deploy/neptun.json
expect_exit "g7 no inherited git identity -> commit + rebase still work" 0
expect_eq "g7 rebased commit's committer is github-actions[bot]" "$BOT" \
    "$(git -C "$T/origin.git" log -1 --format='%cn <%ce>' main)"

run_cmd g8 -- cpush g1 flake.lock
expect_exit "g8 missing --message -> usage" 2
run_cmd g8b -- cpush g1 --message "$MSG"
expect_exit "g8 no PATH -> usage" 2
run_cmd g8h -- cpush g1 --help
expect_exit "g8 --help" 0

summary
