#!/usr/bin/env bash
# Bootstrap: SSM → SSH key → clone → swap → nixos-rebuild switch
# Idempotent — safe to run on every boot (amazon-init).
# After the first successful nixos-rebuild, deploy-poll.timer takes over.
set -euo pipefail

REPO_DIR=/var/lib/sonar-deploy/repo
REPO_URL="git@github.com:plural-reality/deploy.git"
SSM_KEY_NAME="/sonar/deploy-ssh-key"

# --- Derive node name from EC2 instance tag via IMDS v2 ---
TOKEN=$(curl -sfX PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" http://169.254.169.254/latest/api/token)
TAG=$(curl -sfH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/tags/instance/Name)
REGION=$(curl -sfH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
NODE_NAME="${TAG%-app}"

echo "=== Bootstrap: $NODE_NAME ==="

# --- Fetch deploy SSH key from SSM Parameter Store ---
SSH_KEY=$(mktemp)
trap 'rm -f "$SSH_KEY"' EXIT
nix-shell -p awscli2 --run \
  "aws ssm get-parameter --name '$SSM_KEY_NAME' --with-decryption --region '$REGION' --query 'Parameter.Value' --output text" \
  > "$SSH_KEY"
chmod 600 "$SSH_KEY"

export GIT_SSH_COMMAND="ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null"

# --- Clone or update deploy repo via SSH ---
if [ ! -d "$REPO_DIR/.git" ]; then
  mkdir -p "$(dirname "$REPO_DIR")"
  git clone "$REPO_URL" "$REPO_DIR"
else
  cd "$REPO_DIR"
  git fetch origin
  git checkout main
  git reset --hard origin/main
fi

# --- Ensure swap exists for Next.js build (t4g.medium = 4GB RAM) ---
if ! swapon --show | grep -q /swapfile; then
  dd if=/dev/zero of=/swapfile bs=1M count=4096 2>/dev/null
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  echo "Swap enabled: 4GB"
fi

# --- nixos-rebuild switch ---
/run/current-system/sw/bin/nixos-rebuild switch \
  --flake "$REPO_DIR#$NODE_NAME"

echo "=== Bootstrap complete. deploy-poll.timer now manages ongoing deploys. ==="
