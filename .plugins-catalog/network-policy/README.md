# network-policy

After a deployment: maps which networks the stack's containers share, flags containers on the default bridge (no isolation) and records the topology for later comparison.

- **Category:** advanced
- **Version:** 2.0.0
- **Hooks:** `post-deploy`
- **Tags:** network, isolation, topology

## Install

Plugins page → Install, or `POST /plugins/catalog/network-policy/install`, then enable it.
Hooks receive the DCS context on stdin and run with the environment described in
[.plugins/README.md](../../.plugins/README.md); output and exit codes land in the plugin's execution log.
