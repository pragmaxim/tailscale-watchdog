# tailscale-watchdog

A systemd watchdog for long-running Tailscale hosts. It checks tailnet and internet reachability every minute, then recovers `tailscaled` only when the tailnet path is broken but the public internet still works.

Works with Tailscale SaaS and self-hosted [headscale](https://github.com/juanfont/headscale).

## Behavior

- Checks `tailscaled` and `tailscale status`.
- Curls one or more tailnet-only probe URLs from `TAILSCALE_PROBE_URLS`.
- Curls a public internet probe from `INTERNET_PROBE_URL`.
- Retries failed probes once after flushing `systemd-resolved` DNS caches.
- Runs recovery only for tailnet failure with working internet.
- Skips recovery for internet-only or combined tailnet+internet failures.
- Rate-limits recovery attempts.
- Logs a compact `RESULT tailnet=... internet=... recovery=... reason=...` line each run.

Recovery is two-stage: `tailscale down` + `tailscale up`, then `systemctl restart tailscaled` if the tailnet probe still fails.

## Install

```bash
git clone https://github.com/pragmaxim/tailscale-watchdog.git
cd tailscale-watchdog
sudo ./install.sh
```

The installer guides setup: dependency checks, optional Tailscale install, config editing in your default editor, validation, and timer enablement.

The required config value is:

```sh
TAILSCALE_PROBE_URLS="http://100.64.0.10/health http://nas.tailnet.local/health"
```

Use URLs that are reachable only when the tailnet is healthy. If any URL succeeds, the tailnet is considered reachable.

## Operate

```bash
sudo tailscale-watchdog.sh --check-config
sudo tailscale-diagnose.sh
sudo journalctl -u tailscale-watchdog.service -f
```

Configuration lives in `/etc/default/tailscale-watchdog`. The full option list is documented in [`etc/default/tailscale-watchdog.example`](etc/default/tailscale-watchdog.example).
