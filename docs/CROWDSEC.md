# CrowdSec × DCS — the CrowdSec page

CrowdSec reads Traefik's access log, recognises scanners and brute-forcers by how they behave, and bans them; a *bouncer* inside
Traefik then refuses banned addresses at the door, before any of your apps sees the request. The **CrowdSec** page of the
dashboard (in the sidebar, right under *DNS & Routes*) is where you deploy it, see who is knocking, ban and allow addresses, decide
how long a ban lasts, and shape the Discord messages CrowdSec sends. Everything here is also an API route ([the list](#api)).

```
  visitor ─► Traefik ─(access log)─► CrowdSec ─► decision "ban 203.0.113.7 for 4h"
               ▲                                        │
               └──────── bouncer plugin pulls the bans ─┘        └─► Discord message (optional)
```

Contents: [states](#1-the-states) · [overview](#2-overview) · [bans](#3-bans) · [alerts](#4-alerts) · [allowlist](#5-allowlist) ·
[Discord](#6-discord-alerts) · [settings](#7-settings-ban-length-escalation-simulation) · [hub](#8-hub) · [bouncers](#9-bouncers-machines-community) ·
[logs](#10-logs) · [countries](#11-countries) · [safety](#12-safety-rails) · [fleet](#13-a-vm-through-the-hub) · [API](#api) · [troubleshooting](#14-troubleshooting)

---

## 1. The states

One request (`GET /crowdsec/status`) tells the page which state CrowdSec is in, and the page shows what a person needs in *that*
state: the honest reason, the last lines of its log, and the one-click fix.

| State | What you see | One click |
| --- | --- | --- |
| **Not deployed** | An invitation with a pre-flight (Docker answers? template available? Traefik there? Discord webhook set?) and the choice of stack | **Deploy CrowdSec**: the normal template deployment, followed live; the page opens by itself when CrowdSec is healthy |
| **Defined, no container** | The stack file describes CrowdSec but the container is gone | Start the stack · Deploy again · Show the log |
| **Stopped** | Exit code and reason | Start |
| **Crash loop** | "Restarted 17 times", the exit code and the log's last lines (almost always a configuration error) | Show the log · Restart |
| **Starting** | A calm "starting" until the container reports healthy | (waits) |
| **Unhealthy** | Container runs but its health check fails | Restart · Show the log |
| **API unreachable** | Container runs and is healthy, but `cscli` cannot reach CrowdSec's local API; the bouncer keeps its cached bans | Restart · Show the log |
| **Docker unavailable** | DCS cannot talk to Docker | Check again |
| **Healthy** | The full page below | — |

The deployment does what the template always did: it puts CrowdSec next to Traefik, mounts Traefik's access log read-only,
registers the Traefik bouncer and adds its middleware to Traefik's chain (switch off *Block bans at Traefik* to only detect), and, when
a Discord webhook is known, turns the Discord alerts on. **Re-deploying keeps what you configured on the page**: when the ban settings or
the Discord message are managed by the page (their files carry a `# dcs-settings` / `# dcs-notify` marker), the deploy leaves them alone.

Things that need attention appear as banners under the numbers, each with its fix button: *Bans are not enforced at your proxy*
(no bouncer registered, or Traefik not using it), *Traefik has not asked the bouncer yet*, *CrowdSec reads no log lines*, *hub items can be
updated*, *Discord alerts are on but not working*, and so on.

## 2. Overview

The numbers at the top: engine version and health, active bans, alerts in the last 24 h (with the number of sources and countries),
bouncers and when Traefik last pulled, log lines read and understood, and the size of the community blocklist.

*What has been happening* has a window switch (**24 hours / 7 days / 30 days**; CrowdSec keeps 7 days of alerts by default and the page says so
when you ask for more) and shows detections over time, a dotted world map of where attackers are, the countries with how many
of their addresses are banned right now, the kinds of attack in plain words (*SSH brute force*, *Web probing*, *Exploit attempt*),
the busiest addresses (with a **Ban** button when not yet banned) or networks, and the latest detections. Below: **Protection**
(is Traefik enforcing the bans, one line for each thing Traefik's own files say about the bouncer, how many of your routes go through it, and your own
address), **Community** (blocklist, sharing, console) and **Engine** (version, uptime, log lines per source, hub, *Reload* and *Restart*).

**How the bouncer is wired** is read from Traefik's files, not guessed: the plugin is declared in Traefik's static configuration (name and version) and
Traefik has been restarted since; the middleware file `crowdsec-bouncer.yml` exists; `crowdsec-bouncer` is part of `traefik-chain`; the key in the file belongs to
the bouncer CrowdSec knows (a bouncer registered again after the file was written leaves a key that no longer works); when Traefik last asked CrowdSec (the plugin
reports in at least every ten minutes while it runs, so half an hour of silence counts as a problem); and the plugin's mode. Anything wrong is also a banner with the
fix behind a button (*Register again*, *Restart Traefik*). The routes line says how many routes use the chain and names the ones that **bypass** it: a route that does
not go through `traefik-chain` is never checked, so a banned address can still reach it (the same routes carry an *unprotected* badge on the DNS & Routes page).
DCS finds `traefik-chain` in the routes directory (`custom_routes/`) or, for the original layout that keeps `TraefikRoutes.yml` beside it and mounts it into the container's routes
directory, in the Traefik folder above it. The chain is read by its indentation, so a hand-written file works: any indent, entries with or without quotes, a comment after an
entry, Windows line endings, and an `@file` suffix (`traefik-chain@file` in a route counts as the chain).
A route also counts as protected when it uses a chain of your own that lists `crowdsec-bouncer`, directly or through another chain (a `media-chain`, say).

## 3. Bans

Every active ban, with a live countdown. **Search** (address, reason, country, network), filter by **kind** (addresses / networks),
**origin** (detected by CrowdSec, manual, imported, community blocklist), **country** and **reason**, sort by newest, expiring
soon, address, country or reason, hide simulated ones. Select rows to lift many at once; the info button shows the alert behind
a ban.

**Ban an address** takes an IP (IPv4 or IPv6) or a network in CIDR form and a length: 1 h · 4 h · 24 h · 7 d · 30 d · custom (`90m`, `12h`,
`10d`, `2w`, `1d12h`) · **Permanent**. CrowdSec has no ban without an end, so *permanent* is ten years and the page says so. The length
the form starts with is the *manual ban length* from Settings. A reason is optional and shows up in the list and in Discord.

The server refuses (and says why, in words):

| Refused | Why |
| --- | --- |
| your own address | it would lock you out of every site behind Traefik |
| this server's addresses, the home address DCS keeps allowed, addresses on the trusted list | the server would ban itself or the person managing it |
| private, loopback and link-local addresses | Traefik trusts your LAN, so such a ban could never block anything |
| networks wider than a /8 (IPv4) or /16 (IPv6) | a large part of the internet; a /8 to /15 is allowed after a confirmation that shows how many addresses it covers |
| an address on the allowlist | it is never banned: take it off the allowlist first |
| an address already banned for longer | lift that ban first if you want a shorter one |

A permanent ban and every bulk lift ask for confirmation. **Import** takes a list (one address or network per line with `#` comments, a CSV with a
header line `value,duration,reason`, or a JSON list of `{value, duration, reason}`), up to 2000 entries and 512 KB; every entry is checked like a
single ban and the ones that are skipped are listed with the line and the reason. **Export** downloads the (filtered) list as CSV or JSON;
cells that could be read as spreadsheet formulas are prefixed so they stay text.

Bans made by a scenario that is in *simulation mode* are marked **simulated**: they are alerts, and nothing enforces them.

## 4. Alerts

What CrowdSec detected: window (1 h · 6 h · 24 h · 7 d · 30 d), search, scenario, country, hide simulated. Each row says what it was in plain words, where it came from
(flag, network), how many requests added up, and whether the source is banned now. Open one to see the source, when it started
and stopped, what CrowdSec decided, and the requests that raised it (method, path, status, user agent, target). From there an admin can
**ban** the address, **allow it for good**, or jump to its bans.

## 5. Allowlist

Addresses CrowdSec must never ban. DCS uses the best mechanism your CrowdSec offers and tells you which:

* **Native allowlist** (CrowdSec 1.6.8 and newer, list name `dcs`): checked before every decision, also for manual bans; entries can expire (`30m`, `12h`,
  `7d`) and adding one lifts the bans it covers.
* **DCS whitelist parser** (older CrowdSec): a small parser file DCS writes; no expiry; needs a reload, which DCS does.

Your home public address is kept in the list automatically (*managed*, not removable here). The page shows the address you are
connecting from and whether it is covered, with one click to add it. Entries can be an address or a network; a network wider than a /16 asks
for confirmation.

## 6. Discord alerts

Every option of the Discord message is on the **Discord** tab. Nothing is hard-coded: the shipped message is only the default.

| Option | Default | What it does |
| --- | --- | --- |
| **On / off** | on when a webhook exists | send CrowdSec's decisions to Discord |
| **Webhook** | *Global* | *Global*: the webhook DCS uses for its own alerts. *Custom*: one just for CrowdSec (kept in the CrowdSec container's notification file; shown masked, never returned by the API). *Keep*: leave whatever the file has |
| **Name / avatar** | CrowdSec + the CrowdSec avatar | who the message appears from |
| **Embed colour** | automatic (by kind of attack) | or one fixed colour |
| **Mention** | nobody | a role, a user, `@here` or `@everyone`, plus extra text; a *test message never pings anyone* unless you tick it |
| **Which events notify** | new bans and simulated bans | and, optionally, detections that did not lead to a ban |
| **Filters** | none | minimum number of events; only these scenarios; ignore these scenarios |
| **Delivery** | wait 5 s, group at 10, retry 3×, 10 s timeout | how alerts are batched and retried |
| **Message** | see below | title, description, footer, link, timestamp, and up to 8 embed fields (name, value, inline) |

The message is text with placeholders like `{ip}`, `{country_tag}` or `{label}`; the editor has a picker that inserts them, a **live preview** that shows the embed as
Discord will draw it (rendered by the server with the same code that sends the real message, so what you see is what arrives), a sample selector (web probing,
SSH, exploit, manual ban, simulation), and **Send test message**, which really posts to the webhook and reports what Discord answered. The last test, the last
save and recent delivery errors are shown. **Reset to the shipped message** puts the default back and keeps the webhook and the on/off switch.

| Placeholder | Meaning |
| --- | --- |
| `{ip}` `{scope}` `{range}` | the address (or network), `Ip`/`Range`, the network it belongs to |
| `{country}` `{flag}` `{country_tag}` | country code, Discord flag emoji, " :flag_nl: NL" (empty when unknown) |
| `{as_number}` `{as_name}` `{as_tag}` | autonomous system number, who runs the network, " · Name" (empty when unknown) |
| `{scenario}` `{scenario_short}` `{label}` | full scenario name, without the `crowdsecurity/` prefix, and the plain-language attack type |
| `{events}` `{alert_id}` `{message}` `{sim_tag}` | number of log lines, CrowdSec's alert number and one-line summary, " (simulation)" |
| `{decision}` `{duration}` `{for_duration}` | ban, how long, " for 4h" |
| `{origin}` `{origin_tag}` | where the decision came from (detection or manual) |
| `{target}` `{target_tag}` `{path}` `{path_code}` `{user_agent}` | the site attacked, the first request's path and user agent |
| `{machine}` `{machine_tag}` `{domain}` `{server}` | the engine, your domain, this DCS server's name |
| `{time}` | Discord's live "x minutes ago" stamp |
| `{cti_url}` `{abuseipdb_url}` | the address on CrowdSec CTI and on AbuseIPDB |

User text never reaches the generated files as code: the message is compiled into string literals and variables for CrowdSec's template engine, so quotes, backslashes, `{{ }}`
and line breaks in a message can change nothing but the message. The webhook is admin-only and masked everywhere else. CrowdSec cannot announce a lifted ban; unbans made from DCS raise
the `crowdsec_unban` event for the *Notifications* page instead.

## 7. Settings: ban length, escalation, simulation

**How long CrowdSec bans** (the ban profile): the default length for an address (default **4 hours**), for a whole network, an optional **repeat-offender escalation** (each new ban
of the same address lasts longer than the last, up to a cap; default off, cap 30 days), **per-scenario lengths** (up to 12 rows: SSH brute force for a day, known exploits for a week; the
first matching row wins, a `*` at the end matches a prefix), and the length a manual ban gets when nobody chooses one. A sentence at the top says what the result is in plain words.

Saving is safe: DCS builds the new file, has **CrowdSec itself validate it** in a scratch directory of the container, backs the current file up, writes it, restarts CrowdSec, waits until it is
healthy and the local API answers, **reads the file back**, and if anything fails puts the previous file back and restarts again, telling you which step failed. One apply runs at a time.
If someone edited `profiles.yaml` by hand (*custom*), the page shows the file, and replaces it only after you confirm (a backup is kept). Backups are listed.

**The Traefik bouncer plugin** (the same tab; needs the bouncer registered). The plugin is the part inside Traefik that refuses banned visitors; these are its own
settings, written into its middleware file `crowdsec-bouncer.yml` with the same care as the ban profile (checked first, written atomically, the old file kept, a marker line
so registering the bouncer again or a re-deploy keeps them) - Traefik reloads the file by itself within seconds:

| Setting | Default | What it does |
| --- | --- | --- |
| **Mode** | live | *live*: Traefik asks CrowdSec about a visitor the first time it sees one and remembers the answer. *stream*: Traefik downloads the whole ban list every few seconds and decides on its own (a new ban reaches the door that many seconds later, and it keeps working for a while if CrowdSec is down) |
| **Update interval** | 60 s (10 s to 1 h) | stream only: how often the ban list is downloaded |
| **Remember an answer for** | 60 s (10 s to 1 h) | live only: how long an answer about a visitor is kept; shorter means a lifted ban is noticed sooner |
| **Timeout** | 10 s (1 to 60 s) | how long Traefik waits for CrowdSec before it gives up on one question |
| **Status a banned visitor gets** | 403 (400 to 599) | 403 forbidden is the usual one; 429 tells well-behaved clients to slow down |
| **Log level** | INFO | how much the plugin writes in Traefik's log |
| **Visitors that are never checked** | your LAN, your home address | `clientTrustedIPs`: the LAN of your Traefik (`TRAEFIK_TRUSTED_LAN`) is always in; *never check my home address* (on by default when you save) keeps the address DCS follows (dynamic DNS) in the list and moves it when it changes |
| **Proxies whose forwarded address is believed** | Cloudflare's ranges + your LAN | `forwardedHeadersTrustedIPs`: a CDN or proxy in front of Traefik. Only these may say who the real visitor is |

Only a safe subset is offered: the modes *none*, *alone* and *appsec* and the plugin's Redis and AppSec options stay in the file, untouched, for people who need
them. Networks wider than a /8 (IPv4) or /16 (IPv6) are refused in both lists: a list that says "trust everyone" would switch the bouncer off.

**Simulation mode**: scenarios that only alert and never ban, per scenario or for the whole engine (*watch only*, with a warning that nothing is blocked while it is on).

## 8. Hub

The hub is CrowdSec's library of **collections** (bundles), **scenarios** (attack detectors) and **parsers** (log readers). See what is installed and what has an update, install a suggested
bundle for a Traefik + SSH server (each with a sentence on what it does), search everything the hub offers, remove items (with a warning for the ones DCS's detection relies on),
**check for updates** and **upgrade all**. CrowdSec reloads after every change.

## 9. Bouncers, machines, community

* **Traefik enforcement**: is Traefik running, is the DCS bouncer registered, is its middleware file there, is it in Traefik's chain, when did it last pull. **Register the Traefik bouncer**
  makes a fresh key, writes the middleware file and adds it to the chain (safe to repeat: a chain that lists the middleware already is not touched; a new entry goes after
  `cloudflarewarp` or `real-ip` when the chain starts with one, because a bouncer that runs before them would judge Cloudflare's addresses instead of the visitor's; the file is
  rewritten in place, so a stack that bind-mounts it as a single file keeps seeing it).
* **Bouncers**: every program that enforces bans (Traefik's plugin, a firewall bouncer …): type, version, address, last pull. Add one (the API key is shown **once**, with a copy button)
  or delete one (its key stops working at once; deleting the Traefik one stops enforcement until it is registered again).
* **Machines**: the engines that report to this CrowdSec (this container's agent, others you enrolled).
* **Community**: whether the community blocklist is pulled, whether your detections are shared, whether the machine is enrolled in the CrowdSec Console.

## 10. Logs

The tail of the CrowdSec container's log: level (all / warnings / errors), text filter, 100–500 lines, an option to include the noisy API request lines, auto-refresh, copy and download.

## 11. Countries

The country of every ban and alert comes from CrowdSec's GeoIP and is shown everywhere as a flag (where your system draws flag emoji; otherwise a two-letter code chip) and the country name.
The overview ranks countries over 24 h, 7 d or 30 d, and the bans and alerts can be filtered by country. **There are no country-wide bans**: the Traefik bouncer enforces IP addresses and networks
only, so the page never offers one and says so.

## 12. Safety rails

* Viewers read everything but the webhook and the raw profile file; every change needs an admin. Each change is written to the audit log.
* Everything the API sends to Docker is a separate argument, never a shell string; addresses, names, durations and messages are validated before they get anywhere near a command or a file.
* Slow calls have timeouts and a short cache, so an open page adds almost no load; the page refreshes about every 15 s and pauses while the tab is hidden.
* Your own address, this server and the home address can never be banned from the page.

## 13. A VM through the hub

On a hub, the *Server* chips at the top of the page choose the hub or one VM; every call goes through the fleet proxy to that VM's own CrowdSec and its own DCS decides with its own role checks.

**The routes of your VMs are protected by the hub's bouncer.** A VM's service is published through the hub's Traefik (the hub writes the VM's routers into
`fleet-members.yml`), and every one of those routers gets the hub's `traefik-chain` (and `compress-gzip`), the chain that holds `crowdsec-bouncer` once the hub's bouncer
is registered. So the hub's CrowdSec decides for the traffic to a VM's services too: ban an address on the hub and it is refused at the hub's door, whichever VM it
was after. A VM that runs its own Traefik gets the same from its own chain. The routes list of DNS & Routes marks a route that does *not* use the chain (a hand-written
route file without `traefik-chain`) as **unprotected**, and the Protection panel counts them; on a hub without any chain (no Traefik template) a VM's routes have none
and read as unprotected too.

## API

Viewers may `GET` and may draw the Discord preview (it only renders, it never sends); changes need an admin. The generated reference is [docs/API.md](API.md); the CrowdSec routes:

| Route | What |
| --- | --- |
| `GET /crowdsec/status` | the state, the fixes, the numbers, the issues |
| `GET /crowdsec/decisions` · `POST` · `DELETE /crowdsec/decisions/{value}` · `POST …/delete` · `POST …/import` · `GET …/export` | bans |
| `GET /crowdsec/alerts` · `GET /crowdsec/alerts/{id}` | detections |
| `GET /crowdsec/metrics?window=24h\|7d\|30d` | timeline, countries, scenarios, sources, networks, map points |
| `GET /crowdsec/allowlist` · `POST` · `DELETE /crowdsec/allowlist/{value}` | never-ban list |
| `GET /crowdsec/bouncers` · `POST` · `DELETE …/{name}` · `POST …/register-traefik` · `GET /crowdsec/machines` | enforcement |
| `GET /crowdsec/settings` · `PUT` | ban profile |
| `GET /crowdsec/plugin` · `PUT` · `POST /crowdsec/traefik/restart` | the Traefik bouncer plugin's settings, and a Traefik restart (it loads a declared plugin only as it starts) |
| `GET /routes` | every route now says `crowdsec`: `protected`, `bypass` or `off` (CrowdSec is not set up on the proxy) |
| `GET /crowdsec/simulation` · `POST` | alert-only scenarios |
| `GET /crowdsec/notifications` · `PUT` · `POST …/preview` · `POST …/test` · `POST …/reset` | the Discord editor |
| `GET /crowdsec/hub` · `POST …/update` · `…/upgrade` · `…/install` · `…/remove` | the hub |
| `GET /crowdsec/logs` · `GET /crowdsec/community` · `POST /crowdsec/service` | log, community, start/restart/reload |

## 14. Troubleshooting

| Symptom | Look at |
| --- | --- |
| *Bans are not enforced at your proxy* | the banner's button registers the bouncer; Traefik needs the plugin in its static config (DCS adds it and restarts Traefik once if it is missing) |
| Every route behind Traefik answers 404 after a change | Overview → Protection → *How the bouncer is wired*: the plugin must be declared in Traefik's static configuration and Traefik restarted since (*Register again* declares it, *Restart Traefik* loads it); a key that is older than the bouncer makes the bouncer useless, not the routes 404 |
| A route is *unprotected* | it does not use `traefik-chain`: add the chain to the router's middlewares (the routes DCS writes do this by themselves), then reload |
| Bans exist but nothing is blocked | Overview → Protection: is the bouncer pulling? A bouncer that has never pulled means no request has gone through the middleware yet, or the middleware is not in the chain your services use |
| *Log lines: 0 read* | CrowdSec reads Traefik's access log from the shared logs folder; check Traefik writes it (`accessLog` in `traefik.yml`) and that the volume is mounted |
| You banned yourself | Dashboard → *Protection* card → **Unban me**, or lift the ban from the list; the guard normally prevents it |
| Discord stays silent | Discord tab: status card (*wired*, *plugin active*, *working*), **Send test message**, recent delivery errors; the webhook must be a `https://discord.com/api/webhooks/…` URL |
| A settings change failed | the page says which step; the previous file is put back automatically, so CrowdSec is never left on a bad file |
| CrowdSec restarts in a loop | Show the log: almost always a configuration error in a file that was edited by hand |
