#!/bin/bash
# =============================================================================
# Docker Compose Skeleton — Health Check System
# Comprehensive container health monitoring with beautiful formatted output
#
# Usage:
#   Standalone:  ./health-check.sh [--quiet] [--json] [--stack <name>]
#   Sourced:     source health-check.sh; run_health_check
#
# Exit codes:
#   0 — All containers healthy
#   1 — One or more containers have issues
#
# Dependencies (when sourced):
#   $COMPOSE_DIR — path to Stacks/ directory
#   $BASE_DIR    — repository root
#   Logger functions (log_info, etc.) are optional; falls back to echo
# =============================================================================

# =============================================================================
# PATH AUTO-DETECTION
# =============================================================================

# Detect BASE_DIR from script location if not already set
if [[ -z "${BASE_DIR:-}" ]]; then
    _HC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    BASE_DIR="$(cd "$_HC_SCRIPT_DIR/.." && pwd)"
    unset _HC_SCRIPT_DIR
fi

COMPOSE_DIR="${COMPOSE_DIR:-$BASE_DIR/Stacks}"

# Detect Docker Compose command if not already set
if [[ -z "${DOCKER_COMPOSE_CMD:-}" ]]; then
    if docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker-compose"
    else
        DOCKER_COMPOSE_CMD="docker compose"
    fi
fi

# =============================================================================
# COLOR SETUP (standalone mode)
# =============================================================================

# If colors are not already loaded, set up a minimal palette
if [[ -z "${COLOR_RESET:-}" ]]; then
    if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]] && command -v tput >/dev/null 2>&1; then
        _HC_COLORS=true
        _HC_RESET="$(tput sgr0)"
        _HC_BOLD="$(tput bold)"
        _HC_DIM="$(tput dim)"
        _HC_GREEN="$(tput setaf 82)"
        _HC_YELLOW="$(tput setaf 214)"
        _HC_RED="$(tput setaf 196)"
        _HC_CYAN="$(tput setaf 51)"
        _HC_BLUE="$(tput setaf 33)"
        _HC_GRAY="$(tput setaf 245)"
        _HC_WHITE="$(tput setaf 15)"
        _HC_MAGENTA="$(tput setaf 141)"
    else
        _HC_COLORS=false
        _HC_RESET="" _HC_BOLD="" _HC_DIM=""
        _HC_GREEN="" _HC_YELLOW="" _HC_RED="" _HC_CYAN=""
        _HC_BLUE="" _HC_GRAY="" _HC_WHITE="" _HC_MAGENTA=""
    fi
else
    _HC_COLORS=true
    _HC_RESET="${COLOR_RESET}"
    _HC_BOLD="${COLOR_BOLD:-}"
    _HC_DIM="${COLOR_DIM:-}"
    _HC_GREEN="${COLOR_SUCCESS:-$(tput setaf 82 2>/dev/null)}"
    _HC_YELLOW="${COLOR_WARNING:-$(tput setaf 214 2>/dev/null)}"
    _HC_RED="${COLOR_CRITICAL:-$(tput setaf 196 2>/dev/null)}"
    _HC_CYAN="${COLOR_PROMPT:-$(tput setaf 51 2>/dev/null)}"
    _HC_BLUE="${COLOR_FOCUS:-$(tput setaf 33 2>/dev/null)}"
    _HC_GRAY="${COLOR_NEUTRAL:-$(tput setaf 245 2>/dev/null)}"
    _HC_WHITE="$(tput setaf 15 2>/dev/null)"
    _HC_MAGENTA="${COLOR_INFO_HEADER:-$(tput setaf 141 2>/dev/null)}"
fi

# =============================================================================
# INTERNAL UTILITIES
# =============================================================================

# Safe logging: use log_* if available, otherwise echo
_hc_log() {
    local level="$1"; shift
    if command -v "log_${level}" >/dev/null 2>&1; then
        "log_${level}" "$*"
    else
        echo "[$level] $*"
    fi
}

