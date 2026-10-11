{
  description = "NixOS Flake for Raspberry Pi 3 Model B V1.2";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-terminal = {
      url = "github:grburst/nix-terminal";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    llm-agents.url = "github:numtide/llm-agents.nix";
  };

  outputs = {
    self,
    nixpkgs,
    nixos-hardware,
    home-manager,
    nix-terminal,
    llm-agents,
    ...
  } @ inputs: {
    nixosConfigurations.rpi = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      specialArgs = {inherit inputs;};
      modules = [
        # Hardware optimization for Raspberry Pi 3
        nixos-hardware.nixosModules.raspberry-pi-3

        ./configuration.nix

        nix-terminal.homeModules.default
        # Integrate Home Manager as a NixOS module
        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.extraSpecialArgs = {inherit inputs;};
          home-manager.users.pi = import ./home.nix;
        }
      ];
    };
  };
}
