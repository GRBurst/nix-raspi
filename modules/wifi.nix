# rpi.wifi (spec §4; plan D9): Wi-Fi, off by default.
#   off: config.txt keeps the disable-wifi overlay (the chip stays off).
#   on:  the overlay is gone, wpa_supplicant joins rpi.wifi.networks and
#        networkd runs DHCP on the wireless link (NixOS's default wireless
#        network, networking.useDHCP). PSKs never enter the store (it goes
#        to a public cache and is world-readable on the Pi): each network's
#        pskRaw is `ext:<VAR>`, VAR=<psk> lines live in rpi.wifi.secretsFile
#        (root 0600), written by `rpi-deploy secrets` / `flash --wifi-env`.
# The Pi 3 Wi-Fi/Bluetooth firmware (nvmd's raspberrypiWirelessFirmware,
# cached with nvmd's kernel) is listed at priority 49 so it beats
# rpi.sdWear's `hardware.firmware = mkForce [ ]` (50).
# Checked by checks.x86_64-linux.eval-wifi.
{ config, lib, pkgs, nixos-raspberrypi, ... }:
let
  cfg = config.rpi.wifi;
  firmware = nixos-raspberrypi.packages.${pkgs.stdenv.hostPlatform.system}.raspberrypiWirelessFirmware;
in
{
  options.rpi.wifi = {
    enable = lib.mkEnableOption "Wi-Fi (wpa_supplicant; PSKs from rpi.wifi.secretsFile)";

    networks = lib.mkOption {
      type = lib.types.attrsOf (lib.types.strMatching "[A-Za-z_][A-Za-z0-9_]*");
      default = { };
      example = { "Home Net" = "RPI_WIFI_HOME"; };
      description = ''
        SSID → name of the variable holding its PSK. The PSK itself is never
        in the configuration: `rpi-deploy secrets` (or `flash --wifi-env`)
        writes `VAR=<psk>` lines from the deploying machine's environment
        into `rpi.wifi.secretsFile`.
      '';
    };

    secretsFile = lib.mkOption {
      # A string, never a Nix path (a path would be copied into the store).
      type = lib.types.strMatching "/.+";
      default = "/var/lib/rpi/wireless.env";
      description = "Root-only (0600) file on the Pi with the `VAR=<psk>` lines.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (!cfg.enable) {
      hardware.raspberry-pi.config.all.dt-overlays.disable-wifi.enable = true;
    })

    (lib.mkIf cfg.enable {
      networking.wireless = {
        enable = true;
        inherit (cfg) secretsFile;
        networks = lib.mapAttrs (_ssid: var: { pskRaw = "ext:${var}"; }) cfg.networks;
      };
      hardware.firmware = lib.mkOverride 49 [ firmware ];
      systemd.tmpfiles.rules = [ "d /var/lib/rpi 0700 root root -" ];
    })
  ];
}
