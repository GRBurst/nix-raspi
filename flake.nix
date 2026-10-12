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

    # x86_64 test configuration for the build-host module (see tests/).
    # Used by nixosConfigurations.rpiBuildHostTest and by the contract
    # asserts below; booted as a VM by checks.x86_64-linux.rpi-host-vm
    # (which adds the test script and a prebuilt aarch64 binary).
    #
    # NOTE: imports the module files directly, NOT via
    # self.nixosModules.rpiBuildHost — the contract asserts force this
    # config on every flake evaluation, and a self-reference there would
    # be infinite recursion (self forces outputs, which force this).
    hostTestSystem = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        {
          imports = [
            ./modules/build-host.nix
            buildHostModule
            ./tests/build-host.nix
          ];
        }
      ];
    };

    # Contract asserts: evaluated on every flake evaluation, so a drift in
    # what the build-host module wires up fails any flake operation fast.
    contract = {
      binfmt = hostTestSystem.config.boot.binfmt.emulatedSystems == [ "aarch64-linux" ];
      extraPlatforms = lib.elem "aarch64-linux" hostTestSystem.config.nix.settings.extra-platforms;
      expFeatures =
        (lib.intersectLists [ "nix-command" "flakes" ]
        hostTestSystem.config.nix.settings.experimental-features)
        == [ "nix-command" "flakes" ];
      sandboxPaths = lib.any
        (p: lib.strings.hasInfix "qemu-aarch64" p || p == "/run/binfmt")
        hostTestSystem.config.nix.settings.extra-sandbox-paths;
      wrapperPkg = lib.any
        (p: p.name == "rpi-install-flake-wrapper")
        hostTestSystem.config.environment.systemPackages;
    };
  # The contract checks are forced by making them the guard of the
  # outputs value, so any flake operation fails fast on module drift.
  # (lib.assertMsg returns a Bool — it cannot wrap the value itself.)
  in
  if
    (lib.assertMsg contract.binfmt "build-host contract: boot.binfmt.emulatedSystems = [ aarch64-linux ]")
    && (lib.assertMsg contract.extraPlatforms "build-host contract: nix extra-platforms includes aarch64-linux")
    && (lib.assertMsg contract.expFeatures "build-host contract: nix experimental-features include nix-command + flakes")
    && (lib.assertMsg contract.sandboxPaths "build-host contract: nix extra-sandbox-paths expose the qemu-aarch64 handler")
    && (lib.assertMsg contract.wrapperPkg "build-host contract: rpi-install wrapper is in environment.systemPackages")
  then
  {
            
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
                    # nix-terminal options are Home Manager options, so the
                    # module belongs in the HM scope (sharedModules), not in
                    # the NixOS list.
                    home-manager.sharedModules = [ nix-terminal.homeModules.default ];
                    home-manager.users.pi = import ./home.nix;
                  }
                ];
              };

              # x86_64 test configuration for the build-host module:
              #   nix build .#nixosConfigurations.rpiBuildHostTest.config.system.build.toplevel
              rpiBuildHostTest = hostTestSystem;
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

            checks = forSystem [ "aarch64-linux" "x86_64-linux" ] (system: {
              # bash syntax check of the wrapper script.
              # Note: the script must come in as `src`, not
              # `nativeBuildInputs` — stdenv *sources* every regular file in
              # nativeBuildInputs as a setup hook, which would execute the
              # script (with `$pkg -1 0` as positional args) before the check
              # even starts.
              rpi-install-syntax = (pkgsFor system).runCommand "rpi-install-syntax-check" {
                src = ./install.sh;
              } ''
                ${(pkgsFor system).bash}/bin/bash -n $src
                touch $out
              '';
            })
            // (
              # x86_64-only checks (the build host is x86_64).
              let
                x86Pkgs = pkgsFor "x86_64-linux";
                aarch64Pkgs = pkgsFor "aarch64-linux";
              in {
                x86_64-linux = {
                  # Unit tests for the rpi-install script: runs the real
                  # script against mocked `nix`/`nixos-install`, so no real
                  # builds and no aarch64 emulation are needed. Covers the
                  # emulation preflight, build record round-trip, show,
                  # install verification, --from, attr mismatches,
                  # divergence warnings.
                  rpi-install-unit = x86Pkgs.runCommand "rpi-install-unit-check" {
                    scriptSrc = ./install.sh;
                    unitSrc = ./tests/install-unit.sh;
                    nativeBuildInputs = [ x86Pkgs.git ];
                  } ''
                    RPI_INSTALL_SRC=$scriptSrc ${x86Pkgs.bash}/bin/bash $unitSrc
                    touch $out
                  '';

                  # Boots the build-host test system in a VM and verifies
                  # the module end-to-end: binfmt registration, nix aarch64
                  # support, the rpi-install wrapper, and that a real
                  # aarch64 binary runs via binfmt. Slow (qemu TCG without
                  # KVM); no kernel is involved (the aarch64 side is a
                  # prebuilt `hello`).
                  rpi-host-vm = x86Pkgs.testers.runNixOSTest {
                    name = "rpi-build-host";
                    nodes.host = {
                      # The nixos-test framework supplies test-node defaults
                      # (root fs etc.) for boot; tests/build-host.nix' dummy
                      # /dev/sda* entries are for the standalone toplevel
                      # build only.
                      imports = [ self.nixosModules.rpiBuildHost ];
                      # The module is opt-in (mkIf cfg.enable) — the exported
                      # nixosModule only wires the module in, it must not
                      # enable the feature for consumers.
                      rpi.buildHost.enable = true;
                      # exercises the RPI_FLAKE wrapper (mirrors live-host use)
                      rpi.buildHost.flakePath = "/tmp/rpi-nixos";
                      environment.systemPackages = [ aarch64Pkgs.hello x86Pkgs.git ];
                    };
                    testScript = ''
                      start_all()
                      host.wait_for_unit("multi-user.target")
                      host.wait_until_succeeds("nix show-config")
                      # binfmt handler registered for aarch64 (current NixOS
                      # names the handler after the system, not the emulator)
                      host.succeed("test -e /proc/sys/fs/binfmt_misc/aarch64-linux")
                      # nix can cross-build for aarch64 (no -q in the middle of
                      # the pipe: -q silences the stream the next grep reads)
                      host.succeed("nix show-config | grep extra-platforms | grep aarch64-linux")
                      # rpi-install is on PATH, runs, and is the RPI_FLAKE wrapper
                      host.succeed("command -v rpi-install >/dev/null")
                      host.succeed("rpi-install --help")
                      host.succeed("readlink -f $(command -v rpi-install) > /tmp/wrapper")
                      # /tmp/wrapper holds the resolved wrapper PATH (not its
                      # contents) — grep the file at that path
                      host.succeed("grep -qF RPI_FLAKE= $(cat /tmp/wrapper)")
                      host.succeed("grep -qF /tmp/rpi-nixos $(cat /tmp/wrapper)")
                      # an aarch64 binary actually runs via binfmt (the module's core job)
                      host.succeed("${aarch64Pkgs.hello}/bin/hello")
                      # the installed tool runs its dry-run flows end-to-end
                      host.succeed("mkdir -p /tmp/fake-flake && touch /tmp/fake-flake/flake.nix")
                      host.succeed("rpi-install build --dry-run --flake /tmp/fake-flake")
                      host.succeed("rpi-install show --flake /tmp/fake-flake | grep -q 'no build record'")
                    '';
                  };
                };
              }
            );
  }
  else
    builtins.unreachable
;
}
