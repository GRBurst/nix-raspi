# rpi.wifi (spec §4, §7 "Wi-Fi on"; plan T2.4, D9, P6): off by default (the
# disable-wifi overlay stays); on: overlay gone, wpa_supplicant with PSKs
# from a root-only file outside the store (`ext:<VAR>`), the Pi 3 wireless
# firmware despite rpi.sdWear. Evaluated on the fixture host through
# lib.mkPi; never forces the toplevel.
{ lib, rpiLib, fixtures, nvmd, ... }:
let
  minimal = fixtures + "/hosts/minimal.nix";
  mk = extra: rpiLib.mkPi { modules = [ minimal ] ++ extra; };
  t = mk [ ];
  networks = { "Home Net" = "RPI_WIFI_HOME"; Lab = "RPI_WIFI_LAB"; };
  on = mk [ { rpi.wifi = { enable = true; inherit networks; }; } ];
  off = t.config;
  oc = on.config;
  w = oc.networking.wireless;

  # Lines of config.txt's [all] section (what applies to the Pi 3).
  section = c:
    let
      ls = lib.splitString "\n" c.hardware.raspberry-pi.config-generated;
      start = lib.lists.findFirstIndex (l: l == "[all]") (lib.length ls) ls;
      rest = lib.drop (start + 1) ls;
    in
    lib.take (lib.lists.findFirstIndex (lib.hasPrefix "[") (lib.length rest) rest) rest;
  overlay = c: name: lib.elem "dtoverlay=${name}" (section c);
  # hardware.firmware's value is a buildEnv (apply); the definitions that
  # won (highest priority) are the list.
  firmware = sys: lib.concatLists sys.options.hardware.firmware.definitions;
  fw = nvmd.packages.aarch64-linux.raspberrypiWirelessFirmware;
  rejects = v: !(builtins.tryEval (builtins.deepSeq v v)).success;
in
{
  "off: disable-wifi overlay on, no wpa_supplicant, firmware list empty" =
    !off.rpi.wifi.enable && overlay off "disable-wifi"
    && !off.networking.wireless.enable && firmware t == [ ];

  "on: overlay gone, wpa_supplicant on, secretsFile /var/lib/rpi/wireless.env" =
    !(overlay oc "disable-wifi") && w.enable
    && oc.rpi.wifi.secretsFile == "/var/lib/rpi/wireless.env"
    && w.secretsFile == oc.rpi.wifi.secretsFile;

  # P6
  "every network uses ext:<VAR>, never psk" =
    lib.attrNames w.networks == lib.attrNames networks
    && lib.all (ssid: w.networks.${ssid}.pskRaw == "ext:${networks.${ssid}}"
                      && w.networks.${ssid}.psk == null)
      (lib.attrNames networks);

  "secretsFile is a string outside the store" =
    lib.isString w.secretsFile
    && !(lib.hasPrefix builtins.storeDir w.secretsFile)
    && !(on.options.rpi.wifi.secretsFile.type.check ./wifi.nix)
    && !(on.options.rpi.wifi.secretsFile.type.check "wireless.env");

  "on: Pi 3 wireless firmware despite rpi.sdWear" =
    oc.rpi.sdWear.enable
    && map (p: p.outPath) (firmware on) == [ fw.outPath ];

  "/var/lib/rpi is a 0700 root dir" =
    lib.elem "d /var/lib/rpi 0700 root root -" oc.systemd.tmpfiles.rules;

  "network values must be variable names" =
    rejects (mk [ { rpi.wifi.networks.x = "my-var"; } ]).config.rpi.wifi.networks
    && rejects (mk [ { rpi.wifi.networks.x = "1VAR"; } ]).config.rpi.wifi.networks
    && !(rejects (mk [ { rpi.wifi.networks.x = "_Ok_2"; } ]).config.rpi.wifi.networks);
}
