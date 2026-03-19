#!/bin/bash
# =============================================================================
# Docker Compose Skeleton — Configuration Validator
# Validates all .env files, docker-compose.yml files, directory structure,
# and system requirements. Run before startup to catch issues early.
#
# Usage:
#   ./config-validator.sh [--fix] [--quiet] [--json]
#
# Options:
#   --fix     Auto-fix common issues (create missing dirs, set permissions)
#   --quiet   Only show errors (suppress info/warnings)
#   --json    Output results as JSON
#
# Exit codes:
#   0 — All checks passed
#   1 — Critical errors found
#   2 — Warnings only (non-critical)
# =============================================================================

# =============================================================================
# PATH AUTO-DETECTION
# =============================================================================

if [[ -z "${BASE_DIR:-}" ]]; then
    _CV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    BASE_DIR="$(cd "$_CV_SCRIPT_DIR/.." && pwd)"
    unset _CV_SCRIPT_DIR
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

if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]] && command -v tput >/dev/null 2>&1; then
    _CV_RESET="$(tput sgr0)"
    _CV_BOLD="$(tput bold)"
    _CV_DIM="$(tput dim)"
    _CV_GREEN="$(tput setaf 82)"
    _CV_YELLOW="$(tput setaf 214)"
    _CV_RED="$(tput setaf 196)"
    _CV_CYAN="$(tput setaf 51)"
    _CV_BLUE="$(tput setaf 33)"
    _CV_GRAY="$(tput setaf 245)"
    _CV_MAGENTA="$(tput setaf 141)"
else
    _CV_RESET="" _CV_BOLD="" _CV_DIM=""
    _CV_GREEN="" _CV_YELLOW="" _CV_RED="" _CV_CYAN=""
    _CV_BLUE="" _CV_GRAY="" _CV_MAGENTA=""
fi

# =============================================================================
# STATE
# =============================================================================

declare -i PASS_COUNT=0
declare -i WARN_COUNT=0
declare -i FAIL_COUNT=0
declare -i FIX_COUNT=0

AUTO_FIX=false
QUIET_MODE=false
JSON_MODE=false

declare -a RESULTS=()

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fix)   AUTO_FIX=true; shift ;;
        --quiet) QUIET_MODE=true; shift ;;
        --json)  JSON_MODE=true; shift ;;
        --help|-h)
            cat <<EOF
Configuration Validator — Validates your Docker Compose Skeleton setup

Usage: $0 [--fix] [--quiet] [--json]

Options:
  --fix     Auto-fix common issues (directories, permissions)
  --quiet   Only show errors
  --json    Output results as JSON

Checks:
  - System requirements (Docker, Bash version, disk space)
  - Directory structure (Stacks, App-Data, logs)
  - Root .env configuration
  - Stack-level .env files
  - Docker Compose file syntax
  - Script permissions
  - Network/port conflicts
EOF
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# =============================================================================
# REPORTING FUNCTIONS
# =============================================================================

_cv_pass() {
    (( PASS_COUNT++ ))
    RESULTS+=("PASS|$1")
    [[ "$QUIET_MODE" == "true" ]] && return
    [[ "$JSON_MODE" == "true" ]] && return
    echo "  ${_CV_GREEN}PASS${_CV_RESET}  $1"
}

_cv_warn() {
    (( WARN_COUNT++ ))
    RESULTS+=("WARN|$1")
    [[ "$JSON_MODE" == "true" ]] && return
    echo "  ${_CV_YELLOW}WARN${_CV_RESET}  $1"
}

_cv_fail() {
    (( FAIL_COUNT++ ))
    RESULTS+=("FAIL|$1")
    [[ "$JSON_MODE" == "true" ]] && return
    echo "  ${_CV_RED}FAIL${_CV_RESET}  $1"
}

_cv_fix() {
    (( FIX_COUNT++ ))
    [[ "$JSON_MODE" == "true" ]] && return
    echo "  ${_CV_MAGENTA}FIX ${_CV_RESET}  $1"
}

