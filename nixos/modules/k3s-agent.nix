{ config, ... }:
let
  node = config.homelab.node;
in
{
  services.k3s = {
    enable = true;
    role = "agent";
    serverAddr = "https://192.168.1.31:6443";
    tokenFile = config.sops.secrets."k3s/token".path;
    extraFlags = [
      "--node-ip=${node.ipv4}"
      "--flannel-iface=${node.wifiInterface}"  # pin flannel to WiFi (not tailscale0/wwan)
    ];
  };

  networking.firewall.allowedTCPPorts = [ 10250 80 443 ];
}
