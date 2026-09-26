# Changelog

All notable changes to Docker Compose Skeleton AIO are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
