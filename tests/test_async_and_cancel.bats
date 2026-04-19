#!/usr/bin/env bats
load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    TMPHOME="$(mktemp -d)"
    export HOME="$TMPHOME"
    export XDG_CONFIG_HOME="$TMPHOME/.config"
    export XDG_DATA_HOME="$TMPHOME/.local/share"
    export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-fake
    export GH_TOKEN=github_pat_fake
    unset ANTHROPIC_API_KEY

    NOTIFY_LOG="$TMPHOME/notify.log"
    export PAL_NOTIFY_COMMAND_OVERRIDE="$TMPHOME/bin/capture-notify"
    # DOCKER_PS_RUNNING controls whether docker ps returns the fake CID
    export DOCKER_PS_RUNNING=true

    export PATH="$TMPHOME/bin:$PATH"
    mkdir -p "$TMPHOME/bin"

    # Write capture-notify with the literal log path baked in
    cat > "$TMPHOME/bin/capture-notify" <<NOTIFY_MOCK
#!/bin/bash
echo "\$1 \$2" >> "$NOTIFY_LOG"
NOTIFY_MOCK
    chmod +x "$TMPHOME/bin/capture-notify"

    cat > "$TMPHOME/bin/docker" <<'DOCKER_MOCK'
#!/bin/bash
case "$1" in
    info) exit 0 ;;
    run)
        # Locate -v <path>:/status argument
        status_dir=""
        prev=""
        for arg in "$@"; do
            if [ "$prev" = "-v" ]; then
                status_dir="${arg%%:*}"
            fi
            prev="$arg"
        done
        if echo "$*" | grep -q -- '--detach'; then
            if [ -n "$status_dir" ] && [ -d "$status_dir" ]; then
                cat > "$status_dir/status.json" <<EOF_STATUS
{"outcome":"success","phase":"complete","pr_url":"https://github.com/x/y/pull/88","pr_number":88,"failure_reason":null,"commits":[],"review_concerns_addressed":[],"review_concerns_unresolved":[]}
EOF_STATUS
            fi
            echo "abc123deadbeef"
        else
            if [ -n "$status_dir" ] && [ -d "$status_dir" ]; then
                cat > "$status_dir/status.json" <<EOF_STATUS
{"outcome":"success","phase":"complete","pr_url":"https://github.com/x/y/pull/99","pr_number":99,"failure_reason":null,"commits":[],"review_concerns_addressed":[],"review_concerns_unresolved":[]}
EOF_STATUS
            fi
            exit 0
        fi
        ;;
    wait) exit 0 ;;
    logs) echo "container log output"; exit 0 ;;
    ps)
        cid_filter=""
        for arg in "$@"; do
            case "$arg" in id=*) cid_filter="${arg#id=}" ;; esac
        done
        if [ "$cid_filter" = "abc123deadbeef" ] && [ "${DOCKER_PS_RUNNING:-true}" = "true" ]; then
            echo "abc123deadbeef"
        fi
        exit 0
        ;;
    stop) exit 0 ;;
    *) exit 1 ;;
esac
DOCKER_MOCK
    chmod +x "$TMPHOME/bin/docker"
}

teardown() {
    rm -rf "$TMPHOME"
}

@test "pal_launch_async records container_id and watcher writes log" {
    run bash -c "
        export CLAUDE_PLUGIN_ROOT='$REPO_ROOT'
        source '$REPO_ROOT/lib/config.sh'
        source '$REPO_ROOT/lib/runs.sh'
        source '$REPO_ROOT/lib/launcher.sh'
        run_id=\$(pal_new_run_id)
        pal_write_launch_meta \"\$run_id\" owner/repo 42 implement async
        pal_launch_async \"\$run_id\" owner/repo 42 implement
        wait
        run_dir=\$(pal_run_dir \"\$run_id\")
        echo \"cid:\$(cat \"\$run_dir/container_id\")\"
        echo \"log_exists:\$([ -f \"\$run_dir/log\" ] && echo yes || echo no)\"
    "
    assert_success
    assert_output --partial "launched (async"
    assert_output --partial "cid:abc123deadbeef"
    assert_output --partial "log_exists:yes"
}

@test "pal_cancel_run stops container and writes cancelled status" {
    run bash -c "
        export CLAUDE_PLUGIN_ROOT='$REPO_ROOT'
        source '$REPO_ROOT/lib/config.sh'
        source '$REPO_ROOT/lib/runs.sh'
        source '$REPO_ROOT/lib/launcher.sh'
        run_id=\$(pal_new_run_id)
        pal_write_launch_meta \"\$run_id\" owner/repo 42 implement async
        run_dir=\$(pal_run_dir \"\$run_id\")
        echo 'abc123deadbeef' > \"\$run_dir/container_id\"
        pal_cancel_run \"\$run_id\"
        jq -r .outcome \"\$run_dir/status.json\"
    "
    assert_success
    assert_output --partial "cancelled"
}
