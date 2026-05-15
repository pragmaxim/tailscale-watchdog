# tailscale-watchdog

A minute-cadence systemd watchdog that monitors tailnet and internet reachability, then automatically recovers `tailscaled` only when the tailnet path is broken but the public internet is still reachable. Designed for long-running servers where Tailscale must stay up unattended.

Works with both vanilla Tailscale (SaaS control plane) and self-hosted [headscale](https://github.com/juanfont/headscale).

## What it does

Every tick:

1. Checks that `tailscaled` is active and `tailscale status` responds within a timeout.
2. `curl`s one or more tailnet probe URLs (`TAILSCALE_PROBE_URLS`) and an internet probe URL (`INTERNET_PROBE_URL`). If either side fails, flushes the systemd-resolved DNS cache and retries the failed probes once.
3. If the tailnet probe still fails while the internet probe works, captures diagnostics and invokes the recovery script.
4. If the internet probe fails too, captures diagnostics but skips Tailscale recovery because the likely issue is underlay/upstream reachability.

The recovery script is **two-staged**:

1. **Soft** — `tailscale down` + `tailscale up` (with configurable `--login-server`, `--operator`, and other `up` flags). Re-establishes the connection without restarting the daemon. The tailnet reachability probe is repeated afterwards.
2. **Hard** — if soft recovery didn't restore reachability, falls back to `systemctl restart tailscaled`.

Recovery is **rate-limited**: by default, no more than 3 recovery invocations in any rolling 1-hour window. Beyond that, the watchdog still runs, logs, and dumps diagnostics, but stops hammering things. Internet-only or combined tailnet+internet failures do not invoke recovery.

Every run emits a compact summary line for grepping:

```text
RESULT tailnet=ok internet=ok recovery=none reason=ok
RESULT tailnet=fail internet=ok recovery=attempted reason=tailnet-probe-unreachable
```

## What it captures on failure

When a failure path is hit, the watchdog dumps a single `DIAG_START` / `DIAG_END` block to the journal containing:

- `tailscaled` service state, restart count, `tailscale0` link state and MTU
- Interfaces, routes, `/etc/resolv.conf`, full `resolvectl` config
- DNS reachability for both probe hosts tested at **four layers** (see [How to read the diagnostics](#how-to-read-the-diagnostics))
- ICMP and `tailscale ping` to configured tailnet resolvers (direct vs DERP fallback)
- `tailscale netcheck` (DERP latencies, UDP path, NAT type)
- `tailscale debug prefs`, `timedatectl status`
- Last 5 minutes of `tailscaled` journal output

Slice a single failure event out of the journal with:

```bash
journalctl -u tailscale-watchdog | sed -n '/DIAG_START/,/DIAG_END/p'
```

# Install

Requires: `systemd`, `tailscale`, `curl`, `dig` (from `bind-utils` / `dnsutils`), `resolvectl` (from `systemd-resolved`), `iproute2` (`ip`), and `ping` (usually from `iputils`).

```bash
git clone https://github.com/pragmaxim/tailscale-watchdog.git
cd tailscale-watchdog
sudo ./install.sh
```

`install.sh` is idempotent and:

- Copies `bin/*.sh` → `/usr/local/bin/`
- Copies `systemd/*` → `/etc/systemd/system/`
- Copies `etc/default/tailscale-watchdog.example` → `/etc/default/tailscale-watchdog`, **only if that file doesn't already exist** (it never overwrites your config)
- Runs `systemctl daemon-reload`

It does **not** enable the timer — that's a deliberate next step so you can edit config first.

# Howto

## 1. Configure

Edit `/etc/default/tailscale-watchdog`. This file is read by the systemd unit via `EnvironmentFile=`, so every variable set here is exported into the watchdog's environment on each run.

```sh
# /etc/default/tailscale-watchdog

# Required. One or more HTTP(S) URLs reachable only when the tailnet path is
# healthy, space-separated. If any tailnet probe succeeds, the tailnet is treated
# as healthy.
TAILSCALE_PROBE_URLS="http://100.64.0.10/health http://nas.tailnet.local/health"

# Public internet probe. If this fails too, the watchdog logs diagnostics but
# skips tailscaled recovery because the likely problem is outside Tailscale.
# Default: https://controlplane.tailscale.com/
INTERNET_PROBE_URL=https://controlplane.tailscale.com/

# Control plane URL used only as --login-server when recovery runs `tailscale up`.
# Set this for self-hosted headscale; omit it for Tailscale SaaS.
TAILSCALE_LOGIN_SERVER=https://headscale.example.com/

# Tailnet-internal DNS resolvers, space-separated. These are diagnostic targets
# used after failures, not the primary tailnet health probe.
TAILNET_RESOLVERS="10.0.0.2 10.0.0.3"

# Optional. Non-root user permitted to manage tailscale (`tailscale up --operator=`).
TAILSCALE_OPERATOR=youruser
```

Full list of supported variables is in [`etc/default/tailscale-watchdog.example`](etc/default/tailscale-watchdog.example), including timeouts and rate-limit knobs.

After editing, validate config, dependencies, service state, and probes without invoking recovery:

```bash
sudo tailscale-watchdog.sh --check-config
```

Then trigger a one-off service run and check its journal output:

```bash
sudo systemctl start tailscale-watchdog.service
sudo journalctl -u tailscale-watchdog.service -n 80 --no-pager
```

## 2. Enable

```bash
sudo systemctl enable --now tailscale-watchdog.timer
```

Verify:

```bash
systemctl list-timers tailscale-watchdog.timer    # next/last fire time
systemctl status tailscale-watchdog.service       # last run result
journalctl -u tailscale-watchdog.service -f       # follow output live
```

Trigger a one-off run on demand:

```bash
sudo systemctl start tailscale-watchdog.service
```

Run a no-recovery config check on demand:

```bash
sudo tailscale-watchdog.sh --check-config
```

## Diagnose recent activity

For a digest report instead of raw journal output, use the diagnose helper:

```bash
sudo tailscale-diagnose.sh                            # last hour (default)
sudo tailscale-diagnose.sh --since "today"
sudo tailscale-diagnose.sh --since "6 hours ago"
sudo tailscale-diagnose.sh --since "2026-05-15 09:00:00" --full
```

Needs `sudo` (or `systemd-journal` group membership) to read the unit's journal and the state file.

## How to read the diagnostics

The watchdog labels failure paths before recovery:

- `tailnet-probe-unreachable` — tailnet probe failed, internet probe worked, recovery is attempted.
- `internet-probe-unreachable` — tailnet probe worked, internet probe failed, recovery is skipped.
- `tailnet-and-internet-unreachable` — both probes failed, recovery is skipped as a likely underlay/upstream outage.

The `RESULT` line is the fastest way to scan outcomes:

```bash
journalctl -u tailscale-watchdog.service | grep 'RESULT '
```

The four-layer DNS probe is the fastest way to localize a root cause. Diagnostics run these checks for `TAILSCALE_PROBE_URLS` and `INTERNET_PROBE_URL` hostnames:

| Local proxy `100.100.100.100` | Tailnet resolvers `10.x` | Public DNS `1.1.1.1` | System resolver | Most likely cause |
|---|---|---|---|---|
| ✓ | ✓ | ✓ | ✗ | systemd-resolved isn't routing queries to `tailscale0` |
| ✓ | ✗ | ✓ | ✗ | Tailnet resolvers unreachable — tunnel or peer-host issue |
| ✗ | ✗ | ✓ | ✗ | `tailscaled` itself is wedged — its DNS proxy isn't answering |
| ✗ | ✗ | ✗ | ✗ | Underlay network down, not a tailscale problem |

Public DNS may intentionally fail for private tailnet-only probe names. In that case, compare the tailnet probe's Tailscale/local resolver results against the internet probe's public resolver results instead of treating every public-DNS miss as a fault.

Cross-check with the `tailscale ping` block:

- **direct** → working over the WireGuard UDP path
- **via DERP region X** → fell back to TCP relay; UDP/firewall path lost (much slower, frequent DNS timeouts)
- **timeout** → tunnel to that peer is fully broken

## Tuning

All defaults are conservative. Common adjustments:

- **Less aggressive recovery** — raise `RATE_LIMIT_WINDOW` or lower `RATE_LIMIT_MAX`.
- **Multiple tailnet probes** — set `TAILSCALE_PROBE_URLS` so one internal service outage does not look like a broken tailnet.
- **Slower probes** — raise `CURL_TIMEOUT` or `STATUS_TIMEOUT` if you have a flaky upstream and don't want false triggers.
- **Different internet check** — set `INTERNET_PROBE_URL` to another public endpoint if your environment blocks the default.
- **Different cadence** — edit `OnUnitActiveSec=` in `tailscale-watchdog.timer` (1 min by default).
