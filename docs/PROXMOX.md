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
| **Hub and members** | One DCS in its own small LXC or VM (the **hub**) holds the Proxmox link and an account on the DCS of every Docker VM (the **members**): the Proxmox page shows each VM with the stacks its DCS runs, starts and stops them, deploys templates to the VM you pick, merges every member's routes into one feed for the proxy, and alerts when a member stops answering. Members keep working on their own. | The hub in its own LXC/VM (see *Recommended layout*) |

All three ship. Section 5 sets up the hub and its members; nothing about it changes how a
single-host DCS works.

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
| `/fleet` | The hub's members: which VM each DCS runs in, its stacks, whether it answers (on a member: the hub it belongs to) |

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

## 5. The fleet: a hub and its members

Every Docker VM keeps a complete DCS of its own: its stacks, its Docker, its API, its dashboard.
The **hub** is the DCS that is linked to Proxmox. It holds an account on every **member** and,
from one dashboard:

- shows each VM on the Proxmox page **with the stacks its DCS runs** (running or stopped, how
  many containers), next to the VM's own CPU, memory and power buttons;
- **starts, stops and restarts** those stacks, and **deploys any template to the VM you pick**
  (*Deploy here* on the VM card, or the *Deploy to* row in the deploy dialog);
- **merges every member's routes** into its Traefik feed, so the proxy in the networking VM
  pulls one feed for the whole host (section 4);
- **watches the members** once a minute and raises `fleet_member_down` / `fleet_member_up`;
- answers `/fleet` in Discord and shows the fleet on the dashboard's Proxmox card.

It is a control plane over independent compose hosts, not a cluster: nothing is scheduled or
moved between VMs, and a member that loses the hub keeps running exactly as before.

### Linking the VMs

There are three ways, and they mix freely:

