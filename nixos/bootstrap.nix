# Minimal first-boot config — SSH keys + autoUpgrade only.
# Does NOT depend on the sonar flake input (lazy eval skips it).
# After first autoUpgrade cycle, the full config replaces this.
{ config, lib, ... }:
{
  sops = {
    age = { };
    secrets."deploy_ssh_key_infra" = {
      sopsFile = ../secrets/ssh/deploy.yaml;
      key = "deploy";
      owner = "root";
      mode = "0400";
    };
    secrets."deploy_ssh_key_app" = {
      sopsFile = ../secrets/ssh/deploy.yaml;
      key = "sonar";
      owner = "root";
      mode = "0400";
    };
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

  system.autoUpgrade = {
    enable = true;
    flake = "git+ssh://git@github-infra/plural-reality/deploy#${config.networking.hostName}";
    flags = [
      "--override-input" "sonar" "git+ssh://git@github-app/plural-reality/baisoku-survey"
      "--refresh"
      "--option" "fallback" "false"
    ];
    dates = "minutely";
    randomizedDelaySec = "30s";
    allowReboot = false;
  };
}
