# Pi pull updates (rpi.pull.*): CI builds the system and publishes a pointer
# (deploy/<host>.json) plus the closure in our self-signed Cachix
# cache; a timer on the Pi runs `rpi-pull` (rpi-pull.sh), which verifies the
# pointer and activates the system. Spec addendum 2026-10-23 §3.1, §3.4.
#
# Enabled by default once pointerUrl, cacheUrl and cachePublicKey are set;
# configuration.nix sets the pointer URL and takes the cache from keys.nix
# (`cache = { name; publicKey; }`).
{
  config,
  lib,
  pkgs,
  utils,
  ...
}: let
  cfg = config.rpi.pull;
  url = lib.types.nullOr (lib.types.strMatching "https?://.+");
  stateDir = "/var/lib/rpi-pull";

  settings = {
    inherit (cfg) pointerUrl cacheUrl cachePublicKey;
  };
  unset = lib.attrNames (lib.filterAttrs (_: v: v == null) settings);
  partial = unset != [ ] && unset != lib.attrNames settings;

  # rpi-pull plus the fingerprint library it sources (D1); the Pi carries
  # no other host script.
  rpiPull = pkgs.stdenvNoCC.mkDerivation {
    name = "rpi-pull";
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    installPhase = ''
      install -Dm755 ${../rpi-pull.sh} $out/bin/rpi-pull
      install -Dm644 ${../rpi-fp.sh} $out/libexec/rpi-pull/rpi-fp.sh
      wrapProgram $out/bin/rpi-pull \
        --set RPI_FP_LIB $out/libexec/rpi-pull/rpi-fp.sh \
        --prefix PATH : ${lib.makeBinPath [
          config.nix.package
          pkgs.curl
          pkgs.jq
          pkgs.coreutils
          pkgs.util-linux
          config.systemd.package
          pkgs.gnugrep
        ]}
    '';
  };
in {
  options.rpi.pull = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.pointerUrl != null && cfg.cacheUrl != null && cfg.cachePublicKey != null;
      defaultText = lib.literalMD "`true` once `pointerUrl`, `cacheUrl` and `cachePublicKey` are set";
      description = "Whether to apply the system CI publishes (rpi-pull timer).";
    };

    pointerUrl = lib.mkOption {
      type = url;
      default = null;
      example = "https://raw.githubusercontent.com/<owner>/<repo>/main/deploy/<host>.json";
      description = ''
        URL of the pointer file CI commits (`{ seq, storePath, narHash, rev,
        built }`). Use HTTPS; plain HTTP (tests) adds a warning.
      '';
    };

    cacheUrl = lib.mkOption {
      type = url;
      default = null;
      example = "https://<cache>.cachix.org";
      description = "Our binary cache; added to `nix.settings.substituters`.";
    };

    cachePublicKey = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "[^:]+:[A-Za-z0-9+/]{43}=");
      default = null;
      example = "<cache>.cachix.org-1:<43 base64 characters>=";
      description = ''
        Public key of our cache. The pointed-to system must be signed by this
        key (and only this one is accepted for it); also added to
        `nix.settings.trusted-public-keys`.
      '';
    };

    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 05:00";
      description = ''
        When to look for a new pointer (systemd calendar event). Daily: a run
        without a new pointer is one HTTP request.
      '';
    };

    rebootTime = lib.mkOption {
      type = lib.types.strMatching "([01][0-9]|2[0-3]):[0-5][0-9]";
      default = "06:30";
      description = ''
        When to reboot (`shutdown -r HH:MM`, the next such time) after
        activating a system whose boot files changed.
      '';
    };

    maxAgeDays = lib.mkOption {
      type = lib.types.ints.between 1 9999;
      default = 21;
      description = ''
        A pointer built more than this many days ago fails the unit (exit
        39): CI has stalled.
      '';
    };
  };

  config = lib.mkMerge [
    {
      # A10: a partial setup would leave rpi.pull silently off.
      warnings = lib.optional (partial && !cfg.enable)
        "rpi.pull stays disabled: ${lib.concatMapStringsSep ", " (n: "rpi.pull.${n}") unset} not set (keys.nix `cache` gives cacheUrl and cachePublicKey).";
    }

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = unset == [ ];
          message = "rpi.pull.enable needs rpi.pull.pointerUrl, rpi.pull.cacheUrl and rpi.pull.cachePublicKey (keys.nix `cache`).";
        }
      ];
    })

    # Only a complete setup gets units: enabling an incomplete one fails the
    # assertion above, not with an evaluation error on a null argument.
    (lib.mkIf (cfg.enable && unset == [ ]) {
      # D9: http only for the qemu smoke test.
      warnings = lib.optional (lib.hasPrefix "http://" cfg.pointerUrl)
        "rpi.pull.pointerUrl uses plain HTTP: the pointer is not authenticated (use HTTPS outside tests)";

      system.build.rpiPull = rpiPull;

      # cache.nixos.org (nixpkgs, mkAfter) and nvmd's cache stay.
      nix.settings.substituters = [ cfg.cacheUrl ];
      nix.settings.trusted-public-keys = [ cfg.cachePublicKey ];

      systemd.timers.rpi-pull = {
        description = "Daily check for a new system published by CI";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.onCalendar;
          Persistent = true;
          RandomizedDelaySec = "30m";
        };
      };

      # Persistent catch-up may fire at boot, before NTP (no RTC), and
      # time-sync.target alone is reached once timesyncd has started, synced
      # or not. systemd-time-wait-sync waits for the kernel clock to be
      # synchronized; installed but not enabled, so only rpi-pull waits for
      # it (boot never does), and bounded: without NTP for 30 min it fails
      # and rpi-pull runs anyway, as before (final review N1).
      systemd.additionalUpstreamSystemUnits = [ "systemd-time-wait-sync.service" ];
      systemd.services.systemd-time-wait-sync.serviceConfig.TimeoutStartSec = "30min";

      systemd.services.rpi-pull = {
        description = "Apply the system CI published for this Pi (rpi-pull)";
        after = [ "network-online.target" "time-sync.target" "systemd-time-wait-sync.service" ];
        wants = [ "network-online.target" "time-sync.target" "systemd-time-wait-sync.service" ];
        # D15: switch-to-configuration runs inside this unit; a switch that
        # changes the unit must neither restart nor stop it.
        restartIfChanged = false;
        unitConfig.X-StopOnRemoval = false;
        environment.HOME = "/root";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${rpiPull}/bin/rpi-pull "
            + utils.escapeSystemdExecArgs [
              "--pointer-url" cfg.pointerUrl
              "--cache-url" cfg.cacheUrl
              "--cache-key" cfg.cachePublicKey
              "--host" config.system.name
              "--reboot-time" cfg.rebootTime
              "--max-age-days" (toString cfg.maxAgeDays)
              "--state-dir" stateDir
            ];
          StateDirectory = "rpi-pull";
          # ~2x the measured worst case (s8: 180 MB with 2 substitution jobs)
          MemoryMax = "384M";
          Nice = 19;
          IOSchedulingClass = "idle";
          CPUSchedulingPolicy = "idle";
          TimeoutStartSec = "2h";
        };
      };
    })
  ];
}
