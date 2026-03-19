#!/bin/bash
# =============================================================================
# Docker Compose Skeleton — Stop Script (Graceful Shutdown)
#
# Orchestrates the full shutdown sequence:
#   1. Environment verification       3. Post-shutdown verification
#   2. Service shutdown (reverse)     4. Resource cleanup report
#
# Usage:  ./stop.sh [--help] [--debug] [--force]
# =============================================================================

# =============================================================================
# PATH AUTO-DETECTION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$SCRIPT_DIR"
export BASE_DIR

# Load root .env before anything else (provides REMOVE_VOLUMES_ON_STOP, NTFY_URL, etc.)
if [[ -f "$BASE_DIR/.env" ]]; then
    set -a
    source "$BASE_DIR/.env"
    set +a
fi

COMPOSE_DIR="$BASE_DIR/Stacks"
APP_DATA_DIR="${APP_DATA_DIR:-$BASE_DIR/App-Data}"
export COMPOSE_DIR APP_DATA_DIR

# Set TERM if unset (for systemd / cron execution)
[[ -z "${TERM:-}" ]] && export TERM=xterm-256color

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

DEBUG_REQUESTED=false
SHOW_HELP=false
FORCE_STOP=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)   SHOW_HELP=true; shift ;;
        --debug|-d)  DEBUG_REQUESTED=true; shift ;;
        --force|-f)  FORCE_STOP=true; shift ;;
        *)
            echo "Unknown option: $1"
            echo "Run './stop.sh --help' for usage."
            exit 1
            ;;
    esac
done

if [[ "$SHOW_HELP" == "true" ]]; then
    cat <<'EOF'
Docker Compose Skeleton — Stop

Usage: ./stop.sh [OPTIONS]

Stops all Docker Compose service stacks in reverse dependency order
with graceful shutdown, progress tracking, and optional notifications.

OPTIONS:
  --help, -h     Show this help message and exit
  --debug, -d    Enable debug-level logging and bash trace
  --force, -f    Force stop with shorter timeout (5s instead of 30s)

SHUTDOWN ORDER (reverse of startup):
  Determined by DOCKER_STACKS in .env (automatically reversed).
  Default: miscellaneous-services -> ... -> core-infrastructure

CONFIGURATION (.env):
  DOCKER_STACKS="..."            Customize stack categories and order
  REMOVE_VOLUMES_ON_STOP=true    Also remove named volumes (DESTRUCTIVE!)
  SERVICE_STOP_DELAY=2           Delay between stopping stacks (seconds)
  SHOW_STARTUP_BANNER=true       Show the shutdown banner
  API_ENABLED=true               Also stops the REST API server on shutdown

ENVIRONMENT OVERRIDES:
  LOG_LEVEL=DEBUG ./stop.sh      Override log level
  ENVIRONMENT=development        Set environment profile

EOF
    exit 0
fi

# Apply debug mode early so settings.cfg picks it up
if [[ "$DEBUG_REQUESTED" == "true" ]]; then
    export LOG_LEVEL="DEBUG"
    export DEBUG_MODE="true"
fi

# Export force mode for the stop library
if [[ "$FORCE_STOP" == "true" ]]; then
    export FORCE_STOP_MODE="true"
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

# Required: service shutdown
source "$BASE_DIR/.scripts/stop.sh"

