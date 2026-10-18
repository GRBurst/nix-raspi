#!/usr/bin/env bash
#
# Unit tests for install.sh (rpi-install).
#
# Runs the real script against a mocked `nix` and `nixos-install`, so no
# real builds happen and no aarch64 emulation is needed in the test
# environment (binfmt locations are overridden via RPI_BINMFT_*).
#
# Invoked by the flake check `checks.x86_64-linux.rpi-install-unit`:
#
#   RPI_INSTALL_SRC=<path to install.sh> bash tests/install-unit.sh
#
# Exits non-zero if any test fails.

set -u

SCRIPT="${RPI_INSTALL_SRC:?RPI_INSTALL_SRC must point at install.sh}"
[[ -f "$SCRIPT" ]] || { echo "FAIL: script not found: $SCRIPT"; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# Hermetic git: ignore user/global config (e.g. commit.gpgsign) so the
# fixture repos commit without a GPG key in any environment.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0

# The mock executables below need an absolute interpreter path: in a nix
# build sandbox /usr/bin/env does not exist (util-linux is not part of
# stdenv), so `#!/usr/bin/env bash` shebangs would fail silently.
BASH_BIN="$(command -v bash)"

# --- mock environment --------------------------------------------------------
export MOCK_LOG="$T/mocks.log"
export MOCK_SYS="$T/mock-sys"
export MOCK_DRV="$T/mock-toplevel.drv"
export MOCK_COPY=1
: > "$MOCK_LOG"

BIN="$T/bin"
mkdir -p "$BIN"

# Mock `nix`:
#   show-config            -> prints extra-platforms (aarch64 only if
#                             MOCK_PLATFORMS contains it)
#   eval --raw ...         -> prints $MOCK_DRV
#   build ... --print-out-paths -> creates and prints $MOCK_SYS
#   ... copy --to STORE ...    -> (MOCK_COPY=1) creates STORE/store/<basename>
#                                  for each path argument after the target
#   everything else (build --print-build-logs) -> no-op
cat > "$BIN/nix" <<'MOCK'
#!BASHPLACEHOLDER
case " $* " in
  *" show-config "*)
    if [[ "${MOCK_PLATFORMS:-}" == *aarch64* ]]; then
      echo "extra-platforms = x86_64-linux aarch64-linux"
    else
      echo "extra-platforms = x86_64-linux"
    fi
    [[ "${MOCK_CACHE:-0}" == 1 ]] && echo "extra-substituters = https://nixos-raspberrypi.cachix.org"
    ;;
  *" eval --raw "*)
    printf '%s\n' "$MOCK_DRV"
    ;;
  *" --print-out-paths "*)
    mkdir -p "$MOCK_SYS"
    printf '%s\n' "$MOCK_SYS"
    ;;
  *" --print-build-logs "*)
    case "${MOCK_BUILD_FAIL:-}" in
      255) echo "error: builder for '/nix/store/x.drv' failed with exit code 255" ; exit 1 ;;
      oom) echo "Killed"; exit 1 ;;
    esac
    ;;
  *" copy "*" --to "*)
    if [[ "${MOCK_COPY:-1}" == 1 ]]; then
      state="pre"; target=""
      for a in "$@"; do
        case "$state" in
          pre)        [[ "$a" == "--to" ]] && state="wanttarget" ;;
          wanttarget) target="$a"; state="paths" ;;
          paths)      mkdir -p "$target/nix/store/$(basename "$a")" ;;
        esac
      done
    fi
    ;;
esac
exit 0
MOCK

# Mock `sudo`: runs the command unprivileged.
cat > "$BIN/sudo" <<'MOCK'
#!BASHPLACEHOLDER
exec "$@"
MOCK

# Mock `nixos-install`: records its args, succeeds.
cat > "$BIN/nixos-install" <<'MOCK'
#!BASHPLACEHOLDER
echo "nixos-install $*" >> "$MOCK_LOG"
exit 0
MOCK
sed -i "1s|^#!BASHPLACEHOLDER$|#!$BASH_BIN|" "$BIN/nix" "$BIN/nixos-install" "$BIN/sudo"
chmod 755 "$BIN/nix" "$BIN/nixos-install" "$BIN/sudo"
export PATH="$BIN:$PATH"

