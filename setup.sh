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
  6. Installs required + optional system dependencies
     (jq, curl, git, python3, openssl, socat, rsync, tar, etc.)
  7. Verifies Docker and Docker Compose are installed
  8. Launches API server for Setup Wizard configuration

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
echo -e "${C_BOLD}${C_CYAN}|         Docker Compose Skeleton  --  Setup            |${C_RESET}"
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

_header "Step 1/8: Environment Configuration"
_divider

if [[ -f "$BASE_DIR/.env" ]]; then
    _skip ".env already exists -- not overwriting"
elif [[ -f "$BASE_DIR/.env.example" ]]; then
    _run cp "$BASE_DIR/.env.example" "$BASE_DIR/.env"
    _ok "Copied .env.example -> .env"
    _info "Edit .env to customize for your server"
else
    _fail ".env.example not found -- cannot create .env"
    _info "Create .env manually based on the project documentation"
fi

# =============================================================================
# STEP 2: Create Directories
# =============================================================================

_header "Step 2/8: Directory Structure"
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

_header "Step 3/8: Stack Directories"
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

_header "Step 4/8: Script Permissions"
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

_header "Step 5/8: File Ownership"
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
# STEP 6: System Dependencies
# =============================================================================

_header "Step 6/8: System Dependencies"
_divider

# ── Detect Linux distribution ──
_DISTRO="unknown"
_DISTRO_FAMILY="unknown"
_PKG_MGR=""
_PKG_INSTALL=""
_PKG_UPDATE=""

if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release 2>/dev/null
    _DISTRO="${NAME:-unknown}"
    case "${ID:-}:${ID_LIKE:-}" in
        *debian*|*ubuntu*|*mint*|*pop*)
            _DISTRO_FAMILY="debian"
            _PKG_MGR="apt-get"
            _PKG_INSTALL="sudo apt-get install -y"
            _PKG_UPDATE="sudo apt-get update -qq"
            ;;
        *fedora*|*rhel*|*centos*|*rocky*|*alma*)
            _DISTRO_FAMILY="rhel"
            _PKG_MGR="dnf"
            _PKG_INSTALL="sudo dnf install -y"
            _PKG_UPDATE=""
            ;;
        *arch*|*manjaro*|*endeavour*)
            _DISTRO_FAMILY="arch"
            _PKG_MGR="pacman"
            _PKG_INSTALL="sudo pacman -S --noconfirm --needed"
            _PKG_UPDATE="sudo pacman -Sy --noconfirm"
            ;;
        *suse*|*opensuse*)
            _DISTRO_FAMILY="suse"
            _PKG_MGR="zypper"
            _PKG_INSTALL="sudo zypper install -y"
            _PKG_UPDATE=""
            ;;
        *alpine*)
            _DISTRO_FAMILY="alpine"
            _PKG_MGR="apk"
            _PKG_INSTALL="sudo apk add --no-cache"
            _PKG_UPDATE="sudo apk update"
            ;;
        *void*)
            _DISTRO_FAMILY="void"
            _PKG_MGR="xbps-install"
            _PKG_INSTALL="sudo xbps-install -y"
            _PKG_UPDATE="sudo xbps-install -S"
            ;;
        *nixos*|*nix*)
            _DISTRO_FAMILY="nix"
            _PKG_MGR="nix-env"
            _PKG_INSTALL="nix-env -iA nixpkgs."
            _PKG_UPDATE=""
            ;;
    esac
fi

# Fallback detection via available binary
if [[ -z "$_PKG_MGR" ]]; then
    if   command -v apt-get >/dev/null 2>&1; then _DISTRO_FAMILY="debian"; _PKG_MGR="apt-get"; _PKG_INSTALL="sudo apt-get install -y"; _PKG_UPDATE="sudo apt-get update -qq"
    elif command -v dnf     >/dev/null 2>&1; then _DISTRO_FAMILY="rhel";   _PKG_MGR="dnf";     _PKG_INSTALL="sudo dnf install -y"
    elif command -v yum     >/dev/null 2>&1; then _DISTRO_FAMILY="rhel";   _PKG_MGR="yum";     _PKG_INSTALL="sudo yum install -y"
    elif command -v pacman  >/dev/null 2>&1; then _DISTRO_FAMILY="arch";   _PKG_MGR="pacman";   _PKG_INSTALL="sudo pacman -S --noconfirm --needed"; _PKG_UPDATE="sudo pacman -Sy --noconfirm"
    elif command -v zypper  >/dev/null 2>&1; then _DISTRO_FAMILY="suse";   _PKG_MGR="zypper";   _PKG_INSTALL="sudo zypper install -y"
    elif command -v apk     >/dev/null 2>&1; then _DISTRO_FAMILY="alpine"; _PKG_MGR="apk";      _PKG_INSTALL="sudo apk add --no-cache"; _PKG_UPDATE="sudo apk update"
    fi
