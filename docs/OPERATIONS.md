<sub>[← Configuration](CONFIGURATION.md) · [Docs index](README.md) · Next: [Troubleshooting →](TROUBLESHOOTING.md)</sub>

# Operations

Running DCS day to day: the commands, updates, backups, health, alerts, schedules and accounts.

- [Everyday commands](#everyday-commands)
- [Stacks and containers](#stacks-and-containers)
- [Nuke & reinstall](#nuke--reinstall)
- [Updating DCS](#updating-dcs)
- [Unattended updates](#unattended-updates)
- [Image updates](#image-updates)
- [Backups and snapshots](#backups-and-snapshots)
- [The recovery bundle](#the-recovery-bundle)
- [Health](#health)
- [Notifications](#notifications)
- [Schedules and automations](#schedules-and-automations)
- [Users and roles](#users-and-roles)
- [Themes](#themes)
- [The boot services](#the-boot-services)

## Everyday commands

Run these in the install directory (`~/.Docker-Compose-Skeleton-AIO`) as the DCS user.

| Command | What it does |
|---|---|
| `./start.sh` | Starts the API, then every stack in order, and checks their health |
| `./stop.sh` | Stops every stack in reverse order, then the API (`--force` for a short timeout) |
| `./restart.sh` | Stop, then start |
| `./status.sh` | Container status per stack |
| `./compose.sh <stack> …` | `docker compose` for one stack, with the `.env` files and the secret store applied (`--list` names the stacks) |
| `./setup.sh --dry-run` | Shows what setup would change, without changing it |

Work with a stack by hand through `./compose.sh`, not a bare `docker compose`: only DCS resolves
`${SECRETS_…}` references, so a bare command would start the container with blank secrets.

```bash
./compose.sh media-services logs -f jellyfin
./compose.sh networking-security up -d --force-recreate --no-deps traefik
```

<details>
<summary><b>The tools in <code>.scripts/</code></b></summary>

| Script | What it does |
|---|---|
| `api-server.sh` | The API (`--bind`, `--port`, `--stop`, `--help`) |
| `install-service.sh` | Installs the boot services (`--uninstall` removes them) |
| `stack-manager.sh` | Start, stop, restart, status, logs and pull for one stack |
| `health-check.sh` | A health table of the containers |
| `config-validator.sh` | Checks the configuration, folders, compose files and ports (`--fix` repairs) |
| `maintenance.sh` | Docker clean-up, disk report, orphans, log rotation |
| `logs-viewer.sh` | An interactive log viewer |
| `image-tracker.sh` | Image age and staleness |
| `docker-network-info.sh` | A map of the Docker networks |
| `backup-server.sh` | An rsync backup of the server |
| `proxy-reconcile.sh` | Probes every Traefik route and restarts Traefik once when none answer |

Each one prints its options with `--help`.

</details>

## Stacks and containers

The dashboard does everything the commands do, and more:

- **Stacks** (*VMs* on a hub): start, stop, restart and update a stack; follow its progress (pull,
  create, start, health); edit its `docker-compose.yml` and `.env`. Every compose save is checked by the
  security scan and `docker compose config`, and the previous version is kept: the history can put any
  version back.
- **Containers**: state, health, ports, CPU and memory; start, stop, restart, recreate, remove; logs,
  the files inside, its environment (saved where the compose file defines it, then recreated); *Run
  Command* for one-off commands; *Start on demand*, *Theme*, *Add to Homarr* and *Nuke & reinstall*.
- **Terminal**: a shell on the host. Unlock it with the Linux password of the account DCS runs as (or
  root's). Each command may run 60 seconds, and every command is in the audit log.
- **Also**: Images, Networks, Volumes, Logs, Live Events, Topology, Uptime, Diagnostics, Maintenance
  (prune, orphans, disk use) and a File Browser.

On a hub, every one of these works across the fleet: the list pages open on *Everywhere* with a chip
for the hub or one VM, and each action runs where the thing lives.
[Proxmox guide → everything from the hub](PROXMOX.md#everything-from-the-hub).

## Nuke & reinstall

When an app has wedged itself (a lost admin password, a broken database, a config you cannot untangle),
the container's page offers **Nuke & reinstall**. It removes the container, moves the `App-Data` folders
it owns to `App-Data/.trash` (kept for `RESET_TRASH_KEEP_DAYS`, 7 by default, so you can undo it by
hand), removes its own named volumes if you tick them, and creates the service again from the compose
file: a first install. Folders another container also mounts are never touched. The preview lists
everything with its size before you type the container's name to confirm.

## Updating DCS

The **Updates** page checks the release channel (`UPDATE_CHANNEL`: `stable` follows the tagged
releases, `main` every commit), shows the release notes and applies the update in one click.

- Your files under `Stacks/`, `.templates/`, `.api-auth/` and `.plugins/` stay exactly as they are.
- A framework file you edited by hand stops the update until you tick the box to replace it; the old
  copy goes to `.data/update-backups/`. A file whose only change is the executable bit does not count.
- A backup tag is made first (the last ten are kept), and **Rollback** returns to it.
- The API restarts itself afterwards, without root.
- The dashboard container updates from the same page (the newest `DCS-UI` image, recreated).

On a hub, the page also lists every VM's version. **Update all VMs** hands each one the hub's code
(their data, accounts and stacks stay), and a hub update can take the VMs along.

By hand, in the install directory:

```bash
git pull --ff-only
sudo systemctl restart dcs-api
```

This skips the safety net: no backup tag, and a conflict with your edits stops `git` instead.

## Unattended updates

Add a schedule with the action **dcs-update** (target `images` to pull image updates as well). It applies
the channel's release outside the API, restarts the API, waits `UPDATE_HEALTH_GRACE` seconds and rolls
back to the backup tag when the health score dropped by `UPDATE_ROLLBACK_DROP` points. The outcome goes
to your notification channels and to the list on the Updates page (`GET /system/update/history`).
Framework files you edited by hand are never replaced unattended: the Updates page asks you first.

## Image updates

- **Check Registry** on the Updates page asks the registries which images have a newer version.
- **Update** on an image pulls it and recreates exactly the containers that run an older copy. Chips mark
  containers left on an old copy, with a **Recreate** button.
- **Automatic image updates**: the Updates page has a dropdown (off, every night, every Sunday, the 1st
  of the month, at 03:00) that makes an **image-update** schedule. It pulls the image of every running
  container and recreates the ones on an older copy; with the target `pull` it only pulls. It writes
  `logs/image-update.log`, a line on the Updates page, and a notification when something changed or failed.
- **At boot** nothing is pulled unless `UPDATE_ON_BOOT=true`: a boot stays fast and predictable.
- **Docker Engine**: a card on the Updates page shows the engine's version, where it comes from and the
  newest version on offer, and updates it (with passwordless sudo, or with the Terminal's Linux password).

## Backups and snapshots

| Kind | What it holds | Where |
|---|---|---|
| **Backup** | The whole install with the stacks' app data, or one stack's folder | Backup page; set `BACKUP_DEST_DIR` first; `BACKUP_RETENTION_COUNT` kept |
| **Snapshot** | The configuration: compose files, `.env` files, templates | Snapshots page; download or restore any one |
| **Rollback snapshot** | A stack's files, taken before a change | Per stack, `ROLLBACK_MAX_SNAPSHOTS` kept |
| **Recovery bundle** | Everything needed to rebuild the install, encrypted | See [below](#the-recovery-bundle) |

Backups run in the background, can be scheduled (action `backup`) and can be cancelled. A restore asks
for a confirmation first. A backup leaves out the version history of the code, logs, session tokens,
rate-limit state and the secret store's key (`.secrets/.master-key`), and only its owner may read it.
Keep the key somewhere else, or use the recovery bundle, which carries it encrypted.

**On Proxmox**, back up the VM (or container) as well. Proxmox's own backups cover the disk DCS and the
app data live on; with the QEMU guest agent the file system is frozen for a consistent copy. On a hub,
*Back up everything* covers the hub and every VM, and one snapshot can cover them all.

## The recovery bundle

One encrypted file (AES-256) that rebuilds the install on another machine: the root `.env`, the secret
store with its key, accounts, notification rules and dashboard layouts, schedules, every stack's files,
Traefik's and Authelia's data, templates and plugins. App data of the stacks you choose can go along.

1. Store a passphrase as the secret `RECOVERY_PASSPHRASE` (the Backup page asks for it).
2. Optional: set `RECOVERY_REMOTE` to an rsync target or a mounted drive for an off-box copy.
3. Make a bundle on the Backup page, or add a schedule with the action `recovery`.

**To restore** on a new machine: install DCS, and in the wizard's *Admin* step open *Moving from another
server? Restore a recovery bundle*. Then sign in with your old account and start the stacks. On a running
install, the Backup page restores a bundle after taking a snapshot of the current state.

## Health

- **The health score** (0 to 100, with a grade) rates the server, each stack and each container, from
  health checks, uptime, restarts, resource use and image age. Its history is kept.
- **A server without Docker is critical.** When `docker` does not answer, `GET /health` says `critical`
  and the score is capped at 39 (F). On a hub, a VM that does not answer counts as `unreachable` and the
  fleet reads at least `degraded`. *(New in 4.0; earlier versions read an unreachable Docker as an empty,
  healthy server.)*
- **The link to the API** is shown on its own *(new in 4.0)*: **Connected**, **Not answering** (connected,
  but the last checks failed), **Reconnecting…** (the dashboard is trying again by itself) and **Offline**
  (press *Retry*). While the link is down, the pages say so and show the last known state instead of a
  stale "healthy".
- **Uptime** and **Diagnostics** show availability over time and a port and health matrix.
- **The proxy**: `GET /routes/certificates` lists the domain, the certificates and their expiry, a live
  probe of every route and Traefik's last errors (the Certificates panel on DNS & Routes).

## Notifications

Two channels, both optional, set in *Server Config → Notifications*:

- **ntfy**: push notifications to your phone (`NTFY_URL`, `NTFY_TOPIC`, `NTFY_TOKEN`). The setup wizard can
  deploy an ntfy server for you.
- **Discord**: a channel webhook (`DISCORD_WEBHOOK_URL`); every event arrives as an embed.

**Rules** on the Notifications page decide what is sent: unhealthy, stopped or busy containers, low
disk space, stacks that stop or fail, deploys, image updates, backups, automations and every change of
the server's health. Each rule has a cooldown, so a lasting problem does not flood the channel. UPS
events and DCS updates are sent without a rule. **Send test** tries every channel and names the one
that failed.

**Webhooks** (the Integrations part of the page) follow the audit log instead: containers that stop on
their own or recover, every action you take, backups, updates, failed sign-ins. A hook pointed at Discord
gets the same embed, one pointed at Slack gets text, and anything else gets JSON.

On a hub, the VMs send their events to the hub, which notifies with the VM named: the VMs need no
channels of their own. [Discord guide](DISCORD.md) covers every event, the bot and CrowdSec's alerts.

## Schedules and automations

**Schedules** run an action on a cron timetable (*Scheduled Tasks* page):

| Action | What it does |
|---|---|
| `backup` | Back up one stack, or all |
| `start`, `stop`, `restart`, `update` | The same stack actions as the Stacks page |
| `prune` | Remove unused images, networks and stopped containers (on-demand ones are kept) |
| `maintenance` | The maintenance run |
| `health-check`, `metrics-snapshot` | Record a health check or a metrics sample |
| `recovery` | Write a recovery bundle |
| `dcs-update` | [Unattended update](#unattended-updates) (`images`: pull image updates too) |
| `image-update` | [Automatic image update](#image-updates) (`pull`: pull only) |
| `custom` | Run an executable file inside the install directory |

**Automations** react to a timetable or a condition: a container unhealthy or stopped, high CPU or
memory, a full disk (with a 15-minute cool-down). Their actions: start, stop or restart a stack, restart
a container, prune Docker, start a backup, send a notification, update DCS, write a recovery bundle.
Every run is in the automation's history.

## Users and roles

| Role | Can do |
|---|---|
| **admin** | Everything, including accounts, secrets, files, `.env`, the terminal and DCS updates |
| **user** | Read: a viewer. Manages only its own session, profile and 2FA. |
| **bot** | Day-to-day operations: start, stop, restart, update and recreate; deploy, back up, prune, run schedules, unban. No accounts, secrets, files, `.env`, host or DCS changes. Several sessions at once. |

- Create accounts on the **Users** page: invite people with a code (sign-up is invite-only; codes expire
  after 7 days), or create an account directly (for bots and family). Change a role there too; the last
  admin cannot be demoted, and a changed account is signed out.
- Passwords are hashed with PBKDF2-SHA256; logins are rate-limited and locked out after repeated failures.
  Each person can turn on **TOTP two-factor** login in their profile.
- By default a new login ends the account's older sessions (`API_SINGLE_SESSION`).
- The **Activity** page is the audit log: sign-ins, deploys, every start and stop, updates and more.

Every route's access level is listed in the [API reference](API.md). [SECURITY.md](../SECURITY.md)
describes the security model.

## Themes

- **The dashboard**: eight built-in themes (Nord, Dracula, Catppuccin, Solarized, Gruvbox, two light ones
  and the default) and a Theme Studio (*Settings → Appearance*) to make your own with a live preview.
  Themes are stored on the server, an admin sets the one every dashboard follows, and a theme can be
  exported as a file or installed from a file or an https address. CSS that loads or runs anything is
  removed.
- **Your apps**: for the apps [theme.park](https://theme-park.dev) supports (the \*arr apps, qBittorrent,
  Plex, Jellyfin, Uptime Kuma and many more), a container's page has a **Theme** button. DCS adds the
  theme.park middleware to the app's Traefik route; nothing inside the container changes, and **Remove
  theme** gives the app its own look back.

## The boot services

`setup.sh` offers them on the first run; you can install them any time:

```bash
sudo .scripts/install-service.sh              # install and start
sudo .scripts/install-service.sh --uninstall  # remove
```

| Service | What it does |
|---|---|
| `dcs-api` | Runs the API as your user (in the `docker` group) after Docker is up, and restarts it on failure |
| `dcs-stacks` | At boot, runs `start.sh --boot`: stacks in order, a health check, and a repair of Traefik's routes after a power cut |

```bash
systemctl status dcs-api
journalctl -u dcs-api -f
systemctl status dcs-stacks
```

On SELinux systems the installer labels the entry scripts so systemd may run them, and the units put the
label back before every start.
