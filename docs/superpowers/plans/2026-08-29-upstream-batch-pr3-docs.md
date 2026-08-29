# Upstream Batch PR 3 — Docs and Config Surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Document everything PR 1 (#32) and PR 2 (#33) shipped — the per-phase flag surface, `PAL_SYNC_SKILLS`, read-only memory and `/pal-memory`, the new pipeline shape — and pin the `.pal/config.env` passthrough of the new `AGENT_*` knobs with a test.

**Architecture:** One new reference page, `docs/configuration.md`, holds the full knob tables (global `~/.config/sandbox-pal/config.env`, per-repo `.pal/config.env`, memory/skills/proposals). `README.md` and `docs/install.md` are trimmed to point at it. `.pal/config.env.example` becomes a faithful, commented copy of the per-repo surface. No library code changes; the only test is a characterization test of `_pal_launcher_env_args`.

**Tech Stack:** Markdown, bash, BATS (`tests/bats/bin/bats`), shellcheck.

**Spec:** `docs/superpowers/specs/2026-08-29-upstream-batch-adoption-design.md` §3.7 (docs rows), §4 (`tests/test_launcher.bats` extended, PR 3), §5 (PR 3 row). Issue: https://github.com/jnurre64/sandbox-pal/issues/31.

## Global Constraints

- Full check before every commit: `shellcheck -S info $(find . -name '*.sh' -not -path '*/bats/*' -not -path '*/.git/*') && ./tests/bats/bin/bats tests/`.
- Knob names and defaults must match the code: `image/opt/pal/run-pipeline.sh` (defaults block), `image/opt/pal/lib/claude-runner.sh` (`run_claude`), `lib/config.sh`, `lib/launcher.sh`. Copy them from the source, do not recall them.
- No secrets in any file; example tokens are `github_pat_<token>`.
- Commit prefixes: `docs:`, `test(host):`. Every commit ends with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01BkWFyA2AvNHr4a77gM9yUN`.
- Branch: `feature/31-docs` off `main` (after #33). PR title: `docs: configuration reference for the flag surface, PAL_SYNC_SKILLS and /pal-memory`; body `Part 3 of 3 for #31` — this one may say `Closes #31`.

---

## File structure

| Path | Status | Responsibility |
|---|---|---|
| `tests/test_launcher.bats` | modify | Per-repo `.pal/config.env` passthrough of the new `AGENT_*` knobs |
| `.pal/config.env.example` | rewrite | Per-repo surface, commented, matching `docs/configuration.md` |
| `docs/configuration.md` | create | Reference: global knobs, per-repo knobs (phases, flags, gates), memory/skills/proposals |
| `README.md` | modify | Pipeline description (§What it does), config pointers, skills list |
| `docs/install.md` | modify | "What's not in this release" refresh; link to configuration |
| `CHANGELOG.md` | modify | Unreleased → Changed (docs) |

---

### Task 1: Launcher passthrough test for the new `AGENT_*` knobs

**Files:**
- Test: `tests/test_launcher.bats`

This is a characterization test: `_pal_launcher_env_args` already forwards any `AGENT_`/`PAL_` line from `.pal/config.env` (`lib/launcher.sh`), so the test is expected to pass on first run. It pins the contract the docs describe (commented lines ignored, empty-value lines forwarded so `AGENT_JSON_SCHEMA_X=` can disable a schema).

- [ ] **Step 1: Write the test**

Append to `tests/test_launcher.bats`:

