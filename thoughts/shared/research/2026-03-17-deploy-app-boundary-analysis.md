---
date: 2026-03-17T00:00:00+09:00
researcher: yui
git_commit_deploy: 55fec29308895571a4d3b31be151652135f2c186
git_commit_app: 0d4e4bf83499ad8282f5d3b1e7113258f1351f9e
branch: main
repository: plural-reality/deploy + plural-reality/baisoku-survey
topic: "deploy repo と baisoku-survey repo の境界線：contract・secret・config の分け方とディレクトリ構造"
tags: [research, codebase, architecture, boundary, secrets, config, contract]
status: complete
last_updated: 2026-03-17
last_updated_by: yui
---

# Research: deploy / baisoku-survey の境界分析

**Date**: 2026-03-17
**Researcher**: yui
**Deploy Commit**: `55fec29`
**App Commit**: `0d4e4bf`

## Research Question

現状の deploy repo と baisoku-survey repo の境界線（特に contract・secret・config）の分け方とディレクトリ構造を包括的にまとめる。

## Summary

2 つのリポジトリは **app が interface を定義し、deploy が concrete value を binding する** という分離モデルで設計されている。ただし、baisoku-survey 側にも `nixos/` モジュール一式が並行して存在し、deploy repo の `nixos/` とは微妙に異なる実装が混在している。

唯一の正式な cross-repo リンクは `deploy/flake.nix` の `sonar` input（SSH 経由で baisoku-survey を参照）。逆方向の参照は存在しない。

---

## Repo 構造対照表

### deploy repo (`plural-reality/deploy`)

```
deploy/
├── flake.nix                    ← sonar input + nixosConfigurations
├── .sops.yaml                   ← secrets/**/*.yaml → KMS
├── lib/
│   ├── mkNixOSNode.nix          ← 汎用 NixOS system builder
│   ├── mkSonarNode.nix          ← Sonar 特化 node builder (domain, secretsFile, appRef を注入)
│   └── mkCustomerPackage.nix    ← 非 NixOS 顧客向け shell wrapper
├── nixos/
│   ├── infrastructure.nix       ← amazon-image + common.nix
│   ├── common.nix               ← Nix daemon, Docker, SSH, firewall, sonar user, swap
│   ├── sonar.nix                ← Sonar module option 定義 + 下位 module import
│   ├── application.nix          ← nginx (2 vhost) + supabase systemd + sonar systemd
│   ├── secrets.nix              ← sops-nix 宣言 + nextjs-env / supabase-env template
│   ├── deploy.nix               ← system.autoUpgrade + SSH host alias
│   ├── deploy-keys.nix          ← deploy SSH key の SOPS 宣言
│   └── version.nix              ← /etc/nixos-version.json + /.well-known/version
├── terraform/
│   ├── main.tf                  ← providers + locals.environments (staging/prod)
│   ├── variables.tf             ← region, instance_type, SSH key, Cloudflare, KMS ARN
│   ├── compute.tf               ← EC2 (for_each), EIP, IAM role (KMS decrypt)
│   ├── network.tf               ← VPC, subnet, IGW, SG
│   ├── cloudflare.tf            ← A records (app + supabase subdomains)
│   ├── backup.tf                ← EBS daily snapshot (14 日保持)
│   ├── outputs.tf               ← local_file "infra-sonar-{env}.json"
│   └── bootstrap.sh             ← EC2 user_data (IMDS → SOPS → nixos-rebuild)
├── secrets/
│   ├── ssh/
│   │   ├── operator.yaml        ← 人間 SSH 用秘密鍵
│   │   └── deploy.yaml          ← deploy/sonar 用 SSH 鍵 (2 フィールド)
│   ├── sonar/
│   │   ├── stg.yaml             ← staging 環境 secrets
│   │   └── prd.yaml             ← production 環境 secrets
│   └── cartographer/
│       ├── stg.yaml             ← (空スタブ)
│       └── prd.yaml             ← (空スタブ)
├── supabase/
│   ├── docker-compose.yml       ← Self-hosted Supabase stack (6 services)
│   └── volumes/
│       ├── api/kong.yml.template ← ANON_KEY/SERVICE_ROLE_KEY プレースホルダー
│       └── db/init-migrations.sh ← 初回 DB init 時に /app-migrations/*.sql 実行
├── tfc-bootstrap/
│   ├── main.tf                  ← AWS provider (local state)
│   ├── kms.tf                   ← KMS key 作成 + key policy
│   ├── locals.tf                ← developers list
│   └── developers.tf            ← IAM user 作成
└── thoughts/
```

