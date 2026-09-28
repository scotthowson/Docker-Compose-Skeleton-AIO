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
| **The fleet: the VM is the stack** | One DCS in its own small LXC or VM (the **hub**) keeps the dashboard, the Proxmox link and `core-infrastructure`. Every other stack is a VM the hub **builds** (cloud image, Docker, DCS, joined) and that runs exactly that stack: `media-services` is a VM named media-services. The hub's own API answers for all of them, so the Stacks, Containers and Templates pages, the bot and the API work across the whole host as if it were one machine. | The hub in its own LXC/VM (see *Recommended layout*) |

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

## 5. The fleet: the VM is the stack

Every stack you would have run in a directory on one Docker host runs in its own Proxmox VM
instead, and the hub — the DCS linked to Proxmox — makes that invisible:

- `media-services`, `networking-security`, `development-tools`… are **VMs named like the
  stack**, each with Docker and an API-only DCS that carries that one stack (`DOCKER_STACKS=
  media-services`). The hub keeps `core-infrastructure` (the dashboard, the bot, ntfy, uptime).
- The hub's **API is the fleet API**: `GET /stacks` lists the members' stacks next to its own
  (each with `placement: "vm"`, the member and the VMID), and `/stacks/{name}/…`,
  `/containers/{name}/…` and a template deploy whose target stack lives in a VM are **forwarded
  to that VM's DCS** with your own role checked on the hub. The Stacks page shows a *VM* chip,
  the Containers page lists every VM's containers with a *VM* chip, the deploy dialog's stack
  list says which stacks are VMs, and the bot's `/stacks` and `/fleet` follow. Nothing is
  scheduled or moved between VMs: this is a control plane over independent compose hosts, and
  a VM that loses the hub keeps running its stack.
- **The VM is born as the stack**: when the hub builds the VM for `media-services`, its own
  `Stacks/media-services` folder (compose, `.env`, config files — never `App-Data`, data or
  backups) moves into the VM and starts there; a row you renamed in the wizard keeps the folder it
  came from. The hub's copy is a leftover from then on. A stack with no folder starts empty and
  takes templates.
- **The Stacks page is the VMs page** on a hub: the sidebar reads *VMs*, the VMs come first (each
  one a stack) and the hub's own stacks follow; open a VM for the containers running in it, with
  start/stop/restart per container, the compose editor, logs, and the VM's own power. *New VM*
  builds one more, and the builds show on the same page. The Proxmox page's VM cards list the
  same containers with *Open* and *Edit compose*.
- **Proxmox and DCS agree**: starting or stopping a VM in the Proxmox UI is the stack going up
  or down (the VM starts at boot and DCS's boot services start the stack); the Proxmox page
  shows each VM with its stack, containers and power buttons.

### Building the VMs

The wizard's **Stacks** step, once Proxmox is linked and the token may create VMs, shows a
*Hub / VM* switch per stack (VM for every stack but `core-infrastructure`), cores, RAM and disk
per VM, and a **VM settings** panel prefilled from Proxmox and the hub's network: node, disk
storage, image storage, bridge, the first address to hand out, the prefix, gateway and DNS.
*Complete setup* creates the hub's own stacks, then hands the VM plan to the hub, which builds
the VMs one after another in the background. The success screen and the Proxmox page follow
each build on a **progress card**; later, **New VM stack** on the Proxmox page builds one more.

Each build job walks these steps (idempotent, so *Retry* on a failed job resumes where it
stopped):

| Step | What the hub does |
|------|-------------------|
| **Image** | Switches the *import* content type on the image storage if needed, then asks Proxmox to download the Debian cloud image (`FLEET_IMAGE_URL`) into it once. A token without `Sys.AccessNetwork` cannot make Proxmox download, so the hub downloads the image itself and uploads it. |
| **Create** | `POST /nodes/{node}/qemu` with the next free VMID: the image imported as the boot disk (`import-from`), a cloud-init drive, virtio network on the bridge, the guest agent enabled, `onboot`, tags `dcs;<stack>`, then the disk grown to the size you chose. |
| **Cloud-init** | User `dcs` (`FLEET_VM_USER`) with the hub's own ssh key (made once in `.data/fleet-ssh`), the static address, gateway and DNS. |
| **Boot** | Starts the VM and waits for the Proxmox task. |
| **SSH** | Waits for the VM to answer ssh (first boot runs cloud-init). |
| **Install** | Copies `.scripts/fleet-bootstrap.sh` to the VM and runs it: a network check, curl/git/jq/socat/openssl/python3 and the QEMU guest agent, Docker (get.docker.com, with fallbacks) and Compose, then the hub's **own code** as a bundle (`GET /fleet/bundle?token=<join code>`, never data, accounts, secrets or stacks), then an **unattended member setup** that creates the admin (your username on the hub, a generated password kept in the hub's secret store as `FLEET_MEMBER_<STACK>_ADMIN_PASSWORD`), writes the configuration, creates the stack, starts the API without a dashboard and joins the hub, and finally the boot services (`dcs-api`, `dcs-stacks`). Every line lands in the job log. |
| **Join** | Waits for the VM's join, then maps the member to the VMID and marks it *provisioned*. |
| **Stack** | Copies the hub's `Stacks/<source>` (default: the stack's own name) into the VM over ssh — compose, `.env` and config files, never `App-Data`, data, backups or logs — and starts it through the member's API. Nothing to copy: the VM starts empty. |
| **Ready** | Asks the member for its stacks through the hub. |

