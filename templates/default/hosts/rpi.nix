# Your Raspberry Pi 3. The library (lib.mkPi in ../flake.nix) supplies the
# NixOS base, the SD image, key-only SSH and sensible defaults; this file
# holds only your values. Every NixOS option stays settable here, and the
# `rpi.*` options below are the Pi-specific ones. Defaults shown in comments:
# uncomment and change what you need. Full table: README of nix-raspi,
# "Configuration".
{ ... }:
{
  # REQUIRED: your SSH public key(s) (`cat ~/.ssh/id_ed25519.pub`). The admin
  # user and root (push deploys) log in with these keys only; there is no
  # password. Evaluation fails with "rpi.admin.sshKeys is empty" until you
  # add one. Public keys are not secret: commit them.
  rpi.admin.sshKeys = [
    # "ssh-ed25519 AAAA… you@laptop"
  ];

  # Identity (NixOS options, defaults "rpi" / "UTC" / "en_US.UTF-8" / "us"):
  # networking.hostName = "rpi";
  # time.timeZone = "Europe/Berlin";
  # i18n.defaultLocale = "en_US.UTF-8";
  # console.keyMap = "us";

  # Admin user and SSH:
  # rpi.admin.user = "pi";   # normal user in wheel (passwordless sudo)
  # rpi.ssh.port = 22;       # sshd port; rpi-deploy reads it from here

  # Network: DHCP on any wired interface by default. A fixed address:
  # rpi.network = {
  #   mode = "static";
  #   static = { address = "192.168.1.20/24"; gateway = "192.168.1.1"; dns = [ "192.168.1.1" ]; };
  # };

  # Radios are off by default (the chips stay powered down).
  # Wi-Fi: PSKs never go into the Nix store. They come from the environment
  # of `rpi-deploy flash --wifi-env` / `rpi-deploy secrets` (see README).
  # rpi.wifi = {
  #   enable = true;
  #   networks = { "My SSID" = "RPI_WIFI_HOME"; };   # SSID -> PSK variable
  # };
  # rpi.bluetooth.enable = true;

  # Headless Pi (gpu_mem 16, no audio/camera/display): on by default.
  # rpi.headless.enable = false;

  # Pull updates: CI builds this host weekly, pushes the closure to your
  # Cachix cache and commits deploy/<hostname>.json; the Pi applies it.
  # Needs both the repo and the cache (README, "Updates").
  # rpi.pull.repo = "<you>/<this-repo>";
  # rpi.pull.cache = { name = "<cache>"; publicKey = "<cache>.cachix.org-1:…"; };

  # Packages and anything else: plain NixOS.
  # environment.systemPackages = with pkgs; [ screen ];   # add `pkgs` to the arguments

  # The NixOS release this Pi was first installed with. Do not change it
  # when you upgrade nixpkgs.
  system.stateVersion = "26.05";
}
