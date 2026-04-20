<p align="center">
  <img src=".github/icon.png" width="600" alt="claude-pal">
</p>

[![CI](https://github.com/jnurre64/claude-pal/actions/workflows/ci.yml/badge.svg)](https://github.com/jnurre64/claude-pal/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Local agent dispatch via a Claude Code plugin. Ships fresh Claude Code containers against GitHub issues with a gated plan → implement → review pipeline.

See `docs/superpowers/specs/2026-04-18-claude-pal-design.md` for the design document.

**Status:** early development, v0.x. Not yet usable.

## What it does

1. You brainstorm and write an implementation plan (ideally via `superpowers:brainstorming` + `superpowers:writing-plans`).
2. You run `/claude-pal:pal-plan` to post that plan to a GitHub issue with an `<!-- agent-plan -->` marker.
3. You run `/claude-pal:pal-implement <issue#>` to launch an ephemeral Docker container that:
   - Runs an **adversarial plan review** (fresh Claude session, read-only, verifies the plan matches the issue)
   - Implements the plan using **TDD with a retry loop** that feeds failing tests back to the model
   - Runs a **post-implementation review** (fresh session, read-only, checks the diff for scope creep / test quality)
   - Retries once if the post-review finds concerns
   - Pushes the branch and opens a PR

Runs are ephemeral. Credentials never enter the image — only the running container's env for the duration of one run.

## Getting started

See [`docs/install.md`](docs/install.md).

## Relationship to `claude-pal-action`

Sibling project. `claude-pal-action` (formerly `claude-agent-dispatch`) runs the same pipeline shape on self-hosted GitHub Actions runners for team / shared use. claude-pal is personal, local, and triggered from a Claude Code session rather than GitHub labels. claude-pal vendors the review-gate prompts and orchestration library from upstream — see `UPSTREAM.md`.

## Authentication

claude-pal uses **env-passthrough** exclusively — it reads credentials from your shell environment and forwards them to the container at `docker run -e ...` time. No on-disk secrets file is maintained by the plugin. This matches Anthropic's documented `anthropics/claude-code-action` pattern, which is the only sanctioned non-interactive auth mechanism for `claude` CLI.

### One-time setup

```bash
# 1. Generate a Claude OAuth token (for personal/Pro/Max/Team use)
claude setup-token

# 2. Add exports to your shell profile (~/.bashrc, ~/.zshrc, etc.)
export CLAUDE_CODE_OAUTH_TOKEN=<the-token-from-step-1>
export GH_TOKEN=<github-fine-grained-PAT>

# 3. Reload
source ~/.bashrc
```

The GitHub token must be a fine-grained PAT with `Contents`, `Pull requests`, and `Issues` (read/write) access to the repositories you intend to dispatch against.

Alternatively, guided walkthrough: inside a Claude Code session with the plugin loaded, run `/claude-pal:pal-setup`.

### OAuth vs API key

- **`CLAUDE_CODE_OAUTH_TOKEN`** (from `claude setup-token`) — the common case for personal use. Valid ~1 year. Tied to your Pro/Max/Team subscription.
- **`ANTHROPIC_API_KEY`** (from https://console.anthropic.com/) — pay-as-you-go billing via a Console account. Required if you intend to run claude-pal as a shared service for others, or your workflow doesn't involve a subscription.

Set **exactly one** of the two. If both are set, Anthropic's CLI silently prefers `ANTHROPIC_API_KEY` and bills the Console account — claude-pal's preflight will fail hard if it detects both.

### Terms of Service

Claude subscription OAuth tokens (`sk-ant-oat01-*`) are for personal use only per Anthropic's Consumer Terms of Service (Feb 2026 update). **Do not** redistribute your token, commit it to a repo, or deploy claude-pal as a shared service using someone else's subscription. For commercial or multi-user scenarios, use an `ANTHROPIC_API_KEY` from the Console. See the [Anthropic Usage Policy](https://www.anthropic.com/legal/usage-policy).

The claude-pal source code (this repository) is public; your tokens are yours. Keep them in your shell profile — never in this repo, never in a built Docker image.

## Per-repo config (non-secret)

Optional per-repository settings live in `<your-project>/.pal/config.env`. These are non-secret knobs (e.g. `PAL_TEST_CMD=...`, `AGENT_BASE_BRANCH=main`, `DOCKER_HOST=...`) that the launcher passes through to the container. Do not put credentials there — credentials are env-only.

## Plugin skills and commands

- `/claude-pal:pal-brainstorm [idea]` — full ideation → PR flow (depends on the `superpowers` plugin)
- `/claude-pal:pal-plan [issue#] [--file <path>]` — publish a plan file to a GitHub issue
- `/claude-pal:pal-implement <issue#>` — dispatch the pal container on a posted plan
- `/claude-pal:pal-setup` — guided credential setup (interactive)

Claude's natural-language skill selector also picks these up from plain-English prompts ("have pal build this", "publish this plan"), though explicit slash invocation is always available as a backup.

## Contributing

Contributions are welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the workflow, commit style, and test requirements. By participating you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md).

To report a security issue, see [`SECURITY.md`](SECURITY.md).

## License

claude-pal is released under the [MIT License](LICENSE).
