# cleanup-sweeper

After a stack stops: prunes dangling images (only untagged layers) and reports networks that no container uses any more, keeping the Docker host lean without manual work.

- **Category:** operations
- **Version:** 2.0.0
- **Hooks:** `post-stop`
- **Tags:** cleanup, images, networks

## Settings (`config` in plugin.json, editable from the Plugins page)

| Key | Default |
|-----|---------|
| `prune_images` | `true` |

## Install

Plugins page → Install, or `POST /plugins/catalog/cleanup-sweeper/install`, then enable it.
Hooks receive the DCS context on stdin and run with the environment described in
[.plugins/README.md](../../.plugins/README.md); output and exit codes land in the plugin's execution log.
