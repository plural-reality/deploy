# Polling-based self-deploy
# Builds from github: flake URL (no local clone), compares store paths,
# and uses switch-to-configuration test → smoke → commit for safe rollback.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.sonar.deploy;
  sshKeyPath = "/run/secrets/deploy-ssh-key";
  gitSshCommand = "${pkgs.openssh}/bin/ssh -i ${sshKeyPath} -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null";

  overrideFlags = lib.concatLists (
    lib.mapAttrsToList (name: url: [
      "--override-input"
      name
      url
    ]) cfg.appInputs
  );

  deployScript = pkgs.writeShellScript "sonar-deploy" ''
    set -euo pipefail

    /run/current-system/sw/bin/nixos-rebuild build \
      --flake "github:plural-reality/deploy/${cfg.trackBranch}#${cfg.nodeName}" \
      ${lib.concatStringsSep " " (map lib.escapeShellArg overrideFlags)} \
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
    nodeName = lib.mkOption { type = lib.types.str; };
    trackBranch = lib.mkOption {
      type = lib.types.str;
      default = "main";
    };
    appInputs = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
    };
    pollInterval = lib.mkOption {
      type = lib.types.str;
      default = "1min";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.deploy-poll = {
      description = "Poll and deploy NixOS configuration";
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
