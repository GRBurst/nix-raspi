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
run_cmd g9 -- env MOCK_CACHED="$K_DEF" MOCK_DRY="$HYB" bash -c 'source "$RPI_LIB"; rl_guard toplevel 500'
expect_exit "g9 modules missing from the cache -> RL_E_CACHE" 10
run_cmd g9 -- env MOCK_CACHED="" MOCK_NETERR=1 MOCK_DRY="$HYB" bash -c 'source "$RPI_LIB"; rl_guard toplevel 500'
expect_exit "g9 path-info network error counts as a miss -> RL_E_CACHE" 10

reset_log
run_cmd g10 -- env MOCK_DRY="$HYB" bash -c 'source "$RPI_LIB"; rl_guard toplevel 500'
expect_exit "g10 cached kernel + hybrid dry run -> 0" 0
expect_grep "g10 dry run of the toplevel" "^nix build .*--dry-run.* /flk#nixosConfigurations\.rpi\.config\.system\.build\.toplevel( |$)" "$MOCK_LOG"
expect_true "g10 order: path-info before the dry run" \
    test "$(first_line ' path-info ')" -lt "$(first_line ' --dry-run ')"

reset_log
run_cmd g10 -- env MOCK_DRY="$KER" bash -c 'source "$RPI_LIB"; rl_guard sdImage 500'
expect_exit "g10 kernel build in the dry run -> RL_E_FORBIDDEN" 11
expect_grep "g10 sdImage dry run" "^nix build .*--dry-run.*\.config\.system\.build\.sdImage( |$)" "$MOCK_LOG"

reset_log
run_cmd g11 -- env MOCK_CACHED="" MOCK_DRY="$HYB" bash -c 'source "$RPI_LIB"; rl_guard toplevel 500'
expect_eq "g11 cache miss -> no dry run" 0 "$(log_count ' --dry-run ')"
expect_grepf "g11 names the missing path" "$K_DEF" "$ERR"

reset_log
run_cmd g12 -- env MOCK_DRY_RC=1 bash -c 'source "$RPI_LIB"; rl_guard toplevel 500'
expect_exit "g12 dry-run eval error -> RL_E_BUILD" 13
expect_grepf "g12 shows nix's error" "attribute 'rpi' missing" "$ERR"

reset_log
run_cmd g12 -- env MOCK_EVAL_RC=1 bash -c 'source "$RPI_LIB"; rl_guard toplevel 500'
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

run_cmd r5 -- env RL_SSH_PORT=22 RPI_SSH_OPTS="-F x" bash -c 'source "$RPI_LIB"; rl_sshopts'
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
run_cmd r7 -- env RPI_SSH_OPTS="-F x -o A=b" bash -c 'source "$RPI_LIB"; rl_ssh true'
expect_eq "r7 rl_ssh argv" "ssh -p 2222 -F x -o A=b root@neptun true" "$(cat "$MOCK_LOG")"

summary
