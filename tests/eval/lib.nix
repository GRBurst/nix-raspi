# Library entry point (spec §3, plan T2.1, D5–D7): lib.mkPi wraps nvmd's
# nixosSystem (hybrid inputs), the rpi.* modules and home-manager, and marks
# its result as a Pi host (`rpiHost`) for host discovery. Evaluated on the
# fixture host tests/fixtures/hosts/minimal.nix; never forces the toplevel.
{ lib, rpi, rpiLib, nixosModules, fixtures, ... }:
let
  minimal = fixtures + "/hosts/minimal.nix";
  t = rpiLib.mkPi { modules = [ minimal ]; };
  cfg = t.config;
  withMarker = rpiLib.mkPi {
    modules = [ minimal ({ marker, ... }: { environment.etc.m.text = marker; }) ];
    specialArgs.marker = "x";
  };
in
{
  "mkPi returns a nixosSystem marked rpiHost" =
    (t.rpiHost or false) == true && t ? extendModules;

  # Hybrid inputs: the kernel stays nvmd's (cachix hit), as for `rpi`.
  "mkPi keeps nvmd's kernel (hybrid inputs)" =
    cfg.boot.kernelPackages.kernel.outPath == rpi.config.boot.kernelPackages.kernel.outPath;

  "mkPi passes specialArgs to modules" =
    withMarker.config.environment.etc.m.text == "x";

  "mkPi imports the rpi.* modules" =
    t.options.rpi ? headless && t.options.rpi ? pull && t.options.rpi ? sdWear;

  "home-manager is wired, no HM users by default" =
    t.options ? home-manager && cfg.home-manager.users == { };

  "nixosModules.default and .terminal exist" =
    nixosModules ? default && nixosModules ? terminal;
}
