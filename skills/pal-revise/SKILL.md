---
name: pal-revise
description: Dispatch a focused revision pipeline inside the sandbox-pal workspace container to address PR review feedback. Fetches PR branch and review comments, runs a focused implementation pass to address concerns, pushes new commits to the PR.
---

# pal-revise

## Usage

```
/pal-revise <pr#> [--async]
```

## Steps

1. Parse: exactly one positional PR number; optional `--async`.
2. Source shared libs:
   ```bash
   . "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/preflight.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/runs.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/workspace.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/memory-sync.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/container-rules.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/launcher.sh"
   ```
3. Determine repo from cwd git origin or `PAL_REPO`.
4. Derive the host repo path: `HOST_REPO_PATH="$(git -C . rev-parse --show-toplevel)"` (required so memory-sync can locate the host's Auto Memory dir).
5. Run `pal_preflight_all "$repo" "$pr_num"`.
6. Generate run id and write launch meta: `pal_write_launch_meta "$run_id" "$repo" "$pr_num" "revise" "$mode"`.
7. Launch with the new 5-arg launcher signature, passing `revise` as the event_type:
   - Sync: `pal_launch_sync revise "$repo" "$pr_num" "$HOST_REPO_PATH" "$run_id"`
   - Async: `pal_launch_async revise "$repo" "$pr_num" "$HOST_REPO_PATH" "$run_id"`
8. Inside the container the pipeline:
   - Fetches PR branch (via Task 2.3's `setup_worktree` revise path)
   - Fetches PR review feedback (via Task 2.4's `fetch_pr_context`)
   - Skips adversarial plan review
   - Runs an implement pass with `AGENT_REVIEW_CONCERNS` set from review feedback
   - Runs test gate + post-impl review
   - Pushes new commits to the existing PR branch (no new PR)
9. Sync mode prints status summary. Async mode fires desktop notification on completion.

## Examples

- `/pal-revise 317` — address feedback on PR #317 synchronously
- `/pal-revise 317 --async` — same, in background
