{ config, pkgs, lib, ... }:
let
  adminKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFzUvw59McgsCCf+ucUaclE6M9C/UKIQ1YdwF7eoYQs+ vboxuser@virtualbox"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINirl801uWMh5QFXNwZXZ2phVm21JtrQ5eXnxu8ZQlUo slowking@registry"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL9Mv/9PY7JNEY14lzzbVYxiODeGRCClZQRoNIhxqjTe thanas.papa.24@gmail.com"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJLAOt1EjmWI+de0iV9dDoc/Avw3kM6bA1uIANluBVbV thanas.papa.24@gmail.com"
  ];
in
{
  time.timeZone = "Europe/Athens";
  i18n.defaultLocale = "en_US.UTF-8";

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
    trusted-users = [ "root" "deploy" ];
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  users.mutableUsers = false;

  users.users.slowking = {
    isNormalUser = true;
    uid = 1000;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = adminKeys;
    # Interactive password sudo for hands-on admin; hash delivered via sops (Task 8).
    hashedPasswordFile = config.sops.secrets."slowking/hashed-password".path;
  };

  users.users.deploy = {
    isNormalUser = true;
    uid = 1001;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [ (lib.strings.trim (builtins.readFile ../keys/deploy.pub)) ];
  };

  # deploy may run nixos-rebuild's activation non-interactively.
  security.sudo.extraRules = [{
    users = [ "deploy" ];
    commands = [{ command = "ALL"; options = [ "NOPASSWD" ]; }];
  }];

  environment.systemPackages = with pkgs; [
    git vim htop btop tmux iproute2 iptables ethtool pciutils usbutils
    dnsutils curl jq fastfetch aha
  ];
}
