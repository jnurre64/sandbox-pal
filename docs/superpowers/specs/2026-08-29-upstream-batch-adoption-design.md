# Upstream batch adoption and the container middle path — Design

**Issue:** jnurre64/sandbox-pal#31 (handoff) · settles jnurre64/sandbox-pal#30
**Upstream source:** `jnurre64/sandbox-pal-action` at `04cef68` (merge of PR #111; batch tracked in sandbox-pal-action#100, PRs #101–#111)
**Date:** 2026-08-29

## 1. Problem

sandbox-pal vendors its review-gate prompts and orchestration library from
`sandbox-pal-action` (see `UPSTREAM.md`). The vendored copy is frozen at upstream
`07b9347`. Since then upstream landed eleven fixes that apply to this repo with
full force — several of them *more* here than upstream:

- `GH_TOKEN` is injected into the workspace container (`lib/launcher.sh:19`) and
  phase output is posted to public issue comments; nothing redacts it.
- `image/opt/pal/lib/claude-runner.sh:49` (`parse_claude_output`) reads
  `.result` without checking `.is_error` — an API-error envelope
  (`is_error:true, subtype:"success"`) is treated as a normal phase result.
- Permission denials — the largest silent time sink in a headless loop — are
  never surfaced.
- The review gates use the pre-ledger single-retry flow; upstream replaced it
  with a stamped ledger and a capped review loop.
- **No BATS test sources `image/opt/pal/lib/review-gates.sh` or
  `claude-runner.sh`.** The only pipeline test (`tests/test_container_pipeline.bats`)
  is a skipped-by-default live run that still gates on `CLAUDE_CODE_OAUTH_TOKEN`,
  which the auth rework removed.

Separately, #30 asks whether sandbox-pal should offer a host-native execution
mode like upstream's orchestrator mode (#107).

## 2. Decisions

### 2.1 Execution mode (#30): the middle path, kept in the container

sandbox-pal stays **container-only**. Host-native execution is an explicit
non-goal: it duplicates upstream's orchestrator mode and dilutes the one promise
this project makes — Claude credentials in a named volume, phases contained.
Someone wanting host-native inheritance uses `sandbox-pal-action`'s
orchestrator mode.

Instead, the specific environment gaps are closed deliberately — *inherit
identity, memory and skills; gate the tool surface explicitly*:

| Gap | Today | Finished state |
|---|---|---|
| Identity / rules | `lib/container-rules.sh` syncs `~/.config/sandbox-pal/container-CLAUDE.md` → container `~/.claude/CLAUDE.md` | Unchanged; documented as the identity channel |
| Memory | `lib/memory-sync.sh` copies host auto-memory into the container's *writable* project slug | Copied to a **read-only** directory, index injected via `--append-system-prompt`, files readable via `--add-dir` (upstream #109 shape). Updates flow back as **proposals** (§2.3) |
| Skills | Not synced | Opt-in by name: `PAL_SYNC_SKILLS` (default empty) |
| Tool surface | Tool allowlists per phase | Plus `AGENT_MCP_CONFIG` / `AGENT_STRICT_MCP` (`--strict-mcp-config`) and per-phase `--permission-mode` from the vendored runner |

"Finished" is tracked, not implied: PR 2 records the decision on #30 and lands
memory/skills/proposals; anything left over becomes a follow-up issue linked
from #30 before #30 closes.

### 2.2 Vendoring: re-sync, don't fork

`review-gates.sh`, the four prompts, and the new `test-fix.md` prompt and
`schemas/*.json` are re-vendored from upstream `04cef68`. The runner helpers
upstream keeps in `common.sh` are ported into `claude-runner.sh`. Local
modifications are limited to the same class as before and are enumerated in
`UPSTREAM.md`:

- `set_label "agent:failed"` → `STATUS_OUTCOME="failure"` (and the specific
  `STATUS_FAILURE_REASON` that line already carries locally).
- `notify ...` lines dropped (host-side `lib/notify.sh` reads `status.json`).
- `set_heartbeat` → a no-op shim in `claude-runner.sh` (`status.json` is the
  liveness channel here; upstream's lock-file heartbeat does not apply).
- `preserve_branch` **kept** (new behaviour here: a failed gate pushes the work
  branch so the next run resumes instead of restarting).
- `apply_rules_files` / `stage_rules_files` (upstream #104) **not vendored** in
  this batch — the `.claude/**` guard applies identically, but no consumer of
  sandbox-pal has repo rules edited by phases today. The prompt rule text is
  kept so behaviour matches upstream when it is added; filed as a follow-up.
- Prompts: the container intro sentence in `implement.md` (existing), plus one
  shared "Memory proposals" paragraph (§2.3) appended to `implement.md`,
  `post-impl-retry.md` and `test-fix.md`.

### 2.3 Memory proposals (option A)

Memory inside the container is read-only. A phase that learns something durable
writes a proposal file instead:

- Location (in-container): `${WORKTREE_DIR}/.agent-data/memory-proposals/<slug>.md`
  — an ordinary, unguarded path. Same format as auto-memory (frontmatter
  `name`/`description`/`metadata.type`, then body). Never committed (prompts
  already forbid committing `.agent-data/`; `worktree.sh` adds
  `.agent-data/` to `.git/info/exclude`).
- At run end, `run-pipeline.sh`'s EXIT trap copies the directory to
  `${STATUS_DIR}/memory-proposals/` **before** wiping the worktree. `/status`
  is a bind-mount of the host runs dir (`lib/workspace.sh:44`), so the files
  appear at `~/.local/share/sandbox-pal/runs/<run-id>/memory-proposals/` with no
  host-side harvest step.
- `status.json` gains `"memory_proposals": ["<slug>.md", ...]` (empty array when
  none).
- The PR body gets a collapsed `### Memory proposals` section listing each
  proposal's `name` and `description` (not the body) so reviewers see that
  learnings exist.
- **Nothing is written to the host memory dir automatically.** A new
  `/pal-memory` skill lets the interactive session triage:
  `/pal-memory [run-id]` lists pending proposals (default: all runs with
  un-triaged proposals); `--adopt <file>` copies it into
  `~/.claude/projects/<host-slug>/memory/` and appends the index line to
  `MEMORY.md`; `--discard <file>` removes it. Adopted/discarded files are moved
  to `memory-proposals/.triaged/` so the pending list stays honest.

## 3. Components

### 3.1 `image/opt/pal/lib/claude-runner.sh` (rewrite)

Provides: `load_prompt`, `run_claude`, `parse_claude_output`,
`classify_claude_result`, `get_structured_output`, `redact_secrets`,
`extract_permission_denials`, `log_permission_denials`,
`denials_report_section`, `set_heartbeat` (no-op), `preserve_branch`,
`load_shared_memory`, `_resolve_memory_dir`.

`run_claude <prompt> <allowed_tools> [model] [schema_file] [PHASE]`:

```
-p "$prompt" --allowedTools ... --disallowedTools "${AGENT_DISALLOWED_TOOLS:-mcp__github__*}"
--max-turns "${AGENT_MAX_TURNS:-50}" --disable-slash-commands --output-format json
[--model M]
[--add-dir D]...                     # AGENT_ADD_DIRS (space-separated) + memory dir
[--max-budget-usd B]                 # AGENT_BUDGET_USD_<PHASE> then AGENT_BUDGET_USD; limitless unless set
[--effort E]                         # AGENT_EFFORT_<PHASE>
[--permission-mode P]                # AGENT_PERMISSION_MODE_<PHASE>
[--mcp-config F --strict-mcp-config] # AGENT_MCP_CONFIG; or --strict-mcp-config alone when AGENT_STRICT_MCP=true
[--no-session-persistence]           # unless AGENT_SESSION_PERSISTENCE=true
[--append-system-prompt MEMORY]      # load_shared_memory output when non-empty
[--json-schema "$(jq -c . F)"]       # schema_file, when it exists; WARN and continue otherwise
```

Capture: stdout to `$STATUS_DIR/claude-stdout-<phase-or-ts>.log`, stderr to
`claude-stderr-...log`; **both pass through `redact_secrets` before anything
reads them**. Non-zero exit emits the synthetic envelope
`{"result":"claude timed out or errored (exit code N)","error":true}` (kept —
`classify_claude_result` treats `.error` as recoverable).

`redact_secrets` is upstream's verbatim: token-shaped patterns
(`github_pat_…`, `gh[pousr]_…`, `Authorization:` headers) plus the value of
every exported variable whose name matches `*TOKEN*|*SECRET*|*PASSWORD*|*API_KEY*|*APIKEY*|*CREDENTIAL*`
and is ≥ 8 chars, replaced with `[REDACTED:<VAR>]`. Inside the container the
matching variables are `GH_TOKEN` (always) and whatever `.pal/config.env`
passes through — the test suite pins `GH_TOKEN` explicitly.

`parse_claude_output`: `is_error` first → `Agent phase failed: API error — <terminal_reason> — <api_error_status> — <result>`; then `.result // .result_text`; then `subtype` `error_*` → `Agent stopped: error_*`; else raw. `classify_claude_result` → `fail_fast | recoverable | ok` exactly as upstream.

### 3.2 `image/opt/pal/schemas/*.json` (new, copied)

`adversarial-plan.json`, `post-impl-review.json`, `post-impl-retry.json`
copied verbatim. (`triage`, `reply`, `validate`, `cleanup` have no phase here
and are not copied.) Defaults set in `run-pipeline.sh`:

```
AGENT_JSON_SCHEMA_ADVERSARIAL_PLAN="${AGENT_JSON_SCHEMA_ADVERSARIAL_PLAN-/opt/pal/schemas/adversarial-plan.json}"
AGENT_JSON_SCHEMA_POST_IMPL_REVIEW="${AGENT_JSON_SCHEMA_POST_IMPL_REVIEW-/opt/pal/schemas/post-impl-review.json}"
AGENT_JSON_SCHEMA_POST_IMPL_RETRY="${AGENT_JSON_SCHEMA_POST_IMPL_RETRY-/opt/pal/schemas/post-impl-retry.json}"
```

`-` not `:-`: an explicitly empty value disables the schema. Gate code prefers
`get_structured_output "$result"` and falls back to `_extract_review_json`.

### 3.3 `image/opt/pal/lib/review-gates.sh` (re-vendored)

Upstream `04cef68` with the §2.2 adaptations. Public surface:
`run_adversarial_plan_review`, `run_test_gate <impl_tools> <issue_title>`,
`run_post_impl_review`, `run_post_impl_retry_session`,
`run_post_impl_review_loop <impl_tools>` (returns 0 clean / 1 hard failure /
2 cap reached), ledger helpers `_ledger_*`.

Ledger: `${WORKTREE_DIR}/.agent-data/review-ledger.json`, stamped with
`.issue == $NUMBER`; an unstamped or mismatched ledger is discarded on init.
Ledger commits (`chore(agent): review ledger — …`) are kept as upstream does
(they use `git add -f` on the excluded path).

### 3.4 `image/opt/pal/run-pipeline.sh` (modified)

Replace the inline TDD retry loop (lines 189–236) and the single-retry review
call (lines 248–265) with upstream's shape:

```
implement phase (run_claude ... "IMPLEMENT")  → log_permission_denials
classify fail_fast → STATUS_FAILURE_REASON=implement_api_error; exit 1
empty diff check (unchanged)
preserve_branch
run_test_gate "$AGENT_ALLOWED_TOOLS_IMPLEMENT" "$AGENT_ISSUE_TITLE" || { STATUS_FAILURE_REASON=tests_failed; exit 1; }
run_post_impl_review_loop "$AGENT_ALLOWED_TOOLS_IMPLEMENT"; rc=$?
  rc=1 → exit 1 (gate already set STATUS_*)
  rc=2 → STATUS_OUTCOME=review_concerns_unresolved (PR still opened, ⚠ header + outstanding summary in body)
push + PR (body gains ledger summary, denials section, memory-proposals section)
```

`status.json` additions: `permission_denials` (array of `"<phase>: tool: input"`
lines from `.agent-data/permission-denials.log`), `memory_proposals` (§2.3),
`review_ledger` (the ledger object, or `null`). The existing
`review_concerns_addressed` / `review_concerns_unresolved` arrays are **kept**
(`lib/launcher.sh:246-249` renders `review_concerns_unresolved` in the async
summary) and are now derived from the ledger: addressed = findings with
`status == "fixed"`, unresolved = `severity == "blocking" && status == "open"`,
each rendered as `"F<n>: <description>"`.

Config knobs read from env (all passed through by `_pal_launcher_env_args`'s
`AGENT_` prefix rule): `AGENT_TEST_GATE_MAX_RETRIES` (default 2),
`AGENT_POST_IMPL_REVIEW_MAX_RETRIES` (default 3, was 1), `AGENT_MODEL_TEST_FIX`,
`AGENT_JSON_SCHEMA_*`, `AGENT_BUDGET_USD[_<PHASE>]`, `AGENT_EFFORT_<PHASE>`,
`AGENT_PERMISSION_MODE_<PHASE>`, `AGENT_MCP_CONFIG`, `AGENT_STRICT_MCP`,
`AGENT_SESSION_PERSISTENCE`, `AGENT_ADD_DIRS`, `AGENT_MEMORY_DIR`.
`AGENT_IMPL_MAX_RETRIES` is retired (superseded by the test gate); its presence
logs a one-line deprecation warning.

Phase names for the per-phase flag lookup: `ADVERSARIAL_PLAN`, `IMPLEMENT`,
`TEST_FIX`, `POST_IMPL_REVIEW`, `POST_IMPL_RETRY`.

### 3.5 Prompts (`image/opt/pal/prompts/`)

Re-vendor `adversarial-plan.md`, `post-impl-review.md`, `post-impl-retry.md`,
`implement.md`; add `test-fix.md`. Local additions (listed in `UPSTREAM.md`):

- `implement.md` line 1: the existing container sentence.
- Appended to `implement.md`, `post-impl-retry.md`, `test-fix.md`:

  > ## Memory proposals
  > Memory files under the memory directory are read-only. If you learn something durable about this repository that a future session should know (a non-obvious convention, a trap, a decision), write it as a proposal: one file per fact at `.agent-data/memory-proposals/<kebab-slug>.md`, with the same frontmatter as a memory file (`name`, `description`, `metadata.type`). Do not commit these files. A human triages them after the run.

### 3.6 Host side — memory, skills, proposals

`lib/memory-sync.sh`: destination becomes `/home/agent/memory/<host-slug>/`
(not the project slug the container's claude would auto-load and write to).
After `docker cp`, `docker exec -u root … chown -R root:root && chmod -R u=rwX,go=rX` the directory, so the unprivileged `agent` user cannot chmod it writable again. The launcher
passes `-e AGENT_MEMORY_DIR=/home/agent/memory/<host-slug>`; the runner's
`load_shared_memory` injects `MEMORY.md` as the system-prompt index and
`--add-dir` makes the pointed-at files readable. `PAL_SYNC_MEMORIES=false`
skips all of it (unchanged knob).

`lib/skills-sync.sh` (new): `pal_skills_sync_to_container` reads
`PAL_SYNC_SKILLS` (comma-separated names), copies each
`~/.claude/skills/<name>/` to `/home/agent/.claude/skills/<name>/` (removing the
container copy first so deletions propagate), warns and skips names that do not
exist on the host. Default empty: nothing inherits silently. Called from both
launchers next to `pal_container_rules_sync_to_container`.

`skills/pal-memory/SKILL.md` + `commands/pal-memory.md` + `lib/memory-proposals.sh`
(new): `pal_memory_proposals_list [run-id]`, `pal_memory_proposal_adopt <run-id> <file> <host-repo-path>`,
`pal_memory_proposal_discard <run-id> <file>`. Adopt validates the frontmatter
(`name:` present, slug matches filename) and refuses to overwrite an existing
memory file with the same name (prints the diff instead).

### 3.7 Tooling and docs

- `scripts/diff-upstream.sh`: default `UPSTREAM_REPO=$HOME/repos/sandbox-pal-action`;
  MAP gains `test-fix.md`, the three schemas; the runner is listed as
  "conceptual (ported from `scripts/lib/common.sh`)" rather than diffed.
- `UPSTREAM.md`: project name corrected to `jnurre64/sandbox-pal-action`; SHA
  column → `04cef68`; modifications column rewritten per §2.2; a
  "Ported helpers" table maps each `claude-runner.sh` function to its upstream
  origin.
- `docs/superpowers/specs/2026-04-18-sandbox-pal-design.md`: new §9.5
  "Execution mode: container-only (decision, #30)" summarising §2.1; §5.3
  per-repo config example gains the flag surface.
- `README.md` / `docs/`: the flag surface and `PAL_SYNC_SKILLS`,
  `/pal-memory` documented (PR 3).
- `CHANGELOG.md`: one `### Changed` / `### Added` block per PR.

## 4. Testing

All host-runnable with BATS; no Docker, no network, no real `claude`.

- `tests/test_container_lib.bats` (new, PR 1): sources `claude-runner.sh` and
  `review-gates.sh` with `WORKTREE_DIR`/`STATUS_DIR`/`PROMPTS_DIR` pointed at
  temp dirs, a stub `log`, a stub `gh` that records calls, and a fake `claude`
  on `PATH` that emits the envelope named by `FAKE_CLAUDE_ENVELOPE` and records
  its argv to `FAKE_CLAUDE_ARGS`. Cases (each a `REGRESSION` test that must fail
  before its implementation lands):
  - envelope with `is_error:true, subtype:"success"` → `parse_claude_output`
    says "API error", `classify_claude_result` = `fail_fast`.
  - `subtype:error_max_turns` → `recoverable`; synthetic `.error:true` → `recoverable`.
  - `GH_TOKEN=github_pat_$(printf 'x%.0s' {1..30})` exported; envelope and
    stderr containing it → both logs and the returned envelope contain
    `[REDACTED:GH_TOKEN]` and not the token.
  - envelope with `permission_denials` → `log_permission_denials` writes
    `.agent-data/permission-denials.log`; `denials_report_section` renders it.
  - `structured_output` present → `get_structured_output` wins over a
    narrative `.result`.
  - argv assertions: `--json-schema` present when the schema file exists and
    absent when `AGENT_JSON_SCHEMA_X=""`; `--max-budget-usd` absent by default,
    present with `AGENT_BUDGET_USD_IMPLEMENT`; `--no-session-persistence`
    default; `--strict-mcp-config` with `AGENT_STRICT_MCP=true`; `--add-dir`
    for `AGENT_MEMORY_DIR`; `--disable-slash-commands` always.
  - review loop: stale ledger (`issue: 99`) discarded on init; two-pass
    approve-after-fix sequence returns 0 and stamps `cycles: 2`; cap reached
    returns 2; parse failure sets `STATUS_FAILURE_REASON=post_impl_review_could_not_parse`.
  - test gate: green → 0; red, fix session commits, green → 0; fix session
    without commits → stops early, returns 1.
- `tests/test_run_pipeline.bats` (new, PR 1): runs `run-pipeline.sh` end to end
  on the host against a local bare "origin" repo, the fake `claude`, stub `gh`,
  and `PAL_STATUS_DIR`; asserts `status.json` fields including
  `permission_denials`, `review_ledger`, `memory_proposals`, and that
  `memory-proposals/` is copied to the status dir before the worktree is wiped.
- `tests/test_container_pipeline.bats`: the `CLAUDE_CODE_OAUTH_TOKEN` gate is
  replaced by a "workspace running and logged in" gate (`pal_preflight_all`).
- `tests/test_memory_sync.bats` (extended, PR 2): destination path, read-only
  bit, `AGENT_MEMORY_DIR` emitted by `_pal_launcher_env_args`.
- `tests/test_skills_sync.bats`, `tests/test_memory_proposals.bats`,
  `tests/test_skill_pal_memory.bats` (new, PR 2): copy, missing-name warning,
  default-empty no-op; list/adopt/discard including the overwrite refusal.
- `tests/test_launcher.bats` (extended, PR 3): the new `AGENT_*` knobs pass
  through from `.pal/config.env`.
- Every PR: `shellcheck $(find . -name '*.sh') && bats tests/` clean.

## 5. Delivery

| PR | Scope | Spec sections |
|---|---|---|
| 1 | Runner + gates + prompts + schemas re-vendor; pipeline rewrite; tests; `UPSTREAM.md` / `diff-upstream.sh` | 2.2, 3.1–3.5, 3.7 (tooling), 4 |
| 2 | Middle path: read-only memory, skills sync, memory proposals, `/pal-memory`; decision recorded on #30; design-doc §9.5 | 2.1, 2.3, 3.6 |
| 3 | Flag surface + `PAL_SYNC_SKILLS` + `/pal-memory` documentation; launcher passthrough test; `.pal/config.env` example | 3.7 (docs) |

Each PR has its own plan under `docs/superpowers/plans/`, is implemented
in-session (this repo has no `labeled` workflow, so the label pipeline cannot
run here), and follows the upstream rhythm: test first and watched failing,
full check before every commit, CHANGELOG entry.

## 6. Out of scope

- Host-native execution mode (explicit non-goal, §2.1).
- Upstream liveness (#106: lock heartbeat, `status` event) — `status.json` +
  `exec_pid` already cover it here.
- Upstream orchestrator mode and `sp-*` skills (#107).
- Rules staging (#104) — follow-up issue.
- Post-merge cleanup phase (`cleanup.md`) — no merge event reaches sandbox-pal.
- Auto-merging memory proposals into host memory (option B, rejected).
