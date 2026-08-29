# Upstream Batch PR 1 — Runner, Gates, Prompts, Schemas Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-vendor the review gates, prompts and structured-output schemas from `sandbox-pal-action@04cef68`, port upstream's runner helpers (redaction, `is_error`-first parsing, permission denials, per-phase flags) into the container runner, rewrite `run-pipeline.sh` around the ledger review loop and pre-PR test gate, and put the whole container-side lib under host-runnable BATS tests.

**Architecture:** Everything lands under `image/opt/pal/` (copied into the image by the existing `COPY image/opt/pal/ /opt/pal/` in `image/Dockerfile`). `claude-runner.sh` becomes the local analogue of upstream `common.sh` (runner + envelope helpers); `review-gates.sh` is upstream's file with a small, enumerated set of local edits (`set_label` → `STATUS_*`, `notify` dropped); `run-pipeline.sh` orchestrates. Tests source the lib on the host with a fake `claude` on `PATH` — no Docker, no network.

**Tech Stack:** bash (`set -euo pipefail`), jq, BATS-Core (`tests/test_helper/bats-support`, `bats-assert`), shellcheck.

**Spec:** `docs/superpowers/specs/2026-08-29-upstream-batch-adoption-design.md` (§2.2, §3.1–3.5, §3.7 tooling, §4). Read it first. Issue: https://github.com/jnurre64/sandbox-pal/issues/31 (PR 1 row of the delivery table).

**Upstream checkout:** `~/repos/sandbox-pal-action` at commit `04cef68b433e90037b4f7af34b099e6005435a1c` (`git -C ~/repos/sandbox-pal-action rev-parse origin/main`). Every "copy from upstream" step below means `git -C ~/repos/sandbox-pal-action show 04cef68:<path>` so the SHA is exact regardless of that clone's working tree.

## Global Constraints

