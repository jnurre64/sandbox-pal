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

@test "_pal_launcher_env_args forwards AGENT_MEMORY_DIR when set and omits it otherwise" {
    unset AGENT_MEMORY_DIR
    local -a args=()
    GH_TOKEN=ghp_x _pal_launcher_env_args run-1 args
    run printf '%s\n' "${args[@]}"
    refute_line --partial "AGENT_MEMORY_DIR"

    export AGENT_MEMORY_DIR=/home/agent/memory/-home-me-repos-foo
    args=()
    GH_TOKEN=ghp_x _pal_launcher_env_args run-1 args
    run printf '%s\n' "${args[@]}"
    assert_line "AGENT_MEMORY_DIR=/home/agent/memory/-home-me-repos-foo"
}

@test "pal_launch_sync passes the synced memory dir to docker exec" {
    fake_docker_set_running
    mkdir -p "$HOME/.claude/projects/-home-me-repos-foo/memory"
    echo "# idx" > "$HOME/.claude/projects/-home-me-repos-foo/memory/MEMORY.md"
    unset AGENT_MEMORY_DIR
    GH_TOKEN=ghp_x run pal_launch_sync implement owner/repo 42 /home/me/repos/foo run-test-2
    assert_success
    run grep -- "^exec .*-e AGENT_MEMORY_DIR=/home/agent/memory/-home-me-repos-foo .*run-pipeline.sh" "$FAKE_DOCKER_LOG"
    assert_success
}

@test "pal_launch_sync and pal_launch_async sync PAL_SYNC_SKILLS before exec" {
    fake_docker_set_running
    mkdir -p "$HOME/.claude/skills/alpha"; echo "# a" > "$HOME/.claude/skills/alpha/SKILL.md"
    export PAL_SYNC_SKILLS=alpha
    GH_TOKEN=ghp_x run pal_launch_sync implement owner/repo 42 /home/me/repos/foo run-test-3
    assert_success
    run grep -cE '^cp .*sandbox-pal-workspace:/home/agent/.claude/skills/alpha$' "$FAKE_DOCKER_LOG"; assert_output "1"
    : > "$FAKE_DOCKER_LOG"
    GH_TOKEN=ghp_x run pal_launch_async implement owner/repo 42 /home/me/repos/foo run-test-4
    assert_success
    run grep -cE '^cp .*sandbox-pal-workspace:/home/agent/.claude/skills/alpha$' "$FAKE_DOCKER_LOG"; assert_output "1"
}

@test "_pal_launcher_env_args forwards the PR 1/2 AGENT_* knobs from .pal/config.env, skipping comments" {
    local repo="$TMPHOME/proj"; mkdir -p "$repo/.pal"
    cat > "$repo/.pal/config.env" <<'CFG'
# comment line
AGENT_BUDGET_USD_IMPLEMENT=8
AGENT_EFFORT_POST_IMPL_REVIEW=xhigh
AGENT_PERMISSION_MODE_IMPLEMENT=dontAsk
AGENT_STRICT_MCP=true
AGENT_TEST_GATE_MAX_RETRIES=1
AGENT_JSON_SCHEMA_POST_IMPL_REVIEW=
# AGENT_MODEL_IMPLEMENT=commented-out
PAL_ALLOWLIST_EXTRA_DOMAINS=registry.example.com
CFG
    cd "$repo"
    local -a args=()
    GH_TOKEN=ghp_x _pal_launcher_env_args run-1 args
    run printf '%s\n' "${args[@]}"
    assert_line "AGENT_BUDGET_USD_IMPLEMENT=8"
    assert_line "AGENT_EFFORT_POST_IMPL_REVIEW=xhigh"
    assert_line "AGENT_PERMISSION_MODE_IMPLEMENT=dontAsk"
    assert_line "AGENT_STRICT_MCP=true"
    assert_line "AGENT_TEST_GATE_MAX_RETRIES=1"
    assert_line "AGENT_JSON_SCHEMA_POST_IMPL_REVIEW="      # empty value still forwarded (disables the schema)
    assert_line "PAL_ALLOWLIST_EXTRA_DOMAINS=registry.example.com"
    refute_line --partial "commented-out"
}
