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

@test "pal_memory_sync_to_container copies to a root-owned read-only dir under /home/agent/memory and exports AGENT_MEMORY_DIR" {
    fake_docker_set_running

    local host_proj="$BATS_TEST_TMPDIR/host/.claude/projects/-home-me-repos-foo/memory"
    mkdir -p "$host_proj"
    echo "# index" > "$host_proj/MEMORY.md"
    echo "# topic" > "$host_proj/user_role.md"
    echo '{"secret":1}' > "$host_proj/session.jsonl"

    export HOME="$BATS_TEST_TMPDIR/host" PAL_SYNC_MEMORIES=true
    unset AGENT_MEMORY_DIR
    pal_memory_sync_to_container /home/me/repos/foo /home/agent/work/run-1
    assert_equal "$AGENT_MEMORY_DIR" "/home/agent/memory/-home-me-repos-foo"
    run bash -c 'printenv AGENT_MEMORY_DIR'
    assert_output "/home/agent/memory/-home-me-repos-foo"

    # Previous copy is root-owned, so removal and creation happen as root.
    run grep -E '^exec -u root sandbox-pal-workspace rm -rf /home/agent/memory/-home-me-repos-foo$' "$FAKE_DOCKER_LOG"
    assert_success
    run grep -E '^exec -u root sandbox-pal-workspace mkdir -p /home/agent/memory/-home-me-repos-foo$' "$FAKE_DOCKER_LOG"
    assert_success
    run grep -E '^cp .* sandbox-pal-workspace:/home/agent/memory/-home-me-repos-foo$' "$FAKE_DOCKER_LOG"
    assert_success
    # Read-only for the unprivileged agent user: root-owned, go=rX.
    run grep -E '^exec -u root sandbox-pal-workspace chown -R root:root /home/agent/memory/-home-me-repos-foo$' "$FAKE_DOCKER_LOG"
    assert_success
    run grep -E '^exec -u root sandbox-pal-workspace chmod -R u=rwX,go=rX /home/agent/memory/-home-me-repos-foo$' "$FAKE_DOCKER_LOG"
    assert_success
    # The old writable project-slug destination must not be used any more.
    run grep -E '/home/agent/.claude/projects/' "$FAKE_DOCKER_LOG"
    assert_failure
}

@test "REGRESSION: *.jsonl never reaches the docker cp payload unless PAL_SYNC_TRANSCRIPTS=true" {
    fake_docker_set_running
    local host_proj="$BATS_TEST_TMPDIR/host/.claude/projects/-home-me-repos-foo/memory"
    mkdir -p "$host_proj"
    echo "# index" > "$host_proj/MEMORY.md"
    echo '{"secret":1}' > "$host_proj/session.jsonl"
    # The fake docker only logs argv, so make it list the cp source's files.
    export HOME="$BATS_TEST_TMPDIR/host" PAL_SYNC_MEMORIES=true
    cat > "$FAKE_DOCKER_DIR/docker" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_DOCKER_LOG"
if [ "$1" = cp ]; then find "${2%/.}" -type f -printf '%f\n' >> "$FAKE_DOCKER_LOG"; fi
if [ "$1" = ps ]; then echo sandbox-pal-workspace; fi
exit 0
SHIM
    pal_memory_sync_to_container /home/me/repos/foo /home/agent/work/run-1
    run grep -c 'session.jsonl' "$FAKE_DOCKER_LOG"; assert_output "0"
    run grep -c '^MEMORY.md$' "$FAKE_DOCKER_LOG"; assert_output "1"
}

@test "pal_memory_sync_to_container is a no-op when PAL_SYNC_MEMORIES=false" {
    fake_docker_set_running
    unset AGENT_MEMORY_DIR
    PAL_SYNC_MEMORIES=false pal_memory_sync_to_container /any /any
    run grep "^cp " "$FAKE_DOCKER_LOG"
    assert_failure
    [ -z "${AGENT_MEMORY_DIR:-}" ]
}

@test "pal_memory_sync_to_container does nothing if host memory dir absent" {
    fake_docker_set_running
    unset AGENT_MEMORY_DIR
    HOME="$BATS_TEST_TMPDIR/empty" pal_memory_sync_to_container /nope /home/agent/work/run-1
    run grep "^cp " "$FAKE_DOCKER_LOG"
    assert_failure
    [ -z "${AGENT_MEMORY_DIR:-}" ]
}
