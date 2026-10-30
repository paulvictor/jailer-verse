{
  description = "Jailer-verse: Free your team's cache";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = inputs.nixpkgs.lib.systems.flakeExposed;

      flake = {
        nixosModules = {
          headscale-server = ./modules/headscale.nix;
          cache-server = ./modules/cache-server.nix;
          cache-client = ./modules/cache-client.nix;
        };

        nixosConfigurations = {
          # panneer: Oracle Cloud Ampere A1 VM running headscale.
          panneer = inputs.nixpkgs.lib.nixosSystem {
            system = "aarch64-linux";
            specialArgs = {inherit inputs;};
            modules = [
              inputs.disko.nixosModules.disko
              ./modules/headscale.nix
              ./hosts/panneer
            ];
          };

          # varman: office machine running harmonia, reachable only over the tailnet.
          varman = inputs.nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            specialArgs = {inherit inputs;};
            modules = [
              ./modules/cache-server.nix
              ./hosts/varman
            ];
          };
        };
      };

      perSystem = {pkgs, ...}: {
        formatter = pkgs.alejandra;

        checks = pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          cachenet = pkgs.testers.runNixOSTest ./tests/cachenet.nix;
        };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.alejandra
            pkgs.headscale
            pkgs.nixos-anywhere
          ];
        };
      };
    };
}
