# image/opt/pal/lib/claude-runner.sh
# shellcheck shell=bash
# Invoke claude -p with phase-specific tool allowlists and parse JSON output.

load_prompt() {
    local name="$1"
    local path="$PROMPTS_DIR/${name}.md"
    if [ ! -f "$path" ]; then
        log "claude-runner: prompt not found at $path"
        return 1
    fi
    cat "$path"
}

run_claude() {
    local prompt="$1"
    local allowed_tools="${2:-Read,Write,Edit,Bash(git *),Bash(ls *)}"
    local model_override="${3:-}"

    cd "$WORKTREE_DIR" || return 1
    local stderr_log
    stderr_log="$STATUS_DIR/claude-stderr-$(date +%s).log"
    # --disable-slash-commands prevents auto-activation of bundled skills
    # (notably fewer-permission-prompts) that can hijack the turn when the
    # agent hits repeated permission denials on phase-scoped allowlists.
    local claude_args=(
        -p "$prompt"
        --allowedTools "$allowed_tools"
        --disallowedTools "${AGENT_DISALLOWED_TOOLS:-mcp__github__*}"
        --max-turns "${AGENT_MAX_TURNS:-50}"
        --disable-slash-commands
        --output-format json
    )
    if [ -n "$model_override" ]; then
        claude_args+=(--model "$model_override")
    fi

    local timeout="${AGENT_TIMEOUT:-3600}"
    local stdout_log
    stdout_log="$STATUS_DIR/claude-stdout-$(date +%s).log"
    timeout "$timeout" claude "${claude_args[@]}" 2>"$stderr_log" | tee "$stdout_log"
    local ec="${PIPESTATUS[0]}"
    if [ "$ec" -ne 0 ]; then
        log "claude-runner: claude exited with code $ec (stderr: $(head -10 "$stderr_log")) (stdout first 500: $(head -c 500 "$stdout_log"))"
        echo '{"result":"claude timed out or errored","error":true}'
    fi
}

parse_claude_output() {
    local result="$1"
    local out
    out=$(echo "$result" | jq -r '.result // .result_text // empty' 2>/dev/null || echo "")
    if [ -z "$out" ]; then
        out="$result"
    fi
    echo "$out"
}
