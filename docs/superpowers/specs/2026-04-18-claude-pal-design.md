---
title: claude-pal — Local Agent Dispatch via Claude Code Skills
status: draft
date: 2026-04-18
author: jonny (with Claude)
---

# claude-pal — Design Document

## 1. Overview

**claude-pal** is a local agent dispatch system: a set of Claude Code skills that publish implementation plans to GitHub issues and launch ephemeral Docker containers that execute those plans, open PRs, and address review feedback. Each container is a fresh Claude Code CLI process running under the user's own subscription-backed OAuth token, isolated from the host, executing a gated pipeline (adversarial plan review → TDD implementation → post-implementation review → retry on concerns) before opening a PR.

The project is a sibling to `jnurre64/claude-agent-dispatch`, which runs the same pipeline shape on self-hosted GitHub Actions runners. claude-pal differs in threat model and trigger mechanism: no shared infrastructure, no multi-user runners, no Actions workflows. Instead, a user-triggered skill in the user's own Claude Code session launches a container on the user's own Docker daemon (local or remote) and notifies the user when it's done.

**Driving motivation.** The user wants the brainstorm → plan → implement → PR cycle that `claude-agent-dispatch` provides, but triggered from within a Claude Code CLI session as a natural extension of the planning conversation rather than from GitHub labels. The container frees the CLI session from permission-prompt friction while isolating autonomous work from the user's main workspace.

## 2. Scope

### In scope (v1)

- Linux-container Docker backend runnable on Linux, macOS, or Windows hosts (via Docker Desktop in Linux-containers mode)
- Six Claude Code skills: `/pal-plan`, `/pal-implement`, `/pal-revise`, `/pal-status`, `/pal-logs`, `/pal-cancel`
- Sync-default and async run modes
- Plan publishing as GitHub issue comments (with `<!-- agent-plan -->` marker), supporting both new-issue and existing-issue flows
- Vendored adversarial-plan and post-impl review gates from `claude-agent-dispatch`
- Desktop notification on async completion
- Preflight safety checks (auth precedence, permissions, Docker reachability, WSL/Git Bash resolution on Windows)
- Per-repo configuration for test commands, backend choice, remote Docker host

### Out of scope (v1)

- **Windows-container backend (v2, near-term)** — required for .NET Framework MVC work the user has planned
- **sbx (Linux) backend (future, optional)** — deferred until sbx matures, supports `CLAUDE_CODE_OAUTH_TOKEN` headlessly, and has non-vendor case studies
- GitHub webhook listening / auto-response to PR reviews (`/pal-revise` is manually invoked)
- Claude Code hook-based notification surfacing (future polish)
- Multi-user / team mode (explicitly excluded — project is personal-use only)

## 3. Terms of Service and threat model

claude-pal operates as **personal, individual-use infrastructure** under Anthropic's subscription-OAuth guidance. The design specifically matches Anthropic's documented endorsed patterns:

- Only the native `claude` CLI binary runs inside the container. No Agent SDK, no third-party harness, no OAuth forwarding to non-CLI clients.
- Authentication uses `CLAUDE_CODE_OAUTH_TOKEN` minted by `claude setup-token`, passed as an env var to the container — the path Anthropic documents for environments where browser login isn't possible.
- Single-user, no shared runners, no multi-human triggers.
- The agent runs only when the user explicitly invokes it — no scheduled loops, no daemon, no 24/7 service.

**Hardening over the endorsed baseline:**

- Outbound network is deny-by-default via iptables at container start; allowlist covers `api.anthropic.com`, `github.com`, configured package registries.
- `ANTHROPIC_API_KEY` must be unset before launch (silent-override footgun documented in `authentication.md`).
- Config file holds tokens at 0600 (NTFS ACL on Windows) with macOS Keychain / Windows Credential Manager auto-detection as hardening.
- Containers use `--rm`; no persistent container state.
- Full-disk encryption (LUKS / FileVault / BitLocker) is documented as a prerequisite.

