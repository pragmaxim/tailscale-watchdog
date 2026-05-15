#!/bin/bash
# uninstall.sh — uninstall tailscale-watchdog scripts, systemd units

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (try: sudo $0)" >&2
    exit 1
fi

systemctl disable --now tailscale-watchdog.timer
rm /etc/systemd/system/tailscale-watchdog.{service,timer}
rm /usr/local/bin/tailscale-{watchdog,recover,diagnose}.sh
rm -rf /var/lib/tailscale-watchdog
rm /etc/default/tailscale-watchdog       # optional
systemctl daemon-reload
