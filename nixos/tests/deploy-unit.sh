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
export RPI_FP_LIB="${RPI_FP_LIB:-$HERE/../rpi-fp.sh}"
FIXTURES="${FIXTURES:-$HERE/fixtures}"

# shellcheck source=tests/harness.sh
source "$HERE/harness.sh"

# The caller's environment must not leak into the tests.
unset RPI_FLAKE RPI_SSH_OPTS RPI_NIXOS_REBUILD RPI_CACHE_URL RPI_ALLOW_NONBLOCK \
    RL_FLAKE RL_ATTR RL_TARGET RL_SSH_PORT RL_SSH_OPTS RL_CACHE_URL RL_STORE_DIR NIX_SSHOPTS

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
run_cmd r1 -- lib rl_needs_reboot $'kernel: /k\nfat: /f' $'kernel: /k\nfat: /f'
expect_exit "r1 equal fingerprints -> no reboot" 1
run_cmd r2 -- lib rl_needs_reboot $'kernel: /k2\nfat: /f' $'kernel: /k\nfat: /f'
expect_exit "r2 kernel differs -> reboot" 0
run_cmd r3 -- lib rl_needs_reboot $'kernel: /k\nfat: /f2' $'kernel: /k\nfat: /f'
expect_exit "r3 FAT input differs -> reboot" 0
run_cmd r4 -- lib rl_fp_changed $'kernel: /k2\ninitrd: /i\nfat: a\nfat: b' $'kernel: /k\ninitrd: /i\nfat: a\nfat: c'
expect_eq "r4 rl_fp_changed names the differing parts once" "kernel, fat" "$(cat "$OUT")"

RL_SSH_PORT=22 RPI_SSH_OPTS="-F x" run_cmd r5 -- lib rl_sshopts
expect_eq "r5 rl_sshopts" "-p 22 -F x" "$(cat "$OUT")"
run_cmd r5 -- lib rl_sshopts
expect_eq "r5 rl_sshopts default port" "-p 2222" "$(cat "$OUT")"

# Boot fingerprints: fake toplevels (tests/make-sys.sh) whose FAT inputs come
# through nvmd's real builder templates; the fake store is $FX_STORE.
export RL_STORE_DIR="$FX_STORE"
fp() { lib rl_fp_local "$T/$1"; }
make_sys "$T/sysA"
make_sys "$T/sysA2"
run_cmd fp1 -- lib rl_fp_local "$T/sysA"
expect_exit "fp1 rl_fp_local succeeds" 0
expect_grep "fp1 kernel" "^kernel: $FX_STORE/fx-kernel-1/Image$" "$OUT"
expect_grep "fp1 initrd" "^initrd: $FX_STORE/fx-initrd-1/initrd$" "$OUT"
expect_grep "fp1 kernel-modules" "^kernel-modules: $FX_STORE/fx-modules-1$" "$OUT"
expect_grep "fp1 dtbs" "^dtbs: $FX_STORE/fx-dtbs-1$" "$OUT"
expect_grep "fp1 kernel-params" "^kernel-params: console=serial0,115200n8 root=fstab loglevel=1$" "$OUT"
expect_grep "fp1 FAT: the firmware package" \
    "^fat: SRC_FIRMWARE_DIR=$FX_STORE/fx-firmware-1/share/raspberrypi/boot$" "$OUT"
expect_grepf "fp1 FAT: config.txt" "fat: copyForced $FX_STORE/fx-config-1.txt \$target/config.txt" "$OUT"
expect_grepf "fp1 FAT: u-boot" "fat: copyForced $FX_STORE/fx-uboot-1/u-boot.bin \$fwtarget/" "$OUT"
expect_grepf "fp1 FAT: the populate command, builder path elided" \
    "fat: <builder> -r -c \$default -d \$fwtarget" "$OUT"