# Format seconds into a human-readable duration
_hc_format_uptime() {
    local total_seconds="${1:-0}"

    if ! [[ "$total_seconds" =~ ^[0-9]+$ ]] || (( total_seconds < 0 )); then
        echo "--"
        return
    fi

    local days=$(( total_seconds / 86400 ))
    local hours=$(( (total_seconds % 86400) / 3600 ))
    local minutes=$(( (total_seconds % 3600) / 60 ))
    local seconds=$(( total_seconds % 60 ))

    if (( days > 0 )); then
        printf "%dd %dh %dm" "$days" "$hours" "$minutes"
    elif (( hours > 0 )); then
        printf "%dh %dm %ds" "$hours" "$minutes" "$seconds"
    elif (( minutes > 0 )); then
        printf "%dm %ds" "$minutes" "$seconds"
    else
        printf "%ds" "$seconds"
    fi
}

# Format bytes to human-readable
_hc_format_memory() {
    local mem_str="$1"
    # Docker stats returns something like "150.2MiB / 16GiB" — just take the usage part
    echo "${mem_str%%/*}" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//'
}

# Repeat a character N times
_hc_repeat_char() {
    local char="$1"
    local count="$2"
    printf "%0.s${char}" $(seq 1 "$count")
}

# =============================================================================
# BATCHED STATS COLLECTION
# =============================================================================

# Pre-fetch memory stats for all containers in a single Docker API call.
# Populates the _HC_STATS_CACHE associative array: container_name -> mem_usage
declare -gA _HC_STATS_CACHE=()
_HC_STATS_LOADED=false

_hc_load_stats_cache() {
    [[ "$_HC_STATS_LOADED" == "true" ]] && return
    _HC_STATS_LOADED=true

    if [[ "${_HC_QUIET:-false}" == "true" ]]; then
        return
    fi

    local line
    while IFS='|' read -r name mem; do
        [[ -z "$name" ]] && continue
        # Strip leading slash and whitespace
        name="${name#/}"
        name="${name## }"
        name="${name%% }"
        _HC_STATS_CACHE["$name"]="$(_hc_format_memory "$mem")"
    done < <(docker stats --no-stream --format '{{.Name}}|{{.MemUsage}}' 2>/dev/null)
}

# =============================================================================
# CONTAINER INSPECTION
# =============================================================================

