# Build-host module (spec §3.3 "Build-host module", §3.4): keeps aarch64
# emulation, the nvmd cache and rpi-deploy; drops the static-emulator /
# F-flag / chroot requirements and the rpi-binfmt package.
# Reads option values of the x86_64 test system only; never forces a
# toplevel.
{ lib, hostTestSystem, packages, ... }:
let
  cfg = hostTestSystem.config;
in
{
  # --- Task 6.1: cleanup ---
  "module does not force static emulators" = !cfg.boot.binfmt.preferStaticEmulators;

  "rpi-binfmt package removed" = !(packages.x86_64-linux ? rpi-binfmt);

  "aarch64 emulation and nvmd cache still configured" =
    cfg.boot.binfmt.emulatedSystems == [ "aarch64-linux" ]
    && lib.elem "https://nixos-raspberrypi.cachix.org" cfg.nix.settings.extra-substituters;

  "rpi-deploy on PATH" =
    lib.any (p: p.name == "rpi-deploy-flake-wrapper") cfg.environment.systemPackages;

  # Every flake evaluation forces this system (contract asserts), so an
  # unset stateVersion printed a warning on every nix command.
  "host test system sets system.stateVersion (no eval warning)" =
    hostTestSystem.options.system.stateVersion.highestPrio
    < (lib.mkOptionDefault { }).priority;

  # Spec addendum 2026-10-23 §3.5: the host no longer updates the Pi (CI
  # builds, the Pi pulls); rpi.buildHost.autoUpdate and its units are gone.
  "no autoUpdate option or units" =
    !(hostTestSystem.options.rpi.buildHost ? autoUpdate)
    && !(cfg.systemd.services ? rpi-autoupdate)
    && !(cfg.systemd.timers ? rpi-autoupdate);
}
