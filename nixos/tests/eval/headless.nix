# modules/headless.nix: headless config.txt profile (spec §3.2, s6 §4).
# Asserted on the generated config.txt, i.e. the lines the GPU firmware
# reads, not on the option values that produce them.
{ lib, rpi, ... }:
let
  cfg = rpi.config;
  allLines = lib.splitString "\n" cfg.hardware.raspberry-pi.config-generated;
  # Lines of the `[all]` section: what applies to the Pi 3 (the [cm4]/[cm5]
  # sections only filter for other boards). Empty if there is no [all].
  section =
    let
      start = lib.lists.findFirstIndex (l: l == "[all]") (lib.length allLines) allLines;
      rest = lib.drop (start + 1) allLines;
    in
    lib.take (lib.lists.findFirstIndex (lib.hasPrefix "[") (lib.length rest) rest) rest;
  has = l: lib.elem l section;
  hasAnywhere = prefix: lib.any (lib.hasPrefix prefix) allLines;
in
{
  "headless is enabled by default" = cfg.rpi.headless.enable or false;

  "config.txt has gpu_mem=16" = has "gpu_mem=16";

  "config.txt disables wifi and bt overlays" =
    has "dtoverlay=disable-wifi" && has "dtoverlay=disable-bt";

  "config.txt has no vc4-kms-v3d overlay" = !(hasAnywhere "dtoverlay=vc4-kms-v3d");

  "config.txt has no audio dtparam" = !(hasAnywhere "dtparam=audio=");

  "config.txt has no camera/display auto-detect" =
    !(hasAnywhere "camera_auto_detect=") && !(hasAnywhere "display_auto_detect=");

  # Boot-critical lines must survive the profile (UART console, 64 bit, U-Boot).
  "config.txt keeps enable_uart=1" = has "enable_uart=1";

  "config.txt keeps arm_64bit=1 and u-boot kernel" =
    has "arm_64bit=1" && has "kernel=u-boot-rpi-arm64.bin";
}
