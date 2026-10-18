#!/usr/bin/env bash
#
# Unit tests for rpi-deploy.sh (rpi-deploy).
#
# Runs the real script against a mocked `nix` and `nixos-install`, so no
# real builds happen and no aarch64 emulation is needed in the test
# environment (binfmt locations are overridden via RPI_BINMFT_*).
#
# Invoked by the flake check `checks.x86_64-linux.rpi-deploy-unit`:
#
#   RPI_DEPLOY_SRC=<path to rpi-deploy.sh> bash tests/deploy-unit.sh
#
# Exits non-zero if any test fails.

set -u

SCRIPT="${RPI_DEPLOY_SRC:?RPI_DEPLOY_SRC must point at rpi-deploy.sh}"
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
  *" path-info "*) echo "$MOCK_SYS ${MOCK_CLOSURE-1000}" ;;
  *" --apply "*) echo "${MOCK_LOGIN-pi 1 0}" ;;
  *" config show "*)
    case "${@: -1}" in
      substituters) echo "https://cache.nixos.org/ ${MOCK_CACHE:+https://nixos-raspberrypi.cachix.org}" ;;
      trusted-users) echo "${MOCK_TRUSTED-$(id -un)}" ;;
    esac ;;
  *" build --dry-run "*)
    [[ -n "${MOCK_PLAN_FAIL:-}" ]] && { echo "error: evaluation failed" >&2; exit 1; }
    if [[ "${MOCK_KERNEL:-fetch}" == build ]]; then
      printf 'these 2 derivations will be built:\n  /nix/store/aaaa-linux_rpi-bcm2711-6.18.34.drv\n  /nix/store/bbbb-nixos-system-neptun.drv\nthese 9 paths will be fetched (10 MiB download):\n  /nix/store/cccc-glibc\n'
    else
      printf 'these 9 paths will be fetched (300 MiB download, 900 MiB unpacked):\n  /nix/store/dddd-linux_rpi-bcm2711-6.18.34\n  /nix/store/eeee-glibc\nthis derivation will be built:\n  /nix/store/ffff-nixos-system-neptun.drv\n'
    fi ;;
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
    echo "nix $*" >> "$MOCK_LOG"
    if [[ "${MOCK_COPY:-1}" == 1 ]]; then
      state="pre"; target=""
      for a in "$@"; do
        case "$state" in
          pre)        [[ "$a" == "--to" ]] && state="wanttarget" ;;
          wanttarget) target="$a"; state="paths" ;;
          paths)      mkdir -p "$target/nix/store/$(basename "$a")"; case "$a" in *.drv) ;; *) : > "$target/nix/store/$(basename "$a")/activate"; chmod +x "$target/nix/store/$(basename "$a")/activate" ;; esac ;;
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
# sudo -v / sudo -n -v: credential refresh only; otherwise run the command
while [[ "${1:-}" == -* ]]; do
  case "$1" in
    -v) echo "sudo -v" >> "$MOCK_LOG"; [[ -n "${MOCK_SUDO_FAIL:-}" ]] && exit 1; exit 0 ;;
    *) shift ;;
  esac
done
exec "$@"
MOCK

# Mock `nixos-install`: records its args, succeeds.
cat > "$BIN/nixos-install" <<'MOCK'
#!BASHPLACEHOLDER
echo "nixos-install $*" >> "$MOCK_LOG"
# record whether the (bridged) interpreter is visible under --root, like in the chroot
root=""; prev=""; for a in "$@"; do [[ "$prev" == --root ]] && root="$a"; prev="$a"; done
[[ -n "${MOCK_INTERP:-}" && -L "$root$MOCK_INTERP" ]] && echo "interp-visible-in-chroot" >> "$MOCK_LOG"
exit "${MOCK_NIXOS_INSTALL_RC:-0}"
MOCK
sed -i "1s|^#!BASHPLACEHOLDER$|#!$BASH_BIN|" "$BIN/nix" "$BIN/nixos-install" "$BIN/sudo"
chmod 755 "$BIN/nix" "$BIN/nixos-install" "$BIN/sudo"
export PATH="$BIN:$PATH"


# --- mocks for the card tools (prepare / eject) ------------------------------
# All privileged commands go through the `sudo` mock, so the mutating tools
# only record their arguments.
MOCK_MNT="$T/mnt-state"; mkdir -p "$MOCK_MNT"; export MOCK_MNT
for tool in wipefs mkfs.vfat mkfs.ext4 udevadm umount mount sync fatlabel e2label; do
  cat > "$BIN/$tool" <<'MOCK'
#!BASHPLACEHOLDER
echo "$(basename "$0") $*" >> "$MOCK_LOG"
exit 0
MOCK
done
# flock DEV CMD...: record, then run CMD (like util-linux flock on a path)
cat > "$BIN/flock" <<'MOCK'
#!BASHPLACEHOLDER
echo "flock $1" >> "$MOCK_LOG"
shift
exec "$@"
MOCK

# sfdisk also records the partition script it reads from stdin
cat > "$BIN/sfdisk" <<'MOCK'
#!BASHPLACEHOLDER
echo "sfdisk $*" >> "$MOCK_LOG"
sed 's/^/sfdisk-script: /' >> "$MOCK_LOG"
exit 0
MOCK
# findmnt: --mountpoint DIR -> contents of $MOCK_MNT/<DIR with / -> _> (else rc 1);
#          -T PATH          -> the host source device $MOCK_HOST_SRC
cat > "$BIN/findmnt" <<'MOCK'
#!BASHPLACEHOLDER
case " $* " in
  *" --mountpoint "*)
    f="$MOCK_MNT/$(printf '%s' "${@: -1}" | tr / _)"
    [[ -f "$f" ]] && { cat "$f"; exit 0; }
    exit 1 ;;
  *" -T "*) echo "${MOCK_HOST_SRC:-/dev/nvme0n1p1}" ;;
