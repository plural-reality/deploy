{
  description = "Plural Reality deployment — NixOS + customer EC2 configurations";

  inputs = {
    nixpkgs.url = "github:numtide/nixpkgs-unfree?ref=nixos-unstable";
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
      sops-nix,
      sonar,
      ...
    }:
    let
      system = "aarch64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      mkNixOSNode = import ./lib/mkNixOSNode.nix { inherit nixpkgs sops-nix self system; };
      mkCustomerPackage = import ./lib/mkCustomerPackage.nix { inherit pkgs; };

      sonarNodes = {
        # sonar-prod = {
        #   environment = "prod";
        #   domain = "app.baisoku-survey.plural-reality.com";
        #   supabaseDomain = "supabase.baisoku-survey.plural-reality.com";
        # };
        sonar-staging = {
          environment = "staging";
          domain = "staging.baisoku-survey.plural-reality.com";
          supabaseDomain = "staging-supabase.baisoku-survey.plural-reality.com";
        };
      };
    in
    {
      # --- NixOS Nodes ---
      nixosConfigurations = builtins.mapAttrs (
        hostname: cfg:
        mkNixOSNode {
          inherit hostname;
          modules = [
            ./nixos/sonar.nix
            {
              sonar = {
                package = sonar.packages.${system}.sonar;
                inputUrl = sonar.url;
                supabaseSource = ./supabase;
                inherit (cfg) domain supabaseDomain;
                secretsEnvironment = cfg.environment;
                deploy.enable = true;
              };
            }
          ];
        }
      ) sonarNodes;

      # --- Customer (non-NixOS) Packages ---
      packages.${system} = {
        cybozu-prd = mkCustomerPackage {
          name = "cybozu-prd";
          sonarPkg = sonar.packages.${system}.sonar;
          secretsFile = ./secrets/cybozu-prd.yaml;
        };
      };

      # Lightweight metadata for tooling — evaluates without building NixOS configs.
      meta.nodes = builtins.mapAttrs (_: cfg: { inherit (cfg) domain; }) sonarNodes;

      # --- Dev Shells ---
      devShells = builtins.listToAttrs (
        builtins.map (s: {
          name = s;
          value.default =
            let
              p = nixpkgs.legacyPackages.${s};
            in
            p.mkShell {
              packages = [
                p.terraform
                p.sops
                p.awscli2
                p.jq
                p.curl
              ];
              shellHook = ''
                echo "deploy devshell — terraform sops awscli2 jq curl"
              '';
            };
        }) [
          "aarch64-darwin"
          "x86_64-darwin"
          "aarch64-linux"
          "x86_64-linux"
        ]
      );
    };
}
