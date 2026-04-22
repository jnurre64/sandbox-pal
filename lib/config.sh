# lib/config.sh
# shellcheck shell=bash
# claude-pal host-side config loader.
#
# Credentials: GH_TOKEN (required) is env-passthrough. Claude credentials are
# NOT env-passthrough — they are minted inside the workspace container via
# `claude /login`, persisted in the named volume `claude-pal-claude`, and
# never touch the host shell.
#
# Optional non-secret knobs live in ~/.config/claude-pal/config.env:
#   PAL_SYNC_MEMORIES     (default true)
#   PAL_SYNC_TRANSCRIPTS  (default false — *.jsonl are secret-tier)
#   PAL_CPUS              (default unset = uncapped)
#   PAL_MEMORY            (default unset = uncapped)

pal_load_config() {
    GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

    local cfg="${XDG_CONFIG_HOME:-$HOME/.config}/claude-pal/config.env"
    if [ -f "$cfg" ]; then
        # shellcheck disable=SC1090
        . "$cfg"
    fi

    : "${PAL_SYNC_MEMORIES:=true}"
    : "${PAL_SYNC_TRANSCRIPTS:=false}"
    export PAL_SYNC_MEMORIES PAL_SYNC_TRANSCRIPTS
    [ -n "${PAL_CPUS:-}" ]   && export PAL_CPUS
    [ -n "${PAL_MEMORY:-}" ] && export PAL_MEMORY

    if [ -z "${GH_TOKEN:-}" ]; then
        cat >&2 <<'EOF'
pal: missing required environment variable: GH_TOKEN

pal: one-time setup (bash/zsh):
pal:   echo 'export GH_TOKEN=github_pat_<token>' >> ~/.bashrc
pal:   source ~/.bashrc

pal: Claude credentials are handled by the workspace container (not an env var).
pal: After GH_TOKEN is set, run:
pal:   /pal-setup   # create workspace
pal:   /pal-login   # mint credentials inside the container
EOF
        return 1
    fi
}
