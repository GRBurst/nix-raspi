#!/usr/bin/env bash
#
# Unit tests for rpi-deploy.sh and rpi-lib.sh (check `rpi-deploy-unit`).
#
#   RPI_DEPLOY_SRC=rpi-deploy.sh RPI_LIB=rpi-lib.sh FIXTURES=tests/fixtures \
#     bash tests/deploy-unit.sh
#
# (all three default to the files next to this test, so a plain
# `bash tests/deploy-unit.sh` works in a checkout).
#
# nix, ssh, sudo, lsblk, findmnt, dd and nixos-rebuild are mocks (see
# tests/harness.sh); git, zstd and coreutils are real. `flash` only ever
# writes to regular files under the test's temp dir: the dd mock refuses any
# other target, so these tests can never touch a real device.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RPI_DEPLOY_SRC="${RPI_DEPLOY_SRC:-$HERE/../rpi-deploy.sh}"
export RPI_LIB="${RPI_LIB:-$HERE/../rpi-lib.sh}"
FIXTURES="${FIXTURES:-$HERE/fixtures}"

# shellcheck source=tests/harness.sh
source "$HERE/harness.sh"

# The caller's environment must not leak into the tests.
unset RPI_FLAKE RPI_SSH_OPTS RPI_NIXOS_REBUILD RPI_CACHE_URL RPI_ALLOW_NONBLOCK \
    RL_FLAKE RL_ATTR RL_TARGET RL_SSH_PORT RL_SSH_OPTS RL_CACHE_URL NIX_SSHOPTS

# lib FUNC ARGS...: call a rpi-lib.sh function in a fresh subshell, so the
# globals pick up the environment of the call site.
lib() { (
    # shellcheck source=rpi-lib.sh
    source "$RPI_LIB" || exit 99
    "$@"
); }

# first_line ERE: line number of the first matching mock-log line (999999 if none)
first_line() { grep -nE -- "$1" "$MOCK_LOG" | head -n1 | cut -d: -f1 | grep . || echo 999999; }

# --- mocks -------------------------------------------------------------------
export K_DEF=/nix/store/kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk-linux_rpi-bcm2711-6.18.52
export M_DEF=/nix/store/mmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmm-linux_rpi-bcm2711-6.18.52-modules

# nix: kernel/modules eval ($MOCK_K/$MOCK_M; MOCK_EVAL_RC fails it),
# path-info --store (hit iff the path is in $MOCK_CACHED, default both;
# MOCK_NETERR prints a network error), build --dry-run (cat $MOCK_DRY to
# stderr; MOCK_DRY_RC fails it), build --out-link L (creates the image under
# L), run (the pinned nixos-rebuild; logged only).
mock nix <<'EOF'
k="${MOCK_K-$K_DEF}" m="${MOCK_M-$M_DEF}"
case " $* " in
*" eval "*".kernel.modules.outPath "* | *" eval "*".kernel.outPath "*)
    if [[ -n "${MOCK_EVAL_RC:-}" ]]; then echo "error: evaluation aborted" >&2; exit "$MOCK_EVAL_RC"; fi
    case " $* " in *".kernel.modules.outPath "*) printf '%s' "$m" ;; *) printf '%s' "$k" ;; esac ;;
*" path-info "*)
    p="${!#}"
    case " ${MOCK_CACHED-$k $m} " in *" $p "*) echo "$p"; exit 0 ;; esac
    if [[ -n "${MOCK_NETERR:-}" ]]; then
        echo "error: unable to download 'https://nixos-raspberrypi.cachix.org/x.narinfo': Couldn't resolve host name (6)" >&2
    else
        echo "error: path '$p' is not valid" >&2
    fi
    exit 1 ;;
*" build "*" --dry-run "*)
    if [[ -n "${MOCK_DRY_RC:-}" ]]; then echo "error: attribute 'rpi' missing" >&2; exit "$MOCK_DRY_RC"; fi
    cat "${MOCK_DRY:-/dev/null}" >&2 ;;
*" build "*" --out-link "*)
    if [[ -n "${MOCK_BUILD_RC:-}" ]]; then echo "error: build failed" >&2; exit "$MOCK_BUILD_RC"; fi
    prev=""
    for a in "$@"; do
        if [[ "$prev" == --out-link ]]; then
            mkdir -p "$a/sd-image"
            printf '0123456789' >"$a/sd-image/neptun-rpi3.img.zst"
        fi
        prev="$a"
    done ;;