```bash
@test "_pal_launcher_env_args forwards the PR 1/2 AGENT_* knobs from .pal/config.env, skipping comments" {
    local repo="$TMPHOME/proj"; mkdir -p "$repo/.pal"
    cat > "$repo/.pal/config.env" <<'CFG'
# comment line
AGENT_BUDGET_USD_IMPLEMENT=8
AGENT_EFFORT_POST_IMPL_REVIEW=xhigh
AGENT_PERMISSION_MODE_IMPLEMENT=dontAsk
AGENT_STRICT_MCP=true
AGENT_TEST_GATE_MAX_RETRIES=1
AGENT_JSON_SCHEMA_POST_IMPL_REVIEW=
# AGENT_MODEL_IMPLEMENT=commented-out
PAL_ALLOWLIST_EXTRA_DOMAINS=registry.example.com
CFG
    cd "$repo"
    local -a args=()
    GH_TOKEN=ghp_x _pal_launcher_env_args run-1 args
    run printf '%s\n' "${args[@]}"
    assert_line "AGENT_BUDGET_USD_IMPLEMENT=8"
    assert_line "AGENT_EFFORT_POST_IMPL_REVIEW=xhigh"
    assert_line "AGENT_PERMISSION_MODE_IMPLEMENT=dontAsk"
    assert_line "AGENT_STRICT_MCP=true"
    assert_line "AGENT_TEST_GATE_MAX_RETRIES=1"
    assert_line "AGENT_JSON_SCHEMA_POST_IMPL_REVIEW="      # empty value still forwarded (disables the schema)
    assert_line "PAL_ALLOWLIST_EXTRA_DOMAINS=registry.example.com"
    refute_line --partial "commented-out"
}
```

- [ ] **Step 2: Run it**

Run: `./tests/bats/bin/bats tests/test_launcher.bats`
Expected: all pass (characterization). If the empty-value line is missing, `lib/launcher.sh`'s grep dropped it — that would be a real bug to fix in the launcher, not the test.

- [ ] **Step 3: Commit**

```bash
git add tests/test_launcher.bats
git commit -m "test(host): pin .pal/config.env passthrough of the per-phase AGENT_* knobs"
```

---

### Task 2: `docs/configuration.md` and `.pal/config.env.example`

**Files:**
- Create: `docs/configuration.md`
- Rewrite: `.pal/config.env.example`

- [ ] **Step 1: Verify the defaults against the code before writing**

Run: `grep -n 'AGENT_[A-Z_]*="\${AGENT_' image/opt/pal/run-pipeline.sh; grep -n 'AGENT_[A-Z_]*' image/opt/pal/lib/claude-runner.sh | grep -o 'AGENT_[A-Z_]*' | sort -u; grep -n 'PAL_' lib/config.sh`
Expected: the names/defaults below. Fix the doc, not the code, on any mismatch.

- [ ] **Step 2: Write `docs/configuration.md`**

```markdown
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

## Design decision: container-only

sandbox-pal does not offer a host-native execution mode; the three channels
above (memory, skills, rules) plus the explicit tool-surface flags are the
deliberate alternative. Rationale and the full table live in the design doc,
§9.5 (`docs/superpowers/specs/2026-04-18-sandbox-pal-design.md`), decided in
[#30](https://github.com/jnurre64/sandbox-pal/issues/30).
```

- [ ] **Step 3: Rewrite `.pal/config.env.example`**

```bash
# Per-repo sandbox-pal config — non-secret only.
# Copy to <your-project>/.pal/config.env and commit to your project repo.
# Every AGENT_*, PAL_* and DOCKER_HOST= line is forwarded into the pipeline
# environment for runs from this repo. Credentials never go here: Claude
# credentials live in the workspace volume (/pal-login), GH_TOKEN in your shell.
# Reference: docs/configuration.md in the sandbox-pal repo.

# Test gate (disabled when AGENT_TEST_COMMAND is unset)
# AGENT_TEST_COMMAND=bun test
# AGENT_TEST_SETUP_COMMAND=bun install
# AGENT_TEST_GATE_MAX_RETRIES=2

# Review gates
# AGENT_ADVERSARIAL_PLAN_REVIEW=true
# AGENT_POST_IMPL_REVIEW=true
# AGENT_POST_IMPL_REVIEW_MAX_RETRIES=3

# Tool allowlists
# AGENT_ALLOWED_TOOLS_IMPLEMENT=Read,Write,Edit,Glob,Grep,Bash(bun *),Bash(git *)
# AGENT_ALLOWED_TOOLS_TRIAGE=Read,Glob,Grep,Bash(git log *),Bash(git diff *)
# AGENT_MAX_TURNS=50
# AGENT_TIMEOUT=3600

# Per-phase flags. Phases: ADVERSARIAL_PLAN, IMPLEMENT, TEST_FIX,
# POST_IMPL_REVIEW, POST_IMPL_RETRY. Budget is limitless unless set.
# AGENT_MODEL_IMPLEMENT=claude-sonnet-5
# AGENT_BUDGET_USD=10
# AGENT_BUDGET_USD_IMPLEMENT=8
# AGENT_EFFORT_IMPLEMENT=high
# AGENT_PERMISSION_MODE_IMPLEMENT=dontAsk
# AGENT_PROMPT_IMPLEMENT=.pal/prompts/implement.md
# AGENT_JSON_SCHEMA_POST_IMPL_REVIEW=      # empty = disable structured output for that phase
# AGENT_MCP_CONFIG=/home/agent/mcp.json    # --mcp-config + --strict-mcp-config
# AGENT_STRICT_MCP=true                    # --strict-mcp-config with no config
# AGENT_SESSION_PERSISTENCE=false
# AGENT_ADD_DIRS=/home/agent/extra

# Egress allowlist extensions for private registries
# PAL_ALLOWLIST_EXTRA_DOMAINS=private.registry.example.com,artifactory.internal

# Remote Docker daemon
# DOCKER_HOST=ssh://user@windows-box
```

