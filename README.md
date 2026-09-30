<p align="center">
  <img src="docs/img/banner.svg" alt="DCS Orchestrator: plain Docker Compose stacks, a Proxmox fleet where every stack is its own VM, and one dashboard for all of it" width="100%">
</p>

<p align="center">
  Run your Docker Compose stacks from one dashboard,<br>
  on one server or across a Proxmox host where every stack lives in its own VM.
</p>

<p align="center">
  <a href="https://github.com/scotthowson/dcs-orchestrator/releases"><img src="https://img.shields.io/github/v/release/scotthowson/dcs-orchestrator?include_prereleases&sort=semver&style=flat-square&label=release&color=34d399" alt="Latest release"></a>
  <a href="https://github.com/scotthowson/dcs-orchestrator/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/scotthowson/dcs-orchestrator/ci.yml?style=flat-square&label=CI&logo=githubactions&logoColor=white" alt="CI status"></a>
  <a href="https://github.com/scotthowson/dcs-orchestrator/actions/workflows/vm-images.yml"><img src="https://img.shields.io/github/actions/workflow/status/scotthowson/dcs-orchestrator/vm-images.yml?style=flat-square&label=VM%20images&logo=githubactions&logoColor=white" alt="VM images build status"></a>
  <a href="https://github.com/scotthowson/dcs-orchestrator/commits/main"><img src="https://img.shields.io/github/last-commit/scotthowson/dcs-orchestrator?style=flat-square&color=64748b" alt="Last commit"></a>
  <a href="https://github.com/scotthowson/dcs-orchestrator/stargazers"><img src="https://img.shields.io/github/stars/scotthowson/dcs-orchestrator?style=flat-square&color=fbbf24" alt="GitHub stars"></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Docker_Compose-v2-2496ED?style=flat-square&logo=docker&logoColor=white" alt="Docker Compose v2">
  <img src="https://img.shields.io/badge/Proxmox_VE-9-E57000?style=flat-square&logo=proxmox&logoColor=white" alt="Proxmox VE 9">
  <img src="https://img.shields.io/badge/Debian-13-A81D33?style=flat-square&logo=debian&logoColor=white" alt="Debian 13 image">
  <img src="https://img.shields.io/badge/Ubuntu-26.04-E95420?style=flat-square&logo=ubuntu&logoColor=white" alt="Ubuntu 26.04 image">
  <img src="https://img.shields.io/badge/Fedora-44-51A2DA?style=flat-square&logo=fedora&logoColor=white" alt="Fedora 44 image">
  <img src="https://img.shields.io/badge/Arch-rolling-1793D1?style=flat-square&logo=archlinux&logoColor=white" alt="Arch Linux image">
</p>

<p align="center">
  <a href="docs/TEMPLATES.md"><img src="https://img.shields.io/badge/templates-150%2B-34d399?style=flat-square" alt="150+ templates"></a>
  <a href="docs/API.md"><img src="https://img.shields.io/badge/REST_API-360%2B_endpoints-22d3ee?style=flat-square" alt="360+ API endpoints"></a>
  <a href="docs/VM-IMAGES.md"><img src="https://img.shields.io/badge/VM_images-8-a78bfa?style=flat-square" alt="8 VM images"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-fbbf24?style=flat-square" alt="MIT license"></a>
</p>

<p align="center">
  <a href="docs/GETTING-STARTED.md"><b>Get started</b></a> ·
  <a href="docs/README.md">Documentation</a> ·
  <a href="docs/TEMPLATES.md">Templates</a> ·
  <a href="docs/PROXMOX.md">Proxmox fleet</a> ·
  <a href="docs/API.md">API</a> ·
  <a href="docs/TROUBLESHOOTING.md">Troubleshooting</a>
</p>

