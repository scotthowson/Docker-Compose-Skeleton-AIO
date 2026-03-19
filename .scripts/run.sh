#!/bin/bash
# =============================================================================
# Docker Services Start Library v3.0
# Controlled startup of Docker Compose service stacks with dependency ordering,
# progress tracking, resilient failure handling, and NTFY push notifications.
#
# This file is SOURCED by start.sh — do not execute directly.
#
# Expected caller environment:
#   $BASE_DIR              — repository root
#   $COMPOSE_DIR           — path to Stacks/ directory
#   $DOCKER_COMPOSE_CMD    — "docker compose" or "docker-compose"
#   $LOG_FILE              — active log file path
#   $NTFY_URL              — (optional) NTFY push endpoint
#   $PORTAINER_URL         — (optional) Portainer dashboard URL
#   $DASHBOARD_ICON_URL    — (optional) icon for NTFY notifications
#   $SERVER_NAME           — (optional) friendly server name
#   $SKIP_HEALTHCHECK_WAIT — (optional) "true" to skip --wait flag
#   $CONTINUE_ON_FAILURE   — (optional) "true" to continue on stack failures
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

# Service startup order (dependency order — first started, last stopped).
# Each entry corresponds to a subdirectory under $COMPOSE_DIR.
#
# If DOCKER_STACKS is set in .env, use that (space-separated string).
# Otherwise fall back to the built-in default order.
if [[ -n "${DOCKER_STACKS:-}" ]]; then
    read -ra DOCKER_SERVICES <<< "$DOCKER_STACKS"
else
    declare -a DOCKER_SERVICES=(
        "core-infrastructure"
        "networking-security"
        "monitoring-management"
        "development-tools"
        "media-services"
        "web-applications"
        "storage-backup"
        "communication-collaboration"
        "entertainment-personal"
        "miscellaneous-services"
    )
fi

# Stacks that should trigger a push notification on successful start.
# Configurable via NOTIFICATION_STACKS in .env (space-separated).
if [[ -n "${NOTIFICATION_STACKS:-}" ]]; then
    read -ra NOTIFICATION_SERVICES <<< "$NOTIFICATION_STACKS"
else
    declare -a NOTIFICATION_SERVICES=(
        "core-infrastructure"
        "web-applications"
        "communication-collaboration"
    )
fi

# =============================================================================
# CORE SERVICE MANAGEMENT
# =============================================================================

# Start a single service stack.
#
# Loads environment files, builds the docker compose command with appropriate
# flags, captures output to a temp file (filtering noise), and reports the
# result with per-stack timing.
#
# Args:
#   $1 — stack directory name (e.g. "core-infrastructure")
#
# Returns: 0 on success, 1 on failure
start_service_stack() {
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

    log_info "Starting services in $service stack..."

    # ---- Load environment variables ----

    # Root .env first (global defaults), then stack-specific .env (overrides)
    if [[ -f "$BASE_DIR/.env" ]]; then
        set -a
        source "$BASE_DIR/.env"
        set +a
    fi

    if [[ -f "$env_file" ]]; then
        log_debug "Loading environment variables from: $env_file"
        set -a
        source "$env_file"
        set +a
    else
        log_warning "No .env file found for $service, using defaults"
    fi

    # ---- Build compose command arguments ----

    local -a compose_args=(-f "$compose_file" up -d --remove-orphans --timeout 60)

    if [[ "${SKIP_HEALTHCHECK_WAIT:-false}" != "true" ]]; then
        compose_args+=(--wait)
    else
        log_debug "Healthcheck wait skipped for $service (SKIP_HEALTHCHECK_WAIT=true)"
    fi

    # ---- Execute with output capture and timing ----

    log_timer_start "stack_${service}"

    local compose_output
    compose_output="$(mktemp "${TMPDIR:-/tmp}/compose-${service}.XXXXXX")"

    if $DOCKER_COMPOSE_CMD "${compose_args[@]}" > "$compose_output" 2>&1; then
        # Filter meaningful lines into the log file (skip noisy pull progress)
        if [[ -s "$compose_output" ]]; then
            grep -Ei '(Creating|Created|Starting|Started|Pulling|Pulled|Running|Healthy|Unhealthy|Error|error|Recreat|Remov|Network|Volume|Container)' \
                "$compose_output" >> "$LOG_FILE" 2>/dev/null || true
        fi
        rm -f "$compose_output"

        log_timer_stop "stack_${service}"
        log_success "$service stack started successfully"

        # Send push notification for selected stacks
        if _should_notify_service "$service"; then
            _send_start_notification "$service"
        fi

        return 0
    else
        local exit_code=$?

        # On failure, log the full output for diagnostics
        if [[ -s "$compose_output" ]]; then
            {
                echo "--- $service compose output (exit code $exit_code) ---"
                cat "$compose_output"
                echo "--- end $service compose output ---"
            } >> "$LOG_FILE" 2>/dev/null
        fi
        rm -f "$compose_output"

        log_timer_stop "stack_${service}"
        log_warning "Failed to start $service stack (exit code $exit_code). Check $LOG_FILE for details"

        _send_failure_notification "$service"
        return 1
    fi
}

