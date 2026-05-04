---
name: suggest-branch
description: 作業内容を分析して適切なブランチ名を提案 (user)
license: MIT
argument-hint: "[base-branch]"
allowed-tools: Bash(bash *)
---

# ブランチ名提案

作業内容を分析し、`feature/` または `fix/` プレフィックス付きのブランチ名を提案する。

## 入力

`$ARGUMENTS` にベースブランチ名が渡される（省略時は `main`）。

## 手順

### 1. データ取得

プロンプトに `<git-data>` タグでデータが提供されている場合はそれを使用する。
提供されていない場合は `bash ${CLAUDE_SKILL_DIR}/collect.sh $ARGUMENTS` を実行してデータを取得する（引数にベースブランチを渡す。省略時は main）。

### 2. データの読み取り

JSON データの各フィールドを確認する。

- `base_branch` - ベースブランチ名
- `current_branch` - 現在のブランチ名
- `status` - ステージ済みの変更（git diff --cached --name-status）
- `commit_log` - ベースブランチからのコミットログ
- `remote_branches` - 既存リモートブランチ名（命名慣例の参考用）

### 3. ブランチ名候補の生成

#### 差分がある場合

変更内容を分析し、2-4個のブランチ名候補を生成する。

現在のブランチがベースブランチ以外（既にフィーチャーブランチ上）の場合は、現在のブランチ名が変更内容を適切に表しているかも評価する。適切な場合は候補の1つとして含める。

#### 差分がない場合

`commit_log` と `status` がともに空の場合、「差分が見つかりません。作業内容を引数で指定してください。」と出力して終了する。

#### 命名ルール

- プレフィックス
  - 新機能、機能追加、改善 → `feature/`
  - バグ修正 → `fix/`
- 本体部分
  - kebab-case（ハイフン区切り）
  - 英語
  - 簡潔（2-4語程度）
  - 内容が直感的に分かる名前
- 既存ブランチの慣例を参考にする（`remote_branches` フィールド参照）

### 4. JSON出力

候補を以下のJSON形式で出力する。JSON以外のテキスト（説明文など）は一切出力しない。

- `candidates` - 候補の配列
  - `name` - ブランチ名
  - `description` - 候補の意図・理由（日本語）

```json
{
  "candidates": [
    {"name": "feature/add-user-auth", "description": "ユーザー認証機能の追加"},
    {"name": "feature/auth-middleware", "description": "認証ミドルウェアの実装"}
  ]
}
```
