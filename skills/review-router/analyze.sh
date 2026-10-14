#!/usr/bin/env bash
# Analyze the diff against a base branch and classify it into a review tier.
# Emits a single JSON object on stdout describing size, touched dimensions, tier, and the
# reviewers to run (narrowed by this branch's review history unless --full is given).
set -euo pipefail

# Tunable thresholds. Adjust here to change routing aggressiveness.
HIGH_CHURN=400      # insertions+deletions above this => high tier
HIGH_FILES=15       # files changed above this => high tier
LOW_CHURN=50        # insertions+deletions at/below this (with few files, no risk) => low tier
LOW_FILES=3         # files changed at/below this => low tier candidate

# The skill passes $ARGUMENTS as one quoted string, so tokenize all args with
# `read -a`, which splits on whitespace without glob expansion.
read -r -a TOKENS <<<"$*"

BASE_BRANCH=""
OPT_AGY=false
OPT_LMS=false
OPT_FULL=false
for token in "${TOKENS[@]+"${TOKENS[@]}"}"; do
    case "${token}" in
        --agy) OPT_AGY=true ;;
        --lms) OPT_LMS=true ;;
        --full) OPT_FULL=true ;;
        -*)
            echo "ERROR: unknown option '${token}' (supported: --agy, --lms, --full)" >&2
            exit 1
            ;;
        *)
            if [ -n "${BASE_BRANCH}" ]; then
                echo "ERROR: multiple base branches given ('${BASE_BRANCH}', '${token}')" >&2
                exit 1
            fi
            BASE_BRANCH="${token}"
            ;;
    esac
done
BASE_BRANCH="${BASE_BRANCH:-main}"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: not inside a git work tree" >&2
    exit 1
fi

# Resolve the base to a real ref. Fall back to origin/<base> so a checkout that
# only has the remote-tracking branch (e.g. fresh clone, no local main) still works.
RESOLVED_BASE="${BASE_BRANCH}"
if git rev-parse --verify --quiet "${RESOLVED_BASE}" >/dev/null; then
    :
elif git rev-parse --verify --quiet "origin/${BASE_BRANCH}" >/dev/null; then
    RESOLVED_BASE="origin/${BASE_BRANCH}"
else
    echo "ERROR: base ref '${BASE_BRANCH}' not found (also tried 'origin/${BASE_BRANCH}')" >&2
    exit 1
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

# Use three-dot range so we compare against the merge-base (changes on this branch only).
RANGE="${RESOLVED_BASE}...HEAD"

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

# Count non-empty lines (one path per changed file). awk exits 0 even for an
# empty file, so a genuine read error surfaces instead of being masked as 0.
files_changed=$(awk 'NF { c++ } END { print c + 0 }' "${WORK_DIR}/names")

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

# Set the dim_* globals from a file list ($1) and a patch ($2). Also used, in a subshell, to
# check which dimensions changed since a reviewer last ran.
detect_dims() {
    local names_lc added added_lc
    names_lc=$(tr '[:upper:]' '[:lower:]' <"$1")
    # Added/changed content lines (leading '+', excluding the '+++' file header).
    # awk avoids the grep '|| true' that would otherwise mask a real read failure.
    added=$(awk '/^\+/ && !/^\+\+\+/' "$2")
    added_lc=$(tr '[:upper:]' '[:lower:]' <<<"${added}")

    dim_tests=$(has '(^|/)tests?/|(^|/)test_|_test\.|\.test\.|\.spec\.|_spec\.' "${names_lc}")
    if grep -qE '\.pyi$|\.d\.ts$' <<<"${names_lc}"; then
        dim_types=true
    else
        # POSIX ERE word boundaries: (^|[^[:alnum:]_]) / ([^[:alnum:]_]|$). \b/\s are
        # not POSIX and break on non-GNU grep. @dataclass is a substring (a leading
        # boundary before '@' never holds). case-insensitive via added_lc.
        dim_types=$(has '(^|[^[:alnum:]_])(interface|typeddict|protocol)([^[:alnum:]_]|$)|@dataclass|(^|[^[:alnum:]_])(type|enum)[[:space:]]' "${added_lc}")
    fi
    dim_error=$(has '(^|[^[:alnum:]_])(try|except|catch|finally|raise|throw|rescue)([^[:alnum:]_]|$)' "${added}")
    if grep -qE '\.mdx?$|\.rst$' <<<"${names_lc}"; then
        dim_comments=true
    else
        dim_comments=$(has '^\+[[:space:]]*(#|//|/\*|\*|"""|'"'''"')' "${added}")
    fi
    dim_migrations=$(has '(^|/)migrations?/|alembic|\.sql$|schema\.' "${names_lc}")
    dim_security=$(has '(^|[^[:alnum:]_])(authn?|token|crypto|hmac|eval|sql)([^[:alnum:]_]|$)|authenticat|authoriz|oauth|secret|password|passwd|jwt|subprocess|os\.system|\.execute\(' "${added_lc}")
    # concurrency stays case-sensitive: patterns like Thread(/Lock(/Semaphore are capitalized.
    dim_concurrency=$(has '(^|[^[:alnum:]_])(async|await|asyncio|threading|goroutine|mutex|Semaphore)([^[:alnum:]_]|$)|(^|[^[:alnum:]_])(Thread|Lock|RLock)\(|go func' "${added}")
}

detect_dims "${WORK_DIR}/names" "${WORK_DIR}/patch"

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

