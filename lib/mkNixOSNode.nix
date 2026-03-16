# Generic NixOS node builder — no app knowledge.
# Provides: sops-nix, EC2 infrastructure, hostname, configurationRevision.
# App-specific modules are composed via the `modules` parameter.
{
  nixpkgs,
  sops-nix,
  self,
  system,
}:
{ hostname, modules ? [] }:
nixpkgs.lib.nixosSystem {
  inherit system;
  modules = [
    sops-nix.nixosModules.sops
    ../nixos/infrastructure.nix
    {
      networking.hostName = hostname;
      system.configurationRevision = self.rev or self.dirtyRev or "dirty";
    }
  ] ++ modules;
}
