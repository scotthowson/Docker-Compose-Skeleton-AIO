#!/bin/bash
# =============================================================================
# Docker Compose Skeleton — Stack Manager
# CLI for managing individual Docker Compose stacks
#
# Usage:
#   ./stack-manager.sh <command> <stack-name> [options]
#
# Commands:
#   start <stack>     Start a specific stack
#   stop <stack>      Stop a specific stack
#   restart <stack>   Restart a specific stack
#   status <stack>    Show status of a specific stack
#   logs <stack>      Show logs for a specific stack
#   pull <stack>      Pull latest images for a stack
#   update <stack>    Pull, detect changes, recreate if needed
#   list              List all available stacks
#   running           List only running stacks
#
# Examples:
#   ./stack-manager.sh start core-infrastructure
#   ./stack-manager.sh update media-services
#   ./stack-manager.sh logs media-services --follow
#   ./stack-manager.sh status web-applications
#   ./stack-manager.sh list
# =============================================================================

# =============================================================================
# PATH AUTO-DETECTION
# =============================================================================

if [[ -z "${BASE_DIR:-}" ]]; then
    _SM_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    BASE_DIR="$(cd "$_SM_SCRIPT_DIR/.." && pwd)"
    unset _SM_SCRIPT_DIR
fi

# Load root .env
if [[ -f "$BASE_DIR/.env" ]]; then
    set -a
    source "$BASE_DIR/.env"
    set +a
fi

COMPOSE_DIR="${COMPOSE_DIR:-$BASE_DIR/Stacks}"
APP_DATA_DIR="${APP_DATA_DIR:-$BASE_DIR/App-Data}"

# =============================================================================
# COLOR SETUP
# =============================================================================

if [[ -z "${_SM_RESET:-}" ]]; then
    if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]] && command -v tput >/dev/null 2>&1; then
        _SM_RESET="$(tput sgr0)"
        _SM_BOLD="$(tput bold)"
        _SM_DIM="$(tput dim)"
        _SM_GREEN="$(tput setaf 82)"
        _SM_YELLOW="$(tput setaf 214)"
        _SM_RED="$(tput setaf 196)"
        _SM_CYAN="$(tput setaf 51)"
        _SM_BLUE="$(tput setaf 33)"
        _SM_GRAY="$(tput setaf 245)"
        _SM_WHITE="$(tput setaf 15)"
        _SM_MAGENTA="$(tput setaf 141)"
    else
        _SM_RESET="" _SM_BOLD="" _SM_DIM=""
        _SM_GREEN="" _SM_YELLOW="" _SM_RED="" _SM_CYAN=""
        _SM_BLUE="" _SM_GRAY="" _SM_WHITE="" _SM_MAGENTA=""
    fi
fi

# =============================================================================
# DOCKER COMPOSE COMMAND DETECTION
# =============================================================================

