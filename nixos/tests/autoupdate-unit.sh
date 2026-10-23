#!/usr/bin/env bash
#
# Unit tests for rpi-autoupdate.sh (check `autoupdate-unit`).
#
#   RPI_AUTOUPDATE_SRC=rpi-autoupdate.sh RPI_LIB=rpi-lib.sh FIXTURES=tests/fixtures \
#     bash tests/autoupdate-unit.sh
#
# (all three default to the files next to this test, so a plain
# `bash tests/autoupdate-unit.sh` works in a checkout).
#
# nix, ssh, timeout and nixos-rebuild are mocks (see tests/harness.sh); git and
# coreutils are real. Every case gets its own throwaway "user repository"
# (branch main, nixos/flake.lock, uncommitted user changes) and work dir under
# the test's temp dir; nothing outside it is read or written.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RPI_AUTOUPDATE_SRC="${RPI_AUTOUPDATE_SRC:-$HERE/../rpi-autoupdate.sh}"
export RPI_LIB="${RPI_LIB:-$HERE/../rpi-lib.sh}"
FIXTURES="${FIXTURES:-$HERE/fixtures}"

# shellcheck source=tests/harness.sh
source "$HERE/harness.sh"
export BASH_BIN

# The caller's environment must not leak into the tests.
unset RPI_FLAKE RPI_SSH_OPTS RPI_NIXOS_REBUILD RPI_CACHE_URL \
    RL_FLAKE RL_ATTR RL_TARGET RL_SSH_PORT RL_SSH_OPTS RL_CACHE_URL RL_STORE_DIR NIX_SSHOPTS

export FIX_HYB="$FIXTURES/dry-run-hybrid.txt" FIX_KER="$FIXTURES/dry-run-kernel.txt"
export STORE="$T/store" POISON_LOG="$T/poison.log"
mkdir -p "$STORE"
: >"$POISON_LOG"
NEWP="$STORE/new-nixos-system" # the system the build mock "builds"

# Kernel stacks: the old one (nvmd pin unchanged) and the one an nvmd update
# brings in.
export K_OLD=/nix/store/kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk0-linux_rpi-bcm2711-6.18.52
export M_OLD=/nix/store/mmmmmmmmmmmmmmmmmmmmmmmmmmmmmmm0-linux_rpi-bcm2711-6.18.52-modules
export K_NEW=/nix/store/kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk1-linux_rpi-bcm2711-6.18.60
export M_NEW=/nix/store/mmmmmmmmmmmmmmmmmmmmmmmmmmmmmmm1-linux_rpi-bcm2711-6.18.60-modules

# --- mocks -------------------------------------------------------------------
# nix:
#   flake update ... --flake DIR INPUTS  appends "locked by: ARGS" to DIR/flake.lock
#                          (MOCK_UPDATE_NOOP: no change; MOCK_UPDATE_RC: fails)
#   eval ...kernel(.modules).outPath     the NEW kernel iff the lock's last
#                          update included nixos-raspberrypi, else the OLD one
#   path-info --store URL P   MOCK_CACHE: hit (default) | full-miss (the NEW
#                          kernel is not cached) | always-miss
#   build --dry-run        cat $MOCK_DRY (default: hybrid fixture) to stderr
#                          (MOCK_DRY_RC: eval error)
#   build --print-out-paths  creates $NEWP, a fake toplevel (tests/make-sys.sh)
#                          with the parts MOCK_NEW (e.g. "kernel=2 fw=2";
#                          default: the booted system's), the --out-link,
#                          prints $NEWP (MOCK_BUILD_RC: fails)
#   run                    the pinned nixos-rebuild (logged only)
mock nix <<'EOF'
arg_after() { local prev="" a; for a in "${@:2}"; do [[ "$prev" == "$1" ]] && { printf '%s' "$a"; return; }; prev="$a"; done; }
case " $* " in
*" flake update "*)
    if [[ -n "${MOCK_UPDATE_RC:-}" ]]; then echo "error: unable to download 'https://github.com/...'" >&2; exit "$MOCK_UPDATE_RC"; fi
    [[ -n "${MOCK_UPDATE_NOOP:-}" ]] && exit 0
    printf 'locked by: %s\n' "$*" >>"$(arg_after --flake "$@")/flake.lock" ;;
