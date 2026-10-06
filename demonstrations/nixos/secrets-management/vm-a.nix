{ ... }:
{
  networking.hostName = "vm-a";

  environment.etc."ssh/ssh_host_ed25519_key".source = ./keys/vm-a;
  environment.etc."ssh/ssh_host_ed25519_key.pub".source = ./keys/vm-a.pub;

  # name = filename in /run/secrets/, key = which YAML key to extract
  sops.secrets."db-password" = {
    sopsFile = ./secrets/hosts/vm-a.yaml;
    key = "password";
  };
}
