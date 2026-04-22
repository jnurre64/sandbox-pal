# lib/workspace.sh
# shellcheck shell=bash
# Host-side lifecycle for the long-running claude-pal workspace container.

: "${PAL_WORKSPACE_NAME:=claude-pal-workspace}"
: "${PAL_WORKSPACE_VOLUME:=claude-pal-claude}"
: "${PAL_WORKSPACE_IMAGE:=claude-pal:latest}"

_pal_workspace_exists() {
    docker inspect "$PAL_WORKSPACE_NAME" >/dev/null 2>&1
}

_pal_workspace_is_running() {
    docker ps --format '{{.Names}}' | grep -Fxq "$PAL_WORKSPACE_NAME"
}

pal_workspace_start() {
    if _pal_workspace_is_running; then
        return 0
    fi
    if _pal_workspace_exists; then
        docker start "$PAL_WORKSPACE_NAME" >/dev/null
        return 0
    fi
    docker volume create "$PAL_WORKSPACE_VOLUME" >/dev/null

    # Bind-mount the host runs dir into the container at /status so that
    # run-pipeline.sh (invoked via `docker exec`) can write per-run
    # status.json files to /status/<run-id>/ visible on the host.
    # Requires lib/runs.sh for pal_runs_dir.
    # shellcheck source=/dev/null
    . "${CLAUDE_PLUGIN_ROOT}/lib/runs.sh"
    local runs_dir
    runs_dir="$(pal_runs_dir)"
    mkdir -p "$runs_dir"

    local -a args=(
        run -d
        --name "$PAL_WORKSPACE_NAME"
        --cap-add NET_ADMIN
        --cap-add NET_RAW
        -v "${PAL_WORKSPACE_VOLUME}:/home/agent/.claude"
        -v "${runs_dir}:/status"
    )
    [ -n "${PAL_CPUS:-}" ]   && args+=(--cpus="$PAL_CPUS")
    [ -n "${PAL_MEMORY:-}" ] && args+=(--memory="$PAL_MEMORY")
    args+=("$PAL_WORKSPACE_IMAGE" /opt/pal/workspace-boot.sh)

    docker "${args[@]}" >/dev/null
}

pal_workspace_stop() {
    if _pal_workspace_is_running; then
        docker stop "$PAL_WORKSPACE_NAME" >/dev/null
    fi
}

pal_workspace_restart() {
    pal_workspace_stop
    pal_workspace_start
}

pal_workspace_ensure_running() {
    if _pal_workspace_is_running; then
        return 0
    fi
    echo "pal: workspace stopped — starting…" >&2
    pal_workspace_start
}

pal_workspace_is_authenticated() {
    docker exec "$PAL_WORKSPACE_NAME" \
        test -f /home/agent/.claude/.credentials.json
}

pal_workspace_status() {
    if ! _pal_workspace_exists; then
        echo "workspace: absent (no container named ${PAL_WORKSPACE_NAME})"
        return 0
    fi
    local state
    state="$(docker inspect --format '{{.State.Status}}' "$PAL_WORKSPACE_NAME" 2>/dev/null || echo unknown)"
    echo "workspace: ${PAL_WORKSPACE_NAME} (${state})"
    if [ "$state" = "running" ]; then
        if pal_workspace_is_authenticated; then
            echo "  auth: present"
        else
            echo "  auth: missing — run /pal-login"
        fi
    fi
}
