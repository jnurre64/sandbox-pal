---
name: pal-workspace
description: Manage the claude-pal workspace container (start, stop, restart, status, edit-rules).
---

# pal-workspace

Subcommands:

- `start`      — start workspace (or restart if already running)
- `stop`       — graceful stop
- `restart`    — stop + start
- `status`     — print container state + auth state
- `edit-rules` — open `$EDITOR` on `~/.config/claude-pal/container-CLAUDE.md`

```bash
set -euo pipefail
. "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
. "${CLAUDE_PLUGIN_ROOT}/lib/workspace.sh"
. "${CLAUDE_PLUGIN_ROOT}/lib/container-rules.sh"

pal_load_config

case "${1:-status}" in
    start)
        if docker inspect "$PAL_WORKSPACE_NAME" >/dev/null 2>&1 \
            && docker ps --format '{{.Names}}' | grep -Fxq "$PAL_WORKSPACE_NAME"; then
            echo "pal: workspace already running — restarting"
            pal_workspace_restart
        else
            pal_workspace_start
        fi
        pal_workspace_status
        ;;
    stop)       pal_workspace_stop ;;
    restart)    pal_workspace_restart; pal_workspace_status ;;
    status)     pal_workspace_status ;;
    edit-rules) pal_container_rules_edit ;;
    *)          echo "usage: pal-workspace {start|stop|restart|status|edit-rules}" >&2; exit 2 ;;
esac
```
