#!/usr/bin/env bash
#
# Unit tests for the CI scripts ci/*.sh (check `rpi-ci-unit`).
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
# The committed lock: nixpkgs, nixos-raspberrypi (and home-manager) are root
# inputs, as in this repository.
LOCK0='{"nodes":{"home-manager":{"locked":{"rev":"hm0"}},"nixos-raspberrypi":{"locked":{"rev":"rp0"}},"nixpkgs":{"locked":{"rev":"np0"}},"root":{"inputs":{"home-manager":"home-manager","nixos-raspberrypi":"nixos-raspberrypi","nixpkgs":"nixpkgs"}}},"root":"root","version":7}'
# rl_host_info of a host without a cache (the default answer of the nix mock)
export INFO0='{"name":"neptun","target":"root@neptun","port":22,"cache":null,"wifi":{"enable":false,"networks":{},"secretsFile":"/var/lib/rpi/wireless.env"}}'
CKEY="neptun-x.cachix.org-1:$(printf 'A%.0s' $(seq 43))="
# info_cache NAME [CACHE]: rl_host_info of host NAME with cache CACHE
# (default neptun-x with $CKEY)
info_cache() {
    jq -c --arg n "$1" --arg c "${2:-neptun-x}" --arg k "$CKEY" \
        '.name = $n | .cache = {name: $c, publicKey: $k}' <<<"$INFO0"
}

# A bare origin with one commit on main (flake.lock and a README at the root);
# clone NAME gives a fresh work repo $T/NAME tracking it.
git init -q --bare -b main "$T/origin.git"
git init -q -b main "$T/seed"
printf '%s\n' "$LOCK0" >"$T/seed/flake.lock"
printf 'readme\n' >"$T/seed/README.md"
git -C "$T/seed" add -A
git -C "$T/seed" commit -q -m init
git -C "$T/seed" push -q "$T/origin.git" main
clone() { rm -rf "${T:?}/$1"; git clone -q "$T/origin.git" "$T/$1"; }

# --- mocks -------------------------------------------------------------------
# nix: host discovery eval (rl_hosts: ${MOCK_HOSTS-[]}, or rc MOCK_HOSTS_RC),
# host info eval (rl_host_info: ${MOCK_INFO:-$INFO0}, or rc MOCK_INFO_RC),
# the flake-checks eval (getFlake: system ${MOCK_SYS:-aarch64-linux}, check
# names ${MOCK_CHECKS:-[]}, or rc MOCK_CHECKS_RC), kernel/modules eval,
# path-info --closure-size (a
# fixed size) and --recursive (3 paths), path-info per MOCK_CACHE (hit |
# always-miss | full-miss = miss only once nixos-raspberrypi or rpi was
# updated in $MOCK_LOCK), flake update (sets the named inputs' revs in
# <--flake DIR>/flake.lock to <input>-new and appends them to .updated),
# build --dry-run (logs NIX_CONFIG, cat $MOCK_DRY to stderr), build of
# checks (rc MOCK_CHECK_RC), build --print-out-paths ($MOCK_TOP, or rc
# MOCK_BUILD_RC), hash convert (a fixed SRI hash).
mock nix <<'EOF'
case " $* " in
*" eval "*"#nixosConfigurations."*" --apply "*)
    if [[ -n "${MOCK_INFO_RC:-}" ]]; then echo "error: info eval failed" >&2; exit "$MOCK_INFO_RC"; fi
    printf '%s\n' "${MOCK_INFO:-$INFO0}" ;;
*" eval "*" --apply "*)
    if [[ -n "${MOCK_HOSTS_RC:-}" ]]; then echo "error: hosts eval failed" >&2; exit "$MOCK_HOSTS_RC"; fi
    printf '%s\n' "${MOCK_HOSTS-[]}" ;;
*" eval "*" --expr "*getFlake*)
    if [[ -n "${MOCK_CHECKS_RC:-}" ]]; then echo "error: checks eval failed" >&2; exit "$MOCK_CHECKS_RC"; fi
    printf '{"checks":%s,"system":"%s"}\n' "${MOCK_CHECKS:-[]}" "${MOCK_SYS:-aarch64-linux}" ;;
*" eval "*".kernel.modules.outPath "*) printf '%s' "$M_DEF" ;;
*" eval "*".kernel.outPath "*) printf '%s' "$K_DEF" ;;
*" path-info "*"--closure-size "*) printf '%s\t  1.2 GiB\n' "${!#}" ;;
*" path-info "*"--recursive "*) printf '/nix/store/p1\n/nix/store/p2\n/nix/store/p3\n' ;;
*" path-info "*)
    case "${MOCK_CACHE:-hit}" in
    hit) exit 0 ;;
    always-miss) exit 1 ;;
    full-miss)
        if jq -e '(.updated // []) | any(. == "nixos-raspberrypi" or . == "rpi")' "$MOCK_LOCK" >/dev/null; then
            exit 1
        fi ;;
    esac ;;
*" flake update "*)
    prev="" dir="" ins=()
    for a in "$@"; do
        [[ -n "$dir" ]] && ins+=("$a")
        [[ "$prev" == --flake ]] && dir="$a"
        prev="$a"
    done
    jq -c --args '.updated = ((.updated // []) + $ARGS.positional)
        | reduce $ARGS.positional[] as $i (.; .nodes[.nodes[.root].inputs[$i]].locked.rev = "\($i)-new")' \
        "${ins[@]}" <"$dir/flake.lock" >"$dir/flake.lock.new" && mv "$dir/flake.lock.new" "$dir/flake.lock" ;;
*" build "*" --dry-run "*)
    echo "dry-nix-config ${NIX_CONFIG//$'\n'/; }" >>"$MOCK_LOG"
    cat "${MOCK_DRY:-/dev/null}" >&2 ;;
*" build "*"#checks."*)
    echo "check log" >&2
    if [[ -n "${MOCK_CHECK_RC:-}" ]]; then echo "error: check failed" >&2; exit "$MOCK_CHECK_RC"; fi ;;
*" build "*" --print-out-paths "*)
    echo "building toplevel" >&2
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
LOCKF="$T/b/flake.lock"
export MOCK_LOCK="$LOCKF"
# (--host is required since T4.2: the build is per Pi host; the default
# host info names it neptun, so every output ends with name=neptun.)
build() { bash "$CI_DIR/build.sh" --flake "$T/b" --host neptun "$@"; }
OUT0="top=$TOP"$'\n'"name=neptun"
relock() { git -C "$T/b" checkout -q -- flake.lock; }

reset_log
MOCK_DRY="$HYB" run_cmd b1 -- build --event push
expect_exit "b1 push builds" 0
expect_eq "b1 stdout is exactly top=<toplevel> name=<system.name>" "$OUT0" "$(cat "$OUT")"
expect_eq "b1 push does not update the lock" 0 "$(log_count 'flake update')"
expect_eq "b1 push leaves flake.lock as committed" "$LOCK0" "$(cat "$LOCKF")"
pi=$(first_line '^nix .*path-info') dr=$(first_line '^nix .*build .*--dry-run')
bo=$(first_line '^nix .*build .*--print-out-paths .*nixosConfigurations\.neptun\.config\.system\.build\.toplevel')
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
fu=$(first_line "^nix flake update --accept-flake-config --flake $T/b nixpkgs nixos-raspberrypi\$")
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
    "$(log_count "^nix flake update --accept-flake-config --flake $T/b nixpkgs nixos-raspberrypi\$")"
relock

reset_log
MOCK_CACHE=full-miss MOCK_DRY="$HYB" run_cmd b3 -- build --event schedule
expect_exit "b3 kernel miss after the nvmd update -> nixpkgs-only fallback builds" 0
expect_eq "b3 lock = committed + one nixpkgs-only update" \
    '["nixpkgs"] nixpkgs-new rp0' "$(jq -c '.updated' "$LOCKF") $(jq -r '.nodes.nixpkgs.locked.rev, .nodes."nixos-raspberrypi".locked.rev' "$LOCKF" | xargs)"
