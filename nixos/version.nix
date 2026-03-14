# NixOS Revision Endpoint
#
# Responsibilities:
#   1. Generate /etc/nixos-version.json at build time
#   2. Serve via nginx at /.well-known/version
#
# configurationRevision is set in flake.nix via self.rev or self.dirtyRev.
# Dirty trees produce "<hash>-dirty"; clean trees produce the commit hash.

{ config, pkgs, lib, inputRevisions, ... }:

let
  versionJson = builtins.toJSON {
    configurationRevision = config.system.configurationRevision or "dirty";
    inputs = inputRevisions;
    nixosVersion = config.system.nixos.version;
    hostname = config.networking.hostName;
  };

  versionFile = pkgs.writeText "nixos-version.json" versionJson;
in {
  environment.etc."nixos-version.json".source = versionFile;

  services.nginx.virtualHosts."${config.sonar.domain}" = {
    locations."= /.well-known/version" = {
      extraConfig = ''
        root /etc;
        try_files /nixos-version.json =404;
        default_type application/json;
        add_header Cache-Control "no-cache, no-store";
        add_header X-Content-Type-Options nosniff;
      '';
    };
  };
}
