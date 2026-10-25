# shellcheck shell=bash
#
# make-sys.sh DIR [PART=TAG...]: a fake NixOS toplevel at DIR for the boot
# fingerprint tests (rpi-lib.sh rl_fp_*). Run with bash; FX_STORE is the fake
# store, FIXTURES the tests' fixture dir. Every boot-critical part is a path
# in FX_STORE named after its TAG (default 1), so two toplevels share a part
# iff they were made with the same tag:
#   kernel initrd modules dtbs  DIR/kernel, initrd, kernel-modules, dtbs
#   params                      DIR/kernel-params (loglevel=TAG)
#   fw cfg uboot                the FAT inputs: firmware package, config.txt,
#                               u-boot -- wired through nvmd's real builder
#                               templates (fixtures/nvmd), substituted like
#                               nvmd's replaceVarsWith
#   ext                         the extlinux builder (writes /boot, not FAT)
#   stc                         bin/switch-to-configuration (stc=none: absent)
# The wrapper is shaped like the real one (makeWrapper --set INSTALL_BOOTLOADER).

set -euo pipefail

dir="$1"
shift
declare -A v=([kernel]=1 [initrd]=1 [modules]=1 [dtbs]=1 [params]=1
    [fw]=1 [cfg]=1 [uboot]=1 [ext]=1 [stc]=1)
for kv in "$@"; do
    [[ -v "v[${kv%%=*}]" ]] || { echo "make-sys: unknown part: $kv" >&2; exit 2; }
    v[${kv%%=*}]="${kv#*=}"
done

s="$FX_STORE"
fw="$s/fx-firmware-${v[fw]}" cfg="$s/fx-config-${v[cfg]}.txt" ub="$s/fx-uboot-${v[uboot]}"
ext="$s/fx-ext-${v[ext]}-extlinux-conf-builder.sh"
fwb="$s/fx-fwb-${v[fw]}-${v[cfg]}-firmware-builder.sh"
ubb="$s/fx-ubb-${v[fw]}-${v[cfg]}-${v[uboot]}-${v[ext]}-uboot-builder.sh"

mkdir -p "$dir/bin" "$s/fx-kernel-${v[kernel]}" "$s/fx-initrd-${v[initrd]}" \
    "$s/fx-modules-${v[modules]}" "$s/fx-dtbs-${v[dtbs]}" "$fw/share/raspberrypi/boot" "$ub"
: >"$s/fx-kernel-${v[kernel]}/Image"
: >"$s/fx-initrd-${v[initrd]}/initrd"
echo "arm_64bit=1 # ${v[cfg]}" >"$cfg"
printf 'cp %s $target\n' "$s/fx-ext-data-${v[ext]}" >"$ext"

sed -e "s|@bash@|$s/fx-bash|; s|@path@|$s/fx-coreutils/bin|" \
    -e "s|@firmware@|$fw|g; s|@configTxt@|$cfg|" \
    "$FIXTURES/nvmd/firmware-builder.sh" >"$fwb"
sed -e "s|@bash@|$s/fx-bash|; s|@path@|$s/fx-coreutils/bin|" \
    -e "s|@firmwareBuilder@|$fwb -r|; s|@uboot@|$ub|; s|@ubootBinName@|u-boot-rpi-arm64.bin|" \
    -e "s|@extlinuxConfBuilder@|$ext -g 20 -t 5 -r|" \
    "$FIXTURES/nvmd/uboot-builder.sh" >"$ubb"

ln -sfn "$s/fx-kernel-${v[kernel]}/Image" "$dir/kernel"
ln -sfn "$s/fx-initrd-${v[initrd]}/initrd" "$dir/initrd"
ln -sfn "$s/fx-modules-${v[modules]}" "$dir/kernel-modules"
ln -sfn "$s/fx-dtbs-${v[dtbs]}" "$dir/dtbs"
printf 'console=serial0,115200n8 root=fstab loglevel=%s' "${v[params]}" >"$dir/kernel-params"

rm -f "$dir/bin/switch-to-configuration"
if [[ "${v[stc]}" != none ]]; then
    cat >"$dir/bin/switch-to-configuration" <<EOF
#! $s/fx-bash/bin/bash -e
export OUT='$dir'
export TOPLEVEL='$dir'
export INSTALL_BOOTLOADER='$ubb -f /boot/firmware -b /boot -c'
export SYSTEMD='$s/fx-systemd'
exec -a "\$0" "$dir/bin/.switch-to-configuration-wrapped"  "\$@"
EOF
fi
