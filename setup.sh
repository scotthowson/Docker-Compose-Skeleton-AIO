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
    # A value saved without quotes but holding a space would run as a command
    # here; quote such lines first (the original is kept next to the file)
    [[ -f "$BASE_DIR/.lib/envfile.sh" ]] && source "$BASE_DIR/.lib/envfile.sh" && envfile_repair "$BASE_DIR/.env"
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
_env_set() {   # _env_set KEY VALUE — set or add one plain KEY=VALUE line in .env
    local key="$1" value="$2" file="$BASE_DIR/.env"
    [[ "$DRY_RUN" == "true" ]] && { _info "DRY RUN: $key=…"; return 0; }
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        grep -v "^${key}=" "$file" > "$file.tmp" && printf '%s=%s\n' "$key" "$value" >> "$file.tmp" && chmod 600 "$file.tmp" && mv -f "$file.tmp" "$file"
    else
        [[ -s "$file" && "$(tail -c1 "$file")" != "" ]] && printf '\n' >> "$file"
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

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
  --join HUB_URL CODE [NAME]
                  Make an installed DCS a member of the hub at HUB_URL (CODE is
                  a join code from the hub's Proxmox page); nothing else runs

FLEET (Proxmox): a hub is the DCS that is linked to Proxmox; the DCS in each
Docker VM joins it. Setup asks which one this machine is; unattended installs
answer with environment variables:
  DCS_FLEET_ROLE=hub|member|standalone
  DCS_HUB_URL=http://<hub>:9876 DCS_JOIN_TOKEN=<code> [DCS_MEMBER_NAME=<name>]
  DCS_PROXMOX_URL=https://pve:8006 DCS_PROXMOX_TOKEN_ID=user@realm!name
  DCS_PROXMOX_TOKEN_SECRET=<secret>            (links the hub to Proxmox)

UNATTENDED (no prompts, no wizard — what the hub runs inside a new VM):
  DCS_UNATTENDED=true DCS_ADMIN_USER=<name> DCS_ADMIN_PASSWORD=<password>
  DCS_STACKS="media-services" DCS_MEMBER_NAME=media-services DCS_TZ=… DCS_PUID=… DCS_PGID=…
  DCS_PROXY_DOMAIN=… DCS_CF_DNS_API_TOKEN=… DCS_API_PORT=9876 DCS_API_BIND=0.0.0.0
  DCS_NO_UI=true                                (API only: the hub's dashboard drives it)

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
JOIN_ONLY_HUB=""; JOIN_ONLY_CODE=""; JOIN_ONLY_NAME=""
# Unattended: no prompts, the admin account and the configuration come from
# DCS_ADMIN_USER / DCS_ADMIN_PASSWORD / DCS_STACKS / DCS_MEMBER_NAME / DCS_TZ …
# (the hub uses this to build member VMs). DCS_NO_UI=true skips DCS-UI: an
# API-only install, driven from the hub's dashboard.
UNATTENDED="${DCS_UNATTENDED:-false}"; [[ -n "${DCS_ADMIN_PASSWORD:-}" ]] && UNATTENDED=true
NO_UI="${DCS_NO_UI:-false}"
UNATTENDED_TOKEN=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)   show_help ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --verbose|-v) VERBOSE=true; shift ;;
        --join)
            [[ -n "${2:-}" && -n "${3:-}" ]] || { echo "Usage: ./setup.sh --join HUB_URL CODE [NAME]"; exit 1; }
            JOIN_ONLY_HUB="$2"; JOIN_ONLY_CODE="$3"; shift 3
            if [[ $# -gt 0 && "$1" != --* ]]; then JOIN_ONLY_NAME="$1"; shift; fi ;;
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

# ./setup.sh --join: only make this (installed) DCS a member of a hub
if [[ -n "$JOIN_ONLY_HUB" ]]; then
    [[ -x "$BASE_DIR/.scripts/api-server.sh" ]] || { _fail "No API server here — run ./setup.sh first"; exit 1; }
    echo ""
    "$BASE_DIR/.scripts/api-server.sh" --join-hub "$JOIN_ONLY_HUB" "$JOIN_ONLY_CODE" ${JOIN_ONLY_NAME:+"$JOIN_ONLY_NAME"}
    rc=$?
    [[ $rc -eq 0 ]] && _info "The hub's Proxmox page now shows this server's stacks under its VM."
    exit $rc
fi

# -----------------------------------------------------------------------------
# What kind of machine this is: the OS, bare metal or a guest (a QEMU/KVM guest
# is most likely a Proxmox VM, an LXC container most likely lives on a Proxmox
# host), or the Proxmox host itself. On a guest, look for the Proxmox API on
# the default gateway and the usual names so the link can be offered later.
# -----------------------------------------------------------------------------
ENV_OS="$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-$NAME}")"
ENV_VIRT="$(systemd-detect-virt 2>/dev/null || true)"; [[ -n "$ENV_VIRT" ]] || ENV_VIRT="unknown"
ENV_PVE_HOST=false; ENV_PVE_GUEST=false; ENV_PVE_HINT=""; ENV_MACHINE="bare metal"
if [[ -d /etc/pve ]] && command -v pvesh >/dev/null 2>&1; then
    ENV_PVE_HOST=true; ENV_MACHINE="the Proxmox host itself"
else
    case "$ENV_VIRT" in
        kvm|qemu) ENV_PVE_GUEST=true; ENV_MACHINE="QEMU/KVM virtual machine — most likely a Proxmox VM" ;;
        lxc|lxc-libvirt) ENV_PVE_GUEST=true; ENV_MACHINE="LXC container — most likely on a Proxmox host" ;;
        none|unknown) ENV_MACHINE="bare metal" ;;
        *) ENV_MACHINE="$ENV_VIRT guest" ;;
    esac
