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

  programs.terminalKit = {
    enable = true;
    shellIntegration = "sourced";
    clipboard = "osc52";
    theme.modeSource = "terminal";
    aiSkills.enable = true;
  };

  programs.home-manager.enable = true;
  home.stateVersion = "26.05";
}
