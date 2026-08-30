#!/usr/bin/env bats
# tests/test_container_lib.bats
# Unit tests for image/opt/pal/lib/claude-runner.sh and review-gates.sh,
# run on the host with a fake `claude` on PATH.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'test_helper/container-lib'

setup()    { container_lib_setup; }
teardown() { container_lib_teardown; }

@test "fixture: fake claude records argv and replays the envelope" {
    fake_envelope '{"result":"hello","subtype":"success","is_error":false}'
    run claude -p "prompt" --output-format json
    assert_success
    assert_output --partial '"result":"hello"'
    run cat "$FAKE_CLAUDE_ARGS"
    assert_line --index 0 "-p"
    assert_line --index 1 "prompt"
}

# ── parse / classify ────────────────────────────────────────────

@test "REGRESSION #102: API-error envelope with subtype=success is reported as an API error" {
    container_lib_source
    env='{"is_error":true,"subtype":"success","terminal_reason":"api_error","api_error_status":529,"result":"Overloaded"}'
    run parse_claude_output "$env"
    assert_output "Agent phase failed: API error — api_error — 529 — Overloaded"
    run classify_claude_result "$env"
    assert_output "fail_fast"
}

@test "classify: error_max_turns is recoverable" {
    container_lib_source
    run classify_claude_result '{"is_error":false,"subtype":"error_max_turns"}'
    assert_output "recoverable"
    run parse_claude_output '{"is_error":false,"subtype":"error_max_turns"}'
    assert_output "Agent stopped: error_max_turns"
}

@test "classify: synthetic timeout envelope (.error) is recoverable" {
    container_lib_source
    run classify_claude_result '{"result":"claude timed out or errored (exit code 124)","error":true}'
    assert_output "recoverable"
}

@test "classify: normal envelope is ok and parse returns .result" {
    container_lib_source
    run classify_claude_result '{"is_error":false,"subtype":"success","result":"done"}'
    assert_output "ok"
    run parse_claude_output '{"is_error":false,"subtype":"success","result":"done"}'
    assert_output "done"
}

# ── redaction ───────────────────────────────────────────────────

@test "REGRESSION #103: redact_secrets scrubs env secrets and token-shaped strings" {
    # Two passes: token-shaped patterns first (github_pat_/gh?_ /Authorization),
    # then the value of every exported *TOKEN*/*SECRET*/... variable >= 8 chars.
    export GH_TOKEN="not-token-shaped-but-secret-value-1234"
    run bash -c ". \"$LIB_DIR/claude-runner.sh\"; printf 'token=%s and ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ12 and Authorization: Bearer abc.def\n' \"\$GH_TOKEN\" | redact_secrets"
    assert_output "token=[REDACTED:GH_TOKEN] and [REDACTED_TOKEN] and Authorization: Bearer [REDACTED]"
}

@test "REGRESSION #103: run_claude redacts the envelope and the stderr log" {
    container_lib_source
    export GH_TOKEN="not-token-shaped-but-secret-value-1234"
    fake_envelope "{\"result\":\"leaked $GH_TOKEN here\",\"subtype\":\"success\",\"is_error\":false}"
    export FAKE_CLAUDE_STDERR="stderr says $GH_TOKEN"
    run run_claude "prompt" "Read" "" "" "IMPLEMENT"
    assert_success
    refute_output --partial "$GH_TOKEN"
    assert_output --partial "[REDACTED:GH_TOKEN]"
    run cat "$STATUS_DIR"/claude-stderr-*.log
    refute_output --partial "$GH_TOKEN"
    assert_output --partial "[REDACTED:GH_TOKEN]"
    run cat "$STATUS_DIR"/claude-stdout-*.log
    refute_output --partial "$GH_TOKEN"
}

# ── permission denials / structured output ──────────────────────