fi
if [[ "$ENV_PVE_GUEST" == "true" ]] && command -v curl >/dev/null 2>&1; then
    _gw=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
    for _c in $_gw pve proxmox pve.local proxmox.local; do
        [[ -n "$_c" ]] || continue
        _code=$(curl -sk -o /dev/null --max-time 1 -w '%{http_code}' "https://$_c:8006/api2/json/version" 2>/dev/null) || true
        if [[ "$_code" == "401" || "$_code" == "200" ]]; then ENV_PVE_HINT="https://$_c:8006"; break; fi
    done
fi
_info "Operating system: ${ENV_OS:-unknown}"
_info "Machine         : $ENV_MACHINE"
[[ -n "$ENV_PVE_HINT" ]] && _info "Proxmox API     : found at $ENV_PVE_HINT"
if [[ "$ENV_PVE_HOST" == "true" ]]; then
    _warn "This is the Proxmox host itself. DCS runs best in a small LXC or VM on it (docs/PROXMOX.md); continuing anyway."
fi

# -----------------------------------------------------------------------------
# Fleet role. A hub is the DCS linked to Proxmox: it shows and drives the DCS
# in the other VMs (members) from one dashboard. Asked once, on the first run;
# unattended installs answer with DCS_FLEET_ROLE / DCS_HUB_URL + DCS_JOIN_TOKEN.
# -----------------------------------------------------------------------------
FLEET_ROLE="${DCS_FLEET_ROLE:-}"
FLEET_HUB_URL="${DCS_HUB_URL:-}"; FLEET_JOIN_CODE="${DCS_JOIN_TOKEN:-}"; FLEET_MEMBER_NAME="${DCS_MEMBER_NAME:-}"
[[ -n "$FLEET_HUB_URL" && -n "$FLEET_JOIN_CODE" ]] && FLEET_ROLE="member"
case "$FLEET_ROLE" in hub|member|standalone|"") ;; *) _warn "DCS_FLEET_ROLE=$FLEET_ROLE is not hub, member or standalone — ignored"; FLEET_ROLE="" ;; esac
if [[ -z "$FLEET_ROLE" && -t 0 && "$UNATTENDED" != "true" && ! -f "$BASE_DIR/.api-auth/.setup-complete" ]]; then
    echo ""
    _info "How will this DCS be used?"
    echo "    1) Standalone — manage the Docker stacks on this machine (default)"
    echo "    2) Hub        — link Proxmox here and manage the DCS in the other VMs from this dashboard"
    echo "    3) Member     — this VM runs stacks under a hub (you need the hub's address and a join code)"
    read -r -p "  Choice [1/2/3]: " _role_choice
    case "${_role_choice:-1}" in
        2|hub|Hub) FLEET_ROLE="hub" ;;
        3|member|Member)
            FLEET_ROLE="member"
            read -r -p "  Hub address [http://<hub-ip>:9876]: " FLEET_HUB_URL
            read -r -p "  Join code (Proxmox page → Members on the hub): " FLEET_JOIN_CODE
            read -r -p "  Name for this server on the hub [$(hostname)]: " FLEET_MEMBER_NAME
            FLEET_HUB_URL="${FLEET_HUB_URL%/}"
            if [[ -z "$FLEET_HUB_URL" || -z "$FLEET_JOIN_CODE" ]]; then
                _warn "Hub address or join code missing — the join can be done later: ./setup.sh --join <hub-url> <code>"
                FLEET_ROLE="standalone"
            fi ;;
        *) FLEET_ROLE="standalone" ;;
    esac
