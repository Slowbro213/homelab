{ pkgs, lib, ... }:
{
  boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;

  boot.kernelParams = [
    "transparent_hugepage=madvise"
    "psi=1"
    "mitigations=off"
  ];

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
    "vm.swappiness" = 100; # zram-appropriate
    "vm.overcommit_memory" = 1;
    "vm.max_map_count" = 1048576;
    "fs.inotify.max_user_instances" = 8192;
    "fs.inotify.max_user_watches" = 524288;
    "fs.file-max" = 2097152;
    "net.ipv4.ip_forward" = 1;
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.core.somaxconn" = 4096;
    "net.netfilter.nf_conntrack_max" = 262144;
    "vm.dirty_background_ratio" = 5;
    "vm.dirty_ratio" = 10;
    "fs.aio-max-nr" = 1048576;
    "net.ipv4.tcp_congestion_control" = "bbr";
    "net.core.default_qdisc" = "fq";
  };

  boot.kernelModules = [ "tcp_bbr" ];

  services.fstrim.enable = true;

  services.udev.extraRules = ''
    ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
    ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
  '';

  services.journald.extraConfig = ''
    SystemMaxUse=500M
    RateLimitIntervalSec=30s
    RateLimitBurst=10000
  '';

  systemd.oomd.enable = false;
}