esac
MOCK
# lsblk: -dno TYPE -> $MOCK_LSBLK_TYPE (disk); -nlso NAME <src> -> src and its disk;
#        -nlo MOUNTPOINT -> $MOCK_DEV_MOUNTS; anything else -> a table line
cat > "$BIN/lsblk" <<'MOCK'
#!BASHPLACEHOLDER
case " $* " in
  *" -dnP "*) echo 'PATH="/dev/sdq" SIZE="29.8G" TRAN="usb" RM="1" MODEL="Card Reader"' ;;
  *" -dno RM "*) echo "${MOCK_RM:-1}" ;;
  *" -dno TYPE "*) echo "${MOCK_LSBLK_TYPE:-disk}" ;;
  *" -nlso NAME "*)
    src="${@: -1}"; n="$(basename "$src")"; echo "$n"
    case "$n" in nvme*p[0-9]*) echo "${n%p[0-9]*}" ;; sd*[0-9]) echo "${n%[0-9]*}" ;; esac ;;
  *" -no FSTYPE "*)
    case "${@: -1}" in *p1|*[a-z]1) echo "${MOCK_FS_BOOT-vfat}" ;; *) echo "${MOCK_FS_ROOT-ext4}" ;; esac ;;
  *" -no LABEL "*)
    case "${@: -1}" in *p1|*[a-z]1) echo "${MOCK_LABEL_BOOT-NIXOS_BOOT}" ;; *) echo "${MOCK_LABEL_ROOT-NIXOS_SD}" ;; esac ;;
  *" -no MOUNTPOINT "*) echo "${MOCK_PART_MNT:-}" ;;
  *" -nlo PATH,LABEL "*) [[ -n "${MOCK_DUP_LABELS:-}" ]] && printf '%b\n' "$MOCK_DUP_LABELS" ;;
  *" -nlo MOUNTPOINT "*) [[ -n "${MOCK_DEV_MOUNTS:-}" ]] && printf '%s\n' "$MOCK_DEV_MOUNTS" ;;
  *) echo "NAME SIZE FSTYPE LABEL MODEL (mock)" ;;
esac
exit 0
MOCK
sed -i "1s|^#!BASHPLACEHOLDER$|#!$BASH_BIN|" "$BIN"/{wipefs,mkfs.vfat,mkfs.ext4,udevadm,umount,mount,sync,fatlabel,e2label,flock,sfdisk,findmnt,lsblk}
chmod 755 "$BIN"/{wipefs,mkfs.vfat,mkfs.ext4,udevadm,umount,mount,sync,fatlabel,e2label,flock,sfdisk,findmnt,lsblk}


# chroot mock: never really chroots. Succeeds, unless
#   MOCK_CHROOT_NEEDS=<path>  fails until that path exists as a symlink under the root
#                             (models a binfmt interpreter that is only found if bridged)
#   MOCK_CHROOT_FAIL=1        always fails (127, like the real error)
cat > "$BIN/chroot" <<'MOCK'
#!BASHPLACEHOLDER
echo "chroot $*" >> "$MOCK_LOG"
root="$1"
if [[ -n "${MOCK_CHROOT_FAIL:-}" ]] || { [[ -n "${MOCK_CHROOT_NEEDS:-}" ]] && [[ ! -L "$root$MOCK_CHROOT_NEEDS" ]]; }; then
  echo "chroot: failed to run command '$2': No such file or directory" >&2
  exit 127
fi
exit 0
MOCK
sed -i "1s|^#!BASHPLACEHOLDER$|#!$BASH_BIN|" "$BIN/chroot"; chmod 755 "$BIN/chroot"

# mountpoint helper that reports "not mounted" only for <dir>/boot/firmware
cat > "$BIN/mp-nofw" <<'MOCK'
#!BASHPLACEHOLDER
[[ "${@: -1}" != */boot/firmware ]]
MOCK
sed -i "1s|^#!BASHPLACEHOLDER$|#!$BASH_BIN|" "$BIN/mp-nofw"; chmod 755 "$BIN/mp-nofw"

# by-label fixtures: a card whose labels point at $DEVDIR/mmcblk0p{1,2} (names
# only; nothing is opened), plus the dummy "device" used by the format tests
DEVDIR="$T/dev"; mkdir -p "$DEVDIR"; touch "$DEVDIR/mmcblk0p1" "$DEVDIR/mmcblk0p2"
mkdir -p "$T/by-label" "$T/by-label-empty"
ln -s $DEVDIR/mmcblk0p2 "$T/by-label/NIXOS_SD"
ln -s $DEVDIR/mmcblk0p1 "$T/by-label/NIXOS_BOOT"
export RPI_BYLABEL_DIR="$T/by-label"
export RPI_ALLOW_NONBLOCK=1      # test "devices" are not real block devices

# binfmt fixtures for the emulation preflight
mkdir -p "$T/bmf-ok" "$T/bmf-empty"
# a registration as NixOS writes it with preferStaticEmulators (F flag: works in a chroot)
printf 'enabled\ninterpreter /run/binfmt/aarch64-linux\nflags: POCF\noffset 0\n' > "$T/bmf-ok/qemu-aarch64"
# ... and the default one (P only): interpreter looked up inside the chroot -> must be bridged
mkdir -p "$T/bmf-nof" "$T/fake-run/binfmt"
ln -s "$(readlink -f "$BASH_BIN")" "$T/fake-run/binfmt/aarch64-linux"
printf 'enabled\ninterpreter %s/fake-run/binfmt/aarch64-linux\nflags: P\noffset 0\n' "$T" > "$T/bmf-nof/aarch64-linux"
export RPI_BINMFT_DIR="$T/bmf-ok"
export RPI_MOUNTPOINT_CMD=true          # card layout: pretend root and /boot/firmware are mounted
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
expect_grep "help: prints usage" "Usage: rpi-deploy"

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
run_cmd env RPI_BYLABEL_DIR="$T/by-label-empty" RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --flake "$F9" --mount "$T/no-card"
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
run_cmd env RPI_MOUNTPOINT_CMD=mp-nofw RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --flake "$F9" --mount "$C24"
expect_exit "install (firmware not mounted): exit 1" 1
expect_grep "install (firmware not mounted): message" "boot/firmware is not a mount point"
run_cmd env RPI_MOUNTPOINT_CMD=mp-nofw RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --dry-run --flake "$F9" --mount "$C24"
expect_exit "install --dry-run (firmware not mounted): exit 0" 0
expect_grep "install --dry-run (firmware not mounted): warns" "boot/firmware is not a mount point"

