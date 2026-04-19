# Installing claude-pal

claude-pal is a Claude Code plugin that launches a Docker container to run the `claude` CLI non-interactively against GitHub issues. Everything runs on your host — no cloud service component.

## Prerequisites

- **Docker** 20+ (Docker Desktop on macOS/Windows; Docker Engine on Linux). `docker info` must succeed from your shell.
- **Claude Code CLI** installed on your host and logged in interactively at least once (`claude` in a terminal).
- **Git** and **`gh`** (GitHub CLI) installed.
- **Full-disk encryption** enabled on the host (LUKS / FileVault / BitLocker) — documented prerequisite, not enforced by claude-pal.
- **A Claude Pro / Max / Team / Enterprise subscription** (for OAuth) OR an **Anthropic Console API key**.

### Windows additional prerequisites

- **Git for Windows** (provides Git Bash, which Claude Code requires).
- If both WSL and Git Bash are installed, set `CLAUDE_CODE_GIT_BASH_PATH` in `~/.claude/settings.json`:
  ```json
  { "env": { "CLAUDE_CODE_GIT_BASH_PATH": "C:\\Program Files\\Git\\bin\\bash.exe" } }
  ```

## Install steps

### 1. Clone the repo

```bash
git clone https://github.com/jnurre64/claude-pal.git ~/repos/claude-pal
cd ~/repos/claude-pal
```

### 2. Build the container image

```bash
./scripts/build-image.sh
# → builds claude-pal:latest on your local Docker daemon
```

Verify:

```bash
docker images claude-pal
```

### 3. Generate credentials

