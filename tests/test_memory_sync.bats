#!/usr/bin/env bats
# shellcheck shell=bash

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'test_helper/fake-docker.sh'

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
    fake_docker_setup
    # shellcheck source=../lib/memory-sync.sh
    . "$REPO_ROOT/lib/memory-sync.sh"
}

teardown() {
    fake_docker_teardown
}

@test "pal_memory_slug encodes / as -" {
    run pal_memory_slug /home/jonny/repos/claude-pal
    assert_success
    assert_output "-home-jonny-repos-claude-pal"
}

@test "pal_memory_slug encodes nested path" {
    run pal_memory_slug /home/agent/work/run-42
    assert_success
    assert_output "-home-agent-work-run-42"
}
