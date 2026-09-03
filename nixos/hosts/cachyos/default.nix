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

  # Stable node-agnostic path to the real physical disk (as opposed to the
  # Longhorn iSCSI virtual disks, which also enumerate as /dev/sd*), so the
  # smartctl-exporter DaemonSet can use one identical device path across
  # every node regardless of its underlying disk type/name.
  services.udev.extraRules = ''
    KERNEL=="nvme0n1", SYMLINK+="monitored-disk"
  '';

  system.stateVersion = "25.11";
}
