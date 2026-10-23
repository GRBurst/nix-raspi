#!/usr/bin/env bash
#
# Unit tests for rpi-pull.sh (check `rpi-pull-unit`).
#
#   RPI_PULL_SRC=rpi-pull.sh RPI_FP_LIB=rpi-fp.sh FIXTURES=tests/fixtures \
#     bash tests/pull-unit.sh
#
# (all three default to the files next to this test). curl, nix, nix-store,
# nix-env, shutdown and sync are mocks (tests/harness.sh); jq, flock and
# coreutils are real. The Pi's /run/{current,booted}-system and system
# profile live under $T/pi (RPI_PULL_ROOT); its store is the fake store
# $FX_STORE (RPI_PULL_STORE) with make_sys toplevels whose
# switch-to-configuration only logs "stc PATH ACTION".

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RPI_PULL_SRC="${RPI_PULL_SRC:-$HERE/../rpi-pull.sh}"
export RPI_FP_LIB="${RPI_FP_LIB:-$HERE/../rpi-fp.sh}"
FIXTURES="${FIXTURES:-$HERE/fixtures}"

# shellcheck source=tests/harness.sh
source "$HERE/harness.sh"

unset RL_STORE_DIR
export RPI_PULL_ROOT="$T/pi" RPI_PULL_STORE="$FX_STORE" STATE="$T/state"
KEY="neptun-test.cachix.org-1:$(printf 'neptun-pull-unit-test-key-00001!' | base64)"
export KEY
export GOOD_NAR="sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="
export MOCK_BODY="$T/pointer.json"
CACHE=https://neptun-test.cachix.org
H32=0123456789abcdfghijklmnpqrsvwxyz # 32 chars of nix's base32 alphabet

# The fake toplevels' switch-to-configuration wrapper runs $FX_STORE/fx-bash.
mkdir -p "$FX_STORE/fx-bash/bin"
ln -s "$BASH_BIN" "$FX_STORE/fx-bash/bin/bash"

# first_line ERE: line number of the first matching mock-log line (999999 if none)
first_line() { grep -nE -- "$1" "$MOCK_LOG" | head -n1 | cut -d: -f1 | grep . || echo 999999; }

# Every mock-log line of the whole file, for the file-wide p19.
ALL_LOG="$T/all-mocks.log"
: >"$ALL_LOG"

# psys NAME [PART=TAG...]: a fake toplevel $FX_STORE/<hash>-nixos-system-neptun-26.05.NAME
# (hash in nix's base32 alphabet; parts as in make_sys) whose
# switch-to-configuration logs "stc PATH ACTION" and exits $MOCK_STC_RC.
psys() {
    local name="$1" h p
    shift
    h=$(printf %s "$name" | sha256sum | cut -c1-32 | tr e g)
    p="$FX_STORE/$h-nixos-system-neptun-26.05.$name"
    make_sys "$p" "$@" || return 1
    {
        printf '#!%s\n' "$BASH_BIN"
        printf 'printf "%%s\\n" "stc $OUT $*" >>"$MOCK_LOG"\n'
        printf 'exit "${MOCK_STC_RC:-0}"\n'
    } >"$p/bin/.switch-to-configuration-wrapped"
    chmod 755 "$p/bin/.switch-to-configuration-wrapped"
    echo "$p"
}

# pi CURRENT BOOTED PROFILE: the Pi's /run/current-system, /run/booted-system
# and system profile links.
pi() {
    mkdir -p "$T/pi/run" "$T/pi/nix/var/nix/profiles"
    ln -sfn "$1" "$T/pi/run/current-system"
    ln -sfn "$2" "$T/pi/run/booted-system"
    ln -sfn "$3" "$T/pi/nix/var/nix/profiles/system"
}

# json_str S: S as a JSON string (escaped by jq)
json_str() { jq -n --arg s "$1" '$s'; }

# pointer SEQ PATH [NAR]: the served pointer; SEQ is raw JSON text ("-" omits
# the field), PATH and NAR are strings (NAR default $GOOD_NAR).
pointer() {
    local seq=""
    [[ "$1" != - ]] && seq="\"seq\": $1, "
    printf '{%s"storePath": %s, "narHash": %s, "rev": "0123abc"}\n' \
        "$seq" "$(json_str "$2")" "$(json_str "${3:-$GOOD_NAR}")" >"$MOCK_BODY"
}