**What we explicitly do not do:** forward `~/.claude/credentials.json` or any interactive-login artifacts into the container. That is the documented prohibited "credential forwarding" pattern. We use `setup-token`-minted credentials exclusively, which Anthropic built for this use case.

## 4. Architecture

```
┌─ Host (user's machine, or remote via DOCKER_HOST) ──────────────────┐
│                                                                      │
│  User's Claude Code CLI Session                                      │
│  │                                                                   │
│  │  /pal-plan 42                                                     │
│  │  /pal-implement 42 [--async]                                      │
│  │  /pal-revise 123 [--async]                                        │
│  │                                                                   │
│  │  ▼                                                                │
│  │  Skill execution layer (bash on Linux/macOS, Git Bash on Windows) │
│  │    - reads config.env (or Keychain / Credential Manager)          │
│  │    - runs preflight checks                                        │
│  │    - launches container                                           │
│  │    - forks watcher for async mode                                 │
│  │                                                                   │
│  │  ▼                                                                │
│  │  docker run --rm -e CLAUDE_CODE_OAUTH_TOKEN=...                   │
│  │             -e GH_TOKEN=... -v $runs/<run_id>:/status             │
│  │             claude-pal:latest <event> <repo> <number>             │
│  │                                                                   │
│  │  ┌─ Container (ephemeral, Ubuntu) ─────────────────────────────┐  │
│  │  │  entrypoint.sh:                                              │  │
│  │  │    1. apply iptables allowlist                               │  │
│  │  │    2. clone repo, setup worktree                             │  │
│  │  │    3. fetch issue/plan/PR from GitHub                        │  │
│  │  │    4. [gate A] adversarial plan review                       │  │
│  │  │    5. implement with TDD (retry-on-test-fail loop)           │  │
│  │  │    6. run test gate                                          │  │
│  │  │    7. [gate B] post-impl review                              │  │
│  │  │    8. [gate B retry if concerns]                             │  │
│  │  │    9. push branch, create PR with Closes #N                  │  │
│  │  │   10. write /status/status.json + /status/log                │  │
│  │  │   11. exit with status code                                  │  │
│  │  └──────────────────────────────────────────────────────────────┘  │
│  │                                                                   │
│  │  ▼                                                                │
│  │  Async: watcher reads status.json, fires desktop notification     │
│  │  Sync: skill reads status.json, prints summary                    │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
                    │
                    ▼
            ┌─── GitHub ────┐
            │ Issues + PRs  │
            │ <!-- agent-plan --> comment │
            └───────────────┘
```

## 5. Host-side components

### 5.1 Skills

Six skills, all prefixed `pal-`. Each is a markdown file with `shell: bash` frontmatter (default).

| Skill | Arguments | Purpose |
|---|---|---|
| `/pal-plan` | `[issue#] [--file <path>]` | Publish the implementation plan from the current conversation as an issue comment with `<!-- agent-plan -->` marker. If no issue#, create a new issue. Does **not** launch the container — gives the user a checkpoint to review the plan on GitHub before dispatching. Auto-detects the most recent plan file in `docs/superpowers/plans/` if `--file` is not given. |
| `/pal-implement` | `<issue#> [--async]` | Launch a container that executes the pipeline against the plan posted on the issue. Sync by default (streams logs, returns with PR link). `--async` detaches and fires a notification on completion. |
| `/pal-revise` | `<pr#> [--async]` | Launch a container that addresses PR review feedback. Fetches PR branch + review comments + line-level feedback, runs a focused implementation pass. Skips adversarial-plan review; runs test gate and post-impl review. |
| `/pal-status` | `[run_id] [--clean]` | List in-flight and recent runs, or detail one. Reconciles stale status files against `docker ps`. `--clean` prunes entries older than N days. |
| `/pal-logs` | `<run_id> [--follow]` | Tail logs for a run. Used internally by sync mode. |
| `/pal-cancel` | `<run_id>` | Kill an in-flight container (SIGTERM then SIGKILL). Writes `cancelled` status. |

Skill implementations live in `skills/pal-*/SKILL.md` with shared helpers sourced from `skills/lib/*.sh`.

