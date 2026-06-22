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

| Name | 推奨 scope | 説明 |
| --- | --- | --- |
| `auto-commit` | user | ステージ済みの変更から Conventional Commits メッセージ候補を生成 |
| `await-ci` | user | PR の GitHub Actions CI ステータスを確認・完了待機 |
| `pr` | user | ブランチ差分を分析し、リポジトリの template に従って pull request を作成 |
| `resolve-review` | user | PR の未解決レビューコメントを取得・分類(CI 待機 helper を同梱) |
| `suggest-branch` | user | working tree の状態からブランチ名候補を提案 |
| `codex-review` | user | Codex CLI でコードレビューを実行し、結果を分類して報告 |
| `drawio` | project | `.drawio` 図表を生成、PNG / SVG / PDF へエクスポート可 |
| `drawio-aws` | project | `drawio` 経由で AWS 4 アイコンセットを使った AWS アーキテクチャ図を生成 |
| `cloudwatch-logs` | project | CloudWatch Logs の取得・検索(Lambda ログ解析、エラー調査) |
| `design-doc-yaml` | user | 設計内容をYAMLに集約し、診断レビューを経て肥大化しないMarkdown設計書を作成 |

「推奨 scope」は `gh skill install --scope <user|project>` の指針で、frontmatter `description` の `(user)` suffix と対応。user scope はどのリポジトリでも常用したい汎用 skill (git / PR / CI 系)、project scope は特定プロジェクトに紐付く domain 固有 skill (AWS, draw.io 等) を想定。あくまで推奨で、好みで上書き可能。

各 skill の `SKILL.md` 本文はほとんど日本語で記述されています(作者が日本人のため)。コード、frontmatter、helper script は英語です。

## 互換性

主に Claude Code 向けに設計しています。skill は Claude Code 固有の `${CLAUDE_SKILL_DIR}` 変数で script のパスを portable に解決するため、agentskills.io 仕様に準拠した他 agent でこの変数をサポートしないものではそのままでは動作しない可能性があります。

skill 別の外部依存。

- `auto-commit`, `await-ci`, `pr`, `resolve-review`, `suggest-branch`, `codex-review`: `git`, `gh`, `jq`
- `codex-review`: Codex CLI (`codex`)
- `drawio`, `drawio-aws`: draw.io デスクトップアプリ
- `cloudwatch-logs`: `uv`, AWS 認証情報
- `design-doc-yaml`: `uv`

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

実運用例 (全 skill 分の絶対パスエントリ): [rysk-tanaka/dotfiles の `.claude/settings.json`](https://github.com/rysk-tanaka/dotfiles/blob/main/.claude/settings.json)。

## 実装ノート

agentskills.io 仕様および Claude Code 固有の挙動に関する実証ベースのメモは [NOTES.md](NOTES.md) を参照。`${CLAUDE_SKILL_DIR}` の置換範囲、`allowed-tools` format の落とし穴、検証の再現方法など。

## リリース (maintainer 向け)

```bash
# 1. frontmatter / メタデータ validation
gh skill publish --dry-run

# 2. release tag を切る (GitHub Release を作成、--fix で provenance metadata を剥がす)
gh skill publish --fix --tag vX.Y.Z

# 3. topic 確認 (初回のみ、agent-skills が無ければ追加)
gh repo edit rysk-tanaka/skills --add-topic agent-skills
```

`gh skill publish` は git remote URL からリポジトリを判定する。複数アカウント運用などで SSH host alias (`git@github.com-<alias>:...` 形式) を使っている場合は「not a GitHub repository」と warning が出るので、publish 時のみ remote を標準ホスト形式 (`git@github.com:<owner>/<repo>.git`) に切り替える (終わったら戻す)。

各 skill の動作確認は fresh session で行うのが信頼性が高い。同一セッションは permission キャッシュが残るため。

```bash
cd /tmp && claude -p --output-format json --max-turns 5 '/<skill-name>' \
  | jq '.[] | select(.type=="result") | {result, permission_denials}'
```

`permission_denials` 配列が空なら通過、要素があれば該当 tool 呼び出しが拒否されている。

## ライセンス

MIT — [LICENSE](LICENSE) を参照。
