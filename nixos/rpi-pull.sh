#!/usr/bin/env bash
#
# rpi-pull — apply the system CI published for this Pi. Runs on the Pi as
# root (rpi-pull.service, modules/pull-update.nix): fetches the pointer
# (nixos/deploy/<host>.json), checks it, realises the closure from our
# cache and activates it. Spec: docs/superpowers/specs/
# 2026-10-23-ci-pull-updates-design.md §3.4; plan §15.1, §17.
#
# RPI_FP_LIB: rpi-fp.sh (the boot fingerprint), default: next to this script.
# Test hooks: RPI_PULL_ROOT (prefix of /run/{current,booted}-system and the
# system profile), RPI_PULL_STORE (the store dir, default /nix/store).

set -uo pipefail

usage() {
    cat <<'EOF'
usage: rpi-pull --pointer-url URL --cache-url URL --cache-key KEY
                [--host NAME] [--state-dir DIR] [--reboot-time HH:MM]
                [--max-age-days N]

Applies the system in the pointer at URL if its seq is newer than the last
applied one, its store path is HOST's system, its narinfo in the cache at
--cache-url is input-addressed, signed by KEY and has the pointer's narHash
(all checked before anything is realised), and the realised path has that
narHash and is input-addressed. A change the
booted system's boot fingerprint does not cover is switched to; any other
is activated for the next boot, with a reboot scheduled at --reboot-time.
A pointer built more than --max-age-days ago means CI has stalled: exit 39
(after the run has otherwise succeeded).

  --host NAME         system name in the store path (default neptun)
  --state-dir DIR     the lock, the applied seq and store-path, and last-run
                      ("time=<UTC> exit=<code> result=<word>", every run that
                      got the lock) (default /var/lib/rpi-pull)
  --reboot-time HH:MM when to reboot into a new boot configuration (default 04:30)
  --max-age-days N    the pointer's maximum age, 1-9999 (default 21)

exit: 0 applied, up to date, already current or no pointer published yet
        (HTTP 404 before any pointer was applied)
      1 state dir not writable   2 usage
      30 fetch (also HTTP 404 once a pointer was applied)
      31 pointer invalid or older
      32 untrusted (not signed by KEY, or content-addressed)
      33 realise   34 narHash mismatch (narinfo or realised path)
      35 profile   36 activation (switch-to-configuration, shutdown)
      37 busy   38 cache unavailable, or the system is not in it
      39 pointer stale (CI stalled?)
EOF
}

log() { printf 'rpi-pull: %s\n' "$*" >&2; }
die() {
    local rc="$1"
    shift
    log "$*"
    exit "$rc"
}

SEQ_RE='^[1-9][0-9]{0,9}$'

POINTER_URL="" CACHE_URL="" CACHE_KEY="" HOST=neptun STATE=/var/lib/rpi-pull
REBOOT_TIME=04:30 MAX_AGE_DAYS=21
STORE="${RPI_PULL_STORE:-/nix/store}"

