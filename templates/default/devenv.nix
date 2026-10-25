# Operator shell of this repo (`devenv shell`, or direnv): the tools around
# the Pi, not the Pi's system (that is hosts/rpi.nix). rpi-deploy itself comes
# from the library locked in flake.lock, so it stays in step with the system
# it builds and deploys.
{ pkgs, config, ... }:
{
  packages = with pkgs; [
    # create the binary cache and its signing key (README of nix-raspi, Updates)
    cachix
    # Wi-Fi PSKs from your provider into rpi-deploy, never into the store:
    #   secretspec run -- rpi-deploy secrets      (see secretspec.toml)
    secretspec
  ];

  # rpi-deploy needs no --flake: it finds this repository.
  env.RPI_FLAKE = config.devenv.root;

  # rpi-deploy of the locked library (`nix run .#rpi-deploy`, flake.nix
  # re-exports it). Per-machine overrides (RPI_HOST, RPI_TARGET, RPI_PORT)
  # go into devenv.local.nix (copy devenv.local.nix.example).
  scripts.rpi-deploy = {
    exec = ''nix run "$DEVENV_ROOT#rpi-deploy" -- "$@"'';
    description = "rpi-deploy of the locked library (image, flash, deploy, status, secrets)";
  };
}
