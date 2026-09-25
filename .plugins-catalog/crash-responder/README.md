# crash-responder

After a start: finds containers of the stack that exited with an error, saves their last 50 log lines, and optionally restarts them — at most three times per hour per container.

- **Category:** operations
- **Version:** 2.0.0
- **Hooks:** `post-start`
- **Tags:** crash, recovery, logs

## Settings (`config` in plugin.json, editable from the Plugins page)

| Key | Default |
|-----|---------|
| `auto_restart` | `true` |
| `max_restarts_per_hour` | `3` |
| `log_lines` | `50` |

## Install

Plugins page → Install, or `POST /plugins/catalog/crash-responder/install`, then enable it.
Hooks receive the DCS context on stdin and run with the environment described in
[.plugins/README.md](../../.plugins/README.md); output and exit codes land in the plugin's execution log.
