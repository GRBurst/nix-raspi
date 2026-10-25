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
  ci = pkgs.rpi-ci or { };
  ciInstall = ci.installPhase or "";
  ciShips = f: ci ? src && builtins.pathExists (ci.src + "/${f}");
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

  # rpi-lib.sh sources its fingerprint half from its own directory (D1)
  "rpi-deploy package ships rpi-fp.sh next to rpi-lib.sh" =
    lib.hasInfix "$out/libexec/rpi-deploy/rpi-fp.sh" install;

  "rpi-deploy wrapper points RPI_LIB at the packaged lib" =
    lib.hasInfix "--set RPI_LIB $out/libexec/rpi-deploy/rpi-lib.sh" install;

  # check_downgrade reads flake.lock with jq (review S4); flash needs
  # lsblk/findmnt (util-linux)
  "rpi-deploy wrapper PATH has jq and util-linux" =
    lib.hasInfix (binDir x86.jq) install
    && lib.hasInfix (binDir x86.util-linux) install;

  # rpi-ci (`nix run .#rpi-ci -- <cmd>`, `rpi#rpi-ci` in consumers): the
  # dispatcher and its scripts keep the repository layout under libexec, so
  # ci/*.sh find ../rpi-lib.sh and rpi-lib.sh finds rpi-fp.sh next to it.
  "rpi-ci package ships ci/*.sh, rpi-lib.sh and rpi-fp.sh" =
    lib.hasInfix "libexec/rpi-ci" ciInstall
    && lib.hasInfix "rpi-lib.sh" ciInstall
    && lib.hasInfix "rpi-fp.sh" ciInstall
    && lib.all ciShips [ "ci/rpi-ci.sh" "ci/hosts.sh" "ci/build.sh" "rpi-lib.sh" "rpi-fp.sh" ];

  "rpi-ci wraps cachix, jq and git on PATH" =
    lib.all (p: lib.hasInfix (binDir p) ciInstall) [ x86.cachix x86.jq x86.git ];
}
