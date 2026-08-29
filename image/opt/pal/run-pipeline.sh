#!/usr/bin/env bash
# image/opt/pal/run-pipeline.sh
# shellcheck disable=SC1091  # Sourced lib files resolved at runtime
#
# Per-run pipeline. Invoked via `docker exec` against a long-running workspace
# container. Expects firewall already programmed by workspace-boot.sh.
#
# Usage: run-pipeline.sh <event-type> <repo> <number>
#   event-type in {implement, revise}
#   repo       = owner/name
#   number     = issue or PR number
#
# Reads from environment (set at exec time by lib/launcher.sh):
#   GH_TOKEN, RUN_ID, AGENT_TEST_COMMAND, AGENT_TEST_SETUP_COMMAND,
#   PAL_ALLOWLIST_EXTRA_DOMAINS, and any AGENT_* knob from .pal/config.env:
#   AGENT_ALLOWED_TOOLS_{TRIAGE,IMPLEMENT}, AGENT_MODEL[_<PHASE>],
#   AGENT_PROMPT_<PHASE>, AGENT_JSON_SCHEMA_<PHASE> ("" disables),
#   AGENT_BUDGET_USD[_<PHASE>], AGENT_EFFORT_<PHASE>, AGENT_PERMISSION_MODE_<PHASE>,
#   AGENT_MCP_CONFIG, AGENT_STRICT_MCP, AGENT_SESSION_PERSISTENCE, AGENT_ADD_DIRS,
#   AGENT_MEMORY_DIR, AGENT_MAX_TURNS, AGENT_TIMEOUT,
#   AGENT_ADVERSARIAL_PLAN_REVIEW, AGENT_POST_IMPL_REVIEW,
#   AGENT_POST_IMPL_REVIEW_MAX_RETRIES, AGENT_TEST_GATE_MAX_RETRIES.
# Phases: ADVERSARIAL_PLAN, IMPLEMENT, TEST_FIX, POST_IMPL_REVIEW, POST_IMPL_RETRY.

set -euo pipefail

# --- Args: <event_type> <repo> <number> -------------------------
EVENT_TYPE="${1:?Usage: run-pipeline.sh <event_type> <repo> <number>}"
REPO="${2:?}"
NUMBER="${3:?}"

# --- Paths -------------------------------------------------------
PAL_HOME="${PAL_HOME:-/opt/pal}"
# Tests run this script from the repo checkout: derive PAL_HOME from the
# script location when /opt/pal is not where we live.
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -d "$PAL_HOME/lib" ] || PAL_HOME="$_self_dir"
# shellcheck disable=SC2034  # PROMPTS_DIR is read by lib/claude-runner.sh
PROMPTS_DIR="$PAL_HOME/prompts"
LIB_DIR="$PAL_HOME/lib"
SCHEMAS_DIR="$PAL_HOME/schemas"

RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
STATUS_DIR="${PAL_STATUS_DIR:-/status/${RUN_ID}}"
WORKTREE_DIR="${WORKTREE_DIR:-/home/agent/work/${RUN_ID}}"
AGENT_DATA_DIR="${AGENT_DATA_DIR:-/home/agent/.agent-data}"

mkdir -p "$STATUS_DIR" "$WORKTREE_DIR" "$AGENT_DATA_DIR"

