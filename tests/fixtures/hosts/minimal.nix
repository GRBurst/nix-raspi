# Smallest valid Pi host for the eval checks (tests/eval/*.nix): an eval-only
# key (not anyone's real key) and the state version. Everything else comes
# from the library defaults (lib.mkPi, nixosModules.default).
{
  rpi.admin.sshKeys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEvalOnlyTestKeyEvalOnlyTestKeyEvalOnly00 eval@test" ];
  system.stateVersion = "26.05";
}
