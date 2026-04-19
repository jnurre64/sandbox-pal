# skills/lib/config.sh
# shellcheck shell=bash
# Resolve and load the claude-pal host config.
# Returns config values via stdout or sets variables depending on caller.

pal_config_path() {
    local host_os
    host_os=$(uname -s)
    case "$host_os" in
        Linux|Darwin)
            echo "${XDG_CONFIG_HOME:-$HOME/.config}/claude-pal/config.env"
            ;;
        MINGW*|MSYS*|CYGWIN*)
            # Git Bash on Windows
            local local_app
            local_app=$(cygpath -u "$LOCALAPPDATA" 2>/dev/null || echo "$LOCALAPPDATA")
            echo "$local_app/claude-pal/config.env"
            ;;
        *)
            echo "${XDG_CONFIG_HOME:-$HOME/.config}/claude-pal/config.env"
            ;;
    esac
}

pal_load_config() {
    local path
    path=$(pal_config_path)
    if [ ! -f "$path" ]; then
        echo "pal: config file not found at $path" >&2
        echo "pal: run 'pal-setup' or create the file manually — see docs/install.md" >&2
        return 1
    fi
    # shellcheck source=/dev/null
    . "$path"
}

pal_config_permissions_ok() {
    local path
    path=$(pal_config_path)
    local host_os
    host_os=$(uname -s)
    case "$host_os" in
        Linux|Darwin)
            local perms
            perms=$(stat -c '%a' "$path" 2>/dev/null || stat -f '%A' "$path" 2>/dev/null)
            if [ "$perms" != "600" ]; then
                echo "pal: config file $path has permissions $perms, expected 600" >&2
                echo "pal: run 'chmod 600 \"$path\"' and retry" >&2
                return 1
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*)
            # Windows: check NTFS ACL via icacls; simplified presence check for v1
            # Full ACL validation is in Task 7.4
            ;;
    esac
}
