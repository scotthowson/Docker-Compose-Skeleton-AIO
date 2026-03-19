#!/bin/bash
# =============================================================================
# Docker Compose Skeleton - Status Script
# Standalone status checker for all managed Docker Compose stacks
# Does not require the full logger -- uses its own lightweight output
# =============================================================================

set -uo pipefail

# =============================================================================
# PATH AUTO-DETECTION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$SCRIPT_DIR"
export BASE_DIR

# Load root .env (for APP_DATA_DIR, etc.)
if [[ -f "$BASE_DIR/.env" ]]; then
    set -a
    source "$BASE_DIR/.env"
    set +a
fi

COMPOSE_DIR="$BASE_DIR/Stacks"
export COMPOSE_DIR

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

SHOW_HELP=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) SHOW_HELP=true; shift ;;
        *)
            echo "Unknown option: $1"
            echo "Run './status.sh --help' for usage."
            exit 1
            ;;
    esac
done

if [[ "$SHOW_HELP" == "true" ]]; then
    cat <<EOF
Docker Compose Skeleton - Status

Usage: ./status.sh [OPTIONS]

Displays the status of all managed Docker Compose stacks,
including container health, uptime, and resource usage.

OPTIONS:
  --help, -h     Show this help message and exit

OUTPUT:
  For each stack directory in Stacks/:
    - Stack name and running/stopped status
    - Container names, health status, and uptime
  Footer with Docker system resource summary

EOF
    exit 0
fi

# =============================================================================
# DOCKER COMPOSE DETECTION
# =============================================================================

# Source docker-utils.sh for compose command detection
source "$BASE_DIR/.lib/docker-utils.sh"

if ! _detect_docker_compose; then
    echo "ERROR: No Docker Compose installation found." >&2
    exit 1
fi

# =============================================================================
# COLOR SETUP
# =============================================================================

_setup_colors() {
    if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]] && command -v tput >/dev/null 2>&1; then
        local colors
        colors="$(tput colors 2>/dev/null || echo 0)"
        if [[ "$colors" -ge 8 ]]; then
            C_GREEN="$(tput setaf 82 2>/dev/null || tput setaf 2)"
            C_RED="$(tput setaf 124 2>/dev/null || tput setaf 1)"
            C_YELLOW="$(tput setaf 208 2>/dev/null || tput setaf 3)"
            C_BLUE="$(tput setaf 33 2>/dev/null || tput setaf 4)"
            C_CYAN="$(tput setaf 51 2>/dev/null || tput setaf 6)"
            C_DIM="$(tput dim 2>/dev/null || true)"
            C_BOLD="$(tput bold 2>/dev/null || true)"
            C_RESET="$(tput sgr0 2>/dev/null || true)"
            return
        fi
    fi
    C_GREEN="" C_RED="" C_YELLOW="" C_BLUE="" C_CYAN="" C_DIM="" C_BOLD="" C_RESET=""
}

_setup_colors

# =============================================================================
# STACK ORDER (matches the startup dependency order)
# =============================================================================

STACK_ORDER=(
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

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Print a horizontal rule
_hr() {
    local char="${1:--}"
    printf "${C_DIM}%*s${C_RESET}\n" 78 "" | tr ' ' "$char"
}

# Colorize a status word
_colorize_status() {
    local status="$1"
    case "$status" in
        running)  echo -e "${C_GREEN}${status}${C_RESET}" ;;
        healthy)  echo -e "${C_GREEN}${status}${C_RESET}" ;;
        exited|dead|removing|created)
                  echo -e "${C_RED}${status}${C_RESET}" ;;
        unhealthy|restarting)
                  echo -e "${C_YELLOW}${status}${C_RESET}" ;;
        *)        echo -e "${C_DIM}${status}${C_RESET}" ;;
    esac
}

# Format "up X hours" style uptime from docker inspect
_format_uptime() {
    local started_at="$1"
    local status="$2"

    if [[ "$status" != "running" ]]; then
        echo "-"
        return
    fi

    if [[ -z "$started_at" ]] || [[ "$started_at" == "null" ]]; then
        echo "unknown"
        return
    fi

    # Parse ISO 8601 timestamp to epoch
    local start_epoch
    start_epoch="$(date -d "$started_at" '+%s' 2>/dev/null || echo 0)"
    local now_epoch
    now_epoch="$(date '+%s')"

    if [[ "$start_epoch" -eq 0 ]]; then
        echo "unknown"
        return
    fi

    local diff=$(( now_epoch - start_epoch ))
    local days=$(( diff / 86400 ))
    local hours=$(( (diff % 86400) / 3600 ))
    local minutes=$(( (diff % 3600) / 60 ))

    if (( days > 0 )); then
        echo "${days}d ${hours}h"
    elif (( hours > 0 )); then
        echo "${hours}h ${minutes}m"
    else
        echo "${minutes}m"
    fi
}

# =============================================================================
# MAIN STATUS DISPLAY
# =============================================================================

echo ""
echo -e "${C_BOLD}${C_CYAN}+============================================================+${C_RESET}"
echo -e "${C_BOLD}${C_CYAN}|           Docker Compose Skeleton  --  Status              |${C_RESET}"
echo -e "${C_BOLD}${C_CYAN}+============================================================+${C_RESET}"
echo ""
echo -e "  ${C_DIM}Checked at:${C_RESET} $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "  ${C_DIM}Stacks dir:${C_RESET} $COMPOSE_DIR"
echo ""