_cv_section() {
    [[ "$JSON_MODE" == "true" ]] && return
    echo ""
    echo "  ${_CV_BOLD}${_CV_CYAN}$1${_CV_RESET}"
    echo "  ${_CV_GRAY}$(printf '%0.s-' $(seq 1 ${#1}))${_CV_RESET}"
}

# =============================================================================
# CHECK: SYSTEM REQUIREMENTS
# =============================================================================

check_system() {
    _cv_section "System Requirements"

    # Bash version
    local bash_major="${BASH_VERSINFO[0]}"
    if [[ "$bash_major" -ge 4 ]]; then
        _cv_pass "Bash version: ${BASH_VERSION} (>= 4.0 required)"
    else
        _cv_fail "Bash version: ${BASH_VERSION} — Bash 4+ required for associative arrays"
    fi

    # Docker
    if command -v docker >/dev/null 2>&1; then
        local docker_version
        docker_version="$(docker --version 2>/dev/null | sed 's/Docker version //' | cut -d, -f1)"
        _cv_pass "Docker installed: v$docker_version"

        if docker info >/dev/null 2>&1; then
            _cv_pass "Docker daemon is running"
        else
            _cv_fail "Docker daemon is not running or not accessible"
        fi
    else
        _cv_fail "Docker is not installed"
    fi

    # Docker Compose
    if docker compose version >/dev/null 2>&1; then
        local compose_version
        compose_version="$(docker compose version --short 2>/dev/null)"
        _cv_pass "Docker Compose v2 plugin: v$compose_version"
    elif command -v docker-compose >/dev/null 2>&1; then
        local compose_version
        compose_version="$(docker-compose --version 2>/dev/null | grep -oP '[\d.]+')"
        _cv_warn "Using legacy docker-compose v1: v$compose_version (v2 plugin recommended)"
    else
        _cv_fail "No Docker Compose installation found"
    fi

    # Required tools
    for tool in curl grep sed tput mktemp; do
        if command -v "$tool" >/dev/null 2>&1; then
            _cv_pass "Required tool: $tool"
        else
            _cv_warn "Optional tool missing: $tool"
        fi
    done

    # Disk space
    local available_gb
    available_gb="$(df -BG "$BASE_DIR" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G')"
    if [[ -n "$available_gb" ]] && [[ "$available_gb" -gt 5 ]]; then
        _cv_pass "Disk space: ${available_gb}GB available"
    elif [[ -n "$available_gb" ]]; then
        _cv_warn "Low disk space: ${available_gb}GB available (< 5GB)"
    fi
}

# =============================================================================
# CHECK: DIRECTORY STRUCTURE
# =============================================================================

check_directories() {
    _cv_section "Directory Structure"

    local required_dirs=(
        "$BASE_DIR/Stacks"
        "$BASE_DIR/.config"
        "$BASE_DIR/.lib"
        "$BASE_DIR/.scripts"
    )

    for dir in "${required_dirs[@]}"; do
        local relative="${dir#$BASE_DIR/}"
        if [[ -d "$dir" ]]; then
            _cv_pass "Directory exists: $relative"
        else
            _cv_fail "Directory missing: $relative"
            if [[ "$AUTO_FIX" == "true" ]]; then
                mkdir -p "$dir" && _cv_fix "Created: $relative"
            fi
        fi
    done

    # Optional directories (created if --fix)
    local optional_dirs=(
        "$BASE_DIR/logs"
        "$APP_DATA_DIR"
    )

    for dir in "${optional_dirs[@]}"; do
        local relative="${dir#$BASE_DIR/}"
        if [[ -d "$dir" ]]; then
            _cv_pass "Directory exists: $relative"
        else
            _cv_warn "Optional directory missing: $relative"
            if [[ "$AUTO_FIX" == "true" ]]; then
                mkdir -p "$dir" && _cv_fix "Created: $relative"
            fi
        fi
    done
}

# =============================================================================
# CHECK: ROOT CONFIGURATION
# =============================================================================

