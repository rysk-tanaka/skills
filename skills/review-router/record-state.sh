#!/usr/bin/env bash
# Keep per-branch reviewer outcomes so later review-router runs can skip reviewers that
# produced nothing useful last time.
#
# Usage:
#   record-state.sh --path           print the state file for the current branch (nothing on detached HEAD)
#   record-state.sh --read           print the validated state, or null if missing or malformed
#   record-state.sh <base> <result   merge a Workflow result ({"stats": {...}, "skipped": [...]}) into it
#
# The file lives under the git common dir, so it is never committed and is shared by worktrees.
set -euo pipefail

# Print the state file for branch $1. The name is percent-encoded ('%' first, then '/') so
# distinct branches such as feat/x and feat__x never share a file.
state_path() {
    local key common_dir
    key=${1//\%/%25}
    key=${key//\//%2F}
    # --git-common-dir may be relative to the cwd; resolve it without --path-format, which
    # needs git 2.31+.
    common_dir=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
    printf '%s/review-router/%s.json\n' "${common_dir}" "${key}"
}

# Print the state in $1 if it has the shape this script writes, otherwise null (with a warning
# when the file exists). Both reading and recording go through this, so a hand-edited or
# partially written file is treated as no history instead of breaking either side.
load_state() {
    if [ ! -f "$1" ]; then
        echo null
        return
    fi
    if ! jq -c '
        if type == "object"
            and (.branch | type) == "string"
            and (.base | type) == "string"
            and ((.runs // 0) | type) == "number"
            and ((.reviewers // {}) | type) == "object"
            and ([(.reviewers // {})[]
                | type == "object"
                    and ((.last_adopted // 0) | type) == "number"
                    and ((.last_head // "") | type) == "string"] | all)
        then . else error("malformed review history") end' "$1" 2>/dev/null; then
        echo "WARN: ignoring unreadable review history $1" >&2
        echo null
    fi
}

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: not inside a git work tree" >&2
    exit 1
fi

# Detached HEAD has no branch to key the history on.
BRANCH=$(git symbolic-ref --quiet --short HEAD || true)

if [ "${1:-}" = "--path" ]; then
    if [ -n "${BRANCH}" ]; then state_path "${BRANCH}"; fi
    exit 0
fi

if [ "${1:-}" = "--read" ]; then
    if [ -n "${BRANCH}" ]; then load_state "$(state_path "${BRANCH}")"; else echo null; fi
    exit 0
fi

BASE="${1:?usage: record-state.sh --path | --read | <base> <workflow-result.json}"

if [ -z "${BRANCH}" ]; then
    echo "WARN: detached HEAD; review history not recorded" >&2
    exit 0
fi
STATE_FILE=$(state_path "${BRANCH}")

RESULT=$(cat)
if ! jq -e '
    (.stats | type == "object")
    and ([.stats[] | type == "object" and ((.adopted // 0) | type) == "number"] | all)
    and ((.skipped // []) | type == "array")' <<<"${RESULT}" >/dev/null 2>&1; then
    echo "ERROR: stdin must be a JSON object with \"stats\" ({reviewer: {\"adopted\": number}}) and \"skipped\" (array)" >&2
    exit 1
fi

mkdir -p "$(dirname "${STATE_FILE}")"

# A malformed history must not block recording forever, so it is replaced.
PREVIOUS=$(load_state "${STATE_FILE}")
if [ "${PREVIOUS}" = null ]; then PREVIOUS='{}'; fi

TMP_FILE=$(mktemp "${STATE_FILE}.XXXXXX")
trap 'rm -f "${TMP_FILE}"' EXIT

# Skipped reviewers keep their old entry even if stats lists them, so a transient failure
# does not erase what they found before. A changed base or branch starts a fresh history.
# Each reviewer's last_head lets analyze.sh bring it back when its area changes later.
jq -n \
    --argjson prev "${PREVIOUS}" \
    --argjson result "${RESULT}" \
    --arg base "${BASE}" \
    --arg branch "${BRANCH}" \
    --arg head "$(git rev-parse HEAD)" \
    '($prev | if .base == $base and .branch == $branch then . else {} end) as $p
    | ($p.reviewers // {}) as $known
    | ($result.skipped // []) as $skipped
    | {
        branch: $branch,
        base: $base,
        runs: (($p.runs // 0) + 1),
        reviewers: ($known + ($result.stats
            | with_entries(select(.key as $k | $skipped | index($k) | not))
            | with_entries(.value = {
                last_adopted: (.value.adopted // 0),
                last_head: $head
            })))
    }' >"${TMP_FILE}"

mv "${TMP_FILE}" "${STATE_FILE}"
cat "${STATE_FILE}"