rp_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -h | --help) usage; exit 0 ;;
        --pointer-url | --cache-url | --cache-key | --host | --state-dir | --reboot-time | \
            --max-age-days)
            [[ $# -ge 2 ]] || die 2 "$1 needs a value (see --help)"
            case "$1" in
            --pointer-url) POINTER_URL="$2" ;;
            --cache-url) CACHE_URL="$2" ;;
            --cache-key) CACHE_KEY="$2" ;;
            --host) HOST="$2" ;;
            --state-dir) STATE="$2" ;;
            --reboot-time) REBOOT_TIME="$2" ;;
            --max-age-days) MAX_AGE_DAYS="$2" ;;
            esac
            shift ;;
        *) die 2 "unknown argument: $1 (see --help)" ;;
        esac
        shift
    done
    [[ -n "$POINTER_URL" && -n "$CACHE_URL" && -n "$CACHE_KEY" ]] ||
        die 2 "--pointer-url, --cache-url and --cache-key are required (see --help)"
    [[ "$HOST" =~ ^[A-Za-z0-9_-]+$ ]] || die 2 "invalid --host: '$HOST'"
    [[ "$REBOOT_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] ||
        die 2 "invalid --reboot-time: '$REBOOT_TIME' (HH:MM)"
    [[ "$MAX_AGE_DAYS" =~ ^[1-9][0-9]{0,3}$ ]] ||
        die 2 "invalid --max-age-days: '$MAX_AGE_DAYS' (1-9999)"
}

# rp_lock: hold $STATE/lock for the rest of the run (exit 37 if taken, 1 if
# the state dir is unusable)
rp_lock() {
    local fd
    { mkdir -p "$STATE" && exec {fd}>"$STATE/lock"; } 2>/dev/null ||
        die 1 "state dir not writable: cannot open $STATE/lock"
    flock -n "$fd" || die 37 "busy: another rpi-pull holds $STATE/lock"
}

# rp_last_seq: the applied seq ($STATE/seq; 0 if none) -> LAST
rp_last_seq() {
    LAST=0
    [[ -e "$STATE/seq" ]] || return 0
    LAST=$(<"$STATE/seq")
    [[ "$LAST" =~ $SEQ_RE ]] || die 31 "$STATE/seq is not a seq number: '$LAST'"
}

# rp_fetch FILE: the pointer into FILE; HTTP 404 exits 0 if none was ever
# applied (LAST 0: none published yet), else 30 -- a pointer that
# disappeared must not stop the updates silently (final review S3)
rp_fetch() {
    local code
    code=$(curl -sS --proto-redir =https --max-time 60 --retry 3 --retry-delay 20 \
        --max-filesize 65536 -o "$1" -w '%{http_code}' --url "$POINTER_URL") ||
        die 30 "cannot fetch $POINTER_URL (curl exit $?)"
    case "$code" in
    200) ;;
    404)
        ((LAST == 0)) || die 30 "pointer disappeared (HTTP 404) after seq $LAST was applied: $POINTER_URL"
        log "no pointer published yet ($POINTER_URL)"; RESULT=no-pointer; exit 0 ;;
    *) die 30 "cannot fetch $POINTER_URL (HTTP $code)" ;;
    esac
}

# rp_parse FILE: P_SEQ P_PATH P_NAR from the pointer; exit 31 unless each is
# well-formed. jq rejects control characters, so the fields are one line
# each (`explode` and `.seq` fail on non-strings and non-objects).
rp_parse() {
    local fields
    fields=$(jq -er '
        def text: explode | all(. >= 32 and . != 127);
        if (.seq | type) == "number" and (.storePath | text) and (.narHash | text)
            and (.built | text)
        then (.seq | tostring), .storePath, .narHash, .built
        else error("bad pointer") end' "$1" 2>/dev/null) ||
        die 31 "pointer is not a JSON object with seq, storePath, narHash and built"
    { IFS= read -r P_SEQ; IFS= read -r P_PATH; IFS= read -r P_NAR; IFS= read -r P_BUILT; } <<<"$fields"
    [[ "$P_SEQ" =~ $SEQ_RE ]] || die 31 "pointer seq is not a positive integer: $P_SEQ"
    [[ "$P_PATH" =~ ^"$STORE"/[0-9a-df-np-sv-z]{32}-nixos-system-"$HOST"-[A-Za-z0-9+._?=-]+$ ]] ||
        die 31 "pointer storePath is not a $HOST system in $STORE: $P_PATH"
    [[ "$P_NAR" =~ ^sha256-[A-Za-z0-9+/]{43}=$ ]] || die 31 "pointer narHash is not sha256-<base64>: $P_NAR"
    [[ "$P_BUILT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] &&
        P_BUILT_S=$(date -u -d "$P_BUILT" +%s 2>/dev/null) ||
        die 31 "pointer built is not a UTC time YYYY-MM-DDTHH:MM:SSZ: $P_BUILT"
}

# rp_verify_sig: before anything is realised, P_PATH's narinfo in our cache
# must be input-addressed (nix accepts a content-addressed path without any
# signature, in `store verify` and in the realise), name a signature by our
# key, pass `nix store verify` with our key only (--trusted-public-keys
# replaces the configured keys; nix exits 2 for an untrusted path, anything
# else is an unreachable cache) and carry the pointer's narHash.
rp_verify_sig() {
    local info verdict rc=0 name="${CACHE_KEY%%:*}"
    info=$(nix --extra-experimental-features nix-command path-info --json --json-format 1 \
        --store "$CACHE_URL" "$P_PATH") ||
        die 38 "cache unavailable: cannot read the narinfo of $P_PATH in $CACHE_URL (nix exit $?)"
    verdict=$(jq -r --arg p "$P_PATH" --arg k "$name:" '
        .[$p] | if . == null then "absent"
        elif .ca != null then "content-addressed"
        elif (any(.signatures[]?; type == "string" and startswith($k)) | not) then "unsigned"
        else "narHash \(.narHash | tojson)" end' <<<"$info" 2>/dev/null) ||
        die 38 "cache unavailable: unreadable narinfo of $P_PATH in $CACHE_URL"
    case "$verdict" in
    absent) die 38 "cache unavailable: $P_PATH is not in $CACHE_URL (not pushed, or evicted)" ;;
    content-addressed) die 32 "untrusted: $P_PATH is content-addressed in $CACHE_URL (our systems never are)" ;;
    unsigned) die 32 "untrusted: $P_PATH is not signed by $name in $CACHE_URL" ;;
    "narHash "*) ;;
    *) die 38 "cache unavailable: unreadable narinfo of $P_PATH in $CACHE_URL" ;;
    esac
    nix --extra-experimental-features nix-command store verify --no-contents \
        --store "$CACHE_URL" --trusted-public-keys "$CACHE_KEY" "$P_PATH" || rc=$?
    case "$rc" in
    0) ;;
    2) die 32 "untrusted: $P_PATH is not signed by $CACHE_KEY in $CACHE_URL" ;;
    *) die 38 "cache unavailable: cannot verify $P_PATH in $CACHE_URL (nix exit $rc)" ;;
    esac
    [[ "${verdict#narHash }" == "\"$P_NAR\"" ]] ||
        die 34 "narHash mismatch: the narinfo of $P_PATH in $CACHE_URL says ${verdict#narHash }, the pointer $P_NAR"
}

