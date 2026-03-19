#!/bin/bash
# =============================================================================
# Docker Compose Skeleton — REST API Server v1.0
# Lightweight HTTP API for remote management — zero external dependencies.
# Uses socat or ncat to serve JSON responses over HTTP.
#
# Designed as the backend foundation for the Electron desktop app.
#
# Usage:
#   ./api-server.sh [--port PORT] [--bind ADDR] [--daemon] [--stop] [--help]
#
# Endpoints:
#   GET  /                          API info and available endpoints
#   GET  /status                    Overall system status
#   GET  /health                    Container health report (JSON)
#   GET  /stacks                    List all stacks with status
#   GET  /stacks/:name              Detailed info for a specific stack
#   GET  /stacks/:name/containers   Containers in a specific stack
#   GET  /stacks/:name/logs         Recent logs for a stack (last 50 lines)
#   GET  /stacks/:name/compose      Raw docker-compose.yml content for a stack
#   POST /stacks/:name/start        Start a specific stack
#   POST /stacks/:name/stop         Stop a specific stack
#   POST /stacks/:name/restart      Restart a specific stack
#   POST /stacks/:name/update       Pull, detect changes, recreate if needed
#   GET  /images                    All images with age/size/staleness
#   GET  /images/stale              Only stale images (>30 days)
#   GET  /containers                All containers with status
#   GET  /containers/:name          Detailed info for a specific container
#   GET  /containers/:name/stats    Live resource stats for a container
#   GET  /containers/:name/processes Process list for a container
#   GET  /config                    Current configuration (sanitized)
#   GET  /system                    System resource information
#   GET  /networks                  Docker networks and connections
#   GET  /volumes                   Docker volumes and usage
#   GET  /logs                      Framework log (last 100 lines)
#   GET  /events                    Recent Docker events (last 50)
#   GET  /version                   API and framework version info
#
# Authentication Endpoints:
#   POST   /auth/setup              Create first admin account (no auth required)
#   POST   /auth/login              Authenticate and get session token (no auth required)
#   POST   /auth/register           Register with invite code (no auth required)
#   GET    /auth/verify             Verify a token is valid (no auth required)
#   POST   /auth/invite             Generate an invite code (admin only)
#   GET    /auth/users              List all users (admin only)
#   POST   /auth/revoke             Revoke a user's access (admin only)
#   GET    /auth/invites            List active invite codes (admin only)
#   DELETE /auth/invite/:code       Delete an invite code (admin only)
#
# System Update Endpoints:
#   GET  /system/update/check       Check for available updates via git
#   POST /system/update/apply       Apply update (git pull --ff-only with backup)
#   POST /system/update/rollback    Rollback to a previous backup tag
#
# All responses are JSON with Content-Type: application/json.
# CORS headers are included for Electron app compatibility.
# =============================================================================

set -euo pipefail

# =============================================================================
# PATH AUTO-DETECTION
# =============================================================================

if [[ -z "${BASE_DIR:-}" ]]; then
    _API_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    BASE_DIR="$(cd "$_API_SCRIPT_DIR/.." && pwd)"
    unset _API_SCRIPT_DIR
fi

if [[ -f "$BASE_DIR/.env" ]]; then
    set -a
    source "$BASE_DIR/.env"
    set +a
fi

COMPOSE_DIR="${COMPOSE_DIR:-$BASE_DIR/Stacks}"
APP_DATA_DIR="${APP_DATA_DIR:-$BASE_DIR/App-Data}"

# =============================================================================
# CONFIGURATION
# =============================================================================

API_PORT="${API_PORT:-9876}"
API_BIND="${API_BIND:-127.0.0.1}"
API_VERSION="1.0.0"
API_PID_FILE="/tmp/dcs-api-server.pid"
API_LOG_FILE="${BASE_DIR}/logs/api-server.log"

# Authentication configuration
API_AUTH_DIR="${BASE_DIR}/.api-auth"
API_TOKEN_EXPIRY="${API_TOKEN_EXPIRY:-86400}"       # 24 hours in seconds
API_INVITE_EXPIRY="${API_INVITE_EXPIRY:-604800}"     # 7 days in seconds
API_MAX_LOGIN_ATTEMPTS="${API_MAX_LOGIN_ATTEMPTS:-5}"
API_LOCKOUT_DURATION="${API_LOCKOUT_DURATION:-900}"  # 15 minutes in seconds

# Auto-detect whether auth is required based on bind address
# Auth is optional for localhost-only, required for external access
if [[ -n "${API_AUTH_ENABLED:-}" ]]; then
    # Explicit override from config
    API_AUTH_ENABLED="${API_AUTH_ENABLED}"
else
    case "$API_BIND" in
        127.0.0.1|localhost|::1)
            API_AUTH_ENABLED="false"
            ;;
        *)
            API_AUTH_ENABLED="true"
            ;;
    esac
fi

# IP Whitelist — comma-separated list of allowed IPs/CIDRs (empty = allow all)
# Example: API_IP_WHITELIST="192.168.1.0/24,10.0.0.5"
API_IP_WHITELIST="${API_IP_WHITELIST:-}"

# PBKDF2 password hashing iterations
API_PBKDF2_ITERATIONS="${API_PBKDF2_ITERATIONS:-100000}"

# CORS allowed origins (comma-separated, empty = localhost only)
API_CORS_ORIGINS="${API_CORS_ORIGINS:-}"

# Whether the API runs behind a TLS-terminating proxy (enables HSTS header)
API_BEHIND_TLS_PROXY="${API_BEHIND_TLS_PROXY:-false}"

# TLS/HTTPS support — direct TLS termination via socat OPENSSL-LISTEN
API_TLS_ENABLED="${API_TLS_ENABLED:-false}"
API_TLS_CERT="${API_TLS_CERT:-$BASE_DIR/.api-auth/server.crt}"
API_TLS_KEY="${API_TLS_KEY:-$BASE_DIR/.api-auth/server.key}"

# Single-session enforcement (revoke old tokens on new login)
API_SINGLE_SESSION="${API_SINGLE_SESSION:-true}"

# Request body size limit (bytes) — 1 MB default
API_MAX_BODY_SIZE="${API_MAX_BODY_SIZE:-1048576}"

# Global rate limiting — max requests per minute per IP (0 = disabled)
API_RATE_LIMIT="${API_RATE_LIMIT:-120}"
API_RATE_WINDOW="${API_RATE_WINDOW:-60}"  # window in seconds

# Rate limit tracking directory
API_RATE_DIR="/tmp/dcs-api-rates"
mkdir -p "$API_RATE_DIR" 2>/dev/null

# API server start time (epoch) — used by /health for uptime & request counters
API_START_EPOCH="$(date +%s)"
API_STATS_FILE="/tmp/dcs-api-stats"
# Initialize stats file (request count, error count) — shared across forked handlers
[[ -f "$API_STATS_FILE" ]] || printf '0\n0\n' > "$API_STATS_FILE"

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
# ARGUMENT PARSING
# =============================================================================

DAEMON_MODE=false
STOP_SERVER=false
HANDLE_REQUEST=false
SETUP_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --handle-request) HANDLE_REQUEST=true; shift ;;
        --port)    API_PORT="$2"; shift 2 ;;
        --bind)    API_BIND="$2"; shift 2 ;;
        --daemon)  DAEMON_MODE=true; shift ;;
        --stop)    STOP_SERVER=true; shift ;;
        --setup-mode) SETUP_MODE=true; shift ;;
        --help|-h)
            cat <<EOF
Docker Compose Skeleton — REST API Server v${API_VERSION}

Usage: $0 [OPTIONS]

Options:
  --port PORT     Port to listen on (default: ${API_PORT})
  --bind ADDR     Bind address (default: ${API_BIND})
  --daemon        Run in background (daemonize)
  --stop          Stop a running daemon
  --help, -h      Show this help message

The API provides JSON endpoints for managing Docker Compose stacks,
containers, images, and system resources. Designed as the backend
for the Electron desktop application.

Requires: socat or ncat (netcat with -e support)
EOF
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# =============================================================================
# DAEMON MANAGEMENT
# =============================================================================

if [[ "$STOP_SERVER" == "true" ]]; then
    stopped=false
    if [[ -f "$API_PID_FILE" ]]; then
        pid=$(cat "$API_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            # Kill the process group to ensure socat children are also stopped
            kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null
            rm -f "$API_PID_FILE"
            echo "API server stopped (PID $pid)"
            stopped=true
        else
            rm -f "$API_PID_FILE"
        fi
    fi

    # Also try to kill any socat listening on API_PORT as a fallback
    if [[ "$stopped" == "false" ]]; then
        found_pid=$(lsof -ti "tcp:${API_PORT}" -sTCP:LISTEN 2>/dev/null || true)
        if [[ -n "$found_pid" ]]; then
            kill $found_pid 2>/dev/null
            rm -f "$API_PID_FILE"
            echo "API server stopped (found listening on port ${API_PORT})"
        else
            echo "API server is not running"
        fi
    fi
    exit 0
fi

# =============================================================================
# DEPENDENCY CHECK
# =============================================================================

LISTENER_CMD=""
if command -v socat >/dev/null 2>&1; then
    LISTENER_CMD="socat"
elif command -v ncat >/dev/null 2>&1; then
    LISTENER_CMD="ncat"
else
    echo "Error: Neither 'socat' nor 'ncat' found. Install one:" >&2
    echo "  sudo apt install socat       # Debian/Ubuntu" >&2
    echo "  sudo dnf install socat       # Fedora/RHEL" >&2
    echo "  sudo pacman -S socat         # Arch" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required for API authentication security." >&2
    echo "Install: sudo apt install jq  |  sudo dnf install jq  |  sudo pacman -S jq" >&2
    exit 1
fi

# =============================================================================
# JSON HELPERS
# =============================================================================

# Escape a string for safe JSON embedding (handles all control characters)
_api_json_escape() {
    local str="$1"
    # First strip ANSI escape sequences before doing JSON escaping
    # Use perl if available (most reliable), otherwise sed
    if command -v perl >/dev/null 2>&1; then
        str=$(printf '%s' "$str" | perl -pe 's/\e\[[0-9;]*[a-zA-Z]//g; s/\e\][^\a]*\a//g; s/[\x00-\x08\x0B\x0C\x0E-\x1F]//g' 2>/dev/null) || true
    fi
    str="${str//\\/\\\\}"      # backslash
    str="${str//\"/\\\"}"      # double quote
    str="${str//$'\n'/\\n}"    # newline
    str="${str//$'\r'/\\r}"    # carriage return
    str="${str//$'\t'/\\t}"    # tab
    printf '%s' "$str"
}

# Escape a value for use as sed replacement text (handles / \ &)
_sed_escape_val() {
    local v="$1"
    v="${v//\\/\\\\}"   # escape backslashes first
    v="${v//\//\\/}"     # escape forward slashes
    v="${v//&/\\&}"      # escape ampersands
    printf '%s' "$v"
}

# Validate a request Origin against the CORS whitelist
# Returns the origin if allowed, empty if not
_api_cors_origin() {
    local origin="${REQUEST_ORIGIN_HEADER:-}"
    [[ -z "$origin" ]] && return 0  # No Origin header = same-origin, no CORS needed

    # In setup mode before initialization, allow ALL origins so the Electron
    # app can connect from any IP without pre-configuring CORS
    if [[ "$SETUP_MODE" == "true" ]] && ! _api_is_initialized; then
        echo "$origin"
        return 0
    fi

    # Always allow any localhost / 127.0.0.1 origin (any port)
    # This covers Vite dev (5173/5174+), Electron, and any local tooling
    case "$origin" in
        http://localhost|http://localhost:*|https://localhost|https://localhost:*|\
        http://127.0.0.1|http://127.0.0.1:*|https://127.0.0.1|https://127.0.0.1:*|\
        capacitor://localhost)
            echo "$origin"
            return 0
            ;;
    esac

    # Check user-configured origins
    if [[ -n "$API_CORS_ORIGINS" ]]; then
        local IFS=','
        local entry
        for entry in $API_CORS_ORIGINS; do
            entry="${entry## }"  # trim leading space
            entry="${entry%% }"  # trim trailing space
            [[ -n "$entry" && "$origin" == "$entry" ]] && { echo "$origin"; return 0; }
        done
    fi

    return 0  # Return empty (no echo) — origin not allowed
}

# Build a standard JSON response envelope
_api_response() {
    local status_code="$1"
    local body="$2"
    local status_text="OK"

    case "$status_code" in
        200) status_text="OK" ;;
        201) status_text="Created" ;;
        400) status_text="Bad Request" ;;
        401) status_text="Unauthorized" ;;
        403) status_text="Forbidden" ;;
        404) status_text="Not Found" ;;
        405) status_text="Method Not Allowed" ;;
        409) status_text="Conflict" ;;
        413) status_text="Payload Too Large" ;;
        429) status_text="Too Many Requests" ;;
        500) status_text="Internal Server Error" ;;
    esac

    # Use byte count (not char count) for Content-Length — critical for UTF-8
    local content_length
    content_length=$(printf '%s' "$body" | wc -c)

    {
    printf "HTTP/1.1 %s %s\r\n" "$status_code" "$status_text"
    printf "Content-Type: application/json; charset=utf-8\r\n"
    printf "Content-Length: %d\r\n" "$content_length"

    # Dynamic CORS — only emit for whitelisted origins
    local cors_origin
    cors_origin=$(_api_cors_origin)
    if [[ -n "$cors_origin" ]]; then
        printf "Access-Control-Allow-Origin: %s\r\n" "$cors_origin"
        printf "Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS\r\n"
        printf "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
        printf "Access-Control-Allow-Private-Network: true\r\n"
        printf "Vary: Origin\r\n"
    fi

    # Security headers
    printf "X-Content-Type-Options: nosniff\r\n"
    printf "X-Frame-Options: DENY\r\n"
    printf "X-XSS-Protection: 1; mode=block\r\n"
    printf "Cache-Control: no-store, no-cache, must-revalidate\r\n"
    printf "Pragma: no-cache\r\n"
    printf "Content-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\n"
    printf "Referrer-Policy: strict-origin-when-cross-origin\r\n"
    if [[ "$API_TLS_ENABLED" == "true" ]] || [[ "$API_BEHIND_TLS_PROXY" == "true" ]]; then
        printf "Strict-Transport-Security: max-age=31536000; includeSubDomains\r\n"
    fi

    printf "X-API-Version: %s\r\n" "$API_VERSION"
    printf "Connection: close\r\n"
    printf "\r\n"
    printf "%s" "$body"
    } 2>/dev/null
}

_api_error() {
    local code="$1"
    local message="$2"
    local escaped
    escaped="$(_api_json_escape "$message")"
    # Increment error counter
    if [[ -f "${API_STATS_FILE:-/tmp/dcs-api-stats}" ]]; then
        local _rc _ec
        _rc=$(sed -n '1p' "$API_STATS_FILE" 2>/dev/null || echo 0)
        _ec=$(sed -n '2p' "$API_STATS_FILE" 2>/dev/null || echo 0)
        printf '%d\n%d\n' "$_rc" "$(( _ec + 1 ))" > "$API_STATS_FILE" 2>/dev/null
    fi
    _api_response "$code" "{\"error\": true, \"code\": $code, \"message\": \"$escaped\"}"
}

_api_success() {
    local body="$1"
    _api_response 200 "$body"
}

# =============================================================================
# QUERY STRING PARSER
# =============================================================================

declare -gA QUERY_PARAMS=()

_api_parse_query() {
    QUERY_PARAMS=()
    local full_path="$1"
    if [[ "$full_path" == *"?"* ]]; then
        local query_string="${full_path#*\?}"
        local IFS='&'
        local -a pairs
        read -ra pairs <<< "$query_string"
        for pair in "${pairs[@]}"; do
            local key="${pair%%=*}"
            local value="${pair#*=}"
            value="${value//+/ }"
            # URL-decode percent-encoded characters
            value=$(printf '%b' "${value//%/\\x}")
            QUERY_PARAMS["$key"]="$value"
        done
    fi
}

# =============================================================================
# AUTHENTICATION HELPERS
# =============================================================================

# Auth audit log — append-only structured log for security events
# Sanitizes all fields to prevent log injection (strips pipes, newlines, control chars)
_api_audit_log() {
    local ip="$1" event="$2" username="${3:-}" detail="${4:-}"
    # Strip pipe characters, newlines, and control chars from user-supplied fields
    username="${username//|/}"
    username="${username//$'\n'/}"
    username="${username//$'\r'/}"
    detail="${detail//|/}"
    detail="${detail//$'\n'/ }"
    detail="${detail//$'\r'/}"
    # Truncate detail to prevent log flooding (max 256 chars)
    [[ ${#detail} -gt 256 ]] && detail="${detail:0:256}..."
    printf '%s | %-15s | %-14s | %-15s | %s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$ip" "$event" "$username" "$detail" \
        >> "${API_AUTH_DIR}/auth-audit.log" 2>/dev/null
}

# Initialize auth data directory and files
_api_init_auth_dir() {
    if [[ ! -d "$API_AUTH_DIR" ]]; then
        (umask 0077 && mkdir -p "$API_AUTH_DIR")
    fi
    [[ ! -f "$API_AUTH_DIR/users.json" ]]  && install -m 0600 /dev/stdin "$API_AUTH_DIR/users.json" <<< '[]'
    [[ ! -f "$API_AUTH_DIR/tokens.json" ]] && install -m 0600 /dev/stdin "$API_AUTH_DIR/tokens.json" <<< '[]'
    [[ ! -f "$API_AUTH_DIR/invites.json" ]] && install -m 0600 /dev/stdin "$API_AUTH_DIR/invites.json" <<< '[]'
    [[ ! -f "$API_AUTH_DIR/rate_limits.json" ]] && install -m 0600 /dev/stdin "$API_AUTH_DIR/rate_limits.json" <<< '{}'
}

# Force-remove a directory, using Docker as fallback for root-owned files.
# Docker containers create files owned by root; the API server (running as the
# host user) can't delete those with plain rm. This tries rm first, then falls
# back to a throwaway Alpine container that mounts the directory and deletes it.
_force_remove_dir() {
    local dir="$1"
    [[ -d "$dir" ]] || return 0

    # Attempt 1: regular rm
    rm -rf "$dir" 2>/dev/null
    [[ -d "$dir" ]] || return 0

    # Attempt 2: Docker-based privileged removal
    if command -v docker >/dev/null 2>&1; then
        local abs_dir
        abs_dir=$(cd "$dir" 2>/dev/null && pwd || realpath "$dir" 2>/dev/null || echo "$dir")
        docker run --rm -v "$abs_dir:/___target" alpine rm -rf /___target 2>/dev/null
        # Docker removes the contents but the mount-point directory persists —
        # now the host user can remove the empty directory
        rm -rf "$dir" 2>/dev/null
    fi

    [[ -d "$dir" ]] && return 1 || return 0
}

# Hash a password with a given salt using SHA-256 (v1 — legacy, kept for verifying old hashes)
_api_hash_password() {
    local salt="$1"
    local password="$2"
    echo -n "${salt}${password}" | sha256sum | cut -d' ' -f1
}

# Hash a password with PBKDF2-SHA256 (v2 — secure, requires python3)
_api_hash_password_v2() {
    local salt="$1" password="$2" iters="${API_PBKDF2_ITERATIONS:-100000}"
    python3 -c "
import hashlib, sys
print(hashlib.pbkdf2_hmac(
    'sha256',
    sys.argv[1].encode(),
    bytes.fromhex(sys.argv[2]),
    int(sys.argv[3])
).hex())
" "$password" "$salt" "$iters"
}

# Verify a password against a stored hash, dispatching to v1 or v2 based on hash_version
_api_verify_password() {
    local password="$1" stored_hash="$2" stored_salt="$3" hash_version="${4:-1}"
    local computed_hash
    if [[ "$hash_version" == "2" ]]; then
        computed_hash=$(_api_hash_password_v2 "$stored_salt" "$password")
    else
        computed_hash=$(_api_hash_password "$stored_salt" "$password")
    fi
    [[ "$computed_hash" == "$stored_hash" ]]
}

# Update a user's password hash in users.json (for transparent migration)
_api_update_user_hash() {
    local username="$1" new_hash="$2" new_salt="$3" new_version="$4"
    local users
    users=$(_api_read_auth_file "users.json")
    if command -v jq >/dev/null 2>&1; then
        local new_users
        new_users=$(echo "$users" | jq \
            --arg u "$username" \
            --arg h "$new_hash" \
            --arg s "$new_salt" \
            --argjson v "$new_version" \
            '[.[] | if .username == $u then . + {"password_hash": $h, "salt": $s, "hash_version": $v} else . end]' 2>/dev/null)
        _api_write_auth_file "users.json" "$new_users"
    fi
}

# Generate a random token
_api_generate_token() {
    # SECURITY: Always use cryptographic randomness — never bash $RANDOM
    local token=""
    token=$(head -c 32 /dev/urandom 2>/dev/null | xxd -p -c 64 2>/dev/null)
    if [[ -z "$token" ]]; then
        token=$(head -c 32 /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
    fi
    if [[ -z "$token" ]]; then
        token=$(openssl rand -hex 32 2>/dev/null)
    fi
    if [[ -z "$token" || ${#token} -lt 32 ]]; then
        echo "FATAL: Cannot generate secure token — /dev/urandom unavailable" >&2
        return 1
    fi
    echo "$token"
}

# Generate a random salt
_api_generate_salt() {
    # SECURITY: Always use cryptographic randomness — never bash $RANDOM
    local salt=""
    salt=$(head -c 16 /dev/urandom 2>/dev/null | xxd -p -c 32 2>/dev/null)
    if [[ -z "$salt" ]]; then
        salt=$(head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
    fi
    if [[ -z "$salt" ]]; then
        salt=$(openssl rand -hex 16 2>/dev/null)
    fi
    if [[ -z "$salt" || ${#salt} -lt 16 ]]; then
        echo "FATAL: Cannot generate secure salt — /dev/urandom unavailable" >&2
        return 1
    fi
    echo "$salt"
}

# Read a JSON auth file (returns contents)
_api_read_auth_file() {
    local file="$API_AUTH_DIR/$1"
    if [[ -f "$file" ]]; then
        cat "$file" 2>/dev/null
    else
        echo '[]'
    fi
}

# Write a JSON auth file (restricted permissions)
_api_write_auth_file() {
    local file="$API_AUTH_DIR/$1"
    local content="$2"
    install -m 0600 /dev/stdin "$file" <<< "$content"
}

# Get current epoch timestamp
_api_now_epoch() {
    date +%s
}

# Get current ISO timestamp
_api_now_iso() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# Check if a user exists (returns 0 if exists, 1 if not)
_api_user_exists() {
    local username="$1"
    local users
    users=$(_api_read_auth_file "users.json")
    if command -v jq >/dev/null 2>&1; then
        local count
        count=$(echo "$users" | jq -r --arg u "$username" '[.[] | select(.username == $u)] | length' 2>/dev/null)
        [[ "$count" -gt 0 ]] && return 0
    else
        echo "$users" | grep -q "\"username\": *\"$username\"" && return 0
    fi
    return 1
}

# Setup wizard state
SETUP_COMPLETE_MARKER="$API_AUTH_DIR/.setup-complete"

# Check if server is fully initialized (users exist AND setup marker present)
_api_is_initialized() {
    [[ "$(_api_user_count)" -gt 0 ]] && [[ -f "$SETUP_COMPLETE_MARKER" ]]
}

# Gate for setup-only endpoints — returns 1 (and sends 403) if setup is already done
_api_require_setup_mode() {
    if _api_is_initialized; then
        _api_error 403 "Setup already complete"
        return 1
    fi
    return 0
}

# Get user count
_api_user_count() {
    local users
    users=$(_api_read_auth_file "users.json")
    if command -v jq >/dev/null 2>&1; then
        echo "$users" | jq 'length' 2>/dev/null
    else
        # Rough count by counting username fields
        echo "$users" | grep -c '"username"' 2>/dev/null || echo "0"
    fi
}

# Get user record as JSON (requires jq)
_api_get_user() {
    local username="$1"
    local users
    users=$(_api_read_auth_file "users.json")
    echo "$users" | jq -r --arg u "$username" '.[] | select(.username == $u)' 2>/dev/null
}

# Add a user record (always v2 hash)
_api_add_user() {
    local username="$1" password_hash="$2" salt="$3" role="$4"
    local created_at
    created_at=$(_api_now_iso)
    local users
    users=$(_api_read_auth_file "users.json")
    if command -v jq >/dev/null 2>&1; then
        local new_users
        new_users=$(echo "$users" | jq \
            --arg u "$username" \
            --arg h "$password_hash" \
            --arg s "$salt" \
            --arg r "$role" \
            --arg c "$created_at" \
            '. + [{"username": $u, "password_hash": $h, "salt": $s, "role": $r, "created_at": $c, "hash_version": 2}]' 2>/dev/null)
        _api_write_auth_file "users.json" "$new_users"
    else
        # Fallback: manual JSON construction
        local entry="{\"username\": \"$username\", \"password_hash\": \"$password_hash\", \"salt\": \"$salt\", \"role\": \"$role\", \"created_at\": \"$created_at\", \"hash_version\": 2}"
        if [[ "$users" == "[]" ]]; then
            _api_write_auth_file "users.json" "[$entry]"
        else
            # Remove trailing ] and append
            local trimmed="${users%]}"
            _api_write_auth_file "users.json" "${trimmed}, $entry]"
        fi
    fi
}

# Store a session token (enforces single-session when enabled)
_api_store_token() {
    local token="$1" username="$2" role="$3"

    # Single-session enforcement: revoke all existing tokens for this user
    if [[ "${API_SINGLE_SESSION:-true}" == "true" ]]; then
        _api_revoke_user_tokens "$username"
    fi

    local now
    now=$(_api_now_epoch)
    local expires_at=$(( now + API_TOKEN_EXPIRY ))
    local created_at
    created_at=$(_api_now_iso)
    local tokens
    tokens=$(_api_read_auth_file "tokens.json")
    if command -v jq >/dev/null 2>&1; then
        local new_tokens
        new_tokens=$(echo "$tokens" | jq \
            --arg t "$token" \
            --arg u "$username" \
            --arg r "$role" \
            --arg c "$created_at" \
            --argjson e "$expires_at" \
            '. + [{"token": $t, "username": $u, "role": $r, "created_at": $c, "expires_at": $e}]' 2>/dev/null)
        _api_write_auth_file "tokens.json" "$new_tokens"
    else
        local entry="{\"token\": \"$token\", \"username\": \"$username\", \"role\": \"$role\", \"created_at\": \"$created_at\", \"expires_at\": $expires_at}"
        if [[ "$tokens" == "[]" ]]; then
            _api_write_auth_file "tokens.json" "[$entry]"
        else
            local trimmed="${tokens%]}"
            _api_write_auth_file "tokens.json" "${trimmed}, $entry]"
        fi
    fi
}

# Validate a token — sets AUTH_USERNAME and AUTH_ROLE on success; returns 1 on failure
_api_validate_token() {
    local token="$1"
    AUTH_USERNAME=""
    AUTH_ROLE=""

    if [[ -z "$token" ]]; then
        return 1
    fi

    local tokens
    tokens=$(_api_read_auth_file "tokens.json")
    local now
    now=$(_api_now_epoch)

    local record
    record=$(echo "$tokens" | jq -r --arg t "$token" --argjson n "$now" \
        '.[] | select(.token == $t and .expires_at > $n)' 2>/dev/null)
    if [[ -n "$record" ]]; then
        AUTH_USERNAME=$(echo "$record" | jq -r '.username' 2>/dev/null)
        AUTH_ROLE=$(echo "$record" | jq -r '.role' 2>/dev/null)
        return 0
    fi
    return 1
}

# =============================================================================
# IP WHITELIST & RATE LIMITING
# =============================================================================

# Check if a given IP is within a CIDR range (supports /8 /16 /24 /32)
_api_ip_in_cidr() {
    local ip="$1" cidr="$2"
    local net mask
    net="${cidr%/*}"
    mask="${cidr#*/}"
    [[ "$mask" == "$cidr" ]] && mask=32  # no slash means exact match

    # Convert IP to integer
    local IFS='.'
    local -a ip_parts=($ip) net_parts=($net)
    local ip_int=$(( (ip_parts[0] << 24) + (ip_parts[1] << 16) + (ip_parts[2] << 8) + ip_parts[3] ))
    local net_int=$(( (net_parts[0] << 24) + (net_parts[1] << 16) + (net_parts[2] << 8) + net_parts[3] ))
    local mask_int=$(( 0xFFFFFFFF << (32 - mask) ))

    (( (ip_int & mask_int) == (net_int & mask_int) ))
}

# Check if the connecting IP is allowed
# Uses SOCAT_PEERADDR environment variable set by socat
_api_check_ip_whitelist() {
    [[ -z "$API_IP_WHITELIST" ]] && return 0  # no whitelist = allow all

    local client_ip="${SOCAT_PEERADDR:-127.0.0.1}"

    # Always allow localhost
    case "$client_ip" in
        127.0.0.1|::1|localhost) return 0 ;;
    esac

    # Check each entry in the whitelist
    local IFS=','
    for entry in $API_IP_WHITELIST; do
        entry="${entry// /}"  # trim spaces
        [[ -z "$entry" ]] && continue

        # Exact match
        [[ "$client_ip" == "$entry" ]] && return 0

        # CIDR match
        if [[ "$entry" == */* ]]; then
            _api_ip_in_cidr "$client_ip" "$entry" && return 0
        fi
    done

    return 1  # not in whitelist
}

# Check global rate limit for the connecting IP
# Returns 0 if within limit, 1 if rate limited
_api_check_global_rate_limit() {
    (( API_RATE_LIMIT <= 0 )) && return 0  # rate limiting disabled

    local client_ip="${SOCAT_PEERADDR:-127.0.0.1}"
    local now
    now=$(date +%s)

    # Always allow localhost without rate limiting
    case "$client_ip" in
        127.0.0.1|::1|localhost) return 0 ;;
    esac

    # Rate file per IP (sanitize the IP for filename)
    local safe_ip="${client_ip//[^0-9a-fA-F.]/_}"
    local rate_file="${API_RATE_DIR}/${safe_ip}"

    # Clean up old entries and count recent requests
    local count=0
    local cutoff=$(( now - API_RATE_WINDOW ))

    if [[ -f "$rate_file" ]]; then
        # Remove expired timestamps and count valid ones
        local tmp_file="${rate_file}.tmp"
        while IFS= read -r ts; do
            if (( ts > cutoff )); then
                echo "$ts"
                count=$(( count + 1 ))
            fi
        done < "$rate_file" > "$tmp_file" 2>/dev/null
        mv -f "$tmp_file" "$rate_file" 2>/dev/null
    fi

    # Check if over limit
    if (( count >= API_RATE_LIMIT )); then
        return 1
    fi

    # Record this request
    echo "$now" >> "$rate_file"
    return 0
}

# Check authentication from request headers — sets AUTH_USERNAME and AUTH_ROLE
# Returns 0 on success, 1 on failure
_api_check_auth() {
    AUTH_USERNAME=""
    AUTH_ROLE=""

    # If auth is disabled, allow everything
    if [[ "$API_AUTH_ENABLED" != "true" ]]; then
        AUTH_USERNAME="anonymous"
        AUTH_ROLE="admin"
        return 0
    fi

    # If no users exist yet, allow access (setup not complete)
    local user_count
    user_count=$(_api_user_count)
    if [[ "$user_count" -eq 0 ]]; then
        AUTH_USERNAME="anonymous"
        AUTH_ROLE="admin"
        return 0
    fi

    _api_init_auth_dir

    # Extract token from Authorization header
    local token=""
    if [[ -n "${REQUEST_AUTH_HEADER:-}" ]]; then
        # Strip "Bearer " prefix
        token="${REQUEST_AUTH_HEADER#Bearer }"
        token="${token#bearer }"
    fi

    if [[ -z "$token" ]]; then
        return 1
    fi

    _api_validate_token "$token"
    return $?
}

# Check if authenticated user is admin — call after _api_check_auth
_api_check_admin() {
    if [[ "${AUTH_ROLE:-}" != "admin" ]]; then
        return 1
    fi
    return 0
}

# Validate a stack name — rejects path traversal, shell metacharacters, etc.
# Returns 0 if valid, 1 if invalid (and sends 400 error response)
_api_validate_stack_name() {
    local name="$1"
    if [[ -z "$name" ]]; then
        _api_error 400 "Stack name is required"
        return 1
    fi
    # Reject path separators, parent traversal, leading dots
    # Note: null byte check removed — bash strings cannot contain \0, and $'\0' in [[ ]]
    # degrades to an empty string making the pattern ** which matches everything
    if [[ "$name" == *"/"* ]] || [[ "$name" == *".."* ]] || [[ "$name" == "."* ]]; then
        _api_error 400 "Invalid stack name"
        return 1
    fi
    # Enforce safe pattern: alphanumeric start, then alphanumeric/underscore/hyphen
    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
        _api_error 400 "Invalid stack name"
        return 1
    fi
    # Final realpath check — resolved path must stay within COMPOSE_DIR
    local resolved
    resolved=$(realpath -m "$COMPOSE_DIR/$name" 2>/dev/null)
    if [[ "$resolved" != "$COMPOSE_DIR/$name" ]] && [[ "$resolved" != "$COMPOSE_DIR/"* ]]; then
        _api_error 400 "Invalid stack name"
        return 1
    fi
    return 0
}

# Validate a resource name (container, network, volume, image, template, etc.)
# Returns 0 if valid, 1 if invalid (and sends 400 error response)
_api_validate_resource_name() {
    local name="$1" resource_type="${2:-resource}"
    if [[ -z "$name" ]]; then
        _api_error 400 "${resource_type} name is required"
        return 1
    fi
    # Reject path traversal and shell metacharacters
    # Note: null byte check removed — bash strings cannot contain \0, and $'\0' in [[ ]]
    # degrades to an empty string making the pattern ** which matches everything
    if [[ "$name" == *".."* ]] || [[ "$name" == *"/"* ]]; then
        _api_error 400 "Invalid ${resource_type} name"
        return 1
    fi
    # shellcheck disable=SC1003
    case "$name" in
        *';'*|*'|'*|*'`'*|*'$('*|*'&'*|*'>'*|*'<'*)
            _api_error 400 "Invalid ${resource_type} name"
            return 1
            ;;
    esac
    # Enforce safe pattern: alphanumeric start, then alphanumeric/dot/underscore/hyphen/colon
    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._:/-]*$ ]]; then
        _api_error 400 "Invalid ${resource_type} name"
        return 1
    fi
    return 0
}

# Validate a URL for SSRF protection — blocks private/internal IPs
# Returns 0 if safe, 1 if blocked (and sends 400 error response)
_api_validate_url() {
    local url="$1" context="${2:-URL}"

    # Must be http(s) or git@
    if [[ ! "$url" =~ ^https?:// ]] && [[ ! "$url" =~ ^git@ ]]; then
        _api_error 400 "$context must use http://, https://, or git@ scheme"
        return 1
    fi

    # Extract hostname from URL
    local host
    host=$(echo "$url" | sed -E 's|^https?://||; s|^git@||; s|[:/].*||; s|@.*||')

    if [[ -z "$host" ]]; then
        _api_error 400 "Cannot parse hostname from $context"
        return 1
    fi

    # Block obvious internal/private hostnames
    case "$host" in
        localhost|*.local|*.internal|*.localhost)
            _api_error 400 "$context blocked: private hostname ($host)"
            return 1
            ;;
    esac

    # Resolve hostname to IP and check for private ranges
    local resolved_ip
    resolved_ip=$(getent hosts "$host" 2>/dev/null | awk '{print $1; exit}')
    # Also try dig if getent fails
    [[ -z "$resolved_ip" ]] && resolved_ip=$(dig +short "$host" 2>/dev/null | head -1)

    if [[ -n "$resolved_ip" ]]; then
        case "$resolved_ip" in
            # IPv4 private ranges
            10.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|192.168.*) ;;
            # Loopback
            127.*) ;;
            # Link-local / metadata (AWS, GCP, Azure)
            169.254.*|100.100.100.200) ;;
            # IPv6 loopback/link-local
            ::1|fe80:*|fd*) ;;
            # Safe — skip blocking
            *) return 0 ;;
        esac
        _api_error 400 "$context blocked: resolves to private/internal address ($resolved_ip)"
        return 1
    fi

    # If we can't resolve, allow it (DNS may not be available in all environments)
    return 0
}

# Rate limiting: check if an IP is locked out
_api_check_rate_limit() {
    local client_ip="${1:-unknown}"
    local rate_file="$API_AUTH_DIR/rate_limits.json"
    [[ ! -f "$rate_file" ]] && return 0

    if command -v jq >/dev/null 2>&1; then
        local now
        now=$(_api_now_epoch)
        local record
        record=$(cat "$rate_file" | jq -r --arg ip "$client_ip" '.[$ip] // empty' 2>/dev/null)
        if [[ -n "$record" ]]; then
            local attempts locked_until
            attempts=$(echo "$record" | jq -r '.attempts // 0' 2>/dev/null)
            locked_until=$(echo "$record" | jq -r '.locked_until // 0' 2>/dev/null)
            if [[ "$locked_until" -gt "$now" ]] 2>/dev/null; then
                return 1  # Still locked out
            fi
            # Reset if lock has expired
            if [[ "$locked_until" -gt 0 ]] && [[ "$locked_until" -le "$now" ]] 2>/dev/null; then
                _api_reset_rate_limit "$client_ip"
            fi
        fi
    fi
    return 0
}

# Rate limiting: record a failed login attempt
_api_record_failed_login() {
    local client_ip="${1:-unknown}"
    local rate_file="$API_AUTH_DIR/rate_limits.json"
    [[ ! -f "$rate_file" ]] && echo '{}' > "$rate_file"

    if command -v jq >/dev/null 2>&1; then
        local now
        now=$(_api_now_epoch)
        local rates
        rates=$(cat "$rate_file")
        local current_attempts
        current_attempts=$(echo "$rates" | jq -r --arg ip "$client_ip" '.[$ip].attempts // 0' 2>/dev/null)
        current_attempts=$(( current_attempts + 1 ))

        local locked_until=0
        if [[ "$current_attempts" -ge "$API_MAX_LOGIN_ATTEMPTS" ]]; then
            locked_until=$(( now + API_LOCKOUT_DURATION ))
        fi

        local new_rates
        new_rates=$(echo "$rates" | jq \
            --arg ip "$client_ip" \
            --argjson a "$current_attempts" \
            --argjson l "$locked_until" \
            --argjson t "$now" \
            '.[$ip] = {"attempts": $a, "locked_until": $l, "last_attempt": $t}' 2>/dev/null)
        printf '%s' "$new_rates" > "$rate_file"
    fi
}

# Rate limiting: reset after successful login
_api_reset_rate_limit() {
    local client_ip="${1:-unknown}"
    local rate_file="$API_AUTH_DIR/rate_limits.json"
    [[ ! -f "$rate_file" ]] && return

    if command -v jq >/dev/null 2>&1; then
        local rates
        rates=$(cat "$rate_file")
        local new_rates
        new_rates=$(echo "$rates" | jq --arg ip "$client_ip" 'del(.[$ip])' 2>/dev/null)
        printf '%s' "$new_rates" > "$rate_file"
    fi
}

# Clean up expired tokens (called periodically)
_api_cleanup_expired_tokens() {
    local tokens
    tokens=$(_api_read_auth_file "tokens.json")
    local now
    now=$(_api_now_epoch)

    if command -v jq >/dev/null 2>&1; then
        local cleaned
        cleaned=$(echo "$tokens" | jq --argjson n "$now" '[.[] | select(.expires_at > $n)]' 2>/dev/null)
        [[ -n "$cleaned" ]] && _api_write_auth_file "tokens.json" "$cleaned"
    fi
}

# Store an invite code
_api_store_invite() {
    local code="$1" role="$2" created_by="$3"
    local now
    now=$(_api_now_epoch)
    local expires_at=$(( now + API_INVITE_EXPIRY ))
    local created_at
    created_at=$(_api_now_iso)
    local invites
    invites=$(_api_read_auth_file "invites.json")

    if command -v jq >/dev/null 2>&1; then
        local new_invites
        new_invites=$(echo "$invites" | jq \
            --arg c "$code" \
            --arg r "$role" \
            --arg b "$created_by" \
            --arg ca "$created_at" \
            --argjson e "$expires_at" \
            '. + [{"code": $c, "role": $r, "created_by": $b, "created_at": $ca, "expires_at": $e, "used": false, "used_by": ""}]' 2>/dev/null)
        _api_write_auth_file "invites.json" "$new_invites"
    else
        local entry="{\"code\": \"$code\", \"role\": \"$role\", \"created_by\": \"$created_by\", \"created_at\": \"$created_at\", \"expires_at\": $expires_at, \"used\": false, \"used_by\": \"\"}"
        if [[ "$invites" == "[]" ]]; then
            _api_write_auth_file "invites.json" "[$entry]"
        else
            local trimmed="${invites%]}"
            _api_write_auth_file "invites.json" "${trimmed}, $entry]"
        fi
    fi
}

# Validate an invite code — returns role on success, empty on failure
_api_validate_invite() {
    local code="$1"
    local invites
    invites=$(_api_read_auth_file "invites.json")
    local now
    now=$(_api_now_epoch)

    if command -v jq >/dev/null 2>&1; then
        local record
        record=$(echo "$invites" | jq -r --arg c "$code" --argjson n "$now" \
            '.[] | select(.code == $c and .expires_at > $n and (.used != true))' 2>/dev/null)
        if [[ -n "$record" ]]; then
            echo "$record" | jq -r '.role' 2>/dev/null
            return 0
        fi
    else
        if echo "$invites" | grep -q "\"code\": *\"$code\""; then
            echo "user"
            return 0
        fi
    fi
    return 1
}

# Consume an invite code after use — marks as used instead of deleting
_api_consume_invite() {
    local code="$1" username="${2:-unknown}"
    local invites
    invites=$(_api_read_auth_file "invites.json")

    if command -v jq >/dev/null 2>&1; then
        local new_invites
        new_invites=$(echo "$invites" | jq --arg c "$code" --arg u "$username" \
            '[.[] | if .code == $c then . + {"used": true, "used_by": $u} else . end]' 2>/dev/null)
        _api_write_auth_file "invites.json" "$new_invites"
    fi
}

# Delete a specific invite code by value
_api_delete_invite() {
    local code="$1"
    local invites
    invites=$(_api_read_auth_file "invites.json")

    if command -v jq >/dev/null 2>&1; then
        local exists
        exists=$(echo "$invites" | jq -r --arg c "$code" '[.[] | select(.code == $c)] | length' 2>/dev/null)
        if [[ "$exists" -eq 0 ]]; then
            return 1
        fi
        local new_invites
        new_invites=$(echo "$invites" | jq --arg c "$code" '[.[] | select(.code != $c)]' 2>/dev/null)
        _api_write_auth_file "invites.json" "$new_invites"
        return 0
    fi
    return 1
}

# Revoke all tokens for a user
_api_revoke_user_tokens() {
    local username="$1"
    local tokens
    tokens=$(_api_read_auth_file "tokens.json")

    if command -v jq >/dev/null 2>&1; then
        local new_tokens
        new_tokens=$(echo "$tokens" | jq --arg u "$username" '[.[] | select(.username != $u)]' 2>/dev/null)
        _api_write_auth_file "tokens.json" "$new_tokens"
    fi
}

# =============================================================================
# DATA COLLECTION HELPERS
# =============================================================================

# Get all stack names
_api_get_stacks() {
    local -a stacks=()
    for dir in "$COMPOSE_DIR"/*/; do
        [[ -f "${dir}docker-compose.yml" ]] && stacks+=("$(basename "$dir")")
    done
    echo "${stacks[@]}"
}

# Get stack status: RUNNING (with count) or STOPPED
_api_stack_status() {
    local stack="$1"
    local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
    local env_file="$COMPOSE_DIR/$stack/.env"

    local -a args=(-f "$compose_file")
    [[ -f "$env_file" ]] && args+=(--env-file "$env_file")

    local count
    count=$($DOCKER_COMPOSE_CMD "${args[@]}" ps -q 2>/dev/null | wc -l)
    if [[ "$count" -gt 0 ]]; then
        echo "running:$count"
    else
        echo "stopped:0"
    fi
}

# Get container details as JSON array entry
_api_container_json() {
    local container_id="$1"
    local name state health image created status

    name=$(docker inspect --format='{{.Name}}' "$container_id" 2>/dev/null | sed 's|^/||')
    state=$(docker inspect --format='{{.State.Status}}' "$container_id" 2>/dev/null)
    health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id" 2>/dev/null)
    image=$(docker inspect --format='{{.Config.Image}}' "$container_id" 2>/dev/null)
    created=$(docker inspect --format='{{.Created}}' "$container_id" 2>/dev/null)
    status=$(docker inspect --format='{{.State.Status}}' "$container_id" 2>/dev/null)

    local started_at uptime_seconds=0
    started_at=$(docker inspect --format='{{.State.StartedAt}}' "$container_id" 2>/dev/null)
    if [[ -n "$started_at" ]] && [[ "$started_at" != "0001-01-01T00:00:00Z" ]]; then
        local start_epoch now_epoch
        start_epoch=$(date -d "$started_at" +%s 2>/dev/null) || start_epoch=0
        now_epoch=$(date +%s)
        uptime_seconds=$(( now_epoch - start_epoch ))
    fi

    local ports
    ports=$(_api_json_escape "$(docker inspect --format='{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{range $i, $b := $conf}}{{if $i}}, {{end}}{{if $b.HostIp}}{{$b.HostIp}}{{else}}0.0.0.0{{end}}:{{$b.HostPort}}->{{$p}}{{end}}{{end}}{{end}}' "$container_id" 2>/dev/null)")

    local restart_count
    restart_count=$(docker inspect --format='{{.RestartCount}}' "$container_id" 2>/dev/null)

    local image_id
    image_id=$(docker inspect --format='{{.Image}}' "$container_id" 2>/dev/null)
    local image_id_short="${image_id:7:12}"

    printf '{"name": "%s", "state": "%s", "health": "%s", "image": "%s", "image_id": "%s", "created": "%s", "uptime_seconds": %d, "ports": "%s", "restart_count": %s}' \
        "$(_api_json_escape "$name")" \
        "$(_api_json_escape "$state")" \
        "$(_api_json_escape "$health")" \
        "$(_api_json_escape "$image")" \
        "$image_id_short" \
        "$(_api_json_escape "$created")" \
        "$uptime_seconds" \
        "$ports" \
        "${restart_count:-0}"
}

# =============================================================================
# ENDPOINT HANDLERS
# =============================================================================

handle_root() {
    local endpoints='[
    {"method": "GET",  "path": "/",                          "description": "API info and available endpoints"},
    {"method": "GET",  "path": "/status",                    "description": "Overall system status"},
    {"method": "GET",  "path": "/health",                    "description": "Container health report"},
    {"method": "GET",  "path": "/stacks",                    "description": "List all stacks with status"},
    {"method": "GET",  "path": "/stacks/:name",              "description": "Detailed info for a stack"},
    {"method": "GET",  "path": "/stacks/:name/containers",   "description": "Containers in a stack"},
    {"method": "GET",  "path": "/stacks/:name/logs",         "description": "Recent logs for a stack"},
    {"method": "GET",  "path": "/stacks/:name/compose",      "description": "Raw docker-compose.yml content"},
    {"method": "POST", "path": "/stacks/:name/start",        "description": "Start a stack"},
    {"method": "POST", "path": "/stacks/:name/stop",         "description": "Stop a stack"},
    {"method": "POST", "path": "/stacks/:name/restart",      "description": "Restart a stack"},
    {"method": "POST", "path": "/stacks/:name/update",       "description": "Pull, detect, recreate"},
    {"method": "GET",  "path": "/images",                    "description": "All images with metadata"},
    {"method": "GET",  "path": "/images/stale",              "description": "Only stale images older than 30 days"},
    {"method": "GET",  "path": "/containers",                "description": "All containers with status"},
    {"method": "GET",  "path": "/containers/:name",          "description": "Detailed container info"},
    {"method": "GET",  "path": "/containers/:name/stats",    "description": "Live resource stats"},
    {"method": "GET",  "path": "/containers/:name/processes","description": "Container process list"},
    {"method": "GET",  "path": "/config",                    "description": "Current configuration"},
    {"method": "GET",  "path": "/system",                    "description": "System resource info"},
    {"method": "GET",  "path": "/networks",                  "description": "Docker networks"},
    {"method": "GET",  "path": "/volumes",                   "description": "Docker volumes"},
    {"method": "GET",  "path": "/logs",                      "description": "Framework log tail"},
    {"method": "GET",  "path": "/events",                    "description": "Recent Docker events"},
    {"method": "GET",  "path": "/version",                   "description": "Version information"},
    {"method": "GET",    "path": "/setup/status",             "description": "Check if server needs first-run setup", "auth": false},
    {"method": "GET",    "path": "/setup/defaults",           "description": "Get setup defaults and system info", "auth": false},
    {"method": "POST",   "path": "/setup/configure",          "description": "Apply setup configuration", "auth": true},
    {"method": "POST",   "path": "/setup/complete",            "description": "Finalize first-run setup", "auth": true},
    {"method": "POST",   "path": "/stacks/rename",             "description": "Rename a stack directory", "auth": "admin"},
    {"method": "POST",   "path": "/stacks/reorder",            "description": "Set stack startup order", "auth": "admin"},
    {"method": "POST",   "path": "/auth/setup",              "description": "Create first admin account", "auth": false},
    {"method": "POST",   "path": "/auth/login",              "description": "Authenticate and get token", "auth": false},
    {"method": "POST",   "path": "/auth/register",           "description": "Register with invite code", "auth": false},
    {"method": "GET",    "path": "/auth/verify",             "description": "Verify a token", "auth": false},
    {"method": "POST",   "path": "/auth/invite",             "description": "Generate invite code", "auth": "admin"},
    {"method": "GET",    "path": "/auth/users",              "description": "List all users", "auth": "admin"},
    {"method": "POST",   "path": "/auth/revoke",             "description": "Revoke user access", "auth": "admin"},
    {"method": "GET",    "path": "/auth/invites",            "description": "List active invites", "auth": "admin"},
    {"method": "DELETE",  "path": "/auth/invite/:code",      "description": "Delete invite code", "auth": "admin"},
    {"method": "POST",   "path": "/auth/factory-reset",     "description": "Wipe auth state and return to setup wizard", "auth": "admin"},
    {"method": "POST",   "path": "/metrics/snapshot",        "description": "Capture system metrics snapshot"},
    {"method": "GET",    "path": "/metrics/trends",           "description": "Query metrics history (range: 1h|6h|24h|7d)"},
    {"method": "GET",    "path": "/images/check-updates",     "description": "Quick local image staleness check"},
    {"method": "POST",   "path": "/images/check-updates",     "description": "Registry check for image updates (slow)"},
    {"method": "POST",   "path": "/images/:name/update",      "description": "Pull image and restart containers"},
    {"method": "GET",    "path": "/notifications/rules",      "description": "List notification rules"},
    {"method": "POST",   "path": "/notifications/rules",      "description": "Create a notification rule"},
    {"method": "DELETE", "path": "/notifications/rules/:id",  "description": "Delete a notification rule"},
    {"method": "GET",    "path": "/notifications/history",    "description": "Notification send history"},
    {"method": "POST",   "path": "/notifications/test",       "description": "Send a test NTFY notification"},
    {"method": "GET",    "path": "/snapshots",                "description": "List all config snapshots"},
    {"method": "POST",   "path": "/snapshots/create",         "description": "Create a new config snapshot"},
    {"method": "GET",    "path": "/snapshots/:id/download",   "description": "Download a snapshot archive"},
    {"method": "POST",   "path": "/snapshots/:id/restore",    "description": "Restore from a snapshot"},
    {"method": "DELETE", "path": "/snapshots/:id",            "description": "Delete a snapshot"},
    {"method": "GET",    "path": "/stacks/:name/compose/history", "description": "Compose file version history"},
    {"method": "POST",   "path": "/stacks/:name/compose/rollback", "description": "Rollback compose to a previous version"},
    {"method": "GET",    "path": "/templates",                "description": "List available templates"},
    {"method": "GET",    "path": "/templates/:name",          "description": "Template detail with compose content"},
    {"method": "POST",   "path": "/templates/:name/deploy",   "description": "Deploy a template to a new stack"},
    {"method": "POST",   "path": "/templates/import",         "description": "Import a custom template"},
    {"method": "POST",   "path": "/templates/:name/update",   "description": "Update an existing template"},
    {"method": "DELETE", "path": "/templates/:name",           "description": "Delete a template"},
    {"method": "GET",    "path": "/automations",              "description": "List automation rules"},
    {"method": "POST",   "path": "/automations",              "description": "Create an automation rule"},
    {"method": "POST",   "path": "/automations/:id/update",   "description": "Update an automation rule"},
    {"method": "DELETE", "path": "/automations/:id",          "description": "Delete an automation rule"},
    {"method": "GET",    "path": "/automations/:id/history",  "description": "Automation run history"},
    {"method": "GET",    "path": "/topology",                 "description": "Network topology graph data"},
    {"method": "GET",    "path": "/auth/sessions",            "description": "List active sessions", "auth": "admin"},
    {"method": "DELETE", "path": "/auth/sessions/:prefix",    "description": "Revoke a session by token prefix", "auth": "admin"},
    {"method": "GET",    "path": "/system/update/check",     "description": "Check for available DCS updates via git"},
    {"method": "POST",   "path": "/system/update/apply",     "description": "Apply update safely with backup tag"},
    {"method": "POST",   "path": "/system/update/rollback",  "description": "Rollback to a previous backup tag"}
  ]'

    _api_success "{\"name\": \"Docker Compose Skeleton API\", \"version\": \"$API_VERSION\", \"auth_enabled\": $API_AUTH_ENABLED, \"endpoints\": $endpoints}"
}

handle_version() {
    local docker_version compose_version
    docker_version=$(_api_json_escape "$(docker --version 2>/dev/null)")
    compose_version=$(_api_json_escape "$($DOCKER_COMPOSE_CMD version 2>/dev/null)")

    _api_success "{\"api_version\": \"$API_VERSION\", \"framework_version\": \"${SCRIPT_VERSION:-2.0.0}\", \"docker_version\": \"$docker_version\", \"compose_version\": \"$compose_version\", \"compose_command\": \"$DOCKER_COMPOSE_CMD\"}"
}

handle_status() {
    local total_containers running_containers stopped_containers
    total_containers=$(docker ps -a -q 2>/dev/null | wc -l)
    running_containers=$(docker ps -q 2>/dev/null | wc -l)
    stopped_containers=$(( total_containers - running_containers ))

    local total_images
    total_images=$(docker images -q 2>/dev/null | wc -l)

    local total_volumes
    total_volumes=$(docker volume ls -q 2>/dev/null | wc -l)

    local total_networks
    total_networks=$(docker network ls --format '{{.Name}}' 2>/dev/null | grep -cv '^bridge$\|^host$\|^none$' || echo 0)

    local disk_usage
    disk_usage=$(df -h / 2>/dev/null | tail -1 | awk '{printf "{\"total\": \"%s\", \"used\": \"%s\", \"available\": \"%s\", \"percent\": \"%s\"}", $2, $3, $4, $5}')

    local load_avg mem_total mem_available
    load_avg=$(awk '{printf "[%s, %s, %s]", $1, $2, $3}' /proc/loadavg 2>/dev/null || echo "[0,0,0]")
    mem_total=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    mem_available=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)

    local uptime_seconds
    uptime_seconds=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 0)

    # Fast stack status: run all checks in parallel subshells
    local stacks
    stacks=($(_api_get_stacks))
    local running_stacks=0
    local tmpdir
    tmpdir=$(mktemp -d)

    for s in "${stacks[@]}"; do
        (
            local compose_file="$COMPOSE_DIR/$s/docker-compose.yml"
            local env_file="$COMPOSE_DIR/$s/.env"
            local -a args=(-f "$compose_file")
            [[ -f "$env_file" ]] && args+=(--env-file "$env_file")
            local count
            count=$($DOCKER_COMPOSE_CMD "${args[@]}" ps -q 2>/dev/null | wc -l)
            echo "$count" > "$tmpdir/$s"
        ) &
    done
    wait

    for s in "${stacks[@]}"; do
        local count=0
        [[ -f "$tmpdir/$s" ]] && count=$(cat "$tmpdir/$s")
        [[ "$count" -gt 0 ]] && running_stacks=$(( running_stacks + 1 ))
    done
    rm -rf "$tmpdir"

    local cpu_count
    cpu_count=$(nproc 2>/dev/null || echo 0)

    _api_success "{\"timestamp\": \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\", \"hostname\": \"$(hostname)\", \"uptime_seconds\": $uptime_seconds, \"docker\": {\"containers\": {\"total\": $total_containers, \"running\": $running_containers, \"stopped\": $stopped_containers}, \"images\": $total_images, \"volumes\": $total_volumes, \"networks\": $total_networks}, \"stacks\": {\"total\": ${#stacks[@]}, \"running\": $running_stacks}, \"system\": {\"load_average\": $load_avg, \"memory_mb\": {\"total\": $mem_total, \"available\": $mem_available}, \"disk\": $disk_usage, \"cpu_count\": $cpu_count}}"
}

handle_health() {
    local -a results=()
    local total=0 healthy=0 unhealthy=0 stopped=0

    while IFS= read -r cid; do
        [[ -z "$cid" ]] && continue
        total=$(( total + 1 ))

        local name state health
        name=$(docker inspect --format='{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
        state=$(docker inspect --format='{{.State.Status}}' "$cid" 2>/dev/null)
        health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null)

        if [[ "$state" != "running" ]]; then
            stopped=$(( stopped + 1 ))
        elif [[ "$health" == "unhealthy" ]]; then
            unhealthy=$(( unhealthy + 1 ))
        else
            healthy=$(( healthy + 1 ))
        fi

        results+=("{\"name\": \"$(_api_json_escape "$name")\", \"state\": \"$state\", \"health\": \"$health\"}")
    done < <(docker ps -a -q 2>/dev/null)

    # Status logic: stopped containers are expected/normal and don't affect health.
    # Only actually unhealthy containers (failed healthchecks) trigger warnings.
    local overall="healthy"
    if (( unhealthy >= 3 )); then
        overall="critical"
    elif (( unhealthy > 0 )); then
        overall="degraded"
    fi

    local containers_json
    containers_json=$(printf '%s,' "${results[@]}")
    containers_json="[${containers_json%,}]"

    # API server metrics: uptime, request/error counts, memory usage
    local api_uptime=0 api_requests=0 api_errors=0
    local now_epoch
    now_epoch=$(date +%s)
    api_uptime=$(( now_epoch - ${API_START_EPOCH:-now_epoch} ))

    if [[ -f "$API_STATS_FILE" ]]; then
        api_requests=$(sed -n '1p' "$API_STATS_FILE" 2>/dev/null || echo 0)
        api_errors=$(sed -n '2p' "$API_STATS_FILE" 2>/dev/null || echo 0)
    fi

    # API process memory (RSS in KB)
    local api_pid_val api_mem_kb=0
    if [[ -f "$API_PID_FILE" ]]; then
        api_pid_val=$(cat "$API_PID_FILE" 2>/dev/null)
        if [[ -n "$api_pid_val" ]] && kill -0 "$api_pid_val" 2>/dev/null; then
            api_mem_kb=$(ps -o rss= -p "$api_pid_val" 2>/dev/null | tr -d ' ' || echo 0)
        fi
    fi

    _api_success "{\"status\": \"$overall\", \"summary\": {\"total\": $total, \"healthy\": $healthy, \"unhealthy\": $unhealthy, \"stopped\": $stopped}, \"containers\": $containers_json, \"api\": {\"uptime_seconds\": $api_uptime, \"requests_total\": ${api_requests:-0}, \"errors_total\": ${api_errors:-0}, \"memory_kb\": ${api_mem_kb:-0}, \"pid\": ${api_pid_val:-0}}}"
}

handle_stacks() {
    local stacks
    stacks=($(_api_get_stacks))

    local -a entries=()
    for stack in "${stacks[@]}"; do
        local st
        st=$(_api_stack_status "$stack")
        local status="${st%%:*}"
        local count="${st#*:}"

        local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
        local has_env="false"
        [[ -f "$COMPOSE_DIR/$stack/.env" ]] && has_env="true"

        # Count services defined in compose file
        local service_count
        service_count=$(grep -c '^\s\+[a-zA-Z]' "$compose_file" 2>/dev/null || echo 0)

        entries+=("{\"name\": \"$stack\", \"status\": \"$status\", \"running_containers\": $count, \"has_env\": $has_env, \"compose_file\": \"$compose_file\"}")
    done

    local json
    json=$(printf '%s,' "${entries[@]}")
    json="[${json%,}]"

    _api_success "{\"total\": ${#stacks[@]}, \"stacks\": $json}"
}

handle_stack_detail() {
    local stack="$1"
    local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
    local env_file="$COMPOSE_DIR/$stack/.env"

    if [[ ! -f "$compose_file" ]]; then
        _api_error 404 "Stack not found: $stack"
        return
    fi

    local -a compose_args=(-f "$compose_file")
    [[ -f "$env_file" ]] && compose_args+=(--env-file "$env_file")

    local st
    st=$(_api_stack_status "$stack")
    local status="${st%%:*}"
    local count="${st#*:}"

    # Get services from config
    local -a services=()
    while IFS= read -r svc; do
        [[ -n "$svc" ]] && services+=("\"$(_api_json_escape "$svc")\"")
    done < <($DOCKER_COMPOSE_CMD "${compose_args[@]}" config --services 2>/dev/null)

    local services_json
    services_json=$(printf '%s,' "${services[@]}")
    services_json="[${services_json%,}]"

    # Get containers
    local -a container_entries=()
    while IFS= read -r cid; do
        [[ -z "$cid" ]] && continue
        container_entries+=("$(_api_container_json "$cid")")
    done < <($DOCKER_COMPOSE_CMD "${compose_args[@]}" ps -q 2>/dev/null)

    local containers_json
    containers_json=$(printf '%s,' "${container_entries[@]}")
    containers_json="[${containers_json%,}]"

    # Get images used
    local -a image_entries=()
    while IFS= read -r img; do
        [[ -z "$img" ]] && continue
        local img_id size
        img_id=$(docker image inspect --format='{{.Id}}' "$img" 2>/dev/null)
        size=$(docker image inspect --format='{{.Size}}' "$img" 2>/dev/null)
        image_entries+=("{\"name\": \"$(_api_json_escape "$img")\", \"id\": \"${img_id:7:12}\", \"size\": ${size:-0}}")
    done < <($DOCKER_COMPOSE_CMD "${compose_args[@]}" config 2>/dev/null | grep 'image:' | awk '{print $2}' | sort -u)

    local images_json
    images_json=$(printf '%s,' "${image_entries[@]}")
    images_json="[${images_json%,}]"

    _api_success "{\"name\": \"$stack\", \"status\": \"$status\", \"running_containers\": $count, \"has_env\": $([[ -f "$env_file" ]] && echo true || echo false), \"services\": $services_json, \"containers\": $containers_json, \"images\": $images_json}"
}

handle_stack_containers() {
    local stack="$1"
    local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
    local env_file="$COMPOSE_DIR/$stack/.env"

    if [[ ! -f "$compose_file" ]]; then
        _api_error 404 "Stack not found: $stack"
        return
    fi

    local -a compose_args=(-f "$compose_file")
    [[ -f "$env_file" ]] && compose_args+=(--env-file "$env_file")

    local -a entries=()
    while IFS= read -r cid; do
        [[ -z "$cid" ]] && continue
        entries+=("$(_api_container_json "$cid")")
    done < <($DOCKER_COMPOSE_CMD "${compose_args[@]}" ps -q 2>/dev/null)

    local json
    json=$(printf '%s,' "${entries[@]}")
    json="[${json%,}]"

    _api_success "{\"stack\": \"$stack\", \"containers\": $json}"
}

handle_stack_logs() {
    local stack="$1"
    local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
    local env_file="$COMPOSE_DIR/$stack/.env"

    if [[ ! -f "$compose_file" ]]; then
        _api_error 404 "Stack not found: $stack"
        return
    fi

    local -a compose_args=(-f "$compose_file")
    [[ -f "$env_file" ]] && compose_args+=(--env-file "$env_file")

    local logs_raw
    logs_raw=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" logs --tail 50 --no-color 2>&1)
    local escaped
    escaped=$(_api_json_escape "$logs_raw")

    _api_success "{\"stack\": \"$stack\", \"lines\": 50, \"logs\": \"$escaped\"}"
}

handle_stack_compose() {
    local stack="$1"
    local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"

    if [[ ! -f "$compose_file" ]]; then
        _api_error 404 "Stack not found: $stack"
        return
    fi

    local content
    content=$(cat "$compose_file" 2>/dev/null) || {
        _api_error 500 "Failed to read compose file for stack: $stack"
        return
    }

    local escaped
    escaped=$(_api_json_escape "$content")

    _api_success "{\"stack\": \"$(_api_json_escape "$stack")\", \"content\": \"$escaped\"}"
}

# =============================================================================
# COMPOSE EDITOR & STACK ENV HANDLERS (Phase 1)
# =============================================================================

handle_stack_compose_validate() {
    local stack="$1"
    local body="$2"

    if [[ ! -d "$COMPOSE_DIR/$stack" ]]; then
        _api_error 404 "Stack not found: $stack"
        return
    fi

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for compose validation"
        return
    fi

    local content
    content=$(printf '%s' "$body" | jq -r '.content // empty' 2>/dev/null)
    if [[ -z "$content" ]]; then
        _api_error 400 "Missing 'content' field in request body"
        return
    fi

    local tmpfile
    tmpfile=$(mktemp /tmp/dcs-compose-validate-XXXXXX.yml)
    printf '%s' "$content" > "$tmpfile"

    local env_args=()
    if [[ -f "$COMPOSE_DIR/$stack/.env" ]]; then
        env_args=(--env-file "$COMPOSE_DIR/$stack/.env")
    fi

    local validation_output
    local valid=true
    validation_output=$($DOCKER_COMPOSE_CMD -f "$tmpfile" "${env_args[@]}" config 2>&1) || valid=false
    rm -f "$tmpfile"

    local escaped_output
    escaped_output=$(_api_json_escape "$validation_output")

    _api_success "{\"valid\": $valid, \"stack\": \"$(_api_json_escape "$stack")\", \"output\": \"$escaped_output\"}"
}

handle_stack_compose_save() {
    local stack="$1"
    local body="$2"
    local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"

    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    if [[ ! -d "$COMPOSE_DIR/$stack" ]]; then
        _api_error 404 "Stack not found: $stack"
        return
    fi

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for compose save"
        return
    fi

    local content
    content=$(printf '%s' "$body" | jq -r '.content // empty' 2>/dev/null)
    if [[ -z "$content" ]]; then
        _api_error 400 "Missing 'content' field in request body"
        return
    fi

    # Validate before saving
    local tmpfile
    tmpfile=$(mktemp /tmp/dcs-compose-save-XXXXXX.yml)
    printf '%s' "$content" > "$tmpfile"

    local env_args=()
    if [[ -f "$COMPOSE_DIR/$stack/.env" ]]; then
        env_args=(--env-file "$COMPOSE_DIR/$stack/.env")
    fi

    local validation_output
    validation_output=$($DOCKER_COMPOSE_CMD -f "$tmpfile" "${env_args[@]}" config 2>&1)
    local valid=$?
    rm -f "$tmpfile"

    if [[ $valid -ne 0 ]]; then
        local escaped_errors
        escaped_errors=$(_api_json_escape "$validation_output")
        _api_success "{\"success\": false, \"stack\": \"$(_api_json_escape "$stack")\", \"message\": \"Validation failed\", \"validated\": false, \"validation_errors\": \"$escaped_errors\"}"
        return
    fi

    # Backup original
    if [[ -f "$compose_file" ]]; then
        cp "$compose_file" "${compose_file}.bak" 2>/dev/null
        # Save version history before overwriting
        _save_compose_version "$stack"
    fi

    # Write new content
    printf '%s' "$content" > "$compose_file" 2>/dev/null || {
        _api_error 500 "Failed to write compose file"
        return
    }

    _api_success "{\"success\": true, \"stack\": \"$(_api_json_escape "$stack")\", \"message\": \"Compose file saved successfully\", \"validated\": true}"
}

handle_stack_env() {
    local stack="$1"
    local env_file="$COMPOSE_DIR/$stack/.env"

    if [[ ! -d "$COMPOSE_DIR/$stack" ]]; then
        _api_error 404 "Stack not found: $stack"
        return
    fi

    if [[ ! -f "$env_file" ]]; then
        _api_success "{\"stack\": \"$(_api_json_escape "$stack")\", \"raw\": \"\", \"variables\": []}"
        return
    fi

    local raw
    raw=$(cat "$env_file" 2>/dev/null)
    local escaped_raw
    escaped_raw=$(_api_json_escape "$raw")

    local -a vars=()
    local line_num=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        (( line_num++ ))
        if [[ -z "$line" ]]; then
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]*# ]]; then
            vars+=("{\"key\": \"\", \"value\": \"\", \"line\": $line_num, \"comment\": \"$(_api_json_escape "$line")\"}")
            continue
        fi
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            value="${value#\"}" ; value="${value%\"}"
            value="${value#\'}" ; value="${value%\'}"
            vars+=("{\"key\": \"$(_api_json_escape "$key")\", \"value\": \"$(_api_json_escape "$value")\", \"line\": $line_num, \"comment\": \"\"}")
        fi
    done < "$env_file"

    local vars_json
    if [[ ${#vars[@]} -gt 0 ]]; then
        vars_json=$(printf '%s,' "${vars[@]}")
        vars_json="[${vars_json%,}]"
    else
        vars_json="[]"
    fi

    _api_success "{\"stack\": \"$(_api_json_escape "$stack")\", \"raw\": \"$escaped_raw\", \"variables\": $vars_json}"
}

handle_stack_env_save() {
    local stack="$1"
    local body="$2"
    local env_file="$COMPOSE_DIR/$stack/.env"

    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    if [[ ! -d "$COMPOSE_DIR/$stack" ]]; then
        _api_error 404 "Stack not found: $stack"
        return
    fi

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for env save"
        return
    fi

    local content
    content=$(printf '%s' "$body" | jq -r '.content // empty' 2>/dev/null)
    if [[ -z "$content" ]]; then
        _api_error 400 "Missing 'content' field in request body"
        return
    fi

    # Backup existing
    if [[ -f "$env_file" ]]; then
        cp "$env_file" "${env_file}.bak" 2>/dev/null
    fi

    printf '%s' "$content" > "$env_file" 2>/dev/null || {
        _api_error 500 "Failed to write .env file"
        return
    }

    _api_success "{\"success\": true, \"stack\": \"$(_api_json_escape "$stack")\", \"message\": \"Stack .env file saved successfully\"}"
}

handle_stack_action() {
    local stack="$1"
    local action="$2"
    local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
    local env_file="$COMPOSE_DIR/$stack/.env"

    if [[ ! -f "$compose_file" ]]; then
        _api_error 404 "Stack not found: $stack"
        return
    fi

    local -a compose_args=(-f "$compose_file")
    [[ -f "$env_file" ]] && compose_args+=(--env-file "$env_file")

    local output=""
    local success=true

    case "$action" in
        start)
            output=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" up -d --remove-orphans 2>&1) || success=false
            ;;
        stop)
            output=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" down --remove-orphans --timeout 30 2>&1) || success=false
            ;;
        restart)
            output=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" down --remove-orphans --timeout 30 2>&1) || true
            output+=$'\n'
            output+=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" up -d --remove-orphans 2>&1) || success=false
            ;;
        update)
            # Record pre-update IDs
            local -A pre_ids=()
            while IFS= read -r img; do
                [[ -z "$img" ]] && continue
                local cid
                cid=$(docker image inspect --format='{{.Id}}' "$img" 2>/dev/null)
                [[ -n "$cid" ]] && pre_ids["$img"]="$cid"
            done < <($DOCKER_COMPOSE_CMD "${compose_args[@]}" config 2>/dev/null | grep 'image:' | awk '{print $2}' | sort -u)

            # Pull
            output=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" pull 2>&1) || success=false

            # Compare
            local changes_found=false
            local -a changes=()
            for img in "${!pre_ids[@]}"; do
                local new_id
                new_id=$(docker image inspect --format='{{.Id}}' "$img" 2>/dev/null)
                if [[ "${pre_ids[$img]}" != "$new_id" ]]; then
                    changes_found=true
                    changes+=("$img")
                fi
            done

            if [[ "$changes_found" == "true" ]] && [[ "$success" == "true" ]]; then
                output+=$'\n'
                output+=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" up -d --remove-orphans 2>&1) || success=false
            fi

            local changes_json
            changes_json=$(printf '"%s",' "${changes[@]}")
            changes_json="[${changes_json%,}]"

            local escaped_output
            escaped_output=$(_api_json_escape "$output")
            _api_success "{\"stack\": \"$stack\", \"action\": \"update\", \"success\": $success, \"changes_detected\": $changes_found, \"changed_images\": $changes_json, \"output\": \"$escaped_output\"}"
            return
            ;;
    esac

    local escaped_output
    escaped_output=$(_api_json_escape "$output")
    _api_success "{\"stack\": \"$stack\", \"action\": \"$action\", \"success\": $success, \"output\": \"$escaped_output\"}"
}

handle_images() {
    local stale_only="${1:-false}"

    local -a entries=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS='|' read -r repo tag id created size <<< "$line"

        local age_days=-1
        local staleness="unknown"
        if [[ -n "$created" ]] && [[ "$created" != "<none>" ]]; then
            local img_epoch
            img_epoch=$(date -d "$created" '+%s' 2>/dev/null || echo 0)
            if [[ "$img_epoch" -gt 0 ]]; then
                local now_epoch
                now_epoch=$(date '+%s')
                age_days=$(( (now_epoch - img_epoch) / 86400 ))
                if [[ $age_days -lt 7 ]]; then staleness="current"
                elif [[ $age_days -lt 30 ]]; then staleness="aging"
                else staleness="stale"
                fi
            fi
        fi

        if [[ "$stale_only" == "true" ]] && [[ "$staleness" != "stale" ]]; then
            continue
        fi

        entries+=("{\"repository\": \"$(_api_json_escape "$repo")\", \"tag\": \"$(_api_json_escape "$tag")\", \"id\": \"$(_api_json_escape "$id")\", \"created\": \"$(_api_json_escape "$created")\", \"size\": \"$(_api_json_escape "$size")\", \"age_days\": $age_days, \"staleness\": \"$staleness\"}")
    done < <(docker images --format '{{.Repository}}|{{.Tag}}|{{.ID}}|{{.CreatedAt}}|{{.Size}}' 2>/dev/null)

    local json
    json=$(printf '%s,' "${entries[@]}")
    json="[${json%,}]"

    _api_success "{\"total\": ${#entries[@]}, \"images\": $json}"
}

handle_containers() {
    local -a entries=()

    while IFS= read -r cid; do
        [[ -z "$cid" ]] && continue
        entries+=("$(_api_container_json "$cid")")
    done < <(docker ps -a -q 2>/dev/null)

    local json
    json=$(printf '%s,' "${entries[@]}")
    json="[${json%,}]"

    _api_success "{\"total\": ${#entries[@]}, \"containers\": $json}"
}

handle_container_detail() {
    local name="$1"

    if ! docker inspect "$name" >/dev/null 2>&1; then
        _api_error 404 "Container not found: $name"
        return
    fi

    local cid
    cid=$(docker inspect --format='{{.Id}}' "$name" 2>/dev/null)

    local full_json
    full_json=$(_api_container_json "$cid")

    # Add extra detail: environment, mounts, networks, IP addresses
    local env_json mounts_json networks_json ip_json
    env_json=$(_api_json_escape "$(docker inspect --format='{{range .Config.Env}}{{.}}
{{end}}' "$name" 2>/dev/null)")
    mounts_json=$(_api_json_escape "$(docker inspect --format='{{range .Mounts}}{{.Source}}:{{.Destination}}{{if .Mode}}:{{.Mode}}{{end}}
{{end}}' "$name" 2>/dev/null)")
    networks_json=$(_api_json_escape "$(docker inspect --format='{{range $k, $v := .NetworkSettings.Networks}}{{$k}}
{{end}}' "$name" 2>/dev/null)")
    ip_json=$(_api_json_escape "$(docker inspect --format='{{range $k, $v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}}
{{end}}' "$name" 2>/dev/null)")

    # Platform, restart policy, hostname, working dir
    local platform hostname workdir restart_policy
    platform=$(docker inspect --format='{{.Platform}}' "$name" 2>/dev/null)
    hostname=$(docker inspect --format='{{.Config.Hostname}}' "$name" 2>/dev/null)
    workdir=$(docker inspect --format='{{.Config.WorkingDir}}' "$name" 2>/dev/null)
    restart_policy=$(docker inspect --format='{{.HostConfig.RestartPolicy.Name}}' "$name" 2>/dev/null)

    # Reconstruct with extra fields
    # Remove closing brace and append
    full_json="${full_json%\}}"
    full_json+=", \"environment\": \"$env_json\", \"mounts\": \"$mounts_json\", \"networks\": \"$networks_json\", \"ip_addresses\": \"$(_api_json_escape "$ip_json")\", \"platform\": \"$(_api_json_escape "${platform:-linux}")\", \"hostname\": \"$(_api_json_escape "$hostname")\", \"working_dir\": \"$(_api_json_escape "$workdir")\", \"restart_policy\": \"$(_api_json_escape "$restart_policy")\"}"

    _api_success "$full_json"
}

handle_container_stats() {
    local name="$1"

    if ! docker inspect "$name" >/dev/null 2>&1; then
        _api_error 404 "Container not found: $name"
        return
    fi

    local stats_line
    stats_line=$(docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}|{{.BlockIO}}|{{.PIDs}}' "$name" 2>/dev/null)

    IFS='|' read -r cpu mem_usage mem_perc net_io block_io pids <<< "$stats_line"

    _api_success "{\"container\": \"$name\", \"cpu_percent\": \"$(_api_json_escape "$cpu")\", \"memory_usage\": \"$(_api_json_escape "$mem_usage")\", \"memory_percent\": \"$(_api_json_escape "$mem_perc")\", \"network_io\": \"$(_api_json_escape "$net_io")\", \"block_io\": \"$(_api_json_escape "$block_io")\", \"pids\": \"$(_api_json_escape "$pids")\"}"
}

handle_container_processes() {
    local name="$1"

    if ! docker inspect "$name" >/dev/null 2>&1; then
        _api_error 404 "Container not found: $name"
        return
    fi

    # Verify the container is running (docker top requires a running container)
    local state
    state=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null)
    if [[ "$state" != "running" ]]; then
        _api_error 400 "Container is not running: $name (state: $state)"
        return
    fi

    local top_output
    top_output=$(docker top "$name" -eo uid,pid,ppid,%cpu,time,cmd 2>&1) || {
        _api_error 500 "Failed to get processes: $(_api_json_escape "$top_output")"
        return
    }

    local -a entries=()
    local header_skipped=false
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Skip the header line
        if [[ "$header_skipped" == "false" ]]; then
            header_skipped=true
            continue
        fi

        # Parse columns: UID PID PPID %CPU TIME CMD (CMD may contain spaces)
        local uid pid ppid cpu time cmd
        read -r uid pid ppid cpu time cmd <<< "$line"

        entries+=("{\"uid\": \"$(_api_json_escape "$uid")\", \"pid\": \"$(_api_json_escape "$pid")\", \"ppid\": \"$(_api_json_escape "$ppid")\", \"cpu\": \"$(_api_json_escape "$cpu")\", \"time\": \"$(_api_json_escape "$time")\", \"cmd\": \"$(_api_json_escape "$cmd")\"}")
    done <<< "$top_output"

    local json
    json=$(printf '%s,' "${entries[@]}")
    json="[${json%,}]"

    _api_success "{\"container\": \"$(_api_json_escape "$name")\", \"processes\": $json}"
}

handle_config() {
    # Return sanitized configuration (exclude passwords/secrets)
    local config="{"
    config+="\"environment\": \"${ENVIRONMENT:-production}\","
    config+="\"log_level\": \"${LOG_LEVEL:-INFO}\","
    config+="\"compose_dir\": \"$(_api_json_escape "$COMPOSE_DIR")\","
    config+="\"app_data_dir\": \"$(_api_json_escape "$APP_DATA_DIR")\","
    config+="\"base_dir\": \"$(_api_json_escape "$BASE_DIR")\","
    config+="\"compose_command\": \"$DOCKER_COMPOSE_CMD\","
    config+="\"skip_healthcheck_wait\": ${SKIP_HEALTHCHECK_WAIT:-false},"
    config+="\"continue_on_failure\": ${CONTINUE_ON_FAILURE:-true},"
    config+="\"remove_volumes_on_stop\": ${REMOVE_VOLUMES_ON_STOP:-false},"
    config+="\"aggressive_image_prune\": ${AGGRESSIVE_IMAGE_PRUNE:-false},"
    config+="\"update_notification\": ${UPDATE_NOTIFICATION:-true},"
    config+="\"show_banners\": ${SHOW_BANNERS:-true},"
    config+="\"api_port\": $API_PORT,"
    config+="\"api_bind\": \"$API_BIND\","
    config+="\"ntfy_configured\": $([[ -n "${NTFY_URL:-}" ]] && echo true || echo false),"
    config+="\"ntfy_url\": \"$(_api_json_escape "${NTFY_URL:-}")\","
    config+="\"ntfy_topic\": \"$(_api_json_escape "${NTFY_TOPIC:-}")\","
    config+="\"ntfy_priority\": \"$(_api_json_escape "${NTFY_PRIORITY:-default}")\","
    config+="\"enable_colors\": ${ENABLE_COLORS:-true},"
    config+="\"color_mode\": \"${COLOR_MODE:-auto}\","
    config+="\"api_enabled\": ${API_ENABLED:-true},"
    config+="\"server_name\": \"$(_api_json_escape "${SERVER_NAME:-Docker Server}")\","
    config+="\"timezone\": \"${TZ:-UTC}\""
    config+="}"

    _api_success "$config"
}

handle_system() {
    local docker_info
    docker_info=$(docker system df --format '{{.Type}}|{{.TotalCount}}|{{.Active}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null)

    local -a df_entries=()
    while IFS='|' read -r type total active size reclaimable; do
        [[ -z "$type" ]] && continue
        df_entries+=("{\"type\": \"$(_api_json_escape "$type")\", \"total\": \"$(_api_json_escape "$total")\", \"active\": \"$(_api_json_escape "$active")\", \"size\": \"$(_api_json_escape "$size")\", \"reclaimable\": \"$(_api_json_escape "$reclaimable")\"}")
    done <<< "$docker_info"

    local df_json
    df_json=$(printf '%s,' "${df_entries[@]}")
    df_json="[${df_json%,}]"

    local cpu_count mem_total_mb swap_total_mb kernel_version
    cpu_count=$(nproc 2>/dev/null || echo 0)
    mem_total_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    swap_total_mb=$(awk '/SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    kernel_version=$(_api_json_escape "$(uname -r 2>/dev/null)")

    local docker_version
    docker_version=$(_api_json_escape "$(docker --version 2>/dev/null)")

    _api_success "{\"hostname\": \"$(hostname)\", \"kernel\": \"$kernel_version\", \"cpu_count\": $cpu_count, \"memory_total_mb\": $mem_total_mb, \"swap_total_mb\": $swap_total_mb, \"docker_version\": \"$docker_version\", \"docker_disk_usage\": $df_json}"
}

handle_disks() {
    local -a disk_entries=()
    # Parse df output handling mount paths with spaces (e.g. "/media/user/Dev Drive")
    # Split each line into words — last 4 are always size/used/avail/percent,
    # first word is device, everything between is the mount path
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local -a fields
        read -ra fields <<< "$line"
        local nf=${#fields[@]}
        [[ $nf -lt 6 ]] && continue

        local percent="${fields[$((nf-1))]}"
        local available="${fields[$((nf-2))]}"
        local used="${fields[$((nf-3))]}"
        local total="${fields[$((nf-4))]}"
        local device="${fields[0]}"
        # Reconstruct mount path from fields[1] to fields[nf-5]
        local mount=""
        local i
        for ((i=1; i<nf-4; i++)); do
            [[ -n "$mount" ]] && mount+=" "
            mount+="${fields[$i]}"
        done

        [[ -z "$device" || "$device" == "Filesystem" ]] && continue
        case "$mount" in
            /sys/*|/proc/*|/dev/*|/run/*|/snap/*|/boot/efi|/boot/grub) continue ;;
        esac
        [[ "$device" != /* ]] && continue
        disk_entries+=("{\"device\": \"$(_api_json_escape "$device")\", \"mount\": \"$(_api_json_escape "$mount")\", \"total\": \"$(_api_json_escape "$total")\", \"used\": \"$(_api_json_escape "$used")\", \"available\": \"$(_api_json_escape "$available")\", \"percent\": \"$(_api_json_escape "$percent")\"}")
    done < <(df -h --output=source,target,size,used,avail,pcent -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs -x vfat 2>/dev/null | tail -n +2)

    local json
    json=$(printf '%s,' "${disk_entries[@]}")
    json="[${json%,}]"

    _api_success "{\"total\": ${#disk_entries[@]}, \"disks\": $json}"
}

handle_networks() {
    local -a entries=()

    while IFS='|' read -r id name driver scope; do
        [[ -z "$id" ]] && continue

        # Get containers on this network
        local -a net_containers=()
        while IFS= read -r cname; do
            [[ -n "$cname" ]] && net_containers+=("\"$(_api_json_escape "$cname")\"")
        done < <(docker network inspect --format='{{range $k, $v := .Containers}}{{$v.Name}} {{end}}' "$id" 2>/dev/null | tr ' ' '\n' | grep -v '^$')

        local nc_json
        nc_json=$(printf '%s,' "${net_containers[@]}")
        nc_json="[${nc_json%,}]"

        entries+=("{\"id\": \"$(_api_json_escape "$id")\", \"name\": \"$(_api_json_escape "$name")\", \"driver\": \"$(_api_json_escape "$driver")\", \"scope\": \"$(_api_json_escape "$scope")\", \"containers\": $nc_json}")
    done < <(docker network ls --format '{{.ID}}|{{.Name}}|{{.Driver}}|{{.Scope}}' 2>/dev/null)

    local json
    json=$(printf '%s,' "${entries[@]}")
    json="[${json%,}]"

    _api_success "{\"total\": ${#entries[@]}, \"networks\": $json}"
}

handle_volumes() {
    local -a entries=()

    while IFS='|' read -r name driver mountpoint; do
        [[ -z "$name" ]] && continue

        local size="0"
        if [[ -d "$mountpoint" ]]; then
            size=$(du -sb "$mountpoint" 2>/dev/null | awk '{print $1}' || echo 0)
        fi

        entries+=("{\"name\": \"$(_api_json_escape "$name")\", \"driver\": \"$(_api_json_escape "$driver")\", \"mountpoint\": \"$(_api_json_escape "$mountpoint")\", \"size_bytes\": $size}")
    done < <(docker volume ls --format '{{.Name}}|{{.Driver}}|{{.Mountpoint}}' 2>/dev/null)

    local json
    json=$(printf '%s,' "${entries[@]}")
    json="[${json%,}]"

    _api_success "{\"total\": ${#entries[@]}, \"volumes\": $json}"
}

handle_create_network() {
    local body="$1"
    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for network creation"
        return
    fi

    local name driver subnet gateway internal
    name=$(echo "$body" | jq -r '.name // empty' 2>/dev/null)
    driver=$(echo "$body" | jq -r '.driver // "bridge"' 2>/dev/null)
    subnet=$(echo "$body" | jq -r '.subnet // empty' 2>/dev/null)
    gateway=$(echo "$body" | jq -r '.gateway // empty' 2>/dev/null)
    internal=$(echo "$body" | jq -r '.internal // false' 2>/dev/null)

    if [[ -z "$name" ]]; then
        _api_error 400 "Network name is required"
        return
    fi

    # Validate name (alphanumeric, hyphens, underscores)
    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        _api_error 400 "Invalid network name. Use alphanumeric characters, hyphens, underscores, and dots."
        return
    fi

    # Check if network already exists
    if docker network inspect "$name" >/dev/null 2>&1; then
        _api_error 409 "Network '$name' already exists"
        return
    fi

    # Build docker command
    local -a cmd=(docker network create --driver "$driver")
    if [[ -n "$subnet" ]]; then
        cmd+=(--subnet "$subnet")
    fi
    if [[ -n "$gateway" ]]; then
        cmd+=(--gateway "$gateway")
    fi
    if [[ "$internal" == "true" ]]; then
        cmd+=(--internal)
    fi
    cmd+=("$name")

    local output
    output=$("${cmd[@]}" 2>&1) || {
        _api_error 500 "Failed to create network: $(_api_json_escape "$output")"
        return
    }

    _api_success "{\"success\": true, \"name\": \"$(_api_json_escape "$name")\", \"driver\": \"$(_api_json_escape "$driver")\", \"message\": \"Network '$name' created successfully\"}"
}

handle_delete_network() {
    local name="$1"

    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    if [[ -z "$name" ]]; then
        _api_error 400 "Network name is required"
        return
    fi

    # Check if network exists
    if ! docker network inspect "$name" >/dev/null 2>&1; then
        _api_error 404 "Network '$name' not found"
        return
    fi

    # Prevent deleting built-in networks
    if [[ "$name" == "bridge" || "$name" == "host" || "$name" == "none" ]]; then
        _api_error 403 "Cannot delete built-in network '$name'"
        return
    fi

    # Check for connected containers
    local connected
    connected=$(docker network inspect --format='{{range $k, $v := .Containers}}{{$v.Name}} {{end}}' "$name" 2>/dev/null | tr ' ' '\n' | grep -v '^$' | wc -l || true)
    if [[ "$connected" -gt 0 ]]; then
        _api_error 409 "Network '$name' has $connected connected container(s). Disconnect them first."
        return
    fi

    local output
    output=$(docker network rm "$name" 2>&1) || {
        _api_error 500 "Failed to delete network: $(_api_json_escape "$output")"
        return
    }

    _api_success "{\"success\": true, \"name\": \"$(_api_json_escape "$name")\", \"message\": \"Network '$name' deleted successfully\"}"
}

handle_network_connect() {
    local name="$1" body="$2"
    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required"
        return
    fi

    local container
    container=$(echo "$body" | jq -r '.container // empty' 2>/dev/null)

    if [[ -z "$container" ]]; then
        _api_error 400 "Container name is required"
        return
    fi

    local output
    output=$(docker network connect "$name" "$container" 2>&1) || {
        _api_error 500 "Failed to connect: $(_api_json_escape "$output")"
        return
    }

    _api_success "{\"success\": true, \"network\": \"$(_api_json_escape "$name")\", \"container\": \"$(_api_json_escape "$container")\", \"message\": \"Connected '$container' to '$name'\"}"
}

handle_network_disconnect() {
    local name="$1" body="$2"
    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required"
        return
    fi

    local container
    container=$(echo "$body" | jq -r '.container // empty' 2>/dev/null)

    if [[ -z "$container" ]]; then
        _api_error 400 "Container name is required"
        return
    fi

    local output
    output=$(docker network disconnect "$name" "$container" 2>&1) || {
        _api_error 500 "Failed to disconnect: $(_api_json_escape "$output")"
        return
    }

    _api_success "{\"success\": true, \"network\": \"$(_api_json_escape "$name")\", \"container\": \"$(_api_json_escape "$container")\", \"message\": \"Disconnected '$container' from '$name'\"}"
}

handle_network_detail() {
    local name="$1"

    if ! docker network inspect "$name" >/dev/null 2>&1; then
        _api_error 404 "Network '$name' not found"
        return
    fi

    local inspect_json
    inspect_json=$(docker network inspect "$name" 2>/dev/null)

    local id driver scope internal ipam_subnet ipam_gateway
    id=$(echo "$inspect_json" | jq -r '.[0].Id // empty' 2>/dev/null)
    driver=$(echo "$inspect_json" | jq -r '.[0].Driver // empty' 2>/dev/null)
    scope=$(echo "$inspect_json" | jq -r '.[0].Scope // empty' 2>/dev/null)
    internal=$(echo "$inspect_json" | jq -r '.[0].Internal // false' 2>/dev/null)
    ipam_subnet=$(echo "$inspect_json" | jq -r '.[0].IPAM.Config[0].Subnet // empty' 2>/dev/null)
    ipam_gateway=$(echo "$inspect_json" | jq -r '.[0].IPAM.Config[0].Gateway // empty' 2>/dev/null)

    # Get containers with their IPs
    local -a container_entries=()
    while IFS='|' read -r cid cname cipv4; do
        [[ -z "$cid" ]] && continue
        container_entries+=("{\"id\": \"$(_api_json_escape "$cid")\", \"name\": \"$(_api_json_escape "$cname")\", \"ipv4\": \"$(_api_json_escape "$cipv4")\"}")
    done < <(echo "$inspect_json" | jq -r '.[0].Containers | to_entries[] | "\(.key)|\(.value.Name)|\(.value.IPv4Address)"' 2>/dev/null)

    local ce_json
    ce_json=$(printf '%s,' "${container_entries[@]}")
    ce_json="[${ce_json%,}]"

    _api_success "{\"id\": \"$(_api_json_escape "$id")\", \"name\": \"$(_api_json_escape "$name")\", \"driver\": \"$(_api_json_escape "$driver")\", \"scope\": \"$(_api_json_escape "$scope")\", \"internal\": $internal, \"subnet\": \"$(_api_json_escape "$ipam_subnet")\", \"gateway\": \"$(_api_json_escape "$ipam_gateway")\", \"containers\": $ce_json}"
}

handle_delete_volume() {
    local name="$1"

    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    if [[ -z "$name" ]]; then
        _api_error 400 "Volume name is required"
        return
    fi

    # Check if volume exists
    if ! docker volume inspect "$name" >/dev/null 2>&1; then
        _api_error 404 "Volume '$name' not found"
        return
    fi

    local output
    output=$(docker volume rm "$name" 2>&1) || {
        _api_error 500 "Failed to delete volume: $(_api_json_escape "$output"). It may be in use by a container."
        return
    }

    _api_success "{\"success\": true, \"name\": \"$(_api_json_escape "$name")\", \"message\": \"Volume '$name' deleted successfully\"}"
}

handle_logs() {
    local log_file="${BASE_DIR}/logs/docker-services.log"

    if [[ ! -f "$log_file" ]]; then
        _api_success "{\"log_file\": \"\", \"lines\": 0, \"logs\": \"\"}"
        return
    fi

    local num_lines="${QUERY_PARAMS[lines]:-100}"
    local level_filter="${QUERY_PARAMS[level]:-}"
    local search_filter="${QUERY_PARAMS[search]:-}"

    [[ "$num_lines" =~ ^[0-9]+$ ]] || num_lines=100
    (( num_lines > 5000 )) && num_lines=5000

    local content
    if [[ -n "$level_filter" || -n "$search_filter" ]]; then
        content=$(tail -"$num_lines" "$log_file" 2>/dev/null)
        if [[ -n "$level_filter" ]]; then
            content=$(printf '%s\n' "$content" | grep -i "\[$level_filter\]" 2>/dev/null || true)
        fi
        if [[ -n "$search_filter" ]]; then
            content=$(printf '%s\n' "$content" | grep -i "$search_filter" 2>/dev/null || true)
        fi
    else
        content=$(tail -"$num_lines" "$log_file" 2>/dev/null)
    fi

    local escaped
    escaped=$(_api_json_escape "$content")
    local actual_lines
    actual_lines=$(printf '%s' "$content" | wc -l | tr -d ' ')

    _api_success "{\"log_file\": \"$(_api_json_escape "$log_file")\", \"lines\": $actual_lines, \"logs\": \"$escaped\"}"
}

handle_logs_stats() {
    local log_file="${BASE_DIR}/logs/docker-services.log"

    if [[ ! -f "$log_file" ]]; then
        _api_success "{\"total_lines\": 0, \"file_size\": \"0\", \"levels\": {\"error\":0,\"critical\":0,\"warning\":0,\"success\":0,\"info\":0,\"debug\":0,\"step\":0,\"timing\":0}, \"sessions\": 0, \"archives\": {\"count\": 0, \"total_size\": \"0\"}}"
        return
    fi

    local total_lines file_size
    total_lines=$(wc -l < "$log_file" 2>/dev/null | tr -d ' ')
    file_size=$(du -h "$log_file" 2>/dev/null | awk '{print $1}')

    local errors warnings successes infos debugs steps timings criticals
    errors=$(grep -c '\[ERROR\]' "$log_file" 2>/dev/null || echo 0)
    criticals=$(grep -c '\[CRITICAL\]' "$log_file" 2>/dev/null || echo 0)
    warnings=$(grep -c '\[WARNING\]' "$log_file" 2>/dev/null || echo 0)
    successes=$(grep -c '\[SUCCESS\]' "$log_file" 2>/dev/null || echo 0)
    infos=$(grep -c '\[INFO\]' "$log_file" 2>/dev/null || echo 0)
    debugs=$(grep -c '\[DEBUG\]' "$log_file" 2>/dev/null || echo 0)
    steps=$(grep -c '\[STEP' "$log_file" 2>/dev/null || echo 0)
    timings=$(grep -c '\[TIMING\]' "$log_file" 2>/dev/null || echo 0)

    local sessions
    sessions=$(grep -c 'Session Started' "$log_file" 2>/dev/null || echo 0)

    local archive_count=0 archive_size="0"
    local archive_dir="${BASE_DIR}/logs/archive"
    if [[ -d "$archive_dir" ]]; then
        archive_count=$(ls -1 "$archive_dir"/docker-services-*.log* 2>/dev/null | wc -l | tr -d ' ')
        archive_size=$(du -sh "$archive_dir" 2>/dev/null | awk '{print $1}')
    fi

    _api_success "{\"total_lines\": $total_lines, \"file_size\": \"$(_api_json_escape "${file_size:-0}")\", \"levels\": {\"error\": $errors, \"critical\": $criticals, \"warning\": $warnings, \"success\": $successes, \"info\": $infos, \"debug\": $debugs, \"step\": $steps, \"timing\": $timings}, \"sessions\": $sessions, \"archives\": {\"count\": $archive_count, \"total_size\": \"$(_api_json_escape "${archive_size:-0}")\"}}"
}

handle_logs_archives() {
    local archive_dir="${BASE_DIR}/logs/archive"

    if [[ ! -d "$archive_dir" ]]; then
        _api_success "{\"archives\": [], \"total_size\": \"0\"}"
        return
    fi

    local -a archives=()
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local filename size date_str
        filename=$(echo "$entry" | awk '{print $NF}' | xargs basename 2>/dev/null)
        size=$(echo "$entry" | awk '{print $5}')
        date_str=$(echo "$entry" | awk '{print $6, $7, $8}')
        archives+=("{\"filename\": \"$(_api_json_escape "$filename")\", \"size\": \"$(_api_json_escape "$size")\", \"date\": \"$(_api_json_escape "$date_str")\"}")
    done < <(ls -lhtr "$archive_dir"/*.log* 2>/dev/null)

    local archives_json
    if [[ ${#archives[@]} -gt 0 ]]; then
        archives_json=$(printf '%s,' "${archives[@]}")
        archives_json="[${archives_json%,}]"
    else
        archives_json="[]"
    fi

    local total_size
    total_size=$(du -sh "$archive_dir" 2>/dev/null | awk '{print $1}')

    _api_success "{\"archives\": $archives_json, \"total_size\": \"$(_api_json_escape "${total_size:-0}")\"}"
}

handle_events() {
    local events_raw
    events_raw=$(docker events --since '1h' --until "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --format '{{.Time}}|{{.Type}}|{{.Action}}|{{.Actor.Attributes.name}}' 2>/dev/null | tail -50)

    local -a entries=()
    while IFS='|' read -r timestamp type action name; do
        [[ -z "$timestamp" ]] && continue
        entries+=("{\"timestamp\": $timestamp, \"type\": \"$(_api_json_escape "$type")\", \"action\": \"$(_api_json_escape "$action")\", \"name\": \"$(_api_json_escape "$name")\"}")
    done <<< "$events_raw"

    local json
    json=$(printf '%s,' "${entries[@]}")
    json="[${json%,}]"

    _api_success "{\"total\": ${#entries[@]}, \"events\": $json}"
}

# =============================================================================
# AUTHENTICATION ENDPOINT HANDLERS
# =============================================================================

# POST /auth/setup — Create the first admin account (only when no users exist)
handle_auth_setup() {
    local body="$1"

    _api_init_auth_dir

    # Rate limit check
    local client_ip="${SOCAT_PEERADDR:-unknown}"
    if ! _api_check_rate_limit "$client_ip"; then
        _api_audit_log "$client_ip" "LOCKOUT" "" "Rate limit lockout on /auth/setup"
        _api_error 429 "Too many attempts. Please try again later."
        return
    fi

    local user_count
    user_count=$(_api_user_count)
    if [[ "$user_count" -gt 0 ]]; then
        _api_error 400 "Setup already complete. Users already exist."
        return
    fi

    local username password
    if command -v jq >/dev/null 2>&1; then
        username=$(echo "$body" | jq -r '.username // empty' 2>/dev/null)
        password=$(echo "$body" | jq -r '.password // empty' 2>/dev/null)
    else
        username=$(echo "$body" | sed -n 's/.*"username" *: *"\([^"]*\)".*/\1/p')
        password=$(echo "$body" | sed -n 's/.*"password" *: *"\([^"]*\)".*/\1/p')
    fi

    if [[ -z "$username" ]] || [[ -z "$password" ]]; then
        _api_error 400 "Missing required fields: username and password"
        return
    fi

    # Validate username (alphanumeric, hyphens, underscores, 3-32 chars)
    if [[ ! "$username" =~ ^[a-zA-Z0-9_-]{3,32}$ ]]; then
        _api_error 400 "Invalid username. Use 3-32 alphanumeric characters, hyphens, or underscores."
        return
    fi

    # Validate password length
    if [[ ${#password} -lt 8 ]]; then
        _api_error 400 "Password must be at least 8 characters"
        return
    fi

    local salt
    salt=$(_api_generate_salt)
    local password_hash
    password_hash=$(_api_hash_password_v2 "$salt" "$password")

    _api_add_user "$username" "$password_hash" "$salt" "admin"

    local client_ip="${SOCAT_PEERADDR:-unknown}"
    _api_audit_log "$client_ip" "SETUP" "$username" "Admin account created"

    local token
    token=$(_api_generate_token)
    _api_store_token "$token" "$username" "admin"

    _api_success "{\"success\": true, \"token\": \"$token\", \"username\": \"$(_api_json_escape "$username")\", \"role\": \"admin\", \"message\": \"Admin account created successfully\"}"
}

# POST /auth/login — Authenticate and get a session token
handle_auth_login() {
    local body="$1"

    _api_init_auth_dir

    # Rate limit check (use SOCAT_PEERADDR if available, fallback to "unknown")
    local client_ip="${SOCAT_PEERADDR:-unknown}"
    if ! _api_check_rate_limit "$client_ip"; then
        _api_audit_log "$client_ip" "LOCKOUT" "" "Rate limit lockout triggered"
        _api_error 429 "Too many failed login attempts. Please try again later."
        return
    fi

    local username password
    if command -v jq >/dev/null 2>&1; then
        username=$(echo "$body" | jq -r '.username // empty' 2>/dev/null)
        password=$(echo "$body" | jq -r '.password // empty' 2>/dev/null)
    else
        username=$(echo "$body" | sed -n 's/.*"username" *: *"\([^"]*\)".*/\1/p')
        password=$(echo "$body" | sed -n 's/.*"password" *: *"\([^"]*\)".*/\1/p')
    fi

    if [[ -z "$username" ]] || [[ -z "$password" ]]; then
        _api_error 400 "Missing required fields: username and password"
        return
    fi

    # Look up user
    if ! _api_user_exists "$username"; then
        _api_record_failed_login "$client_ip"
        _api_error 401 "Invalid username or password"
        return
    fi

    local user_record
    user_record=$(_api_get_user "$username")
    if [[ -z "$user_record" ]]; then
        _api_record_failed_login "$client_ip"
        _api_error 401 "Invalid username or password"
        return
    fi

    local stored_hash stored_salt role hash_version
    if command -v jq >/dev/null 2>&1; then
        stored_hash=$(echo "$user_record" | jq -r '.password_hash' 2>/dev/null)
        stored_salt=$(echo "$user_record" | jq -r '.salt' 2>/dev/null)
        role=$(echo "$user_record" | jq -r '.role' 2>/dev/null)
        hash_version=$(echo "$user_record" | jq -r '.hash_version // 1' 2>/dev/null)
    else
        stored_hash=$(echo "$user_record" | sed -n 's/.*"password_hash" *: *"\([^"]*\)".*/\1/p')
        stored_salt=$(echo "$user_record" | sed -n 's/.*"salt" *: *"\([^"]*\)".*/\1/p')
        role=$(echo "$user_record" | sed -n 's/.*"role" *: *"\([^"]*\)".*/\1/p')
        hash_version="1"
    fi

    # Verify password (dispatches to v1 or v2 based on hash_version)
    if ! _api_verify_password "$password" "$stored_hash" "$stored_salt" "$hash_version"; then
        _api_record_failed_login "$client_ip"
        _api_audit_log "$client_ip" "LOGIN_FAIL" "$username" "Invalid password"
        _api_error 401 "Invalid username or password"
        return
    fi

    # Success — reset rate limit and create token
    _api_reset_rate_limit "$client_ip"

    # Transparent migration: upgrade v1 hashes to v2 (PBKDF2)
    if [[ "$hash_version" != "2" ]]; then
        local new_salt new_hash
        new_salt=$(_api_generate_salt)
        new_hash=$(_api_hash_password_v2 "$new_salt" "$password")
        _api_update_user_hash "$username" "$new_hash" "$new_salt" 2
    fi

    # Clean up expired tokens periodically
    _api_cleanup_expired_tokens

    _api_audit_log "$client_ip" "LOGIN_OK" "$username" "Login successful"

    local token
    token=$(_api_generate_token)
    _api_store_token "$token" "$username" "$role"

    _api_success "{\"success\": true, \"token\": \"$token\", \"username\": \"$(_api_json_escape "$username")\", \"role\": \"$(_api_json_escape "$role")\"}"
}

# POST /auth/invite — Generate an invite code (admin only)
handle_auth_invite() {
    local body="$1"

    _api_init_auth_dir

    # Must be admin
    if ! _api_check_admin; then
        _api_error 403 "Admin access required"
        return
    fi

    local role="user"
    if command -v jq >/dev/null 2>&1 && [[ -n "$body" ]]; then
        local body_role
        body_role=$(echo "$body" | jq -r '.role // empty' 2>/dev/null)
        [[ -n "$body_role" ]] && role="$body_role"
    fi

    # Validate role
    if [[ "$role" != "user" ]] && [[ "$role" != "admin" ]]; then
        _api_error 400 "Invalid role. Must be 'user' or 'admin'."
        return
    fi

    local code
    code=$(_api_generate_token)
    # Use a shorter invite code (first 16 chars)
    code="${code:0:32}"

    _api_store_invite "$code" "$role" "${AUTH_USERNAME:-unknown}"

    local client_ip="${SOCAT_PEERADDR:-unknown}"
    _api_audit_log "$client_ip" "INVITE_CREATE" "${AUTH_USERNAME:-unknown}" "Role: $role"

    local now
    now=$(_api_now_epoch)
    local expires_at=$(( now + API_INVITE_EXPIRY ))
    local expires_at_iso
    expires_at_iso=$(date -u -d "@$expires_at" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ')

    _api_success "{\"success\": true, \"code\": \"$code\", \"role\": \"$(_api_json_escape "$role")\", \"expires_at\": \"$expires_at_iso\"}"
}

# POST /auth/register — Register a new account with an invite code
handle_auth_register() {
    local body="$1"

    _api_init_auth_dir

    # Rate limit check
    local client_ip="${SOCAT_PEERADDR:-unknown}"
    if ! _api_check_rate_limit "$client_ip"; then
        _api_audit_log "$client_ip" "LOCKOUT" "" "Rate limit lockout on /auth/register"
        _api_error 429 "Too many attempts. Please try again later."
        return
    fi

    local username password invite_code
    if command -v jq >/dev/null 2>&1; then
        username=$(echo "$body" | jq -r '.username // empty' 2>/dev/null)
        password=$(echo "$body" | jq -r '.password // empty' 2>/dev/null)
        invite_code=$(echo "$body" | jq -r '.invite_code // empty' 2>/dev/null)
    else
        username=$(echo "$body" | sed -n 's/.*"username" *: *"\([^"]*\)".*/\1/p')
        password=$(echo "$body" | sed -n 's/.*"password" *: *"\([^"]*\)".*/\1/p')
        invite_code=$(echo "$body" | sed -n 's/.*"invite_code" *: *"\([^"]*\)".*/\1/p')
    fi

    if [[ -z "$username" ]] || [[ -z "$password" ]] || [[ -z "$invite_code" ]]; then
        _api_error 400 "Missing required fields: username, password, and invite_code"
        return
    fi

    # Validate username
    if [[ ! "$username" =~ ^[a-zA-Z0-9_-]{3,32}$ ]]; then
        _api_error 400 "Invalid username. Use 3-32 alphanumeric characters, hyphens, or underscores."
        return
    fi

    # Validate password length
    if [[ ${#password} -lt 8 ]]; then
        _api_error 400 "Password must be at least 8 characters"
        return
    fi

    # Check if username already exists
    if _api_user_exists "$username"; then
        _api_error 409 "Username already taken"
        return
    fi

    # Validate invite code
    local role
    role=$(_api_validate_invite "$invite_code") || {
        _api_error 400 "Invalid or expired invite code"
        return
    }

    if [[ -z "$role" ]]; then
        _api_error 400 "Invalid or expired invite code"
        return
    fi

    # Create user (v2 PBKDF2 hash)
    local salt
    salt=$(_api_generate_salt)
    local password_hash
    password_hash=$(_api_hash_password_v2 "$salt" "$password")

    _api_add_user "$username" "$password_hash" "$salt" "$role"

    # Consume the invite code
    _api_consume_invite "$invite_code" "$username"

    local client_ip="${SOCAT_PEERADDR:-unknown}"
    _api_audit_log "$client_ip" "REGISTER" "$username" "Registered with invite code"

    # Generate session token
    local token
    token=$(_api_generate_token)
    _api_store_token "$token" "$username" "$role"

    _api_success "{\"success\": true, \"token\": \"$token\", \"username\": \"$(_api_json_escape "$username")\", \"role\": \"$(_api_json_escape "$role")\"}"
}

# GET /auth/verify — Verify a token is valid
handle_auth_verify() {
    _api_init_auth_dir

    # Extract token from Authorization header
    local token=""
    if [[ -n "${REQUEST_AUTH_HEADER:-}" ]]; then
        token="${REQUEST_AUTH_HEADER#Bearer }"
        token="${token#bearer }"
    fi

    if [[ -z "$token" ]]; then
        _api_success "{\"valid\": false, \"message\": \"No token provided\"}"
        return
    fi

    if _api_validate_token "$token"; then
        _api_success "{\"valid\": true, \"username\": \"$(_api_json_escape "$AUTH_USERNAME")\", \"role\": \"$(_api_json_escape "$AUTH_ROLE")\"}"
    else
        _api_success "{\"valid\": false, \"message\": \"Token is invalid or expired\"}"
    fi
}

# GET /auth/users — List all users (admin only)
handle_auth_users() {
    _api_init_auth_dir

    if ! _api_check_admin; then
        _api_error 403 "Admin access required"
        return
    fi

    local users
    users=$(_api_read_auth_file "users.json")

    if command -v jq >/dev/null 2>&1; then
        # Strip sensitive fields (password_hash, salt)
        local safe_users
        safe_users=$(echo "$users" | jq '[.[] | {username: .username, role: .role, created_at: .created_at}]' 2>/dev/null)
        _api_success "{\"users\": $safe_users}"
    else
        # Fallback without jq: manually strip sensitive fields via sed
        local safe_users
        safe_users=$(echo "$users" | sed 's/"password_hash" *: *"[^"]*" *,//g; s/"salt" *: *"[^"]*" *,//g; s/"hash_version" *: *[0-9]* *,//g')
        _api_success "{\"users\": $safe_users}"
    fi
}

# POST /auth/revoke — Revoke a user's access (admin only)
handle_auth_revoke() {
    local body="$1"

    _api_init_auth_dir

    if ! _api_check_admin; then
        _api_error 403 "Admin access required"
        return
    fi

    local target_username
    if command -v jq >/dev/null 2>&1; then
        target_username=$(echo "$body" | jq -r '.username // empty' 2>/dev/null)
    else
        target_username=$(echo "$body" | sed -n 's/.*"username" *: *"\([^"]*\)".*/\1/p')
    fi

    if [[ -z "$target_username" ]]; then
        _api_error 400 "Missing required field: username"
        return
    fi

    # Prevent self-revocation
    if [[ "$target_username" == "${AUTH_USERNAME:-}" ]]; then
        _api_error 400 "Cannot revoke your own access"
        return
    fi

    if ! _api_user_exists "$target_username"; then
        _api_error 404 "User not found: $target_username"
        return
    fi

    # Revoke all tokens for the user
    _api_revoke_user_tokens "$target_username"

    # Remove the user from users.json
    if command -v jq >/dev/null 2>&1; then
        local users
        users=$(_api_read_auth_file "users.json")
        local new_users
        new_users=$(echo "$users" | jq --arg u "$target_username" '[.[] | select(.username != $u)]' 2>/dev/null)
        _api_write_auth_file "users.json" "$new_users"
    fi

    local client_ip="${SOCAT_PEERADDR:-unknown}"
    _api_audit_log "$client_ip" "REVOKE" "$target_username" "Revoked by ${AUTH_USERNAME:-unknown}"

    _api_success "{\"success\": true, \"username\": \"$(_api_json_escape "$target_username")\", \"message\": \"User access revoked and all sessions invalidated\"}"
}

# DELETE /auth/invite/:code — Delete an invite code (admin only)
handle_auth_delete_invite() {
    local code="$1"

    _api_init_auth_dir

    if ! _api_check_admin; then
        _api_error 403 "Admin access required"
        return
    fi

    if [[ -z "$code" ]]; then
        _api_error 400 "Missing invite code"
        return
    fi

    if _api_delete_invite "$code"; then
        _api_success "{\"success\": true, \"code\": \"$(_api_json_escape "$code")\", \"message\": \"Invite code deleted\"}"
    else
        _api_error 404 "Invite code not found: $code"
    fi
}

# GET /auth/invites — List active invite codes (admin only)
handle_auth_invites() {
    _api_init_auth_dir

    if ! _api_check_admin; then
        _api_error 403 "Admin access required"
        return
    fi

    local invites
    invites=$(_api_read_auth_file "invites.json")
    local now
    now=$(_api_now_epoch)

    if command -v jq >/dev/null 2>&1; then
        # Return all invites with proper ISO dates and used field handling
        local formatted_invites
        formatted_invites=$(echo "$invites" | jq --argjson n "$now" '
            [.[] | . + {
                "used": (if .used then .used else false end),
                "used_by": (if .used_by then .used_by else "" end),
                "expires_at": (if (.expires_at | type) == "number" then (.expires_at | todate) else .expires_at end),
                "expired": (if (.expires_at | type) == "number" then (.expires_at < $n) else false end)
            }]
        ' 2>/dev/null)
        local count
        count=$(echo "$formatted_invites" | jq 'length' 2>/dev/null)
        _api_success "{\"total\": ${count:-0}, \"invites\": ${formatted_invites:-[]}}"
    else
        _api_success "{\"total\": 0, \"invites\": ${invites:-[]}}"
    fi
}

# POST /auth/logout — Invalidate the current session token
handle_auth_logout() {
    _api_init_auth_dir

    # Extract and remove the current token
    local token=""
    if [[ -n "${REQUEST_AUTH_HEADER:-}" ]]; then
        token="${REQUEST_AUTH_HEADER#Bearer }"
        token="${token#bearer }"
    fi

    if [[ -z "$token" ]]; then
        _api_error 400 "No token provided"
        return
    fi

    # Remove this specific token from tokens.json
    local tokens
    tokens=$(_api_read_auth_file "tokens.json")
    if command -v jq >/dev/null 2>&1; then
        local new_tokens
        new_tokens=$(echo "$tokens" | jq --arg t "$token" '[.[] | select(.token != $t)]' 2>/dev/null)
        _api_write_auth_file "tokens.json" "$new_tokens"
    fi

    local client_ip="${SOCAT_PEERADDR:-unknown}"
    _api_audit_log "$client_ip" "LOGOUT" "${AUTH_USERNAME:-unknown}" "Token invalidated"

    _api_success '{"success": true, "message": "Logged out successfully"}'
}

# POST /auth/logout-all — Invalidate all sessions for a user (admin only)
handle_auth_logout_all() {
    local body="$1"

    _api_init_auth_dir

    if ! _api_check_admin; then
        _api_error 403 "Admin access required"
        return
    fi

    local target_username
    if command -v jq >/dev/null 2>&1; then
        target_username=$(echo "$body" | jq -r '.username // empty' 2>/dev/null)
    else
        target_username=$(echo "$body" | sed -n 's/.*"username" *: *"\([^"]*\)".*/\1/p')
    fi

    if [[ -z "$target_username" ]]; then
        _api_error 400 "Missing required field: username"
        return
    fi

    _api_revoke_user_tokens "$target_username"

    local client_ip="${SOCAT_PEERADDR:-unknown}"
    _api_audit_log "$client_ip" "LOGOUT_ALL" "$target_username" "All sessions revoked by ${AUTH_USERNAME:-unknown}"

    _api_success "{\"success\": true, \"username\": \"$(_api_json_escape "$target_username")\", \"message\": \"All sessions invalidated\"}"
}

# GET /auth/sessions — List active sessions (admin only)
handle_auth_sessions() {
    _api_init_auth_dir

    if ! _api_check_admin; then
        _api_error 403 "Admin access required"
        return
    fi

    local tokens
    tokens=$(_api_read_auth_file "tokens.json")
    local now
    now=$(_api_now_epoch)

    if command -v jq >/dev/null 2>&1; then
        # Filter active (non-expired) tokens, redact the token value, add time-remaining
        local sessions
        sessions=$(echo "$tokens" | jq --argjson now "$now" '
            [.[] | select(.expires_at > $now) |
            {
                id: (.token[:12] + "..."),
                username: .username,
                role: (.role // "user"),
                created_at: .created_at,
                expires_at: .expires_at,
                remaining_seconds: (.expires_at - $now),
                ip: (.ip // "unknown")
            }]' 2>/dev/null)
        [[ -z "$sessions" ]] && sessions="[]"
        local count
        count=$(echo "$sessions" | jq 'length' 2>/dev/null || echo 0)
        _api_success "{\"sessions\": $sessions, \"total\": $count}"
    else
        _api_success '{"sessions": [], "total": 0, "error": "jq required for session listing"}'
    fi
}

# DELETE /auth/sessions/:token_prefix — Revoke a specific session by token prefix (admin only)
handle_auth_session_revoke() {
    local token_prefix="$1"

    _api_init_auth_dir

    if ! _api_check_admin; then
        _api_error 403 "Admin access required"
        return
    fi

    if [[ -z "$token_prefix" || ${#token_prefix} -lt 8 ]]; then
        _api_error 400 "Token prefix must be at least 8 characters"
        return
    fi

    local tokens
    tokens=$(_api_read_auth_file "tokens.json")

    if command -v jq >/dev/null 2>&1; then
        local match_count
        match_count=$(echo "$tokens" | jq --arg p "$token_prefix" '[.[] | select(.token | startswith($p))] | length' 2>/dev/null || echo 0)

        if [[ "$match_count" == "0" ]]; then
            _api_error 404 "No session found with that prefix"
            return
        fi

        local new_tokens
        new_tokens=$(echo "$tokens" | jq --arg p "$token_prefix" '[.[] | select(.token | startswith($p) | not)]' 2>/dev/null)
        _api_write_auth_file "tokens.json" "$new_tokens"

        local client_ip="${SOCAT_PEERADDR:-unknown}"
        _api_audit_log "$client_ip" "SESSION_REVOKE" "${AUTH_USERNAME:-unknown}" "Revoked session ${token_prefix}..."

        _api_success "{\"success\": true, \"revoked\": $match_count, \"message\": \"Session revoked\"}"
    else
        _api_error 500 "jq is required"
    fi
}

# POST /auth/refresh — Refresh the current session token
handle_auth_refresh() {
    _api_init_auth_dir

    # Extract the current token
    local old_token=""
    if [[ -n "${REQUEST_AUTH_HEADER:-}" ]]; then
        old_token="${REQUEST_AUTH_HEADER#Bearer }"
        old_token="${old_token#bearer }"
    fi

    if [[ -z "$old_token" ]]; then
        _api_error 400 "No token provided"
        return
    fi

    local username="${AUTH_USERNAME:-}"
    local role="${AUTH_ROLE:-}"
    if [[ -z "$username" ]]; then
        _api_error 401 "Invalid token"
        return
    fi

    # Remove the old token
    local tokens
    tokens=$(_api_read_auth_file "tokens.json")
    if command -v jq >/dev/null 2>&1; then
        local new_tokens
        new_tokens=$(echo "$tokens" | jq --arg t "$old_token" '[.[] | select(.token != $t)]' 2>/dev/null)
        _api_write_auth_file "tokens.json" "$new_tokens"
    fi

    # Generate and store a new token
    local new_token
    new_token=$(_api_generate_token)
    _api_store_token "$new_token" "$username" "$role"

    local client_ip="${SOCAT_PEERADDR:-unknown}"
    _api_audit_log "$client_ip" "TOKEN_REFRESH" "$username" "Token refreshed"

    _api_success "{\"success\": true, \"token\": \"$new_token\", \"username\": \"$(_api_json_escape "$username")\", \"role\": \"$(_api_json_escape "$role")\"}"
}

# POST /auth/factory-reset — Wipe auth state and return server to first-run mode
handle_auth_factory_reset() {
    local body="$1"

    # Require admin role
    if ! _api_check_admin; then
        _api_error 403 "Admin role required for factory reset"
        return
    fi

    # Parse request body
    local confirm="" reset_compose="false"
    if command -v jq >/dev/null 2>&1; then
        confirm=$(echo "$body" | jq -r '.confirm // ""' 2>/dev/null)
        reset_compose=$(echo "$body" | jq -r '.reset_compose // false' 2>/dev/null)
    else
        confirm=$(echo "$body" | sed -n 's/.*"confirm"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        reset_compose=$(echo "$body" | sed -n 's/.*"reset_compose"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p')
    fi

    # Validate confirmation string
    if [[ "$confirm" != "FACTORY_RESET" ]]; then
        _api_error 400 "Missing or incorrect confirmation. Send {\"confirm\": \"FACTORY_RESET\"}"
        return
    fi

    _api_init_auth_dir
    local auth_dir="$BASE_DIR/.api-auth"
    local removed_json="["
    local rfirst=true

    # Files to remove (auth state + setup flag)
    local reset_files=(
        ".setup-complete"
        "users.json"
        "tokens.json"
        "deploy-history.json"
        "invites.json"
        "terminal-sessions.json"
        "terminal-auth-rate.json"
        "auth-audit.log"
        "terminal-auth-audit.log"
        "terminal-rate.log"
        "rate_limits.json"
    )

    for f in "${reset_files[@]}"; do
        if [[ -f "$auth_dir/$f" ]]; then
            rm -f "$auth_dir/$f"
            [[ "$rfirst" == "true" ]] && rfirst=false || removed_json+=","
            removed_json+="\"$f\""
        fi
    done
    removed_json+="]"

    # Optionally reset compose files to git defaults and remove user-created stacks
    local compose_reset="false"
    local stacks_removed_json="[]"
    local containers_stopped=0
    local images_removed=0
    if [[ "$reset_compose" == "true" ]]; then
        # Kill ALL running containers instantly (no graceful shutdown needed for reset)
        local stacks_dir="$BASE_DIR/Stacks"
        if command -v docker >/dev/null 2>&1; then
            containers_stopped=$(docker ps -q 2>/dev/null | wc -l) || containers_stopped=0
            # Kill all containers at once (instant SIGKILL)
            docker kill $(docker ps -q 2>/dev/null) >/dev/null 2>&1 || true
            # Remove stopped containers + prune images in background (can be slow)
            images_removed=$(docker images -q 2>/dev/null | wc -l) || images_removed=0
            ( docker container prune -f >/dev/null 2>&1; docker image prune -af >/dev/null 2>&1 ) &
            disown
        fi

        # Remove App-Data directories in background (can be slow for root-owned files)
        (
            if [[ -d "$stacks_dir" ]]; then
                for d in "$stacks_dir"/*/; do
                    [[ -d "$d" && -d "$d/App-Data" ]] && rm -rf "$d/App-Data" 2>/dev/null
                done
            fi
        ) &
        disown

        if command -v git >/dev/null 2>&1 && [[ -d "$BASE_DIR/.git" ]]; then
            cd "$BASE_DIR"
            # Reset tracked compose files to git defaults
            git checkout -- Stacks/*/docker-compose.yml 2>/dev/null
            # Also reset tracked .env files if any
            git checkout -- Stacks/*/.env 2>/dev/null || true
            # Remove user-created (untracked) stack directories
            local -a removed_stacks=()
            if [[ -d "$stacks_dir" ]]; then
                for d in "$stacks_dir"/*/; do
                    [[ -d "$d" ]] || continue
                    local dname
                    dname=$(basename "$d")
                    if ! git -C "$BASE_DIR" ls-files --error-unmatch "Stacks/$dname/docker-compose.yml" >/dev/null 2>&1; then
                        rm -rf "$d" 2>/dev/null
                        removed_stacks+=("$dname")
                    fi
                done
            fi
            # Build JSON array of removed stacks
            if [[ ${#removed_stacks[@]} -gt 0 ]]; then
                stacks_removed_json="["
                local sfirst=true
                for s in "${removed_stacks[@]}"; do
                    [[ "$sfirst" == "true" ]] && sfirst=false || stacks_removed_json+=","
                    stacks_removed_json+="\"$s\""
                done
                stacks_removed_json+="]"
            fi
            compose_reset="true"
        fi

        # Clean up v4.0+ data files
        local data_dir="$BASE_DIR/.data"
        if [[ -d "$data_dir" ]]; then
            rm -f "$data_dir/audit.jsonl" 2>/dev/null
            rm -f "$data_dir/webhooks.json" 2>/dev/null
            rm -f "$data_dir/schedules.json" 2>/dev/null
            rm -f "$data_dir/schedule-history.jsonl" 2>/dev/null
            rm -f "$data_dir/metrics.jsonl" 2>/dev/null
            rm -f "$data_dir/secrets.enc" 2>/dev/null
            rm -f "$data_dir/secrets.key" 2>/dev/null
            rm -f "$data_dir/plugins.json" 2>/dev/null
        fi

        # Remove user-imported templates (keep git-tracked ones)
        local templates_dir="$BASE_DIR/.templates"
        if [[ -d "$templates_dir" ]] && command -v git >/dev/null 2>&1; then
            for tdir in "$templates_dir"/*/; do
                [[ -d "$tdir" ]] || continue
                local tname
                tname=$(basename "$tdir")
                if ! git -C "$BASE_DIR" ls-files --error-unmatch ".templates/$tname/docker-compose.yml" >/dev/null 2>&1; then
                    rm -rf "$tdir" 2>/dev/null
                fi
            done
        fi

        # Remove all installed plugins
        local plugins_dir="$BASE_DIR/.plugins"
        if [[ -d "$plugins_dir" ]]; then
            for pdir in "$plugins_dir"/*/; do
                [[ -d "$pdir" ]] || continue
                rm -rf "$pdir" 2>/dev/null
            done
        fi

        # Stop scheduler and metrics daemons if running
        for pidfile in /tmp/dcs-metrics-collector.pid /tmp/dcs-scheduler.pid; do
            if [[ -f "$pidfile" ]]; then
                local daemon_pid
                daemon_pid=$(cat "$pidfile" 2>/dev/null)
                if [[ -n "$daemon_pid" ]] && kill -0 "$daemon_pid" 2>/dev/null; then
                    kill "$daemon_pid" 2>/dev/null
                fi
                rm -f "$pidfile"
            fi
        done
    fi

    # Reset .env to defaults — copy .env.example back to .env
    local env_reset="false"
    if [[ -f "$BASE_DIR/.env.example" ]]; then
        cp -f "$BASE_DIR/.env.example" "$BASE_DIR/.env"
        env_reset="true"
    elif [[ -f "$BASE_DIR/.env" ]]; then
        # No .env.example — fallback to just removing DOCKER_STACKS
        sed -i '/^DOCKER_STACKS=/d' "$BASE_DIR/.env"
    fi
    unset DOCKER_STACKS

    local client_ip="${SOCAT_PEERADDR:-unknown}"
    _api_audit_log "$client_ip" "FACTORY_RESET" "${AUTH_USERNAME:-unknown}" "Factory reset performed. compose_reset=$compose_reset containers_stopped=$containers_stopped images_removed=$images_removed"

    _api_success "{\"success\": true, \"files_removed\": $removed_json, \"compose_reset\": $compose_reset, \"stacks_removed\": $stacks_removed_json, \"env_reset\": $env_reset, \"containers_stopped\": $containers_stopped, \"images_removed\": $images_removed}"
}

# =============================================================================
# CONTAINER ACTION HANDLERS
# =============================================================================

handle_container_action() {
    local name="$1"
    local action="$2"

    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    if ! docker inspect "$name" >/dev/null 2>&1; then
        _api_error 404 "Container not found: $name"
        return
    fi

    local output=""
    local success=true

    case "$action" in
        start)   output=$(docker start "$name" 2>&1) || success=false ;;
        stop)    output=$(docker stop "$name" 2>&1) || success=false ;;
        restart) output=$(docker restart "$name" 2>&1) || success=false ;;
        remove)  output=$(docker rm -f "$name" 2>&1) || success=false ;;
        *)       _api_error 400 "Unknown action: $action"; return ;;
    esac

    local escaped_output
    escaped_output=$(_api_json_escape "$output")

    _api_success "{\"container\": \"$(_api_json_escape "$name")\", \"action\": \"$action\", \"success\": $success, \"output\": \"$escaped_output\"}"
}

handle_container_exec() {
    local name="$1"
    local body="$2"

    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    if ! docker inspect "$name" >/dev/null 2>&1; then
        _api_error 404 "Container not found: $name"
        return
    fi

    # Check container is running
    local state
    state=$(docker inspect --format '{{.State.Running}}' "$name" 2>/dev/null)
    if [[ "$state" != "true" ]]; then
        _api_error 400 "Container is not running"
        return
    fi

    # Extract command from JSON body
    local command
    command=$(echo "$body" | jq -r '.command // empty' 2>/dev/null)

    if [[ -z "$command" ]]; then
        _api_error 400 "Missing required field: command"
        return
    fi

    # SECURITY: Command length limit
    if [[ ${#command} -gt 4096 ]]; then
        _api_error 400 "Command too long (max 4096 characters)"
        return
    fi

    # Execute the command (with timeout to prevent hanging, output capped at 1MB)
    local output=""
    local exit_code=0
    output=$(timeout 30 docker exec -T "$name" sh -c "$command" 2>&1 | head -c 1048576) || exit_code=$?

    # Handle timeout specifically
    if [[ $exit_code -eq 124 ]]; then
        output="Command timed out after 30 seconds"
    fi

    local success=true
    [[ $exit_code -ne 0 ]] && success=false

    local escaped_output escaped_command
    escaped_output=$(_api_json_escape "$output")
    escaped_command=$(_api_json_escape "$command")

    _api_success "{\"container\": \"$(_api_json_escape "$name")\", \"command\": \"$escaped_command\", \"exit_code\": $exit_code, \"output\": \"$escaped_output\", \"success\": $success}"
}

handle_container_logs() {
    local name="$1"

    if ! docker inspect "$name" >/dev/null 2>&1; then
        _api_error 404 "Container not found: $name"
        return
    fi

    local logs_raw
    logs_raw=$(docker logs --tail 100 "$name" 2>&1)
    local escaped
    escaped=$(_api_json_escape "$logs_raw")

    _api_success "{\"container\": \"$(_api_json_escape "$name")\", \"lines\": 100, \"logs\": \"$escaped\"}"
}

# =============================================================================
# MAINTENANCE HANDLERS
# =============================================================================

handle_maintenance_prune() {
    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    local output=""
    local success=true

    output=$(docker system prune -f 2>&1) || success=false
    local escaped
    escaped=$(_api_json_escape "$output")

    _api_success "{\"action\": \"prune\", \"success\": $success, \"output\": \"$escaped\"}"
}

handle_maintenance_image_prune() {
    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    local output=""
    local success=true

    if [[ "${AGGRESSIVE_IMAGE_PRUNE:-false}" == "true" ]]; then
        output=$(docker image prune -a -f 2>&1) || success=false
    else
        output=$(docker image prune -f 2>&1) || success=false
    fi
    local escaped
    escaped=$(_api_json_escape "$output")

    _api_success "{\"action\": \"image_prune\", \"success\": $success, \"output\": \"$escaped\"}"
}

# =============================================================================
# ADVANCED MAINTENANCE HANDLERS (Phase 2)
# =============================================================================

handle_maintenance_report() {
    local running stopped total_containers total_images dangling_images
    local total_volumes dangling_volumes total_networks custom_networks

    running=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
    total_containers=$(docker ps -aq 2>/dev/null | wc -l | tr -d ' ')
    stopped=$(( total_containers - running ))
    total_images=$(docker images -q 2>/dev/null | wc -l | tr -d ' ')
    dangling_images=$(docker images -f 'dangling=true' -q 2>/dev/null | wc -l | tr -d ' ')
    total_volumes=$(docker volume ls -q 2>/dev/null | wc -l | tr -d ' ')
    dangling_volumes=$(docker volume ls -f 'dangling=true' -q 2>/dev/null | wc -l | tr -d ' ')
    total_networks=$(docker network ls -q 2>/dev/null | wc -l | tr -d ' ')
    custom_networks=$(docker network ls --format '{{.Name}}' 2>/dev/null | grep -cvE '^(bridge|host|none)$' || echo 0)

    local docker_df
    docker_df=$(_api_json_escape "$(docker system df 2>/dev/null)")

    local app_data_size="N/A"
    if [[ -d "$APP_DATA_DIR" ]]; then
        app_data_size=$(du -sh "$APP_DATA_DIR" 2>/dev/null | cut -f1)
    fi

    local log_size="N/A"
    local log_dir="${BASE_DIR}/logs"
    if [[ -d "$log_dir" ]]; then
        log_size=$(du -sh "$log_dir" 2>/dev/null | cut -f1)
    fi

    _api_success "{\"containers\": {\"total\": $total_containers, \"running\": $running, \"stopped\": $stopped}, \"images\": {\"total\": $total_images, \"dangling\": $dangling_images}, \"volumes\": {\"total\": $total_volumes, \"dangling\": $dangling_volumes}, \"networks\": {\"total\": $total_networks, \"custom\": $custom_networks}, \"docker_df\": \"$docker_df\", \"app_data_size\": \"$(_api_json_escape "$app_data_size")\", \"log_size\": \"$(_api_json_escape "$log_size")\"}"
}

handle_maintenance_orphans() {
    local -a orphan_containers=()
    while IFS='|' read -r name image status; do
        [[ -z "$name" ]] && continue
        orphan_containers+=("{\"name\": \"$(_api_json_escape "$name")\", \"image\": \"$(_api_json_escape "$image")\", \"status\": \"$(_api_json_escape "$status")\"}")
    done < <(docker ps -a --filter 'status=exited' --format '{{.Names}}|{{.Image}}|{{.Status}}' 2>/dev/null)

    local oc_json
    if [[ ${#orphan_containers[@]} -gt 0 ]]; then
        oc_json=$(printf '%s,' "${orphan_containers[@]}")
        oc_json="[${oc_json%,}]"
    else
        oc_json="[]"
    fi

    local -a dangling_imgs=()
    while IFS='|' read -r id size created; do
        [[ -z "$id" ]] && continue
        dangling_imgs+=("{\"id\": \"$(_api_json_escape "$id")\", \"size\": \"$(_api_json_escape "$size")\", \"created\": \"$(_api_json_escape "$created")\"}")
    done < <(docker images -f 'dangling=true' --format '{{.ID}}|{{.Size}}|{{.CreatedAt}}' 2>/dev/null)

    local di_json
    if [[ ${#dangling_imgs[@]} -gt 0 ]]; then
        di_json=$(printf '%s,' "${dangling_imgs[@]}")
        di_json="[${di_json%,}]"
    else
        di_json="[]"
    fi

    local -a dangling_vols=()
    while IFS='|' read -r name driver; do
        [[ -z "$name" ]] && continue
        dangling_vols+=("{\"name\": \"$(_api_json_escape "$name")\", \"driver\": \"$(_api_json_escape "$driver")\"}")
    done < <(docker volume ls -f 'dangling=true' --format '{{.Name}}|{{.Driver}}' 2>/dev/null)

    local dv_json
    if [[ ${#dangling_vols[@]} -gt 0 ]]; then
        dv_json=$(printf '%s,' "${dangling_vols[@]}")
        dv_json="[${dv_json%,}]"
    else
        dv_json="[]"
    fi

    _api_success "{\"containers\": $oc_json, \"images\": $di_json, \"volumes\": $dv_json}"
}

handle_maintenance_disk() {
    local -a stack_sizes=()
    if [[ -d "$APP_DATA_DIR" ]]; then
        while IFS=$'\t' read -r size dir; do
            [[ -z "$size" ]] && continue
            local dirname
            dirname=$(basename "$dir")
            stack_sizes+=("{\"name\": \"$(_api_json_escape "$dirname")\", \"size\": \"$(_api_json_escape "$size")\"}")
        done < <(du -sh "$APP_DATA_DIR"/*/ 2>/dev/null | sort -rh)
    fi

    local ss_json
    if [[ ${#stack_sizes[@]} -gt 0 ]]; then
        ss_json=$(printf '%s,' "${stack_sizes[@]}")
        ss_json="[${ss_json%,}]"
    else
        ss_json="[]"
    fi

    local -a df_entries=()
    while IFS='|' read -r type total active size reclaimable; do
        [[ -z "$type" || "$type" == "TYPE" ]] && continue
        df_entries+=("{\"type\": \"$(_api_json_escape "$type")\", \"total\": \"$(_api_json_escape "$total")\", \"active\": \"$(_api_json_escape "$active")\", \"size\": \"$(_api_json_escape "$size")\", \"reclaimable\": \"$(_api_json_escape "$reclaimable")\"}")
    done < <(docker system df --format '{{.Type}}|{{.TotalCount}}|{{.Active}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null)

    local df_json
    if [[ ${#df_entries[@]} -gt 0 ]]; then
        df_json=$(printf '%s,' "${df_entries[@]}")
        df_json="[${df_json%,}]"
    else
        df_json="[]"
    fi

    local total_app_data="N/A"
    if [[ -d "$APP_DATA_DIR" ]]; then
        total_app_data=$(du -sh "$APP_DATA_DIR" 2>/dev/null | cut -f1)
    fi

    _api_success "{\"stack_sizes\": $ss_json, \"docker_df\": $df_json, \"total_app_data\": \"$(_api_json_escape "$total_app_data")\"}"
}

handle_maintenance_deep_prune() {
    local body="$1"

    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for deep prune"
        return
    fi

    local confirm
    confirm=$(printf '%s' "$body" | jq -r '.confirm // empty' 2>/dev/null)
    if [[ "$confirm" != "CONFIRM" ]]; then
        _api_error 400 "Deep prune requires {\"confirm\": \"CONFIRM\"} in request body"
        return
    fi

    local output
    local success=true
    output=$(docker system prune -af --volumes 2>&1) || success=false
    local escaped
    escaped=$(_api_json_escape "$output")

    _api_success "{\"action\": \"deep_prune\", \"success\": $success, \"output\": \"$escaped\"}"
}

handle_maintenance_log_rotate() {
    local log_file="${BASE_DIR}/logs/docker-services.log"
    local archive_dir="${BASE_DIR}/logs/archive"
    local retention_count="${LOG_BACKUP_COUNT:-12}"

    if [[ ! -f "$log_file" ]]; then
        _api_success "{\"success\": true, \"message\": \"No active log file to rotate\"}"
        return
    fi

    local log_size
    log_size=$(du -sh "$log_file" 2>/dev/null | cut -f1)
    local log_lines
    log_lines=$(wc -l < "$log_file" 2>/dev/null | tr -d ' ')

    mkdir -p "$archive_dir" 2>/dev/null

    local timestamp
    timestamp=$(date '+%Y%m%d-%H%M%S')
    local archive_name="docker-services-${timestamp}.log"

    cp "$log_file" "$archive_dir/$archive_name" 2>/dev/null
    if command -v gzip >/dev/null 2>&1; then
        gzip "$archive_dir/$archive_name" 2>/dev/null
        archive_name="${archive_name}.gz"
    fi

    : > "$log_file"

    local archive_count
    archive_count=$(ls -1 "$archive_dir"/docker-services-*.log* 2>/dev/null | wc -l | tr -d ' ')
    local purged=0
    if [[ "$archive_count" -gt "$retention_count" ]]; then
        purged=$(( archive_count - retention_count ))
        ls -1t "$archive_dir"/docker-services-*.log* 2>/dev/null | tail -n "$purged" | while read -r old_file; do
            rm -f "$old_file"
        done
    fi

    _api_success "{\"success\": true, \"message\": \"Log rotated successfully\", \"archived_as\": \"$(_api_json_escape "$archive_name")\", \"previous_size\": \"$(_api_json_escape "$log_size")\", \"previous_lines\": $log_lines, \"purged_archives\": $purged}"
}

# =============================================================================
# BATCH OPERATION HANDLERS (Phase 4)
# =============================================================================

handle_batch_stacks() {
    local body="$1"

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for batch operations"
        return
    fi

    local action
    action=$(printf '%s' "$body" | jq -r '.action // empty' 2>/dev/null)
    if [[ -z "$action" || ! "$action" =~ ^(start|stop|restart)$ ]]; then
        _api_error 400 "Invalid or missing 'action'. Must be start, stop, or restart."
        return
    fi

    local stacks_input
    stacks_input=$(printf '%s' "$body" | jq -r '.stacks' 2>/dev/null)

    local -a ordered_stacks=(
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

    local -a target_stacks=()
    if [[ "$stacks_input" == '"all"' || "$stacks_input" == 'all' ]]; then
        for s in "${ordered_stacks[@]}"; do
            [[ -d "$COMPOSE_DIR/$s" && -f "$COMPOSE_DIR/$s/docker-compose.yml" ]] && target_stacks+=("$s")
        done
    else
        while IFS= read -r s; do
            [[ -n "$s" ]] && target_stacks+=("$s")
        done < <(printf '%s' "$body" | jq -r '.stacks[]' 2>/dev/null)
    fi

    # Reverse order for stop
    if [[ "$action" == "stop" ]]; then
        local -a reversed=()
        for (( i=${#target_stacks[@]}-1; i>=0; i-- )); do
            reversed+=("${target_stacks[$i]}")
        done
        target_stacks=("${reversed[@]}")
    fi

    local -a results=()
    for stack in "${target_stacks[@]}"; do
        local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
        if [[ ! -f "$compose_file" ]]; then
            results+=("{\"stack\": \"$(_api_json_escape "$stack")\", \"success\": false, \"message\": \"Stack not found\"}")
            continue
        fi

        local compose_args=(-f "$compose_file")
        [[ -f "$COMPOSE_DIR/$stack/.env" ]] && compose_args+=(--env-file "$COMPOSE_DIR/$stack/.env")

        local output success=true
        case "$action" in
            start)   output=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" up -d 2>&1) || success=false ;;
            stop)    output=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" down 2>&1) || success=false ;;
            restart) output=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" restart 2>&1) || success=false ;;
        esac

        results+=("{\"stack\": \"$(_api_json_escape "$stack")\", \"success\": $success, \"message\": \"$(_api_json_escape "$output")\"}")
    done

    local results_json
    if [[ ${#results[@]} -gt 0 ]]; then
        results_json=$(printf '%s,' "${results[@]}")
        results_json="[${results_json%,}]"
    else
        results_json="[]"
    fi

    _api_success "{\"action\": \"$action\", \"total\": ${#target_stacks[@]}, \"results\": $results_json}"
}

handle_batch_update() {
    local body="$1"

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for batch operations"
        return
    fi

    local stacks_input
    stacks_input=$(printf '%s' "$body" | jq -r '.stacks' 2>/dev/null)

    local -a target_stacks=()
    if [[ "$stacks_input" == '"all"' || "$stacks_input" == 'all' ]]; then
        while IFS= read -r dir; do
            [[ -f "$dir/docker-compose.yml" ]] && target_stacks+=("$(basename "$dir")")
        done < <(find "$COMPOSE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    else
        while IFS= read -r s; do
            [[ -n "$s" ]] && target_stacks+=("$s")
        done < <(printf '%s' "$body" | jq -r '.stacks[]' 2>/dev/null)
    fi

    local -a results=()
    for stack in "${target_stacks[@]}"; do
        local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
        if [[ ! -f "$compose_file" ]]; then
            results+=("{\"stack\": \"$(_api_json_escape "$stack")\", \"success\": false, \"changes_detected\": false, \"message\": \"Stack not found\"}")
            continue
        fi

        local compose_args=(-f "$compose_file")
        [[ -f "$COMPOSE_DIR/$stack/.env" ]] && compose_args+=(--env-file "$COMPOSE_DIR/$stack/.env")

        local before_shas
        before_shas=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" images -q 2>/dev/null | sort)

        local pull_output
        pull_output=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" pull 2>&1)

        local after_shas
        after_shas=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" images -q 2>/dev/null | sort)

        local changes_detected=false
        if [[ "$before_shas" != "$after_shas" ]]; then
            changes_detected=true
            $DOCKER_COMPOSE_CMD "${compose_args[@]}" up -d 2>&1 || true
        fi

        results+=("{\"stack\": \"$(_api_json_escape "$stack")\", \"success\": true, \"changes_detected\": $changes_detected, \"message\": \"$(_api_json_escape "$pull_output")\"}")
    done

    local results_json
    if [[ ${#results[@]} -gt 0 ]]; then
        results_json=$(printf '%s,' "${results[@]}")
        results_json="[${results_json%,}]"
    else
        results_json="[]"
    fi

    _api_success "{\"action\": \"update\", \"total\": ${#target_stacks[@]}, \"results\": $results_json}"
}

# =============================================================================
# ROOT ENVIRONMENT HANDLERS (Phase 5)
# =============================================================================

handle_root_env() {
    local env_file="$BASE_DIR/.env"

    if [[ ! -f "$env_file" ]]; then
        _api_success "{\"raw\": \"\", \"variables\": []}"
        return
    fi

    local raw
    raw=$(cat "$env_file" 2>/dev/null)
    local escaped_raw
    escaped_raw=$(_api_json_escape "$raw")

    local -a vars=()
    local line_num=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        (( line_num++ ))
        if [[ -z "$line" ]]; then continue; fi
        if [[ "$line" =~ ^[[:space:]]*# ]]; then
            vars+=("{\"key\": \"\", \"value\": \"\", \"line\": $line_num, \"comment\": \"$(_api_json_escape "$line")\"}")
            continue
        fi
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            value="${value#\"}" ; value="${value%\"}"
            value="${value#\'}" ; value="${value%\'}"
            vars+=("{\"key\": \"$(_api_json_escape "$key")\", \"value\": \"$(_api_json_escape "$value")\", \"line\": $line_num, \"comment\": \"\"}")
        fi
    done < "$env_file"

    local vars_json
    if [[ ${#vars[@]} -gt 0 ]]; then
        vars_json=$(printf '%s,' "${vars[@]}")
        vars_json="[${vars_json%,}]"
    else
        vars_json="[]"
    fi

    _api_success "{\"raw\": \"$escaped_raw\", \"variables\": $vars_json}"
}

handle_root_env_update() {
    local body="$1"
    local env_file="$BASE_DIR/.env"

    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for env update"
        return
    fi

    local content
    content=$(printf '%s' "$body" | jq -r '.content // empty' 2>/dev/null)
    if [[ -z "$content" ]]; then
        _api_error 400 "Missing 'content' field in request body"
        return
    fi

    if [[ -f "$env_file" ]]; then
        cp "$env_file" "${env_file}.bak" 2>/dev/null
    fi

    printf '%s' "$content" > "$env_file" 2>/dev/null || {
        _api_error 500 "Failed to write .env file"
        return
    }

    _api_success "{\"success\": true, \"message\": \"Root .env file saved successfully\"}"
}

handle_env_validate() {
    local body="$1"

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for env validation"
        return
    fi

    local content
    content=$(printf '%s' "$body" | jq -r '.content // empty' 2>/dev/null)
    if [[ -z "$content" ]]; then
        _api_error 400 "Missing 'content' field in request body"
        return
    fi

    local -a errors=()
    local -a warnings=()
    local -a seen_keys=()
    local line_num=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        (( line_num++ ))
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            errors+=("{\"line\": $line_num, \"message\": \"$(_api_json_escape "Invalid syntax: $line")\"}")
            continue
        fi
        local key="${line%%=*}"
        for seen in "${seen_keys[@]}"; do
            if [[ "$seen" == "$key" ]]; then
                warnings+=("{\"line\": $line_num, \"message\": \"$(_api_json_escape "Duplicate key: $key")\"}")
                break
            fi
        done
        seen_keys+=("$key")
    done <<< "$content"

    local valid=true
    [[ ${#errors[@]} -gt 0 ]] && valid=false

    local errors_json warnings_json
    if [[ ${#errors[@]} -gt 0 ]]; then
        errors_json=$(printf '%s,' "${errors[@]}")
        errors_json="[${errors_json%,}]"
    else
        errors_json="[]"
    fi
    if [[ ${#warnings[@]} -gt 0 ]]; then
        warnings_json=$(printf '%s,' "${warnings[@]}")
        warnings_json="[${warnings_json%,}]"
    else
        warnings_json="[]"
    fi

    _api_success "{\"valid\": $valid, \"errors\": $errors_json, \"warnings\": $warnings_json}"
}

# =============================================================================
# BACKUP & RESTORE HANDLERS (Phase 6)
# =============================================================================

handle_backup_list() {
    local backup_dir="${BACKUP_DEST_DIR:-}"

    if [[ -z "$backup_dir" || ! -d "$backup_dir" ]]; then
        _api_success "{\"backups\": [], \"total\": 0}"
        return
    fi

    local -a entries=()
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        local filename size date_epoch
        filename=$(basename "$file")
        size=$(du -h "$file" 2>/dev/null | cut -f1)
        date_epoch=$(stat -c '%Y' "$file" 2>/dev/null || stat -f '%m' "$file" 2>/dev/null || echo "0")
        entries+=("{\"filename\": \"$(_api_json_escape "$filename")\", \"size\": \"$(_api_json_escape "$size")\", \"timestamp\": $date_epoch}")
    done < <(ls -1t "$backup_dir"/Docker-Compose-Backup-*.tar.gz 2>/dev/null)

    local entries_json
    if [[ ${#entries[@]} -gt 0 ]]; then
        entries_json=$(printf '%s,' "${entries[@]}")
        entries_json="[${entries_json%,}]"
    else
        entries_json="[]"
    fi

    _api_success "{\"backups\": $entries_json, \"total\": ${#entries[@]}}"
}

handle_backup_status() {
    local status_file="$API_AUTH_DIR/backup-status.json"

    if [[ -f "$status_file" ]]; then
        local status_content
        status_content=$(cat "$status_file" 2>/dev/null)
        _api_success "$status_content"
    else
        _api_success "{\"status\": \"idle\", \"last_backup\": null, \"progress\": null}"
    fi
}

handle_backup_config() {
    local backup_dest="${BACKUP_DEST_DIR:-}"
    local backup_source="${BACKUP_SOURCE_DIR:-$BASE_DIR}"
    local retention="${BACKUP_RETENTION_COUNT:-5}"
    local configured=false
    [[ -n "$backup_dest" ]] && configured=true

    _api_success "{\"configured\": $configured, \"destination\": \"$(_api_json_escape "$backup_dest")\", \"source\": \"$(_api_json_escape "$backup_source")\", \"retention_count\": $retention}"
}

handle_backup_trigger() {
    local body="$1"
    local backup_dir="${BACKUP_DEST_DIR:-}"

    if [[ -z "$backup_dir" ]]; then
        _api_error 400 "Backup not configured. Set BACKUP_DEST_DIR in .env"
        return
    fi

    mkdir -p "$backup_dir" 2>/dev/null

    local stack_filter=""
    if command -v jq >/dev/null 2>&1 && [[ -n "$body" ]]; then
        stack_filter=$(printf '%s' "$body" | jq -r '.stack // empty' 2>/dev/null)
    fi

    local status_file="$API_AUTH_DIR/backup-status.json"
    local backup_date
    backup_date=$(date '+%Y-%m-%d_%H%M%S')
    local backup_file="Docker-Compose-Backup-${backup_date}.tar.gz"
    local source_dir="${BACKUP_SOURCE_DIR:-$BASE_DIR}"

    printf '{"status": "running", "started_at": "%s", "filename": "%s", "progress": "Starting backup..."}' \
        "$(date -Iseconds)" "$backup_file" > "$status_file"

    (
        local tmpdir
        tmpdir=$(mktemp -d /tmp/dcs-backup-XXXXXX)

        printf '{"status": "running", "started_at": "%s", "filename": "%s", "progress": "Copying files..."}' \
            "$(date -Iseconds)" "$backup_file" > "$status_file"

        if [[ -n "$stack_filter" ]]; then
            [[ -d "$COMPOSE_DIR/$stack_filter" ]] && rsync -a "$COMPOSE_DIR/$stack_filter/" "$tmpdir/$stack_filter/" 2>/dev/null || true
            [[ -d "$APP_DATA_DIR/$stack_filter" ]] && rsync -a "$APP_DATA_DIR/$stack_filter/" "$tmpdir/App-Data/$stack_filter/" 2>/dev/null || true
        else
            rsync -a --exclude='.git' --exclude='node_modules' "$source_dir/" "$tmpdir/" 2>/dev/null || true
        fi

        printf '{"status": "running", "started_at": "%s", "filename": "%s", "progress": "Creating archive..."}' \
            "$(date -Iseconds)" "$backup_file" > "$status_file"

        if tar -czf "$backup_dir/$backup_file" -C "$tmpdir" . 2>/dev/null; then
            local final_size
            final_size=$(du -h "$backup_dir/$backup_file" 2>/dev/null | cut -f1)
            printf '{"status": "idle", "last_backup": {"filename": "%s", "size": "%s", "timestamp": "%s"}, "progress": null}' \
                "$backup_file" "$final_size" "$(date -Iseconds)" > "$status_file"
        else
            printf '{"status": "error", "error": "Archive creation failed", "progress": null}' > "$status_file"
        fi

        rm -rf "$tmpdir"

        local retention="${BACKUP_RETENTION_COUNT:-5}"
        local count
        count=$(ls -1 "$backup_dir"/Docker-Compose-Backup-*.tar.gz 2>/dev/null | wc -l)
        if [[ "$count" -gt "$retention" ]]; then
            ls -1t "$backup_dir"/Docker-Compose-Backup-*.tar.gz 2>/dev/null | tail -n "$(( count - retention ))" | xargs -r rm -f
        fi
    ) &

    _api_success "{\"success\": true, \"message\": \"Backup started in background\", \"filename\": \"$(_api_json_escape "$backup_file")\"}"
}

handle_backup_restore() {
    local body="$1"
    local backup_dir="${BACKUP_DEST_DIR:-}"

    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for restore"
        return
    fi

    local filename confirm
    filename=$(printf '%s' "$body" | jq -r '.filename // empty' 2>/dev/null)
    confirm=$(printf '%s' "$body" | jq -r '.confirm // empty' 2>/dev/null)

    if [[ -z "$filename" ]]; then
        _api_error 400 "Missing 'filename' in request body"
        return
    fi

    # Security: validate filename — reject path traversal and directory separators
    if [[ "$filename" == *"/"* ]] || [[ "$filename" == *".."* ]] || [[ "$filename" == "."* ]]; then
        _api_error 400 "Invalid backup filename"
        return
    fi
    # Enforce safe filename pattern (alphanumeric, dots, hyphens, underscores)
    if [[ ! "$filename" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        _api_error 400 "Invalid backup filename"
        return
    fi

    if [[ "$confirm" != "RESTORE" ]]; then
        _api_error 400 "Restore requires {\"confirm\": \"RESTORE\"} in request body"
        return
    fi

    local archive_path="$backup_dir/$filename"
    # Security: verify resolved path stays within backup directory
    local resolved_path
    resolved_path=$(realpath -m "$archive_path" 2>/dev/null)
    if [[ "$resolved_path" != "$backup_dir/"* ]]; then
        _api_error 400 "Invalid backup filename"
        return
    fi
    if [[ ! -f "$archive_path" ]]; then
        _api_error 404 "Backup file not found: $filename"
        return
    fi

    if ! tar -tzf "$archive_path" >/dev/null 2>&1; then
        _api_error 400 "Backup archive is corrupt or invalid"
        return
    fi

    local status_file="$API_AUTH_DIR/backup-status.json"
    printf '{"status": "restoring", "filename": "%s", "progress": "Restoring from backup..."}' "$filename" > "$status_file"

    (
        local target="${BACKUP_SOURCE_DIR:-$BASE_DIR}"
        if tar -xzf "$archive_path" -C "$target" 2>/dev/null; then
            printf '{"status": "idle", "last_restore": {"filename": "%s", "timestamp": "%s"}, "progress": null}' \
                "$filename" "$(date -Iseconds)" > "$status_file"
        else
            printf '{"status": "error", "error": "Restore failed", "progress": null}' > "$status_file"
        fi
    ) &

    _api_success "{\"success\": true, \"message\": \"Restore started in background\", \"filename\": \"$(_api_json_escape "$filename")\"}"
}

# =============================================================================
# STACK CREATE / DELETE HANDLERS
# =============================================================================

handle_create_stack() {
    local body="$1"

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for stack creation"
        return
    fi

    local name
    name=$(echo "$body" | jq -r '.name // empty' 2>/dev/null)

    if [[ -z "$name" ]]; then
        _api_error 400 "Missing required field: name"
        return
    fi

    # Validate name: lowercase letters, numbers, hyphens only
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]] && [[ ! "$name" =~ ^[a-z0-9]$ ]]; then
        _api_error 400 "Invalid stack name. Use lowercase letters, numbers, and hyphens only."
        return
    fi

    local stack_dir="$COMPOSE_DIR/$name"

    if [[ -d "$stack_dir" ]]; then
        _api_error 409 "Stack already exists: $name"
        return
    fi

    # Create directory
    mkdir -p "$stack_dir" 2>/dev/null
    if [[ ! -d "$stack_dir" ]]; then
        _api_error 500 "Failed to create stack directory"
        return
    fi

    # Create base docker-compose.yml
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

    # Create base .env
    cat > "$stack_dir/.env" <<ENV_EOF
# =============================================================================
# Stack: $name
# =============================================================================
# Stack-specific environment variables.
# Variables are inherited from the root .env file.
# Add any stack-specific overrides below.
# =============================================================================

# APP_DATA_DIR is inherited from root .env
# TZ is inherited from root .env
# PUID and PGID are inherited from root .env
ENV_EOF

    # Create App-Data directory
    mkdir -p "$stack_dir/App-Data" 2>/dev/null

    _api_success "{\"success\": true, \"name\": \"$name\", \"message\": \"Stack '$name' created successfully\"}"
}

handle_delete_stack() {
    local name="$1"

    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    if [[ -z "$name" ]]; then
        _api_error 400 "Missing stack name"
        return
    fi

    local stack_dir="$COMPOSE_DIR/$name"

    if [[ ! -d "$stack_dir" ]]; then
        _api_error 404 "Stack not found: $name"
        return
    fi

    # Safety: check if stack has running containers
    local running_count=0
    if [[ -f "$stack_dir/docker-compose.yml" ]]; then
        running_count=$($DOCKER_COMPOSE_CMD -f "$stack_dir/docker-compose.yml" ps -q 2>/dev/null | wc -l || true)
    fi

    if [[ "$running_count" -gt 0 ]] 2>/dev/null; then
        _api_error 409 "Cannot delete stack with running containers. Stop the stack first."
        return
    fi

    # Remove the stack directory (falls back to Docker for root-owned files)
    _force_remove_dir "$stack_dir"

    if [[ -d "$stack_dir" ]]; then
        _api_error 500 "Failed to delete stack directory — some files may be owned by root. Try stopping all containers first."
        return
    fi

    _api_success "{\"success\": true, \"name\": \"$name\", \"message\": \"Stack '$name' deleted successfully\"}"
}

# =============================================================================
# CONFIG UPDATE HANDLER
# =============================================================================

handle_config_update() {
    local body="$1"
    local env_file="$BASE_DIR/.env"

    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    if [[ ! -f "$env_file" ]]; then
        _api_error 500 "Configuration file not found: $env_file"
        return
    fi

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for config updates"
        return
    fi

    # Parse the JSON body and update .env file
    # Expected format: { "key": "value", "key2": "value2" }
    local -A updates=()
    local keys
    keys=$(echo "$body" | jq -r 'keys[]' 2>/dev/null)
    if [[ $? -ne 0 ]] || [[ -z "$keys" ]]; then
        _api_error 400 "Invalid JSON body"
        return
    fi

    # Allowed config keys that can be updated (safety whitelist)
    local -A allowed_keys=(
        [ENVIRONMENT]=1 [LOG_LEVEL]=1 [SKIP_HEALTHCHECK_WAIT]=1
        [CONTINUE_ON_FAILURE]=1 [REMOVE_VOLUMES_ON_STOP]=1
        [AGGRESSIVE_IMAGE_PRUNE]=1 [UPDATE_NOTIFICATION]=1
        [SHOW_BANNERS]=1 [API_PORT]=1 [API_BIND]=1 [API_ENABLED]=1
        [SERVER_NAME]=1 [TZ]=1 [NTFY_URL]=1 [NTFY_TOPIC]=1
        [NTFY_PRIORITY]=1 [ENABLE_COLORS]=1 [COLOR_MODE]=1
    )

    local changed=0
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        if [[ -z "${allowed_keys[$key]:-}" ]]; then
            _api_error 400 "Key not allowed: $key"
            return
        fi
        local value
        value=$(echo "$body" | jq -r ".[\"$key\"]" 2>/dev/null)
        updates["$key"]="$value"
    done <<< "$keys"

    # Backup current .env
    cp "$env_file" "${env_file}.bak" 2>/dev/null

    # Apply updates to .env file
    for key in "${!updates[@]}"; do
        local value="${updates[$key]}"
        # Security: reject values containing newlines (could inject additional env entries)
        if [[ "$value" == *$'\n'* ]] || [[ "$value" == *$'\r'* ]]; then
            _api_error 400 "Value for $key contains invalid characters"
            return
        fi
        # Use grep+temp file approach instead of sed to avoid sed injection
        if grep -q "^${key}=" "$env_file" 2>/dev/null; then
            # Remove existing key line and rewrite (avoids sed metacharacter issues)
            grep -v "^${key}=" "$env_file" > "${env_file}.tmp" 2>/dev/null
            printf '%s=%s\n' "$key" "$value" >> "${env_file}.tmp"
            mv "${env_file}.tmp" "$env_file"
        else
            # Append new key
            printf '%s=%s\n' "$key" "$value" >> "$env_file"
        fi
        changed=$(( changed + 1 ))
    done

    # Re-source .env to pick up changes
    set -a
    source "$env_file"
    set +a

    _api_success "{\"success\": true, \"updated\": $changed, \"message\": \"Configuration updated. Some changes may require a restart.\"}"
}

# =============================================================================
# TERMINAL LINUX AUTHENTICATION
# =============================================================================

# Multi-strategy Linux credential validation
_authenticate_linux_user() {
    local username="$1" password="$2"
    local auth_method=""

    # Strategy 1: Python3 PAM (cleanest — requires python3-pam)
    if python3 -c "import pam" 2>/dev/null; then
        auth_method="pam"
        TERM_AUTH_USER="$username" TERM_AUTH_PASS="$password" python3 << 'PYEOF' 2>/dev/null
import pam, os, sys
p = pam.pam()
sys.exit(0 if p.authenticate(os.environ['TERM_AUTH_USER'], os.environ['TERM_AUTH_PASS']) else 1)
PYEOF
        [[ $? -eq 0 ]] && { echo "$auth_method"; return 0; }
    fi

    # Strategy 2: Python3 pty + su (built-in — works on any system with su)
    if python3 -c "import pty" 2>/dev/null; then
        auth_method="python3-pty"
        TERM_AUTH_USER="$username" TERM_AUTH_PASS="$password" python3 << 'PYEOF' 2>/dev/null
import pty, os, sys, select, time

username = os.environ['TERM_AUTH_USER']
password = os.environ['TERM_AUTH_PASS']
marker = 'AUTH_OK_' + str(os.getpid()) + '_' + str(int(time.time()))

pid, fd = pty.fork()
if pid == 0:
    os.execvp('su', ['su', '-c', 'echo ' + marker, '--', username])
    os._exit(1)

output = b''
authenticated = False
password_sent = False
deadline = time.time() + 10

while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.5)
    if r:
        try:
            data = os.read(fd, 4096)
            if not data:
                break
            output += data
        except OSError:
            break
    if not password_sent and b'assword' in output:
        os.write(fd, (password + '\n').encode())
        password_sent = True
        output = b''
    if password_sent and marker.encode() in output:
        authenticated = True
        break

try:
    os.close(fd)
except OSError:
    pass
try:
    os.waitpid(pid, 0)
except ChildProcessError:
    pass

sys.exit(0 if authenticated else 1)
PYEOF
        [[ $? -eq 0 ]] && { echo "$auth_method"; return 0; }
    fi

    # Strategy 3: expect + su
    if command -v expect >/dev/null 2>&1; then
        auth_method="expect"
        local marker="AUTH_OK_$$_$(date +%s)"
        TERM_AUTH_PASS="$password" expect << EXPEOF 2>/dev/null
log_user 0
set timeout 10
spawn su - $username -c "echo $marker"
expect {
    -re {[Pp]assword:} { send "\$env(TERM_AUTH_PASS)\r"; exp_continue }
    "$marker" { exit 0 }
    timeout { exit 1 }
    eof { exit 1 }
}
EXPEOF
        [[ $? -eq 0 ]] && { echo "$auth_method"; return 0; }
    fi

    # Strategy 4: sshpass + ssh localhost
    if command -v sshpass >/dev/null 2>&1; then
        auth_method="sshpass"
        sshpass -p "$password" ssh -o StrictHostKeyChecking=no \
            -o ConnectTimeout=5 -o BatchMode=no \
            "$username@127.0.0.1" 'echo AUTH_OK' 2>/dev/null | grep -q AUTH_OK && { echo "$auth_method"; return 0; }
    fi

    return 1
}

# Validate terminal session token
_validate_terminal_session() {
    local token="$1"
    local sessions_file="$BASE_DIR/.api-auth/terminal-sessions.json"

    [[ -z "$token" ]] && return 1
    [[ ! -f "$sessions_file" ]] && return 1

    local now
    now=$(date +%s)

    if command -v jq >/dev/null 2>&1; then
        local session
        session=$(jq -r --arg t "$token" '.sessions[] | select(.token == $t)' "$sessions_file" 2>/dev/null)
        [[ -z "$session" ]] && return 1

        local expires_at
        expires_at=$(echo "$session" | jq -r '.expires_at' 2>/dev/null)
        [[ "$now" -gt "$expires_at" ]] && return 1

        # Return username via stdout
        echo "$session" | jq -r '.username' 2>/dev/null
        return 0
    else
        # Fallback: grep-based validation
        if grep -q "\"token\":\"$token\"" "$sessions_file" 2>/dev/null || \
           grep -q "\"token\": \"$token\"" "$sessions_file" 2>/dev/null; then
            # Basic expiry check not possible without jq — allow
            echo "unknown"
            return 0
        fi
        return 1
    fi
}

# POST /terminal/auth — Authenticate with Linux credentials
handle_terminal_auth() {
    local body="$1"

    if ! _api_check_admin; then return; fi

    local username password
    if command -v jq >/dev/null 2>&1; then
        username=$(echo "$body" | jq -r '.username // empty' 2>/dev/null)
        password=$(echo "$body" | jq -r '.password // empty' 2>/dev/null)
    else
        username=$(echo "$body" | sed -n 's/.*"username" *: *"\([^"]*\)".*/\1/p')
        password=$(echo "$body" | sed -n 's/.*"password" *: *"\([^"]*\)".*/\1/p')
    fi

    [[ -z "$username" ]] && { _api_error 400 "Missing 'username' field"; return; }
    [[ -z "$password" ]] && { _api_error 400 "Missing 'password' field"; return; }

    local auth_audit="$BASE_DIR/.api-auth/terminal-auth-audit.log"
    local rate_file="$BASE_DIR/.api-auth/terminal-auth-rate.json"
    local sessions_file="$BASE_DIR/.api-auth/terminal-sessions.json"
    mkdir -p "$BASE_DIR/.api-auth"

    # Initialize sessions file if needed
    [[ ! -f "$sessions_file" ]] && echo '{"sessions":[]}' > "$sessions_file"

    # Rate limit: 5 failed attempts per 15 minutes per IP
    local client_ip="${SOCAT_PEERADDR:-127.0.0.1}"
    local now
    now=$(date +%s)
    local window_start=$(( now - 900 ))

    if command -v jq >/dev/null 2>&1 && [[ -f "$rate_file" ]]; then
        local fail_count
        fail_count=$(jq -r --arg ip "$client_ip" --argjson cutoff "$window_start" \
            '[.attempts[] | select(.ip == $ip and .timestamp > $cutoff and .success == false)] | length' \
            "$rate_file" 2>/dev/null || echo 0)
        if (( fail_count >= 5 )); then
            echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') | RATE_LIMITED | ip=$client_ip | user=$username" >> "$auth_audit"
            _api_error 429 "Too many failed attempts. Try again in 15 minutes."
            return
        fi
    fi

    # Initialize rate file if needed
    [[ ! -f "$rate_file" ]] && echo '{"attempts":[]}' > "$rate_file"

    # Authenticate against Linux system
    local auth_method
    auth_method=$(_authenticate_linux_user "$username" "$password")
    local auth_result=$?

    if [[ $auth_result -ne 0 ]]; then
        # Log failed attempt
        echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') | FAILED | ip=$client_ip | user=$username" >> "$auth_audit"

        # Record rate limit
        if command -v jq >/dev/null 2>&1; then
            local tmp_rate
            tmp_rate=$(jq --arg ip "$client_ip" --argjson ts "$now" \
                '.attempts += [{"ip": $ip, "timestamp": $ts, "success": false}]' \
                "$rate_file" 2>/dev/null)
            [[ -n "$tmp_rate" ]] && echo "$tmp_rate" > "$rate_file"
        fi

        _api_error 401 "Invalid Linux credentials"
        return
    fi

    # Generate session token
    local token
    token=$(head -c 32 /dev/urandom | xxd -p | tr -d '\n' 2>/dev/null || openssl rand -hex 32 2>/dev/null || cat /proc/sys/kernel/random/uuid | tr -d '-' | head -c 64)

    local expiry_seconds="${TERMINAL_SESSION_EXPIRY:-14400}"
    local expires_at=$(( now + expiry_seconds ))

    # Store session
    if command -v jq >/dev/null 2>&1; then
        local tmp_sessions
        # Clean expired sessions first
        tmp_sessions=$(jq --argjson now "$now" \
            '.sessions = [.sessions[] | select(.expires_at > $now)]' \
            "$sessions_file" 2>/dev/null)
        [[ -n "$tmp_sessions" ]] && echo "$tmp_sessions" > "$sessions_file"

        # Add new session
        tmp_sessions=$(jq --arg t "$token" --arg u "$username" --argjson c "$now" --argjson e "$expires_at" --arg m "$auth_method" \
            '.sessions += [{"token": $t, "username": $u, "created_at": $c, "expires_at": $e, "auth_method": $m}]' \
            "$sessions_file" 2>/dev/null)
        [[ -n "$tmp_sessions" ]] && echo "$tmp_sessions" > "$sessions_file"
    else
        # Fallback: append to a simple log
        echo "{\"token\":\"$token\",\"username\":\"$username\",\"created_at\":$now,\"expires_at\":$expires_at}" >> "$sessions_file.fallback"
    fi

    # Log success
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') | SUCCESS | ip=$client_ip | user=$username | method=$auth_method" >> "$auth_audit"

    # Record rate limit (success)
    if command -v jq >/dev/null 2>&1; then
        local tmp_rate
        tmp_rate=$(jq --arg ip "$client_ip" --argjson ts "$now" \
            '.attempts += [{"ip": $ip, "timestamp": $ts, "success": true}]' \
            "$rate_file" 2>/dev/null)
        [[ -n "$tmp_rate" ]] && echo "$tmp_rate" > "$rate_file"
    fi

    _api_success "{\"success\": true, \"token\": \"$token\", \"username\": \"$(_api_json_escape "$username")\", \"expires_in\": $expiry_seconds, \"auth_method\": \"$auth_method\", \"message\": \"Terminal session authenticated\"}"
}

# POST /terminal/auth/verify — Verify a terminal session token
handle_terminal_auth_verify() {
    local body="$1"

    if ! _api_check_admin; then return; fi

    local token
    if command -v jq >/dev/null 2>&1; then
        token=$(echo "$body" | jq -r '.token // empty' 2>/dev/null)
    else
        token=$(echo "$body" | sed -n 's/.*"token" *: *"\([^"]*\)".*/\1/p')
    fi

    [[ -z "$token" ]] && { _api_error 400 "Missing 'token' field"; return; }

    local session_user
    session_user=$(_validate_terminal_session "$token")
    if [[ $? -eq 0 && -n "$session_user" ]]; then
        local sessions_file="$BASE_DIR/.api-auth/terminal-sessions.json"
        local expires_at=""
        if command -v jq >/dev/null 2>&1; then
            expires_at=$(jq -r --arg t "$token" '.sessions[] | select(.token == $t) | .expires_at' "$sessions_file" 2>/dev/null)
        fi
        _api_success "{\"valid\": true, \"username\": \"$(_api_json_escape "$session_user")\", \"expires_at\": ${expires_at:-0}}"
    else
        _api_success "{\"valid\": false, \"username\": \"\", \"expires_at\": 0}"
    fi
}

# POST /terminal/auth/logout — Invalidate a terminal session
handle_terminal_logout() {
    local body="$1"

    if ! _api_check_admin; then return; fi

    local token
    if command -v jq >/dev/null 2>&1; then
        token=$(echo "$body" | jq -r '.token // empty' 2>/dev/null)
    else
        token=$(echo "$body" | sed -n 's/.*"token" *: *"\([^"]*\)".*/\1/p')
    fi

    [[ -z "$token" ]] && { _api_error 400 "Missing 'token' field"; return; }

    local sessions_file="$BASE_DIR/.api-auth/terminal-sessions.json"

    if command -v jq >/dev/null 2>&1 && [[ -f "$sessions_file" ]]; then
        local tmp
        tmp=$(jq --arg t "$token" '.sessions = [.sessions[] | select(.token != $t)]' "$sessions_file" 2>/dev/null)
        [[ -n "$tmp" ]] && echo "$tmp" > "$sessions_file"
    fi

    local auth_audit="$BASE_DIR/.api-auth/terminal-auth-audit.log"
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') | LOGOUT | token=${token:0:8}..." >> "$auth_audit"

    _api_success "{\"success\": true, \"message\": \"Terminal session ended\"}"
}

# =============================================================================
# TERMINAL EXEC / HISTORY
# =============================================================================

handle_terminal_exec() {
    local body="$1"

    if ! _api_check_admin; then return; fi

    # Validate terminal session token
    local terminal_token
    if command -v jq >/dev/null 2>&1; then
        terminal_token=$(echo "$body" | jq -r '.terminal_token // empty' 2>/dev/null)
    else
        terminal_token=$(echo "$body" | sed -n 's/.*"terminal_token" *: *"\([^"]*\)".*/\1/p')
    fi

    local session_user=""
    if [[ -n "$terminal_token" ]]; then
        session_user=$(_validate_terminal_session "$terminal_token")
        if [[ $? -ne 0 || -z "$session_user" ]]; then
            _api_error 401 "Terminal session expired. Please re-authenticate with Linux credentials."
            return
        fi
    else
        _api_error 401 "Terminal authentication required. Please authenticate with Linux credentials first."
        return
    fi

    local command cwd
    if command -v jq >/dev/null 2>&1; then
        command=$(echo "$body" | jq -r '.command // empty' 2>/dev/null)
        cwd=$(echo "$body" | jq -r '.cwd // empty' 2>/dev/null)
    else
        command=$(echo "$body" | sed -n 's/.*"command" *: *"\([^"]*\)".*/\1/p')
        cwd=$(echo "$body" | sed -n 's/.*"cwd" *: *"\([^"]*\)".*/\1/p')
    fi

    [[ -z "$command" ]] && { _api_error 400 "Missing 'command' field"; return; }
    [[ -z "$cwd" ]] && cwd="$BASE_DIR"

    # ── Terminal Command Guard: block dangerous shell patterns ──
    local _cmd_lower="${command,,}"
    local -a _blocked_patterns=(
        "rm -rf /"          # filesystem wipe
        "rm -rf /*"         # filesystem wipe variant
        "mkfs"              # format disk
        "dd if="            # raw disk write
        "> /dev/sd"         # raw device write
        ":(){ :|:& };:"    # fork bomb
        "chmod -R 777 /"    # permission wipe
        "chown -R"          # ownership change on system dirs
        "/etc/shadow"       # password file access
        "/etc/passwd"       # user file access
        "curl.*| *bash"     # pipe-to-shell
        "wget.*| *bash"     # pipe-to-shell
        "curl.*| *sh"       # pipe-to-shell
        "wget.*| *sh"       # pipe-to-shell
        "shutdown"          # system shutdown
        "reboot"            # system reboot
        "init 0"            # system halt
        "poweroff"          # system poweroff
    )

    for _pat in "${_blocked_patterns[@]}"; do
        if [[ "$_cmd_lower" == *"${_pat,,}"* ]]; then
            local client_ip="${SOCAT_PEERADDR:-unknown}"
            _api_audit_log "$client_ip" "TERM_BLOCKED" "$session_user" "Blocked: $command"
            _api_error 403 "Command blocked by security policy"
            return
        fi
    done

    # Rate limit: 10 commands/minute
    local rate_file="$BASE_DIR/.api-auth/terminal-rate.log"
    local audit_file="$BASE_DIR/.api-auth/terminal-audit.log"
    mkdir -p "$BASE_DIR/.api-auth"

    local now
    now=$(date +%s)
    local one_min_ago=$(( now - 60 ))

    if [[ -f "$rate_file" ]]; then
        local recent_count
        recent_count=$(awk -v cutoff="$one_min_ago" '$1 >= cutoff' "$rate_file" 2>/dev/null | wc -l)
        if (( recent_count >= 10 )); then
            _api_error 429 "Rate limit exceeded: 10 commands per minute"
            return
        fi
    fi

    echo "$now" >> "$rate_file"

    # Execute command
    local output exit_code
    output=$(cd "$cwd" 2>/dev/null && timeout 60 bash -c "$command" 2>&1) || true
    exit_code=${PIPESTATUS[0]:-$?}

    # Audit log (includes Linux username)
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') | linux_user=$session_user | exit=$exit_code | cwd=$cwd | cmd=$command" >> "$audit_file"

    local success="true"
    [[ "$exit_code" -ne 0 ]] && success="false"

    _api_success "{\"command\": \"$(_api_json_escape "$command")\", \"cwd\": \"$(_api_json_escape "$cwd")\", \"exit_code\": $exit_code, \"output\": \"$(_api_json_escape "$output")\", \"success\": $success, \"timestamp\": \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\"}"
}

handle_terminal_history() {
    if ! _api_check_admin; then return; fi

    local audit_file="$BASE_DIR/.api-auth/terminal-audit.log"

    if [[ ! -f "$audit_file" ]]; then
        _api_success "{\"commands\": [], \"total\": 0}"
        return
    fi

    local lines
    lines=$(tail -50 "$audit_file" 2>/dev/null | tac)

    local json_arr="["
    local first=true
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        $first || json_arr+=","
        first=false
        json_arr+="\"$(_api_json_escape "$line")\""
    done <<< "$lines"
    json_arr+="]"

    local total
    total=$(wc -l < "$audit_file" 2>/dev/null || echo 0)

    _api_success "{\"commands\": $json_arr, \"total\": $total}"
}

# =============================================================================
# CONTAINER FILE BROWSER
# =============================================================================

# GET /containers/:name/files?path=/ — List directory contents inside a container
handle_container_files() {
    if ! _api_check_admin; then return; fi

    local container="$1"
    local query_path="$2"
    [[ -z "$container" ]] && { _api_error 400 "Missing container name"; return; }
    [[ -z "$query_path" ]] && query_path="/"

    # SECURITY: Reject path traversal attempts
    if [[ "$query_path" == *".."* ]] || [[ "$query_path" == *$'\0'* ]] || [[ "$query_path" == *"~"* ]]; then
        _api_error 400 "Invalid file path — path traversal not allowed"
        return
    fi
    if [[ "$query_path" != /* ]]; then
        query_path="/$query_path"
    fi

    # Verify container exists and is running
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null)
    [[ -z "$state" ]] && { _api_error 404 "Container not found: $container"; return; }
    [[ "$state" != "running" ]] && { _api_error 400 "Container is not running (state: $state)"; return; }

    # List directory with detailed info
    local output
    # Use ls -la; try --time-style=long-iso (GNU) first, fall back to plain ls -la (BusyBox)
    output=$(docker exec "$container" ls -la --time-style=long-iso "$query_path" 2>/dev/null) || \
    output=$(docker exec "$container" ls -la "$query_path" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        _api_error 400 "Failed to list directory: $(_api_json_escape "$output")"
        return
    fi

    # Parse ls -la output into JSON entries
    # Supports both GNU (--time-style=long-iso: date in col 6-7, name at 8+)
    # and BusyBox (date in col 6-8, name at 9+)
    local json_entries="["
    local first=true
    while IFS= read -r line; do
        # Skip total line and . / .. entries
        [[ "$line" =~ ^total ]] && continue
        [[ -z "$line" ]] && continue

        local perms type_char name_field size_field date_field
        perms=$(echo "$line" | awk '{print $1}')
        size_field=$(echo "$line" | awk '{print $5}')
        # Detect format: GNU --time-style=long-iso has YYYY-MM-DD in col 6
        local col6
        col6=$(echo "$line" | awk '{print $6}')
        if [[ "$col6" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            # GNU format: date(6) time(7) name(8+)
            date_field=$(echo "$line" | awk '{print $6" "$7}')
            name_field=$(echo "$line" | awk '{for(i=8;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//')
        else
            # BusyBox format: month(6) day(7) time-or-year(8) name(9+)
            date_field=$(echo "$line" | awk '{print $6" "$7" "$8}')
            name_field=$(echo "$line" | awk '{for(i=9;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//')
        fi

        # Skip . and ..
        [[ "$name_field" == "." || "$name_field" == ".." ]] && continue
        [[ -z "$name_field" ]] && continue

        # Determine type
        type_char="${perms:0:1}"
        local ftype="file"
        [[ "$type_char" == "d" ]] && ftype="directory"
        [[ "$type_char" == "l" ]] && ftype="symlink"

        $first || json_entries+=","
        first=false
        json_entries+="{\"name\": \"$(_api_json_escape "$name_field")\", \"type\": \"$ftype\", \"size\": ${size_field:-0}, \"permissions\": \"$perms\", \"modified\": \"$(_api_json_escape "$date_field")\"}"
    done <<< "$output"
    json_entries+="]"

    _api_success "{\"container\": \"$(_api_json_escape "$container")\", \"path\": \"$(_api_json_escape "$query_path")\", \"entries\": $json_entries}"
}

# GET /containers/:name/files/content?path=/etc/hostname — Read file contents inside a container
handle_container_file_content() {
    if ! _api_check_admin; then return; fi

    local container="$1"
    local file_path="$2"
    [[ -z "$container" ]] && { _api_error 400 "Missing container name"; return; }
    [[ -z "$file_path" ]] && { _api_error 400 "Missing file path"; return; }

    # SECURITY: Reject path traversal attempts
    if [[ "$file_path" == *".."* ]] || [[ "$file_path" == *$'\0'* ]] || [[ "$file_path" == *"~"* ]]; then
        _api_error 400 "Invalid file path — path traversal not allowed"
        return
    fi
    if [[ "$file_path" != /* ]]; then
        file_path="/$file_path"
    fi

    # Verify container exists and is running
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null)
    [[ -z "$state" ]] && { _api_error 404 "Container not found: $container"; return; }
    [[ "$state" != "running" ]] && { _api_error 400 "Container is not running"; return; }

    # Get file size first (limit to 1MB)
    local file_size
    file_size=$(docker exec "$container" stat -c %s "$file_path" 2>/dev/null || echo "0")
    if (( file_size > 1048576 )); then
        _api_error 400 "File too large (${file_size} bytes). Maximum 1MB."
        return
    fi

    local content
    content=$(docker exec "$container" cat "$file_path" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        _api_error 400 "Failed to read file: $(_api_json_escape "$content")"
        return
    fi

    _api_success "{\"container\": \"$(_api_json_escape "$container")\", \"path\": \"$(_api_json_escape "$file_path")\", \"content\": \"$(_api_json_escape "$content")\", \"size\": $file_size}"
}

# =============================================================================
# ALERT THRESHOLDS CONFIGURATION
# =============================================================================

# GET /alerts/config — Read alert thresholds
handle_alerts_config() {
    if ! _api_check_admin; then return; fi

    local alerts_file="$BASE_DIR/.api-auth/alerts.json"
    mkdir -p "$BASE_DIR/.api-auth"

    # Initialize with defaults if not exists
    if [[ ! -f "$alerts_file" ]]; then
        cat > "$alerts_file" << 'ALERTS_EOF'
{
    "thresholds": {
        "cpu_warning": 80,
        "cpu_critical": 95,
        "memory_warning": 80,
        "memory_critical": 95,
        "disk_warning": 85,
        "disk_critical": 95,
        "restart_threshold": 5
    }
}
ALERTS_EOF
    fi

    local config
    if command -v jq >/dev/null 2>&1; then
        config=$(jq -c '.' "$alerts_file" 2>/dev/null)
    else
        config=$(cat "$alerts_file" 2>/dev/null)
    fi

    _api_success "$config"
}

# POST /alerts/config — Update alert thresholds
handle_alerts_config_update() {
    if ! _api_check_admin; then return; fi

    local body="$1"
    local alerts_file="$BASE_DIR/.api-auth/alerts.json"
    mkdir -p "$BASE_DIR/.api-auth"

    if command -v jq >/dev/null 2>&1; then
        # Validate it's valid JSON with expected structure
        local thresholds
        thresholds=$(echo "$body" | jq -r '.thresholds // empty' 2>/dev/null)
        if [[ -z "$thresholds" ]]; then
            _api_error 400 "Missing 'thresholds' object"
            return
        fi

        # Merge with defaults
        local defaults='{"thresholds":{"cpu_warning":80,"cpu_critical":95,"memory_warning":80,"memory_critical":95,"disk_warning":85,"disk_critical":95,"restart_threshold":5}}'
        local merged
        if [[ -f "$alerts_file" ]]; then
            merged=$(jq -s '.[0] * .[1]' "$alerts_file" <(echo "$body") 2>/dev/null)
        else
            merged=$(jq -s '.[0] * .[1]' <(echo "$defaults") <(echo "$body") 2>/dev/null)
        fi

        [[ -n "$merged" ]] && echo "$merged" > "$alerts_file"
        _api_success "{\"success\": true, \"message\": \"Alert thresholds updated\", \"thresholds\": $(echo "$merged" | jq '.thresholds' 2>/dev/null)}"
    else
        echo "$body" > "$alerts_file"
        _api_success "{\"success\": true, \"message\": \"Alert thresholds updated\"}"
    fi
}

# =============================================================================
# CRONTAB VIEWER/EDITOR
# =============================================================================

# GET /system/crontab — User crontab entries
handle_crontab() {
    if ! _api_check_admin; then return; fi

    local raw_crontab
    raw_crontab=$(crontab -l 2>&1 || echo "")

    # Parse cron entries into structured format
    local entries="["
    local first=true

    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^# ]] && continue
        [[ "$line" =~ "no crontab for" ]] && continue

        # Parse: min hour day month dow command
        local schedule cmd human_readable
        schedule=$(echo "$line" | awk '{print $1,$2,$3,$4,$5}')
        cmd=$(echo "$line" | awk '{for(i=6;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//')

        [[ -z "$cmd" ]] && continue

        # Generate human-readable description
        human_readable=$(_cron_to_human "$schedule")

        $first || entries+=","
        first=false
        entries+="{\"schedule\": \"$(_api_json_escape "$schedule")\", \"command\": \"$(_api_json_escape "$cmd")\", \"user\": \"$(whoami)\", \"source\": \"user\", \"human_readable\": \"$(_api_json_escape "$human_readable")\"}"
    done <<< "$raw_crontab"
    entries+="]"

    _api_success "{\"entries\": $entries, \"raw\": \"$(_api_json_escape "$raw_crontab")\"}"
}

# GET /system/crontab/system — System-level cron entries
handle_crontab_system() {
    if ! _api_check_admin; then return; fi

    local entries="["
    local first=true

    # Parse /etc/crontab
    if [[ -r /etc/crontab ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            [[ "$line" =~ ^# ]] && continue
            [[ "$line" =~ ^[A-Z_]+= ]] && continue

            local schedule user cmd human_readable
            schedule=$(echo "$line" | awk '{print $1,$2,$3,$4,$5}')
            user=$(echo "$line" | awk '{print $6}')
            cmd=$(echo "$line" | awk '{for(i=7;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//')

            [[ -z "$cmd" ]] && continue
            human_readable=$(_cron_to_human "$schedule")

            $first || entries+=","
            first=false
            entries+="{\"schedule\": \"$(_api_json_escape "$schedule")\", \"command\": \"$(_api_json_escape "$cmd")\", \"user\": \"$(_api_json_escape "$user")\", \"source\": \"system\", \"human_readable\": \"$(_api_json_escape "$human_readable")\"}"
        done < /etc/crontab
    fi

    # List files in /etc/cron.d/
    if [[ -d /etc/cron.d ]]; then
        for cronfile in /etc/cron.d/*; do
            [[ -f "$cronfile" ]] || continue
            local fname
            fname=$(basename "$cronfile")
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                [[ "$line" =~ ^# ]] && continue
                [[ "$line" =~ ^[A-Z_]+= ]] && continue

                local schedule user cmd human_readable
                schedule=$(echo "$line" | awk '{print $1,$2,$3,$4,$5}')
                user=$(echo "$line" | awk '{print $6}')
                cmd=$(echo "$line" | awk '{for(i=7;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//')

                [[ -z "$cmd" ]] && continue
                human_readable=$(_cron_to_human "$schedule")

                $first || entries+=","
                first=false
                entries+="{\"schedule\": \"$(_api_json_escape "$schedule")\", \"command\": \"$(_api_json_escape "$cmd")\", \"user\": \"$(_api_json_escape "$user")\", \"source\": \"cron.d\", \"human_readable\": \"$(_api_json_escape "$human_readable")\"}"
            done < "$cronfile"
        done
    fi

    entries+="]"
    _api_success "{\"entries\": $entries}"
}

# POST /system/crontab — Update user crontab
handle_crontab_update() {
    if ! _api_check_admin; then return; fi

    local body="$1"
    local content
    if command -v jq >/dev/null 2>&1; then
        content=$(echo "$body" | jq -r '.content // empty' 2>/dev/null)
    else
        content=$(echo "$body" | sed -n 's/.*"content" *: *"\([^"]*\)".*/\1/p')
    fi

    [[ -z "$content" ]] && { _api_error 400 "Missing 'content' field"; return; }

    # Backup current crontab
    local backup_file="$BASE_DIR/.api-auth/crontab-backup-$(date +%s).txt"
    mkdir -p "$BASE_DIR/.api-auth"
    crontab -l > "$backup_file" 2>/dev/null || true

    # Install new crontab
    local output
    output=$(echo "$content" | crontab - 2>&1)
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        _api_success "{\"success\": true, \"message\": \"Crontab updated\", \"backup\": \"$(_api_json_escape "$backup_file")\"}"
    else
        _api_error 400 "Failed to update crontab: $(_api_json_escape "$output")"
    fi
}

# Helper: Convert cron expression to human-readable text
_cron_to_human() {
    local schedule="$1"
    local min hour dom mon dow
    read -r min hour dom mon dow <<< "$schedule"

    # Handle common patterns
    if [[ "$min" == "*" && "$hour" == "*" && "$dom" == "*" && "$mon" == "*" && "$dow" == "*" ]]; then
        echo "Every minute"; return
    fi
    if [[ "$min" == "0" && "$hour" == "*" && "$dom" == "*" && "$mon" == "*" && "$dow" == "*" ]]; then
        echo "Every hour"; return
    fi
    if [[ "$min" != "*" && "$hour" != "*" && "$dom" == "*" && "$mon" == "*" && "$dow" == "*" ]]; then
        printf "Daily at %s:%02d" "$hour" "$min"; return
    fi
    if [[ "$min" != "*" && "$hour" != "*" && "$dom" == "*" && "$mon" == "*" && "$dow" == "0" ]]; then
        printf "Weekly (Sun) at %s:%02d" "$hour" "$min"; return
    fi
    if [[ "$min" != "*" && "$hour" != "*" && "$dom" == "1" && "$mon" == "*" && "$dow" == "*" ]]; then
        printf "Monthly (1st) at %s:%02d" "$hour" "$min"; return
    fi
    if [[ "$min" == "*/5" ]]; then
        echo "Every 5 minutes"; return
    fi
    if [[ "$min" == "*/10" ]]; then
        echo "Every 10 minutes"; return
    fi
    if [[ "$min" == "*/15" ]]; then
        echo "Every 15 minutes"; return
    fi
    if [[ "$min" == "*/30" ]]; then
        echo "Every 30 minutes"; return
    fi
    if [[ "$hour" == "*/2" ]]; then
        echo "Every 2 hours at :${min}"; return
    fi

    echo "$schedule"
}

# =============================================================================
# CONTAINER LOG STREAMING (LONG-POLL)
# =============================================================================

# GET /containers/:name/logs/live?lines=100&since=<timestamp> — Fetch recent logs for polling
handle_container_logs_live() {
    if ! _api_check_admin; then return; fi

    local container="$1"
    local lines="${2:-100}"
    local since="$3"
    [[ -z "$container" ]] && { _api_error 400 "Missing container name"; return; }

    # Verify container exists
    docker inspect "$container" >/dev/null 2>&1 || { _api_error 404 "Container not found: $container"; return; }

    local log_output
    if [[ -n "$since" ]]; then
        log_output=$(docker logs --since "$since" --timestamps "$container" 2>&1 | tail -"${lines}")
    else
        log_output=$(docker logs --tail "$lines" --timestamps "$container" 2>&1)
    fi

    # Parse into structured entries
    local json_entries="["
    local first=true
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local ts="" content="" level=""
        # Try to extract timestamp
        if [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+Z?) ]]; then
            ts="${BASH_REMATCH[1]}"
            content="${line#*Z }"
            [[ "$content" == "$line" ]] && content="${line#* }"
        else
            ts=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
            content="$line"
        fi

        # Detect log level
        if [[ "$content" =~ (ERROR|FATAL|CRIT) ]]; then
            level="error"
        elif [[ "$content" =~ (WARN|WARNING) ]]; then
            level="warn"
        elif [[ "$content" =~ (DEBUG|TRACE) ]]; then
            level="debug"
        else
            level="info"
        fi

        $first || json_entries+=","
        first=false
        json_entries+="{\"timestamp\": \"$(_api_json_escape "$ts")\", \"line\": \"$(_api_json_escape "$content")\", \"level\": \"$level\"}"
    done <<< "$log_output"
    json_entries+="]"

    local _lc; _lc=$(echo "$log_output" | grep -c . 2>/dev/null) || _lc=0
    _api_success "{\"container\": \"$(_api_json_escape "$container")\", \"entries\": $json_entries, \"count\": $_lc}"
}

# GET /logs/live?lines=100&since=<timestamp> — Stream DCS application log
handle_app_logs_live() {
    if ! _api_check_admin; then return; fi

    local lines="${1:-100}"
    local since="$2"
    local log_file="$BASE_DIR/logs/docker-services.log"

    [[ ! -f "$log_file" ]] && { _api_success "{\"entries\": [], \"count\": 0}"; return; }

    local log_output
    if [[ -n "$since" ]]; then
        # Get lines after the timestamp
        log_output=$(awk -v ts="$since" '$0 >= ts' "$log_file" 2>/dev/null | tail -"${lines}")
    else
        log_output=$(tail -"${lines}" "$log_file" 2>/dev/null)
    fi

    local json_entries="["
    local first=true
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local ts="" content="" level=""
        # Try to parse timestamp from log format [YYYY-MM-DD HH:MM:SS]
        if [[ "$line" =~ ^\[([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2})\] ]]; then
            ts="${BASH_REMATCH[1]}"
            content="${line#*] }"
        else
            ts=$(date -u '+%Y-%m-%dT%H:%M:%S')
            content="$line"
        fi

        if [[ "$content" =~ (ERROR|FATAL|CRIT) ]]; then
            level="error"
        elif [[ "$content" =~ (WARN|WARNING) ]]; then
            level="warn"
        elif [[ "$content" =~ (DEBUG|TRACE) ]]; then
            level="debug"
        else
            level="info"
        fi

        $first || json_entries+=","
        first=false
        json_entries+="{\"timestamp\": \"$(_api_json_escape "$ts")\", \"line\": \"$(_api_json_escape "$content")\", \"level\": \"$level\"}"
    done <<< "$log_output"
    json_entries+="]"

    local _lc; _lc=$(echo "$log_output" | grep -c . 2>/dev/null) || _lc=0
    _api_success "{\"entries\": $json_entries, \"count\": $_lc}"
}

# =============================================================================
# IMAGE DELETE
# =============================================================================

handle_image_delete() {
    if ! _api_check_admin; then return; fi

    local image_id="$1"
    [[ -z "$image_id" ]] && { _api_error 400 "Missing image ID"; return; }

    local output
    output=$(docker rmi "$image_id" 2>&1)
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        _api_success "{\"success\": true, \"image\": \"$(_api_json_escape "$image_id")\", \"message\": \"Image removed successfully\"}"
    else
        _api_error 500 "Failed to remove image: $(_api_json_escape "$output")"
    fi
}

# =============================================================================
# CONTAINER RENAME
# =============================================================================

handle_container_rename() {
    if ! _api_check_admin; then return; fi

    local name="$1"
    local body="$2"
    [[ -z "$name" ]] && { _api_error 400 "Missing container name"; return; }

    local new_name
    if command -v jq >/dev/null 2>&1; then
        new_name=$(echo "$body" | jq -r '.new_name // empty' 2>/dev/null)
    else
        new_name=$(echo "$body" | sed -n 's/.*"new_name" *: *"\([^"]*\)".*/\1/p')
    fi
    [[ -z "$new_name" ]] && { _api_error 400 "Missing 'new_name' field"; return; }

    local output
    output=$(docker rename "$name" "$new_name" 2>&1)
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        _api_success "{\"success\": true, \"old_name\": \"$(_api_json_escape "$name")\", \"new_name\": \"$(_api_json_escape "$new_name")\", \"message\": \"Container renamed successfully\"}"
    else
        _api_error 500 "Failed to rename container: $(_api_json_escape "$output")"
    fi
}

# =============================================================================
# STACK SERVICES DETAIL
# =============================================================================

handle_stack_services() {
    local stack_name="$1"
    [[ -z "$stack_name" ]] && { _api_error 400 "Missing stack name"; return; }

    local compose_file="$COMPOSE_DIR/$stack_name/docker-compose.yml"
    [[ ! -f "$compose_file" ]] && { _api_error 404 "Stack not found"; return; }

    local env_file="$COMPOSE_DIR/$stack_name/.env"
    local -a compose_args=(-f "$compose_file")
    [[ -f "$env_file" ]] && compose_args+=(--env-file "$env_file")

    local services_json="["
    local first=true

    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        $first || services_json+=","
        first=false

        local container_name state health image
        container_name=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" ps --format '{{.Name}}' "$svc" 2>/dev/null | head -1)

        if [[ -n "$container_name" ]]; then
            state=$(docker inspect --format='{{.State.Status}}' "$container_name" 2>/dev/null || echo "unknown")
            health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_name" 2>/dev/null || echo "none")
            image=$(docker inspect --format='{{.Config.Image}}' "$container_name" 2>/dev/null || echo "unknown")
        else
            state="not_created"
            health="none"
            image=""
            container_name=""
        fi

        services_json+="{\"name\": \"$(_api_json_escape "$svc")\", \"state\": \"$state\", \"health\": \"$health\", \"image\": \"$(_api_json_escape "$image")\", \"container\": \"$(_api_json_escape "$container_name")\"}"
    done < <($DOCKER_COMPOSE_CMD "${compose_args[@]}" config --services 2>/dev/null)

    services_json+="]"

    _api_success "{\"stack\": \"$(_api_json_escape "$stack_name")\", \"services\": $services_json}"
}

# =============================================================================
# SYSTEM UPDATE MANAGEMENT
# =============================================================================

# GET /system/update/check — Check for available DCS updates via git
handle_system_update_check() {
    cd "$BASE_DIR" || { _api_error 500 "Cannot access BASE_DIR"; return; }

    if ! command -v git >/dev/null 2>&1; then
        _api_error 500 "Git is not installed on this system"
        return
    fi

    if [[ ! -d "$BASE_DIR/.git" ]]; then
        _api_error 400 "Not a git repository — updates are not available for manual installations"
        return
    fi

    git fetch origin 2>/dev/null
    local current branch latest behind has_local changelog

    current=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    latest=$(git rev-parse --short "origin/$branch" 2>/dev/null || echo "$current")
    behind=$(git rev-list HEAD.."origin/$branch" --count 2>/dev/null || echo "0")
    has_local=$(git status --porcelain 2>/dev/null | head -1)

    # Get changelog (commits we're behind)
    changelog="[]"
    if [[ "$behind" -gt 0 ]]; then
        if command -v jq >/dev/null 2>&1; then
            changelog=$(git log HEAD.."origin/$branch" --pretty=format:'{"hash":"%h","message":"%s","author":"%an","date":"%ci"}' 2>/dev/null | head -20 | jq -s '.' 2>/dev/null || echo "[]")
        else
            # Fallback: build JSON array manually without jq
            local entries="" entry_line
            while IFS= read -r entry_line; do
                [[ -n "$entries" ]] && entries="$entries,"
                entries="$entries$entry_line"
            done < <(git log HEAD.."origin/$branch" --pretty=format:'{"hash":"%h","message":"%s","author":"%an","date":"%ci"}' 2>/dev/null | head -20)
            changelog="[$entries]"
        fi
    fi

    local available="false"
    [[ "$behind" -gt 0 ]] && available="true"

    local has_changes="false"
    [[ -n "$has_local" ]] && has_changes="true"

    _api_success "{
  \"available\": $available,
  \"current_version\": \"$(_api_json_escape "$current")\",
  \"latest_version\": \"$(_api_json_escape "$latest")\",
  \"commits_behind\": $behind,
  \"changelog\": $changelog,
  \"has_local_changes\": $has_changes,
  \"branch\": \"$(_api_json_escape "$branch")\"
}"
}

# POST /system/update/apply — Apply update safely using git pull --ff-only
handle_system_update_apply() {
    local body="$1"

    cd "$BASE_DIR" || { _api_error 500 "Cannot access BASE_DIR"; return; }

    if ! command -v git >/dev/null 2>&1; then
        _api_error 500 "Git is not installed on this system"
        return
    fi

    if [[ ! -d "$BASE_DIR/.git" ]]; then
        _api_error 400 "Not a git repository — updates are not available for manual installations"
        return
    fi

    # Optional: require explicit confirmation in the payload
    if command -v jq >/dev/null 2>&1 && [[ -n "$body" ]]; then
        local confirm
        confirm=$(printf '%s' "$body" | jq -r '.confirm // empty' 2>/dev/null)
        if [[ "$confirm" != "true" ]]; then
            _api_error 400 "Missing confirmation. Send {\"confirm\": true} to apply the update."
            return
        fi
    fi

    # Check for local changes — refuse to update if the working tree is dirty
    local has_local
    has_local=$(git status --porcelain 2>/dev/null | head -1)
    if [[ -n "$has_local" ]]; then
        _api_error 409 "Cannot update: local changes detected. Commit or stash changes before updating."
        return
    fi

    local branch current
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    current=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

    # Fetch latest
    git fetch origin 2>/dev/null

    local behind
    behind=$(git rev-list HEAD.."origin/$branch" --count 2>/dev/null || echo "0")
    if [[ "$behind" -eq 0 ]]; then
        _api_success "{
  \"updated\": false,
  \"message\": \"Already up to date\",
  \"current_version\": \"$(_api_json_escape "$current")\",
  \"branch\": \"$(_api_json_escape "$branch")\"
}"
        return
    fi

    # Create backup tag before updating
    local backup_tag
    backup_tag="dcs-backup-$(date +%Y%m%d-%H%M%S)-${current}"
    git tag "$backup_tag" HEAD 2>/dev/null || true

    # Attempt fast-forward-only pull (safe — no merge conflicts possible)
    local pull_output pull_exit
    pull_output=$(git pull --ff-only origin "$branch" 2>&1)
    pull_exit=$?

    if [[ $pull_exit -ne 0 ]]; then
        # Rollback to backup tag
        git checkout "$backup_tag" 2>/dev/null || true
        git checkout "$branch" 2>/dev/null || true
        git reset --hard "$backup_tag" 2>/dev/null || true

        local escaped_output
        escaped_output=$(_api_json_escape "$pull_output")
        _api_error 500 "Update failed (rolled back to $backup_tag): $escaped_output"
        return
    fi

    local new_version
    new_version=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

    # Collect changelog of what was applied
    local changelog="[]"
    if command -v jq >/dev/null 2>&1; then
        changelog=$(git log "${backup_tag}..HEAD" --pretty=format:'{"hash":"%h","message":"%s","author":"%an","date":"%ci"}' 2>/dev/null | head -20 | jq -s '.' 2>/dev/null || echo "[]")
    fi

    # NOTE: After a successful update, the API server process should be restarted
    # to pick up any code changes. The UI should trigger a restart or the server
    # can self-restart. A simple approach: touch a sentinel file that the server
    # monitors, or have the UI call a restart endpoint after update completes.

    _api_success "{
  \"updated\": true,
  \"previous_version\": \"$(_api_json_escape "$current")\",
  \"new_version\": \"$(_api_json_escape "$new_version")\",
  \"backup_tag\": \"$(_api_json_escape "$backup_tag")\",
  \"branch\": \"$(_api_json_escape "$branch")\",
  \"commits_applied\": $behind,
  \"changelog\": $changelog,
  \"message\": \"Update applied successfully. API server restart may be required to load new code.\"
}"
}

# POST /system/update/rollback — Rollback to a previously created backup tag
handle_system_update_rollback() {
    local body="$1"

    cd "$BASE_DIR" || { _api_error 500 "Cannot access BASE_DIR"; return; }

    if ! command -v git >/dev/null 2>&1; then
        _api_error 500 "Git is not installed on this system"
        return
    fi

    if [[ ! -d "$BASE_DIR/.git" ]]; then
        _api_error 400 "Not a git repository — rollback is not available for manual installations"
        return
    fi

    # Extract backup_tag from payload
    local backup_tag=""
    if command -v jq >/dev/null 2>&1 && [[ -n "$body" ]]; then
        backup_tag=$(printf '%s' "$body" | jq -r '.backup_tag // empty' 2>/dev/null)
    fi

    if [[ -z "$backup_tag" ]]; then
        # List available backup tags if none specified
        local tags_json="[]"
        local tag_list
        tag_list=$(git tag -l 'dcs-backup-*' --sort=-creatordate 2>/dev/null | head -20)
        if [[ -n "$tag_list" ]] && command -v jq >/dev/null 2>&1; then
            tags_json=$(printf '%s\n' "$tag_list" | jq -R '.' | jq -s '.' 2>/dev/null || echo "[]")
        fi
        _api_error 400 "Missing backup_tag in request body. Available tags: $(printf '%s' "$tag_list" | tr '\n' ', ' | sed 's/,$//')"
        return
    fi

    # Validate: backup_tag must match our naming pattern to prevent arbitrary checkout
    if [[ ! "$backup_tag" =~ ^dcs-backup-[0-9]{8}-[0-9]{6}-[a-f0-9]+$ ]]; then
        _api_error 400 "Invalid backup tag format. Expected: dcs-backup-YYYYMMDD-HHMMSS-<hash>"
        return
    fi

    # Verify the tag exists
    if ! git rev-parse "$backup_tag" >/dev/null 2>&1; then
        _api_error 404 "Backup tag not found: $backup_tag"
        return
    fi

    local current branch
    current=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

    # Perform rollback: reset the branch to the backup tag
    local reset_output reset_exit
    reset_output=$(git reset --hard "$backup_tag" 2>&1)
    reset_exit=$?

    if [[ $reset_exit -ne 0 ]]; then
        local escaped_output
        escaped_output=$(_api_json_escape "$reset_output")
        _api_error 500 "Rollback failed: $escaped_output"
        return
    fi

    local rolled_back_to
    rolled_back_to=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

    # NOTE: After rollback, the API server should be restarted to load the
    # previous version of the code. Same restart considerations as update/apply.

    _api_success "{
  \"rolled_back\": true,
  \"previous_version\": \"$(_api_json_escape "$current")\",
  \"restored_version\": \"$(_api_json_escape "$rolled_back_to")\",
  \"backup_tag\": \"$(_api_json_escape "$backup_tag")\",
  \"branch\": \"$(_api_json_escape "$branch")\",
  \"message\": \"Rollback successful. API server restart may be required to load restored code.\"
}"
}

# =============================================================================
# SYSTEM METRICS SNAPSHOT
# =============================================================================

handle_system_metrics() {
    local cpu_count load1 load5 load15
    cpu_count=$(nproc 2>/dev/null || echo 0)
    read -r load1 load5 load15 _ _ < /proc/loadavg 2>/dev/null || { load1=0; load5=0; load15=0; }

    local mem_total mem_used mem_available mem_cached swap_total swap_used
    mem_total=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    mem_available=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    mem_cached=$(awk '/^Cached:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    mem_used=$(( mem_total - mem_available ))
    swap_total=$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    swap_used=$(( swap_total - $(awk '/SwapFree/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0) ))

    # Disk: all mount points (word-split parsing to handle mount paths with spaces)
    local disk_json="["
    local first=true
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local -a fields
        read -ra fields <<< "$line"
        local nf=${#fields[@]}
        [[ $nf -lt 6 ]] && continue

        local pct="${fields[$((nf-1))]}"
        local avail="${fields[$((nf-2))]}"
        local used="${fields[$((nf-3))]}"
        local total="${fields[$((nf-4))]}"
        local dev="${fields[0]}"
        local mount="" i
        for ((i=1; i<nf-4; i++)); do
            [[ -n "$mount" ]] && mount+=" "
            mount+="${fields[$i]}"
        done

        [[ -z "$dev" || "$dev" != /* ]] && continue
        case "$mount" in
            /sys/*|/proc/*|/dev/*|/run/*|/snap/*) continue ;;
        esac
        $first || disk_json+=","
        first=false
        disk_json+="{\"device\": \"$(_api_json_escape "$dev")\", \"mount\": \"$(_api_json_escape "$mount")\", \"total\": \"$total\", \"used\": \"$used\", \"available\": \"$avail\", \"percent\": \"$pct\"}"
    done < <(df -h --output=source,target,size,used,avail,pcent -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null | tail -n +2)
    disk_json+="]"

    _api_success "{\"cpu\": {\"count\": $cpu_count, \"load_average\": [$load1, $load5, $load15]}, \"memory\": {\"total_mb\": $mem_total, \"used_mb\": $mem_used, \"available_mb\": $mem_available, \"cached_mb\": $mem_cached, \"swap_total_mb\": $swap_total, \"swap_used_mb\": $swap_used}, \"disks\": $disk_json}"
}

# =============================================================================
# FEATURE: RESOURCE USAGE TRENDS (metrics history)
# =============================================================================

METRICS_HISTORY_FILE="$BASE_DIR/.api-auth/metrics-history.jsonl"
METRICS_MAX_ENTRIES=10080

handle_metrics_snapshot() {
    # Capture current CPU/memory/disk and append to JSONL history
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local epoch
    epoch=$(date +%s)

    # CPU load
    local load1 load5 load15
    read -r load1 load5 load15 _ < /proc/loadavg 2>/dev/null || { load1=0; load5=0; load15=0; }
    local cpu_count
    cpu_count=$(nproc 2>/dev/null || echo 1)
    local cpu_pct
    cpu_pct=$(awk "BEGIN { printf \"%.1f\", ($load1 / $cpu_count) * 100 }")

    # Memory
    local mem_total=0 mem_available=0 mem_used=0
    while IFS=':' read -r key val; do
        val="${val// /}"; val="${val%%kB*}"
        case "$key" in
            MemTotal)     mem_total=$((val / 1024)) ;;
            MemAvailable) mem_available=$((val / 1024)) ;;
        esac
    done < /proc/meminfo 2>/dev/null
    mem_used=$((mem_total - mem_available))
    local mem_pct=0
    [[ $mem_total -gt 0 ]] && mem_pct=$(awk "BEGIN { printf \"%.1f\", ($mem_used / $mem_total) * 100 }")

    # Disk
    local disk_pct="0"
    local disk_line
    disk_line=$(df -h / 2>/dev/null | tail -1)
    if [[ -n "$disk_line" ]]; then
        disk_pct=$(echo "$disk_line" | awk '{print $5}' | tr -d '%')
    fi

    local entry="{\"ts\":\"$ts\",\"epoch\":$epoch,\"cpu_pct\":$cpu_pct,\"load1\":$load1,\"load5\":$load5,\"load15\":$load15,\"mem_used_mb\":$mem_used,\"mem_total_mb\":$mem_total,\"mem_pct\":$mem_pct,\"disk_pct\":$disk_pct}"

    # Append and cap file
    echo "$entry" >> "$METRICS_HISTORY_FILE"

    # Trim to max entries
    local line_count
    line_count=$(wc -l < "$METRICS_HISTORY_FILE" 2>/dev/null || echo 0)
    if [[ $line_count -gt $METRICS_MAX_ENTRIES ]]; then
        local excess=$((line_count - METRICS_MAX_ENTRIES))
        tail -n +"$((excess + 1))" "$METRICS_HISTORY_FILE" > "${METRICS_HISTORY_FILE}.tmp" && mv "${METRICS_HISTORY_FILE}.tmp" "$METRICS_HISTORY_FILE"
    fi

    _api_success "{\"success\": true, \"timestamp\": \"$ts\", \"cpu_pct\": $cpu_pct, \"mem_pct\": $mem_pct, \"disk_pct\": $disk_pct}"
}

handle_metrics_trends() {
    local range="${QUERY_PARAMS[range]:-1h}"
    local now
    now=$(date +%s)
    local cutoff=0

    case "$range" in
        1h)  cutoff=$((now - 3600)) ;;
        6h)  cutoff=$((now - 21600)) ;;
        24h) cutoff=$((now - 86400)) ;;
        7d)  cutoff=$((now - 604800)) ;;
        *)   cutoff=$((now - 3600)) ;;
    esac

    if [[ ! -f "$METRICS_HISTORY_FILE" ]]; then
        _api_success "{\"range\": \"$range\", \"points\": [], \"count\": 0}"
        return
    fi

    local -a points=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local epoch
        epoch=$(printf '%s' "$line" | grep -oP '"epoch":\K[0-9]+' 2>/dev/null || echo 0)
        [[ $epoch -ge $cutoff ]] && points+=("$line")
    done < "$METRICS_HISTORY_FILE"

    local json
    json=$(printf '%s,' "${points[@]}")
    json="[${json%,}]"
    [[ ${#points[@]} -eq 0 ]] && json="[]"

    _api_success "{\"range\": \"$range\", \"points\": $json, \"count\": ${#points[@]}}"
}

# =============================================================================
# FEATURE: IMAGE UPDATE CHECKER
# =============================================================================

UPDATE_HISTORY_FILE="$BASE_DIR/.api-auth/update-history.json"

handle_images_check_updates_get() {
    # Quick local staleness check (fast, no registry pull)
    local -a entries=()
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == "REPOSITORY"* ]] && continue
        local repo tag id created size
        read -r repo tag id created size <<< "$line"
        [[ "$repo" == "<none>" ]] && continue

        local full_image="${repo}:${tag}"
        local age_days=0
        local created_ts
        created_ts=$(docker inspect --format '{{.Created}}' "$full_image" 2>/dev/null | head -1)
        if [[ -n "$created_ts" ]]; then
            local created_epoch
            created_epoch=$(date -d "$created_ts" +%s 2>/dev/null || echo 0)
            local now_epoch
            now_epoch=$(date +%s)
            age_days=$(( (now_epoch - created_epoch) / 86400 ))
        fi

        local staleness="current"
        [[ $age_days -gt 30 ]] && staleness="stale"
        [[ $age_days -gt 7 && $age_days -le 30 ]] && staleness="aging"

        # Find containers using this image
        local containers
        containers=$(docker ps -a --filter "ancestor=$full_image" --format '{{.Names}}' 2>/dev/null | tr '\n' ',' | sed 's/,$//')

        # Determine stack
        local stack=""
        if [[ -n "$containers" ]]; then
            local first_container="${containers%%,*}"
            local labels
            labels=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$first_container" 2>/dev/null)
            [[ -n "$labels" && "$labels" != "<no value>" ]] && stack="$labels"
        fi

        entries+=("{\"image\": \"$(_api_json_escape "$full_image")\", \"repository\": \"$(_api_json_escape "$repo")\", \"tag\": \"$(_api_json_escape "$tag")\", \"age_days\": $age_days, \"staleness\": \"$staleness\", \"containers\": \"$(_api_json_escape "$containers")\", \"stack\": \"$(_api_json_escape "$stack")\", \"size\": \"$(_api_json_escape "$size")\"}")
    done < <(docker images --format "{{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.CreatedSince}}\t{{.Size}}" 2>/dev/null)

    local json
    json=$(printf '%s,' "${entries[@]}")
    json="[${json%,}]"
    [[ ${#entries[@]} -eq 0 ]] && json="[]"

    local stale_count=0 aging_count=0 current_count=0
    for e in "${entries[@]}"; do
        case "$e" in
            *'"staleness": "stale"'*) ((stale_count++)) ;;
            *'"staleness": "aging"'*) ((aging_count++)) ;;
            *) ((current_count++)) ;;
        esac
    done

    _api_success "{\"images\": $json, \"total\": ${#entries[@]}, \"stale\": $stale_count, \"aging\": $aging_count, \"current\": $current_count}"
}

handle_images_check_updates_post() {
    # Slow registry check: pull and compare digests
    local -a entries=()
    local updates_available=0

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == "REPOSITORY"* ]] && continue
        local repo tag id _rest
        read -r repo tag id _rest <<< "$line"
        [[ "$repo" == "<none>" || "$tag" == "<none>" ]] && continue

        local full_image="${repo}:${tag}"
        local old_id
        old_id=$(docker images -q "$full_image" 2>/dev/null | head -1)

        # Pull silently
        local pull_output
        pull_output=$(docker pull "$full_image" 2>&1)
        local new_id
        new_id=$(docker images -q "$full_image" 2>/dev/null | head -1)

        local update_available=false
        if [[ -n "$old_id" && -n "$new_id" && "$old_id" != "$new_id" ]]; then
            update_available=true
            ((updates_available++))
        fi

        entries+=("{\"image\": \"$(_api_json_escape "$full_image")\", \"old_id\": \"$(_api_json_escape "$old_id")\", \"new_id\": \"$(_api_json_escape "$new_id")\", \"update_available\": $update_available}")
    done < <(docker images --format "{{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}" 2>/dev/null)

    local json
    json=$(printf '%s,' "${entries[@]}")
    json="[${json%,}]"
    [[ ${#entries[@]} -eq 0 ]] && json="[]"

    _api_success "{\"images\": $json, \"total\": ${#entries[@]}, \"updates_available\": $updates_available, \"checked_at\": \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\"}"
}

handle_image_update() {
    local image_name="$1"
    # URL-decode the image name
    image_name=$(printf '%b' "${image_name//%/\\x}")

    if [[ -z "$image_name" ]]; then
        _api_error 400 "Image name is required"
        return
    fi

    # Pull the new image
    local pull_output
    pull_output=$(docker pull "$image_name" 2>&1) || {
        _api_error 500 "Failed to pull image: $(_api_json_escape "$pull_output")"
        return
    }

    # Find and restart containers using this image
    local -a restarted=()
    local containers
    containers=$(docker ps -q --filter "ancestor=$image_name" 2>/dev/null)
    for cid in $containers; do
        local cname
        cname=$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
        docker restart "$cid" >/dev/null 2>&1
        restarted+=("\"$(_api_json_escape "$cname")\"")
    done

    local restarted_json
    restarted_json=$(printf '%s,' "${restarted[@]}")
    restarted_json="[${restarted_json%,}]"
    [[ ${#restarted[@]} -eq 0 ]] && restarted_json="[]"

    # Log update
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    [[ ! -f "$UPDATE_HISTORY_FILE" ]] && echo "[]" > "$UPDATE_HISTORY_FILE"
    local history_entry="{\"image\": \"$(_api_json_escape "$image_name")\", \"timestamp\": \"$ts\", \"containers_restarted\": $restarted_json}"
    if command -v jq >/dev/null 2>&1; then
        jq --argjson entry "$history_entry" '. + [$entry] | .[-100:]' "$UPDATE_HISTORY_FILE" > "${UPDATE_HISTORY_FILE}.tmp" 2>/dev/null && mv "${UPDATE_HISTORY_FILE}.tmp" "$UPDATE_HISTORY_FILE"
    fi

    _api_success "{\"success\": true, \"image\": \"$(_api_json_escape "$image_name")\", \"containers_restarted\": $restarted_json, \"timestamp\": \"$ts\"}"
}

# =============================================================================
# FEATURE: NTFY NOTIFICATION RULES
# =============================================================================

NOTIFICATIONS_FILE="$BASE_DIR/.api-auth/notifications.json"

_init_notifications_file() {
    if [[ ! -f "$NOTIFICATIONS_FILE" ]]; then
        echo '{"rules": [], "history": []}' > "$NOTIFICATIONS_FILE"
    fi
}

handle_notification_rules_get() {
    _init_notifications_file
    if command -v jq >/dev/null 2>&1; then
        local rules
        rules=$(jq -c '.rules // []' "$NOTIFICATIONS_FILE" 2>/dev/null || echo "[]")
        _api_success "{\"rules\": $rules}"
    else
        _api_success "{\"rules\": []}"
    fi
}

handle_notification_rules_create() {
    local body="$1"
    _init_notifications_file

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required"
        return
    fi

    local name trigger target priority tags enabled
    name=$(printf '%s' "$body" | jq -r '.name // empty' 2>/dev/null)
    trigger=$(printf '%s' "$body" | jq -r '.trigger // empty' 2>/dev/null)
    target=$(printf '%s' "$body" | jq -r '.target // "*"' 2>/dev/null)
    priority=$(printf '%s' "$body" | jq -r '.priority // "default"' 2>/dev/null)
    tags=$(printf '%s' "$body" | jq -c '.tags // []' 2>/dev/null)
    enabled=$(printf '%s' "$body" | jq -r '.enabled // true' 2>/dev/null)

    if [[ -z "$name" || -z "$trigger" ]]; then
        _api_error 400 "Missing required fields: name, trigger"
        return
    fi

    local rule_id="rule_$(date +%s)_$RANDOM"
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local rule="{\"id\": \"$rule_id\", \"name\": \"$(_api_json_escape "$name")\", \"enabled\": $enabled, \"trigger\": \"$(_api_json_escape "$trigger")\", \"target\": \"$(_api_json_escape "$target")\", \"priority\": \"$(_api_json_escape "$priority")\", \"tags\": $tags, \"created_at\": \"$ts\"}"

    jq --argjson rule "$rule" '.rules += [$rule]' "$NOTIFICATIONS_FILE" > "${NOTIFICATIONS_FILE}.tmp" 2>/dev/null && mv "${NOTIFICATIONS_FILE}.tmp" "$NOTIFICATIONS_FILE"

    _api_success "$rule"
}

handle_notification_rules_delete() {
    local rule_id="$1"
    _init_notifications_file

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required"
        return
    fi

    jq --arg id "$rule_id" '.rules = [.rules[] | select(.id != $id)]' "$NOTIFICATIONS_FILE" > "${NOTIFICATIONS_FILE}.tmp" 2>/dev/null && mv "${NOTIFICATIONS_FILE}.tmp" "$NOTIFICATIONS_FILE"

    _api_success "{\"success\": true, \"deleted\": \"$(_api_json_escape "$rule_id")\"}"
}

handle_notification_history() {
    _init_notifications_file
    if command -v jq >/dev/null 2>&1; then
        local history
        history=$(jq -c '.history // [] | .[-100:]' "$NOTIFICATIONS_FILE" 2>/dev/null || echo "[]")
        _api_success "{\"history\": $history}"
    else
        _api_success "{\"history\": []}"
    fi
}

handle_notification_test() {
    local body="$1"
    local ntfy_url="${NTFY_URL:-}"

    if [[ -z "$ntfy_url" ]]; then
        _api_error 400 "NTFY is not configured. Set NTFY_URL in .env"
        return
    fi

    local message priority title tags
    message=$(printf '%s' "$body" | jq -r '.message // "Test notification from DCS"' 2>/dev/null)
    priority=$(printf '%s' "$body" | jq -r '.priority // "default"' 2>/dev/null)
    title=$(printf '%s' "$body" | jq -r '.title // "DCS Test Notification"' 2>/dev/null)
    tags=$(printf '%s' "$body" | jq -r '.tags // "test,docker"' 2>/dev/null)

    local result
    result=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Title: $title" \
        -H "Priority: $priority" \
        -H "Tags: $tags" \
        -d "$message" \
        "$ntfy_url" 2>&1)

    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    # Log to history
    _init_notifications_file
    if command -v jq >/dev/null 2>&1; then
        local entry="{\"timestamp\": \"$ts\", \"type\": \"test\", \"title\": \"$(_api_json_escape "$title")\", \"priority\": \"$priority\", \"status_code\": $result}"
        jq --argjson entry "$entry" '.history = (.history + [$entry]) | .history = .history[-100:]' "$NOTIFICATIONS_FILE" > "${NOTIFICATIONS_FILE}.tmp" 2>/dev/null && mv "${NOTIFICATIONS_FILE}.tmp" "$NOTIFICATIONS_FILE"
    fi

    if [[ "$result" == "200" ]]; then
        _api_success "{\"success\": true, \"message\": \"Test notification sent\", \"status_code\": $result, \"timestamp\": \"$ts\"}"
    else
        _api_error 502 "NTFY returned status $result"
    fi
}

# =============================================================================
# FEATURE: SYSTEM SNAPSHOTS
# =============================================================================

SNAPSHOTS_DIR="$BASE_DIR/.snapshots"

handle_snapshots_list() {
    [[ ! -d "$SNAPSHOTS_DIR" ]] && mkdir -p "$SNAPSHOTS_DIR"

    local -a entries=()
    for f in "$SNAPSHOTS_DIR"/*.tar.gz; do
        [[ ! -f "$f" ]] && continue
        local fname
        fname=$(basename "$f")
        local fsize
        fsize=$(du -h "$f" 2>/dev/null | awk '{print $1}')
        local fdate
        fdate=$(stat -c '%Y' "$f" 2>/dev/null || echo 0)
        local fiso
        fiso=$(date -u -d "@$fdate" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")

        # Read label from manifest if exists
        local label=""
        local manifest
        manifest=$(tar -xzf "$f" manifest.json -O 2>/dev/null)
        if [[ -n "$manifest" ]] && command -v jq >/dev/null 2>&1; then
            label=$(printf '%s' "$manifest" | jq -r '.label // ""' 2>/dev/null)
        fi

        entries+=("{\"filename\": \"$(_api_json_escape "$fname")\", \"label\": \"$(_api_json_escape "$label")\", \"size\": \"$fsize\", \"timestamp\": \"$fiso\", \"epoch\": $fdate}")
    done

    local json
    json=$(printf '%s,' "${entries[@]}")
    json="[${json%,}]"
    [[ ${#entries[@]} -eq 0 ]] && json="[]"

    _api_success "{\"snapshots\": $json, \"total\": ${#entries[@]}}"
}

handle_snapshot_create() {
    local body="$1"
    [[ ! -d "$SNAPSHOTS_DIR" ]] && mkdir -p "$SNAPSHOTS_DIR"

    local label=""
    if command -v jq >/dev/null 2>&1; then
        label=$(printf '%s' "$body" | jq -r '.label // ""' 2>/dev/null)
    fi

    local ts
    ts=$(date '+%Y%m%d-%H%M%S')
    local filename="dcs-snapshot-${ts}.tar.gz"
    local tmpdir
    tmpdir=$(mktemp -d /tmp/dcs-snapshot-XXXXXX)

    # Create manifest
    local hostname_val
    hostname_val=$(hostname 2>/dev/null || echo "unknown")
    cat > "$tmpdir/manifest.json" <<MANIFESTEOF
{"version": "1.0", "label": "$(_api_json_escape "$label")", "created_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')", "hostname": "$hostname_val", "dcs_version": "${SCRIPT_VERSION:-2.0.0}"}
MANIFESTEOF

    # Copy config files
    mkdir -p "$tmpdir/config" "$tmpdir/stacks" "$tmpdir/api-auth"
    [[ -d "$BASE_DIR/.config" ]] && cp -r "$BASE_DIR/.config/"* "$tmpdir/config/" 2>/dev/null
    [[ -f "$BASE_DIR/.env" ]] && cp "$BASE_DIR/.env" "$tmpdir/root.env" 2>/dev/null

    # Copy stack compose + env files
    for stack_dir in "$COMPOSE_DIR"/*/; do
        [[ ! -d "$stack_dir" ]] && continue
        local sname
        sname=$(basename "$stack_dir")
        mkdir -p "$tmpdir/stacks/$sname"
        [[ -f "$stack_dir/docker-compose.yml" ]] && cp "$stack_dir/docker-compose.yml" "$tmpdir/stacks/$sname/" 2>/dev/null
        [[ -f "$stack_dir/.env" ]] && cp "$stack_dir/.env" "$tmpdir/stacks/$sname/" 2>/dev/null
    done

    # Copy api-auth (excluding tokens)
    for f in "$BASE_DIR/.api-auth/"*.json; do
        [[ ! -f "$f" ]] && continue
        local fname
        fname=$(basename "$f")
        [[ "$fname" == "tokens.json" ]] && continue
        cp "$f" "$tmpdir/api-auth/" 2>/dev/null
    done

    # Copy templates if they exist
    [[ -d "$BASE_DIR/.templates" ]] && cp -r "$BASE_DIR/.templates" "$tmpdir/templates" 2>/dev/null

    # Create archive
    tar -czf "$SNAPSHOTS_DIR/$filename" -C "$tmpdir" . 2>/dev/null
    rm -rf "$tmpdir"

    local fsize
    fsize=$(du -h "$SNAPSHOTS_DIR/$filename" 2>/dev/null | awk '{print $1}')

    _api_success "{\"success\": true, \"filename\": \"$(_api_json_escape "$filename")\", \"label\": \"$(_api_json_escape "$label")\", \"size\": \"$fsize\", \"timestamp\": \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\"}"
}

handle_snapshot_download() {
    local snap_id="$1"
    local filepath="$SNAPSHOTS_DIR/$snap_id"

    if [[ ! -f "$filepath" ]]; then
        _api_error 404 "Snapshot not found: $snap_id"
        return
    fi

    local filesize
    filesize=$(stat -c '%s' "$filepath" 2>/dev/null || echo 0)

    # Send binary response
    printf 'HTTP/1.1 200 OK\r\n'
    printf 'Content-Type: application/gzip\r\n'
    printf 'Content-Disposition: attachment; filename="%s"\r\n' "$snap_id"
    printf 'Content-Length: %s\r\n' "$filesize"
    printf 'Connection: close\r\n'
    printf '\r\n'
    cat "$filepath"
}

handle_snapshot_restore() {
    local snap_id="$1"
    local body="$2"
    local filepath="$SNAPSHOTS_DIR/$snap_id"

    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    if [[ ! -f "$filepath" ]]; then
        _api_error 404 "Snapshot not found: $snap_id"
        return
    fi

    # Require confirmation
    local confirm=""
    if command -v jq >/dev/null 2>&1; then
        confirm=$(printf '%s' "$body" | jq -r '.confirm // ""' 2>/dev/null)
    fi
    if [[ "$confirm" != "RESTORE" ]]; then
        _api_error 400 "Must include {\"confirm\": \"RESTORE\"} to proceed"
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d /tmp/dcs-restore-XXXXXX)
    tar -xzf "$filepath" -C "$tmpdir" 2>/dev/null || {
        rm -rf "$tmpdir"
        _api_error 500 "Failed to extract snapshot"
        return
    }

    # Validate manifest
    if [[ ! -f "$tmpdir/manifest.json" ]]; then
        rm -rf "$tmpdir"
        _api_error 400 "Invalid snapshot: no manifest.json"
        return
    fi

    # Restore config
    [[ -d "$tmpdir/config" ]] && cp -r "$tmpdir/config/"* "$BASE_DIR/.config/" 2>/dev/null
    [[ -f "$tmpdir/root.env" ]] && cp "$tmpdir/root.env" "$BASE_DIR/.env" 2>/dev/null

    # Restore stacks
    if [[ -d "$tmpdir/stacks" ]]; then
        for stack_dir in "$tmpdir/stacks"/*/; do
            [[ ! -d "$stack_dir" ]] && continue
            local sname
            sname=$(basename "$stack_dir")
            mkdir -p "$COMPOSE_DIR/$sname"
            [[ -f "$stack_dir/docker-compose.yml" ]] && cp "$stack_dir/docker-compose.yml" "$COMPOSE_DIR/$sname/" 2>/dev/null
            [[ -f "$stack_dir/.env" ]] && cp "$stack_dir/.env" "$COMPOSE_DIR/$sname/" 2>/dev/null
        done
    fi

    # Restore api-auth configs (not tokens)
    if [[ -d "$tmpdir/api-auth" ]]; then
        for f in "$tmpdir/api-auth/"*.json; do
            [[ ! -f "$f" ]] && continue
            local fname
            fname=$(basename "$f")
            [[ "$fname" == "tokens.json" ]] && continue
            cp "$f" "$BASE_DIR/.api-auth/" 2>/dev/null
        done
    fi

    # Restore templates
    [[ -d "$tmpdir/templates" ]] && cp -r "$tmpdir/templates/"* "$BASE_DIR/.templates/" 2>/dev/null

    rm -rf "$tmpdir"

    _api_success "{\"success\": true, \"message\": \"Snapshot restored successfully\", \"filename\": \"$(_api_json_escape "$snap_id")\"}"
}

handle_snapshot_delete() {
    local snap_id="$1"
    local filepath="$SNAPSHOTS_DIR/$snap_id"

    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    if [[ ! -f "$filepath" ]]; then
        _api_error 404 "Snapshot not found: $snap_id"
        return
    fi

    rm -f "$filepath"
    _api_success "{\"success\": true, \"deleted\": \"$(_api_json_escape "$snap_id")\"}"
}

# =============================================================================
# FEATURE: COMPOSE VERSION HISTORY
# =============================================================================

COMPOSE_HISTORY_DIR="$BASE_DIR/.compose-history"

handle_compose_history() {
    local stack="$1"

    if [[ ! -d "$COMPOSE_DIR/$stack" ]]; then
        _api_error 404 "Stack not found: $stack"
        return
    fi

    local history_dir="$COMPOSE_HISTORY_DIR/$stack"
    local history_file="$history_dir/history.json"

    if [[ ! -f "$history_file" ]]; then
        _api_success "{\"stack\": \"$(_api_json_escape "$stack")\", \"versions\": [], \"count\": 0}"
        return
    fi

    if command -v jq >/dev/null 2>&1; then
        local versions
        versions=$(jq -c '.' "$history_file" 2>/dev/null || echo "[]")
        local count
        count=$(jq 'length' "$history_file" 2>/dev/null || echo 0)
        _api_success "{\"stack\": \"$(_api_json_escape "$stack")\", \"versions\": $versions, \"count\": $count}"
    else
        _api_success "{\"stack\": \"$(_api_json_escape "$stack")\", \"versions\": [], \"count\": 0}"
    fi
}

handle_compose_rollback() {
    local stack="$1"
    local body="$2"

    if [[ ! -d "$COMPOSE_DIR/$stack" ]]; then
        _api_error 404 "Stack not found: $stack"
        return
    fi

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required"
        return
    fi

    local version_id
    version_id=$(printf '%s' "$body" | jq -r '.version_id // empty' 2>/dev/null)
    if [[ -z "$version_id" ]]; then
        _api_error 400 "Missing required field: version_id"
        return
    fi

    local history_dir="$COMPOSE_HISTORY_DIR/$stack"
    local version_file="$history_dir/${version_id}.yml"

    if [[ ! -f "$version_file" ]]; then
        _api_error 404 "Version not found: $version_id"
        return
    fi

    local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"

    # Save current as a new version before rollback
    _save_compose_version "$stack"

    # Restore the selected version
    cp "$version_file" "$compose_file" 2>/dev/null || {
        _api_error 500 "Failed to restore compose file"
        return
    }

    _api_success "{\"success\": true, \"stack\": \"$(_api_json_escape "$stack")\", \"restored_version\": \"$(_api_json_escape "$version_id")\", \"message\": \"Compose file rolled back successfully\"}"
}

# Helper: save a compose version snapshot
_save_compose_version() {
    local stack="$1"
    local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"

    [[ ! -f "$compose_file" ]] && return

    local history_dir="$COMPOSE_HISTORY_DIR/$stack"
    mkdir -p "$history_dir"

    local ts
    ts=$(date '+%Y%m%d-%H%M%S')
    local version_id="v_${ts}"

    # Copy compose file
    cp "$compose_file" "$history_dir/${version_id}.yml" 2>/dev/null

    # Update history.json
    local history_file="$history_dir/history.json"
    [[ ! -f "$history_file" ]] && echo "[]" > "$history_file"

    local iso_ts
    iso_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local size
    size=$(stat -c '%s' "$compose_file" 2>/dev/null || echo 0)

    if command -v jq >/dev/null 2>&1; then
        local entry="{\"version_id\": \"$version_id\", \"timestamp\": \"$iso_ts\", \"size\": $size}"
        jq --argjson entry "$entry" '. + [$entry] | .[-50:]' "$history_file" > "${history_file}.tmp" 2>/dev/null && mv "${history_file}.tmp" "$history_file"
    fi
}

# =============================================================================
# FEATURE: STACK TEMPLATES
# =============================================================================

TEMPLATES_DIR="$BASE_DIR/.templates"
DEPLOY_HISTORY_FILE="$BASE_DIR/.api-auth/deploy-history.json"

_init_deploy_history() {
    [[ ! -f "$DEPLOY_HISTORY_FILE" ]] && echo '[]' > "$DEPLOY_HISTORY_FILE"
}

# Record a deploy/undeploy event in the audit log
# Usage: _record_deploy_event <action> <template_name> <target_stack> <services_json> [backup_file]
_record_deploy_event() {
    local action="$1" template_name="$2" target_stack="$3" services_json="$4" backup_file="${5:-}"
    _init_deploy_history

    if ! command -v jq >/dev/null 2>&1; then
        return
    fi

    local id timestamp epoch
    id="evt-$(date +%s)-$$-$RANDOM"
    timestamp=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')
    epoch=$(date +%s)

    local entry
    entry=$(jq -nc \
        --arg id "$id" \
        --arg action "$action" \
        --arg template "$template_name" \
        --arg target "$target_stack" \
        --argjson services "$services_json" \
        --arg backup "$backup_file" \
        --arg ts "$timestamp" \
        --argjson epoch "$epoch" \
        '{id:$id, action:$action, template:$template, target_stack:$target, services:$services, backup_file:$backup, timestamp:$ts, epoch:$epoch}')

    # Prepend to array and cap at 200 entries
    local updated
    updated=$(jq --argjson new "$entry" '[$new] + .[:199]' "$DEPLOY_HISTORY_FILE" 2>/dev/null)
    if [[ -n "$updated" ]]; then
        printf '%s\n' "$updated" > "$DEPLOY_HISTORY_FILE"
    fi
}

handle_deploy_history() {
    _init_deploy_history
    if command -v jq >/dev/null 2>&1; then
        local history
        history=$(jq -c '.' "$DEPLOY_HISTORY_FILE" 2>/dev/null || echo "[]")
        local total
        total=$(jq 'length' "$DEPLOY_HISTORY_FILE" 2>/dev/null || echo 0)
        _api_success "{\"history\": $history, \"total\": $total}"
    else
        _api_success "{\"history\": [], \"total\": 0}"
    fi
}

handle_templates_list() {
    [[ ! -d "$TEMPLATES_DIR" ]] && mkdir -p "$TEMPLATES_DIR"

    local -a entries=()
    for tdir in "$TEMPLATES_DIR"/*/; do
        [[ ! -d "$tdir" ]] && continue
        local tname
        tname=$(basename "$tdir")
        local meta_file="$tdir/template.json"

        if [[ -f "$meta_file" ]] && command -v jq >/dev/null 2>&1; then
            local meta
            meta=$(jq -c '.' "$meta_file" 2>/dev/null)
            [[ -n "$meta" ]] && entries+=("$meta")
        else
            entries+=("{\"name\": \"$(_api_json_escape "$tname")\", \"description\": \"\", \"category\": \"other\", \"tags\": []}")
        fi
    done

    local json
    json=$(printf '%s,' "${entries[@]}")
    json="[${json%,}]"
    [[ ${#entries[@]} -eq 0 ]] && json="[]"

    _api_success "{\"templates\": $json, \"total\": ${#entries[@]}}"
}

handle_template_detail() {
    local name="$1"
    local tdir="$TEMPLATES_DIR/$name"

    if [[ ! -d "$tdir" ]]; then
        _api_error 404 "Template not found: $name"
        return
    fi

    local meta="{}"
    if [[ -f "$tdir/template.json" ]] && command -v jq >/dev/null 2>&1; then
        meta=$(jq -c '.' "$tdir/template.json" 2>/dev/null || echo "{}")
    fi

    local compose_content=""
    if [[ -f "$tdir/docker-compose.yml" ]]; then
        compose_content=$(_api_json_escape "$(cat "$tdir/docker-compose.yml")")
    fi

    local env_content=""
    if [[ -f "$tdir/.env" ]]; then
        env_content=$(_api_json_escape "$(cat "$tdir/.env")")
    fi

    _api_success "{\"template\": $meta, \"compose\": \"$compose_content\", \"env\": \"$env_content\"}"
}

handle_template_deploy() {
    local name="$1"
    local body="$2"

    # B4: Admin-only access
    if ! _api_check_admin; then
        _api_error 403 "Admin access required"
        return
    fi

    local tdir="$TEMPLATES_DIR/$name"

    if [[ ! -d "$tdir" || ! -f "$tdir/docker-compose.yml" ]]; then
        _api_error 404 "Template not found or missing compose file: $name"
        return
    fi

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required"
        return
    fi

    # Load template metadata (needed for config_path, etc.)
    local meta="{}"
    if [[ -f "$tdir/template.json" ]]; then
        meta=$(jq -c '.' "$tdir/template.json" 2>/dev/null || echo "{}")
    fi

    # Accept target_stack from request body (required)
    local target_stack
    target_stack=$(printf '%s' "$body" | jq -r '.target_stack // empty' 2>/dev/null)
    if [[ -z "$target_stack" ]]; then
        _api_error 400 "Missing required field: target_stack"
        return
    fi

    # Sanitize target stack name
    target_stack=$(echo "$target_stack" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g')

    # B4: Path traversal guard
    if [[ "$target_stack" == *".."* || "$target_stack" == *"/"* || -z "$target_stack" ]]; then
        _api_error 400 "Invalid target stack name"
        return
    fi

    local target_dir="$COMPOSE_DIR/$target_stack"
    if [[ ! -d "$target_dir" || ! -f "$target_dir/docker-compose.yml" ]]; then
        local available_stacks=""
        if [[ -n "${DOCKER_STACKS:-}" ]]; then
            available_stacks=" Available stacks: ${DOCKER_STACKS}"
        fi
        _api_error 404 "Target stack not found or missing compose file: $target_stack.${available_stacks}"
        return
    fi

    # Read template compose and substitute variables
    local template_compose
    template_compose=$(cat "$tdir/docker-compose.yml")

    local vars
    vars=$(printf '%s' "$body" | jq -r '.variables // {} | to_entries[] | "\(.key)=\(.value)"' 2>/dev/null)
    while IFS='=' read -r key val; do
        [[ -z "$key" ]] && continue
        # B1: Validate key is a legal env var name
        if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            _api_error 400 "Invalid variable name: $key"
            return
        fi
        # B1: Reject values containing newlines (YAML injection vector)
        if [[ "$val" == *$'\n'* || "$val" == *$'\r'* ]]; then
            _api_error 400 "Variable value for $key contains invalid characters"
            return
        fi
        # Replace ${VAR:-default} patterns FIRST (greedy match for default value)
        local safe_val
        safe_val=$(_sed_escape_val "$val")
        template_compose=$(printf '%s' "$template_compose" | sed "s/\${${key}:-[^}]*}/${safe_val}/g")
        # Then replace simple ${VAR} and $VAR patterns
        template_compose="${template_compose//\$\{$key\}/$val}"
        template_compose="${template_compose//\$$key/$val}"
    done <<< "$vars"

    # Resolve remaining ${VAR:-default} patterns to their default values
    template_compose=$(printf '%s' "$template_compose" | sed 's/${[A-Za-z_][A-Za-z0-9_]*:-\([^}]*\)}/\1/g')

    # Optional: exclude services the user toggled off (e.g. docker-socket-proxy)
    local exclude_services
    exclude_services=$(printf '%s' "$body" | jq -r '.exclude_services // [] | .[]' 2>/dev/null)
    if [[ -n "$exclude_services" ]]; then
        while IFS= read -r exc_svc; do
            [[ -z "$exc_svc" ]] && continue
            # Remove the service block from template compose
            template_compose=$(printf '%s\n' "$template_compose" | awk -v svc="  ${exc_svc}:" '
                BEGIN { skip=0 }
                $0 == svc || index($0, svc) == 1 { skip=1; next }
                skip && /^  [a-zA-Z_-]/ { skip=0 }
                skip && /^[a-zA-Z]/ { skip=0 }
                !skip { print }
            ')
            # Remove depends_on references to excluded service; drop empty depends_on blocks
            template_compose=$(printf '%s\n' "$template_compose" | awk -v svc="$exc_svc" '
                BEGIN { buf_n=0; in_dep=0; dep_indent=0; skip_entry=0; has_other=0 }
                /[[:space:]]+depends_on:[[:space:]]*$/ {
                    in_dep=1; match($0,/^[[:space:]]+/); dep_indent=RLENGTH
                    buf_n++; buf[buf_n]=$0; next
                }
                in_dep {
                    match($0,/^[[:space:]]*/)
                    ci=RLENGTH
                    if ($0 !~ /^[[:space:]]*$/ && ci <= dep_indent) {
                        if (has_other) { for (i=1;i<=buf_n;i++) print buf[i] }
                        buf_n=0;in_dep=0;has_other=0;skip_entry=0; print; next
                    }
                    if (ci == dep_indent+2) {
                        if (index($0,svc":") > 0) { skip_entry=1; next }
                        else { skip_entry=0; has_other=1; buf_n++; buf[buf_n]=$0; next }
                    }
                    if (skip_entry) next
                    has_other=1; buf_n++; buf[buf_n]=$0; next
                }
                { print }
                END { if (in_dep && has_other) { for (i=1;i<=buf_n;i++) print buf[i] } }
            ')
        done <<< "$exclude_services"
    fi

    # Extract service names from template compose (top-level keys under services:)
    local template_services
    template_services=$(printf '%s' "$template_compose" | sed -n '/^services:/,/^[^ ]/{ /^  [a-zA-Z_-][a-zA-Z0-9_-]*:/{ s/^  \([a-zA-Z_-][a-zA-Z0-9_-]*\):.*/\1/; p; } }')
    if [[ -z "$template_services" ]]; then
        _api_error 400 "No services found in template compose file"
        return
    fi

    # Check for service name conflicts against existing compose
    local existing_compose
    existing_compose=$(cat "$target_dir/docker-compose.yml")
    local conflicts=""
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        if printf '%s' "$existing_compose" | grep -q "^  ${svc}:"; then
            conflicts="${conflicts}${conflicts:+, }${svc}"
        fi
    done <<< "$template_services"

    # Allow replacing conflicting services if explicitly requested
    local replace_services
    replace_services=$(printf '%s' "$body" | jq -r '.replace_services // false' 2>/dev/null)

    if [[ -n "$conflicts" ]]; then
        if [[ "$replace_services" != "true" ]]; then
            _api_error 409 "Service name conflict in target stack: $conflicts"
            return
        fi

        # Remove conflicting services from the existing compose before merging.
        # We do NOT stop containers here — docker-compose up -d will handle the
        # lifecycle (stop old → create new → start) atomically without blocking
        # the API response or dropping the TCP connection.
        local svc_to_remove
        while IFS= read -r svc_to_remove; do
            [[ -z "$svc_to_remove" ]] && continue
            if printf '%s' "$existing_compose" | grep -q "^  ${svc_to_remove}:"; then
                existing_compose=$(printf '%s\n' "$existing_compose" | awk -v svc="  ${svc_to_remove}:" '
                    BEGIN { skip=0 }
                    $0 == svc || index($0, svc) == 1 { skip=1; next }
                    skip && /^  [a-zA-Z_-]/ { skip=0 }
                    skip && /^[a-zA-Z]/ { skip=0 }
                    !skip { print }
                ')
            fi
        done <<< "$template_services"
        # Write the cleaned compose back so the merge awk reads the updated version
        printf '%s\n' "$existing_compose" > "$target_dir/docker-compose.yml"
    fi

    # -----------------------------------------------------------------------
    # Port conflict detection — template ports vs OTHER stacks & system
    # When replace_services=true, we skip the running-container check because
    # those ports belong to services being replaced — docker-compose up -d
    # swaps them atomically (stop old → start new).
    # -----------------------------------------------------------------------
    local tpl_ports target_ports
    tpl_ports=$(printf '%s\n' "$template_compose" | awk '
        /[[:space:]]+ports:[[:space:]]*$/ { p=1; next }
        p && /^[[:space:]]+-/ {
            l=$0; gsub(/^[[:space:]]*-[[:space:]]*/, "", l); gsub(/"/, "", l)
            n=split(l, a, ":"); if (n >= 2) { gsub(/[[:space:]]/, "", a[1])
            if (a[1] ~ /^[0-9]+$/) print a[1] }; next
        }
        p && !/^[[:space:]]*$/ && !/^[[:space:]]+-/ { p=0 }
    ')
    target_ports=$(sed 's/${[A-Za-z_][A-Za-z0-9_]*:-\([^}]*\)}/\1/g' "$target_dir/docker-compose.yml" | awk '
        /[[:space:]]+ports:[[:space:]]*$/ { p=1; next }
        p && /^[[:space:]]+-/ {
            l=$0; gsub(/^[[:space:]]*-[[:space:]]*/, "", l); gsub(/"/, "", l)
            n=split(l, a, ":"); if (n >= 2) { gsub(/[[:space:]]/, "", a[1])
            if (a[1] ~ /^[0-9]+$/) print a[1] }; next
        }
        p && !/^[[:space:]]*$/ && !/^[[:space:]]+-/ { p=0 }
    ')

    if [[ -n "$tpl_ports" ]]; then
        # Check against target stack compose file (already cleaned of replaced services)
        if [[ -n "$target_ports" ]]; then
            local port_conflicts=""
            while IFS= read -r port; do
                [[ -z "$port" ]] && continue
                if printf '%s\n' "$target_ports" | grep -qxF "$port"; then
                    port_conflicts="${port_conflicts}${port_conflicts:+, }${port}"
                fi
            done <<< "$tpl_ports"
            if [[ -n "$port_conflicts" ]]; then
                _api_error 409 "Host port conflict with existing services in ${target_stack}: ${port_conflicts}"
                return
            fi
        fi

        # Check against running containers — but SKIP when replacing services
        # in the same stack (their ports will be freed by docker-compose up -d)
        if [[ "$replace_services" != "true" ]] && command -v docker >/dev/null 2>&1; then
            local running_ports
            running_ports=$(docker ps --format '{{.Ports}}' 2>/dev/null | grep -oE '(0\.0\.0\.0:|:::)[0-9]+' | grep -oE '[0-9]+$' | sort -u)
            if [[ -n "$running_ports" ]]; then
                local system_conflicts=""
                while IFS= read -r port; do
                    [[ -z "$port" ]] && continue
                    if printf '%s\n' "$running_ports" | grep -qxF "$port"; then
                        system_conflicts="${system_conflicts}${system_conflicts:+, }${port}"
                    fi
                done <<< "$tpl_ports"
                if [[ -n "$system_conflicts" ]]; then
                    _api_error 409 "Host port(s) already in use by running containers: ${system_conflicts}"
                    return
                fi
            fi
        fi
    fi

    # Back up existing compose file
    local timestamp
    timestamp=$(date +%Y%m%d%H%M%S)
    cp "$target_dir/docker-compose.yml" "$target_dir/docker-compose.yml.bak.${timestamp}"

    # B3: Rotate backups — keep only the 5 most recent
    local -a old_backups=()
    while IFS= read -r f; do
        old_backups+=("$f")
    done < <(ls -1t "$target_dir"/docker-compose.yml.bak.* 2>/dev/null | tail -n +6)
    for f in "${old_backups[@]}"; do
        rm -f "$f"
    done

    # -----------------------------------------------------------------------
    # Section-aware merge: insert services, volumes, networks into correct
    # positions in the target compose file (never blindly append to EOF)
    # -----------------------------------------------------------------------

    # Extract each top-level section's content from the template
    local tpl_svc_block tpl_vol_block tpl_net_block
    tpl_svc_block=$(printf '%s\n' "$template_compose" | awk '
        /^services:/ { f=1; next } f && /^[^ \t]/ { exit } f { print }')
    tpl_vol_block=$(printf '%s\n' "$template_compose" | awk '
        /^volumes:/ { f=1; next } f && /^[^ \t]/ { exit } f { print }')
    tpl_net_block=$(printf '%s\n' "$template_compose" | awk '
        /^networks:/ { f=1; next } f && /^[^ \t]/ { exit } f { print }')

    # Deduplicate: remove template network/volume entries that already exist in target
    local target_content
    target_content=$(cat "$target_dir/docker-compose.yml")
    if [[ -n "$tpl_net_block" ]]; then
        local existing_nets
        existing_nets=$(printf '%s\n' "$target_content" | awk '
            /^networks:/ { f=1; next } f && /^[^ \t#]/ { exit }
            f && /^  [a-zA-Z0-9_-]+:/ { sub(/:.*/, ""); gsub(/^  /, ""); print }')
        if [[ -n "$existing_nets" ]]; then
            while IFS= read -r enet; do
                [[ -z "$enet" ]] && continue
                tpl_net_block=$(printf '%s\n' "$tpl_net_block" | awk -v key="  ${enet}:" '
                    BEGIN { skip=0 }
                    $0 == key || index($0, key) == 1 { skip=1; next }
                    skip && /^  [a-zA-Z0-9_-]/ { skip=0 }
                    skip && /^[^ ]/ { skip=0 }
                    skip { next }
                    { print }')
            done <<< "$existing_nets"
            # Trim to empty if only whitespace remains
            if [[ -z "$(printf '%s' "$tpl_net_block" | tr -d '[:space:]')" ]]; then
                tpl_net_block=""
            fi
        fi
    fi
    if [[ -n "$tpl_vol_block" ]]; then
        local existing_vols
        existing_vols=$(printf '%s\n' "$target_content" | awk '
            /^volumes:/ { f=1; next } f && /^[^ \t#]/ { exit }
            f && /^  [a-zA-Z0-9_-]+:/ { sub(/:.*/, ""); gsub(/^  /, ""); print }')
        if [[ -n "$existing_vols" ]]; then
            while IFS= read -r evol; do
                [[ -z "$evol" ]] && continue
                tpl_vol_block=$(printf '%s\n' "$tpl_vol_block" | awk -v key="  ${evol}:" '
                    BEGIN { skip=0 }
                    $0 == key || index($0, key) == 1 { skip=1; next }
                    skip && /^  [a-zA-Z0-9_-]/ { skip=0 }
                    skip && /^[^ ]/ { skip=0 }
                    skip { next }
                    { print }')
            done <<< "$existing_vols"
            if [[ -z "$(printf '%s' "$tpl_vol_block" | tr -d '[:space:]')" ]]; then
                tpl_vol_block=""
            fi
        fi
    fi

    # Merge template sections into target compose at the correct positions:
    #   - services content  → end of services: section (before next top-level key)
    #   - volumes content   → end of volumes: section (or create new section)
    #   - networks content  → end of networks: section (or create new section)
    local merged_compose
    merged_compose=$(
        _TPL_SVCS="$tpl_svc_block" \
        _TPL_VOLS="$tpl_vol_block" \
        _TPL_NETS="$tpl_net_block" \
        awk '
        BEGIN {
            svcs = ENVIRON["_TPL_SVCS"]; vols = ENVIRON["_TPL_VOLS"]; nets = ENVIRON["_TPL_NETS"]
            cur = ""; has_vol = 0; has_net = 0
            svcs_done = 0; vols_done = 0; nets_done = 0
        }
        # Handle inline empty sections: "services: {}" → "services:" + inject content
        /^services:[[:space:]]*\{\}/ {
            print "services:"
            if (svcs != "") { printf "%s\n", svcs; svcs_done = 1 }
            cur = "services"; next
        }
        /^volumes:[[:space:]]*\{\}/ {
            print "volumes:"
            if (vols != "") { printf "%s\n", vols; vols_done = 1 }
            cur = "volumes"; has_vol = 1; next
        }
        /^networks:[[:space:]]*\{\}/ {
            print "networks:"
            if (nets != "") { printf "%s\n", nets; nets_done = 1 }
            cur = "networks"; has_net = 1; next
        }
        /^[a-zA-Z]/ {
            # Entering a new top-level section — close the previous one first
            if (cur == "services" && !svcs_done && svcs != "") { printf "\n%s\n", svcs; svcs_done = 1 }
            if (cur == "volumes"  && !vols_done && vols != "") { printf "%s\n",  vols; vols_done = 1 }
            if (cur == "networks" && !nets_done && nets != "") { printf "%s\n",  nets; nets_done = 1 }
            if ($0 ~ /^services:/)  cur = "services"
            else if ($0 ~ /^volumes:/)  { cur = "volumes";  has_vol = 1 }
            else if ($0 ~ /^networks:/) { cur = "networks"; has_net = 1 }
            else cur = "other"
        }
        { print }
        END {
            # Close the last section (file ended while still in a section)
            if (cur == "services" && !svcs_done && svcs != "") printf "\n%s\n", svcs
            if (cur == "volumes"  && !vols_done && vols != "") printf "%s\n",  vols
            if (cur == "networks" && !nets_done && nets != "") printf "%s\n",  nets
            # Create new top-level sections if they did not exist in target
            if (!has_vol && vols != "") printf "\nvolumes:\n%s\n", vols
            if (!has_net && nets != "") printf "\nnetworks:\n%s\n", nets
        }
        ' "$target_dir/docker-compose.yml"
    )

    # Write merged result (atomic overwrite, not blind append)
    printf '%s\n' "$merged_compose" > "$target_dir/docker-compose.yml"

    # B2: Validate merged compose file — rollback on failure
    local env_args=()
    [[ -f "$target_dir/.env" ]] && env_args=(--env-file "$target_dir/.env")
    local validate_output
    validate_output=$($DOCKER_COMPOSE_CMD -f "$target_dir/docker-compose.yml" "${env_args[@]}" config 2>&1)
    if [[ $? -ne 0 ]]; then
        # Rollback: restore backup
        cp "$target_dir/docker-compose.yml.bak.${timestamp}" "$target_dir/docker-compose.yml"
        _api_error 422 "Merge produced invalid compose file. Rolled back. Validation error: $(echo "$validate_output" | head -3)"
        return
    fi

    # Append-only merge new variables into .env with template section header
    if [[ -n "$vars" ]]; then
        local env_file="$target_dir/.env"
        [[ ! -f "$env_file" ]] && touch "$env_file"

        # Collect only new variables (anchored ^KEY= match prevents partial hits)
        local -a new_env_entries=()
        local added_vars=""
        while IFS='=' read -r key val; do
            [[ -z "$key" ]] && continue
            if ! grep -q "^${key}=" "$env_file" 2>/dev/null; then
                new_env_entries+=("${key}=${val}")
                added_vars="${added_vars}${added_vars:+, }${key}"
            fi
        done <<< "$vars"

        # Write new variables under a descriptive template section header
        if [[ ${#new_env_entries[@]} -gt 0 ]]; then
            {
                printf '\n# =============================================================================\n'
                printf '# Template: %s (deployed %s)\n' "$name" "$(date '+%Y-%m-%d %H:%M:%S')"
                printf '# =============================================================================\n'
                for entry in "${new_env_entries[@]}"; do
                    printf '%s\n' "$entry"
                done
            } >> "$env_file"
        fi
    fi

    # Build JSON array of added service names
    local services_json="["
    local first=true
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        if $first; then
            services_json+="\"$(_api_json_escape "$svc")\""
            first=false
        else
            services_json+=",\"$(_api_json_escape "$svc")\""
        fi
    done <<< "$template_services"
    services_json+="]"

    # Deploy config files BEFORE auto-start so they exist when containers mount volumes
    if [[ -d "$tdir/config" ]]; then
        local config_target_name
        config_target_name=$(printf '%s' "$meta" | jq -r '.config_path // empty' 2>/dev/null)
        if [[ -n "$config_target_name" ]]; then
            # Config goes into the TARGET STACK's App-Data, not the repo root
            local app_data="${APP_DATA_DIR:-$target_dir/App-Data}"
            # If APP_DATA_DIR is a relative path (e.g. ./App-Data), resolve it relative to target stack
            if [[ "$app_data" == ./* ]]; then
                app_data="$target_dir/${app_data#./}"
            fi
            local config_target="$app_data/$config_target_name"
            mkdir -p "$config_target"
            # rsync is more reliable for recursive copies; fall back to cp -a
            if command -v rsync >/dev/null 2>&1; then
                rsync -a --ignore-existing "$tdir/config/" "$config_target/" 2>/dev/null || true
            else
                cp -a "$tdir/config/"* "$config_target/" 2>/dev/null || true
            fi

            # Create custom_routes subdirectories for ALL existing stacks
            if [[ -d "$config_target/custom_routes" ]]; then
                local all_stacks
                all_stacks=$(_api_get_stacks)
                local stack_name
                for stack_name in $all_stacks; do
                    mkdir -p "$config_target/custom_routes/$stack_name"
                done

                # Move the traefik route file into the target stack's custom_routes
                # (the template ships it under core-infrastructure/ by default)
                if [[ -n "$target_stack" ]]; then
                    mkdir -p "$config_target/custom_routes/$target_stack"
                    local route_src=""
                    # Check all subdirs for a traefik.yml route file
                    local route_file
                    for route_file in "$config_target"/custom_routes/*/traefik.yml; do
                        [[ -f "$route_file" ]] || continue
                        local route_dir
                        route_dir=$(basename "$(dirname "$route_file")")
                        if [[ "$route_dir" != "$target_stack" ]]; then
                            route_src="$route_file"
                            break
                        fi
                    done
                    if [[ -n "$route_src" ]]; then
                        mv "$route_src" "$config_target/custom_routes/$target_stack/traefik.yml"
                    fi
                fi
            fi

            # Apply variable substitution to all .yml/.yaml config files
            if [[ -n "$vars" ]]; then
                local cfg_file
                while IFS= read -r cfg_file; do
                    [[ -z "$cfg_file" ]] && continue
                    local cfg_content
                    cfg_content=$(cat "$cfg_file" 2>/dev/null) || continue
                    local orig_content="$cfg_content"
                    while IFS='=' read -r ckey cval; do
                        [[ -z "$ckey" ]] && continue
                        local safe_cval
                        safe_cval=$(_sed_escape_val "$cval")
                        cfg_content=$(printf '%s' "$cfg_content" | sed "s/\${${ckey}:-[^}]*}/${safe_cval}/g")
                        cfg_content="${cfg_content//\$\{$ckey\}/$cval}"
                    done <<< "$vars"
                    # Resolve remaining ${VAR:-default} patterns to their defaults
                    cfg_content=$(printf '%s' "$cfg_content" | sed 's/${[A-Za-z_][A-Za-z0-9_]*:-\([^}]*\)}/\1/g')
                    # Only write back if content actually changed
                    if [[ "$cfg_content" != "$orig_content" ]]; then
                        printf '%s\n' "$cfg_content" > "$cfg_file"
                    fi
                done < <(find "$config_target" -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null)
            fi

            # Ensure acme.json has secure permissions (required by Traefik)
            if [[ -f "$config_target/acme.json" ]]; then
                chmod 600 "$config_target/acme.json"
            fi
        fi
    fi

    # Auto-start if requested — run in background so API responds immediately.
    # docker-compose up -d handles the full lifecycle: stop old → pull → create → start.
    local auto_start
    auto_start=$(printf '%s' "$body" | jq -r '.auto_start // false' 2>/dev/null)
    local started=false
    if [[ "$auto_start" == "true" ]]; then
        local env_up=()
        [[ -f "$target_dir/.env" ]] && env_up=(--env-file "$target_dir/.env")
        ( $DOCKER_COMPOSE_CMD -f "$target_dir/docker-compose.yml" "${env_up[@]}" up -d --force-recreate --remove-orphans >/dev/null 2>&1 ) &
        disown
        started=true
    fi

    # Record deploy event in audit log
    _record_deploy_event "deploy" "$name" "$target_stack" "$services_json" "docker-compose.yml.bak.${timestamp}"

    _api_success "{\"success\": true, \"target_stack\": \"$(_api_json_escape "$target_stack")\", \"services_added\": $services_json, \"started\": $started, \"backup_file\": \"docker-compose.yml.bak.${timestamp}\", \"message\": \"Template services merged into $target_stack successfully\"}"
}

handle_template_dry_run() {
    local name="$1"
    local body="$2"

    local tdir="$TEMPLATES_DIR/$name"
    if [[ ! -d "$tdir" || ! -f "$tdir/docker-compose.yml" ]]; then
        _api_error 404 "Template not found or missing compose file: $name"
        return
    fi

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required"
        return
    fi

    local target_stack
    target_stack=$(printf '%s' "$body" | jq -r '.target_stack // empty' 2>/dev/null)
    if [[ -z "$target_stack" ]]; then
        _api_error 400 "Missing required field: target_stack"
        return
    fi

    target_stack=$(echo "$target_stack" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g')
    if [[ "$target_stack" == *".."* || "$target_stack" == *"/"* || -z "$target_stack" ]]; then
        _api_error 400 "Invalid target stack name"
        return
    fi

    local target_dir="$COMPOSE_DIR/$target_stack"
    if [[ ! -d "$target_dir" || ! -f "$target_dir/docker-compose.yml" ]]; then
        local available_stacks=""
        if [[ -n "${DOCKER_STACKS:-}" ]]; then
            available_stacks=" Available stacks: ${DOCKER_STACKS}"
        fi
        _api_error 404 "Target stack not found: $target_stack.${available_stacks}"
        return
    fi

    # Read and substitute variables
    local template_compose
    template_compose=$(cat "$tdir/docker-compose.yml")

    local vars
    vars=$(printf '%s' "$body" | jq -r '.variables // {} | to_entries[] | "\(.key)=\(.value)"' 2>/dev/null)
    while IFS='=' read -r key val; do
        [[ -z "$key" ]] && continue
        if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then continue; fi
        # Replace ${VAR:-default} patterns FIRST, then simple ${VAR} and $VAR
        local safe_val
        safe_val=$(_sed_escape_val "$val")
        template_compose=$(printf '%s' "$template_compose" | sed "s/\${${key}:-[^}]*}/${safe_val}/g")
        template_compose="${template_compose//\$\{$key\}/$val}"
        template_compose="${template_compose//\$$key/$val}"
    done <<< "$vars"

    # Resolve remaining ${VAR:-default} patterns to their default values
    # (handles variables the user didn't explicitly set)
    template_compose=$(printf '%s' "$template_compose" | sed 's/${[A-Za-z_][A-Za-z0-9_]*:-\([^}]*\)}/\1/g')

    # Optional: exclude services the user toggled off
    local exclude_services
    exclude_services=$(printf '%s' "$body" | jq -r '.exclude_services // [] | .[]' 2>/dev/null)
    if [[ -n "$exclude_services" ]]; then
        while IFS= read -r exc_svc; do
            [[ -z "$exc_svc" ]] && continue
            template_compose=$(printf '%s\n' "$template_compose" | awk -v svc="  ${exc_svc}:" '
                BEGIN { skip=0 }
                $0 == svc || index($0, svc) == 1 { skip=1; next }
                skip && /^  [a-zA-Z_-]/ { skip=0 }
                skip && /^[a-zA-Z]/ { skip=0 }
                !skip { print }
            ')
            template_compose=$(printf '%s\n' "$template_compose" | awk -v svc="$exc_svc" '
                BEGIN { buf_n=0; in_dep=0; dep_indent=0; skip_entry=0; has_other=0 }
                /[[:space:]]+depends_on:[[:space:]]*$/ {
                    in_dep=1; match($0,/^[[:space:]]+/); dep_indent=RLENGTH
                    buf_n++; buf[buf_n]=$0; next
                }
                in_dep {
                    match($0,/^[[:space:]]*/)
                    ci=RLENGTH
                    if ($0 !~ /^[[:space:]]*$/ && ci <= dep_indent) {
                        if (has_other) { for (i=1;i<=buf_n;i++) print buf[i] }
                        buf_n=0;in_dep=0;has_other=0;skip_entry=0; print; next
                    }
                    if (ci == dep_indent+2) {
                        if (index($0,svc":") > 0) { skip_entry=1; next }
                        else { skip_entry=0; has_other=1; buf_n++; buf[buf_n]=$0; next }
                    }
                    if (skip_entry) next
                    has_other=1; buf_n++; buf[buf_n]=$0; next
                }
                { print }
                END { if (in_dep && has_other) { for (i=1;i<=buf_n;i++) print buf[i] } }
            ')
        done <<< "$exclude_services"
    fi

    # Extract services
    local template_services
    template_services=$(printf '%s' "$template_compose" | sed -n '/^services:/,/^[^ ]/{ /^  [a-zA-Z_-][a-zA-Z0-9_-]*:/{ s/^  \([a-zA-Z_-][a-zA-Z0-9_-]*\):.*/\1/; p; } }')
    if [[ -z "$template_services" ]]; then
        _api_error 400 "No services found in template compose file"
        return
    fi

    # Service conflicts
    local existing_compose
    existing_compose=$(cat "$target_dir/docker-compose.yml")
    local service_conflicts=""
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        if printf '%s' "$existing_compose" | grep -q "^  ${svc}:"; then
            service_conflicts="${service_conflicts}${service_conflicts:+, }${svc}"
        fi
    done <<< "$template_services"

    # Port conflicts — thorough check across ALL stacks + running containers
    local tpl_ports port_conflicts=""
    tpl_ports=$(printf '%s\n' "$template_compose" | awk '
        /[[:space:]]+ports:[[:space:]]*$/ { p=1; next }
        p && /^[[:space:]]+-/ {
            l=$0; gsub(/^[[:space:]]*-[[:space:]]*/, "", l); gsub(/"/, "", l)
            n=split(l, a, ":"); if (n >= 2) { gsub(/[[:space:]]/, "", a[1])
            if (a[1] ~ /^[0-9]+$/) print a[1] }; next
        }
        p && !/^[[:space:]]*$/ && !/^[[:space:]]+-/ { p=0 }
    ')

    # Build a detailed port_conflicts JSON array for thorough reporting
    local -a port_conflict_entries=()

    if [[ -n "$tpl_ports" ]]; then
        # 1) Check against ALL stacks' compose files (not just target)
        for stack_dir in "$COMPOSE_DIR"/*/; do
            [[ ! -f "$stack_dir/docker-compose.yml" ]] && continue
            local stack_name
            stack_name=$(basename "$stack_dir")
            # Extract port:service_name pairs for detailed conflict reporting
            local stack_port_map
            stack_port_map=$(sed 's/${[A-Za-z_][A-Za-z0-9_]*:-\([^}]*\)}/\1/g' "$stack_dir/docker-compose.yml" 2>/dev/null | awk '
                /^  [a-zA-Z_-][a-zA-Z0-9_-]*:/ { gsub(/^  /,""); gsub(/:.*/,""); svc=$0 }
                /[[:space:]]+ports:[[:space:]]*$/ { p=1; next }
                p && /^[[:space:]]+-/ {
                    l=$0; gsub(/^[[:space:]]*-[[:space:]]*/, "", l); gsub(/"/, "", l)
                    n=split(l, a, ":"); if (n >= 2) { gsub(/[[:space:]]/, "", a[1])
                    if (a[1] ~ /^[0-9]+$/) print a[1] "\t" svc }; next
                }
                p && !/^[[:space:]]*$/ && !/^[[:space:]]+-/ { p=0 }
            ')
            if [[ -n "$stack_port_map" ]]; then
                while IFS= read -r port; do
                    [[ -z "$port" ]] && continue
                    local svc_owner
                    svc_owner=$(printf '%s\n' "$stack_port_map" | awk -F'\t' -v p="$port" '$1 == p { print $2; exit }')
                    if [[ -n "$svc_owner" ]]; then
                        local owner_label="${stack_name}/${svc_owner}"
                        port_conflict_entries+=("{\"port\": $port, \"owner\": \"$(_api_json_escape "$owner_label")\", \"type\": \"stack\", \"service\": \"$(_api_json_escape "$svc_owner")\"}")
                        port_conflicts="${port_conflicts}${port_conflicts:+, }${port} (${owner_label})"
                    fi
                done <<< "$tpl_ports"
            fi
        done

        # 2) Check against running Docker containers system-wide
        if command -v docker >/dev/null 2>&1; then
            local running_port_map
            running_port_map=$(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null)
            if [[ -n "$running_port_map" ]]; then
                while IFS= read -r port; do
                    [[ -z "$port" ]] && continue
                    # Check if port is already in conflicts from stack check
                    local already_found=false
                    for entry in "${port_conflict_entries[@]}"; do
                        if [[ "$entry" == *"\"port\": $port,"* ]]; then
                            already_found=true
                            break
                        fi
                    done
                    if ! $already_found; then
                        local container_owner
                        container_owner=$(printf '%s\n' "$running_port_map" | while IFS=$'\t' read -r cname cports; do
                            if printf '%s' "$cports" | grep -qE "(^|,| )(0\.0\.0\.0:|:::)${port}->"; then
                                printf '%s' "$cname"
                                break
                            fi
                        done)
                        if [[ -n "$container_owner" ]]; then
                            port_conflict_entries+=("{\"port\": $port, \"owner\": \"$(_api_json_escape "$container_owner")\", \"type\": \"container\"}")
                            port_conflicts="${port_conflicts}${port_conflicts:+, }${port} (container: ${container_owner})"
                        fi
                    fi
                done <<< "$tpl_ports"
            fi
        fi
    fi

    # Build port_conflicts_detail JSON array
    local port_conflicts_detail="[]"
    if [[ ${#port_conflict_entries[@]} -gt 0 ]]; then
        local joined
        joined=$(printf '%s,' "${port_conflict_entries[@]}")
        port_conflicts_detail="[${joined%,}]"
    fi

    # Env additions — check existing env vars across target stack
    local env_additions="[]"
    local env_existing="[]"
    if [[ -n "$vars" ]]; then
        local env_file="$target_dir/.env"
        local -a env_adds=()
        local -a env_exist=()
        while IFS='=' read -r key val; do
            [[ -z "$key" ]] && continue
            if [[ -f "$env_file" ]] && grep -q "^${key}=" "$env_file" 2>/dev/null; then
                local existing_val
                existing_val=$(grep "^${key}=" "$env_file" 2>/dev/null | head -1 | cut -d'=' -f2-)
                env_exist+=("{\"key\": \"$(_api_json_escape "$key")\", \"current_value\": \"$(_api_json_escape "$existing_val")\", \"new_value\": \"$(_api_json_escape "$val")\"}")
            else
                env_adds+=("{\"key\": \"$(_api_json_escape "$key")\", \"value\": \"$(_api_json_escape "$val")\"}")
            fi
        done <<< "$vars"
        if [[ ${#env_adds[@]} -gt 0 ]]; then
            local joined
            joined=$(printf '%s,' "${env_adds[@]}")
            env_additions="[${joined%,}]"
        fi
        if [[ ${#env_exist[@]} -gt 0 ]]; then
            local joined
            joined=$(printf '%s,' "${env_exist[@]}")
            env_existing="[${joined%,}]"
        fi
    fi

    # Build services JSON array
    local services_json="["
    local first=true
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        if $first; then
            services_json+="\"$(_api_json_escape "$svc")\""
            first=false
        else
            services_json+=",\"$(_api_json_escape "$svc")\""
        fi
    done <<< "$template_services"
    services_json+="]"

    # Extract services block for preview
    local tpl_svc_block
    tpl_svc_block=$(printf '%s\n' "$template_compose" | awk '
        /^services:/ { f=1; next } f && /^[^ \t]/ { exit } f { print }')
    local lines_added
    lines_added=$(printf '%s' "$tpl_svc_block" | wc -l)

    local has_svc_conflict="false"
    [[ -n "$service_conflicts" ]] && has_svc_conflict="true"
    local has_port_conflict="false"
    [[ -n "$port_conflicts" ]] && has_port_conflict="true"

    _api_success "{\"success\": true, \"template\": \"$(_api_json_escape "$name")\", \"target_stack\": \"$(_api_json_escape "$target_stack")\", \"services\": $services_json, \"service_conflicts\": \"$(_api_json_escape "$service_conflicts")\", \"has_service_conflicts\": $has_svc_conflict, \"port_conflicts\": \"$(_api_json_escape "$port_conflicts")\", \"has_port_conflicts\": $has_port_conflict, \"port_conflicts_detail\": $port_conflicts_detail, \"env_additions\": $env_additions, \"env_existing\": $env_existing, \"lines_added\": ${lines_added:-0}, \"compose_preview\": \"$(_api_json_escape "$tpl_svc_block")\"}"
}

handle_template_undeploy() {
    local name="$1"
    local body="$2"

    # Admin-only access
    if ! _api_check_admin; then
        _api_error 403 "Admin access required"
        return
    fi

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required"
        return
    fi

    local target_stack
    target_stack=$(printf '%s' "$body" | jq -r '.target_stack // empty' 2>/dev/null)
    if [[ -z "$target_stack" ]]; then
        _api_error 400 "Missing required field: target_stack"
        return
    fi

    # Sanitize
    target_stack=$(echo "$target_stack" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g')
    if [[ "$target_stack" == *".."* || "$target_stack" == *"/"* || -z "$target_stack" ]]; then
        _api_error 400 "Invalid target stack name"
        return
    fi

    local target_dir="$COMPOSE_DIR/$target_stack"
    if [[ ! -d "$target_dir" || ! -f "$target_dir/docker-compose.yml" ]]; then
        local available_stacks=""
        if [[ -n "${DOCKER_STACKS:-}" ]]; then
            available_stacks=" Available stacks: ${DOCKER_STACKS}"
        fi
        _api_error 404 "Target stack not found: $target_stack.${available_stacks}"
        return
    fi

    # Parse services to remove
    local -a services_to_remove=()
    local svc_json
    svc_json=$(printf '%s' "$body" | jq -c '.services // []' 2>/dev/null)
    if [[ "$svc_json" == "[]" || -z "$svc_json" ]]; then
        _api_error 400 "Missing required field: services (array of service names)"
        return
    fi
    while IFS= read -r svc; do
        [[ -n "$svc" ]] && services_to_remove+=("$svc")
    done < <(printf '%s' "$svc_json" | jq -r '.[]' 2>/dev/null)

    if [[ ${#services_to_remove[@]} -eq 0 ]]; then
        _api_error 400 "No valid services specified"
        return
    fi

    local remove_containers
    remove_containers=$(printf '%s' "$body" | jq -r '.remove_containers // false' 2>/dev/null)
    local remove_data
    remove_data=$(printf '%s' "$body" | jq -r '.remove_data // false' 2>/dev/null)

    # Load template metadata for config_path (needed for data cleanup)
    local tdir="$TEMPLATES_DIR/$name"
    local meta="{}"
    if [[ -f "$tdir/template.json" ]]; then
        meta=$(jq -c '.' "$tdir/template.json" 2>/dev/null || echo "{}")
    fi

    # Backup compose file
    local timestamp
    timestamp=$(date +%Y%m%d%H%M%S)
    cp "$target_dir/docker-compose.yml" "$target_dir/docker-compose.yml.bak.${timestamp}"

    # Rotate backups — keep only the 5 most recent
    local -a old_backups=()
    while IFS= read -r f; do
        old_backups+=("$f")
    done < <(ls -1t "$target_dir"/docker-compose.yml.bak.* 2>/dev/null | tail -n +6)
    for f in "${old_backups[@]}"; do
        rm -f "$f"
    done

    # Stop and remove containers BEFORE modifying compose (so service names still resolve)
    local -a containers_removed=()
    if [[ "$remove_containers" == "true" ]]; then
        local env_args_pre=()
        [[ -f "$target_dir/.env" ]] && env_args_pre=(--env-file "$target_dir/.env")
        # Kill (instant SIGKILL) + rm for the services being removed
        $DOCKER_COMPOSE_CMD -f "$target_dir/docker-compose.yml" "${env_args_pre[@]}" kill "${services_to_remove[@]}" >/dev/null 2>&1 || true
        $DOCKER_COMPOSE_CMD -f "$target_dir/docker-compose.yml" "${env_args_pre[@]}" rm -f "${services_to_remove[@]}" >/dev/null 2>&1 || true
        containers_removed=("${services_to_remove[@]}")
    fi

    # Remove each service block from the compose file using awk
    local compose_content
    compose_content=$(cat "$target_dir/docker-compose.yml")

    for svc in "${services_to_remove[@]}"; do
        # Remove the service block
        compose_content=$(printf '%s\n' "$compose_content" | awk -v svc="$svc" '
            BEGIN { skip=0 }
            /^  [a-zA-Z0-9_-]/ {
                if ($0 ~ "^  " svc ":") { skip=1; next }
                else { skip=0 }
            }
            skip && /^    / { next }
            skip && /^  [^ ]/ { skip=0 }
            skip && /^[^ ]/ { skip=0 }
            !skip { print }
        ')
        # Clean up depends_on references to the removed service in remaining services
        compose_content=$(printf '%s\n' "$compose_content" | awk -v svc="$svc" '
            BEGIN { buf_n=0; in_dep=0; dep_indent=0; skip_entry=0; has_other=0 }
            /[[:space:]]+depends_on:[[:space:]]*$/ {
                in_dep=1; match($0,/^[[:space:]]+/); dep_indent=RLENGTH
                buf_n++; buf[buf_n]=$0; next
            }
            in_dep {
                match($0,/^[[:space:]]*/)
                ci=RLENGTH
                if ($0 !~ /^[[:space:]]*$/ && ci <= dep_indent) {
                    if (has_other) { for (i=1;i<=buf_n;i++) print buf[i] }
                    buf_n=0;in_dep=0;has_other=0;skip_entry=0; print; next
                }
                if (ci == dep_indent+2) {
                    if (index($0,svc":") > 0) { skip_entry=1; next }
                    else { skip_entry=0; has_other=1; buf_n++; buf[buf_n]=$0; next }
                }
                if (skip_entry) next
                has_other=1; buf_n++; buf[buf_n]=$0; next
            }
            { print }
            END { if (in_dep && has_other) { for (i=1;i<=buf_n;i++) print buf[i] } }
        ')
    done

    # Check if any services remain after removal (count only keys under services:, not networks:/volumes:/etc.)
    local remaining_services
    remaining_services=$(printf '%s\n' "$compose_content" | awk '
        /^services:/ { in_svc=1; next }
        in_svc && /^[^ #]/ { in_svc=0 }
        in_svc && /^  [a-zA-Z0-9_-]+:/ { c++ }
        END { print c+0 }
    ')

    # If no services remain, write a valid empty compose (preserves stack dir + App-Data)
    local stack_deleted="false"
    if [[ "$remaining_services" -eq 0 ]]; then
        # Remove any lingering containers (already killed above, just clean up)
        $DOCKER_COMPOSE_CMD -f "$target_dir/docker-compose.yml" rm -f >/dev/null 2>&1 || true
        # Write a valid minimal compose so the stack remains usable
        # Use multi-line format so section-aware merge works correctly on redeploy
        printf 'services:\n  # (empty — available for template deployment)\n' > "$target_dir/docker-compose.yml"
        stack_deleted="true"
    else
        # Write updated compose
        printf '%s\n' "$compose_content" > "$target_dir/docker-compose.yml"

        # Validate merged compose file — rollback on failure
        local env_args=()
        [[ -f "$target_dir/.env" ]] && env_args=(--env-file "$target_dir/.env")
        local validate_output
        validate_output=$($DOCKER_COMPOSE_CMD -f "$target_dir/docker-compose.yml" "${env_args[@]}" config 2>&1)
        if [[ $? -ne 0 ]]; then
            cp "$target_dir/docker-compose.yml.bak.${timestamp}" "$target_dir/docker-compose.yml"
            _api_error 422 "Undeploy produced invalid compose file. Rolled back. Error: $(echo "$validate_output" | head -3)"
            return
        fi

    fi

    # Clean up .env: remove template section header AND the KEY=VALUE lines below it
    if [[ -f "$target_dir/.env" ]]; then
        local env_before
        env_before=$(cat "$target_dir/.env")
        local env_after
        env_after=$(printf '%s\n' "$env_before" | awk -v tpl="$name" '
            BEGIN { skip=0 }
            # Match section separator line
            /^# =+$/ {
                # Peek: if we are starting a skip block, this is the trailing separator
                if (skip == 2) { skip=3; next }
                # Save potential header start
                hold=$0; skip=1; next
            }
            skip == 1 {
                # Check if this is the template header line
                if ($0 ~ "^# Template: " tpl) { skip=2; next }
                # Not our template — print the held separator and this line
                print hold; print; skip=0; next
            }
            skip == 2 {
                # Still in header — skip the closing separator
                if ($0 ~ /^# =+$/) { skip=3; next }
                # Unexpected line in header position — print held content
                print hold; print; skip=0; next
            }
            skip == 3 {
                # Skip KEY=VALUE lines belonging to this template section
                # Stop when we hit a blank line, a comment block, or end of file
                if ($0 ~ /^$/) { skip=0; next }
                if ($0 ~ /^# =+$/) { skip=0 }
                if (skip == 3) next
            }
            { print }
        ')
        printf '%s\n' "$env_after" > "$target_dir/.env"
    fi

    # Remove deployed config data from App-Data if requested
    local data_removed="false"
    if [[ "$remove_data" == "true" ]]; then
        local config_target_name
        config_target_name=$(printf '%s' "$meta" | jq -r '.config_path // empty' 2>/dev/null)
        if [[ -n "$config_target_name" ]]; then
            local app_data="${APP_DATA_DIR:-$target_dir/App-Data}"
            if [[ "$app_data" == ./* ]]; then
                app_data="$target_dir/${app_data#./}"
            fi
            local config_dir="$app_data/$config_target_name"
            if [[ -d "$config_dir" ]]; then
                _force_remove_dir "$config_dir"
                data_removed="true"
            fi
        fi
    fi

    # Build JSON arrays
    local svc_removed_json="["
    local first=true
    for svc in "${services_to_remove[@]}"; do
        if $first; then
            svc_removed_json+="\"$(_api_json_escape "$svc")\""
            first=false
        else
            svc_removed_json+=",\"$(_api_json_escape "$svc")\""
        fi
    done
    svc_removed_json+="]"

    local ctr_removed_json="["
    first=true
    for ctr in "${containers_removed[@]}"; do
        if $first; then
            ctr_removed_json+="\"$(_api_json_escape "$ctr")\""
            first=false
        else
            ctr_removed_json+=",\"$(_api_json_escape "$ctr")\""
        fi
    done
    ctr_removed_json+="]"

    # Record undeploy event
    _record_deploy_event "undeploy" "$name" "$target_stack" "$svc_removed_json" "docker-compose.yml.bak.${timestamp}"

    local msg="Services removed from $target_stack successfully"
    [[ "$stack_deleted" == "true" ]] && msg="Stack $target_stack fully removed (no services remaining)"

    [[ "$data_removed" == "true" ]] && msg="$msg (configuration data removed)"

    _api_success "{\"success\": true, \"template\": \"$(_api_json_escape "$name")\", \"target_stack\": \"$(_api_json_escape "$target_stack")\", \"services_removed\": $svc_removed_json, \"containers_removed\": $ctr_removed_json, \"backup_file\": \"docker-compose.yml.bak.${timestamp}\", \"stack_deleted\": $stack_deleted, \"data_removed\": $data_removed, \"message\": \"$msg\"}"
}

handle_template_import() {
    local body="$1"

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required"
        return
    fi

    local name
    name=$(printf '%s' "$body" | jq -r '.name // empty' 2>/dev/null)
    local compose
    compose=$(printf '%s' "$body" | jq -r '.compose // empty' 2>/dev/null)
    local metadata
    metadata=$(printf '%s' "$body" | jq -c '.metadata // {}' 2>/dev/null)

    if [[ -z "$name" || -z "$compose" ]]; then
        _api_error 400 "Missing required fields: name, compose"
        return
    fi

    # Security: sanitize template name — only allow lowercase alphanumeric, hyphens, underscores
    name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g' | head -c 64)
    # Prevent path traversal
    if [[ "$name" == *".."* || "$name" == *"/"* || -z "$name" ]]; then
        _api_error 400 "Invalid template name"
        return
    fi

    local tdir="$TEMPLATES_DIR/$name"
    mkdir -p "$tdir"

    printf '%s' "$compose" > "$tdir/docker-compose.yml"

    # Create template.json from metadata
    local template_meta
    template_meta=$(printf '%s' "$metadata" | jq --arg n "$name" '. + {"name": $n}' 2>/dev/null || echo "{\"name\": \"$name\"}")
    printf '%s' "$template_meta" > "$tdir/template.json"

    # Also write .env if provided
    local env_content
    env_content=$(printf '%s' "$body" | jq -r '.env // empty' 2>/dev/null)
    if [[ -n "$env_content" ]]; then
        printf '%s' "$env_content" > "$tdir/.env"
    fi

    _api_success "{\"success\": true, \"name\": \"$(_api_json_escape "$name")\", \"message\": \"Template imported successfully\"}"
}

# POST /templates/fetch-url — Fetch compose content from URL without saving
handle_template_fetch_url() {
    local body="$1"

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required"
        return
    fi

    local url
    url=$(printf '%s' "$body" | jq -r '.url // empty' 2>/dev/null)

    if [[ -z "$url" ]]; then
        _api_error 400 "Missing required field: url"
        return
    fi

    # Security: only allow http/https URLs
    if [[ "$url" != http://* && "$url" != https://* ]]; then
        _api_error 400 "URL must start with http:// or https://"
        return
    fi

    # SSRF protection: block private/internal IPs
    _api_validate_url "$url" "Template fetch URL" || return

    # Auto-convert GitHub blob URLs to raw URLs
    if [[ "$url" == *"github.com/"*"/blob/"* ]]; then
        url=$(echo "$url" | sed 's|github\.com/\([^/]*/[^/]*\)/blob/|raw.githubusercontent.com/\1/|')
    fi

    # Fetch the compose content
    local compose_content
    compose_content=$(curl -fsSL --max-time 30 "$url" 2>/dev/null)
    if [[ -z "$compose_content" ]]; then
        _api_error 400 "Failed to fetch content from URL"
        return
    fi

    local escaped_content
    escaped_content=$(_api_json_escape "$compose_content")
    local escaped_url
    escaped_url=$(_api_json_escape "$url")

    _api_success "{\"content\": \"$escaped_content\", \"url\": \"$escaped_url\"}"
}

# POST /templates/import-url — Import a template from a URL
handle_template_import_url() {
    local body="$1"

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required"
        return
    fi

    local url
    url=$(printf '%s' "$body" | jq -r '.url // empty' 2>/dev/null)
    local name
    name=$(printf '%s' "$body" | jq -r '.name // empty' 2>/dev/null)

    if [[ -z "$url" ]]; then
        _api_error 400 "Missing required field: url"
        return
    fi

    # Security: only allow http/https URLs
    if [[ "$url" != http://* && "$url" != https://* ]]; then
        _api_error 400 "URL must start with http:// or https://"
        return
    fi

    # SSRF protection: block private/internal IPs
    _api_validate_url "$url" "Template import URL" || return

    # Auto-convert GitHub blob URLs to raw URLs
    # https://github.com/user/repo/blob/branch/path → https://raw.githubusercontent.com/user/repo/branch/path
    if [[ "$url" == *"github.com/"*"/blob/"* ]]; then
        url=$(echo "$url" | sed 's|github\.com/\([^/]*/[^/]*\)/blob/|raw.githubusercontent.com/\1/|')
    fi

    # Fetch the compose content
    local compose_content
    compose_content=$(curl -fsSL --max-time 30 "$url" 2>/dev/null)
    if [[ -z "$compose_content" ]]; then
        _api_error 400 "Failed to fetch content from URL"
        return
    fi

    # Auto-detect name from URL if not provided
    if [[ -z "$name" ]]; then
        # Extract directory name or filename from URL path
        name=$(echo "$url" | sed 's|.*/||; s|\.ya\?ml$||; s|docker-compose||; s|compose||' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g; s/^-*//; s/-*$//')
        # If name is empty after cleanup, try parent directory
        if [[ -z "$name" || "$name" == "-" ]]; then
            name=$(echo "$url" | sed 's|/[^/]*$||; s|.*/||' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g')
        fi
        [[ -z "$name" ]] && name="imported-$(date +%s)"
    fi

    # Sanitize name
    name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g' | head -c 64)
    if [[ "$name" == *".."* || "$name" == *"/"* || -z "$name" ]]; then
        _api_error 400 "Invalid template name"
        return
    fi

    # Validate it looks like a compose file
    local tmpfile
    tmpfile=$(mktemp /tmp/dcs-validate-XXXXXX.yml)
    printf '%s' "$compose_content" > "$tmpfile"
    local validate_output
    validate_output=$($DOCKER_COMPOSE_CMD -f "$tmpfile" config 2>&1)
    local validate_rc=$?
    rm -f "$tmpfile"

    if [[ $validate_rc -ne 0 ]]; then
        local escaped_err
        escaped_err=$(_api_json_escape "$validate_output")
        _api_error 422 "Invalid compose file: $escaped_err"
        return
    fi

    # Extract service names for metadata
    local services
    services=$(printf '%s' "$compose_content" | grep -E '^  [a-zA-Z_-][a-zA-Z0-9_-]*:' | sed 's/:.*//' | tr -d ' ' | paste -sd ',' -)

    # Create template directory
    local tdir="$TEMPLATES_DIR/$name"
    mkdir -p "$tdir"

    printf '%s' "$compose_content" > "$tdir/docker-compose.yml"

    # Create template.json
    local escaped_name escaped_url escaped_services
    escaped_name=$(_api_json_escape "$name")
    escaped_url=$(_api_json_escape "$url")
    escaped_services=$(_api_json_escape "$services")
    printf '{"name": "%s", "description": "Imported from %s", "category": "other", "tags": ["imported", "url"], "source_url": "%s", "services": "%s"}' \
        "$escaped_name" "$escaped_url" "$escaped_url" "$escaped_services" > "$tdir/template.json"

    _audit_log "template_import_url" "Imported template '$name' from $url" 2>/dev/null

    _api_success "{\"success\": true, \"name\": \"$escaped_name\", \"source_url\": \"$escaped_url\", \"message\": \"Template imported from URL successfully\"}"
}

# GET /templates/gallery — List templates from gallery catalog
handle_template_gallery() {
    local gallery_file="$BASE_DIR/.config/template-gallery.json"

    if [[ ! -f "$gallery_file" ]]; then
        _api_success "{\"templates\": [], \"total\": 0}"
        return
    fi

    local content
    content=$(cat "$gallery_file" 2>/dev/null)
    if [[ -z "$content" ]]; then
        _api_success "{\"templates\": [], \"total\": 0}"
        return
    fi

    # Optional category filter from query string
    local category="${QUERY_PARAMS[category]:-}"

    if [[ -n "$category" ]] && command -v jq >/dev/null 2>&1; then
        local filtered
        filtered=$(printf '%s' "$content" | jq --arg cat "$category" '[.[] | select(.category == $cat)]' 2>/dev/null)
        local count
        count=$(printf '%s' "$filtered" | jq 'length' 2>/dev/null || echo "0")
        _api_success "{\"templates\": $filtered, \"total\": $count}"
    else
        local count
        if command -v jq >/dev/null 2>&1; then
            count=$(printf '%s' "$content" | jq 'length' 2>/dev/null || echo "0")
        else
            count="0"
        fi
        _api_success "{\"templates\": $content, \"total\": $count}"
    fi
}

# POST /stacks/:name/clone — Clone a stack
handle_stack_clone() {
    local stack_name="$1"
    local body="$2"

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required"
        return
    fi

    local new_name
    new_name=$(printf '%s' "$body" | jq -r '.new_name // empty' 2>/dev/null)

    if [[ -z "$new_name" ]]; then
        _api_error 400 "Missing required field: new_name"
        return
    fi

    # Sanitize
    new_name=$(echo "$new_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g' | head -c 64)
    if [[ "$new_name" == *".."* || "$new_name" == *"/"* || -z "$new_name" ]]; then
        _api_error 400 "Invalid stack name"
        return
    fi

    local src_dir="$COMPOSE_DIR/$stack_name"
    local dst_dir="$COMPOSE_DIR/$new_name"

    if [[ ! -d "$src_dir" ]]; then
        _api_error 404 "Source stack not found: $stack_name"
        return
    fi

    if [[ -d "$dst_dir" ]]; then
        _api_error 409 "Stack already exists: $new_name"
        return
    fi

    # Copy the stack directory
    cp -r "$src_dir" "$dst_dir"

    # Update container_name references in compose file
    local compose_file="$dst_dir/docker-compose.yml"
    if [[ -f "$compose_file" ]]; then
        sed -i "s/container_name:.*${stack_name}/container_name: ${new_name}/g" "$compose_file" 2>/dev/null
    fi

    _audit_log "stack_clone" "Cloned stack '$stack_name' to '$new_name'" 2>/dev/null

    local escaped_src escaped_dst
    escaped_src=$(_api_json_escape "$stack_name")
    escaped_dst=$(_api_json_escape "$new_name")
    _api_success "{\"success\": true, \"source\": \"$escaped_src\", \"name\": \"$escaped_dst\", \"message\": \"Stack cloned successfully\"}"
}

# GET /images/search — Search Docker Hub for images
handle_image_search() {
    local query="${QUERY_PARAMS[q]:-}"
    local limit="${QUERY_PARAMS[limit]:-25}"

    if [[ -z "$query" ]]; then
        _api_error 400 "Missing required query parameter: q"
        return
    fi

    local results
    results=$(docker search --format '{"name":"{{.Name}}","description":"{{.Description}}","stars":{{.StarCount}},"official":"{{.IsOfficial}}","automated":"{{.IsAutomated}}"}' --limit "$limit" "$query" 2>/dev/null | sed 's/$/,/' | sed '$ s/,$//')

    if [[ -z "$results" ]]; then
        _api_success "{\"results\": [], \"total\": 0, \"query\": \"$(_api_json_escape "$query")\"}"
        return
    fi

    local count
    count=$(echo "$results" | wc -l)
    _api_success "{\"results\": [$results], \"total\": $count, \"query\": \"$(_api_json_escape "$query")\"}"
}

# POST /compose/validate — Validate a compose file
handle_compose_validate() {
    local body="$1"

    local content stack
    if command -v jq >/dev/null 2>&1; then
        content=$(printf '%s' "$body" | jq -r '.content // empty' 2>/dev/null)
        stack=$(printf '%s' "$body" | jq -r '.stack // empty' 2>/dev/null)
    fi

    local tmpfile validate_output validate_rc

    if [[ -n "$content" ]]; then
        tmpfile=$(mktemp /tmp/dcs-validate-XXXXXX.yml)
        printf '%s' "$content" > "$tmpfile"
        validate_output=$($DOCKER_COMPOSE_CMD -f "$tmpfile" config 2>&1)
        validate_rc=$?
        rm -f "$tmpfile"
    elif [[ -n "$stack" ]]; then
        local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
        if [[ ! -f "$compose_file" ]]; then
            _api_error 404 "Stack compose file not found: $stack"
            return
        fi
        validate_output=$($DOCKER_COMPOSE_CMD -f "$compose_file" config 2>&1)
        validate_rc=$?
    else
        _api_error 400 "Provide either 'content' or 'stack'"
        return
    fi

    local escaped_output
    escaped_output=$(_api_json_escape "$validate_output")

    # Extract service names from valid config
    local services="[]"
    if [[ $validate_rc -eq 0 ]] && command -v jq >/dev/null 2>&1; then
        services=$(echo "$validate_output" | grep -E '^  [a-zA-Z_-][a-zA-Z0-9_-]*:' | sed 's/:.*//' | tr -d ' ' | jq -R . | jq -s . 2>/dev/null || echo "[]")
    fi

    if [[ $validate_rc -eq 0 ]]; then
        _api_success "{\"valid\": true, \"errors\": [], \"warnings\": [], \"services\": $services, \"output\": \"$escaped_output\"}"
    else
        _api_success "{\"valid\": false, \"errors\": [\"$escaped_output\"], \"warnings\": [], \"services\": [], \"output\": \"$escaped_output\"}"
    fi
}

# GET /export/:type — Export data
handle_export() {
    local export_type="$1"

    case "$export_type" in
        health)
            # Export current health report as JSON
            local health_data
            health_data=$(handle_health_internal 2>/dev/null || echo "{}")
            _api_success "$health_data"
            ;;
        system)
            local system_data
            system_data=$(handle_system_info_internal 2>/dev/null || echo "{}")
            _api_success "$system_data"
            ;;
        config)
            local config_data="{}"
            if [[ -f "$BASE_DIR/.env" ]]; then
                local vars=""
                while IFS='=' read -r key value; do
                    [[ -z "$key" || "$key" == \#* ]] && continue
                    key=$(echo "$key" | xargs)
                    value=$(echo "$value" | xargs | sed 's/^"//; s/"$//')
                    vars="${vars}\"$(_api_json_escape "$key")\": \"$(_api_json_escape "$value")\","
                done < "$BASE_DIR/.env"
                vars="${vars%,}"
                config_data="{$vars}"
            fi
            _api_success "{\"type\": \"config\", \"data\": $config_data}"
            ;;
        *)
            _api_error 400 "Invalid export type: $export_type. Valid types: health, system, config"
            ;;
    esac
}

# GET /audit — Get audit log entries
handle_audit_log() {
    local limit="${QUERY_PARAMS[limit]:-100}"
    local action_filter="${QUERY_PARAMS[action]:-}"
    local audit_file="$BASE_DIR/.data/audit.jsonl"

    if [[ ! -f "$audit_file" ]]; then
        _api_success "{\"entries\": [], \"total\": 0}"
        return
    fi

    local entries
    if [[ -n "$action_filter" ]] && command -v jq >/dev/null 2>&1; then
        entries=$(tail -n "$limit" "$audit_file" | jq --arg action "$action_filter" 'select(.action == $action)' 2>/dev/null | jq -s '.' 2>/dev/null)
    else
        entries=$(tail -n "$limit" "$audit_file" | jq -s '.' 2>/dev/null)
    fi

    if [[ -z "$entries" || "$entries" == "null" ]]; then
        entries="[]"
    fi

    local count
    count=$(printf '%s' "$entries" | jq 'length' 2>/dev/null || echo "0")

    # Reverse so newest first
    entries=$(printf '%s' "$entries" | jq 'reverse' 2>/dev/null || echo "$entries")

    _api_success "{\"entries\": $entries, \"total\": $count}"
}

# Audit log helper
_audit_log() {
    local action="$1"
    local detail="$2"
    local audit_file="$BASE_DIR/.data/audit.jsonl"

    mkdir -p "$BASE_DIR/.data"

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local escaped_action escaped_detail
    escaped_action=$(_api_json_escape "$action")
    escaped_detail=$(_api_json_escape "$detail")

    printf '{"timestamp":"%s","action":"%s","detail":"%s"}\n' "$timestamp" "$escaped_action" "$escaped_detail" >> "$audit_file"

    # Fire webhooks if configured
    _webhook_fire "$action" "$detail" 2>/dev/null &
}

# Webhook fire helper
_webhook_fire() {
    local event="$1"
    local detail="$2"
    local webhooks_file="$BASE_DIR/.data/webhooks.json"

    [[ ! -f "$webhooks_file" ]] && return
    command -v jq >/dev/null 2>&1 || return

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local urls
    urls=$(jq -r --arg evt "$event" '.[] | select(.enabled == true) | select(.events | index($evt)) | .url' "$webhooks_file" 2>/dev/null)

    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        curl -s -X POST -H "Content-Type: application/json" \
            -d "{\"event\": \"$(_api_json_escape "$event")\", \"detail\": \"$(_api_json_escape "$detail")\", \"timestamp\": \"$timestamp\"}" \
            --max-time 10 "$url" >/dev/null 2>&1 &
    done <<< "$urls"
}

# GET /webhooks — List webhooks
handle_webhooks_list() {
    local webhooks_file="$BASE_DIR/.data/webhooks.json"

    if [[ ! -f "$webhooks_file" ]]; then
        _api_success "{\"webhooks\": [], \"total\": 0}"
        return
    fi

    local content
    content=$(cat "$webhooks_file" 2>/dev/null || echo "[]")
    local count
    count=$(printf '%s' "$content" | jq 'length' 2>/dev/null || echo "0")

    _api_success "{\"webhooks\": $content, \"total\": $count}"
}

# POST /webhooks — Create a webhook
handle_webhook_create() {
    local body="$1"
    local webhooks_file="$BASE_DIR/.data/webhooks.json"

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required"
        return
    fi

    mkdir -p "$BASE_DIR/.data"

    local url events enabled
    url=$(printf '%s' "$body" | jq -r '.url // empty' 2>/dev/null)
    events=$(printf '%s' "$body" | jq -c '.events // ["deploy","health_change"]' 2>/dev/null)
    enabled=$(printf '%s' "$body" | jq -r '.enabled // true' 2>/dev/null)

    if [[ -z "$url" ]]; then
        _api_error 400 "Missing required field: url"
        return
    fi

    # SSRF protection: block private/internal IPs for webhook targets
    _api_validate_url "$url" "Webhook URL" || return

    local id
    id="wh-$(date +%s)-$RANDOM"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Load or create webhooks array
    local existing="[]"
    [[ -f "$webhooks_file" ]] && existing=$(cat "$webhooks_file" 2>/dev/null || echo "[]")

    local new_webhook
    new_webhook=$(jq -n --arg id "$id" --arg url "$url" --argjson events "$events" --argjson enabled "$enabled" --arg ts "$timestamp" \
        '{id: $id, url: $url, events: $events, enabled: $enabled, created_at: $ts}')

    printf '%s' "$existing" | jq --argjson wh "$new_webhook" '. + [$wh]' > "$webhooks_file"

    _api_success "{\"success\": true, \"webhook\": $new_webhook}"
}

# DELETE /webhooks/:id — Delete a webhook
handle_webhook_delete() {
    local webhook_id="$1"
    local webhooks_file="$BASE_DIR/.data/webhooks.json"

    if [[ ! -f "$webhooks_file" ]]; then
        _api_error 404 "Webhook not found"
        return
    fi

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required"
        return
    fi

    local new_list
    new_list=$(jq --arg id "$webhook_id" '[.[] | select(.id != $id)]' "$webhooks_file" 2>/dev/null)
    printf '%s' "$new_list" > "$webhooks_file"

    _api_success "{\"success\": true, \"deleted\": \"$(_api_json_escape "$webhook_id")\"}"
}

# POST /webhooks/:id/test — Test a webhook
handle_webhook_test() {
    local webhook_id="$1"
    local webhooks_file="$BASE_DIR/.data/webhooks.json"

    if [[ ! -f "$webhooks_file" ]]; then
        _api_error 404 "Webhook not found"
        return
    fi

    local url
    url=$(jq -r --arg id "$webhook_id" '.[] | select(.id == $id) | .url' "$webhooks_file" 2>/dev/null)

    if [[ -z "$url" ]]; then
        _api_error 404 "Webhook not found"
        return
    fi

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Content-Type: application/json" \
        -d "{\"event\": \"test\", \"detail\": \"Webhook test from DCS\", \"timestamp\": \"$timestamp\"}" \
        --max-time 10 "$url" 2>/dev/null)

    _api_success "{\"success\": true, \"status_code\": $http_code, \"url\": \"$(_api_json_escape "$url")\", \"timestamp\": \"$timestamp\"}"
}

# POST /templates/:name/update — Update an existing template's compose, metadata, and .env
handle_template_update() {
    local name="$1"
    local body="$2"

    # Security: validate template name
    if [[ "$name" == *".."* || "$name" == *"/"* || -z "$name" ]]; then
        _api_error 400 "Invalid template name"
        return
    fi

    local tdir="$TEMPLATES_DIR/$name"

    if [[ ! -d "$tdir" ]]; then
        _api_error 404 "Template not found: $name"
        return
    fi

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required"
        return
    fi

    # Update compose if provided
    local compose
    compose=$(printf '%s' "$body" | jq -r '.compose // empty' 2>/dev/null)
    [[ -n "$compose" ]] && printf '%s' "$compose" > "$tdir/docker-compose.yml"

    # Update metadata if provided
    local metadata
    metadata=$(printf '%s' "$body" | jq -c '.metadata // empty' 2>/dev/null)
    if [[ -n "$metadata" && "$metadata" != "null" && "$metadata" != "" ]]; then
        local template_meta
        template_meta=$(printf '%s' "$metadata" | jq --arg n "$name" '. + {"name": $n}' 2>/dev/null || echo "{\"name\": \"$name\"}")
        printf '%s' "$template_meta" > "$tdir/template.json"
    fi

    # Update .env if provided
    local env_content
    env_content=$(printf '%s' "$body" | jq -r '.env // empty' 2>/dev/null)
    [[ -n "$env_content" ]] && printf '%s' "$env_content" > "$tdir/.env"

    _api_success "{\"success\": true, \"name\": \"$(_api_json_escape "$name")\", \"message\": \"Template updated successfully\"}"
}

# DELETE /templates/:name — Delete a template
handle_template_delete() {
    local name="$1"

    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    # Security: validate template name
    if [[ "$name" == *".."* || "$name" == *"/"* || -z "$name" ]]; then
        _api_error 400 "Invalid template name"
        return
    fi

    local tdir="$TEMPLATES_DIR/$name"

    if [[ ! -d "$tdir" ]]; then
        _api_error 404 "Template not found: $name"
        return
    fi

    rm -rf "$tdir"
    _api_success "{\"success\": true, \"name\": \"$(_api_json_escape "$name")\", \"message\": \"Template deleted\"}"
}

# =============================================================================
# FEATURE: SCHEDULED AUTOMATIONS
# =============================================================================

AUTOMATIONS_FILE="$BASE_DIR/.api-auth/automations.json"

_init_automations_file() {
    if [[ ! -f "$AUTOMATIONS_FILE" ]]; then
        echo '[]' > "$AUTOMATIONS_FILE"
    fi
}

handle_automations_list() {
    _init_automations_file
    if command -v jq >/dev/null 2>&1; then
        local rules
        rules=$(jq -c '.' "$AUTOMATIONS_FILE" 2>/dev/null || echo "[]")
        local count
        count=$(jq 'length' "$AUTOMATIONS_FILE" 2>/dev/null || echo 0)
        _api_success "{\"automations\": $rules, \"total\": $count}"
    else
        _api_success "{\"automations\": [], \"total\": 0}"
    fi
}

handle_automation_create() {
    local body="$1"
    _init_automations_file

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required"
        return
    fi

    local name trigger_type trigger_value action_type action_target enabled
    name=$(printf '%s' "$body" | jq -r '.name // empty' 2>/dev/null)
    trigger_type=$(printf '%s' "$body" | jq -r '.trigger_type // empty' 2>/dev/null)
    trigger_value=$(printf '%s' "$body" | jq -r '.trigger_value // ""' 2>/dev/null)
    action_type=$(printf '%s' "$body" | jq -r '.action_type // empty' 2>/dev/null)
    action_target=$(printf '%s' "$body" | jq -r '.action_target // "*"' 2>/dev/null)
    enabled=$(printf '%s' "$body" | jq -r '.enabled // true' 2>/dev/null)

    if [[ -z "$name" || -z "$trigger_type" || -z "$action_type" ]]; then
        _api_error 400 "Missing required fields: name, trigger_type, action_type"
        return
    fi

    local auto_id="auto_$(date +%s)_$RANDOM"
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local automation="{\"id\": \"$auto_id\", \"name\": \"$(_api_json_escape "$name")\", \"enabled\": $enabled, \"trigger_type\": \"$(_api_json_escape "$trigger_type")\", \"trigger_value\": \"$(_api_json_escape "$trigger_value")\", \"action_type\": \"$(_api_json_escape "$action_type")\", \"action_target\": \"$(_api_json_escape "$action_target")\", \"created_at\": \"$ts\", \"run_count\": 0, \"last_run\": null, \"history\": []}"

    jq --argjson auto "$automation" '. + [$auto]' "$AUTOMATIONS_FILE" > "${AUTOMATIONS_FILE}.tmp" 2>/dev/null && mv "${AUTOMATIONS_FILE}.tmp" "$AUTOMATIONS_FILE"

    # If schedule trigger, validate and add crontab entry
    if [[ "$trigger_type" == "schedule" && "$enabled" == "true" && -n "$trigger_value" ]]; then
        if ! _validate_cron_expression "$trigger_value"; then
            _api_error 400 "Invalid cron expression: $(_api_json_escape "$trigger_value")"
            return
        fi
        _add_automation_cron "$auto_id" "$trigger_value" "$action_type" "$action_target"
    fi

    _api_success "$automation"
}

handle_automation_update() {
    local auto_id="$1"
    local body="$2"
    _init_automations_file

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required"
        return
    fi

    # Check automation exists
    local exists
    exists=$(jq --arg id "$auto_id" '[.[] | select(.id == $id)] | length' "$AUTOMATIONS_FILE" 2>/dev/null)
    if [[ "$exists" == "0" ]]; then
        _api_error 404 "Automation not found: $auto_id"
        return
    fi

    # Merge updates
    local updates
    updates=$(printf '%s' "$body" | jq -c 'del(.id, .created_at, .run_count, .last_run, .history)' 2>/dev/null)

    jq --arg id "$auto_id" --argjson upd "$updates" '
        map(if .id == $id then . + $upd else . end)
    ' "$AUTOMATIONS_FILE" > "${AUTOMATIONS_FILE}.tmp" 2>/dev/null && mv "${AUTOMATIONS_FILE}.tmp" "$AUTOMATIONS_FILE"

    # Update cron
    _remove_automation_cron "$auto_id"
    local enabled trigger_type trigger_value action_type action_target
    enabled=$(jq -r --arg id "$auto_id" '.[] | select(.id == $id) | .enabled' "$AUTOMATIONS_FILE" 2>/dev/null)
    trigger_type=$(jq -r --arg id "$auto_id" '.[] | select(.id == $id) | .trigger_type' "$AUTOMATIONS_FILE" 2>/dev/null)
    trigger_value=$(jq -r --arg id "$auto_id" '.[] | select(.id == $id) | .trigger_value' "$AUTOMATIONS_FILE" 2>/dev/null)
    action_type=$(jq -r --arg id "$auto_id" '.[] | select(.id == $id) | .action_type' "$AUTOMATIONS_FILE" 2>/dev/null)
    action_target=$(jq -r --arg id "$auto_id" '.[] | select(.id == $id) | .action_target' "$AUTOMATIONS_FILE" 2>/dev/null)

    if [[ "$trigger_type" == "schedule" && "$enabled" == "true" && -n "$trigger_value" ]]; then
        _add_automation_cron "$auto_id" "$trigger_value" "$action_type" "$action_target"
    fi

    local updated
    updated=$(jq -c --arg id "$auto_id" '.[] | select(.id == $id)' "$AUTOMATIONS_FILE" 2>/dev/null)

    _api_success "$updated"
}

handle_automation_delete() {
    local auto_id="$1"
    _init_automations_file

    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required"
        return
    fi

    _remove_automation_cron "$auto_id"
    jq --arg id "$auto_id" '[.[] | select(.id != $id)]' "$AUTOMATIONS_FILE" > "${AUTOMATIONS_FILE}.tmp" 2>/dev/null && mv "${AUTOMATIONS_FILE}.tmp" "$AUTOMATIONS_FILE"

    _api_success "{\"success\": true, \"deleted\": \"$(_api_json_escape "$auto_id")\"}"
}

handle_automation_history() {
    local auto_id="$1"
    _init_automations_file

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required"
        return
    fi

    local history
    history=$(jq -c --arg id "$auto_id" '.[] | select(.id == $id) | .history // []' "$AUTOMATIONS_FILE" 2>/dev/null || echo "[]")

    _api_success "{\"automation_id\": \"$(_api_json_escape "$auto_id")\", \"history\": $history}"
}

# Cron helpers for automations
_validate_cron_expression() {
    local expr="$1"
    # Reject empty or dangerous characters (shell metacharacters, newlines)
    [[ -z "$expr" ]] && return 1
    case "$expr" in
        *';'*|*'|'*|*'`'*|*'$('*|*'&'*|*'>'*|*'<'*|*$'\n'*|*$'\r'*) return 1 ;;
    esac
    # Validate standard 5-field cron format: min hour dom mon dow
    # Each field: number, range (1-5), list (1,3,5), step (*/5), or wildcard (*)
    local cron_field='(\*|[0-9]{1,2}(-[0-9]{1,2})?(,[0-9]{1,2}(-[0-9]{1,2})?)*)(\/[0-9]{1,2})?'
    local cron_pattern="^${cron_field}[[:space:]]+${cron_field}[[:space:]]+${cron_field}[[:space:]]+${cron_field}[[:space:]]+${cron_field}$"
    [[ "$expr" =~ $cron_pattern ]] && return 0
    # Also allow @reboot, @hourly, @daily, @weekly, @monthly, @yearly, @annually
    case "$expr" in
        @reboot|@hourly|@daily|@weekly|@monthly|@yearly|@annually) return 0 ;;
    esac
    return 1
}

_add_automation_cron() {
    local auto_id="$1" cron_expr="$2" action="$3" target="$4"
    # Security: validate cron expression to prevent injection
    if ! _validate_cron_expression "$cron_expr"; then
        return 1
    fi
    local api_port="${API_PORT:-9876}"
    local api_bind="${API_BIND:-127.0.0.1}"
    local cron_line="$cron_expr curl -s -X POST http://${api_bind}:${api_port}/automations/${auto_id}/run >/dev/null 2>&1 # DCS-AUTO:${auto_id}"
    (crontab -l 2>/dev/null; echo "$cron_line") | crontab - 2>/dev/null
}

_remove_automation_cron() {
    local auto_id="$1"
    crontab -l 2>/dev/null | grep -v "# DCS-AUTO:${auto_id}" | crontab - 2>/dev/null
}

# =============================================================================
# FEATURE: NETWORK TOPOLOGY MAP
# =============================================================================

handle_topology() {
    local -a nodes=()
    local -a edges=()
    local -a net_entries=()

    # Build network map: network_name -> containers[]
    declare -A network_containers
    declare -A container_ips   # container_ips["cname|netname"] = "ip"

    # Get all running containers with their networks
    while IFS= read -r container_id; do
        [[ -z "$container_id" ]] && continue
        local cname cstate chealth cimage cports
        cname=$(docker inspect --format '{{.Name}}' "$container_id" 2>/dev/null | sed 's|^/||')
        cstate=$(docker inspect --format '{{.State.Status}}' "$container_id" 2>/dev/null)
        chealth=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id" 2>/dev/null)
        cimage=$(docker inspect --format '{{.Config.Image}}' "$container_id" 2>/dev/null)

        # Get ports (standard Docker notation: host:port->container/proto)
        cports=$(docker inspect --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{if .HostIp}}{{.HostIp}}{{else}}0.0.0.0{{end}}:{{.HostPort}}->{{end}}{{$p}} {{end}}' "$container_id" 2>/dev/null | sed 's/ $//')

        # Get stack label
        local cstack
        cstack=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$container_id" 2>/dev/null)
        [[ "$cstack" == "<no value>" ]] && cstack=""

        # Get networks + IPs
        local -a container_nets=()
        while IFS='|' read -r netname netip; do
            [[ -z "$netname" ]] && continue
            container_nets+=("\"$(_api_json_escape "$netname")\"")
            network_containers["$netname"]+="$cname "
            [[ -n "$netip" ]] && container_ips["$cname|$netname"]="$netip"
        done < <(docker inspect --format '{{range $key, $val := .NetworkSettings.Networks}}{{$key}}|{{$val.IPAddress}}{{"\n"}}{{end}}' "$container_id" 2>/dev/null)

        local container_nets_json
        container_nets_json=$(printf '%s,' "${container_nets[@]}")
        container_nets_json="[${container_nets_json%,}]"
        [[ ${#container_nets[@]} -eq 0 ]] && container_nets_json="[]"

        # Build ip_addresses JSON array
        local -a ip_entries=()
        for net_entry in "${container_nets[@]}"; do
            local net_clean="${net_entry//\"/}"
            local ip_val="${container_ips[$cname|$net_clean]:-}"
            [[ -n "$ip_val" ]] && ip_entries+=("{\"network\": \"$(_api_json_escape "$net_clean")\", \"ip\": \"$ip_val\"}")
        done
        local ips_json
        if [[ ${#ip_entries[@]} -gt 0 ]]; then
            ips_json=$(printf '%s,' "${ip_entries[@]}")
            ips_json="[${ips_json%,}]"
        else
            ips_json="[]"
        fi

        nodes+=("{\"id\": \"$(_api_json_escape "$cname")\", \"state\": \"$cstate\", \"health\": \"$chealth\", \"image\": \"$(_api_json_escape "$cimage")\", \"stack\": \"$(_api_json_escape "$cstack")\", \"networks\": $container_nets_json, \"ports\": \"$(_api_json_escape "$cports")\", \"ip_addresses\": $ips_json}")
    done < <(docker ps -a -q 2>/dev/null)

    # Build edges: containers sharing a network
    for net in "${!network_containers[@]}"; do
        local -a members
        read -ra members <<< "${network_containers[$net]}"
        for ((i=0; i<${#members[@]}; i++)); do
            for ((j=i+1; j<${#members[@]}; j++)); do
                edges+=("{\"source\": \"$(_api_json_escape "${members[$i]}")\", \"target\": \"$(_api_json_escape "${members[$j]}")\", \"network\": \"$(_api_json_escape "$net")\"}")
            done
        done
    done

    # Build network metadata
    while IFS= read -r net_id; do
        [[ -z "$net_id" ]] && continue
        local nname ndriver nsubnet ncontainer_count
        nname=$(docker network inspect --format '{{.Name}}' "$net_id" 2>/dev/null)
        ndriver=$(docker network inspect --format '{{.Driver}}' "$net_id" 2>/dev/null)
        nsubnet=$(docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$net_id" 2>/dev/null)
        ncontainer_count=$(echo "${network_containers[$nname]:-}" | wc -w)

        net_entries+=("{\"name\": \"$(_api_json_escape "$nname")\", \"driver\": \"$ndriver\", \"subnet\": \"$(_api_json_escape "$nsubnet")\", \"container_count\": $ncontainer_count}")
    done < <(docker network ls -q 2>/dev/null)

    local nodes_json edges_json nets_json
    nodes_json=$(printf '%s,' "${nodes[@]}"); nodes_json="[${nodes_json%,}]"; [[ ${#nodes[@]} -eq 0 ]] && nodes_json="[]"
    edges_json=$(printf '%s,' "${edges[@]}"); edges_json="[${edges_json%,}]"; [[ ${#edges[@]} -eq 0 ]] && edges_json="[]"
    nets_json=$(printf '%s,' "${net_entries[@]}"); nets_json="[${nets_json%,}]"; [[ ${#net_entries[@]} -eq 0 ]] && nets_json="[]"

    _api_success "{\"nodes\": $nodes_json, \"edges\": $edges_json, \"networks\": $nets_json}"
}

# =============================================================================
# SETUP WIZARD ENDPOINTS
# =============================================================================

# GET /setup/status — Always available, no auth. Reports whether server needs setup.
handle_setup_status() {
    _api_init_auth_dir
    if _api_is_initialized; then
        _api_success '{"initialized": true}'
    else
        local needs_admin="true" needs_config="true"
        [[ "$(_api_user_count)" -gt 0 ]] && needs_admin="false"
        [[ -f "$BASE_DIR/.env" ]] && needs_config="false"
        _api_success "{\"initialized\": false, \"needs_admin\": $needs_admin, \"needs_config\": $needs_config}"
    fi
}

# GET /setup/defaults — No auth, only when not initialized.
# Returns .env.example parsed as defaults + auto-detected system values + stack list.
handle_setup_defaults() {
    _api_require_setup_mode || return

    # Parse defaults from .env.example
    local defaults_json="{"
    local first=true
    if [[ -f "$BASE_DIR/.env.example" ]]; then
        while IFS= read -r line; do
            # Skip comments and blank lines
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// /}" ]] && continue
            # Extract KEY=VALUE
            if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*) ]]; then
                local key="${BASH_REMATCH[1]}"
                local val="${BASH_REMATCH[2]}"
                # Strip surrounding quotes
                val="${val#\"}" ; val="${val%\"}"
                val="${val#\'}" ; val="${val%\'}"
                [[ "$first" == "true" ]] && first=false || defaults_json+=","
                defaults_json+="\"$key\": \"$(_api_json_escape "$val")\""
            fi
        done < "$BASE_DIR/.env.example"
    fi
    defaults_json+="}"

    # Overlay current .env values on top of .env.example defaults (for resumed setup)
    if [[ -f "$BASE_DIR/.env" ]]; then
        local overlay_json="{"
        local ofirst=true
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// /}" ]] && continue
            if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*) ]]; then
                local okey="${BASH_REMATCH[1]}"
                local oval="${BASH_REMATCH[2]}"
                oval="${oval#\"}" ; oval="${oval%\"}"
                oval="${oval#\'}" ; oval="${oval%\'}"
                [[ "$ofirst" == "true" ]] && ofirst=false || overlay_json+=","
                overlay_json+="\"$okey\": \"$(_api_json_escape "$oval")\""
            fi
        done < "$BASE_DIR/.env"
        overlay_json+="}"
        # Merge: .env values override .env.example defaults
        if command -v jq >/dev/null 2>&1; then
            defaults_json=$(echo "$defaults_json" "$overlay_json" | jq -s '.[0] * .[1]' 2>/dev/null || echo "$defaults_json")
        fi
    fi

    # Build stacks array from DOCKER_STACKS or defaults
    local stacks_json="["
    local stack_list
    if [[ -n "${DOCKER_STACKS:-}" ]]; then
        read -ra stack_list <<< "$DOCKER_STACKS"
    else
        stack_list=(
            "core-infrastructure" "networking-security" "monitoring-management"
            "development-tools" "media-services" "web-applications"
            "storage-backup" "communication-collaboration"
            "entertainment-personal" "miscellaneous-services"
        )
    fi
    local sfirst=true
    for s in "${stack_list[@]}"; do
        [[ "$sfirst" == "true" ]] && sfirst=false || stacks_json+=","
        stacks_json+="\"$(_api_json_escape "$s")\""
    done
    stacks_json+="]"

    # Auto-detect system values
    local sys_hostname sys_tz sys_puid sys_pgid sys_docker sys_compose
    sys_hostname="$(hostname 2>/dev/null || echo 'unknown')"
    sys_tz="$(timedatectl show -p Timezone --value 2>/dev/null || echo 'UTC')"
    sys_puid="$(id -u 2>/dev/null || echo '1000')"
    sys_pgid="$(id -g 2>/dev/null || echo '1000')"
    sys_docker="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'unknown')"
    sys_compose="$($DOCKER_COMPOSE_CMD version --short 2>/dev/null || echo 'unknown')"

    # Check Docker availability
    local docker_ok="false"
    if docker info >/dev/null 2>&1; then docker_ok="true"; fi

    _api_success "{\"defaults\": $defaults_json, \"stacks\": $stacks_json, \"system\": {\"hostname\": \"$(_api_json_escape "$sys_hostname")\", \"timezone\": \"$(_api_json_escape "$sys_tz")\", \"puid\": $sys_puid, \"pgid\": $sys_pgid, \"docker_version\": \"$(_api_json_escape "$sys_docker")\", \"compose_version\": \"$(_api_json_escape "$sys_compose")\", \"docker_available\": $docker_ok}}"
}

# POST /setup/configure — Requires auth token, only when not initialized.
# Accepts env_vars + stacks array. Writes .env, syncs stack directories.
handle_setup_configure() {
    local body="$1"
    _api_require_setup_mode || return

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for setup configuration"
        return
    fi

    # Parse env_vars object and stacks array
    local env_vars stacks_array
    env_vars=$(echo "$body" | jq -r '.env_vars // empty' 2>/dev/null)
    stacks_array=$(echo "$body" | jq -r '.stacks // empty' 2>/dev/null)

    if [[ -z "$env_vars" ]] || [[ "$env_vars" == "null" ]]; then
        _api_error 400 "Missing required field: env_vars"
        return
    fi
    if [[ -z "$stacks_array" ]] || [[ "$stacks_array" == "null" ]]; then
        _api_error 400 "Missing required field: stacks"
        return
    fi

    # Build DOCKER_STACKS string from array
    local docker_stacks_str
    docker_stacks_str=$(echo "$stacks_array" | jq -r '.[]' 2>/dev/null | tr '\n' ' ')
    docker_stacks_str="${docker_stacks_str% }"  # trim trailing space

    # Validate all stack names
    local sname
    for sname in $docker_stacks_str; do
        if [[ ! "$sname" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
            _api_error 400 "Invalid stack name: $sname"
            return
        fi
    done

    # Backup existing .env
    if [[ -f "$BASE_DIR/.env" ]]; then
        cp "$BASE_DIR/.env" "$BASE_DIR/.env.bak" 2>/dev/null
    fi

    # Start from .env.example as template, or existing .env
    local env_file="$BASE_DIR/.env"
    if [[ ! -f "$env_file" ]] && [[ -f "$BASE_DIR/.env.example" ]]; then
        cp "$BASE_DIR/.env.example" "$env_file"
    elif [[ ! -f "$env_file" ]]; then
        touch "$env_file"
    fi

    # Read env content
    local env_content
    env_content=$(cat "$env_file")

    # Apply each env_var from the request
    local env_updated=0
    local keys
    keys=$(echo "$env_vars" | jq -r 'keys[]' 2>/dev/null)
    local key val
    for key in $keys; do
        val=$(echo "$env_vars" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null)
        # Replace existing KEY=... line or append
        if echo "$env_content" | grep -q "^${key}="; then
            env_content=$(echo "$env_content" | sed "s|^${key}=.*|${key}=\"${val}\"|")
            ((env_updated++))
        else
            env_content+=$'\n'"${key}=\"${val}\""
            ((env_updated++))
        fi
    done

    # Always set DOCKER_STACKS
    if echo "$env_content" | grep -q "^DOCKER_STACKS="; then
        env_content=$(echo "$env_content" | sed "s|^DOCKER_STACKS=.*|DOCKER_STACKS=\"${docker_stacks_str}\"|")
    else
        # Append with a proper section header so .env stays organized
        env_content+=$'\n\n'"# ─── Stack Configuration ─────────────────────────────────────────────────────"
        env_content+=$'\n'"DOCKER_STACKS=\"${docker_stacks_str}\""
    fi

    # Write .env
    echo "$env_content" > "$env_file"

    # Sync stack directories
    local stacks_created="[]" stacks_removed="[]" stacks_warned="[]"
    local created_list="" removed_list="" warned_list=""

    # Create directories for stacks that don't exist
    for sname in $docker_stacks_str; do
        local sdir="$COMPOSE_DIR/$sname"
        if [[ ! -d "$sdir" ]]; then
            mkdir -p "$sdir/App-Data"
            # Create placeholder compose
            cat > "$sdir/docker-compose.yml" <<'COMPOSE_EOF'
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
            cat > "$sdir/.env" <<ENV_EOF
# =============================================================================
# $sname — Stack Environment Variables
# =============================================================================

# Inherit from root .env:
# PUID, PGID, TZ, APP_DATA_DIR, PROXY_DOMAIN
ENV_EOF
            [[ -n "$created_list" ]] && created_list+=","
            created_list+="\"$(_api_json_escape "$sname")\""
        fi
    done

    # Check for directories that exist but are NOT in the new stacks list
    if [[ -d "$COMPOSE_DIR" ]]; then
        local existing_dir
        for existing_dir in "$COMPOSE_DIR"/*/; do
            [[ -d "$existing_dir" ]] || continue
            local dname
            dname=$(basename "$existing_dir")
            # Check if this directory is in the new stacks list
            local found=false
            for sname in $docker_stacks_str; do
                [[ "$sname" == "$dname" ]] && { found=true; break; }
            done
            if [[ "$found" == "false" ]]; then
                # Check if it's a placeholder (only has template compose)
                local service_count
                service_count=$(grep -c "container_name:" "$existing_dir/docker-compose.yml" 2>/dev/null) || service_count=0
                if [[ "$service_count" -eq 0 ]]; then
                    rm -rf "$existing_dir"
                    [[ -n "$removed_list" ]] && removed_list+=","
                    removed_list+="\"$(_api_json_escape "$dname")\""
                else
                    [[ -n "$warned_list" ]] && warned_list+=","
                    warned_list+="\"$(_api_json_escape "$dname")\""
                fi
            fi
        done
    fi

    _api_success "{\"success\": true, \"stacks_created\": [$created_list], \"stacks_removed\": [$removed_list], \"stacks_warned\": [$warned_list], \"env_updated\": $env_updated}"
}

# POST /setup/complete — Requires auth, only when not initialized.
# Creates the setup-complete marker file.
handle_setup_complete() {
    _api_require_setup_mode || return
    _api_init_auth_dir
    touch "$SETUP_COMPLETE_MARKER"
    _api_success '{"initialized": true, "message": "Setup complete"}'
}

# =============================================================================
# STACK MANAGEMENT ENDPOINTS (admin-only, work post-setup too)
# =============================================================================

# POST /stacks/rename — Rename a stack directory
handle_stack_rename() {
    local body="$1"

    if ! _api_check_admin; then
        _api_error 403 "Admin access required"
        return
    fi

    local old_name new_name
    if command -v jq >/dev/null 2>&1; then
        old_name=$(echo "$body" | jq -r '.old_name // empty' 2>/dev/null)
        new_name=$(echo "$body" | jq -r '.new_name // empty' 2>/dev/null)
    else
        old_name=$(echo "$body" | sed -n 's/.*"old_name" *: *"\([^"]*\)".*/\1/p')
        new_name=$(echo "$body" | sed -n 's/.*"new_name" *: *"\([^"]*\)".*/\1/p')
    fi

    if [[ -z "$old_name" ]] || [[ -z "$new_name" ]]; then
        _api_error 400 "Missing required fields: old_name and new_name"
        return
    fi

    _api_validate_stack_name "$old_name" || return
    _api_validate_stack_name "$new_name" || return

    local old_dir="$COMPOSE_DIR/$old_name"
    local new_dir="$COMPOSE_DIR/$new_name"

    if [[ ! -d "$old_dir" ]]; then
        _api_error 404 "Stack not found: $old_name"
        return
    fi
    if [[ -d "$new_dir" ]]; then
        _api_error 409 "Stack already exists: $new_name"
        return
    fi

    # Check no running containers
    local running
    running=$($DOCKER_COMPOSE_CMD -f "$old_dir/docker-compose.yml" ps -q 2>/dev/null | wc -l)
    if [[ "$running" -gt 0 ]]; then
        _api_error 409 "Cannot rename stack with running containers. Stop the stack first."
        return
    fi

    mv "$old_dir" "$new_dir"

    # Update DOCKER_STACKS in .env
    if [[ -f "$BASE_DIR/.env" ]]; then
        sed -i "s|$old_name|$new_name|g" "$BASE_DIR/.env"
    fi

    _api_success "{\"success\": true, \"old_name\": \"$(_api_json_escape "$old_name")\", \"new_name\": \"$(_api_json_escape "$new_name")\"}"
}

# POST /stacks/reorder — Set stack startup order
handle_stack_reorder() {
    local body="$1"

    if ! _api_check_admin; then
        _api_error 403 "Admin access required"
        return
    fi

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for this operation"
        return
    fi

    local stacks_str
    stacks_str=$(echo "$body" | jq -r '.stacks // empty' 2>/dev/null)
    if [[ -z "$stacks_str" ]] || [[ "$stacks_str" == "null" ]]; then
        _api_error 400 "Missing required field: stacks"
        return
    fi

    # Validate all names and verify directories exist
    local ordered_str=""
    local sname
    while IFS= read -r sname; do
        [[ -z "$sname" ]] && continue
        if [[ ! "$sname" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
            _api_error 400 "Invalid stack name: $sname"
            return
        fi
        if [[ ! -d "$COMPOSE_DIR/$sname" ]]; then
            _api_error 404 "Stack directory not found: $sname"
            return
        fi
        [[ -n "$ordered_str" ]] && ordered_str+=" "
        ordered_str+="$sname"
    done < <(echo "$stacks_str" | jq -r '.[]' 2>/dev/null)

    # Write DOCKER_STACKS to .env
    if [[ -f "$BASE_DIR/.env" ]]; then
        if grep -q "^DOCKER_STACKS=" "$BASE_DIR/.env"; then
            sed -i "s|^DOCKER_STACKS=.*|DOCKER_STACKS=\"${ordered_str}\"|" "$BASE_DIR/.env"
        else
            printf '\n\n# ─── Stack Configuration ─────────────────────────────────────────────────────\nDOCKER_STACKS="%s"\n' "${ordered_str}" >> "$BASE_DIR/.env"
        fi
    fi

    # Build response array
    local order_json="["
    local ofirst=true
    for sname in $ordered_str; do
        [[ "$ofirst" == "true" ]] && ofirst=false || order_json+=","
        order_json+="\"$(_api_json_escape "$sname")\""
    done
    order_json+="]"

    _api_success "{\"success\": true, \"order\": $order_json}"
}

# =============================================================================
# FEATURE: METRICS HISTORY & SUMMARY
# =============================================================================

# Helper: parse time range to epoch cutoff
_api_range_to_cutoff() {
    local range="$1"
    local now
    now=$(date +%s)
    case "$range" in
        1h)  echo $((now - 3600)) ;;
        6h)  echo $((now - 21600)) ;;
        24h) echo $((now - 86400)) ;;
        7d)  echo $((now - 604800)) ;;
        *)   echo $((now - 3600)) ;;
    esac
}

# GET /metrics/history?range=1h|6h|24h|7d
# Read JSONL metrics files, filter by time range, return as JSON array
handle_metrics_history() {
    local range="${QUERY_PARAMS[range]:-1h}"
    local cutoff
    cutoff=$(_api_range_to_cutoff "$range")

    local metrics_dir="$BASE_DIR/.data/metrics"
    if [[ ! -d "$metrics_dir" ]]; then
        _api_success "{\"range\": \"$(_api_json_escape "$range")\", \"data\": [], \"count\": 0}"
        return
    fi

    local -a points=()
    local now
    now=$(date +%s)

    # Determine which date-stamped files to read based on range
    local days_back=1
    case "$range" in
        6h)  days_back=1 ;;
        24h) days_back=2 ;;
        7d)  days_back=8 ;;
    esac

    local i
    for (( i=0; i<days_back; i++ )); do
        local date_str
        date_str=$(date -d "-${i} days" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
        local mfile="$metrics_dir/metrics-${date_str}.jsonl"
        [[ -f "$mfile" ]] || continue

        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local ts_val
            ts_val=$(printf '%s' "$line" | grep -oP '"ts":\K[0-9]+' 2>/dev/null || echo 0)
            [[ $ts_val -ge $cutoff ]] && points+=("$line")
        done < "$mfile"
    done

    local json
    if [[ ${#points[@]} -eq 0 ]]; then
        json="[]"
    else
        json=$(printf '%s,' "${points[@]}")
        json="[${json%,}]"
    fi

    _api_success "{\"range\": \"$(_api_json_escape "$range")\", \"data\": $json, \"count\": ${#points[@]}}"
}

# GET /metrics/summary?range=1h|6h|24h|7d
# Compute avg/min/max for cpu, mem from metrics history
handle_metrics_summary() {
    local range="${QUERY_PARAMS[range]:-1h}"
    local cutoff
    cutoff=$(_api_range_to_cutoff "$range")

    local metrics_dir="$BASE_DIR/.data/metrics"
    if [[ ! -d "$metrics_dir" ]]; then
        _api_success "{\"range\": \"$(_api_json_escape "$range")\", \"samples\": 0, \"cpu\": {\"avg\": 0, \"min\": 0, \"max\": 0}, \"mem\": {\"avg\": 0, \"min\": 0, \"max\": 0}}"
        return
    fi

    local days_back=1
    case "$range" in
        6h)  days_back=1 ;;
        24h) days_back=2 ;;
        7d)  days_back=8 ;;
    esac

    # Collect all matching lines into a temp file for awk processing
    local tmpfile
    tmpfile=$(mktemp)

    local i
    for (( i=0; i<days_back; i++ )); do
        local date_str
        date_str=$(date -d "-${i} days" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
        local mfile="$metrics_dir/metrics-${date_str}.jsonl"
        [[ -f "$mfile" ]] || continue

        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local ts_val
            ts_val=$(printf '%s' "$line" | grep -oP '"ts":\K[0-9]+' 2>/dev/null || echo 0)
            [[ $ts_val -ge $cutoff ]] && echo "$line" >> "$tmpfile"
        done < "$mfile"
    done

    if [[ ! -s "$tmpfile" ]]; then
        rm -f "$tmpfile"
        _api_success "{\"range\": \"$(_api_json_escape "$range")\", \"samples\": 0, \"cpu\": {\"avg\": 0, \"min\": 0, \"max\": 0}, \"mem\": {\"avg\": 0, \"min\": 0, \"max\": 0}}"
        return
    fi

    # Use awk to extract cpu and mem values and compute stats
    local stats
    stats=$(awk '
    BEGIN { cpu_sum=0; cpu_min=999999; cpu_max=0; mem_sum=0; mem_min=999999; mem_max=0; n=0 }
    {
        cpu=0; mem=0
        if (match($0, /"cpu":([0-9.]+)/, a)) cpu=a[1]
        if (match($0, /"mem":([0-9.]+)/, a)) mem=a[1]
        cpu_sum+=cpu; mem_sum+=mem; n++
        if (cpu<cpu_min) cpu_min=cpu; if (cpu>cpu_max) cpu_max=cpu
        if (mem<mem_min) mem_min=mem; if (mem>mem_max) mem_max=mem
    }
    END {
        if (n==0) { print "0 0 0 0 0 0 0 0"; exit }
        printf "%.1f %.1f %.1f %.1f %.1f %.1f %d %d\n", cpu_sum/n, cpu_min, cpu_max, mem_sum/n, mem_min, mem_max, n, n
    }' "$tmpfile" 2>/dev/null)

    rm -f "$tmpfile"

    local cpu_avg cpu_min cpu_max mem_avg mem_min mem_max samples _
    read -r cpu_avg cpu_min cpu_max mem_avg mem_min mem_max samples _ <<< "$stats"
    [[ -z "$samples" ]] && samples=0

    _api_success "{\"range\": \"$(_api_json_escape "$range")\", \"samples\": $samples, \"cpu\": {\"avg\": $cpu_avg, \"min\": $cpu_min, \"max\": $cpu_max}, \"mem\": {\"avg\": $mem_avg, \"min\": $mem_min, \"max\": $mem_max}}"
}

# =============================================================================
# FEATURE: ROLLBACK MANAGEMENT
# =============================================================================

# GET /rollback/<stack>/snapshots
# List all rollback snapshots for a stack
handle_rollback_snapshots() {
    local stack="$1"
    local snap_dir="$BASE_DIR/.data/rollback/$stack"

    if [[ ! -d "$snap_dir" ]]; then
        _api_success "{\"stack\": \"$(_api_json_escape "$stack")\", \"snapshots\": [], \"count\": 0}"
        return
    fi

    local -a entries=()
    local dir
    for dir in "$snap_dir"/*/; do
        [[ -d "$dir" ]] || continue
        local ts
        ts=$(basename "$dir")
        local meta_file="$dir/metadata.json"

        if [[ -f "$meta_file" ]]; then
            local meta
            meta=$(cat "$meta_file" 2>/dev/null)
            entries+=("{\"timestamp\": \"$(_api_json_escape "$ts")\", \"metadata\": $meta}")
        else
            local has_compose="false" has_env="false" has_images="false"
            [[ -f "$dir/docker-compose.yml" ]] && has_compose="true"
            [[ -f "$dir/.env" ]] && has_env="true"
            [[ -f "$dir/images.json" ]] && has_images="true"
            entries+=("{\"timestamp\": \"$(_api_json_escape "$ts")\", \"has_compose\": $has_compose, \"has_env\": $has_env, \"has_images\": $has_images}")
        fi
    done

    local json
    if [[ ${#entries[@]} -eq 0 ]]; then
        json="[]"
    else
        json=$(printf '%s,' "${entries[@]}")
        json="[${json%,}]"
    fi

    _api_success "{\"stack\": \"$(_api_json_escape "$stack")\", \"snapshots\": $json, \"count\": ${#entries[@]}}"
}

# GET /rollback/<stack>/snapshots/<timestamp>
# Return metadata.json content for a specific snapshot
handle_rollback_snapshot_detail() {
    local stack="$1"
    local timestamp="$2"
    local snap_dir="$BASE_DIR/.data/rollback/$stack/$timestamp"

    if [[ ! -d "$snap_dir" ]]; then
        _api_error 404 "Snapshot not found: $stack/$timestamp"
        return
    fi

    local meta="{}"
    [[ -f "$snap_dir/metadata.json" ]] && meta=$(cat "$snap_dir/metadata.json" 2>/dev/null)

    local compose_content=""
    if [[ -f "$snap_dir/docker-compose.yml" ]]; then
        compose_content=$(_api_json_escape "$(cat "$snap_dir/docker-compose.yml" 2>/dev/null)")
    fi

    local env_content=""
    if [[ -f "$snap_dir/.env" ]]; then
        env_content=$(_api_json_escape "$(cat "$snap_dir/.env" 2>/dev/null)")
    fi

    local images="[]"
    [[ -f "$snap_dir/images.json" ]] && images=$(cat "$snap_dir/images.json" 2>/dev/null)

    _api_success "{\"stack\": \"$(_api_json_escape "$stack")\", \"timestamp\": \"$(_api_json_escape "$timestamp")\", \"metadata\": $meta, \"compose\": \"$compose_content\", \"env\": \"$env_content\", \"images\": $images}"
}

# POST /rollback/<stack>/restore — body: {"timestamp": "..."}
# Restore a snapshot: copy files back, pull images, restart stack
handle_rollback_restore() {
    local stack="$1"
    local body="$2"

    local timestamp
    if command -v jq >/dev/null 2>&1; then
        timestamp=$(echo "$body" | jq -r '.timestamp // empty' 2>/dev/null)
    else
        timestamp=$(echo "$body" | sed -n 's/.*"timestamp" *: *"\([^"]*\)".*/\1/p')
    fi

    if [[ -z "$timestamp" ]]; then
        _api_error 400 "Missing required field: timestamp"
        return
    fi

    # Validate timestamp format (prevent path traversal)
    if [[ "$timestamp" == *"/"* ]] || [[ "$timestamp" == *".."* ]]; then
        _api_error 400 "Invalid timestamp format"
        return
    fi

    local snap_dir="$BASE_DIR/.data/rollback/$stack/$timestamp"
    local stack_dir="$COMPOSE_DIR/$stack"

    if [[ ! -d "$snap_dir" ]]; then
        _api_error 404 "Snapshot not found: $stack/$timestamp"
        return
    fi

    if [[ ! -d "$stack_dir" ]]; then
        _api_error 404 "Stack directory not found: $stack"
        return
    fi

    # Stop the stack first
    local compose_file="$stack_dir/docker-compose.yml"
    local env_file="$stack_dir/.env"
    local -a compose_args=(-f "$compose_file")
    [[ -f "$env_file" ]] && compose_args+=(--env-file "$env_file")
    $DOCKER_COMPOSE_CMD "${compose_args[@]}" down --remove-orphans 2>/dev/null || true

    # Copy snapshot files back
    [[ -f "$snap_dir/docker-compose.yml" ]] && cp "$snap_dir/docker-compose.yml" "$stack_dir/docker-compose.yml"
    [[ -f "$snap_dir/.env" ]] && cp "$snap_dir/.env" "$stack_dir/.env"

    # Pull images listed in snapshot
    local pull_output=""
    if [[ -f "$snap_dir/images.json" ]] && command -v jq >/dev/null 2>&1; then
        local img
        while IFS= read -r img; do
            [[ -z "$img" ]] && continue
            docker pull "$img" 2>&1 || true
        done < <(jq -r '.[]' "$snap_dir/images.json" 2>/dev/null)
    fi

    # Restart the stack with restored files
    compose_args=(-f "$stack_dir/docker-compose.yml")
    [[ -f "$stack_dir/.env" ]] && compose_args+=(--env-file "$stack_dir/.env")
    local start_output
    start_output=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" up -d 2>&1) || true

    _api_success "{\"success\": true, \"stack\": \"$(_api_json_escape "$stack")\", \"restored_from\": \"$(_api_json_escape "$timestamp")\", \"message\": \"Stack restored and restarted\"}"
}

# GET /rollback/<stack>/diff/<timestamp>
# Diff current compose/env against snapshot
handle_rollback_diff() {
    local stack="$1"
    local timestamp="$2"
    local snap_dir="$BASE_DIR/.data/rollback/$stack/$timestamp"
    local stack_dir="$COMPOSE_DIR/$stack"

    if [[ ! -d "$snap_dir" ]]; then
        _api_error 404 "Snapshot not found: $stack/$timestamp"
        return
    fi

    if [[ ! -d "$stack_dir" ]]; then
        _api_error 404 "Stack directory not found: $stack"
        return
    fi

    local compose_diff="" env_diff=""

    if [[ -f "$snap_dir/docker-compose.yml" ]] && [[ -f "$stack_dir/docker-compose.yml" ]]; then
        compose_diff=$(_api_json_escape "$(diff -u "$snap_dir/docker-compose.yml" "$stack_dir/docker-compose.yml" 2>/dev/null || true)")
    fi

    if [[ -f "$snap_dir/.env" ]] && [[ -f "$stack_dir/.env" ]]; then
        env_diff=$(_api_json_escape "$(diff -u "$snap_dir/.env" "$stack_dir/.env" 2>/dev/null || true)")
    fi

    local compose_changed="false" env_changed="false"
    [[ -n "$compose_diff" ]] && compose_changed="true"
    [[ -n "$env_diff" ]] && env_changed="true"

    _api_success "{\"stack\": \"$(_api_json_escape "$stack")\", \"snapshot\": \"$(_api_json_escape "$timestamp")\", \"compose_changed\": $compose_changed, \"env_changed\": $env_changed, \"compose_diff\": \"$compose_diff\", \"env_diff\": \"$env_diff\"}"
}

# =============================================================================
# FEATURE: SECRETS MANAGEMENT
# =============================================================================

# GET /secrets — List secret key names (never values)
handle_secrets_list() {
    local secrets_dir="$BASE_DIR/.secrets"

    if [[ ! -d "$secrets_dir" ]]; then
        _api_success "{\"secrets\": [], \"count\": 0}"
        return
    fi

    local -a entries=()
    local f
    for f in "$secrets_dir"/*.enc; do
        [[ -f "$f" ]] || continue
        local key
        key=$(basename "$f" .enc)
        local modified
        modified=$(stat -c '%Y' "$f" 2>/dev/null || echo 0)
        local modified_ts
        modified_ts=$(date -u -d "@$modified" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "unknown")
        local size
        size=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
        entries+=("{\"key\": \"$(_api_json_escape "$key")\", \"modified\": \"$modified_ts\", \"size\": $size}")
    done

    local json
    if [[ ${#entries[@]} -eq 0 ]]; then
        json="[]"
    else
        json=$(printf '%s,' "${entries[@]}")
        json="[${json%,}]"
    fi

    _api_success "{\"secrets\": $json, \"count\": ${#entries[@]}}"
}

# POST /secrets — body: {"key": "...", "value": "..."}
# Encrypt and store a secret value
handle_secret_set() {
    local body="$1"

    local key value
    if command -v jq >/dev/null 2>&1; then
        key=$(echo "$body" | jq -r '.key // empty' 2>/dev/null)
        value=$(echo "$body" | jq -r '.value // empty' 2>/dev/null)
    else
        key=$(echo "$body" | sed -n 's/.*"key" *: *"\([^"]*\)".*/\1/p')
        value=$(echo "$body" | sed -n 's/.*"value" *: *"\([^"]*\)".*/\1/p')
    fi

    if [[ -z "$key" ]] || [[ -z "$value" ]]; then
        _api_error 400 "Missing required fields: key and value"
        return
    fi

    # Validate key name: alphanumeric, hyphens, underscores only
    if [[ ! "$key" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        _api_error 400 "Invalid key name. Use only alphanumeric characters, hyphens, and underscores."
        return
    fi

    local secrets_dir="$BASE_DIR/.secrets"
    mkdir -p "$secrets_dir"

    local master_key_file="$secrets_dir/.master-key"
    if [[ ! -f "$master_key_file" ]]; then
        # Generate master key on first use
        openssl rand -hex 32 > "$master_key_file"
        chmod 600 "$master_key_file"
    fi

    local master_key
    master_key=$(cat "$master_key_file" 2>/dev/null)

    local enc_file="$secrets_dir/${key}.enc"
    if printf '%s' "$value" | openssl enc -aes-256-cbc -salt -pbkdf2 -pass "pass:${master_key}" -out "$enc_file" 2>/dev/null; then
        chmod 600 "$enc_file"
        _api_success "{\"success\": true, \"key\": \"$(_api_json_escape "$key")\", \"message\": \"Secret stored successfully\"}"
    else
        _api_error 500 "Failed to encrypt secret"
    fi
}

# DELETE /secrets/<key> — Securely delete a secret
handle_secret_delete() {
    local key="$1"

    # Validate key name
    if [[ ! "$key" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        _api_error 400 "Invalid key name"
        return
    fi

    local enc_file="$BASE_DIR/.secrets/${key}.enc"

    if [[ ! -f "$enc_file" ]]; then
        _api_error 404 "Secret not found: $key"
        return
    fi

    # Securely overwrite before deleting (if shred is available)
    if command -v shred >/dev/null 2>&1; then
        shred -u "$enc_file" 2>/dev/null
    else
        dd if=/dev/urandom of="$enc_file" bs=$(stat -c '%s' "$enc_file" 2>/dev/null || echo 64) count=1 2>/dev/null
        rm -f "$enc_file"
    fi

    _api_success "{\"success\": true, \"key\": \"$(_api_json_escape "$key")\", \"message\": \"Secret deleted securely\"}"
}

# GET /secrets/<key>/exists — Check if a secret exists (boolean)
handle_secret_exists() {
    local key="$1"

    # Validate key name
    if [[ ! "$key" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        _api_error 400 "Invalid key name"
        return
    fi

    local enc_file="$BASE_DIR/.secrets/${key}.enc"
    local exists="false"
    [[ -f "$enc_file" ]] && exists="true"

    _api_success "{\"key\": \"$(_api_json_escape "$key")\", \"exists\": $exists}"
}

# =============================================================================
# FEATURE: SCHEDULE MANAGEMENT
# =============================================================================

# GET /schedules — Return schedules.json content
handle_schedules_list() {
    local sched_file="$BASE_DIR/.data/schedules/schedules.json"

    if [[ ! -f "$sched_file" ]]; then
        _api_success "{\"schedules\": [], \"count\": 0}"
        return
    fi

    local content
    content=$(cat "$sched_file" 2>/dev/null)

    # Validate JSON content
    if command -v jq >/dev/null 2>&1; then
        if ! echo "$content" | jq '.' >/dev/null 2>&1; then
            _api_error 500 "Invalid schedules data file"
            return
        fi
        local count
        count=$(echo "$content" | jq 'length' 2>/dev/null || echo 0)
        _api_success "{\"schedules\": $content, \"count\": $count}"
    else
        _api_success "{\"schedules\": $content, \"count\": 0}"
    fi
}

# POST /schedules — body: schedule entry JSON
# Add a new schedule entry
handle_schedule_create() {
    local body="$1"
    local sched_dir="$BASE_DIR/.data/schedules"
    local sched_file="$sched_dir/schedules.json"
    mkdir -p "$sched_dir"

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for schedule management"
        return
    fi

    # Validate required fields
    local name action cron
    name=$(echo "$body" | jq -r '.name // empty' 2>/dev/null)
    action=$(echo "$body" | jq -r '.action // empty' 2>/dev/null)
    cron=$(echo "$body" | jq -r '.cron // empty' 2>/dev/null)

    if [[ -z "$name" ]] || [[ -z "$action" ]] || [[ -z "$cron" ]]; then
        _api_error 400 "Missing required fields: name, action, and cron"
        return
    fi

    # Generate unique ID
    local id
    id="sched_$(date +%s)_$$"

    # Build new entry with id, enabled=true, and created timestamp
    local new_entry
    new_entry=$(echo "$body" | jq --arg id "$id" --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        '. + {id: $id, enabled: true, created: $ts}' 2>/dev/null)

    # Append to schedules array
    local current="[]"
    [[ -f "$sched_file" ]] && current=$(cat "$sched_file" 2>/dev/null)
    echo "$current" | jq --argjson entry "$new_entry" '. + [$entry]' > "$sched_file" 2>/dev/null

    _api_success "{\"success\": true, \"schedule\": $new_entry}"
}

# POST /schedules/<id>/update — body: updated fields
# Update an existing schedule
handle_schedule_update() {
    local sched_id="$1"
    local body="$2"
    local sched_file="$BASE_DIR/.data/schedules/schedules.json"

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for schedule management"
        return
    fi

    if [[ ! -f "$sched_file" ]]; then
        _api_error 404 "No schedules found"
        return
    fi

    # Check if schedule exists
    local exists
    exists=$(jq --arg id "$sched_id" '[.[] | select(.id == $id)] | length' "$sched_file" 2>/dev/null)
    if [[ "$exists" -eq 0 ]]; then
        _api_error 404 "Schedule not found: $sched_id"
        return
    fi

    # Merge updates into existing entry (preserve id)
    local updated
    updated=$(jq --arg id "$sched_id" --argjson updates "$body" \
        '[.[] | if .id == $id then . * $updates | .id = $id else . end]' \
        "$sched_file" 2>/dev/null)

    echo "$updated" > "$sched_file"

    local entry
    entry=$(echo "$updated" | jq --arg id "$sched_id" '.[] | select(.id == $id)' 2>/dev/null)

    _api_success "{\"success\": true, \"schedule\": $entry}"
}

# DELETE /schedules/<id> — Remove a schedule
handle_schedule_delete() {
    local sched_id="$1"
    local sched_file="$BASE_DIR/.data/schedules/schedules.json"

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for schedule management"
        return
    fi

    if [[ ! -f "$sched_file" ]]; then
        _api_error 404 "No schedules found"
        return
    fi

    local exists
    exists=$(jq --arg id "$sched_id" '[.[] | select(.id == $id)] | length' "$sched_file" 2>/dev/null)
    if [[ "$exists" -eq 0 ]]; then
        _api_error 404 "Schedule not found: $sched_id"
        return
    fi

    jq --arg id "$sched_id" '[.[] | select(.id != $id)]' "$sched_file" > "${sched_file}.tmp" && \
        mv "${sched_file}.tmp" "$sched_file"

    _api_success "{\"success\": true, \"deleted\": \"$(_api_json_escape "$sched_id")\"}"
}

# POST /schedules/<id>/toggle — Enable/disable a schedule
handle_schedule_toggle() {
    local sched_id="$1"
    local sched_file="$BASE_DIR/.data/schedules/schedules.json"

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for schedule management"
        return
    fi

    if [[ ! -f "$sched_file" ]]; then
        _api_error 404 "No schedules found"
        return
    fi

    local exists
    exists=$(jq --arg id "$sched_id" '[.[] | select(.id == $id)] | length' "$sched_file" 2>/dev/null)
    if [[ "$exists" -eq 0 ]]; then
        _api_error 404 "Schedule not found: $sched_id"
        return
    fi

    # Toggle the enabled field
    jq --arg id "$sched_id" \
        '[.[] | if .id == $id then .enabled = (.enabled | not) else . end]' \
        "$sched_file" > "${sched_file}.tmp" && mv "${sched_file}.tmp" "$sched_file"

    local new_state
    new_state=$(jq -r --arg id "$sched_id" '.[] | select(.id == $id) | .enabled' "$sched_file" 2>/dev/null)

    _api_success "{\"success\": true, \"id\": \"$(_api_json_escape "$sched_id")\", \"enabled\": $new_state}"
}

# GET /schedules/<id>/history — Return execution history filtered by schedule id
handle_schedule_history() {
    local sched_id="$1"
    local history_file="$BASE_DIR/.data/schedules/history.jsonl"

    if [[ ! -f "$history_file" ]]; then
        _api_success "{\"schedule_id\": \"$(_api_json_escape "$sched_id")\", \"history\": [], \"count\": 0}"
        return
    fi

    local -a entries=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local line_id
        if command -v jq >/dev/null 2>&1; then
            line_id=$(printf '%s' "$line" | jq -r '.schedule_id // .id // empty' 2>/dev/null)
        else
            line_id=$(printf '%s' "$line" | grep -oP '"schedule_id" *: *"\K[^"]+' 2>/dev/null || \
                      printf '%s' "$line" | grep -oP '"id" *: *"\K[^"]+' 2>/dev/null || echo "")
        fi
        [[ "$line_id" == "$sched_id" ]] && entries+=("$line")
    done < "$history_file"

    local json
    if [[ ${#entries[@]} -eq 0 ]]; then
        json="[]"
    else
        json=$(printf '%s,' "${entries[@]}")
        json="[${json%,}]"
    fi

    _api_success "{\"schedule_id\": \"$(_api_json_escape "$sched_id")\", \"history\": $json, \"count\": ${#entries[@]}}"
}

# =============================================================================
# FEATURE: HEALTH SCORING
# =============================================================================

# GET /health/score — Compute system-wide health score (0-100)
# Factors: stacks (container health), resources (CPU/mem), images (freshness), uptime
handle_health_score() {
    local now
    now=$(date +%s)

    # ── Factor 1: Stack/container health (40% weight) ──
    local total_containers=0 healthy_count=0 unhealthy_count=0
    while IFS= read -r cid; do
        [[ -z "$cid" ]] && continue
        total_containers=$((total_containers + 1))
        local state health
        state=$(docker inspect --format='{{.State.Status}}' "$cid" 2>/dev/null)
        health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null)

        if [[ "$state" == "running" ]]; then
            if [[ "$health" == "unhealthy" ]]; then
                unhealthy_count=$((unhealthy_count + 1))
            else
                healthy_count=$((healthy_count + 1))
            fi
        fi
    done < <(docker ps -a -q 2>/dev/null)

    local stack_score=100
    if [[ $total_containers -gt 0 ]]; then
        stack_score=$(awk "BEGIN { printf \"%d\", ($healthy_count / $total_containers) * 100 }")
    fi

    # ── Factor 2: Resource usage (30% weight) ──
    local load1
    read -r load1 _ < /proc/loadavg 2>/dev/null || load1=0
    local cpu_count
    cpu_count=$(nproc 2>/dev/null || echo 1)
    local cpu_pct
    cpu_pct=$(awk "BEGIN { v = ($load1 / $cpu_count) * 100; if (v > 100) v = 100; printf \"%.0f\", v }")

    local mem_total=0 mem_available=0
    while IFS=':' read -r key val; do
        val="${val// /}"; val="${val%%kB*}"
        case "$key" in
            MemTotal)     mem_total=$((val / 1024)) ;;
            MemAvailable) mem_available=$((val / 1024)) ;;
        esac
    done < /proc/meminfo 2>/dev/null
    local mem_pct=0
    [[ $mem_total -gt 0 ]] && mem_pct=$(awk "BEGIN { printf \"%.0f\", (($mem_total - $mem_available) / $mem_total) * 100 }")

    # Resource score: 100 when usage is low, decreases as usage rises
    local resource_score
    resource_score=$(awk "BEGIN { s = 100 - (($cpu_pct + $mem_pct) / 2); if (s < 0) s = 0; printf \"%d\", s }")

    # ── Factor 3: Image freshness (15% weight) ──
    local total_images=0 stale_images=0
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == "REPOSITORY"* ]] && continue
        local repo tag _rest
        read -r repo tag _rest <<< "$line"
        [[ "$repo" == "<none>" ]] && continue
        total_images=$((total_images + 1))

        local full_image="${repo}:${tag}"
        local created_ts
        created_ts=$(docker inspect --format '{{.Created}}' "$full_image" 2>/dev/null | head -1)
        if [[ -n "$created_ts" ]]; then
            local created_epoch
            created_epoch=$(date -d "$created_ts" +%s 2>/dev/null || echo 0)
            local age_days=$(( (now - created_epoch) / 86400 ))
            [[ $age_days -gt 30 ]] && stale_images=$((stale_images + 1))
        fi
    done < <(docker images --format "{{.Repository}}\t{{.Tag}}\t{{.Size}}" 2>/dev/null)

    local image_score=100
    if [[ $total_images -gt 0 ]]; then
        image_score=$(awk "BEGIN { printf \"%d\", (1 - ($stale_images / $total_images)) * 100 }")
    fi

    # ── Factor 4: System uptime (15% weight) ──
    local uptime_seconds
    uptime_seconds=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 0)
    # Score: 100 if uptime > 7 days, scales linearly below that
    local uptime_score
    uptime_score=$(awk "BEGIN { s = ($uptime_seconds / 604800) * 100; if (s > 100) s = 100; printf \"%d\", s }")

    # ── Weighted total ──
    local total_score
    total_score=$(awk "BEGIN { printf \"%d\", ($stack_score * 0.4) + ($resource_score * 0.3) + ($image_score * 0.15) + ($uptime_score * 0.15) }")

    # Determine grade
    local grade="A"
    if [[ $total_score -ge 90 ]]; then grade="A"
    elif [[ $total_score -ge 80 ]]; then grade="B"
    elif [[ $total_score -ge 70 ]]; then grade="C"
    elif [[ $total_score -ge 60 ]]; then grade="D"
    else grade="F"
    fi

    _api_success "{\"score\": $total_score, \"grade\": \"$grade\", \"factors\": {\"stacks\": {\"score\": $stack_score, \"weight\": 0.4, \"healthy\": $healthy_count, \"unhealthy\": $unhealthy_count, \"total\": $total_containers}, \"resources\": {\"score\": $resource_score, \"weight\": 0.3, \"cpu_pct\": $cpu_pct, \"mem_pct\": $mem_pct}, \"images\": {\"score\": $image_score, \"weight\": 0.15, \"total\": $total_images, \"stale\": $stale_images}, \"uptime\": {\"score\": $uptime_score, \"weight\": 0.15, \"seconds\": $uptime_seconds}}, \"timestamp\": \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\"}"
}

# GET /health/score/<stack> — Compute health score for a specific stack
handle_health_score_stack() {
    local stack="$1"
    local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
    local env_file="$COMPOSE_DIR/$stack/.env"

    if [[ ! -f "$compose_file" ]]; then
        _api_error 404 "Stack not found: $stack"
        return
    fi

    local -a compose_args=(-f "$compose_file")
    [[ -f "$env_file" ]] && compose_args+=(--env-file "$env_file")

    # Get container IDs for this stack
    local -a container_ids=()
    while IFS= read -r cid; do
        [[ -n "$cid" ]] && container_ids+=("$cid")
    done < <($DOCKER_COMPOSE_CMD "${compose_args[@]}" ps -q 2>/dev/null)

    local total=${#container_ids[@]}
    local running=0 healthy=0 unhealthy=0 stopped=0

    local cid
    for cid in "${container_ids[@]}"; do
        local state health
        state=$(docker inspect --format='{{.State.Status}}' "$cid" 2>/dev/null)
        health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null)

        if [[ "$state" == "running" ]]; then
            running=$((running + 1))
            if [[ "$health" == "unhealthy" ]]; then
                unhealthy=$((unhealthy + 1))
            else
                healthy=$((healthy + 1))
            fi
        else
            stopped=$((stopped + 1))
        fi
    done

    # Count expected services from compose file
    local expected_services
    expected_services=$(grep -c 'container_name:' "$compose_file" 2>/dev/null) || expected_services=0
    [[ $expected_services -eq 0 ]] && expected_services=$total

    # Score: penalize for unhealthy and stopped containers
    local score=100
    if [[ $expected_services -gt 0 ]]; then
        score=$(awk "BEGIN { s = ($healthy / $expected_services) * 100; if (s > 100) s = 100; printf \"%d\", s }")
    fi

    # Additional penalty for unhealthy containers
    if [[ $unhealthy -gt 0 ]]; then
        local penalty=$((unhealthy * 15))
        score=$((score - penalty))
        [[ $score -lt 0 ]] && score=0
    fi

    local grade="A"
    if [[ $score -ge 90 ]]; then grade="A"
    elif [[ $score -ge 80 ]]; then grade="B"
    elif [[ $score -ge 70 ]]; then grade="C"
    elif [[ $score -ge 60 ]]; then grade="D"
    else grade="F"
    fi

    _api_success "{\"stack\": \"$(_api_json_escape "$stack")\", \"score\": $score, \"grade\": \"$grade\", \"containers\": {\"total\": $total, \"running\": $running, \"healthy\": $healthy, \"unhealthy\": $unhealthy, \"stopped\": $stopped, \"expected\": $expected_services}, \"timestamp\": \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\"}"
}

# GET /health/score/history?range=1h|24h|7d
# Read health score history from metrics data
handle_health_score_history() {
    local range="${QUERY_PARAMS[range]:-24h}"
    local cutoff
    cutoff=$(_api_range_to_cutoff "$range")

    local metrics_dir="$BASE_DIR/.data/metrics"
    if [[ ! -d "$metrics_dir" ]]; then
        _api_success "{\"range\": \"$(_api_json_escape "$range")\", \"history\": [], \"count\": 0}"
        return
    fi

    local days_back=1
    case "$range" in
        1h)  days_back=1 ;;
        24h) days_back=2 ;;
        7d)  days_back=8 ;;
    esac

    local -a points=()
    local i
    for (( i=0; i<days_back; i++ )); do
        local date_str
        date_str=$(date -d "-${i} days" '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
        local mfile="$metrics_dir/metrics-${date_str}.jsonl"
        [[ -f "$mfile" ]] || continue

        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local ts_val
            ts_val=$(printf '%s' "$line" | grep -oP '"ts":\K[0-9]+' 2>/dev/null || echo 0)
            if [[ $ts_val -ge $cutoff ]]; then
                # Extract health_score field if present
                local hs
                hs=$(printf '%s' "$line" | grep -oP '"health_score":\K[0-9]+' 2>/dev/null || echo "")
                if [[ -n "$hs" ]]; then
                    points+=("{\"ts\": $ts_val, \"score\": $hs}")
                fi
            fi
        done < "$mfile"
    done

    local json
    if [[ ${#points[@]} -eq 0 ]]; then
        json="[]"
    else
        json=$(printf '%s,' "${points[@]}")
        json="[${json%,}]"
    fi

    _api_success "{\"range\": \"$(_api_json_escape "$range")\", \"history\": $json, \"count\": ${#points[@]}}"
}

# =============================================================================
# FEATURE: PLUGIN MANAGEMENT
# =============================================================================

# GET /plugins — Scan .plugins/ directory, return plugin manifest data
handle_plugins_list() {
    local plugins_dir="$BASE_DIR/.plugins"

    if [[ ! -d "$plugins_dir" ]]; then
        _api_success "{\"plugins\": [], \"count\": 0}"
        return
    fi

    local -a entries=()
    local dir
    for dir in "$plugins_dir"/*/; do
        [[ -d "$dir" ]] || continue
        local name
        name=$(basename "$dir")
        local manifest="$dir/plugin.json"

        # Scan templates directory
        local templates_json="["
        local tfirst=true
        if [[ -d "$dir/templates" ]]; then
            local tmpl_dir
            for tmpl_dir in "$dir/templates"/*/; do
                [[ -d "$tmpl_dir" ]] || continue
                [[ "$tfirst" == "true" ]] && tfirst=false || templates_json+=","
                templates_json+="\"$(basename "$tmpl_dir")\""
            done
        fi
        templates_json+="]"

        # Scan hooks directory
        local hooks_json="["
        local hfirst=true
        if [[ -d "$dir/hooks" ]]; then
            local hook_file
            for hook_file in "$dir/hooks"/*; do
                [[ -f "$hook_file" ]] || continue
                [[ "$hfirst" == "true" ]] && hfirst=false || hooks_json+=","
                hooks_json+="\"$(basename "$hook_file")\""
            done
        fi
        hooks_json+="]"

        # Check enabled state
        local enabled="true"
        [[ -f "$dir/.disabled" ]] && enabled="false"

        if [[ -f "$manifest" ]]; then
            local content
            content=$(cat "$manifest" 2>/dev/null)
            if command -v jq >/dev/null 2>&1; then
                content=$(echo "$content" | jq \
                    --arg name "$name" \
                    --argjson templates "$templates_json" \
                    --argjson hooks "$hooks_json" \
                    --argjson enabled "$enabled" \
                    '. + {dir_name: $name, templates: $templates, hooks: $hooks, enabled: $enabled}' 2>/dev/null || echo "$content")
            fi
            entries+=("$content")
        else
            entries+=("{\"dir_name\": \"$(_api_json_escape "$name")\", \"name\": \"$(_api_json_escape "$name")\", \"version\": \"unknown\", \"enabled\": $enabled, \"has_manifest\": false, \"templates\": $templates_json, \"hooks\": $hooks_json}")
        fi
    done

    local json
    if [[ ${#entries[@]} -eq 0 ]]; then
        json="[]"
    else
        json=$(printf '%s,' "${entries[@]}")
        json="[${json%,}]"
    fi

    _api_success "{\"plugins\": $json, \"count\": ${#entries[@]}}"
}

# POST /plugins/install — body: {"url": "..."}
# Git clone a plugin to .plugins/
handle_plugin_install() {
    local body="$1"

    local url
    if command -v jq >/dev/null 2>&1; then
        url=$(echo "$body" | jq -r '.url // empty' 2>/dev/null)
    else
        url=$(echo "$body" | sed -n 's/.*"url" *: *"\([^"]*\)".*/\1/p')
    fi

    if [[ -z "$url" ]]; then
        _api_error 400 "Missing required field: url"
        return
    fi

    # Validate URL format and SSRF protection
    _api_validate_url "$url" "Plugin URL" || return

    if ! command -v git >/dev/null 2>&1; then
        _api_error 500 "git is required for plugin installation"
        return
    fi

    local plugins_dir="$BASE_DIR/.plugins"
    mkdir -p "$plugins_dir"

    # Derive plugin name from URL
    local plugin_name
    plugin_name=$(basename "$url" .git)
    plugin_name="${plugin_name%.git}"

    if [[ -z "$plugin_name" ]] || [[ ! "$plugin_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        _api_error 400 "Cannot derive a valid plugin name from URL"
        return
    fi

    local target_dir="$plugins_dir/$plugin_name"
    if [[ -d "$target_dir" ]]; then
        _api_error 409 "Plugin already installed: $plugin_name"
        return
    fi

    local clone_output
    clone_output=$(git clone --depth 1 "$url" "$target_dir" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        rm -rf "$target_dir" 2>/dev/null
        _api_error 500 "Failed to clone plugin: $(_api_json_escape "$clone_output")"
        return
    fi

    # Read manifest if available and ensure disabled by default
    local manifest="{}"
    if [[ -f "$target_dir/plugin.json" ]]; then
        if command -v jq >/dev/null 2>&1; then
            jq '.enabled = false' "$target_dir/plugin.json" > "$target_dir/plugin.json.tmp" && mv "$target_dir/plugin.json.tmp" "$target_dir/plugin.json"
        fi
        manifest=$(cat "$target_dir/plugin.json" 2>/dev/null)
    fi

    _api_success "{\"success\": true, \"name\": \"$(_api_json_escape "$plugin_name")\", \"path\": \"$(_api_json_escape "$target_dir")\", \"manifest\": $manifest}"
}

# POST /plugins/scaffold — Create a plugin from inline definition (for bundled/featured plugins)
# Body: {"name": "...", "manifest": {...}, "hooks": {"pre-deploy": "#!/bin/bash\n..."}}
handle_plugin_scaffold() {
    local body="$1"

    local name
    if command -v jq >/dev/null 2>&1; then
        name=$(echo "$body" | jq -r '.name // empty' 2>/dev/null)
    else
        name=$(echo "$body" | sed -n 's/.*"name" *: *"\([^"]*\)".*/\1/p')
    fi

    if [[ -z "$name" ]]; then
        _api_error 400 "Missing required field: name"
        return
    fi

    # Validate name (prevent path traversal)
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        _api_error 400 "Invalid plugin name"
        return
    fi

    local plugins_dir="$BASE_DIR/.plugins"
    mkdir -p "$plugins_dir"

    local target_dir="$plugins_dir/$name"
    if [[ -d "$target_dir" ]]; then
        _api_error 409 "Plugin already installed: $name"
        return
    fi

    mkdir -p "$target_dir/hooks"

    # Write manifest (plugin.json)
    if command -v jq >/dev/null 2>&1; then
        local manifest
        manifest=$(echo "$body" | jq -r '.manifest // empty' 2>/dev/null)
        if [[ -n "$manifest" && "$manifest" != "null" ]]; then
            echo "$body" | jq '.manifest + {enabled: false}' > "$target_dir/plugin.json"
        else
            # Build minimal manifest
            local desc
            desc=$(echo "$body" | jq -r '.description // ""' 2>/dev/null)
            local version
            version=$(echo "$body" | jq -r '.version // "1.0.0"' 2>/dev/null)
            local author
            author=$(echo "$body" | jq -r '.author // "DCS Community"' 2>/dev/null)
            cat > "$target_dir/plugin.json" <<MANIFEST_EOF
{
  "name": "$name",
  "version": "$version",
  "description": "$desc",
  "author": "$author",
  "enabled": false
}
MANIFEST_EOF
        fi

        # Write hook scripts
        local hook_keys
        hook_keys=$(echo "$body" | jq -r '.hooks // {} | keys[]' 2>/dev/null)
        for hook_name in $hook_keys; do
            # Validate hook name
            if [[ ! "$hook_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                continue
            fi
            local hook_content
            hook_content=$(echo "$body" | jq -r ".hooks[\"$hook_name\"] // empty" 2>/dev/null)
            if [[ -n "$hook_content" ]]; then
                printf '%s' "$hook_content" > "$target_dir/hooks/$hook_name"
                chmod +x "$target_dir/hooks/$hook_name"
            fi
        done
    else
        # Fallback without jq — just create minimal manifest
        cat > "$target_dir/plugin.json" <<MANIFEST_EOF
{
  "name": "$name",
  "version": "1.0.0",
  "description": "",
  "author": "DCS Community",
  "enabled": false
}
MANIFEST_EOF
    fi

    # Read back manifest
    local final_manifest="{}"
    if [[ -f "$target_dir/plugin.json" ]]; then
        final_manifest=$(cat "$target_dir/plugin.json" 2>/dev/null)
    fi

    _api_success "{\"success\": true, \"name\": \"$(_api_json_escape "$name")\", \"path\": \"$(_api_json_escape "$target_dir")\", \"manifest\": $final_manifest}"
}

# DELETE /plugins/<name> — Remove plugin directory
handle_plugin_remove() {
    local name="$1"

    # Validate name (prevent path traversal)
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        _api_error 400 "Invalid plugin name"
        return
    fi

    local target_dir="$BASE_DIR/.plugins/$name"

    if [[ ! -d "$target_dir" ]]; then
        _api_error 404 "Plugin not found: $name"
        return
    fi

    rm -rf "$target_dir"

    _api_success "{\"success\": true, \"name\": \"$(_api_json_escape "$name")\", \"message\": \"Plugin removed\"}"
}

# POST /plugins/<name>/toggle — Enable/disable by writing to plugin.json
handle_plugin_toggle() {
    local name="$1"

    # Validate name
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        _api_error 400 "Invalid plugin name"
        return
    fi

    local target_dir="$BASE_DIR/.plugins/$name"
    local manifest="$target_dir/plugin.json"

    if [[ ! -d "$target_dir" ]]; then
        _api_error 404 "Plugin not found: $name"
        return
    fi

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for plugin management"
        return
    fi

    # Create manifest if missing
    if [[ ! -f "$manifest" ]]; then
        echo "{\"name\": \"$name\", \"enabled\": true}" > "$manifest"
    fi

    # Toggle the enabled field
    local current_state
    current_state=$(jq -r '.enabled // false' "$manifest" 2>/dev/null)

    local new_state="true"
    if [[ "$current_state" == "true" ]]; then
        new_state="false"
    fi
    jq ".enabled = $new_state" "$manifest" > "${manifest}.tmp" && mv "${manifest}.tmp" "$manifest"

    # Scan templates and hooks for full response
    local templates_json="["
    local tfirst=true
    if [[ -d "$target_dir/templates" ]]; then
        local tmpl_dir
        for tmpl_dir in "$target_dir/templates"/*/; do
            [[ -d "$tmpl_dir" ]] || continue
            [[ "$tfirst" == "true" ]] && tfirst=false || templates_json+=","
            templates_json+="\"$(basename "$tmpl_dir")\""
        done
    fi
    templates_json+="]"

    local hooks_json="["
    local hfirst=true
    if [[ -d "$target_dir/hooks" ]]; then
        local hook_file
        for hook_file in "$target_dir/hooks"/*; do
            [[ -f "$hook_file" ]] || continue
            [[ "$hfirst" == "true" ]] && hfirst=false || hooks_json+=","
            hooks_json+="\"$(basename "$hook_file")\""
        done
    fi
    hooks_json+="]"

    local version description author
    version=$(jq -r '.version // "1.0.0"' "$manifest" 2>/dev/null)
    description=$(jq -r '.description // ""' "$manifest" 2>/dev/null)
    author=$(jq -r '.author // ""' "$manifest" 2>/dev/null)

    _api_success "{\"name\": \"$(_api_json_escape "$name")\", \"version\": \"$(_api_json_escape "$version")\", \"description\": \"$(_api_json_escape "$description")\", \"author\": \"$(_api_json_escape "$author")\", \"enabled\": $new_state, \"templates\": $templates_json, \"hooks\": $hooks_json}"
}

# GET /plugins/:name/hooks — List all hooks with metadata
handle_plugin_hooks_list() {
    local plugin_name="$1"

    # Validate name
    if [[ ! "$plugin_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        _api_error 400 "Invalid plugin name"
        return
    fi

    local plugin_dir="$BASE_DIR/.plugins/$plugin_name"

    if [[ ! -d "$plugin_dir" ]]; then
        _api_error 404 "Plugin not found: $plugin_name"
        return
    fi

    local hooks_json="["
    local first=true
    local hooks_dir="$plugin_dir/hooks"

    if [[ -d "$hooks_dir" ]]; then
        for hook_file in "$hooks_dir"/*; do
            [[ -f "$hook_file" ]] || continue
            local hook_name
            hook_name=$(basename "$hook_file")
            local size
            size=$(stat -c%s "$hook_file" 2>/dev/null || echo "0")
            local executable="false"
            [[ -x "$hook_file" ]] && executable="true"
            local modified
            modified=$(stat -c%Y "$hook_file" 2>/dev/null || echo "0")
            local line_count
            line_count=$(wc -l < "$hook_file" 2>/dev/null || echo "0")

            $first || hooks_json+=","
            first=false
            hooks_json+="{\"name\":\"$(_api_json_escape "$hook_name")\",\"size\":$size,\"executable\":$executable,\"modified\":$modified,\"lines\":$line_count}"
        done
    fi
    hooks_json+="]"

    _api_success "{\"plugin\": \"$(_api_json_escape "$plugin_name")\", \"hooks\": $hooks_json}"
}

# GET /plugins/:name/hooks/:hook — Read hook script content
handle_plugin_hook_read() {
    local plugin_name="$1"
    local hook_name="$2"

    # Validate names
    if [[ ! "$plugin_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        _api_error 400 "Invalid plugin name"
        return
    fi
    if [[ "$hook_name" == *"/"* ]] || [[ "$hook_name" == *".."* ]]; then
        _api_error 400 "Invalid hook name"
        return
    fi

    local hook_file="$BASE_DIR/.plugins/$plugin_name/hooks/$hook_name"

    if [[ ! -f "$hook_file" ]]; then
        _api_error 404 "Hook not found: $hook_name"
        return
    fi

    local content
    content=$(cat "$hook_file" 2>/dev/null)
    local executable="false"
    [[ -x "$hook_file" ]] && executable="true"
    local size
    size=$(stat -c%s "$hook_file" 2>/dev/null || echo "0")

    # JSON-escape the content
    local escaped_content
    escaped_content=$(printf '%s' "$content" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '%s' "$content" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | awk '{printf "%s\\n", $0}' | sed '$ s/\\n$//')

    _api_success "{\"plugin\": \"$(_api_json_escape "$plugin_name")\", \"hook\": \"$(_api_json_escape "$hook_name")\", \"content\": $escaped_content, \"executable\": $executable, \"size\": $size}"
}

# PUT /plugins/:name/hooks/:hook — Update hook script
handle_plugin_hook_update() {
    local plugin_name="$1"
    local hook_name="$2"
    local request_body="$3"

    # Validate names
    if [[ ! "$plugin_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        _api_error 400 "Invalid plugin name"
        return
    fi
    if [[ "$hook_name" == *"/"* ]] || [[ "$hook_name" == *".."* ]]; then
        _api_error 400 "Invalid hook name"
        return
    fi

    local plugin_dir="$BASE_DIR/.plugins/$plugin_name"
    local hooks_dir="$plugin_dir/hooks"
    local hook_file="$hooks_dir/$hook_name"

    # Validate plugin exists
    if [[ ! -d "$plugin_dir" ]]; then
        _api_error 404 "Plugin not found: $plugin_name"
        return
    fi

    local content
    content=$(echo "$request_body" | jq -r '.content // empty' 2>/dev/null)

    if [[ -z "$content" ]]; then
        _api_error 400 "Content is required"
        return
    fi

    mkdir -p "$hooks_dir"
    printf '%s' "$content" > "$hook_file"
    chmod +x "$hook_file"

    _api_success "{\"plugin\": \"$(_api_json_escape "$plugin_name")\", \"hook\": \"$(_api_json_escape "$hook_name")\", \"message\": \"Hook updated successfully\"}"
}

# POST /plugins/:name/hooks/:hook/test — Dry-run a hook
handle_plugin_hook_test() {
    local plugin_name="$1"
    local hook_name="$2"
    local request_body="$3"

    # Validate names
    if [[ ! "$plugin_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        _api_error 400 "Invalid plugin name"
        return
    fi
    if [[ "$hook_name" == *"/"* ]] || [[ "$hook_name" == *".."* ]]; then
        _api_error 400 "Invalid hook name"
        return
    fi

    local hook_file="$BASE_DIR/.plugins/$plugin_name/hooks/$hook_name"

    if [[ ! -f "$hook_file" ]]; then
        _api_error 404 "Hook not found: $hook_name"
        return
    fi

    if [[ ! -x "$hook_file" ]]; then
        _api_error 400 "Hook is not executable"
        return
    fi

    # Build test context
    local test_context
    test_context=$(echo "$request_body" | jq -r '.context // empty' 2>/dev/null)
    [[ -z "$test_context" ]] && test_context="{\"stack\":\"test\",\"event\":\"$hook_name\",\"dry_run\":true,\"timestamp\":\"$(date -Iseconds)\"}"

    # Execute with timeout, capture output
    local output
    local exit_code
    output=$(echo "$test_context" | timeout 30 bash "$hook_file" 2>&1) || true
    exit_code=$?

    local escaped_output
    escaped_output=$(printf '%s' "$output" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '"%s"' "$output")

    _api_success "{\"plugin\": \"$(_api_json_escape "$plugin_name")\", \"hook\": \"$(_api_json_escape "$hook_name")\", \"exit_code\": $exit_code, \"output\": $escaped_output}"
}

# GET /plugins/:name/logs — Execution history
handle_plugin_logs() {
    local plugin_name="$1"

    # Validate name
    if [[ ! "$plugin_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        _api_error 400 "Invalid plugin name"
        return
    fi

    local plugin_dir="$BASE_DIR/.plugins/$plugin_name"

    if [[ ! -d "$plugin_dir" ]]; then
        _api_error 404 "Plugin not found: $plugin_name"
        return
    fi

    local log_file="$plugin_dir/execution.log"

    if [[ ! -f "$log_file" ]]; then
        _api_success "{\"plugin\": \"$(_api_json_escape "$plugin_name")\", \"entries\": [], \"total\": 0}"
        return
    fi

    # Read last 50 log entries (JSONL format)
    local entries="["
    local first=true
    local count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        $first || entries+=","
        first=false
        entries+="$line"
        count=$((count+1))
    done < <(tail -50 "$log_file" 2>/dev/null)
    entries+="]"

    _api_success "{\"plugin\": \"$(_api_json_escape "$plugin_name")\", \"entries\": $entries, \"total\": $count}"
}

# POST /plugins/:name/config — Update plugin configuration
handle_plugin_config_update() {
    local plugin_name="$1"
    local request_body="$2"

    # Validate name
    if [[ ! "$plugin_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        _api_error 400 "Invalid plugin name"
        return
    fi

    local plugin_dir="$BASE_DIR/.plugins/$plugin_name"
    local manifest="$plugin_dir/plugin.json"

    if [[ ! -d "$plugin_dir" ]]; then
        _api_error 404 "Plugin not found: $plugin_name"
        return
    fi

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for plugin management"
        return
    fi

    local config
    config=$(echo "$request_body" | jq -r '.config // empty' 2>/dev/null)

    if [[ -z "$config" ]] || [[ "$config" == "null" ]]; then
        _api_error 400 "Config object is required"
        return
    fi

    # Merge config into manifest
    if [[ -f "$manifest" ]]; then
        local updated
        updated=$(jq --argjson cfg "$config" '.config = $cfg' "$manifest" 2>/dev/null)
        if [[ -n "$updated" ]]; then
            echo "$updated" > "$manifest"
        else
            _api_error 500 "Failed to update manifest"
            return
        fi
    else
        echo "{\"name\":\"$plugin_name\",\"config\":$config}" > "$manifest"
    fi

    _api_success "{\"plugin\": \"$(_api_json_escape "$plugin_name")\", \"message\": \"Configuration updated\"}"
}

# =============================================================================
# FEATURE: CONFIG SCHEMA
# =============================================================================

# GET /config/schema — Return contents of .config/schema.json
handle_config_schema() {
    local schema_file="$BASE_DIR/.config/schema.json"

    if [[ ! -f "$schema_file" ]]; then
        _api_error 404 "Config schema not found"
        return
    fi

    local content
    content=$(cat "$schema_file" 2>/dev/null)

    if [[ -z "$content" ]]; then
        _api_error 500 "Failed to read config schema"
        return
    fi

    _api_success "$content"
}

# =============================================================================
# FEATURE: SSE EVENT STREAM
# =============================================================================

# GET /stream — SSE endpoint: docker events + periodic metrics
handle_sse_stream() {
    local cors_origin
    cors_origin=$(_api_cors_origin)

    # Send SSE headers manually
    {
        printf "HTTP/1.1 200 OK\r\n"
        printf "Content-Type: text/event-stream\r\n"
        printf "Cache-Control: no-cache\r\n"
        printf "Connection: keep-alive\r\n"
        printf "X-Content-Type-Options: nosniff\r\n"
        printf "X-API-Version: %s\r\n" "$API_VERSION"
        if [[ -n "$cors_origin" ]]; then
            printf "Access-Control-Allow-Origin: %s\r\n" "$cors_origin"
            printf "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
            printf "Access-Control-Allow-Private-Network: true\r\n"
            printf "Vary: Origin\r\n"
        fi
        printf "\r\n"
    } 2>/dev/null

    # Start docker events listener in background
    local events_pid=""
    docker events --format '{{json .}}' 2>/dev/null | while IFS= read -r event_line; do
        local escaped
        escaped=$(_api_json_escape "$event_line")
        printf "event: docker-event\ndata: %s\n\n" "$event_line" 2>/dev/null || break
    done &
    events_pid=$!

    # Periodic metrics loop (every 5 seconds)
    local iteration=0
    while true; do
        # Send heartbeat/metrics
        local load1
        read -r load1 _ < /proc/loadavg 2>/dev/null || load1=0
        local cpu_count
        cpu_count=$(nproc 2>/dev/null || echo 1)
        local cpu_pct
        cpu_pct=$(awk "BEGIN { printf \"%.1f\", ($load1 / $cpu_count) * 100 }")

        local mem_total=0 mem_available=0
        while IFS=':' read -r key val; do
            val="${val// /}"; val="${val%%kB*}"
            case "$key" in
                MemTotal)     mem_total=$((val / 1024)) ;;
                MemAvailable) mem_available=$((val / 1024)) ;;
            esac
        done < /proc/meminfo 2>/dev/null
        local mem_pct=0
        [[ $mem_total -gt 0 ]] && mem_pct=$(awk "BEGIN { printf \"%.1f\", (($mem_total - $mem_available) / $mem_total) * 100 }")

        local running
        running=$(docker ps -q 2>/dev/null | wc -l)
        local total
        total=$(docker ps -a -q 2>/dev/null | wc -l)

        local ts
        ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

        printf "event: metrics\ndata: {\"ts\":\"%s\",\"cpu_pct\":%s,\"mem_pct\":%s,\"containers_running\":%d,\"containers_total\":%d}\n\n" \
            "$ts" "$cpu_pct" "$mem_pct" "$running" "$total" 2>/dev/null || break

        # Heartbeat comment to keep connection alive
        printf ": heartbeat %d\n\n" "$iteration" 2>/dev/null || break

        iteration=$((iteration + 1))
        sleep 5
    done

    # Cleanup background docker events listener
    [[ -n "$events_pid" ]] && kill "$events_pid" 2>/dev/null
}

# =============================================================================
# REQUEST ROUTER
# =============================================================================

handle_request() {
    local method path

    # Read the HTTP request line
    local request_line=""
    read -r request_line

    # Parse method and path
    method=$(echo "$request_line" | awk '{print $1}')
    path=$(echo "$request_line" | awk '{print $2}')

    # Consume remaining headers and capture Content-Length, Authorization, Origin
    local header="" content_length=0
    REQUEST_AUTH_HEADER=""
    REQUEST_ORIGIN_HEADER=""
    while IFS= read -r header; do
        header="${header%%$'\r'}"
        [[ -z "$header" ]] && break
        # Capture content-length (case-insensitive)
        if [[ "${header,,}" == content-length:* ]]; then
            content_length="${header#*: }"
            content_length="${content_length// /}"
        fi
        # Capture authorization header (case-insensitive)
        if [[ "${header,,}" == authorization:* ]]; then
            REQUEST_AUTH_HEADER="${header#*: }"
            REQUEST_AUTH_HEADER="${REQUEST_AUTH_HEADER// /}"
            # Re-extract preserving the space after "Bearer "
            REQUEST_AUTH_HEADER="${header#*: }"
        fi
        # Capture origin header for CORS validation
        if [[ "${header,,}" == origin:* ]]; then
            REQUEST_ORIGIN_HEADER="${header#*: }"
            REQUEST_ORIGIN_HEADER="${REQUEST_ORIGIN_HEADER## }"
        fi
    done

    # Read request body if present (enforce size limit)
    local request_body=""
    if [[ "$content_length" -gt 0 ]] 2>/dev/null; then
        if [[ "$content_length" -gt "$API_MAX_BODY_SIZE" ]]; then
            _api_error 413 "Request body too large. Maximum: ${API_MAX_BODY_SIZE} bytes"
            return
        fi
        request_body=$(dd bs=1 count="$content_length" 2>/dev/null)
    fi

    # Normalize path: strip trailing slash, lowercase
    path="${path%/}"
    [[ -z "$path" ]] && path="/"

    # Parse query string and strip from path for clean routing
    _api_parse_query "$path"
    path="${path%%\?*}"

    # Handle CORS preflight
    if [[ "$method" == "OPTIONS" ]]; then
        _api_response 200 ""
        return
    fi

    # Log the request and increment stats counter
    local client_ip="${SOCAT_PEERADDR:-127.0.0.1}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $method $path [${client_ip}]" >> "$API_LOG_FILE" 2>/dev/null
    # Atomic request counter increment (file-based, safe across forked handlers)
    if [[ -f "$API_STATS_FILE" ]]; then
        local _rc _ec
        _rc=$(sed -n '1p' "$API_STATS_FILE" 2>/dev/null || echo 0)
        _ec=$(sed -n '2p' "$API_STATS_FILE" 2>/dev/null || echo 0)
        printf '%d\n%d\n' "$(( _rc + 1 ))" "$_ec" > "$API_STATS_FILE" 2>/dev/null
    fi

    # IP whitelist check — reject before any processing
    if ! _api_check_ip_whitelist; then
        _api_error 403 "Access denied: IP ${client_ip} is not in the allowed list."
        return
    fi

    # Global rate limit check — reject if too many requests from this IP
    if ! _api_check_global_rate_limit; then
        _api_error 429 "Rate limit exceeded. Maximum ${API_RATE_LIMIT} requests per ${API_RATE_WINDOW} seconds."
        return
    fi

    # ── Route: GET endpoints ──────────────────────────────────────────
    if [[ "$method" == "GET" ]]; then

        # Auth/setup endpoints that do NOT require authentication
        case "$path" in
            /)                handle_root; return ;;
            /auth/verify)     handle_auth_verify; return ;;
            /setup/status)    handle_setup_status; return ;;
            /setup/defaults)  handle_setup_defaults; return ;;
        esac

        # All other GET endpoints require authentication
        if ! _api_check_auth; then
            _api_error 401 "Authentication required. Provide Authorization: Bearer <token> header."
            return
        fi

        # Admin-only auth endpoints
        case "$path" in
            /auth/users)    handle_auth_users; return ;;
            /auth/invites)  handle_auth_invites; return ;;
            /auth/sessions) handle_auth_sessions; return ;;
        esac

        # Standard authenticated GET endpoints
        case "$path" in
            /status)                    handle_status ;;
            /health)                    handle_health ;;
            /stacks)                    handle_stacks ;;
            /images)                    handle_images false ;;
            /images/stale)              handle_images true ;;
            /containers)                handle_containers ;;
            /config)                    handle_config ;;
            /system)                    handle_system ;;
            /disks)                     handle_disks ;;
            /networks)                  handle_networks ;;
            /volumes)                   handle_volumes ;;
            /logs)                      handle_logs ;;
            /logs/stats)                handle_logs_stats ;;
            /logs/archives)             handle_logs_archives ;;
            /events)                    handle_events ;;
            /version)                   handle_version ;;
            /maintenance/report)        handle_maintenance_report ;;
            /maintenance/orphans)       handle_maintenance_orphans ;;
            /maintenance/disk)          handle_maintenance_disk ;;
            /env)                       handle_root_env ;;
            /backups)                   handle_backup_list ;;
            /backups/status)            handle_backup_status ;;
            /backups/config)            handle_backup_config ;;
            /terminal/history)          handle_terminal_history ;;
            /system/metrics)            handle_system_metrics ;;
            /system/update/check)       handle_system_update_check ;;
            /alerts/config)             handle_alerts_config ;;
            /system/crontab)            handle_crontab ;;
            /system/crontab/system)     handle_crontab_system ;;
            /metrics/trends)            handle_metrics_trends ;;
            /images/check-updates)      handle_images_check_updates_get ;;
            /notifications/rules)       handle_notification_rules_get ;;
            /notifications/history)     handle_notification_history ;;
            /snapshots)                 handle_snapshots_list ;;
            /templates)                 handle_templates_list ;;
            /templates/deploy-history)  handle_deploy_history ;;
            /automations)               handle_automations_list ;;
            /topology)                  handle_topology ;;
            /metrics/history)           handle_metrics_history ;;
            /metrics/summary)           handle_metrics_summary ;;
            /health/score)              handle_health_score ;;
            /health/score/history)      handle_health_score_history ;;
            /secrets)                   handle_secrets_list ;;
            /schedules)                 handle_schedules_list ;;
            /plugins)                   handle_plugins_list ;;
            /plugins/*/hooks/*)
                local pname="${path#/plugins/}"
                local hook_name="${pname#*/hooks/}"
                pname="${pname%%/*}"
                _api_validate_resource_name "$pname" "plugin" || return
                handle_plugin_hook_read "$pname" "$hook_name"
                ;;
            /plugins/*/hooks)
                local pname="${path#/plugins/}"
                pname="${pname%/hooks}"
                _api_validate_resource_name "$pname" "plugin" || return
                handle_plugin_hooks_list "$pname"
                ;;
            /plugins/*/logs)
                local pname="${path#/plugins/}"
                pname="${pname%/logs}"
                _api_validate_resource_name "$pname" "plugin" || return
                handle_plugin_logs "$pname"
                ;;
            /config/schema)             handle_config_schema ;;
            /stream)                    handle_sse_stream ;;

            /rollback/*/snapshots/*)
                local rpath="${path#/rollback/}"
                local stack="${rpath%%/*}"
                local rest="${rpath#*/snapshots/}"
                _api_validate_stack_name "$stack" || return
                handle_rollback_snapshot_detail "$stack" "$rest"
                ;;
            /rollback/*/snapshots)
                local stack="${path#/rollback/}"
                stack="${stack%/snapshots}"
                _api_validate_stack_name "$stack" || return
                handle_rollback_snapshots "$stack"
                ;;
            /rollback/*/diff/*)
                local rpath="${path#/rollback/}"
                local stack="${rpath%%/*}"
                local timestamp="${rpath#*/diff/}"
                _api_validate_stack_name "$stack" || return
                handle_rollback_diff "$stack" "$timestamp"
                ;;
            /secrets/*/exists)
                local key="${path#/secrets/}"
                key="${key%/exists}"
                _api_validate_resource_name "$key" "secret" || return
                handle_secret_exists "$key"
                ;;
            /health/score/*)
                local stack="${path#/health/score/}"
                _api_validate_stack_name "$stack" || return
                handle_health_score_stack "$stack"
                ;;
            /schedules/*/history)
                local sched_id="${path#/schedules/}"
                sched_id="${sched_id%/history}"
                _api_validate_resource_name "$sched_id" "schedule" || return
                handle_schedule_history "$sched_id"
                ;;

            /templates/gallery)
                handle_template_gallery
                ;;
            /templates/*)
                local tname="${path#/templates/}"
                _api_validate_resource_name "$tname" "template" || return
                handle_template_detail "$tname"
                ;;
            /images/search)
                handle_image_search
                ;;
            /export/*)
                local export_type="${path#/export/}"
                handle_export "$export_type"
                ;;
            /audit)
                handle_audit_log
                ;;
            /webhooks)
                handle_webhooks_list
                ;;
            /snapshots/*/download)
                local snap="${path#/snapshots/}"
                snap="${snap%/download}"
                _api_validate_resource_name "$snap" "snapshot" || return
                handle_snapshot_download "$snap"
                ;;
            /stacks/*/compose/history)
                local stack="${path#/stacks/}"
                stack="${stack%/compose/history}"
                _api_validate_stack_name "$stack" || return
                handle_compose_history "$stack"
                ;;
            /automations/*/history)
                local auto_id="${path#/automations/}"
                auto_id="${auto_id%/history}"
                _api_validate_resource_name "$auto_id" "automation" || return
                handle_automation_history "$auto_id"
                ;;
            /containers/*/files)
                local container="${path#/containers/}"
                container="${container%/files}"
                _api_validate_resource_name "$container" "container" || return
                handle_container_files "$container" "${QUERY_PARAMS[path]:-/}"
                ;;
            /containers/*/files/content)
                local container="${path#/containers/}"
                container="${container%/files/content}"
                _api_validate_resource_name "$container" "container" || return
                handle_container_file_content "$container" "${QUERY_PARAMS[path]:-}"
                ;;
            /containers/*/logs/live)
                local container="${path#/containers/}"
                container="${container%/logs/live}"
                _api_validate_resource_name "$container" "container" || return
                handle_container_logs_live "$container" "${QUERY_PARAMS[lines]:-100}" "${QUERY_PARAMS[since]:-}"
                ;;
            /logs/live)
                handle_app_logs_live "${QUERY_PARAMS[lines]:-100}" "${QUERY_PARAMS[since]:-}"
                ;;
            /stacks/*/services)
                local stack="${path#/stacks/}"
                stack="${stack%/services}"
                _api_validate_stack_name "$stack" || return
                handle_stack_services "$stack"
                ;;
            /stacks/*/containers)
                local stack="${path#/stacks/}"
                stack="${stack%/containers}"
                _api_validate_stack_name "$stack" || return
                handle_stack_containers "$stack"
                ;;
            /stacks/*/logs)
                local stack="${path#/stacks/}"
                stack="${stack%/logs}"
                _api_validate_stack_name "$stack" || return
                handle_stack_logs "$stack"
                ;;
            /stacks/*/compose)
                local stack="${path#/stacks/}"
                stack="${stack%/compose}"
                _api_validate_stack_name "$stack" || return
                handle_stack_compose "$stack"
                ;;
            /stacks/*/env)
                local stack="${path#/stacks/}"
                stack="${stack%/env}"
                _api_validate_stack_name "$stack" || return
                handle_stack_env "$stack"
                ;;
            /stacks/*)
                local stack="${path#/stacks/}"
                _api_validate_stack_name "$stack" || return
                handle_stack_detail "$stack"
                ;;
            /containers/*/stats)
                local container="${path#/containers/}"
                container="${container%/stats}"
                _api_validate_resource_name "$container" "container" || return
                handle_container_stats "$container"
                ;;
            /containers/*/logs)
                local container="${path#/containers/}"
                container="${container%/logs}"
                _api_validate_resource_name "$container" "container" || return
                handle_container_logs "$container"
                ;;
            /containers/*/processes)
                local container="${path#/containers/}"
                container="${container%/processes}"
                _api_validate_resource_name "$container" "container" || return
                handle_container_processes "$container"
                ;;
            /networks/*)
                local network="${path#/networks/}"
                _api_validate_resource_name "$network" "network" || return
                handle_network_detail "$network"
                ;;
            /containers/*)
                local container="${path#/containers/}"
                _api_validate_resource_name "$container" "container" || return
                handle_container_detail "$container"
                ;;
            *)
                _api_error 404 "Endpoint not found: $path"
                ;;
        esac
        return
    fi

    # ── Route: POST endpoints ─────────────────────────────────────────
    if [[ "$method" == "POST" ]]; then

        # Auth endpoints that do NOT require authentication
        case "$path" in
            /auth/setup)    handle_auth_setup "$request_body"; return ;;
            /auth/login)    handle_auth_login "$request_body"; return ;;
            /auth/register) handle_auth_register "$request_body"; return ;;
        esac

        # All other POST endpoints require authentication
        if ! _api_check_auth; then
            _api_error 401 "Authentication required. Provide Authorization: Bearer <token> header."
            return
        fi

        # Setup wizard endpoints (require auth + setup not complete)
        case "$path" in
            /setup/configure) handle_setup_configure "$request_body"; return ;;
            /setup/complete)  handle_setup_complete; return ;;
        esac

        # Auth session management endpoints (any authenticated user)
        case "$path" in
            /auth/logout)   handle_auth_logout; return ;;
            /auth/refresh)  handle_auth_refresh; return ;;
        esac

        # Auth endpoints that require admin
        case "$path" in
            /auth/invite)         handle_auth_invite "$request_body"; return ;;
            /auth/revoke)         handle_auth_revoke "$request_body"; return ;;
            /auth/logout-all)     handle_auth_logout_all "$request_body"; return ;;
            /auth/factory-reset)  handle_auth_factory_reset "$request_body"; return ;;
        esac

        # Stack management endpoints (admin-only)
        case "$path" in
            /stacks/rename)   handle_stack_rename "$request_body"; return ;;
            /stacks/reorder)  handle_stack_reorder "$request_body"; return ;;
        esac

        # Standard authenticated POST endpoints
        case "$path" in
            /terminal/exec)
                handle_terminal_exec "$request_body"
                ;;
            /terminal/auth)
                handle_terminal_auth "$request_body"
                ;;
            /terminal/auth/verify)
                handle_terminal_auth_verify "$request_body"
                ;;
            /terminal/auth/logout)
                handle_terminal_logout "$request_body"
                ;;
            /alerts/config)
                handle_alerts_config_update "$request_body"
                ;;
            /system/crontab)
                handle_crontab_update "$request_body"
                ;;
            /system/update/apply)
                handle_system_update_apply "$request_body"
                ;;
            /system/update/rollback)
                handle_system_update_rollback "$request_body"
                ;;
            /stacks)
                handle_create_stack "$request_body"
                ;;
            /stacks/*/delete)
                local stack="${path#/stacks/}"
                stack="${stack%/delete}"
                _api_validate_stack_name "$stack" || return
                handle_delete_stack "$stack"
                ;;
            /config)
                handle_config_update "$request_body"
                ;;
            /containers/*/start)
                local container="${path#/containers/}"
                container="${container%/start}"
                _api_validate_resource_name "$container" "container" || return
                handle_container_action "$container" "start"
                ;;
            /containers/*/stop)
                local container="${path#/containers/}"
                container="${container%/stop}"
                _api_validate_resource_name "$container" "container" || return
                handle_container_action "$container" "stop"
                ;;
            /containers/*/restart)
                local container="${path#/containers/}"
                container="${container%/restart}"
                _api_validate_resource_name "$container" "container" || return
                handle_container_action "$container" "restart"
                ;;
            /containers/*/remove)
                local container="${path#/containers/}"
                container="${container%/remove}"
                _api_validate_resource_name "$container" "container" || return
                handle_container_action "$container" "remove"
                ;;
            /containers/*/exec)
                local container="${path#/containers/}"
                container="${container%/exec}"
                _api_validate_resource_name "$container" "container" || return
                handle_container_exec "$container" "$request_body"
                ;;
            /containers/*/rename)
                local container="${path#/containers/}"
                container="${container%/rename}"
                _api_validate_resource_name "$container" "container" || return
                handle_container_rename "$container" "$request_body"
                ;;
            /networks)
                handle_create_network "$request_body"
                ;;
            /networks/*/delete)
                local network="${path#/networks/}"
                network="${network%/delete}"
                _api_validate_resource_name "$network" "network" || return
                handle_delete_network "$network"
                ;;
            /networks/*/connect)
                local network="${path#/networks/}"
                network="${network%/connect}"
                _api_validate_resource_name "$network" "network" || return
                handle_network_connect "$network" "$request_body"
                ;;
            /networks/*/disconnect)
                local network="${path#/networks/}"
                network="${network%/disconnect}"
                _api_validate_resource_name "$network" "network" || return
                handle_network_disconnect "$network" "$request_body"
                ;;
            /images/*/delete)
                local image="${path#/images/}"
                image="${image%/delete}"
                _api_validate_resource_name "$image" "image" || return
                handle_image_delete "$image"
                ;;
            /volumes/*/delete)
                local volume="${path#/volumes/}"
                volume="${volume%/delete}"
                _api_validate_resource_name "$volume" "volume" || return
                handle_delete_volume "$volume"
                ;;
            /maintenance/prune)
                handle_maintenance_prune
                ;;
            /maintenance/image-prune)
                handle_maintenance_image_prune
                ;;
            /maintenance/deep-prune)
                handle_maintenance_deep_prune "$request_body"
                ;;
            /maintenance/log-rotate)
                handle_maintenance_log_rotate
                ;;
            /batch/stacks)
                handle_batch_stacks "$request_body"
                ;;
            /batch/update)
                handle_batch_update "$request_body"
                ;;
            /env)
                handle_root_env_update "$request_body"
                ;;
            /env/validate)
                handle_env_validate "$request_body"
                ;;
            /backups/trigger)
                handle_backup_trigger "$request_body"
                ;;
            /backups/restore)
                handle_backup_restore "$request_body"
                ;;
            /stacks/*/compose/validate)
                local stack="${path#/stacks/}"
                stack="${stack%/compose/validate}"
                _api_validate_stack_name "$stack" || return
                handle_stack_compose_validate "$stack" "$request_body"
                ;;
            /stacks/*/compose)
                local stack="${path#/stacks/}"
                stack="${stack%/compose}"
                _api_validate_stack_name "$stack" || return
                handle_stack_compose_save "$stack" "$request_body"
                ;;
            /stacks/*/env)
                local stack="${path#/stacks/}"
                stack="${stack%/env}"
                _api_validate_stack_name "$stack" || return
                handle_stack_env_save "$stack" "$request_body"
                ;;
            /stacks/*/compose/rollback)
                local stack="${path#/stacks/}"
                stack="${stack%/compose/rollback}"
                _api_validate_stack_name "$stack" || return
                handle_compose_rollback "$stack" "$request_body"
                ;;
            /metrics/snapshot)
                handle_metrics_snapshot
                ;;
            /images/check-updates)
                handle_images_check_updates_post
                ;;
            /images/*/update)
                local img="${path#/images/}"
                img="${img%/update}"
                _api_validate_resource_name "$img" "image" || return
                handle_image_update "$img"
                ;;
            /notifications/rules)
                handle_notification_rules_create "$request_body"
                ;;
            /notifications/test)
                handle_notification_test "$request_body"
                ;;
            /snapshots/create)
                handle_snapshot_create "$request_body"
                ;;
            /snapshots/*/restore)
                local snap="${path#/snapshots/}"
                snap="${snap%/restore}"
                _api_validate_resource_name "$snap" "snapshot" || return
                handle_snapshot_restore "$snap" "$request_body"
                ;;
            /templates/*/deploy)
                local tname="${path#/templates/}"
                tname="${tname%/deploy}"
                _api_validate_resource_name "$tname" "template" || return
                handle_template_deploy "$tname" "$request_body"
                ;;
            /templates/*/undeploy)
                local tname="${path#/templates/}"
                tname="${tname%/undeploy}"
                _api_validate_resource_name "$tname" "template" || return
                handle_template_undeploy "$tname" "$request_body"
                ;;
            /templates/*/dry-run)
                local tname="${path#/templates/}"
                tname="${tname%/dry-run}"
                _api_validate_resource_name "$tname" "template" || return
                handle_template_dry_run "$tname" "$request_body"
                ;;
            /templates/import)
                handle_template_import "$request_body"
                ;;
            /templates/fetch-url)
                handle_template_fetch_url "$request_body"
                ;;
            /templates/import-url)
                handle_template_import_url "$request_body"
                ;;
            /stacks/*/clone)
                local sname="${path#/stacks/}"
                sname="${sname%/clone}"
                _api_validate_resource_name "$sname" "stack" || return
                handle_stack_clone "$sname" "$request_body"
                ;;
            /compose/validate)
                handle_compose_validate "$request_body"
                ;;
            /webhooks)
                handle_webhook_create "$request_body"
                ;;
            /webhooks/*/test)
                local wid="${path#/webhooks/}"
                wid="${wid%/test}"
                handle_webhook_test "$wid"
                ;;
            /templates/*/update)
                local tname="${path#/templates/}"
                tname="${tname%/update}"
                _api_validate_resource_name "$tname" "template" || return
                handle_template_update "$tname" "$request_body"
                ;;
            /automations)
                handle_automation_create "$request_body"
                ;;
            /automations/*/update)
                local auto_id="${path#/automations/}"
                auto_id="${auto_id%/update}"
                _api_validate_resource_name "$auto_id" "automation" || return
                handle_automation_update "$auto_id" "$request_body"
                ;;
            /stacks/*/start)
                local stack="${path#/stacks/}"
                stack="${stack%/start}"
                _api_validate_stack_name "$stack" || return
                handle_stack_action "$stack" "start"
                ;;
            /stacks/*/stop)
                local stack="${path#/stacks/}"
                stack="${stack%/stop}"
                _api_validate_stack_name "$stack" || return
                handle_stack_action "$stack" "stop"
                ;;
            /stacks/*/restart)
                local stack="${path#/stacks/}"
                stack="${stack%/restart}"
                _api_validate_stack_name "$stack" || return
                handle_stack_action "$stack" "restart"
                ;;
            /stacks/*/update)
                local stack="${path#/stacks/}"
                stack="${stack%/update}"
                _api_validate_stack_name "$stack" || return
                handle_stack_action "$stack" "update"
                ;;
            /secrets)
                handle_secret_set "$request_body"
                ;;
            /schedules)
                handle_schedule_create "$request_body"
                ;;
            /plugins/install)
                handle_plugin_install "$request_body"
                ;;
            /plugins/scaffold)
                handle_plugin_scaffold "$request_body"
                ;;
            /rollback/*/restore)
                local stack="${path#/rollback/}"
                stack="${stack%/restore}"
                _api_validate_stack_name "$stack" || return
                handle_rollback_restore "$stack" "$request_body"
                ;;
            /schedules/*/update)
                local sched_id="${path#/schedules/}"
                sched_id="${sched_id%/update}"
                _api_validate_resource_name "$sched_id" "schedule" || return
                handle_schedule_update "$sched_id" "$request_body"
                ;;
            /schedules/*/toggle)
                local sched_id="${path#/schedules/}"
                sched_id="${sched_id%/toggle}"
                _api_validate_resource_name "$sched_id" "schedule" || return
                handle_schedule_toggle "$sched_id"
                ;;
            /plugins/*/toggle)
                local pname="${path#/plugins/}"
                pname="${pname%/toggle}"
                _api_validate_resource_name "$pname" "plugin" || return
                handle_plugin_toggle "$pname"
                ;;
            /plugins/*/hooks/*/test)
                local pname="${path#/plugins/}"
                local rest="${pname#*/hooks/}"
                local hook_name="${rest%/test}"
                pname="${pname%%/*}"
                _api_validate_resource_name "$pname" "plugin" || return
                handle_plugin_hook_test "$pname" "$hook_name" "$request_body"
                ;;
            /plugins/*/hooks/*/update)
                local pname="${path#/plugins/}"
                local rest="${pname#*/hooks/}"
                local hook_name="${rest%/update}"
                pname="${pname%%/*}"
                _api_validate_resource_name "$pname" "plugin" || return
                handle_plugin_hook_update "$pname" "$hook_name" "$request_body"
                ;;
            /plugins/*/config)
                local pname="${path#/plugins/}"
                pname="${pname%/config}"
                _api_validate_resource_name "$pname" "plugin" || return
                handle_plugin_config_update "$pname" "$request_body"
                ;;
            *)
                _api_error 404 "Endpoint not found: $path"
                ;;
        esac
        return
    fi

    # ── Route: DELETE endpoints ────────────────────────────────────────
    if [[ "$method" == "DELETE" ]]; then

        # All DELETE endpoints require authentication
        if ! _api_check_auth; then
            _api_error 401 "Authentication required. Provide Authorization: Bearer <token> header."
            return
        fi

        case "$path" in
            /auth/sessions/*)
                local token_prefix="${path#/auth/sessions/}"
                handle_auth_session_revoke "$token_prefix"
                ;;
            /auth/invite/*)
                local code="${path#/auth/invite/}"
                handle_auth_delete_invite "$code"
                ;;
            /notifications/rules/*)
                local rule_id="${path#/notifications/rules/}"
                _api_validate_resource_name "$rule_id" "notification rule" || return
                handle_notification_rules_delete "$rule_id"
                ;;
            /snapshots/*)
                local snap="${path#/snapshots/}"
                _api_validate_resource_name "$snap" "snapshot" || return
                handle_snapshot_delete "$snap"
                ;;
            /webhooks/*)
                local wid="${path#/webhooks/}"
                handle_webhook_delete "$wid"
                ;;
            /templates/*)
                local tname="${path#/templates/}"
                _api_validate_resource_name "$tname" "template" || return
                handle_template_delete "$tname"
                ;;
            /automations/*)
                local auto_id="${path#/automations/}"
                _api_validate_resource_name "$auto_id" "automation" || return
                handle_automation_delete "$auto_id"
                ;;
            /secrets/*)
                local key="${path#/secrets/}"
                _api_validate_resource_name "$key" "secret" || return
                handle_secret_delete "$key"
                ;;
            /schedules/*)
                local sched_id="${path#/schedules/}"
                _api_validate_resource_name "$sched_id" "schedule" || return
                handle_schedule_delete "$sched_id"
                ;;
            /plugins/*)
                local pname="${path#/plugins/}"
                _api_validate_resource_name "$pname" "plugin" || return
                handle_plugin_remove "$pname"
                ;;
            *)
                _api_error 404 "Endpoint not found: $path"
                ;;
        esac
        return
    fi

    _api_error 405 "Method not allowed: $method"
}

# =============================================================================
# SERVER MAIN LOOP
# =============================================================================

start_server() {
    # Create log directory
    mkdir -p "$(dirname "$API_LOG_FILE")" 2>/dev/null

    # Color setup for terminal output
    local _A_RST="" _A_BOLD="" _A_DIM=""
    local _A_CYAN="" _A_BLUE="" _A_GREEN="" _A_GRAY="" _A_WHITE="" _A_MAGENTA=""

    if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]] && command -v tput >/dev/null 2>&1; then
        _A_RST="$(tput sgr0)"
        _A_BOLD="$(tput bold)"
        _A_DIM="$(tput dim)"
        _A_CYAN="$(tput setaf 51)"
        _A_BLUE="$(tput setaf 33)"
        _A_GREEN="$(tput setaf 82)"
        _A_GRAY="$(tput setaf 245)"
        _A_WHITE="$(tput setaf 15)"
        _A_MAGENTA="$(tput setaf 141)"
    fi

    local border
    border="$(printf '%0.s═' $(seq 1 60))"

    echo ""
    echo "  ${_A_BOLD}${_A_BLUE}${border}${_A_RST}"
    echo ""
    echo "  ${_A_BOLD}${_A_CYAN}   ╔═╗╔═╗╦  ╔═╗╔═╗╦═╗╦  ╦╔═╗╦═╗${_A_RST}"
    echo "  ${_A_BOLD}${_A_CYAN}   ╠═╣╠═╝║  ╚═╗║╣ ╠╦╝╚╗╔╝║╣ ╠╦╝${_A_RST}"
    echo "  ${_A_BOLD}${_A_CYAN}   ╩ ╩╩  ╩  ╚═╝╚═╝╩╚═ ╚╝ ╚═╝╩╚═${_A_RST}"
    echo ""
    echo "  ${_A_DIM}${_A_GRAY}  Docker Compose Skeleton REST API${_A_RST}"
    echo ""
    echo "  ${_A_BOLD}${_A_BLUE}${border}${_A_RST}"
    echo ""
    echo "  ${_A_BOLD}${_A_WHITE}Version${_A_RST}    ${_A_CYAN}v${API_VERSION}${_A_RST}"
    echo "  ${_A_BOLD}${_A_WHITE}Listen${_A_RST}     ${_A_GREEN}${API_BIND}:${API_PORT}${_A_RST}"
    echo "  ${_A_BOLD}${_A_WHITE}Transport${_A_RST}  ${_A_MAGENTA}${LISTENER_CMD}${_A_RST}"
    echo "  ${_A_BOLD}${_A_WHITE}Auth${_A_RST}       $([[ "$API_AUTH_ENABLED" == "true" ]] && echo "${_A_GREEN}Enabled${_A_RST}" || echo "${_A_GRAY}Disabled (localhost)${_A_RST}")"
    echo "  ${_A_BOLD}${_A_WHITE}PID${_A_RST}        ${_A_GRAY}$$${_A_RST}"
    echo "  ${_A_BOLD}${_A_WHITE}Base Dir${_A_RST}   ${_A_DIM}${BASE_DIR}${_A_RST}"
    echo ""
    echo "  ${_A_DIM}${_A_GRAY}──────────────────────────────────────────────────────────${_A_RST}"
    echo ""
    echo "  ${_A_GREEN}Endpoints${_A_RST}  ${_A_DIM}curl http://${API_BIND}:${API_PORT}/${_A_RST}"
    echo "  ${_A_GREEN}Stop${_A_RST}       ${_A_DIM}$0 --stop${_A_RST}"
    echo ""
    echo "  ${_A_BOLD}${_A_BLUE}${border}${_A_RST}"
    echo ""

    # Write PID file (use $BASHPID for the actual process PID, not $$ which is always the parent)
    echo "${BASHPID:-$$}" > "$API_PID_FILE"

    local self_path
    self_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

    # Start the listener — socat/ncat invoke this script with --handle-request
    # which triggers the internal request handler (see ENTRY POINT below)
    if [[ "$LISTENER_CMD" == "socat" ]]; then
        if [[ "$API_TLS_ENABLED" == "true" ]]; then
            if [[ ! -f "$API_TLS_CERT" ]] || [[ ! -f "$API_TLS_KEY" ]]; then
                echo "ERROR: TLS enabled but certificate/key not found." >&2
                echo "  Certificate: $API_TLS_CERT" >&2
                echo "  Key: $API_TLS_KEY" >&2
                echo "  Generate with: openssl req -x509 -newkey rsa:4096 -keyout server.key -out server.crt -days 365 -nodes -subj '/CN=dcs-api'" >&2
                exit 1
            fi
            echo "Starting API server on https://${API_BIND}:${API_PORT} (TLS enabled)"
            socat "OPENSSL-LISTEN:${API_PORT},bind=${API_BIND},reuseaddr,fork,cert=${API_TLS_CERT},key=${API_TLS_KEY},verify=0" \
                EXEC:"$self_path --handle-request",nofork
        else
            echo "Starting API server on http://${API_BIND}:${API_PORT}"
            socat "TCP-LISTEN:${API_PORT},bind=${API_BIND},reuseaddr,fork" \
                EXEC:"$self_path --handle-request",nofork
        fi
    else
        # ncat mode
        ncat -l -k "${API_BIND}" "${API_PORT}" -e "$self_path --handle-request"
    fi
}

# =============================================================================
# ENTRY POINT
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Internal: called by socat/ncat for each incoming connection
    if [[ "$HANDLE_REQUEST" == "true" ]]; then
        # Disable errexit for request handling — we handle errors via JSON responses
        set +e
        handle_request
        exit 0
    fi

    if [[ "$DAEMON_MODE" == "true" ]]; then
        start_server >> "$API_LOG_FILE" 2>&1 &
        bg_pid=$!
        disown
        # Overwrite PID file with the actual background PID
        echo "$bg_pid" > "$API_PID_FILE"
        echo "API server started in background (PID: $bg_pid)"
        echo "Log: $API_LOG_FILE"
        echo "Stop: $0 --stop"
    else
        start_server
    fi
fi
