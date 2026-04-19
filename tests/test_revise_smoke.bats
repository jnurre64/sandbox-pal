#!/usr/bin/env bats
load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

# This test requires a real PR with review feedback. Skips if envs missing.

setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    : "${PAL_TEST_REPO:?set PAL_TEST_REPO}"
    : "${PAL_TEST_PR_WITH_REVIEW:?set PAL_TEST_PR_WITH_REVIEW to a PR# with CHANGES_REQUESTED review}"
    : "${CLAUDE_CODE_OAUTH_TOKEN:?}"
    : "${GH_TOKEN:?}"
    IMAGE_TAG="claude-pal:test-revise-$RANDOM"
    STATUS_DIR="$(mktemp -d)"
}

teardown() {
    [ -n "${IMAGE_TAG:-}" ] && docker rmi -f "$IMAGE_TAG" 2>/dev/null || true
    [ -n "${STATUS_DIR:-}" ] && rm -rf "$STATUS_DIR"
}

@test "revise pipeline round-trips on smoketest PR" {
    "$REPO_ROOT/scripts/build-image.sh" "$IMAGE_TAG" > /dev/null 2>&1

    run docker run --rm \
        --cap-add=NET_ADMIN \
        -e CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
        -e GH_TOKEN="$GH_TOKEN" \
        -v "$STATUS_DIR:/status" \
        "$IMAGE_TAG" revise "$PAL_TEST_REPO" "$PAL_TEST_PR_WITH_REVIEW"
    assert_success

    run jq -r '.outcome' "$STATUS_DIR/status.json"
    assert_output "success"
}
