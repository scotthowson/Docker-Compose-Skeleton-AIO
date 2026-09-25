# resource-monitor

After a deployment or start: lists the containers of the stack that run without a memory limit or CPU quota, so resource hogs are found before they starve the host.

- **Category:** monitoring
- **Version:** 2.0.0
- **Hooks:** `post-deploy`, `post-start`
- **Tags:** resources, limits, monitoring

## Install

Plugins page → Install, or `POST /plugins/catalog/resource-monitor/install`, then enable it.
Hooks receive the DCS context on stdin and run with the environment described in
[.plugins/README.md](../../.plugins/README.md); output and exit codes land in the plugin's execution log.
