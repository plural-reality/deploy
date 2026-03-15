{
  description = "Sonar deployment — NixOS configurations for stg/prd EC2 instances";

  inputs = {
    nixpkgs.url = "github:numtide/nixpkgs-unfree?ref=nixos-unstable";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # App repo provides packages.sonar — the production Next.js build artifact.
    # Don't follows nixpkgs: let app use its own pin for build reproducibility.
    sonar.url = "github:plural-reality/baisoku-survey";
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

      mkNode =
        {
          hostname,
          environment,
          domain,
          supabaseDomain,
          refPattern ? "^refs/heads/main$",
        }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = {
            sonar-frontend = sonar.packages.${system}.sonar;
            inherit (sonar) envContract;
            inputRevisions = builtins.mapAttrs (_: i: i.rev or i.dirtyRev or "unknown") {
              inherit sonar nixpkgs sops-nix;
            };
          };
          modules = [
            sops-nix.nixosModules.sops
            ./nixos/infrastructure.nix
            ./nixos/application.nix
            ./nixos/deploy.nix
            ./nixos/secrets.nix
            ./nixos/version.nix
            {
              networking.hostName = hostname;
              system.configurationRevision = self.rev or self.dirtyRev or "dirty";

              sonar = {
                inherit domain supabaseDomain;
                secretsEnvironment = environment;
                deploy = {
                  enable = true;
                  nodeName = hostname;
                  inherit refPattern;
                  appInputs = {
                    sonar = "github:plural-reality/baisoku-survey";
                  };
                };
              };
            }
          ];
        };

      # Customer (non-NixOS) EC2: sonar wrapped with sops exec-env.
      # Encrypted secrets live in nix store; decrypted in-memory at runtime via IAM/KMS.
      mkCustomerPackage =
        {
          name,
          secretsFile,
        }:
        let
          sonarPkg = sonar.packages.${system}.sonar;
        in
        pkgs.writeShellApplication {
          name = "sonar-${name}";
          runtimeInputs = [
            pkgs.sops
            pkgs.nodejs_22
          ];
          text = ''
            export NODE_ENV=production
            export PORT=''${PORT:-3000}
            export HOSTNAME=''${HOSTNAME:-0.0.0.0}
            exec sops exec-env ${secretsFile} "node ${sonarPkg}/app/server.js"
          '';
        };
      nodeDefinitions = {
        sonar-prod = {
          hostname = "sonar-prod";
          environment = "prod";
          domain = "app.baisoku-survey.plural-reality.com";
          supabaseDomain = "supabase.baisoku-survey.plural-reality.com";
          refPattern = "^refs/tags/v";
        };
        sonar-staging = {
          hostname = "sonar-staging";
          environment = "staging";
          domain = "staging.baisoku-survey.plural-reality.com";
          supabaseDomain = "staging-supabase.baisoku-survey.plural-reality.com";
        };
      };
    in
    {
      nixosConfigurations = builtins.mapAttrs (_: cfg: mkNode cfg) nodeDefinitions;

      packages.${system} = {
        cybozu-prd = mkCustomerPackage {
          name = "cybozu-prd";
          secretsFile = ./secrets/cybozu-prd.yaml;
        };
      };

      # Lightweight metadata for tooling — evaluates without building NixOS configs.
      meta.nodes = builtins.mapAttrs (_: cfg: { inherit (cfg) domain; }) nodeDefinitions;
    };
}
