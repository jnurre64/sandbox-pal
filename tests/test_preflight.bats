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
    # shellcheck source=../lib/preflight.sh
    . "$REPO_ROOT/lib/preflight.sh"
}

teardown() {
    fake_docker_teardown
}

@test "pal_preflight_workspace_ready fails when workspace absent" {
    fake_docker_set_absent
    run pal_preflight_workspace_ready
    assert_failure
    assert_output --partial "workspace"
}

@test "pal_preflight_workspace_ready fails when running but not authenticated" {
    fake_docker_set_running
    : > "$FAKE_DOCKER_STATE/exec_fails"
    run pal_preflight_workspace_ready
    assert_failure
    assert_output --partial "/pal-login"
}

@test "pal_preflight_workspace_ready succeeds when running and authenticated" {
    fake_docker_set_running
    run pal_preflight_workspace_ready
    assert_success
}
