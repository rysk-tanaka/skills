#!/usr/bin/env bash
# Resolve PR review threads by node ID
# Usage: resolve.sh <node_id> [<node_id> ...]
set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "Usage: resolve.sh <node_id> [<node_id> ...]" >&2
    exit 2
fi

failed=0

for id in "$@"; do
    # Silently skip PR numbers passed alongside node IDs (intentionally no warning)
    [[ "$id" =~ ^[0-9]+$ ]] && continue
    echo "Resolving: $id" >&2
    # shellcheck disable=SC2016 # $id is a GraphQL variable, not a shell variable
    gh api graphql -f query='mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }' -f id="$id" \
        || { echo "Warning: failed to resolve thread $id" >&2; failed=1; }
done

exit $failed