*" eval "*".kernel.outPath "* | *" eval "*".kernel.modules.outPath "*)
    ref="${!#}"
    if tail -n1 "${ref%%#*}/flake.lock" | grep -q ' nixos-raspberrypi'; then k=$K_NEW m=$M_NEW; else k=$K_OLD m=$M_OLD; fi
    case " $* " in *".kernel.modules.outPath "*) printf '%s' "$m" ;; *) printf '%s' "$k" ;; esac ;;
*" path-info "*)
    p="${!#}" ok=1
    case "${MOCK_CACHE:-hit}" in
    full-miss) [[ "$p" == "$K_NEW" || "$p" == "$M_NEW" ]] && ok=0 ;;
    always-miss) ok=0 ;;
    esac
    if ((ok)); then echo "$p"; exit 0; fi
    echo "error: path '$p' is not valid" >&2
    exit 1 ;;
*" build "*" --dry-run "*)
    if [[ -n "${MOCK_DRY_RC:-}" ]]; then echo "error: attribute 'rpi' missing" >&2; exit "$MOCK_DRY_RC"; fi
    cat "${MOCK_DRY:-$FIX_HYB}" >&2 ;;
*" build "*" --print-out-paths "*)
    if [[ -n "${MOCK_BUILD_RC:-}" ]]; then echo "error: builder for 'x.drv' failed" >&2; exit "$MOCK_BUILD_RC"; fi
    new="$STORE/new-nixos-system"
    # MOCK_NEW: PART=TAG words, split on purpose
    "$BASH_BIN" "$MAKE_SYS" "$new" ${MOCK_NEW:-} || exit 96
    link="$(arg_after --out-link "$@")"
    [[ -n "$link" ]] && ln -sfn "$new" "$link"
    echo "$new" ;;
*" run "*) ;;
*) echo "nix mock: unexpected: $*" >&2; exit 97 ;;
esac
exit 0
EOF

# ssh: the Pi. current-system per MOCK_CUR; the booted system is the fake
# toplevel $MOCK_PI/run/booted-system (all parts tag 1, the Pi's /nix/store
# is $FX_STORE) for the fingerprint script (bash -s; MOCK_FP_RC fails it);
# sync (MOCK_SYNC_RC fails it) and shutdown accepted. MOCK_SSH_RC: unreachable.
mock ssh <<'EOF'
if [[ -n "${MOCK_SSH_RC:-}" ]]; then echo "ssh: connect to host neptun port 2222: No route to host" >&2; exit "$MOCK_SSH_RC"; fi
a=("$@")
case " $* " in
*" readlink -f /run/current-system "*) echo "${MOCK_CUR:-/nix/store/cccccccccccccccccccccccccccccccc-nixos-system-old}" ;;
*" bash -s -- "*" /nix/store ")
    [[ -z "${MOCK_FP_RC:-}" ]] || exit "$MOCK_FP_RC"
    exec bash -s -- "$MOCK_PI${a[-2]}" "$FX_STORE" ;;
*" sync ") exit "${MOCK_SYNC_RC:-0}" ;;
*" shutdown -r "*) ;;
*) echo "ssh mock: unexpected: $*" >&2; exit 97 ;;
esac
EOF
export MOCK_PI="$T/pi" RL_STORE_DIR="$FX_STORE"
mkdir -p "$MOCK_PI/run"
make_sys "$T/booted-sys"
ln -sfn "$T/booted-sys" "$MOCK_PI/run/booted-system"

# The pinned nixos-rebuild (RPI_NIXOS_REBUILD): logs argv and NIX_SSHOPTS;
# fails for the action named in MOCK_NR_FAIL.
mock nr-mock <<'EOF'
printf 'nr-opts %s\n' "${NIX_SSHOPTS:-}" >>"$MOCK_LOG"
[[ "$1" == "${MOCK_NR_FAIL:-}" ]] && { echo "error: activation failed" >&2; exit 1; }
exit 0
EOF
export RPI_NIXOS_REBUILD="$BIN/nr-mock"

