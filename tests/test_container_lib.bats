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
