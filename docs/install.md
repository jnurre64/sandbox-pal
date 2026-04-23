# Installing sandbox-pal

sandbox-pal is a Claude Code plugin that manages a long-running Docker workspace container and dispatches `claude` CLI runs against GitHub issues inside it. Everything runs on your host — no cloud service component.

## Prerequisites

- **Docker** 20.10+ (Docker Desktop on macOS/Windows; Docker Engine on Linux). `docker info` must succeed from your shell, and `docker volume` + `docker exec` must be available (both have been core since 17.06).
- **Claude Code CLI** installed on your host.
- **Git** and **`gh`** (GitHub CLI) installed.
- **Full-disk encryption** enabled on the host (LUKS / FileVault / BitLocker) — documented prerequisite, not enforced by sandbox-pal.
- **A Claude Pro / Max / Team subscription or Console account** — you'll log in inside the workspace container via `/pal-login`, same browser flow as a regular `claude` login.

### Windows additional prerequisites

- **Git for Windows** (provides Git Bash, which Claude Code requires).
- If both WSL and Git Bash are installed, set `CLAUDE_CODE_GIT_BASH_PATH` in `~/.claude/settings.json`:
  ```json
  { "env": { "CLAUDE_CODE_GIT_BASH_PATH": "C:\\Program Files\\Git\\bin\\bash.exe" } }
  ```

## Install steps

### 1. Export `GH_TOKEN` in your shell profile

sandbox-pal only needs **one** host env var: `GH_TOKEN`. Claude credentials live inside the workspace container (step 3) — they are never exported from your shell.

Create a fine-grained GitHub PAT at https://github.com/settings/personal-access-tokens. Grant repository access for each repo you plan to dispatch against, with these scopes:

- Contents: read and write
- Pull requests: read and write
- Issues: read and write
- Metadata: read

Append to `~/.bashrc` (or `~/.zshrc`):

```bash
# sandbox-pal
export GH_TOKEN=github_pat_...your-PAT...
```

Save, then `source ~/.bashrc` in any shell that needs the new value.

**Windows (PowerShell, persistent for the current user):**
```powershell
[System.Environment]::SetEnvironmentVariable('GH_TOKEN', 'github_pat_...', 'User')
# Open a new PowerShell / Git Bash to pick up the new env
```

> **Do not** set `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` in your shell — the workspace-container model does not use them. If you have them set from an earlier sandbox-pal install, `unset` them and remove them from your rc files. See [`docs/authentication.md`](authentication.md) for the full rationale.

### 2. Install the Claude Code plugin from the marketplace

From any `claude` session:

```
/plugin marketplace add jnurre64/sandbox-pal
/plugin install sandbox-pal@sandbox-pal
```

Claude Code pulls the repo into its plugin cache and persists the install across sessions. Verify:

```
/plugin          # should show sandbox-pal as loaded
/skills          # should list pal-plan, pal-implement, pal-workspace, pal-login, pal-logout, etc.
```

### 3. Create the workspace, build the image, and log in

In the same session:

```
/sandbox-pal:pal-setup
```

`pal-setup` verifies Docker + `GH_TOKEN`, then ensures the `sandbox-pal:latest` image exists. The first time you run it, `pal-setup` will offer to build the image (a few minutes; `docker build` against the Dockerfile inside the cached plugin). Subsequent runs are no-ops for the image step.

```
/sandbox-pal:pal-login
# → opens a browser to authorize Claude inside the workspace
# → writes /home/agent/.claude/.credentials.json into the `sandbox-pal-claude` named volume
# → one-time, persists for the workspace's lifetime
```

Verify:

```
/sandbox-pal:pal-workspace status
```

From the host shell you can inspect the volume:

```bash
docker volume inspect sandbox-pal-claude
docker exec sandbox-pal-workspace ls -la /home/agent/.claude/
```

### 4. First live dispatch (validate end-to-end)

