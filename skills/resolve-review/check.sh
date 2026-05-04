#!/usr/bin/env bash
# Check CI status for a PR, optionally polling until completion
set -euo pipefail

# --- Defaults ---

PR_NUMBER=""
WATCH=false
INTERVAL=30
TIMEOUT=540

# --- Argument parsing ---

while [[ $# -gt 0 ]]; do
    case "$1" in
        --watch)    WATCH=true; shift ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        --timeout)  TIMEOUT="$2"; shift 2 ;;
        -*)         echo "Error: unknown flag: $1" >&2; exit 1 ;;
        *)
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                PR_NUMBER="$1"
            else
                echo "Error: invalid argument: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

# --- PR number ---

if [[ -z "$PR_NUMBER" ]]; then
    PR_NUMBER=$(gh pr view --json number -q .number 2>/dev/null || true)
    if [[ -z "$PR_NUMBER" ]]; then
        echo "Error: no PR found for current branch. Specify a PR number as argument." >&2
        exit 1
    fi
fi

# --- Helper functions ---

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

fetch_checks() {
    local stderr_file="$WORK_DIR/stderr"
    if gh pr checks "$PR_NUMBER" \
        --json bucket,name,state,description,link,workflow,event,startedAt,completedAt \
        > "$WORK_DIR/raw" 2>"$stderr_file"; then
        return 0
    fi
    if grep -q "no checks reported" "$stderr_file" 2>/dev/null; then
        echo '[]' > "$WORK_DIR/raw"
        return 10
    fi
    return 1
}

normalize_output() {
    local elapsed="$1"
    jq -n \
        --argjson pr_number "$PR_NUMBER" \
        --argjson elapsed "$elapsed" \
        --rawfile raw "$WORK_DIR/raw" \
        '
        ($raw | fromjson) as $checks |
        {
            pass: [$checks[] | select(.bucket == "pass")] | length,
            fail: [$checks[] | select(.bucket == "fail")] | length,
            pending: [$checks[] | select(.bucket == "pending")] | length,
            skipping: [$checks[] | select(.bucket == "skipping")] | length,
            cancel: [$checks[] | select(.bucket == "cancel")] | length
        } as $counts |
        ($counts | to_entries | map(.value) | add) as $total |
        (if $counts.fail > 0 or $counts.cancel > 0 then "fail"
         elif $total == 0 or $counts.pending > 0 then "pending"
         else "pass" end) as $status |
        {
            pr_number: $pr_number,
            status: $status,
            elapsed_seconds: $elapsed,
            summary: ($counts + { total: $total }),
            checks: [
                $checks[] | {
                    name: .name,
                    bucket: .bucket,
                    state: .state,
                    description: .description,
                    workflow: .workflow,
                    link: .link,
                    started_at: .startedAt,
                    completed_at: .completedAt
                }
            ]
        }
        '
}

has_pending() {
    jq -e 'map(select(.bucket == "pending")) | length > 0' "$WORK_DIR/raw" > /dev/null 2>&1
}

check_count() {
    jq 'length' "$WORK_DIR/raw"
}

exit_with_status() {
    local result="$1"
    local status
    status=$(echo "$result" | jq -r '.status')
    echo "$result"
    case "$status" in
        pass)    exit 0 ;;
        fail)    exit 1 ;;
        pending) exit 2 ;;
        *)       echo "Error: unexpected status: $status" >&2; exit 3 ;;
    esac
}

# --- One-shot mode ---

if [[ "$WATCH" == false ]]; then
    rc=0
    fetch_checks || rc=$?
    if [[ "$rc" -eq 10 ]]; then
        echo '{"pr_number":'"$PR_NUMBER"',"status":"no_checks","elapsed_seconds":0,"summary":{"total":0,"pass":0,"fail":0,"pending":0,"skipping":0,"cancel":0},"checks":[]}'
        exit 0
    elif [[ "$rc" -ne 0 ]]; then
        echo "Error: failed to fetch CI checks for PR #$PR_NUMBER" >&2
        exit 1
    fi
    exit_with_status "$(normalize_output 0)"
fi

# --- Watch mode ---

START_TIME=$SECONDS

NO_CHECKS_LIMIT=60

while true; do
    elapsed=$(( SECONDS - START_TIME ))

    rc=0
    fetch_checks || rc=$?
    if [[ "$rc" -eq 10 ]]; then
        no_checks_limit=$(( NO_CHECKS_LIMIT < TIMEOUT ? NO_CHECKS_LIMIT : TIMEOUT ))
        if [[ "$elapsed" -ge "$no_checks_limit" ]]; then
            echo "[$(date +%H:%M:%S)] No CI checks configured for PR #$PR_NUMBER" >&2
            echo '{"pr_number":'"$PR_NUMBER"',"status":"no_checks","elapsed_seconds":'"$elapsed"',"summary":{"total":0,"pass":0,"fail":0,"pending":0,"skipping":0,"cancel":0},"checks":[]}'
            exit 0
        fi
        echo "[$(date +%H:%M:%S)] No checks found yet, waiting... (${elapsed}s elapsed)" >&2
        sleep "$INTERVAL"
        continue
    elif [[ "$rc" -ne 0 ]]; then
        if [[ "$elapsed" -ge "$TIMEOUT" ]]; then
            echo "Timeout after ${elapsed}s (fetch failed)" >&2
            exit 2
        fi
        echo "[$(date +%H:%M:%S)] Warning: failed to fetch checks, retrying..." >&2
        sleep "$INTERVAL"
        continue
    fi

    total=$(check_count)

    if [[ "$total" -eq 0 ]]; then
        no_checks_limit=$(( NO_CHECKS_LIMIT < TIMEOUT ? NO_CHECKS_LIMIT : TIMEOUT ))
        if [[ "$elapsed" -ge "$no_checks_limit" ]]; then
            echo "[$(date +%H:%M:%S)] No CI checks configured for PR #$PR_NUMBER" >&2
            echo '{"pr_number":'"$PR_NUMBER"',"status":"no_checks","elapsed_seconds":'"$elapsed"',"summary":{"total":0,"pass":0,"fail":0,"pending":0,"skipping":0,"cancel":0},"checks":[]}'
            exit 0
        fi
        echo "[$(date +%H:%M:%S)] No checks found yet, waiting... (${elapsed}s elapsed)" >&2
    else
        result=$(normalize_output "$elapsed")
        jq -r \
            '"[\(now | strftime("%H:%M:%S"))] Checks: \(.summary.pass) pass, \(.summary.fail) fail, \(.summary.pending) pending (\(.elapsed_seconds)s elapsed)"' \
            <<< "$result" >&2

        if ! has_pending; then
            exit_with_status "$result"
        fi
    fi

    if [[ "$elapsed" -ge "$TIMEOUT" ]]; then
        echo "Timeout after ${elapsed}s" >&2
        if [[ "$total" -gt 0 ]]; then
            exit_with_status "$(normalize_output "$elapsed")"
        else
            exit 2
        fi
    fi

    sleep "$INTERVAL"
done