expect_not_grep "fp1 no extlinux (/boot is not FAT, its generations roll back)" "extlinux" "$OUT"
expect_not_grep "fp1 no interpreter" "fx-bash" "$OUT"
expect_not_grep "fp1 no PATH" "fx-coreutils" "$OUT"
expect_not_grep "fp1 no toplevel path" "$T/sysA" "$OUT"
expect_eq "fp2 same parts, another toplevel -> same fingerprint" "$(fp sysA)" "$(fp sysA2)"
for part in kernel initrd modules dtbs params fw cfg uboot; do
    make_sys "$T/sys-$part" "$part=2"
    expect_true "fp3 $part differs -> fingerprint differs" test "$(fp sysA)" != "$(fp "sys-$part")"
done
make_sys "$T/sys-ext" ext=2
expect_eq "fp4 only the extlinux builder differs -> same fingerprint" "$(fp sysA)" "$(fp sys-ext)"
make_sys "$T/sys-nostc" stc=none
make_sys "$T/sys-nostc2" stc=none
run_cmd fp5 -- lib rl_fp_local "$T/sys-nostc"
expect_exit "fp5 unknown bootloader installer -> still a fingerprint" 0
expect_grep "fp5 FAT inputs unknown" "^fat: unknown $T/sys-nostc$" "$OUT"
expect_true "fp5 unknown FAT inputs never compare equal" test "$(fp sys-nostc)" != "$(fp sys-nostc2)"
make_sys "$T/sys-nofwb" fw=gone
rm "$FX_STORE"/fx-fwb-gone-*
expect_grep "fp5 nested builder missing -> FAT inputs unknown" "^fat: unknown $T/sys-nofwb$" <(fp sys-nofwb)
run_cmd fp6 -- lib rl_fp_local "$T/no-such-system"
expect_true "fp6 missing system -> non-zero" test "$RC" -ne 0
expect_eq "fp6 missing system -> no fingerprint" "" "$(cat "$OUT")"

# rl_fp_remote: the same script over ssh (mock: Pi paths under $T/pi, the
# Pi's /nix/store is $FX_STORE).
mock ssh <<'EOF'
case " $* " in
*" bash -s -- "*)
    a=("$@")
    [[ "${a[-1]}" == /nix/store ]] || exit 98
    exec bash -s -- "$MOCK_PI${a[-2]}" "$FX_STORE" ;;
esac
exit 97
EOF
export MOCK_PI="$T/pi"
mkdir -p "$MOCK_PI/run"
ln -sfn "$T/sysA" "$T/pi/run/booted-system"
reset_log
run_cmd fp7 -- lib rl_fp_remote /run/booted-system
expect_exit "fp7 rl_fp_remote succeeds" 0
expect_eq "fp7 remote fingerprint = local one of the same system" "$(fp sysA)" "$(cat "$OUT")"
expect_eq "fp7 one ssh call" 1 "$(log_count '^ssh -p 2222 root@neptun bash -s -- /run/booted-system /nix/store$')"
run_cmd fp8 -- lib rl_fp_remote /run/no-such-system
expect_true "fp8 remote failure -> non-zero" test "$RC" -ne 0

mock ssh <<'EOF'
exit 0
EOF
reset_log
RPI_SSH_OPTS="-F x -o A=b" run_cmd r7 -- lib rl_ssh true
expect_eq "r7 rl_ssh argv" "ssh -p 2222 -F x -o A=b root@neptun true" "$(cat "$MOCK_LOG")"

