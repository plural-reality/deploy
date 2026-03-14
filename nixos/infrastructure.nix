{ modulesPath, ... }:

{
  imports = [
    "${modulesPath}/virtualisation/amazon-image.nix"
    ./common.nix
  ];
}
