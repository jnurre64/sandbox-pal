#!/bin/bash
# Diff vendored files against a local sandbox-pal-action checkout to find upstream drift.

set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-$HOME/repos/sandbox-pal-action}"
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
    ["image/opt/pal/prompts/test-fix.md"]="prompts/test-fix.md"
    ["image/opt/pal/lib/review-gates.sh"]="scripts/lib/review-gates.sh"
    ["image/opt/pal/lib/rules-staging.sh"]="scripts/lib/rules-staging.sh"
    ["image/opt/pal/schemas/adversarial-plan.json"]="schemas/adversarial-plan.json"
    ["image/opt/pal/schemas/post-impl-review.json"]="schemas/post-impl-review.json"
    ["image/opt/pal/schemas/post-impl-retry.json"]="schemas/post-impl-retry.json"
)

echo "=== Upstream commit ==="
(cd "$UPSTREAM_REPO" && git log --oneline -1)
echo ""

diff_tmp="$(mktemp)"
trap 'rm -f "$diff_tmp"' EXIT

exit_code=0
for local_file in "${!MAP[@]}"; do
    upstream_file="${MAP[$local_file]}"
    printf -- "--- %s ---\n" "$local_file"
    if diff -u "$UPSTREAM_REPO/$upstream_file" "$REPO_ROOT/$local_file" > "$diff_tmp"; then
        echo "(unchanged)"
    else
        cat "$diff_tmp"
        exit_code=1
    fi
    echo ""
done

echo "--- image/opt/pal/lib/claude-runner.sh ---"
echo "(ported from scripts/lib/common.sh — not a byte copy; review run_claude, parse_claude_output,"
echo " classify_claude_result, redact_secrets, *_permission_denials, get_structured_output by hand)"

exit $exit_code
