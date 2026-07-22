{ ... }:
{
  imports = [
    ../../modules/k3s-agent.nix
    ../../modules/gitea-runner-seccomp.nix  # runner is nodeSelector-pinned to this node
  ];

  networking.hostName = "tux";
  homelab.node = {
    wifiInterface = "wlp1s0";
    ipv4 = "192.168.1.25";
  };

  # tux is a laptop too — a closed lid must not suspend the cluster node.
  services.logind.lidSwitch = "ignore";
  services.logind.lidSwitchExternalPower = "ignore";

  system.stateVersion = "25.11";
}