### 5.2 Config file — `~/.config/claude-pal/config.env`

Path resolution:
- Linux/macOS: `$XDG_CONFIG_HOME/claude-pal/config.env` (fallback `~/.config/claude-pal/config.env`)
- Windows: `%LOCALAPPDATA%\claude-pal\config.env`

Permissions: 0600 on Linux/macOS; NTFS ACL restricting to current user on Windows. Preflight check validates before each run.

```bash
# Claude authentication (exactly one of these required)
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
# or ANTHROPIC_API_KEY=sk-ant-api-...

# GitHub authentication (personal PAT or bot PAT)
GH_TOKEN=github_pat_...

# Optional: notifier preferences
PAL_NOTIFY=true
PAL_NOTIFY_COMMAND_OVERRIDE=

# Optional: default backend
PAL_BACKEND=docker-linux   # docker-linux | docker-windows (v2) | sbx-linux (future)

# Optional: remote Docker daemon
DOCKER_HOST=               # e.g., ssh://user@strongbad.local
```

**Keychain auto-detection** (hardening beyond baseline):
- macOS: skill tries `security find-generic-password -a $USER -s claude-pal-oauth -w` first; falls back to config.env
- Windows: PowerShell `Get-StoredCredential -Target claude-pal-oauth` first; falls back
- Linux: no auto-detection (libsecret doesn't work headless); document `pass` as opt-in via `PAL_CRED_SOURCE=pass:claude-pal/oauth`

### 5.3 Per-repo config — `.pal/config.env` (committed or gitignored)

Lives at `$repo_root/.pal/config.env`. Mirrors the `.agent-dispatch/config.env` pattern from upstream, with `PAL_`-prefixed additions:

```bash
# Backend override for this repo (e.g., for .NET Framework MVC)
PAL_BACKEND=docker-windows

# Test commands
AGENT_TEST_COMMAND=bun test
AGENT_TEST_SETUP_COMMAND=bun install

# Phase-specific tool allowlists
AGENT_ALLOWED_TOOLS_IMPLEMENT=Read,Write,Edit,Bash(bun *),Bash(git *)

# Model overrides
AGENT_MODEL_IMPLEMENT=claude-sonnet-4-6
AGENT_MODEL_ADVERSARIAL_PLAN=claude-sonnet-4-6

# Review gate toggles (defaults: all true)
AGENT_ADVERSARIAL_PLAN_REVIEW=true
AGENT_POST_IMPL_REVIEW=true
AGENT_POST_IMPL_REVIEW_MAX_RETRIES=1

# Allowlist extensions (comma-separated domains)
PAL_ALLOWLIST_EXTRA_DOMAINS=some.private.registry.example.com

# Remote Docker for this repo (overrides global)
DOCKER_HOST=
```

Placed in a separate `.pal/` directory so it can coexist with `.agent-dispatch/` on repos that already use upstream.

### 5.4 Run registry

Location:
- Linux/macOS: `$XDG_DATA_HOME/claude-pal/runs/` (fallback `~/.local/share/claude-pal/runs/`)
- Windows: `%LOCALAPPDATA%\claude-pal\runs\`

Per-run directory layout:

```
runs/
└── 2026-04-18-1452-abc123/
    ├── container_id          # Docker container ID for ps-reconciliation
    ├── launch_meta.json      # { issue#, repo, mode, started_at, host_os }
    ├── status.json           # produced by container via bind-mount
    └── log                   # full container stdout/stderr (tee'd on sync)
```

Each run dir is immutable after completion. `/pal-status --clean` removes entries older than N days (default 30) or whose containers no longer exist.

### 5.5 Cross-platform notifier

Abstraction in `skills/lib/notify.sh`:

- Linux: `notify-send "claude-pal" "<message>" --icon=...`
- macOS: `osascript -e 'display notification "<message>" with title "claude-pal"'`
- Windows: `powershell -NoProfile -Command "New-BurntToastNotification -Text 'claude-pal', '<message>'"` (requires BurntToast module; documented in install guide)

Delivery failure is non-fatal — logged but doesn't fail the run. Users can override with `PAL_NOTIFY_COMMAND_OVERRIDE` pointing at a custom script.

### 5.6 Preflight checks

Each `/pal-implement` and `/pal-revise` invocation runs these before `docker run`:

1. `ANTHROPIC_API_KEY` is **unset** in caller's environment (hard abort if set — silent-override footgun)
2. Exactly one of `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` in resolved config (hard abort otherwise)
3. Config file permissions are 0600 / ACL-restricted
4. Docker daemon reachable via `docker info`, respecting `DOCKER_HOST` if set
5. **Windows only:** `bash --version` smoke test doesn't resolve to WSL's `bash.exe` — if it does, abort with instructions to set `CLAUDE_CODE_GIT_BASH_PATH` in Claude Code's `settings.json`
6. Optional: `gh auth status` succeeds with configured token (fast-fails on expired PAT)
7. No in-flight run exists for this issue (per-issue lock file in the run registry)

Each failure produces a specific error message with the fix.

## 6. Container components

### 6.1 Base image

`FROM ubuntu:24.04` with a `BASE_IMAGE` build-arg to allow future retargeting at `docker/sandbox-templates:claude-code` for sbx compatibility.

Baked-in tooling:
- `claude` CLI (installed via official npm or curl installer)
- `gh` (GitHub official CLI)
- `git`, `jq`, `curl`, `ca-certificates`
- `iptables` + `iptables-persistent` (for allowlist)
- `bash` 5+

Non-root `agent` user with sudo (consistent with sbx template conventions; eases future migration). Project-specific toolchains (Node, Python, .NET, Godot/GdUnit4, etc.) are added via per-repo image extension — see §6.5.

### 6.2 Entrypoint contract

A single bash script at `/opt/pal/entrypoint.sh` implements the pipeline contract.

**Inputs (env vars):**

| Variable | Required | Purpose |
|---|---|---|
| `EVENT_TYPE` | yes | `implement` or `revise` |
| `REPO` | yes | `owner/name` |
| `ISSUE_NUMBER` or `PR_NUMBER` | yes | target number |
| `CLAUDE_CODE_OAUTH_TOKEN` | yes (if no API key) | Claude auth |
| `ANTHROPIC_API_KEY` | yes (if no OAuth) | Claude auth (alternate) |
| `GH_TOKEN` | yes | GitHub auth |
| `AGENT_TEST_COMMAND` | no | project test runner |
| `AGENT_TEST_SETUP_COMMAND` | no | optional test prep |
| `AGENT_ALLOWED_TOOLS_{TRIAGE,IMPLEMENT,REVIEW}` | no | phase-specific tool allowlists |
| `AGENT_MODEL_{IMPLEMENT,ADVERSARIAL_PLAN,...}` | no | per-phase model overrides |
| `AGENT_*_REVIEW` | no | review-gate toggles |
| `PAL_ALLOWLIST_EXTRA_DOMAINS` | no | extend firewall allowlist |

**Outputs:**

- `/status/status.json` — structured result (see §7.3)
- `/status/log` — full pipeline log
- Exit code 0 on success, non-zero on failure

**Pipeline phases:**

1. Apply iptables allowlist (§6.3)
2. Clone repo + setup worktree on branch `agent/issue-N`
3. Fetch issue body, comments, attached gists/attachments (data-pipeline pattern from upstream)
4. For `implement`: locate latest `<!-- agent-plan -->` comment; extract to `AGENT_PLAN_CONTENT`. If no matching comment exists: fail with `outcome: failure`, `failure_reason: no_plan_found`.
5. **Gate A — adversarial plan review** (read-only tools; skipped for `revise`). On `needs_clarification`: post comment, write `clarification_needed` status, exit. On `corrected`: update plan, proceed. On `approved`: proceed.
6. Implement with TDD. Inner retry loop: up to N iterations of (run claude -p with implement prompt + read-write tools) → (run `AGENT_TEST_COMMAND`) → if green, break; if red, feed failing output into the next iteration's prompt.
7. If no commits: write `failure` (empty_diff), exit.
8. **Gate B — post-impl review** (read-only tools). On `approved`: proceed. On `concerns`: gate B retry.
9. **Gate B retry:** one pass with read-write tools to address concerns, re-run tests, re-run gate B. If still concerns after retry: write `review_concerns_unresolved` status, don't open PR.
10. Push branch, `gh pr create` with `Closes #N`, capture PR URL.
11. Write `success` status.json, exit 0.

Global `ERR`/`EXIT` trap writes `failure` status on any uncaught error.

### 6.3 Firewall allowlist

Data file at `/opt/pal/allowlist.yaml`:

```yaml
domains:
  - api.anthropic.com
  - github.com
  - objects.githubusercontent.com
  - codeload.github.com
  - api.github.com
  - uploads.github.com
  - raw.githubusercontent.com
  - registry.npmjs.org
  - pypi.org
  - files.pythonhosted.org
  - api.nuget.org
  - deb.debian.org       # for apt in Ubuntu
  - security.ubuntu.com
  # ... extensible per-repo via PAL_ALLOWLIST_EXTRA_DOMAINS
```

On Linux, the entrypoint programs iptables rules derived from this file (resolve domains → IPs at startup; allow TCP 443 out to those IPs; default-deny otherwise).

For v2 (Windows container), a PowerShell entrypoint reads the same file and programs Windows Firewall rules via `New-NetFirewallRule` — one policy file, two implementations.

### 6.4 Adversarial plan review and post-impl review

Vendored from `jnurre64/claude-agent-dispatch`:

- `prompts/adversarial-plan.md`
- `prompts/post-impl-review.md`
- `prompts/post-impl-retry.md`
- `scripts/lib/review-gates.sh` and the `_extract_review_json` helper

Vendored copies tracked in `UPSTREAM.md` with source path + upstream commit hash at time of vendor. A `scripts/diff-upstream.sh` helper diffs vendored copies against a local `claude-agent-dispatch` checkout for periodic resync.

### 6.5 Per-repo image extensions (for project toolchains)

Projects with specific toolchain needs (Godot + GdUnit4, .NET SDK, Mono for .NET Framework, etc.) extend the base image. Pattern: repo ships a `.pal/Dockerfile.extra` that `FROM claude-pal:latest` and layers project-specific installs. The skill detects presence of this file at build time and produces a per-repo tag (`claude-pal:<repo>`).

For v1, this is a documented convention rather than automatic build machinery. The skill's launch logic picks the image tag based on whether `.pal/Dockerfile.extra` exists.

## 7. Data contracts

### 7.1 Plan comment format

Standard HTML-comment marker, followed by the plan content:

```markdown
<!-- agent-plan -->
## Implementation Plan

### Problem Statement
...

### Proposed Changes
- **path/to/file**: ...

### Test Strategy
...

### Risks / Tradeoffs
...
```

The container finds the **latest** comment matching this marker (newest wins) to allow replanning via a fresh `/pal-plan` post.

### 7.2 launch_meta.json (written by skill, read by `/pal-status`)

```json
{
  "run_id": "2026-04-18-1452-abc123",
  "event_type": "implement",
  "repo": "Frightful-Games/webber",
  "issue_number": 42,
  "pr_number": null,
  "mode": "async",
  "started_at": "2026-04-18T14:52:03Z",
  "host_os": "linux",
  "backend": "docker-linux",
  "docker_host": null,
  "image_tag": "claude-pal:webber"
}
```

### 7.3 status.json (written by container, read by host)

```json
{
  "run_id": "2026-04-18-1452-abc123",
  "phase": "complete",
  "started_at": "2026-04-18T14:52:03Z",
  "completed_at": "2026-04-18T15:11:47Z",
  "outcome": "success",
  "failure_reason": null,
  "pr_number": 317,
  "pr_url": "https://github.com/Frightful-Games/webber/pull/317",
  "commits": ["abc1234", "def5678"],
  "review_concerns_addressed": [],
  "review_concerns_unresolved": []
}
```

`outcome` values: `success` | `failure` | `clarification_needed` | `review_concerns_unresolved` | `cancelled`.

`phase` values: `cloning` | `fetching_context` | `adversarial_review` | `implementing` | `testing` | `post_impl_review` | `post_impl_retry` | `pushing_pr` | `complete` | `failed`.

Atomic writes (write to `.tmp`, rename in place) so host-side readers never see partial content.

## 8. Workflow flows

### 8.1 Plan publishing

```
User: brainstorm in CLI (superpowers:brainstorming + writing-plans)
  → writing-plans produces a plan file at its conventional output path
    (docs/superpowers/plans/YYYY-MM-DD-<topic>-plan.md by default)

User: /pal-plan [issue#] [--file path]
  → Skill locates plan file:
      - if --file given: use it (absolute or repo-relative path)
      - else: most recent file in docs/superpowers/plans/
      - if neither resolves: fail with clear error pointing to --file
  → Skill reads plan content
  → If no issue#:
      - derive title from plan's first H1/H2
      - gh issue create --title "..." --body "<problem summary>"
      - capture new issue#
  → gh issue comment <issue#> --body "<!-- agent-plan -->\n<plan content>"
  → Print issue URL and next-step hint: "/pal-implement <issue#>"
```

### 8.2 Implement (sync)

```
User: /pal-implement 42
  → Preflight checks
  → Launch container in foreground, bind-mount runs/<run_id>/ to /status
  → Stream docker output via tee to runs/<run_id>/log and terminal
  → Container runs pipeline, writes status.json
  → Skill reads status.json, pretty-prints:
      "✓ Pipeline complete. PR #317 opened: https://..."
      or "✗ Failed at phase <X>: <reason>"
```

### 8.3 Implement (async)

```
User: /pal-implement 42 --async
  → Preflight checks
  → Launch container detached, record container_id
  → Fork watcher subshell:
      (docker wait $id
       && read status.json
       && fire notifier "PR #317 opened" or "Failed: <reason>") &
  → Print run_id, log path, status path
  → Return immediately
  → [user keeps working]
  → Container exits → notifier fires
  → User runs /pal-status to inspect outcome
```

### 8.4 Revise (PR review feedback)

```
User: /pal-revise 317 [--async]
  → Preflight checks
  → Skill fetches PR details (branch, review comments, line-level feedback)
  → Container launched with EVENT_TYPE=revise and PR context env vars
  → Pipeline skips adversarial plan review
  → Fetches PR branch, extracts review concerns
  → Runs focused implementation pass with review concerns as input
  → Runs test gate
  → Runs post-impl review
  → Pushes new commits to existing PR branch (no new PR)
  → Updates status, notifies
```

### 8.5 Clarification cycle

If the adversarial plan review returns `needs_clarification`:
- Container posts a comment on the issue with the specific questions
- Writes `clarification_needed` status
- Exits

Host side:
- `/pal-status` shows the run's final outcome as `clarification_needed`
- User answers the questions on GitHub (or edits the plan comment)
- User re-invokes `/pal-implement <issue#>` — fresh run, picks up the latest plan comment

## 9. Backend roadmap

### 9.1 v1 — plain Docker, Linux container

- `FROM ubuntu:24.04`
- Bash entrypoint at `/opt/pal/entrypoint.sh`
- iptables allowlist
- Runs on Linux, macOS, or Windows hosts (Docker Desktop in Linux-containers mode)
- Skill backend adapter: `skills/lib/backend-docker-linux.sh` (invokes `docker run`)

### 9.2 v2 — plain Docker, Windows container (near-term)

- `FROM mcr.microsoft.com/dotnet/framework/sdk:ltsc2022` (or similar, depending on target .NET Framework version)
- PowerShell entrypoint at `C:\opt\pal\entrypoint.ps1` implementing the same contract
- Windows Firewall allowlist programmed via `New-NetFirewallRule`
- Requires Windows host with Docker Desktop in Windows-containers mode, **or** remote Windows Docker daemon targeted via `DOCKER_HOST=ssh://windows-box`
- Skill backend adapter: `skills/lib/backend-docker-windows.sh` (may target remote daemon)
- Per-repo config: `PAL_BACKEND=docker-windows` + usually `DOCKER_HOST=ssh://...`

Architectural commitments made in v1 that keep v2 cheap:
- Entrypoint is a contract (env in, status file out, exit code) — not tied to bash
- Firewall allowlist is a data file (YAML), not code
- Status schema is platform-neutral JSON
- Skill backend-adapter layer stubs `backend-docker-windows.sh` from v1 (returns "not implemented")

### 9.3 Future — sbx (Linux)

Contingent on:
- sbx reaching GA with stable OAuth surface
- Documented headless-host flow for subscription auth (current `/login` path is interactive)
- Non-vendor case studies of sbx in dispatch-like use cases

Migration cost when those conditions are met: rebase Dockerfile's `BASE_IMAGE` to `docker/sandbox-templates:claude-code`, push image to a registry (sbx has its own image store), add `skills/lib/backend-sbx-linux.sh` adapter (~100 lines). Entrypoint, prompts, status schema, and skill surface are unchanged.

### 9.4 What we explicitly won't do

- Build a Windows-host-only path that requires Windows Docker Desktop on the user's primary machine. Remote Docker daemon is the supported path — a Linux/macOS laptop can target a Windows box's Docker for v2 workloads.
- Re-implement features that live in `claude-agent-dispatch` (GitHub Actions orchestration, label state machine, Discord/Slack bots). claude-pal trades on the local/skill-driven niche; the Actions-runner niche is upstream's.

## 10. Dependencies and reuse

### 10.1 Vendored from `jnurre64/claude-agent-dispatch`

- `prompts/adversarial-plan.md`
- `prompts/post-impl-review.md`
- `prompts/post-impl-retry.md`
- `prompts/implement.md` (lightly adapted for single-session flow — no reference to label state, adjusted to write PR body from status.json)
- `scripts/lib/review-gates.sh` (the gate orchestration, `_extract_review_json`)
- Data-pipeline pattern for fetching issue attachments and gists

Tracked in `UPSTREAM.md`:
- Source repo + path
- Upstream commit at time of vendoring
- Any local modifications

`scripts/diff-upstream.sh` — helper that diffs vendored copies against a local `claude-agent-dispatch` checkout.

### 10.2 Not vendored

- The event-driven orchestrator `scripts/agent-dispatch.sh` and its handler functions (`handle_new_issue`, `handle_implement`, `handle_pr_review`) — coupled to the Actions event model and label state machine; irrelevant in a single-run container.
- `scripts/lib/notify.sh` (Discord/Slack bot notification) — out of scope; our notifier is desktop-local.
- The label state machine — claude-pal has no state machine because each container is a single linear run.

### 10.3 Not used: `frankbria/ralph-claude-code`

Considered and rejected. The retry-on-test-failure pattern (its most useful feature for our case) is implemented directly in the container entrypoint as a ~30-line loop. Avoids adding a second vendored shell project with its own install model and config format. Borrow ideas, don't vendor.

## 11. Error handling

- Container entrypoint uses `set -euo pipefail` and global `ERR`/`EXIT` trap. Any uncaught error writes a `failure` status.json with the failing phase and exit code before the container exits.
- Preflight failures on the host produce clear error messages with remediation pointers (e.g., "ANTHROPIC_API_KEY is set in your shell — unset it and retry; see authentication.md §silent-override").
- Firewall-blocked network calls surface via specific failure reasons (`allowlist_denied`) with the blocked hostname — operator can extend `PAL_ALLOWLIST_EXTRA_DOMAINS` and retry.
- OAuth token expiry: claude CLI emits a known exit code; entrypoint recognizes and reports as `outcome: failure`, `failure_reason: oauth_expired`.
- Test-gate failure after max retries: `outcome: failure`, `failure_reason: tests_failed`, last test output captured in log.
- Empty diff (no commits) after implement phase: `outcome: failure`, `failure_reason: empty_diff` — typically means the plan was too vague or the model declined.

## 12. Testing strategy

- **Unit tests (host-side helpers):** BATS-Core, following upstream convention. Skill scripts tested in isolation with mocked `docker` / `gh` / file-system interactions.
- **Integration test:** smoke-test repo (toy project, trivial issue + plan) that should round-trip to PR in under 2 minutes. Runs in CI on Linux; manually run on macOS and Windows hosts before releases.
- **Platform matrix:**
  - v1 CI: Linux (Ubuntu 24.04)
  - v1 manual: macOS, Windows (Git Bash)
  - v2: Windows with Docker Desktop in Windows-containers mode
- **Vendored prompt drift check:** scheduled CI job that diffs vendored files against upstream and opens an issue if divergence exceeds a threshold.

## 13. Open implementation-detail items

Resolved during implementation, not in this spec:

- Exact iptables ruleset syntax (allowlist.yaml → rules) and behavior under dual-stack IPv4/IPv6
- Specific package versions baked in the base image
- Plan-file auto-detection heuristics beyond "most recent in `docs/superpowers/plans/`"
- Git Bash path auto-detection on Windows — whether to read `settings.json` or prompt
- `/pal-cancel` cleanup edge cases (containers in the middle of git push, etc.)
- Whether per-repo image extensions build locally or pull from a registry the user controls
- Exact text and formatting of `/pal-plan`'s posted comment (header content beyond just the plan)
- How `/pal-revise` distinguishes "general reviewer feedback" from "line-level inline comments" in its prompt

## 14. Future enhancements (deferred beyond v2)

- sbx-Linux backend (§9.3 conditions)
- Claude Code hook-based notification surfacing (auto-announce completion on next Claude Code interaction)
- Automatic plan revision when the user edits the `<!-- agent-plan -->` comment
- Ensemble adversarial review (multiple reviewer models)
- Parallel multi-issue dispatch with resource limits
- Shared config between claude-pal and claude-agent-dispatch for projects that use both

---

## Appendix A: ToS citations

Key quotes from the authoritative documents that justify the design choices in §3:

> "Running the official `claude` CLI binary on your own machine, authenticated with your Pro/Max/Team/Enterprise subscription" is **explicitly allowed**.
> — `docs/claude-code-subscription-automation-guide.md`

> "Using `claude setup-token` to generate a long-lived OAuth token for CI/CD environments where browser login isn't possible — this is Anthropic's officially documented path" is **explicitly allowed**.
> — `docs/claude-code-subscription-automation-guide.md`

> "Plain Docker + `CLAUDE_CODE_OAUTH_TOKEN` ... exactly the use case Anthropic built `setup-token` for."
> — `docs/claude-code-subscription-automation-guide.md`

> "Copying your `~/.claude/` credentials directory into containers, CI systems, or other developers' environments. This is credential forwarding and falls outside the supported Claude Code authentication paths."
> — `jnurre64/claude-agent-dispatch/docs/authentication.md`

> "Never set both env vars simultaneously. `ANTHROPIC_API_KEY` takes precedence over `CLAUDE_CODE_OAUTH_TOKEN` in Claude Code's resolution order. If both are set, the Console API key is used silently."
> — `jnurre64/claude-agent-dispatch/docs/authentication.md`

## Appendix B: Naming collision rationale

`claude-pal` was chosen after collision checks against `claude-buddy` (heavy collision: Anthropic's `/buddy` April 1 2026 pet feature, existing npm package, existing competing product at `claude-buddys.com`), `claude-sidekick` (crowded: 6+ active repos, multiple commercial products including Shopify and monday.com using "sidekick" for AI dev assistants, Anthropic's own marketing calling Claude Code a "coding sidekick"), `claude-ditto`/`claude-shadow`/`claude-partner` (all major collisions including Anthropic's official Partner Network for the last), and `claude-doppelganger` (clean namespace but poor CLI ergonomics — long, hard to spell).

`claude-pal` has minor residual signals (two recently-pushed same-name repos in different niches, `claudepal.com` redirect-squatted to an unrelated marketing tool), all non-blocking. Grab repo + `claude-pal.app` domain before additional discovery noise accumulates.
