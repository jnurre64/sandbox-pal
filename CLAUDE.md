# claude-pal

Local agent dispatch via a Claude Code plugin.

## Key Documentation

- Full design: `docs/superpowers/specs/2026-04-18-claude-pal-design.md`
- Implementation plan: `docs/superpowers/plans/2026-04-18-claude-pal.md`
- Upstream tracking (vendored pieces): `UPSTREAM.md`

## Architecture

claude-pal ships as a Claude Code plugin. Shared bash helpers under plugin-root `lib/` are referenced from every `SKILL.md` via `${CLAUDE_PLUGIN_ROOT}` (set by Claude Code at skill-invocation time). Do NOT use `claude-skill-path` or `$(dirname "${BASH_SOURCE[0]}")` dances in `SKILL.md` — use `${CLAUDE_PLUGIN_ROOT}/lib/foo.sh`.

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

claude-pal is **env-passthrough only** — credentials (`CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY`, plus `GH_TOKEN`) are read from the process environment and forwarded to the container at `docker run -e ...` time. There is no plugin-managed secrets file on disk. This matches Anthropic's own `anthropics/claude-code-action` pattern, which is the only documented non-interactive `claude` CLI auth mechanism. `lib/config.sh` asserts the env vars exist and prints guidance if missing; it does NOT read or write any file. Users wire up tokens once in their shell profile (`~/.bashrc` / `~/.zshrc`) — `/claude-pal:pal-setup` is the guided walkthrough.

Per-repo non-secret knobs (`PAL_TEST_CMD`, `AGENT_BASE_BRANCH`, `DOCKER_HOST`) may live in `<project>/.pal/config.env` — these are passed through by the launcher but never credentials.

## Development

- All shell scripts must pass `shellcheck` with zero warnings
- Tests use BATS-Core
- Run checks: `shellcheck $(find . -name '*.sh') && bats tests/`
- Use `set -euo pipefail` in all scripts

## Local plugin dev loop

Do NOT copy `skills/pal-*` into `~/.claude/skills/` — shared helpers at plugin-root `lib/` rely on `${CLAUDE_PLUGIN_ROOT}`, which Claude Code only sets when it loads the directory as a plugin.

```bash
# 1. Validate the manifest (fast, no session needed)
claude plugin validate ~/repos/claude-pal
# → "✔ Validation passed"

# 2. Load for one session only (session-scoped; no global install state)
claude --plugin-dir ~/repos/claude-pal
# Inside: `/skills` lists pal-implement (and whatever else Phase 4+ adds).
# When a skill fires, ${CLAUDE_PLUGIN_ROOT} points at ~/repos/claude-pal,
# and every SKILL.md's `. "${CLAUDE_PLUGIN_ROOT}/lib/*.sh"` resolves.
```

The BATS smoke tests fake `CLAUDE_PLUGIN_ROOT=$REPO_ROOT` — useful for CI, but only the `--plugin-dir` flow above verifies that Claude Code itself populates the env var.

Publishing to the `claude-plugins-official` marketplace is out of scope for v1; treat this as a local/personal plugin.