| How | When | What happens |
|-----|------|--------------|
| **The wizard's scan** (hub) | Setting up the hub, or *Link VMs* on its Proxmox page | After *Test connection* the wizard runs the link card: connect → token → inventory → **scan**. The hub asks Proxmox for each running guest's addresses (QEMU guest agent, or the container's interfaces) and probes DCS's API port. Every install it finds gets a **Link** button: enter an account of that DCS and the hub logs in, reads its identity and keeps it. VMs without DCS get the join code. |
| **A join code** (member) | Installing DCS in a new VM, or a VM set up before the hub | The hub's Proxmox page (*Join code*) and the wizard show a code, valid 24 h. On the VM: `DCS_HUB_URL=http://<hub>:9876 DCS_JOIN_TOKEN=<code> ./setup.sh` for a fresh install, `./setup.sh --join http://<hub>:9876 <code>` for an installed one, or *Join a DCS hub* in that VM's wizard or Proxmox page. The member creates the account `dcs-hub` for the hub and hands it over once; the hub logs in, matches the guest and keeps it. |
| **By address** (hub) | Any time | *Add member* on the Proxmox page: address, an account that exists on that DCS, optionally the guest. |

`./setup.sh` asks which one this machine is on its first run — **standalone**, **hub** (link
Proxmox here) or **member** (hub address and join code) — and unattended installs answer with
`DCS_FLEET_ROLE=hub|member|standalone`, `DCS_HUB_URL` + `DCS_JOIN_TOKEN` (+ `DCS_MEMBER_NAME`)
and `DCS_PROXMOX_URL` + `DCS_PROXMOX_TOKEN_ID` + `DCS_PROXMOX_TOKEN_SECRET`. A join typed into
`setup.sh` before the VM has an admin account is saved and runs in that VM's wizard, on the same
progress card, right after the admin account exists.

### How a member is matched to its guest

The hub reads the member's identity (hostname, SMBIOS uuid, addresses) and tries, in order: the
**uuid** of a QEMU VM (`smbios1` in its configuration — exact, needs nothing in the guest), a
**shared address** (the guest agent's or the container's addresses against the member's), then
the **name** (guest name equals the member's hostname). A member the hub could not place is
listed under *Members without a guest* with *Pick the guest*; the member menu's *Test* re-runs
the match. Install the QEMU guest agent in every VM so the scan and the address match work.

### What the hub may do, and how it is kept safe

- The hub's account on a member is an **admin** (`dcs-hub`, a random 40-character password kept
  in the hub's secret store as `FLEET_MEMBER_<ID>_PASSWORD`). It is a *service account*: it
  keeps its session when someone else signs in on that member.
- Every call the dashboard makes on a member goes **through the hub**
  (`/fleet/members/{id}/api/…`) with the caller's own role checked against the inner path as if
  it were local — a viewer reads, a bot does what bots may, an admin does everything. Streams,
  auth and setup are never forwarded. Non-GET calls are audited on the hub as `fleet_proxy`.
- **Join codes** live 24 h (or the hours you choose), are used from the hub's LAN address, and
  are rate-limited like logins; revoke them from the Proxmox page.
- **Leaving**: *Leave* on the member removes the `dcs-hub` account there; *Remove* on the hub
  forgets the member (and removes its account when it answers). Neither touches a stack.
- The hub reaches members at `http://<address>:9876` (`FLEET_SELF_URL` on a member fixes a wrong
  detected address; `FLEET_SCAN_PORTS` on the hub changes the ports the scan probes).

### The API

| Method | Path | Access |
|--------|------|--------|
| GET | `/fleet/status` | user — hub, member or standalone; the hub this server joined; a pending join |
| GET | `/fleet/members`, `/fleet/members/{id}` | user |
| POST / PUT / DELETE | `/fleet/members`, `/fleet/members/{id}` | admin — add by address, edit, remove |
| POST | `/fleet/members/{id}/test` | admin — sign in afresh, read the identity, re-match the guest |
| ANY | `/fleet/members/{id}/api/{path}` | the caller's role on the inner path — the proxy |
| GET | `/fleet/overview` | user — every member with its stacks and container counts (10 s cache) |
| GET / POST | `/fleet/discover` | admin — the scan (GET cached 30 s; POST scans now and accepts Proxmox values before they are saved) |
| GET / POST / DELETE | `/fleet/join-tokens`, `/fleet/join-tokens/{token}` | admin — join codes |
| POST | `/fleet/join` | public — a member registers with a join code |
| GET | `/fleet/identity`, `/fleet/feed` | user — what a hub reads from a member |
| POST / DELETE | `/fleet/join-hub`, `/fleet/hub` | admin — join a hub, leave it |

Command line, on any DCS: `.scripts/api-server.sh --join-hub URL CODE [NAME]`, `--join-token
[HOURS]`, `--fleet-status`.

---

## 6. Recommended layout on Proxmox

- **The hub** in its own small LXC or VM (2 cores, 2 GB, Docker installed): it holds the Proxmox
  link, the fleet, the Discord bot and the route feed. An LXC needs *nesting* on for Docker
  (`features: nesting=1`, unprivileged is fine).
- **One VM per group** (`media-services`, `networking-security`, `development-tools`…), each a
  plain DCS install whose stack carries that group, joined to the hub with the join code. VMs
  isolate CPU, memory and disks, and Proxmox backs each one up with vzdump.
- **The proxy** (Traefik, Authelia, CrowdSec) in the networking VM, pulling the hub's feed —
  which now carries every member's routes.
- **The QEMU guest agent** in every VM (`apt install qemu-guest-agent`), and *Options → QEMU
  Guest Agent* on in Proxmox: consistent snapshots, clean shutdowns, and the hub can read each
  VM's IP for the scan and the match.
- **DCS's own backups** stay per VM (Backup page); the hub's `.env`, `.data` and secret store are
  tiny and are covered by the VM backup.

The phase after this one lets the hub clone a cloud-init template into a new VM, install DCS
inside and join it, so the wizard's layout step ("name your VMs") builds the whole tree.

---

## 7. Troubleshooting

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
| *The hub could not log in to http://…* on a join | The hub must reach the member's API at that address: a firewall, or a wrong detected address — set `FLEET_SELF_URL=http://<member ip>:9876` in the member's `.env` (or pass `url` on the join) and join again. |
| The join code is refused | Codes expire after 24 h (or the hours chosen) and are case-insensitive; mint a new one on the hub's Proxmox page. Five wrong codes from one address lock it out for a while, like logins. |
| A member shows *no guest matched* | No guest agent (uuid still works for a VM if the hub reads `smbios1`, but an LXC or a VM whose name differs from the hostname needs the address or the name to match): pick the guest from the member menu. |
| The scan finds nothing | The scan needs each guest's addresses from the QEMU guest agent (or container interfaces) and DCS answering on port 9876 there (`FLEET_SCAN_PORTS` for others). A VM without the agent shows *address unknown*. |
| A member's stacks are missing from the Proxmox page | *Members answering* in the page header says whether the hub reached it; the member menu's *Test* explains a refusal (a changed password on the member: edit the member and enter it again). |
| Detection says nothing about Proxmox | Detection reads `systemd-detect-virt` and the DMI vendor; a VM without the guest agent still shows as *QEMU/KVM*, which is treated as a probable Proxmox VM. The probe looks for port 8006 on the default gateway and on `pve`, `proxmox`, `pve.local`, `proxmox.local`; if your host has another name, just type the URL. |

Related: [README → Running inside a VM](../README.md#running-inside-a-vm-proxmox-kvm-qemu),
[docs/DISCORD.md](DISCORD.md) for the bot and webhooks, [docs/API.md](API.md) for every endpoint.
