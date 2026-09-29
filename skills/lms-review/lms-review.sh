#!/usr/bin/env bash
# Run an independent review of the diff against a base branch via a local LLM
# served by LM Studio (OpenAI-compatible API). Prints the review text on stdout.
#
# Unlike agy-review.sh, the model only sees the diff, with no repo access and no
# tools, so no worktree isolation is needed.
set -euo pipefail

# Connection settings shared with other LM Studio clients. LM_API_URL is the
# server root; the OpenAI-compatible /v1 is appended here. LM_API_TOKEN is the
# token itself; LM_API_TOKEN_COMMAND is an alternative that prints the token,
# so the secret store stays the caller's choice and is only queried when a
# review actually starts.
API_URL="${LM_API_URL:-http://localhost:1234}"
BASE_URL="${API_URL%/}/v1"
TOKEN="${LM_API_TOKEN:-}"

# Tunables. Override via environment when needed.
MODEL="${LMS_REVIEW_MODEL:-qwen/qwen3.6-35b-a3b}"       # MoE is ~6x faster than dense 27B; check keys with `lms ls`
TIMEOUT_SEC="${LMS_REVIEW_TIMEOUT:-900}"                # reasoning can run 10K+ tokens; be generous
TTL_SEC="${LMS_REVIEW_TTL:-600}"                        # unload 10 min after the last request (JIT only)
MAX_DIFF_BYTES="${LMS_REVIEW_MAX_DIFF_BYTES:-60000}"    # keep prompt + output within a 32K context
# Reasoning length varies from 2K to 44K+ tokens on the same model, and it can
# loop re-checking settled points until the timeout. It is therefore opt-in and
# capped by MAX_TOKENS so a runaway run errors out quickly instead.
THINKING="${LMS_REVIEW_THINKING:-false}"
MAX_TOKENS="${LMS_REVIEW_MAX_TOKENS:-16384}"

BASE_BRANCH="${1:?usage: lms-review.sh <base> [context]}"
CONTEXT="${2:-}"

case "${THINKING}" in
    true | false) ;;
    *) echo "ERROR: LMS_REVIEW_THINKING must be true or false" >&2; exit 1 ;;
esac
case "${MAX_TOKENS}" in
    '' | *[!0-9]* | 0*) echo "ERROR: LMS_REVIEW_MAX_TOKENS must be a positive integer" >&2; exit 1 ;;
esac

for cmd in curl jq perl; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "ERROR: ${cmd} not found" >&2
        exit 1
    fi
done

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: not inside a git work tree" >&2
    exit 1
fi

# Give up quickly when the Mac mini is asleep, LM Studio is not running, or
# Tailscale is down, so the caller can move on instead of waiting. Any HTTP
# status counts as reachable; probing before resolving the token avoids a
# pointless secret-store unlock prompt when the server is down.
HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "${BASE_URL}/models" 2>/dev/null || true)"
if [ -z "${HTTP_CODE}" ] || [ "${HTTP_CODE}" = "000" ]; then
    echo "ERROR: LM Studio server not reachable at ${BASE_URL}" >&2
    exit 1
fi

if [ -z "${TOKEN}" ] && [ -n "${LM_API_TOKEN_COMMAND:-}" ]; then
    TOKEN="$(bash -c "${LM_API_TOKEN_COMMAND}")" || {
        echo "ERROR: LM_API_TOKEN_COMMAND failed" >&2
        exit 1
    }
fi

# The token and the diff are handed to curl/jq through files and stdin rather
# than argv, where any local process could read them via `ps` for the whole
# request, which can last up to TIMEOUT_SEC. mktemp -d creates the directory
# as 0700.
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
HEADER_FILE="${WORK_DIR}/headers"
PAYLOAD_FILE="${WORK_DIR}/payload.json"

printf 'Content-Type: application/json\n' >"${HEADER_FILE}"
if [ -n "${TOKEN}" ]; then
    printf 'Authorization: Bearer %s\n' "${TOKEN}" >>"${HEADER_FILE}"
fi

# LM Studio answers an unknown model key with whatever model is loaded instead
# of failing, so a typo would return another model's review as a success.
# Reject keys the server does not list.
MODELS_JSON="$(curl -sS --fail-with-body --max-time 10 -H @"${HEADER_FILE}" "${BASE_URL}/models")" || {
    echo "ERROR: failed to list models at ${BASE_URL}/models" >&2
    printf '%s\n' "${MODELS_JSON:-}" | head -n 20 >&2
    exit 1
}
if ! printf '%s' "${MODELS_JSON}" | jq -e --arg m "${MODEL}" 'any(.data[]?; .id == $m)' >/dev/null 2>&1; then
    AVAILABLE="$(printf '%s' "${MODELS_JSON}" | jq -r '[.data[]?.id] | join(", ")' 2>/dev/null || true)"
    echo "ERROR: model '${MODEL}' not found on LM Studio (available: ${AVAILABLE:-none})" >&2
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

