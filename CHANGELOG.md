# Changelog

All notable changes to Docker Compose Skeleton AIO are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
