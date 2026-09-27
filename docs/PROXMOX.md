# DCS on Proxmox

DCS runs anywhere Docker runs. On a Proxmox host it can also **see and power the VMs and
containers around it**, and it fits a layout where every Docker VM runs its own DCS and one hub
shows them all. This guide covers every piece, from the API token to the Traefik on another VM.

![DCS on Proxmox — hub, members and the proxy](proxmox-architecture.png)

Nothing in this picture is required: a single-host install is the same DCS with one box.

---

## The three ways DCS meets Proxmox

| | What it means | Where it lives |
|---|---|---|
| **DCS inside a VM or LXC** | The normal install. `./setup.sh` notices it runs on a QEMU/KVM guest or in an LXC container and offers to link Proxmox right away. | Any Docker VM or container on the host |
| **Linked to the Proxmox API** | The Proxmox page lists nodes, VMs and LXC containers with live CPU, memory and uptime, starts, shuts down, stops, reboots and resets them, and alerts when a guest stops on its own. The Discord bot gets `/vms` and `/vm`. | Any DCS, single-host or hub |
| **Hub and members** | One DCS in its own small LXC or VM registers the DCS of every Docker VM: one dashboard for all stacks, a deploy-to-VM picker, one merged route feed for the proxy, Proxmox power. Members keep working on their own. | The hub in its own LXC/VM (see *Recommended layout*) |

The first two ship today. Members joining a hub is the next phase; the pieces it builds on
(the Proxmox link and the Traefik feed) are what this guide sets up.

---

## 1. Make an API token on Proxmox

DCS talks to Proxmox with an **API token**, never with a password. The token needs three
privileges on the root path `/`: `VM.Audit` (see guests), `VM.PowerMgmt` (start, stop,
reboot) and `Sys.Audit` (node status and version).

### From the web UI

1. **Datacenter → Permissions → Users → Add**: user `dcs`, realm *Proxmox VE authentication
   server* (`pve`). Any password; it is never used.
2. **Datacenter → Permissions → Roles → Create**: name `DCS`, privileges `VM.Audit`,
   `VM.PowerMgmt`, `Sys.Audit`.
3. **Datacenter → Permissions → Add → User Permission**: path `/`, user `dcs@pve`, role `DCS`,
   *Propagate* ticked.
