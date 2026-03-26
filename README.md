<p align="center">
  <img src="https://img.shields.io/badge/bash-4.0+-4EAA25?style=flat-square&logo=gnubash&logoColor=white" />
  <img src="https://img.shields.io/badge/docker-compose-2496ED?style=flat-square&logo=docker&logoColor=white" />
  <img src="https://img.shields.io/badge/templates-100+-34d399?style=flat-square" />
  <img src="https://img.shields.io/badge/API_endpoints-76+-06b6d4?style=flat-square" />
  <img src="https://img.shields.io/badge/security-67%2B_fixes-a78bfa?style=flat-square" />
  <img src="https://img.shields.io/badge/license-MIT-f472b6?style=flat-square" />
</p>

# Docker Compose Skeleton

**Your entire homelab, orchestrated from one framework.**

Deploy 100+ services with one click. Automatic HTTPS routing. Cloudflare DNS. Authelia SSO. Wildcard TLS. Security-hardened API. Customizable dashboard. Setup wizard. All from a single git clone.

```bash
git clone https://github.com/scotthowson/Docker-Compose-Skeleton.git
cd Docker-Compose-Skeleton && ./setup.sh
```

That's it. The setup wizard handles the rest.

---

## Why DCS?

Most homelab setups are a mess of scattered compose files, manual DNS entries, and no central management. DCS gives you:

- **One framework** that manages every service on your server
- **Deploy anything** from 100 templates — Traefik, Plex, Nextcloud, Authelia, Grafana, and more
- **Automatic HTTPS** with wildcard TLS via Cloudflare DNS challenge (one cert, unlimited subdomains)
- **Auto DNS** — deploy a service, get `service.yourdomain.com` in Cloudflare instantly
- **Undeploy cleanup** — removes routes, DNS records, containers, images, and app data
- **Security-first** — 7 rounds of penetration testing, 67+ fixes, compose security scanner
- **37-page management UI** with glassmorphism design, real-time metrics, and drag-and-drop dashboard

---

## Features

### Infrastructure
- **100 Service Templates** — Traefik, Portainer, Jellyfin, Nextcloud, Grafana, Authelia, and 94 more
- **Traefik Auto-Routing** — deploy a template, get automatic HTTPS route + Cloudflare DNS CNAME
- **Wildcard TLS** — single `*.yourdomain.com` certificate covers all subdomains forever
- **Authelia SSO** — single sign-on with 2FA, WebAuthn, and access control — deployed from Setup Wizard
- **Dynamic DNS** — auto-update Cloudflare A record when your public IP changes
- **Dependency-Ordered Startup** — 10 stack categories start in order, shutdown in reverse

### Security
- **Two-Factor Authentication** — TOTP 2FA with authenticator app support
- **Auto-Lock** — screen locks after inactivity, preserves app state, password to unlock
- **Compose Security Scanner** — blocks privileged containers, dangerous mounts, capability escalation
- **PBKDF2-SHA256 Auth** — 100k iterations, rate limiting, invite-only registration
- **7 Rounds of Penetration Testing** — 67+ security fixes applied

### Management
- **76+ API Endpoints** — full remote management of stacks, containers, templates, networks, volumes
- **Auto-Generate Secrets** — encryption keys and JWT secrets created automatically on deploy
- **Plugin System** — custom dashboard cards, lifecycle hooks, and template extensions
- **Encrypted Secrets** — AES-256-CBC key-value store for API keys, passwords, and tokens
- **System Updates** — git-based with backup tags, one-click rollback, factory reset

### Monitoring
- **Health Scoring** — container health monitoring with uptime tracking
- **Resource Trends** — historical CPU, memory, disk usage with charts
- **Push Notifications** — NTFY integration for start, stop, failure, and health events
- **Backup & Restore** — full system snapshots with path traversal protection

---

## Quick Start

```bash
# 1. Clone
git clone https://github.com/scotthowson/Docker-Compose-Skeleton.git
cd Docker-Compose-Skeleton

# 2. Run setup (installs dependencies, creates directories, starts API)
./setup.sh

# 3. Open DCS Manager → connect to your server → complete the 5-step Setup Wizard
#    (creates admin account, configures domain, deploys Traefik + Authelia)

# 4. Start all services
./start.sh
```

### What the Setup Wizard Does

1. **Connect** — enter your server IP, the wizard finds the API
2. **Account** — create your admin account (PBKDF2-hashed, rate-limited)
3. **Configure** — domain, timezone, PUID/PGID, notifications, Traefik, DDNS
4. **Authelia** — optional SSO with auto-generated config, Redis sessions, Argon2id passwords
5. **Complete** — deploys Traefik + Authelia, creates DNS records, starts containers

---

## The Deploy Flow

When you deploy a template, DCS handles everything:

```
Template Deploy
  ├─ Security scan (blocks privileged, dangerous mounts, capabilities)
  ├─ Port conflict detection across all stacks
  ├─ Compose merge (services added to target stack)
  ├─ Variable substitution + secret auto-generation
  ├─ Config file scaffolding (Traefik, Authelia, etc.)
  ├─ Traefik route file creation (custom subdomain support)
  ├─ Cloudflare CNAME auto-creation
  ├─ Proxy network connection
  ├─ Container startup with volume permission fixing
  └─ Deploy event audit logging
```

On undeploy, the reverse:

```
Template Undeploy
  ├─ Container stop + removal
  ├─ Service removed from compose file
  ├─ Traefik route file deleted
  ├─ Cloudflare DNS record deleted
  ├─ App-Data cleanup (optional)
  ├─ Docker image removal (optional)
  └─ Undeploy event audit logging
```

