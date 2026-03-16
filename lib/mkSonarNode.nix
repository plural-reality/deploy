# Per-app builder for Sonar NixOS nodes.
# Encapsulates all Sonar-specific wiring: modules, package, deploy, supabase.
{
  mkNixOSNode,
  sonarPackage,
  sonarInputUrl,
}:
{ hostname, environment, domain, supabaseDomain }:
mkNixOSNode {
  inherit hostname;
  modules = [
    ../nixos/sonar.nix
    {
      sonar = {
        package = sonarPackage;
        inputUrl = sonarInputUrl;
        supabaseSource = ../supabase;
        inherit domain supabaseDomain;
        secretsEnvironment = environment;
        deploy.enable = true;
      };
    }
  ];
}
