#!/bin/bash
# =============================================================================
# Docker Compose Skeleton — System Information Reporter
# Comprehensive system and Docker environment information display
#
# Usage:
#   Standalone:  ./system-info.sh [--json] [--brief]
#   Sourced:     source system-info.sh; show_system_info
#
# Gathers and displays:
#   - System: hostname, OS, kernel, uptime, load average
#   - Resources: CPU count, total RAM, disk usage
#   - Docker: version, compose version, images, containers, volumes, disk
#   - Network: active Docker networks
#
# Dependencies (when sourced):
#   Logger functions (log_info, log_keyvalue, etc.) are optional
# =============================================================================

# =============================================================================
# PATH AUTO-DETECTION
# =============================================================================

if [[ -z "${BASE_DIR:-}" ]]; then
    _SI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    BASE_DIR="$(cd "$_SI_SCRIPT_DIR/.." && pwd)"
    unset _SI_SCRIPT_DIR
fi

# =============================================================================
# COLOR SETUP
# =============================================================================

if [[ -z "${COLOR_RESET:-}" ]]; then
    if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]] && command -v tput >/dev/null 2>&1; then
        _SI_RESET="$(tput sgr0)"
        _SI_BOLD="$(tput bold)"
        _SI_DIM="$(tput dim)"
        _SI_CYAN="$(tput setaf 51)"
        _SI_BLUE="$(tput setaf 33)"
        _SI_GREEN="$(tput setaf 82)"
        _SI_YELLOW="$(tput setaf 214)"
        _SI_GRAY="$(tput setaf 245)"
        _SI_WHITE="$(tput setaf 15)"
        _SI_MAGENTA="$(tput setaf 141)"
    else
        _SI_RESET="" _SI_BOLD="" _SI_DIM=""
        _SI_CYAN="" _SI_BLUE="" _SI_GREEN=""
        _SI_YELLOW="" _SI_GRAY="" _SI_WHITE="" _SI_MAGENTA=""
    fi
else
    _SI_RESET="${COLOR_RESET}"
    _SI_BOLD="${COLOR_BOLD:-}"
    _SI_DIM="${COLOR_DIM:-}"
    _SI_CYAN="${COLOR_PROMPT:-$(tput setaf 51 2>/dev/null || true)}"
    _SI_BLUE="${COLOR_FOCUS:-$(tput setaf 33 2>/dev/null || true)}"
    _SI_GREEN="${COLOR_SUCCESS:-$(tput setaf 82 2>/dev/null || true)}"
    _SI_YELLOW="${COLOR_WARNING:-$(tput setaf 214 2>/dev/null || true)}"
    _SI_GRAY="${COLOR_NEUTRAL:-$(tput setaf 245 2>/dev/null || true)}"
    _SI_WHITE="$(tput setaf 15 2>/dev/null || true)"
    _SI_MAGENTA="${COLOR_INFO_HEADER:-$(tput setaf 141 2>/dev/null || true)}"
fi

# =============================================================================
# INTERNAL UTILITIES
# =============================================================================

