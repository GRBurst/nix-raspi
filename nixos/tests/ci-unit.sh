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

summary
