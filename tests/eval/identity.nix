# rpi.admin / rpi.ssh / rpi.deploy (spec §4, plan T2.2): the admin user, key-
# only SSH for it and root, the deploy target. Evaluated on the fixture host
# tests/fixtures/hosts/minimal.nix through lib.mkPi; never forces the
# toplevel.
{ lib, rpiLib, fixtures, ... }:
let
  minimal = fixtures + "/hosts/minimal.nix";
  mk = extra: rpiLib.mkPi { modules = [ minimal ] ++ extra; };
  t = mk [ ];
  cfg = t.config;
  # failedAssertion SYSTEM NEEDLE: some assertion mentioning NEEDLE fails.
  failedAssertion = sys: s:
    lib.any (a: !a.assertion && lib.hasInfix s a.message) sys.config.assertions;

  keyOnly = u:
    u.isNormalUser && lib.elem "wheel" u.extraGroups
    && u.password == null && u.hashedPassword == null && u.hashedPasswordFile == null
    && u.initialPassword == null && u.initialHashedPassword == null;
  sshd = c: c.services.openssh;
  sshdKeyOnly = c:
    (sshd c).enable && (sshd c).ports == [ c.rpi.ssh.port ]
    && (sshd c).settings.PasswordAuthentication == false
    && (sshd c).settings.PermitRootLogin == "prohibit-password";

  port2200 = (mk [ { rpi.ssh.port = 2200; } ]).config;
  alice = (mk [ { rpi.admin.user = "alice"; } ]).config;
  noKey = rpiLib.mkPi { modules = [ { system.stateVersion = "26.05"; } ]; };
  garden = (mk [ { networking.hostName = "garden"; } ]).config;
  explicit = (mk [ { rpi.deploy.target = "admin@10.0.0.2"; } ]).config;
  portOk = t.options.rpi.ssh.port.type.check;
  userOk = t.options.rpi.admin.user.type.check;
in
{
  "admin user: normal, wheel, key-only" =
    cfg.rpi.admin.user == "pi"
    && keyOnly cfg.users.users.pi
    && cfg.users.users.pi.openssh.authorizedKeys.keys == cfg.rpi.admin.sshKeys;

  "root has exactly the admin keys" =
    cfg.users.users.root.openssh.authorizedKeys.keys == cfg.rpi.admin.sshKeys;

  "sshd: rpi.ssh.port only, no passwords, root prohibit-password" =
    cfg.rpi.ssh.port == 22 && sshdKeyOnly cfg
    && port2200.services.openssh.ports == [ 2200 ] && sshdKeyOnly port2200;

  "rpi.admin.user renames the admin" =
    keyOnly alice.users.users.alice
    && alice.users.users.alice.openssh.authorizedKeys.keys == alice.rpi.admin.sshKeys
    && !(alice.users.users ? pi);

  "empty rpi.admin.sshKeys fails an assertion naming the option" =
    failedAssertion noKey "rpi.admin.sshKeys is empty"
    && !(failedAssertion t "rpi.admin.sshKeys");

  "deploy target follows the hostname" =
    cfg.rpi.deploy.target == "root@rpi"
    && garden.rpi.deploy.target == "root@garden"
    && explicit.rpi.deploy.target == "admin@10.0.0.2";

  "rpi.ssh.port rejects 0 and 70000" =
    portOk 22 && portOk 2222 && portOk 65535 && !(portOk 0) && !(portOk 70000);

  "rpi.admin.user must be a login name" =
    userOk "pi" && userOk "alice_2" && !(lib.any userOk [ "Pi User" "" "1pi" "root;x" ]);
}
