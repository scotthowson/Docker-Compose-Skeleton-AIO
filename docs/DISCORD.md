# Discord × DCS — the complete setup guide

Everything DCS can do with Discord, and every click it takes. Four pieces, each optional:

| Piece | What it does | What it needs |
| --- | --- | --- |
| **Notifications webhook** | The API posts embeds to a channel: container problems, deploys, backups, disk space, image updates, health changes, automations, UPS events, DCS self-updates | A channel webhook URL pasted into Server Config |
| **CrowdSec alerts** | Every ban CrowdSec issues lands in a channel with the attacker's address, country, network, scenario and duration | The `crowdsec` template (uses the same webhook, or its own) |
| **The bot** (`DCS Discord Bot` template) | Slash commands with buttons: `/status`, `/health`, `/containers`, `/restart`, `/deploy`, `/backup`, `/security` … | A Discord application with a bot token, plus a DCS bot account (created for you) |
| **Rich Presence** (desktop app) | "Managing *your server* · 17/17 containers · all healthy" on your own Discord profile while DCS Manager is open | A Discord application ID pasted into the desktop app's Settings |

Discord IDs (server, channel, user, role) are copied with **Developer Mode** on: Discord → User Settings → Advanced → Developer Mode. Right-click anything → *Copy … ID*. IDs are not secrets; bot tokens and webhook URLs are.

---

## 1. Notifications webhook

### Create the webhook in Discord
1. Open the channel that should receive the messages (for example `#dcs-alerts`) → the gear icon → **Integrations** → **Webhooks** → **New Webhook**.
2. Name it anything (DCS sets its own name and avatar on every post) and make sure the right channel is selected.
3. **Copy Webhook URL**. It looks like `https://discord.com/api/webhooks/1234…/abcd…`. Treat it like a password: anyone holding it can post in that channel.

Renaming or moving the channel later changes nothing — a webhook is bound to its channel by ID.

### Give it to DCS
Either of these, they are the same setting (`DISCORD_WEBHOOK_URL` in the root `.env`):

- **Dashboard:** Server Config → *Notifications* → **Discord webhook** → paste → **Save**. The field shows only the last characters afterwards.
- **Secret store:** Secrets page → add `DISCORD_WEBHOOK` with the URL → set `DISCORD_WEBHOOK_URL=${SECRETS_DISCORD_WEBHOOK}` (the config field accepts the reference as well).

Then **Notifications → Send test**. A "Test notification" embed appears in the channel within a second. If it does not, the page tells you which channel failed and why (`404` means the webhook was deleted in Discord, `0` means the server cannot reach discord.com).

### Name, avatar, link
Under the same Server Config section:

| Setting | `.env` key | Meaning |
| --- | --- | --- |
| Discord name | `DISCORD_WEBHOOK_NAME` | The name the posts appear with (default `DCS Manager`) |
| Discord avatar | `DISCORD_WEBHOOK_AVATAR` | Any https image; empty = the DCS icon |
| Dashboard URL | `DASHBOARD_PUBLIC_URL` | Every title links here (falls back to `https://ui.<PROXY_DOMAIN>`) |
| Server name | `SERVER_NAME` | Shown as the author line of every embed |

### What a message looks like
Every post is one embed: your server's name and icon as the author line, an emoji and a colour per event (emerald good · amber warning · rose bad · cyan information · violet backups), the message as text, the event's facts as fields (**stack**, **container**, status, template, mount …), and a footer with the event, host and DCS version. Nothing in a message can ping anyone.

### Rules: which events post
Notifications page → **New rule** (or a preset). A rule has a trigger, a target (`*`, a stack or a container), a priority, optional title and message templates, and a cooldown.

