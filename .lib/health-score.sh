#!/bin/bash
# =============================================================================
# Health Scoring System v1.0
# Computes 0-100 health scores for containers, stacks, and the whole system
# Factors: health status, uptime, restart count, resource usage, image freshness
#
# Dependencies: docker
# Requires: Bash 4+
# =============================================================================

if [[ -z "${BASE_DIR:-}" ]]; then
    BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

COMPOSE_DIR="${COMPOSE_DIR:-$BASE_DIR/Stacks}"

# =============================================================================
# UTILITIES
# =============================================================================

# Escape a string for safe JSON embedding
_hs_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g'
}

# Convert score to letter grade
_health_grade() {
    local score="${1:-0}"
    if (( score >= 90 )); then echo "A"
    elif (( score >= 75 )); then echo "B"
    elif (( score >= 60 )); then echo "C"
    elif (( score >= 40 )); then echo "D"
    else echo "F"
    fi
}

# =============================================================================
# CONTAINER SCORING
# =============================================================================

# Calculate 0-100 health score for a single container
# Usage: health_score_container container_name
health_score_container() {
    local container="$1"

    # Get container inspect data
    local inspect
    inspect=$(docker inspect "$container" 2>/dev/null) || {
        printf '{"container":"%s","score":0,"grade":"F","factors":{"health":0,"uptime":0,"restarts":0,"resources":0,"image_age":0}}' "$(_hs_json_escape "$container")"
        return
    }

    # --- Factor 1: Health status (30%) ---
    local health_status health_score=70
    health_status=$(echo "$inspect" | grep -o '"Health":{[^}]*"Status":"[^"]*"' | grep -o '"Status":"[^"]*"' | cut -d'"' -f4 | head -1)
    case "$health_status" in
        healthy)   health_score=100 ;;
        starting)  health_score=60 ;;
        unhealthy) health_score=10 ;;
        *)         health_score=70 ;;  # no healthcheck defined
    esac

    # --- Factor 2: Uptime stability (20%) ---
    local started_at uptime_seconds uptime_score=50
    started_at=$(echo "$inspect" | grep -o '"StartedAt":"[^"]*"' | head -1 | cut -d'"' -f4)
    if [[ -n "$started_at" && "$started_at" != "0001-01-01"* ]]; then
        local start_epoch now_epoch
        start_epoch=$(date -d "$started_at" '+%s' 2>/dev/null || date -j -f '%Y-%m-%dT%H:%M:%S' "${started_at%%.*}" '+%s' 2>/dev/null || echo 0)
        now_epoch=$(date '+%s')
        uptime_seconds=$((now_epoch - start_epoch))

        if (( uptime_seconds > 86400 )); then uptime_score=100      # >24h
        elif (( uptime_seconds > 3600 )); then uptime_score=80       # >1h
        elif (( uptime_seconds > 600 )); then uptime_score=60        # >10m
        else uptime_score=30
        fi
    fi

    # --- Factor 3: Restart count (20%) ---
    local restart_count restart_score=100
    restart_count=$(echo "$inspect" | grep -o '"RestartCount":[0-9]*' | head -1 | cut -d: -f2)
    restart_count="${restart_count:-0}"
    if (( restart_count == 0 )); then restart_score=100
    elif (( restart_count == 1 )); then restart_score=80
    elif (( restart_count <= 3 )); then restart_score=50
    else restart_score=20
    fi

    # --- Factor 4: Resource usage (15%) ---
    local resource_score=75
    local stats
    stats=$(docker stats --no-stream --format '{{.CPUPerc}} {{.MemPerc}}' "$container" 2>/dev/null | head -1)
    if [[ -n "$stats" ]]; then
        local cpu_pct mem_pct cpu_score=100 mem_score=100
        cpu_pct=$(echo "$stats" | awk '{gsub(/%/,""); print $1}')
        mem_pct=$(echo "$stats" | awk '{gsub(/%/,""); print $2}')

        cpu_pct=${cpu_pct%.*}; cpu_pct=${cpu_pct:-0}
        mem_pct=${mem_pct%.*}; mem_pct=${mem_pct:-0}

        if (( cpu_pct < 50 )); then cpu_score=100
        elif (( cpu_pct < 80 )); then cpu_score=60
        else cpu_score=30
        fi

        if (( mem_pct < 50 )); then mem_score=100
        elif (( mem_pct < 80 )); then mem_score=60
        else mem_score=30
        fi

        resource_score=$(( (cpu_score + mem_score) / 2 ))
    fi

    # --- Factor 5: Image freshness (15%) ---
    local image_age_score=80
    local image_id
    image_id=$(echo "$inspect" | grep -o '"Image":"sha256:[^"]*"' | head -1 | cut -d'"' -f4)
    if [[ -n "$image_id" ]]; then
        local image_created
        image_created=$(docker inspect --format='{{.Created}}' "$image_id" 2>/dev/null | head -1)
        if [[ -n "$image_created" ]]; then
            local img_epoch now_epoch age_days
            img_epoch=$(date -d "${image_created%%.*}" '+%s' 2>/dev/null || echo 0)
            now_epoch=$(date '+%s')
            age_days=$(( (now_epoch - img_epoch) / 86400 ))

            if (( age_days < 7 )); then image_age_score=100
            elif (( age_days < 30 )); then image_age_score=80
            elif (( age_days < 90 )); then image_age_score=50
            else image_age_score=20
            fi
        fi
    fi

    # --- Weighted total ---
    local total_score=$(( (health_score * 30 + uptime_score * 20 + restart_score * 20 + resource_score * 15 + image_age_score * 15) / 100 ))
    local grade
    grade=$(_health_grade "$total_score")

    printf '{"container":"%s","score":%d,"grade":"%s","factors":{"health":%d,"uptime":%d,"restarts":%d,"resources":%d,"image_age":%d}}' \
        "$(_hs_json_escape "$container")" "$total_score" "$grade" "$health_score" "$uptime_score" "$restart_score" "$resource_score" "$image_age_score"
}