fi
[[ -n "$FLEET_ROLE" ]] || FLEET_ROLE="standalone"
case "$FLEET_ROLE" in
    hub)    _ok "Role: hub — Proxmox is linked here and the other VMs join this DCS" ;;
    member) _ok "Role: member of ${FLEET_HUB_URL} — the join runs when the API is up" ;;
esac

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

# Unattended: the values the caller passed go into .env now, so the stack
# directories (Step 3) and the API (Step 7) follow them
if [[ "$UNATTENDED" == "true" && -f "$BASE_DIR/.env" ]]; then
    [[ -n "${DCS_STACKS:-}" ]] && _env_set DOCKER_STACKS "\"$DCS_STACKS\""
    [[ -n "${DCS_MEMBER_NAME:-}" ]] && _env_set SERVER_NAME "\"$DCS_MEMBER_NAME\""
    [[ -n "${DCS_TZ:-}" ]] && _env_set TZ "$DCS_TZ"
    [[ -n "${DCS_PUID:-}" ]] && _env_set PUID "$DCS_PUID"
    [[ -n "${DCS_PGID:-}" ]] && _env_set PGID "$DCS_PGID"
    [[ -n "${DCS_PROXY_DOMAIN:-}" ]] && _env_set PROXY_DOMAIN "$DCS_PROXY_DOMAIN"
    [[ -n "${DCS_API_PORT:-}" ]] && _env_set API_PORT "$DCS_API_PORT"
    [[ -n "${DCS_API_BIND:-}" ]] && _env_set API_BIND "$DCS_API_BIND"
    [[ -n "${DCS_ADMIN_PASSWORD:-}" ]] && _env_set API_AUTH_ENABLED true
    set -a; source "$BASE_DIR/.env"; set +a
    _ok "Unattended: .env prepared (stacks: ${DCS_STACKS:-default}, name: ${DCS_MEMBER_NAME:-$(hostname)})"
fi

# The DCS-UI container reaches the API through host.docker.internal, so the
# listener must be enabled and bound to all interfaces. .env.example already
# ships those defaults; this only repairs a .env inherited from an older
# version (anchored matches, quote-safe, never touches comments). An API-only
# install (DCS_NO_UI) keeps whatever bind it was given.
if [[ -f "$BASE_DIR/.env" && "$NO_UI" != "true" ]]; then
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

