#!/bin/bash
# Build the sandbox-pal base image.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TAG="${1:-sandbox-pal:latest}"
BASE_IMAGE="${BASE_IMAGE:-ubuntu:24.04}"

cd "$REPO_ROOT"
docker build \
    --build-arg BASE_IMAGE="$BASE_IMAGE" \
    -f image/Dockerfile \
    -t "$TAG" \
    .
