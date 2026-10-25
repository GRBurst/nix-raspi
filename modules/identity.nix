# rpi.admin / rpi.ssh / rpi.deploy (filled in by plan T2.2). The key option
# exists from the start: the fixture host sets it.
{ lib, ... }: {
  options.rpi.admin.sshKeys = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
  };
}
