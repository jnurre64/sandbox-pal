---
name: pal-implement
description: Use when the user wants pal to actually start working on a GitHub issue. Dispatches a pipeline (adversarial plan review → TDD implementation → post-impl review → opens PR) inside the long-running sandbox-pal workspace container. Use when user says "have pal implement this", "kick off pal on issue #N", "dispatch pal", "run the pal container on this issue", or similar. Sync by default; pass --async to background.
---

# pal-implement

Dispatch the sandbox-pal pipeline to implement a GitHub issue's posted plan.

## Usage

```
/pal-implement <issue#> [--async]
```

## Steps

1. Parse arguments. Require exactly one positional argument (issue number); `--async` flag is optional.
2. Source the shared libs (`${CLAUDE_PLUGIN_ROOT}` is set by Claude Code when the skill fires):
   ```bash
   . "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/preflight.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/runs.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/workspace.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/memory-sync.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/container-rules.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/launcher.sh"
   ```
3. Determine the target repo. If the current working directory is inside a git repo, use its origin remote. Otherwise require `PAL_REPO` env var.
4. Derive the host repo path: `HOST_REPO_PATH="$(git -C . rev-parse --show-toplevel)"` (required so memory-sync can locate the host's Auto Memory dir).
5. Run `pal_preflight_all "$repo" "$issue_num"`. On failure, exit with the preflight's own error.
6. Generate a run id: `run_id=$(pal_new_run_id)`.
7. Write launch meta: `pal_write_launch_meta "$run_id" "$repo" "$issue_num" "implement" "${mode}"` where `mode` is `async` or `sync`.
8. If `--async` flag given:
   - `pal_launch_async implement "$repo" "$issue_num" "$HOST_REPO_PATH" "$run_id"`
   - Return immediately; skip status summary step.
   Otherwise:
   - `pal_launch_sync implement "$repo" "$issue_num" "$HOST_REPO_PATH" "$run_id"` (exit code propagates)
   - `pal_render_status_summary "$run_id"`

## Examples

- `/pal-implement 42` — launches container synchronously, blocks until done.
- `/pal-implement 42 --async` — launches container in background, notifies on completion.
