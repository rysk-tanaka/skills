#!/usr/bin/env bash
# Minimize PR comments by node ID
# Usage: minimize.sh <node_id> [<node_id> ...]
set -euo pipefail

for id in "$@"; do
    echo "Minimizing: $id" >&2
    # shellcheck disable=SC2016 # $id is a GraphQL variable, not a shell variable
    gh api graphql -f query='mutation($id: ID!) { minimizeComment(input: {subjectId: $id, classifier: OUTDATED}) { minimizedComment { isMinimized } } }' -f id="$id" \
        || echo "Warning: failed to minimize comment $id" >&2
done
