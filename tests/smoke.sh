#!/bin/bash
# =============================================================================
# DCS API smoke tests
#
# Drives .scripts/api-server.sh's request handler directly over stdin, exactly
# the way socat does in production, so no listener, port or Docker daemon is
# needed. Runs against an isolated copy of the repository in a temp directory
# so it never touches real state.
#
# Usage: tests/smoke.sh            (exit status 0 = all passed)
# =============================================================================

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dcs-smoke-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Minimal isolated installation: scripts, config, one stack, an .env
mkdir -p "$WORK/.scripts" "$WORK/.lib" "$WORK/.config" "$WORK/Stacks/demo" "$WORK/.data" "$WORK/logs" "$WORK/.api-auth" "$WORK/.templates"
cp "$ROOT/.scripts/api-server.sh" "$WORK/.scripts/"
cp -r "$ROOT/.lib/." "$WORK/.lib/"
cp -r "$ROOT/.config/." "$WORK/.config/"
grep -vE '^(API_BIND|API_AUTH_ENABLED|API_INSECURE_NO_AUTH|API_TRUSTED_PROXIES|API_IP_WHITELIST|API_PORT)=' "$ROOT/.env.example" > "$WORK/.env"
printf 'services:\n  demo:\n    image: alpine:3\n    command: ["sleep","infinity"]\n' > "$WORK/Stacks/demo/docker-compose.yml"
printf 'API_PORT=9876\nMETRICS_ENABLED=false\n' >> "$WORK/.env"

API="$WORK/.scripts/api-server.sh"
PASS=0
FAIL=0

# request METHOD PATH [BODY] [extra env assignments...]
# Prints the full HTTP response. Environment overrides come after the body.
request() {
    local method="$1" path="$2" body="${3:-}"
    shift 3 2>/dev/null || shift $#
    local req
    if [[ -n "$body" ]]; then
        req=$(printf '%s %s HTTP/1.1\r\nHost: test\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s' "$method" "$path" "${#body}" "$body")
    else
        req=$(printf '%s %s HTTP/1.1\r\nHost: test\r\n\r\n' "$method" "$path")
    fi
    printf '%s' "$req" | env DOCKER_COMPOSE_CMD="${DOCKER_COMPOSE_CMD:-docker compose}" "$@" "$API" --handle-request 2>/dev/null
}

status_of() { head -1 | awk '{print $2}'; }
body_of()   { sed -n '/^\r*$/,$p' | sed '1d'; }

check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        PASS=$((PASS + 1)); printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s (expected %s, got %s)\n' "$name" "$expected" "$actual"
    fi
}

# Auth disabled on loopback: everything is anonymous admin
NOAUTH=(DCS_API_EFFECTIVE_AUTH=false DCS_API_EFFECTIVE_BIND=127.0.0.1)
# Auth enabled, no account yet: first-run window
AUTH=(DCS_API_EFFECTIVE_AUTH=true DCS_API_EFFECTIVE_BIND=127.0.0.1)

echo "Request parsing"
check "root endpoint answers"           200 "$(request GET / '' "${NOAUTH[@]}" | status_of)"
check "root body is JSON"               true "$(request GET / '' "${NOAUTH[@]}" | body_of | jq -e 'has("endpoints")' 2>/dev/null)"
check "garbage request line"            400 "$(printf 'GARBAGE\r\n\r\n' | "$API" --handle-request 2>/dev/null | status_of)"
check "encoded traversal rejected"      400 "$(request GET '/stacks/%2e%2e/x' '' "${NOAUTH[@]}" | status_of)"
check "unknown route"                   404 "$(request GET /nope '' "${NOAUTH[@]}" | status_of)"
check "unsupported method"              405 "$(request TRACE / '' "${NOAUTH[@]}" | status_of)"
check "oversized body"                  413 "$(printf 'POST /stacks HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n' | env "${NOAUTH[@]}" "$API" --handle-request 2>/dev/null | status_of)"
check "transfer-encoding rejected"      400 "$(printf 'POST /stacks HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n' | env "${NOAUTH[@]}" "$API" --handle-request 2>/dev/null | status_of)"
check "CORS preflight allows PUT"       yes "$(printf 'OPTIONS /routes/a/b HTTP/1.1\r\nOrigin: http://localhost:3000\r\n\r\n' | env "${NOAUTH[@]}" "$API" --handle-request 2>/dev/null | grep -qi 'Allow-Methods:.*PUT' && echo yes || echo no)"
check "security headers present"        yes "$(request GET / '' "${NOAUTH[@]}" | grep -qi '^X-Content-Type-Options: nosniff' && echo yes || echo no)"

