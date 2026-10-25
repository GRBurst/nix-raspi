# Kept NixOS defaults for a small Pi (spec §4 "Kept as mkDefault"; plan D4).
# Every value is lib.mkDefault: a host sets the NixOS option directly to
# change it (checks.x86_64-linux.eval-defaults, "a host overrides every
# kept default").
{ lib, ... }:
let
  inherit (lib) mkDefault;
in
{
  networking.hostName = mkDefault "rpi";
  time.timeZone = mkDefault "UTC";
  i18n.defaultLocale = mkDefault "en_US.UTF-8";

  # systemd-networkd (modules/network.nix adds the static network; DHCP is
  # NixOS's default network for wired and wireless interfaces).
  networking.useNetworkd = mkDefault true;

  # Compressed in-RAM swap (512 MiB on the 1 GiB Pi 3): headroom for the nix
  # daemon (receiving deploys) without SD writes.
  zramSwap = {
    enable = mkDefault true;
    memoryPercent = mkDefault 50;
  };

  boot.tmp.cleanOnBoot = mkDefault true;

  # Generations in the U-Boot menu (extlinux.conf on the SD root). nvmd's
  # U-Boot path runs generic-extlinux-compatible's populateCmd (`-g <limit>`);
  # boot.loader.raspberry-pi.configurationLimit is for the `kernel`
  # bootloader only.
  boot.loader.generic-extlinux-compatible.configurationLimit = mkDefault 5;

  nix = {
    settings = {
      max-jobs = mkDefault 3;
      cores = mkDefault 3;
    };
    gc = {
      automatic = mkDefault true;
      dates = mkDefault "weekly";
      options = mkDefault "--delete-older-than 21d";
    };
    daemonIOSchedPriority = mkDefault 7;
    # No channels: the Pi never evaluates its own config (a host pushes it,
    # or CI builds it for rpi-pull).
    channel.enable = mkDefault false;
  };

  # `nix shell nixpkgs#…` / <nixpkgs> on the Pi use the system's own nixpkgs
  # (already in the store, cache hits).
  nixpkgs.flake = {
    setFlakeRegistry = mkDefault true;
    setNixPath = mkDefault true;
  };

  # nixpkgs evaluates `nixpkgs.config` as a module, so the inner mkDefault
  # keeps working (a host's plain `nixpkgs.config.allowUnfree` wins).
  nixpkgs.config.allowUnfree = mkDefault true;

  security.sudo = {
    enable = mkDefault true;
    # key-only login for the admin user: same trust as the root key
    wheelNeedsPassword = mkDefault false;
  };

  documentation.enable = mkDefault false;
}
