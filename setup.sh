#!/bin/bash
# =============================================================================
# Docker Compose Skeleton - First-Run Setup Script
# Configures permissions, creates directories, and validates the environment
# =============================================================================

set -euo pipefail

# =============================================================================
# PATH AUTO-DETECTION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$SCRIPT_DIR"
export BASE_DIR

# Load root .env if it exists (for APP_DATA_DIR and other overrides)
if [[ -f "$BASE_DIR/.env" ]]; then
    set -a
    source "$BASE_DIR/.env"
    set +a
fi

COMPOSE_DIR="$BASE_DIR/Stacks"
export COMPOSE_DIR

# APP_DATA_DIR is relative — defaults to ./App-Data inside each stack folder.
# Docker Compose resolves this relative to each stack's directory, keeping data
# self-contained per stack (e.g., Stacks/core-infrastructure/App-Data/).
APP_DATA_DIR="${APP_DATA_DIR:-./App-Data}"

# Detect current user (never hardcode)
CURRENT_USER="$(whoami)"
CURRENT_GROUP="$(id -gn)"

# =============================================================================
# SIMPLE COLOR OUTPUT (no dependency on the full logger)
# =============================================================================

_setup_colors() {
    if [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]] && command -v tput >/dev/null 2>&1; then
        local colors
        colors="$(tput colors 2>/dev/null || echo 0)"
        if [[ "$colors" -ge 8 ]]; then
            C_GREEN="$(tput setaf 82 2>/dev/null || tput setaf 2)"
            C_YELLOW="$(tput setaf 208 2>/dev/null || tput setaf 3)"
            C_RED="$(tput setaf 124 2>/dev/null || tput setaf 1)"
            C_BLUE="$(tput setaf 33 2>/dev/null || tput setaf 4)"
            C_CYAN="$(tput setaf 51 2>/dev/null || tput setaf 6)"
            C_BOLD="$(tput bold 2>/dev/null || true)"
            C_DIM="$(tput dim 2>/dev/null || true)"
            C_RESET="$(tput sgr0 2>/dev/null || true)"
            return
        fi
    fi
    # No color support -- all codes are empty
    C_GREEN="" C_YELLOW="" C_RED="" C_BLUE="" C_CYAN="" C_BOLD="" C_DIM="" C_RESET=""
}

_setup_colors

# Print helpers
_ok()      { echo -e "  ${C_GREEN}[OK]${C_RESET}    $1"; }
_skip()    { echo -e "  ${C_YELLOW}[SKIP]${C_RESET}  $1"; }
_warn()    { echo -e "  ${C_YELLOW}[WARN]${C_RESET}  $1"; }
_fail()    { echo -e "  ${C_RED}[FAIL]${C_RESET}  $1"; }
_info()    { echo -e "  ${C_BLUE}[INFO]${C_RESET}  $1"; }
_header()  { echo -e "\n${C_BOLD}${C_CYAN}$1${C_RESET}"; }
_divider() { echo -e "${C_DIM}$(printf '%.0s-' {1..60})${C_RESET}"; }

# =============================================================================
# HELP / USAGE
# =============================================================================

show_help() {
    cat <<EOF
${C_BOLD}Docker Compose Skeleton - Setup${C_RESET}

Usage: ./setup.sh [OPTIONS]

First-run setup script that configures the project directory.

OPTIONS:
  --help, -h      Show this help message and exit
  --dry-run       Show what would be done without making changes
  --verbose, -v   Show extra detail during setup

WHAT IT DOES:
  1. Copies .env.example -> .env (if .env does not exist)
  2. Creates App-Data/ and logs/ directories
  3. Creates stack directories from DOCKER_STACKS in .env
     (each gets a base docker-compose.yml and .env template)
  4. Sets executable permissions on all .sh scripts
  5. Sets ownership to the current user (${CURRENT_USER})
  6. Verifies Docker and Docker Compose are installed
  7. Starts API server + DCS-UI container, prints browser URL

EOF
    exit 0
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

DRY_RUN=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)   show_help ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --verbose|-v) VERBOSE=true; shift ;;
        *)
            echo "Unknown option: $1"
            echo "Run './setup.sh --help' for usage."
            exit 1
            ;;
    esac
