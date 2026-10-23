# Pi configuration (spec §3.2): deployment access, removals, boot/GC
# hygiene. Reads option values only; never forces the toplevel.
{ lib, rpi, ... }:
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
in
{
  # --- access (Task 2.1) ---
  "root login is key-only" =
    ssh.PermitRootLogin == "prohibit-password" && ssh.PasswordAuthentication == false;

  "root has the user key" = lib.elem keys.user rootKeys;

  # P3: the user key is the only unrestricted root key.
  "every non-user root key is from= restricted" =
    lib.all (k: k == keys.user || lib.hasPrefix "from=\"" k) rootKeys;

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
}
