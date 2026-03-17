{
  description = "Plural Reality deployment — NixOS + customer EC2 configurations";

  inputs = {
    nixpkgs.url = "github:numtide/nixpkgs-unfree?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sonar.url = "git+ssh://git@github.com/plural-reality/baisoku-survey";
    cartographer.url = "git+ssh://git@github.com/plural-reality/cartographer";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      sops-nix,
      sonar,
      cartographer,
      ...
    }:
    let
      system = "aarch64-linux";
      mkNixOSNode = import ./lib/mkNixOSNode.nix {
        inherit
          nixpkgs
          sops-nix
          self
          system
          ;
      };
      mkSonarNode = import ./lib/mkSonarNode.nix {
        inherit mkNixOSNode;
        inherit (nixpkgs) lib;
        sonarPackage = sonar.packages.${system}.sonar;
      };
      mkCartographerNode = import ./lib/mkCartographerNode.nix {
        inherit mkNixOSNode;
        inherit (nixpkgs) lib;
        cartographerPackages = cartographer.packages.${system};
      };
      mkCustomerPackage = import ./lib/mkCustomerPackage.nix {
        pkgs = nixpkgs.legacyPackages.${system};
      };
    in
    {
      # --- NixOS Nodes ---
      nixosConfigurations =
        builtins.mapAttrs mkSonarNode {
          sonar-staging = {
            domain = "staging.baisoku-survey.plural-reality.com";
            supabaseDomain = "staging-supabase.baisoku-survey.plural-reality.com";
            secretsFile = ./secrets/sonar/stg.yaml;
            appRef = "main";
          };
          # sonar-prod = {
          #   domain = "app.baisoku-survey.plural-reality.com";
          #   supabaseDomain = "supabase.baisoku-survey.plural-reality.com";
          #   secretsFile = ./secrets/sonar/prd.yaml;
          #   appRef = "stable";
          # };
        }
        // builtins.mapAttrs mkCartographerNode {
          cartographer-staging = {
            domain = "staging.baisoku-kaigi.com";
            efsFileSystemId = "fs-0a3f1c8ae1d63c51b";
            supabaseUrl = "https://uyuyqdhssttxswmflzrx.supabase.co";
            supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InV5dXlxZGhzc3R0eHN3bWZsenJ4Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjE0MjU1MDgsImV4cCI6MjA3NzAwMTUwOH0.u7iVjncFD_p_9CClxEQ4heejvbmEHFDFfDTG2VoyYXM";
            workosClientId = "";
            secretsFile = ./secrets/cartographer/stg.yaml;
            appRef = "main";
          };
          # cartographer-prod = {
          #   domain = "app.baisoku-kaigi.com";
          #   efsFileSystemId = "fs-TODO";
          #   supabaseUrl = "https://TODO.supabase.co";
          #   supabaseAnonKey = "TODO";
          #   workosClientId = "TODO";
          #   secretsFile = ./secrets/cartographer/prd.yaml;
          #   appRef = "stable";
          # };
        }
        // {
          sonar-staging-bootstrap = mkNixOSNode {
            hostname = "sonar-staging";
            modules = [
              ./nixos/deploy.nix
              {
                deploy.overrideInputs.sonar = "git+ssh://git@github-app/plural-reality/baisoku-survey?ref=main";
              }
            ];
          };
          cartographer-staging-bootstrap = mkNixOSNode {
            hostname = "cartographer-staging";
            modules = [
              ./nixos/deploy.nix
              {
                deploy.appSshKeyName = "cartographer";
                deploy.overrideInputs.cartographer = "git+ssh://git@github-app/plural-reality/cartographer?ref=main";
              }
            ];
          };
        };

      # --- Customer (non-NixOS) Packages ---
      packages.${system}.cybozu-prd = mkCustomerPackage {
        name = "cybozu-prd";
        sonarPkg = sonar.packages.${system}.sonar;
        secretsFile = ./secrets/cybozu-prd.yaml;
      };
    }
    // flake-utils.lib.eachDefaultSystem (s: {
      devShells.default = nixpkgs.legacyPackages.${s}.mkShell {
        packages = with nixpkgs.legacyPackages.${s}; [
          terraform
          sops
          awscli2
          jq
          curl
        ];
      };
    });
}
