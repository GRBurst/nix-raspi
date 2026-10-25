# Pi configuration (spec §3.2) of our host neptun (`rpi` here is
# nixosConfigurations.neptun): deployment access, removals, boot/GC
# hygiene, neptun's own values. Reads option values only; never forces the
# toplevel.
{ lib, rpi, nixpkgs, ... }:
let
  cfg = rpi.config;
  # The user key used to come from keys.nix; the reusable library removed
  # keys.nix (spec §7), the key is now neptun's rpi.admin.sshKeys.
  userKeys = cfg.rpi.admin.sshKeys;
  rootKeys = cfg.users.users.root.openssh.authorizedKeys.keys;
  ssh = cfg.services.openssh.settings;
  # Values defined by neptun's host module itself (not by nixpkgs/nvmd or
  # library modules; formerly configuration.nix).
  confFile = toString ../../hosts/neptun/default.nix;
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

  "root has the user key" = userKeys != [ ] && lib.all (k: lib.elem k rootKeys) userKeys;

  # Spec §3.5: the host auto-update key is gone; the user key is the only
  # root key (manual `rpi-deploy deploy`).
  "root has exactly the user key" = lib.length userKeys == 1 && rootKeys == userKeys;

  # keys.nix (with its former auto-update key / host address) is retired
  # (spec §7); neptun has the one user key.
  "no keys.nix: no auto-update key or host address" =
    !builtins.pathExists ../../keys.nix && lib.length userKeys == 1;

  "pi has exactly the user key" =
    cfg.users.users.pi.openssh.authorizedKeys.keys == userKeys;

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

  # Scoped to hosts/neptun: nixpkgs' all-firmware.nix still adds
  # wireless-regdb while enableRedistributableFirmware is on (nvmd,
  # all-hardware.nix); modules/sd-wear.nix (rpi.sdWear) removes all firmware.
  "no wireless-regdb firmware from hosts/neptun" =
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

  "no stale journald limits in hosts/neptun" =
    !lib.hasInfix "SystemMaxUse=" journaldConf
    && !lib.hasInfix "RuntimeMaxUse=8M" journaldConf;

  # --- neptun's own values (plan T2.7, Global Constraints) ---
  "neptun: port 2222, static 192.168.100.20/24 via .1, Europe/Berlin, neo, terminal on, target root@neptun" =
    cfg.networking.hostName == "neptun"
    && cfg.rpi.ssh.port == 2222 && cfg.services.openssh.ports == [ 2222 ]
    && cfg.rpi.network.mode == "static"
    && cfg.rpi.network.static.address == "192.168.100.20/24"
    && cfg.rpi.network.static.gateway == "192.168.100.1"
    && cfg.systemd.network.networks."10-lan-static".networkConfig.Address == "192.168.100.20/24"
    && cfg.time.timeZone == "Europe/Berlin"
    && cfg.console.keyMap == "neo"
    && cfg.rpi.profiles.terminal.enable
    && cfg.rpi.deploy.target == "root@neptun";
}