# =============================================================================
# STACK SCORING
# =============================================================================

# Aggregate health scores for all containers in a stack
health_score_stack() {
    local stack_name="$1"
    local stack_dir="$COMPOSE_DIR/$stack_name"

    local containers=()
    local container_scores="["
    local first=true
    local score_sum=0 count=0 healthy_count=0

    # Get containers for this stack
    if [[ -d "$stack_dir" ]]; then
        while IFS= read -r cname; do
            [[ -z "$cname" ]] && continue
            containers+=("$cname")
        done < <(cd "$stack_dir" 2>/dev/null && ${DOCKER_COMPOSE_CMD:-docker compose} ps --format '{{.Name}}' 2>/dev/null)
    fi

    for cname in "${containers[@]}"; do
        local cscore_json
        cscore_json=$(health_score_container "$cname")
        local cscore
        cscore=$(echo "$cscore_json" | grep -o '"score":[0-9]*' | head -1 | cut -d: -f2)
        cscore="${cscore:-0}"
        score_sum=$((score_sum + cscore))
        count=$((count + 1))
        (( cscore >= 60 )) && healthy_count=$((healthy_count + 1))

        [[ "$first" == "true" ]] && first=false || container_scores+=","
        container_scores+="$cscore_json"
    done
    container_scores+="]"

    local stack_score=0
    if (( count > 0 )); then
        stack_score=$((score_sum / count))
        # Penalty for unhealthy containers
        local unhealthy=$((count - healthy_count))
        local penalty=$((unhealthy * 10))
        stack_score=$((stack_score - penalty))
        (( stack_score < 0 )) && stack_score=0
    fi

    local grade
    grade=$(_health_grade "$stack_score")

    printf '{"stack":"%s","score":%d,"grade":"%s","container_count":%d,"healthy_count":%d,"container_scores":%s}' \
        "$(_hs_json_escape "$stack_name")" "$stack_score" "$grade" "$count" "$healthy_count" "$container_scores"
}

# =============================================================================
# SYSTEM SCORING
# =============================================================================