# state SEQ: the applied seq in $STATE/seq
state() { mkdir -p "$STATE" && printf '%s\n' "$1" >"$STATE/seq"; }

# state_files: the file names in $STATE (but last-run), space-separated
state_files() {
    local f out=""
    for f in "$STATE"/*; do
        [[ "${f##*/}" == last-run ]] || out+="${out:+ }${f##*/}"
    done
    echo "$out"
}

# --- mocks -------------------------------------------------------------------

# curl: copies $MOCK_BODY to the -o file, prints ${MOCK_HTTP:-200} for -w,
# exits ${MOCK_CURL_RC:-0}.
mock curl <<'EOF'
prev="" out=""
for a in "$@"; do [[ "$prev" == -o ]] && out="$a"; prev="$a"; done
[[ -n "$out" ]] && cat "$MOCK_BODY" >"$out"
printf '%s' "${MOCK_HTTP:-200}"
exit "${MOCK_CURL_RC:-0}"
EOF

# nix: store verify (rc 0 iff the signer is ours and the argv trusts $KEY;
# else "untrusted" rc 2; MOCK_VERIFY_RC: another failure), hash convert
# (prints ${MOCK_NAR:-$GOOD_NAR}); anything else is logged only.
mock nix <<'EOF'
case " $* " in
*" store verify "*)
    if [[ -n "${MOCK_VERIFY_RC:-}" ]]; then echo "error: cannot reach the cache" >&2; exit "$MOCK_VERIFY_RC"; fi
    case " $* " in *" --trusted-public-keys $KEY "*) trusts_ours=1 ;; *) trusts_ours="" ;; esac
    [[ "${MOCK_SIGNER:-ours}" == ours && -n "$trusts_ours" ]] && exit 0
    echo "error: path '${!#}' is untrusted" >&2
    exit 2 ;;
*" hash convert "*) echo "${MOCK_NAR:-$GOOD_NAR}" ;;
esac
exit 0
EOF

# nix-store: --realise (rc ${MOCK_REALISE_RC:-0}), --query --hash (a sha256:
# hash; MOCK_QHASH_RC fails it).
mock nix-store <<'EOF'
case " $* " in
*" --realise "*) exit "${MOCK_REALISE_RC:-0}" ;;
*" --query --hash "*)
    [[ -n "${MOCK_QHASH_RC:-}" ]] && exit "$MOCK_QHASH_RC"
    echo "sha256:1b8m03r63zqhnjf7l5wnldhh7c134ap5vpj0850ymkq1iyzicy5s" ;;
esac
exit 0
EOF

# nix-env -p PROFILE --set PATH: points PROFILE at PATH (MOCK_NIXENV_RC fails it)
mock nix-env <<'EOF'
[[ -n "${MOCK_NIXENV_RC:-}" ]] && exit "$MOCK_NIXENV_RC"
prev="" profile="" target=""
for a in "$@"; do
    case "$prev" in -p) profile="$a" ;; --set) target="$a" ;; esac
    prev="$a"
done
ln -sfn "$target" "$profile"
EOF

mock shutdown <<'EOF'
exit "${MOCK_SHUTDOWN_RC:-0}"
EOF

# sync: also logs the applied seq at that moment (state is written after sync)
mock sync <<'EOF'
printf 'sync-state %s\n' "$(cat "$STATE/seq" 2>/dev/null || echo none)" >>"$MOCK_LOG"
EOF

# --- fixture -----------------------------------------------------------------

A=$(psys a)
NEXT=$(psys next)
H_NEXT=$(basename "$NEXT" | cut -c1-32)

# fresh: a new case: Pi on system A (current = booted = profile), no state,
# pointer seq 1 -> NEXT, every mock knob at its default.
fresh() {
    cat "$MOCK_LOG" >>"$ALL_LOG"
    reset_log
    rm -rf "$STATE"
    unset MOCK_HTTP MOCK_CURL_RC MOCK_SIGNER MOCK_VERIFY_RC MOCK_NAR MOCK_QHASH_RC \
        MOCK_REALISE_RC MOCK_NIXENV_RC MOCK_STC_RC MOCK_SHUTDOWN_RC
    pi "$A" "$A" "$A"
    pointer 1 "$NEXT"
}