# Print a key-value pair with dot-leader alignment
_si_kv() {
    local key="$1"
    local value="$2"
    local key_color="${3:-${_SI_CYAN}}"

    local align_width=26
    local key_len=${#key}
    local dots_count=$(( align_width - key_len ))
    (( dots_count < 3 )) && dots_count=3

    local dots
    dots="$(printf '%*s' "$dots_count" '' | tr ' ' '.')"

    printf "    ${key_color}%s${_SI_RESET} ${_SI_DIM}${_SI_GRAY}%s${_SI_RESET} ${_SI_WHITE}%s${_SI_RESET}\n" \
        "$key" "$dots" "$value"
}

# Print a section header
_si_section() {
    local title="$1"
    local width=60
    local pad=$(( (width - ${#title} - 4) / 2 ))
    (( pad < 1 )) && pad=1

    local leader
    leader="$(printf '%*s' "$pad" '' | tr ' ' '-')"

    echo ""
    printf "  ${_SI_BOLD}${_SI_BLUE}%s %s %s${_SI_RESET}\n" "$leader" "$title" "$leader"
    echo ""
}

# Repeat a character
_si_repeat() {
    local char="$1"
    local count="$2"
    (( count <= 0 )) && return
    printf "%0.s${char}" $(seq 1 "$count")
}

# =============================================================================
# DATA GATHERING FUNCTIONS
# =============================================================================

_si_get_os_info() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release 2>/dev/null
        echo "${PRETTY_NAME:-${NAME:-Linux} ${VERSION:-}}"
    elif command -v lsb_release >/dev/null 2>&1; then
        lsb_release -ds 2>/dev/null
    elif [[ -f /etc/redhat-release ]]; then
        cat /etc/redhat-release
    else
        uname -o 2>/dev/null || echo "Unknown"
    fi
}

_si_get_kernel() {
    uname -r 2>/dev/null || echo "Unknown"
}

_si_get_architecture() {
    uname -m 2>/dev/null || echo "Unknown"
}

_si_get_hostname() {
    hostname -f 2>/dev/null || hostname 2>/dev/null || echo "Unknown"
}

_si_get_uptime() {
    if command -v uptime >/dev/null 2>&1; then
        local raw
        raw="$(uptime -p 2>/dev/null)"
        if [[ -n "$raw" ]]; then
            echo "${raw#up }"
        else
            uptime 2>/dev/null | sed 's/.*up \(.*\),.*user.*/\1/' | sed 's/^[[:space:]]*//'
        fi
    else
        echo "Unknown"
    fi
}

_si_get_load_average() {
    if [[ -f /proc/loadavg ]]; then
        awk '{print $1", "$2", "$3}' /proc/loadavg
    elif command -v uptime >/dev/null 2>&1; then
        uptime | awk -F'load average:' '{print $2}' | sed 's/^[[:space:]]*//'
    else
        echo "Unknown"
    fi
}

_si_get_cpu_count() {
    if command -v nproc >/dev/null 2>&1; then
        nproc
    elif [[ -f /proc/cpuinfo ]]; then
        grep -c ^processor /proc/cpuinfo
    else
        echo "Unknown"
    fi
}

_si_get_cpu_model() {
    if [[ -f /proc/cpuinfo ]]; then
        grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | sed 's/.*: //'
    else
        echo "Unknown"
    fi
}

_si_get_total_memory() {
    if command -v free >/dev/null 2>&1; then
        free -h 2>/dev/null | awk '/^Mem:/ {print $2}'
    elif [[ -f /proc/meminfo ]]; then
        awk '/MemTotal/ {printf "%.1f GiB", $2/1048576}' /proc/meminfo
    else
        echo "Unknown"
    fi
}

_si_get_used_memory() {
    if command -v free >/dev/null 2>&1; then
        free -h 2>/dev/null | awk '/^Mem:/ {print $3"/"$2" ("$3/$2*100"%)"}'
        return
    fi
    echo "Unknown"
}

_si_get_memory_percent() {
    if command -v free >/dev/null 2>&1; then
        free 2>/dev/null | awk '/^Mem:/ {printf "%.1f%%", $3/$2*100}'
    else
        echo "Unknown"
    fi
}

_si_get_disk_usage() {
    local mount="${1:-/}"
    if command -v df >/dev/null 2>&1; then
        df -h "$mount" 2>/dev/null | awk 'NR==2 {printf "%s / %s (%s)", $3, $2, $5}'
    else
        echo "Unknown"
    fi
}

_si_get_docker_version() {
    docker version --format '{{.Server.Version}}' 2>/dev/null || echo "Not available"
}

_si_get_compose_version() {
    if docker compose version >/dev/null 2>&1; then
        docker compose version --short 2>/dev/null || docker compose version 2>/dev/null | grep -oP '[\d.]+'
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose version --short 2>/dev/null || echo "Legacy"
    else
        echo "Not installed"
    fi
}

_si_get_docker_running_containers() {
    docker ps -q 2>/dev/null | wc -l | tr -d ' '
}

_si_get_docker_total_containers() {
    docker ps -aq 2>/dev/null | wc -l | tr -d ' '
}

_si_get_docker_images() {
    docker images -q 2>/dev/null | sort -u | wc -l | tr -d ' '
}

_si_get_docker_volumes() {
    docker volume ls -q 2>/dev/null | wc -l | tr -d ' '
}

_si_get_docker_networks() {
    docker network ls --format '{{.Name}}' 2>/dev/null | grep -cv '^bridge$\|^host$\|^none$' || echo "0"
}

_si_get_docker_disk_usage() {
    local usage
    usage="$(docker system df --format '{{.Size}}' 2>/dev/null | head -1)"
    if [[ -n "$usage" ]]; then
        echo "$usage"
    else
        echo "Unknown"
    fi
}

_si_get_docker_networks_list() {
    docker network ls --format '{{.Name}}' 2>/dev/null | grep -v '^bridge$\|^host$\|^none$' | sort
}

# =============================================================================
# MAIN DISPLAY FUNCTION
# =============================================================================

show_system_info() {
    local mode="${1:-full}"  # full, brief, json

    # JSON output mode
    if [[ "$mode" == "json" ]]; then
        _si_json_output
        return $?
    fi

    local width=60
    local border
    border="$(_si_repeat "=" "$width")"

    # Header
    echo ""
    echo "  ${_SI_BOLD}${_SI_BLUE}${border}${_SI_RESET}"
    local header_text="System Information Report"
    local header_pad=$(( (width - ${#header_text}) / 2 ))
    printf "  ${_SI_BOLD}${_SI_CYAN}%*s%s${_SI_RESET}\n" "$header_pad" "" "$header_text"
    echo "  ${_SI_BOLD}${_SI_BLUE}${border}${_SI_RESET}"

    # --- System Section ---
    _si_section "SYSTEM"
    _si_kv "Hostname"      "$(_si_get_hostname)"
    _si_kv "Operating System" "$(_si_get_os_info)"
    _si_kv "Kernel"        "$(_si_get_kernel)"
    _si_kv "Architecture"  "$(_si_get_architecture)"
    _si_kv "System Uptime" "$(_si_get_uptime)"
    _si_kv "Load Average"  "$(_si_get_load_average)"

    # --- Resources Section ---
    _si_section "RESOURCES"
    _si_kv "CPU Cores"     "$(_si_get_cpu_count)"

    if [[ "$mode" == "full" ]]; then
        local cpu_model
        cpu_model="$(_si_get_cpu_model)"
        if [[ -n "$cpu_model" ]] && [[ "$cpu_model" != "Unknown" ]]; then
            _si_kv "CPU Model" "$cpu_model"
        fi
    fi

    _si_kv "Total Memory"  "$(_si_get_total_memory)"
    _si_kv "Memory Usage"  "$(_si_get_memory_percent)"
    _si_kv "Disk Usage (/)" "$(_si_get_disk_usage "/")"

    # --- Docker Section ---
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        _si_section "DOCKER"
        _si_kv "Docker Version"  "$(_si_get_docker_version)"
        _si_kv "Compose Version" "$(_si_get_compose_version)"

        local running total_c
        running="$(_si_get_docker_running_containers)"
        total_c="$(_si_get_docker_total_containers)"
        _si_kv "Containers"      "${running} running / ${total_c} total"
        _si_kv "Images"          "$(_si_get_docker_images)"
        _si_kv "Volumes"         "$(_si_get_docker_volumes)"
        _si_kv "Custom Networks" "$(_si_get_docker_networks)"

        if [[ "$mode" == "full" ]]; then
            _si_kv "Docker Disk" "$(_si_get_docker_disk_usage)"

            # List custom networks
            local -a networks=()
            while IFS= read -r net; do
                [[ -n "$net" ]] && networks+=("$net")
            done < <(_si_get_docker_networks_list)

            if [[ ${#networks[@]} -gt 0 ]]; then
                echo ""
                printf "    ${_SI_BOLD}${_SI_MAGENTA}Active Networks:${_SI_RESET}\n"
                for net in "${networks[@]}"; do
                    printf "      ${_SI_DIM}${_SI_GRAY}|${_SI_RESET} ${_SI_GREEN}%s${_SI_RESET}\n" "$net"
                done
            fi
        fi
    else
        _si_section "DOCKER"
        printf "    ${_SI_YELLOW}Docker is not running or not installed${_SI_RESET}\n"
    fi

    # --- Application Section ---
    _si_section "APPLICATION"
    _si_kv "Version"     "${SCRIPT_VERSION:-Unknown}"
    _si_kv "Environment" "${ENVIRONMENT:-production}"
    _si_kv "Base Dir"    "${BASE_DIR:-Unknown}"
    _si_kv "Log Level"   "${LOG_LEVEL:-INFO}"

    if [[ "$mode" == "full" ]]; then
        _si_kv "Log File"  "${LOG_FILE:-Not configured}"
        _si_kv "User"      "$(whoami)"
        _si_kv "Shell"     "${SHELL:-Unknown}"
    fi

    # Footer
    echo ""
    echo "  ${_SI_DIM}${_SI_GRAY}$(_si_repeat "-" "$width")${_SI_RESET}"
    printf "  ${_SI_DIM}${_SI_GRAY}Report generated at %s${_SI_RESET}\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
}

# =============================================================================
# JSON OUTPUT
# =============================================================================

_si_json_output() {
    local running total_c images volumes networks

    running="$(_si_get_docker_running_containers)"
    total_c="$(_si_get_docker_total_containers)"
    images="$(_si_get_docker_images)"
    volumes="$(_si_get_docker_volumes)"
    networks="$(_si_get_docker_networks)"

    cat <<JSON
{
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "system": {
    "hostname": "$(_si_get_hostname)",
    "os": "$(_si_get_os_info)",
    "kernel": "$(_si_get_kernel)",
    "architecture": "$(_si_get_architecture)",
    "uptime": "$(_si_get_uptime)",
    "load_average": "$(_si_get_load_average)",
    "cpu_cores": $(_si_get_cpu_count),
    "total_memory": "$(_si_get_total_memory)",
    "memory_percent": "$(_si_get_memory_percent)",
    "disk_usage": "$(_si_get_disk_usage "/")"
  },
  "docker": {
    "version": "$(_si_get_docker_version)",
    "compose_version": "$(_si_get_compose_version)",
    "running_containers": $running,
    "total_containers": $total_c,
    "images": $images,
    "volumes": $volumes,
    "custom_networks": $networks
  },
  "application": {
    "version": "${SCRIPT_VERSION:-unknown}",
    "environment": "${ENVIRONMENT:-production}",
    "base_dir": "${BASE_DIR:-unknown}",
    "log_level": "${LOG_LEVEL:-INFO}"
  }
}
JSON
}

# =============================================================================
# STANDALONE EXECUTION
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

    _SI_MODE="full"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json|-j)
                _SI_MODE="json"
                shift
                ;;
            --brief|-b)
                _SI_MODE="brief"
                shift
                ;;
            --help|-h)
                cat <<'HELP'
Docker Compose Skeleton — System Information Reporter

Usage: ./system-info.sh [OPTIONS]

Options:
  --brief, -b    Abbreviated output (skip detailed info)
  --json, -j     Output as JSON
  --help, -h     Show this help message

Examples:
  ./system-info.sh              Full system report
  ./system-info.sh --brief      Quick overview
  ./system-info.sh --json       JSON for automation

HELP
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                echo "Run './system-info.sh --help' for usage."
                exit 1
                ;;
        esac
    done

    show_system_info "$_SI_MODE"
    exit $?
fi

# =============================================================================
# EXPORT FUNCTIONS FOR SOURCED USE
# =============================================================================

export -f show_system_info
export -f _si_kv _si_section _si_repeat
export -f _si_get_os_info _si_get_kernel _si_get_architecture _si_get_hostname
export -f _si_get_uptime _si_get_load_average _si_get_cpu_count _si_get_cpu_model
export -f _si_get_total_memory _si_get_used_memory _si_get_memory_percent
export -f _si_get_disk_usage
export -f _si_get_docker_version _si_get_compose_version
export -f _si_get_docker_running_containers _si_get_docker_total_containers
export -f _si_get_docker_images _si_get_docker_volumes _si_get_docker_networks
export -f _si_get_docker_disk_usage _si_get_docker_networks_list
