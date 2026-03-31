#!/bin/bash
# =============================================================================
# Environment Verification Library
# Checks that the host system has all required tools installed and offers
# to install missing ones via the detected package manager.
#
# This file is SOURCED by start.sh -- do not execute directly.
#
# Logger functions (log_info, log_error, etc.) must be available.
# =============================================================================

# =============================================================================
# HELPERS
# =============================================================================

# Detect the available package manager and return its install command.
# Prints the install command prefix to stdout.  Returns 1 if none found.
_detect_package_manager() {
    if   command -v apt-get >/dev/null 2>&1; then echo "sudo apt-get install -y"
    elif command -v dnf     >/dev/null 2>&1; then echo "sudo dnf install -y"
    elif command -v yum     >/dev/null 2>&1; then echo "sudo yum install -y"
    elif command -v pacman  >/dev/null 2>&1; then echo "sudo pacman -S --noconfirm --needed"
    elif command -v zypper  >/dev/null 2>&1; then echo "sudo zypper install -y"
    elif command -v apk     >/dev/null 2>&1; then echo "sudo apk add --no-cache"
    elif command -v xbps-install >/dev/null 2>&1; then echo "sudo xbps-install -y"
    else
        return 1
    fi
}

# Ensure a single tool is installed.  Prompts the user to install if missing.
# Args: $1 -- tool name
# Returns: 0 on success, exits 1 on failure
_ensure_tool_installed() {
    local tool="$1"

    # Already available -- nothing to do
    if command -v "$tool" &>/dev/null; then
        return 0
    fi

    log_error "Required tool '$tool' is not installed."

    read -rp "Do you want to install '$tool' now? [y/N] " answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        log_error "Installation of '$tool' declined. Exiting script."
        exit 1
    fi

    local install_cmd
    if ! install_cmd=$(_detect_package_manager); then
        log_error "No supported package manager found. Please install '$tool' manually."
        exit 1
    fi

    log_info "Installing '$tool' via: $install_cmd $tool"
    if ! $install_cmd "$tool"; then
        log_error "Failed to install '$tool'. Exiting script."
        exit 1
    fi

    # Verify the installation actually worked
    if ! command -v "$tool" &>/dev/null; then
        log_error "Installation of '$tool' completed but the command is still not found. Exiting script."
        exit 1
    fi

    log_success "Successfully installed '$tool'"
}

# =============================================================================
# MAIN VERIFICATION FUNCTION
# =============================================================================

# Verify that all required tools are present on the system.
verify_environment() {
    log_nodate_important "Environment Verification: Ensuring Compatibility..."

    # Core dependencies
    local -a required_tools=("curl" "docker" "jq" "openssl" "git" "python3")

    for tool in "${required_tools[@]}"; do
        _ensure_tool_installed "$tool"
    done

    # API server listener — need at least one of socat or ncat
    if ! command -v socat &>/dev/null && ! command -v ncat &>/dev/null; then
        log_warning "Neither 'socat' nor 'ncat' found — API server requires one of these"
        _ensure_tool_installed "socat"
    fi

    # Verify optional but recommended tools
    local -a optional_tools=("rsync" "tar" "xxd" "perl" "awk" "nproc" "sqlite3")
    for tool in "${optional_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            log_warning "Optional tool '$tool' not found — some features may be limited"
        fi
    done

    # Create required data directories for new subsystems
    local -a data_dirs=(
        "${BASE_DIR}/.data"
        "${BASE_DIR}/.data/metrics"
        "${BASE_DIR}/.data/rollback"
        "${BASE_DIR}/.data/schedules"
        "${BASE_DIR}/.secrets"
        "${BASE_DIR}/.plugins"
    )
    for dir in "${data_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir" 2>/dev/null
            log_debug "Created directory: $dir"
        fi
    done

    # Set secure permissions on secrets directory
    [[ -d "${BASE_DIR}/.secrets" ]] && chmod 700 "${BASE_DIR}/.secrets" 2>/dev/null

    log_bold_nodate_success "Environment Verification: Successful."
}
