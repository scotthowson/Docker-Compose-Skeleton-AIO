# image-freshness

After a deployment: reports how old each image of the stack is (from the image metadata), warns above the configured age, and flags services on a :latest tag without a pinned digest.

- **Category:** safety
- **Version:** 2.0.0
- **Hooks:** `post-deploy`
- **Tags:** images, updates, safety

## Settings (`config` in plugin.json, editable from the Plugins page)

| Key | Default |
|-----|---------|
| `max_age_days` | `30` |

## Install

Plugins page → Install, or `POST /plugins/catalog/image-freshness/install`, then enable it.
Hooks receive the DCS context on stdin and run with the environment described in
[.plugins/README.md](../../.plugins/README.md); output and exit codes land in the plugin's execution log.