# rp_realise: P_PATH's closure from the substituters, then P_PATH's narHash
# (SRI, D5) must equal the pointer's -- the binding between pointer and
# content, since the realise trusts every configured key -- and P_PATH must
# be input-addressed in the local store too (a narinfo that changed after
# rp_verify_sig read it).
rp_realise() {
    local hash sri
    nix-store --realise "$P_PATH" --option max-substitution-jobs 2 >/dev/null ||
        die 33 "cannot realise $P_PATH"
    hash=$(nix-store --query --hash "$P_PATH") &&
        sri=$(nix --extra-experimental-features nix-command hash convert --to sri "$hash") ||
        die 34 "narHash mismatch: cannot read the narHash of $P_PATH"
    [[ "$sri" == "$P_NAR" ]] || die 34 "narHash mismatch: $P_PATH is $sri, pointer says $P_NAR"
    nix --extra-experimental-features nix-command path-info --json --json-format 1 "$P_PATH" |
        jq -e --arg p "$P_PATH" '.[$p] | type == "object" and .ca == null' >/dev/null 2>&1 ||
        die 32 "untrusted: $P_PATH is content-addressed in the local store (or its path info is unreadable)"
}

# rp_activation: ACTION=boot if P_PATH's boot fingerprint differs from the
# booted system's (only a reboot applies it), else ACTION=switch. Exit 36 if
# either is unreadable -- before the profile is touched (D7).
rp_activation() {
    local fp_new fp_boot booted="${RPI_PULL_ROOT:-}/run/booted-system"
    # shellcheck source=rpi-fp.sh
    source "${RPI_FP_LIB:-$(dirname "${BASH_SOURCE[0]}")/rpi-fp.sh}" ||
        die 36 "cannot load rpi-fp.sh (RPI_FP_LIB=${RPI_FP_LIB:-})"
    fp_new=$(RL_STORE_DIR="$STORE" rl_fp_local "$P_PATH") ||
        die 36 "cannot read the boot fingerprint of $P_PATH"
    fp_boot=$(RL_STORE_DIR="$STORE" rl_fp_local "$booted") ||
        die 36 "cannot read the boot fingerprint of $booted"
    ACTION=switch
    if rl_needs_reboot "$fp_new" "$fp_boot"; then ACTION=boot; fi
}