# -----------------------------------------------------------------------------
# On a Proxmox guest, offer to link DCS to the Proxmox API right away (an API
# token with VM.Audit, VM.PowerMgmt and Sys.Audit — see docs/PROXMOX.md). The
# same link can be made later in the wizard or in Server Config → Proxmox.
# -----------------------------------------------------------------------------
PVE_LINKED=false
_pve_url=""; _pve_tid=""; _pve_sec=""; _pve_ask=false
if [[ -f "$BASE_DIR/.env" ]] && ! grep -qE '^PROXMOX_URL=.+' "$BASE_DIR/.env" 2>/dev/null; then
    if [[ -n "${DCS_PROXMOX_URL:-}" && -n "${DCS_PROXMOX_TOKEN_ID:-}" && -n "${DCS_PROXMOX_TOKEN_SECRET:-}" ]]; then
        _pve_url="${DCS_PROXMOX_URL%/}"; _pve_tid="$DCS_PROXMOX_TOKEN_ID"; _pve_sec="$DCS_PROXMOX_TOKEN_SECRET"; _pve_ask=true
        _info "Linking Proxmox from DCS_PROXMOX_URL…"
    elif [[ -t 0 && "$UNATTENDED" != "true" && ( "$FLEET_ROLE" == "hub" || ( "$FLEET_ROLE" == "standalone" && "$ENV_PVE_GUEST" == "true" && -z "${DCS_FLEET_ROLE:-}" ) ) ]]; then
        echo ""
        _info "DCS can show and power the VMs and containers of this Proxmox host."
        _info "You need an API token: Datacenter → Permissions → API Tokens (docs/PROXMOX.md)."
        _pve_default_yn="y/N"; [[ "$FLEET_ROLE" == "hub" ]] && _pve_default_yn="Y/n"
        read -r -p "  Link DCS to this Proxmox now? [$_pve_default_yn] " _pve_yn
        [[ -z "$_pve_yn" && "$FLEET_ROLE" == "hub" ]] && _pve_yn="y"
        if [[ "${_pve_yn,,}" == "y" || "${_pve_yn,,}" == "yes" ]]; then
            read -r -p "  Proxmox URL [${ENV_PVE_HINT:-https://pve.example.com:8006}]: " _pve_url
            _pve_url="${_pve_url:-${ENV_PVE_HINT:-}}"; _pve_url="${_pve_url%/}"
            read -r -p "  API token ID (user@realm!name): " _pve_tid
            read -r -s -p "  Token secret: " _pve_sec; echo ""
            _pve_ask=true
        fi
    fi
    if [[ "$_pve_ask" == "true" ]]; then
        if [[ -n "$_pve_url" && -n "$_pve_tid" && -n "$_pve_sec" ]]; then
            _pve_verify=true
            _pve_code=$(curl -s -o /dev/null --max-time 8 -w '%{http_code}' -H "Authorization: PVEAPIToken=${_pve_tid}=${_pve_sec}" "$_pve_url/api2/json/version" 2>/dev/null) || true
            if [[ "$_pve_code" == "000" ]]; then
                _pve_code=$(curl -sk -o /dev/null --max-time 8 -w '%{http_code}' -H "Authorization: PVEAPIToken=${_pve_tid}=${_pve_sec}" "$_pve_url/api2/json/version" 2>/dev/null) || true
                [[ "$_pve_code" == "200" ]] && { _pve_verify=false; _info "Proxmox uses a self-signed certificate — verification is switched off for it"; }
            fi
            case "$_pve_code" in
                200)
                    _env_set PROXMOX_URL "$_pve_url"; _env_set PROXMOX_TOKEN_ID "$_pve_tid"; _env_set PROXMOX_TOKEN_SECRET "$_pve_sec"; _env_set PROXMOX_VERIFY_TLS "$_pve_verify"
                    PVE_LINKED=true; _ok "Proxmox linked: $_pve_url" ;;
                401) _warn "Proxmox rejected the token (check user@realm!name and the secret) — link it later in Server Config → Proxmox" ;;
                403) _warn "The token lacks VM.Audit, VM.PowerMgmt or Sys.Audit on / — fix the role, then link it in Server Config → Proxmox" ;;
                *)   _warn "Proxmox did not answer at $_pve_url (HTTP ${_pve_code:-none}) — link it later in Server Config → Proxmox" ;;
            esac
            unset _pve_sec
        else
            _skip "Proxmox link skipped (missing values) — Server Config → Proxmox does the same later"
        fi
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
        # Debian's own docker.io (26) with AppArmor 4 denies nginx its worker sockets, so the dashboard container never
        # answers: on that pairing the core stack runs the dashboard unconfined (Docker CE ships a profile that works)
        if docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q apparmor && [[ "${docker_version%%.*}" =~ ^[0-9]+$ ]] && (( ${docker_version%%.*} < 27 )) \
           && [[ -f /sys/module/apparmor/parameters/enabled ]] && dpkg -s docker.io >/dev/null 2>&1; then
            _core_env="$BASE_DIR/Stacks/core-infrastructure/.env"
            if [[ -d "$BASE_DIR/Stacks/core-infrastructure" ]] && ! grep -q '^DCS_UI_APPARMOR=' "$_core_env" 2>/dev/null; then
                printf 'DCS_UI_APPARMOR=unconfined\n' >> "$_core_env" 2>/dev/null && _warn "Docker $docker_version from Debian with AppArmor: the dashboard runs unconfined (DCS_UI_APPARMOR in Stacks/core-infrastructure/.env); Docker CE would not need this"
            fi
        fi
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
    command -v envfile_repair >/dev/null 2>&1 && envfile_repair "$BASE_DIR/.env"
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

