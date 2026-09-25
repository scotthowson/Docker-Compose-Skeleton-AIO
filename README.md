<p align="center">
  <img src="https://img.shields.io/badge/bash-4.0+-4EAA25?style=flat-square&logo=gnubash&logoColor=white" alt="Bash 4+" />
  <img src="https://img.shields.io/badge/docker-compose_v2-2496ED?style=flat-square&logo=docker&logoColor=white" alt="Docker Compose v2" />
  <img src="https://img.shields.io/badge/templates-103-34d399?style=flat-square" alt="103 templates" />
  <img src="https://img.shields.io/badge/API_endpoints-210-06b6d4?style=flat-square" alt="210 API endpoints" />
  <a href="https://github.com/scotthowson/Docker-Compose-Skeleton-AIO/actions/workflows/ci.yml"><img src="https://github.com/scotthowson/Docker-Compose-Skeleton-AIO/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <img src="https://img.shields.io/badge/license-MIT-f472b6?style=flat-square" alt="MIT" />
</p>

# Docker Compose Skeleton — All-In-One

**Your whole homelab, managed from one repository and one browser tab.**

DCS AIO bundles the Docker Compose Skeleton framework with its web UI. One clone, one setup script,
and you get a management dashboard on port 3000, a hardened REST API on port 9876, 103 one-click
service templates, automatic HTTPS routing through Traefik, Cloudflare DNS, optional Authelia SSO,
plugins, schedules, backups and metrics — all driven by plain Bash and Docker Compose.

```bash
git clone https://github.com/scotthowson/Docker-Compose-Skeleton-AIO.git
cd Docker-Compose-Skeleton-AIO
./setup.sh
```

Then open `http://<your-server>:3000` and follow the setup wizard.

---

## What you get

```
Browser ──► DCS-UI (container, :3000) ──/api/──► api-server.sh (:9876, Bash + socat)
                                                    ├─ docker compose  (Stacks/<category>/)
                                                    ├─ templates       (.templates/<name>/)
                                                    ├─ Traefik routes + Cloudflare DNS + DDNS
                                                    ├─ plugins, schedules, automations, webhooks
                                                    └─ metrics, health score, backups, snapshots
```

- **Dependency-ordered stacks** — ten categories start in order and stop in reverse:
  `core-infrastructure → networking-security → monitoring-management → development-tools →
  media-services → web-applications → storage-backup → communication-collaboration →
  entertainment-personal → miscellaneous-services`.
- **103 templates** — deploy Jellyfin, Nextcloud, Grafana, Vaultwarden, Immich and 98 more into any
  stack. Each deployment is security-scanned, port-checked, merged into the stack's compose file,
  given a Traefik route and a Cloudflare CNAME, connected to the proxy network and started.
  Undeploy reverses every step.
- **Wildcard HTTPS** — Traefik with a `*.yourdomain.com` certificate via the Cloudflare DNS
  challenge; every new service is reachable at `service.yourdomain.com` without touching a config.
- **Authelia SSO** — optional single sign-on with 2FA, deployed and configured by the wizard.
- **A real API** — 210 endpoints covering stacks, containers, images, networks, volumes, logs,
  templates, routes, DNS, plugins, schedules, secrets, backups, snapshots, metrics, notifications,
  webhooks, automations, system updates and the web terminal. See [docs/API.md](docs/API.md).
- **Security by default** — accounts are mandatory on any non-loopback bind, a fresh install only
  answers the setup endpoints, viewers cannot change anything, `.env` is never sourced, compose
  files are scanned for privileged containers and dangerous mounts. See [SECURITY.md](SECURITY.md).

---

## Quick start

```bash
git clone https://github.com/scotthowson/Docker-Compose-Skeleton-AIO.git
cd Docker-Compose-Skeleton-AIO
./setup.sh          # creates .env, directories and permissions; checks Docker; starts the API + web UI
```

`setup.sh` prints the URL of the web UI when it is healthy. The wizard then walks through:

1. **Account** — the first admin account (PBKDF2-hashed, rate-limited, optional TOTP).
2. **Configure** — domain, timezone, PUID/PGID, notifications, Traefik, dynamic DNS.
3. **Authelia** — optional SSO with generated configuration and Redis sessions.
4. **Complete** — deploys Traefik (and Authelia), creates DNS records and starts the core stack.

After that:

```bash
./start.sh          # start every stack in dependency order (API first), pull updates, health check
./stop.sh           # stop in reverse order
./status.sh         # what is running
```

The API can also run as a system service:

```bash
.scripts/install-service.sh    # hardened systemd unit, runs as your user in the docker group
```

---

## Requirements

