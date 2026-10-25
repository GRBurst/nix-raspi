# External USB data disk (spec §3.2, modules/external-storage.nix): disabled by
# default and then a strict no-op; when enabled, the SD card keeps `/` and
# `/boot/firmware` and `/external` plus the bind mounts come from the disk.
# Options and their effects are read from evaluated NixOS configurations; the
# toplevel is never forced (no aarch64 build, no IFD).
{ lib, rpi, ... }:
let
  base = rpi.config;
  # The disabled variant, spelled out (P8): must equal `rpi` itself.
  off = rpi.extendModules { modules = [ { rpi.storage.external.enable = false; } ]; };

  # Enabled variant with a swapfile (defaults otherwise).
  on = rpi.extendModules {
    modules = [ { rpi.storage.external = { enable = true; swapSize = 1024; }; } ];
  };
  onCfg = on.config;
  ext = onCfg.rpi.storage.external;

  # A missing mount yields false properties (informative RED), not eval errors.
  at = c: m: c.fileSystems.${m} or { };
  deviceOf = c: m: (at c m).device or null;
  optionsOf = c: m: (at c m).options or [ ];
  dependsOf = c: m: (at c m).depends or [ ];
  sorted = lib.sort (a: b: a < b);
  # Mount order nixpkgs generates for fstab / initrd (sorted by fsBefore).
  order = c: map (f: f.mountPoint) c.system.build.fileSystems;
  indexOf = x: xs:
    let hits = lib.filter (i: lib.elemAt xs i == x) (lib.range 0 (lib.length xs - 1));
    in if hits == [ ] then lib.length xs else lib.head hits;

  # Enabled with the all-hardware module set switched off (it currently
  # supplies the USB storage drivers to the initrd, see D12).
  bare = (rpi.extendModules {
    modules = [ { rpi.storage.external.enable = true; hardware.enableAllHardware = lib.mkForce false; } ];
  }).config;

  # Non-default values: properties must follow the options, not the literals.
  custom = (rpi.extendModules {
    modules = [ { rpi.storage.external = {
      enable = true; label = "USB_DATA"; fsType = "xfs"; bind = [ "/var" "/srv" ];
    }; } ];
  }).config;

  # Messages of this module's failed assertions for a given `bind`.
  bindFailures = binds:
    let
      c = (rpi.extendModules {
        modules = [ { rpi.storage.external = { enable = true; bind = binds; }; } ];
      }).config;
    in lib.filter (lib.hasPrefix "rpi.storage.external.bind")
      (map (a: a.message) (lib.filter (a: !a.assertion) c.assertions));
  # Binds over an existing SD mount (/, /boot/firmware) already abort the
  # evaluation with a conflicting-definition error before the assertions are
  # read; that is a rejection as well.
  bindRejected = b:
    let r = builtins.tryEval (builtins.deepSeq (bindFailures [ b ]) (bindFailures [ b ]));
    in !r.success || r.value != [ ];

  # Option types reject the value (tryEval catches the module system's throw).
  rejected = def:
    !(builtins.tryEval (builtins.deepSeq
      (rpi.extendModules { modules = [ { rpi.storage.external = def; } ]; })
        .config.rpi.storage.external true)).success;
