# Optional USB data disk (spec §3.2): `rpi.storage.external.*`, disabled by
# default. The SD card stays the boot device: `/`, `/boot` (kernels, initrd and
# extlinux live on the SD root) and `/boot/firmware` are not touched. Checked
# by checks.x86_64-linux.eval-external-storage.
{ config, lib, ... }:
let
  cfg = config.rpi.storage.external;
in
{
  options.rpi.storage.external = {
    enable = lib.mkEnableOption "external USB disk for /nix, /var, /home (SD stays boot device)";
    label = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_-]{1,16}";
      default = "PI_DATA";
      description = "Filesystem label of the data disk (mounted from /dev/disk/by-label).";
    };
    fsType = lib.mkOption {
      type = lib.types.str;
      default = "ext4";
      description = "Filesystem type of the data disk.";
    };
    bind = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "/nix" "/var" "/home" ];
      description = "Paths bind-mounted from /external<path>.";
    };
    swapSize = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = "MiB; swapfile /external/swapfile";
    };
  };

  config = lib.mkIf cfg.enable {
    # Moving any of these off the SD card would break the boot chain
    # (U-Boot reads extlinux and kernels from the SD root, the GPU reads
    # /boot/firmware) or loop /external onto itself.
    assertions = [
      {
        assertion = lib.all
          (b: lib.hasPrefix "/" b
            && !(lib.elem b [ "/" "/boot" "/boot/firmware" "/external" ])
            && !(lib.hasPrefix "/boot/" b)
            && !(lib.hasPrefix "/external/" b))
          cfg.bind;
        message = "rpi.storage.external.bind: absolute paths outside /, /boot, /boot/firmware, /external";
      }
    ];

    fileSystems = {
      # Never `nofail`: /nix and /var are needed to boot, a missing disk must
      # stop the boot (emergency shell) instead of booting a half system.
      "/external" = {
        device = "/dev/disk/by-label/${cfg.label}";
        fsType = cfg.fsType;
        neededForBoot = true;
      };
    } // lib.genAttrs cfg.bind (b: {
      device = "/external${b}";
      fsType = "none";
      options = [ "bind" ];
      depends = [ "/external" ];
    });

    # The data disk is needed for boot: its USB drivers must be in the initrd
    # on their own, not only through hardware.enableAllHardware.
    boot.initrd.availableKernelModules = [ "usb_storage" "uas" ];

    swapDevices = lib.optional (cfg.swapSize != null) {
      device = "/external/swapfile";
      size = cfg.swapSize;
    };
  };
}
