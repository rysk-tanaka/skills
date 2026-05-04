#!/usr/bin/env bash
# Fetch PR review threads with resolved status via GraphQL API
set -euo pipefail

# --- PR number ---

if [[ $# -ge 1 && "$1" =~ ^[0-9]+$ ]]; then
    PR_NUMBER="$1"
else
    PR_NUMBER=$(gh pr view --json number -q .number 2>/dev/null || true)
    if [[ -z "$PR_NUMBER" ]]; then
        echo "Error: no PR found for current branch. Specify a PR number as argument." >&2
        exit 1
    fi
fi

# --- owner/repo ---

OWNER_REPO=$(gh repo view --json owner,name -q '.owner.login + "/" + .name')
OWNER="${OWNER_REPO%%/*}"
REPO="${OWNER_REPO##*/}"

# --- GraphQL query ---

QUERY='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      title
      url
      reviewThreads(first: 100) {
        pageInfo { hasNextPage }
        nodes {
          id
          isResolved
          isOutdated
          comments(first: 50) {
            pageInfo { hasNextPage }
            nodes {
              body
              author { login }
              createdAt
              path
              line
              diffHunk
            }
          }
        }
      }
      comments(first: 100) {
        pageInfo { hasNextPage }
        nodes {
          id
          body
          author { login }
          createdAt
          isMinimized
          url
        }
      }
      reviews(first: 50) {
        pageInfo { hasNextPage }
        nodes {
          id
          author { login }
          state
          body
          createdAt
          url
        }
      }
    }
  }
}
'

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

RESPONSE=$(gh api graphql \
    -f query="$QUERY" \
    -f owner="$OWNER" \
    -f repo="$REPO" \
    -F number="$PR_NUMBER")

echo "$RESPONSE" > "$WORK_DIR/response"

# --- Pagination warnings ---

jq -e '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' "$WORK_DIR/response" > /dev/null 2>&1 \
    && echo "Warning: review threads exceeded 100, some threads may be missing." >&2

jq -e '[.data.repository.pullRequest.reviewThreads.nodes[].comments.pageInfo.hasNextPage] | any' "$WORK_DIR/response" > /dev/null 2>&1 \
    && echo "Warning: some threads exceeded 50 comments, replies may be missing." >&2

jq -e '.data.repository.pullRequest.comments.pageInfo.hasNextPage' "$WORK_DIR/response" > /dev/null 2>&1 \
    && echo "Warning: PR comments exceeded 100, some comments may be missing." >&2

jq -e '.data.repository.pullRequest.reviews.pageInfo.hasNextPage' "$WORK_DIR/response" > /dev/null 2>&1 \
    && echo "Warning: PR reviews exceeded 50, some reviews may be missing." >&2

# --- Bot authors (keep only latest comment per author) ---

BOT_AUTHORS='["claude"]'

# --- Transform to normalized JSON ---

jq -n \
    --argjson number "$PR_NUMBER" \
    --argjson bot_authors "$BOT_AUTHORS" \
    --rawfile response "$WORK_DIR/response" \
    '
    # Strip review-bot metadata noise from comment bodies.
    # Applied to all comments (not just bots) for simplicity — HTML comments
    # stripped here are invisible metadata, not user-visible review content.
    def strip_noise:
      gsub("(?s)<!-- internal state start -->.*?<!-- internal state end -->"; "")
      | gsub("(?s)<!-- tips_start -->.*?<!-- tips_end -->"; "")
      | gsub("(?s)<!-- finishing_touch_checkbox_start -->.*?<!-- finishing_touch_checkbox_end -->"; "")
      | gsub("(?m)^[ \\t]*<!--.*?-->[ \\t]*$"; "")
      | gsub("\\n{3,}"; "\n\n")
      | sub("\\s+$"; "");

    ($response | fromjson) as $data |
    $data.data.repository.pullRequest as $pr |

    # Build all non-minimized comments
    [
        $pr.comments.nodes[] |
        select(.isMinimized | not) |
        {
            id: .id,
            body: (.body | strip_noise),
            author: (.author.login // "ghost"),
            created_at: .createdAt,
            url: .url
        }
    ] as $all_comments |

    # Split into human and bot comments
    [$all_comments[] | select(.author as $a | $bot_authors | index($a) | not)] as $human |
    [$all_comments[] | select(.author as $a | $bot_authors | index($a))] as $bot |

    # Keep only latest comment per bot author
    ([$bot | group_by(.author)[] | sort_by(.created_at) | last]) as $bot_latest |

    # Reviews with substantive content (excludes drafts and pure approval/comment signals).
    # Pure inline-only reviews appear in review_threads; this captures only the summary body.
    [
        $pr.reviews.nodes[] |
        select(.state != "PENDING") |
        select((.body // "") | strip_noise | length > 0) |
        {
            id: .id,
            author: (.author.login // "ghost"),
            state: .state,
            body: (.body | strip_noise),
            created_at: .createdAt,
            url: .url
        }
    ] as $reviews |

    {
        pr_number: $number,
        title: $pr.title,
        url: $pr.url,
        review_threads: [
            $pr.reviewThreads.nodes[] | {
                id: .id,
                is_resolved: .isResolved,
                is_outdated: .isOutdated,
                comments: [
                    .comments.nodes[] | {
                        body: (.body | strip_noise),
                        author: (.author.login // "ghost"),
                        created_at: .createdAt,
                        path: .path,
                        line: .line,
                        diff_hunk: .diffHunk
                    }
                ]
            }
        ],
        reviews: ($reviews | sort_by(.created_at)),
        comments: ($human + $bot_latest | sort_by(.created_at)),
        bot_comments_omitted: (($bot | length) - ($bot_latest | length)),
        bot_comments_to_minimize: (($bot | map(.id)) - ($bot_latest | map(.id)))
    }
    '