# The host's nixos-rebuild must never run.
mock nixos-rebuild <<'EOF'
echo "POISON nixos-rebuild $*" >>"$POISON_LOG"
exit 1
EOF

# timeout: logged, then runs the command (the build's 4 h bound is visible).
mock timeout <<'EOF'
shift
exec "$@"
EOF

# --- helpers -----------------------------------------------------------------
# new_case NAME: fresh user repo $R (main + nixos/flake.lock, plus
# uncommitted user changes), work dir $W (absent), key $KEY; empty mock log.
new_case() {
    local d="$T/case-$1"
    R="$d/repo" W="$d/work" KEY="$d/id_test"
    mkdir -p "$R/nixos"
    : >"$KEY"
    git -C "$R" init -q -b main
    printf 'lock v0\n' >"$R/nixos/flake.lock"
    printf '{ }\n' >"$R/nixos/flake.nix"
    git -C "$R" add -A
    git -C "$R" commit -q -m init
    printf 'notes\n' >"$R/notes.txt"                # untracked
    printf '{ dirty = true; }\n' >"$R/nixos/flake.nix" # modified, uncommitted
    reset_log
}

au() { "$BASH_BIN" "$RPI_AUTOUPDATE_SRC" "$@"; }
au_std() { au --repo "$R" --work-dir "$W" --ssh-key "$KEY" "$@"; }

ref_of() { git -C "$R" rev-parse -q --verify "refs/heads/$1" || echo none; }

# first_line ERE: line number of the first matching mock-log line (999999 if none)
first_line() { grep -nE -- "$1" "$MOCK_LOG" | head -n1 | cut -d: -f1 | grep . || echo 999999; }

# untouched NAME BEFORE: P11 -- no ssh / nixos-rebuild call, auto-update ref
# still BEFORE.
untouched() {
    expect_eq "$1: no ssh / nixos-rebuild call" 0 "$(log_count '^(ssh|nr-mock|nix run) ')"
    expect_eq "$1" "$2" "$(ref_of auto-update)"
}

# tree_hash: hash of the user's working tree (all files outside .git).
tree_hash() {
    (cd "$R" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha256sum) | sha256sum
}

# =============================================================================
# CLI
# =============================================================================
new_case cli
run_cmd c1 -- au --help
expect_exit "c1 --help exits 0" 0
expect_grepf "c1 usage" "rpi-autoupdate --repo PATH --work-dir PATH"
expect_grepf "c1 usage lists --no-deploy" "--no-deploy"

run_cmd c2 -- au
expect_exit "c2 no args -> usage error" 2

run_cmd c3 -- au --repo "$R" --work-dir "$W"
expect_exit "c3 --ssh-key is required unless --no-deploy" 2
expect_grepf "c3 names the missing option" "--ssh-key" "$ERR"

run_cmd c4 -- au_std --reboot-time 4:30
expect_exit "c4 --reboot-time must be HH:MM" 2
for t in 24:00 29:59 12:60; do
    run_cmd c4 -- au_std --reboot-time "$t"
    expect_exit "c4 --reboot-time $t is no time of day" 2
done

run_cmd c5 -- au_std --max-builds 0
expect_exit "c5 --max-builds must be a positive number" 2
run_cmd c5 -- au_std --port abc
expect_exit "c5 --port must be a number" 2

run_cmd c6 -- au_std --bogus
expect_exit "c6 unknown option -> usage error" 2

run_cmd c7 -- au --repo "$R" --work-dir "$W" --ssh-key "$T/no-such-key"
expect_exit "c7 unreadable ssh key -> usage error" 2

run_cmd c8 -- au --repo "$R" --work-dir "$T/sp ace" --no-deploy
expect_exit "c8 whitespace in the work dir -> usage error (ssh options are word-split)" 2

