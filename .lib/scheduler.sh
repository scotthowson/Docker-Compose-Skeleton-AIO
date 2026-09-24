#!/bin/bash
# =============================================================================
# Scheduler Library v1.0
# Cron-like scheduled operations with JSON-based configuration
# Supports: backup, update, prune, health-check, restart, custom actions
#
# Dependencies: date, jq
# Requires: Bash 4+
# =============================================================================

if [[ -z "${BASE_DIR:-}" ]]; then
    BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

SCHEDULER_DIR="${BASE_DIR}/.data/schedules"
SCHEDULER_CONFIG="${SCHEDULER_DIR}/schedules.json"
SCHEDULER_LOG="${SCHEDULER_DIR}/scheduler.log"
SCHEDULER_PID_FILE="${BASE_DIR}/.data/scheduler.pid"
SCHEDULER_CHECK_INTERVAL="${SCHEDULER_CHECK_INTERVAL:-60}"

# =============================================================================
# INITIALIZATION
# =============================================================================

scheduler_init() {
    mkdir -p "$SCHEDULER_DIR" 2>/dev/null
    if [[ ! -f "$SCHEDULER_CONFIG" ]]; then
        echo '[]' > "$SCHEDULER_CONFIG"
    fi
}

# Generate a simple unique ID
_scheduler_gen_id() {
    printf '%s-%s' "$(date '+%s')" "$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
}

# =============================================================================
# CRUD OPERATIONS
# =============================================================================

# Replace schedules.json atomically; refuses anything that is not a JSON array
_scheduler_write_config() {
    local content="$1"
    local tmp_file="${SCHEDULER_CONFIG}.tmp"
    if ! printf '%s\n' "$content" | jq -c 'if type == "array" then . else empty end' > "$tmp_file" 2>/dev/null || [[ ! -s "$tmp_file" ]]; then
        rm -f "$tmp_file"
        return 1
    fi
    mv -f "$tmp_file" "$SCHEDULER_CONFIG"
}

# Add a new schedule
# Usage: scheduler_add name schedule_expr action [target]
scheduler_add() {
    local name="$1"
    local schedule_expr="$2"
    local action="$3"
    local target="${4:-}"

    scheduler_init

    local id created_at next_run
    id=$(_scheduler_gen_id)
    created_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    next_run=$(_scheduler_calculate_next_run "$schedule_expr")

    # Built with jq so names and targets are always valid JSON
    local new_entry
    new_entry=$(jq -nc --arg id "$id" --arg name "$name" --arg schedule "$schedule_expr" \
        --arg action "$action" --arg target "$target" --arg created "$created_at" --arg next "$next_run" \
        '{id: $id, name: $name, schedule: $schedule, action: $action, target: $target, enabled: true,
          created_at: $created, last_run: null, next_run: $next, run_count: 0}') || return 1

    local updated
    updated=$(jq -c --argjson e "$new_entry" '. + [$e]' "$SCHEDULER_CONFIG" 2>/dev/null) || updated="[$new_entry]"
    _scheduler_write_config "$updated" || return 1
    echo "$new_entry"
}

# Remove a schedule by ID
scheduler_remove() {
    local id="$1"
    scheduler_init
    local updated
    updated=$(jq -c --arg id "$id" '[.[] | select(.id != $id)]' "$SCHEDULER_CONFIG" 2>/dev/null) || return 1
    _scheduler_write_config "$updated"
}

# List all schedules as JSON array
scheduler_list() {
    scheduler_init
    jq -c 'if type == "array" then . else [] end' "$SCHEDULER_CONFIG" 2>/dev/null || echo '[]'
}

# Get a single schedule by ID
scheduler_get() {
    local id="$1"
    scheduler_init
    jq -c --arg id "$id" '[.[] | select(.id == $id)] | .[0] // {}' "$SCHEDULER_CONFIG" 2>/dev/null || echo '{}'
}

