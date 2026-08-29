# image/opt/pal/lib/claude-runner.sh
# shellcheck shell=bash
# Container-side analogue of upstream scripts/lib/common.sh (sandbox-pal-action).
# Provides: load_prompt, run_claude, parse_claude_output, classify_claude_result,
#           get_structured_output, redact_secrets, extract_permission_denials,
#           log_permission_denials, denials_report_section, set_heartbeat (no-op),
#           preserve_branch, _resolve_memory_dir, load_shared_memory
# Expects from the sourcing script: log, STATUS_DIR, WORKTREE_DIR, PROMPTS_DIR,
#           BRANCH_NAME (for preserve_branch).

# ─── Prompt loading ──────────────────────────────────────────────
# load_prompt <name> [custom_path]
# custom_path may be absolute or worktree-relative (a repo can commit its
# own prompt overrides under e.g. .pal/prompts/). Falls back to the
# built-in $PROMPTS_DIR/<name>.md.
load_prompt() {
    local name="$1"
    local custom="${2:-}"
    local resolved=""
    if [ -n "$custom" ]; then
        if [[ "$custom" = /* ]]; then
            resolved="$custom"
        elif [ -n "${WORKTREE_DIR:-}" ]; then
            resolved="${WORKTREE_DIR}/${custom}"
        else
            resolved="$custom"
        fi
    fi
    if [ -n "$resolved" ] && [ -f "$resolved" ]; then
        cat "$resolved"
    elif [ -f "$PROMPTS_DIR/${name}.md" ]; then
        cat "$PROMPTS_DIR/${name}.md"
    else
        log "claude-runner: prompt not found for '${name}' (checked '${resolved:-<none>}' and $PROMPTS_DIR/${name}.md)"
        return 1
    fi
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

# ─── Liveness shim ───────────────────────────────────────────────
# Upstream stamps a lock-file heartbeat per phase; here status.json plus
# the host-side exec_pid are the liveness channel, so this is a no-op
# kept only so the vendored review-gates.sh needs no edits at call sites.
set_heartbeat() {
    :
}

# ─── Preserve implementation work on the remote ──────────────────
# Best-effort push so a controlled failure never strands finished commits
# in a worktree that is wiped at run end. setup_worktree resumes from
# origin/$BRANCH_NAME when it exists, so a preserved branch turns a
# re-run into a resume instead of a restart.
preserve_branch() {
    if git -C "$WORKTREE_DIR" push -u origin "$BRANCH_NAME" 2>/dev/null; then
        log "Preserved work branch: pushed ${BRANCH_NAME} to origin"
        return 0
    fi
    log "WARN: could not push ${BRANCH_NAME} to origin — commits remain only in the local worktree"
    return 1
}

# ─── Shared memory (read-only) ───────────────────────────────────
# AGENT_MEMORY_DIR names a directory the host synced in (lib/memory-sync.sh).
# Its MEMORY.md index is appended to the system prompt; --add-dir makes the
# pointed-at files readable. Memory is never writable from a phase.
_resolve_memory_dir() {
    local dir="${AGENT_MEMORY_DIR:-}"
    if [ -n "$dir" ] && [ -d "$dir" ]; then
        (cd "$dir" && pwd)
    else
        echo ""
    fi
}

load_shared_memory() {
    local mem_dir
    mem_dir=$(_resolve_memory_dir)
    [ -n "$mem_dir" ] && [ -f "${mem_dir}/MEMORY.md" ] || { echo ""; return 0; }
    echo "# Shared Project Memory (from interactive sessions)
The following memory was accumulated from working on this project. Use it for context but do NOT attempt to update memory files — the memory directory is read-only to you. If you learn something durable, write a proposal under .agent-data/memory-proposals/ as described in your task prompt.
The index below points at files in ${mem_dir}/ — when a pointer is relevant to your task, Read that file for the full memory.

$(cat "${mem_dir}/MEMORY.md")"
}

# ─── Invoke claude -p ────────────────────────────────────────────
# run_claude <prompt> <allowed_tools> [model] [schema_file] [PHASE]
# PHASE (ADVERSARIAL_PLAN|IMPLEMENT|TEST_FIX|POST_IMPL_REVIEW|POST_IMPL_RETRY)
# selects per-phase AGENT_BUDGET_USD_<PHASE> / AGENT_EFFORT_<PHASE> /
# AGENT_PERMISSION_MODE_<PHASE>. Every flag is optional and defaults to
# current behaviour — budget in particular is LIMITLESS unless set.
run_claude() {
    local prompt="$1"
    local allowed_tools="${2:-Read,Write,Edit,Bash(git *),Bash(ls *)}"
    local model_override="${3:-}"
    local schema_file="${4:-}"
    local phase="${5:-}"

    cd "$WORKTREE_DIR" || return 1
    local stamp
    stamp="${phase:-phase}-$(date +%s)"
    local stderr_log="$STATUS_DIR/claude-stderr-${stamp}.log"
    local stdout_log="$STATUS_DIR/claude-stdout-${stamp}.log"

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
    local effective_model="${model_override:-${AGENT_MODEL:-}}"
    if [ -n "$effective_model" ]; then
        claude_args+=(--model "$effective_model")
    fi
    # Path gating is separate from tool rules: a command matching an allow
    # rule is still denied when it touches a path outside the worktree.
    if [ -n "${AGENT_ADD_DIRS:-}" ]; then
        local add_dir
        for add_dir in $AGENT_ADD_DIRS; do
            claude_args+=(--add-dir "$add_dir")
        done
    fi
    local memory_dir
    memory_dir=$(_resolve_memory_dir)
    if [ -n "$memory_dir" ]; then
        claude_args+=(--add-dir "$memory_dir")
    fi
    if [ -n "$phase" ]; then
        local _var
        _var="AGENT_BUDGET_USD_${phase}"
        local budget="${!_var:-${AGENT_BUDGET_USD:-}}"
        [ -n "$budget" ] && claude_args+=(--max-budget-usd "$budget")
        _var="AGENT_EFFORT_${phase}"
        local effort="${!_var:-}"
        [ -n "$effort" ] && claude_args+=(--effort "$effort")
        _var="AGENT_PERMISSION_MODE_${phase}"
        local permission_mode="${!_var:-}"
        [ -n "$permission_mode" ] && claude_args+=(--permission-mode "$permission_mode")
    elif [ -n "${AGENT_BUDGET_USD:-}" ]; then
        claude_args+=(--max-budget-usd "$AGENT_BUDGET_USD")
    fi
    # Gate the MCP tool surface explicitly: without --strict-mcp-config a
    # phase inherits whatever MCP servers the container's claude has.
    if [ -n "${AGENT_MCP_CONFIG:-}" ]; then
        claude_args+=(--mcp-config "$AGENT_MCP_CONFIG" --strict-mcp-config)
    elif [ "${AGENT_STRICT_MCP:-}" = "true" ]; then
        claude_args+=(--strict-mcp-config)
    fi
    # Headless phases should not accumulate resumable sessions.
    if [ "${AGENT_SESSION_PERSISTENCE:-false}" != "true" ]; then
        claude_args+=(--no-session-persistence)
    fi
    local memory
    memory=$(load_shared_memory)
    if [ -n "$memory" ]; then
        claude_args+=(--append-system-prompt "$memory")
    fi
    # Structured output: the CLI validates the final output against the
    # schema and returns it in .structured_output (upstream #108).
    if [ -n "$schema_file" ]; then
        if [ -f "$schema_file" ]; then
            claude_args+=(--json-schema "$(jq -c . "$schema_file")")
        else
            log "WARN: schema file not found, running without --json-schema: ${schema_file}"
        fi
    fi

    local timeout="${AGENT_TIMEOUT:-3600}"
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
