# lib/notify.sh
# shellcheck shell=bash
# Cross-platform desktop notifier.

pal_notify() {
    local title="${1:-sandbox-pal}"
    local message="$2"

    # Honor override
    if [ -n "${PAL_NOTIFY_COMMAND_OVERRIDE:-}" ]; then
        "$PAL_NOTIFY_COMMAND_OVERRIDE" "$title" "$message" && return 0
    fi

    # Respect disable flag
    if [ "${PAL_NOTIFY:-true}" != "true" ]; then
        return 0
    fi

    local host_os
    host_os=$(uname -s)
    case "$host_os" in
        Linux)
            if command -v notify-send > /dev/null 2>&1; then
                notify-send "$title" "$message" || true
            fi
            ;;
        Darwin)
            osascript -e "display notification \"$(printf '%s' "$message" | sed 's/"/\\"/g')\" with title \"$title\"" 2>/dev/null || true
            ;;
        MINGW*|MSYS*|CYGWIN*)
            if command -v powershell.exe > /dev/null 2>&1; then
                powershell.exe -NoProfile -Command "
                    try {
                        Import-Module BurntToast -ErrorAction Stop
                        New-BurntToastNotification -Text '$title', '$(printf '%s' "$message" | sed "s/'/''/g")'
                    } catch {
                        Write-Host 'pal-notify: BurntToast module not installed (Install-Module BurntToast)'
                    }
                " 2>/dev/null || true
            fi
            ;;
    esac
}