check_root_config() {
    _cv_section "Root Configuration"

    # .env file
    if [[ -f "$BASE_DIR/.env" ]]; then
        _cv_pass ".env file exists"

        # Check for placeholder values
        local proxy_domain
        proxy_domain="$(grep '^PROXY_DOMAIN=' "$BASE_DIR/.env" 2>/dev/null | cut -d= -f2)"
        if [[ "$proxy_domain" == "example.com" ]]; then
            _cv_warn "PROXY_DOMAIN is still set to 'example.com' — update for production"
        elif [[ -n "$proxy_domain" ]]; then
            _cv_pass "PROXY_DOMAIN configured: $proxy_domain"
        fi

        # Check TZ
        local tz_val
        tz_val="$(grep '^TZ=' "$BASE_DIR/.env" 2>/dev/null | cut -d= -f2)"
        if [[ "$tz_val" == "UTC" ]]; then
            _cv_pass "TZ configured: $tz_val"
        elif [[ -n "$tz_val" ]]; then
            _cv_pass "TZ configured: $tz_val"
        else
            _cv_warn "TZ not set in .env"
        fi

        # Check APP_DATA_DIR
        local app_data
        app_data="$(grep '^APP_DATA_DIR=' "$BASE_DIR/.env" 2>/dev/null | cut -d= -f2 | tr -d '"')"
        if [[ -n "$app_data" ]]; then
            _cv_pass "APP_DATA_DIR configured: $app_data"
        fi

    else
        _cv_fail ".env file missing"
        if [[ -f "$BASE_DIR/.env.example" ]]; then
            _cv_warn ".env.example exists — copy it to .env and customize"
            if [[ "$AUTO_FIX" == "true" ]]; then
                cp "$BASE_DIR/.env.example" "$BASE_DIR/.env"
                _cv_fix "Copied .env.example to .env"
            fi
        fi
    fi

    # .env.example
    if [[ -f "$BASE_DIR/.env.example" ]]; then
        _cv_pass ".env.example template exists"
    else
        _cv_warn ".env.example template missing"
    fi

    # settings.cfg
    if [[ -f "$BASE_DIR/.config/settings.cfg" ]]; then
        _cv_pass "settings.cfg exists"
    else
        _cv_fail "settings.cfg missing — logger will fail to initialize"
    fi

    # palette.sh
    if [[ -f "$BASE_DIR/.config/palette.sh" ]]; then
        _cv_pass "palette.sh exists"
    else
        _cv_fail "palette.sh missing — logger will fail to initialize"
    fi
}

# =============================================================================
# CHECK: SCRIPTS
# =============================================================================

check_scripts() {
    _cv_section "Script Files"

    local required_scripts=(
        "$BASE_DIR/start.sh"
        "$BASE_DIR/stop.sh"
        "$BASE_DIR/setup.sh"
        "$BASE_DIR/.scripts/run.sh"
        "$BASE_DIR/.scripts/stop.sh"
        "$BASE_DIR/.lib/logger.sh"
        "$BASE_DIR/.lib/docker-utils.sh"
    )

    for script in "${required_scripts[@]}"; do
        local relative="${script#$BASE_DIR/}"
        if [[ -f "$script" ]]; then
            if [[ -x "$script" ]]; then
                _cv_pass "Executable: $relative"
            else
                _cv_warn "Not executable: $relative"
                if [[ "$AUTO_FIX" == "true" ]]; then
                    chmod +x "$script" && _cv_fix "Made executable: $relative"
                fi
            fi
        else
            _cv_fail "Missing: $relative"
        fi
    done

    # Optional scripts
    local optional_scripts=(
        "$BASE_DIR/restart.sh"
        "$BASE_DIR/status.sh"
        "$BASE_DIR/.scripts/health-check.sh"
        "$BASE_DIR/.scripts/system-info.sh"
        "$BASE_DIR/.scripts/logs-viewer.sh"
        "$BASE_DIR/.scripts/stack-manager.sh"
        "$BASE_DIR/.scripts/clean-up.sh"
        "$BASE_DIR/.scripts/update.sh"
        "$BASE_DIR/.scripts/update_all_stacks.sh"
        "$BASE_DIR/.lib/banner.sh"
    )

    for script in "${optional_scripts[@]}"; do
        local relative="${script#$BASE_DIR/}"
        if [[ -f "$script" ]]; then
            if [[ -x "$script" ]]; then
                _cv_pass "Optional: $relative"
            else
                _cv_warn "Optional but not executable: $relative"
                if [[ "$AUTO_FIX" == "true" ]]; then
                    chmod +x "$script" && _cv_fix "Made executable: $relative"
                fi
            fi
        fi
    done
}

