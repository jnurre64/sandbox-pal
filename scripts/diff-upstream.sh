#!/bin/bash
# Diff vendored files against a local claude-agent-dispatch checkout to find upstream drift.

set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-$HOME/claude-agent-dispatch}"
if [ ! -d "$UPSTREAM_REPO" ]; then
    echo "diff-upstream: $UPSTREAM_REPO not found (set UPSTREAM_REPO to a local clone)" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

declare -A MAP=(
    ["image/opt/pal/prompts/adversarial-plan.md"]="prompts/adversarial-plan.md"
    ["image/opt/pal/prompts/post-impl-review.md"]="prompts/post-impl-review.md"
    ["image/opt/pal/prompts/post-impl-retry.md"]="prompts/post-impl-retry.md"
    ["image/opt/pal/prompts/implement.md"]="prompts/implement.md"
    ["image/opt/pal/lib/review-gates.sh"]="scripts/lib/review-gates.sh"
)

echo "=== Upstream commit ==="
(cd "$UPSTREAM_REPO" && git log --oneline -1)
echo ""

exit_code=0
for local_file in "${!MAP[@]}"; do
    upstream_file="${MAP[$local_file]}"
    printf -- "--- %s ---\n" "$local_file"
    if diff -u "$UPSTREAM_REPO/$upstream_file" "$REPO_ROOT/$local_file" > /tmp/pal-diff.txt; then
        echo "(unchanged)"
    else
        cat /tmp/pal-diff.txt
        exit_code=1
    fi
    echo ""
done

exit $exit_code