# 25. nvmd binary cache: flake config accepted for build + install; warn if cache missing
F25="$(new_flake t25)"
run_cmd env "${EMUL_OK[@]}" bash "$SCRIPT" build --dry-run --flake "$F25"
expect_grep "build: passes --accept-flake-config (eval)" "nix eval --raw .*--accept-flake-config"
expect_grep "build: passes --accept-flake-config (build)" "nix build --accept-flake-config"
expect_grep "build: trusted user -> cache enabled via flake" "enabled through the flake (you are a trusted nix user)"
expect_grep "build: kernel comes from the cache" "available from the binary cache"
expect_not_grep "build: no cache warning for a trusted user" "not a trusted nix user"
run_cmd env "${EMUL_OK[@]}" MOCK_CACHE=1 bash "$SCRIPT" build --dry-run --flake "$F25"
expect_grep "build: cache configured is reported" "nixos-raspberrypi.cachix.org is configured on this host"
run_cmd env "${EMUL_OK[@]}" MOCK_TRUSTED=nobody-here bash "$SCRIPT" build --dry-run --flake "$F25"
expect_grep "build: untrusted user is told how to fix it" "not a trusted nix user"
expect_grep "build: untrusted: suggests trusted-users" "trusted-users"
run_cmd env "${EMUL_OK[@]}" MOCK_TRUSTED="@$(id -gn)" bash "$SCRIPT" build --dry-run --flake "$F25"
expect_grep "build: trusted through a group" "you are a trusted nix user"

# 25b. the authoritative cache test: would the vendor kernel be compiled?
F25B="$(new_flake t25b)"
run_cmd env "${EMUL_OK[@]}" MOCK_KERNEL=build bash "$SCRIPT" build --flake "$F25B"
expect_exit "kernel not cached (no tty): exit 1" 1
expect_grep "kernel not cached: explains" "would be compiled locally under qemu"
expect_grep "kernel not cached: names the kernel" "linux_rpi-bcm2711-6.18.34.drv"
expect_grep "kernel not cached: aborts, offers --yes" "aborted. Fix the cache setup, or pass --yes"
expect_true "kernel not cached: nothing built" test ! -f "$F25B/.rpi-build/last"
run_cmd env "${EMUL_OK[@]}" MOCK_KERNEL=build bash "$SCRIPT" build --flake "$F25B" --yes
expect_exit "kernel not cached (--yes): exit 0" 0
expect_grep "kernel not cached (--yes): continues" "continuing because of --yes"
run_cmd env "${EMUL_OK[@]}" MOCK_KERNEL=build RPI_ASSUME_TTY=1 bash "$SCRIPT" build --flake "$F25B" <<< "n"
expect_exit "kernel not cached (answer n): exit 1" 1
expect_grep "kernel not cached: question asked" "Compile the kernel locally anyway?"
run_cmd env "${EMUL_OK[@]}" MOCK_KERNEL=build RPI_ASSUME_TTY=1 bash "$SCRIPT" build --flake "$F25B" <<< "y"
expect_exit "kernel not cached (answer y): exit 0" 0
run_cmd env "${EMUL_OK[@]}" MOCK_KERNEL=build bash "$SCRIPT" build --dry-run --flake "$F25B"
expect_exit "kernel not cached (--dry-run): warns only, exit 0" 0
expect_grep "kernel not cached (--dry-run): still reported" "would be compiled locally"
run_cmd env "${EMUL_OK[@]}" MOCK_PLAN_FAIL=1 bash "$SCRIPT" build --flake "$F25B"
expect_exit "build plan unavailable: exit 0" 0
expect_grep "build plan unavailable: skipped with a note" "skipping the kernel cache check"
run_cmd env RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --dry-run --flake "$F9" --mount "$C24"
expect_grep "install: nixos-install accepts flake config" "nixos-install --root $C24 --flake $F9#rpi --option accept-flake-config true"

# 26. install copies the configuration checkout to <mount>/etc/nixos
F26="$(new_flake t26)"; C26="$(mktemp -d "$T/card-t26.XXXX")"
mkdir -p "$C26/etc/nixos"; echo stale > "$C26/etc/nixos/stale-file"
mkdir -p "$F26/secrets" "$F26/.rpi-build" "$F26/.nixcache"
echo "MY_WIFI_PASSWORD=x" > "$F26/secrets/wireless.env"
echo junk > "$F26/.rpi-build/last"; echo junk > "$F26/.nixcache/x"; echo junk > "$F26/.rpi-build.log"
run_cmd env RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" config --flake "$F26" --mount "$C26"
expect_exit "config: exit 0" 0
expect_true "config: flake.nix copied" test -f "$C26/etc/nixos/flake.nix"
expect_true "config: secrets copied" test -f "$C26/etc/nixos/secrets/wireless.env"
expect_true "config: .git copied (secrets stay untracked on the pi)" test -d "$C26/etc/nixos/.git"
expect_true "config: stale file removed (mirror)" test ! -e "$C26/etc/nixos/stale-file"
expect_true "config: .rpi-build not copied" test ! -e "$C26/etc/nixos/.rpi-build"
expect_true "config: .nixcache not copied" test ! -e "$C26/etc/nixos/.nixcache"
expect_true "config: .rpi-build.log not copied" test ! -e "$C26/etc/nixos/.rpi-build.log"
run_cmd env RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" config --dry-run --flake "$F26" --mount "$C26"
expect_exit "config --dry-run: exit 0" 0
expect_grep "config --dry-run: prints the copy" "dry-run: tar -C"
# a failed/absent mount must not be written to
run_cmd env RPI_MOUNTPOINT_CMD=false bash "$SCRIPT" config --flake "$F26" --mount "$C26"
expect_exit "config (not a mount point): exit 1" 1
expect_grep "config (not a mount point): message" "is not a mount point"
# real install ends with the config on the card
C26B="$(new_card t26b)"; rm -rf "$C26B/etc/nixos"
run_cmd env RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --flake "$F9" --mount "$C26B"
expect_exit "install (fresh card, no etc/nixos): exit 0" 0
expect_true "install: configuration copied to etc/nixos" test -f "$C26B/etc/nixos/flake.nix"
expect_not_grep "install: no 'configuration was not copied' warning" "was not copied"

