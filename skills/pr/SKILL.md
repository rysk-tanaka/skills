---
name: pr
description: ブランチの変更を分析してプルリクエストを作成 (user)
license: MIT
argument-hint: "[base-branch]"
allowed-tools: Bash(bash *)
---

# プルリクエスト作成

ブランチの変更を分析し、PRテンプレートに従ったプルリクエストを作成する。

## 入力

`$ARGUMENTS` にベースブランチ名が渡される（省略時は `main`）。

## 手順

### 1. ヘルパースクリプトの実行

`bash ${CLAUDE_SKILL_DIR}/collect.sh <base-branch>` を実行する。

- ベースブランチは `$ARGUMENTS` が指定されていればそれを使用、なければ `main` を渡す
- スクリプトが非ゼロ終了した場合は、stderr のエラーメッセージをユーザーに報告して終了

### 2. 出力の解析

スクリプトの stdout は JSON 形式で以下のフィールドを含む。

- `current_branch` - 現在のブランチ名
- `base_branch` - ベースブランチ名
- `stat` - 変更ファイルの統計（git diff --stat）
- `log` - コミット一覧（git log --oneline）
- `diff` - 詳細な差分（lockファイル除外済み）
- `template` - PRテンプレートの内容（見つからない場合は空文字列）

diff が非常に大きい場合は、stat を中心に分析する。

テンプレートは `.github/pull_request_template.md` → `${HOME}/.claude/skills/pr/pull_request_template.md` の順で collect.sh が取得する。
後者は git 管理外のローカル運用のため、リポジトリ内検索や GitHub API では見つからない。
テンプレートの有無は collect.sh の出力のみで判断し、別リポジトリが対象でもそのリポジトリの cwd で collect.sh を実行する。

### 3. PR内容の生成

#### タイトル

- template にタイトルの指示があればそれに従う
- template が空の場合はシンプルな英文（先頭大文字、末尾ピリオドなし）
- ブランチ全体で何を達成したかを簡潔に表現

#### 本文

- template が空でなければ、テンプレートの形式と言語に従って記述
- template が空の場合は、デフォルト構成（変更の概要、主な変更点、変更の背景）で日本語で記述
  - 文末はですます調
  - 句点（。）で改行する
- 1文を短く保ち、1行がおおむね120文字を超えないように作文する（読み手の負荷を下げるため、まず文自体を短くする）
- それでも長くなる場合のみ、意味の切れ目など可読性を考慮した位置で改行する
  - 箇条書きの中で改行する場合は、継続行を項目本文の位置までインデントして箇条書きの構造を崩さない
  - インデントを揃えられず構造が崩れるくらいなら、折り返さずに1行のままにする
- 本文末尾に余分な空行を付けない
- レビュアーが読みやすいよう、簡潔で要点のみを記載
- 冗長な説明や詳細すぎる技術的説明は避ける
- テンプレートの各項目を埋めるために必要な最小限の情報のみを記載
- 個別のコミット内容ではなく、ブランチ全体で何を変更したかに焦点を当てる
- テンプレートのHTMLコメント（`<!-- -->`）は出力に含めない
- 該当する内容がないセクションは省略する（「なし」と記載しない）

#### 禁止事項

- PR本文に `🤖 Generated with [Claude Code](https://claude.com/claude-code)` を含めない
- PR本文に `Co-Authored-By: Claude <noreply@anthropic.com>` を含めない

### 4. ユーザー確認

生成したPRタイトルと本文を以下の形式でユーザーに提示する。

```text
Title: <タイトル>
Base: <ベースブランチ> ← <現在のブランチ>

<PR本文>
```

AskUserQuestion ツールでPR内容の確認と `claude-review` ラベルの付与を同時に尋ねる。

- question: `この内容でPRを作成しますか？修正があればコメントしてください。`
- header: `PR作成`
- multiSelect: false
- 選択肢
  - `作成する` - ラベルなしでPRを作成
  - `claude-review 付きで作成` - `claude-review` ラベルを付けてPRを作成
- 修正が要望された場合は、フィードバックを反映して再度確認する

### 5. PR作成

ユーザーの承認を得た後、`gh pr create` コマンドを実行する。

```bash
# ラベルなし
gh pr create --base <base-branch> --title "<タイトル>" --body "<本文>"

# claude-review ラベル付き
gh pr create --base <base-branch> --title "<タイトル>" --body "<本文>" --label claude-review
```

### 5a. ラベル未作成時のフォールバック

`--label claude-review` 付きで `gh pr create` を実行した際に `'claude-review' not found` エラーが発生した場合、
ユーザーに `mise run setup-review-label` の実行を促し、完了後にPR作成を再試行する。

### 6. 結果の報告

作成されたPRのURLを表示する。

### 7. 次のアクションのサジェスト

PR作成後、PRのURLからPR番号を抽出し、AskUserQuestion ツールで次のアクションを提示する。

- header: `次のアクション`
- question: `PR #<PR番号> を作成しました。次に行うアクションを選択してください。`
- multiSelect: false
- 選択肢
  - `/await-ci <PR番号> --watch` - CI の完了を待機
  - `/resolve-review <PR番号>` - レビュー指摘を確認・対応
  - `/review <PR番号>` - コードレビューを実行
  - `/pr-review-toolkit:review-pr` - PR の包括的レビューを実行
  - `何もしない` - 終了

ユーザーがスキルを選択した場合は、対応する Skill ツールまたは SlashCommand ツールで実行する。

## 既存PR本文の編集

作成済みのPR本文に追記・修正する場合は、ユーザー自身が本文を手直ししている可能性があるため以下の手順に従う。

1. GraphQL の `userContentEdits` で本文の編集履歴を取得する
2. ユーザーによる編集後の形式（改行位置、箇条書きの体裁、末尾の空行有無）を確認する
3. その形式を維持したまま、差分が最小になるよう必要な箇所だけを更新する
