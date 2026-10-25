# The consumer template (spec §3, §9 AC2; plan T5.1, D22, D25, P13): the real
# templates/default/flake.nix is evaluated with our flake as its `rpi` input,
# exactly what a consumer's flake does with the github: one. Its host must be
# a Pi host through lib.mkPi, default to DHCP / port 22 / Wi-Fi and Bluetooth
# off, and fail an assertion until the user adds a key. Never forces the
# toplevel.
{ lib, rpiFlake, fixtures, ... }:
let
  ours = import ../../flake.nix;
  tf = import ../../templates/default/flake.nix;
  tpl = tf.outputs { self = tpl; rpi = rpiFlake; };
  h = tpl.nixosConfigurations.rpi;
  hk = h.extendModules { modules = [ (fixtures + "/hosts/minimal.nix") ]; };
  cfg = h.config;

  # failedAssertion SYSTEM NEEDLE: some assertion mentioning NEEDLE fails.
  failedAssertion = sys: s:
    lib.any (a: !a.assertion && lib.hasInfix s a.message) sys.config.assertions;
in
{
  "template input is rpi = github:GRBurst/nix-raspi" =
    lib.attrNames tf.inputs == [ "rpi" ]
    && tf.inputs.rpi.url == "github:GRBurst/nix-raspi";

  # Same cache config as ours, so the kernel comes from the nvmd cache for a
  # consumer who accepts the flake config.
  "template nixConfig equals ours (nvmd cache)" =
    tf.nixConfig == ours.nixConfig
    && lib.elem "https://nixos-raspberrypi.cachix.org" tf.nixConfig.extra-substituters;

  "template host is a Pi host through lib.mkPi" =
    (h.rpiHost or false) == true && h ? extendModules
    && h.options.rpi ? headless
    && lib.attrNames tpl.nixosConfigurations == [ "rpi" ];

  "template default: DHCP, port 22, Wi-Fi and Bluetooth off, hostname rpi, pull off" =
    cfg.rpi.ssh.port == 22
    && cfg.services.openssh.ports == [ cfg.rpi.ssh.port ]
    && cfg.rpi.network.mode == "dhcp"
    && !cfg.rpi.wifi.enable && !cfg.rpi.bluetooth.enable
    && cfg.networking.hostName == "rpi"
    && !hk.config.rpi.pull.enable;

  "with a key, no failed assertion" =
    lib.all (a: a.assertion) hk.config.assertions;

  "without a key the sshKeys assertion fires" =
    cfg.rpi.admin.sshKeys == [ ]
    && failedAssertion h "rpi.admin.sshKeys is empty";

  "template re-exports apps and packages of rpi" =
    lib.attrNames tpl.packages == lib.attrNames rpiFlake.packages
    && tpl.packages.x86_64-linux.rpi-deploy.outPath == rpiFlake.packages.x86_64-linux.rpi-deploy.outPath
    && tpl.packages.x86_64-linux.rpi-ci.outPath == rpiFlake.packages.x86_64-linux.rpi-ci.outPath
    && tpl.apps == rpiFlake.apps;

  "templates.default points at templates/default with a description" =
    rpiFlake.templates.default.path == ../../templates/default
    && lib.isString rpiFlake.templates.default.description
    && rpiFlake.templates.default.description != "";
}