# Optional libraries (graceful skip if missing)
# _source_optional is provided by docker-utils.sh
_source_optional "$BASE_DIR/.lib/banner.sh"                  "banner.sh"
_source_optional "$BASE_DIR/.scripts/ntfy-status-stop.sh"    "ntfy-status-stop.sh"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Set the terminal title (non-fatal if not supported)
_set_terminal_title() {
    echo -ne "\033]0;${1:-Docker Services Manager}\007" 2>/dev/null || true
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
    local total_steps=4

    # ── Shutdown Banner ──────────────────────────────────────────────
    if [[ "${SHOW_BANNERS:-${SHOW_STARTUP_BANNER:-true}}" == "true" ]] && command -v show_shutdown_banner >/dev/null 2>&1; then
        show_shutdown_banner
    else
        log_banner "DOCKER SERVICES MANAGER" "Shutdown Sequence — v${SCRIPT_VERSION:-2.0.0}"
    fi

    # ── Session Metadata ─────────────────────────────────────────────
    log_separator "-" 60
    log_keyvalue "User"            "$(whoami)"
    log_keyvalue "Hostname"        "$(hostname)"
    log_keyvalue "Base Dir"        "$BASE_DIR"
    log_keyvalue "Stacks Dir"      "$COMPOSE_DIR"
    log_keyvalue "App Data"        "$APP_DATA_DIR"
    log_keyvalue "Environment"     "${ENVIRONMENT:-production}"
    log_keyvalue "Log Level"       "${LOG_LEVEL:-INFO}"
    log_keyvalue "Compose"         "$DOCKER_COMPOSE_CMD"
    log_keyvalue "Volumes on Stop" "$([[ "${REMOVE_VOLUMES_ON_STOP:-false}" == "true" ]] && echo "REMOVE (destructive)" || echo "Preserve")"
    log_keyvalue "Force Mode"      "$([[ "${FORCE_STOP_MODE:-false}" == "true" ]] && echo "Enabled (5s timeout)" || echo "Disabled (30s timeout)")"
    log_keyvalue "Notifications"   "$([[ -n "${NTFY_URL:-}" ]] && echo "Enabled" || echo "Disabled")"
    log_keyvalue "API Server"      "$([[ "${API_ENABLED:-false}" == "true" ]] && echo "Will be stopped" || echo "Not enabled")"
    log_keyvalue "Initiated at"    "$(date '+%Y-%m-%d %H:%M:%S')"
    log_separator "-" 60

    _set_terminal_title "Stopping Docker Services..."

    # ── Master Timer ─────────────────────────────────────────────────
    log_timer_start "full_shutdown"

    # Enable bash trace in debug mode
    if [[ "${DEBUG_MODE:-false}" == "true" ]]; then
        log_debug "Debug mode active — enabling bash trace"
        set -x
    fi

    # ══════════════════════════════════════════════════════════════════
    # Step 1: Verify Environment
    # ══════════════════════════════════════════════════════════════════
    log_step 1 "$total_steps" "Verifying Docker environment"
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running or not accessible"
        _graceful_exit 1
    fi
    log_keyvalue "Docker" "$(docker --version 2>/dev/null | sed 's/Docker version /v/' | cut -d, -f1)"
    log_keyvalue "Compose" "$(_docker_compose_version_string)"
    log_success "Docker environment verified"

    # ── Stop v2.0 background daemons ────────────────────────────────
    # Metrics collector
    if [[ -f "/tmp/dcs-metrics-collector.pid" ]]; then
        local metrics_pid
        metrics_pid=$(cat /tmp/dcs-metrics-collector.pid 2>/dev/null)
        if [[ -n "$metrics_pid" ]] && kill -0 "$metrics_pid" 2>/dev/null; then
            kill "$metrics_pid" 2>/dev/null
            log_success "Metrics collector stopped (PID: $metrics_pid)"
        fi
        rm -f /tmp/dcs-metrics-collector.pid
    fi

    # Scheduler daemon
    if [[ -f "/tmp/dcs-scheduler.pid" ]]; then
        local sched_pid
        sched_pid=$(cat /tmp/dcs-scheduler.pid 2>/dev/null)
        if [[ -n "$sched_pid" ]] && kill -0 "$sched_pid" 2>/dev/null; then
            kill "$sched_pid" 2>/dev/null
            log_success "Scheduler daemon stopped (PID: $sched_pid)"
        fi
        rm -f /tmp/dcs-scheduler.pid
    fi

    # ── Stop REST API server if running ──────────────────────────────
    # Stop if: PID file exists OR API_ENABLED=true (covers orphaned processes)
    local api_script="$BASE_DIR/.scripts/api-server.sh"
    if [[ -x "$api_script" ]]; then
        if [[ -f "/tmp/dcs-api-server.pid" ]] || [[ "${API_ENABLED:-false}" == "true" ]]; then
            log_info "Stopping REST API server..."
            "$api_script" --stop 2>/dev/null && log_success "REST API server stopped" || log_debug "REST API server was not running"
        fi
    fi

    # ══════════════════════════════════════════════════════════════════
    # Step 2: Stop All Stacks (Reverse Dependency Order)
    # ══════════════════════════════════════════════════════════════════
    log_step 2 "$total_steps" "Stopping all Docker service stacks"

    if [[ "${REMOVE_VOLUMES_ON_STOP:-false}" == "true" ]]; then
        log_warning "REMOVE_VOLUMES_ON_STOP is enabled — named volumes WILL be destroyed"
    fi
    if [[ "${FORCE_STOP_MODE:-false}" == "true" ]]; then
        log_note "Force mode: using 5s container timeout instead of 30s"
    fi

    if ! stop_docker_services; then
        log_warning "Service shutdown completed with some failures (see summary above)"
    fi

    # ══════════════════════════════════════════════════════════════════
    # Step 3: Post-Shutdown Verification
    # ══════════════════════════════════════════════════════════════════
    log_step 3 "$total_steps" "Verifying shutdown status"

    local remaining_containers
    remaining_containers="$(docker ps --filter "name=skeleton-" --format '{{.Names}}' 2>/dev/null | wc -l)"

    if [[ "$remaining_containers" -gt 0 ]]; then
        log_warning "$remaining_containers skeleton containers still running:"
        docker ps --filter "name=skeleton-" --format '  {{.Names}} ({{.Status}})' 2>/dev/null | while read -r line; do
            log_warning "$line"
        done
    else
        log_success "All skeleton containers confirmed stopped"
    fi

    # ══════════════════════════════════════════════════════════════════
    # Step 4: Resource Summary
    # ══════════════════════════════════════════════════════════════════
    log_step 4 "$total_steps" "Docker resource summary"

    local images_count volumes_count networks_count
    images_count="$(docker images -q 2>/dev/null | wc -l)"
    volumes_count="$(docker volume ls -q 2>/dev/null | wc -l)"
    networks_count="$(docker network ls --format '{{.Name}}' 2>/dev/null | grep -cv '^bridge$\|^host$\|^none$' || echo 0)"

    log_keyvalue "Images"    "$images_count"
    log_keyvalue "Volumes"   "$volumes_count"
    log_keyvalue "Networks"  "$networks_count (custom)"

    # ── Disable debug trace ──────────────────────────────────────────
    { set +x; } 2>/dev/null

    # ── Stop Master Timer ────────────────────────────────────────────
    log_timer_stop "full_shutdown"

    # ── Completion ───────────────────────────────────────────────────
    if [[ "${SHOW_BANNERS:-${SHOW_STARTUP_BANNER:-true}}" == "true" ]] && command -v show_completion_banner >/dev/null 2>&1; then
        if [[ "$remaining_containers" -gt 0 ]]; then
            show_completion_banner "warning" "Shutdown complete — $remaining_containers containers still running"
        else
            show_completion_banner "success" "All services shut down cleanly"
        fi
    else
        log_separator "=" 60 "SHUTDOWN COMPLETE" "SUCCESS"
        log_success "All operations completed at: $(date '+%Y-%m-%d %H:%M:%S')"
    fi

    _set_terminal_title "Docker Services — Stopped"

    # Close the logger (writes session summary)
    close_logger
}

# =============================================================================
# RUN
# =============================================================================

main "$@"
