# rpi.network (spec §4; plan D8): wired networking through systemd-networkd
# (networking.useNetworkd, modules/base.nix).
#   dhcp   (default) defines no network of its own: NixOS's default DHCP
#          networks for wired `ether` and wireless station interfaces apply
#          (networking.useDHCP default).
#   static one network "10-lan-static" for any wired ethernet interface with
#          rpi.network.static.{address, gateway, dns}; it sorts before
#          NixOS's 99-* DHCP defaults, so it wins on the wire.
# Checked by checks.x86_64-linux.eval-network.
{ config, lib, ... }:
let
  cfg = config.rpi.network;
  ipv4 = "[0-9]{1,3}(\\.[0-9]{1,3}){3}";
  complete = cfg.static.address != null && cfg.static.gateway != null;
in
{
  options.rpi.network = {
    mode = lib.mkOption {
      type = lib.types.enum [ "dhcp" "static" ];
      default = "dhcp";
      description = ''
        `"dhcp"`: address from the router (NixOS's default networkd DHCP
        network). `"static"`: `rpi.network.static.*` on every wired
        ethernet interface.
      '';
    };

    static = {
      address = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "${ipv4}/[0-9]{1,2}");
        default = null;
        example = "192.0.2.20/24";
        description = "IPv4 address with prefix length (CIDR); required in static mode.";
      };

      gateway = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching ipv4);
        default = null;
        example = "192.0.2.1";
        description = "IPv4 default gateway; required in static mode.";
      };

      dns = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "192.0.2.1" ];
        description = "DNS servers (none: resolved without per-link servers).";
      };
    };
  };

  config = lib.mkIf (cfg.mode == "static") (lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.static.address != null;
          message = ''rpi.network.mode = "static" needs rpi.network.static.address (CIDR, e.g. "192.0.2.20/24").'';
        }
        {
          assertion = cfg.static.gateway != null;
          message = ''rpi.network.mode = "static" needs rpi.network.static.gateway (e.g. "192.0.2.1").'';
        }
      ];
    }
    # Only a complete setup gets a network; an incomplete one fails the
    # assertions above.
    (lib.mkIf complete {
      systemd.network.networks."10-lan-static" = {
        matchConfig = {
          Type = "ether"; # any physical wired ethernet interface
        };
        networkConfig = {
          Address = cfg.static.address;
          Gateway = cfg.static.gateway;
        } // lib.optionalAttrs (cfg.static.dns != [ ]) {
          DNS = cfg.static.dns;
        };
      };
    })
  ]);
}
