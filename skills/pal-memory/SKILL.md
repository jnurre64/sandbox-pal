---
name: pal-memory
description: Triage memory proposals from sandbox-pal runs — list pending proposals, adopt one into this repo's host memory, or discard it. Host memory is never written automatically; this is the only path in.
---

# pal-memory

Pipeline phases run with a read-only copy of this repo's Claude Code memory.
When a phase learns something durable it writes a proposal to
`.agent-data/memory-proposals/<slug>.md`; the pipeline copies those to the
run directory (`~/.local/share/sandbox-pal/runs/<run-id>/memory-proposals/`)
and lists them in `status.json` (`memory_proposals`) and the PR body.

Usage:

- `/pal-memory`                           — list pending proposals across all runs
- `/pal-memory <run-id>`                  — list pending proposals for one run
- `/pal-memory <run-id> --adopt <file>`   — copy into `~/.claude/projects/<slug>/memory/` and index it in `MEMORY.md`
- `/pal-memory <run-id> --discard <file>` — move aside without adopting

`<slug>` is derived from the current repo's root (`git rev-parse --show-toplevel`),
so run this from inside the repo the proposal is about. Adopt refuses to
overwrite an existing memory file (it prints the diff instead) and rejects a
proposal whose `name:` does not match its filename.

```bash
set -euo pipefail
. "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
. "${CLAUDE_PLUGIN_ROOT}/lib/runs.sh"
. "${CLAUDE_PLUGIN_ROOT}/lib/memory-proposals.sh"

pal_load_config

usage() { echo "usage: pal-memory [run-id] [--adopt <file> | --discard <file>]" >&2; exit 2; }

run_id=""
action=""
file=""
while [ $# -gt 0 ]; do
    case "$1" in
        --adopt|--discard)
            [ -n "${2:-}" ] || usage
            action="${1#--}"; file="$2"; shift 2 ;;
        --*) usage ;;
        *)
            [ -z "$run_id" ] || usage
            run_id="$1"; shift ;;
    esac
done

case "$action" in
    "")
        pal_memory_proposals_list "$run_id"
        ;;
    adopt)
        [ -n "$run_id" ] || usage
        host_repo="$(git -C . rev-parse --show-toplevel)"
        pal_memory_proposal_adopt "$run_id" "$file" "$host_repo"
        ;;
    discard)
        [ -n "$run_id" ] || usage
        pal_memory_proposal_discard "$run_id" "$file"
        ;;
esac
```

After adopting, tell the user what was written and that the index line was
appended to `MEMORY.md`; suggest opening the file if the description looks
like it needs editing.
