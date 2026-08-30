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
    # shellcheck disable=SC1091
    . "$LIB_DIR/rules-staging.sh"
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
