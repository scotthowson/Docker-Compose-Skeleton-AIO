#!/bin/bash
# =============================================================================
# Docker Compose Skeleton — Docker Network Inspector
# Visualizes Docker networks, container connections, and port mappings
# with beautiful formatted output.
#
# Usage:
#   ./docker-network-info.sh [--all] [--ports] [--json]
#
# Options:
#   --all       Show all networks (including default bridge/host/none)
#   --ports     Include detailed port mapping information
#   --json      Output as JSON
#   --compact   Minimal output (just network -> container list)
# =============================================================================

# =============================================================================
# PATH AUTO-DETECTION
# =============================================================================

if [[ -z "${BASE_DIR:-}" ]]; then
    _DN_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    BASE_DIR="$(cd "$_DN_SCRIPT_DIR/.." && pwd)"
    unset _DN_SCRIPT_DIR
fi

# =============================================================================
# COLOR SETUP
# =============================================================================

if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]] && command -v tput >/dev/null 2>&1; then
    _DN_RESET="$(tput sgr0)"
    _DN_BOLD="$(tput bold)"
    _DN_DIM="$(tput dim)"
    _DN_GREEN="$(tput setaf 82)"
    _DN_YELLOW="$(tput setaf 214)"
    _DN_RED="$(tput setaf 196)"
    _DN_CYAN="$(tput setaf 51)"
    _DN_BLUE="$(tput setaf 33)"
    _DN_GRAY="$(tput setaf 245)"
    _DN_WHITE="$(tput setaf 15)"
    _DN_MAGENTA="$(tput setaf 141)"
    _DN_ORANGE="$(tput setaf 208)"
else
    _DN_RESET="" _DN_BOLD="" _DN_DIM=""
    _DN_GREEN="" _DN_YELLOW="" _DN_RED="" _DN_CYAN=""
    _DN_BLUE="" _DN_GRAY="" _DN_WHITE="" _DN_MAGENTA="" _DN_ORANGE=""
fi

# =============================================================================
# ARGUMENTS
# =============================================================================

SHOW_ALL=false
SHOW_PORTS=false
JSON_OUTPUT=false
COMPACT_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)     SHOW_ALL=true; shift ;;
        --ports)   SHOW_PORTS=true; shift ;;
        --json)    JSON_OUTPUT=true; shift ;;
        --compact) COMPACT_MODE=true; shift ;;
        --help|-h)
            cat <<EOF
Docker Network Inspector — Visualize Docker networking

Usage: $0 [--all] [--ports] [--json] [--compact]

Options:
  --all       Include default networks (bridge, host, none)
  --ports     Show detailed port mappings per container
  --json      Output as JSON
  --compact   Minimal output format
EOF
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

_dn_repeat() {
    local char="$1" count="$2"
    (( count <= 0 )) && return
    printf "%0.s${char}" $(seq 1 "$count")
}

