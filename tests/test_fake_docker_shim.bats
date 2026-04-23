#!/usr/bin/env bats
# shellcheck shell=bash

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'test_helper/fake-docker.sh'

setup() { fake_docker_setup; }
teardown() { fake_docker_teardown; }

@test "fake docker: 'image inspect' fails when image not registered" {
    run docker image inspect sandbox-pal:latest
    assert_failure
}

@test "fake docker: 'image inspect' succeeds after fake_docker_set_image_exists" {
    fake_docker_set_image_exists sandbox-pal:latest
    run docker image inspect sandbox-pal:latest
    assert_success
}

@test "fake docker: 'build' is recorded in FAKE_DOCKER_LOG" {
    run docker build -t sandbox-pal:latest -f some/Dockerfile .
    assert_success
    run grep -F "build -t sandbox-pal:latest" "$FAKE_DOCKER_LOG"
    assert_success
}

@test "fake docker: 'image inspect' handles slashed registry tags round-trip" {
    fake_docker_set_image_exists myregistry.io/org/image:latest
    run docker image inspect myregistry.io/org/image:latest
    assert_success
    fake_docker_set_image_absent myregistry.io/org/image:latest
    run docker image inspect myregistry.io/org/image:latest
    assert_failure
}
