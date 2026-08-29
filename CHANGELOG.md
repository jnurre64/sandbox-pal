# Changelog

## [Unreleased]

### Added
- **Container runner parity with sandbox-pal-action@04cef68.** `image/opt/pal/lib/claude-runner.sh` now scrubs secrets from every phase envelope and stderr log at capture (`redact_secrets`; `GH_TOKEN` is always present inside the workspace), classifies phase results from `is_error` first so an API error can no longer masquerade as a normal result, surfaces `permission_denials` (in the run log, `status.json` and the PR body), prefers `--json-schema` structured output for the review gates, and exposes the per-phase flag surface: `AGENT_BUDGET_USD[_<PHASE>]` (limitless unless set), `AGENT_EFFORT_<PHASE>`, `AGENT_PERMISSION_MODE_<PHASE>`, `AGENT_MCP_CONFIG` / `AGENT_STRICT_MCP` (`--strict-mcp-config`), `AGENT_SESSION_PERSISTENCE` (default off → `--no-session-persistence`), `AGENT_ADD_DIRS`, `AGENT_MEMORY_DIR`. Phases: `ADVERSARIAL_PLAN`, `IMPLEMENT`, `TEST_FIX`, `POST_IMPL_REVIEW`, `POST_IMPL_RETRY`.
- **Ledger-based review loop and pre-PR test gate** (re-vendored `review-gates.sh`): findings ride a stamped `.agent-data/review-ledger.json`; the loop runs review → fix → review up to `AGENT_POST_IMPL_REVIEW_MAX_RETRIES` (default 3, was 1) fix sessions; the test gate runs `AGENT_TEST_COMMAND` with up to `AGENT_TEST_GATE_MAX_RETRIES` (default 2) `test-fix` sessions and stops early when a fix session makes no commits. A run that hits the review cap still opens the PR, with a ⚠ header and the outstanding findings, and reports `outcome: review_concerns_unresolved`.
- **Work-branch preservation:** the implementation branch is pushed before any gate runs, and `setup_worktree` resumes from `origin/agent/issue-<n>` on the next run instead of restarting.
- **Memory proposals:** phases write durable learnings to `.agent-data/memory-proposals/*.md`; the pipeline copies them to the run directory (`memory_proposals` in `status.json`) and lists them in the PR body. Triage tooling (`/pal-memory`) arrives with the next release.
- `status.json` gains `review_ledger`, `permission_denials`, `memory_proposals`; `review_concerns_*` are now derived from the ledger.
- Host-runnable BATS coverage for the container lib (`tests/test_container_lib.bats`, `tests/test_run_pipeline.bats`) with a fake `claude`.
- **Container middle path (#30 decision: container-only, no host-native mode).** Host auto-memory now lands in the workspace at `/home/agent/memory/<host-slug>/` as a root-owned, read-only directory (`lib/memory-sync.sh`); the launcher passes `AGENT_MEMORY_DIR` so the runner injects `MEMORY.md` into the system prompt and exposes the files with `--add-dir`. Selected host skills sync in by name with `PAL_SYNC_SKILLS=name,name` (`lib/skills-sync.sh`; default empty). New `/pal-memory [run-id] [--adopt <file> | --discard <file>]` triages the memory proposals harvested to `~/.local/share/sandbox-pal/runs/<run-id>/memory-proposals/` — the only path by which agent learnings reach host memory. Design doc §9.5 records the decision.

### Changed
- `AGENT_IMPL_MAX_RETRIES` is retired (the test gate replaces the inline TDD retry loop); setting it logs a warning.
- `scripts/diff-upstream.sh` defaults to `~/repos/sandbox-pal-action`; `UPSTREAM.md` now names that project and lists every local modification.
- `tests/test_container_pipeline.bats` gates on a running, logged-in workspace instead of the removed `CLAUDE_CODE_OAUTH_TOKEN`.
- Memory is no longer copied into the container's writable project slug (`~/.claude/projects/<run-slug>/memory`); the container's claude cannot auto-load or edit it.
- **Brand rename:** `claude-pal` → `sandbox-pal`. The plugin, Docker image (`sandbox-pal:latest`), named volumes (`sandbox-pal-claude`, `sandbox-pal-workspace`), host config path (`~/.config/sandbox-pal/`), and marketplace identifiers are all renamed. The `pal-*` command/skill names, `PAL_*` env vars, and per-repo `.pal/` config directory are unchanged. Version stays at 0.5.0.
- `marketplace.json` now pins `source.ref: "main"` rather than a tag — the `v0.5.0` tag's committed `plugin.json` still says `claude-pal`, so tracking `main` keeps the installed plugin consistent with its manifest until the next release.

### Migration (for existing claude-pal users)

The rename orphans three pieces of local state. None are auto-migrated; each has a one-line fix:

```bash
# 1. Credentials volume — the new workspace uses sandbox-pal-claude; start fresh by re-running
#    claude /login inside the new workspace, OR copy the old volume contents:
docker run --rm \
  -v claude-pal-claude:/src \
  -v sandbox-pal-claude:/dst \
  alpine sh -c 'cp -a /src/. /dst/'

# 2. Workspace scratch volume (if you care about its contents):
docker run --rm \
  -v claude-pal-workspace:/src \
  -v sandbox-pal-workspace:/dst \
  alpine sh -c 'cp -a /src/. /dst/'

# 3. Host config:
cp -r ~/.config/claude-pal ~/.config/sandbox-pal
```

The old `claude-pal:latest` Docker image is orphaned; `/pal-setup` will rebuild as `sandbox-pal:latest` on next run. You can remove the old image with `docker image rm claude-pal:latest` once the new one is working.

The `/plugin` marketplace entry (if you installed via `/plugin marketplace add jnurre64/claude-pal`) needs to be re-added: run `/plugin marketplace remove claude-pal`, then `/plugin marketplace add jnurre64/sandbox-pal` and `/plugin install sandbox-pal@sandbox-pal`.

## [0.5.0] — 2026-04-23

### Changed
- **BREAKING (pre-1.0):** Ephemeral `docker run --rm` + `CLAUDE_CODE_OAUTH_TOKEN` env-passthrough replaced by a long-running workspace container (`sandbox-pal-workspace`) with in-container `/login`. See `docs/authentication.md`.
- `lib/config.sh` no longer reads `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY`. `GH_TOKEN` is the only required host env var.
- Per-run host → container memory sync (`~/.claude/projects/<slug>/memory/` → workspace). Markdown only; `*.jsonl` excluded by default (secret-tier).
- Container-scoped `CLAUDE.md` via `~/.config/sandbox-pal/container-CLAUDE.md`; synced per run.
- New optional knobs: `PAL_CPUS`, `PAL_MEMORY`, `PAL_SYNC_MEMORIES`, `PAL_SYNC_TRANSCRIPTS`.
- `/pal-setup` now auto-builds `sandbox-pal:latest` if absent, using `${CLAUDE_PLUGIN_ROOT}/image/Dockerfile` as the build context. The marketplace install flow no longer requires a repo clone for the image build.
- `docs/install.md` rewritten around the marketplace install flow; clone-based workflow moved to a "Contributor / local dev loop" section.
- `README.md` "Getting started" and "One-time setup" rewritten for the marketplace install.

### Added
- **Plugin marketplace distribution.** Install with `/plugin marketplace add jnurre64/sandbox-pal` + `/plugin install sandbox-pal@sandbox-pal`, replacing the session-scoped `claude --plugin-dir` recipe.
- `.claude-plugin/marketplace.json` (flat layout, single plugin entry pinned to the release tag).
- `lib/image.sh` with `pal_image_exists` / `pal_image_build` / `pal_image_ensure` helpers (called by `/pal-setup`).
- CI: `jq -e` parse check for both `.claude-plugin/*.json` manifests.
- `/pal-workspace` (start | stop | restart | status | edit-rules).
- `/pal-login`, `/pal-logout`.
- `docs/authentication.md`.

### Removed
- `image/opt/pal/entrypoint.sh` (split into `workspace-boot.sh` + `run-pipeline.sh`).
- `claude setup-token` is no longer part of setup.

### Testing
- `tests/test_revise_smoke.bats` converted from a real-image smoke test to a mocked-docker smoke test (matching `test_skill_pal_implement.bats` pattern). Formerly required `PAL_TEST_REPO` / `PAL_TEST_PR_WITH_REVIEW` / `CLAUDE_CODE_OAUTH_TOKEN`.

## [0.4.0] — 2026-04-19

First dogfood-ready release. Ships the core flow from an ideation session to an opened PR.

### Added
- **Plugin packaging** — `.claude-plugin/plugin.json`, shared libs at plugin-root `lib/`, skills under `skills/`, commands under `commands/`. Loads via `claude --plugin-dir`.
- **Skills:** `/sandbox-pal:pal-plan`, `/sandbox-pal:pal-implement` (sync mode)
- **Commands:** `/sandbox-pal:pal-brainstorm` (orchestrator for the full flow; depends on the `superpowers` plugin), `/sandbox-pal:pal-setup` (guided credential walkthrough)
- **Container pipeline:** adversarial plan review → TDD implement with retry loop → post-impl review → retry once on concerns → push branch + open PR
- **Auth: env-passthrough only** — reads `CLAUDE_CODE_OAUTH_TOKEN` (or `ANTHROPIC_API_KEY`) + `GH_TOKEN` from the process env, forwards to container at `docker run -e`. No on-disk secrets file. Matches Anthropic's `claude-code-action` pattern.
- **Preflight checks** — auth present, single auth method, Docker reachable, Windows bash, `gh auth status`, no-double-dispatch lock
- **Per-repo config** — `.pal/config.env` for non-secret project knobs (test commands, model overrides, allowlist extensions)
- **Vendored review-gate library** — prompts + `review-gates.sh` from `jnurre64/sandbox-pal-action` (formerly `claude-pal-action` / `claude-agent-dispatch`); see `UPSTREAM.md`

### Fixed
- Launcher pre-creates log file as 0666 before `docker run` so the container's non-root `agent` user can append to it (host-owned file blocked writes)
- `fetch-context.sh` falls back to the issue body when no `<!-- agent-plan -->` comment exists; `pal-plan` posts the marker in the body when creating a new issue

### Documentation
- `docs/install.md` — install guide
- `README.md` — project overview + auth + ToS
- `docs/superpowers/specs/2026-04-18-sandbox-pal-design.md` — full design
- `docs/superpowers/plans/2026-04-18-sandbox-pal.md` — implementation plan
- `UPSTREAM.md` — vendored-file tracking

### Not in 0.4.0 (planned for 0.5 / 0.6)
- Async mode, `/pal-status`, `/pal-logs`, `/pal-cancel` (Phase 5)
- `/pal-revise` for PR-review follow-ups (Phase 6)
- OS-native credential stores — macOS Keychain, Windows Credential Manager, Linux `pass` (Phase 7, deferred)
