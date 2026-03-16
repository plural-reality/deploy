#!/usr/bin/env bash
# Bootstrap: SSM → SSH key → swap → nixos-rebuild switch (no local clone).
# After the first successful rebuild, deploy-poll.timer takes over.
set -euo pipefail

SONAR_INPUT_URL="git+ssh://git@github.com/plural-reality/baisoku-survey"
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

# --- Ensure swap exists for Next.js build (t4g.medium = 4GB RAM) ---
if ! swapon --show | grep -q /swapfile; then
  dd if=/dev/zero of=/swapfile bs=1M count=4096 2>/dev/null
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  echo "Swap enabled: 4GB"
fi

# --- nixos-rebuild switch (fetches flake directly from GitHub, no local clone) ---
/run/current-system/sw/bin/nixos-rebuild switch \
  --flake "github:plural-reality/deploy#$NODE_NAME" \
  --override-input sonar "$SONAR_INPUT_URL" \
  --refresh

echo "=== Bootstrap complete. deploy-poll.timer active. ==="
