# lib/config.sh
# shellcheck shell=bash
# Verify required credentials are present in the process environment.
#
# claude-pal uses env-passthrough exclusively — this matches Anthropic's own
# anthropics/claude-code-action pattern, which is the only documented
# non-interactive auth mechanism for `claude` CLI. No on-disk secret file is
# maintained by the plugin: users export CLAUDE_CODE_OAUTH_TOKEN (or
# ANTHROPIC_API_KEY) and GH_TOKEN in their shell profile (once), and
# claude-pal forwards them to the container at `docker run -e ...` time.

pal_load_config() {
    # gh CLI checks GH_TOKEN first, GITHUB_TOKEN second; mirror that here so
    # Frightful-Games repos work without a direnv override.
    GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    local missing=()
    if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
        missing+=("CLAUDE_CODE_OAUTH_TOKEN (or ANTHROPIC_API_KEY)")
    fi
    if [ -z "${GH_TOKEN:-}" ]; then
        missing+=("GH_TOKEN")
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        echo "pal: missing required environment variable(s): ${missing[*]}" >&2
        echo "pal:" >&2
        echo "pal: one-time setup (bash/zsh):" >&2
        echo "pal:   claude setup-token              # prints an OAuth token valid ~1yr" >&2
        echo "pal:   echo 'export CLAUDE_CODE_OAUTH_TOKEN=<token>' >> ~/.bashrc" >&2
        echo "pal:   echo 'export GH_TOKEN=github_pat_<token>' >> ~/.bashrc" >&2
        echo "pal:   source ~/.bashrc                # or start a new shell" >&2
        echo "pal:" >&2
        echo "pal: or: /claude-pal:pal-setup for a guided walkthrough" >&2
        return 1
    fi
}
