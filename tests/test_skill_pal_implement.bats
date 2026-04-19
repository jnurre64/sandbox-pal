#!/usr/bin/env bats
load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    TMPHOME="$(mktemp -d)"
    export HOME="$TMPHOME"
    export XDG_CONFIG_HOME="$TMPHOME/.config"
    export XDG_DATA_HOME="$TMPHOME/.local/share"

    # env-passthrough: credentials are process env vars, not a file on disk
    export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-fake
    export GH_TOKEN=github_pat_fake
    unset ANTHROPIC_API_KEY

    # Mock docker with a script that writes a fake status.json
    export PATH="$TMPHOME/bin:$PATH"
    mkdir -p "$TMPHOME/bin"
    cat > "$TMPHOME/bin/docker" <<'DOCKER_MOCK'
#!/bin/bash
case "$1" in
    info) exit 0 ;;
    run)
        # Find the -v bind mount for status
        status_dir=$(echo "$@" | grep -oE '/tmp[^:]+:/status' | cut -d: -f1 | head -1)
        [ -z "$status_dir" ] && status_dir=$(echo "$@" | grep -oE '[^ ]+/claude-pal/runs/[^:]+:/status' | cut -d: -f1 | head -1)
        if [ -n "$status_dir" ] && [ -d "$status_dir" ]; then
            cat > "$status_dir/status.json" <<EOF_STATUS
{"outcome":"success","phase":"complete","pr_url":"https://github.com/x/y/pull/99","pr_number":99,"failure_reason":null}
EOF_STATUS
        fi
        exit 0
        ;;
    *) exit 1 ;;
esac
DOCKER_MOCK
    chmod +x "$TMPHOME/bin/docker"
}

teardown() {
    rm -rf "$TMPHOME"
}

@test "pal-implement happy path with mocked docker" {
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
    source "$REPO_ROOT/lib/config.sh"
    source "$REPO_ROOT/lib/preflight.sh"
    source "$REPO_ROOT/lib/runs.sh"
    source "$REPO_ROOT/lib/launcher.sh"

    # Stub pal_preflight_gh_auth to skip network call
    pal_preflight_gh_auth() { :; }

    run bash -c "
        export CLAUDE_PLUGIN_ROOT='$REPO_ROOT'
        source '$REPO_ROOT/lib/config.sh'
        source '$REPO_ROOT/lib/preflight.sh'
        source '$REPO_ROOT/lib/runs.sh'
        source '$REPO_ROOT/lib/launcher.sh'
        pal_preflight_gh_auth() { :; }
        pal_preflight_all 'owner/repo' 42
        run_id=\$(pal_new_run_id)
        pal_write_launch_meta \"\$run_id\" owner/repo 42 implement sync
        pal_launch_sync \"\$run_id\" owner/repo 42 implement > /dev/null
        pal_render_status_summary \"\$run_id\"
    "
    assert_success
    assert_output --partial "success"
    assert_output --partial "https://github.com/x/y/pull/99"
}