# Reviewers routed by tier and dimensions (pr-review-toolkit agent names without the prefix).
# A new specialist also needs its dimension in reviewer_dim and dim_changed_since below, or
# it can never be revived after history omits it.
routed=(code-reviewer)
if [[ "${tier}" != low ]]; then
    if [[ "${dim_tests}" == true ]]; then routed+=(pr-test-analyzer); fi
    if [[ "${dim_types}" == true ]]; then routed+=(type-design-analyzer); fi
    if [[ "${dim_error}" == true ]]; then routed+=(silent-failure-hunter); fi
    if [[ "${dim_comments}" == true ]]; then routed+=(comment-analyzer); fi
fi
# Review history for this branch, written by record-state.sh after the first review round of
# each run. History is an optimization, so any problem reading it falls back to running every
# routed reviewer instead of failing the analysis.
history_reason=""
if ! STATE_FILE=$(bash "$(dirname "${BASH_SOURCE[0]}")/record-state.sh" --path) || [[ "${STATE_FILE}" == *$'\n'* ]]; then
    echo "WARN: review history unavailable; running every routed reviewer" >&2
    STATE_FILE=""
    history_reason=history_unavailable
fi
# record-state.sh --read validates the whole shape (null when missing or malformed), so the
# per-reviewer reads below cannot fail mid-way.
state=null
if [[ -n "${STATE_FILE}" ]] && ! state=$(bash "$(dirname "${BASH_SOURCE[0]}")/record-state.sh" --read); then
    echo "WARN: review history unavailable; running every routed reviewer" >&2
    state=null
    history_reason=history_unavailable
fi
current_branch=$(git symbolic-ref --quiet --short HEAD || true)

if [[ -n "${history_reason}" ]]; then
    :
elif [[ "${OPT_FULL}" == true ]]; then
    history_reason=full
elif [[ -z "${STATE_FILE}" ]]; then
    history_reason=detached_head
elif [[ "${state}" == null || "$(jq -r '.branch // ""' <<<"${state}")" != "${current_branch}" ]]; then
    history_reason=first_run
elif [[ "$(jq -r '.base // ""' <<<"${state}")" != "${RESOLVED_BASE}" ]]; then
    history_reason=base_changed
else
    history_reason=history
fi

# The dimension each specialist reviewer covers, so an omitted reviewer can come back when
# its area changes again.
reviewer_dim() {
    case "$1" in
        pr-test-analyzer) echo tests ;;
        type-design-analyzer) echo types ;;
        silent-failure-hunter) echo error_handling ;;
        comment-analyzer) echo comments_docs ;;
        *) echo "" ;;
    esac
}

# Echo whether a dimension is touched by the changes from commit $1 to HEAD. Runs in a
# command substitution, so detect_dims does not overwrite this run's dim_* values.
dim_changed_since() {
    git diff --name-only "$1" HEAD >"${WORK_DIR}/since_names"
    git diff "$1" HEAD >"${WORK_DIR}/since_patch"
    detect_dims "${WORK_DIR}/since_names" "${WORK_DIR}/since_patch"
    case "$2" in
        tests) echo "${dim_tests}" ;;
        types) echo "${dim_types}" ;;
        error_handling) echo "${dim_error}" ;;
        comments_docs) echo "${dim_comments}" ;;
        *) echo false ;;
    esac
}

# Run every routed reviewer on the first review of a branch. Afterwards keep code-reviewer
# as the general baseline, reviewers whose findings were adopted on the previous run, ones
# that have never run on this branch, and omitted ones whose dimension changed since they
# last ran (or whose last run is no longer in this branch's history, e.g. after a rebase).
selected=()
omitted=()
revived=()
for reviewer in "${routed[@]}"; do
    if [[ "${history_reason}" != history || "${reviewer}" == code-reviewer ]]; then
        selected+=("${reviewer}")
        continue
    fi
    entry=$(jq -c --arg r "${reviewer}" '.reviewers[$r] // empty' <<<"${state}")
    if [[ -z "${entry}" || "$(jq -r '.last_adopted // 0' <<<"${entry}")" -ge 1 ]]; then
        selected+=("${reviewer}")
        continue
    fi
    last_head=$(jq -r '.last_head // ""' <<<"${entry}")
    if [[ -z "${last_head}" ]] || ! git merge-base --is-ancestor "${last_head}" HEAD 2>/dev/null \
        || [[ "$(dim_changed_since "${last_head}" "$(reviewer_dim "${reviewer}")")" == true ]]; then
        selected+=("${reviewer}")
        revived+=("${reviewer}")
        continue
    fi
    omitted+=("${reviewer}")
done

to_json_array() {
    if [ "$#" -eq 0 ]; then echo '[]'; return; fi
    printf '%s\n' "$@" | jq -R . | jq -c -s .
}

previous_runs=0
if [[ "${history_reason}" == history ]]; then
    previous_runs=$(jq -r '.runs // 0' <<<"${state}")
fi

selection=$(jq -n -c \
    --argjson reviewers "$(to_json_array "${selected[@]+"${selected[@]}"}")" \
    --argjson omitted "$(to_json_array "${omitted[@]+"${omitted[@]}"}")" \
    --argjson revived "$(to_json_array "${revived[@]+"${revived[@]}"}")" \
    --arg reason "${history_reason}" \
    --argjson previous_runs "${previous_runs}" \
    --arg state_file "${STATE_FILE}" \
    '{reviewers: $reviewers, reason: $reason, omitted: $omitted, revived: $revived,
      previous_runs: $previous_runs, state_file: $state_file}')

jq -n \
    --arg base "${RESOLVED_BASE}" \
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
    --argjson agy "${OPT_AGY}" \
    --argjson lms "${OPT_LMS}" \
    --argjson full "${OPT_FULL}" \
    --argjson selection "${selection}" \
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
        tier: $tier,
        reviewers: $selection.reviewers,
        history: ($selection | del(.reviewers)),
        options: {
            agy: $agy,
            lms: $lms,
            full: $full
        }
    }'
