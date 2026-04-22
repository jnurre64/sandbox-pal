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

    local -a args=(
        run -d
        --name "$PAL_WORKSPACE_NAME"
        --cap-add NET_ADMIN
        --cap-add NET_RAW
        -v "${PAL_WORKSPACE_VOLUME}:/home/agent/.claude"
    )
    [ -n "${PAL_CPUS:-}" ]   && args+=(--cpus="$PAL_CPUS")
    [ -n "${PAL_MEMORY:-}" ] && args+=(--memory="$PAL_MEMORY")
    args+=("$PAL_WORKSPACE_IMAGE" /opt/pal/workspace-boot.sh)

    docker "${args[@]}" >/dev/null
}