# Inspect a single container and populate result variables
# Sets: _CONT_STATE, _CONT_HEALTH, _CONT_UPTIME, _CONT_MEMORY, _CONT_STATUS_COLOR, _CONT_BADGE
_hc_inspect_container() {
    local container_name="$1"

    _CONT_STATE="unknown"
    _CONT_HEALTH="none"
    _CONT_UPTIME="--"
    _CONT_MEMORY="--"
    _CONT_STATUS_COLOR="${_HC_GRAY}"
    _CONT_BADGE="[UNKNOWN]"

    # Check if container exists
    if ! docker inspect "$container_name" >/dev/null 2>&1; then
        _CONT_STATE="not found"
        _CONT_STATUS_COLOR="${_HC_RED}"
        _CONT_BADGE="[NOT FOUND]"
        return 1
    fi

    # Running state
    local running
    running="$(docker inspect --format='{{.State.Running}}' "$container_name" 2>/dev/null)"

    if [[ "$running" != "true" ]]; then
        _CONT_STATE="stopped"
        _CONT_STATUS_COLOR="${_HC_RED}"
        _CONT_BADGE="[ STOPPED ]"
        return 1
    fi

    _CONT_STATE="running"

    # Health status
    local health_status
    health_status="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_name" 2>/dev/null)"

    case "$health_status" in
        healthy)
            _CONT_HEALTH="healthy"
            _CONT_STATUS_COLOR="${_HC_GREEN}"
            _CONT_BADGE="[ HEALTHY ]"
            ;;
        unhealthy)
            _CONT_HEALTH="unhealthy"
            _CONT_STATUS_COLOR="${_HC_RED}"
            _CONT_BADGE="[UNHEALTHY]"
            ;;
        starting)
            _CONT_HEALTH="starting"
            _CONT_STATUS_COLOR="${_HC_YELLOW}"
            _CONT_BADGE="[STARTING ]"
            ;;
        none|"")
            _CONT_HEALTH="none"
            _CONT_STATUS_COLOR="${_HC_GREEN}"
            _CONT_BADGE="[  RUNNING]"
            ;;
        *)
            _CONT_HEALTH="$health_status"
            _CONT_STATUS_COLOR="${_HC_YELLOW}"
            _CONT_BADGE="[ $health_status ]"
            ;;
    esac

    # Uptime calculation
    local started_at
    started_at="$(docker inspect --format='{{.State.StartedAt}}' "$container_name" 2>/dev/null)"
    if [[ -n "$started_at" ]] && [[ "$started_at" != "0001-01-01T00:00:00Z" ]]; then
        local start_epoch now_epoch
        start_epoch="$(date -d "$started_at" +%s 2>/dev/null)" || start_epoch=""
        now_epoch="$(date +%s)"
        if [[ -n "$start_epoch" ]]; then
            local uptime_seconds=$(( now_epoch - start_epoch ))
            _CONT_UPTIME="$(_hc_format_uptime "$uptime_seconds")"
        fi
    fi

    # Memory usage from batched stats cache (avoids per-container docker stats calls)
    if [[ "${_HC_QUIET:-false}" != "true" ]]; then
        _hc_load_stats_cache
        if [[ -n "${_HC_STATS_CACHE[$container_name]+_}" ]]; then
            _CONT_MEMORY="${_HC_STATS_CACHE[$container_name]}"
        fi
    fi

    return 0
}

# =============================================================================
# TABLE RENDERING ENGINE
# =============================================================================

# Column widths (minimum sizes, expanded as needed)
declare -g _HC_COL_NAME=28
declare -g _HC_COL_STATUS=12
declare -g _HC_COL_HEALTH=12
declare -g _HC_COL_UPTIME=16
declare -g _HC_COL_MEMORY=14

_hc_render_table_border() {
    local style="${1:-middle}"  # top, middle, bottom

    local left middle right hchar
    case "$style" in
        top)    left="╔" middle="╦" right="╗" hchar="═" ;;
        middle) left="╠" middle="╬" right="╣" hchar="═" ;;
        bottom) left="╚" middle="╩" right="╝" hchar="═" ;;
    esac

    printf "%s" "${_HC_BLUE}${left}"
    _hc_repeat_char "$hchar" $(( _HC_COL_NAME + 2 ))
    printf "%s" "$middle"
    _hc_repeat_char "$hchar" $(( _HC_COL_STATUS + 2 ))
    printf "%s" "$middle"
    _hc_repeat_char "$hchar" $(( _HC_COL_HEALTH + 2 ))
    printf "%s" "$middle"
    _hc_repeat_char "$hchar" $(( _HC_COL_UPTIME + 2 ))
    printf "%s" "$middle"
    _hc_repeat_char "$hchar" $(( _HC_COL_MEMORY + 2 ))
    printf "%s${_HC_RESET}\n" "$right"
}

_hc_render_table_row() {
    local name="$1"
    local status="$2"
    local health="$3"
    local uptime="$4"
    local memory="$5"
    local color="${6:-${_HC_RESET}}"

    printf "${_HC_BLUE}║${_HC_RESET} ${color}%-${_HC_COL_NAME}s${_HC_RESET} " "$name"
    printf "${_HC_BLUE}║${_HC_RESET} ${color}%-${_HC_COL_STATUS}s${_HC_RESET} " "$status"
    printf "${_HC_BLUE}║${_HC_RESET} ${color}%-${_HC_COL_HEALTH}s${_HC_RESET} " "$health"
    printf "${_HC_BLUE}║${_HC_RESET} ${color}%-${_HC_COL_UPTIME}s${_HC_RESET} " "$uptime"
    printf "${_HC_BLUE}║${_HC_RESET} ${color}%-${_HC_COL_MEMORY}s${_HC_RESET} ${_HC_BLUE}║${_HC_RESET}\n" "$memory"
}