esac
exit 0
EOF

# =============================================================================
# T5.1 dry-run parsing + build guard
# =============================================================================
HYB="$FIXTURES/dry-run-hybrid.txt"
KER="$FIXTURES/dry-run-kernel.txt"

run_cmd g1 -- lib rl_built_names <"$HYB"
header_n=$(sed -nE 's/^these ([0-9]+) derivations will be built:$/\1/p' "$HYB")
expect_eq "g1 hybrid fixture: one name per built derivation (= header N)" "$header_n" "$(grep -c . "$OUT")"
expect_eq "g1 hybrid header N is 377" 377 "$header_n"
expect_not_grep "g1 names carry no store prefix" "/nix/store/" "$OUT"
expect_not_grep "g1 names carry no .drv suffix" ".drv" "$OUT"
expect_not_grep "g1 the evaluation warning line is ignored" "evaluation warning" "$OUT"

run_cmd g2 -- lib rl_check_builds "$HYB" 500
expect_exit "g2 hybrid fixture is allowed" 0

run_cmd g3 -- lib rl_check_builds "$KER" 500
expect_exit "g3 kernel fixture is forbidden" 11
expect_grepf "g3 lists linux-config" "linux-config-6.18.34-unstable_20260604" "$ERR"
expect_grep "g3 lists the kernel" "(^|[^-])linux_rpi-bcm2711-6\.18\.34-unstable_20260604$" "$ERR"
expect_grepf "g3 lists kernel-intermediate-config" "kernel-intermediate-config" "$ERR"

run_cmd g4 -- lib rl_check_builds "$KER" 500
expect_not_grep "g4 initrd-linux_rpi is not forbidden" "initrd-linux_rpi" "$ERR"
expect_not_grep "g4 kernel modules are not forbidden" "-modules" "$ERR"
expect_not_grep "g4 installkernel is not forbidden" "installkernel" "$ERR"

run_cmd g5 -- lib rl_check_builds "$HYB" 300
expect_exit "g5 too many builds" 12
expect_grepf "g5 reports N > MAX" "377 > 300" "$ERR"

run_cmd g6 -- lib rl_built_names <"$FIXTURES/dry-run-single.txt"
expect_eq "g6 single fixture -> one name" "nixos-system-neptun-26.05" "$(cat "$OUT")"

run_cmd g7 -- lib rl_built_names <"$FIXTURES/dry-run-none.txt"
expect_eq "g7 none fixture -> no names" "" "$(cat "$OUT")"
run_cmd g7 -- lib rl_check_builds "$FIXTURES/dry-run-none.txt" 500
expect_exit "g7 none fixture is allowed" 0

# =============================================================================
# T5.2 cache guard + rl_guard
# =============================================================================
export RL_FLAKE=/flk

reset_log
run_cmd g8 -- lib rl_cache_has "$K_DEF" "$M_DEF"
expect_exit "g8 kernel + modules cached -> 0" 0
expect_grepf "g8 asks nvmd's cachix" "nix path-info --store https://nixos-raspberrypi.cachix.org" "$MOCK_LOG"

run_cmd g8 -- lib rl_kernel_paths
expect_eq "g8 rl_kernel_paths prints kernel and modules" "$K_DEF"$'\n'"$M_DEF" "$(cat "$OUT")"
expect_grepf "g8 kernel path from the flake's config" "/flk#nixosConfigurations.rpi.config.boot.kernelPackages.kernel.outPath" "$MOCK_LOG"

reset_log
MOCK_CACHED="$K_DEF" MOCK_DRY="$HYB" run_cmd g9 -- lib rl_guard toplevel 500
expect_exit "g9 modules missing from the cache -> RL_E_CACHE" 10
MOCK_CACHED="" MOCK_NETERR=1 MOCK_DRY="$HYB" run_cmd g9 -- lib rl_guard toplevel 500
expect_exit "g9 path-info network error counts as a miss -> RL_E_CACHE" 10

reset_log
MOCK_DRY="$HYB" run_cmd g10 -- lib rl_guard toplevel 500
expect_exit "g10 cached kernel + hybrid dry run -> 0" 0
expect_grep "g10 dry run of the toplevel" "^nix build .*--dry-run.* /flk#nixosConfigurations\.rpi\.config\.system\.build\.toplevel( |$)" "$MOCK_LOG"
expect_true "g10 order: path-info before the dry run" \
    test "$(first_line ' path-info ')" -lt "$(first_line ' --dry-run ')"

