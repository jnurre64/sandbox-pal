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
- `tests/` — BATS-Core tests

## Development

- All shell scripts must pass `shellcheck` with zero warnings
- Tests use BATS-Core
- Run checks: `shellcheck $(find . -name '*.sh') && bats tests/`
- Use `set -euo pipefail` in all scripts
