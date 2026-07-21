{ pkgs, ... }:
{
  services.openiscsi = {
    enable = true;
    name = "iqn.2020-01.io.homelab:node";  # stable initiator name for Longhorn
  };

  # Longhorn runtime deps.
  #  - iscsi_tcp: volume attach (Longhorn exposes each volume as a local iSCSI target)
  #  - dm_crypt + cryptsetup: encrypted volumes
  #  - nfs client (supportedFilesystems + nfs-utils): RWX volumes (share-manager exports
  #    over NFSv4.1) and NFS backup targets — Longhorn node-preflight requirement even
  #    though only RWO is used today.
  boot.kernelModules = [ "iscsi_tcp" "br_netfilter" "overlay" "dm_crypt" ];
  boot.supportedFilesystems = [ "nfs" ];  # NFSv4 client for Longhorn RWX / backup targets
  environment.systemPackages = [ pkgs.nfs-utils pkgs.openiscsi pkgs.cryptsetup ];

  # WiFi-only nodes: ensure redistributable WiFi firmware is present even if a
  # regenerated hardware.nix ever drops the not-detected.nix default.
  hardware.enableRedistributableFirmware = true;

  environment.etc."rancher/k3s/registries.yaml".source = ../assets/registries.yaml;
  environment.etc."rancher/k3s/certs/gentoo-internal-ca.crt".source =
    ../assets/gentoo-internal-ca.crt;
}
