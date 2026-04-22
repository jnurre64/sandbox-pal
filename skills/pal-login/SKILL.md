---
name: pal-login
description: Mint Claude credentials inside the workspace container via `claude /login`.
---

# pal-login

Runs the interactive `claude /login` flow inside the workspace. Auto-starts
the workspace if stopped. Requires a TTY.

```bash
set -euo pipefail
. "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
. "${CLAUDE_PLUGIN_ROOT}/lib/workspace.sh"

pal_load_config
pal_workspace_ensure_running

docker exec -it "$PAL_WORKSPACE_NAME" claude /login
```
