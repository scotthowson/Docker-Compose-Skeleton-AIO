# log-archiver

Before a stack stops: saves the last 500 timestamped log lines of each of its containers under the plugin state directory, so debugging context survives the containers.

- **Category:** operations
- **Version:** 2.0.0
- **Hooks:** `pre-stop`
- **Tags:** logs, archive, debugging

## Settings (`config` in plugin.json, editable from the Plugins page)

| Key | Default |
|-----|---------|
| `lines` | `500` |
| `keep_runs` | `10` |

## Install

Plugins page → Install, or `POST /plugins/catalog/log-archiver/install`, then enable it.
Hooks receive the DCS context on stdin and run with the environment described in
[.plugins/README.md](../../.plugins/README.md); output and exit codes land in the plugin's execution log.