# --- Defaults for every knob the gates read (set -u safety) ------
AGENT_TEST_COMMAND="${AGENT_TEST_COMMAND:-}"
AGENT_TEST_SETUP_COMMAND="${AGENT_TEST_SETUP_COMMAND:-}"
AGENT_ADVERSARIAL_PLAN_REVIEW="${AGENT_ADVERSARIAL_PLAN_REVIEW:-true}"
AGENT_POST_IMPL_REVIEW="${AGENT_POST_IMPL_REVIEW:-true}"
AGENT_POST_IMPL_REVIEW_MAX_RETRIES="${AGENT_POST_IMPL_REVIEW_MAX_RETRIES:-3}"
AGENT_TEST_GATE_MAX_RETRIES="${AGENT_TEST_GATE_MAX_RETRIES:-2}"
AGENT_ALLOWED_TOOLS_TRIAGE="${AGENT_ALLOWED_TOOLS_TRIAGE:-Read,Glob,Grep,Bash(ls *),Bash(git log *),Bash(git diff *),Bash(git show *),Bash(echo *),Bash(printenv *)}"
AGENT_ALLOWED_TOOLS_IMPLEMENT="${AGENT_ALLOWED_TOOLS_IMPLEMENT:-Read,Write,Edit,Glob,Grep,Bash(git *),Bash(ls *),Bash(cat *),Bash(echo *),Bash(printenv *),Bash(mkdir *),Bash(mv *),Bash(cp *),Bash(rm *),Bash(chmod *)}"
AGENT_MODEL_ADVERSARIAL_PLAN="${AGENT_MODEL_ADVERSARIAL_PLAN:-}"
AGENT_MODEL_IMPLEMENT="${AGENT_MODEL_IMPLEMENT:-}"
AGENT_MODEL_TEST_FIX="${AGENT_MODEL_TEST_FIX:-}"
AGENT_MODEL_POST_IMPL_REVIEW="${AGENT_MODEL_POST_IMPL_REVIEW:-}"
AGENT_MODEL_POST_IMPL_RETRY="${AGENT_MODEL_POST_IMPL_RETRY:-}"
AGENT_PROMPT_ADVERSARIAL_PLAN="${AGENT_PROMPT_ADVERSARIAL_PLAN:-}"
AGENT_PROMPT_IMPLEMENT="${AGENT_PROMPT_IMPLEMENT:-}"
AGENT_PROMPT_TEST_FIX="${AGENT_PROMPT_TEST_FIX:-}"
AGENT_PROMPT_POST_IMPL_REVIEW="${AGENT_PROMPT_POST_IMPL_REVIEW:-}"
AGENT_PROMPT_POST_IMPL_RETRY="${AGENT_PROMPT_POST_IMPL_RETRY:-}"
# `-` not `:-`: an explicitly empty value disables that phase's schema.
AGENT_JSON_SCHEMA_ADVERSARIAL_PLAN="${AGENT_JSON_SCHEMA_ADVERSARIAL_PLAN-$SCHEMAS_DIR/adversarial-plan.json}"
AGENT_JSON_SCHEMA_POST_IMPL_REVIEW="${AGENT_JSON_SCHEMA_POST_IMPL_REVIEW-$SCHEMAS_DIR/post-impl-review.json}"
AGENT_JSON_SCHEMA_POST_IMPL_RETRY="${AGENT_JSON_SCHEMA_POST_IMPL_RETRY-$SCHEMAS_DIR/post-impl-retry.json}"
export AGENT_TEST_COMMAND AGENT_TEST_SETUP_COMMAND

# --- Status tracking (mutated across phases, emitted at end) ----
STATUS_PHASE="init"
STATUS_OUTCOME="failure"            # default; set to "success" on happy path
STATUS_FAILURE_REASON=""
STATUS_PR_NUMBER="null"
STATUS_PR_URL="null"
STATUS_COMMITS="[]"
STATUS_STARTED_AT="$(date -u +%FT%TZ)"

# --- Logging -----------------------------------------------------
LOG_FILE="$STATUS_DIR/log"
log() {
    printf '[%s] %s\n' "$(date -Iseconds)" "$*" | tee -a "$LOG_FILE" >&2
}

