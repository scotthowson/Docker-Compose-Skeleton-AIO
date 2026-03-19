#!/bin/bash
# =============================================================================
# Docker Services Stop Library v3.0
# Controlled shutdown of Docker Compose service stacks in reverse dependency
# order with progress tracking, per-stack timing, summary tables, and
# NTFY push notifications.
#
# This file is SOURCED by stop.sh — do not execute directly.
#
# Expected environment (set by caller):
#   $BASE_DIR              — repository root
#   $COMPOSE_DIR           — path to Stacks/ directory
#   $DOCKER_COMPOSE_CMD    — "docker compose" or "docker-compose"
#   $LOG_FILE              — active log file path
#   $NTFY_URL              — (optional) NTFY push endpoint
#   $PORTAINER_URL         — (optional) Portainer dashboard URL
#   $SERVER_NAME           — (optional) friendly server name
#   $REMOVE_VOLUMES_ON_STOP — (optional) "true" to add --volumes flag
#   $FORCE_STOP_MODE       — (optional) "true" for shorter timeout
#
# Logger functions (log_info, log_error, log_progress, etc.) must be available.
# =============================================================================

# -----------------------------------------------------------------------------
# Guards — abort early if required variables are missing
# -----------------------------------------------------------------------------

[[ -z "${COMPOSE_DIR:-}" ]] && { echo "ERROR: COMPOSE_DIR not set" >&2; return 1; }
[[ -z "${BASE_DIR:-}" ]]    && { echo "ERROR: BASE_DIR not set" >&2; return 1; }

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

