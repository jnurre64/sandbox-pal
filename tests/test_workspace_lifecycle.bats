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
    run grep "volume create claude-pal-claude" "$FAKE_DOCKER_LOG"
    assert_success
    run grep "run -d --name claude-pal-workspace" "$FAKE_DOCKER_LOG"
    assert_success
    run grep "cap-add NET_ADMIN" "$FAKE_DOCKER_LOG"
    assert_success
    run grep "cap-add NET_RAW" "$FAKE_DOCKER_LOG"
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
    run grep "^start claude-pal-workspace" "$FAKE_DOCKER_LOG"
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
