# Library defaults (spec §4, §7 "defaults"; plan T2.2–T2.6, P3): what a host
# gets without setting anything, and that a host can override every kept
# default with a plain definition. Evaluated on the fixture host
# tests/fixtures/hosts/minimal.nix through lib.mkPi; never forces the
# toplevel.
{ lib, rpiLib, fixtures, nixpkgs, ... }:
let
  minimal = fixtures + "/hosts/minimal.nix";
  mk = extra: rpiLib.mkPi { modules = [ minimal ] ++ extra; };
  t = mk [ ];
  cfg = t.config;
  gc = cfg.nix.gc;

  # P3: every kept default, read from a config...
  kept = sys: let c = sys.config; in {
    hostName = c.networking.hostName;
    timeZone = c.time.timeZone;
    locale = c.i18n.defaultLocale;
    zram = c.zramSwap.enable;
    zramPercent = c.zramSwap.memoryPercent;
    gcAutomatic = c.nix.gc.automatic;
    gcDates = c.nix.gc.dates;
    gcOptions = c.nix.gc.options;
    extlinuxLimit = c.boot.loader.generic-extlinux-compatible.configurationLimit;
    channels = c.nix.channel.enable;
    registry = c.nixpkgs.flake.setFlakeRegistry;
    nixPath = c.nixpkgs.flake.setNixPath;
    sudo = c.security.sudo.enable;
    wheelNeedsPassword = c.security.sudo.wheelNeedsPassword;
    documentation = c.documentation.enable;
    cleanTmp = c.boot.tmp.cleanOnBoot;
    maxJobs = c.nix.settings.max-jobs;
    cores = c.nix.settings.cores;
    ioPriority = c.nix.daemonIOSchedPriority;
    networkd = c.networking.useNetworkd;
    allowUnfree = sys.pkgs.config.allowUnfree;
  };
  # ...and a host that sets another value for each of them, plainly.
  wanted = {
    hostName = "garden";
    timeZone = "Europe/Paris";
    locale = "de_DE.UTF-8";
    zram = false;
    zramPercent = 25;
    gcAutomatic = false;
    gcDates = [ "daily" ];
    gcOptions = "--delete-older-than 7d";
    extlinuxLimit = 10;
    channels = true;
    registry = false;
    nixPath = false;
    sudo = false;
    wheelNeedsPassword = true;
    documentation = true;
    cleanTmp = false;
    maxJobs = 1;
    cores = 2;
    ioPriority = 4;
    networkd = false;
    allowUnfree = false;
  };
  overridden = mk [ {
    networking.hostName = wanted.hostName;
    time.timeZone = wanted.timeZone;
    i18n.defaultLocale = wanted.locale;
    zramSwap.enable = wanted.zram;
    zramSwap.memoryPercent = wanted.zramPercent;
    nix.gc.automatic = wanted.gcAutomatic;
    nix.gc.dates = "daily";
    nix.gc.options = wanted.gcOptions;
    boot.loader.generic-extlinux-compatible.configurationLimit = wanted.extlinuxLimit;
    nix.channel.enable = wanted.channels;
    nixpkgs.flake.setFlakeRegistry = wanted.registry;
    nixpkgs.flake.setNixPath = wanted.nixPath;
    security.sudo.enable = wanted.sudo;
    security.sudo.wheelNeedsPassword = wanted.wheelNeedsPassword;
    documentation.enable = wanted.documentation;
    boot.tmp.cleanOnBoot = wanted.cleanTmp;
    nix.settings.max-jobs = wanted.maxJobs;
    nix.settings.cores = wanted.cores;
    nix.daemonIOSchedPriority = wanted.ioPriority;
    networking.useNetworkd = wanted.networkd;
    nixpkgs.config.allowUnfree = wanted.allowUnfree;
  } ];
  # tryEval: a conflicting plain definition in the library prints the FAIL
  # line instead of aborting the whole check.
  vs = kept overridden;
in
{
  "hostname rpi, time zone UTC" =
    cfg.networking.hostName == "rpi" && cfg.system.name == "rpi" && cfg.time.timeZone == "UTC";

  "SSH on port 22" = cfg.services.openssh.ports == [ 22 ];

  "default network is DHCP" =
    cfg.rpi.network.mode == "dhcp" && !(cfg.systemd.network.networks ? "10-lan-static");

  "kept defaults" =
    cfg.zramSwap.enable && cfg.zramSwap.memoryPercent == 50
    && gc.automatic && gc.dates == [ "weekly" ] && gc.options == "--delete-older-than 21d"
    && cfg.boot.loader.generic-extlinux-compatible.configurationLimit == 5
    && cfg.nix.channel.enable == false
    && cfg.nixpkgs.flake.setFlakeRegistry && cfg.nixpkgs.flake.setNixPath
    && (cfg.nix.registry.nixpkgs.to.path or null) == nixpkgs.outPath
    && lib.elem "nixpkgs=flake:nixpkgs" cfg.nix.nixPath
    && cfg.security.sudo.enable && cfg.security.sudo.wheelNeedsPassword == false
    && cfg.documentation.enable == false
    && cfg.boot.tmp.cleanOnBoot
    && cfg.nix.settings.max-jobs == 3 && cfg.nix.settings.cores == 3
    && t.pkgs.config.allowUnfree
    && cfg.nix.daemonIOSchedPriority == 7
    && cfg.i18n.defaultLocale == "en_US.UTF-8"
    && cfg.networking.useNetworkd;

  "a host overrides every kept default" =
    (builtins.tryEval (builtins.deepSeq vs vs)).success && vs == wanted;

  "the SD image is named after the hostname" =
    cfg.image.fileName == "rpi-rpi3.img.zst"
    && overridden.config.image.fileName == "garden-rpi3.img.zst";
}
