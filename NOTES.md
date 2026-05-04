# 実装ノート

agentskills.io 仕様 + Claude Code 固有挙動について、本リポジトリ作成時に実機検証して得た知見。

## 検証環境

- 検証日 — 2026-05-04
- Claude Code — 2.1.114
- GitHub CLI — 2.90.0

## `${CLAUDE_SKILL_DIR}` の置換は body のみで動作

[Claude Code のスキル docs](https://code.claude.com/docs/en/skills) は `${CLAUDE_SKILL_DIR}` を「string substitution for dynamic values in the skill content」と説明していますが、検証の結果、**置換が起きるのは body content のみ**で、frontmatter `allowed-tools` 内では機能しません。

| 配置場所 | 置換 | 検証方法 |
| --- | --- | --- |
| body (markdown 部分) | OK | skill 起動時に LLM が見る body は絶対パスに pre-render 済み |
| frontmatter `allowed-tools` | NG | リテラル比較で実コマンドにマッチせず permission denial |

検証の決め手は `claude -p --max-turns 5 --output-format json '/auto-commit'` で fresh session を立ち上げ、`allowed-tools: Bash(bash ${CLAUDE_SKILL_DIR}/collect.sh:*)` を設定した状態で `bash /Users/rysk/.claude/skills/auto-commit/collect.sh` が `permission_denials` 配列に並んだこと。

帰結。

- script のパス指定は body 内で `${CLAUDE_SKILL_DIR}/<script>` を使い、portable に保つ
- `allowed-tools` は **command 名ベースの広い pattern** (`Bash(bash *)`, `Bash(python3 *)` 等) で書く
- 厳格な path permission を必要とするなら、consumer 側 `~/.claude/settings.json` の `permissions.allow` に**絶対パスを書く** (skill には押し付けない)

## `allowed-tools` の format

agentskills.io spec ([specification](https://agentskills.io/specification)) は `allowed-tools` を space-delimited string と定義しますが、Claude Code のドキュメントは YAML list 形式の例も挙げており曖昧です。本リポジトリでは spec 通り **string 形式**で統一しています。

```yaml
# OK (spec 準拠)
allowed-tools: Bash(bash *) BashOutput

# NG (gh skill publish --dry-run でエラー)
allowed-tools:
  - Bash(bash *)
  - BashOutput
```

`gh skill publish --dry-run` を validation gate として使うと、この種の不適合は検出されます。

## `argument-hint` で bracket を含む値は quote が必要

Claude Code docs は `argument-hint: [filename] [format]` のような書式例を載せていますが、これは strict YAML parser では invalid (inline array `[filename]` の後に余計な token があると見なされる)。`gh skill publish --dry-run` の YAML parser は厳格なので、quote しないと `invalid frontmatter YAML: yaml: line N: did not find expected key` で落ちます。

```yaml
# OK
argument-hint: "[base-branch] [--bg]"

# NG (gh skill validator の YAML parser でエラー)
argument-hint: [base-branch] [--bg]
```

単一の bracket (`[pr-number]`) は YAML 上「単一要素の inline array」として通るが、Claude Code は string として扱うため意味が変わる。**全ケースで quote するのが安全**。

## `allowed-tools` は実は permission を granular に grant しない

Claude Code には [#14956](https://github.com/anthropics/claude-code/issues/14956) (2025-12-21 時点で OPEN) のバグがあり、`allowed-tools` で path 付き Bash pattern を書いても **実際には permission が付与されない**ことが知られています。

> When a skill defines `allowed-tools` in its SKILL.md frontmatter, the permission is reported as active but Bash commands matching the pattern are still denied.

そのため `allowed-tools` は実質的に「pre-approve の意図表明 + ドキュメント」役割になり、actual permission gate は consumer 側 `settings.json` `permissions.allow` が担います。これも上記「広い pattern」を許容する根拠の 1 つ。

## `${CLAUDE_SKILL_DIR}` は symlink path で展開される

dotfiles 経由で `~/.claude/skills/<name>` が他リポジトリへの symlink になっている環境では、`${CLAUDE_SKILL_DIR}` は **symlink path** (`/Users/rysk/.claude/skills/auto-commit`) として展開され、内部 realpath ではありません。これにより、consumer 側の `settings.json` で書く絶対パスは symlink 形式 (`/Users/rysk/.claude/skills/<name>/<script>`) のままで一致します。

## 推奨パターン (本リポジトリの全 skill が採用)

```yaml
---
name: <skill-name>
description: <description>
license: MIT
argument-hint: "<args>"               # quote 必須
allowed-tools: Bash(bash *) BashOutput # space-delimited、command 名ベース
---

# 本文

`bash ${CLAUDE_SKILL_DIR}/<script>.sh` を実行する。
```

第三者は厳格な path 制限を希望する場合、`~/.claude/settings.json` に下記のような entry を追加。

```json
{
  "permissions": {
    "allow": [
      "Bash(bash /Users/you/.claude/skills/<name>/<script>.sh:*)"
    ]
  }
}
```

## 検証の再現方法

skill の挙動を確かめたい場合、fresh session の方が信頼できる(同一セッション内では SKILL.md 編集後も古い permission がキャッシュされうる)。

```bash
# 別ディレクトリから headless 起動
cd /tmp
claude -p --output-format json --max-turns 5 '/<skill-name>' \
  | jq '.[] | select(.type=="result") | {result, permission_denials}'
```

`permission_denials` 配列が空なら通った、要素があれば該当 tool 呼び出しが拒否された。
