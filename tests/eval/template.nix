# The consumer template (spec §3, §9 AC2; plan T5.1, D22, D25, P13): the real
# templates/default/flake.nix is evaluated with our flake as its `rpi` input,
# exactly what a consumer's flake does with the github: one. Its host must be
# a Pi host through lib.mkPi, default to DHCP / port 22 / Wi-Fi and Bluetooth
# off, and fail an assertion until the user adds a key. Never forces the
# toplevel.
{ lib, nixpkgs, rpiFlake, fixtures, ... }:
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

  # T5.2 helpers.
  declaredPsk = f: (fromTOML (builtins.readFile f)).profiles.default.RPI_WIFI_HOME;
  ignores = f: lib.elem "devenv.local.nix" (lib.splitString "\n" (builtins.readFile f));
  localExampleOk = f:
    let text = builtins.readFile f; in
    ((import f) { }).env ? RPI_HOST
    && lib.hasInfix "RPI_TARGET" text && lib.hasInfix "RPI_PORT" text;
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  devenvModule = f: (import f) { inherit pkgs; config.devenv.root = "/repo"; };
  devenvOk = f:
    let m = devenvModule f; names = map (p: p.pname or p.name) m.packages; in
    m.env.RPI_FLAKE == "/repo"
    && lib.elem "cachix" names && lib.elem "secretspec" names;
  templateDevenv = devenvModule ../../templates/default/devenv.nix;
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

  # --- T5.2: devenv and SecretSpec files, ours and the template's ----------
  # (spec §5; D21: PSKs only through `secretspec run -- rpi-deploy …`, never
  # through devenv's secretspec -> env.*, which would end up in the store)

  "secretspec.toml declares RPI_WIFI_HOME (optional), root and template" =
    lib.all (f: (declaredPsk f).required == false)
      [ ../../secretspec.toml ../../templates/default/secretspec.toml ];

  "devenv.local.nix is gitignored (root, template)" =
    lib.all ignores [ ../../.gitignore ../../templates/default/.gitignore ];

  "devenv.local.nix.example sets RPI_HOST and shows RPI_TARGET, RPI_PORT (root, template)" =
    lib.all localExampleOk
      [ ../../devenv.local.nix.example ../../templates/default/devenv.local.nix.example ];

  # devenv itself cannot run in the sandbox; the module is evaluated here
  # with a fake devenv config instead.
  "devenv.nix (root, template): RPI_FLAKE is the repo root, cachix and secretspec in the shell" =
    lib.all devenvOk [ ../../devenv.nix ../../templates/default/devenv.nix ];

  "template devenv.nix: rpi-deploy runs the locked library's rpi-deploy" =
    lib.hasInfix "#rpi-deploy" (templateDevenv.scripts.rpi-deploy.exec);

  "template devenv.yaml follows the Pi's release" =
    lib.hasInfix "github:NixOS/nixpkgs/nixos-26.05" (builtins.readFile ../../templates/default/devenv.yaml);
}
