#!/usr/bin/env bats
# shellcheck shell=bash
# lib/skills-sync.sh: opt-in, by-name sync of ~/.claude/skills/<name> into the
# workspace container. Default (PAL_SYNC_SKILLS empty) syncs nothing.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'test_helper/fake-docker.sh'

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME/.claude/skills/alpha" "$HOME/.claude/skills/beta"
    echo "# alpha" > "$HOME/.claude/skills/alpha/SKILL.md"
    echo "# beta"  > "$HOME/.claude/skills/beta/SKILL.md"
    fake_docker_setup
    fake_docker_set_running
    # shellcheck source=../lib/skills-sync.sh
    . "$REPO_ROOT/lib/skills-sync.sh"
}

teardown() { fake_docker_teardown; }

@test "default (PAL_SYNC_SKILLS empty) syncs nothing" {
    unset PAL_SYNC_SKILLS
    run pal_skills_sync_to_container
    assert_success
    run grep -c . "$FAKE_DOCKER_LOG"; assert_output "0"
    PAL_SYNC_SKILLS="" run pal_skills_sync_to_container
    assert_success
    run grep -c . "$FAKE_DOCKER_LOG"; assert_output "0"
}

@test "named skills are removed in the container then copied in, one docker cp per skill" {
    PAL_SYNC_SKILLS="alpha, beta" run pal_skills_sync_to_container
    assert_success
    run grep -E '^exec sandbox-pal-workspace rm -rf /home/agent/.claude/skills/alpha$' "$FAKE_DOCKER_LOG"; assert_success
    run grep -E '^exec sandbox-pal-workspace rm -rf /home/agent/.claude/skills/beta$'  "$FAKE_DOCKER_LOG"; assert_success
    run grep -E '^exec sandbox-pal-workspace mkdir -p /home/agent/.claude/skills$' "$FAKE_DOCKER_LOG"; assert_success
    run grep -cE '^cp .* sandbox-pal-workspace:/home/agent/.claude/skills/(alpha|beta)$' "$FAKE_DOCKER_LOG"; assert_output "2"
}

@test "a symlinked skill directory is dereferenced before copy" {
    mkdir -p "$BATS_TEST_TMPDIR/elsewhere/gamma"
    echo "# gamma" > "$BATS_TEST_TMPDIR/elsewhere/gamma/SKILL.md"
    ln -s "$BATS_TEST_TMPDIR/elsewhere/gamma" "$HOME/.claude/skills/gamma"
    # Make the shim record the staged source's SKILL.md content.
    cat > "$FAKE_DOCKER_DIR/docker" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_DOCKER_LOG"
if [ "$1" = cp ]; then
    src="${2%/.}"
    [ -L "$src" ] && echo "SYMLINK" >> "$FAKE_DOCKER_LOG"
    cat "$src/SKILL.md" >> "$FAKE_DOCKER_LOG"
fi
[ "$1" = ps ] && echo sandbox-pal-workspace
exit 0
SHIM
    PAL_SYNC_SKILLS=gamma run pal_skills_sync_to_container
    assert_success
    run grep -c '^SYMLINK$' "$FAKE_DOCKER_LOG"; assert_output "0"
    run grep -c '^# gamma$' "$FAKE_DOCKER_LOG"; assert_output "1"
}

@test "a missing skill name warns on stderr, is skipped, and does not fail the sync" {
    PAL_SYNC_SKILLS="alpha,nope" run pal_skills_sync_to_container
    assert_success
    assert_output --partial "pal: skill 'nope' not found under"
    run grep -c 'skills/nope' "$FAKE_DOCKER_LOG"; assert_output "0"
    run grep -cE '^cp .*skills/alpha$' "$FAKE_DOCKER_LOG"; assert_output "1"
}
