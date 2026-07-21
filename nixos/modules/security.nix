{ lib, ... }:
{
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  services.fail2ban = {
    enable = true;
    maxretry = 5;
  };

  security.apparmor.enable = true;  # NixOS-supported LSM (SELinux is not the NixOS default path)

  services.tailscale.enable = true;

  networking.firewall = {
    enable = true;
    checkReversePath = "loose";          # WiFi roaming + Tailscale asymmetric paths
    # cni0 (pod bridge) and tailscale0 are fully trusted; cross-node pod traffic is
    # FORWARDed (handled by flannel/kube-router), not INPUT, so no host pod-CIDR
    # accept rule is needed here. allowedTCPPorts are added per role below.
    trustedInterfaces = [ "cni0" "tailscale0" ];
  };
}
