# Pi configuration (spec §3.2): deployment access, removals, boot/GC
# hygiene. Reads option values only; never forces the toplevel.
{ lib, rpi, ... }:
let
  cfg = rpi.config;
  keys = import ../../keys.nix;
  rootKeys = cfg.users.users.root.openssh.authorizedKeys.keys;
  ssh = cfg.services.openssh.settings;
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
}
