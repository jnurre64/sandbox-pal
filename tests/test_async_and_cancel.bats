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

    export PATH="$TMPHOME/bin:$PATH"
    mkdir -p "$TMPHOME/bin"

    # Write capture-notify with the literal log path baked in
    cat > "$TMPHOME/bin/capture-notify" <<NOTIFY_MOCK
#!/bin/bash
echo "\$1 \$2" >> "$NOTIFY_LOG"
NOTIFY_MOCK
    chmod +x "$TMPHOME/bin/capture-notify"

    # Docker shim: for exec with a RUN_ID, write a fake success status.json
    # to the host runs dir (visible via XDG_DATA_HOME, mirroring the
    # bind-mount at /status inside the real workspace).
    cat > "$TMPHOME/bin/docker" <<'DOCKER_MOCK'
#!/bin/bash
case "$1" in
    info) exit 0 ;;
    inspect) exit 0 ;;
    ps) echo "sandbox-pal-workspace"; exit 0 ;;
    volume|cp|pull|start|stop|rm) exit 0 ;;
    exec)
        run_id=""
        for arg in "$@"; do
            case "$arg" in RUN_ID=*) run_id="${arg#RUN_ID=}" ;; esac
        done
        if [ -n "$run_id" ]; then
            status_dir="${XDG_DATA_HOME:-$HOME/.local/share}/sandbox-pal/runs/$run_id"
            mkdir -p "$status_dir"
            cat > "$status_dir/status.json" <<EOF_STATUS
{"outcome":"success","phase":"complete","pr_url":"https://github.com/x/y/pull/88","pr_number":88,"failure_reason":null,"commits":[],"review_concerns_addressed":[],"review_concerns_unresolved":[]}
EOF_STATUS
        fi
        exit 0
        ;;
    *) exit 0 ;;
esac
DOCKER_MOCK
    chmod +x "$TMPHOME/bin/docker"
}

teardown() {
    rm -rf "$TMPHOME"
}

@test "pal_launch_async records exec_pid and watcher notifies on exit" {
    run bash -c "
        export CLAUDE_PLUGIN_ROOT='$REPO_ROOT'
        export XDG_DATA_HOME='$XDG_DATA_HOME'
        source '$REPO_ROOT/lib/config.sh'
        source '$REPO_ROOT/lib/runs.sh'
        source '$REPO_ROOT/lib/launcher.sh'
        run_id=\$(pal_new_run_id)
        pal_write_launch_meta \"\$run_id\" owner/repo 42 implement async
        pal_launch_async implement owner/repo 42 /tmp/host-repo \"\$run_id\"
        wait
        run_dir=\$(pal_run_dir \"\$run_id\")
        echo \"exec_pid_file:\$([ -f \"\$run_dir/exec_pid\" ] && echo yes || echo no)\"
    "
    assert_success
    assert_output --partial "launched (async"
    assert_output --partial "exec_pid_file:yes"
}

@test "pal_cancel_run writes cancelled status and signals workspace" {
    run bash -c "
        export CLAUDE_PLUGIN_ROOT='$REPO_ROOT'
        export XDG_DATA_HOME='$XDG_DATA_HOME'
        source '$REPO_ROOT/lib/config.sh'
        source '$REPO_ROOT/lib/runs.sh'
        source '$REPO_ROOT/lib/launcher.sh'
        run_id=\$(pal_new_run_id)
        pal_write_launch_meta \"\$run_id\" owner/repo 42 implement async
        run_dir=\$(pal_run_dir \"\$run_id\")
        # Simulate an already-exited exec by writing a dead PID to the file
        echo '99999999' > \"\$run_dir/exec_pid\"
        pal_cancel_run \"\$run_id\"
        jq -r .outcome \"\$run_dir/status.json\"
    "
    assert_success
    assert_output --partial "cancelled"
}
