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

@test "scaffold entrypoint writes status.json and exits 0" {
    "$REPO_ROOT/scripts/build-image.sh" "$IMAGE_TAG" > /dev/null 2>&1
    run docker run --rm \
        -v "$STATUS_DIR:/status" \
        "$IMAGE_TAG" implement owner/repo 42
    assert_success
    assert [ -f "$STATUS_DIR/status.json" ]
    run jq -r '.outcome' "$STATUS_DIR/status.json"
    assert_output "success"
}
