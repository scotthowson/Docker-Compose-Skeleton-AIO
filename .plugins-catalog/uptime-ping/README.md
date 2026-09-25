# uptime-ping

Pings Healthchecks.io, Uptime Kuma or any webhook URL after a successful start (and the /fail endpoint after a failed one). Set UPTIME_PING_URL in .env.

- **Category:** monitoring
- **Version:** 2.0.0
- **Hooks:** `post-start`
- **Tags:** uptime, monitoring, webhook

## Needs (root `.env`)

- `UPTIME_PING_URL`
- `HEALTHCHECKS_PING_URL`

## Install

Plugins page → Install, or `POST /plugins/catalog/uptime-ping/install`, then enable it.
Hooks receive the DCS context on stdin and run with the environment described in
[.plugins/README.md](../../.plugins/README.md); output and exit codes land in the plugin's execution log.
