# DCS API reference

Generated from the router in `.scripts/api-server.sh` by `.scripts/api-docs.sh` — do not edit by hand.
Run `.scripts/api-docs.sh` after adding or changing a route; CI fails when this file is stale.

The API listens on `API_BIND:API_PORT` (default `0.0.0.0:9876`) and answers JSON.
Every endpoint below is `236` in total.

## Access levels

| Level | Meaning |
|-------|---------|
| public | No token needed (setup, login, health of the API itself). |
| user | Any authenticated account. Users are viewers: they read operational data and manage their own session and profile. |
| admin | Accounts with the admin role. Everything that changes the system, runs code or exposes secrets. |

Send the session token as `Authorization: Bearer <token>`. `POST /auth/setup` creates the first (admin) account on a fresh install; until it exists, only the setup endpoints and `GET /version` answer.

## Usage

```bash
API=http://localhost:9876

# First run: create the admin account (returns a session token)
curl -s -X POST "$API/auth/setup" -H 'Content-Type: application/json' \
     -d '{"username":"admin","password":"correct horse battery staple"}'

# Log in later
TOKEN=$(curl -s -X POST "$API/auth/login" -H 'Content-Type: application/json' \
     -d '{"username":"admin","password":"correct horse battery staple"}' | jq -r .token)
AUTH="Authorization: Bearer $TOKEN"

curl -s -H "$AUTH" "$API/status" | jq .            # host and Docker overview
curl -s -H "$AUTH" "$API/stacks" | jq .            # stacks and their containers
curl -s -H "$AUTH" -X POST "$API/stacks/media-services/start"

# Deploy a template into a stack and start it
curl -s -H "$AUTH" -X POST "$API/templates/jellyfin/deploy" -H 'Content-Type: application/json' \
     -d '{"target_stack":"media-services","auto_start":true,"variables":{"PUID":"1000"}}'

# Preview the same deployment without touching anything
curl -s -H "$AUTH" -X POST "$API/templates/jellyfin/dry-run" -H 'Content-Type: application/json' \
     -d '{"target_stack":"media-services"}' | jq .

# Live events and metrics (Server-Sent Events; EventSource clients pass the token as ?token=)
curl -N -H "$AUTH" "$API/stream"

# Invite a read-only viewer
CODE=$(curl -s -H "$AUTH" -X POST "$API/auth/invite" -d '{"role":"user"}' | jq -r .code)
curl -s -X POST "$API/auth/register" -H 'Content-Type: application/json' \
     -d "{\"username\":\"viewer\",\"password\":\"another strong passphrase\",\"invite_code\":\"$CODE\"}"
```

Errors are JSON too: `{"error": true, "code": 403, "message": "Admin access required"}`.
Rate limiting answers `429`; a fresh install answers `401` with a message pointing at `POST /auth/setup`.

## System

| Method | Path | Access | Description |
|--------|------|--------|-------------|
| GET | `/` | public | API name, version, authentication mode and the endpoint list |
| GET | `/status` | user | Host and Docker overview: containers, images, stacks, load, memory, disk, GPU |
| GET | `/health` | user | Health report for every container (running, unhealthy, stopped, restart loops) |
| GET | `/config` | user | Effective configuration (secrets masked) |
| GET | `/system` | user | Host resources: CPU, memory, uptime, kernel |
| GET | `/disks` | user | Mounted filesystems and their usage |
| GET | `/version` | user | API, framework, Docker and Compose versions |
| GET | `/system/metrics` | user | CPU load, memory and per-mount disk usage |
| GET | `/metrics/trends` | user | Metrics samples for a range (range=1h\|6h\|24h\|7d\|30d\|90d\|1y\|all), downsampled, with min/max for rolled-up points |
| GET | `/metrics/history` | user | Metrics samples for a range (range=1h\|6h\|24h\|7d\|30d\|90d\|1y\|all); same data as /metrics/trends under "data" |
| GET | `/metrics/summary` | user | Min, max and average CPU, memory and disk over a range (range=1h\|6h\|24h\|7d\|30d\|90d\|1y\|all) |
| GET | `/health/score` | user | System health score (0-100) with its factors |
| GET | `/health/score/history` | user | Recorded health scores over a range |
| GET | `/config/schema` | user | Return contents of .config/schema.json |
| GET | `/health/score/{stack}` | user | Compute health score for a specific stack |
| GET | `/export/{health|system|config}` | user | Export data |
| POST | `/config` | admin | Update allow-listed .env settings |
| POST | `/metrics/snapshot` | admin | Record a metrics sample now |