# Update a schedule field. Values that parse as JSON (true, 3, {...}) are
# stored typed; anything else is stored as a string. Prints the updated entry.
scheduler_update() {
    local id="$1"
    local field="$2"
    local value="$3"

    scheduler_init
    [[ "$field" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1

    local updated
    updated=$(jq -c --arg id "$id" --arg field "$field" --arg value "$value" \
        '(try ($value | fromjson) catch $value) as $v
         | map(if .id == $id then .[$field] = $v else . end)' "$SCHEDULER_CONFIG" 2>/dev/null) || return 1
    _scheduler_write_config "$updated" || return 1
    scheduler_get "$id"
}

# Toggle enabled state
scheduler_enable() {
    scheduler_update "$1" "enabled" "true"
}

scheduler_disable() {
    scheduler_update "$1" "enabled" "false"
}

# =============================================================================
# SCHEDULING LOGIC
# =============================================================================

# Calculate next run time from a schedule expression
# Supports: @hourly, @daily, @weekly, @monthly, HH:MM (daily), DOW HH:MM (weekly)
# Returns: ISO 8601 timestamp
_scheduler_calculate_next_run() {
    local expr="$1"
    local now
    now=$(date +%s)

    case "$expr" in
        @minutely|@1min)
            date -u -d "@$((now + 60))" '+%Y-%m-%dT%H:%M:00Z' 2>/dev/null || \
            date -u -r "$((now + 60))" '+%Y-%m-%dT%H:%M:00Z' 2>/dev/null
            ;;
        @5min)
            date -u -d "@$((now + 300))" '+%Y-%m-%dT%H:%M:00Z' 2>/dev/null || \
            date -u -r "$((now + 300))" '+%Y-%m-%dT%H:%M:00Z' 2>/dev/null
            ;;
        @15min)
            date -u -d "@$((now + 900))" '+%Y-%m-%dT%H:%M:00Z' 2>/dev/null || \
            date -u -r "$((now + 900))" '+%Y-%m-%dT%H:%M:00Z' 2>/dev/null
            ;;
        @30min)
            date -u -d "@$((now + 1800))" '+%Y-%m-%dT%H:%M:00Z' 2>/dev/null || \
            date -u -r "$((now + 1800))" '+%Y-%m-%dT%H:%M:00Z' 2>/dev/null
            ;;
        @hourly)
            date -u -d "@$((now + 3600))" '+%Y-%m-%dT%H:00:00Z' 2>/dev/null || \
            date -u -r "$((now + 3600))" '+%Y-%m-%dT%H:00:00Z' 2>/dev/null
            ;;
        @daily)
            date -u -d "tomorrow 00:00" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
            date -u -r "$((now + 86400))" '+%Y-%m-%dT00:00:00Z' 2>/dev/null
            ;;
        @weekly)
            date -u -d "next monday 00:00" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
            date -u -r "$((now + 604800))" '+%Y-%m-%dT00:00:00Z' 2>/dev/null
            ;;
        @monthly)
            date -u -d "$(date '+%Y-%m-01') + 1 month" '+%Y-%m-%dT00:00:00Z' 2>/dev/null || \
            date -u -r "$((now + 2592000))" '+%Y-%m-01T00:00:00Z' 2>/dev/null
            ;;
        [0-2][0-9]:[0-5][0-9])
            # Daily at HH:MM
            local target_today
            target_today=$(date -u -d "today $expr" '+%s' 2>/dev/null || echo 0)
            if [[ "$target_today" -gt "$now" ]]; then
                date -u -d "today $expr" '+%Y-%m-%dT%H:%M:00Z' 2>/dev/null
            else
                date -u -d "tomorrow $expr" '+%Y-%m-%dT%H:%M:00Z' 2>/dev/null
            fi
            ;;
        *)
            # Default: 24h from now
            date -u -d "@$((now + 86400))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
            date -u -r "$((now + 86400))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null
            ;;
    esac
}

# =============================================================================
# EXECUTION
# =============================================================================

# Execute a scheduled action
# A stack target must be a plain stack directory name with a compose file
_scheduler_stack_target_ok() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ && -f "$BASE_DIR/Stacks/$1/docker-compose.yml" ]]
}

