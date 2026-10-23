#!/usr/bin/env bash
#
# rpi-autoupdate — weekly security update of the Pi, pushed from the build
# host (spec §3.4). Run by the systemd service of rpi.buildHost.autoUpdate;
# see `rpi-autoupdate --help` for a manual run.
#
# The user's checkout is never touched: the job works in a dedicated clone
# ($WORK/repo) of branch main of --repo and pushes its lock commit to branch
# auto-update of --repo. Every guard or build failure exits before the Pi is
# contacted, and nothing is pushed unless the whole run succeeded.
#
#   0. refuse if the user has auto-update checked out; clone, reset to main
#   1. nix flake update nixpkgs nixos-raspberrypi
#   2. cache guard: kernel + modules in nvmd's cachix; on a miss restore the
#      lock, update nixpkgs only and check again
#   3. build guard on a dry run (no kernel/toolchain, at most --max-builds)
#   4. build the toplevel (4 h bound; GC root $WORK/rpi-last-built)
#   5. --no-deploy, or the Pi already runs it: go to 8
#   6. nixos-rebuild boot --store-path NEW (the flake's pinned tool)
#   7. same kernel/initrd/modules as booted: switch; else shutdown -r TIME
#   8. commit the lock (if it changed), force-push it to auto-update
#
# Exit codes: RL_E_* of rpi-lib.sh (2 usage, 10 cache, 11 forbidden build,
# 12 too many builds, 13 lock update/eval/build, 14 Pi/deploy); 20 git.

set -uo pipefail

RPI_LIB="${RPI_LIB:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/rpi-lib.sh}"
# shellcheck source=rpi-lib.sh
source "$RPI_LIB" || { echo "rpi-autoupdate: cannot load $RPI_LIB" >&2; exit 2; }

AU_E_GIT=20
LOCK=nixos/flake.lock

usage() {
    cat <<'EOF'
usage: rpi-autoupdate --repo PATH --work-dir PATH [--target USER@HOST] [--port N]
                      [--ssh-key PATH] [--max-builds N] [--reboot-time HH:MM] [--no-deploy]

Updates nixpkgs + nixos-raspberrypi in a dedicated clone (WORK/repo) of branch
main of --repo, checks that the kernel is cached and that nothing heavy would
be built, builds the system, deploys it (boot, then switch; or a reboot at
--reboot-time when kernel/initrd/modules change) and force-pushes the lock
commit to branch auto-update of --repo. The checkout of --repo is never touched.

  --repo PATH          the user's repository (flake in nixos/)
  --work-dir PATH      state: work clone, GC root, known_hosts of the Pi
  --target USER@HOST   default root@neptun
  --port N             sshd port of the Pi, default 2222
  --ssh-key PATH       private key for the Pi (required unless --no-deploy)
  --max-builds N       build guard limit, default 500
  --reboot-time HH:MM  reboot time after a kernel change, default 04:30
  --no-deploy          stop after the build: push the lock, never touch the Pi
EOF
}

log() { echo "rpi-autoupdate: $*" >&2; }
die() {
    local rc="$1"
    shift
    log "$*"
    exit "$rc"
}
usage_die() {
    log "$*"
    usage >&2
    exit "$RL_E_USAGE"
}

REPO="" WORK="" KEY="" TARGET=root@neptun PORT=2222 MAX=500 REBOOT_TIME=04:30 NO_DEPLOY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help) usage; exit 0 ;;
    --no-deploy) NO_DEPLOY=1; shift; continue ;;
    --repo | --work-dir | --target | --port | --ssh-key | --max-builds | --reboot-time)
        [[ $# -ge 2 ]] || usage_die "$1 needs a value" ;;
    *) usage_die "unknown argument: $1" ;;
    esac
    case "$1" in
    --repo) REPO="$2" ;;
    --work-dir) WORK="$2" ;;
    --target) TARGET="$2" ;;
    --port) PORT="$2" ;;
    --ssh-key) KEY="$2" ;;
    --max-builds) MAX="$2" ;;
    --reboot-time) REBOOT_TIME="$2" ;;
    esac
    shift 2
done

[[ -n "$REPO" && -n "$WORK" ]] || usage_die "--repo and --work-dir are required"
[[ "$PORT" =~ ^[0-9]+$ ]] || usage_die "--port must be a number"
[[ "$MAX" =~ ^[1-9][0-9]*$ ]] || usage_die "--max-builds must be a positive number"
[[ "$REBOOT_TIME" =~ ^[0-2][0-9]:[0-5][0-9]$ ]] || usage_die "--reboot-time must be HH:MM"
if ((!NO_DEPLOY)); then
    [[ -n "$KEY" ]] || usage_die "--ssh-key is required unless --no-deploy"
    [[ -r "$KEY" ]] || usage_die "ssh key not readable: $KEY"
    KEY="$(readlink -m -- "$KEY")"
fi
REPO="$(readlink -m -- "$REPO")" WORK="$(readlink -m -- "$WORK")"
# ssh options and NIX_SSHOPTS are word-split
[[ "$WORK$KEY" != *[[:space:]]* ]] || usage_die "--work-dir and --ssh-key must not contain whitespace"