# --- status.json writer (atomic) ---------------------------------
# review_concerns_* are derived from the ledger (lib/launcher.sh renders
# review_concerns_unresolved in the async summary).
write_status() {
    local completed_at ledger_json='null' addressed='[]' unresolved='[]'
    local denials='[]' proposals='[]'
    completed_at="$(date -u +%FT%TZ)"
    local ledger="${WORKTREE_DIR}/.agent-data/review-ledger.json"
    if [ -f "$ledger" ] && jq -e . "$ledger" >/dev/null 2>&1; then
        ledger_json=$(jq -c . "$ledger")
        addressed=$(jq -c '[.findings[] | select(.status == "fixed") | "\(.id): \(.description)"]' "$ledger")
        unresolved=$(jq -c '[.findings[] | select(.severity == "blocking" and .status == "open") | "\(.id): \(.description)"]' "$ledger")
    fi
    local denials_file="${WORKTREE_DIR}/.agent-data/permission-denials.log"
    if [ -s "$denials_file" ]; then
        denials=$(jq -Rsc 'split("\n") | map(select(. != ""))' < "$denials_file")
    fi
    if [ -d "$STATUS_DIR/memory-proposals" ]; then
        proposals=$(find "$STATUS_DIR/memory-proposals" -maxdepth 1 -name '*.md' -printf '%f\n' | sort | jq -Rsc 'split("\n") | map(select(. != ""))')
    fi
    jq -n \
        --arg phase "$STATUS_PHASE" \
        --arg outcome "$STATUS_OUTCOME" \
        --arg failure_reason "$STATUS_FAILURE_REASON" \
        --arg started_at "$STATUS_STARTED_AT" \
        --arg completed_at "$completed_at" \
        --argjson pr_number "$STATUS_PR_NUMBER" \
        --argjson pr_url "$STATUS_PR_URL" \
        --argjson commits "$STATUS_COMMITS" \
        --argjson addressed "$addressed" \
        --argjson unresolved "$unresolved" \
        --argjson ledger "$ledger_json" \
        --argjson denials "$denials" \
        --argjson proposals "$proposals" \
        --arg event_type "$EVENT_TYPE" \
        --arg repo "$REPO" \
        --argjson number "$NUMBER" \
        '{phase: $phase, outcome: $outcome,
          failure_reason: (if $failure_reason == "" then null else $failure_reason end),
          started_at: $started_at, completed_at: $completed_at,
          pr_number: $pr_number, pr_url: $pr_url, commits: $commits,
          review_concerns_addressed: $addressed, review_concerns_unresolved: $unresolved,
          review_ledger: $ledger, permission_denials: $denials, memory_proposals: $proposals,
          event_type: $event_type, repo: $repo, number: $number}' \
        > "$STATUS_DIR/status.json.tmp"
    mv "$STATUS_DIR/status.json.tmp" "$STATUS_DIR/status.json"
}

