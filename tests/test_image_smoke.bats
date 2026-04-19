#!/usr/bin/env bats
load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    IMAGE_TAG="claude-pal:test-$RANDOM"
    STATUS_DIR="$(mktemp -d)"
    # Container runs as non-root "agent" user with a UID that usually
    # differs from the host's, so the bind-mounted status dir must be
    # writable by "other" for the entrypoint to write status.json/log.
    chmod 0777 "$STATUS_DIR"
}

teardown() {
    [ -n "${IMAGE_TAG:-}" ] && docker rmi -f "$IMAGE_TAG" 2>/dev/null || true
    [ -n "${STATUS_DIR:-}" ] && rm -rf "$STATUS_DIR"
}

@test "image builds from scratch" {
    run "$REPO_ROOT/scripts/build-image.sh" "$IMAGE_TAG"
    assert_success
}

# bats test_tags=integration
@test "scaffold entrypoint writes status.json and exits 0" {
    # Originally exercised the Phase 1.7 scaffold entrypoint, which just wrote
    # status.json and exited. Phase 2 replaced that scaffold with the real
    # pipeline (firewall + clone + Claude), so `implement owner/repo 42`
    # now performs a real run. That flow is covered end-to-end by
    # tests/test_container_pipeline.bats with proper creds and NET_ADMIN.
    [ -n "${PAL_TEST_REPO:-}" ]            || skip "superseded by test_container_pipeline.bats; needs PAL_TEST_REPO + creds + NET_ADMIN"
    [ -n "${PAL_TEST_ISSUE:-}" ]           || skip "set PAL_TEST_ISSUE"
    [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]  || skip "set CLAUDE_CODE_OAUTH_TOKEN"
    [ -n "${GH_TOKEN:-}" ]                 || skip "set GH_TOKEN"

    "$REPO_ROOT/scripts/build-image.sh" "$IMAGE_TAG" > /dev/null 2>&1
    run docker run --rm \
        --cap-add=NET_ADMIN \
        -e CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \
        -e GH_TOKEN="$GH_TOKEN" \
        -v "$STATUS_DIR:/status" \
        "$IMAGE_TAG" implement "$PAL_TEST_REPO" "$PAL_TEST_ISSUE"
    assert_success
    assert [ -f "$STATUS_DIR/status.json" ]
    run jq -r '.outcome' "$STATUS_DIR/status.json"
    assert_output "success"
}
