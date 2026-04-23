# skills/lib/runs.sh
# shellcheck shell=bash
# Run registry: directory layout, run id generation, reconciliation.

pal_runs_dir() {
    local host_os
    host_os=$(uname -s)
    case "$host_os" in
        Linux|Darwin)
            echo "${XDG_DATA_HOME:-$HOME/.local/share}/sandbox-pal/runs"
            ;;
        MINGW*|MSYS*|CYGWIN*)
            local local_app
            local_app=$(cygpath -u "$LOCALAPPDATA" 2>/dev/null || echo "$LOCALAPPDATA")
            echo "$local_app/sandbox-pal/runs"
            ;;
    esac
}

pal_new_run_id() {
    printf '%s-%s' "$(date +%Y-%m-%d-%H%M)" "$(head /dev/urandom | LC_ALL=C tr -dc 'a-z0-9' | head -c 6)"
}

pal_run_dir() {
    local run_id="$1"
    echo "$(pal_runs_dir)/$run_id"
}

pal_write_launch_meta() {
    local run_id="$1"
    local repo="$2"
    local number="$3"
    local event_type="$4"
    local mode="$5"
    local run_dir
    run_dir=$(pal_run_dir "$run_id")
    mkdir -p "$run_dir"
    cat > "$run_dir/launch_meta.json" <<EOF_META
{
  "run_id": "$run_id",
  "event_type": "$event_type",
  "repo": "$repo",
  "issue_number": $([ "$event_type" = "implement" ] && echo "$number" || echo "null"),
  "pr_number": $([ "$event_type" = "revise" ] && echo "$number" || echo "null"),
  "mode": "$mode",
  "started_at": "$(date -u +%FT%TZ)",
  "host_os": "$(uname -s)",
  "backend": "${PAL_BACKEND:-docker-linux}",
  "docker_host": $([ -n "${DOCKER_HOST:-}" ] && printf '"%s"' "$DOCKER_HOST" || echo null),
  "image_tag": "${PAL_IMAGE_TAG:-sandbox-pal:latest}"
}
EOF_META
}

pal_acquire_lock() {
    local run_id="$1"
    local repo="$2"
    local number="$3"
    local lock
    lock="$(pal_runs_dir)/.lock-${repo//\//_}-${number}"
    echo "$run_id" > "$lock"
}

pal_release_lock() {
    local repo="$1"
    local number="$2"
    local lock
    lock="$(pal_runs_dir)/.lock-${repo//\//_}-${number}"
    rm -f "$lock"
}
