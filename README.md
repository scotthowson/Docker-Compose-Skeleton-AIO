# Docker Compose Skeleton

A modular Docker service orchestration framework with a REST API, 28 deployable service templates, dependency-ordered startup/shutdown, enhanced logging, NTFY push notifications, intelligent image updates, and a full suite of management utilities.

Clone it, configure it, run it — from any directory, by any user.

---

## Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/scotthowson/Docker-Compose-Skeleton.git
cd Docker-Compose-Skeleton

# 2. Run first-run setup
./setup.sh
#    → Verifies Docker, creates directories, launches setup API
#    → Prints your server IP — enter it in DCS Manager to complete setup

# 3. Open DCS Manager, connect to your server IP, and walk through the Setup Wizard
#    (creates admin account, configures .env, selects stack categories)

# 4. Start all services
./start.sh

# 5. Check status
./status.sh
```

### First-Run Setup Wizard

When you clone DCS fresh and run `./setup.sh`, the script:

1. Verifies Docker and Docker Compose are installed
2. Creates required directories and permissions
3. Detects your server's IP address
4. Launches the API in **setup mode** on `http://<your-ip>:9876`

Open [DCS Manager](https://github.com/scotthowson/Docker-Compose-Skeleton-UI), enter your server IP, and the 5-step Setup Wizard guides you through:

| Step | What it does |
|------|-------------|
| **Connect** | Enter server IP, verify connection, detect system info |
| **Admin Account** | Create your admin username and password |
| **Server Config** | Set timezone, domain, data directory, PUID/PGID |
| **Stack Categories** | Choose, rename, reorder, or add stack categories |
| **Review & Complete** | Review all settings, apply configuration, write `.env` |

After setup completes, run `./start.sh` to launch all services. Re-running `./setup.sh` on a configured server exits immediately with a "setup already complete" message.

## REST API

A built-in REST API server provides remote management of your entire Docker infrastructure. Starts automatically with `./start.sh` and listens on `0.0.0.0:9876`.

### Key Endpoints

| Group | Endpoints | Description |
|-------|-----------|-------------|
| **System** | `/status`, `/health`, `/version` | Server health, system metrics, Docker info |
| **Stacks** | `/stacks`, `/stacks/:name/*` | List, start, stop, restart, pull stacks |
| **Containers** | `/containers`, `/containers/:id/*` | List, inspect, start, stop, restart, logs |
| **Templates** | `/templates`, `/templates/:name/deploy` | Browse, preview, deploy 28 service templates |
| **Images** | `/images`, `/images/prune` | List images, prune unused |
| **Networks** | `/networks`, `/networks/:id` | List, inspect, create, remove |
| **Volumes** | `/volumes`, `/volumes/:name` | List, inspect, create, remove |
| **Logs** | `/logs/services`, `/logs/api` | Service and API log viewing with filtering |
| **Events** | `/events` | Real-time Docker event stream |
| **Config** | `/config/env`, `/config/compose` | Read and edit `.env` and compose files |
| **Maintenance** | `/maintenance/*` | Disk report, prune, orphan detection, log rotation |
| **Backups** | `/backups/*` | Create, list, restore backups |
| **Auth** | `/auth/*` | Setup, login, invite codes, token management |
| **Setup** | `/setup/status`, `/setup/defaults`, `/setup/configure`, `/setup/complete` | First-run wizard endpoints |
| **Terminal** | `/terminal/exec` | Authenticated remote command execution |
| **Batch** | `/batch/start`, `/batch/stop` | Bulk stack operations |

### API Authentication

Token-based authentication with PBKDF2 password hashing, rate limiting, and invite-code registration:

```bash
# Initial admin setup
curl -X POST http://localhost:9876/auth/setup \
  -d '{"username":"admin","password":"your-password"}'

# Login (returns auth token)
curl -X POST http://localhost:9876/auth/login \
  -d '{"username":"admin","password":"your-password"}'

# Use token for authenticated endpoints
curl -H "Authorization: Bearer <token>" http://localhost:9876/stacks
```

### API Security

- Input validation with path traversal protection on all resource names
- Request body size limits (configurable, default 1 MB)
- CORS origin allowlisting (default: localhost only)
- Security headers (X-Content-Type-Options, X-Frame-Options, CSP, etc.)
- Rate limiting on authentication endpoints
- Audit logging for all auth events

## Service Templates

28 ready-to-deploy templates across 8 categories. Deploy via the API or the [DCS Manager UI](https://github.com/scotthowson/Docker-Compose-Skeleton-UI).

### Available Templates

| Template | Category | Description |
|----------|----------|-------------|
| **Authelia** | Web | SSO and 2FA authentication server |
| **Caddy** | Web | Automatic HTTPS web server |
| **Docker Socket Proxy** | Web | Secure Docker API access proxy |
| **Grafana** | Monitoring | Dashboards and data visualization |
| **Homarr** | Web | Server dashboard and startpage |
| **Home Assistant** | Automation | Smart home automation platform |
| **Homepage** | Web | Application dashboard with widgets |
| **Jellyfin** | Media | Open-source media server |
| **MinIO** | Storage | S3-compatible object storage |
| **MongoDB** | Databases | NoSQL document database |
| **MySQL** | Databases | Relational SQL database |
| **Nextcloud** | Storage | File sync and collaboration cloud |
| **Nextcloud AIO** | Web | All-in-one Nextcloud with Collabora, Talk, backups |
| **Nginx Proxy Manager** | Web | Reverse proxy with GUI (SQLite or MariaDB) |
| **Pelican Panel** | Web | Game server management panel + Wings |
| **phpMyAdmin** | Databases | MySQL/MariaDB web administration |
| **Plex** | Media | Media server with transcoding |
| **Portainer CE** | Monitoring | Docker management UI |
| **PostgreSQL** | Databases | Advanced relational database |
| **Prometheus** | Monitoring | Metrics collection and alerting |
| **Redis** | Databases | In-memory key-value cache/store |
| **RedisInsight** | Development | Redis GUI and monitoring tool |
| **Sablier** | Utilities | On-demand container scaling |
| **SpeedTest Tracker** | Monitoring | Network bandwidth monitoring |
| **Traefik** | Web | Reverse proxy with auto-SSL, Cloudflare, file routing |
| **Uptime Kuma** | Monitoring | Uptime monitoring and status pages |
| **Watchtower** | Automation | Automatic Docker image updates |

### Template Deployment

Templates deploy with full variable substitution, port conflict detection, compose file merging, and optional config file scaffolding:

```bash
# Preview a deployment (dry run with conflict detection)
curl -X POST http://localhost:9876/templates/traefik/dry-run \
  -d '{"target_stack":"networking-security","variables":{"TRAEFIK_DOMAIN":"example.com"}}'

# Deploy a template
curl -X POST http://localhost:9876/templates/traefik/deploy \
  -d '{"target_stack":"networking-security","auto_start":true,"variables":{"TRAEFIK_DOMAIN":"example.com","TRAEFIK_ACME_EMAIL":"admin@example.com"}}'
```

**Deployment features:**
- Section-aware compose merge (services, volumes, networks merged into correct sections)
- Port conflict detection across all stacks and running containers
- Automatic backup of existing compose files before merge
- Rollback on validation failure (compose config check)
- Non-destructive config file deployment (`cp -rn` — never overwrites existing files)
- Variable substitution in config files (e.g., Traefik's `${TRAEFIK_DOMAIN}` replaced at deploy time)
- DOCKER_STACKS-aware directory creation (custom routes match your stack categories)

### Traefik Template

The Traefik template includes a complete file-based routing system:

```
App-Data/Traefik/                    # Deployed config structure
├── acme.json                        # ACME cert storage (chmod 600)
├── cache/                           # Plugin cache
├── traefik.yml                      # Static config (entrypoints, providers, ACME)
├── traefikRouters.yml               # Shared middlewares, TLS, security headers
└── custom_routes/                   # Per-stack route directories
    ├── core-infrastructure/         # Sample: traefik.yml (dashboard route)
    ├── networking-security/
    ├── monitoring-management/
    ├── development-tools/
    ├── media-services/
    ├── web-applications/
    ├── storage-backup/
    ├── communication-collaboration/
    ├── entertainment-personal/
    └── miscellaneous-services/
```

Route directories mirror your `DOCKER_STACKS` configuration. Place one `.yml` file per service in the matching stack category — Traefik auto-discovers changes with no restart needed.

## Commands

### Core Operations

| Command | Description |
|---------|-------------|
| `./setup.sh` | First-run setup — verifies Docker, creates directories, launches setup API for DCS Manager wizard |
| `./start.sh` | Start all services in dependency order with updates and health checks |
| `./stop.sh` | Stop all services in reverse dependency order |
| `./restart.sh` | Stop then start all services |
| `./status.sh` | Show container status across all stacks |

### Management Utilities

| Script | Description |
|--------|-------------|
| `.scripts/stack-manager.sh` | CLI for managing individual stacks (start/stop/restart/status/logs/pull) |
| `.scripts/health-check.sh` | Comprehensive container health monitoring with formatted tables |
| `.scripts/config-validator.sh` | Validates all config files, directories, and system requirements |
| `.scripts/maintenance.sh` | Docker cleanup, disk analysis, log rotation, orphan detection |
| `.scripts/docker-network-info.sh` | Visualize Docker networks, connections, and port mappings |
| `.scripts/image-tracker.sh` | Track image age and detect stale images across stacks |
| `.scripts/system-info.sh` | System and Docker resource information |
| `.scripts/logs-viewer.sh` | Interactive log viewer with filtering, search, and stats |
| `.scripts/api-server.sh` | REST API server (auto-started by `start.sh`) |

### Flags

| Flag | Available on | Description |
|------|-------------|-------------|
| `--help` | All scripts | Show usage information |
| `--debug` | `start.sh`, `stop.sh` | Debug logging + bash trace |
| `--force` | `stop.sh` | Force stop with 5s timeout |
| `--fix` | `config-validator.sh` | Auto-fix common issues |
| `--json` | Multiple utilities | JSON output |
| `--quiet` | Multiple utilities | Minimal output |

### Stack Manager Examples

```bash
# Manage individual stacks
.scripts/stack-manager.sh list                          # List all stacks
.scripts/stack-manager.sh start core-infrastructure     # Start one stack
.scripts/stack-manager.sh status web-applications       # Detailed status
.scripts/stack-manager.sh logs media-services --follow   # Live logs
.scripts/stack-manager.sh pull monitoring-management    # Pull latest images
.scripts/stack-manager.sh running                       # Show running stacks
```

### Maintenance Examples

```bash
# System maintenance
.scripts/maintenance.sh                  # Full system report
.scripts/maintenance.sh disk             # Disk usage breakdown
.scripts/maintenance.sh prune            # Safe cleanup
.scripts/maintenance.sh deep-prune       # Aggressive cleanup (interactive)
.scripts/maintenance.sh orphans          # Find orphaned resources
.scripts/maintenance.sh log-rotate       # Rotate log files

# Validate your setup
.scripts/config-validator.sh             # Check everything
.scripts/config-validator.sh --fix       # Auto-fix issues

# Network inspection
.scripts/docker-network-info.sh          # Network overview
.scripts/docker-network-info.sh --ports  # Include port mappings

# Image tracking
.scripts/image-tracker.sh               # Check all images
.scripts/image-tracker.sh --quick       # Only show stale images
```

## Configuration

### Root `.env`

The main configuration file. Copy from `.env.example` on first run (or let `setup.sh` handle it):

| Variable | Default | Description |
|----------|---------|-------------|
| `DOCKER_STACKS` | *(10 default categories)* | Space-separated stack directories — controls startup order |
| `APP_DATA_DIR` | `./App-Data` | Persistent container data directory |
| `PUID` / `PGID` | `1000` | User/Group IDs for file permissions |
| `PROXY_DOMAIN` | `example.com` | Domain for reverse proxy routing |
| `TZ` | `UTC` | Timezone for all containers |
| `NTFY_URL` | *(empty)* | NTFY notification endpoint |
| `SERVER_NAME` | `Docker Server` | Server name in notifications |
| `PORTAINER_URL` | *(empty)* | Portainer dashboard URL |
| `DOCKER_COMPOSE_VERSION` | `auto` | `auto`, `v1`, or `v2` |
| `REMOVE_VOLUMES_ON_STOP` | `false` | Remove named volumes on stop |
| `CONTINUE_ON_FAILURE` | `true` | Continue if a stack fails |
| `SKIP_HEALTHCHECK_WAIT` | `false` | Skip `--wait` flag on startup |
| `API_PORT` | `9876` | REST API server port |
| `API_AUTH_ENABLED` | `true` | Require authentication for API endpoints |

### Stack Configuration

The `DOCKER_STACKS` variable controls which stacks exist and their startup order:

```bash
# Default: 10 category directories under Stacks/
DOCKER_STACKS="core-infrastructure networking-security monitoring-management development-tools media-services web-applications storage-backup communication-collaboration entertainment-personal miscellaneous-services"
```

Add, remove, or reorder categories to fit your environment. `setup.sh` creates directories for any categories listed that don't yet exist. Shutdown order is automatically reversed.

### Advanced Settings (`.config/settings.cfg`)

| Category | Key Settings |
|----------|-------------|
| **Startup Behavior** | `SHOW_STARTUP_BANNER`, `SHOW_SYSTEM_INFO`, `SERVICE_START_DELAY`, `STACK_START_TIMEOUT` |
| **Health Checks** | `ENABLE_POST_STARTUP_HEALTH_CHECK`, `HEALTH_CHECK_DELAY`, `INCLUDE_RESOURCE_METRICS` |
| **Logging** | `LOG_LEVEL`, `LOG_DATE_FORMAT`, `LOG_MAX_SIZE`, `LOG_BACKUP_COUNT`, `LOG_RETENTION_DAYS` |
| **Colors** | `COLOR_MODE` (auto/always/never), `COLOR_THEME` (dark/light/high-contrast) |
| **Docker** | `DOCKER_TIMEOUT`, `SERVICE_START_DELAY`, `SERVICE_STOP_DELAY`, `MAX_PARALLEL_OPERATIONS` |
| **Notifications** | `ENABLE_NOTIFICATIONS`, `NOTIFICATION_LEVELS`, `WEBHOOK_URL`, `EMAIL_ALERTS` |

### Per-Stack `.env`

Each stack in `Stacks/` has its own `.env` for stack-specific overrides. By default they inherit from the root `.env`.

### Environment Overrides

Set `ENVIRONMENT` to change behavior profiles:

| Environment | Effect |
|------------|--------|
| `production` | Default. INFO logging, notifications on. |
| `development` | DEBUG logging, verbose mode, function tracing |
| `testing` | DEBUG logging, mocked external calls |
| `staging` | INFO logging, notifications + metrics on |

Runtime override: `LOG_LEVEL=DEBUG ./start.sh`

## Architecture

### Directory Structure

```
Docker-Compose-Skeleton/
├── start.sh                    # Main entry point (startup sequence)
├── stop.sh                     # Graceful shutdown
├── restart.sh                  # Stop + Start wrapper
├── status.sh                   # Container status viewer
├── setup.sh                    # First-run setup
├── .env.example                # Configuration template
├── .env                        # Your configuration (gitignored)
├── .config/
│   ├── settings.cfg            # Application settings & defaults
│   └── palette.sh              # Terminal color palette system
├── .lib/
│   ├── logger.sh               # Enhanced logging system (v3.0)
│   ├── banner.sh               # ASCII art banner library
│   ├── docker-utils.sh         # Docker Compose detection
│   ├── helpers.sh              # Utility functions
│   ├── environment.sh          # Environment verification
│   ├── error_handling.sh       # Graceful error handling
│   └── debugger.sh             # Debug mode support
├── .scripts/
│   ├── api-server.sh           # REST API server (60+ endpoints)
│   ├── run.sh                  # Service startup library (v3.0)
│   ├── stop.sh                 # Service shutdown library (v3.0)
│   ├── health-check.sh         # Container health monitoring
│   ├── stack-manager.sh        # Individual stack management CLI
│   ├── config-validator.sh     # Configuration validator
│   ├── maintenance.sh          # Docker maintenance & cleanup
│   ├── docker-network-info.sh  # Network visualization
│   ├── image-tracker.sh        # Image update tracker
│   ├── system-info.sh          # System information reporter
│   ├── logs-viewer.sh          # Interactive log viewer
│   ├── update.sh               # Docker Compose updater
│   ├── update_all_stacks.sh    # Intelligent stack updater
│   ├── clean-up.sh             # Unused volume cleanup
│   ├── backup-server.sh        # Backup system
│   ├── ntfy-status.sh          # Start status notifications
│   ├── ntfy-status-stop.sh     # Stop status notifications
│   ├── ntfy-status-restart.sh  # Restart status notifications
│   └── wait-for-it.sh          # TCP port availability checker
├── .templates/                 # 28 deployable service templates
│   ├── traefik/                # Includes full config/ scaffolding
│   ├── authelia/
│   ├── nginx-proxy-manager/
│   └── ...                     # See template list above
├── .api-auth/                  # API authentication data (gitignored)
├── Stacks/
│   ├── core-infrastructure/    # Redis (placeholder)
│   ├── networking-security/    # Whoami (placeholder)
│   ├── monitoring-management/  # Alpine heartbeat
│   ├── development-tools/      # Alpine uptime counter
│   ├── media-services/         # Nginx static page (:8081)
│   ├── web-applications/       # Nginx static page (:8082)
│   ├── storage-backup/         # Alpine file writer
│   ├── communication-collaboration/  # Alpine heartbeat
│   ├── entertainment-personal/ # Alpine heartbeat
│   └── miscellaneous-services/ # Alpine healthcheck demo
├── App-Data/                   # Container volumes (gitignored)
└── logs/                       # Log files (gitignored)
```

### Startup Order (Dependency Chain)

```
1. core-infrastructure          6. web-applications
2. networking-security          7. storage-backup
3. monitoring-management        8. communication-collaboration
4. development-tools            9. entertainment-personal
5. media-services              10. miscellaneous-services
```

Shutdown runs in exact reverse order.

### Startup Sequence

When you run `./start.sh`, this happens:

1. **Environment verification** — checks Docker, Compose, directories
2. **Docker Compose update** — auto-updates the binary (v1 only; v2 is package-managed)
3. **Volume cleanup** — removes unreferenced resources
4. **Service startup** — starts all stacks in dependency order with progress bars and per-stack timing
5. **Image updates** — pulls latest images, detects changes via SHA256, rolling restart
6. **Health monitoring** — comprehensive container health check with color-coded status table
7. **API server** — starts the REST API on port 9876

### Logger System

The Enhanced Logger (v3.0, 1200+ lines) provides 50+ log functions with colored console output and plain-text file logging:

- **20+ log levels**: `log_info`, `log_success`, `log_warning`, `log_error`, `log_debug`, `log_critical`, plus extended variants
- **Bold/no-date/combined variants**: `log_bold_success`, `log_nodate_info`, `log_bold_nodate_warning`
- **Progress bars**: `log_progress "Starting stacks" 3 10` with Unicode block characters
- **Step tracking**: `log_step 1 6 "Verifying environment"`
- **Named timers**: `log_timer_start "pull"` / `log_timer_stop "pull"` with human-readable durations
- **Table formatting**: `log_table "Stack|Status|Duration" "core|OK|12s"` with box-drawing characters
- **Session summaries**: Duration, error/warning counts, entry totals in a formatted box

### Notifications

Push notifications via [NTFY](https://ntfy.sh). Set `NTFY_URL` in `.env` to enable. Notifications fire for:
- Service start (critical stacks)
- Service failure (with Portainer action button)
- Shutdown completion
- Container health issues

Leave `NTFY_URL` empty to disable all notifications.

## DCS Manager UI

A companion desktop application for managing Docker Compose Skeleton servers with a dark glassmorphism UI. See [Docker-Compose-Skeleton-UI](https://github.com/scotthowson/Docker-Compose-Skeleton-UI).

**Stack:** Electron + React + Vite + Tailwind CSS + Zustand + TypeScript

**Features:**
- **Setup Wizard** — 5-step guided first-run configuration (connect, admin account, server config, stacks, review)
- Live dashboard with system metrics, memory, disk, and container status
- Stack management — start, stop, restart, pull with real-time status
- Template browser — deploy any of the 28 templates with a form-based UI
- Container control — inspect, logs, start, stop individual containers
- Compose editor — edit docker-compose.yml and .env files in-browser
- Network and volume management
- Notification center with alerts
- Command palette with keyboard shortcuts

## Customizing Stacks

Each stack ships with a minimal placeholder container. To add your real services:

1. Edit `Stacks/<category>/docker-compose.yml` with your services
2. Add stack-specific variables to `Stacks/<category>/.env`
3. Run `./start.sh` to deploy

Or use the template system to deploy pre-configured services into any stack.

The placeholder containers use `skeleton-*` naming, so they won't conflict with your real services.

## Requirements

- **Bash 4+** (uses associative arrays, `declare -g`)
- **Docker** with either:
  - Docker Compose plugin v2 (`docker compose`) — preferred
  - Legacy docker-compose binary v1
- **jq** for API server JSON processing
- **python3** for PBKDF2 password hashing (API auth)
- **curl** for NTFY notifications (optional)
- **tput** for color support (standard on most systems)
- **bc** for size calculations in maintenance tools (optional)

## License

MIT
