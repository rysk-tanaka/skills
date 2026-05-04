#!/usr/bin/env bash
# Collect staged changes data for commit message generation
set -euo pipefail

# --- Validation ---

if git diff --cached --quiet 2>/dev/null; then
    echo "Error: No staged changes found. Run 'git add' first." >&2
    exit 1
fi

# --- Data collection ---

STAGED_FILES=$(git diff --cached --name-only)
LOG=$(git log --oneline -10 2>/dev/null || true)
STAT=$(git diff --cached --stat)

# Identify large files to exclude from detailed diff
# Criteria: >500 changed lines OR single-file diff >50KB (e.g. minified SVG)
LARGE_FILE_EXCLUDES=()
EXCLUDED_LARGE_FILES=""
while IFS=$'\t' read -r added removed file; do
    [[ "$added" == "-" || "$removed" == "-" ]] && continue  # binary
    total=$((added + removed))
    exclude=false
    if [[ $total -gt 500 ]]; then
        exclude=true
    else
        diff_bytes=$(git diff --cached -- "$file" | wc -c | tr -d ' ')
        if [[ $diff_bytes -gt 51200 ]]; then
            exclude=true
        fi
    fi
    if [[ "$exclude" == "true" ]]; then
        LARGE_FILE_EXCLUDES+=(":!$file")
        EXCLUDED_LARGE_FILES+="$file"$'\n'
    fi
done < <(git diff --cached --numstat)

# Exclude specific lockfiles using :(exclude,glob) magic so ** matches root and subdirectories
LOCK_EXCLUDES=(
    ":(exclude,glob)**/package-lock.json"
    ":(exclude,glob)**/yarn.lock"
    ":(exclude,glob)**/pnpm-lock.yaml"
    ":(exclude,glob)**/uv.lock"
    ":(exclude,glob)**/Gemfile.lock"
    ":(exclude,glob)**/poetry.lock"
    ":(exclude,glob)**/Cargo.lock"
    ":(exclude,glob)**/composer.lock"
)
DIFF=$(git diff --cached -- "${LOCK_EXCLUDES[@]}" ${LARGE_FILE_EXCLUDES[@]+"${LARGE_FILE_EXCLUDES[@]}"})

# --- Output JSON ---

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

printf '%s' "$STAGED_FILES" > "$WORK_DIR/staged_files"
printf '%s' "$LOG" > "$WORK_DIR/log"
printf '%s' "$STAT" > "$WORK_DIR/stat"
printf '%s' "$DIFF" > "$WORK_DIR/diff"
printf '%s' "$EXCLUDED_LARGE_FILES" > "$WORK_DIR/excluded_large_files"

jq -n \
    --rawfile staged_files "$WORK_DIR/staged_files" \
    --rawfile log "$WORK_DIR/log" \
    --rawfile stat "$WORK_DIR/stat" \
    --rawfile diff "$WORK_DIR/diff" \
    --rawfile excluded_large_files "$WORK_DIR/excluded_large_files" \
    '{
        staged_files: $staged_files,
        log: $log,
        stat: $stat,
        diff: $diff,
        excluded_large_files: $excluded_large_files
    }'