# x1: rpi-fp.sh is the Pi-safe half of the lib (D1, P12): the fingerprint
# functions and nothing host-only. Sourced alone, in a fresh shell.
run_cmd x1 -- bash -c 'source "$1" && declare -F rl_fp_local rl_needs_reboot rl_fp_changed' _ "$RPI_FP_LIB"
expect_exit "x1 rpi-fp.sh alone defines the fingerprint functions" 0
run_cmd x1 -- bash -c 'source "$1" || exit 2; for f in rl_ssh rl_guard rl_nixos_rebuild rl_fp_remote; do declare -F "$f" && exit 1; done; exit 0' _ "$RPI_FP_LIB"
expect_exit "x1 rpi-fp.sh defines no host functions" 0

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
# Only an SD card (sysfs device/type "SD") counts; eMMC ("MMC") is
# soldered-in storage. RPI_SYSFS points the check at a fixture tree.
reset_log
MMC="$T/dev/mmcblk0"
head -c 65536 /dev/zero >"$MMC"
export RPI_SYSFS="$T/sys"
mmc_type() {
    rm -rf "$RPI_SYSFS"
    [[ -z "$1" ]] && return 0
    mkdir -p "$RPI_SYSFS/block/mmcblk0/device"
    echo "$1" >"$RPI_SYSFS/block/mmcblk0/device/type"
}
mmc_type SD
MOCK_RM=0 run_cmd f11 -- rd flash "$IMG" "$MMC" <<<"mmcblk0"
expect_exit "f11 an SD card in a built-in reader (mmcblk0, RM=0) is accepted" 0
expect_grepf "f11 verified" "verified" "$OUT"
reset_log
MOCK_RM=0 MOCK_ROOTSRC=/dev/mmcblk0p2 MOCK_PKNAME=mmcblk0 run_cmd f11 -- rd flash "$IMG" "$MMC" <<<"mmcblk0"
expect_exit "f11 an mmcblk holding / is still refused" 16
for t in MMC SDIO ""; do
    reset_log
    mmc_type "$t"
    MOCK_RM=0 run_cmd f11 -- rd flash "$IMG" "$MMC" <<<"mmcblk0"
    expect_exit "f11 mmcblk0 with device/type '${t:-missing}' (eMMC/other, RM=0) is refused" 16
    expect_grepf "f11 ($t) says not removable" "not removable" "$ERR"
    expect_eq "f11 ($t) nothing written" 0 "$(log_count '^sudo ')"
done
unset RPI_SYSFS

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
# ssh: the Pi as the directory tree $MOCK_PI (run/current-system,
# run/booted-system, nix/var/nix/profiles/system: links to fake toplevels;
# its /nix/store is $FX_STORE): readlink -e of those paths, the fingerprint
# script (bash -s), sync. MOCK_SSH_FAIL: unreachable.
mock ssh <<'EOF'
if [[ -n "${MOCK_SSH_FAIL:-}" ]]; then
    echo "ssh: connect to host neptun port 2222: Connection refused" >&2
    exit 255
fi
a=("$@")
case " $* " in
*" readlink -e /run/current-system /run/booted-system /nix/var/nix/profiles/system ")
    for p in "${a[@]: -3}"; do readlink -e "$MOCK_PI$p" || exit 1; done ;;
*" bash -s -- "*" /nix/store ")
    exec bash -s -- "$MOCK_PI${a[-2]}" "$FX_STORE" ;;
*" sync ") exit "${MOCK_SYNC_RC:-0}" ;;
*"rpi-pull.service"*)
    # the pull-state query: MOCK_PULL_OUT is its output (default: no rpi-pull unit)
    [[ -z "${MOCK_PULL_FAIL:-}" ]] || { echo "ssh: query failed" >&2; exit 1; }
    printf '%s\n' "${MOCK_PULL_OUT-LoadState=not-found}" ;;
*) echo "ssh mock: unexpected command: $*" >&2; exit 1 ;;
esac
EOF
# pi_state CURRENT BOOTED DEFAULT: the Pi's systems (fake toplevels in $T)
pi_state() {
    mkdir -p "$MOCK_PI/run" "$MOCK_PI/nix/var/nix/profiles"
    ln -sfn "$T/$1" "$MOCK_PI/run/current-system"
    ln -sfn "$T/$2" "$MOCK_PI/run/booted-system"
    ln -sfn "$T/$3" "$MOCK_PI/nix/var/nix/profiles/system"
}
# default: switched to a userspace-only change (same boot parts as booted)
pi_state sysA2 sysA sysA2