# A missing merge base, as in a shallow clone or unrelated histories, makes
# git diff fail; surface it as an ERROR: line like every other failure path.
DIFF="$(git diff "${RESOLVED_BASE}...HEAD")" || {
    echo "ERROR: git diff against '${RESOLVED_BASE}' failed (no merge base?)" >&2
    exit 1
}
if [ -z "${DIFF}" ]; then
    echo "ERROR: no committed diff against '${RESOLVED_BASE}'" >&2
    exit 1
fi
# ${#DIFF} counts characters under a UTF-8 locale, which undercounts diffs
# heavy in multibyte text such as Japanese docs by up to 3x; count raw bytes
# instead.
DIFF_BYTES="$(printf '%s' "${DIFF}" | LC_ALL=C wc -c | tr -d ' ')"
if [ "${DIFF_BYTES}" -gt "${MAX_DIFF_BYTES}" ]; then
    echo "ERROR: diff is ${DIFF_BYTES} bytes (> ${MAX_DIFF_BYTES}); too large for the local model's context" >&2
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
あなたが見られるのはこの diff だけです。diff に現れない関数やファイルの実装は推測せず、
推測に依存する指摘には必ず「低確信」と明記してください。

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

# LM Studio only honors reasoning_effort "none" (low/medium/high all think the
# same); chat_template_kwargs.enable_thinking is ignored.
printf '%s' "${PROMPT}" | jq -Rs \
    --arg model "${MODEL}" \
    --argjson ttl "${TTL_SEC}" \
    --argjson thinking "${THINKING}" \
    --argjson max_tokens "${MAX_TOKENS}" \
    '{model: $model, ttl: $ttl, temperature: 0.2, stream: false, max_tokens: $max_tokens,
      messages: [{role: "user", content: .}]}
     + (if $thinking then {} else {reasoning_effort: "none"} end)' >"${PAYLOAD_FILE}"

# --fail-with-body keeps LM Studio's error JSON (wrong model key, context
# overflow, ...) so the cause is visible instead of a bare curl exit code.
RESPONSE="$(curl -sS --fail-with-body --max-time "${TIMEOUT_SEC}" \
    -H @"${HEADER_FILE}" \
    --data-binary @"${PAYLOAD_FILE}" \
    "${BASE_URL}/chat/completions")" || {
    echo "ERROR: request to ${BASE_URL}/chat/completions failed or timed out (${TIMEOUT_SEC}s)" >&2
    if [ -n "${RESPONSE:-}" ]; then
        printf '%s\n' "${RESPONSE}" >&2
    fi
    exit 1
}

# A proxy in front of LM Studio may answer 200 with HTML; report it instead of
# letting jq die with a bare parse error under `set -e`.
if ! printf '%s' "${RESPONSE}" | jq -e '.choices[0].message' >/dev/null 2>&1; then
    echo "ERROR: unexpected response from ${BASE_URL}/chat/completions" >&2
    printf '%s\n' "${RESPONSE}" | head -n 20 >&2
    exit 1
fi

# A review cut off at the token limit (or a reasoning dump that never reached
# the answer) would otherwise pass as a complete result, since callers relay
# stdout verbatim.
FINISH_REASON="$(printf '%s' "${RESPONSE}" | jq -r '.choices[0].finish_reason // empty')"
if [ "${FINISH_REASON}" = "length" ]; then
    echo "ERROR: model output was truncated at the token limit (finish_reason: length, max ${MAX_TOKENS}); raise LMS_REVIEW_MAX_TOKENS or retry with a smaller diff; if LMS_REVIEW_THINKING=true, the reasoning likely looped, so retry without it" >&2
    exit 1
fi

CONTENT="$(printf '%s' "${RESPONSE}" | jq -r '.choices[0].message.content // empty')"

# LM Studio normally splits the reasoning into reasoning_content. Strip an
# inline <think> block only when the content opens with one: a bare leading
# </think> cannot be told apart from a review that quotes the tag, and
# stripping on it would silently drop the findings before the quote.
CONTENT="$(printf '%s' "${CONTENT}" | perl -0pe 's/\A\s*<think>.*?<\/think>\s*//s')"

if [ -z "${CONTENT}" ]; then
    echo "ERROR: empty response from model '${MODEL}'" >&2
    exit 1
fi

printf '%s\n' "${CONTENT}"