### baisoku-survey repo (`plural-reality/baisoku-survey`)

```
baisoku-survey/
├── flake.nix                    ← buildNpmPackage + envContract export + sonar-check-env 生成
├── devenv.nix                   ← ローカル開発: process-compose, SOPS decrypt, supabase
├── env-contract.json            ← ★ canonical env var registry (required/secret/alternatives)
├── .sops.yaml                   ← secrets/local.yaml → KMS (ローカル開発用のみ)
├── .envrc                       ← direnv: use flake . --impure
├── .env.example                 ← 参照用（ツールが読まない）
├── next.config.ts               ← standalone output, Sentry
├── nixos/
│   ├── application.nix          ← nginx + supabase systemd + sonar systemd (deploy repo の並行版)
│   ├── common.nix               ← EC2/Docker/SSH baseline (deploy repo と同等)
│   ├── deploy.nix               ← Self-deploy webhook + GitHub App git helper + colmena
│   ├── infrastructure.nix       ← amazon-image + common.nix
│   ├── secrets.nix              ← SOPS 宣言 (deploy repo より古い/不完全な版)
│   └── version.nix              ← /.well-known/version
├── supabase/
│   ├── config.toml              ← Supabase CLI ローカル開発設定
│   ├── migrations/              ← 26 SQL migration files (001–026)
│   └── templates/magic_link.html
├── infra/
│   └── terraform/               ← deploy repo の terraform/ と構造的に同一
├── secrets/
│   └── local.yaml               ← SOPS 暗号化されたローカル開発用 secrets
├── src/
│   ├── app/                     ← Next.js App Router
│   ├── components/
│   ├── hooks/
│   └── lib/
│       ├── runtime-config.ts    ← env → RuntimeConfig + browser injection
│       ├── supabase/            ← server.ts + client.ts
│       ├── openrouter/          ← LLM client
│       └── vertex-ai.ts
├── e2e/                         ← Playwright E2E tests
├── tests/                       ← vitest unit tests
├── scripts/
├── docs/
├── nix/
└── thoughts/
```

---

## Contract の所在と流れ

### env-contract.json (canonical interface — app repo が所有)

`baisoku-survey/env-contract.json` が**唯一の source of truth**。

```
vars (20 entries):
  required + secret:  OPENROUTER_API_KEY
  required + public:  SONAR_SUPABASE_URL, SONAR_SUPABASE_ANON_KEY, SONAR_BASE_URL, SONAR_SITE_URL
  optional + secret:  RESEND_API_KEY, VERTEX_API_KEY, VERTEX_AI_CREDENTIALS,
                      GOOGLE_SERVICE_ACCOUNT_KEY, NOTIFICATION_SECRET, SUPABASE_SERVICE_ROLE_KEY
  optional + public:  SONAR_UMAMI_URL, SONAR_UMAMI_WEBSITE_ID, SONAR_SENTRY_DSN,
                      SONAR_SENTRY_ENVIRONMENT, RESEND_FROM_EMAIL,
                      GOOGLE_SHEETS_IMPERSONATE_EMAIL, VERTEX_MODEL, GCP_PROJECT_ID

alternatives:
  [0]: ["OPENROUTER_API_KEY", "VERTEX_API_KEY", "VERTEX_AI_CREDENTIALS"]
  [1]: ["SONAR_BASE_URL", "SONAR_SITE_URL"]

allOrNone:
  [0]: ["SONAR_UMAMI_URL", "SONAR_UMAMI_WEBSITE_ID"]
```

flake.nix がこれを読み、`sonar-check-env` スクリプトを生成。`sonar` binary の起動前に実行され、バリデーションに失敗するとプロセスが起動しない。

flake output として `envContract` を export:
```nix
# baisoku-survey/flake.nix:44
{ inherit envContract; }
```

### deploy repo 側の binding (secrets.nix)

`deploy/nixos/secrets.nix` が concrete value を bind する。コメントで envContract との対応を明示:
- `# --- App secrets (subset of envContract.vars where secret = true) ---`
- `# Next.js EnvironmentFile — covers all 16 envContract vars.`