- All shell scripts pass `shellcheck` with zero warnings; all scripts use `set -euo pipefail` (library files sourced into such a script must be `set -u`-safe: every optional var read as `${VAR:-}`).
- Full check before every commit: `shellcheck $(find . -name '*.sh') && bats tests/` — run from repo root. `bats tests/` skips the two Docker-tagged integration tests automatically when their env gates are unset.
- Do not use `claude-skill-path` or `$(dirname "${BASH_SOURCE[0]}")` in `SKILL.md` (not touched in this PR, but the rule stands).
- Tests are written first and watched failing. Name regression tests `REGRESSION: ...` when they pin an upstream bug (#102 misclassification, #103 redaction, #105 denials, #101 stale ledger).
- No secrets in any file. The test token is the literal `github_pat_` + 30 `x`s.
- Commit prefixes: `feat(container):`, `fix(container):`, `test(container):`, `docs:`, `chore:`. Every commit ends with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Branch: `feature/31-adopt-upstream-batch` (already exists, spec committed on it). PR title: `feat(container): adopt upstream review-gate batch (runner, ledger loop, schemas, redaction)`; body `Part 1 of 3 for #31` — do **not** write `Closes #31`.

---

## File structure

| Path | Status | Responsibility |
|---|---|---|
| `tests/test_helper/container-lib.bash` | create | Fixture: temp worktree/status dirs, fake `claude`, stub `gh`, stub `sudo`, `log` |
| `tests/test_container_lib.bats` | create | Unit tests for `claude-runner.sh` + `review-gates.sh` |
| `tests/test_run_pipeline.bats` | create | End-to-end `run-pipeline.sh` on the host against a bare origin |
| `image/opt/pal/lib/claude-runner.sh` | rewrite | `run_claude` + envelope helpers (§3.1) |
| `image/opt/pal/schemas/{adversarial-plan,post-impl-review,post-impl-retry}.json` | create | Copied verbatim from upstream |
| `image/opt/pal/lib/review-gates.sh` | re-vendor | Upstream file + enumerated edits (§2.2, §3.3) |
| `image/opt/pal/lib/worktree.sh` | modify | Resume from `origin/<branch>` when it exists; exclude `.agent-data/` |
| `image/opt/pal/prompts/*.md` | re-vendor | + `test-fix.md`; memory-proposals paragraph |
| `image/opt/pal/run-pipeline.sh` | rewrite | Pipeline (§3.4) |
| `tests/test_container_pipeline.bats` | modify | Replace stale `CLAUDE_CODE_OAUTH_TOKEN` gate |
| `scripts/diff-upstream.sh`, `UPSTREAM.md`, `CHANGELOG.md` | modify | Tooling + docs (§3.7) |

---

### Task 1: Test fixture for the container lib

**Files:**
- Create: `tests/test_helper/container-lib.bash`
- Create: `tests/test_container_lib.bats` (first test only)

**Interfaces:**
- Produces: `container_lib_setup`, `container_lib_teardown`, `container_lib_source`, `fake_envelope <json>`, `fake_claude_enqueue <json> [<pre-script>]`, and the exported vars `T`, `STATUS_DIR`, `WORKTREE_DIR`, `PROMPTS_DIR`, `LIB_DIR`, `FAKE_CLAUDE_ARGS`, `FAKE_GH_LOG`, `LOG_FILE`. Every later test task uses these names.

- [ ] **Step 1: Write the fixture**

```bash
# tests/test_helper/container-lib.bash
# shellcheck shell=bash
# Host-side fixture for the container pipeline lib (image/opt/pal/lib).
# Provides a fake `claude` that replays canned envelopes and records argv,
# a stub `gh` that records calls, a stub `sudo` (firewall refresh no-ops),
# and the globals run-pipeline.sh would normally define.

container_lib_setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    PAL_HOME="$REPO_ROOT/image/opt/pal"
    LIB_DIR="$PAL_HOME/lib"
    PROMPTS_DIR="$PAL_HOME/prompts"
    T="$(mktemp -d)"
    STATUS_DIR="$T/status"
    WORKTREE_DIR="$T/work"
    LOG_FILE="$T/log"
    mkdir -p "$STATUS_DIR" "$WORKTREE_DIR" "$T/bin" "$T/queue"
    : > "$LOG_FILE"

    # A real git repo so ledger commits and rev-parse work.
    git -C "$WORKTREE_DIR" init -q -b main
    git -C "$WORKTREE_DIR" config user.email test@example.com
    git -C "$WORKTREE_DIR" config user.name test
    git -C "$WORKTREE_DIR" commit -q --allow-empty -m init

    REPO="owner/repo"
    NUMBER=42
    BRANCH_NAME="agent/issue-42"

    FAKE_CLAUDE_ARGS="$T/claude_args"
    FAKE_CLAUDE_ENVELOPE="$T/envelope.json"
    FAKE_CLAUDE_QUEUE="$T/queue"
    FAKE_GH_LOG="$T/gh.log"
    : > "$FAKE_GH_LOG"

    cat > "$T/bin/claude" <<'FAKE'
#!/usr/bin/env bash
# Records argv (one per line), emits optional stderr, then either runs the
# next queued script (multi-call sequences) or cats the single envelope.
printf '%s\n' "$@" > "${FAKE_CLAUDE_ARGS:?}"
[ -n "${FAKE_CLAUDE_STDERR:-}" ] && printf '%s\n' "$FAKE_CLAUDE_STDERR" >&2
if [ -d "${FAKE_CLAUDE_QUEUE:-}" ]; then
    next=$(ls "$FAKE_CLAUDE_QUEUE" | sort | head -1)
    if [ -n "$next" ]; then
        script="$FAKE_CLAUDE_QUEUE/$next"
        bash "$script"
        rm -f "$script"
        exit 0
    fi
fi
cat "${FAKE_CLAUDE_ENVELOPE:?}"
exit "${FAKE_CLAUDE_EXIT:-0}"
FAKE

    cat > "$T/bin/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_GH_LOG:?}"
exit 0
FAKE

    cat > "$T/bin/sudo" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
    chmod +x "$T/bin/claude" "$T/bin/gh" "$T/bin/sudo"
    export PATH="$T/bin:$PATH"
    export T STATUS_DIR WORKTREE_DIR PROMPTS_DIR LIB_DIR LOG_FILE REPO NUMBER BRANCH_NAME
    export FAKE_CLAUDE_ARGS FAKE_CLAUDE_ENVELOPE FAKE_CLAUDE_QUEUE FAKE_GH_LOG
    fake_envelope '{"result":"ok","subtype":"success","is_error":false}'
}

container_lib_teardown() {
    [ -n "${T:-}" ] && rm -rf "$T"
}

log() {
    printf '[test] %s\n' "$*" >> "$LOG_FILE"
}

container_lib_source() {
    # shellcheck disable=SC1091
    . "$LIB_DIR/claude-runner.sh"
    # shellcheck disable=SC1091
    . "$LIB_DIR/review-gates.sh"
}

# Single-envelope mode: every claude call returns this JSON.
fake_envelope() {
    printf '%s\n' "$1" > "$FAKE_CLAUDE_ENVELOPE"
}

# Sequence mode: each call pops the next entry. $2 (optional) is a bash
# snippet run in the worktree before the envelope is emitted (e.g. commits).
_FAKE_QUEUE_N=0
fake_claude_enqueue() {
    local envelope="$1" pre="${2:-}"
    _FAKE_QUEUE_N=$((_FAKE_QUEUE_N + 1))
    local f
    f=$(printf '%s/%03d.sh' "$FAKE_CLAUDE_QUEUE" "$_FAKE_QUEUE_N")
    {
        printf 'cd "%s"\n' "$WORKTREE_DIR"
        [ -n "$pre" ] && printf '%s\n' "$pre"
        printf "cat <<'ENV'\n%s\nENV\n" "$envelope"
    } > "$f"
}
```

- [ ] **Step 2: Write the first test (fixture smoke)**

```bash
#!/usr/bin/env bats
# tests/test_container_lib.bats
# Unit tests for image/opt/pal/lib/claude-runner.sh and review-gates.sh,
# run on the host with a fake `claude` on PATH.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'test_helper/container-lib'

setup()    { container_lib_setup; }
teardown() { container_lib_teardown; }

@test "fixture: fake claude records argv and replays the envelope" {
    fake_envelope '{"result":"hello","subtype":"success","is_error":false}'
    run claude -p "prompt" --output-format json
    assert_success
    assert_output --partial '"result":"hello"'
    run cat "$FAKE_CLAUDE_ARGS"
    assert_line --index 0 "-p"
    assert_line --index 1 "prompt"
}
```

- [ ] **Step 3: Run it**

Run: `bats tests/test_container_lib.bats`
Expected: `1 test, 0 failures`.

- [ ] **Step 4: Commit**

```bash
git add tests/test_helper/container-lib.bash tests/test_container_lib.bats
git commit -m "test(container): host-side fixture with fake claude for the pipeline lib"
```

---

### Task 2: `parse_claude_output` / `classify_claude_result` — `is_error` first (upstream #102)

**Files:**
- Modify: `image/opt/pal/lib/claude-runner.sh` (replace `parse_claude_output`, lines 49–57; add `classify_claude_result`)
- Test: `tests/test_container_lib.bats`

**Interfaces:**
- Produces: `parse_claude_output <envelope-json>` → text on stdout; `classify_claude_result <envelope-json>` → prints `fail_fast` | `recoverable` | `ok`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_container_lib.bats`:

```bash
# ── parse / classify ────────────────────────────────────────────

@test "REGRESSION #102: API-error envelope with subtype=success is reported as an API error" {
    container_lib_source
    env='{"is_error":true,"subtype":"success","terminal_reason":"api_error","api_error_status":529,"result":"Overloaded"}'
    run parse_claude_output "$env"
    assert_output "Agent phase failed: API error — api_error — 529 — Overloaded"
    run classify_claude_result "$env"
    assert_output "fail_fast"
}

@test "classify: error_max_turns is recoverable" {
    container_lib_source
    run classify_claude_result '{"is_error":false,"subtype":"error_max_turns"}'
    assert_output "recoverable"
    run parse_claude_output '{"is_error":false,"subtype":"error_max_turns"}'
    assert_output "Agent stopped: error_max_turns"
}

@test "classify: synthetic timeout envelope (.error) is recoverable" {
    container_lib_source
    run classify_claude_result '{"result":"claude timed out or errored (exit code 124)","error":true}'
    assert_output "recoverable"
}

@test "classify: normal envelope is ok and parse returns .result" {
    container_lib_source
    run classify_claude_result '{"is_error":false,"subtype":"success","result":"done"}'
    assert_output "ok"
    run parse_claude_output '{"is_error":false,"subtype":"success","result":"done"}'
    assert_output "done"
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/test_container_lib.bats`
Expected: the `#102` test fails (`parse_claude_output` prints `Overloaded`), the `error_max_turns` test fails (prints the raw JSON), `classify_claude_result: command not found`.

- [ ] **Step 3: Implement**

In `image/opt/pal/lib/claude-runner.sh`, replace the existing `parse_claude_output` (everything from `parse_claude_output() {` to its closing `}`) with:

```bash
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
```

- [ ] **Step 4: Run to verify they pass**

Run: `shellcheck image/opt/pal/lib/claude-runner.sh && bats tests/test_container_lib.bats`
Expected: `5 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add image/opt/pal/lib/claude-runner.sh tests/test_container_lib.bats
git commit -m "fix(container): classify phase results from is_error first (upstream #102)"
```

---

### Task 3: `redact_secrets` at the capture point (upstream #103)

**Files:**
- Modify: `image/opt/pal/lib/claude-runner.sh` (add `redact_secrets`; route `run_claude` stdout/stderr through it)
- Test: `tests/test_container_lib.bats`

**Interfaces:**
- Produces: `redact_secrets` (filter: stdin → stdout). `run_claude` output and `$STATUS_DIR/claude-stderr-*.log` are post-redaction.

- [ ] **Step 1: Write the failing tests**

Append:

```bash
# ── redaction ───────────────────────────────────────────────────

@test "REGRESSION #103: redact_secrets scrubs env secrets and token-shaped strings" {
    # Two passes: token-shaped patterns first (github_pat_/gh?_ /Authorization),
    # then the value of every exported *TOKEN*/*SECRET*/... variable >= 8 chars.
    export GH_TOKEN="not-token-shaped-but-secret-value-1234"
    run bash -c ". \"$LIB_DIR/claude-runner.sh\"; printf 'token=%s and ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ12 and Authorization: Bearer abc.def\n' \"\$GH_TOKEN\" | redact_secrets"
    assert_output "token=[REDACTED:GH_TOKEN] and [REDACTED_TOKEN] and Authorization: Bearer [REDACTED]"
}

@test "REGRESSION #103: run_claude redacts the envelope and the stderr log" {
    container_lib_source
    export GH_TOKEN="not-token-shaped-but-secret-value-1234"
    fake_envelope "{\"result\":\"leaked $GH_TOKEN here\",\"subtype\":\"success\",\"is_error\":false}"
    export FAKE_CLAUDE_STDERR="stderr says $GH_TOKEN"
    run run_claude "prompt" "Read" "" "" "IMPLEMENT"
    assert_success
    refute_output --partial "$GH_TOKEN"
    assert_output --partial "[REDACTED:GH_TOKEN]"
    run cat "$STATUS_DIR"/claude-stderr-*.log
    refute_output --partial "$GH_TOKEN"
    assert_output --partial "[REDACTED:GH_TOKEN]"
    run cat "$STATUS_DIR"/claude-stdout-*.log
    refute_output --partial "$GH_TOKEN"
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/test_container_lib.bats`
Expected: both new tests fail (`redact_secrets: command not found`; token present in output).

- [ ] **Step 3: Implement**

Add to `claude-runner.sh` (before `run_claude`):

```bash
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
```

Then rewrite `run_claude`'s capture section. Replace:

```bash
    timeout "$timeout" claude "${claude_args[@]}" 2>"$stderr_log" | tee "$stdout_log"
    local ec="${PIPESTATUS[0]}"
    if [ "$ec" -ne 0 ]; then
        log "claude-runner: claude exited with code $ec (stderr: $(head -10 "$stderr_log")) (stdout first 500: $(head -c 500 "$stdout_log"))"
        echo '{"result":"claude timed out or errored","error":true}'
    fi
```

with:

```bash
    local raw_output ec=0
    raw_output=$(timeout "$timeout" claude "${claude_args[@]}" 2>"$stderr_log") || ec=$?

    # Scrub at the point of capture (upstream #103).
    redact_secrets < "$stderr_log" > "${stderr_log}.tmp" && mv "${stderr_log}.tmp" "$stderr_log"
    printf '%s\n' "$raw_output" | redact_secrets | tee "$stdout_log"

    if [ "$ec" -ne 0 ]; then
        log "claude-runner: claude exited with code $ec (stderr: $(head -10 "$stderr_log")) (stdout first 500: $(head -c 500 "$stdout_log"))"
        echo '{"result":"claude timed out or errored (exit code '"$ec"')","error":true}'
    fi
```

- [ ] **Step 4: Run to verify they pass**

Run: `shellcheck image/opt/pal/lib/claude-runner.sh && bats tests/test_container_lib.bats`
Expected: `7 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add image/opt/pal/lib/claude-runner.sh tests/test_container_lib.bats
git commit -m "feat(container): redact secrets from phase envelopes and stderr at capture (upstream #103)"
```

---

### Task 4: Permission denials and structured output (upstream #105, #108)

**Files:**
- Modify: `image/opt/pal/lib/claude-runner.sh`
- Test: `tests/test_container_lib.bats`

**Interfaces:**
- Produces: `extract_permission_denials <envelope>`, `log_permission_denials <envelope> <phase>` (appends to `${WORKTREE_DIR}/.agent-data/permission-denials.log`), `denials_report_section` (markdown or empty), `get_structured_output <envelope>` (compact JSON or empty).

- [ ] **Step 1: Write the failing tests**

Append:

```bash
# ── permission denials / structured output ──────────────────────

@test "REGRESSION #105: permission denials are logged per phase and rendered for the PR body" {
    container_lib_source
    env='{"result":"x","subtype":"success","is_error":false,"permission_denials":[{"tool_name":"Bash","tool_input":{"command":"npm test"}},{"tool_name":"Edit","tool_input":{"file_path":"src/a.js"}}]}'
    run extract_permission_denials "$env"
    assert_line --index 0 "Bash: npm test"
    assert_line --index 1 "Edit: src/a.js"
    log_permission_denials "$env" "implement"
    run cat "$WORKTREE_DIR/.agent-data/permission-denials.log"
    assert_line --index 0 "[implement] Bash: npm test"
    run denials_report_section
    assert_output --partial "### Permission Denials"
    assert_output --partial "[implement] Edit: src/a.js"
    assert_output --partial ".pal/config.env"
}

@test "denials: no section when nothing was denied" {
    container_lib_source
    run denials_report_section
    assert_output ""
}

@test "structured output: get_structured_output prefers .structured_output" {
    container_lib_source
    run get_structured_output '{"result":"Here is my answer: {\"action\":\"nope\"}","structured_output":{"action":"approved"}}'
    assert_output '{"action":"approved"}'
    run get_structured_output '{"result":"plain"}'
    assert_output ""
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/test_container_lib.bats`
Expected: 3 new failures, `command not found`.

- [ ] **Step 3: Implement**

Add to `claude-runner.sh` after `redact_secrets`:

```bash
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
```

- [ ] **Step 4: Run to verify they pass**

Run: `shellcheck image/opt/pal/lib/claude-runner.sh && bats tests/test_container_lib.bats`
Expected: `10 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add image/opt/pal/lib/claude-runner.sh tests/test_container_lib.bats
git commit -m "feat(container): surface permission denials and read structured output (upstream #105, #108)"
```

---

### Task 5: `run_claude` flag surface, schema, memory dir, shims (upstream #110, #108, #109)

**Files:**
- Modify: `image/opt/pal/lib/claude-runner.sh` (replace `load_prompt` and `run_claude` wholesale; add `set_heartbeat`, `preserve_branch`, `_resolve_memory_dir`, `load_shared_memory`)
- Test: `tests/test_container_lib.bats`

**Interfaces:**
- Produces: `run_claude <prompt> <allowed_tools> [model] [schema_file] [PHASE]`; `load_prompt <name> [custom_path]`; `set_heartbeat <label>` (no-op); `preserve_branch` (pushes `$BRANCH_NAME`); `load_shared_memory` (system-prompt text or empty); `_resolve_memory_dir`.
- Consumes: `redact_secrets`, `log` (Task 3; `run-pipeline.sh`).

- [ ] **Step 1: Write the failing tests**

Append:

```bash
# ── run_claude flag surface ─────────────────────────────────────

_args() { cat "$FAKE_CLAUDE_ARGS"; }

@test "flags: defaults — json output, disable-slash-commands, no-session-persistence, no budget/effort/schema" {
    container_lib_source
    run run_claude "p" "Read" "" "" "IMPLEMENT"
    assert_success
    run _args
    assert_line "--output-format"
    assert_line "--disable-slash-commands"
    assert_line "--no-session-persistence"
    refute_line "--max-budget-usd"
    refute_line "--effort"
    refute_line "--permission-mode"
    refute_line "--json-schema"
    refute_line "--strict-mcp-config"
}

@test "flags: per-phase budget, effort, permission mode" {
    container_lib_source
    export AGENT_BUDGET_USD_IMPLEMENT=8 AGENT_EFFORT_IMPLEMENT=xhigh AGENT_PERMISSION_MODE_IMPLEMENT=dontAsk
    run run_claude "p" "Read" "" "" "IMPLEMENT"
    run _args
    assert_line "--max-budget-usd"; assert_line "8"
    assert_line "--effort";         assert_line "xhigh"
    assert_line "--permission-mode"; assert_line "dontAsk"
}

@test "flags: AGENT_BUDGET_USD is the global fallback; per-phase wins" {
    container_lib_source
    export AGENT_BUDGET_USD=42 AGENT_BUDGET_USD_POST_IMPL_REVIEW=3
    run run_claude "p" "Read" "" "" "IMPLEMENT";        run _args; assert_line "42"
    run run_claude "p" "Read" "" "" "POST_IMPL_REVIEW"; run _args; assert_line "3"; refute_line "42"
}

@test "flags: AGENT_MCP_CONFIG adds --mcp-config + --strict-mcp-config; AGENT_STRICT_MCP=true adds strict alone" {
    container_lib_source
    export AGENT_MCP_CONFIG="$T/mcp.json"
    run run_claude "p" "Read"; run _args
    assert_line "--mcp-config"; assert_line "$T/mcp.json"; assert_line "--strict-mcp-config"
    unset AGENT_MCP_CONFIG; export AGENT_STRICT_MCP=true
    run run_claude "p" "Read"; run _args
    refute_line "--mcp-config"; assert_line "--strict-mcp-config"
}

@test "flags: AGENT_SESSION_PERSISTENCE=true drops --no-session-persistence" {
    container_lib_source
    export AGENT_SESSION_PERSISTENCE=true
    run run_claude "p" "Read"; run _args
    refute_line "--no-session-persistence"
}

@test "flags: AGENT_ADD_DIRS and AGENT_MEMORY_DIR become --add-dir; memory index is appended to the system prompt" {
    container_lib_source
    mkdir -p "$T/extra" "$T/mem"
    printf '# Memory Index\n- [x](x.md) — hook\n' > "$T/mem/MEMORY.md"
    export AGENT_ADD_DIRS="$T/extra" AGENT_MEMORY_DIR="$T/mem"
    run run_claude "p" "Read"; run _args
    assert_line "--add-dir"; assert_line "$T/extra"; assert_line "$T/mem"
    assert_line "--append-system-prompt"
    assert_output --partial "Shared Project Memory"
    assert_output --partial "- [x](x.md) — hook"
    assert_output --partial "read-only"
}

@test "flags: --json-schema carries the compact schema when the file exists; missing file warns and continues" {
    container_lib_source
    printf '{ "type": "object",\n "required": ["action"] }\n' > "$T/s.json"
    run run_claude "p" "Read" "" "$T/s.json" "POST_IMPL_REVIEW"
    assert_success
    run _args
    assert_line "--json-schema"
    assert_line '{"type":"object","required":["action"]}'
    run run_claude "p" "Read" "" "$T/missing.json" "POST_IMPL_REVIEW"
    assert_success
    run _args; refute_line "--json-schema"
    run cat "$LOG_FILE"; assert_output --partial "schema file not found"
}

@test "flags: model override and AGENT_MODEL fallback" {
    container_lib_source
    export AGENT_MODEL=claude-sonnet-5
    run run_claude "p" "Read"; run _args; assert_line "claude-sonnet-5"
    run run_claude "p" "Read" "claude-opus-5"; run _args; assert_line "claude-opus-5"; refute_line "claude-sonnet-5"
}

@test "flags: max-turns and disallowed tools defaults" {
    container_lib_source
    run run_claude "p" "Read"; run _args
    assert_line "--max-turns"; assert_line "50"
    assert_line "--disallowedTools"; assert_line "mcp__github__*"
}

@test "load_prompt: built-in, worktree-relative override, absolute override, missing" {
    container_lib_source
    run load_prompt "implement"
    assert_success
    assert_output --partial "approved plan"
    mkdir -p "$WORKTREE_DIR/.pal/prompts"
    echo "custom rel" > "$WORKTREE_DIR/.pal/prompts/x.md"
    run load_prompt "implement" ".pal/prompts/x.md"; assert_output "custom rel"
    echo "custom abs" > "$T/abs.md"
    run load_prompt "implement" "$T/abs.md"; assert_output "custom abs"
    run load_prompt "does-not-exist"
    assert_failure
}

@test "shims: set_heartbeat is a no-op; preserve_branch pushes BRANCH_NAME and tolerates failure" {
    container_lib_source
    run set_heartbeat "anything"; assert_success; assert_output ""
    # no origin remote → push fails → returns 1, logs a WARN, does not abort
    run preserve_branch
    assert_failure
    run cat "$LOG_FILE"; assert_output --partial "WARN: could not push agent/issue-42"
    bare="$T/origin.git"; git init -q --bare "$bare"
    git -C "$WORKTREE_DIR" remote add origin "$bare"
    run preserve_branch
    assert_success
    run git -C "$bare" branch --list "agent/issue-42"; assert_output --partial "agent/issue-42"
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/test_container_lib.bats`
Expected: the flag tests fail on `--no-session-persistence` / budget etc.; `set_heartbeat: command not found`; `load_prompt` override test fails (second arg ignored).

- [ ] **Step 3: Implement — replace `load_prompt` and `run_claude` in full**

Replace the existing `load_prompt` with:

```bash
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
```

Add (after `get_structured_output`):

```bash
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
```

Replace `run_claude` in full with:

```bash
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
```

Keep the file header comment; update it to list everything provided:

```bash
# image/opt/pal/lib/claude-runner.sh
# shellcheck shell=bash
# Container-side analogue of upstream scripts/lib/common.sh (sandbox-pal-action).
# Provides: load_prompt, run_claude, parse_claude_output, classify_claude_result,
#           get_structured_output, redact_secrets, extract_permission_denials,
#           log_permission_denials, denials_report_section, set_heartbeat (no-op),
#           preserve_branch, _resolve_memory_dir, load_shared_memory
# Expects from the sourcing script: log, STATUS_DIR, WORKTREE_DIR, PROMPTS_DIR,
#           BRANCH_NAME (for preserve_branch).
```

- [ ] **Step 4: Run to verify they pass**

Run: `shellcheck image/opt/pal/lib/claude-runner.sh && bats tests/test_container_lib.bats`
Expected: `21 tests, 0 failures`. (If `assert_line "8"` collides with another argv line — it will not: `--max-turns 50` is the only other bare number.)

- [ ] **Step 5: Commit**

```bash
git add image/opt/pal/lib/claude-runner.sh tests/test_container_lib.bats
git commit -m "feat(container): per-phase claude flags, json schema, read-only memory dir, liveness shim (upstream #108-#110)"
```

---

### Task 6: Copy the structured-output schemas

**Files:**
- Create: `image/opt/pal/schemas/adversarial-plan.json`, `post-impl-review.json`, `post-impl-retry.json`
- Test: `tests/test_container_lib.bats`

- [ ] **Step 1: Write the failing test**

```bash
# ── schemas ─────────────────────────────────────────────────────

@test "schemas: the three phase schemas are valid JSON and match upstream 04cef68 byte-for-byte" {
    for s in adversarial-plan post-impl-review post-impl-retry; do
        run jq -e '.required | index("action")' "$REPO_ROOT/image/opt/pal/schemas/$s.json"
        assert_success
    done
    if [ -d "$HOME/repos/sandbox-pal-action/.git" ]; then
        for s in adversarial-plan post-impl-review post-impl-retry; do
            run diff <(git -C "$HOME/repos/sandbox-pal-action" show "04cef68:schemas/$s.json") "$REPO_ROOT/image/opt/pal/schemas/$s.json"
            assert_success
        done
    fi
}
```

- [ ] **Step 2: Run to verify it fails** — `bats tests/test_container_lib.bats` → the new test fails (no such file).

- [ ] **Step 3: Copy**

```bash
mkdir -p image/opt/pal/schemas
for s in adversarial-plan post-impl-review post-impl-retry; do
  git -C ~/repos/sandbox-pal-action show "04cef68:schemas/$s.json" > "image/opt/pal/schemas/$s.json"
done
```

- [ ] **Step 4: Verify** — `bats tests/test_container_lib.bats` → `22 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add image/opt/pal/schemas
git commit -m "feat(container): vendor structured-output schemas from sandbox-pal-action@04cef68"
```

---

### Task 7: Re-vendor `review-gates.sh` with the enumerated local edits

**Files:**
- Rewrite: `image/opt/pal/lib/review-gates.sh`
- Test: `tests/test_container_lib.bats`

**Interfaces:**
- Consumes: `run_claude`, `parse_claude_output`, `classify_claude_result`, `get_structured_output`, `log_permission_denials`, `denials_report_section`, `set_heartbeat`, `preserve_branch`, `load_prompt` (Tasks 2–5).
- Produces: `run_adversarial_plan_review`, `run_test_gate <impl_tools> <issue_title>`, `run_post_impl_review`, `run_post_impl_retry_session <impl_tools>`, `run_post_impl_review_loop <impl_tools>` (0/1/2), `_ledger_init`, `_ledger_pr_summary`, `_ledger_outstanding_summary`, `LEDGER_FILE`, `POST_IMPL_REVIEW_JSON`. Sets `STATUS_OUTCOME` / `STATUS_FAILURE_REASON` on failure paths.
- Reads (must be defined by `run-pipeline.sh`, Task 9): `AGENT_ADVERSARIAL_PLAN_REVIEW`, `AGENT_POST_IMPL_REVIEW`, `AGENT_POST_IMPL_REVIEW_MAX_RETRIES`, `AGENT_TEST_GATE_MAX_RETRIES`, `AGENT_TEST_COMMAND`, `AGENT_TEST_SETUP_COMMAND`, `AGENT_ALLOWED_TOOLS_TRIAGE`, `AGENT_MODEL_{ADVERSARIAL_PLAN,POST_IMPL_REVIEW,POST_IMPL_RETRY,TEST_FIX}`, `AGENT_PROMPT_{ADVERSARIAL_PLAN,POST_IMPL_REVIEW,POST_IMPL_RETRY,TEST_FIX}`, `AGENT_JSON_SCHEMA_{ADVERSARIAL_PLAN,POST_IMPL_REVIEW,POST_IMPL_RETRY}`, `NUMBER`, `REPO`, `BRANCH_NAME`, `WORKTREE_DIR`.

- [ ] **Step 1: Write the failing tests**

Append. The helper `_gate_env` sets every variable the gates read, so the tests run under the fixture's `set -u`-free bats shell but mirror what `run-pipeline.sh` will export.

```bash
# ── review gates ────────────────────────────────────────────────

_gate_env() {
    export AGENT_ADVERSARIAL_PLAN_REVIEW=true AGENT_POST_IMPL_REVIEW=true
    export AGENT_POST_IMPL_REVIEW_MAX_RETRIES=3 AGENT_TEST_GATE_MAX_RETRIES=2
    export AGENT_TEST_COMMAND="" AGENT_TEST_SETUP_COMMAND=""
    export AGENT_ALLOWED_TOOLS_TRIAGE="Read"
    export AGENT_MODEL_ADVERSARIAL_PLAN="" AGENT_MODEL_POST_IMPL_REVIEW="" AGENT_MODEL_POST_IMPL_RETRY="" AGENT_MODEL_TEST_FIX=""
    export AGENT_PROMPT_ADVERSARIAL_PLAN="" AGENT_PROMPT_POST_IMPL_REVIEW="" AGENT_PROMPT_POST_IMPL_RETRY="" AGENT_PROMPT_TEST_FIX=""
    export AGENT_JSON_SCHEMA_ADVERSARIAL_PLAN="" AGENT_JSON_SCHEMA_POST_IMPL_REVIEW="" AGENT_JSON_SCHEMA_POST_IMPL_RETRY=""
    export AGENT_PLAN_CONTENT="plan" AGENT_ISSUE_TITLE="t" AGENT_ISSUE_BODY="b"
    STATUS_OUTCOME="failure"; STATUS_FAILURE_REASON=""
}

_review() { # structured review envelope
    printf '{"result":"","subtype":"success","is_error":false,"structured_output":%s}' "$1"
}

@test "Gate A: approved / needs_clarification / unparseable set the right STATUS_* (no labels)" {
    _gate_env; container_lib_source
    fake_envelope "$(_review '{"action":"approved"}')"
    run run_adversarial_plan_review; assert_success

    fake_envelope '{"result":"{\"action\":\"needs_clarification\",\"questions\":[\"why?\"]}","subtype":"success","is_error":false}'
    run_adversarial_plan_review && fail "expected 1"
    assert_equal "$STATUS_OUTCOME" "clarification_needed"
    run cat "$FAKE_GH_LOG"; assert_output --partial "Clarification Needed"; assert_output --partial "- why?"

    STATUS_OUTCOME=failure; STATUS_FAILURE_REASON=""
    fake_envelope '{"result":"no json here","subtype":"success","is_error":false}'
    run_adversarial_plan_review && fail "expected 1"
    assert_equal "$STATUS_FAILURE_REASON" "adversarial_review_could_not_parse"
    run cat "$FAKE_GH_LOG"; refute_output --partial "agent:"
}

@test "REGRESSION #101: a ledger stamped with another issue is discarded on init" {
    _gate_env; container_lib_source
    mkdir -p "$WORKTREE_DIR/.agent-data"
    echo '{"issue":99,"cycles":4,"findings":[{"id":"F1","severity":"blocking","description":"old","status":"open","justification":""}]}' > "$WORKTREE_DIR/.agent-data/review-ledger.json"
    _ledger_init
    run jq -r '.issue, .cycles, (.findings|length)' "$LEDGER_FILE"
    assert_line --index 0 "42"; assert_line --index 1 "0"; assert_line --index 2 "0"
    run cat "$LOG_FILE"; assert_output --partial "Discarding stale review ledger (stamped: 99"
}

@test "review loop: concerns → retry fixes → approved returns 0 with cycles=2" {
    _gate_env; container_lib_source
    fake_claude_enqueue "$(_review '{"action":"concerns","verified_fixed":[],"reopened":[],"findings":[{"severity":"blocking","description":"missing test"}]}')"
    fake_claude_enqueue "$(_review '{"action":"addressed","dispositions":[{"id":"F1","status":"fixed","note":"added"}]}')" \
        'echo fix > fix.txt; git add fix.txt; git commit -q -m "fix(review): add test"'
    fake_claude_enqueue "$(_review '{"action":"approved","verified_fixed":["F1"],"reopened":[],"findings":[]}')"
    run_post_impl_review_loop "Read,Edit"
    rc=$?
    assert_equal "$rc" 0
    run jq -r '.cycles, .findings[0].status' "$LEDGER_FILE"
    assert_line --index 0 "2"; assert_line --index 1 "fixed"
    run git -C "$WORKTREE_DIR" log --format=%s
    assert_line --partial "review ledger"
}

@test "review loop: cap reached with blocking findings open returns 2" {
    _gate_env; container_lib_source
    export AGENT_POST_IMPL_REVIEW_MAX_RETRIES=1
    fake_claude_enqueue "$(_review '{"action":"concerns","verified_fixed":[],"reopened":[],"findings":[{"severity":"blocking","description":"bad"}]}')"
    fake_claude_enqueue "$(_review '{"action":"addressed","dispositions":[]}')"
    fake_claude_enqueue "$(_review '{"action":"concerns","verified_fixed":[],"reopened":[],"findings":[]}')"
    run_post_impl_review_loop "Read,Edit" && fail "expected 2"
    rc=$?
    assert_equal "$rc" 2
    run _ledger_outstanding_summary; assert_output --partial "F1"
}

@test "review loop: API error in the review pass is fail-fast (returns 1, status set, branch preserve attempted)" {
    _gate_env; container_lib_source
    fake_envelope '{"is_error":true,"subtype":"success","terminal_reason":"api_error","api_error_status":529,"result":"Overloaded"}'
    run_post_impl_review_loop "Read,Edit" && fail "expected 1"
    assert_equal "$?" 1
    assert_equal "$STATUS_FAILURE_REASON" "post_impl_review_api_error"
    run cat "$FAKE_GH_LOG"; assert_output --partial "API error"; assert_output --partial "/pal-implement"
}

@test "review: unparseable output sets post_impl_review_could_not_parse and mentions the schema when one is configured" {
    _gate_env; container_lib_source
    export AGENT_JSON_SCHEMA_POST_IMPL_REVIEW="/opt/pal/schemas/post-impl-review.json"
    fake_envelope '{"result":"narrative only","subtype":"success","is_error":false}'
    run_post_impl_review_loop "Read" && fail "expected 1"
    assert_equal "$STATUS_FAILURE_REASON" "post_impl_review_could_not_parse"
    run cat "$FAKE_GH_LOG"; assert_output --partial "schema/prompt mismatch"
}

@test "review: legacy {\"concerns\":[...]} response maps to blocking findings" {
    _gate_env; container_lib_source
    export AGENT_POST_IMPL_REVIEW_MAX_RETRIES=0
    fake_envelope '{"result":"{\"action\":\"concerns\",\"concerns\":[\"legacy one\"]}","subtype":"success","is_error":false}'
    run_post_impl_review_loop "Read" && fail "expected 2"
    run jq -r '.findings[0].severity + " " + .findings[0].description' "$LEDGER_FILE"
    assert_output "blocking legacy one"
}

@test "test gate: green passes; red → fix commits → green passes; no-commit fix session stops early" {
    _gate_env; container_lib_source
    export AGENT_TEST_COMMAND="test -f $WORKTREE_DIR/green"
    touch "$WORKTREE_DIR/green"
    run run_test_gate "Read,Edit" "title"; assert_success

    rm "$WORKTREE_DIR/green"
    fake_claude_enqueue '{"result":"fixed","subtype":"success","is_error":false}' 'touch green; git add -f green; git commit -q -m "fix(tests): green"'
    run_test_gate "Read,Edit" "title"
    assert_equal "$?" 0

    rm "$WORKTREE_DIR/green"; git -C "$WORKTREE_DIR" commit -q -am "remove green"
    fake_envelope '{"result":"cannot fix","subtype":"success","is_error":false}'
    run_test_gate "Read,Edit" "title" && fail "expected 1"
    assert_equal "$STATUS_FAILURE_REASON" "tests_failed_after_1_fix_sessions"
    run cat "$LOG_FILE"; assert_output --partial "made no commits"
    run cat "$FAKE_GH_LOG"; assert_output --partial "Test Failure (Pre-PR Gate)"; refute_output --partial "agent:failed"
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/test_container_lib.bats`
Expected: `run_post_impl_review_loop: command not found`, `run_test_gate: command not found`, `_ledger_init: command not found`; Gate A parse-fail test passes already only if `STATUS_FAILURE_REASON` matches (it does in the old file — that one may pass; the rest fail).

- [ ] **Step 3: Copy upstream and apply the edits**

```bash
git -C ~/repos/sandbox-pal-action show 04cef68:scripts/lib/review-gates.sh > image/opt/pal/lib/review-gates.sh
```

Then apply **exactly** these edits (use the Edit tool; each old string is unique in the file):

1. Header. Replace the first three lines
   ```
   #!/bin/bash
   # ─── Review gates: adversarial plan review + post-implementation review ──
   # Provides: run_adversarial_plan_review, run_test_gate, run_post_impl_review, run_post_impl_retry_session, run_post_impl_review_loop, ledger helpers
   ```
   with
   ```
   #!/bin/bash
   # shellcheck disable=SC2034
   # (STATUS_OUTCOME and STATUS_FAILURE_REASON are set here and read by the
   # sourcing run-pipeline.sh when it writes status.json on exit.)
   # ─── Review gates: adversarial plan review + post-implementation review ──
   # Vendored from jnurre64/sandbox-pal-action scripts/lib/review-gates.sh @04cef68.
   # Local edits (see UPSTREAM.md): set_label → STATUS_* writes; notify dropped;
   # label/re-dispatch wording → sandbox-pal wording. Nothing else.
   # Provides: run_adversarial_plan_review, run_test_gate, run_post_impl_review, run_post_impl_retry_session, run_post_impl_review_loop, ledger helpers
   ```
2. Gate A needs_clarification: `            set_label "agent:needs-info"` → `            STATUS_OUTCOME="clarification_needed"`.
3. Gate A parse failure: replace
   ```
               set_label "agent:failed"
               gh issue comment "$NUMBER" --repo "$REPO" \
                   --body "Agent adversarial plan review could not parse its output. Please re-label with \`agent:plan-approved\` to retry." 2>/dev/null || true
   ```
   with
   ```
               STATUS_OUTCOME="failure"
               STATUS_FAILURE_REASON="adversarial_review_could_not_parse"
               gh issue comment "$NUMBER" --repo "$REPO" \
                   --body "Agent adversarial plan review could not parse its output. Please retry the sandbox-pal run." 2>/dev/null || true
   ```
4. Test gate failure comment + label + notify. Replace
   ```
   Tests failed after implementation (${stop_reason}). Setting \`agent:failed\`.

   **Your work is safe:** the implementation commits are pushed to the \`${BRANCH_NAME}\` branch. Re-applying \`agent:plan-approved\` resumes from that branch instead of starting over.
   ```
   with
   ```
   Tests failed after implementation (${stop_reason}).

   **Your work is safe:** the implementation commits are pushed to the \`${BRANCH_NAME}\` branch. Re-running \`/pal-implement\` resumes from that branch instead of starting over.
   ```
   and replace
   ```
       set_label "agent:failed"
       notify "tests_failed" "$issue_title" "https://github.com/${REPO}/issues/${NUMBER}" "Pre-PR test gate failed after ${attempt} fix session(s)"
       return 1
   }
   ```
   with
   ```
       STATUS_OUTCOME="failure"
       STATUS_FAILURE_REASON="tests_failed_after_${attempt}_fix_sessions"
       return 1
   }
   ```
   (`issue_title` is now unused inside the function — keep the parameter for signature parity with upstream; add `# shellcheck disable=SC2034` on the line above `local issue_title="$2"`.)
5. Post-impl review API error. Replace
   ```
           preserve_branch || true
           set_label "agent:failed"
           gh issue comment "$NUMBER" --repo "$REPO" \
               --body "Agent post-implementation review hit an API error (${claude_output}). No later phase can recover this — re-dispatch once the API issue is resolved. The implementation commits are pushed to the \`${BRANCH_NAME}\` branch." 2>/dev/null || true
   ```
   with
   ```
           preserve_branch || true
           STATUS_OUTCOME="failure"
           STATUS_FAILURE_REASON="post_impl_review_api_error"
           gh issue comment "$NUMBER" --repo "$REPO" \
               --body "Agent post-implementation review hit an API error (${claude_output}). No later phase can recover this — re-run \`/pal-implement\` once the API issue is resolved. The implementation commits are pushed to the \`${BRANCH_NAME}\` branch." 2>/dev/null || true
   ```
6. Post-impl review parse failure. Replace
   ```
               preserve_branch || true
               set_label "agent:failed"
               gh issue comment "$NUMBER" --repo "$REPO" \
                   --body "Agent post-implementation review could not parse its output.${parse_note}
   ```
   with
   ```
               preserve_branch || true
               STATUS_OUTCOME="failure"
               STATUS_FAILURE_REASON="post_impl_review_could_not_parse"
               gh issue comment "$NUMBER" --repo "$REPO" \
                   --body "Agent post-implementation review could not parse its output.${parse_note}
   ```
7. Retry session API error. Replace
   ```
           preserve_branch || true
           set_label "agent:failed"
           gh issue comment "$NUMBER" --repo "$REPO" \
               --body "Agent review-loop retry session hit an API error (${claude_output}). No later phase can recover this — re-dispatch once the API issue is resolved. The work so far is pushed to the \`${BRANCH_NAME}\` branch." 2>/dev/null || true
   ```
   with
   ```
           preserve_branch || true
           STATUS_OUTCOME="failure"
           STATUS_FAILURE_REASON="post_impl_retry_api_error"
           gh issue comment "$NUMBER" --repo "$REPO" \
               --body "Agent review-loop retry session hit an API error (${claude_output}). No later phase can recover this — re-run \`/pal-implement\` once the API issue is resolved. The work so far is pushed to the \`${BRANCH_NAME}\` branch." 2>/dev/null || true
   ```
8. Retry session tests failed. Replace
   ```
               preserve_branch || true
               set_label "agent:failed"
               gh issue comment "$NUMBER" --repo "$REPO" \
                   --body "## Post-Implementation Review: Retry Failed
   ```
   with
   ```
               preserve_branch || true
               STATUS_OUTCOME="failure"
               STATUS_FAILURE_REASON="post_impl_retry_tests_failed"
               gh issue comment "$NUMBER" --repo "$REPO" \
                   --body "## Post-Implementation Review: Retry Failed
   ```
9. The `denials_report_section` reference inside the test-gate comment stays (it is defined in `claude-runner.sh`).

Verify no adaptation site was missed: `grep -n "set_label\|notify \|agent:" image/opt/pal/lib/review-gates.sh` must print nothing except the `# Local edits` header line.

- [ ] **Step 4: Run to verify they pass**

Run: `shellcheck image/opt/pal/lib/review-gates.sh image/opt/pal/lib/claude-runner.sh && bats tests/test_container_lib.bats`
Expected: `30 tests, 0 failures`. If the legacy-concerns test fails on `assert_output "blocking legacy one"`, check that the fake envelope's `.result` string is what `_extract_review_json` receives (it is — `get_structured_output` returns empty, then the fallback parses `.result`).

- [ ] **Step 5: Commit**

```bash
git add image/opt/pal/lib/review-gates.sh tests/test_container_lib.bats
git commit -m "feat(container): re-vendor review gates with ledger loop and test gate from sandbox-pal-action@04cef68"
```

---

### Task 8: Prompts re-vendor, `test-fix.md`, memory-proposals paragraph; worktree resume + exclude

**Files:**
- Rewrite: `image/opt/pal/prompts/{adversarial-plan,post-impl-review,post-impl-retry,implement}.md`
- Create: `image/opt/pal/prompts/test-fix.md`
- Modify: `image/opt/pal/lib/worktree.sh:29-38`
- Test: `tests/test_container_lib.bats`

**Interfaces:**
- Produces: `setup_worktree <repo> <number> <event_type>` now resumes from `origin/agent/issue-<n>` when that branch exists and writes `.agent-data/` to the worktree's git exclude file.

- [ ] **Step 1: Write the failing tests**

Append:

```bash
# ── prompts ─────────────────────────────────────────────────────

@test "prompts: vendored files match upstream 04cef68 except the enumerated local lines" {
    P="$REPO_ROOT/image/opt/pal/prompts"
    [ -f "$P/test-fix.md" ]
    for f in implement post-impl-retry test-fix; do
        run grep -c "memory-proposals/" "$P/$f.md"; assert_output "1"
    done
    run grep -c "memory-proposals/" "$P/post-impl-review.md"; assert_output "0"
    run head -1 "$P/implement.md"
    assert_output --partial "sandbox-pal container"
    run grep -c "Prior Work on This Branch" "$P/implement.md"; assert_output "1"
    run grep -c "You cannot write anything under .claude/" "$P/implement.md"; assert_output "1"
    run grep -c '"action": "addressed"' "$P/post-impl-retry.md"; assert_output "1"
    run grep -c "AGENT_REVIEW_LEDGER" "$P/post-impl-review.md"; assert_output "1"
    if [ -d "$HOME/repos/sandbox-pal-action/.git" ]; then
        # Exact diff budget: adversarial-plan identical; post-impl-review identical;
        # the other three differ only by the appended paragraph (and implement's intro).
        run diff <(git -C "$HOME/repos/sandbox-pal-action" show 04cef68:prompts/adversarial-plan.md) "$P/adversarial-plan.md"; assert_success
        run diff <(git -C "$HOME/repos/sandbox-pal-action" show 04cef68:prompts/post-impl-review.md) "$P/post-impl-review.md"; assert_success
    fi
}

# ── worktree ────────────────────────────────────────────────────

@test "worktree: resumes from origin/<branch> when it exists, else branches from origin/main; excludes .agent-data" {
    # shellcheck disable=SC1091
    . "$LIB_DIR/worktree.sh"
    origin="$T/origin.git"; git init -q --bare -b main "$origin"
    seed="$T/seed"; git clone -q "$origin" "$seed"
    git -C "$seed" -c user.email=t@e -c user.name=t commit -q --allow-empty -m base
    git -C "$seed" push -q origin HEAD:main
    # gh stub: `gh repo clone <repo> <dir>` → git clone from $origin
    cat > "$T/bin/gh" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$FAKE_GH_LOG"
case "\$1 \$2" in
  "repo clone") git clone -q "$origin" "\$4" ;;
esac
exit 0
FAKE
    chmod +x "$T/bin/gh"
    export HOME="$T/home"; mkdir -p "$HOME"
    export WORKTREE_DIR="$T/wt1"; export GH_TOKEN=x
    setup_worktree "owner/repo" 42 implement
    assert_equal "$BRANCH_NAME" "agent/issue-42"
    run git -C "$WORKTREE_DIR" log --oneline; assert_line --partial "base"
    run cat "$(git -C "$WORKTREE_DIR" rev-parse --git-path info/exclude)"; assert_line ".agent-data/"

    # push a commit on the branch, wipe, re-setup → resumes with that commit
    git -C "$WORKTREE_DIR" -c user.email=t@e -c user.name=t commit -q --allow-empty -m "prior work"
    git -C "$WORKTREE_DIR" push -q origin agent/issue-42
    git -C "$HOME/.cache/repos/owner/repo" worktree remove --force "$WORKTREE_DIR"
    export WORKTREE_DIR="$T/wt2"
    setup_worktree "owner/repo" 42 implement
    run git -C "$WORKTREE_DIR" log --oneline; assert_line --partial "prior work"
    run cat "$LOG_FILE"; assert_output --partial "resuming from origin/agent/issue-42"
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/test_container_lib.bats`
Expected: prompts test fails (`test-fix.md` missing); worktree test fails on the `.agent-data/` exclude line and on "prior work".

- [ ] **Step 3: Re-vendor prompts**

```bash
for f in adversarial-plan post-impl-review post-impl-retry implement; do
  git -C ~/repos/sandbox-pal-action show "04cef68:prompts/$f.md" > "image/opt/pal/prompts/$f.md"
done
git -C ~/repos/sandbox-pal-action show 04cef68:prompts/test-fix.md > image/opt/pal/prompts/test-fix.md
```

Then edit `implement.md` line 1: replace
`You are implementing an approved plan for a GitHub issue in this repository.`
with
`You are implementing an approved plan for a GitHub issue in this repository, running inside a sandbox-pal container.`
and in the same file replace `This plan has been reviewed and approved by a human. Follow it closely.` with `This plan has been reviewed and approved. Follow it closely.`

Append this exact paragraph (preceded by one blank line) to the **end** of `implement.md`, `post-impl-retry.md` and `test-fix.md`:

```markdown
## Memory proposals
Memory files under the memory directory are read-only. If you learn something durable about this repository that a future session should know (a non-obvious convention, a trap, a decision), write it as a proposal: one file per fact at `.agent-data/memory-proposals/<kebab-slug>.md`, with the same frontmatter as a memory file (`name`, `description`, `metadata.type`). Do not commit these files. A human triages them after the run.
```

- [ ] **Step 4: Worktree resume + exclude**

In `image/opt/pal/lib/worktree.sh`, first make the clone cache home-relative so the lib runs on the host in tests (inside the container `HOME=/home/agent`, so behaviour is unchanged). Replace

```bash
    local repo_cache="/home/agent/.cache/repos/$repo"
```

with

```bash
    local repo_cache="${PAL_REPO_CACHE:-$HOME/.cache/repos}/$repo"
```

Then replace the `else` branch of the `if [ "$event_type" = "revise" ]` block:

```bash
    else
        log "worktree: creating worktree on $branch_name from origin/main"
        git -C "$repo_cache" worktree add -B "$branch_name" "$WORKTREE_DIR" origin/main
        BRANCH_NAME="$branch_name"
    fi
```

with:

```bash
    else
        # A previous run may have pushed the work branch before a gate
        # failed (preserve_branch). Resume from it instead of restarting.
        if git -C "$repo_cache" show-ref --verify --quiet "refs/remotes/origin/$branch_name"; then
            log "worktree: resuming from origin/$branch_name"
            git -C "$repo_cache" worktree add -B "$branch_name" "$WORKTREE_DIR" "origin/$branch_name"
        else
            log "worktree: creating worktree on $branch_name from origin/main"
            git -C "$repo_cache" worktree add -B "$branch_name" "$WORKTREE_DIR" origin/main
        fi
        BRANCH_NAME="$branch_name"
    fi

    # Run-scoped scratch (ledger, denials log, memory proposals) must never
    # be committed by a phase; the ledger is added with -f deliberately.
    local exclude_file
    exclude_file="$(git -C "$WORKTREE_DIR" rev-parse --git-path info/exclude)"
    mkdir -p "$(dirname "$exclude_file")"
    grep -qx '.agent-data/' "$exclude_file" 2>/dev/null || echo '.agent-data/' >> "$exclude_file"
```

Note `git fetch --prune origin` already runs on the cache before this, so `origin/$branch_name` is current.

- [ ] **Step 5: Run to verify they pass**

Run: `shellcheck image/opt/pal/lib/worktree.sh && bats tests/test_container_lib.bats`
Expected: `32 tests, 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add image/opt/pal/prompts image/opt/pal/lib/worktree.sh tests/test_container_lib.bats
git commit -m "feat(container): re-vendor prompts (+test-fix), memory-proposal rule, resume work branch"
```

---

### Task 9: Rewrite `run-pipeline.sh` and test it end to end on the host

**Files:**
- Rewrite: `image/opt/pal/run-pipeline.sh`
- Create: `tests/test_run_pipeline.bats`

**Interfaces:**
- Consumes: everything from Tasks 2–8.
- Produces: `status.json` with the fields in spec §3.4; env contract in the file header below.

- [ ] **Step 1: Write the failing end-to-end test**

```bash
#!/usr/bin/env bats
# tests/test_run_pipeline.bats
# Runs image/opt/pal/run-pipeline.sh on the host: bare-repo origin, stub gh,
# fake claude (sequence mode), stub sudo. No Docker, no network.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'test_helper/container-lib'

setup() {
    container_lib_setup
    export HOME="$T/home"; mkdir -p "$HOME"
    ORIGIN="$T/origin.git"; git init -q --bare -b main "$ORIGIN"
    seed="$T/seed"; git clone -q "$ORIGIN" "$seed"
    printf 'main\n' > "$seed/README.md"
    git -C "$seed" add README.md
    git -C "$seed" -c user.email=t@e -c user.name=t commit -q -m base
    git -C "$seed" push -q origin HEAD:main

    # gh stub with the verbs run-pipeline.sh uses.
    cat > "$T/bin/gh" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$FAKE_GH_LOG"
case "\$1 \$2" in
  "auth setup-git") exit 0 ;;
  "repo clone") git clone -q "$ORIGIN" "\$4" ;;
  "issue view") cat "$T/issue.json" ;;
  "issue comment") exit 0 ;;
  "pr create") echo "https://github.com/owner/repo/pull/7" ;;
  "pr view") echo "https://github.com/owner/repo/pull/7" ;;
esac
exit 0
FAKE
    chmod +x "$T/bin/gh"
    cat > "$T/issue.json" <<'J'
{"title":"Add thing","body":"body","comments":[{"author":{"login":"jonny"},"createdAt":"2026-08-29T00:00:00Z","body":"<!-- agent-plan -->\n# Plan\nDo the thing."}]}
J
    export RUN_ID="testrun"
    export PAL_STATUS_DIR="$STATUS_DIR"
    export WORKTREE_DIR="$T/wt"
    export AGENT_DATA_DIR="$T/agent-data"
    export GH_TOKEN="not-token-shaped-but-secret-value-1234"
    unset AGENT_TEST_COMMAND
    PIPELINE="$REPO_ROOT/image/opt/pal/run-pipeline.sh"
}
teardown() { container_lib_teardown; }

_ok()        { printf '{"result":"%s","subtype":"success","is_error":false}' "$1"; }
_structured() { printf '{"result":"","subtype":"success","is_error":false,"structured_output":%s}' "$1"; }

@test "implement: happy path — approved plan, one commit, review approved, PR opened, status.json complete" {
    fake_claude_enqueue "$(_structured '{"action":"approved"}')"
    fake_claude_enqueue "$(_ok 'implemented')" \
        'echo x > x.txt; git add x.txt; git commit -q -m "feat: x"; mkdir -p .agent-data/memory-proposals; printf -- "---\nname: thing-trap\ndescription: d\nmetadata:\n  type: project\n---\nbody\n" > .agent-data/memory-proposals/thing-trap.md'
    fake_claude_enqueue "$(_structured '{"action":"approved","verified_fixed":[],"reopened":[],"findings":[{"severity":"non-blocking","description":"nit"}]}')"

    run "$PIPELINE" implement owner/repo 42
    assert_success

    S="$STATUS_DIR/status.json"
    run jq -r '.outcome, .phase, .pr_number, .pr_url' "$S"
    assert_line --index 0 "success"; assert_line --index 1 "complete"
    assert_line --index 2 "7"; assert_line --index 3 "https://github.com/owner/repo/pull/7"
    run jq -r '.commits | length' "$S"; assert_output "2"   # feat + ledger commit
    run jq -r '.review_ledger.cycles, (.review_ledger.findings|length), .review_concerns_unresolved|length' "$S"
    assert_line --index 0 "1"; assert_line --index 1 "1"; assert_line --index 2 "0"
    run jq -r '.permission_denials | length' "$S"; assert_output "0"
    run jq -r '.memory_proposals[0]' "$S"; assert_output "thing-trap.md"
    [ -f "$STATUS_DIR/memory-proposals/thing-trap.md" ]
    [ ! -d "$WORKTREE_DIR" ]                                  # wiped at exit
    run git -C "$ORIGIN" branch --list agent/issue-42; assert_output --partial "agent/issue-42"
    run cat "$FAKE_GH_LOG"
    assert_output --partial "pr create"
    assert_output --partial "### Memory proposals"
    assert_output --partial "thing-trap"
    assert_output --partial "Adversarial Review Ledger"
    refute_output --partial "$GH_TOKEN"
}

@test "implement: review cap reached → PR opened with ⚠ header, outcome review_concerns_unresolved, concerns listed" {
    export AGENT_POST_IMPL_REVIEW_MAX_RETRIES=0
    fake_claude_enqueue "$(_structured '{"action":"approved"}')"
    fake_claude_enqueue "$(_ok 'implemented')" 'echo x > x.txt; git add x.txt; git commit -q -m "feat: x"'
    fake_claude_enqueue "$(_structured '{"action":"concerns","verified_fixed":[],"reopened":[],"findings":[{"severity":"blocking","description":"no test"}]}')"

    run "$PIPELINE" implement owner/repo 42
    assert_failure
    S="$STATUS_DIR/status.json"
    run jq -r '.outcome, .pr_number, .review_concerns_unresolved[0]' "$S"
    assert_line --index 0 "review_concerns_unresolved"; assert_line --index 1 "7"; assert_line --index 2 "F1: no test"
    run cat "$FAKE_GH_LOG"; assert_output --partial "Review Unresolved"
}

@test "implement: API error during implement is fail-fast with implement_api_error" {
    fake_claude_enqueue "$(_structured '{"action":"approved"}')"
    fake_claude_enqueue '{"is_error":true,"subtype":"success","terminal_reason":"api_error","api_error_status":529,"result":"Overloaded"}'
    run "$PIPELINE" implement owner/repo 42
    assert_failure
    run jq -r '.outcome, .failure_reason, .phase' "$STATUS_DIR/status.json"
    assert_line --index 0 "failure"; assert_line --index 1 "implement_api_error"; assert_line --index 2 "implementing"
    run cat "$FAKE_GH_LOG"; refute_output --partial "pr create"
}

@test "implement: permission denials reach status.json and the PR body" {
    fake_claude_enqueue "$(_structured '{"action":"approved"}')"
    fake_claude_enqueue '{"result":"done","subtype":"success","is_error":false,"permission_denials":[{"tool_name":"Bash","tool_input":{"command":"npm test"}}]}' \
        'echo x > x.txt; git add x.txt; git commit -q -m "feat: x"'
    fake_claude_enqueue "$(_structured '{"action":"approved","verified_fixed":[],"reopened":[],"findings":[]}')"
    run "$PIPELINE" implement owner/repo 42
    assert_success
    run jq -r '.permission_denials[0]' "$STATUS_DIR/status.json"; assert_output "[implement] Bash: npm test"
    run cat "$FAKE_GH_LOG"; assert_output --partial "### Permission Denials"
}

@test "implement: empty diff fails with empty_diff before any gate" {
    fake_claude_enqueue "$(_structured '{"action":"approved"}')"
    fake_claude_enqueue "$(_ok 'did nothing')"
    run "$PIPELINE" implement owner/repo 42
    assert_failure
    run jq -r '.failure_reason' "$STATUS_DIR/status.json"; assert_output "empty_diff"
}

@test "implement: test gate red with no-commit fix session fails with tests_failed_after_1_fix_sessions and preserves the branch" {
    export AGENT_TEST_COMMAND="test -f green"
    fake_claude_enqueue "$(_structured '{"action":"approved"}')"
    fake_claude_enqueue "$(_ok 'implemented')" 'echo x > x.txt; git add x.txt; git commit -q -m "feat: x"'
    fake_claude_enqueue "$(_ok 'cannot fix')"
    run "$PIPELINE" implement owner/repo 42
    assert_failure
    run jq -r '.failure_reason' "$STATUS_DIR/status.json"; assert_output "tests_failed_after_1_fix_sessions"
    run git -C "$ORIGIN" branch --list agent/issue-42; assert_output --partial "agent/issue-42"
}

@test "implement: AGENT_IMPL_MAX_RETRIES logs a deprecation warning" {
    export AGENT_IMPL_MAX_RETRIES=2
    fake_claude_enqueue "$(_structured '{"action":"approved"}')"
    fake_claude_enqueue "$(_ok 'implemented')" 'echo x > x.txt; git add x.txt; git commit -q -m "feat: x"'
    fake_claude_enqueue "$(_structured '{"action":"approved","verified_fixed":[],"reopened":[],"findings":[]}')"
    run "$PIPELINE" implement owner/repo 42
    assert_success
    assert_output --partial "AGENT_IMPL_MAX_RETRIES is no longer used"
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/test_run_pipeline.bats`
Expected: every test fails — the current pipeline calls `run_post_impl_review`/`handle_post_impl_review_retry`, has no `review_ledger` field, and does not copy memory proposals.

- [ ] **Step 3: Rewrite `run-pipeline.sh`**

Replace the file with:

```bash
#!/usr/bin/env bash
# image/opt/pal/run-pipeline.sh
# shellcheck disable=SC1091  # Sourced lib files resolved at runtime
#
# Per-run pipeline. Invoked via `docker exec` against a long-running workspace
# container. Expects firewall already programmed by workspace-boot.sh.
#
# Usage: run-pipeline.sh <event-type> <repo> <number>
#   event-type in {implement, revise}
#   repo       = owner/name
#   number     = issue or PR number
#
# Reads from environment (set at exec time by lib/launcher.sh):
#   GH_TOKEN, RUN_ID, AGENT_TEST_COMMAND, AGENT_TEST_SETUP_COMMAND,
#   PAL_ALLOWLIST_EXTRA_DOMAINS, and any AGENT_* knob from .pal/config.env:
#   AGENT_ALLOWED_TOOLS_{TRIAGE,IMPLEMENT}, AGENT_MODEL[_<PHASE>],
#   AGENT_PROMPT_<PHASE>, AGENT_JSON_SCHEMA_<PHASE> ("" disables),
#   AGENT_BUDGET_USD[_<PHASE>], AGENT_EFFORT_<PHASE>, AGENT_PERMISSION_MODE_<PHASE>,
#   AGENT_MCP_CONFIG, AGENT_STRICT_MCP, AGENT_SESSION_PERSISTENCE, AGENT_ADD_DIRS,
#   AGENT_MEMORY_DIR, AGENT_MAX_TURNS, AGENT_TIMEOUT,
#   AGENT_ADVERSARIAL_PLAN_REVIEW, AGENT_POST_IMPL_REVIEW,
#   AGENT_POST_IMPL_REVIEW_MAX_RETRIES, AGENT_TEST_GATE_MAX_RETRIES.
# Phases: ADVERSARIAL_PLAN, IMPLEMENT, TEST_FIX, POST_IMPL_REVIEW, POST_IMPL_RETRY.

set -euo pipefail

# --- Args: <event_type> <repo> <number> -------------------------
EVENT_TYPE="${1:?Usage: run-pipeline.sh <event_type> <repo> <number>}"
REPO="${2:?}"
NUMBER="${3:?}"

# --- Paths -------------------------------------------------------
PAL_HOME="${PAL_HOME:-/opt/pal}"
# Tests run this script from the repo checkout: derive PAL_HOME from the
# script location when /opt/pal is not where we live.
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -d "$PAL_HOME/lib" ] || PAL_HOME="$_self_dir"
# shellcheck disable=SC2034  # PROMPTS_DIR is read by lib/claude-runner.sh
PROMPTS_DIR="$PAL_HOME/prompts"
LIB_DIR="$PAL_HOME/lib"
SCHEMAS_DIR="$PAL_HOME/schemas"

RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
STATUS_DIR="${PAL_STATUS_DIR:-/status/${RUN_ID}}"
WORKTREE_DIR="${WORKTREE_DIR:-/home/agent/work/${RUN_ID}}"
AGENT_DATA_DIR="${AGENT_DATA_DIR:-/home/agent/.agent-data}"

mkdir -p "$STATUS_DIR" "$WORKTREE_DIR" "$AGENT_DATA_DIR"

# --- Defaults for every knob the gates read (set -u safety) ------
AGENT_TEST_COMMAND="${AGENT_TEST_COMMAND:-}"
AGENT_TEST_SETUP_COMMAND="${AGENT_TEST_SETUP_COMMAND:-}"
AGENT_ADVERSARIAL_PLAN_REVIEW="${AGENT_ADVERSARIAL_PLAN_REVIEW:-true}"
AGENT_POST_IMPL_REVIEW="${AGENT_POST_IMPL_REVIEW:-true}"
AGENT_POST_IMPL_REVIEW_MAX_RETRIES="${AGENT_POST_IMPL_REVIEW_MAX_RETRIES:-3}"
AGENT_TEST_GATE_MAX_RETRIES="${AGENT_TEST_GATE_MAX_RETRIES:-2}"
AGENT_ALLOWED_TOOLS_TRIAGE="${AGENT_ALLOWED_TOOLS_TRIAGE:-Read,Glob,Grep,Bash(ls *),Bash(git log *),Bash(git diff *),Bash(git show *),Bash(echo *),Bash(printenv *)}"
AGENT_ALLOWED_TOOLS_IMPLEMENT="${AGENT_ALLOWED_TOOLS_IMPLEMENT:-Read,Write,Edit,Glob,Grep,Bash(git *),Bash(ls *),Bash(cat *),Bash(echo *),Bash(printenv *),Bash(mkdir *),Bash(mv *),Bash(cp *),Bash(rm *),Bash(chmod *)}"
AGENT_MODEL_ADVERSARIAL_PLAN="${AGENT_MODEL_ADVERSARIAL_PLAN:-}"
AGENT_MODEL_IMPLEMENT="${AGENT_MODEL_IMPLEMENT:-}"
AGENT_MODEL_TEST_FIX="${AGENT_MODEL_TEST_FIX:-}"
AGENT_MODEL_POST_IMPL_REVIEW="${AGENT_MODEL_POST_IMPL_REVIEW:-}"
AGENT_MODEL_POST_IMPL_RETRY="${AGENT_MODEL_POST_IMPL_RETRY:-}"
AGENT_PROMPT_ADVERSARIAL_PLAN="${AGENT_PROMPT_ADVERSARIAL_PLAN:-}"
AGENT_PROMPT_IMPLEMENT="${AGENT_PROMPT_IMPLEMENT:-}"
AGENT_PROMPT_TEST_FIX="${AGENT_PROMPT_TEST_FIX:-}"
AGENT_PROMPT_POST_IMPL_REVIEW="${AGENT_PROMPT_POST_IMPL_REVIEW:-}"
AGENT_PROMPT_POST_IMPL_RETRY="${AGENT_PROMPT_POST_IMPL_RETRY:-}"
# `-` not `:-`: an explicitly empty value disables that phase's schema.
AGENT_JSON_SCHEMA_ADVERSARIAL_PLAN="${AGENT_JSON_SCHEMA_ADVERSARIAL_PLAN-$SCHEMAS_DIR/adversarial-plan.json}"
AGENT_JSON_SCHEMA_POST_IMPL_REVIEW="${AGENT_JSON_SCHEMA_POST_IMPL_REVIEW-$SCHEMAS_DIR/post-impl-review.json}"
AGENT_JSON_SCHEMA_POST_IMPL_RETRY="${AGENT_JSON_SCHEMA_POST_IMPL_RETRY-$SCHEMAS_DIR/post-impl-retry.json}"
export AGENT_TEST_COMMAND AGENT_TEST_SETUP_COMMAND

# --- Status tracking (mutated across phases, emitted at end) ----
STATUS_PHASE="init"
STATUS_OUTCOME="failure"            # default; set to "success" on happy path
STATUS_FAILURE_REASON=""
STATUS_PR_NUMBER="null"
STATUS_PR_URL="null"
STATUS_COMMITS="[]"
STATUS_STARTED_AT="$(date -u +%FT%TZ)"

# --- Logging -----------------------------------------------------
LOG_FILE="$STATUS_DIR/log"
log() {
    printf '[%s] %s\n' "$(date -Iseconds)" "$*" | tee -a "$LOG_FILE" >&2
}

# --- status.json writer (atomic) ---------------------------------
# review_concerns_* are derived from the ledger (lib/launcher.sh renders
# review_concerns_unresolved in the async summary).
write_status() {
    local completed_at ledger_json='null' addressed='[]' unresolved='[]'
    local denials='[]' proposals='[]'
    completed_at="$(date -u +%FT%TZ)"
    local ledger="${WORKTREE_DIR}/.agent-data/review-ledger.json"
    if [ -f "$ledger" ] && jq -e . "$ledger" >/dev/null 2>&1; then
        ledger_json=$(jq -c . "$ledger")
        addressed=$(jq -c '[.findings[] | select(.status == "fixed") | "\(.id): \(.description)"]' "$ledger")
        unresolved=$(jq -c '[.findings[] | select(.severity == "blocking" and .status == "open") | "\(.id): \(.description)"]' "$ledger")
    fi
    local denials_file="${WORKTREE_DIR}/.agent-data/permission-denials.log"
    if [ -s "$denials_file" ]; then
        denials=$(jq -Rsc 'split("\n") | map(select(. != ""))' < "$denials_file")
    fi
    if [ -d "$STATUS_DIR/memory-proposals" ]; then
        proposals=$(find "$STATUS_DIR/memory-proposals" -maxdepth 1 -name '*.md' -printf '%f\n' | sort | jq -Rsc 'split("\n") | map(select(. != ""))')
    fi
    jq -n \
        --arg phase "$STATUS_PHASE" \
        --arg outcome "$STATUS_OUTCOME" \
        --arg failure_reason "$STATUS_FAILURE_REASON" \
        --arg started_at "$STATUS_STARTED_AT" \
        --arg completed_at "$completed_at" \
        --argjson pr_number "$STATUS_PR_NUMBER" \
        --argjson pr_url "$STATUS_PR_URL" \
        --argjson commits "$STATUS_COMMITS" \
        --argjson addressed "$addressed" \
        --argjson unresolved "$unresolved" \
        --argjson ledger "$ledger_json" \
        --argjson denials "$denials" \
        --argjson proposals "$proposals" \
        --arg event_type "$EVENT_TYPE" \
        --arg repo "$REPO" \
        --argjson number "$NUMBER" \
        '{phase: $phase, outcome: $outcome,
          failure_reason: (if $failure_reason == "" then null else $failure_reason end),
          started_at: $started_at, completed_at: $completed_at,
          pr_number: $pr_number, pr_url: $pr_url, commits: $commits,
          review_concerns_addressed: $addressed, review_concerns_unresolved: $unresolved,
          review_ledger: $ledger, permission_denials: $denials, memory_proposals: $proposals,
          event_type: $event_type, repo: $repo, number: $number}' \
        > "$STATUS_DIR/status.json.tmp"
    mv "$STATUS_DIR/status.json.tmp" "$STATUS_DIR/status.json"
}

# --- Memory proposals: copy out of the worktree before it is wiped ----
harvest_memory_proposals() {
    local src="${WORKTREE_DIR}/.agent-data/memory-proposals"
    [ -d "$src" ] || return 0
    if find "$src" -maxdepth 1 -name '*.md' | grep -q .; then
        mkdir -p "$STATUS_DIR/memory-proposals"
        cp "$src"/*.md "$STATUS_DIR/memory-proposals/"
        log "memory: $(find "$src" -maxdepth 1 -name '*.md' | wc -l) proposal(s) copied to $STATUS_DIR/memory-proposals/"
    fi
}

# --- Global error trap: write a failure status before exit ------
on_error() {
    local ec=$?
    [ "$ec" -eq 0 ] && return 0
    log "run-pipeline failed at line ${1:-?} with exit code $ec (phase=$STATUS_PHASE)"
    if [ -z "$STATUS_FAILURE_REASON" ]; then
        STATUS_FAILURE_REASON="uncaught_error_at_line_${1:-unknown}_exit_${ec}"
    fi
    STATUS_OUTCOME="failure"
}
trap 'on_error $LINENO' ERR

# --- Exit trap: harvest, write status, wipe per-run transient state --
cleanup_on_exit() {
    harvest_memory_proposals
    write_status
    local wt_slug="${WORKTREE_DIR//\//-}"
    rm -rf "$WORKTREE_DIR" "/home/agent/.claude/projects/${wt_slug}" 2>/dev/null || true
}
trap 'cleanup_on_exit' EXIT

# --- Source lib files ------------------------------------------
. "$LIB_DIR/claude-runner.sh"
. "$LIB_DIR/review-gates.sh"
. "$LIB_DIR/firewall.sh"
. "$LIB_DIR/worktree.sh"
. "$LIB_DIR/fetch-context.sh"

# --- Main pipeline ----------------------------------------------
log "sandbox-pal run-pipeline"
log "event=$EVENT_TYPE repo=$REPO number=$NUMBER run_id=$RUN_ID"
if [ -n "${AGENT_IMPL_MAX_RETRIES:-}" ]; then
    log "WARN: AGENT_IMPL_MAX_RETRIES is no longer used; the pre-PR test gate uses AGENT_TEST_GATE_MAX_RETRIES (default 2)"
fi

if [ -n "${PAL_ALLOWLIST_EXTRA_DOMAINS:-}" ]; then
    STATUS_PHASE="refreshing_firewall"
    for d in $(printf '%s\n' "$PAL_ALLOWLIST_EXTRA_DOMAINS" | tr ',' ' '); do
        [ -z "$d" ] && continue
        refresh_firewall_for "$d" || log "warn: firewall refresh failed for $d"
    done
fi

STATUS_PHASE="cloning"
setup_worktree "$REPO" "$NUMBER" "$EVENT_TYPE" || {
    STATUS_FAILURE_REASON="worktree_setup_failed"
    exit 1
}

STATUS_PHASE="fetching_context"
if [ "$EVENT_TYPE" = "implement" ]; then
    set +e
    fetch_issue_context "$REPO" "$NUMBER"
    ctx_rc=$?
    set -e
    if [ "$ctx_rc" -eq 2 ]; then
        STATUS_FAILURE_REASON="no_plan_found"
        exit 1
    elif [ "$ctx_rc" -ne 0 ]; then
        STATUS_FAILURE_REASON="issue_fetch_failed"
        exit 1
    fi
elif [ "$EVENT_TYPE" = "revise" ]; then
    fetch_pr_context "$REPO" "$NUMBER" || {
        STATUS_FAILURE_REASON="pr_fetch_failed"
        exit 1
    }
else
    STATUS_FAILURE_REASON="unknown_event_type_${EVENT_TYPE}"
    exit 1
fi

if [ "$EVENT_TYPE" = "implement" ]; then
    STATUS_PHASE="adversarial_review"
    if ! run_adversarial_plan_review; then
        # review-gates.sh set STATUS_OUTCOME / STATUS_FAILURE_REASON
        exit 1
    fi
fi

# --- Implement phase ---------------------------------------------
STATUS_PHASE="implementing"
if [ -n "$AGENT_TEST_COMMAND" ]; then
    AGENT_ALLOWED_TOOLS_IMPLEMENT="${AGENT_ALLOWED_TOOLS_IMPLEMENT},Bash(${AGENT_TEST_COMMAND%% *} *)"
fi
if [ -n "$AGENT_TEST_SETUP_COMMAND" ]; then
    AGENT_ALLOWED_TOOLS_IMPLEMENT="${AGENT_ALLOWED_TOOLS_IMPLEMENT},Bash(${AGENT_TEST_SETUP_COMMAND%% *} *)"
fi

if [ "$EVENT_TYPE" = "revise" ]; then
    # Reuse the retry prompt for PR feedback; feed the feedback as concerns.
    impl_prompt=$(load_prompt "post-impl-retry" "$AGENT_PROMPT_POST_IMPL_RETRY")
    export AGENT_REVIEW_CONCERNS="${AGENT_REVIEW_FEEDBACK:-}"
    export AGENT_REVIEW_LEDGER='{"cycles":0,"findings":[]}'
else
    impl_prompt=$(load_prompt "implement" "$AGENT_PROMPT_IMPLEMENT")
fi

start_sha=$(git -C "$WORKTREE_DIR" rev-parse HEAD)

set_heartbeat "implement"
result=$(run_claude "$impl_prompt" "$AGENT_ALLOWED_TOOLS_IMPLEMENT" "$AGENT_MODEL_IMPLEMENT" "" "IMPLEMENT")
log_permission_denials "$result" "implement"
claude_output=$(parse_claude_output "$result")
log "implement: claude output (first 500 chars): ${claude_output:0:500}"
if [ "$(classify_claude_result "$result")" = "fail_fast" ]; then
    STATUS_FAILURE_REASON="implement_api_error"
    gh issue comment "$NUMBER" --repo "$REPO" \
        --body "Agent implementation phase hit an API error (${claude_output}). Re-run \`/pal-implement\` once the API issue is resolved." 2>/dev/null || true
    exit 1
fi

end_sha=$(git -C "$WORKTREE_DIR" rev-parse HEAD)
if [ "$start_sha" = "$end_sha" ]; then
    STATUS_FAILURE_REASON="empty_diff"
    exit 1
fi
log "implement: captured $(git -C "$WORKTREE_DIR" rev-list --count "${start_sha}..${end_sha}") new commits"

# Preserve finished work BEFORE any gate can fail.
refresh_firewall_for github.com
refresh_firewall_for api.github.com
preserve_branch || true

# --- Pre-PR test gate (bounded fix sessions) ---------------------
STATUS_PHASE="testing"
if ! run_test_gate "$AGENT_ALLOWED_TOOLS_IMPLEMENT" "${AGENT_ISSUE_TITLE:-}"; then
    exit 1
fi

# --- Post-implementation review loop -----------------------------
STATUS_PHASE="post_impl_review"
review_rc=0
run_post_impl_review_loop "$AGENT_ALLOWED_TOOLS_IMPLEMENT" || review_rc=$?
if [ "$review_rc" -eq 1 ]; then
    exit 1
fi

end_sha=$(git -C "$WORKTREE_DIR" rev-parse HEAD)
STATUS_COMMITS=$(git -C "$WORKTREE_DIR" log --format='%h' "${start_sha}..${end_sha}" | jq -R . | jq -sc . 2>/dev/null || echo '[]')

# --- Push + PR ----------------------------------------------------
STATUS_PHASE="pushing_pr"
refresh_firewall_for github.com
refresh_firewall_for api.github.com

if ! git -C "$WORKTREE_DIR" push -u origin "$BRANCH_NAME"; then
    STATUS_FAILURE_REASON="git_push_failed"
    exit 1
fi
log "pushed branch $BRANCH_NAME"

ledger_summary=""
unresolved_header=""
if [ -f "${WORKTREE_DIR}/.agent-data/review-ledger.json" ]; then
    LEDGER_FILE="${WORKTREE_DIR}/.agent-data/review-ledger.json"
    ledger_summary="
### Adversarial Review Ledger

$(_ledger_pr_summary)
"
    if [ "$review_rc" -eq 2 ]; then
        unresolved_header="## ⚠ Review Unresolved

The adversarial review loop hit its retry cap with blocking findings still open. Do not merge before arbitrating these:

$(_ledger_outstanding_summary)

---
"
    fi
fi

memory_section=""
proposals_dir="${WORKTREE_DIR}/.agent-data/memory-proposals"
if [ -d "$proposals_dir" ] && find "$proposals_dir" -maxdepth 1 -name '*.md' | grep -q .; then
    memory_section="
<details><summary>### Memory proposals</summary>

The agent proposed durable learnings for the host memory. Triage with \`/pal-memory ${RUN_ID}\`.

$(for f in "$proposals_dir"/*.md; do
    n=$(sed -n 's/^name:[[:space:]]*//p' "$f" | head -1)
    d=$(sed -n 's/^description:[[:space:]]*//p' "$f" | head -1)
    printf -- '- **%s** — %s\n' "${n:-$(basename "$f")}" "${d:-}"
done)
</details>
"
fi

if [ "$EVENT_TYPE" = "revise" ]; then
    STATUS_PR_NUMBER="$NUMBER"
    existing_pr_url=$(gh pr view "$NUMBER" --repo "$REPO" --json url --jq .url)
    STATUS_PR_URL="\"$existing_pr_url\""
    log "revise: new commits pushed to existing PR #$NUMBER"
else
    pr_title="${AGENT_ISSUE_TITLE:-sandbox-pal implementation}"
    commit_log=$(git -C "$WORKTREE_DIR" log --format="- %s" "origin/main..HEAD" 2>/dev/null | head -20)
    pr_body="${unresolved_header}## Automated PR for #${NUMBER}

Implemented by sandbox-pal based on the approved plan in issue #${NUMBER}.

${claude_output:0:2000}
${ledger_summary}$(denials_report_section)${memory_section}
### Commits
${commit_log}

Closes #${NUMBER}"

    pr_create_output=$(gh pr create \
        --repo "$REPO" \
        --title "$pr_title" \
        --body "$pr_body" \
        --base main \
        --head "$BRANCH_NAME" 2>&1) || {
            STATUS_FAILURE_REASON="pr_create_failed: ${pr_create_output}"
            exit 1
        }
    STATUS_PR_URL="\"$(echo "$pr_create_output" | tail -1)\""
    STATUS_PR_NUMBER=$(echo "$STATUS_PR_URL" | grep -Eo '/pull/[0-9]+' | grep -Eo '[0-9]+')
    log "created PR at $STATUS_PR_URL"
fi

if [ "$review_rc" -eq 2 ]; then
    STATUS_OUTCOME="review_concerns_unresolved"
    STATUS_FAILURE_REASON="post_impl_review_unresolved"
    STATUS_PHASE="complete"
    exit 1
fi

STATUS_OUTCOME="success"
STATUS_PHASE="complete"
```

Notes for the implementer:
- The PR body is passed to the `gh` stub, which logs `$*` — that is how the tests assert on "### Memory proposals" and the ledger heading.
- `write_status` uses `jq -n` so the `pr_create_failed: …` reason and PR body fragments can never break the JSON (the old heredoc could).
- `STATUS_COMMITS` is captured **after** the review loop so ledger/retry commits are included (`.commits | length == 2` in the happy-path test: `feat: x` + the ledger commit).
- `set -e` + `ERR` trap: `run_post_impl_review_loop ... || review_rc=$?` is the only way to read a non-zero return without tripping the trap.

- [ ] **Step 4: Run to verify they pass**

Run: `shellcheck image/opt/pal/run-pipeline.sh && bats tests/test_run_pipeline.bats tests/test_container_lib.bats`
Expected: all green (`7` + `32`). Likely first-run failures and their fixes:
- `find: unknown predicate -printf` on macOS — not a concern here (Linux host and Ubuntu image).
- If the happy-path `.commits | length` is `1`, the ledger commit did not happen: check `_ledger_commit` output in `$STATUS_DIR/log` (git identity is set in `setup_worktree`).

- [ ] **Step 5: Commit**

```bash
git add image/opt/pal/run-pipeline.sh tests/test_run_pipeline.bats
git commit -m "feat(container): pipeline on the ledger review loop, test gate, fail-fast, denials and memory proposals"
```

---

### Task 10: Integration-test gate, `diff-upstream.sh`, `UPSTREAM.md`, `CHANGELOG.md`, full check

**Files:**
- Modify: `tests/test_container_pipeline.bats:17-32`
- Modify: `scripts/diff-upstream.sh`
- Rewrite: `UPSTREAM.md`
- Modify: `CHANGELOG.md` (Unreleased)

- [ ] **Step 1: Integration test gate**

In `tests/test_container_pipeline.bats` replace

```bash
    [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]  || skip "set CLAUDE_CODE_OAUTH_TOKEN"
```

with

```bash
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx sandbox-pal-workspace \
        || skip "start and log in the sandbox-pal workspace first (/pal-setup, /pal-login)"
```

and replace the whole test body after the `skip` gates with a `docker exec` against the running workspace (delete the `build-image.sh`, `IMAGE_TAG`, `mktemp`/`chmod` lines in `setup`/the test and the `docker rmi` in `teardown` — the test now uses the workspace's own image):

```bash
    RUN_ID="pipeline-test-$RANDOM"
    run timeout 1800 docker exec \
        -e GH_TOKEN="$GH_TOKEN" \
        -e RUN_ID="$RUN_ID" \
        -e AGENT_TEST_COMMAND="${PAL_TEST_CMD:-}" \
        sandbox-pal-workspace /opt/pal/run-pipeline.sh implement "$TEST_REPO" "$TEST_ISSUE"
    assert_success

    # /status inside the workspace is a bind-mount of the host runs dir.
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/runs.sh"
    STATUS_DIR="$(pal_runs_dir)/$RUN_ID"
    assert [ -f "$STATUS_DIR/status.json" ]
    run jq -r '.outcome' "$STATUS_DIR/status.json"
    assert_output "success"
    run jq -r '.pr_url' "$STATUS_DIR/status.json"
    refute_output "null"
```

Run: `bats tests/test_container_pipeline.bats` → `1 test, 0 failures, 1 skipped` (no workspace in CI).

- [ ] **Step 2: `scripts/diff-upstream.sh`**

Replace the `UPSTREAM_REPO` default and the MAP:

```bash
UPSTREAM_REPO="${UPSTREAM_REPO:-$HOME/repos/sandbox-pal-action}"
```

```bash
declare -A MAP=(
    ["image/opt/pal/prompts/adversarial-plan.md"]="prompts/adversarial-plan.md"
    ["image/opt/pal/prompts/post-impl-review.md"]="prompts/post-impl-review.md"
    ["image/opt/pal/prompts/post-impl-retry.md"]="prompts/post-impl-retry.md"
    ["image/opt/pal/prompts/implement.md"]="prompts/implement.md"
    ["image/opt/pal/prompts/test-fix.md"]="prompts/test-fix.md"
    ["image/opt/pal/lib/review-gates.sh"]="scripts/lib/review-gates.sh"
    ["image/opt/pal/schemas/adversarial-plan.json"]="schemas/adversarial-plan.json"
    ["image/opt/pal/schemas/post-impl-review.json"]="schemas/post-impl-review.json"
    ["image/opt/pal/schemas/post-impl-retry.json"]="schemas/post-impl-retry.json"
)
```

Change the first comment line to `# Diff vendored files against a local sandbox-pal-action checkout to find upstream drift.` and the temp file to `"$(mktemp)"` held in a variable (shellcheck-clean; `/tmp/pal-diff.txt` was a fixed path). Add after the loop:

```bash
echo "--- image/opt/pal/lib/claude-runner.sh ---"
echo "(ported from scripts/lib/common.sh — not a byte copy; review run_claude, parse_claude_output,"
echo " classify_claude_result, redact_secrets, *_permission_denials, get_structured_output by hand)"
```

Run: `UPSTREAM_REPO=~/repos/sandbox-pal-action scripts/diff-upstream.sh; echo rc=$?` → expected: adversarial-plan, post-impl-review, the three schemas print `(unchanged)`; implement/post-impl-retry/test-fix show only the appended paragraph (+ implement's two intro edits); review-gates shows only the Task 7 edits. Exit code 1 is expected (there are local modifications).

- [ ] **Step 3: `UPSTREAM.md`**

Rewrite:

```markdown
# Upstream Vendored Files

This project vendors pieces of `jnurre64/sandbox-pal-action`. Each file here is
tracked with its source path, the upstream commit at time of vendor, and its
local modifications — every local modification is listed; if it is not listed,
it is drift.

Resync via `scripts/diff-upstream.sh` (defaults to `~/repos/sandbox-pal-action`;
set `UPSTREAM_REPO` to another clone). Exit 1 means at least one file differs —
compare the diff against the tables below.

Current upstream SHA: `04cef68b433e90037b4f7af34b099e6005435a1c` (merge of sandbox-pal-action#111).

## Prompts

| Local path | Source | Modifications |
|---|---|---|
| `image/opt/pal/prompts/adversarial-plan.md` | `prompts/adversarial-plan.md` | none |
| `image/opt/pal/prompts/post-impl-review.md` | `prompts/post-impl-review.md` | none |
| `image/opt/pal/prompts/post-impl-retry.md` | `prompts/post-impl-retry.md` | appended "Memory proposals" section |
| `image/opt/pal/prompts/test-fix.md` | `prompts/test-fix.md` | appended "Memory proposals" section |
| `image/opt/pal/prompts/implement.md` | `prompts/implement.md` | line 1 mentions the sandbox-pal container; "approved by a human" → "approved"; appended "Memory proposals" section |

## Schemas

| Local path | Source | Modifications |
|---|---|---|
| `image/opt/pal/schemas/adversarial-plan.json` | `schemas/adversarial-plan.json` | none |
| `image/opt/pal/schemas/post-impl-review.json` | `schemas/post-impl-review.json` | none |
| `image/opt/pal/schemas/post-impl-retry.json` | `schemas/post-impl-retry.json` | none |

Not vendored: `triage.json`, `reply.json`, `validate.json`, `cleanup.json` (no such phases here).

## Libraries

| Local path | Source | Modifications |
|---|---|---|
| `image/opt/pal/lib/review-gates.sh` | `scripts/lib/review-gates.sh` | header comment; every `set_label "agent:failed"` → `STATUS_OUTCOME="failure"` + a specific `STATUS_FAILURE_REASON`; `set_label "agent:needs-info"` → `STATUS_OUTCOME="clarification_needed"`; `notify` call removed from `run_test_gate`; comment wording "re-label / re-dispatch" → "re-run `/pal-implement`". Function bodies otherwise identical. |

## Ported helpers (`image/opt/pal/lib/claude-runner.sh`)

Not a byte copy — the container runner is the local analogue of upstream
`scripts/lib/common.sh`. Re-check these by hand on each resync:

| Local function | Upstream origin | Local difference |
|---|---|---|
| `run_claude` | `common.sh: run_claude` | `--disable-slash-commands` always; stdout also tee'd to `$STATUS_DIR/claude-stdout-<phase>-<ts>.log`; no `CONFIG_DIR` schema resolution; no `AGENT_MEMORY_FILE` (directory only) |
| `parse_claude_output`, `classify_claude_result`, `get_structured_output`, `redact_secrets`, `extract_permission_denials`, `log_permission_denials`, `preserve_branch` | `common.sh` (same names) | none |
| `denials_report_section` | `common.sh` | points at `.pal/config.env` instead of `docs/customization.md` |
| `load_prompt` | `common.sh: load_prompt` | overrides resolve against `WORKTREE_DIR`, not `CONFIG_DIR`; returns 1 instead of `exit 1` |
| `load_shared_memory`, `_resolve_memory_dir` | `common.sh` (#109) | directory-only; wording mentions memory proposals |
| `set_heartbeat` | `liveness.sh` | no-op (status.json is the liveness channel here) |

## Conceptual patterns (not directly copied)

- Data-fetch pattern for gists and attachments (upstream `scripts/lib/data-fetch.sh`) — reimplemented inline in `fetch-context.sh` with the same fetch-on-start, bind-to-env-var shape.
- Work-branch resume (upstream `worktree.sh`, #73) — `setup_worktree` checks out `origin/agent/issue-<n>` when it exists.
- PR body assembly (upstream `common.sh: handle_post_implementation`) — inlined in `run-pipeline.sh` with the ledger summary, ⚠ unresolved header, denials section, and a sandbox-pal-only memory-proposals section.

## Deliberately not vendored

- `rules-staging.sh` (#104) — follow-up issue; the prompt rule text is kept.
- `liveness.sh` (#106), orchestrator mode and `sp-*` skills (#107), `cleanup.md` phase, `notify.sh`.
```

- [ ] **Step 4: `CHANGELOG.md`**

Under `## [Unreleased]`, add above the existing `### Changed`:

```markdown
### Added
- **Container runner parity with sandbox-pal-action@04cef68.** `image/opt/pal/lib/claude-runner.sh` now scrubs secrets from every phase envelope and stderr log at capture (`redact_secrets`; `GH_TOKEN` is always present inside the workspace), classifies phase results from `is_error` first so an API error can no longer masquerade as a normal result, surfaces `permission_denials` (in the run log, `status.json` and the PR body), prefers `--json-schema` structured output for the review gates, and exposes the per-phase flag surface: `AGENT_BUDGET_USD[_<PHASE>]` (limitless unless set), `AGENT_EFFORT_<PHASE>`, `AGENT_PERMISSION_MODE_<PHASE>`, `AGENT_MCP_CONFIG` / `AGENT_STRICT_MCP` (`--strict-mcp-config`), `AGENT_SESSION_PERSISTENCE` (default off → `--no-session-persistence`), `AGENT_ADD_DIRS`, `AGENT_MEMORY_DIR`. Phases: `ADVERSARIAL_PLAN`, `IMPLEMENT`, `TEST_FIX`, `POST_IMPL_REVIEW`, `POST_IMPL_RETRY`.
- **Ledger-based review loop and pre-PR test gate** (re-vendored `review-gates.sh`): findings ride a stamped `.agent-data/review-ledger.json`; the loop runs review → fix → review up to `AGENT_POST_IMPL_REVIEW_MAX_RETRIES` (default 3, was 1) fix sessions; the test gate runs `AGENT_TEST_COMMAND` with up to `AGENT_TEST_GATE_MAX_RETRIES` (default 2) `test-fix` sessions and stops early when a fix session makes no commits. A run that hits the review cap still opens the PR, with a ⚠ header and the outstanding findings, and reports `outcome: review_concerns_unresolved`.
- **Work-branch preservation:** the implementation branch is pushed before any gate runs, and `setup_worktree` resumes from `origin/agent/issue-<n>` on the next run instead of restarting.
- **Memory proposals:** phases write durable learnings to `.agent-data/memory-proposals/*.md`; the pipeline copies them to the run directory (`memory_proposals` in `status.json`) and lists them in the PR body. Triage tooling (`/pal-memory`) arrives with the next release.
- `status.json` gains `review_ledger`, `permission_denials`, `memory_proposals`; `review_concerns_*` are now derived from the ledger.
- Host-runnable BATS coverage for the container lib (`tests/test_container_lib.bats`, `tests/test_run_pipeline.bats`) with a fake `claude`.

### Changed
- `AGENT_IMPL_MAX_RETRIES` is retired (the test gate replaces the inline TDD retry loop); setting it logs a warning.
- `scripts/diff-upstream.sh` defaults to `~/repos/sandbox-pal-action`; `UPSTREAM.md` now names that project and lists every local modification.
- `tests/test_container_pipeline.bats` gates on a running, logged-in workspace instead of the removed `CLAUDE_CODE_OAUTH_TOKEN`.
```

(Merge the `### Changed` heading with the existing one — one `### Changed` section, new bullets first.)

- [ ] **Step 5: Full check**

Run: `shellcheck $(find . -name '*.sh') && bats tests/`
Expected: shellcheck silent; bats all green with the two Docker-tagged tests skipped.

Also validate the plugin manifest still loads: `claude plugin validate ~/repos/sandbox-pal` → `✔ Validation passed`.

- [ ] **Step 6: Commit and open the PR**

```bash
git add tests/test_container_pipeline.bats scripts/diff-upstream.sh UPSTREAM.md CHANGELOG.md
git commit -m "docs: track sandbox-pal-action@04cef68 in UPSTREAM.md; diff-upstream and integration-test gate updates"
git push -u origin feature/31-adopt-upstream-batch
GH_TOKEN=$(cat ~/.config/gh-tokens/sandbox-pal-token) gh pr create --repo jnurre64/sandbox-pal \
  --title "feat(container): adopt upstream review-gate batch (runner, ledger loop, schemas, redaction)" \
  --body "Part 1 of 3 for #31 — see docs/superpowers/specs/2026-08-29-upstream-batch-adoption-design.md §5.

- Runner: redaction at capture, is_error-first classification, permission denials, structured output, per-phase flags
- Gates: re-vendored review-gates.sh (ledger loop, test gate) from sandbox-pal-action@04cef68
- Pipeline: fail-fast, branch preservation/resume, memory proposals harvested to the run dir
- Tests: tests/test_container_lib.bats + tests/test_run_pipeline.bats (host-runnable, fake claude)

PR 2 (middle path: read-only memory, skills sync, /pal-memory, #30 decision) and PR 3 (docs) follow."
```

Then rebuild the image so the next real run uses it: `scripts/build-image.sh` (or `/pal-setup --rebuild` if that flag exists — check `commands/pal-setup.md`), and restart the workspace with `/pal-workspace restart`.

---

## Self-review against the spec

- §3.1 runner: Tasks 2–5 ✔ (all listed functions; `--disable-slash-commands` kept; stdout log kept).
- §3.2 schemas + `-` defaults: Tasks 6, 9 ✔.
- §3.3 gates + adaptation rules: Task 7 ✔ (`preserve_branch` kept, `set_heartbeat` shim, ledger commits kept).
- §3.4 pipeline: Task 9 ✔ — phases, `status.json` fields (`review_concerns_*` derived, `review_ledger`, `permission_denials`, `memory_proposals`), `AGENT_IMPL_MAX_RETRIES` warning, rc=2 handling, memory-proposals harvest before wipe.
- §3.5 prompts: Task 8 ✔.
- §2.3 proposals (PR-1 half): Tasks 8, 9 ✔ (`/pal-memory` itself is PR 2).
- §3.7 tooling: Task 10 ✔. Design-doc §9.5 and README are PR 2/3.
- §4 tests: every listed case has a test above; the `run_claude` argv tests replace upstream's `test_phase_flags.bats`.
- Type consistency: `run_claude` 5-arg signature used identically in Tasks 5, 7 (via upstream file), 9; `STATUS_FAILURE_REASON` values used in tests match the strings set in Task 7 edits and Task 9; `_ledger_pr_summary` / `_ledger_outstanding_summary` / `LEDGER_FILE` names match upstream.
