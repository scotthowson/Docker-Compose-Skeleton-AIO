# dns-verify

After a deployment: confirms the stack's Traefik hostnames resolve in DNS and that every port the stack publishes answers on the host, so a service is reachable and not just running.

- **Category:** operations
- **Version:** 2.0.0
- **Hooks:** `post-deploy`
- **Tags:** dns, connectivity, verification

## Install

Plugins page → Install, or `POST /plugins/catalog/dns-verify/install`, then enable it.
Hooks receive the DCS context on stdin and run with the environment described in
[.plugins/README.md](../../.plugins/README.md); output and exit codes land in the plugin's execution log.
