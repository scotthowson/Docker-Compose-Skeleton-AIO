# Docker Compose Skeleton — All-In-One

A batteries-included Docker homelab framework with a built-in web interface. One command to bootstrap your server — complete setup in your browser.

> **AIO** bundles the [DCS framework](https://github.com/scotthowson/Docker-Compose-Skeleton) with [DCS Manager UI](https://github.com/scotthowson/Docker-Compose-Skeleton-UI) as a Docker container. No desktop app install needed.

---

## Quick Start

```bash
git clone https://github.com/scotthowson/Docker-Compose-Skeleton-AIO.git dcs
cd dcs
./setup.sh
```

Open `http://localhost:3000` in your browser. The Setup Wizard walks you through everything: admin account, server configuration, stack selection, and optional Traefik HTTPS.

When ready, start all services:

```bash
./start.sh
```

---

## How It Works

```
./setup.sh
  1. Checks Docker + Docker Compose
  2. Creates .env from .env.example
  3. Creates stack directories
  4. Sets permissions
  5. Verifies Docker environment
  6. Starts API server (background)
  7. Starts core-infrastructure (DCS-UI + Redis)
  8. Prints browser URL

Browser → http://localhost:3000
  → Setup Wizard auto-connects
  → Create admin account
  → Configure server (timezone, domain, stacks)
  → Optionally deploy Traefik for HTTPS
  → Done — manage everything from the web UI
```

## Architecture

```
Browser → https://ui.example.com (or http://localhost:3000)
         → Traefik (optional, Let's Encrypt TLS)
         → DCS-UI container (nginx:alpine, ~25MB)
              → /        serves the SPA
              → /api/*   proxies to host API (127.0.0.1:9876)
                           ↓
                    DCS API server (api-server.sh)
                           ↓
                    Docker Engine → manages all stacks
```

Same origin — no CORS issues. The nginx reverse proxy bridges the container to the host API.

---

## What's Inside

| Component | Description |
|-----------|-------------|
| **DCS Framework** | 10 stack categories, dependency-ordered startup/shutdown, progress bars, health checks |
| **DCS-UI** | Glassmorphism web interface — dashboard, containers, stacks, images, logs, terminal, file browser |
| **REST API** | 60+ endpoints for full server management, auth, SSE streaming |
| **Template System** | 28+ service templates (Traefik, Portainer, Jellyfin, Nextcloud, etc.) — deploy from the UI |
| **Management CLI** | Stack manager, health checks, config validator, network mapper, image tracker, log viewer |

---

## Configuration

All configuration lives in the root `.env` file. Key settings for AIO:

| Variable | Default | Description |
|----------|---------|-------------|
| `API_ENABLED` | `true` | REST API server (required for DCS-UI) |
| `API_PORT` | `9876` | API listen port |
| `API_BIND` | `0.0.0.0` | API bind address (`0.0.0.0` required for container access) |
| `DCS_UI_PORT` | `3000` | Web UI port (published to all interfaces) |
| `TZ` | `UTC` | Timezone |
| `PROXY_DOMAIN` | `example.com` | Domain for Traefik routes |

Restrict DCS-UI to localhost only:
```bash
DCS_UI_PORT=127.0.0.1:3000
```

---

## Updating the Web UI

The DCS-UI container pulls from [GHCR](https://github.com/scotthowson/Docker-Compose-Skeleton-UI/pkgs/container/docker-compose-skeleton-ui). To update:

```bash
docker compose -f Stacks/core-infrastructure/docker-compose.yml pull dcs-ui
docker compose -f Stacks/core-infrastructure/docker-compose.yml up -d dcs-ui
```

Or use `./start.sh` which handles all stacks including image updates.

**What happens on update:**
- New SPA assets are served immediately (Vite content-hashed filenames bust browser cache)
- Auth sessions persist (stored in browser localStorage + host API)
- Server configuration persists (stored on host in `.env` and `.api-auth/`)
- Setup wizard does NOT re-trigger (`.api-auth/.setup-complete` marker is on the host)
- No data loss — the container is stateless; all state lives on the host

---

## Security

| Layer | Protection |
|-------|------------|
| **Authentication** | PBKDF2 password hashing, rate-limited login (5 attempts), 4-hour sessions |
| **API** | Bearer token auth, admin-only endpoints, path traversal guards, SSRF protection |
| **Transport** | HTTP on port 3000 (LAN); HTTPS via Traefik when configured |
| **Container** | nginx security headers (CSP, X-Frame-Options, HSTS), read-only SPA |
| **Docker** | Optional Docker Socket Proxy for restricted API access |

**First-run note:** The Setup Wizard is accessible without authentication until an admin account is created. The first person to complete setup becomes the admin. On a trusted LAN, this is standard for self-hosted applications (same model as Portainer, Nextcloud, etc.).

---

## HTTPS with Traefik

Traefik is available as a template — deploy it from the UI's template browser or via the API:

1. Open **Templates** in the web UI
2. Deploy **Traefik Reverse Proxy** to `networking-security`
3. Enter your domain and Let's Encrypt email
4. DCS-UI becomes available at `https://ui.yourdomain.com`

The Traefik route template (`dcs-ui.yml`) is pre-included and auto-activated when Traefik is deployed.

---

## CLI Commands

```bash
./start.sh                          # Full startup (API + all stacks)
./stop.sh                           # Graceful shutdown
./restart.sh                        # Stop + Start
./status.sh                         # Container status
./setup.sh                          # First-run setup (or re-launch UI)

# Management utilities
.scripts/stack-manager.sh list      # List all stacks
.scripts/maintenance.sh             # System report
.scripts/config-validator.sh --fix  # Validate & fix config
.scripts/docker-network-info.sh     # Network map
.scripts/image-tracker.sh           # Check image freshness
```

---

## Directory Structure

```
Docker-Compose-Skeleton-AIO/
├── start.sh / stop.sh / restart.sh / status.sh    # Entry points
├── setup.sh                                        # First-run setup + DCS-UI launch
├── .env.example                                    # Configuration template
├── .env                                            # Your configuration (created by setup)
├── .scripts/
│   ├── api-server.sh                               # REST API server
│   ├── stack-manager.sh                            # Stack management CLI
│   └── ...                                         # Health, maintenance, network, etc.
├── .lib/                                           # Logger, helpers, Docker utils
├── .templates/                                     # 28+ deployable service templates
│   ├── traefik/                                    # Includes DCS-UI route
│   ├── portainer/
│   └── ...
├── Stacks/
│   ├── core-infrastructure/                        # Redis + DCS-UI (AIO)
│   ├── networking-security/                        # Traefik, Authelia, etc.
│   ├── monitoring-management/                      # Grafana, Prometheus, etc.
│   └── ...                                         # 10 categories total
└── logs/                                           # Runtime logs
```

---

## Differences from Base DCS

| | [DCS](https://github.com/scotthowson/Docker-Compose-Skeleton) | AIO |
|---|---|---|
| Web UI | Separate [Electron app](https://github.com/scotthowson/Docker-Compose-Skeleton-UI) | Built-in (Docker container on port 3000) |
| `core-infrastructure` | Redis only | Redis + DCS-UI |
| `setup.sh` | Prepares files, starts API | Prepares files, starts API + DCS-UI, prints URL |
| `API_ENABLED` | `false` (opt-in) | `true` (required) |
| `API_BIND` | `127.0.0.1` | `0.0.0.0` (container access) |

Everything else is identical. AIO syncs from DCS upstream.

---

## License

MIT

---

Built with [DCS Framework](https://github.com/scotthowson/Docker-Compose-Skeleton) and [DCS Manager UI](https://github.com/scotthowson/Docker-Compose-Skeleton-UI).
