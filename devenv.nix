# Local development shell for this repo (`devenv shell`, or automatic
# activation). Everything the README's workflows need besides nix itself:
# cachix (cache setup, README §4), the lint tools `nix flake check` runs,
# and the tools the qemu smoke tests check for (tests/qemu-pi.sh qp_need).
{
  pkgs,
  config,
  ...
}: {
  packages = with pkgs; [
    # binary cache setup (README §4: create the cache, signing key)
    cachix
    # Wi-Fi PSKs from the user's provider into rpi-deploy, never into the
    # store: `secretspec run -- rpi-deploy secrets` (secretspec.toml)
    secretspec
    # lint, same tools as the flake checks
    shellcheck
    actionlint
    # rpi-deploy and the scripts in ci/
    git
    secretspec
    curl
    zstd
    openssh
    util-linux # sfdisk, flock, lsblk
    # qemu smoke tests (tests/{boot,deploy,pull}-smoke.sh)
    qemu # qemu-system-aarch64 with -M raspi3b
    e2fsprogs # debugfs
    mtools # mcopy
  ];

  # rpi-deploy needs no --flake (what rpi.buildHost.flakePath does on a host).
  env.RPI_FLAKE = config.devenv.root;

  # The two things only the host can provide (README section 1); warns, never
  # blocks the shell.
  scripts.rpi-doctor = {
    exec = ''
      ok=0
      if [[ "$(uname -m)" != aarch64 ]] &&
        ! nix config show extra-platforms 2>/dev/null | grep -qw aarch64-linux; then
        echo 'rpi: no aarch64 emulation: add  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];  to the host NixOS config (README section 1)' >&2
        ok=1
      fi
      if ! nix store info 2>&1 | grep -q '^Trusted: 1'; then
        echo "rpi: $USER is not a trusted nix user: the nvmd cache is ignored and the kernel gets compiled; add  nix.settings.trusted-users = [ \"$USER\" ];  (README section 1)" >&2
        ok=1
      fi
      exit "$ok"
    '';
    description = "check the host prerequisites (aarch64 emulation, trusted nix user)";
  };

  enterShell = "rpi-doctor || true";

  # The working tree's rpi-deploy (the build host's packaged one is the
  # committed version).
  scripts.rpi-deploy = {
    exec = ''exec bash "$DEVENV_ROOT/rpi-deploy.sh" "$@"'';
    description = "rpi-deploy from the working tree (image, flash, deploy, status)";
  };

  scripts.rpi-unit = {
    exec = ''
      cd "$DEVENV_ROOT" || exit 1
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
      cd "$DEVENV_ROOT"
      # yazi's IFD: evaluate the toplevel once before the check (HANDOFF §6)
      nix eval --raw --accept-flake-config \
        .#nixosConfigurations.rpi.config.system.build.toplevel.drvPath >/dev/null
      nix flake check --accept-flake-config "$@"
    '';
    description = "nix flake check at the repository root (all checks incl. the host VM test; --no-build for eval only)";
  };

  # `devenv test`
  enterTest = "rpi-unit";

  git-hooks.hooks = {
    shellcheck = {
      enable = true;
      args = ["-x" "-P" "SCRIPTDIR" "-S" "warning"];
      # vendored nvmd builder templates, not ours
      excludes = ["^tests/fixtures/"];
    };
    actionlint.enable = true;
  };
}
