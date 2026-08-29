#!/usr/bin/env bats
load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

setup() {
    REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
}

# bats test_tags=integration
@test "full implement pipeline round-trips on smoketest issue" {
    [ -n "${PAL_TEST_REPO:-}" ]            || skip "set PAL_TEST_REPO=owner/repo"
    [ -n "${PAL_TEST_ISSUE:-}" ]           || skip "set PAL_TEST_ISSUE to the test issue number"
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx sandbox-pal-workspace \
        || skip "start and log in the sandbox-pal workspace first (/pal-setup, /pal-login)"
    [ -n "${GH_TOKEN:-}" ]                 || skip "set GH_TOKEN"
    TEST_REPO="$PAL_TEST_REPO"
    TEST_ISSUE="$PAL_TEST_ISSUE"

    RUN_ID="pipeline-test-$RANDOM"
    run timeout 1800 docker exec \
        -e GH_TOKEN="$GH_TOKEN" \
        -e RUN_ID="$RUN_ID" \
        -e AGENT_TEST_COMMAND="${PAL_TEST_CMD:-}" \
        sandbox-pal-workspace /opt/pal/run-pipeline.sh implement "$TEST_REPO" "$TEST_ISSUE"
    assert_success

    # /status inside the workspace is a bind-mount of the host runs dir.
    # shellcheck disable=SC1091
    . "$REPO_ROOT/lib/runs.sh"
    STATUS_DIR="$(pal_runs_dir)/$RUN_ID"
    assert [ -f "$STATUS_DIR/status.json" ]
    run jq -r '.outcome' "$STATUS_DIR/status.json"
    assert_output "success"
    run jq -r '.pr_url' "$STATUS_DIR/status.json"
    refute_output "null"
}
