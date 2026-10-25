# SD-card write reduction for the Pi (spec §3.2), on by default. Every
# setting is justified by .scratch/s6/REPORT.md (measured/verified against
# the pinned nixpkgs + nvmd). Checked by checks.x86_64-linux.eval-sd-wear.
#
# Deliberately NOT set (s6 §5): nix.settings.fsync-metadata = false (store
# corruption on power loss), auto-optimise-store / nix.optimise.automatic
# (extra metadata writes), the `discard` mount option (fstrim runs monthly
# instead), f2fs/btrfs (U-Boot cannot read them from /boot).
{ config, lib, ... }:
let
  cfg = config.rpi.sdWear;
in
{
  options.rpi.sdWear.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Reduce writes to the SD card and the size of the closure: no
      redistributable firmware, relaxed ext4 write-back, volatile journal and
      /tmp, no coredumps, monthly fstrim, zram swap tuning.
    '';
  };

  config = lib.mkIf cfg.enable {
    # Wired LAN needs no firmware. all-hardware.nix (pulled in by nixpkgs'
    # sd-image.nix through hardware.enableAllHardware, kept for parity with
    # the tested image) sets both, hence mkForce: -770 MiB of linux-firmware.
    hardware.enableRedistributableFirmware = lib.mkForce false;
    hardware.firmware = lib.mkForce [ ];

    # Fewer metadata writes: no atime updates, lazy timestamp write-back,
    # 60 s journal commit (default 5 s). Lists merge with a host's options.
    fileSystems."/".options = [ "noatime" "lazytime" "commit=60" ];

    # Nix builds use /nix/var/nix/builds, not /tmp, so 256M is plenty.
    boot.tmp = {
      useTmpfs = true;
      tmpfsSize = "256M";
    };

    # Periodic trim instead of the `discard` mount option.
    services.fstrim = {
      enable = true;
      interval = "monthly";
    };

    # journald in RAM, small and quiet (there is no `journald.settings` in
    # 26.05, hence extraConfig). Remote upload stays off.
    services.journald = {
      storage = "volatile";
      extraConfig = ''
        Compress=yes
        RuntimeMaxUse=16M
        MaxLevelStore=info
      '';
      upload.enable = false;
    };
    systemd.coredump.enable = false;
    # Do not keep .drv files of built paths around (never built on the Pi).
    nix.settings.keep-derivations = false;
    # Deploys copy closures and switch right away; fsync every store path
    # before it is registered so a power cut cannot leave a registered but
    # empty/partial path (review S3). Exists in the pinned nix 2.34
    # (`nix config show fsync-store-paths`); nix.checkConfig validates
    # nix.conf when the system is built.
    nix.settings.fsync-store-paths = true;

    # zram swap itself (50 %) is enabled by modules/base.nix; with
    # compressed RAM as swap, prefer it over dropping page cache and do not
    # read ahead (zram has no seek cost).
    boot.kernel.sysctl = {
      "vm.swappiness" = 100;
      "vm.page-cluster" = 0;
    };
  };
}
