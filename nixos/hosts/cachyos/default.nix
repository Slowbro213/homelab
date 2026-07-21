{ ... }:
{
  imports = [ ../../modules/k3s-server.nix ];

  networking.hostName = "cachyos";
  homelab.node = {
    wifiInterface = "wlan0";
    ipv4 = "192.168.1.31";
  };

  # Sole control plane — a closed lid must not suspend the node.
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
  };

  system.stateVersion = "25.11";
}
