# auto-backup

Copies the compose file and .env of a stack before every update and deployment (never during dry runs), keeping the last ten so a bad change can always be rolled back by hand.

- **Category:** safety
- **Version:** 2.0.0
- **Hooks:** `pre-deploy`, `pre-update`
- **Tags:** backup, safety, rollback

## Settings (`config` in plugin.json, editable from the Plugins page)

| Key | Default |
|-----|---------|
| `keep` | `10` |

## Install

Plugins page → Install, or `POST /plugins/catalog/auto-backup/install`, then enable it.
Hooks receive the DCS context on stdin and run with the environment described in
[.plugins/README.md](../../.plugins/README.md); output and exit codes land in the plugin's execution log.
