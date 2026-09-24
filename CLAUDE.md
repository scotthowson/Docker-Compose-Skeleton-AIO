# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Project overview

Docker Compose Skeleton All-In-One (AIO) is the batteries-included edition of DCS: the Bash
orchestration framework plus the web UI ([DCS-UI](https://github.com/scotthowson/Docker-Compose-Skeleton-UI))
as a container in `Stacks/core-infrastructure/`. `./setup.sh` creates `.env`, checks Docker, starts
the REST API on port 9876 and the core stack (Redis + DCS-UI on port 3000), and the user finishes
setup in the browser. Everything is Bash 4+, Docker Compose v2 and jq; there is no build step.
Paths are derived from the repository root at runtime, never hard-coded.

Release version lives in `VERSION` (read by `.config/settings.cfg` and the API); the API protocol
version is `API_VERSION` in `.scripts/api-server.sh`. `CHANGELOG.md` is kept per release.

## Layout

| Path | Role |
|------|------|
| `setup.sh`, `start.sh`, `stop.sh`, `restart.sh`, `status.sh` | entry points (executable) |
| `.config/settings.cfg`, `.config/palette.sh` | defaults for every setting, color detection |
| `.lib/` | sourced libraries: `logger.sh`, `banner.sh`, `docker-utils.sh`, `helpers.sh`, `environment.sh`, `error_handling.sh`, `debugger.sh`, `metrics.sh`, `scheduler.sh`, `secrets.sh`, `sse.sh`, `health-score.sh`, `plugins.sh`, `rollback.sh` |
| `.scripts/api-server.sh` | the REST API (router `handle_request`, handlers `handle_*`) |
| `.scripts/api-docs.sh` | generates `docs/API.md` and the `GET /` catalogue from the router |
| `.scripts/run.sh`, `stop.sh`, `update.sh`, `update_all_stacks.sh`, `clean-up.sh`, `ntfy-status*.sh` | sourced by the entry points |
| `.scripts/*.sh` (others) | standalone utilities with `--help` |
| `Stacks/<category>/` | ten stacks, each `docker-compose.yml` + `.env` |
| `.templates/<name>/` | 103 templates: `docker-compose.yml`, `template.json`, optional `config/` |
| `.plugins/<name>/` | plugins: `plugin.json`, `hooks/`, `cards/` (see `.plugins/README.md`) |
| `.api-auth/`, `.data/`, `.secrets/`, `logs/` | runtime state written by the API (git-ignored except the JSON templates in `.api-auth/`) |
| `tests/` | `lint.sh`, `smoke.sh` |
| `docs/API.md` | generated endpoint reference — never edit by hand |

## Execution flow

```
./start.sh
  -> BASE_DIR from BASH_SOURCE; loads .env (set -a; source), .config/settings.cfg,
     .lib/docker-utils.sh, .lib/logger.sh (initiate_logger), .lib/banner.sh, .scripts/*.sh
  -> main(): verify environment (+ optional tool install offer from .lib/environment.sh)
             start the API if API_ENABLED (leaves a running instance alone)
             cleanup_docker_services (unreferenced App-Data dirs, prompt only on a TTY)
             start_docker_services in stack order, update_all_stacks, run_health_check
     exit status reflects failures.
./stop.sh    stops stacks in reverse order, then the API; finds leftover containers by compose label.
./status.sh  standalone, honours DOCKER_STACKS.
```

Stack order: `core-infrastructure → networking-security → monitoring-management → development-tools →
media-services → web-applications → storage-backup → communication-collaboration →
entertainment-personal → miscellaneous-services`. Shutdown is the exact reverse.

Source order for anything that uses the logger: `.env` → `settings.cfg` → `docker-utils.sh` →
`logger.sh` (`initiate_logger`) → `banner.sh`. Libraries assume `BASE_DIR`, `COMPOSE_DIR` and the
`log_*` functions exist.

## The API server

- **Process model** — `socat`/`ncat` listens and forks `api-server.sh --handle-request` per
  connection; the handler reads the HTTP request from stdin and writes the response to stdout.
  `start_server` supervises the listener in the background so SIGTERM (`--stop`, `stop.sh`,
  systemd) tears it down cleanly.
- **Configuration once, in the parent** — `_api_resolve_auth_policy` decides the effective bind,
  port and auth mode after argument parsing and exports them as `DCS_API_EFFECTIVE_*`;
  `DOCKER_COMPOSE_CMD` is exported too. Handlers must not re-derive these.
- **Auth is mandatory off loopback.** `API_AUTH_ENABLED=false` only works on a loopback bind unless
  `API_INSECURE_NO_AUTH=true`. Until the first admin exists (`SETUP_MODE`), `_api_check_auth`
  admits only the setup endpoints and `GET /version`.
- **Roles are decided in one place**: `_api_route_allowed METHOD PATH`. Admins pass everything; the
  `user` role is a viewer (reads plus its own session/profile/2FA and validation endpoints).
  Add new mutating or secret-exposing routes as admin-only there; keep per-handler checks as
  defence in depth.
- **`.env` is data.** `_api_load_env_file` parses `KEY=value` lines and skips
  `_API_ENV_RESERVED_KEYS`; never `source` it in the API. Writes go through
  `_api_validate_env_content` / `_api_validate_env_kv`.
- **Validate every path parameter in the router** with the `_api_validate_*` helpers (stack,
  container, template, image reference, snapshot name/id, subdomain, schedule target, version id)
  before calling a handler.
- **JSON** — jq is a hard dependency. Build JSON and jq filters with `--arg`/`--argjson`, never by
  interpolating user data into a filter or a Python program. Update JSON files atomically with
  `_api_jq_update_file FILE [jq opts] FILTER` (tmp + flock + mv). Escape strings with
  `_api_json_escape`; answer with `_api_success` / `_api_error`.
- **Secrets** go to child processes through the environment (`DCS_PW`, `DCS_SALT`, ...), never on a
  command line. Secret-bearing files are written with `umask 077`.
- **Background work must be detached**: `( ... ) </dev/null >/dev/null 2>&1 &`. Anything left
  attached to stdout holds the client connection open or corrupts the response.
- **Plugin hooks** run through `_plugin_exec_hook` with `env -i`, a 30 s timeout and bounded
  output, only when `plugin.json` says `"enabled": true`.
- **Route documentation** — put `# METHOD /path — description` on the line above each handler.
  `.scripts/api-docs.sh` reads those comments, the router and `_api_route_allowed` to produce
  `docs/API.md` and the catalogue embedded in `handle_root`. Run it after any route change;
  `--check` fails CI when either is stale.

## Tests and linting

```bash
tests/lint.sh                 # bash -n, shellcheck -S warning, compose config for stacks + templates, JSON, api-docs --check
tests/smoke.sh                # 60+ checks: drives --handle-request over stdin in a temp installation
.scripts/api-docs.sh --check  # reference and GET / catalogue up to date
./setup.sh --dry-run
```

`.github/workflows/ci.yml` runs all of the above. `tests/smoke.sh` needs no network; the
Docker-backed checks are skipped when Docker is unavailable. Keep both suites green before a
commit that touches `.scripts/api-server.sh`.

## Key commands

```bash
./start.sh                          # full startup (add --debug for bash tracing)
./stop.sh [--force]                 # graceful shutdown
./status.sh                         # container status
./setup.sh [--dry-run] [--verbose]  # first-run setup
LOG_LEVEL=DEBUG ./start.sh          # runtime override of any setting

.scripts/api-server.sh --bind 0.0.0.0   # API in the foreground; --stop to stop
.scripts/install-service.sh             # systemd unit
.scripts/stack-manager.sh list          # single-stack CLI
.scripts/config-validator.sh --fix      # validate & repair configuration
.scripts/maintenance.sh                 # cleanup and disk report
```

## Shell conventions

- `#!/bin/bash`, Bash 4+ features are fine (associative arrays, `${var,,}`, `mapfile`).
- `set -euo pipefail` at the top of executables; the API switches to `set +e` while handling a
  request and checks return codes explicitly.
- Private functions are prefixed with `_`; per-script color variables are prefixed (`_XX_*`) to
  avoid clashes; color output honours `ENABLE_COLORS` / `COLOR_MODE`.
- Every setting has a `${VAR:-default}` in `.config/settings.cfg`; precedence is defaults →
  `.env` → `$ENVIRONMENT` profile → per-stack `.env` → runtime environment.
- Use `mktemp` + `mv` for file rewrites, `sed -i` only with anchored patterns, `read -r`, quoted
  expansions, and `mapfile`/`read -a` instead of `=( $(...) )`.
- `shellcheck -S warning -e SC1090,SC1091` must be clean for every script (`tests/lint.sh`).
- Portable tooling: the host `awk` may be mawk (no `match(s, re, arr)`), so use jq for JSON and
  keep awk to simple field handling.
- Commit on a release branch; the default branch is `main`. Do not push without being asked.
