# rpi.bluetooth (spec §4; plan D9): Bluetooth, off by default.
#   off: config.txt keeps the disable-bt overlay. On the Pi 3 that moves the
#        PL011 UART from the Bluetooth chip to the GPIO header, which is
#        then the serial console.
#   on:  the overlay is gone, hardware.bluetooth (bluez) is on, dtparam
#        krnbt=on lets the kernel probe the UART-attached chip (as nvmd's
#        bluetooth module does for the Pi 4/5), and the BCM43430 firmware
#        (nvmd's raspberrypiWirelessFirmware) is listed at priority 49 so it
#        beats rpi.sdWear's `hardware.firmware = mkForce [ ]`.
# Real hardware only (qemu has no radio): see the README's checklist.
# Checked by checks.x86_64-linux.eval-bluetooth.
{ config, lib, pkgs, nixos-raspberrypi, ... }:
let
  cfg = config.rpi.bluetooth;
  firmware = nixos-raspberrypi.packages.${pkgs.stdenv.hostPlatform.system}.raspberrypiWirelessFirmware;
in
{
  options.rpi.bluetooth.enable = lib.mkEnableOption "Bluetooth (bluez, the on-board UART chip)";

  config = lib.mkMerge [
    (lib.mkIf (!cfg.enable) {
      hardware.raspberry-pi.config.all.dt-overlays.disable-bt.enable = true;
    })

    (lib.mkIf cfg.enable {
      hardware.bluetooth.enable = true;
      hardware.raspberry-pi.config.all.base-dt-params.krnbt = {
        enable = true;
        value = "on";
      };
      hardware.firmware = lib.mkOverride 49 [ firmware ];
    })
  ];
}
