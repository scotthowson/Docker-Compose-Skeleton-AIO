#!/bin/bash
# =============================================================================
# Stop Status Monitor with NTFY Notifications
# Verifies that monitored containers have stopped and sends a notification
# summarising the result.
#
# This file is SOURCED by stop.sh -- do not execute directly.
#
# Expected environment (set by caller):
#   $NTFY_URL              -- (optional) NTFY push endpoint
#   $PORTAINER_URL         -- (optional) Portainer dashboard URL
#   $CRITICAL_CONTAINERS   -- (optional) comma-separated critical container names
#   $IMPORTANT_CONTAINERS  -- (optional) comma-separated important container names
#   $SERVER_NAME           -- (optional) friendly server name
#
# Logger functions (log_info, log_error, etc.) must be available.
# =============================================================================

# =============================================================================
# MAIN FUNCTION
# =============================================================================

check_stop_containers_status() {
    local server_name="${SERVER_NAME:-Docker Server}"

    # Build the monitoring list from env vars
    local -a containers_to_check=()

    if [[ -n "${CRITICAL_CONTAINERS:-}" ]]; then
        IFS=',' read -ra _crit <<< "$CRITICAL_CONTAINERS"
        containers_to_check+=("${_crit[@]}")
    fi
    if [[ -n "${IMPORTANT_CONTAINERS:-}" ]]; then
        IFS=',' read -ra _imp <<< "$IMPORTANT_CONTAINERS"
        containers_to_check+=("${_imp[@]}")
    fi

    if [[ ${#containers_to_check[@]} -eq 0 ]]; then
        log_info "No containers configured for stop monitoring (CRITICAL_CONTAINERS / IMPORTANT_CONTAINERS are empty)"
        return 0
    fi

    local all_stopped=true
    local still_running_containers=""

    log_info "Checking container stop status for ${#containers_to_check[@]} monitored containers..."

    for container in "${containers_to_check[@]}"; do
        # Trim whitespace
        container="${container## }"; container="${container%% }"
        [[ -z "$container" ]] && continue

        local status
        status=$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null)

        if [[ "$status" == "true" ]]; then
            all_stopped=false
            still_running_containers+="$container (still running) "
            log_warning "Container '$container' is still running"
        else
            log_info "Container '$container' is stopped"
        fi
    done

    # Send NTFY notification
    if [[ -z "${NTFY_URL:-}" ]]; then
        log_info "NTFY_URL not configured -- skipping push notification"
        return 0
    fi

    local portainer_url="${PORTAINER_URL:-}"
    local -a action_headers=()
    [[ -n "$portainer_url" ]] && action_headers+=(-H "Actions: view, View in Portainer, $portainer_url")

    if [[ "$all_stopped" == "true" ]]; then
        curl -s \
            -H "Title: $server_name - All Containers Stopped" \
            -H "Priority: high" \
            -H "X-Tags: server,stopped,shutdown" \
            "${action_headers[@]}" \
            -d "All specified containers have been successfully stopped. System is now idle." \
            "$NTFY_URL" >/dev/null 2>&1

        log_alert "Notification sent for all containers stopped."
    else
        curl -s \
            -H "Title: $server_name - Stop Failure" \
            -H "Priority: urgent" \
            -H "X-Tags: server,running,warning" \
            "${action_headers[@]}" \
            -d "Some containers are still running: $still_running_containers. Immediate action may be necessary." \
            "$NTFY_URL" >/dev/null 2>&1

        log_alert "Notification sent for failure to stop some containers."
    fi
}
