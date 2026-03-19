#!/bin/bash
# =============================================================================
# Docker Compose Skeleton — Image Update Tracker v2.0
# Compares local Docker image digests against remote registry digests to
# detect available updates. Supports pull mode, full JSON output, and
# per-image staleness detection.
#
# Usage:
#   ./image-tracker.sh [--stack <name>] [--pull] [--json] [--quick]
#
# Options:
#   --stack <name>    Only check images for a specific stack
#   --pull            Pull images and compare (detect real updates)
#   --json            Output results as JSON
#   --quick           Only show images with available updates or stale
#
# This script inspects each running container's image digest and compares
# it to the latest remote digest to identify stale images.
# =============================================================================

# =============================================================================
# PATH AUTO-DETECTION
# =============================================================================

if [[ -z "${BASE_DIR:-}" ]]; then
    _IT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    BASE_DIR="$(cd "$_IT_SCRIPT_DIR/.." && pwd)"
    unset _IT_SCRIPT_DIR
fi

if [[ -f "$BASE_DIR/.env" ]]; then
    set -a
    source "$BASE_DIR/.env"
    set +a
fi

COMPOSE_DIR="${COMPOSE_DIR:-$BASE_DIR/Stacks}"

# =============================================================================
# COLOR SETUP
# =============================================================================

if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]] && command -v tput >/dev/null 2>&1; then
    _IT_RESET="$(tput sgr0)"
    _IT_BOLD="$(tput bold)"
    _IT_DIM="$(tput dim)"
    _IT_GREEN="$(tput setaf 82)"
    _IT_YELLOW="$(tput setaf 214)"
    _IT_RED="$(tput setaf 196)"
    _IT_CYAN="$(tput setaf 51)"
    _IT_BLUE="$(tput setaf 33)"
    _IT_GRAY="$(tput setaf 245)"
    _IT_MAGENTA="$(tput setaf 141)"
    _IT_WHITE="$(tput setaf 15)"
else
    _IT_RESET="" _IT_BOLD="" _IT_DIM=""
    _IT_GREEN="" _IT_YELLOW="" _IT_RED="" _IT_CYAN=""
    _IT_BLUE="" _IT_GRAY="" _IT_MAGENTA="" _IT_WHITE=""
fi

# =============================================================================
# ARGUMENTS
# =============================================================================

STACK_FILTER=""
AUTO_PULL=false
JSON_OUTPUT=false
QUICK_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stack)  STACK_FILTER="$2"; shift 2 ;;
        --pull)   AUTO_PULL=true; shift ;;
        --json)   JSON_OUTPUT=true; shift ;;
        --quick)  QUICK_MODE=true; shift ;;
        --help|-h)
            cat <<EOF
Image Update Tracker v2.0 — Check for Docker image updates

Usage: $0 [--stack <name>] [--pull] [--json] [--quick]

Options:
  --stack <name>    Check only a specific stack's images
  --pull            Pull images and compare IDs (detect real updates)
  --json            Output as JSON (complete with all fields)
  --quick           Only show images needing updates or stale (>30 days)
EOF
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# =============================================================================
# DOCKER COMPOSE DETECTION
# =============================================================================

if [[ -z "${DOCKER_COMPOSE_CMD:-}" ]]; then
    if docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker-compose"
    else
        echo "Error: No Docker Compose found" >&2
        exit 1
    fi
fi

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

_it_repeat() {
    local char="$1" count="$2"
    (( count <= 0 )) && return
    printf "%0.s${char}" $(seq 1 "$count")
}

