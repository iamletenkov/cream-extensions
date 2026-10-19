#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/bisquite-conf"
conf_init edge-domain "$SCRIPT_DIR/knobs" --env
install -m 0644 "$SCRIPT_DIR/configure-edge.service" /etc/systemd/system/configure-edge.service
install -m 0644 "$SCRIPT_DIR/edge-worker.timer" /etc/systemd/system/edge-worker.timer
systemctl enable configure-edge.service