@test "REGRESSION #105: permission denials are logged per phase and rendered for the PR body" {
    container_lib_source
    env='{"result":"x","subtype":"success","is_error":false,"permission_denials":[{"tool_name":"Bash","tool_input":{"command":"npm test"}},{"tool_name":"Edit","tool_input":{"file_path":"src/a.js"}}]}'
    run extract_permission_denials "$env"
    assert_line --index 0 "Bash: npm test"
    assert_line --index 1 "Edit: src/a.js"
    log_permission_denials "$env" "implement"
    run cat "$WORKTREE_DIR/.agent-data/permission-denials.log"
    assert_line --index 0 "[implement] Bash: npm test"
    run denials_report_section
    assert_output --partial "### Permission Denials"
    assert_output --partial "[implement] Edit: src/a.js"
    assert_output --partial ".pal/config.env"
}

@test "denials: no section when nothing was denied" {
    container_lib_source
    run denials_report_section
    assert_output ""
}

@test "structured output: get_structured_output prefers .structured_output" {
    container_lib_source
    run get_structured_output '{"result":"Here is my answer: {\"action\":\"nope\"}","structured_output":{"action":"approved"}}'
    assert_output '{"action":"approved"}'
    run get_structured_output '{"result":"plain"}'
    assert_output ""
}

# ── run_claude flag surface ─────────────────────────────────────

_args() { cat "$FAKE_CLAUDE_ARGS"; }

@test "flags: defaults — json output, disable-slash-commands, no-session-persistence, no budget/effort/schema" {
    container_lib_source
    run run_claude "p" "Read" "" "" "IMPLEMENT"
    assert_success
    run _args
    assert_line "--output-format"
    assert_line "--disable-slash-commands"
    assert_line "--no-session-persistence"
    refute_line "--max-budget-usd"
    refute_line "--effort"
    refute_line "--permission-mode"
    refute_line "--json-schema"
    refute_line "--strict-mcp-config"
}

@test "flags: per-phase budget, effort, permission mode" {
    container_lib_source
    export AGENT_BUDGET_USD_IMPLEMENT=8 AGENT_EFFORT_IMPLEMENT=xhigh AGENT_PERMISSION_MODE_IMPLEMENT=dontAsk
    run run_claude "p" "Read" "" "" "IMPLEMENT"
    run _args
    assert_line "--max-budget-usd"; assert_line "8"
    assert_line "--effort";         assert_line "xhigh"
    assert_line "--permission-mode"; assert_line "dontAsk"
}

@test "flags: AGENT_BUDGET_USD is the global fallback; per-phase wins" {
    container_lib_source
    export AGENT_BUDGET_USD=42 AGENT_BUDGET_USD_POST_IMPL_REVIEW=3
    run run_claude "p" "Read" "" "" "IMPLEMENT";        run _args; assert_line "42"
    run run_claude "p" "Read" "" "" "POST_IMPL_REVIEW"; run _args; assert_line "3"; refute_line "42"
}

@test "flags: AGENT_MCP_CONFIG adds --mcp-config + --strict-mcp-config; AGENT_STRICT_MCP=true adds strict alone" {
    container_lib_source
    export AGENT_MCP_CONFIG="$T/mcp.json"
    run run_claude "p" "Read"; run _args
    assert_line "--mcp-config"; assert_line "$T/mcp.json"; assert_line "--strict-mcp-config"
    unset AGENT_MCP_CONFIG; export AGENT_STRICT_MCP=true
    run run_claude "p" "Read"; run _args
    refute_line "--mcp-config"; assert_line "--strict-mcp-config"
}

@test "flags: AGENT_SESSION_PERSISTENCE=true drops --no-session-persistence" {
    container_lib_source
    export AGENT_SESSION_PERSISTENCE=true
    run run_claude "p" "Read"; run _args
    refute_line "--no-session-persistence"
}

