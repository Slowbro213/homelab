{ config, lib, ... }:
let
  cfg = config.homelab.node;
in
{
  options.homelab.node = {
    wifiInterface = lib.mkOption { type = lib.types.str; description = "WiFi interface name"; };
    ipv4 = lib.mkOption { type = lib.types.str; description = "Static IPv4 address (no prefix)"; };
  };

  config = {
    networking.useDHCP = false;
    networking.wireless = {
      enable = true;
      interfaces = [ cfg.wifiInterface ];
      # SSID is a literal (broadcast, not secret) read from a committed public file.
      # Only the PSK is kept out of the store: `ext:WIFI_PSK` pulls it at service
      # start from the sops-provided secretsFile, which defines `WIFI_PSK=…`.
      # (nixos-25.11 replaced `environmentFile` with `secretsFile`; same file format.)
      secretsFile = config.sops.secrets."wifi/env".path;
      networks.${lib.strings.trim (builtins.readFile ../assets/wifi-ssid.txt)}.pskRaw =
        "ext:WIFI_PSK";
    };

    networking.interfaces.${cfg.wifiInterface}.ipv4.addresses = [
      { address = cfg.ipv4; prefixLength = 24; }
    ];
    networking.defaultGateway = "192.168.1.1";
    networking.nameservers = [ "192.168.1.1" ];

    # Resolve the internal registry / ingress before in-cluster DNS exists.
    networking.extraHosts = ''
      192.168.1.25 registry.gentoo.lan
      192.168.1.25 gentoo.lan
      192.168.1.25 argocd.gentoo.lan
      192.168.1.25 whoami.gentoo.lan
    '';
  };
}
