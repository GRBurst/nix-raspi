{
  description = "My Raspberry Pi 3, on the nix-raspi library";

  # Same binary cache as the library's flake: it holds the vendor kernel and
  # firmware for the locked nixpkgs. Without it the kernel is compiled
  # locally (16+ h under qemu). Applied when the flake config is accepted
  # (`--accept-flake-config`, which rpi-deploy passes) and you are a trusted
  # nix user.
  nixConfig = {
    extra-substituters = [ "https://nixos-raspberrypi.cachix.org" ];
    extra-trusted-public-keys = [
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
    ];
  };

  # Keep the name `rpi` (the CI workflow runs `nix run --inputs-from . rpi#rpi-ci`)
  # and do not add `follows`: inheriting the library's lock is what makes the
  # nixpkgs and nvmd caches hit.
  inputs.rpi.url = "github:GRBurst/nix-raspi";

  outputs = { rpi, ... }: {
    # One Pi: add more with another `lib.mkPi` call and a hosts/<name>.nix.
    nixosConfigurations.rpi = rpi.lib.mkPi { modules = [ ./hosts/rpi.nix ]; };

    # rpi-deploy (image, flash, deploy, status) and rpi-ci, locked with the
    # library: `nix run .#rpi-deploy -- --help`. The pinned nixos-rebuild app
    # is what rpi-deploy runs for a push deploy.
    inherit (rpi) apps packages;
  };
}
