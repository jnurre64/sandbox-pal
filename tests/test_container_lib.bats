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
