# Build-host module (spec §3.3 "Build-host module", §3.4): keeps aarch64
# emulation, the nvmd cache and rpi-deploy; drops the static-emulator /
# F-flag / chroot requirements and the rpi-binfmt package.
# Reads option values of the x86_64 test system only; never forces a
# toplevel.
{ lib, hostTestSystem, packages, ... }:
let
  cfg = hostTestSystem.config;

  # The autoUpdate example from the plan (T6.2), on top of the test system.
  enabled = {
    users.users.alice.isNormalUser = true;
    rpi.buildHost.autoUpdate = {
      enable = true;
      user = "alice";
      repoPath = "/home/alice/rpi";
      sshKey = "/var/lib/rpi-autoupdate/id_ed25519";
    };
  };
  extend = modules: hostTestSystem.extendModules { inherit modules; };
  au = extend [ enabled ];
  auCfg = au.config;
  svc = auCfg.systemd.services.rpi-autoupdate or { };
  sc = svc.serviceConfig or { };
  timer = auCfg.systemd.timers.rpi-autoupdate or { };
  tc = timer.timerConfig or { };
  exec = sc.ExecStart or "";
  # Quoting as systemd parses ExecStart (the module must use the same).
  esc = au._module.args.utils.escapeSystemdExecArgs;
  # (string context discarded: lib.hasInfix rejects store-path context)
  noCtx = builtins.unsafeDiscardStringContext;
  passes = flag: value: lib.hasInfix (noCtx (esc [ flag value ])) (noCtx exec);

  # failedAssertion SYSTEM NEEDLE: some assertion mentioning NEEDLE fails.
  failedAssertion = sys: needle:
    lib.any (a: !a.assertion && lib.hasInfix needle a.message) sys.config.assertions;
in
{
  # --- Task 6.1: cleanup ---
  "module does not force static emulators" = !cfg.boot.binfmt.preferStaticEmulators;

  "rpi-binfmt package removed" = !(packages.x86_64-linux ? rpi-binfmt);

  "aarch64 emulation and nvmd cache still configured" =
    cfg.boot.binfmt.emulatedSystems == [ "aarch64-linux" ]
    && lib.elem "https://nixos-raspberrypi.cachix.org" cfg.nix.settings.extra-substituters;

  "rpi-deploy on PATH" =
    lib.any (p: p.name == "rpi-deploy-flake-wrapper") cfg.environment.systemPackages;

  # Every flake evaluation forces this system (contract asserts), so an
  # unset stateVersion printed a warning on every nix command.
  "host test system sets system.stateVersion (no eval warning)" =
    hostTestSystem.options.system.stateVersion.highestPrio
    < (lib.mkOptionDefault { }).priority;

  # --- Task 6.2: rpi.buildHost.autoUpdate ---
  "autoupdate is off by default" =
    !(cfg.systemd.services ? rpi-autoupdate) && !(cfg.systemd.timers ? rpi-autoupdate);

  "defaults: target root@neptun, port 2222, weekly Sun 03:00, 500 builds, reboot 04:30" =
    let o = auCfg.rpi.buildHost.autoUpdate; in
    o.target == "root@neptun" && o.sshPort == 2222 && o.onCalendar == "Sun 03:00"
    && o.maxBuilds == 500 && o.rebootTime == "04:30"
    && o.workDir == "/var/lib/rpi-autoupdate";

  "timer Sun 03:00, Persistent, 30m jitter, in timers.target" =
    (tc.OnCalendar or null) == "Sun 03:00"
    && (tc.Persistent or null) == true
    && (tc.RandomizedDelaySec or null) == "30m"
    && lib.elem "timers.target" (timer.wantedBy or [ ]);

  "timer is Persistent" = (tc.Persistent or null) == true;

  "service is a oneshot as the configured user" =
    (sc.Type or null) == "oneshot" && (sc.User or null) == "alice";

  "service waits for the network" =
    lib.elem "network-online.target" (svc.after or [ ])
    && lib.elem "network-online.target" (svc.wants or [ ]);

  "service start timeout exceeds the 4h build timeout" = (sc.TimeoutStartSec or null) == "5h";

  "service runs the packaged rpi-autoupdate" =
    lib.hasInfix "/bin/rpi-autoupdate " exec
    && lib.hasPrefix (toString auCfg.rpi.buildHost.installScript) exec;

  # P13
  "ExecStart passes every option" =
    let o = auCfg.rpi.buildHost.autoUpdate; in
    lib.all (fv: passes (lib.elemAt fv 0) (lib.elemAt fv 1)) [
      [ "--repo" o.repoPath ]
      [ "--work-dir" o.workDir ]
      [ "--target" o.target ]
      [ "--port" (toString o.sshPort) ]
      [ "--ssh-key" o.sshKey ]
      [ "--max-builds" (toString o.maxBuilds) ]
      [ "--reboot-time" o.rebootTime ]
    ];

  # The key path goes into ExecStart verbatim: a store copy would make the
  # private key world-readable.
  "sshKey is not copied into the store" =
    let
      # (a store copy carries string context, which builtins.match rejects)
      m = builtins.match ".*\"--ssh-key\" \"([^\"]*)\".*" (noCtx exec);
    in
    m != null && !(lib.hasPrefix builtins.storeDir (lib.head m))
    && lib.head m == "/var/lib/rpi-autoupdate/id_ed25519";

  "workDir is created for the user" =
    lib.elem "d /var/lib/rpi-autoupdate 0700 alice - -" auCfg.systemd.tmpfiles.rules;

  "store-path sshKey is rejected" =
    failedAssertion (extend [ enabled { rpi.buildHost.autoUpdate.sshKey = lib.mkForce "/nix/store/x-key"; } ]) "sshKey";

  "sshKey defaults to null and is required when enabled" =
    auCfg.rpi.buildHost.autoUpdate.sshKey != null
    && cfg.rpi.buildHost.autoUpdate.sshKey == null
    && failedAssertion (extend [ enabled { rpi.buildHost.autoUpdate.sshKey = lib.mkForce null; } ]) "sshKey";

  "relative paths are rejected" =
    failedAssertion (extend [ enabled { rpi.buildHost.autoUpdate.repoPath = lib.mkForce "rpi"; } ]) "repoPath"
    && failedAssertion (extend [ enabled { rpi.buildHost.autoUpdate.workDir = lib.mkForce "work"; } ]) "workDir";

  "autoUpdate without rpi.buildHost.enable is rejected" =
    failedAssertion (extend [ enabled { rpi.buildHost.enable = lib.mkForce false; } ]) "rpi.buildHost.enable";

  "no assertion fails for the valid example" =
    lib.all (a: a.assertion) auCfg.assertions;

  # N1 (review): shutdown -r accepts 00:00-23:59 only
  "rebootTime accepts 00:00-23:59 only" =
    let check = hostTestSystem.options.rpi.buildHost.autoUpdate.rebootTime.type.check; in
    lib.all check [ "00:00" "04:30" "19:59" "23:59" ]
    && !(lib.any check [ "24:00" "29:59" "4:30" "12:60" ]);
}
