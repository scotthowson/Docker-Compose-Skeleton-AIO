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
API_VERSION="1.2.2"

# Plugin system
PLUGINS_DIR="${BASE_DIR}/.plugins"
PLUGINS_HOOKS_ENABLED="${PLUGINS_HOOKS_ENABLED:-true}"
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

# NOTE: API_AUTH_ENABLED is respected as-is from .env or auto-detection above.
# When the user explicitly sets API_AUTH_ENABLED=false, we honor that choice.

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
API_RATE_LIMIT="${API_RATE_LIMIT:-600}"
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
    printf "Permissions-Policy: camera=(), microphone=(), geolocation=(), interest-cohort=()\r\n"
    if [[ "$API_TLS_ENABLED" == "true" ]] || [[ "$API_BEHIND_TLS_PROXY" == "true" ]]; then
        printf "Strict-Transport-Security: max-age=31536000; includeSubDomains; preload\r\n"
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
        (umask 0077 && mkdir -p "$API_AUTH_DIR") 2>/dev/null || mkdir -p "$API_AUTH_DIR" 2>/dev/null
    fi
    # Create missing auth files with secure permissions
    # Use printf + chmod as fallback if install doesn't support /dev/stdin
    for _f in users.json tokens.json invites.json; do
        if [[ ! -f "$API_AUTH_DIR/$_f" ]]; then
            printf '[]' > "$API_AUTH_DIR/$_f" 2>/dev/null && chmod 600 "$API_AUTH_DIR/$_f" 2>/dev/null
        fi
    done
    if [[ ! -f "$API_AUTH_DIR/rate_limits.json" ]]; then
        printf '{}' > "$API_AUTH_DIR/rate_limits.json" 2>/dev/null && chmod 600 "$API_AUTH_DIR/rate_limits.json" 2>/dev/null
    fi
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
    # SECURITY: Constant-time comparison to prevent timing attacks.
    # Python's hmac.compare_digest is guaranteed constant-time.
    python3 -c "
import hmac, sys
sys.exit(0 if hmac.compare_digest(sys.argv[1], sys.argv[2]) else 1)
" "$computed_hash" "$stored_hash"
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

# =============================================================================
# TOTP (Time-Based One-Time Password) — RFC 6238
# =============================================================================

# Generate a TOTP secret (20 bytes random, returned as hex + base32)
_api_totp_generate_secret() {
    python3 -c "
import os, base64
raw = os.urandom(20)
print(raw.hex())
print(base64.b32encode(raw).decode().rstrip('='))
" 2>/dev/null
}

