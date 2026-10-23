# Hybrid inputs (spec §3.1): userspace comes from our nixpkgs input, while
# kernel and firmware are nvmd's own packages (built from nvmd's nixpkgs
# pin, hence cache hits in nixos-raspberrypi.cachix.org). Any divergence of
# the kernel out path means a local kernel build.
{ lib, rpi, nvmd, nixpkgs, flakeLock, ... }:
let
  cfg = rpi.config;
  nvmdPkgs = nvmd.packages.aarch64-linux;

  # flake.lock: an input is a node name (string) when it has its own lock
  # node, and a path (list) when it `follows` another input.
  root = flakeLock.nodes.root.inputs;
  nvmdNode = root.nixos-raspberrypi;
  nvmdInputs = if lib.isString nvmdNode then flakeLock.nodes.${nvmdNode}.inputs else { };
  ours = root.nixpkgs or null;
  theirs = nvmdInputs.nixpkgs or null;
in
{
  "rpi kernel is nvmd's linuxPackages_rpi3 kernel (cachix hit)" =
    cfg.boot.kernelPackages.kernel.outPath == nvmdPkgs.linuxPackages_rpi3.kernel.outPath;

  "rpi kernel modules are nvmd's" =
    cfg.boot.kernelPackages.kernel.modules.outPath == nvmdPkgs.linuxPackages_rpi3.kernel.modules.outPath;

  "Pi firmware package is nvmd's raspberrypifw" =
    cfg.boot.loader.raspberry-pi.firmwarePackage.outPath == nvmdPkgs.raspberrypifw.outPath;

  "userspace nixpkgs is our own input" =
    toString rpi.pkgs.path == nixpkgs.outPath;

  "nixpkgs and nvmd's nixpkgs are separate lock nodes (no follows either way)" =
    lib.isString ours && lib.isString theirs && ours != theirs;
}