What Proxmox needs from the token, beyond `VM.Audit`, `VM.PowerMgmt` and `Sys.Audit`: the
roles **PVEVMAdmin**, **PVEDatastoreAdmin** and **PVESDNUser** on `/` (Datacenter →
Permissions → Add), or the privileges `VM.Allocate`, `VM.Config.*`, `Datastore.AllocateSpace`,
`Datastore.AllocateTemplate`, `Datastore.Allocate` (to switch *import* on) and `SDN.Use`.
`Sys.AccessNetwork` on the node (a custom role) lets Proxmox download the image itself.
`GET /proxmox/capabilities` and the wizard say what is missing. The hub itself needs `ssh` and
`ssh-keygen`, a dir storage for the image (`local`), a bridge the VMs share with the hub, a
free address range, and internet from the VMs (the install log says at once when there is
none).

### The operating system

Every VM is built from a **cloud image**: a system that takes its user, key, address, Docker
and DCS from cloud-init and the bootstrap, so the build needs no hand on it. The VM settings
(the wizard's Stacks step, *New VM*) offer:

| Choice | What happens |
|--------|--------------|
| **Catalogue** — Debian 13 (the default, smallest), Debian 12, Ubuntu Server 26.04 / 24.04 / 22.04 LTS, Fedora Cloud, AlmaLinux 9 | Proxmox downloads the image once into the import storage (or the hub fetches and uploads it), every VM built from it imports that file. |
| **On Proxmox already** — a cloud image in the import storage | Used as is: put images there yourself (Datacenter → Storage → *local* → *Import*) and they show up. |
| **On Proxmox already** — an installer ISO from *ISO Images* | The hub creates the VM with the ISO attached and stops there: install the system in the VM's Proxmox console (the card says which address to give it), then run the one-line join the card shows. The build closes by itself when the VM joins. Anything Proxmox can boot works this way. |
| **A URL** | Any cloud image (`.qcow2`, `.img`, `.raw`) with cloud-init and apt or dnf inside. |

Debian and Ubuntu (apt) and Fedora and AlmaLinux (dnf) are covered by the bootstrap; on
dnf systems it opens the API port in firewalld and leaves SELinux enforcing (add `:z` to a
volume Docker must write). A `.config/fleet-images.json` on the hub (an array of
`{id, label, url, file, family}`) replaces the catalogue. The choice applies to every VM of a
build; *New VM* can pick a different one per VM.

### Faster builds: the baked DCS template

A build from a cloud image spends most of its 85 seconds installing packages and Docker. Tick
**Bake a DCS template first** in the VM settings (on by default) and the hub does that work
once: it builds one VM from the chosen image, installs the tools, Docker and the guest agent,
seals it (`cloud-init clean`, a fresh machine id and host keys) and turns it into a Proxmox
**template** tagged `dcs;template`. Every VM for that image is then a **full clone** of the
template plus its own cloud-init: the build takes about 40 seconds and only the fresh DCS code
from the hub, the setup and the join run inside. The picker lists baked templates first; a
template stays for the next builds, and one bake serves the wizard's whole layout. `GET
/fleet/templates` lists them, `POST /fleet/templates` bakes one by hand, `DELETE
/fleet/templates/{vmid}` removes one (with its VM) — bake again after a big OS update.

### Keeping the VMs on the hub's version

The hub's code is the fleet's code. On a hub, the Updates page shows **The VMs** under the DCS
Framework card: every member with the DCS version it answers with (asked live, `GET
/fleet/versions`), amber when it differs from the hub's. **Update all VMs** (`POST /fleet/update
{members: "all"}`, or a list of ids) hands each answering member the hub's own code: the member
downloads the hub's bundle with a one-hour join code minted for the round (`POST
/fleet/self-update {bundle_url}` on the member, admin only), saves the code it had as
`.snapshots/dcs-code-<version>-<time>.tar.gz`, unpacks the bundle over its install — its `.env`,
`.data`, accounts, secrets, stacks, logs and the settings files it already has in `.config` are
untouched — writes an entry to its update history and restarts its API in place (the same
`kill -USR1` re-exec the hub's own updates use, under systemd or not). The answer lists what
happened per member and the last round stays on the card. A hub update with **Then update the
VMs** ticked (the default on a hub with members: `POST /system/update/apply {fleet: true}`)
queues a round that the hub runs by itself once its API is back on the new code. When the
installer changed with the code (the systemd unit comes from it), a member runs it again and
restarts through systemd instead, so the unit follows too. Every card carries the same status
line: up to date or not, when it was checked, when it last changed.

Image updates see the whole fleet: the Updates page of a hub opens on **Everywhere** — every
image on the hub and on each VM in one list (`GET /fleet/images`), each row saying where it
runs, with *Check Registry* asking every DCS at once (`POST /fleet/images/check`) and each pull
going to the DCS the row belongs to. The **Images on** row narrows the list to the hub alone or
to one VM (the member proxy carries the calls, so nothing new is exposed). Without Proxmox
nothing changes: a DCS without members shows neither the card nor the row, and a VM's own
Updates page says *Updated by its hub* instead of looking for releases.

### Everything from the hub

The hub is the one place to look at and to run the whole server. Every page that lists things
opens on **Everywhere** on a hub — the hub and every VM in one list, each row carrying a capsule
that says where it lives (*Hub*, or *VM #103 · media-services*) — and the same row of chips
narrows it to the hub alone or to one VM: Health, Images, Updates, Networks, Volumes, Snapshots,
Automations, Scheduled Tasks, Secrets and the Activity timeline all share the one choice, and it
is remembered. *Everywhere* is a view: to change something, pick the hub or the VM it lives on
(clicking a row's capsule does that), and the change happens on that DCS through the hub. The API
is the same: `?fleet=1` on `GET /health`, `/images`, `/networks`, `/volumes`, `/events`,
`/snapshots`, `/automations`, `/schedules`, `/secrets` and `/audit` merges every member's rows
(tagged `member`, `member_name`, `vmid`) with the hub's, and `members[]` says how each DCS did.

Some things go further than a merged list:

- **Routes to the VMs.** The hub's own Traefik reaches every service inside the VMs without any
  configuration: the hub writes the members' routes (each VM's DCS writes one per deployed
  service, `service.your.domain`) into its Traefik's `custom_routes` directory as
  `fleet-members.yml`, which the file provider watches, and keeps that file current every half
  minute — with the hub's own middleware chain on every router, so a service in a VM is served,
  compressed, guarded by CrowdSec and put behind Authelia exactly like one on the hub (templates
  whose apps bring their own clients stay open; see the README). A new route also gets its
  Cloudflare record and its Homarr tile from the hub when those are set up there. When the
  Traefik lives inside a VM instead, the hub pushes everyone else's routes into that VM's
  Traefik (`POST /fleet/routes`). A Traefik somewhere else keeps using the feed (section 4).
- **One domain.** The fleet's domain is the hub's (`TRAEFIK_DOMAIN` or `PROXY_DOMAIN`): a VM the
  hub builds gets it at build time, a server that joins gets it with the join answer, and older
  members get it from the hub within a minute (`POST /fleet/hub/domain`, written as
  `PROXY_DOMAIN`); a member that has a domain of its own keeps it. When the domain arrives, the
  VM writes the routes for the services it already runs (`POST /traefik/routes/rebuild` does
  the same by hand, on any DCS that got Traefik after its stacks).
- **Every page, every VM.** Containers, Logs, Uptime, Topology, Backup & Restore, File Browser,
  Environment, System and Maintenance take the same Everywhere / Hub / VM choice as the list
  pages: a container's buttons (start, stop, restart, recreate, remove, env, exec, logs, Sablier,
  Nuke & reinstall) act on the VM it lives in, a stack's backup runs on its VM and restores go to
  the archive's own server, a VM's files and `.env` open through the hub, OS updates on a VM the
  hub built need no password, and maintenance numbers add up (the hub answers the Maintenance
  page's three questions for the whole fleet in one call each: `GET /maintenance/report`,
  `/orphans`, `/disk` with `?fleet=1`). The Live Events page follows the same choice
  (`GET /stream?fleet=1` / `?member=`). The hub only forwards a container request to the
  member whose recorded placements include the container's stack.
- **A shell in every VM.** The Terminal page has the Hub / VM chips: unlock it once with the
  hub's Linux credentials and a VM the hub built is a click away — the command runs inside the
  VM as its DCS account over the hub's ssh key (`GET /fleet/members/{id}/terminal` says whether
  the hub can, `POST /fleet/members/{id}/terminal/exec` runs it), with the same command guard,
  rate limit, 60 s limit and audit log as the hub's own terminal; the prompt says where each
  command ran. A VM you made yourself needs the hub's public key
  (`.data/fleet-ssh/id_ed25519.pub`) in its DCS account's `authorized_keys` first.
- **Themes and Homarr.** Themes (Settings → Appearance) live on the hub and every dashboard
  follows the one set for everyone; Homarr on the hub gets a tile for every routed app, the
  VMs' included, once its API key is stored (Server Config → Integrations, or
  `POST /homarr/key`), and *Sync routes* fills in what is missing.
- **The engine under the containers.** The Updates page's *Docker Engine* card shows the engine
  on the hub and in every VM — version, package source, the newest version that source offers —
  and updates them (`GET /system/docker-engine?fleet=1`, `POST /fleet/docker-engine/update`);
  a VM the hub built needs no password for it.

- **Events reach the hub.** A VM's DCS sends every event it raises (a container that stopped, a
  stack that started, an update, a failed backup…) to its hub with a relay token the hub handed
  it when it joined (`POST /fleet/relay`). The hub notes it in the Activity timeline as
  `fleet_event` and fires its own notification rules with the VM named — a Discord embed or an
  NTFY push from the hub reads *VM media-services · Container stopped* and carries the VM as a
  field. The VMs need no Discord or NTFY settings of their own; the hub's rules and channels
  cover the whole server. Members that joined before this get a token from the hub within a
  minute.
- **A snapshot of everything.** *Create snapshot* on Everywhere (`POST /snapshots/create?fleet=1`)
  takes one snapshot on the hub and one on every VM at the same moment; each DCS keeps its own
  archive (a VM's files stay in the VM), the list shows them together, and a restore goes to the
  DCS the snapshot came from.
- **Secrets travel with a stack.** When a build moves a stack into its VM, the secrets the stack
  refers to (`${SECRETS_…}` in its compose or `.env`) are stored in the VM's own secret store
  first, so the stack starts there as it did on the hub.
- **One version everywhere.** The Updates page keeps every VM on the hub's DCS version (above).

Without Proxmox and without members nothing of this shows: the pages are as they were, and a
DCS with no fleet never asks anyone else.

### The whole thing, step by step

For a fresh Proxmox host, this is the entire path — no terminal on the VMs, no files to edit:

1. Make one VM for the hub (any Debian or Ubuntu, 2 cores, 4 GB, 20 GB) and install DCS in it
   with the one-line installer from the README. The setup wizard opens in the browser.
2. In the wizard's **Proxmox** step, paste the host's address and an API token (section 1 above
   shows the two clicks that make one) and press *Test*. Green means the hub can see the host.
3. In the **Stacks** step, every stack you ticked shows a *Hub / VM* switch. Leave them on *VM*:
   each becomes its own VM, named like the stack. Sizes and the operating system are prefilled;
   change them if you like.
4. Press **Complete setup**. The hub bakes a DCS template once, then clones a VM per stack; each
   card on the screen shows the build step by step. A VM takes about 25 seconds from a template.
5. When the cards are green, the dashboard opens: the Stacks page lists every VM as a stack, the
   Containers page every container with its VM, and the Updates, Health, Images and the other
   pages show *Everywhere*.
6. Later: *New stack → In its own VM* adds one more; *Update all VMs* on the Updates page keeps
   them current; Discord or NTFY on the hub's Notifications page covers every VM.

### VMs you made yourself

Any VM with DCS in it can join the same fleet, and the hub then treats it like a built one:

| How | When | What happens |
|-----|------|--------------|
| **Scan and link** (hub) | The wizard's Proxmox section after *Test connection*, or *Link VMs* on the Proxmox page | The hub asks Proxmox for each running guest's addresses (QEMU guest agent, or the container's interfaces) and probes DCS's API port; every install it finds gets a *Link* button (an account of that DCS), the rest the join code. |
| **A join code** (member) | Installing DCS in a VM, or a VM set up before the hub | The hub's Proxmox page (*Join code*) shows a code, valid 24 h. On the VM: `DCS_HUB_URL=http://<hub>:9876 DCS_JOIN_TOKEN=<code> ./setup.sh` for a fresh install, `./setup.sh --join http://<hub>:9876 <code>` for an installed one, or *Join a DCS hub* in that VM's wizard or Proxmox page. The member creates the account `dcs-hub` for the hub and hands it over once. |
| **By address** (hub) | Any time | *Add member* on the Proxmox page: address, an account that exists on that DCS, optionally the guest. |

`./setup.sh` asks which one a machine is on its first run — **standalone**, **hub** (link
Proxmox here) or **member** (hub address and join code) — and unattended installs answer with
`DCS_FLEET_ROLE=hub|member|standalone`, `DCS_HUB_URL` + `DCS_JOIN_TOKEN` (+ `DCS_MEMBER_NAME`)
and `DCS_PROXMOX_URL` + `DCS_PROXMOX_TOKEN_ID` + `DCS_PROXMOX_TOKEN_SECRET`. A join typed into
`setup.sh` before the VM has an admin account is saved and runs in that VM's wizard, on the
same progress card. A fully unattended install (what the hub runs inside a VM) takes
`DCS_UNATTENDED=true`, `DCS_ADMIN_USER`, `DCS_ADMIN_PASSWORD`, `DCS_STACKS`, `DCS_MEMBER_NAME`,
`DCS_TZ`, `DCS_PUID`, `DCS_PGID`, `DCS_PROXY_DOMAIN`, `DCS_CF_DNS_API_TOKEN`, `DCS_API_PORT`,
`DCS_API_BIND` and `DCS_NO_UI=true` (API only).

The hub matches a member to its guest by the VM's **SMBIOS uuid** (`smbios1` in its
configuration; root-only in the VM's sysfs, so the bootstrap keeps a copy in `.data/product_uuid`
for the API — do the same on a VM you set up by hand), then a **shared address** (guest agent / container interfaces), then the
**name**; a member it could not place is listed under *Members without a guest* with *Pick the
guest*, and the member menu's *Test* re-matches.

