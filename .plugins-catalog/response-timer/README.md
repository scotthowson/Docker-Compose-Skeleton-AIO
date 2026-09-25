# response-timer

After a deployment: measures the HTTP response time of every port the stack publishes on the host (within a 20-second budget), keeps a baseline per service and flags anything slower than the configured limit.

- **Category:** monitoring
- **Version:** 2.0.0
- **Hooks:** `post-deploy`
- **Tags:** performance, http, monitoring

## Settings (`config` in plugin.json, editable from the Plugins page)

| Key | Default |
|-----|---------|
| `slow_ms` | `5000` |

## Install

Plugins page → Install, or `POST /plugins/catalog/response-timer/install`, then enable it.
Hooks receive the DCS context on stdin and run with the environment described in
[.plugins/README.md](../../.plugins/README.md); output and exit codes land in the plugin's execution log.
