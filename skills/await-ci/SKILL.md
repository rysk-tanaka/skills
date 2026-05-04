---
name: await-ci
description: CIチェックの状態確認・完了待機 (user)
license: MIT
argument-hint: "[pr-number]"
allowed-tools: Bash(bash *) BashOutput
---

# CI チェック状態確認

PR の CI チェック状態を取得し、必要に応じて完了まで待機する。

## 入力

`$ARGUMENTS` に PR 番号が渡される（省略時は現在のブランチから自動検出）。

## 手順

### 1. チェック状態の取得

`bash ${CLAUDE_SKILL_DIR}/check.sh $ARGUMENTS` を実行する。

- `$ARGUMENTS` が空の場合は引数なしで実行（スクリプト側で自動検出）
- スクリプトが非ゼロ終了した場合は、終了コードと stderr を確認する

### 2. 出力の解析

スクリプトの stdout は JSON 形式で以下のフィールドを含む。

- `pr_number` - PR番号
- `status` - 全体ステータス（"pass", "fail", "pending", "no_checks"）
- `elapsed_seconds` - 経過時間（秒）
- `summary` - バケットごとのカウント
  - `total`, `pass`, `fail`, `pending`, `skipping`, `cancel`
- `checks` - 個別チェックの配列
  - `name` - チェック名
  - `bucket` - 結果バケット（pass/fail/pending/skipping/cancel）
  - `state` - 詳細ステータス
  - `description` - 説明
  - `workflow` - ワークフロー名
  - `link` - 詳細URL

### 3. 結果の報告

status に応じて報告する。

#### status が "no_checks" の場合

CI チェックが設定されていない旨を報告する。

#### status が "pass" の場合

全チェックが通過した旨を報告する。pass と skipping の件数を表示する。

#### status が "fail" の場合

失敗したチェックの一覧を報告する（name, description, link）。
link を提示し、詳細確認を促す。

#### status が "pending" の場合

pending のチェック名と件数を報告し、ユーザーに待機するか確認する。

待機する場合は `--watch` フラグ付きで再実行する。

```text
bash ${CLAUDE_SKILL_DIR}/check.sh <PR番号> --watch
```

Bash tool の timeout パラメータは 600000（最大値）を指定する。

バックグラウンド実行を希望される場合は `run_in_background=true` で実行し、
BashOutput で定期的に出力を監視する。

### 4. タイムアウト

watch モードが exit 2 で終了した場合はタイムアウト。

- その時点のチェック状態を報告する
- 引き続き pending のチェック名を一覧表示する
- GitHub Actions の URL を提示し、手動確認を促す
