# Plugins

Plugins extend DCS with lifecycle **hooks** (scripts that run on stack and template events) and
dashboard **cards** (widgets rendered in the web UI). A plugin is a directory under `.plugins/`.
Four ship with the repository (below) and a catalogue of 23 more lives in `.plugins-catalog/`.

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
├── state/               # the plugin's own scratch space (created by the runner, ignored by git)
└── execution.log        # last 1 000 hook runs, one JSON object per line (ignored by git)
```

## The catalogue

`.plugins-catalog/` holds ready-made plugins, versioned and linted with the rest of the
repository. Installing one copies it into `.plugins/` **disabled**; enable it once you have read
what it does.

| Action | UI | API |
|--------|----|-----|
| Browse | Plugins page | `GET /plugins/catalog` |
| Install | Install button | `POST /plugins/catalog/{name}/install` |
| Enable | toggle | `POST /plugins/{name}/toggle` |

| Category | Plugins |
|----------|---------|
| safety | `env-validator`, `deploy-guard`, `auto-backup`, `image-freshness`, `rollback-sentinel`, `dependency-checker`, `secret-scanner` |
| monitoring | `container-notifier`, `resource-monitor`, `stack-analytics`, `uptime-ping`, `disk-watchdog`, `response-timer` |
| operations | `port-guard`, `log-archiver`, `dns-verify`, `cleanup-sweeper`, `crash-responder`, `volume-sizer`, `label-enforcer` |
| advanced | `security-audit`, `network-policy`, `network-firewall` |

Each plugin's `README.md` in the catalogue explains what it checks, what it needs (`env`) and
what it can be tuned with (`config`).

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
  "category": "safety",            // safety | monitoring | operations | advanced (catalogue only)
  "tags": ["backup"],
  "env": ["NTFY_URL"],             // root .env variables the hooks may read (see Environment)
  "config": { "threshold": 5 },    // free-form; editable from the UI (POST /plugins/{name}/config)
  "contract": 2
}
```

## Hooks

| Event | Fired by | Context extras |
|-------|----------|----------------|
| `pre-start`, `post-start` | stack start (single stack, batch, template auto-start) | `action`, `success`, `containers` |
| `pre-stop`, `post-stop` | stack stop | `action`, `success`, `containers` |
| `pre-update`, `post-update` | stack update (pull + recreate) | `action`, `success`, `changed_images` |
| `pre-deploy`, `post-deploy` | template deployment | `template`, `compose`, `dry_run`, `success`, `started` |

`pre-*` hooks run before the action and `post-*` hooks after it has **finished**, in order, from
one detached runner. `post-*` hooks always receive `success` (`true`/`false`) so a plugin can
react to a failed start or update. A dry run (`POST /templates/{name}/dry-run`) runs
`pre-deploy` synchronously with `dry_run: true` (10 s, first 2 KB of output shown in the
preview); everything else runs in the background after the request has been answered and cannot
veto an operation.

A hook is an executable file `hooks/<event>` (or `hooks/<event>.sh`). It receives the context as
JSON on **stdin**:

```json
{
  "event": "post-start",
  "stack": "media-services",
  "project": "media-services",
  "compose_file": "/opt/dcs/Stacks/media-services/docker-compose.yml",
  "action": "start",
  "success": true,
  "containers": [{"name": "Jellyfin", "state": "running", "health": "healthy", "image": "jellyfin/jellyfin:latest"}],
  "template": "jellyfin",          // deploy events only
  "compose": "services: ...",      // deploy events only: the rendered template
  "dry_run": false
}
```

### Environment

Hooks run with a **minimal environment**; the server's configuration and secrets are never
exported. What a hook sees:

| Variable | Meaning |
|----------|---------|
| `PATH`, `HOME`, `TZ` | the usual |
| `BASE_DIR`, `COMPOSE_DIR` | the installation and its `Stacks/` directory |
| `DCS_EVENT` | the event name |
| `PLUGIN_NAME`, `PLUGIN_DIR` | the plugin and its directory |
| `PLUGIN_STATE_DIR` | `<plugin>/state/`, created with mode 700; keep counters, timestamps, reports here |
| `DCS_PLUGIN_CONFIG` | the manifest's `config` object as JSON (`jq -r '.threshold' <<< "$DCS_PLUGIN_CONFIG"`) |
| `DCS_DRY_RUN` | `true` during a dry run: report, do not act |
| `DCS_NTFY_URL`, `NTFY_TOKEN` | the notification endpoint (URL + topic) when NTFY is configured |
| `DOCKER_COMPOSE_CMD` | `docker compose` or `docker-compose`, whichever the server uses |
| the names listed in `env` | copied from the root `.env` (upper-case names only; loader and shell variables are refused) |

Rules the runner enforces:

- Hooks run only when the manifest says `"enabled": true`.
- 30-second timeout (10 s for the synchronous dry-run hook), output capped at 64 KB; the first
  2 KB, the exit code and the dry-run flag are kept in `execution.log` (last 1 000 runs, readable
  with `GET /plugins/{name}/logs` and on the plugin's page).
- Symbolic links inside a plugin are never followed.

### Example

```bash
#!/bin/bash
set -euo pipefail
CTX=$(cat)
STACK=$(jq -r '.stack // "unknown"' <<< "$CTX")
OK=$(jq -r '.success // true' <<< "$CTX")
THRESHOLD=$(jq -r '.threshold // 5' <<< "${DCS_PLUGIN_CONFIG:-{}}")

[[ "${DCS_DRY_RUN:-false}" == "true" ]] && { echo "dry run: would check $STACK"; exit 0; }

if [[ "$OK" == "true" ]]; then
    echo "$(date -u +%FT%TZ) $STACK ok" >> "$PLUGIN_STATE_DIR/history.log"
elif [[ -n "${DCS_NTFY_URL:-}" ]]; then
    curl -fsS -m 5 ${NTFY_TOKEN:+-H "Authorization: Bearer $NTFY_TOKEN"} \
        -H "Title: DCS" -d "$STACK failed to start" "$DCS_NTFY_URL" >/dev/null
fi
```

Test it without waiting for an event: `POST /plugins/{name}/hooks/{event}/test` (or the Test
button on the plugin's page) runs the hook with a synthetic dry-run context.

## Cards

See [`example-card/README.md`](example-card/README.md) for the card format, sizing and the
`postMessage` bridge that lets a card fetch API data from inside its sandbox.

## Managing plugins

| Action | UI | API |
|--------|----|-----|
| Install from the catalogue | Plugins page | `POST /plugins/catalog/{name}/install` (installed disabled) |
| Install from a git repository | Plugins page | `POST /plugins/install {"url": "https://..."}` (installed disabled) |
| Create from inline definition | – | `POST /plugins/scaffold` |
| Enable / disable | toggle | `POST /plugins/{name}/toggle` |
| Edit a hook | Plugins page | `POST /plugins/{name}/hooks/{hook}/update`, `.../test` |
| Change `config` | Plugins page | `POST /plugins/{name}/config` |
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
