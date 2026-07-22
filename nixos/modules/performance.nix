{ pkgs, lib, ... }:
{
  # Pinned LTS for a predictable cluster substrate; override per-node if needed.
  boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_6_12;

  boot.kernelParams = [
    "transparent_hugepage=madvise"
    "psi=1"
  ];

  # cgroup v2 unified is the systemd/NixOS default — no action needed.

  # Maximum performance: pin the CPU frequency governor to "performance" (never
  # balanced/powersave), and make sure no power-profile daemon overrides it.
  powerManagement.enable = true;
  powerManagement.cpuFreqGovernor = "performance";
  services.power-profiles-daemon.enable = lib.mkForce false;
  services.tlp.enable = lib.mkForce false;

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  boot.kernel.sysctl = {
    "vm.swappiness" = 100;              # zram-appropriate
    "vm.overcommit_memory" = 1;
    "vm.max_map_count" = 1048576;
    "fs.inotify.max_user_instances" = 8192;
    "fs.inotify.max_user_watches" = 524288;
    "fs.file-max" = 2097152;
    "net.ipv4.ip_forward" = 1;
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.core.somaxconn" = 4096;
    "net.netfilter.nf_conntrack_max" = 262144;
  };
}