# the flake: subdir nixos/ of a git repo (like the real checkout)
REPO="$T/repo" FL="$T/repo/nixos"
mkdir -p "$FL"
echo '{ }' >"$FL/flake.nix"
# lock_json NIXPKGS RPI [OTHER]: a flake.lock whose root inputs nixpkgs
# (node nixpkgs_2, like the real lock's nixpkgs_4) and nixos-raspberrypi
# have these locked.lastModified; OTHER is a non-root node (default 1)
lock_json() {
    cat <<EOF
{ "nodes": {
    "nixpkgs_2": { "locked": { "lastModified": $1, "type": "github" } },
    "nixos-raspberrypi": { "locked": { "lastModified": $2, "type": "github" } },
    "nixpkgs": { "locked": { "lastModified": ${3:-1}, "type": "github" } },
    "root": { "inputs": { "nixpkgs": "nixpkgs_2", "nixos-raspberrypi": "nixos-raspberrypi" } } },
  "root": "root", "version": 7 }
EOF
}
write_lock() { local f="$1"; shift; lock_json "$@" >"$f"; }
# commit_lock NIXPKGS RPI: commit that lock on main (the checkout)
commit_lock() {
    write_lock "$FL/flake.lock" "$@"
    git -C "$REPO" add -A
    git -C "$REPO" commit -q --allow-empty -m "lock $*"
}
write_lock "$FL/flake.lock" 100 200
git -C "$REPO" init -q -b main
git -C "$REPO" add -A
git -C "$REPO" commit -qm init
git -C "$REPO" remote add origin "$T/origin.git" # never fetched: the URL need not exist
# set_ref_lock REF TEXT: REF = main + one commit whose nixos/flake.lock is
# TEXT ('' = the commit deletes it); main is untouched
set_ref_lock() {
    local ref="$1" idx="$T/om-index" blob tree c; shift
    rm -f "$idx"
    GIT_INDEX_FILE="$idx" git -C "$REPO" read-tree main
    if [[ -n "$1" ]]; then
        blob="$(printf '%s\n' "$1" | git -C "$REPO" hash-object -w --stdin)"
        GIT_INDEX_FILE="$idx" git -C "$REPO" update-index --add --cacheinfo "100644,$blob,nixos/flake.lock"
    else
        GIT_INDEX_FILE="$idx" git -C "$REPO" update-index --force-remove nixos/flake.lock
    fi
    tree="$(GIT_INDEX_FILE="$idx" git -C "$REPO" write-tree)"
    c="$(git -C "$REPO" commit-tree -p main -m "ci: lock" "$tree")"
    git -C "$REPO" update-ref "$ref" "$c"
}
# set_origin_main NIXPKGS RPI [OTHER]: CI committed this lock to origin/main
set_origin_main_raw() { set_ref_lock refs/remotes/origin/main "$1"; }
set_origin_main() { set_origin_main_raw "$(lock_json "$@")"; }

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
set_origin_main 150 200
run_cmd d6 -- dep
expect_exit "d6 origin/main locks a newer nixpkgs -> RL_E_DOWNGRADE" 15
expect_grepf "d6 says would downgrade" "would downgrade" "$ERR"
expect_grepf "d6 names the newer input" "nixpkgs" "$ERR"
expect_grepf "d6 tells the user to git pull" "git pull" "$ERR"
expect_eq "d6 no nixos-rebuild" 0 "$(log_count '^nr-mock ')"
expect_eq "d6 checked before the guards" 0 "$(log_count '^nix ')"
no_poison d6