reset_log
MOCK_DRY="$KER" run_cmd g10 -- lib rl_guard sdImage 500
expect_exit "g10 kernel build in the dry run -> RL_E_FORBIDDEN" 11
expect_grep "g10 sdImage dry run" "^nix build .*--dry-run.*\.config\.system\.build\.sdImage( |$)" "$MOCK_LOG"

reset_log
MOCK_CACHED="" MOCK_DRY="$HYB" run_cmd g11 -- lib rl_guard toplevel 500
expect_eq "g11 cache miss -> no dry run" 0 "$(log_count ' --dry-run ')"
expect_grepf "g11 names the missing path" "$K_DEF" "$ERR"

reset_log
MOCK_DRY_RC=1 run_cmd g12 -- lib rl_guard toplevel 500
expect_exit "g12 dry-run eval error -> RL_E_BUILD" 13
expect_grepf "g12 shows nix's error" "attribute 'rpi' missing" "$ERR"

reset_log
MOCK_EVAL_RC=1 run_cmd g12 -- lib rl_guard toplevel 500
expect_exit "g12 kernel eval error -> RL_E_BUILD" 13
expect_eq "g12 kernel eval error -> no cache query" 0 "$(log_count ' path-info ')"
unset RL_FLAKE

# =============================================================================
# T5.3 reboot decision + ssh helpers
# =============================================================================
run_cmd r1 -- lib rl_needs_reboot "/k /i /m" "/k /i /m"
expect_exit "r1 equal triplets -> no reboot" 1
run_cmd r2 -- lib rl_needs_reboot "/k2 /i /m" "/k /i /m"
expect_exit "r2 kernel differs -> reboot" 0
run_cmd r3 -- lib rl_needs_reboot "/k /i2 /m" "/k /i /m"
expect_exit "r3 initrd differs -> reboot" 0
run_cmd r4 -- lib rl_needs_reboot "/k /i /m2" "/k /i /m"
expect_exit "r4 kernel-modules differ -> reboot" 0

RL_SSH_PORT=22 RPI_SSH_OPTS="-F x" run_cmd r5 -- lib rl_sshopts
expect_eq "r5 rl_sshopts" "-p 22 -F x" "$(cat "$OUT")"
run_cmd r5 -- lib rl_sshopts
expect_eq "r5 rl_sshopts default port" "-p 2222" "$(cat "$OUT")"

TOP="$T/toplevel"
mkdir -p "$T/store/k" "$T/store/m" "$TOP"
: >"$T/store/k/Image"; : >"$T/store/initrd"
ln -s "$T/store/k/Image" "$TOP/kernel"
ln -s "$T/store/initrd" "$TOP/initrd"
ln -s "$T/store/m" "$TOP/kernel-modules"
run_cmd r6 -- lib rl_triplet_local "$TOP"
expect_eq "r6 rl_triplet_local resolves kernel, initrd, kernel-modules" \
    "$T/store/k/Image $T/store/initrd $T/store/m" "$(cat "$OUT")"

mock ssh <<'EOF'
exit 0
EOF
reset_log
RPI_SSH_OPTS="-F x -o A=b" run_cmd r7 -- lib rl_ssh true
expect_eq "r7 rl_ssh argv" "ssh -p 2222 -F x -o A=b root@neptun true" "$(cat "$MOCK_LOG")"

# =============================================================================
# T5.4 CLI skeleton
# =============================================================================
rd() { bash "$RPI_DEPLOY_SRC" "$@"; }
reset_log

run_cmd c1 -- rd --help
expect_exit "c1 --help exits 0" 0
expect_grep "c1 usage lists image" "rpi-deploy image" "$OUT"
expect_grepf "c1 usage lists flash IMAGE DEVICE" "flash IMAGE DEVICE" "$OUT"
expect_grep "c1 usage lists deploy" "rpi-deploy deploy" "$OUT"
expect_grep "c1 usage lists status" "rpi-deploy status" "$OUT"
run_cmd c1 -- rd deploy --help
expect_exit "c1 SUBCOMMAND --help exits 0" 0

for sub in prepare install config eject build show all devices; do
    run_cmd c2 -- rd "$sub"
    expect_exit "c2 removed subcommand '$sub' -> exit 2" 2
    expect_grepf "c2 '$sub': unknown subcommand" "unknown subcommand" "$ERR"
done

