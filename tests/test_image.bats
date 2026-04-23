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
    fake_docker_set_image_exists claude-pal:latest
    run pal_image_exists
    assert_success
}

@test "pal_image_exists: returns failure when image is absent" {
    fake_docker_set_image_absent claude-pal:latest
    run pal_image_exists
    assert_failure
}

@test "pal_image_exists: uses PAL_WORKSPACE_IMAGE override" {
    fake_docker_set_image_exists claude-pal:v0.5.0
    PAL_WORKSPACE_IMAGE=claude-pal:v0.5.0 run pal_image_exists
    assert_success
}