in
{
  "external storage is off by default" =
    base.rpi.storage.external.enable == false;

  "disabled module adds no mounts or swap" =
    lib.attrNames base.fileSystems == lib.attrNames off.config.fileSystems
    && base.swapDevices == off.config.swapDevices
    && !(base.fileSystems ? "/external")
    && !(lib.any (s: lib.hasPrefix "/external" s.device) base.swapDevices)
    && !(lib.any (f: f.fsType == "none") (lib.attrValues base.fileSystems));

  "options default to PI_DATA / ext4 / [/nix /var /home] / no swap" =
    let d = base.rpi.storage.external; in
    d.label == "PI_DATA" && d.fsType == "ext4"
    && d.bind == [ "/nix" "/var" "/home" ] && d.swapSize == null;

  "/external is by-label PI_DATA, ext4, neededForBoot" =
    deviceOf onCfg "/external" == "/dev/disk/by-label/PI_DATA"
    && (at onCfg "/external").fsType or null == "ext4"
    && (at onCfg "/external").neededForBoot or false;

  "each bind entry is bind-mounted from /external after /external" =
    ext.bind != [ ]
    && lib.all
      (b: deviceOf onCfg b == "/external${b}"
        && (at onCfg b).fsType or null == "none"
        && lib.elem "bind" (optionsOf onCfg b)
        && lib.elem "/external" (dependsOf onCfg b)
        && indexOf "/external" (order onCfg) < indexOf b (order onCfg))
      ext.bind;

  "no nofail on /external or bind mounts" =
    onCfg.fileSystems ? "/external"
    && lib.all (m: !(lib.elem "nofail" (optionsOf onCfg m))) ([ "/external" ] ++ ext.bind);

  "SD keeps / and /boot/firmware" =
    deviceOf onCfg "/" == base.fileSystems."/".device
    && optionsOf onCfg "/" == base.fileSystems."/".options
    && deviceOf onCfg "/boot/firmware" == base.fileSystems."/boot/firmware".device
    && optionsOf onCfg "/boot/firmware" == base.fileSystems."/boot/firmware".options
    && !(onCfg.fileSystems ? "/boot")
    # exactly /external and the bind entries are new, nothing else moved
    && sorted (lib.attrNames onCfg.fileSystems)
       == sorted (lib.unique (lib.attrNames base.fileSystems ++ [ "/external" ] ++ ext.bind));

  "/nix bind depends on /external, which is neededForBoot" =
    lib.elem "/nix" ext.bind
    && lib.elem "/external" (dependsOf onCfg "/nix")
    && (at onCfg "/external").neededForBoot or false;

  "fstab binds each entry after /external, without nofail" =
    let
      lines = lib.splitString "\n" onCfg.environment.etc."fstab".text;
      lineFor = b: lib.filter (l: lib.hasPrefix "/external${b} ${b} none " l) lines;
      opts = l: lib.splitString "," (lib.elemAt (lib.splitString " " l) 3);
    in
    lib.all
      (b: lib.length (lineFor b) == 1
        && lib.elem "bind" (opts (lib.head (lineFor b)))
        && lib.any (o: lib.hasPrefix "x-systemd.requires-mounts-for=" o && lib.hasSuffix "/external" o)
             (opts (lib.head (lineFor b))))
      ext.bind
    && !(lib.hasInfix "nofail" onCfg.environment.etc."fstab".text);

  "USB storage drivers are in the initrd (the disk is needed for boot)" =
    !bare.hardware.enableAllHardware
    && lib.all (m: lib.elem m bare.boot.initrd.availableKernelModules) [ "usb_storage" "uas" ];

  "swapfile of swapSize MiB on /external" =
    ext.swapSize == 1024
    && lib.elem { device = "/external/swapfile"; size = 1024; }
         (map (s: { inherit (s) device size; }) onCfg.swapDevices)
    && base.swapDevices == [ ];

  "label, fsType and bind follow the options" =
    deviceOf custom "/external" == "/dev/disk/by-label/USB_DATA"
    && (at custom "/external").fsType or null == "xfs"
    && deviceOf custom "/srv" == "/external/srv"
    && deviceOf custom "/var" == "/external/var"
    && !(custom.fileSystems ? "/nix") && !(custom.fileSystems ? "/home");

  "bind on /boot is rejected by an assertion" =
    lib.all (b: bindFailures [ b ] != [ ])
      [ "/boot" "/boot/extlinux" "/external/x" "var" ]
    && lib.all bindRejected [ "/" "/boot/firmware" "/external" ]
    && bindFailures [ "/nix" "/var" "/home" ] == [ ];

  "label and swapSize types reject invalid values" =
    rejected { enable = true; swapSize = 0; }
    && rejected { enable = true; swapSize = "1G"; }
    && rejected { enable = true; label = "has space"; }
    && rejected { enable = true; label = "WAY_TOO_LONG_LABEL_X"; };
}
