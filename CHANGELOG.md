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

### Added

- `tests/smoke.sh`: 60+ checks that drive the request handler exactly as socat does, in an
  isolated temporary installation (no network, no Docker required for most checks).
- `tests/lint.sh` and a GitHub Actions workflow: `bash -n`, `shellcheck`, compose validation of
  every stack and template, the API reference freshness check and the smoke tests.
- `docs/API.md`: the complete endpoint reference (210 endpoints) generated from the router by
  `.scripts/api-docs.sh`, with access levels taken from the server's own policy.
- `SECURITY.md`, this changelog, a `VERSION` file (single source for the release version) and a
  plugin authoring guide in `.plugins/README.md`.
- `API_TRUSTED_PROXIES` and `API_INSECURE_NO_AUTH` settings; `GET /health/score/history` and
  `/metrics/history|summary` now have data; schedules accept `start`, `stop` and `maintenance`.

### Removed

- The accidentally committed duplicate template tree `.templates/.templates/` (215 stale files).
- Committed runtime history in `.api-auth/update-history.json` (now an empty template).
- Dead code: unused Homarr detection, the `if true` scaffolding around Authelia config, the
  Python fallbacks in the plugin handlers, the unused `wait_for_it` wrapper function.
