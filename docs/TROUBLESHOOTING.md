<sub>[← Operations](OPERATIONS.md) · [Docs index](README.md) · Next: [Development →](DEVELOPMENT.md)</sub>

# Troubleshooting

Real problems people have met, and their fixes. Find the symptom, read the fix. For the Proxmox link and
VM builds, the [Proxmox guide's table](PROXMOX.md#7-troubleshooting) goes step by step.

- [Setup](#setup)
- [The dashboard and the API](#the-dashboard-and-the-api)
- [Stacks, containers and templates](#stacks-containers-and-templates)
- [Proxy, DNS and certificates](#proxy-dns-and-certificates)
- [Updates](#updates)
- [Proxmox and the fleet](#proxmox-and-the-fleet)
- [Finding out more](#finding-out-more)

## Setup

| Symptom | Cause and fix |
|---|---|
| *Run ./setup.sh as your normal user, not with sudo.* | Setup run with `sudo` would leave files owned by root and start the API as root. Run it as your user, who needs to be in the `docker` group: `sudo usermod -aG docker $USER`, log out and in, run `./setup.sh` again. |
| *Docker is NOT installed on this system.* | Install Docker Engine with the Compose plugin (`curl -fsSL https://get.docker.com \| sudo sh`), then run `./setup.sh` again. |
| *Docker is installed, but its service is not running*, or *may not use Docker yet* | Setup offers both fixes on a terminal and carries on. By hand: `sudo systemctl enable --now docker`, `sudo usermod -aG docker $USER`, then log out and in (or `newgrp docker`) and run `./setup.sh` again. |
| *The API server needs tools this system does not have yet* | Setup offers to install them on a terminal. An unattended run never installs anything: install `jq`, `socat`, `curl`, `git`, `openssl` and `python3` first. |
| *API server failed to start* | `logs/api-server.log` names the process that holds the port. Stop it, or set another `API_PORT` in `.env`. |
| Setup prints *Containers from an earlier install — the core infrastructure starts anew* on a brand-new machine | Harmless: with Docker 29, setup's check mistakes a missing container for an old one and starts the dashboard with `--force-recreate`. The dashboard comes up as normal. |
| The dashboard container is *unhealthy*, its log says `socketpair() failed (13: Permission denied)` | Debian's own `docker.io` 26 with AppArmor 4 blocks nginx. Setup (3.9.1 and later) writes `DCS_UI_APPARMOR=unconfined` into `Stacks/core-infrastructure/.env`. On an older install add that line and run `./compose.sh core-infrastructure up -d dcs-ui`, or install Docker CE, which needs nothing. |
| In an LXC container: `failed to mount … fstype: overlay … permission denied` | The container lacks nesting. On the Proxmox host: `pct set <id> --features nesting=1,keyctl=1`, then restart it. [INSTALL-LXC](INSTALL-LXC.md#caveats) |
| Fedora: containers cannot write their `App-Data`; Traefik cannot read the Docker socket | Fedora's own Docker package confines containers with SELinux. Setup offers to run them the way Docker CE does (SELinux stays on for the rest of the system). Or keep it and add `:z` to every volume. |
| Fedora: the hub's VMs cannot join, or a build stops at *Install* with *could not fetch the DCS bundle* | firewalld blocks the API port. `sudo firewall-cmd --permanent --add-port=9876/tcp && sudo firewall-cmd --reload`, then *Retry*. |

## The dashboard and the API

| Symptom | Cause and fix |
|---|---|
| The wizard never appears, or the dashboard flips between *Connection Unstable* and *Connection Restored* | The browser tab holds a session from an earlier install. Reload the page (Ctrl+Shift+R) or sign out. |
| The dashboard shows **Not answering**, **Reconnecting…** or **Offline** *(4.0)* | The API does not answer. On the server: `systemctl status dcs-api`, `curl -s http://127.0.0.1:9876/ping`, and the end of `logs/api-server.log` or `journalctl -u dcs-api -n 50`. |
| Everything but the setup answers `401` | No admin exists yet: a fresh install answers only its setup. Finish the wizard. |
| The dashboard is gone after a reboot | The API ran from setup, outside systemd. Install the boot services: `sudo .scripts/install-service.sh`. |
| The dashboard behind Traefik answers `502` after changing `DCS_UI_PORT` | That setting moves only the host port. Traefik reaches the container over the proxy network, so its route must keep `http://DCS-UI:3000`. |
| A viewer account gets `403` on an action | By design: only admins change things. The [API reference](API.md) lists every route's access level. |
| The phone or desktop app cannot connect from outside | Type the dashboard's address (`https://ui.<your-domain>`) into the app's Connect screen: it finds the `/api` path by itself. Port 9876 never needs to be opened to the internet. |

## Stacks, containers and templates

| Symptom | Cause and fix |
|---|---|
| `The "SECRETS_…" variable is not set` when you run `docker compose` by hand | Only DCS resolves `${SECRETS_…}` references. Use `./compose.sh <stack> …`, which applies the `.env` files and the secret store. |
| A stack will not start: *references secrets that do not exist* | The compose or `.env` names a `${SECRETS_…}` value the store does not have. Add it on the Secrets page and start again. |
| A deploy is refused: *Host port conflict* or *Host port(s) already in use* | Another service already publishes that port. Several templates share a default port (Jellyfin and FreshRSS on 8096, Kavita and pgAdmin on 5050, and so on), and the placeholder services of a fresh clone use 8080 to 8082. Pick another port on the deploy sheet. |
| *Singleton template … is already deployed* | It may run once per server. Use the one you have, or replace it (`replace_services: true`). |
| *Protecting a route needs Authelia* | Deploy the Authelia template first, or switch the route's Authelia switch off. |
| *Start on demand needs Sablier* | Deploy the Sablier template first. It is not offered for a stack that lives in a VM. |
| An app answers without the Authelia portal | Templates whose apps bring their own clients (*Own sign-in* in the [catalogue](TEMPLATES.md#the-catalogue)) stay open on purpose. The deploy sheet's switch decides otherwise. |
| *Run Command* on the Containers page stops after 30 seconds | It runs without a terminal and with its input closed, so interactive programs (`ollama run`, editors, shells) end or time out. Use the Terminal page. |
| A settings file was replaced by an empty one, and a `…corrupt-<time>` file appeared | An empty or broken state file (after a crash) is set aside and replaced by an empty default, with an entry in the audit log. The old file is there to inspect. |

## Proxy, DNS and certificates

| Symptom | Cause and fix |
|---|---|
| After a power cut Traefik is up but no site answers | The stacks came up before Traefik could load its plugins or reach the Docker socket. The boot service (`start.sh --boot`) probes every route once the stacks are healthy and restarts Traefik if none answer. `GET /routes/health` shows the probe; `POST /routes/reconcile` runs it now. |
| The browser warns about the certificate, or Cloudflare answers `526` | Traefik has no certificate yet. With a Cloudflare token it uses the DNS challenge; without one, port 80 must reach Traefik for the HTTP challenge. The **Certificates** panel on *DNS & Routes* (`GET /routes/certificates`) shows the challenge, every certificate and the last ACME errors. |
| Traefik answers `404` for an app | The route names a middleware or service that does not exist, or another domain. The same Certificates panel probes every route and names the usual cause. |
| CrowdSec banned your own address (the site works on the phone, not on the PC) | The **Protection** card on the dashboard has *Unban me* and *Trust my address*. Your public address is whitelisted every ten minutes; `CROWDSEC_TRUSTED_IPS` pins more. |
| DNS records are missing or wrong | The *DNS & Routes* page manages the Cloudflare zone and links each record to the route that uses it; *Create N missing* makes the records routes lack. Keep the token as the secret `CF_DNS_API_TOKEN`. |

## Updates

| Symptom | Cause and fix |
|---|---|
| The update stops: *local changes to framework files would be overwritten* | You edited a file DCS ships. Tick the box to replace it (your copy is kept in `.data/update-backups/`), or undo the edit. |
| Fedora: after an update the API does not start; `journalctl -u dcs-api` says `203/EXEC` | SELinux: the new script lost its `bin_t` label. 3.9.9 and later put it back by themselves. By hand: `chcon -t bin_t ~/.Docker-Compose-Skeleton-AIO/.scripts/api-server.sh && sudo systemctl restart dcs-api`, and run `sudo .scripts/install-service.sh` once. |
| An image update reported success but the containers kept the old image | Fixed in 3.9.9: updates now recreate the containers on an older copy. Update DCS, then press *Recreate* on the Updates page. |
| An unattended update rolled itself back | The health score dropped by more than `UPDATE_ROLLBACK_DROP` within `UPDATE_HEALTH_GRACE` seconds. The Updates page lists the attempt and why; update by hand and watch what fails. |

## Proxmox and the fleet

| Symptom | Cause and fix |
|---|---|
| *Proxmox rejected the API token* (401) | The token ID must be `user@realm!name`; the secret is the UUID shown when the token was made. |
| *The API token lacks permission* (403) | Give `VM.Audit`, `VM.PowerMgmt` and `Sys.Audit` on `/`, to the user (privilege separation off) or to the token. Building VMs needs more: [the roles](PROXMOX.md#building-the-vms). |
| *did not answer* | Use the address of the Proxmox web UI, `https://<host>:8006`. Switch *Verify certificate* off for the self-signed certificate. |
| A VM build fails at a step | Each step's failures and fixes are in the [Proxmox guide](PROXMOX.md#7-troubleshooting): *Image*, *Create*, *SSH*, *Install*, *Join*, *Stack*. *Retry* resumes where it stopped. |
| A VM's memory shows near 100 % while it idles | Without a memory balloon Proxmox shows its whole allocation. VMs the hub builds get one; for an older VM use *Enable ballooning* in its sheet and reboot it. |
| A VM's events do not reach the hub's Discord or ntfy | The member has no relay token yet; the hub hands one out within a minute of reaching it. |

## Finding out more

- `logs/` holds the API's log (`api-server.log`), stack actions (`stack-actions.log`), image updates
  (`image-update.log`) and the framework's own logs.
- `journalctl -u dcs-api -f` and `journalctl -u dcs-stacks` follow the boot services.
- `.scripts/config-validator.sh` checks the installation; `--fix` repairs what it can.
- `LOG_LEVEL=DEBUG ./start.sh`, or `./start.sh --debug` for a full trace.
- The **Diagnostics** page shows the port map and a health matrix; `GET /health` the same as JSON.
- Still stuck? Open an issue with `cat VERSION`, what you did and what you saw. Report security problems
  privately, as [SECURITY.md](../SECURITY.md) describes.
