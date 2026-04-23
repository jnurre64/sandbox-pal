# lib/launcher.sh
# shellcheck shell=bash
# Backend adapter: launches the pipeline inside the long-running claude-pal
# workspace container via `docker exec`. Requires the workspace to be running
# and authenticated (enforced upstream by preflight). Memory and
# container-CLAUDE.md are synced before exec.

# _pal_launcher_env_args
#
# Build the `-e` flag array for docker exec. Emits GH_TOKEN and RUN_ID, plus
# any AGENT_TEST_*/PAL_ALLOWLIST_EXTRA_DOMAINS env vars that are set, plus
# any AGENT_/PAL_/DOCKER_HOST= lines from per-repo .pal/config.env (cwd).
#
# Usage: _pal_launcher_env_args <run_id> <out_array_name>
_pal_launcher_env_args() {
    local run_id="$1"
    local -n _out="$2"

    _out=(-e "GH_TOKEN=${GH_TOKEN:?}" -e "RUN_ID=${run_id}")
    [ -n "${AGENT_TEST_COMMAND:-}" ]          && _out+=(-e "AGENT_TEST_COMMAND=${AGENT_TEST_COMMAND}")
    [ -n "${AGENT_TEST_SETUP_COMMAND:-}" ]    && _out+=(-e "AGENT_TEST_SETUP_COMMAND=${AGENT_TEST_SETUP_COMMAND}")
    [ -n "${PAL_ALLOWLIST_EXTRA_DOMAINS:-}" ] && _out+=(-e "PAL_ALLOWLIST_EXTRA_DOMAINS=${PAL_ALLOWLIST_EXTRA_DOMAINS}")

    # Per-repo config (if present in current working directory's .pal/). Users
    # rely on this for AGENT_TEST_COMMAND etc. set per-project.
    local per_repo_config=".pal/config.env"
    if [ -f "$per_repo_config" ]; then
        local per_repo_env
        per_repo_env=$(grep -E '^(AGENT_|PAL_|DOCKER_HOST=)' "$per_repo_config" | grep -v '^#' || true)
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            _out+=(-e "$line")
        done <<< "$per_repo_env"
    fi
}

# pal_launch_sync <event-type> <repo> <number> <host-repo-path> <run-id>
#
# Runs the pipeline inside the workspace container via `docker exec`, in the
# foreground, tee-ing combined output to the run's log file. Exit code of the
# in-container pipeline is returned.
pal_launch_sync() {
    local event_type="$1"
    local repo="$2"
    local number="$3"
    local host_repo_path="$4"
    local run_id="$5"

    # shellcheck source=/dev/null
    . "${CLAUDE_PLUGIN_ROOT}/lib/workspace.sh"
    # shellcheck source=/dev/null
    . "${CLAUDE_PLUGIN_ROOT}/lib/memory-sync.sh"
    # shellcheck source=/dev/null
    . "${CLAUDE_PLUGIN_ROOT}/lib/container-rules.sh"

    pal_workspace_ensure_running

    local container_workdir="/home/agent/work/${run_id}"
    pal_memory_sync_to_container "$host_repo_path" "$container_workdir"
    pal_container_rules_sync_to_container

    local run_dir
    run_dir=$(pal_run_dir "$run_id")
    mkdir -p "$run_dir"
    touch "$run_dir/log"
    chmod 0666 "$run_dir/log" 2>/dev/null || true

    local -a env_args=()
    _pal_launcher_env_args "$run_id" env_args

    pal_acquire_lock "$run_id" "$repo" "$number"

    local exit_code=0
    docker exec "${env_args[@]}" "$PAL_WORKSPACE_NAME" \
        /opt/pal/run-pipeline.sh "$event_type" "$repo" "$number" \
        2>&1 | tee -a "$run_dir/log" || exit_code=$?

    pal_release_lock "$repo" "$number"
    return $exit_code
}

# pal_launch_async <event-type> <repo> <number> <host-repo-path> <run-id>
#
# Runs the pipeline inside the workspace container via `docker exec` in the
# background. Records the host-side PID of the docker exec process to
# $run_dir/exec_pid. Forks a watcher that waits for the exec to exit, then
# reads status.json and sends a desktop notification.
pal_launch_async() {
    local event_type="$1"
    local repo="$2"
    local number="$3"
    local host_repo_path="$4"
    local run_id="$5"

    # shellcheck source=/dev/null
    . "${CLAUDE_PLUGIN_ROOT}/lib/workspace.sh"
    # shellcheck source=/dev/null
    . "${CLAUDE_PLUGIN_ROOT}/lib/memory-sync.sh"
    # shellcheck source=/dev/null
    . "${CLAUDE_PLUGIN_ROOT}/lib/container-rules.sh"

    pal_workspace_ensure_running

    local container_workdir="/home/agent/work/${run_id}"
    pal_memory_sync_to_container "$host_repo_path" "$container_workdir"
    pal_container_rules_sync_to_container

    local run_dir
    run_dir=$(pal_run_dir "$run_id")
    mkdir -p "$run_dir"
    touch "$run_dir/log"
    chmod 0666 "$run_dir/log" 2>/dev/null || true

    local -a env_args=()
    _pal_launcher_env_args "$run_id" env_args

    pal_acquire_lock "$run_id" "$repo" "$number"

    # Run docker exec detached in the background; capture its host PID.
    # stdout/stderr go straight to the run log.
    docker exec "${env_args[@]}" "$PAL_WORKSPACE_NAME" \
        /opt/pal/run-pipeline.sh "$event_type" "$repo" "$number" \
        >> "$run_dir/log" 2>&1 &
    local exec_pid=$!
    echo "$exec_pid" > "$run_dir/exec_pid"

    # Fork a watcher: wait for the exec to exit, release the lock, notify.
    (
        # shellcheck source=/dev/null
        . "${CLAUDE_PLUGIN_ROOT}/lib/notify.sh"
        # shellcheck source=/dev/null
        . "${CLAUDE_PLUGIN_ROOT}/lib/runs.sh"
        wait "$exec_pid" 2>/dev/null || true
        pal_release_lock "$repo" "$number"
        if [ -f "$run_dir/status.json" ]; then
            local outcome pr_url
            outcome=$(jq -r .outcome "$run_dir/status.json" 2>/dev/null)
            pr_url=$(jq -r .pr_url "$run_dir/status.json" 2>/dev/null)
            case "$outcome" in
                success)
                    pal_notify "claude-pal: $run_id complete" "PR: $pr_url"
                    ;;
                *)
                    pal_notify "claude-pal: $run_id $outcome" "Check /pal-status $run_id"
                    ;;
            esac
        else
            pal_notify "claude-pal: $run_id exited" "No status.json — check /pal-logs $run_id"
        fi
    ) &

    echo "Run $run_id launched (async, pid $exec_pid)"
    echo "  Status: /pal-status $run_id"
    echo "  Logs:   /pal-logs $run_id --follow"
}

