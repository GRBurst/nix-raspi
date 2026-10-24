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
    [[ ! -e "$p/bin/switch-to-configuration" ]] || chmod 755 "$p/bin/switch-to-configuration"
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

# ago SECONDS: the UTC time SECONDS ago, as the pointer's `built`
ago() { date -u -d "@$(($(date -u +%s) - $1))" +%Y-%m-%dT%H:%M:%SZ; }
DAY=86400

# pointer SEQ PATH [NAR [BUILT]]: the served pointer; SEQ and BUILT are raw
# JSON text ("-" omits the field), PATH and NAR are strings (NAR default
# $GOOD_NAR, BUILT default: now).
pointer() {
    local seq="" built="${4:-"\"$(ago 0)\""}"
    [[ "$1" != - ]] && seq="\"seq\": $1, "
    [[ "$built" != - ]] && built=", \"built\": $built" || built=""
    printf '{%s"storePath": %s, "narHash": %s, "rev": "0123abc"%s}\n' \
        "$seq" "$(json_str "$2")" "$(json_str "${3:-$GOOD_NAR}")" "$built" >"$MOCK_BODY"
}

# built_ago SECONDS: pointer seq 1 -> NEXT, built SECONDS ago
built_ago() { pointer 1 "$NEXT" "$GOOD_NAR" "\"$(ago "$1")\""; }

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

# nix:
# - store verify: rc 0 iff the signer is ours and the argv trusts $KEY, or
#   the path is content-addressed (MOCK_CA: like nix, a CA path needs no
#   signature); else "untrusted" rc 2; MOCK_VERIFY_RC: another failure.
# - path-info --store URL (the narinfo in the cache, --json-format 1):
#   ca ${MOCK_CA:-null}, narHash ${MOCK_INFO_NAR:-$GOOD_NAR}, signatures by
#   MOCK_SIGNER (ours (default) | forged (our key's name, not by our
#   key) | other | none); MOCK_ABSENT: not in the
#   cache (null); MOCK_PATHINFO_RC: another failure.
# - path-info without --store (the local store, after the realise): ca
#   ${MOCK_LOCAL_CA:-null}.
# - hash convert: prints ${MOCK_NAR:-$GOOD_NAR}.
# Anything else is logged only.
mock nix <<'EOF'
case " $* " in
*" store verify "*)
    if [[ -n "${MOCK_VERIFY_RC:-}" ]]; then echo "error: cannot reach the cache" >&2; exit "$MOCK_VERIFY_RC"; fi
    case " $* " in *" --trusted-public-keys $KEY "*) trusts_ours=1 ;; *) trusts_ours="" ;; esac
    [[ -n "${MOCK_CA:-}" ]] && exit 0
    [[ "${MOCK_SIGNER:-ours}" == ours && -n "$trusts_ours" ]] && exit 0
    echo "error: path '${!#}' is untrusted" >&2
    exit 2 ;;
*" path-info "*)
    p="${!#}"
    case " $* " in
    *" --store "*)
        if [[ -n "${MOCK_PATHINFO_RC:-}" ]]; then echo "error: cannot reach the cache" >&2; exit "$MOCK_PATHINFO_RC"; fi
        if [[ -n "${MOCK_ABSENT:-}" ]]; then jq -nc --arg p "$p" '{($p): null}'; exit 0; fi
        ca="${MOCK_CA:-}" nar="${MOCK_INFO_NAR:-$GOOD_NAR}"
        case "${MOCK_SIGNER:-ours}" in
        ours) sigs="[\"${KEY%%:*}:c2lnbmF0dXJlLW9mLW91cnM=\"]" ;;
        forged) sigs="[\"${KEY%%:*}:Zm9yZ2Vk\"]" ;;
        other) sigs='["other.cachix.org-1:c2lnbmF0dXJlLW9mLW90aGVy"]' ;;
        *) sigs='[]' ;;
        esac ;;
    *) ca="${MOCK_LOCAL_CA:-}" nar="$GOOD_NAR" sigs='[]' ;;
    esac
    jq -nc --arg p "$p" --arg ca "$ca" --arg nar "$nar" --argjson sigs "$sigs" \
        '{($p): {ca: (if $ca == "" then null else $ca end), narHash: $nar, narSize: 520,
            references: [], signatures: $sigs, storeDir: "/nix/store", version: 1}}' ;;
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
        MOCK_REALISE_RC MOCK_NIXENV_RC MOCK_STC_RC MOCK_SHUTDOWN_RC \
        MOCK_CA MOCK_INFO_NAR MOCK_ABSENT MOCK_PATHINFO_RC MOCK_LOCAL_CA
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
expect_grepf "p1 usage: exit 32 covers content-addressed" "content-addressed" "$OUT"

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