fi

_info "Detected: ${C_BOLD}${_DISTRO}${C_RESET} (${_DISTRO_FAMILY})"
[[ -n "$_PKG_MGR" ]] && _info "Package manager: ${C_BOLD}${_PKG_MGR}${C_RESET}"

# ── Cross-distro package name mapping ──
# Tool name → actual package name varies between distro families.
_pkg_name() {
    local tool="$1"
    case "${_DISTRO_FAMILY}:${tool}" in
        # socat
        *:socat) echo "socat" ;;

        # ncat — different package on every distro
        debian:ncat)  echo "ncat" ;;
        rhel:ncat)    echo "nmap-ncat" ;;
        arch:ncat)    echo "nmap" ;;
        suse:ncat)    echo "ncat" ;;
        alpine:ncat)  echo "nmap-ncat" ;;
        *:ncat)       echo "ncat" ;;

        # python3 — Arch uses 'python' as the package name
        arch:python3) echo "python" ;;
        *:python3)    echo "python3" ;;

        # openssl — Alpine uses 'openssl' which is the binary + libs
        alpine:openssl) echo "openssl" ;;
        *:openssl)      echo "openssl" ;;

        # xxd — in different packages across distros
        debian:xxd)   echo "xxd" ;;
        rhel:xxd)     echo "vim-common" ;;
        arch:xxd)     echo "xxd" ;;
        suse:xxd)     echo "xxd" ;;
        alpine:xxd)   echo "vim" ;;
        *:xxd)        echo "xxd" ;;

        # perl — same everywhere except Alpine (perl is large, use perl-utils)
        alpine:perl)  echo "perl" ;;
        *:perl)       echo "perl" ;;

        # rsync
        *:rsync)      echo "rsync" ;;

        # Everything else — tool name = package name
        *)            echo "$tool" ;;
    esac
}

# ── Package index refresh (run once before first install) ──
_pkg_refreshed=false
_refresh_pkg_index() {
    [[ "$_pkg_refreshed" == "true" ]] && return
    if [[ -n "$_PKG_UPDATE" ]]; then
        _info "Updating package index..."
        if $DRY_RUN; then
            _info "DRY RUN: $_PKG_UPDATE"
        else
            ${_PKG_UPDATE} >/dev/null 2>&1 || true
        fi
    fi
    _pkg_refreshed=true
}

# ── Install a tool ──
_install_tool() {
    local tool="$1" required="${2:-false}"
    local pkg
    pkg=$(_pkg_name "$tool")

    if [[ -z "$_PKG_INSTALL" ]]; then
        _fail "No package manager found — install '$tool' manually"
        [[ "$required" == "true" ]] && return 1
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        _info "DRY RUN: Would install '$pkg' via: $_PKG_INSTALL $pkg"
        return 0
    fi

    _refresh_pkg_index

    _info "Installing '${C_BOLD}$pkg${C_RESET}'..."

    # Capture output so we can show it on failure
    local install_output
    if [[ "$_DISTRO_FAMILY" == "nix" ]]; then
        # Nix has a different syntax: nix-env -iA nixpkgs.PACKAGE
        install_output=$(${_PKG_INSTALL}${pkg} 2>&1) || true
    else
        install_output=$(${_PKG_INSTALL} "$pkg" 2>&1) || true
    fi

    if command -v "$tool" >/dev/null 2>&1; then
        _ok "Installed '$tool' successfully"
        return 0
    fi

    # Show install output on failure so user can diagnose
    _fail "Failed to install '$tool' (package: $pkg)"
    if [[ "$VERBOSE" == "true" && -n "$install_output" ]]; then
        echo "$install_output" | tail -5 | while IFS= read -r line; do
            echo "         $line"
        done
    fi
    [[ "$required" == "true" ]] && return 1
    return 0
}

deps_ok=true
deps_missing=0
deps_installed=0

# ── Required dependencies ──
echo ""
echo -e "  ${C_BOLD}Required dependencies:${C_RESET}"
echo ""

# socat OR ncat — need at least one for the API server listener
_LISTENER_FOUND=false
if command -v socat >/dev/null 2>&1; then
    _LISTENER_FOUND=true
    _ok "socat — TCP listener for API server"