# Counters for the summary
total_stacks=0
running_stacks=0
stopped_stacks=0
total_containers=0
running_containers=0

# Iterate stacks in dependency order
for stack in "${STACK_ORDER[@]}"; do
    stack_dir="$COMPOSE_DIR/$stack"

    # Skip stacks that don't exist on disk
    if [[ ! -d "$stack_dir" ]]; then
        continue
    fi

    ((total_stacks++))

    compose_file="$stack_dir/docker-compose.yml"
    env_file="$stack_dir/.env"

    # Build compose command args
    compose_args=()
    if [[ -f "$compose_file" ]]; then
        compose_args+=(-f "$compose_file")
    else
        # No compose file means nothing to check
        echo -e "${C_BOLD}  $stack${C_RESET}"
        echo -e "    ${C_DIM}No docker-compose.yml found${C_RESET}"
        _hr
        continue
    fi

    if [[ -f "$env_file" ]]; then
        compose_args+=(--env-file "$env_file")
    fi

    # Get the list of service container IDs for this stack
    container_ids=()
    while IFS= read -r cid; do
        [[ -n "$cid" ]] && container_ids+=("$cid")
    done < <($DOCKER_COMPOSE_CMD "${compose_args[@]}" ps -q 2>/dev/null)

    container_count=${#container_ids[@]}
    ((total_containers += container_count))

    # Determine stack-level status
    stack_running=0
    if (( container_count > 0 )); then
        for cid in "${container_ids[@]}"; do
            state="$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null || echo "unknown")"
            [[ "$state" == "running" ]] && ((stack_running++))
        done
    fi

    ((running_containers += stack_running))

    # Stack header
    if (( container_count == 0 )); then
        stack_status="${C_RED}STOPPED${C_RESET}"
        ((stopped_stacks++))
    elif (( stack_running == container_count )); then
        stack_status="${C_GREEN}RUNNING${C_RESET}"
        ((running_stacks++))
    else
        stack_status="${C_YELLOW}PARTIAL${C_RESET} (${stack_running}/${container_count})"
        ((running_stacks++))
    fi

    echo -e "${C_BOLD}  $stack${C_RESET}  [$stack_status]  ${C_DIM}(${container_count} containers)${C_RESET}"

    # Container detail table
    if (( container_count > 0 )); then
        # Table header
        printf "    ${C_DIM}%-30s %-12s %-10s %-12s${C_RESET}\n" "CONTAINER" "STATE" "HEALTH" "UPTIME"

        for cid in "${container_ids[@]}"; do
            # Gather container info in one inspect call
            info="$(docker inspect --format '{{.Name}}|{{.State.Status}}|{{.State.Health.Status}}|{{.State.StartedAt}}' "$cid" 2>/dev/null || echo "unknown|unknown|none|")"

            IFS='|' read -r c_name c_state c_health c_started <<< "$info"

            # Clean up the leading slash from container name
            c_name="${c_name#/}"

            # Handle missing health check
            [[ -z "$c_health" ]] || [[ "$c_health" == "<no value>" ]] || [[ "$c_health" == "none" ]] && c_health="-"

            # Format uptime
            uptime_str="$(_format_uptime "$c_started" "$c_state")"

            # Colorize
            colored_state="$(_colorize_status "$c_state")"
            colored_health="$(_colorize_status "$c_health")"

            # Truncate long names
            if (( ${#c_name} > 28 )); then
                c_name="${c_name:0:25}..."
            fi

            # Print row -- use raw escape sequences for alignment
            printf "    %-30s " "$c_name"
            printf "%-22b " "$colored_state"
            printf "%-20b " "$colored_health"
            printf "%-12s\n" "$uptime_str"
        done
    fi

    echo ""
done

# Also scan for any stacks on disk not in the predefined order
for stack_dir in "$COMPOSE_DIR"/*/; do
    [[ -d "$stack_dir" ]] || continue
    stack="$(basename "$stack_dir")"

    # Skip if already shown
    already_shown=false
    for known in "${STACK_ORDER[@]}"; do
        [[ "$stack" == "$known" ]] && already_shown=true && break
    done
    [[ "$already_shown" == "true" ]] && continue

    ((total_stacks++))
    echo -e "${C_BOLD}  $stack${C_RESET}  ${C_DIM}(unlisted stack)${C_RESET}"
    echo ""
done

# =============================================================================
# DOCKER SYSTEM SUMMARY
# =============================================================================

_hr "="
echo ""
echo -e "${C_BOLD}${C_CYAN}  Docker System Resources${C_RESET}"
echo ""

# Collect docker system df output
if docker system df >/dev/null 2>&1; then
    while IFS= read -r line; do
        echo "    $line"
    done < <(docker system df 2>/dev/null)
else
    echo "    ${C_DIM}(docker system df not available)${C_RESET}"
fi

echo ""

# =============================================================================
# FOOTER SUMMARY
# =============================================================================

_hr "="
echo ""
echo -e "  ${C_BOLD}Summary${C_RESET}"
printf "    Stacks     : %d total  |  ${C_GREEN}%d running${C_RESET}  |  ${C_RED}%d stopped${C_RESET}\n" \
    "$total_stacks" "$running_stacks" "$stopped_stacks"
printf "    Containers : %d total  |  ${C_GREEN}%d running${C_RESET}  |  ${C_RED}%d stopped${C_RESET}\n" \
    "$total_containers" "$running_containers" "$(( total_containers - running_containers ))"
echo ""
