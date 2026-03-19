#!/bin/bash
# =============================================================================
# SSE (Server-Sent Events) Streaming Library v1.0
# Provides real-time push from server to clients over HTTP
# Designed for use by api-server.sh's /stream endpoint
#
# Dependencies: docker, /proc filesystem
# Requires: Bash 4+
# =============================================================================

if [[ -z "${BASE_DIR:-}" ]]; then
    BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# Configuration
SSE_KEEPALIVE_INTERVAL="${SSE_KEEPALIVE_INTERVAL:-15}"
SSE_DEFAULT_DURATION="${SSE_DEFAULT_DURATION:-0}"
SSE_METRICS_INTERVAL="${SSE_METRICS_INTERVAL:-5}"

# =============================================================================
# SSE RESPONSE HELPERS
# =============================================================================

# Send HTTP headers for an SSE stream
_sse_response_headers() {
    local cors_origin="${1:-}"

    printf "HTTP/1.1 200 OK\r\n"
    printf "Content-Type: text/event-stream\r\n"
    printf "Cache-Control: no-cache, no-store, must-revalidate\r\n"
    printf "Connection: keep-alive\r\n"
    printf "X-Accel-Buffering: no\r\n"
    printf "X-API-Version: %s\r\n" "${API_VERSION:-1.0.0}"

    if [[ -n "$cors_origin" ]]; then
        printf "Access-Control-Allow-Origin: %s\r\n" "$cors_origin"
        printf "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
        printf "Access-Control-Allow-Private-Network: true\r\n"
        printf "Vary: Origin\r\n"
    fi

    printf "\r\n"
}

# Send a single SSE event
# Usage: _sse_send_event "event-type" '{"key":"value"}'
_sse_send_event() {
    local event_type="$1"
    local data_json="$2"
    printf "event: %s\ndata: %s\n\n" "$event_type" "$data_json"
}

# Send an SSE comment (keepalive)
_sse_send_comment() {
    local text="${1:-keepalive}"
    printf ": %s\n\n" "$text"
}

# =============================================================================
# METRICS COLLECTION (lightweight, no /proc/stat delta)
# =============================================================================

# Collect current system metrics as a JSON string
_sse_collect_metrics() {
    local cpu_percent=0 mem_percent=0 mem_used_mb=0 mem_total_mb=0
    local load_1="" load_5="" load_15=""
    local disk_percent=0 container_count=0 container_running=0

    # Load average
    if [[ -f /proc/loadavg ]]; then
        read -r load_1 load_5 load_15 _ < /proc/loadavg
    fi

    # Memory from /proc/meminfo
    if [[ -f /proc/meminfo ]]; then
        local mem_total_kb mem_avail_kb
        mem_total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
        mem_avail_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
        if [[ -n "$mem_total_kb" && "$mem_total_kb" -gt 0 ]]; then
            mem_total_mb=$((mem_total_kb / 1024))
            mem_used_mb=$(( (mem_total_kb - ${mem_avail_kb:-0}) / 1024 ))
            mem_percent=$(( (mem_total_kb - ${mem_avail_kb:-0}) * 100 / mem_total_kb ))
        fi
    fi

    # CPU approximation from load average vs cores
    local cpu_count
    cpu_count=$(nproc 2>/dev/null || echo 1)
    if [[ -n "$load_1" ]]; then
        cpu_percent=$(awk "BEGIN {v=$load_1/$cpu_count*100; if(v>100)v=100; printf \"%.1f\", v}")
    fi

    # Disk usage of root filesystem
    disk_percent=$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
    disk_percent="${disk_percent:-0}"

    # Container counts
    container_count=$(docker ps -a -q 2>/dev/null | wc -l)
    container_running=$(docker ps -q 2>/dev/null | wc -l)

    printf '{"cpu_percent":%s,"memory_percent":%s,"memory_used_mb":%s,"memory_total_mb":%s,"load_average":[%s,%s,%s],"disk_percent":%s,"container_count":%s,"container_running":%s}' \
        "${cpu_percent:-0}" "${mem_percent:-0}" "${mem_used_mb:-0}" "${mem_total_mb:-0}" \
        "${load_1:-0}" "${load_5:-0}" "${load_15:-0}" \
        "${disk_percent:-0}" "${container_count:-0}" "${container_running:-0}"
}

# =============================================================================
# STREAM HANDLERS
# =============================================================================

# Stream Docker events as SSE for a given duration
# Usage: _sse_stream_docker_events [duration_seconds]
_sse_stream_docker_events() {
    local duration="${1:-0}"
    local end_time=0
    [[ "$duration" -gt 0 ]] && end_time=$(( $(date +%s) + duration ))

    docker events --format '{{json .}}' 2>/dev/null | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        _sse_send_event "docker-event" "$line"

        if [[ "$end_time" -gt 0 && "$(date +%s)" -ge "$end_time" ]]; then
            break
        fi
    done
}

# Stream container logs in real-time
# Usage: _sse_stream_container_logs container_name [tail_lines]
_sse_stream_container_logs() {
    local container="$1"
    local lines="${2:-100}"

    docker logs -f --tail "$lines" "$container" 2>&1 | while IFS= read -r line; do
        local escaped="${line//\\/\\\\}"
        escaped="${escaped//\"/\\\"}"
        escaped="${escaped//$'\n'/\\n}"
        escaped="${escaped//$'\r'/\\r}"
        escaped="${escaped//$'\t'/\\t}"
        _sse_send_event "log-line" "{\"container\":\"$container\",\"line\":\"$escaped\"}"
    done
}

# Combined SSE stream: Docker events + periodic metrics + keepalives
# This is the main handler for the /stream endpoint
# Usage: _sse_stream_combined [duration_seconds]
_sse_stream_combined() {
    local duration="${1:-${SSE_DEFAULT_DURATION:-0}}"
    local metrics_interval="${SSE_METRICS_INTERVAL:-5}"
    local keepalive_interval="${SSE_KEEPALIVE_INTERVAL:-15}"
    local end_time=0
    [[ "$duration" -gt 0 ]] && end_time=$(( $(date +%s) + duration ))

    local last_metrics=0
    local last_keepalive=0

    # Send initial metrics immediately
    local metrics_json
    metrics_json=$(_sse_collect_metrics)
    _sse_send_event "metrics" "$metrics_json"

    # Start docker events in background, piping to our stdout
    local docker_pid=""
    {
        docker events --format '{{json .}}' 2>/dev/null | while IFS= read -r line; do
            [[ -n "$line" ]] && _sse_send_event "docker-event" "$line"
        done
    } &
    docker_pid=$!

    # Trap to clean up background process
    trap "kill $docker_pid 2>/dev/null; exit 0" EXIT INT TERM

    # Main loop: send metrics and keepalives at intervals
    while true; do
        local now
        now=$(date +%s)

        # Check duration limit
        if [[ "$end_time" -gt 0 && "$now" -ge "$end_time" ]]; then
            break
        fi

        # Send metrics at interval
        if (( now - last_metrics >= metrics_interval )); then
            metrics_json=$(_sse_collect_metrics)
            _sse_send_event "metrics" "$metrics_json"
            last_metrics=$now
        fi

        # Send keepalive at interval
        if (( now - last_keepalive >= keepalive_interval )); then
            _sse_send_comment "keepalive $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
            last_keepalive=$now
        fi

        sleep 1
    done

    # Clean up
    kill "$docker_pid" 2>/dev/null
    wait "$docker_pid" 2>/dev/null
}
