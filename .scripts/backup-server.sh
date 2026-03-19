#!/bin/bash
# =============================================================================
# Docker Services Backup Script
# Creates a timestamped compressed backup of the Docker services directory
# with rsync, integrity verification, and configurable retention.
#
# This script can run standalone OR be sourced by start.sh.
# When standalone it auto-detects BASE_DIR and loads the .env + logger.
#
# Environment variables (from .env or caller):
#   $BACKUP_SOURCE_DIR       -- directory to back up  (default: $BASE_DIR)
#   $BACKUP_DEST_DIR         -- where to store archives (required for backup)
#   $BACKUP_RETENTION_COUNT  -- number of archives to keep (default: 6)
#   $BASE_DIR                -- repository root (auto-detected if unset)
#
# Logger functions are used if available; plain echo otherwise.
# =============================================================================

# =============================================================================
# AUTO-DETECTION (standalone mode)
# =============================================================================

# Detect BASE_DIR from the script's own location if not already set.
if [[ -z "${BASE_DIR:-}" ]]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    BASE_DIR="$(cd "$_SCRIPT_DIR/.." && pwd)"
    export BASE_DIR
    unset _SCRIPT_DIR
fi

# Load .env if running standalone and it has not been loaded yet.
if [[ -z "${COMPOSE_DIR:-}" ]] && [[ -f "$BASE_DIR/.env" ]]; then
    set -a
    source "$BASE_DIR/.env"
    set +a
fi

# Source the logger system if not already available.
if ! command -v log_info >/dev/null 2>&1; then
    if [[ -f "$BASE_DIR/.config/settings.cfg" ]] && [[ -f "$BASE_DIR/.lib/logger.sh" ]]; then
        source "$BASE_DIR/.config/settings.cfg"
        source "$BASE_DIR/.lib/logger.sh"

        # Override log file for backup operations if configured
        [[ -n "${BACKUP_LOG_FILE:-}" ]] && LOG_FILE="$BACKUP_LOG_FILE"

        initiate_logger
    fi
fi

# Fallback: if logger is STILL not available, define minimal stubs.
if ! command -v log_info >/dev/null 2>&1; then
    log_info()         { echo "[INFO]    $*"; }
    log_error()        { echo "[ERROR]   $*" >&2; }
    log_success()      { echo "[SUCCESS] $*"; }
    log_warning()      { echo "[WARNING] $*"; }
    log_status()       { echo "[STATUS]  $*"; }
    log_focus()        { echo "[FOCUS]   $*"; }
    log_confirmation() { echo "[OK]      $*"; }
fi

# =============================================================================
# CONFIGURATION
# =============================================================================

BACKUP_SOURCE="${BACKUP_SOURCE_DIR:-$BASE_DIR}"
BACKUP_ROOT="${BACKUP_DEST_DIR:-}"
BACKUP_DATE=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR_TEMP=""            # set later if backup proceeds
BACKUP_FILE="Docker-Compose-Backup-${BACKUP_DATE}.tar.gz"
RETENTION_COUNT="${BACKUP_RETENTION_COUNT:-6}"

# =============================================================================
# MAIN BACKUP FUNCTION
# =============================================================================