# binfmt fixtures for the emulation preflight
mkdir -p "$T/bmf-ok" "$T/bmf-empty"
touch "$T/bmf-ok/qemu-aarch64"
export RPI_BINMFT_DIR="$T/bmf-ok"
export RPI_MOUNTPOINT_CMD=true          # card layout: pretend /boot/firmware is mounted
export RPI_BINMFT_RUN="$T/bmf-run"   # does not exist: exercises the OR branch
EMUL_OK=( MOCK_PLATFORMS="x86_64-linux aarch64-linux" )
EMUL_BAD=( MOCK_PLATFORMS="x86_64-linux" "RPI_BINMFT_DIR=$T/bmf-empty" )

GIT_ID=( -c user.email=test@example.com -c user.name=test )

new_flake() {  # $1 = name; echoes the path; git repo with a flake.nix
  local d="$T/flake-$1"
  mkdir -p "$d"
  echo "test flake" > "$d/flake.nix"
  # same ignore as the real repo: build state must not count as dirty
  echo ".rpi-build/" > "$d/.gitignore"
  git -C "$d" init -q
  git -C "$d" "${GIT_ID[@]}" add flake.nix .gitignore
  git -C "$d" "${GIT_ID[@]}" commit -qm init
  printf '%s\n' "$d"
}

new_card() {  # $1 = name; echoes the path; looks like a NixOS flake install
  local d="$T/card-$1"
  mkdir -p "$d/etc/nixos"
  echo x > "$d/etc/nixos/flake.nix"
  printf '%s\n' "$d"
}

# --- tiny test harness -------------------------------------------------------
pass=0; fail=0
OUT="$T/last.out"
LAST_EXIT=0

run_cmd() {
  "$@" > "$OUT" 2>&1
  LAST_EXIT=$?
}

expect_exit() {  # name expected
  if [[ "$LAST_EXIT" -eq "$2" ]]; then
    pass=$((pass + 1)); echo "PASS: $1 (exit $LAST_EXIT)"
  else
    fail=$((fail + 1)); echo "FAIL: $1 (expected exit $2, got $LAST_EXIT)"
    sed 's/^/    | /' "$OUT"
  fi
}

expect_grep() {  # name pattern [file]
  local f="${3:-$OUT}"
  if grep -q "$2" "$f" 2>/dev/null; then
    pass=$((pass + 1)); echo "PASS: $1"
  else
    fail=$((fail + 1)); echo "FAIL: $1 (pattern '$2' not found in $f)"
    sed 's/^/    | /' "$f" 2>/dev/null | head -20
  fi
}

expect_grepf() {  # name fixed-string [file]
  local f="${3:-$OUT}"
  if grep -qF -- "$2" "$f" 2>/dev/null; then
    pass=$((pass + 1)); echo "PASS: $1"
  else
    fail=$((fail + 1)); echo "FAIL: $1 (string '$2' not found in $f)"
    sed 's/^/    | /' "$f" 2>/dev/null | head -20
  fi
}

expect_not_grep() {  # name fixed-string [file]
  local f="${3:-$OUT}"
  if ! grep -qF -- "$2" "$f" 2>/dev/null; then
    pass=$((pass + 1)); echo "PASS: $1"
  else
    fail=$((fail + 1)); echo "FAIL: $1 (string '$2' unexpectedly found)"
  fi
}

expect_true() {  # name test-cmd args...
  local name="$1"; shift
  if "$@"; then
    pass=$((pass + 1)); echo "PASS: $name"
  else
    fail=$((fail + 1)); echo "FAIL: $name"
  fi
}

record_val() {  # file key -> value (empty if absent)
  sed -n "s/^$2=//p" "$1" | tail -1
}

# --- tests -------------------------------------------------------------------

# 1. help
run_cmd bash "$SCRIPT" --help
expect_exit "help: exit 0" 0
expect_grep "help: prints usage" "Usage: rpi-install"

# 2. unknown argument
run_cmd bash "$SCRIPT" --bogus
expect_exit "unknown arg: exit 2" 2
expect_grep "unknown arg: message" "unknown argument"

