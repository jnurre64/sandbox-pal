# Configuration

Two files, both non-secret. Credentials never go in either: Claude
credentials live in the workspace's named volume (`/pal-login`), `GH_TOKEN`
lives in your shell.

| File | Scope | Read by |
|---|---|---|
| `~/.config/sandbox-pal/config.env` | Host, all repos | `lib/config.sh` at every skill invocation |
| `<your-project>/.pal/config.env` | One repo | `lib/launcher.sh` — every `AGENT_*`, `PAL_*` and `DOCKER_HOST=` line is forwarded verbatim into the pipeline's environment for that run |

`.pal/config.env.example` in this repo is a commented template of the per-repo file.

## Global — `~/.config/sandbox-pal/config.env`

| Knob | Default | Effect |
|---|---|---|
| `PAL_CPUS`, `PAL_MEMORY` | unset (uncapped) | `docker run --cpus/--memory` for the workspace; applies on `/pal-workspace restart` |
| `PAL_SYNC_MEMORIES` | `true` | Copy this repo's Claude Code auto-memory into the workspace before each run (see [Memory](#memory)) |
| `PAL_SYNC_TRANSCRIPTS` | `false` | Include `*.jsonl` transcripts in that copy (secret-tier; not recommended) |
| `PAL_SYNC_SKILLS` | empty | Comma-separated names under `~/.claude/skills/` to copy into the workspace before each run (see [Skills](#skills)) |

## Per-repo — `.pal/config.env`

### Pipeline shape

A run is: adversarial plan review → implement → **pre-PR test gate** → **post-implementation review loop** → push + PR. The pipeline pushes the work branch (`agent/issue-<n>`) as soon as the implement phase commits, so a failed gate never loses work, and the next `/pal-implement` on the same issue resumes from that branch.

| Knob | Default | Effect |
|---|---|---|
| `AGENT_TEST_COMMAND` | unset (gate disabled) | Command the test gate runs in the worktree; its first word is added to the implement allowlist as `Bash(<word> *)` |
| `AGENT_TEST_SETUP_COMMAND` | unset | Run before each test-gate attempt (e.g. `bun install`) |
| `AGENT_TEST_GATE_MAX_RETRIES` | `2` | Fix sessions (`test-fix` prompt) allowed when the gate is red; a fix session that makes no commits stops the gate early |
| `AGENT_ADVERSARIAL_PLAN_REVIEW` | `true` | Gate A on/off |
| `AGENT_POST_IMPL_REVIEW` | `true` | Review loop on/off |
| `AGENT_POST_IMPL_REVIEW_MAX_RETRIES` | `3` | Review → fix → review cycles. Hitting the cap with blocking findings open still opens the PR, with a ⚠ header listing them; `status.json.outcome` is `review_concerns_unresolved` |
| `AGENT_ALLOWED_TOOLS_IMPLEMENT` | `Read,Write,Edit,Glob,Grep,Bash(git *),Bash(ls *),Bash(cat *),Bash(echo *),Bash(printenv *),Bash(mkdir *),Bash(mv *),Bash(cp *),Bash(rm *),Bash(chmod *)` | Implement / test-fix / review-retry tool allowlist |
| `AGENT_ALLOWED_TOOLS_TRIAGE` | `Read,Glob,Grep,Bash(ls *),Bash(git log *),Bash(git diff *),Bash(git show *),Bash(echo *),Bash(printenv *)` | Read-only allowlist for the review phases |
| `AGENT_DISALLOWED_TOOLS` | `mcp__github__*` | `--disallowedTools` for every phase |
| `AGENT_MAX_TURNS` | `50` | `--max-turns` for every phase |
| `AGENT_TIMEOUT` | `3600` | Seconds before a phase is killed (yields a recoverable "timed out" result) |
| `PAL_ALLOWLIST_EXTRA_DOMAINS` | unset | Comma-separated domains added to the egress firewall for the run |
| `DOCKER_HOST` | unset | Remote Docker daemon for this repo |

Denied tool calls are the largest silent time sink in a headless run. Every denial is logged (`WARN: <phase>: permission denial(s)`), listed in `status.json.permission_denials` and in a **Permission Denials** section of the PR body — treat each as an allowlist gap to fix here.

### Per-phase flags

Phases: `ADVERSARIAL_PLAN`, `IMPLEMENT`, `TEST_FIX`, `POST_IMPL_REVIEW`, `POST_IMPL_RETRY`. Every flag is optional and absent unless set.

| Knob | Flag | Notes |
|---|---|---|
| `AGENT_MODEL` / `AGENT_MODEL_<PHASE>` | `--model` | Per-phase wins over global |
| `AGENT_BUDGET_USD` / `AGENT_BUDGET_USD_<PHASE>` | `--max-budget-usd` | **Limitless unless set.** Per-phase wins over global |
| `AGENT_EFFORT_<PHASE>` | `--effort` | e.g. `low`, `medium`, `high`, `xhigh` |
| `AGENT_PERMISSION_MODE_<PHASE>` | `--permission-mode` | e.g. `dontAsk` |
| `AGENT_PROMPT_<PHASE>` | — | Path to a prompt override, absolute or relative to the worktree (e.g. `.pal/prompts/implement.md`) |
| `AGENT_JSON_SCHEMA_ADVERSARIAL_PLAN` / `_POST_IMPL_REVIEW` / `_POST_IMPL_RETRY` | `--json-schema` | Default: the vendored schema under `/opt/pal/schemas/`. Set to an **empty value** (`AGENT_JSON_SCHEMA_POST_IMPL_REVIEW=`) to disable structured output for that phase and fall back to text parsing |
| `AGENT_MCP_CONFIG` | `--mcp-config <file> --strict-mcp-config` | Path inside the container; the phase sees only the servers in that file |
| `AGENT_STRICT_MCP` | `--strict-mcp-config` | `true` → no MCP servers at all (without `AGENT_MCP_CONFIG`) |
| `AGENT_SESSION_PERSISTENCE` | `--no-session-persistence` (default) | `true` keeps resumable sessions in the workspace |
| `AGENT_ADD_DIRS` | `--add-dir` (one per space-separated path) | Extra readable paths |

`AGENT_IMPL_MAX_RETRIES` (the old inline TDD retry loop) is retired; setting it logs a warning.

## Memory

With `PAL_SYNC_MEMORIES=true`, the host's auto-memory for the repo
(`~/.claude/projects/<slug>/memory/`) is copied into the workspace at
`/home/agent/memory/<slug>/`, root-owned and read-only. Each phase gets the
`MEMORY.md` index in its system prompt and can `Read` the linked files; it
cannot edit them. Transcripts (`*.jsonl`) are excluded unless
`PAL_SYNC_TRANSCRIPTS=true`.

### Memory proposals and `/pal-memory`

When a phase learns something durable it writes a proposal file —
`.agent-data/memory-proposals/<slug>.md`, same frontmatter as a memory file —
instead of touching memory. The pipeline copies proposals to
`~/.local/share/sandbox-pal/runs/<run-id>/memory-proposals/`, lists them in
`status.json` (`memory_proposals`) and in a collapsed **Memory proposals**
section of the PR body. Nothing reaches host memory until you triage:

```
/pal-memory                          # pending proposals across all runs
/pal-memory <run-id>                 # one run
/pal-memory <run-id> --adopt <file>  # copy into this repo's memory dir + index line in MEMORY.md
/pal-memory <run-id> --discard <file>
```

Run it from inside the repo the proposal is about. Adopt refuses to overwrite
an existing memory file (it prints the diff) and rejects a proposal whose
`name:` does not match its filename. Triaged files move to
`memory-proposals/.triaged/`.

## Skills

`PAL_SYNC_SKILLS=name,name` copies `~/.claude/skills/<name>/` (symlinks
dereferenced) to `/home/agent/.claude/skills/<name>/` before each run,
removing the workspace copy first so host deletions propagate. Names that do
not exist on the host warn and are skipped. Nothing syncs by default.

## Identity and rules

`/pal-workspace edit-rules` opens `~/.config/sandbox-pal/container-CLAUDE.md`,
which is copied to the workspace's `~/.claude/CLAUDE.md` before each run.

Repo-level rules (`<project>/.claude/rules/*.md`) can be updated by a run.
Claude Code blocks headless writes under `.claude/`, so the pipeline stages
copies under `.agent-data/rules/` before the implement session, and after the
review loop copies back any staged file that changed and commits it as
`chore(agent): apply staged rules updates — <names>` on the PR branch. Only
files that already exist in `.claude/rules/` with names matching
`^[A-Za-z0-9._-]+\.md$` are applied; a phase cannot invent a rules file.
Applied names appear as `rules_applied` in `status.json`.

## Design decision: container-only

sandbox-pal does not offer a host-native execution mode; the three channels
above (memory, skills, rules) plus the explicit tool-surface flags are the
deliberate alternative. Rationale and the full table live in the design doc,
§9.5 (`docs/superpowers/specs/2026-04-18-sandbox-pal-design.md`), decided in
[#30](https://github.com/jnurre64/sandbox-pal/issues/30).
