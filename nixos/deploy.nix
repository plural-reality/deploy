# Polling-based self-deploy via system.autoUpgrade.
# Rebuilds from plural-reality/deploy#<hostname> every minute (over SSH),
# with --override-input sonar to track latest app rev.
#
# Two SSH keys are needed because GitHub deploy keys are per-repo.
# SSH host aliases route each repo to its own key.
{ config, lib, ... }:
{
  options.sonar.deploy.enable = lib.mkEnableOption "polling-based self-deploy";

  config = lib.mkIf config.sonar.deploy.enable {
    system.autoUpgrade = {
      enable = true;
      flake = "git+ssh://git@github-infra/plural-reality/deploy#${config.networking.hostName}";
      flags = [
        "--override-input" "sonar" config.sonar.inputUrl
        "--refresh"
        "--option" "fallback" "false"
      ];
      dates = "minutely";
      randomizedDelaySec = "30s";
      allowReboot = false;
    };

    programs.ssh.extraConfig = let
      mkAlias = name: identityFile: ''
        Host ${name}
          HostName github.com
          IdentityFile ${identityFile}
          IdentitiesOnly yes
          StrictHostKeyChecking accept-new
          UserKnownHostsFile /dev/null
      '';
    in lib.concatStrings [
      (mkAlias "github-infra" config.sops.secrets."deploy_ssh_key_infra".path)
      (mkAlias "github-app" config.sops.secrets."deploy_ssh_key_app".path)
    ];
  };
}
