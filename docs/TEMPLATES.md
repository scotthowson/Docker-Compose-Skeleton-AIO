<sub>[← Hub in an LXC container](INSTALL-LXC.md) · [Docs index](README.md) · Next: [Configuration →](CONFIGURATION.md)</sub>

# Templates

A template is a ready Compose service with a form around it. Pick one, fill in a few fields, and DCS
merges it into a stack, gives it a route, a DNS record and a login portal, and starts it. Every template
was deployed and watched until healthy before it shipped, and each description says what to do after
the first start.

- [How a template becomes a stack](#how-a-template-becomes-a-stack)
- [Authelia per route](#authelia-per-route)
- [Start on demand](#start-on-demand)
- [Templates in a fleet](#templates-in-a-fleet)
- [The catalogue](#the-catalogue)
- [template.json reference](#templatejson-reference)
- [Keeping this page up to date](#keeping-this-page-up-to-date)

## How a template becomes a stack

1. **Choose.** On the **Templates** page, open a card and press **Deploy** (admins only).
2. **Fill in the deploy sheet.**
   - *Stack*: where it lands. The template's own stack is preselected.
   - *Variables*: ports, paths, passwords. Defaults come from the template; an empty secret is filled with
     64 random hex characters.
   - *Optional services*: parts you can leave out, such as Traefik's Docker socket proxy.
   - *Per route*: behind Authelia or not, start on demand or not, and whether to add it to Homarr.
3. **Preview** (optional). The preview lists name and port conflicts, the variables and anything the
   security scan found, without changing a thing.
4. **Deploy.** DCS works through these steps, and stops with the reason when one fails:

   | Step | What happens |
   |---|---|
   | Variables | Required ones checked; values with line breaks or shell characters refused; empty secrets generated |
   | Security scan | The compose is checked for privileged mode, host namespaces, dangerous mounts and capabilities |
   | Conflicts | A second copy of a one-per-host template is refused, and so are clashing service names and host ports |
   | Merge | The stack's `docker-compose.yml` is backed up, the services, volumes and networks are merged in, and the result is validated (the backup comes back if it is invalid); new variables go to the stack's `.env` |
   | Config files | The template's `config/` files are copied into the app's `App-Data` folder, never over files that exist |
   | Route and DNS | A Traefik route for `<name>.<your-domain>`, a Cloudflare record, the Authelia and Sablier middlewares you chose, a Homarr tile if asked |
   | Start | The new services are pulled, created and started, and followed until they are healthy |

5. **Use it.** Open it at its port or at `https://<name>.<your-domain>`. The container's page has its logs,
   a shell, its environment and **Nuke & reinstall**.

**Undeploy** takes the template's services out of the stack and removes their containers. On request it
also removes their data, their images and their routes.

The same from the API, with an admin token:

```bash
curl -s -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -X POST http://localhost:9876/templates/jellyfin/deploy \
  -d '{"target_stack":"media-services","auto_start":true,"variables":{"MEDIA_PATH":"/srv/media"}}'
```

Other fields the deploy takes: `exclude_services`, `container_names` (`{service: name}`),
`authelia_services`, `on_demand_services`, `add_to_homarr`, `replace_services`. `POST /templates/{name}/dry-run`
is the preview, `POST /templates/{name}/undeploy` the way back. [API reference](API.md#templates) has them all.

## Authelia per route

Once the **Authelia** template is deployed, every new route goes behind its login portal (with 2FA),
unless you say otherwise:

- Templates whose apps bring their own clients stay open by default: Plex, Jellyfin, Nextcloud, Immich,
  Vaultwarden, the *arr apps, ntfy, Gitea, MinIO and others. The catalogue marks them **Own sign-in**
  (`"auth": "bypass"` in their `template.json`), because a phone app or a TV cannot pass a web portal.
- The deploy sheet has a switch per route, and its choice always wins.
- Routes that existed before Authelia was deployed go behind it when it arrives.

Protecting a route needs Authelia first; without it the deploy answers *Protecting a route needs
Authelia: deploy the Authelia template first*.

## Start on demand

With the **Sablier** template deployed, an app can sleep while nobody uses it and wake on the first visit.

- Choose it per service on the deploy sheet, or later with **Start on demand** on the container's page.
- Pick how long it may idle (5 minutes to 12 hours) and the waiting page visitors see (ghost, shuffle,
  hacker-terminal, matrix).
- DCS puts the Sablier middleware last in the route's chain, so a visitor passes CrowdSec and Authelia
  before anything wakes up.
- Health, Uptime and the Containers page show such apps as **on demand**, not stopped, and they raise
  no "container stopped" alert. Prunes leave them alone.

## Templates in a fleet

On a hub, the deploy sheet also lists the stacks that live in VMs. A deploy into one of them goes to
that VM's DCS, with your own role checked on the hub first. The hub's Traefik serves the new route, and
the hub keeps your Authelia choice for it. *Start on demand* is not offered for a VM's stack: Sablier runs
on the hub and can only wake the hub's own containers. **Deploy here** on the Proxmox page opens the
sheet with that VM's stack chosen.

## The catalogue

**Port** is the default host port to open (you can change it when you deploy). **Stack** is where the
template lands unless you pick another. **Notes**: *Own sign-in* stays out of Authelia by default,
*One per host* can be deployed once per server, *Not routed* services keep a plain port (games, voice,
MQTT, DNS), *Optional* services can be left out.

<!-- templates:begin (generated by docs/tools/gen-templates.sh, do not edit by hand) -->
**151 templates** in 13 categories, grouped the way the dashboard's Templates page groups them.

| Category | Templates | For example |
|---|---:|---|
| 🎬 [Media](#media) | 22 | Jellyfin Media Server, Plex Media Server, Immich, Sonarr |
| 📈 [Monitoring](#monitoring) | 20 | Grafana, Uptime Kuma, Prometheus, Netdata |
| 🌐 [Web](#web) | 15 | Traefik Reverse Proxy, Nginx Proxy Manager, WordPress, Caddy Web Server |
| 🗄️ [Databases](#databases) | 12 | PostgreSQL 16, MariaDB, Redis 7, MongoDB 7 |
| 🛠️ [Development](#development) | 6 | Gitea, Code Server, Docker Registry, JupyterLab |
| 🧰 [Tools](#tools) | 11 | IT-Tools, Stirling-PDF, Apache Guacamole, BentoPDF |
| 📝 [Productivity](#productivity) | 19 | Paperless-ngx, Mealie, BookStack, Actual Budget |
| ⚙️ [Automation](#automation) | 12 | n8n, Home Assistant, Node-RED, ntfy |
| 🛡️ [Security](#security) | 7 | Vaultwarden, Authelia, CrowdSec, WireGuard Easy |
| 🔌 [Network](#network) | 6 | Pi-hole, AdGuard Home, Cloudflare Tunnel, Komodo |
| 💾 [Storage](#storage) | 7 | Nextcloud, MinIO Object Storage, Duplicati, File Browser |
| ⬇️ [Download](#download) | 4 | qBittorrent, SABnzbd, MeTube, Transmission |
| 🎮 [Entertainment](#entertainment) | 10 | Minecraft Server, Ollama (Standalone), Open WebUI + Ollama, EmulatorJS |

### Media

| Template | What it does | Port | Stack | Notes |
|---|---|---|---|---|
| 🎧 **Audiobookshelf**<br>[`audiobookshelf`](../.templates/audiobookshelf) | Self-hosted audiobook and podcast server with a beautiful player | 13378 | `media-services` | Own sign-in |
| 💬 **Bazarr**<br>[`bazarr`](../.templates/bazarr) | Automated subtitle manager for Sonarr and Radarr | 6767 | `media-services` | Own sign-in |
| 📚 **Calibre-Web**<br>[`calibre-web`](../.templates/calibre-web) | Web interface for browsing, reading, and downloading ebooks from a Calibre library | 8083 | `media-services` | Own sign-in |
| ☁️ **FlareSolverr**<br>[`flaresolverr`](../.templates/flaresolverr) | Proxy server that solves Cloudflare and DDoS-GUARD challenges for Prowlarr and other \*arr apps | 8191 | `media-services` |  |
| 📰 **FreshRSS**<br>[`freshrss`](../.templates/freshrss) | Self-hosted RSS feed aggregator with a rich web UI | 8096 | `web-applications` |  |
| 👻 **Ghost**<br>[`ghost`](../.templates/ghost) | Professional publishing platform for blogs and newsletters | 2368 | `web-applications` |  |
| 📸 **Immich**<br>[`immich`](../.templates/immich) | Self-hosted Google Photos replacement with mobile auto-backup, face recognition, smart search, and shared albums | 2283 | `storage-backup` | Own sign-in |
| 🎬 **Jellyfin Media Server**<br>[`jellyfin`](../.templates/jellyfin) | Jellyfin open-source media server for streaming movies, TV shows, and music | 8096 | `media-services` | Own sign-in |
| 🎬 **Jellyseerr**<br>[`jellyseerr`](../.templates/jellyseerr) | Media request management for Jellyfin and Emby — fork of Overseerr tailored for non-Plex media servers | 5056 | `media-services` | Own sign-in |
| 📕 **Kavita**<br>[`kavita`](../.templates/kavita) | Fast, feature-rich reading server for manga, comics, and ebooks | 5050 | `media-services` | Own sign-in |
| 📚 **Komga**<br>[`komga`](../.templates/komga) | Komga serves comics, manga and ebooks (CBZ, CBR, PDF, EPUB) to the browser and to apps like Tachiyomi/Mihon and Panels | 25600 | `media-services` | Own sign-in |
| 🎵 **Lidarr**<br>[`lidarr`](../.templates/lidarr) | Automated music collection manager — the music counterpart to Sonarr/Radarr | 8686 | `media-services` | Own sign-in |
| 🎵 **Navidrome**<br>[`navidrome`](../.templates/navidrome) | Navidrome streams your music collection to the browser and to any Subsonic app (Symfonium, play:Sub, DSub, Ultrasonic…) | 4533 | `media-services` | Own sign-in |
| 🌄 **PhotoPrism**<br>[`photoprism`](../.templates/photoprism) | PhotoPrism indexes your photo library with face recognition, maps and automatic tagging, all on your own hardware | 2342 | `storage-backup` | Own sign-in |
| 📺 **Plex Media Server**<br>[`plex`](../.templates/plex) | Plex Media Server with LinuxServer.io image — organize and stream your personal media collection with hardware transcoding support | 32400 | `media-services` | Own sign-in |
| 🔍 **Prowlarr**<br>[`prowlarr`](../.templates/prowlarr) | Indexer manager for the \*arr stack — centralizes all indexer/tracker configuration and syncs them to Sonarr, Radarr, Lidarr, and Readarr automatically | 9696 | `media-services` | Own sign-in |
| 🎬 **Radarr**<br>[`radarr`](../.templates/radarr) | Automated movie management — monitors RSS feeds, searches indexers, and manages your movie library | 7878 | `media-services` | Own sign-in |
| 📚 **Readarr**<br>[`readarr`](../.templates/readarr) | Automated ebook and audiobook manager — the book counterpart to Sonarr/Radarr | 8787 | `media-services` | Own sign-in |
| 🎬 **Seerr**<br>[`seerr`](../.templates/seerr) | Modern media request management and discovery tool | 5055 | `media-services` |  |
| 📺 **Sonarr**<br>[`sonarr`](../.templates/sonarr) | Automated TV series management — monitors RSS feeds, searches indexers, and manages your library | 8989 | `media-services` | Own sign-in |
| 📊 **Tautulli**<br>[`tautulli`](../.templates/tautulli) | Monitoring and tracking tool for Plex Media Server | 8181 | `media-services` | Own sign-in |
| 🧙 **Wizarr**<br>[`wizarr`](../.templates/wizarr) | Automated user invitation system for Plex, Jellyfin, and Emby | 5690 | `media-services` |  |

### Monitoring

| Template | What it does | Port | Stack | Notes |
|---|---|---|---|---|
| 📊 **Beszel**<br>[`beszel`](../.templates/beszel) | Beszel is a lightweight server monitor: CPU, memory, disk, network and per-container stats with history and alerts, in a few MB of RAM | 8790 | `monitoring-management` |  |
| 📡 **Beszel Agent**<br>[`beszel-agent`](../.templates/beszel-agent) | The agent side of Beszel: reports this host and its containers to a Beszel hub | 45876 | `monitoring-management` |  |
| 👁️ **Changedetection.io**<br>[`changedetection`](../.templates/changedetection) | Monitor any website for changes — price drops, restocks, content updates, page outages | 5050 | `monitoring-management` |  |
| ⚡ **dash.**<br>[`dashdot`](../.templates/dashdot) | Minimal, beautiful server dashboard showing CPU, RAM, storage, and network at a glance | 3001 | `monitoring-management` |  |
| 🏠 **Dashy**<br>[`dashy`](../.templates/dashy) | Feature-rich homelab dashboard with status checking, widgets, themes, icon packs, and multi-page layouts | 4000 | `web-applications` | One per host |
| 🔄 **Diun**<br>[`diun`](../.templates/diun) | Docker Image Update Notifier — monitors your running containers and alerts you when newer versions are available on the registry | — | `monitoring-management` |  |
| 📜 **Dozzle**<br>[`dozzle`](../.templates/dozzle) | Lightweight real-time Docker container log viewer | 9999 | `monitoring-management` |  |
| 🟢 **Gatus**<br>[`gatus`](../.templates/gatus) | Gatus is a status page that checks your endpoints on a schedule (HTTP, TCP, DNS, ICMP, TLS expiry) and alerts on Discord, ntfy, Slack and more | 8480 | `monitoring-management` |  |
| 📊 **Grafana**<br>[`grafana`](../.templates/grafana) | Grafana open-source analytics and monitoring dashboards | 3200 | `monitoring-management` |  |
| 📋 **Grafana Loki**<br>[`loki`](../.templates/loki) | Horizontally-scalable log aggregation system | 3100 | `monitoring-management` |  |
| 💓 **Healthchecks**<br>[`healthchecks`](../.templates/healthchecks) | Cron job monitoring service — listens for pings from your scheduled tasks and alerts when they don't arrive on time | 8001 | `monitoring-management` |  |
| 📈 **Jellystat**<br>[`jellystat`](../.templates/jellystat) | Jellystat is Tautulli for Jellyfin: watch history, most played, active streams and library statistics | 3008 | `media-services` |  |
| 📈 **Netdata**<br>[`netdata`](../.templates/netdata) | Real-time performance monitoring with per-second granularity | 19999 | `monitoring-management` | One per host |
| 🔋 **NUT UPS Server**<br>[`nut-upsd`](../.templates/nut-upsd) | Network UPS Tools server for a USB-connected UPS | 3493 | `monitoring-management` |  |
| 📊 **Portainer CE**<br>[`portainer`](../.templates/portainer) | Lightweight Docker management UI with real-time container monitoring, stack deployment, image management, and multi-environment support | 9443 | `monitoring-management` | One per host |
| 🔥 **Prometheus**<br>[`prometheus`](../.templates/prometheus) | Prometheus time-series metrics collection and alerting system | 9090 | `monitoring-management` |  |
| 🔭 **Prometheus exporters**<br>[`prometheus-exporters`](../.templates/prometheus-exporters) | Node Exporter (host CPU, memory, disks, network) and cAdvisor (per-container resources) for the Prometheus template | 9100 | `monitoring-management` |  |
| 💽 **Scrutiny**<br>[`scrutiny`](../.templates/scrutiny) | Scrutiny reads S.M.A.R.T. data from every disk and NVMe on this host, keeps the history and warns before a drive fails, with a clean dashboard | 8482 | `monitoring-management` |  |
| 🏎️ **SpeedTest Tracker**<br>[`speedtest-tracker`](../.templates/speedtest-tracker) | Self-hosted internet speed test tracker that runs automated Ookla speedtests and displays results in a beautiful dashboard with historical graphs | 8765 | `monitoring-management` |  |
| 📡 **Uptime Kuma**<br>[`uptime-kuma`](../.templates/uptime-kuma) | Uptime Kuma self-hosted uptime monitoring tool with status pages and notifications | 3001 | `monitoring-management` |  |

### Web

| Template | What it does | Port | Stack | Notes |
|---|---|---|---|---|
| 🔒 **Caddy Web Server**<br>[`caddy`](../.templates/caddy) | Caddy modern web server with automatic HTTPS and reverse proxy capabilities | 80 | `networking-security` |  |
| 🌐 **Cloudflare Dynamic DNS**<br>[`cloudflare-ddns`](../.templates/cloudflare-ddns) | Automatically detects your public IP and updates Cloudflare DNS records when it changes | — | `networking-security` |  |
| 🔒 **Docker Socket Proxy**<br>[`docker-socket-proxy`](../.templates/docker-socket-proxy) | Secure Docker socket proxy that restricts API access to read-only operations, protecting your Docker daemon from unauthorized commands | 2375 | `core-infrastructure` | One per host |
| 💬 **Flarum Forum**<br>[`flarum`](../.templates/flarum) | Modern, fast, and free community forum platform | 8090 | `web-applications` | Optional: `flarum-db` |
| 🧭 **Homarr**<br>[`homarr`](../.templates/homarr) | Modern dashboard for managing and monitoring your server with Docker integration, service bookmarks, and system stats | 7575 | `web-applications` | One per host |
| 🏡 **Homepage**<br>[`homepage`](../.templates/homepage) | Homepage modern self-hosted application dashboard with service widgets and Docker integration | 3400 | `web-applications` | One per host |
| 💬 **Mattermost**<br>[`mattermost`](../.templates/mattermost) | Mattermost Team Edition: a self-hosted Slack — channels, threads, calls, file sharing and integrations, with PostgreSQL | 8065 | `communication-collaboration` |  |
| 🎙️ **Mumble Server**<br>[`mumble`](../.templates/mumble) | Mumble is low-latency, encrypted voice chat for gaming and teams, with channels and permissions | 64738 | `communication-collaboration` | Not routed: `mumble` |
| ☁️ **Nextcloud All-in-One**<br>[`nextcloud-aio`](../.templates/nextcloud-aio) | Full-featured Nextcloud deployment with automatic updates, built-in Collabora Office, Talk, backups, and GPU acceleration | 8080 | `web-applications` | Routed as `cloud` to port 11000 |
| 🌐 **Nginx Proxy Manager**<br>[`nginx-proxy-manager`](../.templates/nginx-proxy-manager) | Full-featured reverse proxy manager with a beautiful web UI for managing SSL certificates, proxy hosts, redirections, and access lists | 81 | `networking-security` |  |
| 🌐 **Nginx Web Server**<br>[`nginx-web`](../.templates/nginx-web) | High-performance web server and reverse proxy | 8080 | `web-applications` |  |
| 🔗 **Shlink**<br>[`shlink`](../.templates/shlink) | Shlink is a URL shortener with visit statistics, QR codes and an API, plus the web client to manage links in the browser | 8381 | `web-applications` |  |
| 🔀 **Traefik Reverse Proxy**<br>[`traefik`](../.templates/traefik) | Modern reverse proxy and load balancer with automatic SSL via Let's Encrypt, Docker integration, Cloudflare DNS challenge, and a file-based routing system organized by stack category | 8180 | `networking-security` | One per host · Optional: `docker-socket-proxy` |
| 📉 **Umami**<br>[`umami`](../.templates/umami) | Umami is privacy-friendly web analytics (no cookies, GDPR-clean) for your own sites | 3013 | `web-applications` |  |
| 🅦 **WordPress**<br>[`wordpress`](../.templates/wordpress) | WordPress with its own MariaDB: the first visit runs the famous five-minute install | 8280 | `web-applications` |  |

### Databases

| Template | What it does | Port | Stack | Notes |
|---|---|---|---|---|
| 🔧 **Adminer**<br>[`adminer`](../.templates/adminer) | Lightweight database management in a single PHP file | 8097 | `development-tools` |  |
| 📊 **InfluxDB**<br>[`influxdb`](../.templates/influxdb) | Purpose-built time-series database for metrics, events, and analytics | 8086 | `monitoring-management` |  |
| 🗄️ **MariaDB**<br>[`mariadb`](../.templates/mariadb) | Community-developed MySQL fork with enhanced performance, security features, and storage engines | 3306 | `core-infrastructure` |  |
| 🔍 **Meilisearch**<br>[`meilisearch`](../.templates/meilisearch) | Meilisearch is a fast, typo-tolerant search engine with a simple REST API, used by apps like Karakeep, Linkwarden and your own projects | 7700 | `development-tools` |  |
| 📊 **Metabase**<br>[`metabase`](../.templates/metabase) | Metabase builds dashboards and charts on top of your databases (PostgreSQL, MySQL, SQLite, and more) with a point-and-click query builder | 3014 | `development-tools` |  |
| 🍃 **MongoDB 7**<br>[`mongodb`](../.templates/mongodb) | MongoDB 7 NoSQL document database with authentication and persistent storage | 27017 | `development-tools` |  |
| 🐬 **MySQL**<br>[`mysql`](../.templates/mysql) | Popular open-source relational database with comprehensive SQL support, replication, and robust data integrity | 3306 | `development-tools` |  |
| 🧮 **NocoDB**<br>[`nocodb`](../.templates/nocodb) | NocoDB turns a database into a spreadsheet-like workspace: tables, forms, kanban, galleries, API and webhooks — an open-source Airtable | 8470 | `development-tools` |  |
| 🐘 **pgAdmin 4**<br>[`pgadmin`](../.templates/pgadmin) | Comprehensive PostgreSQL management platform with query tool, ERD designer, backup/restore, performance dashboards, and server monitoring | 5050 | `development-tools` |  |
| 🐘 **phpMyAdmin**<br>[`phpmyadmin`](../.templates/phpmyadmin) | Web-based MySQL and MariaDB administration tool with an intuitive interface for managing databases, tables, users, and running SQL queries | 8090 | `development-tools` |  |
| 🐘 **PostgreSQL 16**<br>[`postgresql`](../.templates/postgresql) | PostgreSQL 16 relational database with persistent storage and health checks | 5432 | `development-tools` |  |
| 🔴 **Redis 7**<br>[`redis`](../.templates/redis) | Redis 7 in-memory data store with optional password authentication | 6379 | `development-tools` |  |

### Development

| Template | What it does | Port | Stack | Notes |
|---|---|---|---|---|
| 💻 **Code Server**<br>[`code-server`](../.templates/code-server) | VS Code running in your browser | 8443 | `development-tools` |  |
| 🗄️ **Docker Registry**<br>[`docker-registry`](../.templates/docker-registry) | A private Docker image registry with a web UI to browse, inspect and delete images | 5002 | `development-tools` | Not routed: `registry` |
| 🍵 **Gitea**<br>[`gitea`](../.templates/gitea) | Gitea lightweight self-hosted Git service with web interface and API | 3300 | `development-tools` | Own sign-in |
| 🪐 **JupyterLab**<br>[`jupyter`](../.templates/jupyter) | JupyterLab notebooks (Python, with pip and conda available) served from your own server | 8889 | `development-tools` |  |
| 📬 **Mailpit**<br>[`mailpit`](../.templates/mailpit) | Mailpit catches every e-mail your apps send (SMTP on port 1025, any login accepted) and shows it in a web inbox with HTML, source and spam-score views | 8025 | `development-tools` |  |
| 🔍 **RedisInsight**<br>[`redisinsight`](../.templates/redisinsight) | Official Redis GUI for visualizing and optimizing Redis data, monitoring performance, and managing Redis instances with an intuitive browser-based interface | 5540 | `development-tools` |  |

### Tools

| Template | What it does | Port | Stack | Notes |
|---|---|---|---|---|
| 🖥️ **Apache Guacamole**<br>[`guacamole`](../.templates/guacamole) | Guacamole is a clientless remote desktop gateway: RDP, VNC and SSH sessions in the browser, all in one image with its own database | 8660 | `miscellaneous-services` |  |
| 🍱 **BentoPDF**<br>[`bentopdf`](../.templates/bentopdf) | Privacy-first PDF toolkit that runs entirely in the browser | 8087 | `development-tools` |  |
| 🤖 **DCS Discord Bot**<br>[`discord-bot`](../.templates/discord-bot) | Slash commands for this server from Discord, with buttons and confirmations | — | `monitoring-management` |  |
| 🎨 **Excalidraw**<br>[`excalidraw`](../.templates/excalidraw) | Virtual whiteboard for sketching diagrams with a hand-drawn feel | 3380 | `development-tools` |  |
| 🧰 **IT-Tools**<br>[`it-tools`](../.templates/it-tools) | Collection of 100+ handy developer utilities in a beautiful web interface | 8092 | `development-tools` |  |
| 📋 **PrivateBin**<br>[`privatebin`](../.templates/privatebin) | Minimalist, open-source online pastebin where the server has zero knowledge of pasted data | 8888 | `communication-collaboration` |  |
| 📝 **Reactive Resume**<br>[`reactive-resume`](../.templates/reactive-resume) | Free, privacy-first resume builder | 3200 | `web-applications` |  |
| 🖥️ **RustDesk Server**<br>[`rustdesk`](../.templates/rustdesk) | Self-hosted remote desktop server — open-source TeamViewer/AnyDesk alternative | — | `miscellaneous-services` |  |
| ⏱️ **Sablier**<br>[`sablier`](../.templates/sablier) | Sablier on-demand container scaling that starts containers when traffic arrives and stops them after idle timeout | — | `core-infrastructure` |  |
| 📄 **Stirling-PDF**<br>[`stirling-pdf`](../.templates/stirling-pdf) | Powerful self-hosted PDF manipulation toolkit with 50+ tools — merge, split, convert, compress, sign, OCR, redact, and more | 8088 | `development-tools` |  |
| 🪟 **Webtop**<br>[`webtop`](../.templates/webtop) | A full Linux desktop (Alpine XFCE by default) in a browser tab, from LinuxServer | 3016 | `miscellaneous-services` |  |

### Productivity

| Template | What it does | Port | Stack | Notes |
|---|---|---|---|---|
| 💰 **Actual Budget**<br>[`actual-budget`](../.templates/actual-budget) | Super fast, privacy-focused personal finance app with envelope budgeting, bank sync, powerful rules, and beautiful reports | 5006 | `entertainment-personal` |  |
| 📅 **Baïkal**<br>[`baikal`](../.templates/baikal) | Baïkal is a small CalDAV and CardDAV server: calendars and contacts that sync with iOS, Android (DAVx⁵), Thunderbird and macOS | 8900 | `communication-collaboration` |  |
| 📖 **BookStack**<br>[`bookstack`](../.templates/bookstack) | Open-source wiki platform for organizing and storing information | 6875 | `web-applications` |  |
| 📐 **draw.io**<br>[`drawio`](../.templates/drawio) | The diagrams.net editor served from your own server: flowcharts, network and architecture diagrams, saved to your disk or your Nextcloud | 8290 | `communication-collaboration` |  |
| 🔥 **Firefly III**<br>[`firefly-iii`](../.templates/firefly-iii) | Self-hosted personal finance manager | 8084 | `entertainment-personal` |  |
| 🥕 **Grocy**<br>[`grocy`](../.templates/grocy) | Grocy is the household ERP: stock and expiry tracking with barcodes, shopping lists, chores, meal planning, recipes and batteries | 9283 | `entertainment-personal` |  |
| 📦 **Homebox**<br>[`homebox`](../.templates/homebox) | Homebox keeps an inventory of the things you own: locations, labels, warranties, receipts, QR labels for storage boxes and a fast search | 7745 | `entertainment-personal` |  |
| 🔖 **Karakeep**<br>[`karakeep`](../.templates/karakeep) | AI-powered bookmark manager for links, notes, images, and PDFs | 3010 | `communication-collaboration` |  |
| 🔗 **Linkwarden**<br>[`linkwarden`](../.templates/linkwarden) | Collaborative bookmark manager that preserves webpages as screenshots and PDFs | 3020 | `communication-collaboration` |  |
| 🍽️ **Mealie**<br>[`mealie`](../.templates/mealie) | Beautiful recipe manager with meal planning, shopping lists, and automatic import from any recipe URL | 9925 | `entertainment-personal` | Own sign-in |
| 📝 **Memos**<br>[`memos`](../.templates/memos) | Lightweight, self-hosted note-taking hub | 5230 | `communication-collaboration` |  |
| 💎 **Obsidian LiveSync**<br>[`obsidian-livesync`](../.templates/obsidian-livesync) | A CouchDB tuned for the Self-hosted LiveSync plugin, so your Obsidian vaults sync between every device through your own server | 5984 | `communication-collaboration` |  |
| 📝 **ONLYOFFICE Docs**<br>[`onlyoffice`](../.templates/onlyoffice) | ONLYOFFICE Document Server edits Word, Excel and PowerPoint files in the browser, with live co-editing | 8300 | `communication-collaboration` |  |
| 📑 **Paperless-ngx**<br>[`paperless-ngx`](../.templates/paperless-ngx) | Scan, index, and archive all your paper documents | 8010 | `storage-backup` | Own sign-in |
| 📌 **Planka**<br>[`planka`](../.templates/planka) | Elegant Kanban board for project tracking — clean Trello alternative with real-time updates, file attachments, due dates, labels, and team collaboration | 1337 | `communication-collaboration` |  |
| 👨‍🍳 **Tandoor Recipes**<br>[`tandoor`](../.templates/tandoor) | Advanced recipe manager with meal planning, shopping lists, ingredient management, nutrition info, and multi-user households | 8099 | `entertainment-personal` |  |
| 🧠 **Trilium Notes**<br>[`trilium`](../.templates/trilium) | Hierarchical note-taking app built for large personal knowledge bases | 8082 | `communication-collaboration` |  |
| ✅ **Vikunja**<br>[`vikunja`](../.templates/vikunja) | Open-source task management — lists, Kanban boards, Gantt charts, calendars, and team collaboration | 3456 | `communication-collaboration` |  |
| 📖 **Wiki.js**<br>[`wikijs`](../.templates/wikijs) | Wiki.js is a modern wiki with Markdown and visual editors, page history, search, permissions and many login providers, backed by PostgreSQL | 3012 | `communication-collaboration` |  |

### Automation

| Template | What it does | Port | Stack | Notes |
|---|---|---|---|---|
| 🔌 **ESPHome**<br>[`esphome`](../.templates/esphome) | ESPHome dashboard: write YAML for ESP32/ESP8266 boards, compile and flash them over USB or over the air, and they show up in Home Assistant | 6052 | `miscellaneous-services` |  |
| 📹 **Frigate NVR**<br>[`frigate`](../.templates/frigate) | Frigate, the open-source NVR with real-time object detection for IP cameras | 8971 | `miscellaneous-services` | Own sign-in · Not routed: `frigate-rtsp` |
| 📨 **Gotify**<br>[`gotify`](../.templates/gotify) | Simple, self-hosted push notification server with a REST API and web/Android clients | 8094 | `communication-collaboration` | Own sign-in |
| 🏠 **Home Assistant**<br>[`home-assistant`](../.templates/home-assistant) | Home Assistant open-source home automation platform with local control and privacy | 8123 | `miscellaneous-services` | Own sign-in |
| 📡 **Mosquitto MQTT**<br>[`mosquitto`](../.templates/mosquitto) | Eclipse Mosquitto, the MQTT broker Home Assistant, Zigbee2MQTT, ESPHome, Frigate and most smart-home services talk to | 1883 | `miscellaneous-services` | Not routed: `mosquitto` |
| ⚡ **n8n**<br>[`n8n`](../.templates/n8n) | Powerful workflow automation platform — self-hosted Zapier/Make alternative | 5678 | `development-tools` |  |
| 🔴 **Node-RED**<br>[`node-red`](../.templates/node-red) | Node-RED, flow-based automation: wire MQTT, HTTP, Home Assistant, timers and devices together in the browser | 1880 | `miscellaneous-services` |  |
| 🔔 **ntfy**<br>[`ntfy`](../.templates/ntfy) | Simple HTTP-based push notification server | 8093 | `communication-collaboration` | Own sign-in |
| 🚀 **Semaphore UI**<br>[`semaphore`](../.templates/semaphore) | Modern web UI for running Ansible playbooks, Terraform, Bash scripts, and more | 3033 | `development-tools` |  |
| 🔄 **Syncthing**<br>[`syncthing`](../.templates/syncthing) | Peer-to-peer file synchronization — keeps folders in sync across devices without a cloud middleman | 8384 | `storage-backup` |  |
| 🗼️ **Watchtower**<br>[`watchtower`](../.templates/watchtower) | Automatic Docker container updater that monitors running containers, pulls new images, and gracefully restarts services with the latest version | — | `core-infrastructure` | One per host |
| 🐝 **Zigbee2MQTT**<br>[`zigbee2mqtt`](../.templates/zigbee2mqtt) | Zigbee2MQTT bridges a Zigbee USB coordinator (Sonoff Dongle Plus, SkyConnect, ConBee…) to MQTT with a web frontend and Home Assistant discovery | 8081 | `miscellaneous-services` |  |

### Security

| Template | What it does | Port | Stack | Notes |
|---|---|---|---|---|
| 🛡️ **Authelia**<br>[`authelia`](../.templates/authelia) | SSO and two-factor authentication for all your services | 9091 | `networking-security` | One per host |
| 🛡️ **CrowdSec**<br>[`crowdsec`](../.templates/crowdsec) | Intrusion detection from Traefik's access log with the CrowdSec community blocklists | 8070 | `networking-security` |  |
| 🛰️ **Headscale**<br>[`headscale`](../.templates/headscale) | Headscale is a self-hosted Tailscale control server: your own mesh VPN with MagicDNS and no account at Tailscale | 8585 | `networking-security` | Own sign-in |
| 🔎 **SearXNG**<br>[`searxng`](../.templates/searxng) | Privacy-respecting metasearch engine | 8888 | `web-applications` |  |
| 🔗 **Tailscale**<br>[`tailscale`](../.templates/tailscale) | Joins this host to your Tailscale network (or a Headscale one) so you reach it from anywhere without opening ports | — | `networking-security` |  |
| 🔐 **Vaultwarden**<br>[`vaultwarden`](../.templates/vaultwarden) | Lightweight, self-hosted Bitwarden-compatible password manager written in Rust | 8222 | `networking-security` | Own sign-in |
| 🔒 **WireGuard Easy**<br>[`wg-easy`](../.templates/wg-easy) | Simplest way to run WireGuard VPN with a web-based management UI | — | `networking-security` |  |

### Network

| Template | What it does | Port | Stack | Notes |
|---|---|---|---|---|
| 🛑 **AdGuard Home**<br>[`adguard-home`](../.templates/adguard-home) | Network-wide ad and tracker blocker with DNS-over-HTTPS, DNS-over-TLS, and a beautiful dashboard | 3080 | `networking-security` | One per host |
| ☁️ **Cloudflare Tunnel**<br>[`cloudflared`](../.templates/cloudflared) | Expose local services to the internet securely without port forwarding | — | `networking-security` |  |
| 🦎 **Komodo**<br>[`komodo`](../.templates/komodo) | Modern Docker management platform — deploy, monitor, and manage containers and stacks with a beautiful web UI | 9120 | `core-infrastructure` |  |
| 🕳️ **Pi-hole**<br>[`pihole`](../.templates/pihole) | Network-wide ad blocker acting as a DNS sinkhole | 8089 | `networking-security` | One per host |
| 🧭 **Unbound**<br>[`unbound`](../.templates/unbound) | Unbound is a validating, recursive DNS resolver: it asks the root servers itself instead of forwarding to Google or Cloudflare, with DNSSEC | 5335 | `networking-security` | Not routed: `unbound` |
| ⛵ **Yacht**<br>[`yacht`](../.templates/yacht) | Docker management UI with template support, container management, and resource monitoring | 8000 | `core-infrastructure` |  |

### Storage

| Template | What it does | Port | Stack | Notes |
|---|---|---|---|---|
| 💾 **Duplicati**<br>[`duplicati`](../.templates/duplicati) | Free encrypted backup to cloud storage — supports S3, Backblaze B2, Google Drive, OneDrive, SFTP, and 25+ backends | 8200 | `storage-backup` |  |
| 📁 **File Browser**<br>[`filebrowser`](../.templates/filebrowser) | Clean, web-based file manager with upload, download, preview, rename, and edit capabilities | 8095 | `storage-backup` |  |
| 🗃️ **Kopia**<br>[`kopia`](../.templates/kopia) | Kopia makes fast, encrypted, deduplicated backups to a local folder, S3, B2, SFTP or a cloud drive, with a web UI for snapshots and restores | 51515 | `storage-backup` |  |
| 🪣 **MinIO Object Storage**<br>[`minio`](../.templates/minio) | MinIO high-performance S3-compatible object storage server | 9001 | `storage-backup` | Own sign-in |
| ☁️ **Nextcloud**<br>[`nextcloud`](../.templates/nextcloud) | Nextcloud self-hosted file storage, sync, and collaboration platform | 8080 | `storage-backup` | Own sign-in |
| 📲 **PairDrop**<br>[`pairdrop`](../.templates/pairdrop) | PairDrop is AirDrop for every device | 3015 | `storage-backup` |  |
| 📁 **SFTPGo**<br>[`sftpgo`](../.templates/sftpgo) | SFTPGo is an SFTP, FTPS, WebDAV and HTTP file server with per-user folders, quotas, virtual folders and a web admin plus a web client for users | 8590 | `storage-backup` |  |

### Download

| Template | What it does | Port | Stack | Notes |
|---|---|---|---|---|
| ⬇️ **MeTube**<br>[`metube`](../.templates/metube) | MeTube is a web UI for yt-dlp: paste a video or playlist URL and it downloads to your media folder, with format and quality presets | 8098 | `media-services` |  |
| ⬇️ **qBittorrent**<br>[`qbittorrent`](../.templates/qbittorrent) | Feature-rich BitTorrent client with a web UI | 8091 | `media-services` | Own sign-in |
| 📦 **SABnzbd**<br>[`sabnzbd`](../.templates/sabnzbd) | Automated Usenet download client | 8085 | `media-services` | Own sign-in |
| 📥 **Transmission**<br>[`transmission`](../.templates/transmission) | Lightweight BitTorrent client with minimal resource usage | 9091 | `media-services` | Own sign-in |

### Entertainment

| Template | What it does | Port | Stack | Notes |
|---|---|---|---|---|
| 🎮 **EmulatorJS**<br>[`emulatorjs`](../.templates/emulatorjs) | Browser-based retro game emulation platform supporting PS1, GBA, N64, SNES, NES, NDS, and more | — | `entertainment-personal` |  |
| 🌐 **LibreTranslate**<br>[`libretranslate`](../.templates/libretranslate) | LibreTranslate is a translation API and web page that runs entirely on your server (Argos models, no Google) | 5100 | `development-tools` |  |
| ⛏️ **Minecraft Server**<br>[`minecraft`](../.templates/minecraft) | A Minecraft Java server (Paper by default, or Vanilla, Fabric, Forge, Purpur) from the itzg image | 25565 | `entertainment-personal` | Not routed: `minecraft` |
| ⌨️ **MonkeyType**<br>[`monkeytype`](../.templates/monkeytype) | Self-hosted typing test application with customizable themes, multiple test modes, and detailed statistics tracking | 5001 | `entertainment-personal` |  |
| 🦙 **Ollama (Standalone)**<br>[`ollama`](../.templates/ollama) | Run large language models locally with a single command | 11434 | `development-tools` |  |
| 🤖 **Open WebUI + Ollama**<br>[`open-webui`](../.templates/open-webui) | ChatGPT-style interface for local LLMs | 3100 | `development-tools` |  |
| 🎮 **Pelican Panel + Wings**<br>[`pelican`](../.templates/pelican) | Open-source game server management panel with a companion Wings daemon | 8005 | `entertainment-personal` |  |
| 🕹️ **RomM**<br>[`romm`](../.templates/romm) | RomM is a ROM manager and web player for your retro game library | 8495 | `entertainment-personal` |  |
| 🪓 **Valheim Server**<br>[`valheim`](../.templates/valheim) | A dedicated Valheim server that installs and updates itself from Steam, with automatic world backups | 2456 | `entertainment-personal` | Not routed: `valheim` |
| 🎵 **Your Spotify**<br>[`your-spotify`](../.templates/your-spotify) | Self-hosted Spotify listening history tracker and statistics dashboard | 3005 | `entertainment-personal` |  |

<!-- templates:end -->

## template.json reference

Every template is a folder under `.templates/` with a `docker-compose.yml`, a `template.json` and, when
the app needs files before its first start, a `config/` folder.

| Field | Meaning |
|---|---|
| `name`, `title`, `description`, `icon`, `tags` | What the gallery shows. The description should say what to do after the first start (default logins, where to click). |
| `category` | The gallery group: `media`, `monitoring`, `web`, `databases`, `development`, `tools`, `productivity`, `automation`, `security`, `network`, `storage`, `download`, `entertainment`. The dashboard also takes aliases such as `notes`, `photos`, `vpn`, `backup`, `ai` and `gaming`. |
| `target_stack` | The stack it lands in by default. |
| `variables[]` | The deploy form: `name`, `label`, `description`, `default`, `required`. `type: "password"` hides the value; `options: [{value, label}]` makes a picker; `show_if: {OTHER_VAR: "value"}` hides a field until another one matches; `generate: "hex64"` fills an empty value with 64 random hex characters. |
| `config_path` | The folder under the stack's `App-Data/` that receives the template's `config/` files before the first start. `${VAR:-default}` placeholders in `.yml`, `.yaml`, `.conf` and `.env` files are filled from the deploy variables. |
| `route_skip` | Services that get no Traefik route, DNS record or proxy network: game, voice, MQTT and DNS ports. Services without a published port, or bound to `127.0.0.1`, are skipped anyway. |
| `route_override` | `{subdomain, port, protocol, use_host_ip, container}` for an app whose routable service is not in the compose file (Nextcloud AIO). |
| `singleton` | `true` when only one copy may run on a server (Traefik, Portainer, Watchtower…). |
| `optional_services` | `[{service, label, description, default_enabled}]`: services the deploy sheet can leave out (`exclude_services` in the API). |
| `auth` | `"bypass"`: the app's own clients sign in directly, so its routes stay out of Authelia unless the deploy sheet says otherwise. `auth_note` explains why on the sheet. |

Compose files use `${APP_DATA_DIR:-./App-Data}/<Name>/…` bind mounts, so *Nuke & reinstall*, backups and
the file editor find the data; `${PUID}`, `${PGID}` and `${TZ}` from the root `.env`; and a `healthcheck`
wherever the image has a tool to run one. `tests/lint.sh` validates every template's compose file with
its own defaults.

## Keeping this page up to date

The catalogue above is generated from `.templates/*/template.json`. After adding or changing a template:

```bash
docs/tools/gen-templates.sh            # rewrite the catalogue
docs/tools/gen-templates.sh --check    # exit 1 when this page is out of date
```

The script needs `bash` and `jq`, only touches the part between the two markers, and changes nothing
when it runs twice.
