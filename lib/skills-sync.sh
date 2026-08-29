# lib/skills-sync.sh
# shellcheck shell=bash
# Opt-in, by-name sync of host Claude Code skills into the workspace
# container. Nothing inherits silently: PAL_SYNC_SKILLS (comma-separated
# directory names under ~/.claude/skills/) is empty by default.

# shellcheck source=/dev/null
. "${CLAUDE_PLUGIN_ROOT}/lib/workspace.sh"

# pal_skills_sync_to_container
#
# For each name in PAL_SYNC_SKILLS: remove the container copy (so host
# deletions propagate), stage a dereferenced copy (host skills are often
# symlinks into per-skill repos), docker cp it to
# /home/agent/.claude/skills/<name>. Missing names warn and are skipped.
pal_skills_sync_to_container() {
    local names="${PAL_SYNC_SKILLS:-}"
    [ -n "$names" ] || return 0

    local host_skills="${HOME}/.claude/skills"
    local container_skills="/home/agent/.claude/skills"

    local staging
    staging="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$staging'" RETURN

    docker exec "$PAL_WORKSPACE_NAME" mkdir -p "$container_skills" >/dev/null

    local name
    local -a _names
    IFS=',' read -ra _names <<< "$names"
    for name in "${_names[@]}"; do
        name="${name#"${name%%[![:space:]]*}"}"   # ltrim
        name="${name%"${name##*[![:space:]]}"}"   # rtrim
        [ -n "$name" ] || continue
        if [ ! -d "$host_skills/$name" ]; then
            echo "pal: skill '$name' not found under ~/.claude/skills — skipped" >&2
            continue
        fi
        rm -rf "${staging:?}/$name"
        cp -rL "$host_skills/$name" "$staging/$name"
        docker exec "$PAL_WORKSPACE_NAME" rm -rf "$container_skills/$name" >/dev/null 2>&1 || true
        docker cp "$staging/$name" "${PAL_WORKSPACE_NAME}:${container_skills}/${name}"
    done
    return 0
}
