#!/bin/bash
# =============================================================================
# Docker Utilities Library
# Provides Docker Compose command detection and shared Docker helpers
# =============================================================================

# Detect the best available Docker Compose command
# Sets DOCKER_COMPOSE_CMD globally
# Respects DOCKER_COMPOSE_VERSION setting (auto/v1/v2)
_detect_docker_compose() {
    local preference="${DOCKER_COMPOSE_VERSION:-auto}"

    case "$preference" in
        v2)
            if docker compose version &>/dev/null; then
                DOCKER_COMPOSE_CMD="docker compose"
            else
                echo "ERROR: docker compose plugin (v2) requested but not available" >&2
                return 1
            fi
            ;;
        v1)
            if command -v docker-compose &>/dev/null; then
                DOCKER_COMPOSE_CMD="docker-compose"
            else
                echo "ERROR: docker-compose binary (v1) requested but not installed" >&2
                return 1
            fi
            ;;
        auto|*)
            if docker compose version &>/dev/null; then
                DOCKER_COMPOSE_CMD="docker compose"
            elif command -v docker-compose &>/dev/null; then
                DOCKER_COMPOSE_CMD="docker-compose"
            else
                echo "ERROR: No Docker Compose installation found (tried 'docker compose' and 'docker-compose')" >&2
                return 1
            fi
            ;;
    esac

    export DOCKER_COMPOSE_CMD
    return 0
}

# Get the detected Docker Compose version string
_docker_compose_version_string() {
    if [[ "$DOCKER_COMPOSE_CMD" == "docker compose" ]]; then
        docker compose version 2>/dev/null || echo "unknown"
    else
        docker-compose --version 2>/dev/null || echo "unknown"
    fi
}

# Check if using Docker Compose v2 plugin
_is_compose_v2() {
    [[ "$DOCKER_COMPOSE_CMD" == "docker compose" ]]
}

# Source an optional script with a log message if the logger is available
# Args: $1 — file path, $2 — human-readable label
_source_optional() {
    local path="$1"
    local label="$2"
    if [[ -f "$path" ]]; then
        source "$path"
        if command -v log_debug >/dev/null 2>&1; then
            log_debug "Loaded: $label"
        fi
    else
        if command -v log_debug >/dev/null 2>&1; then
            log_debug "Not found, skipping: $label"
        fi
    fi
}

# Export functions
export -f _detect_docker_compose _docker_compose_version_string _is_compose_v2 _source_optional
export DOCKER_COMPOSE_CMD