perform_docker_backup() {
    log_focus "Starting Docker services backup"
    log_info "Backup target: $BACKUP_FILE"

    # Validate source
    if [[ ! -d "$BACKUP_SOURCE" ]]; then
        log_error "Source directory does not exist: $BACKUP_SOURCE"
        return 1
    fi

    # Validate destination
    if [[ -z "$BACKUP_ROOT" ]]; then
        log_error "BACKUP_DEST_DIR is not set. Configure it in .env to enable backups."
        return 1
    fi

    if [[ ! -d "$BACKUP_ROOT" ]]; then
        log_info "Creating backup root directory: $BACKUP_ROOT"
        if ! mkdir -p "$BACKUP_ROOT"; then
            log_error "Failed to create backup root directory"
            return 1
        fi
    fi

    # Create temporary staging directory
    BACKUP_DIR_TEMP="$BACKUP_ROOT/$BACKUP_DATE"
    log_status "Creating temporary backup directory"
    if ! mkdir -p "$BACKUP_DIR_TEMP"; then
        log_error "Failed to create backup directory: $BACKUP_DIR_TEMP"
        return 1
    fi

    # Perform rsync backup
    log_status "Performing rsync backup"

    local rsync_err
    rsync_err=$(mktemp)

    if rsync -av --delete --partial --stats \
        --exclude='App-Data/NextCloud/' \
        "$BACKUP_SOURCE/" "$BACKUP_DIR_TEMP" 2>"$rsync_err"; then

        log_success "Rsync backup completed successfully"
    else
        local rsync_exit=$?
        log_warning "Initial rsync failed with exit code: $rsync_exit"

        # Retry with elevated permissions if it was a permission error
        if grep -q "Permission denied\|Operation not permitted" "$rsync_err" 2>/dev/null; then
            log_info "Attempting backup with elevated permissions"

            local rsync_err_sudo
            rsync_err_sudo=$(mktemp)

            if sudo rsync -av --delete --partial --stats \
                --exclude='App-Data/NextCloud/' \
                "$BACKUP_SOURCE/" "$BACKUP_DIR_TEMP" 2>"$rsync_err_sudo"; then

                log_success "Rsync backup completed with elevated permissions"
                sudo chown -R "$(whoami):$(id -gn)" "$BACKUP_DIR_TEMP"
            else
                log_error "Rsync backup failed even with elevated permissions"
                rm -f "$rsync_err" "$rsync_err_sudo"
                rm -rf "$BACKUP_DIR_TEMP"
                return 1
            fi
            rm -f "$rsync_err_sudo"
        else
            log_error "Rsync backup failed with non-permission related errors"
            rm -f "$rsync_err"
            rm -rf "$BACKUP_DIR_TEMP"
            return 1
        fi
    fi
    rm -f "$rsync_err"

    # Create compressed archive
    log_status "Creating compressed archive"
    if tar -czf "$BACKUP_ROOT/$BACKUP_FILE" -C "$BACKUP_DIR_TEMP" .; then
        log_success "Archive created successfully"

        # Verify archive integrity
        if tar -tzf "$BACKUP_ROOT/$BACKUP_FILE" >/dev/null 2>&1; then
            log_success "Archive integrity verified"
        else
            log_error "Archive integrity check failed"
            rm -f "$BACKUP_ROOT/$BACKUP_FILE"
            rm -rf "$BACKUP_DIR_TEMP"
            return 1
        fi
    else
        log_error "Archive creation failed"
        rm -rf "$BACKUP_DIR_TEMP"
        return 1
    fi

    # Remove temporary staging directory
    log_status "Cleaning up temporary files"
    rm -rf "$BACKUP_DIR_TEMP"

    # Enforce retention policy
    log_status "Enforcing backup retention (keeping $RETENTION_COUNT most recent)"
    local backup_count
    backup_count=$(find "$BACKUP_ROOT" -maxdepth 1 -name "Docker-Compose-Backup-*.tar.gz" -type f 2>/dev/null | wc -l)

    if [[ $backup_count -gt $RETENTION_COUNT ]]; then
        find "$BACKUP_ROOT" -maxdepth 1 -name "Docker-Compose-Backup-*.tar.gz" -type f -printf '%T@ %p\n' \
            | sort -n \
            | head -n "$(( backup_count - RETENTION_COUNT ))" \
            | awk '{print $2}' \
            | xargs -r rm -f

        log_info "Removed old backups, keeping $RETENTION_COUNT most recent"
    else
        log_info "No old backups to remove ($backup_count <= $RETENTION_COUNT)"
    fi

    # Report
    local backup_size
    backup_size=$(du -h "$BACKUP_ROOT/$BACKUP_FILE" 2>/dev/null | cut -f1)
    log_success "Docker backup completed successfully"
    log_info "Final archive size: $backup_size"
    log_info "Location: $BACKUP_ROOT/$BACKUP_FILE"

    return 0
}

# =============================================================================
# SCRIPT EXECUTION (standalone mode)
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main() {
        local start_time
        start_time=$(date +%s)

        log_info "Docker Services Backup Started"
        log_info "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"

        if perform_docker_backup; then
            local end_time duration
            end_time=$(date +%s)
            duration=$(( end_time - start_time ))
            log_confirmation "Backup operation completed in ${duration} seconds"
            exit 0
        else
            log_error "Backup operation failed"
            exit 1
        fi
    }

    main "$@"
fi
