#!/bin/bash
# =============================================================================
# Docker Stack Updater — Intelligent Stack Update System v2.0
# Pulls latest images in parallel, compares SHA256 digests to detect real
# changes, applies rolling updates only when needed, supports rollback on
# failure, sends NTFY notifications, and cleans up old images.
#
# This file is SOURCED by start.sh — do not execute directly.
#
# Expected environment (set by caller):
#   $COMPOSE_DIR         — path to Stacks/ directory
#   $DOCKER_COMPOSE_CMD  — "docker compose" or "docker-compose"
#   $NTFY_URL            — (optional) NTFY push endpoint
#   $SERVER_NAME         — (optional) friendly name
#
# Logger functions (log_info, log_error, etc.) must be available.
# =============================================================================

# =============================================================================
# INTERNAL HELPERS
# =============================================================================

# Convert a human-readable size string (e.g., "1.5GB", "200MB") to bytes.
_uas_size_to_bytes() {
    local size_str="$1"
    local num unit

    if [[ "$size_str" =~ ^([0-9]+\.?[0-9]*)([KMGT]?)B?$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
    else
        echo 0
        return
    fi

    case "$unit" in
        K) awk "BEGIN {printf \"%d\", $num * 1024}" ;;
        M) awk "BEGIN {printf \"%d\", $num * 1048576}" ;;
        G) awk "BEGIN {printf \"%d\", $num * 1073741824}" ;;
        T) awk "BEGIN {printf \"%d\", $num * 1099511627776}" ;;
        *) awk "BEGIN {printf \"%d\", $num}" ;;
    esac
}

# Convert bytes to a human-readable string.
_uas_bytes_to_human() {
    local bytes="${1:-0}"

    if (( bytes >= 1073741824 )); then
        awk "BEGIN {printf \"%.1fGB\", $bytes / 1073741824}"
    elif (( bytes >= 1048576 )); then
        awk "BEGIN {printf \"%.1fMB\", $bytes / 1048576}"
    elif (( bytes >= 1024 )); then
        awk "BEGIN {printf \"%.1fKB\", $bytes / 1024}"
    else
        echo "${bytes}B"
    fi
}

# =============================================================================
# MAIN UPDATE FUNCTION
# =============================================================================

