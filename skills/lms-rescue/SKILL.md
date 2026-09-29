---
name: lms-rescue
description: LM Studio のローカル LLM に調査・修正を委任（Codex CLI 経由） (user)
license: MIT
argument-hint: "[--write|--read-only] [--resume|--fresh] [--model <key>] <依頼内容>"
allowed-tools: Bash(bash *) BashOutput AskUserQuestion
---

# ローカル LLM への委任

LM Studio で動くローカル LLM に、調査・修正を任せる。エージェントの実行環境には Codex CLI を使い、モデルはリポジトリのファイルを読んだりコマンドを実行したりできる。

## 入力

`$ARGUMENTS` に依頼内容とオプションが渡される。依頼内容が無い場合は、何を調査・修正させるかをユーザーに尋ねる。

例

- `/lms-rescue テストが落ちる原因を調べて` → 読み取り専用で調査
- `/lms-rescue --write parse_date のタイムゾーン処理を直して` → 作業ツリー内の編集を許可
- `/lms-rescue --resume 続けて` → 直前のセッションを引き継ぐ

## オプションの解釈

- `--write`: 作業ツリー内の編集を許可する（Codex の workspace-write sandbox）
- `--read-only`: 編集させない
- どちらも無い場合は依頼内容から判断する。修正・実装を明示的に求めていれば `--write`、調査・診断・レビューだけなら読み取り専用にする
- `--resume`: この作業ディレクトリで直前の lms-rescue セッションを引き継ぐ。`--model` を付けなければ、そのセッションで使ったモデルのまま続ける
- `--fresh`: 新しいセッションで始める
- `--resume` も `--fresh` も無く、依頼が「続けて」「その修正を適用して」のような継続の指示なら `--resume` を付ける。それ以外は新しいセッションにする
- `--model <key>`: モデルを指定する（`lms ls` のキー）。指定が無ければ付けない
- `--read-only` と `--fresh` はラッパーに渡さない（既定の動作のため）

## 実行

次のコマンドを必ず `run_in_background=true` で起動する（ローカルモデルのエージェント実行は数分から数十分かかり、Bash ツールの上限 600 秒を超えうるため）。

```bash
bash ${CLAUDE_SKILL_DIR}/lms-rescue.sh [--write] [--resume] [--model <key>] -- "$(cat <<'LMS_TEXT'
<依頼内容>
LMS_TEXT
)"
```

- 依頼内容はユーザーの文面を基本的にそのまま渡す。オプションだけを取り除く
- 自由記述の文字列は、本文を展開しない quoted heredoc（`<<'LMS_TEXT'`）で渡す。ダブルクォートに直接埋め込むと、識別子を囲むバッククォートや `$(...)` をシェルがコマンドとして実行してしまうため
- `--` は依頼内容の前に必ず置く（依頼内容が `--` で始まってもオプションと解釈させないため）
- 起動したら「ローカル LLM に委任した」とだけ伝え、このターンでは待たない
- 完了通知が届いたら、stdout をそのまま提示する。要約・言い換え・独自の追加作業はしない

## 制約

- 委任に徹する。リポジトリを自分で調べたり、モデルの代わりに修正したりしない
- `--write` の実行後は、stdout 末尾の作業ツリーの状態をそのまま示す。変更の採否はユーザーに委ねる
- ローカルモデルは誤った修正をしやすい。変更をコミットする前に差分を確認するようユーザーに促す

## 失敗時

非ゼロ終了した場合は stderr の `ERROR:` 行と、続くログの末尾をそのまま伝えて終了する。主な原因。

- サーバーに接続できない（Mac mini のスリープ、LM Studio 停止、Tailscale 切断）
- `codex` CLI が無い
- 認証エラーやモデルキーの誤り
- コンテキスト長の不足（LM Studio でモデルのコンテキスト長を 64K 程度に設定する）

## 設定

接続先と認証は `lms-review` と共通の環境変数を使う。

| 変数 | 用途 | 既定値 |
| --- | --- | --- |
| `LM_API_URL` | LM Studio サーバーのルート URL（`/v1` は付けない） | `http://localhost:1234` |
| `LM_API_TOKEN` | 認証トークン | なし |
| `LM_API_TOKEN_COMMAND` | トークンを標準出力に出すコマンド（例: `op read 'op://...'`）。`LM_API_TOKEN` が空のとき、接続確認の後にだけ実行される | なし |
| `LMS_RESCUE_MODEL` | モデルキー | `qwen/qwen3.6-35b-a3b` |
| `LMS_RESCUE_CONTEXT_WINDOW` | LM Studio 側のコンテキスト長（Codex の自動圧縮の目安） | なし |
| `LMS_RESCUE_HOME` | セッションとログの保存先 | `~/.local/state/lms-rescue` |

セッションは専用の `CODEX_HOME`（`$LMS_RESCUE_HOME/codex`）に保存されるため、普段の Codex の履歴や設定とは混ざらない。実行ごとの詳細ログは `$LMS_RESCUE_HOME/logs/` に残る。
