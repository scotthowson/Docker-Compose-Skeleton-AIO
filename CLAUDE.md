# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Docker Compose Skeleton All-In-One (AIO) is the batteries-included edition of DCS. It bundles the full DCS framework with [DCS-UI](https://github.com/scotthowson/Docker-Compose-Skeleton-UI) as a Docker container in `Stacks/core-infrastructure/`. Users run `./setup.sh` → the API + web UI start automatically → they complete setup at `http://localhost:3000`.

The base DCS framework is a portable, modular Docker service orchestration framework for managing multiple Compose stacks with dependency-ordered startup/shutdown, enhanced logging, NTFY push notifications, intelligent image updates, and a comprehensive suite of management utilities. It is a Bash-based framework (no build system, no tests) designed to be cloned and configured for any server by any user. All paths are auto-detected from the repository root.

### AIO-Specific Additions

- `Stacks/core-infrastructure/docker-compose.yml` — includes `dcs-ui` service (GHCR image, port 3000, host.docker.internal API proxy)
- `setup.sh` Step 7 — starts API server + core-infrastructure, waits for DCS-UI healthy, prints browser URL
- `.env.example` — defaults `API_ENABLED=true`, `API_BIND=0.0.0.0`, adds `DCS_UI_PORT=3000`
- `.templates/traefik/config/custom_routes/core-infrastructure/dcs-ui.yml` — Traefik route for HTTPS

## Architecture

### Execution Flow

```
./start.sh (entry point)
  -> auto-detects BASE_DIR from script location (BASH_SOURCE)
  -> loads root .env (user configuration)
  -> sources .config/settings.cfg (config + color detection + validation)
  -> sources .lib/docker-utils.sh (detects docker compose v1 vs v2)
  -> sources .lib/logger.sh (initializes logging system v3.0)
  -> sources .lib/banner.sh (ASCII art banners)
  -> sources .scripts/run.sh, update.sh, update_all_stacks.sh, clean-up.sh
  -> sources .scripts/health-check.sh, system-info.sh (optional)
  -> main():
       1. verify_environment() — checks docker, compose, base dirs
       2. initiate_docker_update() — auto-updates docker-compose binary (v1 only)
       3. cleanup_docker_services() — removes unreferenced resources
       4. start_docker_services() — starts all 10 stacks with progress bars + timing
       5. update_all_stacks() — pulls images, detects changes via SHA256, rolling updates
       6. run_health_check() — comprehensive container health check with formatted table
```

`./stop.sh` mirrors this with `show_shutdown_banner`, `stop_docker_services()` (reverse order), post-shutdown verification, and `show_completion_banner`.

`./restart.sh` runs stop followed by start.

`./status.sh` displays container status across all stacks (standalone, no logger dependency).

### Source Dependency Chain

All scripts assume these are sourced first (in order):
1. Root `.env` — user configuration (loaded via `set -a; source .env; set +a`)
2. `.config/settings.cfg` — exports `LOG_LEVEL`, `ENABLE_COLORS`, `LOG_FILE`, all feature flags
3. `.config/palette.sh` — sourced internally by `logger.sh`, provides `COLOR_PALETTE` associative array
4. `.lib/docker-utils.sh` — detects Docker Compose version, sets `DOCKER_COMPOSE_CMD`
5. `.lib/logger.sh` — must call `initiate_logger` after sourcing; provides all `log_*` functions
6. `.lib/banner.sh` — ASCII art banners (optional, loaded via `_source_optional`)

Scripts in `.scripts/` and `.lib/` are **libraries** (sourced, not executed directly). They rely on `log_*` functions and `$COMPOSE_DIR`/`$BASE_DIR` being set by the caller.

### Stack Management

10 service categories under `Stacks/`, each with `docker-compose.yml` + `.env`:

**Startup order:** core-infrastructure -> networking-security -> monitoring-management -> development-tools -> media-services -> web-applications -> storage-backup -> communication-collaboration -> entertainment-personal -> miscellaneous-services

**Shutdown order:** exact reverse of startup.

### Logger System (v3.0)

`.lib/logger.sh` (1200+ lines) provides 50+ log functions:

**Core:** `log_info`, `log_success`, `log_warning`, `log_error`, `log_debug`, `log_critical`
**Extended:** `log_info_header`, `log_focus`, `log_highlight`, `log_alert`, etc.
**Variants:** `log_bold_*`, `log_nodate_*`, `log_bold_nodate_*`
**Advanced:** `log_progress`, `log_step`, `log_timer_start/stop`, `log_table`, `log_banner`, `log_keyvalue`, `log_separator`
**Tracking:** `LOG_ERROR_COUNT`, `LOG_WARNING_COUNT`, `LOG_ENTRY_COUNT` (auto-incremented)