@test "flags: AGENT_ADD_DIRS and AGENT_MEMORY_DIR become --add-dir; memory index is appended to the system prompt" {
    container_lib_source
    mkdir -p "$T/extra" "$T/mem"
    printf '# Memory Index\n- [x](x.md) — hook\n' > "$T/mem/MEMORY.md"
    export AGENT_ADD_DIRS="$T/extra" AGENT_MEMORY_DIR="$T/mem"
    run run_claude "p" "Read"; run _args
    assert_line "--add-dir"; assert_line "$T/extra"; assert_line "$T/mem"
    assert_line "--append-system-prompt"
    assert_output --partial "Shared Project Memory"
    assert_output --partial "- [x](x.md) — hook"
    assert_output --partial "read-only"
}

@test "flags: --json-schema carries the compact schema when the file exists; missing file warns and continues" {
    container_lib_source
    printf '{ "type": "object",\n "required": ["action"] }\n' > "$T/s.json"
    run run_claude "p" "Read" "" "$T/s.json" "POST_IMPL_REVIEW"
    assert_success
    run _args
    assert_line "--json-schema"
    assert_line '{"type":"object","required":["action"]}'
    run run_claude "p" "Read" "" "$T/missing.json" "POST_IMPL_REVIEW"
    assert_success
    run _args; refute_line "--json-schema"
    run cat "$LOG_FILE"; assert_output --partial "schema file not found"
}

@test "flags: model override and AGENT_MODEL fallback" {
    container_lib_source
    export AGENT_MODEL=claude-sonnet-5
    run run_claude "p" "Read"; run _args; assert_line "claude-sonnet-5"
    run run_claude "p" "Read" "claude-opus-5"; run _args; assert_line "claude-opus-5"; refute_line "claude-sonnet-5"
}

@test "flags: max-turns and disallowed tools defaults" {
    container_lib_source
    run run_claude "p" "Read"; run _args
    assert_line "--max-turns"; assert_line "50"
    assert_line "--disallowedTools"; assert_line "mcp__github__*"
}

@test "load_prompt: built-in, worktree-relative override, absolute override, missing" {
    container_lib_source
    run load_prompt "implement"
    assert_success
    assert_output --partial "approved plan"
    mkdir -p "$WORKTREE_DIR/.pal/prompts"
    echo "custom rel" > "$WORKTREE_DIR/.pal/prompts/x.md"
    run load_prompt "implement" ".pal/prompts/x.md"; assert_output "custom rel"
    echo "custom abs" > "$T/abs.md"
    run load_prompt "implement" "$T/abs.md"; assert_output "custom abs"
    run load_prompt "does-not-exist"
    assert_failure
}

@test "shims: set_heartbeat is a no-op; preserve_branch pushes BRANCH_NAME and tolerates failure" {
    container_lib_source
    run set_heartbeat "anything"; assert_success; assert_output ""
    # no origin remote → push fails → returns 1, logs a WARN, does not abort
    run preserve_branch
    assert_failure
    run cat "$LOG_FILE"; assert_output --partial "WARN: could not push agent/issue-42"
    bare="$T/origin.git"; git init -q --bare "$bare"
    git -C "$WORKTREE_DIR" remote add origin "$bare"
    git -C "$WORKTREE_DIR" checkout -q -b "$BRANCH_NAME"   # a real worktree lives on BRANCH_NAME
    run preserve_branch
    assert_success
    run git -C "$bare" branch --list "agent/issue-42"; assert_output --partial "agent/issue-42"
}

# ── schemas ─────────────────────────────────────────────────────

@test "schemas: the three phase schemas are valid JSON and match upstream 04cef68 byte-for-byte" {
    for s in adversarial-plan post-impl-review post-impl-retry; do
        run jq -e '.required | index("action")' "$REPO_ROOT/image/opt/pal/schemas/$s.json"
        assert_success
    done
    if [ -d "$HOME/repos/sandbox-pal-action/.git" ]; then
        for s in adversarial-plan post-impl-review post-impl-retry; do
            run diff <(git -C "$HOME/repos/sandbox-pal-action" show "04cef68:schemas/$s.json") "$REPO_ROOT/image/opt/pal/schemas/$s.json"
            assert_success
        done
    fi
}

