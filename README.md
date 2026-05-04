# rysk-tanaka/skills

Claude Code 用の個人 Agent Skills 集。[Agent Skills specification](https://agentskills.io/specification) 準拠。

## インストール

```bash
gh skill install rysk-tanaka/skills <skill-name> --agent claude-code
```

例: `auto-commit` を user scope に release tag pinning でインストールする場合。

```bash
gh skill install rysk-tanaka/skills auto-commit --agent claude-code --scope user --pin v0.1.0
```

## Skills 一覧

| Name | 説明 |
| --- | --- |
| `auto-commit` | ステージ済みの変更から Conventional Commits メッセージ候補を生成 |
| `await-ci` | PR の GitHub Actions CI ステータスを確認・完了待機 |
| `pr` | ブランチ差分を分析し、リポジトリの template に従って pull request を作成 |
| `resolve-review` | PR の未解決レビューコメントを取得・分類(CI 待機 helper を同梱) |
| `suggest-branch` | working tree の状態からブランチ名候補を提案 |
| `codex-review` | Codex CLI でコードレビューを実行し、結果を分類して報告 |
| `drawio` | `.drawio` 図表を生成、PNG / SVG / PDF へエクスポート可 |
| `drawio-aws` | `drawio` 経由で AWS 4 アイコンセットを使った AWS アーキテクチャ図を生成 |
| `cloudwatch-logs` | CloudWatch Logs の取得・検索(Lambda ログ解析、エラー調査) |

各 skill の `SKILL.md` 本文はほとんど日本語で記述されています(作者が日本人のため)。コード、frontmatter、helper script は英語です。

## 互換性

主に Claude Code 向けに設計しています。skill は Claude Code 固有の `${CLAUDE_SKILL_DIR}` 変数で script のパスを portable に解決するため、agentskills.io 仕様に準拠した他 agent でこの変数をサポートしないものではそのままでは動作しない可能性があります。

skill 別の外部依存。

- `auto-commit`, `await-ci`, `pr`, `resolve-review`, `suggest-branch`, `codex-review`: `git`, `gh`, `jq`
- `codex-review`: Codex CLI (`codex`)
- `drawio`, `drawio-aws`: draw.io デスクトップアプリ
- `cloudwatch-logs`: `uv`, AWS 認証情報

## 権限

各 skill は install 場所を問わず動くよう `allowed-tools: Bash(bash *)` という広めの pattern を宣言しています。自分のマシンで script 単位に権限を絞りたい場合は、`~/.claude/settings.json` に絶対パスエントリを追加してください。

```json
{
  "permissions": {
    "allow": [
      "Bash(bash /Users/you/.claude/skills/auto-commit/collect.sh:*)"
    ]
  }
}
```

## 実装ノート

agentskills.io 仕様および Claude Code 固有の挙動に関する実証ベースのメモは [NOTES.md](NOTES.md) を参照。`${CLAUDE_SKILL_DIR}` の置換範囲、`allowed-tools` format の落とし穴、検証の再現方法など。

## ライセンス

MIT — [LICENSE](LICENSE) を参照。
