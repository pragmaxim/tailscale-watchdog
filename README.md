# tailscale-watchdog

A minute-cadence systemd watchdog that monitors Tailscale connectivity and automatically restarts `tailscaled` when reachability breaks. Designed for long-running servers where Tailscale must stay up unattended.

Works with both vanilla Tailscale (SaaS control plane) and self-hosted [headscale](https://github.com/juanfont/headscale).

## What it does

Every tick:

1. Checks that `tailscaled` is active and `tailscale status` responds within a timeout.
2. `curl`s a configured probe URL. If it fails, flushes the systemd-resolved DNS cache and retries.
3. If still unreachable, captures detailed diagnostics to the journal and invokes the recovery script.

The recovery script is **two-staged**:

1. **Soft** — `tailscale down` + `tailscale up` (with configurable `--login-server`, `--operator`, and other `up` flags). Re-establishes the connection without restarting the daemon. The reachability probe is repeated afterwards.
2. **Hard** — if soft recovery didn't restore reachability, falls back to `systemctl restart tailscaled`.

Recovery is **rate-limited**: by default, no more than 3 recovery invocations in any rolling 1-hour window. Beyond that, the watchdog still runs, logs, and dumps diagnostics, but stops hammering things.

## What it captures on failure

When a failure path is hit, the watchdog dumps a single `DIAG_START` / `DIAG_END` block to the journal containing:

- `tailscaled` service state, restart count, `tailscale0` link state and MTU
- Interfaces, routes, `/etc/resolv.conf`, full `resolvectl` config
- DNS reachability tested at **four layers** (see [How to read the diagnostics](#how-to-read-the-diagnostics))
- ICMP and `tailscale ping` to configured tailnet resolvers (direct vs DERP fallback)
- `tailscale netcheck` (DERP latencies, UDP path, NAT type)
- `tailscale debug prefs`, `timedatectl status`
- Last 5 minutes of `tailscaled` journal output

Slice a single failure event out of the journal with:

```bash
journalctl -u tailscale-watchdog | sed -n '/DIAG_START/,/DIAG_END/p'
```

# Install

Requires: `systemd`, `tailscale`, `curl`, `dig` (from `bind-utils` / `dnsutils`), `resolvectl` (from `systemd-resolved`), and `iproute2` (`ip`, `ss`).

```bash
git clone https://github.com/<you>/tailscale-watchdog.git
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

# Control plane URL. Used BOTH as the reachability probe (curled by the
# watchdog) AND as --login-server when the recovery script runs `tailscale up`.
# Default: https://controlplane.tailscale.com/ (Tailscale SaaS).
# For self-hosted headscale:
TAILSCALE_LOGIN_SERVER=https://headscale.example.com/

# Tailnet-internal DNS resolvers, space-separated. List these if your tailnet
# pushes custom DNS servers reachable only over the tunnel (e.g. internal
# Bind/CoreDNS/AD). The watchdog will probe each with dig, ICMP ping, and
# `tailscale ping` so you can localize tunnel vs DNS-daemon failures.
TAILNET_RESOLVERS="10.0.0.2 10.0.0.3"

# Optional. Non-root user permitted to manage tailscale (`tailscale up --operator=`).
TAILSCALE_OPERATOR=youruser
```

Full list of supported variables is in [`etc/default/tailscale-watchdog.example`](etc/default/tailscale-watchdog.example), including timeouts and rate-limit knobs.

After editing, you can validate the unit picks up the changes with:

```bash
sudo systemctl show tailscale-watchdog.service -p Environment
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

## How to read the diagnostics

The four-layer DNS probe is the fastest way to localize a root cause:

| Local proxy `100.100.100.100` | Tailnet resolvers `10.x` | Public DNS `1.1.1.1` | System resolver | Most likely cause |
|---|---|---|---|---|
| ✓ | ✓ | ✓ | ✗ | systemd-resolved isn't routing queries to `tailscale0` |
| ✓ | ✗ | ✓ | ✗ | Tailnet resolvers unreachable — tunnel or peer-host issue |
| ✗ | ✗ | ✓ | ✗ | `tailscaled` itself is wedged — its DNS proxy isn't answering |
| ✗ | ✗ | ✗ | ✗ | Underlay network down, not a tailscale problem |

Cross-check with the `tailscale ping` block:

- **direct** → working over the WireGuard UDP path
- **via DERP region X** → fell back to TCP relay; UDP/firewall path lost (much slower, frequent DNS timeouts)
- **timeout** → tunnel to that peer is fully broken

## Tuning

All defaults are conservative. Common adjustments:

- **Less aggressive recovery** — raise `RATE_LIMIT_WINDOW` or lower `RATE_LIMIT_MAX`.
- **Slower probe** — raise `CURL_TIMEOUT` or `STATUS_TIMEOUT` if you have a flaky upstream and don't want false triggers.
- **Different cadence** — edit `OnUnitActiveSec=` in `tailscale-watchdog.timer` (1 min by default).

## Uninstall

```bash
sudo systemctl disable --now tailscale-watchdog.timer
sudo rm /etc/systemd/system/tailscale-watchdog.{service,timer}
sudo rm /usr/local/bin/tailscale-{watchdog,recover}.sh
sudo rm -rf /var/lib/tailscale-watchdog
sudo rm /etc/default/tailscale-watchdog       # optional
sudo systemctl daemon-reload
```
