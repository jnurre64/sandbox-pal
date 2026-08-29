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

# ─── Redact secrets from phase output ────────────────────────────
# Applied at the capture point — before the envelope or the stderr log
# reaches any log line, parse, file, or comment. Inside the workspace
# container GH_TOKEN is always present (lib/launcher.sh injects it) and
# phase output is posted to public issues/PRs. (upstream #103)
redact_secrets() {
    local text
    text=$(cat)
    text=$(printf '%s' "$text" | sed -E \
        -e 's/github_pat_[A-Za-z0-9_]{20,}/[REDACTED_TOKEN]/g' \
        -e 's/gh[pousr]_[A-Za-z0-9]{20,}/[REDACTED_TOKEN]/g' \
        -e 's/([Aa]uthorization:[[:space:]]*([Tt]oken|[Bb]earer|[Bb]asic)[[:space:]]+)[^[:space:]"'\'']+/\1[REDACTED]/g')
    local var_name var_value
    while read -r var_name; do
        case "$var_name" in
            *TOKEN*|*SECRET*|*PASSWORD*|*API_KEY*|*APIKEY*|*CREDENTIAL*)
                var_value="${!var_name-}"
                # Short values are skipped: replacing a 2-char password
                # everywhere it appears would mangle ordinary text.
                if [ "${#var_value}" -ge 8 ]; then
                    text="${text//"$var_value"/[REDACTED:${var_name}]}"
                fi
                ;;
        esac
    done < <(compgen -e)
    printf '%s\n' "$text"
}

# ─── Surface permission denials ──────────────────────────────────
# Denied tool calls are the largest silent time sink in a headless
# loop: the phase retries variants and burns its turn cap on nothing.
# Every denial is an allow-list gap to fix in config. (upstream #105)
extract_permission_denials() {
    local result="$1"
    printf '%s' "$result" | jq -r '
        (.permission_denials // [])[]
        | .tool_name + ": "
          + ((.tool_input.command // .tool_input.file_path // .tool_input.pattern // "unknown") | tostring)
    ' 2>/dev/null || true
}

# Log each denial and append it (phase-tagged) to the run-scoped denials
# file, which the PR body and status.json read.
log_permission_denials() {
    local result="$1" phase="${2:-phase}"
    local denials
    denials=$(extract_permission_denials "$result")
    [ -z "$denials" ] && return 0
    log "WARN: ${phase}: permission denial(s) — each is an allow-list gap costing turns:"
    local line
    while IFS= read -r line; do
        log "  denied: $line"
        if [ -n "${WORKTREE_DIR:-}" ] && [ -d "$WORKTREE_DIR" ]; then
            mkdir -p "${WORKTREE_DIR}/.agent-data"
            printf '[%s] %s\n' "$phase" "$line" >> "${WORKTREE_DIR}/.agent-data/permission-denials.log"
        fi
    done <<< "$denials"
    return 0
}

# Markdown block of the run's accumulated denials. Empty when none.
denials_report_section() {
    local denials_file="${WORKTREE_DIR}/.agent-data/permission-denials.log"
    [ -s "$denials_file" ] || return 0
    # shellcheck disable=SC2016  # literal markdown code fence, not an expansion
    printf '\n### Permission Denials\n\nEach denial is an allow-list gap that cost the agent turns — fix it in `.pal/config.env` (`AGENT_ALLOWED_TOOLS_IMPLEMENT` / `AGENT_ALLOWED_TOOLS_TRIAGE`):\n\n```\n%s\n```\n' \
        "$(head -30 "$denials_file")"
}

# ─── Structured output (upstream #108) ───────────────────────────
get_structured_output() {
    local result="$1"
    printf '%s' "$result" \
        | jq -c '.structured_output // empty | select(. != null)' 2>/dev/null \
        || true
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
    local raw_output ec=0
    raw_output=$(timeout "$timeout" claude "${claude_args[@]}" 2>"$stderr_log") || ec=$?

    # Scrub at the point of capture (upstream #103).
    redact_secrets < "$stderr_log" > "${stderr_log}.tmp" && mv "${stderr_log}.tmp" "$stderr_log"
    printf '%s\n' "$raw_output" | redact_secrets | tee "$stdout_log"

    if [ "$ec" -ne 0 ]; then
        log "claude-runner: claude exited with code $ec (stderr: $(head -10 "$stderr_log")) (stdout first 500: $(head -c 500 "$stdout_log"))"
        echo '{"result":"claude timed out or errored (exit code '"$ec"')","error":true}'
    fi
}

# ─── Parse Claude JSON output ────────────────────────────────────
# `is_error` is authoritative and `subtype` is not a cause: an API-error
# envelope carries is_error:true together with subtype:"success", so the
# error check must come first and a non-error_* subtype is never
# interpolated as a reason. (upstream #102)
parse_claude_output() {
    local result="$1"
    if [ "$(printf '%s' "$result" | jq -r '.is_error // false' 2>/dev/null)" = "true" ]; then
        local detail
        detail=$(printf '%s' "$result" | jq -r \
            '[.terminal_reason, .api_error_status, (.result // .result_text)]
             | map(select(. != null and . != "") | tostring) | join(" — ")' 2>/dev/null)
        echo "Agent phase failed: API error${detail:+ — ${detail}}"
        return 0
    fi
    local out
    out=$(printf '%s' "$result" | jq -r '.result // .result_text // empty' 2>/dev/null || true)
    if [ -z "$out" ]; then
        out=$(printf '%s' "$result" | jq -r '.subtype // empty' 2>/dev/null || true)
        case "$out" in
            error_*) out="Agent stopped: $out" ;;
            *) out="" ;;
        esac
    fi
    if [ -z "$out" ]; then
        out="$result"
    fi
    echo "$out"
}

# ─── Classify how a phase ended ──────────────────────────────────
# fail_fast:   an API error — no later phase can recover it.
# recoverable: a turn/budget cap or timeout — what fix-up phases are for.
# ok:          a normal ending.
classify_claude_result() {
    local result="$1"
    if [ "$(printf '%s' "$result" | jq -r '.is_error // false' 2>/dev/null)" = "true" ]; then
        echo "fail_fast"
        return 0
    fi
    local subtype
    subtype=$(printf '%s' "$result" | jq -r '.subtype // empty' 2>/dev/null || echo "")
    case "$subtype" in
        error_*) echo "recoverable" ;;
        *)
            # run_claude's synthetic timeout envelope carries .error, not .is_error
            if [ "$(printf '%s' "$result" | jq -r '.error // false' 2>/dev/null)" = "true" ]; then
                echo "recoverable"
            else
                echo "ok"
            fi
            ;;
    esac
}
