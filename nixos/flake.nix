{
  description = "gentoo k3s homelab — NixOS node configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, sops-nix, ... }:
    let
      system = "x86_64-linux";
      mkNode = hostName:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit self; };
          modules = [
            disko.nixosModules.disko
            sops-nix.nixosModules.sops
            ./modules/sops.nix
            ./modules/common.nix
            ./modules/performance.nix
            ./modules/security.nix
            ./modules/networking.nix
            ./modules/k3s-common.nix
            ./hosts/${hostName}/default.nix
            ./hosts/${hostName}/hardware.nix
            ./hosts/${hostName}/disko.nix
          ];
        };
    in
    {
      nixosConfigurations = {
        cachyos = mkNode "cachyos";
        tux = mkNode "tux";
      };
    };
}
