# Polling-based self-deploy
# Every pollInterval, rebuilds from github:plural-reality/deploy#<hostname>
# with --override-input sonar to track latest app rev.
# Uses switch-to-configuration test → smoke → commit for safe rollback.
{
  config,
  lib,
  pkgs,
  sonarInputUrl,
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

    /run/current-system/sw/bin/nixos-rebuild build \
      --flake ${lib.escapeShellArg flakeRef} \
      --override-input sonar ${lib.escapeShellArg sonarInputUrl} \
      --refresh

    NEW=$(readlink -f result)
    CURRENT=$(readlink -f /run/current-system)

    [ "$NEW" = "$CURRENT" ] && { echo "No changes"; exit 0; }
    echo "=== Change: $CURRENT -> $NEW ==="

    "$NEW/bin/switch-to-configuration" test

    sleep 5
    ${pkgs.curl}/bin/curl -sf --max-time 30 --retry 3 --retry-delay 5 \
      http://localhost:3000 || {
        echo "ERROR: Smoke test failed. Rolling back..."
        "$CURRENT/bin/switch-to-configuration" switch
        exit 1
      }

    ${pkgs.nix}/bin/nix-env --profile /nix/var/nix/profiles/system --set "$NEW"
    "$NEW/bin/switch-to-configuration" switch
    echo "=== Deploy complete at $(date -Iseconds) ==="
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
