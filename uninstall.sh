#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERR] This script must be run as root (use sudo)." >&2
    exit 1
fi

echo "[INFO] Stopping and removing slyber_turn service..."
systemctl stop slyber_turn 2>/dev/null || true
systemctl disable slyber_turn 2>/dev/null || true
rm -f /etc/systemd/system/slyber_turn.service
systemctl daemon-reload

rm -f /usr/local/bin/slyber_turn
rm -f /opt/slyber_turn/slyber_turn

if [ "${PURGE_DATA:-false}" = "true" ]; then
    rm -rf /opt/slyber_turn
    echo "[OK] Removed /opt/slyber_turn including configuration and telemetry."
else
    echo "[OK] Binary and systemd service removed. Config and telemetry preserved in /opt/slyber_turn (set PURGE_DATA=true to delete)."
fi