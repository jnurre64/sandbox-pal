#!/usr/bin/env bats
load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    TMPHOME="$(mktemp -d)"
    export HOME="$TMPHOME"
    export XDG_CONFIG_HOME="$TMPHOME/.config"
    # env-passthrough: credentials are process env vars, not a file on disk
    export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-fake
    export GH_TOKEN=github_pat_fake
    unset ANTHROPIC_API_KEY

    # Fake project with a plan file
    WORKDIR="$(mktemp -d)"
    mkdir -p "$WORKDIR/docs/superpowers/plans"
    cat > "$WORKDIR/docs/superpowers/plans/2026-04-18-feature.md" <<PLAN
# Test Plan
This is a test plan.
PLAN

    # Mock gh
    export PATH="$TMPHOME/bin:$PATH"
    mkdir -p "$TMPHOME/bin"
    cat > "$TMPHOME/bin/gh" <<'GH_MOCK'
#!/bin/bash
case "$1 $2" in
    "issue create")
        echo "https://github.com/owner/repo/issues/123"
        exit 0
        ;;
    "issue comment")
        echo "https://github.com/owner/repo/issues/42#issuecomment-99"
        exit 0
        ;;
esac
exit 1
GH_MOCK
    chmod +x "$TMPHOME/bin/gh"
}

teardown() {
    rm -rf "$TMPHOME" "$WORKDIR"
}

@test "pal-plan with existing issue posts a comment" {
    cd "$WORKDIR"
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
    source "$REPO_ROOT/lib/config.sh"
    source "$REPO_ROOT/lib/plan-locator.sh"
    source "$REPO_ROOT/lib/publisher.sh"
    pal_load_config
    plan=$(pal_find_plan_file)

    run pal_publish_plan "$plan" owner/repo 42
    assert_success
    assert_output --partial "Posted plan comment"
    assert_output --partial "/pal-implement 42"
}

@test "pal-plan without issue creates a new one" {
    cd "$WORKDIR"
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
    source "$REPO_ROOT/lib/config.sh"
    source "$REPO_ROOT/lib/plan-locator.sh"
    source "$REPO_ROOT/lib/publisher.sh"
    pal_load_config
    plan=$(pal_find_plan_file)

    run pal_publish_plan "$plan" owner/repo ""
    assert_success
    assert_output --partial "Created new issue"
    assert_output --partial "/pal-implement 123"
}