---

## Service Templates

100 ready-to-deploy templates. Deploy via the UI or API.

<details>
<summary><strong>View all 100 templates</strong></summary>

| Category | Templates |
|----------|-----------|
| **Reverse Proxies** | Traefik, Caddy, Nginx Proxy Manager, Cloudflared |
| **Media** | Jellyfin, Plex, Sonarr, Radarr, Lidarr, Readarr, Prowlarr, Bazarr, Tautulli, Seerr, Jellyseerr, qBittorrent, Transmission, SABnzbd, FlareSolverr |
| **Dashboards** | Homarr, Homepage, Dashy, Dashdot, Yacht |
| **Monitoring** | Grafana, Prometheus, Uptime Kuma, Netdata, Loki, InfluxDB, SpeedTest Tracker, Dozzle |
| **Storage** | Nextcloud, Nextcloud AIO, MinIO, Syncthing, Duplicati, FileBrowser |
| **Databases** | PostgreSQL, MySQL, MariaDB, MongoDB, Redis, RedisInsight, Adminer, pgAdmin, phpMyAdmin |
| **Productivity** | Memos, Trilium, BookStack, Mealie, Tandoor, Actual Budget, Firefly III, Vikunja, Planka, Reactive Resume, Karakeep, Linkwarden, Kavita, Calibre-Web, Audiobookshelf, Paperless-ngx |
| **Development** | Gitea, Code Server, n8n, Semaphore |
| **Security** | Authelia, Vaultwarden, CrowdSec, WireGuard, AdGuard Home, Pi-hole, Docker Socket Proxy |
| **Communication** | PrivateBin, Ntfy, Gotify, FreshRSS, SearXNG, Wizarr |
| **Gaming** | EmulatorJS, MonkeyType, Pelican Panel, RustDesk |
| **Infrastructure** | Portainer, Watchtower, Diun, Sablier, Komodo, Home Assistant, Healthchecks |
| **AI** | Ollama, Open WebUI |
| **Web** | Nginx, Ghost, Excalidraw, Stirling PDF, IT-Tools, Immich |
| **DNS** | Cloudflare DDNS |

</details>

---

## REST API

13,700+ line hardened bash API server. 76+ endpoints. Starts on port `9876`.

<details>
<summary><strong>View all endpoint groups</strong></summary>

| Group | Endpoints | Description |
|-------|-----------|-------------|
| **System** | `/status`, `/health`, `/version`, `/system` | Health, metrics, Docker info |
| **Stacks** | `/stacks`, `/stacks/:name/*` | Start, stop, restart, update, rename, clone |
| **Containers** | `/containers`, `/containers/:id/*` | Inspect, logs, exec, file browser, stats |
| **Templates** | `/templates`, `/templates/:name/deploy` | Browse, deploy, import, undeploy |
| **Auth** | `/auth/*` | Login, TOTP 2FA, invite codes, sessions |
| **Networks** | `/networks/*` | Create, remove, connect, disconnect |
| **Volumes** | `/volumes/*` | List, inspect, remove |
| **Logs** | `/logs/*` | Filtering, live streaming, statistics |
| **Backups** | `/backups/*` | Create, restore, status |
| **Plugins** | `/plugins/*` | Install, scaffold, enable, cards |
| **Updates** | `/system/update/*` | Check, apply, rollback |
| **Webhooks** | `/webhooks/*` | Create, test, fire |
| **Automations** | `/automations/*` | Cron-based scheduled tasks |

</details>

---

## Commands

| Command | Description |
|---------|-------------|
| `./setup.sh` | First-run setup with dependency installer |
| `./start.sh` | Start all services in dependency order |
| `./stop.sh` | Graceful shutdown in reverse order |
| `./restart.sh` | Stop then start |
| `./status.sh` | Container status overview |

<details>
<summary><strong>Management utilities</strong></summary>

| Script | Description |
|--------|-------------|
| `.scripts/api-server.sh --bind 0.0.0.0` | Start API server (external access) |
| `.scripts/stack-manager.sh list` | CLI for individual stacks |
| `.scripts/health-check.sh` | Container health monitoring |
| `.scripts/config-validator.sh --fix` | Validate and fix configuration |
| `.scripts/maintenance.sh` | Docker cleanup and disk analysis |
| `.scripts/docker-network-info.sh` | Network visualization |
| `.scripts/image-tracker.sh` | Image freshness tracking |

</details>

---

## DCS Manager UI

A companion 37-page Electron + web app with glassmorphism dark theme.

See [Docker-Compose-Skeleton-UI](https://github.com/scotthowson/Docker-Compose-Skeleton-UI).

**Pages:** Dashboard, Containers, Stacks, Templates, Health, Uptime, Trends, Networks, Volumes, Images, Logs, Terminal, Export, Settings, Users, Plugins, Notifications, Automations, Schedules, Secrets, Snapshots, Backup, File Browser, Environment, Config, Diagnostics, Disk Analysis, Topology, Event Feed, Bookmarks, Activity, Updates, System, Login, Setup Wizard

---

## Requirements

| Dependency | Purpose |
|------------|---------|
| **Docker + Compose v2** | Container runtime |
| **Bash 4+** | Framework scripts |
| **jq** | JSON processing |
| **python3** | Password hashing |
| **curl, git, openssl** | Health checks, updates, tokens |
| **socat** or **ncat** | API server listener |

`./setup.sh` auto-installs everything. Supports Ubuntu, Debian, Fedora, RHEL, Arch, Alpine, openSUSE, Void, NixOS.

---

## License

MIT