# ── review gates ────────────────────────────────────────────────

_gate_env() {
    export AGENT_ADVERSARIAL_PLAN_REVIEW=true AGENT_POST_IMPL_REVIEW=true
    export AGENT_POST_IMPL_REVIEW_MAX_RETRIES=3 AGENT_TEST_GATE_MAX_RETRIES=2
    export AGENT_TEST_COMMAND="" AGENT_TEST_SETUP_COMMAND=""
    export AGENT_ALLOWED_TOOLS_TRIAGE="Read"
    export AGENT_MODEL_ADVERSARIAL_PLAN="" AGENT_MODEL_POST_IMPL_REVIEW="" AGENT_MODEL_POST_IMPL_RETRY="" AGENT_MODEL_TEST_FIX=""
    export AGENT_PROMPT_ADVERSARIAL_PLAN="" AGENT_PROMPT_POST_IMPL_REVIEW="" AGENT_PROMPT_POST_IMPL_RETRY="" AGENT_PROMPT_TEST_FIX=""
    export AGENT_JSON_SCHEMA_ADVERSARIAL_PLAN="" AGENT_JSON_SCHEMA_POST_IMPL_REVIEW="" AGENT_JSON_SCHEMA_POST_IMPL_RETRY=""
    export AGENT_PLAN_CONTENT="plan" AGENT_ISSUE_TITLE="t" AGENT_ISSUE_BODY="b"
    STATUS_OUTCOME="failure"; STATUS_FAILURE_REASON=""
}

_review() { # structured review envelope
    printf '{"result":"","subtype":"success","is_error":false,"structured_output":%s}' "$1"
}

@test "Gate A: approved / needs_clarification / unparseable set the right STATUS_* (no labels)" {
    _gate_env; container_lib_source
    fake_envelope "$(_review '{"action":"approved"}')"
    run run_adversarial_plan_review; assert_success

    fake_envelope '{"result":"{\"action\":\"needs_clarification\",\"questions\":[\"why?\"]}","subtype":"success","is_error":false}'
    run_adversarial_plan_review && fail "expected 1"
    assert_equal "$STATUS_OUTCOME" "clarification_needed"
    run cat "$FAKE_GH_LOG"; assert_output --partial "Clarification Needed"; assert_output --partial "- why?"

    STATUS_OUTCOME=failure; STATUS_FAILURE_REASON=""
    fake_envelope '{"result":"no json here","subtype":"success","is_error":false}'
    run_adversarial_plan_review && fail "expected 1"
    assert_equal "$STATUS_FAILURE_REASON" "adversarial_review_could_not_parse"
    run cat "$FAKE_GH_LOG"; refute_output --partial "agent:"
}

@test "REGRESSION #101: a ledger stamped with another issue is discarded on init" {
    _gate_env; container_lib_source
    mkdir -p "$WORKTREE_DIR/.agent-data"
    echo '{"issue":99,"cycles":4,"findings":[{"id":"F1","severity":"blocking","description":"old","status":"open","justification":""}]}' > "$WORKTREE_DIR/.agent-data/review-ledger.json"
    _ledger_init
    run jq -r '.issue, .cycles, (.findings|length)' "$LEDGER_FILE"
    assert_line --index 0 "42"; assert_line --index 1 "0"; assert_line --index 2 "0"
    run cat "$LOG_FILE"; assert_output --partial "Discarding stale review ledger (stamped: 99"
}

