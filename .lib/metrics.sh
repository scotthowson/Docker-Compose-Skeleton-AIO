#!/bin/bash
# =============================================================================
# Metrics Collection & Storage Library v1.0
# Stores time-series data in JSONL format for historical trending
# Provides collection, querying, rotation, and background daemon
#
# Dependencies: docker, /proc filesystem, awk, date
# Requires: Bash 4+
# =============================================================================

if [[ -z "${BASE_DIR:-}" ]]; then
    BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# Configuration
METRICS_DATA_DIR="${BASE_DIR}/.data/metrics"
METRICS_FILE="${METRICS_DATA_DIR}/system.jsonl"
METRICS_COLLECT_INTERVAL="${METRICS_COLLECT_INTERVAL:-30}"
METRICS_RETENTION_DAYS="${METRICS_RETENTION_DAYS:-7}"
METRICS_PID_FILE="/tmp/dcs-metrics-collector.pid"

# =============================================================================
# INITIALIZATION
# =============================================================================

metrics_init() {
    mkdir -p "$METRICS_DATA_DIR" 2>/dev/null
    touch "$METRICS_FILE" 2>/dev/null
}

# =============================================================================
# COLLECTION
# =============================================================================

# Gather current system metrics and output as a single JSON line
metrics_collect_snapshot() {
    local ts cpu_percent mem_percent mem_used_mb mem_total_mb
    local load_1 load_5 load_15
    local disk_percent disk_used_gb disk_total_gb
    local containers_total containers_running containers_stopped
    local images_count networks_count volumes_count

    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    # Load average
    if [[ -f /proc/loadavg ]]; then
        read -r load_1 load_5 load_15 _ < /proc/loadavg
    else
        load_1=0; load_5=0; load_15=0
    fi

    # Memory
    if [[ -f /proc/meminfo ]]; then
        local mem_total_kb mem_avail_kb
        mem_total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
        mem_avail_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
        mem_total_mb=$(( ${mem_total_kb:-0} / 1024 ))
        mem_used_mb=$(( (${mem_total_kb:-0} - ${mem_avail_kb:-0}) / 1024 ))
        if [[ "${mem_total_kb:-0}" -gt 0 ]]; then
            mem_percent=$(( (${mem_total_kb} - ${mem_avail_kb:-0}) * 100 / ${mem_total_kb} ))
        else
            mem_percent=0
        fi
    else
        mem_total_mb=0; mem_used_mb=0; mem_percent=0
    fi

    # CPU from load average
    local cpu_count
    cpu_count=$(nproc 2>/dev/null || echo 1)
    cpu_percent=$(awk "BEGIN {v=${load_1:-0}/${cpu_count}*100; if(v>100)v=100; printf \"%.1f\", v}")

    # Disk: use largest real filesystem (not root/boot/tmpfs) — typically /home
    local disk_info
    disk_info=$(df -B1 -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs -x vfat 2>/dev/null | awk 'NR>1 && $6 !~ /^\/$|^\/boot|^\/snap|^\/dev|^\/run|^\/sys|^\/proc/ {print $2, $3, $5}' | sort -k1 -nr | head -1)
    [[ -z "$disk_info" ]] && disk_info=$(df -B1 / 2>/dev/null | awk 'NR==2 {print $2, $3, $5}')
    if [[ -n "$disk_info" ]]; then
        local d_total d_used d_pct
        read -r d_total d_used d_pct <<< "$disk_info"
        disk_total_gb=$(awk "BEGIN {printf \"%.1f\", ${d_total:-0}/1073741824}")
        disk_used_gb=$(awk "BEGIN {printf \"%.1f\", ${d_used:-0}/1073741824}")
        disk_percent="${d_pct//%/}"
    else
        disk_total_gb=0; disk_used_gb=0; disk_percent=0
    fi

    # Docker counts
    containers_total=$(docker ps -a -q 2>/dev/null | wc -l)
    containers_running=$(docker ps -q 2>/dev/null | wc -l)
    containers_stopped=$(( containers_total - containers_running ))
    images_count=$(docker images -q 2>/dev/null | wc -l)
    networks_count=$(docker network ls -q 2>/dev/null | wc -l)
    volumes_count=$(docker volume ls -q 2>/dev/null | wc -l)

    printf '{"ts":"%s","cpu_percent":%s,"memory_percent":%s,"memory_used_mb":%s,"memory_total_mb":%s,"load_1m":%s,"load_5m":%s,"load_15m":%s,"disk_percent":%s,"disk_used_gb":%s,"disk_total_gb":%s,"containers_total":%s,"containers_running":%s,"containers_stopped":%s,"images_count":%s,"networks_count":%s,"volumes_count":%s}\n' \
        "$ts" "${cpu_percent:-0}" "${mem_percent:-0}" "${mem_used_mb:-0}" "${mem_total_mb:-0}" \
        "${load_1:-0}" "${load_5:-0}" "${load_15:-0}" \
        "${disk_percent:-0}" "${disk_used_gb:-0}" "${disk_total_gb:-0}" \
        "${containers_total:-0}" "${containers_running:-0}" "${containers_stopped:-0}" \
        "${images_count:-0}" "${networks_count:-0}" "${volumes_count:-0}"
}

# Collect and append a metrics snapshot to the JSONL file
metrics_write() {
    metrics_init
    metrics_collect_snapshot >> "$METRICS_FILE"
}

# =============================================================================
# QUERYING
# =============================================================================

# Return the most recent metrics entry (or collect fresh)
metrics_latest() {
    if [[ -s "$METRICS_FILE" ]]; then
        tail -1 "$METRICS_FILE"
    else
        metrics_collect_snapshot
    fi
}

