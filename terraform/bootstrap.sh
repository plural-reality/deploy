#!/usr/bin/env bash
set -euo pipefail
TOKEN=$(curl -sfX PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" http://169.254.169.254/latest/api/token)
TAG=$(curl -sfH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/tags/instance/Name)
/run/current-system/sw/bin/nixos-rebuild switch --flake "github:plural-reality/deploy#${TAG}-bootstrap" --refresh