# 27. prepare: mount an existing card by its labels
: > "$MOCK_LOG"; rm -f "$MOCK_MNT"/*
C27="$T/card-t27"
run_cmd bash "$SCRIPT" prepare --dry-run --mount "$C27"
expect_exit "prepare (by label, dry-run): exit 0" 0
expect_grepf "prepare: mounts root" "dry-run: sudo mount $DEVDIR/mmcblk0p2 $C27" 
expect_grepf "prepare: creates firmware dir" "mkdir -p $C27/boot/firmware"
expect_grepf "prepare: mounts firmware partition" "mount $DEVDIR/mmcblk0p1 $C27/boot/firmware"
run_cmd bash "$SCRIPT" prepare --mount "$C27"
expect_exit "prepare (by label, real): exit 0" 0
expect_grepf "prepare real: mount root recorded" "mount $DEVDIR/mmcblk0p2 $C27" "$MOCK_LOG"
expect_grepf "prepare real: mount firmware recorded" "mount $DEVDIR/mmcblk0p1 $C27/boot/firmware" "$MOCK_LOG"
expect_not_grep "prepare (by label) never formats" "mkfs" "$MOCK_LOG"
# already mounted -> nothing mounted twice
: > "$MOCK_LOG"
echo $DEVDIR/mmcblk0p2 > "$MOCK_MNT/$(printf '%s' "$C27" | tr / _)"
echo $DEVDIR/mmcblk0p1 > "$MOCK_MNT/$(printf '%s' "$C27/boot/firmware" | tr / _)"
run_cmd bash "$SCRIPT" prepare --mount "$C27"
expect_exit "prepare (already mounted): exit 0" 0
expect_not_grep "prepare (already mounted): no second mount" "mount /dev" "$MOCK_LOG"
# old layout: FAT mounted at <mount>/boot is moved to boot/firmware
: > "$MOCK_LOG"; rm -f "$MOCK_MNT"/*
echo $DEVDIR/mmcblk0p2 > "$MOCK_MNT/$(printf '%s' "$C27" | tr / _)"
echo $DEVDIR/mmcblk0p1 > "$MOCK_MNT/$(printf '%s' "$C27/boot" | tr / _)"
run_cmd bash "$SCRIPT" prepare --mount "$C27"
expect_exit "prepare (old layout): exit 0" 0
expect_grepf "prepare (old layout): FAT unmounted from /boot" "umount $C27/boot" "$MOCK_LOG"
expect_grepf "prepare (old layout): FAT remounted at boot/firmware" "mount $DEVDIR/mmcblk0p1 $C27/boot/firmware" "$MOCK_LOG"
# wrong device already at the mount point
rm -f "$MOCK_MNT"/*; echo /dev/sdz9 > "$MOCK_MNT/$(printf '%s' "$C27" | tr / _)"
run_cmd bash "$SCRIPT" prepare --mount "$C27"
expect_exit "prepare (mount point busy): exit 1" 1
expect_grep "prepare (mount point busy): message" "already mounted from /dev/sdz9"
rm -f "$MOCK_MNT"/*
# no labelled card at all

run_cmd env RPI_BYLABEL_DIR="$T/by-label-empty" bash "$SCRIPT" prepare --mount "$C27"
expect_exit "prepare (no card): exit 1" 1
expect_grep "prepare (no card): hint to format" "prepare /dev/sdX --format"

# 28. prepare DEVICE --format
: > "$MOCK_LOG"
run_cmd bash "$SCRIPT" prepare /dev/sdq --format --yes --mount "$C27"
expect_exit "format (labels not matching afterwards): exit 1" 1
expect_grep "format: verifies the labels afterwards" "does not have the expected layout"
expect_grepf "format: wipes the device" "wipefs -a /dev/sdq" "$MOCK_LOG"
expect_grepf "format: MBR table" "sfdisk-script: label: dos" "$MOCK_LOG"
expect_grepf "format: 256MiB FAT32 boot partition, bootable" "sfdisk-script: ,256MiB,c,*" "$MOCK_LOG"
expect_grepf "format: root takes the rest" "sfdisk-script: ,,83" "$MOCK_LOG"
expect_grepf "format: FAT32 label" "mkfs.vfat -F 32 -n NIXOS_BOOT /dev/sdq1" "$MOCK_LOG"
expect_grepf "format: ext4 label" "mkfs.ext4 -q -F -L NIXOS_SD /dev/sdq2" "$MOCK_LOG"
# the same with matching labels (mmcblk0 -> p1/p2) ends mounted correctly
: > "$MOCK_LOG"
run_cmd bash "$SCRIPT" prepare $DEVDIR/mmcblk0 --format --yes --mount "$C27"
expect_exit "format mmcblk0: exit 0" 0
expect_grepf "format mmcblk0: partition names use the p suffix" "mkfs.vfat -F 32 -n NIXOS_BOOT $DEVDIR/mmcblk0p1" "$MOCK_LOG"
expect_grepf "format mmcblk0: root mounted" "mount $DEVDIR/mmcblk0p2 $C27" "$MOCK_LOG"
expect_grepf "format mmcblk0: firmware mounted" "mount $DEVDIR/mmcblk0p1 $C27/boot/firmware" "$MOCK_LOG"
# custom boot size
: > "$MOCK_LOG"
run_cmd bash "$SCRIPT" prepare $DEVDIR/mmcblk0 --format --yes --boot-size 512MiB --mount "$C27"
expect_grepf "format: custom boot size" "sfdisk-script: ,512MiB,c,*" "$MOCK_LOG"
run_cmd bash "$SCRIPT" prepare $DEVDIR/mmcblk0 --format --yes --boot-size lots --mount "$C27"
expect_exit "format: bad --boot-size: exit 1" 1
expect_grep "format: bad --boot-size: message" "boot-size must look like"
# dry-run changes nothing
: > "$MOCK_LOG"
run_cmd bash "$SCRIPT" prepare /dev/sdq --format --dry-run --mount "$C27"
expect_exit "format --dry-run: exit 0" 0
expect_grep "format --dry-run: prints sfdisk (under flock)" "dry-run: sudo flock /dev/sdq sfdisk --quiet /dev/sdq"
expect_grep "format --dry-run: warns about data loss" "DESTROY ALL DATA on /dev/sdq"
expect_true "format --dry-run: runs nothing" test ! -s "$MOCK_LOG"
# safety
run_cmd env MOCK_HOST_SRC=/dev/sdq1 bash "$SCRIPT" prepare /dev/sdq --format --yes --mount "$C27"
expect_exit "format (host disk): exit 1" 1
expect_grep "format (host disk): message" "holds the host's"
run_cmd env MOCK_LSBLK_TYPE=part bash "$SCRIPT" prepare /dev/sdq1 --format --yes --mount "$C27"
expect_exit "format (partition given): exit 1" 1
expect_grep "format (partition given): message" "not a whole disk"
: > "$MOCK_LOG"
run_cmd env MOCK_DEV_MOUNTS=/run/media/u/NIXOS_SD bash "$SCRIPT" prepare /dev/sdq --format --yes --mount "$C27"
expect_grep "format (automounted): announced" "will be unmounted"
expect_grepf "format (automounted): unmounted before partitioning" "umount -R /run/media/u/NIXOS_SD" "$MOCK_LOG"
run_cmd env MOCK_DEV_MOUNTS="[SWAP]" bash "$SCRIPT" prepare /dev/sdq --format --yes --mount "$C27"
expect_exit "format (swap): exit 1" 1
expect_grep "format (swap): message" "used as swap"
run_cmd env MOCK_RM=0 bash "$SCRIPT" prepare /dev/sdq --format --dry-run --mount "$C27"
expect_grep "format (non-removable): warns" "not a removable device"
run_cmd env RPI_ALLOW_NONBLOCK=0 bash "$SCRIPT" prepare /tmp/not-a-device --format --yes --mount "$C27"
expect_exit "format (not a block device): exit 1" 1
expect_grep "format (not a block device): message" "not a block device"
run_cmd bash "$SCRIPT" prepare /dev/sdq --format --mount "$C27" < /dev/null
expect_exit "format (no tty, no --yes): exit 1" 1
expect_grep "format (no tty, no --yes): message" "pass --yes"
run_cmd bash "$SCRIPT" prepare --format --mount "$C27"
expect_exit "format without device: exit 2" 2
run_cmd bash "$SCRIPT" build --format
expect_exit "--format on build: exit 2" 2
# an explicit DEVICE without --format must carry the labels
run_cmd bash "$SCRIPT" prepare /dev/sdq --mount "$C27"
expect_exit "prepare DEVICE (foreign card, no --format): exit 1" 1
expect_grep "prepare DEVICE (foreign card): hint" "prepare /dev/sdq --format"

# 28b. labels: an existing card with missing/wrong labels is repaired, nothing is formatted
: > "$MOCK_LOG"
run_cmd env MOCK_LABEL_BOOT= MOCK_LABEL_ROOT=old bash "$SCRIPT" prepare $DEVDIR/mmcblk0 --mount "$C27"
expect_exit "labels repaired: exit 0" 0
expect_grepf "labels: FAT label set" "fatlabel $DEVDIR/mmcblk0p1 NIXOS_BOOT" "$MOCK_LOG"
expect_grepf "labels: ext4 label set" "e2label $DEVDIR/mmcblk0p2 NIXOS_SD" "$MOCK_LOG"
expect_grepf "labels: udev refreshed" "udevadm trigger --action=change --settle" "$MOCK_LOG"
expect_not_grep "labels: never formats" "mkfs" "$MOCK_LOG"
expect_grep "labels: reported" "setting label of"
: > "$MOCK_LOG"
run_cmd bash "$SCRIPT" prepare $DEVDIR/mmcblk0 --mount "$C27"
expect_exit "labels correct: exit 0" 0
expect_not_grep "labels correct: nothing relabelled" "label" "$MOCK_LOG"
run_cmd env MOCK_FS_ROOT=btrfs bash "$SCRIPT" prepare $DEVDIR/mmcblk0 --mount "$C27"
expect_exit "labels: foreign fs: exit 1" 1
expect_grep "labels: foreign fs: message" "expected ext4"
run_cmd env MOCK_FS_BOOT= bash "$SCRIPT" prepare $DEVDIR/mmcblk0 --mount "$C27"
expect_exit "labels: unformatted partition: exit 1" 1
expect_grep "labels: unformatted: message" "unformatted"
: > "$MOCK_LOG"
run_cmd env MOCK_LABEL_ROOT=old MOCK_PART_MNT=/mnt/x bash "$SCRIPT" prepare $DEVDIR/mmcblk0 --mount "$C27"
expect_exit "labels: mounted partition not relabelled: exit 1" 1
expect_grep "labels: mounted partition: message" "unmount it first"
expect_not_grep "labels: mounted partition untouched" "e2label" "$MOCK_LOG"
: > "$MOCK_LOG"
run_cmd env MOCK_LABEL_ROOT=old bash "$SCRIPT" prepare $DEVDIR/mmcblk0 --dry-run --mount "$C27"
expect_exit "labels dry-run: exit 0" 0
expect_grep "labels dry-run: prints e2label" "dry-run: sudo e2label"
expect_true "labels dry-run: runs nothing" test ! -s "$MOCK_LOG"

# 28c. regression: sfdisk runs exactly once, under flock, after wipefs + settle
: > "$MOCK_LOG"
run_cmd bash "$SCRIPT" prepare $DEVDIR/mmcblk0 --format --yes --mount "$C27"
expect_exit "format (sfdisk once): exit 0" 0
expect_true "format: sfdisk invoked exactly once" test "$(grep -c '^sfdisk ' "$MOCK_LOG")" = 1
expect_grepf "format: partition table written under flock" "flock $DEVDIR/mmcblk0" "$MOCK_LOG"
expect_true "format: wipefs before sfdisk" test "$(grep -n '^wipefs' "$MOCK_LOG" | head -1 | cut -d: -f1)" -lt "$(grep -n '^sfdisk' "$MOCK_LOG" | head -1 | cut -d: -f1)"
expect_true "format: mkfs once per partition" test "$(grep -c '^mkfs' "$MOCK_LOG")" = 2

# 31. devices: candidates + card status
run_cmd bash "$SCRIPT" devices
expect_exit "devices: exit 0" 0
expect_grep "devices: lists removable disk" "/dev/sdq .*29.8G.*usb.*Card Reader"
expect_grep "devices: card present hint" "NIXOS_SD / NIXOS_BOOT is present"
run_cmd env RPI_BYLABEL_DIR="$T/by-label-empty" bash "$SCRIPT" devices
expect_grep "devices: no card hint" "prepare /dev/sdX --format"
run_cmd env RPI_BYLABEL_DIR="$T/by-label-empty" bash "$SCRIPT" prepare --mount "$C27"
expect_exit "prepare (no card): exit 1 (still)" 1
expect_grep "prepare (no card): lists candidates" "removable / MMC disks"

# 32. install mounts a labelled but unmounted card by itself
: > "$MOCK_LOG"
run_cmd env RPI_MOUNTPOINT_CMD=false RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --flake "$F9" --mount "$C27"
expect_grep "install: auto-mount announced" "mounting the card found by its labels"
expect_grepf "install: auto-mount mounted the root" "mount $DEVDIR/mmcblk0p2 $C27" "$MOCK_LOG"

# 33. install: card summary, space check, login check, next steps
C33="$(new_card t33)"; F34B="$(new_flake t34b)"
run_cmd env RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --flake "$F9" --mount "$C33"
expect_exit "install (ux): exit 0" 0
expect_grep "install: card summary" "target card: .* total, .* free"
expect_grep "install: duration reported" "in [0-9][0-9]*s"
expect_grep "install: next steps" "next: rpi-deploy eject"
expect_not_grep "install: no login warning when a key exists" "could not log in"
run_cmd env MOCK_CLOSURE=99999999999999999 RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --flake "$F9" --mount "$C33"
expect_exit "install (closure too big): exit 1" 1
expect_grep "install (closure too big): message" "does not fit on the card"
run_cmd env MOCK_LOGIN="pi 0 0" RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --flake "$F9" --mount "$C33"
expect_exit "install (no login, no tty): refuses" 1
expect_grep "install (no login): warns" "could not log in to the pi"
expect_grep "install (no login): aborted with advice" "aborted: add an ssh key to configuration.nix"
run_cmd env MOCK_LOGIN="pi 0 0" RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --flake "$F9" --mount "$C33" --yes
expect_exit "install (no login, --yes): installs" 0
expect_grep "install (no login, --yes): says so" "continuing because of --yes: Continue without any way to log in?"
run_cmd env MOCK_LOGIN="pi 0 0" RPI_ASSUME_TTY=1 RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --flake "$F9" --mount "$C33" <<< "n"
expect_exit "install (no login, answer n): refuses" 1
expect_grep "install (no login): question asked" "Continue without any way to log in?"
expect_not_grep "install (no login, answer n): nothing installed" "installed mock-sys"
run_cmd env MOCK_LOGIN="pi 0 0" RPI_ASSUME_TTY=1 RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --flake "$F9" --mount "$C33" <<< "y"
expect_exit "install (no login, answer y): installs" 0
run_cmd env "${EMUL_OK[@]}" MOCK_LOGIN="pi 0 0" bash "$SCRIPT" build --flake "$F34B"
expect_exit "build (no login, no tty): asks before the long build -> refuses" 1
expect_true "build (no login): nothing built" test ! -f "$F34B/.rpi-build/last"
run_cmd env "${EMUL_OK[@]}" MOCK_LOGIN="pi 0 0" RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" all --flake "$F34B" --mount "$C33" --yes
expect_exit "all (no login, --yes): exit 0" 0
expect_true "all (no login): asked only once" test "$(grep -c 'Continue without any way to log in' "$OUT")" = 1
run_cmd env MOCK_LOGIN="pi 0 1" RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --flake "$F9" --mount "$C33"
expect_not_grep "install (password set): no warning" "could not log in"
run_cmd env MOCK_LOGIN="garbage" RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --flake "$F9" --mount "$C33"
expect_not_grep "install (unparsable login info): silent" "could not log in"

# 34. build: next steps; no colour codes when not on a terminal
F34="$(new_flake t34)"
run_cmd env "${EMUL_OK[@]}" bash "$SCRIPT" build --flake "$F34"
expect_exit "build (ux): exit 0" 0
expect_grep "build: duration reported" "built in [0-9][0-9]*s"
expect_grep "build: next steps" "next: insert the SD card"
expect_not_grep "no ANSI colours off a tty" $'\033'
run_cmd env "${EMUL_OK[@]}" bash "$SCRIPT" all --flake "$F34" --mount "$C33"
expect_not_grep "all: no premature next-step hint after build" "next: insert the SD card"

# 29a. two cards with the same labels: ambiguous, never guess
run_cmd env MOCK_DUP_LABELS='/dev/sdx2 NIXOS_SD\n/dev/sdy2 NIXOS_SD\n/dev/sdx1 NIXOS_BOOT' bash "$SCRIPT" prepare --mount "$C27"
expect_exit "duplicate labels: exit 1" 1
expect_grep "duplicate labels: explained" "label is ambiguous"
expect_grep "duplicate labels: lists the partitions" "NIXOS_SD: /dev/sdx2 /dev/sdy2"
run_cmd env MOCK_DUP_LABELS='/dev/sdx2 NIXOS_SD\n/dev/sdx1 NIXOS_BOOT' bash "$SCRIPT" prepare --mount "$C27"
expect_exit "unique labels: exit 0" 0
run_cmd env MOCK_DUP_LABELS='/dev/sdx2 NIXOS_SD\n/dev/sdy2 NIXOS_SD' bash "$SCRIPT" prepare /dev/sdq --mount "$C27"
expect_exit "duplicate labels + foreign DEVICE: exit 1" 1
expect_grep "duplicate labels + DEVICE: hint to unplug" "unplug it"

# 35. nixos-install runs `activate` inside a chroot of the card: an aarch64
#     binfmt handler without the F flag is not found there (the real failure:
#     "chroot: failed to run command .../activate: No such file or directory").
#     The script tests the chroot with the system's own bash BEFORE nixos-install.
C35="$(new_card t35)"; INTERP="$T/fake-run/binfmt/aarch64-linux"
chroot_line() { grep -n '^chroot ' "$MOCK_LOG" | head -1 | cut -d: -f1; }

# (a) the chroot works: nothing to do, whatever the flags say
: > "$MOCK_LOG"
run_cmd env RPI_BINMFT_DIR="$T/bmf-nof" MOCK_INTERP="$INTERP" bash "$SCRIPT" install --flake "$F9" --mount "$C35"
expect_exit "chroot emu (works): exit 0" 0
expect_grep "chroot emu (works): reported" "aarch64 binaries start (emulation works inside the chroot)"
expect_not_grep "chroot emu (works): no bridging" "bridging the interpreter"
expect_grepf "chroot emu (works): tested with the system's own bash" "chroot $C35 $T/mock-sys/sw/bin/bash -c true" "$MOCK_LOG"
expect_true "chroot emu (works): tested before nixos-install" test "$(chroot_line)" -lt "$(grep -n '^nixos-install' "$MOCK_LOG" | tail -1 | cut -d: -f1)"

# (b) no F flag, chroot fails until the interpreter is bridged -> bridged, retested, installed
: > "$MOCK_LOG"
run_cmd env RPI_BINMFT_DIR="$T/bmf-nof" MOCK_INTERP="$INTERP" MOCK_CHROOT_NEEDS="$INTERP" bash "$SCRIPT" install --flake "$F9" --mount "$C35"
expect_exit "chroot emu (bridge needed): exit 0" 0
expect_grep "chroot emu (bridge needed): says it does not start" "do not start inside a chroot of the card"
expect_grep "chroot emu (bridge needed): explained" "has no F flag"
expect_grep "chroot emu (bridge needed): names the permanent fix" "preferStaticEmulators"
expect_grep "chroot emu (bridge needed): works afterwards" "start now (through the bridged interpreter)"
expect_grepf "chroot emu (bridge needed): interpreter closure copied into the card" "nix copy --no-check-sigs --to $C35 $(readlink -f "$BASH_BIN" | sed -E 's|^(/nix/store/[^/]+).*|\1|')" "$MOCK_LOG"
expect_grepf "chroot emu (bridge needed): interpreter visible in the chroot during nixos-install" "interp-visible-in-chroot" "$MOCK_LOG"
expect_true "chroot emu (bridge needed): bridge removed afterwards" test ! -e "$C35$INTERP" -a ! -L "$C35$INTERP"
expect_true "chroot emu (bridge needed): empty dir removed too" test ! -d "$C35$(dirname "$INTERP")"
expect_true "chroot emu (bridge needed): bridged before nixos-install" test "$(grep -n 'nix copy.*bash' "$MOCK_LOG" | tail -1 | cut -d: -f1)" -lt "$(grep -n '^nixos-install' "$MOCK_LOG" | tail -1 | cut -d: -f1)"

# (c) the bridge does not help either: stop BEFORE nixos-install, with facts
: > "$MOCK_LOG"
run_cmd env RPI_BINMFT_DIR="$T/bmf-nof" MOCK_INTERP="$INTERP" MOCK_CHROOT_FAIL=1 bash "$SCRIPT" install --flake "$F9" --mount "$C35"
expect_exit "chroot emu (hopeless): exit 1" 1
expect_grep "chroot emu (hopeless): refuses to run a doomed install" "would fail. Nothing was installed"
expect_grep "chroot emu (hopeless): prints the binfmt entry" "binfmt entry  :"
expect_grep "chroot emu (hopeless): prints the interpreter" "interpreter   : "
expect_grep "chroot emu (hopeless): prints the chroot error" "chroot output : chroot: failed to run command"
expect_grep "chroot emu (hopeless): host fix" "emulatedSystems"
expect_not_grep "chroot emu (hopeless): nixos-install not started" "^nixos-install" "$MOCK_LOG"
expect_true "chroot emu (hopeless): bridge removed" test ! -L "$C35$INTERP"
expect_not_grep "chroot emu (hopeless): no success claim" "installed mock-sys"

# (d) F flag set but the chroot still fails: do not pretend, show the facts
run_cmd env RPI_BINMFT_DIR="$T/bmf-ok" MOCK_CHROOT_FAIL=1 bash "$SCRIPT" install --flake "$F9" --mount "$C35"
expect_exit "chroot emu (F flag, still failing): exit 1" 1
expect_grep "chroot emu (F flag, still failing): message" "has the F flag, which should work in a chroot"
expect_grep "chroot emu (F flag, still failing): facts" "chroot output :"

# (e) binfmt entry unreadable and the chroot fails
run_cmd env RPI_BINMFT_DIR="$T/bmf-empty" RPI_BINMFT_RUN="$T/bmf-ok" MOCK_CHROOT_FAIL=1 bash "$SCRIPT" install --flake "$F9" --mount "$C35"
expect_exit "chroot emu (entry unreadable, failing): exit 1" 1
expect_grep "chroot emu (entry unreadable): message" "no aarch64 binfmt handler is readable"
run_cmd env RPI_BINMFT_DIR="$T/bmf-empty" RPI_BINMFT_RUN="$T/bmf-ok" bash "$SCRIPT" install --flake "$F9" --mount "$C35"
expect_exit "chroot emu (entry unreadable, chroot works): exit 0" 0

# (f) nixos-install itself failing: bridge removed, advice printed
: > "$MOCK_LOG"
run_cmd env RPI_BINMFT_DIR="$T/bmf-nof" MOCK_INTERP="$INTERP" MOCK_CHROOT_NEEDS="$INTERP" MOCK_NIXOS_INSTALL_RC=3 bash "$SCRIPT" install --flake "$F9" --mount "$C35"
expect_exit "nixos-install failure: exit 1" 1
expect_true "nixos-install failure: bridge still removed" test ! -L "$C35$INTERP"
expect_grep "nixos-install failure: safe to re-run" "re-run 'rpi-deploy install'"
expect_not_grep "nixos-install failure: no success claim" "installed mock-sys"

# (g) dry-run shows the bridge steps without touching the card
: > "$MOCK_LOG"
run_cmd env RPI_BINMFT_DIR="$T/bmf-nof" bash "$SCRIPT" install --dry-run --flake "$F9" --mount "$C35"
expect_exit "chroot emu dry-run: exit 0" 0
expect_grep "chroot emu dry-run: prints the symlink" "dry-run: sudo ln -sfn"
expect_true "chroot emu dry-run: runs nothing" test ! -s "$MOCK_LOG"

# (h) show reports it
run_cmd env RPI_BINMFT_DIR="$T/bmf-nof" bash "$SCRIPT" show --flake "$F9"
expect_grep "show: chroot emulation bridged" "chroot emu .*bridged automatically"
run_cmd env RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" show --flake "$F9"
expect_grep "show: chroot emulation ok" "chroot emu .*ok"

# 36. sudo: authenticate once up front (the copy outlasts the sudo timeout)
: > "$MOCK_LOG"
run_cmd env RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --flake "$F9" --mount "$C35"
expect_grepf "sudo: authenticated up front" "sudo -v" "$MOCK_LOG"
expect_true "sudo: authenticated before the card copy" test "$(grep -n '^sudo -v' "$MOCK_LOG" | head -1 | cut -d: -f1)" -lt "$(grep -n 'nix copy' "$MOCK_LOG" | head -1 | cut -d: -f1)"
run_cmd env MOCK_SUDO_FAIL=1 RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --flake "$F9" --mount "$C35"
expect_exit "sudo refused: exit 1" 1
expect_grep "sudo refused: message" "sudo authentication failed"
: > "$MOCK_LOG"
run_cmd env RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" install --dry-run --flake "$F9" --mount "$C35"
expect_true "sudo: no password prompt in dry-run" test ! -s "$MOCK_LOG"
: > "$MOCK_LOG"
run_cmd env "${EMUL_OK[@]}" RPI_BINMFT_DIR="$T/bmf-ok" bash "$SCRIPT" all --flake "$(new_flake t36)" --mount "$C35" --yes
expect_true "sudo (all): password asked once, before the long build" test "$(grep -c '^sudo -v' "$MOCK_LOG")" = 1
run_cmd env "${EMUL_OK[@]}" bash "$SCRIPT" build --flake "$(new_flake t36b)"
expect_not_grep "sudo: build never asks for it" "root access is needed"
: > "$MOCK_LOG"
run_cmd bash "$SCRIPT" show --flake "$F9"
expect_true "sudo: show does not ask" test ! -s "$MOCK_LOG"

# 29. eject
: > "$MOCK_LOG"
run_cmd bash "$SCRIPT" eject --mount "$C27"
expect_exit "eject: exit 0" 0
expect_grepf "eject: syncs" "sync" "$MOCK_LOG"
expect_grepf "eject: unmounts recursively" "umount -R $C27" "$MOCK_LOG"
: > "$MOCK_LOG"
run_cmd env RPI_MOUNTPOINT_CMD=false bash "$SCRIPT" eject --mount "$C27"
expect_exit "eject (not mounted): exit 0" 0
expect_not_grep "eject (not mounted): nothing unmounted" "umount" "$MOCK_LOG"

# 30. show reports card + firmware state
run_cmd env RPI_MOUNTPOINT_CMD=mp-nofw bash "$SCRIPT" show --flake "$F26" --mount "$C27"
expect_exit "show: exit 0" 0
expect_grep "show: firmware not mounted" "firmware: NOT mounted"

# --- summary -----------------------------------------------------------------
echo
echo "rpi-deploy unit tests: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
