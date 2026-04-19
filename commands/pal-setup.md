---
description: Use when the user hasn't configured claude-pal yet and wants a guided setup. Walks them through generating a Claude OAuth token via `claude setup-token`, obtaining a fine-grained GitHub PAT, and exporting both in their shell profile so claude-pal can read them at dispatch time. Env-passthrough only — does not write a secrets file. Use when user sees "missing required environment variable" from claude-pal, or asks "how do I set up pal", "configure claude-pal", "set pal tokens", or similar.
---

# pal-setup

Guide the user through one-time claude-pal authentication.

**Background.** claude-pal uses env-passthrough: the user exports two environment variables in their shell profile, and claude-pal forwards them to the container at `docker run` time. This matches Anthropic's documented `claude-code-action` pattern. Nothing is written to a plugin-managed secrets file.

## Check current state

First, run a preflight check to see what is already set:

```bash
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && echo "CLAUDE_CODE_OAUTH_TOKEN: set" || echo "CLAUDE_CODE_OAUTH_TOKEN: missing"
[ -n "${ANTHROPIC_API_KEY:-}" ]       && echo "ANTHROPIC_API_KEY: set"       || echo "ANTHROPIC_API_KEY: missing"
[ -n "${GH_TOKEN:-}" ]                && echo "GH_TOKEN: set"                || echo "GH_TOKEN: missing"
```

Interpret the output:
- Claude credential: exactly one of `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` must be set. OAuth is the common case for personal use.
- `GH_TOKEN` is required (must be a fine-grained PAT with access to the repos the user will dispatch against).

## Walkthrough

Ask the user these questions, one at a time, and tailor the instructions:

1. **Which Claude credential?**
   - "Do you have a Claude Pro/Max/Team/Enterprise subscription and want to use it for personal dispatches?" → OAuth token (via `claude setup-token`)
   - "Do you want to bill a Console API account?" → `ANTHROPIC_API_KEY` from https://console.anthropic.com/settings/keys

2. **Which GitHub token?**
   - Ask the user if they already have a fine-grained PAT they want to reuse, or want to create a new one.
   - Creation link: https://github.com/settings/personal-access-tokens/new
   - Minimum scopes for claude-pal dispatch: repository access for the repos they'll target; "Contents (read/write)", "Pull requests (read/write)", "Issues (read/write)".

3. **Which shell?**
   - Detect: `echo $SHELL`. Map to profile file:
     - `bash` → `~/.bashrc`
     - `zsh` → `~/.zshrc`
     - `fish` → `~/.config/fish/config.fish` (use `set -x VAR value` syntax)
     - Other → ask the user where they add env vars.

## Apply the exports

**Important: keep the token out of this conversation.** Run `claude setup-token` in a regular terminal (NOT the Claude Code session where this command is firing), and edit `~/.bashrc` directly. Never paste the OAuth token, API key, or PAT back into the Claude Code prompt, a chat, a screenshot, or a bug report. claude-pal reads them from your shell env — they never need to be text in a conversation.

For the OAuth path:

```bash
# In a regular terminal (separate from the Claude Code session):
claude setup-token
# Local machine with a browser: default browser opens automatically.
# SSH / headless: setup-token prints a URL — open it in the browser on your
# local machine, authorize, and the token still prints back in the SSH terminal.

# In that same terminal (or in an editor like `nano ~/.bashrc`), add these lines:
#   export CLAUDE_CODE_OAUTH_TOKEN=<the-token-that-just-printed>
#   export GH_TOKEN=<your-github-PAT>
# then:
source ~/.bashrc
```

For the API key path, substitute `CLAUDE_CODE_OAUTH_TOKEN` with `ANTHROPIC_API_KEY` and the token with the Console API key (created at https://console.anthropic.com/settings/keys — no OAuth flow needed).

## Verify

After the user exports, verify in the **current** session:

```bash
pal-preflight-check() {
    [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || [ -n "${ANTHROPIC_API_KEY:-}" ] || { echo "missing claude credential"; return 1; }
    [ -n "${GH_TOKEN:-}" ] || { echo "missing GH_TOKEN"; return 1; }
    GH_TOKEN="$GH_TOKEN" gh auth status >/dev/null 2>&1 || { echo "gh auth failed"; return 1; }
    echo "ok"
}
pal-preflight-check
```

If this prints `ok`, tell the user they're ready to run `/claude-pal:pal-plan` or `/claude-pal:pal-brainstorm`. Claude Code may need to be restarted so the new exports reach the plugin subprocess.

## Terms-of-service note

Remind the user:

- OAuth tokens (`sk-ant-oat01-*`) from `claude setup-token` are for **personal use only** per Anthropic's Consumer ToS (Feb 2026 update). Do not share your token, do not deploy claude-pal as a shared service, do not redistribute your token in a public repo.
- For commercial or shared use (running claude-pal as a service for others), use an `ANTHROPIC_API_KEY` from https://console.anthropic.com/ instead.
- See Anthropic's [Usage Policy](https://www.anthropic.com/legal/usage-policy) for the authoritative rules.