| Trigger | Fires when | Default cooldown |
| --- | --- | --- |
| `container_unhealthy` | A running container fails its health check, or restarts more than the alert threshold | 60 min (`NOTIFY_COOLDOWN_MINUTES`) |
| `container_stopped` | A container is not running (and is not an on-demand one) | 60 min |
| `container_high_cpu` / `container_high_memory` | A container is over the CPU / memory threshold from the Alerts settings (checked every minute) | 60 min |
| `disk_warning` | A mounted filesystem is over the disk threshold (checked every minute) | 6 h |
| `stack_down` | A stack was stopped from DCS | always |
| `stack_failed` | A start, restart or deploy left a stack broken | always |
| `deploy_complete` | A template deployment came up | always |
| `update_available` | A registry check found newer images (once per set of images) | daily |
| `image_stale` | Images older than 30 days exist | daily |
| `health_change` | The server's overall verdict changed (healthy ↔ degraded ↔ critical) | always |
| `backup_complete` / `backup_failed` | A backup finished or failed | always |
| `automation_run` | An automation ran | always |

Cooldown: while a problem persists, the same rule for the same container repeats at most once per cooldown; when the container recovers, the next problem posts right away. Set a rule's own cooldown in the rule form, or change the default for container rules under Server Config → *Repeat cooldown* (`0` = every check, about every 10 seconds while the dashboard is open — noisy).

Templates use `{stack}`, `{container}`, `{status}`, `{event}`, `{timestamp}`, `{hostname}`, and per event `{template}`, `{action}`, `{mount}`, `{message}`, `{automation}`. Leave them empty for DCS's own wording.

Rules also go to ntfy when `NTFY_URL` is set. UPS events, DCS self-updates and automation "send a notification" actions post without a rule. Everything sent is listed under Notifications → History.

---

## 2. CrowdSec alerts

Deploying the `crowdsec` template asks for a **Discord webhook for alerts**. Leave it empty to reuse the server's webhook, or paste a different one to keep bans in their own channel (create it exactly like in section 1). DCS renders the alert template with that URL and your domain, copies it into the container, and restarts CrowdSec once so the plugin reads it.

Each ban is one embed: what was blocked in plain words (SSH brute force, web probing, exploit attempt …), the address with its flag and network, the number of hits, the decision and its duration, the scenario, links to CrowdSec CTI and AbuseIPDB, and the first request that triggered it when there was one.

**Already running CrowdSec?** Re-apply the template to it without redeploying:

```bash
TOKEN=$(curl -s -X POST http://127.0.0.1:9876/auth/login -H 'Content-Type: application/json' \
  -d '{"username":"YOUR_ADMIN","password":"YOUR_PASSWORD"}' | jq -r .token)
curl -s -X POST http://127.0.0.1:9876/crowdsec/notifications -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"test": true}'
```

`{"webhook": "https://discord.com/api/webhooks/…"}` in the body points it at another channel; `"test": true` posts a sample alert so you can see it land. The API restarts CrowdSec and waits for it to be healthy again (a few seconds; the Traefik bouncer keeps its decision cache meanwhile).

---

## 3. The bot

