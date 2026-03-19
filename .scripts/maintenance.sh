#!/bin/bash
# =============================================================================
# Docker Compose Skeleton — Maintenance & Cleanup Utility
# Comprehensive Docker system maintenance with disk usage analysis,
# orphaned resource detection, and safe cleanup operations.
#
# Usage:
#   ./maintenance.sh [command]
#
# Commands:
#   report        Full system report (default)
#   disk          Disk usage breakdown
#   prune         Safe cleanup (dangling images, stopped containers)
#   deep-prune    Aggressive cleanup (unused images, volumes, networks)
#   orphans       Find orphaned resources
#   log-rotate    Rotate and archive log files
# =============================================================================

# =============================================================================
# PATH AUTO-DETECTION
# =============================================================================

if [[ -z "${BASE_DIR:-}" ]]; then
    _MT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    BASE_DIR="$(cd "$_MT_SCRIPT_DIR/.." && pwd)"
    unset _MT_SCRIPT_DIR
fi

if [[ -f "$BASE_DIR/.env" ]]; then
    set -a
    source "$BASE_DIR/.env"
    set +a
fi

APP_DATA_DIR="${APP_DATA_DIR:-$BASE_DIR/App-Data}"
LOG_DIR="${LOG_DIR:-$BASE_DIR/logs}"

# =============================================================================
# COLOR SETUP
# =============================================================================

if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]] && command -v tput >/dev/null 2>&1; then
    _MT_RESET="$(tput sgr0)"
    _MT_BOLD="$(tput bold)"
    _MT_DIM="$(tput dim)"
    _MT_GREEN="$(tput setaf 82)"
    _MT_YELLOW="$(tput setaf 214)"
    _MT_RED="$(tput setaf 196)"
    _MT_CYAN="$(tput setaf 51)"
    _MT_BLUE="$(tput setaf 33)"
    _MT_GRAY="$(tput setaf 245)"
    _MT_MAGENTA="$(tput setaf 141)"
    _MT_WHITE="$(tput setaf 15)"
else
    _MT_RESET="" _MT_BOLD="" _MT_DIM=""
    _MT_GREEN="" _MT_YELLOW="" _MT_RED="" _MT_CYAN=""
    _MT_BLUE="" _MT_GRAY="" _MT_MAGENTA="" _MT_WHITE=""
fi

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

_mt_repeat() {
    local char="$1" count="$2"
    (( count <= 0 )) && return
    printf "%0.s${char}" $(seq 1 "$count")
}

