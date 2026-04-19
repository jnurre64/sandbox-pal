# skills/lib/launcher.sh
# shellcheck shell=bash
# Backend adapter: launches the container via docker run.

pal_launch_sync() {
    local run_id="$1"
    local repo="$2"
    local number="$3"
    local event_type="$4"   # implement or revise

    local run_dir
    run_dir=$(pal_run_dir "$run_id")
    local image_tag="${PAL_IMAGE_TAG:-claude-pal:latest}"

    # Make the bind-mounted status dir writable by the container's non-root
    # agent user (UID differs from host on Linux). See note above.
    chmod 0777 "$run_dir"

    # Per-repo config (if present in current working directory's .pal/)
    local per_repo_config=".pal/config.env"
    local per_repo_args=()
    if [ -f "$per_repo_config" ]; then
        # Source, then translate each PAL_-namespaced or AGENT_-namespaced variable into -e args
        # (we read, then use `env` to pass through)
        local per_repo_env
        per_repo_env=$(grep -E '^(AGENT_|PAL_|DOCKER_HOST=)' "$per_repo_config" | grep -v '^#' || true)
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            per_repo_args+=(-e "$line")
        done <<< "$per_repo_env"
    fi

    local docker_args=(
        run --rm
        --cap-add=NET_ADMIN
        -e CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"
        -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
        -e GH_TOKEN="$GH_TOKEN"
        -v "$run_dir:/status"
    )
    docker_args+=("${per_repo_args[@]}")
    docker_args+=("$image_tag" "$event_type" "$repo" "$number")

    pal_acquire_lock "$run_id" "$repo" "$number"

    # Pre-create log file world-writable so the container's non-root agent
    # user can also append to it via tee (host tee creates it owned by host
    # user otherwise, blocking container writes).
    touch "$run_dir/log" && chmod 0666 "$run_dir/log"

    # Sync mode: run in foreground, tee to log
    local exit_code=0
    docker "${docker_args[@]}" 2>&1 | tee -a "$run_dir/log" || exit_code=$?

    pal_release_lock "$repo" "$number"
    return $exit_code
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

pal_launch_async() {
    local run_id="$1"
    local repo="$2"
    local number="$3"
    local event_type="$4"

    local run_dir
    run_dir=$(pal_run_dir "$run_id")
    local image_tag="${PAL_IMAGE_TAG:-claude-pal:latest}"

    local per_repo_config=".pal/config.env"
    local per_repo_args=()
    if [ -f "$per_repo_config" ]; then
        local per_repo_env
        per_repo_env=$(grep -E '^(AGENT_|PAL_|DOCKER_HOST=)' "$per_repo_config" | grep -v '^#' || true)
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            per_repo_args+=(-e "$line")
        done <<< "$per_repo_env"
    fi

    local docker_args=(
        run --rm --detach
        --cap-add=NET_ADMIN
        -e CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"
        -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
        -e GH_TOKEN="$GH_TOKEN"
        -v "$run_dir:/status"
    )
    docker_args+=("${per_repo_args[@]}")
    docker_args+=("$image_tag" "$event_type" "$repo" "$number")

    pal_acquire_lock "$run_id" "$repo" "$number"

    local cid
    cid=$(docker "${docker_args[@]}")
    echo "$cid" > "$run_dir/container_id"

    # Fork watcher: wait for container exit, then notify
    (
        # shellcheck source=/dev/null
        source "$(dirname "${BASH_SOURCE[0]}")/notify.sh"
        # shellcheck source=/dev/null
        source "$(dirname "${BASH_SOURCE[0]}")/runs.sh"
        docker wait "$cid" > /dev/null 2>&1 || true
        # Harvest final logs (best-effort)
        docker logs "$cid" > "$run_dir/log" 2>&1 || true
        # Release lock
        pal_release_lock "$repo" "$number"
        # Read status and notify
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

    echo "Run $run_id launched (async, container $cid)"
    echo "  Status: /pal-status $run_id"
    echo "  Logs:   /pal-logs $run_id --follow"
}