## Authentication

| Method | Path | Access | Description |
|--------|------|--------|-------------|
| GET | `/auth/verify` | public | Verify a token is valid |
| GET | `/auth/users` | admin | List all users (admin only) |
| GET | `/auth/invites` | admin | List active invite codes (admin only) |
| GET | `/auth/sessions` | admin | List active sessions (admin only) |
| POST | `/auth/setup` | public | Create the first admin account (only when no users exist) |
| POST | `/auth/login` | public | Authenticate and get a session token |
| POST | `/auth/register` | public | Register a new account with an invite code |
| POST | `/auth/totp/validate` | public | Validate TOTP code during login (second step) |
| POST | `/auth/logout` | user | Invalidate the current session token |
| POST | `/auth/refresh` | user | Refresh the current session token |
| POST | `/auth/totp/setup` | user | Generate TOTP secret and return QR URI (not yet enabled) |
| POST | `/auth/totp/verify` | user | Verify a TOTP code and enable 2FA |
| POST | `/auth/totp/disable` | user | Disable 2FA (requires password confirmation) |
| POST | `/auth/invite` | admin | Generate an invite code (admin only) |
| POST | `/auth/revoke` | admin | Revoke a user's access (admin only) |
| POST | `/auth/logout-all` | admin | Invalidate all sessions for a user (admin only) |
| POST | `/auth/factory-reset` | admin | Wipe auth state and return server to first-run mode |
| DELETE | `/auth/sessions/{token-prefix}` | admin | Revoke a specific session by token prefix (admin only) |
| DELETE | `/auth/invite/{code}` | admin | Delete an invite code (admin only) |

## Setup wizard

| Method | Path | Access | Description |
|--------|------|--------|-------------|
| GET | `/setup/status` | public | Always available, no auth. Reports whether server needs setup. |
| GET | `/setup/defaults` | public | Defaults and detected system values for the setup wizard (anonymous until setup is complete, admin afterwards) |
| POST | `/setup/configure` | user | Apply the setup wizard's settings and stack list |
| POST | `/setup/complete` | user | Mark first-run setup as finished |

## Stacks

| Method | Path | Access | Description |
|--------|------|--------|-------------|
| GET | `/stacks` | user | All stacks with running-container counts |
| GET | `/stacks/{stack}/compose/history/{version}` | user | View a specific compose version's content |
| GET | `/stacks/{stack}/compose/history` | user | Saved versions of a stack's compose file |
| GET | `/stacks/{stack}/activity` | user | Progress of the action running (or last run) on a stack: phase, per-service state, compose output |
| GET | `/stacks/{stack}/services` | user | Services of a stack with container state, health and image |
| GET | `/stacks/{stack}/containers` | user | Containers of one stack |
| GET | `/stacks/{stack}/logs` | user | Recent log lines of a stack |
| GET | `/stacks/{stack}/compose` | user | The stack's docker-compose.yml |
| GET | `/stacks/{stack}/env` | admin | The stack's .env file |
| GET | `/stacks/{stack}` | user | Stack detail: services, containers and images |
| POST | `/stacks/rename` | admin | Rename a stack directory |
| POST | `/stacks/reorder` | admin | Set stack startup order |
| POST | `/stacks` | admin | Create an empty stack directory |
| POST | `/stacks/{stack}/delete` | admin | Delete a stopped stack directory |
| POST | `/batch/stacks` | admin | Start, stop or restart several stacks in dependency order |
| POST | `/batch/update` | admin | Pull images for several stacks and recreate what changed |
| POST | `/stacks/{stack}/compose/validate` | user | Validate compose content for a stack without saving it |
| POST | `/stacks/{stack}/compose` | admin | Save the stack's docker-compose.yml (policy-scanned, previous version kept) |
| POST | `/stacks/{stack}/env` | admin | Save the stack's .env file |
| POST | `/stacks/{stack}/compose/rollback` | admin | Restore a saved compose version |
| POST | `/stacks/{stack}/clone` | admin | Clone a stack |
| POST | `/stacks/{stack}/start` | admin | Start, stop, restart or update (pull + recreate) a stack |
| POST | `/stacks/{stack}/stop` | admin | Start, stop, restart or update (pull + recreate) a stack |
| POST | `/stacks/{stack}/restart` | admin | Start, stop, restart or update (pull + recreate) a stack |
| POST | `/stacks/{stack}/update` | admin | Start, stop, restart or update (pull + recreate) a stack |

