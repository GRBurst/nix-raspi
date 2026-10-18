{
  pkgs,
  inputs,
  ...
}: {
  home.username = "pi";
  home.homeDirectory = "/home/pi";

  # Install nix-terminal package directly from its flake input
  home.packages = with pkgs; [
    btop
    atop

    wget
    curl

    git
    tig

    netcat
    nmap

    psmisc

    tree

    ncdu
  ];

  # Headless terminal environment (no display server on the Pi):
  # - clipboard = "osc52": yank goes through the terminal's OSC 52 sequence;
  #   no X/Wayland clipboard tools are installed
  # - shellIntegration default ("owned") is correct for a fresh install;
  #   "sourced" is the mode for Coder workspaces
  programs.terminalKit = {
    enable = true;
    clipboard = "osc52";
    theme.modeSource = "terminal";
    aiSkills.enable = true;
    # The dev set (nodejs/clang/devenv/docker-compose) is "heavy"; the Pi 3
    # has 1 GB RAM, so keep it off.
    packages.dev.enable = false;
  };

  # home-manager master vs nixos-26.05 nixpkgs (pinned by nixos-raspberrypi);
  # see flake.nix. Silences the release-mismatch warning.
  home.enableNixpkgsReleaseCheck = false;
  # HM master asserts fzf >= 0.73 for its nushell integration; nixos-26.05 ships
  # an older fzf. The Pi uses zsh, so the nushell integration is not needed.
  programs.fzf.enableNushellIntegration = false;

  programs.home-manager.enable = true;
  home.stateVersion = "26.05";
}
