# Changelog

All notable changes to Docker Compose Skeleton AIO are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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

### Removed

- The accidentally committed duplicate template tree `.templates/.templates/` (215 stale files).
- Committed runtime history in `.api-auth/update-history.json` (now an empty template).
- Dead code: unused Homarr detection, the `if true` scaffolding around Authelia config, the
  Python fallbacks in the plugin handlers, the unused `wait_for_it` wrapper function.
