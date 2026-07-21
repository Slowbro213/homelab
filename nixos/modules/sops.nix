{ config, ... }:
{
  sops.defaultSopsFile = ../secrets/cluster.yaml;
  # The age key used to decrypt at runtime IS the machine's SSH host key,
  # delivered to /etc/ssh/ssh_host_ed25519_key at install via nixos-anywhere --extra-files.
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  sops.secrets."k3s/token" = { };
  sops.secrets."wifi/env" = { };
  sops.secrets."slowking/hashed-password" = { neededForUsers = true; };

  # Host key also sealed per-host so `nixos-rebuild switch` can restore it if lost.
  sops.secrets."ssh_host_ed25519_key" = {
    sopsFile = ../secrets/hosts/${config.networking.hostName}.yaml;
    path = "/etc/ssh/ssh_host_ed25519_key";
    mode = "0600";
    neededForUsers = false;
  };
}
