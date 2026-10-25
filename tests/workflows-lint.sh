#!/usr/bin/env bash
#
# tests/workflows-lint.sh — lint of the CI workflows (check `actionlint`):
# ours (.github/workflows/pi.yml) and the template's
# (templates/default/.github/workflows/pi.yml). actionlint (+ shellcheck on
# the run: blocks) on both, and their invariants:
# - the template's workflow is ours but runs rpi-ci of its `rpi` input
#   (`nix run --inputs-from . rpi#rpi-ci`) instead of `nix run .#rpi-ci` (P10);
# - build job: build < publish < pointer < upload-artifact (the pointer is
#   written only after push + pin; `rpi-ci build` also builds the flake's
#   checks before it prints its outputs, D16), the pointer step only when
#   published, one job per host (`name: build ${{ matrix.host }}`);
# - commit job: needs the build jobs (so it runs only when every build
#   succeeded, D14), download-artifact < `rpi-ci -- commit`;
# - hosts and commit run on main only (they build and pin main whatever the
#   ref; elsewhere a run would only rotate pins);
# - `contents: read` for the workflow, `contents: write` only in the commit
#   job: the build jobs hold the signing key and cannot push (D15);
# - every action pinned by full commit SHA with its tag in a trailing
#   comment, no signing key or auth token handed to an action (rpi-ci
#   publish gets them via env), dependabot keeps the pins current (S4);
# - no `working-directory` (the scripts take --flake, default $PWD).
#
#   bash tests/workflows-lint.sh      (needs actionlint and shellcheck on PATH)
#
# Runs on the repository root (the directory above this script). Prints a
# FAIL line and exits 1 on the first violation.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ours=.github/workflows/pi.yml
tpl=templates/default/.github/workflows/pi.yml
fail() { echo "FAIL: $*"; exit 1; }
for w in "$ours" "$tpl"; do [ -f "$w" ] || fail "$w is missing"; done
actionlint -no-color "$ours" "$tpl"

# P10: byte-for-byte ours once the template's rpi-ci is the local one.
{ [ "$(grep -c 'rpi-ci -- ' "$tpl")" -gt 0 ] &&
  [ "$(grep -c 'rpi-ci -- ' "$tpl")" = "$(grep -c 'nix run --inputs-from \. rpi#rpi-ci -- ' "$tpl")" ] &&
  sed 's#nix run --inputs-from \. rpi\#rpi-ci#nix run .\#rpi-ci#g' "$tpl" | cmp -s - "$ours"; } ||
  fail "pi.yml is not the template's workflow with the local rpi-ci"

# job W NAME: the lines of job NAME of workflow W (`  NAME:` up to the next job)
job() {
  awk -v j="  $2:" '
    /^[^ #]/ { injobs = ($0 == "jobs:"); on = 0; next }
    injobs && /^  [^ #]/ { on = ($0 == j) }
    on' "$1"
}
# step ID < JOB: the lines of step `- id: ID` of a job text
step() { awk -v s="      - id: $1" '/^      - / { on = ($0 == s) } /^ {0,5}[^ ]/ { on = 0 } on'; }
# l STR < TEXT: the number of the first non-comment line containing STR
l() { grep -n -F -- "$1" | grep -vE '^[0-9]+: *#' | head -n1 | cut -d: -f1; }
# before TEXT A B: A and B occur, A on an earlier line than B
before() {
  local a b
  a=$(printf '%s\n' "$1" | l "$2") b=$(printf '%s\n' "$1" | l "$3")
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
main_only="    if: github.ref == 'refs/heads/main'"

for w in "$ours" "$tpl"; do
  hosts=$(job "$w" hosts) build=$(job "$w" build) commit=$(job "$w" commit)
  [ -n "$hosts" ] && [ -n "$build" ] && [ -n "$commit" ] || fail "$w: jobs hosts, build, commit expected"

  before "$build" "rpi-ci -- build" "rpi-ci -- publish" || fail "$w: rpi-ci build does not run before publish"
  before "$build" "rpi-ci -- publish" "rpi-ci -- pointer" || fail "pointer is written after push + pin ($w)"
  before "$build" "rpi-ci -- pointer" "actions/upload-artifact@" || fail "$w: the pointer is not uploaded after it is written"
  printf '%s\n' "$build" | step pointer | grep -qxF "        if: steps.publish.outputs.published == 'true'" ||
    fail "$w: the pointer step does not run only when published"
  # shellcheck disable=SC2016 # the literal GitHub expression
  printf '%s\n' "$build" | grep -qxF '    name: build ${{ matrix.host }}' ||
    fail "$w: the build job is not named 'build \${{ matrix.host }}'"

  printf '%s\n' "$commit" | grep -qE '^    needs: .*\bbuild\b' || fail "$w: the commit job does not need the build jobs"
  before "$commit" "actions/download-artifact@" "rpi-ci -- commit" ||
    fail "$w: the commit job does not commit the downloaded artifacts"

  for j in hosts commit; do
    job "$w" $j | grep -qxF "$main_only" || fail "$w: job $j is not guarded to refs/heads/main"
  done

  # D15: read for the workflow; the one write is the commit job's contents.
  [ "$(awk '/^[^ #]/ { on = ($0 == "permissions:"); next } on' "$w")" = "  contents: read" ] ||
    fail "only the commit job may write ($w: workflow permissions are not 'contents: read')"
  writes=$(grep -nE '(: *write|write-all)' "$w" | grep -vE '^[0-9]+: *#' || true)
  { [ "$(printf '%s\n' "$writes" | grep -c .)" = 1 ] &&
    printf '%s\n' "$commit" | grep -A1 -xF '    permissions:' | grep -qxF '      contents: write'; } ||
    fail "only the commit job may write ($w)"

  grep -qE '^ *(- )?uses:' "$w" || fail "$w: no uses: lines found"
  unpinned=$(grep -nE '^ *(- )?uses:' "$w" | grep -vE 'uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40} # [^ ]+$' || true)
  [ -z "$unpinned" ] || fail "$w: actions not pinned by commit SHA + '# tag':"$'\n'"$unpinned"
  ! grep -nE '^ *(signingKey|authToken):' "$w" || fail "$w: signingKey/authToken passed to an action"
  ! grep -n 'working-directory' "$w" || fail "$w: working-directory (pass --flake instead)"
done

for d in .github/dependabot.yml templates/default/.github/dependabot.yml; do
  { [ -f "$d" ] && grep -qE '^ *- package-ecosystem: "?github-actions"?$' "$d"; } ||
    fail "$d does not update github-actions"
done
