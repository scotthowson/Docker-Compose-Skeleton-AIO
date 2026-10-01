# Changelog

All notable changes to DCS Orchestrator are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [4.0.9] - 2026-10-01

### Fixed

- **The Updates page kept reporting VMs that no longer exist.** *Last round: 0 updated, 5 failed* listed every VM that had been removed
  since, for good. The report is read without the members that left the fleet (and is dropped when none of them is left), and removing
  a member takes its lines out of it.
- **A member that leaves takes everything of it along.** *Remove from the fleet* and a forgotten stack's member go through one path now:
  the record, the stored passwords, the hub's session with it, its relay token (a VM that left could still have relayed events), the
  stamps kept for it and its lines in the last update round.
- **Edit backups with a time in their name travelled into the hub's copy of a VM stack** (`docker-compose.yml.bak.20261001143241`): they
  stay where they are made, like the plain `.bak` files; the next pull takes them out of the hub's folder.
- **A VM that missed one look answered 502 through the hub for up to a minute and a half** (4.0.7): a member marked unreachable is asked
  again at most every ten seconds, by whichever call comes first; a VM that was rebooting or just built is back within those ten seconds,
  and VMs that are gone still cost nothing in between.

### Tests

- `tests/fleet-files.sh`: a timed backup does not travel, the round's report forgets who left, a removed member leaves no token, session
  or stamp behind (64 checks).

## [4.0.8] - 2026-10-01

### Changed

- **A request through the worker pool costs about half of what it did, and a burst of dashboard polls stays in the pool.** Measured on a
  4-core Debian 13 hub with a 430-line `.env`: a pooled request 39 ms → 22 ms, a burst of 24 parallel requests 1.8 s → 0.9 s of CPU.
  - A worker parsed `.env` again for every request (so that a setting saved through another worker was in force at once): on a hub
    with a long `.env` that cost more than the pool saved. It is read again only when the file is newer than the worker, a test bash
    does itself.
  - `API_WORKERS` is automatic when empty: twice the cores, 4 to 8 (4 on a machine with less than 3 GB). Four workers were fewer
    than the requests three or four open dashboards send at the same moment, and what did not fit was served the expensive way.
  - The front waits a second for a free worker before it gives a request a process of its own (a quarter of a second spilled most
    of a burst), and neither the front nor a worker starts a process for a temporary name, the clock or a pause any more.

## [4.0.7] - 2026-10-01

### Fixed

