# Customer (non-NixOS) EC2 wrapper.
# Encrypted secrets live in nix store; decrypted in-memory at runtime via IAM/KMS.
{ pkgs }:
{ name, sonarPkg, secretsFile }:
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
}