_hc_render_header() {
    _hc_render_table_border "top"
    printf "${_HC_BLUE}║${_HC_RESET} ${_HC_BOLD}${_HC_CYAN}%-${_HC_COL_NAME}s${_HC_RESET} " "CONTAINER"
    printf "${_HC_BLUE}║${_HC_RESET} ${_HC_BOLD}${_HC_CYAN}%-${_HC_COL_STATUS}s${_HC_RESET} " "STATE"
    printf "${_HC_BLUE}║${_HC_RESET} ${_HC_BOLD}${_HC_CYAN}%-${_HC_COL_HEALTH}s${_HC_RESET} " "HEALTH"
    printf "${_HC_BLUE}║${_HC_RESET} ${_HC_BOLD}${_HC_CYAN}%-${_HC_COL_UPTIME}s${_HC_RESET} " "UPTIME"
    printf "${_HC_BLUE}║${_HC_RESET} ${_HC_BOLD}${_HC_CYAN}%-${_HC_COL_MEMORY}s${_HC_RESET} ${_HC_BLUE}║${_HC_RESET}\n" "MEMORY"
    _hc_render_table_border "middle"
}

# =============================================================================
# STANDALONE BANNER
# =============================================================================

_hc_show_banner() {
    local width=92
    local border
    border="$(_hc_repeat_char "=" "$width")"

    echo ""
    echo "${_HC_BOLD}${_HC_BLUE}${border}${_HC_RESET}"
    printf "${_HC_BOLD}${_HC_CYAN}%*s${_HC_RESET}\n" $(( (width + 34) / 2 )) "Docker Compose Skeleton"
    printf "${_HC_DIM}${_HC_GRAY}%*s${_HC_RESET}\n" $(( (width + 37) / 2 )) "Container Health Check Report"
    printf "${_HC_DIM}${_HC_GRAY}%*s${_HC_RESET}\n" $(( (width + ${#border}) / 2 )) "$(date '+%Y-%m-%d %H:%M:%S')"
    echo "${_HC_BOLD}${_HC_BLUE}${border}${_HC_RESET}"
    echo ""
}

# =============================================================================
# SUMMARY DISPLAY
# =============================================================================

_hc_render_summary() {
    local total="$1"
    local healthy="$2"
    local unhealthy="$3"
    local stopped="$4"
    local no_check="$5"

    local width=92
    local border
    border="$(_hc_repeat_char "-" "$width")"

    echo ""
    echo "${_HC_DIM}${_HC_GRAY}${border}${_HC_RESET}"
    echo ""

    # Summary badges
    printf "  ${_HC_BOLD}${_HC_WHITE}SUMMARY${_HC_RESET}   "
    printf "${_HC_BOLD}${_HC_CYAN}Total: %-4d${_HC_RESET}  " "$total"
    printf "${_HC_BOLD}${_HC_GREEN}Healthy: %-4d${_HC_RESET}  " "$healthy"

    if (( unhealthy > 0 )); then
        printf "${_HC_BOLD}${_HC_RED}Unhealthy: %-4d${_HC_RESET}  " "$unhealthy"
    else
        printf "${_HC_DIM}${_HC_GRAY}Unhealthy: %-4d${_HC_RESET}  " "$unhealthy"
    fi

    if (( stopped > 0 )); then
        printf "${_HC_BOLD}${_HC_RED}Stopped: %-4d${_HC_RESET}  " "$stopped"
    else
        printf "${_HC_DIM}${_HC_GRAY}Stopped: %-4d${_HC_RESET}  " "$stopped"
    fi

    printf "${_HC_DIM}${_HC_GRAY}No Check: %-4d${_HC_RESET}" "$no_check"
    echo ""

    # Overall status
    echo ""
    if (( unhealthy == 0 && stopped == 0 )); then
        echo "  ${_HC_BOLD}${_HC_GREEN}STATUS: ALL SYSTEMS OPERATIONAL${_HC_RESET}"
    elif (( stopped > 0 )); then
        echo "  ${_HC_BOLD}${_HC_RED}STATUS: CRITICAL -- ${stopped} container(s) stopped${_HC_RESET}"
    else
        echo "  ${_HC_BOLD}${_HC_YELLOW}STATUS: WARNING -- ${unhealthy} container(s) unhealthy${_HC_RESET}"
    fi

    echo ""
    echo "${_HC_DIM}${_HC_GRAY}${border}${_HC_RESET}"
    echo ""
}

# =============================================================================
# JSON OUTPUT
# =============================================================================

_hc_json_output() {
    local -n _containers_ref=$1
    local total="${2:-0}"
    local healthy="${3:-0}"
    local unhealthy="${4:-0}"
    local stopped="${5:-0}"

    echo "{"
    echo "  \"timestamp\": \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\","
    echo "  \"hostname\": \"$(hostname)\","
    echo "  \"summary\": {"
    echo "    \"total\": $total,"
    echo "    \"healthy\": $healthy,"
    echo "    \"unhealthy\": $unhealthy,"
    echo "    \"stopped\": $stopped"
    echo "  },"
    echo "  \"containers\": ["

    local first=true
    local entry
    for entry in "${_containers_ref[@]}"; do
        IFS='|' read -r name state health uptime memory <<< "$entry"
        [[ "$first" == "true" ]] && first=false || echo ","
        printf '    {"name": "%s", "state": "%s", "health": "%s", "uptime": "%s", "memory": "%s"}' \
            "$name" "$state" "$health" "$uptime" "$memory"
    done

    echo ""
    echo "  ],"
    if (( unhealthy == 0 && stopped == 0 )); then
        echo "  \"status\": \"healthy\""
    else
        echo "  \"status\": \"degraded\""
    fi
    echo "}"
}

# =============================================================================
# MAIN HEALTH CHECK FUNCTION
# =============================================================================

run_health_check() {
    local output_mode="${1:-table}"   # table, json, quiet
    local filter_stack="${2:-}"       # optional: only check one stack

    # Counters
    local total_containers=0
    local healthy_count=0
    local unhealthy_count=0
    local stopped_count=0
    local no_check_count=0

    # Collected container data for JSON output
    local -a container_data=()

    # Verify Docker is available
    if ! command -v docker >/dev/null 2>&1; then
        _hc_log "error" "Docker is not installed or not in PATH"
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        _hc_log "error" "Docker daemon is not running or not accessible"
        return 1
    fi

    # Determine which stacks to check
    local -a stacks_to_check=()
    if [[ -n "$filter_stack" ]]; then
        stacks_to_check=("$filter_stack")
    elif [[ -d "${COMPOSE_DIR:-}" ]]; then
        local stack_dir
        for stack_dir in "$COMPOSE_DIR"/*/; do
            [[ -d "$stack_dir" ]] || continue
            [[ -f "$stack_dir/docker-compose.yml" ]] || continue
            stacks_to_check+=("$(basename "$stack_dir")")
        done
    fi

    # If no stacks found, fall back to checking all running containers
    local use_stacks=true
    if [[ ${#stacks_to_check[@]} -eq 0 ]]; then
        use_stacks=false
    fi

    # Show header for table mode
    if [[ "$output_mode" == "table" ]]; then
        _hc_render_header
    fi

    if [[ "$use_stacks" == "true" ]]; then
        # Iterate through stacks
        for stack_name in "${stacks_to_check[@]}"; do
            local stack_path="${COMPOSE_DIR}/${stack_name}"
            local compose_file="${stack_path}/docker-compose.yml"

            [[ -f "$compose_file" ]] || continue

            # Get containers for this stack
            local -a stack_containers=()
            local container_line
            while IFS= read -r container_line; do
                [[ -n "$container_line" ]] && stack_containers+=("$container_line")
            done < <($DOCKER_COMPOSE_CMD -f "$compose_file" ps --format '{{.Name}}' 2>/dev/null)

            # If no containers from compose, try project label
            if [[ ${#stack_containers[@]} -eq 0 ]]; then
                while IFS= read -r container_line; do
                    [[ -n "$container_line" ]] && stack_containers+=("$container_line")
                done < <(docker ps -a --filter "label=com.docker.compose.project.working_dir=${stack_path}" --format '{{.Names}}' 2>/dev/null)
            fi

            [[ ${#stack_containers[@]} -eq 0 ]] && continue

            # Stack section header in table mode
            if [[ "$output_mode" == "table" ]]; then
                local stack_label
                stack_label="$(echo "$stack_name" | tr '-' ' ' | sed 's/\b\(.\)/\u\1/g')"
                printf "${_HC_BLUE}║${_HC_RESET} ${_HC_BOLD}${_HC_MAGENTA}%-${_HC_COL_NAME}s${_HC_RESET} " "$stack_label"
                printf "${_HC_BLUE}║${_HC_RESET} ${_HC_DIM}${_HC_GRAY}%-${_HC_COL_STATUS}s${_HC_RESET} " ""
                printf "${_HC_BLUE}║${_HC_RESET} ${_HC_DIM}${_HC_GRAY}%-${_HC_COL_HEALTH}s${_HC_RESET} " ""
                printf "${_HC_BLUE}║${_HC_RESET} ${_HC_DIM}${_HC_GRAY}%-${_HC_COL_UPTIME}s${_HC_RESET} " ""
                printf "${_HC_BLUE}║${_HC_RESET} ${_HC_DIM}${_HC_GRAY}%-${_HC_COL_MEMORY}s${_HC_RESET} ${_HC_BLUE}║${_HC_RESET}\n" ""
            fi

            for container in "${stack_containers[@]}"; do
                (( total_containers++ ))

                _hc_inspect_container "$container"

                # Update counters
                case "$_CONT_STATE" in
                    running)
                        case "$_CONT_HEALTH" in
                            healthy)    (( healthy_count++ )) ;;
                            unhealthy)  (( unhealthy_count++ )) ;;
                            starting)   (( healthy_count++ )) ;;
                            none)       (( no_check_count++ )); (( healthy_count++ )) ;;
                            *)          (( healthy_count++ )) ;;
                        esac
                        ;;
                    stopped|"not found")
                        (( stopped_count++ ))
                        ;;
                esac

                # Collect data
                container_data+=("${container}|${_CONT_STATE}|${_CONT_HEALTH}|${_CONT_UPTIME}|${_CONT_MEMORY}")

                # Render table row
                if [[ "$output_mode" == "table" ]]; then
                    local display_name="  $container"
                    # Truncate long names
                    if [[ ${#display_name} -gt $_HC_COL_NAME ]]; then
                        display_name="${display_name:0:$(( _HC_COL_NAME - 2 ))}.."
                    fi
                    _hc_render_table_row \
                        "$display_name" \
                        "$_CONT_STATE" \
                        "$_CONT_BADGE" \
                        "$_CONT_UPTIME" \
                        "$_CONT_MEMORY" \
                        "$_CONT_STATUS_COLOR"
                fi
            done
        done
    else
        # No stacks — check all running containers
        local container_line
        while IFS= read -r container_line; do
            [[ -z "$container_line" ]] && continue
            (( total_containers++ ))

            _hc_inspect_container "$container_line"

            case "$_CONT_STATE" in
                running)
                    case "$_CONT_HEALTH" in
                        healthy)    (( healthy_count++ )) ;;
                        unhealthy)  (( unhealthy_count++ )) ;;
                        starting)   (( healthy_count++ )) ;;
                        none)       (( no_check_count++ )); (( healthy_count++ )) ;;
                        *)          (( healthy_count++ )) ;;
                    esac
                    ;;
                stopped|"not found")
                    (( stopped_count++ ))
                    ;;
            esac

            container_data+=("${container_line}|${_CONT_STATE}|${_CONT_HEALTH}|${_CONT_UPTIME}|${_CONT_MEMORY}")

            if [[ "$output_mode" == "table" ]]; then
                local display_name="$container_line"
                if [[ ${#display_name} -gt $_HC_COL_NAME ]]; then
                    display_name="${display_name:0:$(( _HC_COL_NAME - 2 ))}.."
                fi
                _hc_render_table_row \
                    "$display_name" \
                    "$_CONT_STATE" \
                    "$_CONT_BADGE" \
                    "$_CONT_UPTIME" \
                    "$_CONT_MEMORY" \
                    "$_CONT_STATUS_COLOR"
            fi
        done < <(docker ps -a --format '{{.Names}}')
    fi

    # Close table
    if [[ "$output_mode" == "table" ]]; then
        _hc_render_table_border "bottom"
        _hc_render_summary "$total_containers" "$healthy_count" "$unhealthy_count" "$stopped_count" "$no_check_count"
    elif [[ "$output_mode" == "json" ]]; then
        _hc_json_output container_data "$total_containers" "$healthy_count" "$unhealthy_count" "$stopped_count"
    elif [[ "$output_mode" == "quiet" ]]; then
        if (( unhealthy_count > 0 || stopped_count > 0 )); then
            echo "DEGRADED: ${unhealthy_count} unhealthy, ${stopped_count} stopped out of ${total_containers} containers"
        else
            echo "HEALTHY: All ${total_containers} containers operational"
        fi
    fi

    # Return code
    if (( unhealthy_count > 0 || stopped_count > 0 )); then
        return 1
    fi
    return 0
}

# =============================================================================
# STANDALONE EXECUTION
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

    # Parse arguments
    _HC_OUTPUT_MODE="table"
    _HC_QUIET=false
    _HC_STACK_FILTER=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quiet|-q)
                _HC_OUTPUT_MODE="quiet"
                _HC_QUIET=true
                shift
                ;;
            --json|-j)
                _HC_OUTPUT_MODE="json"
                shift
                ;;
            --stack|-s)
                _HC_STACK_FILTER="${2:-}"
                shift 2
                ;;
            --help|-h)
                cat <<'HELP'
Docker Compose Skeleton — Health Check

Usage: ./health-check.sh [OPTIONS]

Options:
  --quiet, -q         Minimal one-line output
  --json, -j          Output results as JSON
  --stack, -s NAME    Check only the specified stack
  --help, -h          Show this help message

Exit codes:
  0    All containers healthy
  1    One or more issues detected

Examples:
  ./health-check.sh                     Full health report
  ./health-check.sh --json              JSON output for automation
  ./health-check.sh --stack media       Check only the media stack
  ./health-check.sh --quiet             One-line status for monitoring

HELP
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                echo "Run './health-check.sh --help' for usage."
                exit 1
                ;;
        esac
    done

    # Show banner in table mode
    if [[ "$_HC_OUTPUT_MODE" == "table" ]]; then
        _hc_show_banner
    fi

    # Run the health check
    run_health_check "$_HC_OUTPUT_MODE" "$_HC_STACK_FILTER"
    exit $?
fi

# =============================================================================
# EXPORT FUNCTIONS FOR SOURCED USE
# =============================================================================

export -f run_health_check
export -f _hc_inspect_container _hc_format_uptime _hc_format_memory
export -f _hc_render_table_border _hc_render_table_row _hc_render_header
export -f _hc_render_summary _hc_log _hc_repeat_char _hc_load_stats_cache
