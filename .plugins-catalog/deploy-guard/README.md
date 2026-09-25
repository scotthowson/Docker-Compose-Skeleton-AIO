# deploy-guard

Logs every deployment with its outcome, checkpoints the running containers of a stack before an update, and verifies container health after a start (with a push notification when something is unhealthy).

- **Category:** safety
- **Version:** 2.0.0
- **Hooks:** `post-deploy`, `post-start`, `pre-update`
- **Tags:** safety, deployment, health

## Settings (`config` in plugin.json, editable from the Plugins page)

| Key | Default |
|-----|---------|
| `health_wait_seconds` | `20` |

## Install

Plugins page → Install, or `POST /plugins/catalog/deploy-guard/install`, then enable it.
Hooks receive the DCS context on stdin and run with the environment described in
[.plugins/README.md](../../.plugins/README.md); output and exit codes land in the plugin's execution log.