update_all_stacks() {
    log_focus "Starting intelligent Docker stack updates"

    local updated_stacks=0
    local skipped_stacks=0
    local failed_stacks=0
    local rolled_back=0
    local stacks_dir="$COMPOSE_DIR"

    # Collect per-image change details for notification (temp file for subshell access)
    local change_log_file
    change_log_file="$(mktemp /tmp/change_log.XXXXXX)"

    # =========================================================================
    # PHASE 1: PARALLEL IMAGE PULLING
    # =========================================================================

    log_info_header "Phase 1: Pulling latest images for all stacks"

    local pull_pids=()
    local found_stacks=0
    local pull_results
    pull_results="$(mktemp /tmp/pull_results.XXXXXX)"

    trap 'rm -f "$change_log_file" "$pull_results"' EXIT

    for dir in "$stacks_dir"/*/; do
        [[ -f "$dir/docker-compose.yml" ]] || continue

        local stack_name
        stack_name=$(basename "$dir")
        (( found_stacks++ ))

        # Each subshell writes to its own temp file to avoid race conditions
        (
            local my_result
            my_result="$(mktemp /tmp/pull_result_${stack_name}.XXXXXX)"
            cd "$dir" || exit 1

            if $DOCKER_COMPOSE_CMD pull --quiet 2>/dev/null; then
                echo "SUCCESS:$stack_name" > "$my_result"
            else
                echo "FAILED:$stack_name" > "$my_result"
            fi
            cat "$my_result" >> "$pull_results"
            rm -f "$my_result"
        ) &
        pull_pids+=($!)
    done

    if [[ $found_stacks -eq 0 ]]; then
        log_warning "No valid Docker stacks found"
        rm -f "$pull_results"
        return 0
    fi

    log_status "Pulling images for $found_stacks stacks in parallel"

    # Wait for all pulls to complete
    for pid in "${pull_pids[@]}"; do
        wait "$pid"
    done

    # Report pull results
    local pull_failures=0
    while IFS=':' read -r status stack_name; do
        [[ -z "$status" ]] && continue
        case "$status" in
            SUCCESS) log_success "$stack_name — Images pulled successfully" ;;
            FAILED)
                log_error "$stack_name — Failed to pull images"
                (( pull_failures++ ))
                ;;
        esac
    done < "$pull_results"
    rm -f "$pull_results"

    if [[ $pull_failures -gt 0 ]]; then
        log_caution "$pull_failures stacks failed to pull images, continuing with available images"
    else
        log_confirmation "All images pulled successfully"
    fi

    # =========================================================================
    # PHASE 2: INTELLIGENT UPDATE DETECTION & APPLICATION
    # =========================================================================

    log_info_header "Phase 2: Analyzing image changes and applying updates"

    local temp_results
    temp_results="$(mktemp /tmp/stack_update_results.XXXXXX)"

    for dir in "$stacks_dir"/*/; do
        [[ -f "$dir/docker-compose.yml" ]] || continue

        local stack_name
        stack_name=$(basename "$dir")

        (
            cd "$dir" || exit 1

            # Count running containers for this stack
            local running_containers
            running_containers=$($DOCKER_COMPOSE_CMD ps --format "{{.Name}}" 2>/dev/null | wc -l)

            if [[ $running_containers -eq 0 ]]; then
                log_info "$stack_name — No running containers, images ready for next startup"
                echo "SKIPPED" >> "$temp_results"
                exit 0
            fi

            # ── Correct SHA256 detection ──────────────────────────────
            # For each service image defined in the compose file:
            #   1. Get the image ID that the running container was started with
            #   2. Get the image ID of the freshly-pulled tag
            #   3. Compare — they differ when a new image was pulled

            local images_changed=false
            local -a pre_update_digests=()

            while IFS= read -r img_name; do
                [[ -z "$img_name" ]] && continue

                # Image ID baked into running containers (what they were started with)
                local container_image_id=""
                local container_name
                container_name=$($DOCKER_COMPOSE_CMD ps --format "{{.Name}}" 2>/dev/null | head -1)

                # Get image ID from containers using this image
                while IFS= read -r cname; do
                    [[ -z "$cname" ]] && continue
                    local cimg
                    cimg=$(docker inspect --format='{{.Config.Image}}' "$cname" 2>/dev/null)
                    if [[ "$cimg" == "$img_name" ]]; then
                        container_image_id=$(docker inspect --format='{{.Image}}' "$cname" 2>/dev/null)
                        break
                    fi
                done < <($DOCKER_COMPOSE_CMD ps --format "{{.Name}}" 2>/dev/null)

                # Image ID of the freshly-pulled tag (what docker would use for new containers)
                local pulled_image_id
                pulled_image_id=$(docker image inspect --format='{{.Id}}' "$img_name" 2>/dev/null)

                # Record pre-update digest for rollback
                if [[ -n "$container_image_id" ]]; then
                    pre_update_digests+=("$img_name=$container_image_id")
                fi

                if [[ -n "$container_image_id" ]] && [[ -n "$pulled_image_id" ]]; then
                    if [[ "$container_image_id" != "$pulled_image_id" ]]; then
                        images_changed=true
                        local old_short="${container_image_id:7:12}"
                        local new_short="${pulled_image_id:7:12}"
                        log_info "$stack_name/$img_name — Changed: ${old_short} -> ${new_short}"
                        echo "$stack_name | $img_name | ${old_short} → ${new_short}" >> "$change_log_file"
                    fi
                elif [[ -z "$container_image_id" ]]; then
                    # Container not found for this image — might be a new service
                    images_changed=true
                fi
            done < <($DOCKER_COMPOSE_CMD config 2>/dev/null | grep 'image:' | awk '{print $2}' | sort -u)

            # ── Apply rolling update only when images have changed ────
            if [[ "$images_changed" == "true" ]]; then
                log_important "$stack_name — Applying rolling update to $running_containers containers"

                if $DOCKER_COMPOSE_CMD up -d --remove-orphans 2>/dev/null; then
                    log_success "$stack_name — Successfully updated with new images"
                    echo "UPDATED" >> "$temp_results"
                    sleep 1
                else
                    log_error "$stack_name — Update failed, attempting rollback"

                    # ── Rollback: restore previous image tags ─────────
                    local rollback_ok=true
                    for digest_pair in "${pre_update_digests[@]}"; do
                        local rb_image="${digest_pair%%=*}"
                        local rb_digest="${digest_pair#*=}"
                        # Re-tag the old image so compose picks it up
                        if ! docker tag "$rb_digest" "$rb_image" 2>/dev/null; then
                            rollback_ok=false
                        fi
                    done

                    if [[ "$rollback_ok" == "true" ]]; then
                        if $DOCKER_COMPOSE_CMD up -d --remove-orphans 2>/dev/null; then
                            log_warning "$stack_name — Rolled back to previous images"
                            echo "ROLLED_BACK" >> "$temp_results"
                        else
                            log_error "$stack_name — Rollback also failed"
                            echo "FAILED" >> "$temp_results"
                        fi
                    else
                        log_error "$stack_name — Could not restore previous images"
                        echo "FAILED" >> "$temp_results"
                    fi
                fi
            else
                log_success "$stack_name — Already running latest images ($running_containers containers)"
                echo "UP_TO_DATE" >> "$temp_results"
            fi
        )
    done

    # =========================================================================
    # RESULTS AGGREGATION
    # =========================================================================

    while IFS= read -r result; do
        case "$result" in
            UPDATED)     (( updated_stacks++ )) ;;
            UP_TO_DATE)  (( skipped_stacks++ )) ;;
            SKIPPED)     (( skipped_stacks++ )) ;;
            ROLLED_BACK) (( rolled_back++ ))     ;;
            FAILED)      (( failed_stacks++ ))   ;;
        esac
    done < "$temp_results"
    rm -f "$temp_results"

    # =========================================================================
    # PHASE 3: SYSTEM CLEANUP
    # =========================================================================

    log_info_header "Phase 3: Cleaning up unused Docker images"

    local total_freed_bytes=0

    # Remove dangling (untagged) images
    log_status "Removing dangling images"
    local dangling_output
    dangling_output=$(docker image prune -f 2>/dev/null)
    local dangling_freed
    dangling_freed=$(echo "$dangling_output" | grep -oE '[0-9]+(\.[0-9]+)?[KMGT]?B' | tail -1)
    if [[ -n "$dangling_freed" ]]; then
        total_freed_bytes=$(( total_freed_bytes + $(_uas_size_to_bytes "$dangling_freed") ))
    fi

    # Configurable: aggressive prune removes ALL unused images, conservative only prunes >24h
    local unused_output=""
    if [[ "${AGGRESSIVE_IMAGE_PRUNE:-false}" == "true" ]]; then
        log_status "Removing ALL unused images (aggressive mode)"
        unused_output=$(docker image prune -a -f 2>/dev/null)
    else
        log_status "Removing unused images older than 24 hours"
        unused_output=$(docker image prune -a -f --filter "until=24h" 2>/dev/null)
    fi
    local unused_freed
    unused_freed=$(echo "$unused_output" | grep -oE '[0-9]+(\.[0-9]+)?[KMGT]?B' | tail -1)
    if [[ -n "$unused_freed" ]]; then
        total_freed_bytes=$(( total_freed_bytes + $(_uas_size_to_bytes "$unused_freed") ))
    fi

    # Report space freed (properly summed)
    local total_cleanup
    total_cleanup="$(_uas_bytes_to_human "$total_freed_bytes")"

    if (( total_freed_bytes > 0 )); then
        log_success "Freed $total_cleanup of disk space"
    else
        log_info "No images cleaned up"
        log_debug "Dangling output: $dangling_output"
        log_debug "Unused output: $unused_output"
    fi

    # =========================================================================
    # PHASE 4: NTFY NOTIFICATION
    # =========================================================================

    if [[ "${UPDATE_NOTIFICATION:-true}" == "true" ]] && [[ -n "${NTFY_URL:-}" ]]; then
        if [[ $updated_stacks -gt 0 ]] || [[ $failed_stacks -gt 0 ]] || [[ $rolled_back -gt 0 ]]; then
            local server_name="${SERVER_NAME:-Docker Server}"
            local timestamp
            timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

            local change_details=""
            if [[ -s "$change_log_file" ]]; then
                change_details=$'\nImage Changes:\n'
                while IFS= read -r entry; do
                    change_details+="  $entry"$'\n'
                done < "$change_log_file"
            fi

            local priority="default"
            local tags="docker,update"
            local title="$server_name — Image Updates"

            if [[ $failed_stacks -gt 0 ]]; then
                priority="high"
                tags="warning,docker,update"
                title="$server_name — Update Issues"
            fi

            local message="Docker Image Update Report

