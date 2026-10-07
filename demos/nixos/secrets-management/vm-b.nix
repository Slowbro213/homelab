{ ... }:
{
  networking.hostName = "vm-b";

  environment.etc."ssh/ssh_host_ed25519_key".source = ./keys/vm-b;
  environment.etc."ssh/ssh_host_ed25519_key.pub".source = ./keys/vm-b.pub;

  # vm-b IS a recipient of this file
  sops.secrets."db-password" = {
    sopsFile = ./secrets/hosts/vm-b.yaml;
    key = "password";
  };
}
