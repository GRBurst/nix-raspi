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
    # "Hybrid" inputs (checked by checks.x86_64-linux.eval-kernel):
    # kernel + firmware come from nvmd's own nixpkgs pin (cached in its
    # cachix), userspace from our nixpkgs. Never add a follows either way;
    # out-of-tree kernel modules only from config.boot.kernelPackages.
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/develop";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    home-manager = {
      # master, not release-26.05: nix-terminal needs HM options that only
      # exist on master (programs.devenv). Master against our nixos-26.05
      # nixpkgs works; the release-mismatch warning is silenced in home.nix.
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

    # The host tool (image/flash/deploy/status) and the weekly job
    # (rpi-autoupdate, run by rpi.buildHost.autoUpdate) as a package: pure
    # shell, so it is usable on any build host. Explicit mkDerivation: the
    # writeShellScript* helpers' store-path shape varies between nixpkgs
    # versions, but $out/bin/<name> is what environment.systemPackages
    # (buildEnv) requires. The shared guard library goes to libexec and the
    # wrapper pins RPI_LIB to it.
    #
    # The tools the script calls are appended to PATH (suffix: the host's
    # own tools win), so it works on a host that has none of them in its
    # profile. nix and sudo are deliberately NOT bundled: they must be the
    # host's. nixos-rebuild is never the host's: the script runs the flake's
    # pinned app (apps.x86_64-linux.nixos-rebuild).
    mkRpiDeploy = pkgs: pkgs.stdenv.mkDerivation {
      name = "rpi-deploy";
      dontUnpack = true;
      dontBuild = true;
      nativeBuildInputs = [ pkgs.makeWrapper ];
      installPhase = ''
        mkdir -p $out/bin $out/libexec/rpi-deploy
        cp ${./rpi-deploy.sh} $out/bin/rpi-deploy
        cp ${./rpi-autoupdate.sh} $out/bin/rpi-autoupdate
        cp ${./rpi-lib.sh} $out/libexec/rpi-deploy/rpi-lib.sh
        for tool in rpi-deploy rpi-autoupdate; do
          chmod 755 $out/bin/$tool
          wrapProgram $out/bin/$tool \
            --set RPI_LIB $out/libexec/rpi-deploy/rpi-lib.sh \
            --suffix PATH : ${lib.makeBinPath (with pkgs; [
              util-linux coreutils zstd gnugrep gnused gawk git openssh
            ])}
        done
      '';
      meta.mainProgram = "rpi-deploy";
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
      # (the default without static emulators: extra-sandbox-paths)
      sandboxPaths =
        hostTestSystem.config.boot.binfmt.registrations.aarch64-linux.fixBinary
        || lib.any
          (p: lib.strings.hasInfix "qemu-aarch64" p || p == "/run/binfmt")
          hostTestSystem.config.nix.settings.extra-sandbox-paths;
      nvmdCache = lib.elem "https://nixos-raspberrypi.cachix.org"
        hostTestSystem.config.nix.settings.extra-substituters;
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
                # HYBRID: userspace from our nixpkgs; kernel/firmware stay
                # nvmd's packages (its own pin), see inputs.
                inherit nixpkgs;
                specialArgs = { inherit inputs; };
                modules = [
                  # Raspberry Pi 3 base: U-Boot, firmware, config.txt,
                  # vendor kernel (linuxPackages_rpi3)
                  nixos-raspberrypi.nixosModules.raspberry-pi-3.base

                  # The SD image is a build output of this very system
                  # (config.system.build.sdImage), see modules/sd-image.nix.
                  ./modules/sd-image.nix
                  # Pi modules (rpi.sdWear, rpi.headless: on by default;
                  # rpi.storage.external: off by default)
                  ./modules/sd-wear.nix
                  ./modules/headless.nix
                  ./modules/external-storage.nix

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

            # The deploy tool pinned to the Pi's release (spec "pinned
            # nixos-rebuild"): nixos-rebuild-ng from our nixpkgs, run with
            # --no-reexec by rpi-deploy. The host's own (newer) one half-
            # applies on the Pi (E3: systemd-run --output=cat).
            apps.x86_64-linux.nixos-rebuild = {
              type = "app";
              program = lib.getExe (pkgsFor "x86_64-linux").nixos-rebuild-ng;
              meta.description = "nixos-rebuild pinned to the Pi's release";
            };

            packages = forSystem [ "aarch64-linux" "x86_64-linux" ] (system: {
              rpi-deploy = rpiDeploy system;
              default = rpiDeploy system;
            } // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
              nixos-rebuild = (pkgsFor system).nixos-rebuild-ng;
            });

            # recursiveUpdate, not `//`: the x86_64-only checks below must be
            # merged into checks.x86_64-linux, not replace it (a shallow `//`
            # dropped rpi-deploy-syntax there).
            checks = lib.recursiveUpdate (forSystem [ "aarch64-linux" "x86_64-linux" ] (system: {
              # bash syntax + shellcheck (warnings and up) of the host
              # scripts; shellcheck follows rpi-deploy.sh's `source` of the
              # lib (-x), so the lib's globals count as assigned there.
              # Note: the scripts must come in as `src`, not
              # `nativeBuildInputs` — stdenv *sources* every regular file in
              # nativeBuildInputs as a setup hook, which would execute the
              # script (with `$pkg -1 0` as positional args) before the check
              # even starts.
              rpi-deploy-syntax = (pkgsFor system).runCommand "rpi-deploy-syntax-check" {
                src = lib.fileset.toSource {
                  root = ./.;
                  fileset = lib.fileset.unions [ ./rpi-deploy.sh ./rpi-autoupdate.sh ./rpi-lib.sh ];
                };
                nativeBuildInputs = [ (pkgsFor system).shellcheck ];
              } ''
                cd $src
                for f in rpi-deploy.sh rpi-autoupdate.sh rpi-lib.sh; do
                  ${(pkgsFor system).bash}/bin/bash -n $f
                done
                shellcheck -x -S warning rpi-deploy.sh rpi-autoupdate.sh rpi-lib.sh
                touch $out
              '';
            }))
            (
              # x86_64-only checks (the build host is x86_64).
              let
                x86Pkgs = pkgsFor "x86_64-linux";
                aarch64Pkgs = pkgsFor "aarch64-linux";
              in {
                x86_64-linux = {
                  # Unit tests for rpi-deploy.sh + rpi-lib.sh: the real
                  # scripts against mocked nix/ssh/sudo/lsblk/findmnt/dd/
                  # nixos-rebuild (real git, zstd, coreutils), plus guard
                  # parsing on real `nix build --dry-run` fixtures. No real
                  # builds, no network, no devices (flash writes to temp
                  # files only). util-linux is deliberately absent: lsblk
                  # and findmnt must be the mocks.
                  rpi-deploy-unit = x86Pkgs.runCommand "rpi-deploy-unit-check" {
                    src = lib.fileset.toSource {
                      root = ./.;
                      fileset = lib.fileset.unions [
                        ./rpi-deploy.sh
                        ./rpi-lib.sh
                        ./tests/harness.sh
                        ./tests/deploy-unit.sh
                        ./tests/fixtures
                      ];
                    };
                    nativeBuildInputs = with x86Pkgs; [ git zstd gnugrep gnused gawk ];
                  } ''
                    RPI_DEPLOY_SRC=$src/rpi-deploy.sh RPI_LIB=$src/rpi-lib.sh FIXTURES=$src/tests/fixtures \
                      ${x86Pkgs.bash}/bin/bash $src/tests/deploy-unit.sh
                    touch $out
                  '';

                  # Unit tests for rpi-autoupdate.sh (the weekly job): the
                  # real script + lib against mocked nix/ssh/timeout/
                  # nixos-rebuild and real git on throwaway repositories
                  # (lock flow, cache fallback, guards, boot -> switch or
                  # scheduled reboot, push to auto-update, the user's
                  # checkout left alone). No network, no real Pi.
                  autoupdate-unit = x86Pkgs.runCommand "autoupdate-unit-check" {
                    src = lib.fileset.toSource {
                      root = ./.;
                      fileset = lib.fileset.unions [
                        ./rpi-autoupdate.sh
                        ./rpi-lib.sh
                        ./tests/harness.sh
                        ./tests/autoupdate-unit.sh
                        ./tests/fixtures
                      ];
                    };
                    nativeBuildInputs = with x86Pkgs; [ git gnugrep gnused gawk findutils ];
                  } ''
                    RPI_AUTOUPDATE_SRC=$src/rpi-autoupdate.sh RPI_LIB=$src/rpi-lib.sh FIXTURES=$src/tests/fixtures \
                      ${x86Pkgs.bash}/bin/bash $src/tests/autoupdate-unit.sh
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
                      # the installed tool is the image/flash/deploy/status CLI
                      host.succeed("rpi-deploy --help | grep -q 'flash IMAGE DEVICE'")
                      host.fail("rpi-deploy install")
                    '';
                  };
                }
                # Eval-level checks: one check `eval-<name>` per
                # tests/eval/<name>.nix (auto-discovered, see
                # tests/eval/default.nix for the file contract).
                // import ./tests/eval {
                  inherit lib;
                  pkgs = x86Pkgs;
                  args = {
                    inherit lib nixpkgs hostTestSystem;
                    rpi = self.nixosConfigurations.rpi;
                    nvmd = nixos-raspberrypi;
                    nixosConfigurations = self.nixosConfigurations;
                    packages = self.packages;
                    apps = self.apps or { };
                    flakeLock = lib.importJSON ./flake.lock;
                  };
                };
              }
            );
  }
  else
    builtins.unreachable
;
}
