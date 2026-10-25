#!/usr/bin/env bash
#
# Unit tests for rpi-lib.sh's host discovery (check `rpi-lib-unit`):
# rl_hosts and rl_host_info.
#
#   RPI_LIB=rpi-lib.sh bash tests/lib-unit.sh
#
# (RPI_LIB defaults to the file next to this test). nix is a mock
# (tests/harness.sh) that logs its argv, prints $MOCK_NIX_OUT on stdout and
# $MOCK_NIX_ERR on stderr, and exits $MOCK_NIX_RC.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RPI_LIB="${RPI_LIB:-$HERE/../rpi-lib.sh}"

# shellcheck source=tests/harness.sh
source "$HERE/harness.sh"

mock nix <<'EOF'
[ -z "${MOCK_NIX_ERR:-}" ] || printf '%s\n' "$MOCK_NIX_ERR" >&2
[ -z "${MOCK_NIX_OUT:-}" ] || printf '%s\n' "$MOCK_NIX_OUT"
exit "${MOCK_NIX_RC:-0}"
EOF

# lib FN ARGS...: run FN from a freshly sourced rpi-lib.sh
lib() { bash -c 'source "$RPI_LIB" && "$@"' lib "$@"; }

# --- lh1: rl_hosts lists the rpiHost-marked configurations, sorted
reset_log
MOCK_NIX_OUT='["b","a"]' run_cmd lh1 -- lib rl_hosts F
expect_exit "lh1 rl_hosts -> exit 0" 0
expect_eq "lh1 one host per line, sorted" $'a\nb' "$(cat "$OUT")"
expect_eq "lh1 one nix call" 1 "$(log_count '^nix ')"
expect_grep "lh1 nix eval --json of F#nixosConfigurations" \
    '^nix eval --accept-flake-config --json F#nixosConfigurations --apply ' "$MOCK_LOG"
expect_grepf "lh1 filtered on rpiHost or false" "rpiHost or false" "$MOCK_LOG"

reset_log
MOCK_NIX_OUT='[]' run_cmd lh1b -- lib rl_hosts F
expect_exit "lh1 no Pi host -> exit 0" 0
expect_eq "lh1 no Pi host -> no output" "" "$(cat "$OUT")"

# --- lh2: an evaluation error is passed through
reset_log
MOCK_NIX_RC=1 MOCK_NIX_ERR="error: attribute 'boom' missing" run_cmd lh2 -- lib rl_hosts F
expect_true "lh2 eval error -> exit != 0" test "$RC" -ne 0
expect_grepf "lh2 nix's stderr passed through" "error: attribute 'boom' missing" "$ERR"
expect_eq "lh2 nothing on stdout" "" "$(cat "$OUT")"

# --- lh3: rl_host_info prints the host's info JSON
INFO='{"name":"neptun","target":"root@neptun","port":2222,"cache":null,"wifi":{"enable":false,"networks":{},"secretsFile":"/var/lib/rpi/wireless.env"}}'
reset_log
MOCK_NIX_OUT=$INFO run_cmd lh3 -- lib rl_host_info F h1
expect_exit "lh3 rl_host_info -> exit 0" 0
expect_eq "lh3 stdout is nix's JSON" "$INFO" "$(cat "$OUT")"
expect_grep "lh3 nix eval --json of F#nixosConfigurations.h1" \
    '^nix eval --accept-flake-config --json F#nixosConfigurations\.h1 --apply ' "$MOCK_LOG"
for a in system.name rpi.deploy.target rpi.ssh.port rpi.pull.cache rpi.wifi; do
    expect_grepf "lh3 info reads config.$a" "c.config.$a" "$MOCK_LOG"
done

reset_log
MOCK_NIX_RC=1 MOCK_NIX_ERR="error: no host h1" run_cmd lh3b -- lib rl_host_info F h1
expect_true "lh3 eval error -> exit != 0" test "$RC" -ne 0
expect_grepf "lh3 nix's stderr passed through" "error: no host h1" "$ERR"

# --- lh4: a host name that is not a plain attribute name is refused
for h in 'a.b' 'a b' '' 'x;y' $'a\nb'; do
    reset_log
    MOCK_NIX_OUT=$INFO run_cmd "lh4 '$h'" -- lib rl_host_info F "$h"
    if [[ "$RC" -eq 2 ]] && grep -qF "invalid host name" "$ERR" && [[ "$(log_count '^nix ')" -eq 0 ]]; then
        h_pass "lh4 invalid host name '$h' -> exit 2, no nix call"
    else
        h_fail "lh4 invalid host name -> exit 2, no nix call ('$h': exit $RC, $(log_count '^nix ') nix calls)"
    fi
done

summary
