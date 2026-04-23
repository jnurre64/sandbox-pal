#!/usr/bin/env bats
# shellcheck shell=bash

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'test_helper/fake-docker.sh'

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
    fake_docker_setup
    # shellcheck source=../lib/image.sh
    . "$REPO_ROOT/lib/image.sh"
}

teardown() {
    fake_docker_teardown
}

@test "pal_image_exists: returns success when image is present" {
    fake_docker_set_image_exists sandbox-pal:latest
    run pal_image_exists
    assert_success
}

@test "pal_image_exists: returns failure when image is absent" {
    fake_docker_set_image_absent sandbox-pal:latest
    run pal_image_exists
    assert_failure
}

@test "pal_image_exists: uses PAL_WORKSPACE_IMAGE override" {
    fake_docker_set_image_exists sandbox-pal:v0.5.0
    PAL_WORKSPACE_IMAGE=sandbox-pal:v0.5.0 run pal_image_exists
    assert_success
}

@test "pal_image_build: invokes docker build with Dockerfile and plugin root as context" {
    run pal_image_build
    assert_success
    run grep -F -- "-f ${CLAUDE_PLUGIN_ROOT}/image/Dockerfile" "$FAKE_DOCKER_LOG"
    assert_success
    run grep -F -- "-t sandbox-pal:latest" "$FAKE_DOCKER_LOG"
    assert_success
    # Build context is the plugin root (trailing positional).
    run grep -F -- "${CLAUDE_PLUGIN_ROOT}" "$FAKE_DOCKER_LOG"
    assert_success
}

@test "pal_image_build: passes BASE_IMAGE build-arg (default ubuntu:24.04)" {
    run pal_image_build
    assert_success
    run grep -F -- "--build-arg BASE_IMAGE=ubuntu:24.04" "$FAKE_DOCKER_LOG"
    assert_success
}

@test "pal_image_build: respects BASE_IMAGE env override" {
    BASE_IMAGE=ubuntu:22.04 run pal_image_build
    assert_success
    run grep -F -- "--build-arg BASE_IMAGE=ubuntu:22.04" "$FAKE_DOCKER_LOG"
    assert_success
}

@test "pal_image_build: respects PAL_WORKSPACE_IMAGE tag override" {
    PAL_WORKSPACE_IMAGE=sandbox-pal:v0.5.0 run pal_image_build
    assert_success
    run grep -F -- "-t sandbox-pal:v0.5.0" "$FAKE_DOCKER_LOG"
    assert_success
}

@test "pal_image_ensure: builds when image is absent" {
    fake_docker_set_image_absent sandbox-pal:latest
    run pal_image_ensure
    assert_success
    run grep -F "build" "$FAKE_DOCKER_LOG"
    assert_success
}

@test "pal_image_ensure: does NOT build when image is already present" {
    fake_docker_set_image_exists sandbox-pal:latest
    run pal_image_ensure
    assert_success
    run grep -F "build" "$FAKE_DOCKER_LOG"
    assert_failure
}

@test "pal_image_ensure: prints progress note when building" {
    fake_docker_set_image_absent sandbox-pal:latest
    run pal_image_ensure
    assert_success
    assert_output --partial "pal: building sandbox-pal:latest"
}
