#!/usr/bin/env bash
#
# ci/commit-push.sh — commit the given paths (flake.lock, the pointers) as
# github-actions[bot] and push them to main of `origin`.
#
#   ci/commit-push.sh --message MSG [--base REV --artifacts DIR] [PATH...]
#
# - Runs only for GITHUB_REF=refs/heads/main (a run dispatched from another
#   branch must never push to main).
# - --artifacts DIR: the commit job's download of the build jobs' artifacts,
#   one subdirectory per job, each with its flake.lock and, when published,
#   deploy/NAME.json (download-artifact extracts a lone artifact straight
#   into DIR: DIR/flake.lock or DIR/deploy/ → DIR is the only artifact).
#   Every job updates the lock itself (D14), so the locks
#   must be identical ("lock differs between hosts": exit 1, nothing
#   copied or pushed); a pointer name may come from one artifact only. The
#   lock and every pointer are copied into the work tree and committed with
#   the PATHs.
# - --base REV (required with --artifacts): the commit the build jobs built
#   (the hosts job's rev). This job checks out main later; when main's
#   flake.lock differs from REV's, a lock change landed during the build and
#   the artifacts' lock would silently revert it: refused (exit 1, nothing
#   copied or pushed; the run of that change builds it). Checked again
#   after a rebase, which would merge two locks that need not conflict.
# - Paths that do not exist are skipped; nothing changed → `pushed=false`.
# - Commits are unsigned (an unattended job cannot sign). A rejected push
#   (main moved on) rebases once (`git pull --rebase origin main`) and
#   pushes again; a conflict aborts the rebase (work tree left clean) and
#   fails the job, so main and its pointer stay unchanged.
#
# stdout: `pushed=true|false` (for $GITHUB_OUTPUT); git output on stderr.
# Under GitHub Actions also annotations and a step summary section.
# Exit: 0 | 1 refused / differing locks / bad artifact / rebase or push
# failed | 2 usage.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gh.sh
source "$HERE/gh.sh"

BOT_NAME='github-actions[bot]'
BOT_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'

usage() { echo "usage: ci/commit-push.sh --message MSG [--base REV --artifacts DIR] [PATH...]"; }
# summary LINE...: this step's summary section (GitHub Actions only)
summary() { { echo "## commit"; echo; printf '%s\n' "$@"; echo; } | gh_summary; }
die() { gh_error "$*"; summary "- failed: $*"; exit 1; }
die_usage() { echo "ci/commit-push.sh: $1" >&2; usage >&2; exit 2; }

msg="" art="" base="" paths=()
while (($#)); do
    case "$1" in
    --message | --artifacts | --base) (($# >= 2)) || die_usage "$1 needs a value" ;;&
    --message) msg="$2"; shift 2 ;;
    --artifacts) art="$2"; shift 2 ;;
    --base) base="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    -*) die_usage "unknown option '$1'" ;;
    *) paths+=("$1"); shift ;;
    esac
done
[[ -n "$msg" ]] || die_usage "missing --message"
[[ -n "$art" ]] || ((${#paths[@]})) || die_usage "neither --artifacts nor a PATH given"
[[ -z "$art" || -n "$base" ]] || die_usage "--artifacts needs --base REV (the commit the build jobs built)"

ref="${GITHUB_REF:-}"
[[ "$ref" == refs/heads/main ]] ||
    die "refusing to push: GITHUB_REF='$ref' is not refs/heads/main"

# lock_moved REF: REF's flake.lock differs from --base's (none: never)
lock_moved() { [[ -n "$base" ]] && ! git diff --quiet "$base" "$1" -- flake.lock; }
lock_moved_msg="flake.lock on main changed during the build (since $base): nothing committed; the run of that change builds and publishes it"
if [[ -n "$base" ]]; then
    git rev-parse -q --verify "$base^{commit}" >/dev/null ||
        die "--base $base is not a commit of this checkout"
    ! lock_moved HEAD || die "$lock_moved_msg"
fi

# The artifacts: check all of them before copying anything.
if [[ -n "$art" ]]; then
    [[ -d "$art" ]] || die "no artifacts directory '$art'"
    lock="" lock_from="" copies=()
    declare -A ptr_from=()
    if [[ -f "$art/flake.lock" || -d "$art/deploy" ]]; then dirs=("${art%/}/"); else dirs=("$art"/*/); fi
    for a in "${dirs[@]}"; do
        [[ -d "$a" ]] || continue
        a="${a%/}" an="${a##*/}"
        if [[ -f "$a/flake.lock" ]]; then
            if [[ -z "$lock" ]]; then
                lock="$a/flake.lock" lock_from="$an"
            elif ! cmp -s "$lock" "$a/flake.lock"; then
                die "flake.lock differs between hosts ($lock_from, $an): nothing committed"
            fi
        fi
        for p in "$a"/deploy/*; do
            [[ -e "$p" ]] || continue
            b="${p##*/}"
            [[ -f "$p" && "$b" =~ ^[A-Za-z0-9_-]+\.json$ ]] || die "$an: not a pointer deploy/NAME.json: deploy/$b"
            [[ -z "${ptr_from[$b]:-}" ]] ||
                die "deploy/$b is in more than one artifact (${ptr_from[$b]}, $an): nothing committed"
            ptr_from[$b]="$an"
            copies+=("$p" "deploy/$b")
        done
    done
    [[ -z "$lock" ]] || copies+=("$lock" flake.lock)
    for ((i = 0; i < ${#copies[@]}; i += 2)); do
        mkdir -p "$(dirname "${copies[i + 1]}")"
        cp -- "${copies[i]}" "${copies[i + 1]}"
        paths+=("${copies[i + 1]}")
    done
fi

# The bot identity for the commit and for the rebase of `pull --rebase`;
# GIT_* in the environment would override user.*, so set those too.
export GIT_AUTHOR_NAME="$BOT_NAME" GIT_AUTHOR_EMAIL="$BOT_EMAIL" \
    GIT_COMMITTER_NAME="$BOT_NAME" GIT_COMMITTER_EMAIL="$BOT_EMAIL"
g() { git -c user.name="$BOT_NAME" -c user.email="$BOT_EMAIL" -c commit.gpgsign=false "$@"; }

existing=()
for p in "${paths[@]}"; do
    if [[ -e "$p" ]]; then existing+=("$p"); else echo "ci/commit-push.sh: skipping missing $p" >&2; fi
done
if ((${#existing[@]})); then
    git add -- "${existing[@]}"
fi
if ((${#existing[@]} == 0)) || git diff --cached --quiet -- "${existing[@]}"; then
    echo "ci/commit-push.sh: nothing changed" >&2
    summary "- nothing changed: no commit"
    echo "pushed=false"
    exit 0
fi
files="$(git diff --cached --name-only -- "${existing[@]}" | xargs)"

g commit -q -m "$msg" -- "${existing[@]}" >&2
if ! git push origin HEAD:main >&2; then
    echo "ci/commit-push.sh: push rejected; rebasing once onto origin/main" >&2
    if ! g pull --rebase --autostash origin main >&2; then
        git rebase --abort >&2 || true
        die "rebase onto origin/main failed (conflict?); nothing pushed"
    fi
    ! lock_moved FETCH_HEAD || die "$lock_moved_msg"
    git push origin HEAD:main >&2 || die "push failed after the rebase"
fi
summary "- pushed \`$(git rev-parse --short HEAD)\` to main: $files"
echo "pushed=true"