- **The dashboard kept losing the API on a hub with a dashboard open, and the CPU ran high** (4.0.5 and 4.0.6). The worker pool was a
  queue: an event stream (the dashboard's *Live* feed is open for as long as its tab is) held a worker for good, and a request that
  found every worker busy waited up to five seconds and was then refused. The pool is a fast path now: a stream, and any request that
  finds no free worker within a quarter of a second, is served by a process of its own, the way every request was before the pool —
  nothing waits behind a slow request and nothing is refused.
- **Every fleet answer waited seconds for each VM that was gone.** A member the watcher had marked unreachable was asked again by every
  call (3 s each, per member, per request). The watcher looks once a minute; within that minute its verdict stands and a call to such a
  member fails at once. The member's *Test* button still asks for real.

### Tests

- `tests/api-workers.sh`: two open streams leave the two workers free; a request with no free worker is answered all the same (28 checks).

## [4.0.6] - 2026-10-01

### Fixed

- **Delete on a stack whose VM is gone did nothing.** The request was forwarded to a VM that no longer answered (deleted in Proxmox, or
  off), and the card stayed on the Stacks page for good. The hub settles it now: a VM that Proxmox no longer has, or one the hub cannot
  ask Proxmox about, is forgotten — the stack's placement and the hub's copy of its files go (the compose history keeps the versions),
  and when the guest is gone and that was its last stack the member is removed from the fleet with it. A VM that still exists but is off
  is left alone, and the answer says so: start it and delete again, or use *Remove from the fleet* on the Proxmox page.

### Tests

- `tests/fleet-files.sh`: deleting a stack whose VM does not answer forgets it (56 checks).
- The two listener tests run where Docker is absent (the Debian CI container) and no longer count a worker's socket in the moment
  between two connections.

## [4.0.5] - 2026-10-01

### Added

- **Nodes: `DCS_ROLE=node`, the API alone.** A VM that runs stacks under a hub needs no dashboard, no accounts and no wizard of its
  own. With `DCS_ROLE=node` in `.env` (what `setup.sh` writes for one; a DCS node image says so in `/etc/dcs-role`) the API has no
  first-admin gate — an empty `users.json` means "not joined yet", never "set me up" — and `POST /auth/setup`, invites,
  `POST /auth/users`, `POST /auth/register` and the wizard's endpoints answer 403 naming the hub (*This is a node of
  Howson-Hub (http://…): accounts belong to the hub — open the hub's dashboard*); `POST /auth/login` refuses every name but a
  service account's, so the hub's `dcs-hub` signs in and nobody else can. `GET /setup/status` on a node says `role: node` and
  which hub manages it, `GET /` and `GET /fleet/status` carry the role (`dcs_role`), a node's identity does too (the hub keeps
  it as `identity.role`), a factory reset keeps `DCS_ROLE` as it keeps `FLEET_ROLE`, `start.sh` and `stop.sh` on a node touch
  only the stacks the hub gave it and never the dashboard's stack, and `setup.sh` on a node asks no role question, makes no
  admin, takes no stack list from the example and binds the API for its hub. The default, `hub`, is what every install was
  until now — the full DCS; a standalone server is a hub without members — and nothing changes for it. See
  [Configuration](docs/CONFIGURATION.md#proxmox-and-the-fleet), [Proxmox → VMs you made yourself](docs/PROXMOX.md#vms-you-made-yourself)
  and [Getting Started → a node](docs/GETTING-STARTED.md#a-node-a-vm-the-hub-manages).
- **One line makes any VM a node of the hub.** `GET /fleet/bootstrap?token=<join code>` (public with a valid code, like the
  bundle; `&stack=` names the one stack the node carries) serves `.scripts/fleet-bootstrap.sh` with the join's values in front
  of it, so `curl -fsSL 'http://<hub>:9876/fleet/bootstrap?token=<code>' | bash`, run as a user with sudo on any Debian, Ubuntu,
  Fedora or Arch machine, installs Docker and the tools, fetches the hub's code, sets DCS up as a node and joins.
  `POST /fleet/join-tokens` and `GET /fleet/join-tokens` answer the line as `node_command`, the dashboard's Join code card shows
  it first, `setup.sh` on a hub and `--join-token` print it, and a VM built from an installer ISO gets it in its build card. The
  bootstrap now runs as root without sudo, says at once when sudo would ask for a password, installs with pacman on Arch, and
  names the stack after the machine when the hub did not.
- **The API answers from a pool of worker processes (`API_WORKERS`, default 4).** Every request used to start bash on the 27,000-line API script
  (about 0.15 s of CPU on a small VM, cached answer or not), and an open dashboard made five of them a second: a 2-vCPU hub sat at 100 % and more
  with one browser tab. The server now keeps copies of itself that read the script once; a tiny front (`.scripts/api-dispatch.sh`, socat execs it per
  connection) reads the request and hands it to a free worker with the client's address, tries the next one when that worker is busy, and waits a
  few seconds when all are. A request runs in a subshell of the worker, so nothing a handler sets, changes or traps survives into the next; a worker
  renews itself after `API_WORKER_REQUESTS` answers and a dead one is replaced. `API_WORKERS=0` is the old transport; ncat hosts keep it.
- **Topology across the fleet.** On a hub, *Everywhere* on the Topology page is the fleet map: the hub's own stacks, containers and networks and every
  reachable VM's, each under its server's band (`GET /topology?fleet=1`; a VM's names are kept apart under its own name). A VM that did not answer
  is shown as such.
- **A VM stack's files are the hub's.** `Stacks/<name>/` on the hub holds a VM stack's compose, `.env` and configuration like any
  stack the hub runs itself: the dashboard reads the hub's copy (a VM that is off still shows its files) and writes it, and every save
  is pushed into the VM right after (`POST /stacks/<name>/files` there; the answer says whether the VM took it). What the VM wrote
  itself (a template deployed into it) is pulled back; a VM stack the hub has no files for yet is adopted on the first read, on join,
  on a manual add and from the watcher. *Push files to the VM* / *Pull files from the VM* on the stack, *Sync stack files* on the VM
  (`POST /stacks/<name>/push`, `/pull`, `POST /fleet/members/<id>/sync`). Only configuration travels: no App-Data, data, logs,
  caches, `acme.json` or edit backups; 2 MB a file, 16 MB a stack; a path cannot leave the stack folder. A rebuilt VM gets its stack
  back with one push, and a stack made last night is still there in the morning.
- **The fleet's services by name.** `GET /fleet/services` lists every running container with a published port on the hub and in every
  reachable VM — where it runs, its LAN address, its route. A template deploy's `*_URL`, `*_ENDPOINT` and `*_HOST` variables left at
  their compose-network default (`http://jellyfin:8096` reaches a Jellyfin on the same Docker network only) are pointed at the fleet's
  service of that name when it runs on another server, on the hub and before a deploy is forwarded into a VM; a value you typed is
  kept, a service of the template itself is left alone, and the Activity page says what was filled.
- **A VM you linked by address or by code is placed.** A stack a member runs that nobody answers for, and that the hub does not run
  itself, is placed with that member by the watcher — before, a VM whose stack was named like a folder the hub ships was never placed,
  so its buttons landed on the hub's own folder.
- `POST /auth/password` changes your own password (the Settings page only rewrote a copy in the browser); `/auth/verify` says whether
  2FA is on; a session remembers the address it was opened from.
- `POST /images/pull` (the Images page's Pull button had no route) and `POST /images/delete {image}` (a tagged image goes by its name).
- A snapshot's row says the host and DCS version it came from; the Config page's *Force colour* and *Progress bar width* are keys the
  save takes and reads back, *Pull images on boot* reads back.
- **Homarr in a VM counts.** The hub finds a running Homarr on any member (the fleet snapshot: a container named Homarr with 7575 published), so the
  deploy sheet offers *Add to Homarr*, the Integrations panel says which VM it runs in, the stored key is checked against that Homarr, and every new
  route of a VM gets its tile - with Homarr on the hub, in a VM, or at `HOMARR_URL`.
- **`CROWDSEC_MEDIA_APPS`: a media app's web client is not a crawler.** One page of Jellyfin's web client makes dozens of API and artwork requests in a second, some of them answered 404
  (an item without a logo), and CrowdSec's generic HTTP scenarios (`http-crawl-non_statics`, `http-probing`) banned a friend who was just watching. The setting names the Traefik backends
  that are media apps (comma separated service hosts, default `jellyfin`, empty turns it off). For them DCS keeps `parsers/s02-enrich/dcs-media-apps.yaml` in CrowdSec's configuration,
  next to the whitelist's file: it is written when it differs, removed when the setting is empty, and CrowdSec reloads only then. The file ignores what the app **answered** (a `GET` or `HEAD`
  with 2xx/3xx, unless the path tries to leave the web root) and a 404 on an item's picture; 404/403/400/401 answers, other methods, path traversal and every other backend are judged
  as before, so scanners and brute forcers are still banned. Names are checked (`^[a-z0-9][a-z0-9_.-]*$`, any case) before they go into the file. See
  [docs/CROWDSEC.md](docs/CROWDSEC.md#media-apps-a-web-client-is-not-a-crawler).
- **Traefik's add-ons are switches of the template.** The Traefik step of the setup wizard and the template's deploy sheet have five switches (`TRAEFIK_SABLIER`,
  `TRAEFIK_CLOUDFLARE_REAL_IP`, `TRAEFIK_GEOBLOCK` with `TRAEFIK_GEOBLOCK_COUNTRIES`, `TRAEFIK_THEMEPARK`, `TRAEFIK_MAINTENANCE`). *Start containers on demand* deploys
  the Sablier template into the same stack, started with Traefik (a Sablier that runs already is left alone). *Cloudflare real IP* puts `cloudflarewarp` first in
  `traefik-chain`, so the CrowdSec bouncer and Geoblock judge the visitor and not Cloudflare. *Geoblock* defines a `geoblock` middleware in the chain with the
  countries you list (ISO 3166-1 alpha-2, comma separated, checked before anything is written: `UK` is refused and told that the United Kingdom is `GB`; the
  preview refuses the same). *theme.park themes* declares the plugin at the start, so a theme needs no Traefik restart. *Maintenance mode* defines a `maintenance`
  middleware with a holding page, shown with a 503 on the routes that name it while `App-Data/Traefik/maintenance.trigger` exists. Each switch declares its plugin
  only while it is on: Traefik downloads every declared plugin at start and does not start when one cannot be fetched. The proxy stack's `.env` remembers the
  switches (a deploy that does not mention them keeps them), a re-deploy takes out what DCS wrote and nothing else (a `geoblock` of your own stays), and a running
  Traefik restarts when its static config changed. The deploy's answer carries `addons` and `sablier`. See [docs/TEMPLATES.md](docs/TEMPLATES.md#traefik-add-ons).
- **Optional blocks in a template's config files.** A block between `# dcs-if: VAR` and `# dcs-end` is uncommented when the deploy variable `VAR` is true and
  commented out when it is not, on every deploy, the way the ACME challenge markers already work; `type: "boolean"` in `template.json` makes such a variable a
  switch on the deploy sheet. The Traefik template's plugin declarations use it, and `_traefik_ensure_plugin` turns a block on instead of declaring a plugin twice.

### Changed

- **The Traefik template declares a plugin only while its switch is on.** It declared geoblock, cloudflarewarp, log4shell and Sablier on every deploy, whether or
  not anything used them, and a plugin that cannot be fetched (the registry down, no route out) stops Traefik from starting at all; the chain file also defined
  `my-geoblock`, `cloudflarewarp` and `log4shell` middlewares for them. Only the CrowdSec bouncer stays declared always (the crowdsec template wires it); the
  Log4Shell plugin, which nothing used, is gone; geoblock is pinned to v0.3.8. An existing install keeps its files: a plugin a flow needs on the spot (the theme
  page, start on demand) is still declared then, by turning its block on.

- **The VMs the hub builds are nodes.** The bootstrap exports `DCS_ROLE=node`: no admin account is made in the VM any more and
  no `FLEET_MEMBER_<STACK>_ADMIN_PASSWORD` is minted on the hub (the one kept for a VM built earlier is still removed with its
  member). Members installed as a full DCS keep working as they are: a node is a role an install has, not something an update
  does to it.
- **Docs: the cloud-init key step of the hub VM no longer fails on a fresh Proxmox host.** [Getting Started](docs/GETTING-STARTED.md), step 4, used `--sshkeys /root/my-key.pub` without saying where
  that file comes from, so `qm set` printed *can't open '/root/my-key.pub' - No such file or directory* - and still generated the cloud-init drive, which left a VM with no key (ssh takes keys
  only). The step now makes the key (`ssh-keygen`), copies it (`scp`), shows it (`cat`), guards the `qm set` line (an `if [ -s ... ]`, so the VM is never started without a key) and says how to recover
  (`qm set` again, `qm reboot`, the serial console with `--cipassword`). The by-hand example in [VM-IMAGES.md](docs/VM-IMAGES.md) used `~/.ssh/id_ed25519.pub`, which a Proxmox host does not
  have either; it points to the same step now, and the troubleshooting table has the message.

### Fixed

- **What an audit of every dashboard button against its handler found**, fixed on the API side: a worker serves each request with
  the `.env` of now and renews itself when `.env` changed; the deploy sheet's proxy-network switch is honoured; batch *Update
  selected* and batch "all" reach the stacks in VMs (they were pulled and started on the hub); a VM stack deleted on purpose takes
  the hub's copy and placement with it, a clone made in a VM is placed there, a VM stack cannot be renamed on the hub (409 with the
  reason), a renamed hub stack keeps its history; an emptied `.env` or crontab is a valid save; a member's dashboard/OS facts reach
  the overview; a VM stack's row says qemu or lxc; a build's log shows 60 lines; the live framework log's `since` takes the stamp the
  API printed and the log is readable by whoever may read the log; the hub's terminal follows `cd`; a webhook test says whether the
  hook took it; a download through another origin (the Android app) carries the CORS headers; a member's route rename or delete
  finds the file under the stack it was deployed into; the fleet update's running marker has the shape the Updates page reads; the
  nuke dialog's answer uses the names the dialog reads; a member refusing the hub's account answers 502 instead of a 401 that signed
  the dashboard out of the hub; a member's terminal sign-in goes through the hub; the hub's cache is cleared before a forwarded write.
- **The deploy sheet's HTTPS routing switch and its per-service boxes switch a route off now** (`{routes: false}`, `{route_services:
  [names]}` on a deploy): before, a service left unticked still got the default route, behind Authelia, because the API wrote one for
  every service without a route file.
- **A VM built by the hub has its stack's files on the hub from the start**: the build pulls them from the VM once the stack runs
  there (a join that came in while the copy was under way had adopted the VM's placeholder compose instead).
- **Homarr on the hub was never found** since the locator asked itself for the port (the hub branch was dead; a VM's Homarr was found).
  An imported template without metadata no longer breaks the Templates page; an edit of a template keeps the keys the editor does not
  carry (icon, auth, singleton, config_path, route_skip).
- **A re-deploy of the Traefik template reset the stack's route file.** `custom_routes/<stack>/traefik.yml` (the dashboard route and `traefik-chain`) was
  overwritten with the shipped copy on every re-deploy, which dropped the CrowdSec bouncer's chain entry and any edit by hand, and the shipped copy was also left
  under `custom_routes/core-infrastructure/`, where Traefik read its routers a second time. The stack's copy is kept now, and no second copy is left behind.
- **A VM you made yourself never linked to the hub.** `.scripts/api-server.sh --join-hub` (what `DCS_HUB_URL=… DCS_JOIN_TOKEN=…
  ./setup.sh` runs at the end) found no account on the fresh VM and *saved* the join for the VM's own setup wizard to run — the
  hub's account made earlier would have closed the first-admin window — and printed *Join saved*, so `setup.sh` reported success.
  Nobody opens a wizard on a VM that is only meant to run stacks, so the VM stayed behind its first-admin gate for ever and the
  hub never heard of it (`media-services` at 192.168.1.20). A node has no wizard and no admin of its own: it joins at once, and
  the hub's account is the only one it ever has. A full DCS without an admin still defers its join to its wizard, which is right
  for it.
- **On Debian 13 the CrowdSec page said *Could not work out the CrowdSec state*, a VM's details sheet showed *empty answer* and never read the balloon
  state, and the CrowdSec Settings tab wrote nothing.** Debian 13's jq (its build of 1.7.1, reporting `jq-1.7`) refuses three things jq 1.8 accepts:
  an operator inside an object value (`{a: $x + 1}`), `f?.field`, and `A + B as $x | …` (bound as `A + (B as $x | …)`: the profiles file came out as an
  array added to a string). Every such place is written the way both read it, CI runs the smoke suite inside `debian:trixie` as well, and the hub
  VM images (all Debian 13) are covered by it.
- **`traefik.<domain>` answered 502 on every default deploy.** The dashboard route (`.templates/traefik/config/custom_routes/*/traefik.yml`) pointed at `http://Traefik:${TRAEFIK_PORT_DASHBOARD}`, but that variable is the port published on the HOST (8180 by default, since the template moved off 8080); inside the Docker network the dashboard listens on 8080 only, so Traefik had nothing to talk to. The route now names the container port. An existing route file keeps the old port until you change it: `sed -i 's#http://Traefik:8180#http://Traefik:8080#' Stacks/<stack>/App-Data/Traefik/custom_routes/<stack>/traefik.yml` (the file provider picks it up in seconds).
- **Every whitelist sync rewrote `dcs-whitelist.yaml` and reloaded CrowdSec, although nothing had changed.** The file was compared with the text it ends in a newline, and `$(cat …)` drops
  that newline, so the two never matched: CrowdSec got a reload every ten minutes (and every DDNS check). It is compared as it is written now, and the reload, like the
  `reloaded` field of `.data/crowdsec-whitelist.json`, means the file really changed.

### Tests

- `tests/fleet-files.sh`: a VM stack's files against two real listeners — adoption on a read, pull, push, sync both ways, a save on the
  hub reaching the VM, nothing but configuration travelling, a path that cannot leave the folder, a member that is off (52 checks).
- `tests/smoke.sh`: a password change of one's own, the 2FA flag, the session address, the Config rows, image delete by reference.
- `tests/api-workers.sh`: the worker pool on a real loopback listener - the same answers and headers as the one-process transport, the client's address
  reaches the handler, a 16-way burst, renewal in place, a killed worker replaced, `--stop` leaves nothing behind, `API_WORKERS=0`.
- `tests/smoke.sh`: Homarr found in a VM (where, address, mode, hint), the fleet topology merge (both servers, the VM answered, its names kept apart).
- CI: `smoke-debian` runs the whole smoke suite inside `debian:trixie` (the hub images' OS and jq).
- `tests/smoke.sh` (`SMOKE_CS_PARTS=mediaapps`): the file for the default, two names, an empty setting, names that are not host names and letters of other alphabets; a sync that changes nothing
  rewrites nothing and reloads nothing; one reload for a change; CrowdSec absent or stopped; a loop that started with another value follows `.env`.
- `tests/crowdsec-media-apps.sh` (opt-in: Docker, the CrowdSec image, the network): the file DCS writes, replayed through the real CrowdSec twice, without it and with it, over fifteen kinds
  of traffic: page loads are not alerts any more, scanners, brute forcers, traversal and other backends alert exactly as before.
- `tests/smoke.sh`: the Traefik template deployed with every add-on off, on (the plugins declared and their modules, the countries tidied and listed, the chain
  order, the maintenance middleware and page, Sablier merged into the stack, two backups), refused (`UK`, an empty list, three letters, `XX`; the preview too),
  kept by a deploy that does not mention them, off again (the static config as shipped); a hand-written `geoblock` left alone; a flow declaring a plugin turns
  its block on, once; the switch blocks change nothing when run again; a re-deploy keeps the bouncer in the chain and leaves no second route file.

## [4.0.4] - 2026-09-30

### Fixed

- **The dashboard's "Active Routes" card (the Subdomain Status card of the `traefik-subdomain-guard` plugin) stopped its list at 200 px, however tall the card was made in *Edit dashboard*.**
  The card capped its list with `max-height: 200px`; it fills its frame now and the list takes the height that is left. It also takes its colours from the look in use (`--dcs-text`,
  `--dcs-text-muted`): its route names were pale grey on white in the light theme. The authoring notes for plugin cards
  (`.plugins/example-card/README.md`) say the same to whoever writes the next card: give the list `flex: 1; min-height: 0; overflow-y: auto`, never a fixed cap. The dashboard 4.0.3 makes the page a
  card runs in as tall as its frame, and the built-in cards follow their box too (see its release notes).

## [4.0.3] - 2026-09-30

### Fixed

- **The Flarum template's optional database showed up as a blank choice in the deploy sheet.** Its `optional_services` entry was a bare service name (`"flarum-db"`), while every other template
  (and `docs/TEMPLATES.md`) uses `{service, label, description, default_enabled}` and the sheet reads the label. It has its label and description now (Include the built-in MariaDB database),
  and `tests/lint.sh` fails a template whose optional services are not in that shape.
- **`docs/CONFIGURATION.md` listed settings that no longer do anything** (`STACK_START_TIMEOUT`, `DOCKER_TIMEOUT`, `REMOVE_ORPHANED_CONTAINERS`, `FORCE_RECREATE`, `LOG_MAX_SIZE`,
  `LOG_RETENTION_DAYS`): they were removed in 4.0, the API accepts and ignores them from an older dashboard, and nothing reads them. The tables list what is read.

### Tests

- The CrowdSec settings endpoint is checked against a hand-written `profiles.yaml` that has only one of the two stock profiles, or neither (`settings/partial`): the page must call it
  a hand-written file (200, `mode: custom`), never fail with a 500.

## [4.0.2] - 2026-09-30

### Fixed

- **The CrowdSec page said "Traefik has not asked CrowdSec yet" when you define the `crowdsec-bouncer` middleware yourself.** Traefik keeps the first definition of a name it reads,
  so with your own definition in `TraefikRoutes.yml` and the copy DCS wrote at registration, it uses yours (with your key) and skips DCS's, and the bouncer DCS registered is never asked.
  The page only watched that bouncer. It counts the newest pull of any Traefik bouncer now, names it (`bouncer.pulled_by`), and shows a note (`bouncer_duplicate`) that the middleware is
  defined twice. A page with only your own middleware and bouncer reads as a working setup, not as a missing file.
- **Registering the bouncer wrote a second copy and a second bouncer next to your own middleware** (which is how the false alarm above began: the old chain check told such an
  install that the chain did not list the bouncer, and *Register again* was the button). It puts your middleware in the chain and stops now.
- **A 403 from CrowdSec's Central API is explained** on the community row: CrowdSec is refusing this server (its login or its address), what to run, and that detections and bans keep working.

## [4.0.1] - 2026-09-30

### Fixed

- **The CrowdSec page said the bouncer was not in `traefik-chain` and that every route bypassed it, on an install whose chain file sits beside the routes directory.**
  The original Traefik layout keeps `TraefikRoutes.yml` next to `custom_routes/` and mounts it into the container's routes directory, so on the host the chain is one level above
  the place DCS looked, and DCS looked there for a `traefik-chain:` at exactly four spaces of indent. It finds the chain in the routes directory or in the Traefik folder above
  it now, and reads it by its indentation (any indent, quotes or none, a comment after an entry, Windows line endings, an `@file` suffix). A route that lists
  `traefik-chain@file` counts as protected too, and so does a route on a chain of your own that lists the bouncer (a `media-chain`, or a chain of chains): the page
  no longer calls such a route unprotected.
- **Registering the bouncer could not add it to such a chain, and would have put it at the top of a hand-written one.** *Register again* leaves a chain that lists the
  middleware already untouched, puts a new entry after `cloudflarewarp` or `real-ip` (a bouncer that runs before them judges Cloudflare's addresses), and rewrites the file in
  place: a stack that bind-mounts the chain file as a single file kept looking at the old copy after a rename over it.

## [4.0.0] - 2026-09-30

The first release under the name DCS Orchestrator. The headline changes are the purpose-built VM images for Proxmox, the CrowdSec
page, one set of names for every page, and a round of fixes to the API (below). It is a normal release: an install on the stable
channel is offered it under *Updates*, and nothing about its branch or channel has to change.

### Added

- **Purpose-built VM images** (`vm-images/`, [docs/VM-IMAGES.md](docs/VM-IMAGES.md)). A hub image that boots straight into the
  setup wizard and a node image the hub clones for every stack, for Debian 13, Ubuntu 26.04 LTS, Fedora 44 (SELinux
  enforcing) and Arch Linux (rolling): a Docker host and nothing else, 240-470 MB to download, a fresh disk of 640-980 MB, ssh
  about five seconds after `qm start` on Proxmox (1-2 s of userspace on KVM). One disk boots under BIOS and UEFI; `dcs-init` reads
  the Proxmox seed in place of cloud-init and survives a power cut at its first boot; the Proxmox console shows a login (and a hub's
  address); `dcs-proxmox.sh` turns a release image into a hub VM or a node template on the Proxmox host in one command. `build.sh`
  builds and tests them without root: 22 checks per node image, 27 per hub image, on both firmwares.
- **`vm-images/images.json` is the one list of images.** The build, the CI matrix, the Proxmox importer, the API's image catalogue and
  the documentation read it or are checked against it; `tests/lint.sh` fails when a distribution is in one place and not in another.
- **VMs start 2.6 s sooner.** Proxmox starts every VM with `-boot menu=on` and SeaBIOS as well as OVMF wait about 2.6 s for an ESC key,
  at every boot. `dcs-proxmox.sh` switches it off (`--boot-menu` keeps it); the hub tries it on the VMs it builds (only `root@pam` may
  set `args`: a token is refused once, the build's log says so and gives the `qm set` line), and a VM's *Info* sheet shows the state.
- **Docker Engine on Arch.** The engine card and its update know Arch's `docker` package: the newest version is read from a private
  copy of the sync databases (the system's own are never refreshed alone) and the update is a whole-system `pacman -Syu`, with the
  engine restarted, or a reboot note when the kernel changed.
- **A hub's badges and cards count its VMs' images, networks and volumes.** `GET /fleet/overview` carries each VM's Docker counts (from its
  `/status`) and their sum in `totals` (`images`, `networks`, `volumes`); the dashboard adds them to the hub's own in the sidebar badges, the
  Docker Images card and the status bar, as it already did the containers and the stacks.
- **The boot test makes a member of every node image.** On its BIOS run a node image is joined to a hub started from the checkout, with
  the same bootstrap the dashboard runs, and used through it: host name, the Docker Engine card, the Cron Jobs page, a stack with a healthy
  and an unhealthy container, a Docker restart, an engine update (`vm-images/tests/member-check.sh`). It found the problems listed under
  Fixed below.
- **Each image says what its kernel drives.** `vm-images/images.json` holds a `hardware` line per image (Debian's cloud kernel drives
  virtual hardware only, the others carry the drivers of real GPUs, USB devices and network cards), the image catalogue passes it on, lint
  fails when one is missing, and the *New VM* sheet shows it under the operating system.
- **The hub builds VMs from the purpose-built images.** The OS pickers (the wizard's VM step, *New VM stack*) list the DCS
  images first and recommend them; a VM from one is created straight from the imported image (nothing to install, so
  nothing to bake), and the hub has Proxmox check the download against the release's `SHA256SUMS`. The images come from the
  release of the running version (`FLEET_DCS_IMAGE_BASE` names another place); the cloud images stay in the list.
- **A theme carries both its looks.** A theme document may hold `palette_dark` and `palette_light` next to `palette` (each a
  full palette, validated like it); the dashboard shows the one that matches the dark/light switch, so a theme is never
  worn in the wrong mode. Documents with only `palette` and `mode` stay valid.
- **The VM sheet says what the VM runs and what it was built from.** Info on a VM card lists the operating system the guest
  reports through the guest agent (or the DCS inside it, or Proxmox's OS type), the image the hub built it from and the DCS
  template it was cloned from, the firmware (BIOS or UEFI) and the creation date. New VMs carry the image in their Proxmox
  description; `GET /proxmox/vms/{node}/{type}/{vmid}` returns `os`, `image` and `config.bios`, `machine`, `created`.
- **The hub's own VM is tagged in Proxmox.** The VMs the hub builds already carried `dcs;<stack>`; the VM that runs the
  hub now gets `dcs;hub`, put on when the wizard finishes with Proxmox linked (the completion screen says so) and by
  an *Add …* button naming the missing tags on the *This server* card of the Proxmox page (`GET /proxmox/self`, `POST /proxmox/self/tag`).
  DCS only adds tags, finds its VM by SMBIOS id, address or name, tags a non-hub DCS `dcs` alone, leaves a machine that
  is no guest of the linked host alone, and explains a token without `VM.Config.Options` instead of failing the setup.
- **The CrowdSec page** ([docs/CROWDSEC.md](docs/CROWDSEC.md)). One page for intrusion prevention, with a logical view for every state
  CrowdSec can be in (not deployed: a pre-flight and one-click deploy that follows the deployment and opens the page by itself; stopped, crash
  loop, starting, unhealthy, API unreachable, Docker down: the honest reason, the log and the one-click fix) and, when healthy, an overview
  (detections over time, a dotted world map, countries, kinds of attack, busiest sources, whether Traefik enforces the bans), the bans (search,
  filters, sort, ban an address or network for 1 h to permanent, bulk lift, import and export as CSV or JSON, a self-lockout guard), the alerts
  with the requests that raised them, the allowlist (CrowdSec's native allowlist or DCS's whitelist parser, and it says which), the Discord alerts, the ban
  settings, the hub, the bouncers, machines and community status, and the container log. Countries are shown everywhere as a flag and a name and can be
  filtered and ranked over 24 hours, 7 or 30 days (the Traefik bouncer enforces addresses and networks only, so there are no country bans, and the page says so).
  **Everything about the Discord message is configurable on the page**: on and off, a global or CrowdSec-only webhook (masked, admin only), name, avatar,
  colour, mention, which events notify, filters, batching, and the title, description, footer and fields written with 33 placeholders, with a live preview that
  is rendered by the server so it equals what is sent, and a real test message. The ban length, repeat-offender escalation, per-scenario lengths and simulation mode
  are settings too. Every change to CrowdSec's files is validated by CrowdSec itself, backed up, applied with a restart, read back, and rolled back on failure; user
  text never reaches a generated file as code; a re-deploy keeps what the page manages. `GET /crowdsec/status`, `/decisions`, `/alerts`, `/metrics`, `/allowlist`,
  `/bouncers`, `/machines`, `/settings`, `/simulation`, `/notifications`, `/hub`, `/logs`, `/community` and their mutations are new (viewers read, admins change,
  every change is in the audit log). **The Traefik bouncer plugin is covered end to end**: the page reads Traefik's own files (plugin declared with its version, middleware file,
`traefik-chain`, the key, when Traefik last asked, the mode) and raises what is wrong with a fix button (also on the dashboard card); its mode, timings, log level, the status
a banned visitor sees and the trusted networks are settings (written to the middleware file with a marker, atomically, kept across a re-registration and following the home
address); `GET /routes` says for every route, VMs' routes included, whether the bouncer checks it, and a route that bypasses the chain reads as unprotected. `tests/mock-crowdsec.py` is a stateful stand-in for `docker` and `cscli` that the smoke tests and browser labs run against.

### Changed

- **DCS Orchestrator is the name wherever DCS speaks.** The banners and `--help` of the scripts, the API's name (`GET /`), the default
  server subtitle, the systemd units' Documentation line, SECURITY.md, the setup hints and the templates' comments say DCS Orchestrator,
  and the repository links use `dcs-orchestrator`. The install directory `~/.Docker-Compose-Skeleton-AIO` keeps its name (the VMs a hub
  builds and the updater use it), and so does the dashboard's container image until it is published under both names.
- **Sixteen settings that nothing read are gone.** `SCHEDULER_ENABLED`, `HEALTH_SCORE_ENABLED`, `MAX_PARALLEL_OPERATIONS`,
  `INCLUDE_RESOURCE_METRICS`, `DOCKER_TIMEOUT`, `STACK_START_TIMEOUT`, `FORCE_RECREATE`, `REMOVE_ORPHANED_CONTAINERS`, `COLOR_THEME`,
  `LOG_DATE_FORMAT`, `ENABLE_MILLISECONDS`, `ENABLE_LOG_MOOD`, `ENABLE_LOG_PID`, `ENABLE_LOG_HOSTNAME`, `LOG_MAX_SIZE` and
  `LOG_RETENTION_DAYS` were in `.env.example`, the schema, `settings.cfg` and the Config page, and switching them did nothing (their
  defaults did not even agree). They are not offered any more; a `.env` that still has them keeps working, and `POST /config` accepts and
  ignores them so an older dashboard can still save.
- **A release candidate runs its own dashboard.** `Stacks/core-infrastructure/docker-compose.yml` names the dashboard image, and while `VERSION`
  is a release candidate (`X.Y.Z-rc.N`) it pins that tag; a release says `:latest`. The dashboard's update check and its update read the
  image from that file, so a hub (or a hub VM image) made from a release candidate shows the dashboard of the same version, and `tests/lint.sh`
  keeps the tag and `VERSION` in step.
- **`sudo` in the web terminal can write `/usr` and `/etc`.** The API service no longer sets `ProtectSystem=full` (it made both read-only
  for everything the service starts, sudo included, so `sudo apt install` failed with "Read-only file system"). `PrivateTmp` and the
  kernel and cgroup protections stay, and the OS and Docker Engine updates still run through `systemd-run`. Units installed before are
  rewritten the next time an update changes `install-service.sh`. Lint keeps the line out.
- **CI runs on Ubuntu 24.04 and 26.04** (what `ubuntu-latest` becomes on October 19, 2026) with Node 24 actions, checks the
  first-boot script and the boot menu writer of the VM images, and a new workflow (its matrix comes from `images.json`) builds all
  eight images, boots each on BIOS and UEFI under KVM and, on a version tag, attaches them to the release with `SHA256SUMS`,
  `images.json` and `dcs-proxmox.sh`. A provisioning check that looked at
  a stack before its VM had started it (one red run in twenty) now waits for it.
- **The heartbeat answers in about 30 ms instead of 70.** `GET /ping` is answered before the ~26,000 lines of handlers are
  parsed (they were about 85 of every request's 105 ms), with the same response function, so the headers are the ones every
  answer carries. A server with an IP allow-list or in setup mode, and every other route, takes the normal path. A heartbeat
  is no longer written to the access log or counted. `DCS_NO_FAST_PING=1` turns it off.

### Fixed

- **The Health page read "Disk 0%" on a VM or an LXC.** `GET /system/metrics` and `GET /disks` left the root file system out, which is
  all a VM has; they report it when there is no other.
- **A fresh or rebooted server was a C or a B for days.** The uptime factor of the system health score is a step now (a day 100, an
  hour 90, ten minutes 75), not a ramp over seven days.
- **`api-server.sh --stop` could not stop a listener started with a relative path** (`.scripts/api-server.sh --bind …`, as CLAUDE.md
  shows): it called the process foreign and left it running.
- **`docker inspect` of a missing container** printed an empty line first on Docker 29, so `setup.sh` took a fresh machine for one
  with an earlier install ("Containers from an earlier install", `--force-recreate`); `status.sh` and the API's alert check had the same fallback.
- **The hub's own VM card said "No DCS linked".** It says *This hub* now.
- **A stopped Docker no longer reads as "All Systems Healthy".** `docker ps` failing (the daemon stopped, the socket
  refused) was taken for an empty container list, so a host with no Docker at all scored 100/A. `GET /health` now says
  `critical` with `docker: {reachable: false, error}`, `GET /health/score` puts the stacks at 0 and caps the total at
  39 (F), and the fleet views do the same for every VM whose Docker does not answer.
- **A VM that does not answer is no longer left out of the fleet's verdict.** `GET /health?fleet=1` counts it as
  `unreachable` and reports at least `degraded`; the fleet score is capped when a reachable VM has no Docker.
- **An engine or OS update started from the dashboard could not finish.** Two things ended it. The API service runs with
  `ProtectSystem=full`, which makes `/usr` and `/etc` read-only for everything it starts, sudo included, so no package file could be
  installed. And the service *required* Docker: an engine update restarts Docker, systemd restarted the API with it, the job died with
  the service and its status read "running" for good (every later update was refused with 409). Both updates start through
  `systemd-run` now (the manager's own namespace and cgroup), the API unit *wants* Docker (a stopped Docker is something the API has to
  be up to report), Arch restarts Docker only when its packages changed, and an update whose job is gone reads "failed" with what is
  known instead of "running". Tested with a real upgrade in an Arch VM.
- **An Arch node could not be built.** The member bootstrap used `sg`, which Arch does not have, and stopped at "Docker Compose is not
  available"; it uses `newgrp` there. Arch's minimal image has no `hostname` command either, so a member reported an empty host name:
  every script reads the name from `uname -n` (the API from `/proc`) and the first address from `ip`.
- **The Cron Jobs page listed "command not found" as a job** on a machine without cron, which is every DCS VM image. It shows an empty
  list. `maintenance.sh` no longer needs `bc` to print sizes.
- **Checking for OS updates on Arch left the system's package databases newer than the packages.** The check ran `pacman -Sy` on its
  own, which Arch does not support (the next `pacman -S` is then a partial upgrade). It asks a private copy of the databases now, like the
  Docker Engine lookup, and the version it lists is the new one (it read the arrow).
- **A VM with running containers took 90 s to power off.** The images keep Docker's `live-restore` on, so stopping Docker leaves the
  containers to systemd, which sends SIGTERM and waits 90 s for one that ignores it (`sleep infinity`, `tail -f`, a shell as PID 1).
  `dcs-container-stop.service` stops them first, the way `docker stop` does: ten seconds at most.
- **A dashboard on another origin got a CORS error from a cached answer.** The response cache kept the headers of the request that
  filled it, `Access-Control-Allow-Origin` included, and served them to whoever asked next. The cache now drops the stored CORS
  lines and writes the ones for the request it answers.
- **A container whose health check failed was listed as healthy.** `Up 2 hours (unhealthy)` contains "healthy", and that test came
  first. "Unhealthy" is looked for first now. The uptime of a container is counted from when it started (`Up 3 hours`), not from when it was created.
- **Two sign-ins at the same moment could lose a session.** Every change to `tokens.json` (storing a token, the clean-up of expired ones,
  revoking a user's tokens) takes the same lock now; before, two requests could each read the file and one write undid the other.

## [3.9.9] - 2026-09-29

### Fixed

- **The Update button could leave the API dead on Fedora (SELinux enforcing).** Three things had to go wrong, and did:
  1. *The label.* git writes `api-server.sh` anew on an update and the file takes the directory's label (`user_home_t`);
     systemd cannot start a service from that (`203/EXEC`, "Permission denied"). The unattended update and the code
     bundle put `bin_t` back afterwards, the Update button and a rollback did not. Every code switch now does, the API
     does it first thing at start, and the service units (`dcs-api`, `dcs-stacks`) restore it before every start
     (`ExecStartPre`, after `install-service.sh` has run once more) — also after a `git pull` by hand.
  2. *A helper holding the port.* With the `ncat` transport (hosts without `socat`) every request handler inherited the
     listening socket, so anything a request left running — the DDNS loop that the wizard or a settings change starts,
     its 300 s `sleep` — kept port 9876 bound after the listener was gone. The API re-executed after the update, found
     "port 9876 is already in use by PID …: sleep 300" and quit; systemd then tried to start it and met the label.
     Handlers now close every descriptor but the connection; the DDNS loop is stopped through its pid file when the
     listener stops and its sleeps end with it; and a listener that starts on a port still held by what the previous one
     left behind (a shell utility in its own service) ends those helpers instead of giving up.
  3. *A loop that died silently.* The DDNS loop started by the server itself inherited `set -e`: one failed request to
     Cloudflare during boot ended it without a word. It retries now, as its own comment says.
- **"Recreate containers" recreated nothing.** The containers to recreate were found with
  `docker ps --filter ancestor=<image>` *after* the pull, and that filter follows the tag to the image it points to now —
  it lists the containers already on the new image and never the ones left on the old one. Every update reported success
  with `containers_restarted: []`, the registry check then said "Latest", and the containers stayed on the old copy until a
  stack was started by hand. Containers are now found by the image they were created from (`nginx`, `library/nginx` and
  `nginx:latest` are one) and by the image they run, so an update recreates exactly those on an older copy — also when an
  earlier run only pulled or ran on an older version. `GET /images/check-updates` lists them per image
  (`containers_outdated`), `POST /images/update` recreates them, and the Updates page shows them ("old copy" chips, a
  "Recreate" button and a banner).
- **An update was held back because `setup.sh` had made a script executable.** Setup runs `chmod +x` over every script; two
  libraries (`.lib/envfile.sh`, `.lib/setup-checks.sh`) are tracked as 644, so every install that had run setup listed them
  as edited framework files. The first release to change one of them would be refused ("local changes to framework files
  would be overwritten", 409), the unattended update would wait for consent about edits nobody had made, and the Updates
  page showed them as "edited on this server". A file whose only difference is the executable bit is no longer a local
  change: the update check leaves it out, the update goes through and sets the bit again afterwards. A real edit to the
  same file is still caught.

### Added

- **Automatic image updates.** A new schedule action `image-update` (target empty: pull and recreate, `pull`: pull only)
  starts a detached job that pulls the image of every running container and recreates those on an older copy, with a lock,
  a log (`logs/image-update.log`), a line in the Updates page's unattended list and a notification when something changed
  or failed. The Updates page has a dropdown for it (off, every night, every Sunday, the 1st of the month, at 03:00) for
  the servers its "Images on" chips select — everywhere, the hub, or one VM.

## [3.9.8] - 2026-09-29

### Fixed

- **A VM request that was refused halfway left the first stacks queued.** `POST /fleet/provision`
  checked and queued one stack at a time, so a refusal on the third (a guest on Proxmox already
  carrying its name, a stack that runs on the hub) returned an error with the first two already on
  disk. They blocked every retry ("a VM for … is already queued") and were picked up the next time
  any build started the runner. The whole request is now checked first and queued afterwards; a
  refused request leaves nothing behind. A stack listed twice, or one address given to two VMs, is
  refused as well (409).

- **Deploying a template into a VM with "Protect with Authelia" failed** ("Protecting a route needs
  Authelia: deploy the Authelia template first"): the choice was forwarded to the VM, which has no
  Authelia. Authelia and Traefik are the hub's — its Traefik serves the VM's routes — so the hub now
  keeps the choice (which routes of which VM sit behind its Authelia, `.data/fleet-auth.json`), applies it
  whenever it writes the VM's routes, and sends the VM a plain deploy. A template that brings its own
  clients stays open by default, as before. Start on demand is the hub's too (Sablier wakes the hub's
  containers only): asking for it on a VM stack is refused with that reason, and the deploy sheet does not
  offer it for one.
- **The Stacks card said 18 while 9 were running.** The hub's stack count added the stack folders left
  behind on the hub by stacks that moved into VMs (10 folders) to the VMs' own stacks (8): those stacks
  counted twice. `GET /status` no longer counts a folder whose stack a VM runs; a stack the hub runs
  itself (in `DOCKER_STACKS`, or with containers up) always counts.
- **A stack removed on the wizard's stack page came back as "stopped".** Setup only dropped it from the
  managed list and kept the folder (the repository ships one per stack). The wizard sends the stacks
  the person removed (`remove_stacks` in `POST /setup/configure`) and the folders go, like Delete on the
  Stacks page — unless containers run from one or its App-Data holds data, which is kept and reported.

### Added

- `GET /fleet/provision/defaults` lists the guests Proxmox already has (`guests`: name, VMID, type,
  node, state; templates apart) and the stacks with containers up on this server (`running_stacks`).
  The setup wizard (UI 3.9.9) marks a stack whose name is taken — "VM 101 exists" — leaves just that
  one out of the build with a note and builds the rest, and locks the stacks that already run on the
  hub (a build used to refuse them at the very end, after everything else was set up).
- Smoke suite 1052: a refused request queues nothing (later stack refused, stack listed twice, one
  address for two VMs), the guests in the defaults, a VM deploy's Authelia choice (kept, applied, cleared,
  refused without Authelia), the stack count with a leftover folder, and the wizard's removed stacks.

## [3.9.7] - 2026-09-29

### Fixed

- **Linking Proxmox during setup failed on `http://`.** `http://192.168.2.12:8006/` ended in
  "Proxmox did not answer (HTTP 301)": on 8006 Proxmox answers plain HTTP with a redirect and
  nothing else. Setup now takes the address any way it is typed: https for http (and any
  redirect followed), `:8006` added when no port is given, a path or the `#…` of an address
  pasted from the browser dropped. The dashboard's Proxmox forms (the wizard, Server Config →
  Proxmox) clean the address the same way before they test or save it.
- **The token secret prompt showed nothing** while typing or pasting, so it looked as if it
  took no input. It now prints a `*` for every character (Backspace and Ctrl-U edit; paste marks
  and arrow keys are ignored), checks that the text is a Proxmox secret (the UUID shown when the
  token is made) and says how many characters it received. The token ID is checked as well
  (`user@realm!name`), and `user@realm!name=secret` pasted in one go fills both.
- **A refused token or a wrong address is asked again** (three rounds; an empty line skips)
  instead of setup giving up, with the reason: the token refused, nothing listening (with
  curl's reason), or something that is not Proxmox.
- **A fresh server no longer runs every step and then stops on "Docker daemon is not running
  or not accessible".** Setup checks Docker first and offers the fix: start it now and at boot
  (`systemctl enable --now docker`), add the user to the docker group — and carries on in the
  same run under the new group, without logging out. Missing jq, socat or curl are named and
  offered for install with the system's package manager. When Docker still needs a hand, setup
  says to run `./setup.sh` again (`./start.sh` does not finish a first setup).
- **The wizard did not know it was on the hub.** Choosing *Hub* in `./setup.sh` and linking
  Proxmox there left the wizard blank and acting like a standalone server. Setup now records the
  role (`FLEET_ROLE` in `.env`) and the API reports it with the saved link (`GET /setup/defaults`
  → `system.fleet_role`, `system.proxmox.linked`). The wizard (UI 3.9.8) opens the Proxmox section
  as the hub's, fills in the link setup saved once you are signed in (the secret stays on the
  server: leave its field empty to keep it), tests it by itself, and the stacks start out as VMs;
  *Join a DCS hub* no longer shows on a hub. A factory reset keeps the role (credentials still go).
- **A VM build stopped at *Install* with "could not fetch the DCS bundle from the hub".** firewalld
  on a Fedora hub blocks port 9876, which every new VM fetches DCS from and joins on. The
  bootstrap now asks the hub first and stops at once with the fix; the hub names its firewall in
  the failure; the wizard and *New VM* warn before a build, with the command to copy
  (`GET /fleet/provision/defaults` → `hub_firewall`: firewalld answers port queries only to
  root, so a plain user's check reads the zone as Fedora ships it and says "unless opened by hand").
- **The wizard offered the docker group as PGID** after `newgrp docker` (and setup gave the files
  to that group): both now use the account's own group.
- **CrowdSec would not deploy on an SELinux system** ("invalid spec: …/var/log/traefik:ro,z:z: too
  many colons"): the step that adds `:z` to a template's volumes only recognised `:z`, so the
  template's own `:ro,z` got a second one. It also added `:z` to host paths — `/` (Duplicati, the
  Prometheus exporters), `/var/log`, `/var/lib/docker`, device nodes — which a Docker that labels
  would relabel for containers, taking them from the host. Only the stack's own folders (`./…`,
  `../…`, or under an absolute `APP_DATA_DIR`) are labelled now, `z` or `Z` anywhere in the options
  counts, and host paths, named volumes and quoted lines stay as written (`_selinux_label_volumes`).
- **A reinstall kept showing the old wizard**: setup started the dashboard image the machine
  already had (or left an old DCS-UI running). It now fetches the current image every time and
  restarts DCS-UI only when that image is newer; a first setup that finds the dashboard or its
  Redis from an earlier install — a folder deleted under running containers leaves them on
  mounts that are gone ("unhealthy") — starts the core infrastructure anew.
- **Building the VMs refused networking-security** ("runs on this server (the hub): its containers
  are still up here"): the wizard had just deployed Traefik, Authelia and CrowdSec into it on the
  hub, then asked for it as a VM. The stacks the wizard deploys into — the proxy stack when Traefik
  is on, the self-hosted ntfy's stack, core-infrastructure — stay on the hub (UI 3.9.8: the VM
  switch is locked there, with the reason); the hub's Traefik serves every VM's routes anyway.

### Added

- **Sizing a VM** (UI 3.9.8): *Small*, *Medium*, *Large* and *X-Large*, and a − / + stepper for
  cores, memory and disk that walks through the usual sizes (the number can still be typed) —
  instead of three tiny number boxes. Nothing goes past the Proxmox node (`capacity` in
  `GET /fleet/provision/defaults`) or below a 10 GB disk, and the wizard sets the plan's totals
  against the node's cores and memory.
- **The token's privileges are checked when the link is made**: a token that works but lacks
  `VM.Audit`, `VM.PowerMgmt` or `Sys.Audit` on `/` (Privilege Separation ticked and no role for
  the token itself) is named right away, with the fix.
- **Fedora and friends set up by hand** (the VMs a hub builds get this from their bootstrap):
  a hub or member offers to open the API port in firewalld, since the hub and its VMs talk on
  it; Docker that confines containers with SELinux (Fedora's own Docker package, not Docker CE)
  is noticed — under it a container may not write its App-Data folder, nor Traefik read the
  Docker socket — and setup offers to run containers the way Docker CE does (SELinux stays on
  for the rest of the system); the first setup offers the boot service
  (`.scripts/install-service.sh`), so DCS comes back after a reboot.
- Smoke suite: the setup checks against a stand-in that answers like Proxmox on 8006 (HTTPS
  with a self-signed certificate, plain HTTP redirected), the secret prompt through a pty, the
  API's address clean-up, the role and the link in the setup answer, the hub's firewall through
  firewalld stand-ins, and a factory reset that keeps the role.

## [3.9.6] - 2026-09-29

### Fixed

- **Applying a theme turned the app into a 404** on a server whose Traefik already declared
  theme.park under its own name ("theme-park"): DCS saw the plugin declared and wrote its
  middleware as `plugin: themepark`, which that Traefik does not know — it refused the
  middleware and disabled the whole router, so Plex, Sonarr and the rest answered "404 page not
  found" until the theme was removed. DCS now reads the name Traefik knows each plugin by from
  its static config (`moduleName`/`modulename` in any case) and uses it for theme.park,
  Sablier and the CrowdSec bouncer, on the hub's own routes and on the VM routes it serves.
- **Every theme change is checked through Traefik**: the route is asked before and after
  (Traefik reloads its files within two seconds); a change that turns it into a 404 is undone
  exactly — the files as they were — and the dashboard says why. A plugin declared after
  Traefik started gets one restart first. A theme can no longer leave an app down.
- **The theme files 3.9.5 wrote are repaired** when the API starts (in the background) and
  before every theme change: a DCS theme file whose route answers 404 under an old plugin name
  gets the declared one, kept only when the route answers again; a route that works is left as
  it is, and a user's own files are never touched.
- **Themes written by hand are recognised**: a theme.park middleware in the route (a
  `sonarr-dark` with `theme-park: {app, theme, addons}`) shows as the container's current
  theme, "from your route"; applying a theme from DCS takes its place on that route (its
  definition stays in the file) instead of stacking a second theme on top.
- A Traefik plugin is never declared a second time under another name (a duplicate key would
  stop Traefik from starting).

## [3.9.5] - 2026-09-29

### Added

- **Add to Homarr from the Containers page.** A container's page shows, under its health
  badge, **Add to Homarr** when it is not on the dashboard yet and **✓ Added** when it is —
  the same registration the deploy sheet's switch makes: the app with its template's name and
  icon at its HTTPS route (or a published port), plus a tile on the home board when Homarr's
  API key is stored (the app library without it). `GET/POST /containers/{name}/homarr`; on a
  hub a VM's container is added to the hub's Homarr (`?member=`: the address from the VM, a
  host the hub renamed for a twin used; a VM on an older DCS answers from its routes).
- **theme.park themes for the apps that support them.** A **Theme** button next to Start on
  demand, for the 54 apps theme.park themes (Sonarr, Radarr, Prowlarr, Lidarr, Bazarr,
  qBittorrent, Plex, Jellyfin, Tautulli, Overseerr, Uptime Kuma, Portainer, Dozzle…): the 11
  official themes, the 30 community ones (Catppuccin, Rose Pine, Blackberry…) and the app's
  add-ons (4K logos, darker…). DCS writes the theme.park Traefik middleware onto the
  container's route, last in its chain, and declares the plugin in Traefik's static config
  when it is missing (one Traefik restart); nothing inside the container changes and taking it
  off is instant. On a hub a VM's container is themed by the hub's Traefik, which serves the
  VM's routes: the hub keeps the choice (`.data/fleet-themes.json`) and adds the middleware
  when it writes the VM routes. `GET/POST /containers/{name}/theme`; the catalogue comes from
  theme-park.dev once a day, with a copy shipped for servers that cannot reach it.
- A VM's container rows carry `member_host`, the VM's address: Diagnostics' port map opens a
  VM's published port on the VM (it opened the hub's address) and says which VM it is.

### Fixed

- **Serving a container normally again left Sablier's session behind**: Sablier stopped the
  container when the session ran out although the middleware was gone (Homarr went down on
  the lab 15 minutes after an on-demand test). Switching on-demand off now drops the
  container's session (Sablier saves its sessions on a graceful stop; the entry is removed and
  Sablier started again) and starts the container when it was asleep.
- `GET /homarr/status` said "without an API key" when Homarr was merely stopped; it says
  stopped now, and a container's Homarr card only counts a running Homarr.
- Start on demand is no longer offered for a VM's containers: the hub's Traefik serves a VM's
  routes and Sablier cannot wake a container in a VM from there.
- Lists that keyed rows by a bare container or stack name on a hub (Diagnostics' health
  matrix and port map, the stack list, the deploy sheet's stack picker) key them by VM and
  name: two VMs running a "Homepage" each dropped one of them.
- The API reference names the plugin card path's parameters.

## [3.9.4] - 2026-09-28

### Added

- **On-demand settings on the Containers page.** The Start on demand button opens a dialog with
  the same choices as the deploy sheet — how long a container may idle before Sablier stops
  it, the waiting page (ghost, shuffle, hacker-terminal, matrix), the name shown there and
  whether details show — and when a container already starts on demand the same button
  brings the settings back to change them or to serve it normally again.
  `GET /containers/{name}/sablier` answers the current settings (read from the Sablier
  middleware on its route, wherever a deploy put it) and whether Traefik routes the container
  and Sablier is deployed; `POST /containers/{name}/sablier` takes `show_details` too, and a
  block a template deploy wrote into the route file is rewritten with the new settings (and
  removed on disable) instead of being doubled. The middleware now goes last in the router's
  list, after the chain and Authelia, so a visitor is checked before the container is woken.

### Fixed

- **Sablier deployed from the template never started.** It mounted `sablier.yml` and
  `state.json` from App-Data, which a fresh deploy does not have, so Docker made folders there
  and Sablier stopped with "is a directory" on every start. It takes its settings as flags now
  and keeps its state in a folder (`App-Data/Sablier/data`); proven on the lab end to end — a
  request to a sleeping container gets the waiting page, the container starts, and Traefik
  serves it a few seconds later.
- **File Browser kept its users and settings in anonymous volumes.** The current image reads
  `/config` and `/database`, so the template's `/.filebrowser.json` and `/database.db` mounts
  were ignored and a recreate lost everything. It mounts `config`, `database` and `data`
  folders under App-Data and runs as the stack's user. A File Browser deployed before keeps
  its old volumes until it is redeployed.
- **Dashy started without a configuration** (a folder in place of `conf.yml`); the template
  ships a starter `config.yml`.
- **Every deploy now makes its App-Data mounts before the containers start** — folders owned
  by the DCS user instead of root, and a mount that names a file (it has an extension) as an
  empty file, replacing an empty folder an earlier failed start left there. Templates imported
  from elsewhere get the same protection.
- The API lets browsers remember a CORS preflight for ten minutes: a dashboard on another
  origin sent an OPTIONS request before nearly every call.

## [3.9.3] - 2026-09-28

### Added

- **A shell inside a VM, from the hub.** The Terminal page gets the Hub / VM chips: the hub's
  own Terminal session (its Linux credentials) unlocks a shell in every VM the hub built, the
  command travels over the hub's ssh key (`GET /fleet/members/{id}/terminal` says whether it
  can, `POST /fleet/members/{id}/terminal/exec {terminal_token, command, cwd?}` runs it) with
  the same command guard, rate limit, 60 s limit and audit log as the host terminal. Each server
  keeps its own working directory; the prompt says where a command ran.
- **The Maintenance page asks the hub once.** `GET /maintenance/report`, `/orphans` and
  `/disk` take `?fleet=1` on a hub: the hub asks every VM at the same time and answers the
  merged picture (numbers and sizes added up, rows tagged `member`, `member_name`, `vmid`,
  `members[]` per DCS), cached 30 s — one request instead of three per server. A dashboard
  on an older hub keeps asking each server itself.

### Fixed

- **Templates load fast again — and so does every large answer.** The "empty answer" guard
  on every success answer stripped the blanks out of the whole body with a bash substitution,
  which is quadratic: five seconds of CPU for the 120 KB templates list (the page had grown
  slower with every template added — 151 since 3.9.0), and seconds on every cache miss of a
  hub's `/containers`, `/images` or `/routes`. It is a regex search for one non-blank character
  now (a millisecond). The catalogue is also read with one jq run instead of one per template,
  and the list is cached for a minute (any template write clears it).
- Dashboard cards that listed stacks or containers by bare name (Stack Status, Stack Controls,
  Container Overview, Spotlight, Quick Actions) key their rows by where they live too, so a
  hub whose VMs run same-named stacks or containers renders every row; Quick Actions says
  which VM a choice belongs to.

## [3.9.2] - 2026-09-27

### Added

- **Themes.** A theme is a small document (palette of a dozen colours, dark or light, optional
  font, corner radius and extra CSS) that every dashboard can follow: stored on the server
  (`GET/POST /themes`, `GET/DELETE /themes/{name}`, `POST /themes/import {url}`,
  `PUT /themes/active {name}`), made in the dashboard's Theme Studio with a live preview,
  exported as a file, installed from a file or an https address, and set for everyone by an
  admin. CSS that loads or runs anything is cut out and reported. Eight built-in themes ship
  with the dashboard (Nord, Dracula, Catppuccin, Solarized, Gruvbox, two light ones and the
  default look).
- **Live Events for the fleet.** `GET /stream?fleet=1` on a hub carries every VM's docker
  events next to its own (each with `member`, `member_name`, `vmid`); `?member=id` one VM's.
  The Live Events page has the Everywhere / Hub / VM chips and a capsule per event.
- **Every remaining page works with the VMs.** Containers (the hub's `GET /containers` already lists every VM's, tagged; every
  button — start, stop, restart, recreate, remove, env, exec, logs, Sablier, Nuke & reinstall —
  on the VM the container lives in), Logs, Uptime, Topology, Backup & Restore
  (`GET /backups?fleet=1`; the stack list shows where each stack lives, a backup runs on that
  VM, restores go to the archive's own server, *Back up everything* covers the hub and every VM),
  File Browser, Environment, System (OS updates on a hub-built VM need no password) and
  Maintenance (numbers add up, actions run everywhere or on one VM).
- **Homarr made whole.** `POST /homarr/key {key}` checks the key against Homarr and stores it;
  `DELETE /homarr/key`; `POST /homarr/sync` registers every routed service (the hub's and the
  VMs') that Homarr does not have yet; `GET /homarr/status` says which mode applies (tiles on
  the home board, library only, not deployed) and how to get a key. A settings panel drives it.
- **Proxmox guest cards** are one shape with equal heights per row: the same slots for every
  guest, containers collapsed to a summary line that expands in place, actions pinned to the
  bottom.

### Changed

- **The memory balloon floor is three quarters of a VM's memory** (at most 512 MB can be taken
  back): half turned out too low — under host pressure a 1.5 GB VM was squeezed to 768 MB, its
  Java app was killed and its API stalled. Existing VMs: *Enable ballooning* again in the VM's
  sheet, or `qm set <vmid> --balloon <three quarters>`.
- The Docker Engine card answers at once: the package source's newest version is asked in the
  background (dnf could take twenty seconds and the card sat on its skeleton), the card shows
  "asking the package source" until it is known, and a dashboard newer than its server explains
  that the framework must be updated first.

### Security

- A member can no longer attract a container request by naming a container it does not own:
  the hub forwards `/containers/{name}/…` only to the member whose recorded placements include
  the container's stack, and to nobody when two members name it (pin one with `?member=`).

## [3.9.1] - 2026-09-27

### Added

- **Routes to the VMs through the hub's own Traefik.** The hub writes the members' routes into
  its Traefik's `custom_routes/fleet-members.yml` (file provider, watched) from the metrics loop,
  only when they change, and removes the file when no VM offers a route (audit `fleet_routes`).
  Every VM router gets the hub's middleware chain (CrowdSec, headers, compression, Authelia), a
  new route gets its Cloudflare record and its Homarr tile from the hub, and a Traefik that runs
  inside a VM receives everyone else's routes from the hub (`POST /fleet/routes`).
- **One domain for the fleet.** The hub hands its proxy domain to every member: at build time
  (`DCS_PROXY_DOMAIN`), with the join answer, or from the loop for older members
  (`POST /fleet/hub/domain`). A member with a domain of its own keeps it.
- **Routes for what was deployed before.** When the domain arrives (or by hand,
  `POST /traefik/routes/rebuild {stack?}`), every service that publishes a port and exists as a
  container gets the route a fresh deploy would have written.
- **Authelia protects by default.** With Authelia deployed, routes written by a deploy, the
  rebuild and the hub (for the VMs) carry its forward-auth middleware, except for templates
  whose apps bring their own clients (`"auth": "bypass"` — Plex, Jellyfin, Nextcloud, Immich,
  Vaultwarden, ntfy, Gitea, MinIO, the *arr apps, …) and for what the deploy sheet switches off;
  routes written before Authelia go behind it when it is deployed (audit `authelia_routes`).
  The deploy sheet defaults its switches accordingly and always sends its choice.
- **Template defaults on every deploy.** A deploy without `variables` (the API, an automation,
  a hub deploying into a VM) fills them from `template.json` like the wizard does — no more
  `:3000` published on a random port. Homepage's allowed hosts default to `*` behind Traefik.
- **Docker Engine card** on the Updates page: version, package source (Docker's, Debian's,
  Fedora's), the newest version that source offers, the AppArmor/`docker.io` problem called
  out, a one-click update (unattended with passwordless sudo, otherwise with the Linux account
  like the OS updates) and, on a hub, every VM's engine with *Update N VMs*
  (`GET /system/docker-engine`, `POST /system/docker-engine/update`, `…/status`,
  `POST /fleet/docker-engine/update`).
- **Real memory numbers for VMs.** VMs the hub builds get a memory balloon (the guest keeps
  three quarters), so Proxmox reports the guest's usage instead of the host's view of the whole
  allocation and can take idle memory back; `POST /proxmox/vms/{node}/qemu/{vmid}/balloon`
  retrofits an older VM (reboot to take effect) and the VM detail carries `balloon` and the
  guest's memory figures.
- **The setup wizard** lists Authelia and CrowdSec in its review, keeps its results on screen
  when a step failed, and says what Authelia does to later deploys.
- **Cloudflare and dynamic DNS are tested**: `tests/mock-cloudflare.py` stands in for the API
  (`CF_API_BASE`, `DDNS_IP_URLS`, `DDNS_ONCE` for tests); the smoke covers the CNAME a routed
  service gets, the A records that follow the public address, and the CNAME left to routing.

### Fixed

- The dashboard container stayed unhealthy on hosts with Debian's own `docker.io` 26 and
  AppArmor 4.1 (Debian 13, Proxmox hosts): nginx could not create its worker sockets. `setup.sh`
  now detects that pairing and sets `DCS_UI_APPARMOR=unconfined` in the core stack's `.env`; the
  dashboard service carries `security_opt: apparmor=${DCS_UI_APPARMOR:-docker-default}`.
- `POST /proxmox/test` without `verify_tls` kept the saved choice instead of turning verification
  on, which made the link panel fail against a self-signed Proxmox.
- A member takes code only from its own hub (`POST /fleet/self-update` refuses other hosts).
- The smoke's fleet score check no longer assumes containers exist (the CI runner has none).

### Fixed

- **A Fedora (SELinux enforcing) member did not come back after a reboot that followed an
  update round**: the bundle replaced `api-server.sh`, the new file took the home directory's
  label and systemd refused to execute it (`203/EXEC`). Both update paths now put the
  installer's `bin_t` label back (`restorecon`, else `chcon`), hub-built Fedora VMs get
  `policycoreutils-python-utils` so the rule is persistent, and the audit says
  `selinux_relabel` when it had to.

### Security

Hardening of the hub↔member protocol after an audit. A member is another machine, and everything
it sends is data now.

- A member could push any router into the hub's Traefik feed and its `fleet-members.yml` — the
  hub's own hostnames included, a `priority` to win over them, servers pointing anywhere. Every
  member router and service is now rebuilt from a whitelist; a route for one of the hub's own hosts
  is refused, servers may point at the member's own address only, a hostname two members offer goes
  to the first in the fleet list (the other is renamed `<sub>-<member-id>.<domain>`), and
  `GET /traefik/feed/status` lists what was refused or renamed and why (`member_skipped`).
- An update round handed every member a live join code (good for an hour) that could enrol any
  machine. Each member now gets a bundle code of its own, tagged with its purpose and the member,
  revoked the moment the member's call returns (and on the way out however the round ends); such a
  code opens the bundle for that member and can never join. The member fetches the bundle from its
  own record of the hub's address (`token`), which also fixes members joined by name, over HTTPS or
  on another interface getting 403 on the bundle; `bundle_url` is still sent for 3.9.0 members.
- A member could claim any stack (at join, or by listing it in its `/stacks` answer) and receive
  the admin requests the hub forwards for it. Placements now come only from the build that moved
  the stack in, from an admin (`PUT /fleet/members/{id}` with `stacks`), and at join only for names
  the hub has no `Stacks/` folder for; the overview no longer writes what a member runs back as
  placements (it shows `placements` next to `stacks`, and `GET /stacks` rows carry `placed`).
- `POST /fleet/relay` was public, unthrottled, and let a member's context pose as the hub. It now
  takes 30 events a minute per member (429 beyond), drops the keys the hub sets itself (`event`,
  `timestamp`, `hostname`, `vm`, `vmid`, `member`, `relayed`) and the ones that steer a
  notification's cooldown (`fingerprint`, `mount`, `automation`, `template`), and cuts values to
  120 characters in the activity line.
- A member could make the hub read an answer of any size. The hub stops at 8 MB ("answer larger
  than 8 MB") and gives up on a connection after 2 s.
- A member's answer of the wrong shape (`{"networks": "nope"}`, a string where an object was due)
  could break a merged list, the fleet health and score, the images list, the engine card, or end
  an update round. Every merged field is typed before it is counted, a malformed answer counts as
  that member failing, an empty handler answer is a 500 (`empty answer`) instead of a blank 200,
  and the response cache never keeps an empty body.
- Two hubs that joined each other relayed every event back and forth without end. A relayed event
  is marked (`relayed=1`) and never relayed again; a server refuses to join one of its own members
  as hub, and a hub refuses its own hub as a member.
- The hub's metrics loop waited on every member each tick, so a stalled member froze the samples.
  The fleet work now runs in the background under a lock (`.data/fleet-loop.lock`, taken over after
  ten minutes), and a member known to be down is probed with a 3 s `/ping` before any login.
- A member's name went unchecked into audit lines, notifications and ntfy headers. Names are cleaned
  when a member registers or is edited (control characters out, 64 printable characters at most, 400
  otherwise), and ntfy header values never carry a line break.
- The code snapshot a self-update keeps was world-readable next to the configuration snapshots. It
  is written with `umask 077` into `.snapshots/code/` (the newest three kept), where `GET /snapshots`
  never lists it.
- `POST /fleet/update` held the request for the whole round and took unchecked ids. Ids are
  validated, the round runs detached (`.data/fleet-update-last.json` reads `running`, then `done`),
  and the answer is 202 `{running: true}` when the round outlasts 25 s — `GET /fleet/versions`
  (`last_round`) follows it.

## [3.9.0] - 2026-09-27

### Added

- **The VM is the stack.** On Proxmox, one DCS is the hub (the dashboard, the Proxmox link,
  `core-infrastructure`) and every other stack is a VM the hub builds and that runs exactly that
  stack. The wizard's Stacks step shows a *Hub / VM* switch per stack with cores, RAM and disk
  and a VM-settings panel prefilled from Proxmox and the hub's network; *Complete setup* hands
  the plan to the hub (`POST /fleet/provision`), which builds the VMs one after another in the
  background: image imported once (Proxmox downloads it, or the hub downloads and uploads when
  the token lacks `Sys.AccessNetwork`), `POST /nodes/{node}/qemu` with `import-from`, a cloud-init
  drive with a static address and the hub's own ssh key, boot, ssh, the bootstrap
  (`.scripts/fleet-bootstrap.sh`: network check, tools, Docker and Compose with fallbacks, the
  hub's own code from `GET /fleet/bundle?token=`, an unattended member setup, boot services), the
  join and a check. Every step is on a progress card in the wizard's success screen and on the
  Proxmox page (`GET /fleet/jobs`, retry from the failed step, dismiss); *New VM stack* builds one
  more; *Stop and destroy the VM* removes one (`DELETE /fleet/members/{id}?destroy=true`).
- **The fleet follows the hub's version.** On a hub the Updates page shows *The VMs* — every
  member with the DCS version it answers with (`GET /fleet/versions`) — and *Update all VMs*
  (`POST /fleet/update {members}`) hands each one the hub's own code: the member fetches the hub's
  bundle with a join code minted for the round (`POST /fleet/self-update`), keeps its `.env`,
  data, accounts, secrets, stacks and settings, saves the old code under `.snapshots`, records
  the update in its history and re-executes its API in place. A hub update with *Then update the
  VMs* ticked (`{fleet: true}`) queues the round for right after the hub's own restart; a member
  whose installer changed runs it again and restarts through systemd, so the unit follows. Image
  updates see the whole fleet: *Everywhere* lists every image on the hub and on each VM with
  where it runs (`GET /fleet/images`), *Check Registry* asks every DCS at once
  (`POST /fleet/images/check`), each pull goes to the DCS its row belongs to, and *Images on*
  narrows to the hub or one VM. Every card on the Updates page carries the same status line (up
  to date or not, checked when, last changed when); a VM's own page says *Updated by its hub*,
  a copy without git *Installed without git*, and a failed check shows the reason with a retry
  instead of an endless skeleton. Without members nothing changes.
- **Everything from the hub.** Every list page of a hub opens on *Everywhere* — the hub and every
  VM in one list, each row with a capsule saying where it lives — with chips for the hub alone or
  one VM, one choice shared by Health, Images, Updates, Networks, Volumes, Snapshots, Automations,
  Scheduled Tasks, Secrets and Activity (`?fleet=1` on the list endpoints merges the members' rows,
  tagged `member`, `member_name`, `vmid`). Changes happen on the hub or on one VM through the hub.
  A VM's events reach the hub with a relay token handed out at join (`POST /fleet/relay`): the hub
  notes them as `fleet_event` and its Discord/NTFY rules fire with the VM named, so the VMs need no
  channels of their own. *Create snapshot* on Everywhere snapshots the hub and every VM at once
  (`POST /snapshots/create?fleet=1`). The secrets a stack refers to travel with it into its VM.
  The Stacks entry reads *Stacks* again (the VMs are the stacks), with a calmer header (New stack
  → in its own VM or on the hub, a pill for builds in flight, the rest under *More*); builds and
  the baked DCS templates live on the Proxmox page.
- The service unit no longer sets `RestrictSUIDSGID`: under it systemd 259 (Fedora 44) answers
  tar's `openat2()` with ENOSYS, which broke code updates unpacked by the API.
- **The hub's API is the fleet API.** `GET /stacks` on a hub lists the members' stacks next to
  its own (`placement`, `member`, `vmid`, `reachable`), `GET /containers` every member's
  containers (`member`), and `/stacks/{name}/…`, `/containers/{name}/…` (`?member=` when a name
  is not unique) and template deploys whose target stack lives in a VM are forwarded to that
  VM's DCS with the caller's role checked on the hub, audited as `fleet_proxy`. The Stacks and
  Containers pages show a *VM* chip, the deploy dialog's stack list says which stacks are VMs,
  *Deploy here* on the Proxmox page preselects the VM's stack, the bot's `/stacks` marks them.
- **Unattended setup.** `DCS_UNATTENDED=true` with `DCS_ADMIN_USER`, `DCS_ADMIN_PASSWORD`,
  `DCS_STACKS`, `DCS_MEMBER_NAME`, `DCS_TZ`, `DCS_PUID`, `DCS_PGID`, `DCS_PROXY_DOMAIN`,
  `DCS_CF_DNS_API_TOKEN`, `DCS_API_PORT`, `DCS_API_BIND`; `DCS_NO_UI=true` for an API-only
  install; the role prompt (standalone, hub, member) and `DCS_FLEET_ROLE`, `DCS_HUB_URL`,
  `DCS_JOIN_TOKEN`, `DCS_PROXMOX_*` for the hub; `./setup.sh --join`; a join saved before the
  first admin runs in the wizard on the same card.
- **Members, join codes, scan, merged feed, watcher** (the substrate): `.data/fleet.json`
  members with a `dcs-hub` admin account per member (password in the hub's secret store, a
  service account exempt from the single-session rule), `POST /fleet/join` with 24 h codes,
  `/fleet/discover` (guest-agent and container addresses probed on `FLEET_SCAN_PORTS`), matching
  by SMBIOS uuid, address or name, `/fleet/members/{id}/api/*`, `/fleet/overview`, the hub's
  Traefik feed carrying every member's routes (`GET /fleet/feed`), `fleet_member_down` /
  `fleet_member_up` / `fleet_member_joined` / `fleet_vm_ready` / `fleet_vm_failed` events, the
  bot's `/fleet`, `GET /proxmox/capabilities` (what the token may do), `GET /proxmox/storage`,
  `FLEET_SELF_URL`, `FLEET_SCAN_PORTS`, `FLEET_IMAGE_URL`, `FLEET_VM_USER`.

- `DELETE /fleet/jobs/{id}?destroy=true` destroys the VM a failed build left behind; *Dismiss*
  on a failed job card asks. A stack whose name already exists as a guest on Proxmox is refused
  (link that guest, or rename it) so the hub never builds a twin.

### Fixed

- `--stop` only ends listeners that belong to this installation (matched by its own script
  path); another DCS on the same port is reported and left running. Every write to
  `.data/fleet.json` is atomic under a lock. `setup.sh` no longer aborts when a Proxmox probe
  times out. Proxmox's own message is shown on a 403 (which role is missing).
- `tests/mock-proxmox.py` serves storages, image import, VM creation, configuration, tasks and
  permissions, and `tests/smoke.sh` builds a VM end to end against it with an ssh stand-in that
  runs the real unattended setup (560 checks).
- **What counts as the hub's stack.** The hub took a `Stacks/<name>` folder as proof that it ran
  the stack — a fresh clone ships all ten, so every VM placement was refused and a VM's stack
  was shadowed by an empty folder. A stack is the hub's own when it is in `DOCKER_STACKS` or has
  containers up; a leftover folder never hides, blocks or captures the VM's stack.
- **Boot services on a built VM.** The service installer started `dcs-api.service` while the
  API instance setup.sh had launched still held the port, leaving the unit in a restart loop; it
  now hands over (stops that instance, starts the unit, waits for `/ping`) and never prompts
  when unattended. The bootstrap is copied to the VM and run with its input detached instead of
  piped into `bash -s`, where setup.sh could read the rest of the script as its own input.
- Proxmox `DELETE` calls carried their parameters in a body, which Proxmox answers with HTTP 501
  — *Stop and destroy the VM* failed; they go in the query string now.
- The wizard's success screen stayed on *Entering Dashboard…* for ever when the VM build was
  refused; it shows the reason and an *Open the dashboard* button.
- A bare `wait` in the hub's metrics loop made some bash versions print *not a child of this
  shell* without end (a 15 GB log in an hour); the fleet waits for its own children only.
- `install-service.sh` died under `pipefail` when `.env` had no `API_BIND`.
- The VM network the wizard proposes is read from the bridge when the hub sits on the Proxmox
  host itself (its `vmbr0` address, the host as gateway), and its DNS is never a local stub:
  `/etc/resolv.conf` unless it points at `127.*`, then systemd-resolved's upstream servers, then
  the router, then a public resolver.
- A member the hub built reports its SMBIOS uuid (root-only in sysfs; the bootstrap keeps a copy
  the API can read) so the hub matches it to its guest by uuid, not just by address, and says
  whether it serves a dashboard — the Proxmox page hides *Its dashboard* for API-only members
  and counts the hub's own stacks only (a member's stack is not "run here").
- The wizard refreshes the VM settings from the hub's defaults after another *Test connection*
  unless you edited them.
- **The VM is born as the stack.** A build has a *Stack* step: the hub's `Stacks/<name>` folder
  (compose, `.env`, config files — never `App-Data`, data or backups) is copied into the VM over
  ssh and started through the member's API; a row renamed in the wizard keeps the folder it came
  from (`source`). Nothing to copy: the VM starts empty and takes templates.
- **A baked DCS template makes builds fast.** With *Bake a DCS template first* (on by default)
  the hub builds one VM from the chosen image, installs the tools, Docker and the guest agent,
  seals it with cloud-init and turns it into a Proxmox template; every VM for that image is then
  a full clone plus cloud-init — about 40 seconds instead of about 85 — with only the fresh DCS
  code, the setup and the join running inside. `GET/POST /fleet/templates`,
  `DELETE /fleet/templates/{vmid}`; the picker lists baked templates first.
- **The operating system is a choice.** The VM settings offer a catalogue (Debian 13, Debian 12,
  Ubuntu Server 26.04/24.04/22.04 LTS, Fedora Cloud, AlmaLinux 9), whatever Proxmox already
  holds (imported cloud images, installer ISOs from *ISO Images*) and a URL; `.config/fleet-
  images.json` replaces the catalogue. A cloud image builds unattended; an ISO build creates the
  VM with the installer attached, shows the one-line join and closes by itself when the VM joins
  (or is dismissed with its VM). The bootstrap covers apt and dnf systems and opens the API port
  in firewalld. The build cards carry an overall bar with the time left and a *Clear finished*
  button; a VM's capsule sits under the status on the stack card; the hub's sidebar badge counts
  VMs.
- **The hub never starts a VM's stack itself.** `start.sh`/the boot service and the batch actions
  skip stacks that a member runs (their folder on the hub is a leftover), whatever `DOCKER_STACKS`
  says; a VM's stack in a batch is acted on through its VM. After a build moves a stack in, the
  hub's own containers of it are retired (removed; App-Data stays), and the build step says
  exactly what the hub saw — a still-running hub copy fails the step for a *Retry*.
- **The VMs page.** On a hub the Stacks page reads *VMs* (sidebar too): VMs first, each one a
  stack, then the hub's own stacks; a VM opens on the containers running in it with
  start/stop/restart per row, the compose editor and logs, and its power (start, reboot, shut
  down) in the header; *New VM* and the build cards live on the same page. The Proxmox page's VM
  cards list the same containers with *Open* and *Edit compose* instead of a stack row.
- *Test* on a member keeps the guest it re-matched (a guest mapped by hand stays as mapped). A
  member that does not answer — its VM is off — keeps its stacks in the hub's list, marked
  offline, so the hub's leftover `Stacks/<name>` folder never stands in for a VM's stack.
- `api-server.sh --stop` trusts its pid file only when that process is this installation's own
  server, and only ever removes port listeners started from this installation — a copied
  `.data/` or a reused pid can no longer point it at another DCS.

## [3.8.0] - 2026-09-27

### Added

- **Proxmox.** Link an API token (`PROXMOX_URL`, `PROXMOX_TOKEN_ID`, `PROXMOX_TOKEN_SECRET` or
  the secret of that name, `PROXMOX_VERIFY_TLS`, `PROXMOX_NODE`) and DCS shows every node, VM and
  LXC container with live load, powers them (`start`, `shutdown`, `stop`, `reboot`, `reset`,
  `suspend`, `resume`) with an audit entry and webhook event per action, lists recent tasks, and
  watches the guests once a minute: `proxmox_vm_stopped` and `proxmox_vm_started` fire when a
  guest changes state without DCS asking (a change DCS made is remembered for five minutes).
  Endpoints: `GET /proxmox/status|nodes|vms|tasks`, `GET /proxmox/vms/{node}/{type}/{vmid}`,
  `POST /proxmox/vms/{node}/{type}/{vmid}/{action}`, `POST /proxmox/test`. Viewers may look,
  admins and bots may power. `docs/PROXMOX.md` is the guide; `tests/mock-proxmox.py` stands in
  for a host in the smoke suite.
- **Setup knows where it runs.** `setup.sh` and `GET /setup/defaults` report the operating
  system and whether the machine is bare metal, a QEMU/KVM guest (a Proxmox VM), an LXC container
  or the Proxmox host itself, probe the default gateway and the usual names for a Proxmox API,
  and offer to link it; the wizard's Server step opens a Proxmox section by itself on a guest,
  with a *Test connection* button.
- **A Traefik in another VM or machine.** `GET /traefik/dynamic?token=…` serves every route DCS keeps as
  a Traefik HTTP-provider configuration, each service rewritten to `TRAEFIK_FEED_TARGET_HOST`
  (default: the detected LAN IP) and the container's published port, with the middlewares,
  entrypoint, TLS and certificate resolver of the remote side (`TRAEFIK_FEED_*`). Turning
  `TRAEFIK_FEED_ENABLED` on mints the token; `GET /traefik/feed/status` reports routes served,
  routes skipped and when the proxy last pulled; `POST /traefik/feed/token` rotates. A host with
  no Traefik of its own keeps its route files in `.data/routes`, so deploys still make routes and
  DNS records; the proxy network and Sablier plugin steps only run with a local Traefik.

## [3.7.0] - 2026-09-27

### Added

- **45 templates** (151 in the catalogue). Every one was deployed for real and watched until
  healthy before it shipped; each description says what to do after the first start.
  - Home automation: Mosquitto MQTT (config with anonymous/password modes), Zigbee2MQTT (adapter
    picker, MQTT and Home Assistant wired), Node-RED, ESPHome, Frigate NVR (starter config).
  - Media: Navidrome, Komga, MeTube, Jellystat (+PostgreSQL), PhotoPrism (+MariaDB).
  - Monitoring: Beszel hub and Beszel Agent, Gatus (status page with two starter checks),
    Scrutiny (S.M.A.R.T.), Prometheus exporters (Node Exporter + cAdvisor on 127.0.0.1).
  - Productivity: Wiki.js (+PostgreSQL), Homebox, Grocy, Obsidian LiveSync (CouchDB tuned for
    the plugin), draw.io, ONLYOFFICE Docs (JWT ready for Nextcloud), Baïkal CalDAV/CardDAV.
  - Development & data: Docker Registry with web UI, JupyterLab, Mailpit, Umami (+PostgreSQL),
    NocoDB, Metabase, Meilisearch.
  - Network: Tailscale (subnet routes, exit node, Headscale login), Headscale (config written for
    you), Unbound recursive DNS for AdGuard/Pi-hole.
  - Web: WordPress (+MariaDB), Shlink with its web client pre-connected.
  - Gaming: Minecraft (Paper/Vanilla/Fabric/Forge/Purpur), Valheim, RomM (+MariaDB).
  - Storage: Kopia, PairDrop, SFTPGo. Remote: Apache Guacamole, Webtop.
  - Communication: Mattermost (+PostgreSQL), Mumble. AI: LibreTranslate.
- **`route_skip`** in `template.json`: services that must not get a Traefik route, DNS record or
  proxy network (game, voice, MQTT and DNS ports). The README now has a reference of every
  `template.json` field.

## [3.6.0] - 2026-09-27

### Added

- **`GET /ping`** — a public liveness probe: no auth, no Docker call, a tiny body. The
  dashboard's heartbeat times it, so the latency in the status bar is the round trip alone.
- Cached answers carry **`X-DCS-Cache: hit|stale|miss`** and **`Age`**, so a slow poll can be
  told apart from a slow network.

### Changed

- **Polls never wait for Docker.** The response cache is stale-while-revalidate: an answer past
  its TTL is served at once and refreshed in the background (one refresh per endpoint at a
  time); only an answer older than `API_CACHE_MAX_STALE` (120 s), or a cache a write just
  cleared, runs the handler inline. `/events`, `/routes`, `/routes/certificates`, `/disks`,
  `/system`, `/networks`, `/volumes`, `/images`, `/images/check-updates`, `/logs/stats`,
  `/maintenance/report`, `/topology` and `/dns/status` join `/status`, `/health`, `/stacks`,
  `/containers` and `/health/score` behind it. On a 45-container host the median `/containers`
  and `/health` answer goes from ~700 ms to ~100 ms; `/topology` (11 s to compute) is instant
  after its first call.
- The compose command is detected once by the listener and inherited by the request handlers
  instead of running `docker compose version` on every request (~25 ms each).

## [3.5.2] - 2026-09-27

### Added

- **Container events reach the Integrations webhooks.** Start, stop, restart, recreate and
  remove from DCS are audited (`container_start`, `container_stop`, …), and the health monitor
  announces transitions: `container_stopped` (on its own), `container_unhealthy`,
  `container_recovered`. Stops, restarts, deploys, nukes and the UPS shutdown that DCS itself
  performs are marked as intended for five minutes, so they never read as crashes and a start
  you asked for is not a "recovery". More than five containers changing in one poll is one
  summary message. `disk_warning` is audited once per threshold crossing.
- **Webhook catalogue**: events are matched case-insensitively and without the `auth.` prefix,
  so a hook can subscribe to `user_create`, `login_fail`, `lockout`, `system_update`,
  `recovery_bundle` and every other audited action the dashboard now lists in groups.
- **User list carries profiles**: `GET /auth/users` adds `display_name`, `avatar`,
  `status_emoji` and `status_text` from each person's profile.

### Changed

- **Lighter on the Docker daemon.** `/status`, `/health`, `/stacks`, `/containers` and
  `/health/score` are served from a short cache (10 s, 5 s, 10 s, 5 s, 15 s) shared by every
  client; any write, and any audited event, clears it (`API_RESPONSE_CACHE=false` turns it off).
  The container stats sweep behind `/containers` runs at most every 15 s instead of on every
  call. On a box with several dashboards open this removes most of containerd's and dockerd's
  CPU time.
- Invites are for people again (`user` or `admin`); bot accounts are created directly.

## [3.5.1] - 2026-09-27

### Fixed

- `POST /crowdsec/notifications` also finds the webhook the crowdsec template was deployed with
  (the stack's `.env`) or the one CrowdSec already posts to, so re-applying the alert template
  works on installs that never set `DISCORD_WEBHOOK_URL` in the root config.

## [3.5.0] - 2026-09-27

Discord, finished: every message DCS posts now reads like the dashboard, the bot grew up, and the
whole setup is written down in `docs/DISCORD.md`.

### Added

- **Notification embeds rebuilt**: the server as author line, an emoji and colour per event
  (emerald / amber / rose / cyan / violet, the dashboard's palette), the event's facts as fields
  with identifiers in bold, a footer with event, host and version, and the title linking to the
  dashboard; the posts carry the DCS avatar and can never ping anyone. `DISCORD_WEBHOOK_NAME` and
  `DISCORD_WEBHOOK_AVATAR` change the identity; ptb/canary webhook hosts are accepted.
- **Events that were advertised now fire**: `deploy_complete`, `health_change` (once per change of
  the overall verdict), `backup_complete` / `backup_failed`, `disk_warning` (per mounted filesystem),
  `container_high_cpu` / `container_high_memory` (only when a rule asks), `update_available` (once
  per set of images), `image_stale`. Stack starts, stops, restarts and updates are audited
  (`stack_start`, `stack_stop`, `stack_restart`, `stack_update`), so the Integrations webhooks
  finally receive them. Container events carry their stack.
- **Cooldowns**: a rule repeats the same event for the same target at most once per cooldown while
  the condition lasts (`NOTIFY_COOLDOWN_MINUTES`, default 60 for container rules; 6 h for disk,
  a day for images; deploys, backups and health changes always post); `cooldown_minutes` per rule;
  a recovered container may alert again right away. Default wording per event when a rule's
  templates are empty.
- **Generic webhooks speak Discord and Slack**: an Integrations hook pointed at a Discord webhook
  gets the same embed, a Slack incoming webhook gets text, anything else a JSON envelope with a
  human title.
- **CrowdSec alerts redesigned**: what was blocked in plain words, address with flag and network,
  hits, decision and duration, scenario, CTI and AbuseIPDB links, the first request; the DCS
  shield avatar. Deploying restarts CrowdSec so the plugin reads it, and
  `POST /crowdsec/notifications {webhook?, test?}` re-applies it to a running CrowdSec and can
  post a test alert.
- **Bot accounts** (`role: bot`): day-to-day operations only — read what a user can plus the audit
  log, backups and update checks; start, stop, restart, update and recreate stacks and
  containers, deploy, back up, prune, run schedules, unban. No accounts, secrets, files, host,
  network or DCS changes. Several sessions at once even in single-session mode. The Discord bot
  template creates its account with this role. `POST /auth/users/{username}/role` changes a role
  (the last admin stays; the account's sessions are signed out).
- **Nuke & reinstall** a container: `GET /containers/{name}/reset` previews what goes (App-Data
  folders with sizes, named volumes, folders kept because another container shares them);
  `POST /containers/{name}/reset {confirm, wipe_app_data, wipe_volumes, pull}` removes the
  container, moves its folders to `App-Data/.trash` (kept `RESET_TRASH_KEEP_DAYS`, default 7),
  drops its own volumes when asked, pulls and creates it again from the compose file. Backups skip
  the trash.
- `docs/DISCORD.md`: webhook, rules and cooldowns, CrowdSec alerts, the bot (application, invite
  URL, IDs, account, template, commands, channel lock, troubleshooting), Rich Presence, the brand
  kit, generic webhooks, a reference of every event's look.
- Discord bot template: `DISCORD_ADMIN_ROLE_IDS` and `DISCORD_CHANNEL_IDS`.

### Fixed

- Discord embeds never showed their fields (the payload used a key Discord ignores).
- A rule for a stopped or unhealthy container posted on every health poll.

## [3.4.2] - 2026-09-26

### Added

- `POST /auth/users {username, password, role}`: an admin creates an account directly, no invite
  code — for the Discord bot and for people who should not register themselves. Deploying the
  `discord-bot` template creates the DCS account it signs in as when it does not exist yet.

## [3.4.1] - 2026-09-26

### Fixed

- `GET /health` reports a stopped on-demand container with `health: "sleeping"` instead of the
  stale result of its last health check, so dashboards stop calling it unhealthy.

## [3.4.0] - 2026-09-26

### Added

- **Deploy switches.** The deploy request takes `authelia_services` and `on_demand_services`:
  a route is protected by whatever forward-auth middleware this install defines
  (`authelia-forwardauth` in hand-built configs, `authelia` in the template — the deploy rewrites
  the reference, so a route never points at a middleware that does not exist), and an on-demand
  service ships with its Sablier middleware, the plugin declared in Traefik once. `GET /traefik/status`
  reports `authelia_middleware`, `authelia` and `sablier` so the deploy screen only offers what exists.
- **Recovery bundles.** `POST /recovery/bundle` writes one AES-256 encrypted archive with the root
  `.env`, the secret store and its key, accounts, rules and layouts, schedules, every stack's files,
  Traefik and Authelia data (App-Data of chosen stacks on request), templates and plugins.
  `GET /recovery` lists bundles, `GET /recovery/{file}/download` fetches one, `POST /recovery/upload`
  and `POST /recovery/restore` put one back (pre-restore snapshot kept), and `POST /setup/restore`
  does the same from the setup wizard before any account exists. The passphrase lives in the secret
  store as `RECOVERY_PASSPHRASE`; `RECOVERY_REMOTE` receives a copy (rsync target or mounted path).
  Schedule action `recovery` and automation action `recovery_bundle`.
- **UPS watch.** With `UPS_ENABLED=true` the listener polls a NUT server over the network
  protocol (no client binaries needed) or apcupsd, keeps `.data/power.json`, alerts on every
  mains/battery transition, and below `UPS_SHUTDOWN_CHARGE` or `UPS_SHUTDOWN_RUNTIME` stops every
  stack cleanly (`UPS_ON_BATTERY_ACTION`), runs `UPS_HOST_SHUTDOWN_CMD` when set, and optionally
  starts the stacks again when mains returns. `GET /power`, `POST /power/sample`. New template
  `nut-upsd` serves a USB UPS from a container.
- **Unattended self-update.** `api-server.sh --self-update [--images]` (schedule action
  `dcs-update`, automation action `dcs_update`) runs outside the listener: it applies the channel's
  release, restarts the API, optionally pulls image updates for every stack, waits
  `UPDATE_HEALTH_GRACE` seconds and rolls back to the backup tag when the health score fell by
  `UPDATE_ROLLBACK_DROP` points (`UPDATE_AUTO_ROLLBACK`). Outcomes go to the notification channels
  and `GET /system/update/history`. Edited framework files are never replaced unattended.

### Fixed

- Routes generated for protected services referenced `authelia-forwardauth`, which the template
  never defined; new installs now get a working reference.
- The `bentopdf` template pointed at port 80; the published image serves on 8080.
- **Restart from the page works everywhere.** A listener started with `nohup` inherits SIGHUP
  ignored, which bash cannot trap, so the 3.3.0 in-place restart was a silent no-op there. New
  listeners advertise `reexec-usr1` and restart on SIGUSR1; a 3.3.0 listener under systemd still
  gets SIGHUP, and one outside systemd is stopped and started again with its own arguments by a
  detached helper (`relaunch`). `GET /system/update/check` reports the method in `restart_method`.
- **Prunes spare on-demand containers.** Every prune (Maintenance, deep prune, the `prune`
  schedule, the `docker_prune` automation) used `docker system prune`, which deletes stopped
  containers — and a container Sablier put to sleep is stopped. They now remove stopped containers
  one by one, skipping the on-demand ones, keep the networks those need, and the orphan report no
  longer lists them. On-demand containers an older prune already removed are recreated (created,
  not started) at API start and by `POST /sablier/repair`; `GET /health` reports them under
  `summary.on_demand_missing`.

## [3.3.0] - 2026-09-26

### Added

- **Self-update that needs no shell.** `GET /system/update/check` follows a release channel
  (`UPDATE_CHANNEL=stable`, the newest `vX.Y.Z` tag, or `main`) instead of the checked-out
  branch, so an install left on an old release branch sees every release. It reports the release
  notes, whether GitHub answered at all (`checked`, `error`), the relation to the release
  (`state`: current, behind, ahead, diverged) and which local edits the update would touch.
  `POST /system/update/apply` keeps every edited file under `Stacks/`, `.templates/`,
  `.api-auth/` and `.plugins/` byte for byte, deleted ones stay deleted, and no `git stash` is
  involved any more. Edited framework files stop the update until `replace_local` is sent; the
  replaced copies are kept under `.data/update-backups/`. The response lists what was kept and
  replaced, new settings that appeared in `.env.example`, and whether the systemd unit template
  changed. Backup tags are pruned to the last ten; rollback keeps user files the same way.
- `POST /system/restart`: the listener restarts without root. A listener started by this version
  re-executes itself on SIGHUP (same PID, systemd notices nothing); an older one running under a
  unit with `Restart=on-failure` is relaunched by systemd. `apply` and `rollback` accept
  `restart: true` to do it right after the switch, and the Updates page waits for the API to
  come back.
- BentoPDF template (`bentopdf`): the browser-side PDF toolkit — one nginx image, no data.
- **Add to Homarr places a tile.** Registration uses Homarr 1.x's REST API when the secret
  `HOMARR_API_KEY` is stored: the app is created (or reused when its URL exists) and a tile is put
  on the home board; without a key the app only lands in the library, as before.
  `POST /homarr/register {name, url, icon, description}` does the same for anything else.

### Fixed

- Template preview and deploy: "Target stack not found" lists the stacks that actually have a
  compose file instead of the stale `DOCKER_STACKS` value.
- `GET /config` reports `update_channel`; `POST /config` accepts `UPDATE_CHANNEL`.

## [3.2.1] - 2026-09-26

### Fixed

- Sablier detection also reads dynamic files kept beside `traefik.yml` and mounted into the
  routes directory by hand (a `TraefikRoutes.yml` from an older setup), so containers managed
  there count as on demand too.

## [3.2.0] - 2026-09-26

### Added

- **Sablier awareness.** Containers that Traefik starts on demand (a `sablier` plugin middleware
  naming them in any route file) are reported as `on_demand`; stopped ones count as `sleeping`
  in `GET /health` instead of stopped and no longer raise "container stopped" notifications.
  `POST /containers/{c}/sablier {enabled}` writes or removes the middleware on the container's
  route (its own `<name>-sablier.yml` file), declares the plugin in `traefik.yml` when an older
  install lacks it, and restarts Traefik once in that case.
- **CrowdSec from the setup wizard.** The crowdsec template reads Traefik's JSON access log,
  registers a Traefik bouncer on its LAPI (`dcs-traefik-bouncer`) and puts `crowdsec-bouncer`
  first in `traefik-chain`, posts every decision to Discord with a per-scenario embed when a
  webhook is known, and undoes the chain and middleware on undeploy. The Traefik template now
  writes a JSON access log to `App-Data/Traefik/logs` for it.
- `_traefik_ensure_plugin`: a plugin used by DCS-written middleware is declared in the static
  config of an existing install before it is referenced, so no route is ever dropped for a
  missing plugin.

### Changed

- Traefik template: plugins are declared and pinned (geoblock, cloudflarewarp, log4shell,
  sablier, crowdsec-bouncer); the shipped but never-loaded `traefikRouters.yml` is gone and its
  middlewares (default/security headers, cors-all, nextcloud chain) live in the loaded
  `custom_routes/…/traefik.yml`; the LAN allow-list uses the deploy's `TRAEFIK_TRUSTED_LAN`
  instead of a hard-coded subnet; the dead `cache` middleware (undeclared plugin) is removed.
- Traefik stack detection matches the proxy image only (`traefik/whoami` is not Traefik) and
  prefers the stack whose App-Data holds Traefik's config.
- DDNS starts as soon as the wizard or Server Config enables it, not at the next API restart,
  and stops when disabled.
- API 1.6.0, 236 endpoints, smoke suite 222 checks.

## [3.1.7] - 2026-09-26

### Fixed

- Authelia could not be deployed since 3.0.0: the security hardening of 2026-09-24 validated
  a template's `config_path` as a single directory name, and Authelia's template uses the
  nested `Authelia/config`, so every deploy (setup wizard included) was refused with
  "Template metadata has an invalid config_path". Nested relative paths are accepted again;
  absolute paths and `..` segments are still refused. Without Authelia every Traefik route
  that names its middleware answered 404.

## [3.1.6] - 2026-09-26

### Changed

- `GET /routes/certificates` grew into the proxy health view: the domain routes are built on,
  a live probe of every route through Traefik (passing, dead with their HTTP code, backends
  down), the last Traefik errors and warnings from its log, and hints that name the usual
  cause of a 404 from Traefik (a route referencing a middleware or service that does not
  exist, another domain, an unread routes directory) or of an `example.com` domain.

## [3.1.5] - 2026-09-26

### Fixed

- The traefik template said "leave the Cloudflare token empty to use the HTTP challenge", but
  the deployed `traefik.yml` always kept `dnsChallenge`, so an install without a token never
  got a certificate: browsers warned, Cloudflare in Full (strict) mode answered 526. The deploy
  now keeps the challenge that matches the deploy (token → DNS-01, none → HTTP-01 on port 80)
  through markers in the template's `traefik.yml`; redeploying switches it either way.

### Added

- `GET /routes/certificates`: the proxy's TLS state — challenge in use, ACME account email,
  whether the token is set, `acme.json` presence and mode, every certificate Traefik holds with
  its expiry, the last ACME errors from Traefik's log, and plain-language hints for the usual
  causes. The DNS & Routes page shows it as a Certificates panel.

## [3.1.4] - 2026-09-25

### Added

- `./compose.sh <stack> [args…]`: docker compose for one stack the way the dashboard and
  start.sh run it, with the root `.env`, the stack `.env` and the encrypted secret store
  applied (`--list` names the stacks). A bare `docker compose` in a stack directory cannot see
  `${SECRETS_name}` values and recreates a container with blank secrets; the README says so now.

## [3.1.3] - 2026-09-25

### Fixed

- An empty or corrupt state file (a schedules.json left at 0 bytes by an old crash) made
  `GET /schedules` answer `{"schedules": , "count": }`, which the dashboard reported as
  "Invalid JSON response". State files (schedules, notifications, automations, deploy history)
  are now checked before use: a bad one is moved aside as `<file>.corrupt-<timestamp>` and
  replaced by an empty default, with an audit entry. The response writer also refuses to send
  a body that is not valid JSON and answers a real 500 with a hint instead.

## [3.1.2] - 2026-09-25

### Changed

- Unattended boots (`dcs-stacks.service`) no longer pull image updates for every stack: the
  services come back with the images they have, and updates stay with the Updates page and
  schedules. `UPDATE_ON_BOOT=true` restores the old behaviour. Two pulls timing out at boot
  used to leave "Failed to pull images" errors in every boot log.
- `proxy-reconcile.sh` restarts Traefik only when routes are missing (000/404). An app that
  answers 502/503/504 is reported as "not answering yet" (exit 3) instead of triggering a
  Traefik restart, and start.sh logs it as a warning instead of failing the boot unit; a slow
  starter such as Pelican Wings or Plex turned the unit red on every boot.
- start.sh returns its outcome without tripping its own error trap, which logged a misleading
  "Script interrupted" and wrote the session summary twice.

## [3.1.1] - 2026-09-25

### Fixed

- Server Config wrote values without quotes, so a Server Name with a space
  (`SERVER_NAME=Howson Server`) broke every script that sources `.env`: start.sh, stop.sh,
  status.sh and setup.sh printed "Server: command not found" and lost the value, and the boot
  unit ran the stacks without it. Values are now quoted the way bash reads them
  (`.lib/envfile.sh`), the API parses them back identically, the setup wizard writes through the
  same path, and the scripts repair an already broken `.env` before sourcing it (the original is
  kept as `.env.bak-repair`).
- A stack listed in `DOCKER_STACKS` without a `docker-compose.yml` no longer fails the whole
  start or stop (and with it `dcs-stacks.service` at boot); it is reported as skipped.
- `install-service.sh` labels the entry scripts `bin_t` on SELinux systems (persistent
  `semanage` rule, `chcon` fallback) so systemd runs them as `unconfined_service_t` instead of
  `init_t`; that ends the setroubleshoot denials at boot and real failures once SELinux enforces.
  Re-run it with sudo on an existing install to apply.
- `_envfile_set` keeps the file's mode (a stack `.env` no longer turns world-readable after a
  container environment edit) and no longer mangles backslashes.

## [3.1.0] - 2026-09-25

### Added

- Discord notifications: set `DISCORD_WEBHOOK_URL` (a channel webhook, or a `${SECRETS_name}`
  reference) and every notification rule, automation and test also posts a rich embed to Discord:
  an emoji and colour per event, the event's facts as fields, the host and DCS version in the
  footer, and a title linking back to the dashboard (`DASHBOARD_PUBLIC_URL`, otherwise
  `https://ui.<PROXY_DOMAIN>`). The setup wizard and Server Config take the webhook; `GET /config`
  reports `discord_configured` and the last characters of the URL, never the URL itself.
- Discord bot template (`discord-bot`): deploys `ghcr.io/scotthowson/dcs-discord-bot`, which signs
  in to the API with its own user and answers `/status`, `/usage`, `/health`, `/containers`,
  `/stacks`, `/updates`, `/container <name> <info|logs|start|stop|restart|recreate>` and
  `/stack <name> <info|start|stop|restart|update>`. Commands that change the server are limited
  to the Discord user IDs in `DISCORD_ADMIN_IDS`.
- Card Studio endpoints: `POST /plugins/{plugin}/cards/{card}` writes a dashboard card
  (`card.json` + `index.html`, creating an enabled card-only plugin when needed),
  `GET .../source` returns it for editing and `DELETE` removes it. Admin only, 1 MiB limit.
- `GET /system` reports `virtualization` (`none` on bare metal, otherwise what
  `systemd-detect-virt` names) and `guest_agent` (QEMU guest agent installed, running, and the
  VM's agent channel present), so a Proxmox/KVM guest can see what its backups rely on.

### Changed

- `POST /notifications/test` tries every configured channel and names the one that failed; it
  used to blame ntfy for a Discord error. API version 1.5.0, 234 endpoints, smoke suite 177 checks.
- The example System Clock card's badge shows the time zone instead of "Plugin Card".

## [3.0.3] - 2026-09-25

### Fixed

- Resource Trends history was cut to seven days: the hourly tier honoured the old
  `METRICS_RETENTION_DAYS=7` from existing `.env` files. The tiers now have their own settings
  (`METRICS_RAW_DAYS` 7, `METRICS_5M_DAYS` 90, `METRICS_HOURLY_DAYS` 730) and the long ranges
  fill up over time.
- Plugin cards: manifests written with `size` instead of `defaultW`/`defaultH` (the Traefik
  subdomain card) produced a card with no dimensions and broke the dashboard grid; the cards
  list now normalises every manifest to numbers. A card's own `style.css`/`script.js` are
  inlined into its HTML, since the dashboard renders cards from a blob URL where relative
  files cannot load.

## [3.0.2] - 2026-09-25

### Fixed

- The dashboard's image count came from `docker info`, which also counts untagged intermediate
  layers, so it disagreed with the Images page; `GET /status` now counts the same top-level
  images the page lists.
- Container uptime in `GET /health` and `GET /containers/{container}` tolerates a start time
  jq cannot parse instead of failing the whole response.

## [3.0.1] - 2026-09-25

### Added

- `POST /containers/{container}/env` changes a Compose-managed container's environment where
  it is defined: the service's `environment` entry in `docker-compose.yml` (list or map form,
  formatting and comments kept), or the stack `.env` variable the entry references. Validated
  like a compose save (policy scan, `compose config`, backup, version history) and the container
  is recreated unless `recreate` is `false`.
- `GET /containers/{container}` reports `compose_project`, `compose_service` and `compose_dir`.

### Fixed

- `GET /containers` dropped every container whose Docker uptime reads "About an hour ago" or
  "About a minute ago": the uptime parser found no digit and emptied the whole entry out of the
  list, so the Containers page showed fewer containers than the sidebar until the wording
  changed to "2 hours ago".

### Changed

- Smoke suite at 159 checks (environment editor helpers and endpoint policy).

## [3.0.0] - 2026-09-25

The long-term release. Everything from the 2.1.0 readiness pass plus the deployment,
network and update work verified on a real install. The API version is now 1.4.0.

### Added

- `POST /networks/{network}/recreate` rebuilds a network with new settings: its containers are
  disconnected, the network removed and created again, the containers reconnected. Compose
  ownership labels survive unless the request replaces them; if Docker refuses the new
  settings the old network is restored. `POST /networks` accepts `ip_range`, `attachable`,
  `ipv6` and `labels`; `GET /networks/{network}` reports them plus `created` and the owning
  Compose project.
- Template deployments accept `container_names` ({service: name}). Names are validated,
  refused when another stack's container already uses them, and written into the merged
  compose so routes, activity tracking and the container page all use them.
- `POST /images/update` takes `recreate` (default true). With `false` the image is only
  pulled; the containers keep running on the old image. A successful pull marks the image
  current in the registry cache, so `GET /images/check-updates` stops calling it stale
  until the next registry check.

### Changed

- `POST /templates/{template}/undeploy` removes the containers of the services it drops
  unless `remove_containers` is `false` (the dashboard always asked for it; a raw call that
  purged App-Data under a still-running container was a trap).
- API version 1.4.0; 230 documented endpoints; smoke suite 148 checks (network option
  validation, recreate policy, deploy container-name validation).

## [2.1.0] - 2026-09-24

The release-readiness pass: a security review of the whole API server, a clean-up of the
repository, a test suite and generated documentation. The API version is now 1.3.0.

### Security

- Authentication is mandatory on any non-loopback bind, decided after `--bind` is parsed and shared
  with every request handler (previously `.scripts/api-server.sh --bind 0.0.0.0` on a default
  `.env` served the whole API without a token). `API_INSECURE_NO_AUTH=true` is the only opt-out.
- A fresh install (or a factory reset) only answers the setup endpoints and `GET /version` until
  the first admin account exists.
- Central role policy: the `user` role is read-only; every mutating, code-executing or
  secret-exposing route requires `admin` (plugins, templates, schedules, snapshots, backups,
  system and OS updates, `.env`, secrets, crontab, webhooks, automations, image updates...).
- `.env` is loaded as data instead of being sourced; writes through the API are validated and
  reserved shell/loader variables are refused.
- Fixed command execution through a route rename (GNU `sed` `e` command), a jq filter injection in
  `/metrics/trends` that could dump the server environment, shell interpolation in the Homarr
  registration script, and unvalidated stack names, service names, snapshot ids, version ids,
  `config_path` values and schedule targets reaching `rm -rf`, `docker compose`, `rsync` and `sed`.
- Snapshots and backups no longer contain session tokens, invites or rate-limit state; archives
  are created with mode 600 and listed once before extraction (no SIGPIPE race).
- Plugin hooks run with a minimal environment, never through symlinks, and only when enabled in
  the manifest (the `.disabled` marker and the manifest flag used to disagree). The dry-run
  `pre-deploy` hook used to inherit the whole server environment. `git clone` for plugins no
  longer follows redirects, prompts or creates symlinks.
- Passwords and the secrets master key never appear on a command line.
- The terminal can only be unlocked with the service account's or root's credentials, reports the
  real exit code, and its audit log cannot be forged with newlines.
- `X-Forwarded-For` from trusted proxies (`API_TRUSTED_PROXIES`) drives rate limits, lockouts,
  whitelists and audit logs, so UI users no longer share one bucket.
- Route updates validate the subdomain and build Cloudflare requests with jq; nested subdomains no
  longer delete a sibling DNS record.
- Template fetch and import do not follow redirects; imports refuse to overwrite an existing
  template unless `overwrite: true`.

### Fixed

- `api-server.sh --stop`, `stop.sh` and systemd could not stop the server: the listener ran in
  the foreground so the SIGTERM trap never fired. The listener is now supervised and stops
  cleanly; `--stop` also cleans up orphaned listeners, open event/log streams and the hourly
  housekeeping sleep that used to outlive the server.
- `GET /setup/defaults` answered `403` to the UI's server-configuration page once setup was
  complete; admins can read it again (it stays anonymous only during first-run setup).
- Authentication events (logins, failures, lockouts, invites, TOTP changes...) were written to a
  text file nothing read; they now also appear in `GET /audit` and can trigger webhooks.
- The server refuses to start when its port is held by another process and names it, instead of
  failing silently inside socat; `--stop` no longer kills whatever listens on the port (another
  DCS installation, an unrelated service), only orphaned DCS listeners.
- A browser tab that was already showing the dashboard kept a session from an older UI (local
  accounts, no API token), so after `./setup.sh` it polled with no credentials, never showed the
  wizard and flapped between "Connection Unstable" and "Connection Restored". The bundled web UI
  now ends such a session on the first 401 and lands on the login/setup flow (UI 2.23.1);
  `setup.sh` reminds you to reload an already-open dashboard.
- The systemd unit used `Type=forking` for a foreground process and flapped every 30 seconds.
- `setup.sh` crashed on hosts without Docker (undefined `_warn`), refused nothing when run with
  `sudo`, corrupted quoted `.env` values with an unanchored `sed`, and kept a loopback-bound API
  running after switching `.env` to `0.0.0.0`.
- `.env.example` had lost the All-In-One defaults (`API_ENABLED=true`, `API_BIND=0.0.0.0`,
  `DCS_UI_PORT=3000`), so a fresh clone brought up a web UI that could not reach the API.
- `pre-deploy` plugin hooks only ever ran during dry runs; real deployments now fire them too.
- `GET /routes/check` and route update/delete crashed on undefined variables; snapshot labels never
  loaded (`./manifest.json`); metrics history/summary read files nothing wrote; the health score
  history endpoint had no data source; hook tests always reported exit code 0; notification rules
  and webhooks could not be created disabled; stack rename corrupted hyphenated neighbours in
  `DOCKER_STACKS`.
- Container recreate replaced non-Compose containers with a bare `docker run` (volumes, ports and
  environment lost); image update deleted containers it could not recreate. Both now refuse and
  report instead.
- Template deploy: privileged mode was silently allowed for every built-in template; the backup was
  taken after the compose file had already been rewritten; `&` in variable values corrupted the
  compose file on bash 5.2+; Authelia used the wrong domain and shipped an unverifiable password
  hash when no hasher was available.
- Metrics rotation on `mawk` hosts (Debian/Ubuntu default) wiped the history every hour.
- The scheduler library built Python programs from user data (code injection) and JSON by string
  concatenation.
- `stop.sh` looked for PID files in `/tmp` that nothing writes; `start.sh` always exited 0;
  `status.sh` ignored `DOCKER_STACKS`; the configuration validator's port check could never match;
  `clean-up.sh`'s deletion prompt called a function that was never loaded; headless runs of
  `start.sh` exited on an unanswerable prompt.
- Automations never ran: rules were written to the user's crontab through a pattern that could
  also wipe unrelated entries, the matching `cron.sh` did not exist, `POST /automations/{id}/run`
  did not exist, and the history endpoint returned invalid JSON for an unknown rule.
- Secrets did not work end to end: the API wrote a different file format than `.lib/secrets.sh`
  read, `${SECRETS_NAME}` placeholders were only resolved by one code path, stack start silently
  ran with empty values, and compose validation rewrote `.env` files.
- Trends only ever showed the last 49 samples: the raw history was trimmed on every read.
- Plugin hooks received an empty context and no environment, so 21 of the 24 catalogue plugins
  could not work; `post-*` hooks fired before the action had finished and never learned whether
  it succeeded.
- NTFY: the topic configured in `.env` was ignored by half of the senders; `NTFY_TOKEN` is now
  honoured everywhere.
- After a power loss, Traefik could come up before its plugins and the Docker socket proxy and
  route nothing until restarted (see `start.sh --boot` under Added).
- Factory reset left automations, schedules, metrics and secrets behind.
- The factory reset's "wipe stacks" option killed every container on the host and pruned every
  image, including ones that were never DCS's. It now takes down only DCS stacks (never
  core-infrastructure, so the dashboard survives), their volumes and the images they used.
- `POST /containers/{name}/exec` passed `-T` to `docker exec`, which does not exist, so every
  command from the Containers page failed with exit 125. Commands now run without a terminal,
  with stdin closed, and fall back to `bash` or a direct exec when the image has no `sh`.
- Deploy auto-start used `--no-recreate`, so a replaced service kept running with its old
  definition; the ownership fix after a deployment chowned every root-owned directory in the
  stack's App-Data and restarted the whole stack. It now recreates only the deployed services,
  fixes only their own bind mounts and restarts only them.
- The nginx-web template mounted an empty `conf.d`, so a fresh deployment served nothing and
  failed its health check; it now ships a default server block and page.
- `GET /auth/verify` answers 401 for a missing or dead token (see Auth above); the connect
  screens resolve any address form; the DCS-UI route template documents the container port.

### Changed

- Per-request cost halved: the compose command is detected once by the server and inherited by the
  request handlers; `/stacks` uses one `docker ps` instead of one `docker compose ps` per stack;
  container, image, health-score and topology handlers batch their `docker inspect` calls.
- Disk figures report the filesystem that holds the installation instead of `/home`.
- Cloudflare and Homarr work, backups, restores, stack actions and plugin hooks run detached from
  the request connection.
- `.gitignore` covers every runtime file the server writes (`.api-auth/*`, `.data/`, `.secrets/`,
  logs, plugin state, editor files).
- `README.md`, `CLAUDE.md` and the systemd unit now describe the All-In-One edition (web UI on
  port 3000, this repository's URL).
- Stack start/stop/restart/update and template deployments run through one detached runner that
  fires the `pre-*` hook, performs the action, then fires the `post-*` hook with `success`,
  `containers` and (for updates) `changed_images` in the context; results are logged to
  `logs/stack-actions.log`.
- Metrics are kept in three tiers: raw samples for 7 days, 5-minute averages for 90 days and
  hourly averages for two years, stitched together and downsampled to at most 1 500 points per
  request. `GET /metrics/trends` accepts `1h`...`7d`, `30d`, `90d`, `1y` and `all`.
- `stack start` refuses (422) when a `${SECRETS_*}` placeholder has no stored value; template
  deploys still write the compose file but hold the auto-start and say why.
- The `dcs-stacks` service starts after the network is online and after `dcs-api`, waits for the
  installation's filesystem, and runs `start.sh --boot` (no banners, keep going on failures).
- `.scripts/metrics.sh` and `.lib/scheduler.sh` daemons are no longer started by `start.sh`; the
  API server owns metrics, schedules and automations.
- The `SECRETS_ENCRYPTION` setting is gone: secrets are always encrypted at rest.

### Added

- `tests/smoke.sh`: 110+ checks that drive the request handler exactly as socat does, in an
  isolated temporary installation (no network, no Docker required for most checks).
- `tests/lint.sh` and a GitHub Actions workflow: `bash -n`, `shellcheck`, compose validation of
  every stack and template, the API reference freshness check and the smoke tests.
- `docs/API.md`: the complete endpoint reference (222 endpoints) generated from the router by
  `.scripts/api-docs.sh`, with access levels taken from the server's own policy.
- `SECURITY.md`, this changelog, a `VERSION` file (single source for the release version) and a
  plugin authoring guide in `.plugins/README.md`.
- `API_TRUSTED_PROXIES` and `API_INSECURE_NO_AUTH` settings; `GET /health/score/history` and
  `/metrics/history|summary` now have data; schedules accept `start`, `stop` and `maintenance`.
- An in-process automation engine: cron expressions and presets (`@hourly`, `@5min`...),
  conditions (`container_unhealthy`, `container_stopped`, `high_cpu`, `high_memory`,
  `disk_full`) with a 15-minute cool-down, actions (`stack_start|stop|restart`,
  `container_restart`, `docker_prune`, `backup_trigger`, `notification_send`), run history and
  `POST /automations/{id}/run`.
- Secrets v2: `GET /secrets/{name}/references` shows every compose and `.env` file that uses a
  secret; names follow `^[A-Za-z_][A-Za-z0-9_]{0,63}$`; the CLI (`run.sh`, `stack-manager.sh`,
  `update_all_stacks.sh`, scheduler, rollback) resolves the same placeholders as the API.
- CrowdSec integration: `GET /crowdsec/status`, `GET /crowdsec/decisions`,
  `DELETE /crowdsec/decisions/{ip}`, `POST /crowdsec/unban-me`, `POST|DELETE /crowdsec/trust`;
  the home public address (from the DDNS file or ipify) and `CROWDSEC_TRUSTED_IPS` are written
  to a CrowdSec whitelist parser every ten minutes, so a dynamic address never bans itself.
- Reverse-proxy reconciliation: `.scripts/proxy-reconcile.sh` probes every Traefik route and
  restarts Traefik once when none answer; `start.sh --boot`, `PROXY_RECONCILE=true`,
  `GET /routes/health` and `POST /routes/reconcile`.
- Plugin contract v2: hooks receive a JSON context on stdin (`event`, `stack`, `project`,
  `compose_file`, `action`, `success`, `containers`, `template`, `compose`, `dry_run`) and a
  documented environment (`PLUGIN_DIR`, `PLUGIN_STATE_DIR`, `DCS_PLUGIN_CONFIG`, `DCS_NTFY_URL`,
  `DOCKER_COMPOSE_CMD`, the `.env` names the manifest lists...). A catalogue of 23 ready-made
  plugins ships in `.plugins-catalog/` (`GET /plugins/catalog`,
  `POST /plugins/catalog/{name}/install`).
- `NTFY_TOKEN` for protected NTFY servers; the setup wizard can deploy an NTFY server itself.
- Cloudflare DNS management: `GET /dns/status` (token source and validity, zone), `GET /dns/zones`,
  `GET /dns/records` (every type, with the DCS route that uses each name), `POST /dns/records`,
  `PUT /dns/records/{id}`, `DELETE /dns/records/{id}` (the zone apex and names a route uses need
  `force=true`) and `POST /dns/records/sync` (creates the CNAMEs routes are missing). The token
  is read from the secret `CF_DNS_API_TOKEN` first, and a `${SECRETS_CF_DNS_API_TOKEN}`
  placeholder in any `.env` resolves through the secret store; the setup wizard stores the
  token that way.
- `GET /images/check-updates` reports `registry_checked_at`; `POST /images/{image}/update`
  reports `containers_failed` (recreated but not running) and fires the `post-update` plugin
  hook for every stack it touched.
- Real deployment progress: every background stack action (deploy auto-start, start, stop,
  restart) keeps a record and its compose output under `.data/stack-actions/`, and
  `GET /stacks/{stack}/activity` reports the phase (pulling, creating, starting, health check,
  running, failed, unhealthy, exited), each service's container, state, health and the
  container's own health-check output or last log lines. The deploy response carries the
  container names and the activity id. `GET /templates/{name}` lists the `${SECRETS_…}`
  names a template uses and whether each exists.

### Removed

- The accidentally committed duplicate template tree `.templates/.templates/` (215 stale files).
- Committed runtime history in `.api-auth/update-history.json` (now an empty template).
- Dead code: unused Homarr detection, the `if true` scaffolding around Authelia config, the
  Python fallbacks in the plugin handlers, the unused `wait_for_it` wrapper function.
