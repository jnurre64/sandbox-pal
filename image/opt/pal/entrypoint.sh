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
    AGENT_ALLOWED_TOOLS_TRIAGE="${AGENT_ALLOWED_TOOLS_TRIAGE:-Read,Glob,Grep,Bash(ls *),Bash(git log *),Bash(git diff *),Bash(git show *),Bash(echo *)}"
    AGENT_MODEL_ADVERSARIAL_PLAN="${AGENT_MODEL_ADVERSARIAL_PLAN:-}"
    if ! run_adversarial_plan_review; then
        # review-gates.sh sets STATUS_OUTCOME and STATUS_FAILURE_REASON on failure modes
        exit 1
    fi
fi

# (Tasks 2.7–2.11 add pipeline phases)

# Placeholder for now so the skeleton runs to completion
STATUS_OUTCOME="success"
STATUS_PHASE="complete"
