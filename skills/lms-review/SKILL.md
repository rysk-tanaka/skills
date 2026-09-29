---
name: lms-review
description: LM Studio のローカル LLM でブランチ差分をレビュー (user)
license: MIT
argument-hint: "[base-branch]"
allowed-tools: Bash(bash *) BashOutput
---

# ローカル LLM レビュー

LM Studio で動くローカル LLM に、ベースブランチとの差分（`git diff <base>...HEAD`）を渡して独立レビューを受ける。モデルが見るのは diff だけで、リポジトリのファイルは読まない。

## 入力

`$ARGUMENTS` にベースブランチが渡される（省略可、デフォルト main）。

例

- `/lms-review` → main との差分
- `/lms-review develop` → develop との差分

## 実行

`git log --oneline <base>..HEAD` でコミットを確認し（ローカルに `<base>` が無ければ `origin/<base>` を使う。スクリプトと同じ解決順）、変更の目的・背景を 1〜2 文にまとめる。コミットが無ければレビュー対象が無い旨を報告して終了する。

次のコマンドを必ず `run_in_background=true` で起動する（ローカルモデルは数分かかり、ラッパーのタイムアウト既定 900 秒が Bash ツールの上限 600 秒を超えるため）。

```bash
bash ${CLAUDE_SKILL_DIR}/lms-review.sh "<base>" "$(cat <<'LMS_TEXT'
<変更概要>
LMS_TEXT
)"
```

- 自由記述の文字列は、本文を展開しない quoted heredoc（`<<'LMS_TEXT'`）で渡す。ダブルクォートに直接埋め込むと、識別子を囲むバッククォートや `$(...)` をシェルがコマンドとして実行してしまうため
- 起動したら「ローカル LLM のレビューをバックグラウンドで開始した」とだけ伝え、このターンでは待たない
- 完了通知が届いたら、stdout をそのまま提示する。要約・言い換え・独自の指摘の追加はしない

## 制約

- レビュー専用。指摘を修正したり、修正に取りかかると伝えたりしない
- コミット済みの変更のみが対象。未コミットの作業ツリーは含まれない
- 推測に基づく指摘はモデル側で「低確信」と明記される。裏取りするかどうかはユーザーの判断に委ねる

## 失敗時

非ゼロ終了した場合は stderr の `ERROR:` 行をそのまま伝えて終了する。主な原因。

- サーバーに接続できない（Mac mini のスリープ、LM Studio 停止、Tailscale 切断）
- diff が上限（既定 60KB）を超えている
- モデルキーの誤り（LM Studio に無いキーは実行前に弾き、使えるモデルの一覧を出す）
- 認証エラー（LM Studio のエラー本文が stderr に出る）

## 設定

環境変数で指定する。

| 変数 | 用途 | 既定値 |
| --- | --- | --- |
| `LM_API_URL` | LM Studio サーバーのルート URL（`/v1` は付けない） | `http://localhost:1234` |
| `LM_API_TOKEN` | 認証トークン | なし |
| `LM_API_TOKEN_COMMAND` | トークンを標準出力に出すコマンド（例: `op read 'op://...'`）。`LM_API_TOKEN` が空のとき、接続確認の後にだけ実行される | なし |
| `LMS_REVIEW_MODEL` | モデルキー（`lms ls` で確認） | `qwen/qwen3.6-27b` |
| `LMS_REVIEW_TIMEOUT` | リクエストのタイムアウト秒数 | `900` |
| `LMS_REVIEW_MAX_DIFF_BYTES` | diff の上限 | `60000` |
| `LMS_REVIEW_TTL` | JIT ロードしたモデルを最後のリクエストからアンロードするまでの秒数 | `600` |
