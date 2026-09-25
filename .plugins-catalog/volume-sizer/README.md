# volume-sizer

After a deployment: measures every Docker volume through the Docker API (no root needed), lists volumes that no container uses, and shows the ten largest.

- **Category:** operations
- **Version:** 2.0.0
- **Hooks:** `post-deploy`
- **Tags:** volumes, disk, cleanup

## Install

Plugins page → Install, or `POST /plugins/catalog/volume-sizer/install`, then enable it.
Hooks receive the DCS context on stdin and run with the environment described in
[.plugins/README.md](../../.plugins/README.md); output and exit codes land in the plugin's execution log.