_dn_header() {
    local title="$1"
    local width=65
    echo ""
    echo "  ${_DN_BLUE}+$(_dn_repeat "-" "$width")+${_DN_RESET}"
    local pad=$(( (width - ${#title}) / 2 ))
    printf "  ${_DN_BLUE}|%*s${_DN_BOLD}${_DN_CYAN}%s${_DN_RESET}${_DN_BLUE}%*s|${_DN_RESET}\n" "$pad" "" "$title" $(( width - pad - ${#title} )) ""
    echo "  ${_DN_BLUE}+$(_dn_repeat "-" "$width")+${_DN_RESET}"
    echo ""
}

# =============================================================================
# NETWORK OVERVIEW
# =============================================================================

show_network_overview() {
    _dn_header "Docker Network Overview"

    # Get all networks
    local networks
    if [[ "$SHOW_ALL" == "true" ]]; then
        networks="$(docker network ls --format '{{.Name}}|{{.Driver}}|{{.Scope}}|{{.ID}}' 2>/dev/null)"
    else
        networks="$(docker network ls --format '{{.Name}}|{{.Driver}}|{{.Scope}}|{{.ID}}' 2>/dev/null | grep -v '^bridge|' | grep -v '^host|' | grep -v '^none|')"
    fi

    if [[ -z "$networks" ]]; then
        echo "  ${_DN_YELLOW}No custom networks found${_DN_RESET}"
        echo "  ${_DN_DIM}Use --all to include default networks${_DN_RESET}"
        return
    fi

    # Network table header
    printf "  ${_DN_BOLD}${_DN_CYAN}%-25s %-12s %-10s %-14s %-8s${_DN_RESET}\n" \
        "NETWORK" "DRIVER" "SCOPE" "SUBNET" "CONTAINERS"
    printf "  ${_DN_GRAY}%-25s %-12s %-10s %-14s %-8s${_DN_RESET}\n" \
        "$(_dn_repeat "-" 23)" "$(_dn_repeat "-" 10)" "$(_dn_repeat "-" 8)" "$(_dn_repeat "-" 12)" "$(_dn_repeat "-" 6)"

    while IFS='|' read -r name driver scope net_id; do
        [[ -z "$name" ]] && continue

        # Get subnet
        local subnet
        subnet="$(docker network inspect "$name" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null)"
        [[ -z "$subnet" ]] && subnet="--"

        # Count connected containers
        local container_count
        container_count="$(docker network inspect "$name" --format '{{len .Containers}}' 2>/dev/null)"
        [[ -z "$container_count" ]] && container_count="0"

        # Color based on container count
        local count_color="$_DN_GRAY"
        if [[ "$container_count" -gt 0 ]]; then
            count_color="$_DN_GREEN"
        fi

        # Color network name by driver
        local name_color="$_DN_WHITE"
        case "$driver" in
            bridge)  name_color="$_DN_BLUE" ;;
            overlay) name_color="$_DN_MAGENTA" ;;
            macvlan) name_color="$_DN_ORANGE" ;;
            host)    name_color="$_DN_YELLOW" ;;
        esac

        printf "  ${name_color}%-25s${_DN_RESET} %-12s %-10s ${_DN_DIM}%-14s${_DN_RESET} ${count_color}%-8s${_DN_RESET}\n" \
            "$name" "$driver" "$scope" "$subnet" "$container_count"
    done <<< "$networks"

    echo ""
}

# =============================================================================
# NETWORK DETAIL (Container Connections)
# =============================================================================

show_network_detail() {
    _dn_header "Network Connections"

    local networks
    if [[ "$SHOW_ALL" == "true" ]]; then
        networks="$(docker network ls --format '{{.Name}}' 2>/dev/null)"
    else
        networks="$(docker network ls --format '{{.Name}}' 2>/dev/null | grep -v '^bridge$' | grep -v '^host$' | grep -v '^none$')"
    fi

    while IFS= read -r network; do
        [[ -z "$network" ]] && continue

        local containers
        containers="$(docker network inspect "$network" --format '{{range $id, $config := .Containers}}{{$config.Name}}|{{$config.IPv4Address}}|{{$config.MacAddress}}
{{end}}' 2>/dev/null | sed '/^$/d')"

        if [[ -z "$containers" ]]; then
            if [[ "$COMPACT_MODE" != "true" ]]; then
                echo "  ${_DN_BLUE}$network${_DN_RESET} ${_DN_DIM}(no containers)${_DN_RESET}"
            fi
            continue
        fi

        local container_count
        container_count="$(echo "$containers" | wc -l)"

        echo "  ${_DN_BOLD}${_DN_BLUE}$network${_DN_RESET} ${_DN_DIM}($container_count containers)${_DN_RESET}"

        if [[ "$COMPACT_MODE" == "true" ]]; then
            while IFS='|' read -r cname cip cmac; do
                [[ -z "$cname" ]] && continue
                echo "    ${_DN_GREEN}$cname${_DN_RESET} ${_DN_DIM}$cip${_DN_RESET}"
            done <<< "$containers"
        else
            echo "  ${_DN_GRAY}|${_DN_RESET}"

            local line_count=0
            local total_lines
            total_lines="$(echo "$containers" | wc -l)"

            while IFS='|' read -r cname cip cmac; do
                [[ -z "$cname" ]] && continue
                (( line_count++ ))

                local connector="├"
                [[ "$line_count" -eq "$total_lines" ]] && connector="└"

                echo "  ${_DN_GRAY}${connector}── ${_DN_GREEN}${_DN_BOLD}$cname${_DN_RESET}"
                echo "  ${_DN_GRAY}$([ "$line_count" -lt "$total_lines" ] && echo "│" || echo " ")   ${_DN_DIM}IP: $cip${_DN_RESET}"

                if [[ "$SHOW_PORTS" == "true" ]]; then
                    local ports
                    ports="$(docker port "$cname" 2>/dev/null)"
                    if [[ -n "$ports" ]]; then
                        while IFS= read -r port_line; do
                            echo "  ${_DN_GRAY}$([ "$line_count" -lt "$total_lines" ] && echo "│" || echo " ")   ${_DN_CYAN}Port: $port_line${_DN_RESET}"
                        done <<< "$ports"
                    fi
                fi
            done <<< "$containers"
        fi

        echo ""
    done <<< "$networks"
}

# =============================================================================
# PORT MAP
# =============================================================================

show_port_map() {
    _dn_header "Port Mappings"

    local port_data
    port_data="$(docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null | sort)"

    if [[ -z "$port_data" ]]; then
        echo "  ${_DN_YELLOW}No running containers with port mappings${_DN_RESET}"
        return
    fi

    printf "  ${_DN_BOLD}${_DN_CYAN}%-30s %-50s${_DN_RESET}\n" "CONTAINER" "PORT MAPPINGS"
    printf "  ${_DN_GRAY}%-30s %-50s${_DN_RESET}\n" "$(_dn_repeat "-" 28)" "$(_dn_repeat "-" 48)"

    while IFS='|' read -r name ports; do
        [[ -z "$name" ]] && continue
        [[ -z "$ports" ]] && ports="${_DN_DIM}(none)${_DN_RESET}"

        # Split long port strings across lines
        if [[ ${#ports} -gt 48 ]]; then
            printf "  %-30s %s\n" "$name" "${ports:0:48}"
            printf "  %-30s %s\n" "" "${ports:48}"
        else
            printf "  %-30s %s\n" "$name" "$ports"
        fi
    done <<< "$port_data"

    echo ""
}

# =============================================================================
# JSON OUTPUT
# =============================================================================

show_json() {
    echo "{"
    echo "  \"timestamp\": \"$(date -Iseconds)\","

    # Networks
    echo "  \"networks\": ["
    local first_net=true
    local networks
    networks="$(docker network ls --format '{{.Name}}' 2>/dev/null | grep -v '^bridge$' | grep -v '^host$' | grep -v '^none$')"

    while IFS= read -r network; do
        [[ -z "$network" ]] && continue
        [[ "$first_net" == "true" ]] && first_net=false || echo ","

        local subnet driver
        subnet="$(docker network inspect "$network" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null)"
        driver="$(docker network inspect "$network" --format '{{.Driver}}' 2>/dev/null)"

        printf '    {"name": "%s", "driver": "%s", "subnet": "%s", "containers": [' "$network" "$driver" "$subnet"

        local first_container=true
        docker network inspect "$network" --format '{{range $id, $config := .Containers}}{{$config.Name}}|{{$config.IPv4Address}}
{{end}}' 2>/dev/null | sed '/^$/d' | while IFS='|' read -r cname cip; do
            [[ -z "$cname" ]] && continue
            [[ "$first_container" == "true" ]] && first_container=false || printf ','
            printf '{"name": "%s", "ip": "%s"}' "$cname" "$cip"
        done

        printf ']}'
    done <<< "$networks"

    echo ""
    echo "  ]"
    echo "}"
}

# =============================================================================
# SUMMARY STATS
# =============================================================================

show_summary() {
    local total_networks total_containers total_ports

    total_networks="$(docker network ls -q 2>/dev/null | wc -l)"
    total_containers="$(docker ps -q 2>/dev/null | wc -l)"
    total_ports="$(docker ps --format '{{.Ports}}' 2>/dev/null | tr ',' '\n' | grep -c ':' 2>/dev/null || echo 0)"

    echo "  ${_DN_GRAY}$(_dn_repeat "-" 45)${_DN_RESET}"
    printf "  ${_DN_DIM}Networks: %-5s  Containers: %-5s  Ports: %-5s${_DN_RESET}\n" \
        "$total_networks" "$total_containers" "$total_ports"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        show_json
    else
        show_network_overview
        show_network_detail
        if [[ "$SHOW_PORTS" == "true" ]]; then
            show_port_map
        fi
        show_summary
    fi
fi
