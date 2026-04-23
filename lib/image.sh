# lib/image.sh
# shellcheck shell=bash
# Host-side helpers for the sandbox-pal container image.

: "${PAL_WORKSPACE_IMAGE:=sandbox-pal:latest}"

pal_image_exists() {
    docker image inspect "$PAL_WORKSPACE_IMAGE" >/dev/null 2>&1
}

pal_image_build() {
    local base_image="${BASE_IMAGE:-ubuntu:24.04}"
    docker build \
        --build-arg BASE_IMAGE="$base_image" \
        -f "${CLAUDE_PLUGIN_ROOT}/image/Dockerfile" \
        -t "$PAL_WORKSPACE_IMAGE" \
        "${CLAUDE_PLUGIN_ROOT}"
}

pal_image_ensure() {
    if pal_image_exists; then
        return 0
    fi
    echo "pal: building ${PAL_WORKSPACE_IMAGE}…" >&2
    pal_image_build
}