expect_eq "b3 second update has nixpkgs only" 1 "$(log_count 'flake update .* nixpkgs$')"
expect_grepf "b3 says why it falls back" "nixpkgs only" "$ERR"
expect_eq "b3 stdout is top= name=" "$OUT0" "$(cat "$OUT")"
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
expect_grepf "b9 --help names --host" "--host" "$OUT"

# --- T4.2: per host, own cache as substituter, flake checks, summary -------
reset_log
run_cmd b-host -- bash "$CI_DIR/build.sh" --flake "$T/b" --event push
expect_exit "b-host --host is required" 2
expect_grepf "b-host says --host is missing" "--host" "$ERR"
expect_eq "b-host no nix call" 0 "$(log_count '^nix ')"
for bad in a.b 'a b' 'x;y'; do
    reset_log
    run_cmd b-host-bad -- bash "$CI_DIR/build.sh" --flake "$T/b" --host "$bad" --event push
    expect_exit "b-host invalid host '$bad' -> 2" 2
    expect_eq "b-host invalid host '$bad': nothing evaluated or built" 0 "$(log_count '^nix ')"
done

reset_log
MOCK_INFO="$(info_cache garden-pi | jq -c '.cache = null')" MOCK_DRY="$HYB" \
    run_cmd b-host2 -- bash "$CI_DIR/build.sh" --flake "$T/b" --host garden --event push
expect_exit "b-host2 --host garden builds" 0
expect_eq "b-host2 host info of garden" 1 \
    "$(log_count "^nix eval --accept-flake-config --json $T/b#nixosConfigurations\.garden --apply ")"
expect_eq "b-host2 guard evaluates garden's kernel" 1 \
    "$(log_count "^nix eval .*$T/b#nixosConfigurations\.garden\.config\.boot\.kernelPackages\.kernel\.outPath")"
expect_eq "b-host2 dry run of garden" 1 \
    "$(log_count "^nix build .*--dry-run .*$T/b#nixosConfigurations\.garden\.config\.system\.build\.toplevel")"
expect_eq "b-host2 builds garden's toplevel" 1 \
    "$(log_count "^nix build .*--print-out-paths .*$T/b#nixosConfigurations\.garden\.config\.system\.build\.toplevel\$")"
expect_eq "b-host2 no other configuration" 0 "$(log_count 'nixosConfigurations\.(rpi|neptun)')"
expect_eq "b-host2 name= is system.name (not the attribute)" "top=$TOP"$'\n'"name=garden-pi" "$(cat "$OUT")"

reset_log
MOCK_INFO_RC=1 MOCK_DRY="$HYB" run_cmd b-info -- build --event push
expect_exit "b-info host info eval error -> RL_E_BUILD" 13
expect_eq "b-info nothing built" 0 "$(log_count '^nix build ')"
expect_eq "b-info stdout empty" "" "$(cat "$OUT")"

reset_log
MOCK_INFO="$(info_cache neptun)" MOCK_CHECKS='["x"]' MOCK_DRY="$HYB" run_cmd b-sub -- build --event push
expect_exit "b-sub host with a cache builds" 0
SUBST="--option extra-substituters https://neptun-x.cachix.org --option extra-trusted-public-keys $CKEY"
expect_eq "b-sub toplevel build substitutes from the host's cache" 1 \
    "$(log_count "^nix build .*$SUBST .*--print-out-paths |^nix build .*--print-out-paths .*$SUBST")"
expect_eq "b-sub checks build substitutes from the host's cache" 1 \
    "$(log_count "^nix build .*$SUBST.*#checks\.")"
expect_eq "b-sub the guard's dry run sees the host's cache too" 1 \
    "$(log_count "^dry-nix-config .*extra-substituters = https://neptun-x\.cachix\.org; extra-trusted-public-keys = $CKEY")"
reset_log
MOCK_CHECKS='["x"]' MOCK_DRY="$HYB" run_cmd b-sub0 -- build --event push
expect_exit "b-sub no cache builds" 0
expect_eq "b-sub no cache -> no extra substituter" 0 "$(log_count 'extra-substituters|extra-trusted-public-keys')"
for bad in Neptun 'a b' '-x' 'x.y'; do
    reset_log
    MOCK_INFO="$(info_cache neptun "$bad")" MOCK_DRY="$HYB" run_cmd b-sub-bad -- build --event push
    expect_exit "b-sub cache name '$bad' is not a Cachix name -> 1" 1
    expect_grepf "b-sub cache name '$bad': names rpi.pull.cache" "rpi.pull.cache" "$ERR"
    expect_eq "b-sub cache name '$bad': nothing built" 0 "$(log_count '^nix build ')"
done

reset_log
MOCK_CHECKS='["x","y"]' MOCK_SYS=aarch64-linux MOCK_DRY="$HYB" run_cmd b-chk -- build --event push
expect_exit "b-chk builds with checks" 0
expect_eq "b-chk checks of the built flake for the current system" 1 \
    "$(log_count "^nix eval .*--impure .*getFlake .*$T/b.*currentSystem")"
expect_eq "b-chk builds checks x and y in one call" 1 \
    "$(log_count "^nix build .* $T/b#checks\.aarch64-linux\.x $T/b#checks\.aarch64-linux\.y\$")"
bo=$(first_line '^nix build .*--print-out-paths') ck=$(first_line '^nix build .*#checks\.')
expect_true "b-chk checks after the toplevel ($bo < $ck)" test "$bo" -lt "$ck" -a "$ck" -lt 999999
expect_eq "b-chk stdout is top= name=" "$OUT0" "$(cat "$OUT")"
reset_log
MOCK_CHECKS='["x"]' MOCK_CHECK_RC=1 MOCK_DRY="$HYB" run_cmd b-chk-fail -- build --event push
expect_exit "b-chk a failing check -> RL_E_BUILD" 13
expect_eq "b-chk a failing check -> no top= (nothing to publish)" "" "$(cat "$OUT")"
expect_grepf "b-chk a failing check is reported" "checks failed for neptun" "$ERR"
reset_log
MOCK_CHECKS_RC=1 MOCK_DRY="$HYB" run_cmd b-chk-eval -- build --event push
expect_exit "b-chk checks eval error -> RL_E_BUILD" 13
expect_eq "b-chk checks eval error -> no top=" "" "$(cat "$OUT")"
reset_log
MOCK_CHECKS='[]' MOCK_SYS=aarch64-linux MOCK_DRY="$HYB" run_cmd b-chk-none -- build --event push
expect_exit "b-chk no checks -> builds" 0
expect_grep "b-chk no checks -> notice" '^rpi-ci: notice: no checks for aarch64-linux' "$ERR"
expect_eq "b-chk no checks -> no checks build" 0 "$(log_count '#checks\.')"
expect_eq "b-chk no checks: stdout is top= name=" "$OUT0" "$(cat "$OUT")"

# b-sum: the step summary (P9: only under GitHub Actions)
SUM="$T/b-sum.md"
rm -f "$SUM"
reset_log
GITHUB_STEP_SUMMARY="$SUM" MOCK_CHECKS='["x","y"]' MOCK_DRY="$HYB" run_cmd b-sum0 -- build --event push
expect_exit "b-sum outside GitHub Actions builds" 0
expect_true "b-sum outside GitHub Actions: no summary" test ! -e "$SUM"
expect_eq "b-sum outside GitHub Actions: no :: lines" 0 "$(grep -c '^::' "$ALL")"
expect_eq "b-sum outside GitHub Actions: no closure-size query" 0 "$(log_count 'path-info .*--closure-size')"
reset_log
GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$SUM" MOCK_CHECKS='["x","y"]' MOCK_DRY="$HYB" \
    run_cmd b-sum -- build --event push
