#!/usr/bin/env bats
# shellcheck shell=bash

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'test_helper/fake-docker.sh'

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
    fake_docker_setup
    # shellcheck source=../lib/workspace.sh
    . "$REPO_ROOT/lib/workspace.sh"
}

teardown() {
    fake_docker_teardown
}

@test "pal_workspace_start creates volume and runs container when absent" {
    fake_docker_set_absent
    run pal_workspace_start
    assert_success
    run grep "volume create sandbox-pal-claude" "$FAKE_DOCKER_LOG"
    assert_success
    run grep "run -d --name sandbox-pal-workspace" "$FAKE_DOCKER_LOG"
    assert_success
    run grep "cap-add NET_ADMIN" "$FAKE_DOCKER_LOG"
    assert_success
    run grep "cap-add NET_RAW" "$FAKE_DOCKER_LOG"
    assert_success
    # Host runs-dir must be bind-mounted at /status so run-pipeline.sh (via
    # docker exec) can write status.json visible to the host.
    run grep -E -- "-v [^ ]+:/status" "$FAKE_DOCKER_LOG"
    assert_success
}

@test "pal_workspace_start is a no-op if already running" {
    fake_docker_set_running
    run pal_workspace_start
    assert_success
    run grep "run -d" "$FAKE_DOCKER_LOG"
    assert_failure
}

@test "pal_workspace_start starts existing but stopped container" {
    fake_docker_set_stopped
    run pal_workspace_start
    assert_success
    run grep "^start sandbox-pal-workspace" "$FAKE_DOCKER_LOG"
    assert_success
}

@test "pal_workspace_start respects PAL_CPUS and PAL_MEMORY" {
    fake_docker_set_absent
    PAL_CPUS=2.0 PAL_MEMORY=4g run pal_workspace_start
    assert_success
    run grep -- "--cpus=2.0" "$FAKE_DOCKER_LOG"
    assert_success
    run grep -- "--memory=4g" "$FAKE_DOCKER_LOG"
    assert_success
}

@test "pal_workspace_stop stops running workspace" {
    fake_docker_set_running
    run pal_workspace_stop
    assert_success
    run grep "^stop sandbox-pal-workspace" "$FAKE_DOCKER_LOG"
    assert_success
}

@test "pal_workspace_stop is a no-op if not running" {
    fake_docker_set_stopped
    run pal_workspace_stop
    assert_success
    run grep "^stop " "$FAKE_DOCKER_LOG"
    assert_failure
}

@test "pal_workspace_restart stops then starts" {
    fake_docker_set_running
    run pal_workspace_restart
    assert_success
    run grep "^stop sandbox-pal-workspace" "$FAKE_DOCKER_LOG"
    assert_success
    run grep "^start sandbox-pal-workspace" "$FAKE_DOCKER_LOG"
    assert_success
}

@test "pal_workspace_ensure_running starts stopped workspace and emits log line" {
    fake_docker_set_stopped
    run pal_workspace_ensure_running
    assert_success
    assert_output --partial "workspace stopped — starting"
}

@test "pal_workspace_ensure_running is silent when already running" {
    fake_docker_set_running
    run pal_workspace_ensure_running
    assert_success
    refute_output --partial "workspace stopped"
}

@test "pal_workspace_is_authenticated returns 0 when credentials exist" {
    fake_docker_set_running
    # fake docker defaults to exit 0 for exec
    run pal_workspace_is_authenticated
    assert_success
}

@test "pal_workspace_is_authenticated returns non-zero when credentials missing" {
    fake_docker_set_running
    : > "$FAKE_DOCKER_STATE/exec_fails"
    run pal_workspace_is_authenticated
    assert_failure
}

@test "pal_workspace_status prints name, state, and auth summary" {
    fake_docker_set_running
    run pal_workspace_status
    assert_success
    assert_output --partial "sandbox-pal-workspace"
    assert_output --partial "running"
}