reset_log
set_origin_main 100 300
run_cmd d6 -- dep
expect_exit "d6 origin/main locks a newer nixos-raspberrypi -> RL_E_DOWNGRADE" 15
expect_grepf "d6 names nixos-raspberrypi" "nixos-raspberrypi" "$ERR"
expect_eq "d6 (rpi) no nixos-rebuild" 0 "$(log_count '^nr-mock ')"

reset_log
run_cmd d7 -- dep --force
expect_exit "d7 --force deploys anyway" 0
expect_eq "d7 --force -> nixos-rebuild ran" 1 "$(log_count '^nr-mock switch ')"
expect_grepf "d7 still warns" "origin/main" "$ERR"
no_poison d7

reset_log
git -C "$REPO" update-ref refs/remotes/origin/main main
run_cmd d11 -- dep
expect_exit "d11 origin/main merged into HEAD -> deploys" 0

# S4: squash/cherry-pick: origin/main keeps a commit HEAD lacks, but the
# checkout already locks the same revisions -> no refusal
reset_log
set_origin_main 150 300
commit_lock 150 300
run_cmd d11 -- dep
expect_exit "d11 squash-merged (same lock, commit not in HEAD) -> deploys" 0
expect_eq "d11 squash -> nixos-rebuild ran" 1 "$(log_count '^nr-mock switch ')"
expect_not_grep "d11 squash -> no downgrade warning" "origin/main" "$ERR"

# the user ran `nix flake update` on main: the checkout is newer
reset_log
set_origin_main 150 300
commit_lock 160 400
run_cmd d11 -- dep
expect_exit "d11 checkout lock newer than origin/main's -> deploys" 0

# an uncommitted lock update counts (the working tree is what is deployed)
reset_log
commit_lock 100 200
set_origin_main 150 300
write_lock "$FL/flake.lock" 150 300
run_cmd d11 -- dep
expect_exit "d11 uncommitted newer lock in the working tree -> deploys" 0
git -C "$REPO" checkout -q -- .

# only the root inputs nixpkgs and nixos-raspberrypi count (the real lock
# maps nixpkgs to a node like nixpkgs_4; other nodes may be newer)
reset_log
set_origin_main 100 200 999
run_cmd d11 -- dep
expect_exit "d11 only other lock nodes newer -> deploys" 0

# fail closed: an unreadable lock cannot be compared
reset_log
set_origin_main_raw 'not json'
run_cmd d16 -- dep
expect_exit "d16 origin/main lock unparsable -> RL_E_DOWNGRADE" 15
expect_grepf "d16 says it cannot compare" "cannot compare" "$ERR"
expect_eq "d16 no nixos-rebuild" 0 "$(log_count '^nr-mock ')"
reset_log
run_cmd d16 -- dep --force
expect_exit "d16 --force deploys anyway" 0

reset_log
set_origin_main 150 300
rm "$FL/flake.lock"
run_cmd d16 -- dep
expect_exit "d16 no flake.lock in the checkout -> RL_E_DOWNGRADE" 15
git -C "$REPO" checkout -q -- .

# origin/main has no lock for this flake (another flake dir): nothing to compare
reset_log
set_origin_main_raw ''
run_cmd d17 -- dep
expect_exit "d17 origin/main without this flake's lock -> deploys" 0
git -C "$REPO" update-ref refs/remotes/origin/main main

# d18 no origin remote (a leftover ref is not consulted): deploys
reset_log
git -C "$REPO" remote remove origin
set_origin_main 150 300
run_cmd d18 -- dep
expect_exit "d18 no origin remote -> no downgrade check, deploys" 0
expect_eq "d18 nixos-rebuild ran" 1 "$(log_count '^nr-mock switch ')"

# d19 origin remote without refs/remotes/origin/main: nothing to compare
git -C "$REPO" remote add origin "$T/origin.git"
git -C "$REPO" update-ref -d refs/remotes/origin/main
reset_log
run_cmd d19 -- dep
expect_exit "d19 origin without origin/main -> deploys" 0