echo "Authentication policy"
check "first-run: /version open"        200 "$(request GET /version '' "${AUTH[@]}" | status_of)"
check "first-run: /setup/status open"   200 "$(request GET /setup/status '' "${AUTH[@]}" | status_of)"
check "first-run: /stacks locked"       401 "$(request GET /stacks '' "${AUTH[@]}" | status_of)"
check "first-run: message explains"     yes "$(request GET /stacks '' "${AUTH[@]}" | body_of | grep -q 'auth/setup' && echo yes || echo no)"
check "first-run: POST locked"          401 "$(request POST /maintenance/prune '' "${AUTH[@]}" | status_of)"
check "bad token rejected"              401 "$(printf 'GET /stacks HTTP/1.1\r\nAuthorization: Bearer nope\r\n\r\n' | env "${AUTH[@]}" "$API" --handle-request 2>/dev/null | status_of)"
check "non-loopback forces auth"        401 "$(request GET /stacks '' API_BIND=0.0.0.0 API_AUTH_ENABLED=false | status_of)"
check "insecure opt-in honoured"        200 "$(request GET /stacks '' API_BIND=0.0.0.0 API_AUTH_ENABLED=false API_INSECURE_NO_AUTH=true | status_of)"

echo "Account lifecycle"
SETUP=$(request POST /auth/setup '{"username":"admin","password":"correct horse battery"}' "${AUTH[@]}")
check "admin account created"           200 "$(printf '%s' "$SETUP" | status_of)"
TOKEN=$(printf '%s' "$SETUP" | body_of | jq -r '.token // empty' 2>/dev/null)
check "token issued"                    yes "$([[ ${#TOKEN} -ge 32 ]] && echo yes || echo no)"
check "second setup refused"            400 "$(request POST /auth/setup '{"username":"x","password":"yyyyyyyyy"}' "${AUTH[@]}" | status_of)"
auth_request() { local m="$1" p="$2" b="${3:-}"; printf '%s %s HTTP/1.1\r\nAuthorization: Bearer %s\r\nContent-Length: %d\r\n\r\n%s' "$m" "$p" "$TOKEN" "${#b}" "$b" | env DOCKER_COMPOSE_CMD="${DOCKER_COMPOSE_CMD:-docker compose}" "${AUTH[@]}" "$API" --handle-request 2>/dev/null; }
check "token grants access"             200 "$(auth_request GET /version | status_of)"
check "wrong password rejected"         401 "$(request POST /auth/login '{"username":"admin","password":"wrong-password"}' "${AUTH[@]}" | status_of)"
LOGIN=$(request POST /auth/login '{"username":"admin","password":"correct horse battery"}' "${AUTH[@]}")
check "login works"                     200 "$(printf '%s' "$LOGIN" | status_of)"
check "login revokes the older session" 401 "$(auth_request GET /version | status_of)"
TOKEN=$(printf '%s' "$LOGIN" | body_of | jq -r '.token // empty' 2>/dev/null)
check "new session token works"         200 "$(auth_request GET /version | status_of)"
check "password hash is PBKDF2 (v2)"    2   "$(jq -r '.[0].hash_version' "$WORK/.api-auth/users.json" 2>/dev/null)"
check "auth files are private"          600 "$(stat -c %a "$WORK/.api-auth/users.json" 2>/dev/null)"
INVITE=$(auth_request POST /auth/invite '{"role":"user"}' | body_of | jq -r '.code // empty')
check "invite created"                  yes "$([[ -n "$INVITE" ]] && echo yes || echo no)"
REG=$(request POST /auth/register "{\"username\":\"viewer\",\"password\":\"viewer-pass-123\",\"invite_code\":\"$INVITE\"}" "${AUTH[@]}")
check "viewer registered"               200 "$(printf '%s' "$REG" | status_of)"
VTOKEN=$(printf '%s' "$REG" | body_of | jq -r '.token // empty')
viewer_request() { local m="$1" p="$2" b="${3:-}"; printf '%s %s HTTP/1.1\r\nAuthorization: Bearer %s\r\nContent-Length: %d\r\n\r\n%s' "$m" "$p" "$VTOKEN" "${#b}" "$b" | env DOCKER_COMPOSE_CMD="${DOCKER_COMPOSE_CMD:-docker compose}" "${AUTH[@]}" "$API" --handle-request 2>/dev/null; }
check "viewer can read stacks"          200 "$(viewer_request GET /stacks | status_of)"
check "viewer cannot read .env"         403 "$(viewer_request GET /env | status_of)"
check "viewer cannot mutate"            403 "$(viewer_request POST /maintenance/prune | status_of)"
check "viewer cannot install plugins"   403 "$(viewer_request POST /plugins/install '{"url":"https://example.com/x.git"}' | status_of)"
check "viewer can logout"               200 "$(viewer_request POST /auth/logout | status_of)"
check "viewer token gone after logout"  401 "$(viewer_request GET /stacks | status_of)"

