# Polling-based self-deploy
# EC2 polls the deploy repo (HTTPS) and app flake inputs (SSH) for changes
# via systemd timer. On change, pulls updates and applies via nixos-rebuild switch.
# SSH deploy key is used for both ls-remote checks and nixos-rebuild --override-input.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.sonar.deploy;
  repoDir = "/var/lib/sonar-deploy/repo";
  git = "${pkgs.git}/bin/git";
  sshKeyPath = "/run/secrets/deploy-ssh-key";

  # SSH only for nix flake fetch of private app repo
  gitSshCommand = "${pkgs.openssh}/bin/ssh -i ${sshKeyPath} -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null";

  overrideFlags = lib.concatStringsSep " " (
    lib.mapAttrsToList (name: url: ''--override-input ${name} "${url}"'') cfg.appInputs
  );

  deployScript = pkgs.writeShellScript "sonar-deploy" ''
    set -euo pipefail

    LOCK=/run/sonar-deploy.lock
    exec 200>"$LOCK"
    ${pkgs.util-linux}/bin/flock -n 200 || { echo "Deploy already running, skipping"; exit 0; }

    cd "${repoDir}"

    if [ "$(${git} remote get-url origin)" != "${cfg.repoUrl}" ]; then
      ${git} remote set-url origin "${cfg.repoUrl}"
    fi

    ${git} fetch origin
    ${git} checkout "${cfg.trackBranch}"
    ${git} pull origin "${cfg.trackBranch}" --ff-only

    # Record current generation for rollback
    PREV_SYSTEM=$(readlink /run/current-system)
    echo "=== Previous generation: $PREV_SYSTEM ==="

    echo "=== Building NixOS configuration: ${cfg.nodeName} ==="
    GIT_SSH_COMMAND="${gitSshCommand}" \
      /run/current-system/sw/bin/nixos-rebuild switch \
        --flake "${repoDir}#${cfg.nodeName}" \
        ${overrideFlags}

    echo "=== Restarting Supabase ==="
    ${pkgs.systemd}/bin/systemctl restart supabase.service

    echo "=== Smoke test ==="
    sleep 5
    if ! ${pkgs.curl}/bin/curl -sf --max-time 30 --retry 3 --retry-delay 5 \
        http://localhost:3000; then
      echo "ERROR: Smoke test failed. Rolling back to previous generation..."
      "$PREV_SYSTEM/bin/switch-to-configuration" switch
      echo "Rollback complete. Previous generation restored."
      exit 1
    fi

    echo "=== Deploy complete at $(date -Iseconds). Smoke test passed. ==="
  '';

  # Exits 0 if any appInputs flake input has a newer commit than what's deployed.
  # Compares git ls-remote HEAD against inputRevisions in /etc/nixos-version.json.
  checkInputsScript = pkgs.writeShellScript "check-app-inputs" ''
    set -euo pipefail
    export GIT_SSH_COMMAND="${gitSshCommand}"
    ${lib.concatStrings (lib.mapAttrsToList (name: url:
      let gitUrl = lib.removePrefix "git+" url; in ''
    REMOTE=$(${git} ls-remote "${gitUrl}" HEAD 2>/dev/null | ${pkgs.coreutils}/bin/cut -f1 || echo "unknown")
    DEPLOYED=$(${pkgs.jq}/bin/jq -r '.inputs.${name} // "unknown"' /etc/nixos-version.json 2>/dev/null || echo "unknown")
    [ "$REMOTE" = "unknown" ] || [ "$REMOTE" = "$DEPLOYED" ] || { echo "${name}: $DEPLOYED -> $REMOTE"; exit 0; }
    '') cfg.appInputs)}
    exit 1
  '';

  pollScript = pkgs.writeShellScript "deploy-poll" ''
    set -euo pipefail
    cd "${repoDir}"

    CHANGED=false

    # Check deploy repo for new commits
    ${git} fetch origin
    LOCAL=$(${git} rev-parse HEAD)
    REMOTE=$(${git} rev-parse "origin/${cfg.trackBranch}")
    [ "$LOCAL" = "$REMOTE" ] || { echo "Deploy repo changed: $LOCAL -> $REMOTE"; CHANGED=true; }

    # Check app flake inputs for new commits
    ${checkInputsScript} && { echo "App input changed"; CHANGED=true; } || true

    $CHANGED || { echo "No changes (deploy: $LOCAL, inputs: current)"; exit 0; }
    exec ${deployScript}
  '';
in
{
  options.sonar.deploy = {
    enable = lib.mkEnableOption "polling-based self-deploy";

    nodeName = lib.mkOption {
      type = lib.types.str;
      description = "NixOS configuration name for nixos-rebuild";
      example = "sonar-prod";
    };

    trackBranch = lib.mkOption {
      type = lib.types.str;
      default = "main";
      description = "Remote branch to track for changes";
    };

    repoUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/plural-reality/deploy.git";
      description = "Git repository URL (public, no auth needed)";
    };

    appInputs = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Flake inputs to override with latest (input name -> flake URL)";
      example = {
        sonar = "git+ssh://git@github.com/plural-reality/baisoku-survey";
      };
    };

    pollInterval = lib.mkOption {
      type = lib.types.str;
      default = "5min";
      description = "How often to poll for changes";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.deploy-repo-init = {
      description = "Clone deploy repo for self-deploy";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "clone-repo" ''
          set -euo pipefail
          if [ -d "${repoDir}/.git" ]; then
            cd "${repoDir}"
            if [ "$(${git} remote get-url origin)" != "${cfg.repoUrl}" ]; then
              ${git} remote set-url origin "${cfg.repoUrl}"
            fi
            echo "Repo already cloned at ${repoDir}"
            exit 0
          fi
          ${pkgs.coreutils}/bin/mkdir -p "$(dirname "${repoDir}")"
          ${git} clone "${cfg.repoUrl}" "${repoDir}"
          echo "Repo cloned to ${repoDir}"
        '';
      };
    };

    systemd.services.deploy-poll = {
      description = "Poll deploy repo and apply changes";
      after = [
        "network-online.target"
        "deploy-repo-init.service"
      ];
      wants = [ "network-online.target" ];
      requires = [ "deploy-repo-init.service" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = pollScript;
      };
    };

    systemd.timers.deploy-poll = {
      description = "Poll deploy repo for changes";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = cfg.pollInterval;
        RandomizedDelaySec = "30s";
      };
    };
  };
}