expect_exit "b-sum under GitHub Actions builds" 0
expect_eq "b-sum stdout unchanged by GitHub Actions" "$OUT0" "$(cat "$OUT")"
expect_grep "b-sum section ## <host>: build" '^## neptun: build$' "$SUM"
expect_grep "b-sum nixpkgs revision" 'nixpkgs.*np0' "$SUM"
expect_grep "b-sum nixos-raspberrypi revision" 'nixos-raspberrypi.*rp0' "$SUM"
expect_grep "b-sum lock as committed" 'lock.*as committed' "$SUM"
expect_grepf "b-sum toplevel" "$TOP" "$SUM"
expect_grep "b-sum closure size" 'closure.*1\.2 GiB' "$SUM"
expect_grep "b-sum checks" 'checks.*x, y' "$SUM"
expect_eq "b-sum one section" 1 "$(grep -c '^## ' "$SUM")"
rm -f "$SUM"
reset_log
GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$SUM" MOCK_DRY="$HYB" run_cmd b-sum-lock -- build --event push --update-lock
expect_exit "b-sum --update-lock builds" 0
expect_grep "b-sum lock: updated with old -> new revisions" \
    'lock: updated.*nixpkgs `np0` → `nixpkgs-new`.*nixos-raspberrypi `rp0` → `nixos-raspberrypi-new`' "$SUM"
expect_grep "b-sum the revisions are the updated ones" 'nixpkgs.*nixpkgs-new' "$SUM"
expect_grep "b-sum no checks -> said so" 'checks.*none' "$SUM"
relock
rm -f "$SUM"
reset_log
GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$SUM" MOCK_CACHE=always-miss MOCK_DRY="$HYB" \
    run_cmd b-sum-guard -- build --event push
expect_exit "b-sum guard failure -> RL_E_CACHE" 10
expect_grep "b-sum guard failure -> ::error line" '^::error::.*neptun.*guard' "$ERR"
expect_grep "b-sum guard failure in the summary" '^## neptun: build$' "$SUM"
expect_grep "b-sum guard failure: says why" 'failed.*kernel' "$SUM"
reset_log
GITHUB_ACTIONS=true MOCK_DRY="$HYB" MOCK_BUILD_RC=1 run_cmd b-sum-build -- build --event push
expect_exit "b-sum build failure -> RL_E_BUILD" 13
expect_grep "b-sum build failure -> ::error line" '^::error::.*build of neptun failed' "$ERR"

# b-grp: the toplevel build's log is a collapsible group
reset_log
GITHUB_ACTIONS=true MOCK_CHECKS='["x"]' MOCK_DRY="$HYB" run_cmd b-grp -- build --event push
gs=$(grep -n '^::group::build neptun$' "$ERR" | cut -d: -f1 | head -n1)
bl=$(grep -n '^building toplevel$' "$ERR" | cut -d: -f1 | head -n1)
ge=$(grep -n '^::endgroup::$' "$ERR" | cut -d: -f1 | head -n1)
expect_true "b-grp group build <host> < build log < endgroup (${gs:-none} < ${bl:-none} < ${ge:-none})" \
    test -n "$gs" -a -n "$bl" -a -n "$ge" -a "${gs:-0}" -lt "${bl:-0}" -a "${bl:-0}" -lt "${ge:-0}"
expect_grep "b-grp the checks have their own group" '^::group::checks neptun$' "$ERR"
expect_eq "b-grp groups are closed" "$(grep -c '^::group::' "$ERR")" "$(grep -c '^::endgroup::$' "$ERR")"

# b-rpi: a consumer flake (the template): its only Pi input is the library
# `rpi` (nixpkgs and nixos-raspberrypi come with it), so the lock update
# updates rpi; the summary reads the revisions through rpi.
clone c
CLOCK='{"nodes":{"nixos-raspberrypi":{"locked":{"rev":"rp1"}},"nixpkgs":{"locked":{"rev":"np1"}},"root":{"inputs":{"rpi":"rpi"}},"rpi":{"inputs":{"nixos-raspberrypi":"nixos-raspberrypi","nixpkgs":"nixpkgs"},"locked":{"rev":"lib1"}}},"root":"root","version":7}'
printf '%s\n' "$CLOCK" >"$T/c/flake.lock"
git -C "$T/c" commit -q -am "consumer lock"
reset_log
GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$T/c.md" MOCK_LOCK="$T/c/flake.lock" MOCK_DRY="$HYB" \
    run_cmd b-rpi -- bash "$CI_DIR/build.sh" --flake "$T/c" --host neptun --event schedule
expect_exit "b-rpi consumer lock update builds" 0
expect_eq "b-rpi updates the library input rpi only" 1 \
    "$(log_count "^nix flake update --accept-flake-config --flake $T/c rpi\$")"
expect_eq "b-rpi one lock update" 1 "$(log_count 'flake update')"
expect_grep "b-rpi nixpkgs revision through rpi" 'nixpkgs.*np1' "$T/c.md"
expect_grep "b-rpi nixos-raspberrypi revision through rpi" 'nixos-raspberrypi.*rp1' "$T/c.md"
expect_grep "b-rpi lock diff names rpi" 'lock: updated.*rpi `lib1` → `rpi-new`' "$T/c.md"
git -C "$T/c" checkout -q -- flake.lock
reset_log
MOCK_CACHE=full-miss MOCK_LOCK="$T/c/flake.lock" MOCK_DRY="$HYB" \
    run_cmd b-rpi3 -- bash "$CI_DIR/build.sh" --flake "$T/c" --host neptun --event schedule
expect_exit "b-rpi kernel miss after the rpi update -> builds the committed lock" 0
expect_eq "b-rpi fallback: lock as committed" "$CLOCK" "$(cat "$T/c/flake.lock")"
expect_eq "b-rpi fallback: no second update" 1 "$(log_count 'flake update')"
expect_grepf "b-rpi fallback: says so" "committed lock" "$ERR"

# =============================================================================
# ci/publish.sh
# =============================================================================
# (ci/cache-name.sh and its tests c1-c3 are gone since T4.7: the cache is
# per host in rpi.pull.cache, read through rl_host_info by build and
# publish; its cases are covered by b-sub and pb1-pb5.)

# --- T4.3 ci/publish.sh: the cache comes from rpi.pull.cache (host info).
# Old u1-u3 became pb4/pb5 (the CLI changed from positional `CACHE TOP` to
# --host/--top: the cache is per host now).
publish() { bash "$CI_DIR/publish.sh" --flake "$T/b" "$@"; }
export CACHIX_AUTH_TOKEN=tok CACHIX_SIGNING_KEY=sig

reset_log
run_cmd pb1 -- env -u CACHIX_AUTH_TOKEN -u CACHIX_SIGNING_KEY bash "$CI_DIR/publish.sh" --flake "$T/b" --host neptun --top "$TOP"
expect_exit "pb1 no cache -> notice, published=false, rc 0" 0
expect_eq "pb1 stdout is published=false" "published=false" "$(cat "$OUT")"
expect_grepf "pb1 notice names the host" \
    "rpi-ci: notice: no cache configured for neptun: built and tested, not published" "$ERR"
expect_eq "pb1 no cachix call" 0 "$(log_count '^cachix')"
expect_eq "pb1 the host info of --host" 1 \
    "$(log_count "^nix eval --accept-flake-config --json $T/b#nixosConfigurations\.neptun --apply ")"
reset_log
GITHUB_ACTIONS=true run_cmd pb1g -- publish --host neptun --top "$TOP"
expect_eq "pb1 under GitHub Actions: ::notice::" \
    "::notice::no cache configured for neptun: built and tested, not published" "$(grep '^::' "$ERR")"
expect_exit "pb1 under GitHub Actions: rc 0" 0

