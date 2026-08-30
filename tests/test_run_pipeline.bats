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

@test "implement: staged .agent-data/rules edit is applied as a chore(agent) commit, counted, pushed, and listed in status.json" {
    # Seed a rules file on origin/main so stage_rules_files has something to stage.
    mkdir -p "$seed/.claude/rules"
    printf 'original rule\n' > "$seed/.claude/rules/x.md"
    git -C "$seed" add .claude/rules/x.md
    git -C "$seed" -c user.email=t@e -c user.name=t commit -q -m "add rules"
    git -C "$seed" push -q origin HEAD:main

    fake_claude_enqueue "$(_structured '{"action":"approved"}')"
    fake_claude_enqueue "$(_ok 'implemented')" \
        'echo x > x.txt; git add x.txt; git commit -q -m "feat: x"; test -f .agent-data/rules/x.md || exit 9; printf "edited rule\n" > .agent-data/rules/x.md'
    fake_claude_enqueue "$(_structured '{"action":"approved","verified_fixed":[],"reopened":[],"findings":[]}')"

    run "$PIPELINE" implement owner/repo 42
    assert_success

    S="$STATUS_DIR/status.json"
    run jq -r '.outcome' "$S"; assert_output "success"
    run jq -r '.commits | length' "$S"; assert_output "3"          # feat + ledger + rules
    run jq -c '.rules_applied' "$S"; assert_output '["x.md"]'
    run git -C "$ORIGIN" log --format=%s agent/issue-42
    assert_line --index 0 "chore(agent): apply staged rules updates — x.md"
    run git -C "$ORIGIN" show agent/issue-42:.claude/rules/x.md; assert_output "edited rule"
    run git -C "$ORIGIN" ls-tree -r --name-only agent/issue-42; refute_output --partial ".agent-data/rules"   # staged copies never land in git (ledger does, by design)
}

@test "implement: rules_applied is an empty array when the repo has no .claude/rules" {
    fake_claude_enqueue "$(_structured '{"action":"approved"}')"
    fake_claude_enqueue "$(_ok 'implemented')" 'echo x > x.txt; git add x.txt; git commit -q -m "feat: x"'
    fake_claude_enqueue "$(_structured '{"action":"approved","verified_fixed":[],"reopened":[],"findings":[]}')"
    run "$PIPELINE" implement owner/repo 42
    assert_success
    run jq -c '.rules_applied' "$STATUS_DIR/status.json"; assert_output '[]'
}
