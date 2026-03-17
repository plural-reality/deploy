# pull-deploy 設計書

## 概要

複数の app repo(cartographer, baisoku-survey)を複数の EC2 インスタンス(NixOS 公開版, Ubuntu Cybozu版)に自動デプロイする仕組みの設計。

NixOS の `system.autoUpgrade`、世代管理によるロールバック、`sops-nix` による secrets 管理など、標準機能と既存ライブラリを最大限活用し、自前実装を最小化する。

初回 bootstrap のみ `nix run "git+ssh://...#bootstrap"` を実行。以降は `system.autoUpgrade` が自動で polling + rebuild する。

---

## 設計原則

- **NixOS 標準機能を使い切る**: `system.autoUpgrade`、世代管理、`sops-nix` 等。自前実装は最終手段
- **dumb boring simple**: Docker なし、GitHub Actions CD なし、Colmena によるアプリデプロイなし
- **鶏卵の解消**: bootstrap は初回 1 回のみ。以降は `system.autoUpgrade` が自動
- **グローバル状態変更ゼロ**: `~/.ssh/config` に触らない。Nix が管理する専用 SSH config を使用

---

## 命名規則

### プロダクト名(正規名)

deploy repo 内では GitHub リポ名ではなくプロダクト名で統一する:

| プロダクト名 | GitHub リポ | flake input 名 |
|---|---|---|
| `cartographer` | plural-reality/cartographer | `cartographer` |
| `sonar` | plural-reality/baisoku-survey | `sonar` |

flake input 名・environments ファイル名・EC2 ディレクトリ名・secrets ファイル名すべてプロダクト名基準。

### 環境名

`{product}-{owner}-{stage}` の形式:

| 環境名 | 意味 |
|---|---|
| `cartographer-public-stg` | cartographer 公開版 staging |
| `cartographer-public-prod` | cartographer 公開版 production |
| `cartographer-cybozu-prod` | cartographer Cybozu版 production |
| `sonar-public-stg` | sonar 公開版 staging |
| `sonar-public-prod` | sonar 公開版 production |

---

## リポジトリ構成

```
plural-reality/deploy              ... デプロイ基盤(本設計の主体)
plural-reality/cartographer        ... app repo(packages, apps.up, env ABI 宣言)
plural-reality/baisoku-survey      ... app repo(同上)
```

### 責務の分離

| リポジトリ | 責務 | 知ってよいこと |
|---|---|---|
| app repo | ビルド定義(packages)、アプリコード、apps.up(起動方法)、env ABI 宣言 | 自分が必要とする環境変数の名前 |
| deploy repo | デプロイ基盤、secrets、環境定義、Terraform、devenv(全開発ツール)、env ABI 検証 | app repo の存在、EC2 の構成、KMS キー |

app repo は deploy repo の存在を一切知らない。devenv / devShell は持たない。

### app repo の flake outputs

```nix
{
  packages.aarch64-linux = {
    cartographer-front = mkDerivation {
      # ...
      passthru.requiredEnv = [ "NEXT_PUBLIC_SUPABASE_URL" "NEXT_PUBLIC_SUPABASE_ANON_KEY" ];
      passthru.optionalEnv = [ "SENTRY_DSN" ];
    };
    cartographer-back = mkDerivation {
      # ...
      passthru.requiredEnv = [ "DATABASE_URL" "SESSION_SECRET" "WORKOS_API_KEY" "WORKOS_CLIENT_ID" ];
      passthru.optionalEnv = [ "LOG_LEVEL" ];
    };
  };

  # env が設定済みの前提で front + back を起動する
  apps.aarch64-linux.up = { ... };
}
```

env 依存は `passthru` でパッケージに付随する。ビルドグラフには影響せず、
`nix eval` で機械的に取得できる:

```bash
nix eval cartographer#packages.aarch64-linux.cartographer-back.requiredEnv --json
# → ["DATABASE_URL", "SESSION_SECRET", "WORKOS_API_KEY", "WORKOS_CLIENT_ID"]
```

### deploy repo による env ABI 検証

deploy repo は activate 前に app の `requiredEnv` を読み、secrets 復号後の環境変数と突合する:

```bash
# pull-deploy 内部
eval "$(sops -d ...)"

for var in $(nix eval cartographer#packages.aarch64-linux.cartographer-back.requiredEnv --json | jq -r '.[]'); do
  [ -z "${!var}" ] && echo "FATAL: $var is not set" && exit 1
done

# 全 required env が揃っていることを確認してから activate
```

これにより:
- app 開発者がパッケージを変更するときに env 依存も一緒に更新する動線になる
- secrets を足し忘れたとき、smoke test より前(activate 前)に失敗できる
- 契約は app repo に、検証は deploy repo に。宣言と実行の責務が分離される

---

## 環境一覧

| 環境名 | OS | product | EC2 管理者 | DB |
|---|---|---|---|---|
| cartographer-public-stg | NixOS | cartographer | 多元現実 (Terraform) | Supabase (hosted) |
| cartographer-public-prod | NixOS | cartographer | 多元現実 (Terraform) | Supabase (hosted) |
| cartographer-cybozu-prod | Ubuntu | cartographer | サイボウズ (Terraform) | EC2 上 Postgres |
| sonar-public-stg | NixOS | sonar | 多元現実 (Terraform) | Self-hosted Supabase |
| sonar-public-prod | NixOS | sonar | 多元現実 (Terraform) | Self-hosted Supabase |
| sonar-cybozu-prod | Ubuntu | sonar | サイボウズ (Terraform) | EC2 上 Postgres |

※ 環境は今後増減する可能性がある。pull-deploy は環境定義ファイルに基づいて動作し、ハードコードしない。

---

## deploy repo ディレクトリ構成

```
deploy/
├── flake.nix                          ... flake-parts ベース
├── flake.lock
├── environments/                      ... 環境定義(現 flake.nix の node 宣言を置換)
│   ├── cartographer-public-stg.nix
│   ├── cartographer-public-prod.nix
│   ├── cartographer-cybozu-prod.nix
│   ├── sonar-public-stg.nix
│   ├── sonar-public-prod.nix
│   └── sonar-cybozu-prod.nix
├── modules/                           ... NixOS / system-manager モジュール
│   ├── nixos/                         ... NixOS 固有
│   │   ├── common.nix
│   │   ├── infrastructure.nix
│   │   └── version.nix
│   ├── apps/                          ... アプリ固有のサービス定義
│   │   ├── cartographer.nix
│   │   └── sonar.nix
│   ├── deploy/                        ... pull-deploy 関連
│   │   ├── pull-deploy.nix
│   │   ├── smoke-test.nix
│   │   └── deploy-keys.nix           ... SSH config + deploy key 管理
│   └── secrets/
│       ├── cartographer.nix
│       └── sonar.nix
├── lib/
│   ├── mkNode.nix
│   ├── loadEnvironments.nix
│   └── mkCustomerPackage.nix
├── secrets/
│   ├── .sops.yaml
│   ├── cartographer-public-stg.yaml
│   ├── cartographer-public-prod.yaml
│   ├── cartographer-cybozu-prod.yaml
│   ├── sonar-public-stg.yaml
│   ├── sonar-public-prod.yaml
│   ├── sonar-cybozu-prod.yaml
│   └── ssh/
│       ├── deploy.yaml
│       ├── cartographer.yaml
│       └── sonar.yaml
├── supabase/
├── terraform/
├── tfc-bootstrap/
└── thoughts/
```

### 変更点まとめ