for v in CACHIX_AUTH_TOKEN CACHIX_SIGNING_KEY; do
    for how in unset empty; do
        reset_log
        if [[ "$how" == unset ]]; then e=(env -u "$v"); else e=(env "$v="); fi
        MOCK_INFO="$(info_cache neptun)" GITHUB_ACTIONS=true \
            run_cmd "pb2 $v $how" -- "${e[@]}" bash "$CI_DIR/publish.sh" --flake "$T/b" --host neptun --top "$TOP"
        n=pb2; [[ "$v" == CACHIX_SIGNING_KEY ]] && n=pb3
        expect_exit "$n $v $how -> rc 1" 1
        expect_grep "$n missing $v -> error naming it ($how)" "^::error::$v is not set" "$ERR"
        expect_eq "$n $v $how -> no cachix call" 0 "$(log_count '^cachix')"
        expect_not_grep "$n $v $how -> no published=" "published=" "$OUT"
    done
done
reset_log
MOCK_INFO="$(info_cache neptun)" run_cmd pb3b -- env -u CACHIX_AUTH_TOKEN -u CACHIX_SIGNING_KEY \
    bash "$CI_DIR/publish.sh" --flake "$T/b" --host neptun --top "$TOP"
expect_exit "pb3 both secrets missing -> rc 1" 1
expect_grepf "pb3 both missing: names CACHIX_AUTH_TOKEN" "CACHIX_AUTH_TOKEN is not set" "$ERR"
expect_grepf "pb3 both missing: names CACHIX_SIGNING_KEY" "CACHIX_SIGNING_KEY is not set" "$ERR"

reset_log
MOCK_INFO="$(info_cache neptun)" run_cmd pb4 -- publish --host neptun --top "$TOP"
expect_exit "pb4 cache and secrets -> published" 0
expect_eq "pb4 stdout is exactly published=true (cachix output goes to stderr)" "published=true" "$(cat "$OUT")"
expect_eq "pb4 pushes the closure to the host's cache" 1 "$(log_count "^cachix push neptun-x $TOP\$")"
expect_eq "pb4 pins it as the system name, keeping 4 revisions" 1 \
    "$(log_count "^cachix pin neptun-x neptun $TOP --keep-revisions 4\$")"
expect_true "pb4 push before pin" \
    test "$(first_line '^cachix push')" -lt "$(first_line '^cachix pin')"
reset_log
MOCK_INFO="$(info_cache garden-pi garden-cache)" run_cmd pb4n -- publish --host garden --top "$TOP"
expect_eq "pb4 pin name = system.name (garden-pi), cache = its rpi.pull.cache" 1 \
    "$(log_count "^cachix pin garden-cache garden-pi $TOP --keep-revisions 4\$")"

reset_log
MOCK_INFO="$(info_cache neptun)" MOCK_PUSH_RC=1 run_cmd pb5 -- publish --host neptun --top "$TOP"
expect_true "pb5 push failure -> non-zero" test "$RC" -ne 0
expect_eq "pb5 push failure -> no pin" 0 "$(log_count '^cachix pin')"
expect_not_grep "pb5 push failure -> no published=" "published=" "$OUT"
reset_log
MOCK_INFO="$(info_cache neptun)" MOCK_PIN_RC=1 run_cmd pb5p -- publish --host neptun --top "$TOP"
expect_true "pb5 pin failure -> non-zero" test "$RC" -ne 0
expect_not_grep "pb5 pin failure -> no published=" "published=" "$OUT"

reset_log
MOCK_INFO="$(info_cache neptun 'Bad.Name')" run_cmd pb6 -- publish --host neptun --top "$TOP"
expect_exit "pb6 cache name not a Cachix name -> 1" 1
expect_eq "pb6 no cachix call" 0 "$(log_count '^cachix')"
reset_log
MOCK_INFO_RC=1 run_cmd pb6i -- publish --host neptun --top "$TOP"
expect_exit "pb6 host info eval error -> 13" 13
expect_eq "pb6 host info eval error: no cachix call" 0 "$(log_count '^cachix')"

SUM="$T/pb-sum.md"
rm -f "$SUM"
GITHUB_STEP_SUMMARY="$SUM" MOCK_INFO="$(info_cache neptun)" run_cmd pb-sum0 -- publish --host neptun --top "$TOP"
expect_true "pb-sum outside GitHub Actions: no summary" test ! -e "$SUM"
GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$SUM" MOCK_INFO="$(info_cache neptun)" \
    run_cmd pb-sum -- publish --host neptun --top "$TOP"
expect_grep "pb-sum section ## <host>: publish" '^## neptun: publish$' "$SUM"
expect_grep "pb-sum names the cache" 'neptun-x' "$SUM"
expect_grep "pb-sum paths pushed and closure size" '3 paths.*1\.2 GiB' "$SUM"
expect_grep "pb-sum pin" 'pinned.*neptun' "$SUM"
expect_grep "pb-sum push log in a group" '^::group::push neptun' "$ERR"
rm -f "$SUM"
GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$SUM" run_cmd pb-sum-skip -- publish --host neptun --top "$TOP"
expect_grep "pb-sum no cache -> skipped with the reason" \
    '^- skipped: no cache configured \(rpi\.pull\.cache\)' "$SUM"
expect_grep "pb-sum no cache: section" '^## neptun: publish$' "$SUM"

for args in "--host neptun" "--top $TOP" "--host neptun --top" "--host neptun --top $TOP x"; do
    reset_log
    # shellcheck disable=SC2086 # word-split on purpose
    run_cmd pb7 -- publish $args
    expect_exit "pb7 usage ($args) -> 2" 2
    expect_eq "pb7 usage ($args): nothing pushed" 0 "$(log_count '^cachix')"
done
run_cmd pb7h -- publish --help
expect_exit "pb7 --help" 0
expect_grepf "pb7 --help names --host" "--host" "$OUT"
unset CACHIX_AUTH_TOKEN CACHIX_SIGNING_KEY

# =============================================================================
# T7.3 ci/pointer.sh
# =============================================================================
SRI=sha256-MOCKMOCKMOCKMOCKMOCKMOCKMOCKMOCKMOCKMOCKMOC=
# T4.4: the pointer carries bootFp, the boot fingerprint of TOP's files, so
# its toplevels are fake systems (make_sys) in the fake store $FX_STORE, which
# RL_STORE_DIR makes the store. TOP2 boots another kernel; TOP3 differs from
# TOP only in its path (same boot fingerprint). Restored after this section.
TOP0="$TOP"
TOP=$FX_STORE/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-neptun-26.05.20261021.da6dc0e
TOP2=$FX_STORE/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-nixos-system-neptun-26.05.20261028.0123456
TOP3=$FX_STORE/cccccccccccccccccccccccccccccccc-nixos-system-neptun-26.05.20261029.0123456
make_sys "$TOP" && make_sys "$TOP2" kernel=2 && make_sys "$TOP3"
clone p
PF="$T/p/deploy/neptun.json"
pointer() { RL_STORE_DIR="$FX_STORE" bash "$CI_DIR/pointer.sh" "$@"; }
# fp_of SYSTEM: the expected bootFp (sha256 of rl_fp_local SYSTEM)
fp_of() {
    (
        # shellcheck source=../rpi-fp.sh
        source "$CI_DIR/../rpi-fp.sh"
        RL_STORE_DIR="$FX_STORE" rl_fp_local "$1" | sha256sum | cut -c1-64
    )
}
# put_pointer FILE SEQ PATH: an existing pointer as CI would have written it
put_pointer() {
    mkdir -p "$(dirname "$1")"
    jq -n --argjson seq "$2" --arg p "$3" \
        '{seq: $seq, storePath: $p, narHash: "sha256-x", rev: "r", built: "b"}' >"$1"
}