# A pointer that disappears after one was applied (repo private, renamed or
# deleted; pointer file removed) is a failure, not "nothing yet" (final
# review S3): the Pi would otherwise stop updating silently.
fresh
state 5
MOCK_HTTP=404 rp p2b
expect_exit "p2b HTTP 404 after seq 5 was applied -> 30" 30
expect_grepf "p2b says the pointer disappeared" "pointer disappeared (HTTP 404) after seq 5" "$ERR"
expect_not_grep "p2b not 'no pointer published yet'" "no pointer published yet" "$ERR"
untouched "p2b pointer disappeared"
expect_eq "p2b no nix calls" 0 "$(log_count '^nix')"

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
# README section 5 (final review N7): removing the bad seq is the recovery.
rp p7-again
expect_exit "p7 bad seq: the next run fails again" 31
rm "$STATE/seq"
rp p7-recovered
expect_exit "p7 bad seq removed -> applies like a fresh flash" 0
expect_eq "p7 bad seq removed: seq recorded" 1 "$(cat "$STATE/seq" 2>/dev/null)"

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
expect_eq "p10 untrusted: nothing realised" 0 "$(log_count '^nix-store ')"

# A signature that names our key but is not by it: only `store verify`
# (the cryptographic check) catches it.
fresh
MOCK_SIGNER=forged rp p10-forged
expect_exit "p10 forged signature under our key's name -> 32" 32
expect_grepf "p10 forged: says untrusted" "untrusted" "$ERR"
untouched "p10 forged"
expect_grepf "p10 verify uses --trusted-public-keys only" \
    "nix --extra-experimental-features nix-command store verify --no-contents --store $CACHE --trusted-public-keys $KEY $NEXT" \
    "$MOCK_LOG"
expect_eq "p10 never --extra-trusted-public-keys" 0 "$(log_count 'extra-trusted-public-keys')"
expect_eq "p10 forged: nothing realised" 0 "$(log_count '^nix-store ')"

for rc in 1 4; do
    fresh
    MOCK_VERIFY_RC=$rc rp "p10 verify rc $rc"
    expect_exit "p10 verify rc $rc -> 38 (cache unavailable, not untrusted)" 38
    expect_grepf "p10 verify rc $rc says cache unavailable" "cache unavailable" "$ERR"
    untouched "p10 verify rc $rc"
    expect_eq "p10 verify rc $rc: nothing realised" 0 "$(log_count '^nix-store ')"
done

# The narinfo in our cache, read before anything is realised (final review
# S1). nix treats a content-addressed path as valid without any signature
# (`store verify` passes it, the realise substitutes it), so the toplevel
# must be input-addressed, carry a signature by our key and have the
# pointer's narHash.
CA_SUM=fixed:r:sha256:1ygsiqb6j4bhgz23zaiifq0j4vm38dsdis5gh540amg857hwbsvb
OTHER_NAR="sha256-$(printf 'A%.0s' {1..43})="
for signer in none other ours; do
    fresh
    MOCK_CA=$CA_SUM MOCK_SIGNER=$signer rp "p10c ca, signer $signer"
    expect_exit "p10c content-addressed, signer $signer -> 32" 32
    expect_grepf "p10c ca, signer $signer: says content-addressed" "content-addressed" "$ERR"
    untouched "p10c ca, signer $signer"
    expect_eq "p10c ca, signer $signer: nothing realised" 0 "$(log_count '^nix-store ')"
done

fresh
pi "$NEXT" "$A" "$NEXT"
MOCK_CA=$CA_SUM MOCK_SIGNER=none rp p10c-current
expect_exit "p10c content-addressed, already current -> 32" 32
expect_eq "p10c already current: nothing recorded" none "$(cat "$STATE/seq" 2>/dev/null || echo none)"

fresh
MOCK_INFO_NAR=$OTHER_NAR rp p10d
expect_exit "p10d narinfo narHash differs from the pointer's -> 34" 34
expect_grepf "p10d says narHash mismatch" "narHash mismatch" "$ERR"
untouched "p10d narinfo narHash"
expect_eq "p10d nothing realised" 0 "$(log_count '^nix-store ')"