### Management Utilities

Standalone scripts in `.scripts/` with their own color setup and `--help`:
- `stack-manager.sh` — CLI for individual stacks (start/stop/restart/status/logs/pull/list/running)
- `health-check.sh` — Container health monitoring with formatted tables
- `config-validator.sh` — Validates config, directories, compose syntax, ports, system requirements
- `maintenance.sh` — Cleanup, disk analysis, orphan detection, log rotation (report/disk/prune/deep-prune/orphans/log-rotate)
- `docker-network-info.sh` — Network visualization with tree-style container connections
- `image-tracker.sh` — Image age tracking and staleness detection
- `system-info.sh` — Docker and system resource information
- `logs-viewer.sh` — Interactive log viewer with filtering and search

## Key Commands

```bash
./start.sh                          # Full startup sequence
./stop.sh                           # Graceful shutdown
./stop.sh --force                   # Force stop (5s timeout)
./restart.sh                        # Stop + Start
./status.sh                         # Container status
./setup.sh                          # First-run setup
./start.sh --debug                  # Debug mode
LOG_LEVEL=DEBUG ./start.sh          # Runtime override

# Management utilities
.scripts/stack-manager.sh list      # List all stacks
.scripts/maintenance.sh             # System report
.scripts/config-validator.sh --fix  # Validate & fix config
.scripts/docker-network-info.sh     # Network map
.scripts/image-tracker.sh           # Check image freshness
```

There are no tests, no linter, and no CI pipeline.

## Shell Conventions

- Bash 4+ required (associative arrays, `declare -gA`, `${var,,}`)
- Functions prefixed with `_` are private/internal
- All scripts use `#!/bin/bash` shebang
- Config uses `${VAR:-default}` pattern extensively
- `export -f` shares functions across sourced scripts
- Color output respects `$ENABLE_COLORS` and `$COLOR_MODE` (auto/always/never)
- `BASE_DIR` is auto-detected via `BASH_SOURCE` — never hardcoded
- Standalone utilities detect their own `BASE_DIR` relative to script location
- Each standalone script has its own color palette (prefixed `_XX_*` to avoid conflicts)

## Configuration Hierarchy

1. **Defaults** in `.config/settings.cfg` (every setting has a `${VAR:-default}`)
2. **Root `.env`** — user-facing configuration (created by `setup.sh` from `.env.example`)
3. **Environment overrides** via `$ENVIRONMENT` variable (development/testing/staging/production)
4. **Per-stack** `.env` files in each `Stacks/<category>/` directory
5. **Runtime** environment variables override everything (e.g., `LOG_LEVEL=DEBUG ./start.sh`)

## File Reference

### Entry Points (executable)
- `start.sh` — Full startup sequence with banners, progress, health check
- `stop.sh` — Graceful shutdown with progress bars, verification, cleanup report
- `restart.sh` — Stop then start wrapper
- `status.sh` — Container status viewer (standalone, no logger)
- `setup.sh` — First-run setup

### Libraries (`.lib/`, sourced)
- `logger.sh` — Enhanced logging system v3.0
- `banner.sh` — ASCII art banners (startup/shutdown/completion/mini)
- `docker-utils.sh` — Docker Compose version detection
- `helpers.sh`, `environment.sh`, `error_handling.sh`, `debugger.sh`

### Core Scripts (`.scripts/`, sourced by entry points)
- `run.sh` — Service startup with progress, timers, summary tables
- `stop.sh` — Service shutdown with progress, timers, summary tables
- `update.sh`, `update_all_stacks.sh`, `clean-up.sh`
- `ntfy-status.sh`, `ntfy-status-stop.sh`, `ntfy-status-restart.sh`
- `backup-server.sh`, `wait-for-it.sh`

### Standalone Utilities (`.scripts/`, directly executable)
- `stack-manager.sh` — Individual stack management CLI
- `health-check.sh` — Container health monitoring
- `config-validator.sh` — Configuration validation
- `maintenance.sh` — Docker maintenance & cleanup
- `docker-network-info.sh` — Network visualization
- `image-tracker.sh` — Image update tracking
- `system-info.sh` — System information
- `logs-viewer.sh` — Log viewer with filtering
