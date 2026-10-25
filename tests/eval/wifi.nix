# rpi.wifi (spec §4, §7 "Wi-Fi on"; plan T2.4, D9, P6): off by default (the
# disable-wifi overlay stays); on: overlay gone, wpa_supplicant with PSKs
# from a file outside the store (`ext:<VAR>`) that only the daemon's user
# reads (B1), the Pi 3 wireless firmware despite rpi.sdWear. Evaluated on the fixture host through
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

  # B1 (final review): nixpkgs 26.05 runs wpa_supplicant as its own user
  # (networking.wireless.enableHardening, default on) without a DAC
  # override, and ext_password_backend=file: opens the secrets file as that
  # user. tmpfilesFor SYS FILE: the fields of the `z FILE ...` rules.
  tmpfilesFor = sys: f:
    map (r: lib.filter (s: s != "") (lib.splitString " " r))
      (lib.filter (lib.hasPrefix "z ${f} ") sys.config.systemd.tmpfiles.rules);
  # readableOnlyBy SYS: exactly one `z` rule hands rpi.wifi.secretsFile to
  # the user the service runs as, mode 0600 (nobody else, not even the
  # group: users in wpa_supplicant may control the daemon, not read PSKs).
  readableOnlyBy = sys:
    let
      sc = sys.config.systemd.services.wpa_supplicant.serviceConfig;
      rules = tmpfilesFor sys sys.config.rpi.wifi.secretsFile;
      r = lib.head rules;
    in
    lib.length rules == 1
    && lib.elemAt r 2 == "0600"
    && lib.elemAt r 3 == sc.User && lib.elemAt r 4 == sc.Group;
  etcFile = mk [ { rpi.wifi = { enable = true; inherit networks; secretsFile = "/etc/wifi.env"; }; } ];
  # S2: one unit per interface when networking.wireless.interfaces is set
  wlan0Sys = mk [ { rpi.wifi = { enable = true; inherit networks; };
                    networking.wireless.interfaces = [ "wlan0" ]; } ];
  wlan0 = wlan0Sys.config.systemd.services;
  # N5: rpi-lib.sh's host info expression (what rpi-deploy reads), applied
  # to a configuration as `nix eval --apply` does
  hostInfo = import (builtins.toFile "host-info.nix" (lib.head (builtins.match
    ".*\nRL_HOST_INFO_EXPR='([^']*)'\n.*" (builtins.readFile ../../rpi-lib.sh))));
  conditioned = u: (u.unitConfig.ConditionPathExists or null) == "/var/lib/rpi/wireless.env";
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

  "secretsFile is readable by the wpa_supplicant service user (and only by it)" =
    oc.systemd.services.wpa_supplicant.serviceConfig.User == "wpa_supplicant"
    && readableOnlyBy on
    && readableOnlyBy etcFile
    && tmpfilesFor t off.rpi.wifi.secretsFile == [ ];

  # S2 (final review): nixpkgs bind-mounts the file without `-`, so a
  # missing file fails the unit and with it the switch (exit 14/36); the
  # unit is skipped instead until `rpi-deploy secrets` writes the file.
  "wpa_supplicant unit(s) are conditioned on the secrets file" =
    conditioned oc.systemd.services.wpa_supplicant
    && conditioned wlan0."wpa_supplicant-wlan0"
    && !(wlan0 ? wpa_supplicant);

  # N5: `rpi-deploy secrets` restarts exactly these (read-only, derived)
  "the host info names the wpa_supplicant unit(s) secrets restarts" =
    (hostInfo on).wifi.units == [ "wpa_supplicant" ]
    && (hostInfo wlan0Sys).wifi.units == [ "wpa_supplicant-wlan0" ]
    && lib.all (u: wlan0 ? ${u}) wlan0Sys.config.rpi.wifi.units
    && rejects (mk [ { rpi.wifi.units = [ "x" ]; } ]).config.rpi.wifi.units;

  # L2 (re-review): a newer rpi-deploy/rpi-ci on a flake whose library
  # predates rpi.wifi.units: the host info still evaluates, without units
  # (rpi-deploy secrets then restarts wpa_supplicant)
  "host info of a library without rpi.wifi.units omits units" =
    let
      old = hostInfo {
        config.system.name = "old";
        config.rpi = {
          deploy.target = "root@old";
          ssh.port = 22;
          pull.cache = null;
          wifi = { enable = true; networks = { }; secretsFile = "/var/lib/rpi/wireless.env"; };
        };
      };
    in
    old.wifi.enable && old.wifi.secretsFile == "/var/lib/rpi/wireless.env"
    && !(old.wifi ? units);

  "/var/lib/rpi is a 0700 root dir" =
    lib.elem "d /var/lib/rpi 0700 root root -" oc.systemd.tmpfiles.rules;

  "network values must be variable names" =
    rejects (mk [ { rpi.wifi.networks.x = "my-var"; } ]).config.rpi.wifi.networks
    && rejects (mk [ { rpi.wifi.networks.x = "1VAR"; } ]).config.rpi.wifi.networks
    && !(rejects (mk [ { rpi.wifi.networks.x = "_Ok_2"; } ]).config.rpi.wifi.networks);
}