## Containers

| Method | Path | Access | Description |
|--------|------|--------|-------------|
| GET | `/containers` | user | All containers with state, health, ports and cached CPU/memory usage |
| GET | `/containers/{container}/files` | admin | List directory contents inside a container |
| GET | `/containers/{container}/files/content` | admin | Read file contents inside a container |
| GET | `/containers/{container}/logs/live` | user | Fetch recent logs for polling |
| GET | `/containers/{container}/stats` | user | Live CPU, memory, network and block I/O of a container |
| GET | `/containers/{container}/logs` | user | Recent log lines of a container |
| GET | `/containers/{container}/processes` | user | Process list inside a container |
| GET | `/containers/{container}` | user | Container detail |
| POST | `/containers/{container}/start` | admin | Start, stop, restart, recreate (Compose-managed only) or remove a container |
| POST | `/containers/{container}/stop` | admin | Start, stop, restart, recreate (Compose-managed only) or remove a container |
| POST | `/containers/{container}/restart` | admin | Start, stop, restart, recreate (Compose-managed only) or remove a container |
| POST | `/containers/{container}/recreate` | admin | Start, stop, restart, recreate (Compose-managed only) or remove a container |
| POST | `/containers/{container}/remove` | admin | Start, stop, restart, recreate (Compose-managed only) or remove a container |
| POST | `/containers/{container}/exec` | admin | Run a command inside a container (30 s limit) |
| POST | `/containers/{container}/sablier` | admin | Start this container on demand through Sablier (enabled: true) or serve it normally again; writes or removes the Traefik middleware on its route |
| POST | `/containers/{container}/env` | admin | Change a Compose-managed container's environment in its stack {set{}, unset[], recreate} |
| POST | `/containers/{container}/rename` | admin | Rename a container |

## Images

| Method | Path | Access | Description |
|--------|------|--------|-------------|
| GET | `/images` | user | Images with age, size and staleness (/images/stale lists only stale ones) |
| GET | `/images/stale` | user | Images with age, size and staleness (/images/stale lists only stale ones) |
| GET | `/images/check-updates` | user | Image staleness from age plus the cached registry check |
| GET | `/images/search` | user | Search Docker Hub for images |
| POST | `/images/{image}/delete` | admin | Remove an image |
| POST | `/images/check-updates` | admin | Compare local image digests with their registries (slow) |
| POST | `/images/update` | admin | Pull an image and recreate the Compose services that use it |
| POST | `/images/{image}/update` | admin | Pull an image and recreate the Compose services that use it |

## Networks and volumes

| Method | Path | Access | Description |
|--------|------|--------|-------------|
| GET | `/networks` | user | Docker networks with connected containers |
| GET | `/volumes` | user | Docker volumes |
| GET | `/topology` | user | Container and network topology graph |
| GET | `/networks/{network}` | user | Network detail with its members |
| POST | `/networks` | admin | Create a Docker network {name, driver, subnet, gateway, ip_range, internal, attachable, ipv6, labels} |
| POST | `/networks/{network}/delete` | admin | Remove a Docker network |
| POST | `/networks/{network}/connect` | admin | Connect a container to a network |
| POST | `/networks/{network}/disconnect` | admin | Disconnect a container from a network |
| POST | `/networks/{network}/recreate` | admin | Rebuild a network with new settings and reconnect its containers |
| POST | `/volumes/{volume}/delete` | admin | Remove a Docker volume |

