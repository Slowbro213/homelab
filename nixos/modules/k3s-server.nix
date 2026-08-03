{ config, ... }:
let
  node = config.homelab.node;
in
{
  services.k3s = {
    enable = true;
    role = "server";
    tokenFile = config.sops.secrets."k3s/token".path;
    extraFlags = [
      "--flannel-backend=host-gw"
      "--node-name=cachyos"
      "--node-ip=${node.ipv4}"
      "--flannel-iface=${node.wifiInterface}"  # pin flannel to WiFi (not tailscale0/wwan)
      "--tls-san=192.168.1.31"
      "--tls-san=k3s.gentoo.lan"
      "--write-kubeconfig-mode=0644"
      # Longhorn only auto-creates its default disk on nodes carrying this label
      # (create-default-disk-labeled-nodes=true). Without it the node reports 0
      # storage and no PVC can schedule.
      "--node-label=node.longhorn.io/create-default-disk=true"
      "--secrets-encryption"
    ];
  };

  # API server, kubelet metrics, servicelb/traefik ingress (live on both nodes today),
  # and node-exporter (hostNetwork, scraped cross-node by Prometheus).
  networking.firewall.allowedTCPPorts = [ 6443 10250 80 443 9100 ];
}