| Dependency | Used for |
|------------|----------|
| Docker Engine + Compose v2 | running the stacks |
| Bash 4+ | every script |
| jq | all JSON handling |
| python3 | PBKDF2 password hashing |
| curl, git, openssl | health checks, updates, TLS and tokens |
| socat (or ncat) | the API listener |

`./setup.sh` checks for Docker and Compose. `./start.sh` checks the remaining tools and offers to
install missing ones through `apt`, `dnf`, `yum`, `pacman`, `zypper` or `xbps`.

---

## Templates

<details>
<summary><strong>All 103 templates by category</strong></summary>

| Category | Templates |
|----------|-----------|
| **Reverse proxies & web** | Traefik, Caddy, Nginx Proxy Manager, Nginx, Cloudflare Tunnel, Cloudflare Dynamic DNS, Docker Socket Proxy |
| **Dashboards & management** | Homarr, Homepage, Dashy, dash., Yacht, Komodo, Portainer CE |
| **Media** | Jellyfin, Plex, Sonarr, Radarr, Lidarr, Readarr, Prowlarr, Bazarr, Tautulli, Seerr, Jellyseerr, Wizarr, Kavita, Calibre-Web, Audiobookshelf, FlareSolverr, qBittorrent, Transmission, SABnzbd |
| **Monitoring** | Grafana, Prometheus, Loki, Uptime Kuma, Netdata, InfluxDB, SpeedTest Tracker, Dozzle, Diun, Healthchecks, Changedetection.io, Watchtower |
| **Storage, photos & backup** | Nextcloud, Nextcloud All-in-One, MinIO, Syncthing, Duplicati, File Browser, Immich |
| **Databases** | PostgreSQL 16, MySQL, MariaDB, MongoDB 7, Redis 7, RedisInsight, Adminer, pgAdmin 4, phpMyAdmin |
| **Productivity & notes** | Memos, Trilium Notes, BookStack, Mealie, Tandoor Recipes, Actual Budget, Firefly III, Vikunja, Planka, Karakeep, Linkwarden, Paperless-ngx, Reactive Resume |
| **Development & automation** | Gitea, Code Server, n8n, Semaphore UI, Home Assistant |
| **Security & network** | Authelia, Vaultwarden, CrowdSec, WireGuard Easy, AdGuard Home, Pi-hole |
| **Communication & publishing** | ntfy, Gotify, FreshRSS, SearXNG, PrivateBin, Flarum, Ghost |
| **Entertainment & gaming** | EmulatorJS, MonkeyType, Your Spotify, Pelican Panel + Wings, RustDesk Server |
| **AI** | Ollama, Open WebUI + Ollama |
| **Tools** | Excalidraw, IT-Tools, Stirling-PDF, Sablier |

</details>

Every template is a directory under `.templates/` with a `docker-compose.yml`, a `template.json`
(variables, ports, category, Traefik settings) and optional config scaffolding. Deploy from the UI,
or from the API:

```bash
curl -s -H "Authorization: Bearer $TOKEN" -X POST http://localhost:9876/templates/jellyfin/deploy \
     -H 'Content-Type: application/json' \
     -d '{"target_stack":"media-services","auto_start":true,"variables":{"MEDIA_PATH":"/srv/media"}}'
```

---

## The API

`.scripts/api-server.sh` is a single Bash program served by `socat`: one process per request,
JSON in and out, no runtime to install. It starts with `setup.sh`/`start.sh` or on its own:

```bash
.scripts/api-server.sh --bind 0.0.0.0        # foreground; --help lists the options
.scripts/api-server.sh --stop
```

- **Accounts and roles** — `admin` can do everything; `user` is a viewer with its own session,
  profile and 2FA. Registration is invite-only.
- **First run** — until the first admin exists only `POST /auth/setup`, the setup status endpoints
  and `GET /version` answer.
- **Behind the UI** — the DCS-UI container proxies `/api/` to the host; `API_TRUSTED_PROXIES`
  tells the API which proxies may set `X-Forwarded-For`, so rate limits and audit logs see the
  real client.
- **Reference** — [docs/API.md](docs/API.md) lists all 210 endpoints with their access level and
  is generated from the router by `.scripts/api-docs.sh`; `GET /` serves the same catalogue.

---

## Commands

| Command | Description |
|---------|-------------|
| `./setup.sh` | First-run setup (`--dry-run`, `--verbose`) |
| `./start.sh` | Start the API and every stack in order, pull updates, run a health check |
| `./stop.sh` | Stop every stack in reverse order and the API (`--force` for a short timeout) |
| `./restart.sh` | Stop then start |
| `./status.sh` | Container status per stack |

