#!/bin/bash
# =============================================================================
# Docker Compose Update Library
# Checks for the latest Docker Compose release on GitHub and offers to install
# it, with architecture detection, backup, and rollback support.
#
# This file is SOURCED by start.sh -- do not execute directly.
#
# Expected environment (set by caller):
#   $DOCKER_COMPOSE_CMD  -- detected compose command (from docker-utils.sh)
#
# Logger functions (log_info, log_error, etc.) must be available.
# =============================================================================

# =============================================================================
# MAIN UPDATE FUNCTION
# =============================================================================

initiate_docker_update() {
    # If using the v2 plugin (docker compose) the binary is managed by the
    # system package manager -- there is nothing for us to download.
    if _is_compose_v2 2>/dev/null; then
        log_bold_nodate_info "Using Docker Compose plugin (v2) -- managed by package manager, skipping manual update"
        return 0
    fi

    # Constants
    local install_location="/usr/bin/docker-compose"
    local github_api_url="https://api.github.com/repos/docker/compose/releases/latest"

    # Detect system architecture
    local arch
    arch=$(uname -m)
    local arch_suffix
    case "$arch" in
        x86_64)          arch_suffix="linux-x86_64" ;;
        aarch64|arm64)   arch_suffix="linux-aarch64" ;;
        *)
            log_bold_nodate_error "Unsupported architecture: $arch"
            return 1
            ;;
    esac

    # Check required commands
    local cmd
    for cmd in curl jq sudo; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_bold_nodate_error "Required command '$cmd' not found. Please install it first."
            return 1
        fi
    done

    # Get current version (if installed)
    local current_version=""
    if [[ -f "$install_location" ]]; then
        current_version=$("$install_location" --version 2>/dev/null \
            | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        log_bold_nodate_info "Current Docker Compose version: v${current_version:-unknown}"
    else
        log_bold_nodate_warning "Docker Compose v1 binary is not installed at $install_location"
    fi

    # Fetch latest release from GitHub
    log_bold_nodate_info "Fetching latest Docker Compose release information..."
    local release_data
    if ! release_data=$(curl -sf --connect-timeout 10 --max-time 30 "$github_api_url"); then
        log_bold_nodate_error "Failed to fetch release data from GitHub API. Check your internet connection."
        return 1
    fi

    local latest_version
    local download_url
    latest_version=$(echo "$release_data" | jq -r '.tag_name' | sed 's/^v//')
    download_url=$(echo "$release_data" | jq -r --arg suffix "docker-compose-$arch_suffix" \
        '.assets[] | select(.name == $suffix) | .browser_download_url')

    if [[ -z "$latest_version" || "$latest_version" == "null" ]]; then
        log_bold_nodate_error "Failed to parse latest version from GitHub API response."
        return 1
    fi

    if [[ -z "$download_url" || "$download_url" == "null" ]]; then
        log_bold_nodate_error "No compatible binary found for architecture: $arch"
        return 1
    fi

    log_bold_nodate_highlight "Latest version available: v$latest_version"

    # Skip if already up to date
    if [[ "$current_version" == "$latest_version" ]]; then
        log_bold_nodate_success "Docker Compose is already up to date (v$latest_version)."
        return 0
    fi

    # User confirmation
    log_bold_nodate_question "Update Docker Compose from v${current_version:-none} to v$latest_version? (y/N): "
    read -r answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        log_bold_nodate_tip "Update cancelled by user."
        return 0
    fi

    # Create backup of existing binary
    if [[ -f "$install_location" ]]; then
        log_bold_nodate_info "Creating backup of current installation..."
        if ! sudo cp "$install_location" "${install_location}.backup.$(date +%Y%m%d_%H%M%S)"; then
            log_bold_nodate_warning "Failed to create backup, but continuing with update..."
        fi
    fi

    # Download and install
    log_bold_nodate_info "Downloading Docker Compose v$latest_version..."
    if sudo curl -fL --progress-bar --connect-timeout 10 --max-time 300 \
        "$download_url" -o "$install_location"; then
        log_bold_nodate_success "Download completed successfully."
    else
        log_bold_nodate_error "Download failed. Restoring from backup if available..."
        local latest_backup
        latest_backup=$(ls -t "${install_location}.backup."* 2>/dev/null | head -1)
        [[ -n "$latest_backup" ]] && sudo mv "$latest_backup" "$install_location" 2>/dev/null
        return 1
    fi

    # Set executable permissions
    if ! sudo chmod +x "$install_location"; then
        log_bold_nodate_error "Failed to set executable permissions."
        return 1
    fi

    # Verify installation
    local installed_version
    if installed_version=$("$install_location" --version 2>/dev/null); then
        log_bold_nodate_success "Docker Compose successfully updated!"
        log_bold_nodate_info "Installed version: $installed_version"

        # Clean up old backups (keep only 3 most recent)
        find /usr/bin -name "docker-compose.backup.*" -type f 2>/dev/null \
            | sort | head -n -3 | xargs -r sudo rm -f
    else
        log_bold_nodate_error "Installation verification failed. Docker Compose may not be working correctly."
        return 1
    fi

    return 0
}