fresh
MOCK_SIGNER=none rp p10e
expect_exit "p10e unsigned -> 32" 32
expect_grepf "p10e says not signed by our key" "not signed by ${KEY%%:*}" "$ERR"
untouched "p10e unsigned"
expect_eq "p10e nothing realised" 0 "$(log_count '^nix-store ')"

fresh
MOCK_ABSENT=1 rp p10f
expect_exit "p10f not in our cache -> 38" 38
expect_grepf "p10f says not in the cache" "$NEXT is not in $CACHE" "$ERR"
untouched "p10f absent"
expect_eq "p10f nothing realised" 0 "$(log_count '^nix-store ')"

fresh
MOCK_PATHINFO_RC=1 rp p10g
expect_exit "p10g narinfo unreadable -> 38" 38
expect_grepf "p10g says cache unavailable" "cache unavailable" "$ERR"
untouched "p10g narinfo unreadable"
expect_eq "p10g nothing realised" 0 "$(log_count '^nix-store ')"

fresh
rp p10h
expect_exit "p10h signed by ours, input-addressed, same narHash -> 0" 0
expect_grepf "p10h reads the narinfo from our cache" \
    "nix --extra-experimental-features nix-command path-info --json --json-format 1 --store $CACHE $NEXT" \
    "$MOCK_LOG"
expect_true "p10h narinfo read before the realise" \
    test "$(first_line ' path-info .*--store ')" -lt "$(first_line '^nix-store --realise ')"

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

# A narinfo that changed between the check and the realise (S1): the
# realised path must be input-addressed in the local store too.
fresh
MOCK_LOCAL_CA=$CA_SUM rp p13c
expect_exit "p13c realised path content-addressed -> 32" 32
expect_grepf "p13c says content-addressed" "content-addressed" "$ERR"
untouched "p13c realised path content-addressed"
expect_grepf "p13c reads the local path info" \
    "nix --extra-experimental-features nix-command path-info --json --json-format 1 $NEXT" "$MOCK_LOG"
expect_true "p13c local path info read after the realise" \
    test "$(first_line '^nix-store --realise ')" -lt "$(first_line "path-info --json --json-format 1 $NEXT\$")"

# --- 5.5 decision, profile, activation, state -----------------------------------

PROFILE="$T/pi/nix/var/nix/profiles/system"

fresh
rp p14
expect_exit "p14 userspace-only change -> 0" 0
expect_grepf "p14 sets the system profile" "nix-env -p $PROFILE --set $NEXT" "$MOCK_LOG"
expect_eq "p14 profile points at the new system" "$NEXT" "$(readlink "$PROFILE")"
expect_grepf "p14 switches to the new system" "stc $NEXT switch" "$MOCK_LOG"
expect_eq "p14 no boot activation" 0 "$(log_count '^stc .* boot$')"
expect_eq "p14 no shutdown" 0 "$(log_count '^shutdown ')"
expect_eq "p14 one sync" 1 "$(log_count '^sync-state ')"
expect_eq "p14 records the seq" 1 "$(cat "$STATE/seq" 2>/dev/null)"
expect_eq "p14 records the store path" "$NEXT" "$(cat "$STATE/store-path" 2>/dev/null)"
expect_eq "p14 no temp files left in the state dir" "lock seq store-path" "$(state_files)"
expect_grepf "p14 says applied (switch)" "applied seq 1 (switch)" "$ERR"
expect_true "p14 P2 verify < realise" \
    test "$(first_line ' store verify ')" -lt "$(first_line '^nix-store --realise ')"
expect_true "p14 P2 realise < nix-env" \
    test "$(first_line '^nix-store --realise ')" -lt "$(first_line '^nix-env ')"
expect_true "p14 P2 nix-env < stc" \
    test "$(first_line '^nix-env ')" -lt "$(first_line '^stc ')"
expect_true "p14 P2 stc < sync" \
    test "$(first_line '^stc ')" -lt "$(first_line '^sync-state ')"
expect_grep "p14 P2 sync < state written" '^sync-state none$' "$MOCK_LOG"

