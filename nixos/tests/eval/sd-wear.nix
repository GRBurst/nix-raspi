# modules/sd-wear.nix: SD-card write reduction (spec §3.2). Properties are
# asserted on the effects in the evaluated `rpi` (generated journald.conf,
# tmp mount unit, fstrim timer), not only on the option values.
{ lib, rpi, ... }:
let
  cfg = rpi.config;
  lines = s: lib.splitString "\n" s;
  sysctl = k: toString (cfg.boot.kernel.sysctl.${k} or "unset");
  journald = lines cfg.environment.etc."systemd/journald.conf".text;
  tmpMount = lib.findFirst (m: m.where == "/tmp") null cfg.systemd.mounts;
  mountOptions = if tmpMount == null then [ ] else lib.splitString "," tmpMount.mountConfig.Options;
  fsOptions = lib.concatMap (fs: fs.options) (lib.attrValues cfg.fileSystems);
  # tryEval: while the option is missing (RED) the evaluation throws; that
  # must surface as a FAIL line, not as an evaluation error.
  disabled = builtins.tryEval
    (rpi.extendModules { modules = [ { rpi.sdWear.enable = false; } ]; }).config.hardware.enableRedistributableFirmware;
in
{
  "sd-wear is enabled by default" = cfg.rpi.sdWear.enable or false;

  # hardware.firmware is a buildEnv (udev.nix `apply`); `.paths` is the list.
  "linux-firmware removed" =
    !cfg.hardware.enableRedistributableFirmware && cfg.hardware.firmware.paths == [ ];

  "disabling sd-wear restores firmware" =
    disabled.success && disabled.value;

  "root mounted noatime,lazytime,commit=60" =
    lib.all (o: lib.elem o cfg.fileSystems."/".options) [ "noatime" "lazytime" "commit=60" ];

  "no discard mount option anywhere" = !(lib.elem "discard" fsOptions);

  "/tmp is a 256M tmpfs" =
    tmpMount != null && tmpMount.type == "tmpfs" && lib.elem "size=256M" mountOptions;

  "fstrim monthly" =
    cfg.services.fstrim.enable && lib.last cfg.systemd.timers.fstrim.timerConfig.OnCalendar == "monthly";

  "journald volatile, 16M runtime, info level" =
    lib.all (l: lib.elem l journald) [ "Storage=volatile" "RuntimeMaxUse=16M" "MaxLevelStore=info" ];

  "journal upload off" = !cfg.services.journald.upload.enable;

  "no coredumps" = !cfg.systemd.coredump.enable;

  "keep-derivations off" = (cfg.nix.settings.keep-derivations or true) == false;

  "zram 50% with swappiness 100, page-cluster 0" =
    cfg.zramSwap.enable && cfg.zramSwap.memoryPercent == 50
    && sysctl "vm.swappiness" == "100"
    && sysctl "vm.page-cluster" == "0";

  # G8: rejected in s6 §5 (corruption risk / extra metadata writes)
  "no fsync-metadata=false, auto-optimise or optimise timer" =
    (cfg.nix.settings.fsync-metadata or true)
    && !(cfg.nix.settings.auto-optimise-store or false)
    && !cfg.nix.optimise.automatic;
}
