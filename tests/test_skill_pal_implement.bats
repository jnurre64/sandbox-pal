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

    # Give the memory sync something to stage, and the rules sync a file to cp.
    mkdir -p "$HOME/.claude/projects/-tmp-host-repo/memory"
    echo "# mem" > "$HOME/.claude/projects/-tmp-host-repo/memory/MEMORY.md"
    mkdir -p "$XDG_CONFIG_HOME/claude-pal"
    echo "be careful" > "$XDG_CONFIG_HOME/claude-pal/container-CLAUDE.md"

    # Mock docker with a script that logs every invocation and writes a fake
    # status.json on `exec` so pal_render_status_summary finds one.
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
        # Find the RUN_ID from the env args; create the run's status dir and
        # write a fake success status.json so pal_render_status_summary works.
        run_id=""
        for arg in "$@"; do
            case "$arg" in RUN_ID=*) run_id="${arg#RUN_ID=}" ;; esac
        done
        if [ -n "$run_id" ]; then
            status_dir="${XDG_DATA_HOME:-$HOME/.local/share}/claude-pal/runs/$run_id"
            mkdir -p "$status_dir"
            cat > "$status_dir/status.json" <<EOF_STATUS
{"outcome":"success","phase":"complete","pr_url":"https://github.com/x/y/pull/99","pr_number":99,"failure_reason":null}
EOF_STATUS
        fi
        exit 0
        ;;
    run)
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
        export HOME='$HOME'
        export XDG_CONFIG_HOME='$XDG_CONFIG_HOME'
        export XDG_DATA_HOME='$XDG_DATA_HOME'
        export DOCKER_CALL_LOG='$DOCKER_CALL_LOG'
        source '$REPO_ROOT/lib/config.sh'
        source '$REPO_ROOT/lib/preflight.sh'
        source '$REPO_ROOT/lib/runs.sh'
        source '$REPO_ROOT/lib/launcher.sh'
        pal_preflight_gh_auth() { :; }
        pal_preflight_all 'owner/repo' 42
        run_id=\$(pal_new_run_id)
        pal_write_launch_meta \"\$run_id\" owner/repo 42 implement sync
        pal_launch_sync implement owner/repo 42 /tmp/host-repo \"\$run_id\" > /dev/null
        pal_render_status_summary \"\$run_id\"
    "
    assert_success
    assert_output --partial "success"
    assert_output --partial "https://github.com/x/y/pull/99"
}

@test "pal-implement syncs memory and container rules via docker cp before exec" {
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"

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
        pal_preflight_all 'owner/repo' 42
        run_id=\$(pal_new_run_id)
        pal_write_launch_meta \"\$run_id\" owner/repo 42 implement sync
        pal_launch_sync implement owner/repo 42 /tmp/host-repo \"\$run_id\" > /dev/null
    "
    assert_success

    # At least one docker cp must fire (memory sync + container-CLAUDE.md sync).
    run grep -E "^cp " "$DOCKER_CALL_LOG"
    assert_success

    # The container-rules sync must target /home/agent/.claude/CLAUDE.md.
    run grep -E "^cp .*CLAUDE.md" "$DOCKER_CALL_LOG"
    assert_success

    # The pipeline exec must run after the cp calls.
    first_cp=$(grep -n "^cp " "$DOCKER_CALL_LOG" | head -1 | cut -d: -f1)
    first_exec_pipeline=$(grep -n "^exec .*run-pipeline.sh" "$DOCKER_CALL_LOG" | head -1 | cut -d: -f1)
    [ -n "$first_cp" ]
    [ -n "$first_exec_pipeline" ]
    [ "$first_cp" -lt "$first_exec_pipeline" ]

    # Pipeline is invoked with the new 3-arg run-pipeline.sh signature
    # (event_type, repo, number) — not the old 3-arg docker run form.
    run grep -E "^exec .*run-pipeline.sh implement owner/repo 42" "$DOCKER_CALL_LOG"
    assert_success
}
