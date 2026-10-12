{
  description = "NixOS Flake for Raspberry Pi 3 Model B V1.2, plus aarch64 build-host tooling (rpi-install)";

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
      inputs.home-manager.follows = "home-manager";
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
  } @ inputs: let
    lib = nixpkgs.lib;
    pkgsFor = system: nixpkgs.legacyPackages.${system};
    forSystem = systems: lib.genAttrs systems;

    # The install/build wrapper script as a package (pure shell, so the
    # package is usable on any build host). Explicit mkDerivation: the
    # writeShellScript* helpers' store-path shape varies between nixpkgs
    # versions, but $out/bin/<name> is what environment.systemPackages
    # (buildEnv) requires.
    rpiInstall = system: (pkgsFor system).stdenv.mkDerivation {
      name = "rpi-install";
      dontUnpack = true;
      dontBuild = true;
      installPhase = ''
        mkdir -p $out/bin
        cp ${./install.sh} $out/bin/rpi-install
        chmod 755 $out/bin/rpi-install
      '';
    };

    # Importing the modules via the flake outputs pre-fills the
    # installScript option, so a plain `rpi.buildHost.enable = true` is
    # enough on the consuming side. Must stay a module *function* in the
    # imports list: the module system calls it with proper args (pkgs is
    # resolved through _module.args, which a raw function call would
    # bypass).
    buildHostModule =
      { pkgs, ... }: {
        rpi.buildHost.installScript = lib.mkDefault (
          pkgs.stdenv.mkDerivation {
            name = "rpi-install";
            dontUnpack = true;
            dontBuild = true;
            installPhase = ''
              mkdir -p $out/bin
              cp ${./install.sh} $out/bin/rpi-install
              chmod 755 $out/bin/rpi-install
            '';
          }
        );
      };
  in {
    nixosConfigurations = {
      rpi = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          # Hardware optimization for Raspberry Pi 3
          nixos-hardware.nixosModules.raspberry-pi-3

          ./configuration.nix

          # Integrate Home Manager as a NixOS module
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.extraSpecialArgs = { inherit inputs; };
            # nix-terminal options are Home Manager options, so the module
            # belongs in the HM scope (sharedModules), not in the NixOS list.
            home-manager.sharedModules = [ nix-terminal.homeModules.default ];
            home-manager.users.pi = import ./home.nix;
          }
        ];
      };

      # x86_64 test configuration for the build-host module:
      #   nix build .#nixosConfigurations.rpiBuildHostTest.config.system.build.toplevel
      rpiBuildHostTest = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          {
            imports = [
              self.nixosModules.rpiBuildHost
              ./tests/build-host.nix
            ];
          }
        ];
      };
    };

    # Build-host modules: aarch64 emulation + rpi-install (see modules/).
    nixosModules.rpiBuildHost = {
      imports = [
        ./modules/build-host.nix
        buildHostModule
      ];
    };

    homeModules.rpiBuildHost = {
      imports = [
        ./modules/build-host-home.nix
        buildHostModule
      ];
    };

    packages = forSystem [ "aarch64-linux" "x86_64-linux" ] (system: {
      rpi-install = rpiInstall system;
      default = rpiInstall system;
    });

    checks = forSystem [ "aarch64-linux" "x86_64-linux" ] (system: let
      pkgs = pkgsFor system;
    in {
      # bash syntax check of the wrapper script.
      # Note: the script must come in as `src`, not `nativeBuildInputs` —
      # stdenv *sources* every regular file in nativeBuildInputs as a
      # setup hook, which would execute the script (with `$pkg -1 0` as
      # positional args) before the check even starts.
      rpi-install-syntax = pkgs.runCommand "rpi-install-syntax-check" {
        src = ./install.sh;
      } ''
        ${pkgs.bash}/bin/bash -n $src
        touch $out
      '';
    });
  };
}
