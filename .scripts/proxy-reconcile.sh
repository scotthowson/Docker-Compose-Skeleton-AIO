#!/bin/bash
# =============================================================================
# Proxy reconciliation — make sure Traefik is actually routing after a boot.
#
# After a power loss Docker restarts every container at once. Traefik can come
# up before the network is fully usable (its plugins are downloaded at start),
# before its Docker socket proxy answers, or before the services its routes
# point at exist. Some of those states never self-heal: the classic symptom is
# "every site is a 404 until I restart Traefik".
#
# This script probes every route Traefik knows from its custom_routes files
# through Traefik itself (Host header, loopback). If routes are dead while the
# target containers are running, it restarts Traefik once and probes again.
#
# Usage:  .scripts/proxy-reconcile.sh [--json] [--dry-run] [--wait SECONDS]
#         Sourced: proxy_reconcile [--json] [--dry-run]
# A 502/503/504 means Traefik routed the request but the app did not answer
# (still starting, crashed): that is reported, never "fixed" by a restart.
# Exit:   0 routing healthy (or nothing to do), 1 still broken after a restart,
#         2 could not probe (no Traefik, no routes), 3 routing fine but some
#         apps are not answering yet
# =============================================================================

_pr_base_dir() {
    if [[ -n "${BASE_DIR:-}" ]]; then printf '%s' "$BASE_DIR"; else
        (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); fi
}

# Traefik container name (compose service "traefik" or a container named Traefik)
_pr_traefik_container() {
    local c
    c=$(docker ps --filter "label=com.docker.compose.service=traefik" --format '{{.Names}}' 2>/dev/null | head -1)
    [[ -z "$c" ]] && c=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -ixE 'traefik' | head -1)
    [[ -n "$c" ]] && printf '%s' "$c"
}

# host:port Traefik listens on for HTTPS (published port for 443), else HTTP
_pr_traefik_entry() {
    local c="$1" p
    p=$(docker port "$c" 443/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}')
    [[ -n "$p" ]] && { printf 'https://127.0.0.1:%s' "$p"; return 0; }
    p=$(docker port "$c" 80/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}')
    [[ -n "$p" ]] && { printf 'http://127.0.0.1:%s' "$p"; return 0; }
    return 1
}

