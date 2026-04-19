#!/bin/bash
# shellcheck disable=SC1091  # Sourced lib files resolved at runtime
set -euo pipefail

# ─── Args: <event_type> <repo> <number> ─────────────────────────
EVENT_TYPE="${1:?Usage: entrypoint.sh <event_type> <repo> <number>}"
REPO="${2:?}"
NUMBER="${3:?}"

# ─── Paths ───────────────────────────────────────────────────────
PAL_HOME="/opt/pal"
# shellcheck disable=SC2034  # PROMPTS_DIR is read by lib/claude-runner.sh (sourced later)
PROMPTS_DIR="$PAL_HOME/prompts"
LIB_DIR="$PAL_HOME/lib"
STATUS_DIR="${PAL_STATUS_DIR:-/status}"
WORKTREE_DIR="${WORKTREE_DIR:-/home/agent/work}"
AGENT_DATA_DIR="${AGENT_DATA_DIR:-/home/agent/.agent-data}"

mkdir -p "$STATUS_DIR" "$WORKTREE_DIR" "$AGENT_DATA_DIR"

# ─── Status tracking (mutated across phases, emitted at end) ────
STATUS_PHASE="init"
STATUS_OUTCOME="failure"            # default; set to "success" on happy path
STATUS_FAILURE_REASON=""
STATUS_PR_NUMBER="null"
STATUS_PR_URL="null"
STATUS_COMMITS="[]"
STATUS_REVIEW_CONCERNS_ADDRESSED="[]"
STATUS_REVIEW_CONCERNS_UNRESOLVED="[]"
STATUS_STARTED_AT="$(date -u +%FT%TZ)"

# ─── Logging ─────────────────────────────────────────────────────
LOG_FILE="$STATUS_DIR/log"
log() {
    printf '[%s] %s\n' "$(date -Iseconds)" "$*" | tee -a "$LOG_FILE" >&2
}

# ─── status.json writer (atomic) ─────────────────────────────────
write_status() {
    local completed_at="${1:-$(date -u +%FT%TZ)}"
    cat > "$STATUS_DIR/status.json.tmp" <<EOF
{
  "phase": "$STATUS_PHASE",
  "outcome": "$STATUS_OUTCOME",
  "failure_reason": $([ -z "$STATUS_FAILURE_REASON" ] && echo null || printf '"%s"' "$STATUS_FAILURE_REASON"),
  "started_at": "$STATUS_STARTED_AT",
  "completed_at": "$completed_at",
  "pr_number": $STATUS_PR_NUMBER,
  "pr_url": $STATUS_PR_URL,
  "commits": $STATUS_COMMITS,
  "review_concerns_addressed": $STATUS_REVIEW_CONCERNS_ADDRESSED,
  "review_concerns_unresolved": $STATUS_REVIEW_CONCERNS_UNRESOLVED,
  "event_type": "$EVENT_TYPE",
  "repo": "$REPO",
  "number": $NUMBER
}
EOF
    mv "$STATUS_DIR/status.json.tmp" "$STATUS_DIR/status.json"
}

# ─── Global error trap: write a failure status before exit ──────
on_error() {
    local ec=$?
    [ "$ec" -eq 0 ] && return 0
    log "entrypoint failed at line ${1:-?} with exit code $ec (phase=$STATUS_PHASE)"
    if [ -z "$STATUS_FAILURE_REASON" ]; then
        STATUS_FAILURE_REASON="uncaught_error_at_line_${1:-unknown}_exit_${ec}"
    fi
    STATUS_OUTCOME="failure"
    write_status
}
trap 'on_error $LINENO' ERR
trap 'write_status' EXIT

# ─── Source lib files (review-gates provides gate functions) ────
# shellcheck source=/dev/null
. "$LIB_DIR/review-gates.sh"
# shellcheck source=/dev/null
. "$LIB_DIR/firewall.sh"

# ─── Main pipeline (filled in by later tasks) ───────────────────
log "claude-pal v0.2 entrypoint"
log "event=$EVENT_TYPE repo=$REPO number=$NUMBER"

STATUS_PHASE="applying_firewall"
apply_firewall "$PAL_HOME/allowlist.yaml" || {
    STATUS_FAILURE_REASON="firewall_apply_failed"
    exit 1
}

# shellcheck source=/dev/null
. "$LIB_DIR/worktree.sh"
# shellcheck source=/dev/null
. "$LIB_DIR/fetch-context.sh"
# shellcheck source=/dev/null
. "$LIB_DIR/claude-runner.sh"

STATUS_PHASE="cloning"
setup_worktree "$REPO" "$NUMBER" "$EVENT_TYPE" || {
    STATUS_FAILURE_REASON="worktree_setup_failed"
    exit 1
}

