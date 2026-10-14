---
name: review-router
description: 差分を分析して規模・観点に応じたレビューを自動振り分けし、Must-Fix・Important を未コミットのまま自動修正して再レビューする (user)
license: MIT
argument-hint: "[base-branch] [--agy] [--lms]"
allowed-tools: Bash(bash *) Bash(git status *) Bash(git diff *) Bash(git merge-base *) Bash(git add -N *) BashOutput Task Edit Write
---

# レビュー・ルーター

ベースブランチとの差分を分析し、規模・触れた観点・リスクから tier を判定して、適切なレビューだけを自動起動する。「ローカルか PR か」は人が決め、深さと観点の選択はこのスキルに任せるのが狙い。

## 入力

`$ARGUMENTS` にベースブランチとオプションが渡される（どちらも省略可、ベースブランチのデフォルトは main）。

- `--agy` - agy CLI（Gemini）による独立レビューを追加で実行する
- `--lms` - ローカル LLM による独立レビューを追加で実行する

agy CLI とローカル LLM は誤検出が多いため、指定したときだけ動かす。

例

- `/review-router` → main との差分
- `/review-router develop` → develop との差分
- `/review-router main --agy --lms` → main との差分に agy CLI とローカル LLM のレビューを加える

## 1. 差分の分析

`bash ${CLAUDE_SKILL_DIR}/analyze.sh "$ARGUMENTS"` を実行し、出力 JSON を取得する。ワード分割・glob を防ぐため、`$ARGUMENTS` は必ずダブルクォートで囲む。

- ベースブランチが見つからない、未知のオプションが渡された等で非ゼロ終了した場合は、エラー内容を報告して終了する
- 差分が空（files_changed が 0）の場合は、レビュー対象が無い旨を報告して終了する

JSON の構造。

```json
{
  "base": "main",
  "files_changed": 12,
  "insertions": 340,
  "deletions": 50,
  "languages": ["py", "ts"],
  "dimensions": {
    "tests": true,
    "types": false,
    "error_handling": true,
    "comments_docs": false,
    "migrations": false,
    "security": false,
    "concurrency": false
  },
  "tier": "medium",
  "options": {
    "agy": false,
    "lms": false
  }
}
```

## 2. ルーティングの決定

`tier` と `dimensions` から実行するレビューを決める。

| tier | 自動実行 | 提案のみ |
| --- | --- | --- |
| low | code-reviewer のみ | なし |
| medium | code-reviewer ＋ true の観点に対応するサブエージェント（並行） | なし |
| high | code-reviewer ＋ true の観点に対応するサブエージェント全部（並行） | codex / `/code-review ultra` / `--agy` `--lms`（未指定時） |

agy CLI とローカル LLM は tier に関係なく、`options.agy` / `options.lms` が true のときだけ並行起動する。

観点 → pr-review-toolkit サブエージェント対応。

- 常時: `pr-review-toolkit:code-reviewer`
- `tests`: `pr-review-toolkit:pr-test-analyzer`
- `types`: `pr-review-toolkit:type-design-analyzer`
- `error_handling`: `pr-review-toolkit:silent-failure-hunter`
- `comments_docs`: `pr-review-toolkit:comment-analyzer`

`migrations` / `security` / `concurrency` には専用サブエージェントが無い。これらは tier 判定（true なら high）に効くが、専門レビューは常時起動の `code-reviewer` が一般観点としてカバーする。専用エージェントが必要になったらこの表に追加する。

判定結果（tier・起動するレビュー一覧、agy CLI・ローカル LLM を使うか）を実行前にユーザーへ一行で示す。

## 3. レビューの実行

### pr-review-toolkit サブエージェント

選んだサブエージェントを `Task` ツールで並行起動する（1 メッセージに複数 tool 呼び出し）。各エージェントへの指示。

- レビュー対象は base（JSON の `base`）との差分のみ。`git diff <base>...HEAD` の範囲に限定する
- confidence 80 以上の指摘だけ報告する
- 各指摘に file:line と確信度を含める

該当プラグインが利用不可でサブエージェント type が存在しない場合は、その観点を飛ばして報告する。

### agy CLI（`options.agy` が true のときのみ）

Antigravity CLI (agy) で Claude / Codex と系統の異なる Gemini による独立レビューを並行実行する（バックグラウンド起動可）。

```bash
bash ${CLAUDE_SKILL_DIR}/agy-review.sh "<base>" "$(cat <<'REVIEW_TEXT'
<変更概要>
REVIEW_TEXT
)"
```

- ラッパーが `git diff <base>...HEAD` を埋め込むため、レビューするのはコミット済みの変更だけで、未コミットの作業ツリーは巻き込まない
- `<base>` は JSON の `base` をそのまま渡す。`origin/main` 等の remote-tracking ref に解決されている場合も書き換えない
- `<変更概要>` は差分から読み取った変更の目的・背景の 1〜2 文（省略可）。レビュー精度が上がるため原則渡す
- `<変更概要>` は本文を展開しない quoted heredoc（`<<'REVIEW_TEXT'`）で渡す。ダブルクォートに直接埋め込むと、識別子を囲むバッククォートや `$(...)` をシェルがコマンドとして実行してしまうため
- `--sandbox` はターミナルしか制限せず、agy が検証用ファイルを書き込むことがあるため、agy は使い捨ての detached worktree 内で動かす。それでも呼び出し元の作業ツリーや HEAD が変わった場合、ラッパーは終了コード 3 で終わる。レビュー結果は使ってよいが、`git status` を確認し、ユーザー自身の並行編集ではない、agy による意図しない変更があればユーザーに報告する
- `agy` CLI が無い・未サインイン、diff が上限超過、または 3 以外の非ゼロで終了した場合は飛ばし、その旨を報告する。失敗はフロー全体を止めない。導入は mise の `aqua:google-antigravity/antigravity-cli`

