{
  config,
  pkgs,
  lib,
  ...
}: {
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

  nix = {
    settings = {
      max-jobs = 3;
      cores = 3;
    };
    gc = {
      automatic = true;
      dates = "monthly";
      options = "--delete-older-than 7d";
    };
    daemonIOSchedPriority = 7;
  };

  system.autoUpgrade.enable = true;
  system.autoUpgrade.dates = "03:30";

  security = {
    sudo = {
      enable = true;
      wheelNeedsPassword = true;
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
        PermitRootLogin = "no";
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

  # https://github.com/NixOS/nixpkgs/issues/82462#issuecomment-604634627
  systemd.services.iwd.serviceConfig.Restart = "always";
  systemd.network.networks."10-lan-static" = {
    matchConfig = {
      Type = "ether"; # Matches ANY physical wired ethernet interface
    };
    networkConfig = {
      Address = "192.168.100.20/24";
      Gateway = "192.168.100.1";
    };
  };
  hardware.enableRedistributableFirmware = true;
  hardware.firmware = [pkgs.wireless-regdb];
  boot = {
    extraModprobeConfig = ''
      options cf680211 ieee80211_regdom="DE"
    '';
  };

  networking = {
    hostName = "neptun";
    useNetworkd = true;
    # networking.firewall.allowedUDPPortRanges = [ { from = 60000; to = 61000; } ]; # for mosh
    wireless = {
      enable = false;
      userControlled = true;
      secretsFile = "/etc/nixos/secrets/wireless.env";
      networks = {
        "Pfefferoni" = {
          psk = "@MY_WIFI_PASSWORD@";
        };
      };
    };
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
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKxv8UiT62T7r81Z3h/L/7qhZZqVhF5ogXXthjhdAJVe pallon@andromeda->pi3 on 2026-10-18"
    ];
  };

  # NixOS requires the login shell to be an enabled shell program (see the
  # users.users.<name>.shell assertion); the actual zsh configuration comes
  # from the nix-terminal kit in the home-manager scope.
  programs.zsh.enable = true;

  system.stateVersion = "26.05";
}
