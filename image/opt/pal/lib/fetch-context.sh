# image/opt/pal/lib/fetch-context.sh
# shellcheck shell=bash
# Fetch issue + plan comment (or PR context for revise) and export as env vars.

fetch_issue_context() {
    local repo="$1"
    local number="$2"

    local issue_json
    issue_json=$(gh issue view "$number" --repo "$repo" --json title,body,comments 2>/dev/null) || {
        log "fetch-context: failed to load issue $number on $repo"
        return 1
    }

    AGENT_ISSUE_NUMBER="$number"
    AGENT_ISSUE_TITLE=$(jq -r .title <<< "$issue_json")
    AGENT_ISSUE_BODY=$(jq -r .body <<< "$issue_json")
    AGENT_COMMENTS=$(jq -r '.comments[] | "## " + .author.login + " at " + .createdAt + "\n" + .body' <<< "$issue_json")

    # Find the latest <!-- agent-plan --> marker — check comments first, then body
    AGENT_PLAN_CONTENT=$(jq -r '[.comments[] | select(.body | startswith("<!-- agent-plan -->"))] | last | .body // ""' <<< "$issue_json" | sed 's|^<!-- agent-plan -->||')

    if [ -z "$AGENT_PLAN_CONTENT" ]; then
        # Fallback: publisher puts the marker in the issue body when creating a new issue
        local raw_body
        raw_body=$(jq -r '.body // ""' <<< "$issue_json")
        if [[ "$raw_body" == "<!-- agent-plan -->"* ]]; then
            AGENT_PLAN_CONTENT="${raw_body#<!-- agent-plan -->}"
        fi
    fi

    if [ -z "$AGENT_PLAN_CONTENT" ]; then
        log "fetch-context: no <!-- agent-plan --> comment found on issue $number"
        return 2  # caller handles "no plan" specially
    fi

    export AGENT_ISSUE_NUMBER AGENT_ISSUE_TITLE AGENT_ISSUE_BODY AGENT_COMMENTS AGENT_PLAN_CONTENT
    log "fetch-context: loaded issue $number (plan length: $(printf '%s' "$AGENT_PLAN_CONTENT" | wc -c) bytes)"
}

fetch_pr_context() {
    local repo="$1"
    local pr_number="$2"

    local pr_json
    pr_json=$(gh pr view "$pr_number" --repo "$repo" --json title,body,comments,reviews,headRefName) || {
        log "fetch-context: failed to load PR $pr_number on $repo"
        return 1
    }

    AGENT_PR_NUMBER="$pr_number"
    AGENT_PR_TITLE=$(jq -r .title <<< "$pr_json")
    AGENT_PR_BODY=$(jq -r .body <<< "$pr_json")
    AGENT_PR_BRANCH=$(jq -r .headRefName <<< "$pr_json")

    # Gather review feedback (general + inline)
    AGENT_REVIEW_FEEDBACK=$(jq -r '
        [.reviews[] | select(.state=="CHANGES_REQUESTED") | "## Reviewer " + .author.login + " (" + .submittedAt + ")\n" + .body] +
        [.comments[] | "## Comment by " + .author.login + "\n" + .body]
        | join("\n\n")
    ' <<< "$pr_json")

    # Also fetch linked issue for plan lookup
    local linked_issue
    linked_issue=$(gh pr view "$pr_number" --repo "$repo" --json body --jq '.body' | grep -Eoi 'closes?[[:space:]]+#([0-9]+)' | head -1 | grep -Eo '[0-9]+' || true)
    if [ -n "$linked_issue" ]; then
        fetch_issue_context "$repo" "$linked_issue" || true
    fi

    export AGENT_PR_NUMBER AGENT_PR_TITLE AGENT_PR_BODY AGENT_PR_BRANCH AGENT_REVIEW_FEEDBACK
    log "fetch-context: loaded PR $pr_number (branch $AGENT_PR_BRANCH, review feedback length: $(printf '%s' "$AGENT_REVIEW_FEEDBACK" | wc -c) bytes)"
}