_scheduler_execute() {
    local schedule_json="$1"
    local action target schedule_id name
    action=$(jq -r '.action // empty' <<< "$schedule_json" 2>/dev/null)
    target=$(jq -r '.target // empty' <<< "$schedule_json" 2>/dev/null)
    schedule_id=$(jq -r '.id // empty' <<< "$schedule_json" 2>/dev/null)
    name=$(jq -r '.name // empty' <<< "$schedule_json" 2>/dev/null)

    local start_time output success=true duration_ms
    start_time=$(date +%s%N 2>/dev/null || echo "$(date +%s)000000000")

    case "$action" in
        backup)
            output=$("$BASE_DIR/.scripts/backup-server.sh" 2>&1) || success=false
            ;;
        update)
            if _scheduler_stack_target_ok "$target"; then
                output=$(cd "$BASE_DIR/Stacks/$target" 2>/dev/null && ${DOCKER_COMPOSE_CMD:-docker compose} pull 2>&1 && ${DOCKER_COMPOSE_CMD:-docker compose} up -d 2>&1) || success=false
            else
                output="No valid target stack specified for update" && success=false
            fi
            ;;
        prune)
            output=$(docker system prune -f 2>&1) || success=false
            ;;
        health-check)
            output=$("$BASE_DIR/.scripts/health-check.sh" 2>&1) || success=false
            ;;
        restart)
            if _scheduler_stack_target_ok "$target"; then
                output=$(cd "$BASE_DIR/Stacks/$target" 2>/dev/null && ${DOCKER_COMPOSE_CMD:-docker compose} restart 2>&1) || success=false
            else
                output="No valid target stack specified for restart" && success=false
            fi
            ;;
        metrics-snapshot)
            # Capture CPU/mem/disk metrics and append to history
            local _mf="$BASE_DIR/.api-auth/metrics-history.jsonl"
            local _ts _ep _l1 _l5 _l15 _ncpu _cpct _mt _ma _mu _mpct _dpct
            _ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
            _ep=$(date +%s)
            read -r _l1 _l5 _l15 _ _ < /proc/loadavg 2>/dev/null || { _l1=0; _l5=0; _l15=0; }
            _ncpu=$(nproc 2>/dev/null || echo 1)
            _cpct=$(awk "BEGIN {v=$_l1/$_ncpu*100; if(v>100)v=100; printf \"%.1f\", v}")
            _mt=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
            _ma=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
            _mu=$((_mt - _ma))
            [[ "$_mt" -gt 0 ]] && _mpct=$(awk "BEGIN {printf \"%.1f\", $_mu/$_mt*100}") || _mpct=0
            _dpct=$(df -P "$BASE_DIR" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
            [[ -z "$_dpct" ]] && _dpct=$(df -P / 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
            [[ -z "$_dpct" ]] && _dpct=0
            echo "{\"ts\":\"$_ts\",\"epoch\":$_ep,\"cpu_pct\":$_cpct,\"load1\":$_l1,\"load5\":$_l5,\"load15\":$_l15,\"mem_used_mb\":$_mu,\"mem_total_mb\":$_mt,\"mem_pct\":$_mpct,\"disk_pct\":$_dpct}" >> "$_mf"
            local _lc; _lc=$(wc -l < "$_mf" 2>/dev/null) || _lc=0
            [[ "$_lc" -gt 10080 ]] && { tail -n 10080 "$_mf" > "$_mf.tmp" && mv "$_mf.tmp" "$_mf"; }
            output="Metrics snapshot captured (cpu: ${_cpct}%, mem: ${_mpct}%, disk: ${_dpct}%)"
            ;;
        custom)
            # Only executables that live inside this installation may be scheduled
            local _real
            _real=$(realpath -e -- "$target" 2>/dev/null)
            if [[ -n "$target" && "$target" == /* && -n "$_real" && "$_real" == "$BASE_DIR/"* && -f "$_real" && -x "$_real" ]]; then
                output=$(timeout 600 "$_real" 2>&1 | head -c 65536) || success=false
            else
                output="Custom script must be an executable file inside $BASE_DIR: $target" && success=false
            fi
            ;;
        *)
            output="Unknown action: $action" && success=false
            ;;
    esac

    local end_time
    end_time=$(date +%s%N 2>/dev/null || echo "$(date +%s)000000000")
    duration_ms=$(( (${end_time%??????} - ${start_time%??????}) ))
    [[ "$duration_ms" -lt 0 ]] && duration_ms=0

    # Log execution (one valid JSON object per line)
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    jq -nc --arg ts "$ts" --arg id "$schedule_id" --arg name "$name" --arg action "$action" --arg target "$target" \
        --argjson success "$success" --argjson duration "$duration_ms" --arg output "$(printf '%s' "$output" | head -c 500)" \
        '{timestamp: $ts, schedule_id: $id, name: $name, action: $action, target: $target, success: $success, duration_ms: $duration, output: $output}' \
        >> "$SCHEDULER_LOG" 2>/dev/null

    # Update schedule: last_run, next_run, run_count
    local next_run schedule_expr updated
    schedule_expr=$(jq -r '.schedule // empty' <<< "$schedule_json" 2>/dev/null)
    next_run=$(_scheduler_calculate_next_run "$schedule_expr")
    updated=$(jq -c --arg id "$schedule_id" --arg ts "$ts" --arg next "$next_run" \
        'map(if .id == $id then .last_run = $ts | .next_run = $next | .run_count = ((.run_count // 0) + 1) else . end)' \
        "$SCHEDULER_CONFIG" 2>/dev/null) && _scheduler_write_config "$updated"
}

# Check all schedules and execute due ones
scheduler_check_and_run() {
    scheduler_init
    local now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    jq -c --arg now "$now" '.[] | select(.enabled == true and ((.next_run // "") <= $now))' "$SCHEDULER_CONFIG" 2>/dev/null \
        | while IFS= read -r schedule_json; do
            [[ -z "$schedule_json" ]] && continue
            _scheduler_execute "$schedule_json"
        done
}

# =============================================================================
# DAEMON
# =============================================================================

scheduler_daemon_start() {
    scheduler_init

    if [[ -f "$SCHEDULER_PID_FILE" ]]; then
        local pid
        pid=$(cat "$SCHEDULER_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "Scheduler already running (PID $pid)"
            return 0
        fi
        rm -f "$SCHEDULER_PID_FILE"
    fi

    (
        trap 'rm -f "$SCHEDULER_PID_FILE"; exit 0' SIGTERM SIGINT EXIT
        echo $BASHPID > "$SCHEDULER_PID_FILE"

        while true; do
            scheduler_check_and_run
            sleep "$SCHEDULER_CHECK_INTERVAL"
        done
    ) &
    disown

    echo "Scheduler daemon started (check interval: ${SCHEDULER_CHECK_INTERVAL}s)"
}

scheduler_daemon_stop() {
    if [[ -f "$SCHEDULER_PID_FILE" ]]; then
        local pid
        pid=$(cat "$SCHEDULER_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            rm -f "$SCHEDULER_PID_FILE"
            echo "Scheduler daemon stopped (PID $pid)"
        else
            rm -f "$SCHEDULER_PID_FILE"
            echo "Scheduler daemon was not running"
        fi
    else
        echo "Scheduler daemon is not running"
    fi
}

# Return execution history for a schedule
# Usage: scheduler_history schedule_id
scheduler_history() {
    local schedule_id="${1:-}"

    if [[ ! -f "$SCHEDULER_LOG" ]]; then
        echo '[]'
        return 0
    fi

    tail -50 "$SCHEDULER_LOG" \
        | jq -Rc --arg id "$schedule_id" 'fromjson? | select(type == "object" and ($id == "" or .schedule_id == $id))' 2>/dev/null \
        | jq -sc '.' 2>/dev/null || echo '[]'
}