### What the hub may do, and how it is kept safe

- The hub's account on a member is an **admin** (`dcs-hub`, a random 40-character password kept
  in the hub's secret store as `FLEET_MEMBER_<ID>_PASSWORD`), a *service account* that keeps its
  session when someone else signs in on that member.
- Every call the dashboard makes on a member goes **through the hub**
  (`/fleet/members/{id}/api/…`, or transparently for stacks, containers and deploys) with the
  caller's own role checked against the inner path — a viewer reads, a bot does what bots may,
  an admin does everything. Streams, auth and setup are never forwarded. Non-GET calls are
  audited on the hub as `fleet_proxy`.
- **Join codes** live 24 h (48 h for a build), are rate-limited like logins, and can be revoked
  from the Proxmox page. The **code bundle** a VM fetches needs a valid join code and never
  carries `.env`, accounts, secrets, data, stacks or logs. An update round mints a *bundle code*
  per member instead (tagged with the member, revoked the moment that member's call returns): it
  opens the bundle for that member and can never join.
- **Removing**: *Remove from the fleet* forgets a member (its `dcs-hub` account is removed when
  it answers); *Stop and destroy the VM on Proxmox* also stops and deletes the VM with its
  disks after you type the stack's name. *Leave* on a member removes the hub's account there.
- **Whose stack is it**: the hub treats a stack as its own when it is in the hub's `DOCKER_STACKS`
  or has containers up. A `Stacks/<name>` folder alone does not count — the repository ships one
  per stack, and a stack placed in a VM leaves its folder behind on the hub — so the VM's stack is
  the one listed, forwarded and deployed to. To move a stack that runs on the hub into a VM, stop
  it and take it out of `DOCKER_STACKS` first (the wizard's Stacks step does that for you).
- **The hub never starts a VM's stack itself**: `start.sh` (and the boot service), *Start All*
  and the batch actions skip every stack that a member runs — its folder on the hub is a
  leftover — whatever `DOCKER_STACKS` says; the log line says so. Actions on such a stack go to
  the VM instead.
- **One name, one guest**: building a VM for a stack whose name already exists as a guest on
  Proxmox is refused — link that guest from the Proxmox page (*Link VMs*) or rename it there. A
  failed build's VM can go with its job (*Dismiss* asks; `DELETE /fleet/jobs/{id}?destroy=true`).
- The hub reaches members at `http://<address>:9876` and members reach the hub at
  `FLEET_SELF_URL` (detected: the hub's LAN address and API port; set it when the hub sits
  behind another address). `FLEET_SCAN_PORTS` changes the ports the scan probes,
  `FLEET_IMAGE_URL` the cloud image, `FLEET_VM_USER` the user cloud-init makes.

### What a member can and cannot do to its hub

A member is another machine, so the hub treats everything it sends as data:

- **Routes**: a member's feed is never merged as sent. Every router and service is rebuilt from a
  whitelist — a name of `[a-z0-9-]`, one `Host(…)` rule with an optional `PathPrefix`,
  `entryPoints`, `tls` with a `certResolver` at most, `middlewares`; `priority` and every other
  field are dropped. A service may point at the member's own address only (the address the hub
  reaches it by, or what that name resolves to). A route for one of the hub's own hostnames (its
  route files, `ui.` and `api.` under the proxy domain, `DASHBOARD_PUBLIC_URL`) is refused, and a
  hostname two members offer goes to the first in the fleet list — the other is renamed
  `<sub>-<member-id>.<domain>`. `GET /traefik/feed/status` lists what was refused or renamed and
  why (`member_skipped`).