ただし、**プログラム的に envContract を参照していない**（コメントのみ）。deploy repo の flake.nix は `sonar.packages.${system}.sonar` しか使っておらず、`sonar.envContract` は参照されていない。

---

## Secret の分割

| Scope | 場所 | 内容 | 暗号化 |
|-------|------|------|--------|
| Staging/Prod secrets | `deploy/secrets/sonar/stg.yaml`, `prd.yaml` | postgres_password, jwt_secret, anon_key, service_role_key, openrouter_api_key, resend_api_key, smtp_pass, cloudflare_api_token | SOPS + KMS |
| SSH keys | `deploy/secrets/ssh/operator.yaml`, `deploy.yaml` | 人間 SSH / deploy + sonar deploy key | SOPS + KMS |
| ローカル開発 | `baisoku-survey/secrets/local.yaml` | OPENROUTER_API_KEY, RESEND_API_KEY 等 | SOPS + KMS |

**KMS key は全て同一**: `arn:aws:kms:ap-northeast-1:377786476154:key/74beb9ae-57b3-4789-b41c-588fca1d960e`

**アクセス制御**:
- 開発者 IAM user → Encrypt/Decrypt/DescribeKey/GenerateDataKey/ReEncrypt
- EC2 instance profile (`sonar-ec2-sops`) → Decrypt/DescribeKey のみ

---

## Config の流れ（データフローダイアグラム）

```
┌─────────────────────────────────────────────────┐
│  baisoku-survey repo                            │
│                                                 │
│  env-contract.json ──→ flake.nix ──→ sonar pkg  │
│       (interface)       (check-env)  (+ binary) │
│                                                 │
│  secrets/local.yaml ──→ devenv.nix ──→ local dev│
│  supabase/config.toml ──→ supabase start        │
└─────────┬───────────────────────────────────────┘
          │ git+ssh:// (flake input)
          ▼
┌─────────────────────────────────────────────────┐
│  deploy repo                                    │
│                                                 │
│  flake.nix ──→ mkSonarNode ──→ nixosConfiguration│
│    │              │                              │
│    │              ├── domain, supabaseDomain     │
│    │              ├── secretsFile path           │
│    │              └── appRef (git branch)        │
│    │                                             │
│    └── sonar.packages.aarch64-linux.sonar        │
│                                                  │
│  secrets/sonar/stg.yaml ──→ sops-nix ──→ runtime│
│                                │                 │
│                                ├── nextjs-env    │
│                                │   (EnvironmentFile)│
│                                └── supabase-env  │
│                                    (.env for DC) │
│                                                  │
│  terraform/ ──→ EC2, VPC, DNS, IAM, EIP         │
│    └── infra-sonar-{env}.json (output artifact)  │
│                                                  │
│  supabase/docker-compose.yml ──→ self-hosted DB  │
│  supabase/volumes/api/kong.yml.template          │
│  supabase/volumes/db/init-migrations.sh          │
└──────────────────────────────────────────────────┘
```

---

## nixos/ モジュールの重複

両リポジトリに `nixos/` ディレクトリが存在し、以下のファイルが並行している:

| ファイル | deploy repo | baisoku-survey repo | 差異 |
|----------|------------|---------------------|------|
| `application.nix` | nginx + supabase + sonar systemd | 同等だが、self-deploy webhook proxy 追加 | app repo は `/.well-known/deploy` proxy を含む |
| `common.nix` | EC2 baseline | ほぼ同一 | — |
| `secrets.nix` | 16 vars の nextjs-env template | 6 vars のみの nextjs-env template | deploy repo がより完全 |
| `deploy.nix` | system.autoUpgrade (毎分 pull) | Webhook + colmena apply-local | 異なるデプロイ戦略 |
| `version.nix` | 同一 | 同一 | — |
| `infrastructure.nix` | 同一 | 同一 | — |

**deploy repo の `nixos/`** は bootstrap + autoUpgrade パスで使用される（EC2 が毎分 deploy repo を poll）。
**app repo の `nixos/`** は self-deploy webhook パスで使用される（GitHub push → webhook → colmena apply-local）。

---

## Terraform の重複

