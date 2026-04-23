#!/usr/bin/env bats
# shellcheck shell=bash

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'test_helper/fake-docker.sh'

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    # Isolate from any inherited XDG_CONFIG_HOME — CI runners leak one in.
    export XDG_CONFIG_HOME="$HOME/.config"
    fake_docker_setup
    # shellcheck source=../lib/container-rules.sh
    . "$REPO_ROOT/lib/container-rules.sh"
}

teardown() {
    fake_docker_teardown
}

@test "pal_container_rules_path respects XDG_CONFIG_HOME" {
    XDG_CONFIG_HOME="$HOME/xdg" run pal_container_rules_path
    assert_success
    assert_output "$HOME/xdg/claude-pal/container-CLAUDE.md"
}

@test "pal_container_rules_path falls back to ~/.config" {
    unset XDG_CONFIG_HOME
    run pal_container_rules_path
    assert_success
    assert_output "$HOME/.config/claude-pal/container-CLAUDE.md"
}

@test "pal_container_rules_ensure creates empty file when missing" {
    run pal_container_rules_ensure
    assert_success
    [ -f "$HOME/.config/claude-pal/container-CLAUDE.md" ]
    run cat "$HOME/.config/claude-pal/container-CLAUDE.md"
    assert_output ""
}

@test "pal_container_rules_sync_to_container copies file into container" {
    fake_docker_set_running
    pal_container_rules_ensure
    echo "do not run destructive commands" \
        > "$HOME/.config/claude-pal/container-CLAUDE.md"
    run pal_container_rules_sync_to_container
    assert_success
    run grep "cp .*container-CLAUDE.md claude-pal-workspace:/home/agent/.claude/CLAUDE.md" "$FAKE_DOCKER_LOG"
    assert_success
}
