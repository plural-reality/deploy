# pull-deploy 設計書

## 概要

複数の app repo（cartographer, baisoku-survey）を複数の EC2 インスタンス（NixOS 公開版, Ubuntu Cybozu版）に自動デプロイする仕組みの設計。

NixOS の `system.autoUpgrade`、世代管理によるロールバック、`sops-nix` による secrets 管理など、標準機能と既存ライブラリを最大限活用し、自前実装を最小化する。

初回 bootstrap のみ `nix run "git+ssh://...#bootstrap"` を実行。以降は `system.autoUpgrade` が自動で polling + rebuild する。

---

## 設計原則

- **NixOS 標準機能を使い切る**: `system.autoUpgrade`、世代管理、`sops-nix` 等。自前実装は最終手段
- **dumb boring simple**: Docker なし、GitHub Actions CD なし、Colmena によるアプリデプロイなし
- **鶏卵の解消**: bootstrap は初回 1 回のみ。以降は `system.autoUpgrade` が自動
- **グローバル状態変更ゼロ**: `.ssh/config` 等に触らず `GIT_SSH_COMMAND` で one-off 処理

---

## 命名規則

### プロダクト名（正規名）

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
plural-reality/deploy              … デプロイ基盤（本設計の主体）
plural-reality/cartographer        … app repo（packages, apps.up, env ABI 宣言）
plural-reality/baisoku-survey      … app repo（同上）
```

### 責務の分離

| リポジトリ | 責務 | 知ってよいこと |
|---|---|---|
| app repo | ビルド定義（packages）、アプリコード、apps.up（起動方法）、env ABI 宣言 | 自分が必要とする環境変数の名前 |
| deploy repo | デプロイ基盤、secrets、環境定義、Terraform、devenv（全開発ツール）、env ABI 検証 | app repo の存在、EC2 の構成、KMS キー |

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
- secrets を足し忘れたとき、smoke test より前（activate 前）に失敗できる
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

※ 環境は今後増減する可能性がある。pull-deploy は環境定義ファイルに基づいて動作し、ハードコードしない。

---

## deploy repo ディレクトリ構成

### 現状 → 移行後

```
deploy/
├── flake.nix                          … flake-parts ベース
├── flake.lock
│
├── environments/                      … 環境定義（現 flake.nix の node 宣言を置換）
│   ├── cartographer-public-stg.nix
│   ├── cartographer-public-prod.nix
│   ├── cartographer-cybozu-prod.nix
│   ├── sonar-public-stg.nix
│   └── sonar-public-prod.nix
│
├── modules/                           … NixOS / system-manager モジュール
│   ├── nixos/                         … NixOS 固有
│   │   ├── common.nix                 … (現 nixos/common.nix)
│   │   ├── infrastructure.nix         … (現 nixos/infrastructure.nix)
│   │   └── version.nix                … (現 nixos/version.nix)
│   ├── apps/                          … アプリ固有のサービス定義
│   │   ├── cartographer.nix           … (現 nixos/cartographer.nix + cartographer-application.nix 統合)
│   │   └── sonar.nix                  … (現 nixos/sonar.nix + application.nix 統合)
│   ├── deploy/                        … pull-deploy 関連
│   │   ├── pull-deploy.nix            … メインロジック
│   │   ├── smoke-test.nix             … ヘルスチェック定義
│   │   └── deploy-keys.nix            … (現 nixos/deploy-keys.nix)
│   └── secrets/                       … SOPS/KMS 復号
│       ├── cartographer.nix           … (現 nixos/cartographer-secrets.nix)
│       └── sonar.nix                  … (現 nixos/secrets.nix)
│
├── lib/                               … Nix ヘルパー関数
│   ├── mkNode.nix                     … 統合ノード生成（現 mkNixOSNode + mkSonarNode + mkCartographerNode 統合）
│   ├── loadEnvironments.nix           … environments/*.nix を読み込む
│   └── mkCustomerPackage.nix          … (現状維持、将来 environments に吸収)
│
├── secrets/                           … SOPS 暗号化済みファイル
│   ├── .sops.yaml
│   ├── cartographer/
│   │   ├── stg.yaml
│   │   └── prd.yaml
│   ├── sonar/
│   │   ├── stg.yaml
│   │   └── prd.yaml
│   ├── cybozu/
│   │   └── prd.yaml
│   └── ssh/
│       ├── deploy.yaml                … deploy repo 用 deploy key
│       ├── cartographer.yaml          … cartographer repo 用 deploy key
│       └── sonar.yaml                 … sonar repo 用 deploy key
│
├── supabase/                          … sonar 用 self-hosted Supabase 設定
│   ├── docker-compose.yml
│   └── volumes/
│
├── terraform/                         … 公開版インフラ定義
│   ├── main.tf
│   ├── compute.tf
│   ├── network.tf
│   ├── cloudflare.tf
│   ├── github.tf
│   ├── backup.tf
│   ├── outputs.tf
│   ├── variables.tf
│   └── bootstrap.sh
│
├── tfc-bootstrap/                     … Terraform Cloud 初期設定
│
└── thoughts/                          … 設計メモ・ポストモーテム
```

### 変更点まとめ

| 現状 | 移行後 | 理由 |
|---|---|---|
| `nixos/*.nix` (フラット11ファイル) | `modules/{nixos,apps,deploy,secrets}/` | 責務ごとにグループ化 |
| `lib/mkSonarNode.nix` + `lib/mkCartographerNode.nix` | `lib/mkNode.nix` (統合) | environments/*.nix が差分を吸収。app 固有の mk*Node は不要に |
| flake.nix 内の node 宣言 (domain, secretsFile 等) | `environments/*.nix` | 環境定義を flake.nix から分離 |
| `secrets/ssh/{deploy,operator}.yaml` | `secrets/ssh/{deploy,cartographer,sonar}.yaml` | app ごとの deploy key 体系に変更 |
| `terraform/*.tfstate*` | `.gitignore` に追加 | state ファイルは git 管理しない |

---

## flake.nix（flake-parts ベース）

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

注意: flake inputs に app repo を持たない。各 environment が `repo` と `ref` を直接持ち、
`nix run` や `git fetch` で直接参照する。flake.lock で app repo の rev を固定する必要がないため
（pull-deploy が EC2 上で最新の ref を追跡するのが目的）、input に入れる理由がない。

ただし `nixosConfigurations` のビルドに app の packages が必要な場合は、
`mkNode.nix` 内で `builtins.getFlake env.repo` するか、
必要に応じて inputs に追加する判断は実装時に行う。

### environments/*.nix が現 flake.nix の node 宣言を置換する

現状の flake.nix:
```nix
# 現状: flake.nix に直接書かれている
builtins.mapAttrs mkCartographerNode {
  cartographer-staging = {
    domain = "staging.baisoku-kaigi.com";
    efsFileSystemId = "fs-0a3f1c8ae1d63c51b";
    supabaseUrl = "https://...supabase.co";
    supabaseAnonKey = "eyJ...";
    workosClientId = "";
    secretsFile = ./secrets/cartographer/stg.yaml;
    appRef = "main";
  };
};
```

移行後:
```nix
# environments/cartographer-public-stg.nix
{
  repo = "git@github.com:plural-reality/cartographer.git";
  ref = "main";
  deployKey = "cartographer";         # secrets/ssh/ 内のファイル名
  platform = "nixos";                 # "nixos" or "ubuntu-system-manager"

  modules = [
    ../modules/nixos/common.nix
    ../modules/apps/cartographer.nix
    ../modules/secrets/cartographer.nix
    ../modules/deploy/pull-deploy.nix
  ];

  # app 設定（現 mkCartographerNode に渡していた値）
  domain = "staging.baisoku-kaigi.com";
  efsFileSystemId = "fs-0a3f1c8ae1d63c51b";
  supabaseUrl = "https://...supabase.co";
  supabaseAnonKey = "eyJ...";
  workosClientId = "";

  secretsPath = "cartographer/stg.yaml";

  smokeTest = {
    url = "http://localhost:3000/api/health";
    expectedStatus = 200;
    timeoutSeconds = 30;
  };
}
```

```nix
# environments/cartographer-cybozu-prod.nix
{
  repo = "git@github.com:plural-reality/cartographer.git";
  ref = "stable";
  deployKey = "cartographer";
  platform = "ubuntu-system-manager";

  modules = [
    ../modules/apps/cartographer.nix
    ../modules/deploy/pull-deploy.nix
    # NixOS 固有モジュールは含まない
    # system-manager 固有モジュールを含む
  ];

  domain = "...";
  secretsPath = "cybozu/prd.yaml";

  smokeTest = { ... };
}
```

`lib/mkNode.nix` は `env.modules` をそのまま使う。product 名からの自動判定はしない。
環境ファイルを読めば、何が deploy されるか全部わかる。

---

## Git クレデンシャル: Deploy Key (SSH)

### 選定理由

| 方式 | 評価 |
|---|---|
| 個人 SSH キー | 不適切。個人アカウントに紐づく |
| Fine-grained PAT | 不適切。個人アカウントに紐づく |
| GitHub App Installation Token | 正式だが過剰。JWT 生成→トークン発行ロジックが必要。3人チーム・4リポでは複雑さに見合わない |
| **Deploy Key (SSH)** | **採用。** リポ単位の read-only SSH キー。個人から完全分離。設定がシンプル。SOPS/KMS で秘密鍵管理可能 |

### Deploy Key の制約と対処

- 制約: 1 キー = 1 リポジトリ（同じ公開鍵を複数 repo に登録不可）
- 対処: リポごとに別の Ed25519 キーペアを生成し、`GIT_SSH_COMMAND` で切り替え

### キー管理

```
secrets/ssh/
├── deploy.yaml          … deploy repo 自身用
├── cartographer.yaml    … cartographer repo 用
└── sonar.yaml           … sonar repo 用
```

### Git 操作時の認証（one-off、グローバル状態変更なし）

```bash
GIT_SSH_COMMAND="ssh -i /run/secrets/deploy-key-cartographer -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" \
  git -C "$dest" fetch origin
```

### Nix flake 参照

`github:` fetcher は GitHub API を叩くため rate limit の対象になる（未認証 60 回/時間）。
`git+ssh://` を使うことで API を経由せず SSH 直接通信となり、rate limit が完全に無関係になる。

```bash
NIX_SSHOPTS="-i /run/secrets/deploy-key-deploy -o IdentitiesOnly=yes" \
  nix run "git+ssh://git@github.com/plural-reality/deploy#pull-deploy"
```

---

## pull-deploy の動作

### 方針: NixOS 標準機能を最大限活用する

| 機能 | 自前実装ではなく | 使うもの |
|---|---|---|
| 定期 polling + rebuild | 自前 systemd timer | `system.autoUpgrade` （NixOS 標準） |
| ロールバック | 自前 rev 管理 + 前 profile 切り替え | NixOS 世代管理（`nixos-rebuild switch --rollback`） |
| secrets 復号 | 自前スクリプト | `sops-nix` （NixOS モジュール） |
| deploy key 配置 | 自前 tmpfs 管理 | `sops-nix` の `sops.secrets` |
| smoke test | 自前ヘルスチェック | `nixos-tests` or systemd の `ExecStartPost` |

### NixOS 版: system.autoUpgrade で pull-deploy

EC2 上に deploy repo を clone し、`system.autoUpgrade` で定期的に `nixos-rebuild switch` を走らせる。
これは NixOS が標準で提供する機能で、flake 対応済み:

```nix
# modules/deploy/pull-deploy.nix
{ config, lib, ... }:
{
  system.autoUpgrade = {
    enable = true;
    flake = "/var/lib/deploy/repo#${config.networking.hostName}";
    flags = [
      "--refresh"           # キャッシュ済み flake を無効化し最新を取得
      "--print-build-logs"
    ];
    dates = "*:0/1";        # 1 分間隔
    randomizedDelaySec = "0";
    allowReboot = false;
  };

  # deploy repo を定期的に git pull する systemd service
  systemd.services.deploy-fetch = {
    description = "Fetch latest deploy repo";
    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = "/var/lib/deploy/repo";
      ExecStart = toString (pkgs.writeShellScript "deploy-fetch" ''
        GIT_SSH_COMMAND="${pkgs.openssh}/bin/ssh -i /run/secrets/deploy-key -o IdentitiesOnly=yes" \
          ${pkgs.git}/bin/git fetch origin
        ${pkgs.git}/bin/git reset --hard origin/main
      '');
    };
    # autoUpgrade の前に実行
    before = [ "nixos-upgrade.service" ];
    wantedBy = [ "nixos-upgrade.service" ];
  };

  # sops-nix で deploy key を自動配置
  sops.secrets.deploy-key = {
    sopsFile = ../../secrets/ssh/deploy.yaml;
    path = "/run/secrets/deploy-key";
    mode = "0400";
  };
}
```

`system.autoUpgrade` が提供するもの:
- systemd timer（`nixos-upgrade.timer`）
- `nixos-rebuild switch --flake ...` の実行
- ログ（`systemctl status nixos-upgrade.service`）

自前で書くものは `deploy-fetch`（git pull）だけ。残りは NixOS 標準。

### ロールバック

NixOS の世代管理がそのまま使える。自前の `current-rev` ファイルは不要:

```bash
# 直前の世代に戻す
nixos-rebuild switch --rollback

# 世代一覧
nix-env --list-generations -p /nix/var/nix/profiles/system

# 特定世代に切り替え
nix-env --switch-generation 42 -p /nix/var/nix/profiles/system
/nix/var/nix/profiles/system/bin/switch-to-configuration switch
```

GRUB にも自動で世代が登録されるため、起動時に前の世代を選択することもできる。

### Smoke Test

systemd の標準機能でアプリの起動後にヘルスチェックを行う:

```nix
# modules/deploy/smoke-test.nix
{ config, pkgs, lib, ... }:
let
  env = config.deploy.environment;
in {
  systemd.services."smoke-test-${env.domain}" = {
    description = "Smoke test for ${env.domain}";
    after = [ "app.service" ];   # アプリ起動後に実行
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "smoke-test" ''
        for i in $(seq 1 ${toString env.smokeTest.timeoutSeconds}); do
          if ${pkgs.curl}/bin/curl -sf ${env.smokeTest.url}; then
            echo "Smoke test passed"
            exit 0
          fi
          sleep 1
        done
        echo "Smoke test FAILED"
        exit 1
      '';
    };
  };
}
```

失敗時に自動 rollback したい場合は `nixos-rebuild switch` の代わりに
`nixos-rebuild test`（世代を作らない）で先に検証し、成功したら `switch` する方式も取れる。

### Ubuntu (system-manager) 版

`system.autoUpgrade` は NixOS 固有なので、Ubuntu では別途 systemd timer を定義する。
ただしロジックは同じ: git pull → system-manager switch。

```nix
# Ubuntu 用の polling timer（system-manager モジュール）
systemd.timers.deploy-poll = {
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnBootSec = "1min";
    OnUnitActiveSec = "1min";
  };
};

systemd.services.deploy-poll = {
  serviceConfig = {
    Type = "oneshot";
    ExecStart = writeShellScript "deploy-poll" ''
      cd /var/lib/deploy/repo
      GIT_SSH_COMMAND="ssh -i /run/secrets/deploy-key -o IdentitiesOnly=yes" \
        git pull --ff-only origin main
      system-manager switch
    '';
  };
};
```

### エントリポイント（初回 bootstrap のみ）

```
nix run "git+ssh://git@github.com/plural-reality/deploy#bootstrap"
```

bootstrap が行うこと:
1. deploy repo を `/var/lib/deploy/repo` に clone
2. `nixos-rebuild switch --flake /var/lib/deploy/repo#<hostname>`

以降は `system.autoUpgrade` が自動で polling + rebuild する。
bootstrap は初回のみ。鶏卵問題はここで 1 回だけ解決される。

### ディレクトリレイアウト（EC2 上）

```
/var/lib/deploy/
└── repo/                              … deploy repo の clone
    ├── flake.nix
    ├── environments/
    ├── modules/
    ├── secrets/                        … SOPS 暗号化済み（暗号文のまま）
    └── ...

/run/secrets/                          … sops-nix が自動配置（tmpfs）
├── deploy-key-deploy                  … deploy repo 用
├── deploy-key-cartographer            … cartographer repo 用
├── deploy-key-sonar                   … sonar repo 用
└── app-env                            … アプリ用環境変数（復号済み）
```

deploy key は repo ごとに分離（GitHub の制約: 同じ公開鍵を複数 repo に登録不可）。

### bootstrap（初回のみ、鶏卵の解決）

鶏卵問題: SSH key で private flake inputs を fetch したいが、SSH key は SOPS 暗号化されていて NixOS config の apply が必要。

解決: deploy repo を public（or HTTPS）で clone → SOPS CLI で key を復号 → `nixos-rebuild switch`:

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

# deploy repo を public clone（SSH key なしで取得可能にしておく）
git clone --depth 1 https://github.com/plural-reality/deploy.git "$WORK/repo"

# SOPS CLI で deploy key を復号（EC2 の IAM ロール経由で KMS にアクセス）
nix-shell -p sops --run \
  "sops -d --extract '[\"$APP\"]' $WORK/repo/secrets/ssh/deploy.yaml > $WORK/key"
chmod 600 "$WORK/key"

# 復号した key で private flake inputs を fetch しつつ rebuild
export GIT_SSH_COMMAND="ssh -i $WORK/key -o StrictHostKeyChecking=accept-new"
/run/current-system/sw/bin/nixos-rebuild switch \
  --flake "$WORK/repo#${TAG}-bootstrap" \
  --refresh
```

bootstrap 後は `system.autoUpgrade` が引き継ぐ。bootstrap は初回のみ。
Terraform の `user_data` でこのスクリプトを実行する。

---

## NixOS 版 vs Ubuntu (system-manager) 版

| | NixOS (公開版) | Ubuntu + system-manager (Cybozu版) |
|---|---|---|
| OS 管理 | Terraform + NixOS AMI | サイボウズ側管理 |
| polling | `system.autoUpgrade`（標準） | 自前 systemd timer |
| activate | `nixos-rebuild switch`（autoUpgrade が自動実行） | `system-manager switch` |
| rollback | NixOS 世代管理（`--rollback`、GRUB メニュー） | 前 config に切り替え |
| secrets | `sops-nix` モジュール | sops CLI |
| 初回 bootstrap | Terraform user_data: `nix run ...#bootstrap` | SSH で bootstrap 1 回 |

---

## Secrets 管理

### SOPS 設定（複数 KMS キー対応）

```yaml
# secrets/.sops.yaml
creation_rules:
  - path_regex: cybozu/.*\.yaml$
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
| 定期 polling + rebuild | `system.autoUpgrade` | NixOS 標準。timer + nixos-rebuild を提供 |
| ロールバック | NixOS 世代管理 | 自前の rev 追跡不要。`--rollback` や GRUB で切り替え |
| secrets 管理 | `sops-nix` | NixOS モジュール。tmpfs への復号・systemd 連携を自動化 |
| バイナリキャッシュ | Cachix | EC2 でのフルビルド回避 |
| flake 構造化 | flake-parts | perSystem / flake の分離 |
| Nix GC | `nix.gc` | NixOS 標準。世代の自動削除でディスク肥大防止 |
| Ubuntu 宣言管理 | `numtide/system-manager` | Ubuntu EC2 を NixOS 的に管理 |

### 検討したが不採用のツール

| ツール | 評価 | ステータス |
|---|---|---|
| `deploy-rs` | magic rollback が優秀だが push 型前提。pull 型アーキテクチャには不適合 | 不採用 |
| `nixos-autodeploy` | derivation-based gating（drift 防止）、`/run/upstream-system` によるプレビュー、Prometheus metrics が魅力。ただし Colmena 等の push-deploy との協調前提で設計されており、今の自己完結 pull 型とは思想が異なる。2025年6月公開で若い | **ウォッチ**。monitoring が必要になったら再検討 |
| `colmena` | NixOS 前提で push 型。Ubuntu 非対応。既に脱却済み | 不採用 |
| `nixops` | ステートフルで複雑。3人チームには過剰 | 不採用 |

```nix
# modules/nixos/common.nix に含める
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
EC2:          nix build → Cachix cache hit → activate（一瞬）
```

---

## 開発環境（devenv）

### devenv は deploy repo にのみ存在する

app repo に devenv / devShell は置かない。
app repo が持つのは flake の `packages` と `apps.up` のみ。

```
deploy repo の devShell
├── 言語ツールチェイン（Node, Haskell 等）
├── リンター、フォーマッター
├── sops, age, terraform, cachix
└── nix run .#dev-*
```

### dev コマンド（environments から自動生成）

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
- **Webhook**: 即時反映が必要な場合（polling と併用）
- **EC2 追加**: pull-deploy を実行するだけ
