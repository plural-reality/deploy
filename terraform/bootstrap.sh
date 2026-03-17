#!/usr/bin/env bash
set -euo pipefail

# --- Instance identity ---
TOKEN=$(curl -sfX PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" http://169.254.169.254/latest/api/token)
TAG=$(curl -sfH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/tags/instance/Name)

# Derive the app name from the instance tag (e.g. "sonar-staging" -> "sonar", "cartographer-staging" -> "cartographer")
APP=${TAG%%-*}

# --- Break the chicken-and-egg: need SSH key to fetch private flake inputs,
#     but SSH key is in SOPS which requires the NixOS config to be applied.
#     Solution: clone the public deploy repo, decrypt the key with sops CLI,
#     then feed it to nix via GIT_SSH_COMMAND. ---
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

git clone --depth 1 https://github.com/plural-reality/deploy.git "$WORK/repo"

nix-shell -p sops --run \
  "sops -d --extract '[\"$APP\"]' $WORK/repo/secrets/ssh/deploy.yaml > $WORK/key"
chmod 600 "$WORK/key"

export GIT_SSH_COMMAND="ssh -i $WORK/key -o StrictHostKeyChecking=accept-new"

/run/current-system/sw/bin/nixos-rebuild switch \
  --flake "$WORK/repo#${TAG}-bootstrap" \
  --refresh