# System-wide health score
health_score_system() {
    local stacks_json="["
    local first=true
    local stack_score_sum=0 stack_count=0

    # Score each stack
    local stack_list="${DOCKER_STACKS:-}"
    if [[ -z "$stack_list" && -f "$BASE_DIR/.env" ]]; then
        stack_list=$(grep '^DOCKER_STACKS=' "$BASE_DIR/.env" 2>/dev/null | cut -d= -f2- | tr -d '"')
    fi

    for stack in $stack_list; do
        local sscore_json
        sscore_json=$(health_score_stack "$stack")
        local sscore
        sscore=$(echo "$sscore_json" | grep -o '"score":[0-9]*' | head -1 | cut -d: -f2)
        sscore="${sscore:-0}"
        stack_score_sum=$((stack_score_sum + sscore))
        stack_count=$((stack_count + 1))

        [[ "$first" == "true" ]] && first=false || stacks_json+=","
        stacks_json+="$sscore_json"
    done
    stacks_json+="]"

    local stacks_avg=0
    (( stack_count > 0 )) && stacks_avg=$((stack_score_sum / stack_count))

    # System resources factor
    local cpu_count load_1 resource_score=75
    cpu_count=$(nproc 2>/dev/null || echo 1)
    load_1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)
    local load_pct
    load_pct=$(awk "BEGIN {v=$load_1/$cpu_count*100; printf \"%d\", v}")
    local mem_avail_pct
    mem_avail_pct=$(awk '/^MemAvailable:/ {a=$2} /^MemTotal:/ {t=$2} END {if(t>0) printf "%d", a*100/t; else print 50}' /proc/meminfo 2>/dev/null || echo 50)
    local disk_used_pct
    disk_used_pct=$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $5}')
    disk_used_pct="${disk_used_pct:-50}"

    local cpu_score=100 mem_score=100 disk_score=100
    (( load_pct > 80 )) && cpu_score=30 || { (( load_pct > 50 )) && cpu_score=60; }
    (( mem_avail_pct < 20 )) && mem_score=30 || { (( mem_avail_pct < 40 )) && mem_score=60; }
    (( disk_used_pct > 90 )) && disk_score=20 || { (( disk_used_pct > 80 )) && disk_score=50 || { (( disk_used_pct > 70 )) && disk_score=70; }; }
    resource_score=$(( (cpu_score + mem_score + disk_score) / 3 ))

    # Image freshness factor
    local images_score=80
    local total_images stale_images
    total_images=$(docker images -q 2>/dev/null | wc -l)
    stale_images=$(docker images --format '{{.CreatedSince}}' 2>/dev/null | grep -c 'months\|years' || echo 0)
    if (( total_images > 0 )); then
        local fresh_pct=$(( (total_images - stale_images) * 100 / total_images ))
        if (( fresh_pct >= 90 )); then images_score=100
        elif (( fresh_pct >= 70 )); then images_score=80
        elif (( fresh_pct >= 50 )); then images_score=50
        else images_score=20
        fi
    fi

    # Uptime factor
    local uptime_score=80
    local uptime_seconds
    uptime_seconds=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 0)
    if (( uptime_seconds > 604800 )); then uptime_score=100      # >7d
    elif (( uptime_seconds > 86400 )); then uptime_score=90       # >1d
    elif (( uptime_seconds > 3600 )); then uptime_score=70        # >1h
    else uptime_score=40
    fi

    # Weighted system score
    local system_score=$(( (stacks_avg * 40 + resource_score * 30 + images_score * 15 + uptime_score * 15) / 100 ))
    local grade
    grade=$(_health_grade "$system_score")

    printf '{"score":%d,"grade":"%s","factors":{"stacks":%d,"resources":%d,"images":%d,"uptime":%d},"stacks":%s}' \
        "$system_score" "$grade" "$stacks_avg" "$resource_score" "$images_score" "$uptime_score" "$stacks_json"
}

# =============================================================================
# HISTORY
# =============================================================================

# Return historical health scores from metrics data
health_score_history() {
    local range="${1:-24h}"

    # If metrics library is available, use it
    if command -v metrics_query >/dev/null 2>&1; then
        local metrics
        metrics=$(metrics_query "$range")
        # For each metrics point, approximate a health score
        echo "$metrics" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    result = []
    for m in data:
        cpu = m.get('cpu_percent', 0)
        mem = m.get('memory_percent', 0)
        disk = m.get('disk_percent', 0)
        running = m.get('containers_running', 0)
        total = m.get('containers_total', 1)
        # Simple approximation
        res_score = max(0, 100 - int((cpu + mem) / 2))
        disk_score = max(0, 100 - int(disk))
        container_ratio = (running / total * 100) if total > 0 else 50
        score = int(res_score * 0.4 + disk_score * 0.3 + container_ratio * 0.3)
        result.append({'ts': m.get('ts', ''), 'score': min(100, max(0, score))})
    print(json.dumps(result))
except:
    print('[]')
" 2>/dev/null
    else
        echo '[]'
    fi
}