## Templates

| Method | Path | Access | Description |
|--------|------|--------|-------------|
| GET | `/templates` | user | Available templates |
| GET | `/templates/deploy-history` | admin | Template deploy and undeploy events |
| GET | `/templates/gallery` | user | List templates from gallery catalog |
| GET | `/templates/{template}` | user | Template metadata, compose file and .env |
| POST | `/templates/{template}/deploy` | admin | Deploy a template into a stack (merge, routes, DNS, optional start) |
| POST | `/templates/{template}/undeploy` | admin | Remove a template's services from a stack with their containers (remove_containers=false keeps them; optionally data, images, routes) |
| POST | `/templates/{template}/dry-run` | user | Preview a deployment: conflicts, ports, variables and policy findings |
| POST | `/templates/import` | admin | Import a template from compose content |
| POST | `/templates/fetch-url` | admin | Fetch compose content from URL without saving |
| POST | `/templates/import-url` | admin | Import a template from a URL |
| POST | `/compose/validate` | user | Validate a compose file |
| POST | `/templates/{template}/update` | admin | Update an existing template's compose, metadata, and .env |
| DELETE | `/templates/{template}` | admin | Delete a template |

## Routing and DNS

| Method | Path | Access | Description |
|--------|------|--------|-------------|
| GET | `/ddns/status` | admin | Check DDNS status and current IP |
| GET | `/routes/health` | user | Probe every custom route through Traefik (no changes made) |
| GET | `/traefik/status` | user | Check if Traefik is deployed and return domain |
| GET | `/routes` | user | Traefik routes: subdomain, service, stack and target |
| GET | `/routes/certificates` | user | Reverse-proxy health: domain, ACME challenge and account, certificates held, a live probe of every route through Traefik, the last Traefik errors, and hints |
| GET | `/routes/check` | user | Check if a subdomain is available |
| GET | `/dns/status` | user | Cloudflare integration: where the token comes from, whether it is valid, the zone |
| GET | `/dns/zones` | admin | Zones the Cloudflare token can manage |
| GET | `/dns/records` | admin | DNS records of the zone (all types) with their DCS route links |
| GET | `/homarr/status` | user | Check if Homarr is deployed and has an API key configured |
| POST | `/dns/records` | admin | Create a record {type, name, content, ttl, proxied, priority, comment, zone} |
| POST | `/dns/records/sync` | admin | Create the proxied CNAME records that DCS routes are missing |
| POST | `/routes/reconcile` | admin | Probe the routes and restart Traefik once if they are dead |
| PUT | `/dns/records/*` | admin | Change a record's type, name, content, TTL, proxy status, priority or comment |
| PUT | `/routes/{stack}/{service}` | admin | Update a route file's subdomain |
| DELETE | `/dns/records/*` | admin | Delete a record (the zone apex and names DCS routes use need force=true) |
| DELETE | `/routes/{stack}/{service}` | admin | Delete a route file and optionally clean up DNS |

## Logs and events

| Method | Path | Access | Description |
|--------|------|--------|-------------|
| GET | `/logs` | user | Tail of the framework log |
| GET | `/logs/stats` | user | Log file size and per-level counts |
| GET | `/logs/archives` | user | Rotated log archives |
| GET | `/events` | user | Recent Docker events |
| GET | `/stream` | user | SSE endpoint: docker events + periodic metrics |
| GET | `/audit` | admin | Get audit log entries |
| GET | `/logs/live` | user | Stream DCS application log |

## Updates and maintenance

| Method | Path | Access | Description |
|--------|------|--------|-------------|
| GET | `/system/update/check` | admin | Check for available DCS updates via git |
| GET | `/system/os-update/status` | admin | Poll background OS update progress |
| GET | `/system/crontab` | admin | User crontab entries |
| GET | `/system/crontab/system` | admin | System-level cron entries |
| POST | `/system/crontab` | admin | Update user crontab |
| POST | `/system/update/apply` | admin | Apply update safely using git pull --ff-only |
| POST | `/system/ui-update/apply` | admin | Pull latest DCS-UI image and recreate container |
| POST | `/system/update/rollback` | admin | Rollback to a previously created backup tag |
| POST | `/system/os-update/check` | admin | List available OS package updates (terminal session required) |
| POST | `/system/os-update/apply` | admin | Apply OS package updates in the background (terminal session required) |

