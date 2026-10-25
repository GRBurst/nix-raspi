# Who may log in, and how (spec §4): the admin user (rpi.admin.user, in
# wheel, key-only), root with the same keys (push deploys log in as root:
# no sudo, no trusted-users needed), sshd on rpi.ssh.port with password
# login off. rpi.deploy.target is read by rpi-deploy (with rpi.ssh.port).
# Always on: a Pi host without SSH access cannot be deployed to.
# Checked by checks.x86_64-linux.eval-identity.
{ config, lib, ... }:
let
  cfg = config.rpi;
in
{
  options.rpi = {
    admin.user = lib.mkOption {
      type = lib.types.strMatching "[a-z_][a-z0-9_-]*";
      default = "pi";
      description = "Login name of the admin user (normal user in `wheel`, SSH keys only, no password).";
    };

    admin.sshKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "ssh-ed25519 AAAA… you@laptop" ];
      description = ''
        SSH public keys of the admin user, also authorized for root (push
        deploys log in as root). Required: an empty list fails evaluation
        instead of building an image nobody can log in to.
      '';
    };

    ssh.port = lib.mkOption {
      type = lib.types.ints.between 1 65535;
      default = 22;
      description = "Port sshd listens on (the only one).";
    };

    deploy.target = lib.mkOption {
      type = lib.types.str;
      default = "root@${config.networking.hostName}";
      defaultText = lib.literalExpression ''"root@''${config.networking.hostName}"'';
      example = "root@192.0.2.20";
      description = ''
        SSH destination `rpi-deploy` deploys to (with `rpi.ssh.port`);
        `RPI_TARGET` / `--target` override it on the deploying machine.
      '';
    };
  };

  config = {
    assertions = [
      {
        assertion = cfg.admin.sshKeys != [ ];
        message = "rpi.admin.sshKeys is empty: add your SSH public key (the admin user and root log in with keys only, there is no password).";
      }
    ];

    users.users.${cfg.admin.user} = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = cfg.admin.sshKeys;
    };

    # Push deploys log in as root (no sudo, no trusted-users needed).
    users.users.root.openssh.authorizedKeys.keys = cfg.admin.sshKeys;

    services.openssh = {
      enable = true;
      ports = [ cfg.ssh.port ];
      settings = {
        PasswordAuthentication = false;
        # root: key-only; used by `rpi-deploy deploy`
        PermitRootLogin = "prohibit-password";
      };
    };
  };
}
