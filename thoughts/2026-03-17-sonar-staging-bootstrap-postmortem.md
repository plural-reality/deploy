---
date: 2026-03-17
git_commit: cc1394e
branch: main
topic: sonar-staging bootstrap — 初回デプロイの知見
---

# sonar-staging bootstrap: 実際にやって分かったこと

## 背景

sonar-staging の EC2 インスタンスが起動しているのにポート全閉・応答なしだった。
原因を追って bootstrap → full config → deploy pipeline 検証まで一気通貫で実施。

## 発見した問題と解決策

### 1. bootstrap.sh の chicken-and-egg

**症状**: `amazon-init.service` (userdata) が FAILED。

**根本原因**: 2つの問題が重なっていた。

#### 1a. EC2 tag 名のミスマッチ

bootstrap.sh は IMDS から `Name` tag を取得して `${TAG}-bootstrap` を flake output 名にする。

```
EC2 tag:        sonar-staging-app     (Terraform の旧命名)
flake output:   sonar-staging-bootstrap
探していた名前: sonar-staging-app-bootstrap  ← 存在しない
```

**教訓**: `for_each` migration の `moved` ブロックは Terraform state を移行するが、
実リソースの tag は apply しないと変わらない。tag に依存する userdata ロジックがある場合、
tag のリネームは実質的な破壊的変更。

#### 1b. private flake input の認証

flake.nix の `sonar` input (`git+ssh://git@github.com/...`) は全 output 評価時に fetch される。
bootstrap output が `sonar` を参照していなくても、nix は全 input を fetch しようとする。
base NixOS AMI には SSH deploy key がないため失敗。

**解決策**: deploy repo が public であることを利用。

```bash
git clone https://github.com/plural-reality/deploy.git  # public, no auth
sops -d --extract '["sonar"]' secrets/ssh/deploy.yaml    # IAM role → KMS
export GIT_SSH_COMMAND="ssh -i $key ..."
nixos-rebuild switch --flake ./repo#${TAG}-bootstrap
```

**教訓**: nix flake は lazy に見えて input fetch は eager。
private input が1つでもあれば、bootstrap 段階で認証手段が必要。
「deploy repo が public だから大丈夫」は成り立たない。

### 2. autoUpgrade の SSH host alias

**症状**: bootstrap 成功後、autoUpgrade が `Host key verification failed` で失敗。

**根本原因**: deploy.nix の `system.autoUpgrade` は `--override-input` で
`github-app` SSH alias を使うが、bootstrap config には `deploy.overrideInputs` が空だった。
結果、flake.lock の `git+ssh://git@github.com/...` が直接使われ、
`github.com` の host key が unknown → verification fail。

**解決策**: bootstrap config にも `deploy.overrideInputs.sonar` を明示。

```nix
sonar-staging-bootstrap = mkNixOSNode {
  hostname = "sonar-staging";
  modules = [
    ./nixos/deploy.nix
    { deploy.overrideInputs.sonar = "git+ssh://git@github-app/...?ref=main"; }
  ];
};
```

**教訓**: bootstrap は「最小構成」を目指すが、self-deploy が動くために必要な設定は
全て含めないと、bootstrap 後の自律動作に移行できない。
「deploy.nix を入れたから autoUpgrade は動く」は不十分 — override-input も必要。

### 3. npmDepsHash の drift

**症状**: `hash mismatch in fixed-output derivation sonar-0.1.0-npm-deps`

**根本原因**: app repo で `package-lock.json` が更新されたが、
`flake.nix` の `npmDepsHash` が追従していなかった。

**教訓**: `buildNpmPackage` の `npmDepsHash` は CI で自動検証すべき。
`nix build .#sonar` を CI に入れれば、hash 不整合で即 fail する。

## 時間計測

| フェーズ | 所要時間 |
|---------|---------|
| bootstrap (nixos-rebuild) | ~6分 (cache なし、t4g.medium) |
| full config upgrade (手動) | ~8分 (app ビルド含む) |
| app 変更の自動デプロイ | ~6分 (push → staging 反映) |

## 今後の改善候補

1. **cachix push を CI に追加**: app ビルド結果を cachix に push すれば、
   EC2 上でのビルドが fetch のみになり大幅短縮
2. **`nix build .#sonar` を app CI に追加**: npmDepsHash drift を即検出
3. **`sonar-prod-bootstrap` の追加**: prod 展開時に同じ問題を踏まないように
4. **bootstrap の冪等性テスト**: 新規インスタンスで bootstrap が通ることを定期的に検証

## アーキテクチャ図 (実証後の理解)

```
[EC2 起動]
  │
  ├─ base NixOS AMI (SSH, DHCP のみ)
  │
  ▼
[amazon-init: bootstrap.sh]
  │
  ├─ git clone deploy repo (HTTPS, public)
  ├─ sops -d → SSH deploy key (IAM → KMS)
  ├─ GIT_SSH_COMMAND で nix に鍵を渡す
  ├─ nixos-rebuild switch #sonar-staging-bootstrap
  │    ├─ sops-nix: deploy keys を /run/secrets/ に配置
  │    ├─ SSH host alias: github-infra, github-app
  │    └─ system.autoUpgrade: minutely polling 開始
  │
  ▼
[autoUpgrade: 毎分]
  │
  ├─ git+ssh://github-infra → deploy repo (infra key)
  ├─ --override-input sonar → github-app (app key)
  ├─ nixos-rebuild switch #sonar-staging (full config)
  │    ├─ nginx, supabase, sonar services
  │    ├─ ACME TLS
  │    └─ version endpoint
  │
  ▼
[定常運用]
  push to app main → 次の polling で検出 → rebuild → switch (~6min)
```
