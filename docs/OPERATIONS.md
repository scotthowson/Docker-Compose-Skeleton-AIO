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
| `backup-server.sh` | The Backup page's backup, in the foreground (`[stack]` for one stack) |
| `proxy-reconcile.sh` | Probes every Traefik route and restarts Traefik once when none answer |

Each one prints its options with `--help`.

</details>

## Stacks and containers

The dashboard does everything the commands do, and more:

- **Stacks** (on a hub, the VMs' stacks too): start, stop, restart and update a stack; follow its progress (pull,
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

The folders are the stack's own: with the default `APP_DATA_DIR=./App-Data` every stack keeps its data
in `Stacks/<stack>/App-Data`, and that is where the nuke looks and where its trash is
(`Stacks/<stack>/App-Data/.trash`). An `App-Data` that Docker made belongs to root; the move into the
trash is done as root in a small container, so nothing is lost there either. With an absolute
`APP_DATA_DIR` (one root for every stack) only what lies two levels below the root counts as a
container's own. A container in a VM is nuked in its VM: the hub forwards the request.

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
| **Backup** | Everything a server runs on: every stack's folder (compose, `.env`, App-Data, data) with its named volumes, and the install's own state | Backup page; set `BACKUP_DEST_DIR` first; `BACKUP_RETENTION_COUNT` kept of each kind |
| **Snapshot** | The configuration: every stack's compose, `.env` and config files, the root `.env`, accounts and rules, templates, Traefik's routes, the schedules | Snapshots page; download or restore any one |
| **Rollback snapshot** | A stack's files, taken before a change | Per stack, `ROLLBACK_MAX_SNAPSHOTS` kept |
| **Recovery bundle** | Everything needed to rebuild the install, encrypted | See [below](#the-recovery-bundle) |

**What a backup holds and leaves out** *(4.0.28)*

| In it | Left out |
|---|---|
| Each stack's whole folder: `docker-compose.yml`, `.env`, config files, `App-Data`, `data`, files of every owner (a database's, root's) with owners and modes as numbers | The link to a VM's App-Data on a hub (`Stacks/<name>/VM-App-Data`, an sshfs mount): that data is the VM's, in the VM's own backup |
| Each named volume of a stack (`com.docker.compose.project` label) | Volumes a compose file declares `external`, and folders outside the stack (a media library): back those up where they live |
| `.env`, accounts and their layouts, notification rules, automations | Sessions, invite codes, rate limits, logs, caches, metrics |
| `.secrets/*.enc` | The secret store's key, `.secrets/.master-key`: keep it elsewhere, or use the recovery bundle, which carries it encrypted |
| `.data`: the fleet (`fleet.json`, the hub's ssh key to its VMs), schedules, CrowdSec, the intended state | `.data/cache`, `.data/metrics`, sessions to the VMs, `.data/recovery`, `.data/pre-restore` |
| `.config`, `.templates`, `.plugins`, `.compose-history`, `.snapshots`, `VERSION` | The DCS code itself (reinstall it; the manifest names the version) and `.git` |

- **Readable whatever the owner.** The stack folders and volumes are read as root, with passwordless sudo, or through a
  small read-only helper container (`alpine`), whichever the server has (*Config → Backup* shows which as `reads_as`).
  A file nothing can read is **named** in the result and the backup is marked incomplete (status `error`, notification
  `backup_failed`): nothing is left out without a word.
- **A database is copied as it was at one instant.** The stack's running containers are paused (`docker pause`) while its
  folder and volumes are read, then resumed: SQLite (Sonarr, Radarr…), Postgres and MySQL find the copy the way a power cut
  would leave them, which they recover from. A paused stack does not answer while it is read: seconds for most, longer for
  a large library. `BACKUP_PAUSE_EXCEPT="adguard plex"` reads those stacks while they run; `BACKUP_PAUSE=false` never
  pauses. A cancelled backup, or one the API's restart cut short, resumes them.
- **Checked.** The archive is written aside, read back to the end (gzip and tar), every part its manifest names is in it,
  and only then it takes its name, with a `.sha256` beside it. *Verify* (`POST /backups/verify`) checks one again later; a
  restore refuses an archive that fails it.
- **Room.** Nothing is staged in `/tmp`. The parts are written next to the archive, so the destination needs about twice
  the data free while a backup runs; the backup says so before it starts when it does not.
- **No rsync needed** (the DCS VM images have none: before 4.0.28 a backup there finished "done" with an empty archive).

**Restoring** asks for a confirmation and runs in the background (*GET /backups/status*):

1. The archive is checked, and every part listed: an entry with `..`, an absolute name, a hard link out, or a file under a
   link is refused before anything is touched. Links that point outside are left out of the install's files.
2. The stacks it restores are stopped (`docker stop`, `BACKUP_RESTORE_STOP_TIMEOUT` seconds, 20).
3. Each stack's folder as it is now is **set aside** in `.data/pre-restore/<time>/` (a rename, nothing is copied), then the
   archive's copy takes its place, owners and modes as they were. A database's `-wal` written after the backup cannot
   be replayed over the restored database: the folder is the backup's, file for file. The link to a VM's App-Data goes back.
4. Each volume as it is now is saved to the same folder, emptied, and filled from the archive.
5. A full backup also brings back the install's state (`.env`, accounts, secrets, `.data`, settings): sessions and the
   secret store's key stay as they are, the settings files DCS ships stay the code's, templates already here stay.
   Restart the API afterwards so it reads the restored `.env` (the result says so).
6. The containers start again.

`{"stack": "sonarr"}` restores that stack alone (from a full backup or its own). The newest two sets in
`.data/pre-restore` are kept (`BACKUP_PRE_RESTORE_KEEP`). A backup made before 4.0.28 (no manifest) is unpacked over the
install as before, minus links that point outside.

By hand, on any machine: `tar -xzOf Docker-Compose-Backup-….tar.gz ./.dcs-backup/manifest.json` lists the parts, and
`tar -xzOf Docker-Compose-Backup-….tar.gz ./.dcs-backup/stacks/<stack>.tar | sudo tar --numeric-owner -xpf - -C Stacks/<stack>`
puts one stack's folder back.

**Snapshots** are light and quick: the configuration only, no App-Data. A restore takes a snapshot of the current state
first (*before restoring …*), puts every stack's files back (a stack that runs in a VM gets them in the VM too; it uses
them at its next start), with the routes, the schedules, notification rules and templates. It never restores the root
`.env` (it lands in `.env.restored`), accounts or secrets. *(Before 4.0.28 every snapshot restore failed: the tar option
it used does not exist.)*

**On a hub**, *Back up everything* starts a backup on the hub and on every VM (each VM needs its own `BACKUP_DEST_DIR`),
and *Create snapshot* on *Everywhere* (`POST /snapshots/create?fleet=1`) takes one snapshot on the hub and one on every
VM; a VM that does not answer is named in the result, the others still get theirs. The hub's backup holds the VM stacks'
files and the hub's own copy of their old App-Data, never the live data in the VMs: that is each VM's own backup.

**On Proxmox**, back up the VM (or container) as well. Proxmox's own backups cover the disk DCS and the
app data live on; with the QEMU guest agent the file system is frozen for a consistent copy.

`.scripts/backup-server.sh [stack]` makes the same backup in the foreground (the scheduler's `backup` action makes it too).

## The recovery bundle

One encrypted file (AES-256) that rebuilds the install on another machine: the root `.env`, the secret
store with its key, accounts, notification rules and dashboard layouts, schedules, every stack's files,
Traefik's and Authelia's data, templates and plugins. App data of the stacks you choose can go along (read like a
backup reads it, so a database's files are in it; they come back owned by DCS's user). It needs no rsync *(before
4.0.28 it refused to run without it, which the DCS VM images do not have)*.

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

Two channels, both optional, set in *Config → Notifications*:

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

**Schedules** run an action on a cron timetable (*Schedules* page):

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
