# disk-watchdog

After every deployment and start: checks disk usage of the installation and every mounted filesystem, alerts above the configured percentage, records a usage sample and predicts from the trend when the data disk will be full.

- **Category:** monitoring
- **Version:** 2.0.0
- **Hooks:** `post-deploy`, `post-start`
- **Tags:** disk, monitoring, alerts

## Settings (`config` in plugin.json, editable from the Plugins page)

| Key | Default |
|-----|---------|
| `warn_percent` | `85` |

## Install

Plugins page → Install, or `POST /plugins/catalog/disk-watchdog/install`, then enable it.
Hooks receive the DCS context on stdin and run with the environment described in
[.plugins/README.md](../../.plugins/README.md); output and exit codes land in the plugin's execution log.
