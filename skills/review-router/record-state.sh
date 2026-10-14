#!/usr/bin/env bash
# Keep per-branch reviewer outcomes so later review-router runs can skip reviewers that
# produced nothing useful last time.
#
# Usage:
#   record-state.sh --path           print the state file for the current branch (nothing on detached HEAD)
#   record-state.sh <base> <result   merge a Workflow result ({"stats": {...}, "skipped": [...]}) into it
#
# The file lives under the git common dir, so it is never committed and is shared by worktrees.
set -euo pipefail

state_path() {
    local branch common_dir
    # Detached HEAD has no branch to key the history on, so print nothing.
    branch=$(git symbolic-ref --quiet --short HEAD) || return 0
    common_dir=$(git rev-parse --path-format=absolute --git-common-dir)
    printf '%s/review-router/%s.json\n' "${common_dir}" "${branch//\//__}"
}

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: not inside a git work tree" >&2
    exit 1
fi

if [ "${1:-}" = "--path" ]; then
    state_path
    exit 0
fi

BASE="${1:?usage: record-state.sh --path | record-state.sh <base> <workflow-result.json}"

STATE_FILE=$(state_path)
if [ -z "${STATE_FILE}" ]; then
    echo "WARN: detached HEAD; review history not recorded" >&2
    exit 0
fi

RESULT=$(cat)
if ! jq -e '(.stats | type == "object") and ((.skipped // []) | type == "array")' <<<"${RESULT}" >/dev/null 2>&1; then
    echo "ERROR: stdin must be a JSON object with \"stats\" (object) and \"skipped\" (array)" >&2
    exit 1
fi

mkdir -p "$(dirname "${STATE_FILE}")"

PREVIOUS='{}'
if [ -f "${STATE_FILE}" ]; then
    if ! PREVIOUS=$(jq -c 'if type == "object" then . else error("not an object") end' "${STATE_FILE}" 2>/dev/null); then
        # A corrupt history must not block recording forever; start over and say so.
        echo "WARN: replacing unreadable review history ${STATE_FILE}" >&2
        PREVIOUS='{}'
    fi
fi

TMP_FILE=$(mktemp "${STATE_FILE}.XXXXXX")
trap 'rm -f "${TMP_FILE}"' EXIT

# Reviewers missing from stats (skipped ones) keep their old entry, so a transient failure
# does not erase what they found before. A changed base starts a fresh history.
jq -n \
    --argjson prev "${PREVIOUS}" \
    --argjson result "${RESULT}" \
    --arg base "${BASE}" \
    --arg branch "$(git symbolic-ref --short HEAD)" \
    --arg head "$(git rev-parse HEAD)" \
    '($prev | if .base == $base then . else {} end) as $p
    | ($p.reviewers // {}) as $known
    | {
        branch: $branch,
        base: $base,
        runs: (($p.runs // 0) + 1),
        last_head: $head,
        reviewers: ($known + ($result.stats | with_entries(.value = {
            runs: (($known[.key].runs // 0) + 1),
            last_adopted: (.value.adopted // 0)
        })))
    }' >"${TMP_FILE}"

mv "${TMP_FILE}" "${STATE_FILE}"
cat "${STATE_FILE}"