# --- Memory proposals: copy out of the worktree before it is wiped ----
harvest_memory_proposals() {
    local src="${WORKTREE_DIR}/.agent-data/memory-proposals"
    [ -d "$src" ] || return 0
    if find "$src" -maxdepth 1 -name '*.md' | grep -q .; then
        mkdir -p "$STATUS_DIR/memory-proposals"
        cp "$src"/*.md "$STATUS_DIR/memory-proposals/"
        log "memory: $(find "$src" -maxdepth 1 -name '*.md' | wc -l) proposal(s) copied to $STATUS_DIR/memory-proposals/"
    fi
}

# --- Global error trap: write a failure status before exit ------
on_error() {
    local ec=$?
    [ "$ec" -eq 0 ] && return 0
    log "run-pipeline failed at line ${1:-?} with exit code $ec (phase=$STATUS_PHASE)"
    if [ -z "$STATUS_FAILURE_REASON" ]; then
        STATUS_FAILURE_REASON="uncaught_error_at_line_${1:-unknown}_exit_${ec}"
    fi
    STATUS_OUTCOME="failure"
}
trap 'on_error $LINENO' ERR

# --- Exit trap: harvest, write status, wipe per-run transient state --
cleanup_on_exit() {
    harvest_memory_proposals
    write_status
    local wt_slug="${WORKTREE_DIR//\//-}"
    rm -rf "$WORKTREE_DIR" "/home/agent/.claude/projects/${wt_slug}" 2>/dev/null || true
}
trap 'cleanup_on_exit' EXIT

# --- Source lib files ------------------------------------------
. "$LIB_DIR/claude-runner.sh"
. "$LIB_DIR/review-gates.sh"
. "$LIB_DIR/firewall.sh"
. "$LIB_DIR/worktree.sh"
. "$LIB_DIR/fetch-context.sh"

# --- Main pipeline ----------------------------------------------
log "sandbox-pal run-pipeline"
log "event=$EVENT_TYPE repo=$REPO number=$NUMBER run_id=$RUN_ID"
if [ -n "${AGENT_IMPL_MAX_RETRIES:-}" ]; then
    log "WARN: AGENT_IMPL_MAX_RETRIES is no longer used; the pre-PR test gate uses AGENT_TEST_GATE_MAX_RETRIES (default 2)"
fi

if [ -n "${PAL_ALLOWLIST_EXTRA_DOMAINS:-}" ]; then
    STATUS_PHASE="refreshing_firewall"
    for d in $(printf '%s\n' "$PAL_ALLOWLIST_EXTRA_DOMAINS" | tr ',' ' '); do
        [ -z "$d" ] && continue
        refresh_firewall_for "$d" || log "warn: firewall refresh failed for $d"
    done
fi

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
    if ! run_adversarial_plan_review; then
        # review-gates.sh set STATUS_OUTCOME / STATUS_FAILURE_REASON
        exit 1
    fi
fi

# --- Implement phase ---------------------------------------------
STATUS_PHASE="implementing"
if [ -n "$AGENT_TEST_COMMAND" ]; then
    AGENT_ALLOWED_TOOLS_IMPLEMENT="${AGENT_ALLOWED_TOOLS_IMPLEMENT},Bash(${AGENT_TEST_COMMAND%% *} *)"
fi
if [ -n "$AGENT_TEST_SETUP_COMMAND" ]; then
    AGENT_ALLOWED_TOOLS_IMPLEMENT="${AGENT_ALLOWED_TOOLS_IMPLEMENT},Bash(${AGENT_TEST_SETUP_COMMAND%% *} *)"
fi

if [ "$EVENT_TYPE" = "revise" ]; then
    # Reuse the retry prompt for PR feedback; feed the feedback as concerns.
    impl_prompt=$(load_prompt "post-impl-retry" "$AGENT_PROMPT_POST_IMPL_RETRY")
    export AGENT_REVIEW_CONCERNS="${AGENT_REVIEW_FEEDBACK:-}"
    export AGENT_REVIEW_LEDGER='{"cycles":0,"findings":[]}'
else
    impl_prompt=$(load_prompt "implement" "$AGENT_PROMPT_IMPLEMENT")
fi

start_sha=$(git -C "$WORKTREE_DIR" rev-parse HEAD)

set_heartbeat "implement"
result=$(run_claude "$impl_prompt" "$AGENT_ALLOWED_TOOLS_IMPLEMENT" "$AGENT_MODEL_IMPLEMENT" "" "IMPLEMENT")
log_permission_denials "$result" "implement"
claude_output=$(parse_claude_output "$result")
log "implement: claude output (first 500 chars): ${claude_output:0:500}"
if [ "$(classify_claude_result "$result")" = "fail_fast" ]; then
    STATUS_FAILURE_REASON="implement_api_error"
    gh issue comment "$NUMBER" --repo "$REPO" \
        --body "Agent implementation phase hit an API error (${claude_output}). Re-run \`/pal-implement\` once the API issue is resolved." 2>/dev/null || true
    exit 1
fi

end_sha=$(git -C "$WORKTREE_DIR" rev-parse HEAD)
if [ "$start_sha" = "$end_sha" ]; then
    STATUS_FAILURE_REASON="empty_diff"
    exit 1
fi
log "implement: captured $(git -C "$WORKTREE_DIR" rev-list --count "${start_sha}..${end_sha}") new commits"

# Preserve finished work BEFORE any gate can fail.
refresh_firewall_for github.com
refresh_firewall_for api.github.com
preserve_branch || true

# --- Pre-PR test gate (bounded fix sessions) ---------------------
STATUS_PHASE="testing"
if ! run_test_gate "$AGENT_ALLOWED_TOOLS_IMPLEMENT" "${AGENT_ISSUE_TITLE:-}"; then
    exit 1
fi

# --- Post-implementation review loop -----------------------------
STATUS_PHASE="post_impl_review"
review_rc=0
run_post_impl_review_loop "$AGENT_ALLOWED_TOOLS_IMPLEMENT" || review_rc=$?
if [ "$review_rc" -eq 1 ]; then
    exit 1
fi

end_sha=$(git -C "$WORKTREE_DIR" rev-parse HEAD)
STATUS_COMMITS=$(git -C "$WORKTREE_DIR" log --format='%h' "${start_sha}..${end_sha}" | jq -R . | jq -sc . 2>/dev/null || echo '[]')

# --- Push + PR ----------------------------------------------------
STATUS_PHASE="pushing_pr"
refresh_firewall_for github.com
refresh_firewall_for api.github.com

if ! git -C "$WORKTREE_DIR" push -u origin "$BRANCH_NAME"; then
    STATUS_FAILURE_REASON="git_push_failed"
    exit 1
fi
log "pushed branch $BRANCH_NAME"

ledger_summary=""
unresolved_header=""
if [ -f "${WORKTREE_DIR}/.agent-data/review-ledger.json" ]; then
    # shellcheck disable=SC2034  # read by _ledger_pr_summary / _ledger_outstanding_summary (review-gates.sh)
    LEDGER_FILE="${WORKTREE_DIR}/.agent-data/review-ledger.json"
    ledger_summary="
### Adversarial Review Ledger

$(_ledger_pr_summary)
"
    if [ "$review_rc" -eq 2 ]; then
        unresolved_header="## ⚠ Review Unresolved

The adversarial review loop hit its retry cap with blocking findings still open. Do not merge before arbitrating these:

$(_ledger_outstanding_summary)

---
"
    fi
fi

memory_section=""
proposals_dir="${WORKTREE_DIR}/.agent-data/memory-proposals"
if [ -d "$proposals_dir" ] && find "$proposals_dir" -maxdepth 1 -name '*.md' | grep -q .; then
    memory_section="
<details><summary>### Memory proposals</summary>

The agent proposed durable learnings for the host memory. Triage with \`/pal-memory ${RUN_ID}\`.

$(for f in "$proposals_dir"/*.md; do
    n=$(sed -n 's/^name:[[:space:]]*//p' "$f" | head -1)
    d=$(sed -n 's/^description:[[:space:]]*//p' "$f" | head -1)
    printf -- '- **%s** — %s\n' "${n:-$(basename "$f")}" "${d:-}"
done)
</details>
"
fi