@test "review loop: concerns → retry fixes → approved returns 0 with cycles=2" {
    _gate_env; container_lib_source
    fake_claude_enqueue "$(_review '{"action":"concerns","verified_fixed":[],"reopened":[],"findings":[{"severity":"blocking","description":"missing test"}]}')"
    fake_claude_enqueue "$(_review '{"action":"addressed","dispositions":[{"id":"F1","status":"fixed","note":"added"}]}')" \
        'echo fix > fix.txt; git add fix.txt; git commit -q -m "fix(review): add test"'
    fake_claude_enqueue "$(_review '{"action":"approved","verified_fixed":["F1"],"reopened":[],"findings":[]}')"
    run_post_impl_review_loop "Read,Edit"
    rc=$?
    assert_equal "$rc" 0
    run jq -r '.cycles, .findings[0].status' "$LEDGER_FILE"
    assert_line --index 0 "2"; assert_line --index 1 "fixed"
    run git -C "$WORKTREE_DIR" log --format=%s
    assert_line --partial "review ledger"
}

@test "review loop: cap reached with blocking findings open returns 2" {
    _gate_env; container_lib_source
    export AGENT_POST_IMPL_REVIEW_MAX_RETRIES=1
    fake_claude_enqueue "$(_review '{"action":"concerns","verified_fixed":[],"reopened":[],"findings":[{"severity":"blocking","description":"bad"}]}')"
    fake_claude_enqueue "$(_review '{"action":"addressed","dispositions":[]}')"
    fake_claude_enqueue "$(_review '{"action":"concerns","verified_fixed":[],"reopened":[],"findings":[]}')"
    run_post_impl_review_loop "Read,Edit" && fail "expected 2"
    rc=$?
    assert_equal "$rc" 2
    run _ledger_outstanding_summary; assert_output --partial "F1"
}

@test "review loop: API error in the review pass is fail-fast (returns 1, status set, branch preserve attempted)" {
    _gate_env; container_lib_source
    fake_envelope '{"is_error":true,"subtype":"success","terminal_reason":"api_error","api_error_status":529,"result":"Overloaded"}'
    run_post_impl_review_loop "Read,Edit" && fail "expected 1"
    assert_equal "$?" 1
    assert_equal "$STATUS_FAILURE_REASON" "post_impl_review_api_error"
    run cat "$FAKE_GH_LOG"; assert_output --partial "API error"; assert_output --partial "/pal-implement"
}

@test "review: unparseable output sets post_impl_review_could_not_parse and mentions the schema when one is configured" {
    _gate_env; container_lib_source
    export AGENT_JSON_SCHEMA_POST_IMPL_REVIEW="/opt/pal/schemas/post-impl-review.json"
    fake_envelope '{"result":"narrative only","subtype":"success","is_error":false}'
    run_post_impl_review_loop "Read" && fail "expected 1"
    assert_equal "$STATUS_FAILURE_REASON" "post_impl_review_could_not_parse"
    run cat "$FAKE_GH_LOG"; assert_output --partial "schema/prompt mismatch"
}

@test "review: legacy {\"concerns\":[...]} response maps to blocking findings" {
    _gate_env; container_lib_source
    export AGENT_POST_IMPL_REVIEW_MAX_RETRIES=0
    fake_envelope '{"result":"{\"action\":\"concerns\",\"concerns\":[\"legacy one\"]}","subtype":"success","is_error":false}'
    run_post_impl_review_loop "Read" && fail "expected 2"
    run jq -r '.findings[0].severity + " " + .findings[0].description' "$LEDGER_FILE"
    assert_output "blocking legacy one"
}

@test "test gate: green passes; red → fix commits → green passes; no-commit fix session stops early" {
    _gate_env; container_lib_source
    export AGENT_TEST_COMMAND="test -f $WORKTREE_DIR/green"
    touch "$WORKTREE_DIR/green"
    run run_test_gate "Read,Edit" "title"; assert_success

    rm "$WORKTREE_DIR/green"
    fake_claude_enqueue '{"result":"fixed","subtype":"success","is_error":false}' 'touch green; git add -f green; git commit -q -m "fix(tests): green"'
    run_test_gate "Read,Edit" "title"
    assert_equal "$?" 0

    rm "$WORKTREE_DIR/green"; git -C "$WORKTREE_DIR" commit -q -am "remove green"
    fake_envelope '{"result":"cannot fix","subtype":"success","is_error":false}'
    run_test_gate "Read,Edit" "title" && fail "expected 1"
    assert_equal "$STATUS_FAILURE_REASON" "tests_failed_after_1_fix_sessions"
    run cat "$LOG_FILE"; assert_output --partial "made no commits"
    run cat "$FAKE_GH_LOG"; assert_output --partial "Test Failure (Pre-PR Gate)"; refute_output --partial "agent:failed"
}

