---
name: pal-status
description: List sandbox-pal runs or show details on a specific one. Reconciles stale status against docker ps.
---

# pal-status

## Usage

```
/pal-status [run_id] [--clean [days]]
```

## Steps

1. Source shared libs:
   ```bash
   . "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/runs.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/status-list.sh"
   ```
2. If `--clean` given: `pal_clean_runs "${days:-30}"`. Exit.
3. If `run_id` given: `pal_show_run "$run_id"`.
4. Otherwise: `pal_list_runs`.
