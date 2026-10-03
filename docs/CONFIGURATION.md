<sub>[← Templates](TEMPLATES.md) · [Docs index](README.md) · Next: [Operations →](OPERATIONS.md)</sub>

# Configuration

DCS keeps its settings in plain `KEY=value` files. This page lists the ones that matter, grouped by
what they do. Every setting has a default, so an empty `.env` works.

- [Where settings live](#where-settings-live)
- [Server identity](#server-identity)
- [API and dashboard](#api-and-dashboard)
- [Accounts and sessions](#accounts-and-sessions)
- [Stacks and startup](#stacks-and-startup)
- [Proxy, DNS and domain](#proxy-dns-and-domain)
- [Notifications](#notifications)
- [Updates](#updates)
- [Backups and recovery](#backups-and-recovery)
- [Power (UPS)](#power-ups)
- [Proxmox and the fleet](#proxmox-and-the-fleet)
- [Metrics and logs](#metrics-and-logs)
- [Secrets DCS looks for](#secrets-dcs-looks-for)
- [Setup variables](#setup-variables)

## Where settings live

| File | What it holds |
|---|---|
| `.env` | Your settings. `setup.sh` copies it from `.env.example` with mode `600`. |
| `.config/settings.cfg` | The default of every setting. Do not edit it: updates replace it. |
| `Stacks/<stack>/.env` | Variables for one stack's compose file; templates add theirs here. |
| `.secrets/` | The encrypted secret store (Secrets page). |

When a setting is set in more than one place, the later one wins: the defaults, then `.env`, then the
`ENVIRONMENT` profile, then the stack's `.env`, then the environment you start a script with
(`LOG_LEVEL=DEBUG ./start.sh`).

**How to change them.** *Config* in the dashboard covers the common settings, the *Environment*
page edits `.env` itself, and you can edit the file by hand. Every write through the dashboard or the
API is checked: only `KEY=value` lines, no command substitution, no loader variables such as
`LD_PRELOAD`. The API reads `.env` as data and never runs it.

**When they apply.** The API reads `.env` on every request, so most changes count from the next one. The
API's own address, port, TLS and login policy, and the intervals of its background loops, change when
the API restarts: `sudo systemctl restart dcs-api`, or `POST /system/restart`.

**Secrets in settings.** Any value can point into the secret store as `${SECRETS_<name>}`, for example
`DISCORD_WEBHOOK_URL=${SECRETS_DISCORD_WEBHOOK}`. DCS resolves these references itself; a bare
`docker compose` does not see them, so work with a stack by hand through `./compose.sh <stack> …`.

## Server identity

| Key | Default | Meaning |
|---|---|---|
| `SERVER_NAME` | `Docker Server` | The name in the dashboard, in notifications and on the hub's lists |
| `SERVER_SUBTITLE` | `DCS Orchestrator` | The line under the name |
| `TZ` | `UTC` | Time zone for DCS and every container that takes `${TZ}` |
| `PUID`, `PGID` | `1000` | The user and group containers run as; setup uses your own IDs |
| `APP_DATA_DIR` | `./App-Data` | Where app data goes, relative to each stack's folder |
| `PROXY_DOMAIN` | `example.com` | Your domain: routes are `<app>.<domain>` |

## API and dashboard

| Key | Default | Meaning |
|---|---|---|
| `API_ENABLED` | `true` | Start the API with `start.sh`; the dashboard needs it |
| `API_BIND` | `0.0.0.0` | The address the API listens on; the dashboard container reaches it through the host |
| `API_PORT` | `9876` | The API's port |
| `DCS_UI_PORT` | `3000` | The dashboard's host port. Traefik still reaches the container at `http://DCS-UI:3000`. |
| `API_AUTH_ENABLED` | `true` | Accounts on or off. Off only works on a loopback address… |
| `API_INSECURE_NO_AUTH` | `false` | …unless you also set this. Do not. |
| `API_TRUSTED_PROXIES` | `172.16.0.0/12` | Peers allowed to set `X-Forwarded-For`, so rate limits and the audit log see real clients. The default covers Docker's bridges; add Cloudflare's ranges when it fronts you. |
| `API_IP_WHITELIST` | *(empty: all)* | Comma-separated CIDRs allowed to call the API |
| `API_CORS_ORIGINS` | *(empty: localhost)* | Other origins a browser may call the API from |
| `API_TLS_ENABLED` | `false` | Serve HTTPS directly, with `API_TLS_CERT` and `API_TLS_KEY` |
| `API_BEHIND_TLS_PROXY` | `false` | The API sits behind Traefik or another TLS proxy (adds HSTS) |
| `API_RATE_LIMIT`, `API_RATE_WINDOW` | `600`, `60` | Requests per client per window, in seconds (`0` turns it off) |
| `API_MAX_BODY_SIZE` | `1048576` | Largest request body, in bytes |
| `API_RESPONSE_CACHE` | `true` | Share one answer of the polled read endpoints between all clients |
| `API_WORKERS` | automatic | Pre-read copies of the API script that answer the requests; the front hands each connection to a free one. Empty = twice the cores, 4 to 8 (4 on a machine with less than 3 GB of memory); a request that stays open (an event stream) or finds no free worker for a second gets a process of its own. Reading the 27,000-line script is what a request costs most, so this is what keeps a small hub idle with a dashboard open. `0` = one process per connection |
| `API_WORKER_REQUESTS` | `500` | A worker renews itself (same process id, fresh memory) after this many answers |
| `API_WORKER_IDLE_SECS` | `900` | A worker's connection that goes quiet for this long (a handler that works in silence) is closed |
| `API_CACHE_MAX_STALE` | `120` | Oldest cached answer, in seconds, that may be served while it refreshes |

## Accounts and sessions

| Key | Default | Meaning |
|---|---|---|
| `API_TOKEN_EXPIRY` | `86400` | Session length in seconds (24 h) |
| `API_SINGLE_SESSION` | `true` | A new login ends the account's older sessions. Service and bot accounts may keep several. |
| `API_INVITE_EXPIRY` | `604800` | Invite codes expire after this many seconds (7 days) |
| `API_MAX_LOGIN_ATTEMPTS`, `API_LOCKOUT_DURATION` | `5`, `900` | Failed logins before a lockout, and its length in seconds |
| `TERMINAL_SESSION_EXPIRY` | `14400` | How long an unlocked web terminal stays open (4 h) |

## Stacks and startup

| Key | Default | Meaning |
|---|---|---|
| `DOCKER_STACKS` | all ten | The stacks `start.sh` and `stop.sh` manage, in start order (stop is the reverse) |
| `CONTINUE_ON_FAILURE` | `true` | Keep starting the other stacks when one fails |
| `SKIP_HEALTHCHECK_WAIT` | `false` | Start without waiting for health checks |
| `SERVICE_START_DELAY`, `SERVICE_STOP_DELAY` | `5`, `10` | Seconds between stacks when starting and stopping |
| `DOCKER_COMPOSE_VERSION` | `auto` | `auto`, `v2` (the plugin) or `v1` (the old `docker-compose`) |
| `REMOVE_VOLUMES_ON_STOP` | `false` | Delete named volumes on stop. Destroys data. |
| `ENABLE_POST_STARTUP_HEALTH_CHECK`, `HEALTH_CHECK_DELAY` | `true`, `10` | Check health after `start.sh`, after this many seconds |
| `PROXY_RECONCILE` | `false` | Probe Traefik's routes after every `start.sh` (the boot service always does) |
| `SHOW_BANNERS`, `SHOW_SYSTEM_INFO` | `true`, `false` | Console output of the scripts |

The default order is `core-infrastructure → networking-security → monitoring-management →
development-tools → media-services → web-applications → storage-backup → communication-collaboration →
entertainment-personal → miscellaneous-services`. Each stack in a fresh clone holds a small placeholder
service (an nginx page, `traefik/whoami`, or an idle Alpine) so you can see it start; remove it when you
deploy real services. On a hub, a stack that runs in a VM is never started on the hub, whatever
`DOCKER_STACKS` says.

## Proxy, DNS and domain

| Key | Default | Meaning |
|---|---|---|
| `TRAEFIK_DOMAIN` | *(empty)* | The domain Traefik's certificates and routes use; falls back to `PROXY_DOMAIN` |
| `TRAEFIK_ACME_EMAIL` | *(empty)* | The e-mail for Let's Encrypt |
| `TRAEFIK_TRUSTED_LAN` | `192.168.1.0/24` | Your LAN, for IP allow-lists |
| `CF_DNS_API_TOKEN` | *(empty)* | Cloudflare token (*Zone → DNS → Edit*) for wildcard certificates and DNS records. Keep it in the secret store: the wizard does. |
| `DDNS_ENABLED` | `false` | Keep Cloudflare A records on your public address |
| `DDNS_INTERVAL` | `300` | Seconds between checks |
| `DDNS_SUBDOMAINS` | `@` | Records to update (`@` is the domain itself, `*` the wildcard) |
| `DASHBOARD_PUBLIC_URL` | *(empty)* | Where notification links point; defaults to `https://ui.<PROXY_DOMAIN>` |
| `PROXY_DOMAINS_EXTRA` | *(empty)* | More domains this server answers for, space separated (DNS & Routes → Domains writes it). [More than one domain](#more-than-one-domain) |
| `PROXMOX_DOMAIN` | *(empty)* | The domain new VMs answer under; empty = this server's own (`PROXY_DOMAIN`) |
| `CROWDSEC_TRUSTED_IPS` | *(empty)* | Addresses CrowdSec must never ban, beside your public address |
| `CROWDSEC_MEDIA_APPS` | `jellyfin` | Media apps whose web client CrowdSec must not take for a crawler: comma separated Traefik service hosts (the container name in the route's URL). Their routers are found by DCS (a VM of the fleet, a renamed route, Docker labels). Empty turns it off. [Details](CROWDSEC.md#media-apps-a-web-client-is-not-a-crawler) |
| `CROWDSEC_HOME_IPV6_PREFIX` | `64` | The home network over IPv6 is trusted like the home IPv4 address: this server's global IPv6 address cut to this many bits (32-128; 56 or 48 when the router hands out several /64s), following the provider's prefix. `off` turns it off. [Details](CROWDSEC.md#the-home-network-over-ipv6) |

### More than one domain

The hub's own stacks answer under `PROXY_DOMAIN`. Add more domains on **DNS & Routes → Domains** (or `POST /domains
{domain}`): the one Cloudflare token covers them all when they are on its account. Each domain then gets:

- a wildcard certificate: an entry in the `domains` list of Traefik's `websecure` entrypoint (`*.<domain>`);
- a sign-in: an Authelia cookie for it (`auth.<domain>`), the access rules the primary domain has repeated for it, and
  the sign-in route answering `auth.<domain>` too. A session does not cross domains, so moving between apps on
  different domains asks to sign in once on each;
- its apex record on the public address, kept there by DDNS with the primary's (same IP: Traefik tells the apps apart
  by name).

Traefik and Authelia restart a moment after the change (their static configuration is read at start). A copy of each
file is kept beside it (`.bak-<time>`). Taking a domain off undoes exactly that; its DNS records stay in Cloudflare.

**Who answers under which domain.** A VM answers under one domain: the default for new VMs (`PROXMOX_DOMAIN`, the
hub's own when empty; the Domains card sets it), the one chosen when it is built or a stack is moved into it, or the
one chosen later on the VM (Proxmox page → the VM → Domain). Changing it moves the VM's routes at once
(`sonarr.howson.dev` becomes `sonarr.howson.lol`) and makes their DNS records; `POST /fleet/members/{id}/domain`. A
stack deployed on the hub can pick a domain on the deploy sheet; a stack deployed into a VM answers under the VM's.

**The Traefik template's add-ons** are switches of its deploy (the wizard's Traefik step, the deploy
sheet). The deploy writes them to the proxy stack's `.env`, where a later deploy that does not mention
them finds them; [Templates → Traefik add-ons](TEMPLATES.md#traefik-add-ons) says what each one does.

| Key | Default | Meaning |
|---|---|---|
| `TRAEFIK_SABLIER` | `false` | Deploy Sablier with Traefik and declare its plugin: containers that start on demand |
| `TRAEFIK_CLOUDFLARE_REAL_IP` | `false` | Behind Cloudflare's proxy, the visitor's address replaces Cloudflare's before CrowdSec and Geoblock judge it (`cloudflarewarp`, first in `traefik-chain`) |
| `TRAEFIK_GEOBLOCK` | `false` | Only the countries listed reach the routes DCS writes (`geoblock` in `traefik-chain`; your LAN always may) |
| `TRAEFIK_GEOBLOCK_COUNTRIES` | *(empty)* | ISO 3166-1 alpha-2 codes, comma separated (`GB,US,DE`); required while Geoblock is on, and checked |
| `TRAEFIK_THEMEPARK` | `false` | Declare the theme.park plugin at the start, so a theme on an app's pages needs no Traefik restart |
| `TRAEFIK_MAINTENANCE` | `false` | Declare the maintenance plugin and define the `maintenance` middleware with its holding page |

**A Traefik on another machine** pulls this server's routes as a feed:

| Key | Default | Meaning |
|---|---|---|
| `TRAEFIK_FEED_ENABLED` | `false` | Publish the routes at `/traefik/dynamic?token=…` |
| `TRAEFIK_FEED_TOKEN` | *(minted when enabled)* | The feed's token; rotate it in Config |
| `TRAEFIK_FEED_TARGET_HOST` | *(the LAN address)* | The address the remote Traefik uses to reach this server |
| `TRAEFIK_FEED_ENTRYPOINT` | `websecure` | The entrypoint name on the remote side |
| `TRAEFIK_FEED_MIDDLEWARES` | *(empty)* | Middlewares that exist on the remote side |
| `TRAEFIK_FEED_TLS`, `TRAEFIK_FEED_CERT_RESOLVER` | `true`, *(empty)* | TLS on the remote routes, and its certificate resolver |

[Proxmox guide → the route feed](PROXMOX.md#4-a-traefik-in-another-vm-or-machine-the-route-feed) explains the setup.

## Notifications

| Key | Default | Meaning |
|---|---|---|
| `NTFY_URL`, `NTFY_TOPIC`, `NTFY_TOKEN` | *(empty)*, `dcs`, *(empty)* | Push notifications through an ntfy server; the token when it needs one |
| `NTFY_PRIORITY` | `default` | ntfy priority |
| `DISCORD_WEBHOOK_URL` | *(empty)* | A Discord channel webhook, or a `${SECRETS_…}` reference |
| `DISCORD_WEBHOOK_NAME`, `DISCORD_WEBHOOK_AVATAR` | `DCS Manager`, *(the DCS icon)* | The name and picture the posts carry |
| `NOTIFY_COOLDOWN_MINUTES` | `60` | How often a container rule repeats the same event while the problem lasts (disk rules wait 6 h, image rules a day) |
| `CRITICAL_CONTAINERS`, `IMPORTANT_CONTAINERS` | *(empty)* | Containers named in the ntfy start and stop reports |

The rules themselves (which events, which targets) live on the Notifications page.
[Discord guide](DISCORD.md) covers the webhook, the rules and every event.

## Updates

| Key | Default | Meaning |
|---|---|---|
| `UPDATE_CHANNEL` | `stable` | `stable` follows the tagged releases, `main` every commit |
| `UPDATE_ON_BOOT` | `false` | Pull image updates when the boot service starts the stacks |
| `UPDATE_AUTO_ROLLBACK` | `true` | Roll an unattended update back when the health score drops |
| `UPDATE_HEALTH_GRACE` | `120` | Seconds to wait after an unattended update before judging it |
| `UPDATE_ROLLBACK_DROP` | `15` | Points the health score may drop before the rollback |
| `AGGRESSIVE_IMAGE_PRUNE` | `false` | After updates, remove every unused image, not only dangling and old ones |
| `UPDATE_NOTIFICATION` | `true` | Send a summary after an image update run |

## Backups and recovery

| Key | Default | Meaning |
|---|---|---|
| `BACKUP_DEST_DIR` | *(empty)* | Where backups go (each with a `.sha256`); nothing is backed up until it is set |
| `BACKUP_SOURCE_DIR` | *(empty)* | An extra folder a full backup carries (`.dcs-backup/source.tar`); the install is always in it |
| `BACKUP_RETENTION_COUNT` | `6` | Backups kept of each kind: the full ones, and each stack's own |
| `BACKUP_PAUSE` | `true` | Pause a stack's running containers while its folder and volumes are read (a consistent copy of a database) |
| `BACKUP_PAUSE_EXCEPT` | *(empty)* | Stacks never paused (space-separated): the LAN's DNS, a media server with a huge library |
| `BACKUP_RESTORE_STOP_TIMEOUT` | `20` | Seconds a container has to stop before a restore replaces its data |
| `BACKUP_PRE_RESTORE_KEEP` | `2` | Sets of "the data before a restore" kept in `.data/pre-restore` |
| `RECOVERY_DEST_DIR` | *(empty)* | Where recovery bundles go: `BACKUP_DEST_DIR/recovery`, then `.data/recovery` |
| `RECOVERY_REMOTE` | *(empty)* | An off-box copy: an rsync target (`user@nas:/backups/dcs`) or a mounted path |
| `RECOVERY_RETENTION_COUNT` | `10` | Bundles kept |
| `RESET_TRASH_KEEP_DAYS` | `7` | Days *Nuke & reinstall* keeps an app's old data in `App-Data/.trash` |
| `ROLLBACK_ENABLED`, `ROLLBACK_MAX_SNAPSHOTS` | `true`, `10` | Snapshot a stack's files before changes, and how many to keep |

## Power (UPS)

| Key | Default | Meaning |
|---|---|---|
| `UPS_ENABLED` | `false` | Watch a UPS |
| `UPS_SOURCE` | `auto` | `nut`, `apcupsd`, `pwrstat` (CyberPower PowerPanel) or `auto` (tries them in that order) |
| `UPS_PWRSTAT_BIN` | *(found by itself)* | Where `pwrstat` is, when it is not in `/usr/bin` |
| `UPS_NUT_HOST`, `UPS_NUT_PORT`, `UPS_NAME` | `127.0.0.1`, `3493`, `ups` | The NUT server and the UPS name on it (the `nut-upsd` template serves a USB UPS) |
| `UPS_POLL_INTERVAL` | `15` | Seconds between reads |
| `UPS_SHUTDOWN_CHARGE`, `UPS_SHUTDOWN_RUNTIME` | `20`, `300` | On battery, below this charge (%) or runtime (s) the stacks stop |
| `UPS_ON_BATTERY_ACTION` | `stop-stacks` | What happens at the threshold |
| `UPS_HOST_SHUTDOWN_CMD` | *(empty)* | A command to run after the stacks stopped, such as a sudo rule for `shutdown -h` |
| `UPS_START_ON_POWER` | `false` | Start the stacks again when mains returns |

**A CyberPower UPS (PowerPanel, `pwrstat`).** Set `UPS_SOURCE=pwrstat` (or leave `auto`: it finds `pwrstat` itself). The program
belongs to root, so the server reads it through `sudo -n`; one line lets it, and only that command:

```bash
echo 'howson ALL=(root) NOPASSWD: /usr/bin/pwrstat -status' | sudo tee /etc/sudoers.d/dcs-pwrstat
sudo chmod 440 /etc/sudoers.d/dcs-pwrstat
```

(`howson` is the user DCS runs as; until the line is there, the Power card says so and shows this command.) Charge, runtime,
load in watts and percent, the input and output voltage, the last power event and the self-test result are read; a power
failure is *on battery*, and *low* means the charge or runtime is under the two thresholds above. The Dashboard's Power card
shows it, and a board that reads the [dashboard feed](DASHBOARDS.md) (`system.ups`) can draw it.

## Proxmox and the fleet

| Key | Default | Meaning |
|---|---|---|
| `PROXMOX_URL` | *(empty)* | The Proxmox API, `https://<host>:8006` |
| `PROXMOX_TOKEN_ID` | *(empty)* | `user@realm!name`, for example `dcs@pve!dcs` |
| `PROXMOX_TOKEN_SECRET` | *(empty)* | The token's secret. The secret store wins over this line. |
| `PROXMOX_VERIFY_TLS` | `true` | `false` accepts Proxmox's self-signed certificate |
| `PROXMOX_NODE` | *(empty: all)* | Show only this node |
| `FLEET_ROLE` | *(set by setup)* | `hub`, `member` or `standalone`, as chosen in `setup.sh` |
| `DCS_ROLE` | `hub` | `hub`: the full DCS — the API, the dashboard, accounts and the setup wizard; a standalone server is a hub without members. `node`: the API alone, managed from its hub's dashboard — no dashboard, no accounts of its own, no wizard, no first-admin gate; the join creates only the hub's account (`dcs-hub`). `setup.sh` writes it; the hub's one-line join command and the DCS node images (`/etc/dcs-role`) make a node. |
| `FLEET_SELF_URL` | *(detected)* | How other machines reach this API, `http://<address>:9876` |
| `FLEET_SCAN_PORTS` | `9876` | Ports the hub probes when it scans guests for DCS |
| `FLEET_IMAGE_URL` | Debian 13 cloud image | The image the hub imports for new VMs |
| `FLEET_VM_USER` | `dcs` | The user cloud-init makes in the VMs the hub builds |
| `FLEET_APPDATA_MOUNT` | `true` | A hub shows every VM stack's App-Data at `Stacks/<name>/VM-App-Data` (a link to an sshfs mount of the VM's folder); `false` takes the mounts and the links away |
| `FLEET_APPDATA_INSTALL` | `true` | The hub installs `sshfs` by itself when it is missing and the DCS account has passwordless sudo; `false` leaves that to you |
| `FLEET_MOUNT_DIR` | `~/.dcs-vm-data` | Where those mounts are made — outside the DCS folder on purpose (a folder inside it is refused) |

`.config/fleet-images.json` on the hub (an array of `{id, label, url, file, family}`) replaces the list of
operating systems the VM settings offer. [Proxmox guide](PROXMOX.md) explains every piece.

## Metrics and logs

| Key | Default | Meaning |
|---|---|---|
| `METRICS_ENABLED` | `true` | Record resource samples for the trends |
| `METRICS_COLLECT_INTERVAL` | `30` | Seconds between samples |
| `METRICS_RAW_DAYS`, `METRICS_5M_DAYS`, `METRICS_HOURLY_DAYS` | `7`, `90`, `730` | Days kept as raw samples, 5-minute averages and hourly averages |
| `LOG_LEVEL` | `INFO` | `ERROR`, `WARNING`, `INFO`, `DEBUG` or `VERBOSE` |
| `COLOR_MODE` | `auto` | Console colours: `auto`, `always`, `never` |
| `LOG_BACKUP_COUNT` | `12` | How many rotated logs are kept |
| `ENABLE_STRUCTURED_LOGGING` | `true` | A JSON-lines log beside the plain one |
| `ENVIRONMENT` | `production` | Profile: `development` and `testing` turn on debug output |
| `PLUGINS_ENABLED`, `PLUGINS_HOOKS_ENABLED` | `true`, `true` | Plugins and their lifecycle hooks |

## Secrets DCS looks for

Store these on the **Secrets** page (or `POST /secrets/{name}`); they are encrypted at rest and never
shown again.

| Secret | Used for |
|---|---|
| `CF_DNS_API_TOKEN` | Cloudflare DNS: certificates, records, dynamic DNS |
| `PROXMOX_TOKEN_SECRET` | The Proxmox link |
| `RECOVERY_PASSPHRASE` | Encrypting recovery bundles |
| `HOMARR_API_KEY` | Tiles on Homarr's home board (set it with *Config → Integrations*) |
| `FLEET_MEMBER_…` | Written by a hub: the passwords of its accounts on the members |

Back up `.secrets/.master-key` apart from the store itself: without it, the secrets cannot be read.

## Setup variables

`setup.sh` reads these when you run it. They are for scripts, images and the VMs a hub builds;
`./setup.sh --help` prints them.

| Variable | Meaning |
|---|---|
| `DCS_UNATTENDED=true` | No questions. Nothing is installed or changed on the system without being asked. |
| `DCS_ADMIN_USER`, `DCS_ADMIN_PASSWORD` | Create the first admin and finish the setup without the wizard |
| `DCS_STACKS` | The stacks to manage, in order |
| `DCS_MEMBER_NAME` | The server's name (`SERVER_NAME`) |
| `DCS_TZ`, `DCS_PUID`, `DCS_PGID`, `DCS_PROXY_DOMAIN` | The same settings as in `.env` |
| `DCS_CF_DNS_API_TOKEN` | Stored in the secret store as `CF_DNS_API_TOKEN` |
| `DCS_API_PORT`, `DCS_API_BIND` | Where the API listens |
| `DCS_NO_UI=true` | An API-only install, driven from a hub's dashboard |
| `DCS_ROLE=node` | Install a node: the API alone, no admin account, no wizard; with `DCS_HUB_URL` + `DCS_JOIN_TOKEN` the join runs at once. What the hub's one-line command sets; a DCS node image implies it. |
| `DCS_FLEET_ROLE` | `hub`, `member` or `standalone` |
| `DCS_HUB_URL`, `DCS_JOIN_TOKEN` | Join a hub as a member (a join code from the hub's Proxmox page) |
| `DCS_PROXMOX_URL`, `DCS_PROXMOX_TOKEN_ID`, `DCS_PROXMOX_TOKEN_SECRET` | Link Proxmox during setup |

`./setup.sh --join <hub-url> <code> [name]` joins an installed DCS to a hub, and `./setup.sh --dry-run`
shows what setup would do without changing anything.

A node needs no `setup.sh` run by hand at all: the hub's Proxmox page (*Join code*) and `POST /fleet/join-tokens`
(`node_command`) show the one line, `curl -fsSL 'http://<hub>:9876/fleet/bootstrap?token=<code>' | bash`, that
installs Docker, the tools and DCS as a node of that hub on any Debian, Ubuntu, Fedora or Arch machine and joins it.

On hosts with Debian's own `docker.io` 26 and AppArmor 4, setup writes `DCS_UI_APPARMOR=unconfined` into
`Stacks/core-infrastructure/.env` so the dashboard container can start; Docker CE needs nothing.
