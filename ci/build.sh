#!/usr/bin/env bash
#
# ci/build.sh — CI build of one Pi host's system (`rpi-ci build`, one job of
# the workflow's host matrix).
#
#   ci/build.sh --host NAME [--event NAME] [--update-lock] [--update-library] [--flake DIR] [--max-builds N]
#
# 1. Host info (rpi-lib.sh rl_host_info of nixosConfigurations.NAME):
#    system.name and rpi.pull.cache. A cache is added as an extra
#    substituter of the guard's dry run and of the builds
#    (--option extra-substituters / extra-trusted-public-keys; nix-daemon
#    honours them only for a trusted user, which the runner's user is).
# 2. Lock update when NAME (default $GITHUB_EVENT_NAME) is `schedule` or
#    --update-lock is given: `nix flake update` of nixpkgs and
#    nixos-raspberrypi: each root input of that name and, in a flake built
#    on this library (input rpi, the template), the library's own node of
#    it (rpi/nixpkgs, rpi/nixos-raspberrypi; not when it follows a root
#    input): a consumer's own root nixpkgs does not stop the system's
#    rpi/nixpkgs from moving (re-review SF1). Never rpi itself (final review S3): the library's code reaches a
#    consumer's Pi only through --update-library (the workflow's manual
#    update-library input), which updates rpi with the inputs it locked.
# 3. Guards (rpi-lib.sh rl_guard): the kernel must be in the nvmd cache, no
#    kernel/toolchain build, at most N local builds (default 500).
#    A kernel cache miss right after a lock update falls back to the
#    committed lock plus an update of the nixpkgs among them only and
#    guards again, so an uncached nvmd kernel does not hold back that week's
#    userspace fixes.
# 4. `nix build --no-link` of the host's toplevel; `df -h /`.
# 5. `nix build` of every checks.<current system> of the flake (none: a
#    notice), so nothing is published that fails its own tests.
#
# stdout: `top=<store path>` and `name=<system.name>` (for $GITHUB_OUTPUT),
# only after all of it succeeded; logs on stderr. Under GitHub Actions also
# annotations, log groups and a step summary section (ci/gh.sh).
# Exit: 0 | 1 invalid rpi.pull.cache or system.name | 2 usage | rl_guard's
# RL_E_* (10 cache, 11 forbidden, 12 too many, 13 eval/build/check error).
#
# DIR defaults to the working directory; RPI_LIB overrides the path of rpi-lib.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
usage: ci/build.sh --host NAME [--event NAME] [--update-lock] [--update-library] [--flake DIR] [--max-builds N]

  --host NAME     the Pi host (nixosConfigurations.NAME) to build
  --event NAME    GitHub event (default \$GITHUB_EVENT_NAME); schedule updates the lock
  --update-lock   update nixpkgs and nixos-raspberrypi (and/or rpi/nixpkgs and
                  rpi/nixos-raspberrypi) in flake.lock first; never rpi
  --update-library  update rpi (the library, with the inputs it locked) first
  --flake DIR     flake directory (default: the working directory)
  --max-builds N  build guard limit (default 500)

stdout: top=<store path of the toplevel>, name=<its system.name>
EOF
}

die_usage() { echo "ci/build.sh: $1" >&2; usage >&2; exit 2; }

event="${GITHUB_EVENT_NAME:-}" update_lock=0 update_library=0 dir="$PWD" max=500 host=""
while (($#)); do
    case "$1" in
    --event | --flake | --max-builds | --host) (($# >= 2)) || die_usage "$1 needs a value" ;;&
    --event) event="$2"; shift 2 ;;
    --update-lock) update_lock=1; shift ;;
    --update-library) update_library=1; shift ;;
    --flake) dir="$2"; shift 2 ;;
    --max-builds) max="$2"; shift 2 ;;
    --host) host="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) die_usage "unknown argument '$1'" ;;
    esac
done
[[ -n "$host" ]] || die_usage "missing --host NAME"
[[ "$host" =~ ^[A-Za-z0-9_-]+$ ]] || die_usage "invalid host name: '$host'"
[[ "$max" =~ ^[0-9]+$ ]] || die_usage "--max-builds must be a number"
[[ "$event" == schedule ]] && update_lock=1
dir="$(cd "$dir" && pwd)" || die_usage "no such directory: '$dir'"

export RL_FLAKE="$dir" RL_ATTR="$host"
# shellcheck source=../rpi-lib.sh
source "${RPI_LIB:-$HERE/../rpi-lib.sh}"
# shellcheck source=gh.sh
source "$HERE/gh.sh"

lock="$dir/flake.lock" nl=$'\n'
name="" top="" checks_line="" lock_state="as committed" revs_before=""

