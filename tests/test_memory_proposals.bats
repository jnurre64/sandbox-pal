#!/usr/bin/env bats
# shellcheck shell=bash
# lib/memory-proposals.sh: list / adopt / discard proposals harvested to
# <runs>/<run-id>/memory-proposals/ by run-pipeline.sh (PR 1).

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_DATA_HOME="$HOME/.local/share"
    mkdir -p "$HOME"
    # shellcheck source=../lib/runs.sh
    . "$REPO_ROOT/lib/runs.sh"
    # shellcheck source=../lib/memory-proposals.sh
    . "$REPO_ROOT/lib/memory-proposals.sh"
    RUN1="$(pal_run_dir run-1)"; RUN2="$(pal_run_dir run-2)"
    mkdir -p "$RUN1/memory-proposals" "$RUN2/memory-proposals" "$(pal_run_dir run-3)"
    _proposal "$RUN1/memory-proposals/build-trap.md" build-trap "bun test needs --bail"
    _proposal "$RUN1/memory-proposals/ci-quirk.md"   ci-quirk   "CI runs old shellcheck"
    _proposal "$RUN2/memory-proposals/other.md"      other      "from run 2"
    HOST_REPO=/home/me/repos/foo
    MEM_DIR="$HOME/.claude/projects/-home-me-repos-foo/memory"
}

_proposal() { # <path> <name> <description>
    printf -- '---\nname: %s\ndescription: %s\nmetadata:\n  type: project\n---\n\nbody of %s\n' "$2" "$3" "$2" > "$1"
}

@test "list: all runs, tab-separated, sorted by run then file; .triaged excluded" {
    mkdir -p "$RUN1/memory-proposals/.triaged"
    _proposal "$RUN1/memory-proposals/.triaged/done.md" done "already triaged"
    run pal_memory_proposals_list
    assert_success
    assert_line --index 0 "$(printf 'run-1\tbuild-trap.md\tbuild-trap — bun test needs --bail')"
    assert_line --index 1 "$(printf 'run-1\tci-quirk.md\tci-quirk — CI runs old shellcheck')"
    assert_line --index 2 "$(printf 'run-2\tother.md\tother — from run 2')"
    refute_output --partial "done"
}

@test "list: a single run; a run with none says so on stderr and exits 0" {
    run pal_memory_proposals_list run-2
    assert_success
    assert_output "$(printf 'run-2\tother.md\tother — from run 2')"
    run pal_memory_proposals_list run-3
    assert_success
    assert_output --partial "pal: no pending memory proposals"
}

@test "adopt: copies the file, creates MEMORY.md with the index line, moves the proposal to .triaged" {
    run pal_memory_proposal_adopt run-1 build-trap.md "$HOST_REPO"
    assert_success
    [ -f "$MEM_DIR/build-trap.md" ]
    run cat "$MEM_DIR/MEMORY.md"
    assert_line --index 0 "# Memory Index"
    assert_line "- [build-trap](build-trap.md) — bun test needs --bail"
    [ -f "$RUN1/memory-proposals/.triaged/build-trap.md" ]
    [ ! -f "$RUN1/memory-proposals/build-trap.md" ]
    # second adopt appends to the existing index, does not rewrite the header
    run pal_memory_proposal_adopt run-1 ci-quirk.md "$HOST_REPO"
    assert_success
    run grep -c '^# Memory Index' "$MEM_DIR/MEMORY.md"; assert_output "1"
    run grep -c '^- \[' "$MEM_DIR/MEMORY.md"; assert_output "2"
}

@test "adopt: refuses to overwrite an existing memory file and prints the diff" {
    mkdir -p "$MEM_DIR"
    printf -- '---\nname: build-trap\ndescription: old\nmetadata:\n  type: project\n---\n\nold body\n' > "$MEM_DIR/build-trap.md"
    run pal_memory_proposal_adopt run-1 build-trap.md "$HOST_REPO"
    assert_failure
    assert_output --partial "already exists"
    assert_output --partial "-old body"
    assert_output --partial "+body of build-trap"
    run cat "$MEM_DIR/build-trap.md"; assert_output --partial "old body"
    [ -f "$RUN1/memory-proposals/build-trap.md" ]      # still pending
}

@test "adopt: rejects missing name, name/filename mismatch, and a missing file — nothing written" {
    printf -- '---\ndescription: no name\n---\nbody\n' > "$RUN1/memory-proposals/noname.md"
    run pal_memory_proposal_adopt run-1 noname.md "$HOST_REPO"
    assert_failure; assert_output --partial "no 'name:'"
    _proposal "$RUN1/memory-proposals/wrong.md" right "mismatch"
    run pal_memory_proposal_adopt run-1 wrong.md "$HOST_REPO"
    assert_failure; assert_output --partial "does not match"
    run pal_memory_proposal_adopt run-1 ghost.md "$HOST_REPO"
    assert_failure; assert_output --partial "no such proposal"
    [ ! -d "$MEM_DIR" ]
}

@test "discard: moves to .triaged without touching host memory; missing file fails" {
    run pal_memory_proposal_discard run-1 ci-quirk.md
    assert_success
    [ -f "$RUN1/memory-proposals/.triaged/ci-quirk.md" ]
    [ ! -d "$MEM_DIR" ]
    run pal_memory_proposal_discard run-1 ci-quirk.md
    assert_failure
}