| 現状 | 移行後 | 理由 |
|---|---|---|
| `nixos/*.nix` (フラット11ファイル) | `modules/{nixos,apps,deploy,secrets}/` | 責務ごとにグループ化 |
| `lib/mkSonarNode.nix` + `lib/mkCartographerNode.nix` | `lib/mkNode.nix` (統合) | environments/*.nix が差分を吸収 |
| flake.nix 内の node 宣言 | `environments/*.nix` | 環境定義を flake.nix から分離 |
| `secrets/ssh/{deploy,operator}.yaml` | `secrets/ssh/{deploy,cartographer,sonar}.yaml` | app ごとの deploy key |
| `.ssh/config` に github-app エイリアス | `/etc/deploy-ssh-config` を NixOS module で管理 | 宣言的、`~/.ssh/config` 非破壊 |
| `terraform/*.tfstate*` | `.gitignore` に追加 | state ファイルは git 管理しない |

---

## flake.nix(flake-parts ベース)

```nix
{
  description = "Plural Reality deployment";

  inputs = {
    nixpkgs.url = "github:numtide/nixpkgs-unfree?ref=nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "aarch64-linux" "x86_64-linux" ];

      flake = let
        environments = import ./lib/loadEnvironments.nix {
          dir = ./environments;
          inherit inputs;
        };
      in {
        nixosConfigurations = builtins.mapAttrs
          (name: env: import ./lib/mkNode.nix { inherit inputs env name; })
          (nixpkgs.lib.filterAttrs (_: e: e.platform == "nixos") environments);
      };

      perSystem = { pkgs, system, ... }: {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            terraform sops age awscli2 cachix jq curl
            nodejs_22
          ];
        };

        apps = builtins.mapAttrs (name: env: {
          type = "app";
          program = toString (pkgs.writeShellScript "dev-${name}" ''
            eval "$(${pkgs.sops}/bin/sops -d --output-type dotenv secrets/${env.secretsPath})"
            exec nix run "git+ssh://${env.repo}?ref=${env.ref}#up"
          '');
        }) environments;
      };
    };
}
```

注意: flake inputs に app repo を持たない。各 environment が `repo` と `ref` を直接持つ。
ただし `nixosConfigurations` のビルドに app の packages が必要な場合は、
必要に応じて inputs に追加する判断は実装時に行う。

### environments/*.nix の例

```nix
# environments/cartographer-public-stg.nix
{
  repo = "git@github-cartographer:plural-reality/cartographer.git";
  ref = "main";
  deployKey = "cartographer";
  platform = "nixos";

  modules = [
    ../modules/nixos/common.nix
    ../modules/apps/cartographer.nix
    ../modules/secrets/cartographer.nix
    ../modules/deploy/pull-deploy.nix
    ../modules/deploy/deploy-keys.nix
  ];

  domain = "staging.baisoku-kaigi.com";
  efsFileSystemId = "fs-0a3f1c8ae1d63c51b";
  supabaseUrl = "https://...supabase.co";
  supabaseAnonKey = "eyJ...";
  workosClientId = "";
  secretsPath = "cartographer-public-stg.yaml";

  smokeTest = {
    url = "http://localhost:3000/api/health";
    expectedStatus = 200;
    timeoutSeconds = 30;
  };
}
```

`lib/mkNode.nix` は `env.modules` をそのまま使う。自動判定はしない。

---

## Git クレデンシャル: Deploy Key (SSH)

### 選定理由

| 方式 | 評価 |
|---|---|
| 個人 SSH キー | 不適切。個人アカウントに紐づく |
| Fine-grained PAT | 不適切。個人アカウントに紐づく |
| GitHub App Installation Token | 正式だが過剰。3人チーム・4リポでは複雑さに見合わない |
| **Deploy Key (SSH)** | **採用。** リポ単位の read-only SSH キー。個人から完全分離 |

### 複数 deploy key の切り替え: 宣言的 SSH config

`~/.ssh/config` は触らない。NixOS module で `/etc/deploy-ssh-config` を宣言的に管理し、
`nix.settings.ssh-config-file` で Nix に教える:

```nix
# modules/deploy/deploy-keys.nix
{ config, ... }:
{
  environment.etc."deploy-ssh-config" = {
    text = ''
      Host github-cartographer
        HostName github.com
        User git
        IdentityFile /run/secrets/deploy-key-cartographer
        IdentitiesOnly yes

      Host github-sonar
        HostName github.com
        User git
        IdentityFile /run/secrets/deploy-key-sonar
        IdentitiesOnly yes

      Host github-deploy
        HostName github.com
        User git
        IdentityFile /run/secrets/deploy-key-deploy
        IdentitiesOnly yes
    '';
    mode = "0444";
  };

  nix.settings.ssh-config-file = "/etc/deploy-ssh-config";

  sops.secrets.deploy-key-deploy = {
    sopsFile = ../../secrets/ssh/deploy.yaml;
    path = "/run/secrets/deploy-key-deploy";
    mode = "0400";
  };
  sops.secrets.deploy-key-cartographer = {
    sopsFile = ../../secrets/ssh/cartographer.yaml;
    path = "/run/secrets/deploy-key-cartographer";
    mode = "0400";
  };
  sops.secrets.deploy-key-sonar = {
    sopsFile = ../../secrets/ssh/sonar.yaml;
    path = "/run/secrets/deploy-key-sonar";
    mode = "0400";
  };
}
```

flake inputs・environments の `repo` はホストエイリアスで参照:

```nix
repo = "git@github-cartographer:plural-reality/cartographer.git";
```

bootstrap 時は `/etc/deploy-ssh-config` が未配置のため `GIT_SSH_COMMAND` + 単一 key で解決。
bootstrap 完了後、SSH config が配置され以降は自動で正しい key が使われる。

---

## pull-deploy の動作

### 方針: NixOS 標準機能を最大限活用する

| 機能 | 自前実装ではなく | 使うもの |
|---|---|---|
| 定期 polling + rebuild | 自前 systemd timer | `system.autoUpgrade` (NixOS 標準) |
| ロールバック | 自前 rev 管理 | NixOS 世代管理 |
| secrets 復号 + deploy key 配置 | 自前スクリプト | `sops-nix` |
| deploy key 切り替え | `GIT_SSH_COMMAND` one-off | `/etc/deploy-ssh-config` + `nix.settings.ssh-config-file` |
| smoke test | 自前ヘルスチェック | systemd `ExecStartPost` |

### NixOS 版: system.autoUpgrade

```nix
# modules/deploy/pull-deploy.nix
{ config, pkgs, ... }:
{
  system.autoUpgrade = {
    enable = true;
    flake = "/var/lib/deploy/repo#${config.networking.hostName}";
    flags = [ "--refresh" "--print-build-logs" ];
    dates = "*:0/1";
    randomizedDelaySec = "0";
    allowReboot = false;
  };

  systemd.services.deploy-fetch = {
    description = "Fetch latest deploy repo";
    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = "/var/lib/deploy/repo";
      ExecStart = toString (pkgs.writeShellScript "deploy-fetch" ''
        GIT_SSH_COMMAND="${pkgs.openssh}/bin/ssh -i /run/secrets/deploy-key-deploy -o IdentitiesOnly=yes" \
          ${pkgs.git}/bin/git fetch origin
        ${pkgs.git}/bin/git reset --hard origin/main
      '');
    };
    before = [ "nixos-upgrade.service" ];
    wantedBy = [ "nixos-upgrade.service" ];
  };
}
```

自前で書くのは `deploy-fetch`(git pull)だけ。残りは NixOS 標準。
app repo の fetch は `nix.settings.ssh-config-file` 経由で自動的に正しい deploy key を使う。

### ロールバック

```bash
nixos-rebuild switch --rollback     # 直前の世代に戻す
```

NixOS の世代管理がそのまま使える。GRUB メニューからも選択可能。

### bootstrap(初回のみ、鶏卵の解決)

```bash
#!/usr/bin/env bash
set -euo pipefail

# --- EC2 インスタンスタグから環境を自動特定 ---
TOKEN=$(curl -sfX PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
  http://169.254.169.254/latest/api/token)
TAG=$(curl -sfH "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/tags/instance/Name)
APP=${TAG%%-*}

# --- 鶏卵の解決 ---
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

git clone --depth 1 https://github.com/plural-reality/deploy.git "$WORK/repo"

nix-shell -p sops --run \
  "sops -d --extract '[\"$APP\"]' $WORK/repo/secrets/ssh/deploy.yaml > $WORK/key"
chmod 600 "$WORK/key"

# bootstrap 時は GIT_SSH_COMMAND で 1 key だけ使う(SSH config はまだ存在しない)
export GIT_SSH_COMMAND="ssh -i $WORK/key -o StrictHostKeyChecking=accept-new"
/run/current-system/sw/bin/nixos-rebuild switch \
  --flake "$WORK/repo#${TAG}-bootstrap" \
  --refresh
```

bootstrap 完了後: `/etc/deploy-ssh-config` 配置 → sops-nix が deploy key 配置 → `system.autoUpgrade` 有効化 → 全自動。

### Ubuntu (system-manager) 版

```nix
systemd.timers.deploy-poll = {
  wantedBy = [ "timers.target" ];
  timerConfig = { OnBootSec = "1min"; OnUnitActiveSec = "1min"; };
};

systemd.services.deploy-poll = {
  serviceConfig = {
    Type = "oneshot";
    ExecStart = writeShellScript "deploy-poll" ''
      cd /var/lib/deploy/repo
      GIT_SSH_COMMAND="ssh -i /run/secrets/deploy-key-deploy -o IdentitiesOnly=yes" \
        git pull --ff-only origin main
      system-manager switch
    '';
  };
};
```

---

## Secrets 管理

### SOPS 設定(複数 KMS キー対応)

```yaml
# secrets/.sops.yaml
creation_rules:
  - path_regex: .*-cybozu-.*\.yaml$
    kms: >-
      arn:aws:kms:ap-northeast-1:CYBOZU_ACCOUNT:key/CYBOZU_KEY_ID,
      arn:aws:kms:ap-northeast-1:PLURAL_ACCOUNT:key/PLURAL_KEY_ID
    age: age1xxxxxxxx

  - path_regex: .*\.yaml$
    kms: arn:aws:kms:ap-northeast-1:PLURAL_ACCOUNT:key/PLURAL_KEY_ID
    age: age1xxxxxxxx
```

復号は環境に応じて自動選択:
- **公開版 EC2**: IAM ロール → 自社 KMS
- **Cybozu EC2**: IAM ロール → サイボウズ KMS
- **ローカル開発**: age 秘密鍵

---

## 活用する NixOS 標準機能・外部ライブラリ

| 機能 | ツール | 備考 |
|---|---|---|
| 定期 polling + rebuild | `system.autoUpgrade` | NixOS 標準 |
| ロールバック | NixOS 世代管理 | `--rollback` / GRUB |
| secrets 管理 | `sops-nix` | tmpfs 復号・systemd 連携 |
| バイナリキャッシュ | Cachix | EC2 フルビルド回避 |
| flake 構造化 | flake-parts | perSystem / flake 分離 |
| Nix GC | `nix.gc` | 世代自動削除 |
| Ubuntu 宣言管理 | `numtide/system-manager` | Ubuntu を NixOS 的に管理 |

### 検討したが不採用のツール

| ツール | 評価 | ステータス |
|---|---|---|
| `deploy-rs` | magic rollback 優秀だが push 型前提 | 不採用 |
| `nixos-autodeploy` | derivation-based gating が魅力。push-deploy 協調前提。若い | **ウォッチ** |
| `colmena` | push 型・NixOS 前提。既に脱却済み | 不採用 |
| `nixops` | ステートフル・過剰 | 不採用 |

```nix
nix.gc = {
  automatic = true;
  dates = "weekly";
  options = "--delete-older-than 14d";
};
```

---

## Cachix

```
開発者マシン: nix build → cachix push
EC2:          nix build → Cachix cache hit → activate(一瞬)
```

---

## 開発環境(devenv)

### devenv は deploy repo にのみ存在する

app repo に devenv / devShell は置かない。
app repo が持つのは flake の `packages` と `apps.up` のみ。

```
deploy repo の devShell
├── 言語ツールチェイン(Node, Haskell 等)
├── リンター、フォーマッター
├── sops, age, terraform, cachix
└── nix run .#dev-*
```

### dev コマンド(environments から自動生成)

```bash
nix run .#dev-cartographer-public-stg
nix run .#dev-sonar-public-stg
```

### ローカル開発

```
Ghostty Tab 1: cd deploy          → nix run .#dev-cartographer-public-stg
Ghostty Tab 2: cd cartographer    → claude
```

direnv: deploy repo に `use flake` → cd で devShell に入る。

---

## 将来の拡張

- **GitHub App**: Deploy Key 管理が煩雑になった場合
- **Webhook**: 即時反映が必要な場合(polling と併用)
- **EC2 追加**: pull-deploy を実行するだけ
