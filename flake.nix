{
  description = "Sonar deployment — NixOS configurations for stg/prd EC2 instances";

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

      # Generic NixOS node builder — no app knowledge.
      mkNixOSNode =
        { hostname, modules ? [] }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            sops-nix.nixosModules.sops
            ./nixos/infrastructure.nix
            {
              networking.hostName = hostname;
              system.configurationRevision = self.rev or self.dirtyRev or "dirty";
            }
          ] ++ modules;
        };

      # Per-environment data for Sonar NixOS nodes.
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
      devSystems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
    in
    {
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

      packages.${system} = {
        cybozu-prd = mkCustomerPackage {
          name = "cybozu-prd";
          secretsFile = ./secrets/cybozu-prd.yaml;
        };
      };

      # Lightweight metadata for tooling — evaluates without building NixOS configs.
      meta.nodes = builtins.mapAttrs (_: cfg: { inherit (cfg) domain; }) sonarNodes;

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
        }) devSystems
      );
    };
}
