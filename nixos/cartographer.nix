# Cartographer application module — bundles all Cartographer-specific NixOS modules
# and defines options for injecting app packages and related inputs.
{ lib, ... }:
{
  imports = [
    ./cartographer-application.nix
    ./cartographer-secrets.nix
    ./deploy.nix
  ];

  options.cartographer = {
    backendPackage = lib.mkOption {
      type = lib.types.package;
      description = "Cartographer Haskell backend package";
    };

    frontendPackage = lib.mkOption {
      type = lib.types.package;
      description = "Cartographer Next.js frontend package";
    };

    agentPackage = lib.mkOption {
      type = lib.types.package;
      description = "Cartographer agent package";
    };

    domain = lib.mkOption {
      type = lib.types.str;
      description = "Domain name for the application";
    };

    efsFileSystemId = lib.mkOption {
      type = lib.types.str;
      description = "EFS file system ID for M36 data";
    };

    supabaseUrl = lib.mkOption {
      type = lib.types.str;
      description = "External Supabase project URL";
    };

    supabaseAnonKey = lib.mkOption {
      type = lib.types.str;
      description = "External Supabase anon key (public)";
    };

    workosClientId = lib.mkOption {
      type = lib.types.str;
      description = "WorkOS client ID (non-secret)";
    };

    secretsFile = lib.mkOption {
      type = lib.types.path;
      description = "SOPS YAML file for this environment's secrets";
    };
  };
}
