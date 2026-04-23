---
name: pal-logs
description: Tail logs for a sandbox-pal run. Supports --follow to stream live output.
---

# pal-logs

## Usage

```
/pal-logs <run_id> [--follow]
```

## Steps

1. Source shared libs:
   ```bash
   . "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/runs.sh"
   ```
2. Compute `log_file="$(pal_run_dir "$run_id")/log"`.
3. If file does not exist, report error and exit 1.
4. If `--follow` flag given: `tail -f "$log_file"`.
5. Else: `cat "$log_file"`.
