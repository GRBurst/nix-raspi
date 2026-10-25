# rpi.profiles.terminal (spec §4; plan D5): a terminal environment for the
# admin user, off by default. home-manager with the nix-terminal kit
# (programs.terminalKit, a Home Manager module lib.mkPi adds to
# home-manager.sharedModules) and zsh as the login shell.
#
# Separate output (nixosModules.terminal): it defines home-manager options,
# which only exist with the home-manager NixOS module (lib.mkPi imports it).
#
# Every Home Manager value is a default for a small headless Pi; the host
# overrides it in its own home-manager config, e.g.
#   home-manager.users.<user>.programs.terminalKit.clipboard = "system";
# Checked by checks.x86_64-linux.eval-terminal.
{ config, lib, pkgs, ... }:
let
  cfg = config.rpi.profiles.terminal;
  user = config.rpi.admin.user;
  inherit (lib) mkDefault;
in
{
  options.rpi.profiles.terminal.enable =
    lib.mkEnableOption "home-manager + nix-terminal for rpi.admin.user, zsh as login shell";

  config = lib.mkIf cfg.enable {
    # zsh is configured by the nix-terminal kit (home-manager); NixOS requires
    # the login shell to be an enabled shell program.
    users.users.${user}.shell = pkgs.zsh;
    programs.zsh.enable = true;

    home-manager.users.${user} = {
      # Headless: yank goes through the terminal's OSC 52 sequence (no
      # X/Wayland clipboard tools). The dev package set (nodejs, clang,
      # devenv, docker-compose) is too heavy for 1 GB of RAM.
      programs.terminalKit = {
        enable = mkDefault true;
        clipboard = mkDefault "osc52";
        packages.dev.enable = mkDefault false;
      };
      # home-manager master against nixos-26.05 nixpkgs: silences the
      # release-mismatch warning.
      home.enableNixpkgsReleaseCheck = mkDefault false;
      # HM master asserts fzf >= 0.73 for its nushell integration;
      # nixos-26.05 ships an older fzf, and the login shell is zsh.
      programs.fzf.enableNushellIntegration = mkDefault false;
      programs.home-manager.enable = mkDefault true;
      home.stateVersion = mkDefault "26.05";
    };
  };
}