done

# Wrapper that respects --dry-run
_run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        _info "DRY RUN: $*"
    else
        "$@"
    fi
}

# =============================================================================
# BANNER
# =============================================================================

echo ""
echo -e "${C_BOLD}${C_CYAN}+======================================================+${C_RESET}"
echo -e "${C_BOLD}${C_CYAN}|    Docker Compose Skeleton AIO  --  Setup             |${C_RESET}"
echo -e "${C_BOLD}${C_CYAN}+======================================================+${C_RESET}"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    _info "Running in DRY RUN mode -- no changes will be made"
    echo ""
fi

_info "Base directory  : $BASE_DIR"
_info "Stacks directory: $COMPOSE_DIR"
_info "App-Data target : $APP_DATA_DIR"
_info "Running as user : ${CURRENT_USER}:${CURRENT_GROUP}"

# Running setup through sudo would leave .env, logs/ and every App-Data
# directory owned by root and start the API server as root.
if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    echo ""
    _fail "Run ./setup.sh as your normal user, not with sudo."
    _info "Docker access comes from membership in the docker group:"
    _info "  sudo usermod -aG docker ${SUDO_USER}   (then log out and back in)"
    echo ""
    exit 1
fi

# =============================================================================
# PRE-CHECK: Docker must be installed before proceeding
# =============================================================================

if ! command -v docker >/dev/null 2>&1; then
    echo ""
    _warn "Docker is NOT installed on this system."
    _info "DCS requires Docker Engine to manage containers."
    _info "Install Docker first: https://docs.docker.com/engine/install/"
    echo ""
    _fail "Cannot continue without Docker. Install it and run ./setup.sh again."
    exit 1
fi

# =============================================================================
# STEP 1: Environment File
# =============================================================================

_header "Step 1/7: Environment Configuration"
_divider

if [[ -f "$BASE_DIR/.env" ]]; then
    _skip ".env already exists -- not overwriting"
elif [[ -f "$BASE_DIR/.env.example" ]]; then
    _run cp "$BASE_DIR/.env.example" "$BASE_DIR/.env"
    _run chmod 600 "$BASE_DIR/.env"
    _ok "Copied .env.example -> .env"
    _info "Edit .env to customize for your server"
else
    _fail ".env.example not found -- cannot create .env"
    _info "Create .env manually based on the project documentation"
fi

# The DCS-UI container reaches the API through host.docker.internal, so the
# listener must be enabled and bound to all interfaces. .env.example already
# ships those defaults; this only repairs a .env inherited from an older
# version (anchored matches, quote-safe, never touches comments).
if [[ -f "$BASE_DIR/.env" ]]; then
    if grep -qE '^API_BIND=["'"'"']?127\.0\.0\.1' "$BASE_DIR/.env"; then
        [[ "$DRY_RUN" != "true" ]] && sed -i -E 's/^API_BIND=.*$/API_BIND=0.0.0.0/' "$BASE_DIR/.env"
        _ok "Updated API_BIND to 0.0.0.0 (required for the DCS-UI container)"
    fi
    if grep -qE '^API_ENABLED=["'"'"']?false' "$BASE_DIR/.env"; then
        [[ "$DRY_RUN" != "true" ]] && sed -i -E 's/^API_ENABLED=.*$/API_ENABLED=true/' "$BASE_DIR/.env"
        _ok "Enabled the API server (required for DCS-UI)"
    fi
    if grep -qE '^API_AUTH_ENABLED=["'"'"']?false' "$BASE_DIR/.env"; then
        _warn "API_AUTH_ENABLED=false is ignored on a non-loopback bind — authentication stays on"
        _info "(set API_INSECURE_NO_AUTH=true as well if you really want an open API)"
    fi
fi

# =============================================================================
# STEP 2: Create Directories
# =============================================================================

_header "Step 2/7: Directory Structure"
_divider

declare -a REQUIRED_DIRS=(
    "$BASE_DIR/logs"
    "$BASE_DIR/logs/archive"
)

