#!/usr/bin/env bats
# shellcheck shell=bash
#
# Presence/parse test for the /pal-login skill. The skill's runtime behaviour
# is an interactive `docker exec -it … claude /login`, which can't be usefully
# exercised under BATS — we only check that the skill file exists, has the
# expected frontmatter, and that its extracted bash block parses.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SKILL_FILE="$REPO_ROOT/skills/pal-login/SKILL.md"
}

@test "pal-login SKILL.md exists" {
    run test -f "$SKILL_FILE"
    assert_success
}

@test "pal-login SKILL.md has the expected frontmatter name" {
    run grep -Fxq "name: pal-login" "$SKILL_FILE"
    assert_success
}

@test "pal-login bash block parses under bash -n" {
    tmp="$(mktemp)"
    awk '
        /^```bash$/ { in_block=1; next }
        /^```$/     { if (in_block) { exit } }
        in_block    { print }
    ' "$SKILL_FILE" > "$tmp"
    run test -s "$tmp"
    assert_success
    run bash -n "$tmp"
    assert_success
    rm -f "$tmp"
}
