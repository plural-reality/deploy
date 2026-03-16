# Polling-based self-deploy via system.autoUpgrade.
# Rebuilds from github:plural-reality/deploy#<hostname> every minute,
# with --override-input sonar to track latest app rev.
{ config, lib, pkgs, ... }:
{
  options.sonar.deploy.enable = lib.mkEnableOption "polling-based self-deploy";

  config = lib.mkIf config.sonar.deploy.enable {
    system.autoUpgrade = {
      enable = true;
      flake = "github:plural-reality/deploy#${config.networking.hostName}";
      flags = [
        "--override-input" "sonar" config.sonar.inputUrl
        "--refresh"
        "--option" "fallback" "false"
      ];
      dates = "minutely";
      randomizedDelaySec = "30s";
      allowReboot = false;
    };

    systemd.services.nixos-upgrade.environment.GIT_SSH_COMMAND =
      "${pkgs.openssh}/bin/ssh -i ${config.sops.secrets."deploy_ssh_key".path} -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null";
  };
}