for part in kernel initrd modules dtbs params fw cfg uboot; do
    N=$(psys "n-$part" "$part=2")
    fresh
    pointer 1 "$N"
    rp "p15 $part"
    expect_exit "p15 $part change -> 0" 0
    expect_true "p15 $part change -> boot + shutdown -r 06:30" \
        grep -qxF -e "stc $N boot" "$MOCK_LOG"
    expect_grepf "p15 $part change: shutdown -r 06:30" "shutdown -r 06:30" "$MOCK_LOG"
    expect_eq "p15 $part change: no switch" 0 "$(log_count '^stc .* switch$')"
    expect_true "p15 $part change: stc boot < shutdown" \
        test "$(first_line '^stc ')" -lt "$(first_line '^shutdown ')"
    expect_eq "p15 $part change: one sync" 1 "$(log_count '^sync-state ')"
    expect_eq "p15 $part change: profile set" "$N" "$(readlink "$PROFILE")"
    expect_eq "p15 $part change: seq recorded" 1 "$(cat "$STATE/seq" 2>/dev/null)"
    expect_grepf "p15 $part change: says reboot at 06:30" "applied seq 1 (boot, reboot at 06:30)" "$ERR"
done

N=$(psys n-kernel kernel=2)
fresh
pointer 1 "$N"
rp p15-time --reboot-time 03:15
expect_exit "p15 --reboot-time 03:15 -> 0" 0
expect_grepf "p15 --reboot-time 03:15 -> shutdown -r 03:15" "shutdown -r 03:15" "$MOCK_LOG"

# The boot fingerprint is the booted system's, not the current one's: after
# a switch to a new kernel (no reboot yet), another system with that kernel
# still needs the reboot.
K2=$(psys n-kernel kernel=2)
K2B=$(psys n-kernel-b kernel=2)
fresh
pi "$K2" "$A" "$K2"
pointer 1 "$K2B"
rp p15-booted
expect_exit "p15 booted kernel 1, current kernel 2 -> 0" 0
expect_true "p15 compares with the booted system (boot)" grep -qxF -e "stc $K2B boot" "$MOCK_LOG"
fresh
pi "$A" "$K2" "$A"
pointer 1 "$K2B"
rp p15-booted-same
expect_true "p15 same boot fingerprint as booted -> switch" grep -qxF -e "stc $K2B switch" "$MOCK_LOG"

for t in '' x 4:30 24:00 12:60 now +5 '04:30 -k' $'04:30\n'; do
    fresh
    rp "p15 reboot-time '$t'" --reboot-time "$t"
    expect_exit "p15 --reboot-time '$t' refused -> 2" 2
    expect_eq "p15 --reboot-time '$t': nothing fetched" 0 "$(log_count '^curl ')"
done

N=$(psys n-ext ext=2)
fresh
pointer 1 "$N"
rp p16
expect_exit "p16 extlinux-only change -> 0" 0
expect_true "p16 extlinux-only change -> switch" grep -qxF -e "stc $N switch" "$MOCK_LOG"
expect_eq "p16 no shutdown" 0 "$(log_count '^shutdown ')"

fresh
MOCK_STC_RC=1 rp p17
expect_exit "p17 switch-to-configuration fails -> 36" 36
expect_eq "p17 sync still runs" 1 "$(log_count '^sync-state ')"
expect_eq "p17 seq not recorded" none "$(cat "$STATE/seq" 2>/dev/null || echo none)"

N=$(psys n-kernel kernel=2)
fresh
pointer 1 "$N"
MOCK_STC_RC=1 rp p17-boot
expect_exit "p17 stc boot fails -> 36" 36
expect_eq "p17 stc boot fails: no shutdown" 0 "$(log_count '^shutdown ')"
expect_eq "p17 stc boot fails: sync still runs" 1 "$(log_count '^sync-state ')"
expect_eq "p17 stc boot fails: seq not recorded" none "$(cat "$STATE/seq" 2>/dev/null || echo none)"

fresh
pointer 1 "$N"
MOCK_SHUTDOWN_RC=1 rp p17-shutdown
expect_exit "p17 shutdown fails -> 36" 36
expect_eq "p17 shutdown fails: seq not recorded" none "$(cat "$STATE/seq" 2>/dev/null || echo none)"

fresh
pi "$A" "$T/pi/gone" "$A"
rp p17-booted
expect_exit "p17 booted-system unreadable -> 36" 36
expect_eq "p17 booted-system unreadable: no nix-env (D7)" 0 "$(log_count '^nix-env ')"
untouched "p17 booted-system unreadable"

fresh
pointer 1 "$FX_STORE/$H_NEXT-nixos-system-neptun-26.05.absent"
rp p17-newfp
expect_exit "p17 new system unreadable after the realise -> 36" 36
expect_eq "p17 new system unreadable: no nix-env (D7)" 0 "$(log_count '^nix-env ')"
untouched "p17 new system unreadable"

fresh
RPI_FP_LIB="$T/no-such-fp.sh" rp p17-fplib
expect_exit "p17 rpi-fp.sh missing -> 36" 36
untouched "p17 rpi-fp.sh missing"

