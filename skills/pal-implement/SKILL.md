---
name: pal-implement
description: Use when the user wants pal to actually start working on a GitHub issue. Launches an ephemeral Docker container that reads the plan from the issue and runs a gated pipeline (adversarial plan review → TDD implementation → post-impl review → opens PR). Use when user says "have pal implement this", "kick off pal on issue #N", "dispatch pal", "run the pal container on this issue", or similar. Sync by default; pass --async to background.
---

# pal-implement

Launch a claude-pal container to implement a GitHub issue's posted plan.

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
   . "${CLAUDE_PLUGIN_ROOT}/lib/launcher.sh"
   ```
3. Determine the target repo. If the current working directory is inside a git repo, use its origin remote. Otherwise require `PAL_REPO` env var.
4. Run `pal_preflight_all "$repo" "$issue_num"`. On failure, exit with the preflight's own error.
5. Generate a run id: `run_id=$(pal_new_run_id)`.
6. Write launch meta: `pal_write_launch_meta "$run_id" "$repo" "$issue_num" "implement" "sync"`.
7. Launch: `pal_launch_sync "$run_id" "$repo" "$issue_num" "implement"`. Exit code propagates.
8. After container exits, call `pal_render_status_summary "$run_id"`.

If `--async` flag is given, instead of steps 6-8 use the async path (implemented in Phase 5).

## Examples

- `/pal-implement 42` — launches container synchronously, blocks until done.
- `/pal-implement 42 --async` — launches container in background (requires Phase 5).
