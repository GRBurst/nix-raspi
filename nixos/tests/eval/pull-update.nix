# Pi pull updates (spec addendum 2026-10-23 §3.1, §3.4; plan M6, §17 A5,
# A6, A10): rpi.pull options, units, package, substituter and key.
# Reads option values of `rpi` and of extended copies of it; never forces
# the toplevel.
{ lib, rpi, ... }:
let
  keys = import ../../keys.nix;
  # Test key: syntactically valid, not any real cache's key (A10).
  testCache = {
    name = "neptun-test";
    publicKey = "neptun-test.cachix.org-1:bmVwdHVuLWV2YWwtdGVzdC1rZXktbm90LXJlYWwtMDA=";
  };
  extend = modules: rpi.extendModules { inherit modules; };

  # Nothing set: no cache in keys.nix, no pointer URL.
  off = extend [ { _module.args.rpiKeys = keys // { cache = null; }; rpi.pull.pointerUrl = lib.mkForce null; } ];

  # Everything set: the test cache in keys.nix, a pointer URL (overrides
  # configuration.nix's).
  onWith = pointerUrl: extend [ {
    _module.args.rpiKeys = keys // { cache = testCache; };
    rpi.pull.pointerUrl = lib.mkForce pointerUrl;
  } ];
  on = onWith "https://raw.githubusercontent.com/o/r/main/nixos/deploy/neptun.json";
  onHttp = onWith "http://192.168.100.1:18080/neptun.json";
  # Partial setups (A10): pointer URL only; cache only.
  pointerOnly = extend [ { _module.args.rpiKeys = keys // { cache = null; }; rpi.pull.pointerUrl = lib.mkForce "https://x/neptun.json"; } ];
  cacheOnly = on.extendModules { modules = [ { rpi.pull.pointerUrl = lib.mkOverride 10 null; } ]; };

  oc = on.config;
  o = oc.rpi.pull;
  svc = oc.systemd.services.rpi-pull or { };
  sc = svc.serviceConfig or { };
  timer = oc.systemd.timers.rpi-pull or { };
  tc = timer.timerConfig or { };
  exec = sc.ExecStart or "";
  pkg = oc.system.build.rpiPull or null;
  # Quoting as systemd parses ExecStart (the module must use the same).
  esc = on._module.args.utils.escapeSystemdExecArgs;
  # (string context discarded: lib.hasInfix rejects store-path context)
  noCtx = builtins.unsafeDiscardStringContext;
  passes = flag: value: lib.hasInfix (noCtx (esc [ flag value ])) (noCtx exec);
  warns = sys: needle: lib.any (lib.hasInfix needle) sys.config.warnings;

  opts = rpi.options.rpi.pull;
  p = rpi.config.rpi.pull;

  # failedAssertion SYSTEM NEEDLE: some assertion mentioning NEEDLE fails.
  failedAssertion = sys: needle:
    lib.any (a: !a.assertion && lib.hasInfix needle a.message) sys.config.assertions;
in
{
  # --- Task 6.1: options, disabled by default ---
  "disabled without cache key or pointer URL (no units)" =
    !off.config.rpi.pull.enable
    && !(off.config.systemd.services ? rpi-pull)
    && !(off.config.systemd.timers ? rpi-pull);

  # P11 on the real configuration (stays true once keys.nix has the cache).
  "enable follows pointerUrl, cacheUrl and cachePublicKey" =
    p.enable == (p.pointerUrl != null && p.cacheUrl != null && p.cachePublicKey != null);

  "option defaults: URLs and key null, daily 05:00, reboot 04:30, 21 days" =
    opts.pointerUrl.default == null && opts.cacheUrl.default == null
    && opts.cachePublicKey.default == null
    && opts.onCalendar.default == "*-*-* 05:00"
    && opts.rebootTime.default == "04:30"
    && opts.maxAgeDays.default == 21;

  # shutdown -r accepts 00:00-23:59 only (rpi-pull --reboot-time: HH:MM)
  "rebootTime accepts 00:00-23:59 only" =
    let check = opts.rebootTime.type.check; in
    lib.all check [ "00:00" "04:30" "19:59" "23:59" ]
    && !(lib.any check [ "24:00" "29:59" "4:30" "12:60" ]);

  # rpi-pull --max-age-days: 1-9999, anything else exits 2
  "maxAgeDays accepts 1-9999 only" =
    let check = opts.maxAgeDays.type.check; in
    lib.all check [ 1 21 9999 ] && !(lib.any check [ 0 (-1) 10000 "21" ]);

  "URLs need http(s)://, the key name:base64" =
    let
      url = opts.pointerUrl.type.check;
      key = opts.cachePublicKey.type.check;
    in
    url "https://raw.githubusercontent.com/o/r/main/nixos/deploy/neptun.json"
    && url "http://192.168.100.1:18080/neptun.json"
    && !(lib.any url [ "ftp://x/neptun.json" "raw.githubusercontent.com/o/r" "https://" ])
    && opts.cacheUrl.type.check "https://neptun-test.cachix.org"
    && key testCache.publicKey
    && !(lib.any key [
      "bmVwdHVuLWV2YWwtdGVzdC1rZXktbm90LXJlYWwtMDA="
      "neptun-test.cachix.org-1:bmVwdHVu"
      "neptun-test.cachix.org-1:bmVwdHVuLWV2YWwtdGVzdC1rZXktbm90LXJlYWwtMD=="
    ]);

  "enable without pointerUrl, cacheUrl and cachePublicKey is rejected" =
    failedAssertion (off.extendModules { modules = [ { rpi.pull.enable = true; } ]; }) "rpi.pull";

  # --- Task 6.2: units, package, substituter ---
  "enabled once the cache key and the pointer URL are set" =
    o.enable && oc.systemd.services ? rpi-pull && oc.systemd.timers ? rpi-pull
    && lib.all (a: a.assertion) oc.assertions;

  "our cache is a substituter with its key; cache.nixos.org stays" =
    lib.elem o.cacheUrl oc.nix.settings.substituters
    && lib.elem testCache.publicKey oc.nix.settings.trusted-public-keys
    && lib.elem "https://cache.nixos.org/" oc.nix.settings.substituters;

  # A6: daily (the no-op path is one curl)
  "timer daily 05:00, Persistent, 30m jitter, in timers.target" =
    (tc.OnCalendar or null) == "*-*-* 05:00"
    && (tc.Persistent or null) == true
    && (tc.RandomizedDelaySec or null) == "30m"
    && lib.elem "timers.target" (timer.wantedBy or [ ]);

  # D15: switch-to-configuration must not stop/restart the unit running it.
  "service: oneshot, idle, bounded, never restarted by a switch" =
    (sc.Type or null) == "oneshot"
    && (svc.restartIfChanged or null) == false
    && (svc.unitConfig.X-StopOnRemoval or null) == false
    && (sc.Nice or null) == 19
    && (sc.IOSchedulingClass or null) == "idle"
    && (sc.CPUSchedulingPolicy or null) == "idle"
    && (sc.MemoryMax or null) == "384M"
    && (sc.TimeoutStartSec or null) == "2h"
    && (sc.StateDirectory or null) == "rpi-pull"
    && (svc.environment.HOME or null) == "/root";

  # A6: Persistent catch-up can fire at boot before NTP (no RTC on the Pi).
  "service waits for the network and a synced clock" =
    lib.all (t: lib.elem t (svc.after or [ ]) && lib.elem t (svc.wants or [ ]))
      [ "network-online.target" "time-sync.target" ];

  # Final review N1: time-sync.target alone is reached once timesyncd has
  # started, synced or not. systemd-time-wait-sync (upstream unit, installed
  # but not enabled: boot never waits for NTP) is pulled in by rpi-pull only,
  # with a bounded wait (no NTP within 30 min: rpi-pull runs anyway).
  "service waits for systemd-time-wait-sync; boot does not; bounded" =
    let
      tws = "systemd-time-wait-sync.service";
      u = oc.systemd.services.systemd-time-wait-sync or { };
    in
    lib.elem tws oc.systemd.additionalUpstreamSystemUnits
    && lib.elem tws (svc.after or [ ]) && lib.elem tws (svc.wants or [ ])
    && !(lib.elem tws (svc.requires or [ ]))
    && (u.wantedBy or [ ]) == [ ] && (u.requiredBy or [ ]) == [ ]
    && (u.serviceConfig.TimeoutStartSec or null) == "30min";

  "disabled: no systemd-time-wait-sync" =
    !(lib.elem "systemd-time-wait-sync.service" off.config.systemd.additionalUpstreamSystemUnits);

  "service runs the packaged rpi-pull" =
    pkg != null && lib.hasPrefix "${noCtx (toString pkg)}/bin/rpi-pull " (noCtx exec);

  # P10
  "ExecStart passes every option" =
    lib.all (fv: passes (lib.elemAt fv 0) (lib.elemAt fv 1)) [
      [ "--pointer-url" o.pointerUrl ]
      [ "--cache-url" o.cacheUrl ]
      [ "--cache-key" o.cachePublicKey ]
      [ "--host" oc.system.name ]
      [ "--reboot-time" o.rebootTime ]
      [ "--max-age-days" (toString o.maxAgeDays) ]
      [ "--state-dir" "/var/lib/rpi-pull" ]
    ];

  "package ships rpi-fp.sh next to rpi-pull" =
    pkg != null
    && lib.hasInfix "--set RPI_FP_LIB $out/libexec/rpi-pull/rpi-fp.sh" (noCtx pkg.installPhase);

  "rpi-pull finds nix, curl, jq, flock and shutdown" =
    pkg != null
    && lib.all (d: lib.hasInfix "${noCtx (toString d)}/bin" (noCtx pkg.installPhase)) [
      oc.nix.package on.pkgs.curl on.pkgs.jq on.pkgs.util-linux oc.systemd.package
    ];

  # D9: http only for the smoke test
  "http pointer URL warns" = warns onHttp "rpi.pull.pointerUrl";

  "https pointer URL does not warn" = !warns on "rpi.pull";

  # A10: a partial setup leaves rpi.pull silently off otherwise.
  "partial setup warns (pointer URL only; cache only)" =
    !pointerOnly.config.rpi.pull.enable && warns pointerOnly "rpi.pull"
    && !cacheOnly.config.rpi.pull.enable && warns cacheOnly "rpi.pull";

  "nothing set: no rpi.pull warning" = !warns off "rpi.pull";

  # --- Task 6.3: keys.cache -> rpi.pull ---
  "cacheUrl and key come from keys.nix cache" =
    o.cacheUrl == "https://neptun-test.cachix.org" && o.cachePublicKey == testCache.publicKey;

  # Spec §6: the user fills keys.nix `cache`; null until then (pull off).
  "keys.nix has a cache entry: null or { name; publicKey; }" =
    keys ? cache
    && (keys.cache == null || (lib.isString keys.cache.name && lib.isString keys.cache.publicKey));

  # Plan §17 "Remote": the production pointer (raw GitHub, HTTPS).
  "configuration.nix sets the production pointer URL" =
    p.pointerUrl == "https://raw.githubusercontent.com/GRBurst/nix-raspi/main/nixos/deploy/neptun.json";
}
