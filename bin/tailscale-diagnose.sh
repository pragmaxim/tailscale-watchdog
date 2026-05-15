#!/bin/bash
# tailscale-diagnose: summarize tailscale-watchdog activity over a time window.
#
# Usage:
#   sudo tailscale-diagnose.sh [--since "<spec>"] [--full]
# Examples:
#   sudo tailscale-diagnose.sh
#   sudo tailscale-diagnose.sh --since "today"
#   sudo tailscale-diagnose.sh --since "6 hours ago"
#   sudo tailscale-diagnose.sh --since "2026-05-15 09:00:00" --full

set -u

SINCE="1 hour ago"
FULL=0
UNIT=tailscale-watchdog.service
STATE_FILE="${STATE_DIRECTORY:-/var/lib/tailscale-watchdog}/recovery.attempts"

usage() {
    cat <<EOF
Usage: $0 [--since "<spec>"] [--full]

Reports on tailscale-watchdog activity over a time window.

Options:
  --since "<spec>"  journalctl --since spec. Default: "1 hour ago".
                    Examples: "today", "6 hours ago", "2026-05-15 09:00:00".
  --full            Append full DIAG_START..DIAG_END blocks for each failure.
  -h, --help        Show this help.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --since)    SINCE="$2"; shift 2 ;;
        --since=*)  SINCE="${1#--since=}"; shift ;;
        --full)     FULL=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
    esac
done

section() { printf '\n== %s ==\n' "$1"; }

# Need journal-read access (typically root or systemd-journal group).
if ! journalctl -u "$UNIT" -n 1 --no-pager >/dev/null 2>&1; then
    echo "ERROR: cannot read journal for $UNIT. Try: sudo $0 $*" >&2
    exit 1
fi

section "Service health"
printf 'Timer enabled: %s\n' "$(systemctl is-enabled tailscale-watchdog.timer 2>&1)"
printf 'Timer active:  %s\n' "$(systemctl is-active tailscale-watchdog.timer 2>&1)"
systemctl list-timers tailscale-watchdog.timer --no-pager 2>/dev/null | head -3
printf 'Last service result: %s\n' "$(systemctl show "$UNIT" -p Result --value 2>/dev/null)"
printf 'Last fire:           %s\n' "$(systemctl show "$UNIT" -p ActiveEnterTimestamp --value 2>/dev/null)"

section "Rate-limit state"
if [ -r "$STATE_FILE" ]; then
    count=$(wc -l < "$STATE_FILE" 2>/dev/null | tr -d ' ')
    printf 'Recoveries in active window: %s\n' "${count:-0}"
    if [ -n "${count:-}" ] && [ "$count" -gt 0 ]; then
        echo "Timestamps:"
        while read -r ts; do
            printf '  %s\n' "$(date -d "@$ts" -Iseconds 2>/dev/null || echo "$ts")"
        done < "$STATE_FILE"
    fi
elif [ -e "$STATE_FILE" ]; then
    echo "State file exists at $STATE_FILE but is not readable (try sudo)."
else
    echo "No state file at $STATE_FILE (no recoveries yet)."
fi

section "Activity (since: $SINCE)"
JOURNAL=$(journalctl -u "$UNIT" --since "$SINCE" --no-pager -o short-iso 2>/dev/null)
if [ -z "$JOURNAL" ]; then
    echo "No journal entries in this window."
    exit 0
fi

ticks=$(echo "$JOURNAL"      | grep -c '=== Tailscale Watchdog' || true)
done_ok=$(echo "$JOURNAL"    | grep -c '=== Done ===' || true)
dns_healed=$(echo "$JOURNAL" | grep -c 'reachable after DNS flush' || true)
soft_ok=$(echo "$JOURNAL"    | grep -c 'Recovery complete (soft)' || true)
hard_ok=$(echo "$JOURNAL"    | grep -c 'Recovery complete (hard)' || true)
degraded=$(echo "$JOURNAL"   | grep -c 'Recovery complete (degraded)' || true)
rate_lim=$(echo "$JOURNAL"   | grep -c 'RATE-LIMITED' || true)

printf 'Total ticks:         %5d\n' "$ticks"
printf 'Clean (Done):        %5d\n' "$done_ok"
printf 'DNS hiccups healed:  %5d\n' "$dns_healed"
printf 'Soft recoveries:     %5d\n' "$soft_ok"
printf 'Hard recoveries:     %5d\n' "$hard_ok"
printf 'Degraded outcomes:   %5d\n' "$degraded"
printf 'Rate-limit skips:    %5d\n' "$rate_lim"

section "Verdict"
if [ "$degraded" -gt 0 ] || [ "$rate_lim" -gt 0 ]; then
    echo "ATTENTION: watchdog could not restore connectivity in this window."
    echo "Investigate the DIAG blocks (rerun with --full, or extract from journal)."
elif [ "$hard_ok" -gt 0 ]; then
    echo "Daemon required full restart at least once. Soft recovery wasn't enough."
    echo "If this recurs, dig into tailscaled's own logs."
elif [ "$soft_ok" -gt 0 ]; then
    echo "Soft recovery (down/up) was applied. Review DIAG for the root cause."
elif [ "$dns_healed" -gt 0 ]; then
    echo "Only transient DNS hiccups, self-healed via cache flush. Usually nothing to do."
else
    echo "All clear. No failures in this window."
fi

section "Failure events"
events=$(echo "$JOURNAL" | awk '
    /=== Tailscale Watchdog/ {
        if (in_tick && reason != "") {
            printf "%s  reason=%-20s outcome=%s\n", ts, reason, (outcome=="" ? "(none)" : outcome)
        }
        ts = $1
        reason = ""
        outcome = ""
        in_tick = 1
        next
    }
    /reason=/ {
        if (match($0, /reason=[a-z-]+/)) {
            reason = substr($0, RSTART + 7, RLENGTH - 7)
        }
    }
    /Recovery complete \(soft\)/      { outcome = "soft" }
    /Recovery complete \(hard\)/      { outcome = "hard" }
    /Recovery complete \(degraded\)/  { outcome = "degraded" }
    /RATE-LIMITED/                    { outcome = "rate-limited" }
    END {
        if (in_tick && reason != "") {
            printf "%s  reason=%-20s outcome=%s\n", ts, reason, (outcome=="" ? "(none)" : outcome)
        }
    }
')
if [ -z "$events" ]; then
    echo "None in this window."
else
    echo "$events"
fi

if [ "$FULL" = "1" ]; then
    section "Full DIAG blocks"
    echo "$JOURNAL" | sed -n '/DIAG_START/,/DIAG_END/p'
fi