STATUS_PHASE="fetching_context"
if [ "$EVENT_TYPE" = "implement" ]; then
    set +e
    fetch_issue_context "$REPO" "$NUMBER"
    ctx_rc=$?
    set -e
    if [ "$ctx_rc" -eq 2 ]; then
        STATUS_FAILURE_REASON="no_plan_found"
        exit 1
    elif [ "$ctx_rc" -ne 0 ]; then
        STATUS_FAILURE_REASON="issue_fetch_failed"
        exit 1
    fi
elif [ "$EVENT_TYPE" = "revise" ]; then
    fetch_pr_context "$REPO" "$NUMBER" || {
        STATUS_FAILURE_REASON="pr_fetch_failed"
        exit 1
    }
else
    STATUS_FAILURE_REASON="unknown_event_type_${EVENT_TYPE}"
    exit 1
fi

if [ "$EVENT_TYPE" = "implement" ]; then
    STATUS_PHASE="adversarial_review"
    AGENT_ADVERSARIAL_PLAN_REVIEW="${AGENT_ADVERSARIAL_PLAN_REVIEW:-true}"
    AGENT_ALLOWED_TOOLS_TRIAGE="${AGENT_ALLOWED_TOOLS_TRIAGE:-Read,Glob,Grep,Bash(ls *),Bash(git log *),Bash(git diff *),Bash(git show *),Bash(echo *),Bash(printenv *)}"
    AGENT_MODEL_ADVERSARIAL_PLAN="${AGENT_MODEL_ADVERSARIAL_PLAN:-}"
    if ! run_adversarial_plan_review; then
        # review-gates.sh sets STATUS_OUTCOME and STATUS_FAILURE_REASON on failure modes
        exit 1
    fi
fi

STATUS_PHASE="implementing"
AGENT_ALLOWED_TOOLS_IMPLEMENT="${AGENT_ALLOWED_TOOLS_IMPLEMENT:-Read,Write,Edit,Glob,Grep,Bash(git *),Bash(ls *),Bash(cat *),Bash(echo *),Bash(printenv *),Bash(mkdir *),Bash(mv *),Bash(cp *),Bash(rm *),Bash(chmod *)}"
# Plus project-specific test and setup command tools:
if [ -n "${AGENT_TEST_COMMAND:-}" ]; then
    AGENT_ALLOWED_TOOLS_IMPLEMENT="${AGENT_ALLOWED_TOOLS_IMPLEMENT},Bash(${AGENT_TEST_COMMAND%% *} *)"
fi
if [ -n "${AGENT_TEST_SETUP_COMMAND:-}" ]; then
    AGENT_ALLOWED_TOOLS_IMPLEMENT="${AGENT_ALLOWED_TOOLS_IMPLEMENT},Bash(${AGENT_TEST_SETUP_COMMAND%% *} *)"
fi
AGENT_MODEL_IMPLEMENT="${AGENT_MODEL_IMPLEMENT:-}"

# Load appropriate prompt (implement for issue, revise for PR feedback)
if [ "$EVENT_TYPE" = "revise" ]; then
    impl_prompt=$(load_prompt "post-impl-retry")  # Reuse retry prompt for PR revise
    export AGENT_REVIEW_CONCERNS="${AGENT_REVIEW_FEEDBACK:-}"
else
    impl_prompt=$(load_prompt "implement")
fi

# Capture starting SHA to detect "no commits" case
start_sha=$(git -C "$WORKTREE_DIR" rev-parse HEAD)

# TDD retry loop: run implement; if tests fail, feed output back; up to N retries
AGENT_IMPL_MAX_RETRIES="${AGENT_IMPL_MAX_RETRIES:-2}"
retry=0
test_exit=0
while [ "$retry" -le "$AGENT_IMPL_MAX_RETRIES" ]; do
    log "implement: attempt $((retry+1)) of $((AGENT_IMPL_MAX_RETRIES+1))"
    result=$(run_claude "$impl_prompt" "$AGENT_ALLOWED_TOOLS_IMPLEMENT" "$AGENT_MODEL_IMPLEMENT")
    claude_output=$(parse_claude_output "$result")
    log "implement: claude output (first 500 chars): ${claude_output:0:500}"

    # If AGENT_TEST_COMMAND is set, run it; pass on green, feed failure back if red
    if [ -n "${AGENT_TEST_COMMAND:-}" ]; then
        STATUS_PHASE="testing"
        if [ -n "${AGENT_TEST_SETUP_COMMAND:-}" ]; then
            (cd "$WORKTREE_DIR" && eval "$AGENT_TEST_SETUP_COMMAND") >> "$LOG_FILE" 2>&1 || log "warn: test setup exited non-zero"
        fi

        set +e
        test_output=$(cd "$WORKTREE_DIR" && eval "$AGENT_TEST_COMMAND" 2>&1)
        test_exit=$?
        set -e

        if [ "$test_exit" -eq 0 ]; then
            log "implement: tests green on attempt $((retry+1))"
            break
        fi

        log "implement: tests failed on attempt $((retry+1)); feeding output back"
        # Extend the prompt with failing output for next iteration
        impl_prompt="$impl_prompt

