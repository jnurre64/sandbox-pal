#!/usr/bin/env bats
# shellcheck shell=bash
#
# Smoke test for the /pal-workspace skill. Extracts the bash block from
# SKILL.md and exercises the case dispatch against a fake docker shim.

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

    # pal_load_config requires GH_TOKEN
    export GH_TOKEN=github_pat_fake
    unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN

    fake_docker_setup

    # Extract the first bash code block from SKILL.md into a sourceable script.
    SKILL_SCRIPT="$TMPHOME/pal-workspace.sh"
    awk '
        /^```bash$/ { in_block=1; next }
        /^```$/     { if (in_block) { exit } }
        in_block    { print }
    ' "$REPO_ROOT/skills/pal-workspace/SKILL.md" > "$SKILL_SCRIPT"
}

teardown() {
    fake_docker_teardown
    rm -rf "$TMPHOME"
}

@test "pal-workspace SKILL.md contains a bash block" {
    run test -s "$SKILL_SCRIPT"
    assert_success
    run grep -Fq "pal_workspace_status" "$SKILL_SCRIPT"
    assert_success
}

@test "pal-workspace status runs end-to-end" {
    fake_docker_set_running
    run bash "$SKILL_SCRIPT" status
    assert_success
    assert_output --partial "sandbox-pal-workspace"
    assert_output --partial "running"
}

@test "pal-workspace (no arg) defaults to status" {
    fake_docker_set_running
    run bash "$SKILL_SCRIPT"
    assert_success
    assert_output --partial "sandbox-pal-workspace"
}

@test "pal-workspace start launches a stopped workspace" {
    fake_docker_set_absent
    run bash "$SKILL_SCRIPT" start
    assert_success
    run grep "run -d --name sandbox-pal-workspace" "$FAKE_DOCKER_LOG"
    assert_success
}

@test "pal-workspace start on already-running workspace restarts it" {
    fake_docker_set_running
    run bash "$SKILL_SCRIPT" start
    assert_success
    assert_output --partial "already running"
    run grep "^stop sandbox-pal-workspace" "$FAKE_DOCKER_LOG"
    assert_success
}

@test "pal-workspace stop stops a running workspace" {
    fake_docker_set_running
    run bash "$SKILL_SCRIPT" stop
    assert_success
    run grep "^stop sandbox-pal-workspace" "$FAKE_DOCKER_LOG"
    assert_success
}

@test "pal-workspace restart stops and starts" {
    fake_docker_set_running
    run bash "$SKILL_SCRIPT" restart
    assert_success
    run grep "^stop sandbox-pal-workspace" "$FAKE_DOCKER_LOG"
    assert_success
    run grep "^start sandbox-pal-workspace" "$FAKE_DOCKER_LOG"
    assert_success
}

@test "pal-workspace with unknown subcommand exits non-zero with usage" {
    fake_docker_set_running
    run bash "$SKILL_SCRIPT" bogus
    assert_failure
    assert_output --partial "usage: pal-workspace"
}
