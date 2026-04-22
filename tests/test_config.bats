#!/usr/bin/env bats
# shellcheck shell=bash

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"

    TMPHOME="$(mktemp -d)"
    export HOME="$TMPHOME"
    export XDG_CONFIG_HOME="$TMPHOME/.config"

    # shellcheck source=../lib/config.sh
    . "$REPO_ROOT/lib/config.sh"
}

teardown() {
    rm -rf "$TMPHOME"
}

@test "pal_load_config succeeds when only GH_TOKEN is set (OAuth no longer required)" {
    unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY
    export GH_TOKEN=ghp_test
    run pal_load_config
    assert_success
}

@test "pal_load_config errors only on missing GH_TOKEN" {
    unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY GH_TOKEN GITHUB_TOKEN
    run pal_load_config
    assert_failure
    assert_output --partial "GH_TOKEN"
    refute_output --partial "CLAUDE_CODE_OAUTH_TOKEN"
}

@test "pal_load_config sources ~/.config/claude-pal/config.env when present" {
    mkdir -p "$HOME/.config/claude-pal"
    cat > "$HOME/.config/claude-pal/config.env" <<EOF
PAL_CPUS=2.0
PAL_MEMORY=4g
PAL_SYNC_MEMORIES=false
EOF
    export GH_TOKEN=ghp_test
    run bash -c '. "$CLAUDE_PLUGIN_ROOT/lib/config.sh" && pal_load_config && echo "CPUS=$PAL_CPUS MEM=$PAL_MEMORY SYNC=$PAL_SYNC_MEMORIES"'
    assert_success
    assert_output --partial "CPUS=2.0"
    assert_output --partial "MEM=4g"
    assert_output --partial "SYNC=false"
}
