# SD image of `rpi` itself (formerly the `rpi-image` output, "Variant B"):
#   nix build .#nixosConfigurations.rpi.config.system.build.sdImage
# Only nixpkgs' generic sd-image.nix plus the populate commands nvmd's own
# sd-image module uses, so the image system is our system (no base
# profile). The bootloader/firmware are populated inside the image build
# (nix sandbox): no nixos-install, no chroot, no binfmt-in-chroot.
# Checked by checks.x86_64-linux.eval-image.
{ config, lib, modulesPath, ... }: {
  imports = [ (modulesPath + "/installer/sd-card/sd-image.nix") ];
  # nixpkgs sd-image.nix adds the `sd-card` tag; the pulled toplevel must be
  # nixos-system-<hostName>-<version> (addendum §3.5, rpi-pull name regex).
  system.nixos.tags = lib.mkForce [ ];
  # same mount options as the installed `rpi` system
  fileSystems."/boot/firmware".options = lib.mkForce [ "fmask=0077" "dmask=0077" ];
  sdImage = {
    # keep our labels (the system mounts its file systems by label)
    firmwarePartitionName = "NIXOS_BOOT";
    # U-Boot: the FAT partition holds only firmware, config.txt,
    # u-boot (kernels live on the ext4 root), see README.
    firmwareSize = 256;
    firmwarePartitionID = "0x2175794e";
    compressImage = true;
    expandOnBoot = true;
    populateFirmwareCommands = ''
      ${config.boot.loader.raspberry-pi.firmwarePopulateCmd} -c ${config.system.build.toplevel} -f ./firmware
    '';
    populateRootCommands = ''
      mkdir -p ./files/boot/firmware
      ${config.boot.loader.raspberry-pi.bootPopulateCmd} -c ${config.system.build.toplevel} -b ./files/boot
    '';
  };
  # <hostName>-rpi3.img.zst
  image.baseName = lib.mkDefault "${config.networking.hostName}-rpi3";
}
