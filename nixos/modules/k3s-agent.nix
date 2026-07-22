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
      # Keep the k8s Node name identical to today's live cluster (this node's
      # current OS hostname). Without this, k3s would register the node as
      # "tux" (the new networking.hostName), breaking the nodeSelector in
      # apps/gitea-runners/runner.yaml, which pins the buildah runner to
      # kubernetes.io/hostname: registry.gentoo.lan.
      "--node-name=registry.gentoo.lan"
    ];
  };

  networking.firewall.allowedTCPPorts = [ 10250 80 443 ];
}
