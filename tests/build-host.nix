# Test configuration extras for the build-host module, instantiated from
# flake.nix as `nixosConfigurations.rpiBuildHostTest` on x86_64. Validated by:
#
#   nix build .#nixosConfigurations.rpiBuildHostTest.config.system.build.toplevel
#
# (fast, native build; proves the module evaluates and wires up binfmt/nix
# settings without touching a real host)

{
  # Dummy boot/filesystem entries so the bare x86_64 test system passes
  # NixOS's bootability assertions (this config is never installed).
  fileSystems."/" = {
    device = "/dev/sda2";
    fsType = "ext4";
  };
  boot.loader.grub.devices = [ "/dev/sda" ];
  # Every flake evaluation forces this system (contract asserts in
  # flake.nix); without it each nix command warns "stateVersion is not set".
  system.stateVersion = "26.05";

  rpi.buildHost.enable = true;
  # arbitrary: exercises the RPI_FLAKE wrapper in the test system
  rpi.buildHost.flakePath = "/tmp/rpi-nixos";
}