# 3. two subcommands
run_cmd bash "$SCRIPT" build install
expect_exit "double subcommand: exit 2" 2
expect_grep "double subcommand: message" "multiple subcommands"

# 4. nonexistent flake path
run_cmd bash "$SCRIPT" show --flake "$T/does-not-exist"
expect_exit "bad flake path: exit 1" 1
expect_grep "bad flake path: message" "flake path does not exist"

# 5. show with no record
F5="$(new_flake t5)"
run_cmd bash "$SCRIPT" show --flake "$F5"
expect_exit "show (no record): exit 0" 0
expect_grep "show: no record message" "no build record"
expect_grep "show: git head resolved" "git head: [0-9a-f]\{40\}"

# 6. install with no record (real mode)
F6="$(new_flake t6)"; C6="$(new_card t6)"
run_cmd env RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --flake "$F6" --mount "$C6"
expect_exit "install without record: exit 1" 1
expect_grep "install without record: message" "no build record at"

# 7. build with broken emulation preflight
F7="$(new_flake t7)"
run_cmd env "${EMUL_BAD[@]}" bash "$SCRIPT" build --flake "$F7"
expect_exit "build (no emulation): exit 1" 1
expect_grep "build (no emulation): preflight failure" "emulation preflight failed"
expect_grep "build (no emulation): shows module hint" "emulatedSystems"

# 8. build --dry-run with working emulation
F8="$(new_flake t8)"
run_cmd env "${EMUL_OK[@]}" bash "$SCRIPT" build --dry-run --flake "$F8"
expect_exit "build --dry-run: exit 0" 0
expect_grep "build --dry-run: prints eval" "dry-run: nix eval --raw"
expect_grep "build --dry-run: prints build" "dry-run: nix build"
expect_true "build --dry-run: state dir created" test -d "$F8/.rpi-build"
expect_true "build --dry-run: no record written" test ! -f "$F8/.rpi-build/last"

# 9. real build (mocked nix) writes a complete record
F9="$(new_flake t9)"
run_cmd env "${EMUL_OK[@]}" bash "$SCRIPT" build --flake "$F9"
expect_exit "build (real, mocked nix): exit 0" 0
LAST="$F9/.rpi-build/last"
[[ -f "$LAST" ]] || { fail=$((fail + 1)); echo "FAIL: build: no record written"; }
if [[ -f "$LAST" ]]; then
  [[ "$(record_val "$LAST" flake)" == "$F9" ]] \
    && { pass=$((pass + 1)); echo "PASS: record.flake"; } \
    || { fail=$((fail + 1)); echo "FAIL: record.flake"; cat "$LAST"; }
  [[ "$(record_val "$LAST" attr)" == "rpi" ]] \
    && { pass=$((pass + 1)); echo "PASS: record.attr"; } \
    || { fail=$((fail + 1)); echo "FAIL: record.attr"; cat "$LAST"; }
  [[ "$(record_val "$LAST" sys)" == "$MOCK_SYS" ]] \
    && { pass=$((pass + 1)); echo "PASS: record.sys"; } \
    || { fail=$((fail + 1)); echo "FAIL: record.sys"; cat "$LAST"; }
  [[ "$(record_val "$LAST" drv)" == "$MOCK_DRV" ]] \
    && { pass=$((pass + 1)); echo "PASS: record.drv"; } \
    || { fail=$((fail + 1)); echo "FAIL: record.drv"; cat "$LAST"; }
  [[ "$(record_val "$LAST" dirty)" == "clean" ]] \
    && { pass=$((pass + 1)); echo "PASS: record.dirty"; } \
    || { fail=$((fail + 1)); echo "FAIL: record.dirty"; cat "$LAST"; }
  if [[ "$(record_val "$LAST" rev)" =~ ^[0-9a-f]{40}$ ]]; then
    pass=$((pass + 1)); echo "PASS: record.rev (40-hex git sha)"
  else
    fail=$((fail + 1)); echo "FAIL: record.rev"; cat "$LAST"
  fi
  if [[ -n "$(record_val "$LAST" built)" ]]; then
    pass=$((pass + 1)); echo "PASS: record.built"
  else
    fail=$((fail + 1)); echo "FAIL: record.built"; cat "$LAST"
  fi
