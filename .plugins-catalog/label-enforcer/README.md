# label-enforcer

After a deployment: checks the stack's containers for the labels your organisation requires (configurable; defaults to maintainer, version, stack-category, backup-policy) and writes a compliance report.

- **Category:** advanced
- **Version:** 2.0.0
- **Hooks:** `post-deploy`
- **Tags:** labels, compliance, governance

## Settings (`config` in plugin.json, editable from the Plugins page)

| Key | Default |
|-----|---------|
| `required_labels` | `["maintainer", "version", "stack-category", "backup-policy"]` |

## Install

Plugins page → Install, or `POST /plugins/catalog/label-enforcer/install`, then enable it.
Hooks receive the DCS context on stdin and run with the environment described in
[.plugins/README.md](../../.plugins/README.md); output and exit codes land in the plugin's execution log.
