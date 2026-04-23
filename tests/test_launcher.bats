#!/usr/bin/env bats
# shellcheck shell=bash

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'test_helper/fake-docker.sh'

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
    TMPHOME="$(mktemp -d)"
    export HOME="$TMPHOME"
    export XDG_CONFIG_HOME="$TMPHOME/.config"
    export XDG_DATA_HOME="$TMPHOME/.local/share"
    mkdir -p "$HOME"

    fake_docker_setup

    # shellcheck source=../lib/workspace.sh
    . "$REPO_ROOT/lib/workspace.sh"
    # shellcheck source=../lib/runs.sh
    . "$REPO_ROOT/lib/runs.sh"
    # shellcheck source=../lib/memory-sync.sh
    . "$REPO_ROOT/lib/memory-sync.sh"
    # shellcheck source=../lib/container-rules.sh
    . "$REPO_ROOT/lib/container-rules.sh"
    # shellcheck source=../lib/launcher.sh
    . "$REPO_ROOT/lib/launcher.sh"
}

teardown() {
    fake_docker_teardown
    rm -rf "$TMPHOME"
}

@test "pal_launch_sync calls ensure-running, syncs, then docker exec (not docker run)" {
    fake_docker_set_running

    mkdir -p "$HOME/.claude/projects/-home-me-repos-foo/memory"
    echo "# idx" > "$HOME/.claude/projects/-home-me-repos-foo/memory/MEMORY.md"

    # Ensure a container-CLAUDE.md exists so the rules sync has something to cp.
    pal_container_rules_ensure
    echo "do not be evil" > "$(pal_container_rules_path)"

    GH_TOKEN=ghp_x \
    run pal_launch_sync implement owner/repo 42 /home/me/repos/foo run-test-1
    assert_success

    run grep -- "^run -d" "$FAKE_DOCKER_LOG"
    assert_failure   # must NOT be using `docker run` anymore

    run grep -- "^exec .*sandbox-pal-workspace.*run-pipeline.sh implement owner/repo 42" "$FAKE_DOCKER_LOG"
    assert_success

    run grep -- "^cp .*container-CLAUDE.md" "$FAKE_DOCKER_LOG"
    assert_success
}

@test "pal_launch_sync forwards GH_TOKEN but NOT CLAUDE_CODE_OAUTH_TOKEN" {
    fake_docker_set_running

    export GH_TOKEN=ghp_x
    export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-should-be-ignored

    run pal_launch_sync implement owner/repo 42 /tmp/repo run-test-2
    assert_success

    run grep -- "-e GH_TOKEN" "$FAKE_DOCKER_LOG"
    assert_success
    run grep -- "CLAUDE_CODE_OAUTH_TOKEN" "$FAKE_DOCKER_LOG"
    assert_failure
}
