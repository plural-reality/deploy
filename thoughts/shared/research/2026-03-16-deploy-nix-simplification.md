---
date: 2026-03-16
researcher: claude
git_commit: 5159c11b9e91a60d0f95c6117240cdf344a4faca
branch: main
repository: deploy
topic: "deploy.nix 簡素化: nixos-rebuild test + store path 比較による自動デプロイ"
tags: [deploy, nixos, nixos-rebuild, rollback, self-deploy, simplification]
status: ready-to-implement
last_updated: 2026-03-16
last_updated_by: claude
---

# deploy.nix 簡素化

## 動機

現在の `deploy.nix` (~190行) は自前のポーリング・差分検知・rollback ロジックを持つ。
NixOS の profile / generation 機構を直接使えば、同等の機能を ~60行で実現できる。

## 設計

### 原理

| 現在の自前実装 | NixOS が提供する等価機構 |
|----------------|--------------------------|
| `git fetch` + `rev-parse` 比較 | `nixos-rebuild build` → store path 比較 |
| `git ls-remote` で app repo 変更検知 | `--override-input` + `--refresh` で nix が直接 fetch |
| local git clone (`deploy-repo-init`) | `github:` flake URL で tarball fetch |
| `flock` による排他制御 | systemd `Type=oneshot` |
| `PREV_SYSTEM=$(readlink ...)` + 手動 rollback | `switch-to-configuration test` (profile 不変) → 失敗時に profile から restore |
| `systemctl restart supabase` | `switch-to-configuration` が変更サービスのみ restart |

### フロー

```
deploy-poll.timer (5min, OnBootSec=2min, ±30s jitter)
  │
  ▼
deploy-poll.service → deployScript
  │
  ├─ nixos-rebuild build
  │    --flake "github:plural-reality/deploy/<branch>#<node>"
  │    --override-input sonar "git+ssh://..."
  │    --refresh
  │    → /var/lib/sonar-deploy/result
  │
  ├─ store path 比較
  │    NEW=$(readlink -f result)
  │    CURRENT=$(readlink -f /run/current-system)
  │    同一 → "No changes", exit 0
  │
  ├─ $NEW/bin/switch-to-configuration test
  │    (activate のみ。profile/bootloader 不変)
  │
  ├─ curl smoke test (localhost:3000, retry×3)
  │    fail → $CURRENT/bin/switch-to-configuration switch (即 rollback)
  │    pass ↓
  │
  ├─ nix-env --profile /nix/var/nix/profiles/system --set "$NEW"
  └─ $NEW/bin/switch-to-configuration switch (commit)
```

### 削除対象

| 対象 | 理由 |
|------|------|
| `deploy-repo-init` service | `github:` flake URL に統合 |
| `pollScript` | store path 比較で代替 |
| `checkInputsScript` | `--override-input` + `--refresh` で代替 |
| `repoUrl` option | flake URL に統合 |
| `deployScript` の git 操作 | nix が直接 fetch |
| `flock` | systemd oneshot |
| `systemctl restart supabase` | NixOS service diffing |
| `version.nix` の `inputRevisions` | change detection 不要 |

### `system.autoUpgrade` を使わない理由

- `operation = "test"` 未対応 (switch/boot のみ)
- smoke test / rollback 機構なし
- no-op 検知なし (毎回 switch 実行)
- 半端にラップするより薄い自前 service のほうが clean

### コード

```nix
{ config, lib, pkgs, ... }:
let
  cfg = config.sonar.deploy;
  sshKeyPath = "/run/secrets/deploy-ssh-key";
  gitSshCommand = "${pkgs.openssh}/bin/ssh -i ${sshKeyPath} -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null";

  overrideFlags = lib.concatLists (
    lib.mapAttrsToList (name: url: [ "--override-input" name url ]) cfg.appInputs
  );

  deployScript = pkgs.writeShellScript "sonar-deploy" ''
    set -euo pipefail

    /run/current-system/sw/bin/nixos-rebuild build \
      --flake "github:plural-reality/deploy/${cfg.trackBranch}#${cfg.nodeName}" \
      ${lib.concatStringsSep " " (map lib.escapeShellArg overrideFlags)} \
      --refresh

    NEW=$(readlink -f result)
    CURRENT=$(readlink -f /run/current-system)

    [ "$NEW" = "$CURRENT" ] && { echo "No changes"; exit 0; }
    echo "=== Change: $CURRENT -> $NEW ==="

    "$NEW/bin/switch-to-configuration" test

    sleep 5
    ${pkgs.curl}/bin/curl -sf --max-time 30 --retry 3 --retry-delay 5 \
      http://localhost:3000 || {
        echo "ERROR: Smoke test failed. Rolling back..."
        "$CURRENT/bin/switch-to-configuration" switch
        exit 1
      }

    ${pkgs.nix}/bin/nix-env --profile /nix/var/nix/profiles/system --set "$NEW"
    "$NEW/bin/switch-to-configuration" switch
    echo "=== Deploy complete at $(date -Iseconds) ==="
  '';
in
{
  options.sonar.deploy = {
    enable = lib.mkEnableOption "polling-based self-deploy";
    nodeName = lib.mkOption { type = lib.types.str; };
    trackBranch = lib.mkOption { type = lib.types.str; default = "main"; };
    appInputs = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = { }; };
    pollInterval = lib.mkOption { type = lib.types.str; default = "5min"; };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.deploy-poll = {
      description = "Poll and deploy NixOS configuration";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment.GIT_SSH_COMMAND = gitSshCommand;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = deployScript;
        StateDirectory = "sonar-deploy";
        WorkingDirectory = "/var/lib/sonar-deploy";
      };
    };

    systemd.timers.deploy-poll = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = cfg.pollInterval;
        RandomizedDelaySec = "30s";
      };
    };
  };
}
```

## Next Actions

1. **`deploy.nix` を上記コードで置換**
   - `version.nix` から `inputRevisions` 関連を削除
   - `flake.nix` から `inputRevisions` specialArg を削除

2. **staging で検証**
   - `sonar-staging` に deploy → timer 発火を確認
   - app repo に dummy commit → 5分以内に deploy されることを確認
   - smoke test 失敗シナリオ: port 3000 を止めた状態で deploy → rollback を確認

3. **prod 適用**
   - staging 検証後に main へ merge
