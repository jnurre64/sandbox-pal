#!/usr/bin/env bats
load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

# Build the image once per file, share across tests. Cheap after the first
# build (Docker BuildKit caches layers); without this, tests 2 and 3 would
# reference an image that was only built in test 1 and then torn down.
setup_file() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
    IMAGE_TAG="sandbox-pal:test-$RANDOM"
    export IMAGE_TAG REPO_ROOT
    "$REPO_ROOT/scripts/build-image.sh" "$IMAGE_TAG" >/dev/null
}

teardown_file() {
    [ -n "${IMAGE_TAG:-}" ] && docker rmi -f "$IMAGE_TAG" >/dev/null 2>&1 || true
}

@test "image builds from scratch" {
    # setup_file already built it; assert presence.
    run docker image inspect "$IMAGE_TAG"
    assert_success
}

@test "image contains workspace-boot.sh and run-pipeline.sh" {
    run docker run --rm --entrypoint sh "$IMAGE_TAG" -c 'test -x /opt/pal/workspace-boot.sh && test -x /opt/pal/run-pipeline.sh'
    [ "$status" -eq 0 ]
}

@test "image default CMD is workspace-boot.sh" {
    run docker inspect --format '{{json .Config.Cmd}}' "$IMAGE_TAG"
    [ "$status" -eq 0 ]
    [[ "$output" == *"workspace-boot.sh"* ]]
}
