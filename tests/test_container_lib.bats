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
