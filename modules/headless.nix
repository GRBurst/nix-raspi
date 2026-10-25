# Headless profile for the Pi (spec §3.2, s6 §4): the board has no display,
# camera or audio attached and wifi/bluetooth are unused (wired LAN only).
# Only config.txt is touched; boot-critical lines (arm_64bit, enable_uart,
# kernel=u-boot…) are left to nvmd's defaults. Checked by
# checks.x86_64-linux.eval-headless.
#
# Consequences (accepted): no HDMI console; disable-bt moves the PL011 UART
# to the GPIO header, which is then the serial console. Only manual AC6
# (real hardware) verifies this; qemu uses direct kernel boot.
#
# The `cma=32M` kernel parameter (needed only for the KMS console) is
# dropped in configuration.nix, not here: boot.kernelParams must not be
# mkForce'd, that would also drop root=fstab, loglevel and lsm.
{ config, lib, ... }:
let
  cfg = config.rpi.headless;
in
{
  options.rpi.headless.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Headless config.txt: 16 MiB GPU memory, wifi/bluetooth overlays
      disabled, no KMS graphics driver, no audio, no camera/display
      auto-detection.
    '';
  };

  config = lib.mkIf cfg.enable {
    # nvmd's defaults (configtxt.nix) are mkDefault, mkForce makes the
    # switch-off explicit.
    hardware.raspberry-pi.config.all = {
      options = {
        gpu_mem = {
          enable = true;
          value = 16; # selects the cut-down start_cd.elf
        };
        camera_auto_detect.enable = lib.mkForce false;
        display_auto_detect.enable = lib.mkForce false;
      };
      base-dt-params.audio.enable = lib.mkForce false;
      dt-overlays = {
        vc4-kms-v3d.enable = lib.mkForce false;
        disable-bt.enable = true;
        disable-wifi.enable = true;
      };
    };
  };
}
