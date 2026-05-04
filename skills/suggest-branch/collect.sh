#!/usr/bin/env bash
# Collect branch context data for branch name suggestion
set -euo pipefail

BASE_BRANCH="${1:-main}"

# --- Data collection ---

CURRENT_BRANCH=$(git branch --show-current)
# Only staged changes; unstaged/untracked files are noise for branch naming
STATUS=$(git diff --cached --name-status)

# Resolve base branch: try local ref, then remote tracking ref (origin/<base>)
RESOLVED_BASE=""
if git rev-parse --verify "$BASE_BRANCH" &>/dev/null; then
    RESOLVED_BASE="$BASE_BRANCH"
elif git rev-parse --verify "origin/$BASE_BRANCH" &>/dev/null; then
    RESOLVED_BASE="origin/$BASE_BRANCH"
fi

if [[ -z "$RESOLVED_BASE" ]]; then
    echo "Error: base branch '$BASE_BRANCH' not found locally or as 'origin/$BASE_BRANCH'." >&2
    exit 1
fi

COMMIT_LOG=$(git log "${RESOLVED_BASE}..HEAD" --oneline 2>/dev/null || true)

REMOTE_BRANCHES=$(git branch -r --format='%(refname:short)' 2>/dev/null | head -30 || true)

# --- Output JSON ---

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Use printf '%s' to avoid implicit trailing newline on empty values
printf '%s' "$CURRENT_BRANCH" > "$WORK_DIR/current_branch"
printf '%s' "$STATUS" > "$WORK_DIR/status"
printf '%s' "$COMMIT_LOG" > "$WORK_DIR/commit_log"
printf '%s' "$REMOTE_BRANCHES" > "$WORK_DIR/remote_branches"

jq -n \
    --arg base_branch "$BASE_BRANCH" \
    --rawfile current_branch "$WORK_DIR/current_branch" \
    --rawfile status "$WORK_DIR/status" \
    --rawfile commit_log "$WORK_DIR/commit_log" \
    --rawfile remote_branches "$WORK_DIR/remote_branches" \
    '{
        base_branch: $base_branch,
        current_branch: $current_branch,
        status: $status,
        commit_log: $commit_log,
        remote_branches: $remote_branches
    }'