### Step 1 — create the Discord application
1. [discord.com/developers/applications](https://discord.com/developers/applications) → **New Application** → name it (for example `DCS Commands`).
2. **Bot** tab → **Reset Token** → copy the token. It is shown once; this is `DISCORD_BOT_TOKEN`.
3. Same tab: give it an avatar and banner from the [brand kit](#5-brand-kit) if you like. No privileged intents are needed.
4. **OAuth2** tab → note the **Client ID** (also the Application ID).
5. Invite it with this URL (replace `APP_ID`):

   ```
   https://discord.com/oauth2/authorize?client_id=APP_ID&scope=bot%20applications.commands&permissions=117760
   ```

   `117760` = View Channels + Send Messages + Embed Links + Attach Files + Read Message History. Pick your server, **Authorize**.

### Step 2 — collect the IDs
With Developer Mode on:

| ID | Where | Used for |
| --- | --- | --- |
| Server ID | right-click your server → Copy Server ID | `DISCORD_GUILD_ID` — commands register there instantly (global registration takes up to an hour) |
| Channel ID | right-click the channel → Copy Channel ID | `DISCORD_CHANNEL_IDS` — the only channel(s) the bot answers in |
| Your user ID | right-click yourself → Copy User ID | `DISCORD_ADMIN_IDS` — who may run commands that change the server |
| Role ID (optional) | Server Settings → Roles → … → Copy Role ID | `DISCORD_ADMIN_ROLE_IDS` — a role whose members count as admins |

### Step 3 — the bot's DCS account
The bot signs in to the DCS API with its own account, never yours (single-session mode would sign you out). The template creates it for you with the **bot** role. A bot account can look at everything a user can plus the audit log and backups, and may start, stop, restart, update and recreate stacks and containers, deploy templates, run backups, prune, run schedules and lift CrowdSec bans. It cannot touch accounts, secrets, files, `.env`, the host, networks or DCS itself, and it may keep several sessions open. Change a role any time on the Users page (the account's sessions are signed out).

Want `/dcs update` and `/dcs restart` from Discord as well? Give the bot's account the **admin** role on the Users page. Everything else works with the bot role.

### Step 4 — deploy the template
Templates → **DCS Discord Bot** → Deploy. The variables:

| Variable | Value |
| --- | --- |
| `DISCORD_BOT_TOKEN` | from step 1 (press the lock to keep it in the secret store) |
| `DISCORD_GUILD_ID` | your server ID |
| `DISCORD_ADMIN_IDS` | comma-separated user IDs allowed to change things |
| `DISCORD_ADMIN_ROLE_IDS` | comma-separated role IDs with the same rights (optional) |
| `DISCORD_CHANNEL_IDS` | comma-separated channel IDs the bot answers in; empty = anywhere it is invited |
| `DCS_BOT_USERNAME` | the DCS account for the bot (default `discord-bot`); created as a bot account if missing |
| `DCS_BOT_PASSWORD` | its password (lock it into the secret store) |
| `DCS_API_URL` | `http://host.docker.internal:9876` on Linux with the default port |
| `DCS_DASHBOARD_URL` | optional link on every reply, e.g. `https://ui.example.com` |

The container is `DCS-Discord-Bot` in the `monitoring-management` stack. Its log (Containers → DCS-Discord-Bot → Logs) should read:

```
signed in to Discord as DCS Commands#1234
signed in to DCS at http://host.docker.internal:9876 as discord-bot
registered 24 commands in guild 2537…
```

Changing a value later: Stacks → monitoring-management → **.env** → edit → restart the bot (or deploy the template again with the new values).

### Step 5 — use it
Type `/` in the channel. Names autocomplete while you type. Every reply has buttons: 🔄 refresh, navigation between views, and for admins the actions that fit (Restart, Stop, Recreate, Update, Deploy …). Anything destructive asks the person who ran the command to confirm within 60 seconds; nobody else can confirm it.

| Read | What you get |
| --- | --- |
| `/status` | Overview: containers, stacks, health score, load, memory, every drive, uptime, DCS version |
| `/usage` | CPU, memory, swap and each mounted drive with bars |
| `/health` | Unhealthy, restarting, stopped and sleeping containers, with a "restart all unhealthy" button |
| `/containers [filter] [show]` | Every container grouped by stack |
| `/stacks` | Every stack with its container count and health |
| `/top` | Busiest containers by CPU and memory |
| `/disk` | Drives, Docker disk usage, biggest App-Data folders, prune button |
| `/updates` | Newer images and images older than 30 days; check the registry; update everything |
| `/logs <target> [lines]` | Last lines of a container or stack, visible only to you |
| `/routes [check]` | Domains Traefik serves, optionally probed |
| `/vms` | Every Proxmox node and guest: state, CPU, memory, uptime (needs the Proxmox link) |
| `/vm <vm> <action>` | `info`, or `start`, `shutdown`, `stop`, `reboot`, `reset`, `suspend`, `resume` a VM or container — admins, with a confirmation for anything but start and resume |
| `/power` | UPS state |
| `/security` | CrowdSec bans and trusted addresses |
| `/schedules` · `/audit [count]` · `/dcs` · `/help` | Schedules and automations · recent actions · DCS version and updates · this list |

| Act (admins) | What happens |
| --- | --- |
| `/start` · `/stop` · `/restart <target>` | A stack or a container; stops ask for confirmation |
| `/update <stack|container|all>` | Pull newer images and recreate what changed |
| `/container <name> [action]` · `/stack <name> [action]` | Info cards with action buttons |
| `/deploy <template> [stack]` | Dry-run first (ports, variables, conflicts), then a confirm button |
| `/backup [stack]` · `/backup list:true` | Run a backup and watch it finish · list recent ones |
| `/prune` | Remove stopped containers, dangling images, unused networks (on-demand containers are kept) |
| `/run <schedule>` · `/unban <ip>` | Run a schedule now · lift a CrowdSec ban |
| `/dcs action:update` · `/dcs action:restart` | Self-update DCS · restart the API (needs an admin-role bot account) |

The bot's own status line mirrors the server: *Watching 17 containers · all healthy* (green), a stopped container turns it idle (yellow), an unhealthy one busy (red).

**Locking it to a channel.** `DISCORD_CHANNEL_IDS` makes the bot answer only there (elsewhere it replies, privately, where to go). Discord can also hide the commands from other channels: Server Settings → Integrations → your bot → **Command Permissions** → Channels.

### Troubleshooting
- **No commands appear** — check `DISCORD_GUILD_ID`, invite the bot again with the `applications.commands` scope, restart Discord. Global registration (empty guild ID) takes up to an hour.
- **"I can't reach DCS at …"** — the API must listen where the container can reach it: `API_BIND=0.0.0.0` (Server Config) and the default `DCS_API_URL=http://host.docker.internal:9876`.
- **"DCS refused the bot's sign-in"** — `DCS_BOT_USERNAME` / `DCS_BOT_PASSWORD` do not match the account on the Users page.
- **"the bot's user is not an admin"** — that command needs more than the bot role; make the account admin on the Users page, or run it from the dashboard.
- **"your Discord account is not on the admin list"** — add your user ID to `DISCORD_ADMIN_IDS` (or your role to `DISCORD_ADMIN_ROLE_IDS`) and restart the bot.

---

## 4. Rich Presence (desktop app)

1. [discord.com/developers/applications](https://discord.com/developers/applications) → **New Application** → name it `DCS Manager` (a separate application from the bot keeps the profile text clean, but the bot's application works too).
2. **General Information**: upload `app-icon.png` as the App Icon, fill **Terms of Service URL** and **Privacy Policy URL** — DCS Manager's live at
   `https://github.com/scotthowson/Docker-Compose-Skeleton-UI/blob/main/TERMS.md` and
   `https://github.com/scotthowson/Docker-Compose-Skeleton-UI/blob/main/PRIVACY.md`.
3. **Rich Presence → Art Assets**: upload `presence-dcs.png` as `dcs`, `presence-healthy.png` as `healthy`, `presence-warning.png` as `warning` (the names matter).
4. Copy the **Application ID**.
5. DCS Manager (desktop) → Settings → **Discord Rich Presence** → paste the ID → switch it on. Discord must be running on the same computer. In Discord → User Settings → Activity Privacy, "Share your activity status" must be on.

Your profile then shows *Managing <server> · 17/17 containers · 9 stacks · all healthy*, how long the app has been open, and a "Get DCS" button. Everything shown is what the app already sees; nothing else leaves your machine.

---

## 5. Brand kit

`brand/discord/` in the DCS Manager repository holds ready-made artwork (SVG sources, `render.sh` rebuilds the PNGs):

| File | Where to put it |
| --- | --- |
| `app-icon.png` (1024²) | Developer portal → application → General Information → App Icon (both applications) |
| `bot-avatar.png` (1024²) | Developer portal → Bot → Avatar (the slash badge) |
| `bot-banner.png` (1360×480) | Developer portal → Bot → Banner |
| `webhook-avatar.png` (1024²) | Used automatically by notification posts (`DISCORD_WEBHOOK_AVATAR` overrides it); also fine as the webhook's own avatar in Discord |
| `crowdsec-avatar.png` (1024²) | Used automatically by CrowdSec alerts |
| `presence-dcs.png`, `presence-healthy.png`, `presence-warning.png` | Rich Presence → Art Assets as `dcs`, `healthy`, `warning` |

---

## 6. Generic webhooks (Integrations)

Notifications page → **Webhooks** posts audited events to any URL, and this is the simplest way to get
a Discord channel that follows the server without writing rules: paste a Discord webhook URL, tick the
events, done. A Discord URL receives the same embeds as section 1; a Slack incoming webhook receives
text; anything else receives `{event, title, detail, timestamp, hostname, server, version}` as JSON.
"Test" sends a sample so you can see the shape. The picker groups the events:

| Group | Events |
| --- | --- |
| Containers | `container_stopped` (on its own), `container_unhealthy`, `container_recovered`, `container_start`, `container_stop`, `container_restart`, `container_recreate`, `container_remove`, `container_reset` (nuke & reinstall) |
| Stacks & deploys | `deploy`, `undeploy`, `stack_start`, `stack_stop`, `stack_restart`, `stack_update`, `automation_run` |
| Health & space | `health_change` (the overall verdict), `disk_warning` (once per threshold crossing) |
| Backups & DCS | `backup_complete`, `backup_failed`, `recovery_bundle`, `recovery_restore`, `system_update`, `system_rollback`, `api_restart` |
| Security & accounts | `login_fail`, `lockout`, `login_ok`, `user_create`, `user_role`, `crowdsec_unban` |
| Proxmox | `proxmox_vm_stopped` (a guest stopped on its own), `proxmox_vm_started` (came back without DCS), `proxmox_vm_start`, `proxmox_vm_shutdown`, `proxmox_vm_stop`, `proxmox_vm_reboot`, `proxmox_vm_reset`, `proxmox_vm_suspend`, `proxmox_vm_resume` (by DCS) |

Stops and starts DCS performs itself (a stack stop, a deploy, a nuke, the UPS shutdown) are never
reported as crashes or recoveries; only what happens on its own is. When more than five containers
change in the same health poll you get one summary message instead of a flood.

---

## 7. Reference

Colours and emoji per event (the same on every channel):

| Event | Emoji | Colour |
| --- | --- | --- |
| container unhealthy · stack failed · backup failed | 🩺 💥 💾 | rose |
| container stopped · stack stopped · disk space · high CPU/memory · health changed · power · DCS rolled back | ⏹️ 🛑 💽 🔥 🧠 💓 ⚡ ⏪ | amber |
| deployed · stack started | 🚀 ▶️ | emerald |
| updates · automations · DCS update · on demand · dynamic DNS · CrowdSec · test | ⬆️ 🤖 🔄 💤 🌐 🛡️ 🔔 | cyan |
| backup finished · recovery bundle | 💾 🧳 | violet |
| removed · sign-ins | 🧹 🔑 | slate |

`.env` keys involved: `DISCORD_WEBHOOK_URL`, `DISCORD_WEBHOOK_NAME`, `DISCORD_WEBHOOK_AVATAR`, `NOTIFY_COOLDOWN_MINUTES`, `SERVER_NAME`, `DASHBOARD_PUBLIC_URL`, `NTFY_*`. Bot variables live in the `monitoring-management` stack's `.env`.