# d20 a local branch auto-update (newer lock) is no longer consulted
git -C "$REPO" update-ref refs/remotes/origin/main main
set_ref_lock refs/heads/auto-update "$(lock_json 150 300)"
reset_log
run_cmd d20 -- dep
expect_exit "d20 local branch auto-update ignored -> deploys" 0
git -C "$REPO" update-ref -d refs/heads/auto-update


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
expect_eq "d10 no status after a failed deploy" 0 "$(log_count '^ssh .* (readlink|bash) ')"
expect_eq "d10 a failed deploy still syncs (the bootloader may be written)" 1 "$(log_count '^ssh .* sync$')"

reset_log
run_cmd d13 -- dep
expect_grep "d13 switch prints the status" "^reboot pending: (yes|no)" "$OUT"
expect_true "d13 status after the switch" test "$(first_line '^nr-mock ')" -lt "$(first_line '^ssh .* readlink ')"
for action in boot test; do
    reset_log
    run_cmd d13 -- dep "$action"
    expect_eq "d13 $action: no status query" 0 "$(log_count '^ssh .* (readlink|bash) ')"
done
reset_log
MOCK_SSH_FAIL=1 run_cmd d13 -- dep
expect_exit "d13 status failing after a good switch -> still 0" 0

# d14 the Pi syncs after every deploy (S2: the vfat NIXOS_BOOT is rewritten
# and switch-to-configuration only syncs the store's filesystem)
for action in switch boot test; do
    reset_log
    run_cmd d14 -- dep "$action"
    expect_eq "d14 $action: one sync on the Pi" 1 "$(log_count '^ssh -p 2222 root@neptun sync$')"
    expect_true "d14 $action: sync after nixos-rebuild, before the status" \
        test "$(first_line '^nr-mock ')" -lt "$(first_line ' sync$')" -a \
        "$(first_line ' sync$')" -lt "$(first_line '^ssh .* readlink ')"
done
reset_log
MOCK_SYNC_RC=1 run_cmd d14 -- dep boot
expect_exit "d14 sync failure after a good deploy -> still 0" 0
expect_grepf "d14 sync failure is reported" "sync" "$ERR"

# =============================================================================
# T5.8 status
# =============================================================================
reset_log
pi_state sysA2 sysA sysA2
run_cmd s1 -- rd status
expect_exit "s1 status succeeds" 0
expect_grep "s1 current line" "^current: $T/sysA2$" "$OUT"
expect_grep "s1 booted line" "^booted: $T/sysA$" "$OUT"
expect_grep "s1 boot default line" "^default: $T/sysA2$" "$OUT"
expect_grep "s1 default target and port" "^ssh -p 2222 root@neptun " "$MOCK_LOG"
expect_grep "s2 switched, same boot parts as booted -> reboot pending: no" "^reboot pending: no$" "$OUT"

# s3 a reboot would change the system: the boot default is not running
# (after `deploy boot`, even without boot changes), or a boot part of the
# default differs from the booted system's (switch to a new kernel, ...).
pi_state sysA sysA sysA2
run_cmd s3 -- rd status
expect_grep "s3 after deploy boot (userspace only) -> reboot pending: yes" \
    "^reboot pending: yes \(the boot default is not the running system\)$" "$OUT"
for part in kernel initrd modules dtbs params fw cfg uboot; do
    pi_state "sys-$part" sysA "sys-$part"
    run_cmd s3 -- rd status
    expect_grep "s3 switched to a new $part -> reboot pending: yes" \
        "^reboot pending: yes \(changed since boot: [a-z-]+\)$" "$OUT"
    pi_state sysA sysA "sys-$part"
    run_cmd s3 -- rd status
    expect_grep "s3 deploy boot of a new $part -> reboot pending: yes, both reasons" \
        "^reboot pending: yes \(the boot default is not the running system; changed since boot: [a-z-]+\)$" "$OUT"