- [ ] **Step 4: Commit**

```bash
git add docs/configuration.md .pal/config.env.example
git commit -m "docs: configuration reference for the flag surface, memory, skills and /pal-memory"
```

---

### Task 3: README, install.md, CHANGELOG; full check; PR

**Files:**
- Modify: `README.md` (§What it does, §Resource caps, §Per-repo config, §Plugin skills and commands)
- Modify: `docs/install.md` (§What's not in this release)
- Modify: `CHANGELOG.md`

- [ ] **Step 1: README**

Replace the §What it does step-3 bullet list with:

```markdown
   - Runs an **adversarial plan review** (fresh session, read-only, structured verdict against the issue)
   - **Implements** the plan and pushes the work branch immediately, so a later failure never loses the commits (the next run resumes from that branch)
   - Runs the **pre-PR test gate**: `AGENT_TEST_COMMAND` with bounded `test-fix` sessions
   - Runs the **post-implementation review loop** — review → fix → review against a stamped findings ledger, up to `AGENT_POST_IMPL_REVIEW_MAX_RETRIES` cycles; if blocking findings survive, the PR still opens with a ⚠ header listing them
   - Opens the PR with the ledger summary, any permission denials, and any memory proposals in the body
```

Rename `### Resource caps (optional)` to `### Host config (optional)` and replace its body with:

```markdown
Knobs in `~/.config/sandbox-pal/config.env`:

    PAL_CPUS=2.0
    PAL_MEMORY=4g
    PAL_SYNC_MEMORIES=true      # read-only copy of this repo's auto-memory into each run
    PAL_SYNC_TRANSCRIPTS=false
    PAL_SYNC_SKILLS=            # comma-separated ~/.claude/skills names to sync (default: none)

Caps apply on `/pal-workspace restart`; sync knobs apply on the next run. Full reference: [`docs/configuration.md`](docs/configuration.md).
```

Replace the §Per-repo config paragraph with:

```markdown
Optional per-repository settings live in `<your-project>/.pal/config.env` — every `AGENT_*`, `PAL_*` and `DOCKER_HOST=` line is forwarded into the pipeline for runs from that repo: the test gate (`AGENT_TEST_COMMAND`), review-gate caps, per-phase model / budget / effort / permission mode / MCP config, prompt overrides, extra egress domains. Template: [`.pal/config.env.example`](.pal/config.env.example); reference: [`docs/configuration.md`](docs/configuration.md). Do not put credentials there.
```

In §Plugin skills and commands add, after the `pal-implement` line:

```markdown
- `/sandbox-pal:pal-revise <pr#>` — feed PR review feedback back through the pipeline
- `/sandbox-pal:pal-status [run-id]`, `/sandbox-pal:pal-logs <run-id>`, `/sandbox-pal:pal-cancel <run-id>` — async run management
- `/sandbox-pal:pal-memory [run-id] [--adopt <file> | --discard <file>]` — triage memory proposals from runs (the only path by which agent learnings reach host memory)
```

- [ ] **Step 2: install.md**

Replace the §What's not in this release body with:

```markdown
v0.x ships the full pipeline (adversarial review → implement → test gate → review loop → PR) in sync and async mode, the workspace-container lifecycle, read-only memory and opt-in skills sync, and `/pal-memory` triage. See [`configuration.md`](configuration.md) for every knob. Not yet in this release:

- Repo-rules staging (phases editing `.claude/**` rules files) — upstream #104; tracked as a follow-up
- Windows-container backend (`PAL_BACKEND=docker-windows`)
```

- [ ] **Step 3: CHANGELOG**

Under `## [Unreleased]` → `### Changed`, append:

```markdown
- Docs: new `docs/configuration.md` (global + per-repo knobs, per-phase flags, memory/skills/proposals); `.pal/config.env.example` rewritten to the current surface; README pipeline description and skills list updated.
```

- [ ] **Step 4: Full check**

Run: `shellcheck -S info $(find . -name '*.sh' -not -path '*/bats/*' -not -path '*/.git/*') && ./tests/bats/bin/bats tests/ && claude plugin validate ~/repos/sandbox-pal`
Expected: clean; all green; `✔ Validation passed`. Also: `grep -rn 'CLAUDE_CODE_OAUTH_TOKEN' README.md docs/*.md .pal/` must be empty (the auth rework removed it).

- [ ] **Step 5: Commit, push, PR**

```bash
git add README.md docs/install.md CHANGELOG.md
git commit -m "docs: README and install guide reflect the test gate, review loop, memory and skills sync"
git push -u origin feature/31-docs
GH_TOKEN=$(cat ~/.config/gh-tokens/sandbox-pal-token) gh pr create --repo jnurre64/sandbox-pal \
  --title "docs: configuration reference for the flag surface, PAL_SYNC_SKILLS and /pal-memory" \
  --body "Part 3 of 3 for #31. Closes #31.

- docs/configuration.md: global knobs, per-repo knobs, per-phase flags (defaults copied from run-pipeline.sh / claude-runner.sh), memory + proposals + /pal-memory, skills, rules, the #30 decision pointer
- .pal/config.env.example rewritten to the current surface
- README: pipeline description (test gate, ledger loop, ⚠ unresolved), host/per-repo config pointers, skills list incl. /pal-memory
- docs/install.md: what's-not-in-this-release refreshed
- tests/test_launcher.bats: characterization test for .pal/config.env passthrough of the new AGENT_* knobs (incl. empty-value lines)"
```

Then file the rules-staging follow-up and link it from #30 (the spec's "leftover before #30 closes"):

```bash
GH_TOKEN=$(cat ~/.config/gh-tokens/sandbox-pal-token) gh issue create --repo jnurre64/sandbox-pal \
  --title "Vendor rules staging (upstream #104): let phases propose .claude/** rule edits" \
  --body "Follow-up from #31 / #30. Upstream sandbox-pal-action#104 added rules-staging.sh: phases cannot write under .claude/ (Claude Code path guard), so rule edits are staged under .agent-data/ and applied by the orchestrator. Deliberately not vendored in #32 (UPSTREAM.md → Deliberately not vendored); the prompt rule text is kept so behaviour matches upstream once this lands. Scope: vendor stage_rules_files/apply_rules_files, call apply after the review loop in run-pipeline.sh, tests in tests/test_container_lib.bats, UPSTREAM.md row."
GH_TOKEN=$(cat ~/.config/gh-tokens/sandbox-pal-token) gh issue comment 30 --repo jnurre64/sandbox-pal \
  --body "Leftover linked: <follow-up-issue-url> (rules staging, upstream #104). With #32, #33 and the docs PR the acceptance items on this issue are covered; closing once the docs PR merges."
```

---

## Self-review against the spec

- §3.7 docs row: README + docs cover the flag surface, `PAL_SYNC_SKILLS`, `/pal-memory` ✔ (Tasks 2, 3). Design-doc §9.5/§5.3 were PR 2 ✔.
- §4: `tests/test_launcher.bats` extended for new `AGENT_*` passthrough ✔ (Task 1). `.pal/config.env` example ✔ (Task 2).
- §2.1 "finished is tracked": follow-up issue for rules staging filed and linked from #30 ✔ (Task 3).
- Consistency: every knob in `docs/configuration.md` is verified against the code in Task 2 Step 1; the example file lists a subset of the same names.