> **Keep your tokens out of chat.** Run `claude setup-token` in a regular terminal — **not inside a Claude Code session**, and never paste the resulting token into a Claude Code conversation, chat app, bug report, or screenshot. Edit `~/.bashrc` (or your shell's profile) directly with an editor so the token only ever lives in your shell env. claude-pal reads that env var at dispatch time; it never needs to see the token as text in a conversation.

**Claude authentication** — pick exactly ONE of these:

- **Subscription OAuth** (common for personal use):
  ```bash
  claude setup-token
  ```
  Run this in a terminal. It opens a URL that you authorize in a browser, then prints a token beginning `sk-ant-oat01-` (valid ~1 year).
  - **Local machine with a browser** (your desktop / laptop GUI): `setup-token` launches your default browser automatically — authorize and the token prints in the same terminal.
  - **SSH / remote shell (no local browser)**: `setup-token` prints the URL to stdout. Copy that URL into the browser on *your* machine (the one with a GUI), authorize there, and the token still prints back in the SSH terminal. Close the terminal when done — do not relay the token elsewhere.
- **Console API key** (for commercial / multi-user / pay-as-you-go scenarios): create one at https://console.anthropic.com/settings/keys — begins `sk-ant-api03-`. No OAuth flow; copy the key once at creation time.

**GitHub token:** create a fine-grained PAT at https://github.com/settings/personal-access-tokens. Grant repository access for each repo you plan to dispatch against, with these scopes:

- Contents: read and write
- Pull requests: read and write
- Issues: read and write
- Metadata: read

### 4. Export credentials in your shell profile

claude-pal reads credentials from the process environment at dispatch time — there is no `config.env` file managed by the plugin. This matches Anthropic's documented [`claude-code-action`](https://github.com/anthropics/claude-code-action) pattern.

> **Edit your shell profile directly — don't paste tokens into any chat.** Open `~/.bashrc` (or `~/.zshrc`) in an editor like `nano` or `vim`, or append via a shell `>>` redirect in the same terminal where `claude setup-token` just printed the token. The token value should go from the terminal → your profile file and nowhere else.

**Linux / macOS (bash):** open `~/.bashrc` in an editor and append these two lines, replacing the placeholders with your real token / PAT:

```bash
# claude-pal
export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...your-token...
export GH_TOKEN=github_pat_...your-PAT...
```

Save, then `source ~/.bashrc` in any shell that needs the new values. (Already-running shells won't pick up the change until you source the file or open a new shell — including any already-running Claude Code session.)

Same for `~/.zshrc` (zsh). Use `set -x CLAUDE_CODE_OAUTH_TOKEN ...` syntax for fish in `~/.config/fish/config.fish`.

**Windows (PowerShell, persistent for the current user):**
```powershell
[System.Environment]::SetEnvironmentVariable('CLAUDE_CODE_OAUTH_TOKEN', 'sk-ant-oat01-...', 'User')
[System.Environment]::SetEnvironmentVariable('GH_TOKEN', 'github_pat_...', 'User')
# Open a new PowerShell / Git Bash to pick up the new env
```

If you prefer an API key, substitute `CLAUDE_CODE_OAUTH_TOKEN` with `ANTHROPIC_API_KEY`. **Set exactly one of the two** — setting both is an error (preflight will reject it).

Alternative: once claude-pal is loaded as a plugin (step 5), run `/claude-pal:pal-setup` for a guided walkthrough.

### 5. Load claude-pal as a Claude Code plugin

claude-pal is a Claude Code plugin (manifest at `.claude-plugin/plugin.json`, shared libs at plugin-root `lib/`, skills under `skills/pal-*/SKILL.md`, commands under `commands/*.md`). It must be loaded *as a plugin* so `${CLAUDE_PLUGIN_ROOT}` is populated — do NOT copy `skills/pal-*` into `~/.claude/skills/`; the `lib/` sourcing inside each SKILL.md will fail.

**Developer / local-only (recommended today):**

```bash
# Validate the manifest (fast, no session needed)
claude plugin validate ~/repos/claude-pal
# → "✔ Validation passed"

# Load for one session at a time
claude --plugin-dir ~/repos/claude-pal
```

`--plugin-dir` is scoped to the one `claude` session. Inside that session, `/plugin` lists `claude-pal` and `/skills` lists `pal-implement` and `pal-plan`. Persistent / marketplace install is out of scope for v0.x.

### 6. Verify

Inside a `claude --plugin-dir ~/repos/claude-pal` session:

```
/plugin          # should show claude-pal as loaded
/skills          # should list pal-plan and pal-implement
```

From the host shell:

```bash
docker info                           # should succeed
[ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] || [ -n "$ANTHROPIC_API_KEY" ] && echo "claude cred: ok"
[ -n "$GH_TOKEN" ] && echo "gh cred: ok"
GH_TOKEN="$GH_TOKEN" gh auth status   # should succeed
```

### 7. First live dispatch (validate end-to-end)

```
# Inside the claude --plugin-dir session, from a checkout of a GitHub repo the PAT can access:
/claude-pal:pal-plan
# → publishes the most recent docs/superpowers/plans/*.md file as a new issue
# → prints the issue URL

/claude-pal:pal-implement <the-issue-number>
# → runs preflight checks
# → launches the container (adversarial review → TDD → post-impl review → PR)
# → prints the PR URL on success
```

Watch for errors at each stage. Common failures are covered below.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `pal: missing required environment variable(s): ...` | Token not exported in current shell | Re-read step 4; open a new shell after editing your profile |
| `pal: ERROR — both CLAUDE_CODE_OAUTH_TOKEN and ANTHROPIC_API_KEY are set` | Both auth env vars set | Unset whichever you don't want: `unset ANTHROPIC_API_KEY` (or vice-versa) |
| `docker daemon not reachable` | Docker not running / wrong `DOCKER_HOST` | Start Docker Desktop / `sudo systemctl start docker`; check `echo $DOCKER_HOST` |
| `Claude Code is using WSL's bash, not Git Bash` (Windows) | WSL precedence in Claude Code settings | Set `CLAUDE_CODE_GIT_BASH_PATH` in `~/.claude/settings.json` (see Prerequisites) |
| `gh auth status` fails | Expired PAT or missing scopes | Re-issue the PAT per step 3 |
| Container network failures | Firewall allowlist too narrow for a private registry | Add entries to `PAL_ALLOWLIST_EXTRA_DOMAINS` in the target repo's `.pal/config.env` |
| `/claude-pal:pal-brainstorm` stops with "install superpowers" | `superpowers` plugin not loaded in the session | `claude --plugin-dir ~/repos/claude-pal --plugin-dir <path-to-superpowers>` — or skip `pal-brainstorm` and use `/claude-pal:pal-plan` directly on a plan you already have |

## Terms of Service

Claude subscription OAuth tokens (`sk-ant-oat01-*`) are for personal use only per Anthropic's Consumer Terms of Service (Feb 2026 update). Do **not** redistribute your token, commit it to a repo, or deploy claude-pal as a shared service for others using someone else's subscription. For commercial or multi-user scenarios, use an `ANTHROPIC_API_KEY` from the Console instead.

See: https://www.anthropic.com/legal/usage-policy

## What's not in this release

v0.4.0 ships the core flow (plan → implement → PR) in sync mode. Planned for later releases:

- Async mode + `/claude-pal:pal-status`, `/claude-pal:pal-logs`, `/claude-pal:pal-cancel` (Phase 5)
- `/claude-pal:pal-revise` for PR-review follow-ups (Phase 6)
- OS-native credential stores — macOS Keychain, Windows Credential Manager, Linux `pass` (Phase 7 — deferred)