elif command -v ncat >/dev/null 2>&1; then
    _LISTENER_FOUND=true
    _ok "ncat — TCP listener for API server"
fi

# Ordered list with descriptions (arrays instead of associative for consistent order)
_REQ_TOOLS=(jq curl git python3 openssl)
_REQ_DESCS=(
    "JSON processor — required for API server"
    "HTTP client — required for health checks and updates"
    "Version control — required for updates and plugin installs"
    "Python 3 — required for secure password hashing (PBKDF2)"
    "OpenSSL — required for secure token generation and TLS"
)

for i in "${!_REQ_TOOLS[@]}"; do
    tool="${_REQ_TOOLS[$i]}"
    desc="${_REQ_DESCS[$i]}"
    if command -v "$tool" >/dev/null 2>&1; then
        _ok "$tool — $desc"
    else
        deps_missing=$((deps_missing + 1))
        echo ""
        _fail "$tool — $desc"
        read -rp "    Install '$tool' now? [Y/n] " _answer
        if [[ ! "$_answer" =~ ^[Nn]$ ]]; then
            if _install_tool "$tool" "true"; then
                deps_installed=$((deps_installed + 1))
            else
                deps_ok=false
            fi
        else
            _fail "Skipped — '$tool' is required for full functionality"
            deps_ok=false
        fi
    fi
done

# Install socat if no listener found
if [[ "$_LISTENER_FOUND" == "false" ]]; then
    deps_missing=$((deps_missing + 1))
    echo ""
    _fail "socat — TCP listener for API server (neither socat nor ncat found)"
    read -rp "    Install 'socat' now? [Y/n] " _answer
    if [[ ! "$_answer" =~ ^[Nn]$ ]]; then
        if _install_tool "socat" "true"; then
            deps_installed=$((deps_installed + 1))
        else
            deps_ok=false
        fi
    else
        deps_ok=false
    fi
fi

# ── Optional dependencies (recommended) ──
echo ""
echo -e "  ${C_BOLD}Optional dependencies ${C_DIM}(recommended)${C_RESET}${C_BOLD}:${C_RESET}"
echo ""

_OPT_TOOLS=(rsync tar xxd perl)
_OPT_DESCS=(
    "Fast file copy — used for backups and snapshots"
    "Archive tool — used for backup/restore operations"
    "Hex encoder — used for secure token generation"
    "Text processing — used for ANSI code stripping in logs"
)

opt_missing=()
opt_missing_desc=()
for i in "${!_OPT_TOOLS[@]}"; do
    tool="${_OPT_TOOLS[$i]}"
    desc="${_OPT_DESCS[$i]}"
    if command -v "$tool" >/dev/null 2>&1; then
        _ok "$tool — $desc"
    else
        opt_missing+=("$tool")
        opt_missing_desc+=("$desc")
        _skip "$tool — $desc ${C_DIM}(not installed)${C_RESET}"
    fi
done

