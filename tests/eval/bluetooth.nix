# rpi.bluetooth (spec §4, §7 "Bluetooth on"; plan T2.4, D9): off by default
# (the disable-bt overlay stays); on: overlay gone, hardware.bluetooth, the
# Pi 3 firmware (BCM43430 patch) despite rpi.sdWear. Evaluated on the
# fixture host through lib.mkPi; never forces the toplevel.
{ lib, rpiLib, fixtures, nvmd, ... }:
let
  minimal = fixtures + "/hosts/minimal.nix";
  mk = extra: rpiLib.mkPi { modules = [ minimal ] ++ extra; };
  t = mk [ ];
  on = mk [ { rpi.bluetooth.enable = true; } ];
  off = t.config;
  oc = on.config;
  section = c:
    let
      ls = lib.splitString "\n" c.hardware.raspberry-pi.config-generated;
      start = lib.lists.findFirstIndex (l: l == "[all]") (lib.length ls) ls;
      rest = lib.drop (start + 1) ls;
    in
    lib.take (lib.lists.findFirstIndex (lib.hasPrefix "[") (lib.length rest) rest) rest;
  overlay = c: name: lib.elem "dtoverlay=${name}" (section c);
  firmware = sys: lib.concatLists sys.options.hardware.firmware.definitions;
  fw = nvmd.packages.aarch64-linux.raspberrypiWirelessFirmware;
in
{
  "off: disable-bt overlay on, bluetooth off" =
    !off.rpi.bluetooth.enable && overlay off "disable-bt"
    && !off.hardware.bluetooth.enable && firmware t == [ ];

  "bluetooth on: disable-bt overlay gone, hardware.bluetooth on, firmware" =
    !(overlay oc "disable-bt") && oc.hardware.bluetooth.enable
    && map (p: p.outPath) (firmware on) == [ fw.outPath ];

  # Wi-Fi and Bluetooth share the firmware package (each module lists it;
  # the firmware buildEnv holds it once).
  "both radios on: both overlays gone, the firmware present" =
    let b = mk [ { rpi.bluetooth.enable = true; rpi.wifi.enable = true; } ]; in
    lib.unique (map (p: p.outPath) (firmware b)) == [ fw.outPath ]
    && !(overlay b.config "disable-bt") && !(overlay b.config "disable-wifi");
}
