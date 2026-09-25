# port-guard

Before a stack starts: lists the host ports its compose file publishes and reports any that another process (outside this stack) already listens on — the cause of silent bind failures.

- **Category:** operations
- **Version:** 2.0.0
- **Hooks:** `pre-start`
- **Tags:** ports, conflicts, startup

## Install

Plugins page → Install, or `POST /plugins/catalog/port-guard/install`, then enable it.
Hooks receive the DCS context on stdin and run with the environment described in
[.plugins/README.md](../../.plugins/README.md); output and exit codes land in the plugin's execution log.
