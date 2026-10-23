#!/usr/bin/env bash
#
# ci/commit-push.sh — commit the given paths (flake.lock, the pointer) as
# github-actions[bot] and push them to main of `origin`.
#
#   ci/commit-push.sh --message MSG PATH...
#
# - Runs only for GITHUB_REF=refs/heads/main (a run dispatched from another
#   branch must never push to main).
# - Paths that do not exist are skipped; nothing changed → `pushed=false`.
# - Commits are unsigned (an unattended job cannot sign). A rejected push
#   (main moved on) rebases once (`git pull --rebase origin main`) and
#   pushes again; a conflict aborts the rebase (work tree left clean) and
#   fails the job, so main and its pointer stay unchanged.
#
# stdout: `pushed=true|false` (for $GITHUB_OUTPUT); git output on stderr.
# Exit: 0 | 1 refused / rebase or push failed | 2 usage.
set -euo pipefail

BOT_NAME='github-actions[bot]'
BOT_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'

usage() { echo "usage: ci/commit-push.sh --message MSG PATH..."; }
die() { echo "ci/commit-push.sh: $*" >&2; exit 1; }
die_usage() { echo "ci/commit-push.sh: $1" >&2; usage >&2; exit 2; }

msg="" paths=()
while (($#)); do
    case "$1" in
    --message)
        (($# >= 2)) || die_usage "--message needs a value"
        msg="$2"
        shift 2
        ;;
    -h | --help) usage; exit 0 ;;
    -*) die_usage "unknown option '$1'" ;;
    *) paths+=("$1"); shift ;;
    esac
done
[[ -n "$msg" ]] || die_usage "missing --message"
((${#paths[@]})) || die_usage "no PATH given"

ref="${GITHUB_REF:-}"
[[ "$ref" == refs/heads/main ]] ||
    die "refusing to push: GITHUB_REF='$ref' is not refs/heads/main"

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
    echo "pushed=false"
    exit 0
fi

g commit -q -m "$msg" -- "${existing[@]}" >&2
if ! git push origin HEAD:main >&2; then
    echo "ci/commit-push.sh: push rejected; rebasing once onto origin/main" >&2
    if ! g pull --rebase --autostash origin main >&2; then
        git rebase --abort >&2 || true
        die "rebase onto origin/main failed (conflict?); nothing pushed"
    fi
    git push origin HEAD:main >&2 || die "push failed after the rebase"
fi
echo "pushed=true"
