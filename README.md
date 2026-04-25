<p align="center">
  <img src="claude_pal_sides2_seed8888-transparent-v2.png" width="600" alt="Sandbox Pal">
</p>

<h1 align="center">Sandbox Pal</h1>

<p align="center">
  <a href="https://github.com/jnurre64/sandbox-pal/actions/workflows/ci.yml"><img src="https://github.com/jnurre64/sandbox-pal/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT"></a>
</p>

Local agent dispatch via a Claude Code plugin. Ships fresh Claude Code containers against GitHub issues with a gated plan → implement → review pipeline.

> **Independent, community-built project.** Not affiliated with, endorsed by, or sponsored by Anthropic, PBC. "Claude" and "Claude Code" are trademarks of Anthropic; this project uses Claude Code as its underlying agent and references these trademarks solely to describe that functionality.

See `docs/superpowers/specs/2026-04-18-sandbox-pal-design.md` for the design document.

**Status:** early development, v0.x. Not yet usable.

## What it does

1. You brainstorm and write an implementation plan (ideally via `superpowers:brainstorming` + `superpowers:writing-plans`).
2. You run `/sandbox-pal:pal-plan` to post that plan to a GitHub issue with an `<!-- agent-plan -->` marker.
3. You run `/sandbox-pal:pal-implement <issue#>`. The plugin `docker exec`s into the long-running `sandbox-pal-workspace` container, which:
   - Runs an **adversarial plan review** (fresh Claude session, read-only, verifies the plan matches the issue)
   - Implements the plan using **TDD with a retry loop** that feeds failing tests back to the model
   - Runs a **post-implementation review** (fresh session, read-only, checks the diff for scope creep / test quality)
   - Retries once if the post-review finds concerns
   - Pushes the branch and opens a PR

Claude credentials live in a Docker-managed named volume inside the workspace — never on the host, never in env vars.

## Getting started

```
/plugin marketplace add jnurre64/sandbox-pal
/plugin install sandbox-pal@sandbox-pal
/sandbox-pal:pal-setup
/sandbox-pal:pal-login
```

Full walkthrough in [`docs/install.md`](docs/install.md).

## Relationship to `claude-pal-action`

Sibling project. `claude-pal-action` (formerly `claude-agent-dispatch`) runs the same pipeline shape on self-hosted GitHub Actions runners for team / shared use. sandbox-pal is personal, local, and triggered from a Claude Code session rather than GitHub labels. sandbox-pal vendors the review-gate prompts and orchestration library from upstream — see `UPSTREAM.md`.

## Authentication

sandbox-pal uses a **long-running workspace container**. Claude credentials are
minted inside the container via `claude /login` and persisted in a
Docker-managed named volume — they never touch the host filesystem.

Only `GH_TOKEN` lives in your host shell.

### One-time setup

1. Export `GH_TOKEN` in your shell (add to `~/.bashrc` or `~/.zshrc`):
   ```bash
   export GH_TOKEN=github_pat_<token>
   ```
2. Install the plugin from the marketplace (from any `claude` session):
   ```
   /plugin marketplace add jnurre64/sandbox-pal
   /plugin install sandbox-pal@sandbox-pal
   ```
3. Provision the workspace and credentials:
   ```
   /sandbox-pal:pal-setup     # builds the image if absent; creates the workspace
   /sandbox-pal:pal-login     # interactive browser flow, run once per workspace lifetime
   ```

### Resource caps (optional)

Knobs in `~/.config/sandbox-pal/config.env`:

    PAL_CPUS=2.0
    PAL_MEMORY=4g
    PAL_SYNC_MEMORIES=true
    PAL_SYNC_TRANSCRIPTS=false

Changes apply on `/pal-workspace restart`.

### Terms of Service

Running `claude /login` inside a long-lived container under your own
subscription is endorsed by Anthropic's Legal & Compliance docs and mirrors
Anthropic's reference `.devcontainer`. Do not share the workspace volume or
expose the container to other users.

## Per-repo config (non-secret)

Optional per-repository settings live in `<your-project>/.pal/config.env`. These are non-secret knobs (e.g. `PAL_TEST_CMD=...`, `AGENT_BASE_BRANCH=main`, `DOCKER_HOST=...`) that the launcher forwards to the workspace for the duration of a run. Do not put credentials there — Claude credentials live in the workspace's named volume, and `GH_TOKEN` lives in your shell.

## Plugin skills and commands

- `/sandbox-pal:pal-brainstorm [idea]` — full ideation → PR flow (depends on the `superpowers` plugin)
- `/sandbox-pal:pal-plan [issue#] [--file <path>]` — publish a plan file to a GitHub issue
- `/sandbox-pal:pal-implement <issue#>` — dispatch the pipeline against the workspace container
- `/sandbox-pal:pal-setup` — guided workspace + credential setup (interactive)
- `/sandbox-pal:pal-workspace` — manage the workspace container (`start | stop | restart | status | edit-rules`)
- `/sandbox-pal:pal-login` — mint Claude credentials inside the workspace
- `/sandbox-pal:pal-logout` — revoke Claude credentials inside the workspace

Claude's natural-language skill selector also picks these up from plain-English prompts ("have pal build this", "publish this plan"), though explicit slash invocation is always available as a backup.

## Contributing

Contributions are welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the workflow, commit style, and test requirements. By participating you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md).

To report a security issue, see [`SECURITY.md`](SECURITY.md).

## License

sandbox-pal is released under the [MIT License](LICENSE).
