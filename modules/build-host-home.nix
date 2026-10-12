# Home Manager module: put `rpi-install` on the PATH of a build host.
#
# Use this when the build host is not NixOS-managed (or when you only want
# the script). On a NixOS host prefer `./build-host.nix`, which also enables
# aarch64 emulation. On non-NixOS hosts you must set up qemu/binfmt manually
# (e.g. `binfmt-support` on Debian/Ubuntu), otherwise cross builds fail.
#
# Import via the flake output (preferred — provides the rpi-install script):
#
#   inputs.pi = { url = "git+file:///home/pallon/projects/pi/nixos"; flake = true; };
#   ...
#   home-manager.users.alice = {
#     imports = [ inputs.pi.homeModules.rpiBuildHost ];
#     rpi.buildHost.enable = true;
#     rpi.buildHost.flakePath = "/home/alice/projects/pi/nixos";
#   };

{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.rpi.buildHost;

  scriptPackage =
    if cfg.flakePath != "" then
      pkgs.stdenv.mkDerivation {
        name = "rpi-install-flake-wrapper";
        dontUnpack = true;
        dontBuild = true;
        # The quoted heredoc terminator must land at column 0 after nix's
        # indentation stripping (see the unindented EOF below).
        installPhase = ''
          mkdir -p $out/bin
          cat > $out/bin/rpi-install <<'EOF'
          export RPI_FLAKE="${cfg.flakePath}"
          exec ${cfg.installScript}/bin/rpi-install "$@"
EOF
          chmod 755 $out/bin/rpi-install
        '';
      }
    else cfg.installScript;
in
{
  options.rpi.buildHost = {
    enable = lib.mkEnableOption "the rpi-install build host tooling";

    flakePath = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "/home/alice/projects/pi/nixos";
      description = ''
        If set, the installed `rpi-install` wrapper pre-sets `RPI_FLAKE` to
        this path, so `rpi-install build` / `rpi-install install` work without
        `--flake`.
      '';
    };

    installScript = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = ''
        The `rpi-install` script package to add to `home.packages`.
        Defaults to the package provided by the flake when the module is
        imported through the flake output.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = lib.optionals (cfg.installScript != null) [ scriptPackage ];
  };
}