CLONE="$WORK/repo"
RL_FLAKE="$CLONE/nixos" RL_TARGET="$TARGET" RL_SSH_PORT="$PORT"
# Unattended ssh (plan D9): only the dedicated key, no prompts, the Pi's host
# key pinned in the work dir on first contact (after a re-flash: delete
# $WORK/known_hosts). Extra options from RPI_SSH_OPTS are appended.
RL_SSH_OPTS="-i $KEY -o IdentitiesOnly=yes -o UserKnownHostsFile=$WORK/known_hosts"
RL_SSH_OPTS+=" -o StrictHostKeyChecking=accept-new -o BatchMode=yes${RPI_SSH_OPTS:+ $RPI_SSH_OPTS}"

# git in the work clone: no hooks, no signing, a fixed identity -- the user's
# global git config must neither break nor sign an unattended commit.
au_git() {
    GIT_AUTHOR_NAME=rpi-autoupdate GIT_AUTHOR_EMAIL=rpi-autoupdate@localhost \
        GIT_COMMITTER_NAME=rpi-autoupdate GIT_COMMITTER_EMAIL=rpi-autoupdate@localhost \
        git -c core.hooksPath=/dev/null -c commit.gpgsign=false -C "$CLONE" "$@"
}

# 0. the work clone, at the head of main
au_git_sync() {
    if [[ "$(git -C "$REPO" symbolic-ref -q --short HEAD)" == auto-update ]]; then
        die "$RL_E_USAGE" "branch auto-update is checked out in $REPO; check out another branch first"
    fi
    if [[ ! -d "$CLONE/.git" ]]; then
        mkdir -p "$WORK" && git -c core.hooksPath=/dev/null clone -q "$REPO" "$CLONE" ||
            die "$AU_E_GIT" "cannot clone $REPO"
    fi
    au_git remote set-url origin "$REPO" &&
        au_git fetch -q origin main &&
        au_git checkout -q -f -B auto-update origin/main ||
        die "$AU_E_GIT" "cannot reset the work clone to main of $REPO"
}

# 8. commit + push the lock
au_git_push() {
    if au_git diff --quiet -- "$LOCK"; then
        log "flake.lock unchanged: nothing to push"
        return 0
    fi
    au_git commit -q --no-verify -m "auto-update: flake.lock $(date -I)" -- "$LOCK" ||
        die "$AU_E_GIT" "cannot commit $LOCK"
    au_git push -q --no-verify --force origin HEAD:refs/heads/auto-update ||
        die "$AU_E_GIT" "cannot push to branch auto-update of $REPO"
    log "pushed $(au_git rev-parse --short HEAD) to branch auto-update of $REPO"
}

au_update() { nix flake update --accept-flake-config --flake "$RL_FLAKE" "$@"; }

# 6.-7. boot, then switch or a scheduled reboot
au_deploy() {
    local new="$1" booted
    log "installing $new as the boot default of $RL_TARGET"
    rl_nixos_rebuild boot --no-reexec --store-path "$new" --target-host "$RL_TARGET" ||
        die "$RL_E_DEPLOY" "nixos-rebuild boot failed (the running system is unchanged)"
    booted="$(rl_triplet_remote booted)" ||
        die "$RL_E_DEPLOY" "cannot read the booted kernel of $RL_TARGET"
    if rl_needs_reboot "$booted" "$(rl_triplet_local "$new")"; then
        log "kernel/initrd/modules changed: $RL_TARGET reboots at $REBOOT_TIME"
        rl_ssh shutdown -r "$REBOOT_TIME" || die "$RL_E_DEPLOY" "cannot schedule the reboot"
    else
        log "switching $RL_TARGET to $new"
        rl_nixos_rebuild switch --no-reexec --store-path "$new" --target-host "$RL_TARGET" ||
            die "$RL_E_DEPLOY" "nixos-rebuild switch failed"
    fi
}

au_git_sync

# 1.-3. lock update and guards (rl_guard: cache guard first, then the dry run)
log "updating nixpkgs and nixos-raspberrypi in $RL_FLAKE"
au_update nixpkgs nixos-raspberrypi || die "$RL_E_BUILD" "flake update failed"
rl_guard toplevel "$MAX"
rc=$?
if ((rc == RL_E_CACHE)); then
    log "the updated kernel is not cached: keeping nixos-raspberrypi as locked on main, updating nixpkgs only"
    au_git checkout -q -- "$LOCK" || die "$AU_E_GIT" "cannot restore $LOCK"
    au_update nixpkgs || die "$RL_E_BUILD" "flake update failed"
    rl_guard toplevel "$MAX"
    rc=$?
fi
((rc == 0)) || die "$rc" "guard failed (exit $rc); the Pi is untouched"

# 4. build
log "building $(rl_conf_ref) (at most 4 h)"
NEW="$(timeout 4h nix build --accept-flake-config --out-link "$WORK/rpi-last-built" \
    --print-out-paths "$(rl_conf_ref).config.system.build.toplevel")" && [[ -n "$NEW" ]] ||
    die "$RL_E_BUILD" "build failed or timed out; the Pi is untouched"

# 5. deploy unless asked not to or already current
if ((NO_DEPLOY)); then
    log "--no-deploy: not touching $RL_TARGET"
else
    CUR="$(rl_ssh readlink -f /run/current-system)" ||
        die "$RL_E_DEPLOY" "cannot reach $RL_TARGET; the Pi is untouched"
    if [[ "$CUR" == "$NEW" ]]; then
        log "$RL_TARGET already runs $NEW"
    else
        au_deploy "$NEW"
    fi
fi

au_git_push
log "done"
