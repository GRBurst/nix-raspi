# Pi pull updates (rpi.pull.*): CI builds the system and publishes a pointer
# (nixos/deploy/neptun.json) plus the closure in our self-signed Cachix
# cache; a timer on the Pi runs `rpi-pull` (rpi-pull.sh), which verifies the
# pointer and activates the system. Spec addendum 2026-10-23 §3.1, §3.4.
#
# Enabled by default once pointerUrl, cacheUrl and cachePublicKey are set;
# configuration.nix sets the pointer URL and takes the cache from keys.nix
# (`cache = { name; publicKey; }`).
{
  config,
  lib,
  ...
}: let
  cfg = config.rpi.pull;
  url = lib.types.nullOr (lib.types.strMatching "https?://.+");
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
      example = "https://raw.githubusercontent.com/<owner>/<repo>/main/nixos/deploy/neptun.json";
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
      default = "04:30";
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

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.pointerUrl != null && cfg.cacheUrl != null && cfg.cachePublicKey != null;
        message = "rpi.pull.enable needs rpi.pull.pointerUrl, rpi.pull.cacheUrl and rpi.pull.cachePublicKey (keys.nix `cache`).";
      }
    ];
  };
}
