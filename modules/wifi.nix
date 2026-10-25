# rpi.wifi (spec §4; plan D9): Wi-Fi, off by default.
#   off: config.txt keeps the disable-wifi overlay (the chip stays off).
#   on:  the overlay is gone, wpa_supplicant joins rpi.wifi.networks and
#        networkd runs DHCP on the wireless link (NixOS's default wireless
#        network, networking.useDHCP). PSKs never enter the store (it goes
#        to a public cache and is world-readable on the Pi): each network's
#        pskRaw is `ext:<VAR>`, VAR=<psk> lines live in rpi.wifi.secretsFile,
#        written by `rpi-deploy secrets` / `flash --wifi-env`. nixpkgs 26.05
#        runs wpa_supplicant as the user wpa_supplicant without a DAC
#        override (networking.wireless.enableHardening), so a tmpfiles `z`
#        rule hands the file to that user, mode 0600: at every boot (a card
#        written by `flash --wifi-env` has no such user yet), on a switch
#        that adds the rule, and right after `secrets` writes the file.
# The Pi 3 Wi-Fi/Bluetooth firmware (nvmd's raspberrypiWirelessFirmware,
# cached with nvmd's kernel) is listed at priority 49 so it beats
# rpi.sdWear's `hardware.firmware = mkForce [ ]` (50).
# Checked by checks.x86_64-linux.eval-wifi.
{ config, lib, pkgs, nixos-raspberrypi, ... }:
let
  cfg = config.rpi.wifi;
  # nixpkgs' unit names: one per networking.wireless.interfaces entry, else one
  units =
    let ifs = config.networking.wireless.interfaces; in
    if ifs == [ ] then [ "wpa_supplicant" ] else map (i: "wpa_supplicant-${i}") ifs;
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
      # A plain absolute file path (rpi-deploy's rule, re-review N-c): it goes
      # into a tmpfiles line, BindReadOnlyPaths and rpi-deploy's remote
      # command, where whitespace, `%` or shell characters would break.
      type = lib.types.addCheck (lib.types.strMatching "/[A-Za-z0-9._/-]*[A-Za-z0-9._-]")
        (s: !lib.hasInfix "/../" "${s}/");
      default = "/var/lib/rpi/wireless.env";
      description = ''
        File on the Pi with the `VAR=<psk>` lines, outside the store, owned
        by the wpa_supplicant user (the daemon's), mode 0600; a tmpfiles
        rule sets both. A plain absolute path: letters, digits, `._-/`, no
        `..` segment.
      '';
    };

    units = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = units;
      defaultText = lib.literalExpression ''[ "wpa_supplicant" ]'';
      readOnly = true;
      internal = true;
      description = ''
        The wpa_supplicant unit names (without `.service`); `rpi-deploy
        secrets` restarts them (read through rpi-lib.sh's host info).
      '';
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
      # nixpkgs bind-mounts the secrets file into the unit (no `-` prefix),
      # so without the file the unit fails (226/NAMESPACE) and with it a
      # deploy's switch. Skipped instead until the file exists; `rpi-deploy
      # secrets` writes it and restarts the unit (final review S2).
      systemd.services = lib.genAttrs units (_: {
        unitConfig.ConditionPathExists = cfg.secretsFile;
      });
      hardware.firmware = lib.mkOverride 49 [ firmware ];
      systemd.tmpfiles.rules = [
        "d /var/lib/rpi 0700 root root -"
        # the daemon reads the file as this user through a read-only bind
        # mount (the 0700 directory is not in the way); `rpi-deploy
        # secrets` applies the rule with systemd-tmpfiles --prefix=<file>
        "z ${cfg.secretsFile} 0600 wpa_supplicant wpa_supplicant -"
      ];
    })
  ];
}
