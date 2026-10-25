# SSH public keys and our binary cache for the Pi (read by configuration.nix,
# ci/cache-name.sh and tests/eval/{pi-config,pull-update}.nix).
#   user  - the user's key: `pi` and root (manual `rpi-deploy deploy`)
#   cache - our self-signed Cachix cache; null until created (rpi.pull off)
{
  user = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKxv8UiT62T7r81Z3h/L/7qhZZqVhF5ogXXthjhdAJVe pallon@andromeda->pi3 on 2026-10-18";

  # Own self-signed Cachix cache (addendum §3.1, §6): cache = { name = "<cache>"; publicKey = "<cache>.cachix.org-1:…"; };
  cache = null;
}