# =============================================================================
# CHECK: STACKS
# =============================================================================

check_stacks() {
    _cv_section "Docker Compose Stacks"

    local stack_count=0
    local valid_count=0

    for stack_dir in "$COMPOSE_DIR"/*/; do
        [[ ! -d "$stack_dir" ]] && continue
        local stack_name="$(basename "$stack_dir")"
        (( stack_count++ ))

        local compose_file="$stack_dir/docker-compose.yml"
        local env_file="$stack_dir/.env"

        if [[ -f "$compose_file" ]]; then
            # Validate compose file syntax
            if docker compose -f "$compose_file" config >/dev/null 2>&1; then
                _cv_pass "Stack valid: $stack_name"
                (( valid_count++ ))
            elif $DOCKER_COMPOSE_CMD -f "$compose_file" config >/dev/null 2>&1; then
                _cv_pass "Stack valid: $stack_name"
                (( valid_count++ ))
            else
                _cv_warn "Stack syntax issue: $stack_name (may work with env vars)"
                (( valid_count++ ))
            fi
        else
            _cv_fail "No docker-compose.yml: $stack_name"
        fi

        if [[ ! -f "$env_file" ]]; then
            _cv_warn "No .env file: $stack_name (will inherit from root)"
        fi
    done

    if [[ "$stack_count" -eq 0 ]]; then
        _cv_fail "No stacks found in $COMPOSE_DIR"
    else
        echo ""
        echo "  ${_CV_DIM}${_CV_GRAY}$valid_count/$stack_count stacks validated${_CV_RESET}"
    fi
}

# =============================================================================
# CHECK: PORT CONFLICTS
# =============================================================================

check_ports() {
    _cv_section "Port Analysis"

    # Extract exposed ports from all compose files
    local -A port_map=()
    local conflicts=0

    for stack_dir in "$COMPOSE_DIR"/*/; do
        [[ ! -d "$stack_dir" ]] && continue
        local stack_name="$(basename "$stack_dir")"
        local compose_file="$stack_dir/docker-compose.yml"

        [[ ! -f "$compose_file" ]] && continue

        # Extract host port mappings (lines like "8080:80" or "- 8080:80")
        while IFS= read -r line; do
            local host_port
            host_port="$(echo "$line" | grep -oP '^\s*-?\s*"?\K\d+(?=:)' 2>/dev/null)"
            if [[ -n "$host_port" ]]; then
                if [[ -n "${port_map[$host_port]:-}" ]]; then
                    _cv_warn "Port $host_port used by both: ${port_map[$host_port]} and $stack_name"
                    (( conflicts++ ))
                else
                    port_map["$host_port"]="$stack_name"
                fi
            fi
        done < <(grep -E '^\s*-?\s*"?\d+:\d+' "$compose_file" 2>/dev/null)
    done

    if [[ "$conflicts" -eq 0 ]]; then
        _cv_pass "No port conflicts detected"
    fi

    local port_count="${#port_map[@]}"
    echo "  ${_CV_DIM}${_CV_GRAY}$port_count unique host ports mapped${_CV_RESET}"
}

# =============================================================================
# SUMMARY
# =============================================================================

