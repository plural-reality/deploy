# Per-app builder for Sonar NixOS nodes.
# Signature: hostname -> { domain, supabaseDomain, secretsFile, appRef } -> nixosSystem
{
  mkNixOSNode,
  sonarPackage,
  sonarMigrations,
  lib,
}:
hostname:
{
  domain,
  supabaseDomain,
  secretsFile,
  appRef,
}:
mkNixOSNode {
  inherit hostname;
  modules = [
    ../nixos/sonar.nix
    {
      sonar = {
        package = sonarPackage;
        supabaseSource = ../supabase;
        supabaseMigrations = sonarMigrations;
        inherit domain supabaseDomain secretsFile;
      };
      deploy.overrideInputs.sonar = "git+ssh://git@github-app/plural-reality/baisoku-survey?ref=${appRef}";
    }
  ];
}