expect_eq "c9 usage errors do nothing" 0 "$(log_count .)"
expect_true "c9 usage errors create no work clone" test ! -e "$W"

# =============================================================================
# Success paths
# =============================================================================
# a1 userspace-only change (same boot fingerprint as booted): switch only --
# the bootloader (vfat NIXOS_BOOT) is installed once -- then sync; lock pushed.
new_case a1
run_cmd a1 -- au_std
expect_exit "a1 userspace-only update exits 0" 0
f=$(first_line '^ssh .* bash -s -- /run/booted-system /nix/store$')
s=$(first_line '^nr-mock switch ') y=$(first_line '^ssh .* sync$')
expect_true "a1 booted fingerprint read before the switch" test "$f" -lt "$s" -a "$s" -ne 999999
expect_true "a1 sync after the switch" test "$s" -lt "$y" -a "$y" -ne 999999
expect_eq "a1 no boot step" 0 "$(log_count '^nr-mock boot ')"
expect_eq "a1 one sync" 1 "$(log_count '^ssh .* sync$')"
expect_eq "a1 no reboot scheduled" 0 "$(log_count '^ssh .*shutdown')"
expect_grepf "a1 switch: pinned tool, store path, target" \
    "nr-mock switch --no-reexec --store-path $NEWP --target-host root@neptun" "$MOCK_LOG"
expect_grep "a1 updates nixpkgs and nixos-raspberrypi in the work clone" \
    "^nix flake update .*--flake $W/repo/nixos nixpkgs nixos-raspberrypi$" "$MOCK_LOG"
expect_eq "a1 auto-update = work clone HEAD" "$(git -C "$W/repo" rev-parse HEAD)" "$(ref_of auto-update)"
expect_eq "a1 auto-update is main + 1 commit" "$(ref_of main)" "$(git -C "$R" rev-parse auto-update^)"
expect_eq "a1 the commit changes only nixos/flake.lock" "nixos/flake.lock" \
    "$(git -C "$R" diff --name-only main auto-update)"
git -C "$R" log -1 --format=%s auto-update >"$T/subject"
expect_grep "a1 commit subject" '^auto-update: flake\.lock [0-9]{4}-[0-9]{2}-[0-9]{2}$' "$T/subject"
expect_eq "a1 committed as rpi-autoupdate" "rpi-autoupdate <rpi-autoupdate@localhost>" \
    "$(git -C "$R" log -1 --format='%an <%ae>' auto-update)"
expect_eq "a1 committer is rpi-autoupdate" "rpi-autoupdate <rpi-autoupdate@localhost>" \
    "$(git -C "$R" log -1 --format='%cn <%ce>' auto-update)"
expect_grepf "a1 pushed lock is the updated one" "nixpkgs nixos-raspberrypi" \
    <(git -C "$R" show auto-update:nixos/flake.lock)
expect_eq "a1 user's branch still main" main "$(git -C "$R" symbolic-ref --short HEAD)"

# a2 kernel change: boot, sync, then a scheduled reboot instead of switch.
new_case a2
MOCK_NEW="kernel=2" run_cmd a2 -- au_std
expect_exit "a2 kernel update exits 0" 0
expect_true "a2 kernel change schedules reboot, no switch" \
    test "$(log_count '^ssh .* shutdown -r 04:30$')" -eq 1 -a "$(log_count '^nr-mock switch ')" -eq 0
expect_grepf "a2 boot: pinned tool, store path, target" \
    "nr-mock boot --no-reexec --store-path $NEWP --target-host root@neptun" "$MOCK_LOG"
b=$(first_line '^nr-mock boot ') y=$(first_line '^ssh .* sync$') r=$(first_line '^ssh .* shutdown -r')
expect_true "a2 boot, then sync, then the reboot" test "$b" -lt "$y" -a "$y" -lt "$r" -a "$r" -ne 999999
expect_grepf "a2 says what changed" "changed since boot: kernel" "$ERR"
expect_true "a2 lock pushed" test "$(ref_of auto-update)" != none

