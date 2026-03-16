# Per-app builder for Sonar NixOS nodes.
# Signature: hostname -> { domain, supabaseDomain } -> nixosSystem
# environment is derived from hostname by stripping "sonar-" prefix.
{
  mkNixOSNode,
  sonarPackage,
  sonarUrl,
  lib,
}:
hostname:
{ domain, supabaseDomain }:
mkNixOSNode {
  inherit hostname;
  modules = [
    ../nixos/sonar.nix
    {
      sonar = {
        package = sonarPackage;
        inputUrl = sonarUrl;
        supabaseSource = ../supabase;
        inherit domain supabaseDomain;
        secretsEnvironment = lib.removePrefix "sonar-" hostname;
        deploy.enable = true;
      };
    }
  ];
}
