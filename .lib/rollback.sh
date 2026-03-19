#!/bin/bash
# =============================================================================
# Rollback System v1.0
# Pre-operation snapshots and restore capability for Docker Compose stacks
# Snapshots compose files, .env, and image SHA digests before operations
#
# Dependencies: docker, jq (optional, graceful fallback)
# Requires: Bash 4+
# =============================================================================

if [[ -z "${BASE_DIR:-}" ]]; then
    BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

COMPOSE_DIR="${COMPOSE_DIR:-$BASE_DIR/Stacks}"
ROLLBACK_DIR="${BASE_DIR}/.data/rollback"
ROLLBACK_MAX_SNAPSHOTS="${ROLLBACK_MAX_SNAPSHOTS:-10}"

# =============================================================================
# INITIALIZATION
# =============================================================================

rollback_init() {
    mkdir -p "$ROLLBACK_DIR" 2>/dev/null
}

# =============================================================================
# SNAPSHOT CREATION
# =============================================================================

# Create a pre-operation snapshot for a stack
# Usage: rollback_create_snapshot stack_name operation
# Returns: snapshot ID (timestamp) on stdout
rollback_create_snapshot() {
    local stack_name="$1"
    local operation="${2:-unknown}"
    local stack_dir="$COMPOSE_DIR/$stack_name"
    local snapshot_id
    snapshot_id="$(date '+%Y%m%d-%H%M%S')"
    local snap_dir="$ROLLBACK_DIR/$stack_name/$snapshot_id"

    rollback_init
    mkdir -p "$snap_dir"

    # Copy compose file
    if [[ -f "$stack_dir/docker-compose.yml" ]]; then
        cp "$stack_dir/docker-compose.yml" "$snap_dir/docker-compose.yml"
    fi

    # Copy .env if exists
    if [[ -f "$stack_dir/.env" ]]; then
        cp "$stack_dir/.env" "$snap_dir/.env"
    fi

    # Capture current image digests
    local images_json="[]"
    if [[ -f "$stack_dir/docker-compose.yml" ]]; then
        local images_arr="["
        local first=true
        while IFS= read -r line; do
            local img_name img_digest
            img_name=$(echo "$line" | awk '{print $2}')
            img_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "$img_name" 2>/dev/null || echo "")
            if [[ "$first" == "true" ]]; then
                first=false
            else
                images_arr+=","
            fi
            images_arr+="{\"name\":\"$img_name\",\"digest\":\"${img_digest:-unknown}\"}"
        done < <(cd "$stack_dir" && ${DOCKER_COMPOSE_CMD:-docker compose} images 2>/dev/null | tail -n +2)
        images_arr+="]"
        images_json="$images_arr"
    fi
    echo "$images_json" > "$snap_dir/images.json"

    # Write metadata
    local status="unknown"
    if cd "$stack_dir" 2>/dev/null && ${DOCKER_COMPOSE_CMD:-docker compose} ps --quiet 2>/dev/null | head -1 | grep -q .; then
        status="running"
    else
        status="stopped"
    fi

    cat > "$snap_dir/metadata.json" <<METAEOF
{"snapshot_id":"$snapshot_id","timestamp":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')","operation":"$operation","user":"$(whoami)","stack_status":"$status","stack":"$stack_name"}
METAEOF

    echo "$snapshot_id"
}

# =============================================================================
# LISTING & DETAIL
# =============================================================================

