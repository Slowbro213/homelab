{ config, lib, ... }:
let
  cfg = config.homelab.node;
in
{
  options.homelab.node = {
    wifiInterface = lib.mkOption { type = lib.types.str; description = "WiFi interface name"; };
    ipv4 = lib.mkOption { type = lib.types.str; description = "Static IPv4 address (no prefix)"; };
  };

  config.networking = {
    useDHCP = false;
    enableIPv6 = false;
    wireless = {
      enable = true;
      interfaces = [ cfg.wifiInterface ];
      secretsFile = config.sops.secrets."wifi/env".path;
      networks.${lib.strings.trim (builtins.readFile ../assets/wifi-ssid.txt)}.pskRaw =
        "ext:WIFI_PSK";
    };

    interfaces.${cfg.wifiInterface}.ipv4.addresses = [
      { address = cfg.ipv4; prefixLength = 24; }
    ];
    defaultGateway = "192.168.1.1";
    nameservers = [ "192.168.1.1" ];

    extraHosts = ''
      192.168.1.25 registry.gentoo.lan
    '';
  };
}
