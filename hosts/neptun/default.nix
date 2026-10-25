# neptun: our Raspberry Pi 3, a host of the library
# (nixosConfigurations.neptun = self.lib.mkPi { modules = [ ./hosts/neptun ]; }).
# Only neptun's own values live here; everything else (SSH, sudo, nix GC,
# zram, extlinux limit, channels, ...) comes from the rpi.* modules and
# their defaults (modules/, see README). Checked by
# checks.x86_64-linux.eval-pi-config.
#
# Bootloader: provided by nixos-raspberrypi (nvmd) through lib.mkPi
# (`nixosModules.raspberry-pi-3.base`). For the Pi 3 it is U-Boot (default):
# the firmware partition (/boot/firmware: Pi firmware, config.txt,
# u-boot-rpi-arm64.bin, DTBs) is populated by the image build
# (modules/sd-image.nix) and by the bootloader installer on every switch;
# kernel, initrd and extlinux.conf live in /boot on the root filesystem.
# No GRUB; nvmd enables generic-extlinux-compatible for extlinux.conf.
# File systems (labels NIXOS_SD / NIXOS_BOOT) come from modules/sd-image.nix,
# an optional USB data disk from modules/external-storage.nix.
# config.txt is generated from `hardware.raspberry-pi.config`, e.g.:
#   hardware.raspberry-pi.config.all.dt-params.audio = { enable = true; value = "on"; };
#
# Kernel: nvmd's linuxPackages_rpi3 (cached in nixos-raspberrypi.cachix.org).
# Do not override boot.kernelPackages (checks.x86_64-linux.eval-kernel).
{pkgs, ...}: {
  networking.hostName = "neptun";
  time.timeZone = "Europe/Berlin";
  # Renamed from i18n.consoleKeyMap (26.11)
  console.keyMap = "neo";

  # The admin user `pi` and root (push deploys) log in with this key only.
  rpi.admin.sshKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKxv8UiT62T7r81Z3h/L/7qhZZqVhF5ogXXthjhdAJVe pallon@andromeda->pi3 on 2026-10-18"
  ];
  rpi.ssh.port = 2222;
  # rpi-deploy's target: root@neptun (rpi.deploy.target default).

  rpi.network = {
    mode = "static";
    static = {
      address = "192.168.100.20/24";
      gateway = "192.168.100.1";
    };
  };

  # zsh + home-manager with the nix-terminal kit for `pi` (home.nix
  # overrides the profile's defaults).
  rpi.profiles.terminal.enable = true;
  home-manager.users.pi = import ./home.nix;

  # Pull updates (modules/pull-update.nix): CI builds this system weekly and
  # commits the pointer (deploy/neptun.json of the repo); rpi-pull applies
  # it. On once rpi.pull.cache is set (our self-signed Cachix cache, which
  # also becomes a substituter with its key):
  rpi.pull.cache = {
    name = "grburst-nix-raspi";
    publicKey = "grburst-nix-raspi.cachix.org-1:fZVFRpxdOsrA1W2BpRKM17ck1l2NH2sL2lZ0W1dIqpI=";
  };
  # Left unset (default null, pull off) rather than `cache = null`: an
  # explicit null would conflict with a module that sets a cache (the
  # refactor invariant's I2 does that via extendModules).
  rpi.pull.repo = "GRBurst/nix-raspi";

  boot.kernel.sysctl = {
    "fs.inotify.max_user_watches" = "409600";
  };

  programs.screen = {
    enable = true;
    screenrc = ''
      term screen-256color
      termcapinfo xterm*|xs|rxvt* ti@:te@
      startup_message off
      caption string '%{= G}[ %{G}%H %{g}][%= %{= w}%?%-Lw%?%{= R}%n*%f %t%?%{= R}(%u)%?%{= w}%+Lw%?%= %{= g}][ %{y}Load: %l %{g}][%{B}%Y-%m-%d %{W}%c:%s %{g}]'
      caption always
    '';
  };

  environment = {
    systemPackages = with pkgs; [
      neovim
    ];
    variables = {
      SUDO_EDITOR = "nvim";
      EDITOR = "nvim";
    };
  };

  # virtualisation.docker.enable = true;
  users.users.pi.extraGroups = ["docker" "video"];

  system.stateVersion = "26.05";
}