fresh
MOCK_NIXENV_RC=1 rp p17-nixenv
expect_exit "p17 nix-env fails -> 35" 35
expect_eq "p17 nix-env fails: no stc" 0 "$(log_count '^stc ')"
expect_eq "p17 nix-env fails: seq not recorded" none "$(cat "$STATE/seq" 2>/dev/null || echo none)"

fresh
rm -rf "$STATE"
rp p20
expect_exit "p20 no state dir, seq 1 -> applies" 0
expect_eq "p20 seq 1 recorded" 1 "$(cat "$STATE/seq" 2>/dev/null)"
expect_grepf "p20 switched" "stc $NEXT switch" "$MOCK_LOG"

# --- A5 staleness: pointer `built`, --max-age-days -----------------------------

for built in - 7 '"2026-10-23"' '"2026-10-23T12:00:00"' '"2026-10-23 12:00:00Z"' \
    '"2026-10-23T12:00Z"' '"2026-13-45T25:61:61Z"' '"2026-02-30T12:00:00Z"' \
    '"2026-10-23T12:00:00Z\n"' '"x2026-10-23T12:00:00Z"' '"2026-10-23T12:00:00+02:00"'; do
    fresh
    pointer 1 "$NEXT" "$GOOD_NAR" "$built"
    rp "a5 built $built"
    expect_exit "a5 built $built -> 31" 31
    untouched "a5 built $built"
done

for days in 0 -1 x '' 1.5 021 100000 ' 21'; do
    fresh
    rp "a5 max-age-days '$days'" --max-age-days "$days"
    expect_exit "a5 --max-age-days '$days' refused -> 2" 2
    expect_eq "a5 --max-age-days '$days': nothing fetched" 0 "$(log_count '^curl ')"
done

fresh
built_ago $((22 * DAY))
rp a5-applied
expect_exit "a5 stale pointer applied -> 39" 39
expect_grepf "a5 says how old" "pointer is 22 days old (CI stalled?)" "$ERR"
expect_eq "a5 stale pointer: seq recorded" 1 "$(cat "$STATE/seq" 2>/dev/null)"
expect_grepf "a5 stale pointer: switched" "stc $NEXT switch" "$MOCK_LOG"

fresh
state 1
built_ago $((22 * DAY))
rp a5-uptodate
expect_exit "a5 stale pointer up to date -> 39" 39
expect_grepf "a5 up to date: says how old" "pointer is 22 days old (CI stalled?)" "$ERR"

fresh
pi "$NEXT" "$A" "$NEXT"
built_ago $((22 * DAY))
rp a5-current
expect_exit "a5 stale pointer already current -> 39" 39
expect_eq "a5 already current: seq recorded" 1 "$(cat "$STATE/seq" 2>/dev/null)"

fresh
built_ago $((21 * DAY - 3600))
rp a5-young
expect_exit "a5 pointer 20 days 23 h old -> 0" 0
expect_not_grep "a5 young pointer: no age warning" "days old" "$ERR"

fresh
built_ago $((21 * DAY + 3600))
rp a5-21
expect_exit "a5 pointer 21 days 1 h old -> 39" 39
expect_grepf "a5 says 21 days" "pointer is 21 days old (CI stalled?)" "$ERR"

fresh
built_ago $((22 * DAY))
rp a5-max30 --max-age-days 30
expect_exit "a5 22 days old, --max-age-days 30 -> 0" 0

fresh
built_ago $((3 * DAY))
rp a5-max2 --max-age-days 2
expect_exit "a5 3 days old, --max-age-days 2 -> 39" 39
expect_grepf "a5 says 3 days" "pointer is 3 days old (CI stalled?)" "$ERR"

fresh
built_ago $((-30 * DAY))
rp a5-future
expect_exit "a5 built 30 days in the future (clock skew) -> 0" 0

fresh
built_ago $((22 * DAY))
MOCK_STC_RC=1 rp a5-failed
expect_exit "a5 stale pointer, activation fails -> 36 (the failure wins)" 36

# --- A6 last-run ------------------------------------------------------------------

# last_run NAME EXIT RESULT: $STATE/last-run is the one line
# "time=<UTC> exit=EXIT result=RESULT"
last_run() {
    expect_eq "$1: last-run is one line" 1 "$(wc -l <"$STATE/last-run" 2>/dev/null || echo 0)"
    expect_grep "$1: last-run exit=$2 result=$3" \
        "^time=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z exit=$2 result=$3\$" "$STATE/last-run"
}

