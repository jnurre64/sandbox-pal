# sandbox-pal

Local agent dispatch via a Claude Code plugin.

## Key Documentation

- Full design: `docs/superpowers/specs/2026-04-18-sandbox-pal-design.md`
- Implementation plan: `docs/superpowers/plans/2026-04-18-sandbox-pal.md`
- Upstream tracking (vendored pieces): `UPSTREAM.md`

## Architecture

sandbox-pal ships as a Claude Code plugin. Shared bash helpers under plugin-root `lib/` are referenced from every `SKILL.md` via `${CLAUDE_PLUGIN_ROOT}` (set by Claude Code at skill-invocation time). Do NOT use `claude-skill-path` or `$(dirname "${BASH_SOURCE[0]}")` dances in `SKILL.md` — use `${CLAUDE_PLUGIN_ROOT}/lib/foo.sh`.

- `.claude-plugin/plugin.json` — Claude Code plugin manifest
- `image/Dockerfile` — base Ubuntu image with claude CLI, gh, jq, git, iptables
- `image/opt/pal/entrypoint.sh` — pipeline orchestrator (bash)
- `image/opt/pal/allowlist.yaml` — firewall allowlist (data)
- `image/opt/pal/prompts/` — vendored adversarial/post-impl review prompts
- `image/opt/pal/lib/` — bash helpers inside the container (vendored review-gates.sh etc.)
- `lib/` — shared plugin-side helpers (config loader, preflight, launcher, etc.); sourced via `${CLAUDE_PLUGIN_ROOT}/lib/...`
- `skills/pal-*/SKILL.md` — Claude Code skills (host-side)
- `commands/pal-*.md` — Claude Code slash-command prompts (host-side)
- `tests/` — BATS-Core tests

## Authentication model

sandbox-pal uses a **long-running workspace container** that owns its own Claude
credentials. `claude /login` is run interactively **inside** the container
once; the resulting `.credentials.json` persists in a Docker-managed named
volume (`sandbox-pal-claude`) and never touches the host filesystem. Every
`pal-*` invocation `docker exec`s into the workspace.

The host shell only needs `GH_TOKEN` (or `GITHUB_TOKEN`) — there is **no**
`CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` env-var path. `lib/config.sh`
asserts `GH_TOKEN` and optionally sources `~/.config/sandbox-pal/config.env` for
non-secret knobs (`PAL_CPUS`, `PAL_MEMORY`, `PAL_SYNC_MEMORIES`,
`PAL_SYNC_TRANSCRIPTS`).

Per-repo non-secret knobs (`PAL_TEST_CMD`, `AGENT_BASE_BRANCH`, `DOCKER_HOST`)
may still live in `<project>/.pal/config.env`.

## Development

- All shell scripts must pass `shellcheck` with zero warnings
- Tests use BATS-Core
- Run checks: `shellcheck $(find . -name '*.sh') && bats tests/`
- Use `set -euo pipefail` in all scripts

## Local plugin dev loop

Do NOT copy `skills/pal-*` into `~/.claude/skills/` — shared helpers at plugin-root `lib/` rely on `${CLAUDE_PLUGIN_ROOT}`, which Claude Code only sets when it loads the directory as a plugin.

```bash
# 1. Validate the manifest (fast, no session needed)
claude plugin validate ~/repos/sandbox-pal
# → "✔ Validation passed"

# 2. Load for one session only (session-scoped; no global install state)
claude --plugin-dir ~/repos/sandbox-pal
# Inside: `/skills` lists pal-implement (and whatever else Phase 4+ adds).
# When a skill fires, ${CLAUDE_PLUGIN_ROOT} points at ~/repos/sandbox-pal,
# and every SKILL.md's `. "${CLAUDE_PLUGIN_ROOT}/lib/*.sh"` resolves.
```

The BATS smoke tests fake `CLAUDE_PLUGIN_ROOT=$REPO_ROOT` — useful for CI, but only the `--plugin-dir` flow above verifies that Claude Code itself populates the env var.

Publishing to the `claude-plugins-official` marketplace is out of scope for v1; treat this as a local/personal plugin.
