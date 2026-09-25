# dependency-checker

Before a deployment: resolves the template's depends_on graph with docker compose and reports circular references, missing targets, and dependencies on services without a health check (which makes condition: service_healthy impossible).

- **Category:** advanced
- **Version:** 2.0.0
- **Hooks:** `pre-deploy`
- **Tags:** dependencies, compose, validation

## Install

Plugins page → Install, or `POST /plugins/catalog/dependency-checker/install`, then enable it.
Hooks receive the DCS context on stdin and run with the environment described in
[.plugins/README.md](../../.plugins/README.md); output and exit codes land in the plugin's execution log.