fresh
rp l1
last_run "l1 applied" 0 applied
lr_time=$(sed -n 's/^time=\([^ ]*\) .*/\1/p' "$STATE/last-run" 2>/dev/null)
lr_age=$(($(date -u +%s) - $(date -u -d "${lr_time:-1970-01-01T00:00:00Z}" +%s)))
expect_true "l1 last-run time is now (${lr_age}s ago)" test "$lr_age" -ge 0 -a "$lr_age" -lt 300
expect_eq "l1 no temp files left in the state dir" "lock seq store-path" "$(state_files)"

fresh
state 1
rp l2
last_run "l2 up to date" 0 up-to-date

fresh
pi "$NEXT" "$A" "$NEXT"
rp l3
last_run "l3 already current" 0 already-current

fresh
MOCK_HTTP=404 rp l4
last_run "l4 no pointer" 0 no-pointer

# l5 CASE EXIT RESULT: one failing run per exit code (the knob is set by the caller)
l5() {
    rp "l5 $1"
    expect_exit "l5 $1 -> $2" "$2"
    last_run "l5 $1" "$2" "$3"
}
fresh; MOCK_CURL_RC=6 l5 fetch 30 fetch-failed
fresh; state 5; MOCK_HTTP=404 l5 disappeared 30 fetch-failed
fresh; printf 'not json\n' >"$MOCK_BODY"; l5 invalid 31 pointer-invalid
fresh; state 5; pointer 4 "$NEXT"; l5 older 31 pointer-invalid
fresh; state abc; l5 state-seq 31 pointer-invalid
fresh; MOCK_SIGNER=other l5 untrusted 32 untrusted
fresh; MOCK_REALISE_RC=1 l5 realise 33 realise-failed
fresh; MOCK_NAR="sha256-${GOOD_NAR:8}" l5 nar 34 narhash-mismatch
fresh; MOCK_NIXENV_RC=1 l5 profile 35 profile-failed
fresh; MOCK_STC_RC=1 l5 activation 36 activation-failed
fresh; MOCK_VERIFY_RC=1 l5 cache 38 cache-unavailable
fresh; MOCK_CA=$CA_SUM MOCK_SIGNER=none l5 ca 32 untrusted
fresh; MOCK_ABSENT=1 l5 absent 38 cache-unavailable
fresh; built_ago $((22 * DAY)); l5 stale 39 stale

fresh
mkdir -p "$STATE"
echo 'time=2026-01-01T00:00:00Z exit=0 result=applied' >"$STATE/last-run"
exec 8>"$STATE/lock"
flock -n 8
rp l6
exec 8>&-
expect_exit "l6 busy -> 37" 37
expect_eq "l6 busy: last-run untouched" 'time=2026-01-01T00:00:00Z exit=0 result=applied' \
    "$(cat "$STATE/last-run")"

fresh
rp l7 --host a/b
expect_exit "l7 usage error -> 2" 2
expect_true "l7 usage error (before the lock): no last-run" test ! -e "$STATE/last-run"

# --- lock ------------------------------------------------------------------------

fresh
mkdir -p "$STATE"
exec 8>"$STATE/lock"
flock -n 8
rp p18
exec 8>&-
expect_exit "p18 lock held -> 37" 37
expect_eq "p18 nothing fetched" 0 "$(log_count '^curl ')"

# An unusable state dir is exit 1 ("state dir", usage and README), not 37
# "busy" (final review N2).
fresh
: >"$T/not-a-dir"
for sd in "$T/not-a-dir" /proc/rpi-pull-unit-x; do
    fresh
    run_cmd "p18 state dir $sd" -- bash "$RPI_PULL_SRC" --pointer-url https://x/neptun.json \
        --cache-url "$CACHE" --cache-key "$KEY" --state-dir "$sd"
    expect_exit "p18 state dir $sd unusable -> 1" 1
    expect_grepf "p18 state dir $sd unusable: says why" "cannot open $sd/lock" "$ERR"
    expect_eq "p18 state dir $sd unusable: nothing fetched" 0 "$(log_count '^curl ')"
done

fresh
# p19 (G1): no evaluation or build on the Pi, in any case of this file
expect_eq "p19 no nix eval/build or nixos-rebuild anywhere" 0 \
    "$(grep -cE '^nix .*[[:space:]](eval|build)( |$)|^nix-(build|instantiate) |nixos-rebuild' "$ALL_LOG")"
expect_true "p19 the mocks logged something" test -s "$ALL_LOG"
summary
