# shellcheck shell=bash
#
# Tiny test harness for the bash unit tests (tests/deploy-unit.sh,
# tests/autoupdate-unit.sh). Source it; it has no arguments.
#
# Provides:
#   $T          temp dir (removed on exit)       $BIN  mock dir, first in PATH
#   $MOCK_LOG   every mock appends "NAME ARGS..." here
#   mock NAME <<'EOF' ... EOF   write the mock executable $BIN/NAME (body = stdin;
#               a log line is prepended automatically)
#   run_cmd NAME -- CMD...      run CMD; stdout -> $OUT, stderr -> $ERR,
#               both -> $ALL (stdout first), exit code -> $RC
#   expect_exit NAME RC         expect_grep NAME ERE [FILE]
#   expect_grepf NAME STR [FILE]  expect_not_grep NAME STR [FILE]
#   expect_eq NAME WANT GOT     expect_true NAME CMD...
#   log_count ERE               number of matching $MOCK_LOG lines
#   reset_log                   truncate $MOCK_LOG
#   summary                     "N passed, M failed"; exit 1 if M > 0 or N == 0
#
# FILE defaults to $ALL. Mocks get an absolute bash shebang: the nix build
# sandbox has no /usr/bin/env.

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
BIN="$T/bin"
mkdir -p "$BIN"
export PATH="$BIN:$PATH"
BASH_BIN="$(command -v bash)"

# Hermetic git: ignore user/system config (commit.gpgsign, hooks, ...).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost

export MOCK_LOG="$T/mock.log"
: >"$MOCK_LOG"
OUT="$T/out" ERR="$T/err" ALL="$T/all" RC=0 CUR_TEST=""
: >"$OUT"; : >"$ERR"; : >"$ALL"
H_PASS=0 H_FAIL=0

# Tests never read the terminal unless they redirect stdin explicitly.
exec </dev/null

mock() {
    local f="$BIN/$1"
    {
        printf '#!%s\n' "$BASH_BIN"
        printf 'printf "%%s\\n" "%s $*" >>"$MOCK_LOG"\n' "$1"
        cat
    } >"$f"
    chmod 755 "$f"
}

reset_log() { : >"$MOCK_LOG"; }

log_count() { grep -cE -- "$1" "$MOCK_LOG" || true; }

run_cmd() {
    CUR_TEST="$1"
    shift
    [[ "${1:-}" == -- ]] && shift
    "$@" >"$OUT" 2>"$ERR"
    RC=$?
    cat "$OUT" "$ERR" >"$ALL"
}

h_pass() { H_PASS=$((H_PASS + 1)); echo "PASS: $1"; }
h_fail() {
    H_FAIL=$((H_FAIL + 1))
    echo "FAIL: $1"
    {
        echo "  last run: ${CUR_TEST:-none} (exit $RC)"
        echo "  --- stdout"; head -n 20 "$OUT"
        echo "  --- stderr"; head -n 20 "$ERR"
        echo "  --- mock log"; head -n 20 "$MOCK_LOG"
    } | sed 's/^/    | /'
}

expect_exit() {
    if [[ "$RC" -eq "$2" ]]; then h_pass "$1"; else h_fail "$1 (expected exit $2, got $RC)"; fi
}

expect_grep() {
    if grep -qE -- "$2" "${3:-$ALL}" 2>/dev/null; then h_pass "$1"; else h_fail "$1 (no match for /$2/ in ${3:-\$ALL})"; fi
}

expect_grepf() {
    if grep -qF -- "$2" "${3:-$ALL}" 2>/dev/null; then h_pass "$1"; else h_fail "$1 ('$2' not found in ${3:-\$ALL})"; fi
}

expect_not_grep() {
    if ! grep -qF -- "$2" "${3:-$ALL}" 2>/dev/null; then h_pass "$1"; else h_fail "$1 ('$2' unexpectedly found in ${3:-\$ALL})"; fi
}

expect_eq() {
    if [[ "$2" == "$3" ]]; then h_pass "$1"; else h_fail "$1 (want '$2', got '$3')"; fi
}

expect_true() {
    local name="$1"
    shift
    if "$@"; then h_pass "$name"; else h_fail "$name"; fi
}

summary() {
    echo "$H_PASS passed, $H_FAIL failed"
    if [[ "$H_PASS" -eq 0 ]]; then
        echo "FAIL: no assertions ran"
        exit 1
    fi
    [[ "$H_FAIL" -eq 0 ]] || exit 1
}