> [!IMPORTANT]
> **4.0 is in release-candidate testing (`4.0.0-rc.1`).** A release candidate is a GitHub pre-release: the stable update channel still offers
> 3.9.9 and `latest` is still the last release. To try it, set the update channel to `main` (*Config → Update channel*) or import a release
> image ([docs/VM-IMAGES.md](docs/VM-IMAGES.md#get-an-image)). Please tell us what breaks in
> [Issues](https://github.com/scotthowson/dcs-orchestrator/issues).

---

DCS Orchestrator deploys, runs and watches your containers. Every stack stays a plain
`docker-compose.yml` that you can read and run by hand. Around it, DCS adds what a homelab or a
small server needs: 150+ ready templates, Traefik with wildcard HTTPS, Cloudflare DNS, Authelia
single sign-on, CrowdSec, updates with rollback, backups and a recovery bundle, health scores,
notifications, a Discord bot and a REST API.

Link a Proxmox host and one DCS becomes the **hub**. It builds a VM for each stack, installs
Docker and DCS in it, moves the stack in and then drives the whole host as one machine.

> [!NOTE]
> DCS Orchestrator was called **Docker Compose Skeleton AIO** until 4.0. It is the same project:
> the install directory, the settings and the API stay the same.

<table>
  <tr>
    <td width="33%"><a href="docs/img/screens/dashboard.png"><img src="docs/img/screens/dashboard.png" alt="The dashboard: stacks, containers, health and resources at a glance"></a></td>
    <td width="33%"><a href="docs/img/screens/proxmox.png"><img src="docs/img/screens/proxmox.png" alt="The Proxmox page: the node, this hub with its Proxmox tags, and every guest with the DCS it runs"></a></td>
    <td width="33%"><a href="docs/img/screens/templates.png"><img src="docs/img/screens/templates.png" alt="The template gallery: 151 templates grouped by category"></a></td>
  </tr>
  <tr>
    <td align="center"><sub>Dashboard</sub></td>
    <td align="center"><sub>Proxmox and the fleet</sub></td>
    <td align="center"><sub>Templates</sub></td>
  </tr>
  <tr>
    <td width="33%"><a href="docs/img/screens/containers.png"><img src="docs/img/screens/containers.png" alt="Every container on the hub and in its VMs, grouped by where it runs"></a></td>
    <td width="33%"><a href="docs/img/screens/health.png"><img src="docs/img/screens/health.png" alt="The Health page: every container on the hub and its VMs, and the health score"></a></td>
    <td width="33%"><a href="docs/img/screens/updates.png"><img src="docs/img/screens/updates.png" alt="The Updates page: DCS, the dashboard, the Docker Engine and the VMs on the hub's version"></a></td>
  </tr>
  <tr>
    <td align="center"><sub>Containers</sub></td>
    <td align="center"><sub>Health</sub></td>
    <td align="center"><sub>Updates</sub></td>
  </tr>
</table>

## ✨ Why DCS

| | |
|---|---|
| 📄 **It is just Compose** | A stack is a folder: `Stacks/<name>/docker-compose.yml` and its `.env`. Read it, edit it, run it by hand with `./compose.sh`. Your containers keep running when DCS stops. |
| 🖥️ **The VM is the stack** | On Proxmox, the hub builds one VM per stack and runs exactly that stack in it. Proxmox isolates, snapshots and backs up each VM; the hub shows them all as one. |
| 🔋 **Batteries included** | Reverse proxy with HTTPS, DNS records, single sign-on, intrusion detection, updates, backups, health and alerts. The setup wizard wires them up for you. |
| 🎛️ **One place to run it** | A web dashboard (also as Android, Linux and Windows apps), a REST API with 330+ endpoints and a Discord bot, all with the same accounts and roles. |
| 🪶 **Nothing to compile** | The API is a Bash program behind `socat`; `jq` and Docker Compose do the work. It runs wherever Docker runs. |

## 🚀 Get started

<p align="center">
  <img src="docs/img/install-paths.svg" alt="Four ways to install: the hub VM image, an LXC container, any Docker host, or a VM from an installer ISO" width="100%">
</p>

Pick the path that matches what you have:

| You have | Do this | Guide |
|---|---|---|
| A Proxmox host, and you want the full fleet | Import the DCS hub image as a VM *(new in 4.0)* | [A · Hub VM image](docs/GETTING-STARTED.md#a-the-hub-vm-image-on-proxmox) |
| A Proxmox host, and you want the lightest hub | Create a Debian 13 LXC container | [B · Hub in an LXC](docs/INSTALL-LXC.md) |
| Any Linux machine with Docker | `git clone` and `./setup.sh` | [C · Any Docker host](docs/GETTING-STARTED.md#c-any-docker-host) |
| A Proxmox host and an installer ISO | Make a VM, install Debian or Ubuntu, then do C | [D · VM from an ISO](docs/GETTING-STARTED.md#d-a-vm-from-an-installer-iso) |

The quick way, on any Linux machine with Docker:

```bash
git clone https://github.com/scotthowson/dcs-orchestrator.git ~/.Docker-Compose-Skeleton-AIO
cd ~/.Docker-Compose-Skeleton-AIO
./setup.sh
```

`setup.sh` checks Docker and the tools it needs, offers to fix what is missing, starts the API and
the dashboard and prints the address. Open `http://<your-server>:3000` and follow the wizard:
**Connect → Admin → Server → Stacks → Review**. The [first ten minutes](docs/GETTING-STARTED.md#the-first-ten-minutes)
walk you through it.

## 🧭 How it fits together

<p align="center">
  <img src="docs/img/architecture.svg" alt="Browser, apps and Discord talk to the hub; the hub runs the dashboard, the API, Traefik, Authelia and CrowdSec, talks to the Proxmox API and drives one member VM per stack" width="100%">
</p>

- **The dashboard** (`DCS-UI`, a container on port 3000) serves the web app and forwards `/api/` to the API.
- **The API** (port 9876) is one Bash process per request. It runs `docker compose` in `Stacks/<name>/`,
  writes Traefik routes and Cloudflare records, keeps metrics, schedules and backups, and checks every
  caller's role.
- **The proxy** is a set of templates the wizard deploys for you: Traefik, Authelia and CrowdSec.
- **On a hub**, the API also talks to the Proxmox API and to each **member** (the DCS inside a VM the
  hub built). Pages, the API and the bot act on the whole fleet; the hub's Traefik serves every VM's routes.

<p align="center">
  <img src="docs/img/fleet-flow.svg" alt="The fleet: the wizard plans the VMs, the hub builds each from an image, the VM joins the hub and its stack starts" width="100%">
</p>

## 🧰 Features

<details open>
<summary><b>Stacks and templates</b></summary>

- **Ten ordered stacks.** `core-infrastructure` starts first and stops last; the order is yours to change. [Configuration](docs/CONFIGURATION.md#stacks-and-startup)
- **150+ templates.** Jellyfin, Nextcloud, Immich, Home Assistant, Vaultwarden, Grafana and many more, each deployed and watched until healthy before it shipped. [Catalogue](docs/TEMPLATES.md)
- **Deploys that do the plumbing.** A deploy checks ports and the compose file, merges it into the stack, writes the Traefik route and the DNS record and starts it. Undeploy reverses it. [How a template becomes a stack](docs/TEMPLATES.md#how-a-template-becomes-a-stack)
- **Your own templates.** Write one on the Templates page or import one from a URL. [template.json reference](docs/TEMPLATES.md#templatejson-reference)
- **Compose editor with history.** Every save is validated, backed up and can be rolled back. [Operations](docs/OPERATIONS.md#stacks-and-containers)
- **Nuke & reinstall.** Reset a wedged app to a first install; its data goes to a trash folder first. [Operations](docs/OPERATIONS.md#nuke--reinstall)

</details>

<details open>
<summary><b>Proxy, DNS and access</b></summary>

- **Traefik with wildcard HTTPS.** Every app gets `app.your-domain` with a certificate through the Cloudflare DNS challenge. [Configuration](docs/CONFIGURATION.md#proxy-dns-and-domain)
- **Cloudflare DNS.** Records are made for each route and managed on the DNS & Routes page; dynamic DNS follows your public address. [Configuration](docs/CONFIGURATION.md#proxy-dns-and-domain)
- **Authelia single sign-on.** Apps sit behind a login portal with 2FA; apps with their own clients stay open, and you can choose per route. [Templates](docs/TEMPLATES.md#authelia-per-route)
- **CrowdSec.** Attackers are refused at the proxy, with an alert for every ban. [Discord guide](docs/DISCORD.md#2-crowdsec-alerts)
- **Start on demand (Sablier).** Idle apps sleep and wake on the first visit. [Templates](docs/TEMPLATES.md#start-on-demand)
- **A route feed** for a Traefik on another machine. [Proxmox guide](docs/PROXMOX.md#4-a-traefik-in-another-vm-or-machine-the-route-feed)

</details>

<details open>
<summary><b>Updates, backups and recovery</b></summary>

- **One-click DCS updates** from a release channel, with your edits kept and a rollback tag. [Operations](docs/OPERATIONS.md#updating-dcs)
- **Unattended updates** that roll back by themselves when the health score drops. [Operations](docs/OPERATIONS.md#unattended-updates)
- **Automatic image updates** that pull and recreate only the containers on an older copy. [Operations](docs/OPERATIONS.md#image-updates)
- **Backups and snapshots** of the whole install or one stack, on a schedule. [Operations](docs/OPERATIONS.md#backups-and-snapshots)
- **A recovery bundle:** one encrypted file that rebuilds the whole install on a new machine. [Operations](docs/OPERATIONS.md#the-recovery-bundle)

</details>

<details open>
<summary><b>Health, alerts and automation</b></summary>

- **A health score** from 0 to 100 for the server, each stack and each container, with history. [Operations](docs/OPERATIONS.md#health)
- **Metrics and trends** kept for up to two years at hourly detail. [Configuration](docs/CONFIGURATION.md#metrics-and-logs)
- **Notifications** to Discord and ntfy with rules and cooldowns, plus generic webhooks. [Discord guide](docs/DISCORD.md)
- **Schedules and automations:** backups, prunes, updates and your own scripts on cron. [Operations](docs/OPERATIONS.md#schedules-and-automations)
- **UPS watch** through NUT or apcupsd, with a clean shutdown on low battery. [Configuration](docs/CONFIGURATION.md#power-ups)
- **Plugins** with lifecycle hooks and dashboard cards; 23 more in the catalogue. [Plugin guide](.plugins/README.md)

</details>

<details open>
<summary><b>Proxmox and the fleet</b></summary>

- **The Proxmox page:** nodes, VMs and LXC containers with live load, power buttons and recent tasks. [Proxmox guide](docs/PROXMOX.md#3-what-you-get)
- **The VM is the stack:** the hub builds a VM per stack from a cloud image or a baked template. [Proxmox guide](docs/PROXMOX.md#5-the-fleet-the-vm-is-the-stack)
- **Everything from the hub:** every list page opens on *Everywhere*, with a chip for the hub or one VM. [Proxmox guide](docs/PROXMOX.md#everything-from-the-hub)
- **One version everywhere:** *Update all VMs* hands every member the hub's code. [Proxmox guide](docs/PROXMOX.md#keeping-the-vms-on-the-hubs-version)
- **Bring your own VMs:** any DCS joins the hub with a join code. [Proxmox guide](docs/PROXMOX.md#vms-you-made-yourself)

</details>

<details open>
<summary><b>People, apps and the API</b></summary>

- **Accounts and roles:** admin, viewer and bot, with optional TOTP 2FA and invite-only sign-up. [Operations](docs/OPERATIONS.md#users-and-roles)
- **A Discord bot** with slash commands, buttons and confirmations. [Discord guide](docs/DISCORD.md#3-the-bot)
- **A web terminal**, a file browser, live logs, topology and uptime pages. [Operations](docs/OPERATIONS.md#stacks-and-containers)
- **Themes:** eight built-in looks and a Theme Studio; theme.park themes for your apps. [Operations](docs/OPERATIONS.md#themes)
- **A REST API** with 330+ endpoints, each with its access level. [API reference](docs/API.md)
- **Security by default:** accounts are required off loopback, and a fresh install answers only its setup. [Security](SECURITY.md)

</details>

## 💿 VM images <sup>new in 4.0</sup>

<p align="center">
  <img src="docs/img/vm-images.svg" alt="Two purpose-built VM images, the hub image and the node image, for Debian 13, Ubuntu 26.04, Fedora 44 and Arch Linux" width="100%">
</p>

DCS 4.0 brings its own VM images (Debian 13, Ubuntu 26.04, Fedora 44 and Arch Linux): small, single-purpose Docker hosts built from `vm-images/`.

- **Node image:** a ready Docker host for the VMs of a fleet. Docker CE with the Compose plugin, the QEMU guest
  agent, ssh with keys only, and a tiny first-boot service that reads the Proxmox cloud-init drive.
- **Hub image:** the node image plus DCS, which starts as a hub on the first boot. Open port 3000 and finish in the wizard.
- **One disk, both firmwares:** each image boots with SeaBIOS or UEFI, and its disk grows to the size you give the VM.

| Node image | Download | On disk | RAM idle, Docker running |
|---|---|---|---|
| Debian 13 | 236 MB | 635 MB | ~140 MB |
| Ubuntu 26.04 LTS | 373 MB | 815 MB | ~190 MB |
| Fedora 44 (SELinux enforcing) | 383 MB | 829 MB | ~210 MB |
| Arch Linux (rolling) | 419 MB | 975 MB | ~180 MB |

<sub>Measured with the images' own boot test (KVM) and on Proxmox 9.2, where each answers ssh about five seconds after `qm start`.
The hub image adds DCS: about 47 MB more to download.</sub>

Every release carries the images, their checksums and `dcs-proxmox.sh`, which puts one on your Proxmox host in a single command
(`bash dcs-proxmox.sh hub debian-13`). The details, and which distribution to pick: [VM images](docs/VM-IMAGES.md); the walk-through:
[Getting started → A](docs/GETTING-STARTED.md#a-the-hub-vm-image-on-proxmox).

## 📚 Documentation

| Guide | What is in it |
|---|---|
| [Getting started](docs/GETTING-STARTED.md) | The four ways to install, then the first ten minutes |
| [Hub in an LXC container](docs/INSTALL-LXC.md) | A tested, step-by-step Proxmox LXC install |
| [Templates](docs/TEMPLATES.md) | Every template by category, and how a template becomes a stack |
| [Configuration](docs/CONFIGURATION.md) | The `.env` settings that matter, grouped |
| [Operations](docs/OPERATIONS.md) | Updates, backups, health, notifications, users and roles |
| [Proxmox and the fleet](docs/PROXMOX.md) | API token, the Proxmox page, the hub and its VMs |
| [Discord](docs/DISCORD.md) | Webhook alerts, CrowdSec alerts, the bot, Rich Presence |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Real failure modes and their fixes |
| [API reference](docs/API.md) | Every endpoint with its access level (generated) |
| [Development](docs/DEVELOPMENT.md) | Repository layout, tests, running the API locally |
| [Security](SECURITY.md) | The security model and how to report a problem |

## 📋 Requirements

| What | Details |
|---|---|
| Operating system | Linux. Setup and the fleet cover Debian, Ubuntu, Fedora and AlmaLinux; `setup.sh` installs missing tools with apt, dnf, yum, pacman, zypper, apk or xbps. |
| Docker | Docker Engine with the Compose v2 plugin |
| Tools | Bash 4+, jq, curl, git, openssl, python3, socat (or ncat) |
| Resources | A hub runs in 2 cores, 4 GB RAM and 32 GB of disk with room to spare. Measured in the LXC test: about 200 MB of RAM and 1.6 GB of disk with the core stack up. |
| Proxmox (optional) | Proxmox VE with an API token; see [Proxmox guide → token](docs/PROXMOX.md#1-make-an-api-token-on-proxmox) |
| Ports | 3000 (dashboard) and 9876 (API) on your network. Neither needs to face the internet: put the dashboard behind Traefik. |

## 🔄 Updating

The **Updates** page shows new releases with their notes and applies them in one click. Your stacks,
templates, accounts and edited files stay as they are, and a backup tag lets you roll back. You can
also let DCS update itself on a schedule, and keep your images fresh the same way.
[Operations → Updating DCS](docs/OPERATIONS.md#updating-dcs) has the details.

By hand, in the install directory:

```bash
git pull --ff-only
sudo systemctl restart dcs-api
```

## ❓ FAQ

<details>
<summary><b>Is DCS a Kubernetes replacement?</b></summary>

No. There is no scheduler and nothing moves between machines. Each host, or each VM in a fleet,
runs plain Docker Compose. The hub is a control plane over independent Compose hosts: a VM that
loses its hub keeps running its stack.
</details>

<details>
<summary><b>Do I need Proxmox?</b></summary>

No. DCS runs on any Linux machine with Docker. Proxmox adds the Proxmox page and the fleet, where the
hub builds and drives one VM per stack.
</details>

<details>
<summary><b>What happens to my containers if DCS stops?</b></summary>

They keep running. Docker runs them with their restart policies, and Traefik keeps serving your
routes. Without the API you lose the dashboard, alerts and schedules until it is back.
</details>

<details>
<summary><b>Can I bring my own compose files?</b></summary>

Yes. Put a `docker-compose.yml` into a folder under `Stacks/`, or save it as a template on the
Templates page and deploy it like any other. Work with a stack by hand through `./compose.sh`,
which applies the `.env` files and the secret store the way DCS does.
</details>

<details>
<summary><b>Is it safe to reach from the internet?</b></summary>

Accounts are required on any network address, and a fresh install answers only its setup until the
first admin exists. Reach the dashboard through Traefik with HTTPS (and Authelia if you like): the
dashboard forwards `/api/`, so port 9876 never needs to be opened. See [SECURITY.md](SECURITY.md).
</details>

<details>
<summary><b>Should the hub be an LXC container or a VM?</b></summary>

Both work. A VM is the sturdier choice, and it is what Proxmox recommends for Docker. An unprivileged
LXC with nesting uses less memory and was tested for this guide on Proxmox 9.2.
[INSTALL-LXC](docs/INSTALL-LXC.md#lxc-or-vm) explains the difference.
</details>

<details>
<summary><b>Where does my data live?</b></summary>

Each stack keeps its app data in `Stacks/<stack>/App-Data/`. Settings are in `.env`, secrets are
encrypted in `.secrets/`, accounts are in `.api-auth/`. The recovery bundle packs all of it into one
encrypted file. See [Operations → Backups](docs/OPERATIONS.md#backups-and-snapshots).
</details>

<details>
<summary><b>Is there a phone app?</b></summary>

The dashboard works in a phone browser. Every release of the
[dashboard repository](https://github.com/scotthowson/dcs-orchestrator-ui/releases) also ships an
Android APK and Linux and Windows installers.
</details>

## 🤝 Contributing

Issues and pull requests are welcome. Before you open one, run the two test suites:

```bash
tests/lint.sh    # bash -n, shellcheck, compose validation, API reference freshness
tests/smoke.sh   # the API's request handler, driven in a temporary install
```

[Development](docs/DEVELOPMENT.md) explains the layout, the tests and how to run the API locally. The
dashboard lives in its own repository: [dcs-orchestrator-ui](https://github.com/scotthowson/dcs-orchestrator-ui).
Please report security problems privately, as [SECURITY.md](SECURITY.md) describes.

## 📄 License

[MIT](LICENSE) © Scott Howson
