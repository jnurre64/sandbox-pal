#!/usr/bin/env bash
# image/opt/pal/workspace-boot.sh
# shellcheck disable=SC1091  # Sourced lib files resolved at runtime
#
# One-shot boot for the workspace container. Programs the firewall once, runs
# the default-deny verification, then sleeps forever. `docker exec` is the
# per-run entry point.

set -euo pipefail

# Minimal log helper (firewall.sh calls `log`).
log() {
    printf '[%s] %s\n' "$(date -Iseconds)" "$*" >&2
}

. /opt/pal/lib/firewall.sh

echo "pal: programming firewall from /opt/pal/allowlist.yaml"
apply_firewall /opt/pal/allowlist.yaml

echo "pal: verifying default-deny (attempting to reach example.com)"
if curl --max-time 3 --silent --output /dev/null https://example.com; then
    echo "pal: FATAL: firewall verification failed - example.com reachable" >&2
    exit 1
fi
echo "pal: firewall verified (example.com unreachable as expected)"

echo "pal: workspace ready - sleeping forever, awaiting docker exec"
exec sleep infinity