run_cmd c3 -- rd
expect_exit "c3 no args -> exit 2" 2
expect_grepf "c3 no args prints the usage" "flash IMAGE DEVICE" "$ERR"

run_cmd c4 -- rd deploy --frobnicate
expect_exit "c4 unknown option -> exit 2" 2
run_cmd c4 -- rd deploy --port
expect_exit "c4 option without value -> exit 2" 2
run_cmd c4 -- rd deploy --port abc
expect_exit "c4 non-numeric --port -> exit 2" 2
run_cmd c4 -- rd deploy --max-builds 1x
expect_exit "c4 non-numeric --max-builds -> exit 2" 2
run_cmd c4 -- rd status --force
expect_exit "c4 option of another subcommand -> exit 2" 2
run_cmd c4 -- rd image extra
expect_exit "c4 surplus argument -> exit 2" 2
expect_eq "c4 usage errors never reach nix/ssh" 0 "$(log_count '^(nix|ssh) ')"

# =============================================================================
# T5.5 image
# =============================================================================
W="$T/work"
mkdir -p "$W"
image_in_w() { (cd "$W" && RPI_FLAKE=/flk rd image "$@"); }

reset_log
MOCK_DRY="$HYB" run_cmd i1 -- image_in_w
expect_exit "i1 image succeeds" 0
expect_grep "i1 builds the flake's sdImage into ./result-rpi-image" \
    "^nix build .*--out-link $W/result-rpi-image .*/flk#nixosConfigurations\.rpi\.config\.system\.build\.sdImage( |$)" "$MOCK_LOG"
expect_true "i1 order: path-info < dry run < build" test \
    "$(first_line ' path-info ')" -lt "$(first_line ' --dry-run .*build\.sdImage')" -a \
    "$(first_line ' --dry-run ')" -lt "$(first_line ' --out-link ')"
expect_grep "i3 prints the image path" "$W/result-rpi-image/sd-image/neptun-rpi3\.img\.zst$" "$OUT"
expect_grep "i3 prints the size" "size: *10( |B|$)" "$OUT"

reset_log
MOCK_CACHED="" MOCK_DRY="$HYB" run_cmd i2 -- image_in_w
expect_exit "i2 kernel not cached -> RL_E_CACHE" 10
expect_eq "i2 no real build" 0 "$(log_count '^nix build .*--out-link')"

reset_log
MOCK_DRY="$KER" run_cmd i2 -- image_in_w
expect_exit "i2 kernel build in the dry run -> RL_E_FORBIDDEN" 11
expect_eq "i2 forbidden -> no real build" 0 "$(log_count '^nix build .*--out-link')"

reset_log
MOCK_DRY="$HYB" run_cmd i2 -- image_in_w --max-builds 10
expect_exit "i2 --max-builds is honoured -> RL_E_TOO_MANY" 12

reset_log
MOCK_DRY="$HYB" MOCK_BUILD_RC=1 run_cmd i2 -- image_in_w
expect_exit "i2 failing image build -> RL_E_BUILD" 13

reset_log
MOCK_DRY="$HYB" run_cmd i4 -- image_in_w --out "$T/imgout" --flake /other --attr neptun
expect_exit "i4 image --out succeeds" 0
expect_grep "i4 out-link in --out DIR, --flake/--attr honoured" \
    "^nix build .*--out-link $T/imgout/result-rpi-image .*/other#nixosConfigurations\.neptun\.config\.system\.build\.sdImage" "$MOCK_LOG"
expect_grepf "i4 prints the image under --out" "$T/imgout/result-rpi-image/sd-image/neptun-rpi3.img.zst" "$OUT"

# =============================================================================
# T5.6 flash (devices are regular files under $T; lsblk/findmnt/sudo/dd mocked)
# =============================================================================
REAL_DD="$(PATH="${PATH#"$BIN:"}" command -v dd)"
export REAL_DD MOCK_ROOT="$T"

# lsblk: one property per call (-dno PROP DEV), the mount points of DEV and
# its partitions (-nlo MOUNTPOINTS), and the inverse chain of the root
# source (-nlso NAME SRC: SRC's name, then $MOCK_PKNAME).
mock lsblk <<'EOF'
dev="${!#}"
case " $* " in
*" -nlso NAME "*) printf '%s\n%s\n' "$(basename "$dev")" "${MOCK_PKNAME:-nvme0n1}" ;;
*" MOUNTPOINTS "*)
    if [[ -n "${MOCK_MOUNTS_FAIL:-}" ]]; then echo "lsblk: unknown column: MOUNTPOINTS" >&2; exit 1; fi
    printf '\n%s\n\n' "${MOCK_MOUNTS:-}" ;;