# lock_revs: "PATH REV" for the lock paths nixpkgs, nixos-raspberrypi and
# rpi (root inputs) and rpi/nixpkgs, rpi/nixos-raspberrypi (rpi's inputs,
# unless they follow the root input of the same name); follows paths are
# resolved from the root. The same paths as lock_targets, so the summary
# names exactly what moved.
# shellcheck disable=SC2016 # jq program
REVS_JQ='
def node_of($L; $n; $in):
  ($L.nodes[$n].inputs // {})[$in] as $r
  | if $r == null then null
    elif ($r | type) == "string" then $r
    else reduce $r[] as $i ($L.root; if . == null then null else node_of($L; .; $i) end)
    end;
. as $L
| node_of($L; $L.root; "rpi") as $rpi
| (("nixpkgs", "nixos-raspberrypi") as $x
   | node_of($L; $L.root; $x) as $o
   | ([$x, $o],
      (if $rpi == null then empty
       else node_of($L; $rpi; $x) as $n
       | if $n != null and ($n != $o or ($L.nodes[$rpi].inputs[$x] | type) == "string")
         then ["rpi/\($x)", $n] else empty end
       end))),
  ["rpi", $rpi]
| select(.[1] != null)
| "\(.[0]) \($L.nodes[.[1]].locked.rev // "?")"'
lock_revs() { jq -r "$REVS_JQ" "$lock" 2>/dev/null || true; }

# summary LINE...: this build's step summary section (GitHub Actions only)
summary() {
    gh_on || return 0
    local input rev size
    {
        echo "## $host: build"
        echo
        [[ -z "$name" || "$name" == "$host" ]] || echo "- system.name: \`$name\`"
        while read -r input rev; do
            [[ -z "$input" ]] || echo "- $input: \`$rev\`"
        done <<<"$(lock_revs)"
        echo "- lock: $lock_state"
        if [[ -n "$top" ]]; then
            size="$(nix path-info --closure-size --human-readable "$top" 2>/dev/null | cut -f2 | sed 's/^ *//')" || true
            echo "- toplevel: \`$top\`"
            echo "- closure: ${size:-unknown}"
        fi
        [[ -z "$checks_line" ]] || echo "- checks: $checks_line"
        (($# == 0)) || printf '%s\n' "$@"
        echo
    } | gh_summary
}

# fail RC MSG: error annotation, summary section, exit RC
fail() {
    gh_error "$2"
    summary "- failed: $2"
    exit "$1"
}

# update INPUT...: nix flake update of the named inputs in DIR/flake.lock.
update() {
    echo "ci/build.sh: updating flake.lock: $*" >&2
    nix flake update --accept-flake-config --flake "$dir" "$@"
}

# --- host info: name, cache ---------------------------------------------------
info="$(rl_host_info "$dir" "$host")" || fail "$RL_E_BUILD" "cannot evaluate the host info of $host"
name="$(jq -r '.name | strings' <<<"$info")" || name=""
[[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || fail 1 "system.name of $host is not a plain name: '$name'"
cache_name="$(jq -r '.cache.name // empty' <<<"$info")"
cache_key="$(jq -r '.cache.publicKey // empty' <<<"$info")"
subst=() subst_conf=""
if [[ -n "$cache_name" || -n "$cache_key" ]]; then
    [[ "$cache_name" =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
        fail 1 "rpi.pull.cache.name of $host is not a Cachix cache name: '$cache_name'"
    [[ "$cache_key" =~ ^[^[:space:]:]+:[A-Za-z0-9+/]+=*$ ]] ||
        fail 1 "rpi.pull.cache.publicKey of $host is not a public key: '$cache_key'"
    subst=(--option extra-substituters "https://$cache_name.cachix.org"
        --option extra-trusted-public-keys "$cache_key")
    subst_conf="extra-substituters = https://$cache_name.cachix.org${nl}extra-trusted-public-keys = $cache_key"
    echo "ci/build.sh: substituting from $host's cache https://$cache_name.cachix.org" >&2
fi

# --- lock update ----------------------------------------------------------------
# lock_targets: the inputs to update, one per line. --update-lock: nixpkgs
# and nixos-raspberrypi, each as a root input and as the library's own
# input (rpi/<name>, a flake built on this library: the template; a
# follows is moved by the root input it follows), both when the consumer
# has a root nixpkgs of its own (re-review SF1: the system uses
# rpi/nixpkgs); never rpi itself. --update-library: rpi, with the nixpkgs
# and nixos-raspberrypi the library locked (what its CI built), so not also
# its nested inputs.
# shellcheck disable=SC2016 # jq program
TARGETS_JQ='
.nodes[.root].inputs as $i
| (if ($i.rpi | type) == "string" then .nodes[$i.rpi].inputs // {} else {} end) as $r
| (if $upd then ("nixpkgs", "nixos-raspberrypi") as $x
     | (if $i[$x] != null then $x else empty end),
       (if ($lib | not) and ($r[$x] | type) == "string" then "rpi/\($x)" else empty end)
   else empty end),
  (if $lib and $i.rpi != null then "rpi" else empty end)'
lock_targets() {
    local upd=false lib=false
    if ((update_lock)); then upd=true; fi
    if ((update_library)); then lib=true; fi
    jq -r --argjson upd "$upd" --argjson lib "$lib" "$TARGETS_JQ" "$lock" 2>/dev/null || true
}
updated=()
if ((update_lock || update_library)); then
    revs_before="$(lock_revs)"
    mapfile -t updated < <(lock_targets)
    if ((update_library)) && [[ " ${updated[*]} " != *" rpi "* ]]; then
        gh_warning "--update-library: no input rpi in $lock (the library itself has none)"
    fi
    if ((${#updated[@]})); then
        update "${updated[@]}" || fail "$RL_E_BUILD" "lock update of $host failed"
    elif ((update_lock)); then
        gh_warning "lock not updated: neither nixpkgs nor nixos-raspberrypi is an input (or an input of rpi) in $lock"
    fi
fi

# --- guards -----------------------------------------------------------------------
# guard: rl_guard on the toplevel; its dry run sees the host's cache too.
guard() {
    if [[ -n "$subst_conf" ]]; then
        NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG$nl}$subst_conf" rl_guard toplevel "$max"
    else
        rl_guard toplevel "$max"
    fi
}
guard_reason() {
    case "$1" in
    "$RL_E_CACHE") echo "the kernel is not in the nixos-raspberrypi cache" ;;
    "$RL_E_FORBIDDEN") echo "it would build the kernel or a toolchain locally" ;;
    "$RL_E_TOO_MANY") echo "more than $max local builds" ;;
    *) echo "evaluation or dry run failed" ;;
    esac
}

rc=0
guard || rc=$?
if ((rc == RL_E_CACHE && ${#updated[@]})); then
    git -C "$dir" checkout -- flake.lock
    np=() # nixpkgs and/or rpi/nixpkgs, when updated
    for u in "${updated[@]}"; do
        if [[ "$u" == nixpkgs || "$u" == rpi/nixpkgs ]]; then np+=("$u"); fi
    done
    if ((${#np[@]} && ${#np[@]} < ${#updated[@]})); then
        echo "ci/build.sh: kernel not cached after the update; retrying with nixpkgs only (${np[*]})" >&2
        update "${np[@]}" || fail "$RL_E_BUILD" "lock update of $host failed"
    else
        echo "ci/build.sh: kernel not cached after the update; building the committed lock" >&2
    fi
    rc=0
    guard || rc=$?
fi
if ((update_lock || update_library)); then
    # "INPUT `OLD` → `NEW`" for each input whose revision changed
    changes="$(awk 'NR == FNR { if ($1 != "") b[$1] = $2; next }
        { o = ($1 in b) ? b[$1] : "-" } o != $2 { printf "%s%s `%s` → `%s`", sep, $1, o, $2; sep = "; " }' \
        <(printf '%s\n' "$revs_before") <(lock_revs))"
    lock_state="${changes:+updated ($changes)}"
    lock_state="${lock_state:-update requested, no change}"
fi
((rc == 0)) || fail "$rc" "$host: build guard failed: $(guard_reason "$rc")"

# --- build ------------------------------------------------------------------------
gh_group "build $host"
if ! top="$(nix build --accept-flake-config --no-link --print-out-paths "${subst[@]}" \
    "$(rl_conf_ref).config.system.build.toplevel")"; then
    gh_endgroup
    top=""
    fail "$RL_E_BUILD" "build of $host failed"
fi
gh_endgroup
df -h / >&2 || true

# --- the flake's checks for this system ---------------------------------------------
flake_str="$(jq -rn --arg s "$dir" '$s | tojson | gsub("\\$"; "\\$")')"
checks_json="$(nix eval --accept-flake-config --impure --json --expr \
    "let f = builtins.getFlake $flake_str; s = builtins.currentSystem; in
     { system = s; checks = builtins.attrNames (f.checks.\${s} or { }); }")" ||
    fail "$RL_E_BUILD" "cannot evaluate the checks of $dir"
sys="$(jq -r '.system' <<<"$checks_json")"
mapfile -t checks < <(jq -r '.checks[]' <<<"$checks_json")
if ((${#checks[@]} == 0)); then
    gh_notice "no checks for $sys"
    checks_line="none for $sys"
else
    refs=()
    for c in "${checks[@]}"; do refs+=("$dir#checks.$sys.$c"); done
    gh_group "checks $host"
    if ! nix build --accept-flake-config --no-link -L "${subst[@]}" "${refs[@]}"; then
        gh_endgroup
        checks_line="failed ($sys: ${checks[*]})"
        fail "$RL_E_BUILD" "checks failed for $host (checks.$sys: ${checks[*]})"
    fi
    gh_endgroup
    checks_line="$sys: $(printf '%s, ' "${checks[@]}" | sed 's/, $//')"
fi

summary
echo "top=$top"
echo "name=$name"
