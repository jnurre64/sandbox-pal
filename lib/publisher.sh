# lib/publisher.sh
# shellcheck shell=bash
# Publish a plan file as an issue comment (with <!-- agent-plan --> marker).

pal_publish_plan() {
    local plan_file="$1"
    local repo="$2"
    local issue="${3:-}"

    local plan_content
    plan_content=$(cat "$plan_file")
    local comment_body=$'<!-- agent-plan -->\n'"$plan_content"

    if [ -z "$issue" ]; then
        # Derive title from first H1 in the plan file
        local title
        title=$(awk '/^# /{sub(/^# /,""); print; exit}' "$plan_file")
        if [ -z "$title" ]; then
            title="sandbox-pal implementation plan ($(date -I))"
        fi

        local problem_summary="<!-- agent-plan -->
$plan_content"

        local new_issue_url
        new_issue_url=$(GH_TOKEN="$GH_TOKEN" gh issue create \
            --repo "$repo" \
            --title "$title" \
            --body "$problem_summary" \
            2>&1 | tail -1) || {
                echo "pal: failed to create issue" >&2
                return 1
            }
        issue=$(echo "$new_issue_url" | grep -Eo '/issues/[0-9]+' | grep -Eo '[0-9]+')
        echo "Created new issue: $new_issue_url"
    else
        local comment_url
        comment_url=$(GH_TOKEN="$GH_TOKEN" gh issue comment "$issue" \
            --repo "$repo" \
            --body "$comment_body" 2>&1 | tail -1) || {
                echo "pal: failed to post comment on issue $issue" >&2
                return 1
            }
        echo "Posted plan comment: $comment_url"
    fi

    echo ""
    echo "Next step:"
    echo "  /pal-implement $issue"
}
