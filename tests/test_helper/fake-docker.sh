# tests/test_helper/fake-docker.sh
# shellcheck shell=bash
# Provide a `docker` shim on PATH that records invocations to a file.
# Tests can inspect FAKE_DOCKER_LOG and can set FAKE_DOCKER_STATE to
# control responses to `docker ps`, `docker inspect`, etc.

fake_docker_setup() {
    FAKE_DOCKER_DIR="$(mktemp -d)"
    FAKE_DOCKER_LOG="$FAKE_DOCKER_DIR/calls.log"
    FAKE_DOCKER_STATE="$FAKE_DOCKER_DIR/state"
    mkdir -p "$FAKE_DOCKER_STATE"
    : > "$FAKE_DOCKER_LOG"

    cat > "$FAKE_DOCKER_DIR/docker" <<'SHIM'
#!/usr/bin/env bash
set -u
echo "$*" >> "$FAKE_DOCKER_LOG"
case "$1" in
    ps)
        if [ -f "$FAKE_DOCKER_STATE/running" ]; then
            echo "sandbox-pal-workspace"
        fi
        ;;
    inspect)
        if [ -f "$FAKE_DOCKER_STATE/exists" ]; then
            # If caller requested just the status field, echo a plain word
            # rather than the full JSON blob.
            for arg in "$@"; do
                case "$arg" in
                    *State.Status*)
                        if [ -f "$FAKE_DOCKER_STATE/running" ]; then
                            echo "running"
                        else
                            echo "exited"
                        fi
                        exit 0
                        ;;
                esac
            done
            echo '{"State":{"Status":"running"}}'
            exit 0
        fi
        exit 1
        ;;
    image)
        # Handle `docker image inspect <tag>` — success only if the tag is
        # marked present via fake_docker_set_image_exists.
        if [ "${2:-}" = "inspect" ] && [ -n "${3:-}" ]; then
            safe_tag="${3//:/_}"
            safe_tag="${safe_tag//\//_}"
            if [ -f "$FAKE_DOCKER_STATE/image_${safe_tag}" ]; then
                echo '[{"Id":"fake"}]'
                exit 0
            fi
            exit 1
        fi
        # Any other `docker image <subcommand>` — default success.
        ;;
    build)
        # Already logged at top of shim; default success. Tests grep the log.
        ;;
    exec)
        # Last arg is usually the command; simulate success by default.
        if [ -f "$FAKE_DOCKER_STATE/exec_fails" ]; then
            exit 1
        fi
        ;;
    run)
        # Simulate the container now existing and running.
        : > "$FAKE_DOCKER_STATE/exists"
        : > "$FAKE_DOCKER_STATE/running"
        ;;
    start)
        : > "$FAKE_DOCKER_STATE/running"
        ;;
    stop)
        rm -f "$FAKE_DOCKER_STATE/running"
        ;;
    rm|cp|volume|pull)
        : # success
        ;;
    *)
        : # success
        ;;
esac
exit 0
SHIM
    chmod +x "$FAKE_DOCKER_DIR/docker"
    export PATH="$FAKE_DOCKER_DIR:$PATH"
    export FAKE_DOCKER_LOG FAKE_DOCKER_STATE
}

fake_docker_teardown() {
    rm -rf "$FAKE_DOCKER_DIR"
}

fake_docker_set_running() {
    : > "$FAKE_DOCKER_STATE/running"
    : > "$FAKE_DOCKER_STATE/exists"
}

fake_docker_set_stopped() {
    rm -f "$FAKE_DOCKER_STATE/running"
    : > "$FAKE_DOCKER_STATE/exists"
}

fake_docker_set_absent() {
    rm -f "$FAKE_DOCKER_STATE/running" "$FAKE_DOCKER_STATE/exists"
}

fake_docker_set_image_exists() {
    local tag="${1:-sandbox-pal:latest}"
    local safe_tag="${tag//:/_}"
    safe_tag="${safe_tag//\//_}"
    : > "$FAKE_DOCKER_STATE/image_${safe_tag}"
}

fake_docker_set_image_absent() {
    local tag="${1:-sandbox-pal:latest}"
    local safe_tag="${tag//:/_}"
    safe_tag="${safe_tag//\//_}"
    rm -f "$FAKE_DOCKER_STATE/image_${safe_tag}"
}