- **Stacks**: a member cannot attract another stack's requests. The stacks the hub forwards to a
  member (`/stacks/<name>/…`, template deploys) are its *placements*, given by the build that moved
  the stack in or by an admin (`PUT /fleet/members/{id}` with `stacks`), and at join only for
  names the hub has no `Stacks/` folder for. What a member says it runs is shown (`GET
  /fleet/overview` → `stacks`, next to `placements`; the VM rows of `GET /stacks` carry `placed`)
  but never becomes a placement.
- **Events**: `POST /fleet/relay` takes 30 events a minute per member (429 beyond). The context a
  member sends cannot pose as the hub (`hostname`, `timestamp`, `event`, `vm`, `vmid`, `member`
  are the hub's own), cannot steer a notification's cooldown (only `stack` and `container` take
  part), and is cut to 120 characters in the activity line. A relayed event is never relayed
  again, and a server refuses to join one of its own members as hub (or to take its own hub as a
  member), so two hubs cannot bounce events between them.
- **Answers**: the hub reads at most 8 MB from a member, gives up on a connection after 2 s, probes
  a member it knows to be down with a 3 s `/ping` before any login, and types every field of a
  merged answer before it is counted — a member answering `{"networks": "nope"}` leaves
  `/networks?fleet=1` a valid answer with the hub's own rows, and a malformed answer to an update
  counts as that member failing, never as the round ending.
- **Code**: the member fetches an update from its own record of the hub's address (the hub sends
  the bundle code alone), so a hub reached by name, over HTTPS or on another interface serves it
  too; the old code lands in `.snapshots/code/` (private, the newest three), out of the
  configuration snapshots' list.
