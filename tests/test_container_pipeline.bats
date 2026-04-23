#!/usr/bin/env bats
load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    IMAGE_TAG="sandbox-pal:test-pipeline-$RANDOM"
    STATUS_DIR="$(mktemp -d)"
    chmod 0777 "$STATUS_DIR"   # container runs as non-root agent user with different UID
}

teardown() {
    [ -n "${IMAGE_TAG:-}" ] && docker rmi -f "$IMAGE_TAG" 2>/dev/null || true
    [ -n "${STATUS_DIR:-}" ] && rm -rf "$STATUS_DIR"
}

# bats test_tags=integration
@test "full implement pipeline round-trips on smoketest issue" {
    [ -n "${PAL_TEST_REPO:-}" ]            || skip "set PAL_TEST_REPO=owner/repo"
    [ -n "${PAL_TEST_ISSUE:-}" ]           || skip "set PAL_TEST_ISSUE to the test issue number"
    [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]  || skip "set CLAUDE_CODE_OAUTH_TOKEN"
    [ -n "${GH_TOKEN:-}" ]                 || skip "set GH_TOKEN"
    TEST_REPO="$PAL_TEST_REPO"
    TEST_ISSUE="$PAL_TEST_ISSUE"

    "$REPO_ROOT/scripts/build-image.sh" "$IMAGE_TAG" > /dev/null 2>&1

    # Outer `timeout` bounds the whole run; `--cap-add=NET_ADMIN` needed for iptables.
    run timeout 1800 docker run --rm \
        --cap-add=NET_ADMIN \
        -e CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
        -e GH_TOKEN="$GH_TOKEN" \
        -e AGENT_TEST_COMMAND="${PAL_TEST_CMD:-}" \
        -v "$STATUS_DIR:/status" \
        "$IMAGE_TAG" implement "$TEST_REPO" "$TEST_ISSUE"
    assert_success

    assert [ -f "$STATUS_DIR/status.json" ]
    run jq -r '.outcome' "$STATUS_DIR/status.json"
    assert_output "success"

    run jq -r '.pr_url' "$STATUS_DIR/status.json"
    refute_output "null"
}