# "host<TAB>service-url" per route file found under Traefik's custom_routes mount
_pr_routes() {
    local c="$1" dir
    dir=$(docker inspect "$c" --format '{{range .Mounts}}{{if eq .Destination "/etc/traefik/custom_routes"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
    [[ -n "$dir" && -d "$dir" ]] || return 1
    local f host url
    while IFS= read -r f; do
        host=$(grep -oE 'Host\(`[^`]+`\)' "$f" 2>/dev/null | head -1 | sed -E 's/Host\(`([^`]+)`\)/\1/')
        url=$(grep -oE 'url: *"?[^" ]+' "$f" 2>/dev/null | head -1 | sed -E 's/url: *"?//')
        [[ -n "$host" && "$host" != *'${'* ]] && printf '%s\t%s\n' "$host" "${url:-}"
    done < <(find "$dir" -name '*.yml' -type f 2>/dev/null | sort)
}

# Container name from a service url like http://Plex:32400 (empty if not a container)
_pr_url_container() {
    local u="${1#*://}"; u="${u%%/*}"; u="${u%%:*}"
    [[ -n "$u" ]] && docker inspect "$u" >/dev/null 2>&1 && printf '%s' "$u"
}

# Probe one host through Traefik; prints the HTTP status (000 on failure)
_pr_probe() {
    local entry="$1" host="$2"
    curl -sk -o /dev/null -w '%{http_code}' --max-time 8 --resolve "${host}:${entry##*:}:127.0.0.1" \
        -H "Host: $host" "${entry%%:*}://${host}:${entry##*:}/" 2>/dev/null || printf '000'
}

proxy_reconcile() {
    local json=false dry=false wait_s=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json=true ;;
            --dry-run) dry=true ;;
            --wait) wait_s="${2:-0}"; shift ;;
        esac
        shift
    done
    local traefik entry
    traefik=$(_pr_traefik_container) || traefik=""
    if [[ -z "$traefik" ]]; then
        $json && echo '{"traefik": null, "status": "absent", "message": "No Traefik container running"}' || echo "proxy-reconcile: no Traefik container running — nothing to do"
        return 2
    fi
    entry=$(_pr_traefik_entry "$traefik") || { $json && echo '{"status": "no-entrypoint"}' || echo "proxy-reconcile: Traefik publishes no 80/443 port"; return 2; }

    # Optional grace period so containers that Traefik depends on can settle
    if (( wait_s > 0 )); then sleep "$wait_s"; fi

    local -a routes=()
    mapfile -t routes < <(_pr_routes "$traefik")
    if [[ ${#routes[@]} -eq 0 ]]; then
        $json && printf '{"traefik": "%s", "status": "no-routes", "message": "No custom route files"}\n' "$traefik" || echo "proxy-reconcile: no route files to probe"
        return 2
    fi

    _pr_check() {   # fills DEAD (Traefik not routing), BACKEND (app not answering) and PASS
        DEAD=(); BACKEND=(); PASS=0; SKIPPED=0
        local r host url code cname
        for r in "${routes[@]}"; do
            host="${r%%	*}"; url="${r#*	}"
            cname=$(_pr_url_container "$url") || cname=""
            if [[ -n "$cname" ]] && [[ "$(docker inspect -f '{{.State.Running}}' "$cname" 2>/dev/null)" != "true" ]]; then
                SKIPPED=$((SKIPPED+1)); continue   # target down: not Traefik's fault
            fi
            code=$(_pr_probe "$entry" "$host")
            case "$code" in
                000|404) DEAD+=("$host=$code") ;;
                502|503|504) BACKEND+=("$host=$code") ;;
                *) PASS=$((PASS+1)) ;;
            esac
        done
    }

    local DEAD BACKEND PASS SKIPPED
    _pr_check
    local restarted=false
    if [[ ${#DEAD[@]} -gt 0 ]]; then
        if $dry; then
            :
        else
            docker restart "$traefik" >/dev/null 2>&1 && restarted=true
            # Traefik needs a moment to load providers and plugins
            for _ in $(seq 1 30); do
                sleep 2
                [[ "$(docker inspect -f '{{.State.Health.Status}}' "$traefik" 2>/dev/null)" == "healthy" ]] && break
            done
            _pr_check
        fi
    fi

    local status="healthy"
    if [[ ${#DEAD[@]} -gt 0 ]]; then status="broken"; elif [[ ${#BACKEND[@]} -gt 0 ]]; then status="backends_down"; fi
    local dead_json="[]" backend_json="[]"
    [[ ${#DEAD[@]} -gt 0 ]] && dead_json=$(printf '%s\n' "${DEAD[@]}" | jq -R . | jq -s -c .)
    [[ ${#BACKEND[@]} -gt 0 ]] && backend_json=$(printf '%s\n' "${BACKEND[@]}" | jq -R . | jq -s -c .)
    if $json; then
        printf '{"traefik": "%s", "status": "%s", "routes": %d, "passing": %d, "skipped_target_down": %d, "dead": %s, "backend_down": %s, "restarted": %s, "dry_run": %s}\n' \
            "$traefik" "$status" "${#routes[@]}" "$PASS" "$SKIPPED" "$dead_json" "$backend_json" "$restarted" "$dry"
    else
        echo "proxy-reconcile: $traefik — ${#routes[@]} routes, $PASS passing, $SKIPPED skipped (target down), ${#DEAD[@]} dead, ${#BACKEND[@]} not answering${restarted:+, restarted=$restarted}"
        [[ ${#DEAD[@]} -gt 0 ]] && printf '  dead: %s\n' "${DEAD[@]}"
        [[ ${#BACKEND[@]} -gt 0 ]] && printf '  not answering: %s\n' "${BACKEND[@]}"
    fi
    case "$status" in healthy) return 0 ;; backends_down) return 3 ;; *) return 1 ;; esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    BASE_DIR="${BASE_DIR:-$(_pr_base_dir)}"
    proxy_reconcile "$@"
fi
