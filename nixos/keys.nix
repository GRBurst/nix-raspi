# SSH public keys for the Pi (read by configuration.nix and
# tests/eval/pi-config.nix).
#   user        - the user's key: `pi` and root (manual `rpi-deploy deploy`)
#   autoUpdate  - dedicated key of the host's rpi-autoupdate job, or null.
#                 Added to root only, restricted to `from="<hostAddress>"`.
#   hostAddress - LAN address of the build host (andromeda, enp5s0); required
#                 when autoUpdate is set.
{
  user = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKxv8UiT62T7r81Z3h/L/7qhZZqVhF5ogXXthjhdAJVe pallon@andromeda->pi3 on 2026-10-18";
  # Not generated yet: paste the content of ~/.ssh/rpi-autoupdate.pub here.
  autoUpdate = null;
  hostAddress = "192.168.100.115";
}
