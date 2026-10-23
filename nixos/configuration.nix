{
  config,
  pkgs,
  lib,
  ...
}: let
  keys = import ./keys.nix;
in {
  # Bootloader: provided by nixos-raspberrypi (nvmd), pulled in through
  # `nixosModules.raspberry-pi-3.base` in flake.nix. For the Pi 3 it is U-Boot
  # (default): the firmware partition (/boot/firmware: Pi firmware, config.txt,
  # u-boot-rpi-arm64.bin, DTBs) is populated by the bootloader installer at
  # nixos-install / switch time; kernel, initrd and extlinux.conf live in
  # /boot on the root filesystem. GRUB / generic-extlinux are not enabled here.
  # config.txt is generated from `hardware.raspberry-pi.config`, e.g.:
  #   hardware.raspberry-pi.config.all.dt-params.audio = { enable = true; value = "on"; };

  # !!! Needed for the virtual console to work on the RPi 3, as the default of 16M doesn't seem to be enough.
  # If X.org behaves weirdly (I only saw the cursor) then try increasing this to 256M.
  boot.kernelParams = ["cma=32M"];

  boot.kernel.sysctl = {
    "fs.inotify.max_user_watches" = "409600";
  };

  # boot.kernelPackages = pkgs.linuxPackages_latest;
  # boot.kernelPackages = pkgs.linuxPackages_4_14;  # fix wifi regression?
  # File systems configuration for using the installer's partition layout
  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/NIXOS_SD";
      fsType = "ext4";
    };
    # FAT firmware partition (label kept from the previous layout, so existing
    # cards need no re-partitioning). `rpi-deploy prepare` creates/mounts it at
    # <target>/boot/firmware during install.
    "/boot/firmware" = {
      device = "/dev/disk/by-label/NIXOS_BOOT";
      fsType = "vfat";
      options = ["fmask=0077" "dmask=0077"];
    };

    # "/external" = {
    #   device = "/dev/disk/by-uuid/e118cff8-0b67-4a3e-956e-d5a98744654e";
    #   fsType = "ext4";
    #   neededForBoot = true;
    # };
    # "/nix" = {
    #   device = "/external/nix";
    #   fsType = "none";
    #   options = ["bind"];
    # };
    # "/var" = {
    #   device = "/external/var";
    #   fsType = "none";
    #   options = ["bind"];
    # };
    # "/tmp" = {
    #   device = "/external/tmp";
    #   fsType = "none";
    #   options = ["bind"];
    # };
    # "/home" = {
    #   device = "/external/home";
    #   fsType = "none";
    #   options = ["bind"];
    # };
  };

  # swapDevices = [
  #   {
  #     device = "/external/swap";
  #     size = 10240;
  #   }
  # ];

  # Compressed in-RAM swap (512 MiB on the 1 GiB RPi 3). Gives autoUpgrade
  # builds and the nix daemon headroom without any SD-card writes.
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

    journald = {
      # nixos-26.05 (the nixpkgs pinned by nixos-raspberrypi) has no
      # journald.settings yet; that arrives in 26.11.
      storage = "volatile";
      extraConfig = ''
        Compress=yes
        SystemMaxUse=128M
        RuntimeMaxUse=8M
      '';
    };
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
  # auto-update key may only log in from the build host.
  users.users.root.openssh.authorizedKeys.keys =
    [keys.user]
    ++ lib.optional (keys.autoUpdate != null)
    ''from="${keys.hostAddress}" ${keys.autoUpdate}'';

  # NixOS requires the login shell to be an enabled shell program (see the
  # users.users.<name>.shell assertion); the actual zsh configuration comes
  # from the nix-terminal kit in the home-manager scope.
  programs.zsh.enable = true;

  system.stateVersion = "26.05";
}
