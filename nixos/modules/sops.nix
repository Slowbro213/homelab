{ config, ... }:
{
  sops.defaultSopsFile = ../secrets/cluster.yaml;
  # The age key used to decrypt at runtime IS the machine's SSH host key,
  # delivered to /etc/ssh/ssh_host_ed25519_key at install via nixos-anywhere --extra-files.
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  sops.secrets."k3s/token" = { };
  sops.secrets."wifi/env" = { };
  sops.secrets."slowking/hashed-password" = { neededForUsers = true; };

  # NOTE: The machine's SSH host key at /etc/ssh/ssh_host_ed25519_key IS the age
  # identity sops uses to decrypt (sops.age.sshKeyPaths above). It is delivered as a
  # real file at install time via nixos-anywhere --extra-files and persists on the XFS
  # root across reboots/rebuilds. It must NOT be managed as a sops secret: doing so
  # replaces the real key with a symlink into /run/secrets, which is only populated by
  # decrypting *with that key* — a circular dependency that makes every secret
  # (slowking password, wifi PSK, k3s token) fail to decrypt on boot.
}