# Service shutdown order (reverse of startup dependency order).
# Each entry corresponds to a subdirectory under $COMPOSE_DIR.
#
# If DOCKER_STACKS is set in .env, auto-reverse it for shutdown.
# Otherwise fall back to the built-in default reverse order.
if [[ -n "${DOCKER_STACKS:-}" ]]; then
    read -ra _start_order <<< "$DOCKER_STACKS"
    declare -a DOCKER_SERVICES_STOP=()
    for (( i=${#_start_order[@]}-1; i>=0; i-- )); do
        DOCKER_SERVICES_STOP+=("${_start_order[i]}")
    done
    unset _start_order
else
    declare -a DOCKER_SERVICES_STOP=(
        "miscellaneous-services"
        "entertainment-personal"
        "communication-collaboration"
        "storage-backup"
        "web-applications"
        "media-services"
        "development-tools"
        "monitoring-management"
        "networking-security"
        "core-infrastructure"
    )
fi

# =============================================================================
# CORE SERVICE MANAGEMENT
# =============================================================================

# Stop and remove containers for a single service stack.
#
# Builds the docker compose down command with appropriate flags, captures
# output, filters noise, and reports the result with per-stack timing.
#
# Args:
#   $1 — stack directory name (e.g. "core-infrastructure")
#
# Returns: 0 on success, 1 on failure
stop_and_remove_containers() {
    local service="$1"
    local service_path="$COMPOSE_DIR/$service"
    local env_file="$service_path/.env"
    local compose_file="$service_path/docker-compose.yml"

    # ---- Validate service directory ----

    if [[ ! -d "$service_path" ]]; then
        log_warning "Service directory not found: $service_path"
        return 1
    fi

    if [[ ! -f "$compose_file" ]]; then
        log_warning "Compose file missing: $compose_file"
        return 1
    fi

    log_info "Stopping services in $service stack..."

    # ---- Build compose-down arguments ----

    local stop_timeout=30
    if [[ "${FORCE_STOP_MODE:-false}" == "true" ]]; then
        stop_timeout=5
    fi

    local -a compose_args=(-f "$compose_file" down --remove-orphans --timeout "$stop_timeout")

    if [[ "${REMOVE_VOLUMES_ON_STOP:-false}" == "true" ]]; then
        compose_args+=(--volumes)
        log_debug "Volume removal enabled for $service"
    fi

    # Add env-file if it exists
    if [[ -f "$env_file" ]]; then
        compose_args=(-f "$compose_file" --env-file "$env_file" down --remove-orphans --timeout "$stop_timeout")
        if [[ "${REMOVE_VOLUMES_ON_STOP:-false}" == "true" ]]; then
            compose_args+=(--volumes)
        fi
    fi

    # ---- Execute with output capture and timing ----

    log_timer_start "stop_${service}"

    local compose_output
    compose_output="$(mktemp "${TMPDIR:-/tmp}/compose-stop-${service}.XXXXXX")"

    if $DOCKER_COMPOSE_CMD "${compose_args[@]}" > "$compose_output" 2>&1; then
        # Filter meaningful lines into the log file
        if [[ -s "$compose_output" ]]; then
            grep -Ei '(Stopping|Stopped|Removing|Removed|Network|Volume|Container|Killed|error)' \
                "$compose_output" >> "$LOG_FILE" 2>/dev/null || true
        fi
        rm -f "$compose_output"

        log_timer_stop "stop_${service}"
        log_success "$service stack stopped successfully"
        return 0
    else
        local exit_code=$?

        # On failure, log the full output for diagnostics
        if [[ -s "$compose_output" ]]; then
            {
                echo "--- $service stop output (exit code $exit_code) ---"
                cat "$compose_output"
                echo "--- end $service stop output ---"
            } >> "$LOG_FILE" 2>/dev/null
        fi
        rm -f "$compose_output"

        log_timer_stop "stop_${service}"
        log_warning "Failed to stop $service stack (exit code $exit_code). Check $LOG_FILE for details"
        return 1
    fi
}

# Stop a list of service stacks sequentially with progress tracking.
#
# Iterates through the provided stack names in order, stopping each one,
# displaying a progress bar after every stack, and collecting results into
# parallel arrays for a summary table at the end.
#
# Args: $@ — stack names
# Returns: 0 if all succeeded, 1 if any failed
stop_docker_compose_services() {
    local services_to_stop=("$@")
    local total_services=${#services_to_stop[@]}

    # Parallel arrays for the summary table
    local -a result_names=()
    local -a result_statuses=()
    local -a result_durations=()

    local failed_services=()
    local stopped_count=0

    log_info "Initiating shutdown of $total_services Docker service stacks..."
    log_separator "=" 60 "SERVICE SHUTDOWN SEQUENCE" "INFO"

    local stack_index=0
    for service in "${services_to_stop[@]}"; do
        (( stack_index++ )) || true

        if [[ -d "$COMPOSE_DIR/$service" ]]; then
            local timer_start
            timer_start="$(date '+%s')"

            if stop_and_remove_containers "$service"; then
                (( stopped_count++ ))

                local timer_end
                timer_end="$(date '+%s')"
                local elapsed=$(( timer_end - timer_start ))
                local duration_str
                duration_str="$(_format_duration "$elapsed")"

                result_names+=("$service")
                result_statuses+=("OK")
                result_durations+=("$duration_str")

                # Brief pause between stacks for system stability
                sleep "${SERVICE_STOP_DELAY:-1}"
            else
                local timer_end
                timer_end="$(date '+%s')"
                local elapsed=$(( timer_end - timer_start ))
                local duration_str
                duration_str="$(_format_duration "$elapsed")"

                failed_services+=("$service")

                result_names+=("$service")
                result_statuses+=("FAILED")
                result_durations+=("$duration_str")

                log_warning "Service '$service' failed to stop cleanly"
            fi
        else
            log_warning "Service directory for '$service' does not exist, skipping"
            failed_services+=("$service")

            result_names+=("$service")
            result_statuses+=("SKIPPED")
            result_durations+=("--")
        fi

        # Progress bar after each stack
        log_progress "Stopping stacks" "$stack_index" "$total_services"
    done

    # ---- Summary table ----

    log_separator "=" 60 "SHUTDOWN SUMMARY" "INFO"

    # Build table rows: header + one row per stack
    local -a table_rows=()
    table_rows+=("Stack|Status|Duration")

    local i
    for (( i = 0; i < ${#result_names[@]}; i++ )); do
        table_rows+=("${result_names[$i]}|${result_statuses[$i]}|${result_durations[$i]}")
    done

    log_table "${table_rows[@]}"

    # ---- Final log lines ----

    log_info "Total: $total_services | Stopped: $stopped_count | Failed: ${#failed_services[@]}"

    if [[ ${#failed_services[@]} -eq 0 ]]; then
        log_success "All $stopped_count service stacks stopped successfully"
        return 0
    else
        log_warning "Failed stacks: ${failed_services[*]}"
        return 1
    fi
}

# =============================================================================
# NOTIFICATION FUNCTIONS
# =============================================================================

# Send a shutdown success notification via NTFY.
send_success_notification() {
    local message="${1:-Docker services stopped successfully}"

    [[ -z "${NTFY_URL:-}" ]] && return 0

    if command -v curl >/dev/null 2>&1; then
        local -a headers=()
        [[ -n "${DASHBOARD_ICON_URL:-}" ]] && headers+=(-H "Icon: $DASHBOARD_ICON_URL")

        curl -s \
            "${headers[@]}" \
            -H "Title: Docker Services - Shutdown Complete" \
            -H "Priority: normal" \
            -H "X-Tags: white_check_mark,docker,shutdown" \
            -d "$message" \
            "$NTFY_URL" >/dev/null 2>&1 || true

        log_alert "Success notification sent to monitoring system"
    else
        log_warning "curl not available, skipping notification"
    fi
}

# Send a shutdown failure notification via NTFY.
send_failure_notification() {
    local message="${1:-Some Docker services failed to stop}"

    [[ -z "${NTFY_URL:-}" ]] && return 0

    if command -v curl >/dev/null 2>&1; then
        local -a action_headers=()
        if [[ -n "${PORTAINER_URL:-}" ]]; then
            action_headers+=(-H "Actions: view, View in Portainer, $PORTAINER_URL")
        fi

        curl -s \
            -H "Title: Docker Services - Shutdown Issues" \
            -H "Priority: high" \
            -H "X-Tags: warning,docker,error" \
            "${action_headers[@]}" \
            -d "$message" \
            "$NTFY_URL" >/dev/null 2>&1 || true

        log_alert "Failure notification sent to monitoring system"
    else
        log_warning "curl not available, skipping error notification"
    fi
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

# Stop Docker services (all or a specified subset).
#
# Orchestrates the full shutdown sequence: determines which stacks to stop,
# calls stop_docker_compose_services(), sends summary notifications, and
# returns an appropriate exit code.
#
# Args: $@ — optional list of specific stack names
# Returns: 0 on complete success, 1 if any issues occurred
stop_docker_services() {
    local services_to_stop
    local exit_code=0

    log_info_header "Docker Services Shutdown Initiated"
    log_info "Shutdown requested at: $(date '+%Y-%m-%d %H:%M:%S')"

    # Log active feature flags
    if [[ "${REMOVE_VOLUMES_ON_STOP:-false}" == "true" ]]; then
        log_warning "Volume removal: ENABLED — named volumes will be destroyed"
    else
        log_info "Volume removal: DISABLED — named volumes will be preserved"
    fi
    if [[ "${FORCE_STOP_MODE:-false}" == "true" ]]; then
        log_info "Force mode: ENABLED — using 5s container timeout"
    fi

    # Determine which stacks to stop
    if [[ "$#" -gt 0 ]]; then
        services_to_stop=("$@")
        log_info "Selective shutdown requested for: ${services_to_stop[*]}"
    else
        services_to_stop=("${DOCKER_SERVICES_STOP[@]}")
        log_info "Full system shutdown requested for all ${#DOCKER_SERVICES_STOP[@]} service stacks"
    fi

    if [[ ${#services_to_stop[@]} -eq 0 ]]; then
        log_warning "No services specified for shutdown"
        return 1
    fi

    # Execute the shutdown sequence
    log_focus "Beginning controlled Docker services shutdown..."

    if stop_docker_compose_services "${services_to_stop[@]}"; then
        log_highlight "All specified Docker service stacks stopped successfully"
        send_success_notification "Successfully stopped ${#services_to_stop[@]} Docker service stacks on ${SERVER_NAME:-$(hostname)}"
        exit_code=0
    else
        log_warning "Shutdown completed with some failures"
        send_failure_notification "Docker services shutdown encountered issues on ${SERVER_NAME:-$(hostname)}"
        exit_code=1
    fi

    # Final status
    log_separator "=" 60 "OPERATION COMPLETE" "SUCCESS"
    log_info "Shutdown operation completed at: $(date '+%Y-%m-%d %H:%M:%S')"

    if [[ $exit_code -eq 0 ]]; then
        log_success "Docker services shutdown completed successfully"
    else
        log_warning "Docker services shutdown completed with failures"
    fi

    return "$exit_code"
}

# =============================================================================
# STANDALONE EXECUTION HANDLER
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if ! command -v log_info >/dev/null 2>&1; then
        echo "Error: Enhanced logger not available. Please source the logger first." >&2
        exit 1
    fi
    stop_docker_services "$@"
    exit $?
fi

# =============================================================================
# EXPORT FUNCTIONS FOR EXTERNAL USE
# =============================================================================

export -f stop_docker_services stop_docker_compose_services
export -f stop_and_remove_containers send_success_notification send_failure_notification