_mt_header() {
    local title="$1"
    local width=60
    echo ""
    echo "  ${_MT_BLUE}+$(_mt_repeat "-" "$width")+${_MT_RESET}"
    local pad=$(( (width - ${#title}) / 2 ))
    printf "  ${_MT_BLUE}|%*s${_MT_BOLD}${_MT_CYAN}%s${_MT_RESET}${_MT_BLUE}%*s|${_MT_RESET}\n" "$pad" "" "$title" $(( width - pad - ${#title} )) ""
    echo "  ${_MT_BLUE}+$(_mt_repeat "-" "$width")+${_MT_RESET}"
    echo ""
}

_mt_success() { echo "  ${_MT_GREEN}[OK]${_MT_RESET}   $*"; }
_mt_warning() { echo "  ${_MT_YELLOW}[!!]${_MT_RESET}   $*"; }
_mt_error()   { echo "  ${_MT_RED}[ERR]${_MT_RESET}  $*"; }
_mt_info()    { echo "  ${_MT_CYAN}[>>]${_MT_RESET}   $*"; }
_mt_item()    { echo "  ${_MT_GRAY}       $*${_MT_RESET}"; }

_mt_kv() {
    local key="$1" value="$2" width="${3:-30}"
    local dots_len=$(( width - ${#key} ))
    (( dots_len < 2 )) && dots_len=2
    local dots
    dots="$(printf '%*s' "$dots_len" '' | tr ' ' '.')"
    printf "  ${_MT_DIM}%s${_MT_RESET} %s ${_MT_BOLD}%s${_MT_RESET}\n" "$key" "$dots" "$value"
}

# Convert bytes to human-readable
_mt_human_size() {
    local bytes="$1"
    if [[ "$bytes" -ge 1073741824 ]]; then
        printf "%.1f GB" "$(echo "scale=1; $bytes/1073741824" | bc)"
    elif [[ "$bytes" -ge 1048576 ]]; then
        printf "%.1f MB" "$(echo "scale=1; $bytes/1048576" | bc)"
    elif [[ "$bytes" -ge 1024 ]]; then
        printf "%.1f KB" "$(echo "scale=1; $bytes/1024" | bc)"
    else
        printf "%d B" "$bytes"
    fi
}

# =============================================================================
# COMMAND: REPORT (default)
# =============================================================================

cmd_report() {
    _mt_header "Docker System Report"

    # Docker info
    local docker_version
    docker_version="$(docker --version 2>/dev/null | sed 's/Docker version //' | cut -d, -f1)"
    _mt_kv "Docker version" "$docker_version"

    local docker_root
    docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
    _mt_kv "Storage root" "$docker_root"

    local storage_driver
    storage_driver="$(docker info --format '{{.Driver}}' 2>/dev/null)"
    _mt_kv "Storage driver" "$storage_driver"

    echo ""

    # Container stats
    local running stopped total_containers
    running="$(docker ps -q 2>/dev/null | wc -l)"
    total_containers="$(docker ps -aq 2>/dev/null | wc -l)"
    stopped=$(( total_containers - running ))

    _mt_kv "Containers (total)" "$total_containers"
    _mt_kv "  Running" "${_MT_GREEN}$running${_MT_RESET}"
    _mt_kv "  Stopped" "$([[ $stopped -gt 0 ]] && echo "${_MT_YELLOW}$stopped${_MT_RESET}" || echo "$stopped")"

    echo ""

    # Image stats
    local total_images dangling_images
    total_images="$(docker images -q 2>/dev/null | wc -l)"
    dangling_images="$(docker images -f 'dangling=true' -q 2>/dev/null | wc -l)"

    _mt_kv "Images (total)" "$total_images"
    _mt_kv "  Dangling" "$([[ $dangling_images -gt 0 ]] && echo "${_MT_YELLOW}$dangling_images${_MT_RESET}" || echo "$dangling_images")"

    echo ""

    # Volume stats
    local total_volumes dangling_volumes
    total_volumes="$(docker volume ls -q 2>/dev/null | wc -l)"
    dangling_volumes="$(docker volume ls -f 'dangling=true' -q 2>/dev/null | wc -l)"

    _mt_kv "Volumes (total)" "$total_volumes"
    _mt_kv "  Dangling" "$([[ $dangling_volumes -gt 0 ]] && echo "${_MT_YELLOW}$dangling_volumes${_MT_RESET}" || echo "$dangling_volumes")"

    echo ""

    # Network stats
    local total_networks custom_networks
    total_networks="$(docker network ls -q 2>/dev/null | wc -l)"
    custom_networks="$(docker network ls --format '{{.Name}}' 2>/dev/null | grep -cv '^bridge$\|^host$\|^none$' || echo 0)"

    _mt_kv "Networks (total)" "$total_networks"
    _mt_kv "  Custom" "$custom_networks"

    echo ""

    # Disk usage summary from docker system df
    echo "  ${_MT_BOLD}${_MT_CYAN}Disk Usage:${_MT_RESET}"
    echo ""
    docker system df 2>/dev/null | while IFS= read -r line; do
        echo "  $line"
    done

    echo ""

    # App-Data size
    if [[ -d "$APP_DATA_DIR" ]]; then
        local app_data_size
        app_data_size="$(du -sh "$APP_DATA_DIR" 2>/dev/null | cut -f1)"
        _mt_kv "App-Data directory" "$app_data_size"
    fi

    # Log directory size
    if [[ -d "$LOG_DIR" ]]; then
        local log_size
        log_size="$(du -sh "$LOG_DIR" 2>/dev/null | cut -f1)"
        _mt_kv "Log directory" "$log_size"
    fi

    echo ""
}

# =============================================================================
# COMMAND: DISK
# =============================================================================

cmd_disk() {
    _mt_header "Disk Usage Breakdown"

    echo "  ${_MT_BOLD}${_MT_CYAN}Docker System:${_MT_RESET}"
    echo ""
    docker system df -v 2>/dev/null | head -80 | while IFS= read -r line; do
        echo "  $line"
    done

    echo ""

    # Per-stack App-Data sizes
    if [[ -d "$APP_DATA_DIR" ]]; then
        echo "  ${_MT_BOLD}${_MT_CYAN}App-Data Per Stack:${_MT_RESET}"
        echo ""

        printf "  ${_MT_BOLD}%-35s %s${_MT_RESET}\n" "DIRECTORY" "SIZE"
        printf "  ${_MT_GRAY}%-35s %s${_MT_RESET}\n" "$(_mt_repeat "-" 33)" "$(_mt_repeat "-" 10)"

        du -sh "$APP_DATA_DIR"/*/ 2>/dev/null | sort -rh | while IFS=$'\t' read -r size dir; do
            local dirname
            dirname="$(basename "$dir")"
            printf "  %-35s %s\n" "$dirname" "$size"
        done

        echo ""
        local total_size
        total_size="$(du -sh "$APP_DATA_DIR" 2>/dev/null | cut -f1)"
        _mt_kv "Total App-Data" "$total_size"
    fi

    echo ""
}

# =============================================================================
# COMMAND: PRUNE (safe)
# =============================================================================

cmd_prune() {
    _mt_header "Safe Cleanup"

    echo "  ${_MT_DIM}This will remove:${_MT_RESET}"
    echo "    - Stopped containers"
    echo "    - Dangling images (untagged)"
    echo "    - Unused build cache"
    echo ""

    # Show what would be removed
    local stopped_count dangling_count
    stopped_count="$(docker ps -aq -f 'status=exited' 2>/dev/null | wc -l)"
    dangling_count="$(docker images -f 'dangling=true' -q 2>/dev/null | wc -l)"

    _mt_info "Stopped containers: $stopped_count"
    _mt_info "Dangling images: $dangling_count"
    echo ""

    if [[ "$stopped_count" -eq 0 ]] && [[ "$dangling_count" -eq 0 ]]; then
        _mt_success "System is clean — nothing to prune"
        return 0
    fi

    # Ask for confirmation (unless piped)
    if [[ -t 0 ]]; then
        printf "  ${_MT_YELLOW}Proceed with cleanup? [y/N]:${_MT_RESET} "
        local answer
        read -r answer
        if [[ "${answer,,}" != "y" ]]; then
            _mt_info "Cleanup cancelled"
            return 0
        fi
    fi

    echo ""
    _mt_info "Running docker system prune..."
    echo ""

    local output
    output="$(docker system prune -f 2>&1)"
    echo "$output" | while IFS= read -r line; do
        echo "  $line"
    done

    echo ""
    _mt_success "Cleanup completed"
}

# =============================================================================
# COMMAND: DEEP-PRUNE (aggressive)
# =============================================================================

cmd_deep_prune() {
    _mt_header "Deep Cleanup (Aggressive)"

    echo "  ${_MT_RED}${_MT_BOLD}WARNING: This will remove:${_MT_RESET}"
    echo "    - ALL stopped containers"
    echo "    - ALL unused images (not just dangling)"
    echo "    - ALL unused volumes"
    echo "    - ALL unused networks"
    echo "    - Build cache"
    echo ""
    echo "  ${_MT_RED}This cannot be undone!${_MT_RESET}"
    echo ""

    # Calculate potential savings
    local reclaimable
    reclaimable="$(docker system df --format '{{.Reclaimable}}' 2>/dev/null | head -1)"
    _mt_kv "Estimated reclaimable" "${reclaimable:-unknown}"
    echo ""

    if [[ -t 0 ]]; then
        printf "  ${_MT_RED}Type 'CONFIRM' to proceed:${_MT_RESET} "
        local answer
        read -r answer
        if [[ "$answer" != "CONFIRM" ]]; then
            _mt_info "Deep cleanup cancelled"
            return 0
        fi
    else
        _mt_error "Deep prune requires interactive confirmation"
        return 1
    fi

    echo ""
    _mt_warning "Running deep prune..."
    echo ""

    docker system prune -af --volumes 2>&1 | while IFS= read -r line; do
        echo "  $line"
    done

    echo ""
    _mt_success "Deep cleanup completed"
    echo ""

    # Show result
    cmd_report
}

# =============================================================================
# COMMAND: ORPHANS
# =============================================================================

cmd_orphans() {
    _mt_header "Orphaned Resources"

    local found_orphans=false

    # Orphaned containers (exited, not part of any compose project)
    echo "  ${_MT_BOLD}${_MT_CYAN}Orphaned Containers:${_MT_RESET}"
    local orphaned_containers
    orphaned_containers="$(docker ps -a --filter 'status=exited' --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.CreatedAt}}' 2>/dev/null)"

    if [[ -n "$orphaned_containers" ]]; then
        found_orphans=true
        printf "  ${_MT_BOLD}%-25s %-25s %-20s${_MT_RESET}\n" "NAME" "IMAGE" "EXITED"
        printf "  ${_MT_GRAY}%-25s %-25s %-20s${_MT_RESET}\n" \
            "$(_mt_repeat "-" 23)" "$(_mt_repeat "-" 23)" "$(_mt_repeat "-" 18)"

        while IFS='|' read -r name image status created; do
            [[ -z "$name" ]] && continue
            # Truncate long names/images
            [[ ${#name} -gt 24 ]] && name="${name:0:21}..."
            [[ ${#image} -gt 24 ]] && image="${image:0:21}..."
            printf "  ${_MT_YELLOW}%-25s${_MT_RESET} %-25s ${_MT_DIM}%-20s${_MT_RESET}\n" "$name" "$image" "$status"
        done <<< "$orphaned_containers"
    else
        _mt_success "No orphaned containers"
    fi

    echo ""

    # Dangling images
    echo "  ${_MT_BOLD}${_MT_CYAN}Dangling Images:${_MT_RESET}"
    local dangling_images
    dangling_images="$(docker images -f 'dangling=true' --format '{{.ID}}|{{.Size}}|{{.CreatedAt}}' 2>/dev/null)"

    if [[ -n "$dangling_images" ]]; then
        found_orphans=true
        printf "  ${_MT_BOLD}%-15s %-12s %-25s${_MT_RESET}\n" "IMAGE ID" "SIZE" "CREATED"
        printf "  ${_MT_GRAY}%-15s %-12s %-25s${_MT_RESET}\n" \
            "$(_mt_repeat "-" 13)" "$(_mt_repeat "-" 10)" "$(_mt_repeat "-" 23)"

        while IFS='|' read -r id size created; do
            [[ -z "$id" ]] && continue
            printf "  ${_MT_YELLOW}%-15s${_MT_RESET} %-12s ${_MT_DIM}%-25s${_MT_RESET}\n" "${id:0:12}" "$size" "$created"
        done <<< "$dangling_images"
    else
        _mt_success "No dangling images"
    fi

    echo ""

    # Dangling volumes
    echo "  ${_MT_BOLD}${_MT_CYAN}Dangling Volumes:${_MT_RESET}"
    local dangling_volumes
    dangling_volumes="$(docker volume ls -f 'dangling=true' --format '{{.Name}}|{{.Driver}}' 2>/dev/null)"

    if [[ -n "$dangling_volumes" ]]; then
        found_orphans=true
        while IFS='|' read -r name driver; do
            [[ -z "$name" ]] && continue
            echo "  ${_MT_YELLOW}$name${_MT_RESET} ${_MT_DIM}($driver)${_MT_RESET}"
        done <<< "$dangling_volumes"
    else
        _mt_success "No dangling volumes"
    fi

    echo ""

    if [[ "$found_orphans" == "true" ]]; then
        _mt_warning "Orphaned resources found — run '$0 prune' to clean up"
    else
        _mt_success "No orphaned resources found"
    fi

    echo ""
}

# =============================================================================
# COMMAND: LOG-ROTATE
# =============================================================================

cmd_log_rotate() {
    _mt_header "Log Rotation"

    local log_file="$LOG_DIR/docker-services.log"
    local archive_dir="$LOG_DIR/archive"
    local retention_count="${LOG_BACKUP_COUNT:-12}"

    if [[ ! -f "$log_file" ]]; then
        _mt_info "No active log file found at: $log_file"
        return 0
    fi

    local log_size
    log_size="$(du -sh "$log_file" 2>/dev/null | cut -f1)"
    local log_lines
    log_lines="$(wc -l < "$log_file" 2>/dev/null)"

    _mt_kv "Current log" "$log_file"
    _mt_kv "Size" "$log_size"
    _mt_kv "Lines" "$log_lines"
    _mt_kv "Archive dir" "$archive_dir"
    _mt_kv "Retention" "${retention_count} files"
    echo ""

    # Create archive directory
    mkdir -p "$archive_dir" 2>/dev/null

    # Rotate
    local timestamp
    timestamp="$(date '+%Y%m%d-%H%M%S')"
    local archive_name="docker-services-${timestamp}.log"

    if [[ -t 0 ]]; then
        printf "  ${_MT_YELLOW}Rotate log now? [y/N]:${_MT_RESET} "
        local answer
        read -r answer
        if [[ "${answer,,}" != "y" ]]; then
            _mt_info "Log rotation cancelled"
            return 0
        fi
    fi

    # Copy and compress
    cp "$log_file" "$archive_dir/$archive_name"

    if command -v gzip >/dev/null 2>&1; then
        gzip "$archive_dir/$archive_name"
        _mt_success "Archived: ${archive_name}.gz"
    else
        _mt_success "Archived: $archive_name"
    fi

    # Truncate current log
    : > "$log_file"
    _mt_success "Current log file truncated"

    # Purge old archives beyond retention count
    local archive_count
    archive_count="$(ls -1 "$archive_dir"/docker-services-*.log* 2>/dev/null | wc -l)"

    if [[ "$archive_count" -gt "$retention_count" ]]; then
        local remove_count=$(( archive_count - retention_count ))
        ls -1t "$archive_dir"/docker-services-*.log* 2>/dev/null | tail -n "$remove_count" | while read -r old_file; do
            rm -f "$old_file"
            _mt_info "Purged old archive: $(basename "$old_file")"
        done
    fi

    echo ""
    _mt_kv "Archives kept" "$(ls -1 "$archive_dir"/docker-services-*.log* 2>/dev/null | wc -l)"
    echo ""
}

# =============================================================================
# HELP
# =============================================================================

show_help() {
    cat <<EOF
${_MT_BOLD}${_MT_CYAN}Docker Compose Skeleton — Maintenance Utility${_MT_RESET}

${_MT_BOLD}Usage:${_MT_RESET}
  $0 [command]

${_MT_BOLD}Commands:${_MT_RESET}
  ${_MT_GREEN}report${_MT_RESET}        Full system report (default)
  ${_MT_CYAN}disk${_MT_RESET}          Detailed disk usage breakdown
  ${_MT_YELLOW}prune${_MT_RESET}         Safe cleanup (dangling resources)
  ${_MT_RED}deep-prune${_MT_RESET}    Aggressive cleanup (ALL unused resources)
  ${_MT_MAGENTA}orphans${_MT_RESET}       Find orphaned containers, images, volumes
  ${_MT_BLUE}log-rotate${_MT_RESET}    Rotate and archive log files

${_MT_BOLD}Examples:${_MT_RESET}
  $0                    # Full system report
  $0 disk               # Disk usage analysis
  $0 prune              # Safe cleanup
  $0 orphans            # Find orphaned resources
  $0 log-rotate         # Rotate logs

EOF
}

# =============================================================================
# MAIN
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    command="${1:-report}"

    case "$command" in
        report)      cmd_report ;;
        disk)        cmd_disk ;;
        prune)       cmd_prune ;;
        deep-prune)  cmd_deep_prune ;;
        orphans)     cmd_orphans ;;
        log-rotate)  cmd_log_rotate ;;
        help|--help|-h) show_help ;;
        *)
            _mt_error "Unknown command: $command"
            echo ""
            show_help
            exit 1
            ;;
    esac
fi
