#!/bin/bash
# tailscale-watchdog: periodic reachability check + bounded auto-recovery.
# Output goes to stdout/stderr; the systemd unit captures it in the journal.

set -u

# Config (override via env, typically /etc/default/tailscale-watchdog).
: "${TAILSCALE_LOGIN_SERVER:=https://controlplane.tailscale.com/}"
: "${TAILNET_RESOLVERS:=}"
: "${TAILSCALE_SERVICE:=tailscaled}"
: "${RECOVERY_SCRIPT:=/usr/local/bin/tailscale-recover.sh}"
: "${RATE_LIMIT_WINDOW:=3600}"
: "${RATE_LIMIT_MAX:=3}"
: "${CURL_TIMEOUT:=5}"
: "${STATUS_TIMEOUT:=10}"
: "${DNS_FLUSH_WAIT:=2}"

# StateDirectory= in the systemd unit creates /var/lib/tailscale-watchdog and
# exports $STATE_DIRECTORY. Fall back to the conventional path for manual runs.
STATE_DIR="${STATE_DIRECTORY:-/var/lib/tailscale-watchdog}"
STATE_FILE="$STATE_DIR/recovery.attempts"

mkdir -p "$STATE_DIR"

# Hostname for DNS-resolution tests, derived from the probe URL.
PROBE_HOST="${TAILSCALE_LOGIN_SERVER#*://}"
PROBE_HOST="${PROBE_HOST%%/*}"
PROBE_HOST="${PROBE_HOST%%:*}"

if [ -z "$PROBE_HOST" ]; then
    echo "ERROR: could not extract hostname from TAILSCALE_LOGIN_SERVER=$TAILSCALE_LOGIN_SERVER"
    exit 2
fi

echo "=== Tailscale Watchdog $(date) ==="

prune_attempts() {
    local now cutoff tmp
    now=$(date +%s)
    cutoff=$((now - RATE_LIMIT_WINDOW))
    if [ ! -f "$STATE_FILE" ]; then
        echo 0
        return
    fi
    tmp=$(mktemp)
    awk -v c="$cutoff" '$1 >= c' "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"
    wc -l < "$STATE_FILE" | tr -d ' '
}

# Dump everything useful for post-mortem. Only called on failure paths.
# Marker lines let you slice a single event out of the journal:
#   journalctl -u tailscale-watchdog | sed -n '/DIAG_START/,/DIAG_END/p'
collect_diagnostics() {
    local reason="${1:-unknown}"
    echo "=== DIAG_START $(date +%s) reason=$reason ==="

    echo "--- $TAILSCALE_SERVICE service state ---"
    systemctl show "$TAILSCALE_SERVICE" --property=ActiveEnterTimestamp,ActiveState,SubState,MainPID,NRestarts 2>&1 || true

    echo "--- tailscale0 link ---"
    ip -d link show tailscale0 2>&1 || true

    echo "--- interfaces (brief) ---"
    ip -brief addr 2>&1 || true

    echo "--- ip route ---"
    ip route 2>&1 || true

    echo "--- /etc/resolv.conf ---"
    readlink -f /etc/resolv.conf 2>&1 || true
    cat /etc/resolv.conf 2>&1 || true

    echo "--- resolvectl on tailscale0 ---"
    resolvectl dns tailscale0 2>&1 || true
    resolvectl domain tailscale0 2>&1 || true

    echo "--- resolvectl status (full) ---"
    resolvectl status 2>&1 || true

    # Four-layer DNS probe — see README for how to read this.
    echo "--- DNS test: tailscale local proxy (100.100.100.100) ---"
    timeout 3 dig @100.100.100.100 "$PROBE_HOST" +time=2 +tries=1 +short 2>&1 || true
    if [ -n "$TAILNET_RESOLVERS" ]; then
        for r in $TAILNET_RESOLVERS; do
            echo "--- DNS test: tailnet resolver $r ---"
            timeout 3 dig "@$r" "$PROBE_HOST" +time=2 +tries=1 +short 2>&1 || true
        done
    fi
    echo "--- DNS test: public (1.1.1.1) ---"
    timeout 3 dig @1.1.1.1 "$PROBE_HOST" +time=2 +tries=1 +short 2>&1 || true
    echo "--- DNS test: system resolver ---"
    timeout 3 getent hosts "$PROBE_HOST" 2>&1 || true

    if [ -n "$TAILNET_RESOLVERS" ]; then
        for r in $TAILNET_RESOLVERS; do
            echo "--- ICMP ping $r ---"
            timeout 5 ping -c 2 -W 2 "$r" 2>&1 || true
            echo "--- tailscale ping $r (direct vs DERP) ---"
            timeout 6 tailscale ping --c=2 --timeout=2s "$r" 2>&1 || true
        done
    fi

    echo "--- tailscale netcheck ---"
    timeout 10 tailscale netcheck 2>&1 || true

    echo "--- tailscale debug prefs ---"
    timeout 3 tailscale debug prefs 2>&1 || true

    echo "--- $TAILSCALE_SERVICE recent logs ---"
    journalctl -u "$TAILSCALE_SERVICE" --since "5 min ago" --no-pager -n 100 2>&1 || true

    echo "--- timedatectl ---"
    timedatectl status 2>&1 || true

    echo "=== DIAG_END $(date +%s) ==="
}

run_recovery() {
    local count
    count=$(prune_attempts)
    if [ "$count" -ge "$RATE_LIMIT_MAX" ]; then
        echo "RATE-LIMITED: $count recovery attempts already in last $RATE_LIMIT_WINDOW s (max $RATE_LIMIT_MAX) — skipping"
        return 1
    fi
    echo "Recovery attempt $((count + 1))/$RATE_LIMIT_MAX within last $RATE_LIMIT_WINDOW s"
    date +%s >> "$STATE_FILE"
    "$RECOVERY_SCRIPT"
}

if ! systemctl is-active "$TAILSCALE_SERVICE" > /dev/null 2>&1; then
    echo "ERROR: $TAILSCALE_SERVICE is not running"
    timeout 5 systemctl status "$TAILSCALE_SERVICE" --no-pager -l || true
    collect_diagnostics "service-down"
    run_recovery
    exit 1
fi

if ! timeout "$STATUS_TIMEOUT" tailscale status --json > /dev/null 2>&1; then
    echo "ERROR: tailscale status check failed or timed out"
    collect_diagnostics "status-hang"
    run_recovery
    exit 1
fi

check_probe() {
    curl -s --max-time "$CURL_TIMEOUT" "$TAILSCALE_LOGIN_SERVER" > /dev/null 2>&1
}

if ! check_probe; then
    echo "WARNING: $TAILSCALE_LOGIN_SERVER unreachable, flushing DNS caches..."
    resolvectl flush-caches 2>/dev/null || true
    sleep "$DNS_FLUSH_WAIT"

    if check_probe; then
        echo "OK: $TAILSCALE_LOGIN_SERVER reachable after DNS flush"
    else
        echo "ERROR: $TAILSCALE_LOGIN_SERVER still unreachable after DNS flush"
        collect_diagnostics "probe-unreachable"
        run_recovery
        exit 1
    fi
fi

echo "=== Done ==="