4. **Datacenter → Permissions → API Tokens → Add**: user `dcs@pve`, token ID `dcs`, **untick
   Privilege Separation** (so the token inherits the user's permissions). Copy the **secret**:
   it is shown once.

The token ID DCS asks for is `dcs@pve!dcs` (user, realm, `!`, token name).

### From the Proxmox shell

```bash
pveum role add DCS -privs "VM.Audit VM.PowerMgmt Sys.Audit"
pveum user add dcs@pve
pveum aclmod / -user dcs@pve -role DCS
pveum user token add dcs@pve dcs -privsep 0      # prints the secret once
```

To let DCS also see storage and tasks of the whole cluster add `Datastore.Audit`; nothing
else is needed. A token with *Privilege Separation* on works too if you give **the token** the
`DCS` role at `/` instead of the user.

---

## 2. Link DCS to Proxmox

Three places do the same thing; use whichever you are at.

**`./setup.sh`** — when it runs inside a Proxmox guest it prints what it found:

```
  [INFO]  Machine: QEMU/KVM virtual machine — most likely a Proxmox VM
  [INFO]  Proxmox API found at https://192.168.1.2:8006
  Link DCS to this Proxmox now? [y/N]
```

Answer `y`, confirm the URL, paste the token ID and secret. Setup tests the token and writes
`PROXMOX_URL`, `PROXMOX_TOKEN_ID`, `PROXMOX_TOKEN_SECRET` (and `PROXMOX_VERIFY_TLS=false` when
Proxmox still uses its self-signed certificate) to `.env`. Say `n` to do it later.

**The setup wizard** — the *Server* step shows a **Proxmox** section, opened automatically on a
Proxmox guest with the detected URL filled in. *Test connection* checks the token before you
continue; the review page lists the result.

**Server Config → Proxmox** — on an existing install: URL (`https://pve.example.com:8006`),
token ID, secret, *Verify certificate* (off for the self-signed one), an optional *Only this
node* filter, and *Test connection*. The URL and token ID go to the root `.env`; the **secret is
kept in the secret store** under `PROXMOX_TOKEN_SECRET` (Secrets page) — never in plain text —
and the store always wins over a `PROXMOX_TOKEN_SECRET` line in `.env`.

The certificate: Proxmox ships self-signed. Either switch *Verify certificate* off, or give
Proxmox a real certificate (Datacenter → ACME) and keep verification on.

---

## 3. What you get

### The Proxmox page

- **Nodes** — every node with status, CPU, memory and root-disk bars, uptime and its guest
  count.
- **VMs & containers** — each guest with its state, VMID, type (VM or LXC), node, CPU, memory,
  uptime and tags. Filter by state or type, search by name, ID, node or tag.
- **Power** (admins) — *Start* for a stopped guest; *Shut down* (clean ACPI or container stop),
  *Reboot*, *Stop* (hard) and, for VMs, *Reset* and *Suspend* for a running one; *Resume* for a
  paused one. Every action asks first and explains what it does.
- **Recent tasks** — starts, stops, backups and migrations with who ran them and how they ended.
- **A dashboard card** with the node load and the guests, one click from the page.

### Events, alerts and audit

Every action is audited as `proxmox_vm_<action>` (`Started VM 101 (media-services) on pve by
scott`) and reaches your Integrations webhooks and Discord like any other event. A watcher in
the metrics loop checks the guests once a minute:

| Event | When |
|-------|------|
| `proxmox_vm_stopped` | a guest went from running to stopped, paused or unknown and DCS did not ask for it in the last five minutes |
| `proxmox_vm_started` | a guest came back to running without DCS asking |
| `proxmox_vm_start`, `_shutdown`, `_stop`, `_reboot`, `_reset`, `_suspend`, `_resume` | DCS did it (dashboard, API or bot) |

Add them to a webhook on the Notifications page (group **Proxmox**) or make a notification rule
with the *VM stopped on its own* trigger for ntfy or Discord.

### The Discord bot

| Command | What it does |
|---------|--------------|
| `/vms` | Every node and guest: state, CPU, memory, uptime, grouped by node |
| `/vm <name or VMID> <action>` | `info`, or `start`, `shutdown`, `stop`, `reboot`, `reset`, `suspend`, `resume` — admins only, with a confirmation for anything but start and resume |

The bot's DCS account may power guests when it has the **bot** or **admin** role.

### The API

| Method | Path | Access |
|--------|------|--------|
| GET | `/proxmox/status` | user — configured, reachable, version, node and guest counts, hints |
| GET | `/proxmox/nodes` | user |
| GET | `/proxmox/vms` | user — every guest (templates dropped) |
| GET | `/proxmox/vms/{node}/{qemu\|lxc}/{vmid}` | user — live status plus configuration |
| GET | `/proxmox/tasks` | user — recent tasks |
| POST | `/proxmox/vms/{node}/{qemu\|lxc}/{vmid}/{action}` | admin, bot — `start shutdown stop reboot reset suspend resume` |
| POST | `/proxmox/test` | admin — try `{url, token_id, token_secret, verify_tls}` without saving |

Read endpoints are cached for 10–15 s like the rest of the dashboard's polls; a power action
clears the cache.

---

## 4. A Traefik in another VM or machine (the route feed)

In the hub-and-VMs layout on one Proxmox box, the Traefik in the networking VM is "another
machine" from the media VM's point of view: it must reach containers that live in other VMs.
The same is true of a friend's proxy box. In both cases DCS does not need its own Traefik. Every route DCS makes (deploys, the DNS & Routes
page) is published as a **feed** that Traefik's HTTP provider pulls; nothing is installed on the
proxy machine, and a new deployment shows up there within seconds.

1. **Server Config → Traefik & DNS → Traefik on another machine**: switch *Publish routes as a
   feed* on and save. DCS mints a token.
2. Set the **target host** if the proxy should reach this machine at another address than its
   LAN IP (a Tailscale IP, for instance), the **entrypoint** name that Traefik uses
   (`websecure` by default), any **middlewares** that exist over there, and whether the routes
   carry **TLS** with a named **certificate resolver**.
