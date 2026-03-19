#!/bin/bash
# =============================================================================
# Restart Status Monitor with NTFY Notifications
# Verifies that monitored containers are running after a restart and sends
# a notification summarising the result.
#
# This file is SOURCED by restart.sh -- do not execute directly.
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

check_containers_running_status() {
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
        log_info "No containers configured for restart monitoring (CRITICAL_CONTAINERS / IMPORTANT_CONTAINERS are empty)"
        return 0
    fi

    local all_running=true
    local stopped_containers=""

    log_info "Checking container running status for ${#containers_to_check[@]} monitored containers..."

    for container in "${containers_to_check[@]}"; do
        # Trim whitespace
        container="${container## }"; container="${container%% }"
        [[ -z "$container" ]] && continue

        local status
        status=$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null)

        if [[ "$status" != "true" ]]; then
            all_running=false
            stopped_containers+="$container (stopped) "
            log_warning "Container '$container' is not running after restart"
        else
            log_info "Container '$container' is running"
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

    if [[ "$all_running" == "true" ]]; then
        curl -s \
            -H "Title: $server_name - All Containers Running" \
            -H "Priority: high" \
            -H "X-Tags: server,running,restart" \
            "${action_headers[@]}" \
            -d "All specified containers have been successfully restarted and are running." \
            "$NTFY_URL" >/dev/null 2>&1

        log_nodate_alert "Notification sent for all containers running after restart."
    else
        curl -s \
            -H "Title: $server_name - Restart Issues" \
            -H "Priority: urgent" \
            -H "X-Tags: server,stopped,warning" \
            "${action_headers[@]}" \
            -d "Some containers are not running after restart: $stopped_containers. Immediate action may be necessary." \
            "$NTFY_URL" >/dev/null 2>&1

        log_nodate_alert "Notification sent for some containers still stopped after restart."
    fi
}
