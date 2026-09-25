# security-audit

Deep security check — before a deployment on the template (privileged, host namespaces, dangerous capabilities, disabled seccomp/AppArmor, docker.sock) and after it on the running containers (root user, writable root filesystem). Scores each service.

- **Category:** advanced
- **Version:** 2.0.0
- **Hooks:** `post-deploy`, `pre-deploy`
- **Tags:** security, audit, hardening

## Install

Plugins page → Install, or `POST /plugins/catalog/security-audit/install`, then enable it.
Hooks receive the DCS context on stdin and run with the environment described in
[.plugins/README.md](../../.plugins/README.md); output and exit codes land in the plugin's execution log.