_sm_detect_compose() {
    if [[ -n "${DOCKER_COMPOSE_CMD:-}" ]]; then
        return 0
    fi

    if docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker-compose"
    else
        echo "${_SM_RED}Error: No Docker Compose installation found${_SM_RESET}" >&2
        return 1
    fi
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

_sm_print() {
    local color="$1"; shift
    echo "${color}${*}${_SM_RESET}"
}

_sm_header() {
    local title="$1"
    local width=60
    local border
    border="$(printf '%0.s─' $(seq 1 "$width"))"
    local heavy_border
    heavy_border="$(printf '%0.s═' $(seq 1 "$width"))"

    echo ""
    echo "  ${_SM_BLUE}╔${heavy_border}╗${_SM_RESET}"
    local pad=$(( (width - ${#title}) / 2 ))
    printf "  ${_SM_BLUE}║%*s${_SM_BOLD}${_SM_CYAN}%s${_SM_RESET}${_SM_BLUE}%*s║${_SM_RESET}\n" "$pad" "" "$title" $(( width - pad - ${#title} )) ""
    echo "  ${_SM_BLUE}╚${heavy_border}╝${_SM_RESET}"
    echo ""
}

_sm_success() { echo "  ${_SM_GREEN}[OK]${_SM_RESET} $*"; }
_sm_warning() { echo "  ${_SM_YELLOW}[!!]${_SM_RESET} $*"; }
_sm_error()   { echo "  ${_SM_RED}[ERR]${_SM_RESET} $*"; }
_sm_info()    { echo "  ${_SM_CYAN}[>>]${_SM_RESET} $*"; }

# Get all available stacks
_sm_get_stacks() {
    local stacks=()
    for dir in "$COMPOSE_DIR"/*/; do
        if [[ -f "${dir}docker-compose.yml" ]]; then
            stacks+=("$(basename "$dir")")
        fi
    done
    echo "${stacks[@]}"
}

# Validate a stack name exists
_sm_validate_stack() {
    local stack="$1"
    local stack_path="$COMPOSE_DIR/$stack"

    if [[ ! -d "$stack_path" ]]; then
        _sm_error "Stack not found: ${_SM_BOLD}$stack${_SM_RESET}"
        echo ""
        echo "  Available stacks:"
        for s in $(_sm_get_stacks); do
            echo "    - $s"
        done
        return 1
    fi

    if [[ ! -f "$stack_path/docker-compose.yml" ]]; then
        _sm_error "No docker-compose.yml found in: $stack_path"
        return 1
    fi

    return 0
}

# Get running containers for a stack
_sm_get_stack_containers() {
    local stack="$1"
    local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
    $DOCKER_COMPOSE_CMD -f "$compose_file" ps --format '{{.Name}}|{{.Status}}|{{.Ports}}' 2>/dev/null
}

# =============================================================================
# COMMANDS
# =============================================================================

cmd_start() {
    local stack="$1"
    _sm_validate_stack "$stack" || return 1

    local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
    local env_file="$COMPOSE_DIR/$stack/.env"

    _sm_header "Starting: $stack"

    local -a args=(-f "$compose_file")
    [[ -f "$env_file" ]] && args+=(--env-file "$env_file")
    args+=(up -d --remove-orphans)

    if [[ "${SKIP_HEALTHCHECK_WAIT:-false}" != "true" ]]; then
        args+=(--wait)
    fi

    _sm_info "Running: $DOCKER_COMPOSE_CMD ${args[*]}"
    echo ""

    if $DOCKER_COMPOSE_CMD "${args[@]}"; then
        echo ""
        _sm_success "Stack ${_SM_BOLD}$stack${_SM_RESET} started successfully"
    else
        echo ""
        _sm_error "Failed to start stack ${_SM_BOLD}$stack${_SM_RESET}"
        return 1
    fi
}

cmd_stop() {
    local stack="$1"
    _sm_validate_stack "$stack" || return 1

    local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
    local env_file="$COMPOSE_DIR/$stack/.env"

    _sm_header "Stopping: $stack"

    local -a args=(-f "$compose_file")
    [[ -f "$env_file" ]] && args+=(--env-file "$env_file")
    args+=(down --remove-orphans --timeout 30)

    if [[ "${REMOVE_VOLUMES_ON_STOP:-false}" == "true" ]]; then
        args+=(--volumes)
        _sm_warning "Volume removal is enabled"
    fi

    _sm_info "Running: $DOCKER_COMPOSE_CMD ${args[*]}"
    echo ""

    if $DOCKER_COMPOSE_CMD "${args[@]}"; then
        echo ""
        _sm_success "Stack ${_SM_BOLD}$stack${_SM_RESET} stopped successfully"
    else
        echo ""
        _sm_error "Failed to stop stack ${_SM_BOLD}$stack${_SM_RESET}"
        return 1
    fi
}

cmd_restart() {
    local stack="$1"
    _sm_validate_stack "$stack" || return 1

    _sm_header "Restarting: $stack"

    _sm_info "Stopping $stack..."
    cmd_stop "$stack" || true
    echo ""
    _sm_info "Starting $stack..."
    cmd_start "$stack"
}

cmd_status() {
    local stack="$1"
    _sm_validate_stack "$stack" || return 1

    _sm_header "Status: $stack"

    local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
    local env_file="$COMPOSE_DIR/$stack/.env"

    local -a compose_args=(-f "$compose_file")
    [[ -f "$env_file" ]] && compose_args+=(--env-file "$env_file")

    # Container status
    local containers
    containers="$($DOCKER_COMPOSE_CMD "${compose_args[@]}" ps --format '{{.Name}}|{{.Status}}|{{.Ports}}' 2>/dev/null)"

    if [[ -z "$containers" ]]; then
        _sm_warning "No containers running for stack ${_SM_BOLD}$stack${_SM_RESET}"
        return 0
    fi

    # Table header
    printf "  ${_SM_BOLD}${_SM_CYAN}%-30s %-25s %s${_SM_RESET}\n" "CONTAINER" "STATUS" "PORTS"
    printf "  ${_SM_GRAY}%-30s %-25s %s${_SM_RESET}\n" "$(printf '%0.s-' {1..28})" "$(printf '%0.s-' {1..23})" "$(printf '%0.s-' {1..20})"

    while IFS='|' read -r name status ports; do
        [[ -z "$name" ]] && continue

        local status_color="$_SM_GRAY"
        if [[ "$status" == *"Up"* ]] || [[ "$status" == *"running"* ]]; then
            status_color="$_SM_GREEN"
        elif [[ "$status" == *"Exited"* ]] || [[ "$status" == *"exited"* ]]; then
            status_color="$_SM_RED"
        elif [[ "$status" == *"unhealthy"* ]]; then
            status_color="$_SM_YELLOW"
        fi

        # Truncate long port strings
        if [[ ${#ports} -gt 40 ]]; then
            ports="${ports:0:37}..."
        fi

        printf "  %-30s ${status_color}%-25s${_SM_RESET} ${_SM_DIM}%s${_SM_RESET}\n" "$name" "$status" "$ports"
    done <<< "$containers"

    echo ""

    # Resource usage
    local container_names
    container_names="$($DOCKER_COMPOSE_CMD "${compose_args[@]}" ps -q 2>/dev/null)"

    if [[ -n "$container_names" ]]; then
        _sm_info "Resource usage:"
        echo ""
        printf "  ${_SM_BOLD}${_SM_CYAN}%-30s %-12s %-12s %-15s${_SM_RESET}\n" "CONTAINER" "CPU" "MEMORY" "NET I/O"
        printf "  ${_SM_GRAY}%-30s %-12s %-12s %-15s${_SM_RESET}\n" "$(printf '%0.s-' {1..28})" "$(printf '%0.s-' {1..10})" "$(printf '%0.s-' {1..10})" "$(printf '%0.s-' {1..13})"

        docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.NetIO}}' $container_names 2>/dev/null | while IFS='|' read -r name cpu mem net; do
            printf "  %-30s %-12s %-12s %-15s\n" "$name" "$cpu" "$mem" "$net"
        done
    fi

    echo ""
}

cmd_logs() {
    local stack="$1"; shift
    _sm_validate_stack "$stack" || return 1

    local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
    local env_file="$COMPOSE_DIR/$stack/.env"

    _sm_header "Logs: $stack"

    local -a log_args=(-f "$compose_file")
    [[ -f "$env_file" ]] && log_args+=(--env-file "$env_file")
    log_args+=(logs)

    # Parse additional flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --follow|-f) log_args+=(--follow); shift ;;
            --tail)      log_args+=(--tail "${2:-100}"); shift 2 ;;
            --since)     log_args+=(--since "$2"); shift 2 ;;
            *)           log_args+=("$1"); shift ;;
        esac
    done

    # Default: last 50 lines if no --follow
    local has_follow=false
    for arg in "${log_args[@]}"; do
        [[ "$arg" == "--follow" ]] && has_follow=true
    done
    if [[ "$has_follow" != "true" ]]; then
        log_args+=(--tail 50)
    fi

    $DOCKER_COMPOSE_CMD "${log_args[@]}" 2>&1
}

cmd_pull() {
    local stack="$1"
    _sm_validate_stack "$stack" || return 1

    local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
    local env_file="$COMPOSE_DIR/$stack/.env"

    _sm_header "Pulling images: $stack"

    local -a args=(-f "$compose_file")
    [[ -f "$env_file" ]] && args+=(--env-file "$env_file")
    args+=(pull)

    if $DOCKER_COMPOSE_CMD "${args[@]}"; then
        echo ""
        _sm_success "Images updated for ${_SM_BOLD}$stack${_SM_RESET}"
        echo ""
        _sm_info "Run '${_SM_BOLD}$0 restart $stack${_SM_RESET}' to apply the updates"
        _sm_info "Or run '${_SM_BOLD}$0 update $stack${_SM_RESET}' to detect and apply changes"
    else
        echo ""
        _sm_error "Failed to pull images for ${_SM_BOLD}$stack${_SM_RESET}"
        return 1
    fi
}

cmd_update() {
    local stack="$1"
    _sm_validate_stack "$stack" || return 1

    local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
    local env_file="$COMPOSE_DIR/$stack/.env"

    _sm_header "Updating: $stack"

    local -a compose_args=(-f "$compose_file")
    [[ -f "$env_file" ]] && compose_args+=(--env-file "$env_file")

    # Phase 1: Record pre-update image IDs (what running containers use)
    _sm_info "Recording current image IDs..."
    declare -A pre_ids=()

    while IFS= read -r img_name; do
        [[ -z "$img_name" ]] && continue
        local current_id
        current_id=$(docker image inspect --format='{{.Id}}' "$img_name" 2>/dev/null)
        [[ -n "$current_id" ]] && pre_ids["$img_name"]="$current_id"
    done < <($DOCKER_COMPOSE_CMD "${compose_args[@]}" config 2>/dev/null | grep 'image:' | awk '{print $2}' | sort -u)

    # Phase 2: Pull latest images
    _sm_info "Pulling latest images..."
    echo ""
    if ! $DOCKER_COMPOSE_CMD "${compose_args[@]}" pull; then
        _sm_error "Failed to pull images"
        return 1
    fi
    echo ""

    # Phase 3: Compare image IDs
    local changes_detected=false
    local -a changed_images=()

    for img_name in "${!pre_ids[@]}"; do
        local new_id
        new_id=$(docker image inspect --format='{{.Id}}' "$img_name" 2>/dev/null)
        if [[ "${pre_ids[$img_name]}" != "$new_id" ]]; then
            changes_detected=true
            local old_short="${pre_ids[$img_name]:7:12}"
            local new_short="${new_id:7:12}"
            changed_images+=("$img_name: ${old_short} -> ${new_short}")
            _sm_success "Changed: ${_SM_BOLD}$img_name${_SM_RESET} (${old_short} -> ${new_short})"
        fi
    done

    if [[ "$changes_detected" == "true" ]]; then
        echo ""
        _sm_info "Recreating containers with new images..."
        echo ""

        local -a up_args=("${compose_args[@]}" up -d --remove-orphans)
        if [[ "${SKIP_HEALTHCHECK_WAIT:-false}" != "true" ]]; then
            up_args+=(--wait)
        fi

        if $DOCKER_COMPOSE_CMD "${up_args[@]}"; then
            echo ""
            _sm_success "Stack ${_SM_BOLD}$stack${_SM_RESET} updated successfully"
            echo ""
            for change in "${changed_images[@]}"; do
                _sm_info "  $change"
            done
        else
            echo ""
            _sm_error "Failed to recreate containers for ${_SM_BOLD}$stack${_SM_RESET}"
            return 1
        fi
    else
        _sm_success "All images are already up-to-date — no changes needed"
    fi

    echo ""
}

cmd_list() {
    _sm_header "Available Stacks"

    local stacks
    stacks=($(_sm_get_stacks))

    if [[ ${#stacks[@]} -eq 0 ]]; then
        _sm_warning "No stacks found in $COMPOSE_DIR"
        return 0
    fi

    printf "  ${_SM_BOLD}${_SM_CYAN}%-3s %-35s %-10s %-10s${_SM_RESET}\n" "#" "STACK" "STATUS" "CONTAINERS"
    printf "  ${_SM_GRAY}%-3s %-35s %-10s %-10s${_SM_RESET}\n" "---" "$(printf '%0.s-' {1..33})" "$(printf '%0.s-' {1..8})" "$(printf '%0.s-' {1..8})"

    local index=0
    for stack in "${stacks[@]}"; do
        (( index++ )) || true
        local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
        local env_file="$COMPOSE_DIR/$stack/.env"

        local -a _list_args=(-f "$compose_file")
        [[ -f "$env_file" ]] && _list_args+=(--env-file "$env_file")

        # Check if any containers are running
        local running_count=0
        running_count="$($DOCKER_COMPOSE_CMD "${_list_args[@]}" ps -q 2>/dev/null | wc -l)"

        local status_text status_color
        if [[ "$running_count" -gt 0 ]]; then
            status_text="RUNNING"
            status_color="$_SM_GREEN"
        else
            status_text="STOPPED"
            status_color="$_SM_RED"
        fi

        printf "  %-3s %-35s ${status_color}%-10s${_SM_RESET} %-10s\n" "$index" "$stack" "$status_text" "$running_count"
    done

    echo ""
    _sm_info "Total: ${_SM_BOLD}${#stacks[@]}${_SM_RESET} stacks found"
    echo ""
}

cmd_running() {
    _sm_header "Running Stacks"

    local stacks
    stacks=($(_sm_get_stacks))
    local running_stacks=0

    printf "  ${_SM_BOLD}${_SM_CYAN}%-35s %-10s %-8s${_SM_RESET}\n" "STACK" "STATUS" "CONTAINERS"
    printf "  ${_SM_GRAY}%-35s %-10s %-8s${_SM_RESET}\n" "$(printf '%0.s-' {1..33})" "$(printf '%0.s-' {1..8})" "$(printf '%0.s-' {1..6})"

    for stack in "${stacks[@]}"; do
        local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
        local env_file="$COMPOSE_DIR/$stack/.env"

        local -a _run_args=(-f "$compose_file")
        [[ -f "$env_file" ]] && _run_args+=(--env-file "$env_file")

        local running_count=0
        running_count="$($DOCKER_COMPOSE_CMD "${_run_args[@]}" ps -q 2>/dev/null | wc -l)"

        if [[ "$running_count" -gt 0 ]]; then
            (( running_stacks++ ))
            printf "  %-35s ${_SM_GREEN}%-10s${_SM_RESET} %-8s\n" "$stack" "RUNNING" "$running_count"
        fi
    done

    echo ""
    if [[ "$running_stacks" -eq 0 ]]; then
        _sm_warning "No stacks are currently running"
    else
        _sm_success "${_SM_BOLD}$running_stacks${_SM_RESET} stacks running"
    fi
    echo ""
}

# =============================================================================
# HELP
# =============================================================================

show_help() {
    local _border
    _border="$(printf '%0.s─' $(seq 1 50))"

    cat <<EOF

  ${_SM_BOLD}${_SM_BLUE}╔$(printf '%0.s═' $(seq 1 50))╗${_SM_RESET}
  ${_SM_BOLD}${_SM_BLUE}║${_SM_RESET}  ${_SM_BOLD}${_SM_CYAN}Docker Compose Skeleton — Stack Manager${_SM_RESET}  ${_SM_BOLD}${_SM_BLUE}  ║${_SM_RESET}
  ${_SM_BOLD}${_SM_BLUE}╚$(printf '%0.s═' $(seq 1 50))╝${_SM_RESET}

${_SM_BOLD}Usage:${_SM_RESET}
  $0 <command> [stack-name] [options]

${_SM_BOLD}Commands:${_SM_RESET}
  ${_SM_GREEN}start${_SM_RESET}   <stack>     Start a specific stack
  ${_SM_RED}stop${_SM_RESET}    <stack>     Stop a specific stack
  ${_SM_YELLOW}restart${_SM_RESET} <stack>     Restart a specific stack
  ${_SM_CYAN}status${_SM_RESET}  <stack>     Show detailed status of a stack
  ${_SM_MAGENTA}logs${_SM_RESET}    <stack>     Show logs (--follow, --tail N, --since TIME)
  ${_SM_BLUE}pull${_SM_RESET}    <stack>     Pull latest images
  ${_SM_MAGENTA}update${_SM_RESET}  <stack>     Pull, detect changes, and recreate if needed
  ${_SM_WHITE}list${_SM_RESET}                List all available stacks
  ${_SM_WHITE}running${_SM_RESET}             List only running stacks

${_SM_BOLD}Examples:${_SM_RESET}
  $0 start core-infrastructure
  $0 status web-applications
  $0 logs media-services --follow
  $0 update monitoring-management
  $0 pull monitoring-management
  $0 list

EOF
}

# =============================================================================
# MAIN
# =============================================================================

# When run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _sm_detect_compose || exit 1

    if [[ $# -eq 0 ]]; then
        show_help
        exit 0
    fi

    command="$1"; shift

    case "$command" in
        start)    cmd_start "$@" ;;
        stop)     cmd_stop "$@" ;;
        restart)  cmd_restart "$@" ;;
        status)   cmd_status "$@" ;;
        logs)     cmd_logs "$@" ;;
        pull)     cmd_pull "$@" ;;
        update)   cmd_update "$@" ;;
        list)     cmd_list ;;
        running)  cmd_running ;;
        help|--help|-h) show_help ;;
        *)
            _sm_error "Unknown command: $command"
            echo ""
            show_help
            exit 1
            ;;
    esac
fi