## Backups and maintenance

| Method | Path | Access | Description |
|--------|------|--------|-------------|
| GET | `/maintenance/report` | user | Docker disk usage report |
| GET | `/maintenance/orphans` | user | Containers, volumes and networks no stack references |
| GET | `/maintenance/disk` | user | Per-stack App-Data sizes, Docker disk usage and volume sizes |
| GET | `/backups` | admin | Backup archives in BACKUP_DEST_DIR |
| GET | `/backups/status` | admin | Progress of the running backup or the last result |
| GET | `/backups/config` | admin | Backup source, destination and retention |
| GET | `/snapshots` | admin | Configuration snapshots |
| GET | `/rollback/{stack}/snapshots/{snapshot}` | user | Content of a rollback snapshot |
| GET | `/rollback/{stack}/snapshots` | user | Rollback snapshots of a stack |
| GET | `/rollback/{stack}/diff/{snapshot}` | user | Diff between a snapshot and the current stack files |
| GET | `/snapshots/{snapshot}/download` | admin | Download a snapshot archive |
| POST | `/maintenance/prune` | admin | Prune stopped containers, dangling images and unused networks |
| POST | `/maintenance/image-prune` | admin | Prune unused images |
| POST | `/maintenance/deep-prune` | admin | Prune everything unused, volumes included (confirmation required) |
| POST | `/maintenance/log-rotate` | admin | Rotate and archive the framework log |
| POST | `/backups/trigger` | admin | Start a backup in the background (optionally one stack) |
| POST | `/backups/cancel` | admin | Kill a running backup |
| POST | `/backups/restore` | admin | Restore a backup archive (confirmation required) |
| POST | `/snapshots/create` | admin | Create a configuration snapshot (compose files, .env files, templates) |
| POST | `/snapshots/{snapshot}/restore` | admin | Restore a snapshot (confirmation required, policy-scanned) |
| POST | `/rollback/{stack}/restore` | admin | Restore a stack from a rollback snapshot (policy-scanned) |
| DELETE | `/snapshots/{snapshot}` | admin | Delete a snapshot |

## Configuration

| Method | Path | Access | Description |
|--------|------|--------|-------------|
| GET | `/env` | admin | The root .env file, raw and parsed |
| GET | `/settings/dashboard` | user | Fetch user's dashboard layout |
| GET | `/settings/profile` | user | Fetch user's profile settings |
| GET | `/secrets` | admin | List secret key names (never values) |
| GET | `/secrets/{key}/exists` | admin | Check if a secret exists (boolean) |
| GET | `/secrets/{key}/references` | admin | Stacks and env files that reference a secret |
| POST | `/env` | admin | Save the root .env file (validated as plain KEY=value data) |
| POST | `/env/validate` | user | Validate .env content without saving it |
| POST | `/settings/dashboard` | user | Save user's dashboard layout |
| POST | `/settings/profile` | user | Save user's profile settings |
| POST | `/secrets` | admin | Store an encrypted secret (also POST /secrets/{key}) |
| POST | `/secrets/{key}` | admin | Store an encrypted secret (also POST /secrets/{key}) |
| DELETE | `/secrets/{key}` | admin | Securely delete a secret |

## Notifications

| Method | Path | Access | Description |
|--------|------|--------|-------------|
| GET | `/alerts/config` | user | Read alert thresholds |
| GET | `/notifications/rules` | user | NTFY notification rules |
| GET | `/notifications/history` | user | Recently sent notifications |
| GET | `/webhooks` | user | List webhooks |
| POST | `/alerts/config` | admin | Update alert thresholds |
| POST | `/notifications/rules` | admin | Create or update a notification rule |
| POST | `/notifications/test` | admin | Send a test notification to every configured channel (NTFY, Discord) |
| POST | `/webhooks` | admin | Create a webhook |
| POST | `/webhooks/{id}/test` | admin | Test a webhook |
| DELETE | `/notifications/rules/{id}` | admin | Delete a notification rule |
| DELETE | `/webhooks/{id}` | admin | Delete a webhook |