## Previous attempt failed tests
\`\`\`
$(echo "$test_output" | tail -80)
\`\`\`

The code you just wrote did not pass tests. Investigate, fix, and try again."
        retry=$((retry+1))
    else
        log "implement: no AGENT_TEST_COMMAND set; accepting implement output as-is"
        break
    fi
done

if [ -n "${AGENT_TEST_COMMAND:-}" ] && [ "$test_exit" -ne 0 ]; then
    STATUS_FAILURE_REASON="tests_failed_after_${AGENT_IMPL_MAX_RETRIES}_retries"
    exit 1
fi

# Capture post-implement commits
end_sha=$(git -C "$WORKTREE_DIR" rev-parse HEAD)
if [ "$start_sha" = "$end_sha" ]; then
    STATUS_FAILURE_REASON="empty_diff"
    exit 1
fi

STATUS_COMMITS=$(git -C "$WORKTREE_DIR" log --format='%h' "${start_sha}..${end_sha}" | jq -R . | jq -sc . 2>/dev/null || echo '[]')
log "implement: captured $(git -C "$WORKTREE_DIR" rev-list --count "${start_sha}..${end_sha}") new commits"

STATUS_PHASE="post_impl_review"
AGENT_POST_IMPL_REVIEW="${AGENT_POST_IMPL_REVIEW:-true}"
AGENT_POST_IMPL_REVIEW_MAX_RETRIES="${AGENT_POST_IMPL_REVIEW_MAX_RETRIES:-1}"
AGENT_MODEL_POST_IMPL_REVIEW="${AGENT_MODEL_POST_IMPL_REVIEW:-}"
AGENT_MODEL_POST_IMPL_RETRY="${AGENT_MODEL_POST_IMPL_RETRY:-}"

if ! run_post_impl_review; then
    # review-gates.sh sets POST_IMPL_REVIEW_CONCERNS
    STATUS_PHASE="post_impl_retry"
    if ! handle_post_impl_review_retry "$AGENT_ALLOWED_TOOLS_IMPLEMENT"; then
        STATUS_OUTCOME="review_concerns_unresolved"
        STATUS_REVIEW_CONCERNS_UNRESOLVED=$(jq -Rs 'split("\n") | map(select(. != ""))' <<< "$POST_IMPL_REVIEW_CONCERNS")
        STATUS_FAILURE_REASON="post_impl_review_unresolved"
        exit 1
    else
        STATUS_REVIEW_CONCERNS_ADDRESSED=$(jq -Rs 'split("\n") | map(select(. != ""))' <<< "$REVIEW_RETRY_CONCERNS")
    fi
fi

STATUS_PHASE="pushing_pr"

# Refresh firewall rules for GitHub endpoints (IP rotation tolerance)
refresh_firewall_for github.com
refresh_firewall_for api.github.com

# Push branch
if ! git -C "$WORKTREE_DIR" push -u origin "$BRANCH_NAME"; then
    STATUS_FAILURE_REASON="git_push_failed"
    exit 1
fi
log "pushed branch $BRANCH_NAME"

if [ "$EVENT_TYPE" = "revise" ]; then
    # No new PR; the existing PR picks up the push
    STATUS_PR_NUMBER="$NUMBER"
    existing_pr_url=$(gh pr view "$NUMBER" --repo "$REPO" --json url --jq .url)
    STATUS_PR_URL="\"$existing_pr_url\""
    log "revise: new commits pushed to existing PR #$NUMBER"
else
    # Create PR
    local_pr_title="${AGENT_ISSUE_TITLE:-claude-pal implementation}"
    local_pr_body="Closes #${NUMBER}

Implemented by claude-pal based on the approved plan in issue #${NUMBER}."

    pr_create_output=$(gh pr create \
        --repo "$REPO" \
        --title "$local_pr_title" \
        --body "$local_pr_body" \
        --base main \
        --head "$BRANCH_NAME" 2>&1) || {
            STATUS_FAILURE_REASON="pr_create_failed: ${pr_create_output}"
            exit 1
        }
    STATUS_PR_URL="\"$(echo "$pr_create_output" | tail -1)\""
    STATUS_PR_NUMBER=$(echo "$STATUS_PR_URL" | grep -Eo '/pull/[0-9]+' | grep -Eo '[0-9]+')
    log "created PR at $STATUS_PR_URL"
fi

STATUS_OUTCOME="success"
STATUS_PHASE="complete"
