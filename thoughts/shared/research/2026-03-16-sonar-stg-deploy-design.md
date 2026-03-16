---
date: 2026-03-16T00:00:00+09:00
researcher: claude
git_commit: 68a8c89cfb9240a41a46a79aadd7fee1aa754ccd
branch: main
repository: deploy
topic: "sonar-stg デプロイ設計の現状"
tags: [research, codebase, sonar-staging, deploy, nixos, terraform, self-deploy]
status: complete
last_updated: 2026-03-16
last_updated_by: claude
---

# Research: sonar-stg デプロイ設計の現状

**Date**: 2026-03-16T00:00:00+09:00
**Researcher**: claude
**Git Commit**: 68a8c89cfb9240a41a46a79aadd7fee1aa754ccd
**Branch**: main
**Repository**: deploy

## Research Question
現状、sonar-stgのdeployはどのような設計になってる?

## Summary

sonar-stg（`sonar-staging`）のデプロイは **polling-based self-deploy** パターンで構成されている。AWS EC2 上の NixOS インスタンスが、5分間隔で deploy リポジトリの `main` ブランチを polling し、変更を検知すると `nixos-rebuild switch` を自動実行する。ロールバック付きの smoke test も組み込まれている。

全体は3層で成り立つ:
1. **Terraform** — EC2 / EIP / DNS / IAM を `local.environments` の `for_each` で staging/prod 2環境分プロビジョニング
2. **bootstrap.sh** — EC2 初回起動時のみ実行。IMDS からノード名を取得し、初回 `nixos-rebuild switch`
3. **NixOS modules** — 5つのモジュールを `mkNode` で合成。self-deploy timer, nginx, Supabase (Docker), Next.js service, SOPS secrets

## Detailed Findings

### 1. Terraform 層: インフラ定義

**`terraform/main.tf:22-31`** — 全ての `for_each` リソースの source of truth:

```
local.environments = {
  staging = { app_subdomain = "staging.baisoku-survey", supabase_subdomain = "staging-supabase.baisoku-survey" }
  prod    = { app_subdomain = "app.baisoku-survey",     supabase_subdomain = "supabase.baisoku-survey" }
}
```

この1つの map から EC2, EIP, DNS レコード, output JSON がすべて fan-out する。

**`terraform/compute.tf`**:
- `aws_instance.app["staging"]` — NixOS 25.11 aarch64 / t4g.medium / 40GB gp3
- `aws_eip.app["staging"]` — Elastic IP
- IAM role `sonar-ec2-sops` — KMS Decrypt 権限（SOPS 復号用）
- `user_data = bootstrap.sh`（初回のみ）、`lifecycle.ignore_changes = [ami, user_data]`

**`terraform/cloudflare.tf`**:
- `staging.baisoku-survey.plural-reality.com` → staging EIP (DNS-only, proxied = false)
- `staging-supabase.baisoku-survey.plural-reality.com` → staging EIP

**`terraform/outputs.tf`**:
- `terraform/infra-sonar-staging.json` を出力（ip, domain, supabase_domain, kms_key_arn）

### 2. 初回ブート: bootstrap.sh

`terraform/bootstrap.sh` は EC2 user_data として初回起動時のみ実行:

1. IMDSv2 で `Name` タグ取得 → `-app` を strip → `NODE_NAME=sonar-staging`
2. deploy リポジトリを `/var/lib/sonar-deploy/repo` に clone
3. `nix-shell -p sops` で `secrets/ssh/deploy.yaml` を復号 → ephemeral temp file に SSH 秘密鍵
4. `GIT_SSH_COMMAND` 経由で `nixos-rebuild switch --flake <repo>#sonar-staging`
5. 初回 apply 完了後、NixOS 側の `deploy-poll.timer` が継続的デプロイを引き継ぐ

### 3. NixOS モジュール構成

**`flake.nix:94-108`** — ノード定義:

```nix
sonar-staging = {
  hostname        = "sonar-staging";
  environment     = "staging";
  domain          = "staging.baisoku-survey.plural-reality.com";
  supabaseDomain  = "staging-supabase.baisoku-survey.plural-reality.com";
  trackBranch     = "main";  # デフォルト
}
```

**`flake.nix:35-69`** — `mkNode` が以下のモジュールを合成:

| Module | Role |
|--------|------|
| `sops-nix` | SOPS 復号 upstream module |
| `nixos/infrastructure.nix` | `amazon-image.nix` + `common.nix` |
| `nixos/application.nix` | nginx, Supabase, Next.js service |
| `nixos/deploy.nix` | polling self-deploy |
| `nixos/secrets.nix` | SOPS 宣言 + テンプレート |
| `nixos/version.nix` | ビルド時バージョン JSON |
| inline module | `sonar.*` option binding |

### 4. Self-Deploy メカニズム (deploy.nix)

3つの systemd ユニット:

**`deploy-repo-init.service`** — oneshot, RemainAfterExit
- `/var/lib/sonar-deploy/repo` の存在を保証

**`deploy-poll.timer`**
- `OnBootSec = 2min`, `OnUnitActiveSec = 5min`, `RandomizedDelaySec = 30s`