reset_log
run_cmd w1 -- pointer --host neptun --seq 7 --rev abc123 --file "$PF" "$TOP"
expect_exit "w1 new pointer" 0
expect_eq "w1 stdout is changed=true" "changed=true" "$(cat "$OUT")"
expect_eq "w1 keys are exactly seq storePath narHash rev built bootFp" \
    '["bootFp","built","narHash","rev","seq","storePath"]' "$(jq -c 'keys' "$PF" 2>&1)"
# pt1 (D18)
expect_eq "pt1 bootFp = sha256 of rl_fp_local TOP" "$(fp_of "$TOP")" "$(jq -r .bootFp "$PF" 2>&1)"
expect_grep "pt1 bootFp is 64 hex chars" '^[0-9a-f]{64}$' <(jq -r .bootFp "$PF" 2>&1)
expect_true "pt1 another kernel -> another bootFp" test "$(fp_of "$TOP")" != "$(fp_of "$TOP2")"
expect_eq "pt1 same boot files -> same bootFp" "$(fp_of "$TOP")" "$(fp_of "$TOP3")"
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
run_cmd w2 -- pointer --host neptun --seq 8 --rev def456 --file "$PF" "$TOP"
expect_exit "w2 same TOP again" 0
expect_eq "w2 stdout is changed=false" "changed=false" "$(cat "$OUT")"
expect_true "w2 file bytes unchanged" cmp -s "$T/w1.json" "$PF"
run_cmd w2b -- pointer --host neptun --seq 7 --rev abc123 --file "$PF" "$TOP"
expect_eq "w2 same TOP and seq -> changed=false" "changed=false" "$(cat "$OUT")"
expect_true "w2 same TOP and seq -> bytes unchanged" cmp -s "$T/w1.json" "$PF"

put_pointer "$PF" 9 "$TOP"
cp "$PF" "$T/w3.json"
for s in 9 3; do
    run_cmd "w3-$s" -- pointer --host neptun --seq "$s" --rev x --file "$PF" "$TOP2"
    expect_exit "w3 non-increasing seq refused (existing 9, new path, --seq $s)" 1
    expect_grepf "w3 --seq $s: says why" "not newer" "$ERR"
    expect_true "w3 --seq $s: file unchanged" cmp -s "$T/w3.json" "$PF"
    expect_eq "w3 --seq $s: stdout empty" "" "$(cat "$OUT")"
done
run_cmd w3ok -- pointer --host neptun --seq 10 --rev x --file "$PF" "$TOP2"
expect_eq "w3 --seq 10 > 9 -> changed=true" "changed=true" "$(cat "$OUT")"
expect_eq "w3 --seq 10 -> storePath is the new path" "$TOP2" "$(jq -r .storePath "$PF")"

cp "$PF" "$T/w4.json"
for bad in "$FX_STORE"/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-mars-1 /tmp/x \
    "$FX_STORE"/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-nixos-system-neptun-1 \
    "$FX_STORE/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-neptun-1 x" \
    "$FX_STORE"/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-neptun-1/bin \
    /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-neptun-1; do
    run_cmd w4 -- pointer --host neptun --seq 20 --rev x --file "$PF" "$bad"
    expect_exit "w4 TOP '$bad' refused" 1
    expect_true "w4 TOP '$bad': file unchanged" cmp -s "$T/w4.json" "$PF"
done
for bad in 0 -1 1.0 1e3 01 abc 12345678901 ''; do
    run_cmd w4s -- pointer --host neptun --seq "$bad" --rev x --file "$PF" "$TOP"
    expect_exit "w4 --seq '$bad' refused" 1
done
expect_true "w4 bad seqs: file unchanged" cmp -s "$T/w4.json" "$PF"
MARS=$FX_STORE/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos-system-mars-1
make_sys "$MARS"
run_cmd w4h -- pointer --host mars --seq 1 --rev x --file "$T/mars/p.json" "$MARS"
expect_eq "w4 --host mars accepts a mars toplevel" "changed=true" "$(cat "$OUT")"
run_cmd w4i -- pointer --host 'nep.*' --seq 1 --rev x --file "$T/mars/q.json" "$TOP"
expect_exit "w4 --host must be a plain name" 1

reset_log
MOCK_NSQ_RC=1 run_cmd w5f -- pointer --host neptun --seq 30 --rev x --file "$T/w5f/p.json" "$TOP"
expect_true "w5 narHash query failure -> non-zero" test "$RC" -ne 0
expect_true "w5 narHash query failure -> no file" test ! -e "$T/w5f/p.json"

printf 'not json\n' >"$T/w9.json"
run_cmd w9 -- pointer --host neptun --seq 30 --rev x --file "$T/w9.json" "$TOP"
expect_exit "w9 an existing invalid pointer is not overwritten" 1
expect_eq "w9 file unchanged" "not json" "$(cat "$T/w9.json")"

# w6 (A4): the pointer on origin/main counts too (a stale checkout or a re-run
# of an older run must not move the pointer backwards).
clone o
put_pointer "$T/o/deploy/neptun.json" 12 "$TOP"
git -C "$T/o" add -A && git -C "$T/o" commit -q -m "pointer 12" && git -C "$T/o" push -q origin main
clone q
QF="$T/q/deploy/neptun.json"
put_pointer "$QF" 5 "$TOP"
git -C "$T/q" fetch -q origin
cp "$QF" "$T/w6.json"
run_cmd w6 -- pointer --host neptun --seq 10 --rev x --file "$QF" "$TOP2"
expect_exit "w6 origin/main has seq 12 -> --seq 10 refused" 1
expect_grepf "w6 names origin/main" "origin/main" "$ERR"
expect_true "w6 file unchanged" cmp -s "$T/w6.json" "$QF"
run_cmd w6ok -- pointer --host neptun --seq 13 --rev x --file "$QF" "$TOP2"
expect_eq "w6 --seq 13 > 12 -> changed=true" "changed=true" "$(cat "$OUT")"
expect_eq "w6 --seq 13 written" 13 "$(jq -r .seq "$QF")"
cp "$QF" "$T/w6c.json"
run_cmd w6c -- pointer --host neptun --seq 14 --rev x --file "$QF" "$TOP"
expect_eq "w6 origin/main already points at TOP -> changed=false" "changed=false" "$(cat "$OUT")"
expect_true "w6 origin/main already points at TOP -> file unchanged" cmp -s "$T/w6c.json" "$QF"

# w11 (final review N7, README, "Recovery and rollback"): the run_number-reset recovery. A
# reset counter (seq 2) is refused while origin/main has seq 12; after the
# pointer is removed from main and fetched, seq 2 is written.
clone w11
WF="$T/w11/deploy/neptun.json"
run_cmd w11a -- pointer --host neptun --seq 2 --rev x --file "$WF" "$TOP2"
expect_exit "w11 reset run_number (2 < 12 on origin/main) refused" 1
git -C "$T/w11" rm -q deploy/neptun.json
git -C "$T/w11" commit -q -m "drop pointer" && git -C "$T/w11" push -q origin main
run_cmd w11b -- pointer --host neptun --seq 2 --rev x --file "$WF" "$TOP2"
expect_exit "w11 pointer removed from main -> seq 2 written" 0
expect_eq "w11 seq 2 in the file" 2 "$(jq -r .seq "$WF")"
# restore origin/main's pointer 12 for the later tests
git -C "$T/o" pull -q --rebase origin main
put_pointer "$T/o/deploy/neptun.json" 12 "$TOP"
git -C "$T/o" add -A && git -C "$T/o" commit -q -m "pointer 12 again" && git -C "$T/o" push -q origin main

# w8: outside a git repo (pull-smoke writes its pointer into a web root).
run_cmd w8 -- pointer --host neptun --seq 1 --rev smoke --file "$T/www/neptun.json" "$TOP"
expect_exit "w8 no git repo -> written" 0
expect_eq "w8 stdout" "changed=true" "$(cat "$OUT")"

