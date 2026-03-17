# Per-app builder for Cartographer NixOS nodes.
# Signature: hostname -> { domain, efsFileSystemId, supabaseUrl, supabaseAnonKey, workosClientId, secretsFile, appRef } -> nixosSystem
{
  mkNixOSNode,
  cartographerPackages,
  lib,
}:
hostname:
{
  domain,
  efsFileSystemId,
  supabaseUrl,
  supabaseAnonKey,
  workosClientId,
  secretsFile,
  appRef,
}:
mkNixOSNode {
  inherit hostname;
  modules = [
    ../nixos/cartographer.nix
    {
      cartographer = {
        backendPackage = cartographerPackages.cartographer-backend;
        frontendPackage = cartographerPackages.cartographer-frontend;
        agentPackage = cartographerPackages.cartographer-agent;
        inherit
          domain
          efsFileSystemId
          supabaseUrl
          supabaseAnonKey
          workosClientId
          secretsFile
          ;
      };
      deploy.appSshKeyName = "cartographer";
      deploy.overrideInputs.cartographer = "git+ssh://git@github-app/plural-reality/cartographer?ref=${appRef}";
    }
  ];
}
