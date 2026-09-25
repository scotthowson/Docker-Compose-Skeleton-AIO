# container-notifier

Sends an alert when a deployment or start fails or leaves containers unhealthy — to DCS's ntfy channel automatically, and to a Slack/Discord/generic webhook when NOTIFY_WEBHOOK_URL is set in .env.

- **Category:** monitoring
- **Version:** 2.0.0
- **Hooks:** `post-deploy`, `post-start`
- **Tags:** notifications, webhook, alerts

## Needs (root `.env`)

- `NOTIFY_WEBHOOK_URL`

## Install

Plugins page → Install, or `POST /plugins/catalog/container-notifier/install`, then enable it.
Hooks receive the DCS context on stdin and run with the environment described in
[.plugins/README.md](../../.plugins/README.md); output and exit codes land in the plugin's execution log.