run_cmd w10 -- pointer --host neptun --seq 1 --file "$T/w10.json" "$TOP"
expect_exit "w10 missing --rev -> usage" 2
run_cmd w10b -- pointer --host neptun --seq 1 --rev x "$TOP"
expect_exit "w10 missing --file -> usage" 2
run_cmd w10c -- pointer --host neptun --seq 1 --rev x --file "$T/w10.json"
expect_exit "w10 missing TOP -> usage" 2
run_cmd w10h -- pointer --help
expect_exit "w10 --help" 0

# pt3: --host is required (the pointer file and the toplevel are per host)
run_cmd pt3 -- pointer --seq 1 --rev x --file "$T/pt3/neptun.json" "$TOP"
expect_exit "pt3 no --host -> usage" 2
expect_grepf "pt3 says --host is missing" "--host" "$ERR"
expect_true "pt3 no file written" test ! -e "$T/pt3/neptun.json"

# pt4 ("host attribute name != hostname"): the workflow-style call keyed on
# system.name (build's name=), relative to the checkout.
GARDEN=$FX_STORE/dddddddddddddddddddddddddddddddd-nixos-system-garden-26.05.20261029.0123456
make_sys "$GARDEN"
clone pt4
cd "$T/pt4" || exit 1
run_cmd pt4 -- pointer --host garden --seq 31 --rev x --file deploy/garden.json "$GARDEN"
cd - >/dev/null || exit 1
expect_exit "pt4 --host garden" 0
expect_eq "pt4 writes deploy/garden.json of the checkout" "$GARDEN" \
    "$(jq -r .storePath "$T/pt4/deploy/garden.json" 2>&1)"
run_cmd pt4n -- pointer --host garden --seq 32 --rev x --file "$T/pt4/deploy/garden.json" "$TOP"
expect_exit "pt4 --host garden refuses a neptun toplevel" 1