# Query metrics for a time range, output as JSON array
# Usage: metrics_query "1h" | "6h" | "24h" | "7d"
metrics_query() {
    local range="${1:-24h}"
    local seconds=86400

    case "$range" in
        1h)  seconds=3600 ;;
        6h)  seconds=21600 ;;
        24h) seconds=86400 ;;
        7d)  seconds=604800 ;;
        *)   seconds=86400 ;;
    esac

    local cutoff
    cutoff=$(date -u -d "@$(($(date +%s) - seconds))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
             date -u -r "$(($(date +%s) - seconds))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
             echo "1970-01-01T00:00:00Z")

    if [[ ! -s "$METRICS_FILE" ]]; then
        echo '[]'
        return 0
    fi

    # Read file and filter by timestamp, output as JSON array
    awk -v cutoff="$cutoff" '
    BEGIN { printf "["; sep="" }
    {
        # Extract ts field
        match($0, /"ts":"([^"]+)"/, arr)
        if (arr[1] >= cutoff) {
            printf "%s%s", sep, $0
            sep=","
        }
    }
    END { print "]" }
    ' "$METRICS_FILE"
}

# Return summary statistics for a time range
# Usage: metrics_summary "24h"
metrics_summary() {
    local range="${1:-24h}"
    local data
    data=$(metrics_query "$range")

    if [[ "$data" == "[]" ]]; then
        printf '{"range":"%s","cpu":{"min":0,"max":0,"avg":0},"memory":{"min":0,"max":0,"avg":0},"disk":{"min":0,"max":0,"avg":0}}' "$range"
        return 0
    fi

    echo "$data" | awk '
    BEGIN {
        cpu_min=999; cpu_max=0; cpu_sum=0
        mem_min=999; mem_max=0; mem_sum=0
        disk_min=999; disk_max=0; disk_sum=0
        count=0
    }
    {
        # Parse cpu_percent
        if (match($0, /"cpu_percent":([0-9.]+)/, a)) {
            v = a[1]+0
            if (v < cpu_min) cpu_min = v
            if (v > cpu_max) cpu_max = v
            cpu_sum += v
        }
        if (match($0, /"memory_percent":([0-9.]+)/, a)) {
            v = a[1]+0
            if (v < mem_min) mem_min = v
            if (v > mem_max) mem_max = v
            mem_sum += v
        }
        if (match($0, /"disk_percent":([0-9.]+)/, a)) {
            v = a[1]+0
            if (v < disk_min) disk_min = v
            if (v > disk_max) disk_max = v
            disk_sum += v
        }
        count++
    }
    END {
        if (count == 0) count = 1
        if (cpu_min == 999) cpu_min = 0
        if (mem_min == 999) mem_min = 0
        if (disk_min == 999) disk_min = 0
        printf "{\"range\":\"%s\",\"cpu\":{\"min\":%.1f,\"max\":%.1f,\"avg\":%.1f},\"memory\":{\"min\":%.1f,\"max\":%.1f,\"avg\":%.1f},\"disk\":{\"min\":%.1f,\"max\":%.1f,\"avg\":%.1f}}", \
            "'"$range"'", cpu_min, cpu_max, cpu_sum/count, mem_min, mem_max, mem_sum/count, disk_min, disk_max, disk_sum/count
    }
    ' RS='},{' ORS='},{'
}

# =============================================================================
# ROTATION
# =============================================================================

# Remove entries older than retention period
metrics_rotate() {
    local retention_days="${METRICS_RETENTION_DAYS:-7}"
    local cutoff
    cutoff=$(date -u -d "@$(($(date +%s) - retention_days * 86400))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
             date -u -r "$(($(date +%s) - retention_days * 86400))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
             echo "1970-01-01T00:00:00Z")

    if [[ ! -s "$METRICS_FILE" ]]; then
        return 0
    fi

    local tmp_file="${METRICS_FILE}.tmp"
    awk -v cutoff="$cutoff" '
    {
        match($0, /"ts":"([^"]+)"/, arr)
        if (arr[1] >= cutoff) print
    }
    ' "$METRICS_FILE" > "$tmp_file"
    mv "$tmp_file" "$METRICS_FILE"
}

# =============================================================================
# BACKGROUND COLLECTOR DAEMON
# =============================================================================

# Start background metrics collection loop
metrics_collector_start() {
    metrics_init

    # Check if already running
    if [[ -f "$METRICS_PID_FILE" ]]; then
        local pid
        pid=$(cat "$METRICS_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "Metrics collector already running (PID $pid)"
            return 0
        fi
        rm -f "$METRICS_PID_FILE"
    fi

    (
        trap 'rm -f "$METRICS_PID_FILE"; exit 0' SIGTERM SIGINT EXIT
        echo $BASHPID > "$METRICS_PID_FILE"

        local rotate_counter=0
        while true; do
            metrics_write

            # Rotate once per hour (interval-count based)
            rotate_counter=$((rotate_counter + 1))
            if (( rotate_counter * METRICS_COLLECT_INTERVAL >= 3600 )); then
                metrics_rotate
                rotate_counter=0
            fi

            sleep "$METRICS_COLLECT_INTERVAL"
        done
    ) &
    disown

    echo "Metrics collector started (interval: ${METRICS_COLLECT_INTERVAL}s)"
}

# Stop the background metrics collector
metrics_collector_stop() {
    if [[ -f "$METRICS_PID_FILE" ]]; then
        local pid
        pid=$(cat "$METRICS_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            rm -f "$METRICS_PID_FILE"
            echo "Metrics collector stopped (PID $pid)"
        else
            rm -f "$METRICS_PID_FILE"
            echo "Metrics collector was not running"
        fi
    else
        echo "Metrics collector is not running"
    fi
}
