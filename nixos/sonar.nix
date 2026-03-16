# Sonar application module — bundles all Sonar-specific NixOS modules
# and defines options for injecting the app package and related inputs.
{ lib, ... }:
{
  imports = [
    ./application.nix
    ./deploy.nix
    ./secrets.nix
    ./version.nix
  ];

  options.sonar = {
    package = lib.mkOption {
      type = lib.types.package;
      description = "Sonar application package";
    };

    inputUrl = lib.mkOption {
      type = lib.types.str;
      description = "Flake URL of the sonar input (for --override-input in self-deploy)";
    };

    supabaseSource = lib.mkOption {
      type = lib.types.path;
      description = "Path to supabase configuration directory";
    };
  };
}
