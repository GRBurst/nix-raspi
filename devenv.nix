# Local development shell for this repo (`devenv shell`, or automatic
# activation). Everything the README's workflows need besides nix itself:
# cachix (cache setup, README §4), the lint tools `nix flake check` runs,
# and the tools the qemu smoke tests check for (tests/qemu-pi.sh qp_need).
{ pkgs, ... }:

{
  packages = with pkgs; [
    # binary cache setup (README §4: create the cache, signing key)
    cachix
    # lint, same tools as the flake checks
    shellcheck
    actionlint
    # rpi-deploy and the scripts in nixos/ci
    git
    jq
    curl
    zstd
    openssh
    util-linux # sfdisk, flock, lsblk
    # qemu smoke tests (tests/{boot,deploy,pull}-smoke.sh)
    qemu # qemu-system-aarch64 with -M raspi3b
    e2fsprogs # debugfs
    mtools # mcopy
  ];

  # The working tree's rpi-deploy (the build host's packaged one is the
  # committed version).
  scripts.rpi-deploy = {
    exec = ''exec bash "$DEVENV_ROOT/nixos/rpi-deploy.sh" "$@"'';
    description = "rpi-deploy from the working tree (image, flash, deploy, status)";
  };

  scripts.rpi-unit = {
    exec = ''
      cd "$DEVENV_ROOT/nixos" || exit 1
      rc=0
      for t in tests/*-unit.sh; do
        last=$(bash "$t" 2>&1 | tail -n 1)
        echo "== $t: $last"
        [[ "$last" == *" 0 failed" ]] || rc=1
      done
      exit "$rc"
    '';
    description = "unit tests (tests/*-unit.sh, ~1 min, no VMs)";
  };

  scripts.rpi-check = {
    exec = ''
      set -e
      cd "$DEVENV_ROOT/nixos"
      # yazi's IFD: evaluate the toplevel once before the check (HANDOFF §6)
      nix eval --raw --accept-flake-config \
        .#nixosConfigurations.rpi.config.system.build.toplevel.drvPath >/dev/null
      nix flake check --accept-flake-config "$@"
    '';
    description = "nix flake check in nixos/ (all checks incl. the host VM test; --no-build for eval only)";
  };

  # `devenv test`
  enterTest = "rpi-unit";

  git-hooks.hooks = {
    shellcheck = {
      enable = true;
      args = [ "-x" "-P" "SCRIPTDIR" "-S" "warning" ];
      # vendored nvmd builder templates, not ours
      excludes = [ "^nixos/tests/fixtures/" ];
    };
    actionlint.enable = true;
  };
}