- **Names**: a member's name is cleaned when it registers (control characters out, 64 characters at
  most) and is the one the hub uses in activity lines and notifications; ntfy header values never
  carry a line break.
- **The hub's loop**: the fleet work (the watcher, relay tokens, the domain, the routes) runs in
  the background under a lock, so a member that stalls never holds up the hub's own samples.

### The API

| Method | Path | Access |
|--------|------|--------|
| GET | `/fleet/status` | user — hub, member or standalone; the hub this server joined; a pending join |
| GET | `/fleet/members`, `/fleet/members/{id}` | user |
| POST / PUT / DELETE | `/fleet/members`, `/fleet/members/{id}` (`?destroy=true` also destroys the VM) | admin — `PUT` also takes `stacks`, the placements: the stacks this member answers for |
| POST | `/fleet/members/{id}/test` | admin — sign in afresh, read the identity, re-match the guest |
| ANY | `/fleet/members/{id}/api/{path}` | the caller's role on the inner path — the proxy |
| GET | `/fleet/overview` | user — every member with its stacks, containers and counts (10 s cache) |
| GET / POST | `/fleet/discover` | admin — the scan (GET cached 30 s; POST scans now, accepts Proxmox values before they are saved) |
| GET / POST | `/fleet/provision/defaults` | admin — prefilled values for building VMs (POST with Proxmox values before they are saved) |
| POST | `/fleet/provision` | admin — build one VM per stack `{node, storage, image_storage, bridge, cidr, gateway, dns, ip_start, vms: [{stack, source, cores, memory_mb, disk_gb, ip}]}`; `source` is the hub folder that moves into the VM (default: the stack name) |
| GET | `/fleet/jobs`, `/fleet/jobs/{id}` | admin — the builds with steps and log |
| POST / DELETE | `/fleet/jobs/{id}/retry`, `/fleet/jobs/{id}` (`?destroy=true` also destroys a failed build's VM) | admin |
| GET / POST / DELETE | `/fleet/templates`, `/fleet/templates/{vmid}` | admin — the baked DCS templates: list, bake one, remove one with its VM |
| GET | `/fleet/versions` | admin — the hub's DCS version next to every member's (asked live), who is behind, the last update round |
| POST | `/fleet/update` | admin — bring members to the hub's version `{members: ["id", …] or "all"}`: each fetches the hub's bundle and re-executes; the round runs on its own — 202 `{running: true}` when it outlasts 25 s, `GET /fleet/versions` (`last_round`) follows it |
| POST | `/fleet/self-update` | admin, on a member — install a code bundle over this install `{token}` (the hub's bundle code; the bundle is fetched from the member's own record of its hub) or `{bundle_url}` under the hub's address; data, accounts, secrets, stacks and settings stay, the old code lands in `.snapshots/code` (the newest three) |
| GET | `/fleet/images` | user — every image on the hub and on each member, tagged with where it runs; the counts add up |
| POST | `/fleet/images/check` | admin — the registry check on the hub and on every member at once |
| GET | `/health`, `/images`, `/networks`, `/volumes`, `/events`, `/snapshots`, `/automations`, `/schedules`, `/secrets`, `/audit` with `?fleet=1` | as the plain endpoint — the members' rows merged in, tagged `member`, `member_name`, `vmid`; `members[]` per DCS |
| POST | `/snapshots/create?fleet=1` | admin — one snapshot on the hub and one on every member; `results[]` per DCS |
| POST | `/fleet/relay` | public with a relay token — a member's event for the hub `{token, event, context}`: noted as `fleet_event`, notified with the VM named; 30 events a minute per member (429 beyond) |
| POST | `/fleet/hub/relay-token` | admin, on a member — the hub hands the member its relay token `{token}` |
| GET | `/backups?fleet=1` | as the plain endpoint — the members' rows merged in (`member`, `member_name`, `vmid`); `GET /containers` on a hub carries them always |
| GET | `/stream?fleet=1` / `?member=id` | user — the hub's SSE stream with every VM's docker events (or one VM's) |
| GET | `/maintenance/report`, `/maintenance/orphans`, `/maintenance/disk` with `?fleet=1` | user — the hub's and every VM's maintenance picture in one answer each: numbers and sizes added up, rows tagged, `members[]` per DCS (30 s cache) |
| GET / POST | `/fleet/members/{id}/terminal`, `/fleet/members/{id}/terminal/exec` | admin — can the hub open a shell in this VM (its ssh key, a live test); run a command there `{terminal_token, command, cwd?}` with the hub's own Terminal session, guarded, rate-limited and audited like the host terminal |
| POST | `/fleet/hub/domain` | admin, on a member — the hub hands the member the fleet's proxy domain `{domain, force}`; kept when the member has one of its own |
| POST | `/fleet/routes` | admin, on a member that runs a Traefik — the hub hands it everyone else's routes for that Traefik (`fleet-members.yml`) |
| POST | `/traefik/routes/rebuild` | admin — routes for services deployed before the domain (or Traefik) was there `{stack?}`; routes written before Authelia go behind it |
| GET | `/system/docker-engine` (`?fleet=1` on a hub) | user — the Docker Engine: version, package source, newest version offered, whether it can be updated unattended |
| POST | `/system/docker-engine/update`, `/fleet/docker-engine/update` | admin — update the engine here (unattended with passwordless sudo, else with the Terminal session and password) / on members `{members}` |
| POST | `/proxmox/vms/{node}/qemu/{vmid}/balloon` | admin — give a VM a memory balloon (three quarters of its memory kept): Proxmox then shows the guest's real usage and can take idle memory back |
| GET / POST | `/proxmox/capabilities`, `/proxmox/storage` | admin — what the token may do, the storages |
| GET / POST / DELETE | `/fleet/join-tokens`, `/fleet/join-tokens/{token}` | admin — join codes |
| POST | `/fleet/join` | public — a member registers with a join code |
| GET | `/fleet/bundle?token=` | public with a join code — the hub's code for a VM being built; or with an update round's bundle code, for the member it names |
| GET | `/fleet/identity`, `/fleet/feed` | user — what a hub reads from a member |
| POST / DELETE | `/fleet/join-hub`, `/fleet/hub` | admin — join a hub, leave it |

Command line, on any DCS: `.scripts/api-server.sh --join-hub URL CODE [NAME]`, `--join-token
[HOURS]`, `--fleet-status`.

---

## 6. Recommended layout on Proxmox

- **The hub** in its own small LXC or VM (2 cores, 2 GB, Docker installed): it keeps the
  dashboard (`core-infrastructure`), the Proxmox link, the fleet, the Discord bot and the route
  feed. An LXC needs *nesting* on for Docker (`features: nesting=1`, unprivileged is fine). Not
  on the Proxmox host itself: Docker there sets the kernel's forwarding policy to drop, which
  breaks the bridges Proxmox routes through.
- **One VM per stack**, built by the hub from the wizard's Stacks step (`media-services`,
  `networking-security`, `development-tools`…): 2 cores, 4 GB and 32 GB by default, sized per
  stack, each an API-only DCS with that one stack, joined to the hub, started at boot. VMs
  isolate CPU, memory and disks, and Proxmox backs each one up with vzdump.
- **The proxy** (Traefik, Authelia, CrowdSec) in the `networking-security` VM, pulling the
  hub's feed, which carries every VM's routes.
- **Addresses**: a range next to the hub (the wizard proposes `.200` upwards on the hub's
  subnet) on the bridge the hub shares with the VMs; the hub reaches each VM at
  `http://<address>:9876`, the VMs reach the hub at `FLEET_SELF_URL`.
- **DCS's own backups** stay per VM (Backup page); the hub's `.env`, `.data` and secret store
  are tiny and are covered by the VM backup.

---

## 7. Troubleshooting

| Symptom | Cause and fix |
|---------|---------------|
| *Proxmox rejected the API token* (401) | The token ID must be `user@realm!name`; the secret is the one shown when the token was made. Make a new token if it was lost. |
| *The API token lacks permission* (403) | Give `VM.Audit`, `VM.PowerMgmt`, `Sys.Audit` on `/` to the user (privilege separation off) or to the token itself. |
| *did not answer* | Wrong URL or port (the web UI's, `:8006`), a firewall in front of it, or certificate verification on with the self-signed certificate — switch it off, or install a real certificate on Proxmox. |
| Guests missing | *Only this node* is set, or they are templates (never listed). |
| `reset` refused for a container | Containers have no hardware reset; use *Reboot*. |
| The Terminal says *the hub cannot open a shell in* a VM | The hub reaches a VM's shell with its own ssh key as the VM's DCS account (`dcs`): a VM the hub built accepts it; one you made yourself needs the hub's public key (`.data/fleet-ssh/id_ed25519.pub` on the hub) in `~dcs/.ssh/authorized_keys`, and a VM that is off does not answer. The reason shown names which. |
| A stop shows as *VM stopped on its own* | The watcher only ignores changes DCS asked for in the last five minutes; a shutdown from the Proxmox UI or from inside the guest is reported, which is the point. |
| Feed never pulled | The proxy machine must reach `http://<target host>:9876` (or the dashboard URL): test with `curl` from there; check the token in the snippet; Traefik logs a provider error when it cannot fetch. |
| A route is missing from the feed | Its container publishes no host port, or only on `127.0.0.1`; the panel lists it under *skipped*. Add a `ports:` mapping. |
| A build fails at **Image** | *cannot hold imported images*: tick *Import* under Datacenter → Storage → local → Content (or give the token `Datastore.Allocate`). *download refused* / a 403 with `Sys.AccessNetwork`: the hub then downloads and uploads the image itself; give the token `Sys.AccessNetwork` on the node to let Proxmox download. |
| A build fails at **Create** | Proxmox's own message is in the log: `SDN.Use` on the bridge means the token lacks the role PVESDNUser; `Datastore.AllocateSpace` the role PVEDatastoreAdmin. |
| A build fails at **SSH** | The VM booted but never answered at its address: the bridge is not the hub's network, the gateway or prefix is wrong, or the address is taken. The Proxmox console of the VM shows cloud-init's log. |
| A build fails at **Install** with *cannot reach the internet* | The VM has no way out: the gateway does not answer, DNS fails, or (on a Proxmox host that also runs Docker) the forwarding policy dropped it. Fix the network, then *Retry*. |
| A build fails at **Install** with *could not fetch the DCS bundle* | The VM cannot reach the hub at `FLEET_SELF_URL` (a 403 means the build's join code expired — *Retry* renews it). |
| A build fails at **Join** | The VM installed DCS but its join never arrived: `FLEET_SELF_URL` must be the hub's address as the VM sees it; the VM's `~/.Docker-Compose-Skeleton-AIO/logs` says what it tried. |
| A build stops at **Stack** | The hub could not copy its `Stacks/<source>` into the VM over ssh (the VM's disk, or a folder the hub cannot read) — *Retry* copies again. A copy that landed but did not start says so in the log: open the VM on the VMs page and start it from there. |
| *The hub could not log in to http://…* on a join | The hub must reach the member's API at that address: a firewall, or a wrong detected address — set `FLEET_SELF_URL=http://<member ip>:9876` in the member's `.env` (or pass `url` on the join) and join again. |
| A build is refused: *runs on this server (the hub)* | The hub runs that stack itself: the message says whether it is in the hub's `DOCKER_STACKS` (take it out: Stacks page → order) or its containers are still up (a stop takes a moment — try again when the Stacks page shows it stopped). A bare `Stacks/<name>` folder never blocks a build. |
| A build is refused: *A guest named … already exists on Proxmox* | A VM or container already carries the stack's name. Link it from the Proxmox page if it is that stack's DCS, or rename it in Proxmox and build. |
| A build failed and its VM is still on Proxmox | *Retry* resumes the job (the VM is reused); *Dismiss* asks whether to destroy the VM as well (`DELETE /fleet/jobs/{id}?destroy=true`). |
| The join code is refused | Codes expire after 24 h (or the hours chosen) and are case-insensitive; mint a new one on the hub's Proxmox page. Five wrong codes from one address lock it out for a while, like logins. |
| A member shows *no guest matched* | No guest agent (uuid still works for a VM if the hub reads `smbios1`, but an LXC or a VM whose name differs from the hostname needs the address or the name to match): pick the guest from the member menu. |
| The scan finds nothing | The scan needs each guest's addresses from the QEMU guest agent (or container interfaces) and DCS answering on port 9876 there (`FLEET_SCAN_PORTS` for others). A VM without the agent shows *address unknown*. |
| A member's stacks are missing from the Proxmox page | *Members answering* in the page header says whether the hub reached it; the member menu's *Test* explains a refusal (a changed password on the member: edit the member and enter it again). |
| An update round says *the bundle could not be unpacked: … Function not implemented* | The member's `dcs-api.service` still carries `RestrictSUIDSGID=true` from an older installer; under it systemd answers tar's `openat2()` with ENOSYS on Fedora 44 (systemd 259). Run `sudo .scripts/install-service.sh` once on that VM and restart the service — every later round refreshes the unit by itself when the installer changes. |
| A VM's events do not show on the hub's Activity page or in its Discord/NTFY | The member has no relay token yet: the hub hands one out within a minute of the member answering (`.data/fleet-relay.json` on the hub); a member older than 3.9.0 gets it after an update round. Events raised while the hub was unreachable are not queued. |
| The dashboard container (DCS-UI) is *unhealthy* and its log says `socketpair() failed (13: Permission denied)` | Debian's own `docker.io` 26 with AppArmor 4.1 (Debian 13, and a Proxmox host) denies nginx its worker sockets. `setup.sh` detects that pairing and writes `DCS_UI_APPARMOR=unconfined` into `Stacks/core-infrastructure/.env`; on an install made before 3.9.1 add that line yourself and run `docker compose up -d dcs-ui` in that folder, or install Docker CE, which needs nothing. |
| A service inside a VM is not reachable through the hub's Traefik | The hub writes the members' routes into its Traefik's `custom_routes/fleet-members.yml` every half minute (audit entry `fleet_routes`); the member must answer, its container must carry Traefik labels, and the hub's Traefik must reach the VM's address (same bridge, no firewall in between). The feed for a Traefik elsewhere is separate (section 4). |
| A VM's RAM shows near 100 % on the Proxmox page while the guest is idle | Without a memory balloon Proxmox reports the host's view of the VM (its whole allocation, once the page cache fills). VMs the hub builds get a balloon (three quarters of the memory kept); for an older one use *Enable ballooning* in the VM's sheet (or `qm set <vmid> --balloon <half>`) and reboot it. |
| A service in a VM answers without the Authelia portal | The hub's Traefik puts VM routes behind Authelia when Authelia is deployed on the hub; templates whose apps bring their own clients (`"auth": "bypass"` in their `template.json`) stay open on purpose. The deploy sheet's per-route switch decides otherwise. |
| A service deployed into a VM has no route | The VM had no domain when the service was deployed: the hub hands the domain out within a minute (audit `fleet_domain`), and the member writes the missing routes then; *Rebuild routes* (`POST /traefik/routes/rebuild`) does it by hand. |
| A Fedora VM does not answer after a reboot; `journalctl -u dcs-api` says `203/EXEC` | SELinux: the updated script lost its `bin_t` label (fixed in 3.9.1, the update relabels). By hand: `chcon -t bin_t ~/.Docker-Compose-Skeleton-AIO/.scripts/api-server.sh && sudo systemctl restart dcs-api`; `dnf install policycoreutils-python-utils` and `./.scripts/install-service.sh` make the rule persistent. |
| A VM's own Updates page says *Updated by its hub* | By design: a VM built by the hub has no git checkout, its code comes from the hub's Updates page (*Update all VMs*). |
| Detection says nothing about Proxmox | Detection reads `systemd-detect-virt` and the DMI vendor; a VM without the guest agent still shows as *QEMU/KVM*, which is treated as a probable Proxmox VM. The probe looks for port 8006 on the default gateway and on `pve`, `proxmox`, `pve.local`, `proxmox.local`; if your host has another name, just type the URL. |

Related: [README → Running inside a VM](../README.md#running-inside-a-vm-proxmox-kvm-qemu),
[docs/DISCORD.md](DISCORD.md) for the bot and webhooks, [docs/API.md](API.md) for every endpoint.