# Check whether a stack should trigger a push notification.
# Args: $1 — stack name
# Returns: 0 if yes, 1 if no
_should_notify_service() {
    local service="$1"

    for notify_service in "${NOTIFICATION_SERVICES[@]}"; do
        [[ "$service" == "$notify_service" ]] && return 0
    done
    return 1
}

# Start a list of service stacks sequentially with progress tracking.
#
# Iterates through the provided stack names in order, starting each one,
# displaying a progress bar after every stack, and collecting results into
# parallel arrays for a summary table at the end.
#
# Args: $@ — stack names
# Returns: 0 if all succeeded, 1 if any failed
start_docker_compose_services() {
    local services_to_start=("$@")
    local total_services=${#services_to_start[@]}

    # Parallel arrays for the summary table
    local -a result_names=()
    local -a result_statuses=()
    local -a result_durations=()

    local failed_services=()
    local started_count=0

    log_info "Initiating startup of $total_services Docker service stacks..."
    log_separator "=" 60 "SERVICE STARTUP SEQUENCE" "INFO"

    local stack_index=0
    for service in "${services_to_start[@]}"; do
        (( stack_index++ )) || true

        if [[ -d "$COMPOSE_DIR/$service" ]]; then
            local timer_start
            timer_start="$(date '+%s')"

            if start_service_stack "$service"; then
                (( started_count++ ))

                local timer_end
                timer_end="$(date '+%s')"
                local elapsed=$(( timer_end - timer_start ))
                local duration_str
                duration_str="$(_format_duration "$elapsed")"

                result_names+=("$service")
                result_statuses+=("OK")
                result_durations+=("$duration_str")

                # Brief pause between stacks for system stability
                sleep "${SERVICE_START_DELAY:-2}"
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

                log_warning "Service '$service' failed to start cleanly"
            fi
        else
            log_warning "Service directory for '$service' does not exist, skipping"
            failed_services+=("$service")

            result_names+=("$service")
            result_statuses+=("SKIPPED")
            result_durations+=("--")
        fi

        # Progress bar after each stack
        log_progress "Starting stacks" "$stack_index" "$total_services"
    done

    # ---- Summary table ----

    log_separator "=" 60 "STARTUP SUMMARY" "INFO"

    # Build table rows: header + one row per stack
    local -a table_rows=()
    table_rows+=("Stack|Status|Duration")

    local i
    for (( i = 0; i < ${#result_names[@]}; i++ )); do
        table_rows+=("${result_names[$i]}|${result_statuses[$i]}|${result_durations[$i]}")
    done

    log_table "${table_rows[@]}"

    # ---- Final log lines ----

    log_info "Total: $total_services | Succeeded: $started_count | Failed: ${#failed_services[@]}"

    if [[ ${#failed_services[@]} -eq 0 ]]; then
        log_success "All $started_count service stacks started successfully"
        return 0
    else
        log_warning "Failed stacks: ${failed_services[*]}"
        return 1
    fi
}

# =============================================================================
# NOTIFICATION FUNCTIONS
# =============================================================================

# Send a per-stack startup notification via NTFY.
# Args: $1 — stack name
_send_start_notification() {
    local service="$1"

    [[ -z "${NTFY_URL:-}" ]] && return 0

    if command -v curl >/dev/null 2>&1; then
        local -a headers=()
        [[ -n "${DASHBOARD_ICON_URL:-}" ]] && headers+=(-H "Icon: $DASHBOARD_ICON_URL")

        curl -s \
            "${headers[@]}" \
            -H "Title: Service Alert - $service stack active" \
            -H "Priority: high" \
            -H "X-Tags: white_check_mark,docker,$service" \
            -d "$service is up and running. Started without any issues." \
            "$NTFY_URL" >/dev/null 2>&1

        log_alert "Startup notification sent for $service"
    else
        log_warning "curl not available, skipping service notification"
    fi
}

# Send a per-stack failure notification via NTFY.
# Args: $1 — stack name
_send_failure_notification() {
    local service="$1"

    [[ -z "${NTFY_URL:-}" ]] && return 0

    if command -v curl >/dev/null 2>&1; then
        local -a action_headers=()
        if [[ -n "${PORTAINER_URL:-}" ]]; then
            action_headers+=(-H "Actions: view, View in Portainer, $PORTAINER_URL")
        fi

        curl -s \
            -H "Title: Docker Compose - $service Failed" \
            -H "Priority: urgent" \
            -H "X-Tags: warning,no_entry_sign,docker,$service" \
            "${action_headers[@]}" \
            -d "Urgent: $service failed to start. Immediate action required. Check logs for troubleshooting." \
            "$NTFY_URL" >/dev/null 2>&1

        log_alert "Failure notification sent for $service"
    else
        log_warning "curl not available, skipping error notification"
    fi
}

# Send a general success notification.
_send_success_notification() {
    local message="${1:-All Docker services started successfully}"

    [[ -z "${NTFY_URL:-}" ]] && return 0

    if command -v curl >/dev/null 2>&1; then
        curl -s \
            -H "Title: Docker Services - Startup Complete" \
            -H "Priority: normal" \
            -H "X-Tags: white_check_mark,docker,startup" \
            -d "$message" \
            "$NTFY_URL" >/dev/null 2>&1 || true

        log_alert "General success notification sent to monitoring system"
    else
        log_warning "curl not available, skipping general notification"
    fi
}

# Send a general failure notification.
_send_general_failure_notification() {
    local message="${1:-Some Docker services failed to start}"

    [[ -z "${NTFY_URL:-}" ]] && return 0

    if command -v curl >/dev/null 2>&1; then
        curl -s \
            -H "Title: Docker Services - Startup Issues" \
            -H "Priority: high" \
            -H "X-Tags: warning,docker,error" \
            -d "$message" \
            "$NTFY_URL" >/dev/null 2>&1 || true

        log_alert "General failure notification sent to monitoring system"
    else
        log_warning "curl not available, skipping error notification"
    fi
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

# Start Docker services (all or a specified subset).
#
# Orchestrates the full startup sequence: determines which stacks to start,
# calls start_docker_compose_services(), sends summary notifications, and
# returns an exit code that respects the CONTINUE_ON_FAILURE setting.
#
# Args: $@ — optional list of specific stack names
# Returns:
#   When CONTINUE_ON_FAILURE=true  (default): always 0 (failures logged as warnings)
#   When CONTINUE_ON_FAILURE=false:           1 if any stacks failed
start_docker_services() {
    local services_to_start
    local exit_code=0

    log_info_header "Docker Services Startup Initiated"
    log_info "Startup requested at: $(date '+%Y-%m-%d %H:%M:%S')"

    # Log active feature flags
    if [[ "${SKIP_HEALTHCHECK_WAIT:-false}" == "true" ]]; then
        log_info "Healthcheck wait: DISABLED (fast startup mode)"
    else
        log_info "Healthcheck wait: ENABLED (containers must report healthy)"
    fi
    log_debug "CONTINUE_ON_FAILURE=${CONTINUE_ON_FAILURE:-true}"

    # Determine which stacks to start
    if [[ "$#" -gt 0 ]]; then
        services_to_start=("$@")
        log_info "Selective startup requested for: ${services_to_start[*]}"
    else
        services_to_start=("${DOCKER_SERVICES[@]}")
        log_info "Full system startup requested for all ${#DOCKER_SERVICES[@]} service stacks"
    fi

    if [[ ${#services_to_start[@]} -eq 0 ]]; then
        log_warning "No services specified for startup"
        return 1
    fi

    # Execute the startup sequence
    log_focus "Beginning controlled Docker services startup..."

    if start_docker_compose_services "${services_to_start[@]}"; then
        log_highlight "All specified Docker service stacks started successfully"
        _send_success_notification "Successfully started ${#services_to_start[@]} Docker service stacks on ${SERVER_NAME:-$(hostname)}"
        exit_code=0
    else
        # Some stacks failed — decide how to handle based on CONTINUE_ON_FAILURE
        if [[ "${CONTINUE_ON_FAILURE:-true}" == "true" ]]; then
            log_warning "Startup completed with failures, but CONTINUE_ON_FAILURE is enabled"
            _send_general_failure_notification "Docker services startup encountered issues on ${SERVER_NAME:-$(hostname)}"
            exit_code=0
        else
            log_error "Startup completed with errors. CONTINUE_ON_FAILURE is disabled — returning failure"
            _send_general_failure_notification "Docker services startup failed on ${SERVER_NAME:-$(hostname)}"
            exit_code=1
        fi
    fi

    # Final status
    log_separator "=" 60 "OPERATION COMPLETE" "SUCCESS"
    log_info "Startup operation completed at: $(date '+%Y-%m-%d %H:%M:%S')"

    if [[ $exit_code -eq 0 ]]; then
        log_success "Docker services startup completed successfully"
    else
        log_warning "Docker services startup completed with failures"
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
    start_docker_services "$@"
    exit $?
fi

# =============================================================================
# EXPORT FUNCTIONS FOR EXTERNAL USE
# =============================================================================

export -f start_docker_services start_docker_compose_services
export -f start_service_stack
