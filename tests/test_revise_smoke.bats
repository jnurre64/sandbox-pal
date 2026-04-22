#!/usr/bin/env bats
load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

# Smoke test for /pal-revise end-to-end against a mocked docker.
# Mirrors the pattern used by test_skill_pal_implement.bats.

setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    TMPHOME="$(mktemp -d)"
    export HOME="$TMPHOME"
    export XDG_CONFIG_HOME="$TMPHOME/.config"
    export XDG_DATA_HOME="$TMPHOME/.local/share"

    # env-passthrough: credentials are process env vars, not a file on disk
    export GH_TOKEN=github_pat_fake
    unset ANTHROPIC_API_KEY
    unset CLAUDE_CODE_OAUTH_TOKEN

    # Give memory sync something to stage and container rules a file to cp.
    mkdir -p "$HOME/.claude/projects/-tmp-host-repo/memory"
    echo "# mem" > "$HOME/.claude/projects/-tmp-host-repo/memory/MEMORY.md"
    mkdir -p "$XDG_CONFIG_HOME/claude-pal"
    echo "revise rules" > "$XDG_CONFIG_HOME/claude-pal/container-CLAUDE.md"

    # Mock docker that logs calls and writes a fake status.json on exec.
    export DOCKER_CALL_LOG="$TMPHOME/docker-calls.log"
    : > "$DOCKER_CALL_LOG"
    export PATH="$TMPHOME/bin:$PATH"
    mkdir -p "$TMPHOME/bin"
    cat > "$TMPHOME/bin/docker" <<'DOCKER_MOCK'
#!/bin/bash
echo "$*" >> "$DOCKER_CALL_LOG"
case "$1" in
    info) exit 0 ;;
    inspect) exit 0 ;;
    ps) echo "claude-pal-workspace"; exit 0 ;;
    volume|cp|pull|start|stop|rm) exit 0 ;;
    exec)
        run_id=""
        for arg in "$@"; do
            case "$arg" in RUN_ID=*) run_id="${arg#RUN_ID=}" ;; esac
        done
        if [ -n "$run_id" ]; then
            status_dir="${XDG_DATA_HOME:-$HOME/.local/share}/claude-pal/runs/$run_id"
            mkdir -p "$status_dir"
            cat > "$status_dir/status.json" <<EOF_STATUS
{"outcome":"success","phase":"complete","pr_url":"https://github.com/owner/repo/pull/317","pr_number":317,"failure_reason":null}
EOF_STATUS
        fi
        exit 0
        ;;
    run) exit 0 ;;
    *) exit 1 ;;
esac
DOCKER_MOCK
    chmod +x "$TMPHOME/bin/docker"
}

teardown() {
    rm -rf "$TMPHOME"
}

@test "pal-revise happy path with mocked docker, event_type=revise" {
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
    source "$REPO_ROOT/lib/config.sh"
    source "$REPO_ROOT/lib/preflight.sh"
    source "$REPO_ROOT/lib/runs.sh"
    source "$REPO_ROOT/lib/launcher.sh"

    # Stub pal_preflight_gh_auth to skip network call
    pal_preflight_gh_auth() { :; }

    run bash -c "
        export CLAUDE_PLUGIN_ROOT='$REPO_ROOT'
        export HOME='$HOME'
        export XDG_CONFIG_HOME='$XDG_CONFIG_HOME'
        export XDG_DATA_HOME='$XDG_DATA_HOME'
        export DOCKER_CALL_LOG='$DOCKER_CALL_LOG'
        source '$REPO_ROOT/lib/config.sh'
        source '$REPO_ROOT/lib/preflight.sh'
        source '$REPO_ROOT/lib/runs.sh'
        source '$REPO_ROOT/lib/launcher.sh'
        pal_preflight_gh_auth() { :; }
        pal_preflight_all 'owner/repo' 317
        run_id=\$(pal_new_run_id)
        pal_write_launch_meta \"\$run_id\" owner/repo 317 revise sync
        pal_launch_sync revise owner/repo 317 /tmp/host-repo \"\$run_id\" > /dev/null
        pal_render_status_summary \"\$run_id\"
    "
    assert_success
    assert_output --partial "success"
    assert_output --partial "https://github.com/owner/repo/pull/317"
}

@test "pal-revise passes event_type=revise into the workspace pipeline" {
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
    source "$REPO_ROOT/lib/config.sh"
    source "$REPO_ROOT/lib/preflight.sh"
    source "$REPO_ROOT/lib/runs.sh"
    source "$REPO_ROOT/lib/launcher.sh"

    pal_preflight_gh_auth() { :; }

    run bash -c "
        export CLAUDE_PLUGIN_ROOT='$REPO_ROOT'
        export HOME='$HOME'
        export XDG_CONFIG_HOME='$XDG_CONFIG_HOME'
        export XDG_DATA_HOME='$XDG_DATA_HOME'
        export DOCKER_CALL_LOG='$DOCKER_CALL_LOG'
        source '$REPO_ROOT/lib/config.sh'
        source '$REPO_ROOT/lib/preflight.sh'
        source '$REPO_ROOT/lib/runs.sh'
        source '$REPO_ROOT/lib/launcher.sh'
        pal_preflight_gh_auth() { :; }
        pal_preflight_all 'owner/repo' 317
        run_id=\$(pal_new_run_id)
        pal_write_launch_meta \"\$run_id\" owner/repo 317 revise sync
        pal_launch_sync revise owner/repo 317 /tmp/host-repo \"\$run_id\" > /dev/null
    "
    assert_success

    # Must exec into the workspace (not docker run --rm).
    run grep -E "^run --rm" "$DOCKER_CALL_LOG"
    assert_failure

    run grep -E "^exec .*run-pipeline.sh revise owner/repo 317" "$DOCKER_CALL_LOG"
    assert_success

    # Memory-sync + rules-sync must fire before the pipeline exec.
    run grep -E "^cp " "$DOCKER_CALL_LOG"
    assert_success

    # GH_TOKEN forwarded; CLAUDE_CODE_OAUTH_TOKEN is not.
    run grep -E "GH_TOKEN" "$DOCKER_CALL_LOG"
    assert_success
    run grep -E "CLAUDE_CODE_OAUTH_TOKEN" "$DOCKER_CALL_LOG"
    assert_failure
}