echo "Input validation"
check "env save rejects command subst"  400 "$(auth_request POST /env '{"content":"FOO=$(id)"}' | status_of)"
check "env save rejects LD_PRELOAD"     400 "$(auth_request POST /env '{"content":"LD_PRELOAD=/x.so"}' | status_of)"
check "env save accepts plain data"     200 "$(auth_request POST /env '{"content":"API_BIND=127.0.0.1\nTZ=UTC\nMETRICS_ENABLED=false\n"}' | status_of)"
check "env file mode private"           600 "$(stat -c %a "$WORK/.env" 2>/dev/null)"
check "config update rejects backticks" 400 "$(auth_request POST /config '{"TZ":"`id`"}' | status_of)"
check "config update rejects bad key"   400 "$(auth_request POST /config '{"PATH":"/x"}' | status_of)"
check "config update accepts value"     200 "$(auth_request POST /config '{"TZ":"Europe/London"}' | status_of)"
check "config value written"            yes "$(grep -q '^TZ=Europe/London$' "$WORK/.env" && echo yes || echo no)"
check "bad stack name rejected"         400 "$(auth_request GET '/stacks/..evil' | status_of)"
check "batch stacks validates names"    400 "$(auth_request POST /batch/stacks '{"action":"start","stacks":["../../etc"]}' | status_of)"
check "metrics range is validated"      1h  "$(auth_request GET '/metrics/trends?range=1h%22,env:$ENV,x:%22' | body_of | jq -r '.range' 2>/dev/null)"
check "routes/check validates subdomain" 400 "$(auth_request GET '/routes/check?subdomain=a%7Cg;e%20id' | status_of)"
check "snapshot name validated"         400 "$(auth_request GET '/snapshots/evil.tar.gz/download' | status_of)"
check "image ref validated"             400 "$(auth_request POST '/images/--help/update' | status_of)"
check "compose rollback id validated"   400 "$(auth_request POST '/stacks/demo/compose/rollback' '{"version_id":"../../x"}' | status_of)"

echo "Client IP handling"
LOG="$WORK/logs/api-server.log"
: > "$LOG"
request GET /version '' "${NOAUTH[@]}" SOCAT_PEERADDR=10.9.9.9 API_TRUSTED_PROXIES=10.0.0.0/8 REQUEST_XFF_HEADER= >/dev/null
printf 'GET /version HTTP/1.1\r\nX-Forwarded-For: 203.0.113.7, 10.9.9.9\r\n\r\n' | env "${NOAUTH[@]}" SOCAT_PEERADDR=10.9.9.9 API_TRUSTED_PROXIES=10.0.0.0/8 "$API" --handle-request >/dev/null 2>&1
check "XFF from trusted proxy used"     yes "$(tail -1 "$LOG" | grep -q '\[203.0.113.7\]' && echo yes || echo no)"
printf 'GET /version HTTP/1.1\r\nX-Forwarded-For: 203.0.113.7\r\n\r\n' | env "${NOAUTH[@]}" SOCAT_PEERADDR=192.0.2.5 API_TRUSTED_PROXIES=10.0.0.0/8 "$API" --handle-request >/dev/null 2>&1
check "XFF from untrusted peer ignored" yes "$(tail -1 "$LOG" | grep -q '\[192.0.2.5\]' && echo yes || echo no)"
printf 'GET /version HTTP/1.1\r\nX-Forwarded-For: 127.0.0.1, 192.0.2.9\r\n\r\n' | env "${NOAUTH[@]}" SOCAT_PEERADDR=10.9.9.9 API_TRUSTED_PROXIES=10.0.0.0/8 API_IP_WHITELIST=192.168.1.0/24 "$API" --handle-request 2>/dev/null | status_of | { read -r s; check "spoofed loopback in XFF cannot bypass whitelist" 403 "$s"; }
printf 'GET /version HTTP/1.1\r\nX-Forwarded-For: 192.168.1.20\r\n\r\n' | env "${NOAUTH[@]}" SOCAT_PEERADDR=10.9.9.9 API_TRUSTED_PROXIES=10.0.0.0/8 API_IP_WHITELIST=192.168.1.0/24 "$API" --handle-request 2>/dev/null | status_of | { read -r s; check "whitelisted client behind trusted proxy admitted" 200 "$s"; }

echo "Docker-backed endpoints (skipped when Docker is unavailable)"
if docker info >/dev/null 2>&1; then
    check "GET /status"                 200 "$(auth_request GET /status | status_of)"
    check "GET /stacks lists demo"      demo "$(auth_request GET /stacks | body_of | jq -r '.stacks[0].name' 2>/dev/null)"
    check "GET /stacks/demo"            200 "$(auth_request GET /stacks/demo | status_of)"
    check "GET /containers"             200 "$(auth_request GET /containers | status_of)"
    check "GET /health"                 200 "$(auth_request GET /health | status_of)"
    check "GET /maintenance/disk"       200 "$(auth_request GET /maintenance/disk | status_of)"
    check "GET /images/check-updates"   200 "$(auth_request GET /images/check-updates | status_of)"
    check "GET /templates"              200 "$(auth_request GET /templates | status_of)"
else
    echo "  skip (no Docker daemon)"
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
