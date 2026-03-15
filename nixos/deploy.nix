# Polling-based self-deploy
# EC2 polls the deploy repo for changes via systemd timer,
# pulls via GitHub App installation tokens, and applies via nixos-rebuild switch.
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

  # Generate a short-lived GitHub App installation token from SOPS credentials.
  # Outputs the token to stdout. Used by both git operations and nix flake fetching.
  generateGitHubToken = pkgs.writeShellScript "generate-github-token" ''
    set -euo pipefail
    b64url() {
      ${pkgs.openssl}/bin/openssl base64 -A \
        | ${pkgs.coreutils}/bin/tr '+/' '-_' \
        | ${pkgs.coreutils}/bin/tr -d '='
    }
    APP_ID=$(${pkgs.coreutils}/bin/cat /run/secrets/github-app-id)
    INSTALLATION_ID=$(${pkgs.coreutils}/bin/cat /run/secrets/github-app-installation-id)
    NOW=$(${pkgs.coreutils}/bin/date +%s)
    HEADER=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
    PAYLOAD=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$((NOW - 60))" "$((NOW + 540))" "$APP_ID" | b64url)
    UNSIGNED="$HEADER.$PAYLOAD"
    SIGNATURE=$(printf '%s' "$UNSIGNED" \
      | ${pkgs.openssl}/bin/openssl dgst -binary -sha256 -sign /run/secrets/github-app-private-key \
      | b64url)
    JWT="$UNSIGNED.$SIGNATURE"
    ${pkgs.curl}/bin/curl -fsSL \
      -X POST \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $JWT" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/app/installations/$INSTALLATION_ID/access_tokens" \
        | ${pkgs.jq}/bin/jq -re '.token'
  '';

  gitWithGitHubApp = pkgs.writeShellScript "git-with-github-app" ''
    set -euo pipefail
    GITHUB_APP_TOKEN=$(${generateGitHubToken})
    ASKPASS=$(${pkgs.coreutils}/bin/mktemp)
    cleanup() {
      ${pkgs.coreutils}/bin/rm -f "$ASKPASS"
    }
    trap cleanup EXIT
    ${pkgs.coreutils}/bin/cat > "$ASKPASS" <<'EOF'
#!/bin/sh
case "$1" in
  *Username*) printf '%s\n' "x-access-token" ;;
  *Password*) printf '%s\n' "$GITHUB_APP_TOKEN" ;;
  *) exit 1 ;;
esac
EOF
    ${pkgs.coreutils}/bin/chmod 700 "$ASKPASS"
    export GITHUB_APP_TOKEN
    export GIT_ASKPASS="$ASKPASS"
    export GIT_TERMINAL_PROMPT=0
    exec "$@"
  '';

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

    ${gitWithGitHubApp} ${git} fetch origin

    ${git} checkout "${cfg.trackBranch}"
    ${gitWithGitHubApp} ${git} pull origin "${cfg.trackBranch}" --ff-only

    # Record current generation for rollback
    PREV_SYSTEM=$(readlink /run/current-system)
    echo "=== Previous generation: $PREV_SYSTEM ==="

    echo "=== Generating GitHub App token for nix ==="
    NIX_GITHUB_TOKEN=$(${generateGitHubToken})
    NIX_ACCESS="--option access-tokens github.com=$NIX_GITHUB_TOKEN"

    echo "=== Building NixOS configuration: ${cfg.nodeName} ==="
    /run/current-system/sw/bin/nixos-rebuild switch \
      --flake "${repoDir}#${cfg.nodeName}" \
      ${overrideFlags} \
      $NIX_ACCESS

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

  pollScript = pkgs.writeShellScript "deploy-poll" ''
    set -euo pipefail
    cd "${repoDir}"

    ${gitWithGitHubApp} ${git} fetch origin

    LOCAL=$(${git} rev-parse HEAD)
    REMOTE=$(${git} rev-parse "origin/${cfg.trackBranch}")

    [ "$LOCAL" != "$REMOTE" ] || { echo "No changes on ${cfg.trackBranch} ($LOCAL)"; exit 0; }

    echo "Change detected: $LOCAL -> $REMOTE"
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
      description = "Git repository HTTPS URL";
    };

    appInputs = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Flake inputs to override with latest (input name -> flake URL)";
      example = { sonar = "github:plural-reality/baisoku-survey"; };
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
          ${gitWithGitHubApp} ${git} clone "${cfg.repoUrl}" "${repoDir}"
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