| 場所 | 用途 |
|------|------|
| `deploy/terraform/` | canonical（state も含む） |
| `baisoku-survey/infra/terraform/` | 構造的に同一だが、GitHub provider 追加 |
| `deploy/tfc-bootstrap/` | KMS + IAM 初期設定（1 回だけ実行） |
| `baisoku-survey/infra/tfc-bootstrap/` | 同様（並行コピー） |

---

## Cross-repo リンクの方向性

```
deploy ──[sonar flake input]──→ baisoku-survey   (SSH 経由で package を取得)
deploy ──[comment reference]──→ env-contract.json (プログラム的参照なし)

baisoku-survey ──[なし]──→ deploy                 (逆方向の参照は存在しない)
```

baisoku-survey 側は deploy repo の存在を知らない。deploy repo が一方的に app を pull する構造。

---

## Supabase の分割

| 関心 | 場所 |
|------|------|
| SQL migrations | `baisoku-survey/supabase/migrations/` (26 ファイル) |
| ローカル開発設定 | `baisoku-survey/supabase/config.toml` |
| メールテンプレート | `baisoku-survey/supabase/templates/` |
| 本番 Docker Compose | `deploy/supabase/docker-compose.yml` |
| Kong ルーティング | `deploy/supabase/volumes/api/kong.yml.template` |
| 初回 DB init | `deploy/supabase/volumes/db/init-migrations.sh` |

本番 migration は `deploy/supabase/volumes/db/init-migrations.sh` が `/app-migrations/*.sql` を実行する仕組み。ただしこのマウントの source は application.nix の ExecStartPre で app package から コピーされる。

---

## App 側の env 消費パス

| 変数 | 読み取り場所 | 経路 |
|------|-------------|------|
| `SONAR_SUPABASE_URL` | `src/lib/runtime-config.ts` → `src/lib/supabase/{server,client}.ts` | server: process.env, browser: `__SONAR_RUNTIME_CONFIG__` |
| `SONAR_SUPABASE_ANON_KEY` | 同上 | 同上 |
| `OPENROUTER_API_KEY` | `src/lib/openrouter/client.ts` | server only (process.env 直接) |
| `VERTEX_AI_CREDENTIALS` | `src/lib/vertex-ai.ts` | server only |
| `RESEND_API_KEY` | `src/lib/email/resend.ts` | server only |
| `SONAR_BASE_URL` / `SONAR_SITE_URL` | `src/lib/runtime-config.ts` | server + browser |
| `SONAR_UMAMI_*` | `src/lib/runtime-config.ts` | server + browser |
| `SONAR_SENTRY_*` | `src/lib/runtime-config.ts` | server + browser |

Browser への橋渡しは `src/app/layout.tsx` の inline `<script>` が `globalThis.__SONAR_RUNTIME_CONFIG__` を設定する仕組み。

---

## Code References

- `deploy/flake.nix:11` — `sonar.url = "git+ssh://git@github.com/plural-reality/baisoku-survey"`
- `deploy/flake.nix:36` — `sonarPackage = sonar.packages.${system}.sonar`
- `deploy/nixos/secrets.nix:31` — `# --- App secrets (subset of envContract.vars where secret = true) ---`
- `deploy/nixos/secrets.nix:68` — `# Next.js EnvironmentFile — covers all 16 envContract vars.`
- `deploy/lib/mkSonarNode.nix:25` — `deploy.overrideInputs.sonar`
- `baisoku-survey/flake.nix:23` — `envContract = builtins.fromJSON (builtins.readFile ./env-contract.json)`
- `baisoku-survey/flake.nix:44` — `{ inherit envContract; }` (flake output)
- `baisoku-survey/env-contract.json` — canonical env var registry
- `baisoku-survey/src/lib/runtime-config.ts` — env → RuntimeConfig + browser injection
- `baisoku-survey/devenv.nix:81-90` — SOPS decrypt at shell entry

## Open Questions

1. deploy repo の `secrets.nix` は `envContract` をコメントでのみ参照しており、プログラム的に import していない。ドリフトの検知は手動。
2. 両リポジトリの `nixos/` モジュールが並行して存在し、`secrets.nix` の nextjs-env template に var 数の差異がある（deploy: 16, app: 6）。
3. `baisoku-survey/infra/terraform/` と `deploy/terraform/` の重複。
4. `secrets/sonar/stg.yaml` と `prd.yaml` が同一の暗号化値を持っている（意図的かは不明）。