# ── prompts ─────────────────────────────────────────────────────

@test "prompts: vendored files match upstream 04cef68 except the enumerated local lines" {
    P="$REPO_ROOT/image/opt/pal/prompts"
    [ -f "$P/test-fix.md" ]
    for f in implement post-impl-retry test-fix; do
        run grep -c "memory-proposals/" "$P/$f.md"; assert_output "1"
    done
    run grep -c "memory-proposals/" "$P/post-impl-review.md"; assert_output "0"
    run head -1 "$P/implement.md"
    assert_output --partial "sandbox-pal container"
    run grep -c "Prior Work on This Branch" "$P/implement.md"; assert_output "1"
    run grep -c "You cannot write anything under .claude/" "$P/implement.md"; assert_output "1"
    run grep -c '"action": "addressed"' "$P/post-impl-retry.md"; assert_output "1"
    run grep -c "AGENT_REVIEW_LEDGER" "$P/post-impl-review.md"; assert_output "1"
    if [ -d "$HOME/repos/sandbox-pal-action/.git" ]; then
        # Exact diff budget: adversarial-plan identical; post-impl-review identical;
        # the other three differ only by the appended paragraph (and implement's intro).
        run diff <(git -C "$HOME/repos/sandbox-pal-action" show 04cef68:prompts/adversarial-plan.md) "$P/adversarial-plan.md"; assert_success
        run diff <(git -C "$HOME/repos/sandbox-pal-action" show 04cef68:prompts/post-impl-review.md) "$P/post-impl-review.md"; assert_success
    fi
}

# ── worktree ────────────────────────────────────────────────────

@test "worktree: resumes from origin/<branch> when it exists, else branches from origin/main; excludes .agent-data" {
    # shellcheck disable=SC1091
    . "$LIB_DIR/worktree.sh"
    origin="$T/origin.git"; git init -q --bare -b main "$origin"
    seed="$T/seed"; git clone -q "$origin" "$seed"
    git -C "$seed" -c user.email=t@e -c user.name=t commit -q --allow-empty -m base
    git -C "$seed" push -q origin HEAD:main
    # gh stub: `gh repo clone <repo> <dir>` → git clone from $origin
    cat > "$T/bin/gh" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$FAKE_GH_LOG"
case "\$1 \$2" in
  "repo clone") git clone -q "$origin" "\$4" ;;
esac
exit 0
FAKE
    chmod +x "$T/bin/gh"
    export HOME="$T/home"; mkdir -p "$HOME"
    export WORKTREE_DIR="$T/wt1"; export GH_TOKEN=x
    setup_worktree "owner/repo" 42 implement
    assert_equal "$BRANCH_NAME" "agent/issue-42"
    run git -C "$WORKTREE_DIR" log --oneline; assert_line --partial "base"
    run cat "$(git -C "$WORKTREE_DIR" rev-parse --git-path info/exclude)"; assert_line ".agent-data/"

    # push a commit on the branch, wipe, re-setup → resumes with that commit
    git -C "$WORKTREE_DIR" -c user.email=t@e -c user.name=t commit -q --allow-empty -m "prior work"
    git -C "$WORKTREE_DIR" push -q origin agent/issue-42
    git -C "$HOME/.cache/repos/owner/repo" worktree remove --force "$WORKTREE_DIR"
    export WORKTREE_DIR="$T/wt2"
    setup_worktree "owner/repo" 42 implement
    run git -C "$WORKTREE_DIR" log --oneline; assert_line --partial "prior work"
    run cat "$LOG_FILE"; assert_output --partial "resuming from origin/agent/issue-42"
}