print_summary() {
    if [[ "$JSON_MODE" == "true" ]]; then
        echo "{"
        echo "  \"pass\": $PASS_COUNT,"
        echo "  \"warn\": $WARN_COUNT,"
        echo "  \"fail\": $FAIL_COUNT,"
        echo "  \"fixed\": $FIX_COUNT,"
        echo "  \"results\": ["
        local first=true
        for result in "${RESULTS[@]}"; do
            local level="${result%%|*}"
            local message="${result#*|}"
            [[ "$first" == "true" ]] && first=false || echo ","
            printf '    {"level": "%s", "message": "%s"}' "$level" "$message"
        done
        echo ""
        echo "  ]"
        echo "}"
        return
    fi

    echo ""
    local total=$(( PASS_COUNT + WARN_COUNT + FAIL_COUNT ))
    local border
    border="$(printf '%0.s-' {1..50})"

    echo "  ${_CV_BLUE}+${border}+${_CV_RESET}"
    echo "  ${_CV_BLUE}|${_CV_RESET}  ${_CV_BOLD}${_CV_CYAN}VALIDATION SUMMARY${_CV_RESET}$(printf '%*s' 30 '')${_CV_BLUE}|${_CV_RESET}"
    echo "  ${_CV_BLUE}+${border}+${_CV_RESET}"
    echo "  ${_CV_BLUE}|${_CV_RESET}                                                  ${_CV_BLUE}|${_CV_RESET}"
    printf "  ${_CV_BLUE}|${_CV_RESET}    ${_CV_GREEN}Passed:${_CV_RESET}  %-5s                              ${_CV_BLUE}|${_CV_RESET}\n" "$PASS_COUNT"
    printf "  ${_CV_BLUE}|${_CV_RESET}    ${_CV_YELLOW}Warnings:${_CV_RESET} %-5s                             ${_CV_BLUE}|${_CV_RESET}\n" "$WARN_COUNT"
    printf "  ${_CV_BLUE}|${_CV_RESET}    ${_CV_RED}Failed:${_CV_RESET}  %-5s                              ${_CV_BLUE}|${_CV_RESET}\n" "$FAIL_COUNT"

    if [[ "$FIX_COUNT" -gt 0 ]]; then
        printf "  ${_CV_BLUE}|${_CV_RESET}    ${_CV_MAGENTA}Fixed:${_CV_RESET}   %-5s                              ${_CV_BLUE}|${_CV_RESET}\n" "$FIX_COUNT"
    fi

    echo "  ${_CV_BLUE}|${_CV_RESET}                                                  ${_CV_BLUE}|${_CV_RESET}"

    if [[ "$FAIL_COUNT" -eq 0 ]] && [[ "$WARN_COUNT" -eq 0 ]]; then
        echo "  ${_CV_BLUE}|${_CV_RESET}    ${_CV_BOLD}${_CV_GREEN}All checks passed!${_CV_RESET}                          ${_CV_BLUE}|${_CV_RESET}"
    elif [[ "$FAIL_COUNT" -eq 0 ]]; then
        echo "  ${_CV_BLUE}|${_CV_RESET}    ${_CV_BOLD}${_CV_YELLOW}No critical issues, some warnings${_CV_RESET}          ${_CV_BLUE}|${_CV_RESET}"
    else
        echo "  ${_CV_BLUE}|${_CV_RESET}    ${_CV_BOLD}${_CV_RED}Critical issues found — please fix${_CV_RESET}         ${_CV_BLUE}|${_CV_RESET}"
    fi

    echo "  ${_CV_BLUE}|${_CV_RESET}                                                  ${_CV_BLUE}|${_CV_RESET}"
    echo "  ${_CV_BLUE}+${border}+${_CV_RESET}"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "$JSON_MODE" != "true" ]]; then
        echo ""
        echo "  ${_CV_BOLD}${_CV_CYAN}Docker Compose Skeleton — Configuration Validator${_CV_RESET}"
        echo "  ${_CV_GRAY}Checking your setup...${_CV_RESET}"
    fi

    check_system
    check_directories
    check_root_config
    check_scripts
    check_stacks
    check_ports
    print_summary

    if [[ "$FAIL_COUNT" -gt 0 ]]; then
        exit 1
    elif [[ "$WARN_COUNT" -gt 0 ]]; then
        exit 2
    else
        exit 0
    fi
fi
