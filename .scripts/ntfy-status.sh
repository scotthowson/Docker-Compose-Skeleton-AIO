#!/bin/bash
# =============================================================================
# Enhanced Container Status Monitor with NTFY Notifications
# Checks critical and important containers, gathers system metrics, and
# sends categorised push notifications (critical / warning / all-clear).
#
# This file is SOURCED by start.sh -- do not execute directly.
#
# Expected environment (set by caller):
#   $NTFY_URL            -- (optional) NTFY push endpoint
#   $SERVER_NAME         -- (optional) friendly name  (default: "Docker Server")
#   $PORTAINER_URL       -- (optional) Portainer dashboard URL
#   $CRITICAL_CONTAINERS -- (optional) comma-separated list of critical names
#   $IMPORTANT_CONTAINERS-- (optional) comma-separated list of important names
#
# Logger functions (log_info, log_error, etc.) must be available.
# =============================================================================

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Return a human-readable uptime string for a container.
# Args: $1 -- container name
get_container_uptime() {
    local container="$1"
    local started
    started=$(docker inspect --format='{{.State.StartedAt}}' "$container" 2>/dev/null)

    if [[ -n "$started" ]]; then
        local start_epoch now_epoch uptime_seconds
        start_epoch=$(date -d "$started" +%s 2>/dev/null) || { echo "unknown"; return; }
        now_epoch=$(date +%s)
        uptime_seconds=$(( now_epoch - start_epoch ))

        if   (( uptime_seconds < 60 ));    then echo "${uptime_seconds}s"
        elif (( uptime_seconds < 3600 ));   then echo "$(( uptime_seconds / 60 ))m"
        elif (( uptime_seconds < 86400 ));  then echo "$(( uptime_seconds / 3600 ))h $(( uptime_seconds % 3600 / 60 ))m"
        else                                     echo "$(( uptime_seconds / 86400 ))d $(( uptime_seconds % 86400 / 3600 ))h"
        fi
    else
        echo "unknown"
    fi
}

# Return memory usage for a container.
get_container_memory_usage() {
    local container="$1"
    docker stats --no-stream --format "{{.MemUsage}}" "$container" 2>/dev/null || echo "N/A"
}

# Return CPU usage for a container.
get_container_cpu_usage() {
    local container="$1"
    docker stats --no-stream --format "{{.CPUPerc}}" "$container" 2>/dev/null || echo "N/A"
}

