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
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      sops-nix,
      sonar,
      ...
    }:
    let
      system = "aarch64-linux";
      mkNixOSNode = import ./lib/mkNixOSNode.nix { inherit nixpkgs sops-nix self system; };
      mkSonarNode = import ./lib/mkSonarNode.nix {
        inherit mkNixOSNode;
        inherit (nixpkgs) lib;
        sonarPackage = sonar.packages.${system}.sonar;
        # deploy-time URL uses SSH host alias (github-app) for key routing
        sonarUrl = "git+ssh://git@github-app/plural-reality/baisoku-survey";
      };
      mkCustomerPackage = import ./lib/mkCustomerPackage.nix {
        pkgs = nixpkgs.legacyPackages.${system};
      };
    in
    {
      # --- NixOS Nodes ---
      nixosConfigurations = builtins.mapAttrs mkSonarNode {
        sonar-staging = {
          domain = "staging.baisoku-survey.plural-reality.com";
          supabaseDomain = "staging-supabase.baisoku-survey.plural-reality.com";
        };
        # sonar-prod = {
        #   domain = "app.baisoku-survey.plural-reality.com";
        #   supabaseDomain = "supabase.baisoku-survey.plural-reality.com";
        # };
      } // {
        sonar-staging-bootstrap = mkNixOSNode {
          hostname = "sonar-staging";
          modules = [ ./nixos/bootstrap.nix ];
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
        packages = with nixpkgs.legacyPackages.${s}; [ terraform sops awscli2 jq curl ];
      };
    });
}