# pal_cancel_run <run_id>
#
# Sends SIGTERM to the host-side docker exec process (propagates through docker
# to the in-container pipeline). Writes a cancelled status.json for the run
# and releases any issue-in-flight lock.
pal_cancel_run() {
    local run_id="$1"
    local run_dir
    run_dir=$(pal_run_dir "$run_id")
    local pid_file="$run_dir/exec_pid"

    if [ -f "$pid_file" ]; then
        local exec_pid
        exec_pid=$(cat "$pid_file")
        if [ -n "$exec_pid" ] && kill -0 "$exec_pid" 2>/dev/null; then
            echo "pal: sending SIGTERM to docker exec pid $exec_pid (grace 10s)"
            kill -TERM "$exec_pid" 2>/dev/null || true
            local i=0
            while kill -0 "$exec_pid" 2>/dev/null && [ $i -lt 10 ]; do
                sleep 1
                i=$((i + 1))
            done
            if kill -0 "$exec_pid" 2>/dev/null; then
                kill -KILL "$exec_pid" 2>/dev/null || true
            fi
        fi
    else
        echo "pal: no exec_pid recorded for run $run_id (already exited?)" >&2
    fi

    # Belt-and-suspenders: ask the workspace to pkill any lingering
    # run-pipeline.sh processes. Safe because only one pipeline can be active
    # in the workspace at a time per current design.
    # shellcheck source=/dev/null
    . "${CLAUDE_PLUGIN_ROOT}/lib/workspace.sh"
    docker exec "$PAL_WORKSPACE_NAME" \
        pkill -TERM -f "run-pipeline.sh" >/dev/null 2>&1 || true

    # Write a cancelled status (overrides whatever the pipeline may have left)
    cat > "$run_dir/status.json" <<EOF_CANCEL
{
  "phase": "cancelled",
  "outcome": "cancelled",
  "failure_reason": "user_cancelled",
  "pr_number": null,
  "pr_url": null,
  "commits": [],
  "review_concerns_addressed": [],
  "review_concerns_unresolved": []
}
EOF_CANCEL

    # Release lock if meta exists
    if [ -f "$run_dir/launch_meta.json" ]; then
        local repo number
        repo=$(jq -r .repo "$run_dir/launch_meta.json")
        number=$(jq -r '.issue_number // .pr_number' "$run_dir/launch_meta.json")
        pal_release_lock "$repo" "$number"
    fi

    echo "pal: run $run_id cancelled"
}

pal_render_status_summary() {
    local run_id="$1"
    local run_dir
    run_dir=$(pal_run_dir "$run_id")
    local status_file="$run_dir/status.json"

    if [ ! -f "$status_file" ]; then
        echo "pal: no status.json found at $status_file" >&2
        return 1
    fi

    local outcome phase pr_url failure_reason
    outcome=$(jq -r .outcome "$status_file")
    phase=$(jq -r .phase "$status_file")
    pr_url=$(jq -r .pr_url "$status_file")
    failure_reason=$(jq -r .failure_reason "$status_file")

    case "$outcome" in
        success)
            printf '✓ claude-pal run %s: success\n' "$run_id"
            printf '  PR opened: %s\n' "$pr_url"
            ;;
        clarification_needed)
            printf '? claude-pal run %s: clarification needed\n' "$run_id"
            printf '  Respond on the issue, then re-run /pal-implement\n'
            ;;
        review_concerns_unresolved)
            printf '⚠ claude-pal run %s: post-impl review concerns unresolved\n' "$run_id"
            printf '  Review the branch manually. Concerns:\n'
            jq -r '.review_concerns_unresolved[]' "$status_file" | sed 's/^/    - /'
            ;;
        failure)
            printf '✗ claude-pal run %s: failed at phase %s\n' "$run_id" "$phase"
            printf '  Reason: %s\n' "$failure_reason"
            printf '  Log: %s/log\n' "$run_dir"
            ;;
        cancelled)
            printf '✗ claude-pal run %s: cancelled\n' "$run_id"
            ;;
        *)
            printf '? claude-pal run %s: unknown outcome "%s"\n' "$run_id" "$outcome"
            ;;
    esac
}
