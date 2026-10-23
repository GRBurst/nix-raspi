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

summary
