{ ... }:
{
  system.stateVersion = "26.05";

  # throwaway demo VMs: log straight in as root, no password
  services.getty.autologinUser = "root";

  # tell sops-nix to derive its age identity from the machine's SSH host key,
  # injected per-VM in vm-a.nix / vm-b.nix (stand-in for nixos-anywhere --extra-files)
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  # shared secret: both VMs are recipients of demo.yaml, so both can decrypt it
  sops.secrets."api-token".sopsFile = ./secrets/demo.yaml;
}