for dir in "${REQUIRED_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        _skip "Directory exists: ${dir#"$BASE_DIR/"}"
    else
        _run mkdir -p "$dir"
        _ok "Created: ${dir#"$BASE_DIR/"}"
    fi
done

# =============================================================================
# STEP 3: Stack Directories
# =============================================================================

_header "Step 3/7: Stack Directories"
_divider

# Read stack list from .env (DOCKER_STACKS), or use defaults
if [[ -n "${DOCKER_STACKS:-}" ]]; then
    read -ra _SETUP_STACKS <<< "$DOCKER_STACKS"
    _info "Using DOCKER_STACKS from .env (${#_SETUP_STACKS[@]} stacks)"
else
    _SETUP_STACKS=(
        "core-infrastructure"
        "networking-security"
        "monitoring-management"
        "development-tools"
        "media-services"
        "web-applications"
        "storage-backup"
        "communication-collaboration"
        "entertainment-personal"
        "miscellaneous-services"
    )
    _info "Using default stack list (${#_SETUP_STACKS[@]} stacks)"
fi

stacks_created=0
stacks_existed=0

for stack_name in "${_SETUP_STACKS[@]}"; do
    stack_dir="$COMPOSE_DIR/$stack_name"
    if [[ -d "$stack_dir" ]]; then
        stacks_existed=$((stacks_existed + 1))
        # Ensure App-Data exists even for pre-existing stacks
        if [[ ! -d "$stack_dir/App-Data" ]]; then
            _run mkdir -p "$stack_dir/App-Data"
            _ok "Created App-Data/ in existing stack: $stack_name"
        fi
        [[ "$VERBOSE" == "true" ]] && _skip "Stack exists: $stack_name"
    else
        _run mkdir -p "$stack_dir"
        _run mkdir -p "$stack_dir/App-Data"

        # Create base docker-compose.yml
        if [[ "$DRY_RUN" != "true" ]]; then
            cat > "$stack_dir/docker-compose.yml" <<'COMPOSE_EOF'
services:
  # Add your services here
  # Example:
  # my-service:
  #   container_name: my-service
  #   image: alpine:latest
  #   restart: unless-stopped
  #   environment:
  #     - TZ=${TZ:-UTC}
  #   volumes:
  #     - ${APP_DATA_DIR:-./App-Data}/my-service:/data
COMPOSE_EOF
        fi

        # Create base .env
        if [[ "$DRY_RUN" != "true" ]]; then
            cat > "$stack_dir/.env" <<ENV_EOF
# =============================================================================
# $stack_name — Stack Environment Variables
# These override root .env values for services in this stack.
# =============================================================================

# Inherit from root .env:
# PUID, PGID, TZ, APP_DATA_DIR, PROXY_DOMAIN
ENV_EOF
        fi

        _ok "Created stack: $stack_name (docker-compose.yml + .env + App-Data/)"
        stacks_created=$((stacks_created + 1))
    fi
done

if [[ "$stacks_created" -gt 0 ]]; then
    _ok "Created $stacks_created new stack director${stacks_created:+ies}"
fi
if [[ "$stacks_existed" -gt 0 ]]; then
    _info "$stacks_existed stack directories already existed"
fi

unset _SETUP_STACKS

# =============================================================================
# STEP 4: Set Executable Permissions
# =============================================================================

_header "Step 4/7: Script Permissions"
_divider

chmod_count=0

# Root-level scripts
for script in "$BASE_DIR"/*.sh; do
    [[ -f "$script" ]] || continue
    _run chmod +x "$script"
    chmod_count=$((chmod_count + 1))
    [[ "$VERBOSE" == "true" ]] && _ok "chmod +x: $(basename "$script")"
done

# .lib/ scripts
if [[ -d "$BASE_DIR/.lib" ]]; then
    for script in "$BASE_DIR/.lib/"*.sh; do
        [[ -f "$script" ]] || continue
        _run chmod +x "$script"
        chmod_count=$((chmod_count + 1))
        [[ "$VERBOSE" == "true" ]] && _ok "chmod +x: .lib/$(basename "$script")"
    done
fi

# .scripts/ scripts
if [[ -d "$BASE_DIR/.scripts" ]]; then
    for script in "$BASE_DIR/.scripts/"*.sh; do
        [[ -f "$script" ]] || continue
        _run chmod +x "$script"
        chmod_count=$((chmod_count + 1))
        [[ "$VERBOSE" == "true" ]] && _ok "chmod +x: .scripts/$(basename "$script")"
    done
fi

# .config/ scripts
if [[ -d "$BASE_DIR/.config" ]]; then
    for script in "$BASE_DIR/.config/"*.sh; do
        [[ -f "$script" ]] || continue
        _run chmod +x "$script"
        chmod_count=$((chmod_count + 1))
        [[ "$VERBOSE" == "true" ]] && _ok "chmod +x: .config/$(basename "$script")"
    done
fi

_ok "Set executable on $chmod_count script files"

# =============================================================================
# STEP 5: Set Ownership
# =============================================================================

_header "Step 5/7: File Ownership"
_divider

# Only attempt chown if we can (avoids errors in unprivileged containers)
if [[ "$(id -u)" -eq 0 ]] || id -nG "$CURRENT_USER" 2>/dev/null | grep -qw "$(stat -c '%G' "$BASE_DIR" 2>/dev/null || echo "")"; then
    _run chown -R "${CURRENT_USER}:${CURRENT_GROUP}" "$BASE_DIR/.lib" 2>/dev/null || true
    _run chown -R "${CURRENT_USER}:${CURRENT_GROUP}" "$BASE_DIR/.scripts" 2>/dev/null || true
    _run chown -R "${CURRENT_USER}:${CURRENT_GROUP}" "$BASE_DIR/.config" 2>/dev/null || true
    _run chown "${CURRENT_USER}:${CURRENT_GROUP}" "$BASE_DIR"/*.sh 2>/dev/null || true
    _ok "Ownership set to ${CURRENT_USER}:${CURRENT_GROUP}"
else
    _skip "Not adjusting ownership (current user already owns files)"
fi

# =============================================================================
# STEP 6: Verify Docker Environment
# =============================================================================

_header "Step 6/7: Docker Environment"
_divider

docker_ok=true

# Check Docker daemon
if command -v docker >/dev/null 2>&1; then
    _ok "Docker binary found: $(command -v docker)"
    if docker info >/dev/null 2>&1; then
        _ok "Docker daemon is running"
        docker_version="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'unknown')"
        _info "Docker version: $docker_version"
    else
        _fail "Docker daemon is not running or not accessible"
        _info "Start Docker with: sudo systemctl start docker"
        docker_ok=false
    fi
else
    _fail "Docker is not installed"
    _info "Install Docker: https://docs.docker.com/engine/install/"
    docker_ok=false
fi

# Check Docker Compose
compose_found=false
if docker compose version &>/dev/null; then
    compose_version="$(docker compose version --short 2>/dev/null || echo 'unknown')"
    _ok "Docker Compose plugin (v2): $compose_version"
    compose_found=true
fi
if command -v docker-compose &>/dev/null; then
    compose_version="$(docker-compose --version 2>/dev/null | head -1 || echo 'unknown')"
    _ok "docker-compose binary (v1): $compose_version"
    compose_found=true
fi
if [[ "$compose_found" == "false" ]]; then
    _fail "No Docker Compose installation found"
    _info "Install: https://docs.docker.com/compose/install/"
    docker_ok=false
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
_divider
_header "Setup Complete"
_divider
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    _info "This was a DRY RUN -- no changes were made"
    _info "Remove --dry-run to apply changes"
    echo ""
    exit 0
elif [[ "$docker_ok" != "true" ]]; then
    _fail "Setup completed with warnings (Docker issues above)"
    _info "Resolve the Docker issues above, then run ./start.sh"
    echo ""
    exit 1
fi

_ok "Everything is configured and ready"
echo ""

# =============================================================================
# STEP 7: Launch DCS-UI — Start API + Web Interface
# =============================================================================

# Detect host IP for connection banners
_detect_ip() {
    local ip
    ip=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -1)
    [[ -n "$ip" ]] && { echo "$ip"; return; }
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -n "$ip" ]] && { echo "$ip"; return; }
    echo "localhost"
}

# Re-source .env to pick up any changes from Step 1
if [[ -f "$BASE_DIR/.env" ]]; then
    set -a; source "$BASE_DIR/.env"; set +a
fi

# Detect compose command (already validated in Step 6)
if docker compose version &>/dev/null; then
    _COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
    _COMPOSE_CMD="docker-compose"
else
    _fail "Docker Compose not available — cannot start DCS-UI"
    exit 1
fi

API_PORT="${API_PORT:-9876}"
API_BIND="${API_BIND:-0.0.0.0}"
DCS_UI_PORT="${DCS_UI_PORT:-3000}"
API_PID_FILE="$BASE_DIR/.data/api-server.pid"
API_BIND_FILE="$BASE_DIR/.data/api-server.bind"
HOST_IP=$(_detect_ip)
SETUP_COMPLETE_MARKER="$BASE_DIR/.api-auth/.setup-complete"

# ---------------------------------------------------------------------------
# Helper: ensure the API server is running in the background with the bind
# address .env asks for (a server left over from an older .env is replaced)
# ---------------------------------------------------------------------------
_ensure_api_running() {
    local running_pid=""
    [[ -f "$API_PID_FILE" ]] && running_pid=$(cat "$API_PID_FILE" 2>/dev/null)
    if [[ -n "$running_pid" ]] && kill -0 "$running_pid" 2>/dev/null; then
        local running_bind=""
        [[ -f "$API_BIND_FILE" ]] && running_bind=$(cat "$API_BIND_FILE" 2>/dev/null)
        if [[ "$running_bind" == "${API_BIND}:${API_PORT}" ]]; then
            _ok "API server already running (PID $running_pid, ${API_BIND}:${API_PORT})"
            return 0
        fi
        _info "API server is running with a different bind (${running_bind:-unknown}) — restarting"
    fi

    # Stop any previous or orphaned instance before starting a new one
    "$BASE_DIR/.scripts/api-server.sh" --stop >/dev/null 2>&1 || true

    _info "Starting API server on ${API_BIND}:${API_PORT}..."
    mkdir -p "$BASE_DIR/.data" "$BASE_DIR/logs"
    nohup "$BASE_DIR/.scripts/api-server.sh" --bind "$API_BIND" --port "$API_PORT" \
        </dev/null > "$BASE_DIR/logs/api-server.log" 2>&1 &
    local pid=$!
    echo "$pid" > "$API_PID_FILE"
    echo "${API_BIND}:${API_PORT}" > "$API_BIND_FILE"

    # Wait (up to 5 s) for the process to settle and the port to open
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.5
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        if ss -ltn 2>/dev/null | grep -qE "[:.]${API_PORT}[[:space:]]"; then
            _ok "API server started (PID $pid, listening on ${API_BIND}:${API_PORT})"
            return 0
        fi
    done

    if kill -0 "$pid" 2>/dev/null; then
        _ok "API server started (PID $pid)"
        return 0
    fi
    _fail "API server failed to start — check logs/api-server.log"
    tail -n 5 "$BASE_DIR/logs/api-server.log" 2>/dev/null | sed 's/^/        /'
    return 1
}

# ---------------------------------------------------------------------------
# Helper: ensure core-infrastructure stack is running (DCS-UI + Redis)
# ---------------------------------------------------------------------------
_ensure_core_infra_running() {
    local ui_status
    ui_status=$(docker inspect --format='{{.State.Status}}' DCS-UI 2>/dev/null || echo "not_found")

    if [[ "$ui_status" == "running" ]]; then
        # Already running — check health
        local health
        health=$(docker inspect --format='{{.State.Health.Status}}' DCS-UI 2>/dev/null || echo "unknown")
        if [[ "$health" == "healthy" ]]; then
            _ok "DCS-UI is running and healthy"
            return 0
        fi
        _info "DCS-UI is running (health: $health)"
        return 0
    fi

    _info "Starting core infrastructure..."
    local compose_rc=0
    $_COMPOSE_CMD -f "$COMPOSE_DIR/core-infrastructure/docker-compose.yml" \
        --env-file "$BASE_DIR/.env" \
        up -d 2>&1 | while IFS= read -r line; do
        [[ -n "$line" ]] && _info "  $line"
    done
    compose_rc=${PIPESTATUS[0]}
    if [[ $compose_rc -ne 0 ]]; then
        _fail "docker compose up failed (exit $compose_rc) — see the messages above"
        return 1
    fi

    # Wait for DCS-UI to become healthy
    _info "Waiting for DCS-UI to be ready..."
    local max_wait=90
    for i in $(seq 1 $max_wait); do
        local status
        status=$(docker inspect --format='{{.State.Health.Status}}' DCS-UI 2>/dev/null || echo "not_found")
        case "$status" in
            healthy)
                _ok "DCS-UI is healthy"
                return 0
                ;;
            unhealthy)
                _fail "DCS-UI container is unhealthy"
                _info "Check logs: docker logs DCS-UI"
                return 1
                ;;
            not_found)
                if (( i >= 5 )); then
                    _fail "DCS-UI container was not created"
                    _info "Check: $_COMPOSE_CMD -f Stacks/core-infrastructure/docker-compose.yml ps"
                    return 1
                fi
                ;;
        esac
        # Progress update every 10 seconds
        if (( i % 10 == 0 )); then
            _info "  Still waiting... (${i}s)"
        fi
        sleep 1
    done

    # If we got here, it didn't become healthy in time — but it may still be starting
    local final_status
    final_status=$(docker inspect --format='{{.State.Status}}' DCS-UI 2>/dev/null || echo "not_found")
    if [[ "$final_status" == "running" ]]; then
        _info "DCS-UI is running but not yet healthy — it may still be starting"
        return 0
    fi
    _fail "DCS-UI did not start within ${max_wait}s"
    return 1
}

# ---------------------------------------------------------------------------
# Helper: print the connection banner
# ---------------------------------------------------------------------------
_print_url_banner() {
    local local_url="http://localhost:${DCS_UI_PORT}"
    local net_url="http://${HOST_IP}:${DCS_UI_PORT}"
    local width=57
    # Every row is padded to the frame width so the right border lines up
    _row() { printf '%b  ║%-*s║%b\n' "$1" "$width" "$2" "$C_RESET"; }
    echo ""
    echo -e "${C_BOLD}${C_CYAN}  ╔═════════════════════════════════════════════════════════╗${C_RESET}"
    _row "${C_BOLD}${C_CYAN}" ""
    _row "${C_BOLD}${C_CYAN}" "   Open your browser to complete setup:"
    _row "${C_BOLD}${C_CYAN}" ""
    _row "${C_BOLD}${C_GREEN}" "   Local:   ${local_url}"
    _row "${C_BOLD}${C_GREEN}" "   Network: ${net_url}"
    _row "${C_BOLD}${C_CYAN}" ""
    _row "${C_BOLD}${C_CYAN}" "   The web UI will guide you through the rest."
    _row "${C_BOLD}${C_CYAN}" ""
    echo -e "${C_BOLD}${C_CYAN}  ╚═════════════════════════════════════════════════════════╝${C_RESET}"
    echo ""
    _info "Dashboard already open in a browser? Reload it (Ctrl+Shift+R) so it talks to this server."
    echo ""
}

# =============================================================================
# Already configured — start services and show URL
# =============================================================================
if [[ -f "$SETUP_COMPLETE_MARKER" ]]; then
    _ok "Initial setup already complete."
    echo ""
    _ensure_api_running
    _ensure_core_infra_running
    _print_url_banner
    _info "Run ${C_BOLD}./start.sh${C_RESET} to launch all stacks."
    echo ""
    exit 0
fi

# =============================================================================
# First run — bootstrap API + DCS-UI, then hand off to the browser
# =============================================================================
_header "Step 7/7: Launch DCS-UI"
_divider

_ensure_api_running || {
    _fail "Cannot continue without API server"
    _info "Check logs/api-server.log for details"
    exit 1
}

_ensure_core_infra_running || {
    _info "DCS-UI may still be starting — try the URL below"
}

_print_url_banner