# List all snapshots for a stack as JSON array
rollback_list_snapshots() {
    local stack_name="$1"
    local snap_base="$ROLLBACK_DIR/$stack_name"

    if [[ ! -d "$snap_base" ]]; then
        echo '[]'
        return 0
    fi

    local result="["
    local first=true
    local snap_id

    # Sort newest first
    while IFS= read -r snap_dir; do
        snap_id=$(basename "$snap_dir")
        local meta_file="$snap_dir/metadata.json"
        local timestamp="" operation="" images_count=0

        if [[ -f "$meta_file" ]]; then
            timestamp=$(grep -o '"timestamp":"[^"]*"' "$meta_file" | head -1 | cut -d'"' -f4)
            operation=$(grep -o '"operation":"[^"]*"' "$meta_file" | head -1 | cut -d'"' -f4)
        fi

        if [[ -f "$snap_dir/images.json" ]]; then
            images_count=$(grep -o '"name"' "$snap_dir/images.json" | wc -l)
        fi

        [[ "$first" == "true" ]] && first=false || result+=","
        result+="{\"id\":\"$snap_id\",\"timestamp\":\"${timestamp:-$snap_id}\",\"operation\":\"${operation:-unknown}\",\"images_count\":$images_count}"
    done < <(ls -1dr "$snap_base"/*/ 2>/dev/null)

    result+="]"
    echo "$result"
}

# Get full details of a specific snapshot
rollback_get_snapshot() {
    local stack_name="$1"
    local snapshot_id="$2"
    local snap_dir="$ROLLBACK_DIR/$stack_name/$snapshot_id"

    if [[ ! -d "$snap_dir" ]]; then
        echo '{"error":"Snapshot not found"}'
        return 1
    fi

    local compose_content="" env_content="" images_content="[]" meta_content="{}"

    [[ -f "$snap_dir/docker-compose.yml" ]] && compose_content=$(cat "$snap_dir/docker-compose.yml")
    [[ -f "$snap_dir/.env" ]] && env_content=$(cat "$snap_dir/.env")
    [[ -f "$snap_dir/images.json" ]] && images_content=$(cat "$snap_dir/images.json")
    [[ -f "$snap_dir/metadata.json" ]] && meta_content=$(cat "$snap_dir/metadata.json")

    # Escape for JSON embedding
    local esc_compose esc_env
    esc_compose=$(printf '%s' "$compose_content" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | tr '\n' '\n' | sed ':a;N;$!ba;s/\n/\\n/g')
    esc_env=$(printf '%s' "$env_content" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | tr '\n' '\n' | sed ':a;N;$!ba;s/\n/\\n/g')

    printf '{"id":"%s","stack":"%s","compose_file":"%s","env_file":%s,"images":%s,"metadata":%s}' \
        "$snapshot_id" "$stack_name" \
        "$esc_compose" \
        "$(if [[ -n "$env_content" ]]; then echo "\"$esc_env\""; else echo "null"; fi)" \
        "$images_content" \
        "$meta_content"
}

# =============================================================================
# RESTORE
# =============================================================================

# Restore a stack from a snapshot
# Usage: rollback_restore stack_name snapshot_id
rollback_restore() {
    local stack_name="$1"
    local snapshot_id="$2"
    local snap_dir="$ROLLBACK_DIR/$stack_name/$snapshot_id"
    local stack_dir="$COMPOSE_DIR/$stack_name"

    if [[ ! -d "$snap_dir" ]]; then
        echo '{"success":false,"error":"Snapshot not found"}'
        return 1
    fi

    local output=""
    local success=true

    # Stop the stack
    output+="Stopping stack $stack_name... "
    if cd "$stack_dir" 2>/dev/null; then
        ${DOCKER_COMPOSE_CMD:-docker compose} down 2>&1 || true
        output+="done. "
    fi

    # Restore compose file
    if [[ -f "$snap_dir/docker-compose.yml" ]]; then
        cp "$snap_dir/docker-compose.yml" "$stack_dir/docker-compose.yml"
        output+="Restored docker-compose.yml. "
    fi

    # Restore .env
    if [[ -f "$snap_dir/.env" ]]; then
        cp "$snap_dir/.env" "$stack_dir/.env"
        output+="Restored .env. "
    fi

    # Pull exact image digests if available
    if [[ -f "$snap_dir/images.json" ]]; then
        while IFS= read -r digest; do
            if [[ -n "$digest" && "$digest" != "unknown" && "$digest" != "null" ]]; then
                docker pull "$digest" 2>&1 || true
            fi
        done < <(grep -o '"digest":"[^"]*"' "$snap_dir/images.json" | cut -d'"' -f4)
        output+="Pulled snapshot images. "
    fi

    # Start the stack
    output+="Starting stack $stack_name... "
    if cd "$stack_dir" 2>/dev/null; then
        if ${DOCKER_COMPOSE_CMD:-docker compose} up -d 2>&1; then
            output+="done."
        else
            output+="FAILED."
            success=false
        fi
    else
        output+="FAILED (directory not found)."
        success=false
    fi

    local esc_output
    esc_output=$(printf '%s' "$output" | sed 's/"/\\"/g')
    printf '{"success":%s,"stack":"%s","snapshot_id":"%s","output":"%s"}' \
        "$success" "$stack_name" "$snapshot_id" "$esc_output"
}

# =============================================================================
# DIFF
# =============================================================================

# Show diff between current state and a snapshot
rollback_diff() {
    local stack_name="$1"
    local snapshot_id="$2"
    local snap_dir="$ROLLBACK_DIR/$stack_name/$snapshot_id"
    local stack_dir="$COMPOSE_DIR/$stack_name"

    local compose_diff="" env_diff="" image_changes="[]"

    # Compose diff
    if [[ -f "$snap_dir/docker-compose.yml" && -f "$stack_dir/docker-compose.yml" ]]; then
        compose_diff=$(diff -u "$snap_dir/docker-compose.yml" "$stack_dir/docker-compose.yml" 2>/dev/null || true)
    fi

    # Env diff
    if [[ -f "$snap_dir/.env" && -f "$stack_dir/.env" ]]; then
        env_diff=$(diff -u "$snap_dir/.env" "$stack_dir/.env" 2>/dev/null || true)
    fi

    # Escape diffs for JSON
    local esc_compose esc_env
    esc_compose=$(printf '%s' "$compose_diff" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | tr '\n' '\n' | sed ':a;N;$!ba;s/\n/\\n/g')
    esc_env=$(printf '%s' "$env_diff" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | tr '\n' '\n' | sed ':a;N;$!ba;s/\n/\\n/g')

    printf '{"stack":"%s","snapshot_id":"%s","compose_diff":"%s","env_diff":"%s","image_changes":%s}' \
        "$stack_name" "$snapshot_id" "$esc_compose" "$esc_env" "$image_changes"
}

# =============================================================================
# CLEANUP
# =============================================================================

# Remove snapshots beyond max count (keep newest)
# Usage: rollback_cleanup [stack_name]  (empty = all stacks)
rollback_cleanup() {
    local stack_name="${1:-}"
    local stacks=()

    if [[ -n "$stack_name" ]]; then
        stacks=("$stack_name")
    else
        while IFS= read -r dir; do
            stacks+=("$(basename "$dir")")
        done < <(ls -1d "$ROLLBACK_DIR"/*/ 2>/dev/null)
    fi

    for stack in "${stacks[@]}"; do
        local snap_base="$ROLLBACK_DIR/$stack"
        local count=0
        while IFS= read -r snap_dir; do
            count=$((count + 1))
            if [[ "$count" -gt "$ROLLBACK_MAX_SNAPSHOTS" ]]; then
                rm -rf "$snap_dir"
            fi
        done < <(ls -1dr "$snap_base"/*/ 2>/dev/null)
    done
}

# Wrapper: create snapshot + cleanup in one call
rollback_auto_snapshot() {
    local stack_name="$1"
    local operation="${2:-unknown}"

    if [[ "${ROLLBACK_ENABLED:-true}" != "true" ]]; then
        return 0
    fi

    local snap_id
    snap_id=$(rollback_create_snapshot "$stack_name" "$operation")
    rollback_cleanup "$stack_name"
    echo "$snap_id"
}
