#!/usr/bin/env bats
# shellcheck shell=bash
# Smoke test for the /pal-memory skill: extracts the bash block from SKILL.md
# and drives list / adopt / discard against a temp HOME and runs dir.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
    TMPHOME="$(mktemp -d)"
    export HOME="$TMPHOME"
    export XDG_CONFIG_HOME="$TMPHOME/.config"
    export XDG_DATA_HOME="$TMPHOME/.local/share"
    export GH_TOKEN=github_pat_fake

    SKILL_SCRIPT="$TMPHOME/pal-memory.sh"
    awk '
        /^```bash$/ { in_block=1; next }
        /^```$/     { if (in_block) { exit } }
        in_block    { print }
    ' "$REPO_ROOT/skills/pal-memory/SKILL.md" > "$SKILL_SCRIPT"

    # A host repo (cwd) so the skill can resolve the memory slug.
    REPO="$TMPHOME/repo"; mkdir -p "$REPO"; git -C "$REPO" init -q
    RUN_DIR="$XDG_DATA_HOME/sandbox-pal/runs/run-9/memory-proposals"; mkdir -p "$RUN_DIR"
    printf -- '---\nname: trap\ndescription: a trap\nmetadata:\n  type: project\n---\nbody\n' > "$RUN_DIR/trap.md"
    printf -- '---\nname: junk\ndescription: junk\nmetadata:\n  type: project\n---\nbody\n' > "$RUN_DIR/junk.md"
    cd "$REPO"
}

teardown() { rm -rf "$TMPHOME"; }

@test "pal-memory SKILL.md contains a bash block that sources memory-proposals.sh" {
    run test -s "$SKILL_SCRIPT"; assert_success
    run grep -Fq 'lib/memory-proposals.sh' "$SKILL_SCRIPT"; assert_success
}

@test "pal-memory (no args) lists pending proposals across runs" {
    run bash "$SKILL_SCRIPT"
    assert_success
    assert_output --partial "run-9"
    assert_output --partial "trap — a trap"
    assert_output --partial "junk — junk"
}

@test "pal-memory <run-id> --adopt <file> writes host memory for the cwd repo" {
    run bash "$SKILL_SCRIPT" run-9 --adopt trap.md
    assert_success
    local slug="${REPO//\//-}"
    [ -f "$HOME/.claude/projects/$slug/memory/trap.md" ]
    run grep -c 'trap.md' "$HOME/.claude/projects/$slug/memory/MEMORY.md"; assert_output "1"
    run bash "$SKILL_SCRIPT" run-9
    refute_output --partial "trap — a trap"
}

@test "pal-memory <run-id> --discard <file> moves it aside" {
    run bash "$SKILL_SCRIPT" run-9 --discard junk.md
    assert_success
    [ -f "$RUN_DIR/.triaged/junk.md" ]
    [ ! -d "$HOME/.claude/projects" ]
}

@test "pal-memory --adopt without a run-id, or an unknown flag, prints usage and fails" {
    run bash "$SKILL_SCRIPT" --adopt trap.md
    assert_failure; assert_output --partial "usage: pal-memory"
    run bash "$SKILL_SCRIPT" run-9 --bogus x
    assert_failure; assert_output --partial "usage: pal-memory"
}