### ローカル LLM（`options.lms` が true のときのみ）

Mac mini 上の LM Studio（Qwen3.6-35B-A3B）で独立レビューを並行実行する。

必ず `run_in_background=true` で起動する。モデルの読み込みや思考（`LMS_REVIEW_THINKING=true`）で長引くことがあり、ラッパーのタイムアウト（既定 900 秒）が Bash ツールの上限 600 秒を超えるため、フォアグラウンドでは打ち切られる。

```bash
bash ${CLAUDE_SKILL_DIR}/../lms-review/lms-review.sh "<base>" "$(cat <<'REVIEW_TEXT'
<変更概要>
REVIEW_TEXT
)"
```

- 引数と出力の扱いは agy CLI と同じ。単独の指摘は裏取りできるまで Suggestion に留める
- モデルは diff しか見ずリポジトリを読めないため、推測に基づく指摘は「低確信」として扱う
- ラッパーは `lms-review` skill に同梱されており、兄弟ディレクトリとして相対パスで参照するため、`lms-review` は `review-router` と同じ scope にインストールする。`lms-review` skill が入っておらず script が無い場合は飛ばす。接続先・認証の環境変数は `lms-review` の SKILL.md を参照
- サーバーに接続できない、diff が上限超過、タイムアウトなど非ゼロで終了した場合は飛ばし、その旨を報告する

## 4. 結果の集約

agy CLI・ローカル LLM をバックグラウンドで起動した場合は、完了通知が届くまで集約しない。先に終わったサブエージェントの結果だけで結論を出さない。

全レビューの指摘をまとめ、重複を排除して以下に正規化する。

- Must-Fix - マージ前に必ず直す（バグ・セキュリティ・データ損失）
- Important - 直すべき（重要だが非ブロッカー）
- Suggestion - 任意（軽微・スタイル）

報告の方針。

- カテゴリごとにグループ化し、各指摘に file:line を付ける
- agy CLI・ローカル LLM 単独の指摘（他レビュアーと重複しない指摘）は、コードを読んで裏取りできるまで Suggestion に留め、実行ごとのブレ・誤検出を出口で吸収する
- Must-Fix・Important が無い場合はその旨を明記する
- Must-Fix と Important はどちらも 6 章の修正ループで直す対象。Suggestion は報告のみで直さない

## 5. 追加レビューの提案（high tier のみ）

high tier では、自動実行に加えて以下を「必要なら手動で走らせるべき」と提案するが、自動実行はしない。いずれもコミット済みの差分を見るため、6 章で修正した場合は「修正をコミットしてから」実行するよう添える。

- `/codex:review <base>` - Codex による独立レビュー
- `/code-review ultra` - クラウドの深掘りマルチエージェントレビュー
- `/review-router <base> --agy --lms` - 系統の異なるモデルの視点を加える（今回指定していない場合のみ）

## 6. 修正と再レビュー

Must-Fix と Important が 0 件になるまで、ユーザーの承認を待たずに修正と再レビューを繰り返す。

開始前に `git status --porcelain --untracked-files=no` を確認する。追跡中のファイルに未コミットの変更が既にある場合は、修正がユーザーの変更と混ざって区別できなくなるため、ループに入らず指摘一覧を示して進め方を確認する。

### 1 ラウンドの手順

1. Must-Fix と Important を修正する。修正は指摘箇所のみ最小限に留め、Suggestion と、停止条件に挙げた設計判断を要する指摘には手を付けない
2. 修正はコミットしない。コミットするかどうかはユーザーが決める。新規ファイルを作った場合は `git add -N <file>` で diff に載せる
3. 1 回目と同じ pr-review-toolkit サブエージェントで再レビューする。範囲は `git diff $(git merge-base <base> HEAD)` とし、コミット済みの変更に未コミットの修正を加えた全体を見せる。前ラウンドまでの指摘一覧を状態付きで渡し、次のように指示する
   - 修正済みの指摘は、出どころ（agy CLI・ローカル LLM を含む）に関係なく、修正が正しいかを確認し、直っていなければ改めて報告する
   - 設計判断のため残した指摘と、Suggestion に留めた指摘は繰り返さない
4. 4 章と同じ基準で集約し、Must-Fix・Important の件数を確認する

agy CLI とローカル LLM はコミット済みの差分しか見ないため、再レビューでは起動しない。

### 停止条件

次のいずれかでループを止める。

- Must-Fix と Important が 0 件になった（正常終了）
- 3 ラウンド修正した。3 回目以降は収束しにくく、同じ箇所を行き来しやすいため
- 修正を試みた指摘と同じもの（同じファイル・同じ内容）が修正後も残った。直し方が合っていない可能性が高い。設計判断のため残した指摘はこの判定に含めない
- 残りが設計判断を要する指摘だけになった。修正方針が複数考えられるもの、仕様や公開インターフェースの変更を伴うもの、指摘同士が矛盾するものが該当し、これらは自動修正せずに残す

### 終了時の報告

- 停止理由と、残った指摘（あれば理由付き）
- ラウンドごとの修正内容（file:line と一言）
- `git diff --stat` の結果と、修正が未コミットである旨。`git add -N` したファイルがあれば、コミットしない場合も intent-to-add のままインデックスに残る旨を添える