# Verify a TOTP code against a secret. Allows +/-1 time window (90 seconds).
# Args: $1=hex_secret $2=6-digit code
# Returns: 0 on success, 1 on failure
_api_totp_verify() {
    local hex_secret="$1" code="$2"
    python3 -c "
import hmac, hashlib, struct, sys, time
secret = bytes.fromhex(sys.argv[1])
code = sys.argv[2].strip()
if len(code) != 6 or not code.isdigit():
    sys.exit(1)
now = int(time.time())
# Check current period and +/-1 for clock skew (90 second window)
for offset in (-1, 0, 1):
    t = (now // 30) + offset
    msg = struct.pack('>Q', t)
    h = hmac.new(secret, msg, hashlib.sha1).digest()
    o = h[-1] & 0x0F
    token = (struct.unpack('>I', h[o:o+4])[0] & 0x7FFFFFFF) % 1000000
    if str(token).zfill(6) == code:
        sys.exit(0)
sys.exit(1)
" "$hex_secret" "$code" 2>/dev/null
}

# Build an otpauth:// URI for QR code generation
# Args: $1=base32_secret $2=username $3=issuer
_api_totp_uri() {
    local b32="$1" username="$2" issuer="${3:-DCS}"
    printf 'otpauth://totp/%s:%s?secret=%s&issuer=%s&algorithm=SHA1&digits=6&period=30' \
        "$(_api_json_escape "$issuer")" "$(_api_json_escape "$username")" "$b32" "$(_api_json_escape "$issuer")"
}

# Update a user's TOTP fields in users.json
_api_totp_update_user() {
    local username="$1" totp_secret="$2" totp_enabled="$3"
    local users
    users=$(_api_read_auth_file "users.json")
    if command -v jq >/dev/null 2>&1; then
        local new_users
        new_users=$(echo "$users" | jq \
            --arg u "$username" \
            --arg s "$totp_secret" \
            --argjson e "$totp_enabled" \
            '[.[] | if .username == $u then . + {"totp_secret": $s, "totp_enabled": $e} else . end]' 2>/dev/null)
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

# Read a JSON auth file (returns contents, with shared flock)
_api_read_auth_file() {
    local file="$API_AUTH_DIR/$1"
    [[ -f "$file" ]] || { echo '[]'; return; }
    if command -v flock >/dev/null 2>&1; then
        (flock -s -w 2 200; cat "$file" 2>/dev/null) 200>"$file.lock"
    else
        cat "$file" 2>/dev/null
    fi
}

# Write a JSON auth file (exclusive flock + restricted permissions)
_api_write_auth_file() {
    local file="$API_AUTH_DIR/$1"
    local content="$2"
    [[ -d "$API_AUTH_DIR" ]] || mkdir -p "$API_AUTH_DIR" 2>/dev/null
    if command -v flock >/dev/null 2>&1; then
        (flock -w 2 200; printf '%s' "$content" > "$file" 2>/dev/null; chmod 600 "$file" 2>/dev/null) 200>"$file.lock"
    else
        printf '%s' "$content" > "$file" 2>/dev/null
        chmod 600 "$file" 2>/dev/null
    fi
    return 0
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
    # When auth is disabled, only check the marker file (no user accounts required)
    if [[ "$API_AUTH_ENABLED" != "true" ]]; then
        [[ -f "$SETUP_COMPLETE_MARKER" ]]
        return $?
    fi
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
    local lockfile="$API_AUTH_DIR/.tokens.lock"

    # SECURITY: File lock prevents race condition where concurrent logins
    # both pass the single-session check and create duplicate tokens.
    (
        flock -w 10 200 || { echo "Token lock timeout" >&2; return 1; }

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
    ) 200>"$lockfile"
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

    # If no users exist yet, allow anonymous access for initial setup.
    # This covers both fresh installs AND factory resets (which delete users + .setup-complete).
    local user_count
    user_count=$(_api_user_count)
    if [[ "$user_count" -eq 0 ]] && [[ ! -f "$API_AUTH_DIR/.setup-complete" ]]; then
        AUTH_USERNAME="anonymous"
        AUTH_ROLE="admin"
        return 0
    fi

    _api_init_auth_dir

    # Extract token from Authorization header or ?token= query parameter
    local token=""
    if [[ -n "${REQUEST_AUTH_HEADER:-}" ]]; then
        # Strip "Bearer " prefix
        token="${REQUEST_AUTH_HEADER#Bearer }"
        token="${token#bearer }"
    fi

    # Fallback: check query parameter (needed for EventSource/SSE which can't set headers)
    if [[ -z "$token" && -n "${QUERY_PARAMS[token]:-}" ]]; then
        token="${QUERY_PARAMS[token]}"
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

# =============================================================================
# COMPOSE SECURITY SCANNER
# =============================================================================
# Scans docker-compose YAML content for dangerous Docker features that could
# allow container escape, host compromise, or privilege escalation.
# Returns 0 if safe, 1 if dangerous (and sends 400 error response with details).
#
# This prevents the #1 Docker attack vector: deploying a privileged container
# that mounts the host filesystem, escapes, and installs malware (e.g., crypto miners).
# =============================================================================

_api_scan_compose_security() {
    local content="$1"
    local context="${2:-compose file}"
    local mode="${3:-strict}"  # "strict" = block everything, "deploy" = allow docker.sock (trusted templates)
    local -a violations=()

    # SECURITY: Pre-resolve ${VAR:-default} patterns before scanning.
    # This prevents bypass via `privileged: ${X:-true}` which Docker Compose
    # resolves to `privileged: true` at runtime. We scan the resolved version.
    local resolved_content
    resolved_content=$(printf '%s' "$content" | sed 's/\${[A-Za-z_][A-Za-z0-9_]*:-\([^}]*\)}/\1/g')

    # Convert to lowercase for case-insensitive matching
    # Use resolved content for scanning (catches ${VAR:-dangerous} bypass)
    local lower_content="${resolved_content,,}"

    # ── CRITICAL: Container escape vectors ──
    # NOTE: We check for the KEY existing at all (not just specific values) for the most
    # dangerous features. This prevents bypass via YAML anchors, aliases, or variable
    # substitution (e.g., `privileged: *anchor` or `privileged: ${VAR:-true}`).

    # ── CRITICAL: Build context (Dockerfile can execute arbitrary code) ──
    # Block `build:` directive entirely — only pre-built images are allowed.
    # A Dockerfile can RUN any command during build, bypassing all runtime checks.
    if printf '%s' "$lower_content" | grep -qE '^\s+build:\s'; then
        violations+=("'build:' directive is not allowed — only pre-built images (image:) are permitted. Dockerfiles can execute arbitrary code during build.")
    fi

    # ── CRITICAL: File inclusion directives (can reference files outside App-Data) ──
    # `extends:` includes another compose file which may contain dangerous directives
    # that bypass our scanner (the included file is never scanned)
    if [[ "$mode" == "strict" ]]; then
        if printf '%s' "$lower_content" | grep -qE '^\s+extends:\s'; then
            violations+=("'extends:' directive is not allowed in user-edited compose files (can include unscanned external files)")
        fi
    fi

    # ── CRITICAL: Container escape vectors ──
    # privileged mode = full host access (most dangerous)
    if [[ "$mode" == "strict" ]]; then
        # Strict: block ANY use of privileged key
        if printf '%s' "$lower_content" | grep -qE '^\s+privileged:\s'; then
            violations+=("'privileged' key is not allowed in user-edited compose files (container escape risk)")
        fi
    else
        # Deploy: block privileged: true/yes AND YAML aliases (*anchor)
        # This prevents bypass via `x-p: &p true` + `privileged: *p`
        if printf '%s' "$lower_content" | grep -qE '^\s+privileged:\s*(true|yes|\*[a-z])'; then
            violations+=("privileged mode is not allowed (grants full host access). Template requires manual approval via --allow-privileged flag.")
        fi
    fi

    # Host PID namespace = can see/kill host processes
    if printf '%s' "$lower_content" | grep -qE '^\s+pid:\s*["'"'"']?host'; then
        violations+=("host PID namespace is not allowed (exposes host processes)")
    fi

    # Host network = bypass network isolation
    if printf '%s' "$lower_content" | grep -qE '^\s+network_mode:\s*["'"'"']?host'; then
        violations+=("host network mode is not allowed (bypasses network isolation)")
    fi

    # Host IPC namespace
    if printf '%s' "$lower_content" | grep -qE '^\s+ipc:\s*["'"'"']?host'; then
        violations+=("host IPC namespace is not allowed")
    fi

    # userns_mode: host = share user namespace with host
    if printf '%s' "$lower_content" | grep -qE '^\s+userns_mode:\s*["'"'"']?host'; then
        violations+=("host user namespace is not allowed")
    fi

    # cgroup_parent = custom cgroup (can escape resource limits)
    if printf '%s' "$lower_content" | grep -qE '^\s+cgroup_parent:\s'; then
        violations+=("cgroup_parent is not allowed")
    fi

    # ── HIGH: Dangerous volume mounts ──

    # Mount host root filesystem
    if printf '%s' "$lower_content" | grep -qE '^\s+-\s*["'"'"']?/:/'; then
        violations+=("mounting host root filesystem (/) is not allowed")
    fi

    # Mount /etc directly (system config) — but allow specific subdirs like /etc/localtime
    # Block: "- /etc:/something" or "- /etc" (bare mount)
    # Allow: "- /etc/localtime:/etc/localtime:ro" or "- /etc/timezone:/etc/timezone:ro"
    if printf '%s' "$lower_content" | grep -qE '^\s+-\s*["'"'"']?/etc[:"'"'"'\s]' | grep -vq '/etc/'; then
        # Only flag if mounting /etc root, not a subdirectory
        if printf '%s' "$lower_content" | grep -qE '^\s+-\s*["'"'"']?/etc[:"'"'"'\s]'; then
            local etc_mount
            etc_mount=$(printf '%s' "$lower_content" | grep -E '^\s+-\s*["'"'"']?/etc[:"'"'"'\s]')
            # If it's /etc: or /etc" (bare), that's the whole /etc directory
            if echo "$etc_mount" | grep -qE '/etc["'"'"']?:'; then
                violations+=("mounting /etc is not allowed (contains system configuration)")
            fi
        fi
    fi

    # Mount /root (root home directory)
    if printf '%s' "$lower_content" | grep -qE '^\s+-\s*["'"'"']?/root[/:]'; then
        violations+=("mounting /root is not allowed")
    fi

    # Mount /proc or /sys (kernel interfaces) — strict mode only
    # In deploy mode, monitoring tools (Netdata, Dashdot) need :ro access to /proc and /sys
    if [[ "$mode" == "strict" ]]; then
        if printf '%s' "$lower_content" | grep -qE '^\s+-\s*["'"'"']?/(proc|sys)[/:]'; then
            violations+=("mounting /proc or /sys is not allowed (kernel interface access)")
        fi
    else
        # Even in deploy mode, block writable /proc or /sys mounts
        if printf '%s' "$lower_content" | grep -qE '^\s+-\s*["'"'"']?/(proc|sys)[/:]' && \
           ! printf '%s' "$lower_content" | grep -E '^\s+-\s*["'"'"']?/(proc|sys)[/:]' | grep -q ':ro'; then
            violations+=("mounting /proc or /sys without :ro is not allowed")
        fi
    fi

    # Mount /dev (device access) — allow only /dev/null, /dev/urandom, /dev/random
    if printf '%s' "$lower_content" | grep -qE '^\s+-\s*["'"'"']?/dev[/:]'; then
        if ! printf '%s' "$lower_content" | grep -E '^\s+-\s*["'"'"']?/dev[/:]' | grep -qE '/dev/(null|urandom|random)'; then
            violations+=("mounting /dev is not allowed (device access)")
        fi
    fi

    # Mount Docker socket — container escape via Docker API
    # In "deploy" mode, allow docker.sock (trusted built-in templates need it for
    # Portainer, Watchtower, Docker Socket Proxy, etc.)
    # In "strict" mode (user compose edits), block it entirely
    if [[ "$mode" == "strict" ]]; then
        if printf '%s' "$lower_content" | grep -qE 'docker\.sock'; then
            violations+=("mounting docker.sock is not allowed in user-edited compose files (use docker-socket-proxy template instead)")
        fi
    fi

    # Mount /boot (bootloader access)
    if printf '%s' "$lower_content" | grep -qE '^\s+-\s*["'"'"']?/boot[/:]'; then
        violations+=("mounting /boot is not allowed")
    fi

    # Mount /var/run (runtime sockets including Docker) — only in strict mode
    # In deploy mode, some templates mount /var/run/docker.sock specifically
    if [[ "$mode" == "strict" ]]; then
        if printf '%s' "$lower_content" | grep -qE '^\s+-\s*["'"'"']?/var/run[/:]'; then
            violations+=("mounting /var/run is not allowed (contains system sockets)")
        fi
    fi

    # Mount /home with write access (user data access)
    if printf '%s' "$lower_content" | grep -qE '^\s+-\s*["'"'"']?/home[/:]' | grep -vq ':ro'; then
        if printf '%s' "$lower_content" | grep -qE '^\s+-\s*["'"'"']?/home[/:]' && \
           ! printf '%s' "$lower_content" | grep -E '^\s+-\s*["'"'"']?/home[/:]' | grep -q ':ro'; then
            violations+=("mounting /home with write access is not allowed")
        fi
    fi

    # ── MEDIUM: Dangerous capabilities ──
    # NOTE: In Docker Compose YAML, cap_add and the capability name are on SEPARATE lines:
    #   cap_add:
    #     - SYS_ADMIN
    # So we must check for the capability value as a standalone line, not on the same line as cap_add.
    # We look for the capability name in list items (- SYS_ADMIN) anywhere in the file.

    # In strict mode, block all dangerous capabilities.
    # In deploy mode, allow them (trusted templates like Netdata need SYS_ADMIN/SYS_PTRACE).
    if [[ "$mode" == "strict" ]]; then
        local -a _dangerous_caps=(sys_admin sys_ptrace net_admin net_raw sys_rawio sys_module dac_override dac_read_search)
        for _cap in "${_dangerous_caps[@]}"; do
            if printf '%s' "$lower_content" | grep -qE "^\s+-\s*[\"']?${_cap}[\"']?\s*$"; then
                violations+=("${_cap^^} capability is not allowed (container escape / privilege escalation risk)")
            fi
        done
        if printf '%s' "$lower_content" | grep -qE 'cap_add:\s*\[.*\b(sys_admin|sys_ptrace|net_admin|net_raw|sys_rawio|sys_module)\b'; then
            violations+=("Dangerous capabilities detected in inline cap_add format")
        fi
    fi

    # ── MEDIUM: Security options ──
    # In strict mode, block disabling security profiles.
    # In deploy mode, allow (trusted templates like Netdata need apparmor:unconfined).
    if [[ "$mode" == "strict" ]]; then
        if printf '%s' "$lower_content" | grep -qE '^\s+-\s*[\"'"'"']?apparmor[=:]unconfined'; then
            violations+=("disabling AppArmor is not allowed")
        fi
        if printf '%s' "$lower_content" | grep -qE '^\s+-\s*[\"'"'"']?seccomp[=:]unconfined'; then
            violations+=("disabling seccomp is not allowed")
        fi
        if printf '%s' "$lower_content" | grep -qE '^\s+-\s*[\"'"'"']?label[=:]disable'; then
            violations+=("disabling SELinux labels is not allowed")
        fi
        if printf '%s' "$lower_content" | grep -qE 'security_opt:\s*\[.*\b(apparmor|seccomp)[=:]unconfined\b'; then
            violations+=("Dangerous security_opt detected in inline format")
        fi
    fi

    # ── MEDIUM: Variable substitution bypass detection ──
    # Attackers can wrap dangerous values in ${VAR:-value} to bypass text scanning.
    # Docker Compose resolves these at runtime, so we must detect them.
    # Check for patterns like: privileged: ${ANYTHING:-true}
    if printf '%s' "$lower_content" | grep -qE 'privileged:\s*\$\{[^}]*:-\s*true\s*\}'; then
        violations+=("privileged with variable substitution default detected (bypass attempt)")
    fi
    if printf '%s' "$lower_content" | grep -qE 'pid:\s*\$\{[^}]*:-\s*host\s*\}'; then
        violations+=("host PID namespace via variable substitution default detected")
    fi
    if printf '%s' "$lower_content" | grep -qE 'network_mode:\s*\$\{[^}]*:-\s*host\s*\}'; then
        violations+=("host network mode via variable substitution default detected")
    fi
    if printf '%s' "$lower_content" | grep -qE 'ipc:\s*\$\{[^}]*:-\s*host\s*\}'; then
        violations+=("host IPC namespace via variable substitution default detected")
    fi

    # ── Report results ──

    if [[ ${#violations[@]} -gt 0 ]]; then
        local details=""
        for v in "${violations[@]}"; do
            details="${details}${details:+; }$v"
        done
        _api_error 403 "Security policy violation in ${context}: ${details}"
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

    # SECURITY: If we can't resolve the hostname, BLOCK the request.
    # This prevents DNS rebinding attacks where the hostname intentionally fails
    # resolution on the first attempt but succeeds when curl fetches it.
    _api_error 400 "$context blocked: hostname '$host' could not be resolved"
    return 1
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

    # Use docker inspect with JSON output + jq for reliable parsing
    if command -v jq >/dev/null 2>&1; then
        local raw
        raw=$(timeout 5 docker inspect "$container_id" 2>/dev/null)
        [[ -z "$raw" ]] && { echo '{"name":"unknown","state":"unknown","health":"none","image":"","image_id":"","created":"","uptime_seconds":0,"ports":"","restart_count":0}'; return; }

        local now_epoch
        now_epoch=$(date +%s)

        printf '%s' "$raw" | jq -c --argjson now "$now_epoch" '
            .[0] | {
                name: (.Name | ltrimstr("/")),
                state: .State.Status,
                health: (if .State.Health then .State.Health.Status else "none" end),
                image: .Config.Image,
                image_id: (.Image | split(":") | .[1][:12] // ""),
                created: .Created,
                uptime_seconds: (if .State.Status == "running" and .State.StartedAt != "0001-01-01T00:00:00Z" then
                    ($now - (.State.StartedAt | split(".")[0] + "Z" | fromdateiso8601)) else 0 end),
                ports: ([.NetworkSettings.Ports | to_entries[] |
                    select(.value != null) | .value[] |
                    (if .HostIp == "" or .HostIp == "0.0.0.0" then "0.0.0.0" else .HostIp end) +
                    ":" + .HostPort + "->" + (.key // "")] | join(", ")),
                restart_count: (.RestartCount // 0)
            }' 2>/dev/null
        return
    fi

    # Fallback without jq — simple format
    local name state health image
    name=$(timeout 3 docker inspect --format='{{.Name}}' "$container_id" 2>/dev/null | sed 's|^/||')
    state=$(timeout 3 docker inspect --format='{{.State.Status}}' "$container_id" 2>/dev/null)
    health=$(timeout 3 docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id" 2>/dev/null)
    image=$(timeout 3 docker inspect --format='{{.Config.Image}}' "$container_id" 2>/dev/null)

    printf '{"name":"%s","state":"%s","health":"%s","image":"%s","image_id":"","created":"","uptime_seconds":0,"ports":"","restart_count":0}' \
        "$(_api_json_escape "$name")" "$(_api_json_escape "$state")" "$(_api_json_escape "$health")" "$(_api_json_escape "$image")"
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
    {"method": "GET",    "path": "/stacks/:name/compose/history/:id", "description": "View a specific compose version content"},
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

    _api_success "{\"api_version\": \"$API_VERSION\", \"framework_version\": \"${SCRIPT_VERSION:-2.0.0}\", \"docker_version\": \"$(_api_json_escape "$docker_version")\", \"compose_version\": \"$(_api_json_escape "$compose_version")\", \"compose_command\": \"$(_api_json_escape "$DOCKER_COMPOSE_CMD")\"}"
}

handle_status() {
    # PERFORMANCE: Use docker system info for counts (single command) + parallel for the rest
    local total_containers=0 running_containers=0 stopped_containers=0
    local total_images=0 total_volumes=0 total_networks=0

    # Get all counts from docker system info in one call
    if command -v jq >/dev/null 2>&1; then
        local dinfo
        dinfo=$(timeout 5 docker system info --format '{{json .}}' 2>/dev/null)
        if [[ -n "$dinfo" ]]; then
            total_containers=$(printf '%s' "$dinfo" | jq '.Containers // 0' 2>/dev/null)
            running_containers=$(printf '%s' "$dinfo" | jq '.ContainersRunning // 0' 2>/dev/null)
            stopped_containers=$(printf '%s' "$dinfo" | jq '.ContainersStopped // 0' 2>/dev/null)
            total_images=$(printf '%s' "$dinfo" | jq '.Images // 0' 2>/dev/null)
        fi
    fi

    # Volumes and networks (fast, no heavy operations)
    total_volumes=$(timeout 3 docker volume ls -q 2>/dev/null | wc -l)
    total_networks=$(timeout 3 docker network ls --format '{{.Name}}' 2>/dev/null | grep -cv '^bridge$\|^host$\|^none$') || total_networks=0

    local disk_usage
    disk_usage=$(df -h / 2>/dev/null | tail -1 | awk '{printf "{\"total\": \"%s\", \"used\": \"%s\", \"available\": \"%s\", \"percent\": \"%s\"}", $2, $3, $4, $5}')

    local load_avg mem_total mem_available
    load_avg=$(awk '{printf "[%s, %s, %s]", $1, $2, $3}' /proc/loadavg 2>/dev/null || echo "[0,0,0]")
    mem_total=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    mem_available=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)

    local uptime_seconds
    uptime_seconds=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 0)

    # Fast stack count: use docker compose ls (single command, lists all projects)
    local stacks
    stacks=($(_api_get_stacks))
    local running_stacks=0
    local active_projects
    active_projects=$(timeout 5 docker compose ls --format json 2>/dev/null | jq -r '.[].Name' 2>/dev/null) || active_projects=""
    for s in "${stacks[@]}"; do
        if echo "$active_projects" | grep -q "^${s}$" 2>/dev/null; then
            running_stacks=$(( running_stacks + 1 ))
        fi
    done

    local cpu_count
    cpu_count=$(nproc 2>/dev/null || echo 0)

    _api_success "{\"timestamp\": \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\", \"hostname\": \"$(_api_json_escape "$(hostname)")\", \"uptime_seconds\": $uptime_seconds, \"docker\": {\"containers\": {\"total\": $total_containers, \"running\": $running_containers, \"stopped\": $stopped_containers}, \"images\": $total_images, \"volumes\": $total_volumes, \"networks\": $total_networks}, \"stacks\": {\"total\": ${#stacks[@]}, \"running\": $running_stacks}, \"system\": {\"load_average\": $load_avg, \"memory_mb\": {\"total\": $mem_total, \"available\": $mem_available}, \"disk\": $disk_usage, \"cpu_count\": $cpu_count}}"
}

# Internal variant — returns JSON to stdout (used by export handler)
handle_system_info_internal() {
    local load_avg mem_total mem_available uptime_seconds cpu_count disk_usage
    load_avg=$(awk '{printf "[%s, %s, %s]", $1, $2, $3}' /proc/loadavg 2>/dev/null || echo "[0,0,0]")
    mem_total=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    mem_available=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    uptime_seconds=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 0)
    cpu_count=$(nproc 2>/dev/null || echo 0)
    disk_usage=$(df -h / 2>/dev/null | tail -1 | awk '{printf "{\"total\":\"%s\",\"used\":\"%s\",\"available\":\"%s\",\"percent\":\"%s\"}", $2, $3, $4, $5}')
    printf '{"hostname":"%s","uptime_seconds":%d,"system":{"load_average":%s,"memory_mb":{"total":%d,"available":%d},"disk":%s,"cpu_count":%d}}' \
        "$(_api_json_escape "$(hostname)")" "$uptime_seconds" "$load_avg" "$mem_total" "$mem_available" "${disk_usage:-{}}" "$cpu_count"
}

handle_health() {
    local -a results=()
    local total=0 healthy=0 unhealthy=0 stopped=0

    # Get restart threshold from config
    local _restart_threshold=5
    if [[ -f "$BASE_DIR/.data/config.json" ]] && command -v jq >/dev/null 2>&1; then
        local _rt
        _rt=$(jq -r '.thresholds.restart_threshold // 5' "$BASE_DIR/.data/config.json" 2>/dev/null)
        [[ "$_rt" =~ ^[0-9]+$ ]] && _restart_threshold="$_rt"
    fi

    # Single docker inspect for ALL containers — include restart count
    local inspect_data=""
    local all_cids
    all_cids=$(timeout 5 docker ps -a -q 2>/dev/null | tr '\n' ' ')
    if [[ -n "$all_cids" ]] && command -v jq >/dev/null 2>&1; then
        inspect_data=$(timeout 10 docker inspect $all_cids 2>/dev/null | jq -r '.[] | "\(.Name | ltrimstr("/"))\t\(.State.Status)\t\(if .State.Health then .State.Health.Status else "none" end)\t\(.RestartCount // 0)"' 2>/dev/null) || inspect_data=""
    fi

    while IFS=$'\t' read -r name state health restart_count; do
        [[ -z "$name" ]] && continue
        name="${name#/}"
        total=$(( total + 1 ))

        if [[ "$state" != "running" ]]; then
            stopped=$(( stopped + 1 ))
            _fire_notifications "container_stopped" "container=$name" "status=stopped" 2>/dev/null
        elif [[ "$health" == "unhealthy" ]]; then
            unhealthy=$(( unhealthy + 1 ))
            _fire_notifications "container_unhealthy" "container=$name" "status=unhealthy" 2>/dev/null
        else
            healthy=$(( healthy + 1 ))
        fi

        # Check restart threshold
        if [[ "${restart_count:-0}" -ge "$_restart_threshold" ]] 2>/dev/null; then
            _fire_notifications "container_unhealthy" "container=$name" "status=restarting (${restart_count}x)"  2>/dev/null
        fi

        results+=("{\"name\": \"$(_api_json_escape "$name")\", \"state\": \"$state\", \"health\": \"$health\", \"restart_count\": ${restart_count:-0}}")
    done <<< "$inspect_data"

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

# Internal variant — returns JSON to stdout (used by export handler)
handle_health_internal() {
    local -a results=()
    local total=0 healthy=0 unhealthy=0 stopped=0
    local inspect_data="" all_cids
    all_cids=$(timeout 5 docker ps -a -q 2>/dev/null | tr '\n' ' ')
    if [[ -n "$all_cids" ]] && command -v jq >/dev/null 2>&1; then
        inspect_data=$(timeout 10 docker inspect $all_cids 2>/dev/null | jq -r '.[] | "\(.Name | ltrimstr("/"))\t\(.State.Status)\t\(if .State.Health then .State.Health.Status else "none" end)"' 2>/dev/null) || inspect_data=""
    fi
    while IFS=$'\t' read -r name state health; do
        [[ -z "$name" ]] && continue
        name="${name#/}"; total=$(( total + 1 ))
        if [[ "$state" != "running" ]]; then stopped=$(( stopped + 1 ))
        elif [[ "$health" == "unhealthy" ]]; then unhealthy=$(( unhealthy + 1 ))
        else healthy=$(( healthy + 1 )); fi
        results+=("{\"name\":\"$(_api_json_escape "$name")\",\"state\":\"$state\",\"health\":\"$health\"}")
    done <<< "$inspect_data"
    local overall="healthy"
    (( unhealthy >= 3 )) && overall="critical"
    (( unhealthy > 0 && unhealthy < 3 )) && overall="degraded"
    local cj; cj=$(printf '%s,' "${results[@]}"); cj="[${cj%,}]"
    printf '{"status":"%s","summary":{"total":%d,"healthy":%d,"unhealthy":%d,"stopped":%d},"containers":%s}' \
        "$overall" "$total" "$healthy" "$unhealthy" "$stopped" "$cj"
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
        service_count=$(grep -c '^\s\+[a-zA-Z]' "$compose_file" 2>/dev/null) || service_count=0

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

    # SECURITY: Scan compose content for dangerous Docker features.
    # Use "deploy" mode if the stack was created from a trusted template (has .dcs-trusted-templates).
    # This allows template-required capabilities (docker.sock, label:disable) to persist through edits.
    local _scan_mode="strict"
    [[ -f "$COMPOSE_DIR/$stack/.dcs-trusted-templates" ]] && _scan_mode="deploy"
    if ! _api_scan_compose_security "$content" "compose validation for $stack" "$_scan_mode"; then
        return
    fi

    # Normalize ${SECRETS.KEY} → ${SECRETS_KEY} for validation
    content=$(printf '%s' "$content" | _normalize_secrets_syntax)

    local tmpfile
    tmpfile=$(mktemp /tmp/dcs-compose-validate-XXXXXX.yml)
    printf '%s' "$content" > "$tmpfile"

    # Normalize ${SECRETS.KEY} in stack .env too (docker compose reads it)
    local _stack_env="$COMPOSE_DIR/$stack/.env"
    if [[ -f "$_stack_env" ]] && grep -q 'SECRETS\.' "$_stack_env" 2>/dev/null; then
        sed -i 's/${SECRETS\.\([A-Za-z0-9_-]*\)}/${SECRETS_\1}/g' "$_stack_env"
    fi

    local env_args=()
    [[ -f "$_stack_env" ]] && env_args=(--env-file "$_stack_env")

    # Inject decrypted SECRETS_* as env vars for validation
    local validation_output
    local valid=true
    validation_output=$(
        eval "$(_secrets_env_exports "$tmpfile")"
        $DOCKER_COMPOSE_CMD -f "$tmpfile" "${env_args[@]}" config 2>&1
    ) || valid=false
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

    # Normalize ${SECRETS.KEY} → ${SECRETS_KEY} (dots invalid in compose var names)
    content=$(printf '%s' "$content" | _normalize_secrets_syntax)

    # SECURITY: Scan compose content for dangerous Docker features.
    # Use "deploy" mode for stacks deployed from trusted templates.
    local _scan_mode="strict"
    [[ -f "$COMPOSE_DIR/$stack/.dcs-trusted-templates" ]] && _scan_mode="deploy"
    if ! _api_scan_compose_security "$content" "compose save for $stack" "$_scan_mode"; then
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

    # Inject decrypted SECRETS_* as env vars for validation
    local validation_output
    validation_output=$(
        eval "$(_secrets_env_exports "$tmpfile")"
        $DOCKER_COMPOSE_CMD -f "$tmpfile" "${env_args[@]}" config 2>&1
    )
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

    # Write new content (atomic: write to temp then rename to prevent corruption)
    local tmpwrite="${compose_file}.tmp.$$"
    printf '%s' "$content" > "$tmpwrite" 2>/dev/null && mv -f "$tmpwrite" "$compose_file" 2>/dev/null || {
        rm -f "$tmpwrite" 2>/dev/null
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
    local _hook_ctx="{\"stack\":\"$stack\",\"action\":\"$action\"}"

    case "$action" in
        start)
            _run_plugin_hooks "pre-start" "$_hook_ctx"
            ( _compose_with_secrets "$compose_file" "$env_file" up -d --remove-orphans >/dev/null 2>&1 ) &
            _run_plugin_hooks "post-start" "$_hook_ctx"
            output="Starting $stack (background)"
            ;;
        stop)
            _run_plugin_hooks "pre-stop" "$_hook_ctx"
            ( $DOCKER_COMPOSE_CMD "${compose_args[@]}" down --remove-orphans --timeout 15 >/dev/null 2>&1 ) &
            _run_plugin_hooks "post-stop" "$_hook_ctx"
            _fire_notifications "stack_down" "stack=$stack" "status=stopped"
            output="Stopping $stack (background)"
            ;;
        restart)
            _run_plugin_hooks "pre-stop" "$_hook_ctx"
            ( $DOCKER_COMPOSE_CMD "${compose_args[@]}" down --remove-orphans --timeout 15 >/dev/null 2>&1
              _compose_with_secrets "$compose_file" "$env_file" up -d --remove-orphans >/dev/null 2>&1 ) &
            _run_plugin_hooks "post-start" "$_hook_ctx"
            output="Restarting $stack (background)"
            ;;
        update)
            _run_plugin_hooks "pre-update" "$_hook_ctx"
            # Record pre-update IDs
            local -A pre_ids=()
            while IFS= read -r img; do
                [[ -z "$img" ]] && continue
                local cid
                cid=$(docker image inspect --format='{{.Id}}' "$img" 2>/dev/null)
                [[ -n "$cid" ]] && pre_ids["$img"]="$cid"
            done < <(_compose_with_secrets "$compose_file" "$env_file" config 2>/dev/null | grep 'image:' | awk '{print $2}' | sort -u)

            # Pull
            output=$(_compose_with_secrets "$compose_file" "$env_file" pull 2>&1) || success=false

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
                output+=($(_compose_with_secrets "$compose_file" "$env_file" up -d --remove-orphans 2>&1)) || success=false
            fi

            local changes_json
            changes_json=$(printf '"%s",' "${changes[@]}")
            changes_json="[${changes_json%,}]"

            _run_plugin_hooks "post-update" "$_hook_ctx"
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

    # Load registry cache for staleness override
    local _ic="$BASE_DIR/.data/image-update-cache.json"
    local -A _ic_cache=()
    if [[ -f "$_ic" ]]; then
        while IFS='=' read -r k v; do
            [[ -n "$k" ]] && _ic_cache["$k"]="$v"
        done < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' "$_ic" 2>/dev/null)
    fi

    local -a entries=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS='|' read -r repo tag id created size <<< "$line"

        local age_days=-1
        local staleness="unknown"
        if [[ -n "$created" ]] && [[ "$created" != "<none>" ]]; then
            local created_clean="${created% [A-Z]*}"
            local img_epoch
            img_epoch=$(date -d "$created_clean" '+%s' 2>/dev/null || date -d "$created" '+%s' 2>/dev/null || echo 0)
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

        # Override with registry cache — confirmed latest = current, confirmed update = stale
        local full_image="${repo}:${tag}"
        local update_available="null"
        if [[ "${_ic_cache[$full_image]:-}" == "false" ]]; then
            staleness="current"
            update_available="false"
        elif [[ "${_ic_cache[$full_image]:-}" == "true" ]]; then
            staleness="stale"
            update_available="true"
        fi

        if [[ "$stale_only" == "true" ]] && [[ "$staleness" != "stale" ]]; then
            continue
        fi

        entries+=("{\"repository\": \"$(_api_json_escape "$repo")\", \"tag\": \"$(_api_json_escape "$tag")\", \"id\": \"$(_api_json_escape "$id")\", \"created\": \"$(_api_json_escape "$created")\", \"size\": \"$(_api_json_escape "$size")\", \"age_days\": $age_days, \"staleness\": \"$staleness\", \"update_available\": $update_available}")
    done < <(docker images --format '{{.Repository}}|{{.Tag}}|{{.ID}}|{{.CreatedAt}}|{{.Size}}' 2>/dev/null)

    local json
    json=$(printf '%s,' "${entries[@]}")
    json="[${json%,}]"

    _api_success "{\"total\": ${#entries[@]}, \"images\": $json}"
}

handle_containers() {
    # PERFORMANCE: Single docker command to get all container data as JSON
    # Then use jq to transform — fast, reliable, no delimiter issues
    local raw_json
    raw_json=$(timeout 10 docker ps -a --format '{{json .}}' 2>/dev/null)

    if [[ -z "$raw_json" ]]; then
        _api_success '{"total": 0, "containers": []}'
        return
    fi

    if command -v jq >/dev/null 2>&1; then
        local now_epoch
        now_epoch=$(date +%s)

        # Stats cache — refreshed in background each call, read via jq --slurpfile
        local _stats_cache="$BASE_DIR/.data/container-stats-cache.json"
        [[ ! -f "$_stats_cache" ]] && echo '{}' > "$_stats_cache"

        # Refresh cache in background for next request
        (
            mkdir -p "$BASE_DIR/.data" 2>/dev/null
            local _sl
            _sl=$(docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemPerc}}' 2>/dev/null | awk -F'|' '{
                gsub(/%/, "", $2); gsub(/%/, "", $3); gsub(/^ +| +$/, "", $1); gsub(/^ +| +$/, "", $2); gsub(/^ +| +$/, "", $3)
                if (NR > 1) printf ","
                printf "\"%s\":{\"cpu\":%s,\"mem\":%s}", $1, ($2+0), ($3+0)
            }')
            [[ -n "$_sl" ]] && printf '{%s}' "$_sl" > "$_stats_cache"
        ) &

        # Build containers JSON — read stats cache via --slurpfile (avoids shell arg size limits)
        local containers_json
        containers_json=$(printf '%s\n' "$raw_json" | jq -s --argjson now "$now_epoch" --slurpfile stats "$_stats_cache" '
            ($stats[0] // {}) as $st |
            [.[] | {
                name: .Names,
                state: .State,
                health: (if .Status | test("healthy") then "healthy"
                         elif .Status | test("unhealthy") then "unhealthy"
                         elif .Status | test("health:") then "starting"
                         else "none" end),
                image: .Image,
                image_id: (.ID[:12] // ""),
                created: .CreatedAt,
                uptime_seconds: (if .State != "running" then 0
                    else ((.RunningFor // "0") | try (
                        (match("[0-9]+").string | tonumber) * (
                            if test("second") then 1
                            elif test("minute") then 60
                            elif test("hour") then 3600
                            elif test("day") then 86400
                            elif test("week") then 604800
                            elif test("month") then 2592000
                            else 0 end)
                    ) catch 0) end),
                ports: .Ports,
                restart_count: 0,
                cpu_percent: ($st[.Names].cpu // null),
                mem_percent: ($st[.Names].mem // null)
            }]' 2>/dev/null)

        if [[ -n "$containers_json" ]]; then
            local total
            total=$(printf '%s' "$containers_json" | jq 'length' 2>/dev/null)
            _api_success "{\"total\": ${total:-0}, \"containers\": $containers_json}"
            return
        fi
    fi

    # Fallback: per-container inspect (slower but always works)
    local -a entries=()
    while IFS= read -r cid; do
        [[ -z "$cid" ]] && continue
        entries+=("$(_api_container_json "$cid")")
    done < <(docker ps -a -q 2>/dev/null)

    local json
    if [[ ${#entries[@]} -gt 0 ]]; then
        json=$(printf '%s,' "${entries[@]}")
        json="[${json%,}]"
    else
        json="[]"
    fi
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
    # Return full configuration — sensitive values (tokens, certs) excluded
    local config="{"
    # General
    config+="\"environment\": \"${ENVIRONMENT:-production}\","
    config+="\"server_name\": \"$(_api_json_escape "${SERVER_NAME:-Docker Server}")\","
    config+="\"server_subtitle\": \"$(_api_json_escape "${SERVER_SUBTITLE:-Docker Compose Skeleton}")\","
    config+="\"timezone\": \"${TZ:-UTC}\","
    config+="\"puid\": ${PUID:-1000},"
    config+="\"pgid\": ${PGID:-1000},"
    config+="\"proxy_domain\": \"$(_api_json_escape "${PROXY_DOMAIN:-}")\","
    config+="\"compose_dir\": \"$(_api_json_escape "$COMPOSE_DIR")\","
    config+="\"app_data_dir\": \"$(_api_json_escape "$APP_DATA_DIR")\","
    config+="\"base_dir\": \"$(_api_json_escape "$BASE_DIR")\","
    config+="\"compose_command\": \"$(_api_json_escape "$DOCKER_COMPOSE_CMD")\","
    # Startup/Shutdown
    config+="\"skip_healthcheck_wait\": ${SKIP_HEALTHCHECK_WAIT:-false},"
    config+="\"continue_on_failure\": ${CONTINUE_ON_FAILURE:-true},"
    config+="\"remove_volumes_on_stop\": ${REMOVE_VOLUMES_ON_STOP:-false},"
    config+="\"show_banners\": ${SHOW_BANNERS:-true},"
    config+="\"show_system_info\": ${SHOW_SYSTEM_INFO:-true},"
    config+="\"service_start_delay\": ${SERVICE_START_DELAY:-0},"
    config+="\"service_stop_delay\": ${SERVICE_STOP_DELAY:-0},"
    # Docker
    config+="\"docker_stacks\": \"$(_api_json_escape "${DOCKER_STACKS:-}")\","
    config+="\"docker_timeout\": ${DOCKER_TIMEOUT:-120},"
    config+="\"force_recreate\": ${FORCE_RECREATE:-false},"
    config+="\"remove_orphaned_containers\": ${REMOVE_ORPHANED_CONTAINERS:-true},"
    # Logging
    config+="\"log_level\": \"${LOG_LEVEL:-INFO}\","
    config+="\"enable_colors\": ${ENABLE_COLORS:-true},"
    config+="\"color_mode\": \"${COLOR_MODE:-auto}\","
    config+="\"color_theme\": \"${COLOR_THEME:-dark}\","
    config+="\"verbose_mode\": ${VERBOSE_MODE:-false},"
    config+="\"enable_log_date\": ${ENABLE_LOG_DATE:-true},"
    config+="\"enable_milliseconds\": ${ENABLE_MILLISECONDS:-false},"
    config+="\"log_date_format\": \"$(_api_json_escape "${LOG_DATE_FORMAT:-%Y-%m-%d %H:%M:%S}")\","
    config+="\"enable_log_mood\": ${ENABLE_LOG_MOOD:-true},"
    config+="\"enable_log_pid\": ${ENABLE_LOG_PID:-false},"
    config+="\"enable_log_hostname\": ${ENABLE_LOG_HOSTNAME:-false},"
    config+="\"log_max_size\": \"${LOG_MAX_SIZE:-10M}\","
    config+="\"log_backup_count\": ${LOG_BACKUP_COUNT:-12},"
    # Image Updates
    config+="\"aggressive_image_prune\": ${AGGRESSIVE_IMAGE_PRUNE:-false},"
    config+="\"update_notification\": ${UPDATE_NOTIFICATION:-true},"
    # Notifications
    config+="\"ntfy_configured\": $([[ -n "${NTFY_URL:-}" ]] && echo true || echo false),"
    config+="\"ntfy_url\": \"$(_api_json_escape "${NTFY_URL:-}")\","
    config+="\"ntfy_topic\": \"$(_api_json_escape "${NTFY_TOPIC:-}")\","
    config+="\"ntfy_priority\": \"$(_api_json_escape "${NTFY_PRIORITY:-default}")\","
    config+="\"notification_stacks\": \"$(_api_json_escape "${NOTIFICATION_STACKS:-}")\","
    # API
    config+="\"api_enabled\": ${API_ENABLED:-true},"
    config+="\"api_port\": $API_PORT,"
    config+="\"api_bind\": \"$API_BIND\","
    config+="\"api_auth_enabled\": ${API_AUTH_ENABLED:-true},"
    config+="\"api_rate_limit\": ${API_RATE_LIMIT:-600},"
    config+="\"api_rate_window\": ${API_RATE_WINDOW:-60},"
    config+="\"api_token_expiry\": ${API_TOKEN_EXPIRY:-86400},"
    config+="\"api_single_session\": ${API_SINGLE_SESSION:-false},"
    config+="\"api_cors_origins\": \"$(_api_json_escape "${API_CORS_ORIGINS:-}")\","
    # Traefik/DNS (tokens excluded)
    config+="\"traefik_domain\": \"$(_api_json_escape "${TRAEFIK_DOMAIN:-}")\","
    config+="\"traefik_acme_email\": \"$(_api_json_escape "${TRAEFIK_ACME_EMAIL:-}")\","
    config+="\"cf_dns_api_token_set\": $([[ -n "${CF_DNS_API_TOKEN:-}" ]] && echo true || echo false),"
    config+="\"ddns_enabled\": ${DDNS_ENABLED:-false},"
    config+="\"ddns_interval\": ${DDNS_INTERVAL:-300},"
    # Health
    config+="\"enable_post_startup_health_check\": ${ENABLE_POST_STARTUP_HEALTH_CHECK:-true},"
    config+="\"health_check_delay\": ${HEALTH_CHECK_DELAY:-10},"
    config+="\"critical_containers\": \"$(_api_json_escape "${CRITICAL_CONTAINERS:-}")\","
    config+="\"important_containers\": \"$(_api_json_escape "${IMPORTANT_CONTAINERS:-}")\","
    # Features
    config+="\"metrics_enabled\": ${METRICS_ENABLED:-true},"
    config+="\"metrics_collect_interval\": ${METRICS_COLLECT_INTERVAL:-60},"
    config+="\"rollback_enabled\": ${ROLLBACK_ENABLED:-true},"
    config+="\"scheduler_enabled\": ${SCHEDULER_ENABLED:-true},"
    config+="\"plugins_enabled\": ${PLUGINS_ENABLED:-true},"
    config+="\"plugins_hooks_enabled\": ${PLUGINS_HOOKS_ENABLED:-true},"
    config+="\"health_score_enabled\": ${HEALTH_SCORE_ENABLED:-true},"
    # Backup
    config+="\"backup_source_dir\": \"$(_api_json_escape "${BACKUP_SOURCE_DIR:-}")\","
    config+="\"backup_dest_dir\": \"$(_api_json_escape "${BACKUP_DEST_DIR:-}")\","
    config+="\"backup_retention_count\": ${BACKUP_RETENTION_COUNT:-7}"
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

    _api_success "{\"hostname\": \"$(_api_json_escape "$(hostname)")\", \"kernel\": \"$(_api_json_escape "$kernel_version")\", \"cpu_count\": $cpu_count, \"memory_total_mb\": $mem_total_mb, \"swap_total_mb\": $swap_total_mb, \"docker_version\": \"$docker_version\", \"docker_disk_usage\": $df_json}"
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
            /|/boot|/boot/*|/sys/*|/proc/*|/dev/*|/run/*|/snap/*) continue ;;
        esac
        # Skip mergerfs/overlay mounts (device paths contain colons)
        [[ "$device" == *":"* ]] && continue
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

    # Validate driver (only allow known Docker network drivers)
    case "$driver" in
        bridge|host|overlay|macvlan|ipvlan|none) ;;
        *)
            _api_error 400 "Invalid network driver. Allowed: bridge, host, overlay, macvlan, ipvlan, none"
            return
            ;;
    esac

    # Validate subnet (CIDR notation)
    if [[ -n "$subnet" && ! "$subnet" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        _api_error 400 "Invalid subnet format. Use CIDR notation (e.g., 172.20.0.0/16)"
        return
    fi

    # Validate gateway (IPv4 address)
    if [[ -n "$gateway" && ! "$gateway" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        _api_error 400 "Invalid gateway format. Use IPv4 address (e.g., 172.20.0.1)"
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
    output=$(docker network rm -- "$name" 2>&1) || {
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

    # SECURITY: Validate container name to prevent Docker flag injection
    _api_validate_resource_name "$container" "container" || return

    local output
    # SECURITY: Use -- to separate flags from positional arguments
    output=$(docker network connect -- "$name" "$container" 2>&1) || {
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

    # SECURITY: Validate container name to prevent Docker flag injection
    _api_validate_resource_name "$container" "container" || return

    local output
    output=$(docker network disconnect -- "$name" "$container" 2>&1) || {
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
    output=$(docker volume rm -- "$name" 2>&1) || {
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
            # SECURITY: Use -F (fixed string) not regex to prevent ReDoS attacks
            content=$(printf '%s\n' "$content" | grep -iF "$search_filter" 2>/dev/null || true)
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

    # Count log levels — grep -c returns exit code 1 when count is 0,
    # so use "|| true" to prevent the fallback from appending a second "0"
    local errors warnings successes infos debugs steps timings criticals
    errors=$(grep -c '\[ERROR\]' "$log_file" 2>/dev/null) || errors=0
    criticals=$(grep -c '\[CRITICAL\]' "$log_file" 2>/dev/null) || criticals=0
    warnings=$(grep -c '\[WARNING\]' "$log_file" 2>/dev/null) || warnings=0
    successes=$(grep -c '\[SUCCESS\]' "$log_file" 2>/dev/null) || successes=0
    infos=$(grep -c '\[INFO\]' "$log_file" 2>/dev/null) || infos=0
    debugs=$(grep -c '\[DEBUG\]' "$log_file" 2>/dev/null) || debugs=0
    steps=$(grep -c '\[STEP' "$log_file" 2>/dev/null) || steps=0
    timings=$(grep -c '\[TIMING\]' "$log_file" 2>/dev/null) || timings=0

    local sessions
    sessions=$(grep -c 'Session Started' "$log_file" 2>/dev/null) || sessions=0

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

    # NOTE: Do NOT touch .setup-complete here — that's done by /setup/complete
    # (the final step of the wizard). Marking it here would block steps 3-5.

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
        # SECURITY: Perform a dummy hash to prevent username enumeration via timing.
        # Without this, nonexistent users return immediately while existing users
        # take ~100ms+ for PBKDF2, allowing attackers to discover valid usernames.
        _api_hash_password_v2 "0000000000000000000000000000000000000000" "dummy_password" >/dev/null 2>&1
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

    # ── TOTP 2FA check ──
    # If user has TOTP enabled, don't issue a real token yet.
    # Issue a temporary token with totp_pending=true that only works for /auth/totp/validate.
    local totp_enabled
    totp_enabled=$(echo "$user_record" | jq -r '.totp_enabled // false' 2>/dev/null)
    if [[ "$totp_enabled" == "true" ]]; then
        local totp_token
        totp_token=$(_api_generate_token)
        # Store as pending token (5 minute expiry for TOTP entry)
        local now; now=$(_api_now_epoch)
        local totp_expires=$(( now + 300 ))
        local tokens; tokens=$(_api_read_auth_file "tokens.json")
        if command -v jq >/dev/null 2>&1; then
            local new_tokens
            new_tokens=$(echo "$tokens" | jq \
                --arg t "$totp_token" --arg u "$username" --arg r "$role" \
                --argjson e "$totp_expires" \
                '. + [{"token": $t, "username": $u, "role": $r, "expires_at": $e, "totp_pending": true}]' 2>/dev/null)
            _api_write_auth_file "tokens.json" "$new_tokens"
        fi
        _api_audit_log "$client_ip" "LOGIN_TOTP_PENDING" "$username" "Password OK, awaiting 2FA"
        _api_success "{\"success\": true, \"requires_totp\": true, \"totp_token\": \"$totp_token\", \"message\": \"Enter your 2FA code to complete login.\"}"
        return
    fi

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

# =============================================================================
# TOTP 2FA ENDPOINTS
# =============================================================================

# POST /auth/totp/setup — Generate TOTP secret and return QR URI (not yet enabled)
handle_totp_setup() {
    local body="$1"
    _api_init_auth_dir

    # Get current user from auth
    [[ -z "${AUTH_USERNAME:-}" ]] && { _api_error 401 "Authentication required"; return; }

    # Check if already enabled
    local user_record
    user_record=$(_api_get_user "$AUTH_USERNAME")
    local already_enabled
    already_enabled=$(echo "$user_record" | jq -r '.totp_enabled // false' 2>/dev/null)
    if [[ "$already_enabled" == "true" ]]; then
        _api_error 409 "TOTP is already enabled for this account. Disable it first to regenerate."
        return
    fi

    # Generate secret
    local totp_output
    totp_output=$(_api_totp_generate_secret)
    local hex_secret b32_secret
    hex_secret=$(echo "$totp_output" | head -1)
    b32_secret=$(echo "$totp_output" | tail -1)

    if [[ -z "$hex_secret" || -z "$b32_secret" ]]; then
        _api_error 500 "Failed to generate TOTP secret"
        return
    fi

    # Store secret but don't enable yet (user must verify first)
    _api_totp_update_user "$AUTH_USERNAME" "$hex_secret" "false"

    # Build QR URI
    local uri
    uri=$(_api_totp_uri "$b32_secret" "$AUTH_USERNAME" "DCS")

    _api_success "{\"secret\": \"$b32_secret\", \"uri\": \"$(_api_json_escape "$uri")\", \"message\": \"Scan the QR code with your authenticator app, then verify with a code to enable 2FA.\"}"
}

# POST /auth/totp/verify — Verify a TOTP code and enable 2FA
handle_totp_verify() {
    local body="$1"
    _api_init_auth_dir

    [[ -z "${AUTH_USERNAME:-}" ]] && { _api_error 401 "Authentication required"; return; }

    local code
    if command -v jq >/dev/null 2>&1; then
        code=$(printf '%s' "$body" | jq -r '.code // empty' 2>/dev/null)
    else
        code=$(echo "$body" | sed -n 's/.*"code" *: *"\([^"]*\)".*/\1/p')
    fi

    [[ -z "$code" ]] && { _api_error 400 "Missing 'code' field (6-digit TOTP code)"; return; }

    # Get the stored (but not yet enabled) secret
    local user_record
    user_record=$(_api_get_user "$AUTH_USERNAME")
    local hex_secret
    hex_secret=$(echo "$user_record" | jq -r '.totp_secret // empty' 2>/dev/null)

    [[ -z "$hex_secret" ]] && { _api_error 400 "No TOTP secret set up. Call /auth/totp/setup first."; return; }

    # Verify the code
    if _api_totp_verify "$hex_secret" "$code"; then
        # Enable TOTP
        _api_totp_update_user "$AUTH_USERNAME" "$hex_secret" "true"
        _api_audit_log "${SOCAT_PEERADDR:-unknown}" "TOTP_ENABLED" "$AUTH_USERNAME" "2FA enabled"
        _api_success "{\"success\": true, \"message\": \"Two-factor authentication is now enabled.\"}"
    else
        _api_error 401 "Invalid TOTP code. Make sure your authenticator app is synced."
    fi
}

# POST /auth/totp/disable — Disable 2FA (requires password confirmation)
handle_totp_disable() {
    local body="$1"
    _api_init_auth_dir

    [[ -z "${AUTH_USERNAME:-}" ]] && { _api_error 401 "Authentication required"; return; }

    local password
    if command -v jq >/dev/null 2>&1; then
        password=$(printf '%s' "$body" | jq -r '.password // empty' 2>/dev/null)
    fi

    [[ -z "$password" ]] && { _api_error 400 "Password required to disable 2FA"; return; }

    # Verify password
    local user_record
    user_record=$(_api_get_user "$AUTH_USERNAME")
    local stored_hash stored_salt hash_version
    stored_hash=$(echo "$user_record" | jq -r '.password_hash' 2>/dev/null)
    stored_salt=$(echo "$user_record" | jq -r '.salt' 2>/dev/null)
    hash_version=$(echo "$user_record" | jq -r '.hash_version // 1' 2>/dev/null)

    if ! _api_verify_password "$password" "$stored_hash" "$stored_salt" "$hash_version"; then
        _api_error 401 "Incorrect password"
        return
    fi

    # Disable TOTP
    _api_totp_update_user "$AUTH_USERNAME" "" "false"
    _api_audit_log "${SOCAT_PEERADDR:-unknown}" "TOTP_DISABLED" "$AUTH_USERNAME" "2FA disabled"
    _api_success "{\"success\": true, \"message\": \"Two-factor authentication has been disabled.\"}"
}

# POST /auth/totp/validate — Validate TOTP code during login (second step)
handle_totp_validate() {
    local body="$1"
    _api_init_auth_dir

    local totp_token code
    if command -v jq >/dev/null 2>&1; then
        totp_token=$(printf '%s' "$body" | jq -r '.totp_token // empty' 2>/dev/null)
        code=$(printf '%s' "$body" | jq -r '.code // empty' 2>/dev/null)
    fi

    [[ -z "$totp_token" ]] && { _api_error 400 "Missing 'totp_token' field"; return; }
    [[ -z "$code" ]] && { _api_error 400 "Missing 'code' field (6-digit TOTP code)"; return; }

    # Validate the temporary TOTP token
    local tokens
    tokens=$(_api_read_auth_file "tokens.json")
    local now
    now=$(_api_now_epoch)
    local record
    record=$(echo "$tokens" | jq -r --arg t "$totp_token" --argjson n "$now" \
        '.[] | select(.token == $t and .expires_at > $n and .totp_pending == true)' 2>/dev/null)

    [[ -z "$record" ]] && { _api_error 401 "Invalid or expired TOTP token"; return; }

    local username role
    username=$(echo "$record" | jq -r '.username' 2>/dev/null)
    role=$(echo "$record" | jq -r '.role' 2>/dev/null)

    # Get user's TOTP secret
    local user_record
    user_record=$(_api_get_user "$username")
    local hex_secret
    hex_secret=$(echo "$user_record" | jq -r '.totp_secret // empty' 2>/dev/null)

    [[ -z "$hex_secret" ]] && { _api_error 500 "TOTP secret not found for user"; return; }

    # Verify the code
    if _api_totp_verify "$hex_secret" "$code"; then
        # Remove the temporary TOTP token
        local new_tokens
        new_tokens=$(echo "$tokens" | jq --arg t "$totp_token" '[.[] | select(.token != $t)]' 2>/dev/null)
        _api_write_auth_file "tokens.json" "$new_tokens"

        # Issue a real session token
        local real_token
        real_token=$(_api_generate_token)
        _api_store_token "$real_token" "$username" "$role"

        _api_audit_log "${SOCAT_PEERADDR:-unknown}" "TOTP_LOGIN_OK" "$username" "2FA verified"
        _api_success "{\"success\": true, \"token\": \"$real_token\", \"username\": \"$(_api_json_escape "$username")\", \"role\": \"$(_api_json_escape "$role")\"}"
    else
        _api_audit_log "${SOCAT_PEERADDR:-unknown}" "TOTP_LOGIN_FAIL" "$username" "Invalid 2FA code"
        _api_error 401 "Invalid TOTP code"
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

    # Remove factory-reset-pending if it exists from a previous reset
    rm -f "$auth_dir/.factory-reset-pending" 2>/dev/null

    # Files to remove (auth state + setup marker — full clean slate)
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

        # Remove App-Data directories in background (handles root-owned files via docker alpine)
        (
            if [[ -d "$stacks_dir" ]]; then
                for d in "$stacks_dir"/*/; do
                    [[ -d "$d" && -d "$d/App-Data" ]] || continue
                    # Try normal rm first, then use docker for root-owned files
                    rm -rf "$d/App-Data" 2>/dev/null
                    if [[ -d "$d/App-Data" ]]; then
                        docker run --rm -v "$d/App-Data:/cleanup" alpine rm -rf /cleanup 2>/dev/null || true
                        rm -rf "$d/App-Data" 2>/dev/null || true
                    fi
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

        # Remove compose backup files (.bak and .bak.TIMESTAMP)
        if [[ -d "$stacks_dir" ]]; then
            find "$stacks_dir" -name 'docker-compose.yml.bak*' -delete 2>/dev/null || true
        fi

        # Remove compose history snapshots
        rm -rf "$BASE_DIR/.compose-history" 2>/dev/null || true

        # Remove rollback snapshots
        rm -rf "$BASE_DIR/.data/rollback" 2>/dev/null || true

        # Remove system snapshots
        rm -rf "$BASE_DIR/.snapshots" 2>/dev/null || true

        # Remove root .env backup
        rm -f "$BASE_DIR/.env.bak" 2>/dev/null || true

        # Remove per-user dashboard layouts and profiles
        rm -rf "$auth_dir/dashboard-layouts" 2>/dev/null || true
        rm -rf "$auth_dir/profiles" 2>/dev/null || true

        # Remove automation rules data
        rm -rf "$BASE_DIR/.data/automations" 2>/dev/null || true

        # Remove notification rules and history
        rm -f "$BASE_DIR/.data/notification-rules.json" 2>/dev/null || true
        rm -f "$BASE_DIR/.data/notification-history.jsonl" 2>/dev/null || true

        # Remove metrics history
        rm -rf "$BASE_DIR/.data/metrics" 2>/dev/null || true

        # Remove backup status
        rm -f "$auth_dir/backup-status.json" 2>/dev/null || true

        # Clean up Cloudflare DNS records created by DCS (background, non-fatal)
        local _cf_token="${CF_DNS_API_TOKEN:-}"
        local _cf_domain="${TRAEFIK_DOMAIN:-}"
        [[ -z "$_cf_token" ]] && _cf_token=$(grep -m1 '^CF_DNS_API_TOKEN=' "$COMPOSE_DIR"/*/".env" "$BASE_DIR/.env" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        [[ -z "$_cf_domain" ]] && _cf_domain=$(grep -m1 '^TRAEFIK_DOMAIN=' "$COMPOSE_DIR"/*/".env" "$BASE_DIR/.env" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        if [[ -n "$_cf_token" && -n "$_cf_domain" ]] && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
            (
                local cf_api="https://api.cloudflare.com/client/v4"
                local zone_id=""
                [[ -f "$auth_dir/.cf-zone-cache" ]] && zone_id=$(sed -n '2p' "$auth_dir/.cf-zone-cache" 2>/dev/null)
                [[ -z "$zone_id" ]] && zone_id=$(curl -s --max-time 10 -H "Authorization: Bearer $_cf_token" "$cf_api/zones?name=$_cf_domain&status=active" 2>/dev/null | jq -r '.result[0].id // empty')
                [[ -z "$zone_id" ]] && exit 0
                # Delete DNS records with "DCS" or "Auto-created by DCS" in comment
                # Paginate through all records (100 per page)
                local _cf_log="$auth_dir/cf-cleanup.log"
                local page=1 deleted=0
                while true; do
                    local records
                    records=$(curl -s --max-time 15 -H "Authorization: Bearer $_cf_token" \
                        "$cf_api/zones/$zone_id/dns_records?per_page=100&page=$page" 2>/dev/null)
                    local count
                    count=$(printf '%s' "$records" | jq '.result | length' 2>/dev/null) || count=0
                    [[ "$count" -eq 0 ]] && break

                    printf '%s' "$records" | jq -r '.result[] | select(.comment != null and (.comment | test("DCS"))) | "\(.id) \(.name)"' 2>/dev/null | while read -r rid rname; do
                        [[ -z "$rid" ]] && continue
                        curl -s --max-time 10 -X DELETE -H "Authorization: Bearer $_cf_token" \
                            "$cf_api/zones/$zone_id/dns_records/$rid" >/dev/null 2>&1
                        echo "$(date -Iseconds) DELETED $rname ($rid)" >> "$_cf_log" 2>/dev/null
                        deleted=$((deleted + 1))
                    done

                    [[ "$count" -lt 100 ]] && break
                    page=$((page + 1))
                    [[ "$page" -gt 10 ]] && break  # safety limit
                done
                echo "$(date -Iseconds) CF cleanup complete: $deleted records deleted" >> "$_cf_log" 2>/dev/null
            ) &
            disown
        fi
        rm -f "$auth_dir/.cf-zone-cache" "$auth_dir/cf-dns-audit.log" "$auth_dir/ddns.log" "$auth_dir/os-update-status.json" 2>/dev/null || true

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
        start)    output=$(docker start -- "$name" 2>&1) || success=false ;;
        stop)     output=$(docker stop -- "$name" 2>&1) || success=false ;;
        restart)  output=$(docker restart -- "$name" 2>&1) || success=false ;;
        recreate)
            local img
            img=$(docker inspect --format='{{.Config.Image}}' "$name" 2>/dev/null)
            docker pull "$img" >/dev/null 2>&1 || true
            output=$(docker stop -- "$name" 2>&1 && docker rm -- "$name" 2>&1) || success=false
            if [[ "$success" == "true" ]]; then
                # Find the compose file and SERVICE name that owns this container
                local _stack_dir="" _svc_name=""
                for _sd in "$COMPOSE_DIR"/*/docker-compose.yml; do
                    if grep -q "container_name: $name" "$_sd" 2>/dev/null; then
                        _stack_dir=$(dirname "$_sd")
                        # Extract the service name (the YAML key above container_name)
                        _svc_name=$(awk -v cn="container_name: $name" '
                            /^  [a-zA-Z0-9_-]+:/ { svc=$1; gsub(/:$/,"",svc) }
                            $0 ~ cn { print svc; exit }
                        ' "$_sd" 2>/dev/null)
                        break
                    fi
                done
                if [[ -n "$_stack_dir" && -n "$_svc_name" ]]; then
                    local _rec_env=""
                    [[ -f "$_stack_dir/.env" ]] && _rec_env="$_stack_dir/.env"
                    output=$(_compose_with_secrets "$_stack_dir/docker-compose.yml" "$_rec_env" up -d --force-recreate --no-deps "$_svc_name" 2>&1) || success=false
                else
                    output="Container recreated but no compose file found — started from pulled image"
                    docker run -d --name "$name" "$img" >/dev/null 2>&1 || success=false
                fi
            fi
            ;;
        remove)   output=$(docker rm -f -- "$name" 2>&1) || success=false ;;
        *)        _api_error 400 "Unknown action: $action"; return ;;
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
    custom_networks=$(docker network ls --format '{{.Name}}' 2>/dev/null | grep -cvE '^(bridge|host|none)$') || custom_networks=0

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
    # Scan per-stack App-Data directories (DCS stores data inside each stack dir)
    local -a stack_sizes=()
    local total_bytes=0
    for _stack_dir in "$COMPOSE_DIR"/*/; do
        [[ ! -d "$_stack_dir" ]] && continue
        local stack_name
        stack_name=$(basename "$_stack_dir")
        local _ad="$_stack_dir/App-Data"
        # Also check configured APP_DATA_DIR relative path
        if [[ ! -d "$_ad" ]]; then
            local _configured="${APP_DATA_DIR:-./App-Data}"
            [[ "$_configured" == ./* ]] && _ad="$_stack_dir/${_configured#./}" || _ad="$_configured"
        fi
        [[ ! -d "$_ad" ]] && continue
        local size_raw size_bytes
        size_raw=$(du -sh "$_ad" 2>/dev/null | cut -f1)
        [[ -z "$size_raw" ]] && continue
        # Parse size to bytes for total calculation
        size_bytes=$(du -sb "$_ad" 2>/dev/null | cut -f1) || size_bytes=0
        total_bytes=$((total_bytes + size_bytes))
        stack_sizes+=("{\"name\": \"$(_api_json_escape "$stack_name")\", \"size\": \"$(_api_json_escape "$size_raw")\"}")
    done

    local ss_json
    if [[ ${#stack_sizes[@]} -gt 0 ]]; then
        ss_json=$(printf '%s,' "${stack_sizes[@]}")
        ss_json="[${ss_json%,}]"
    else
        ss_json="[]"
    fi

    # Docker system disk usage
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

    # Calculate total app data from per-stack scan
    local total_app_data="N/A"
    if [[ $total_bytes -gt 0 ]]; then
        if [[ $total_bytes -ge 1073741824 ]]; then
            total_app_data=$(awk "BEGIN { printf \"%.1fG\", $total_bytes / 1073741824 }")
        elif [[ $total_bytes -ge 1048576 ]]; then
            total_app_data=$(awk "BEGIN { printf \"%.1fM\", $total_bytes / 1048576 }")
        else
            total_app_data=$(awk "BEGIN { printf \"%.0fK\", $total_bytes / 1024 }")
        fi
    fi

    # Host disk info (filesystem where stacks live)
    local disk_total="N/A" disk_used="N/A" disk_avail="N/A" disk_pct="N/A"
    local _df_line
    _df_line=$(df -h "$COMPOSE_DIR" 2>/dev/null | tail -1)
    if [[ -n "$_df_line" ]]; then
        disk_total=$(echo "$_df_line" | awk '{print $2}')
        disk_used=$(echo "$_df_line" | awk '{print $3}')
        disk_avail=$(echo "$_df_line" | awk '{print $4}')
        disk_pct=$(echo "$_df_line" | awk '{print $5}')
    fi

    # Docker volume sizes (named volumes with their actual disk usage)
    local -a vol_entries=()
    while IFS= read -r vname; do
        [[ -z "$vname" ]] && continue
        local vpath
        vpath=$(docker volume inspect --format '{{.Mountpoint}}' "$vname" 2>/dev/null)
        local vsize="unknown"
        if [[ -d "$vpath" ]]; then
            vsize=$(du -sh "$vpath" 2>/dev/null | cut -f1) || vsize="unknown"
        fi
        vol_entries+=("{\"name\": \"$(_api_json_escape "$vname")\", \"size\": \"$(_api_json_escape "$vsize")\"}")
    done < <(docker volume ls -q 2>/dev/null)

    local vol_json
    if [[ ${#vol_entries[@]} -gt 0 ]]; then
        vol_json=$(printf '%s,' "${vol_entries[@]}")
        vol_json="[${vol_json%,}]"
    else
        vol_json="[]"
    fi

    _api_success "{\"stack_sizes\": $ss_json, \"docker_df\": $df_json, \"total_app_data\": \"$(_api_json_escape "$total_app_data")\", \"host_disk\": {\"total\": \"$disk_total\", \"used\": \"$disk_used\", \"available\": \"$disk_avail\", \"percent\": \"$disk_pct\"}, \"volumes\": $vol_json}"
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

    # Read startup order from .env DOCKER_STACKS (respects user customization via
    # setup wizard or /stacks/reorder endpoint). Falls back to default if unset.
    local -a ordered_stacks=()
    if [[ -n "${DOCKER_STACKS:-}" ]]; then
        read -ra ordered_stacks <<< "$DOCKER_STACKS"
    else
        ordered_stacks=(
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
    fi

    local -a target_stacks=()
    if [[ "$stacks_input" == '"all"' || "$stacks_input" == 'all' ]]; then
        for s in "${ordered_stacks[@]}"; do
            [[ -d "$COMPOSE_DIR/$s" && -f "$COMPOSE_DIR/$s/docker-compose.yml" ]] && target_stacks+=("$s")
        done
    else
        # For selected stacks, reorder them to match DOCKER_STACKS order
        local -a selected=()
        while IFS= read -r s; do
            [[ -n "$s" ]] && selected+=("$s")
        done < <(printf '%s' "$body" | jq -r '.stacks[]' 2>/dev/null)
        for s in "${ordered_stacks[@]}"; do
            for sel in "${selected[@]}"; do
                if [[ "$s" == "$sel" ]]; then
                    target_stacks+=("$s")
                    break
                fi
            done
        done
        # Append any selected stacks not in ordered_stacks (custom stacks)
        for sel in "${selected[@]}"; do
            local found=false
            for t in "${target_stacks[@]}"; do
                [[ "$t" == "$sel" ]] && { found=true; break; }
            done
            [[ "$found" == "false" ]] && target_stacks+=("$sel")
        done
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

        local _batch_env="$COMPOSE_DIR/$stack/.env"
        local compose_args=(-f "$compose_file")
        [[ -f "$_batch_env" ]] && compose_args+=(--env-file "$_batch_env")

        # Run each stack action in background — API responds immediately
        case "$action" in
            start)   ( _compose_with_secrets "$compose_file" "$_batch_env" up -d >/dev/null 2>&1 ) & ;;
            stop)    ( $DOCKER_COMPOSE_CMD "${compose_args[@]}" down --timeout 10 >/dev/null 2>&1 ) & ;;
            restart) ( $DOCKER_COMPOSE_CMD "${compose_args[@]}" down --timeout 10 >/dev/null 2>&1; _compose_with_secrets "$compose_file" "$_batch_env" up -d >/dev/null 2>&1 ) & ;;
        esac

        results+=("{\"stack\": \"$(_api_json_escape "$stack")\", \"success\": true, \"message\": \"$action queued\"}")
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

    # Read startup order from .env (same as batch/stacks handler)
    local -a ordered_stacks=()
    if [[ -n "${DOCKER_STACKS:-}" ]]; then
        read -ra ordered_stacks <<< "$DOCKER_STACKS"
    else
        ordered_stacks=(
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
    fi

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

    # SECURITY: Check for path traversal in archive (../../ etc) before extracting
    if tar -tzf "$archive_path" 2>/dev/null | grep -qE '^\.\./|/\.\./|^/'; then
        _api_error 403 "Backup archive contains path traversal entries — refusing to extract"
        return
    fi

    # SECURITY: Check for symlinks in archive (symlink-following traversal attack)
    # A symlink entry pointing to /etc/cron.d followed by a file entry writes through it
    if tar -tvf "$archive_path" 2>/dev/null | grep -q '^l'; then
        _api_error 403 "Backup archive contains symbolic links — refusing to extract for security"
        return
    fi

    local status_file="$API_AUTH_DIR/backup-status.json"
    printf '{"status": "restoring", "filename": "%s", "progress": "Restoring from backup..."}' "$filename" > "$status_file"

    (
        local target="${BACKUP_SOURCE_DIR:-$BASE_DIR}"
        # SECURITY: --no-absolute-names prevents extracting absolute paths
        if tar -xzf "$archive_path" --no-absolute-names -C "$target" 2>/dev/null; then
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
        # General
        [ENVIRONMENT]=1 [SERVER_NAME]=1 [SERVER_SUBTITLE]=1 [TZ]=1 [PUID]=1 [PGID]=1
        [PROXY_DOMAIN]=1 [APP_DATA_DIR]=1
        # Startup/Shutdown
        [SKIP_HEALTHCHECK_WAIT]=1 [CONTINUE_ON_FAILURE]=1
        [REMOVE_VOLUMES_ON_STOP]=1 [SHOW_BANNERS]=1 [SHOW_SYSTEM_INFO]=1
        [SERVICE_START_DELAY]=1 [SERVICE_STOP_DELAY]=1
        # Docker
        [DOCKER_STACKS]=1 [DOCKER_TIMEOUT]=1 [FORCE_RECREATE]=1
        [REMOVE_ORPHANED_CONTAINERS]=1 [MAX_PARALLEL_OPERATIONS]=1
        # Logging
        [LOG_LEVEL]=1 [ENABLE_COLORS]=1 [COLOR_MODE]=1 [COLOR_THEME]=1
        [VERBOSE_MODE]=1 [ENABLE_LOG_DATE]=1 [ENABLE_MILLISECONDS]=1
        [LOG_DATE_FORMAT]=1 [ENABLE_LOG_MOOD]=1 [ENABLE_LOG_PID]=1
        [ENABLE_LOG_HOSTNAME]=1 [LOG_MAX_SIZE]=1 [LOG_BACKUP_COUNT]=1
        # Image Updates
        [AGGRESSIVE_IMAGE_PRUNE]=1 [UPDATE_NOTIFICATION]=1
        # Notifications
        [NTFY_URL]=1 [NTFY_TOPIC]=1 [NTFY_PRIORITY]=1
        [NOTIFICATION_STACKS]=1
        # API
        [API_ENABLED]=1 [API_PORT]=1 [API_BIND]=1
        [API_AUTH_ENABLED]=1 [API_RATE_LIMIT]=1 [API_RATE_WINDOW]=1
        [API_CORS_ORIGINS]=1 [API_IP_WHITELIST]=1
        [API_TOKEN_EXPIRY]=1 [API_SINGLE_SESSION]=1
        # Traefik/DNS
        [TRAEFIK_DOMAIN]=1 [TRAEFIK_ACME_EMAIL]=1
        [CF_DNS_API_TOKEN]=1 [DDNS_ENABLED]=1 [DDNS_INTERVAL]=1
        # Health/Monitoring
        [ENABLE_POST_STARTUP_HEALTH_CHECK]=1 [HEALTH_CHECK_DELAY]=1
        [CRITICAL_CONTAINERS]=1 [IMPORTANT_CONTAINERS]=1
        # Metrics/Features
        [METRICS_ENABLED]=1 [METRICS_COLLECT_INTERVAL]=1
        [ROLLBACK_ENABLED]=1 [SCHEDULER_ENABLED]=1
        [PLUGINS_ENABLED]=1 [PLUGINS_HOOKS_ENABLED]=1
        [HEALTH_SCORE_ENABLED]=1
        # Backup
        [BACKUP_SOURCE_DIR]=1 [BACKUP_DEST_DIR]=1 [BACKUP_RETENTION_COUNT]=1
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

    # Re-source .env to pick up changes — preserve runtime CLI overrides
    local _saved_api_bind="$API_BIND"
    local _saved_api_port="$API_PORT"
    set -a
    source "$env_file"
    set +a
    API_BIND="$_saved_api_bind"
    API_PORT="$_saved_api_port"

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
        # SECURITY: Quote all variables via env() to prevent shell injection
        TERM_AUTH_USER="$username" TERM_AUTH_PASS="$password" TERM_AUTH_MARKER="$marker" expect << 'EXPEOF' 2>/dev/null
log_user 0
set timeout 10
spawn su - $env(TERM_AUTH_USER) -c "echo $env(TERM_AUTH_MARKER)"
expect {
    -re {[Pp]assword:} { send "$env(TERM_AUTH_PASS)\r"; exp_continue }
    "$env(TERM_AUTH_MARKER)" { exit 0 }
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

    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

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

    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

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

    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

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

    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

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

    # SECURITY: Validate cwd — must be a real directory, no path traversal
    if [[ "$cwd" == *".."* ]]; then
        _api_error 400 "Invalid working directory: path traversal not allowed"
        return
    fi
    if [[ ! -d "$cwd" ]]; then
        _api_error 400 "Working directory does not exist: $cwd"
        return
    fi

    # ── Terminal Command Guard: block dangerous shell patterns ──
    # NOTE: This is a SAFETY NET against accidental destructive commands, NOT a security
    # boundary. The terminal requires triple auth (API token + admin role + Linux credentials).
    # A determined admin can always bypass a denylist (base64, aliases, scripting languages).
    # The real security is the triple auth requirement + audit logging.

    # SECURITY: Command length limit (prevents buffer overflow attacks)
    if [[ ${#command} -gt 8192 ]]; then
        _api_error 400 "Command too long (max 8192 characters)"
        return
    fi

    local _cmd_lower="${command,,}"
    local -a _blocked_patterns=(
        "rm -rf /"          # filesystem wipe
        "rm -rf /*"         # filesystem wipe variant
        "rm -rf ~"          # home directory wipe
        "mkfs"              # format disk
        "dd if="            # raw disk write
        "> /dev/sd"         # raw device write
        "> /dev/nvme"       # raw NVMe device write
        ":(){ :|:& };:"    # fork bomb
        ".(){.|.&};."       # fork bomb variant
        "chmod -r 777 /"    # permission wipe
        "chmod 777 /"       # permission wipe
        "chown -r"          # ownership change on system dirs
        "/etc/shadow"       # password file access
        "/etc/passwd"       # user file access
        "/etc/sudoers"      # sudo file access
        "curl.*| *bash"     # pipe-to-shell
        "wget.*| *bash"     # pipe-to-shell
        "curl.*| *sh"       # pipe-to-shell
        "wget.*| *sh"       # pipe-to-shell
        "shutdown"          # system shutdown
        "reboot"            # system reboot
        "init 0"            # system halt
        "poweroff"          # system poweroff
        "halt"              # system halt
        "systemctl.*halt"   # systemd halt
        "systemctl.*poweroff" # systemd poweroff
        "systemctl.*reboot" # systemd reboot
        "crontab -r"        # cron wipe
        "iptables -f"       # firewall flush
        "nft flush"         # nftables flush
        "visudo"            # sudo editor
        "passwd"            # password change
        "useradd"           # user creation
        "userdel"           # user deletion
        "groupdel"          # group deletion
    )

    for _pat in "${_blocked_patterns[@]}"; do
        if [[ "$_cmd_lower" == *"${_pat,,}"* ]]; then
            local client_ip="${SOCAT_PEERADDR:-unknown}"
            _api_audit_log "$client_ip" "TERM_BLOCKED" "$session_user" "Blocked: $command"
            _api_error 403 "Command blocked by security policy"
            return
        fi
    done

    # Regex-based patterns (for pipe chains and complex patterns that need wildcards)
    local -a _blocked_regex=(
        'curl\s.*\|\s*(ba)?sh'       # curl pipe-to-shell
        'wget\s.*\|\s*(ba)?sh'       # wget pipe-to-shell
        'systemctl\s.*(halt|poweroff|reboot|suspend)'  # systemd destructive
        'base64\s.*\|\s*(ba)?sh'     # base64 decode pipe-to-shell
        'python[23]?\s+-c\s.*os\.(system|exec|popen)'  # python os exec
        'perl\s+-e\s.*system\('      # perl system exec
        'ruby\s+-e\s.*system\('      # ruby system exec
    )
    for _rpat in "${_blocked_regex[@]}"; do
        if printf '%s' "$_cmd_lower" | grep -qE "$_rpat"; then
            local client_ip="${SOCAT_PEERADDR:-unknown}"
            _api_audit_log "$client_ip" "TERM_BLOCKED" "$session_user" "Blocked(regex): $command"
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
    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

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
    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    local container="$1"
    local query_path="$2"
    [[ -z "$container" ]] && { _api_error 400 "Missing container name"; return; }
    [[ -z "$query_path" ]] && query_path="/"

    # SECURITY: Reject path traversal attempts
    # Note: $'\0' check removed — bash strings cannot contain null bytes, and $'\0'
    # in [[ ]] degrades to an empty string making the pattern ** which matches everything.
    if [[ "$query_path" == *".."* ]] || [[ "$query_path" == *"~"* ]]; then
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
    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    local container="$1"
    local file_path="$2"
    [[ -z "$container" ]] && { _api_error 400 "Missing container name"; return; }
    [[ -z "$file_path" ]] && { _api_error 400 "Missing file path"; return; }

    # SECURITY: Reject path traversal attempts (see null byte note in handle_container_files)
    if [[ "$file_path" == *".."* ]] || [[ "$file_path" == *"~"* ]]; then
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

    # Check if file is binary (contains null bytes) — reject gracefully
    if docker exec "$container" grep -qP '\x00' "$file_path" 2>/dev/null; then
        _api_error 400 "Binary file cannot be displayed as text"
        return
    fi

    local content
    content=$(docker exec "$container" cat "$file_path" 2>/dev/null)
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
    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

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
    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

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
    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

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
    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

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
    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

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
    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    local container="$1"
    local lines="${2:-100}"
    local since="$3"
    [[ -z "$container" ]] && { _api_error 400 "Missing container name"; return; }

    # SECURITY: Validate lines is a positive integer (prevents flag injection via tail -"${lines}")
    [[ "$lines" =~ ^[0-9]+$ ]] || lines=100
    (( lines > 5000 )) && lines=5000

    # SECURITY: Validate since is a safe timestamp or duration (prevents docker flag injection)
    if [[ -n "$since" ]]; then
        if [[ ! "$since" =~ ^[0-9T.:ZzZ+/-]+$ ]] && [[ ! "$since" =~ ^[0-9]+[smh]$ ]]; then
            since=""
        fi
    fi

    # Verify container exists
    docker inspect "$container" >/dev/null 2>&1 || { _api_error 404 "Container not found: $container"; return; }

    local log_output
    if [[ -n "$since" ]]; then
        log_output=$(docker logs --since "$since" --timestamps -- "$container" 2>&1 | tail -"${lines}")
    else
        log_output=$(docker logs --tail "$lines" --timestamps -- "$container" 2>&1)
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
    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    local lines="${1:-100}"
    local since="$2"
    local log_file="$BASE_DIR/logs/docker-services.log"

    # SECURITY: Validate lines and since parameters
    [[ "$lines" =~ ^[0-9]+$ ]] || lines=100
    (( lines > 5000 )) && lines=5000
    if [[ -n "$since" && ! "$since" =~ ^[0-9T.:ZzZ+/-]+$ ]]; then
        since=""
    fi

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
    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

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
    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

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

    # SECURITY: Validate new name to prevent Docker flag injection
    _api_validate_resource_name "$new_name" "container" || return

    local output
    output=$(docker rename -- "$name" "$new_name" 2>&1)
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

# Check if DCS-UI Docker image has a newer version available on GHCR
_check_ui_image_update() {
    local ui_image="ghcr.io/scotthowson/docker-compose-skeleton-ui:latest"
    local result='{"available": false}'

    # Check if DCS-UI container exists
    if ! docker inspect DCS-UI >/dev/null 2>&1; then
        echo "$result"
        return
    fi

    # Get local image digest (the sha256 from RepoDigests — this is the manifest list digest)
    local local_digest
    local_digest=$(docker image inspect "$ui_image" --format='{{index .RepoDigests 0}}' 2>/dev/null | cut -d'@' -f2)

    if [[ -z "$local_digest" ]]; then
        echo "$result"
        return
    fi

    # Get remote manifest list digest from GHCR registry API (HEAD request for Docker-Content-Digest).
    # This returns the same digest type as RepoDigests, so comparison is valid.
    local remote_digest _ghcr_token
    _ghcr_token=$(timeout 5 curl -sf "https://ghcr.io/token?scope=repository:scotthowson/docker-compose-skeleton-ui:pull" 2>/dev/null | jq -r '.token // empty' 2>/dev/null)
    if [[ -n "$_ghcr_token" ]]; then
        remote_digest=$(timeout 5 curl -sfI \
            -H "Authorization: Bearer $_ghcr_token" \
            -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json" \
            "https://ghcr.io/v2/scotthowson/docker-compose-skeleton-ui/manifests/latest" 2>/dev/null \
            | grep -i 'docker-content-digest' | awk '{print $2}' | tr -d '\r\n')
    fi

    if [[ -z "$remote_digest" ]]; then
        echo "$result"
        return
    fi

    # Compare digests (both are manifest list digests now)
    if [[ "$local_digest" != "$remote_digest" ]]; then
        echo "{\"available\": true, \"current\": \"${local_digest:7:12}\", \"latest\": \"${remote_digest:7:12}\"}"
    else
        echo "$result"
    fi
}

# POST /system/ui-update/apply — Pull latest DCS-UI image and recreate container
handle_ui_update_apply() {
    if ! _api_check_admin; then return; fi

    local ui_image="ghcr.io/scotthowson/docker-compose-skeleton-ui:latest"

    if ! docker inspect DCS-UI >/dev/null 2>&1; then
        _api_error 404 "DCS-UI container not found"
        return
    fi

    # Pull the latest image
    local pull_output
    pull_output=$(timeout 120 docker pull "$ui_image" 2>&1)
    if [[ $? -ne 0 ]]; then
        _api_error 500 "Failed to pull image: $(_api_json_escape "$pull_output")"
        return
    fi

    # Find the compose file that has DCS-UI
    local compose_file=""
    local stack_dir=""
    for _cf in "$COMPOSE_DIR"/*/docker-compose.yml; do
        if grep -q 'container_name: DCS-UI' "$_cf" 2>/dev/null; then
            compose_file="$_cf"
            stack_dir=$(dirname "$_cf")
            break
        fi
    done

    if [[ -z "$compose_file" ]]; then
        _api_error 404 "DCS-UI compose file not found"
        return
    fi

    # Recreate in background — the UI will disconnect briefly
    local env_args=()
    [[ -f "$stack_dir/.env" ]] && env_args=(--env-file "$stack_dir/.env")
    ( $DOCKER_COMPOSE_CMD -f "$compose_file" "${env_args[@]}" up -d --force-recreate --no-deps dcs-ui >/dev/null 2>&1 ) &

    _api_success "{\"success\": true, \"message\": \"DCS-UI is being updated. The page will reconnect automatically.\"}"
}

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
    # Use refs/remotes/ explicitly to avoid ambiguity with tags of the same name
    latest=$(git rev-parse --short "refs/remotes/origin/$branch" 2>/dev/null || echo "$current")
    behind=$(git rev-list HEAD.."refs/remotes/origin/$branch" --count 2>/dev/null || echo "0")
    # Ignore runtime data files when checking for local changes
    has_local=$(git diff --name-only HEAD 2>/dev/null | grep -vE '^\.api-auth/|^\.data/|^\.compose-history/|^\.secrets/|^\.plugins/|^logs/|^\.env|^Stacks/|^\.templates/.*/\.env' | head -1)

    # Get changelog (commits we're behind)
    # SECURITY: Use tab-separated format and escape each field to prevent
    # JSON injection via commit messages containing double-quotes
    changelog="[]"
    if [[ "$behind" -gt 0 ]]; then
        local -a cl_entries=()
        while IFS=$'\t' read -r _hash _msg _author _date; do
            [[ -z "$_hash" ]] && continue
            cl_entries+=("{\"hash\":\"$(_api_json_escape "$_hash")\",\"message\":\"$(_api_json_escape "$_msg")\",\"author\":\"$(_api_json_escape "$_author")\",\"date\":\"$(_api_json_escape "$_date")\"}")
        done < <(git log HEAD.."refs/remotes/origin/$branch" --pretty=format:'%h%x09%s%x09%an%x09%ci' 2>/dev/null | head -20)
        if [[ ${#cl_entries[@]} -gt 0 ]]; then
            local cl_json
            cl_json=$(printf '%s,' "${cl_entries[@]}")
            changelog="[${cl_json%,}]"
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
  \"branch\": \"$(_api_json_escape "$branch")\",
  \"ui_update\": $(_check_ui_image_update)
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

    # Check for local changes to TRACKED files — refuse if working tree is dirty
    # Only check tracked files (not untracked .api-auth, .env, .compose-history, etc.)
    local has_local
    # Check for local changes to tracked files — but ignore user-modified runtime files.
    # Template deployment modifies compose files, setup modifies .env, etc.
    has_local=$(git diff --name-only HEAD 2>/dev/null | grep -vE '^\.api-auth/|^\.data/|^\.compose-history/|^\.secrets/|^\.plugins/|^logs/|^\.env|^Stacks/|^\.templates/.*/\.env' | head -1)
    if [[ -n "$has_local" ]]; then
        _api_error 409 "Cannot update: local changes to tracked source files detected. Commit or stash changes before updating."
        return
    fi

    local branch current
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    current=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

    # Fetch latest
    git fetch origin 2>/dev/null

    local behind
    behind=$(git rev-list HEAD.."refs/remotes/origin/$branch" --count 2>/dev/null || echo "0")
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

    # Attempt fast-forward-only pull — use explicit refs/heads/ to avoid tag ambiguity
    local pull_output pull_exit
    pull_output=$(git pull --ff-only origin "refs/heads/$branch" 2>&1)
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

    # Collect changelog of what was applied (safely escaped to prevent JSON injection)
    local changelog="[]"
    local -a _cl=()
    while IFS=$'\t' read -r _h _m _a _d; do
        [[ -z "$_h" ]] && continue
        _cl+=("{\"hash\":\"$(_api_json_escape "$_h")\",\"message\":\"$(_api_json_escape "$_m")\",\"author\":\"$(_api_json_escape "$_a")\",\"date\":\"$(_api_json_escape "$_d")\"}")
    done < <(git log "${backup_tag}..HEAD" --pretty=format:'%h%x09%s%x09%an%x09%ci' 2>/dev/null | head -20)
    if [[ ${#_cl[@]} -gt 0 ]]; then
        local _cj; _cj=$(printf '%s,' "${_cl[@]}")
        changelog="[${_cj%,}]"
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
# OS PACKAGE UPDATE MANAGEMENT
# =============================================================================

# Detect the system package manager
_detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then echo "apt"
    elif command -v dnf >/dev/null 2>&1; then echo "dnf"
    elif command -v yum >/dev/null 2>&1; then echo "yum"
    elif command -v pacman >/dev/null 2>&1; then echo "pacman"
    elif command -v apk >/dev/null 2>&1; then echo "apk"
    elif command -v zypper >/dev/null 2>&1; then echo "zypper"
    else echo "unknown"
    fi
}

# Run a command with root privileges using the best available method.
# Args: $1=password $2=username $3...=command
# Tries: root > NOPASSWD sudo > sudo.ws -S > sudo -S > su via python pty
_run_privileged() {
    local _pw="$1" _user="$2"
    shift 2

    # Already root — just run it
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@" 2>&1
        return $?
    fi

    # NOPASSWD sudo available
    if sudo -n true 2>/dev/null; then
        sudo "$@" 2>&1
        return $?
    fi

    # Need password — try traditional sudo.ws first (handles -S properly)
    if [[ -n "$_pw" ]]; then
        # Try original sudo (sudo.ws) which handles -S stdin correctly
        if [[ -x /usr/bin/sudo.ws ]]; then
            printf '%s\n' "$_pw" | /usr/bin/sudo.ws -S "$@" 2>&1
            return $?
        fi

        # Try regular sudo -S (works on traditional sudo, not sudo-rs)
        local _sudo_out
        _sudo_out=$(printf '%s\n' "$_pw" | sudo -S "$@" 2>&1)
        local _rc=$?
        if [[ $_rc -eq 0 ]] || ! echo "$_sudo_out" | grep -qi "authentication failed\|try again"; then
            echo "$_sudo_out"
            return $_rc
        fi

        # Fallback: use python3 pty to run su -c (same as terminal auth strategy)
        # SECURITY: Pass password and command via environment variables, NOT string interpolation.
        # This prevents code injection via passwords containing quotes or Python metacharacters.
        if command -v python3 >/dev/null 2>&1; then
            local _cmd_str
            _cmd_str=$(printf '%q ' "$@")
            _DCS_PW="$_pw" _DCS_USER="$_user" _DCS_CMD="$_cmd_str" python3 -c "
import pty, os, sys, select, time
_pw = os.environ.get('_DCS_PW', '')
_user = os.environ.get('_DCS_USER', '')
_cmd = os.environ.get('_DCS_CMD', '')
pid, fd = pty.openpty()
child = os.fork()
if child == 0:
    os.setsid()
    os.dup2(fd, 0); os.dup2(fd, 1); os.dup2(fd, 2)
    os.close(fd)
    os.execlp('su', 'su', '-c', _cmd, _user)
else:
    os.close(fd)
    master = pid
    output = b''
    pw_sent = False
    start = time.time()
    while time.time() - start < 300:
        try:
            r, _, _ = select.select([master], [], [], 1)
            if r:
                data = os.read(master, 4096)
                if not data: break
                output += data
                if not pw_sent and (b'assword' in output or b'Password' in output):
                    os.write(master, _pw.encode() + b'\n')
                    pw_sent = True
        except: break
    _, status = os.waitpid(child, 0)
    # Strip password echo and prompt from output
    lines = output.decode('utf-8', errors='replace').split('\n')
    clean = [l for l in lines if 'assword' not in l and 'su:' not in l]
    sys.stdout.write('\n'.join(clean))
    sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1)
" 2>&1
            return $?
        fi
    fi

    echo "No privilege escalation method available"
    return 1
}

# POST /system/os-update/check — Check for available OS package updates
# Requires terminal auth token (Linux credentials)
handle_os_update_check() {
    local body="$1"

    # Validate terminal session token
    local token=""
    if command -v jq >/dev/null 2>&1; then
        token=$(printf '%s' "$body" | jq -r '.terminal_token // empty' 2>/dev/null)
    fi
    if [[ -z "$token" ]]; then
        _api_error 401 "Terminal authentication required. Provide terminal_token."
        return
    fi

    local term_user=""
    term_user=$(_validate_terminal_session "$token")
    if [[ $? -ne 0 || -z "$term_user" ]]; then
        _api_error 401 "Invalid or expired terminal session"
        return
    fi

    local pkg_manager
    pkg_manager=$(_detect_pkg_manager)

    if [[ "$pkg_manager" == "unknown" ]]; then
        _api_error 500 "No supported package manager found (apt, dnf, yum, pacman, apk, zypper)"
        return
    fi

    local update_output=""
    local update_count=0
    local update_list="[]"

    # Get password for privilege escalation
    local password=""
    password=$(printf '%s' "$body" | jq -r '.password // empty' 2>/dev/null)

    if [[ "$(id -u)" -ne 0 ]] && ! sudo -n true 2>/dev/null && [[ -z "$password" ]]; then
        _api_error 403 "Sudo password required. Please re-authenticate."
        return
    fi

    case "$pkg_manager" in
        apt)
            _run_privileged "$password" "$term_user" apt-get update -qq >/dev/null 2>&1
            update_output=$(_run_privileged "$password" "$term_user" apt list --upgradable 2>/dev/null | grep -v "^Listing" | head -50)
            update_count=$(echo "$update_output" | grep -c '/' 2>/dev/null) || update_count=0
            if command -v jq >/dev/null 2>&1 && [[ -n "$update_output" && "$update_count" -gt 0 ]]; then
                update_list=$(echo "$update_output" | head -30 | while IFS='/' read -r pkg rest; do
                    [[ -z "$pkg" ]] && continue
                    local ver
                    ver=$(echo "$rest" | awk '{print $2}' 2>/dev/null)
                    printf '{"package":"%s","version":"%s"}\n' "$(_api_json_escape "$pkg")" "$(_api_json_escape "$ver")"
                done | jq -s '.' 2>/dev/null || echo "[]")
            fi
            ;;
        dnf|yum)
            update_output=$(_run_privileged "$password" "$term_user" $pkg_manager check-update 2>/dev/null | grep -E '^\S+\.\S+' | head -50)
            update_count=$(echo "$update_output" | grep -c '\.' 2>/dev/null) || update_count=0
            if command -v jq >/dev/null 2>&1 && [[ -n "$update_output" && "$update_count" -gt 0 ]]; then
                update_list=$(echo "$update_output" | head -30 | awk '{printf "{\"package\":\"%s\",\"version\":\"%s\"}\n", $1, $2}' | jq -s '.' 2>/dev/null || echo "[]")
            fi
            ;;
        pacman)
            _run_privileged "$password" "$term_user" pacman -Sy --noconfirm >/dev/null 2>&1
            update_output=$(_run_privileged "$password" "$term_user" pacman -Qu 2>/dev/null | head -50)
            update_count=$(echo "$update_output" | grep -c '\S' 2>/dev/null) || update_count=0
            if command -v jq >/dev/null 2>&1 && [[ -n "$update_output" && "$update_count" -gt 0 ]]; then
                update_list=$(echo "$update_output" | head -30 | awk '{printf "{\"package\":\"%s\",\"version\":\"%s\"}\n", $1, $3}' | jq -s '.' 2>/dev/null || echo "[]")
            fi
            ;;
        apk)
            _run_privileged "$password" "$term_user" apk update >/dev/null 2>&1
            update_output=$(_run_privileged "$password" "$term_user" apk upgrade --simulate 2>/dev/null | grep "Upgrading" | head -50)
            update_count=$(echo "$update_output" | grep -c 'Upgrading' 2>/dev/null) || update_count=0
            ;;
        zypper)
            _run_privileged "$password" "$term_user" zypper refresh >/dev/null 2>&1
            update_output=$(_run_privileged "$password" "$term_user" zypper list-updates 2>/dev/null | grep '|' | tail -n +3 | head -50)
            update_count=$(echo "$update_output" | grep -c '|' 2>/dev/null) || update_count=0
            ;;
    esac

    [[ "$update_count" -lt 0 ]] && update_count=0

    _api_success "{
  \"available\": $([ "$update_count" -gt 0 ] && echo true || echo false),
  \"count\": $update_count,
  \"package_manager\": \"$pkg_manager\",
  \"packages\": $update_list,
  \"checked_as\": \"$(_api_json_escape "$term_user")\"
}"
}

# POST /system/os-update/apply — Apply all available OS package updates
# Requires terminal auth token (Linux credentials)
handle_os_update_apply() {
    local body="$1"

    # Validate terminal session token
    local token="" confirm=""
    if command -v jq >/dev/null 2>&1; then
        token=$(printf '%s' "$body" | jq -r '.terminal_token // empty' 2>/dev/null)
        confirm=$(printf '%s' "$body" | jq -r '.confirm // empty' 2>/dev/null)
    fi
    if [[ -z "$token" ]]; then
        _api_error 401 "Terminal authentication required. Provide terminal_token."
        return
    fi
    if [[ "$confirm" != "true" ]]; then
        _api_error 400 "Missing confirmation. Send {\"confirm\": true} to apply OS updates."
        return
    fi

    local term_user=""
    term_user=$(_validate_terminal_session "$token")
    if [[ $? -ne 0 || -z "$term_user" ]]; then
        _api_error 401 "Invalid or expired terminal session"
        return
    fi

    local pkg_manager
    pkg_manager=$(_detect_pkg_manager)

    if [[ "$pkg_manager" == "unknown" ]]; then
        _api_error 500 "No supported package manager found"
        return
    fi

    local update_cmd=""
    case "$pkg_manager" in
        apt)     update_cmd="DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q" ;;
        dnf)     update_cmd="dnf upgrade -y --quiet" ;;
        yum)     update_cmd="yum update -y -q" ;;
        pacman)  update_cmd="pacman -Syu --noconfirm" ;;
        apk)     update_cmd="apk upgrade --no-cache" ;;
        zypper)  update_cmd="zypper update -y --no-confirm" ;;
    esac

    # Get password for privilege escalation
    local password=""
    password=$(printf '%s' "$body" | jq -r '.password // empty' 2>/dev/null)

    if [[ "$(id -u)" -ne 0 ]] && ! sudo -n true 2>/dev/null && [[ -z "$password" ]]; then
        _api_error 403 "Sudo password required to apply updates."
        return
    fi

    # Run update in BACKGROUND — write status to a file, respond immediately.
    # This prevents the HTTP connection from timing out during long apt upgrades.
    local status_file="$API_AUTH_DIR/os-update-status.json"
    printf '{"status":"running","package_manager":"%s","started_at":"%s","message":"Applying updates..."}' \
        "$pkg_manager" "$(date -Iseconds)" > "$status_file"

    local client_ip="${SOCAT_PEERADDR:-unknown}"

    (
        local output=""
        local exit_code=0
        output=$(_run_privileged "$password" "$term_user" bash -c "$update_cmd" 2>&1) || exit_code=$?

        # Extract summary
        local summary=""
        case "$pkg_manager" in
            apt)
                summary=$(echo "$output" | grep -E '^\d+ upgraded|^0 upgraded' | tail -1)
                [[ -z "$summary" ]] && summary=$(echo "$output" | tail -3 | head -1)
                ;;
            dnf|yum)
                summary=$(echo "$output" | grep -E 'Complete!|Nothing to do' | tail -1)
                [[ -z "$summary" ]] && summary=$(echo "$output" | tail -3 | head -1)
                ;;
            pacman)
                summary=$(echo "$output" | grep -E 'there is nothing to do|upgraded' | tail -1)
                ;;
            *)
                summary=$(echo "$output" | tail -3 | head -1)
                ;;
        esac

        local truncated_output
        truncated_output=$(echo "$output" | tail -100)

        _api_audit_log "$client_ip" "OS_UPDATE" "$term_user" "OS update via $pkg_manager (exit=$exit_code)"

        # Write final status
        if [[ "$exit_code" -eq 0 ]]; then
            printf '{"status":"complete","success":true,"package_manager":"%s","exit_code":0,"summary":"%s","output":"%s","applied_as":"%s","message":"System packages updated successfully.","completed_at":"%s"}' \
                "$pkg_manager" "$(_api_json_escape "$summary")" "$(_api_json_escape "$truncated_output")" "$(_api_json_escape "$term_user")" "$(date -Iseconds)" > "$status_file"
        else
            printf '{"status":"complete","success":false,"package_manager":"%s","exit_code":%d,"summary":"%s","output":"%s","applied_as":"%s","message":"Update completed with errors (exit code %d).","completed_at":"%s"}' \
                "$pkg_manager" "$exit_code" "$(_api_json_escape "$summary")" "$(_api_json_escape "$truncated_output")" "$(_api_json_escape "$term_user")" "$exit_code" "$(date -Iseconds)" > "$status_file"
        fi
    ) &
    disown

    _api_success "{
  \"success\": true,
  \"status\": \"running\",
  \"package_manager\": \"$pkg_manager\",
  \"message\": \"Update started in background. Poll /system/os-update/status for progress.\"
}"
}

# GET /system/os-update/status — Poll background OS update progress
handle_os_update_status() {
    local status_file="$API_AUTH_DIR/os-update-status.json"
    if [[ -f "$status_file" ]]; then
        local content
        content=$(cat "$status_file" 2>/dev/null)
        _api_success "$content"
    else
        _api_success "{\"status\":\"idle\"}"
    fi
}

# =============================================================================
# DYNAMIC DNS (CLOUDFLARE)
# =============================================================================
# Built-in DDNS: detects public IP and updates Cloudflare DNS records.
# Runs as a background loop inside the API server — no extra container needed.

DDNS_ENABLED="${DDNS_ENABLED:-false}"
DDNS_INTERVAL="${DDNS_INTERVAL:-300}"
DDNS_PID_FILE="/tmp/dcs-ddns.pid"

_ddns_get_public_ip() {
    # Try multiple providers — use plain IPv4 services to avoid Cloudflare proxy IPs
    local ip=""
    ip=$(curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null)
    [[ -z "$ip" || ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && ip=$(curl -4 -s --max-time 5 https://ifconfig.me 2>/dev/null)
    [[ -z "$ip" || ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && ip=$(curl -4 -s --max-time 5 https://icanhazip.com 2>/dev/null | tr -d '[:space:]')
    [[ -z "$ip" || ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && ip=$(curl -4 -s --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')
    echo "$ip"
}

_ddns_update_loop() {
    local cf_token="${CF_DNS_API_TOKEN:-}"
    local domain="${TRAEFIK_DOMAIN:-}"
    local subdomains="${DDNS_SUBDOMAINS:-@}"
    local interval="${DDNS_INTERVAL:-300}"
    local cf_api="https://api.cloudflare.com/client/v4"
    local last_ip=""
    local log_file="$BASE_DIR/.api-auth/ddns.log"

    [[ -z "$cf_token" || -z "$domain" ]] && return

    # Get zone ID
    local zone_id=""
    local zone_cache="$BASE_DIR/.api-auth/.cf-zone-cache"
    if [[ -f "$zone_cache" ]]; then
        local cd cz
        cd=$(sed -n '1p' "$zone_cache" 2>/dev/null)
        cz=$(sed -n '2p' "$zone_cache" 2>/dev/null)
        [[ "$cd" == "$domain" && -n "$cz" ]] && zone_id="$cz"
    fi
    if [[ -z "$zone_id" ]]; then
        local zr
        zr=$(curl -s --max-time 10 -H "Authorization: Bearer $cf_token" "$cf_api/zones?name=$domain&status=active" 2>/dev/null)
        zone_id=$(printf '%s' "$zr" | jq -r '.result[0].id // empty' 2>/dev/null)
        [[ -z "$zone_id" ]] && return
        printf '%s\n%s\n' "$domain" "$zone_id" > "$zone_cache" 2>/dev/null
    fi

    printf '[%s] DDNS started — domain=%s interval=%ss\n' "$(date -Iseconds)" "$domain" "$interval" >> "$log_file"

    while true; do
        local current_ip
        current_ip=$(_ddns_get_public_ip)

        if [[ -n "$current_ip" && "$current_ip" != "$last_ip" ]]; then
            # IP changed — update records
            IFS=',' read -ra subs <<< "$subdomains"
            for sub in "${subs[@]}"; do
                sub=$(echo "$sub" | tr -d ' ')
                local fqdn
                if [[ "$sub" == "@" || -z "$sub" ]]; then
                    fqdn="$domain"
                else
                    fqdn="${sub}.${domain}"
                fi

                # Check ALL records for this FQDN first
                local all_records
                all_records=$(curl -s --max-time 10 -H "Authorization: Bearer $cf_token" \
                    "$cf_api/zones/$zone_id/dns_records?name=$fqdn" 2>/dev/null)

                # Skip if a CNAME exists (managed by auto-routing, not DDNS)
                local cname_count
                cname_count=$(printf '%s' "$all_records" | jq -r '[.result[] | select(.type=="CNAME")] | length' 2>/dev/null || echo 0)
                if [[ "$cname_count" -gt 0 ]]; then
                    continue
                fi

                # Find existing A record
                local record_id
                record_id=$(printf '%s' "$all_records" | jq -r '[.result[] | select(.type=="A")][0].id // empty' 2>/dev/null)
                local record_ip
                record_ip=$(printf '%s' "$all_records" | jq -r '[.result[] | select(.type=="A")][0].content // empty' 2>/dev/null)

                if [[ -n "$record_id" ]]; then
                    # Only update if IP actually differs
                    if [[ "$record_ip" != "$current_ip" ]]; then
                        curl -s --max-time 10 -X PATCH \
                            -H "Authorization: Bearer $cf_token" \
                            -H "Content-Type: application/json" \
                            -d "{\"content\":\"$current_ip\"}" \
                            "$cf_api/zones/$zone_id/dns_records/$record_id" >/dev/null 2>&1
                    fi
                else
                    # Create new A record (no existing A or CNAME)
                    curl -s --max-time 10 -X POST \
                        -H "Authorization: Bearer $cf_token" \
                        -H "Content-Type: application/json" \
                        -d "{\"type\":\"A\",\"name\":\"$fqdn\",\"content\":\"$current_ip\",\"proxied\":true,\"ttl\":1,\"comment\":\"DCS DDNS\"}" \
                        "$cf_api/zones/$zone_id/dns_records" >/dev/null 2>&1
                fi
            done

            printf '[%s] IP updated: %s → %s (%s)\n' "$(date -Iseconds)" "${last_ip:-none}" "$current_ip" "$subdomains" >> "$log_file"
            last_ip="$current_ip"
        fi

        # On IP change, also scan custom_routes for subdomains that need DNS records.
        # Only runs when IP changes (not every cycle) to avoid hitting CF rate limits.
        if [[ -n "$current_ip" && "$current_ip" != "${_last_route_sync_ip:-}" ]]; then
            _last_route_sync_ip="$current_ip"
            local routes_dir=""
            local _sd
            for _sd in "$COMPOSE_DIR"/*/App-Data/Traefik/custom_routes; do
                [[ -d "$_sd" ]] && routes_dir="$_sd" && break
            done
            if [[ -n "$routes_dir" ]]; then
                local route_file
                while IFS= read -r route_file; do
                    [[ -f "$route_file" ]] || continue
                    local route_sub
                    route_sub=$(basename "$route_file" .yml)
                    [[ "$route_sub" == ".reload" || "$route_sub" == "traefik" ]] && continue
                    local route_fqdn="${route_sub}.${domain}"
                    # Quick check: does any record exist?
                    local rec
                    rec=$(curl -s --max-time 5 -H "Authorization: Bearer $cf_token" \
                        "$cf_api/zones/$zone_id/dns_records?name=$route_fqdn" 2>/dev/null)
                    local rec_count
                    rec_count=$(printf '%s' "$rec" | jq -r '.result | length' 2>/dev/null || echo 0)
                    if [[ "$rec_count" -eq 0 ]]; then
                        # No record at all — create CNAME
                        curl -s --max-time 10 -X POST \
                            -H "Authorization: Bearer $cf_token" \
                            -H "Content-Type: application/json" \
                            -d "{\"type\":\"CNAME\",\"name\":\"$route_fqdn\",\"content\":\"$domain\",\"proxied\":true,\"ttl\":1,\"comment\":\"DCS DDNS sync\"}" \
                            "$cf_api/zones/$zone_id/dns_records" >/dev/null 2>&1
                        printf '[%s] DDNS sync: created CNAME %s → %s\n' "$(date -Iseconds)" "$route_fqdn" "$domain" >> "$log_file"
                    fi
                    sleep 2  # Pace CF API calls to avoid rate limits
                done < <(find "$routes_dir" -name '*.yml' -not -name '.reload' 2>/dev/null)
            fi
        fi

        sleep "$interval"
    done
}

# DDNS loop is started inside start_server() — NOT here at top level.
# Top-level code runs for EVERY socat request handler fork. Starting the
# DDNS loop here would spawn a new loop per HTTP request, leaking thousands
# of sleep processes.

# GET /ddns/status — Check DDNS status and current IP
handle_ddns_status() {
    local enabled="$DDNS_ENABLED"
    local current_ip=""
    current_ip=$(_ddns_get_public_ip 2>/dev/null)
    local last_log=""
    last_log=$(tail -1 "$BASE_DIR/.api-auth/ddns.log" 2>/dev/null || echo "")
    local running="false"
    if [[ -f "$DDNS_PID_FILE" ]] && kill -0 "$(cat "$DDNS_PID_FILE" 2>/dev/null)" 2>/dev/null; then
        running="true"
    fi

    _api_success "{
  \"enabled\": $([[ "$enabled" == "true" ]] && echo true || echo false),
  \"running\": $running,
  \"current_ip\": \"$(_api_json_escape "$current_ip")\",
  \"domain\": \"$(_api_json_escape "${TRAEFIK_DOMAIN:-}")\",
  \"subdomains\": \"$(_api_json_escape "${DDNS_SUBDOMAINS:-@}")\",
  \"interval\": ${DDNS_INTERVAL:-300},
  \"last_log\": \"$(_api_json_escape "$last_log")\"
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
        epoch=$(printf '%s' "$line" | sed -n 's/.*"epoch":\([0-9]*\).*/\1/p' 2>/dev/null || echo 0)
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

# Get the remote registry digest for an image WITHOUT pulling.
# Supports Docker Hub (official + user), GHCR, LSCR, and Quay.
# Prints the sha256 digest on stdout, or empty on failure.
_get_remote_digest() {
    local image="$1"
    local registry="registry-1.docker.io"
    local repo="" tag="" token_url="" token=""

    # Parse image reference into registry/repo:tag
    if [[ "$image" == *"/"*"/"* ]]; then
        # Full registry path: ghcr.io/org/repo:tag or lscr.io/org/repo:tag
        registry="${image%%/*}"
        local rest="${image#*/}"
        repo="${rest%%:*}"
        tag="${rest##*:}"
        [[ "$tag" == "$rest" ]] && tag="latest"
    elif [[ "$image" == *"/"* ]]; then
        # Docker Hub user repo: user/repo:tag
        repo="${image%%:*}"
        tag="${image##*:}"
        [[ "$tag" == "$image" || -z "$tag" ]] && tag="latest"
    else
        # Official Docker Hub: repo:tag → library/repo
        local name_part="${image%%:*}"
        tag="${image##*:}"
        [[ "$tag" == "$image" || -z "$tag" ]] && tag="latest"
        repo="library/${name_part}"
    fi

    # Get bearer token (anonymous pull scope)
    local auth_header=""
    case "$registry" in
        ghcr.io)
            token=$(timeout 5 curl -sf "https://ghcr.io/token?scope=repository:${repo}:pull" 2>/dev/null | jq -r '.token // empty' 2>/dev/null)
            ;;
        lscr.io)
            # LSCR proxies to GHCR
            token=$(timeout 5 curl -sf "https://ghcr.io/token?scope=repository:${repo}:pull" 2>/dev/null | jq -r '.token // empty' 2>/dev/null)
            registry="ghcr.io"
            ;;
        registry-1.docker.io|docker.io)
            token=$(timeout 5 curl -sf "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" 2>/dev/null | jq -r '.token // empty' 2>/dev/null)
            registry="registry-1.docker.io"
            ;;
        quay.io)
            # Quay supports anonymous access for public repos
            token=""
            ;;
        *)
            token=""
            ;;
    esac

    [[ -n "$token" ]] && auth_header="Authorization: Bearer $token"

    # HEAD request for the manifest digest
    local digest
    digest=$(timeout 10 curl -sfI \
        ${auth_header:+-H "$auth_header"} \
        -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json" \
        "https://${registry}/v2/${repo}/manifests/${tag}" 2>/dev/null \
        | grep -i 'docker-content-digest' | awk '{print $2}' | tr -d '\r\n')

    printf '%s' "$digest"
}

handle_images_check_updates_get() {
    # Quick local-only check: image age + cached registry results
    local -a entries=()
    local cache_file="$BASE_DIR/.data/image-update-cache.json"

    # Load cached registry results if available
    local -A cached_updates=()
    if [[ -f "$cache_file" ]]; then
        while IFS='=' read -r k v; do
            [[ -n "$k" ]] && cached_updates["$k"]="$v"
        done < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' "$cache_file" 2>/dev/null)
    fi

    while IFS=$'\t' read -r repo tag id size; do
        [[ -z "$repo" || "$repo" == "<none>" ]] && continue
        [[ "$tag" == "<none>" ]] && continue

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

        # Staleness: start with age-based, then override with registry results
        local staleness="current"
        [[ $age_days -gt 30 ]] && staleness="stale"
        [[ $age_days -gt 7 && $age_days -le 30 ]] && staleness="aging"

        # Check cached registry result — overrides age-based staleness
        local update_available="null"
        if [[ -n "${cached_updates[$full_image]:-}" ]]; then
            update_available="${cached_updates[$full_image]}"
            if [[ "$update_available" == "false" ]]; then
                staleness="current"
            elif [[ "$update_available" == "true" ]]; then
                staleness="stale"
            fi
        fi

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

        entries+=("{\"image\": \"$(_api_json_escape "$full_image")\", \"repository\": \"$(_api_json_escape "$repo")\", \"tag\": \"$(_api_json_escape "$tag")\", \"age_days\": $age_days, \"staleness\": \"$staleness\", \"update_available\": $update_available, \"containers\": \"$(_api_json_escape "$containers")\", \"stack\": \"$(_api_json_escape "$stack")\", \"size\": \"$(_api_json_escape "$size")\"}")
    done < <(docker images --format "{{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}" 2>/dev/null)

    local json
    json=$(printf '%s,' "${entries[@]}")
    json="[${json%,}]"
    [[ ${#entries[@]} -eq 0 ]] && json="[]"

    local stale_count=0 aging_count=0 current_count=0 updates_count=0
    for e in "${entries[@]}"; do
        case "$e" in
            *'"staleness": "stale"'*) ((stale_count++)) ;;
            *'"staleness": "aging"'*) ((aging_count++)) ;;
            *) ((current_count++)) ;;
        esac
        [[ "$e" == *'"update_available": true'* ]] && ((updates_count++))
    done

    _api_success "{\"images\": $json, \"total\": ${#entries[@]}, \"stale\": $stale_count, \"aging\": $aging_count, \"current\": $current_count, \"updates_available\": $updates_count}"
}

handle_images_check_updates_post() {
    # Registry digest check: compares local RepoDigests vs remote manifest digest.
    # No image pulling — uses HEAD requests to registry APIs. Fast and bandwidth-free.
    local -a entries=()
    local updates_available=0
    local -A cache_results=()

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == "REPOSITORY"* ]] && continue
        local repo tag id _rest
        read -r repo tag id _rest <<< "$line"
        [[ "$repo" == "<none>" || "$tag" == "<none>" ]] && continue

        local full_image="${repo}:${tag}"

        # Get local digest from RepoDigests
        local local_digest
        local_digest=$(docker image inspect "$full_image" --format='{{index .RepoDigests 0}}' 2>/dev/null | cut -d'@' -f2)

        # Get remote digest from registry (no pull)
        local remote_digest
        remote_digest=$(_get_remote_digest "$full_image")

        local update_available=false
        local status="unknown"
        if [[ -n "$local_digest" && -n "$remote_digest" ]]; then
            if [[ "$local_digest" != "$remote_digest" ]]; then
                update_available=true
                status="update_available"
                ((updates_available++))
            else
                status="up_to_date"
            fi
        elif [[ -z "$remote_digest" ]]; then
            status="check_failed"
        fi

        cache_results["$full_image"]="$update_available"

        entries+=("{\"image\": \"$(_api_json_escape "$full_image")\", \"local_digest\": \"$(_api_json_escape "${local_digest:0:19}")\", \"remote_digest\": \"$(_api_json_escape "${remote_digest:0:19}")\", \"update_available\": $update_available, \"status\": \"$status\"}")

        # Brief delay to avoid rate limiting
        sleep 0.3
    done < <(docker images --format "{{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}" 2>/dev/null)

    # Cache results for the GET endpoint
    mkdir -p "$BASE_DIR/.data" 2>/dev/null
    local cache_json="{"
    local _first=true
    for _ck in "${!cache_results[@]}"; do
        [[ "$_first" == "true" ]] && _first=false || cache_json+=","
        cache_json+="\"$(_api_json_escape "$_ck")\": ${cache_results[$_ck]}"
    done
    cache_json+="}"
    printf '%s' "$cache_json" > "$BASE_DIR/.data/image-update-cache.json"

    local json
    json=$(printf '%s,' "${entries[@]}")
    json="[${json%,}]"
    [[ ${#entries[@]} -eq 0 ]] && json="[]"

    _api_success "{\"images\": $json, \"total\": ${#entries[@]}, \"updates_available\": $updates_available, \"checked_at\": \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\"}"
}

handle_image_update() {
    local image_name="$1"

    # Support both URL path (for simple names) and request body (for names with slashes)
    if [[ -z "$image_name" || "$image_name" == "update" ]] && [[ -n "${2:-}" ]]; then
        # Read from request body
        image_name=$(printf '%s' "$2" | jq -r '.image // .name // empty' 2>/dev/null)
    fi

    # URL-decode if needed
    [[ "$image_name" == *"%"* ]] && image_name=$(printf '%b' "${image_name//%/\\x}")

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

    # Find containers using this image and recreate them with the new image
    # docker restart alone does NOT use the newly pulled image — must recreate
    local -a restarted=()
    local containers
    containers=$(docker ps -q --filter "ancestor=$image_name" 2>/dev/null)
    for cid in $containers; do
        local cname svc_name compose_project
        cname=$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
        svc_name=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$cid" 2>/dev/null)
        # working_dir label gives the compose file directory (v2+), fall back to config_files
        compose_project=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$cid" 2>/dev/null)
        if [[ -z "$compose_project" ]]; then
            # Fallback: extract directory from config_files label (v1 compat)
            local _cfg_files
            _cfg_files=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$cid" 2>/dev/null)
            [[ -n "$_cfg_files" ]] && compose_project=$(dirname "${_cfg_files%%,*}")
        fi

        if [[ -n "$svc_name" && -n "$compose_project" && -f "$compose_project/docker-compose.yml" ]]; then
            # Recreate via docker compose — picks up the new image properly
            local -a _env_args=()
            [[ -f "$compose_project/.env" ]] && _env_args=(--env-file "$compose_project/.env")
            $DOCKER_COMPOSE_CMD -f "$compose_project/docker-compose.yml" "${_env_args[@]}" up -d --force-recreate --no-deps "$svc_name" >/dev/null 2>&1
        else
            # Non-compose container: stop + rm (can't recreate without compose config)
            docker stop "$cid" >/dev/null 2>&1
            docker rm "$cid" >/dev/null 2>&1
        fi
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

    local name trigger target priority tags enabled title_template message_template
    name=$(printf '%s' "$body" | jq -r '.name // empty' 2>/dev/null)
    trigger=$(printf '%s' "$body" | jq -r '.trigger // empty' 2>/dev/null)
    target=$(printf '%s' "$body" | jq -r '.target // "*"' 2>/dev/null)
    priority=$(printf '%s' "$body" | jq -r '.priority // "default"' 2>/dev/null)
    tags=$(printf '%s' "$body" | jq -c '.tags // []' 2>/dev/null)
    enabled=$(printf '%s' "$body" | jq -r '.enabled // true' 2>/dev/null)
    title_template=$(printf '%s' "$body" | jq -r '.title_template // empty' 2>/dev/null)
    message_template=$(printf '%s' "$body" | jq -r '.message_template // empty' 2>/dev/null)

    if [[ -z "$name" || -z "$trigger" ]]; then
        _api_error 400 "Missing required fields: name, trigger"
        return
    fi

    # If updating an existing rule (same id passed), remove old one first
    local existing_id
    existing_id=$(printf '%s' "$body" | jq -r '.id // empty' 2>/dev/null)
    if [[ -n "$existing_id" ]]; then
        jq --arg id "$existing_id" '.rules = [.rules[] | select(.id != $id)]' "$NOTIFICATIONS_FILE" > "${NOTIFICATIONS_FILE}.tmp" 2>/dev/null && mv "${NOTIFICATIONS_FILE}.tmp" "$NOTIFICATIONS_FILE"
    fi

    local rule_id="${existing_id:-rule_$(date +%s)_$RANDOM}"
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local rule
    rule=$(jq -n \
        --arg id "$rule_id" \
        --arg name "$name" \
        --argjson enabled "$enabled" \
        --arg trigger "$trigger" \
        --arg target "$target" \
        --arg priority "$priority" \
        --argjson tags "$tags" \
        --arg title_template "$title_template" \
        --arg message_template "$message_template" \
        --arg created_at "$ts" \
        '{id: $id, name: $name, enabled: $enabled, trigger: $trigger, target: $target, priority: $priority, tags: $tags, title_template: $title_template, message_template: $message_template, created_at: $created_at}')

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

# Fire notifications for a given event. Evaluates all enabled rules,
# substitutes variables in title/message templates, and sends via NTFY.
# Variables: {stack}, {container}, {status}, {event}, {timestamp}, {hostname}
# Usage: _fire_notifications "container_unhealthy" "stack=media-services" "container=Plex" "status=unhealthy"
_fire_notifications() {
    local event="$1"; shift
    local ntfy_url="${NTFY_URL:-}"
    [[ -z "$ntfy_url" ]] && return 0
    [[ ! -f "$NOTIFICATIONS_FILE" ]] && return 0

    # Parse key=value context args into associative array
    local -A ctx=()
    ctx[event]="$event"
    ctx[timestamp]=$(date '+%Y-%m-%d %H:%M:%S')
    ctx[hostname]=$(hostname 2>/dev/null || echo "unknown")
    for arg in "$@"; do
        local k="${arg%%=*}" v="${arg#*=}"
        ctx["$k"]="$v"
    done

    # Read all enabled rules matching this event
    local rules_json
    rules_json=$(jq -c --arg ev "$event" '[.rules[] | select(.enabled == true and .trigger == $ev)]' "$NOTIFICATIONS_FILE" 2>/dev/null)
    [[ -z "$rules_json" || "$rules_json" == "[]" ]] && return 0

    # Process each matching rule
    while IFS= read -r rule; do
        [[ -z "$rule" ]] && continue

        local target priority title_template message_template tags_str
        target=$(printf '%s' "$rule" | jq -r '.target // "*"')
        priority=$(printf '%s' "$rule" | jq -r '.priority // "default"')
        title_template=$(printf '%s' "$rule" | jq -r '.title_template // ""')
        message_template=$(printf '%s' "$rule" | jq -r '.message_template // ""')
        tags_str=$(printf '%s' "$rule" | jq -r '.tags // [] | join(",")')

        # Check target match (wildcard or specific stack/container)
        if [[ "$target" != "*" && "$target" != "${ctx[stack]:-}" && "$target" != "${ctx[container]:-}" ]]; then
            continue
        fi

        # Default templates if user didn't set custom ones
        [[ -z "$title_template" ]] && title_template="DCS — {event}"
        [[ -z "$message_template" ]] && message_template="{event} on {stack}: {container} is {status}"

        # Substitute variables: {key} → value
        local title="$title_template" message="$message_template"
        for k in "${!ctx[@]}"; do
            title="${title//\{$k\}/${ctx[$k]}}"
            message="${message//\{$k\}/${ctx[$k]}}"
        done

        # Clean up unreplaced variables
        title=$(echo "$title" | sed 's/{[a-z_]*}//g; s/  */ /g; s/^ *//; s/ *$//')
        message=$(echo "$message" | sed 's/{[a-z_]*}//g; s/  */ /g; s/^ *//; s/ *$//')

        # Send via NTFY (background, non-blocking)
        (
            local _result
            _result=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
                -H "Title: $title" \
                -H "Priority: $priority" \
                ${tags_str:+-H "Tags: $tags_str"} \
                -d "$message" \
                "$ntfy_url" 2>&1)

            # Log to history
            local _ts
            _ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
            local _entry
            _entry=$(jq -n \
                --arg ts "$_ts" --arg type "$event" --arg title "$title" \
                --arg message "$message" --arg priority "$priority" \
                --argjson code "${_result:-0}" \
                '{timestamp: $ts, type: $type, title: $title, message: $message, priority: $priority, status_code: $code}')
            jq --argjson entry "$_entry" '.history = (.history + [$entry]) | .history = .history[-100:]' \
                "$NOTIFICATIONS_FILE" > "${NOTIFICATIONS_FILE}.tmp" 2>/dev/null && \
                mv "${NOTIFICATIONS_FILE}.tmp" "$NOTIFICATIONS_FILE"
        ) &
    done < <(printf '%s' "$rules_json" | jq -c '.[]')
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
    result=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
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

    # SECURITY: Check for path traversal in archive before extracting
    if tar -tzf "$filepath" 2>/dev/null | grep -qE '^\.\./|/\.\./|^/'; then
        _api_error 403 "Snapshot contains path traversal entries — refusing to extract"
        return
    fi

    # SECURITY: Check for symlinks (symlink-following traversal attack)
    if tar -tvf "$filepath" 2>/dev/null | grep -q '^l'; then
        _api_error 403 "Snapshot contains symbolic links — refusing to extract for security"
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d /tmp/dcs-restore-XXXXXX)
    tar -xzf "$filepath" --no-absolute-names -C "$tmpdir" 2>/dev/null || {
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

    # Restore config (settings only, not auth-sensitive files)
    [[ -d "$tmpdir/config" ]] && cp -r "$tmpdir/config/"* "$BASE_DIR/.config/" 2>/dev/null

    # SECURITY: Do NOT restore root .env — it could contain API_AUTH_ENABLED=false
    # or API_BIND=0.0.0.0 which would compromise security. Admin must manually
    # reconfigure these settings after restore.
    if [[ -f "$tmpdir/root.env" ]]; then
        cp "$tmpdir/root.env" "$BASE_DIR/.env.restored" 2>/dev/null
    fi

    # Restore stacks (with compose security scanning)
    if [[ -d "$tmpdir/stacks" ]]; then
        for stack_dir in "$tmpdir/stacks"/*/; do
            [[ ! -d "$stack_dir" ]] && continue
            local sname
            sname=$(basename "$stack_dir")
            mkdir -p "$COMPOSE_DIR/$sname"
            # SECURITY: Scan restored compose files through security scanner
            if [[ -f "$stack_dir/docker-compose.yml" ]]; then
                local compose_content
                compose_content=$(cat "$stack_dir/docker-compose.yml" 2>/dev/null)
                if _api_scan_compose_security "$compose_content" "snapshot restore ($sname)" "deploy" 2>/dev/null; then
                    cp "$stack_dir/docker-compose.yml" "$COMPOSE_DIR/$sname/" 2>/dev/null
                fi
            fi
            [[ -f "$stack_dir/.env" ]] && cp "$stack_dir/.env" "$COMPOSE_DIR/$sname/" 2>/dev/null
        done
    fi

    # SECURITY: Do NOT restore auth files (users.json, invites.json, etc.)
    # A crafted snapshot could inject attacker credentials or reset auth state.
    # Only restore non-sensitive operational data.
    if [[ -d "$tmpdir/api-auth" ]]; then
        local -a _safe_auth_files=(alerts.json automations.json notifications.json deploy-history.json)
        for f in "$tmpdir/api-auth/"*.json; do
            [[ ! -f "$f" ]] && continue
            local fname
            fname=$(basename "$f")
            local _is_safe=false
            for _sf in "${_safe_auth_files[@]}"; do
                [[ "$fname" == "$_sf" ]] && _is_safe=true
            done
            [[ "$_is_safe" == "true" ]] && cp "$f" "$BASE_DIR/.api-auth/" 2>/dev/null
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

# GET /stacks/:name/compose/history/:version_id — View a specific compose version's content
handle_compose_history_view() {
    local stack="$1"
    local version_id="$2"

    if [[ ! -d "$COMPOSE_DIR/$stack" ]]; then
        _api_error 404 "Stack not found: $stack"
        return
    fi

    # Validate version_id (prevent path traversal)
    if [[ "$version_id" == *".."* ]] || [[ "$version_id" == *"/"* ]]; then
        _api_error 400 "Invalid version ID"
        return
    fi

    local version_file="$COMPOSE_HISTORY_DIR/$stack/${version_id}.yml"
    if [[ ! -f "$version_file" ]]; then
        _api_error 404 "Version not found: $version_id"
        return
    fi

    local content
    content=$(cat "$version_file" 2>/dev/null)
    local size
    size=$(stat -c '%s' "$version_file" 2>/dev/null || echo 0)

    _api_success "{\"stack\": \"$(_api_json_escape "$stack")\", \"version_id\": \"$(_api_json_escape "$version_id")\", \"content\": \"$(_api_json_escape "$content")\", \"size\": $size}"
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

# GET /traefik/status — Check if Traefik is deployed and return domain
handle_traefik_status() {
    local traefik_active="false"
    local traefik_domain=""
    local traefik_routes_dir=""

    # Find the Traefik custom_routes directory — only in the stack that runs Traefik
    local _check_stack
    for _check_stack in $(_api_get_stacks); do
        local _check_appdata="${APP_DATA_DIR:-$COMPOSE_DIR/$_check_stack/App-Data}"
        [[ "$_check_appdata" == ./* ]] && _check_appdata="$COMPOSE_DIR/$_check_stack/${_check_appdata#./}"
        if [[ -d "$_check_appdata/Traefik/custom_routes" ]]; then
            if grep -q 'container_name: Traefik\|image: traefik' "$COMPOSE_DIR/$_check_stack/docker-compose.yml" 2>/dev/null; then
                traefik_active="true"
                traefik_routes_dir="$_check_appdata/Traefik/custom_routes"
                break
            fi
        fi
    done

    if [[ "$traefik_active" == "true" ]]; then
        # Read TRAEFIK_DOMAIN from .env files
        local _env_file
        for _env_file in "$COMPOSE_DIR"/*/".env" "$BASE_DIR/.env"; do
            [[ -f "$_env_file" ]] || continue
            local _domain
            _domain=$(grep -m1 '^TRAEFIK_DOMAIN=' "$_env_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")
            if [[ -n "$_domain" ]]; then
                traefik_domain="$_domain"
                break
            fi
        done
        # Fallback to PROXY_DOMAIN
        if [[ -z "$traefik_domain" ]]; then
            for _env_file in "$COMPOSE_DIR"/*/".env" "$BASE_DIR/.env"; do
                [[ -f "$_env_file" ]] || continue
                local _pdomain
                _pdomain=$(grep -m1 '^PROXY_DOMAIN=' "$_env_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")
                if [[ -n "$_pdomain" ]]; then
                    traefik_domain="$_pdomain"
                    break
                fi
            done
        fi
    fi

    _api_success "{\"active\": $traefik_active, \"domain\": \"$(_api_json_escape "$traefik_domain")\"}"
}

# GET /routes — List all Traefik routes with subdomains
handle_routes() {
    local traefik_routes_dir=""
    local traefik_domain=""

    # Find Traefik custom_routes directory
    local _check_stack
    for _check_stack in $(_api_get_stacks); do
        local _check_appdata="${APP_DATA_DIR:-$COMPOSE_DIR/$_check_stack/App-Data}"
        [[ "$_check_appdata" == ./* ]] && _check_appdata="$COMPOSE_DIR/$_check_stack/${_check_appdata#./}"
        if [[ -d "$_check_appdata/Traefik/custom_routes" ]]; then
            traefik_routes_dir="$_check_appdata/Traefik/custom_routes"
            break
        fi
    done

    if [[ -z "$traefik_routes_dir" ]]; then
        _api_success '{"total": 0, "routes": [], "domain": ""}'
        return
    fi

    # Read domain
    local _env_file
    for _env_file in "$COMPOSE_DIR"/*/".env" "$BASE_DIR/.env"; do
        [[ -f "$_env_file" ]] || continue
        local _d
        _d=$(grep -m1 '^TRAEFIK_DOMAIN=\|^PROXY_DOMAIN=' "$_env_file" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        [[ -n "$_d" ]] && { traefik_domain="$_d"; break; }
    done

    # Scan all route YAML files
    local -a route_entries=()
    local -A seen_subdomains=()
    while IFS= read -r route_file; do
        [[ -f "$route_file" ]] || continue
        local fname stack_name subdomain url_target
        fname=$(basename "$route_file" .yml)
        stack_name=$(basename "$(dirname "$route_file")")

        # Skip .reload marker and non-yml
        [[ "$fname" == ".reload" || "$fname" == ".gitkeep" ]] && continue

        # Extract subdomain from Host() rule
        subdomain=$(sed -n 's/.*Host(`\([^`]*\)`).*/\1/p' "$route_file" 2>/dev/null | head -1)
        [[ -z "$subdomain" ]] && continue

        # Extract backend URL
        url_target=$(grep -m1 'url:' "$route_file" 2>/dev/null | sed 's/.*url:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d ' ')

        # Track duplicates
        local conflict="false"
        if [[ -n "${seen_subdomains[$subdomain]:-}" ]]; then
            conflict="true"
        fi
        seen_subdomains["$subdomain"]="$stack_name/$fname"

        route_entries+=("{\"subdomain\": \"$(_api_json_escape "$subdomain")\", \"service\": \"$(_api_json_escape "$fname")\", \"stack\": \"$(_api_json_escape "$stack_name")\", \"target\": \"$(_api_json_escape "$url_target")\", \"conflict\": $conflict}")
    done < <(find "$traefik_routes_dir" -name '*.yml' -type f 2>/dev/null | sort)

    local json
    json=$(printf '%s,' "${route_entries[@]}")
    json="[${json%,}]"
    [[ ${#route_entries[@]} -eq 0 ]] && json="[]"

    _api_success "{\"total\": ${#route_entries[@]}, \"routes\": $json, \"domain\": \"$(_api_json_escape "$traefik_domain")\"}"
}

# GET /routes/check?subdomain=xyz — Check if a subdomain is available
handle_routes_check() {
    local subdomain="${1:-}"
    [[ -z "$subdomain" ]] && { _api_error 400 "subdomain parameter required"; return; }

    local traefik_routes_dir=""
    local traefik_domain=""

    # Find Traefik routes dir
    for _check_stack in $(_api_get_stacks); do
        local _check_appdata="${APP_DATA_DIR:-$COMPOSE_DIR/$_check_stack/App-Data}"
        [[ "$_check_appdata" == ./* ]] && _check_appdata="$COMPOSE_DIR/$_check_stack/${_check_appdata#./}"
        [[ -d "$_check_appdata/Traefik/custom_routes" ]] && { traefik_routes_dir="$_check_appdata/Traefik/custom_routes"; break; }
    done

    # Read domain
    for _env_file in "$COMPOSE_DIR"/*/".env" "$BASE_DIR/.env"; do
        [[ -f "$_env_file" ]] || continue
        local _d
        _d=$(grep -m1 '^TRAEFIK_DOMAIN=\|^PROXY_DOMAIN=' "$_env_file" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        [[ -n "$_d" ]] && { traefik_domain="$_d"; break; }
    done

    local fqdn="${subdomain}.${traefik_domain}"
    local available="true"
    local existing_stack="" existing_service=""

    if [[ -n "$traefik_routes_dir" ]]; then
        # Search all route files for this subdomain
        while IFS= read -r route_file; do
            [[ -f "$route_file" ]] || continue
            if grep -q "Host(\`${fqdn}\`)\|Host(\`${subdomain}\.${traefik_domain}\`)" "$route_file" 2>/dev/null; then
                available="false"
                existing_service=$(basename "$route_file" .yml)
                existing_stack=$(basename "$(dirname "$route_file")")
                break
            fi
        done < <(find "$traefik_routes_dir" -name '*.yml' -type f 2>/dev/null)
    fi

    _api_success "{\"available\": $available, \"subdomain\": \"$(_api_json_escape "$subdomain")\", \"fqdn\": \"$(_api_json_escape "$fqdn")\", \"existing_service\": \"$(_api_json_escape "$existing_service")\", \"existing_stack\": \"$(_api_json_escape "$existing_stack")\"}"
}

# Helper: Delete a Cloudflare DNS CNAME record by subdomain
_cloudflare_delete_dns() {
    local subdomain="$1" domain="$2" cf_token="$3"
    [[ -z "$cf_token" || -z "$domain" || -z "$subdomain" ]] && return 0
    command -v curl >/dev/null 2>&1 || return 0
    command -v jq >/dev/null 2>&1 || return 0

    local fqdn="${subdomain}.${domain}"
    local cf_api="https://api.cloudflare.com/client/v4"

    # Get zone ID from cache
    local zone_id=""
    local zone_cache="$BASE_DIR/.api-auth/.cf-zone-cache"
    if [[ -f "$zone_cache" ]]; then
        local cached_domain cached_zone
        cached_domain=$(sed -n '1p' "$zone_cache" 2>/dev/null)
        cached_zone=$(sed -n '2p' "$zone_cache" 2>/dev/null)
        [[ "$cached_domain" == "$domain" && -n "$cached_zone" ]] && zone_id="$cached_zone"
    fi
    [[ -z "$zone_id" ]] && return 0

    # Find the record ID
    local record_id
    record_id=$(curl -s --max-time 15 \
        -H "Authorization: Bearer $cf_token" \
        "$cf_api/zones/$zone_id/dns_records?name=${fqdn}&type=CNAME" 2>/dev/null \
        | jq -r '.result[0].id // empty' 2>/dev/null)
    [[ -z "$record_id" ]] && return 0

    # Delete it
    curl -s --max-time 15 -X DELETE \
        -H "Authorization: Bearer $cf_token" \
        "$cf_api/zones/$zone_id/dns_records/$record_id" >/dev/null 2>&1

    printf '[%s] DELETED %s (CNAME)\n' "$(date -Iseconds)" "$fqdn" >> "$BASE_DIR/.api-auth/cf-dns-audit.log" 2>/dev/null
    return 0
}

# PUT /routes/:stack/:service — Update a route file's subdomain
handle_route_update() {
    local stack="$1" service="$2" body="$3"

    _api_check_admin || return
    _api_validate_resource_name "$stack" "stack" || return
    _api_validate_resource_name "$service" "service" || return

    local new_subdomain
    new_subdomain=$(printf '%s' "$body" | jq -r '.subdomain // empty' 2>/dev/null)
    [[ -z "$new_subdomain" ]] && { _api_error 400 "subdomain is required"; return; }

    # Find Traefik routes dir
    local traefik_routes_dir="" traefik_domain=""
    for _check_stack in $(_api_get_stacks); do
        local _check_appdata="${APP_DATA_DIR:-$COMPOSE_DIR/$_check_stack/App-Data}"
        [[ "$_check_appdata" == ./* ]] && _check_appdata="$COMPOSE_DIR/$_check_stack/${_check_appdata#./}"
        [[ -d "$_check_appdata/Traefik/custom_routes" ]] && { traefik_routes_dir="$_check_appdata/Traefik/custom_routes"; break; }
    done
    [[ -z "$traefik_routes_dir" ]] && { _api_error 404 "Traefik routes directory not found"; return; }

    # Read domain
    for _env_file in "$COMPOSE_DIR"/*/".env" "$BASE_DIR/.env"; do
        [[ -f "$_env_file" ]] || continue
        local _d
        _d=$(grep -m1 '^TRAEFIK_DOMAIN=\|^PROXY_DOMAIN=' "$_env_file" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        [[ -n "$_d" ]] && { traefik_domain="$_d"; break; }
    done

    local route_file="$traefik_routes_dir/$stack/${service}.yml"
    [[ ! -f "$route_file" ]] && { _api_error 404 "Route file not found: $stack/$service"; return; }

    # Check if new subdomain conflicts with existing routes
    local new_fqdn="${new_subdomain}.${traefik_domain}"
    local conflict_file
    conflict_file=$(grep -rl "Host(\`${new_fqdn}\`)" "$traefik_routes_dir" 2>/dev/null | grep -v "$route_file" | head -1)
    if [[ -n "$conflict_file" ]]; then
        local conflict_svc conflict_stack
        conflict_svc=$(basename "$conflict_file" .yml)
        conflict_stack=$(basename "$(dirname "$conflict_file")")
        _api_error 409 "Subdomain ${new_subdomain} already used by ${conflict_svc} in ${conflict_stack}"
        return
    fi

    # Read old subdomain for DNS cleanup
    local old_fqdn
    old_fqdn=$(sed -n 's/.*Host(`\([^`]*\)`).*/\1/p' "$route_file" 2>/dev/null | head -1)

    # Update the Host() rule in the route file
    sed -i "s|Host(\`[^)]*\`)|Host(\`${new_fqdn}\`)|g" "$route_file"

    # Touch .reload marker for Traefik file watcher
    touch "$traefik_routes_dir/.reload" 2>/dev/null

    # Update Cloudflare DNS in background (delete old, create new)
    local _cf_token=""
    _cf_token="${CF_DNS_API_TOKEN:-}"
    if [[ -z "$_cf_token" ]]; then
        for _env_file in "$COMPOSE_DIR"/*/".env" "$BASE_DIR/.env"; do
            [[ -f "$_env_file" ]] || continue
            _cf_token=$(grep -m1 '^CF_DNS_API_TOKEN=' "$_env_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")
            [[ -n "$_cf_token" ]] && break
        done
    fi

    if [[ -n "$_cf_token" && -n "$old_fqdn" && "$old_fqdn" != "$new_fqdn" ]]; then
        # Delete old DNS record in background
        _cloudflare_delete_dns "${old_fqdn%%.*}" "$traefik_domain" "$_cf_token" &
        # Create new DNS record in background
        (
            local cf_api="https://api.cloudflare.com/client/v4"
            local zone_cache="$BASE_DIR/.api-auth/.cf-zone-cache"
            local zone_id=""
            if [[ -f "$zone_cache" ]]; then
                local cached_domain cached_zone
                cached_domain=$(sed -n '1p' "$zone_cache" 2>/dev/null)
                cached_zone=$(sed -n '2p' "$zone_cache" 2>/dev/null)
                [[ "$cached_domain" == "$traefik_domain" && -n "$cached_zone" ]] && zone_id="$cached_zone"
            fi
            [[ -z "$zone_id" ]] && exit 0
            curl -s --max-time 15 -X POST \
                -H "Authorization: Bearer $_cf_token" \
                -H "Content-Type: application/json" \
                -d "{\"type\":\"CNAME\",\"name\":\"${new_fqdn}\",\"content\":\"${traefik_domain}\",\"proxied\":true,\"ttl\":1,\"comment\":\"Auto-created by DCS\"}" \
                "$cf_api/zones/$zone_id/dns_records" >/dev/null 2>&1
            printf '[%s] RENAMED %s → %s (route update)\n' "$(date -Iseconds)" "$old_fqdn" "$new_fqdn" >> "$BASE_DIR/.api-auth/cf-dns-audit.log" 2>/dev/null
        ) &
    fi

    _api_audit_log "$REMOTE_ADDR" "ROUTE_UPDATE" "${_current_user:-system}" "Renamed ${old_fqdn} → ${new_fqdn}"
    _api_success "{\"success\": true, \"old_subdomain\": \"$(_api_json_escape "$old_fqdn")\", \"new_subdomain\": \"$(_api_json_escape "$new_fqdn")\", \"service\": \"$(_api_json_escape "$service")\", \"stack\": \"$(_api_json_escape "$stack")\"}"
}

# DELETE /routes/:stack/:service — Delete a route file and optionally clean up DNS
handle_route_delete() {
    local stack="$1" service="$2"

    _api_check_admin || return
    _api_validate_resource_name "$stack" "stack" || return
    _api_validate_resource_name "$service" "service" || return

    # Find Traefik routes dir
    local traefik_routes_dir="" traefik_domain=""
    for _check_stack in $(_api_get_stacks); do
        local _check_appdata="${APP_DATA_DIR:-$COMPOSE_DIR/$_check_stack/App-Data}"
        [[ "$_check_appdata" == ./* ]] && _check_appdata="$COMPOSE_DIR/$_check_stack/${_check_appdata#./}"
        [[ -d "$_check_appdata/Traefik/custom_routes" ]] && { traefik_routes_dir="$_check_appdata/Traefik/custom_routes"; break; }
    done
    [[ -z "$traefik_routes_dir" ]] && { _api_error 404 "Traefik routes directory not found"; return; }

    for _env_file in "$COMPOSE_DIR"/*/".env" "$BASE_DIR/.env"; do
        [[ -f "$_env_file" ]] || continue
        local _d
        _d=$(grep -m1 '^TRAEFIK_DOMAIN=\|^PROXY_DOMAIN=' "$_env_file" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        [[ -n "$_d" ]] && { traefik_domain="$_d"; break; }
    done

    local route_file="$traefik_routes_dir/$stack/${service}.yml"
    [[ ! -f "$route_file" ]] && { _api_error 404 "Route file not found: $stack/$service"; return; }

    # Read subdomain before deleting
    local fqdn
    fqdn=$(sed -n 's/.*Host(`\([^`]*\)`).*/\1/p' "$route_file" 2>/dev/null | head -1)

    # Delete the route file
    rm -f "$route_file"
    touch "$traefik_routes_dir/.reload" 2>/dev/null

    # Clean up Cloudflare DNS record in background
    local _cf_token="${CF_DNS_API_TOKEN:-}"
    if [[ -z "$_cf_token" ]]; then
        for _env_file in "$COMPOSE_DIR"/*/".env" "$BASE_DIR/.env"; do
            [[ -f "$_env_file" ]] || continue
            _cf_token=$(grep -m1 '^CF_DNS_API_TOKEN=' "$_env_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")
            [[ -n "$_cf_token" ]] && break
        done
    fi

    if [[ -n "$_cf_token" && -n "$fqdn" ]]; then
        _cloudflare_delete_dns "${fqdn%%.*}" "$traefik_domain" "$_cf_token" &
    fi

    _api_audit_log "$REMOTE_ADDR" "ROUTE_DELETE" "${_current_user:-system}" "Deleted route ${fqdn} (${stack}/${service})"
    _api_success "{\"success\": true, \"deleted\": \"$(_api_json_escape "$fqdn")\", \"service\": \"$(_api_json_escape "$service")\", \"stack\": \"$(_api_json_escape "$stack")\"}"
}

# GET /dns/records — List all Cloudflare DNS CNAME records
handle_dns_records() {
    local traefik_domain=""
    for _env_file in "$COMPOSE_DIR"/*/".env" "$BASE_DIR/.env"; do
        [[ -f "$_env_file" ]] || continue
        local _d
        _d=$(grep -m1 '^TRAEFIK_DOMAIN=\|^PROXY_DOMAIN=' "$_env_file" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        [[ -n "$_d" ]] && { traefik_domain="$_d"; break; }
    done
    [[ -z "$traefik_domain" ]] && { _api_success '{"total": 0, "records": [], "domain": ""}'; return; }

    local _cf_token="${CF_DNS_API_TOKEN:-}"
    if [[ -z "$_cf_token" ]]; then
        for _env_file in "$COMPOSE_DIR"/*/".env" "$BASE_DIR/.env"; do
            [[ -f "$_env_file" ]] || continue
            _cf_token=$(grep -m1 '^CF_DNS_API_TOKEN=' "$_env_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")
            [[ -n "$_cf_token" ]] && break
        done
    fi

    if [[ -z "$_cf_token" ]]; then
        _api_success "{\"total\": 0, \"records\": [], \"domain\": \"$(_api_json_escape "$traefik_domain")\", \"cf_configured\": false}"
        return
    fi

    local cf_api="https://api.cloudflare.com/client/v4"
    local zone_id=""
    local zone_cache="$BASE_DIR/.api-auth/.cf-zone-cache"
    if [[ -f "$zone_cache" ]]; then
        local cached_domain cached_zone
        cached_domain=$(sed -n '1p' "$zone_cache" 2>/dev/null)
        cached_zone=$(sed -n '2p' "$zone_cache" 2>/dev/null)
        [[ "$cached_domain" == "$traefik_domain" && -n "$cached_zone" ]] && zone_id="$cached_zone"
    fi

    if [[ -z "$zone_id" ]]; then
        zone_id=$(curl -s --max-time 15 -H "Authorization: Bearer $_cf_token" \
            "$cf_api/zones?name=${traefik_domain}&status=active" 2>/dev/null \
            | jq -r '.result[0].id // empty' 2>/dev/null)
        [[ -z "$zone_id" ]] && { _api_success "{\"total\": 0, \"records\": [], \"domain\": \"$(_api_json_escape "$traefik_domain")\", \"cf_configured\": true, \"error\": \"Zone not found\"}"; return; }
        printf '%s\n%s\n' "$traefik_domain" "$zone_id" > "$zone_cache" 2>/dev/null
    fi

    # Fetch all CNAME records for this zone that have the DCS auto-create comment
    local records_json
    records_json=$(curl -s --max-time 30 \
        -H "Authorization: Bearer $_cf_token" \
        "$cf_api/zones/$zone_id/dns_records?type=CNAME&per_page=100" 2>/dev/null)

    local -a entries=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local rec_name rec_content rec_proxied rec_id rec_comment
        rec_id=$(printf '%s' "$line" | jq -r '.id // empty' 2>/dev/null)
        rec_name=$(printf '%s' "$line" | jq -r '.name // empty' 2>/dev/null)
        rec_content=$(printf '%s' "$line" | jq -r '.content // empty' 2>/dev/null)
        rec_proxied=$(printf '%s' "$line" | jq -r '.proxied // false' 2>/dev/null)
        rec_comment=$(printf '%s' "$line" | jq -r '.comment // empty' 2>/dev/null)
        local subdomain="${rec_name%%.*}"
        local managed="false"
        [[ "$rec_comment" == *"DCS"* || "$rec_comment" == *"Auto-created"* ]] && managed="true"
        entries+=("{\"id\": \"$(_api_json_escape "$rec_id")\", \"name\": \"$(_api_json_escape "$rec_name")\", \"subdomain\": \"$(_api_json_escape "$subdomain")\", \"content\": \"$(_api_json_escape "$rec_content")\", \"proxied\": $rec_proxied, \"managed\": $managed}")
    done < <(printf '%s' "$records_json" | jq -c '.result[]' 2>/dev/null)

    local json
    json=$(printf '%s,' "${entries[@]}")
    json="[${json%,}]"
    [[ ${#entries[@]} -eq 0 ]] && json="[]"

    _api_success "{\"total\": ${#entries[@]}, \"records\": $json, \"domain\": \"$(_api_json_escape "$traefik_domain")\", \"cf_configured\": true}"
}

# GET /homarr/status — Check if Homarr is deployed and has an API key configured
handle_homarr_status() {
    local active="false"
    local url=""

    # Check if Homarr container exists (running or stopped)
    if docker inspect Homarr >/dev/null 2>&1; then
        active="true"
        url="http://Homarr:7575"
    elif [[ -n "${HOMARR_URL:-}" ]]; then
        active="true"
        url="$HOMARR_URL"
    fi

    # Check if API key is configured
    local has_key="false"
    if _decrypt_secret "HOMARR_API_KEY" >/dev/null 2>&1; then
        has_key="true"
    fi

    _api_success "{\"active\": $active, \"has_api_key\": $has_key, \"url\": \"$(_api_json_escape "$url")\"}"
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

    # Auto-generate empty secret/key variables (e.g., SECRET_ENCRYPTION_KEY, JWT_SECRET)
    if [[ -f "$tdir/template.json" ]] && command -v jq >/dev/null 2>&1; then
        local _gen_vars
        _gen_vars=$(jq -r '.variables[]? | select(.generate != null or (.name | test("SECRET|_KEY$|ENCRYPTION"))) | .name' "$tdir/template.json" 2>/dev/null)
        for _gv in $_gen_vars; do
            local _gv_val
            _gv_val=$(printf '%s' "$body" | jq -r --arg k "$_gv" '.variables[$k] // empty' 2>/dev/null)
            if [[ -z "$_gv_val" ]]; then
                _gv_val=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p -c 64 2>/dev/null)
                # Replace the empty entry in vars (not append — first match wins in substitution)
                if echo "$vars" | grep -q "^${_gv}="; then
                    vars=$(echo "$vars" | sed "s|^${_gv}=.*|${_gv}=${_gv_val}|")
                else
                    vars+=$'\n'"${_gv}=${_gv_val}"
                fi
            fi
        done
    fi

    while IFS='=' read -r key val; do
        [[ -z "$key" ]] && continue
        # B1: Validate key is a legal env var name
        if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            _api_error 400 "Invalid variable name: $key"
            return
        fi
        # B1: Reject values containing newlines, control chars (YAML injection vector)
        if [[ "$val" == *$'\n'* || "$val" == *$'\r'* ]]; then
            _api_error 400 "Variable value for $key contains invalid characters"
            return
        fi
        # SECURITY: Reject shell metacharacters in variable values
        case "$val" in
            *'`'*|*'$('*)
                _api_error 400 "Variable value for $key contains unsafe characters"
                return
                ;;
        esac
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

    # SELinux: append :z to volume mounts that don't already have a mode suffix.
    # The :z flag relabels files for container access (required on Fedora/RHEL/CentOS).
    # Harmless on non-SELinux systems (Ubuntu, Debian, Arch).
    # Pattern: matches "- host/path:/container/path" but NOT environment vars like "tcp://host:port"
    if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]; then
        template_compose=$(printf '%s' "$template_compose" | awk '
            /^[ \t]*volumes:[ \t]*$/ { in_vol=1; print; next }
            in_vol && /^[ \t]*-[ \t]/ && /:\// {
                if (/:z/ || /:Z/) { print; next }
                if (/:ro$/) { sub(/:ro$/, ":ro,z"); print; next }
                if (/:rw$/) { sub(/:rw$/, ":rw,z"); print; next }
                print $0 ":z"; next
            }
            in_vol && /^[ \t]*[a-zA-Z_]/ && !/^[ \t]*-/ { in_vol=0 }
            { print }
        ')
    fi

    # Inject resource limits if provided in the deploy request
    # Accepts: { "resource_limits": { "mem_limit": "2g", "cpus": 2 } }
    local _rl_mem _rl_cpus
    _rl_mem=$(printf '%s' "$body" | jq -r '.resource_limits.mem_limit // empty' 2>/dev/null)
    _rl_cpus=$(printf '%s' "$body" | jq -r '.resource_limits.cpus // empty' 2>/dev/null)
    if [[ -n "$_rl_mem" || -n "$_rl_cpus" ]]; then
        # Inject mem_limit and/or cpus after each service's restart: line (or image: as fallback)
        template_compose=$(printf '%s' "$template_compose" | awk -v mem="$_rl_mem" -v cpus="$_rl_cpus" '
            /^  [a-zA-Z_-]+:/ { in_svc=1; svc_indent="    "; printed_limits=0 }
            in_svc && /^  [a-zA-Z_-]+:/ && printed_limits { printed_limits=0 }
            in_svc && (/restart:/ || /image:/) && !printed_limits {
                print
                if (mem != "") print svc_indent "mem_limit: " mem
                if (cpus != "") print svc_indent "cpus: " cpus
                printed_limits=1
                next
            }
            { print }
        ')
    fi

    # SECURITY: Scan the resolved template compose for dangerous Docker features.
    # Built-in templates (from .templates/) are trusted, but user-modified variables
    # could inject dangerous YAML, so we still scan after variable substitution.
    # Use lenient mode for deploys: allow docker.sock (needed by Portainer, Watchtower, etc.)
    if ! _api_scan_compose_security "$template_compose" "template deploy ($name)" "deploy"; then
        return
    fi

    # Optional: exclude services the user toggled off (e.g. docker-socket-proxy)
    local exclude_services
    exclude_services=$(printf '%s' "$body" | jq -r '.exclude_services // [] | .[]' 2>/dev/null)
    if [[ -n "$exclude_services" ]]; then
        while IFS= read -r exc_svc; do
            [[ -z "$exc_svc" ]] && continue
            # SECURITY: Validate service name (alphanumeric, hyphens, underscores only)
            if [[ ! "$exc_svc" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then continue; fi
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

    # Homarr integration flag (read early — used in auto-routing loop below)
    local _add_homarr
    _add_homarr=$(printf '%s' "$body" | jq -r '.add_to_homarr // false' 2>/dev/null)

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

    # Normalize ${SECRETS.KEY} → ${SECRETS_KEY} before writing (dots invalid in compose vars)
    merged_compose=$(printf '%s' "$merged_compose" | _normalize_secrets_syntax)

    # Write merged result (atomic overwrite, not blind append)
    printf '%s\n' "$merged_compose" > "$target_dir/docker-compose.yml"

    # Mark this stack as deployed from a trusted built-in template.
    # This allows the compose editor to use "deploy" mode for security scanning,
    # so users can edit ports/env without being blocked by docker.sock or label:disable
    # restrictions that the template legitimately requires.
    printf '%s\n' "$name" >> "$target_dir/.dcs-trusted-templates"
    sort -u -o "$target_dir/.dcs-trusted-templates" "$target_dir/.dcs-trusted-templates"

    # B2: Validate merged compose file — rollback on failure
    local env_args=()
    [[ -f "$target_dir/.env" ]] && env_args=(--env-file "$target_dir/.env")
    local validate_output
    # Inject decrypted SECRETS_* as env vars for validation
    validate_output=$(
        eval "$(_secrets_env_exports "$target_dir/docker-compose.yml")"
        $DOCKER_COMPOSE_CMD -f "$target_dir/docker-compose.yml" "${env_args[@]}" config 2>&1
    )
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

        # Normalize ${SECRETS.KEY} → ${SECRETS_KEY} in .env (dots invalid in compose vars)
        if grep -q 'SECRETS\.' "$env_file" 2>/dev/null; then
            sed -i 's/${SECRETS\.\([A-Za-z0-9_-]*\)}/${SECRETS_\1}/g' "$env_file"
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

    # -----------------------------------------------------------------------
    # Detect Traefik — needed by config generation (Authelia routes) and auto-routing.
    # Checks both existing App-Data AND the deploy request variables.
    # -----------------------------------------------------------------------
    local traefik_routes_dir="" traefik_domain=""
    for _check_stack in $(_api_get_stacks); do
        local _check_appdata="${APP_DATA_DIR:-$COMPOSE_DIR/$_check_stack/App-Data}"
        [[ "$_check_appdata" == ./* ]] && _check_appdata="$COMPOSE_DIR/$_check_stack/${_check_appdata#./}"
        if [[ -d "$_check_appdata/Traefik/custom_routes" ]]; then
            # Verify this stack actually runs Traefik (not a stale artifact)
            if grep -q 'container_name: Traefik\|image: traefik' "$COMPOSE_DIR/$_check_stack/docker-compose.yml" 2>/dev/null; then
                traefik_routes_dir="$_check_appdata/Traefik/custom_routes"
                break
            fi
        fi
    done
    # Domain: check .env files, then request variables, then root .env PROXY_DOMAIN
    for _env_file in "$COMPOSE_DIR"/*/".env" "$BASE_DIR/.env"; do
        [[ -f "$_env_file" ]] || continue
        local _d
        _d=$(grep -m1 '^TRAEFIK_DOMAIN=' "$_env_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        if [[ -n "$_d" ]]; then traefik_domain="$_d"; break; fi
    done
    # Fallback: request variables (critical for first-time Traefik deploy)
    [[ -z "$traefik_domain" ]] && traefik_domain=$(printf '%s' "$body" | jq -r '.variables.TRAEFIK_DOMAIN // empty' 2>/dev/null)
    # Fallback: PROXY_DOMAIN from .env
    if [[ -z "$traefik_domain" ]]; then
        for _env_file in "$COMPOSE_DIR"/*/".env" "$BASE_DIR/.env"; do
            [[ -f "$_env_file" ]] || continue
            local _pd
            _pd=$(grep -m1 '^PROXY_DOMAIN=' "$_env_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")
            if [[ -n "$_pd" ]]; then traefik_domain="$_pd"; break; fi
        done
    fi

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
            mkdir -p "$config_target" 2>/dev/null || docker run --rm -v "$app_data:/d" alpine mkdir -p "/d/$config_target_name" 2>/dev/null || true

            # CRITICAL: Docker creates DIRECTORIES for missing bind-mount targets.
            # If a previous failed deploy left traefik.yml or acme.json as directories,
            # rsync --ignore-existing will skip them. Remove any directory-as-file artifacts
            # BEFORE copying so the real files can be placed.
            while IFS= read -r _src_file; do
                [[ -z "$_src_file" ]] && continue
                local _rel="${_src_file#$tdir/config/}"
                local _dst="$config_target/$_rel"
                if [[ -d "$_dst" && -f "$_src_file" ]]; then
                    rm -rf "$_dst"
                fi
            done < <(find "$tdir/config" -type f 2>/dev/null)

            # Copy config files — use docker if target is root-owned
            if [[ -w "$config_target" ]]; then
                if command -v rsync >/dev/null 2>&1; then
                    rsync -a --ignore-existing "$tdir/config/" "$config_target/" 2>/dev/null || true
                else
                    cp -an "$tdir/config/"* "$config_target/" 2>/dev/null || cp -a "$tdir/config/"* "$config_target/" 2>/dev/null || true
                fi
            else
                # Target is root-owned — use docker alpine to copy
                docker run --rm -v "$tdir/config:/src:ro" -v "$config_target:/dst" alpine sh -c \
                    'cp -rn /src/* /dst/ 2>/dev/null; cp -r /src/* /dst/ 2>/dev/null' || true
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

            # Ensure traefik.yml and acme.json are FILES not directories.
            # Docker creates directories for missing bind mount sources — if the config
            # copy didn't run yet or was skipped, these may be directories which breaks Traefik.
            for _critical_file in "traefik.yml" "acme.json"; do
                local _cf_path="$config_target/$_critical_file"
                if [[ -d "$_cf_path" ]]; then
                    # Docker created a directory — remove it and copy the real file
                    rm -rf "$_cf_path"
                fi
                if [[ ! -f "$_cf_path" ]]; then
                    if [[ -f "$tdir/config/$_critical_file" ]]; then
                        cp -a "$tdir/config/$_critical_file" "$_cf_path"
                    else
                        touch "$_cf_path"
                    fi
                fi
            done
            # Make config files readable by containers (rootless Docker maps UIDs)
            # acme.json MUST be 600 (Traefik enforces this)
            chmod -R 755 "$config_target" 2>/dev/null || \
                docker run --rm -v "$config_target:/cfg" alpine sh -c "chmod -R 755 /cfg" 2>/dev/null
            chmod 600 "$config_target/acme.json" 2>/dev/null || \
                docker run --rm -v "$config_target:/cfg" alpine sh -c "chmod 600 /cfg/acme.json" 2>/dev/null
        fi
    fi

    # Re-detect Traefik AFTER config copy — when deploying the Traefik template itself,
    # the config copy above creates the custom_routes directory. The early detection at
    # the top of the handler found nothing because the directory didn't exist yet.
    if [[ -z "$traefik_routes_dir" ]]; then
        for _check_stack in $(_api_get_stacks); do
            local _check_appdata="${APP_DATA_DIR:-$COMPOSE_DIR/$_check_stack/App-Data}"
            [[ "$_check_appdata" == ./* ]] && _check_appdata="$COMPOSE_DIR/$_check_stack/${_check_appdata#./}"
            if [[ -d "$_check_appdata/Traefik/custom_routes" ]]; then
                if grep -q 'container_name: Traefik\|image: traefik' "$COMPOSE_DIR/$_check_stack/docker-compose.yml" 2>/dev/null; then
                    traefik_routes_dir="$_check_appdata/Traefik/custom_routes"
                    break
                fi
            fi
        done
    fi

    # -----------------------------------------------------------------------
    # Authelia config generation — creates configuration.yml and users_database.yml
    # when deploying the authelia template. Secrets are auto-generated.
    # -----------------------------------------------------------------------
    if [[ "$name" == "authelia" ]]; then
        local _auth_base="${APP_DATA_DIR:-$target_dir/App-Data}"
        [[ "$_auth_base" == ./* ]] && _auth_base="$target_dir/${_auth_base#./}"
        local _auth_dir="$_auth_base/Authelia/config"
        # Write to a temp dir first, then copy with docker (handles root-owned target dirs)
        local _auth_tmp="/tmp/dcs-authelia-$$"
        mkdir -p "$_auth_tmp"
        # Also ensure target dirs exist
        mkdir -p "$_auth_dir" 2>/dev/null || docker run --rm -v "$_auth_base:/d" alpine mkdir -p /d/Authelia/config 2>/dev/null || true

        local _domain="${TRAEFIK_DOMAIN:-example.com}"
        local _admin_user _admin_display _admin_email _admin_pass
        _admin_user=$(printf '%s' "$body" | jq -r '.variables.AUTHELIA_ADMIN_USER // "admin"' 2>/dev/null)
        _admin_display=$(printf '%s' "$body" | jq -r '.variables.AUTHELIA_ADMIN_DISPLAY // ""' 2>/dev/null)
        [[ -z "$_admin_display" ]] && _admin_display="$_admin_user"
        _admin_email=$(printf '%s' "$body" | jq -r '.variables.AUTHELIA_ADMIN_EMAIL // "admin@'$_domain'"' 2>/dev/null)
        _admin_pass=$(printf '%s' "$body" | jq -r '.variables.AUTHELIA_ADMIN_PASSWORD // "changeme"' 2>/dev/null)

        # Generate random secrets
        local _jwt_secret _session_secret _storage_key
        _jwt_secret=$(openssl rand -hex 32 2>/dev/null || head -c 64 /dev/urandom | xxd -p -c 64)
        _session_secret=$(openssl rand -hex 32 2>/dev/null || head -c 64 /dev/urandom | xxd -p -c 64)
        _storage_key=$(openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64)

        # Hash the admin password with Argon2id (via docker if argon2 not installed)
        local _hashed_pass=""
        if command -v authelia >/dev/null 2>&1; then
            _hashed_pass=$(authelia crypto hash generate argon2 --password "$_admin_pass" 2>/dev/null | grep 'Digest:' | sed 's/Digest: //')
        fi
        if [[ -z "$_hashed_pass" ]]; then
            _hashed_pass=$(docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password "$_admin_pass" 2>/dev/null | grep 'Digest:' | sed 's/Digest: //')
        fi
        if [[ -z "$_hashed_pass" ]]; then
            # Fallback: use python3 argon2 if available
            _hashed_pass=$(python3 -c "
import hashlib, os, base64
salt = os.urandom(16)
h = hashlib.scrypt(b'$_admin_pass', salt=salt, n=65536, r=8, p=1, dklen=32)
s64 = base64.b64encode(salt).decode().rstrip('=')
h64 = base64.b64encode(h).decode().rstrip('=')
print(f'\$argon2id\$v=19\$m=65536,t=3,p=4\${s64}\${h64}')
" 2>/dev/null) || _hashed_pass='$argon2id$v=19$m=65536,t=3,p=4$CHANGE_ME_HASH'
        fi

        # Write configuration.yml (only if it doesn't exist — don't overwrite user edits)
        # Always write config on deploy (overwrites container defaults and stale configs)
        if true; then
            cat > "$_auth_tmp/configuration.yml" << AUTHELIA_CONFIG_EOF
---
# =============================================================================
# Authelia Configuration — Auto-generated by DCS
# =============================================================================
# Documentation: https://www.authelia.com/configuration/
# =============================================================================

server:
  address: 'tcp://0.0.0.0:9091/'

log:
  level: info

theme: dark

identity_validation:
  reset_password:
    jwt_secret: '${_jwt_secret}'

totp:
  issuer: ${_domain}

webauthn:
  disable: false
  display_name: Authelia
  attestation_conveyance_preference: indirect
  user_verification: preferred
  timeout: 60s

password_policy:
  standard:
    enabled: true
    min_length: 8
    max_length: 128
    require_uppercase: true
    require_lowercase: true
    require_number: true
    require_special: true

authentication_backend:
  file:
    path: /config/users_database.yml
    password:
      algorithm: argon2id
      iterations: 3
      salt_length: 16
      parallelism: 4
      memory: 65536

access_control:
  default_policy: deny
  rules:
    - domain:
        - "auth.${_domain}"
      policy: bypass
    - domain:
        - "*.${_domain}"
      subject:
        - "group:admins"
      policy: one_factor

session:
  name: authelia_session
  secret: '${_session_secret}'
  expiration: 1h
  inactivity: 5m
  cookies:
    - domain: ${_domain}
      authelia_url: 'https://auth.${_domain}'
      default_redirection_url: 'https://dash.${_domain}'

  redis:
    host: Authelia-Redis
    port: 6379

regulation:
  max_retries: 3
  find_time: 2m
  ban_time: 5m

storage:
  encryption_key: '${_storage_key}'
  local:
    path: /config/db.sqlite3

notifier:
  filesystem:
    filename: /config/notifications.txt
AUTHELIA_CONFIG_EOF
        fi

        # Write users_database.yml (only if it doesn't exist)
        if true; then
            cat > "$_auth_tmp/users_database.yml" << AUTHELIA_USERS_EOF
---
# =============================================================================
# Authelia Users Database — Auto-generated by DCS
# =============================================================================
# Add users here. Passwords must be hashed with Argon2id.
# Generate hashes:
#   docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password 'YOUR_PASSWORD'
# =============================================================================

users:
  ${_admin_user}:
    disabled: false
    displayname: "${_admin_display}"
    password: "${_hashed_pass}"
    email: ${_admin_email}
    groups:
      - admins
AUTHELIA_USERS_EOF
        fi

        # Copy generated configs from temp into target (handles root-owned dirs via docker)
        if [[ -s "$_auth_tmp/configuration.yml" ]]; then
            # Copy to target dir
            cp -f "$_auth_tmp/configuration.yml" "$_auth_dir/" 2>/dev/null && \
            cp -f "$_auth_tmp/users_database.yml" "$_auth_dir/" 2>/dev/null && \
            chmod 644 "$_auth_dir/configuration.yml" "$_auth_dir/users_database.yml" 2>/dev/null || \
            docker run --rm -v "$_auth_dir:/dst" -v "$_auth_tmp:/src" alpine sh -c \
                "cp -f /src/configuration.yml /src/users_database.yml /dst/; chmod 644 /dst/configuration.yml /dst/users_database.yml" 2>/dev/null
            # Cache for post-start re-apply (outside root-owned config dir)
            local _cache_dir="$_auth_base/Authelia/.dcs-cache"
            mkdir -p "$_cache_dir" 2>/dev/null || docker run --rm -v "$_auth_base/Authelia:/d" alpine mkdir -p /d/.dcs-cache 2>/dev/null
            cp -f "$_auth_tmp/configuration.yml" "$_cache_dir/" 2>/dev/null && \
            cp -f "$_auth_tmp/users_database.yml" "$_cache_dir/" 2>/dev/null || \
            docker run --rm -v "$_cache_dir:/dst" -v "$_auth_tmp:/src" alpine sh -c \
                "cp -f /src/configuration.yml /src/users_database.yml /dst/" 2>/dev/null
        fi
        rm -rf "$_auth_tmp"

        # Create Traefik route file for auth.domain → Authelia:9091
        if [[ -n "${traefik_routes_dir:-}" && -n "${traefik_domain:-}" ]]; then
            mkdir -p "$traefik_routes_dir/$target_stack"
            # Always write — overrides the auto-generated route to use auth. subdomain
            if true; then
                cat > "$traefik_routes_dir/$target_stack/authelia.yml" << AUTH_ROUTE_EOF
# Auto-generated Traefik route for Authelia SSO portal
http:
  routers:
    authelia-router:
      entryPoints:
        - "websecure"
      rule: "Host(\`auth.${traefik_domain}\`)"
      service: "authelia"
      middlewares:
        - "authelia-headers"
        - "compress-gzip"
      tls: {}

  services:
    authelia:
      loadBalancer:
        servers:
          - url: "http://Authelia:9091"

  middlewares:
    authelia-headers:
      headers:
        browserXssFilter: true
        customFrameOptionsValue: "SAMEORIGIN"
        customResponseHeaders:
          Cache-Control: "no-store"
          Pragma: "no-cache"
        sslProxyHeaders:
          X-Forwarded-Proto: "https"
        referrerPolicy: "same-origin"
        forceSTSHeader: true
        stsPreload: true
        stsIncludeSubdomains: true
        stsSeconds: 315360000

    authelia-forwardauth:
      forwardAuth:
        address: "http://Authelia:9091/api/authz/forward-auth"
        trustForwardHeader: true
        maxResponseBodySize: 4096
        authResponseHeaders:
          - "Remote-User"
          - "Remote-Groups"
          - "Remote-Name"
          - "Remote-Email"
AUTH_ROUTE_EOF
            fi
        fi
    fi

    # -----------------------------------------------------------------------
    # Cloudflare DNS auto-creation helper
    # -----------------------------------------------------------------------
    # Homarr Integration — auto-register services on the Homarr dashboard
    # -----------------------------------------------------------------------

    # Detect running Homarr instance — returns localhost URL with mapped port
    _detect_homarr() {
        if docker inspect Homarr >/dev/null 2>&1; then
            local _hp
            _hp=$(docker inspect --format='{{range $p, $conf := .NetworkSettings.Ports}}{{if eq $p "7575/tcp"}}{{(index $conf 0).HostPort}}{{end}}{{end}}' Homarr 2>/dev/null)
            [[ -n "$_hp" ]] && echo "http://localhost:${_hp}" && return
        fi
        echo "${HOMARR_URL:-}"
    }

    # Map template names to dashboard icon URLs (walkxcode/dashboard-icons)
    _get_template_icon() {
        local name="$1"
        local base="https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png"
        case "$name" in
            # Media
            plex) echo "$base/plex.png" ;;
            jellyfin) echo "$base/jellyfin.png" ;;
            emby) echo "$base/emby.png" ;;
            tautulli) echo "$base/tautulli.png" ;;
            audiobookshelf) echo "$base/audiobookshelf.png" ;;
            navidrome) echo "$base/navidrome.png" ;;
            # *arr stack
            sonarr) echo "$base/sonarr.png" ;;
            radarr) echo "$base/radarr.png" ;;
            lidarr) echo "$base/lidarr.png" ;;
            prowlarr) echo "$base/prowlarr.png" ;;
            readarr) echo "$base/readarr.png" ;;
            bazarr) echo "$base/bazarr.png" ;;
            # Request managers
            jellyseerr) echo "$base/jellyseerr.png" ;;
            seerr|overseerr) echo "$base/overseerr.png" ;;
            wizarr) echo "$base/wizarr.png" ;;
            # Download
            qbittorrent) echo "$base/qbittorrent.png" ;;
            transmission) echo "$base/transmission.png" ;;
            sabnzbd) echo "$base/sabnzbd.png" ;;
            flaresolverr) echo "$base/flaresolverr.png" ;;
            # Monitoring
            grafana) echo "$base/grafana.png" ;;
            prometheus) echo "$base/prometheus.png" ;;
            uptime-kuma) echo "$base/uptime-kuma.png" ;;
            netdata) echo "$base/netdata.png" ;;
            dashdot) echo "$base/dash-dot.png" ;;
            loki) echo "$base/loki.png" ;;
            # Web & CMS
            ghost) echo "$base/ghost.png" ;;
            wordpress) echo "$base/wordpress.png" ;;
            nginx*) echo "$base/nginx.png" ;;
            # Productivity
            nextcloud*) echo "$base/nextcloud.png" ;;
            mealie) echo "$base/mealie.png" ;;
            paperless*) echo "$base/paperless-ngx.png" ;;
            vikunja) echo "$base/vikunja.png" ;;
            trilium) echo "$base/trilium.png" ;;
            memos) echo "$base/memos.png" ;;
            excalidraw) echo "$base/excalidraw.png" ;;
            actual*) echo "$base/actual.png" ;;
            tandoor) echo "$base/tandoor.png" ;;
            # Photos & Storage
            immich) echo "$base/immich.png" ;;
            syncthing) echo "$base/syncthing.png" ;;
            filebrowser) echo "$base/filebrowser.png" ;;
            privatebin) echo "$base/privatebin.png" ;;
            calibre*) echo "$base/calibre-web.png" ;;
            # Security & Network
            traefik) echo "$base/traefik.png" ;;
            authelia) echo "$base/authelia.png" ;;
            vaultwarden) echo "$base/vaultwarden.png" ;;
            adguard*) echo "$base/adguard-home.png" ;;
            pihole) echo "$base/pi-hole.png" ;;
            wg-easy) echo "$base/wireguard.png" ;;
            crowdsec) echo "$base/crowdsec.png" ;;
            # Development
            gitea) echo "$base/gitea.png" ;;
            code-server) echo "$base/code-server.png" ;;
            it-tools) echo "$base/it-tools.png" ;;
            # Databases
            mysql) echo "$base/mysql.png" ;;
            postgres*) echo "$base/postgresql.png" ;;
            redis*) echo "$base/redis.png" ;;
            influxdb) echo "$base/influxdb.png" ;;
            mariadb) echo "$base/mariadb.png" ;;
            mongo*) echo "$base/mongodb.png" ;;
            pgadmin) echo "$base/pgadmin.png" ;;
            # Automation & Notifications
            n8n) echo "$base/n8n.png" ;;
            ntfy) echo "$base/ntfy.png" ;;
            changedetection*) echo "$base/changedetection-io.png" ;;
            komodo) echo "$base/komodo.png" ;;
            # Dashboards
            dashy) echo "$base/dashy.png" ;;
            homepage) echo "$base/homepage.png" ;;
            homarr) echo "$base/homarr.png" ;;
            # Infrastructure
            portainer) echo "$base/portainer.png" ;;
            watchtower) echo "$base/watchtower.png" ;;
            # Search & Privacy
            searxng) echo "$base/searxng.png" ;;
            freshrss) echo "$base/freshrss.png" ;;
            # Other
            homeassistant) echo "$base/home-assistant.png" ;;
            speedtest*) echo "$base/speedtest-tracker.png" ;;
            semaphore) echo "$base/semaphore.png" ;;
            gotify) echo "$base/gotify.png" ;;
            monkeytype) echo "$base/monkeytype.png" ;;
            # Smart fallback: try the template name directly (works for many services)
            *) echo "$base/${name}.png" ;;
        esac
    }

    # Register an app on the Homarr dashboard via direct SQLite INSERT.
    # Bypasses tRPC API entirely — no SSR revalidation, no crash, instant.
    # Falls back to tRPC if SQLite is unavailable.
    _homarr_register_app() {
        local app_name="$1" app_url="$2" icon_url="$3" description="$4"

        [[ -z "$description" ]] && description="Deployed via DCS"
        [[ -z "$icon_url" ]] && icon_url="https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/docker.png"

        # Find Homarr's SQLite DB on the host (mounted volume)
        local db_path=""
        local _sd
        for _sd in "$COMPOSE_DIR"/*/App-Data/Homarr/appdata/db/db.sqlite; do
            [[ -f "$_sd" ]] && db_path="$_sd" && break
        done

        # Generate unique ID
        local app_id
        app_id="dcs_$(head -c 16 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 20)"

        # Escape single quotes for SQL
        local _sq_name="${app_name//\'/\'\'}"
        local _sq_url="${app_url//\'/\'\'}"
        local _sq_icon="${icon_url//\'/\'\'}"
        local _sq_desc="${description//\'/\'\'}"

        # Write via detached script (socat kills background subshells)
        local _reg_script
        _reg_script=$(mktemp /tmp/dcs-homarr-reg-XXXXXX.sh)

        if [[ -n "$db_path" ]] && command -v sqlite3 >/dev/null 2>&1; then
            # Primary: SQLite — instant, no API call, no SSR crash
            cat > "$_reg_script" << HOMARR_SQLITE_EOF
#!/bin/bash
DB="$db_path"
EXISTS=\$(sqlite3 "\$DB" "SELECT COUNT(*) FROM app WHERE href='$_sq_url';" 2>/dev/null)
if [[ "\$EXISTS" == "0" ]]; then
    sqlite3 "\$DB" "INSERT INTO app (id, name, description, icon_url, href, ping_url) VALUES ('$app_id', '$_sq_name', '$_sq_desc', '$_sq_icon', '$_sq_url', '$_sq_url');" 2>/dev/null
    echo "\$(date): ✓ Registered '$app_name' on Homarr (SQLite)" >> "$BASE_DIR/logs/homarr-register.log"
else
    echo "\$(date): ⊘ Skipped '$app_name' — already exists on Homarr" >> "$BASE_DIR/logs/homarr-register.log"
fi
rm -f "$_reg_script"
HOMARR_SQLITE_EOF
        else
            # Fallback: tRPC API (when sqlite3 is not installed)
            local homarr_port=""
            homarr_port=$(docker inspect --format='{{range $p, $conf := .NetworkSettings.Ports}}{{if eq $p "7575/tcp"}}{{(index $conf 0).HostPort}}{{end}}{{end}}' Homarr 2>/dev/null)
            [[ -z "$homarr_port" ]] && rm -f "$_reg_script" && return 0
            local api_key
            api_key=$(_decrypt_secret "HOMARR_API_KEY") || { rm -f "$_reg_script"; return 0; }
            [[ -z "$api_key" ]] && rm -f "$_reg_script" && return 0
            local payload
            payload=$(jq -nc --arg name "$app_name" --arg href "$app_url" --arg icon "$icon_url" --arg desc "$description" --arg ping "$app_url" \
                '{json: {name: $name, href: $href, description: $desc, iconUrl: $icon, pingUrl: $ping}}')
            cat > "$_reg_script" << HOMARR_API_EOF
#!/bin/bash
sleep 10
for _i in 1 2 3; do
    _code=\$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X POST "http://localhost:${homarr_port}/api/trpc/app.create" -H "ApiKey: $api_key" -H "Content-Type: application/json" -d '$payload' 2>/dev/null)
    echo "\$(date): Homarr register '$app_name' attempt \$_i — HTTP \$_code (tRPC fallback)" >> "$BASE_DIR/logs/homarr-register.log"
    [[ "\$_code" == "200" ]] && break
    sleep 5
done
rm -f "$_reg_script"
HOMARR_API_EOF
        fi

        chmod +x "$_reg_script"
        nohup bash "$_reg_script" >/dev/null 2>&1 &
    }

    # -----------------------------------------------------------------------
    # Creates a CNAME record for a subdomain pointing to the root domain.
    # Requires CF_DNS_API_TOKEN. Zone ID is auto-detected and cached.
    # Non-fatal — errors are logged but never block deployment.
    # -----------------------------------------------------------------------
    _cloudflare_add_dns() {
        local subdomain="$1" domain="$2" cf_token="$3"
        [[ -z "$cf_token" || -z "$domain" || -z "$subdomain" ]] && return 0
        command -v curl >/dev/null 2>&1 || return 0
        command -v jq >/dev/null 2>&1 || return 0

        local fqdn="${subdomain}.${domain}"
        local cf_api="https://api.cloudflare.com/client/v4"
        local cf_auth=(-H "Authorization: Bearer $cf_token")

        # ── Get or cache Zone ID ──
        local zone_id=""
        local zone_cache="$BASE_DIR/.api-auth/.cf-zone-cache"
        mkdir -p "$(dirname "$zone_cache")" 2>/dev/null
        if [[ -f "$zone_cache" ]]; then
            local cached_domain cached_zone
            cached_domain=$(sed -n '1p' "$zone_cache" 2>/dev/null)
            cached_zone=$(sed -n '2p' "$zone_cache" 2>/dev/null)
            [[ "$cached_domain" == "$domain" && -n "$cached_zone" ]] && zone_id="$cached_zone"
        fi

        if [[ -z "$zone_id" ]]; then
            # Try exact domain first, then strip subdomains to find zone
            local _lookup_domain="$domain"
            local _attempts=0
            while [[ -z "$zone_id" && "$_attempts" -lt 3 ]]; do
                local zone_resp
                zone_resp=$(curl -s --max-time 15 "${cf_auth[@]}" \
                    "$cf_api/zones?name=${_lookup_domain}&status=active" 2>/dev/null)
                zone_id=$(printf '%s' "$zone_resp" | jq -r '.result[0].id // empty' 2>/dev/null)
                if [[ -n "$zone_id" ]]; then
                    break
                fi
                # Strip leftmost subdomain: sub.example.com → example.com
                _lookup_domain="${_lookup_domain#*.}"
                [[ "$_lookup_domain" == *.* ]] || break
                _attempts=$((_attempts + 1))
            done

            if [[ -z "$zone_id" ]]; then
                return 0  # Zone not found — skip silently
            fi
            printf '%s\n%s\n' "$domain" "$zone_id" > "$zone_cache" 2>/dev/null
        fi

        # ── Create CNAME: subdomain.domain.com → domain.com (proxied) ──
        # Single attempt — no duplicate check (saves an API call, avoids rate limits).
        # If the record already exists, CF returns an error which we silently ignore.
        local create_resp
        create_resp=$(curl -s --max-time 15 -X POST \
            "${cf_auth[@]}" \
            -H "Content-Type: application/json" \
            -d "{\"type\":\"CNAME\",\"name\":\"${fqdn}\",\"content\":\"${domain}\",\"proxied\":true,\"ttl\":1,\"comment\":\"Auto-created by DCS\"}" \
            "$cf_api/zones/$zone_id/dns_records" 2>/dev/null)

        local success
        success=$(printf '%s' "$create_resp" | jq -r '.success // false' 2>/dev/null)

        if [[ "$success" == "true" ]]; then
            printf '[%s] CREATED %s → %s (CNAME, proxied)\n' "$(date -Iseconds)" "$fqdn" "$domain" >> "$BASE_DIR/.api-auth/cf-dns-audit.log" 2>/dev/null
        fi

        return 0
    }

    # -----------------------------------------------------------------------
    # Auto-generate Traefik route files for deployed services
    # -----------------------------------------------------------------------
    # If Traefik's custom_routes directory exists, create a route file for
    # each service that has an exposed port. Uses the Traefik file provider
    # which auto-discovers new .yml files (no restart needed).
    # Skip for the traefik template itself (it ships its own routes).
    # -----------------------------------------------------------------------
    if [[ "$name" != "traefik" ]]; then
        # traefik_routes_dir and traefik_domain already computed above
        if [[ -n "$traefik_routes_dir" && -n "$traefik_domain" && "$traefik_domain" != "example.com" ]]; then
                mkdir -p "$traefik_routes_dir/$target_stack"

                # Read CF_DNS_API_TOKEN for auto DNS record creation
                # Priority: request body variables > stack .env files > root .env > environment
                local _cf_token=""
                # 1. From deploy request variables
                _cf_token=$(printf '%s' "$body" | jq -r '.variables.CF_DNS_API_TOKEN // empty' 2>/dev/null)
                # 2. From environment (already sourced from .env at startup)
                [[ -z "$_cf_token" ]] && _cf_token="${CF_DNS_API_TOKEN:-}"
                # 3. From stack .env files
                if [[ -z "$_cf_token" ]]; then
                    for _env_file in "$COMPOSE_DIR"/*/".env" "$BASE_DIR/.env"; do
                        [[ -f "$_env_file" ]] || continue
                        local _tk
                        _tk=$(grep -m1 '^CF_DNS_API_TOKEN=' "$_env_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")
                        if [[ -n "$_tk" ]]; then
                            _cf_token="$_tk"
                            break
                        fi
                    done
                fi

                # If user provided custom route content, save those first.
                # The auto-generation loop below will skip services that already have route files.
                local _custom_routes_json
                _custom_routes_json=$(printf '%s' "$body" | jq -c '.custom_routes // {}' 2>/dev/null)
                if [[ -n "$_custom_routes_json" && "$_custom_routes_json" != "{}" && "$_custom_routes_json" != "null" ]]; then
                    local _cr_key
                    for _cr_key in $(printf '%s' "$_custom_routes_json" | jq -r 'keys[]' 2>/dev/null); do
                        [[ -z "$_cr_key" ]] && continue
                        # Validate key is safe for filename
                        if [[ ! "$_cr_key" =~ ^[a-zA-Z0-9_-]+$ ]]; then continue; fi
                        local _cr_content
                        _cr_content=$(printf '%s' "$_custom_routes_json" | jq -r --arg k "$_cr_key" '.[$k] // empty' 2>/dev/null)
                        [[ -z "$_cr_content" ]] && continue
                        printf '%s\n' "$_cr_content" > "$traefik_routes_dir/$target_stack/${_cr_key}.yml"
                    done
                fi

                # Check if template.json has a route_override (for templates like Nextcloud AIO
                # where the routable service isn't in the compose file — it's spawned externally).
                # route_override: { subdomain, port, protocol, use_host_ip }
                # When use_host_ip is true, the route points to the host's LAN IP instead of
                # a Docker container name, because the spawned container isn't on Traefik's network.
                local _route_override=""
                _route_override=$(jq -c '.route_override // empty' "$tdir/template.json" 2>/dev/null)
                if [[ -n "$_route_override" ]]; then
                    local _ro_sub _ro_port _ro_proto _ro_host_ip
                    _ro_sub=$(printf '%s' "$_route_override" | jq -r '.subdomain // empty')
                    _ro_port=$(printf '%s' "$_route_override" | jq -r '.port // empty')
                    _ro_proto=$(printf '%s' "$_route_override" | jq -r '.protocol // "http"')
                    _ro_host_ip=$(printf '%s' "$_route_override" | jq -r '.use_host_ip // false')
                    if [[ -n "$_ro_port" ]]; then
                        [[ -z "$_ro_sub" ]] && _ro_sub="$name"
                        # Allow subdomain override from deploy variables (e.g. NEXTCLOUD_DOMAIN)
                        local _ro_domain_var
                        _ro_domain_var=$(printf '%s' "$body" | jq -r '.variables.NEXTCLOUD_DOMAIN // empty' 2>/dev/null)
                        if [[ -n "$_ro_domain_var" && "$_ro_domain_var" == *.* ]]; then
                            _ro_sub="${_ro_domain_var%%.*}"
                        fi
                        # Determine the route target: host IP or container name
                        local _ro_target=""
                        if [[ "$_ro_host_ip" == "true" ]]; then
                            # Detect the host's LAN IP for the route target
                            _ro_target=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
                            [[ -z "$_ro_target" ]] && _ro_target=$(hostname -I 2>/dev/null | awk '{print $1}')
                        fi
                        if [[ -z "$_ro_target" ]]; then
                            # Fallback to container name from route_override
                            _ro_target=$(printf '%s' "$_route_override" | jq -r '.container // empty')
                        fi
                        [[ -z "$_ro_target" ]] && _ro_target="$name"

                        local _ro_id
                        _ro_id=$(printf '%s' "$_ro_sub" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]-' '-')
                        if [[ ! -f "$traefik_routes_dir/$target_stack/${name}.yml" ]]; then
                            cat > "$traefik_routes_dir/$target_stack/${name}.yml" << OVERRIDE_EOF
# Auto-generated Traefik route for: ${_ro_sub}
# Edit the subdomain or middlewares as needed.

http:
  routers:
    ${_ro_id}-router:
      entryPoints:
        - "websecure"
      rule: "Host(\`${_ro_sub}.${traefik_domain}\`)"
      service: "${_ro_id}"
      middlewares:
        - "traefik-chain"
        - "compress-gzip"
      tls: {}

  services:
    ${_ro_id}:
      loadBalancer:
        servers:
          - url: "${_ro_proto}://${_ro_target}:${_ro_port}"
OVERRIDE_EOF
                        fi
                        # Create DNS record for the override subdomain
                        if [[ -n "$_cf_token" ]]; then
                            _cloudflare_add_dns "$_ro_sub" "$traefik_domain" "$_cf_token"
                            sleep 1
                        fi
                        # Register route_override with Homarr
                        if [[ "${_add_homarr:-}" == "true" ]]; then
                            local _hm_ro_name _hm_ro_icon _hm_ro_desc
                            _hm_ro_name=$(jq -r '.title // .name // empty' "$tdir/template.json" 2>/dev/null)
                            [[ -z "$_hm_ro_name" ]] && _hm_ro_name="$name"
                            _hm_ro_icon=$(_get_template_icon "$name")
                            _hm_ro_desc=$(jq -r '.description // empty' "$tdir/template.json" 2>/dev/null | head -c 200)
                            _homarr_register_app "$_hm_ro_name" "https://${_ro_sub}.${traefik_domain}" "$_hm_ro_icon" "$_hm_ro_desc"
                        fi
                    fi
                fi

                # Parse each service from the SUBSTITUTED template compose
                local _svc_name
                while IFS= read -r _svc_name; do
                    [[ -z "$_svc_name" ]] && continue

                    local _route_exists=false
                    [[ -f "$traefik_routes_dir/$target_stack/${_svc_name}.yml" ]] && _route_exists=true

                    # Extract container_name for this service
                    local _container_name=""
                    _container_name=$(printf '%s' "$template_compose" | awk -v svc="  ${_svc_name}:" '
                        BEGIN { in_svc=0 }
                        $0 == svc || index($0, svc) == 1 { in_svc=1; next }
                        in_svc && /^  [a-zA-Z_-]/ { in_svc=0 }
                        in_svc && /^[a-zA-Z]/ { in_svc=0 }
                        in_svc && /container_name:/ { gsub(/.*container_name:[[:space:]]*/, ""); gsub(/[[:space:]]*$/, ""); print; exit }
                    ')
                    # Fallback: use service name as container name
                    [[ -z "$_container_name" ]] && _container_name="$_svc_name"

                    # Extract the first container port (right side of host:container mapping)
                    # Handles ${VAR:-default} patterns by resolving them to defaults first
                    local _container_port=""
                    local _port_line
                    _port_line=$(printf '%s' "$template_compose" | awk -v svc="  ${_svc_name}:" '
                        BEGIN { in_svc=0; in_ports=0 }
                        $0 == svc || index($0, svc) == 1 { in_svc=1; next }
                        in_svc && /^  [a-zA-Z_-]/ { in_svc=0 }
                        in_svc && /^[a-zA-Z]/ { in_svc=0 }
                        in_svc && /ports:/ { in_ports=1; next }
                        in_svc && in_ports && /^      - / { gsub(/^[[:space:]]*-[[:space:]]*/, ""); gsub(/"/, ""); print; exit }
                        in_svc && in_ports && /^    [^ ]/ { in_ports=0 }
                    ')
                    if [[ -n "$_port_line" ]]; then
                        # Resolve ${VAR:-default} to default values first
                        local _resolved_port
                        _resolved_port=$(printf '%s' "$_port_line" | sed 's/${[A-Za-z_][A-Za-z0-9_]*:-\([^}]*\)}/\1/g; s/${[A-Za-z_][A-Za-z0-9_]*}//g')
                        # Now split on colon safely — take the right side (container port)
                        _container_port=$(echo "$_resolved_port" | awk -F: '{print $NF}' | sed 's|/.*||')
                    fi

                    # Skip services without ports (databases, workers, etc.)
                    [[ -z "$_container_port" ]] && continue

                    # Skip localhost-bound ports (not publicly routable)
                    if [[ "$_port_line" == *"127.0.0.1"* || "$_port_line" == *"localhost"* ]]; then
                        continue
                    fi

                    # Determine protocol (HTTPS for 443/9443 ports, HTTP otherwise)
                    local _protocol="http"
                    if [[ "$_container_port" == "443" || "$_container_port" == "9443" || "$_container_port" == "8443" ]]; then
                        _protocol="https"
                    fi

                    # Generate the route file (skip if already exists — preserves user edits)
                    local _route_id
                    _route_id=$(printf '%s' "$_svc_name" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]-' '-')

                    if [[ "$_route_exists" != "true" ]]; then
                    cat > "$traefik_routes_dir/$target_stack/${_svc_name}.yml" << ROUTE_EOF
# =============================================================================
# Auto-generated Traefik route for: $_svc_name
# =============================================================================
# Created during template deployment to $target_stack.
# Traefik's file provider auto-discovers this file (no restart needed).
# Edit the subdomain or middlewares as needed.
# =============================================================================

http:
  routers:
    ${_route_id}-router:
      entryPoints:
        - "websecure"
      rule: "Host(\`${_svc_name}.${traefik_domain}\`)"
      service: "${_route_id}"
      middlewares:
        - "traefik-chain"
        - "compress-gzip"
      tls: {}

  services:
    ${_route_id}:
      loadBalancer:
        servers:
          - url: "${_protocol}://${_container_name}:${_container_port}"
ROUTE_EOF
                    fi
                    # Auto-create Cloudflare DNS record using the actual subdomain from the route file
                    # (respects user-edited subdomains, not just the service name)
                    if [[ -n "$_cf_token" ]]; then
                        local _dns_sub="$_svc_name"
                        # Extract subdomain from the route file's Host() rule if it exists
                        local _route_file="$traefik_routes_dir/$target_stack/${_svc_name}.yml"
                        if [[ -f "$_route_file" ]]; then
                            local _host_sub
                            _host_sub=$(sed -n 's/.*Host(`\([^.]*\).*/\1/p' "$_route_file" 2>/dev/null | head -1)
                            [[ -n "$_host_sub" ]] && _dns_sub="$_host_sub"
                        fi
                        _cloudflare_add_dns "$_dns_sub" "$traefik_domain" "$_cf_token"
                        sleep 1
                    fi

                    # Register with Homarr dashboard if enabled
                    if [[ "${_add_homarr:-}" == "true" ]]; then
                        local _hm_name _hm_icon _hm_desc
                        _hm_name=$(jq -r '.title // .name // empty' "$tdir/template.json" 2>/dev/null)
                        [[ -z "$_hm_name" ]] && _hm_name="$_svc_name"
                        _hm_icon=$(_get_template_icon "$name")
                        _hm_desc=$(jq -r '.description // empty' "$tdir/template.json" 2>/dev/null | head -c 200)
                        # Use subdomain from route file for the URL
                        local _hm_sub="$_svc_name"
                        if [[ -f "$traefik_routes_dir/$target_stack/${_svc_name}.yml" ]]; then
                            local _hm_host
                            _hm_host=$(sed -n 's/.*Host(`\([^.]*\).*/\1/p' "$traefik_routes_dir/$target_stack/${_svc_name}.yml" 2>/dev/null | head -1)
                            [[ -n "$_hm_host" ]] && _hm_sub="$_hm_host"
                        fi
                        _homarr_register_app "$_hm_name" "https://${_hm_sub}.${traefik_domain}" "$_hm_icon" "$_hm_desc"
                    fi

                    # Add proxy network to this service in the target compose file
                    # so Traefik can reach it. Uses docker compose to connect at runtime
                    # AND injects into compose for persistence across restarts.
                    # Connect immediately via Docker CLI (works even before compose recreate)
                    docker network connect proxy "$_container_name" 2>/dev/null || true

                    # Also inject into compose file for persistence
                    local _tc
                    _tc=$(cat "$target_dir/docker-compose.yml")
                    # Check if this service already has proxy in its networks
                    local _has_proxy
                    _has_proxy=$(printf '%s' "$_tc" | python3 -c "
import sys, re
content = sys.stdin.read()
# Find the service block
pattern = r'^  ${_svc_name}:.*?(?=^  [a-zA-Z]|\Z)'
match = re.search(pattern, content, re.MULTILINE | re.DOTALL)
if match and 'proxy' in match.group():
    print('yes')
else:
    print('no')
" 2>/dev/null || echo "no")
                    if [[ "$_has_proxy" != "yes" ]]; then
                        # Use python for reliable YAML-aware insertion
                        printf '%s' "$_tc" | python3 -c "
import sys
lines = sys.stdin.read().split('\n')
result = []
in_svc = False
svc_name = '  ${_svc_name}:'
injected = False
for i, line in enumerate(lines):
    if line.startswith(svc_name):
        in_svc = True
        result.append(line)
        continue
    if in_svc and not injected:
        # Check if next line is a new service or top-level key
        if line and not line.startswith('    ') and not line.startswith('      '):
            result.append('    networks:')
            result.append('      - default')
            result.append('      - proxy')
            in_svc = False
            injected = True
    result.append(line)
if in_svc and not injected:
    result.append('    networks:')
    result.append('      - default')
    result.append('      - proxy')
print('\n'.join(result))
" > "$target_dir/docker-compose.yml" 2>/dev/null || true
                    fi

                done <<< "$template_services"

                # Trigger Traefik's file watcher to reload routes
                # Touch the root custom_routes dir and a marker file to ensure inotify fires
                touch "$traefik_routes_dir" 2>/dev/null
                touch "$traefik_routes_dir/.reload" 2>/dev/null

                # Ensure the proxy external network is declared in the compose file
                local _final_compose
                _final_compose=$(cat "$target_dir/docker-compose.yml")
                if ! printf '%s' "$_final_compose" | grep -q 'name: proxy'; then
                    # Add proxy network declaration at the end
                    if printf '%s' "$_final_compose" | grep -q '^networks:'; then
                        # networks section exists — append proxy to it
                        _final_compose=$(printf '%s\n' "$_final_compose" | awk '
                            /^networks:/ { print; print "  proxy:"; print "    name: proxy"; print "    external: true"; next }
                            { print }
                        ')
                    else
                        # No networks section — add one at the end
                        _final_compose=$(printf '%s\nnetworks:\n  proxy:\n    name: proxy\n    external: true\n' "$_final_compose")
                    fi
                    printf '%s\n' "$_final_compose" > "$target_dir/docker-compose.yml"
                fi
        fi
    fi

    # -----------------------------------------------------------------------
    # Infrastructure DNS — create subdomains for core services (traefik, auth)
    # These aren't port-scanned; they need explicit DNS entries.
    # -----------------------------------------------------------------------
    if [[ -n "${traefik_domain:-}" ]]; then
        local _infra_cf_token="${CF_DNS_API_TOKEN:-}"
        [[ -z "$_infra_cf_token" ]] && _infra_cf_token=$(printf '%s' "$body" | jq -r '.variables.CF_DNS_API_TOKEN // empty' 2>/dev/null)
        [[ -z "$_infra_cf_token" ]] && _infra_cf_token=$(grep -m1 '^CF_DNS_API_TOKEN=' "$COMPOSE_DIR"/*/".env" "$BASE_DIR/.env" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")

        printf '[%s] INFRA-DNS: name=%s domain=%s token=%s\n' \
            "$(date -Iseconds)" "$name" "$traefik_domain" "${_infra_cf_token:0:8}" \
            >> "$BASE_DIR/.api-auth/cf-dns-audit.log" 2>/dev/null

        if [[ -n "$_infra_cf_token" ]]; then
            case "$name" in
                traefik)
                    _cloudflare_add_dns "traefik" "$traefik_domain" "$_infra_cf_token"
                    sleep 2
                    ;;
                authelia)
                    _cloudflare_add_dns "auth" "$traefik_domain" "$_infra_cf_token"
                    sleep 2
                    ;;
            esac
        else
            printf '[%s] INFRA-DNS: NO TOKEN FOUND\n' "$(date -Iseconds)" \
                >> "$BASE_DIR/.api-auth/cf-dns-audit.log" 2>/dev/null
        fi
    else
        printf '[%s] INFRA-DNS: NO DOMAIN (traefik_domain empty)\n' "$(date -Iseconds)" \
            >> "$BASE_DIR/.api-auth/cf-dns-audit.log" 2>/dev/null
    fi

    # Auto-start if requested — run in background so API responds immediately.
    # After compose up, fix App-Data ownership for non-root images.
    local auto_start connect_proxy
    auto_start=$(printf '%s' "$body" | jq -r '.auto_start // false' 2>/dev/null)
    connect_proxy=$(printf '%s' "$body" | jq -r '.connect_proxy // false' 2>/dev/null)
    local started=false
    _run_plugin_hooks "post-deploy" "{\"stack\":\"$target_stack\",\"template\":\"$name\"}"
    if [[ "$auto_start" == "true" ]]; then
        _run_plugin_hooks "pre-start" "{\"stack\":\"$target_stack\",\"template\":\"$name\"}"
        local env_up=()
        [[ -f "$target_dir/.env" ]] && env_up=(--env-file "$target_dir/.env")
        local _puid="${PUID:-1000}"
        local _pgid="${PGID:-1000}"
        local _ad="${APP_DATA_DIR:-$target_dir/App-Data}"
        [[ "$_ad" == ./* ]] && _ad="$target_dir/${_ad#./}"
        (
            # Safety: ensure Traefik directories and files exist before compose up
            mkdir -p "$_ad/Traefik/custom_routes" "$_ad/Traefik/cache" 2>/dev/null
            # Ensure bind-mount targets are files, not directories (Docker creates dirs for missing targets)
            for _bm in traefik.yml acme.json; do
                local _bm_path="$_ad/Traefik/$_bm"
                if [[ -d "$_bm_path" ]]; then
                    rm -rf "$_bm_path"
                    touch "$_bm_path"
                    [[ "$_bm" == "acme.json" ]] && chmod 600 "$_bm_path"
                fi
            done

            # Start ONLY the newly deployed services — don't restart existing containers
            # in the same stack (prevents Homarr/other services from restarting)
            local _deploy_env=""
            [[ -f "$target_dir/.env" ]] && _deploy_env="$target_dir/.env"
            local _svc_list=""
            _svc_list=$(printf '%s' "$template_services" | tr '\n' ' ')
            _compose_with_secrets "$target_dir/docker-compose.yml" "$_deploy_env" up -d --no-recreate $_svc_list >/dev/null 2>&1

            # Connect routed containers to the 'proxy' network so Traefik can reach them.
            # Controlled by the connect_proxy flag from the deploy request.
            if [[ "$connect_proxy" == "true" ]] && docker network inspect proxy >/dev/null 2>&1; then
                for _rf in "$traefik_routes_dir/$target_stack"/*.yml; do
                    [[ -f "$_rf" ]] || continue
                    local _cname
                    _cname=$(sed -n 's|.*url: "https\{0,1\}://\([^:]*\).*|\1|p' "$_rf" 2>/dev/null | head -1)
                    [[ -n "$_cname" ]] && docker network connect proxy "$_cname" 2>/dev/null || true
                done
            fi

            # Re-apply Authelia config AFTER compose up — the container's entrypoint
            # overwrites our generated config with its default template on first start.
            if [[ "$name" == "authelia" && -d "$_ad/Authelia/.dcs-cache" ]]; then
                sleep 3
                # Restore our generated config — container may have overwritten it with defaults
                docker run --rm -v "$_ad/Authelia/.dcs-cache:/src" -v "$_ad/Authelia/config:/dst" alpine sh -c \
                    "cp -f /src/configuration.yml /src/users_database.yml /dst/ 2>/dev/null; chmod 644 /dst/configuration.yml /dst/users_database.yml" 2>/dev/null
                # Restart Authelia to pick up the correct config
                $DOCKER_COMPOSE_CMD -f "$target_dir/docker-compose.yml" "${env_up[@]}" restart authelia >/dev/null 2>&1 || true
            fi

            # Fix volume ownership — Docker creates bind-mount dirs as root
            # This runs AFTER compose creates the directories but containers may need a restart
            sleep 2
            local _needs_restart=false
            while IFS= read -r _vol_path; do
                [[ -z "$_vol_path" || "$_vol_path" != "$_ad/"* ]] && continue
                [[ ! -d "$_vol_path" ]] && continue
                local _owner
                _owner=$(stat -c '%u' "$_vol_path" 2>/dev/null)
                if [[ "$_owner" == "0" && "$_puid" != "0" ]]; then
                    docker run --rm -v "$_vol_path:/d" alpine chown -R "$_puid:$_pgid" /d 2>/dev/null || chown -R "$_puid:$_pgid" "$_vol_path" 2>/dev/null || true
                    _needs_restart=true
                fi
            done < <(find "$_ad" -maxdepth 2 -type d 2>/dev/null)
            # Restart containers that had permission-fixed volumes
            if [[ "$_needs_restart" == "true" ]]; then
                $DOCKER_COMPOSE_CMD -f "$target_dir/docker-compose.yml" "${env_up[@]}" restart >/dev/null 2>&1 || true
            fi
        ) &
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
        # SECURITY: Reject shell metacharacters in variable values
        case "$val" in *'`'*|*'$('*) continue ;; esac
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
            # SECURITY: Validate service name (alphanumeric, hyphens, underscores only)
            if [[ ! "$exc_svc" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then continue; fi
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

    # Remove routes immediately (fast), then heavy cleanup in background
    local data_removed="false"
    local images_removed="false"
    local routes_removed="false"

    # ALWAYS remove Traefik route files and CF DNS on undeploy (these are infrastructure, not user data)
    local _routes_dir=""
    local _sd_stack
    for _sd_stack in $(_api_get_stacks); do
        local _sd_appdata="${APP_DATA_DIR:-$COMPOSE_DIR/$_sd_stack/App-Data}"
        [[ "$_sd_appdata" == ./* ]] && _sd_appdata="$COMPOSE_DIR/$_sd_stack/${_sd_appdata#./}"
        if [[ -d "$_sd_appdata/Traefik/custom_routes" ]] && \
           grep -q 'container_name: Traefik\|image: traefik' "$COMPOSE_DIR/$_sd_stack/docker-compose.yml" 2>/dev/null; then
            _routes_dir="$_sd_appdata/Traefik/custom_routes"
            break
        fi
    done
    # Collect actual subdomains from route files BEFORE deleting them
    local -a _dns_subs_to_remove=()
    if [[ -n "$_routes_dir" ]]; then
        for svc in "${services_to_remove[@]}"; do
            local _rf="$_routes_dir/$target_stack/${svc}.yml"
            local _sub="$svc"
            if [[ -f "$_rf" ]]; then
                local _hsub
                _hsub=$(sed -n 's/.*Host(`\([^.]*\).*/\1/p' "$_rf" 2>/dev/null | head -1)
                [[ -n "$_hsub" ]] && _sub="$_hsub"
                rm -f "$_rf" && routes_removed="true"
            fi
            _dns_subs_to_remove+=("$_sub")
        done
        [[ "$routes_removed" == "true" ]] && touch "$_routes_dir/.reload" 2>/dev/null
    fi

    # Remove CF DNS records in background (always, not gated on remove_data)
    local _dns_list="${_dns_subs_to_remove[*]}"
    (
        local _cf_token="${CF_DNS_API_TOKEN:-}"
        local _cf_domain="${TRAEFIK_DOMAIN:-}"
        [[ -z "$_cf_token" ]] && _cf_token=$(grep -m1 '^CF_DNS_API_TOKEN=' "$COMPOSE_DIR"/*/".env" "$BASE_DIR/.env" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        [[ -z "$_cf_domain" ]] && _cf_domain=$(grep -m1 '^TRAEFIK_DOMAIN=' "$COMPOSE_DIR"/*/".env" "$BASE_DIR/.env" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        if [[ -n "$_cf_token" && -n "$_cf_domain" ]] && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
            local cf_api="https://api.cloudflare.com/client/v4"
            local zone_id=""
            [[ -f "$BASE_DIR/.api-auth/.cf-zone-cache" ]] && zone_id=$(sed -n '2p' "$BASE_DIR/.api-auth/.cf-zone-cache" 2>/dev/null)
            [[ -z "$zone_id" ]] && zone_id=$(curl -s --max-time 10 -H "Authorization: Bearer $_cf_token" "$cf_api/zones?name=$_cf_domain&status=active" 2>/dev/null | jq -r '.result[0].id // empty')
            if [[ -n "$zone_id" ]]; then
                for _dns_sub in $_dns_list; do
                    local fqdn="${_dns_sub}.${_cf_domain}"
                    local rec_id
                    rec_id=$(curl -s --max-time 10 -H "Authorization: Bearer $_cf_token" "$cf_api/zones/$zone_id/dns_records?name=$fqdn" 2>/dev/null | jq -r '.result[0].id // empty')
                    [[ -n "$rec_id" ]] && curl -s --max-time 10 -X DELETE -H "Authorization: Bearer $_cf_token" "$cf_api/zones/$zone_id/dns_records/$rec_id" >/dev/null 2>&1
                    printf '[%s] DELETED %s (undeploy)\n' "$(date -Iseconds)" "$fqdn" >> "$BASE_DIR/.api-auth/cf-dns-audit.log" 2>/dev/null
                    sleep 1
                done
            fi
        fi
    ) &
    disown

    if [[ "$remove_data" == "true" ]]; then
        # Heavy cleanup in background — app-data, images (prevents HTTP timeout)
        local _app_data="${APP_DATA_DIR:-$target_dir/App-Data}"
        [[ "$_app_data" == ./* ]] && _app_data="$target_dir/${_app_data#./}"
        local _config_path
        _config_path=$(printf '%s' "$meta" | jq -r '.config_path // empty' 2>/dev/null)
        local _backup_file="$target_dir/docker-compose.yml.bak.${timestamp}"
        (
            # 1. Remove per-service App-Data
            for svc in "${services_to_remove[@]}"; do
                for dir_name in "$svc" "${svc^}" "${svc^^}"; do
                    [[ -d "$_app_data/$dir_name" ]] && docker run --rm -v "$_app_data/$dir_name:/d" alpine rm -rf /d 2>/dev/null
                done
            done
            # 2. Remove config_path data
            [[ -n "$_config_path" && -d "$_app_data/$_config_path" ]] && docker run --rm -v "$_app_data/$_config_path:/d" alpine rm -rf /d 2>/dev/null
            # 3. Remove Docker images
            for svc in "${services_to_remove[@]}"; do
                local img
                img=$(awk -v s="  ${svc}:" 'BEGIN{f=0} $0==s||index($0,s)==1{f=1;next} f&&/image:/{gsub(/.*image:[[:space:]]*/,"");gsub(/[[:space:]]*$/,"");print;exit} f&&/^  [a-zA-Z]/{exit}' "$_backup_file" 2>/dev/null)
                [[ -n "$img" ]] && docker rmi "$img" 2>/dev/null || true
            done
        ) &
        disown
        data_removed="true"
        images_removed="true"
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
    [[ "$data_removed" == "true" ]] && msg="$msg — app data purged"
    [[ "$images_removed" == "true" ]] && msg="$msg — images removed"
    [[ "$routes_removed" == "true" ]] && msg="$msg — routes cleaned"

    _api_success "{\"success\": true, \"template\": \"$(_api_json_escape "$name")\", \"target_stack\": \"$(_api_json_escape "$target_stack")\", \"services_removed\": $svc_removed_json, \"containers_removed\": $ctr_removed_json, \"backup_file\": \"docker-compose.yml.bak.${timestamp}\", \"stack_deleted\": $stack_deleted, \"data_removed\": $data_removed, \"images_removed\": $images_removed, \"routes_removed\": $routes_removed, \"message\": \"$msg\"}"
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

    # SECURITY: Scan imported compose for dangerous Docker features
    if ! _api_scan_compose_security "$compose" "template import ($name)"; then
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

    # SECURITY: Scan fetched compose for dangerous Docker features
    if ! _api_scan_compose_security "$compose_content" "URL import from $url"; then
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

    # SECURITY: Validate limit is a positive integer (prevents flag injection)
    [[ "$limit" =~ ^[0-9]+$ ]] || limit=25
    (( limit > 100 )) && limit=100

    # SECURITY: Use --format with tab separators for safe, parseable output.
    # Docker Hub descriptions can contain quotes/special chars — escaping each field prevents JSON injection.
    local raw_results
    raw_results=$(docker search --format '{{.Name}}\t{{.Description}}\t{{.StarCount}}\t{{.IsOfficial}}' --limit "$limit" -- "$query" 2>/dev/null)

    if [[ -z "$raw_results" ]]; then
        _api_success "{\"results\": [], \"total\": 0, \"query\": \"$(_api_json_escape "$query")\"}"
        return
    fi

    # Build JSON safely by escaping each field
    local -a entries=()
    while IFS=$'\t' read -r name desc stars official; do
        [[ -z "$name" ]] && continue
        [[ ! "$stars" =~ ^[0-9]+$ ]] && stars=0
        entries+=("{\"name\":\"$(_api_json_escape "$name")\",\"description\":\"$(_api_json_escape "$desc")\",\"stars\":$stars,\"official\":\"$(_api_json_escape "$official")\"}")
    done <<< "$raw_results"

    local json
    json=$(printf '%s,' "${entries[@]}")
    json="[${json%,}]"

    _api_success "{\"results\": $json, \"total\": ${#entries[@]}, \"query\": \"$(_api_json_escape "$query")\"}"
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
            # SECURITY: Require admin role for config export (contains sensitive values)
            if ! _api_check_admin; then _api_error 403 "Admin access required for config export"; return; fi
            local config_data="{}"
            if [[ -f "$BASE_DIR/.env" ]]; then
                local vars=""
                while IFS='=' read -r key value; do
                    [[ -z "$key" || "$key" == \#* ]] && continue
                    key=$(echo "$key" | xargs)
                    value=$(echo "$value" | xargs | sed 's/^"//; s/"$//')
                    # SECURITY: Mask sensitive values (tokens, passwords, secrets, keys)
                    local key_upper="${key^^}"
                    if [[ "$key_upper" == *TOKEN* || "$key_upper" == *PASSWORD* || "$key_upper" == *SECRET* || "$key_upper" == *KEY* || "$key_upper" == *CREDENTIAL* ]]; then
                        if [[ -n "$value" ]]; then
                            value="${value:0:4}****"
                        fi
                    fi
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
    _webhook_fire "$action" "$detail" >/dev/null 2>&1 &
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
        # SECURITY: Re-validate URL at fire time to prevent DNS rebinding attacks.
        # The URL was validated at creation, but DNS could have changed since then.
        if ! _api_validate_url "$url" "webhook" 2>/dev/null; then
            continue
        fi
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

    # SECURITY: Re-validate URL at test time (DNS could have changed since creation)
    _api_validate_url "$url" "webhook test" || return

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
    if [[ -n "$compose" ]]; then
        # SECURITY: Scan compose content for dangerous Docker features
        if ! _api_scan_compose_security "$compose" "template update ($name)"; then
            return
        fi
        printf '%s' "$compose" > "$tdir/docker-compose.yml"
    fi

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
        # SECURITY: Validate key is a legal env var name (prevent injection)
        if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then continue; fi
        val=$(echo "$env_vars" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null)
        # Sanitize CF_DNS_API_TOKEN — extract token if user pasted a curl command
        if [[ "$key" == "CF_DNS_API_TOKEN" && "$val" == *"curl "* ]]; then
            val=$(printf '%s' "$val" | sed -n 's/.*Bearer \([A-Za-z0-9_-]*\).*/\1/p' | head -1)
        fi
        # Strip any value containing shell-dangerous characters (newlines, backticks, $())
        val=$(printf '%s' "$val" | tr -d '\n\r' | sed 's/`//g')
        # SECURITY: Escape sed delimiter and special chars in value
        local safe_val="${val//\\/\\\\}"
        safe_val="${safe_val//|/\\|}"
        safe_val="${safe_val//&/\\&}"
        # Replace existing KEY=... line or append
        if echo "$env_content" | grep -q "^${key}="; then
            env_content=$(echo "$env_content" | sed "s|^${key}=.*|${key}=\"${safe_val}\"|")
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

    # Update DOCKER_STACKS in .env (word-boundary matching to prevent partial replacements)
    # Only replace within the DOCKER_STACKS line, not across the entire file
    if [[ -f "$BASE_DIR/.env" ]]; then
        sed -i "/^DOCKER_STACKS=/s|\b${old_name}\b|${new_name}|g" "$BASE_DIR/.env"
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
            ts_val=$(printf '%s' "$line" | sed -n 's/.*"ts":\([0-9]*\).*/\1/p' 2>/dev/null || echo 0)
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
            ts_val=$(printf '%s' "$line" | sed -n 's/.*"ts":\([0-9]*\).*/\1/p' 2>/dev/null || echo 0)
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

# Decrypt a single secret by key name. Returns the plaintext value on stdout.
# Returns 1 if the secret doesn't exist or decryption fails.
_decrypt_secret() {
    local key="$1"
    local secrets_dir="$BASE_DIR/.secrets"
    local enc_file="$secrets_dir/${key}.enc"
    local master_key_file="$secrets_dir/.master-key"

    [[ -f "$enc_file" ]] || return 1
    [[ -f "$master_key_file" ]] || return 1

    local master_key
    master_key=$(cat "$master_key_file" 2>/dev/null) || return 1

    openssl enc -d -aes-256-cbc -pbkdf2 -pass "pass:${master_key}" -in "$enc_file" 2>/dev/null
}

# Normalize ${SECRETS.KEY} → ${SECRETS_KEY} in a string.
# Docker Compose rejects dots in variable names. This converts the user-friendly
# dot syntax to valid underscore syntax that compose can parse.
_normalize_secrets_syntax() {
    sed 's/\${SECRETS\.\([A-Za-z0-9_-]*\)}/${SECRETS_\1}/g; s/\$SECRETS\.\([A-Za-z0-9_-]*\)/$SECRETS_\1/g'
}

# Build environment variables for all SECRETS_* references in a compose file.
# Decrypts each referenced secret and prints KEY=VALUE lines.
# Usage: eval "$(_secrets_env_exports compose_file)"
_secrets_env_exports() {
    local compose_file="$1"
    [[ -f "$compose_file" ]] || return 0

    local content
    content=$(cat "$compose_file")

    # Find all SECRETS_* variable references
    local -a refs=()
    while IFS= read -r ref; do
        [[ -z "$ref" ]] && continue
        refs+=("$ref")
    done < <(printf '%s' "$content" | grep -oE 'SECRETS_[A-Za-z0-9_]+' | sort -u)

    [[ ${#refs[@]} -eq 0 ]] && return 0

    for ref in "${refs[@]}"; do
        local key="${ref#SECRETS_}"  # Strip SECRETS_ prefix to get the secret name
        local val
        if val=$(_decrypt_secret "$key"); then
            # Export as environment variable — docker compose reads these
            printf 'export %s=%q\n' "$ref" "$val"
        else
            echo "[DCS] WARN: Secret not found: $key (referenced as \${$ref})" >&2
        fi
    done
}

# Run docker compose with decrypted secrets injected as environment variables.
# Secrets are only in the process environment — never written to disk.
# Usage: _compose_with_secrets compose_file env_file action [args...]
_compose_with_secrets() {
    local compose_file="$1"; shift
    local env_file="$1"; shift
    # remaining args are the docker compose subcommand + flags

    local -a compose_args=(-f "$compose_file")
    [[ -n "$env_file" && -f "$env_file" ]] && compose_args+=(--env-file "$env_file")

    # Run in subshell so exported secrets don't leak into the API process
    (
        eval "$(_secrets_env_exports "$compose_file")"
        $DOCKER_COMPOSE_CMD "${compose_args[@]}" "$@"
    )
}

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
            line_id=$(printf '%s' "$line" | sed -n 's/.*"schedule_id" *: *"\([^"]*\).*/\1/p' 2>/dev/null)
            [[ -z "$line_id" ]] && line_id=$(printf '%s' "$line" | sed -n 's/.*"id" *: *"\([^"]*\).*/\1/p' 2>/dev/null)
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
    # Uses registry cache when available — images confirmed as "latest" are NOT stale.
    # Only images with confirmed updates or unchecked images >30 days old count as stale.
    local total_images=0 stale_images=0
    local _img_cache="$BASE_DIR/.data/image-update-cache.json"
    local -A _img_cached=()
    if [[ -f "$_img_cache" ]]; then
        while IFS='=' read -r k v; do
            [[ -n "$k" ]] && _img_cached["$k"]="$v"
        done < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' "$_img_cache" 2>/dev/null)
    fi

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == "REPOSITORY"* ]] && continue
        local repo tag _rest
        read -r repo tag _rest <<< "$line"
        [[ "$repo" == "<none>" ]] && continue
        total_images=$((total_images + 1))

        local full_image="${repo}:${tag}"

        # If registry cache confirms latest, skip — not stale
        if [[ "${_img_cached[$full_image]:-}" == "false" ]]; then
            continue
        fi

        # If registry cache confirms update available, count as stale
        if [[ "${_img_cached[$full_image]:-}" == "true" ]]; then
            stale_images=$((stale_images + 1))
            continue
        fi

        # No cache — fall back to age-based check
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

# =============================================================================
# DASHBOARD LAYOUT PERSISTENCE
# =============================================================================

DASHBOARD_LAYOUTS_DIR="$BASE_DIR/.api-auth/dashboard-layouts"
PROFILES_DIR="$BASE_DIR/.api-auth/profiles"

# GET /settings/dashboard — Fetch user's dashboard layout
handle_dashboard_layout_get() {
    if ! _api_check_auth; then return; fi

    local username="${AUTH_USERNAME:-default}"
    mkdir -p "$DASHBOARD_LAYOUTS_DIR"
    local layout_file="$DASHBOARD_LAYOUTS_DIR/${username}.json"

    if [[ -f "$layout_file" ]]; then
        local content
        content=$(cat "$layout_file" 2>/dev/null)
        _api_success "{\"layout\": $content}"
    else
        _api_success "{\"layout\": null}"
    fi
}

# POST /settings/dashboard — Save user's dashboard layout
handle_dashboard_layout_save() {
    local body="$1"
    if ! _api_check_auth; then return; fi

    local username="${AUTH_USERNAME:-default}"
    mkdir -p "$DASHBOARD_LAYOUTS_DIR"
    local layout_file="$DASHBOARD_LAYOUTS_DIR/${username}.json"

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required"
        return
    fi

    local layout
    layout=$(printf '%s' "$body" | jq -c '.layout // empty' 2>/dev/null)
    if [[ -z "$layout" || "$layout" == "null" ]]; then
        _api_error 400 "Missing required field: layout"
        return
    fi

    local card_count
    card_count=$(printf '%s' "$layout" | jq '.cards | length' 2>/dev/null || echo 0)
    if [[ "$card_count" -eq 0 ]]; then
        _api_error 400 "Layout must contain at least one card"
        return
    fi

    printf '%s' "$layout" > "$layout_file"
    _api_success "{\"success\": true, \"cards\": $card_count}"
}

# GET /settings/profile — Fetch user's profile settings
handle_profile_get() {
    if ! _api_check_auth; then return; fi

    local username="${AUTH_USERNAME:-default}"
    mkdir -p "$PROFILES_DIR"
    local profile_file="$PROFILES_DIR/${username}.json"

    if [[ -f "$profile_file" ]]; then
        local content
        content=$(cat "$profile_file" 2>/dev/null)
        _api_success "{\"profile\": $content}"
    else
        _api_success "{\"profile\": null}"
    fi
}

# POST /settings/profile — Save user's profile settings
handle_profile_save() {
    local body="$1"
    if ! _api_check_auth; then return; fi

    local username="${AUTH_USERNAME:-default}"
    mkdir -p "$PROFILES_DIR"
    local profile_file="$PROFILES_DIR/${username}.json"

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required"
        return
    fi

    local profile
    profile=$(printf '%s' "$body" | jq -c '.profile // empty' 2>/dev/null)
    if [[ -z "$profile" || "$profile" == "null" ]]; then
        _api_error 400 "Missing required field: profile"
        return
    fi

    printf '%s' "$profile" > "$profile_file"
    _api_success "{\"success\": true}"
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
            ts_val=$(printf '%s' "$line" | sed -n 's/.*"ts":\([0-9]*\).*/\1/p' 2>/dev/null || echo 0)
            if [[ $ts_val -ge $cutoff ]]; then
                # Extract health_score field if present
                local hs
                hs=$(printf '%s' "$line" | sed -n 's/.*"health_score":\([0-9]*\).*/\1/p' 2>/dev/null || echo "")
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

# Run lifecycle hooks across all enabled plugins.
# Events: pre-start, post-start, pre-stop, post-stop, pre-update, post-update, pre-deploy, post-deploy
# Context JSON is passed on stdin to each hook script.
# Runs in background to avoid blocking API responses.
_run_plugin_hooks() {
    local event="$1"
    local context="${2:-{\}}"

    [[ "${PLUGINS_HOOKS_ENABLED:-true}" != "true" ]] && return 0
    [[ ! -d "$PLUGINS_DIR" ]] && return 0

    (
        for plugin_dir in "$PLUGINS_DIR"/*/; do
            [[ ! -d "$plugin_dir" ]] && continue
            [[ -f "$plugin_dir/.disabled" ]] && continue

            local hook_script="$plugin_dir/hooks/$event"
            [[ -f "$hook_script" && -x "$hook_script" ]] || {
                hook_script="$plugin_dir/hooks/${event}.sh"
                [[ -f "$hook_script" && -x "$hook_script" ]] || continue
            }

            local plugin_name
            plugin_name=$(basename "$plugin_dir")
            local output
            output=$(echo "$context" | timeout 30 "$hook_script" 2>&1) || true

            # Log execution
            local log_file="$plugin_dir/execution.log"
            printf '{"ts":"%s","event":"%s","plugin":"%s","output":"%s"}\n' \
                "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$event" "$plugin_name" \
                "$(printf '%s' "$output" | head -c 500 | sed 's/"/\\"/g' | tr '\n' ' ')" \
                >> "$log_file" 2>/dev/null
        done
    ) &
}

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

    # SECURITY: Validate URL (SSRF protection) and prevent git option injection
    _api_validate_url "$url" "Plugin clone URL" || return
    if [[ "$url" == --* ]]; then
        _api_error 400 "Invalid plugin URL"
        return
    fi

    local clone_output
    clone_output=$(git clone --depth 1 -- "$url" "$target_dir" 2>&1)
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
            printf '{"name": "%s", "version": "%s", "description": "%s", "author": "%s", "enabled": false}\n' \
                "$(_api_json_escape "$name")" "$(_api_json_escape "$version")" "$(_api_json_escape "$desc")" "$(_api_json_escape "$author")" \
                > "$target_dir/plugin.json"
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

    # Write card definitions (dashboard widget cards)
    if command -v jq >/dev/null 2>&1; then
        local card_keys
        card_keys=$(echo "$body" | jq -r '.cards // {} | keys[]' 2>/dev/null)
        for card_name in $card_keys; do
            if [[ ! "$card_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                continue
            fi
            mkdir -p "$target_dir/cards/$card_name"
            # Write card.json metadata
            local card_meta
            card_meta=$(echo "$body" | jq -c ".cards[\"$card_name\"].meta // {}" 2>/dev/null)
            [[ -n "$card_meta" && "$card_meta" != "{}" ]] && printf '%s' "$card_meta" > "$target_dir/cards/$card_name/card.json"
            # Write index.html content
            local card_html
            card_html=$(echo "$body" | jq -r ".cards[\"$card_name\"].html // empty" 2>/dev/null)
            [[ -n "$card_html" ]] && printf '%s' "$card_html" > "$target_dir/cards/$card_name/index.html"
        done
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
# =============================================================================
# PLUGIN CARDS — Custom dashboard card discovery and content serving
# =============================================================================

# GET /plugins/cards — List all available plugin cards across all enabled plugins
handle_plugin_cards_list() {
    if ! _api_check_auth; then return; fi

    local -a entries=()
    local plugin_dir
    for plugin_dir in "$BASE_DIR/.plugins"/*/; do
        [[ -d "$plugin_dir" ]] || continue
        local plugin_name
        plugin_name=$(basename "$plugin_dir")
        local manifest="$plugin_dir/plugin.json"

        # Skip disabled plugins
        if [[ -f "$manifest" ]] && command -v jq >/dev/null 2>&1; then
            local enabled
            enabled=$(jq -r '.enabled // true' "$manifest" 2>/dev/null)
            [[ "$enabled" == "false" ]] && continue
        fi

        # Scan cards/ directory
        local card_dir
        for card_dir in "$plugin_dir/cards"/*/; do
            [[ -d "$card_dir" ]] || continue
            local card_json="$card_dir/card.json"
            [[ -f "$card_json" ]] || continue

            if command -v jq >/dev/null 2>&1; then
                local _card_dirname
                _card_dirname=$(basename "$card_dir")
                local card_meta
                card_meta=$(jq -c --arg plugin "$plugin_name" --arg cid "plugin:${plugin_name}:${_card_dirname}" \
                    '. + {plugin: $plugin, id: $cid}' "$card_json" 2>/dev/null)
                [[ -n "$card_meta" ]] && entries+=("$card_meta")
            fi
        done
    done

    local json
    if [[ ${#entries[@]} -gt 0 ]]; then
        json=$(printf '%s,' "${entries[@]}")
        json="[${json%,}]"
    else
        json="[]"
    fi

    _api_success "{\"cards\": $json, \"total\": ${#entries[@]}}"
}

# GET /plugins/:name/cards/:card — Return card HTML content as JSON
handle_plugin_card_content() {
    local plugin_name="$1"
    local card_name="$2"

    if [[ "$plugin_name" == *".."* || "$plugin_name" == *"/"* ]] || \
       [[ "$card_name" == *".."* || "$card_name" == *"/"* ]]; then
        _api_error 400 "Invalid plugin or card name"
        return
    fi

    local html_file="$BASE_DIR/.plugins/$plugin_name/cards/$card_name/index.html"

    if [[ ! -f "$html_file" ]]; then
        _api_error 404 "Card not found: $plugin_name/$card_name"
        return
    fi

    local content
    content=$(cat "$html_file" 2>/dev/null)

    _api_success "{\"plugin\": \"$(_api_json_escape "$plugin_name")\", \"card\": \"$(_api_json_escape "$card_name")\", \"html\": \"$(_api_json_escape "$content")\"}"
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
        printf "event: docker-event\ndata: %s\n\n" "$event_line" 2>/dev/null || break
    done &
    events_pid=$!

    # Ensure docker events process is killed when this function exits
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
        running=$(timeout 3 docker ps -q 2>/dev/null | wc -l)
        local total
        total=$(timeout 3 docker ps -a -q 2>/dev/null | wc -l)

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
            local _new_cl="${header#*: }"
            _new_cl="${_new_cl// /}"
            # SECURITY: Reject duplicate Content-Length (HTTP request smuggling vector)
            if [[ "$content_length" -gt 0 ]] 2>/dev/null && [[ "$_new_cl" != "$content_length" ]]; then
                _api_error 400 "Duplicate Content-Length headers with different values"
                return
            fi
            content_length="$_new_cl"
        fi
        # SECURITY: Reject Transfer-Encoding (not supported, prevents request smuggling)
        if [[ "${header,,}" == transfer-encoding:* ]]; then
            _api_error 400 "Transfer-Encoding is not supported"
            return
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
            # SECURITY: Strip CR/LF from Origin to prevent HTTP response splitting.
            # An attacker could inject headers via: Origin: http://localhost:1234\r\nSet-Cookie: evil
            REQUEST_ORIGIN_HEADER="${REQUEST_ORIGIN_HEADER//$'\r'/}"
            REQUEST_ORIGIN_HEADER="${REQUEST_ORIGIN_HEADER//$'\n'/}"
        fi
    done

    # Read request body if present (enforce size limit)
    # SECURITY: Validate content_length is a positive integer (prevents injection via headers)
    local request_body=""
    if [[ "$content_length" =~ ^[0-9]+$ ]] && [[ "$content_length" -gt 0 ]]; then
        if [[ "$content_length" -gt "$API_MAX_BODY_SIZE" ]]; then
            _api_error 413 "Request body too large. Maximum: ${API_MAX_BODY_SIZE} bytes"
            return
        fi
        # Read body with timeout to prevent slowloris DoS.
        # Use head -c for reliable reading (works across all platforms).
        request_body=$(timeout 30 head -c "$content_length" 2>/dev/null) || {
            _api_error 408 "Request timeout: body not received within 30 seconds"
            return
        }
    fi

    # Normalize path: strip trailing slash, lowercase
    path="${path%/}"
    [[ -z "$path" ]] && path="/"

    # Parse query string and strip from path for clean routing
    _api_parse_query "$path"
    path="${path%%\?*}"

    # SECURITY: Reject URL-encoded path traversal attempts (%2e = '.', %2f = '/')
    # Also reject null bytes (%00) and other encoded dangerous chars
    if [[ "$path" == *"%2e"* || "$path" == *"%2E"* || "$path" == *"%2f"* || "$path" == *"%2F"* || "$path" == *"%00"* ]]; then
        _api_error 400 "Invalid request path"
        return
    fi

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
            /system/os-update/status)   handle_os_update_status ;;
            /ddns/status)               handle_ddns_status ;;
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
            /traefik/status)            handle_traefik_status ;;
            /routes)                    handle_routes ;;
            /routes/check)              handle_routes_check "${_QUERY_PARAMS[subdomain]:-}" ;;
            /dns/records)               handle_dns_records ;;
            /homarr/status)             handle_homarr_status ;;
            /metrics/history)           handle_metrics_history ;;
            /metrics/summary)           handle_metrics_summary ;;
            /health/score)              handle_health_score ;;
            /health/score/history)      handle_health_score_history ;;
            /settings/dashboard)        handle_dashboard_layout_get ;;
            /settings/profile)          handle_profile_get ;;
            /secrets)                   handle_secrets_list ;;
            /schedules)                 handle_schedules_list ;;
            /plugins)                   handle_plugins_list ;;
            /plugins/cards)             handle_plugin_cards_list ;;
            /plugins/*/cards/*)
                local pname="${path#/plugins/}"
                local cname="${pname#*/cards/}"
                pname="${pname%%/*}"
                cname="${cname%%/*}"
                _api_validate_resource_name "$pname" "plugin" || return
                handle_plugin_card_content "$pname" "$cname"
                ;;
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
            /stacks/*/compose/history/*)
                local stack="${path#/stacks/}"
                local version_id="${stack##*/compose/history/}"
                stack="${stack%%/compose/history/*}"
                _api_validate_stack_name "$stack" || return
                handle_compose_history_view "$stack" "$version_id"
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
            /auth/setup)          handle_auth_setup "$request_body"; return ;;
            /auth/login)          handle_auth_login "$request_body"; return ;;
            /auth/register)       handle_auth_register "$request_body"; return ;;
            /auth/totp/validate)  handle_totp_validate "$request_body"; return ;;
        esac

        # All other POST endpoints require authentication
        if ! _api_check_auth; then
            _api_error 401 "Authentication required. Provide Authorization: Bearer <token> header."
            return
        fi

        # SECURITY: Audit log ALL authenticated POST requests (write operations)
        _api_audit_log "$client_ip" "POST" "${AUTH_USERNAME:-unknown}" "$path"

        # Setup wizard endpoints (require auth + setup not complete)
        case "$path" in
            /setup/configure) handle_setup_configure "$request_body"; return ;;
            /setup/complete)  handle_setup_complete; return ;;
        esac

        # Auth session management endpoints (any authenticated user)
        case "$path" in
            /auth/logout)        handle_auth_logout; return ;;
            /auth/refresh)       handle_auth_refresh; return ;;
            /auth/totp/setup)    handle_totp_setup "$request_body"; return ;;
            /auth/totp/verify)   handle_totp_verify "$request_body"; return ;;
            /auth/totp/disable)  handle_totp_disable "$request_body"; return ;;
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
            /system/ui-update/apply)
                handle_ui_update_apply
                ;;
            /system/update/rollback)
                handle_system_update_rollback "$request_body"
                ;;
            /system/os-update/check)
                handle_os_update_check "$request_body"
                ;;
            /system/os-update/apply)
                handle_os_update_apply "$request_body"
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
            /containers/*/recreate)
                local container="${path#/containers/}"
                container="${container%/recreate}"
                _api_validate_resource_name "$container" "container" || return
                handle_container_action "$container" "recreate"
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
            /settings/dashboard)
                handle_dashboard_layout_save "$request_body"
                ;;
            /settings/profile)
                handle_profile_save "$request_body"
                ;;
            /metrics/snapshot)
                handle_metrics_snapshot
                ;;
            /images/check-updates)
                handle_images_check_updates_post
                ;;
            /images/update)
                # Image name in body: {"image": "lscr.io/linuxserver/plex:latest"}
                handle_image_update "" "$request_body"
                ;;
            /images/*/update)
                local img="${path#/images/}"
                img="${img%/update}"
                handle_image_update "$img" "$request_body"
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
            /secrets/*)
                local key="${path#/secrets/}"
                key="${key%%/*}"
                _api_validate_resource_name "$key" "secret" || return
                # Merge URL key into body for the handler
                local _sb
                _sb=$(printf '%s' "$request_body" | jq -c --arg k "$key" '. + {key: $k}' 2>/dev/null)
                [[ -n "$_sb" ]] && request_body="$_sb"
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

    # ── Route: PUT endpoints ──────────────────────────────────────────
    if [[ "$method" == "PUT" || "$method" == "PATCH" ]]; then

        # All PUT/PATCH endpoints require authentication
        if ! _api_check_auth; then
            _api_error 401 "Authentication required. Provide Authorization: Bearer <token> header."
            return
        fi

        # SECURITY: Audit log ALL PUT/PATCH requests
        _api_audit_log "$client_ip" "PUT" "${AUTH_USERNAME:-unknown}" "$path"

        case "$path" in
            /routes/*/*)
                local _route_parts="${path#/routes/}"
                local _route_stack="${_route_parts%%/*}"
                local _route_svc="${_route_parts#*/}"
                handle_route_update "$_route_stack" "$_route_svc" "$request_body"
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

        # SECURITY: Audit log ALL DELETE requests
        _api_audit_log "$client_ip" "DELETE" "${AUTH_USERNAME:-unknown}" "$path"

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
            /routes/*/*)
                local _route_parts="${path#/routes/}"
                local _route_stack="${_route_parts%%/*}"
                local _route_svc="${_route_parts#*/}"
                handle_route_delete "$_route_stack" "$_route_svc"
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

    # SECURITY: Graceful shutdown handler — clean up child processes and temp files
    trap 'echo ""; echo "  Shutting down API server..."; kill $(jobs -p) 2>/dev/null; rm -f "$API_PID_FILE"; exit 0' SIGTERM SIGINT SIGHUP

    local self_path
    self_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

    # Start DDNS loop (only once, in the server process — not per-request)
    if [[ "$DDNS_ENABLED" == "true" && -n "${CF_DNS_API_TOKEN:-}" && -n "${TRAEFIK_DOMAIN:-}" ]]; then
        _ddns_update_loop &
        local _ddns_pid=$!
        echo "$_ddns_pid" > "${DDNS_PID_FILE:-/tmp/dcs-ddns.pid}" 2>/dev/null
    fi

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