if [ "$EVENT_TYPE" = "revise" ]; then
    STATUS_PR_NUMBER="$NUMBER"
    existing_pr_url=$(gh pr view "$NUMBER" --repo "$REPO" --json url --jq .url)
    STATUS_PR_URL="\"$existing_pr_url\""
    log "revise: new commits pushed to existing PR #$NUMBER"
else
    pr_title="${AGENT_ISSUE_TITLE:-sandbox-pal implementation}"
    commit_log=$(git -C "$WORKTREE_DIR" log --format="- %s" "origin/main..HEAD" 2>/dev/null | head -20)
    pr_body="${unresolved_header}## Automated PR for #${NUMBER}

Implemented by sandbox-pal based on the approved plan in issue #${NUMBER}.

${claude_output:0:2000}
${ledger_summary}$(denials_report_section)${memory_section}
### Commits
${commit_log}

Closes #${NUMBER}"

    pr_create_output=$(gh pr create \
        --repo "$REPO" \
        --title "$pr_title" \
        --body "$pr_body" \
        --base main \
        --head "$BRANCH_NAME" 2>&1) || {
            STATUS_FAILURE_REASON="pr_create_failed: ${pr_create_output}"
            exit 1
        }
    STATUS_PR_URL="\"$(echo "$pr_create_output" | tail -1)\""
    STATUS_PR_NUMBER=$(echo "$STATUS_PR_URL" | grep -Eo '/pull/[0-9]+' | grep -Eo '[0-9]+')
    log "created PR at $STATUS_PR_URL"
fi

if [ "$review_rc" -eq 2 ]; then
    STATUS_OUTCOME="review_concerns_unresolved"
    STATUS_FAILURE_REASON="post_impl_review_unresolved"
    STATUS_PHASE="complete"
    exit 1
fi

STATUS_OUTCOME="success"
STATUS_PHASE="complete"
