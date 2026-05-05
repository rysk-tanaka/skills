# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## このリポジトリ

`rysk-tanaka/skills` — Claude Code 向け個人 Agent Skills 集([agentskills.io specification](https://agentskills.io/specification) 準拠)。配布チャネルは `gh skill install rysk-tanaka/skills <name> --agent claude-code`。

ユーザー向け README / 各 `SKILL.md` 本文は日本語、frontmatter / shell script / Python はすべて英語。

## レイアウト

```tree
skills/<skill-name>/
├── SKILL.md            必須。frontmatter + body
├── <helper>.sh / .py   任意。body から ${CLAUDE_SKILL_DIR}/<helper> で呼ばれる
└── ...
```

`SKILL.md` 1 つにつき skill 1 つ。skill 名 = ディレクトリ名 = frontmatter `name`。helper script は SKILL.md 本文から呼び出され、構造化データ(主に JSON)を stdout に吐いて LLM に渡す pattern。

## 検証 / リリース

このリポジトリは build / test / lint の中央 task runner を持たない。検証コマンド (`gh skill publish --dry-run` / fresh session での実機テスト) と release 手順 (`gh skill publish --fix --tag`) は [README.md の「リリース」節](README.md#リリース-maintainer-向け) を参照。

linter は dotfiles repo から symlink された `.markdownlint-cli2.jsonc` と `.pre-commit-config.yaml` が pre-commit hook として動く。

## maintainer 環境での消費

rysk の dotfiles では `mise run setup-skills` が `~/Repositories/rysk/skills/skills/<name>` を `~/Repositories/rysk/dotfiles/.claude/skills/<name>` に per-skill symlink で配置する。`~/.claude/skills` は dotfiles `.claude/skills` への symlink なので、このリポジトリで編集した内容は即座に Claude Code セッションへ反映される(`gh skill install --force` 等の再 install は不要)。

## SKILL.md frontmatter の規約

検証で得たハマりどころ(`${CLAUDE_SKILL_DIR}` の置換範囲、`allowed-tools` の format/既知バグ、`argument-hint` の quote 必須)はすべて [NOTES.md](NOTES.md) 参照。新規 skill は下記テンプレートから始める。

```yaml
---
name: <skill-name>
description: <description>
license: MIT
argument-hint: "<args>"                # 必ず quote
allowed-tools: Bash(bash *) BashOutput # space-delimited、command 名ベース
---
```

## helper script の規約

- `set -euo pipefail` で開始。`mktemp -d` + `trap 'rm -rf "$WORK_DIR"' EXIT` で一時ファイルを掃除。
- 外部依存は readme に記載済み: bash/Python skill 共通で `git`, `gh`, `jq`。Python skill は `uv run` で起動し PEP 723 inline script metadata で依存を宣言する(`cloudwatch-logs/cloudwatch_logs.py` 参照)。
- 大きな diff を含む output(`auto-commit`, `pr`)はデフォルトで lockfile / 500 行超 / 50KB 超を除外する。
- バックグラウンド対応 skill (`codex-review`, `resolve-review`) は `--bg` 引数で `run_in_background=true` に切り替え、`$HOME/.cache/claude-bg/<name>-*.txt` にログを残す方式。
