# Polling-based self-deploy via system.autoUpgrade.
# SSH host aliases route per-repo deploy keys.
# App-agnostic — override inputs are injected from outside.
{ config, lib, ... }:
{
  imports = [ ./deploy-keys.nix ];

  options.deploy.overrideInputs = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    description = "Flake inputs to override during self-deploy. key = input name, value = flake URL.";
  };

  config = {
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

    system.autoUpgrade = {
      enable = true;
      flake = "git+ssh://git@github-infra/plural-reality/deploy#${config.networking.hostName}";
      flags =
        (lib.concatMap
          (name: [ "--override-input" name config.deploy.overrideInputs.${name} ])
          (builtins.attrNames config.deploy.overrideInputs)
        )
        ++ [
          "--refresh"
          "--option" "fallback" "false"
        ];
      dates = "minutely";
      randomizedDelaySec = "30s";
      allowReboot = false;
    };
  };
}