fi

# 10. show after a build prints the record
run_cmd env RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" show --flake "$F9"
expect_exit "show (with record): exit 0" 0
expect_grep "show: record header" "last build record"
expect_grepf "show: prints recorded system" "$MOCK_SYS"

# 11. install --dry-run with record
C11="$(new_card t11)"
run_cmd env RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --dry-run --flake "$F9" --mount "$C11"
expect_exit "install --dry-run: exit 0" 0
expect_grep "install --dry-run: store copy" "dry-run: sudo nix copy --no-check-sigs --to"
expect_grepf "install --dry-run: nixos-install args" "dry-run: sudo nixos-install --root $C11 --flake $F9#rpi"

# 12. real install with missing card
run_cmd env RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --flake "$F9" --mount "$T/no-card"
expect_exit "install (card missing): exit 1" 1
expect_grep "install (card missing): message" "mount point does not exist"

# 13. real install (mocked): copies, runs nixos-install, verifies
C13="$(new_card t13)"
: > "$MOCK_LOG"
run_cmd env RPI_BINMFT_DIR="$T/bmf-ok" MOCK_COPY=1 bash "$SCRIPT" install --flake "$F9" --mount "$C13"
expect_exit "install (real, mocked): exit 0" 0
expect_grepf "install: success message" "installed $(basename "$MOCK_SYS")"
expect_grepf "install: nixos-install got --root" "--root $C13" "$MOCK_LOG"
expect_grepf "install: nixos-install got host flake" "--flake $F9#rpi" "$MOCK_LOG"
sysname="$(basename "$MOCK_SYS")"; drvname="$(basename "$MOCK_DRV")"
expect_true "install: system path landed on card" \
  test -d "$C13/nix/store/$sysname"
expect_true "install: drv path landed on card" \
  test -d "$C13/nix/store/$drvname"

# 14. real install fails verification when the copy produced nothing
C14="$(new_card t14)"
run_cmd env RPI_BINMFT_DIR="$T/bmf-ok" MOCK_COPY=0 bash "$SCRIPT" install --flake "$F9" --mount "$C14"
expect_exit "install (copy no-op): exit 1" 1
expect_grep "install (copy no-op): verification failure" "verification failed"

# 15. attr mismatch between record and request
F15="$(new_flake t15)"
run_cmd env "${EMUL_OK[@]}" bash "$SCRIPT" build --attr foo --flake "$F15"
expect_exit "build --attr foo: exit 0" 0
C15="$(new_card t15)"
run_cmd env RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --dry-run --flake "$F15" --mount "$C15"
expect_exit "install (attr mismatch): exit 1" 1
expect_grep "install (attr mismatch): message" "recorded build is for attr"

# 16. divergence warning: checkout HEAD moved after the recorded build
echo change >> "$F9/flake.nix"
git -C "$F9" "${GIT_ID[@]}" add -A
git -C "$F9" "${GIT_ID[@]}" commit -qm second
C16="$(new_card t16)"
run_cmd env RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --dry-run --flake "$F9" --mount "$C16"
expect_exit "install (HEAD moved): exit 0" 0
expect_grep "install (HEAD moved): divergence warning" "differs from recorded build"

# 17. dirty-tree warning
touch "$F9/untracked"
run_cmd env RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --dry-run --flake "$F9" --mount "$C16"
expect_exit "install (dirty tree): exit 0" 0
expect_grep "install (dirty tree): warning" "uncommitted changes"

# 18. install --from without any build record (dry-run)
F18="$(new_flake t18)"; C18="$(new_card t18)"
run_cmd env RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --from "$MOCK_SYS" --dry-run --flake "$F18" --mount "$C18"
expect_exit "install --from (dry-run, no record): exit 0" 0
expect_grepf "install --from: nixos-install args" "dry-run: sudo nixos-install --root $C18 --flake $F18#rpi"

# 19. install --from without any build record (real mode, drv via eval mock)
run_cmd env RPI_BINMFT_DIR="$T/bmf-ok" MOCK_COPY=1 bash "$SCRIPT" install --from "$MOCK_SYS" --flake "$F18" --mount "$C18"
expect_exit "install --from (real, no record): exit 0" 0
expect_grepf "install --from: success message" "installed $(basename "$MOCK_SYS")"