**`deploy-poll.service`** → `pollScript` → `deployScript`:
```
git fetch origin
HEAD == origin/main ? → exit 0 (no changes)
HEAD != origin/main ? → exec deployScript:
  flock -n /run/sonar-deploy.lock
  git pull --ff-only
  PREV_SYSTEM=$(readlink /run/current-system)
  GIT_SSH_COMMAND=/run/secrets/deploy-ssh-key \
    nixos-rebuild switch \
      --flake .#sonar-staging \
      --override-input sonar git+ssh://git@github.com/plural-reality/baisoku-survey
  systemctl restart supabase.service
  curl http://localhost:3000 (smoke test, 3 retries)
  fail → $PREV_SYSTEM/bin/switch-to-configuration switch (rollback)
```

`--override-input sonar` により、deploy リポジトリの `flake.lock` に固定された sonar rev ではなく、app リポジトリの最新 HEAD を毎回 fetch してビルドする。

### 5. アプリケーション層 (application.nix)

**nginx**:
- `staging.baisoku-survey.plural-reality.com` → `http://127.0.0.1:3000` (Next.js)
- `staging-supabase.baisoku-survey.plural-reality.com` → `http://127.0.0.1:8000` (Kong)
- 両方 ACME + forceSSL

**Supabase** (Docker Compose):
- `WorkingDirectory = /var/lib/sonar-deploy/repo/supabase`
- `ExecStartPre` で SOPS テンプレートから `.env` と `kong.yml` を生成
- `Requires = deploy-repo-init.service`

**Next.js `sonar` service**:
- `ExecStart = ${sonar-app}/bin/sonar` (Nix store パスのラッパー)
- `EnvironmentFile = sops.templates."nextjs-env".path`
- PORT=3000, NODE_ENV=production

### 6. シークレット管理 (secrets.nix)

- `sops.defaultSopsFile = secrets/sonar-staging.yaml`
- KMS のみで復号（age なし）
- 個別シークレット: `postgres_password`, `jwt_secret`, `anon_key`, `service_role_key`, `smtp_pass`, `openrouter_api_key`, `resend_api_key`
- Deploy SSH key: `secrets/ssh/deploy.yaml` → `/run/secrets/deploy-ssh-key`
- テンプレート `supabase-env`: Docker Compose 用 .env
- テンプレート `nextjs-env`: Next.js 用 env file（16変数、うち3つが SOPS placeholder）

### 7. 共通基盤 (common.nix)

- Nix daemon: max-jobs=1, cores=2, MemoryMax=2048M
- Binary cache: plural-reality.cachix.org
- 2GB swapfile
- Docker + weekly prune
- `sonar` user (uid auto, group sonar, home /var/lib/sonar)
- IMDS route (`169.254.169.254/32`) を policy routing table 100 に固定（Docker bridge 干渉回避）
- Firewall: TCP 22, 80, 443

## Code References

- `flake.nix:94-108` — sonar-staging ノード定義
- `flake.nix:27-69` — mkNode factory
- `nixos/deploy.nix:25-66` — deployScript（pull + rebuild + smoke test + rollback）
- `nixos/deploy.nix:68-81` — pollScript（diff 検知）
- `nixos/deploy.nix:84-119` — sonar.deploy option 宣言
- `nixos/deploy.nix:148-171` — deploy-poll.timer / service
- `nixos/application.nix:43-85` — nginx virtual hosts
- `nixos/application.nix:88-129` — Supabase Docker service
- `nixos/application.nix:132-159` — Next.js sonar service
- `nixos/secrets.nix:32-118` — SOPS declarations + templates
- `nixos/common.nix:83-87` — IMDS policy routing
- `terraform/main.tf:22-31` — local.environments map
- `terraform/compute.tf:25-55` — EC2 instance definition
- `terraform/bootstrap.sh` — first-boot script

## Architecture Documentation

### デプロイトリガーの流れ

```
[Developer pushes to deploy repo main] or [Developer pushes to app repo main]
         ↓
deploy-poll.timer (5min ± 30s)
         ↓
pollScript: git fetch → compare HEAD vs origin/main
         ↓ (diff detected)
deployScript:
  flock → git pull → nixos-rebuild switch --override-input sonar <app-repo>
         ↓
  Nix fetches latest app HEAD via SSH deploy key
         ↓
  New NixOS generation activated
         ↓
  systemctl restart supabase
         ↓
  Smoke test: curl localhost:3000
         ↓
  Pass → done | Fail → rollback to PREV_SYSTEM
```

### 環境分離の単位

- Terraform: `local.environments` map の key (`staging` / `prod`)
- NixOS: `flake.nix` の `nodeDefinitions` attrset の key (`sonar-staging` / `sonar-prod`)
- Secrets: ファイル単位で分離 (`secrets/sonar-staging.yaml` / `secrets/sonar-prod.yaml`)
- ネットワーク: 同一 VPC / 同一 subnet（環境間のネットワーク分離なし）

### staging 固有の値

| 項目 | 値 |
|------|-----|
| EC2 Name tag | `sonar-staging-app` |
| NixOS node name | `sonar-staging` |
| App domain | `staging.baisoku-survey.plural-reality.com` |
| Supabase domain | `staging-supabase.baisoku-survey.plural-reality.com` |
| Secrets file | `secrets/sonar-staging.yaml` |
| SENTRY_ENVIRONMENT | `staging` |
| Track branch | `main` |

## Open Questions

- `sonar-staging` の `trackBranch` は現在 `main` だが、staging 専用ブランチ（例: `develop`）を追跡させる想定はあるか？
- staging と prod が同一 subnet にあるが、セキュリティグループも共有しているので、環境間のネットワーク分離は意図的に省略されているか？
