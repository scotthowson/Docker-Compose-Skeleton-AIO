#!/bin/bash
# =============================================================================
# Docker Compose Skeleton — Start Script (Main Entry Point)
#
# Orchestrates the full startup sequence:
#   1. Environment verification       4. Service startup (dependency order)
#   2. Docker Compose updates          5. Intelligent image updates
#   3. Orphaned resource cleanup       6. Post-startup health check
#
# Usage:  ./start.sh [--help] [--debug]
# =============================================================================

# =============================================================================
# PATH AUTO-DETECTION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$SCRIPT_DIR"
export BASE_DIR

# Load root .env before anything else (provides APP_DATA_DIR, NTFY_URL, etc.)
if [[ -f "$BASE_DIR/.env" ]]; then
    set -a
    source "$BASE_DIR/.env"
    set +a
fi

COMPOSE_DIR="$BASE_DIR/Stacks"
# Data lives per stack (Stacks/<name>/App-Data, the ./App-Data default in
# .env); a relative value must never be resolved against the caller's $PWD
APP_DATA_DIR="${APP_DATA_DIR:-./App-Data}"
[[ "$APP_DATA_DIR" == /* ]] || APP_DATA_DIR="$BASE_DIR/${APP_DATA_DIR#./}"
export COMPOSE_DIR APP_DATA_DIR

# Set TERM if unset (for systemd / cron execution)
[[ -z "${TERM:-}" ]] && export TERM=xterm-256color

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

DEBUG_REQUESTED=false
BOOT_MODE=false
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)   SHOW_HELP=true; shift ;;
        --debug|-d)  DEBUG_REQUESTED=true; shift ;;
        --boot)      BOOT_MODE=true; shift ;;
        *)
            echo "Unknown option: $1"
            echo "Run './start.sh --help' for usage."
            exit 1
            ;;
    esac
done

# Unattended boot (systemd): quiet output, never stop on one failed stack, and
# reconcile the reverse proxy once every stack has been started.
if [[ "$BOOT_MODE" == "true" ]]; then
    export SHOW_BANNERS=false CONTINUE_ON_FAILURE=true DCS_BOOT=true
fi

if [[ "$SHOW_HELP" == "true" ]]; then
    cat <<'EOF'
Docker Compose Skeleton — Start

Usage: ./start.sh [OPTIONS]

Starts all Docker Compose service stacks in dependency order with
optional image updates, cleanup, and health monitoring.

OPTIONS:
  --help, -h     Show this help message and exit
  --debug, -d    Enable debug-level logging and bash trace
  --boot         Unattended mode for the systemd unit: no banners, keep going on
                 failures, verify Traefik's routes afterwards (restart it once
                 when they are dead)

STARTUP SEQUENCE:
  1. Verify environment (Docker, directories)
  2. Update Docker Compose binary (v1 only — v2 is package-managed)
  3. Clean up orphaned volumes/images
  4. Start all stacks in dependency order
  5. Pull and apply image updates (intelligent SHA256 detection)
  6. Post-startup container health check

CONFIGURATION (.env):
  SKIP_HEALTHCHECK_WAIT=true    Skip waiting for healthchecks (faster startup)
  CONTINUE_ON_FAILURE=true      Don't abort if a stack fails
  SHOW_BANNERS=true             Show the startup banner (false for cron/headless)
  SHOW_SYSTEM_INFO=false        Show system info on startup
  API_ENABLED=true              Start the REST API / web UI backend (AIO default)

ENVIRONMENT OVERRIDES:
  LOG_LEVEL=DEBUG ./start.sh    Override log level
  ENVIRONMENT=development       Set environment profile

EOF
    exit 0
fi

# Apply debug mode early so settings.cfg picks it up
if [[ "$DEBUG_REQUESTED" == "true" ]]; then
    export LOG_LEVEL="DEBUG"
    export DEBUG_MODE="true"
fi

# =============================================================================
# CONFIGURATION AND LOGGER INITIALIZATION
# =============================================================================

# Suppress palette validation noise during init
export PALETTE_QUIET=true

# Source settings (provides LOG_LEVEL, colors, feature flags)
source "$BASE_DIR/.config/settings.cfg"

# Source Docker utilities and detect compose command
source "$BASE_DIR/.lib/docker-utils.sh"
if ! _detect_docker_compose; then
    echo "FATAL: No Docker Compose installation found. Aborting." >&2
    exit 1
fi

# Source and initialize the logger
source "$BASE_DIR/.lib/logger.sh"
initiate_logger
export LOGGER_INITIALIZED=true

# Re-enable palette warnings
unset PALETTE_QUIET

# =============================================================================
# SCRIPT LIBRARY IMPORTS
# =============================================================================

# Required: service startup
source "$BASE_DIR/.scripts/run.sh"

# Optional libraries (graceful skip if missing)
# _source_optional is provided by docker-utils.sh
_source_optional "$BASE_DIR/.lib/banner.sh"                  "banner.sh"
_source_optional "$BASE_DIR/.lib/environment.sh"             "environment.sh"
_source_optional "$BASE_DIR/.scripts/update.sh"              "update.sh"
_source_optional "$BASE_DIR/.scripts/update_all_stacks.sh"   "update_all_stacks.sh"
_source_optional "$BASE_DIR/.scripts/clean-up.sh"            "clean-up.sh"
_source_optional "$BASE_DIR/.scripts/ntfy-status.sh"         "ntfy-status.sh"
_source_optional "$BASE_DIR/.scripts/health-check.sh"        "health-check.sh"
_source_optional "$BASE_DIR/.scripts/system-info.sh"         "system-info.sh"

# v2.0 subsystem libraries
_source_optional "$BASE_DIR/.lib/metrics.sh"                 "metrics.sh"
_source_optional "$BASE_DIR/.lib/rollback.sh"                "rollback.sh"
_source_optional "$BASE_DIR/.lib/secrets.sh"                 "secrets.sh"
_source_optional "$BASE_DIR/.lib/scheduler.sh"               "scheduler.sh"
_source_optional "$BASE_DIR/.lib/health-score.sh"            "health-score.sh"
_source_optional "$BASE_DIR/.lib/plugins.sh"                 "plugins.sh"
_source_optional "$BASE_DIR/.lib/sse.sh"                     "sse.sh"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Set the terminal title (non-fatal if not supported)
_set_terminal_title() {
    echo -ne "\033]0;${1:-Docker Services Manager}\007" 2>/dev/null || true
}

# Verify that the Docker environment is ready
_verify_environment() {
    log_info "Verifying Docker environment..."

    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running or not accessible"
        return 1
    fi

    if [[ -z "${DOCKER_COMPOSE_CMD:-}" ]]; then
        log_error "Docker Compose command is not set"
        return 1
    fi

    if [[ ! -d "$COMPOSE_DIR" ]]; then
        log_error "Stacks directory not found: $COMPOSE_DIR"
        return 1
    fi

    # Only a shared, absolute App-Data location is created here; the per-stack
    # directories are created by setup.sh and the deploy flow
    if [[ "${APP_DATA_DIR}" != "$BASE_DIR/App-Data" && ! -d "$APP_DATA_DIR" ]]; then
        mkdir -p "$APP_DATA_DIR"
        log_info "Created App-Data directory: $APP_DATA_DIR"
    fi

    log_keyvalue "Docker" "$(docker --version 2>/dev/null | sed 's/Docker version /v/' | cut -d, -f1)"
    log_keyvalue "Compose" "$(_docker_compose_version_string)"
    log_success "Environment verification passed"
    return 0
}

# Graceful exit handler
_graceful_exit() {
    local exit_code="${1:-1}"
    log_warning "Script interrupted (exit code: $exit_code)"
    close_logger
    exit "$exit_code"
}

# =============================================================================
# ERROR HANDLING
# =============================================================================

trap '_graceful_exit $?' ERR
trap '_graceful_exit 130' INT TERM

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    local total_steps=6
    local exit_status=0

    # ── Startup Banner ────────────────────────────────────────────────
    if [[ "${SHOW_BANNERS:-${SHOW_STARTUP_BANNER:-true}}" == "true" ]] && command -v show_startup_banner >/dev/null 2>&1; then
        show_startup_banner
    else
        log_banner "DOCKER SERVICES MANAGER" "Startup Sequence — v${SCRIPT_VERSION:-2.0.0}"
    fi

    # ── Session Metadata ──────────────────────────────────────────────
    log_separator "-" 60
    log_keyvalue "User"            "$(whoami)"
    log_keyvalue "Hostname"        "$(hostname)"
    log_keyvalue "Base Dir"        "$BASE_DIR"
    log_keyvalue "Stacks Dir"      "$COMPOSE_DIR"
    log_keyvalue "App Data"        "$APP_DATA_DIR"
    log_keyvalue "Environment"     "${ENVIRONMENT:-production}"
    log_keyvalue "Log Level"       "${LOG_LEVEL:-INFO}"
    log_keyvalue "Compose"         "$DOCKER_COMPOSE_CMD"
    log_keyvalue "Healthcheck Wait" "$([[ "${SKIP_HEALTHCHECK_WAIT:-false}" == "true" ]] && echo "Disabled" || echo "Enabled")"
    log_keyvalue "On Failure"      "$([[ "${CONTINUE_ON_FAILURE:-true}" == "true" ]] && echo "Continue" || echo "Abort")"
    log_keyvalue "Volumes on Stop" "$([[ "${REMOVE_VOLUMES_ON_STOP:-false}" == "true" ]] && echo "Remove" || echo "Preserve")"
    log_keyvalue "Notifications"   "$([[ -n "${NTFY_URL:-}" ]] && echo "Enabled" || echo "Disabled")"
    log_keyvalue "Started at"      "$(date '+%Y-%m-%d %H:%M:%S')"
    log_separator "-" 60

    # ── Optional System Info ──────────────────────────────────────────
    if [[ "${SHOW_SYSTEM_INFO:-false}" == "true" ]] && command -v show_system_info >/dev/null 2>&1; then
        show_system_info
    fi

    _set_terminal_title "${APPLICATION_TITLE:-Docker Services Manager}"

    # ── Master Timer ──────────────────────────────────────────────────
    log_timer_start "full_startup"

    # Enable bash trace in debug mode
    if [[ "${DEBUG_MODE:-false}" == "true" ]]; then
        log_debug "Debug mode active — enabling bash trace"
        set -x
    fi

    # ══════════════════════════════════════════════════════════════════
    # Step 1: Verify Environment
    # ══════════════════════════════════════════════════════════════════
    log_step 1 "$total_steps" "Verifying Docker environment"
    # Secrets store first: stacks may reference ${SECRETS_*} when they start
    if command -v secrets_init >/dev/null 2>&1; then
        secrets_init && log_debug "Secrets store ready"
    fi

    if ! _verify_environment; then
        log_error "Environment verification failed — aborting"
        _graceful_exit 1
    fi

    # Run tool verification (curl, docker, jq, socat, ncat) if available
    if command -v verify_environment >/dev/null 2>&1; then
        verify_environment
    fi

    # ══════════════════════════════════════════════════════════════════
    # REST API server — the backend of the web UI, so it comes up first.
    # A running instance is left alone; a stale PID file is cleaned up.
    # ══════════════════════════════════════════════════════════════════
    if [[ "${API_ENABLED:-true}" == "true" ]]; then
        local api_script="$BASE_DIR/.scripts/api-server.sh"
        local api_pid_file="$BASE_DIR/.data/api-server.pid"
        if [[ -x "$api_script" ]]; then
            if [[ -f "$api_pid_file" ]] && kill -0 "$(cat "$api_pid_file" 2>/dev/null)" 2>/dev/null; then
                log_info "REST API server already running (PID $(cat "$api_pid_file"))"
            else
                "$api_script" --stop >/dev/null 2>&1 || true
                log_info "Starting REST API server on ${API_BIND:-127.0.0.1}:${API_PORT:-9876}..."
                if "$api_script" --daemon --port "${API_PORT:-9876}" --bind "${API_BIND:-127.0.0.1}" >/dev/null; then
                    log_success "REST API server started (daemon mode)"
                else
                    log_warning "REST API server failed to start — see logs/api-server.log"
                    exit_status=1
                fi
            fi
        else
            log_warning "API_ENABLED=true but api-server.sh not found or not executable at: $api_script"
        fi
    fi

    # ══════════════════════════════════════════════════════════════════
    # Step 2: Update Docker Compose Binary
    # ══════════════════════════════════════════════════════════════════
    log_step 2 "$total_steps" "Updating Docker Compose"
    if command -v initiate_docker_update >/dev/null 2>&1; then
        initiate_docker_update
    else
        log_info "Docker Compose update function not available, skipping"
    fi

    # ══════════════════════════════════════════════════════════════════
    # Step 3: Clean Up Docker Resources
    # ══════════════════════════════════════════════════════════════════
    log_step 3 "$total_steps" "Cleaning up Docker resources"
    if command -v cleanup_docker_services >/dev/null 2>&1; then
        cleanup_docker_services
    else
        log_info "Cleanup function not available, skipping"
    fi

    # ══════════════════════════════════════════════════════════════════
    # Step 4: Start Docker Services
    # ══════════════════════════════════════════════════════════════════
    log_step 4 "$total_steps" "Starting Docker service stacks"

    if [[ "${SKIP_HEALTHCHECK_WAIT:-false}" == "true" ]]; then
        log_note "Healthcheck wait: DISABLED — containers start without waiting for health"
    fi

    if ! start_docker_services; then
        log_warning "Service startup completed with some failures (see summary above)"
        exit_status=1
    fi

    # ══════════════════════════════════════════════════════════════════
    # Step 5: Update Docker Stacks (Pull Latest Images)
    # ══════════════════════════════════════════════════════════════════
    log_step 5 "$total_steps" "Pulling and applying image updates"
    if command -v update_all_stacks >/dev/null 2>&1; then
        if ! update_all_stacks; then
            log_warning "Some stacks failed to update, but continuing"
            [[ "${CONTINUE_ON_FAILURE:-true}" == "true" ]] || exit_status=1
        fi
    else
        log_info "Stack update function not available, skipping"
    fi

    # ══════════════════════════════════════════════════════════════════
    # Step 6: Post-Startup Health Check
    # ══════════════════════════════════════════════════════════════════
    log_step 6 "$total_steps" "Running post-startup health check"

    if [[ "${ENABLE_POST_STARTUP_HEALTH_CHECK:-true}" == "true" ]]; then
        local health_delay="${HEALTH_CHECK_DELAY:-10}"
        log_info "Waiting ${health_delay}s for services to stabilize..."
        sleep "$health_delay"

        if command -v run_health_check >/dev/null 2>&1; then
            run_health_check
        elif command -v check_containers_status >/dev/null 2>&1; then
            check_containers_status
        else
            log_info "No health check function available, skipping"
        fi
    else
        log_info "Post-startup health check disabled"
    fi

    # ══════════════════════════════════════════════════════════════════
    # Reverse proxy reconciliation (boot mode, or PROXY_RECONCILE=true)
    # After a power loss Traefik can come up before its plugins, its socket
    # proxy or the services exist and then serve 404s until restarted. Probe
    # the routes through Traefik and restart it once when they are dead.
    # ══════════════════════════════════════════════════════════════════
    if [[ "${BOOT_MODE:-false}" == "true" || "${PROXY_RECONCILE:-false}" == "true" ]] && [[ -x "$BASE_DIR/.scripts/proxy-reconcile.sh" ]]; then
        log_info "Verifying reverse proxy routes..."
        local _pr_out _pr_rc=0
        _pr_out=$("$BASE_DIR/.scripts/proxy-reconcile.sh" --wait "${PROXY_RECONCILE_WAIT:-15}" 2>&1) || _pr_rc=$?
        case "$_pr_rc" in
            0) log_success "Reverse proxy routes verified: ${_pr_out##*: }" ;;
            2) log_info "Reverse proxy check skipped: ${_pr_out##*: }" ;;
            *) log_warning "Reverse proxy routes still failing after a restart: ${_pr_out##*: }"; exit_status=1 ;;
        esac
    fi

    # ══════════════════════════════════════════════════════════════════
    # Optional: Initialize v2.0 Subsystems
    # ══════════════════════════════════════════════════════════════════

    # Plugin system
    if [[ "${PLUGINS_ENABLED:-true}" == "true" ]] && command -v plugins_init >/dev/null 2>&1; then
        plugins_init
        plugins_scan
        log_success "Plugin system initialized"
    fi

    # Metrics history, schedules and automations run inside the API server
    # (see .scripts/api-server.sh); the standalone daemons are no longer started.

    # ── Disable debug trace ───────────────────────────────────────────
    { set +x; } 2>/dev/null

    # ── Stop Master Timer ─────────────────────────────────────────────
    log_timer_stop "full_startup"

    # ── Completion ────────────────────────────────────────────────────
    if [[ "${SHOW_BANNERS:-${SHOW_STARTUP_BANNER:-true}}" == "true" ]] && command -v show_completion_banner >/dev/null 2>&1; then
        if [[ $exit_status -eq 0 ]]; then
            show_completion_banner "success" "All operations completed successfully"
        else
            show_completion_banner "warning" "Startup finished with failures (see above)"
        fi
    else
        log_separator "=" 60 "STARTUP COMPLETE" "$([[ $exit_status -eq 0 ]] && echo SUCCESS || echo WITH FAILURES)"
        log_success "All operations completed at: $(date '+%Y-%m-%d %H:%M:%S')"
    fi

    # Close the logger (writes session summary) and report the real outcome
    close_logger
    return "$exit_status"
}

# =============================================================================
# RUN
# =============================================================================

main "$@"
exit $?