new_case a2i
MOCK_NEW="initrd=2" run_cmd a2i -- au_std --reboot-time 05:15
expect_exit "a2i initrd update exits 0" 0
expect_true "a2i initrd change schedules reboot at --reboot-time, no switch" \
    test "$(log_count '^ssh .* shutdown -r 05:15$')" -eq 1 -a "$(log_count '^nr-mock switch ')" -eq 0
new_case a2t
MOCK_NEW="initrd=2" run_cmd a2t -- au_std --reboot-time 23:59
expect_exit "a2t --reboot-time 23:59 is valid" 0
expect_eq "a2t reboot at 23:59" 1 "$(log_count '^ssh .* shutdown -r 23:59$')"

# a2x every other boot-critical part (S1): modules, device trees, kernel
# parameters, and the FAT's firmware, config.txt and u-boot -- these are not
# generational, so a reboot right after the update attributes any breakage.
for part in modules dtbs params fw cfg uboot; do
    new_case "a2x-$part"
    MOCK_NEW="$part=2" run_cmd a2x -- au_std
    expect_exit "a2x $part update exits 0" 0
    expect_true "a2x $part change: boot + sync + reboot, no switch" \
        test "$(log_count '^nr-mock boot ')" -eq 1 -a "$(log_count '^ssh .* sync$')" -eq 1 -a \
        "$(log_count '^ssh .* shutdown -r ')" -eq 1 -a "$(log_count '^nr-mock switch ')" -eq 0
done

# a2e only the extlinux builder changed (it writes /boot, generational): switch.
new_case a2e
MOCK_NEW="ext=2" run_cmd a2e -- au_std
expect_true "a2e extlinux builder change: switch, no boot, no reboot" \
    test "$(log_count '^nr-mock switch ')" -eq 1 -a "$(log_count '^nr-mock boot ')" -eq 0 -a \
    "$(log_count 'shutdown')" -eq 0

# a3 the Pi already runs the new system: no deploy, lock still pushed.
new_case a3
MOCK_CUR="$NEWP" run_cmd a3 -- au_std
expect_exit "a3 up to date exits 0" 0
expect_eq "a3 no nixos-rebuild call" 0 "$(log_count '^(nr-mock|nix run) ')"
expect_eq "a3 no reboot" 0 "$(log_count 'shutdown')"
expect_eq "a3 lock committed and pushed" "$(git -C "$W/repo" rev-parse HEAD)" "$(ref_of auto-update)"

# a4 the updated nvmd kernel is not cached: restore the lock, nixpkgs only.
new_case a4
MOCK_CACHE=full-miss run_cmd a4 -- au_std
expect_exit "a4 cache fallback exits 0" 0
u1=$(first_line '^nix flake update .* nixpkgs nixos-raspberrypi$') u2=$(first_line '^nix flake update .* nixpkgs$')
expect_true "a4 full update first, then nixpkgs only" test "$u1" -lt "$u2" -a "$u2" -ne 999999
expect_not_grep "a4 pushed lock has no nixos-raspberrypi update" "nixos-raspberrypi" \
    <(git -C "$R" show auto-update:nixos/flake.lock)
expect_eq "a4 pushed lock = main's lock + the nixpkgs update" 2 \
    "$(git -C "$R" show auto-update:nixos/flake.lock | wc -l)"
expect_eq "a4 deployed" 1 "$(log_count '^nr-mock (boot|switch) ')"

# =============================================================================
# Failure paths (P11: exit before touching the Pi, auto-update unchanged)
# =============================================================================
# p11_case NAME: new case with a pre-existing auto-update branch.
p11_case() {
    new_case "$1"
    git -C "$R" branch auto-update
    BEFORE="$(ref_of auto-update)"
}

p11_case a5
MOCK_CACHE=always-miss run_cmd a5 -- au_std
expect_exit "a5 kernel never cached -> RL_E_CACHE" 10
untouched "a5 guard failure leaves auto-update ref unchanged" "$BEFORE"
expect_eq "a5 nothing built" 0 "$(log_count '^(timeout|nix build)')"