if [[ "$NO_UI" == "true" ]]; then
    _info "API-only install: DCS-UI is not started here (a hub's dashboard drives this server)"
else
    _ensure_core_infra_running || {
        _info "DCS-UI may still be starting — try the URL below"
    }
fi

# Unattended: the first admin account and the configuration, without the wizard
# The address the unattended steps talk to: loopback, or the one specific address the API is bound to
_api_local_url() {
    local host="127.0.0.1"
    [[ "${API_BIND:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "${API_BIND}" != "0.0.0.0" ]] && host="$API_BIND"
    printf 'http://%s:%s' "$host" "${API_PORT:-9876}"
}
_unattended_finish() {
    local api user="${DCS_ADMIN_USER:-admin}" pass="${DCS_ADMIN_PASSWORD:-}" res tok stacks_json env_json i
    api=$(_api_local_url)
    [[ -n "$pass" ]] || { _warn "DCS_ADMIN_PASSWORD is not set — the first account is created in the wizard"; return 0; }
    for i in $(seq 1 30); do curl -s -m 2 "$api/setup/status" >/dev/null 2>&1 && break; sleep 1; done
    _info "Unattended setup: creating the admin account '$user'…"
    res=$(curl -s -m 30 -X POST "$api/auth/setup" -H 'Content-Type: application/json' -d "$(jq -nc --arg u "$user" --arg p "$pass" '{username: $u, password: $p}')") || res=""
    tok=$(jq -r '.token // empty' <<< "$res" 2>/dev/null) || tok=""
    if [[ -z "$tok" ]]; then
        res=$(curl -s -m 30 -X POST "$api/auth/login" -H 'Content-Type: application/json' -d "$(jq -nc --arg u "$user" --arg p "$pass" '{username: $u, password: $p}')") || res=""
        tok=$(jq -r '.token // empty' <<< "$res" 2>/dev/null) || tok=""
    fi
    [[ -n "$tok" ]] || { _fail "Could not create or sign in the admin account: $(jq -r '.message // .' <<< "$res" 2>/dev/null | head -c 200)"; return 1; }
    UNATTENDED_TOKEN="$tok"
    stacks_json=$(printf '%s\n' ${DCS_STACKS:-} | grep -v '^$' | jq -R . | jq -sc .) || stacks_json="[]"
    [[ "$stacks_json" != "[]" && -n "$stacks_json" ]] || stacks_json=$(printf '%s\n' ${DOCKER_STACKS:-core-infrastructure} | grep -v '^$' | jq -R . | jq -sc .) || stacks_json='["core-infrastructure"]'
    env_json=$(jq -nc --arg n "${DCS_MEMBER_NAME:-${SERVER_NAME:-}}" --arg tz "${DCS_TZ:-${TZ:-UTC}}" --arg puid "${DCS_PUID:-${PUID:-1000}}" --arg pgid "${DCS_PGID:-${PGID:-1000}}" --arg dom "${DCS_PROXY_DOMAIN:-${PROXY_DOMAIN:-}}" \
        '{SERVER_NAME: $n, TZ: $tz, PUID: $puid, PGID: $pgid, PROXY_DOMAIN: $dom} | with_entries(select(.value != ""))')
    res=$(curl -s -m 120 -X POST "$api/setup/configure" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d "$(jq -nc --argjson e "$env_json" --argjson s "$stacks_json" '{env_vars: $e, stacks: $s}')") || res=""
    jq -e '.error != true' <<< "$res" >/dev/null 2>&1 || _warn "setup/configure answered: $(head -c 200 <<< "$res")"
    if [[ -n "${DCS_CF_DNS_API_TOKEN:-}" ]]; then
        curl -s -m 20 -X POST "$api/secrets/CF_DNS_API_TOKEN" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d "$(jq -nc --arg v "$DCS_CF_DNS_API_TOKEN" '{value: $v}')" >/dev/null 2>&1 && _ok "Cloudflare token stored in the secret store"
    fi
    _ok "Admin account and configuration in place (stacks: $(jq -r 'join(", ")' <<< "$stacks_json"))"
}
_unattended_complete() {
    [[ -n "$UNATTENDED_TOKEN" ]] || return 0
    local res; res=$(curl -s -m 60 -X POST "$(_api_local_url)/setup/complete" -H "Authorization: Bearer $UNATTENDED_TOKEN" -H 'Content-Type: application/json' -d '{}') || res=""
    if jq -e '.initialized == true' <<< "$res" >/dev/null 2>&1; then _ok "Setup complete (unattended)"; else _warn "setup/complete answered: $(head -c 200 <<< "$res")"; fi
}
if [[ "$UNATTENDED" == "true" ]]; then
    _unattended_finish || exit 1
fi

if [[ "$NO_UI" == "true" ]]; then
    echo ""
    _info "API: http://${HOST_IP}:${API_PORT:-9876} (no dashboard on this server)"
else
    _print_url_banner
fi

# Fleet: a member joins now (or as soon as the wizard has made the first admin);
# a hub prints the join code the other VMs use.
_fleet_closing() {
    local api="$BASE_DIR/.scripts/api-server.sh" line tok url
    case "$FLEET_ROLE" in
        member)
            echo ""
            _info "Joining the hub at $FLEET_HUB_URL…"
            if "$api" --join-hub "$FLEET_HUB_URL" "$FLEET_JOIN_CODE" ${FLEET_MEMBER_NAME:+"$FLEET_MEMBER_NAME"} 2>&1 | sed 's/^/        /'; then
                _info "The hub's Proxmox page lists this server's stacks under its VM once the join is complete."
            else
                _warn "The join did not go through — fix the cause, then run: ./setup.sh --join $FLEET_HUB_URL <code>"
            fi ;;
        hub)
            line=$("$api" --join-token-quiet 2>/dev/null) || line=""
            tok="${line%%$'\t'*}"; url="${line#*$'\t'}"; url="${url%%$'\t'*}"
            [[ -n "$tok" && -n "$url" ]] || return 0
            echo ""
            _info "This DCS is the hub. On each Docker VM (join code valid 24 h, more on the Proxmox page):"
            echo -e "      ${C_BOLD}git clone https://github.com/scotthowson/Docker-Compose-Skeleton-AIO.git ~/.Docker-Compose-Skeleton-AIO${C_RESET}"
            echo -e "      ${C_BOLD}cd ~/.Docker-Compose-Skeleton-AIO && DCS_HUB_URL=$url DCS_JOIN_TOKEN=$tok ./setup.sh${C_RESET}"
            _info "A VM that already runs DCS:  ./setup.sh --join $url $tok"
            _info "The wizard's Proxmox step scans the VMs for DCS installs and links them too." ;;
    esac
}
_fleet_closing
[[ "$UNATTENDED" == "true" ]] && _unattended_complete

if [[ "$ENV_PVE_GUEST" == "true" || "$ENV_PVE_HOST" == "true" ]]; then
    echo ""
    if [[ "$PVE_LINKED" == "true" ]]; then
        _info "Proxmox: linked — the Proxmox page shows your VMs and containers; docs/PROXMOX.md covers the rest"
    elif grep -qE '^PROXMOX_URL=.+' "$BASE_DIR/.env" 2>/dev/null; then
        _info "Proxmox: linked in .env — see the Proxmox page"
    else
        _info "Proxmox: link it any time in Server Config → Proxmox (API token, docs/PROXMOX.md)${ENV_PVE_HINT:+ — the API answered at $ENV_PVE_HINT}"
    fi
fi