# rp NAME [ARGS...]: run rpi-pull with the test's URLs, key and state dir
# (snapshots profile and state for `untouched`).
rp() {
    local name="$1"
    shift
    PROFILE_BEFORE=$(readlink "$T/pi/nix/var/nix/profiles/system")
    SEQ_BEFORE=$(cat "$STATE/seq" 2>/dev/null || echo none)
    run_cmd "$name" -- bash "$RPI_PULL_SRC" --pointer-url https://x/neptun.json \
        --cache-url "$CACHE" --cache-key "$KEY" --state-dir "$STATE" "$@"
}

# untouched NAME: P1 -- profile, activation and applied seq are as before the run
untouched() {
    expect_eq "$1: profile unchanged" "$PROFILE_BEFORE" "$(readlink "$T/pi/nix/var/nix/profiles/system")"
    expect_eq "$1: no nix-env, stc or shutdown" 0 "$(log_count '^(nix-env|stc|shutdown) ')"
    expect_eq "$1: applied seq unchanged" "$SEQ_BEFORE" "$(cat "$STATE/seq" 2>/dev/null || echo none)"
}

# --- 5.1 CLI, fetch, parse, validate -----------------------------------------

fresh
run_cmd p1 -- bash "$RPI_PULL_SRC" --help
expect_exit "p1 --help exits 0" 0
for o in --pointer-url --cache-url --cache-key; do
    expect_grepf "p1 usage names $o" "$o" "$OUT"
done

