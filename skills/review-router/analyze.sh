#!/usr/bin/env bash
# Analyze the diff against a base branch and classify it into a review tier.
# Emits a single JSON object on stdout describing size, touched dimensions, and tier.
set -euo pipefail

# Tunable thresholds. Adjust here to change routing aggressiveness.
HIGH_CHURN=400      # insertions+deletions above this => high tier
HIGH_FILES=15       # files changed above this => high tier
LOW_CHURN=50        # insertions+deletions at/below this (with few files, no risk) => low tier
LOW_FILES=3         # files changed at/below this => low tier candidate

BASE_BRANCH="${1:-main}"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: not inside a git work tree" >&2
    exit 1
fi

if ! git rev-parse --verify --quiet "${BASE_BRANCH}" >/dev/null; then
    echo "ERROR: base ref '${BASE_BRANCH}' not found" >&2
    exit 1
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

# Use three-dot range so we compare against the merge-base (changes on this branch only).
RANGE="${BASE_BRANCH}...HEAD"

# A real diff failure here (no merge base, unborn HEAD, corrupt object) must abort
# loudly. Masking it with `2>/dev/null || true` would feed empty files downstream
# and emit confident "0 files / low tier" JSON, silently misrouting the review.
if ! git diff --numstat "${RANGE}" >"${WORK_DIR}/numstat"; then
    echo "ERROR: cannot diff '${RANGE}' (no merge base / unborn HEAD?)" >&2
    exit 1
fi
git diff --name-only "${RANGE}" >"${WORK_DIR}/names"
# Patch text (added/removed lines) for content-based dimension detection.
git diff "${RANGE}" >"${WORK_DIR}/patch"

files_changed=$(grep -c . "${WORK_DIR}/names" || true)
files_changed=${files_changed:-0}

# Sum insertions/deletions from numstat, skipping binary files ('-' columns).
read -r insertions deletions < <(awk '
    $1 != "-" && $2 != "-" { ins += $1; del += $2 }
    END { printf "%d %d\n", ins+0, del+0 }
' "${WORK_DIR}/numstat")

churn=$((insertions + deletions))

# Languages from file extensions (unique, lowercase). Use the last dot in the
# basename, and ignore leading-dot dotfiles (e.g. .gitignore => no extension).
languages=$(awk -F/ '
    {
        b = $NF; p = 0
        for (i = 1; i <= length(b); i++) if (substr(b, i, 1) == ".") p = i
        if (p > 1) print tolower(substr(b, p + 1))
    }
' "${WORK_DIR}/names" | sort -u | jq -R . | jq -c -s .)
# (empty input yields [] naturally; a genuine jq failure aborts under set -e.)

names_lc=$(tr '[:upper:]' '[:lower:]' <"${WORK_DIR}/names")
# Only added/changed content lines (leading '+', excluding the '+++' file header).
added=$(grep -E '^\+' "${WORK_DIR}/patch" | grep -vE '^\+\+\+' || true)
added_lc=$(tr '[:upper:]' '[:lower:]' <<<"${added}")

# Pattern presence test via here-string, NOT a pipe: under `set -euo pipefail`
# a piped `grep -q` exits at the first match and SIGPIPEs the upstream writer,
# which aborts the whole script on large (high-tier) diffs before any JSON.
has() {
    if grep -qE "$1" <<<"$2"; then
        echo true
    else
        local rc=$?
        # rc 1 == no match (expected); anything else is a real grep error.
        [ "${rc}" -eq 1 ] && { echo false; return; }
        echo "ERROR: grep failed (rc=${rc}) for pattern: $1" >&2
        exit 1
    fi
}

dim_tests=$(has '(^|/)tests?/|(^|/)test_|_test\.|\.test\.|\.spec\.|_spec\.' "${names_lc}")
if grep -qE '\.pyi$|\.d\.ts$' <<<"${names_lc}"; then
    dim_types=true
else
    # case-insensitive (added_lc) so Python TypedDict/Protocol/Enum still match.
    dim_types=$(has '\b(interface|type |typeddict|protocol|@dataclass|enum )' "${added_lc}")
fi
dim_error=$(has '\b(try|except|catch|finally|raise|throw)\b|rescue ' "${added}")
if grep -qE '\.mdx?$|\.rst$' <<<"${names_lc}"; then
    dim_comments=true
else
    dim_comments=$(has '^\+\s*(#|//|/\*|\*|"""|'"'''"')' "${added}")
fi
dim_migrations=$(has '(^|/)migrations?/|alembic|\.sql$|schema\.' "${names_lc}")
dim_security=$(has 'auth|token|secret|password|passwd|jwt|crypto|hmac|\beval\b|subprocess|os\.system|\.execute\(|sql' "${added_lc}")
# concurrency stays case-sensitive: patterns like Thread(/Lock(/Semaphore are capitalized.
dim_concurrency=$(has '\b(async|await|asyncio|threading|Thread\(|goroutine|go func|mutex|Lock\(|RLock\(|Semaphore)\b' "${added}")

# Tier classification.
has_risk=false
if [[ "${dim_security}" == true || "${dim_migrations}" == true || "${dim_concurrency}" == true ]]; then
    has_risk=true
fi

if [[ "${has_risk}" == true || "${churn}" -gt "${HIGH_CHURN}" || "${files_changed}" -gt "${HIGH_FILES}" ]]; then
    tier=high
elif [[ "${churn}" -le "${LOW_CHURN}" && "${files_changed}" -le "${LOW_FILES}" ]]; then
    tier=low
else
    tier=medium
fi

jq -n \
    --arg base "${BASE_BRANCH}" \
    --argjson files "${files_changed}" \
    --argjson ins "${insertions}" \
    --argjson del "${deletions}" \
    --argjson langs "${languages}" \
    --argjson tests "${dim_tests}" \
    --argjson types "${dim_types}" \
    --argjson err "${dim_error}" \
    --argjson comments "${dim_comments}" \
    --argjson migrations "${dim_migrations}" \
    --argjson security "${dim_security}" \
    --argjson concurrency "${dim_concurrency}" \
    --arg tier "${tier}" \
    '{
        base: $base,
        files_changed: $files,
        insertions: $ins,
        deletions: $del,
        languages: $langs,
        dimensions: {
            tests: $tests,
            types: $types,
            error_handling: $err,
            comments_docs: $comments,
            migrations: $migrations,
            security: $security,
            concurrency: $concurrency
        },
        tier: $tier
    }'