# ── rules staging (upstream #104) ───────────────────────────────

_seed_rules_file() {
    # $1 = name, $2 = content. Commits into the fixture worktree.
    mkdir -p "$WORKTREE_DIR/.claude/rules"
    printf '%s\n' "$2" > "$WORKTREE_DIR/.claude/rules/$1"
    git -C "$WORKTREE_DIR" add -A
    git -C "$WORKTREE_DIR" commit -q -m "add rules $1"
}

@test "rules: stage_rules_files copies .claude/rules/*.md into .agent-data/rules/" {
    container_lib_source
    _seed_rules_file style.md "original rule text"
    stage_rules_files
    [ -f "$WORKTREE_DIR/.agent-data/rules/style.md" ]
    run cat "$WORKTREE_DIR/.agent-data/rules/style.md"; assert_output "original rule text"
    run cat "$LOG_FILE"; assert_output --partial "Staged 1 rules file(s)"
}

@test "rules: stage_rules_files is a no-op when the repo has no .claude/rules directory" {
    container_lib_source
    stage_rules_files
    [ ! -d "$WORKTREE_DIR/.agent-data/rules" ]
}

@test "rules: apply_rules_files copies back a modified staged file and commits it" {
    container_lib_source
    _seed_rules_file style.md "original rule text"
    stage_rules_files
    printf 'edited by the phase\n' > "$WORKTREE_DIR/.agent-data/rules/style.md"
    apply_rules_files
    run cat "$WORKTREE_DIR/.claude/rules/style.md"; assert_output "edited by the phase"
    run git -C "$WORKTREE_DIR" log -1 --format=%s
    assert_output "chore(agent): apply staged rules updates — style.md"
    [ "$RULES_APPLIED" = "style.md" ]
    run git -C "$WORKTREE_DIR" status --porcelain -- .claude; assert_output ""   # nothing left dirty under .claude/
}

@test "REGRESSION upstream v1.2.0: a staged file with no counterpart in .claude/rules/ is not applied" {
    container_lib_source
    _seed_rules_file style.md "original rule text"
    stage_rules_files
    printf 'invented by the phase\n' > "$WORKTREE_DIR/.agent-data/rules/invented.md"
    apply_rules_files
    [ ! -f "$WORKTREE_DIR/.claude/rules/invented.md" ]
    [ -z "$RULES_APPLIED" ]
    run cat "$LOG_FILE"; assert_output --partial "no counterpart"
}

@test "rules: apply_rules_files ignores staged names outside the allow-list pattern" {
    container_lib_source
    _seed_rules_file "bad name.md" "spaced original"
    stage_rules_files
    printf 'edited\n' > "$WORKTREE_DIR/.agent-data/rules/bad name.md"
    apply_rules_files
    run cat "$WORKTREE_DIR/.claude/rules/bad name.md"; assert_output "spaced original"
    run cat "$LOG_FILE"; assert_output --partial "outside the allow-list pattern"
}

@test "rules: apply_rules_files makes no commit when nothing differs" {
    container_lib_source
    _seed_rules_file style.md "original rule text"
    stage_rules_files
    before=$(git -C "$WORKTREE_DIR" rev-parse HEAD)
    apply_rules_files
    [ "$(git -C "$WORKTREE_DIR" rev-parse HEAD)" = "$before" ]
    [ -z "$RULES_APPLIED" ]
}

@test "rules: vendored rules-staging.sh is byte-identical to upstream 04cef68" {
    if [ ! -d "$HOME/repos/sandbox-pal-action/.git" ]; then skip "upstream clone not present"; fi
    run diff <(git -C "$HOME/repos/sandbox-pal-action" show 04cef68:scripts/lib/rules-staging.sh) "$LIB_DIR/rules-staging.sh"
    assert_success
}