_it_header() {
    local title="$1"
    local width=65
    local heavy_border
    heavy_border="$(_it_repeat "═" "$width")"

    echo ""
    echo "  ${_IT_BLUE}╔${heavy_border}╗${_IT_RESET}"
    local pad=$(( (width - ${#title}) / 2 ))
    printf "  ${_IT_BLUE}║%*s${_IT_BOLD}${_IT_CYAN}%s${_IT_RESET}${_IT_BLUE}%*s║${_IT_RESET}\n" "$pad" "" "$title" $(( width - pad - ${#title} )) ""
    echo "  ${_IT_BLUE}╚${heavy_border}╝${_IT_RESET}"
    echo ""
}

# Safe division: uses bc if available, falls back to awk
_it_div() {
    local num="$1" den="$2" scale="${3:-1}"
    if command -v bc >/dev/null 2>&1; then
        echo "scale=$scale; $num/$den" | bc
    else
        awk "BEGIN {printf \"%.${scale}f\", $num/$den}"
    fi
}

# Format bytes to human-readable (with bc fallback)
_it_format_size() {
    local size="$1"
    if [[ -z "$size" ]] || ! [[ "$size" =~ ^[0-9]+$ ]]; then
        echo "--"
        return
    fi

    if [[ "$size" -ge 1073741824 ]]; then
        echo "$(_it_div "$size" 1073741824)G"
    elif [[ "$size" -ge 1048576 ]]; then
        echo "$(_it_div "$size" 1048576)M"
    elif [[ "$size" -ge 1024 ]]; then
        echo "$(_it_div "$size" 1024)K"
    else
        echo "${size}B"
    fi
}

# Check a single image for updates by pulling and comparing IDs.
# Returns: "updated", "up-to-date", "missing"
_it_check_image() {
    local image="$1"

    # Get local image ID
    local local_id
    local_id="$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null)"

    if [[ -z "$local_id" ]]; then
        echo "missing"
        return
    fi

    # Pull the latest version
    docker pull "$image" --quiet >/dev/null 2>&1

    # Get the new image ID
    local new_id
    new_id="$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null)"

    if [[ "$local_id" != "$new_id" ]]; then
        echo "updated"
    else
        echo "up-to-date"
    fi
}

# =============================================================================
# SCAN STACKS (TABLE OUTPUT)
# =============================================================================

scan_images() {
    _it_header "Docker Image Update Tracker"

    local -a stacks=()

    if [[ -n "$STACK_FILTER" ]]; then
        stacks=("$STACK_FILTER")
    else
        for dir in "$COMPOSE_DIR"/*/; do
            [[ -f "${dir}docker-compose.yml" ]] && stacks+=("$(basename "$dir")")
        done
    fi

    if [[ ${#stacks[@]} -eq 0 ]]; then
        echo "  ${_IT_YELLOW}No stacks found${_IT_RESET}"
        return
    fi

    local total_images=0
    local outdated_images=0
    local current_images=0
    local unknown_images=0
    local updated_images=0

    declare -a all_results=()

    for stack in "${stacks[@]}"; do
        local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
        [[ ! -f "$compose_file" ]] && continue

        local env_file="$COMPOSE_DIR/$stack/.env"

        # Get running containers for this stack
        local -a compose_args=(-f "$compose_file")
        [[ -f "$env_file" ]] && compose_args+=(--env-file "$env_file")

        local containers
        containers="$($DOCKER_COMPOSE_CMD "${compose_args[@]}" ps -q 2>/dev/null)"
        [[ -z "$containers" ]] && continue

        echo "  ${_IT_BOLD}${_IT_BLUE}$stack${_IT_RESET}"

        while IFS= read -r container_id; do
            [[ -z "$container_id" ]] && continue

            local container_name
            container_name="$(docker inspect "$container_id" --format '{{.Name}}' 2>/dev/null | sed 's|^/||')"

            local image_name
            image_name="$(docker inspect "$container_id" --format '{{.Config.Image}}' 2>/dev/null)"

            # Image ID baked into the running container
            local container_image_id
            container_image_id="$(docker inspect "$container_id" --format '{{.Image}}' 2>/dev/null)"
            local image_id_short="${container_image_id:7:12}"

            local image_created
            image_created="$(docker image inspect "$image_name" --format '{{.Created}}' 2>/dev/null | cut -dT -f1)"

            local image_size_raw
            image_size_raw="$(docker image inspect "$image_name" --format '{{.Size}}' 2>/dev/null)"
            local image_size
            image_size="$(_it_format_size "$image_size_raw")"

            (( total_images++ ))

            # ── Pull mode: detect real updates ────────────────────────
            local update_status=""
            if [[ "$AUTO_PULL" == "true" ]]; then
                update_status="$(_it_check_image "$image_name")"

                if [[ "$update_status" == "updated" ]]; then
                    (( updated_images++ ))
                fi
            fi

            # Determine freshness based on image creation date
            local status_icon status_color staleness="unknown" age_info="--"
            if [[ -n "$image_created" ]] && [[ "$image_created" != "--" ]]; then
                local image_epoch
                image_epoch="$(date -d "$image_created" '+%s' 2>/dev/null || echo 0)"
                local now_epoch
                now_epoch="$(date '+%s')"
                local age_days=$(( (now_epoch - image_epoch) / 86400 ))

                age_info="${age_days}d ago"

                if [[ "$update_status" == "updated" ]]; then
                    status_icon="${_IT_MAGENTA}UPDATED${_IT_RESET}"
                    status_color="$_IT_MAGENTA"
                    staleness="updated"
                elif [[ "$age_days" -lt 7 ]]; then
                    status_icon="${_IT_GREEN}CURRENT${_IT_RESET}"
                    status_color="$_IT_GREEN"
                    staleness="current"
                    (( current_images++ ))
                elif [[ "$age_days" -lt 30 ]]; then
                    status_icon="${_IT_YELLOW}AGING  ${_IT_RESET}"
                    status_color="$_IT_YELLOW"
                    staleness="aging"
                    (( current_images++ ))
                else
                    status_icon="${_IT_RED}STALE  ${_IT_RESET}"
                    status_color="$_IT_RED"
                    staleness="stale"
                    (( outdated_images++ ))
                fi
            else
                status_icon="${_IT_GRAY}UNKNOWN${_IT_RESET}"
                status_color="$_IT_GRAY"
                (( unknown_images++ ))
            fi

            if [[ "$QUICK_MODE" == "true" ]] && [[ "$staleness" == "current" ]]; then
                continue
            fi

            printf "    %s  ${_IT_DIM}%-30s${_IT_RESET} %-25s ${_IT_DIM}%-8s %-10s${_IT_RESET}\n" \
                "$status_icon" "$container_name" "$image_name" "$image_size" "$age_info"

            all_results+=("$stack|$container_name|$image_name|$image_id_short|$image_size|$age_info")
        done <<< "$containers"

        echo ""
    done

    # Summary
    local sum_border
    sum_border="$(_it_repeat "─" 65)"
    echo "  ${_IT_BLUE}╔${sum_border}╗${_IT_RESET}"
    printf "  ${_IT_BLUE}║${_IT_RESET}  ${_IT_BOLD}${_IT_WHITE}SUMMARY${_IT_RESET}   "
    printf "${_IT_CYAN}Total: ${_IT_BOLD}%-4s${_IT_RESET}  " "$total_images"
    printf "${_IT_GREEN}Current: ${_IT_BOLD}%-4s${_IT_RESET}  " "$current_images"
    printf "${_IT_RED}Stale: ${_IT_BOLD}%-4s${_IT_RESET}  " "$outdated_images"
    printf "${_IT_GRAY}Unknown: ${_IT_BOLD}%-4s${_IT_RESET}"  "$unknown_images"
    printf "  ${_IT_BLUE}║${_IT_RESET}\n"

    if [[ "$AUTO_PULL" == "true" ]] && [[ $updated_images -gt 0 ]]; then
        printf "  ${_IT_BLUE}║${_IT_RESET}  ${_IT_MAGENTA}Updated: ${_IT_BOLD}%-4s${_IT_RESET} ${_IT_DIM}(images pulled with new versions)${_IT_RESET}"  "$updated_images"
        printf "%*s${_IT_BLUE}║${_IT_RESET}\n" $(( 65 - 51 )) ""
    fi
    echo "  ${_IT_BLUE}╚${sum_border}╝${_IT_RESET}"
    echo ""

    if [[ "$outdated_images" -gt 0 ]]; then
        echo "  ${_IT_YELLOW}$outdated_images image(s) are over 30 days old — consider running updates${_IT_RESET}"
        echo "  ${_IT_DIM}Tip: Use ./start.sh to pull latest images during startup${_IT_RESET}"
        echo "  ${_IT_DIM}     Use $0 --pull to pull and detect real updates${_IT_RESET}"
        echo ""
    fi
}

# =============================================================================
# JSON OUTPUT (complete with all fields)
# =============================================================================

scan_images_json() {
    local -a json_entries=()

    for dir in "$COMPOSE_DIR"/*/; do
        [[ ! -f "${dir}docker-compose.yml" ]] && continue
        local stack
        stack="$(basename "$dir")"

        if [[ -n "$STACK_FILTER" ]] && [[ "$stack" != "$STACK_FILTER" ]]; then
            continue
        fi

        local compose_file="${dir}docker-compose.yml"
        local env_file="${dir}.env"

        local -a compose_args=(-f "$compose_file")
        [[ -f "$env_file" ]] && compose_args+=(--env-file "$env_file")

        local containers
        containers="$($DOCKER_COMPOSE_CMD "${compose_args[@]}" ps -q 2>/dev/null)"
        [[ -z "$containers" ]] && continue

        while IFS= read -r cid; do
            [[ -z "$cid" ]] && continue

            local cname image container_image_id image_created_raw image_size_raw
            cname="$(docker inspect "$cid" --format '{{.Name}}' 2>/dev/null | sed 's|^/||')"
            image="$(docker inspect "$cid" --format '{{.Config.Image}}' 2>/dev/null)"
            container_image_id="$(docker inspect "$cid" --format '{{.Image}}' 2>/dev/null)"
            image_created_raw="$(docker image inspect "$image" --format '{{.Created}}' 2>/dev/null)"
            image_size_raw="$(docker image inspect "$image" --format '{{.Size}}' 2>/dev/null)"

            local age_days=-1
            local staleness="unknown"
            local image_date="${image_created_raw%%T*}"

            if [[ -n "$image_created_raw" ]]; then
                local img_epoch
                img_epoch="$(date -d "$image_date" '+%s' 2>/dev/null || echo 0)"
                if [[ "$img_epoch" -gt 0 ]]; then
                    local now_epoch
                    now_epoch="$(date '+%s')"
                    age_days=$(( (now_epoch - img_epoch) / 86400 ))

                    if [[ $age_days -lt 7 ]]; then
                        staleness="current"
                    elif [[ $age_days -lt 30 ]]; then
                        staleness="aging"
                    else
                        staleness="stale"
                    fi
                fi
            fi

            local update_status="unknown"
            if [[ "$AUTO_PULL" == "true" ]]; then
                update_status="$(_it_check_image "$image")"
            fi

            local id_short="${container_image_id:7:12}"

            json_entries+=("{\"stack\": \"$stack\", \"container\": \"$cname\", \"image\": \"$image\", \"image_id\": \"$id_short\", \"size\": ${image_size_raw:-0}, \"size_human\": \"$(_it_format_size "$image_size_raw")\", \"created\": \"$image_date\", \"age_days\": $age_days, \"staleness\": \"$staleness\", \"update_status\": \"$update_status\"}")
        done <<< "$containers"
    done

    echo "{"
    echo "  \"timestamp\": \"$(date -Iseconds)\","
    echo "  \"hostname\": \"$(hostname)\","
    echo "  \"total_images\": ${#json_entries[@]},"
    echo "  \"images\": ["

    local i=0
    for entry in "${json_entries[@]}"; do
        (( i++ ))
        if [[ $i -lt ${#json_entries[@]} ]]; then
            echo "    ${entry},"
        else
            echo "    ${entry}"
        fi
    done

    echo "  ]"
    echo "}"
}

# =============================================================================
# MAIN
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        scan_images_json
    else
        scan_images
    fi
fi
