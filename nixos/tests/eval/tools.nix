# Host tools (spec §3.3, plan D7): the deploy tool is the nixos-rebuild of
# the flake's own nixpkgs (the Pi's release), exposed as an app, and the
# rpi-deploy package ships the shared guard library. (Whether the installed
# wrapper really finds the lib is covered by the rpi-host-vm test; a
# derivation's contents are not visible at eval time.)
{ lib, nixpkgs, packages, apps, ... }:
let
  nr = nixpkgs.legacyPackages.x86_64-linux.nixos-rebuild-ng;
  app = (apps.x86_64-linux or { }).nixos-rebuild or { };
  pkgs = packages.x86_64-linux;
  x86 = nixpkgs.legacyPackages.x86_64-linux;
  binDir = p: builtins.unsafeDiscardStringContext "${lib.getBin p}/bin";
  install = pkgs.rpi-deploy.installPhase or "";
in
{
  "apps.x86_64-linux.nixos-rebuild is the flake's 26.05 nixos-rebuild-ng" =
    (app.type or null) == "app"
    && (app.program or null) == lib.getExe nr
    && lib.hasPrefix "26.05" nr.version;

  "packages.x86_64-linux.nixos-rebuild exists" =
    pkgs ? nixos-rebuild && pkgs.nixos-rebuild.outPath == nr.outPath;

  "rpi-deploy package ships rpi-lib.sh" =
    lib.hasInfix "rpi-lib.sh" install;

  "rpi-deploy wrapper points RPI_LIB at the packaged lib" =
    lib.hasInfix "--set RPI_LIB $out/libexec/rpi-deploy/rpi-lib.sh" install;

  # check_downgrade reads flake.lock with jq (review S4); flash needs
  # lsblk/findmnt (util-linux)
  "rpi-deploy wrapper PATH has jq and util-linux" =
    lib.hasInfix (binDir x86.jq) install
    && lib.hasInfix (binDir x86.util-linux) install;
}
