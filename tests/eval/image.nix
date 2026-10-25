# One definition (spec §3): the SD image is a build output of `rpi` itself
# (config.system.build.sdImage, modules/sd-image.nix); the separate
# rpi-image / rpi-image-nvmd outputs are gone. Reads option values only:
# the image derivation is never instantiated here (it would force toplevel).
{ lib, rpi, nixosConfigurations, ... }:
let
  cfg = rpi.config;
  # `or null`: without modules/sd-image.nix the sdImage options do not
  # exist; the property is then false instead of an evaluation error.
  sd = cfg.sdImage or { };
  firmwareOpts = cfg.fileSystems."/boot/firmware".options or [ ];
in
{
  "rpi exposes system.build.sdImage" =
    cfg.system.build ? sdImage && lib.isDerivation cfg.system.build.sdImage;

  "image file is neptun-rpi3.img.zst" =
    (cfg.image.fileName or null) == "neptun-rpi3.img.zst";

  "firmware partition label is NIXOS_BOOT" =
    (sd.firmwarePartitionName or null) == "NIXOS_BOOT";

  "root label is NIXOS_SD" =
    (sd.rootVolumeLabel or null) == "NIXOS_SD"
    && cfg.fileSystems."/".device == "/dev/disk/by-label/NIXOS_SD";

  "firmware partition is 256 MiB with ID 0x2175794e" =
    (sd.firmwareSize or null) == 256 && (sd.firmwarePartitionID or null) == "0x2175794e";

  "image is compressed and expands on first boot" =
    (sd.compressImage or false) && (sd.expandOnBoot or false)
    && cfg.systemd.services ? expand-root-partition;

  "/boot/firmware mounted with fmask/dmask, not noauto" =
    lib.elem "fmask=0077" firmwareOpts && lib.elem "dmask=0077" firmwareOpts
    && !(lib.elem "noauto" firmwareOpts);

  # P9: the pulled toplevel must be nixos-system-neptun-<version> (addendum
  # §3.5); nixpkgs sd-image.nix would add the `sd-card` tag.
  "no sd-card tag: toplevel is nixos-system-neptun-<version>" =
    cfg.system.nixos.tags == [ ]
    && cfg.system.nixos.label == cfg.system.nixos.version
    && cfg.system.name == "neptun"
    && builtins.match "nixos-system-neptun-[^/]*" "nixos-system-${cfg.system.name}-${cfg.system.nixos.label}" != null;

  "no separate rpi-image outputs" =
    !(nixosConfigurations ? rpi-image) && !(nixosConfigurations ? rpi-image-nvmd);
}
