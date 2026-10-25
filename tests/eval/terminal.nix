# rpi.profiles.terminal (spec §4; plan T2.6, D5): home-manager + nix-terminal
# for rpi.admin.user with zsh as login shell; off by default (eval-defaults
# "no HM users by default"). Every setting is a default the host's own
# home-manager config overrides (home-manager.users.<user>.programs.terminalKit.*).
# HM option values only: never forces packages or the toplevel.
{ lib, rpiLib, fixtures, ... }:
let
  minimal = fixtures + "/hosts/minimal.nix";
  mk = extra: rpiLib.mkPi { modules = [ minimal { rpi.profiles.terminal.enable = true; } ] ++ extra; };
  t = mk [ ];
  cfg = t.config;
  u = cfg.rpi.admin.user;
  hm = cfg.home-manager.users.${u};
  kit = hm.programs.terminalKit;
  alice = (mk [ { rpi.admin.user = "alice"; } ]).config;
  zshLogin = c: user:
    c.programs.zsh.enable && lib.getName c.users.users.${user}.shell == "zsh";
  overridden = (mk [ {
    home-manager.users.pi.programs.terminalKit = {
      clipboard = "system";
      packages.dev.enable = true;
    };
  } ]).config.home-manager.users.pi.programs.terminalKit;
in
{
  "HM user is rpi.admin.user with zsh login shell" =
    u == "pi" && zshLogin cfg u
    && lib.attrNames cfg.home-manager.users == [ u ];

  "terminal profile follows rpi.admin.user" =
    zshLogin alice "alice"
    && lib.attrNames alice.home-manager.users == [ "alice" ]
    && !(alice.users.users ? pi);

  "terminalKit on with Pi defaults (osc52, dev packages off, release check off, fzf nushell off)" =
    kit.enable && kit.clipboard == "osc52" && !kit.packages.dev.enable
    && !hm.home.enableNixpkgsReleaseCheck
    && !hm.programs.fzf.enableNushellIntegration
    && hm.programs.home-manager.enable
    && hm.home.stateVersion == "26.05";

  "a host overrides the profile's terminalKit settings" =
    overridden.clipboard == "system" && overridden.packages.dev.enable;
}
