#!/bin/bash
# install.sh — install tailscale-watchdog scripts, systemd units, and example
# config to their conventional locations. Idempotent; safe to re-run.

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (try: sudo $0)" >&2
    exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR=/usr/local/bin
SYSTEMD_DIR=/etc/systemd/system
CONFIG_FILE=/etc/default/tailscale-watchdog
CONFIG_EXAMPLE="$REPO_DIR/etc/default/tailscale-watchdog.example"

echo "Installing scripts to $BIN_DIR..."
install -m 755 "$REPO_DIR/bin/tailscale-watchdog.sh" "$BIN_DIR/tailscale-watchdog.sh"
install -m 755 "$REPO_DIR/bin/tailscale-recover.sh"  "$BIN_DIR/tailscale-recover.sh"
install -m 755 "$REPO_DIR/bin/tailscale-diagnose.sh" "$BIN_DIR/tailscale-diagnose.sh"

echo "Installing systemd units to $SYSTEMD_DIR..."
install -m 644 "$REPO_DIR/systemd/tailscale-watchdog.service" "$SYSTEMD_DIR/tailscale-watchdog.service"
install -m 644 "$REPO_DIR/systemd/tailscale-watchdog.timer"   "$SYSTEMD_DIR/tailscale-watchdog.timer"

if [ ! -e "$CONFIG_FILE" ]; then
    echo "Installing example config to $CONFIG_FILE..."
    install -m 644 "$CONFIG_EXAMPLE" "$CONFIG_FILE"
else
    echo "$CONFIG_FILE already exists, leaving it alone."
    echo "Compare against $CONFIG_EXAMPLE to see any new options."
fi

systemctl daemon-reload

echo ""
echo "Install complete. Next steps:"
echo "  1. Edit $CONFIG_FILE (set TAILSCALE_PROBE_URLS, optionally INTERNET_PROBE_URL and TAILNET_RESOLVERS)."
echo "  2. Enable the timer:"
echo "       sudo systemctl enable --now tailscale-watchdog.timer"
echo "  3. Tail logs:"
echo "       journalctl -u tailscale-watchdog.service -f"
echo "  4. Trigger a manual run to test:"
echo "       sudo systemctl start tailscale-watchdog.service"
