# NixOS module: turn this machine into a build host for the pi (aarch64).
#
# Import via the flake output (preferred — provides the rpi-deploy package:
# `rpi-deploy image/flash/deploy/status` and the `rpi-autoupdate` job):
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
#     RPI_FLAKE points at rpi.buildHost.flakePath) and rpi-autoupdate
#   - optional weekly security updates of the Pi (rpi.buildHost.autoUpdate):
#     a systemd timer + oneshot service running rpi-autoupdate

{
  config,
  lib,
  pkgs,
  utils,
  ...
}: let
  cfg = config.rpi.buildHost;
  au = cfg.autoUpdate;

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
          # the package's other tools (rpi-autoupdate) unchanged
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

    # Weekly security updates of the Pi, pushed from this host (spec §3.4;
    # the job itself is rpi-autoupdate.sh).
    autoUpdate = {
      enable = lib.mkEnableOption ''
        weekly Pi security updates pushed from this host: a systemd timer runs
        `rpi-autoupdate` (lock update in a dedicated clone, cache and build
        guards, build, `nixos-rebuild boot`, then `switch` or a scheduled
        reboot, push of the lock to branch `auto-update` of `repoPath`)
      '';

      user = lib.mkOption {
        type = lib.types.str;
        example = "alice";
        description = ''
          User the job runs as. Owns `workDir`, can read `sshKey` and push to
          `repoPath`.
        '';
      };

      repoPath = lib.mkOption {
        type = lib.types.str;
        example = "/home/alice/projects/raspberry-pi";
        description = ''
          Root of the user's git repository (the flake is its `nixos/`
          directory). The job only reads branch `main` from it and pushes
          branch `auto-update` to it; the checkout itself is never touched.
        '';
      };

      workDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/rpi-autoupdate";
        description = ''
          State directory of the job (created for `user`, mode 0700): the
          dedicated work clone, the GC root of the last built system and the
          known_hosts file of the Pi (delete it after re-flashing the Pi).
        '';
      };

      target = lib.mkOption {
        type = lib.types.str;
        default = "root@neptun";
        description = "ssh target of the Pi (root: activation needs it).";
      };

      sshPort = lib.mkOption {
        type = lib.types.port;
        default = 2222;
        description = ''
          sshd port of the Pi. Passed explicitly: the service must not depend
          on an ssh_config entry.
        '';
      };

      sshKey = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/home/alice/.ssh/rpi-autoupdate";
        description = ''
          Absolute path of the dedicated private key the job logs in with
          (readable by `user`; its public key goes into the Pi's
          `nixos/keys.nix` as `autoUpdate`). Required when enabled. A string,
          not a path: the key must never be copied into the world-readable
          nix store.
        '';
      };

      onCalendar = lib.mkOption {
        type = lib.types.str;
        default = "Sun 03:00";
        description = "When the timer fires (systemd.time(7) calendar event).";
      };

      maxBuilds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 500;
        description = ''
          Build guard: refuse when the dry run lists more local builds.
        '';
      };

      rebootTime = lib.mkOption {
        type = lib.types.strMatching "[0-2][0-9]:[0-5][0-9]";
        default = "04:30";
        description = ''
          When the Pi reboots (`shutdown -r HH:MM`) after an update that
          changes the kernel, initrd or kernel modules.
        '';
      };
    };
  };

  config = lib.mkMerge [ (lib.mkIf cfg.enable {
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
  })

  (lib.mkIf au.enable {
    assertions =
      let
        absolute = name: value: {
          assertion = lib.hasPrefix "/" value;
          message = "rpi.buildHost.autoUpdate.${name} must be an absolute path (got '${value}').";
        };
      in
      [
        {
          assertion = cfg.enable;
          message = "rpi.buildHost.autoUpdate.enable needs rpi.buildHost.enable = true.";
        }
        {
          assertion = cfg.installScript != null;
          message = "rpi.buildHost.autoUpdate needs rpi.buildHost.installScript (import the module through the flake output).";
        }
        {
          assertion = au.sshKey != null;
          message = "rpi.buildHost.autoUpdate.sshKey must be set (path of the job's private key, e.g. ~/.ssh/rpi-autoupdate).";
        }
        (absolute "repoPath" au.repoPath)
        (absolute "workDir" au.workDir)
      ]
      ++ lib.optionals (au.sshKey != null) [
        (absolute "sshKey" au.sshKey)
        {
          assertion = !lib.hasPrefix builtins.storeDir au.sshKey;
          message = "rpi.buildHost.autoUpdate.sshKey must not be in the nix store (world-readable): ${au.sshKey}";
        }
      ];
  })

  (lib.mkIf (cfg.enable && au.enable) {
    systemd.timers.rpi-autoupdate = {
      description = "Weekly security update of the Raspberry Pi";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = au.onCalendar;
        # catch up after the host was off at the scheduled time
        Persistent = true;
        RandomizedDelaySec = "30m";
      };
    };

    systemd.services.rpi-autoupdate = {
      description = "Security update of the Raspberry Pi (lock update, guards, build, deploy)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [ config.nix.package pkgs.git pkgs.openssh pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        User = au.user;
        # rpi-autoupdate bounds the build itself to 4 h; the rest (lock
        # update, guards, copy to the Pi, activation) fits in the margin.
        TimeoutStartSec = "5h";
        ExecStart = "${cfg.installScript}/bin/rpi-autoupdate "
          + utils.escapeSystemdExecArgs [
            "--repo" au.repoPath
            "--work-dir" au.workDir
            "--target" au.target
            "--port" (toString au.sshPort)
            "--ssh-key" (toString au.sshKey)
            "--max-builds" (toString au.maxBuilds)
            "--reboot-time" au.rebootTime
          ];
      };
    };

    systemd.tmpfiles.rules = [ "d ${au.workDir} 0700 ${au.user} - -" ];
  })
  ];
}