3. Copy the **snippet** the panel shows into that Traefik's static configuration and restart it:

   ```yaml
   providers:
     http:
       endpoint: "http://192.168.1.20:9876/traefik/dynamic?token=…"
       pollInterval: "10s"
   ```

   Through the dashboard instead of the API port: `https://<dashboard>/api/traefik/dynamic?token=…`.
   Traefik v3 can send the token as a header instead of a query string:
   `headers: { Authorization: "Bearer …" }`.
4. The panel shows **Last pulled … by …** once the proxy has fetched the feed, how many routes
   it serves and which it could not offer.

What the feed does with a route: the rule stays (`Host(`plex.example.com`)`), the service URL
`http://Plex:32400` becomes `http://<target host>:<published host port>`, middlewares are
replaced by the list you configured (the local ones do not exist over there), and TLS is added.
A container that publishes no host port, or only on `127.0.0.1`, cannot be reached by another
machine and is listed as skipped.

A host with no Traefik of its own keeps its route files in `.data/routes`, so deploys still
create routes (and Cloudflare DNS records) for the feed. A local Traefik and the feed can be on
at the same time. `POST /traefik/feed/token` (the *Rotate* button) mints a new token; the old
one stops working at once.

---

## 5. Recommended layout on Proxmox

- **The hub** in its own small LXC or VM (2 cores, 2 GB, Docker installed): it holds the Proxmox
  link, the fleet view, the Discord bot and the route feed. An LXC needs *nesting* on for Docker
  (`features: nesting=1`, unprivileged is fine).
- **One VM per group** (`media-services`, `networking-security`, `development-tools`…), each a
  plain DCS install whose stack carries that group. VMs isolate CPU, memory and disks, and
  Proxmox backs each one up with vzdump.
- **The proxy** (Traefik, Authelia, CrowdSec) in the networking VM, pulling the hub's feed.
- **The QEMU guest agent** in every VM (`apt install qemu-guest-agent`), and *Options → QEMU
  Guest Agent* on in Proxmox: consistent snapshots, clean shutdowns, and the hub can read each
  VM's IP.
- **DCS's own backups** stay per VM (Backup page); the hub's `.env` and `.data` are tiny and are
  covered by the VM backup.

Next phases, in order: members join a hub from their own setup (one URL and a join token),
the hub forwards deploys to the VM you pick and merges every member's routes into one feed;
then the hub can clone a cloud-init template into a new VM, install DCS inside and register it,
so the wizard's layout step ("name your VMs") builds the whole tree.

---

## 6. Troubleshooting

| Symptom | Cause and fix |
|---------|---------------|
| *Proxmox rejected the API token* (401) | The token ID must be `user@realm!name`; the secret is the one shown when the token was made. Make a new token if it was lost. |
| *The API token lacks permission* (403) | Give `VM.Audit`, `VM.PowerMgmt`, `Sys.Audit` on `/` to the user (privilege separation off) or to the token itself. |
| *did not answer* | Wrong URL or port (the web UI's, `:8006`), a firewall in front of it, or certificate verification on with the self-signed certificate — switch it off, or install a real certificate on Proxmox. |
| Guests missing | *Only this node* is set, or they are templates (never listed). |
| `reset` refused for a container | Containers have no hardware reset; use *Reboot*. |
| A stop shows as *VM stopped on its own* | The watcher only ignores changes DCS asked for in the last five minutes; a shutdown from the Proxmox UI or from inside the guest is reported, which is the point. |
| Feed never pulled | The proxy machine must reach `http://<target host>:9876` (or the dashboard URL): test with `curl` from there; check the token in the snippet; Traefik logs a provider error when it cannot fetch. |
| A route is missing from the feed | Its container publishes no host port, or only on `127.0.0.1`; the panel lists it under *skipped*. Add a `ports:` mapping. |
| Detection says nothing about Proxmox | Detection reads `systemd-detect-virt` and the DMI vendor; a VM without the guest agent still shows as *QEMU/KVM*, which is treated as a probable Proxmox VM. The probe looks for port 8006 on the default gateway and on `pve`, `proxmox`, `pve.local`, `proxmox.local`; if your host has another name, just type the URL. |

Related: [README → Running inside a VM](../README.md#running-inside-a-vm-proxmox-kvm-qemu),
[docs/DISCORD.md](DISCORD.md) for the bot and webhooks, [docs/API.md](API.md) for every endpoint.