# Gather high-level system information.
get_system_info() {
    local total_containers total_images disk_usage load_avg
    total_containers=$(docker ps -q 2>/dev/null | wc -l)
    total_images=$(docker images -q 2>/dev/null | wc -l)
    disk_usage=$(df -h / 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//')
    load_avg=$(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')

    echo "Containers: $total_containers | Images: $total_images | Disk: ${disk_usage}% | Load: $load_avg"
}

# =============================================================================
# MAIN STATUS CHECK
# =============================================================================

check_containers_status() {
    local server_name="${SERVER_NAME:-Docker Server}"

    # Parse container lists from comma-separated env vars
    local -a critical_containers=()
    local -a important_containers=()

    if [[ -n "${CRITICAL_CONTAINERS:-}" ]]; then
        IFS=',' read -ra critical_containers <<< "$CRITICAL_CONTAINERS"
    fi
    if [[ -n "${IMPORTANT_CONTAINERS:-}" ]]; then
        IFS=',' read -ra important_containers <<< "$IMPORTANT_CONTAINERS"
    fi

    local total_monitored=$(( ${#critical_containers[@]} + ${#important_containers[@]} ))

    # Nothing to monitor
    if [[ $total_monitored -eq 0 ]]; then
        log_info "No containers configured for monitoring (CRITICAL_CONTAINERS / IMPORTANT_CONTAINERS are empty)"
        return 0
    fi

    log_bold_status "Checking container status..."

    local -a critical_down=()
    local -a important_down=()
    local -a critical_issues=()
    local status_details=""
    local healthy_count=0

    # -- Check critical containers --
    for container in "${critical_containers[@]}"; do
        # Trim whitespace
        container="${container## }"; container="${container%% }"
        [[ -z "$container" ]] && continue

        local status health
        status=$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null)
        health=$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null)

        if [[ "$status" != "true" ]]; then
            critical_down+=("$container")
            critical_issues+=("$container (STOPPED)")
        elif [[ "$health" == "unhealthy" ]]; then
            critical_issues+=("$container (UNHEALTHY)")
            (( healthy_count++ ))
        else
            local uptime
            uptime=$(get_container_uptime "$container")
            status_details+="$container ($uptime) "
            (( healthy_count++ ))
        fi
    done

    # -- Check important containers --
    for container in "${important_containers[@]}"; do
        container="${container## }"; container="${container%% }"
        [[ -z "$container" ]] && continue

        local status health
        status=$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null)
        health=$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null)

        if [[ "$status" != "true" ]]; then
            important_down+=("$container")
        elif [[ "$health" == "unhealthy" ]]; then
            status_details+="$container (unhealthy) "
            (( healthy_count++ ))
        else
            local uptime
            uptime=$(get_container_uptime "$container")
            status_details+="$container ($uptime) "
            (( healthy_count++ ))
        fi
    done

    # System information
    local system_info timestamp
    system_info=$(get_system_info)
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Allow services to stabilise before sending alerts
    log_bold_status "Allowing services to stabilize..."
    sleep 8

    # -- Send NTFY notifications --
    if [[ -z "${NTFY_URL:-}" ]]; then
        log_info "NTFY_URL not configured -- skipping push notifications"
        log_info "Status: ${healthy_count}/${total_monitored} containers operational"
        return 0
    fi

    local portainer_url="${PORTAINER_URL:-}"

    if [[ ${#critical_down[@]} -gt 0 ]]; then
        # CRITICAL ALERT
        local critical_list
        critical_list=$(printf " - %s\n" "${critical_down[@]}")

        local message="CRITICAL SYSTEM FAILURE

Critical services are down:
$critical_list

System Status: ${healthy_count}/${total_monitored} containers operational
Time: $timestamp
Info: $system_info

Immediate intervention required!"

        local -a action_headers=()
        [[ -n "$portainer_url" ]] && action_headers+=(-H "Actions: view, Emergency Dashboard, $portainer_url")

        curl -s \
            -H "Title: CRITICAL: $server_name Down" \
            -H "Priority: urgent" \
            -H "X-Tags: critical,server,down,emergency" \
            "${action_headers[@]}" \
            -d "$message" \
            "$NTFY_URL" >/dev/null 2>&1

    elif [[ ${#important_down[@]} -gt 0 ]] || [[ ${#critical_issues[@]} -gt 0 ]]; then
        # WARNING ALERT
        local issue_list=""
        [[ ${#important_down[@]} -gt 0 ]] && issue_list+=$(printf " - %s (stopped)\n" "${important_down[@]}")
        [[ ${#critical_issues[@]} -gt 0 ]] && issue_list+=$(printf " - %s\n" "${critical_issues[@]}")

        local message="SERVICE ISSUES DETECTED

Issues requiring attention:
$issue_list

System Status: ${healthy_count}/${total_monitored} containers operational
Time: $timestamp
Info: $system_info"

        local -a action_headers=()
        [[ -n "$portainer_url" ]] && action_headers+=(-H "Actions: view, Check Dashboard, $portainer_url")

        curl -s \
            -H "Title: Service Issues - $server_name" \
            -H "Priority: high" \
            -H "X-Tags: warning,server,issues" \
            "${action_headers[@]}" \
            -d "$message" \
            "$NTFY_URL" >/dev/null 2>&1

    else
        # ALL SYSTEMS OPERATIONAL
        local uptime_info
        uptime_info=$(uptime 2>/dev/null | awk -F'up ' '{print $2}' | awk -F',' '{print $1}')

        local message="ALL SYSTEMS OPERATIONAL

Status: All ${total_monitored} monitored containers are healthy
Uptime: $uptime_info
Time: $timestamp
Info: $system_info

$status_details

Infrastructure running optimally."

        local -a action_headers=()
        [[ -n "$portainer_url" ]] && action_headers+=(-H "Actions: view, View Dashboard, $portainer_url")

        curl -s \
            -H "Title: $server_name - All Systems GO" \
            -H "Priority: default" \
            -H "X-Tags: success,server,operational,healthy" \
            "${action_headers[@]}" \
            -d "$message" \
            "$NTFY_URL" >/dev/null 2>&1
    fi

    log_success "Notification sent successfully"
}

# =============================================================================
# EXTENDED MONITORING
# =============================================================================

# Check for containers with high CPU usage and send an alert if found.
check_resource_usage() {
    log_bold_info "Gathering system metrics..."

    local -a critical_containers=()
    local -a important_containers=()

    if [[ -n "${CRITICAL_CONTAINERS:-}" ]]; then
        IFS=',' read -ra critical_containers <<< "$CRITICAL_CONTAINERS"
    fi
    if [[ -n "${IMPORTANT_CONTAINERS:-}" ]]; then
        IFS=',' read -ra important_containers <<< "$IMPORTANT_CONTAINERS"
    fi

    local -a high_cpu_containers=()
    local server_name="${SERVER_NAME:-Docker Server}"

    for container in "${critical_containers[@]}" "${important_containers[@]}"; do
        container="${container## }"; container="${container%% }"
        [[ -z "$container" ]] && continue

        if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
            local cpu
            cpu=$(docker stats --no-stream --format "{{.CPUPerc}}" "$container" 2>/dev/null)

            if [[ "$cpu" =~ ^([0-9]+\.?[0-9]*)% ]]; then
                local cpu_num="${BASH_REMATCH[1]}"
                if (( $(echo "$cpu_num > 80" | bc -l 2>/dev/null) )); then
                    high_cpu_containers+=("$container ($cpu)")
                fi
            fi
        fi
    done

    if [[ ${#high_cpu_containers[@]} -gt 0 ]] && [[ -n "${NTFY_URL:-}" ]]; then
        local message="RESOURCE USAGE ALERT

High CPU usage detected:
$(printf " - %s\n" "${high_cpu_containers[@]}")

Monitor system performance closely."

        curl -s \
            -H "Title: Resource Alert - $server_name" \
            -H "Priority: default" \
            -H "X-Tags: performance,monitoring,resources" \
            -d "$message" \
            "$NTFY_URL" >/dev/null 2>&1
    fi
}

# =============================================================================
# STANDALONE EXECUTION HANDLER
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Starting enhanced container monitoring..."
    echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    check_containers_status
    echo "Monitoring cycle completed"
fi
