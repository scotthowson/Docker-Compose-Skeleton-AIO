#!/bin/bash
# =============================================================================
# Docker Services Cleanup Library
# Identifies and removes orphaned App-Data directories that are no longer
# referenced in any docker-compose.yml volume mount.
#
# This file is SOURCED by start.sh -- do not execute directly.
#
# Expected environment (set by caller):
#   $BASE_DIR        -- repository root
#   $COMPOSE_DIR     -- path to Stacks/ directory
#   $APP_DATA_DIR    -- (optional) overrides default App-Data location
#
# Logger functions (log_info, log_error, etc.) must be available.
# =============================================================================

# =============================================================================
# MAIN CLEANUP FUNCTION
# =============================================================================

# Scan App-Data for directories that are not referenced in any
# docker-compose.yml file and offer to delete them.
cleanup_docker_services() {
    local app_data_dir="${APP_DATA_DIR:-$BASE_DIR/App-Data}"
    local stacks_dir="${COMPOSE_DIR:-$BASE_DIR/Stacks}"

    # Validate directories
    if [[ ! -d "$app_data_dir" ]]; then
        log_bold_nodate_warning "App-Data directory not found: $app_data_dir -- skipping cleanup"
        return 0
    fi

    if [[ ! -d "$stacks_dir" ]]; then
        log_bold_nodate_warning "Stacks directory not found: $stacks_dir -- skipping cleanup"
        return 0
    fi

    log_bold_nodate_info "Base directory set to: $app_data_dir"

    # Collect all top-level volume directory names
    local volume_dirs
    volume_dirs=$(find "$app_data_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null)

    if [[ -z "$volume_dirs" ]]; then
        log_bold_nodate_success "No volume directories found in $app_data_dir. Nothing to check."
        return 0
    fi

    # Create a secure temporary file for collecting referenced volumes
    local tmp_volumes
    tmp_volumes=$(mktemp) || {
        log_bold_nodate_error "Failed to create temporary file"
        return 1
    }

    # Scan all docker-compose.yml files for references to App-Data subdirectories
    log_bold_nodate_highlight "Scanning Docker Compose files at: $stacks_dir"

    while IFS= read -r compose_file; do
        log_bold_nodate_focus "Reading file: $compose_file"

        # Use envsubst to resolve ${APP_DATA_DIR} / ${BASE_DIR} and extract
        # the final path component of any reference into the data directory.
        APP_DATA_DIR="$app_data_dir" BASE_DIR="$BASE_DIR" envsubst < "$compose_file" \
            | grep -o "${app_data_dir}/[^:/]*" \
            | awk -F'/' '{print $NF}' \
            >> "$tmp_volumes"
    done < <(find "$stacks_dir" -name "docker-compose.yml" 2>/dev/null)

    # Deduplicate referenced volumes
    local used_volumes
    used_volumes=$(sort -u "$tmp_volumes")
    rm -f "$tmp_volumes"

    # Compare on-disk directories against referenced volumes
    log_bold_nodate_info "Checking for unreferenced directories..."

    local to_be_deleted=()
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        if ! grep -qx "$dir" <<< "$used_volumes"; then
            to_be_deleted+=("$dir")
        fi
    done <<< "$volume_dirs"

    if [[ ${#to_be_deleted[@]} -eq 0 ]]; then
        log_bold_nodate_success "No unused directories found. Nothing to delete."
    else
        log_bold_nodate_warning "The following directories are not referenced in any docker-compose.yml and can be deleted:"
        for dir in "${to_be_deleted[@]}"; do
            log_bold_nodate_caution "$app_data_dir/$dir"
        done

        if confirm_deletion "[WARNING] Are you sure you want to delete these directories?"; then
            for dir in "${to_be_deleted[@]}"; do
                sudo rm -rf "$app_data_dir/$dir"
                log_bold_nodate_success "Deleted $app_data_dir/$dir"
            done
        else
            log_bold_nodate_error "Deletion aborted by user or timeout reached."
        fi
    fi

    log_bold_nodate_status "Verification complete."
}
