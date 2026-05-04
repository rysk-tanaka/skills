---
name: cloudwatch-logs
description: CloudWatchログの取得・検索（Lambda関数のログ解析、エラー調査）
license: MIT
argument-hint: "<log-group-name>"
allowed-tools: Bash(uv run *)
---

# CloudWatch Logs 取得

CloudWatchログを取得・検索します。

## 実行コマンド

引数: `$ARGUMENTS`（ロググループ名）

```bash
uv run ${CLAUDE_SKILL_DIR}/cloudwatch_logs.py $ARGUMENTS
```

## オプション

| オプション | 説明 | デフォルト |
| --- | --- | --- |
| `--hours`, `-H` | 過去N時間のログを取得 | 1 |
| `--filter-pattern`, `-f` | カスタムフィルタパターン | なし |
| `--profile`, `-p` | AWSプロファイル名 | AWS_PROFILE環境変数 |
| `--region`, `-r` | AWSリージョン | ap-northeast-1 |
| `--max-events`, `-n` | 最大イベント数 | 100 |

## タスク

1. スクリプトを実行してログを取得
2. 出力結果を分析し、概要を日本語で報告
3. エラーが検出された場合は詳細を報告
