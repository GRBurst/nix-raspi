# Eval-level checks, auto-discovered: every other `*.nix` file in this
# directory is a function `args -> { "<human-readable property>" = <bool>; }`
# and becomes `checks.x86_64-linux.eval-<file>`. The check fails with one
# `FAIL: <property>` line per false entry (or `FAIL: no assertions` for an
# empty set). The booleans are computed at evaluation time, so the check
# derivations themselves are trivial.
#
# Rules for the files: >= 1 entry; never force
# config.system.build.toplevel (IFD / aarch64 builds); never interpolate
# store paths into the messages (attribute names carry no string context).
{ lib, pkgs, args }:
let
  files = lib.attrNames (lib.filterAttrs
    (n: t: t == "regular" && lib.hasSuffix ".nix" n && n != "default.nix") (builtins.readDir ./.));
  mkCheck = file:
    let
      results = import (./. + "/${file}") args;          # attrsOf bool
      failed  = lib.attrNames (lib.filterAttrs (_: ok: !ok) results);
      msg = if results == { } then [ "no assertions" ] else failed;
    in pkgs.runCommand "eval-${lib.removeSuffix ".nix" file}"
      { failures = lib.concatMapStrings (m: "FAIL: ${m}\n") msg;
        passed = toString (lib.length (lib.attrNames results)); }
      ''
        if [ -n "$failures" ]; then printf '%s' "$failures" >&2; exit 1; fi
        echo "$passed assertions passed"; touch $out
      '';
in lib.listToAttrs (map (f: lib.nameValuePair "eval-${lib.removeSuffix ".nix" f}" (mkCheck f)) files)
