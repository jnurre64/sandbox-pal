<p align="center">
  <img src="claude_pal_sides2_seed8888-transparent-v3.png" width="200" alt="Sandbox Pal">
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
   - Runs an **adversarial plan review** (fresh session, read-only, structured verdict against the issue)
   - **Implements** the plan and pushes the work branch immediately, so a later failure never loses the commits (the next run resumes from that branch)
   - Runs the **pre-PR test gate**: `AGENT_TEST_COMMAND` with bounded `test-fix` sessions
   - Runs the **post-implementation review loop** — review → fix → review against a stamped findings ledger, up to `AGENT_POST_IMPL_REVIEW_MAX_RETRIES` cycles; if blocking findings survive, the PR still opens with a ⚠ header listing them
   - Opens the PR with the ledger summary, any permission denials, and any memory proposals in the body

Claude credentials live in a Docker-managed named volume inside the workspace — never on the host, never in env vars.

## Getting started

```
/plugin marketplace add jnurre64/sandbox-pal
/plugin install sandbox-pal@sandbox-pal
/sandbox-pal:pal-setup
/sandbox-pal:pal-login
```

Full walkthrough in [`docs/install.md`](docs/install.md).

## Relationship to `sandbox-pal-action`

Sibling project. `sandbox-pal-action` runs the same pipeline shape on self-hosted GitHub Actions runners for team / shared use. sandbox-pal is personal, local, and triggered from a Claude Code session rather than GitHub labels. sandbox-pal vendors the review-gate prompts and orchestration library from upstream — see `UPSTREAM.md`.

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

### Host config (optional)

Knobs in `~/.config/sandbox-pal/config.env`:

    PAL_CPUS=2.0
    PAL_MEMORY=4g
    PAL_SYNC_MEMORIES=true      # read-only copy of this repo's auto-memory into each run
    PAL_SYNC_TRANSCRIPTS=false
    PAL_SYNC_SKILLS=            # comma-separated ~/.claude/skills names to sync (default: none)

Caps apply on `/pal-workspace restart`; sync knobs apply on the next run. Full reference: [`docs/configuration.md`](docs/configuration.md).

### Terms of Service

Running `claude /login` inside a long-lived container under your own
subscription is endorsed by Anthropic's Legal & Compliance docs and mirrors
Anthropic's reference `.devcontainer`. Do not share the workspace volume or
expose the container to other users.

## Per-repo config (non-secret)

Optional per-repository settings live in `<your-project>/.pal/config.env` — every `AGENT_*`, `PAL_*` and `DOCKER_HOST=` line is forwarded into the pipeline for runs from that repo: the test gate (`AGENT_TEST_COMMAND`), review-gate caps, per-phase model / budget / effort / permission mode / MCP config, prompt overrides, extra egress domains. Template: [`.pal/config.env.example`](.pal/config.env.example); reference: [`docs/configuration.md`](docs/configuration.md). Do not put credentials there.

## Plugin skills and commands

- `/sandbox-pal:pal-brainstorm [idea]` — full ideation → PR flow (depends on the `superpowers` plugin)
- `/sandbox-pal:pal-plan [issue#] [--file <path>]` — publish a plan file to a GitHub issue
- `/sandbox-pal:pal-implement <issue#>` — dispatch the pipeline against the workspace container
- `/sandbox-pal:pal-revise <pr#>` — feed PR review feedback back through the pipeline
- `/sandbox-pal:pal-status [run-id]`, `/sandbox-pal:pal-logs <run-id>`, `/sandbox-pal:pal-cancel <run-id>` — async run management
- `/sandbox-pal:pal-memory [run-id] [--adopt <file> | --discard <file>]` — triage memory proposals from runs (the only path by which agent learnings reach host memory)
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