p11_case a6
MOCK_DRY="$FIX_KER" run_cmd a6 -- au_std
expect_exit "a6 kernel build -> RL_E_FORBIDDEN" 11
untouched "a6 forbidden build leaves auto-update ref unchanged" "$BEFORE"
expect_eq "a6 nothing built" 0 "$(log_count '^timeout')"

p11_case a7
run_cmd a7 -- au_std --max-builds 300
expect_exit "a7 377 > 300 builds -> RL_E_TOO_MANY" 12
untouched "a7 too many builds leaves auto-update ref unchanged" "$BEFORE"
expect_grepf "a7 reports the count" "377 > 300" "$ERR"

p11_case a8
MOCK_BUILD_RC=1 run_cmd a8 -- au_std
expect_exit "a8 build failure -> RL_E_BUILD" 13
untouched "a8 build failure leaves auto-update ref unchanged" "$BEFORE"

p11_case a8u
MOCK_UPDATE_RC=1 run_cmd a8u -- au_std
expect_exit "a8u lock update failure -> RL_E_BUILD" 13
untouched "a8u lock update failure leaves auto-update ref unchanged" "$BEFORE"

p11_case a8d
MOCK_DRY_RC=1 run_cmd a8d -- au_std
expect_exit "a8d dry-run eval error -> RL_E_BUILD" 13
untouched "a8d eval error leaves auto-update ref unchanged" "$BEFORE"

# Pi unreachable / deploy failures: built, but nothing pushed.
p11_case a15
MOCK_NEW="kernel=2" MOCK_NR_FAIL=boot run_cmd a15 -- au_std
expect_exit "a15 boot failure -> RL_E_DEPLOY" 14
expect_eq "a15 no switch, no reboot" 0 "$(log_count '^nr-mock switch |shutdown')"
expect_eq "a15 boot failure leaves auto-update ref unchanged" "$BEFORE" "$(ref_of auto-update)"
expect_eq "a15 still syncs (the bootloader may be written)" 1 "$(log_count '^ssh .* sync$')"

p11_case a15s
MOCK_NR_FAIL=switch run_cmd a15s -- au_std
expect_exit "a15s switch failure -> RL_E_DEPLOY" 14
expect_eq "a15s switch failure leaves auto-update ref unchanged" "$BEFORE" "$(ref_of auto-update)"

p11_case a15f
MOCK_FP_RC=1 run_cmd a15f -- au_std
expect_exit "a15f booted fingerprint unreadable -> RL_E_DEPLOY" 14
expect_eq "a15f no nixos-rebuild call" 0 "$(log_count '^(nr-mock|nix run) ')"
expect_eq "a15f leaves auto-update ref unchanged" "$BEFORE" "$(ref_of auto-update)"

p11_case a15y
MOCK_NEW="kernel=2" MOCK_SYNC_RC=1 run_cmd a15y -- au_std
expect_exit "a15y sync failure after boot -> RL_E_DEPLOY" 14
expect_eq "a15y no reboot scheduled" 0 "$(log_count 'shutdown')"
expect_eq "a15y leaves auto-update ref unchanged" "$BEFORE" "$(ref_of auto-update)"

p11_case a20
MOCK_SSH_RC=255 run_cmd a20 -- au_std
expect_exit "a20 Pi unreachable -> RL_E_DEPLOY" 14
expect_eq "a20 no nixos-rebuild call" 0 "$(log_count '^(nr-mock|nix run) ')"
expect_eq "a20 unreachable Pi leaves auto-update ref unchanged" "$BEFORE" "$(ref_of auto-update)"

# =============================================================================
# --no-deploy (AC5), the user's checkout, the work clone
# =============================================================================
new_case a9
run_cmd a9 -- au --repo "$R" --work-dir "$W" --no-deploy
expect_exit "a9 --no-deploy exits 0 (no --ssh-key needed)" 0
expect_eq "a9 no ssh / nixos-rebuild call" 0 "$(log_count '^(ssh|nr-mock|nix run) ')"
expect_eq "a9 built the toplevel" 1 "$(log_count '^timeout 4h nix build ')"
expect_eq "a9 lock committed and pushed" "$(git -C "$W/repo" rev-parse HEAD)" "$(ref_of auto-update)"

