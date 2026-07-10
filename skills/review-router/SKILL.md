---
name: review-router
description: 差分を分析して規模・観点に応じたレビューを自動振り分け (user)
license: MIT
argument-hint: "[base-branch]"
allowed-tools: Bash(bash *) BashOutput Task
---

# レビュー・ルーター

ベースブランチとの差分を分析し、規模・触れた観点・リスクから tier を判定して、適切なレビューだけを自動起動する。「ローカルか PR か」は人が決め、深さと観点の選択はこのスキルに任せるのが狙い。

## 入力

`$ARGUMENTS` にベースブランチが渡される（省略可、デフォルト main）。

例

- `/review-router` → main との差分
- `/review-router develop` → develop との差分

## 1. 差分の分析

`bash ${CLAUDE_SKILL_DIR}/analyze.sh "$ARGUMENTS"` を実行し、出力 JSON を取得する（`$ARGUMENTS` は必ずダブルクォートで囲み、ワード分割・glob を防ぐ）。

- ベースブランチが見つからない等で非ゼロ終了した場合は、エラー内容を報告して終了する
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
  "tier": "medium"
}
```

## 2. ルーティングの決定

`tier` と `dimensions` から実行するレビューを決める。

| tier | 自動実行 | 提案のみ |
| --- | --- | --- |
| low | code-reviewer のみ | なし |
| medium | code-reviewer ＋ true の観点に対応するサブエージェント ＋ agy CLI（並行） | なし |
| high | code-reviewer ＋ true の観点に対応するサブエージェント全部 ＋ agy CLI（並行） | codex / `/code-review ultra` |

観点 → pr-review-toolkit サブエージェント対応。

- 常時: `pr-review-toolkit:code-reviewer`
- `tests`: `pr-review-toolkit:pr-test-analyzer`
- `types`: `pr-review-toolkit:type-design-analyzer`
- `error_handling`: `pr-review-toolkit:silent-failure-hunter`
- `comments_docs`: `pr-review-toolkit:comment-analyzer`

`migrations` / `security` / `concurrency` には専用サブエージェントが無い。これらは tier 判定（true なら high）に効くが、専門レビューは常時起動の `code-reviewer` が一般観点としてカバーする。high tier では並行する agy CLI もこれらを拾う。専用エージェントが必要になったらこの表に追加する。

判定結果（tier・起動するレビュー一覧）を実行前にユーザーへ一行で示す。

## 3. レビューの実行

### pr-review-toolkit サブエージェント

選んだサブエージェントを `Task` ツールで並行起動する（1 メッセージに複数 tool 呼び出し）。各エージェントへの指示。

- レビュー対象は base（JSON の `base`）との差分のみ。`git diff <base>...HEAD` の範囲に限定する
- confidence 80 以上の指摘だけ報告する
- 各指摘に file:line と確信度を含める

該当プラグインが利用不可（サブエージェント type が存在しない）の場合は、その観点を skip し報告する。

### agy CLI（medium tier 以上）

Antigravity CLI (agy) で Claude / Codex と系統の異なる Gemini による独立レビューを並行実行する（バックグラウンド起動可）。

```bash
bash ${CLAUDE_SKILL_DIR}/agy-review.sh "<base>" "<変更概要>"
```

- コミット済みの変更のみレビューする（ラッパーが `git diff <base>...HEAD` を埋め込むため、未コミットの作業ツリーは巻き込まない）
- `<base>` は JSON の `base` を使う（`origin/main` 等の remote-tracking ref に解決されている場合もそのまま渡す）
- `<変更概要>` は差分から読み取った変更の目的・背景の 1〜2 文（省略可）。レビュー精度が上がるため原則渡す
- `agy` CLI が無い・未サインイン、diff が上限超過、または非ゼロ終了した場合は skip し、その旨を報告する。失敗はフロー全体を止めない（導入は mise の `aqua:google-antigravity/antigravity-cli`）

## 4. 結果の集約

全レビューの指摘をまとめ、重複を排除して以下に正規化する。

- Must-Fix - マージ前に必ず直す（バグ・セキュリティ・データ損失）
- Important - 直すべき（重要だが非ブロッカー）
- Suggestion - 任意（軽微・スタイル）

報告の方針。

- カテゴリごとにグループ化し、各指摘に file:line を付ける
- agy CLI 単独の指摘（他レビュアーと重複しない指摘）は、コードを読んで裏取りできるまで Suggestion に留める（実行ごとのブレ・誤検出を出口で吸収する）
- Must-Fix が無い場合はその旨を明記する
- 停止条件を明示する。反復は「Must-Fix がゼロ」になったら打ち切る（指摘ゼロまで回さない）

## 5. 追加レビューの提案（high tier のみ）

high tier では、自動実行に加えて以下を「必要なら手動で走らせるべき」と提案する（自動実行しない）。

- `/codex:review <base>` - Codex による独立レビュー
- `/code-review ultra` - クラウドの深掘りマルチエージェントレビュー

## 6. 修正と再レビュー

Must-Fix と Important について修正方針を提示する。

- ユーザーの承認を得てから修正する
- 修正は指摘箇所のみ最小限に留める
- 修正後は `/review-router <base>` での再レビューを提案する
