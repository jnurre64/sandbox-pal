# Changelog

## [0.4.0] — 2026-04-19

First dogfood-ready release. Ships the core flow from an ideation session to an opened PR.

### Added
- **Plugin packaging** — `.claude-plugin/plugin.json`, shared libs at plugin-root `lib/`, skills under `skills/`, commands under `commands/`. Loads via `claude --plugin-dir`.
- **Skills:** `/claude-pal:pal-plan`, `/claude-pal:pal-implement` (sync mode)
- **Commands:** `/claude-pal:pal-brainstorm` (orchestrator for the full flow; depends on the `superpowers` plugin), `/claude-pal:pal-setup` (guided credential walkthrough)
- **Container pipeline:** adversarial plan review → TDD implement with retry loop → post-impl review → retry once on concerns → push branch + open PR
- **Auth: env-passthrough only** — reads `CLAUDE_CODE_OAUTH_TOKEN` (or `ANTHROPIC_API_KEY`) + `GH_TOKEN` from the process env, forwards to container at `docker run -e`. No on-disk secrets file. Matches Anthropic's `claude-code-action` pattern.
- **Preflight checks** — auth present, single auth method, Docker reachable, Windows bash, `gh auth status`, no-double-dispatch lock
- **Per-repo config** — `.pal/config.env` for non-secret project knobs (test commands, model overrides, allowlist extensions)
- **Vendored review-gate library** — prompts + `review-gates.sh` from `jnurre64/claude-pal-action` (formerly `claude-agent-dispatch`); see `UPSTREAM.md`

### Fixed
- Launcher pre-creates log file as 0666 before `docker run` so the container's non-root `agent` user can append to it (host-owned file blocked writes)
- `fetch-context.sh` falls back to the issue body when no `<!-- agent-plan -->` comment exists; `pal-plan` posts the marker in the body when creating a new issue

### Documentation
- `docs/install.md` — install guide
- `README.md` — project overview + auth + ToS
- `docs/superpowers/specs/2026-04-18-claude-pal-design.md` — full design
- `docs/superpowers/plans/2026-04-18-claude-pal.md` — implementation plan
- `UPSTREAM.md` — vendored-file tracking

### Not in 0.4.0 (planned for 0.5 / 0.6)
- Async mode, `/pal-status`, `/pal-logs`, `/pal-cancel` (Phase 5)
- `/pal-revise` for PR-review follow-ups (Phase 6)
- OS-native credential stores — macOS Keychain, Windows Credential Manager, Linux `pass` (Phase 7, deferred)
