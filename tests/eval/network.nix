# rpi.network (spec §4, §7 "static network"; plan T2.3, D8): DHCP by default
# through NixOS's own networkd default network, or one static wired network
# (10-lan-static). Evaluated on the fixture host through lib.mkPi; never
# forces the toplevel.
{ lib, rpiLib, fixtures, ... }:
let
  minimal = fixtures + "/hosts/minimal.nix";
  mk = extra: rpiLib.mkPi { modules = [ minimal ] ++ extra; };
  t = mk [ ];
  cfg = t.config;
  failedAssertion = sys: s:
    lib.any (a: !a.assertion && lib.hasInfix s a.message) sys.config.assertions;

  static = extra: mk [ {
    rpi.network = {
      mode = "static";
      static = { address = "192.0.2.20/24"; gateway = "192.0.2.1"; } // extra;
    };
  } ];
  s = (static { }).config;
  dns = [ "192.0.2.53" "9.9.9.9" ];
  sd = (static { inherit dns; }).config;
  lan = c: c.systemd.network.networks."10-lan-static" or null;
  noAddr = mk [ { rpi.network.mode = "static"; rpi.network.static.gateway = "192.0.2.1"; } ];
  noGw = mk [ { rpi.network.mode = "static"; rpi.network.static.address = "192.0.2.20/24"; } ];

  # Property, not a unit name: some network matches wired ether with DHCP.
  dhcpEther = c: lib.any
    (n: (n.matchConfig.Type or null) == "ether"
        && ((n.DHCP or null) == "yes" || (n.networkConfig.DHCP or null) == "yes"))
    (lib.attrValues c.systemd.network.networks);

  opts = t.options.rpi.network;
  addrOk = opts.static.address.type.check;
  gwOk = opts.static.gateway.type.check;
  modeOk = opts.mode.type.check;
in
{
  "dhcp (default): no 10-lan-static; networkd; some network matches ether with DHCP" =
    cfg.rpi.network.mode == "dhcp" && lan cfg == null
    && cfg.networking.useNetworkd && dhcpEther cfg;

  "static: 10-lan-static with Address and Gateway" =
    let n = lan s; in
    n != null
    && n.matchConfig.Type == "ether"
    && (n.networkConfig.Address or null) == "192.0.2.20/24"
    && (n.networkConfig.Gateway or null) == "192.0.2.1"
    && !(n.networkConfig ? DNS);

  "static with dns sets DNS" = ((lan sd).networkConfig.DNS or null) == dns;

  "static without address fails an assertion naming rpi.network.static.address" =
    failedAssertion noAddr "rpi.network.static.address"
    && failedAssertion noGw "rpi.network.static.gateway"
    && !(failedAssertion (static { }) "rpi.network");

  "address must be CIDR" =
    addrOk "192.0.2.20/24" && addrOk "10.0.0.2/8"
    && !(lib.any addrOk [ "192.168.1.20" "host/24" "192.0.2.20/" ])
    && gwOk "192.0.2.1" && !(gwOk "192.0.2.1/24");

  "mode accepts dhcp or static only" =
    modeOk "dhcp" && modeOk "static" && !(modeOk "wifi");
}
