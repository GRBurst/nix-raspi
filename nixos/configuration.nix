{
  config,
  pkgs,
  lib,
  ...
}: let
  # keys.nix, overridable through _module.args.rpiKeys (eval tests)
  keys = config._module.args.rpiKeys;
in {
  _module.args.rpiKeys = lib.mkDefault (import ./keys.nix);

  # Bootloader: provided by nixos-raspberrypi (nvmd), pulled in through
  # `nixosModules.raspberry-pi-3.base` in flake.nix. For the Pi 3 it is U-Boot
  # (default): the firmware partition (/boot/firmware: Pi firmware, config.txt,
  # u-boot-rpi-arm64.bin, DTBs) is populated by the image build
  # (modules/sd-image.nix) and by the bootloader installer on every switch;
  # kernel, initrd and extlinux.conf live in /boot on the root filesystem.
  # No GRUB; nvmd enables generic-extlinux-compatible for extlinux.conf.
  # File systems (labels NIXOS_SD / NIXOS_BOOT) come from modules/sd-image.nix,
  # an optional USB data disk from modules/external-storage.nix.
  # config.txt is generated from `hardware.raspberry-pi.config`, e.g.:
  #   hardware.raspberry-pi.config.all.dt-params.audio = { enable = true; value = "on"; };

  boot.kernel.sysctl = {
    "fs.inotify.max_user_watches" = "409600";
  };

  # Kernel: nvmd's linuxPackages_rpi3 (cached in nixos-raspberrypi.cachix.org).
  # Do not override boot.kernelPackages (checks.x86_64-linux.eval-kernel).

  # Compressed in-RAM swap (512 MiB on the 1 GiB RPi 3). Gives the nix
  # daemon (receiving deploys) and dev tooling headroom without SD writes.
  # Remove this block if you prefer no swap at all.
  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  boot.tmp.cleanOnBoot = true;

  # Generations in the U-Boot menu (extlinux.conf on the SD root). nvmd's
  # uboot path runs generic-extlinux-compatible's populateCmd (`-g <limit>`);
  # boot.loader.raspberry-pi.configurationLimit is for the `kernel`
  # bootloader only.
  boot.loader.generic-extlinux-compatible.configurationLimit = 5;

  nix = {
    settings = {
      max-jobs = 3;
      cores = 3;
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 21d";
    };
    daemonIOSchedPriority = 7;
    # No channels: the Pi never evaluates its own config (pushed from the host).
    channel.enable = false;
  };
  # `nix shell nixpkgs#…` / <nixpkgs> on the Pi use the system's own nixpkgs
  # (already in the store, cache hits).
  nixpkgs.flake = {
    setFlakeRegistry = true;
    setNixPath = true;
  };

  security = {
    sudo = {
      enable = true;
      # pi has no password (key-only login, same trust as the root key)
      wheelNeedsPassword = false;
    };
  };
  nixpkgs.config.allowUnfree = true;

  services = {
    # nixosManual.enable = false;
    openssh = {
      enable = true;
      ports = [2222];
      settings = {
        PasswordAuthentication = false;
        # root: key-only; used by `rpi-deploy deploy` and rpi-autoupdate
        PermitRootLogin = "prohibit-password";
      };
      #  usePAM = false;
      # gatewayPorts = "clientspecified"; # bind ssh reverse tunnel to public interface https://superuser.com/a/591963
    };
    # sshd.usePAM = false;
    # journald (volatile, size limits): modules/sd-wear.nix (rpi.sdWear)
  };

  systemd.network.networks."10-lan-static" = {
    matchConfig = {
      Type = "ether"; # Matches ANY physical wired ethernet interface
    };
    networkConfig = {
      Address = "192.168.100.20/24";
      Gateway = "192.168.100.1";
    };
  };

  networking = {
    hostName = "neptun";
    useNetworkd = true;
    # networking.firewall.allowedUDPPortRanges = [ { from = 60000; to = 61000; } ]; # for mosh
  };

  i18n = {
    # consoleFont = "Lat2-Terminus16";
    defaultLocale = "en_US.UTF-8";
  };

  # Renamed from i18n.consoleKeyMap (26.11)
  console.keyMap = "neo";

  programs = {
    screen = {
      enable = true;
      screenrc = ''
        term screen-256color
        termcapinfo xterm*|xs|rxvt* ti@:te@
        startup_message off
        caption string '%{= G}[ %{G}%H %{g}][%= %{= w}%?%-Lw%?%{= R}%n*%f %t%?%{= R}(%u)%?%{= w}%+Lw%?%= %{= g}][ %{y}Load: %l %{g}][%{B}%Y-%m-%d %{W}%c:%s %{g}]'
        caption always
      '';
    };
  };

  time.timeZone = "Europe/Berlin";

  documentation.enable = false;
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

  users.users.pi = {
    isNormalUser = true;
    extraGroups = ["wheel" "docker" "video"];
    # zsh is provided by the nix-terminal kit (home-manager); make it the login shell
    shell = pkgs.zsh;
    openssh.authorizedKeys.keys = [keys.user];
  };

  # Push deploys log in as root (no sudo, no trusted-users needed). The
  # auto-update key may only log in from the build host, and `restrict`
  # drops forwarding and the pty (nix copy and systemd-run --pipe need
  # neither).
  users.users.root.openssh.authorizedKeys.keys =
    [keys.user]
    ++ lib.optional (keys.autoUpdate != null)
    ''from="${keys.hostAddress}",restrict ${keys.autoUpdate}'';

  # NixOS requires the login shell to be an enabled shell program (see the
  # users.users.<name>.shell assertion); the actual zsh configuration comes
  # from the nix-terminal kit in the home-manager scope.
  programs.zsh.enable = true;

  system.stateVersion = "26.05";
}
