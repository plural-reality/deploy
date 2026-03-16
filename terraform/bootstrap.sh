#!/usr/bin/env bash
# Bootstrap: clone (public) → SOPS decrypt SSH key → nixos-rebuild switch
# Idempotent — safe to run on every boot (amazon-init).
# After the first successful nixos-rebuild, deploy-poll.timer takes over.
set -euo pipefail

REPO_DIR=/var/lib/sonar-deploy/repo
REPO_URL="https://github.com/plural-reality/deploy.git"

# --- Derive node name from EC2 instance tag via IMDS v2 ---
TOKEN=$(curl -sfX PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" http://169.254.169.254/latest/api/token)
TAG=$(curl -sfH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/tags/instance/Name)
NODE_NAME="${TAG%-app}"

echo "=== Bootstrap: $NODE_NAME ==="

# --- Clone deploy repo (public, no auth needed) ---
if [ ! -d "$REPO_DIR/.git" ]; then
  mkdir -p "$(dirname "$REPO_DIR")"
  git clone "$REPO_URL" "$REPO_DIR"
else
  cd "$REPO_DIR"
  git fetch origin
  git checkout main
  git pull origin main --ff-only
fi

# --- Decrypt SSH deploy key via KMS (for private app repo fetch) ---
SSH_KEY=$(mktemp)
trap 'rm -f "$SSH_KEY"' EXIT
nix-shell -p sops --run "sops -d --extract '[\"data\"]' '$REPO_DIR/secrets/ssh/deploy.yaml'" > "$SSH_KEY"
chmod 600 "$SSH_KEY"

# --- nixos-rebuild (app flake uses git+ssh://, needs SSH key) ---
export GIT_SSH_COMMAND="ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null"
/run/current-system/sw/bin/nixos-rebuild switch \
  --flake "$REPO_DIR#$NODE_NAME"

echo "=== Bootstrap complete. deploy-poll.timer now manages ongoing deploys. ==="