## Automation

| Method | Path | Access | Description |
|--------|------|--------|-------------|
| GET | `/automations` | user | Automation rules |
| GET | `/schedules` | user | Return schedules.json content |
| GET | `/schedules/{id}/history` | user | Return execution history filtered by schedule id |
| GET | `/automations/{id}/history` | user | Run history of an automation |
| POST | `/automations` | admin | Create an automation rule |
| POST | `/automations/{id}/update` | admin | Update an automation rule |
| POST | `/automations/{id}/run` | admin | Run an automation now |
| POST | `/schedules` | admin | Create a scheduled task |
| POST | `/schedules/{id}/update` | admin | Update a scheduled task |
| POST | `/schedules/{id}/toggle` | admin | Enable/disable a schedule |
| POST | `/schedules/{id}/run` | admin | Execute a schedule immediately |
| DELETE | `/automations/{id}` | admin | Delete an automation rule |
| DELETE | `/schedules/{id}` | admin | Remove a schedule |

## Plugins

| Method | Path | Access | Description |
|--------|------|--------|-------------|
| GET | `/plugins` | user | Scan .plugins/ directory, return plugin manifest data |
| GET | `/plugins/cards` | user | List all available plugin cards across all enabled plugins |
| GET | `/plugins/catalog` | user | Plugins available to install, with their manifest and installed state |
| GET | `/plugins/{plugin}/cards/*/source` | admin | The card's manifest and raw HTML, for editing |
| GET | `/plugins/{plugin}/cards/{card}` | user | Return card HTML content as JSON |
| GET | `/plugins/{plugin}/hooks/{hook}` | admin | Read hook script content |
| GET | `/plugins/{plugin}/hooks` | admin | List all hooks with metadata |
| GET | `/plugins/{plugin}/logs` | admin | Execution history |
| POST | `/plugins/install` | admin | Install a plugin from a git URL (installed disabled) |
| POST | `/plugins/scaffold` | admin | Create a plugin from an inline manifest, hooks and cards |
| POST | `/plugins/catalog/*/install` | admin | Install a catalogue plugin (copied into .plugins, disabled) |
| POST | `/plugins/{plugin}/cards/{card}` | admin | Create or replace a dashboard card in a plugin {meta{}, html} |
| POST | `/plugins/{plugin}/toggle` | admin | Enable/disable by writing to plugin.json |
| POST | `/plugins/{plugin}/hooks/{hook}/test` | admin | Dry-run a hook |
| POST | `/plugins/{plugin}/hooks/{hook}/update` | admin | Update hook script |
| POST | `/plugins/{plugin}/config` | admin | Update plugin configuration |
| DELETE | `/plugins/{plugin}/cards/{card}` | admin | Remove a dashboard card from a plugin |
| DELETE | `/plugins/{plugin}` | admin | Remove plugin directory |

## Terminal

| Method | Path | Access | Description |
|--------|------|--------|-------------|
| GET | `/terminal/history` | admin | Recent terminal commands from the audit log |
| POST | `/terminal/exec` | admin | Run a shell command on the host (terminal session required, 60 s limit) |
| POST | `/terminal/auth` | admin | Authenticate with Linux credentials |
| POST | `/terminal/auth/verify` | admin | Verify a terminal session token |
| POST | `/terminal/auth/logout` | admin | Invalidate a terminal session |

## Other

| Method | Path | Access | Description |
|--------|------|--------|-------------|
| GET | `/crowdsec/status` | user | CrowdSec presence, whitelist state and active decisions |
| GET | `/crowdsec/decisions` | user | Active CrowdSec decisions (bans) |
| POST | `/crowdsec/trust` | admin | Add an address to the whitelist (body {ip}; defaults to the home public address and the caller) |
| POST | `/crowdsec/unban-me` | user | Unban the caller: its client address and the home public address |
| DELETE | `/crowdsec/decisions/*` | admin | Remove every decision for an address (unban) |
| DELETE | `/crowdsec/trust/*` | admin | Remove an address from the whitelist |

