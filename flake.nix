{
  description = "Generic NixOS Jellyfin media server configuration with Arr stack";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    mkdocs-catppuccin = {
      url = "github:ruslanlap/mkdocs-catppuccin";
      flake = false;
    };
    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-anywhere = {
      url = "github:nix-community/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      treefmt-nix,
      microvm,
      nixos-anywhere,
      sops-nix,
      ...
    }@inputs:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        f:
        lib.genAttrs systems (
          system:
          f rec {
            inherit system lib;
            pkgs = import nixpkgs {
              inherit system;
              config.allowUnfree = true;
              config.allowUnfreePredicate = _: true;
            };
            treefmt = treefmt-nix.lib.evalModule pkgs ./treefmt.nix;
          }
        );
    in
    {
      nixosModules.default = import ./modules;
      nixosModules.nixflix = import ./modules;
      nixosModules.microvm = import ./modules/microvm { inherit microvm; };

      # Disko disk layout for Hetzner deployment.
      # Consumers: include disko.nixosModules.disko + diskoConfigurations.hetzner
      # in a nixosConfiguration, or run nixos-anywhere with --flake .#hetzner-host.
      diskoConfigurations.hetzner = import ./deploy/hetzner/disko.nix;

      # ---------------------------------------------------------------------------
      # nixosConfigurations — deployable host configs
      # ---------------------------------------------------------------------------

      # Bare-metal Hetzner server running the representative nixflix stack.
      # Deploy with nixos-anywhere:
      #   nix run .#deploy-hetzner-bare -- root@<ip>
      #
      # Required before first deploy:
      #   1. Generate a host age key (see deploy/secrets/README.md)
      #   2. Set sshPublicKeys below to your real SSH public key(s)
      #   3. Set nginx.domain to your real domain
      nixosConfigurations.hetzner-bare = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {
          hostName = "hetzner-bare";
          # Add your SSH public key(s) here before deploying.
          sshKeys = [
            # "ssh-ed25519 AAAA... user@host"
          ];
        };
        modules = [
          disko.nixosModules.disko
          ./deploy/hetzner/disko.nix
          sops-nix.nixosModules.sops
          self.nixosModules.nixflix
          ./deploy/configs/hetzner-bare.nix
        ];
      };


      packages = perSystem (
        {
          system,
          pkgs,
          ...
        }:
        (import ./docs { inherit pkgs inputs; })
        // {
          default = self.packages.${system}.docs;
        }
      );

      apps = perSystem (
        {
          system,
          pkgs,
          ...
        }:
        {
          docs-serve = {
            type = "app";
            program = toString (
              pkgs.writeShellScript "docs-serve" ''
                echo "Starting documentation server from ${self.packages.${system}.docs}"
                ${pkgs.python3}/bin/python3 -m http.server --directory ${self.packages.${system}.docs} 8000
              ''
            );
          };
          deploy = {
            type = "app";
            program = toString (
              pkgs.writeShellScript "deploy" ''
                export PATH="${
                  lib.makeBinPath [
                    nixos-anywhere.packages.${system}.nixos-anywhere
                    pkgs.openssh
                  ]
                }:$PATH"
                exec ${self}/deploy/scripts/deploy.sh "$@"
              ''
            );
          };
        }
      );

      formatter = perSystem ({ treefmt, ... }: treefmt.config.build.wrapper);

      checks = perSystem (
        {
          treefmt,
          lib,
          pkgs,
          system,
          ...
        }:
        let
          tests = import ./tests {
            inherit system pkgs lib;
            nixosModules = self.nixosModules.default;
            microvmModules = self.nixosModules.microvm;
          };
        in
        {
          formatting = treefmt.config.build.check self;
          docs-build = self.packages.${system}.docs;
        }
        // tests.vm-tests
        // tests.unit-tests
      );

      devShells = perSystem (
        {
          pkgs,
          treefmt,
          ...
        }:
        {
          default = pkgs.mkShell {
            nativeBuildInputs = [
              treefmt.config.build.wrapper
            ]
            ++ (lib.attrValues treefmt.config.build.programs);

            shellHook = ''
              echo "🎬 Nixflix Development Shell"
              echo ""
              echo "Documentation Commands:"
              echo "  nix build .#docs        - Build documentation"
              echo "  nix run .#docs-serve    - Serve docs"
              echo "  nix fmt                 - Format code"
              echo ""
            '';
          };
        }
      );
    };
}
