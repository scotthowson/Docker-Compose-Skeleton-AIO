#!/bin/bash
# =============================================================================
# Debug Mode Library
# Toggles Bash debug/verbose modes based on LOG_LEVEL and VERBOSE_MODE settings.
#
# This file is SOURCED by start.sh or other entry points.
# It conditionally sources settings.cfg and logger.sh only if they have not
# already been loaded (checked via SETTINGS_LOADED and LOGGER_INITIALIZED).
#
# Expected environment (set by caller or auto-detected):
#   $LOG_LEVEL      -- current log level
#   $VERBOSE_MODE   -- "true" to enable verbose output
#   $BASE_DIR       -- (optional) repository root for path resolution
# =============================================================================

# Resolve the directory containing this script (used for relative sourcing)
DEBUGGER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# DEPENDENCY LOADING (conditional -- avoids double-sourcing)
# =============================================================================

if [[ "${SETTINGS_LOADED:-}" != "true" ]]; then
    local_settings="$DEBUGGER_DIR/../.config/settings.cfg"
    if [[ -f "$local_settings" ]]; then
        source "$local_settings"
    fi
    unset local_settings
fi

if [[ "${LOGGER_INITIALIZED:-}" != "true" ]]; then
    local_logger="$DEBUGGER_DIR/logger.sh"
    if [[ -f "$local_logger" ]]; then
        source "$local_logger"
        if command -v initiate_logger >/dev/null 2>&1; then
            initiate_logger
        fi
    fi
    unset local_logger
fi

# =============================================================================
# DEBUG FUNCTIONS
# =============================================================================

# Toggle Bash debug and verbose modes based on current settings.
# Args: $1 -- optional message to log at DEBUG level
toggle_debug_mode() {
    local message="${1:-Debug mode toggled}"

    if [[ "$LOG_LEVEL" == "DEBUG" ]] || [[ "${VERBOSE_MODE:-false}" == "true" ]]; then
        if command -v log_debug >/dev/null 2>&1; then
            log_debug "$message"
        fi
        set -x              # Enable Bash debug mode (trace)
        set -o verbose      # Enable Bash verbose mode
    else
        set +x              # Disable Bash debug mode
        set +o verbose      # Disable Bash verbose mode
    fi
}

# Dump key environment variables at DEBUG level for troubleshooting.
dump_debug_info() {
    if [[ "$LOG_LEVEL" != "DEBUG" ]]; then
        return 0
    fi

    local logger="log_debug"
    command -v log_debug >/dev/null 2>&1 || logger="echo"

    $logger "--- DEBUG DUMP ---"
    $logger "BASE_DIR       = ${BASE_DIR:-<unset>}"
    $logger "COMPOSE_DIR    = ${COMPOSE_DIR:-<unset>}"
    $logger "LOG_LEVEL      = ${LOG_LEVEL:-<unset>}"
    $logger "ENVIRONMENT    = ${ENVIRONMENT:-<unset>}"
    $logger "DOCKER_COMPOSE_CMD = ${DOCKER_COMPOSE_CMD:-<unset>}"
    $logger "NTFY_URL       = ${NTFY_URL:+[set]}"
    $logger "BASH_VERSION   = ${BASH_VERSION:-<unset>}"
    $logger "--- END DUMP ---"
}

# =============================================================================
# EXPORT
# =============================================================================

export -f toggle_debug_mode dump_debug_info
