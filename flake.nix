{
  description = "Sonar deployment — NixOS configurations for stg/prd EC2 instances";

  inputs = {
    nixpkgs.url = "github:numtide/nixpkgs-unfree?ref=nixos-25.11";
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

      mkNode =
        {
          hostname,
          environment,
          domain,
          supabaseDomain,
          smtp,
        }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = {
            sonar-frontend = sonar.packages.${system}.sonar;
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
                inherit domain supabaseDomain smtp;
                secretsEnvironment = environment;
                deploy = {
                  enable = true;
                  nodeName = hostname;
                };
              };
            }
          ];
        };
    in
    {
      nixosConfigurations = {
        sonar-prod = mkNode {
          hostname = "sonar-prod";
          environment = "prod";
          domain = "app.baisoku-survey.plural-reality.com";
          supabaseDomain = "supabase.baisoku-survey.plural-reality.com";
          smtp = {
            host = "smtp.resend.com";
            port = 465;
            user = "resend";
            adminEmail = "noreply@plural-reality.com";
          };
        };

        sonar-staging = mkNode {
          hostname = "sonar-staging";
          environment = "staging";
          domain = "staging.baisoku-survey.plural-reality.com";
          supabaseDomain = "staging-supabase.baisoku-survey.plural-reality.com";
          smtp = {
            host = "smtp.resend.com";
            port = 465;
            user = "resend";
            adminEmail = "noreply@plural-reality.com";
          };
        };
      };
    };
}