<details>
<summary><strong>Management utilities (<code>.scripts/</code>)</strong></summary>

| Script | Description |
|--------|-------------|
| `api-server.sh` | The REST API (`--bind`, `--port`, `--stop`, `--help`) |
| `api-docs.sh` | Regenerate `docs/API.md` and the `GET /` catalogue (`--check` for CI) |
| `install-service.sh` | Install the API as a systemd service |
| `stack-manager.sh` | Start/stop/restart/status/logs/pull for a single stack |
| `health-check.sh` | Container health table |
| `config-validator.sh` | Validate configuration, directories, compose files, ports (`--fix`) |
| `maintenance.sh` | Docker cleanup, disk analysis, orphan detection, log rotation |
| `docker-network-info.sh` | Network map |
| `image-tracker.sh` | Image age and staleness |
| `logs-viewer.sh` | Interactive log viewer |
| `backup-server.sh` | rsync-based server backup |

</details>

---

## Configuration

`setup.sh` copies `.env.example` to `.env` (mode 600). The important keys:

| Key | Default | Meaning |
|-----|---------|---------|
| `API_BIND` / `API_PORT` | `0.0.0.0` / `9876` | where the API listens (authentication is forced on non-loopback binds) |
| `DCS_UI_PORT` | `3000` | web UI port |
| `API_TRUSTED_PROXIES` | `172.16.0.0/12` | proxies allowed to set `X-Forwarded-For` (the Docker bridge range covers DCS-UI) |
| `API_IP_WHITELIST` | empty | comma-separated CIDRs allowed to call the API |
| `API_TLS_ENABLED` / `API_BEHIND_TLS_PROXY` | `false` | serve TLS directly, or mark the API as fronted by Traefik |
| `DOCKER_STACKS` | all ten | the stacks `start.sh`/`stop.sh` manage, in order |
| `LOG_LEVEL`, `ENABLE_COLORS`, `SHOW_BANNERS` | `INFO`, `true`, `true` | console output |

Per-stack settings live in `Stacks/<category>/.env`. Everything has a sensible default in
`.config/settings.cfg`; runtime environment variables override all of it
(`LOG_LEVEL=DEBUG ./start.sh`).

---

## Plugins

Plugins add lifecycle hooks (`pre-deploy`, `post-start`, ...) and dashboard cards. Four ship
enabled-ready in `.plugins/`, and a catalogue of 23 more (deploy guards, backups, monitors,
security audits, notifiers...) lives in `.plugins-catalog/`: install any of them from the Plugins
page or with `POST /plugins/catalog/{name}/install`, then enable it. The hook contract (JSON
context on stdin, the environment a hook sees, timeouts, state directory) and the API are
described in [.plugins/README.md](.plugins/README.md).

---

## Troubleshooting

- **The dashboard says "Connection Unstable" / "Connection Restored" in a loop, or the wizard never
  appeared.** The browser tab holds a session from an earlier install. Reload the page
  (Ctrl+Shift+R) or sign out; with web UI 2.23.1 or newer this happens automatically.
- **`API server failed to start`** after `./setup.sh`: `logs/api-server.log` names the process
  that already holds the port. Stop it or change `API_PORT` in `.env`.
- **After a power loss Traefik is up but no site answers** until it is restarted: the stacks came
  up before Traefik could load its plugins or reach the Docker socket. `start.sh --boot` (what the
  `dcs-stacks` service runs) probes every route once the stacks are healthy and restarts Traefik
  if none answer; `GET /routes/health` shows the probe and `POST /routes/reconcile` runs it now.
- **CrowdSec banned my own address** (the site works from the phone but not from the PC): the
  Protection card on the dashboard has "Unban me" and "Trust my address"; the whitelist follows
  the DDNS/public address every ten minutes, and `CROWDSEC_TRUSTED_IPS` in `.env` pins more.
- **A viewer account gets 403** on an action: by design. Only admins change the system; see
  [docs/API.md](docs/API.md) for the access level of every endpoint.
- **Everything else**: `.scripts/config-validator.sh` checks the installation, `tests/lint.sh` the
  code, and `logs/` holds the API and framework logs.

## Development

```bash
tests/lint.sh       # bash -n, shellcheck, compose validation of every stack and template, API reference freshness
tests/smoke.sh      # 60+ API checks against the request handler in an isolated temporary installation
```

Both run in CI on every push and pull request. After adding or changing a route, run
`.scripts/api-docs.sh` so the reference and the `GET /` catalogue stay in sync. The web UI lives in
its own repository: [Docker-Compose-Skeleton-UI](https://github.com/scotthowson/Docker-Compose-Skeleton-UI).

---

## License

[MIT](LICENSE)
