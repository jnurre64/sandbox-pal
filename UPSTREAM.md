# Upstream Vendored Files

This project vendors pieces of `jnurre64/sandbox-pal-action`. Each file here is
tracked with its source path, the upstream commit at time of vendor, and its
local modifications — every local modification is listed; if it is not listed,
it is drift.

Resync via `scripts/diff-upstream.sh` (defaults to `~/repos/sandbox-pal-action`;
set `UPSTREAM_REPO` to another clone). Exit 1 means at least one file differs —
compare the diff against the tables below.

Current upstream SHA: `04cef68b433e90037b4f7af34b099e6005435a1c` (merge of sandbox-pal-action#111).

## Prompts

| Local path | Source | Modifications |
|---|---|---|
| `image/opt/pal/prompts/adversarial-plan.md` | `prompts/adversarial-plan.md` | none |
| `image/opt/pal/prompts/post-impl-review.md` | `prompts/post-impl-review.md` | none |
| `image/opt/pal/prompts/post-impl-retry.md` | `prompts/post-impl-retry.md` | appended "Memory proposals" section |
| `image/opt/pal/prompts/test-fix.md` | `prompts/test-fix.md` | appended "Memory proposals" section |
| `image/opt/pal/prompts/implement.md` | `prompts/implement.md` | line 1 mentions the sandbox-pal container; "approved by a human" → "approved"; appended "Memory proposals" section |

## Schemas

| Local path | Source | Modifications |
|---|---|---|
| `image/opt/pal/schemas/adversarial-plan.json` | `schemas/adversarial-plan.json` | none |
| `image/opt/pal/schemas/post-impl-review.json` | `schemas/post-impl-review.json` | none |
| `image/opt/pal/schemas/post-impl-retry.json` | `schemas/post-impl-retry.json` | none |

Not vendored: `triage.json`, `reply.json`, `validate.json`, `cleanup.json` (no such phases here).

## Libraries

| Local path | Source | Modifications |
|---|---|---|
| `image/opt/pal/lib/review-gates.sh` | `scripts/lib/review-gates.sh` | header comment; every `set_label "agent:failed"` → `STATUS_OUTCOME="failure"` + a specific `STATUS_FAILURE_REASON`; `set_label "agent:needs-info"` → `STATUS_OUTCOME="clarification_needed"`; `notify` call removed from `run_test_gate`; comment wording "re-label / re-dispatch" → "re-run `/pal-implement`". Function bodies otherwise identical. |

## Ported helpers (`image/opt/pal/lib/claude-runner.sh`)

Not a byte copy — the container runner is the local analogue of upstream
`scripts/lib/common.sh`. Re-check these by hand on each resync:

| Local function | Upstream origin | Local difference |
|---|---|---|
| `run_claude` | `common.sh: run_claude` | `--disable-slash-commands` always; stdout also tee'd to `$STATUS_DIR/claude-stdout-<phase>-<ts>.log`; no `CONFIG_DIR` schema resolution; no `AGENT_MEMORY_FILE` (directory only) |
| `parse_claude_output`, `classify_claude_result`, `get_structured_output`, `redact_secrets`, `extract_permission_denials`, `log_permission_denials`, `preserve_branch` | `common.sh` (same names) | none |
| `denials_report_section` | `common.sh` | points at `.pal/config.env` instead of `docs/customization.md` |
| `load_prompt` | `common.sh: load_prompt` | overrides resolve against `WORKTREE_DIR`, not `CONFIG_DIR`; returns 1 instead of `exit 1` |
| `load_shared_memory`, `_resolve_memory_dir` | `common.sh` (#109) | directory-only; wording mentions memory proposals |
| `set_heartbeat` | `liveness.sh` | no-op (status.json is the liveness channel here) |

## Conceptual patterns (not directly copied)

- Data-fetch pattern for gists and attachments (upstream `scripts/lib/data-fetch.sh`) — reimplemented inline in `fetch-context.sh` with the same fetch-on-start, bind-to-env-var shape.
- Work-branch resume (upstream `worktree.sh`, #73) — `setup_worktree` checks out `origin/agent/issue-<n>` when it exists.
- PR body assembly (upstream `common.sh: handle_post_implementation`) — inlined in `run-pipeline.sh` with the ledger summary, ⚠ unresolved header, denials section, and a sandbox-pal-only memory-proposals section.

## Deliberately not vendored

- `rules-staging.sh` (#104) — follow-up issue; the prompt rule text is kept.
- `liveness.sh` (#106), orchestrator mode and `sp-*` skills (#107), `cleanup.md` phase, `notify.sh`.
