# Plugins

Plugins extend DCS with lifecycle **hooks** (scripts that run on stack and template events) and
dashboard **cards** (widgets rendered in the web UI). A plugin is a directory under `.plugins/`.

```
.plugins/my-plugin/
├── plugin.json          # manifest (required)
├── README.md            # what it does, how to configure it
├── hooks/               # executables named after the event they handle
│   ├── pre-deploy
│   └── post-start
├── cards/               # dashboard widgets
│   └── my-card/
│       ├── card.json    # title, icon, size (see example-card/README.md)
│       └── index.html   # self-contained page rendered in a sandboxed iframe
└── state/               # anything the plugin writes at runtime (ignored by git)
```

## Manifest

```jsonc
{
  "name": "my-plugin",
  "version": "1.0.0",
  "description": "One line shown in the UI",
  "author": "You",
  "enabled": true,                 // the single source of truth: false = hooks and cards are off
  "hooks": ["pre-deploy", "post-start"],
  "cards": ["my-card"],
  "config": { "threshold": 5 }     // free-form; editable from the UI (POST /plugins/{name}/config)
}
```

## Hooks

| Event | Fired by |
|-------|----------|
| `pre-start`, `post-start` | stack start (single stack and batch), template auto-start |
| `pre-stop`, `post-stop` | stack stop |
| `pre-update`, `post-update` | stack update (pull + recreate) |
| `pre-deploy`, `post-deploy` | template deployment. A dry run (`POST /templates/{name}/dry-run`) also runs `pre-deploy` synchronously (10 s, first 2 KB of output returned in the preview, context includes the rendered `compose`) |

A hook is an executable file `hooks/<event>` (or `hooks/<event>.sh`). It receives a JSON context on
**stdin**, for example `{"stack":"media-services","template":"jellyfin"}`, and may read its own
manifest for configuration:

```bash
#!/bin/bash
set -euo pipefail
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTEXT=$(cat)
STACK=$(jq -r '.stack // empty' <<< "$CONTEXT")
THRESHOLD=$(jq -r '.config.threshold // 5' "$PLUGIN_DIR/plugin.json")
echo "checking $STACK with threshold $THRESHOLD"
```

Rules the runner enforces:

- Hooks run only when the manifest says `"enabled": true`.
- They run with a **minimal environment** (`PATH`, `HOME`, `BASE_DIR`, `DCS_EVENT`): the server's
  configuration and secrets are never exported to a hook.
- 30-second timeout, output capped at 64 KB; the first 500 bytes are kept in
  `.plugins/<name>/execution.log` (one JSON object per line, readable with
  `GET /plugins/{name}/logs`).
- Hooks run in the background after the triggering request has been answered; they cannot block or
  veto an operation. The only synchronous case is `pre-deploy` during a dry run, whose output is
  shown to the user as a preview warning.
- Symbolic links inside a plugin are never followed.

## Cards

See [`example-card/README.md`](example-card/README.md) for the card format, sizing and the
`postMessage` bridge that lets a card fetch API data from inside its sandbox.

## Managing plugins

| Action | UI | API |
|--------|----|-----|
| Install from a git repository | Plugins page | `POST /plugins/install {"url": "https://..."}` (installed disabled) |
| Create from inline definition | – | `POST /plugins/scaffold` |
| Enable / disable | toggle | `POST /plugins/{name}/toggle` |
| Edit a hook | Plugins page | `POST /plugins/{name}/hooks/{hook}/update`, `.../test` |
| Remove | Plugins page | `DELETE /plugins/{name}` |

All of these require the `admin` role. Plugins cloned from the network are installed **disabled**;
read them before enabling.

## Bundled plugins

| Plugin | Purpose |
|--------|---------|
| `deploy-notifier` | NTFY push notifications on deploy, start and stop |
| `health-watchdog` | Checks container health after starts and deploys, logs unhealthy containers |
| `traefik-subdomain-guard` | Warns about subdomain conflicts before a deployment; ships a status card |
| `example-card` | Two sample dashboard cards to copy from |
