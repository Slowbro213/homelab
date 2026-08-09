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
      "--kube-apiserver-arg=audit-log-path=/var/log/kubernetes/audit/audit.log"
      "--kube-apiserver-arg=audit-policy-file=/etc/rancher/k3s/audit-policy.yaml"
      "--kube-apiserver-arg=audit-log-maxage=7"
      "--kube-apiserver-arg=audit-log-maxbackup=5"
      "--kube-apiserver-arg=audit-log-maxsize=100"
    ];
  };

  # kube-apiserver creates the audit log file itself but not the parent directory.
  systemd.tmpfiles.rules = [
    "d /var/log/kubernetes/audit 0750 root root - -"
  ];

  environment.etc."rancher/k3s/audit-policy.yaml".source = ../assets/audit-policy.yaml;

  # API server, kubelet metrics, servicelb/traefik ingress (live on both nodes today),
  # and node-exporter (hostNetwork, scraped cross-node by Prometheus).
  networking.firewall.allowedTCPPorts = [ 6443 10250 80 443 9100 ];
}
