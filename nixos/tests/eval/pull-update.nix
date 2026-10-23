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
}
