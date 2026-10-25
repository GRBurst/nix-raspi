# nixosModules.default: every rpi.* module (spec §3, §4). For users who wire
# nvmd's raspberry-pi-3.base themselves (through nvmd's lib.nixosSystem:
# wifi.nix and bluetooth.nix take its `nixos-raspberrypi` module argument for
# the wireless firmware; plain nixpkgs.lib.nixosSystem needs
# specialArgs.nixos-raspberrypi = <nvmd flake>); lib.mkPi imports it for
# everyone else. The terminal profile is separate (nixosModules.terminal):
# it defines home-manager options and needs the home-manager NixOS module (D5).
#
# Order matters (D6): it is the order list options merge in, kept equal to
# the pre-library module list so existing hosts keep their derivations.
{
  imports = [
    ./sd-image.nix
    ./sd-wear.nix
    ./headless.nix
    ./external-storage.nix
    ./pull-update.nix
    ./base.nix
    ./identity.nix
    ./network.nix
    ./wifi.nix
    ./bluetooth.nix
  ];
}
