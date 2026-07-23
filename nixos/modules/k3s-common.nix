{ pkgs, config, ... }:
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

  # Longhorn's node environment check runs `nsenter --mount=<host-ns> iscsiadm`,
  # which resolves `iscsiadm` via the host PATH (/usr/local/bin, /usr/sbin, ...).
  # NixOS keeps it in /run/current-system/sw/bin, so symlink it into standard
  # locations or Longhorn fails with "iscsiadm: No such file or directory".
  systemd.tmpfiles.rules = [
    "d /usr/local/bin 0755 root root - -"
    "d /usr/local/sbin 0755 root root - -"
    "L+ /usr/local/bin/iscsiadm  - - - - /run/current-system/sw/bin/iscsiadm"
    "L+ /usr/local/sbin/iscsiadm - - - - /run/current-system/sw/bin/iscsiadm"
  ];

  # registries.yaml carries the registry-admin password (Zot requires auth for
  # pulls), so it is rendered from a sops template rather than shipped as a static
  # asset — the plaintext secret never lands in the Nix store or git. k3s reads
  # this file only at startup to generate containerd's registry config, so k3s /
  # k3s-agent must be restarted after this file changes.
  sops.templates."registries.yaml".content = ''
    mirrors:
      registry.gentoo.lan:
        endpoint:
          - "http://registry.gentoo.lan"
    configs:
      "registry.gentoo.lan":
        auth:
          username: registry-admin
          password: ${config.sops.placeholder."registry/password"}
        tls:
          ca_file: /etc/rancher/k3s/certs/gentoo-internal-ca.crt
  '';
  environment.etc."rancher/k3s/registries.yaml".source =
    config.sops.templates."registries.yaml".path;
  environment.etc."rancher/k3s/certs/gentoo-internal-ca.crt".source =
    ../assets/gentoo-internal-ca.crt;
}
