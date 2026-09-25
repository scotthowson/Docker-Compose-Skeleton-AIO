# env-validator

Before a deployment: finds ${VARIABLES} the compose file references that are defined nowhere (no default, not in the stack or root .env, not a secret), duplicate and empty keys in the stack .env, and passwords typed straight into the compose file.

- **Category:** safety
- **Version:** 2.0.0
- **Hooks:** `pre-deploy`
- **Tags:** validation, environment, safety

## Install

Plugins page → Install, or `POST /plugins/catalog/env-validator/install`, then enable it.
Hooks receive the DCS context on stdin and run with the environment described in
[.plugins/README.md](../../.plugins/README.md); output and exit codes land in the plugin's execution log.