# 20. no subcommand defaults to `all` (dry-run, both phases)
F20="$(new_flake t20)"; C20="$(new_card t20)"
run_cmd env "${EMUL_OK[@]}" bash "$SCRIPT" --dry-run --flake "$F20" --mount "$C20"
expect_exit "default subcommand (all --dry-run): exit 0" 0
expect_grep "all: ran build phase" "dry-run: nix build"
expect_grepf "all: ran install phase" "dry-run: sudo nixos-install --root $C20 --flake $F20#rpi"

# 21. positional target path (same as --mount); a second one is rejected
F21="$(new_flake t21)"; C21="$(new_card t21)"
run_cmd env RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --dry-run --flake "$F21" "$C21"
expect_exit "positional target: exit 0" 0
expect_grepf "positional target: nixos-install root" "dry-run: sudo nixos-install --root $C21 --flake $F21#rpi"
run_cmd bash "$SCRIPT" install --flake "$F21" "$C21" /other
expect_exit "two targets: exit 2" 2
expect_grep "two targets: message" "multiple target paths"

# 22. build failure shows log tail + hint, writes no record
F22="$(new_flake t22)"
run_cmd env "${EMUL_OK[@]}" MOCK_BUILD_FAIL=255 bash "$SCRIPT" build --flake "$F22"
expect_exit "build failure (255): exit 1" 1
expect_grep "build failure (255): hint" "could not be exec'd under qemu"
expect_grep "build failure: message" "build failed"
expect_true "build failure: no record written" test ! -f "$F22/.rpi-build/last"
run_cmd env "${EMUL_OK[@]}" MOCK_BUILD_FAIL=oom bash "$SCRIPT" build --flake "$F22"
expect_exit "build failure (oom): exit 1" 1
expect_grep "build failure (oom): hint" "out of memory"

# 23. install warns when the card lacks etc/NIXOS and the firmware files
C23="$(new_card t23)"
run_cmd env RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --flake "$F9" --mount "$C23"
expect_exit "install (incomplete card): exit 0" 0
expect_grep "install: warns missing etc/NIXOS" "etc/NIXOS"
expect_grep "install: warns missing config.txt" "firmware/config.txt"
expect_grep "install: warns missing u-boot" "u-boot-rpi-arm64.bin"

# 24. firmware partition must be a mount point (real install dies, dry-run warns)
C24="$(new_card t24)"
run_cmd env RPI_MOUNTPOINT_CMD=false RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --flake "$F9" --mount "$C24"
expect_exit "install (firmware not mounted): exit 1" 1
expect_grep "install (firmware not mounted): message" "boot/firmware is not a mount point"
run_cmd env RPI_MOUNTPOINT_CMD=false RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --dry-run --flake "$F9" --mount "$C24"
expect_exit "install --dry-run (firmware not mounted): exit 0" 0
expect_grep "install --dry-run (firmware not mounted): warns" "boot/firmware is not a mount point"

# 25. nvmd binary cache: flake config accepted for build + install; warn if cache missing
F25="$(new_flake t25)"
run_cmd env "${EMUL_OK[@]}" bash "$SCRIPT" build --dry-run --flake "$F25"
expect_grep "build: passes --accept-flake-config (eval)" "nix eval --raw .*--accept-flake-config"
expect_grep "build: passes --accept-flake-config (build)" "nix build --accept-flake-config"
expect_grep "build: warns when cache not configured" "nixos-raspberrypi.cachix.org is not in"
run_cmd env "${EMUL_OK[@]}" MOCK_CACHE=1 bash "$SCRIPT" build --dry-run --flake "$F25"
expect_grep "build: cache configured is reported" "binary cache: nixos-raspberrypi.cachix.org configured"
run_cmd env RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --dry-run --flake "$F9" --mount "$C24"
expect_grep "install: nixos-install accepts flake config" "nixos-install --root $C24 --flake $F9#rpi --option accept-flake-config true"

# --- summary -----------------------------------------------------------------
echo
echo "rpi-install unit tests: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
