#!/bin/bash
# tailscale-watchdog: periodic reachability check + bounded auto-recovery.
# Output goes to stdout/stderr; the systemd unit captures it in the journal.

set -u

CONFIG_FILE=/etc/default/tailscale-watchdog
CHECK_CONFIG=0

usage() {
    cat <<EOF
Usage: $0 [--check-config]

Options:
  --check-config  Validate config, dependencies, service state, and probes.
                  Never invokes recovery.
  -h, --help      Show this help.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --check-config) CHECK_CONFIG=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# Pick up config for standalone validation. Under systemd these values are
# already supplied by EnvironmentFile= on normal watchdog runs.
[ "$CHECK_CONFIG" = "1" ] && [ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"

# Config (override via env, typically /etc/default/tailscale-watchdog).
: "${TAILSCALE_LOGIN_SERVER:=https://controlplane.tailscale.com/}"
: "${TAILSCALE_PROBE_URLS:=}"
: "${INTERNET_PROBE_URL:=https://controlplane.tailscale.com/}"
: "${TAILNET_RESOLVERS:=}"
: "${TAILSCALE_SERVICE:=tailscaled}"
: "${RECOVERY_SCRIPT:=/usr/local/bin/tailscale-recover.sh}"
: "${RATE_LIMIT_WINDOW:=3600}"
: "${RATE_LIMIT_MAX:=3}"
: "${CURL_TIMEOUT:=5}"
: "${STATUS_TIMEOUT:=10}"
: "${DNS_FLUSH_WAIT:=2}"

TAILSCALE_PROBE_URL_LIST=()
TAILSCALE_PROBE_HOST_LIST=()
INTERNET_PROBE_HOST=
RECOVERY_ACTION=none

extract_host() {
    local url="$1"
    local host
    host="${url#*://}"
    host="${host%%/*}"
    host="${host%%:*}"
    echo "$host"
}

add_tailnet_probe_url() {
    local url="$1"
    [ -n "$url" ] && TAILSCALE_PROBE_URL_LIST+=("$url")
}

build_tailnet_probe_list() {
    local url
    TAILSCALE_PROBE_URL_LIST=()

    for url in $TAILSCALE_PROBE_URLS; do
        add_tailnet_probe_url "$url"
    done
}

validate_config() {
    local url host
    build_tailnet_probe_list

    if [ "${#TAILSCALE_PROBE_URL_LIST[@]}" -eq 0 ]; then
        echo "CONFIG ERROR: TAILSCALE_PROBE_URLS must be set to at least one tailnet-reachable URL"
        return 2
    fi

    TAILSCALE_PROBE_HOST_LIST=()
    for url in "${TAILSCALE_PROBE_URL_LIST[@]}"; do
        host="$(extract_host "$url")"
        if [ -z "$host" ]; then
            echo "CONFIG ERROR: could not extract hostname from tailnet probe URL: $url"
            return 2
        fi
        TAILSCALE_PROBE_HOST_LIST+=("$host")
    done

    INTERNET_PROBE_HOST="$(extract_host "$INTERNET_PROBE_URL")"
    if [ -z "$INTERNET_PROBE_HOST" ]; then
        echo "CONFIG ERROR: could not extract hostname from INTERNET_PROBE_URL=$INTERNET_PROBE_URL"
        return 2
    fi

    return 0
}

check_dependencies() {
    local verbose="${1:-0}"
    local missing=0
    local cmd
    local commands=(
        systemctl tailscale curl dig resolvectl ip ping journalctl timedatectl
        timeout getent
    )

    for cmd in "${commands[@]}"; do
        if command -v "$cmd" > /dev/null 2>&1; then
            [ "$verbose" = "1" ] && echo "OK dependency: $cmd"
        else
            echo "MISSING dependency: $cmd"
            missing=1
        fi
    done

    return "$missing"
}

# StateDirectory= in the systemd unit creates /var/lib/tailscale-watchdog and
# exports $STATE_DIRECTORY. Fall back to the conventional path for manual runs.
STATE_DIR="${STATE_DIRECTORY:-/var/lib/tailscale-watchdog}"
STATE_FILE="$STATE_DIR/recovery.attempts"

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
    local host
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

    for host in "${TAILSCALE_PROBE_HOST_LIST[@]}"; do
        run_dns_diagnostics "tailnet probe" "$host"
    done
    run_dns_diagnostics "internet probe" "$INTERNET_PROBE_HOST"

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

run_dns_diagnostics() {
    local label="$1"
    local host="$2"

    # Four-layer DNS probe - see README for how to read this.
    echo "--- DNS test: $label via tailscale local proxy (100.100.100.100): $host ---"
    timeout 3 dig @100.100.100.100 "$host" +time=2 +tries=1 +short 2>&1 || true
    if [ -n "$TAILNET_RESOLVERS" ]; then
        for r in $TAILNET_RESOLVERS; do
            echo "--- DNS test: $label via tailnet resolver $r: $host ---"
            timeout 3 dig "@$r" "$host" +time=2 +tries=1 +short 2>&1 || true
        done
    fi
    echo "--- DNS test: $label via public DNS (1.1.1.1): $host ---"
    timeout 3 dig @1.1.1.1 "$host" +time=2 +tries=1 +short 2>&1 || true
    echo "--- DNS test: $label via system resolver: $host ---"
    timeout 3 getent hosts "$host" 2>&1 || true
}

run_recovery() {
    local count
    mkdir -p "$STATE_DIR"
    count=$(prune_attempts)
    if [ "$count" -ge "$RATE_LIMIT_MAX" ]; then
        RECOVERY_ACTION=rate-limited
        echo "RATE-LIMITED: $count recovery attempts already in last $RATE_LIMIT_WINDOW s (max $RATE_LIMIT_MAX) — skipping"
        return 1
    fi
    echo "Recovery attempt $((count + 1))/$RATE_LIMIT_MAX within last $RATE_LIMIT_WINDOW s"
    RECOVERY_ACTION=attempted
    date +%s >> "$STATE_FILE"
    "$RECOVERY_SCRIPT"
}

check_url() {
    local url="$1"
    curl -s --max-time "$CURL_TIMEOUT" "$url" > /dev/null 2>&1
}

check_tailnet_probes() {
    local url
    local reachable=0

    for url in "${TAILSCALE_PROBE_URL_LIST[@]}"; do
        if check_url "$url"; then
            echo "OK: tailnet probe reachable: $url"
            reachable=1
        else
            echo "WARNING: tailnet probe unreachable: $url"
        fi
    done

    [ "$reachable" -eq 1 ]
}

check_internet_probe() {
    if check_url "$INTERNET_PROBE_URL"; then
        echo "OK: internet probe reachable: $INTERNET_PROBE_URL"
        return 0
    fi

    echo "WARNING: internet probe unreachable: $INTERNET_PROBE_URL"
    return 1
}

status_word() {
    local reachable="$1"
    if [ "$reachable" -eq 1 ]; then
        echo ok
    else
        echo fail
    fi
}

emit_result() {
    local tailnet="$1"
    local internet="$2"
    local recovery="$3"
    local reason="$4"
    echo "RESULT tailnet=$tailnet internet=$internet recovery=$recovery reason=$reason"
}

INTERNET_RECOVERY_STATUS=unknown

internet_probe_allows_recovery() {
    if check_url "$INTERNET_PROBE_URL"; then
        INTERNET_RECOVERY_STATUS=ok
        return 0
    fi

    echo "WARNING: internet probe unreachable while considering recovery, flushing DNS caches..."
    resolvectl flush-caches 2>/dev/null || true
    sleep "$DNS_FLUSH_WAIT"

    if check_url "$INTERNET_PROBE_URL"; then
        echo "OK: internet probe reachable after DNS flush"
        INTERNET_RECOVERY_STATUS=ok
        return 0
    fi

    echo "ERROR: internet probe still unreachable after DNS flush"
    INTERNET_RECOVERY_STATUS=fail
    return 1
}

run_recovery_if_internet_reachable() {
    if internet_probe_allows_recovery; then
        run_recovery
    else
        RECOVERY_ACTION=skipped
        echo "Recovery skipped: internet probe unreachable; likely underlay outage"
    fi
}

run_check_config() {
    local exit_code=0
    local tailnet_reachable=0
    local internet_reachable=0
    local url

    echo "=== Tailscale Watchdog Config Check $(date) ==="
    echo "Config file: $CONFIG_FILE"
    echo "Tailscale service: $TAILSCALE_SERVICE"
    echo "Login server: $TAILSCALE_LOGIN_SERVER"
    echo "Internet probe: $INTERNET_PROBE_URL"
    echo "Tailnet probes:"
    for url in "${TAILSCALE_PROBE_URL_LIST[@]}"; do
        echo "  $url"
    done

    if systemctl is-active "$TAILSCALE_SERVICE" > /dev/null 2>&1; then
        echo "OK: $TAILSCALE_SERVICE is active"
    else
        echo "ERROR: $TAILSCALE_SERVICE is not active"
        exit_code=1
    fi

    if timeout "$STATUS_TIMEOUT" tailscale status --json > /dev/null 2>&1; then
        echo "OK: tailscale status responded"
    else
        echo "ERROR: tailscale status check failed or timed out"
        exit_code=1
    fi

    if check_tailnet_probes; then
        tailnet_reachable=1
    else
        exit_code=1
    fi

    if check_internet_probe; then
        internet_reachable=1
    else
        exit_code=1
    fi

    emit_result "$(status_word "$tailnet_reachable")" "$(status_word "$internet_reachable")" "none" "check-config"
    exit "$exit_code"
}

if ! validate_config; then
    exit 2
fi

if ! check_dependencies "$CHECK_CONFIG"; then
    exit 2
fi

if [ "$CHECK_CONFIG" = "1" ]; then
    run_check_config
fi

echo "=== Tailscale Watchdog $(date) ==="

if ! systemctl is-active "$TAILSCALE_SERVICE" > /dev/null 2>&1; then
    echo "ERROR: $TAILSCALE_SERVICE is not running"
    timeout 5 systemctl status "$TAILSCALE_SERVICE" --no-pager -l || true
    collect_diagnostics "service-down"
    run_recovery_if_internet_reachable
    emit_result "unknown" "$INTERNET_RECOVERY_STATUS" "$RECOVERY_ACTION" "service-down"
    exit 1
fi

if ! timeout "$STATUS_TIMEOUT" tailscale status --json > /dev/null 2>&1; then
    echo "ERROR: tailscale status check failed or timed out"
    collect_diagnostics "status-hang"
    run_recovery_if_internet_reachable
    emit_result "unknown" "$INTERNET_RECOVERY_STATUS" "$RECOVERY_ACTION" "status-hang"
    exit 1
fi

tailnet_reachable=0
internet_reachable=0

if check_tailnet_probes; then
    tailnet_reachable=1
fi

if check_internet_probe; then
    internet_reachable=1
fi

if [ "$tailnet_reachable" -eq 0 ] || [ "$internet_reachable" -eq 0 ]; then
    echo "WARNING: one or more probes unreachable, flushing DNS caches..."
    resolvectl flush-caches 2>/dev/null || true
    sleep "$DNS_FLUSH_WAIT"

    if [ "$tailnet_reachable" -eq 0 ]; then
        if check_tailnet_probes; then
            echo "OK: at least one tailnet probe reachable after DNS flush"
            tailnet_reachable=1
        else
            echo "ERROR: all tailnet probes still unreachable after DNS flush"
        fi
    fi

    if [ "$internet_reachable" -eq 0 ]; then
        if check_internet_probe; then
            echo "OK: internet probe reachable after DNS flush"
            internet_reachable=1
        else
            echo "ERROR: internet probe still unreachable after DNS flush"
        fi
    fi
fi

if [ "$tailnet_reachable" -eq 1 ] && [ "$internet_reachable" -eq 1 ]; then
    emit_result "ok" "ok" "none" "ok"
    echo "=== Done ==="
    exit 0
fi

if [ "$tailnet_reachable" -eq 0 ] && [ "$internet_reachable" -eq 1 ]; then
    collect_diagnostics "tailnet-probe-unreachable"
    run_recovery
    emit_result "fail" "ok" "$RECOVERY_ACTION" "tailnet-probe-unreachable"
    exit 1
fi

if [ "$tailnet_reachable" -eq 0 ] && [ "$internet_reachable" -eq 0 ]; then
    collect_diagnostics "tailnet-and-internet-unreachable"
    echo "Recovery skipped: internet probe unreachable; likely underlay outage"
    emit_result "fail" "fail" "skipped" "tailnet-and-internet-unreachable"
    exit 1
fi

collect_diagnostics "internet-probe-unreachable"
echo "Recovery skipped: tailnet probe is reachable; tailscaled recovery is not indicated"
emit_result "ok" "fail" "skipped" "internet-probe-unreachable"
exit 1
