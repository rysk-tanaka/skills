#!/usr/bin/env bash
# Delegate an investigation or fix to a local LLM served by LM Studio, using
# Codex CLI as the agent harness. Prints the agent's final message on stdout.
#
# usage: lms-rescue.sh [--write] [--resume] [--model <key>] <task...>
#   --write   allow edits inside the working tree (workspace-write sandbox);
#             read-only otherwise
#   --resume  continue the most recent lms-rescue session for this directory
set -euo pipefail

# Connection settings shared with other LM Studio clients (see lms-review.sh).
API_URL="${LM_API_URL:-http://localhost:1234}"
BASE_URL="${API_URL%/}/v1"
TOKEN="${LM_API_TOKEN:-}"

# Tunables. Override via environment when needed.
MODEL="${LMS_RESCUE_MODEL:-qwen/qwen3.6-35b-a3b}"      # MoE keeps multi-turn agent loops fast
CONTEXT_WINDOW="${LMS_RESCUE_CONTEXT_WINDOW:-}"        # match LM Studio's loaded context length
# A dedicated CODEX_HOME keeps these sessions out of the user's regular Codex
# history (so --resume never picks up a cloud Codex thread) and skips the
# user's Codex config (MCP servers, plugins) that a local model may choke on.
STATE_DIR="${LMS_RESCUE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/lms-rescue}"

WRITE=false
RESUME=false
HAS_EXPLICIT_MODEL=false
while [ $# -gt 0 ]; do
    case "$1" in
        --write) WRITE=true; shift ;;
        --resume) RESUME=true; shift ;;
        --model) MODEL="${2:?--model requires a value}"; HAS_EXPLICIT_MODEL=true; shift 2 ;;
        --) shift; break ;;
        *) break ;;
    esac
done
TASK="$*"
if [ -z "${TASK}" ]; then
    echo "usage: lms-rescue.sh [--write] [--resume] [--model <key>] <task...>" >&2
    exit 1
fi

for cmd in codex curl git jq; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "ERROR: ${cmd} not found" >&2
        exit 1
    fi
done

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: not inside a git work tree" >&2
    exit 1
fi

# Fail fast when the server is unreachable so the caller is not left waiting.
# Any HTTP status counts as reachable; probing before resolving the token
# avoids a pointless secret-store unlock prompt when the server is down.
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

# The token reaches curl through a header file, not argv, so `ps` cannot see
# it. mktemp -d creates the directory as 0700.
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
HEADER_FILE="${WORK_DIR}/headers"
printf 'Accept: application/json\n' >"${HEADER_FILE}"
if [ -n "${TOKEN}" ]; then
    printf 'Authorization: Bearer %s\n' "${TOKEN}" >>"${HEADER_FILE}"
fi

# Codex reads the key from the env var named by env_key and errors out when
# that variable is empty, so only wire it up when auth is actually in use.
PROVIDER="{name=\"LM Studio\", base_url=\"${BASE_URL}\", wire_api=\"responses\"}"
if [ -n "${TOKEN}" ]; then
    export LMS_RESCUE_API_KEY="${TOKEN}"
    PROVIDER="{name=\"LM Studio\", base_url=\"${BASE_URL}\", env_key=\"LMS_RESCUE_API_KEY\", wire_api=\"responses\"}"
fi

SANDBOX="read-only"
if [ "${WRITE}" = true ]; then
    SANDBOX="workspace-write"
fi

# Repos in this ecosystem often carry CLAUDE.md instead of AGENTS.md; let the
# agent pick up the same project conventions Claude Code follows.
CODEX_ARGS=(
    -c model_provider=lms_remote
    -c "model_providers.lms_remote=${PROVIDER}"
    -c "sandbox_mode=\"${SANDBOX}\""
    -c 'project_doc_fallback_filenames=["CLAUDE.md"]'
)
if [ -n "${CONTEXT_WINDOW}" ]; then
    CODEX_ARGS+=(-c "model_context_window=${CONTEXT_WINDOW}")
fi

mkdir -p "${STATE_DIR}/codex" "${STATE_DIR}/logs" "${STATE_DIR}/models"
export CODEX_HOME="${STATE_DIR}/codex"

# `codex exec resume` does not restore the session's model; without -m it falls
# back to Codex's own default, which LM Studio does not serve. Remember the
# model per directory (resume --last is scoped to the cwd too) so a resume
# without --model continues on the model the session started with.
MODEL_FILE="${STATE_DIR}/models/$(printf '%s' "${PWD}" | git hash-object --stdin | cut -c1-40)"
if [ "${RESUME}" = true ] && [ "${HAS_EXPLICIT_MODEL}" = false ] && [ -s "${MODEL_FILE}" ]; then
    MODEL="$(cat "${MODEL_FILE}")"
fi
# LM Studio answers an unknown model key with whatever model is loaded instead
# of failing, so a typo would run silently on the wrong model (and later break
# once that model unloads). Reject keys the server does not list.
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

# A fresh run records its model up front: the session is created with it even
# if the run later fails (e.g. context overflow). A resume switching models only
# records it on success, so a mistyped --model cannot poison later resumes.
if [ "${RESUME}" = false ]; then
    printf '%s\n' "${MODEL}" >"${MODEL_FILE}"
fi
LOG_FILE="${STATE_DIR}/logs/$(date +%Y%m%d-%H%M%S)-$$.log"

LAST_MESSAGE="${WORK_DIR}/last-message.txt"

# The progress trace goes to a log file so stdout carries only the final
# answer; stdin is closed because codex otherwise waits for piped input.
if [ "${RESUME}" = true ]; then
    CMD=(codex exec resume --last "${CODEX_ARGS[@]}" -m "${MODEL}" -o "${LAST_MESSAGE}" -- "${TASK}")
else
    CMD=(codex exec --color never "${CODEX_ARGS[@]}" -m "${MODEL}" -o "${LAST_MESSAGE}" -- "${TASK}")
fi
if ! "${CMD[@]}" </dev/null >"${LOG_FILE}" 2>&1; then
    echo "ERROR: codex exec failed (log: ${LOG_FILE})" >&2
    tail -n 20 "${LOG_FILE}" >&2
    exit 1
fi
if [ "${RESUME}" = true ] && [ "${HAS_EXPLICIT_MODEL}" = true ]; then
    printf '%s\n' "${MODEL}" >"${MODEL_FILE}"
fi

if [ ! -s "${LAST_MESSAGE}" ]; then
    echo "ERROR: no final message from model '${MODEL}' (log: ${LOG_FILE})" >&2
    exit 1
fi

# Trim the blank lines local models tend to emit before the answer.
sed '/./,$!d' "${LAST_MESSAGE}"

if [ "${WRITE}" = true ]; then
    printf '\n---\n作業ツリーの状態（実行後）:\n'
    git status --short
fi
printf '\n(log: %s)\n' "${LOG_FILE}"
