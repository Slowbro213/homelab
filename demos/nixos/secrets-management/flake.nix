{
  description = "sops-nix secrets management demo: devShell + two local VMs";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, sops-nix, ... }: let
    # system should match the system you are running on
    system = "x86_64-linux";

    mkVm = hostName:
      nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          sops-nix.nixosModules.sops
          ./vm-common.nix
          ./vm-${hostName}.nix
        ];
      };
  in {
    devShells."${system}".default = let
      pkgs = import nixpkgs { inherit system; };
    in pkgs.mkShell {
      packages = with pkgs; [
          sops
          age
          ssh-to-age
      ];

      shellHook = ''
        echo "You've entered the dev environment for the sops-nix secrets demo!"
      '';
    };

    nixosConfigurations = {
      vm-a = mkVm "a";
      vm-b = mkVm "b";
    };
  };
}
