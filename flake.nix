{
  description = "NixOS Flake for Raspberry Pi 3 Model B V1.2, plus aarch64 build-host tooling (rpi-deploy)";

  # Binary cache of nvmd/nixos-raspberrypi: holds the vendor kernel
  # (linux_rpi3), firmware and RPi packages built for the nixpkgs revision
  # that nixos-raspberrypi pins. Without it the kernel is compiled locally
  # (16+ h under qemu). Applied when the flake config is accepted
  # (`--accept-flake-config`, which rpi-deploy.sh passes) and the user is
  # trusted, or when the host nix.conf lists it (see modules/build-host.nix).
  nixConfig = {
    extra-substituters = [ "https://nixos-raspberrypi.cachix.org" ];
    extra-trusted-public-keys = [
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
    ];
  };

  inputs = {
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";

    # CRITICAL: use exactly the nixpkgs that nixos-raspberrypi pins (and
    # builds its cache from). Any other revision changes the kernel
    # derivation hash -> cache miss -> local kernel build.
    nixpkgs.follows = "nixos-raspberrypi/nixpkgs";

    home-manager = {
      # master, not release-26.05: nix-terminal needs HM options that only
      # exist on master (programs.devenv). Master against the older nixpkgs of
      # nixos-raspberrypi works; the release-mismatch warning is silenced in
      # home.nix.
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
    nixos-raspberrypi,
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
    #
    # The card tools of `prepare`/`eject`/`config` are appended to PATH
    # (suffix: the host's own tools win), so the script works on a host that
    # has none of them in its profile. nix/nixos-install/sudo are deliberately
    # NOT bundled: they must be the host's.
    mkRpiDeploy = pkgs: pkgs.stdenv.mkDerivation {
      name = "rpi-deploy";
      dontUnpack = true;
      dontBuild = true;
      nativeBuildInputs = [ pkgs.makeWrapper ];
      installPhase = ''
        mkdir -p $out/bin
        cp ${./rpi-deploy.sh} $out/bin/rpi-deploy
        chmod 755 $out/bin/rpi-deploy
        wrapProgram $out/bin/rpi-deploy --suffix PATH : ${lib.makeBinPath (with pkgs; [
          util-linux dosfstools e2fsprogs gnutar findutils coreutils git
        ])}
      '';
    };
    rpiDeploy = system: mkRpiDeploy (pkgsFor system);

    # Importing the modules via the flake outputs pre-fills the
    # installScript option, so a plain `rpi.buildHost.enable = true` is
    # enough on the consuming side. Must stay a module *function* in the
    # imports list: the module system calls it with proper args (pkgs is
    # resolved through _module.args, which a raw function call would
    # bypass).
    buildHostModule =
      { pkgs, ... }: {
        rpi.buildHost.installScript = lib.mkDefault (mkRpiDeploy pkgs);
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
      # the emulator must be usable in the nix build sandbox: either the
      # kernel already holds it open (F flag) or the sandbox exposes it
      sandboxPaths =
        hostTestSystem.config.boot.binfmt.registrations.aarch64-linux.fixBinary
        || lib.any
          (p: lib.strings.hasInfix "qemu-aarch64" p || p == "/run/binfmt")
          hostTestSystem.config.nix.settings.extra-sandbox-paths;
      nvmdCache = lib.elem "https://nixos-raspberrypi.cachix.org"
        hostTestSystem.config.nix.settings.extra-substituters;
      # F flag: the qemu handler must also work inside the card chroot that
      # nixos-install uses (see modules/build-host.nix)
      chrootEmulation =
        hostTestSystem.config.boot.binfmt.registrations.aarch64-linux.fixBinary;
      wrapperPkg = lib.any
        (p: p.name == "rpi-deploy-flake-wrapper")
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
    && (lib.assertMsg contract.sandboxPaths "build-host contract: the qemu-aarch64 handler is usable in the nix sandbox (F flag or extra-sandbox-paths)")
    && (lib.assertMsg contract.nvmdCache "build-host contract: nix extra-substituters include the nixos-raspberrypi cache")
    && (lib.assertMsg contract.chrootEmulation "build-host contract: the aarch64 binfmt handler has the F flag (works in the nixos-install chroot)")
    && (lib.assertMsg contract.wrapperPkg "build-host contract: rpi-deploy wrapper is in environment.systemPackages")
  then
  {
            
            nixosConfigurations = {
              # nixos-raspberrypi.lib.nixosSystem is a drop-in for
              # nixpkgs.lib.nixosSystem: it injects the vendor kernel /
              # firmware overlays and trusts the nvmd binary cache.
              # (nixosSystemFull would apply RPi overlays globally = more
              # rebuilds; not needed for this headless system.)
              rpi = nixos-raspberrypi.lib.nixosSystem {
                specialArgs = { inherit inputs; };
                modules = [
                  # Raspberry Pi 3 base: U-Boot, firmware, config.txt,
                  # vendor kernel (linuxPackages_rpi3)
                  nixos-raspberrypi.nixosModules.raspberry-pi-3.base

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

              # Alias under the pi's hostname: on the pi, `nixos-rebuild --flake
              # /etc/nixos` (and autoUpgrade) default to `#<hostname>`. Same
              # derivation as `rpi`, so the installed system does not change.
              neptun = self.nixosConfigurations.rpi;

              # EXPERIMENT (see HANDOFF.md, "Decision record"): the same system
              # as an SD image, built with nixos-raspberrypi's sd-image module.
              # The bootloader/firmware are populated inside the image build
              # (nix sandbox) - no nixos-install, no chroot, no binfmt-in-chroot.
              #   nix build .#nixosConfigurations.rpi-image.config.system.build.sdImage
              #
              # Variant A (`rpi-image-nvmd`): upstream's sd-image module as is.
              # It imports nixpkgs' profiles/base.nix (rescue tools, zfs/btrfs/
              # cryptsetup...), i.e. a heavier system than `rpi`. Kept only to
              # measure that difference.
              rpi-image-nvmd = self.nixosConfigurations.rpi.extendModules {
                modules = [
                  nixos-raspberrypi.nixosModules.sd-image
                  {
                    sdImage = {
                      firmwarePartitionName = "NIXOS_BOOT";
                      firmwareSize = nixpkgs.lib.mkForce 256;
                    };
                  }
                ];
              };

              # Variant B (`rpi-image`): only nixpkgs' generic sd-image.nix plus
              # the same populate commands upstream uses, so the image system
              # is our system (no base profile).
              rpi-image = self.nixosConfigurations.rpi.extendModules {
                modules = [
                  ({ config, lib, modulesPath, ... }: {
                    imports = [ (modulesPath + "/installer/sd-card/sd-image.nix") ];
                    # same mount options as the installed `rpi` system
                    fileSystems."/boot/firmware".options = lib.mkForce [ "fmask=0077" "dmask=0077" ];
                    fileSystems."/".options = [ "noatime" ];
                    sdImage = {
                      # keep our labels (configuration.nix mounts by label)
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
                    image.baseName = "neptun-rpi3";
                  })
                ];
              };

              # x86_64 test configuration for the build-host module:
              #   nix build .#nixosConfigurations.rpiBuildHostTest.config.system.build.toplevel
              rpiBuildHostTest = hostTestSystem;
            };

            # Build-host modules: aarch64 emulation + rpi-deploy (see modules/).
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
              rpi-deploy = rpiDeploy system;
              default = rpiDeploy system;
            } // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
              # The binfmt_misc registration line (with the F flag) that
              # `rpi-deploy install` writes temporarily to
              # /proc/sys/fs/binfmt_misc/register while nixos-install runs.
              # Derived from the build-host module's own aarch64 registration
              # (static qemu), so it is what boot.binfmt.preferStaticEmulators
              # would set up permanently. Building it fetches that qemu.
              # The interpreter is referenced directly instead of through
              # /run/binfmt/<name>, so it needs no tmpfiles/systemd state.
              rpi-binfmt =
                let
                  r = hostTestSystem.config.boot.binfmt.registrations.aarch64-linux;
                  flags = nixpkgs.lib.optionalString r.preserveArgvZero "P"
                    + nixpkgs.lib.optionalString (r.openBinary && !r.matchCredentials) "O"
                    + nixpkgs.lib.optionalString r.matchCredentials "C"
                    + "F";
                in
                (pkgsFor system).writeText "rpi-binfmt-register"
                  ":rpi-deploy-aarch64:M:${toString r.offset}:${r.magicOrExtension}:${toString r.mask}:${r.interpreter}:${flags}";
            });

            checks = forSystem [ "aarch64-linux" "x86_64-linux" ] (system: {
              # bash syntax check of the wrapper script.
              # Note: the script must come in as `src`, not
              # `nativeBuildInputs` — stdenv *sources* every regular file in
              # nativeBuildInputs as a setup hook, which would execute the
              # script (with `$pkg -1 0` as positional args) before the check
              # even starts.
              rpi-deploy-syntax = (pkgsFor system).runCommand "rpi-deploy-syntax-check" {
                src = ./rpi-deploy.sh;
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
                  # Unit tests for the rpi-deploy script: runs the real
                  # script against mocked `nix`/`nixos-install`, so no real
                  # builds and no aarch64 emulation are needed. Covers the
                  # emulation preflight, build record round-trip, show,
                  # install verification, --from, attr mismatches,
                  # divergence warnings.
                  rpi-deploy-unit = x86Pkgs.runCommand "rpi-deploy-unit-check" {
                    scriptSrc = ./rpi-deploy.sh;
                    unitSrc = ./tests/deploy-unit.sh;
                    nativeBuildInputs = [ x86Pkgs.git ];
                  } ''
                    RPI_DEPLOY_SRC=$scriptSrc ${x86Pkgs.bash}/bin/bash $unitSrc
                    touch $out
                  '';

                  # Boots the build-host test system in a VM and verifies
                  # the module end-to-end: binfmt registration, nix aarch64
                  # support, the rpi-deploy wrapper, and that a real
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
                      # rpi-deploy is on PATH, runs, and is the RPI_FLAKE wrapper
                      host.succeed("command -v rpi-deploy >/dev/null")
                      host.succeed("rpi-deploy --help")
                      host.succeed("readlink -f $(command -v rpi-deploy) > /tmp/wrapper")
                      # /tmp/wrapper holds the resolved wrapper PATH (not its
                      # contents) — grep the file at that path
                      host.succeed("grep -qF RPI_FLAKE= $(cat /tmp/wrapper)")
                      host.succeed("grep -qF /tmp/rpi-nixos $(cat /tmp/wrapper)")
                      # an aarch64 binary actually runs via binfmt (the module's core job)
                      host.succeed("${aarch64Pkgs.hello}/bin/hello")
                      # the installed tool runs its dry-run flows end-to-end
                      host.succeed("mkdir -p /tmp/fake-flake && touch /tmp/fake-flake/flake.nix")
                      host.succeed("rpi-deploy build --dry-run --flake /tmp/fake-flake")
                      host.succeed("rpi-deploy show --flake /tmp/fake-flake | grep -q 'no build record'")
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
