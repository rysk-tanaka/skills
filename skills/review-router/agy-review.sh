#!/usr/bin/env bash
# Run an independent third-perspective review of the diff against a base branch
# via Antigravity CLI (agy). Prints the review text on stdout.
set -euo pipefail

# Tunables. Override via environment when needed.
MODEL="${AGY_REVIEW_MODEL:-Gemini 3.1 Pro (High)}"
PRINT_TIMEOUT="${AGY_REVIEW_TIMEOUT:-10m}"
MAX_DIFF_BYTES="${AGY_REVIEW_MAX_DIFF_BYTES:-262144}"   # skip above this to keep the prompt sane

BASE_BRANCH="${1:?usage: agy-review.sh <base> [context]}"
CONTEXT="${2:-}"

if ! command -v agy >/dev/null 2>&1; then
    echo "ERROR: agy CLI not found" >&2
    exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: not inside a git work tree" >&2
    exit 1
fi

# Resolve the base to a real ref. Fall back to origin/<base> so a checkout that
# only has the remote-tracking branch still works.
RESOLVED_BASE="${BASE_BRANCH}"
if git rev-parse --verify --quiet "${RESOLVED_BASE}" >/dev/null; then
    :
elif git rev-parse --verify --quiet "origin/${BASE_BRANCH}" >/dev/null; then
    RESOLVED_BASE="origin/${BASE_BRANCH}"
else
    echo "ERROR: base ref '${BASE_BRANCH}' not found (also tried 'origin/${BASE_BRANCH}')" >&2
    exit 1
fi

DIFF="$(git diff "${RESOLVED_BASE}...HEAD")"
if [ -z "${DIFF}" ]; then
    echo "ERROR: no committed diff against '${RESOLVED_BASE}'" >&2
    exit 1
fi
if [ "${#DIFF}" -gt "${MAX_DIFF_BYTES}" ]; then
    echo "ERROR: diff is ${#DIFF} bytes (> ${MAX_DIFF_BYTES}); review it in smaller pieces" >&2
    exit 1
fi

CONTEXT_SECTION=""
if [ -n "${CONTEXT}" ]; then
    CONTEXT_SECTION="## 変更の背景

${CONTEXT}

"
fi

PROMPT="あなたはコードレビュアーです。以下の diff をレビューしてください。

${CONTEXT_SECTION}## 依頼

既存の挙動を壊すバグ、境界条件の誤り、セキュリティ上の問題、テストの検証漏れを重点的に探してください。
判断に迷ったら、リポジトリ内の該当ファイルを読んで diff の前後の実装を確認してください。
設計判断・規約は AGENTS.md（無ければ CLAUDE.md）と docs/ 配下を読んで確認し、
そこに記載された確定済みの設計判断と矛盾する指摘は出さないでください。

## 指摘に含めないもの

- 設計の代替案・リファクタ提案・スタイル改善
- diff 範囲外のコードへの変更要望
- 問題が顕在化する具体的な入力条件を示せない指摘

## 出力形式

指摘には file:line と、問題が顕在化する具体的な入力条件を付けてください。
確信度の低い指摘は「低確信」と明記してください。問題がなければ「指摘なし」と結論してください。
日本語で回答してください。

## diff

\`\`\`diff
${DIFF}
\`\`\`"

# Headless (-p) auto-denies any tool that needs a permission prompt, which
# kills the run as soon as the reviewer tries to read repo files. Skip the
# prompts, and keep --sandbox so terminal commands stay confined.
exec agy -p "${PROMPT}" --model "${MODEL}" --print-timeout "${PRINT_TIMEOUT}" \
    --sandbox --dangerously-skip-permissions
