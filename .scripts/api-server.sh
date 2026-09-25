#!/bin/bash
# =============================================================================
# Docker Compose Skeleton — REST API Server
# Lightweight HTTP/JSON API for remote management, served by socat or ncat.
# Each connection is handled by a fresh `--handle-request` instance of this
# script: handlers are plain bash functions that read the request on stdin and
# write the HTTP response to stdout.
#
# Usage:
#   ./api-server.sh [--port PORT] [--bind ADDR] [--daemon] [--stop] [--help]
#
# Endpoint reference: docs/API.md — generated from the router at the bottom of
# this file by .scripts/api-docs.sh (run it after adding or changing a route).
#
# Security model (details in SECURITY.md):
#   - Authentication is mandatory unless the listener is bound to loopback.
#   - Bearer tokens over PBKDF2-hashed passwords, optional TOTP, invite-only
#     registration, per-client rate limits and login lockouts.
#   - Two roles: "user" (read-only viewer) and "admin" (everything else).
#   - Compose content is scanned for container-escape vectors before it is
#     written or deployed; .env is read as data, never sourced.
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

# Keys that must never be set from .env: they change how bash or the dynamic
# loader behave for every command this server runs.
_API_ENV_RESERVED_KEYS='PATH|IFS|PS4|ENV|BASH_ENV|BASH_XTRACEFD|SHELLOPTS|BASHOPTS|CDPATH|GLOBIGNORE|PROMPT_COMMAND|LD_PRELOAD|LD_LIBRARY_PATH|LD_AUDIT|BASE_DIR|HANDLE_REQUEST|DAEMON_MODE|STOP_SERVER'

# Load a .env file as DATA, never as code. Only `KEY=value` lines are accepted,
# values are taken literally (matching surrounding quotes are stripped) and
# reserved keys are ignored. Sourcing the file would turn write access to .env
# (which the API grants to admins) into command execution on the host.
_api_load_env_file() {
    local file="$1" line key val
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%$'\r'}"
        [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        key="${BASH_REMATCH[2]}"
        val="${BASH_REMATCH[3]}"
        [[ "$key" =~ ^(${_API_ENV_RESERVED_KEYS})$ || "$key" == BASH_FUNC_* ]] && continue
        if [[ ${#val} -ge 2 && "$val" == \"*\" ]]; then
            val="${val:1:${#val}-2}"
            # inside double quotes bash reads \\ \" \$ \` as the bare character
            [[ "$val" == *\\* ]] && val=$(printf '%s' "$val" | sed 's/\\\([\\"$`]\)/\1/g')
        elif [[ ${#val} -ge 2 && "$val" == \'*\' ]]; then
            val="${val:1:${#val}-2}"
        else
            val="${val%%[[:space:]]#*}"
            val="${val%"${val##*[![:space:]]}"}"
        fi
        export "$key=$val"
    done < "$file"
}

# Validate .env content before it is written by the API (raw editor, config
# update, setup wizard). Prints the first problem and returns 1 on rejection.
_api_validate_env_content() {
    local content="$1" line n=0 key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$(( n + 1 ))
        line="${line%%$'\r'}"
        [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ ! "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            echo "line $n is not KEY=value"
            return 1
        fi
        key="${BASH_REMATCH[2]}"
        val="${BASH_REMATCH[3]}"
        if [[ "$key" =~ ^(${_API_ENV_RESERVED_KEYS})$ || "$key" == BASH_FUNC_* ]]; then
            echo "line $n sets reserved variable $key"
            return 1
        fi
        if [[ "$val" == *'$('* || "$val" == *'`'* || "$val" =~ [[:cntrl:]] ]]; then
            echo "line $n: values may not contain command substitution or control characters"
            return 1
        fi
    done <<< "$content"
    return 0
}

# Validate a single KEY=value pair destined for .env
_api_validate_env_kv() {
    local key="$1" val="$2"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "invalid key '$key'"; return 1; }
    [[ "$key" =~ ^(${_API_ENV_RESERVED_KEYS})$ || "$key" == BASH_FUNC_* ]] && { echo "reserved variable $key"; return 1; }
    [[ "$val" == *'$('* || "$val" == *'`'* || "$val" =~ [[:cntrl:]] ]] && { echo "value of $key contains command substitution or control characters"; return 1; }
    return 0
}

_api_load_env_file "$BASE_DIR/.env"

COMPOSE_DIR="${COMPOSE_DIR:-$BASE_DIR/Stacks}"
APP_DATA_DIR="${APP_DATA_DIR:-$BASE_DIR/App-Data}"

# =============================================================================
# CONFIGURATION
# =============================================================================

# The server process exports the values it actually listens with; per-request
# handlers (spawned by socat) take those over anything in .env so that every
# process agrees on the bind address, port and authentication policy.
API_PORT="${DCS_API_EFFECTIVE_PORT:-${API_PORT:-9876}}"
API_BIND="${DCS_API_EFFECTIVE_BIND:-${API_BIND:-127.0.0.1}}"
API_VERSION="1.5.0"
DCS_VERSION="$(cat "${BASE_DIR}/VERSION" 2>/dev/null || echo "unknown")"

# Plugin system
PLUGINS_DIR="${BASE_DIR}/.plugins"
PLUGINS_HOOKS_ENABLED="${PLUGINS_HOOKS_ENABLED:-true}"
API_PID_FILE="${BASE_DIR}/.data/api-server.pid"
API_LOG_FILE="${BASE_DIR}/logs/api-server.log"

# Authentication configuration
API_AUTH_DIR="${BASE_DIR}/.api-auth"
API_TOKEN_EXPIRY="${API_TOKEN_EXPIRY:-86400}"       # 24 hours in seconds
API_INVITE_EXPIRY="${API_INVITE_EXPIRY:-604800}"     # 7 days in seconds
API_MAX_LOGIN_ATTEMPTS="${API_MAX_LOGIN_ATTEMPTS:-5}"
API_LOCKOUT_DURATION="${API_LOCKOUT_DURATION:-900}"  # 15 minutes in seconds

# Authentication policy — resolved by _api_resolve_auth_policy once the command
# line has been parsed (so --bind counts) and exported to the request handlers.
#
#   Loopback bind (127.x / localhost / ::1): auth optional, off unless enabled.
#   Any other bind address: auth is mandatory. API_AUTH_ENABLED=false is ignored
#   there unless API_INSECURE_NO_AUTH=true is ALSO set, because an open API on a
#   reachable interface hands out full control of the Docker host.
API_AUTH_ENABLED="${DCS_API_EFFECTIVE_AUTH:-${API_AUTH_ENABLED:-}}"
API_INSECURE_NO_AUTH="${API_INSECURE_NO_AUTH:-false}"
API_AUTH_FORCED="false"
SETUP_MODE="${DCS_API_SETUP_MODE:-false}"

# Peers listed here (comma-separated IPs/CIDRs) are trusted to set
# X-Forwarded-For. The DCS-UI container proxies browser traffic to this API,
# so without it every UI user would share one rate-limit bucket and one
# login-lockout counter, and audit logs would only ever show the container IP.
API_TRUSTED_PROXIES="${API_TRUSTED_PROXIES:-}"

_api_bind_is_loopback() {
    case "$1" in
        127.*|localhost|::1|'') return 0 ;;
        *) return 1 ;;
    esac
}

_api_resolve_auth_policy() {
    if _api_bind_is_loopback "$API_BIND"; then
        [[ -z "$API_AUTH_ENABLED" ]] && API_AUTH_ENABLED="false"
    elif [[ "$API_AUTH_ENABLED" != "true" ]]; then
        if [[ "$API_INSECURE_NO_AUTH" == "true" ]]; then
            API_AUTH_ENABLED="false"
        else
            API_AUTH_ENABLED="true"
            API_AUTH_FORCED="true"
        fi
    fi
    [[ "$API_AUTH_ENABLED" == "true" ]] || API_AUTH_ENABLED="false"
    export DCS_API_EFFECTIVE_AUTH="$API_AUTH_ENABLED"
    export DCS_API_EFFECTIVE_BIND="$API_BIND"
    export DCS_API_EFFECTIVE_PORT="$API_PORT"
    export DCS_API_SETUP_MODE="$SETUP_MODE"
}

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
API_RATE_DIR="${API_RATE_DIR:-$BASE_DIR/.data/rates}"
mkdir -p "$API_RATE_DIR" 2>/dev/null

# API server start time (epoch) — used by /health for uptime & request counters
API_START_EPOCH="$(date +%s)"
API_STATS_FILE="${API_STATS_FILE:-$BASE_DIR/.data/api-stats}"
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
# Exported so the per-request processes skip the detection (one docker CLI
# round-trip per request otherwise).
export DOCKER_COMPOSE_CMD

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

DAEMON_MODE=false
STOP_SERVER=false
HANDLE_REQUEST=false

# Only when executed: a script that sources this file for its functions
# (tests, tooling) must not have its own arguments parsed as server options.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
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
fi

_api_resolve_auth_policy

# =============================================================================
# DAEMON MANAGEMENT
# =============================================================================

# PIDs of processes listening on a TCP port (ss preferred, lsof fallback)
_api_port_listeners() {
    local port="$1" pids=""
    if command -v ss >/dev/null 2>&1; then
        pids=$(ss -Hltnp "sport = :${port}" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u | tr '\n' ' ')
    fi
    if [[ -z "${pids// /}" ]] && command -v lsof >/dev/null 2>&1; then
        pids=$(lsof -ti "tcp:${port}" -sTCP:LISTEN 2>/dev/null | tr '\n' ' ')
    fi
    printf '%s' "${pids% }"
}

if [[ "$STOP_SERVER" == "true" ]]; then
    stopped=false
    if [[ -f "$API_PID_FILE" ]]; then
        pid=$(cat "$API_PID_FILE" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            # SIGTERM lets the server's trap stop the listener and its helpers
            kill -TERM "$pid" 2>/dev/null
            for _ in $(seq 1 50); do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.1
            done
            if kill -0 "$pid" 2>/dev/null; then
                pkill -KILL -P "$pid" 2>/dev/null || true
                kill -KILL "$pid" 2>/dev/null || true
            fi
            echo "API server stopped (PID $pid)"
            stopped=true
        fi
        rm -f "$API_PID_FILE"
    fi

    # Fallback: an orphaned DCS listener still bound to the port (older
    # version, or a server started without a PID file). Anything else that
    # owns the port — another program, or another DCS installation — is
    # reported, never killed.
    _leftover=$(_api_port_listeners "$API_PORT")
    for _p in $_leftover; do
        _cmd=$(tr '\0' ' ' < "/proc/${_p}/cmdline" 2>/dev/null || true)
        if [[ "$_cmd" == *api-server.sh* ]]; then
            kill -TERM "$_p" 2>/dev/null || true
            sleep 0.5
            kill -KILL "$_p" 2>/dev/null || true
            echo "Stopped orphaned listener on port ${API_PORT} (PID ${_p})"
            stopped=true
        else
            echo "Port ${API_PORT} is held by PID ${_p} (${_cmd:0:70}) — not a DCS API server, left running"
        fi
    done
    # Long-lived request handlers (SSE and log streams) outlive the listener.
    # They belong to this installation (matched by this script's absolute
    # path), so end them as well.
    _self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    _self_re=$(printf '%s' "$_self" | sed 's/[][\.*^$+?(){}|]/\\&/g')
    if pkill -TERM -f -- "${_self_re} --handle-request$" 2>/dev/null; then
        echo "Stopped lingering request handlers"
        stopped=true
    fi
    [[ "$stopped" == "false" ]] && echo "API server is not running"
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
        printf "Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS\r\n"
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
    if [[ -f "${API_STATS_FILE}" ]]; then
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
    # Mirror into the JSON audit log that GET /audit, the UI and webhooks consume
    _audit_log "auth.${event,,}" "${username:-anonymous}@${ip}${detail:+ — $detail}"
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
    # The password travels in the environment, never on the command line
    # (argv is readable by every local user via /proc).
    DCS_PW="$password" DCS_SALT="$salt" DCS_ITERS="$iters" python3 -c '
import hashlib, os
print(hashlib.pbkdf2_hmac(
    "sha256",
    os.environ["DCS_PW"].encode(),
    bytes.fromhex(os.environ["DCS_SALT"]),
    int(os.environ["DCS_ITERS"])
).hex())'
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
    DCS_A="$computed_hash" DCS_B="$stored_hash" python3 -c '
import hmac, os
raise SystemExit(0 if hmac.compare_digest(os.environ["DCS_A"], os.environ["DCS_B"]) else 1)'
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
    # Usernames are validated to [A-Za-z0-9_-] at signup and the issuer is a
    # fixed label, so no URL encoding is needed here.
    printf 'otpauth://totp/%s:%s?secret=%s&issuer=%s&algorithm=SHA1&digits=6&period=30' \
        "$issuer" "$username" "$b32" "$issuer"
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
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ && "$net" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ && "$mask" =~ ^[0-9]{1,2}$ && "$mask" -le 32 ]] || return 1

    # Convert IP to integer
    local IFS='.'
    local -a ip_parts net_parts
    read -ra ip_parts <<< "$ip"
    read -ra net_parts <<< "$net"
    local ip_int=$(( (ip_parts[0] << 24) + (ip_parts[1] << 16) + (ip_parts[2] << 8) + ip_parts[3] ))
    local net_int=$(( (net_parts[0] << 24) + (net_parts[1] << 16) + (net_parts[2] << 8) + net_parts[3] ))
    local mask_int=0
    (( mask > 0 )) && mask_int=$(( (0xFFFFFFFF << (32 - mask)) & 0xFFFFFFFF ))

    (( (ip_int & mask_int) == (net_int & mask_int) ))
}

# Is $1 an exact entry or inside a CIDR of the comma-separated list $2?
_api_ip_in_list() {
    local ip="$1" list="$2" entry
    local IFS=','
    for entry in $list; do
        entry="${entry// /}"
        [[ -z "$entry" ]] && continue
        [[ "$ip" == "$entry" ]] && return 0
        [[ "$entry" == */* ]] && _api_ip_in_cidr "$ip" "$entry" && return 0
    done
    return 1
}

# Resolve the client IP for this request into CLIENT_IP. socat exposes the TCP
# peer as SOCAT_PEERADDR (ncat: NCAT_REMOTE_ADDR). When that peer is a trusted
# proxy, X-Forwarded-For is walked from the right, skipping trusted hops, so a
# client cannot spoof its address by sending its own X-Forwarded-For header.
_api_resolve_client_ip() {
    CLIENT_IP="${SOCAT_PEERADDR-}"
    [[ -z "$CLIENT_IP" ]] && CLIENT_IP="${NCAT_REMOTE_ADDR-}"
    [[ -z "$CLIENT_IP" ]] && CLIENT_IP="127.0.0.1"
    if [[ -n "$API_TRUSTED_PROXIES" && -n "${REQUEST_XFF_HEADER:-}" ]] && _api_ip_in_list "$CLIENT_IP" "$API_TRUSTED_PROXIES"; then
        local -a hops
        local IFS=','
        read -ra hops <<< "$REQUEST_XFF_HEADER"
        local i hop
        for (( i = ${#hops[@]} - 1; i >= 0; i-- )); do
            hop="${hops[$i]//[[:space:]]/}"
            [[ "$hop" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || break
            if _api_ip_in_list "$hop" "$API_TRUSTED_PROXIES"; then
                continue
            fi
            CLIENT_IP="$hop"
            break
        done
    fi
}

# Check if the connecting IP is allowed (CLIENT_IP is set by handle_request)
_api_check_ip_whitelist() {
    [[ -z "$API_IP_WHITELIST" ]] && return 0  # no whitelist = allow all

    local client_ip="${CLIENT_IP:-127.0.0.1}"

    # Always allow localhost
    case "$client_ip" in
        127.0.0.1|::1|localhost) return 0 ;;
    esac

    _api_ip_in_list "$client_ip" "$API_IP_WHITELIST"
}

# Check global rate limit for the connecting IP
# Returns 0 if within limit, 1 if rate limited
_api_check_global_rate_limit() {
    (( API_RATE_LIMIT <= 0 )) && return 0  # rate limiting disabled

    local client_ip="${CLIENT_IP:-127.0.0.1}"
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

    # First-run window: no account exists yet and setup has never completed
    # (fresh install or factory reset). Only what the setup wizard needs is
    # reachable anonymously — the public routes handled before this check plus
    # GET /version — so that an API exposed on the network can't be driven by
    # a bystander before the owner has created the admin account.
    local user_count
    user_count=$(_api_user_count)
    if [[ "$user_count" -eq 0 ]] && [[ ! -f "$API_AUTH_DIR/.setup-complete" ]]; then
        if [[ "${REQUEST_METHOD:-GET}" == "GET" && "${REQUEST_PATH:-/}" == "/version" ]]; then
            AUTH_USERNAME="anonymous"
            AUTH_ROLE="admin"
            return 0
        fi
        AUTH_ERROR="Setup required: create the first admin account with POST /auth/setup before using this endpoint."
        return 1
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

# Role policy for a route, applied by the router right after authentication.
# Admins may call everything. The "user" role is a viewer: it can read
# operational data and manage its own session/profile, but every request that
# changes the system, executes code or exposes secrets requires admin.
# Handlers keep their own _api_check_admin calls as defence in depth.
_api_route_allowed() {
    local method="$1" path="$2"
    [[ "${AUTH_ROLE:-}" == "admin" ]] && return 0
    case "$method" in
        GET)
            case "$path" in
                /env|/stacks/*/env|/snapshots|/snapshots/*|/audit|/terminal/history|\
                /backups|/backups/*|/secrets|/secrets/*|/system/crontab|/system/crontab/*|\
                /system/update/check|/system/os-update/*|/ddns/status|/dns/records|/dns/zones|\
                /plugins/*/hooks|/plugins/*/hooks/*|/plugins/*/logs|/plugins/*/cards/*/source|\
                /containers/*/files|/containers/*/files/*|/export/config|\
                /auth/users|/auth/invites|/auth/sessions|/templates/deploy-history)
                    return 1 ;;
            esac
            return 0 ;;
        *)
            case "$path" in
                /auth/logout|/auth/refresh|/auth/totp/*|/settings/dashboard|/settings/profile|\
                /setup/configure|/setup/complete|/compose/validate|/stacks/*/compose/validate|\
                /env/validate|/templates/*/dry-run|/crowdsec/unban-me)
                    return 0 ;;
            esac
            return 1 ;;
    esac
}

# Apply a jq filter to a JSON state file atomically under an exclusive lock.
# Usage: _api_jq_update_file FILE [jq options...] FILTER
_api_jq_update_file() {
    local file="$1"; shift
    (
        flock -w 5 200 || exit 1
        local out
        out=$(jq "$@" "$file" 2>/dev/null) || exit 1
        [[ -n "$out" ]] || exit 1
        printf '%s\n' "$out" > "$file.tmp" && chmod 600 "$file.tmp" 2>/dev/null && mv -f "$file.tmp" "$file"
    ) 200>"$file.lock"
}

# Format a byte count for humans (K/M/G with one decimal)
_api_fmt_bytes() {
    local b="${1:-0}"
    [[ "$b" =~ ^[0-9]+$ ]] || b=0
    if (( b >= 1073741824 )); then printf '%d.%dG' $(( b / 1073741824 )) $(( (b % 1073741824) * 10 / 1073741824 ))
    elif (( b >= 1048576 )); then printf '%d.%dM' $(( b / 1048576 )) $(( (b % 1048576) * 10 / 1048576 ))
    elif (( b >= 1024 )); then printf '%dK' $(( b / 1024 ))
    else printf '%dB' "$b"; fi
}

# Validate an image reference (name[:tag][@digest]) — rejects option-like and
# shell-hostile values before it reaches docker.
_api_validate_image_ref() {
    local ref="$1"
    if [[ -z "$ref" || ${#ref} -gt 255 || ! "$ref" =~ ^[a-zA-Z0-9][a-zA-Z0-9._:/@-]*$ ]]; then
        _api_error 400 "Invalid image reference"
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
    # Block: "- /etc:/something" or bare "- /etc"
    # Allow: "- /etc/localtime:/etc/localtime:ro" or "- /etc/timezone:/etc/timezone:ro"
    if printf '%s' "$lower_content" | grep -qE '^\s+-\s*["'"'"']?/etc["'"'"']?(:|[[:space:]]|$)'; then
        # Only flag if mounting /etc root, not a subdirectory like /etc/localtime
        local etc_lines
        etc_lines=$(printf '%s' "$lower_content" | grep -E '^\s+-\s*["'"'"']?/etc["'"'"']?(:|[[:space:]]|$)')
        if echo "$etc_lines" | grep -qvE '/etc/'; then
            violations+=("mounting /etc is not allowed (contains system configuration)")
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
        if [[ "${_API_SCAN_QUIET:-false}" == "true" ]]; then
            # Collect-only mode: print the findings and let the caller decide
            printf '%s' "$details"
            return 1
        fi
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
    if [[ ! -f "$rate_file" ]]; then
        printf '{}' > "$rate_file" 2>/dev/null
        chmod 600 "$rate_file" 2>/dev/null
    fi

    if command -v jq >/dev/null 2>&1; then
        local now
        now=$(_api_now_epoch)
        local record
        record=$(cat "$rate_file" | jq -r --arg ip "$client_ip" '.[$ip] // empty' 2>/dev/null)
        if [[ -n "$record" ]]; then
            local locked_until
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

    local record
    record=$(echo "$invites" | jq -r --arg c "$code" --argjson n "$now" \
        '.[] | select(.code == $c and .expires_at > $n and (.used != true))' 2>/dev/null)
    if [[ -n "$record" ]]; then
        echo "$record" | jq -r '.role' 2>/dev/null
        return 0
    fi
    return 1
}

# Consume an invite code after use — marks as used instead of deleting
_api_consume_invite() {
    local code="$1" username="${2:-unknown}"
    local invites
    invites=$(_api_read_auth_file "invites.json")

    local new_invites
    new_invites=$(echo "$invites" | jq --arg c "$code" --arg u "$username" \
        '[.[] | if .code == $c then . + {"used": true, "used_by": $u} else . end]' 2>/dev/null)
    _api_write_auth_file "invites.json" "$new_invites"
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
                    (try ($now - (.State.StartedAt | split(".")[0] + "Z" | fromdateiso8601)) catch 0) else 0 end),
                ports: ([.NetworkSettings.Ports | to_entries[] |
                    select(.value != null) | .value[] |
                    (if .HostIp == "" or .HostIp == "0.0.0.0" then "0.0.0.0" else .HostIp end) +
                    ":" + .HostPort + "->" + (.key // "")] | join(", ")),
                restart_count: (.RestartCount // 0)
            }' 2>/dev/null
        return
    fi

    # Fallback without jq — single inspect call
    local _info name state health image
    _info=$(timeout 3 docker inspect --format='{{.Name}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.Config.Image}}' "$container_id" 2>/dev/null) || _info="/$container_id|unknown|none|unknown"
    _info="${_info#/}"
    IFS='|' read -r name state health image <<< "$_info"

    printf '{"name":"%s","state":"%s","health":"%s","image":"%s","image_id":"","created":"","uptime_seconds":0,"ports":"","restart_count":0}' \
        "$(_api_json_escape "$name")" "$(_api_json_escape "$state")" "$(_api_json_escape "$health")" "$(_api_json_escape "$image")"
}

# =============================================================================
# ENDPOINT HANDLERS
# =============================================================================

# GET / — API name, version, authentication mode and the endpoint list
handle_root() {
    # Endpoint catalogue — generated by .scripts/api-docs.sh (do not edit by hand)
    local endpoints
    read -r -d '' endpoints <<'DCS_ENDPOINTS' || true
[{"method":"GET","path":"/","access":"public","description":"API name, version, authentication mode and the endpoint list"},{"method":"GET","path":"/auth/verify","access":"public","description":"Verify a token is valid"},{"method":"GET","path":"/setup/status","access":"public","description":"Always available, no auth. Reports whether server needs setup."},{"method":"GET","path":"/setup/defaults","access":"public","description":"Defaults and detected system values for the setup wizard (anonymous until setup is complete, admin afterwards)"},{"method":"GET","path":"/auth/users","access":"admin","description":"List all users (admin only)"},{"method":"GET","path":"/auth/invites","access":"admin","description":"List active invite codes (admin only)"},{"method":"GET","path":"/auth/sessions","access":"admin","description":"List active sessions (admin only)"},{"method":"GET","path":"/status","access":"user","description":"Host and Docker overview: containers, images, stacks, load, memory, disk, GPU"},{"method":"GET","path":"/health","access":"user","description":"Health report for every container (running, unhealthy, stopped, restart loops)"},{"method":"GET","path":"/stacks","access":"user","description":"All stacks with running-container counts"},{"method":"GET","path":"/images","access":"user","description":"Images with age, size and staleness (/images/stale lists only stale ones)"},{"method":"GET","path":"/images/stale","access":"user","description":"Images with age, size and staleness (/images/stale lists only stale ones)"},{"method":"GET","path":"/containers","access":"user","description":"All containers with state, health, ports and cached CPU/memory usage"},{"method":"GET","path":"/config","access":"user","description":"Effective configuration (secrets masked)"},{"method":"GET","path":"/system","access":"user","description":"Host resources: CPU, memory, uptime, kernel"},{"method":"GET","path":"/disks","access":"user","description":"Mounted filesystems and their usage"},{"method":"GET","path":"/networks","access":"user","description":"Docker networks with connected containers"},{"method":"GET","path":"/volumes","access":"user","description":"Docker volumes"},{"method":"GET","path":"/logs","access":"user","description":"Tail of the framework log"},{"method":"GET","path":"/logs/stats","access":"user","description":"Log file size and per-level counts"},{"method":"GET","path":"/logs/archives","access":"user","description":"Rotated log archives"},{"method":"GET","path":"/events","access":"user","description":"Recent Docker events"},{"method":"GET","path":"/version","access":"user","description":"API, framework, Docker and Compose versions"},{"method":"GET","path":"/maintenance/report","access":"user","description":"Docker disk usage report"},{"method":"GET","path":"/maintenance/orphans","access":"user","description":"Containers, volumes and networks no stack references"},{"method":"GET","path":"/maintenance/disk","access":"user","description":"Per-stack App-Data sizes, Docker disk usage and volume sizes"},{"method":"GET","path":"/env","access":"admin","description":"The root .env file, raw and parsed"},{"method":"GET","path":"/backups","access":"admin","description":"Backup archives in BACKUP_DEST_DIR"},{"method":"GET","path":"/backups/status","access":"admin","description":"Progress of the running backup or the last result"},{"method":"GET","path":"/backups/config","access":"admin","description":"Backup source, destination and retention"},{"method":"GET","path":"/terminal/history","access":"admin","description":"Recent terminal commands from the audit log"},{"method":"GET","path":"/system/metrics","access":"user","description":"CPU load, memory and per-mount disk usage"},{"method":"GET","path":"/system/update/check","access":"admin","description":"Check for available DCS updates via git"},{"method":"GET","path":"/system/os-update/status","access":"admin","description":"Poll background OS update progress"},{"method":"GET","path":"/ddns/status","access":"admin","description":"Check DDNS status and current IP"},{"method":"GET","path":"/alerts/config","access":"user","description":"Read alert thresholds"},{"method":"GET","path":"/system/crontab","access":"admin","description":"User crontab entries"},{"method":"GET","path":"/system/crontab/system","access":"admin","description":"System-level cron entries"},{"method":"GET","path":"/metrics/trends","access":"user","description":"Metrics samples for a range (range=1h|6h|24h|7d|30d|90d|1y|all), downsampled, with min/max for rolled-up points"},{"method":"GET","path":"/images/check-updates","access":"user","description":"Image staleness from age plus the cached registry check"},{"method":"GET","path":"/notifications/rules","access":"user","description":"NTFY notification rules"},{"method":"GET","path":"/notifications/history","access":"user","description":"Recently sent notifications"},{"method":"GET","path":"/snapshots","access":"admin","description":"Configuration snapshots"},{"method":"GET","path":"/templates","access":"user","description":"Available templates"},{"method":"GET","path":"/templates/deploy-history","access":"admin","description":"Template deploy and undeploy events"},{"method":"GET","path":"/automations","access":"user","description":"Automation rules"},{"method":"GET","path":"/crowdsec/status","access":"user","description":"CrowdSec presence, whitelist state and active decisions"},{"method":"GET","path":"/routes/health","access":"user","description":"Probe every custom route through Traefik (no changes made)"},{"method":"GET","path":"/crowdsec/decisions","access":"user","description":"Active CrowdSec decisions (bans)"},{"method":"GET","path":"/topology","access":"user","description":"Container and network topology graph"},{"method":"GET","path":"/traefik/status","access":"user","description":"Check if Traefik is deployed and return domain"},{"method":"GET","path":"/routes","access":"user","description":"Traefik routes: subdomain, service, stack and target"},{"method":"GET","path":"/routes/check","access":"user","description":"Check if a subdomain is available"},{"method":"GET","path":"/dns/status","access":"user","description":"Cloudflare integration: where the token comes from, whether it is valid, the zone"},{"method":"GET","path":"/dns/zones","access":"admin","description":"Zones the Cloudflare token can manage"},{"method":"GET","path":"/dns/records","access":"admin","description":"DNS records of the zone (all types) with their DCS route links"},{"method":"GET","path":"/homarr/status","access":"user","description":"Check if Homarr is deployed and has an API key configured"},{"method":"GET","path":"/metrics/history","access":"user","description":"Metrics samples for a range (range=1h|6h|24h|7d|30d|90d|1y|all); same data as /metrics/trends under \"data\""},{"method":"GET","path":"/metrics/summary","access":"user","description":"Min, max and average CPU, memory and disk over a range (range=1h|6h|24h|7d|30d|90d|1y|all)"},{"method":"GET","path":"/health/score","access":"user","description":"System health score (0-100) with its factors"},{"method":"GET","path":"/health/score/history","access":"user","description":"Recorded health scores over a range"},{"method":"GET","path":"/settings/dashboard","access":"user","description":"Fetch user's dashboard layout"},{"method":"GET","path":"/settings/profile","access":"user","description":"Fetch user's profile settings"},{"method":"GET","path":"/secrets","access":"admin","description":"List secret key names (never values)"},{"method":"GET","path":"/schedules","access":"user","description":"Return schedules.json content"},{"method":"GET","path":"/plugins","access":"user","description":"Scan .plugins/ directory, return plugin manifest data"},{"method":"GET","path":"/plugins/cards","access":"user","description":"List all available plugin cards across all enabled plugins"},{"method":"GET","path":"/plugins/catalog","access":"user","description":"Plugins available to install, with their manifest and installed state"},{"method":"GET","path":"/plugins/{plugin}/cards/*/source","access":"admin","description":"The card's manifest and raw HTML, for editing"},{"method":"GET","path":"/plugins/{plugin}/cards/{card}","access":"user","description":"Return card HTML content as JSON"},{"method":"GET","path":"/plugins/{plugin}/hooks/{hook}","access":"admin","description":"Read hook script content"},{"method":"GET","path":"/plugins/{plugin}/hooks","access":"admin","description":"List all hooks with metadata"},{"method":"GET","path":"/plugins/{plugin}/logs","access":"admin","description":"Execution history"},{"method":"GET","path":"/config/schema","access":"user","description":"Return contents of .config/schema.json"},{"method":"GET","path":"/stream","access":"user","description":"SSE endpoint: docker events + periodic metrics"},{"method":"GET","path":"/rollback/{stack}/snapshots/{snapshot}","access":"user","description":"Content of a rollback snapshot"},{"method":"GET","path":"/rollback/{stack}/snapshots","access":"user","description":"Rollback snapshots of a stack"},{"method":"GET","path":"/rollback/{stack}/diff/{snapshot}","access":"user","description":"Diff between a snapshot and the current stack files"},{"method":"GET","path":"/secrets/{key}/exists","access":"admin","description":"Check if a secret exists (boolean)"},{"method":"GET","path":"/secrets/{key}/references","access":"admin","description":"Stacks and env files that reference a secret"},{"method":"GET","path":"/health/score/{stack}","access":"user","description":"Compute health score for a specific stack"},{"method":"GET","path":"/schedules/{id}/history","access":"user","description":"Return execution history filtered by schedule id"},{"method":"GET","path":"/templates/gallery","access":"user","description":"List templates from gallery catalog"},{"method":"GET","path":"/templates/{template}","access":"user","description":"Template metadata, compose file and .env"},{"method":"GET","path":"/images/search","access":"user","description":"Search Docker Hub for images"},{"method":"GET","path":"/export/{health|system|config}","access":"user","description":"Export data"},{"method":"GET","path":"/audit","access":"admin","description":"Get audit log entries"},{"method":"GET","path":"/webhooks","access":"user","description":"List webhooks"},{"method":"GET","path":"/snapshots/{snapshot}/download","access":"admin","description":"Download a snapshot archive"},{"method":"GET","path":"/stacks/{stack}/compose/history/{version}","access":"user","description":"View a specific compose version's content"},{"method":"GET","path":"/stacks/{stack}/compose/history","access":"user","description":"Saved versions of a stack's compose file"},{"method":"GET","path":"/automations/{id}/history","access":"user","description":"Run history of an automation"},{"method":"GET","path":"/containers/{container}/files","access":"admin","description":"List directory contents inside a container"},{"method":"GET","path":"/containers/{container}/files/content","access":"admin","description":"Read file contents inside a container"},{"method":"GET","path":"/containers/{container}/logs/live","access":"user","description":"Fetch recent logs for polling"},{"method":"GET","path":"/logs/live","access":"user","description":"Stream DCS application log"},{"method":"GET","path":"/stacks/{stack}/activity","access":"user","description":"Progress of the action running (or last run) on a stack: phase, per-service state, compose output"},{"method":"GET","path":"/stacks/{stack}/services","access":"user","description":"Services of a stack with container state, health and image"},{"method":"GET","path":"/stacks/{stack}/containers","access":"user","description":"Containers of one stack"},{"method":"GET","path":"/stacks/{stack}/logs","access":"user","description":"Recent log lines of a stack"},{"method":"GET","path":"/stacks/{stack}/compose","access":"user","description":"The stack's docker-compose.yml"},{"method":"GET","path":"/stacks/{stack}/env","access":"admin","description":"The stack's .env file"},{"method":"GET","path":"/stacks/{stack}","access":"user","description":"Stack detail: services, containers and images"},{"method":"GET","path":"/containers/{container}/stats","access":"user","description":"Live CPU, memory, network and block I/O of a container"},{"method":"GET","path":"/containers/{container}/logs","access":"user","description":"Recent log lines of a container"},{"method":"GET","path":"/containers/{container}/processes","access":"user","description":"Process list inside a container"},{"method":"GET","path":"/networks/{network}","access":"user","description":"Network detail with its members"},{"method":"GET","path":"/containers/{container}","access":"user","description":"Container detail"},{"method":"POST","path":"/auth/setup","access":"public","description":"Create the first admin account (only when no users exist)"},{"method":"POST","path":"/auth/login","access":"public","description":"Authenticate and get a session token"},{"method":"POST","path":"/auth/register","access":"public","description":"Register a new account with an invite code"},{"method":"POST","path":"/auth/totp/validate","access":"public","description":"Validate TOTP code during login (second step)"},{"method":"POST","path":"/setup/configure","access":"user","description":"Apply the setup wizard's settings and stack list"},{"method":"POST","path":"/setup/complete","access":"user","description":"Mark first-run setup as finished"},{"method":"POST","path":"/auth/logout","access":"user","description":"Invalidate the current session token"},{"method":"POST","path":"/auth/refresh","access":"user","description":"Refresh the current session token"},{"method":"POST","path":"/auth/totp/setup","access":"user","description":"Generate TOTP secret and return QR URI (not yet enabled)"},{"method":"POST","path":"/auth/totp/verify","access":"user","description":"Verify a TOTP code and enable 2FA"},{"method":"POST","path":"/auth/totp/disable","access":"user","description":"Disable 2FA (requires password confirmation)"},{"method":"POST","path":"/auth/invite","access":"admin","description":"Generate an invite code (admin only)"},{"method":"POST","path":"/auth/revoke","access":"admin","description":"Revoke a user's access (admin only)"},{"method":"POST","path":"/auth/logout-all","access":"admin","description":"Invalidate all sessions for a user (admin only)"},{"method":"POST","path":"/auth/factory-reset","access":"admin","description":"Wipe auth state and return server to first-run mode"},{"method":"POST","path":"/stacks/rename","access":"admin","description":"Rename a stack directory"},{"method":"POST","path":"/stacks/reorder","access":"admin","description":"Set stack startup order"},{"method":"POST","path":"/terminal/exec","access":"admin","description":"Run a shell command on the host (terminal session required, 60 s limit)"},{"method":"POST","path":"/terminal/auth","access":"admin","description":"Authenticate with Linux credentials"},{"method":"POST","path":"/terminal/auth/verify","access":"admin","description":"Verify a terminal session token"},{"method":"POST","path":"/terminal/auth/logout","access":"admin","description":"Invalidate a terminal session"},{"method":"POST","path":"/alerts/config","access":"admin","description":"Update alert thresholds"},{"method":"POST","path":"/system/crontab","access":"admin","description":"Update user crontab"},{"method":"POST","path":"/system/update/apply","access":"admin","description":"Apply update safely using git pull --ff-only"},{"method":"POST","path":"/system/ui-update/apply","access":"admin","description":"Pull latest DCS-UI image and recreate container"},{"method":"POST","path":"/system/update/rollback","access":"admin","description":"Rollback to a previously created backup tag"},{"method":"POST","path":"/system/os-update/check","access":"admin","description":"List available OS package updates (terminal session required)"},{"method":"POST","path":"/system/os-update/apply","access":"admin","description":"Apply OS package updates in the background (terminal session required)"},{"method":"POST","path":"/stacks","access":"admin","description":"Create an empty stack directory"},{"method":"POST","path":"/stacks/{stack}/delete","access":"admin","description":"Delete a stopped stack directory"},{"method":"POST","path":"/config","access":"admin","description":"Update allow-listed .env settings"},{"method":"POST","path":"/containers/{container}/start","access":"admin","description":"Start, stop, restart, recreate (Compose-managed only) or remove a container"},{"method":"POST","path":"/containers/{container}/stop","access":"admin","description":"Start, stop, restart, recreate (Compose-managed only) or remove a container"},{"method":"POST","path":"/containers/{container}/restart","access":"admin","description":"Start, stop, restart, recreate (Compose-managed only) or remove a container"},{"method":"POST","path":"/containers/{container}/recreate","access":"admin","description":"Start, stop, restart, recreate (Compose-managed only) or remove a container"},{"method":"POST","path":"/containers/{container}/remove","access":"admin","description":"Start, stop, restart, recreate (Compose-managed only) or remove a container"},{"method":"POST","path":"/containers/{container}/exec","access":"admin","description":"Run a command inside a container (30 s limit)"},{"method":"POST","path":"/containers/{container}/env","access":"admin","description":"Change a Compose-managed container's environment in its stack {set{}, unset[], recreate}"},{"method":"POST","path":"/containers/{container}/rename","access":"admin","description":"Rename a container"},{"method":"POST","path":"/networks","access":"admin","description":"Create a Docker network {name, driver, subnet, gateway, ip_range, internal, attachable, ipv6, labels}"},{"method":"POST","path":"/networks/{network}/delete","access":"admin","description":"Remove a Docker network"},{"method":"POST","path":"/networks/{network}/connect","access":"admin","description":"Connect a container to a network"},{"method":"POST","path":"/networks/{network}/disconnect","access":"admin","description":"Disconnect a container from a network"},{"method":"POST","path":"/networks/{network}/recreate","access":"admin","description":"Rebuild a network with new settings and reconnect its containers"},{"method":"POST","path":"/images/{image}/delete","access":"admin","description":"Remove an image"},{"method":"POST","path":"/volumes/{volume}/delete","access":"admin","description":"Remove a Docker volume"},{"method":"POST","path":"/maintenance/prune","access":"admin","description":"Prune stopped containers, dangling images and unused networks"},{"method":"POST","path":"/maintenance/image-prune","access":"admin","description":"Prune unused images"},{"method":"POST","path":"/maintenance/deep-prune","access":"admin","description":"Prune everything unused, volumes included (confirmation required)"},{"method":"POST","path":"/maintenance/log-rotate","access":"admin","description":"Rotate and archive the framework log"},{"method":"POST","path":"/batch/stacks","access":"admin","description":"Start, stop or restart several stacks in dependency order"},{"method":"POST","path":"/batch/update","access":"admin","description":"Pull images for several stacks and recreate what changed"},{"method":"POST","path":"/env","access":"admin","description":"Save the root .env file (validated as plain KEY=value data)"},{"method":"POST","path":"/env/validate","access":"user","description":"Validate .env content without saving it"},{"method":"POST","path":"/backups/trigger","access":"admin","description":"Start a backup in the background (optionally one stack)"},{"method":"POST","path":"/backups/cancel","access":"admin","description":"Kill a running backup"},{"method":"POST","path":"/backups/restore","access":"admin","description":"Restore a backup archive (confirmation required)"},{"method":"POST","path":"/stacks/{stack}/compose/validate","access":"user","description":"Validate compose content for a stack without saving it"},{"method":"POST","path":"/stacks/{stack}/compose","access":"admin","description":"Save the stack's docker-compose.yml (policy-scanned, previous version kept)"},{"method":"POST","path":"/stacks/{stack}/env","access":"admin","description":"Save the stack's .env file"},{"method":"POST","path":"/stacks/{stack}/compose/rollback","access":"admin","description":"Restore a saved compose version"},{"method":"POST","path":"/settings/dashboard","access":"user","description":"Save user's dashboard layout"},{"method":"POST","path":"/settings/profile","access":"user","description":"Save user's profile settings"},{"method":"POST","path":"/metrics/snapshot","access":"admin","description":"Record a metrics sample now"},{"method":"POST","path":"/dns/records","access":"admin","description":"Create a record {type, name, content, ttl, proxied, priority, comment, zone}"},{"method":"POST","path":"/dns/records/sync","access":"admin","description":"Create the proxied CNAME records that DCS routes are missing"},{"method":"POST","path":"/images/check-updates","access":"admin","description":"Compare local image digests with their registries (slow)"},{"method":"POST","path":"/images/update","access":"admin","description":"Pull an image and recreate the Compose services that use it"},{"method":"POST","path":"/images/{image}/update","access":"admin","description":"Pull an image and recreate the Compose services that use it"},{"method":"POST","path":"/notifications/rules","access":"admin","description":"Create or update a notification rule"},{"method":"POST","path":"/notifications/test","access":"admin","description":"Send a test notification to every configured channel (NTFY, Discord)"},{"method":"POST","path":"/snapshots/create","access":"admin","description":"Create a configuration snapshot (compose files, .env files, templates)"},{"method":"POST","path":"/snapshots/{snapshot}/restore","access":"admin","description":"Restore a snapshot (confirmation required, policy-scanned)"},{"method":"POST","path":"/templates/{template}/deploy","access":"admin","description":"Deploy a template into a stack (merge, routes, DNS, optional start)"},{"method":"POST","path":"/templates/{template}/undeploy","access":"admin","description":"Remove a template's services from a stack with their containers (remove_containers=false keeps them; optionally data, images, routes)"},{"method":"POST","path":"/templates/{template}/dry-run","access":"user","description":"Preview a deployment: conflicts, ports, variables and policy findings"},{"method":"POST","path":"/templates/import","access":"admin","description":"Import a template from compose content"},{"method":"POST","path":"/templates/fetch-url","access":"admin","description":"Fetch compose content from URL without saving"},{"method":"POST","path":"/templates/import-url","access":"admin","description":"Import a template from a URL"},{"method":"POST","path":"/stacks/{stack}/clone","access":"admin","description":"Clone a stack"},{"method":"POST","path":"/compose/validate","access":"user","description":"Validate a compose file"},{"method":"POST","path":"/webhooks","access":"admin","description":"Create a webhook"},{"method":"POST","path":"/webhooks/{id}/test","access":"admin","description":"Test a webhook"},{"method":"POST","path":"/templates/{template}/update","access":"admin","description":"Update an existing template's compose, metadata, and .env"},{"method":"POST","path":"/routes/reconcile","access":"admin","description":"Probe the routes and restart Traefik once if they are dead"},{"method":"POST","path":"/crowdsec/trust","access":"admin","description":"Add an address to the whitelist (body {ip}; defaults to the home public address and the caller)"},{"method":"POST","path":"/crowdsec/unban-me","access":"user","description":"Unban the caller: its client address and the home public address"},{"method":"POST","path":"/automations","access":"admin","description":"Create an automation rule"},{"method":"POST","path":"/automations/{id}/update","access":"admin","description":"Update an automation rule"},{"method":"POST","path":"/automations/{id}/run","access":"admin","description":"Run an automation now"},{"method":"POST","path":"/stacks/{stack}/start","access":"admin","description":"Start, stop, restart or update (pull + recreate) a stack"},{"method":"POST","path":"/stacks/{stack}/stop","access":"admin","description":"Start, stop, restart or update (pull + recreate) a stack"},{"method":"POST","path":"/stacks/{stack}/restart","access":"admin","description":"Start, stop, restart or update (pull + recreate) a stack"},{"method":"POST","path":"/stacks/{stack}/update","access":"admin","description":"Start, stop, restart or update (pull + recreate) a stack"},{"method":"POST","path":"/secrets","access":"admin","description":"Store an encrypted secret (also POST /secrets/{key})"},{"method":"POST","path":"/secrets/{key}","access":"admin","description":"Store an encrypted secret (also POST /secrets/{key})"},{"method":"POST","path":"/schedules","access":"admin","description":"Create a scheduled task"},{"method":"POST","path":"/plugins/install","access":"admin","description":"Install a plugin from a git URL (installed disabled)"},{"method":"POST","path":"/plugins/scaffold","access":"admin","description":"Create a plugin from an inline manifest, hooks and cards"},{"method":"POST","path":"/rollback/{stack}/restore","access":"admin","description":"Restore a stack from a rollback snapshot (policy-scanned)"},{"method":"POST","path":"/schedules/{id}/update","access":"admin","description":"Update a scheduled task"},{"method":"POST","path":"/schedules/{id}/toggle","access":"admin","description":"Enable/disable a schedule"},{"method":"POST","path":"/schedules/{id}/run","access":"admin","description":"Execute a schedule immediately"},{"method":"POST","path":"/plugins/catalog/*/install","access":"admin","description":"Install a catalogue plugin (copied into .plugins, disabled)"},{"method":"POST","path":"/plugins/{plugin}/cards/{card}","access":"admin","description":"Create or replace a dashboard card in a plugin {meta{}, html}"},{"method":"POST","path":"/plugins/{plugin}/toggle","access":"admin","description":"Enable/disable by writing to plugin.json"},{"method":"POST","path":"/plugins/{plugin}/hooks/{hook}/test","access":"admin","description":"Dry-run a hook"},{"method":"POST","path":"/plugins/{plugin}/hooks/{hook}/update","access":"admin","description":"Update hook script"},{"method":"POST","path":"/plugins/{plugin}/config","access":"admin","description":"Update plugin configuration"},{"method":"PUT","path":"/dns/records/*","access":"admin","description":"Change a record's type, name, content, TTL, proxy status, priority or comment"},{"method":"PUT","path":"/routes/{stack}/{service}","access":"admin","description":"Update a route file's subdomain"},{"method":"DELETE","path":"/auth/sessions/{token-prefix}","access":"admin","description":"Revoke a specific session by token prefix (admin only)"},{"method":"DELETE","path":"/auth/invite/{code}","access":"admin","description":"Delete an invite code (admin only)"},{"method":"DELETE","path":"/notifications/rules/{id}","access":"admin","description":"Delete a notification rule"},{"method":"DELETE","path":"/snapshots/{snapshot}","access":"admin","description":"Delete a snapshot"},{"method":"DELETE","path":"/webhooks/{id}","access":"admin","description":"Delete a webhook"},{"method":"DELETE","path":"/templates/{template}","access":"admin","description":"Delete a template"},{"method":"DELETE","path":"/crowdsec/decisions/*","access":"admin","description":"Remove every decision for an address (unban)"},{"method":"DELETE","path":"/crowdsec/trust/*","access":"admin","description":"Remove an address from the whitelist"},{"method":"DELETE","path":"/automations/{id}","access":"admin","description":"Delete an automation rule"},{"method":"DELETE","path":"/secrets/{key}","access":"admin","description":"Securely delete a secret"},{"method":"DELETE","path":"/schedules/{id}","access":"admin","description":"Remove a schedule"},{"method":"DELETE","path":"/plugins/{plugin}/cards/{card}","access":"admin","description":"Remove a dashboard card from a plugin"},{"method":"DELETE","path":"/plugins/{plugin}","access":"admin","description":"Remove plugin directory"},{"method":"DELETE","path":"/dns/records/*","access":"admin","description":"Delete a record (the zone apex and names DCS routes use need force=true)"},{"method":"DELETE","path":"/routes/{stack}/{service}","access":"admin","description":"Delete a route file and optionally clean up DNS"}]
DCS_ENDPOINTS

    _api_success "{\"name\": \"Docker Compose Skeleton API\", \"version\": \"$API_VERSION\", \"auth_enabled\": $API_AUTH_ENABLED, \"endpoints\": $endpoints}"
}

# GET /version — API, framework, Docker and Compose versions
handle_version() {
    local docker_version compose_version
    docker_version=$(_api_json_escape "$(docker --version 2>/dev/null)")
    compose_version=$(_api_json_escape "$($DOCKER_COMPOSE_CMD version 2>/dev/null)")

    _api_success "{\"api_version\": \"$API_VERSION\", \"framework_version\": \"$(_api_json_escape "$DCS_VERSION")\", \"docker_version\": \"$docker_version\", \"compose_version\": \"$compose_version\", \"compose_command\": \"$(_api_json_escape "$DOCKER_COMPOSE_CMD")\"}"
}

# GET /status — Host and Docker overview: containers, images, stacks, load, memory, disk, GPU
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
            # Top-level images, the same rows the Images page lists (docker info's
            # count also includes untagged intermediate layers)
            total_images=$(docker images -q 2>/dev/null | wc -l | tr -d ' ')
        fi
    fi

    # Volumes and networks (fast, no heavy operations)
    total_volumes=$(timeout 3 docker volume ls -q 2>/dev/null | wc -l)
    total_networks=$(timeout 3 docker network ls --format '{{.Name}}' 2>/dev/null | grep -cv '^bridge$\|^host$\|^none$') || total_networks=0

    # Disk: the filesystem that holds this installation (stacks and App-Data)
    local disk_usage
    disk_usage=$(df -hP "$BASE_DIR" 2>/dev/null | tail -1 | awk '{printf "{\"total\": \"%s\", \"used\": \"%s\", \"available\": \"%s\", \"percent\": \"%s\", \"mount\": \"%s\"}", $2, $3, $4, $5, $6}')
    [[ -z "$disk_usage" || "$disk_usage" == *'""'* ]] && disk_usage=$(df -hP / 2>/dev/null | tail -1 | awk '{printf "{\"total\": \"%s\", \"used\": \"%s\", \"available\": \"%s\", \"percent\": \"%s\", \"mount\": \"/\"}", $2, $3, $4, $5}')

    local load_avg mem_total mem_available swap_total swap_free
    load_avg=$(awk '{printf "[%s, %s, %s]", $1, $2, $3}' /proc/loadavg 2>/dev/null || echo "[0,0,0]")
    mem_total=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    mem_available=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    swap_total=$(awk '/SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    swap_free=$(awk '/SwapFree/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)

    local uptime_seconds
    uptime_seconds=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 0)

    # Fast stack count: use docker compose ls (single command, lists all projects)
    local stacks
    read -ra stacks <<< "$(_api_get_stacks)"
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

    # GPU detection (NVIDIA via nvidia-smi)
    local gpu_json="null"
    if command -v nvidia-smi >/dev/null 2>&1; then
        local _gpu_name _gpu_util _gpu_mem_used _gpu_mem_total _gpu_temp _gpu_fan
        _gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits 2>/dev/null | head -1)
        _gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        _gpu_mem_used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        _gpu_mem_total=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        _gpu_temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        _gpu_fan=$(nvidia-smi --query-gpu=fan.speed --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        if [[ -n "$_gpu_name" ]]; then
            gpu_json="{\"name\": \"$(_api_json_escape "$_gpu_name")\", \"utilization\": ${_gpu_util:-0}, \"memory_used_mb\": ${_gpu_mem_used:-0}, \"memory_total_mb\": ${_gpu_mem_total:-0}, \"temperature\": ${_gpu_temp:-0}, \"fan_speed\": ${_gpu_fan:-0}}"
        fi
    fi

    _api_success "{\"timestamp\": \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\", \"hostname\": \"$(_api_json_escape "$(hostname)")\", \"uptime_seconds\": $uptime_seconds, \"docker\": {\"containers\": {\"total\": $total_containers, \"running\": $running_containers, \"stopped\": $stopped_containers}, \"images\": $total_images, \"volumes\": $total_volumes, \"networks\": $total_networks}, \"stacks\": {\"total\": ${#stacks[@]}, \"running\": $running_stacks}, \"system\": {\"load_average\": $load_avg, \"memory_mb\": {\"total\": $mem_total, \"available\": $mem_available}, \"swap_mb\": {\"total\": $swap_total, \"free\": $swap_free}, \"gpu\": $gpu_json, \"disk\": $disk_usage, \"cpu_count\": $cpu_count}}"
}

# Internal variant — returns JSON to stdout (used by export handler)
handle_system_info_internal() {
    local load_avg mem_total mem_available uptime_seconds cpu_count disk_usage
    load_avg=$(awk '{printf "[%s, %s, %s]", $1, $2, $3}' /proc/loadavg 2>/dev/null || echo "[0,0,0]")
    mem_total=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    mem_available=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    uptime_seconds=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 0)
    cpu_count=$(nproc 2>/dev/null || echo 0)
    disk_usage=$(df -hP "$BASE_DIR" 2>/dev/null | tail -1 | awk '{printf "{\"total\":\"%s\",\"used\":\"%s\",\"available\":\"%s\",\"percent\":\"%s\"}", $2, $3, $4, $5}')
    [[ -z "$disk_usage" || "$disk_usage" == *'""'* ]] && disk_usage=$(df -hP / 2>/dev/null | tail -1 | awk '{printf "{\"total\":\"%s\",\"used\":\"%s\",\"available\":\"%s\",\"percent\":\"%s\"}", $2, $3, $4, $5}')
    printf '{"hostname":"%s","uptime_seconds":%d,"system":{"load_average":%s,"memory_mb":{"total":%d,"available":%d},"disk":%s,"cpu_count":%d}}' \
        "$(_api_json_escape "$(hostname)")" "$uptime_seconds" "$load_avg" "$mem_total" "$mem_available" "${disk_usage:-{}}" "$cpu_count"
}

# GET /health — Health report for every container (running, unhealthy, stopped, restart loops)
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

# GET /stacks — All stacks with running-container counts
handle_stacks() {
    local stacks
    read -ra stacks <<< "$(_api_get_stacks)"

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

        entries+=("{\"name\": \"$stack\", \"status\": \"$status\", \"running_containers\": $count, \"has_env\": $has_env, \"compose_file\": \"$(_api_json_escape "$compose_file")\"}")
    done

    local json
    json=$(printf '%s,' "${entries[@]}")
    json="[${json%,}]"

    _api_success "{\"total\": ${#stacks[@]}, \"stacks\": $json}"
}

# GET /stacks/{stack} — Stack detail: services, containers and images
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

# GET /stacks/{stack}/containers — Containers of one stack
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

# GET /stacks/{stack}/logs — Recent log lines of a stack
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

# GET /stacks/{stack}/compose — The stack's docker-compose.yml
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

# POST /stacks/{stack}/compose/validate — Validate compose content for a stack without saving it
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

    local _stack_env="$COMPOSE_DIR/$stack/.env"
    local env_args=()
    [[ -f "$_stack_env" ]] && env_args=(--env-file "$_stack_env")

    # Validation is open to the viewer role and returns compose's output, so it
    # must never interpolate: no secrets are injected and --no-interpolate keeps
    # every ${VAR} (including values from the stack .env) out of the response.
    # Saving is a separate, admin-only step that normalizes the .env file.
    local validation_output
    local valid=true
    validation_output=$(
        $DOCKER_COMPOSE_CMD -f "$tmpfile" "${env_args[@]}" config --no-interpolate 2>&1
    ) || valid=false
    rm -f "$tmpfile"

    local escaped_output
    escaped_output=$(_api_json_escape "$validation_output")

    _api_success "{\"valid\": $valid, \"stack\": \"$(_api_json_escape "$stack")\", \"output\": \"$escaped_output\"}"
}

# POST /stacks/{stack}/compose — Save the stack's docker-compose.yml (policy-scanned, previous version kept)
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

# GET /stacks/{stack}/env — The stack's .env file
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

# POST /stacks/{stack}/env — Save the stack's .env file
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

# POST /stacks/{stack}/start — Start, stop, restart or update (pull + recreate) a stack
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

    # A referenced secret that does not exist would start the service with an
    # empty value; refuse up front and name what is missing.
    if [[ "$action" != "stop" ]]; then
        local _missing
        _missing=$(secrets_missing "$compose_file" "$env_file" "$BASE_DIR/.env" | tr '\n' ' ')
        if [[ -n "${_missing// /}" ]]; then
            _api_error 422 "Stack $stack references secrets that do not exist: ${_missing% }. Create them on the Secrets page first."
            return
        fi
    fi

    case "$action" in
        start|stop|restart)
            # Hooks and notifications run in order with a success flag inside
            # the detached job (see _stack_run_detached)
            _stack_run_detached "$action" "$stack"
            case "$action" in
                start)   output="Starting $stack (background)" ;;
                stop)    output="Stopping $stack (background)" ;;
                restart) output="Restarting $stack (background)" ;;
            esac
            ;;
        update)
            _run_plugin_hooks "pre-update" "$(_hook_ctx "$stack" "$_hook_ctx")" sync
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
                output+=$(_compose_with_secrets "$compose_file" "$env_file" up -d --remove-orphans 2>&1) || success=false
            fi

            local changes_json
            changes_json=$(printf '"%s",' "${changes[@]}")
            changes_json="[${changes_json%,}]"

            _run_plugin_hooks "post-update" "$(_hook_ctx "$stack" "{\"action\":\"update\",\"changed_images\":$changes_json}" "$success")"
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

# GET /images — Images with age, size and staleness (/images/stale lists only stale ones)
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

# GET /containers — All containers with state, health, ports and cached CPU/memory usage
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
        ) </dev/null >/dev/null 2>&1 &

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
                    else ((.RunningFor // "") as $rf
                        # "About an hour ago" / "About a minute ago" carry no digit: a
                        # missing match must not empty the whole entry out of the list
                        | ([$rf | match("[0-9]+").string | tonumber] | .[0]) as $n
                        | (if ($rf | test("About a")) then 1 elif $n == null then 0 else $n end) * (
                            if ($rf | test("second")) then 1
                            elif ($rf | test("minute")) then 60
                            elif ($rf | test("hour")) then 3600
                            elif ($rf | test("day")) then 86400
                            elif ($rf | test("week")) then 604800
                            elif ($rf | test("month")) then 2592000
                            elif ($rf | test("year")) then 31536000
                            else 0 end)) end),
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

# GET /containers/{container} — Container detail
handle_container_detail() {
    local name="$1"

    if ! docker inspect "$name" >/dev/null 2>&1; then
        _api_error 404 "Container not found: $name"
        return
    fi

    # Single inspect call — extract all fields via jq
    local _full_inspect
    _full_inspect=$(timeout 5 docker inspect "$name" 2>/dev/null) || {
        _api_error 500 "Failed to inspect container: $name"
        return
    }

    local now_epoch
    now_epoch=$(date +%s)

    local full_json
    full_json=$(printf '%s' "$_full_inspect" | jq -c --argjson now "$now_epoch" '
        .[0] | {
            name: (.Name | ltrimstr("/")),
            state: .State.Status,
            health: (if .State.Health then .State.Health.Status else "none" end),
            image: .Config.Image,
            image_id: (.Image | split(":") | .[1][:12] // ""),
            created: .Created,
            uptime_seconds: (if .State.Status == "running" and .State.StartedAt != "0001-01-01T00:00:00Z" then
                (try ($now - (.State.StartedAt | split(".")[0] + "Z" | fromdateiso8601)) catch 0) else 0 end),
            ports: ([.NetworkSettings.Ports | to_entries[] |
                select(.value != null) | .value[] |
                (if .HostIp == "" or .HostIp == "0.0.0.0" then "0.0.0.0" else .HostIp end) +
                ":" + .HostPort + "->" + (.key // "")] | join(", ")),
            restart_count: (.RestartCount // 0),
            environment: ([.Config.Env // [] | .[] | .] | join("\n")),
            mounts: ([.Mounts // [] | .[] | .Source + ":" + .Destination + (if .Mode != "" then ":" + .Mode else "" end)] | join("\n")),
            networks: ([.NetworkSettings.Networks // {} | keys[] | .] | join("\n")),
            ip_addresses: ([.NetworkSettings.Networks // {} | to_entries[] | .key + "=" + .value.IPAddress] | join("\n")),
            platform: (.Platform // "linux"),
            hostname: .Config.Hostname,
            working_dir: .Config.WorkingDir,
            restart_policy: .HostConfig.RestartPolicy.Name,
            compose_project: (.Config.Labels["com.docker.compose.project"] // ""),
            compose_service: (.Config.Labels["com.docker.compose.service"] // ""),
            compose_dir: (.Config.Labels["com.docker.compose.project.working_dir"] // "")
        }' 2>/dev/null)

    [[ -z "$full_json" ]] && { _api_error 500 "Failed to parse container data"; return; }

    _api_success "$full_json"
}

# GET /containers/{container}/stats — Live CPU, memory, network and block I/O of a container
handle_container_stats() {
    local name="$1"

    if ! docker inspect "$name" >/dev/null 2>&1; then
        _api_error 404 "Container not found: $name"
        return
    fi

    local stats_line
    stats_line=$(docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}|{{.BlockIO}}|{{.PIDs}}' "$name" 2>/dev/null)

    IFS='|' read -r cpu mem_usage mem_perc net_io block_io pids <<< "$stats_line"

    # Strip % signs and whitespace for numeric fields
    cpu="${cpu%%%*}"; cpu="${cpu// /}"
    mem_perc="${mem_perc%%%*}"; mem_perc="${mem_perc// /}"
    pids="${pids// /}"
    # Default to 0 if empty or --
    [[ -z "$cpu" || "$cpu" == "--" ]] && cpu="0"
    [[ -z "$mem_perc" || "$mem_perc" == "--" ]] && mem_perc="0"
    [[ -z "$pids" || "$pids" == "--" ]] && pids="0"

    _api_success "{\"container\": \"$(_api_json_escape "$name")\", \"cpu_percent\": $cpu, \"memory_usage\": \"$(_api_json_escape "$mem_usage")\", \"memory_percent\": $mem_perc, \"network_io\": \"$(_api_json_escape "$net_io")\", \"block_io\": \"$(_api_json_escape "$block_io")\", \"pids\": $pids}"
}

# GET /containers/{container}/processes — Process list inside a container
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

# GET /config — Effective configuration (secrets masked)
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
    config+="\"docker_compose_version\": \"$(_api_json_escape "${DOCKER_COMPOSE_VERSION:-auto}")\","
    config+="\"docker_timeout\": ${DOCKER_TIMEOUT:-120},"
    config+="\"stack_start_timeout\": ${STACK_START_TIMEOUT:-300},"
    config+="\"force_recreate\": ${FORCE_RECREATE:-false},"
    config+="\"remove_orphaned_containers\": ${REMOVE_ORPHANED_CONTAINERS:-true},"
    config+="\"max_parallel_operations\": ${MAX_PARALLEL_OPERATIONS:-3},"
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
    config+="\"log_retention_days\": ${LOG_RETENTION_DAYS:-30},"
    config+="\"enable_structured_logging\": ${ENABLE_STRUCTURED_LOGGING:-false},"
    # Image Updates
    config+="\"aggressive_image_prune\": ${AGGRESSIVE_IMAGE_PRUNE:-false},"
    config+="\"update_notification\": ${UPDATE_NOTIFICATION:-true},"
    # Notifications
    config+="\"ntfy_configured\": $([[ -n "${NTFY_URL:-}" ]] && echo true || echo false),"
    config+="\"discord_configured\": $(_discord_webhook >/dev/null 2>&1 && echo true || echo false),"
    config+="\"discord_webhook_hint\": \"$(_api_json_escape "$( _u=$(_discord_webhook 2>/dev/null) && printf '…%s' "${_u: -6}" )")\","
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
    config+="\"api_ip_whitelist\": \"$(_api_json_escape "${API_IP_WHITELIST:-}")\","
    config+="\"api_max_login_attempts\": ${API_MAX_LOGIN_ATTEMPTS:-5},"
    config+="\"api_lockout_duration\": ${API_LOCKOUT_DURATION:-900},"
    config+="\"api_tls_enabled\": ${API_TLS_ENABLED:-false},"
    config+="\"api_behind_tls_proxy\": ${API_BEHIND_TLS_PROXY:-false},"
    config+="\"api_invite_expiry\": ${API_INVITE_EXPIRY:-604800},"
    config+="\"api_max_body_size\": ${API_MAX_BODY_SIZE:-1048576},"
    config+="\"terminal_session_expiry\": ${TERMINAL_SESSION_EXPIRY:-14400},"
    # Traefik/DNS (tokens excluded)
    config+="\"traefik_domain\": \"$(_api_json_escape "${TRAEFIK_DOMAIN:-}")\","
    config+="\"traefik_acme_email\": \"$(_api_json_escape "${TRAEFIK_ACME_EMAIL:-}")\","
    config+="\"traefik_trusted_lan\": \"$(_api_json_escape "${TRAEFIK_TRUSTED_LAN:-}")\","
    config+="\"cf_dns_api_token_set\": $([[ -n "$(_find_cf_token)" ]] && echo true || echo false),"
    config+="\"ddns_enabled\": ${DDNS_ENABLED:-false},"
    config+="\"ddns_interval\": ${DDNS_INTERVAL:-300},"
    config+="\"ddns_subdomains\": \"$(_api_json_escape "${DDNS_SUBDOMAINS:-@}")\","
    # Health
    config+="\"enable_post_startup_health_check\": ${ENABLE_POST_STARTUP_HEALTH_CHECK:-true},"
    config+="\"health_check_delay\": ${HEALTH_CHECK_DELAY:-10},"
    config+="\"critical_containers\": \"$(_api_json_escape "${CRITICAL_CONTAINERS:-}")\","
    config+="\"important_containers\": \"$(_api_json_escape "${IMPORTANT_CONTAINERS:-}")\","
    # Features
    config+="\"metrics_enabled\": ${METRICS_ENABLED:-true},"
    config+="\"metrics_collect_interval\": ${METRICS_COLLECT_INTERVAL:-60},"
    config+="\"metrics_retention_days\": ${METRICS_RETENTION_DAYS:-7},"
    config+="\"include_resource_metrics\": ${INCLUDE_RESOURCE_METRICS:-true},"
    config+="\"rollback_enabled\": ${ROLLBACK_ENABLED:-true},"
    config+="\"scheduler_enabled\": ${SCHEDULER_ENABLED:-true},"
    config+="\"plugins_enabled\": ${PLUGINS_ENABLED:-true},"
    config+="\"plugins_hooks_enabled\": ${PLUGINS_HOOKS_ENABLED:-true},"
    config+="\"health_score_enabled\": ${HEALTH_SCORE_ENABLED:-true},"
    config+="\"rollback_max_snapshots\": ${ROLLBACK_MAX_SNAPSHOTS:-10},"
    config+="\"secrets_encryption\": ${SECRETS_ENCRYPTION:-true},"
    config+="\"scheduler_check_interval\": ${SCHEDULER_CHECK_INTERVAL:-60},"
    # Dashboard
    config+="\"portainer_url\": \"$(_api_json_escape "${PORTAINER_URL:-}")\","
    config+="\"dashboard_icon_url\": \"$(_api_json_escape "${DASHBOARD_ICON_URL:-}")\","
    # Backup
    config+="\"backup_source_dir\": \"$(_api_json_escape "${BACKUP_SOURCE_DIR:-}")\","
    config+="\"backup_dest_dir\": \"$(_api_json_escape "${BACKUP_DEST_DIR:-}")\","
    config+="\"backup_retention_count\": ${BACKUP_RETENTION_COUNT:-7}"
    config+="}"

    _api_success "$config"
}

# GET /system — Host resources: CPU, memory, uptime, kernel
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
    # Hypervisor or container the host runs in ("none" = bare metal)
    # systemd-detect-virt exits 1 on bare metal while still printing "none"
    local virt
    virt=$(systemd-detect-virt 2>/dev/null) || true
    [[ -n "$virt" ]] || virt="unknown"
    # QEMU guest agent, for Proxmox/KVM guests: the package, the daemon, and the
    # virtio channel the hypervisor talks through (the VM's "QEMU Guest Agent" option)
    local ga_installed=false ga_active=false ga_channel=false
    if command -v qemu-ga >/dev/null 2>&1 || [[ -x /usr/sbin/qemu-ga || -x /usr/bin/qemu-ga || -x /usr/local/sbin/qemu-ga ]]; then ga_installed=true; fi
    pgrep -x qemu-ga >/dev/null 2>&1 && ga_active=true
    [[ -e /dev/virtio-ports/org.qemu.guest_agent.0 ]] && ga_channel=true

    _api_success "{\"hostname\": \"$(_api_json_escape "$(hostname)")\", \"virtualization\": \"$(_api_json_escape "$virt")\", \"guest_agent\": {\"installed\": $ga_installed, \"active\": $ga_active, \"channel\": $ga_channel}, \"kernel\": \"$(_api_json_escape "$kernel_version")\", \"cpu_count\": $cpu_count, \"memory_total_mb\": $mem_total_mb, \"swap_total_mb\": $swap_total_mb, \"docker_version\": \"$docker_version\", \"docker_disk_usage\": $df_json}"
}

# GET /disks — Mounted filesystems and their usage
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

# GET /networks — Docker networks with connected containers
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

# GET /volumes — Docker volumes
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

# POST /networks — Create a Docker network {name, driver, subnet, gateway, ip_range, internal, attachable, ipv6, labels}
handle_create_network() {
    local body="$1"
    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for network creation"
        return
    fi

    local name driver
    name=$(printf '%s' "$body" | jq -r '.name // empty' 2>/dev/null)
    driver=$(printf '%s' "$body" | jq -r '.driver // "bridge"' 2>/dev/null)

    if [[ -z "$name" ]]; then
        _api_error 400 "Network name is required"
        return
    fi

    # Validate name (alphanumeric, hyphens, underscores)
    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        _api_error 400 "Invalid network name. Use alphanumeric characters, hyphens, underscores, and dots."
        return
    fi

    # Driver, IPAM, internal/attachable/ipv6 and labels: validated in one place
    local -a flags=()
    local flag_err
    if ! flag_err=$(_network_create_flags "$body" 2>&1 >/dev/null); then
        _api_error 400 "${flag_err:-Invalid network options}"
        return
    fi
    mapfile -t flags < <(_network_create_flags "$body" 2>/dev/null)

    # Check if network already exists
    if docker network inspect "$name" >/dev/null 2>&1; then
        _api_error 409 "Network '$name' already exists"
        return
    fi

    local -a cmd=(docker network create "${flags[@]}" -- "$name")

    local output
    output=$("${cmd[@]}" 2>&1) || {
        _api_error 500 "Failed to create network: $(_api_json_escape "$output")"
        return
    }

    _api_success "{\"success\": true, \"name\": \"$(_api_json_escape "$name")\", \"driver\": \"$(_api_json_escape "$driver")\", \"message\": \"Network '$name' created successfully\"}"
}

# POST /networks/{network}/delete — Remove a Docker network
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

# POST /networks/{network}/connect — Connect a container to a network
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

# POST /networks/{network}/disconnect — Disconnect a container from a network
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

# Turn a network request body into `docker network create` flags, one per line.
# Validates every value; on a bad one prints the reason on stderr and returns 1.
# Body: {driver, subnet, gateway, ip_range, internal, attachable, ipv6, labels{}}
_network_create_flags() {
    local body="${1:-{\}}"
    local driver subnet gateway ip_range internal attachable ipv6
    driver=$(printf '%s' "$body" | jq -r '.driver // "bridge"' 2>/dev/null) || driver=bridge
    subnet=$(printf '%s' "$body" | jq -r '.subnet // empty' 2>/dev/null)
    gateway=$(printf '%s' "$body" | jq -r '.gateway // empty' 2>/dev/null)
    ip_range=$(printf '%s' "$body" | jq -r '.ip_range // empty' 2>/dev/null)
    internal=$(printf '%s' "$body" | jq -r '.internal // false' 2>/dev/null)
    attachable=$(printf '%s' "$body" | jq -r '.attachable // false' 2>/dev/null)
    ipv6=$(printf '%s' "$body" | jq -r '.ipv6 // false' 2>/dev/null)
    case "$driver" in
        bridge|host|overlay|macvlan|ipvlan|none) ;;
        *) echo "Invalid network driver. Allowed: bridge, host, overlay, macvlan, ipvlan, none" >&2; return 1 ;;
    esac
    local cidr4='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' cidr6='^[0-9a-fA-F:]+/[0-9]+$' ip4='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' ip6='^[0-9a-fA-F:]+$'
    if [[ -n "$subnet" && ! "$subnet" =~ $cidr4 && ! "$subnet" =~ $cidr6 ]]; then
        echo "Invalid subnet format. Use CIDR notation (e.g. 172.20.0.0/16)" >&2; return 1
    fi
    if [[ -n "$gateway" && ! "$gateway" =~ $ip4 && ! "$gateway" =~ $ip6 ]]; then
        echo "Invalid gateway format. Use an IP address (e.g. 172.20.0.1)" >&2; return 1
    fi
    if [[ -n "$ip_range" && ! "$ip_range" =~ $cidr4 && ! "$ip_range" =~ $cidr6 ]]; then
        echo "Invalid IP range. Use CIDR notation (e.g. 172.20.5.0/24)" >&2; return 1
    fi
    if [[ -z "$subnet" && ( -n "$gateway" || -n "$ip_range" ) ]]; then
        echo "A gateway or IP range needs a subnet" >&2; return 1
    fi
    printf '%s\n' --driver "$driver"
    [[ -n "$subnet" ]] && printf '%s\n' --subnet "$subnet"
    [[ -n "$gateway" ]] && printf '%s\n' --gateway "$gateway"
    [[ -n "$ip_range" ]] && printf '%s\n' --ip-range "$ip_range"
    [[ "$internal" == "true" ]] && printf '%s\n' --internal
    [[ "$attachable" == "true" ]] && printf '%s\n' --attachable
    [[ "$ipv6" == "true" ]] && printf '%s\n' --ipv6
    local k v
    while IFS=$'\t' read -r k v; do
        [[ -n "$k" ]] || continue
        if [[ ! "$k" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ || ${#v} -gt 512 ]]; then
            echo "Invalid label: $k" >&2; return 1
        fi
        printf '%s\n' --label "$k=$v"
    done < <(printf '%s' "$body" | jq -r '(.labels // {}) | to_entries[] | select(.value | type == "string") | select(.value | test("\n") | not) | "\(.key)\t\(.value)"' 2>/dev/null)
    return 0
}

# The request body that would recreate a network as `docker network inspect` shows it
_network_body_from_inspect() {
    printf '%s' "$1" | jq -c '.[0] | {driver: (.Driver // "bridge"), subnet: (.IPAM.Config[0].Subnet // ""), gateway: (.IPAM.Config[0].Gateway // ""), ip_range: (.IPAM.Config[0].IPRange // ""), internal: (.Internal // false), attachable: (.Attachable // false), ipv6: (.EnableIPv6 // false), labels: (.Labels // {})}' 2>/dev/null
}

# POST /networks/{network}/recreate — Rebuild a network with new settings and reconnect its containers
handle_network_recreate() {
    local name="$1" body="${2:-{\}}"

    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi
    if [[ "$name" == "bridge" || "$name" == "host" || "$name" == "none" ]]; then
        _api_error 403 "Built-in network '$name' cannot be changed"
        return
    fi
    local inspect_json
    if ! inspect_json=$(docker network inspect "$name" 2>/dev/null) || [[ -z "$inspect_json" ]]; then
        _api_error 404 "Network '$name' not found"
        return
    fi
    printf '%s' "$body" | jq -e 'type == "object"' >/dev/null 2>&1 || { _api_error 400 "Request body must be a JSON object"; return; }

    # Compose ownership labels survive unless the request replaces them, so the
    # stack that owns the network still recognises it on its next `up`
    local merged_body
    merged_body=$(printf '%s' "$inspect_json" | jq -c --argjson req "$body" \
        '(.[0].Labels // {} | with_entries(select(.key | startswith("com.docker.compose.")))) as $keep
         | $req + {labels: ($keep + ($req.labels // {}))}' 2>/dev/null) || merged_body="$body"

    local -a flags=() old_flags=()
    local flag_err
    if ! flag_err=$(_network_create_flags "$merged_body" 2>&1 >/dev/null); then
        _api_error 400 "${flag_err:-Invalid network options}"
        return
    fi
    mapfile -t flags < <(_network_create_flags "$merged_body" 2>/dev/null)
    # The old definition, for putting things back if the new one is refused
    mapfile -t old_flags < <(_network_create_flags "$(_network_body_from_inspect "$inspect_json")" 2>/dev/null)

    local -a members=()
    mapfile -t members < <(printf '%s' "$inspect_json" | jq -r '.[0].Containers // {} | to_entries[] | .value.Name' 2>/dev/null)

    local member back output
    local -a detached=()
    for member in "${members[@]}"; do
        [[ -n "$member" ]] || continue
        if output=$(docker network disconnect -f -- "$name" "$member" 2>&1); then
            detached+=("$member")
        else
            for back in "${detached[@]}"; do docker network connect -- "$name" "$back" >/dev/null 2>&1 || true; done
            _api_error 500 "Could not disconnect $member from '$name': $(_api_json_escape "$output")"
            return
        fi
    done

    if ! output=$(docker network rm -- "$name" 2>&1); then
        for back in "${detached[@]}"; do docker network connect -- "$name" "$back" >/dev/null 2>&1 || true; done
        _api_error 500 "Could not remove '$name': $(_api_json_escape "$output")"
        return
    fi

    local new_id
    if ! new_id=$(docker network create "${flags[@]}" -- "$name" 2>&1); then
        local create_err="$new_id"
        # Put the old network back so nothing stays detached
        if [[ ${#old_flags[@]} -gt 0 ]] && docker network create "${old_flags[@]}" -- "$name" >/dev/null 2>&1; then
            for back in "${detached[@]}"; do docker network connect -- "$name" "$back" >/dev/null 2>&1 || true; done
            _api_error 400 "Docker refused the new settings, the network was restored: $(_api_json_escape "$create_err")"
        else
            _api_error 500 "Docker refused the new settings and the old network could not be restored: $(_api_json_escape "$create_err")"
        fi
        return
    fi

    local -a rc_ok=() rc_failed=()
    for back in "${detached[@]}"; do
        if docker network connect -- "$name" "$back" >/dev/null 2>&1; then rc_ok+=("$back"); else rc_failed+=("$back"); fi
    done
    local rc_json fl_json
    rc_json=$(printf '%s\n' "${rc_ok[@]}" | jq -R . | jq -sc 'map(select(length > 0))')
    fl_json=$(printf '%s\n' "${rc_failed[@]}" | jq -R . | jq -sc 'map(select(length > 0))')
    _audit_log "network.recreate" "Rebuilt network '$name': ${#rc_ok[@]} reconnected, ${#rc_failed[@]} failed" 2>/dev/null || true
    _api_success "{\"success\": true, \"name\": \"$(_api_json_escape "$name")\", \"id\": \"$(_api_json_escape "${new_id:0:12}")\", \"reconnected\": $rc_json, \"failed\": $fl_json, \"message\": \"Network '$name' rebuilt; ${#rc_ok[@]} container(s) reconnected${rc_failed[*]:+, ${#rc_failed[@]} could not be reconnected}\"}"
}

# GET /networks/{network} — Network detail with its members
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

    local base_json extra_json
    base_json="{\"id\": \"$(_api_json_escape "$id")\", \"name\": \"$(_api_json_escape "$name")\", \"driver\": \"$(_api_json_escape "$driver")\", \"scope\": \"$(_api_json_escape "$scope")\", \"internal\": $internal, \"subnet\": \"$(_api_json_escape "$ipam_subnet")\", \"gateway\": \"$(_api_json_escape "$ipam_gateway")\", \"containers\": $ce_json}"
    # What the edit form needs to rebuild the network: attachable, IPv6, IP range, labels, owner
    extra_json=$(printf '%s' "$inspect_json" | jq -c '.[0] | {attachable: (.Attachable // false), ipv6: (.EnableIPv6 // false), ip_range: (.IPAM.Config[0].IPRange // ""), labels: (.Labels // {}), created: (.Created // ""), compose_project: (.Labels["com.docker.compose.project"] // "")}' 2>/dev/null) || extra_json='{}'
    _api_success "$(printf '%s' "$base_json" | jq -c --argjson e "$extra_json" '. + $e' 2>/dev/null || printf '%s' "$base_json")"
}

# POST /volumes/{volume}/delete — Remove a Docker volume
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

# GET /logs — Tail of the framework log
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

# GET /logs/stats — Log file size and per-level counts
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

# GET /logs/archives — Rotated log archives
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

# GET /events — Recent Docker events
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
    local client_ip="${CLIENT_IP:-unknown}"
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

    local client_ip="${CLIENT_IP:-unknown}"
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
    local client_ip="${CLIENT_IP:-unknown}"
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

    local client_ip="${CLIENT_IP:-unknown}"
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
    local client_ip="${CLIENT_IP:-unknown}"
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

    local client_ip="${CLIENT_IP:-unknown}"
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

    # A missing or dead token is a 401, not a 200 with valid:false — clients
    # that only check the status (the login page, server profiles) used to
    # read the 200 as "already signed in" and never sent the login request.
    if [[ -z "$token" ]]; then
        _api_error 401 "No token provided"
        return
    fi

    if _api_validate_token "$token"; then
        _api_success "{\"valid\": true, \"username\": \"$(_api_json_escape "$AUTH_USERNAME")\", \"role\": \"$(_api_json_escape "$AUTH_ROLE")\"}"
    else
        _api_error 401 "Token is invalid or expired"
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

    # Strip sensitive fields (password_hash, salt)
    local safe_users
    safe_users=$(echo "$users" | jq '[.[] | {username: .username, role: .role, created_at: .created_at}]' 2>/dev/null)
    _api_success "{\"total\": $(echo "$safe_users" | jq 'length' 2>/dev/null || echo 0), \"users\": $safe_users}"
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
    target_username=$(echo "$body" | jq -r '.username // empty' 2>/dev/null)

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

    local client_ip="${CLIENT_IP:-unknown}"
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
        _api_audit_log "${CLIENT_IP:-unknown}" "TOTP_ENABLED" "$AUTH_USERNAME" "2FA enabled"
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
    _api_audit_log "${CLIENT_IP:-unknown}" "TOTP_DISABLED" "$AUTH_USERNAME" "2FA disabled"
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

        # Clean up TOTP attempt tracking on success
        sed -i "/^${totp_token:0:16}$/d" "$API_AUTH_DIR/.totp-attempts" 2>/dev/null

        _api_audit_log "${CLIENT_IP:-unknown}" "TOTP_LOGIN_OK" "$username" "2FA verified"
        _api_success "{\"success\": true, \"token\": \"$real_token\", \"username\": \"$(_api_json_escape "$username")\", \"role\": \"$(_api_json_escape "$role")\"}"
    else
        _api_audit_log "${CLIENT_IP:-unknown}" "TOTP_LOGIN_FAIL" "$username" "Invalid 2FA code"

        # Track failed TOTP attempts — revoke token after 5 failures
        local _totp_attempts_file="$API_AUTH_DIR/.totp-attempts"
        local _totp_key="${totp_token:0:16}"
        local _totp_fails=0
        if [[ -f "$_totp_attempts_file" ]]; then
            _totp_fails=$(grep -c "^${_totp_key}$" "$_totp_attempts_file" 2>/dev/null) || _totp_fails=0
        fi
        touch "$_totp_attempts_file" 2>/dev/null
        chmod 600 "$_totp_attempts_file" 2>/dev/null
        echo "$_totp_key" >> "$_totp_attempts_file"
        _totp_fails=$(( _totp_fails + 1 ))

        if [[ "$_totp_fails" -ge 5 ]]; then
            # Revoke the TOTP pending token
            local new_tokens
            new_tokens=$(echo "$tokens" | jq --arg t "$totp_token" '[.[] | select(.token != $t)]' 2>/dev/null)
            _api_write_auth_file "tokens.json" "$new_tokens"
            _api_audit_log "${CLIENT_IP:-unknown}" "TOTP_REVOKED" "$username" "TOTP token revoked after 5 failed attempts"
            _api_error 401 "Too many failed TOTP attempts. Please log in again."
            return
        fi

        _api_error 401 "Invalid TOTP code"
        return
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

    local client_ip="${CLIENT_IP:-unknown}"
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
    target_username=$(echo "$body" | jq -r '.username // empty' 2>/dev/null)

    if [[ -z "$target_username" ]]; then
        _api_error 400 "Missing required field: username"
        return
    fi

    _api_revoke_user_tokens "$target_username"

    local client_ip="${CLIENT_IP:-unknown}"
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

        local client_ip="${CLIENT_IP:-unknown}"
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

    local client_ip="${CLIENT_IP:-unknown}"
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
        # Only DCS stacks are torn down — never other containers on this host —
        # and core-infrastructure (the dashboard itself) keeps running so the
        # Setup Wizard can be reached afterwards. Their named volumes go with
        # them (App-Data is removed below) and the images they used are
        # deleted when nothing else still uses them.
        local stacks_dir="$BASE_DIR/Stacks"
        if command -v docker >/dev/null 2>&1; then
            local -a _reset_images=()
            local _sd _sname _cf _ef _img _n
            for _sd in "$stacks_dir"/*/; do
                [[ -d "$_sd" ]] || continue
                _sname=$(basename "$_sd")
                [[ "$_sname" == "core-infrastructure" ]] && continue
                _cf="$_sd/docker-compose.yml"
                [[ -f "$_cf" ]] || continue
                _ef=""
                [[ -f "$_sd/.env" ]] && _ef="$_sd/.env"
                while IFS= read -r _img; do
                    [[ -n "$_img" ]] && _reset_images+=("$_img")
                done < <(_compose_with_secrets "$_cf" "$_ef" config --images 2>/dev/null || true)
                _n=$(_compose_with_secrets "$_cf" "$_ef" ps -q 2>/dev/null | grep -c . || true)
                containers_stopped=$(( containers_stopped + ${_n:-0} ))
                _compose_with_secrets "$_cf" "$_ef" down --remove-orphans --volumes --timeout 10 >/dev/null 2>&1 || true
            done
            if [[ ${#_reset_images[@]} -gt 0 ]]; then
                while IFS= read -r _img; do
                    [[ -n "$_img" ]] || continue
                    docker rmi "$_img" >/dev/null 2>&1 && images_removed=$(( images_removed + 1 ))
                done < <(printf '%s\n' "${_reset_images[@]}" | sort -u)
            fi
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
        ) </dev/null >/dev/null 2>&1 &
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
            rm -rf "$data_dir/schedules" "$data_dir/metrics" 2>/dev/null
            rm -f "$data_dir/automation-state.json" "$data_dir/metrics.jsonl" "$data_dir/plugins.json" 2>/dev/null
            echo '[]' > "$auth_dir/automations.json" 2>/dev/null
            rm -f "$auth_dir/metrics-history.jsonl" 2>/dev/null
            # Encrypted secrets and their key: a reset is a clean slate
            rm -rf "$BASE_DIR/.secrets" 2>/dev/null
            crontab -l 2>/dev/null | grep -q '# DCS-AUTO:' && crontab -l 2>/dev/null | grep -v '# DCS-AUTO:[A-Za-z0-9_]*$' | crontab - 2>/dev/null
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
        local _cf_token _cf_domain
        _cf_token=$(_find_cf_token)
        _cf_domain=$(_find_traefik_domain)
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
            ) </dev/null >/dev/null 2>&1 &
            disown
        fi
        rm -f "$auth_dir/.cf-zone-cache" "$auth_dir/cf-dns-audit.log" "$auth_dir/ddns.log" "$auth_dir/os-update-status.json" 2>/dev/null || true

        # Stop scheduler and metrics daemons if running
        for pidfile in "${BASE_DIR}/.data/metrics-collector.pid" "${BASE_DIR}/.data/scheduler.pid"; do
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

    local client_ip="${CLIENT_IP:-unknown}"
    _api_audit_log "$client_ip" "FACTORY_RESET" "${AUTH_USERNAME:-unknown}" "Factory reset performed. compose_reset=$compose_reset containers_stopped=$containers_stopped images_removed=$images_removed"

    _api_success "{\"success\": true, \"files_removed\": $removed_json, \"compose_reset\": $compose_reset, \"stacks_removed\": $stacks_removed_json, \"env_reset\": $env_reset, \"containers_stopped\": $containers_stopped, \"images_removed\": $images_removed, \"core_infrastructure_kept\": true, \"secrets_removed\": $compose_reset}"
}

# =============================================================================
# CONTAINER ACTION HANDLERS
# =============================================================================

# POST /containers/{container}/start — Start, stop, restart, recreate (Compose-managed only) or remove a container
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
            # Only Compose-managed containers can be recreated faithfully: the
            # compose labels give the project directory and service, and
            # `up --force-recreate` rebuilds the container with all of its
            # volumes, networks, ports and environment. Anything else is
            # refused rather than replaced by a bare `docker run`.
            local _proj_dir _svc_name _cfg_files
            _proj_dir=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$name" 2>/dev/null)
            _svc_name=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$name" 2>/dev/null)
            if [[ -z "$_proj_dir" ]]; then
                _cfg_files=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$name" 2>/dev/null)
                [[ -n "$_cfg_files" ]] && _proj_dir=$(dirname "${_cfg_files%%,*}")
            fi
            if [[ -z "$_proj_dir" || -z "$_svc_name" || ! -f "$_proj_dir/docker-compose.yml" ]]; then
                _api_error 400 "Container '$name' is not managed by a Compose stack, so it cannot be recreated safely. Use its stack's update action or recreate it manually."
                return
            fi
            local _rec_env=""
            [[ -f "$_proj_dir/.env" ]] && _rec_env="$_proj_dir/.env"
            output=$(_compose_with_secrets "$_proj_dir/docker-compose.yml" "$_rec_env" pull "$_svc_name" 2>&1) || true
            output+=$'\n'"$(_compose_with_secrets "$_proj_dir/docker-compose.yml" "$_rec_env" up -d --force-recreate --no-deps "$_svc_name" 2>&1)" || success=false
            ;;
        remove)   output=$(docker rm -f -- "$name" 2>&1) || success=false ;;
        *)        _api_error 400 "Unknown action: $action"; return ;;
    esac

    local escaped_output
    escaped_output=$(_api_json_escape "$output")

    _api_success "{\"container\": \"$(_api_json_escape "$name")\", \"action\": \"$action\", \"success\": $success, \"output\": \"$escaped_output\"}"
}

# Environment editing for a Compose service. The compose file is edited line by
# line so comments, order and formatting survive; only the one entry changes.
#   stdin: compose content;  args: SERVICE KEY  → prints the raw value (exit 1 if absent)
_compose_env_get() {
    awk -v svc="$1" -v key="$2" '
        /^  [A-Za-z0-9_.-]+:[ \t]*$/ { cur=$0; sub(/^  /,"",cur); sub(/:.*$/,"",cur); insvc=(cur==svc); inenv=0; next }
        /^[^ #]/ { insvc=0; inenv=0 }
        insvc && /^    environment:[ \t]*$/ { inenv=1; next }
        insvc && inenv && /^    [^ ]/ { inenv=0 }
        insvc && inenv {
            line=$0; sub(/^[ \t]+/,"",line)
            if (line ~ /^- /) {
                sub(/^- +/,"",line); q=""
                if (line ~ /^["\047]/) { q=substr(line,1,1); line=substr(line,2); sub(q "[ \t]*(#.*)?$","",line) } else { sub(/[ \t]+#.*$/,"",line) }
                eq=index(line,"="); k=(eq?substr(line,1,eq-1):line); v=(eq?substr(line,eq+1):"")
                if (k==key) { print v; found=1; exit }
            } else if (match(line, /^[A-Za-z_][A-Za-z0-9_]*[ \t]*:/)) {
                k=substr(line,1,RLENGTH-1); sub(/[ \t]+$/,"",k); v=substr(line,RLENGTH+1); sub(/^[ \t]+/,"",v)
                if (v ~ /^["\047]/) { q=substr(v,1,1); v=substr(v,2); sub(q "[ \t]*(#.*)?$","",v) } else { sub(/[ \t]+#.*$/,"",v) }
                if (k==key) { print v; found=1; exit }
            }
        }
        END { exit (found?0:1) }'
}

#   stdin: compose content;  args: SERVICE KEY VALUE MODE(set|unset) → prints the new content
#   exit 3 when the service has no block form the editor can change (flow-style environment)
_compose_env_edit() {
    awk -v svc="$1" -v key="$2" -v val="$3" -v mode="$4" '
        function q_dq(v) { gsub(/\\/,"\\\\",v); gsub(/"/,"\\\"",v); return "\"" v "\"" }
        function needs_quote(v) { return (v ~ /^[ \t]/ || v ~ /[ \t]$/ || v ~ /[ \t]#/ || v ~ /^[!&*\[\]{}|>%@`#"\047]/ || v ~ /: / || v == "") }
        function list_line(k, v,   s) { s = k "=" v; return "      - " (needs_quote(s) ? q_dq(s) : s) }
        function map_line(k, v) { return "      " k ": " ((needs_quote(v) || v ~ /^(true|false|yes|no|on|off|null|~)$/ || v ~ /^[-+.0-9]+$/ || v ~ /^0x/) ? q_dq(v) : v) }
        function emit_new() { print (style=="map" ? map_line(key,val) : list_line(key,val)); done=1 }
        function leave_env() { if (inenv && !done && mode=="set") emit_new(); inenv=0 }
        function leave_svc() { if (insvc && !done && mode=="set" && !hadenv) { print "    environment:"; emit_new() } insvc=0; inenv=0 }
        BEGIN { style="list"; done=0 }
        /^  [A-Za-z0-9_.-]+:[ \t]*$/ { leave_env(); leave_svc(); cur=$0; sub(/^  /,"",cur); sub(/:.*$/,"",cur); insvc=(cur==svc); hadenv=0; print; next }
        /^[^ #]/ { leave_env(); leave_svc(); print; next }
        insvc && /^    environment:[ \t]*$/ { inenv=1; hadenv=1; style="unknown"; print; next }
        insvc && /^    environment:[ \t]*[\[{]/ { bad=1 }
        insvc && inenv && /^    [^ ]/ { leave_env() }
        insvc && inenv {
            if ($0 ~ /^[ \t]*$/ || $0 ~ /^[ \t]*#/) { print; next }
            line=$0; sub(/^[ \t]+/,"",line)
            if (style=="unknown") style = (line ~ /^- / ? "list" : "map")
            if (line ~ /^- /) {
                body=line; sub(/^- +/,"",body); q=""
                if (body ~ /^["\047]/) { q=substr(body,1,1); body=substr(body,2); sub(q "[ \t]*(#.*)?$","",body) } else { sub(/[ \t]+#.*$/,"",body) }
                eq=index(body,"="); k=(eq?substr(body,1,eq-1):body)
                if (k==key) { if (mode=="set") emit_new(); else done=1; next }
            } else if (match(line, /^[A-Za-z_][A-Za-z0-9_]*[ \t]*:/)) {
                k=substr(line,1,RLENGTH-1); sub(/[ \t]+$/,"",k)
                if (k==key) { if (mode=="set") emit_new(); else done=1; next }
            }
            print; next
        }
        { print }
        END { leave_env(); leave_svc(); if (bad) exit 3 }'
}

# Set KEY=VALUE in a Compose .env file (replace the line or append); quotes when needed
# _envfile_set FILE KEY VALUE [bash|compose] — set one variable, quoting what
# the file's reader would misread (compose for stack files, bash for the root
# .env). Backslashes reach awk through ENVIRON, which does not interpret them.
_envfile_set() {
    local file="$1" key="$2" val="$3" mode="${4:-compose}" out
    val=$(envfile_quote "$val" "$mode")
    [[ -f "$file" ]] || : > "$file"
    out=$(K="$key" V="$val" awk 'BEGIN{done=0; k=ENVIRON["K"]; v=ENVIRON["V"]} $0 ~ ("^(export[ \t]+)?" k "[ \t]*=") && !done { print k "=" v; done=1; next } { print } END { if (!done) print k "=" v }' "$file") || return 1
    printf '%s\n' "$out" > "$file.tmp.$$" || { rm -f "$file.tmp.$$"; return 1; }
    chmod --reference="$file" "$file.tmp.$$" 2>/dev/null
    mv -f "$file.tmp.$$" "$file"
}

# POST /containers/{container}/env — Change a Compose-managed container's environment in its stack {set{}, unset[], recreate}
handle_container_env_update() {
    local name="$1" body="${2:-{\}}"

    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi
    if ! docker inspect "$name" >/dev/null 2>&1; then
        _api_error 404 "Container not found: $name"
        return
    fi
    printf '%s' "$body" | jq -e 'type == "object"' >/dev/null 2>&1 || { _api_error 400 "Request body must be a JSON object"; return; }

    local recreate
    recreate=$(printf '%s' "$body" | jq -r 'if .recreate == false then "false" else "true" end' 2>/dev/null)
    local -a set_keys=() unset_keys=()
    mapfile -t set_keys < <(printf '%s' "$body" | jq -r '(.set // {}) | to_entries[] | select(.value | type == "string") | .key' 2>/dev/null)
    mapfile -t unset_keys < <(printf '%s' "$body" | jq -r '(.unset // []) | .[] | select(type == "string")' 2>/dev/null)
    if [[ ${#set_keys[@]} -eq 0 && ${#unset_keys[@]} -eq 0 ]]; then
        _api_error 400 "Nothing to change: pass set {KEY: value} and/or unset [KEY]"
        return
    fi
    local k
    for k in "${set_keys[@]}" "${unset_keys[@]}"; do
        [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { _api_error 400 "Invalid variable name: $k"; return; }
    done

    # The stack and service that own the container (Compose labels)
    local proj_dir svc_name
    proj_dir=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$name" 2>/dev/null)
    svc_name=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$name" 2>/dev/null)
    if [[ -z "$proj_dir" || -z "$svc_name" || ! -f "$proj_dir/docker-compose.yml" ]]; then
        _api_error 400 "Container '$name' is not managed by a Compose stack, so its environment lives nowhere DCS can edit"
        return
    fi
    if [[ "$proj_dir" != "$COMPOSE_DIR/"* ]]; then
        _api_error 400 "Container '$name' belongs to a Compose project outside this installation"
        return
    fi
    local stack compose_file env_file
    stack=$(basename "$proj_dir")
    compose_file="$proj_dir/docker-compose.yml"
    env_file="$proj_dir/.env"

    local content original
    content=$(cat "$compose_file") || { _api_error 500 "Cannot read the stack's compose file"; return; }
    original="$content"

    local -a envedit_compose=() envedit_env=() envedit_removed=()
    local val raw
    for k in "${set_keys[@]}"; do
        val=$(printf '%s' "$body" | jq -r --arg k "$k" '.set[$k]' 2>/dev/null)
        [[ "$val" == *$'\n'* ]] && { _api_error 400 "Values cannot contain line breaks ($k)"; return; }
        # A value that is a plain ${VAR} reference lives in the stack .env: change it there
        if raw=$(printf '%s\n' "$content" | _compose_env_get "$svc_name" "$k") && [[ "$raw" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)(:?-[^}]*)?\}$ ]]; then
            local var="${BASH_REMATCH[1]}"
            _envfile_set "$env_file" "$var" "$val" || { _api_error 500 "Could not write $var to the stack .env"; return; }
            envedit_env+=("$k=$var")
            continue
        fi
        if ! content=$(printf '%s\n' "$content" | _compose_env_edit "$svc_name" "$k" "$val" set); then
            _api_error 422 "The environment of $svc_name is written in a form this editor cannot change (flow style); edit the compose file instead"
            return
        fi
        envedit_compose+=("$k")
    done
    for k in "${unset_keys[@]}"; do
        content=$(printf '%s\n' "$content" | _compose_env_edit "$svc_name" "$k" "" unset) || { _api_error 422 "Could not remove $k"; return; }
        envedit_removed+=("$k")
    done

    if [[ "$content" != "$original" ]]; then
        # Same guards as a compose save: policy scan, validation, backup, version, atomic write
        local _scan_mode="strict"
        [[ -f "$proj_dir/.dcs-trusted-templates" ]] && _scan_mode="deploy"
        _api_scan_compose_security "$content" "environment change for $stack" "$_scan_mode" || return
        local tmpfile validation_output
        tmpfile=$(mktemp /tmp/dcs-env-edit-XXXXXX.yml)
        printf '%s\n' "$content" > "$tmpfile"
        local env_args=()
        [[ -f "$env_file" ]] && env_args=(--env-file "$env_file")
        validation_output=$(
            eval "$(_secrets_env_exports "$tmpfile")"
            $DOCKER_COMPOSE_CMD -f "$tmpfile" "${env_args[@]}" config 2>&1
        ) || { rm -f "$tmpfile"; _api_error 422 "The change does not validate: $(_api_json_escape "$(printf '%s' "$validation_output" | head -3)")"; return; }
        rm -f "$tmpfile"
        cp "$compose_file" "${compose_file}.bak" 2>/dev/null
        _save_compose_version "$stack"
        local tmpwrite="${compose_file}.tmp.$$"
        printf '%s\n' "$content" > "$tmpwrite" 2>/dev/null && mv -f "$tmpwrite" "$compose_file" 2>/dev/null || {
            rm -f "$tmpwrite" 2>/dev/null
            _api_error 500 "Failed to write the compose file"
            return
        }
    fi

    local output="" success=true recreated=false
    if [[ "$recreate" == "true" ]]; then
        local _rec_env=""
        [[ -f "$env_file" ]] && _rec_env="$env_file"
        output=$(_compose_with_secrets "$compose_file" "$_rec_env" up -d --force-recreate --no-deps "$svc_name" 2>&1) || success=false
        [[ "$success" == "true" ]] && recreated=true
    fi

    local cc ec rm_json
    cc=$(printf '%s\n' "${envedit_compose[@]}" | jq -R . | jq -sc 'map(select(length > 0))')
    ec=$(printf '%s\n' "${envedit_env[@]}" | jq -R . | jq -sc 'map(select(length > 0))')
    rm_json=$(printf '%s\n' "${envedit_removed[@]}" | jq -R . | jq -sc 'map(select(length > 0))')
    _audit_log "container.env" "Changed environment of $svc_name in $stack: ${#envedit_compose[@]} in compose, ${#envedit_env[@]} in .env, ${#envedit_removed[@]} removed" 2>/dev/null || true
    _api_success "{\"success\": $success, \"container\": \"$(_api_json_escape "$name")\", \"stack\": \"$(_api_json_escape "$stack")\", \"service\": \"$(_api_json_escape "$svc_name")\", \"compose_changed\": $cc, \"env_changed\": $ec, \"removed\": $rm_json, \"recreated\": $recreated, \"output\": \"$(_api_json_escape "$output")\"}"
}

# POST /containers/{container}/exec — Run a command inside a container (30 s limit)
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

    # Execute the command: no TTY (this is a request/response API), stdin
    # closed so interactive programs exit instead of hanging, 30-second
    # limit, output capped at 1 MB. Containers without sh fall back to bash,
    # then to running the words directly.
    local output=""
    local exit_code=0
    output=$(timeout 30 docker exec "$name" sh -c "$command" </dev/null 2>&1 | head -c 1048576) || exit_code=$?
    if [[ ( $exit_code -eq 126 || $exit_code -eq 127 ) && "$output" == *'"sh": executable file not found'* ]]; then
        exit_code=0
        output=$(timeout 30 docker exec "$name" bash -c "$command" </dev/null 2>&1 | head -c 1048576) || exit_code=$?
        if [[ ( $exit_code -eq 126 || $exit_code -eq 127 ) && "$output" == *'"bash": executable file not found'* ]]; then
            exit_code=0
            set -f
            # shellcheck disable=SC2086
            output=$(timeout 30 docker exec "$name" $command </dev/null 2>&1 | head -c 1048576) || exit_code=$?
            set +f
        fi
    fi

    # Handle timeout specifically
    if [[ $exit_code -eq 124 ]]; then
        output="${output:+$output
}Command timed out after 30 seconds (commands run without a terminal; interactive programs cannot be used here)"
    fi

    local success=true
    [[ $exit_code -ne 0 ]] && success=false

    local escaped_output escaped_command
    escaped_output=$(_api_json_escape "$output")
    escaped_command=$(_api_json_escape "$command")

    _api_success "{\"container\": \"$(_api_json_escape "$name")\", \"command\": \"$escaped_command\", \"exit_code\": $exit_code, \"output\": \"$escaped_output\", \"success\": $success}"
}

# GET /containers/{container}/logs — Recent log lines of a container
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

# POST /maintenance/prune — Prune stopped containers, dangling images and unused networks
handle_maintenance_prune() {
    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    local output=""
    local success=true

    output=$(docker system prune -f 2>&1) || success=false
    local escaped
    escaped=$(_api_json_escape "$output")

    _api_success "{\"action\": \"prune\", \"success\": $success, \"output\": \"$escaped\"}"
}

# POST /maintenance/image-prune — Prune unused images
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

# GET /maintenance/report — Docker disk usage report
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

# GET /maintenance/orphans — Containers, volumes and networks no stack references
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

# GET /maintenance/disk — Per-stack App-Data sizes, Docker disk usage and volume sizes
handle_maintenance_disk() {
    # Scan per-stack App-Data directories (DCS stores data inside each stack dir)
    local -a stack_sizes=()
    local total_bytes=0
    for _stack_dir in "$COMPOSE_DIR"/*/; do
        [[ ! -d "$_stack_dir" ]] && continue
        local stack_name
        stack_name=$(basename "$_stack_dir")
        # Each stack keeps its data in its own App-Data directory (the root .env
        # default is the relative ./App-Data); a shared absolute directory is
        # deliberately not charged to every stack.
        local _ad="$_stack_dir/App-Data"
        [[ ! -d "$_ad" ]] && continue
        local size_bytes
        size_bytes=$(du -sb "$_ad" 2>/dev/null | cut -f1)
        [[ "$size_bytes" =~ ^[0-9]+$ ]] || continue
        total_bytes=$((total_bytes + size_bytes))
        stack_sizes+=("{\"name\": \"$(_api_json_escape "$stack_name")\", \"size\": \"$(_api_fmt_bytes "$size_bytes")\", \"bytes\": $size_bytes}")
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
    [[ $total_bytes -gt 0 ]] && total_app_data=$(_api_fmt_bytes "$total_bytes")

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

    # Docker volume sizes — the daemon computes them (the API user usually cannot
    # read /var/lib/docker/volumes), one call for all volumes
    local -a vol_entries=()
    local _vols_json
    _vols_json=$(timeout 20 docker system df -v --format '{{json .Volumes}}' 2>/dev/null)
    if [[ -n "$_vols_json" ]] && jq -e 'type == "array"' <<< "$_vols_json" >/dev/null 2>&1; then
        while IFS=$'\t' read -r vname vsize; do
            [[ -z "$vname" ]] && continue
            vol_entries+=("{\"name\": \"$(_api_json_escape "$vname")\", \"size\": \"$(_api_json_escape "${vsize:-unknown}")\"}")
        done < <(jq -r '.[] | [(.Name // ""), (.Size // "unknown")] | @tsv' <<< "$_vols_json" 2>/dev/null)
    else
        while IFS= read -r vname; do
            [[ -z "$vname" ]] && continue
            vol_entries+=("{\"name\": \"$(_api_json_escape "$vname")\", \"size\": \"unknown\"}")
        done < <(docker volume ls -q 2>/dev/null)
    fi

    local vol_json
    if [[ ${#vol_entries[@]} -gt 0 ]]; then
        vol_json=$(printf '%s,' "${vol_entries[@]}")
        vol_json="[${vol_json%,}]"
    else
        vol_json="[]"
    fi

    _api_success "{\"stack_sizes\": $ss_json, \"docker_df\": $df_json, \"total_app_data\": \"$(_api_json_escape "$total_app_data")\", \"host_disk\": {\"total\": \"$disk_total\", \"used\": \"$disk_used\", \"available\": \"$disk_avail\", \"percent\": \"$disk_pct\"}, \"volumes\": $vol_json}"
}

# POST /maintenance/deep-prune — Prune everything unused, volumes included (confirmation required)
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

# POST /maintenance/log-rotate — Rotate and archive the framework log
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

    _api_success "{\"success\": true, \"message\": \"Log rotated successfully\", \"archived_as\": \"$(_api_json_escape "$archive_name")\", \"previous_size\": \"$(_api_json_escape "$log_size")\", \"previous_lines\": ${log_lines:-0}, \"purged_archives\": ${purged:-0}}"
}

# =============================================================================
# BATCH OPERATION HANDLERS (Phase 4)
# =============================================================================

# POST /batch/stacks — Start, stop or restart several stacks in dependency order
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
        done < <(printf '%s' "$body" | jq -r '.stacks[]?' 2>/dev/null)
        local _sel
        for _sel in "${selected[@]}"; do
            _api_validate_stack_name "$_sel" || return
        done
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
            start)   _stack_run_detached "start" "$stack" ;;
            stop)   _stack_run_detached "stop" "$stack" ;;
            restart)   _stack_run_detached "restart" "$stack" ;;
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

# POST /batch/update — Pull images for several stacks and recreate what changed
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
            [[ -n "$s" ]] || continue
            _api_validate_stack_name "$s" || return
            target_stacks+=("$s")
        done < <(printf '%s' "$body" | jq -r '.stacks[]?' 2>/dev/null)
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

        local pull_output stack_ok=true
        pull_output=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" pull 2>&1) || stack_ok=false

        local after_shas
        after_shas=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" images -q 2>/dev/null | sort)

        local changes_detected=false
        if [[ "$stack_ok" == "true" && "$before_shas" != "$after_shas" ]]; then
            changes_detected=true
            _compose_with_secrets "$compose_file" "$COMPOSE_DIR/$stack/.env" up -d >/dev/null 2>&1 || stack_ok=false
        fi

        results+=("{\"stack\": \"$(_api_json_escape "$stack")\", \"success\": $stack_ok, \"changes_detected\": $changes_detected, \"message\": \"$(_api_json_escape "$pull_output")\"}")
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

# GET /env — The root .env file, raw and parsed
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

# POST /env — Save the root .env file (validated as plain KEY=value data)
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

    local problem
    if ! problem=$(_api_validate_env_content "$content"); then
        _api_error 400 "Rejected .env content: $problem"
        return
    fi

    if [[ -f "$env_file" ]]; then
        cp -p "$env_file" "${env_file}.bak" 2>/dev/null
    fi

    if ! (umask 077; printf '%s\n' "${content%$'\n'}" > "${env_file}.tmp") 2>/dev/null || ! mv -f "${env_file}.tmp" "$env_file" 2>/dev/null; then
        rm -f "${env_file}.tmp" 2>/dev/null
        _api_error 500 "Failed to write .env file"
        return
    fi

    _api_success "{\"success\": true, \"message\": \"Root .env file saved successfully\"}"
}

# POST /env/validate — Validate .env content without saving it
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

    local _policy
    if ! _policy=$(_api_validate_env_content "$content"); then
        errors+=("{\"line\": 0, \"message\": \"$(_api_json_escape "Policy: $_policy")\"}")
    fi

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

# GET /backups — Backup archives in BACKUP_DEST_DIR
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

# GET /backups/status — Progress of the running backup or the last result
handle_backup_status() {
    local status_file="$API_AUTH_DIR/backup-status.json"

    local status_content=""
    [[ -f "$status_file" ]] && status_content=$(cat "$status_file" 2>/dev/null)
    if [[ -n "$status_content" ]] && jq -e . <<< "$status_content" >/dev/null 2>&1; then
        _api_success "$status_content"
    else
        _api_success "{\"status\": \"idle\", \"last_backup\": null, \"progress\": null}"
    fi
}

# GET /backups/config — Backup source, destination and retention
handle_backup_config() {
    local backup_dest="${BACKUP_DEST_DIR:-}"
    local backup_source="${BACKUP_SOURCE_DIR:-$BASE_DIR}"
    local retention="${BACKUP_RETENTION_COUNT:-5}"
    local configured=false
    [[ -n "$backup_dest" ]] && configured=true

    _api_success "{\"configured\": $configured, \"destination\": \"$(_api_json_escape "$backup_dest")\", \"source\": \"$(_api_json_escape "$backup_source")\", \"retention_count\": $retention}"
}

# POST /backups/trigger — Start a backup in the background (optionally one stack)
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
    if [[ -n "$stack_filter" ]]; then
        _api_validate_stack_name "$stack_filter" || return
    fi

    local status_file="$API_AUTH_DIR/backup-status.json"
    local backup_date
    backup_date=$(date '+%Y-%m-%d_%H%M%S')
    local backup_file="Docker-Compose-Backup-${backup_date}.tar.gz"
    local source_dir="${BACKUP_SOURCE_DIR:-$BASE_DIR}"

    local _bpid_file="$API_AUTH_DIR/backup.pid"
    if [[ -f "$_bpid_file" ]] && kill -0 "$(cat "$_bpid_file" 2>/dev/null)" 2>/dev/null; then
        _api_error 409 "A backup is already running"
        return
    fi
    local _bst
    _bst="$(date -Iseconds)"

    _backup_progress() {
        printf '{"status":"running","started_at":"%s","filename":"%s","progress":"%s","percent":%d,"stage":"%s","pid":%d}' \
            "$_bst" "$backup_file" "$1" "$2" "$3" "${_bpid:-0}" > "$status_file"
    }

    _backup_progress "Preparing backup..." 0 "prepare"

    (
        # Archives hold .env and per-stack secrets: keep everything private
        umask 077
        echo $BASHPID > "$_bpid_file"
        _bpid=$BASHPID

        local tmpdir
        if ! tmpdir=$(mktemp -d /tmp/dcs-backup-XXXXXX 2>/dev/null) || [[ -z "$tmpdir" ]]; then
            printf '{"status":"error","error":"Could not create a temporary directory","progress":null,"percent":0,"stage":"error"}' > "$status_file"
            rm -f "$_bpid_file"
            exit 1
        fi

        _backup_progress "Copying files..." 15 "copy"

        # Session tokens, rate-limit state, caches and logs are transient and
        # must not travel in a backup; accounts and encrypted secrets do.
        local -a _bx=(--exclude='.git' --exclude='node_modules' --exclude='.data' --exclude='logs'
                      --exclude='.api-auth/tokens.json' --exclude='.api-auth/terminal-sessions.json'
                      --exclude='.api-auth/rate_limits.json' --exclude='.api-auth/*.log' --exclude='.api-auth/rates'
                      --exclude='.secrets/.master-key')
        if [[ -n "$stack_filter" ]]; then
            [[ -d "$COMPOSE_DIR/$stack_filter" ]] && rsync -a "$COMPOSE_DIR/$stack_filter/" "$tmpdir/$stack_filter/" 2>/dev/null || true
            [[ -d "$APP_DATA_DIR/$stack_filter" ]] && rsync -a "$APP_DATA_DIR/$stack_filter/" "$tmpdir/App-Data/$stack_filter/" 2>/dev/null || true
        else
            rsync -a "${_bx[@]}" "$source_dir/" "$tmpdir/" 2>/dev/null || true
        fi

        _backup_progress "Files copied, creating archive..." 55 "archive"

        if tar -czf "$backup_dir/$backup_file" -C "$tmpdir" . 2>/dev/null; then
            _backup_progress "Archive created, cleaning up..." 85 "cleanup"
            rm -rf "$tmpdir"

            _backup_progress "Enforcing retention policy..." 92 "retention"

            local retention="${BACKUP_RETENTION_COUNT:-5}"
            local count
            count=$(ls -1 "$backup_dir"/Docker-Compose-Backup-*.tar.gz 2>/dev/null | wc -l)
            if [[ "$count" -gt "$retention" ]]; then
                ls -1t "$backup_dir"/Docker-Compose-Backup-*.tar.gz 2>/dev/null | tail -n "$(( count - retention ))" | xargs -r rm -f
            fi

            local final_size
            final_size=$(du -h "$backup_dir/$backup_file" 2>/dev/null | cut -f1)
            printf '{"status":"idle","last_backup":{"filename":"%s","size":"%s","timestamp":"%s"},"progress":null,"percent":100,"stage":"done"}' \
                "$backup_file" "$final_size" "$(date -Iseconds)" > "$status_file"
        else
            rm -rf "$tmpdir"
            printf '{"status":"error","error":"Archive creation failed","progress":null,"percent":0,"stage":"error"}' > "$status_file"
        fi

        rm -f "$_bpid_file"
    ) </dev/null >/dev/null 2>&1 &

    _api_success "{\"success\": true, \"message\": \"Backup started in background\", \"filename\": \"$(_api_json_escape "$backup_file")\"}"
}

# POST /backups/cancel — Kill a running backup
handle_backup_cancel() {
    local pid_file="$API_AUTH_DIR/backup.pid"
    local status_file="$API_AUTH_DIR/backup-status.json"

    if [[ ! -f "$pid_file" ]]; then
        _api_error 404 "No backup is currently running"
        return
    fi

    local pid
    pid=$(cat "$pid_file" 2>/dev/null)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        # Kill the backup process and its children (rsync, tar)
        pkill -TERM -P "$pid" 2>/dev/null || true
        kill -TERM "$pid" 2>/dev/null || true
        sleep 0.5
        pkill -KILL -P "$pid" 2>/dev/null || true
        kill -KILL "$pid" 2>/dev/null || true
        # Clean up temp dirs
        rm -rf /tmp/dcs-backup-* 2>/dev/null
        rm -f "$pid_file"
        printf '{"status":"idle","progress":null,"percent":0,"stage":"cancelled","error":"Backup cancelled by user"}' > "$status_file"
        _api_success '{"success": true, "message": "Backup cancelled"}'
    else
        rm -f "$pid_file"
        _api_error 404 "Backup process not found (may have already completed)"
    fi
}

# POST /backups/restore — Restore a backup archive (confirmation required)
handle_backup_restore() {
    local body="$1"
    local backup_dir="${BACKUP_DEST_DIR:-}"

    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for restore"
        return
    fi

    if [[ -z "$backup_dir" ]]; then
        _api_error 400 "Backup not configured. Set BACKUP_DEST_DIR in .env"
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

    # List the archive once. (Piping tar into `grep -q` would let grep exit early
    # and turn a match into a SIGPIPE failure under pipefail — the check would
    # pass exactly when it matched.)
    local _listing
    if ! _listing=$(tar -tvzf "$archive_path" 2>/dev/null); then
        _api_error 400 "Backup archive is corrupt or invalid"
        return
    fi

    # SECURITY: Check for path traversal in archive (../../ etc) before extracting
    if awk '{print $NF}' <<< "$_listing" | grep -qE '^\.\./|/\.\./|^/'; then
        _api_error 403 "Backup archive contains path traversal entries — refusing to extract"
        return
    fi

    # SECURITY: Check for symlinks in archive (symlink-following traversal attack)
    # A symlink entry pointing to /etc/cron.d followed by a file entry writes through it
    if grep -q '^l' <<< "$_listing"; then
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
    ) </dev/null >/dev/null 2>&1 &

    _api_success "{\"success\": true, \"message\": \"Restore started in background\", \"filename\": \"$(_api_json_escape "$filename")\"}"
}

# =============================================================================
# STACK CREATE / DELETE HANDLERS
# =============================================================================

# POST /stacks — Create an empty stack directory
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

# POST /stacks/{stack}/delete — Delete a stopped stack directory
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

# POST /config — Update allow-listed .env settings
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
        [REMOVE_ORPHANED_CONTAINERS]=1 [STACK_START_TIMEOUT]=1 [MAX_PARALLEL_OPERATIONS]=1
        # Logging
        [LOG_LEVEL]=1 [ENABLE_COLORS]=1 [COLOR_MODE]=1 [COLOR_THEME]=1
        [VERBOSE_MODE]=1 [ENABLE_LOG_DATE]=1 [ENABLE_MILLISECONDS]=1
        [LOG_DATE_FORMAT]=1 [ENABLE_LOG_MOOD]=1 [ENABLE_LOG_PID]=1
        [ENABLE_LOG_HOSTNAME]=1 [LOG_MAX_SIZE]=1 [LOG_BACKUP_COUNT]=1
        [LOG_RETENTION_DAYS]=1 [ENABLE_STRUCTURED_LOGGING]=1
        # Image Updates
        [AGGRESSIVE_IMAGE_PRUNE]=1 [UPDATE_NOTIFICATION]=1
        # Notifications
        [NTFY_URL]=1 [NTFY_TOPIC]=1 [NTFY_PRIORITY]=1 [NTFY_TOKEN]=1 [DISCORD_WEBHOOK_URL]=1 [UPDATE_ON_BOOT]=1 [CROWDSEC_TRUSTED_IPS]=1
        [NOTIFICATION_STACKS]=1
        # API
        [API_ENABLED]=1 [API_PORT]=1 [API_BIND]=1
        [API_AUTH_ENABLED]=1 [API_RATE_LIMIT]=1 [API_RATE_WINDOW]=1
        [API_CORS_ORIGINS]=1 [API_IP_WHITELIST]=1
        [API_TOKEN_EXPIRY]=1 [API_SINGLE_SESSION]=1
        [API_MAX_LOGIN_ATTEMPTS]=1 [API_LOCKOUT_DURATION]=1
        [API_TLS_ENABLED]=1 [API_BEHIND_TLS_PROXY]=1
        [API_INVITE_EXPIRY]=1 [API_MAX_BODY_SIZE]=1
        [TERMINAL_SESSION_EXPIRY]=1
        # Traefik/DNS
        [TRAEFIK_DOMAIN]=1 [TRAEFIK_ACME_EMAIL]=1
        [CF_DNS_API_TOKEN]=1 [DDNS_ENABLED]=1 [DDNS_INTERVAL]=1
        [TRAEFIK_TRUSTED_LAN]=1 [DDNS_SUBDOMAINS]=1
        # Health/Monitoring
        [ENABLE_POST_STARTUP_HEALTH_CHECK]=1 [HEALTH_CHECK_DELAY]=1
        [CRITICAL_CONTAINERS]=1 [IMPORTANT_CONTAINERS]=1
        # Metrics/Features
        [METRICS_ENABLED]=1 [METRICS_COLLECT_INTERVAL]=1
        [ROLLBACK_ENABLED]=1 [SCHEDULER_ENABLED]=1
        [PLUGINS_ENABLED]=1 [PLUGINS_HOOKS_ENABLED]=1
        [HEALTH_SCORE_ENABLED]=1
        [ROLLBACK_MAX_SNAPSHOTS]=1 [SECRETS_ENCRYPTION]=1 [SCHEDULER_CHECK_INTERVAL]=1
        [METRICS_RETENTION_DAYS]=1 [INCLUDE_RESOURCE_METRICS]=1
        [API_TRUSTED_PROXIES]=1 [DCS_UI_PORT]=1
        # Dashboard/General
        [PORTAINER_URL]=1 [DASHBOARD_ICON_URL]=1 [DOCKER_COMPOSE_VERSION]=1
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
        local value problem
        value=$(echo "$body" | jq -r --arg k "$key" 'if .[$k] == null then "" else .[$k] end' 2>/dev/null)
        # Reject anything that would not survive as plain data in .env
        if ! problem=$(_api_validate_env_kv "$key" "$value"); then
            _api_error 400 "Rejected value: $problem"
            return
        fi
        updates["$key"]="$value"
    done <<< "$keys"

    # Backup current .env
    cp -p "$env_file" "${env_file}.bak" 2>/dev/null

    # Apply updates to .env file (grep + temp file: no sed metacharacter issues)
    for key in "${!updates[@]}"; do
        local value="${updates[$key]}"
        if grep -q "^${key}=" "$env_file" 2>/dev/null; then
            grep -v "^${key}=" "$env_file" > "${env_file}.tmp" 2>/dev/null
            printf '%s=%s\n' "$key" "$(envfile_quote "$value" bash)" >> "${env_file}.tmp"
            chmod --reference="$env_file" "${env_file}.tmp" 2>/dev/null
            mv -f "${env_file}.tmp" "$env_file"
        else
            [[ -s "$env_file" && "$(tail -c1 "$env_file")" != "" ]] && printf '\n' >> "$env_file"
            printf '%s=%s\n' "$key" "$(envfile_quote "$value" bash)" >> "$env_file"
        fi
        changed=$(( changed + 1 ))
    done

    # Reload .env as data — the listener's own bind/port/auth stay as started
    _api_load_env_file "$env_file"
    API_BIND="${DCS_API_EFFECTIVE_BIND:-$API_BIND}"
    API_PORT="${DCS_API_EFFECTIVE_PORT:-$API_PORT}"

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
        # PAM can verify the service account's own password without root; that
        # answer is final. (Other accounts fall through to su, which prompts.)
        [[ "$username" == "$(id -un)" ]] && return 1
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
        local marker
        marker="AUTH_OK_$$_$(date +%s)"
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

    # Strategy 4: sshpass + ssh localhost (password via environment, never argv;
    # username as -l so it can never be parsed as an ssh option)
    if command -v sshpass >/dev/null 2>&1; then
        auth_method="sshpass"
        SSHPASS="$password" sshpass -e ssh -o StrictHostKeyChecking=no \
            -o ConnectTimeout=5 -o BatchMode=no -l "$username" \
            127.0.0.1 'echo AUTH_OK' 2>/dev/null | grep -q AUTH_OK && { echo "$auth_method"; return 0; }
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
    if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        _api_error 400 "Invalid username"
        return
    fi

    local auth_audit="$BASE_DIR/.api-auth/terminal-auth-audit.log"
    local rate_file="$BASE_DIR/.api-auth/terminal-auth-rate.json"
    local sessions_file="$BASE_DIR/.api-auth/terminal-sessions.json"
    mkdir -p "$BASE_DIR/.api-auth"

    # Terminal commands run as the API service account whoever authenticated,
    # so only that account (or root) may unlock it. Otherwise any local login —
    # a guest, a service user — would hand out a shell in the docker group.
    local _svc_user
    _svc_user=$(id -un)
    if [[ "$username" != "$_svc_user" && "$username" != "root" ]]; then
        echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') | REJECTED | ip=${CLIENT_IP:-unknown} | user=$username | reason=not-service-account" >> "$auth_audit"
        _api_error 403 "Terminal access requires the credentials of the service account (${_svc_user}) or root"
        return
    fi

    # Initialize sessions file if needed
    [[ ! -f "$sessions_file" ]] && { echo '{"sessions":[]}' > "$sessions_file"; chmod 600 "$sessions_file" 2>/dev/null; }

    # Rate limit: 5 failed attempts per 15 minutes per IP
    local client_ip="${CLIENT_IP:-127.0.0.1}"
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
    [[ ! -f "$rate_file" ]] && { echo '{"attempts":[]}' > "$rate_file"; chmod 600 "$rate_file" 2>/dev/null; }

    # Authenticate against Linux system
    local auth_method
    auth_method=$(_authenticate_linux_user "$username" "$password")
    local auth_result=$?

    if [[ $auth_result -ne 0 ]]; then
        # Log failed attempt
        echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') | FAILED | ip=$client_ip | user=$username" >> "$auth_audit"

        # Record rate limit (and drop attempts older than the 15-minute window)
        _api_jq_update_file "$rate_file" --arg ip "$client_ip" --argjson ts "$now" \
            '.attempts = [.attempts[] | select(.timestamp > ($ts - 900))] + [{"ip": $ip, "timestamp": $ts, "success": false}]'

        _api_error 401 "Invalid Linux credentials"
        return
    fi

    # Generate session token
    local token
    token=$(head -c 32 /dev/urandom | xxd -p | tr -d '\n' 2>/dev/null || openssl rand -hex 32 2>/dev/null || cat /proc/sys/kernel/random/uuid | tr -d '-' | head -c 64)

    local expiry_seconds="${TERMINAL_SESSION_EXPIRY:-14400}"
    local expires_at=$(( now + expiry_seconds ))

    # Store session (expired sessions are pruned in the same locked update)
    if ! _api_jq_update_file "$sessions_file" --arg t "$token" --arg u "$username" --argjson c "$now" --argjson e "$expires_at" --arg m "$auth_method" \
        '.sessions = [.sessions[] | select(.expires_at > $c)] + [{"token": $t, "username": $u, "created_at": $c, "expires_at": $e, "auth_method": $m}]'; then
        _api_error 500 "Failed to store terminal session"
        return
    fi

    # Log success
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') | SUCCESS | ip=$client_ip | user=$username | method=$auth_method" >> "$auth_audit"

    # Record rate limit (success)
    _api_jq_update_file "$rate_file" --arg ip "$client_ip" --argjson ts "$now" \
        '.attempts = [.attempts[] | select(.timestamp > ($ts - 900))] + [{"ip": $ip, "timestamp": $ts, "success": true}]'

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

    if [[ -f "$sessions_file" ]]; then
        _api_jq_update_file "$sessions_file" --arg t "$token" '.sessions = [.sessions[] | select(.token != $t)]'
    fi

    local auth_audit="$BASE_DIR/.api-auth/terminal-auth-audit.log"
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') | LOGOUT | token=${token:0:8}..." >> "$auth_audit"

    _api_success "{\"success\": true, \"message\": \"Terminal session ended\"}"
}

# =============================================================================
# TERMINAL EXEC / HISTORY
# =============================================================================

# POST /terminal/exec — Run a shell command on the host (terminal session required, 60 s limit)
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
        "init 0"            # system halt
        "crontab -r"        # cron wipe
        "iptables -f"       # firewall flush
        "nft flush"         # nftables flush
    )

    for _pat in "${_blocked_patterns[@]}"; do
        if [[ "$_cmd_lower" == *"${_pat,,}"* ]]; then
            local client_ip="${CLIENT_IP:-unknown}"
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
        # whole-word matches only, so `getent passwd` or `last reboot` still work
        '(^|[;&|[:space:]])(sudo\s+)?(shutdown|reboot|poweroff|halt|passwd|useradd|userdel|groupdel|visudo)([[:space:]]|$)'
    )
    for _rpat in "${_blocked_regex[@]}"; do
        if printf '%s' "$_cmd_lower" | grep -qE "$_rpat"; then
            local client_ip="${CLIENT_IP:-unknown}"
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

    local recent_count=0
    if [[ -f "$rate_file" ]]; then
        recent_count=$(awk -v cutoff="$one_min_ago" '$1 >= cutoff' "$rate_file" 2>/dev/null | wc -l)
        if (( recent_count >= 10 )); then
            _api_error 429 "Rate limit exceeded: 10 commands per minute"
            return
        fi
    fi

    # Keep only the current window in the rate log (it must not grow forever)
    { [[ -f "$rate_file" ]] && awk -v cutoff="$one_min_ago" '$1 >= cutoff' "$rate_file" 2>/dev/null; echo "$now"; } > "$rate_file.tmp" && mv -f "$rate_file.tmp" "$rate_file"

    # Execute command (handlers run with errexit off, so $? is the real status)
    local output exit_code
    output=$(cd "$cwd" 2>/dev/null && timeout 60 bash -c "$command" 2>&1)
    exit_code=$?

    # Audit log (includes Linux username); one line per command, no injection
    local _cmd_log="${command//$'\n'/ }" _cwd_log="${cwd//$'\n'/ }"
    _cmd_log="${_cmd_log//$'\r'/}"
    _cwd_log="${_cwd_log//$'\r'/}"
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') | linux_user=$session_user | exit=$exit_code | cwd=$_cwd_log | cmd=$_cmd_log" >> "$audit_file"

    local success="true"
    [[ "$exit_code" -ne 0 ]] && success="false"

    _api_success "{\"command\": \"$(_api_json_escape "$command")\", \"cwd\": \"$(_api_json_escape "$cwd")\", \"exit_code\": $exit_code, \"output\": \"$(_api_json_escape "$output")\", \"success\": $success, \"timestamp\": \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\"}"
}

# GET /terminal/history — Recent terminal commands from the audit log
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
    output=$(timeout 10 docker exec "$container" ls -la --time-style=long-iso "$query_path" 2>/dev/null) || \
    output=$(timeout 10 docker exec "$container" ls -la "$query_path" 2>&1)
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

        # Parse in bash (no subprocesses per entry): perms links owner group size ...
        local perms type_char name_field size_field date_field
        local _links _owner _group _f6 _f7 _f8 _rest
        read -r perms _links _owner _group size_field _f6 _f7 _f8 _rest <<< "$line"
        if [[ "$size_field" == *, ]]; then
            # Device nodes print "major, minor" in place of a size
            read -r perms _links _owner _group size_field _ _f6 _f7 _f8 _rest <<< "$line"
            size_field=0
        fi
        [[ "$size_field" =~ ^[0-9]+$ ]] || size_field=0
        if [[ "$_f6" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            # GNU --time-style=long-iso: date(6) time(7) name(8+)
            date_field="$_f6 $_f7"
            name_field="${_f8}${_rest:+ $_rest}"
        else
            # BusyBox: month(6) day(7) time-or-year(8) name(9+)
            date_field="$_f6 $_f7 $_f8"
            name_field="$_rest"
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

    # Only regular files: FIFOs, device nodes and /proc entries can block the
    # handler or grow without bound (stat reports 0 bytes for them)
    local _ftype
    _ftype=$(timeout 10 docker exec "$container" stat -c %F "$file_path" 2>/dev/null)
    if [[ "$_ftype" != "regular file" && "$_ftype" != "regular empty file" ]]; then
        _api_error 400 "Not a regular file (${_ftype:-not found})"
        return
    fi

    # Size limit: 1MB
    local file_size
    file_size=$(timeout 10 docker exec "$container" stat -c %s "$file_path" 2>/dev/null || echo "0")
    [[ "$file_size" =~ ^[0-9]+$ ]] || file_size=0
    if (( file_size > 1048576 )); then
        _api_error 400 "File too large (${file_size} bytes). Maximum 1MB."
        return
    fi

    local content
    content=$(timeout 15 docker exec "$container" head -c 1048576 "$file_path" 2>/dev/null)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        _api_error 400 "Failed to read file: $(_api_json_escape "$content")"
        return
    fi

    # Reject binary content (control bytes other than tab/newline/CR)
    local _binre=$'[\x01-\x08\x0e-\x1f]'
    if [[ "$content" =~ $_binre ]]; then
        _api_error 400 "Binary file cannot be displayed as text"
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
    local entries_json="["
    local first=true

    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^# ]] && continue
        [[ "$line" =~ "no crontab for" ]] && continue

        # Parse: min hour day month dow command  (or @reboot/@daily shortcuts)
        local schedule cmd human_readable
        if [[ "$line" == @* ]]; then
            schedule="${line%%[[:space:]]*}"
            cmd="${line#*[[:space:]]}"
            [[ "$cmd" == "$line" ]] && cmd=""
        else
            schedule=$(echo "$line" | awk '{print $1,$2,$3,$4,$5}')
            cmd=$(echo "$line" | awk '{for(i=6;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//')
        fi

        [[ -z "$cmd" ]] && continue

        # Generate human-readable description
        human_readable=$(_cron_to_human "$schedule")

        $first || entries_json+=","
        first=false
        entries_json+="{\"schedule\": \"$(_api_json_escape "$schedule")\", \"command\": \"$(_api_json_escape "$cmd")\", \"user\": \"$(whoami)\", \"source\": \"user\", \"human_readable\": \"$(_api_json_escape "$human_readable")\"}"
    done <<< "$raw_crontab"
    entries_json+="]"

    _api_success "{\"entries\": $entries_json, \"raw\": \"$(_api_json_escape "$raw_crontab")\"}"
}

# GET /system/crontab/system — System-level cron entries
handle_crontab_system() {
    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    local entries_json="["
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

            $first || entries_json+=","
            first=false
            entries_json+="{\"schedule\": \"$(_api_json_escape "$schedule")\", \"command\": \"$(_api_json_escape "$cmd")\", \"user\": \"$(_api_json_escape "$user")\", \"source\": \"system\", \"human_readable\": \"$(_api_json_escape "$human_readable")\"}"
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

                $first || entries_json+=","
                first=false
                entries_json+="{\"schedule\": \"$(_api_json_escape "$schedule")\", \"command\": \"$(_api_json_escape "$cmd")\", \"user\": \"$(_api_json_escape "$user")\", \"source\": \"cron.d\", \"human_readable\": \"$(_api_json_escape "$human_readable")\"}"
            done < "$cronfile"
        done
    fi

    entries_json+="]"
    _api_success "{\"entries\": $entries_json}"
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

    # Backup current crontab (keep the last 10)
    local backup_file
    backup_file="$BASE_DIR/.api-auth/crontab-backup-$(date +%s).txt"
    mkdir -p "$BASE_DIR/.api-auth"
    crontab -l > "$backup_file" 2>/dev/null || true
    ls -1t "$BASE_DIR"/.api-auth/crontab-backup-*.txt 2>/dev/null | tail -n +11 | xargs -r rm -f

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

    case "$schedule" in
        @reboot)  echo "At boot"; return ;;
        @hourly)  echo "Every hour"; return ;;
        @daily|@midnight) echo "Daily at midnight"; return ;;
        @weekly)  echo "Weekly"; return ;;
        @monthly) echo "Monthly"; return ;;
        @yearly|@annually) echo "Yearly"; return ;;
    esac
    # Fixed-time descriptions need plain numbers (not */5 or 1,15 lists)
    local _numeric=false
    [[ "$min" =~ ^[0-9]+$ && "$hour" =~ ^[0-9]+$ ]] && _numeric=true

    # Handle common patterns
    if [[ "$min" == "*" && "$hour" == "*" && "$dom" == "*" && "$mon" == "*" && "$dow" == "*" ]]; then
        echo "Every minute"; return
    fi
    if [[ "$min" == "0" && "$hour" == "*" && "$dom" == "*" && "$mon" == "*" && "$dow" == "*" ]]; then
        echo "Every hour"; return
    fi
    if [[ "$_numeric" == "true" && "$dom" == "*" && "$mon" == "*" && "$dow" == "*" ]]; then
        printf "Daily at %s:%02d" "$hour" "$min"; return
    fi
    if [[ "$_numeric" == "true" && "$dom" == "*" && "$mon" == "*" && "$dow" == "0" ]]; then
        printf "Weekly (Sun) at %s:%02d" "$hour" "$min"; return
    fi
    if [[ "$_numeric" == "true" && "$dom" == "1" && "$mon" == "*" && "$dow" == "*" ]]; then
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
        log_output=$(awk -v ts="$since" 'substr($0, 2, 19) >= ts' "$log_file" 2>/dev/null | tail -"${lines}")
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

# POST /images/{image}/delete — Remove an image
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

# POST /containers/{container}/rename — Rename a container
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

# GET /stacks/{stack}/services — Services of a stack with container state, health and image
handle_stack_services() {
    local stack_name="$1"
    [[ -z "$stack_name" ]] && { _api_error 400 "Missing stack name"; return; }

    local compose_file="$COMPOSE_DIR/$stack_name/docker-compose.yml"
    [[ ! -f "$compose_file" ]] && { _api_error 404 "Stack not found"; return; }

    local env_file="$COMPOSE_DIR/$stack_name/.env"
    local -a compose_args=(-f "$compose_file")
    [[ -f "$env_file" ]] && compose_args+=(--env-file "$env_file")

    # Get all service names from compose config
    local -a svc_list=()
    while IFS= read -r svc; do
        [[ -n "$svc" ]] && svc_list+=("$svc")
    done < <($DOCKER_COMPOSE_CMD "${compose_args[@]}" config --services 2>/dev/null)

    # Map service names to container names (single compose ps call)
    local -A svc_to_container=()
    local -a container_names=()
    while IFS=$'\t' read -r _svc_name _ctr_name; do
        [[ -n "$_svc_name" && -n "$_ctr_name" ]] && {
            svc_to_container["$_svc_name"]="$_ctr_name"
            container_names+=("$_ctr_name")
        }
    done < <($DOCKER_COMPOSE_CMD "${compose_args[@]}" ps --format '{{.Service}}\t{{.Name}}' 2>/dev/null)

    # Batch inspect all containers at once (1 call instead of 3N)
    local _inspect_index="{}"
    if [[ ${#container_names[@]} -gt 0 ]]; then
        local _batch_inspect
        _batch_inspect=$(timeout 5 docker inspect "${container_names[@]}" 2>/dev/null)
        if [[ -n "$_batch_inspect" ]]; then
            _inspect_index=$(printf '%s' "$_batch_inspect" | jq -c '
                [.[] | {
                    key: (.Name | ltrimstr("/")),
                    value: {
                        state: .State.Status,
                        health: (if .State.Health then .State.Health.Status else "none" end),
                        image: .Config.Image
                    }
                }] | from_entries' 2>/dev/null) || _inspect_index="{}"
        fi
    fi

    # Build response from indexed data
    local services_json="["
    local first=true

    for svc in "${svc_list[@]}"; do
        $first || services_json+=","
        first=false

        local container_name="${svc_to_container[$svc]:-}"
        local state health image

        if [[ -n "$container_name" ]]; then
            local _svc_data
            _svc_data=$(printf '%s' "$_inspect_index" | jq -r --arg cn "$container_name" '.[$cn] // empty' 2>/dev/null)
            if [[ -n "$_svc_data" ]]; then
                state=$(printf '%s' "$_svc_data" | jq -r '.state // "unknown"' 2>/dev/null)
                health=$(printf '%s' "$_svc_data" | jq -r '.health // "none"' 2>/dev/null)
                image=$(printf '%s' "$_svc_data" | jq -r '.image // "unknown"' 2>/dev/null)
            else
                state="unknown"; health="none"; image="unknown"
            fi
        else
            state="not_created"; health="none"; image=""; container_name=""
        fi

        services_json+="{\"name\": \"$(_api_json_escape "$svc")\", \"state\": \"$state\", \"health\": \"$health\", \"image\": \"$(_api_json_escape "$image")\", \"container\": \"$(_api_json_escape "$container_name")\"}"
    done

    services_json+="]"

    _api_success "{\"stack\": \"$(_api_json_escape "$stack_name")\", \"services\": $services_json}"
}

# GET /stacks/{stack}/activity — Progress of the action running (or last run) on a stack: phase, per-service state, compose output
handle_stack_activity() {
    local stack="$1"
    local rec_file="$STACK_ACTIVITY_DIR/$stack.json" log_file="$STACK_ACTIVITY_DIR/$stack.log"
    local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml" env_file="$COMPOSE_DIR/$stack/.env"
    [[ -f "$compose_file" ]] || { _api_error 404 "Stack not found"; return; }
    if [[ ! -f "$rec_file" ]]; then
        _api_success "$(jq -nc --arg s "$stack" '{stack: $s, active: false, id: null, action: null, template: null, phase: "idle", started_at: null, finished_at: null, success: null, elapsed_s: 0, services: [], output: [], error: ""}')"
        return
    fi
    local rec
    rec=$(cat "$rec_file" 2>/dev/null) || rec='{}'
    printf '%s' "$rec" | jq -e 'type == "object"' >/dev/null 2>&1 || rec='{}'
    local finished_at success pid started_at action
    finished_at=$(jq -r '.finished_at // empty' <<< "$rec"); success=$(jq -r '.success // empty' <<< "$rec")
    pid=$(jq -r '.pid // empty' <<< "$rec"); started_at=$(jq -r '.started_at // empty' <<< "$rec")
    action=$(jq -r '.action // empty' <<< "$rec")
    local active=true
    if [[ -n "$finished_at" ]]; then
        active=false
    elif [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
        # The runner is gone without closing its record (server restart, kill)
        _stack_activity_end "$stack" false "The background runner stopped before it finished"
        rec=$(cat "$rec_file" 2>/dev/null) || rec='{}'
        active=false; success=false; finished_at=$(jq -r '.finished_at // empty' <<< "$rec")
    fi
    local elapsed=0 start_epoch end_epoch
    start_epoch=$(date -d "$started_at" +%s 2>/dev/null) || start_epoch=0
    if [[ "$active" == "true" ]]; then end_epoch=$(date +%s); else end_epoch=$(date -d "$finished_at" +%s 2>/dev/null) || end_epoch=$(date +%s); fi
    [[ "$start_epoch" -gt 0 ]] && elapsed=$(( end_epoch - start_epoch ))
    # Services: the ones the action is about (deploy), else the whole stack
    local -a svcs=()
    mapfile -t svcs < <(jq -r '.services[]? // empty' <<< "$rec")
    if [[ ${#svcs[@]} -eq 0 ]]; then
        local -a compose_args=(-f "$compose_file")
        [[ -f "$env_file" ]] && compose_args+=(--env-file "$env_file")
        mapfile -t svcs < <($DOCKER_COMPOSE_CMD "${compose_args[@]}" config --services 2>/dev/null)
    fi
    local logtxt=""
    [[ -f "$log_file" ]] && logtxt=$(tr '\r' '\n' < "$log_file" | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g')
    local services_json="[" first=true
    local svc cn insp state health image pulled created started_flag re_svc re_cn first_detail=""
    local any_not_pulled=false any_not_created=false all_running=true any_exited=false any_unhealthy=false any_health_starting=false
    for svc in "${svcs[@]}"; do
        cn=$(jq -r --arg s "$svc" '.containers[$s] // empty' <<< "$rec")
        [[ -z "$cn" ]] && cn=$(_compose_container_name "$COMPOSE_DIR/$stack" "$svc")
        state="missing"; health="none"; image=""
        if insp=$(docker inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.Config.Image}}' "$cn" 2>/dev/null); then
            IFS='|' read -r state health image <<< "$insp"
        fi
        [[ -z "$image" ]] && image=$(_compose_service_image "$COMPOSE_DIR/$stack" "$svc")
        re_svc=$(printf '%s' "$svc" | sed 's/[.[*^$]/\\&/g'); re_cn=$(printf '%s' "$cn" | sed 's/[.[*^$]/\\&/g')
        pulled=false; created=false; started_flag=false
        grep -Eq "^[[:space:]]*${re_svc}[[:space:]]+Pulled" <<< "$logtxt" && pulled=true
        grep -Eq "^[[:space:]]*Container[[:space:]]+${re_cn}[[:space:]]+(Created|Recreated|Starting|Started|Running|Healthy)" <<< "$logtxt" && created=true
        grep -Eq "^[[:space:]]*Container[[:space:]]+${re_cn}[[:space:]]+(Started|Running|Healthy)" <<< "$logtxt" && started_flag=true
        [[ "$state" != "missing" ]] && created=true
        [[ "$state" == "running" ]] && started_flag=true
        if [[ "$pulled" == "false" && -n "$image" ]] && docker image inspect "$image" >/dev/null 2>&1; then pulled=true; fi
        [[ "$pulled" == "false" ]] && any_not_pulled=true
        [[ "$created" == "false" ]] && any_not_created=true
        [[ "$state" != "running" ]] && all_running=false
        [[ "$state" == "exited" || "$state" == "dead" ]] && any_exited=true
        [[ "$health" == "unhealthy" ]] && any_unhealthy=true
        [[ "$health" == "starting" ]] && any_health_starting=true
        # What the container itself says when it is not fine: the last health
        # check output, or the last log lines of an exited container
        local detail=""
        if [[ "$health" == "unhealthy" || "$health" == "starting" ]]; then
            detail=$(docker inspect --format '{{json .State.Health}}' "$cn" 2>/dev/null | jq -r '.Log[-1].Output // empty' 2>/dev/null | tail -c 400 | tr -d '\r' | sed -E 's/[[:space:]]+$//') || detail=""
            [[ -n "$detail" ]] && detail="health check: $detail"
        elif [[ "$state" == "exited" || "$state" == "dead" ]]; then
            detail=$(docker logs --tail 5 "$cn" 2>&1 | tail -c 600 | tr -d '\r') || detail=""
            [[ -n "$detail" ]] && detail="last log lines: $detail"
        fi
        [[ -z "$first_detail" && -n "$detail" && ( "$health" == "unhealthy" || "$state" == "exited" || "$state" == "dead" ) ]] && first_detail="$svc — $detail"
        $first || services_json+=","
        first=false
        services_json+=$(jq -nc --arg s "$svc" --arg c "$cn" --arg i "$image" --arg st "$state" --arg h "$health" --arg d "$detail" \
            --argjson p "$pulled" --argjson cr "$created" --argjson sd "$started_flag" \
            '{service: $s, container: $c, image: $i, state: $st, health: $h, pulled: $p, created: $cr, started: $sd, detail: $d}')
    done
    services_json+="]"
    local phase
    if [[ "$active" == "true" ]]; then
        # Containers can be up while the runner still runs plugin hooks and
        # the ownership fix: report that as running so the UI can move on
        if [[ "$action" == "stop" ]]; then phase="stopping"
        elif [[ "$any_not_pulled" == "true" ]]; then phase="pulling"
        elif [[ "$any_not_created" == "true" ]]; then phase="creating"
        elif [[ "$all_running" == "true" && "$any_health_starting" == "false" && "$any_unhealthy" == "false" && ${#svcs[@]} -gt 0 ]]; then phase="running"
        elif [[ "$all_running" == "true" && "$any_health_starting" == "true" ]]; then phase="healthcheck"
        else phase="starting"; fi
    elif [[ "$success" == "true" ]]; then
        if [[ "$action" == "stop" ]]; then phase="stopped"
        elif [[ "$any_exited" == "true" ]]; then phase="exited"
        elif [[ "$any_unhealthy" == "true" ]]; then phase="unhealthy"
        elif [[ "$any_health_starting" == "true" ]]; then phase="healthcheck"
        elif [[ "$all_running" == "true" ]]; then phase="running"
        else phase="started"; fi
    else
        phase="failed"
    fi
    # Output tail (plain lines) and the most telling error line
    local output_json="[]" error=""
    if [[ -n "$logtxt" ]]; then
        output_json=$(printf '%s\n' "$logtxt" | sed -E 's/[[:space:]]+$//' | grep -v '^[[:space:]]*$' | tail -n 60 | jq -R . | jq -s -c .) || output_json="[]"
        if [[ "$phase" == "failed" || "$phase" == "exited" ]]; then
            error=$(printf '%s\n' "$logtxt" | grep -iE 'error|failed|denied|no such|cannot|invalid|conflict' | tail -n 1 | sed -E 's/^[[:space:]]+//') || error=""
        fi
    fi
    [[ -z "$error" && -n "$first_detail" && ( "$phase" == "unhealthy" || "$phase" == "exited" ) ]] && error="$first_detail"
    [[ -z "$error" && "$phase" == "failed" ]] && error=$(jq -r '.message // "The action did not complete"' <<< "$rec")
    _api_success "$(jq -nc --arg s "$stack" --argjson a "$active" --argjson rec "$rec" --arg ph "$phase" --argjson el "$elapsed" \
        --argjson sv "$services_json" --argjson out "$output_json" --arg err "$error" \
        '{stack: $s, active: $a, id: ($rec.id // null), action: ($rec.action // null), template: ($rec.template // null), phase: $ph,
          started_at: ($rec.started_at // null), finished_at: ($rec.finished_at // null), success: ($rec.success // null),
          elapsed_s: $el, services: $sv, output: $out, error: $err}')"
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
    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    local ui_image="ghcr.io/scotthowson/docker-compose-skeleton-ui:latest"

    if ! docker inspect DCS-UI >/dev/null 2>&1; then
        _api_error 404 "DCS-UI container not found"
        return
    fi

    # Pull the latest image
    local pull_output
    if ! pull_output=$(timeout 120 docker pull "$ui_image" 2>&1); then
        _api_error 500 "Failed to pull image: $pull_output"
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
    ( $DOCKER_COMPOSE_CMD -f "$compose_file" "${env_args[@]}" up -d --force-recreate --no-deps dcs-ui ) </dev/null >/dev/null 2>&1 &

    _api_success "{\"success\": true, \"message\": \"DCS-UI is being updated. The page will reconnect automatically.\"}"
}

# Paths git tracks but users legitimately edit (deployed stacks, template
# .env files, alert/automation state, plugin manifests). They must survive
# `git pull` and `git reset --hard`.
_API_GIT_USER_PATHS=(Stacks .templates .api-auth .plugins)

# Run a git command with user-edited tracked files stashed around it.
# Prints the command output; returns its exit status.
_api_git_preserving_user_data() {
    local stashed=false out rc=0
    if [[ -n "$(git status --porcelain -- "${_API_GIT_USER_PATHS[@]}" 2>/dev/null | grep -v '^??')" ]]; then
        git stash push --quiet -- "${_API_GIT_USER_PATHS[@]}" >/dev/null 2>&1 && stashed=true
    fi
    out=$("$@" 2>&1) || rc=$?
    if [[ "$stashed" == "true" ]] && ! git stash pop --quiet >/dev/null 2>&1; then
        out+=$'\n'"WARNING: local changes to stack/template/plugin files conflict with this version and were left in 'git stash'. Run 'git stash pop' in $BASE_DIR to merge them."
    fi
    printf '%s' "$out"
    return "$rc"
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

    # Include last backup tag for rollback UI (most recent dcs-backup-* tag)
    local last_backup=""
    last_backup=$(git tag -l 'dcs-backup-*' --sort=-creatordate 2>/dev/null | head -1)

    _api_success "{
  \"available\": $available,
  \"current_version\": \"$(_api_json_escape "$current")\",
  \"latest_version\": \"$(_api_json_escape "$latest")\",
  \"commits_behind\": $behind,
  \"changelog\": $changelog,
  \"has_local_changes\": $has_changes,
  \"branch\": \"$(_api_json_escape "$branch")\",
  \"last_backup_tag\": \"$(_api_json_escape "$last_backup")\",
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

    # Explicit confirmation is always required
    local confirm
    confirm=$(printf '%s' "$body" | jq -r '.confirm // empty' 2>/dev/null)
    if [[ "$confirm" != "true" ]]; then
        _api_error 400 "Missing confirmation. Send {\"confirm\": true} to apply the update."
        return
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

    # Fast-forward-only pull (explicit refs/heads/ avoids tag ambiguity). A
    # refused fast-forward leaves the tree untouched, so nothing needs undoing —
    # never `reset --hard` here, that would wipe user-edited stack files.
    local pull_output pull_exit=0
    pull_output=$(_api_git_preserving_user_data git pull --ff-only origin "refs/heads/$branch") || pull_exit=$?

    if [[ $pull_exit -ne 0 ]]; then
        _api_error 500 "Update failed (nothing was changed; backup tag $backup_tag kept): $pull_output"
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
        local tag_list
        tag_list=$(git tag -l 'dcs-backup-*' --sort=-creatordate 2>/dev/null | head -20)
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

    # Perform rollback: reset the branch to the backup tag, keeping user data
    local reset_output reset_exit=0
    reset_output=$(_api_git_preserving_user_data git reset --hard "$backup_tag") || reset_exit=$?

    if [[ $reset_exit -ne 0 ]]; then
        _api_error 500 "Rollback failed: $reset_output"
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
            printf '%s\n' "$_pw" | /usr/bin/sudo.ws -S -p '' "$@" 2>&1
            return $?
        fi

        # Try regular sudo -S (works on traditional sudo, not sudo-rs)
        local _sudo_out
        _sudo_out=$(printf '%s\n' "$_pw" | sudo -S -p '' "$@" 2>&1)
        local _rc=$?
        if [[ $_rc -eq 0 ]] || ! echo "$_sudo_out" | grep -qi "authentication failed\|try again"; then
            echo "$_sudo_out"
            return $_rc
        fi

        # Fallback: use python3 pty to run su -c (same as terminal auth strategy).
        # `su` only escalates when the target account is root — for any other
        # user it would just run the command unprivileged and report failures.
        # SECURITY: Pass password and command via environment variables, NOT string interpolation.
        # This prevents code injection via passwords containing quotes or Python metacharacters.
        if [[ "$_user" == "root" ]] && command -v python3 >/dev/null 2>&1; then
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
# POST /system/os-update/check — List available OS package updates (terminal session required)
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
# POST /system/os-update/apply — Apply OS package updates in the background (terminal session required)
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

    local client_ip="${CLIENT_IP:-unknown}"

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
    ) </dev/null >/dev/null 2>&1 &
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
    local content=""
    [[ -f "$status_file" ]] && content=$(cat "$status_file" 2>/dev/null)
    if [[ -n "$content" ]] && jq -e . <<< "$content" >/dev/null 2>&1; then
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
DDNS_PID_FILE="${BASE_DIR}/.data/ddns.pid"
DDNS_IP_FILE="${BASE_DIR}/.data/ddns-current-ip"

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
    local cf_token
    cf_token=$(_find_cf_token)
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
    # Zone lookup with retries — a transient API failure at boot must not
    # silently disable DDNS until the next restart
    while [[ -z "$zone_id" ]]; do
        local zr
        zr=$(curl -s --max-time 10 -H "Authorization: Bearer $cf_token" "$cf_api/zones?name=$domain&status=active" 2>/dev/null)
        zone_id=$(printf '%s' "$zr" | jq -r '.result[0].id // empty' 2>/dev/null)
        if [[ -z "$zone_id" ]]; then
            printf '[%s] DDNS: could not resolve Cloudflare zone for %s (%s) — retrying in %ss\n' "$(date -Iseconds)" "$domain" \
                "$(printf '%s' "$zr" | jq -r '.errors[0].message // "no response"' 2>/dev/null)" "$interval" >> "$log_file"
            sleep "$interval"
            continue
        fi
        printf '%s\n%s\n' "$domain" "$zone_id" > "$zone_cache" 2>/dev/null
    done

    printf '[%s] DDNS started — domain=%s interval=%ss\n' "$(date -Iseconds)" "$domain" "$interval" >> "$log_file"

    while true; do
        local current_ip
        current_ip=$(_ddns_get_public_ip)
        [[ -n "$current_ip" ]] && printf '%s\n' "$current_ip" > "$DDNS_IP_FILE" 2>/dev/null
        # The CrowdSec whitelist must follow the home address, or the next
        # visit from the LAN through the public name gets banned
        _crowdsec_whitelist_sync >/dev/null 2>&1 || true

        if [[ -n "$current_ip" && "$current_ip" != "$last_ip" ]]; then
            # IP changed — update records; last_ip only advances when every
            # record update succeeded, so failures are retried next cycle
            local all_ok=true
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

                local cf_resp
                if [[ -n "$record_id" ]]; then
                    # Only update if IP actually differs
                    if [[ "$record_ip" != "$current_ip" ]]; then
                        cf_resp=$(curl -s --max-time 10 -X PATCH \
                            -H "Authorization: Bearer $cf_token" \
                            -H "Content-Type: application/json" \
                            -d "{\"content\":\"$current_ip\"}" \
                            "$cf_api/zones/$zone_id/dns_records/$record_id" 2>/dev/null)
                    else
                        cf_resp='{"success":true}'
                    fi
                else
                    # Create new A record (no existing A or CNAME)
                    cf_resp=$(curl -s --max-time 10 -X POST \
                        -H "Authorization: Bearer $cf_token" \
                        -H "Content-Type: application/json" \
                        -d "{\"type\":\"A\",\"name\":\"$fqdn\",\"content\":\"$current_ip\",\"proxied\":true,\"ttl\":1,\"comment\":\"DCS DDNS\"}" \
                        "$cf_api/zones/$zone_id/dns_records" 2>/dev/null)
                fi
                if [[ "$(printf '%s' "$cf_resp" | jq -r '.success // false' 2>/dev/null)" != "true" ]]; then
                    all_ok=false
                    printf '[%s] DDNS: failed to update %s → %s (%s)\n' "$(date -Iseconds)" "$fqdn" "$current_ip" \
                        "$(printf '%s' "$cf_resp" | jq -r '.errors[0].message // "no response"' 2>/dev/null)" >> "$log_file"
                fi
            done

            if [[ "$all_ok" == "true" ]]; then
                printf '[%s] IP updated: %s → %s (%s)\n' "$(date -Iseconds)" "${last_ip:-none}" "$current_ip" "$subdomains" >> "$log_file"
                last_ip="$current_ip"
            fi
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
    # The loop caches the last public IP it saw; a status poll must not make
    # four outbound HTTP requests of its own
    local current_ip=""
    [[ -f "$DDNS_IP_FILE" ]] && current_ip=$(head -c 64 "$DDNS_IP_FILE" 2>/dev/null | tr -d '[:space:]')
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

# GET /system/metrics — CPU load, memory and per-mount disk usage
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
            /|/boot|/boot/*|/sys/*|/proc/*|/dev/*|/run/*|/snap/*) continue ;;
        esac
        # Skip mergerfs/overlay mounts (device paths contain colons)
        [[ "$dev" == *":"* ]] && continue
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
# Metrics history is tiered: raw samples (every METRICS_COLLECT_INTERVAL s) for
# METRICS_RAW_DAYS, 5-minute averages for METRICS_5M_DAYS, hourly averages for
# METRICS_RETENTION_DAYS. The collector rolls the tiers up once an hour; readers
# stitch the tiers together and downsample to at most METRICS_MAX_POINTS.
METRICS_ROLLUP_DIR="$BASE_DIR/.data/metrics"
METRICS_ROLLUP_5M="$METRICS_ROLLUP_DIR/rollup-5m.jsonl"
METRICS_ROLLUP_1H="$METRICS_ROLLUP_DIR/rollup-1h.jsonl"
METRICS_RAW_DAYS="${METRICS_RAW_DAYS:-7}"
METRICS_5M_DAYS="${METRICS_5M_DAYS:-90}"
# Hourly rows are tiny (8,760 a year): keep them for two years. The legacy
# METRICS_RETENTION_DAYS (7 in older .env files) only ever meant the raw tier
# and must not cut the long history short.
METRICS_HOURLY_DAYS="${METRICS_HOURLY_DAYS:-730}"
METRICS_MAX_POINTS="${METRICS_MAX_POINTS:-1500}"

# jq helpers shared by the reader and the rollup
_METRICS_JQ_DEFS='
def num(f): ((f // 0) | tonumber? // 0);
def avg(a): if (a | length) == 0 then 0 else ((a | add) / (a | length) * 10 | round / 10) end;
def agg(bsz): group_by(((.epoch / bsz) | floor)) | map(
    (((.[0].epoch / bsz) | floor) * bsz) as $e
    | { epoch: $e, ts: ($e | todate), n: (map(.n // 1) | add),
        cpu_pct: avg(map(num(.cpu_pct))), cpu_min: (map(num(.cpu_min // .cpu_pct)) | min), cpu_max: (map(num(.cpu_max // .cpu_pct)) | max),
        mem_pct: avg(map(num(.mem_pct))), mem_min: (map(num(.mem_min // .mem_pct)) | min), mem_max: (map(num(.mem_max // .mem_pct)) | max),
        disk_pct: avg(map(num(.disk_pct))), disk_min: (map(num(.disk_min // .disk_pct)) | min), disk_max: (map(num(.disk_max // .disk_pct)) | max),
        load1: avg(map(num(.load1))), mem_used_mb: (avg(map(num(.mem_used_mb))) | round), mem_total_mb: (map(num(.mem_total_mb)) | max) });
'

# Seconds covered by a range name; empty for an unknown range.
_metrics_range_seconds() {
    case "$1" in
        1h) echo 3600 ;; 6h) echo 21600 ;; 24h) echo 86400 ;; 7d) echo 604800 ;;
        30d) echo 2592000 ;; 90d) echo 7776000 ;; 1y) echo 31536000 ;; all) echo 0 ;;
        *) return 1 ;;
    esac
}

# Rows of one tier as a JSON stream, tagged with their tier. Partial lines are skipped.
_metrics_tier_rows() {
    local file="$1" tier="$2"
    [[ -s "$file" ]] || return 0
    jq -Rc --arg t "$tier" 'fromjson? | select(type == "object" and ((.epoch // null) | type) == "number") | . + {tier: $t}' "$file" 2>/dev/null
}

# Points for a range as one JSON object: {range, points, count, total,
# resolution_s, oldest_epoch, newest_epoch}. Raw samples win where they exist,
# then 5-minute rows, then hourly rows, so young installs and old history both
# render; the result is downsampled to METRICS_MAX_POINTS by bucket averaging.
_metrics_points() {
    local range="$1" now secs cutoff
    now=$(date +%s)
    secs=$(_metrics_range_seconds "$range") || { range="1h"; secs=3600; }
    cutoff=$(( secs == 0 ? 0 : now - secs ))
    {
        _metrics_tier_rows "$METRICS_ROLLUP_1H" "1h"
        _metrics_tier_rows "$METRICS_ROLLUP_5M" "5m"
        _metrics_tier_rows "$METRICS_HISTORY_FILE" "raw"
    } | jq -sc --argjson cutoff "$cutoff" --argjson now "$now" --argjson maxp "$METRICS_MAX_POINTS" \
           --argjson raw_res "${METRICS_COLLECT_INTERVAL:-30}" --arg range "$range" "$_METRICS_JQ_DEFS"'
        (map(select(.tier == "raw" and .epoch >= $cutoff))) as $raw
        | (if ($raw | length) > 0 then ($raw | map(.epoch) | min) else $now end) as $rawmin
        | (map(select(.tier == "5m" and .epoch >= $cutoff and (.epoch + 300) <= $rawmin))) as $five
        | (if ($five | length) > 0 then ($five | map(.epoch) | min) else $rawmin end) as $fivemin
        | (map(select(.tier == "1h" and .epoch >= $cutoff and (.epoch + 3600) <= $fivemin))) as $hour
        | ($hour + $five + $raw | sort_by(.epoch) | map(del(.tier))) as $pts
        | ($pts | length) as $total
        | (if $total > 0 then ($pts | map(.epoch) | min) else null end) as $oldest
        | (if $total > 0 then ($pts | map(.epoch) | max) else null end) as $newest
        | (if $total > $maxp then ((($newest - $oldest) / ($maxp - 1)) | ceil | if . < $raw_res then $raw_res else . end) else 0 end) as $bsz
        | (if $bsz > 0 then ($pts | agg($bsz)) else $pts end) as $out
        | { range: $range, points: $out, count: ($out | length), total: $total,
            resolution_s: (if $bsz > 0 then $bsz elif ($raw | length) > 0 then $raw_res elif ($five | length) > 0 then 300 else 3600 end),
            oldest_epoch: $oldest, newest_epoch: $newest }' 2>/dev/null \
    || printf '{"range": "%s", "points": [], "count": 0, "total": 0, "resolution_s": %s, "oldest_epoch": null, "newest_epoch": null}' "$range" "${METRICS_COLLECT_INTERVAL:-30}"
}

# Hourly maintenance: trim raw samples to METRICS_RAW_DAYS and rebuild the
# 5-minute and hourly tiers (existing coarse rows are kept where the finer
# tier no longer covers them). Runs under a lock; a failed step never
# replaces a file.
_metrics_rollup() {
    local now
    now=$(date +%s)
    mkdir -p "$METRICS_ROLLUP_DIR" 2>/dev/null || return 1
    (
        flock -n 9 || exit 0
        local raw_cut=$(( now - METRICS_RAW_DAYS * 86400 ))
        local c5=$(( now - METRICS_5M_DAYS * 86400 ))
        local c1=$(( now - METRICS_HOURLY_DAYS * 86400 ))
        if [[ -s "$METRICS_HISTORY_FILE" ]]; then
            jq -Rc --argjson c "$raw_cut" 'fromjson? | select(type == "object" and (.epoch // 0) >= $c)' "$METRICS_HISTORY_FILE" > "$METRICS_HISTORY_FILE.tmp" 2>/dev/null \
                && mv -f "$METRICS_HISTORY_FILE.tmp" "$METRICS_HISTORY_FILE" || rm -f "$METRICS_HISTORY_FILE.tmp"
        fi
        # 5-minute tier from raw
        { _metrics_tier_rows "$METRICS_ROLLUP_5M" "5m"; _metrics_tier_rows "$METRICS_HISTORY_FILE" "raw"; } \
        | jq -sc --argjson c "$c5" --argjson now "$now" "$_METRICS_JQ_DEFS"'
            (map(select(.tier == "raw"))) as $raw
            | (if ($raw | length) > 0 then ($raw | map(.epoch) | min) else $now end) as $rmin
            | (map(select(.tier == "5m" and .epoch >= $c and (.epoch + 300) <= $rmin) | del(.tier))) as $old
            | (($raw | map(del(.tier)) | agg(300)) + $old) | group_by(.epoch) | map(.[0]) | sort_by(.epoch) | .[]' > "$METRICS_ROLLUP_5M.tmp" 2>/dev/null \
            && mv -f "$METRICS_ROLLUP_5M.tmp" "$METRICS_ROLLUP_5M" || rm -f "$METRICS_ROLLUP_5M.tmp"
        # hourly tier from the 5-minute tier
        { _metrics_tier_rows "$METRICS_ROLLUP_1H" "1h"; _metrics_tier_rows "$METRICS_ROLLUP_5M" "5m"; } \
        | jq -sc --argjson c "$c1" --argjson now "$now" "$_METRICS_JQ_DEFS"'
            (map(select(.tier == "5m"))) as $five
            | (if ($five | length) > 0 then ($five | map(.epoch) | min) else $now end) as $fmin
            | (map(select(.tier == "1h" and .epoch >= $c and (.epoch + 3600) <= $fmin) | del(.tier))) as $old
            | (($five | map(del(.tier)) | agg(3600)) + $old) | group_by(.epoch) | map(.[0]) | sort_by(.epoch) | .[]' > "$METRICS_ROLLUP_1H.tmp" 2>/dev/null \
            && mv -f "$METRICS_ROLLUP_1H.tmp" "$METRICS_ROLLUP_1H" || rm -f "$METRICS_ROLLUP_1H.tmp"
    ) 9>"$METRICS_ROLLUP_DIR/.rollup.lock"
}

# POST /metrics/snapshot — Record a metrics sample now
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
    cpu_pct=$(awk "BEGIN { v = ($load1 / $cpu_count) * 100; if (v > 100) v = 100; printf \"%.1f\", v }")

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

    # Disk: the filesystem that holds this installation
    local disk_pct="0"
    local disk_line
    disk_line=$(df -hP "$BASE_DIR" 2>/dev/null | tail -1)
    [[ -z "$disk_line" ]] && disk_line=$(df -hP / 2>/dev/null | tail -1)
    if [[ -n "$disk_line" ]]; then
        disk_pct=$(echo "$disk_line" | awk '{print $5}' | tr -d '%')
    fi

    local entry="{\"ts\":\"$ts\",\"epoch\":$epoch,\"cpu_pct\":$cpu_pct,\"load1\":$load1,\"load5\":$load5,\"load15\":$load15,\"mem_used_mb\":$mem_used,\"mem_total_mb\":$mem_total,\"mem_pct\":$mem_pct,\"disk_pct\":$disk_pct}"

    # Append; the collector's hourly rollup keeps the file bounded
    echo "$entry" >> "$METRICS_HISTORY_FILE"

    _api_success "{\"success\": true, \"timestamp\": \"$ts\", \"cpu_pct\": $cpu_pct, \"mem_pct\": $mem_pct, \"disk_pct\": $disk_pct}"
}

# GET /metrics/trends — Metrics samples for a range (range=1h|6h|24h|7d|30d|90d|1y|all), downsampled, with min/max for rolled-up points
handle_metrics_trends() {
    local range="${QUERY_PARAMS[range]:-1h}"
    _api_success "$(_metrics_points "$range")"
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
    local repo="" tag="" token=""

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

# GET /images/check-updates — Image staleness from age plus the cached registry check
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

    # One pass over all containers: image -> "name1,name2" and image -> stack
    local -A image_containers=() image_stack=()
    while IFS=$'\t' read -r _img _cname _proj; do
        [[ -z "$_img" || -z "$_cname" ]] && continue
        image_containers["$_img"]+="${image_containers[$_img]:+,}$_cname"
        [[ -z "${image_stack[$_img]:-}" && -n "$_proj" ]] && image_stack["$_img"]="$_proj"
    done < <(timeout 10 docker ps -a --format '{{.Image}}\t{{.Names}}\t{{.Label "com.docker.compose.project"}}' 2>/dev/null)

    local now_epoch
    now_epoch=$(date +%s)
    while IFS=$'\t' read -r repo tag id size created_ts; do
        [[ -z "$repo" || "$repo" == "<none>" ]] && continue
        [[ "$tag" == "<none>" ]] && continue

        local full_image="${repo}:${tag}"
        local age_days=0
        if [[ -n "$created_ts" ]]; then
            local created_epoch
            created_epoch=$(date -d "$created_ts" +%s 2>/dev/null || echo 0)
            (( created_epoch > 0 )) && age_days=$(( (now_epoch - created_epoch) / 86400 ))
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

        # Containers using this image and the stack they belong to (from the map above)
        local containers="${image_containers[$full_image]:-}"
        local stack="${image_stack[$full_image]:-}"
        [[ "$stack" == "<no value>" ]] && stack=""

        entries+=("{\"image\": \"$(_api_json_escape "$full_image")\", \"repository\": \"$(_api_json_escape "$repo")\", \"tag\": \"$(_api_json_escape "$tag")\", \"age_days\": $age_days, \"staleness\": \"$staleness\", \"update_available\": $update_available, \"containers\": \"$(_api_json_escape "$containers")\", \"stack\": \"$(_api_json_escape "$stack")\", \"size\": \"$(_api_json_escape "$size")\"}")
    done < <(docker images --format "{{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}\t{{.CreatedAt}}" 2>/dev/null)

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

    local checked_at=""
    [[ -f "$cache_file" ]] && checked_at=$(date -u -d "@$(stat -c %Y "$cache_file" 2>/dev/null || echo 0)" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")
    _api_success "{\"images\": $json, \"total\": ${#entries[@]}, \"stale\": $stale_count, \"aging\": $aging_count, \"current\": $current_count, \"updates_available\": $updates_count, \"registry_checked_at\": $([[ -n "$checked_at" ]] && printf '"%s"' "$checked_at" || echo null)}"
}

# POST /images/check-updates — Compare local image digests with their registries (slow)
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

        # Brief delay to avoid registry rate limiting
        sleep 0.1
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

# POST /images/{image}/update — Pull an image and recreate the Compose services that use it
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
    _api_validate_image_ref "$image_name" || return
    # {"recreate": false} pulls only and leaves running containers on the old image
    local recreate=true
    [[ -n "${2:-}" ]] && recreate=$(printf '%s' "$2" | jq -r 'if .recreate == false then "false" else "true" end' 2>/dev/null || echo true)

    # Pull the new image
    local pull_output
    pull_output=$(timeout 600 docker pull "$image_name" 2>&1) || {
        _api_error 500 "Failed to pull image: $pull_output"
        return
    }

    # The tag's newest digest is now local: the cached registry verdict for this
    # image is "up to date" until the next registry check says otherwise
    local _cache_file="$BASE_DIR/.data/image-update-cache.json"
    mkdir -p "$BASE_DIR/.data" 2>/dev/null
    [[ -s "$_cache_file" ]] || printf '{}' > "$_cache_file"
    _api_jq_update_file "$_cache_file" --arg i "$image_name" '.[$i] = false' || true

    # Find containers using this image and recreate them with the new image
    # docker restart alone does NOT use the newly pulled image — must recreate.
    # Containers that are not Compose-managed are left alone and reported:
    # without a compose file they cannot be recreated with their settings.
    local -a restarted=() skipped=() _iu_failed=()
    local -A touched_stacks=()
    local containers=""
    [[ "$recreate" == "true" ]] && containers=$(docker ps -q --filter "ancestor=$image_name" 2>/dev/null)
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
            # Recreate via docker compose — picks up the new image properly —
            # and report honestly whether the service is running afterwards
            local _env_file="" _state=""
            [[ -f "$compose_project/.env" ]] && _env_file="$compose_project/.env"
            _compose_with_secrets "$compose_project/docker-compose.yml" "$_env_file" up -d --force-recreate --no-deps "$svc_name" >/dev/null 2>&1 || true
            sleep 1
            _state=$(docker inspect --format '{{.State.Status}}' "$cname" 2>/dev/null || echo "missing")
            if [[ "$_state" == "running" ]]; then
                restarted+=("\"$(_api_json_escape "$cname")\"")
            else
                _iu_failed+=("\"$(_api_json_escape "$cname")\"")
            fi
            [[ "$compose_project" == "$COMPOSE_DIR"/* ]] && touched_stacks["$(basename "$compose_project")"]=1
        else
            skipped+=("\"$(_api_json_escape "$cname")\"")
        fi
    done

    # Plugins learn about the update the same way they do for stack updates
    local _ts
    for _ts in "${!touched_stacks[@]}"; do
        _run_plugin_hooks "post-update" "$(_hook_ctx "$_ts" "{\"action\":\"image-update\",\"changed_images\":[\"$(_api_json_escape "$image_name")\"]}" "$([[ ${#_iu_failed[@]} -eq 0 ]] && echo true || echo false)")"
    done

    local restarted_json skipped_json
    restarted_json=$(printf '%s,' "${restarted[@]}")
    restarted_json="[${restarted_json%,}]"
    [[ ${#restarted[@]} -eq 0 ]] && restarted_json="[]"
    skipped_json=$(printf '%s,' "${skipped[@]}")
    skipped_json="[${skipped_json%,}]"
    [[ ${#skipped[@]} -eq 0 ]] && skipped_json="[]"
    local failed_json
    failed_json=$(printf '%s,' "${_iu_failed[@]}")
    failed_json="[${failed_json%,}]"
    [[ ${#_iu_failed[@]} -eq 0 ]] && failed_json="[]"

    # Log update
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    [[ ! -f "$UPDATE_HISTORY_FILE" ]] && echo "[]" > "$UPDATE_HISTORY_FILE"
    local history_entry
    history_entry="{\"image\": \"$(_api_json_escape "$image_name")\", \"timestamp\": \"$ts\", \"containers_restarted\": $restarted_json}"
    if command -v jq >/dev/null 2>&1; then
        jq --argjson entry "$history_entry" '. + [$entry] | .[-100:]' "$UPDATE_HISTORY_FILE" > "${UPDATE_HISTORY_FILE}.tmp" 2>/dev/null && mv "${UPDATE_HISTORY_FILE}.tmp" "$UPDATE_HISTORY_FILE"
    fi

    _api_success "{\"success\": true, \"image\": \"$(_api_json_escape "$image_name")\", \"recreate\": $recreate, \"containers_restarted\": $restarted_json, \"containers_skipped\": $skipped_json, \"containers_failed\": $failed_json, \"timestamp\": \"$ts\"}"
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

# GET /notifications/rules — NTFY notification rules
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

# POST /notifications/rules — Create or update a notification rule
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
    tags=$(printf '%s' "$body" | jq -c '.tags // [] | if type == "array" then . else [] end' 2>/dev/null)
    # `// true` would turn false into true — test for null explicitly
    enabled=$(printf '%s' "$body" | jq -r 'if .enabled == null then true else .enabled end' 2>/dev/null)
    title_template=$(printf '%s' "$body" | jq -r '.title_template // empty' 2>/dev/null)
    message_template=$(printf '%s' "$body" | jq -r '.message_template // empty' 2>/dev/null)

    if [[ -z "$name" || -z "$trigger" ]]; then
        _api_error 400 "Missing required fields: name, trigger"
        return
    fi
    if [[ "$enabled" != "true" && "$enabled" != "false" ]]; then
        _api_error 400 "enabled must be true or false"
        return
    fi

    # If updating an existing rule (same id passed), remove old one first
    local existing_id
    existing_id=$(printf '%s' "$body" | jq -r '.id // empty' 2>/dev/null)
    if [[ -n "$existing_id" ]]; then
        _api_jq_update_file "$NOTIFICATIONS_FILE" --arg id "$existing_id" '.rules = [.rules[] | select(.id != $id)]'
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

    if ! _api_jq_update_file "$NOTIFICATIONS_FILE" --argjson rule "$rule" '.rules += [$rule]'; then
        _api_error 500 "Failed to save notification rule"
        return
    fi

    _api_success "$rule"
}

# DELETE /notifications/rules/{id} — Delete a notification rule
handle_notification_rules_delete() {
    local rule_id="$1"
    _init_notifications_file

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required"
        return
    fi

    _api_jq_update_file "$NOTIFICATIONS_FILE" --arg id "$rule_id" '.rules = [.rules[] | select(.id != $id)]'

    _api_success "{\"success\": true, \"deleted\": \"$(_api_json_escape "$rule_id")\"}"
}

# GET /notifications/history — Recently sent notifications
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
    # Nothing to do until at least one channel exists (NTFY or Discord)
    _ntfy_endpoint >/dev/null 2>&1 || _discord_webhook >/dev/null 2>&1 || return 0
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

        # The event's facts travel as embed fields on Discord
        local _fields='{}' _fk
        for _fk in "${!ctx[@]}"; do
            _fields=$(jq -c --arg k "$_fk" --arg v "${ctx[$_fk]}" '. + {($k): $v}' <<< "$_fields" 2>/dev/null) || _fields='{}'
        done

        # Send on every configured channel (background, non-blocking)
        (
            local _result
            _result=$(_notify_send "$title" "$message" "$priority" "$tags_str" "$event" "$_fields")

            # Log to history (locked: several rules may fire at once)
            [[ "$_result" =~ ^[0-9]+$ ]] || _result=0
            local _ts
            _ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
            local _entry
            _entry=$(jq -n \
                --arg ts "$_ts" --arg type "$event" --arg title "$title" \
                --arg message "$message" --arg priority "$priority" \
                --argjson code "$((10#$_result))" \
                '{timestamp: $ts, type: $type, title: $title, message: $message, priority: $priority, status_code: $code}')
            _api_jq_update_file "$NOTIFICATIONS_FILE" --argjson entry "$_entry" \
                '.history = (.history + [$entry]) | .history = .history[-100:]'
        ) </dev/null >/dev/null 2>&1 &
    done < <(printf '%s' "$rules_json" | jq -c '.[]')
}

# POST /notifications/test — Send a test notification to every configured channel (NTFY, Discord)
handle_notification_test() {
    local body="$1"

    if ! _ntfy_endpoint >/dev/null 2>&1 && ! _discord_webhook >/dev/null 2>&1; then
        _api_error 400 "No notification channel is configured. Set NTFY_URL or DISCORD_WEBHOOK_URL in .env"
        return
    fi

    local message priority title tags
    message=$(printf '%s' "$body" | jq -r '.message // "Test notification from DCS"' 2>/dev/null)
    priority=$(printf '%s' "$body" | jq -r '.priority // "default"' 2>/dev/null)
    title=$(printf '%s' "$body" | jq -r '.title // "DCS Test Notification"' 2>/dev/null)
    tags=$(printf '%s' "$body" | jq -r '.tags // "test,docker"' 2>/dev/null)

    # Each configured channel is tried and reported on its own, so a failing
    # webhook is named as such instead of being blamed on ntfy
    local result="" nt_code nt_sent=() nt_failed=()
    local fields_json
    fields_json=$(jq -nc --arg h "$(hostname 2>/dev/null || echo DCS)" '{host: $h, channel: "all"}')
    if _ntfy_endpoint >/dev/null 2>&1; then
        nt_code=$(_ntfy_send "$title" "$message" "$priority" "$tags") || true
        if [[ "$nt_code" =~ ^2 ]]; then nt_sent+=("ntfy ($(_ntfy_endpoint))"); else nt_failed+=("ntfy at $(_ntfy_endpoint) answered ${nt_code:-0} (0 = unreachable; check NTFY_URL, NTFY_TOPIC and NTFY_TOKEN)"); fi
        result="$nt_code"
    fi
    if _discord_webhook >/dev/null 2>&1; then
        nt_code=$(_discord_send "$title" "$message" "$priority" "test" "$fields_json") || true
        if [[ "$nt_code" =~ ^2 ]]; then nt_sent+=("Discord"); else nt_failed+=("Discord answered ${nt_code:-0} (0 = unreachable; 401/404 mean the webhook URL is wrong or was deleted)"); fi
        [[ -n "$result" && ! "$result" =~ ^2 ]] || result="$nt_code"
    fi

    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    # Log to history
    _init_notifications_file
    [[ "$result" =~ ^[0-9]+$ ]] || result=0
    local entry
    entry=$(jq -n --arg ts "$ts" --arg title "$title" --arg priority "$priority" --argjson code "$((10#$result))" \
        '{timestamp: $ts, type: "test", title: $title, priority: $priority, status_code: $code}')
    _api_jq_update_file "$NOTIFICATIONS_FILE" --argjson entry "$entry" '.history = (.history + [$entry]) | .history = .history[-100:]'

    local sent_list="" failed_list=""
    (( ${#nt_sent[@]} )) && sent_list=$(IFS=,; printf '%s' "${nt_sent[*]}") && sent_list="${sent_list//,/ and }"
    (( ${#nt_failed[@]} )) && failed_list=$(printf '%s; ' "${nt_failed[@]}") && failed_list="${failed_list%; }"
    if (( ${#nt_failed[@]} == 0 )); then
        _api_success "{\"success\": true, \"message\": \"Test notification sent to $(_api_json_escape "$sent_list")\", \"status_code\": $result, \"timestamp\": \"$ts\"}"
    elif (( ${#nt_sent[@]} )); then
        _api_error 502 "Sent to $sent_list, but $failed_list"
    else
        _api_error 502 "$failed_list"
    fi
}

# =============================================================================
# FEATURE: SYSTEM SNAPSHOTS
# =============================================================================

SNAPSHOTS_DIR="$BASE_DIR/.snapshots"

# Snapshot file names are generated by handle_snapshot_create; only those may
# be downloaded, restored or deleted.
_api_validate_snapshot_name() {
    if [[ ! "$1" =~ ^dcs-snapshot-[0-9]{8}-[0-9]{6}\.tar\.gz$ ]]; then
        _api_error 400 "Invalid snapshot name"
        return 1
    fi
    return 0
}

# GET /snapshots — Configuration snapshots
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

        # Read label from manifest if exists (archives are created with -C dir .,
        # so the member is ./manifest.json)
        local label=""
        local manifest
        manifest=$(tar -xzOf "$f" ./manifest.json 2>/dev/null || tar -xzOf "$f" manifest.json 2>/dev/null)
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

# POST /snapshots/create — Create a configuration snapshot (compose files, .env files, templates)
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
    # Snapshots contain .env files: keep the staging area and archive private
    umask 077
    if ! tmpdir=$(mktemp -d /tmp/dcs-snapshot-XXXXXX 2>/dev/null) || [[ -z "$tmpdir" ]]; then
        _api_error 500 "Could not create a temporary directory"
        return
    fi

    # Create manifest
    local hostname_val
    hostname_val=$(hostname 2>/dev/null || echo "unknown")
    cat > "$tmpdir/manifest.json" <<MANIFESTEOF
{"version": "1.0", "label": "$(_api_json_escape "$label")", "created_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')", "hostname": "$hostname_val", "dcs_version": "${DCS_VERSION}"}
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

    # Copy api-auth: operational state only. Session tokens, invite codes,
    # terminal sessions and rate-limit state never belong in a snapshot (an
    # unused admin invite inside an archive is an admin account).
    local -a _snap_auth_files=(alerts.json automations.json notifications.json deploy-history.json update-history.json users.json)
    local _saf
    for _saf in "${_snap_auth_files[@]}"; do
        [[ -f "$BASE_DIR/.api-auth/$_saf" ]] && cp "$BASE_DIR/.api-auth/$_saf" "$tmpdir/api-auth/" 2>/dev/null
    done

    # Copy templates if they exist
    [[ -d "$BASE_DIR/.templates" ]] && cp -r "$BASE_DIR/.templates" "$tmpdir/templates" 2>/dev/null
    # Encrypted secrets travel too (never the master key)
    if compgen -G "$BASE_DIR/.secrets/*.enc" >/dev/null 2>&1; then
        mkdir -p "$tmpdir/secrets" && cp "$BASE_DIR/.secrets/"*.enc "$tmpdir/secrets/" 2>/dev/null
    fi

    # Create archive
    tar -czf "$SNAPSHOTS_DIR/$filename" -C "$tmpdir" . 2>/dev/null
    rm -rf "$tmpdir"

    local fsize
    fsize=$(du -h "$SNAPSHOTS_DIR/$filename" 2>/dev/null | awk '{print $1}')

    _api_success "{\"success\": true, \"filename\": \"$(_api_json_escape "$filename")\", \"label\": \"$(_api_json_escape "$label")\", \"size\": \"$fsize\", \"timestamp\": \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\"}"
}

# GET /snapshots/{snapshot}/download — Download a snapshot archive
handle_snapshot_download() {
    local snap_id="$1"
    local filepath="$SNAPSHOTS_DIR/$snap_id"

    _api_validate_snapshot_name "$snap_id" || return
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

# POST /snapshots/{snapshot}/restore — Restore a snapshot (confirmation required, policy-scanned)
handle_snapshot_restore() {
    local snap_id="$1"
    local body="$2"
    local filepath="$SNAPSHOTS_DIR/$snap_id"

    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    _api_validate_snapshot_name "$snap_id" || return
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

    # List once (a `tar | grep -q` pipeline can be cut short by SIGPIPE under
    # pipefail, which would make a match look like a pass)
    local _listing
    if ! _listing=$(tar -tvzf "$filepath" 2>/dev/null); then
        _api_error 400 "Snapshot archive is corrupt or invalid"
        return
    fi

    # SECURITY: Check for path traversal in archive before extracting
    if awk '{print $NF}' <<< "$_listing" | grep -qE '^\.\./|/\.\./|^/'; then
        _api_error 403 "Snapshot contains path traversal entries — refusing to extract"
        return
    fi

    # SECURITY: Check for symlinks (symlink-following traversal attack)
    if grep -q '^l' <<< "$_listing"; then
        _api_error 403 "Snapshot contains symbolic links — refusing to extract for security"
        return
    fi

    local tmpdir
    umask 077
    if ! tmpdir=$(mktemp -d /tmp/dcs-restore-XXXXXX 2>/dev/null) || [[ -z "$tmpdir" ]]; then
        _api_error 500 "Could not create a temporary directory"
        return
    fi
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

    # Restore stacks (with compose security scanning); rejected stacks are
    # skipped entirely and reported, never half-restored
    local -a _skipped=()
    if [[ -d "$tmpdir/stacks" ]]; then
        for stack_dir in "$tmpdir/stacks"/*/; do
            [[ ! -d "$stack_dir" ]] && continue
            local sname
            sname=$(basename "$stack_dir")
            [[ "$sname" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || { _skipped+=("\"$(_api_json_escape "$sname")\""); continue; }
            if [[ -f "$stack_dir/docker-compose.yml" ]]; then
                local compose_content _scan_msg
                compose_content=$(cat "$stack_dir/docker-compose.yml" 2>/dev/null)
                if ! _scan_msg=$(_API_SCAN_QUIET=true _api_scan_compose_security "$compose_content" "snapshot restore ($sname)" "deploy"); then
                    _skipped+=("\"$(_api_json_escape "$sname: $_scan_msg")\"")
                    continue
                fi
                mkdir -p "$COMPOSE_DIR/$sname"
                cp "$stack_dir/docker-compose.yml" "$COMPOSE_DIR/$sname/" 2>/dev/null
            fi
            mkdir -p "$COMPOSE_DIR/$sname"
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

    local _skipped_json="[]"
    if [[ ${#_skipped[@]} -gt 0 ]]; then
        _skipped_json=$(printf '%s,' "${_skipped[@]}")
        _skipped_json="[${_skipped_json%,}]"
    fi
    _api_success "{\"success\": true, \"message\": \"Snapshot restored successfully\", \"filename\": \"$(_api_json_escape "$snap_id")\", \"skipped_stacks\": $_skipped_json}"
}

# DELETE /snapshots/{snapshot} — Delete a snapshot
handle_snapshot_delete() {
    local snap_id="$1"
    local filepath="$SNAPSHOTS_DIR/$snap_id"

    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    _api_validate_snapshot_name "$snap_id" || return
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

# GET /stacks/{stack}/compose/history — Saved versions of a stack's compose file
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

# POST /stacks/{stack}/compose/rollback — Restore a saved compose version
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
    if [[ ! "$version_id" =~ ^v_[0-9]{8}-[0-9]{6}(-[0-9]+)?$ ]]; then
        _api_error 400 "Invalid version ID"
        return
    fi

    local history_dir="$COMPOSE_HISTORY_DIR/$stack"
    local version_file="$history_dir/${version_id}.yml"

    if [[ ! -f "$version_file" ]]; then
        _api_error 404 "Version not found: $version_id"
        return
    fi

    # The archived version goes through the same policy as a fresh edit
    local _scan_mode="strict"
    [[ -f "$COMPOSE_DIR/$stack/.dcs-trusted-templates" ]] && _scan_mode="deploy"
    _api_scan_compose_security "$(cat "$version_file")" "rollback of $stack" "$_scan_mode" || return

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

    # Validate version_id (only ids _save_compose_version generates)
    if [[ ! "$version_id" =~ ^v_[0-9]{8}-[0-9]{6}(-[0-9]+)?$ ]]; then
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
    local version_id="v_${ts}-$$"

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
    # Keep the on-disk copies in step with the 50-entry history
    ls -1t "$history_dir"/v_*.yml 2>/dev/null | tail -n +51 | xargs -r rm -f
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

# GET /templates/deploy-history — Template deploy and undeploy events
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

# GET /templates — Available templates
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

# GET /templates/{template} — Template metadata, compose file and .env
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

    # Secrets the template references (${SECRETS_NAME} or ${SECRETS.NAME}) and whether they exist yet
    local secrets_json="[]" _sn
    while IFS= read -r _sn; do
        [[ -n "$_sn" ]] || continue
        secrets_json=$(jq -c --arg n "$_sn" --argjson e "$(secrets_exists "$_sn" && echo true || echo false)" '. + [{name: $n, exists: $e}]' <<< "$secrets_json")
    done < <(cat "$tdir/docker-compose.yml" "$tdir/.env" 2>/dev/null | grep -oE 'SECRETS[._][A-Za-z_][A-Za-z0-9_]*' | sed -E 's/^SECRETS[._]//' | sort -u)

    _api_success "{\"template\": $meta, \"compose\": \"$compose_content\", \"env\": \"$env_content\", \"secrets\": $secrets_json}"
}

# GET /traefik/status — Check if Traefik is deployed and return domain
handle_traefik_status() {
    local traefik_active="false" traefik_domain=""

    # Traefik is active when a stack runs it and its custom_routes directory exists
    if [[ -n "$(_find_traefik_routes_dir)" ]]; then
        local _s
        for _s in $(_api_get_stacks); do
            if grep -q 'container_name: Traefik\|image: traefik' "$COMPOSE_DIR/$_s/docker-compose.yml" 2>/dev/null; then
                traefik_active="true"
                break
            fi
        done
    fi
    [[ "$traefik_active" == "true" ]] && traefik_domain=$(_find_traefik_domain)

    _api_success "{\"active\": $traefik_active, \"domain\": \"$(_api_json_escape "$traefik_domain")\"}"
}

# A subdomain label chain such as "app" or "grafana.internal" — nothing that
# could act as a sed/regex/JSON metacharacter
_api_validate_subdomain() {
    local s="$1"
    if [[ -z "$s" || ${#s} -gt 200 || ! "$s" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$ ]]; then
        _api_error 400 "Invalid subdomain (use lowercase letters, digits and hyphens)"
        return 1
    fi
    return 0
}

# Helper: find Traefik custom_routes directory (shared by all route handlers)
# Uses the SAME per-stack resolution as handle_traefik_status() which is known to work
_find_traefik_routes_dir() {
    local _s

    # 1. Per-stack resolution: ./App-Data → $COMPOSE_DIR/$stack/App-Data
    #    This is the pattern used by handle_traefik_status() and template deploy
    for _s in $(_api_get_stacks); do
        local _ad="${APP_DATA_DIR:-$COMPOSE_DIR/$_s/App-Data}"
        [[ "$_ad" == ./* ]] && _ad="$COMPOSE_DIR/$_s/${_ad#./}"
        [[ -d "$_ad/Traefik/custom_routes" ]] && { printf '%s' "$_ad/Traefik/custom_routes"; return; }
    done

    # 2. Global APP_DATA_DIR (fallback for layouts with root-level App-Data)
    local _gad="${APP_DATA_DIR:-./App-Data}"
    [[ "$_gad" == ./* ]] && _gad="$BASE_DIR/${_gad#./}"
    [[ -d "$_gad/Traefik/custom_routes" ]] && { printf '%s' "$_gad/Traefik/custom_routes"; return; }

    # 3. find fallback — search entire BASE_DIR
    local _dir
    _dir=$(find "$BASE_DIR" -maxdepth 6 -type d -name "custom_routes" -path "*/Traefik/*" 2>/dev/null | head -1)
    [[ -n "$_dir" ]] && printf '%s' "$_dir"
}

# Helper: read TRAEFIK_DOMAIN from env files
_find_traefik_domain() {
    local _d="" _ef
    for _ef in "$COMPOSE_DIR"/*/".env" "$BASE_DIR/.env"; do
        [[ -f "$_ef" ]] || continue
        _d=$(grep -m1 '^TRAEFIK_DOMAIN=' "$_ef" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        [[ -n "$_d" ]] && { printf '%s' "$_d"; return; }
    done
    for _ef in "$COMPOSE_DIR"/*/".env" "$BASE_DIR/.env"; do
        [[ -f "$_ef" ]] || continue
        _d=$(grep -m1 '^PROXY_DOMAIN=' "$_ef" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")
        [[ -n "$_d" ]] && { printf '%s' "$_d"; return; }
    done
}

# =============================================================================
# CLOUDFLARE — token discovery
# =============================================================================
# The API token comes from, in order: the secret CF_DNS_API_TOKEN, the
# CF_DNS_API_TOKEN value of the root .env, or a stack .env. A value written
# as ${SECRETS_NAME} in any of those is resolved through the secrets store,
# so the token never has to sit in plain text. CF_TOKEN_SOURCE tells where
# the token came from ("secret", "env", "stack-env").

CF_API_BASE="https://api.cloudflare.com/client/v4"
CF_HTTP_CODE="000"
CF_BODY=""
CF_MUTABLE_TYPES=" A AAAA CNAME TXT MX NS "

# Resolve a ${SECRETS_NAME} placeholder to the stored value (other values pass through)
_cf_resolve_value() {
    local v="$1"
    if [[ "$v" =~ ^\$\{SECRETS_([A-Za-z_][A-Za-z0-9_]*)\}$ ]]; then
        secrets_get "${BASH_REMATCH[1]}" 2>/dev/null || true
    else
        printf '%s' "$v"
    fi
}

# Helper: the Cloudflare token (secret first, then env files) as
# "source<TAB>token" — source is secret, env or stack-env. Prints nothing when
# there is none; callers test for emptiness, never the exit status.
_find_cf_token_ex() {
    local t=""
    t=$(secrets_get CF_DNS_API_TOKEN 2>/dev/null) || t=""
    if [[ -n "$t" ]]; then printf 'secret\t%s' "$t"; return 0; fi
    if [[ -n "${CF_DNS_API_TOKEN:-}" ]]; then
        t=$(_cf_resolve_value "$CF_DNS_API_TOKEN")
        if [[ -n "$t" ]]; then printf 'env\t%s' "$t"; return 0; fi
    fi
    local _ef
    for _ef in "$BASE_DIR/.env" "$COMPOSE_DIR"/*/".env"; do
        [[ -f "$_ef" ]] || continue
        t=$(grep -m1 '^CF_DNS_API_TOKEN=' "$_ef" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'") || t=""
        t=$(_cf_resolve_value "$t")
        if [[ -n "$t" ]]; then
            if [[ "$_ef" == "$BASE_DIR/.env" ]]; then printf 'env\t%s' "$t"; else printf 'stack-env\t%s' "$t"; fi
            return 0
        fi
    done
    return 0
}

# Token only (the common case)
_find_cf_token() {
    local r
    r=$(_find_cf_token_ex)
    printf '%s' "${r#*$'\t'}"
}

# GET /routes — List all Traefik routes with subdomains
# Strategy: scan route YAML files first, then fall back to Traefik's runtime API
# GET /routes — Traefik routes: subdomain, service, stack and target
handle_routes() {
    local traefik_routes_dir
    traefik_routes_dir=$(_find_traefik_routes_dir)
    local traefik_domain
    traefik_domain=$(_find_traefik_domain)

    local -a route_entries=()
    local -A seen_subdomains=()

    # ── Method 1: Scan route YAML files ──
    if [[ -n "$traefik_routes_dir" ]]; then
        while IFS= read -r route_file; do
            [[ -f "$route_file" ]] || continue
            local fname stack_name subdomain url_target
            fname=$(basename "$route_file" .yml)
            stack_name=$(basename "$(dirname "$route_file")")

            [[ "$fname" == ".reload" || "$fname" == ".gitkeep" ]] && continue

            subdomain=$(sed -n 's/.*Host(`\([^`]*\)`).*/\1/p' "$route_file" 2>/dev/null | head -1)
            [[ -z "$subdomain" ]] && continue

            url_target=$(grep -m1 'url:' "$route_file" 2>/dev/null | sed 's/.*url:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d ' ')

            local conflict="false"
            [[ -n "${seen_subdomains[$subdomain]:-}" ]] && conflict="true"
            seen_subdomains["$subdomain"]="$stack_name/$fname"

            route_entries+=("{\"subdomain\": \"$(_api_json_escape "$subdomain")\", \"service\": \"$(_api_json_escape "$fname")\", \"stack\": \"$(_api_json_escape "$stack_name")\", \"target\": \"$(_api_json_escape "$url_target")\", \"conflict\": $conflict}")
        done < <(find "$traefik_routes_dir" \( -name '*.yml' -o -name '*.yaml' \) -type f 2>/dev/null | sort)
    fi

    # ── Method 2: Query Traefik runtime API (fallback when no files found) ──
    if [[ ${#route_entries[@]} -eq 0 ]]; then
        local traefik_api_url=""
        # Try common Traefik API addresses
        for _try_url in "http://Traefik:8080" "http://localhost:8080" "http://traefik:8080"; do
            if curl -sf --max-time 3 "$_try_url/api/version" >/dev/null 2>&1; then
                traefik_api_url="$_try_url"
                break
            fi
        done

        if [[ -n "$traefik_api_url" ]]; then
            local routers_json
            routers_json=$(curl -sf --max-time 10 "$traefik_api_url/api/http/routers" 2>/dev/null)
            if [[ -n "$routers_json" ]]; then
                while IFS= read -r router_line; do
                    [[ -z "$router_line" ]] && continue
                    local r_name r_rule r_service r_provider
                    r_name=$(printf '%s' "$router_line" | jq -r '.name // empty' 2>/dev/null)
                    r_rule=$(printf '%s' "$router_line" | jq -r '.rule // empty' 2>/dev/null)
                    r_service=$(printf '%s' "$router_line" | jq -r '.service // empty' 2>/dev/null)
                    r_provider=$(printf '%s' "$router_line" | jq -r '.provider // empty' 2>/dev/null)

                    # Only include file-provider routes (our custom routes)
                    [[ "$r_provider" != *"file"* ]] && continue

                    # Extract Host() from rule
                    local subdomain=""
                    subdomain=$(printf '%s' "$r_rule" | grep -oP 'Host\(`\K[^`]+' 2>/dev/null || printf '%s' "$r_rule" | sed -n 's/.*Host(`\([^`]*\)`).*/\1/p')
                    [[ -z "$subdomain" ]] && continue

                    # Skip internal Traefik routes (api@internal, etc.)
                    [[ "$r_name" == *"@internal"* ]] && continue

                    # Extract service name from router name (router names are like "servicename-router@file")
                    local svc_name="${r_name%%-router@*}"
                    [[ "$svc_name" == *"@"* ]] && svc_name="${svc_name%%@*}"

                    local conflict="false"
                    [[ -n "${seen_subdomains[$subdomain]:-}" ]] && conflict="true"
                    seen_subdomains["$subdomain"]="api/$svc_name"

                    route_entries+=("{\"subdomain\": \"$(_api_json_escape "$subdomain")\", \"service\": \"$(_api_json_escape "$svc_name")\", \"stack\": \"traefik\", \"target\": \"$(_api_json_escape "$r_service")\", \"conflict\": $conflict}")
                done < <(printf '%s' "$routers_json" | jq -c '.[]' 2>/dev/null)
            fi
        fi
    fi

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
    subdomain="${subdomain,,}"
    _api_validate_subdomain "$subdomain" || return

    local traefik_routes_dir traefik_domain
    traefik_routes_dir=$(_find_traefik_routes_dir)
    traefik_domain=$(_find_traefik_domain)

    local fqdn="${subdomain}.${traefik_domain}"
    local available="true"
    local existing_stack="" existing_service=""

    if [[ -n "$traefik_routes_dir" ]]; then
        # Search all route files for this subdomain
        while IFS= read -r route_file; do
            [[ -f "$route_file" ]] || continue
            if grep -qF "Host(\`${fqdn}\`)" "$route_file" 2>/dev/null; then
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

    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi
    _api_validate_stack_name "$stack" || return
    _api_validate_resource_name "$service" "service" || return

    local new_subdomain
    new_subdomain=$(printf '%s' "$body" | jq -r '.subdomain // empty' 2>/dev/null)
    [[ -z "$new_subdomain" ]] && { _api_error 400 "subdomain is required"; return; }
    new_subdomain="${new_subdomain,,}"
    # The value is spliced into a sed script, a grep pattern and a Cloudflare
    # request below — only a plain label chain is acceptable
    _api_validate_subdomain "$new_subdomain" || return

    local traefik_routes_dir traefik_domain
    traefik_routes_dir=$(_find_traefik_routes_dir)
    traefik_domain=$(_find_traefik_domain)
    [[ -z "$traefik_routes_dir" ]] && { _api_error 404 "Traefik routes directory not found"; return; }

    local route_file="$traefik_routes_dir/$stack/${service}.yml"
    [[ ! -f "$route_file" ]] && { _api_error 404 "Route file not found: $stack/$service"; return; }

    # Check if new subdomain conflicts with existing routes
    local new_fqdn="${new_subdomain}.${traefik_domain}"
    local conflict_file
    conflict_file=$(grep -rlF "Host(\`${new_fqdn}\`)" "$traefik_routes_dir" 2>/dev/null | grep -vF "$route_file" | head -1)
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
    local _cf_token
    _cf_token=$(_find_cf_token)

    if [[ -n "$_cf_token" && -n "$old_fqdn" && "$old_fqdn" != "$new_fqdn" ]]; then
        # Delete old DNS record in background (keep the whole label chain so a
        # nested subdomain never deletes a sibling record)
        _cloudflare_delete_dns "${old_fqdn%."$traefik_domain"}" "$traefik_domain" "$_cf_token" </dev/null >/dev/null 2>&1 &
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
                -d "$(jq -n --arg name "$new_fqdn" --arg content "$traefik_domain" '{type:"CNAME",name:$name,content:$content,proxied:true,ttl:1,comment:"Auto-created by DCS"}')" \
                "$cf_api/zones/$zone_id/dns_records" >/dev/null 2>&1
            printf '[%s] RENAMED %s → %s (route update)\n' "$(date -Iseconds)" "$old_fqdn" "$new_fqdn" >> "$BASE_DIR/.api-auth/cf-dns-audit.log" 2>/dev/null
        ) </dev/null >/dev/null 2>&1 &
    fi

    _api_audit_log "${CLIENT_IP:-unknown}" "ROUTE_UPDATE" "${AUTH_USERNAME:-unknown}" "Renamed ${old_fqdn} → ${new_fqdn}"
    _api_success "{\"success\": true, \"old_subdomain\": \"$(_api_json_escape "$old_fqdn")\", \"new_subdomain\": \"$(_api_json_escape "$new_fqdn")\", \"service\": \"$(_api_json_escape "$service")\", \"stack\": \"$(_api_json_escape "$stack")\"}"
}

# DELETE /routes/:stack/:service — Delete a route file and optionally clean up DNS
handle_route_delete() {
    local stack="$1" service="$2"

    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi
    _api_validate_stack_name "$stack" || return
    _api_validate_resource_name "$service" "service" || return

    local traefik_routes_dir traefik_domain
    traefik_routes_dir=$(_find_traefik_routes_dir)
    traefik_domain=$(_find_traefik_domain)
    [[ -z "$traefik_routes_dir" ]] && { _api_error 404 "Traefik routes directory not found"; return; }

    local route_file="$traefik_routes_dir/$stack/${service}.yml"
    [[ ! -f "$route_file" ]] && { _api_error 404 "Route file not found: $stack/$service"; return; }

    # Read subdomain before deleting
    local fqdn
    fqdn=$(sed -n 's/.*Host(`\([^`]*\)`).*/\1/p' "$route_file" 2>/dev/null | head -1)

    # Delete the route file
    rm -f "$route_file"
    touch "$traefik_routes_dir/.reload" 2>/dev/null

    # Clean up Cloudflare DNS record in background
    local _cf_token
    _cf_token=$(_find_cf_token)
    if [[ -n "$_cf_token" && -n "$fqdn" ]]; then
        _cloudflare_delete_dns "${fqdn%."$traefik_domain"}" "$traefik_domain" "$_cf_token" </dev/null >/dev/null 2>&1 &
    fi

    _api_audit_log "${CLIENT_IP:-unknown}" "ROUTE_DELETE" "${AUTH_USERNAME:-unknown}" "Deleted route ${fqdn} (${stack}/${service})"
    _api_success "{\"success\": true, \"deleted\": \"$(_api_json_escape "$fqdn")\", \"service\": \"$(_api_json_escape "$service")\", \"stack\": \"$(_api_json_escape "$stack")\"}"
}

# =============================================================================
# CLOUDFLARE DNS MANAGEMENT
# =============================================================================
# Records of the DCS zone can be listed, created, changed and deleted like on
# the Cloudflare dashboard. DCS routes are linked to their records, records
# a route needs are protected from accidental deletion, and "sync" creates
# the CNAMEs that routes are missing.

# _cf_request TOKEN METHOD PATH [JSON] → prints "<body>\n<http code>"
_cf_request() {
    local token="$1" method="$2" path="$3" body="${4:-}" out
    local -a args=(-s --max-time 20 -X "$method" -H "Authorization: Bearer $token" -H "Content-Type: application/json" -w $'\n%{http_code}')
    [[ -n "$body" ]] && args+=(--data-binary "$body")
    out=$(curl "${args[@]}" "${CF_API_BASE}${path}" 2>/dev/null) || out=$'\n000'
    printf '%s' "$out"
}

# _cf_call TOKEN METHOD PATH [JSON] → sets CF_BODY and CF_HTTP_CODE in this shell
_cf_call() {
    local raw
    raw=$(_cf_request "$@")
    CF_HTTP_CODE="${raw##*$'\n'}"
    CF_BODY="${raw%$'\n'*}"
    [[ "$CF_HTTP_CODE" =~ ^[0-9]{3}$ ]] || CF_HTTP_CODE="000"
}

_cf_error_message() {
    local m=""
    m=$(printf '%s' "$1" | jq -r '[.errors[]?.message] | join("; ")' 2>/dev/null) || m=""
    [[ -n "$m" ]] && printf '%s' "$m" || printf 'request failed (HTTP %s)' "$CF_HTTP_CODE"
}

# Zone id for a domain, cached in .api-auth/.cf-zone-cache (line 1 domain, line 2 id)
_cf_zone_id() {
    local domain="$1" token="$2" zone_cache="$BASE_DIR/.api-auth/.cf-zone-cache" zid=""
    [[ -z "$domain" || -z "$token" ]] && return 0
    if [[ -f "$zone_cache" && "$(sed -n '1p' "$zone_cache" 2>/dev/null)" == "$domain" ]]; then
        zid=$(sed -n '2p' "$zone_cache" 2>/dev/null) || zid=""
    fi
    if [[ -z "$zid" ]]; then
        zid=$(curl -s --max-time 15 -H "Authorization: Bearer $token" "${CF_API_BASE}/zones?name=${domain}&status=active" 2>/dev/null | jq -r '.result[0].id // empty' 2>/dev/null) || zid=""
        [[ -n "$zid" ]] && printf '%s\n%s\n' "$domain" "$zid" > "$zone_cache" 2>/dev/null
    fi
    printf '%s' "$zid"
}

# All records of a zone (every page). Prints a JSON array, or "__ERROR__:message".
_cf_records_all() {
    local token="$1" zone="$2" page=1 all='[]' count
    while :; do
        _cf_call "$token" GET "/zones/$zone/dns_records?per_page=100&page=$page"
        if [[ "$CF_HTTP_CODE" != "200" ]]; then
            [[ "$page" -eq 1 ]] && { printf '__ERROR__:%s' "$(_cf_error_message "$CF_BODY")"; return 0; }
            break
        fi
        all=$(jq -c --argjson add "$(printf '%s' "$CF_BODY" | jq -c '.result // []' 2>/dev/null || echo '[]')" '. + $add' <<< "$all" 2>/dev/null) || break
        count=$(printf '%s' "$CF_BODY" | jq -r '.result | length' 2>/dev/null) || count=0
        (( count < 100 )) && break
        page=$((page + 1))
        (( page > 20 )) && break
    done
    printf '%s' "$all"
}

# {fqdn: "stack/service"} for every Traefik route file
_dns_route_map() {
    local dir f host
    dir=$(_find_traefik_routes_dir)
    [[ -n "$dir" ]] || { printf '{}'; return 0; }
    {
        while IFS= read -r f; do
            host=$(sed -n 's/.*Host(`\([^`]*\)`).*/\1/p' "$f" 2>/dev/null | head -1) || host=""
            [[ -n "$host" ]] || continue
            jq -nc --arg h "$host" --arg v "$(basename "$(dirname "$f")")/$(basename "$f" .yml)" '{($h): $v}'
        done < <(find "$dir" \( -name '*.yml' -o -name '*.yaml' \) -type f 2>/dev/null | sort)
    } | jq -sc 'add // {}' 2>/dev/null || printf '{}'
}

# The zone to work on: an explicit id or name, or the DCS domain. Prints "id name".
_dns_target_zone() {
    local token="$1" want="${2:-}" domain id="" name=""
    domain=$(_find_traefik_domain)
    if [[ -n "$want" ]]; then
        if [[ "$want" =~ ^[0-9a-f]{32}$ ]]; then
            _cf_call "$token" GET "/zones/$want"
            [[ "$CF_HTTP_CODE" == "200" ]] || { echo "zone not found"; return 1; }
            name=$(printf '%s' "$CF_BODY" | jq -r '.result.name // empty' 2>/dev/null) || name=""
            id="$want"
        else
            [[ "$want" =~ ^[a-z0-9.-]{1,253}$ ]] || { echo "invalid zone"; return 1; }
            _cf_call "$token" GET "/zones?name=$want&status=active"
            id=$(printf '%s' "$CF_BODY" | jq -r '.result[0].id // empty' 2>/dev/null) || id=""
            [[ -n "$id" ]] || { echo "zone $want not found"; return 1; }
            name="$want"
        fi
    else
        [[ -n "$domain" ]] || { echo "no domain is configured (TRAEFIK_DOMAIN)"; return 1; }
        id=$(_cf_zone_id "$domain" "$token")
        [[ -n "$id" ]] || { echo "no active Cloudflare zone named $domain is visible to this token"; return 1; }
        name="$domain"
    fi
    printf '%s %s' "$id" "$name"
}

_DNS_JQ_DEFS='def dcs_record($zone; $domain; $routes): {
    id, type, name, content,
    ttl: (.ttl // 1), proxied: (.proxied // false), proxiable: (.proxiable // false),
    priority: (.priority // null), comment: (.comment // ""), tags: (.tags // []), locked: (.locked // false),
    created_on: (.created_on // ""), modified_on: (.modified_on // ""),
    subdomain: (if .name == $zone then "@" elif (.name | endswith("." + $zone)) then (.name | .[0:(length - ($zone | length) - 1)]) else .name end),
    managed: ((.comment // "") | test("DCS")),
    route: ($routes[.name] // null),
    points_to_dcs: (.type == "CNAME" and $domain != "" and .content == $domain),
    editable: (([.type] | inside(["A","AAAA","CNAME","TXT","MX","NS"])) and ((.locked // false) | not))
  };'

# Normalise and validate a record. Prints the Cloudflare payload, or an error
# message with exit status 1.
_dns_validate_record() {
    local zone="$1" type="${2^^}" name="${3,,}" content="$4" ttl="${5:-1}" proxied="${6:-false}" priority="${7:-}" comment="${8:-}"
    [[ "$CF_MUTABLE_TYPES" == *" $type "* ]] || { echo "type must be one of A, AAAA, CNAME, TXT, MX or NS"; return 1; }
    name="${name%.}"
    name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
    [[ -z "$name" || "$name" == "@" ]] && name="$zone"
    [[ "$name" == "$zone" || "$name" == *".$zone" ]] || name="${name}.${zone}"
    local label_re='^(\*\.)?([a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
    [[ "$name" == "$zone" || "$name" =~ $label_re ]] || { echo "name '$name' is not a valid hostname under $zone"; return 1; }
    (( ${#name} <= 253 )) || { echo "name is too long"; return 1; }
    content="${content#"${content%%[![:space:]]*}"}"; content="${content%"${content##*[![:space:]]}"}"
    [[ -n "$content" ]] || { echo "content is required"; return 1; }
    [[ "$content" =~ [[:cntrl:]] ]] && { echo "content contains control characters"; return 1; }
    local host_re='^([a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?\.)*[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.?$'
    case "$type" in
        A)
            _crowdsec_valid_ip "$content" || { echo "content must be an IPv4 address"; return 1; } ;;
        AAAA)
            [[ "$content" =~ ^[0-9a-fA-F:]+$ && "$content" == *:* && ${#content} -le 45 ]] || { echo "content must be an IPv6 address"; return 1; } ;;
        CNAME|NS)
            content="${content,,}"
            [[ "$content" =~ $host_re ]] || { echo "content must be a hostname"; return 1; }
            [[ "$type" == "CNAME" && "${content%.}" == "$name" ]] && { echo "a CNAME cannot point to itself"; return 1; } ;;
        MX)
            content="${content,,}"
            [[ "$content" =~ $host_re ]] || { echo "content must be a mail server hostname"; return 1; }
            [[ -z "$priority" ]] && priority=10 ;;
        TXT)
            (( ${#content} <= 2048 )) || { echo "TXT content is limited to 2048 characters"; return 1; } ;;
    esac
    [[ "$ttl" =~ ^[0-9]+$ ]] || { echo "ttl must be a number of seconds (1 = automatic)"; return 1; }
    [[ "$ttl" -eq 1 || ( "$ttl" -ge 60 && "$ttl" -le 86400 ) ]] || { echo "ttl must be 1 (automatic) or between 60 and 86400 seconds"; return 1; }
    case "$proxied" in true|false) ;; *) echo "proxied must be true or false"; return 1 ;; esac
    if [[ "$type" != "A" && "$type" != "AAAA" && "$type" != "CNAME" ]]; then proxied=false; fi
    # Cloudflare forces the automatic TTL on proxied records
    [[ "$proxied" == "true" ]] && ttl=1
    if [[ -n "$priority" ]]; then
        [[ "$priority" =~ ^[0-9]+$ && "$priority" -le 65535 ]] || { echo "priority must be between 0 and 65535"; return 1; }
    fi
    [[ "$comment" =~ [[:cntrl:]] ]] && { echo "comment contains control characters"; return 1; }
    (( ${#comment} <= 100 )) || { echo "comment is limited to 100 characters"; return 1; }
    jq -nc --arg t "$type" --arg n "$name" --arg c "$content" --argjson ttl "$ttl" --argjson p "$proxied" --arg pr "$priority" --arg cm "$comment" \
        '{type: $t, name: $n, content: $c, ttl: $ttl, proxied: $p} + (if $pr != "" then {priority: ($pr | tonumber)} else {} end) + {comment: $cm}'
}

# Map a Cloudflare error to an API status: 400 for rejected input, 409 for
# duplicates, 502 for everything else
_dns_cf_failure() {
    local body="$1" msg code=502
    msg=$(_cf_error_message "$body")
    [[ "$CF_HTTP_CODE" == "400" ]] && code=400
    [[ "$msg" == *"already exist"* || "$msg" == *"identical record"* ]] && code=409
    [[ "$CF_HTTP_CODE" == "403" ]] && { code=403; msg="the token lacks permission for this zone or action ($msg)"; }
    if [[ "$msg" == *"Invalid request headers"* || "$msg" == *"Authentication error"* || "$msg" == *"Invalid API Token"* || "$CF_HTTP_CODE" == "401" ]]; then
        code=502; msg="Cloudflare rejected the API token — check the secret CF_DNS_API_TOKEN ($msg)"
    fi
    _api_error "$code" "Cloudflare: $msg"
}

_dns_audit_line() {
    printf '[%s] %s (%s)\n' "$(date -Iseconds)" "$1" "${AUTH_USERNAME:-api}" >> "$BASE_DIR/.api-auth/cf-dns-audit.log" 2>/dev/null || true
}

# GET /dns/status — Cloudflare integration: where the token comes from, whether it is valid, the zone
handle_dns_status() {
    local domain token src="" verify="unknown" zone_json="null" zone_id="" cf_configured=false
    domain=$(_find_traefik_domain)
    local _tok_ex
    _tok_ex=$(_find_cf_token_ex)
    token="${_tok_ex#*$'\t'}"
    [[ -n "$token" ]] && src="${_tok_ex%%$'\t'*}"
    if [[ -n "$token" ]]; then
        cf_configured=true
        _cf_call "$token" GET "/user/tokens/verify"
        if [[ "$CF_HTTP_CODE" == "200" ]]; then
            verify=$(printf '%s' "$CF_BODY" | jq -r '.result.status // "unknown"' 2>/dev/null) || verify="unknown"
        elif [[ "$CF_HTTP_CODE" == "000" ]]; then
            verify="unreachable"
        else
            verify="invalid"
        fi
        if [[ -n "$domain" ]]; then
            zone_id=$(_cf_zone_id "$domain" "$token")
            if [[ -n "$zone_id" ]]; then
                _cf_call "$token" GET "/zones/$zone_id"
                if [[ "$CF_HTTP_CODE" == "200" ]]; then
                    zone_json=$(printf '%s' "$CF_BODY" | jq -c '{id: .result.id, name: .result.name, status: .result.status, name_servers: (.result.name_servers // []), plan: (.result.plan.name // "")}' 2>/dev/null) || zone_json="null"
                else
                    zone_json=$(jq -nc --arg id "$zone_id" --arg n "$domain" '{id: $id, name: $n, status: "unknown", name_servers: [], plan: ""}')
                fi
            fi
        fi
    fi
    _api_success "$(jq -nc --arg d "$domain" --arg s "$src" --arg v "$verify" --argjson c "$cf_configured" --argjson z "$zone_json" \
        '{cf_configured: $c, token_source: $s, token_status: $v, domain: $d, zone: $z, zone_found: ($z != null),
          hint: (if $c then (if $z == null and $d != "" then "No active Cloudflare zone named " + $d + " is visible to this token" else "" end)
                 elif $d == "" then "Set the domain (TRAEFIK_DOMAIN, from the Traefik template) so DCS knows which zone to manage"
                 else "Store the Cloudflare API token as the secret CF_DNS_API_TOKEN, or set CF_DNS_API_TOKEN in .env" end)}')"
}

# GET /dns/zones — Zones the Cloudflare token can manage
handle_dns_zones() {
    local token
    token=$(_find_cf_token)
    [[ -z "$token" ]] && { _api_error 503 "Cloudflare is not configured: store the API token as the secret CF_DNS_API_TOKEN"; return; }
    _cf_call "$token" GET "/zones?per_page=50&status=active"
    [[ "$CF_HTTP_CODE" == "200" ]] || { _dns_cf_failure "$CF_BODY"; return; }
    _api_success "$(printf '%s' "$CF_BODY" | jq -c '{zones: [.result[] | {id, name, status, name_servers: (.name_servers // []), plan: (.plan.name // "")}], total: (.result | length)}' 2>/dev/null || echo '{"zones": [], "total": 0}')"
}

# GET /dns/records?zone=&type=&search= — DNS records of the zone (all types) with their DCS route links
handle_dns_records() {
    local domain token _tok_ex
    domain=$(_find_traefik_domain)
    _tok_ex=$(_find_cf_token_ex)
    token="${_tok_ex#*$'\t'}"
    if [[ -z "$token" ]]; then
        _api_success "$(jq -nc --arg d "$domain" '{total: 0, records: [], domain: $d, zone: null, cf_configured: false, token_source: "", routes_without_dns: [], hint: "Store the Cloudflare API token as the secret CF_DNS_API_TOKEN, or set CF_DNS_API_TOKEN in .env"}')"
        return
    fi
    local src="${_tok_ex%%$'\t'*}" zone_info zone_id="" zone_name=""
    if ! zone_info=$(_dns_target_zone "$token" "${QUERY_PARAMS[zone]:-}"); then
        _api_success "$(jq -nc --arg d "$domain" --arg s "$src" --arg e "$zone_info" '{total: 0, records: [], domain: $d, zone: null, cf_configured: true, token_source: $s, routes_without_dns: [], error: $e}')"
        return
    fi
    read -r zone_id zone_name <<< "$zone_info"
    local records
    records=$(_cf_records_all "$token" "$zone_id")
    [[ "$records" == __ERROR__:* ]] && { _api_error 502 "Cloudflare: ${records#__ERROR__:}"; return; }
    local routes want_type search
    routes=$(_dns_route_map)
    want_type="${QUERY_PARAMS[type]:-}"; want_type="${want_type^^}"
    [[ "$want_type" =~ ^[A-Z]{0,6}$ ]] || want_type=""
    search="${QUERY_PARAMS[search]:-}"; search="${search,,}"
    local out
    out=$(printf '%s' "$records" | jq -c --arg zone "$zone_name" --arg domain "$domain" --argjson routes "$routes" --arg t "$want_type" --arg q "$search" --arg src "$src" --arg zid "$zone_id" "$_DNS_JQ_DEFS"'
        [ .[] | dcs_record($zone; $domain; $routes) ] as $all
        | ($all
           | map(select($t == "" or .type == $t))
           | map(select($q == "" or ((.name + " " + .content + " " + .comment) | ascii_downcase | contains($q))))
           | sort_by((if .type == "A" or .type == "AAAA" then 0 elif .type == "CNAME" then 1 else 2 end), .name)) as $recs
        | ($routes | to_entries
           | map(select(.key == $zone or (.key | endswith("." + $zone))))
           | map(select(.key as $h | ($all | map(select(.name == $h and (.type == "A" or .type == "AAAA" or .type == "CNAME"))) | length) == 0))
           | map({fqdn: .key, route: .value})) as $missing
        | {total: ($recs | length), all_total: ($all | length), records: $recs, domain: $domain, zone: {id: $zid, name: $zone},
           cf_configured: true, token_source: $src, routes_without_dns: $missing}' 2>/dev/null) \
        || { _api_error 500 "Could not process the Cloudflare response"; return; }
    _api_success "$out"
}

# POST /dns/records — Create a record {type, name, content, ttl, proxied, priority, comment, zone}
handle_dns_record_create() {
    local body="$1"
    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi
    local type name content ttl proxied priority comment zone_param
    type=$(printf '%s' "$body" | jq -r '.type // empty' 2>/dev/null) || type=""
    name=$(printf '%s' "$body" | jq -r '.name // empty' 2>/dev/null) || name=""
    content=$(printf '%s' "$body" | jq -r '.content // empty' 2>/dev/null) || content=""
    ttl=$(printf '%s' "$body" | jq -r '.ttl // 1' 2>/dev/null) || ttl=1
    proxied=$(printf '%s' "$body" | jq -r 'if .proxied == true then "true" else "false" end' 2>/dev/null) || proxied=false
    priority=$(printf '%s' "$body" | jq -r 'if .priority == null then "" else (.priority | tostring) end' 2>/dev/null) || priority=""
    comment=$(printf '%s' "$body" | jq -r '.comment // ""' 2>/dev/null) || comment=""
    zone_param=$(printf '%s' "$body" | jq -r '.zone // empty' 2>/dev/null) || zone_param=""
    [[ "$CF_MUTABLE_TYPES" == *" ${type^^} "* ]] || { _api_error 400 "type must be one of A, AAAA, CNAME, TXT, MX or NS"; return; }
    [[ -n "$content" ]] || { _api_error 400 "content is required"; return; }
    local token
    token=$(_find_cf_token)
    [[ -z "$token" ]] && { _api_error 503 "Cloudflare is not configured: store the API token as the secret CF_DNS_API_TOKEN"; return; }
    local zone_info zone_id="" zone_name=""
    if ! zone_info=$(_dns_target_zone "$token" "$zone_param"); then _api_error 404 "$zone_info"; return; fi
    read -r zone_id zone_name <<< "$zone_info"
    local payload
    if ! payload=$(_dns_validate_record "$zone_name" "$type" "$name" "$content" "$ttl" "$proxied" "$priority" "$comment"); then
        _api_error 400 "$payload"; return
    fi
    _cf_call "$token" POST "/zones/$zone_id/dns_records" "$payload"
    [[ "$CF_HTTP_CODE" == "200" ]] || { _dns_cf_failure "$CF_BODY"; return; }
    local rec _dns_summary
    rec=$(printf '%s' "$CF_BODY" | jq -c --arg zone "$zone_name" --arg domain "$(_find_traefik_domain)" --argjson routes "$(_dns_route_map)" "$_DNS_JQ_DEFS"'.result | dcs_record($zone; $domain; $routes)' 2>/dev/null) || rec='{}'
    _dns_summary=$(printf '%s' "$payload" | jq -r '"\(.type) \(.name) -> \(.content)"' 2>/dev/null) || _dns_summary="record"
    _dns_audit_line "CREATED $_dns_summary"
    _api_audit_log "${CLIENT_IP:-unknown}" "DNS_RECORD_CREATE" "${AUTH_USERNAME:-unknown}" "$_dns_summary"
    _api_success "{\"success\": true, \"record\": $rec}"
}

# PUT /dns/records/{id} — Change a record's type, name, content, TTL, proxy status, priority or comment
handle_dns_record_update() {
    local id="$1" body="$2"
    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi
    [[ "$id" =~ ^[0-9a-f]{32}$ ]] || { _api_error 400 "Invalid record id"; return; }
    printf '%s' "$body" | jq -e 'type == "object"' >/dev/null 2>&1 || { _api_error 400 "Invalid JSON body"; return; }
    local token
    token=$(_find_cf_token)
    [[ -z "$token" ]] && { _api_error 503 "Cloudflare is not configured: store the API token as the secret CF_DNS_API_TOKEN"; return; }
    local zone_param zone_info zone_id="" zone_name=""
    zone_param=$(printf '%s' "$body" | jq -r '.zone // empty' 2>/dev/null) || zone_param=""
    if ! zone_info=$(_dns_target_zone "$token" "$zone_param"); then _api_error 404 "$zone_info"; return; fi
    read -r zone_id zone_name <<< "$zone_info"
    _cf_call "$token" GET "/zones/$zone_id/dns_records/$id"
    [[ "$CF_HTTP_CODE" == "200" ]] || { _api_error 404 "Record not found in zone $zone_name"; return; }
    local merged
    merged=$(printf '%s' "$CF_BODY" | jq -c --argjson b "$body" '.result as $r | {
        type: ($b.type // $r.type), name: ($b.name // $r.name), content: ($b.content // $r.content),
        ttl: (if $b.ttl == null then ($r.ttl // 1) else $b.ttl end),
        proxied: (if $b.proxied == null then ($r.proxied // false) else $b.proxied end),
        priority: (if $b.priority == null then $r.priority else $b.priority end),
        comment: (if $b.comment == null then ($r.comment // "") else $b.comment end)}' 2>/dev/null) || merged=""
    [[ -n "$merged" ]] || { _api_error 400 "Invalid JSON body"; return; }
    local type name content ttl proxied priority comment
    type=$(printf '%s' "$merged" | jq -r '.type // empty'); name=$(printf '%s' "$merged" | jq -r '.name // empty')
    content=$(printf '%s' "$merged" | jq -r '.content // empty'); ttl=$(printf '%s' "$merged" | jq -r '.ttl // 1')
    proxied=$(printf '%s' "$merged" | jq -r 'if .proxied == true then "true" else "false" end')
    priority=$(printf '%s' "$merged" | jq -r 'if .priority == null then "" else (.priority | tostring) end')
    comment=$(printf '%s' "$merged" | jq -r '.comment // ""')
    local payload
    if ! payload=$(_dns_validate_record "$zone_name" "$type" "$name" "$content" "$ttl" "$proxied" "$priority" "$comment"); then
        _api_error 400 "$payload"; return
    fi
    _cf_call "$token" PUT "/zones/$zone_id/dns_records/$id" "$payload"
    [[ "$CF_HTTP_CODE" == "200" ]] || { _dns_cf_failure "$CF_BODY"; return; }
    local rec _dns_summary
    rec=$(printf '%s' "$CF_BODY" | jq -c --arg zone "$zone_name" --arg domain "$(_find_traefik_domain)" --argjson routes "$(_dns_route_map)" "$_DNS_JQ_DEFS"'.result | dcs_record($zone; $domain; $routes)' 2>/dev/null) || rec='{}'
    _dns_summary=$(printf '%s' "$payload" | jq -r '"\(.type) \(.name) -> \(.content) ttl=\(.ttl) proxied=\(.proxied)"' 2>/dev/null) || _dns_summary="record"
    _dns_audit_line "UPDATED $id $_dns_summary"
    _api_audit_log "${CLIENT_IP:-unknown}" "DNS_RECORD_UPDATE" "${AUTH_USERNAME:-unknown}" "$_dns_summary"
    _api_success "{\"success\": true, \"record\": $rec}"
}

# DELETE /dns/records/{id}?force=true — Delete a record (the zone apex and names DCS routes use need force=true)
handle_dns_record_delete() {
    local id="$1"
    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi
    [[ "$id" =~ ^[0-9a-f]{32}$ ]] || { _api_error 400 "Invalid record id"; return; }
    local token
    token=$(_find_cf_token)
    [[ -z "$token" ]] && { _api_error 503 "Cloudflare is not configured: store the API token as the secret CF_DNS_API_TOKEN"; return; }
    local zone_info zone_id="" zone_name=""
    if ! zone_info=$(_dns_target_zone "$token" "${QUERY_PARAMS[zone]:-}"); then _api_error 404 "$zone_info"; return; fi
    read -r zone_id zone_name <<< "$zone_info"
    _cf_call "$token" GET "/zones/$zone_id/dns_records/$id"
    [[ "$CF_HTTP_CODE" == "200" ]] || { _api_error 404 "Record not found in zone $zone_name"; return; }
    local rname rtype rcontent
    rname=$(printf '%s' "$CF_BODY" | jq -r '.result.name // empty'); rtype=$(printf '%s' "$CF_BODY" | jq -r '.result.type // empty')
    rcontent=$(printf '%s' "$CF_BODY" | jq -r '.result.content // empty')
    local reason="" route_owner=""
    route_owner=$(_dns_route_map | jq -r --arg n "$rname" '.[$n] // empty' 2>/dev/null) || route_owner=""
    if [[ "$rtype" == "A" || "$rtype" == "AAAA" || "$rtype" == "CNAME" ]]; then
        if [[ "$rname" == "$zone_name" ]]; then
            reason="$rname is the apex record of the zone; every DCS route points at it"
        elif [[ -n "$route_owner" ]]; then
            reason="the DCS route $route_owner uses $rname"
        fi
    fi
    if [[ -n "$reason" && "${QUERY_PARAMS[force]:-}" != "true" ]]; then
        _api_error 409 "Refusing to delete: $reason. Repeat with force=true to delete it anyway."
        return
    fi
    _cf_call "$token" DELETE "/zones/$zone_id/dns_records/$id"
    [[ "$CF_HTTP_CODE" == "200" ]] || { _dns_cf_failure "$CF_BODY"; return; }
    _dns_audit_line "DELETED $rtype $rname -> $rcontent${reason:+ [forced]}"
    _api_audit_log "${CLIENT_IP:-unknown}" "DNS_RECORD_DELETE" "${AUTH_USERNAME:-unknown}" "$rtype $rname${reason:+ (forced)}"
    _api_success "$(jq -nc --arg id "$id" --arg n "$rname" --arg t "$rtype" --argjson forced "$([[ -n "$reason" ]] && echo true || echo false)" '{success: true, id: $id, name: $n, type: $t, forced: $forced}')"
}

# POST /dns/records/sync — Create the proxied CNAME records that DCS routes are missing
handle_dns_records_sync() {
    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi
    local token domain
    token=$(_find_cf_token)
    [[ -z "$token" ]] && { _api_error 503 "Cloudflare is not configured: store the API token as the secret CF_DNS_API_TOKEN"; return; }
    domain=$(_find_traefik_domain)
    [[ -n "$domain" ]] || { _api_error 400 "No domain is configured (TRAEFIK_DOMAIN)"; return; }
    local zone_info zone_id="" zone_name=""
    if ! zone_info=$(_dns_target_zone "$token" ""); then _api_error 404 "$zone_info"; return; fi
    read -r zone_id zone_name <<< "$zone_info"
    local records
    records=$(_cf_records_all "$token" "$zone_id")
    [[ "$records" == __ERROR__:* ]] && { _api_error 502 "Cloudflare: ${records#__ERROR__:}"; return; }
    local missing
    missing=$(_dns_route_map | jq -r --argjson recs "$records" --arg zone "$zone_name" 'to_entries[] | select(.key != $zone and (.key | endswith("." + $zone))) | select(.key as $h | ($recs | map(select(.name == $h and (.type == "A" or .type == "AAAA" or .type == "CNAME"))) | length) == 0) | .key' 2>/dev/null) || missing=""
    local -a _sync_created=() _sync_failed=()
    local fqdn payload
    while IFS= read -r fqdn; do
        [[ -n "$fqdn" ]] || continue
        payload=$(jq -nc --arg n "$fqdn" --arg c "$domain" '{type: "CNAME", name: $n, content: $c, ttl: 1, proxied: true, comment: "Auto-created by DCS"}')
        _cf_call "$token" POST "/zones/$zone_id/dns_records" "$payload"
        if [[ "$CF_HTTP_CODE" == "200" ]]; then
            _sync_created+=("$(jq -nc --arg n "$fqdn" '$n')")
            _dns_audit_line "CREATED CNAME $fqdn -> $domain (sync)"
        else
            _sync_failed+=("$(jq -nc --arg n "$fqdn" --arg e "$(_cf_error_message "$CF_BODY")" '{name: $n, error: $e}')")
        fi
    done <<< "$missing"
    local created_json failed_json
    created_json=$(printf '%s,' "${_sync_created[@]}"); created_json="[${created_json%,}]"; [[ ${#_sync_created[@]} -eq 0 ]] && created_json="[]"
    failed_json=$(printf '%s,' "${_sync_failed[@]}"); failed_json="[${failed_json%,}]"; [[ ${#_sync_failed[@]} -eq 0 ]] && failed_json="[]"
    _api_audit_log "${CLIENT_IP:-unknown}" "DNS_SYNC" "${AUTH_USERNAME:-unknown}" "created ${#_sync_created[@]}, failed ${#_sync_failed[@]}"
    _api_success "{\"success\": true, \"created\": $created_json, \"failed\": $failed_json, \"zone\": \"$(_api_json_escape "$zone_name")\"}"
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

# POST /templates/{template}/deploy — Deploy a template into a stack (merge, routes, DNS, optional start)
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
    # config_path is joined to App-Data and handed to rm -rf/rsync/chmod later:
    # it must be a plain directory name
    local _meta_config_path
    _meta_config_path=$(printf '%s' "$meta" | jq -r '.config_path // empty' 2>/dev/null)
    if [[ -n "$_meta_config_path" && ! "$_meta_config_path" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        _api_error 400 "Template metadata has an invalid config_path: $_meta_config_path"
        return
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

    # --- Singleton check: prevent duplicate deployment of singleton templates ---
    local is_singleton
    is_singleton=$(printf '%s' "$meta" | jq -r '.singleton // false' 2>/dev/null)
    if [[ "$is_singleton" == "true" ]]; then
        local target_compose="$target_dir/docker-compose.yml"
        local template_services
        template_services=$(awk '/^services:/{found=1; next} found && /^[a-zA-Z]/{exit} found && /^  [a-zA-Z]/{gsub(/^ +/, ""); gsub(/:.*/, ""); print}' "$tdir/docker-compose.yml" 2>/dev/null)
        local replace_flag
        replace_flag=$(printf '%s' "$body" | jq -r '.replace_services // false' 2>/dev/null)
        if [[ "$replace_flag" != "true" ]]; then
            local _dup_services=""
            while IFS= read -r _svc; do
                [[ -z "$_svc" ]] && continue
                local _svc_escaped
                _svc_escaped=$(printf '%s' "$_svc" | sed 's/[.[\*^$()+?{|\\]/\\&/g')
                if grep -qE "^\s+${_svc_escaped}:" "$target_compose" 2>/dev/null; then
                    _dup_services="${_dup_services:+$_dup_services, }$_svc"
                fi
            done <<< "$template_services"
            if [[ -n "$_dup_services" ]]; then
                _api_error 409 "Singleton template '$name' is already deployed (services: $_dup_services). Pass replace_services: true to replace."
                return
            fi
        fi
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

    # --- Required variable validation ---
    if [[ -f "$tdir/template.json" ]]; then
        local _req_vars _missing_vars=""
        _req_vars=$(jq -r '.variables[]? | select(.required == true) | .name' "$tdir/template.json" 2>/dev/null)
        while IFS= read -r _rv; do
            [[ -z "$_rv" ]] && continue
            local _rv_val
            _rv_val=$(echo "$vars" | grep -m1 "^${_rv}=" | cut -d= -f2-)
            if [[ -z "$_rv_val" ]]; then
                _missing_vars="${_missing_vars:+$_missing_vars, }$_rv"
            fi
        done <<< "$_req_vars"
        if [[ -n "$_missing_vars" ]]; then
            _api_error 400 "Missing required variables: $_missing_vars"
            return
        fi
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
        # Then replace simple ${VAR} and whole-word $VAR patterns. The
        # replacement is quoted so `&` in a value stays literal (bash 5.2+
        # patsub_replacement), and bare $KEY never rewrites $KEY_SUFFIX.
        template_compose="${template_compose//\$\{$key\}/"$val"}"
        template_compose=$(printf '%s' "$template_compose" | sed -E "s/\\\$${key}([^A-Za-z0-9_]|\$)/${safe_val}\\1/g")
    done <<< "$vars"

    # Resolve remaining ${VAR:-default} patterns to their default values
    template_compose=$(printf '%s' "$template_compose" | sed 's/${[A-Za-z_][A-Za-z0-9_]*:-\([^}]*\)}/\1/g')

    # SELinux: append :z to volume mounts that don't already have a mode suffix.
    # The :z flag relabels files for container access (required on Fedora/RHEL/CentOS).
    # Harmless on non-SELinux systems (Ubuntu, Debian, Arch).
    # SKIP system paths: docker.sock, /etc/*, /var/run/*, /var/lib/dbus/* — relabeling these breaks the host.
    if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]; then
        template_compose=$(printf '%s' "$template_compose" | awk '
            /^[ \t]*volumes:[ \t]*$/ { in_vol=1; print; next }
            in_vol && /^[ \t]*-[ \t]/ && /:\// {
                if (/:z/ || /:Z/) { print; next }
                # Skip system paths that must not be relabeled
                if (/docker\.sock/ || /\/etc\// || /\/var\/run\// || /\/var\/lib\/dbus\// || /\/proc\// || /\/sys\//) { print; next }
                if (/:ro$/) { sub(/:ro$/, ":ro,z"); print; next }
                if (/:rw$/) { sub(/:rw$/, ":rw,z"); print; next }
                print $0 ":z"; next
            }
            in_vol && /^[ \t]*[a-zA-Z_]/ && !/^[ \t]*-/ { in_vol=0 }
            { print }
        ')
    fi

    # Container names chosen on the deploy screen: {"container_names": {"service": "Name"}}
    # The name is written into the template's service block before anything else
    # reads the compose (routes, proxy connection, progress record).
    local _cn_json
    _cn_json=$(printf '%s' "$body" | jq -c '.container_names // {} | with_entries(select(.value | type == "string" and length > 0))' 2>/dev/null) || _cn_json='{}'
    if [[ "$_cn_json" != "{}" ]]; then
        local _cn_svc _cn_name _cn_existing
        while IFS=$'\t' read -r _cn_svc _cn_name; do
            [[ -n "$_cn_svc" && -n "$_cn_name" ]] || continue
            [[ "$_cn_svc" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || { _api_error 400 "Invalid service name in container_names: $_cn_svc"; return; }
            [[ "$_cn_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] || { _api_error 400 "Invalid container name for $_cn_svc: only letters, digits, dot, dash and underscore"; return; }
            if _cn_existing=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}/{{index .Config.Labels "com.docker.compose.service"}}' "$_cn_name" 2>/dev/null); then
                local _cn_project
                _cn_project=$(grep -m1 '^COMPOSE_PROJECT_NAME=' "$target_dir/.env" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || _cn_project=""
                [[ -z "$_cn_project" ]] && _cn_project=$(basename "$target_dir" | tr '[:upper:]' '[:lower:]')
                if [[ "$_cn_existing" != "${_cn_project}/${_cn_svc}" ]]; then
                    _api_error 409 "A container named ${_cn_name} already exists (${_cn_existing%/*}); choose another name"
                    return
                fi
            fi
            template_compose=$(printf '%s\n' "$template_compose" | awk -v svc="$_cn_svc" -v name="$_cn_name" '
                /^  [A-Za-z0-9_.-]+:/ { cur=$1; sub(":","",cur); insvc = (cur == svc); if (insvc) { print; print "    container_name: " name; done_hdr=1 } else { print }; next }
                insvc && /^    container_name:/ { next }
                { print }')
        done < <(printf '%s' "$_cn_json" | jq -r 'to_entries[] | "\(.key)\t\(.value)"' 2>/dev/null)
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
    # Strip privileged mode from scan — built-in templates are trusted, and the UI
    # auto-sends allow_privileged for templates that need it. Also accept the flag
    # from the request body for API consumers.
    local _scan_compose="$template_compose"
    local _allow_privileged
    _allow_privileged=$(printf '%s' "$body" | jq -r '.allow_privileged // false' 2>/dev/null)
    # Privileged mode is waved through only when the admin caller explicitly
    # asked for it AND the resolved compose actually uses it (the UI sends the
    # flag for the templates that need it, e.g. Pelican Wings).
    if [[ "$_allow_privileged" == "true" ]] && printf '%s' "${template_compose,,}" | grep -qE '^\s+privileged:\s'; then
        _scan_compose=$(printf '%s' "$template_compose" | sed '/^\s*privileged:\s*/d')
        _api_audit_log "${CLIENT_IP:-unknown}" "DEPLOY_PRIVILEGED" "${AUTH_USERNAME:-anonymous}" "Privileged mode approved for template: $name"
    fi
    if ! _api_scan_compose_security "$_scan_compose" "template deploy ($name)" "deploy"; then
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

    _run_plugin_hooks "pre-deploy" "$(_hook_ctx "$target_stack" "$(jq -nc --arg t "$name" --arg c "$template_compose" '{template: $t, compose: $c, dry_run: false}')")" sync

    # Back up the existing compose file before anything modifies it — the
    # replace path and the conflict checks below can both bail out afterwards
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
                cp "$target_dir/docker-compose.yml.bak.${timestamp}" "$target_dir/docker-compose.yml"
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
                    cp "$target_dir/docker-compose.yml.bak.${timestamp}" "$target_dir/docker-compose.yml"
                    _api_error 409 "Host port(s) already in use by running containers: ${system_conflicts}"
                    return
                fi
            fi
        fi
    fi

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

            # Apply variable substitution to deployed config files (.env, .yml,
            # .yaml, .conf). Uses $vars, which includes generated secrets.
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
                        cfg_content="${cfg_content//\$\{$ckey\}/"$cval"}"
                    done <<< "$vars"
                    # Resolve remaining ${VAR:-default} patterns to their defaults
                    cfg_content=$(printf '%s' "$cfg_content" | sed 's/${[A-Za-z_][A-Za-z0-9_]*:-\([^}]*\)}/\1/g')
                    # Only write back if content actually changed
                    if [[ "$cfg_content" != "$orig_content" ]]; then
                        printf '%s\n' "$cfg_content" > "$cfg_file"
                    fi
                done < <(find "$config_target" -maxdepth 3 -type f \( -name '.env' -o -name '*.yml' -o -name '*.yaml' -o -name '*.conf' \) 2>/dev/null)
            fi

            # Ensure traefik.yml and acme.json are FILES not directories.
            # Docker creates directories for missing bind mount sources — if the config
            # copy didn't run yet or was skipped, these may be directories which breaks Traefik.
            # Only for templates that ship (or mount) these files — other templates' config
            # directories must not receive empty Traefik files.
            for _critical_file in "traefik.yml" "acme.json"; do
                local _cf_path="$config_target/$_critical_file"
                [[ -f "$tdir/config/$_critical_file" || -d "$_cf_path" ]] || continue
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
        # Write to a private temp dir first, then copy with docker (handles root-owned target dirs)
        local _auth_tmp
        if ! _auth_tmp=$(mktemp -d /tmp/dcs-authelia-XXXXXX 2>/dev/null) || [[ -z "$_auth_tmp" ]]; then
            cp "$target_dir/docker-compose.yml.bak.${timestamp}" "$target_dir/docker-compose.yml"
            _api_error 500 "Could not create a temporary directory. Deployment rolled back."
            return
        fi
        # Also ensure target dirs exist
        mkdir -p "$_auth_dir" 2>/dev/null || docker run --rm -v "$_auth_base:/d" alpine mkdir -p /d/Authelia/config 2>/dev/null || true

        # The domain resolved for routing above (which includes the deploy
        # request's own TRAEFIK_DOMAIN) — not just the process environment
        local _domain="${traefik_domain:-${TRAEFIK_DOMAIN:-example.com}}"
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
            # No real Argon2id digest means no working admin login — refuse
            # rather than ship a users database Authelia can never verify
            rm -rf "$_auth_tmp"
            cp "$target_dir/docker-compose.yml.bak.${timestamp}" "$target_dir/docker-compose.yml"
            _api_error 500 "Could not hash the Authelia admin password: neither the authelia CLI nor the authelia/authelia image was usable. Deployment rolled back."
            return
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

        # The registration runs in a detached script (socat reaps background
        # subshells). The script body is a QUOTED heredoc — nothing from the
        # template or route file is ever interpolated into shell code; values
        # travel in the environment and are SQL-quoted inside the script.
        local _reg_script
        _reg_script=$(mktemp /tmp/dcs-homarr-reg-XXXXXX.sh) || return 0
        local _hm_log="$BASE_DIR/logs/homarr-register.log"

        if [[ -n "$db_path" ]] && command -v sqlite3 >/dev/null 2>&1; then
            # Primary: SQLite — instant, no API call, no SSR crash
            cat > "$_reg_script" << 'HOMARR_SQLITE_EOF'
#!/bin/bash
sq() { printf '%s' "$1" | sed "s/'/''/g"; }
EXISTS=$(sqlite3 "$HM_DB" "SELECT COUNT(*) FROM app WHERE href='$(sq "$HM_URL")';" 2>/dev/null)
if [[ "$EXISTS" == "0" ]]; then
    sqlite3 "$HM_DB" "INSERT INTO app (id, name, description, icon_url, href, ping_url) VALUES ('$(sq "$HM_ID")', '$(sq "$HM_NAME")', '$(sq "$HM_DESC")', '$(sq "$HM_ICON")', '$(sq "$HM_URL")', '$(sq "$HM_URL")');" 2>/dev/null
    echo "$(date): Registered '$HM_NAME' on Homarr (SQLite)" >> "$HM_LOG"
else
    echo "$(date): Skipped '$HM_NAME' - already exists on Homarr" >> "$HM_LOG"
fi
rm -f -- "$0"
HOMARR_SQLITE_EOF
            chmod +x "$_reg_script"
            HM_DB="$db_path" HM_ID="$app_id" HM_NAME="$app_name" HM_DESC="$description" HM_ICON="$icon_url" HM_URL="$app_url" HM_LOG="$_hm_log" \
                nohup bash "$_reg_script" </dev/null >/dev/null 2>&1 &
        else
            # Fallback: tRPC API (when sqlite3 is not installed)
            local homarr_port=""
            homarr_port=$(docker inspect --format='{{range $p, $conf := .NetworkSettings.Ports}}{{if eq $p "7575/tcp"}}{{(index $conf 0).HostPort}}{{end}}{{end}}' Homarr 2>/dev/null)
            [[ -z "$homarr_port" || ! "$homarr_port" =~ ^[0-9]+$ ]] && rm -f "$_reg_script" && return 0
            local api_key
            api_key=$(_decrypt_secret "HOMARR_API_KEY") || { rm -f "$_reg_script"; return 0; }
            [[ -z "$api_key" ]] && rm -f "$_reg_script" && return 0
            local payload
            payload=$(jq -nc --arg name "$app_name" --arg href "$app_url" --arg icon "$icon_url" --arg desc "$description" --arg ping "$app_url" \
                '{json: {name: $name, href: $href, description: $desc, iconUrl: $icon, pingUrl: $ping}}')
            cat > "$_reg_script" << 'HOMARR_API_EOF'
#!/bin/bash
sleep 10
for _i in 1 2 3; do
    _code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X POST "http://localhost:${HM_PORT}/api/trpc/app.create" -H "ApiKey: $HM_KEY" -H "Content-Type: application/json" -d "$HM_PAYLOAD" 2>/dev/null)
    echo "$(date): Homarr register '$HM_NAME' attempt $_i - HTTP $_code (tRPC fallback)" >> "$HM_LOG"
    [[ "$_code" == "200" ]] && break
    sleep 5
done
rm -f -- "$0"
HOMARR_API_EOF
            chmod +x "$_reg_script"
            HM_PORT="$homarr_port" HM_KEY="$api_key" HM_PAYLOAD="$payload" HM_NAME="$app_name" HM_LOG="$_hm_log" \
                nohup bash "$_reg_script" </dev/null >/dev/null 2>&1 &
        fi
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
                # 1. From the deploy request (a ${SECRETS_…} placeholder resolves through the secret store)
                _cf_token=$(_cf_resolve_value "$(printf '%s' "$body" | jq -r '.variables.CF_DNS_API_TOKEN // empty' 2>/dev/null)")
                # 2. The secret store, then the root .env and the stack .env files
                [[ -z "$_cf_token" ]] && _cf_token=$(_find_cf_token)

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
        local _infra_cf_token
        _infra_cf_token=$(_find_cf_token)
        [[ -z "$_infra_cf_token" ]] && _infra_cf_token=$(_cf_resolve_value "$(printf '%s' "$body" | jq -r '.variables.CF_DNS_API_TOKEN // empty' 2>/dev/null)")

        printf '[%s] INFRA-DNS: name=%s domain=%s token=%s\n' \
            "$(date -Iseconds)" "$name" "$traefik_domain" "$([[ -n "$_infra_cf_token" ]] && echo present || echo absent)" \
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
    local started=false deploy_warning=""
    local _deploy_ctx
    _deploy_ctx=$(jq -nc --arg t "$name" --argjson svcs "$services_json" '{template: $t, services: $svcs}')
    if [[ "$auto_start" == "true" ]]; then
        local _missing_secrets
        _missing_secrets=$(secrets_missing "$target_dir/docker-compose.yml" "$target_dir/.env" "$BASE_DIR/.env" | tr '\n' ' ')
        if [[ -n "${_missing_secrets// /}" ]]; then
            auto_start=false
            deploy_warning="Not started: the secrets ${_missing_secrets% } do not exist yet. Create them on the Secrets page, then start the stack."
        fi
    fi
    # Container names the deployed services get (deploy response + progress)
    local _containers_json='{}' _svc _cn
    for _svc in $template_services; do
        _cn=$(_compose_container_name "$target_dir" "$_svc")
        _containers_json=$(jq -c --arg s "$_svc" --arg c "$_cn" '. + {($s): $c}' <<< "$_containers_json")
    done
    local activity_id=""
    if [[ "$auto_start" == "true" ]]; then
        local env_up=()
        [[ -f "$target_dir/.env" ]] && env_up=(--env-file "$target_dir/.env")
        local _puid="${PUID:-1000}"
        local _pgid="${PGID:-1000}"
        local _ad="${APP_DATA_DIR:-$target_dir/App-Data}"
        [[ "$_ad" == ./* ]] && _ad="$target_dir/${_ad#./}"
        local _svc_list=""
        _svc_list=$(printf '%s' "$template_services" | tr '\n' ' ')
        # Progress record + compose output log, read by GET /stacks/{stack}/activity
        activity_id=$(_stack_activity_begin "$target_stack" "deploy" "$(jq -nc --arg t "$name" --argjson s "$services_json" --argjson c "$_containers_json" '{template: $t, services: $s, containers: $c}')")
        local _activity_log="$STACK_ACTIVITY_DIR/$target_stack.log"
        local -a _prog=()
        read -ra _prog <<< "$(_compose_progress_args)"
        (
            set +e
            _stack_activity_pid "$target_stack"
            _plugin_hooks_now "pre-start" "$(_hook_ctx "$target_stack" "$_deploy_ctx")"
            local _up_ok=true
            # Safety: ensure Traefik directories exist ONLY if Traefik is in this stack
            if grep -q 'container_name: Traefik\|image: traefik' "$target_dir/docker-compose.yml" 2>/dev/null; then
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
            fi

            # Start ONLY the deployed services. Compose recreates a replaced
            # service (its definition changed) and leaves the rest of the stack
            # alone; the plain progress output feeds the activity log.
            local _deploy_env=""
            [[ -f "$target_dir/.env" ]] && _deploy_env="$target_dir/.env"
            # shellcheck disable=SC2086
            _compose_with_secrets "$target_dir/docker-compose.yml" "$_deploy_env" "${_prog[@]}" up -d $_svc_list >>"$_activity_log" 2>&1 || _up_ok=false

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
                docker run --rm -v "$_ad/Authelia/.dcs-cache:/src" -v "$_ad/Authelia/config:/dst" alpine sh -c \
                    "cp -f /src/configuration.yml /src/users_database.yml /dst/ 2>/dev/null; chmod 644 /dst/configuration.yml /dst/users_database.yml" 2>/dev/null
                $DOCKER_COMPOSE_CMD -f "$target_dir/docker-compose.yml" "${env_up[@]}" "${_prog[@]}" restart authelia >>"$_activity_log" 2>&1 || true
            fi

            # Docker creates bind-mount directories as root. Fix the ownership of
            # the deployed services' own App-Data paths only, and restart only
            # those services — the rest of the stack is never touched.
            sleep 2
            local _needs_restart=false _vol_path _owner
            # shellcheck disable=SC2086
            while IFS= read -r _vol_path; do
                [[ -n "$_vol_path" && -d "$_vol_path" ]] || continue
                _owner=$(stat -c '%u' "$_vol_path" 2>/dev/null)
                if [[ "$_owner" == "0" && "$_puid" != "0" ]]; then
                    docker run --rm -v "$_vol_path:/d" alpine chown -R "$_puid:$_pgid" /d 2>/dev/null || chown -R "$_puid:$_pgid" "$_vol_path" 2>/dev/null || true
                    _needs_restart=true
                fi
            done < <(_compose_bind_mounts "$target_dir" "$_ad" $_svc_list)
            if [[ "$_needs_restart" == "true" ]]; then
                # shellcheck disable=SC2086
                $DOCKER_COMPOSE_CMD -f "$target_dir/docker-compose.yml" "${env_up[@]}" "${_prog[@]}" restart $_svc_list >>"$_activity_log" 2>&1 || true
            fi
            _plugin_hooks_now "post-start" "$(_hook_ctx "$target_stack" "$_deploy_ctx" "$_up_ok")"
            _plugin_hooks_now "post-deploy" "$(_hook_ctx "$target_stack" "$(jq -c '. + {started: true}' <<< "$_deploy_ctx")" "$_up_ok")"
            [[ "$_up_ok" == "false" ]] && _fire_notifications "stack_failed" "stack=$target_stack" "action=deploy" "template=$name"
            _stack_activity_end "$target_stack" "$_up_ok"
        ) </dev/null >/dev/null 2>&1 &
        disown
        started=true
    else
        _run_plugin_hooks "post-deploy" "$(_hook_ctx "$target_stack" "$(jq -c '. + {started: false}' <<< "$_deploy_ctx")" true)"
    fi

    # Record deploy event in audit log (and fire "deploy" webhooks)
    _record_deploy_event "deploy" "$name" "$target_stack" "$services_json" "docker-compose.yml.bak.${timestamp}"
    _audit_log "deploy" "Deployed template '$name' to $target_stack" 2>/dev/null

    _api_success "{\"success\": true, \"target_stack\": \"$(_api_json_escape "$target_stack")\", \"services_added\": $services_json, \"started\": $started, \"containers\": $_containers_json, \"activity_id\": \"$(_api_json_escape "$activity_id")\", \"warning\": \"$(_api_json_escape "$deploy_warning")\", \"backup_file\": \"docker-compose.yml.bak.${timestamp}\", \"message\": \"Template services merged into $target_stack successfully\"}"
}

# POST /templates/{template}/dry-run — Preview a deployment: conflicts, ports, variables and policy findings
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

    # --- Security scan (non-blocking — report warnings, don't reject) ---
    local security_warnings="[]"
    if command -v _api_scan_compose_security >/dev/null 2>&1; then
        # Capture violations without rejecting
        local _scan_out
        if ! _scan_out=$(_API_SCAN_QUIET=true _api_scan_compose_security "$template_compose" "dry-run ($name)" "deploy"); then
            security_warnings="[\"$(_api_json_escape "$_scan_out")\"]"
        fi
    fi

    # --- Singleton check ---
    local is_singleton="false"
    local singleton_conflict=""
    local meta="{}"
    if [[ -f "$tdir/template.json" ]]; then
        meta=$(jq -c '.' "$tdir/template.json" 2>/dev/null || echo "{}")
        local _sing
        _sing=$(printf '%s' "$meta" | jq -r '.singleton // false' 2>/dev/null)
        if [[ "$_sing" == "true" ]]; then
            is_singleton="true"
            local target_compose="$target_dir/docker-compose.yml"
            while IFS= read -r _svc; do
                [[ -z "$_svc" ]] && continue
                if grep -qF "  ${_svc}:" "$target_compose" 2>/dev/null; then
                    singleton_conflict="${singleton_conflict:+$singleton_conflict, }$_svc"
                fi
            done <<< "$template_services"
        fi
    fi
    local has_singleton_conflict="false"
    [[ -n "$singleton_conflict" ]] && has_singleton_conflict="true"

    # --- Required variable check ---
    local missing_vars=""
    if [[ -f "$tdir/template.json" ]]; then
        local _req_vars
        _req_vars=$(jq -r '.variables[]? | select(.required == true) | .name' "$tdir/template.json" 2>/dev/null)
        local vars
        vars=$(printf '%s' "$body" | jq -r '.variables // {} | to_entries[] | "\(.key)=\(.value)"' 2>/dev/null)
        while IFS= read -r _rv; do
            [[ -z "$_rv" ]] && continue
            local _rv_val
            _rv_val=$(echo "$vars" | grep -m1 "^${_rv}=" | cut -d= -f2-)
            if [[ -z "$_rv_val" ]]; then
                missing_vars="${missing_vars:+$missing_vars, }$_rv"
            fi
        done <<< "$_req_vars"
    fi
    local has_missing_vars="false"
    [[ -n "$missing_vars" ]] && has_missing_vars="true"

    # --- Pre-deploy plugin hooks (non-blocking, collect output) ---
    local plugin_results="[]"
    if [[ "${PLUGINS_ENABLED:-true}" == "true" && "${PLUGINS_HOOKS_ENABLED:-true}" == "true" ]]; then
        local _plugin_dir="${PLUGINS_DIR:-$BASE_DIR/.plugins}"
        if [[ -d "$_plugin_dir" ]]; then
            local -a _plugin_outputs=()
            for _pd in "$_plugin_dir"/*/; do
                [[ ! -f "$_pd/plugin.json" ]] && continue
                _plugin_enabled "$_pd" || continue
                local _pname
                _pname=$(basename "$_pd")
                local _hook="$_pd/hooks/pre-deploy"
                [[ ! -x "$_hook" ]] && _hook="${_hook}.sh"
                [[ ! -x "$_hook" ]] && continue
                _plugin_path_ok "$_pd" "$_hook" || continue
                local _ctx
                _ctx=$(_hook_ctx "$target_stack" "$(jq -nc --arg t "$name" --arg c "$template_compose" '{template: $t, compose: $c, dry_run: true}')")
                local _pout _prc=0
                _pout=$(_plugin_exec_hook "$_hook" "$_ctx" "pre-deploy" 10 "$_pd" 2>/dev/null) || _prc=$?
                _plugin_log_run "$_pd" "pre-deploy" "$_pout" "$_prc" true
                _pout=$(printf '%s' "$_pout" | head -c 2048)
                if [[ -n "$_pout" ]]; then
                    _plugin_outputs+=("{\"plugin\": \"$(_api_json_escape "$_pname")\", \"output\": \"$(_api_json_escape "$_pout")\"}")
                fi
            done
            if [[ ${#_plugin_outputs[@]} -gt 0 ]]; then
                local _pj
                _pj=$(printf '%s,' "${_plugin_outputs[@]}")
                plugin_results="[${_pj%,}]"
            fi
        fi
    fi

    _api_success "{\"success\": true, \"template\": \"$(_api_json_escape "$name")\", \"target_stack\": \"$(_api_json_escape "$target_stack")\", \"services\": $services_json, \"service_conflicts\": \"$(_api_json_escape "$service_conflicts")\", \"has_service_conflicts\": $has_svc_conflict, \"port_conflicts\": \"$(_api_json_escape "$port_conflicts")\", \"has_port_conflicts\": $has_port_conflict, \"port_conflicts_detail\": $port_conflicts_detail, \"env_additions\": $env_additions, \"env_existing\": $env_existing, \"lines_added\": ${lines_added:-0}, \"compose_preview\": \"$(_api_json_escape "$tpl_svc_block")\", \"is_singleton\": $is_singleton, \"singleton_conflict\": \"$(_api_json_escape "$singleton_conflict")\", \"has_singleton_conflict\": $has_singleton_conflict, \"missing_required_vars\": \"$(_api_json_escape "$missing_vars")\", \"has_missing_vars\": $has_missing_vars, \"security_warnings\": $security_warnings, \"plugin_results\": $plugin_results}"
}

# POST /templates/{template}/undeploy — Remove a template's services from a stack with their containers (remove_containers=false keeps them; optionally data, images, routes)
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
        [[ -z "$svc" ]] && continue
        # Names reach awk patterns, route file paths and rm -rf below
        if [[ ! "$svc" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
            _api_error 400 "Invalid service name: $svc"
            return
        fi
        services_to_remove+=("$svc")
    done < <(printf '%s' "$svc_json" | jq -r '.[]?' 2>/dev/null)

    if [[ ${#services_to_remove[@]} -eq 0 ]]; then
        _api_error 400 "No valid services specified"
        return
    fi

    local remove_containers
    # Containers of a service that leaves the compose file go with it unless the
    # caller says otherwise: a running container over purged App-Data is a trap
    remove_containers=$(printf '%s' "$body" | jq -r 'if .remove_containers == false then "false" else "true" end' 2>/dev/null)
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

    # An awk failure would leave an empty document — never write that out
    if [[ -z "${compose_content//[[:space:]]/}" ]]; then
        cp "$target_dir/docker-compose.yml.bak.${timestamp}" "$target_dir/docker-compose.yml"
        _api_error 500 "Service removal produced an empty compose file. Rolled back."
        return
    fi

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
        local _cf_token _cf_domain
        _cf_token=$(_find_cf_token)
        _cf_domain=$(_find_traefik_domain)
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
    ) </dev/null >/dev/null 2>&1 &
    disown

    if [[ "$remove_data" == "true" ]]; then
        # Heavy cleanup in background — app-data, images (prevents HTTP timeout)
        local _app_data="${APP_DATA_DIR:-$target_dir/App-Data}"
        [[ "$_app_data" == ./* ]] && _app_data="$target_dir/${_app_data#./}"
        local _config_path
        _config_path=$(printf '%s' "$meta" | jq -r '.config_path // empty' 2>/dev/null)
        # Only a plain directory name may be removed under App-Data
        [[ "$_config_path" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || _config_path=""
        local _backup_file="$target_dir/docker-compose.yml.bak.${timestamp}"
        (
            # 1. Remove per-service App-Data
            for svc in "${services_to_remove[@]}"; do
                for dir_name in "$svc" "${svc^}" "${svc^^}"; do
                    if [[ -d "$_app_data/$dir_name" ]]; then
                        rm -rf "${_app_data:?}/$dir_name" 2>/dev/null || docker run --rm -v "$_app_data/$dir_name:/d" alpine rm -rf /d 2>/dev/null
                    fi
                done
            done
            # 2. Remove config_path data (e.g. Pelican/ directory for pelican template)
            if [[ -n "$_config_path" && -d "$_app_data/$_config_path" ]]; then
                rm -rf "${_app_data:?}/${_config_path:?}" 2>/dev/null || docker run --rm -v "$_app_data/$_config_path:/d" alpine rm -rf /d 2>/dev/null
                # Also remove any stray files at the config_path level (acme.json, traefik.yml etc)
                rmdir "$_app_data/$_config_path" 2>/dev/null || true
            fi
            # 3. Remove Docker images
            for svc in "${services_to_remove[@]}"; do
                local img
                img=$(awk -v s="  ${svc}:" 'BEGIN{f=0} $0==s||index($0,s)==1{f=1;next} f&&/image:/{gsub(/.*image:[[:space:]]*/,"");gsub(/[[:space:]]*$/,"");print;exit} f&&/^  [a-zA-Z]/{exit}' "$_backup_file" 2>/dev/null)
                [[ -n "$img" ]] && docker rmi "$img" 2>/dev/null || true
            done
        ) </dev/null >/dev/null 2>&1 &
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

    # Record undeploy event (and fire "undeploy" webhooks)
    _record_deploy_event "undeploy" "$name" "$target_stack" "$svc_removed_json" "docker-compose.yml.bak.${timestamp}"
    _audit_log "undeploy" "Removed ${#services_to_remove[@]} service(s) of template '$name' from $target_stack" 2>/dev/null

    local msg="Services removed from $target_stack successfully"
    [[ "$stack_deleted" == "true" ]] && msg="Stack $target_stack fully removed (no services remaining)"
    [[ "$data_removed" == "true" ]] && msg="$msg — app data purged"
    [[ "$images_removed" == "true" ]] && msg="$msg — images removed"
    [[ "$routes_removed" == "true" ]] && msg="$msg — routes cleaned"

    _api_success "{\"success\": true, \"template\": \"$(_api_json_escape "$name")\", \"target_stack\": \"$(_api_json_escape "$target_stack")\", \"services_removed\": $svc_removed_json, \"containers_removed\": $ctr_removed_json, \"backup_file\": \"docker-compose.yml.bak.${timestamp}\", \"stack_deleted\": $stack_deleted, \"data_removed\": $data_removed, \"images_removed\": $images_removed, \"routes_removed\": $routes_removed, \"message\": \"$msg\"}"
}

# POST /templates/import — Import a template from compose content
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

    # Metadata is trusted by the deploy path (config_path ends up in rm -rf)
    local _cp
    _cp=$(printf '%s' "$metadata" | jq -r '.config_path // empty' 2>/dev/null)
    if [[ -n "$_cp" && ! "$_cp" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        _api_error 400 "Invalid config_path in metadata"
        return
    fi

    local tdir="$TEMPLATES_DIR/$name"
    local overwrite
    overwrite=$(printf '%s' "$body" | jq -r '.overwrite // false' 2>/dev/null)
    if [[ -d "$tdir" && "$overwrite" != "true" ]]; then
        _api_error 409 "Template already exists: $name (pass overwrite: true to replace it)"
        return
    fi
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

    # Fetch the compose content. Redirects are not followed: the SSRF check
    # above only vetted this hostname, and a redirect could point anywhere.
    local compose_content
    compose_content=$(curl -fsS --max-redirs 0 --max-time 30 --max-filesize 10485760 "$url" 2>/dev/null)
    if [[ -z "$compose_content" ]]; then
        _api_error 400 "Failed to fetch content from URL (redirects are not followed — use the final URL)"
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

    # Fetch the compose content (no redirects — see handle_template_fetch_url)
    local compose_content
    compose_content=$(curl -fsS --max-redirs 0 --max-time 30 --max-filesize 10485760 "$url" 2>/dev/null)
    if [[ -z "$compose_content" ]]; then
        _api_error 400 "Failed to fetch content from URL (redirects are not followed — use the final URL)"
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

    # SECURITY: Scan fetched compose for dangerous Docker features BEFORE
    # handing it to `docker compose config` (which resolves extends:/include:)
    if ! _api_scan_compose_security "$compose_content" "URL import from $url"; then
        return
    fi

    # Validate it looks like a compose file
    local tmpfile
    tmpfile=$(mktemp /tmp/dcs-validate-XXXXXX.yml) || { _api_error 500 "Could not create a temporary file"; return; }
    printf '%s' "$compose_content" > "$tmpfile"
    local validate_output
    validate_output=$($DOCKER_COMPOSE_CMD -f "$tmpfile" config 2>&1)
    local validate_rc=$?
    rm -f "$tmpfile"

    if [[ $validate_rc -ne 0 ]]; then
        _api_error 422 "Invalid compose file: $validate_output"
        return
    fi

    # Extract service names for metadata
    local services
    services=$(printf '%s' "$compose_content" | grep -E '^  [a-zA-Z_-][a-zA-Z0-9_-]*:' | sed 's/:.*//' | tr -d ' ' | paste -sd ',' -)

    # Create template directory (never replace an existing template silently)
    local tdir="$TEMPLATES_DIR/$name"
    local overwrite
    overwrite=$(printf '%s' "$body" | jq -r '.overwrite // false' 2>/dev/null)
    if [[ -d "$tdir" && "$overwrite" != "true" ]]; then
        _api_error 409 "Template already exists: $name (pass overwrite: true to replace it)"
        return
    fi
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
    if [[ -z "$content" ]] || ! jq -e 'type == "array"' <<< "$content" >/dev/null 2>&1; then
        _api_success "{\"templates\": [], \"total\": 0}"
        return
    fi

    # Optional category filter from query string
    local category="${QUERY_PARAMS[category]:-}"

    if [[ -n "$category" ]] && command -v jq >/dev/null 2>&1; then
        local filtered
        filtered=$(printf '%s' "$content" | jq --arg cat "$category" '[.[] | select(.category == $cat)]' 2>/dev/null)
        [[ -z "$filtered" ]] && filtered="[]"
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

    # Copy the definition only (compose + .env). App-Data, backups and trust
    # markers belong to the source stack.
    if ! mkdir -p "$dst_dir/App-Data" 2>/dev/null; then
        _api_error 500 "Failed to create stack directory"
        return
    fi
    if [[ ! -f "$src_dir/docker-compose.yml" ]] || ! cp "$src_dir/docker-compose.yml" "$dst_dir/docker-compose.yml" 2>/dev/null; then
        rm -rf "$dst_dir"
        _api_error 500 "Failed to copy the compose file"
        return
    fi
    [[ -f "$src_dir/.env" ]] && cp "$src_dir/.env" "$dst_dir/.env" 2>/dev/null

    # Every container_name gets the new stack's prefix so the clone can run
    # alongside the original without name conflicts
    local compose_file="$dst_dir/docker-compose.yml"
    sed -i -E "s/^([[:space:]]*container_name:[[:space:]]*)[\"']?([A-Za-z0-9._-]+)[\"']?[[:space:]]*$/\1${new_name}-\2/" "$compose_file" 2>/dev/null

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
        # Policy scan first: `docker compose config` would otherwise resolve
        # extends:/include: references to arbitrary files on the host
        local _scan_msg
        if ! _scan_msg=$(_API_SCAN_QUIET=true _api_scan_compose_security "$content" "validation"); then
            _api_success "{\"valid\": false, \"errors\": [\"$(_api_json_escape "Security policy: $_scan_msg")\"], \"warnings\": [], \"services\": [], \"output\": \"\"}"
            return
        fi
        tmpfile=$(mktemp /tmp/dcs-validate-XXXXXX.yml) || { _api_error 500 "Could not create a temporary file"; return; }
        printf '%s' "$content" > "$tmpfile"
        validate_output=$($DOCKER_COMPOSE_CMD -f "$tmpfile" config 2>&1)
        validate_rc=$?
        rm -f "$tmpfile"
    elif [[ -n "$stack" ]]; then
        _api_validate_stack_name "$stack" || return
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
    [[ "$limit" =~ ^[0-9]+$ ]] || limit=100
    (( limit > 5000 )) && limit=5000
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

    # Fire webhooks if configured (detached from the request's socket)
    _webhook_fire "$action" "$detail" </dev/null >/dev/null 2>&1 &
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
    events=$(printf '%s' "$body" | jq -c '(.events // ["deploy","health_change"]) | if type == "array" then map(tostring) else empty end' 2>/dev/null)
    enabled=$(printf '%s' "$body" | jq -r 'if .enabled == null then true else .enabled end' 2>/dev/null)

    if [[ -z "$url" ]]; then
        _api_error 400 "Missing required field: url"
        return
    fi
    if [[ -z "$events" ]]; then
        _api_error 400 "events must be an array of event names"
        return
    fi
    if [[ "$enabled" != "true" && "$enabled" != "false" ]]; then
        _api_error 400 "enabled must be true or false"
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
    jq -e 'type == "array"' <<< "$existing" >/dev/null 2>&1 || existing="[]"

    local new_webhook
    new_webhook=$(jq -n --arg id "$id" --arg url "$url" --argjson events "$events" --argjson enabled "$enabled" --arg ts "$timestamp" \
        '{id: $id, url: $url, events: $events, enabled: $enabled, created_at: $ts}')

    # Write to a temp file first: a redirect truncates before jq runs
    if ! printf '%s' "$existing" | jq --argjson wh "$new_webhook" '. + [$wh]' > "${webhooks_file}.tmp" 2>/dev/null; then
        rm -f "${webhooks_file}.tmp"
        _api_error 500 "Failed to save webhook"
        return
    fi
    mv -f "${webhooks_file}.tmp" "$webhooks_file"

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

    local before after new_list
    before=$(jq 'length' "$webhooks_file" 2>/dev/null || echo 0)
    new_list=$(jq --arg id "$webhook_id" '[.[] | select(.id != $id)]' "$webhooks_file" 2>/dev/null)
    if [[ -z "$new_list" ]]; then
        _api_error 500 "Webhook store is not valid JSON"
        return
    fi
    after=$(jq 'length' <<< "$new_list" 2>/dev/null || echo 0)
    if [[ "$before" == "$after" ]]; then
        _api_error 404 "Webhook not found"
        return
    fi
    printf '%s' "$new_list" > "${webhooks_file}.tmp" && mv -f "${webhooks_file}.tmp" "$webhooks_file"

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
        local _cp
        _cp=$(printf '%s' "$metadata" | jq -r '.config_path // empty' 2>/dev/null)
        if [[ -n "$_cp" && ! "$_cp" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
            _api_error 400 "Invalid config_path in metadata"
            return
        fi
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

# GET /automations — Automation rules
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

# POST /automations — Create an automation rule
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
    enabled=$(printf '%s' "$body" | jq -r 'if .enabled == null then true else .enabled end' 2>/dev/null)

    if [[ -z "$name" || -z "$trigger_type" || -z "$action_type" ]]; then
        _api_error 400 "Missing required fields: name, trigger_type, action_type"
        return
    fi
    if [[ "$enabled" != "true" && "$enabled" != "false" ]]; then
        _api_error 400 "enabled must be true or false"
        return
    fi
    _automation_validate_rule "$trigger_type" "$trigger_value" "$action_type" "$action_target" || return

    local auto_id
    auto_id="auto_$(date +%s)_$RANDOM"
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local automation
    automation="{\"id\": \"$auto_id\", \"name\": \"$(_api_json_escape "$name")\", \"enabled\": $enabled, \"trigger_type\": \"$(_api_json_escape "$trigger_type")\", \"trigger_value\": \"$(_api_json_escape "$trigger_value")\", \"action_type\": \"$(_api_json_escape "$action_type")\", \"action_target\": \"$(_api_json_escape "$action_target")\", \"created_at\": \"$ts\", \"run_count\": 0, \"last_run\": null, \"history\": []}"

    if ! _api_jq_update_file "$AUTOMATIONS_FILE" --argjson auto "$automation" '. + [$auto]'; then
        _api_error 500 "Failed to save automation"
        return
    fi

    _api_success "$automation"
}

# POST /automations/{id}/update — Update an automation rule
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

    # Merge updates (the body must be an object; ids and counters are immutable)
    local updates
    updates=$(printf '%s' "$body" | jq -c 'select(type == "object") | del(.id, .created_at, .run_count, .last_run, .history)' 2>/dev/null)
    if [[ -z "$updates" ]]; then
        _api_error 400 "Request body must be a JSON object"
        return
    fi
    # Validate what the rule will look like after the merge
    local _merged
    _merged=$(jq -c --arg id "$auto_id" --argjson upd "$updates" '.[] | select(.id == $id) | . + $upd' "$AUTOMATIONS_FILE" 2>/dev/null)
    _automation_validate_rule \
        "$(printf '%s' "$_merged" | jq -r '.trigger_type // empty')" \
        "$(printf '%s' "$_merged" | jq -r '.trigger_value // ""')" \
        "$(printf '%s' "$_merged" | jq -r '.action_type // empty')" \
        "$(printf '%s' "$_merged" | jq -r '.action_target // "*"')" || return

    if ! _api_jq_update_file "$AUTOMATIONS_FILE" --arg id "$auto_id" --argjson upd "$updates" \
        'map(if .id == $id then . + $upd else . end)'; then
        _api_error 500 "Failed to update automation"
        return
    fi

    # Automations created by older versions installed crontab lines; drop them
    _remove_automation_cron "$auto_id"

    local updated
    updated=$(jq -c --arg id "$auto_id" '.[] | select(.id == $id)' "$AUTOMATIONS_FILE" 2>/dev/null)

    _api_success "$updated"
}

# DELETE /automations/{id} — Delete an automation rule
handle_automation_delete() {
    local auto_id="$1"
    _init_automations_file

    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required"
        return
    fi

    local exists
    exists=$(jq --arg id "$auto_id" '[.[] | select(.id == $id)] | length' "$AUTOMATIONS_FILE" 2>/dev/null)
    if [[ "$exists" != "1" ]]; then
        _api_error 404 "Automation not found: $auto_id"
        return
    fi
    _remove_automation_cron "$auto_id"
    if ! _api_jq_update_file "$AUTOMATIONS_FILE" --arg id "$auto_id" '[.[] | select(.id != $id)]'; then
        _api_error 500 "Failed to delete automation"
        return
    fi

    _api_success "{\"success\": true, \"deleted\": \"$(_api_json_escape "$auto_id")\"}"
}

# GET /automations/{id}/history — Run history of an automation
handle_automation_history() {
    local auto_id="$1"
    _init_automations_file

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required"
        return
    fi

    local rule
    rule=$(jq -c --arg id "$auto_id" 'map(select(.id == $id))[0] // empty' "$AUTOMATIONS_FILE" 2>/dev/null)
    if [[ -z "$rule" ]]; then
        _api_error 404 "Automation not found: $auto_id"
        return
    fi
    local history
    history=$(printf '%s' "$rule" | jq -c '(.history // []) | reverse' 2>/dev/null || echo "[]")

    _api_success "{\"automation_id\": \"$(_api_json_escape "$auto_id")\", \"history\": $history, \"run_count\": $(printf '%s' "$rule" | jq '.run_count // 0'), \"last_run\": $(printf '%s' "$rule" | jq '.last_run')}"
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
        @reboot|@hourly|@daily|@midnight|@weekly|@monthly|@yearly|@annually) return 0 ;;
        @minutely|@5min|@15min|@30min) return 0 ;;
    esac
    return 1
}


_remove_automation_cron() {
    local auto_id="$1"
    # Legacy cleanup only: automations no longer install cron lines. Remove the
    # line tagged with exactly this id (end-anchored, so auto_1_5 never removes
    # auto_1_55). Never install an empty crontab if the listing fails.
    local current
    current=$(crontab -l 2>/dev/null) || return 0
    [[ -z "$current" ]] && return 0
    grep -qF -- "# DCS-AUTO:${auto_id}" <<< "$current" || return 0
    local kept
    kept=$(grep -vE -- "# DCS-AUTO:$(printf '%s' "$auto_id" | sed 's/[][\.*^$+?(){}|]/\\&/g')\$" <<< "$current")
    printf '%s\n' "$kept" | crontab - 2>/dev/null
}

# =============================================================================
# AUTOMATION ENGINE
# Rules run inside the server process: a loop wakes every 20 s, evaluates each
# enabled rule once per minute (cron matcher for schedules, live checks for
# conditions), runs the action synchronously, and records the outcome in the
# rule's history. No crontab, no token, no TLS assumptions.
# =============================================================================

AUTOMATION_STATE_FILE="$BASE_DIR/.data/automation-state.json"
AUTOMATION_LOG="$BASE_DIR/logs/automations.log"
AUTOMATION_HISTORY_MAX=50
AUTOMATION_CONDITION_COOLDOWN="${AUTOMATION_CONDITION_COOLDOWN:-900}"

_AUTOMATION_TRIGGERS='schedule|condition'
_AUTOMATION_CONDITIONS='container_unhealthy|container_stopped|high_cpu|high_memory|disk_full'
_AUTOMATION_ACTIONS='stack_start|stack_stop|stack_restart|container_restart|docker_prune|notification_send|backup_trigger'

# Validate a rule's shape. Answers 400 itself; returns 1 on failure.
_automation_validate_rule() {
    local trigger_type="$1" trigger_value="$2" action_type="$3" action_target="$4"
    local _tre="^(${_AUTOMATION_TRIGGERS})$" _cre="^(${_AUTOMATION_CONDITIONS})$" _are="^(${_AUTOMATION_ACTIONS})$"
    if [[ ! "$trigger_type" =~ $_tre ]]; then
        _api_error 400 "trigger_type must be one of: ${_AUTOMATION_TRIGGERS//|/, }"
        return 1
    fi
    if [[ "$trigger_type" == "schedule" ]]; then
        if [[ -z "$trigger_value" ]] || ! _validate_cron_expression "$trigger_value"; then
            _api_error 400 "Invalid cron expression: ${trigger_value:-<empty>} (5 fields: minute hour day month weekday, or @hourly/@daily/@weekly/@monthly)"
            return 1
        fi
    elif [[ ! "$trigger_value" =~ $_cre ]]; then
        _api_error 400 "Condition must be one of: ${_AUTOMATION_CONDITIONS//|/, }"
        return 1
    fi
    if [[ ! "$action_type" =~ $_are ]]; then
        _api_error 400 "action_type must be one of: ${_AUTOMATION_ACTIONS//|/, }"
        return 1
    fi
    case "$action_type" in
        stack_start|stack_stop|stack_restart|backup_trigger)
            if [[ -n "$action_target" && "$action_target" != "*" ]]; then
                _api_validate_stack_name "$action_target" || return 1
                if [[ "$action_type" != "backup_trigger" && ! -f "$COMPOSE_DIR/$action_target/docker-compose.yml" ]]; then
                    _api_error 400 "Unknown stack: $action_target"
                    return 1
                fi
            fi
            ;;
        container_restart)
            if [[ -n "$action_target" && "$action_target" != "*" ]] && [[ ! "$action_target" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]]; then
                _api_error 400 "Invalid container name: $action_target"
                return 1
            fi
            ;;
        notification_send)
            if [[ ${#action_target} -gt 500 ]]; then
                _api_error 400 "Notification text is limited to 500 characters"
                return 1
            fi
            ;;
    esac
    return 0
}

# One cron field against a value: *, n, a-b, a,b, */s, a-b/s.
_cron_field_matches() {
    local field="$1" value="$2" min="$3" max="$4"
    local -a parts
    IFS=',' read -ra parts <<< "$field"
    local part step range lo hi
    for part in "${parts[@]}"; do
        step=1; range="$part"
        if [[ "$part" == */* ]]; then step="${part#*/}"; range="${part%%/*}"; fi
        [[ "$step" =~ ^[0-9]+$ && "$step" -ge 1 ]] || continue
        if [[ "$range" == "*" ]]; then lo=$min; hi=$max
        elif [[ "$range" == *-* ]]; then lo="${range%-*}"; hi="${range#*-}"
        else lo="$range"; hi="$range"; [[ "$part" == */* ]] && hi=$max; fi
        [[ "$lo" =~ ^[0-9]+$ && "$hi" =~ ^[0-9]+$ ]] || continue
        (( value >= lo && value <= hi )) || continue
        (( (value - lo) % step == 0 )) && return 0
    done
    return 1
}

# Does a cron expression fire in the minute that contains EPOCH (local time)?
_cron_matches() {
    local expr="$1" epoch="$2"
    case "$expr" in
        @minutely)          expr="* * * * *" ;;
        @5min)              expr="*/5 * * * *" ;;
        @15min)             expr="*/15 * * * *" ;;
        @30min)             expr="*/30 * * * *" ;;
        @hourly)            expr="0 * * * *" ;;
        @daily|@midnight)   expr="0 0 * * *" ;;
        @weekly)            expr="0 0 * * 0" ;;
        @monthly)           expr="0 0 1 * *" ;;
        @yearly|@annually)  expr="0 0 1 1 *" ;;
        @reboot)            return 1 ;;
    esac
    local f_min f_hour f_dom f_mon f_dow _extra
    read -r f_min f_hour f_dom f_mon f_dow _extra <<< "$expr"
    [[ -n "$f_dow" && -z "$_extra" ]] || return 1
    local mi ho dm mo dw
    read -r mi ho dm mo dw <<< "$(date -d "@$epoch" '+%-M %-H %-d %-m %w' 2>/dev/null)"
    [[ -n "$dw" ]] || return 1
    _cron_field_matches "$f_min" "$mi" 0 59 || return 1
    _cron_field_matches "$f_hour" "$ho" 0 23 || return 1
    _cron_field_matches "$f_mon" "$mo" 1 12 || return 1
    local dom_ok=1 dow_ok=1
    _cron_field_matches "$f_dom" "$dm" 1 31 && dom_ok=0
    _cron_field_matches "$f_dow" "$dw" 0 7 && dow_ok=0
    [[ "$dw" == "0" ]] && _cron_field_matches "$f_dow" 7 0 7 && dow_ok=0
    # Like cron: when both day fields are restricted, either one may match
    if [[ "$f_dom" != "*" && "$f_dow" != "*" ]]; then
        (( dom_ok == 0 || dow_ok == 0 ))
    else
        (( dom_ok == 0 && dow_ok == 0 ))
    fi
}

# Push endpoint: NTFY_URL plus the topic, unless the URL already names it.
_ntfy_endpoint() {
    local url="${NTFY_URL:-}" topic="${NTFY_TOPIC:-}"
    [[ -z "$url" ]] && return 1
    url="${url%/}"
    if [[ -n "$topic" && "$url" != */"$topic" ]]; then
        url="$url/$topic"
    fi
    printf '%s' "$url"
}

# Send one push message. Usage: _ntfy_send TITLE MESSAGE [PRIORITY] [TAGS]
# Prints the HTTP status code; returns 0 only for a 2xx answer.
_ntfy_send() {
    local title="$1" message="$2" priority="${3:-default}" tags="${4:-}"
    local endpoint
    endpoint=$(_ntfy_endpoint) || { printf '0'; return 1; }
    local -a hdr=(-H "Title: $title" -H "Priority: $priority")
    [[ -n "$tags" ]] && hdr+=(-H "Tags: $tags")
    [[ -n "${NTFY_TOKEN:-}" ]] && hdr+=(-H "Authorization: Bearer ${NTFY_TOKEN}")
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${hdr[@]}" --data-binary "$message" "$endpoint" 2>/dev/null)
    [[ "$code" =~ ^[0-9]+$ ]] || code=0
    printf '%s' "$code"
    [[ "$code" =~ ^2 ]]
}

# Discord: a channel webhook in DISCORD_WEBHOOK_URL (a ${SECRETS_NAME} reference
# is resolved from the secret store). Prints the URL; fails when not configured.
_discord_webhook() {
    local url="${DISCORD_WEBHOOK_URL:-}"
    if [[ "$url" =~ ^\$\{SECRETS[._]([A-Za-z_][A-Za-z0-9_]*)\}$ ]]; then
        url=$(secrets_get "${BASH_REMATCH[1]}" 2>/dev/null) || url=""
    fi
    [[ "$url" == https://discord.com/api/webhooks/* || "$url" == https://discordapp.com/api/webhooks/* ]] || return 1
    printf '%s' "$url"
}

# Where the dashboard lives, for the link on every Discord message
_dashboard_public_url() {
    if [[ -n "${DASHBOARD_PUBLIC_URL:-}" ]]; then printf '%s' "${DASHBOARD_PUBLIC_URL%/}"
    elif [[ -n "${PROXY_DOMAIN:-}" ]]; then printf 'https://ui.%s' "$PROXY_DOMAIN"
    fi
}

# Post one message to Discord as an embed: an emoji and colour per event, the
# event's facts as fields, the host and version in the footer, and the title
# linking back to the dashboard. Usage: _discord_send TITLE MESSAGE [PRIORITY] [EVENT] [FIELDS_JSON]
# Prints the HTTP status code (0 when nothing was sent).
_discord_send() {
    local title="$1" message="$2" priority="${3:-default}" event="${4:-}" embed_fields="${5:-{\}}"
    local url color emoji payload code
    url=$(_discord_webhook) || { printf '0'; return 1; }
    case "$event" in
        container_unhealthy) emoji="🩺"; color=15548997 ;;
        container_stopped)   emoji="⛔"; color=16753920 ;;
        stack_failed)        emoji="💥"; color=15548997 ;;
        stack_down)          emoji="🛑"; color=16753920 ;;
        stack_started|deploy|deployed) emoji="🚀"; color=5763719 ;;
        automation_run)      emoji="🤖"; color=3447003 ;;
        image_update|updates) emoji="⬆️"; color=3447003 ;;
        backup)              emoji="💾"; color=10181046 ;;
        test)                emoji="🔔"; color=5763719 ;;
        *)                   emoji="📣"; color=5763719 ;;
    esac
    case "$priority" in
        urgent|max|5) color=15548997 ;;
        high|4)       [[ "$color" == 5763719 || "$color" == 3447003 ]] && color=16753920 ;;
    esac
    [[ "$embed_fields" =~ ^\{ ]] || embed_fields='{}'
    payload=$(jq -nc --arg t "$emoji $title" --arg m "$message" --arg host "$(hostname 2>/dev/null || echo DCS)" \
        --arg ver "${DCS_VERSION:-}" --arg link "$(_dashboard_public_url)" --argjson c "$color" \
        --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --argjson f "$embed_fields" '
        def pretty: gsub("_"; " ") | split(" ") | map((.[0:1] | ascii_upcase) + .[1:]) | join(" ");
        {
          username: "DCS Manager",
          embeds: [{
            title: $t,
            description: $m,
            color: $c,
            timestamp: $ts,
            footer: { text: ($host + (if $ver != "" then " · DCS " + $ver else "" end)) },
            embed_fields: ([$f | to_entries[] | select(.key != "event" and .key != "timestamp" and .key != "hostname" and (.value | tostring | length) > 0)
                      | { name: (.key | pretty), value: ("`" + (.value | tostring | .[0:120]) + "`"), inline: true }] | .[0:10])
          } + (if $link != "" then { url: $link } else {} end)]
        }') || { printf '0'; return 1; }
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H 'Content-Type: application/json' --data-binary "$payload" "$url" 2>/dev/null)
    [[ "$code" =~ ^[0-9]+$ ]] || code=0
    printf '%s' "$code"
    [[ "$code" =~ ^2 ]]
}

# Every configured channel gets the message (NTFY, Discord). Prints NTFY's
# status code when NTFY is configured, otherwise Discord's; succeeds when the
# printed code is 2xx.
_notify_send() {
    local title="$1" message="$2" priority="${3:-default}" tags="${4:-}" event="${5:-}" embed_fields="${6:-{\}}" code="" dcode=""
    if _ntfy_endpoint >/dev/null 2>&1; then code=$(_ntfy_send "$title" "$message" "$priority" "$tags"); fi
    if _discord_webhook >/dev/null 2>&1; then dcode=$(_discord_send "$title" "$message" "$priority" "$event" "$embed_fields"); fi
    [[ -n "$code" ]] || code="$dcode"
    [[ -n "$code" ]] || code=0
    printf '%s' "$code"
    [[ "$code" =~ ^2 ]]
}

# Evaluate a condition trigger. Sets _AC_DETAIL (what matched) and
# _AC_MATCHED (container names, space separated) for the action.
_automation_condition_met() {
    local condition="$1" target="${2:-*}" threshold="${3:-90}"
    _AC_DETAIL=""; _AC_MATCHED=""
    [[ "$threshold" =~ ^[0-9]+$ ]] || threshold=90
    case "$condition" in
        container_unhealthy)
            local names
            names=$(docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null)
            [[ "$target" != "*" ]] && names=$(grep -Fx -- "$target" <<< "$names")
            [[ -n "$names" ]] || return 1
            _AC_MATCHED=$(tr '\n' ' ' <<< "$names"); _AC_DETAIL="unhealthy: ${_AC_MATCHED% }"
            ;;
        container_stopped)
            local names
            names=$(docker ps -a --filter status=exited --format '{{.Names}}\t{{.Status}}' 2>/dev/null | grep -v $'\t''Exited (0)' | cut -f1)
            [[ "$target" != "*" ]] && names=$(grep -Fx -- "$target" <<< "$names")
            [[ -n "$names" ]] || return 1
            _AC_MATCHED=$(tr '\n' ' ' <<< "$names"); _AC_DETAIL="stopped: ${_AC_MATCHED% }"
            ;;
        high_cpu)
            local l1 nc pct
            read -r l1 _ _ _ < /proc/loadavg 2>/dev/null || return 1
            nc=$(nproc 2>/dev/null || echo 1)
            pct=$(awk "BEGIN {printf \"%d\", $l1/$nc*100}")
            (( pct >= threshold )) || return 1
            _AC_DETAIL="cpu ${pct}% >= ${threshold}%"
            ;;
        high_memory)
            local mt ma pct
            mt=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null); ma=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null)
            [[ "${mt:-0}" -gt 0 ]] || return 1
            pct=$(( (mt - ma) * 100 / mt ))
            (( pct >= threshold )) || return 1
            _AC_DETAIL="memory ${pct}% >= ${threshold}%"
            ;;
        disk_full)
            local pct
            pct=$(df -P "$BASE_DIR" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')
            [[ "${pct:-}" =~ ^[0-9]+$ ]] || return 1
            (( pct >= threshold )) || return 1
            _AC_DETAIL="disk ${pct}% >= ${threshold}%"
            ;;
        *) return 1 ;;
    esac
    return 0
}

# Run an action. Sets _AE_SUCCESS (true|false) and _AE_MESSAGE.
_automation_execute() {
    local name="$1" action="$2" target="${3:-*}" context="${4:-}"
    _AE_SUCCESS="true"; _AE_MESSAGE=""
    local -a stacks=()
    case "$action" in
        stack_start|stack_stop|stack_restart)
            local verb="${action#stack_}"
            if [[ "$target" == "*" || -z "$target" ]]; then
                read -ra stacks <<< "${DOCKER_STACKS:-}"
            else
                stacks=("$target")
            fi
            local st ok=0 failed=0 summary=""
            for st in "${stacks[@]}"; do
                [[ -f "$COMPOSE_DIR/$st/docker-compose.yml" ]] || { summary+="$st: not found; "; failed=$((failed+1)); continue; }
                _schedule_run_action "$verb" "$st" "$name"
                if [[ "$_SR_SUCCESS" == "true" ]]; then ok=$((ok+1)); else failed=$((failed+1)); summary+="$st: ${_SR_OUTPUT:0:120}; "; fi
            done
            (( failed == 0 )) || _AE_SUCCESS="false"
            _AE_MESSAGE="${verb} ${ok} stack(s)${failed:+, ${failed} failed}${summary:+ — ${summary% }}"
            [[ "$failed" == "0" ]] && _AE_MESSAGE="${verb} ${ok} stack(s)"
            ;;
        container_restart)
            local -a names=()
            if [[ "$target" == "*" || -z "$target" ]]; then
                read -ra names <<< "${_AC_MATCHED:-}"
                [[ ${#names[@]} -eq 0 ]] && read -ra names <<< "$(docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')"
            else
                names=("$target")
            fi
            if [[ ${#names[@]} -eq 0 ]]; then
                _AE_MESSAGE="nothing to restart"
            else
                local cn out
                for cn in "${names[@]}"; do
                    if out=$(timeout 120 docker restart -- "$cn" 2>&1); then
                        _AE_MESSAGE+="restarted $cn; "
                    else
                        _AE_SUCCESS="false"; _AE_MESSAGE+="$cn: ${out:0:120}; "
                    fi
                done
                _AE_MESSAGE="${_AE_MESSAGE%; }"
            fi
            ;;
        docker_prune)
            local out
            out=$(timeout 600 docker system prune -f 2>&1) || _AE_SUCCESS="false"
            _AE_MESSAGE=$(tail -n 1 <<< "$out")
            ;;
        backup_trigger)
            local bt="$target"; [[ "$bt" == "*" ]] && bt=""
            _schedule_run_action backup "$bt" "$name"
            _AE_SUCCESS="$_SR_SUCCESS"; _AE_MESSAGE="${_SR_OUTPUT:0:200}"
            ;;
        notification_send)
            local text="${target}"
            [[ -z "$text" || "$text" == "*" ]] && text="Automation '${name}' fired${context:+ (${context})} on $(hostname 2>/dev/null)"
            local code
            code=$(_notify_send "DCS: ${name}" "$text" default "robot" "automation_run" "$(jq -nc --arg a "$name" '{automation: $a}')")
            if [[ "$code" =~ ^2 ]]; then _AE_MESSAGE="notification sent"; else _AE_SUCCESS="false"; _AE_MESSAGE="ntfy answered ${code} (check NTFY_URL/NTFY_TOPIC)"; fi
            ;;
        *)
            _AE_SUCCESS="false"; _AE_MESSAGE="unknown action: $action"
            ;;
    esac
    return 0
}

# Persist an outcome on the rule and emit audit/notification events.
_automation_record() {
    local auto_id="$1" name="$2" success="$3" message="$4" trigger="${5:-schedule}"
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local ok=false; [[ "$success" == "true" ]] && ok=true
    _api_jq_update_file "$AUTOMATIONS_FILE" --arg id "$auto_id" --arg ts "$ts" --argjson ok "$ok" \
        --arg msg "${message:0:500}" --arg trig "$trigger" --argjson max "$AUTOMATION_HISTORY_MAX" \
        'map(if .id == $id then .run_count = ((.run_count // 0) + 1) | .last_run = $ts | .last_success = $ok
              | .history = (((.history // []) + [{timestamp: $ts, success: $ok, message: $msg, trigger: $trig}]) | .[-$max:])
              else . end)' >/dev/null 2>&1 || true
    mkdir -p "$(dirname "$AUTOMATION_LOG")" 2>/dev/null
    printf '%s | %-8s | %-5s | %s | %s\n' "$ts" "$trigger" "$success" "$name" "$message" >> "$AUTOMATION_LOG" 2>/dev/null
    _audit_log "automation_run" "${name}: ${message:0:200} (success=${success}, trigger=${trigger})"
    _fire_notifications "automation_run" "automation=$name" "status=$success" "message=${message:0:200}"
}

# Evaluate every enabled rule for the minute containing EPOCH.
_automation_tick() {
    local now="$1"
    local minute=$(( now / 60 ))
    _init_automations_file
    mkdir -p "$(dirname "$AUTOMATION_STATE_FILE")" 2>/dev/null
    [[ -s "$AUTOMATION_STATE_FILE" ]] || echo '{}' > "$AUTOMATION_STATE_FILE"

    local rule
    while IFS= read -r rule; do
        [[ -z "$rule" ]] && continue
        local id name ttype tval atype atarget threshold cooldown
        id=$(jq -r '.id' <<< "$rule"); name=$(jq -r '.name' <<< "$rule")
        ttype=$(jq -r '.trigger_type' <<< "$rule"); tval=$(jq -r '.trigger_value // ""' <<< "$rule")
        atype=$(jq -r '.action_type' <<< "$rule"); atarget=$(jq -r '.action_target // "*"' <<< "$rule")
        threshold=$(jq -r '.threshold // 90' <<< "$rule"); cooldown=$(jq -r ".cooldown // $AUTOMATION_CONDITION_COOLDOWN" <<< "$rule")
        local last_minute last_fire
        last_minute=$(jq -r --arg id "$id" '.[$id].minute // -1' "$AUTOMATION_STATE_FILE" 2>/dev/null)
        last_fire=$(jq -r --arg id "$id" '.[$id].fired // 0' "$AUTOMATION_STATE_FILE" 2>/dev/null)
        [[ "$last_minute" =~ ^-?[0-9]+$ ]] || last_minute=-1
        [[ "$last_fire" =~ ^[0-9]+$ ]] || last_fire=0
        local fire=false context=""
        if [[ "$ttype" == "schedule" ]]; then
            (( minute != last_minute )) && _cron_matches "$tval" "$now" && fire=true
        elif [[ "$ttype" == "condition" ]]; then
            if (( now - last_fire >= cooldown )) && _automation_condition_met "$tval" "$atarget" "$threshold"; then
                fire=true; context="$_AC_DETAIL"
            fi
        fi
        [[ "$fire" == "true" ]] || continue
        _api_jq_update_file "$AUTOMATION_STATE_FILE" --arg id "$id" --argjson m "$minute" --argjson f "$now" \
            '.[$id] = {minute: $m, fired: $f}' >/dev/null 2>&1 || true
        _automation_execute "$name" "$atype" "$atarget" "$context"
        _automation_record "$id" "$name" "$_AE_SUCCESS" "${context:+${context}: }${_AE_MESSAGE}" "$ttype"
    done < <(jq -c '.[] | select(.enabled == true)' "$AUTOMATIONS_FILE" 2>/dev/null)

    # Schedules (the Schedules page) run through the same clock
    local sched_file="$BASE_DIR/.data/schedules/schedules.json"
    [[ -s "$sched_file" ]] || return 0
    local entry
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local sid scron saction starget sname key last
        sid=$(jq -r '.id' <<< "$entry"); scron=$(jq -r '.cron // .schedule // ""' <<< "$entry")
        saction=$(jq -r '.action // ""' <<< "$entry"); starget=$(jq -r '.target // ""' <<< "$entry"); sname=$(jq -r '.name // ""' <<< "$entry")
        [[ -n "$scron" && -n "$saction" ]] || continue
        key="sched:$sid"
        last=$(jq -r --arg id "$key" '.[$id].minute // -1' "$AUTOMATION_STATE_FILE" 2>/dev/null)
        [[ "$last" =~ ^-?[0-9]+$ ]] || last=-1
        (( minute != last )) || continue
        _cron_matches "$scron" "$now" || continue
        _api_jq_update_file "$AUTOMATION_STATE_FILE" --arg id "$key" --argjson m "$minute" --argjson f "$now" \
            '.[$id] = {minute: $m, fired: $f}' >/dev/null 2>&1 || true
        if _api_validate_schedule_target "$saction" "$starget" >/dev/null 2>&1; then
            _schedule_run_action "$saction" "$starget" "$sname"
            _schedule_finish "$sid" "$sname" "$saction" "$starget" "$_SR_SUCCESS" "$_SR_OUTPUT" "schedule"
            printf '%s | schedule | %-5s | %s | %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$_SR_SUCCESS" "$sname" "${_SR_OUTPUT:0:200}" >> "$AUTOMATION_LOG" 2>/dev/null
        fi
    done < <(jq -c '.[] | select(.enabled == true)' "$sched_file" 2>/dev/null)
}

# Background loop started by start_server. Errors in one rule never stop it.
_dcs_automation_loop() {
    trap 'kill "${_sleep_pid:-}" 2>/dev/null; exit 0' TERM INT
    set +e
    local last_minute=-1 now minute
    while true; do
        now=$(date +%s); minute=$(( now / 60 ))
        if (( minute != last_minute )); then
            last_minute=$minute
            _automation_tick "$now" </dev/null >>"$AUTOMATION_LOG" 2>&1
            (( minute % 10 == 0 )) && _crowdsec_whitelist_sync >/dev/null 2>&1
            # keep the log bounded
            if [[ -f "$AUTOMATION_LOG" ]] && (( $(wc -c < "$AUTOMATION_LOG" 2>/dev/null || echo 0) > 1048576 )); then
                tail -n 2000 "$AUTOMATION_LOG" > "$AUTOMATION_LOG.tmp" 2>/dev/null && mv -f "$AUTOMATION_LOG.tmp" "$AUTOMATION_LOG"
            fi
        fi
        sleep 20 & _sleep_pid=$!
        wait "$_sleep_pid" || true
    done
}

# POST /automations/{id}/run — Run an automation now
handle_automation_run() {
    local auto_id="$1"
    _init_automations_file
    local rule
    rule=$(jq -c --arg id "$auto_id" 'map(select(.id == $id))[0] // empty' "$AUTOMATIONS_FILE" 2>/dev/null)
    if [[ -z "$rule" ]]; then
        _api_error 404 "Automation not found: $auto_id"
        return
    fi
    local name atype atarget
    name=$(jq -r '.name' <<< "$rule"); atype=$(jq -r '.action_type' <<< "$rule"); atarget=$(jq -r '.action_target // "*"' <<< "$rule")
    _AC_MATCHED=""
    _automation_execute "$name" "$atype" "$atarget" "manual run"
    _automation_record "$auto_id" "$name" "$_AE_SUCCESS" "$_AE_MESSAGE" "manual"
    _api_success "{\"success\": $_AE_SUCCESS, \"id\": \"$(_api_json_escape "$auto_id")\", \"action\": \"$(_api_json_escape "$atype")\", \"message\": \"$(_api_json_escape "$_AE_MESSAGE")\"}"
}

# GET /routes/health — Probe every custom route through Traefik (no changes made)
handle_routes_health() {
    local out
    out=$("$BASE_DIR/.scripts/proxy-reconcile.sh" --json --dry-run 2>/dev/null) || true
    [[ -z "$out" ]] && out='{"status": "unavailable"}'
    _api_success "$out"
}

# POST /routes/reconcile — Probe the routes and restart Traefik once if they are dead
handle_routes_reconcile() {
    local out
    out=$("$BASE_DIR/.scripts/proxy-reconcile.sh" --json 2>/dev/null) || true
    [[ -z "$out" ]] && out='{"status": "unavailable"}'
    _api_audit_log "${CLIENT_IP:-unknown}" "PROXY_RECONCILE" "${AUTH_USERNAME:-}" "$(printf '%s' "$out" | jq -r '.status // "?"')"
    _api_success "$out"
}

# =============================================================================
# FEATURE: CROWDSEC INTEGRATION
# Keeps a CrowdSec whitelist in step with the addresses that must never be
# banned (the home public IP, which DDNS already tracks, plus admin additions)
# and exposes decisions so a self-ban is one click away instead of an SSH
# session. Works with the crowdsec template: /etc/crowdsec is the bind-mounted
# App-Data/CrowdSec/config directory, so the parser file is written there and
# CrowdSec is told to reload.
# =============================================================================

CROWDSEC_TRUSTED_FILE="$BASE_DIR/.data/crowdsec-trusted.json"
CROWDSEC_SYNC_STATE="$BASE_DIR/.data/crowdsec-whitelist.json"

_crowdsec_valid_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        local o
        IFS='./' read -ra o <<< "$ip"
        [[ ${o[0]} -le 255 && ${o[1]} -le 255 && ${o[2]} -le 255 && ${o[3]} -le 255 ]] || return 1
        [[ -z "${o[4]:-}" || ${o[4]} -le 32 ]] || return 1
        return 0
    fi
    [[ "$ip" =~ ^[0-9A-Fa-f:]{2,39}(/[0-9]{1,3})?$ && "$ip" == *:* ]] && return 0
    return 1
}

_crowdsec_is_private_ip() {
    case "$1" in
        10.*|192.168.*|127.*|169.254.*|::1|fc*|fd*|fe80*) return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
    esac
    return 1
}

# Name of the running CrowdSec container (compose service "crowdsec", or a
# container named CrowdSec/crowdsec).
_crowdsec_container() {
    local c
    c=$(docker ps --filter "label=com.docker.compose.service=crowdsec" --format '{{.Names}}' 2>/dev/null | head -1)
    [[ -z "$c" ]] && c=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -ixE 'crowdsec' | head -1)
    [[ -n "$c" ]] && printf '%s' "$c"
}

# Host directory mounted at /etc/crowdsec in that container.
_crowdsec_config_dir() {
    docker inspect "$1" --format '{{range .Mounts}}{{if eq .Destination "/etc/crowdsec"}}{{.Source}}{{end}}{{end}}' 2>/dev/null
}

# Current public address: the DDNS loop's record when it is recent, otherwise
# a direct lookup (only called from the server loop or an admin request).
_crowdsec_public_ip() {
    local ip=""
    if [[ -f "$DDNS_IP_FILE" ]] && [[ $(( $(date +%s) - $(stat -c %Y "$DDNS_IP_FILE" 2>/dev/null || echo 0) )) -lt 86400 ]]; then
        ip=$(head -c 64 "$DDNS_IP_FILE" 2>/dev/null | tr -d '[:space:]')
    fi
    if [[ -z "$ip" ]]; then
        ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')
        [[ -z "$ip" ]] && ip=$(curl -s --max-time 5 https://ifconfig.me/ip 2>/dev/null | tr -d '[:space:]')
    fi
    _crowdsec_valid_ip "$ip" && printf '%s' "$ip"
}

_crowdsec_trusted_list() {
    [[ -f "$CROWDSEC_TRUSTED_FILE" ]] && jq -r '.ips[]? // empty' "$CROWDSEC_TRUSTED_FILE" 2>/dev/null
    local extra
    IFS=',' read -ra extra <<< "${CROWDSEC_TRUSTED_IPS:-}"
    local e
    for e in "${extra[@]}"; do e="${e// /}"; [[ -n "$e" ]] && echo "$e"; done
}

# Write parsers/s02-enrich/dcs-whitelist.yaml and reload CrowdSec when the set
# of addresses changed. Returns 0 when in sync, 1 when CrowdSec is absent.
_crowdsec_whitelist_sync() {
    local container dir
    container=$(_crowdsec_container) || return 1
    [[ -n "$container" ]] || return 1
    dir=$(_crowdsec_config_dir "$container")
    [[ -n "$dir" && -d "$dir" ]] || return 1

    local -a ips=() cidrs=()
    local public_ip a
    public_ip=$(_crowdsec_public_ip) || public_ip=""
    while IFS= read -r a; do
        [[ -z "$a" ]] || _crowdsec_valid_ip "$a" || continue
        [[ -z "$a" ]] && continue
        if [[ "$a" == */* ]]; then cidrs+=("$a"); else ips+=("$a"); fi
    done < <({ [[ -n "$public_ip" ]] && echo "$public_ip"; _crowdsec_trusted_list; } | sort -u)

    local content="name: custom/dcs-whitelist"$'\n'
    content+="description: \"Addresses trusted by DCS: the home public IP (kept current by DDNS) and admin additions\""$'\n'
    content+="# Managed by DCS — edit the trusted list from the UI or the API, not here."$'\n'
    content+="whitelist:"$'\n'"  reason: \"trusted by DCS\""$'\n'
    if [[ ${#ips[@]} -gt 0 ]]; then content+="  ip:"$'\n'; for a in "${ips[@]}"; do content+="    - $a"$'\n'; done; fi
    if [[ ${#cidrs[@]} -gt 0 ]]; then content+="  cidr:"$'\n'; for a in "${cidrs[@]}"; do content+="    - $a"$'\n'; done; fi
    [[ ${#ips[@]} -eq 0 && ${#cidrs[@]} -eq 0 ]] && content+="  ip: []"$'\n'

    local target="$dir/parsers/s02-enrich/dcs-whitelist.yaml"
    mkdir -p "$dir/parsers/s02-enrich" 2>/dev/null
    local changed=false
    if [[ ! -f "$target" ]] || [[ "$(cat "$target" 2>/dev/null)" != "$content" ]]; then
        printf '%s' "$content" > "$target.tmp" && mv -f "$target.tmp" "$target" && changed=true
        docker kill -s HUP "$container" >/dev/null 2>&1 || true
    fi
    mkdir -p "$(dirname "$CROWDSEC_SYNC_STATE")" 2>/dev/null
    jq -n --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg pub "$public_ip" --arg file "$target" --argjson changed "$changed" \
        --argjson ips "$(printf '%s\n' "${ips[@]}" "${cidrs[@]}" | grep -v '^$' | jq -R . | jq -s .)" \
        '{synced_at: $ts, public_ip: $pub, file: $file, addresses: $ips, reloaded: $changed}' > "$CROWDSEC_SYNC_STATE" 2>/dev/null
    return 0
}

_crowdsec_decisions_json() {
    local container="$1"
    docker exec "$container" cscli decisions list -o json 2>/dev/null | jq -c '
        [ (if type == "array" then .[] else empty end)
          | . as $a | ($a.decisions // [])[]
          | {ip: .value, scope: .scope, scenario: .scenario, origin: .origin, duration: .duration, type: .type,
             since: ($a.created_at // ""), country: ($a.source.cn // "")} ]' 2>/dev/null || echo "[]"
}

# GET /crowdsec/status — CrowdSec presence, whitelist state and active decisions
handle_crowdsec_status() {
    local container
    container=$(_crowdsec_container) || container=""
    if [[ -z "$container" ]]; then
        _api_success "{\"installed\": false, \"running\": false, \"message\": \"CrowdSec is not running. Deploy the crowdsec template to enable protection.\"}"
        return
    fi
    local state="{}" decisions
    [[ -f "$CROWDSEC_SYNC_STATE" ]] && state=$(cat "$CROWDSEC_SYNC_STATE" 2>/dev/null)
    decisions=$(_crowdsec_decisions_json "$container")
    local trusted
    trusted=$(_crowdsec_trusted_list | jq -R . | jq -s -c .)
    local client="${CLIENT_IP:-}"
    local client_banned=false
    [[ -n "$client" ]] && printf '%s' "$decisions" | jq -e --arg ip "$client" 'map(select(.ip == $ip)) | length > 0' >/dev/null 2>&1 && client_banned=true
    _api_success "{\"installed\": true, \"running\": true, \"container\": \"$(_api_json_escape "$container")\", \"client_ip\": \"$(_api_json_escape "$client")\", \"client_banned\": $client_banned, \"trusted\": $trusted, \"whitelist\": $state, \"decisions\": $decisions, \"decision_count\": $(printf '%s' "$decisions" | jq 'length')}"
}

# GET /crowdsec/decisions — Active CrowdSec decisions (bans)
handle_crowdsec_decisions() {
    local container
    container=$(_crowdsec_container) || container=""
    [[ -z "$container" ]] && { _api_error 404 "CrowdSec is not running"; return; }
    local decisions
    decisions=$(_crowdsec_decisions_json "$container")
    _api_success "{\"decisions\": $decisions, \"count\": $(printf '%s' "$decisions" | jq 'length')}"
}

# DELETE /crowdsec/decisions/{ip} — Remove every decision for an address (unban)
handle_crowdsec_unban() {
    local ip="$1"
    _crowdsec_valid_ip "$ip" || { _api_error 400 "Invalid IP address: $ip"; return; }
    local container
    container=$(_crowdsec_container) || container=""
    [[ -z "$container" ]] && { _api_error 404 "CrowdSec is not running"; return; }
    local out
    out=$(docker exec "$container" cscli decisions delete --ip "$ip" 2>&1) || { _api_error 502 "cscli failed: $(printf '%s' "$out" | tail -n 1)"; return; }
    _api_audit_log "${CLIENT_IP:-unknown}" "CROWDSEC_UNBAN" "${AUTH_USERNAME:-}" "$ip"
    _api_success "{\"success\": true, \"ip\": \"$(_api_json_escape "$ip")\", \"message\": \"$(_api_json_escape "$(printf '%s' "$out" | tail -n 1)")\"}"
}

# POST /crowdsec/unban-me — Unban the caller: its client address and the home public address
handle_crowdsec_unban_me() {
    local container
    container=$(_crowdsec_container) || container=""
    [[ -z "$container" ]] && { _api_error 404 "CrowdSec is not running"; return; }
    local -a targets=()
    [[ -n "${CLIENT_IP:-}" ]] && _crowdsec_valid_ip "$CLIENT_IP" && ! _crowdsec_is_private_ip "$CLIENT_IP" && targets+=("$CLIENT_IP")
    local pub
    pub=$(_crowdsec_public_ip) || pub=""
    [[ -n "$pub" && "$pub" != "${CLIENT_IP:-}" ]] && targets+=("$pub")
    [[ ${#targets[@]} -eq 0 ]] && { _api_error 400 "Could not determine a public address to unban"; return; }
    local t _summary=""
    for t in "${targets[@]}"; do
        local out
        out=$(docker exec "$container" cscli decisions delete --ip "$t" 2>&1 | tail -n 1)
        _summary+="$t: ${out}; "
    done
    _api_audit_log "${CLIENT_IP:-unknown}" "CROWDSEC_UNBAN" "${AUTH_USERNAME:-}" "${targets[*]}"
    _api_success "{\"success\": true, \"addresses\": $(printf '%s\n' "${targets[@]}" | jq -R . | jq -s -c .), \"message\": \"$(_api_json_escape "${_summary%; }")\"}"
}

# POST /crowdsec/trust — Add an address to the whitelist (body {ip}; defaults to the home public address and the caller)
handle_crowdsec_trust() {
    local body="$1"
    local ip
    ip=$(printf '%s' "$body" | jq -r '.ip // empty' 2>/dev/null)
    local -a add=()
    if [[ -n "$ip" ]]; then
        _crowdsec_valid_ip "$ip" || { _api_error 400 "Invalid IP address or CIDR: $ip"; return; }
        add+=("$ip")
    else
        local pub
        pub=$(_crowdsec_public_ip) || pub=""
        [[ -n "$pub" ]] && add+=("$pub")
        [[ -n "${CLIENT_IP:-}" ]] && _crowdsec_valid_ip "$CLIENT_IP" && ! _crowdsec_is_private_ip "$CLIENT_IP" && [[ "$CLIENT_IP" != "$pub" ]] && add+=("$CLIENT_IP")
        [[ ${#add[@]} -eq 0 ]] && { _api_error 400 "Could not determine a public address; pass {\"ip\": \"...\"}"; return; }
    fi
    mkdir -p "$(dirname "$CROWDSEC_TRUSTED_FILE")" 2>/dev/null
    [[ -s "$CROWDSEC_TRUSTED_FILE" ]] || echo '{"ips": []}' > "$CROWDSEC_TRUSTED_FILE"
    local a
    for a in "${add[@]}"; do
        _api_jq_update_file "$CROWDSEC_TRUSTED_FILE" --arg ip "$a" --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
            '.ips = ((.ips // []) + [$ip] | unique) | .updated = $ts' >/dev/null 2>&1
    done
    local synced=true
    _crowdsec_whitelist_sync || synced=false
    # A trusted address must not stay banned either
    local container
    container=$(_crowdsec_container) || container=""
    if [[ -n "$container" ]]; then
        for a in "${add[@]}"; do docker exec "$container" cscli decisions delete --ip "${a%%/*}" >/dev/null 2>&1 || true; done
    fi
    _api_audit_log "${CLIENT_IP:-unknown}" "CROWDSEC_TRUST" "${AUTH_USERNAME:-}" "${add[*]}"
    _api_success "{\"success\": true, \"addresses\": $(printf '%s\n' "${add[@]}" | jq -R . | jq -s -c .), \"synced\": $synced, \"trusted\": $(_crowdsec_trusted_list | jq -R . | jq -s -c .)}"
}

# DELETE /crowdsec/trust/{ip} — Remove an address from the whitelist
handle_crowdsec_untrust() {
    local ip="$1"
    _crowdsec_valid_ip "$ip" || { _api_error 400 "Invalid IP address or CIDR: $ip"; return; }
    [[ -s "$CROWDSEC_TRUSTED_FILE" ]] || { _api_error 404 "Address is not in the trusted list"; return; }
    _api_jq_update_file "$CROWDSEC_TRUSTED_FILE" --arg ip "$ip" '.ips = ((.ips // []) - [$ip])' >/dev/null 2>&1
    local synced=true
    _crowdsec_whitelist_sync || synced=false
    _api_audit_log "${CLIENT_IP:-unknown}" "CROWDSEC_UNTRUST" "${AUTH_USERNAME:-}" "$ip"
    _api_success "{\"success\": true, \"removed\": \"$(_api_json_escape "$ip")\", \"synced\": $synced, \"trusted\": $(_crowdsec_trusted_list | jq -R . | jq -s -c .)}"
}

# =============================================================================
# FEATURE: NETWORK TOPOLOGY MAP
# =============================================================================

# GET /topology — Container and network topology graph
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
# GET /setup/defaults — Defaults and detected system values for the setup wizard (anonymous until setup is complete, admin afterwards)
handle_setup_defaults() {
    # Anonymous while the first-run wizard needs it; admins only once setup is
    # complete (the UI's server-config page reads the same defaults).
    if _api_is_initialized; then
        if ! _api_check_auth; then
            _api_error 401 "${AUTH_ERROR:-Authentication required. Provide Authorization: Bearer <token> header.}"
            return
        fi
        if [[ "${AUTH_ROLE:-}" != "admin" ]]; then
            _api_error 403 "Admin access required"
            return
        fi
    fi

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
                # This endpoint is unauthenticated while setup is incomplete:
                # never echo stored credentials back
                case "${okey^^}" in
                    *TOKEN*|*PASSWORD*|*SECRET*|*_KEY|*CREDENTIAL*) [[ -n "$oval" ]] && oval="********" ;;
                esac
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
# POST /setup/configure — Apply the setup wizard's settings and stack list
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

    # Work on a private copy and swap it in at the end. Every value goes
    # through _envfile_set in bash mode, so whatever the user typed (spaces,
    # quotes, dollars) survives both the scripts' `source` and the API's parser.
    local tmp_env="${env_file}.tmp"
    (umask 077; cp "$env_file" "$tmp_env") || { _api_error 500 "Cannot write .env"; return; }

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
        val=$(printf '%s' "$val" | tr -d '\n\r')
        local _problem
        if ! _problem=$(_api_validate_env_kv "$key" "$val"); then
            rm -f "$tmp_env"
            _api_error 400 "Rejected value for $key: $_problem"
            return
        fi
        _envfile_set "$tmp_env" "$key" "$val" bash || { rm -f "$tmp_env"; _api_error 500 "Cannot write .env"; return; }
        env_updated=$(( env_updated + 1 ))
    done

    # Always set DOCKER_STACKS (under its own header when the key is new)
    if ! grep -q '^DOCKER_STACKS=' "$tmp_env" 2>/dev/null; then
        printf '\n# ─── Stack Configuration ─────────────────────────────────────────────────────\n' >> "$tmp_env"
    fi
    _envfile_set "$tmp_env" DOCKER_STACKS "$docker_stacks_str" bash || { rm -f "$tmp_env"; _api_error 500 "Cannot write .env"; return; }

    # Swap in (private: it holds tokens)
    mv -f "$tmp_env" "$env_file"

    # Sync stack directories
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
                # Only an untouched placeholder is removed: no real service
                # definitions (image: lines) and nothing stored under App-Data.
                # Anything else is kept and reported.
                local service_count data_entries
                service_count=$(grep -cE '^\s+image:' "$existing_dir/docker-compose.yml" 2>/dev/null) || service_count=0
                data_entries=$(find "$existing_dir/App-Data" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
                if [[ "$service_count" -eq 0 && "$data_entries" -eq 0 ]]; then
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
# POST /setup/complete — Mark first-run setup as finished
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

    # Update DOCKER_STACKS in .env by exact token (a regex word boundary would
    # also match inside hyphenated names such as media-services)
    if [[ -f "$BASE_DIR/.env" ]] && grep -q '^DOCKER_STACKS=' "$BASE_DIR/.env"; then
        local _ds _new_ds="" _tok
        _ds=$(grep -m1 '^DOCKER_STACKS=' "$BASE_DIR/.env" | cut -d= -f2- | tr -d '"' | tr -d "'")
        for _tok in $_ds; do
            [[ "$_tok" == "$old_name" ]] && _tok="$new_name"
            _new_ds+="${_new_ds:+ }$_tok"
        done
        sed -i "s|^DOCKER_STACKS=.*|DOCKER_STACKS=\"${_new_ds}\"|" "$BASE_DIR/.env"
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

# GET /metrics/history — Metrics samples for a range (range=1h|6h|24h|7d|30d|90d|1y|all); same data as /metrics/trends under "data"
handle_metrics_history() {
    local range="${QUERY_PARAMS[range]:-1h}"
    _api_success "$(_metrics_points "$range" | jq -c '. + {data: .points} | del(.points)')"
}

# GET /metrics/summary — Min, max and average CPU, memory and disk over a range (range=1h|6h|24h|7d|30d|90d|1y|all)
handle_metrics_summary() {
    local range="${QUERY_PARAMS[range]:-1h}"
    _api_success "$(_metrics_points "$range" | jq -c '
        def num(f): ((f // 0) | tonumber? // 0);
        def stat(a; lo; hi): if (a | length) == 0 then {avg: 0, min: 0, max: 0}
            else {avg: ((a | add) / (a | length) * 10 | round / 10), min: (lo | min), max: (hi | max)} end;
        .points as $p
        | { range: .range, samples: .total, points: .count, resolution_s: .resolution_s, oldest_epoch: .oldest_epoch, newest_epoch: .newest_epoch,
            cpu: stat($p | map(num(.cpu_pct)); $p | map(num(.cpu_min // .cpu_pct)); $p | map(num(.cpu_max // .cpu_pct))),
            mem: stat($p | map(num(.mem_pct)); $p | map(num(.mem_min // .mem_pct)); $p | map(num(.mem_max // .mem_pct))),
            disk: stat($p | map(num(.disk_pct)); $p | map(num(.disk_min // .disk_pct)); $p | map(num(.disk_max // .disk_pct))) }')"
}

# =============================================================================
# FEATURE: ROLLBACK MANAGEMENT
# =============================================================================

# GET /rollback/<stack>/snapshots
# List all rollback snapshots for a stack
# GET /rollback/{stack}/snapshots — Rollback snapshots of a stack
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

# Snapshot ids are directory names under .data/rollback/<stack>/ — plain
# tokens only, never path components
_api_validate_snapshot_id() {
    if [[ -z "$1" || ${#1} -gt 64 || ! "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || "$1" == *..* ]]; then
        _api_error 400 "Invalid snapshot id"
        return 1
    fi
    return 0
}

# GET /rollback/<stack>/snapshots/<timestamp>
# Return metadata.json content for a specific snapshot
# GET /rollback/{stack}/snapshots/{snapshot} — Content of a rollback snapshot
handle_rollback_snapshot_detail() {
    local stack="$1"
    local timestamp="$2"
    _api_validate_snapshot_id "$timestamp" || return
    local snap_dir="$BASE_DIR/.data/rollback/$stack/$timestamp"

    if [[ ! -d "$snap_dir" ]]; then
        _api_error 404 "Snapshot not found: $stack/$timestamp"
        return
    fi

    local meta="{}"
    [[ -f "$snap_dir/metadata.json" ]] && meta=$(jq -c '.' "$snap_dir/metadata.json" 2>/dev/null || echo "{}")

    local compose_content=""
    if [[ -f "$snap_dir/docker-compose.yml" ]]; then
        compose_content=$(_api_json_escape "$(cat "$snap_dir/docker-compose.yml" 2>/dev/null)")
    fi

    local env_content=""
    if [[ -f "$snap_dir/.env" ]]; then
        env_content=$(_api_json_escape "$(cat "$snap_dir/.env" 2>/dev/null)")
    fi

    local images="[]"
    [[ -f "$snap_dir/images.json" ]] && images=$(jq -c '.' "$snap_dir/images.json" 2>/dev/null || echo "[]")

    _api_success "{\"stack\": \"$(_api_json_escape "$stack")\", \"timestamp\": \"$(_api_json_escape "$timestamp")\", \"metadata\": $meta, \"compose\": \"$compose_content\", \"env\": \"$env_content\", \"images\": $images}"
}

# POST /rollback/<stack>/restore — body: {"timestamp": "..."}
# Restore a snapshot: copy files back, pull images, restart stack
# POST /rollback/{stack}/restore — Restore a stack from a rollback snapshot (policy-scanned)
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

    _api_validate_snapshot_id "$timestamp" || return

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

    # The archived compose goes through the same policy as a fresh edit
    if [[ -f "$snap_dir/docker-compose.yml" ]]; then
        local _scan_mode="strict"
        [[ -f "$stack_dir/.dcs-trusted-templates" ]] && _scan_mode="deploy"
        _api_scan_compose_security "$(cat "$snap_dir/docker-compose.yml")" "rollback of $stack" "$_scan_mode" || return
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

    # Pull the images recorded in the snapshot (entries are either plain
    # references or {name, digest} objects written by .lib/rollback.sh)
    if [[ -f "$snap_dir/images.json" ]]; then
        local img
        while IFS= read -r img; do
            [[ -z "$img" || "$img" == "unknown" ]] && continue
            [[ "$img" =~ ^[a-zA-Z0-9][a-zA-Z0-9._:/@-]*$ ]] || continue
            timeout 600 docker pull "$img" >/dev/null 2>&1 || true
        done < <(jq -r '.[] | if type == "object" then (.digest // .name // empty) else . end' "$snap_dir/images.json" 2>/dev/null)
    fi

    # Restart the stack with restored files
    local _env_file=""
    [[ -f "$stack_dir/.env" ]] && _env_file="$stack_dir/.env"
    _compose_with_secrets "$stack_dir/docker-compose.yml" "$_env_file" up -d >/dev/null 2>&1 || true

    _api_success "{\"success\": true, \"stack\": \"$(_api_json_escape "$stack")\", \"restored_from\": \"$(_api_json_escape "$timestamp")\", \"message\": \"Stack restored and restarted\"}"
}

# GET /rollback/<stack>/diff/<timestamp>
# Diff current compose/env against snapshot
# GET /rollback/{stack}/diff/{snapshot} — Diff between a snapshot and the current stack files
handle_rollback_diff() {
    local stack="$1"
    local timestamp="$2"
    _api_validate_snapshot_id "$timestamp" || return
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

# The store, the name rule and compose injection live in .lib/secrets.sh so
# that start.sh, stack-manager.sh, the scheduler and the API behave the same.
# shellcheck source=/dev/null
source "$BASE_DIR/.lib/secrets.sh"
# Quoting rules shared with the shell scripts (.env is sourced by them, read as data here)
source "$BASE_DIR/.lib/envfile.sh"

# GET /secrets — List secret key names (never values)
handle_secrets_list() {
    local json="[]"
    [[ -d "$SECRETS_DIR" ]] && json=$(secrets_list_json)
    _api_success "{\"secrets\": $json, \"count\": $(printf '%s' "$json" | jq 'length'), \"name_rule\": \"$SECRETS_NAME_RE\"}"
}

# POST /secrets — body: {"key": "...", "value": "..."}
# Encrypt and store a secret value
# POST /secrets — Store an encrypted secret (also POST /secrets/{key})
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
    if [[ ! "$key" =~ $SECRETS_NAME_RE ]]; then
        _api_error 400 "Invalid secret name. Use letters, digits and underscores, starting with a letter (e.g. HOMARR_PASSWORD); it is referenced as \${SECRETS_NAME} in compose and .env files."
        return
    fi
    if [[ ${#value} -gt 65536 ]]; then
        _api_error 400 "Secret values are limited to 64 KB"
        return
    fi
    local existed=false
    secrets_exists "$key" && existed=true
    if ! secrets_set "$key" "$value" 2>/dev/null; then
        _api_error 500 "Failed to encrypt and store the secret"
        return
    fi
    _api_audit_log "${CLIENT_IP:-unknown}" "SECRET_SET" "${AUTH_USERNAME:-}" "$key (replaced=$existed)"
    _api_success "{\"success\": true, \"key\": \"$(_api_json_escape "$key")\", \"replaced\": $existed, \"reference\": \"\${SECRETS_$(_api_json_escape "$key")}\", \"message\": \"Secret stored. Restart stacks that reference it for the new value to apply.\"}"
}

# DELETE /secrets/<key> — Securely delete a secret
handle_secret_delete() {
    local key="$1"

    if [[ ! "$key" =~ $SECRETS_NAME_RE ]]; then
        _api_error 400 "Invalid secret name"
        return
    fi
    if ! secrets_exists "$key"; then
        _api_error 404 "Secret not found: $key"
        return
    fi
    secrets_delete "$key" 2>/dev/null || { _api_error 500 "Failed to delete secret"; return; }
    _api_audit_log "${CLIENT_IP:-unknown}" "SECRET_DELETE" "${AUTH_USERNAME:-}" "$key"
    _api_success "{\"success\": true, \"key\": \"$(_api_json_escape "$key")\", \"message\": \"Secret deleted securely\"}"
}

# GET /secrets/<key>/exists — Check if a secret exists (boolean)
handle_secret_exists() {
    local key="$1"

    if [[ ! "$key" =~ $SECRETS_NAME_RE ]]; then
        _api_error 400 "Invalid secret name"
        return
    fi
    local exists="false"
    secrets_exists "$key" && exists="true"
    _api_success "{\"key\": \"$(_api_json_escape "$key")\", \"exists\": $exists}"
}

# GET /secrets/{key}/references — Stacks and env files that reference a secret
handle_secret_references() {
    local key="$1"
    if [[ ! "$key" =~ $SECRETS_NAME_RE ]]; then
        _api_error 400 "Invalid secret name"
        return
    fi
    local -a stacks=()
    local d
    for d in "$COMPOSE_DIR"/*/; do
        [[ -d "$d" ]] || continue
        if grep -qE "SECRETS_${key}([^A-Za-z0-9_]|$)" "$d/docker-compose.yml" "$d/.env" 2>/dev/null; then
            stacks+=("\"$(_api_json_escape "$(basename "$d")")\"")
        fi
    done
    local root_env=false
    grep -qE "SECRETS_${key}([^A-Za-z0-9_]|$)" "$BASE_DIR/.env" 2>/dev/null && root_env=true
    local list="[]"
    [[ ${#stacks[@]} -gt 0 ]] && list="[$(IFS=,; echo "${stacks[*]}")]"
    local exists="false"
    secrets_exists "$key" && exists="true"
    _api_success "{\"key\": \"$(_api_json_escape "$key")\", \"exists\": $exists, \"stacks\": $list, \"root_env\": $root_env, \"reference\": \"\${SECRETS_$(_api_json_escape "$key")}\"}"
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
# POST /schedules — Create a scheduled task
handle_schedule_create() {
    local body="$1"
    local sched_dir="$BASE_DIR/.data/schedules"
    local sched_file="$sched_dir/schedules.json"
    mkdir -p "$sched_dir"

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for schedule management"
        return
    fi

    # Validate required fields (accept both "cron" and "schedule" for the expression)
    local name action cron
    name=$(echo "$body" | jq -r '.name // empty' 2>/dev/null)
    action=$(echo "$body" | jq -r '.action // empty' 2>/dev/null)
    cron=$(echo "$body" | jq -r '.cron // .schedule // empty' 2>/dev/null)

    if [[ -z "$name" ]] || [[ -z "$action" ]] || [[ -z "$cron" ]]; then
        _api_error 400 "Missing required fields: name, action, and schedule"
        return
    fi
    if ! _validate_cron_expression "$cron"; then
        _api_error 400 "Invalid cron expression: $cron"
        return
    fi
    local _target
    _target=$(echo "$body" | jq -r '.target // empty' 2>/dev/null)
    _api_validate_schedule_target "$action" "$_target" || return

    # Normalize: ensure both "cron" and "schedule" fields are present in the stored entry
    body=$(echo "$body" | jq --arg c "$cron" 'select(type == "object") | . + {cron: $c, schedule: $c}' 2>/dev/null)
    if [[ -z "$body" ]]; then
        _api_error 400 "Request body must be a JSON object"
        return
    fi

    # Generate unique ID
    local id
    id="sched_$(date +%s)_$$"

    # Build new entry with id, enabled=true, and created timestamp
    local new_entry
    new_entry=$(echo "$body" | jq --arg id "$id" --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        '. + {id: $id, enabled: true, created: $ts}' 2>/dev/null)

    # Append to schedules array (write to a temp file: a redirect would
    # truncate the store before jq ran)
    local current="[]"
    [[ -f "$sched_file" ]] && current=$(cat "$sched_file" 2>/dev/null)
    jq -e 'type == "array"' <<< "$current" >/dev/null 2>&1 || current="[]"
    if ! echo "$current" | jq --argjson entry "$new_entry" '. + [$entry]' > "${sched_file}.tmp" 2>/dev/null; then
        rm -f "${sched_file}.tmp"
        _api_error 500 "Failed to save schedule"
        return
    fi
    mv -f "${sched_file}.tmp" "$sched_file"

    _api_success "{\"success\": true, \"schedule\": $new_entry}"
}

# POST /schedules/<id>/update — body: updated fields
# Update an existing schedule
# POST /schedules/{id}/update — Update a scheduled task
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

    # The body must be an object; validate any new cron/target before merging
    if ! jq -e 'type == "object"' <<< "$body" >/dev/null 2>&1; then
        _api_error 400 "Request body must be a JSON object"
        return
    fi
    local _ncron _naction _ntarget
    _ncron=$(jq -r '.cron // .schedule // empty' <<< "$body" 2>/dev/null)
    if [[ -n "$_ncron" ]] && ! _validate_cron_expression "$_ncron"; then
        _api_error 400 "Invalid cron expression: $_ncron"
        return
    fi
    [[ -n "$_ncron" ]] && body=$(jq --arg c "$_ncron" '. + {cron: $c, schedule: $c}' <<< "$body")
    _naction=$(jq -r '.action // empty' <<< "$body" 2>/dev/null)
    [[ -z "$_naction" ]] && _naction=$(jq -r --arg id "$sched_id" '.[] | select(.id == $id) | .action // empty' "$sched_file" 2>/dev/null)
    _ntarget=$(jq -r '.target // empty' <<< "$body" 2>/dev/null)
    [[ -z "$_ntarget" ]] && _ntarget=$(jq -r --arg id "$sched_id" '.[] | select(.id == $id) | .target // empty' "$sched_file" 2>/dev/null)
    _api_validate_schedule_target "$_naction" "$_ntarget" || return

    # Merge updates into existing entry (preserve id)
    local updated
    updated=$(jq --arg id "$sched_id" --argjson updates "$body" \
        '[.[] | if .id == $id then . * $updates | .id = $id else . end]' \
        "$sched_file" 2>/dev/null)
    if [[ -z "$updated" ]]; then
        _api_error 500 "Failed to update schedule"
        return
    fi

    printf '%s\n' "$updated" > "${sched_file}.tmp" && mv -f "${sched_file}.tmp" "$sched_file"

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

# A schedule's target is either a stack name (backup/update/restart) or, for
# custom, an executable inside this installation. Nothing else is ever run.
_api_validate_schedule_target() {
    local action="$1" target="$2"
    case "$action" in
        backup)
            [[ -z "$target" ]] && return 0
            _api_validate_stack_name "$target" || return 1
            ;;
        update|restart|start|stop)
            [[ -z "$target" ]] && return 0
            _api_validate_stack_name "$target" || return 1
            ;;
        maintenance) ;;
        custom)
            local real
            real=$(realpath -e -- "$target" 2>/dev/null)
            if [[ -z "$target" || "$target" != /* || -z "$real" || "$real" != "$BASE_DIR/"* || ! -f "$real" || ! -x "$real" ]]; then
                _api_error 400 "Custom schedule targets must be executable files inside $BASE_DIR"
                return 1
            fi
            ;;
        prune|health-check|metrics-snapshot) ;;
        *)
            _api_error 400 "Unknown schedule action: $action"
            return 1
            ;;
    esac
    return 0
}

# POST /schedules/<id>/run — Execute a schedule immediately
handle_schedule_run() {
    local sched_id="$1"
    local sched_file="$BASE_DIR/.data/schedules/schedules.json"

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required"
        return
    fi

    if [[ ! -f "$sched_file" ]]; then
        _api_error 404 "No schedules found"
        return
    fi

    local entry
    entry=$(jq -r --arg id "$sched_id" '.[] | select(.id == $id)' "$sched_file" 2>/dev/null)
    [[ -z "$entry" || "$entry" == "null" ]] && { _api_error 404 "Schedule not found"; return; }

    local action target name
    action=$(printf '%s' "$entry" | jq -r '.action // empty' 2>/dev/null)
    target=$(printf '%s' "$entry" | jq -r '.target // empty' 2>/dev/null)
    name=$(printf '%s' "$entry" | jq -r '.name // empty' 2>/dev/null)

    [[ -z "$action" ]] && { _api_error 400 "Schedule has no action defined"; return; }
    # The stored entry is re-validated at run time (it may predate validation)
    _api_validate_schedule_target "$action" "$target" || return

    _schedule_run_action "$action" "$target" "$name"
    _schedule_finish "$sched_id" "$name" "$action" "$target" "$_SR_SUCCESS" "$_SR_OUTPUT" "manual"

    _api_success "{\"success\": $_SR_SUCCESS, \"action\": \"$(_api_json_escape "$action")\", \"output\": \"$(_api_json_escape "$(printf '%s' "$_SR_OUTPUT" | head -c 200)")\"}"
}

# Execute one schedule/automation action. Sets _SR_SUCCESS and _SR_OUTPUT.
# Usage: _schedule_run_action ACTION TARGET NAME
_schedule_run_action() {
    local action="$1" target="$2" name="${3:-}"
    local output="" success="true"
    case "$action" in
        backup)
            # Run backup in background with progress stages (same as handle_backup_trigger)
            local _bdir="${BACKUP_DEST_DIR:-}"
            if [[ -z "$_bdir" ]]; then
                output="Backup not configured — set BACKUP_DEST_DIR in .env" && success="false"
            else
                local _bdate _bfile _bsrc _bstatus _bpid_file
                _bdate=$(date '+%Y-%m-%d_%H%M%S')
                _bfile="Docker-Compose-Backup-${_bdate}.tar.gz"
                _bsrc="${BACKUP_SOURCE_DIR:-$BASE_DIR}"
                _bstatus="$API_AUTH_DIR/backup-status.json"
                _bpid_file="$API_AUTH_DIR/backup.pid"
                local _bst
                _bst="$(date -Iseconds)"
                mkdir -p "$_bdir" 2>/dev/null

                printf '{"status":"running","started_at":"%s","filename":"%s","progress":"Scheduled backup starting...","percent":0,"stage":"prepare"}' \
                    "$_bst" "$_bfile" > "$_bstatus"

                (
                    umask 077
                    echo $BASHPID > "$_bpid_file"
                    local _btmp
                    if ! _btmp=$(mktemp -d /tmp/dcs-backup-XXXXXX 2>/dev/null) || [[ -z "$_btmp" ]]; then
                        printf '{"status":"error","error":"Could not create a temporary directory","progress":null,"percent":0,"stage":"error"}' > "$_bstatus"
                        rm -f "$_bpid_file"
                        exit 1
                    fi

                    printf '{"status":"running","started_at":"%s","filename":"%s","progress":"Copying files...","percent":15,"stage":"copy"}' \
                        "$_bst" "$_bfile" > "$_bstatus"

                    if [[ -n "$target" ]]; then
                        [[ -d "$COMPOSE_DIR/$target" ]] && rsync -a "$COMPOSE_DIR/$target/" "$_btmp/$target/" 2>/dev/null || true
                    else
                        rsync -a --exclude='.git' --exclude='node_modules' --exclude='.data' --exclude='logs' \
                            --exclude='.api-auth/tokens.json' --exclude='.api-auth/terminal-sessions.json' \
                            --exclude='.api-auth/rate_limits.json' --exclude='.api-auth/*.log' --exclude='.api-auth/rates' \
                            "$_bsrc/" "$_btmp/" 2>/dev/null || true
                    fi

                    printf '{"status":"running","started_at":"%s","filename":"%s","progress":"Creating archive...","percent":55,"stage":"archive"}' \
                        "$_bst" "$_bfile" > "$_bstatus"

                    if tar -czf "$_bdir/$_bfile" -C "$_btmp" . 2>/dev/null; then
                        printf '{"status":"running","started_at":"%s","filename":"%s","progress":"Cleaning up...","percent":85,"stage":"cleanup"}' \
                            "$_bst" "$_bfile" > "$_bstatus"
                        rm -rf "$_btmp"
                        local _ret="${BACKUP_RETENTION_COUNT:-5}"
                        local _cnt
                        _cnt=$(ls -1 "$_bdir"/Docker-Compose-Backup-*.tar.gz 2>/dev/null | wc -l)
                        [[ "$_cnt" -gt "$_ret" ]] && ls -1t "$_bdir"/Docker-Compose-Backup-*.tar.gz | tail -n "$((_cnt - _ret))" | xargs -r rm -f
                        local _bsz
                        _bsz=$(du -h "$_bdir/$_bfile" 2>/dev/null | cut -f1)
                        printf '{"status":"idle","last_backup":{"filename":"%s","size":"%s","timestamp":"%s"},"progress":null,"percent":100,"stage":"done"}' \
                            "$_bfile" "$_bsz" "$(date -Iseconds)" > "$_bstatus"
                    else
                        rm -rf "$_btmp"
                        printf '{"status":"error","error":"Archive creation failed","progress":null,"percent":0,"stage":"error"}' > "$_bstatus"
                    fi
                    rm -f "$_bpid_file"
                ) </dev/null >/dev/null 2>&1 &

                output="Backup started: $_bfile"
            fi
            ;;
        update)
            if [[ -n "$target" && -f "$COMPOSE_DIR/$target/docker-compose.yml" ]]; then
                local _sched_env=""
                [[ -f "$COMPOSE_DIR/$target/.env" ]] && _sched_env="$COMPOSE_DIR/$target/.env"
                output=$(_compose_with_secrets "$COMPOSE_DIR/$target/docker-compose.yml" "$_sched_env" pull 2>&1 && _compose_with_secrets "$COMPOSE_DIR/$target/docker-compose.yml" "$_sched_env" up -d 2>&1) || success="false"
            else
                output="No target stack specified" && success="false"
            fi
            ;;
        prune|maintenance)
            output=$(docker system prune -f 2>&1) || success="false"
            ;;
        start|stop)
            if [[ -n "$target" && -f "$COMPOSE_DIR/$target/docker-compose.yml" ]]; then
                local _sched_env=""
                [[ -f "$COMPOSE_DIR/$target/.env" ]] && _sched_env="$COMPOSE_DIR/$target/.env"
                if [[ "$action" == "start" ]]; then
                    output=$(_compose_with_secrets "$COMPOSE_DIR/$target/docker-compose.yml" "$_sched_env" up -d 2>&1) || success="false"
                else
                    output=$(_compose_with_secrets "$COMPOSE_DIR/$target/docker-compose.yml" "$_sched_env" down --timeout 10 2>&1) || success="false"
                fi
            else
                output="No target stack specified" && success="false"
            fi
            ;;
        health-check)
            # Inline health check — scan running containers for unhealthy status
            local _hc_total=0 _hc_healthy=0 _hc_unhealthy=0 _hc_none=0
            local _hc_bad=""
            while IFS='|' read -r _cn _cs _ch; do
                [[ -z "$_cn" ]] && continue
                _hc_total=$((_hc_total + 1))
                if [[ "$_ch" == *"healthy"* && "$_ch" != *"unhealthy"* ]]; then
                    _hc_healthy=$((_hc_healthy + 1))
                elif [[ "$_ch" == *"unhealthy"* ]]; then
                    _hc_unhealthy=$((_hc_unhealthy + 1))
                    _hc_bad="${_hc_bad}${_cn}, "
                else
                    _hc_none=$((_hc_none + 1))
                fi
            done < <(docker ps --format '{{.Names}}|{{.Status}}|{{.Status}}' 2>/dev/null)
            if [[ $_hc_unhealthy -gt 0 ]]; then
                output="Health check: ${_hc_unhealthy} unhealthy (${_hc_bad%, }), ${_hc_healthy} healthy, ${_hc_total} total"
            else
                output="Health check: All ${_hc_total} containers healthy (${_hc_healthy} with healthcheck, ${_hc_none} without)"
            fi
            ;;
        restart)
            if [[ -n "$target" && -f "$COMPOSE_DIR/$target/docker-compose.yml" ]]; then
                local _sched_env=""
                [[ -f "$COMPOSE_DIR/$target/.env" ]] && _sched_env="$COMPOSE_DIR/$target/.env"
                output=$(_compose_with_secrets "$COMPOSE_DIR/$target/docker-compose.yml" "$_sched_env" restart 2>&1) || success="false"
            else
                output="No target stack specified" && success="false"
            fi
            ;;
        metrics-snapshot)
            # Trigger metrics collection via the API endpoint
            local _mf="$BASE_DIR/.api-auth/metrics-history.jsonl"
            local _ts _ep _l1 _l5 _l15 _nc _cp _mt _ma _mu _mp _dp
            _ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ'); _ep=$(date +%s)
            read -r _l1 _l5 _l15 _ _ < /proc/loadavg 2>/dev/null || { _l1=0; _l5=0; _l15=0; }
            _nc=$(nproc 2>/dev/null || echo 1)
            _cp=$(awk "BEGIN {v=$_l1/$_nc*100; if(v>100)v=100; printf \"%.1f\", v}")
            _mt=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
            _ma=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
            _mu=$((_mt - _ma))
            [[ "$_mt" -gt 0 ]] && _mp=$(awk "BEGIN {printf \"%.1f\", $_mu/$_mt*100}") || _mp=0
            _dp=$(df -P "$BASE_DIR" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%'); [[ -z "$_dp" ]] && _dp=0
            echo "{\"ts\":\"$_ts\",\"epoch\":$_ep,\"cpu_pct\":$_cp,\"load1\":$_l1,\"load5\":$_l5,\"load15\":$_l15,\"mem_used_mb\":$_mu,\"mem_total_mb\":$_mt,\"mem_pct\":$_mp,\"disk_pct\":$_dp}" >> "$_mf"
            output="Metrics snapshot captured"
            ;;
        custom)
            # Validated above: an executable inside this installation
            output=$(timeout 600 "$target" 2>&1 | head -c 65536) || success="false"
            ;;
        *)
            output="Unknown action: $action" && success="false"
            ;;
    esac
    _SR_OUTPUT="$output"; _SR_SUCCESS="$success"
}

# Record a schedule run: counters on the entry, one JSON line of history.
# Usage: _schedule_finish ID NAME ACTION TARGET SUCCESS OUTPUT TRIGGER
_schedule_finish() {
    local sched_id="$1" name="$2" action="$3" target="$4" success="$5" output="$6" trigger="${7:-manual}"
    local sched_file="$BASE_DIR/.data/schedules/schedules.json"
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    [[ -f "$sched_file" ]] && _api_jq_update_file "$sched_file" --arg id "$sched_id" --arg ts "$ts" \
        '[.[] | if .id == $id then .run_count = ((.run_count // 0) + 1) | .last_run = $ts else . end]' >/dev/null 2>&1

    # Log to history (valid JSON per line, capped at 1000 entries)
    local history_file="$BASE_DIR/.data/schedules/history.jsonl"
    mkdir -p "$(dirname "$history_file")" 2>/dev/null
    jq -nc --arg ts "$ts" --arg id "$sched_id" --arg name "$name" --arg action "$action" --arg target "$target" \
        --argjson success "$success" --arg output "$(printf '%s' "$output" | head -c 500)" --arg trigger "$trigger" \
        '{timestamp: $ts, schedule_id: $id, name: $name, action: $action, target: $target, success: $success, output: $output, trigger: $trigger}' \
        >> "$history_file" 2>/dev/null
    if [[ $(wc -l < "$history_file" 2>/dev/null || echo 0) -gt 1000 ]]; then
        tail -n 1000 "$history_file" > "${history_file}.tmp" 2>/dev/null && mv -f "${history_file}.tmp" "$history_file"
    fi
}

# GET /schedules/<id>/history — Return execution history filtered by schedule id
handle_schedule_history() {
    local sched_id="$1"
    local history_file="$BASE_DIR/.data/schedules/history.jsonl"

    if [[ ! -f "$history_file" ]]; then
        _api_success "{\"schedule_id\": \"$(_api_json_escape "$sched_id")\", \"history\": [], \"count\": 0}"
        return
    fi

    # One jq pass; malformed lines are skipped rather than breaking the response
    local json
    json=$(jq -c --arg id "$sched_id" 'select(type == "object" and ((.schedule_id // .id) == $id))' "$history_file" 2>/dev/null | jq -sc '.' 2>/dev/null)
    [[ -z "$json" ]] && json="[]"
    local count
    count=$(jq 'length' <<< "$json" 2>/dev/null || echo 0)

    _api_success "{\"schedule_id\": \"$(_api_json_escape "$sched_id")\", \"history\": $json, \"count\": ${count:-0}}"
}

# =============================================================================
# FEATURE: HEALTH SCORING
# =============================================================================

HEALTH_SCORE_HISTORY_FILE="$BASE_DIR/.data/health-score-history.jsonl"

# GET /health/score — Compute system-wide health score (0-100)
# Factors: stacks (container health), resources (CPU/mem), images (freshness), uptime
# GET /health/score — System health score (0-100) with its factors
handle_health_score() {
    local now
    now=$(date +%s)

    # ── Factor 1: Stack/container health (40% weight) — one docker call ──
    local total_containers=0 healthy_count=0 unhealthy_count=0
    while IFS=$'\t' read -r state status; do
        [[ -z "$state" ]] && continue
        total_containers=$((total_containers + 1))
        if [[ "$state" == "running" ]]; then
            if [[ "$status" == *"(unhealthy)"* ]]; then
                unhealthy_count=$((unhealthy_count + 1))
            else
                healthy_count=$((healthy_count + 1))
            fi
        fi
    done < <(timeout 10 docker ps -a --format '{{.State}}\t{{.Status}}' 2>/dev/null)

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

    while IFS=$'\t' read -r repo tag created_ts; do
        [[ -z "$repo" || "$repo" == "<none>" ]] && continue
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

        # No cache — fall back to age-based check (creation time comes with the listing)
        if [[ -n "$created_ts" ]]; then
            local created_epoch
            created_epoch=$(date -d "$created_ts" +%s 2>/dev/null || echo 0)
            (( created_epoch > 0 )) && (( (now - created_epoch) / 86400 > 30 )) && stale_images=$((stale_images + 1))
        fi
    done < <(docker images --format "{{.Repository}}\t{{.Tag}}\t{{.CreatedAt}}" 2>/dev/null)

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

    # Keep a bounded history so /health/score/history has data (max 2016 points, i.e. a week at 5-minute polls)
    mkdir -p "$BASE_DIR/.data" 2>/dev/null
    printf '{"ts":%d,"score":%d,"grade":"%s"}\n' "$now" "$total_score" "$grade" >> "$HEALTH_SCORE_HISTORY_FILE" 2>/dev/null
    if [[ $(wc -l < "$HEALTH_SCORE_HISTORY_FILE" 2>/dev/null || echo 0) -gt 2016 ]]; then
        tail -n 2016 "$HEALTH_SCORE_HISTORY_FILE" > "${HEALTH_SCORE_HISTORY_FILE}.tmp" 2>/dev/null && mv -f "${HEALTH_SCORE_HISTORY_FILE}.tmp" "$HEALTH_SCORE_HISTORY_FILE"
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

    # One inspect call for the whole stack
    if [[ $total -gt 0 ]]; then
        while IFS=$'\t' read -r state health; do
            [[ -z "$state" ]] && continue
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
        done < <(timeout 10 docker inspect --format $'{{.State.Status}}\t{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${container_ids[@]}" 2>/dev/null)
    fi

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
    local username="${AUTH_USERNAME:-default}"
    mkdir -p "$DASHBOARD_LAYOUTS_DIR"
    local layout_file="$DASHBOARD_LAYOUTS_DIR/${username}.json"

    local content=""
    [[ -f "$layout_file" ]] && content=$(jq -c '.' "$layout_file" 2>/dev/null)
    if [[ -n "$content" ]]; then
        _api_success "{\"layout\": $content}"
    else
        _api_success "{\"layout\": null}"
    fi
}

# POST /settings/dashboard — Save user's dashboard layout
handle_dashboard_layout_save() {
    local body="$1"
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

    printf '%s\n' "$layout" > "${layout_file}.tmp" && mv -f "${layout_file}.tmp" "$layout_file"
    _api_success "{\"success\": true, \"cards\": $card_count}"
}

# GET /settings/profile — Fetch user's profile settings
handle_profile_get() {
    local username="${AUTH_USERNAME:-default}"
    mkdir -p "$PROFILES_DIR"
    local profile_file="$PROFILES_DIR/${username}.json"

    local content=""
    [[ -f "$profile_file" ]] && content=$(jq -c '.' "$profile_file" 2>/dev/null)
    if [[ -n "$content" ]]; then
        _api_success "{\"profile\": $content}"
    else
        _api_success "{\"profile\": null}"
    fi
}

# POST /settings/profile — Save user's profile settings
handle_profile_save() {
    local body="$1"
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

    printf '%s\n' "$profile" > "${profile_file}.tmp" && mv -f "${profile_file}.tmp" "$profile_file"
    _api_success "{\"success\": true}"
}

# GET /health/score/history?range=1h|24h|7d
# Read health score history from metrics data
# GET /health/score/history — Recorded health scores over a range
handle_health_score_history() {
    local range="${QUERY_PARAMS[range]:-24h}"
    case "$range" in 1h|6h|24h|7d) ;; *) range="24h" ;; esac
    local cutoff
    cutoff=$(_api_range_to_cutoff "$range")

    local result=""
    if [[ -f "$HEALTH_SCORE_HISTORY_FILE" ]]; then
        result=$(jq -sc --argjson c "$cutoff" --arg range "$range" \
            '[.[] | select(type == "object" and (.ts // 0) >= $c)] | {range: $range, history: ., count: length}' \
            "$HEALTH_SCORE_HISTORY_FILE" 2>/dev/null)
    fi
    if [[ -n "$result" ]]; then
        _api_success "$result"
    else
        _api_success "{\"range\": \"$range\", \"history\": [], \"count\": 0}"
    fi
}

# =============================================================================
# FEATURE: PLUGIN MANAGEMENT
# =============================================================================

# Run lifecycle hooks across all enabled plugins.
# Events: pre-start, post-start, pre-stop, post-stop, pre-update, post-update, pre-deploy, post-deploy
# Context JSON is passed on stdin to each hook script.
# Runs in background to avoid blocking API responses.
# Is the plugin in DIR enabled? The manifest's "enabled" flag is the single
# source of truth (install writes false, toggle flips it). A plugin without a
# manifest counts as enabled for backwards compatibility.
_plugin_enabled() {
    local manifest="$1/plugin.json"
    [[ -f "$manifest" ]] || return 0
    [[ "$(jq -r 'if .enabled == null then true else .enabled end' "$manifest" 2>/dev/null)" == "true" ]]
}

# A file inside a plugin directory that is safe to read or write: a regular
# file (never a symlink) whose real path stays inside that plugin.
_plugin_path_ok() {
    local plugin_dir="$1" file="$2" real
    [[ -L "$file" ]] && return 1
    [[ -e "$file" ]] || return 0
    real=$(realpath -e -- "$file" 2>/dev/null) || return 1
    [[ "$real" == "$(realpath -e -- "$plugin_dir" 2>/dev/null)/"* ]]
}

# Plugin hook contract (v2). A hook is an executable hooks/<event> (or .sh)
# inside an enabled plugin. It receives a JSON context on stdin and a small,
# explicit environment: PATH HOME BASE_DIR COMPOSE_DIR DCS_EVENT PLUGIN_NAME
# PLUGIN_DIR PLUGIN_STATE_DIR (created, private) DCS_PLUGIN_CONFIG (the
# manifest's "config" as JSON) DCS_DRY_RUN DCS_NTFY_URL NTFY_TOKEN
# DOCKER_COMPOSE_CMD TZ, plus the root .env values whose names the manifest
# lists under "env" (never the whole server environment). 30 s timeout,
# 64 KB output. Usage: _plugin_exec_hook HOOK CONTEXT EVENT [TIMEOUT] [PLUGIN_DIR]
_plugin_exec_hook() {
    local hook_script="$1" context="$2" event="${3:-}" tmo="${4:-30}" plugin_dir="${5:-}"
    [[ -z "$plugin_dir" ]] && plugin_dir=$(dirname "$(dirname "$hook_script")")
    plugin_dir="${plugin_dir%/}"
    local pname state cfg='{}' envlist="" dry
    pname=$(basename "$plugin_dir")
    state="$plugin_dir/state"
    (umask 077; mkdir -p "$state") 2>/dev/null
    if [[ -f "$plugin_dir/plugin.json" ]]; then
        cfg=$(jq -c '.config // {}' "$plugin_dir/plugin.json" 2>/dev/null) || cfg='{}'
        envlist=$(jq -r '.env[]? // empty' "$plugin_dir/plugin.json" 2>/dev/null | grep -E '^[A-Z][A-Z0-9_]*$' | grep -vE '^(PATH|HOME|IFS|ENV|SHELLOPTS|BASHOPTS)$|^(LD|BASH)_' | sort -u)
    fi
    dry=$(printf '%s' "$context" | jq -r 'if .dry_run == true then "true" else "false" end' 2>/dev/null) || dry=false
    local -a envargs=(PATH="$PATH" HOME="$HOME" BASE_DIR="$BASE_DIR" COMPOSE_DIR="$COMPOSE_DIR" DCS_EVENT="$event"
                      PLUGIN_NAME="$pname" PLUGIN_DIR="$plugin_dir" PLUGIN_STATE_DIR="$state" DCS_PLUGIN_CONFIG="$cfg"
                      DCS_DRY_RUN="$dry" DOCKER_COMPOSE_CMD="${DOCKER_COMPOSE_CMD:-docker compose}" TZ="${TZ:-UTC}")
    local ntfy
    if ntfy=$(_ntfy_endpoint 2>/dev/null) && [[ -n "$ntfy" ]]; then
        envargs+=(DCS_NTFY_URL="$ntfy")
        [[ -n "${NTFY_TOKEN:-}" ]] && envargs+=(NTFY_TOKEN="$NTFY_TOKEN")
    fi
    local v
    for v in $envlist; do
        [[ -n "${!v:-}" ]] && envargs+=("$v=${!v}")
    done
    printf '%s' "$context" | env -i "${envargs[@]}" timeout "$tmo" "$hook_script" 2>&1 | head -c 65536
    return "${PIPESTATUS[1]}"
}

# One JSON line per run in <plugin>/execution.log, bounded.
_plugin_log_run() {
    local plugin_dir="$1" event="$2" output="$3" rc="${4:-0}" dry="${5:-false}"
    local log_file="${plugin_dir%/}/execution.log"
    jq -nc --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg ev "$event" --arg p "$(basename "${plugin_dir%/}")" \
        --arg out "$(printf '%s' "$output" | head -c 2000)" --argjson rc "$rc" --argjson dry "$dry" \
        '{ts: $ts, event: $ev, plugin: $p, exit_code: $rc, dry_run: $dry, output: $out}' >> "$log_file" 2>/dev/null
    if [[ $(wc -l < "$log_file" 2>/dev/null || echo 0) -gt 2000 ]]; then
        tail -n 1000 "$log_file" > "${log_file}.tmp" 2>/dev/null && mv -f "${log_file}.tmp" "$log_file"
    fi
}

# Hook context for a stack: {stack, project, compose_file} plus the JSON in $2
# and, when $3 is given, {success: $3, containers: [...]} for post-* events.
_hook_ctx() {
    local stack="$1" _xjson="${2:-{\}}" ok="${3:-}"
    local containers="[]"
    if [[ -n "$ok" ]]; then
        containers=$(docker ps -a --filter "label=com.docker.compose.project=$stack" --format '{{.Names}}' 2>/dev/null | jq -R . | jq -s -c . 2>/dev/null) || containers="[]"
        [[ -z "$containers" ]] && containers="[]"
    fi
    jq -nc --arg s "$stack" --arg cf "$COMPOSE_DIR/$stack/docker-compose.yml" --argjson extra "$_xjson" \
        --arg ok "$ok" --argjson c "$containers" \
        '{stack: $s, project: $s, compose_file: $cf} + $extra + (if $ok == "" then {} else {success: ($ok == "true"), containers: $c} end)' 2>/dev/null \
        || printf '{"stack":"%s","project":"%s"}' "$stack" "$stack"
}

# Run every enabled plugin's hook for EVENT, in the foreground, in order.
_plugin_hooks_now() {
    local event="$1"
    local context="${2:-{\}}"
    [[ "${PLUGINS_HOOKS_ENABLED:-true}" != "true" ]] && return 0
    [[ ! -d "$PLUGINS_DIR" ]] && return 0
    local plugin_dir hook_script output rc dry
    dry=$(printf '%s' "$context" | jq -r 'if .dry_run == true then "true" else "false" end' 2>/dev/null) || dry=false
    for plugin_dir in "$PLUGINS_DIR"/*/; do
        [[ ! -d "$plugin_dir" ]] && continue
        _plugin_enabled "$plugin_dir" || continue
        hook_script="$plugin_dir/hooks/$event"
        [[ -f "$hook_script" && -x "$hook_script" ]] || {
            hook_script="$plugin_dir/hooks/${event}.sh"
            [[ -f "$hook_script" && -x "$hook_script" ]] || continue
        }
        _plugin_path_ok "$plugin_dir" "$hook_script" || continue
        rc=0
        output=$(_plugin_exec_hook "$hook_script" "$context" "$event" 30 "$plugin_dir") || rc=$?
        _plugin_log_run "$plugin_dir" "$event" "$output" "$rc" "$dry"
    done
    return 0
}

# Same, detached from the request (the default for handlers that answer
# before the work is done). Pass "sync" as $3 to wait instead.
_run_plugin_hooks() {
    local event="$1"
    local context="${2:-{\}}"
    if [[ "${3:-}" == "sync" ]]; then
        _plugin_hooks_now "$event" "$context"
    else
        ( _plugin_hooks_now "$event" "$context" ) </dev/null >/dev/null 2>&1 &
    fi
}

# Stack lifecycle with hooks in the right order and a success flag: runs in
# a detached subshell so the request can answer at once.
# Usage: _stack_run_detached start|stop|restart STACK
# =============================================================================
# STACK ACTIVITY — one record per stack for the action running (or last run)
# in the background: start/stop/restart from the Stacks page and template
# deployments. The compose output is kept in a per-stack log, so the UI can
# show real progress (pulling, creating, starting) instead of guessing.
# =============================================================================
STACK_ACTIVITY_DIR="$BASE_DIR/.data/stack-actions"

# Global compose flags that make the output plain and parseable (empty on
# Compose releases that predate --progress)
_compose_progress_args() {
    if [[ -z "${_COMPOSE_PROGRESS_CACHE+x}" ]]; then
        if ${DOCKER_COMPOSE_CMD:-docker compose} --progress plain --ansi never version >/dev/null 2>&1; then
            _COMPOSE_PROGRESS_CACHE="--progress plain --ansi never"
        else
            _COMPOSE_PROGRESS_CACHE=""
        fi
    fi
    printf '%s' "$_COMPOSE_PROGRESS_CACHE"
}

# _stack_activity_begin STACK ACTION [EXTRA_JSON] → prints the activity id
_stack_activity_begin() {
    local stack="$1" action="$2" _extra_json="${3:-}"
    [[ -n "$_extra_json" ]] || _extra_json='{}'
    mkdir -p "$STACK_ACTIVITY_DIR" 2>/dev/null
    local id
    id="${stack}-$(date +%s)"
    : > "$STACK_ACTIVITY_DIR/$stack.log"
    jq -nc --arg id "$id" --arg s "$stack" --arg a "$action" --arg t "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --argjson x "$_extra_json" \
        '{id: $id, stack: $s, action: $a, started_at: $t, finished_at: null, success: null, pid: null} + $x' \
        > "$STACK_ACTIVITY_DIR/$stack.json" 2>/dev/null
    printf '%s' "$id"
}

# Called first thing inside the background runner so a dead runner is detectable
_stack_activity_pid() {
    local f="$STACK_ACTIVITY_DIR/$1.json"
    [[ -f "$f" ]] && _api_jq_update_file "$f" --argjson p "$BASHPID" '.pid = $p'
    return 0
}

# _stack_activity_end STACK SUCCESS(true|false) [MESSAGE]
_stack_activity_end() {
    local stack="$1" ok="$2" msg="${3:-}"
    local f="$STACK_ACTIVITY_DIR/$stack.json"
    [[ -f "$f" ]] || return 0
    _api_jq_update_file "$f" --arg t "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --argjson ok "$ok" --arg m "$msg" \
        '.finished_at = $t | .success = $ok | (if $m != "" then .message = $m else . end)'
    return 0
}

# Container name a compose service gets: its container_name, else <project>-<service>-1
_compose_container_name() {
    local dir="$1" svc="$2" cn=""
    cn=$(awk -v s="$svc" '
        /^  [A-Za-z0-9_.-]+:/ { cur=$1; sub(":","",cur); next }
        cur==s && /^    container_name:/ { v=$0; sub(/^    container_name:[[:space:]]*/, "", v); gsub(/["\x27]/, "", v); print v; exit }' "$dir/docker-compose.yml" 2>/dev/null) || cn=""
    if [[ -z "$cn" || "$cn" == *'${'* ]]; then
        local project=""
        [[ -f "$dir/.env" ]] && { project=$(grep -m1 '^COMPOSE_PROJECT_NAME=' "$dir/.env" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || project=""; }
        [[ -z "$project" ]] && { project=$(basename "$dir" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_\n-' '_') || project="stack"; }
        cn="${project}-${svc}-1"
    fi
    printf '%s' "$cn"
    return 0
}

# Image reference of a service as written in the compose file
_compose_service_image() {
    awk -v s="$2" '
        /^  [A-Za-z0-9_.-]+:/ { cur=$1; sub(":","",cur); next }
        cur==s && /^    image:/ { v=$0; sub(/^    image:[[:space:]]*/, "", v); gsub(/["\x27]/, "", v); print v; exit }' "$1/docker-compose.yml" 2>/dev/null || true
    return 0
}

# Bind-mount host paths under App-Data of the given services
# Usage: _compose_bind_mounts STACK_DIR APP_DATA_DIR SERVICE...
_compose_bind_mounts() {
    local dir="$1" ad="$2"; shift 2
    [[ $# -gt 0 ]] || return 0
    local svc_re
    svc_re=$(printf '%s|' "$@"); svc_re="^(${svc_re%|})$"
    awk -v re="$svc_re" -v ad="$ad" '
        /^  [A-Za-z0-9_.-]+:/ { svc=$1; sub(":","",svc); insvc = (svc ~ re); invol=0; next }
        insvc && /^    volumes:/ { invol=1; next }
        insvc && invol && /^    [A-Za-z_]/ { invol=0 }
        insvc && invol && /^      - / {
            v=$0; sub(/^      - /, "", v); gsub(/["\x27]/, "", v)
            n=index(v, ":"); if (n==0) next
            h=substr(v, 1, n-1)
            if (h ~ /^\$\{APP_DATA_DIR[^}]*\}\//) { sub(/^\$\{APP_DATA_DIR[^}]*\}/, ad, h) }
            else if (h ~ /^\.\/App-Data\//) { sub(/^\.\/App-Data/, ad, h) }
            else next
            print h
        }' "$dir/docker-compose.yml" 2>/dev/null | sort -u || true
    return 0
}

_stack_run_detached() {
    local action="$1" stack="$2"
    local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml" env_file="$COMPOSE_DIR/$stack/.env"
    local -a args=(-f "$compose_file")
    [[ -f "$env_file" ]] && args+=(--env-file "$env_file")
    mkdir -p "$BASE_DIR/logs" 2>/dev/null
    local logf="$STACK_ACTIVITY_DIR/$stack.log"
    _stack_activity_begin "$stack" "$action" >/dev/null
    local -a prog=()
    read -ra prog <<< "$(_compose_progress_args)"
    (
        set +e
        _stack_activity_pid "$stack"
        local ok
        local base_ctx
        base_ctx=$(_hook_ctx "$stack" "{\"action\":\"$action\"}")
        printf '%s | %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$action" "$stack"
        case "$action" in
            start)
                _plugin_hooks_now "pre-start" "$base_ctx"
                _compose_with_secrets "$compose_file" "$env_file" "${prog[@]}" up -d --remove-orphans >>"$logf" 2>&1 && ok=true || ok=false
                _plugin_hooks_now "post-start" "$(_hook_ctx "$stack" "{\"action\":\"start\"}" "$ok")"
                [[ "$ok" == "false" ]] && _fire_notifications "stack_failed" "stack=$stack" "action=start"
                ;;
            stop)
                _plugin_hooks_now "pre-stop" "$base_ctx"
                $DOCKER_COMPOSE_CMD "${args[@]}" "${prog[@]}" down --remove-orphans --timeout 15 >>"$logf" 2>&1 && ok=true || ok=false
                _plugin_hooks_now "post-stop" "$(_hook_ctx "$stack" "{\"action\":\"stop\"}" "$ok")"
                _fire_notifications "stack_down" "stack=$stack" "status=stopped"
                ;;
            restart)
                _plugin_hooks_now "pre-stop" "$base_ctx"
                $DOCKER_COMPOSE_CMD "${args[@]}" "${prog[@]}" down --remove-orphans --timeout 15 >>"$logf" 2>&1 && ok=true || ok=false
                _plugin_hooks_now "post-stop" "$(_hook_ctx "$stack" "{\"action\":\"restart\"}" "$ok")"
                _plugin_hooks_now "pre-start" "$base_ctx"
                _compose_with_secrets "$compose_file" "$env_file" "${prog[@]}" up -d --remove-orphans >>"$logf" 2>&1 && ok=true || ok=false
                _plugin_hooks_now "post-start" "$(_hook_ctx "$stack" "{\"action\":\"restart\"}" "$ok")"
                [[ "$ok" == "false" ]] && _fire_notifications "stack_failed" "stack=$stack" "action=restart"
                ;;
        esac
        _stack_activity_end "$stack" "${ok:-false}"
        printf '%s | %s %s done (success=%s)\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$action" "$stack" "${ok:-?}"
    ) </dev/null >>"$BASE_DIR/logs/stack-actions.log" 2>&1 &
}

# =============================================================================
# PLUGIN CATALOGUE — plugins shipped with DCS in .plugins-catalog/, installed
# by copying into .plugins/ (disabled until the admin enables them).
# =============================================================================
PLUGIN_CATALOG_DIR="$BASE_DIR/.plugins-catalog"

# GET /plugins/catalog — Plugins available to install, with their manifest and installed state
handle_plugins_catalog() {
    local -a entries=()
    local d name
    for d in "$PLUGIN_CATALOG_DIR"/*/; do
        [[ -f "$d/plugin.json" ]] || continue
        name=$(basename "$d")
        local installed=false
        [[ -d "$PLUGINS_DIR/$name" ]] && installed=true
        local hooks
        hooks=$(find "$d/hooks" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | jq -R . | jq -s -c .)
        [[ -z "$hooks" ]] && hooks="[]"
        local entry
        entry=$(jq -c --arg n "$name" --argjson inst "$installed" --argjson hooks "$hooks" \
            '. + {name: (.name // $n), installed: $inst, hooks: $hooks, env: (.env // []), config: (.config // {}), category: (.category // "operations"), tags: (.tags // [])}' \
            "$d/plugin.json" 2>/dev/null) || continue
        entries+=("$entry")
    done
    local json="[]"
    [[ ${#entries[@]} -gt 0 ]] && json="[$(IFS=,; echo "${entries[*]}")]"
    _api_success "{\"plugins\": $json, \"count\": ${#entries[@]}}"
}

# POST /plugins/catalog/{name}/install — Install a catalogue plugin (copied into .plugins, disabled)
handle_plugin_catalog_install() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]; then
        _api_error 400 "Invalid plugin name"
        return
    fi
    local src="$PLUGIN_CATALOG_DIR/$name" dst="$PLUGINS_DIR/$name"
    if [[ ! -f "$src/plugin.json" ]]; then
        _api_error 404 "Not in the catalogue: $name"
        return
    fi
    if [[ -e "$dst" ]]; then
        _api_error 409 "Plugin already installed: $name"
        return
    fi
    mkdir -p "$PLUGINS_DIR" 2>/dev/null
    if ! cp -r "$src" "$dst" 2>/dev/null; then
        _api_error 500 "Could not copy the plugin"
        return
    fi
    chmod +x "$dst"/hooks/* 2>/dev/null || true
    (umask 077; mkdir -p "$dst/state") 2>/dev/null
    local tmp="$dst/plugin.json.tmp"
    jq '. + {enabled: false, installed_from: "catalog", installed_at: (now | todate)}' "$dst/plugin.json" > "$tmp" 2>/dev/null && mv -f "$tmp" "$dst/plugin.json"
    _api_audit_log "${CLIENT_IP:-unknown}" "PLUGIN_INSTALL" "${AUTH_USERNAME:-}" "$name (catalog)"
    _api_success "{\"success\": true, \"plugin\": $(cat "$dst/plugin.json"), \"message\": \"Installed $name. Enable it to activate its hooks.\"}"
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
                templates_json+="\"$(_api_json_escape "$(basename "$tmpl_dir")")\""
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
                hooks_json+="\"$(_api_json_escape "$(basename "$hook_file")")\""
            done
        fi
        hooks_json+="]"

        # Check enabled state (manifest flag)
        local enabled="true"
        _plugin_enabled "$dir" || enabled="false"

        if [[ -f "$manifest" ]] && jq -e 'type == "object"' "$manifest" >/dev/null 2>&1; then
            local content
            content=$(jq -c \
                --arg name "$name" \
                --argjson templates "$templates_json" \
                --argjson hooks "$hooks_json" \
                --argjson enabled "$enabled" \
                '. + {dir_name: $name, templates: $templates, hooks: $hooks, enabled: $enabled}' "$manifest" 2>/dev/null)
            [[ -z "$content" ]] && content="{\"dir_name\": \"$(_api_json_escape "$name")\", \"name\": \"$(_api_json_escape "$name")\", \"error\": \"invalid manifest\", \"enabled\": $enabled, \"templates\": $templates_json, \"hooks\": $hooks_json}"
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
# POST /plugins/install — Install a plugin from a git URL (installed disabled)
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

    # Clone without following redirects (the SSRF check vetted this host only),
    # without prompts, without symlinks and with a hard time limit
    local clone_output
    clone_output=$(GIT_TERMINAL_PROMPT=0 timeout 120 git -c http.followRedirects=false -c core.symlinks=false \
        clone --depth 1 -- "$url" "$target_dir" 2>&1)
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        rm -rf "$target_dir" 2>/dev/null
        _api_error 500 "Failed to clone plugin: $clone_output"
        return
    fi
    if find "$target_dir" -type l -print -quit 2>/dev/null | grep -q .; then
        rm -rf "$target_dir" 2>/dev/null
        _api_error 400 "Plugin repository contains symbolic links — refusing to install"
        return
    fi
    rm -rf "$target_dir/.git" 2>/dev/null

    # Read manifest if available and ensure disabled by default
    local manifest="{}"
    if [[ -f "$target_dir/plugin.json" ]]; then
        if jq -e 'type == "object"' "$target_dir/plugin.json" >/dev/null 2>&1; then
            jq '.enabled = false' "$target_dir/plugin.json" > "$target_dir/plugin.json.tmp" && mv "$target_dir/plugin.json.tmp" "$target_dir/plugin.json"
            manifest=$(jq -c '.' "$target_dir/plugin.json" 2>/dev/null || echo "{}")
        else
            rm -rf "$target_dir" 2>/dev/null
            _api_error 400 "Plugin manifest (plugin.json) is not valid JSON"
            return
        fi
    fi

    _api_success "{\"success\": true, \"name\": \"$(_api_json_escape "$plugin_name")\", \"path\": \"$(_api_json_escape "$target_dir")\", \"manifest\": $manifest}"
}

# POST /plugins/scaffold — Create a plugin from inline definition (for bundled/featured plugins)
# Body: {"name": "...", "manifest": {...}, "hooks": {"pre-deploy": "#!/bin/bash\n..."}}
# POST /plugins/scaffold — Create a plugin from an inline manifest, hooks and cards
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
        manifest=$(echo "$body" | jq -c '.manifest | select(type == "object")' 2>/dev/null)
        if [[ -n "$manifest" ]]; then
            printf '%s' "$manifest" | jq --arg n "$name" '. + {name: (.name // $n), enabled: false}' > "$target_dir/plugin.json"
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
        final_manifest=$(jq -c '.' "$target_dir/plugin.json" 2>/dev/null || echo "{}")
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
    current_state=$(jq -r 'if .enabled == false then "false" else "true" end' "$manifest" 2>/dev/null)

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
    if [[ ! "$hook_name" =~ ^[a-zA-Z0-9_-]+(\.sh)?$ ]]; then
        _api_error 400 "Invalid hook name"
        return
    fi

    local plugin_dir="$BASE_DIR/.plugins/$plugin_name"
    local hook_file="$plugin_dir/hooks/$hook_name"

    if [[ ! -f "$hook_file" ]] || ! _plugin_path_ok "$plugin_dir" "$hook_file"; then
        _api_error 404 "Hook not found: $hook_name"
        return
    fi

    local content
    content=$(head -c 1048576 "$hook_file" 2>/dev/null)
    local executable="false"
    [[ -x "$hook_file" ]] && executable="true"
    local size
    size=$(stat -c%s "$hook_file" 2>/dev/null || echo "0")

    _api_success "{\"plugin\": \"$(_api_json_escape "$plugin_name")\", \"hook\": \"$(_api_json_escape "$hook_name")\", \"content\": \"$(_api_json_escape "$content")\", \"executable\": $executable, \"size\": ${size:-0}}"
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
    if [[ ! "$hook_name" =~ ^[a-zA-Z0-9_-]+(\.sh)?$ ]]; then
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
    if [[ -L "$hooks_dir" ]] || ! _plugin_path_ok "$plugin_dir" "$hook_file"; then
        _api_error 400 "Hook path is not writable (symbolic link)"
        return
    fi

    local content
    content=$(echo "$request_body" | jq -r '.content // empty' 2>/dev/null)

    if [[ -z "$content" ]]; then
        _api_error 400 "Content is required"
        return
    fi

    mkdir -p "$hooks_dir"
    printf '%s' "$content" > "${hook_file}.tmp" && chmod +x "${hook_file}.tmp" && mv -f "${hook_file}.tmp" "$hook_file"
    _api_audit_log "${CLIENT_IP:-unknown}" "PLUGIN_HOOK_WRITE" "${AUTH_USERNAME:-unknown}" "$plugin_name/$hook_name"

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
    if [[ ! "$hook_name" =~ ^[a-zA-Z0-9_-]+(\.sh)?$ ]]; then
        _api_error 400 "Invalid hook name"
        return
    fi

    local plugin_dir="$BASE_DIR/.plugins/$plugin_name"
    local hook_file="$plugin_dir/hooks/$hook_name"

    if [[ ! -f "$hook_file" ]] || ! _plugin_path_ok "$plugin_dir" "$hook_file"; then
        _api_error 404 "Hook not found: $hook_name"
        return
    fi

    if [[ ! -x "$hook_file" ]]; then
        _api_error 400 "Hook is not executable"
        return
    fi

    # Build test context
    local test_context
    test_context=$(echo "$request_body" | jq -c '.context | select(type == "object")' 2>/dev/null)
    [[ -z "$test_context" ]] && test_context="{\"stack\":\"test\",\"event\":\"$hook_name\",\"dry_run\":true,\"timestamp\":\"$(date -Iseconds)\"}"

    # Execute exactly as the hook runner does (same isolation, same timeout)
    local output exit_code=0
    output=$(_plugin_exec_hook "$hook_file" "$test_context" "$hook_name" 30 "$(dirname "$(dirname "$hook_file")")") || exit_code=$?

    _api_success "{\"plugin\": \"$(_api_json_escape "$plugin_name")\", \"hook\": \"$(_api_json_escape "$hook_name")\", \"exit_code\": $exit_code, \"output\": \"$(_api_json_escape "$output")\"}"
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

    # Read last 50 log entries (JSONL format); malformed lines are skipped
    local entries
    entries=$(tail -50 "$log_file" 2>/dev/null | jq -c 'select(type == "object")' 2>/dev/null | jq -sc '.' 2>/dev/null)
    [[ -z "$entries" ]] && entries="[]"
    local count
    count=$(jq 'length' <<< "$entries" 2>/dev/null || echo 0)

    _api_success "{\"plugin\": \"$(_api_json_escape "$plugin_name")\", \"entries\": $entries, \"total\": ${count:-0}}"
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
    config=$(echo "$request_body" | jq -c '.config | select(type == "object")' 2>/dev/null)

    if [[ -z "$config" ]]; then
        _api_error 400 "Config object is required"
        return
    fi

    # Merge config into manifest
    local updated
    if [[ -f "$manifest" ]] && jq -e 'type == "object"' "$manifest" >/dev/null 2>&1; then
        updated=$(jq --argjson cfg "$config" '.config = $cfg' "$manifest" 2>/dev/null)
    else
        updated=$(jq -n --arg n "$plugin_name" --argjson cfg "$config" '{name: $n, enabled: true, config: $cfg}' 2>/dev/null)
    fi
    if [[ -z "$updated" ]]; then
        _api_error 500 "Failed to update manifest"
        return
    fi
    printf '%s\n' "$updated" > "${manifest}.tmp" && mv -f "${manifest}.tmp" "$manifest"

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
                # Manifests come in two dialects: defaultW/defaultH or size (small,
                # medium, large), refreshInterval or refresh_interval. The dashboard
                # gets one shape, always with numbers it can place on the grid.
                card_meta=$(jq -c --arg plugin "$plugin_name" --arg cid "plugin:${plugin_name}:${_card_dirname}" --arg cname "$_card_dirname" '
                    (if .size == "small" then {w: 6, h: 4} elif .size == "large" then {w: 12, h: 8} else {w: 8, h: 5} end) as $sz
                    | . + {plugin: $plugin, id: $cid}
                    | .title = (.title // .name // $cname)
                    | .icon = (.icon // "Box")
                    | .description = (.description // "")
                    | .defaultW = ((.defaultW // $sz.w) | tonumber? // $sz.w)
                    | .defaultH = ((.defaultH // $sz.h) | tonumber? // $sz.h)
                    | .refreshInterval = ((.refreshInterval // .refresh_interval // 0) | tonumber? // 0)
                    | .minW = ((.minW // 3) | tonumber? // 3) | .minH = ((.minH // 2) | tonumber? // 2)
                    | .maxW = ((.maxW // 24) | tonumber? // 24) | .maxH = ((.maxH // 16) | tonumber? // 16)
                ' "$card_json" 2>/dev/null)
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

    local plugin_dir="$BASE_DIR/.plugins/$plugin_name"
    local html_file="$plugin_dir/cards/$card_name/index.html"

    if [[ ! -f "$html_file" ]] || ! _plugin_path_ok "$plugin_dir" "$html_file" || ! _plugin_enabled "$plugin_dir"; then
        _api_error 404 "Card not found: $plugin_name/$card_name"
        return
    fi

    local content
    content=$(head -c 1048576 "$html_file" 2>/dev/null)

    # The dashboard renders the card from a blob URL, where a relative
    # stylesheet or script cannot resolve: inline the card's own files here.
    shopt -u patsub_replacement 2>/dev/null || true
    local card_dir="$plugin_dir/cards/$card_name" ref asset_file tag guard=0
    while (( guard++ < 20 )) && [[ "$content" =~ \<link[^\>]*href=\"([A-Za-z0-9_./-]+\.css)\"[^\>]*\> ]]; do
        tag="${BASH_REMATCH[0]}"; ref="${BASH_REMATCH[1]}"; asset_file="$card_dir/$ref"
        if [[ "$ref" != *..* && -f "$asset_file" ]]; then
            content="${content/"$tag"/<style>$(head -c 262144 "$asset_file")</style>}"
        else
            content="${content/"$tag"/}"
        fi
    done
    guard=0
    while (( guard++ < 20 )) && [[ "$content" =~ \<script[^\>]*src=\"([A-Za-z0-9_./-]+\.js)\"[^\>]*\>[[:space:]]*\</script\> ]]; do
        tag="${BASH_REMATCH[0]}"; ref="${BASH_REMATCH[1]}"; asset_file="$card_dir/$ref"
        if [[ "$ref" != *..* && -f "$asset_file" ]]; then
            content="${content/"$tag"/<script>$(head -c 262144 "$asset_file")</script>}"
        else
            content="${content/"$tag"/}"
        fi
    done

    _api_success "{\"plugin\": \"$(_api_json_escape "$plugin_name")\", \"card\": \"$(_api_json_escape "$card_name")\", \"html\": \"$(_api_json_escape "$content")\"}"
}

# POST /plugins/{plugin}/cards/{card} — Create or replace a dashboard card in a plugin {meta{}, html}
handle_plugin_card_save() {
    local plugin_name="$1" card_name="$2" body="$3"
    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi
    local plugin_dir="$BASE_DIR/.plugins/$plugin_name"
    local html meta
    html=$(printf '%s' "$body" | jq -r '.html // empty' 2>/dev/null)
    [[ -n "$html" ]] || { _api_error 400 "Missing 'html'"; return; }
    (( ${#html} <= 1048576 )) || { _api_error 413 "Card HTML is larger than 1 MiB"; return; }
    meta=$(printf '%s' "$body" | jq -c --arg n "$card_name" '(.meta // {}) | select(type == "object") | . + {name: $n} | .title = (.title // $n)' 2>/dev/null)
    [[ -n "$meta" ]] || { _api_error 400 "'meta' must be an object"; return; }
    # A plugin that holds only cards is created on the spot, enabled
    if [[ ! -d "$plugin_dir" ]]; then
        mkdir -p "$plugin_dir/hooks" || { _api_error 500 "Cannot create the plugin directory"; return; }
        jq -n --arg n "$plugin_name" '{name: $n, version: "1.0.0", description: "Dashboard cards made in DCS Manager", author: "You", enabled: true, hooks: []}' > "$plugin_dir/plugin.json"
    fi
    local card_dir="$plugin_dir/cards/$card_name"
    _plugin_path_ok "$plugin_dir" "$card_dir" || { _api_error 400 "Invalid card location"; return; }
    mkdir -p "$card_dir" || { _api_error 500 "Cannot create the card directory"; return; }
    printf '%s\n' "$meta" > "$card_dir/card.json.tmp" && mv -f "$card_dir/card.json.tmp" "$card_dir/card.json" || { _api_error 500 "Cannot write card.json"; return; }
    printf '%s' "$html" > "$card_dir/index.html.tmp" && mv -f "$card_dir/index.html.tmp" "$card_dir/index.html" || { _api_error 500 "Cannot write index.html"; return; }
    _audit_log "plugin.card" "Saved card $plugin_name/$card_name" 2>/dev/null || true
    _api_success "{\"success\": true, \"plugin\": \"$(_api_json_escape "$plugin_name")\", \"card\": \"$(_api_json_escape "$card_name")\", \"id\": \"plugin:$(_api_json_escape "$plugin_name"):$(_api_json_escape "$card_name")\"}"
}

# GET /plugins/{plugin}/cards/{card}/source — The card's manifest and raw HTML, for editing
handle_plugin_card_source() {
    local plugin_name="$1" card_name="$2"
    local plugin_dir="$BASE_DIR/.plugins/$plugin_name"
    local card_dir="$plugin_dir/cards/$card_name"
    if [[ ! -f "$card_dir/index.html" ]] || ! _plugin_path_ok "$plugin_dir" "$card_dir/index.html"; then
        _api_error 404 "Card not found: $plugin_name/$card_name"
        return
    fi
    local meta html files
    meta=$(jq -c . "$card_dir/card.json" 2>/dev/null) || meta='{}'
    html=$(head -c 1048576 "$card_dir/index.html" 2>/dev/null)
    files=$(command ls -1 "$card_dir" 2>/dev/null | jq -R . | jq -sc .)
    _api_success "{\"plugin\": \"$(_api_json_escape "$plugin_name")\", \"card\": \"$(_api_json_escape "$card_name")\", \"meta\": $meta, \"html\": \"$(_api_json_escape "$html")\", \"files\": $files}"
}

# DELETE /plugins/{plugin}/cards/{card} — Remove a dashboard card from a plugin
handle_plugin_card_delete() {
    local plugin_name="$1" card_name="$2"
    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi
    local plugin_dir="$BASE_DIR/.plugins/$plugin_name"
    local card_dir="$plugin_dir/cards/$card_name"
    if [[ ! -d "$card_dir" ]] || ! _plugin_path_ok "$plugin_dir" "$card_dir"; then
        _api_error 404 "Card not found: $plugin_name/$card_name"
        return
    fi
    rm -rf -- "$card_dir" || { _api_error 500 "Could not remove the card"; return; }
    _audit_log "plugin.card" "Removed card $plugin_name/$card_name" 2>/dev/null || true
    _api_success "{\"success\": true, \"plugin\": \"$(_api_json_escape "$plugin_name")\", \"card\": \"$(_api_json_escape "$card_name")\"}"
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

    # docker events feeds the stream through a process substitution so that $!
    # is the docker process itself; the EXIT trap kills it when the client goes
    # away (the next printf fails, or SIGPIPE ends the handler).
    local events_pid=""
    trap 'kill "${events_pid:-}" 2>/dev/null; exit 0' EXIT PIPE TERM INT
    docker events --format '{{json .}}' 2>/dev/null > >(while IFS= read -r event_line; do
        printf "event: docker-event\ndata: %s\n\n" "$event_line" 2>/dev/null || exit 0
    done) &
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

        local running=0 total=0 _st
        while IFS= read -r _st; do
            [[ -z "$_st" ]] && continue
            total=$((total + 1))
            [[ "$_st" == "running" ]] && running=$((running + 1))
        done < <(timeout 3 docker ps -a --format '{{.State}}' 2>/dev/null)

        local ts
        ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

        printf "event: metrics\ndata: {\"ts\":\"%s\",\"cpu_pct\":%s,\"mem_pct\":%s,\"containers_running\":%d,\"containers_total\":%d}\n\n" \
            "$ts" "$cpu_pct" "$mem_pct" "$running" "$total" 2>/dev/null || break

        # Heartbeat comment to keep connection alive
        printf ": heartbeat %d\n\n" "$iteration" 2>/dev/null || break

        iteration=$((iteration + 1))
        sleep 5
    done
}

# =============================================================================
# REQUEST ROUTER
# =============================================================================

handle_request() {
    local method="" path=""

    # Read the HTTP request line (bounded wait: an idle connection must not pin
    # a handler process forever)
    local request_line=""
    if ! read -r -t 10 request_line; then
        printf 'HTTP/1.1 408 Request Timeout\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
        return
    fi
    request_line="${request_line%%$'\r'}"

    # Parse method and path without spawning subprocesses
    read -r method path _ <<< "$request_line"
    if [[ -z "$method" || -z "$path" || "$path" != /* ]]; then
        printf 'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
        return
    fi

    # Consume remaining headers and capture Content-Length, Authorization, Origin
    local header="" content_length=0
    REQUEST_AUTH_HEADER=""
    REQUEST_ORIGIN_HEADER=""
    REQUEST_XFF_HEADER=""
    AUTH_ERROR=""
    local _hdr_count=0
    while IFS= read -r -t 10 header; do
        (( ++_hdr_count ))
        if [[ $_hdr_count -gt 100 ]]; then
            printf 'HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
            return
        fi
        if [[ ${#header} -gt 16384 ]]; then
            printf 'HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
            return
        fi
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
        # Capture X-Forwarded-For — only honoured when the peer is a trusted proxy
        if [[ "${header,,}" == x-forwarded-for:* ]]; then
            REQUEST_XFF_HEADER="${header#*: }"
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

    # Resolve the client IP once — used for whitelisting, rate limiting and audit
    _api_resolve_client_ip
    local client_ip="$CLIENT_IP"
    REQUEST_METHOD="$method"
    REQUEST_PATH="$path"

    # Log the request and increment stats counter
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
            _api_error 401 "${AUTH_ERROR:-Authentication required. Provide Authorization: Bearer <token> header.}"
            return
        fi
        if ! _api_route_allowed "$method" "$path"; then
            _api_error 403 "Admin access required"
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
            /crowdsec/status)           handle_crowdsec_status ;;
            /routes/health)             handle_routes_health ;;
            /crowdsec/decisions)        handle_crowdsec_decisions ;;
            /topology)                  handle_topology ;;
            /traefik/status)            handle_traefik_status ;;
            /routes)                    handle_routes ;;
            /routes/check)              handle_routes_check "${QUERY_PARAMS[subdomain]:-}" ;;
            /dns/status)                handle_dns_status ;;
            /dns/zones)                 handle_dns_zones ;;
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
            /plugins/catalog)           handle_plugins_catalog ;;
            /plugins/*/cards/*/source)
                local pname="${path#/plugins/}"
                local cname="${pname#*/cards/}"
                pname="${pname%%/*}"
                cname="${cname%%/*}"
                _api_validate_resource_name "$pname" "plugin" || return
                _api_validate_resource_name "$cname" "card" || return
                handle_plugin_card_source "$pname" "$cname"
                ;;
            /plugins/*/cards/*)
                local pname="${path#/plugins/}"
                local cname="${pname#*/cards/}"
                pname="${pname%%/*}"
                cname="${cname%%/*}"
                _api_validate_resource_name "$pname" "plugin" || return
                _api_validate_resource_name "$cname" "card" || return
                handle_plugin_card_content "$pname" "$cname"
                ;;
            /plugins/*/hooks/*)
                local pname="${path#/plugins/}"
                local hook_name="${pname#*/hooks/}"
                pname="${pname%%/*}"
                _api_validate_resource_name "$pname" "plugin" || return
                _api_validate_resource_name "$hook_name" "hook" || return
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
            /secrets/*/references)
                local key="${path#/secrets/}"
                key="${key%/references}"
                _api_validate_resource_name "$key" "secret" || return
                handle_secret_references "$key"
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
            /stacks/*/activity)
                local stack="${path#/stacks/}"
                stack="${stack%/activity}"
                _api_validate_stack_name "$stack" || return
                handle_stack_activity "$stack"
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
            _api_error 401 "${AUTH_ERROR:-Authentication required. Provide Authorization: Bearer <token> header.}"
            return
        fi
        if ! _api_route_allowed "$method" "$path"; then
            _api_error 403 "Admin access required"
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
            /containers/*/env)
                local container="${path#/containers/}"
                container="${container%/env}"
                _api_validate_resource_name "$container" "container" || return
                handle_container_env_update "$container" "$request_body"
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
            /networks/*/recreate)
                local network="${path#/networks/}"
                network="${network%/recreate}"
                _api_validate_resource_name "$network" "network" || return
                handle_network_recreate "$network" "$request_body"
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
            /backups/cancel)
                handle_backup_cancel
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
            /dns/records)
                handle_dns_record_create "$request_body"
                ;;
            /dns/records/sync)
                handle_dns_records_sync
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
                _api_validate_image_ref "$img" || return
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
                _api_validate_stack_name "$sname" || return
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
            /routes/reconcile)
                handle_routes_reconcile
                ;;
            /crowdsec/trust)
                handle_crowdsec_trust "$request_body"
                ;;
            /crowdsec/unban-me)
                handle_crowdsec_unban_me
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
            /automations/*/run)
                local auto_id="${path#/automations/}"
                auto_id="${auto_id%/run}"
                _api_validate_resource_name "$auto_id" "automation" || return
                handle_automation_run "$auto_id" "$request_body"
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
            /schedules/*/run)
                local sched_id="${path#/schedules/}"
                sched_id="${sched_id%/run}"
                _api_validate_resource_name "$sched_id" "schedule" || return
                handle_schedule_run "$sched_id"
                ;;
            /plugins/catalog/*/install)
                local _cat="${path#/plugins/catalog/}"
                _cat="${_cat%/install}"
                _api_validate_resource_name "$_cat" "plugin" || return
                handle_plugin_catalog_install "$_cat"
                ;;
            /plugins/*/cards/*)
                local pname="${path#/plugins/}"
                local cname="${pname#*/cards/}"
                pname="${pname%%/*}"
                cname="${cname%%/*}"
                _api_validate_resource_name "$pname" "plugin" || return
                _api_validate_resource_name "$cname" "card" || return
                handle_plugin_card_save "$pname" "$cname" "$request_body"
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
                _api_validate_resource_name "$hook_name" "hook" || return
                handle_plugin_hook_test "$pname" "$hook_name" "$request_body"
                ;;
            /plugins/*/hooks/*/update)
                local pname="${path#/plugins/}"
                local rest="${pname#*/hooks/}"
                local hook_name="${rest%/update}"
                pname="${pname%%/*}"
                _api_validate_resource_name "$pname" "plugin" || return
                _api_validate_resource_name "$hook_name" "hook" || return
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
            _api_error 401 "${AUTH_ERROR:-Authentication required. Provide Authorization: Bearer <token> header.}"
            return
        fi
        if ! _api_route_allowed "$method" "$path"; then
            _api_error 403 "Admin access required"
            return
        fi

        # SECURITY: Audit log ALL PUT/PATCH requests
        _api_audit_log "$client_ip" "PUT" "${AUTH_USERNAME:-unknown}" "$path"

        case "$path" in
            /dns/records/*)
                local _rec_id="${path#/dns/records/}"
                handle_dns_record_update "$_rec_id" "$request_body"
                ;;
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
            _api_error 401 "${AUTH_ERROR:-Authentication required. Provide Authorization: Bearer <token> header.}"
            return
        fi
        if ! _api_route_allowed "$method" "$path"; then
            _api_error 403 "Admin access required"
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
            /crowdsec/decisions/*)
                local _cs_ip="${path#/crowdsec/decisions/}"
                handle_crowdsec_unban "$_cs_ip"
                ;;
            /crowdsec/trust/*)
                local _cs_ip="${path#/crowdsec/trust/}"
                handle_crowdsec_untrust "$_cs_ip"
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
            /plugins/*/cards/*)
                local pname="${path#/plugins/}"
                local cname="${pname#*/cards/}"
                pname="${pname%%/*}"
                cname="${cname%%/*}"
                _api_validate_resource_name "$pname" "plugin" || return
                _api_validate_resource_name "$cname" "card" || return
                handle_plugin_card_delete "$pname" "$cname"
                ;;
            /plugins/*)
                local pname="${path#/plugins/}"
                _api_validate_resource_name "$pname" "plugin" || return
                handle_plugin_remove "$pname"
                ;;
            /dns/records/*)
                local _rec_id="${path#/dns/records/}"
                handle_dns_record_delete "$_rec_id"
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
    echo "  ${_A_DIM}${_A_GRAY}$(printf '%0.s─' $(seq 1 60))${_A_RST}"
    echo ""
    echo "  ${_A_GREEN}Endpoints${_A_RST}  ${_A_DIM}curl http://${API_BIND}:${API_PORT}/${_A_RST}"
    echo "  ${_A_GREEN}Stop${_A_RST}       ${_A_DIM}$0 --stop${_A_RST}"
    echo ""
    echo "  ${_A_BOLD}${_A_BLUE}${border}${_A_RST}"
    echo ""

    # Refuse to start on a port something else already owns (another DCS
    # installation, an unrelated service): a bind failure inside socat would
    # only show up as a dead API from the UI's side.
    local _holders _h
    _holders=$(_api_port_listeners "$API_PORT")
    if [[ -n "$_holders" ]]; then
        for _h in $_holders; do
            echo "  ERROR: port ${API_PORT} is already in use by PID ${_h}: $(tr '\0' ' ' < "/proc/${_h}/cmdline" 2>/dev/null | cut -c1-80)" >&2
        done
        echo "         Stop that process ('$0 --stop' removes an orphaned DCS listener)," >&2
        echo "         or set API_PORT in .env to a free port, then start again." >&2
        exit 1
    elif command -v ss >/dev/null 2>&1 && [[ -n "$(ss -Hltn "sport = :${API_PORT}" 2>/dev/null)" ]]; then
        echo "  ERROR: port ${API_PORT} is already in use by another user's process." >&2
        echo "         Set API_PORT in .env to a free port, then start again." >&2
        exit 1
    fi

    # Write PID file (use $BASHPID for the actual process PID, not $$ which is always the parent)
    echo "${BASHPID:-$$}" > "$API_PID_FILE"

    if [[ "$API_AUTH_FORCED" == "true" ]]; then
        echo "  WARNING: API_AUTH_ENABLED=false was ignored because the listener is not"
        echo "           bound to loopback. Set API_INSECURE_NO_AUTH=true to override."
        echo ""
    elif [[ "$API_AUTH_ENABLED" != "true" ]] && ! _api_bind_is_loopback "$API_BIND"; then
        echo "  WARNING: authentication is DISABLED on a non-loopback address"
        echo "           (API_INSECURE_NO_AUTH=true). Anyone who can reach"
        echo "           ${API_BIND}:${API_PORT} controls this Docker host."
        echo ""
    fi

    # Graceful shutdown: stop the listener and every helper loop we started
    trap '_api_shutdown_children; rm -f "$API_PID_FILE"; exit 0' SIGTERM SIGINT SIGHUP

    local self_path
    self_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

    # Start DDNS loop (only once, in the server process — not per-request)
    if [[ "$DDNS_ENABLED" == "true" && -n "${CF_DNS_API_TOKEN:-}" && -n "${TRAEFIK_DOMAIN:-}" ]]; then
        _ddns_update_loop &
        local _ddns_pid=$!
        echo "$_ddns_pid" > "$DDNS_PID_FILE" 2>/dev/null
    fi

    # Start metrics collector background loop (same pattern as DDNS loop above)
    if [[ "${METRICS_ENABLED:-true}" == "true" ]]; then
        local _m_interval="${METRICS_COLLECT_INTERVAL:-60}"
        local _m_file="$BASE_DIR/.api-auth/metrics-history.jsonl"
        _dcs_metrics_loop() {
            # sleep runs as a job so SIGTERM ends the loop immediately
            trap 'kill "${_sleep_pid:-}" 2>/dev/null; exit 0' TERM INT
            while true; do
                local ts ep l1 l5 l15 nc cp mt ma mu mp dp
                ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
                ep=$(date +%s)
                read -r l1 l5 l15 _ _ < /proc/loadavg 2>/dev/null || { l1=0; l5=0; l15=0; }
                nc=$(nproc 2>/dev/null || echo 1)
                cp=$(awk "BEGIN {v=$l1/$nc*100; if(v>100)v=100; printf \"%.1f\", v}")
                mt=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
                ma=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
                mu=$((mt - ma))
                if [[ "$mt" -gt 0 ]]; then
                    mp=$(awk "BEGIN {printf \"%.1f\", $mu/$mt*100}")
                else
                    mp=0
                fi
                dp=$(df -P "$BASE_DIR" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
                [[ -z "$dp" ]] && dp=$(df -P / 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
                [[ -z "$dp" ]] && dp=0
                echo "{\"ts\":\"$ts\",\"epoch\":$ep,\"cpu_pct\":$cp,\"load1\":$l1,\"load5\":$l5,\"load15\":$l15,\"mem_used_mb\":$mu,\"mem_total_mb\":$mt,\"mem_pct\":$mp,\"disk_pct\":$dp}" >> "$_m_file"
                # Once an hour: trim raw samples and rebuild the 5-minute and hourly tiers
                if (( ep / 3600 != ${_last_rollup_hour:--1} )); then
                    _last_rollup_hour=$(( ep / 3600 ))
                    _metrics_rollup >/dev/null 2>&1 || true
                fi
                sleep "$_m_interval" & _sleep_pid=$!
                wait "$_sleep_pid" || true
            done
        }
        _dcs_metrics_loop &
        echo "  Metrics collector started (interval: ${_m_interval}s)"
    fi

    # Automations and schedules run in the server process (no crontab)
    if [[ "${AUTOMATIONS_ENABLED:-true}" == "true" ]]; then
        mkdir -p "$BASE_DIR/.data" "$BASE_DIR/logs" 2>/dev/null
        # Lines installed by older versions pointed at a route that never existed
        if crontab -l 2>/dev/null | grep -q '# DCS-AUTO:'; then
            _legacy=$(crontab -l 2>/dev/null | grep -v '# DCS-AUTO:[A-Za-z0-9_]*$')
            printf '%s\n' "$_legacy" | crontab - 2>/dev/null && echo "  Removed legacy automation crontab lines"
        fi
        _dcs_automation_loop &
        echo "  Automation engine started (rules and schedules, 1-minute clock)"
    fi

    # Periodic cleanup: stale rate-limit files and TOTP tracking.
    # sleep runs as a job so SIGTERM ends the loop at once instead of leaving
    # an hour-long sleep behind when the server stops.
    (
        trap 'kill "${_sleep_pid:-}" 2>/dev/null; exit 0' TERM INT
        while true; do
            sleep 3600 & _sleep_pid=$!
            wait "$_sleep_pid" || true
            find "${API_RATE_DIR:-$API_AUTH_DIR/rates}" -type f -mmin +1440 -delete 2>/dev/null
            : > "$API_AUTH_DIR/.totp-attempts" 2>/dev/null
        done
    ) &

    # Start the listener in the background and wait on it. A trap cannot run
    # while bash is blocked on a foreground child, so this is what makes
    # SIGTERM (systemd stop, --stop) actually stop the server. socat/ncat
    # invoke this script with --handle-request for every connection.
    local listener_pid
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
                EXEC:"$self_path --handle-request",nofork &
        else
            echo "Starting API server on http://${API_BIND}:${API_PORT}"
            socat "TCP-LISTEN:${API_PORT},bind=${API_BIND},reuseaddr,fork" \
                EXEC:"$self_path --handle-request",nofork &
        fi
    else
        # ncat mode
        ncat -l -k "${API_BIND}" "${API_PORT}" -e "$self_path --handle-request" &
    fi
    listener_pid=$!

    local rc=0
    wait "$listener_pid" || rc=$?
    # The listener exited on its own (port in use, crash): tidy up and report
    _api_shutdown_children
    rm -f "$API_PID_FILE"
    return "$rc"
}

# Stop the listener and the background loops started by start_server
_api_shutdown_children() {
    echo ""
    echo "  Shutting down API server..."
    local pids
    pids=$(jobs -p 2>/dev/null)
    [[ -n "$pids" ]] && kill $pids 2>/dev/null
    pkill -TERM -P "${BASHPID:-$$}" 2>/dev/null || true
    # Request handlers are socat's children, not ours: end the long-lived ones
    if [[ -n "${self_path:-}" ]]; then
        local self_re
        self_re=$(printf '%s' "$self_path" | sed 's/[][\.*^$+?(){}|]/\\&/g')
        pkill -TERM -f -- "${self_re} --handle-request$" 2>/dev/null || true
    fi
    rm -f "$DDNS_PID_FILE" 2>/dev/null
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