```
# From a checkout of a GitHub repo the PAT can access:
/sandbox-pal:pal-plan
# → publishes the most recent docs/superpowers/plans/*.md file as a new issue
# → prints the issue URL

/sandbox-pal:pal-implement <the-issue-number>
# → runs preflight checks
# → docker execs the pipeline inside the workspace (adversarial review → TDD → post-impl review → PR)
# → prints the PR URL on success
```

Watch for errors at each stage. Common failures are covered below.

## Troubleshooting

First stop for any container-side issue: `/sandbox-pal:pal-workspace status`. It prints whether the workspace is running, whether `.credentials.json` is present in the volume, and resource usage. Also see [`docs/authentication.md`](authentication.md) for a deeper troubleshooting tree.

| Symptom | Cause | Fix |
|---|---|---|
| `pal: missing required environment variable GH_TOKEN` | PAT not exported in current shell | Re-read step 3; open a new shell after editing your profile |
| `pal: workspace not running` | Container stopped or never created | `/sandbox-pal:pal-workspace start` (or `/sandbox-pal:pal-setup` if it was never created) |
| `claude: please run /login` inside pipeline | Credentials missing or wiped from the volume | `/sandbox-pal:pal-login` to mint fresh credentials |
| `docker daemon not reachable` | Docker not running / wrong `DOCKER_HOST` | Start Docker Desktop / `sudo systemctl start docker`; check `echo $DOCKER_HOST` |
| `Claude Code is using WSL's bash, not Git Bash` (Windows) | WSL precedence in Claude Code settings | Set `CLAUDE_CODE_GIT_BASH_PATH` in `~/.claude/settings.json` (see Prerequisites) |
| `gh auth status` fails | Expired PAT or missing scopes | Re-issue the PAT per step 3 |
| Container network failures | Firewall allowlist too narrow for a private registry | Add entries to `PAL_ALLOWLIST_EXTRA_DOMAINS` in the target repo's `.pal/config.env` |
| `/sandbox-pal:pal-brainstorm` stops with "install superpowers" | `superpowers` plugin not loaded in the session | `claude --plugin-dir ~/repos/sandbox-pal --plugin-dir <path-to-superpowers>` — or skip `pal-brainstorm` and use `/sandbox-pal:pal-plan` directly on a plan you already have |

## Terms of Service

Running `claude /login` inside a long-lived container under your own subscription is endorsed by Anthropic's Legal & Compliance docs and mirrors Anthropic's reference `.devcontainer`. Do **not** share the workspace volume, expose the container to other users, or deploy sandbox-pal as a shared service using someone else's subscription. For commercial or multi-user scenarios, use a Console account and log in with it inside the workspace.

See: https://code.claude.com/docs/en/legal-and-compliance

## What's not in this release

v0.x ships the core flow (plan → implement → PR) in sync mode, plus the workspace-container lifecycle. Planned for later releases:

- Async mode + `/sandbox-pal:pal-status`, `/sandbox-pal:pal-logs`, `/sandbox-pal:pal-cancel`
- Expanded `/sandbox-pal:pal-revise` coverage for PR-review follow-ups

## Contributor / local dev loop

If you're developing against a clone of the repo (sending PRs, iterating on skills), the marketplace install is not what you want — use the session-scoped `--plugin-dir` instead so you can edit files and see changes immediately.

```bash
# Clone
git clone https://github.com/jnurre64/sandbox-pal.git ~/repos/sandbox-pal
cd ~/repos/sandbox-pal

# Validate the manifest (fast, no session needed)
claude plugin validate ~/repos/sandbox-pal
# → "✔ Validation passed"

# Build the image directly (the marketplace flow does this via /pal-setup;
# contributors often want to iterate on the Dockerfile without going through
# the skill each time)
./scripts/build-image.sh

# Load the plugin for one session
claude --plugin-dir ~/repos/sandbox-pal
```

`--plugin-dir` is scoped to that single `claude` session. Contributors typically have the marketplace install removed (`/plugin marketplace remove sandbox-pal`) while iterating, to avoid two loaded copies of the plugin fighting over skill names.