if [[ ${#opt_missing[@]} -gt 0 ]]; then
    echo ""
    _dep_word="dependency"; [[ ${#opt_missing[@]} -gt 1 ]] && _dep_word="dependencies"
    echo -e "  ${C_CYAN}Install ${#opt_missing[@]} optional ${_dep_word}? ${C_DIM}(recommended for full functionality)${C_RESET}"
    read -rp "    Install optional dependencies? [Y/n] " _opt_answer
    if [[ ! "$_opt_answer" =~ ^[Nn]$ ]]; then
        for tool in "${opt_missing[@]}"; do
            _install_tool "$tool" "false"
        done
    else
        _info "Skipped optional dependencies — some features may be limited"
    fi
fi

if [[ "$deps_installed" -gt 0 ]]; then
    echo ""
    _ok "Installed $deps_installed new package(s)"
fi

# =============================================================================
# STEP 7: Verify Docker Environment
# =============================================================================

_header "Step 7/8: Docker Environment"
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
elif [[ "$docker_ok" != "true" ]] || [[ "$deps_ok" != "true" ]]; then
    _fail "Setup completed with warnings (see issues above)"
    _info "Resolve the issues above, then run ./start.sh"
    echo ""
    exit 1
fi

_ok "Everything is configured and ready"
echo ""

# =============================================================================
# STEP 8: Setup Wizard — Launch API for remote configuration
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

SETUP_COMPLETE_MARKER="$BASE_DIR/.api-auth/.setup-complete"

if [[ -f "$SETUP_COMPLETE_MARKER" ]]; then
    _ok "Initial setup already complete."
    echo ""

    # Check if API server is already running
    API_PID_FILE="$BASE_DIR/.data/api-server.pid"
    if [[ -f "$API_PID_FILE" ]] && kill -0 "$(cat "$API_PID_FILE")" 2>/dev/null; then
        _info "API server is already running (PID $(cat "$API_PID_FILE"))"
        _info "Run ${C_BOLD}./start.sh${C_RESET} to launch all services."
        echo ""
        exit 0
    fi

    # Offer to start the API server
    echo -e "  ${C_CYAN}Would you like to start the API server?${C_RESET}"
    echo ""
    echo -e "    ${C_BOLD}1)${C_RESET} Start in background (recommended)"
    echo -e "    ${C_BOLD}2)${C_RESET} Start in foreground"
    echo -e "    ${C_BOLD}3)${C_RESET} Skip — just run ${C_DIM}./start.sh${C_RESET} later"
    echo ""
    read -r -p "  Choose [1/2/3]: " _api_choice
    echo ""

    API_PORT="${API_PORT:-9876}"
    HOST_IP=$(_detect_ip 2>/dev/null || echo "localhost")

    case "$_api_choice" in
        1)
            _info "Starting API server in background..."
            mkdir -p "$BASE_DIR/.data"
            nohup "$BASE_DIR/.scripts/api-server.sh" --bind 0.0.0.0 --port "$API_PORT" \
                > "$BASE_DIR/logs/api-server.log" 2>&1 &
            echo "$!" > "$API_PID_FILE"
            sleep 1
            if kill -0 "$(cat "$API_PID_FILE")" 2>/dev/null; then
                _ok "API server started (PID $(cat "$API_PID_FILE"))"
                # Verify the port is actually responding (not just process alive)
                local _api_ready=false
                for _i in $(seq 1 10); do
                    if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${API_PORT}/" 2>/dev/null; then
                        _api_ready=true
                        break
                    fi
                    sleep 1
                done
                if [[ "$_api_ready" == "true" ]]; then
                    _ok "API responding on http://${HOST_IP}:${API_PORT}"
                else
                    _warn "API process running but port ${API_PORT} not responding yet"
                    _info "It may still be initializing — check logs/api-server.log"
                fi
                _info "Logs: $BASE_DIR/logs/api-server.log"
            else
                _fail "API server failed to start — check logs/api-server.log"
            fi
            ;;
        2)
            _info "Starting API server in foreground (Ctrl+C to stop)..."
            echo ""
            exec "$BASE_DIR/.scripts/api-server.sh" --bind 0.0.0.0 --port "$API_PORT"
            ;;
        *)
            _info "Skipped. Run ${C_BOLD}./start.sh${C_RESET} to launch all services."
            ;;
    esac
    echo ""
    exit 0
fi

_header "Step 8/8: Setup Wizard"
_divider
echo ""

HOST_IP=$(_detect_ip)
API_PORT="${API_PORT:-9876}"

echo ""
echo -e "${C_BOLD}${C_CYAN}  ╔═══════════════════════════════════════════════════════╗${C_RESET}"
echo -e "${C_BOLD}${C_CYAN}  ║                                                       ║${C_RESET}"
echo -e "${C_BOLD}${C_CYAN}  ║          Setup API is ready!                           ║${C_RESET}"
echo -e "${C_BOLD}${C_CYAN}  ║                                                       ║${C_RESET}"
echo -e "${C_BOLD}${C_CYAN}  ║   Open DCS Manager and connect to:                    ║${C_RESET}"
echo -e "${C_BOLD}${C_GREEN}  ║   http://${HOST_IP}:${API_PORT}$(printf '%*s' $((28 - ${#HOST_IP} - ${#API_PORT})) '')║${C_RESET}"
echo -e "${C_BOLD}${C_CYAN}  ║                                                       ║${C_RESET}"
echo -e "${C_BOLD}${C_CYAN}  ║   Press Ctrl+C to stop the setup server               ║${C_RESET}"
echo -e "${C_BOLD}${C_CYAN}  ║                                                       ║${C_RESET}"
echo -e "${C_BOLD}${C_CYAN}  ╚═══════════════════════════════════════════════════════╝${C_RESET}"
echo ""

_info "Starting API server in setup mode..."
echo ""

# Launch API in foreground so Ctrl+C stops it cleanly
exec "$BASE_DIR/.scripts/api-server.sh" --bind 0.0.0.0 --port "$API_PORT" --setup-mode
