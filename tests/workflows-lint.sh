#!/usr/bin/env bash
#
# tests/workflows-lint.sh — lint of the CI workflows (check `actionlint`):
# ours (.github/workflows/pi.yml) and the template's
# (templates/default/.github/workflows/pi.yml). actionlint (+ shellcheck on
# the run: blocks) on both, and their invariants:
# - the template's workflow is ours but takes rpi-ci from its `rpi` input
#   (`--inputs-from . rpi#rpi-ci`) instead of this flake (`.#rpi-ci`) (P10);
# - the build and commit jobs resolve rpi-ci once, before the lock update
#   (`nix build ... --out-link "$RUNNER_TEMP/rpi-ci"`), and call only that:
#   the Cachix secrets never meet library code the update brought in; the
#   library input moves only through the manual `update-library` input (S3);
# - build job: build < publish < pointer < upload-artifact (the pointer is
#   written only after push + pin; `rpi-ci build` also builds the flake's
#   checks before it prints its outputs, D16), the pointer step only when
#   published, one job per host (`name: build ${{ matrix.host }}`);
# - commit job: needs the build jobs (so it runs only when every build
#   succeeded, D14), download-artifact < `rpi-ci commit`;
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
{ n=$(grep -c 'rpi#rpi-ci' "$tpl") && [ "$n" -gt 0 ] &&
  [ "$n" = "$(grep -c -- '--inputs-from \. rpi#rpi-ci' "$tpl")" ] && ! grep -qF '.#rpi-ci' "$tpl" &&
  sed 's#--inputs-from \. rpi\#rpi-ci#.\#rpi-ci#g' "$tpl" | cmp -s - "$ours"; } ||
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
# shellcheck disable=SC2016 # the literal call in the workflows
RC='"$RUNNER_TEMP/rpi-ci/bin/rpi-ci"'

for w in "$ours" "$tpl"; do
  hosts=$(job "$w" hosts) build=$(job "$w" build) commit=$(job "$w" commit)
  [ -n "$hosts" ] && [ -n "$build" ] && [ -n "$commit" ] || fail "$w: jobs hosts, build, commit expected"

  before "$build" "$RC build" "$RC publish" || fail "$w: rpi-ci build does not run before publish"
  before "$build" "$RC publish" "$RC pointer" || fail "pointer is written after push + pin ($w)"
  before "$build" "$RC pointer" "actions/upload-artifact@" || fail "$w: the pointer is not uploaded after it is written"
  printf '%s\n' "$build" | step pointer | grep -qxF "        if: steps.publish.outputs.published == 'true'" ||
    fail "$w: the pointer step does not run only when published"
  # shellcheck disable=SC2016 # the literal GitHub expression
  printf '%s\n' "$build" | grep -qxF '    name: build ${{ matrix.host }}' ||
    fail "$w: the build job is not named 'build \${{ matrix.host }}'"

  printf '%s\n' "$commit" | grep -qE '^    needs: .*\bbuild\b' || fail "$w: the commit job does not need the build jobs"
  before "$commit" "actions/download-artifact@" "$RC commit" ||
    fail "$w: the commit job does not commit the downloaded artifacts"

  # S1 (final review): one base commit for the run. The hosts job names it,
  # every build job checks it out, the commit job refuses when main's
  # flake.lock moved away from it (rpi-ci commit --base).
  # shellcheck disable=SC2016 # literal GitHub expressions
  { printf '%s\n' "$hosts" | grep -qxF '      rev: ${{ steps.hosts.outputs.rev }}' &&
    printf '%s\n' "$hosts" | step hosts | grep -qF 'echo "rev=$(git rev-parse HEAD)" >> "$GITHUB_OUTPUT"'; } ||
    fail "$w: the hosts job does not output the run's base commit (rev)"
  # shellcheck disable=SC2016
  { [ "$(printf '%s\n' "$build" | grep -cE '^ +ref: ')" = 1 ] &&
    printf '%s\n' "$build" | grep -qxF '          ref: ${{ needs.hosts.outputs.rev }}'; } ||
    fail "$w: the build jobs do not check out the hosts job's rev"
  # shellcheck disable=SC2016
  { printf '%s\n' "$commit" | step commit | grep -qxF '          BASE: ${{ needs.hosts.outputs.rev }}' &&
    printf '%s\n' "$commit" | step commit | grep -qF "$RC commit --base \"\$BASE\" "; } ||
    fail "$w: the commit job does not pass the build's base (--base) to rpi-ci commit"

  # S3 (final review): rpi-ci resolved from the committed lock before the
  # lock update; build, publish (the secrets), pointer and commit call it.
  for j in build commit; do
    jt=$(job "$w" $j)
    tool=$(printf '%s\n' "$jt" | step rpi-ci)
    # shellcheck disable=SC2016 # literal $RUNNER_TEMP
    printf '%s\n' "$tool" | grep -qE '^        run: nix build (--inputs-from \. rpi#|\.#)rpi-ci --out-link "\$RUNNER_TEMP/rpi-ci"$' ||
      fail "$w: job $j does not resolve rpi-ci once (step rpi-ci: nix build ... --out-link \"\$RUNNER_TEMP/rpi-ci\")"
    { [ "$(printf '%s\n' "$jt" | grep -c 'nix build')" = 1 ] && ! printf '%s\n' "$jt" | grep -q 'nix run'; } ||
      fail "$w: job $j runs rpi-ci other than through $RC"
  done
  before "$build" "      - id: rpi-ci" "$RC build" || fail "$w: rpi-ci is not resolved before the lock update (build)"
  before "$commit" "      - id: rpi-ci" "$RC commit" || fail "$w: the commit job does not resolve rpi-ci first"
  # the library input moves only on the manual update-library input
  # shellcheck disable=SC2016
  { awk '/^    inputs:$/ { on = 1 } on' "$w" | grep -A3 -xF '      update-library:' | grep -qxF '        default: false' &&
    printf '%s\n' "$build" | step build | grep -qxF '          UPDATE_LIBRARY: ${{ inputs.update-library }}' &&
    [ "$(grep -c -- '--update-library' "$w")" = 1 ] &&
    printf '%s\n' "$build" | step build | grep -qxF '          if [ "$UPDATE_LIBRARY" = true ]; then set -- "$@" --update-library; fi'; } ||
    fail "$w: --update-library is not only the manual update-library input (default false)"

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
