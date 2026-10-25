#!/usr/bin/env bash
#
# tests/workflows-lint.sh — lint of the CI workflow (check `actionlint`):
# actionlint (+ shellcheck on the run: blocks), and the workflow's invariants:
# the pointer is written only after push + pin; the unit tests and shellcheck
# run between build and publish (final review S5); main only (N6); every
# action pinned by full commit SHA with its tag in a trailing comment, no
# signing key or auth token handed to an action (ci/publish.sh gets them via
# env), and dependabot keeps the pins current (S4).
#
#   bash tests/workflows-lint.sh      (needs actionlint and shellcheck on PATH)
#
# Runs on the repository root (the directory above this script). Prints a
# FAIL line and exits 1 on the first violation.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

w=.github/workflows/neptun.yml
actionlint -no-color $w
# l STR: the first non-comment line of the workflow containing STR
l() { grep -n -F -- "$1" $w | grep -vE '^[0-9]+: *#' | head -n1 | cut -d: -f1; }
[ "$(l ci/publish.sh)" -lt "$(l ci/pointer.sh)" ] && [ "$(l ci/pointer.sh)" -lt "$(l ci/commit-push.sh)" ] \
  || { echo "FAIL: pointer is written after push + pin"; exit 1; }
# Final review S5: the unit tests and shellcheck pass before
# anything is published (after the build: the updated lock).
for c in rpi-deploy-syntax rpi-pull-unit rpi-ci-unit rpi-deploy-unit; do
  [ -n "$(l ".#checks.aarch64-linux.$c")" ] && [ "$(l ci/build.sh)" -lt "$(l ".#checks.aarch64-linux.$c")" ] \
    && [ "$(l ".#checks.aarch64-linux.$c")" -lt "$(l ci/publish.sh)" ] \
    || { echo "FAIL: checks.aarch64-linux.$c does not run between build and publish"; exit 1; }
done
# Final review N6: the whole job runs on main only (it builds and
# pins main whatever the ref; elsewhere it would only rotate pins).
grep -qxF "    if: github.ref == 'refs/heads/main'" $w \
  || { echo "FAIL: the job is not guarded to refs/heads/main"; exit 1; }
grep -qE '^ *(- )?uses:' $w || { echo "FAIL: no uses: lines found"; exit 1; }
unpinned=$(grep -nE '^ *(- )?uses:' $w | grep -vE 'uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40} # [^ ]+$' || true)
[ -z "$unpinned" ] || { echo "FAIL: actions not pinned by commit SHA + '# tag':"; echo "$unpinned"; exit 1; }
! grep -nE '^ *(signingKey|authToken):' $w || { echo "FAIL: signingKey/authToken passed to an action"; exit 1; }
grep -qE '^ *- package-ecosystem: "?github-actions"?$' .github/dependabot.yml \
  || { echo "FAIL: .github/dependabot.yml does not update github-actions"; exit 1; }
