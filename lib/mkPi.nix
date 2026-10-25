# lib.mkPi: the library's one entry point (spec §3; plan §15, D5–D7).
#
#   nixosConfigurations.<name> = rpi.lib.mkPi { modules = [ ./hosts/<name>.nix ]; };
#
# Wraps nvmd's nixosSystem (Raspberry Pi 3 base: U-Boot, firmware,
# config.txt, vendor kernel) with the "hybrid" inputs (userspace from our
# nixpkgs, kernel/firmware from nvmd's own pin and cache), the rpi.* modules
# (nixosModules.default), the terminal profile (nixosModules.terminal, off by
# default) and home-manager. Every NixOS option stays settable from
# `modules`.
#
# The result is marked `rpiHost = true`: host discovery (rpi-lib.sh
# rl_hosts, rpi-ci hosts) filters nixosConfigurations on it without
# evaluating each system.
#
# Module order (D6) mirrors the pre-library configuration (Pi base, rpi.*
# modules, host, home-manager) so list options merge in the same order.
# `specialArgs` default to `{ inherit inputs; }` (the library's inputs);
# a consumer's specialArgs win, also for Home Manager modules
# (extraSpecialArgs.inputs). Library modules never read `inputs`.
{ inputs }:
{ modules, specialArgs ? { } }:
let
  args = { inherit inputs; } // specialArgs;
in
(inputs.nixos-raspberrypi.lib.nixosSystem {
  inherit (inputs) nixpkgs;
  specialArgs = args;
  modules = [
    inputs.nixos-raspberrypi.nixosModules.raspberry-pi-3.base
    inputs.self.nixosModules.default
    inputs.self.nixosModules.terminal
  ]
  ++ modules
  ++ [
    inputs.home-manager.nixosModules.home-manager
    {
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      # the same `inputs` as the NixOS modules (a consumer's win)
      home-manager.extraSpecialArgs = { inherit (args) inputs; };
      # nix-terminal options are Home Manager options, so the module belongs
      # in the HM scope (sharedModules), not in the NixOS list.
      home-manager.sharedModules = [ inputs.nix-terminal.homeModules.default ];
    }
  ];
}) // { rpiHost = true; }
