# Polling-based self-deploy
# Every pollInterval, rebuilds from github:plural-reality/deploy#<hostname>
# with --override-input sonar to track latest app rev.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.sonar.deploy;
  hostname = config.networking.hostName;
  sshKeyPath = "/run/secrets/deploy-ssh-key";
  gitSshCommand = "${pkgs.openssh}/bin/ssh -i ${sshKeyPath} -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null";

  flakeRef = "github:plural-reality/deploy#${hostname}";

  deployScript = pkgs.writeShellScript "sonar-deploy" ''
    set -euo pipefail

    rebuild() {
      ${pkgs.nixos-rebuild}/bin/nixos-rebuild "$@" \
        --flake ${lib.escapeShellArg flakeRef} \
        --override-input sonar ${lib.escapeShellArg config.sonar.inputUrl}
    }

    rebuild build --refresh

    [ "$(readlink -f result)" = "$(readlink -f /run/current-system)" ] && { echo "No changes"; exit 0; }

    rebuild switch
  '';
in
{
  options.sonar.deploy = {
    enable = lib.mkEnableOption "polling-based self-deploy";
    pollInterval = lib.mkOption {
      type = lib.types.str;
      default = "1min";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.deploy-poll = {
      description = "Poll and deploy ${hostname}";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment.GIT_SSH_COMMAND = gitSshCommand;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = deployScript;
        StateDirectory = "sonar-deploy";
        WorkingDirectory = "/var/lib/sonar-deploy";
      };
    };

    systemd.timers.deploy-poll = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = cfg.pollInterval;
        RandomizedDelaySec = "30s";
      };
    };
  };
}