Updated: $updated_stacks stacks
Up-to-date: $skipped_stacks stacks
Failed: $failed_stacks stacks
Rolled back: $rolled_back stacks
Space freed: $total_cleanup
${change_details}
Time: $timestamp"

            curl -s \
                -H "Title: $title" \
                -H "Priority: $priority" \
                -H "X-Tags: $tags" \
                -d "$message" \
                "$NTFY_URL" >/dev/null 2>&1

            log_debug "Update notification sent via NTFY"
        fi
    fi

    # =========================================================================
    # FINAL SUMMARY
    # =========================================================================

    log_confirmation "Docker stack update sequence completed"
    log_info_header "Update Summary Report"

    [[ $updated_stacks -gt 0 ]] && log_success "Stacks updated: $updated_stacks"
    [[ $skipped_stacks -gt 0 ]] && log_success "Stacks up-to-date: $skipped_stacks"
    [[ $rolled_back    -gt 0 ]] && log_warning "Stacks rolled back: $rolled_back"
    [[ $failed_stacks  -gt 0 ]] && log_error   "Failed updates: $failed_stacks"

    log_info "Space freed: $total_cleanup"

    if [[ -s "$change_log_file" ]]; then
        log_info "Image changes detected:"
        while IFS= read -r entry; do
            log_info "  $entry"
        done < "$change_log_file"
    fi

    rm -f "$change_log_file"
    return "$failed_stacks"
}
