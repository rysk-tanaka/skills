#!/usr/bin/env bash
# Run codex review and extract the review result from stderr
set -euo pipefail

BASE_BRANCH="${1:-main}"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# codex review outputs everything to stderr (stdout is empty)
if ! codex review --base "$BASE_BRANCH" >"$WORK_DIR/stdout" 2>"$WORK_DIR/stderr"; then
    cat "$WORK_DIR/stderr" >&2
    exit 1
fi

# Extract the "codex" section from role-tagged output
# Format: lines like "user", "thinking", "exec", "codex" act as section headers
RESULT=$(awk '
BEGIN { in_codex = 0 }
/^(user|thinking|exec|codex)$/ {
    in_codex = ($0 == "codex")
    next
}
in_codex { print }
' "$WORK_DIR/stderr")

# Extract session id from stderr for cache persistence
SESSION_ID=$(grep -oE 'session id: [0-9a-f-]+' "$WORK_DIR/stderr" | cut -d' ' -f3 || true)

CACHE_DIR="$HOME/.cache/claude-bg"
mkdir -p "$CACHE_DIR"
# Clean up cache files older than 7 days
find "$CACHE_DIR" -name 'codex-review-*.txt' -mtime +7 -delete 2>/dev/null || true

if [[ -z "$RESULT" ]]; then
    # Fallback: output entire stderr for best-effort analysis
    cat "$WORK_DIR/stderr"
else
    printf '%s\n' "$RESULT"
fi

# Extract usage via ccusage-codex (latest session = the one just completed)
USAGE=$(ccusage-codex session --since "$(date +%Y%m%d)" --json --noColor 2>/dev/null \
    | jq -c '.sessions[-1] // empty | {
        total_tokens: .totalTokens,
        input_tokens: .inputTokens,
        cached_tokens: .cachedInputTokens,
        output_tokens: .outputTokens,
        reasoning_tokens: .reasoningOutputTokens,
        cost_usd: .costUSD,
        model: (.models | keys[0])
    }' 2>/dev/null || true)

# Extract rate limits from latest session JSONL
# File names contain timestamps (rollout-YYYY-MM-DDT...), so reverse sort by name = newest first
# Session directories use local time, not UTC
RATE_LIMITS=$(find "$HOME/.codex/sessions/$(date +%Y/%m/%d)" -name 'rollout-*.jsonl' 2>/dev/null \
    | sort -r \
    | head -5 \
    | xargs grep -l 'rate_limits' 2>/dev/null \
    | head -1 \
    | xargs grep 'rate_limits' 2>/dev/null \
    | tail -1 \
    | jq -c '.payload.rate_limits | select(.primary) | {
        remaining_5h: (100 - .primary.used_percent),
        remaining_weekly: (100 - .secondary.used_percent)
    }' 2>/dev/null || true)

# Merge usage and rate limits into single JSON
if [[ -n "$USAGE" && -n "$RATE_LIMITS" ]]; then
    USAGE=$(jq -c -s '.[0] * .[1]' <(printf '%s' "$USAGE") <(printf '%s' "$RATE_LIMITS") 2>/dev/null || printf '%s' "$USAGE")
fi
if [[ -n "$USAGE" ]]; then
    printf '\n---USAGE---\n%s\n' "$USAGE"
fi

# Cache output for session loss recovery
CACHE_ID="${SESSION_ID:-$(date +%s)}"
OUTPUT=$(if [[ -z "$RESULT" ]]; then cat "$WORK_DIR/stderr"; else printf '%s\n' "$RESULT"; fi)
if [[ -n "$USAGE" ]]; then
    printf '%s\n\n---USAGE---\n%s\n' "$OUTPUT" "$USAGE" > "$CACHE_DIR/codex-review-$CACHE_ID.txt"
else
    printf '%s\n' "$OUTPUT" > "$CACHE_DIR/codex-review-$CACHE_ID.txt"
fi