done
pi_state sys-fw sysA sys-fw
run_cmd s3 -- rd status
expect_grep "s3 names the changed part" "^reboot pending: yes \(changed since boot: fat\)$" "$OUT"
pi_state sys-ext sysA sys-ext
run_cmd s3 -- rd status
expect_grep "s3 extlinux builder only -> reboot pending: no" "^reboot pending: no$" "$OUT"
pi_state sysA2 sysA sysA2

reset_log
RPI_SSH_OPTS="-F cfg" run_cmd s3 -- rd status --target pi@x --port 22
expect_grep "s3 --target/--port/RPI_SSH_OPTS honoured" "^ssh -p 22 -F cfg pi@x " "$MOCK_LOG"

MOCK_SSH_FAIL=1 run_cmd s4 -- rd status
expect_true "s4 ssh failure -> non-zero" test "$RC" -ne 0
expect_grepf "s4 cannot reach root@neptun" "cannot reach root@neptun" "$ERR"
expect_not_grep "s4 no half status" "reboot pending" "$OUT"


# =============================================================================
# status: the Pi's pull state (S5/S6: applied seq + age, last run)
# =============================================================================
pi_state sysA2 sysA sysA2
P7=/nix/store/pppppppppppppppppppppppppppppppp-nixos-system-neptun-x
export MOCK_PULL_OUT="LoadState=loaded
seq=7
store-path=$P7
age=172800
last-run=time=2026-10-25T05:12:03+01:00 exit=0 result=success"
reset_log
run_cmd s5 -- rd status
expect_exit "s5 status succeeds" 0
expect_grepf "s5 status shows the applied pull seq" "pull applied: seq 7 $P7 (2d ago)" "$OUT"
expect_grepf "s5 status shows the last run" "pull last run: success (exit 0) at 2026-10-25T05:12:03+01:00" "$OUT"
expect_grep "s5 pull lines come after reboot pending" "reboot pending" "$OUT"
expect_true "s5 pull state is the last section" test "$(grep -n '^reboot pending:' "$OUT" | cut -d: -f1)" -lt "$(grep -n '^pull applied:' "$OUT" | cut -d: -f1)"
expect_grep "s5 query goes to the target" "^ssh -p 2222 root@neptun .*rpi-pull" "$MOCK_LOG"

# a failed run is shown with its result and exit code
export MOCK_PULL_OUT="LoadState=loaded
seq=7
store-path=$P7
age=7200
last-run=time=2026-10-26T05:00:00+01:00 exit=32 result=untrusted"
run_cmd s5 -- rd status
expect_grepf "s5 failed last run shows result and exit" "pull last run: untrusted (exit 32) at 2026-10-26T05:00:00+01:00" "$OUT"
expect_grepf "s5 age in hours" "(2h ago)" "$OUT"

# s6 loaded, nothing applied, never ran
export MOCK_PULL_OUT="LoadState=loaded"
run_cmd s6 -- rd status
expect_grepf "s6 nothing applied" "pull applied: none" "$OUT"
expect_grepf "s6 never ran" "pull last run: never" "$OUT"

# s7 no rpi-pull unit: exactly one pull line
export MOCK_PULL_OUT="LoadState=not-found"
run_cmd s7 -- rd status
expect_eq "s7 one pull line" 1 "$(grep -c '^pull' "$OUT")"
expect_grepf "s7 disabled" "pull: disabled" "$OUT"

# s8 the pull query fails: status still succeeds and says so
unset MOCK_PULL_OUT
MOCK_PULL_FAIL=1 run_cmd s8 -- rd status
expect_exit "s8 pull query failure -> status still 0" 0
expect_grepf "s8 pull unknown" "pull: unknown (cannot query rpi-pull on root@neptun)" "$OUT"
expect_grep "s8 booted/reboot lines still printed" "^reboot pending: " "$OUT"
summary