# rp_apply: the system profile -> P_PATH (exit 35), then activate it by
# ACTION and sync (always); boot also schedules the reboot (exit 36).
rp_apply() {
    local rc=0
    nix-env -p "${RPI_PULL_ROOT:-}/nix/var/nix/profiles/system" --set "$P_PATH" ||
        die 35 "cannot set the system profile to $P_PATH"
    "$P_PATH/bin/switch-to-configuration" "$ACTION" || rc=$?
    sync
    ((rc == 0)) || die 36 "switch-to-configuration $ACTION failed (exit $rc)"
    if [[ "$ACTION" == boot ]]; then
        shutdown -r "$REBOOT_TIME" || die 36 "cannot schedule the reboot at $REBOOT_TIME"
    fi
}

# rp_check_age: exit 39 if the pointer was built more than MAX_AGE_DAYS ago
# -- CI stopped publishing (A5); a pointer from the future is not stale.
rp_check_age() {
    local age
    age=$(($(date -u +%s) - P_BUILT_S))
    ((age <= MAX_AGE_DAYS * 86400)) || die 39 "pointer is $((age / 86400)) days old (CI stalled?)"
}

# rp_result RC: the last-run result for exit code RC (RESULT names the
# successful outcome)
rp_result() {
    case "$1" in
    0) echo "${RESULT:-ok}" ;;
    1) echo state-error ;;
    30) echo fetch-failed ;;
    31) echo pointer-invalid ;;
    32) echo untrusted ;;
    33) echo realise-failed ;;
    34) echo narhash-mismatch ;;
    35) echo profile-failed ;;
    36) echo activation-failed ;;
    38) echo cache-unavailable ;;
    39) echo stale ;;
    *) echo error ;;
    esac
}

# rp_finish: on exit once the lock is held -- drop the pointer temp file and
# write $STATE/last-run "time=<UTC> exit=<rc> result=<word>" (tmp + mv; A6).
# The exit code stays the run's.
rp_finish() {
    local rc=$?
    [[ -z "${TMP:-}" ]] || rm -f "$TMP"
    { printf 'time=%s exit=%s result=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "$(rp_result "$rc")" \
        >"$STATE/last-run.tmp" && mv -f "$STATE/last-run.tmp" "$STATE/last-run"; } 2>/dev/null ||
        log "cannot write $STATE/last-run"
}

# rp_record: the applied pointer -> $STATE/store-path, $STATE/seq (each
# written to a temp file and renamed; seq last, so a crash re-applies)
rp_record() {
    local f v
    for f in store-path seq; do
        v="$P_PATH"
        [[ "$f" == seq ]] && v="$P_SEQ"
        { printf '%s\n' "$v" >"$STATE/$f.tmp" && mv -f "$STATE/$f.tmp" "$STATE/$f"; } ||
            die 1 "cannot write $STATE/$f"
    done
}

main() {
    rp_parse_args "$@"
    rp_lock
    trap rp_finish EXIT
    rp_last_seq
    TMP=$(mktemp "$STATE/pointer.XXXXXX") || die 1 "cannot create a temp file in $STATE"
    rp_fetch "$TMP"
    rp_parse "$TMP"
    rp_update
    rp_check_age
}

# rp_update: bring the Pi to the parsed pointer (exit on any failure)
rp_update() {
    if ((P_SEQ == LAST)); then
        log "up to date (seq $P_SEQ)"
        RESULT=up-to-date
        return 0
    fi
    ((P_SEQ > LAST)) || die 31 "pointer seq $P_SEQ is older than applied seq $LAST"
    rp_verify_sig
    if [[ "$(readlink -f "${RPI_PULL_ROOT:-}/run/current-system")" == "$P_PATH" ]]; then
        rp_record
        log "already current: $P_PATH (seq $P_SEQ recorded)"
        RESULT=already-current
        return 0
    fi
    rp_realise
    rp_activation
    rp_apply
    rp_record
    RESULT=applied
    if [[ "$ACTION" == boot ]]; then
        log "applied seq $P_SEQ (boot, reboot at $REBOOT_TIME)"
    else
        log "applied seq $P_SEQ (switch)"
    fi
}

main "$@"