for missing in --pointer-url --cache-url --cache-key; do
    fresh
    args=(--pointer-url https://x/neptun.json --cache-url "$CACHE" --cache-key "$KEY" --state-dir "$STATE")
    for i in "${!args[@]}"; do
        [[ "${args[$i]:-}" == "$missing" ]] && unset "args[$i]" "args[$((i + 1))]"
    done
    run_cmd "p1 no $missing" -- bash "$RPI_PULL_SRC" "${args[@]}"
    expect_exit "p1 missing $missing -> 2" 2
    expect_eq "p1 missing $missing: nothing fetched" 0 "$(log_count '^curl ')"
done

fresh
rp p1-unknown --frobnicate
expect_exit "p1 unknown argument -> 2" 2
fresh
rp p1-novalue --host
expect_exit "p1 option without a value -> 2" 2

for host in 'nep.tune' 'a/b' '' 'x y' '(neptun|mars)' $'nep\ntune'; do
    fresh
    rp "p1 host '$host'" --host "$host"
    expect_exit "p1 --host '$host' refused -> 2" 2
    expect_eq "p1 --host '$host': nothing fetched" 0 "$(log_count '^curl ')"
done

fresh
MOCK_HTTP=404 rp p2
expect_exit "p2 HTTP 404 -> 0" 0
expect_grepf "p2 says no pointer published yet" "no pointer published yet" "$ERR"
expect_eq "p2 no nix calls" 0 "$(log_count '^nix')"

fresh
MOCK_CURL_RC=6 rp p3-curl
expect_exit "p3 curl error -> 30" 30
untouched "p3 curl error"
expect_eq "p3 curl error: no nix calls" 0 "$(log_count '^nix')"
expect_true "p3 no pointer temp file left" bash -c '! compgen -G "$STATE/pointer.*" >/dev/null'
expect_grep "p3 curl --max-time 60" '^curl .*--max-time 60( |$)' "$MOCK_LOG"
expect_grep "p3 curl --retry 3" '^curl .*--retry 3( |$)' "$MOCK_LOG"
expect_grep "p3 curl --proto-redir =https" '^curl .*--proto-redir =https( |$)' "$MOCK_LOG"
expect_grep "p3 curl --max-filesize 65536" '^curl .*--max-filesize 65536( |$)' "$MOCK_LOG"
expect_grep "p3 curl fetches the pointer URL" '^curl .* https://x/neptun\.json( |$)' "$MOCK_LOG"
fresh
MOCK_HTTP=500 rp p3-500
expect_exit "p3 HTTP 500 -> 30" 30
untouched "p3 HTTP 500"

fresh
printf 'not json\n' >"$MOCK_BODY"
rp p4
expect_exit "p4 invalid JSON -> 31" 31
untouched "p4 invalid JSON"
for body in 'null' '[1]' '"x"'; do
    fresh
    printf '%s\n' "$body" >"$MOCK_BODY"
    rp "p4 body $body"
    expect_exit "p4 body $body -> 31" 31
done

for seq in - '"5"' 0 -1 1.5 1.0 1e3 99999999999999999999 null; do
    fresh
    pointer "$seq" "$NEXT"
    rp "p5 seq $seq"
    expect_exit "p5 seq $seq -> 31" 31
    untouched "p5 seq $seq"
done

fresh
state 5
pointer 5 "$NEXT"
rp p6
expect_exit "p6 seq == applied -> 0" 0
expect_grepf "p6 says up to date" "up to date" "$ERR"
expect_eq "p6 no nix store verify" 0 "$(log_count '^nix .*store verify')"

fresh
state 5
pointer 4 "$NEXT"
rp p7
expect_exit "p7 older seq refused" 31
expect_grepf "p7 says older than applied" "older than applied" "$ERR"
untouched "p7 older seq"

for bad in abc '' 05 1.5; do
    fresh
    state "$bad"
    rp "p7 state seq '$bad'"
    expect_exit "p7 non-numeric state seq '$bad' -> 31" 31
    untouched "p7 state seq '$bad'"
done

for path in \
    "$FX_STORE/$H_NEXT-nixos-system-mars-26.05" \
    "$NEXT/../x" \
    "$NEXT/" \
    "/elsewhere/$H_NEXT-nixos-system-neptun-1" \
    "$FX_STORE/${H_NEXT:1}-nixos-system-neptun-1" \
    "$FX_STORE/${H_NEXT}a-nixos-system-neptun-1" \
    "$FX_STORE/$H_NEXT-hello-1.0" \
    "$FX_STORE/$H_NEXT-nixos-system-neptun-" \
    "$FX_STORE/${H32:0:31}e-nixos-system-neptun-1" \
    "$FX_STORE/${H32:0:31}o-nixos-system-neptun-1" \
    "$FX_STORE/${H32:0:31}t-nixos-system-neptun-1" \
    "$FX_STORE/${H32:0:31}u-nixos-system-neptun-1" \
    "$FX_STORE/${H32:0:31}A-nixos-system-neptun-1" \
    "$FX_STORE/$H_NEXT-nixos-system-neptun-26.05 x" \
    "$FX_STORE/$H_NEXT-nixos-system-neptun-26.05;reboot" \
    "$FX_STORE/$H_NEXT-nixos-system-neptun-26.05\$x" \
    "$FX_STORE/$H_NEXT-nixos-system-neptun-26.05$(printf '\033')x"; do
    fresh
    pointer 1 "$path"
    rp "p8 path $path"
    expect_exit "p8 storePath '$path' -> 31" 31
    untouched "p8 path $path"
done
fresh
printf '{"seq": 1, "storePath": 7, "narHash": "%s"}\n' "$GOOD_NAR" >"$MOCK_BODY"
rp p8-number
expect_exit "p8 storePath not a string -> 31" 31

# A newline inside a field must not shift the fields read after it.
fresh
pointer 1 "$NEXT"$'\n'"$GOOD_NAR" "$NEXT"
rp p8-newline
expect_exit "p8 control character in storePath -> 31" 31
untouched "p8 newline"

for nar in 'sha256:abc' "${GOOD_NAR%=}" "${GOOD_NAR:1}" "sha512-${GOOD_NAR#sha256-}" \
    "${GOOD_NAR%=}x=" "${GOOD_NAR} "; do
    fresh
    pointer 1 "$NEXT" "$nar"
    rp "p9 narHash $nar"
    expect_exit "p9 narHash '$nar' -> 31" 31
    untouched "p9 narHash $nar"
done

# --- 5.2 signature by our key only -------------------------------------------

fresh
MOCK_SIGNER=other rp p10
expect_exit "p10 signed by another key -> 32" 32
expect_grepf "p10 says untrusted" "untrusted" "$ERR"
untouched "p10 untrusted"
expect_grepf "p10 verify uses --trusted-public-keys only" \
    "nix --extra-experimental-features nix-command store verify --no-contents --store $CACHE --trusted-public-keys $KEY $NEXT" \
    "$MOCK_LOG"
expect_eq "p10 never --extra-trusted-public-keys" 0 "$(log_count 'extra-trusted-public-keys')"
expect_eq "p10 untrusted: nothing realised" 0 "$(log_count '^nix-store ')"

for rc in 1 4; do
    fresh
    MOCK_VERIFY_RC=$rc rp "p10 verify rc $rc"
    expect_exit "p10 verify rc $rc -> 38 (cache unavailable, not untrusted)" 38
    expect_grepf "p10 verify rc $rc says cache unavailable" "cache unavailable" "$ERR"
    untouched "p10 verify rc $rc"
    expect_eq "p10 verify rc $rc: nothing realised" 0 "$(log_count '^nix-store ')"
done

# --- 5.3 already current ------------------------------------------------------

fresh
pi "$NEXT" "$A" "$NEXT"
state 3
pointer 4 "$NEXT"
rp p11
expect_exit "p11 already current -> 0" 0
expect_grepf "p11 says already current" "already current" "$ERR"
expect_eq "p11 records the pointer seq" 4 "$(cat "$STATE/seq" 2>/dev/null)"
expect_eq "p11 records the store path" "$NEXT" "$(cat "$STATE/store-path" 2>/dev/null)"
expect_eq "p11 nothing realised, set or activated" 0 "$(log_count '^(nix-store --realise|nix-env|stc|shutdown) ')"
expect_eq "p11 no temp files left in the state dir" "lock seq store-path" "$(state_files)"

fresh
pi "$NEXT" "$A" "$NEXT"
MOCK_SIGNER=other rp p11-untrusted
expect_exit "p11 already current but untrusted -> 32 (verify first)" 32
expect_eq "p11 untrusted: nothing recorded" none "$(cat "$STATE/seq" 2>/dev/null || echo none)"

# --- 5.4 realise + narHash -----------------------------------------------------

fresh
MOCK_REALISE_RC=1 rp p12
expect_exit "p12 realise fails -> 33" 33
untouched "p12 realise fails"
expect_grepf "p12 realises with 2 substitution jobs" \
    "nix-store --realise $NEXT --option max-substitution-jobs 2" "$MOCK_LOG"
expect_true "p12 verify precedes the realise" \
    test "$(first_line ' store verify ')" -lt "$(first_line '^nix-store --realise ')"

fresh
MOCK_NAR="sha256-${GOOD_NAR:8}" rp p13
expect_exit "p13 narHash mismatch -> exit 34" 34
expect_grepf "p13 says narHash mismatch" "narHash mismatch" "$ERR"
untouched "p13 narHash mismatch"
expect_grepf "p13 converts the store's narHash to SRI" \
    "nix --extra-experimental-features nix-command hash convert --to sri sha256:1b8m03r63zqhnjf7l5wnldhh7c134ap5vpj0850ymkq1iyzicy5s" \
    "$MOCK_LOG"
expect_true "p13 hash read after the realise" \
    test "$(first_line '^nix-store --realise ')" -lt "$(first_line "^nix-store --query --hash $NEXT\$")"

fresh
MOCK_QHASH_RC=1 rp p13-query
expect_exit "p13 narHash unreadable -> 34" 34
untouched "p13 narHash unreadable"

# --- lock ------------------------------------------------------------------------

fresh
mkdir -p "$STATE"
exec 8>"$STATE/lock"
flock -n 8
rp p18
exec 8>&-
expect_exit "p18 lock held -> 37" 37
expect_eq "p18 nothing fetched" 0 "$(log_count '^curl ')"

fresh
: >"$T/not-a-dir"
run_cmd p18-statefile -- bash "$RPI_PULL_SRC" --pointer-url https://x/neptun.json \
    --cache-url "$CACHE" --cache-key "$KEY" --state-dir "$T/not-a-dir"
expect_exit "p18 state dir unusable -> 37" 37
expect_grepf "p18 state dir unusable: says why" "cannot open $T/not-a-dir/lock" "$ERR"
expect_eq "p18 state dir unusable: nothing fetched" 0 "$(log_count '^curl ')"

fresh
summary