# a10 P12: the user's checkout is byte-identical, main unchanged.
new_case a10
h0="$(tree_hash)" m0="$(ref_of main)" s0="$(git -C "$R" status --porcelain)"
run_cmd a10 -- au_std
expect_exit "a10 run exits 0" 0
expect_eq "a10 user working tree byte-identical" "$h0" "$(tree_hash)"
expect_eq "a10 main unchanged" "$m0" "$(ref_of main)"
expect_eq "a10 git status unchanged" "$s0" "$(git -C "$R" status --porcelain)"

# a11 refuses when the user has auto-update checked out.
new_case a11
git -C "$R" checkout -q -b auto-update
a0="$(ref_of auto-update)"
run_cmd a11 -- au_std
expect_exit "a11 auto-update checked out -> usage error" 2
expect_grepf "a11 says why" "auto-update" "$ERR"
expect_eq "a11 nothing done" 0 "$(log_count .)"
expect_true "a11 no work clone" test ! -e "$W/repo"
expect_eq "a11 ref unchanged" "$a0" "$(ref_of auto-update)"

# a12 every ssh / nixos-rebuild invocation carries the unattended options.
new_case a12
MOCK_NEW="kernel=2" run_cmd a12 -- au_std
expect_exit "a12 run exits 0" 0
for opt in "-p 2222" "-i $KEY" "-o IdentitiesOnly=yes" "-o UserKnownHostsFile=$W/known_hosts" \
    "-o StrictHostKeyChecking=accept-new" "-o BatchMode=yes"; do
    n_ssh=$(log_count '^ssh ') n_nr=$(log_count '^nr-opts ')
    expect_true "a12 all $n_ssh ssh calls carry '$opt'" \
        test "$n_ssh" -ge 3 -a "$(grep -c -F -- " $opt " <(grep '^ssh ' "$MOCK_LOG"))" -eq "$n_ssh"
    expect_true "a12 all $n_nr NIX_SSHOPTS carry '$opt'" \
        test "$n_nr" -ge 1 -a "$(grep -c -F -- " $opt" <(grep '^nr-opts ' "$MOCK_LOG"))" -eq "$n_nr"
done
expect_grep "a12 NIX_SSHOPTS starts with the port" "^nr-opts -p 2222 " "$MOCK_LOG"

new_case a12t
run_cmd a12t -- au_std --target root@pi.example --port 22
expect_exit "a12t run exits 0" 0
expect_grep "a12t ssh honours --port/--target" "^ssh -p 22 .* root@pi\.example readlink" "$MOCK_LOG"
expect_grepf "a12t nixos-rebuild honours --target" "--target-host root@pi.example" "$MOCK_LOG"
expect_grep "a12t NIX_SSHOPTS honours --port" "^nr-opts -p 22 " "$MOCK_LOG"

# a13 a second run reuses the work clone, resets it to the new main and
# force-pushes (auto-update is not fast-forwardable between runs).
new_case a13
run_cmd a13 -- au_std
first="$(ref_of auto-update)"
git -C "$R" commit -q --allow-empty -m "user work on main"
printf 'garbage from a crashed run\n' >>"$W/repo/nixos/flake.lock"
reset_log
run_cmd a13 -- au_std
expect_exit "a13 second run exits 0" 0
expect_eq "a13 auto-update is the new main + 1 commit" "$(ref_of main)" "$(git -C "$R" rev-parse auto-update^)"
expect_true "a13 auto-update was replaced" test "$(ref_of auto-update)" != "$first"
expect_not_grep "a13 leftovers in the work clone are discarded" "garbage" \
    <(git -C "$R" show auto-update:nixos/flake.lock)

# a14 the build: 4 h bound, GC root in the work dir, the work clone's toplevel.
new_case a14
run_cmd a14 -- au_std
expect_grep "a14 build is bounded to 4h, GC-rooted in the work dir" \
    "^timeout 4h nix build .*--out-link $W/rpi-last-built .*$W/repo/nixos#nixosConfigurations\.rpi\.config\.system\.build\.toplevel" "$MOCK_LOG"
