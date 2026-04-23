---
name: pal-cancel
description: Cancel an in-flight sandbox-pal run. Sends SIGTERM (10s grace) then SIGKILL.
---

# pal-cancel

## Usage

```
/pal-cancel <run_id>
```

## Steps

1. Source shared libs:
   ```bash
   . "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/runs.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/launcher.sh"
   ```
2. Call `pal_cancel_run "$run_id"`.