# pt2 (D18): the step summary says whether the Pi switches or reboots, by
# comparing bootFp with the previous pointer's (origin/main's copy, else the
# file); only under GitHub Actions.
SUM="$T/pt2-summary.md"
ghp() { GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$SUM" pointer "$@"; }
: >"$SUM"
run_cmd pt2a -- ghp --host neptun --seq 1 --rev x --file "$T/pt2/neptun.json" "$TOP"
expect_exit "pt2 first pointer" 0
expect_grepf "pt2 summary section names the host" "## neptun: pointer" "$SUM"
expect_grepf "pt2 summary names file, seq and TOP" "$T/pt2/neptun.json: seq 1 → \`$TOP\`" "$SUM"
expect_grepf "pt2 no previous pointer -> unknown" "boot: unknown (no previous pointer)" "$SUM"
: >"$SUM"
run_cmd pt2b -- ghp --host neptun --seq 2 --rev x --file "$T/pt2/neptun.json" "$TOP3"
expect_grepf "pt2 same bootFp -> the Pi switches" "boot: unchanged → the Pi switches" "$SUM"
: >"$SUM"
run_cmd pt2c -- ghp --host neptun --seq 3 --rev x --file "$T/pt2/neptun.json" "$TOP2"
expect_grepf "pt2 other bootFp -> the Pi reboots" \
    "boot: changed → the Pi reboots at rpi.pull.rebootTime" "$SUM"
: >"$SUM"
run_cmd pt2d -- ghp --host neptun --seq 3 --rev x --file "$T/pt2/neptun.json" "$TOP2"
expect_eq "pt2 same TOP -> changed=false" "changed=false" "$(cat "$OUT")"
expect_grepf "pt2 same TOP -> summary says unchanged" "already points at" "$SUM"
# origin/main's copy (what the Pi reads) wins over the work tree's file:
# origin/main has seq 12 without bootFp (an older CI's pointer).
clone pt2e
run_cmd pt2e0 -- pointer --host neptun --seq 13 --rev x --file "$T/pt2e/deploy/neptun.json" "$TOP2"
: >"$SUM"
run_cmd pt2e -- ghp --host neptun --seq 14 --rev x --file "$T/pt2e/deploy/neptun.json" "$TOP3"
expect_exit "pt2 previous pointer without bootFp" 0
expect_grepf "pt2 previous pointer without bootFp -> unknown" \
    "boot: unknown (the previous pointer has no bootFp)" "$SUM"
: >"$SUM"
run_cmd pt2f -- pointer --host neptun --seq 15 --rev x --file "$T/pt2/neptun.json" "$TOP"
expect_eq "pt2 outside GitHub Actions: no summary" "" "$(cat "$SUM")"
TOP="$TOP0"

# =============================================================================
# T7.4 ci/commit-push.sh (real git, bare origin)
# =============================================================================
BOT='github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>'
MSG='neptun: build 7 (push)'
origin_main() { git -C "$T/origin.git" rev-parse main; }
# cpush REPO ARGS...: run commit-push.sh in REPO like the workflow does
cpush() { local r="$1"; shift; (cd "$T/$r" && bash "$CI_DIR/commit-push.sh" "$@"); }
# change REPO: a lock update and a new pointer in REPO's work tree
change() {
    printf 'update %s\n' "$1" >>"$T/$1/flake.lock"
    put_pointer "$T/$1/deploy/neptun.json" 7 "$TOP"
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
printf 'stray\n' >"$T/g2/stray.txt"
run_cmd g2 -- cpush g2 --message "$MSG" flake.lock deploy/neptun.json nope.json
expect_exit "g2 lock + pointer changed" 0
expect_eq "g2 stdout is pushed=true" "pushed=true" "$(cat "$OUT")"
expect_eq "g2 one new commit on origin main" "$before" "$(git -C "$T/origin.git" rev-parse main^)"
expect_eq "g2 the commit touches exactly lock + pointer" \
    "deploy/neptun.json flake.lock" \
    "$(git -C "$T/origin.git" diff-tree --no-commit-id --name-only -r main | sort | xargs)"
expect_eq "g2 author is github-actions[bot]" "$BOT" "$(git -C "$T/origin.git" log -1 --format='%an <%ae>' main)"
expect_eq "g2 committer is github-actions[bot]" "$BOT" "$(git -C "$T/origin.git" log -1 --format='%cn <%ce>' main)"
expect_eq "g2 message" "$MSG" "$(git -C "$T/origin.git" log -1 --format=%s main)"
expect_eq "g2 the work tree pointer is what origin has" "$(cat "$T/g2/deploy/neptun.json")" \
    "$(git -C "$T/origin.git" show main:deploy/neptun.json)"

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
    "$(git -C "$T/origin.git" show main:deploy/neptun.json | jq -r .seq)"

clone g4
change g4
other g4o flake.lock
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
    -u GIT_COMMITTER_EMAIL -u EMAIL bash -c 'cd "$1" && bash "$2/commit-push.sh" "${@:3}"' _ \
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

# T4.5 commit --artifacts DIR: the commit job's download-artifact directory,
# one subdirectory per build job (pi-HOST) with its flake.lock and, when
# published, deploy/NAME.json; one commit of the lock and all pointers (D14).
# art DIR LOCK [NAME...]: an artifact DIR with lock text LOCK (- = none)
# and a pointer deploy/NAME.json per NAME
art() {
    local d="$1" lock="$2" n
    shift 2
    mkdir -p "$d"
    [[ "$lock" == - ]] || printf '%s\n' "$lock" >"$d/flake.lock"
    for n in "$@"; do put_pointer "$d/deploy/$n.json" 40 "$TOP"; done
}
changed_files() { git -C "$T/origin.git" diff-tree --no-commit-id --name-only -r main | sort | xargs; }

clone k1
L0="$(cat "$T/k1/flake.lock")" L1="$(cat "$T/k1/flake.lock")"$'\nupdate k1'
art "$T/k1-art/pi-a" "$L1" a
art "$T/k1-art/pi-b" "$L1" b
before="$(origin_main)" SUM="$T/k1-summary.md"
GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$SUM" \
    run_cmd k1 -- cpush k1 --artifacts "$T/k1-art" --message "$MSG"
expect_exit "k1 two artifacts, same updated lock" 0
expect_eq "k1 stdout is pushed=true" "pushed=true" "$(cat "$OUT")"
expect_eq "k1 one new commit on origin main" "$before" "$(git -C "$T/origin.git" rev-parse main^)"
expect_eq "k1 the commit changes exactly both pointers + the lock" \
    "deploy/a.json deploy/b.json flake.lock" "$(changed_files)"
expect_eq "k1 origin has the artifacts' lock" "$L1" "$(git -C "$T/origin.git" show main:flake.lock)"
expect_eq "k1 origin has pointer a" "$(cat "$T/k1-art/pi-a/deploy/a.json")" \
    "$(git -C "$T/origin.git" show main:deploy/a.json)"
expect_eq "k1 message" "$MSG" "$(git -C "$T/origin.git" log -1 --format=%s main)"
expect_grepf "k1 summary section" "## commit" "$SUM"
expect_grepf "k1 summary names the pushed files" "deploy/a.json" "$SUM"

clone k1b
art "$T/k1b-art/pi-c" "$L1" c
art "$T/k1b-art/pi-d" "$L1"
run_cmd k1b -- cpush k1b --artifacts "$T/k1b-art" --message "$MSG"
expect_exit "k1b lock as on main" 0
expect_eq "k1b the commit changes only the pointer" "deploy/c.json" "$(changed_files)"

clone k2
art "$T/k2-art/pi-a" "$L1" k2a
art "$T/k2-art/pi-b" "$L0"$'\nupdate other' k2b
before="$(origin_main)"
run_cmd k2 -- cpush k2 --artifacts "$T/k2-art" --message "$MSG"
expect_exit "k2 locks differ between hosts -> 1" 1
expect_grepf "k2 says the lock differs between hosts" "lock differs between hosts" "$ERR"
expect_eq "k2 stdout empty" "" "$(cat "$OUT")"
expect_eq "k2 origin unchanged" "$before" "$(origin_main)"
expect_eq "k2 work tree untouched" "" "$(git -C "$T/k2" status --porcelain)"

clone k3
mkdir -p "$T/k3-art"
before="$(origin_main)"
run_cmd k3 -- cpush k3 --artifacts "$T/k3-art" --message "$MSG"
expect_exit "k3 empty artifacts dir" 0
expect_eq "k3 stdout is pushed=false" "pushed=false" "$(cat "$OUT")"
expect_eq "k3 origin unchanged" "$before" "$(origin_main)"
run_cmd k3m -- cpush k3 --artifacts "$T/k3-missing" --message "$MSG"
expect_exit "k3 missing artifacts dir -> 1" 1

clone k4
art "$T/k4-art/pi-e" "$L0"$'\nupdate k4'
run_cmd k4 -- cpush k4 --artifacts "$T/k4-art" --message "$MSG"
expect_exit "k4 lock-only artifact (no cache, updated lock)" 0
expect_eq "k4 stdout is pushed=true" "pushed=true" "$(cat "$OUT")"
expect_eq "k4 the commit changes only the lock" "flake.lock" "$(changed_files)"

clone k5
art "$T/k5-art/pi-a" "$L0" a
art "$T/k5-art/pi-b" "$L0" a
before="$(origin_main)"
run_cmd k5 -- cpush k5 --artifacts "$T/k5-art" --message "$MSG"
expect_exit "k5 one pointer name in two artifacts -> 1" 1
expect_grepf "k5 names the pointer" "deploy/a.json" "$ERR"
expect_eq "k5 origin unchanged" "$before" "$(origin_main)"
rm -rf "$T/k5-art/pi-b"
art "$T/k5-art/pi-b" "$L0"
put_pointer "$T/k5-art/pi-b/deploy/a b.json" 40 "$TOP"
run_cmd k5b -- cpush k5 --artifacts "$T/k5-art" --message "$MSG"
expect_exit "k5 a pointer that is not deploy/NAME.json -> 1" 1
expect_eq "k5 origin still unchanged" "$before" "$(origin_main)"
run_cmd k6 -- cpush k5 --message "$MSG"
expect_exit "k6 neither --artifacts nor PATH -> usage" 2

# k7: one build job (one host) → one artifact, and download-artifact
# extracts a lone artifact straight into its path, without the pi-HOST
# subdirectory (actions/download-artifact v8: `artifacts.length === 1`).
clone k7
art "$T/k7-art" "$L1" k7a
before="$(origin_main)"
run_cmd k7 -- cpush k7 --artifacts "$T/k7-art" --message "$MSG"
expect_exit "k7 one artifact extracted without a subdirectory" 0
expect_eq "k7 stdout is pushed=true" "pushed=true" "$(cat "$OUT")"
expect_eq "k7 one new commit on origin main" "$before" "$(git -C "$T/origin.git" rev-parse main^)"
expect_eq "k7 the commit changes the pointer + the lock" \
    "deploy/k7a.json flake.lock" "$(changed_files)"
clone k7b
art "$T/k7b-art" - k7b
run_cmd k7b -- cpush k7b --artifacts "$T/k7b-art" --message "$MSG"
expect_exit "k7b a lone artifact without a lock" 0
expect_eq "k7b the commit changes the pointer" "deploy/k7b.json" "$(changed_files)"

# =============================================================================
# ci/gh.sh (annotations, groups, step summary; only under GitHub Actions)
# =============================================================================
# ghx ENV... -- CODE: run CODE in bash with ci/gh.sh sourced, under env ENV
# (GITHUB_ACTIONS unset unless ENV sets it)
ghx() {
    local -a envs=()
    while [[ "$1" != -- ]]; do envs+=("$1"); shift; done
    shift
    env -u GITHUB_ACTIONS "${envs[@]}" bash -c 'source "$1"; eval "$2"' _ "$CI_DIR/gh.sh" "$1"
}
GH_ALL='gh_notice m; gh_warning w; gh_error e f 3; gh_group t; echo inside; gh_endgroup; gh_summary <<<"x"'

SUM="$T/gh1-summary.md"
run_cmd gh1 -- ghx GITHUB_STEP_SUMMARY="$SUM" -- "$GH_ALL"
expect_exit "gh1 helpers succeed outside GitHub Actions" 0
expect_eq "gh1 no :: lines outside GitHub Actions" 0 "$(grep -c '^::' "$ALL")"
expect_true "gh1 no step summary outside GitHub Actions" test ! -e "$SUM"
expect_grep "gh1 notice -> 'rpi-ci: notice: m' on stderr" '^rpi-ci: notice: m$' "$ERR"
expect_grep "gh1 warning -> 'rpi-ci: warning: w' on stderr" '^rpi-ci: warning: w$' "$ERR"
expect_grep "gh1 error -> 'rpi-ci: error: f:3: e' on stderr" '^rpi-ci: error: f:3: e$' "$ERR"
expect_eq "gh1 stdout has only the command's own output" inside "$(cat "$OUT")"
run_cmd gh1f -- ghx GITHUB_ACTIONS=false GITHUB_STEP_SUMMARY="$SUM" -- "$GH_ALL"
expect_eq "gh1 GITHUB_ACTIONS=false: no :: lines" 0 "$(grep -c '^::' "$ALL")"
expect_true "gh1 GITHUB_ACTIONS=false: no step summary" test ! -e "$SUM"

run_cmd gh2 -- ghx GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$SUM" -- "$GH_ALL"
expect_exit "gh2 helpers succeed under GitHub Actions" 0
expect_eq "gh2 annotations and groups on stderr, in order" \
    "::notice::m ::warning::w ::error file=f,line=3::e ::group::t ::endgroup::" "$(xargs <"$ERR")"
expect_eq "gh2 stdout has only the command's own output" inside "$(cat "$OUT")"
expect_eq "gh2 gh_summary appends stdin to \$GITHUB_STEP_SUMMARY" x "$(cat "$SUM")"
run_cmd gh2a -- ghx GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$SUM" -- 'gh_summary <<<"y"; gh_error e2'
expect_eq "gh2 gh_summary appends (keeps earlier sections)" $'x\ny' "$(cat "$SUM")"
expect_eq "gh2 gh_error without FILE" "::error::e2" "$(cat "$ERR")"
run_cmd gh2u -- ghx GITHUB_ACTIONS=true -- 'gh_summary <<<"z"'
expect_exit "gh2 no \$GITHUB_STEP_SUMMARY -> gh_summary does nothing" 0

run_cmd gh3 -- ghx GITHUB_ACTIONS=true -- $'gh_notice "100% a\r\nb"; gh_error "x" "a,b:c" 7'
expect_eq "gh3 escaping of %, CR and LF in messages" "::notice::100%25 a%0D%0Ab" "$(head -n1 "$ERR")"
expect_eq "gh3 escaping of , and : in properties" "::error file=a%2Cb%3Ac,line=7::x" "$(sed -n 2p "$ERR")"
expect_eq "gh3 one line per annotation" 2 "$(wc -l <"$ERR")"

# =============================================================================
# ci/rpi-ci.sh (dispatcher), ci/hosts.sh
# =============================================================================
run_cmd r1 -- bash "$CI_DIR/rpi-ci.sh" --help
expect_exit "r1 --help" 0
for c in hosts build publish pointer commit; do
    expect_grep "r1 --help lists $c" "^  $c " "$OUT"
done
expect_not_grep "r1 --help no longer lists cache-name" "cache-name" "$OUT"

run_cmd r2 -- bash "$CI_DIR/rpi-ci.sh" frobnicate
expect_exit "r2 unknown subcommand -> exit 2" 2
expect_grepf "r2 names the unknown subcommand" "unknown command 'frobnicate'" "$ERR"
run_cmd r2c -- bash "$CI_DIR/rpi-ci.sh" cache-name
expect_exit "r2 cache-name is gone (the cache is per host: rpi.pull.cache) -> exit 2" 2
run_cmd r2n -- bash "$CI_DIR/rpi-ci.sh"
expect_exit "r2 no subcommand -> exit 2" 2
expect_grepf "r2 no subcommand -> usage on stderr" "usage:" "$ERR"

reset_log
MOCK_HOSTS='["neptun"]' run_cmd r3 -- bash "$CI_DIR/rpi-ci.sh" hosts --flake "$T/b"
expect_exit "r3 hosts -> exit 0" 0
expect_eq "r3 hosts= is a JSON array" 'hosts=["neptun"]' "$(cat "$OUT")"
expect_eq "r3 hosts are discovered in --flake DIR" 1 \
    "$(log_count "^nix eval --accept-flake-config --json $T/b#nixosConfigurations --apply ")"
MOCK_HOSTS='["b","a"]' run_cmd r3s -- bash "$CI_DIR/rpi-ci.sh" hosts --flake "$T/b"
expect_eq "r3 several hosts, sorted" 'hosts=["a","b"]' "$(cat "$OUT")"
MOCK_HOSTS_RC=1 run_cmd r3e -- bash "$CI_DIR/rpi-ci.sh" hosts --flake "$T/b"
expect_true "r3 eval error -> exit != 0" test "$RC" -ne 0
expect_not_grep "r3 eval error -> no hosts= line" "hosts=" "$OUT"
expect_grepf "r3 eval error is passed through" "error: hosts eval failed" "$ERR"

MOCK_HOSTS='[]' run_cmd r4 -- bash "$CI_DIR/rpi-ci.sh" hosts --flake "$T/b"
expect_exit "r4 no Pi host -> exit 0" 0
expect_eq "r4 no Pi host -> hosts=[]" 'hosts=[]' "$(cat "$OUT")"
# hs1: nothing to build is not an error, but says so (the build job is skipped)
expect_exit "hs1 no Pi host -> exit 0" 0
expect_grepf "hs1 no Pi host -> notice" \
    "rpi-ci: notice: no Pi hosts (lib.mkPi) in nixosConfigurations" "$ERR"
MOCK_HOSTS='[]' GITHUB_ACTIONS=true run_cmd hs1g -- bash "$CI_DIR/rpi-ci.sh" hosts --flake "$T/b"
expect_grepf "hs1 under GitHub Actions -> ::notice::" \
    "::notice::no Pi hosts (lib.mkPi) in nixosConfigurations" "$ERR"
expect_eq "hs1 under GitHub Actions: stdout is only hosts=[]" 'hosts=[]' "$(cat "$OUT")"
MOCK_HOSTS='["neptun"]' run_cmd hs1n -- bash "$CI_DIR/rpi-ci.sh" hosts --flake "$T/b"
expect_not_grep "hs1 hosts -> no notice" "notice" "$ERR"
run_cmd r4h -- bash "$CI_DIR/hosts.sh" --help
expect_exit "r4 hosts --help" 0
run_cmd r4u -- bash "$CI_DIR/hosts.sh" --frob
expect_exit "r4 hosts unknown argument -> usage" 2

# r5: the dispatcher execs the script next to it with the arguments as
# given; a copy of rpi-ci.sh next to stubs that log "<script> <arg>..."
mkdir -p "$T/rci"
cp "$CI_DIR/rpi-ci.sh" "$T/rci/"
for s in hosts build publish pointer commit-push; do
    printf 'printf "%%s" "%s.sh" >>"$MOCK_LOG"; printf " <%%s>" "$@" >>"$MOCK_LOG"; echo >>"$MOCK_LOG"; exit "${STUB_RC:-0}"\n' \
        "$s" >"$T/rci/$s.sh"
done
reset_log
run_cmd r5 -- bash "$T/rci/rpi-ci.sh" build --x
expect_exit "r5 build -> exit 0" 0
expect_eq "r5 build --x execs build.sh --x" "build.sh <--x>" "$(cat "$MOCK_LOG")"
for m in hosts:hosts publish:publish pointer:pointer commit:commit-push; do
    reset_log
    run_cmd "r5 ${m%%:*}" -- bash "$T/rci/rpi-ci.sh" "${m%%:*}" --message "a b" ''
    expect_eq "r5 ${m%%:*} execs ${m#*:}.sh with its arguments" "${m#*:}.sh <--message> <a b> <>" "$(cat "$MOCK_LOG")"
done
STUB_RC=3 run_cmd r5rc -- bash "$T/rci/rpi-ci.sh" publish
expect_exit "r5 the script's exit code is rpi-ci's" 3

# r6: without --flake every CI script works on the working directory
# (formerly the flake next to ci/; the tests above pass --flake or cd).
clone r6
reset_log
MOCK_HOSTS='[]' run_cmd r6h -- bash -c 'cd "$1" && bash "$2/rpi-ci.sh" hosts' _ "$T/r6" "$CI_DIR"
expect_eq "r6 hosts without --flake uses \$PWD" 1 \
    "$(log_count "^nix eval --accept-flake-config --json $T/r6#nixosConfigurations --apply ")"
reset_log
MOCK_DRY="$HYB" run_cmd r6b -- bash -c 'cd "$1" && bash "$2/build.sh" --host neptun --event push' _ "$T/r6" "$CI_DIR"
expect_exit "r6 build without --flake -> exit 0" 0
expect_eq "r6 build without --flake uses \$PWD" 1 \
    "$(log_count "^nix build .*--print-out-paths $T/r6#nixosConfigurations\.neptun\.config\.system\.build\.toplevel\$")"

summary
