# stack-analytics

Records every deployment and start with its outcome and container list to a bounded JSONL timeline in the plugin's state directory — an operational history you can query with jq.

- **Category:** monitoring
- **Version:** 2.0.0
- **Hooks:** `post-deploy`, `post-start`
- **Tags:** analytics, history, timeline

## Settings (`config` in plugin.json, editable from the Plugins page)

| Key | Default |
|-----|---------|
| `keep_events` | `5000` |

## Install

Plugins page → Install, or `POST /plugins/catalog/stack-analytics/install`, then enable it.
Hooks receive the DCS context on stdin and run with the environment described in
[.plugins/README.md](../../.plugins/README.md); output and exit codes land in the plugin's execution log.
