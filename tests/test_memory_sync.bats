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
    run pal_memory_slug /home/jonny/repos/sandbox-pal
    assert_success
    assert_output "-home-jonny-repos-sandbox-pal"
}

@test "pal_memory_slug encodes nested path" {
    run pal_memory_slug /home/agent/work/run-42
    assert_success
    assert_output "-home-agent-work-run-42"
}

@test "pal_memory_sync_to_container copies MEMORY.md and topic .md files" {
    fake_docker_set_running

    local host_proj="$BATS_TEST_TMPDIR/host/.claude/projects/-home-me-repos-foo/memory"
    mkdir -p "$host_proj"
    echo "# index" > "$host_proj/MEMORY.md"
    echo "# topic" > "$host_proj/user_role.md"
    echo '{"secret":1}' > "$host_proj/session.jsonl"

    HOME="$BATS_TEST_TMPDIR/host" \
    PAL_SYNC_MEMORIES=true \
        run pal_memory_sync_to_container \
            /home/me/repos/foo \
            /home/agent/work/run-1
    assert_success

    # Assert the docker cp/exec commands were called and *.jsonl is NOT in the
    # payload (inspect FAKE_DOCKER_LOG).
    run grep -E 'exec.*rm -rf /home/agent/.claude/projects/-home-agent-work-run-1/memory' "$FAKE_DOCKER_LOG"
    assert_success
    run grep -E 'cp .* sandbox-pal-workspace:/home/agent/.claude/projects/-home-agent-work-run-1/memory' "$FAKE_DOCKER_LOG"
    assert_success
}

@test "pal_memory_sync_to_container is a no-op when PAL_SYNC_MEMORIES=false" {
    fake_docker_set_running
    PAL_SYNC_MEMORIES=false run pal_memory_sync_to_container /any /any
    assert_success
    run grep "^cp " "$FAKE_DOCKER_LOG"
    assert_failure
}

@test "pal_memory_sync_to_container does nothing if host memory dir absent" {
    fake_docker_set_running
    HOME="$BATS_TEST_TMPDIR/empty" run pal_memory_sync_to_container /nope /home/agent/work/run-1
    assert_success
}
