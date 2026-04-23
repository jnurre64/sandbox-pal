# lib/image.sh
# shellcheck shell=bash
# Host-side helpers for the claude-pal container image.

: "${PAL_WORKSPACE_IMAGE:=claude-pal:latest}"

pal_image_exists() {
    docker image inspect "$PAL_WORKSPACE_IMAGE" >/dev/null 2>&1
}
