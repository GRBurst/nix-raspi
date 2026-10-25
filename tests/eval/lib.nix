# Library entry point (spec §3, plan T2.1, D5–D7): lib.mkPi wraps nvmd's
# nixosSystem (hybrid inputs), the rpi.* modules and home-manager, and marks
# its result as a Pi host (`rpiHost`) for host discovery. Evaluated on the
# fixture host tests/fixtures/hosts/minimal.nix; never forces the toplevel.
{ lib, rpi, rpiLib, nixosModules, nixosConfigurations, fixtures, ... }:
let
  minimal = fixtures + "/hosts/minimal.nix";
  t = rpiLib.mkPi { modules = [ minimal ]; };
  cfg = t.config;
  withMarker = rpiLib.mkPi {
    modules = [ minimal ({ marker, ... }: { environment.etc.m.text = marker; }) ];
    specialArgs.marker = "x";
  };
  # N7: a consumer's specialArgs.inputs reach NixOS and Home Manager modules
  withInputs = (rpiLib.mkPi {
    modules = [ minimal ({ inputs, ... }: {
      environment.etc.n.text = inputs.mine;
      users.users.alice.isNormalUser = true;
      home-manager.users.alice = { inputs, ... }: {
        home.stateVersion = "26.05";
        home.file.n.text = inputs.mine;
      };
    }) ];
    specialArgs.inputs = { mine = "y"; };
  }).config;
in
{
  "mkPi returns a nixosSystem marked rpiHost" =
    (t.rpiHost or false) == true && t ? extendModules;

  # Hybrid inputs: the kernel stays nvmd's (cachix hit), as for `rpi`.
  "mkPi keeps nvmd's kernel (hybrid inputs)" =
    cfg.boot.kernelPackages.kernel.outPath == rpi.config.boot.kernelPackages.kernel.outPath;

  "mkPi passes specialArgs to modules" =
    withMarker.config.environment.etc.m.text == "x";

  "a consumer's specialArgs.inputs reach NixOS and Home Manager modules" =
    withInputs.environment.etc.n.text == "y"
    && withInputs.home-manager.users.alice.home.file.n.text == "y";

  "mkPi imports the rpi.* modules" =
    t.options.rpi ? headless && t.options.rpi ? pull && t.options.rpi ? sdWear;

  "home-manager is wired, no HM users by default" =
    t.options ? home-manager && cfg.home-manager.users == { };

  "nixosModules.default and .terminal exist" =
    nixosModules ? default && nixosModules ? terminal;

  # P7: host discovery (rpi-lib.sh RL_HOSTS_EXPR) finds neptun only; the
  # `rpi` alias (one release) is marked rpiHost = false.
  "Pi hosts: neptun only (rpi is an alias)" =
    lib.filter (n: (nixosConfigurations.${n}.rpiHost or false) == true)
      (lib.attrNames nixosConfigurations)
    == [ "neptun" ];
}
