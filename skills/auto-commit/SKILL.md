---
name: auto-commit
description: ステージ済みの変更からコミットメッセージを自動生成 (user)
license: MIT
allowed-tools: Bash(bash *)
---

# コミットメッセージ自動生成

ステージ済みの変更を分析し、Conventional Commits形式のコミットメッセージを生成する。

## 手順

### 1. データ取得

プロンプトに `<git-data>` タグでデータが提供されている場合はそれを使用する。
提供されていない場合は `bash ${CLAUDE_SKILL_DIR}/collect.sh` を実行してデータを取得する。

### 2. データの読み取り

JSON データの各フィールドを確認する。

- `staged_files` - ステージ済みファイル一覧
- `log` - 直近10件のコミット履歴（スコープの命名規則の参考用）
- `stat` - 変更ファイルの統計（ファイル名と行数）
- `diff` - 詳細な差分（lockファイルと500行超えファイルは除外済み）
- `excluded_large_files` - diff から除外された大きなファイルの一覧（stat のみで判断すること）

### 3. コミットメッセージ候補の生成

以下のルールに従って、2-4個のコミットメッセージ候補を生成する。
各候補はニュアンスや着眼点を変えて、異なる表現を提示する。

#### 形式

```text
type(scope): description
```

#### type の選択基準

- `feat` - 新機能の追加
- `fix` - バグ修正
- `docs` - ドキュメントのみの変更
- `style` - コードの意味に影響しない変更（空白、フォーマット等）
- `refactor` - バグ修正でも機能追加でもないコード変更
- `perf` - パフォーマンス改善
- `test` - テストの追加・修正
- `chore` - ビルドプロセスや補助ツールの変更

#### scope の決定

- 直近のコミット履歴で使われているスコープを参考にする
- 変更が単一のコンポーネント/ディレクトリに限定される場合はそれをスコープにする
- 変更が広範囲にわたる場合はスコープを省略可

#### description のルール

- 英語で記述
- 先頭は小文字
- 末尾にピリオドを付けない
- 命令形で記述（add, update, fix 等）
- 簡潔に（50文字以内を目安）

### 4. JSON出力

候補を以下のJSON形式で出力する。JSON以外のテキスト（説明文など）は一切出力しない。

- `candidates` - 候補の配列
  - `message` - コミットメッセージ本文
  - `description` - 候補の意図・ニュアンスの違い（日本語）

```json
{
  "candidates": [
    {"message": "fix(auth): handle expired token refresh", "description": "トークン更新処理の修正に着目"},
    {"message": "fix(auth): add token expiry handling", "description": "期限切れハンドリングの追加として表現"}
  ]
}
```

メッセージに以下は絶対に含めない。

- `🤖 Generated with [Claude Code](https://claude.com/claude-code)`
- `Co-Authored-By: Claude <noreply@anthropic.com>`
