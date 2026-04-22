# lib/container-rules.sh
# shellcheck shell=bash
# Manage the host file that becomes the container's
# /home/agent/.claude/CLAUDE.md — user-configurable rules synced into the
# workspace container before each run.

# shellcheck source=/dev/null
. "${CLAUDE_PLUGIN_ROOT}/lib/workspace.sh"

pal_container_rules_path() {
    local base="${XDG_CONFIG_HOME:-$HOME/.config}"
    printf '%s/claude-pal/container-CLAUDE.md\n' "$base"
}

pal_container_rules_ensure() {
    local path
    path="$(pal_container_rules_path)"
    if [ ! -f "$path" ]; then
        mkdir -p "$(dirname "$path")"
        : > "$path"
    fi
}

pal_container_rules_sync_to_container() {
    local path
    path="$(pal_container_rules_path)"
    [ -f "$path" ] || return 0
    docker cp "$path" "${PAL_WORKSPACE_NAME}:/home/agent/.claude/CLAUDE.md"
}

pal_container_rules_edit() {
    pal_container_rules_ensure
    local path editor
    path="$(pal_container_rules_path)"
    editor="${EDITOR:-vi}"
    "$editor" "$path"
}
