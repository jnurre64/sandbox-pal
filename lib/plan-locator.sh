# lib/plan-locator.sh
# shellcheck shell=bash
# Locate the implementation plan file to publish.

pal_find_plan_file() {
    local explicit_file="${1:-}"
    if [ -n "$explicit_file" ]; then
        if [ ! -f "$explicit_file" ]; then
            echo "pal: plan file not found: $explicit_file" >&2
            return 1
        fi
        echo "$explicit_file"
        return 0
    fi

    # Auto-detect: most recent file in docs/superpowers/plans/
    local default_dir="docs/superpowers/plans"
    if [ -d "$default_dir" ]; then
        local latest
        # shellcheck disable=SC2012  # sorting by mtime is the goal; `find ... -printf | sort` is heavier
        latest=$(ls -t "$default_dir"/*.md 2>/dev/null | head -1 || true)
        if [ -n "$latest" ]; then
            echo "$latest"
            return 0
        fi
    fi

    echo "pal: could not auto-detect a plan file" >&2
    echo "pal: checked: $default_dir" >&2
    echo "pal: provide a path explicitly via: /pal-plan [issue#] --file <path>" >&2
    return 1
}