*" RM "*) echo "  ${MOCK_RM-1}" ;;
*" TYPE "*) echo "${MOCK_TYPE-disk}" ;;
*" MODEL "*) echo "${MOCK_MODEL-Generic STORAGE DEVICE}   " ;;
*" SIZE "*) echo " ${MOCK_SIZE-29.7G}" ;;
*) echo "lsblk mock: unexpected call: $*" >&2; exit 1 ;;
esac
EOF

mock findmnt <<'EOF'
echo "${MOCK_ROOTSRC-/dev/nvme0n1p2}"
EOF

mock sudo <<'EOF'
if [[ -n "${MOCK_READBACK_FAIL:-}" && "$1" == head ]]; then echo "head: cannot open: Permission denied" >&2; exit 1; fi
exec "$@"
EOF

# dd: never writes outside the test dir; drops oflag=direct (no O_DIRECT on
# tmpfs); MOCK_DD_CORRUPT=1 flips one byte after writing.
mock dd <<'EOF'
args=() of=""
for a in "$@"; do
    case "$a" in
    oflag=direct) continue ;;
    of=*) of="${a#of=}" ;;
    esac
    args+=("$a")
done
case "$of" in
"$MOCK_ROOT"/*) ;;
*) echo "dd mock: refusing to write outside the test dir: '$of'" >&2; exit 99 ;;
esac
"$REAL_DD" "${args[@]}" || exit
if [[ "${MOCK_DD_CORRUPT:-}" == 1 ]]; then
    printf 'X' | "$REAL_DD" of="$of" bs=1 seek=100 conv=notrunc status=none
fi
EOF

IMG="$T/neptun-rpi3.img.zst"
printf 'NIXIMG%.0s' {1..1000} | zstd -q >"$IMG"
mkdir -p "$T/dev"
DEV="$T/dev/sdz"
new_dev() { head -c 65536 /dev/zero >"$DEV"; }
dev_sum() { sha256sum <"$DEV" | cut -d' ' -f1; }
new_dev
ZERO_SUM="$(dev_sum)"
export RPI_ALLOW_NONBLOCK=1

refused() {  # NAME: exit RL_E_DEVICE, nothing written, no sudo
    expect_exit "$1 -> RL_E_DEVICE" 16
    expect_eq "$1: device unchanged" "$ZERO_SUM" "$(dev_sum)"
    expect_eq "$1: no sudo" 0 "$(log_count '^sudo ')"
}

reset_log; new_dev
MOCK_RM=0 run_cmd f1 -- rd flash "$IMG" "$DEV" <<<"sdz"
refused "f1 flash refuses non-removable disk"
expect_grepf "f1 says not removable" "not removable" "$ERR"

reset_log; new_dev
MOCK_MOUNTS=/run/media/x run_cmd f2 -- rd flash "$IMG" "$DEV" <<<"sdz"
refused "f2 flash refuses a disk with a mounted partition"
expect_grepf "f2 names the mount point" "/run/media/x" "$ERR"

reset_log; new_dev
MOCK_ROOTSRC=/dev/sdz2 MOCK_PKNAME=sdz run_cmd f3 -- rd flash "$IMG" "$DEV" <<<"sdz"
refused "f3 flash refuses the disk holding /"
expect_grepf "f3 names the root source" "/dev/sdz2" "$ERR"

reset_log; new_dev
RPI_ALLOW_NONBLOCK=0 run_cmd f4 -- rd flash "$IMG" "$DEV" <<<"sdz"
refused "f4 flash refuses a non-block device"
expect_grepf "f4 says not a block device" "not a block device" "$ERR"

reset_log; new_dev
MOCK_TYPE=part run_cmd f12 -- rd flash "$IMG" "$DEV" <<<"sdz"
refused "f12 flash refuses a partition"

reset_log; new_dev
run_cmd f5 -- rd flash "$IMG" "$DEV" <<<"sdx"
refused "f5 confirmation typo"
expect_eq "f5 confirmation typo: no dd" 0 "$(log_count '^dd ')"
reset_log; new_dev
run_cmd f5 -- rd flash "$IMG" "$DEV"
refused "f5 no confirmation (EOF)"

reset_log; new_dev
run_cmd f6 -- rd flash "$IMG" "$DEV" <<<"sdz"
expect_exit "f6 flash succeeds" 0
expect_grepf "f6 shows the model" "Generic STORAGE DEVICE" "$OUT"
expect_grepf "f6 shows the size" "29.7G" "$OUT"
expect_grepf "f6 asks to type the device name" "type the device name" "$OUT"
for flag in bs=4M conv=fsync oflag=direct status=progress "of=$DEV"; do
    expect_grep "f6 dd has $flag" "^dd (.* )?$flag( |$)" "$MOCK_LOG"
done
expect_grep "f6 dd runs under sudo" "^sudo dd " "$MOCK_LOG"
expect_grepf "f7 verified" "verified" "$OUT"
expect_true "f7 the device starts with the image" \
    cmp -s -n "$(zstdcat "$IMG" | wc -c)" <(zstdcat "$IMG") "$DEV"
expect_eq "f10 sudo only for the write and the read-back" 2 "$(log_count '^sudo ')"
expect_eq "f10 sudo dd once" 1 "$(log_count '^sudo dd ')"
expect_eq "f10 sudo read-back once" 1 "$(log_count "^sudo head -c [0-9]+ $DEV\$")"

reset_log; new_dev
MOCK_DD_CORRUPT=1 run_cmd f8 -- rd flash "$IMG" "$DEV" <<<"sdz"
expect_exit "f8 corrupt write -> RL_E_VERIFY" 17
expect_grepf "f8 says verify failed" "verify failed" "$ERR"

reset_log
run_cmd f9 -- rd flash "$T/missing.img.zst" "$DEV" <<<"sdz"
expect_exit "f9 missing IMAGE -> exit 2" 2
expect_eq "f9 no device query" 0 "$(log_count '^(lsblk|sudo|dd) ')"

reset_log; new_dev
run_cmd f13 -- rd flash "$IMG" "$DEV" <<<"$DEV"
expect_exit "f13 typing the full device path also confirms" 0

# MMC/SD block devices never carry the kernel's removable flag (see
# flash_check_device), so a card in a built-in reader is mmcblkN with RM=0.
reset_log
MMC="$T/dev/mmcblk0"
head -c 65536 /dev/zero >"$MMC"
MOCK_RM=0 run_cmd f11 -- rd flash "$IMG" "$MMC" <<<"mmcblk0"
expect_exit "f11 an SD card in a built-in reader (mmcblk0, RM=0) is accepted" 0
expect_grepf "f11 verified" "verified" "$OUT"
reset_log
MOCK_RM=0 MOCK_ROOTSRC=/dev/mmcblk0p2 MOCK_PKNAME=mmcblk0 run_cmd f11 -- rd flash "$IMG" "$MMC" <<<"mmcblk0"
expect_exit "f11 an mmcblk holding / is still refused" 16

reset_log; new_dev
MOCK_MOUNTS_FAIL=1 run_cmd f14 -- rd flash "$IMG" "$DEV" <<<"sdz"
refused "f14 mount points unknown (lsblk fails) -> fail closed"

reset_log; new_dev
MOCK_READBACK_FAIL=1 run_cmd f15 -- rd flash "$IMG" "$DEV" <<<"sdz"
expect_exit "f15 read-back failure -> RL_E_VERIFY" 17
expect_grepf "f15 says verify failed" "verify failed" "$ERR"
unset RPI_ALLOW_NONBLOCK

# =============================================================================
# T5.7 deploy
# =============================================================================
# nr-mock: the nixos-rebuild under test (RPI_NIXOS_REBUILD); logs argv + env.
mock nr-mock <<'EOF'
printf 'NIX_SSHOPTS=%s\n' "${NIX_SSHOPTS-unset}" >>"$MOCK_LOG"
printf 'NIX_CONFIG=%s\n' "${NIX_CONFIG-unset}" | tr '\n' ' ' >>"$MOCK_LOG"; echo >>"$MOCK_LOG"
exit "${MOCK_NR_RC:-0}"
EOF
# The host's nixos-rebuild (newer release) must never run.
mock nixos-rebuild <<'EOF'
echo POISON >>"$MOCK_LOG"
exit 1
EOF
# ssh: the Pi's current/booted system and their kernel triplets.
mock ssh <<'EOF'
if [[ -n "${MOCK_SSH_FAIL:-}" ]]; then
    echo "ssh: connect to host neptun port 2222: Connection refused" >&2
    exit 255
fi
case " $* " in
*" readlink /run/current-system /run/booted-system "*)
    printf '%s\n%s\n' "${MOCK_CUR-/nix/store/cccc-nixos-system-neptun-2}" \
        "${MOCK_BOOTED-/nix/store/bbbb-nixos-system-neptun-1}" ;;
*" readlink -f /run/current-system/kernel "*)
    printf '%s\n' ${MOCK_CUR_TRIPLET-/nix/store/k1/Image /nix/store/i1/initrd /nix/store/m1} ;;
*" readlink -f /run/booted-system/kernel "*)
    printf '%s\n' ${MOCK_BOOTED_TRIPLET-/nix/store/k1/Image /nix/store/i1/initrd /nix/store/m1} ;;
*) echo "ssh mock: unexpected command: $*" >&2; exit 1 ;;
esac
EOF

# the flake: subdir nixos/ of a git repo (like the real checkout)
REPO="$T/repo" FL="$T/repo/nixos"
mkdir -p "$FL"
echo '{ }' >"$FL/flake.nix"
git -C "$REPO" init -q -b main
git -C "$REPO" add -A
git -C "$REPO" commit -qm init
# set_auto_update AHEAD: branch auto-update = HEAD (+ one lock commit if AHEAD=1)
set_auto_update() {
    local c
    c="$(git -C "$REPO" rev-parse HEAD)"
    [[ "$1" == 1 ]] && c="$(git -C "$REPO" commit-tree -p HEAD -m "auto-update: lock" 'HEAD^{tree}')"
    git -C "$REPO" branch -f auto-update "$c"
}

dep() { RPI_NIXOS_REBUILD="$BIN/nr-mock" rd deploy --flake "$FL" "$@"; }
no_poison() { expect_eq "$1: d8 host nixos-rebuild never used" 0 "$(log_count POISON)"; }

reset_log
run_cmd d1 -- dep
expect_exit "d1 deploy succeeds" 0
expect_eq "d1 default action switch, pinned argv" 1 \
    "$(log_count "^nr-mock switch --no-reexec --flake $FL#rpi --target-host root@neptun\$")"
expect_true "d1 guards before nixos-rebuild" test "$(first_line ' --dry-run ')" -lt "$(first_line '^nr-mock ')"
# nixos-rebuild's inner `nix build` of the flake must accept its nixConfig
# (nvmd cachix) without an interactive prompt
expect_grep "d1 nixos-rebuild accepts the flake config" "^NIX_CONFIG=.*accept-flake-config = true" "$MOCK_LOG"
no_poison d1

for action in boot test; do
    reset_log
    run_cmd d2 -- dep "$action" --attr neptun
    expect_exit "d2 deploy $action succeeds" 0
    expect_eq "d2 $action passed through" 1 \
        "$(log_count "^nr-mock $action --no-reexec --flake $FL#neptun --target-host root@neptun\$")"
    no_poison "d2 $action"
done

reset_log
run_cmd d3 -- dep dry-activate
expect_exit "d3 dry-activate -> exit 2" 2
expect_eq "d3 no nixos-rebuild" 0 "$(log_count '^nr-mock ')"

reset_log
run_cmd d4 -- dep
expect_grep "d4 NIX_SSHOPTS starts with -p 2222" "^NIX_SSHOPTS=-p 2222( |$)" "$MOCK_LOG"
reset_log
RPI_SSH_OPTS="-F cfg" run_cmd d4 -- dep --port 22 --target root@h
expect_grep "d4 --port and RPI_SSH_OPTS reach NIX_SSHOPTS" "^NIX_SSHOPTS=-p 22 -F cfg$" "$MOCK_LOG"
expect_grep "d4 --target honoured" "^nr-mock switch .*--target-host root@h$" "$MOCK_LOG"
expect_grep "d4 status uses --port/--target" "^ssh -p 22 -F cfg root@h " "$MOCK_LOG"
no_poison d4

for fail in "MOCK_CACHED=" "MOCK_DRY=$KER" "MOCK_DRY_RC=1" "MOCK_EVAL_RC=1"; do
    reset_log
    run_cmd d5 -- env "$fail" RPI_NIXOS_REBUILD="$BIN/nr-mock" bash "$RPI_DEPLOY_SRC" deploy --flake "$FL"
    expect_true "d5 guard failure ($fail) -> non-zero" test "$RC" -ne 0
    expect_eq "d5 guard failure ($fail) -> Pi untouched (no nixos-rebuild, no ssh)" 0 "$(log_count '^(nr-mock|ssh) ')"
    no_poison "d5 $fail"
done
reset_log
MOCK_DRY="$HYB" run_cmd d5 -- dep --max-builds 100
expect_exit "d5 --max-builds honoured -> RL_E_TOO_MANY" 12

reset_log
set_auto_update 1
run_cmd d6 -- dep
expect_exit "d6 auto-update ahead -> RL_E_DOWNGRADE" 15
expect_grepf "d6 says would downgrade" "would downgrade" "$ERR"
expect_eq "d6 no nixos-rebuild" 0 "$(log_count '^nr-mock ')"
expect_eq "d6 checked before the guards" 0 "$(log_count '^nix ')"
no_poison d6

reset_log
run_cmd d7 -- dep --force
expect_exit "d7 --force deploys anyway" 0
expect_eq "d7 --force -> nixos-rebuild ran" 1 "$(log_count '^nr-mock switch ')"
expect_grepf "d7 still warns" "auto-update" "$ERR"
no_poison d7

reset_log
set_auto_update 0
run_cmd d11 -- dep
expect_exit "d11 auto-update merged into HEAD -> deploys" 0

reset_log
NOGIT="$T/nogit"
mkdir -p "$NOGIT"
RPI_NIXOS_REBUILD="$BIN/nr-mock" run_cmd d12 -- rd deploy --flake "$NOGIT"
expect_exit "d12 flake outside git -> no downgrade check, deploys" 0

reset_log
RPI_FLAKE="$FL" run_cmd d9 -- rd deploy
expect_exit "d9 deploy with the flake's pinned tool succeeds" 0
expect_grep "d9 runs the flake's nixos-rebuild" \
    "^nix run --accept-flake-config $FL#nixos-rebuild -- switch --no-reexec --flake $FL#rpi --target-host root@neptun$" "$MOCK_LOG"
no_poison d9

reset_log
MOCK_NR_RC=1 run_cmd d10 -- dep
expect_exit "d10 nixos-rebuild failure -> RL_E_DEPLOY" 14
expect_eq "d10 no status after a failed deploy" 0 "$(log_count '^ssh ')"

reset_log
run_cmd d13 -- dep
expect_grep "d13 switch prints the status" "^reboot pending: (yes|no)$" "$OUT"
expect_true "d13 status after the switch" test "$(first_line '^nr-mock ')" -lt "$(first_line '^ssh ')"
reset_log
run_cmd d13 -- dep boot
expect_eq "d13 boot: no status query" 0 "$(log_count '^ssh ')"
reset_log
MOCK_SSH_FAIL=1 run_cmd d13 -- dep
expect_exit "d13 status failing after a good switch -> still 0" 0

# =============================================================================
# T5.8 status
# =============================================================================
reset_log
MOCK_CUR=/nix/store/c-sys MOCK_BOOTED=/nix/store/b-sys run_cmd s1 -- rd status
expect_exit "s1 status succeeds" 0
expect_grep "s1 current line" "^current: /nix/store/c-sys$" "$OUT"
expect_grep "s1 booted line" "^booted: /nix/store/b-sys$" "$OUT"
expect_grep "s1 default target and port" "^ssh -p 2222 root@neptun " "$MOCK_LOG"

run_cmd s2 -- rd status
expect_grep "s2 equal triplets -> reboot pending: no" "^reboot pending: no$" "$OUT"

for diff in "/nix/store/k2/Image /nix/store/i1/initrd /nix/store/m1" \
    "/nix/store/k1/Image /nix/store/i2/initrd /nix/store/m1" \
    "/nix/store/k1/Image /nix/store/i1/initrd /nix/store/m2"; do
    MOCK_CUR_TRIPLET="$diff" run_cmd s3 -- rd status
    expect_grep "s3 current ($diff) != booted -> reboot pending: yes" "^reboot pending: yes$" "$OUT"
done

reset_log
RPI_SSH_OPTS="-F cfg" run_cmd s3 -- rd status --target pi@x --port 22
expect_grep "s3 --target/--port/RPI_SSH_OPTS honoured" "^ssh -p 22 -F cfg pi@x " "$MOCK_LOG"

MOCK_SSH_FAIL=1 run_cmd s4 -- rd status
expect_true "s4 ssh failure -> non-zero" test "$RC" -ne 0
expect_grepf "s4 cannot reach root@neptun" "cannot reach root@neptun" "$ERR"
expect_not_grep "s4 no half status" "reboot pending" "$OUT"

summary
