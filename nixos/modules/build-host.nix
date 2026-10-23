# NixOS module: turn this machine into a build host for the pi (aarch64).
#
# Import via the flake output (preferred — provides the rpi-deploy package:
# `rpi-deploy image/flash/deploy/status`):
#
#   inputs.pi = { url = "git+file:///home/pallon/projects/pi/nixos"; flake = true; };
#   ...
#   modules = [
#     inputs.pi.nixosModules.rpiBuildHost
#     {
#       rpi.buildHost.enable = true;
#       rpi.buildHost.flakePath = "/home/pallon/projects/pi/nixos";
#     }
#   ];
#
# What it configures:
#   - boot.binfmt.emulatedSystems = [ "aarch64-linux" ]
#     (qemu user-mode emulation; also wires up the nix sandbox paths so
#      cross builds work with `nix.settings.sandbox = true`)
#   - nix experimental features: nix-command, flakes
#   - nixos-raspberrypi binary cache (prebuilt vendor kernel), see nvmdCache
#   - environment.systemPackages += rpi-deploy (optionally wrapped so
#     RPI_FLAKE points at rpi.buildHost.flakePath)

{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.rpi.buildHost;

  # Optionally pre-set RPI_FLAKE so `rpi-deploy` works without --flake.
  # NOTE: the heredoc body must stay at column 0 — nix strips the MINIMAL
  # indentation of a long string, and a line at column 0 disables stripping
  # for the whole string. A shebang with leading spaces is not a shebang,
  # so the body (and only the body) sits at column 0.
  scriptPackage =
    if cfg.flakePath != "" then
      pkgs.stdenv.mkDerivation {
        name = "rpi-deploy-flake-wrapper";
        dontUnpack = true;
        dontBuild = true;
        installPhase = ''
          mkdir -p $out/bin
          cat > $out/bin/rpi-deploy <<'EOF'
#!/usr/bin/env bash
export RPI_FLAKE="${cfg.flakePath}"
exec ${cfg.installScript}/bin/rpi-deploy "$@"
EOF
          chmod 755 $out/bin/rpi-deploy
          # the package's other tools unchanged
          for f in ${cfg.installScript}/bin/*; do
            [ "$(basename "$f")" = rpi-deploy ] || ln -s "$f" $out/bin/
          done
        '';
      }
    else cfg.installScript;
in
{
  options.rpi.buildHost = {
    enable = lib.mkEnableOption "the aarch64 (Raspberry Pi) build host setup";

    flakePath = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "/home/alice/projects/pi/nixos";
      description = ''
        If set, the installed `rpi-deploy` wrapper pre-sets `RPI_FLAKE` to
        this path, so `rpi-deploy image` / `rpi-deploy deploy` work without
        `--flake` from any directory.
      '';
    };

    nvmdCache = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Add the nixos-raspberrypi binary cache (nixos-raspberrypi.cachix.org)
        to the nix substituters. It holds the prebuilt Raspberry Pi vendor
        kernel; without it the kernel is compiled locally under qemu (16+ h).
      '';
    };

    installScript = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = ''
        The `rpi-deploy` script package to add to `environment.systemPackages`.
        Defaults to the package provided by the flake when the module is
        imported through the flake output.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # qemu user-mode emulation for aarch64. The nixpkgs binfmt module also
    # adds the handler to `nix.settings.extra-sandbox-paths` and
    # `nix.settings.extra-platforms`, so aarch64 builds work in the nix
    # sandbox out of the box (no static emulator / F flag needed: nothing
    # runs in a chroot anymore).
    boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

    nix.settings = {
      experimental-features = lib.mkDefault [ "nix-command" "flakes" ];
    } // lib.optionalAttrs cfg.nvmdCache {
      extra-substituters = [ "https://nixos-raspberrypi.cachix.org" ];
      extra-trusted-public-keys = [
        "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
      ];
    };

    environment.systemPackages = lib.optionals (cfg.installScript != null) [ scriptPackage ];
  };
}
