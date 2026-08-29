# lib/memory-sync.sh
# shellcheck shell=bash
# Sync host memory (Claude Code Auto Memory markdown) into the workspace
# container for a given run.

# shellcheck source=/dev/null
. "${CLAUDE_PLUGIN_ROOT}/lib/workspace.sh"

pal_memory_slug() {
    # Claude Code Auto Memory encodes a literal absolute path by replacing
    # every `/` with `-`. /home/jonny → -home-jonny.
    local path="$1"
    printf '%s\n' "${path//\//-}"
}

# pal_memory_sync_to_container <host-repo-path> <container-workdir>
#
# One-way sync of Claude Code Auto Memory markdown from the host into the
# workspace container at /home/agent/memory/<host-slug>/ — a directory the
# container's claude does NOT auto-load or write. The runner injects its
# MEMORY.md via --append-system-prompt and exposes the files with --add-dir
# (see image/opt/pal/lib/claude-runner.sh: load_shared_memory). The copy is
# root-owned and go=rX so the unprivileged agent user cannot modify it or
# chmod it back; phases propose changes via .agent-data/memory-proposals/.
#
# On success exports AGENT_MEMORY_DIR (read by _pal_launcher_env_args).
# <container-workdir> is accepted for call-site compatibility and unused.
#
# *.jsonl transcripts are excluded by default (secret-tier). Set
# PAL_SYNC_TRANSCRIPTS=true to include them (not recommended).
pal_memory_sync_to_container() {
    local host_repo="$1"
    # shellcheck disable=SC2034  # kept for call-site compatibility
    local container_workdir="${2:-}"

    [ "${PAL_SYNC_MEMORIES:-true}" = "true" ] || return 0

    local host_slug host_dir container_dir
    host_slug="$(pal_memory_slug "$host_repo")"
    host_dir="${HOME}/.claude/projects/${host_slug}/memory"
    container_dir="/home/agent/memory/${host_slug}"

    [ -d "$host_dir" ] || return 0

    # The previous run's copy is root-owned: remove and recreate as root.
    docker exec -u root "$PAL_WORKSPACE_NAME" \
        rm -rf "$container_dir" >/dev/null 2>&1 || true
    docker exec -u root "$PAL_WORKSPACE_NAME" \
        mkdir -p "$container_dir" >/dev/null

    # Stage a filtered copy so the docker cp payload never contains *.jsonl
    # unless the user opted in.
    local staging
    staging="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$staging'" RETURN

    if [ "${PAL_SYNC_TRANSCRIPTS:-false}" = "true" ]; then
        cp -r "$host_dir/." "$staging/"
    else
        (
            cd "$host_dir" || exit 0
            find . -type f \! -name '*.jsonl' -print0 \
                | xargs -0 -I{} cp --parents {} "$staging/"
        )
    fi

    docker cp "$staging/." "${PAL_WORKSPACE_NAME}:${container_dir}"

    # Read-only to the agent user (docker cp lands files as root already;
    # make it explicit and strip any group/other write bits from the host).
    docker exec -u root "$PAL_WORKSPACE_NAME" \
        chown -R root:root "$container_dir" >/dev/null
    docker exec -u root "$PAL_WORKSPACE_NAME" \
        chmod -R u=rwX,go=rX "$container_dir" >/dev/null

    AGENT_MEMORY_DIR="$container_dir"
    export AGENT_MEMORY_DIR
}
