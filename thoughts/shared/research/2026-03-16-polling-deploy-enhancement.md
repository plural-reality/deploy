---
date: 2026-03-16
researcher: claude
git_commit: 5159c11b9e91a60d0f95c6117240cdf344a4faca
branch: main
repository: deploy
topic: "polling self-deploy の強化: app repo 変更検知 + Terraform state クリーンアップ"
tags: [deploy, nixos, terraform, polling, self-deploy, app-input-tracking]
status: complete
last_updated: 2026-03-16
last_updated_by: claude
---

# polling self-deploy の強化

## 背景

commit `d966575` で webhook を polling に置き換え、`68a8c89` で GitHub webhook Terraform リソースを削除した。
polling 自体は動いていたが、以下の2つのギャップがあった。

### ギャップ 1: app repo 変更が検知されない

polling は deploy repo の `origin/main` と ローカル HEAD を比較するだけだった。
`--override-input sonar <ssh-url>` により nixos-rebuild は常に app repo の最新 HEAD を取得するが、
**deploy repo に変更がなければ poll が発火しない** ため、app repo のみの変更ではデプロイされなかった。

### ギャップ 2: Terraform state に旧 webhook リソースが残存

`.tf` ファイルからは削除済みだが、state に以下が残っていた:

- `github_repository_webhook.deploy["prod"]`
- `github_repository_webhook.deploy["staging"]`
- `data.sops_file.ci`

## 実施内容

### 1. `nixos/deploy.nix` — app repo 変更検知の追加

`pollScript` を強化し、deploy repo に加えて `appInputs` で指定された flake input も polling するようにした。

**追加: `checkInputsScript`**

各 `appInputs` flake input に対して:
1. `git ls-remote <url> HEAD` で remote の最新 commit を取得（SSH deploy key 使用）
2. `/etc/nixos-version.json` の `.inputs.<name>` からデプロイ済み revision を取得
3. 不一致なら exit 0（変更あり）、全一致なら exit 1（変更なし）

```
check-app-inputs:
  GIT_SSH_COMMAND=<deploy-key> git ls-remote ssh://...baisoku-survey HEAD
  → REMOTE_REV
  jq .inputs.sonar /etc/nixos-version.json
  → DEPLOYED_REV
  REMOTE ≠ DEPLOYED → exit 0 (changed)
  otherwise → exit 1 (no change)
```

**変更: `pollScript`**

```
deploy-poll:
  CHANGED=false
  git fetch origin
  HEAD vs origin/main → CHANGED=true if different
  check-app-inputs → CHANGED=true if exit 0
  CHANGED=false → "No changes", exit 0
  CHANGED=true → exec sonar-deploy
```

`version.nix` が `inputRevisions` を `/etc/nixos-version.json` に書き出しているため、
`--override-input` で取得された app rev もビルド時に記録される。これが比較の基準になる。

### 2. Terraform state クリーンアップ

`terraform state rm` で旧リソースを除去:

```bash
terraform state rm 'github_repository_webhook.deploy["prod"]'
terraform state rm 'github_repository_webhook.deploy["staging"]'
terraform state rm 'data.sops_file.ci'
```

`terraform/github.tf` のコメントも更新。

## 最終的なポーリングフロー

```
deploy-poll.timer (5min, OnBootSec=2min, ±30s jitter)
  │
  ▼
deploy-poll.service → pollScript
  ├─ git fetch deploy repo
  │   HEAD vs origin/main → diff? → CHANGED=true
  ├─ check-app-inputs
  │   git ls-remote sonar HEAD vs /etc/nixos-version.json → diff? → CHANGED=true
  │
  ├─ CHANGED=false → "No changes", exit 0
  └─ CHANGED=true → exec sonar-deploy
                       ├─ flock /run/sonar-deploy.lock
                       ├─ git pull --ff-only
                       ├─ PREV_SYSTEM=$(readlink /run/current-system)
                       ├─ nixos-rebuild switch --override-input sonar <ssh-url>
                       ├─ systemctl restart supabase
                       ├─ curl localhost:3000 (smoke test, 3 retries)
                       │   pass → "Deploy complete"
                       │   fail → $PREV_SYSTEM/bin/switch-to-configuration switch (rollback)
                       └─ exit
```

## 設計判断

| 判断 | 理由 |
|------|------|
| `git ls-remote` で app repo を確認 | `git clone` 不要で軽量。HEAD の commit hash だけ取得 |
| `/etc/nixos-version.json` と比較 | `version.nix` が `inputRevisions` を既に公開している。新たな state file 不要 |
| 別スクリプト (`check-app-inputs`) に分離 | `set -e` との相性。exit code で変更有無を伝達し、`pollScript` 側で `&& ... \|\| true` で安全にハンドリング |
| `appInputs` が空なら即 exit 1 | deploy repo のみの polling に自然にフォールバック |
| SSH key 未配置時は `echo "unknown"` | sops-nix 起動前の初回 poll でも安全にスキップ |

## コード参照

- `nixos/deploy.nix:68-80` — `checkInputsScript`
- `nixos/deploy.nix:82-99` — 強化された `pollScript`
- `nixos/version.nix:13-18` — `inputRevisions` を含む `versionJson`
- `flake.nix:40-43` — `inputRevisions` の定義（`sonar`, `nixpkgs`, `sops-nix`）
- `terraform/github.tf` — webhook 除去済みコメント
