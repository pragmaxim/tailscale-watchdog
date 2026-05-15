#!/bin/bash
# tailscale-recover: two-stage recovery.
#   1. Soft: `tailscale down` + `tailscale up` (re-establishes the connection
#      without restarting the daemon). Tests reachability after.
#   2. Hard: if soft didn't restore reachability, `systemctl restart tailscaled`.
# Output goes to stdout/stderr; the systemd journal captures it when invoked
# from the watchdog service.

set -u

# Pick up config when invoked standalone (when called by the watchdog, these are
# already inherited via the service unit's EnvironmentFile).
[ -r /etc/default/tailscale-watchdog ] && . /etc/default/tailscale-watchdog

: "${TAILSCALE_SERVICE:=tailscaled}"
: "${TAILSCALE_LOGIN_SERVER:=https://controlplane.tailscale.com/}"
: "${TAILSCALE_OPERATOR:=}"
: "${TAILSCALE_UP_FLAGS:=--accept-dns --accept-routes}"
: "${UP_TIMEOUT:=30}"
: "${POST_UP_WAIT:=10}"
: "${POST_RESTART_WAIT:=15}"
: "${CURL_TIMEOUT:=5}"

probe_reachable() {
    curl -s --max-time "$CURL_TIMEOUT" "$TAILSCALE_LOGIN_SERVER" > /dev/null 2>&1
}

build_up_args() {
    local args=($TAILSCALE_UP_FLAGS --login-server="$TAILSCALE_LOGIN_SERVER")
    [ -n "$TAILSCALE_OPERATOR" ] && args+=("--operator=$TAILSCALE_OPERATOR")
    echo "${args[@]}"
}

echo "=== Tailscale Recovery $(date) ==="

# --- Stage 1: soft recovery (down + up) ---
# Schedule the `up` in a backgrounded subshell so it fires even if `down`
# disconnects something upstream (e.g. an SSH session calling this by hand).
# Under systemd this is just a slight delay.
UP_ARGS=$(build_up_args)
echo "[soft] Scheduling 'tailscale up $UP_ARGS' in 5s..."
(
    sleep 5
    echo "[soft] Bringing tailscale up..."
    # shellcheck disable=SC2086
    timeout "$UP_TIMEOUT" tailscale up $UP_ARGS \
        || echo "[soft] WARNING: 'tailscale up' failed or timed out"
) &
UP_PID=$!

echo "[soft] Bringing tailscale down..."
tailscale down || echo "[soft] WARNING: 'tailscale down' returned non-zero"

wait "$UP_PID" || true
sleep "$POST_UP_WAIT"

if probe_reachable; then
    echo "[soft] $TAILSCALE_LOGIN_SERVER reachable after down/up."
    echo "=== Recovery complete (soft) ==="
    exit 0
fi

echo "[soft] $TAILSCALE_LOGIN_SERVER still unreachable after down/up."

# --- Stage 2: hard recovery (service restart) ---
echo "[hard] Restarting $TAILSCALE_SERVICE..."
systemctl restart "$TAILSCALE_SERVICE"
sleep "$POST_RESTART_WAIT"

if ! systemctl is-active "$TAILSCALE_SERVICE" > /dev/null 2>&1; then
    echo "ERROR: $TAILSCALE_SERVICE failed to restart"
    exit 1
fi
echo "[hard] $TAILSCALE_SERVICE is active."

if probe_reachable; then
    echo "[hard] $TAILSCALE_LOGIN_SERVER reachable after service restart."
    echo "=== Recovery complete (hard) ==="
    exit 0
fi

echo "WARNING: $TAILSCALE_LOGIN_SERVER still unreachable after service restart"
echo "=== Recovery complete (degraded) ==="
exit 0
