# Pi configuration (spec §3.2): deployment access, removals, boot/GC
# hygiene. Reads option values only; never forces the toplevel.
{ lib, rpi, nixpkgs, ... }:
let
  cfg = rpi.config;
  keys = import ../../keys.nix;
  rootKeys = cfg.users.users.root.openssh.authorizedKeys.keys;
  ssh = cfg.services.openssh.settings;
  # Values defined by configuration.nix itself (not by nixpkgs/nvmd modules).
  confFile = toString ../../configuration.nix;
  definedInConf = opt:
    lib.concatMap (d: lib.toList d.value)
    (lib.filter (d: d.file == confFile) opt.definitionsWithLocations);
  extlinux = cfg.boot.loader.generic-extlinux-compatible;
  limit = 5;
  gc = cfg.nix.gc;
  nixPath = cfg.nix.nixPath;
  journaldConf = cfg.environment.etc."systemd/journald.conf".text;
in
{
  # --- access (Task 2.1) ---
  "root login is key-only" =
    ssh.PermitRootLogin == "prohibit-password" && ssh.PasswordAuthentication == false;

  "root has the user key" = lib.elem keys.user rootKeys;

  # P3: the user key is the only unrestricted root key.
  "every non-user root key is from= restricted" =
    lib.all (k: k == keys.user || lib.hasPrefix "from=\"" k) rootKeys;

  # N3: with an auto-update key set (keys.nix has none yet), the key line
  # is from=-limited and `restrict`ed (no forwarding, no pty).
  "auto-update key line is from=...,restrict" =
    let
      withKey = rpi.extendModules {
        modules = [ {
          _module.args.rpiKeys = keys // {
            autoUpdate = "ssh-ed25519 AAAAtest rpi-autoupdate";
            hostAddress = "192.0.2.1";
          };
        } ];
      };
      r = builtins.tryEval withKey.config.users.users.root.openssh.authorizedKeys.keys;
    in
    r.success && r.value == [ keys.user ''from="192.0.2.1",restrict ssh-ed25519 AAAAtest rpi-autoupdate'' ];

  "an auto-update key needs hostAddress" =
    keys.autoUpdate == null || keys.hostAddress != null;

  "pi has exactly the user key" =
    cfg.users.users.pi.openssh.authorizedKeys.keys == [ keys.user ];

  "wheel needs no sudo password" = !cfg.security.sudo.wheelNeedsPassword;

  "no trusted-users change" = cfg.nix.settings.trusted-users == [ "root" ];

  # --- removals: no on-Pi update, no wifi, no secrets (Task 2.2) ---
  "autoUpgrade is off" = !cfg.system.autoUpgrade.enable;

  "wifi is off and has no networks or secrets file" =
    !cfg.networking.wireless.enable
    && cfg.networking.wireless.networks == { }
    && cfg.networking.wireless.secretsFile == null;

  "no iwd override" = !(cfg.systemd.services ? iwd);

  # (the old line misspelled the module as cf680211)
  "no cfg80211 modprobe line" =
    !(lib.hasInfix "cf680211" cfg.boot.extraModprobeConfig
      || lib.hasInfix "cfg80211" cfg.boot.extraModprobeConfig);

  # Scoped to configuration.nix: nixpkgs' all-firmware.nix still adds
  # wireless-regdb while enableRedistributableFirmware is on (nvmd,
  # all-hardware.nix); modules/sd-wear.nix (rpi.sdWear) removes all firmware.
  "no wireless-regdb firmware from configuration.nix" =
    !lib.any (p: lib.hasInfix "wireless-regdb" p.name)
      (definedInConf rpi.options.hardware.firmware);

  # --- boot/GC hygiene (Task 2.3) ---
  # P4: the effect, not just the value. nvmd's U-Boot path runs
  # generic-extlinux-compatible's populateCmd; the raspberry-pi
  # configurationLimit is "Used only by `kernel` bootloader!".
  "extlinux keeps 5 generations (populateCmd -g 5)" =
    extlinux.configurationLimit == limit
    && lib.hasInfix "-g ${toString limit} " extlinux.populateCmd;

  "nix gc weekly, older than 21d" =
    gc.automatic && gc.dates == [ "weekly" ] && gc.options == "--delete-older-than 21d";

  "channels off" =
    !cfg.nix.channel.enable && !lib.any (lib.hasInfix "channels") nixPath;

  "flake registry and NIX_PATH point at system nixpkgs" =
    cfg.nixpkgs.flake.setFlakeRegistry && cfg.nixpkgs.flake.setNixPath
    && (cfg.nix.registry.nixpkgs.to.path or null) == nixpkgs.outPath
    && lib.elem "nixpkgs=flake:nixpkgs" nixPath;

  # --- dead/duplicate config (Task 2.4); journald belongs to rpi.sdWear ---
  "no cma=32M kernel parameter" = !lib.elem "cma=32M" cfg.boot.kernelParams;

  "no stale journald limits in configuration.nix" =
    !lib.hasInfix "SystemMaxUse=" journaldConf
    && !lib.hasInfix "RuntimeMaxUse=8M" journaldConf;
}
