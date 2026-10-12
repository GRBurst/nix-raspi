{
  config,
  pkgs,
  lib,
  ...
}: {
  # NixOS wants to enable GRUB by default
  boot.loader.grub.enable = false;
  # Enables the generation of /boot/extlinux/extlinux.conf
  boot.loader.generic-extlinux-compatible.enable = true;

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
    "/boot" = {
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
  boot.cleanTmpDir = true;

  nix.maxJobs = 3;
  nix.buildCores = 3;

  nix.gc.automatic = true;
  nix.gc.dates = "monthly";
  nix.gc.options = "--delete-older-than 7d";
  nix.daemonIONiceLevel = 7;
  system.autoUpgrade.enable = true;
  system.autoUpgrade.dates = "03:30";

  security = {
    sudo = {
      enable = true;
      wheelNeedsPassword = true;
    };
  };
  nixpkgs.config.allowUnfree = true;

  # networking.firewall.allowedUDPPortRanges = [ { from = 60000; to = 61000; } ]; # for mosh

  services = {
    # nixosManual.enable = false;
    openssh = {
      enable = true;
      ports = [2222];
      passwordAuthentication = false;
      permitRootLogin = "no";
      #  usePAM = false;
      # gatewayPorts = "clientspecified"; # bind ssh reverse tunnel to public interface https://superuser.com/a/591963
    };
    # sshd.usePAM = false;

    journald = {
      settings.Journal = {
        Storage = "volatile";
        Compress = "yes";
        SystemMaxUse = "128M";
        RuntimeMaxUse = "8M";
      };
      # extraConfig = ''
      #   Storage=volatile
      #   Compress=yes
      #   SystemMaxUse=128M
      #   RuntimeMaxUse=8M
      # '';
    };
  };

  networking.hostName = "neptun";

  # https://github.com/NixOS/nixpkgs/issues/82462#issuecomment-604634627
  systemd.services.iwd.serviceConfig.Restart = "always";
  hardware.enableRedistributableFirmware = true;
  hardware.firmware = [pkgs.wireless-regdb];
  boot = {
    extraModprobeConfig = ''
      options cf680211 ieee80211_regdom="DE"
    '';
  };

  networking.wireless = {
    enable = true;
    userControlled.enable = true;

    secretsFile = "/etc/nixos/secrets/wireless.env";
    networks = {
      "Pfefferoni" = {
        psk = "@MY_WIFI_PASSWORD@";
      };
    };
  };

  i18n = {
    # consoleFont = "Lat2-Terminus16";
    consoleKeyMap = "neo";
    defaultLocale = "en_US.UTF-8";
  };

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
    ];
  };

  # NixOS requires the login shell to be an enabled shell program (see the
  # users.users.<name>.shell assertion); the actual zsh configuration comes
  # from the nix-terminal kit in the home-manager scope.
  programs.zsh.enable = true;

  system.stateVersion = "26.05";
}
