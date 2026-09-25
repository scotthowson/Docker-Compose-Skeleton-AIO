# secret-scanner

Before a deployment: scans the template and the stack .env for credentials typed in plain text — AWS and GitHub tokens, JWT secrets, private keys, database passwords and 20+ other formats — and points at the Secrets page instead.

- **Category:** advanced
- **Version:** 2.0.0
- **Hooks:** `pre-deploy`
- **Tags:** secrets, security, scan

## Install

Plugins page → Install, or `POST /plugins/catalog/secret-scanner/install`, then enable it.
Hooks receive the DCS context on stdin and run with the environment described in
[.plugins/README.md](../../.plugins/README.md); output and exit codes land in the plugin's execution log.
