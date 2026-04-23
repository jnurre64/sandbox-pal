# Authentication

Single source of truth for how sandbox-pal authenticates.

## TL;DR

Setup is two slash commands, no env-var credentials for Claude:

```
/pal-setup     # creates the `sandbox-pal-claude` named volume + `sandbox-pal-workspace` container
/pal-login     # browser flow, run once per workspace lifetime
```

Your shell only needs `GH_TOKEN`. There is **no** `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` env-var path in sandbox-pal.

## Why not env-var auth

Earlier drafts of sandbox-pal used env-passthrough — the host shell held a `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`), and every run forwarded it to an ephemeral container via `docker run -e`. The workspace-container rework removed that path entirely. The rationale (summarized from [`docs/superpowers/specs/2026-04-21-sandbox-pal-auth-rework.md`](superpowers/specs/2026-04-21-sandbox-pal-auth-rework.md) §4):

- **Matches Anthropic's vendor-official pattern.** Anthropic's reference [`.devcontainer`](https://github.com/anthropics/claude-code/tree/main/.devcontainer) runs `claude /login` **inside** the container and persists the resulting `.credentials.json` in a Docker-managed named volume. That's a tacit Terms-of-Service endorsement for the `/login`-inside-container pattern ([Claude Code Legal & Compliance](https://code.claude.com/docs/en/legal-and-compliance)).
- **One auth path = one set of failure modes.** Env-passthrough had two subtly different variants (`CLAUDE_CODE_OAUTH_TOKEN` vs `ANTHROPIC_API_KEY`) and a silent-override footgun when both were set. The workspace model collapses that to a single path.
- **Credentials never touch the host filesystem.** `.credentials.json` lives in the `sandbox-pal-claude` Docker volume; it never appears in `~/.bashrc`, `~/.zshrc`, or `~/.claude/` on the host.
- **`claude setup-token` is eliminated** from user setup, which also removes the "paste a token into chat by accident" failure mode.

If you specifically need non-interactive env-var auth (for example, a CI runner), use the sibling project [`claude-pal-action`](https://github.com/jnurre64/claude-pal-action) instead — it's designed for the shared-runner / GitHub Actions topology.

## Where credentials live

Inside the workspace, at `/home/agent/.claude/.credentials.json`. On the host, that's backed by the `sandbox-pal-claude` named Docker volume.

Inspect:

```bash
# Host-side — see the volume metadata (mountpoint, driver, labels)
docker volume inspect sandbox-pal-claude

# Container-side — list what's there without cat'ing the secret
docker exec sandbox-pal-workspace ls -la /home/agent/.claude/
```

The credential file is readable only by the `agent` user inside the container. Do not cat it, screenshot it, or copy it out of the volume.

## Multi-subscription / Terms of Service

sandbox-pal is a **single-user, single-account** tool by design. Running `claude /login` inside a long-lived container under your own subscription is endorsed by the [Claude Code Legal & Compliance](https://code.claude.com/docs/en/legal-and-compliance) docs and mirrors Anthropic's reference [`.devcontainer`](https://github.com/anthropics/claude-code/tree/main/.devcontainer).

Hard "don't":

- Do not share the workspace volume with other users or machines.
- Do not expose the workspace container over the network.
- Do not use someone else's Claude subscription to log in.
- Do not deploy sandbox-pal as a shared service for a team — for commercial / multi-user scenarios, use a Console account (and still log in via `/pal-login` inside your own workspace on your own machine), or use `claude-pal-action` on a shared runner.

## Migration from env-var auth

If you installed an earlier version of sandbox-pal, you likely have these in your shell profile:

```bash
export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
export ANTHROPIC_API_KEY=sk-ant-api03-...
```

Both are unused by the current sandbox-pal. To migrate:

1. Remove the `export CLAUDE_CODE_OAUTH_TOKEN=...` and `export ANTHROPIC_API_KEY=...` lines from `~/.bashrc` (or `~/.zshrc`, or `~/.config/fish/config.fish`, etc.).
2. In any already-running shell: `unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY`.
3. Open a new shell, or `source` the profile you just edited.
4. Start the workspace and log in:

   ```
   /pal-setup
   /pal-login
   ```

Keep your `GH_TOKEN` — it's still required.

## Troubleshooting

| Symptom | Diagnosis | Fix |
|---|---|---|
| `pal: workspace not running` | Container is stopped or was never created | `/pal-workspace status` to confirm, then `/pal-workspace start` (or `/pal-setup` if the volume + container are missing) |
| `claude: please run /login` inside a pipeline run | Credentials were wiped, expired, or never minted in this workspace | `/pal-login` to mint fresh credentials |
| `docker volume inspect sandbox-pal-claude` errors with "no such volume" | The named volume was deleted (manually, or by `docker system prune --volumes`) | `/pal-workspace start` recreates the volume; then `/pal-login` to mint credentials again |
| `/pal-login` opens the browser but the token never lands | Firewall or network allowlist is blocking the OAuth callback domains | Check the workspace firewall allowlist (`image/opt/pal/allowlist.yaml`); see [`docs/install.md`](install.md) troubleshooting |
| Host shell still complains about `CLAUDE_CODE_OAUTH_TOKEN` | Preflight warns about a stale env var | See "Migration from env-var auth" above — `unset` it and remove from your rc files |

First stop for any issue: `/pal-workspace status`. It reports whether the workspace is running, whether `.credentials.json` is present, and current resource usage.

## References

- [Claude Code Legal & Compliance](https://code.claude.com/docs/en/legal-and-compliance)
- [Anthropic's reference `.devcontainer`](https://github.com/anthropics/claude-code/tree/main/.devcontainer)
- [sandbox-pal auth-rework design spec](superpowers/specs/2026-04-21-sandbox-pal-auth-rework.md)
