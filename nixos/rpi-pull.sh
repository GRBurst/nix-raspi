#!/usr/bin/env bash
#
# rpi-pull — apply the system CI published for this Pi. Runs on the Pi as
# root (rpi-pull.service, modules/pull-update.nix): fetches the pointer
# (nixos/deploy/<host>.json), checks it, realises the closure from our
# cache and activates it. Spec: docs/superpowers/specs/
# 2026-10-23-ci-pull-updates-design.md §3.4; plan §15.1, §17.
#
# Test hooks: RPI_PULL_ROOT (prefix of /run/{current,booted}-system and the
# system profile), RPI_PULL_STORE (the store dir, default /nix/store),
# RPI_FP_LIB (rpi-fp.sh, default: next to this script).

set -uo pipefail

usage() {
    cat <<'EOF'
usage: rpi-pull --pointer-url URL --cache-url URL --cache-key KEY
                [--host NAME] [--state-dir DIR]

Applies the system in the pointer at URL if its seq is newer than the last
applied one, its store path is HOST's system, it is signed by KEY in the
cache at --cache-url and its narHash matches the pointer.

  --host NAME         system name in the store path (default neptun)
  --state-dir DIR     applied seq/store-path and the lock (default /var/lib/rpi-pull)

exit: 0 applied, up to date, already current or no pointer published yet
      2 usage   30 fetch   31 pointer invalid or older   37 busy
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
STORE="${RPI_PULL_STORE:-/nix/store}"

rp_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -h | --help) usage; exit 0 ;;
        --pointer-url | --cache-url | --cache-key | --host | --state-dir)
            [[ $# -ge 2 ]] || die 2 "$1 needs a value (see --help)"
            case "$1" in
            --pointer-url) POINTER_URL="$2" ;;
            --cache-url) CACHE_URL="$2" ;;
            --cache-key) CACHE_KEY="$2" ;;
            --host) HOST="$2" ;;
            --state-dir) STATE="$2" ;;
            esac
            shift ;;
        *) die 2 "unknown argument: $1 (see --help)" ;;
        esac
        shift
    done
    [[ -n "$POINTER_URL" && -n "$CACHE_URL" && -n "$CACHE_KEY" ]] ||
        die 2 "--pointer-url, --cache-url and --cache-key are required (see --help)"
    [[ "$HOST" =~ ^[A-Za-z0-9_-]+$ ]] || die 2 "invalid --host: '$HOST'"
}

# rp_lock: hold $STATE/lock for the rest of the run (exit 37 if taken)
rp_lock() {
    local fd
    { mkdir -p "$STATE" && exec {fd}>"$STATE/lock"; } 2>/dev/null ||
        die 37 "cannot open $STATE/lock"
    flock -n "$fd" || die 37 "busy: another rpi-pull holds $STATE/lock"
}

# rp_last_seq: the applied seq ($STATE/seq; 0 if none) -> LAST
rp_last_seq() {
    LAST=0
    [[ -e "$STATE/seq" ]] || return 0
    LAST=$(<"$STATE/seq")
    [[ "$LAST" =~ $SEQ_RE ]] || die 31 "$STATE/seq is not a seq number: '$LAST'"
}

# rp_fetch FILE: the pointer into FILE; exits 0 if none is published yet
rp_fetch() {
    local code
    code=$(curl -sS --proto-redir =https --max-time 60 --retry 3 --retry-delay 20 \
        --max-filesize 65536 -o "$1" -w '%{http_code}' --url "$POINTER_URL") ||
        die 30 "cannot fetch $POINTER_URL (curl exit $?)"
    case "$code" in
    200) ;;
    404) log "no pointer published yet ($POINTER_URL)"; exit 0 ;;
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
        then (.seq | tostring), .storePath, .narHash
        else error("bad pointer") end' "$1" 2>/dev/null) ||
        die 31 "pointer is not a JSON object with seq, storePath and narHash"
    { IFS= read -r P_SEQ; IFS= read -r P_PATH; IFS= read -r P_NAR; } <<<"$fields"
    [[ "$P_SEQ" =~ $SEQ_RE ]] || die 31 "pointer seq is not a positive integer: $P_SEQ"
    [[ "$P_PATH" =~ ^"$STORE"/[0-9a-df-np-sv-z]{32}-nixos-system-"$HOST"-[A-Za-z0-9+._?=-]+$ ]] ||
        die 31 "pointer storePath is not a $HOST system in $STORE: $P_PATH"
    [[ "$P_NAR" =~ ^sha256-[A-Za-z0-9+/]{43}=$ ]] || die 31 "pointer narHash is not sha256-<base64>: $P_NAR"
}

main() {
    rp_parse_args "$@"
    rp_lock
    rp_last_seq
    TMP=$(mktemp "$STATE/pointer.XXXXXX") || die 30 "cannot create a temp file in $STATE"
    trap 'rm -f "$TMP"' EXIT
    rp_fetch "$TMP"
    rp_parse "$TMP"
    if ((P_SEQ == LAST)); then
        log "up to date (seq $P_SEQ)"
        exit 0
    fi
    ((P_SEQ > LAST)) || die 31 "pointer seq $P_SEQ is older than applied seq $LAST"
    die 1 "not implemented"
}

main "$@"
