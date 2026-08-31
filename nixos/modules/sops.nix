{ config, ... }:
{
  sops.defaultSopsFile = ../secrets/cluster.yaml;
  # The age key used to decrypt at runtime IS the machine's SSH host key,
  # delivered to /etc/ssh/ssh_host_ed25519_key at install via nixos-anywhere --extra-files.
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  sops.secrets."k3s/token" = { };
  # nixos-26.05's wpa_supplicant module hardened its systemd unit to run
  # unprivileged (User=wpa_supplicant, ProtectSystem=strict) instead of root.
  # It still BindReadOnlyPaths= this file in, but can't open a root-only 0400
  # file as that user — group-read for wpa_supplicant is required as of 26.05.
  # The group doesn't exist pre-26.05 (older wpa_supplicant module ran as
  # root), so guard it — this keeps the module buildable if ever rolled back
  # to an older generation, same as nixos-25.11 currently is.
  sops.secrets."wifi/env" = {
    group = if (config.users.groups ? wpa_supplicant) then "wpa_supplicant" else "root";
    mode = "0440";
  };
  sops.secrets."slowking/hashed-password" = { neededForUsers = true; };
  # registry-admin password for pulling from the internal Zot registry
  # (registry.gentoo.lan). Rendered into /etc/rancher/k3s/registries.yaml via a
  # sops template in k3s-common.nix — Zot requires auth for reads (no anonymous
  # pull policy), so kubelet must present these creds or every internal image
  # pull fails with 401 ImagePullBackOff.
  sops.secrets."registry/password" = { };

  # NOTE: The machine's SSH host key at /etc/ssh/ssh_host_ed25519_key IS the age
  # identity sops uses to decrypt (sops.age.sshKeyPaths above). It is delivered as a
  # real file at install time via nixos-anywhere --extra-files and persists on the XFS
  # root across reboots/rebuilds. It must NOT be managed as a sops secret: doing so
  # replaces the real key with a symlink into /run/secrets, which is only populated by
  # decrypting *with that key* — a circular dependency that makes every secret
  # (slowking password, wifi PSK, k3s token) fail to decrypt on boot.
}