expect_true "a14 GC root exists" test -L "$W/rpi-last-built"
expect_true "a14 guards (dry run) before the build" \
    test "$(first_line '^nix build .*--dry-run')" -lt "$(first_line '^timeout 4h nix build')"
expect_true "a14 cache check before the dry run" \
    test "$(first_line '^nix path-info ')" -lt "$(first_line '^nix build .*--dry-run')"

# a16 nothing new upstream and the Pi is current: no commit, no push.
new_case a16
MOCK_UPDATE_NOOP=1 MOCK_CUR="$NEWP" run_cmd a16 -- au_std
expect_exit "a16 no-op run exits 0" 0
expect_eq "a16 nothing pushed" none "$(ref_of auto-update)"
expect_grepf "a16 says the lock is unchanged" "flake.lock unchanged" "$ERR"

# a17 the user's global git config (signing, hooks) does not break the job.
new_case a17
mkdir -p "$T/hooks"
printf '#!%s\nexit 1\n' "$BASH_BIN" >"$T/hooks/pre-commit"
cp "$T/hooks/pre-commit" "$T/hooks/pre-push"
cp "$T/hooks/pre-commit" "$T/hooks/commit-msg"
cp "$T/hooks/pre-commit" "$T/hooks/post-checkout"
chmod +x "$T/hooks/"*
printf '[commit]\n\tgpgsign = true\n[gpg]\n\tprogram = false\n[core]\n\thooksPath = %s\n' "$T/hooks" >"$T/gitconfig"
GIT_CONFIG_GLOBAL="$T/gitconfig" run_cmd a17 -- au_std
expect_exit "a17 signing/hooks in the user's git config: exits 0" 0
expect_eq "a17 lock pushed unsigned" "$(git -C "$W/repo" rev-parse HEAD)" "$(ref_of auto-update)"

# a18 the user works on another branch: the job still builds on main.
new_case a18
git -C "$R" checkout -q -b feature
printf 'lock feature\n' >"$R/nixos/flake.lock"
git -C "$R" commit -q -am "feature lock"
run_cmd a18 -- au_std
expect_exit "a18 run exits 0" 0
expect_eq "a18 auto-update is main + 1 commit" "$(ref_of main)" "$(git -C "$R" rev-parse auto-update^)"
expect_eq "a18 user's branch untouched" feature "$(git -C "$R" symbolic-ref --short HEAD)"

# a19 without RPI_NIXOS_REBUILD: the work clone's pinned nixos-rebuild.
new_case a19
RPI_NIXOS_REBUILD="" run_cmd a19 -- au_std
expect_exit "a19 run exits 0" 0
expect_grepf "a19 switch via the work clone's pinned tool" \
    "nix run --accept-flake-config $W/repo/nixos#nixos-rebuild -- switch --no-reexec --store-path $NEWP" "$MOCK_LOG"
new_case a19b
MOCK_NEW="kernel=2" RPI_NIXOS_REBUILD="" run_cmd a19b -- au_std
expect_grepf "a19b boot via the work clone's pinned tool" \
    "nix run --accept-flake-config $W/repo/nixos#nixos-rebuild -- boot --no-reexec --store-path $NEWP" "$MOCK_LOG"

# a21 relative --repo / --work-dir are made absolute.
new_case a21
run_cmd a21 -- bash -c 'cd "$(dirname "$1")" && "$BASH_BIN" "$RPI_AUTOUPDATE_SRC" --repo repo --work-dir work --no-deploy' _ "$R"
expect_exit "a21 relative paths: exits 0" 0
expect_grep "a21 the flake is the absolute work clone" "^nix flake update .*--flake $W/repo/nixos " "$MOCK_LOG"
expect_eq "a21 lock pushed" "$(git -C "$W/repo" rev-parse HEAD)" "$(ref_of auto-update)"

expect_eq "the host's nixos-rebuild is never used" "" "$(cat "$POISON_LOG")"

summary
