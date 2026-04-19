# skills/lib/preflight.sh
# shellcheck shell=bash
# Preflight checks run before every dispatch.

pal_preflight_no_api_key_in_env() {
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        echo "pal: ERROR — ANTHROPIC_API_KEY is set in your environment." >&2
        echo "pal: This would silently override your CLAUDE_CODE_OAUTH_TOKEN and bill a Console account." >&2
        echo "pal: Unset it with: unset ANTHROPIC_API_KEY" >&2
        return 1
    fi
}

pal_preflight_single_auth_method() {
    local has_oauth=0 has_api=0
    [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && has_oauth=1
    [ -n "${ANTHROPIC_API_KEY:-}" ] && has_api=1
    local count=$((has_oauth + has_api))
    if [ "$count" -eq 0 ]; then
        echo "pal: ERROR — neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY is set in config.env" >&2
        return 1
    fi
    if [ "$count" -gt 1 ]; then
        echo "pal: ERROR — both CLAUDE_CODE_OAUTH_TOKEN and ANTHROPIC_API_KEY are in config.env" >&2
        echo "pal: Set exactly one. See docs/authentication.md." >&2
        return 1
    fi
}

pal_preflight_docker_reachable() {
    if ! docker info > /dev/null 2>&1; then
        local target="${DOCKER_HOST:-local}"
        echo "pal: ERROR — docker daemon not reachable (DOCKER_HOST=$target)" >&2
        return 1
    fi
}

pal_preflight_windows_bash() {
    local host_os
    host_os=$(uname -s)
    case "$host_os" in
        MINGW*|MSYS*|CYGWIN*)
            local bash_version
            bash_version=$(bash --version | head -1)
            if echo "$bash_version" | grep -qi wsl; then
                echo "pal: ERROR — Claude Code is using WSL's bash, not Git Bash" >&2
                echo "pal: Set CLAUDE_CODE_GIT_BASH_PATH in your Claude Code settings.json:" >&2
                printf 'pal:   {"env": {"CLAUDE_CODE_GIT_BASH_PATH": "C:\\\\Program Files\\\\Git\\\\bin\\\\bash.exe"}}\n' >&2
                return 1
            fi
            ;;
    esac
}

pal_preflight_gh_auth() {
    if [ -z "${GH_TOKEN:-}" ]; then
        echo "pal: ERROR — GH_TOKEN not set in config.env" >&2
        return 1
    fi
    if ! GH_TOKEN="$GH_TOKEN" gh auth status > /dev/null 2>&1; then
        echo "pal: WARN — gh auth status failed with configured token" >&2
        # Non-fatal: some PATs return 200 but fail auth status; let the container try
    fi
}

pal_preflight_issue_not_in_flight() {
    local repo="$1"
    local number="$2"
    local lock
    lock="$(pal_runs_dir)/.lock-${repo//\//_}-${number}"
    if [ -f "$lock" ]; then
        local existing_run
        existing_run=$(cat "$lock")
        echo "pal: ERROR — another run is already in flight for $repo#$number (run $existing_run)" >&2
        echo "pal: Use '/pal-status $existing_run' to check its state, or '/pal-cancel $existing_run' to kill it" >&2
        return 1
    fi
}

pal_preflight_all() {
    local repo="${1:-}"
    local number="${2:-}"

    pal_preflight_no_api_key_in_env &&
    pal_load_config &&
    pal_config_permissions_ok &&
    pal_preflight_single_auth_method &&
    pal_preflight_docker_reachable &&
    pal_preflight_windows_bash &&
    pal_preflight_gh_auth || return 1

    if [ -n "$repo" ] && [ -n "$number" ]; then
        pal_preflight_issue_not_in_flight "$repo" "$number" || return 1
    fi
}
