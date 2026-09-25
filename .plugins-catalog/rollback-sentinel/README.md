# rollback-sentinel

Captures a restore point before every real deployment (compose file, container IDs, image digests, port mappings) and, when a deployment fails, prints the exact command that restores the previous state.

- **Category:** safety
- **Version:** 2.0.0
- **Hooks:** `post-deploy`, `pre-deploy`
- **Tags:** rollback, safety, deployment

## Settings (`config` in plugin.json, editable from the Plugins page)

| Key | Default |
|-----|---------|
| `keep` | `10` |

## Install

Plugins page → Install, or `POST /plugins/catalog/rollback-sentinel/install`, then enable it.
Hooks receive the DCS context on stdin and run with the environment described in
[.plugins/README.md](../../.plugins/README.md); output and exit codes land in the plugin's execution log.
