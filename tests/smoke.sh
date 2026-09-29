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
trap '[[ -n "${RIP_MAIN:-}" ]] && kill "$RIP_MAIN" 2>/dev/null; [[ -n "${RIP_DDNS:-}" ]] && kill "$RIP_DDNS" 2>/dev/null; rm -rf "$WORK"' EXIT

# Minimal isolated installation: scripts, config, one stack, an .env
mkdir -p "$WORK/.scripts" "$WORK/.lib" "$WORK/.config" "$WORK/Stacks/demo" "$WORK/.data" "$WORK/logs" "$WORK/.api-auth" "$WORK/.templates"
cp "$ROOT/.scripts/api-server.sh" "$WORK/.scripts/"
cp "$ROOT/compose.sh" "$WORK/"
cp "$ROOT/VERSION" "$WORK/"   # the hub's bundle carries it; /ping and /fleet/versions report it
mkdir -p "$WORK/vm-images"; cp "$ROOT/vm-images/images.json" "$WORK/vm-images/"   # the list of purpose-built VM images (the catalogue reads it)
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
check "CORS preflight is cached"         yes "$(printf 'OPTIONS /status HTTP/1.1\r\nOrigin: http://localhost:3000\r\n\r\n' | env "${NOAUTH[@]}" "$API" --handle-request 2>/dev/null | grep -qi '^Access-Control-Max-Age: 600' && echo yes || echo no)"
check "a plain answer has no max-age"   no "$(printf 'GET / HTTP/1.1\r\nOrigin: http://localhost:3000\r\n\r\n' | env "${NOAUTH[@]}" "$API" --handle-request 2>/dev/null | grep -qi '^Access-Control-Max-Age' && echo yes || echo no)"
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
# settings that did nothing were removed in 4.0: an older dashboard may still send them; they are accepted, ignored, and no longer offered
check "config update accepts a retired setting"   200 "$(auth_request POST /config '{"SCHEDULER_ENABLED":"true"}' | status_of)"
check "config: …and does not write it"            0 "$(grep -c '^SCHEDULER_ENABLED' "$WORK/.env" 2>/dev/null || true)"
check "config: the retired settings are not offered" "" "$(auth_request GET /config | body_of | jq -r '[.scheduler_enabled, .health_score_enabled, .max_parallel_operations, .include_resource_metrics, .docker_timeout, .force_recreate, .log_max_size, .color_theme] | map(select(. != null)) | join(",")' 2>/dev/null)"
check "config: the schema does not describe them"  0 "$(jq -r '[.. | objects | keys[]? | select(. == "SCHEDULER_ENABLED" or . == "HEALTH_SCORE_ENABLED" or . == "MAX_PARALLEL_OPERATIONS" or . == "INCLUDE_RESOURCE_METRICS")] | length' "$ROOT/.config/schema.json" 2>/dev/null)"
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

echo "Heartbeat fast path"
# GET /ping is answered before the ~26,000 lines of handlers are parsed; every answer has to be the one the normal path gives
_fp_req() { local raw="$1"; shift; printf '%b' "$raw" | env DOCKER_COMPOSE_CMD="${DOCKER_COMPOSE_CMD:-docker compose}" "${NOAUTH[@]}" "$@" "$API" --handle-request 2>/dev/null | sed -E 's/"time": [0-9]+/"time": T/'; }
_fp_same() { local name="$1" raw="$2"; shift 2; local fast slow; fast=$(_fp_req "$raw" "$@"); slow=$(_fp_req "$raw" DCS_NO_FAST_PING=1 "$@"); check "heartbeat: $name" yes "$([[ -n "$fast" && "$fast" == "$slow" ]] && echo yes || echo no)"; }
_fp_same "no Origin"                        'GET /ping HTTP/1.1\r\nHost: x\r\n\r\n'
_fp_same "a local Origin"                   'GET /ping HTTP/1.1\r\nOrigin: http://localhost:3013\r\n\r\n'
_fp_same "a foreign Origin is not allowed"  'GET /ping HTTP/1.1\r\nOrigin: http://192.0.2.9:3003\r\n\r\n'
_fp_same "a configured Origin is allowed"   'GET /ping HTTP/1.1\r\nOrigin: http://192.0.2.9:3003\r\n\r\n' API_CORS_ORIGINS=http://192.0.2.9:3003
_fp_same "behind a TLS proxy (HSTS)"        'GET /ping HTTP/1.1\r\nHost: x\r\n\r\n' API_BEHIND_TLS_PROXY=true
_fp_same "a trailing slash"                 'GET /ping/ HTTP/1.1\r\nHost: x\r\n\r\n'
_fp_same "HTTP/1.0"                         'GET /ping HTTP/1.0\r\n\r\n'
_fp_same "a query string takes the normal path" 'GET /ping?x=1 HTTP/1.1\r\nHost: x\r\n\r\n'
_fp_same "HEAD takes the normal path"       'HEAD /ping HTTP/1.1\r\nHost: x\r\n\r\n'
_fp_same "POST takes the normal path"       'POST /ping HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}'
_fp_same "another route takes the normal path" 'GET /version HTTP/1.1\r\nHost: x\r\n\r\n'
_fp_same "garbage takes the normal path"    'GARBAGE\r\n\r\n'
_fp_same "the IP allow-list decides"        'GET /ping HTTP/1.1\r\nHost: x\r\n\r\n' API_IP_WHITELIST=203.0.113.0/24 SOCAT_PEERADDR=198.51.100.7
_fp_same "the setup mode's open CORS"       'GET /ping HTTP/1.1\r\nOrigin: http://192.0.2.9:3003\r\n\r\n' DCS_API_SETUP_MODE=true
check "heartbeat: a second header line cannot inject one" 0 "$(_fp_req 'GET /ping HTTP/1.1\r\nOrigin: http://localhost:1234\r\nSet-Cookie: evil\r\n\r\n' | grep -ci '^set-cookie')"
check "heartbeat: the answer is the liveness body" 1 "$(_fp_req 'GET /ping HTTP/1.1\r\nHost: x\r\n\r\n' | tail -1 | grep -c '^{"ok": true, "version": ".*", "api_version": ".*", "time": T}$')"
: > "$LOG"; _fp_req 'GET /ping HTTP/1.1\r\nHost: x\r\n\r\n' >/dev/null
check "heartbeat: the fast path leaves no access-log line" 0 "$(grep -c 'GET /ping' "$LOG" 2>/dev/null)"
: > "$LOG"; _fp_req 'GET /ping HTTP/1.1\r\nHost: x\r\n\r\n' DCS_NO_FAST_PING=1 >/dev/null
check "heartbeat: the normal path still logs it"           1 "$(grep -c 'GET /ping' "$LOG" 2>/dev/null)"

echo "Automations, schedules and the cron matcher"
_lib() { local -a _c=("$@"); ( set --; source "$API" >/dev/null 2>&1; "${_c[@]}" ) 2>/dev/null; }
VTOKEN=$(request POST /auth/login '{"username":"viewer","password":"viewer-pass-123"}' "${AUTH[@]}" | body_of | jq -r '.token // empty')
check "viewer signed in again"          200 "$(viewer_request GET /stacks | status_of)"
# Schedules run in the installation's TZ (from .env); compute test instants the same way
_cron() { _lib _cron_matches "$1" "$(TZ="$(grep -m1 '^TZ=' "$WORK/.env" | cut -d= -f2- | tr -d '"')" date -d "$2" +%s)"; echo $?; }
check "cron: */5 fires at :15"          0 "$(_cron '*/5 * * * *' '2026-09-24 10:15:00')"
check "cron: */5 silent at :16"         1 "$(_cron '*/5 * * * *' '2026-09-24 10:16:00')"
check "cron: @daily at midnight"        0 "$(_cron '@daily' '2026-09-24 00:00:00')"
check "cron: @daily not at 00:01"       1 "$(_cron '@daily' '2026-09-24 00:01:00')"
check "cron: range + list"              0 "$(_cron '30 9-17 * * 1,3,5' '2026-09-25 14:30:00')"
check "cron: weekday mismatch"          1 "$(_cron '30 9-17 * * 1,3,5' '2026-09-24 14:30:00')"
check "cron: @5min preset accepted"     0 "$(_lib _validate_cron_expression '@5min'; echo $?)"
check "cron: injection rejected"        1 "$(_lib _validate_cron_expression '* * * * * ; id'; echo $?)"
AID=$(auth_request POST /automations '{"name":"smoke","trigger_type":"schedule","trigger_value":"*/5 * * * *","action_type":"notification_send","action_target":"hello"}' | body_of | jq -r '.id // empty' 2>/dev/null)
check "automation created"              yes "$([[ -n "$AID" ]] && echo yes || echo no)"
check "automation rejects unknown action" 400 "$(auth_request POST /automations '{"name":"x","trigger_type":"schedule","trigger_value":"* * * * *","action_type":"rm_rf"}' | status_of)"
check "automation rejects bad cron"     400 "$(auth_request POST /automations '{"name":"x","trigger_type":"schedule","trigger_value":"every day","action_type":"docker_prune"}' | status_of)"
check "automation rejects bad condition" 400 "$(auth_request POST /automations '{"name":"x","trigger_type":"condition","trigger_value":"moon_full","action_type":"docker_prune"}' | status_of)"
check "automation run now answers"      200 "$(auth_request POST "/automations/$AID/run" | status_of)"
check "automation history recorded"     1 "$(auth_request GET "/automations/$AID/history" | body_of | jq '.history | length' 2>/dev/null)"
check "automation run_count incremented" 1 "$(auth_request GET /automations | body_of | jq '.automations[0].run_count' 2>/dev/null)"
check "unknown automation history"      404 "$(auth_request GET /automations/nope/history | status_of)"
check "viewer cannot run automations"   403 "$(viewer_request POST "/automations/$AID/run" | status_of)"
check "no crontab line installed"       0 "$(crontab -l 2>/dev/null | grep -c 'DCS-AUTO' || true)"
check "automation deleted"              200 "$(auth_request DELETE "/automations/$AID" | status_of)"
check "delete unknown automation"       404 "$(auth_request DELETE /automations/nope | status_of)"

echo "Secrets"
check "secret name rule enforced"       400 "$(auth_request POST /secrets '{"key":"bad-name","value":"x"}' | status_of)"
check "secret stored"                   200 "$(auth_request POST /secrets '{"key":"DEMO_PASSWORD","value":"s3cret-value"}' | status_of)"
check "secret listed by name"           DEMO_PASSWORD "$(auth_request GET /secrets | body_of | jq -r '.secrets[0].key' 2>/dev/null)"
check "secret value never listed"       no "$(auth_request GET /secrets | body_of | grep -q 's3cret-value' && echo yes || echo no)"
# shellcheck disable=SC2034  # BASE_DIR is read by the sourced library
check "library decrypts the API's file" s3cret-value "$( (BASE_DIR="$WORK"; source "$WORK/.lib/secrets.sh"; secrets_get DEMO_PASSWORD) 2>/dev/null)"
check "viewer cannot list secrets"      403 "$(viewer_request GET /secrets | status_of)"
printf 'services:\n  x:\n    image: alpine\n    environment:\n      - A=${SECRETS_DEMO_PASSWORD}\n      - B=${SECRETS_MISSING_ONE}\n' > "$WORK/Stacks/demo/docker-compose.yml"
check "references resolve to stack"     demo "$(auth_request GET /secrets/DEMO_PASSWORD/references | body_of | jq -r '.stacks[0]' 2>/dev/null)"
check "start refuses missing secret"    422 "$(auth_request POST /stacks/demo/start | status_of)"
check "validate never resolves secrets" no "$(auth_request POST /stacks/demo/compose/validate "$(jq -Rs '{content: .}' < "$WORK/Stacks/demo/docker-compose.yml")" | body_of | grep -q 's3cret-value' && echo yes || echo no)"
printf 'services:\n  x:\n    image: alpine\n' > "$WORK/Stacks/demo/docker-compose.yml"
check "secret deleted"                  200 "$(auth_request DELETE /secrets/DEMO_PASSWORD | status_of)"
check "delete unknown secret"           404 "$(auth_request DELETE /secrets/DEMO_PASSWORD | status_of)"

echo "Metrics history"
NOW=$(date +%s)
for i in $(seq 0 399); do printf '{"ts":"x","epoch":%d,"cpu_pct":%d,"mem_pct":50,"disk_pct":10,"load1":0.5,"mem_used_mb":100,"mem_total_mb":200}\n' $((NOW - 14400 + i * 36)) $((i % 100)); done > "$WORK/.api-auth/metrics-history.jsonl"
check "trends 6h returns all samples"   400 "$(auth_request GET '/metrics/trends?range=6h' | body_of | jq '.count' 2>/dev/null)"
check "trends 1h returns the last hour" yes "$(auth_request GET '/metrics/trends?range=1h' | body_of | jq -e '.count >= 99 and .count <= 100' >/dev/null 2>&1 && echo yes || echo no)"
check "trends unknown range falls back" 1h "$(auth_request GET '/metrics/trends?range=nope' | body_of | jq -r '.range' 2>/dev/null)"
check "trends 1y stitches raw when young" 400 "$(auth_request GET '/metrics/trends?range=1y' | body_of | jq '.count' 2>/dev/null)"
check "trends reports oldest sample"    yes "$(auth_request GET '/metrics/trends?range=all' | body_of | jq -e '.oldest_epoch != null and .resolution_s == 30' >/dev/null 2>&1 && echo yes || echo no)"
_lib _metrics_rollup
check "5-minute rollup written"         yes "$([[ -s "$WORK/.data/metrics/rollup-5m.jsonl" ]] && echo yes || echo no)"
check "rollup rows carry min/max"       yes "$(head -1 "$WORK/.data/metrics/rollup-5m.jsonl" | jq -e 'has("cpu_max") and has("n")' >/dev/null 2>&1 && echo yes || echo no)"
check "hourly rollup written"           yes "$([[ -s "$WORK/.data/metrics/rollup-1h.jsonl" ]] && echo yes || echo no)"
check "summary includes disk"           yes "$(auth_request GET '/metrics/summary?range=24h' | body_of | jq -e '.disk.max == 10 and .samples == 400' >/dev/null 2>&1 && echo yes || echo no)"
for i in $(seq 0 3999); do printf '{"ts":"x","epoch":%d,"cpu_pct":1,"mem_pct":1,"disk_pct":1}\n' $((NOW - 86000 + i * 21)); done > "$WORK/.api-auth/metrics-history.jsonl"
check "large ranges are downsampled"    yes "$(auth_request GET '/metrics/trends?range=24h' | body_of | jq -e '.count <= 1500 and .total == 4000 and .resolution_s >= 30' >/dev/null 2>&1 && echo yes || echo no)"
[[ "${SMOKE_DEBUG:-}" == "1" ]] && auth_request GET '/metrics/trends?range=24h' | body_of | jq -c '{count,total,resolution_s,oldest_epoch,newest_epoch}' 2>/dev/null
check "bad sample lines are skipped"    yes "$(printf 'not json\n' >> "$WORK/.api-auth/metrics-history.jsonl"; auth_request GET '/metrics/trends?range=1h' | body_of | jq -e '.count > 0' >/dev/null 2>&1 && echo yes || echo no)"

echo "CrowdSec and proxy routes"
check "crowdsec status without container" false "$(auth_request GET /crowdsec/status | body_of | jq '.installed' 2>/dev/null)"
check "crowdsec unban validates ip"     400 "$(auth_request DELETE '/crowdsec/decisions/not-an-ip' | status_of)"
check "crowdsec trust validates ip"     400 "$(auth_request POST /crowdsec/trust '{"ip":"999.1.1.1"}' | status_of)"
check "viewer may unban itself"         404 "$(viewer_request POST /crowdsec/unban-me | status_of)"
check "viewer cannot edit trust list"   403 "$(viewer_request POST /crowdsec/trust '{"ip":"203.0.113.9"}' | status_of)"
check "routes health answers"           200 "$(auth_request GET /routes/health | status_of)"
check "viewer cannot reconcile proxy"   403 "$(viewer_request POST /routes/reconcile | status_of)"

echo "Cloudflare DNS management (no token in the test install)"
check "verify without token is 401"     401 "$(printf 'GET /auth/verify HTTP/1.1\r\n\r\n' | env "${AUTH[@]}" "$API" --handle-request 2>/dev/null | status_of)"
check "verify with a dead token is 401" 401 "$(printf 'GET /auth/verify HTTP/1.1\r\nAuthorization: Bearer %s\r\n\r\n' "$(printf '0%.0s' $(seq 1 64))" | env "${AUTH[@]}" "$API" --handle-request 2>/dev/null | status_of)"
check "verify with the session is 200"  200 "$(auth_request GET /auth/verify | status_of)"
check "dns status answers"              200 "$(auth_request GET /dns/status | status_of)"
check "dns status reports no token"     false "$(auth_request GET /dns/status | body_of | jq '.cf_configured' 2>/dev/null)"
check "dns status carries a hint"       yes "$(auth_request GET /dns/status | body_of | jq -e '.hint | length > 0' >/dev/null 2>&1 && echo yes || echo no)"
check "dns records list without token"  false "$(auth_request GET /dns/records | body_of | jq '.cf_configured' 2>/dev/null)"
check "dns zones need a token"          503 "$(auth_request GET /dns/zones | status_of)"
check "dns create validates type"       400 "$(auth_request POST /dns/records '{"type":"SRV","name":"x","content":"y"}' | status_of)"
check "dns create needs content"        400 "$(auth_request POST /dns/records '{"type":"A","name":"x"}' | status_of)"
check "dns create needs a token"        503 "$(auth_request POST /dns/records '{"type":"A","name":"x","content":"203.0.113.9"}' | status_of)"
check "dns delete validates id"         400 "$(auth_request DELETE /dns/records/not-an-id | status_of)"
check "dns update validates id"         400 "$(auth_request PUT /dns/records/not-an-id '{"content":"203.0.113.9"}' | status_of)"
check "viewer cannot list records"      403 "$(viewer_request GET /dns/records | status_of)"
check "viewer cannot create records"    403 "$(viewer_request POST /dns/records '{"type":"A","name":"x","content":"203.0.113.9"}' | status_of)"
check "viewer may read dns status"      200 "$(viewer_request GET /dns/status | status_of)"
check "record validator: bad ipv4"      no "$(_lib _dns_validate_record example.com A app 999.1.1.1 1 false "" "" >/dev/null 2>&1 && echo yes || echo no)"
check "record validator: cname payload" app.example.com "$(_lib _dns_validate_record example.com cname app target.example.net 1 true "" "" | jq -r '.name' 2>/dev/null)"
check "record validator: proxied ttl"   1 "$(_lib _dns_validate_record example.com A app 203.0.113.9 300 true "" "" | jq -r '.ttl' 2>/dev/null)"
check "record validator: apex"          example.com "$(_lib _dns_validate_record example.com TXT @ "v=spf1 -all" 3600 false "" "" | jq -r '.name' 2>/dev/null)"
check "record validator: mx priority"   10 "$(_lib _dns_validate_record example.com MX @ mail.example.com 1 false "" "" | jq -r '.priority' 2>/dev/null)"
check "stack activity idle"             idle "$(auth_request GET /stacks/demo/activity | body_of | jq -r '.phase' 2>/dev/null)"
check "stack activity unknown stack"    404 "$(auth_request GET /stacks/nope/activity | status_of)"
check "container name derives project"  demo-x-1 "$(_lib _compose_container_name "$WORK/Stacks/demo" x)"
mkdir -p "$WORK/.templates/demo-tpl" && printf '{"name":"demo-tpl","title":"Demo","category":"other","variables":[]}\n' > "$WORK/.templates/demo-tpl/template.json" && printf 'services:\n  demo:\n    image: alpine\n    environment:\n      - PW=${SECRETS_DEMO_TPL_PW}\n' > "$WORK/.templates/demo-tpl/docker-compose.yml"
check "template detail lists secrets"   DEMO_TPL_PW "$(auth_request GET /templates/demo-tpl | body_of | jq -r '.secrets[0].name' 2>/dev/null)"
check "template secret reported missing" false "$(auth_request GET /templates/demo-tpl | body_of | jq -r '.secrets[0].exists' 2>/dev/null)"
# bind mounts under App-Data exist before a deploy starts them: files as files, folders as folders
_PM="$WORK/pm-test"; mkdir -p "$_PM/ad/Old/state.json" "$_PM/ad/Keep/data.db"; printf 'x' > "$_PM/ad/Keep/data.db/inside"
printf 'services:\n  a:\n    image: alpine\n    volumes:\n      - ${APP_DATA_DIR:-./App-Data}/App/config.yml:/etc/app.yml:ro\n      - "${APP_DATA_DIR}/App/data:/data"\n      - ./App-Data/Other/db.sqlite:/db.sqlite\n      - ${APP_DATA_DIR:-./App-Data}/Old/state.json:/state.json\n      - ${APP_DATA_DIR:-./App-Data}/Keep/data.db:/data.db\n      - /var/run/docker.sock:/var/run/docker.sock\n      - ${APP_DATA_DIR:-./App-Data}/../escape.yml:/x.yml\n' > "$_PM/compose.yml"
_lib _template_prepare_mounts "$_PM/compose.yml" "$_PM/ad"
check "mounts: a file mount is a file"      yes "$([[ -f "$_PM/ad/App/config.yml" ]] && echo yes || echo no)"
check "mounts: a folder mount is a folder"  yes "$([[ -d "$_PM/ad/App/data" ]] && echo yes || echo no)"
check "mounts: ./App-Data form handled"     yes "$([[ -f "$_PM/ad/Other/db.sqlite" ]] && echo yes || echo no)"
check "mounts: docker's empty folder fixed" yes "$([[ -f "$_PM/ad/Old/state.json" ]] && echo yes || echo no)"
check "mounts: a full folder is kept"       yes "$([[ -f "$_PM/ad/Keep/data.db/inside" ]] && echo yes || echo no)"
check "mounts: nothing outside App-Data"    no "$([[ -e "$_PM/escape.yml" ]] && echo yes || echo no)"
rm -rf "$_PM"
# the catalogue: one jq run for every template.json, cached; a folder without one is still listed, a broken one is skipped
mkdir -p "$WORK/.templates/bare-tpl"; printf 'services: {}\n' > "$WORK/.templates/bare-tpl/docker-compose.yml"
_TN=$(find "$WORK/.templates" -mindepth 1 -maxdepth 1 -type d | wc -l)
check "templates: every folder listed"   "$_TN" "$(auth_request GET /templates | body_of | jq -r '.total' 2>/dev/null)"
check "templates: bare folder listed"    other "$(auth_request GET /templates | body_of | jq -r '.templates[] | select(.name == "bare-tpl") | .category' 2>/dev/null)"
check "templates: list is cached"        yes "$(auth_request GET /templates | grep -qi '^X-DCS-Cache:' && echo yes || echo no)"
# a cached answer carries the CORS headers of the request it is served to, not those of the request that filled the cache
# (a second dashboard origin used to get the first one's Access-Control-Allow-Origin, and a CORS error)
_corso() { printf 'GET /templates HTTP/1.1\r\nOrigin: %s\r\n\r\n' "$1" | env "${NOAUTH[@]}" "$API" --handle-request 2>/dev/null | tr -d '\r'; }
_corso http://localhost:3013 >/dev/null
_c2=$(_corso http://localhost:4000)
check "cache: served from the cache"                   hit "$(grep -i '^X-DCS-Cache:' <<< "$_c2" | awk '{print $2}')"
check "cache: …with the second origin's own CORS"      http://localhost:4000 "$(grep -i '^Access-Control-Allow-Origin:' <<< "$_c2" | awk '{print $2}')"
check "cache: …and only one CORS origin header"        1 "$(grep -ci '^Access-Control-Allow-Origin:' <<< "$_c2")"
check "cache: a foreign origin gets no CORS header"    0 "$(_corso http://192.0.2.9:3003 | grep -ci '^Access-Control-Allow-Origin:')"
check "cache: no Origin, no CORS header"               0 "$(printf 'GET /templates HTTP/1.1\r\n\r\n' | env "${NOAUTH[@]}" "$API" --handle-request 2>/dev/null | grep -ci '^Access-Control-Allow-Origin:')"
check "cache: the body is intact"                      yes "$(sed -n '/^$/,$p' <<< "$_c2" | sed '1d' | jq -e 'has("templates")' >/dev/null 2>&1 && echo yes || echo no)"

# the container list: an unhealthy container is not healthy (its text holds "healthy"), and a running one's uptime counts from its start
_ROWS='{"ID":"a1","Names":"web","State":"running","Status":"Up 3 hours (unhealthy)","RunningFor":"5 days ago","Image":"i","CreatedAt":"","Ports":"","Labels":""}
{"ID":"a2","Names":"db","State":"running","Status":"Up About an hour (healthy)","RunningFor":"2 weeks ago","Image":"i","CreatedAt":"","Ports":"","Labels":""}
{"ID":"a3","Names":"cache","State":"running","Status":"Up 12 minutes (health: starting)","RunningFor":"12 minutes ago","Image":"i","CreatedAt":"","Ports":"","Labels":""}
{"ID":"a4","Names":"old","State":"exited","Status":"Exited (0) 2 days ago","RunningFor":"3 days ago","Image":"i","CreatedAt":"","Ports":"","Labels":""}'
_CL=$(printf '%s\n' "$_ROWS" | _lib eval 'jq -s --argjson now 0 --argjson sab "{}" --slurpfile stats <(echo "{}") "$_CONTAINERS_JQ"' | jq -r '.[] | "\(.name) \(.health) \(.uptime_seconds)"' | tr '\n' ';')
check "containers: unhealthy is unhealthy, uptime from the start" "web unhealthy 10800;db healthy 3600;cache starting 720;old none 0;" "$_CL"
mkdir -p "$WORK/.templates/broken-tpl"; printf '{not json' > "$WORK/.templates/broken-tpl/template.json"; rm -f "$WORK/.data/cache"/templates*.http
check "templates: broken one skipped"    "$_TN" "$(auth_request GET /templates | body_of | jq -r '.total' 2>/dev/null)"
check "templates: others still there"    demo-tpl "$(auth_request GET /templates | body_of | jq -r '.templates[] | select(.name == "demo-tpl") | .name' 2>/dev/null)"
rm -rf "$WORK/.templates/bare-tpl" "$WORK/.templates/broken-tpl"; rm -f "$WORK/.data/cache"/templates*.http
check "image check exposes registry time" yes "$(auth_request GET /images/check-updates | body_of | jq -e 'has("registry_checked_at")' >/dev/null 2>&1 && echo yes || echo no)"
check "network flags: driver default"   yes "$(_lib _network_create_flags '{}' | grep -qx -- 'bridge' && echo yes || echo no)"
check "network flags: attachable+ipv6"  2 "$(_lib _network_create_flags '{"attachable":true,"ipv6":true}' | grep -c -- '--attachable\|--ipv6')"
check "network flags: label"            "team=ops" "$(_lib _network_create_flags '{"labels":{"team":"ops"}}' | grep -A1 -x -- '--label' | tail -1)"
check "network flags reject bad subnet" 1 "$(_lib _network_create_flags '{"subnet":"nope"}' >/dev/null; echo $?)"
check "network flags reject bad label"  1 "$(_lib _network_create_flags '{"labels":{"bad key":"x"}}' >/dev/null; echo $?)"
check "network flags: gateway needs subnet" 1 "$(_lib _network_create_flags '{"gateway":"10.0.0.1"}' >/dev/null; echo $?)"
check "network recreate built-in"       403 "$(auth_request POST /networks/bridge/recreate '{}' | status_of)"
check "network recreate unknown"        404 "$(auth_request POST /networks/nope-zz/recreate '{}' | status_of)"
check "network recreate viewer denied"  403 "$(viewer_request POST /networks/nope-zz/recreate '{}' | status_of)"
check "network create rejects bad range" 400 "$(auth_request POST /networks '{"name":"zz-net","subnet":"10.9.0.0/24","ip_range":"bad"}' | status_of)"
_ENVC=$(printf 'services:\n  x:\n    image: a\n    environment:\n      - A=1\n      - "B=2"\n  y:\n    image: b\n')
check "env edit: replace list entry"     1 "$(printf '%s\n' "$_ENVC" | _lib _compose_env_edit x A 9 set | grep -c '^      - A=9$')"
check "env edit: append quoted"          1 "$(printf '%s\n' "$_ENVC" | _lib _compose_env_edit x C 'v #x' set | grep -c '^      - "C=v #x"$')"
check "env edit: other service untouched" 0 "$(printf '%s\n' "$_ENVC" | _lib _compose_env_edit x C 3 set | sed -n '/^  y:/,$p' | grep -c 'C=3')"
check "env edit: unset"                  0 "$(printf '%s\n' "$_ENVC" | _lib _compose_env_edit x A '' unset | grep -c 'A=1')"
check "env edit: map style"              1 "$(printf 'services:\n  x:\n    environment:\n      A: 1\n' | _lib _compose_env_edit x A hello set | grep -c '^      A: hello$')"
check "env edit: creates the block"      1 "$(printf 'services:\n  x:\n    image: a\n  y:\n    image: b\n' | _lib _compose_env_edit x A 1 set | sed -n '/^  x:/,/^  y:/p' | grep -c '^      - A=1$')"
check "env get: raw reference"           '${FOO:-1}' "$(printf 'services:\n  x:\n    environment:\n      - A=${FOO:-1}\n' | _lib _compose_env_get x A)"
_ENVF=$(mktemp); printf 'FOO=1\n' > "$_ENVF"; _lib _envfile_set "$_ENVF" FOO 'a b'; _lib _envfile_set "$_ENVF" NEW 'x#y'
check "envfile set: replace (quoted)"    'FOO="a b"' "$(grep '^FOO=' "$_ENVF")"
check "envfile set: append quoted"       'NEW="x#y"' "$(grep '^NEW=' "$_ENVF")"; rm -f "$_ENVF"
check "container env: unknown container" 404 "$(auth_request POST /containers/nope-zz/env '{"set":{"A":"1"}}' | status_of)"
check "container env: viewer denied"     403 "$(viewer_request POST /containers/nope-zz/env '{"set":{"A":"1"}}' | status_of)"

echo "Card Studio (plugin cards written through the API) and Discord"
_CARD='{"meta":{"title":"Demo","icon":"Clock","defaultW":6,"defaultH":4},"html":"<b>hi</b>"}'
check "card save: viewer denied"        403 "$(viewer_request POST /plugins/zz-cards/cards/demo "$_CARD" | status_of)"
check "card save: plugin name checked"  400 "$(auth_request POST '/plugins/..x/cards/demo' "$_CARD" | status_of)"
check "card save: html required"        400 "$(auth_request POST /plugins/zz-cards/cards/demo '{"meta":{"title":"Demo"}}' | status_of)"
check "card save: creates plugin + card" 200 "$(auth_request POST /plugins/zz-cards/cards/demo "$_CARD" | status_of)"
check "card save: files on disk"        yes "$([[ -s "$WORK/.plugins/zz-cards/cards/demo/index.html" && -s "$WORK/.plugins/zz-cards/cards/demo/card.json" && -s "$WORK/.plugins/zz-cards/plugin.json" ]] && echo yes || echo no)"
check "card source: html round-trips"   '<b>hi</b>' "$(auth_request GET /plugins/zz-cards/cards/demo/source | body_of | jq -r '.html' 2>/dev/null)"
check "card source: viewer denied"      403 "$(viewer_request GET /plugins/zz-cards/cards/demo/source | status_of)"
check "card list: shows the new card"   Demo "$(auth_request GET /plugins/cards | body_of | jq -r '.cards[] | select(.plugin == "zz-cards" and .name == "demo") | .title' 2>/dev/null)"
check "card render"                     200 "$(auth_request GET /plugins/zz-cards/cards/demo | status_of)"
check "card delete: viewer denied"      403 "$(viewer_request DELETE /plugins/zz-cards/cards/demo | status_of)"
check "card delete"                     200 "$(auth_request DELETE /plugins/zz-cards/cards/demo | status_of)"
check "card delete: source gone"        404 "$(auth_request GET /plugins/zz-cards/cards/demo/source | status_of)"
check "system reports virtualization" true "$(auth_request GET /system | body_of | jq -r 'has("virtualization") and (.guest_agent | type == "object")' 2>/dev/null)"
check "notification test needs a channel" 400 "$(auth_request POST /notifications/test '{}' | status_of)"
_lib _envfile_set "$WORK/.env" DISCORD_WEBHOOK_URL "https://example.com/hook"
check "discord webhook: foreign URL refused" 1 "$(_lib _discord_webhook >/dev/null; echo $?)"
_lib _envfile_set "$WORK/.env" DISCORD_WEBHOOK_URL "https://discord.com/api/webhooks/1/abc"
check "discord webhook: discord URL accepted" "https://discord.com/api/webhooks/1/abc" "$(_lib _discord_webhook)"
check "config reports discord configured" true "$(auth_request GET /config | body_of | jq -r '.discord_configured' 2>/dev/null)"
check "config hides the webhook"        yes "$(auth_request GET /config | body_of | grep -q 'webhooks/1/abc' && echo no || echo yes)"
sed -i '/^DISCORD_WEBHOOK_URL=/d' "$WORK/.env"

echo ".env quoting (scripts source it, the API reads it as data)"
auth_request POST /config '{"SERVER_NAME":"Howson Server"}' >/dev/null
check "config write quotes a spaced value" 'SERVER_NAME="Howson Server"' "$(grep '^SERVER_NAME=' "$WORK/.env")"
check "env file still sources cleanly"   0 "$(bash -c "set -a; source '$WORK/.env'" >/dev/null 2>&1; echo $?)"
check "quoted value reads back as data"  "Howson Server" "$(auth_request GET /config | body_of | jq -r '.server_name' 2>/dev/null)"
_ENVQ=$(mktemp); printf 'A=x y\nB="kept"\nE=a b # note\n' > "$_ENVQ"; _lib envfile_repair "$_ENVQ" 2>/dev/null
check "envfile repair quotes the bad line" 'A="x y"' "$(grep '^A=' "$_ENVQ")"
check "envfile repair keeps good lines"    'B="kept"' "$(grep '^B=' "$_ENVQ")"
check "envfile repair keeps a comment"     'E="a b" # note' "$(grep '^E=' "$_ENVQ")"
check "envfile repair keeps a backup"      yes "$([[ -f "$_ENVQ.bak-repair" ]] && echo yes || echo no)"
_lib _envfile_set "$_ENVQ" C 'back\slash $x' bash
check "envfile set escapes for bash"       'C="back\\slash \$x"' "$(grep '^C=' "$_ENVQ")"
check "loader unescapes what bash would"   'back\slash $x' "$(_lib eval "_api_load_env_file '$_ENVQ'; printf '%s' \"\$C\"")"
_lib _envfile_set "$_ENVQ" D 'ref ${OTHER}' compose
check "envfile set keeps compose refs"     'D="ref ${OTHER}"' "$(grep '^D=' "$_ENVQ")"
rm -f "$_ENVQ" "$_ENVQ.bak-repair"

echo "State files: empty or corrupt files heal themselves"
mkdir -p "$WORK/.data/schedules"; : > "$WORK/.data/schedules/schedules.json"
check "empty schedules file answers cleanly" 0 "$(auth_request GET /schedules | body_of | jq -r '.count' 2>/dev/null)"
check "empty schedules file was repaired"    '[]' "$(tr -d '\n' < "$WORK/.data/schedules/schedules.json")"
check "corrupt copy kept for inspection"     yes "$(ls "$WORK/.data/schedules/"schedules.json.corrupt-* >/dev/null 2>&1 && echo yes || echo no)"
printf '{"rules": ' > "$WORK/.api-auth/notifications.json"
check "corrupt notifications file heals"     '[]' "$(auth_request GET /notifications/rules | body_of | jq -c '.rules' 2>/dev/null)"
check "response guard turns bad JSON into 500" 500 "$(_lib _api_response 200 '{"schedules": , "count": }' | status_of)"
check "response guard leaves good JSON alone"  200 "$(_lib _api_response 200 '{"ok": true}' | status_of)"

echo "compose.sh wrapper (secrets reach docker compose by hand)"
check "wrapper lists stacks"             demo "$(cd "$WORK" && ./compose.sh --list | head -1)"
check "wrapper rejects unknown stack"    2 "$(cd "$WORK" && ./compose.sh nope-zz ps >/dev/null 2>&1; echo $?)"
mkdir -p "$WORK/Stacks/zz-wrap"; printf 'services:\n  x:\n    image: alpine\n    environment:\n      - A=${SECRETS_WRAP_DEMO}\n' > "$WORK/Stacks/zz-wrap/docker-compose.yml"
auth_request POST /secrets '{"key":"WRAP_DEMO","value":"wrap-value"}' >/dev/null
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    check "wrapper injects the stored secret" 1 "$(cd "$WORK" && ./compose.sh zz-wrap config 2>/dev/null | grep -c 'A: wrap-value')"
    check "bare compose would leave it blank" 0 "$(cd "$WORK/Stacks/zz-wrap" && docker compose -f docker-compose.yml config 2>/dev/null | grep -c 'wrap-value')"
else
    echo "  skip (docker compose plugin not available)"
fi

echo "Traefik: ACME challenge follows the token; certificate view"
_TY=$(mktemp); cp "$ROOT/.templates/traefik/config/traefik.yml" "$_TY"
_lib _traefik_pick_challenge "$_TY" http
check "no token: http challenge active"   1 "$(grep -c '^      httpChallenge:' "$_TY")"
check "no token: dns challenge commented" 1 "$(grep -c '^      # dnsChallenge:' "$_TY")"
_lib _traefik_pick_challenge "$_TY" dns
check "token: dns challenge active"       1 "$(grep -c '^      dnsChallenge:' "$_TY")"
check "token: http challenge commented"   1 "$(grep -c '^      # httpChallenge:' "$_TY")"
rm -f "$_TY"
check "certificates view without traefik" none "$(auth_request GET /routes/certificates | body_of | jq -r '.challenge' 2>/dev/null)"

echo "Template config_path (Authelia uses a nested one)"
check "nested config_path accepted"      0 "$(_lib _api_config_path_ok 'Authelia/config'; echo $?)"
check "plain config_path accepted"       0 "$(_lib _api_config_path_ok 'Traefik'; echo $?)"
check "traversal refused"                1 "$(_lib _api_config_path_ok 'a/../b'; echo $?)"
check "absolute path refused"            1 "$(_lib _api_config_path_ok '/etc'; echo $?)"
check "empty segment refused"            1 "$(_lib _api_config_path_ok 'a//b'; echo $?)"
check "dot segment refused"              1 "$(_lib _api_config_path_ok './x'; echo $?)"

echo "Sablier detection, the Traefik chain helper and the DDNS guard"
mkdir -p "$WORK/Stacks/zz-proxy/App-Data/Traefik/custom_routes/core-infrastructure" "$WORK/Stacks/zz-proxy/App-Data/Traefik/custom_routes/demo"
printf 'services:\n  traefik:\n    image: traefik:v3\n    container_name: Traefik\n' > "$WORK/Stacks/zz-proxy/docker-compose.yml"
printf 'http:\n  middlewares:\n    traefik-chain:\n      chain:\n        middlewares:\n          - "https-redirect"\n    other:\n      compress: {}\n' > "$WORK/Stacks/zz-proxy/App-Data/Traefik/custom_routes/core-infrastructure/traefik.yml"
printf 'http:\n  routers:\n    tools-router:\n      rule: "Host(`tools.example.test`)"\n      service: "tools"\n      middlewares:\n        - "ittools-sablier"\n  services:\n    tools:\n      loadBalancer:\n        servers:\n          - url: "http://IT-Tools:80"\n  middlewares:\n    ittools-sablier:\n      plugin:\n        sablier:\n          names: IT-Tools\n          sessionDuration: 30m\n    multi-sablier:\n      plugin:\n        sablier:\n          names:\n            - "Ollama"\n            - Plex\n' > "$WORK/Stacks/zz-proxy/App-Data/Traefik/custom_routes/demo/tools.yml"
grep -q "^DOCKER_STACKS=" "$WORK/.env" && sed -i 's/^DOCKER_STACKS=.*/DOCKER_STACKS="demo zz-proxy"/' "$WORK/.env" || printf 'DOCKER_STACKS="demo zz-proxy"\n' >> "$WORK/.env"
check "sablier names parsed (scalar + list)" "IT-Tools Ollama Plex" "$(_lib _sablier_names | tr '\n' ' ' | sed 's/ $//')"
check "sablier names as json"               true "$(_lib _sablier_names_json | jq -r '.["IT-Tools"]')"
_lib _traefik_chain_set crowdsec-bouncer add; _lib _traefik_chain_set crowdsec-bouncer add
check "chain: bouncer added once"           1 "$(grep -c 'crowdsec-bouncer' "$WORK/Stacks/zz-proxy/App-Data/Traefik/custom_routes/core-infrastructure/traefik.yml")"
check "chain: existing entry kept"          1 "$(grep -c '"https-redirect"' "$WORK/Stacks/zz-proxy/App-Data/Traefik/custom_routes/core-infrastructure/traefik.yml")"
_lib _traefik_chain_set crowdsec-bouncer remove
check "chain: bouncer removed"              0 "$(grep -c 'crowdsec-bouncer' "$WORK/Stacks/zz-proxy/App-Data/Traefik/custom_routes/core-infrastructure/traefik.yml")"
check "health reports sleeping"             true "$(auth_request GET /health | body_of | jq -r '.summary | has("sleeping")' 2>/dev/null)"
check "sablier toggle: unknown container"   404 "$(auth_request POST /containers/nope-zz/sablier '{"enabled":true}' | status_of)"
check "sablier toggle: viewer denied"       403 "$(viewer_request POST /containers/nope-zz/sablier '{"enabled":true}' | status_of)"
check "sablier settings: unknown container" 404 "$(auth_request GET /containers/nope-zz/sablier | status_of)"
# the block that names a container, wherever a deploy put it; its settings; removing it leaves the rest
_SBF="$WORK/Stacks/zz-proxy/App-Data/Traefik/custom_routes/demo/tools.yml"; cp "$_SBF" "$_SBF.orig"   # later checks expect the fixture whole
check "sablier block: scalar name found"    ittools-sablier "$(_lib _sablier_blocks_for IT-Tools | cut -f2)"
check "sablier block: list name found"      multi-sablier "$(_lib _sablier_blocks_for Plex | cut -f2)"
check "sablier block: group size counted"   2 "$(_lib _sablier_blocks_for Plex | cut -f3)"
check "sablier block: single block counted" 1 "$(_lib _sablier_blocks_for IT-Tools | cut -f3)"
check "sablier block: file named"           "$_SBF" "$(_lib _sablier_blocks_for IT-Tools | cut -f1)"
check "sablier block: settings read"        "30m" "$(_lib _sablier_block_read "$_SBF" ittools-sablier | cut -d $'' -f1)"
_lib _sablier_block_remove "$_SBF" ittools-sablier
check "sablier block: removed from names"   "Ollama Plex" "$(_lib _sablier_names | tr '\n' ' ' | sed 's/ $//')"
check "sablier block: router reference gone" 0 "$(grep -c 'ittools-sablier' "$_SBF")"
check "sablier block: the other one stays"  1 "$(grep -c 'multi-sablier:' "$_SBF")"
check "sablier block: file still yaml"      ok "$(python3 -c "import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); print('ok' if 'multi-sablier' in d['http']['middlewares'] and 'ittools-sablier' not in d['http']['middlewares'] else 'bad')" "$_SBF" 2>/dev/null || echo ok)"
mv -f "$_SBF.orig" "$_SBF"
check "ddns guard is a no-op when off"      0 "$(_lib _ddns_ensure_running; echo $?)"
# The helper edits the traefik.yml of whichever stack DCS treats as the proxy stack
_TAD=$(_lib _traefik_stack_appdata | cut -f2); mkdir -p "$_TAD/Traefik"
printf 'entryPoints:\n  web:\n    address: ":80"\nexperimental:\n  plugins:\n    geoblock:\n      moduleName: "github.com/PascalMinder/geoblock"\n      version: "v0.3.3"\n' > "$_TAD/Traefik/traefik.yml"
check "proxy stack resolved"               yes "$([[ -n "$_TAD" ]] && echo yes || echo no)"
check "plugin added when missing"          1 "$(_lib _traefik_ensure_plugin sablier github.com/acouvreur/sablier v1.7.0-beta.15; echo $?)"
check "plugin declared under plugins:"     1 "$(grep -c 'github.com/acouvreur/sablier' "$_TAD/Traefik/traefik.yml")"
check "plugin not added twice"             0 "$(_lib _traefik_ensure_plugin sablier github.com/acouvreur/sablier v1.7.0-beta.15; echo $?)"
check "plugin yaml still parses"           ok "$(python3 -c "import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); print('ok' if 'sablier' in d['experimental']['plugins'] else 'bad')" "$_TAD/Traefik/traefik.yml" 2>/dev/null || echo ok)"
sed -i 's/^DOCKER_STACKS=.*/DOCKER_STACKS="demo"/' "$WORK/.env"

echo "Self-update: release channels, user files kept, rollback, restart method"
UPD_ORIGIN="$WORK/upd-origin.git"; UPD_SRC="$WORK/upd-src"; UPD="$WORK/upd"
git init -q --bare "$UPD_ORIGIN" && git -C "$UPD_ORIGIN" symbolic-ref HEAD refs/heads/main
_gs() { git -C "$UPD_SRC" -c user.name=smoke -c user.email=smoke@example.com "$@"; }
_gu() { git -C "$UPD" -c user.name=smoke -c user.email=smoke@example.com "$@"; }
git init -q -b main "$UPD_SRC"
mkdir -p "$UPD_SRC/.scripts" "$UPD_SRC/Stacks/demo" "$UPD_SRC/.plugins/x"
printf '1.0.0\n' > "$UPD_SRC/VERSION"
printf '# Changelog\n\n## [1.0.0] - 2026-01-01\n\n- First\n' > "$UPD_SRC/CHANGELOG.md"
printf 'echo one\n' > "$UPD_SRC/.scripts/tool.sh"
printf 'services:\n  demo:\n    image: alpine:3\n' > "$UPD_SRC/Stacks/demo/docker-compose.yml"
printf '{"name":"x"}\n' > "$UPD_SRC/.plugins/x/plugin.json"
printf 'KEY_A=1\n' > "$UPD_SRC/.env.example"
_gs add -A >/dev/null && _gs commit -q -m 'release 1.0.0' && _gs tag v1.0.0 && _gs remote add origin "$UPD_ORIGIN" && _gs push -q origin main --tags
git clone -q "$UPD_ORIGIN" "$UPD"
mkdir -p "$UPD/.scripts" "$UPD/.lib" "$UPD/.config" "$UPD/.data" "$UPD/logs" "$UPD/.api-auth"
cp "$API" "$UPD/.scripts/" && cp -r "$ROOT/.lib/." "$UPD/.lib/" && cp -r "$ROOT/.config/." "$UPD/.config/"
cp "$WORK/.env" "$UPD/.env" && printf 'KEY_A=1\n' >> "$UPD/.env" && cp -r "$WORK/.api-auth/." "$UPD/.api-auth/"
UPD_API="$UPD/.scripts/api-server.sh"
# upstream: a tagged 1.1.0 (framework file, template compose, new setting) and an untagged commit after it
printf '1.1.0\n' > "$UPD_SRC/VERSION"
printf '# Changelog\n\n## [1.1.0] - 2026-02-01\n\n- New thing\n\n## [1.0.0] - 2026-01-01\n\n- First\n' > "$UPD_SRC/CHANGELOG.md"
printf 'echo two\n' > "$UPD_SRC/.scripts/tool.sh"
printf 'services:\n  demo:\n    image: alpine:3.20\n' > "$UPD_SRC/Stacks/demo/docker-compose.yml"
printf 'KEY_A=1\nKEY_B=2\n' > "$UPD_SRC/.env.example"
printf '{"name":"x","v":2}\n' > "$UPD_SRC/.plugins/x/plugin.json"
_gs add -A >/dev/null && _gs commit -q -m 'release 1.1.0' && _gs tag v1.1.0
printf 'wip\n' > "$UPD_SRC/README.md" && _gs add -A >/dev/null && _gs commit -q -m 'wip after release' && _gs push -q origin main --tags
# the install: a user-edited stack file, a deleted plugin file, an edited framework file
printf 'services:\n  demo:\n    image: alpine:3\n    # mine\n' > "$UPD/Stacks/demo/docker-compose.yml"
rm -f "$UPD/.plugins/x/plugin.json"
printf 'echo local\n' > "$UPD/.scripts/tool.sh"
# requests go through the install's own API copy (admin token, real router)
_upd() { local m="$1" p="$2" b="${3:-}"; printf '%s %s HTTP/1.1\r\nAuthorization: Bearer %s\r\nContent-Length: %d\r\n\r\n%s' "$m" "$p" "$TOKEN" "${#b}" "$b" | env DOCKER_COMPOSE_CMD="${DOCKER_COMPOSE_CMD:-docker compose}" "${AUTH[@]}" "$UPD_API" --handle-request 2>/dev/null; }
_upd_channel() { sed -i '/^UPDATE_CHANNEL=/d' "$UPD/.env"; printf 'UPDATE_CHANNEL=%s\n' "$1" >> "$UPD/.env"; }
CHK=$(_upd GET /system/update/check | body_of)
check "check: release available"        true "$(printf '%s' "$CHK" | jq -r '.available')"
check "check: state behind"             behind "$(printf '%s' "$CHK" | jq -r '.state')"
check "check: newest tag chosen"        v1.1.0 "$(printf '%s' "$CHK" | jq -r '.latest_name')"
check "check: target version"           1.1.0 "$(printf '%s' "$CHK" | jq -r '.latest_version')"
check "check: only the release counts"  1 "$(printf '%s' "$CHK" | jq -r '.commits_behind')"
check "check: release notes"            yes "$(printf '%s' "$CHK" | jq -r '.release_notes' | grep -q 'New thing' && echo yes || echo no)"
check "check: notes stop at current"    no "$(printf '%s' "$CHK" | jq -r '.release_notes' | grep -q 'First' && echo yes || echo no)"
check "check: user edits will be kept"  '.plugins/x/plugin.json Stacks/demo/docker-compose.yml' "$(printf '%s' "$CHK" | jq -r '.local_changes.kept | join(" ")')"
check "check: framework edit conflicts" '.scripts/tool.sh' "$(printf '%s' "$CHK" | jq -r '.local_changes.conflicts | join(" ")')"
check "check: deleted plugin listed"    yes "$(printf '%s' "$CHK" | jq -r '.local_changes.user[]' | grep -q 'plugins/x/plugin.json' && echo yes || echo no)"
check "check: restart method (no pid)"  manual "$(printf '%s' "$CHK" | jq -r '.restart_method')"
check "apply: needs confirm"            400 "$(_upd POST /system/update/apply '{}' | status_of)"
check "apply: refuses framework edits"  409 "$(_upd POST /system/update/apply '{"confirm":true}' | status_of)"
check "apply: nothing moved on refusal" 1.0.0 "$(tr -d '[:space:]' < "$UPD/VERSION")"
APPLY=$(_upd POST /system/update/apply '{"confirm":true,"replace_local":true}')
check "apply: succeeds with replace"    200 "$(printf '%s' "$APPLY" | status_of)"
check "apply: new version"              1.1.0 "$(printf '%s' "$APPLY" | body_of | jq -r '.new_version')"
check "apply: fleet flag, no members"   false "$(_upd POST /system/update/apply '{"confirm":true,"fleet":true}' | body_of | jq -r '.fleet_update_queued // false')"
check "apply: no round queued then"     no "$([[ -f "$UPD/.data/fleet-update-pending" ]] && echo yes || echo no)"
check "apply: VERSION on disk"          1.1.0 "$(tr -d '[:space:]' < "$UPD/VERSION")"
check "apply: HEAD is the tag"          "$(git -C "$UPD_SRC" rev-parse v1.1.0)" "$(git -C "$UPD" rev-parse HEAD)"
check "apply: user compose kept"        yes "$(grep -q '# mine' "$UPD/Stacks/demo/docker-compose.yml" && echo yes || echo no)"
check "apply: deleted plugin stays gone" no "$([[ -e "$UPD/.plugins/x/plugin.json" ]] && echo yes || echo no)"
check "apply: framework file replaced"  'echo two' "$(cat "$UPD/.scripts/tool.sh")"
check "apply: replaced copy kept"       'echo local' "$(cat "$(printf '%s' "$APPLY" | body_of | jq -r '.backup_dir')/.scripts/tool.sh" 2>/dev/null)"
check "apply: kept list (deleted too)"  '.plugins/x/plugin.json Stacks/demo/docker-compose.yml' "$(printf '%s' "$APPLY" | body_of | jq -r '.kept_local | join(" ")')"
check "apply: replaced list"            '.scripts/tool.sh' "$(printf '%s' "$APPLY" | body_of | jq -r '.replaced_local | join(" ")')"
check "apply: new setting reported"     KEY_B "$(printf '%s' "$APPLY" | body_of | jq -r '.new_settings | join(" ")')"
check "apply: no stash left behind"     0 "$(_gu stash list | wc -l)"
check "apply: backup tag created"       1 "$(_gu tag -l 'dcs-backup-*' | wc -l)"
BACKUP_TAG=$(printf '%s' "$APPLY" | body_of | jq -r '.backup_tag')
check "check: current after update"     current "$(_upd GET /system/update/check | body_of | jq -r '.state')"
check "apply: already up to date"       false "$(_upd POST /system/update/apply '{"confirm":true}' | body_of | jq -r '.updated')"
_upd_channel main
CHK_MAIN=$(_upd GET /system/update/check | body_of)
check "main channel: sees the wip commit" true "$(printf '%s' "$CHK_MAIN" | jq -r '.available')"
check "main channel: name"              main "$(printf '%s' "$CHK_MAIN" | jq -r '.latest_name')"
check "main channel: applies"           true "$(_upd POST /system/update/apply '{"confirm":true}' | body_of | jq -r '.updated')"
check "main channel: at origin/main"    "$(git -C "$UPD_SRC" rev-parse main)" "$(git -C "$UPD" rev-parse HEAD)"
check "main channel: user compose kept" yes "$(grep -q '# mine' "$UPD/Stacks/demo/docker-compose.yml" && echo yes || echo no)"
_upd_channel stable
check "rollback: bad tag rejected"      400 "$(_upd POST /system/update/rollback '{"backup_tag":"v1.0.0"}' | status_of)"
RB=$(_upd POST /system/update/rollback "{\"backup_tag\":\"$BACKUP_TAG\"}")
check "rollback: succeeds"              200 "$(printf '%s' "$RB" | status_of)"
check "rollback: restored version"      1.0.0 "$(printf '%s' "$RB" | body_of | jq -r '.restored_version')"
check "rollback: user compose kept"     yes "$(grep -q '# mine' "$UPD/Stacks/demo/docker-compose.yml" && echo yes || echo no)"
check "rollback: framework file back"   'echo one' "$(cat "$UPD/.scripts/tool.sh")"
# setup.sh runs chmod +x over every script, so a script git tracks as 644 reads as edited although only the
# executable bit differs. That is not a local edit and must not hold an update back; a real edit still does
chmod +x "$UPD/.scripts/tool.sh"
check "exec bit: git lists the file"       yes "$(_gu status --porcelain --untracked-files=no | grep -q '\.scripts/tool\.sh' && echo yes || echo no)"
CHK_X=$(_upd GET /system/update/check | body_of)
check "exec bit: no framework edit shown"  '' "$(printf '%s' "$CHK_X" | jq -r '.local_changes.framework | join(" ")')"
check "exec bit: no conflict with update"  '' "$(printf '%s' "$CHK_X" | jq -r '.local_changes.conflicts | join(" ")')"
APPLY_X=$(_upd POST /system/update/apply '{"confirm":true}')
check "exec bit: apply goes through"       200 "$(printf '%s' "$APPLY_X" | status_of)"
check "exec bit: file updated"             'echo two' "$(cat "$UPD/.scripts/tool.sh")"
check "exec bit: still executable"         yes "$([[ -x "$UPD/.scripts/tool.sh" ]] && echo yes || echo no)"
check "exec bit: nothing reported replaced" '' "$(printf '%s' "$APPLY_X" | body_of | jq -r '.replaced_local | join(" ")')"
printf '1.2.0\n' > "$UPD_SRC/VERSION"; printf 'echo three\n' > "$UPD_SRC/.scripts/tool.sh"
_gs add -A >/dev/null && _gs commit -q -m 'release 1.2.0' && _gs tag v1.2.0 && _gs push -q origin main --tags
printf 'echo mine\n' > "$UPD/.scripts/tool.sh"     # a real edit on top of the executable bit
check "exec bit + edit: still a conflict"  '.scripts/tool.sh' "$(_upd GET /system/update/check | body_of | jq -r '.local_changes.conflicts | join(" ")')"
check "exec bit + edit: apply refused"     409 "$(_upd POST /system/update/apply '{"confirm":true}' | status_of)"
check "exec bit + edit: nothing moved"     1.1.0 "$(tr -d '[:space:]' < "$UPD/VERSION")"
_gu checkout -q -- .scripts/tool.sh; chmod +x "$UPD/.scripts/tool.sh"   # the edit is gone, the bit stays
check "exec bit: the next release applies" 200 "$(_upd POST /system/update/apply '{"confirm":true}' | status_of)"
check "exec bit: next release content"     'echo three' "$(cat "$UPD/.scripts/tool.sh")"
check "exec bit: executable after that"    yes "$([[ -x "$UPD/.scripts/tool.sh" ]] && echo yes || echo no)"
# SELinux: git writes api-server.sh anew and the file takes the directory's label (user_home_t), which systemd cannot
# start a service from (203/EXEC). Every code switch, the Update button included, has to put bin_t back
mkdir -p "$WORK/fakebin-se"
printf '#!/bin/bash\necho Enforcing\n' > "$WORK/fakebin-se/getenforce"
printf '#!/bin/bash\nif [[ "$1" == "-c" && "$2" == "%%C" ]]; then\n  [[ -f "$(dirname "$0")/labelled.$(basename "$3")" ]] && echo system_u:object_r:bin_t:s0 || echo system_u:object_r:user_home_t:s0\n  exit 0\nfi\nexec %s "$@"\n' "$(command -v stat)" > "$WORK/fakebin-se/stat"
printf '#!/bin/bash\nexit 0\n' > "$WORK/fakebin-se/restorecon"
printf '#!/bin/bash\nshift 2\nfor f in "$@"; do printf "%%s\\n" "$f" >> "$(dirname "$0")/chcon.log"; : > "$(dirname "$0")/labelled.$(basename "$f")"; done\n' > "$WORK/fakebin-se/chcon"
chmod +x "$WORK/fakebin-se/"*
printf '1.3.0\n' > "$UPD_SRC/VERSION"; printf 'echo four\n' > "$UPD_SRC/.scripts/tool.sh"
_gs add -A >/dev/null && _gs commit -q -m 'release 1.3.0' && _gs tag v1.3.0 && _gs push -q origin main --tags
RL=$(PATH="$WORK/fakebin-se:$PATH" _upd POST /system/update/apply '{"confirm":true}')
check "selinux: the update goes through"    200 "$(printf '%s' "$RL" | status_of)"
check "selinux: api-server.sh labelled bin_t" "$UPD/.scripts/api-server.sh" "$(grep -m1 'api-server\.sh' "$WORK/fakebin-se/chcon.log" 2>/dev/null)"
RLB=$(printf '%s' "$RL" | body_of | jq -r '.backup_tag')
rm -f "$WORK/fakebin-se/chcon.log" "$WORK/fakebin-se/labelled."*
check "selinux: rollback goes through"      200 "$(PATH="$WORK/fakebin-se:$PATH" _upd POST /system/update/rollback "{\"backup_tag\":\"$RLB\"}" | status_of)"
check "selinux: labelled again after it"    "$UPD/.scripts/api-server.sh" "$(grep -m1 'api-server\.sh' "$WORK/fakebin-se/chcon.log" 2>/dev/null)"
check "user path: Stacks"               0 "$(_lib _api_git_is_user_path Stacks/demo/.env; echo $?)"
check "user path: scripts are not"      1 "$(_lib _api_git_is_user_path .scripts/api-server.sh; echo $?)"
sleep 300 & _UPD_SLEEP=$!
printf '%s\n' "$_UPD_SLEEP" > "$WORK/.data/api-server.pid"
check "restart method: foreign process" "manual $_UPD_SLEEP" "$(_lib _api_restart_method)"
printf 'reexec\n' > "$WORK/.data/api-server.caps"
check "restart method: 3.3 marker, not a listener" "manual $_UPD_SLEEP" "$(_lib _api_restart_method)"
printf 'reexec-usr1\n' > "$WORK/.data/api-server.caps"
check "restart method: new listener (USR1)" "reexec $_UPD_SLEEP USR1" "$(_lib _api_restart_method)"
kill "$_UPD_SLEEP" 2>/dev/null; wait "$_UPD_SLEEP" 2>/dev/null || true
rm -f "$WORK/.data/api-server.pid" "$WORK/.data/api-server.caps"

echo "Restart in place: a request's helpers must not keep the port, and the port comes back"
# a handler keeps the connection and nothing else: ncat hands every handler its listening socket
_fdt() { exec 7>/dev/null 8</dev/null; _api_close_inherited_fds; local r="" n; for n in 0 1 2 7 8; do [[ -e /proc/$BASHPID/fd/$n ]] && r+="$n:open " || r+="$n:closed "; done; printf '%s' "${r% }"; }
check "handler: inherited descriptors closed" "0:open 1:open 2:open 7:closed 8:closed" "$(_lib _fdt)"
_free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
_alive() { [[ -d "/proc/$1" && "$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null)" != Z ]]; }   # a zombie is not running
# a helper that inherited the listening socket (what older versions left behind: the DDNS loop's 300 s sleep)
RP=$(_free_port)
python3 - "$RP" <<'PY' &
import os, socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(5); os.set_inheritable(s.fileno(), True)
os.execvp("sleep", ["sleep", "300"])
PY
RP_PID=$!
sleep 0.7
check "leaked helper: holds the port"       "$RP_PID" "$(_lib _api_port_listeners "$RP")"
check "leaked helper: the port is reclaimed" 0 "$(_lib _api_reclaim_port "$RP" >/dev/null; echo $?)"
for _i in $(seq 1 10); do _alive "$RP_PID" || break; sleep 0.3; done
check "leaked helper: ended"                no "$(_alive "$RP_PID" && echo yes || echo no)"
kill -KILL "$RP_PID" 2>/dev/null; wait "$RP_PID" 2>/dev/null
check "leaked helper: the port is free"     "" "$(_lib _api_port_listeners "$RP")"
# another program on the port is not ours to end
RP2=$(_free_port)
python3 -c 'import socket, sys, time; s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(5); time.sleep(300)' "$RP2" &
RP2_PID=$!
sleep 0.7
check "another program: left alone"         1 "$(_lib _api_reclaim_port "$RP2" >/dev/null; echo $?)"
check "another program: still running"      yes "$(_alive "$RP2_PID" && echo yes || echo no)"
kill "$RP2_PID" 2>/dev/null; wait "$RP2_PID" 2>/dev/null
# A copy of the API as a real listener on a loopback port: _rip_install DIR PORT
_rip_install() {
    local d="$1" port="$2"
    mkdir -p "$d/.scripts" "$d/.lib" "$d/.config" "$d/.data" "$d/logs" "$d/.api-auth" "$d/Stacks"
    command cp "$API" "$d/.scripts/"; command cp "$ROOT/compose.sh" "$ROOT/VERSION" "$d/"
    command cp -r "$ROOT/.lib/." "$d/.lib/"; command cp -r "$ROOT/.config/." "$d/.config/"
    grep -vE '^(API_BIND|API_AUTH_ENABLED|API_INSECURE_NO_AUTH|API_TRUSTED_PROXIES|API_IP_WHITELIST|API_PORT|DDNS_ENABLED|CF_DNS_API_TOKEN|TRAEFIK_DOMAIN|DDNS_INTERVAL|METRICS_ENABLED|AUTOMATIONS_ENABLED)=' "$ROOT/.env.example" > "$d/.env"
    printf 'API_PORT=%s\nAPI_BIND=127.0.0.1\nAPI_AUTH_ENABLED=false\nMETRICS_ENABLED=false\nAUTOMATIONS_ENABLED=true\nDDNS_ENABLED=false\nDDNS_INTERVAL=300\nCF_DNS_API_TOKEN=smoke-not-a-token\nTRAEFIK_DOMAIN=smoke.test\nCF_API_BASE=http://127.0.0.1:9\n' "$port" >> "$d/.env"
}
# the answer of the listener on RIPPORT, and how long a restart takes to bring it back (seconds, or "never")
_rip_ping() { curl -s -m 1 "http://127.0.0.1:$RIPPORT/ping" 2>/dev/null; }
_rip_wait() { local i; for ((i = 0; i < ${1:-60}; i++)); do [[ "$(_rip_ping)" == *ok* ]] && return 0; sleep 0.25; done; return 1; }
_rip_holders() { local p c=""; for p in $(ss -Hltnp "sport = :$RIPPORT" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u); do c+="$(cat "/proc/$p/comm" 2>/dev/null) "; done; printf '%s' "$c" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//'; }
# A listener started with a RELATIVE path (`.scripts/api-server.sh --bind …`, as CLAUDE.md shows) is stopped by --stop like any other:
# its command line holds only the relative path, and --stop used to call the process foreign and leave it running
if command -v socat >/dev/null 2>&1 && command -v ss >/dev/null 2>&1; then
    RIP="$WORK/rip-rel"; RIPPORT=$(_free_port); _rip_install "$RIP" "$RIPPORT"
    (cd "$RIP" && setsid nohup .scripts/api-server.sh --bind 127.0.0.1 --port "$RIPPORT" > "$RIP/logs/rip.log" 2>&1 < /dev/null &)
    _rip_wait 60
    RIP_MAIN=$(cat "$RIP/.data/api-server.pid" 2>/dev/null)
    check "stop, relative start: the API answers"        yes "$([[ "$(_rip_ping)" == *ok* ]] && echo yes || echo no)"
    (cd "$RIP" && .scripts/api-server.sh --stop >/dev/null 2>&1)
    for _i in $(seq 1 30); do kill -0 "$RIP_MAIN" 2>/dev/null || break; sleep 0.25; done
    check "stop, relative start: the process ends"       no "$(kill -0 "$RIP_MAIN" 2>/dev/null && echo yes || echo no)"
    check "stop, relative start: the port is free"       "" "$(ss -Hltn "sport = :$RIPPORT" 2>/dev/null)"
    RIP_MAIN=""
fi
# The plain case, on the default transport: no DDNS loop, a listener that restarts itself twice (an update, POST /system/restart)
# and stops cleanly. A shutdown step that fails ends the whole process (the server runs with errexit) and nothing comes back.
if command -v socat >/dev/null 2>&1 && command -v ss >/dev/null 2>&1; then
    RIP="$WORK/rip-plain"; RIPPORT=$(_free_port); _rip_install "$RIP" "$RIPPORT"
    setsid nohup "$RIP/.scripts/api-server.sh" --bind 127.0.0.1 --port "$RIPPORT" > "$RIP/logs/rip.log" 2>&1 < /dev/null &
    _rip_wait 60
    RIP_MAIN=$(cat "$RIP/.data/api-server.pid" 2>/dev/null)
    check "restart in place: served through socat"   socat "$(sed 's/\x1b\[[0-9;]*m//g' "$RIP/logs/rip.log" | awk '/Transport/{print $2; exit}')"
    for _n in 1 2; do
        kill -USR1 "$RIP_MAIN"; sleep 0.5
        _rip_wait 60
        check "restart in place: the API answers again (restart $_n)" yes "$([[ "$(_rip_ping)" == *ok* ]] && echo yes || echo no)"
        check "restart in place: the same process lives on ($_n)"     yes "$(kill -0 "$RIP_MAIN" 2>/dev/null && echo yes || echo no)"
    done
    check "restart in place: the pid file is kept"     "$RIP_MAIN" "$(cat "$RIP/.data/api-server.pid" 2>/dev/null)"
    check "restart in place: only socat holds the port" socat "$(_rip_holders)"
    "$RIP/.scripts/api-server.sh" --stop >/dev/null 2>&1
    for _i in $(seq 1 30); do kill -0 "$RIP_MAIN" 2>/dev/null || break; sleep 0.25; done
    check "stop: the process ends"                     no "$(kill -0 "$RIP_MAIN" 2>/dev/null && echo yes || echo no)"
    check "stop: the pid file is removed (the shutdown ran to its end)" no "$([[ -e "$RIP/.data/api-server.pid" ]] && echo yes || echo no)"
    check "stop: the port is free"                     "" "$(ss -Hltn "sport = :$RIPPORT" 2>/dev/null)"
    RIP_MAIN=""
else
    echo "  skip the plain restart test (socat or ss not installed)"
fi
# the real listener on the ncat transport (hosts without socat): the DDNS loop that a settings change starts from a
# request must not hold the port, and the in-place restart must come back
if command -v ncat >/dev/null 2>&1 && command -v ss >/dev/null 2>&1; then
    RIP="$WORK/rip"; RIPPORT=$(_free_port); _rip_install "$RIP" "$RIPPORT"; mkdir -p "$RIP/shim"
    # a PATH without socat: the API then serves through ncat, as it does on a host that has no socat
    IFS=: read -ra _pd <<< "$PATH"
    for ((_i=${#_pd[@]}-1; _i>=0; _i--)); do for _f in "${_pd[_i]}"/*; do [[ -x "$_f" && ! -d "$_f" ]] && ln -sf "$_f" "$RIP/shim/${_f##*/}"; done; done
    command rm -f "$RIP/shim/socat"
    PATH="$RIP/shim" setsid nohup "$RIP/.scripts/api-server.sh" --bind 127.0.0.1 --port "$RIPPORT" > "$RIP/logs/rip.log" 2>&1 < /dev/null &
    _rip_wait 60
    RIP_MAIN=$(cat "$RIP/.data/api-server.pid" 2>/dev/null)
    check "ncat restart: served through ncat"   ncat "$(sed 's/\x1b\[[0-9;]*m//g' "$RIP/logs/rip.log" | awk '/Transport/{print $2; exit}')"
    curl -s -m 10 -X POST -H 'Content-Type: application/json' -d '{"DDNS_ENABLED":"true"}' "http://127.0.0.1:$RIPPORT/config" >/dev/null
    sleep 2
    RIP_DDNS=$(cat "$RIP/.data/ddns.pid" 2>/dev/null)
    check "ncat restart: DDNS started by the request" yes "$([[ -n "$RIP_DDNS" ]] && kill -0 "$RIP_DDNS" 2>/dev/null && echo yes || echo no)"
    check "ncat restart: only ncat holds the port" ncat "$(_rip_holders)"
    RIP_DDNS_OLD="$RIP_DDNS"
    kill -USR1 "$RIP_MAIN"; sleep 0.5
    _rip_wait 60
    check "ncat restart: the API answers again"  yes "$([[ "$(_rip_ping)" == *ok* ]] && echo yes || echo no)"
    check "ncat restart: same process, alive"    yes "$(kill -0 "$RIP_MAIN" 2>/dev/null && echo yes || echo no)"
    check "ncat restart: the old DDNS loop ended" no "$(kill -0 "$RIP_DDNS_OLD" 2>/dev/null && echo yes || echo no)"
    sleep 1
    RIP_DDNS=$(cat "$RIP/.data/ddns.pid" 2>/dev/null)
    check "ncat restart: a new DDNS loop runs"   yes "$([[ -n "$RIP_DDNS" && "$RIP_DDNS" != "$RIP_DDNS_OLD" ]] && kill -0 "$RIP_DDNS" 2>/dev/null && echo yes || echo no)"
    check "ncat restart: only ncat holds the port after it" ncat "$(_rip_holders)"
    kill "$RIP_MAIN" 2>/dev/null; kill "$RIP_DDNS" 2>/dev/null
    for _i in $(seq 1 20); do [[ -z "$(ss -Hltn "sport = :$RIPPORT" 2>/dev/null)" ]] && break; sleep 0.25; done
    check "ncat restart: the port is free after stopping" "" "$(ss -Hltn "sport = :$RIPPORT" 2>/dev/null)"
    RIP_MAIN="" RIP_DDNS=""
else
    echo "  skip ncat restart test (ncat or ss not installed)"
fi

echo "Image updates: the containers left on the old copy are recreated, the schedule runs the same"
# A pull moves the tag to the new image and docker's ancestor filter follows it, so the containers left on the old copy
# were never found and "Recreate containers" did nothing. A stateful fake docker stands in for the daemon.
IMG_DIR="$WORK/fakebin-img"; IMG_ST="$IMG_DIR/state"; mkdir -p "$IMG_ST" "$WORK/Stacks/imgstack"
printf 'services:\n  app:\n    image: ghcr.io/x/app:latest\n  web:\n    image: nginx\n' > "$WORK/Stacks/imgstack/docker-compose.yml"
cat > "$IMG_DIR/docker" <<'FAKE'
#!/bin/bash
ST="$(dirname "$0")/state"
norm() { local r="$1"; r="${r#docker.io/}"; r="${r#index.docker.io/}"; r="${r#library/}"; [[ "${r##*/}" == *[:@]* ]] || r+=":latest"; printf '%s' "$r"; }
img_id() { awk -F'\t' -v r="$(norm "$1")" '$1 == r {print $2; exit}' "$ST/images"; }
set_id() { awk -F'\t' -v OFS='\t' -v r="$1" -v n="$2" '$1 == r {$2 = n} {print}' "$ST/images" > "$ST/images.tmp" && mv "$ST/images.tmp" "$ST/images"; }
short() { local i="${1#sha256:}"; printf '%s' "${i:0:12}"; }
case "$1" in
    pull)
        ref="$2"
        case "$ref" in
            local/*) echo "Error response from daemon: pull access denied for $ref, repository does not exist or may require 'docker login'" >&2; exit 1 ;;
            broken/*) echo "Error response from daemon: connection reset by peer" >&2; exit 1 ;;
        esac
        printf '%s\n' "$ref" >> "$ST/pulls.log"
        n=$(norm "$ref")
        if grep -qxF "$n" "$ST/newer" 2>/dev/null; then
            set_id "$n" "sha256:new-$(printf '%s' "$n" | cksum | cut -d' ' -f1)"
            grep -vxF "$n" "$ST/newer" > "$ST/newer.tmp"; mv "$ST/newer.tmp" "$ST/newer"
            echo "Status: Downloaded newer image for $ref"
        else
            echo "Status: Image is up to date for $ref"
        fi ;;
    image)
        if [[ "$2" == inspect ]]; then id=$(img_id "${@: -1}"); [[ -n "$id" ]] || exit 1; printf '%s\n' "$id"; fi ;;
    images)
        if [[ "$*" == *--no-trunc* ]]; then
            cat "$ST/images"
        else
            while IFS=$'\t' read -r ref id; do
                printf '%s\t%s\t%s\t100MB\t2026-09-28 00:00:00 +0000 UTC\n' "${ref%:*}" "${ref##*:}" "$(short "$id")"
            done < "$ST/images"
        fi ;;
    ps)
        if [[ "$*" == *"ancestor="* ]]; then
            # as the real docker: the name is followed to the image it points to NOW, so only containers on that image match
            anc="${*#*ancestor=}"; anc="${anc%% *}"; cur=$(img_id "$anc")
            while IFS='|' read -r cid name ref have rest; do [[ "$have" == "$cur" ]] && printf '%s\n' "${cid:0:12}"; done < "$ST/containers"
        elif [[ "$*" == *"--format"* ]]; then
            # as the real docker: a container whose tag has moved on is named by its image id
            while IFS='|' read -r cid name ref have proj svc wd cfg; do
                cur=$(img_id "$ref"); shown=$ref; [[ "$cur" == "$have" ]] || shown=$(short "$have")
                printf '%s\t%s\t%s\n' "$shown" "$name" "$proj"
            done < "$ST/containers"
        else
            cut -d'|' -f1 "$ST/containers" | cut -c1-12
        fi ;;
    inspect)
        shift
        fmt=""; if [[ "$1" == "--format" ]]; then fmt="$2"; shift 2; fi
        for want in "$@"; do
            line=$(awk -F'|' -v w="$want" 'index($1, w) == 1 || $2 == w {print; exit}' "$ST/containers")
            if [[ -z "$line" ]]; then [[ "$fmt" == "{{.State.Status}}" ]] && { echo missing; exit 1; }; continue; fi
            IFS='|' read -r cid name ref have proj svc wd cfg <<< "$line"
            case "$fmt" in
                '{{.Id}}|{{.Name}}|'*) printf '%s|/%s|%s|%s|%s|%s|%s|%s\n' "$cid" "$name" "$ref" "$have" "$proj" "$svc" "$wd" "$cfg" ;;
                '{{.Name}}|{{.Config.Image}}|{{.Image}}|'*) printf '/%s|%s|%s|%s|%s|%s\n' "$name" "$ref" "$have" "$svc" "$wd" "$cfg" ;;
                '{{.Config.Image}}') printf '%s\n' "$ref" ;;
                '{{.State.Status}}') echo running ;;
            esac
        done ;;
    *) exit 0 ;;
esac
FAKE
cat > "$IMG_DIR/compose" <<'FAKE'
#!/bin/bash
# docker compose -f FILE [--env-file F] up -d --force-recreate --no-deps SERVICE: the service's container runs the tag's current image
ST="$(dirname "$0")/state"
echo "$*" >> "$ST/compose.log"
file=""; svc=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f) file="$2"; shift 2 ;;
        --env-file) shift 2 ;;
        up|-d|--force-recreate|--no-deps) shift ;;
        *) svc="$1"; shift ;;
    esac
done
wd=$(dirname "$file")
norm() { local r="$1"; r="${r#docker.io/}"; r="${r#index.docker.io/}"; r="${r#library/}"; [[ "${r##*/}" == *[:@]* ]] || r+=":latest"; printf '%s' "$r"; }
while IFS='|' read -r cid name ref have proj s w cfg; do
    if [[ "$s" == "$svc" && "$w" == "$wd" ]]; then
        have=$(awk -F'\t' -v r="$(norm "$ref")" '$1 == r {print $2; exit}' "$ST/images")
    fi
    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$cid" "$name" "$ref" "$have" "$proj" "$s" "$w" "$cfg"
done < "$ST/containers" > "$ST/containers.tmp"
mv "$ST/containers.tmp" "$ST/containers"
FAKE
chmod +x "$IMG_DIR/docker" "$IMG_DIR/compose"
# the registry has a newer copy of app; app-1 (Compose) and app-2 (started by hand) run the old one; web was created from plain "nginx"
_img_reset() {
    printf 'ghcr.io/x/app:latest\tsha256:app-old\nnginx:latest\tsha256:nginx-cur\nlocal/tool:latest\tsha256:tool-cur\n' > "$IMG_ST/images"
    printf 'ghcr.io/x/app:latest\n' > "$IMG_ST/newer"
    printf '%s\n' "c1aaaaaaaaaa1|app-1|ghcr.io/x/app:latest|sha256:app-old|imgstack|app|$WORK/Stacks/imgstack|" \
                  "c2bbbbbbbbbb2|app-2|ghcr.io/x/app:latest|sha256:app-old||||" \
                  "c3cccccccccc3|web|nginx|sha256:nginx-cur|imgstack|web|$WORK/Stacks/imgstack|" \
                  "c4dddddddddd4|tool|local/tool:latest|sha256:tool-cur||||" > "$IMG_ST/containers"
    : > "$IMG_ST/compose.log"; : > "$IMG_ST/pulls.log"
}
img_request() { command rm -f "$WORK/.data/cache/"*.http; PATH="$IMG_DIR:$PATH" DOCKER_COMPOSE_CMD="$IMG_DIR/compose" auth_request "$@"; }
_img_field() { jq -r --arg i "$1" --arg f "${2:-containers_outdated}" '.images[] | select(.image == $i) | .[$f]'; }

_img_reset
check "image list: nothing outdated before the pull" "" "$(img_request GET /images/check-updates | body_of | _img_field ghcr.io/x/app:latest)"
R=$(img_request POST /images/update '{"image":"ghcr.io/x/app:latest","recreate":true}')
check "image update: answers"                      200 "$(printf '%s' "$R" | status_of)"
check "image update: the Compose container is recreated" '["app-1"]' "$(printf '%s' "$R" | body_of | jq -c '.containers_restarted')"
check "image update: one outside Compose is reported" '["app-2"]' "$(printf '%s' "$R" | body_of | jq -c '.containers_skipped')"
check "image update: nothing failed"               '[]' "$(printf '%s' "$R" | body_of | jq -c '.containers_failed')"
check "image update: compose recreated the service" yes "$(grep -q -- "up -d --force-recreate --no-deps app" "$IMG_ST/compose.log" && echo yes || echo no)"
check "image update: a service on a current image is left alone" 1 "$(wc -l < "$IMG_ST/compose.log" | tr -d ' ')"
check "image list: the container started by hand still runs the old copy" app-2 "$(img_request GET /images/check-updates | body_of | _img_field ghcr.io/x/app:latest containers_outdated_manual)"
check "image list: nothing left for DCS to recreate" "" "$(img_request GET /images/check-updates | body_of | _img_field ghcr.io/x/app:latest)"
check "image list: a container created from nginx shows under nginx:latest" web "$(img_request GET /images/check-updates | body_of | _img_field nginx:latest containers)"
# pull only: the containers stay, and the list says so
_img_reset
R=$(img_request POST /images/update '{"image":"ghcr.io/x/app:latest","recreate":false}')
check "pull only: nothing recreated"               '[]' "$(printf '%s' "$R" | body_of | jq -c '.containers_restarted')"
check "pull only: compose untouched"               0 "$(wc -l < "$IMG_ST/compose.log" | tr -d ' ')"
check "pull only: the Compose container is listed as outdated" "app-1" "$(img_request GET /images/check-updates | body_of | _img_field ghcr.io/x/app:latest)"
check "pull only: so is the one started by hand, apart" "app-2" "$(img_request GET /images/check-updates | body_of | _img_field ghcr.io/x/app:latest containers_outdated_manual)"
# what the old code left behind: the tag moved on a pull, the containers did not follow. Updating again puts it right
R=$(img_request POST /images/update '{"image":"ghcr.io/x/app:latest"}')
check "leftover: the containers on the old copy are recreated now" '["app-1"]' "$(printf '%s' "$R" | body_of | jq -c '.containers_restarted')"
# a container created from "nginx" belongs to the image "nginx:latest"
_img_reset; printf 'nginx:latest\n' > "$IMG_ST/newer"
R=$(img_request POST /images/update '{"image":"nginx:latest"}')
check "nginx = nginx:latest: the container is recreated" '["web"]' "$(printf '%s' "$R" | body_of | jq -c '.containers_restarted')"
_img_reset
R=$(img_request POST /images/update '{"image":"broken/pull:latest"}')
check "a failed pull is an error"                  500 "$(printf '%s' "$R" | status_of)"
# the unattended job (what the image-update schedule starts)
_img_reset
printf 'c5eeeeeeeeee5|bad|broken/pull:latest|sha256:bad-cur||||\n' >> "$IMG_ST/containers"; printf 'broken/pull:latest\tsha256:bad-cur\n' >> "$IMG_ST/images"
printf 'nginx:latest\n' >> "$IMG_ST/newer"
OUT=$(PATH="$IMG_DIR:$PATH" DOCKER_COMPOSE_CMD="$IMG_DIR/compose" "$API" --image-update 2>&1)
check "job: the image with a newer copy is updated" yes "$(grep -q 'ghcr.io/x/app:latest: updated, 1 container(s) recreated' <<< "$OUT" && echo yes || echo no)"
check "job: the container created from nginx is recreated" yes "$(grep -q 'nginx: updated, 1 container(s) recreated' <<< "$OUT" && echo yes || echo no)"
check "job: a local-only image is left alone"      yes "$(grep -q 'local/tool:latest: not pullable' <<< "$OUT" && echo yes || echo no)"
check "job: a failed pull is reported"             yes "$(grep -q 'broken/pull:latest: pull failed' <<< "$OUT" && echo yes || echo no)"
check "job: history entry of the images"           images "$(jq -r '.[-1].type' "$WORK/.api-auth/update-history.json" 2>/dev/null)"
check "job: a failed pull makes the run failed"    failed "$(jq -r '.[-1].result' "$WORK/.api-auth/update-history.json" 2>/dev/null)"
_img_reset; : > "$IMG_ST/newer"
OUT=$(PATH="$IMG_DIR:$PATH" DOCKER_COMPOSE_CMD="$IMG_DIR/compose" "$API" --image-update 2>&1)
check "job: everything current is a quiet ok"      ok "$(jq -r '.[-1].result' "$WORK/.api-auth/update-history.json" 2>/dev/null)"
check "job: nothing recreated when all is current" 0 "$(wc -l < "$IMG_ST/compose.log" | tr -d ' ')"
_img_reset
OUT=$(PATH="$IMG_DIR:$PATH" DOCKER_COMPOSE_CMD="$IMG_DIR/compose" "$API" --image-update --pull-only 2>&1)
check "job pull only: says so"                     yes "$(grep -q 'recreate containers: false' <<< "$OUT" && echo yes || echo no)"
check "job pull only: compose untouched"           0 "$(wc -l < "$IMG_ST/compose.log" | tr -d ' ')"
check "job pull only: the containers stay on the old copy" "app-1" "$(img_request GET /images/check-updates | body_of | _img_field ghcr.io/x/app:latest)"
# the schedule
check "schedule: image-update accepted"            200 "$(auth_request POST /schedules '{"name":"images nightly","schedule":"0 3 * * *","action":"image-update","target":""}' | status_of)"
check "schedule: image-update pull-only accepted"  200 "$(auth_request POST /schedules '{"name":"images pull","schedule":"0 4 * * *","action":"image-update","target":"pull"}' | status_of)"
check "schedule: image-update bad target"          400 "$(auth_request POST /schedules '{"name":"images bad","schedule":"0 3 * * *","action":"image-update","target":"bogus"}' | status_of)"
check "schedule: viewer cannot create it"          403 "$(viewer_request POST /schedules '{"name":"v","schedule":"@daily","action":"image-update","target":""}' | status_of)"
_img_reset
: > "$WORK/logs/image-update.log"
ISID=$(auth_request GET /schedules | body_of | jq -r '.schedules[]? | select(.action=="image-update" and .target=="") | .id' | head -1)
check "schedule: run now starts the job"           true "$(img_request POST "/schedules/$ISID/run" | body_of | jq -r '.success')"
for _i in $(seq 1 40); do grep -q 'image-update: done' "$WORK/logs/image-update.log" 2>/dev/null && break; sleep 0.5; done
check "schedule: the job ran to the end"           yes "$(grep -q 'image-update: done' "$WORK/logs/image-update.log" && echo yes || echo no)"
check "schedule: the job recreated the container"  yes "$(grep -q 'ghcr.io/x/app:latest: updated, 1 container(s) recreated' "$WORK/logs/image-update.log" && echo yes || echo no)"
for _sid in $(auth_request GET /schedules | body_of | jq -r '.schedules[]? | select(.action=="image-update") | .id'); do auth_request DELETE "/schedules/$_sid" >/dev/null; done

echo "Health: a Docker that does not answer is not a healthy server, and neither is a hub with a silent VM"
# "docker ps" failing is not an empty list: every container is down, so the verdict cannot be "healthy — 0 containers"
mkdir -p "$WORK/fakebin-dead" "$WORK/fakebin-empty"
printf '#!/bin/bash\necho "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2\nexit 1\n' > "$WORK/fakebin-dead/docker"
printf '#!/bin/bash\nexit 0\n' > "$WORK/fakebin-empty/docker"
chmod +x "$WORK/fakebin-dead/docker" "$WORK/fakebin-empty/docker"
_health_with() { command rm -f "$WORK/.data/cache/"*.http; PATH="$1:$PATH" auth_request GET /health | body_of; }   # the .env of the test install keeps the response cache on
HD=$(_health_with "$WORK/fakebin-dead")
check "health: Docker down is critical"          critical "$(jq -r '.status' <<< "$HD" 2>/dev/null)"
check "health: Docker down is reported"          false "$(jq -r '.docker.reachable' <<< "$HD" 2>/dev/null)"
check "health: the reason is given"              yes "$(jq -r '.docker.error' <<< "$HD" 2>/dev/null | grep -q 'Cannot connect to the Docker daemon' && echo yes || echo no)"
HE=$(_health_with "$WORK/fakebin-empty")
check "health: an answering Docker with no containers is healthy" healthy "$(jq -r '.status' <<< "$HE" 2>/dev/null)"
check "health: ...and says it answers"           true "$(jq -r '.docker.reachable' <<< "$HE" 2>/dev/null)"
check "health: ...with no error text"            "" "$(jq -r '.docker.error' <<< "$HE" 2>/dev/null)"
# the score: no containers because Docker is down is not "100 % healthy"
_score_with() { command rm -f "$WORK/.data/cache/"*.http; PATH="$1:$PATH" auth_request GET /health/score | body_of; }
SD=$(_score_with "$WORK/fakebin-dead"); SE=$(_score_with "$WORK/fakebin-empty")
check "score: Docker down is an F"               F "$(jq -r '.grade' <<< "$SD" 2>/dev/null)"
check "score: ...at most 39"                     yes "$(jq -e '.score <= 39' <<< "$SD" >/dev/null 2>&1 && echo yes || echo no)"
check "score: the containers factor is zero"     0 "$(jq -r '.factors.stacks.score' <<< "$SD" 2>/dev/null)"
check "score: it says Docker does not answer"    false "$(jq -r '.docker.reachable' <<< "$SD" 2>/dev/null)"
check "score: an answering Docker with no containers keeps its 100" 100 "$(jq -r '.factors.stacks.score' <<< "$SE" 2>/dev/null)"
check "score: ...and says it answers"            true "$(jq -r '.docker.reachable' <<< "$SE" 2>/dev/null)"
check "score: ...and is not capped"              yes "$(jq -e '.score > 39' <<< "$SE" >/dev/null 2>&1 && echo yes || echo no)"

echo "Round 2: prune safety, power watch, recovery bundles, new schedule actions, deploy switches"
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/docker" <<'FAKE'
#!/bin/bash
case "$*" in
  "ps -a --filter status=exited --filter status=created --filter status=dead --format {{.Names}}") printf 'zz-stopped\nIT-Tools\nzz-other\n' ;;
  "inspect Ollama") exit 1 ;;
  "inspect --type container Authelia") [[ -f "$(dirname "$0")/.authelia" ]] && exit 0 || exit 1 ;;
  "inspect --type container Never") exit 1 ;;
  "inspect Sablier") [[ -f "$(dirname "$0")/.nosablier" ]] && exit 1 || exit 0 ;;
  "inspect -f {{.State.Running}} Homarr") echo true ;;
  *) exit 0 ;;
esac
FAKE
cat > "$WORK/fakebin/apcaccess" <<'FAKE'
#!/bin/bash
printf 'APC      : 001,036,0872\nSTATUS   : ONBATT\nBCHARGE  : 42.0 Percent\nTIMELEFT : 23.0 Minutes\nLOADPCT  : 12.0 Percent\nLINEV    : 0.0 Volts\nMODEL    : Smoke UPS\n'
FAKE
chmod +x "$WORK/fakebin/docker" "$WORK/fakebin/apcaccess"
check "prune spares on-demand containers" 'zz-stopped zz-other' "$(PATH="$WORK/fakebin:$PATH" _lib _prune_stopped_candidates | tr '\n' ' ' | sed 's/ $//')"
check "missing on-demand container found" Ollama "$(PATH="$WORK/fakebin:$PATH" _lib _sablier_missing | tr '\n' ' ' | sed 's/ $//')"
check "health lists missing on-demand"   array "$(auth_request GET /health | body_of | jq -r '.summary.on_demand_missing | type' 2>/dev/null)"
check "sablier repair answers"          200 "$(auth_request POST /sablier/repair | status_of)"
check "sablier repair: viewer denied"   403 "$(viewer_request POST /sablier/repair | status_of)"
# the container's on-demand dialog end to end (the fake docker says the container and Sablier exist): the
# settings a deploy wrote into the route file are read, replaced by the API's own file with the new ones,
# a refused change keeps them, a group block is never touched, and switching off leaves nothing behind
_SBF="$WORK/Stacks/zz-proxy/App-Data/Traefik/custom_routes/demo/tools.yml"; _SBD=$(dirname "$_SBF"); cp "$_SBF" "$_SBF.orig"
sab_request() { PATH="$WORK/fakebin:$PATH" auth_request "$@"; }
check "on demand: deploy's settings read"   "true 30m" "$(sab_request GET /containers/IT-Tools/sablier | body_of | jq -r '"\(.enabled) \(.session)"')"
check "on demand: group reported"           true "$(sab_request GET /containers/Plex/sablier | body_of | jq -r '.group')"
check "on demand: single is no group"       false "$(sab_request GET /containers/IT-Tools/sablier | body_of | jq -r '.group')"
touch "$WORK/fakebin/.nosablier"
check "on demand: refused without Sablier"  409 "$(sab_request POST /containers/IT-Tools/sablier '{"enabled":true,"session":"1h"}' | status_of)"
check "on demand: refusal keeps settings"   1 "$(grep -c 'ittools-sablier:' "$_SBF")"
rm -f "$WORK/fakebin/.nosablier"
check "on demand: new settings saved"       true "$(sab_request POST /containers/IT-Tools/sablier '{"enabled":true,"session":"2h","theme":"shuffle","show_details":false,"display_name":"Tools"}' | body_of | jq -r '.enabled')"
check "on demand: deploy block replaced"    0 "$(grep -c 'ittools-sablier:' "$_SBF")"
check "on demand: own file written"         1 "$(grep -c 'sessionDuration: 2h' "$_SBD/ittools-sablier.yml" 2>/dev/null)"
check "on demand: router names it once"     1 "$(grep -c '"ittools-sablier"' "$_SBF")"
check "on demand: settings read back"       "2h shuffle false Tools" "$(sab_request GET /containers/IT-Tools/sablier | body_of | jq -r '"\(.session) \(.theme) \(.show_details) \(.display_name)"')"
check "on demand: group block untouched"    1 "$(grep -c 'multi-sablier:' "$_SBF")"
check "on demand: served normally again"    false "$(sab_request POST /containers/IT-Tools/sablier '{"enabled":false}' | body_of | jq -r '.enabled')"
check "on demand: own file removed"         no "$([[ -f "$_SBD/ittools-sablier.yml" ]] && echo yes || echo no)"
check "on demand: no reference left"        0 "$(grep -c 'ittools-sablier' "$_SBF")"
check "on demand: GET says off"             false "$(sab_request GET /containers/IT-Tools/sablier | body_of | jq -r '.enabled')"
check "on demand: route file still yaml"    ok "$(python3 -c "import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); r=d['http']['routers']['tools-router']; print('ok' if 'multi-sablier' in d['http']['middlewares'] and not r.get('middlewares') else 'bad')" "$_SBF" 2>/dev/null || echo ok)"
check "on demand: no empty middlewares key" 0 "$(awk '/^      middlewares:[ ]*$/ { getline n; if (n !~ /^        - /) c++ } END { print c+0 }' "$_SBF")"
mv -f "$_SBF.orig" "$_SBF"; rm -f "$_SBD/ittools-sablier.yml"
# a theme.park theme on a container's route (the catalogue seeded; the fake docker says the container exists)
printf '%s\n' '{"apps":{"sonarr":["sonarr-4k-logo","sonarr-darker"],"radarr":[]},"themes":["dark","nord"],"community":["catppuccin-mocha"]}' > "$WORK/.data/themepark.json"
printf 'http:\n  routers:\n    sonarr-router:\n      rule: "Host(`sonarr.example.test`)"\n      service: "sonarr"\n      middlewares:\n        - "traefik-chain"\n        - "compress-gzip"\n  services:\n    sonarr:\n      loadBalancer:\n        servers:\n          - url: "http://Sonarr:8989"\n' > "$_SBD/sonarr.yml"
_TS=$(sab_request GET /containers/Sonarr/theme | body_of)
check "theme: app recognised"             "true sonarr" "$(jq -r '"\(.supported) \(.app)"' <<< "$_TS" 2>/dev/null)"
check "theme: route found"                "true sonarr.example.test" "$(jq -r '"\(.routed) \(.host)"' <<< "$_TS" 2>/dev/null)"
check "theme: catalogue offered"          "2 1 2" "$(jq -r '"\(.catalog.themes | length) \(.catalog.community | length) \(.catalog.addons | length)"' <<< "$_TS" 2>/dev/null)"
check "theme: off at first"               false "$(jq -r '.enabled' <<< "$_TS" 2>/dev/null)"
check "theme: other apps not offered"     false "$(sab_request GET /containers/IT-Tools/theme | body_of | jq -r '.supported' 2>/dev/null)"
check "theme: unknown theme refused"      400 "$(sab_request POST /containers/Sonarr/theme '{"enabled":true,"theme":"nope"}' | status_of)"
check "theme: unknown add-on refused"     400 "$(sab_request POST /containers/Sonarr/theme '{"enabled":true,"theme":"nord","addons":["radarr-4k-logo"]}' | status_of)"
check "theme: darker needs the base"      400 "$(sab_request POST /containers/Sonarr/theme '{"enabled":true,"theme":"nord","addons":["sonarr-darker"]}' | status_of)"
check "theme: viewer may not theme"       403 "$(viewer_request POST /containers/Sonarr/theme '{"enabled":true,"theme":"nord"}' | status_of)"
check "theme: applied"                    true "$(sab_request POST /containers/Sonarr/theme '{"enabled":true,"theme":"Nord","addons":["sonarr-4k-logo"]}' | body_of | jq -r '.enabled' 2>/dev/null)"
check "theme: middleware written"         "nord" "$(sed -nE 's/^[[:space:]]+theme: ([a-z-]+)$/\1/p' "$_SBD/sonarr-theme.yml" 2>/dev/null)"
check "theme: last in the chain"          '"sonarr-theme"' "$(awk '/^      middlewares:/ { on=1; next } on && /^        - / { l=$2; next } on { on=0 } END { print l }' "$_SBD/sonarr.yml")"
check "theme: plugin declared"            1 "$(grep -c 'packruler/traefik-themepark' "$_TAD/Traefik/traefik.yml")"
check "theme: read back"                  "true nord sonarr-4k-logo" "$(sab_request GET /containers/Sonarr/theme | body_of | jq -r '"\(.enabled) \(.theme) \(.addons | join(","))"' 2>/dev/null)"
check "theme: a community theme"          catppuccin-mocha "$(sab_request POST /containers/Sonarr/theme '{"enabled":true,"theme":"catppuccin-mocha"}' | body_of | jq -r '.theme' 2>/dev/null)"
check "theme: still named once"           1 "$(grep -c '"sonarr-theme"' "$_SBD/sonarr.yml")"
check "theme: taken off"                  false "$(sab_request POST /containers/Sonarr/theme '{"enabled":false}' | body_of | jq -r '.enabled' 2>/dev/null)"
check "theme: nothing left behind"        "0 no" "$(grep -c 'sonarr-theme' "$_SBD/sonarr.yml") $([[ -f "$_SBD/sonarr-theme.yml" ]] && echo yes || echo no)"
check "theme: the chain kept"             '"traefik-chain" "compress-gzip"' "$(awk '/^      middlewares:/ { on=1; next } on && /^        - / { printf "%s%s", (n++ ? " " : ""), $2; next } on { on=0 }' "$_SBD/sonarr.yml")"
# the hub adds a VM route's theme when it writes the VM routes
check "theme: VM route themed on the hub" '["traefik-chain","tp-media-vm-sonarr-lab-test"] nord' "$(FLEET_THEMES_FILE=<(printf '%s' '{"media-vm|sonarr.lab.test":{"app":"sonarr","theme":"nord","addons":[]}}') _lib _fleet_themes_apply '{"http":{"routers":{"media-vm-sonarr-dcs":{"rule":"Host(`sonarr.lab.test`)","middlewares":["traefik-chain"]},"other-sonarr-dcs":{"rule":"Host(`sonarr.lab.test`)"}},"services":{}}}' | jq -c '[.http.routers["media-vm-sonarr-dcs"].middlewares, .http.middlewares["tp-media-vm-sonarr-lab-test"].plugin.themepark.theme] | "\(.[0] | tojson) \(.[1])"' -r 2>/dev/null)"
check "theme: another VM's route untouched" null "$(FLEET_THEMES_FILE=<(printf '%s' '{"media-vm|sonarr.lab.test":{"app":"sonarr","theme":"nord","addons":[]}}') _lib _fleet_themes_apply '{"http":{"routers":{"other-sonarr-dcs":{"rule":"Host(`sonarr.lab.test`)"}},"services":{}}}' | jq -c '.http.routers["other-sonarr-dcs"].middlewares' 2>/dev/null)"
# Traefik knows theme.park by the name its static config declares (Scott's "theme-park", modulename in lower
# case): DCS's middleware must use it — under another name Traefik refuses the middleware and the router answers 404
printf '%s\n' '{"apps":{"sonarr":["sonarr-4k-logo","sonarr-text-logo"]},"themes":["dark","nord","spacegray"],"community":[]}' > "$WORK/.data/themepark.json"
_TY2="$_TAD/Traefik/traefik.yml"; cp "$_TY2" "$_TY2.orig"
sed -i -E 's/^    themepark:[[:space:]]*$/    theme-park:/; s#^      moduleName: "github.com/packruler/traefik-themepark"#      modulename: "github.com/packruler/traefik-themepark"#' "$_TY2"
check "plugin name: read from the static config" theme-park "$(_lib _traefik_plugin_name github.com/packruler/traefik-themepark)"
check "plugin name: sablier as declared"         sablier "$(_lib _traefik_plugin_name github.com/acouvreur/sablier)"
check "plugin name: undeclared is nothing"       "" "$(_lib _traefik_plugin_name github.com/none/none)"
printf 'http:\n  routers:\n    sonarr-router:\n      rule: "Host(`sonarr.example.test`)"\n      service: "sonarr"\n      middlewares:\n        - "traefik-chain"\n        - "compress-gzip"\n        - "sonarr-dark"\n  services:\n    sonarr:\n      loadBalancer:\n        servers:\n          - url: "http://Sonarr:8989"\n  middlewares:\n    sonarr-dark:\n      plugin:\n        theme-park:\n          app: sonarr\n          theme: spacegray\n          addons:\n            - sonarr-text-logo\n' > "$_SBD/sonarr.yml"
_TS2=$(sab_request GET /containers/Sonarr/theme | body_of)
check "theme: hand-written one seen"          "true false sonarr-dark spacegray" "$(jq -r '"\(.enabled) \(.managed) \(.middleware) \(.theme)"' <<< "$_TS2" 2>/dev/null)"
check "theme: its add-ons read"               sonarr-text-logo "$(jq -r '.addons | join(",")' <<< "$_TS2" 2>/dev/null)"
check "theme: plugin name reported"           theme-park "$(jq -r '.plugin' <<< "$_TS2" 2>/dev/null)"
check "theme: applied under that name"        true "$(sab_request POST /containers/Sonarr/theme '{"enabled":true,"theme":"nord"}' | body_of | jq -r '.enabled' 2>/dev/null)"
check "theme: middleware uses theme-park"     1 "$(grep -c '^        theme-park:$' "$_SBD/sonarr-theme.yml" 2>/dev/null)"
check "theme: no second declaration"          1 "$(grep -c 'packruler/traefik-themepark' "$_TY2")"
check "theme: the hand-written one gives way" '"traefik-chain" "compress-gzip" "sonarr-theme"' "$(awk '/^      middlewares:/ { on=1; next } on && /^        - / { printf "%s%s", (n++ ? " " : ""), $2; next } on { on=0 }' "$_SBD/sonarr.yml")"
check "theme: its definition stays"           1 "$(grep -c '^    sonarr-dark:$' "$_SBD/sonarr.yml")"
check "theme: DCS's own now"                  "true true sonarr-theme" "$(sab_request GET /containers/Sonarr/theme | body_of | jq -r '"\(.enabled) \(.managed) \(.middleware)"' 2>/dev/null)"
sab_request POST /containers/Sonarr/theme '{"enabled":false}' >/dev/null
check "theme: taken off, nothing left"        "0 0 no" "$(grep -c 'sonarr-theme' "$_SBD/sonarr.yml") $(grep -c '"sonarr-dark"' "$_SBD/sonarr.yml") $([[ -f "$_SBD/sonarr-theme.yml" ]] && echo yes || echo no)"
# the files 3.9.5 wrote under "themepark" while Traefik declares "theme-park" (the route answered 404) are
# repaired, and the hand-written middleware beside DCS's comes off that route; a user's own file is left alone
printf 'http:\n  middlewares:\n    sonarr-theme:\n      plugin:\n        themepark:\n          app: sonarr\n          theme: dark\n' > "$_SBD/sonarr-theme.yml"
sed -i 's/^        - "compress-gzip"$/        - "compress-gzip"\n        - "sonarr-dark"\n        - "sonarr-theme"/' "$_SBD/sonarr.yml"
printf 'http:\n  middlewares:\n    extra:\n      plugin:\n        themepark:\n          app: sonarr\n          theme: dark\n' > "$_SBD/mine-theme.yml"; _MINE=$(md5sum < "$_SBD/mine-theme.yml")
check "repair: two changes"                   2 "$(_lib _theme_files_repair)"
check "repair: the plugin name fixed"         1 "$(grep -c '^        theme-park:$' "$_SBD/sonarr-theme.yml")"
check "repair: one theme on the route"        '"traefik-chain" "compress-gzip" "sonarr-theme"' "$(awk '/^      middlewares:/ { on=1; next } on && /^        - / { printf "%s%s", (n++ ? " " : ""), $2; next } on { on=0 }' "$_SBD/sonarr.yml")"
check "repair: nothing more to do"            0 "$(_lib _theme_files_repair)"
check "repair: a user's own file untouched"   yes "$([[ "$(md5sum < "$_SBD/mine-theme.yml")" == "$_MINE" ]] && echo yes || echo no)"
# the repair touches only a broken route: one that answers keeps the name it has (the declared one may not be loaded
# yet), and a rewrite Traefik still refuses is put back
printf 'http:
  middlewares:
    sonarr-theme:
      plugin:
        themepark:
          app: sonarr
          theme: dark
' > "$_SBD/sonarr-theme.yml"
check "repair: a working route left alone"    "0 1" "$(_lib eval '_traefik_probe() { echo 200; }; _theme_files_repair') $(grep -c '^        themepark:$' "$_SBD/sonarr-theme.yml")"
check "repair: a rewrite that fails is undone" "0 1" "$(_lib eval '_traefik_probe() { echo 404; }; THEME_REPAIR_WAIT=0; _theme_files_repair') $(grep -c '^        themepark:$' "$_SBD/sonarr-theme.yml")"
rm -f "$WORK/probe-count"
check "repair: a rewrite that works is kept"  "1 1" "$(_lib eval '_traefik_probe() { local c; c=$(cat "$WORK/probe-count" 2>/dev/null || echo 0); echo $((c + 1)) > "$WORK/probe-count"; [[ $c -eq 0 ]] && echo 404 || echo 200; }; THEME_REPAIR_WAIT=0; _theme_files_repair') $(grep -c '^        theme-park:$' "$_SBD/sonarr-theme.yml")"
rm -f "$WORK/probe-count"
check "theme: a VM route themed under that name" theme-park "$(FLEET_THEMES_FILE=<(printf '%s' '{"media-vm|sonarr.lab.test":{"app":"sonarr","theme":"nord","addons":[]}}') _lib _fleet_themes_apply '{"http":{"routers":{"media-vm-sonarr-dcs":{"rule":"Host(`sonarr.lab.test`)"}},"services":{}}}' | jq -r '.http.middlewares[].plugin | keys[0]' 2>/dev/null)"
# the check after a change: a 404 that was not there before is Traefik refusing the middleware
check "verify: nothing to compare without Traefik" 0 "$(_lib eval 'THEME_VERIFY_WAITS=0; _theme_verify sonarr.example.test 000; echo $?')"
check "verify: a new 404 is a refusal"        1 "$(_lib eval '_traefik_probe() { echo 404; }; THEME_VERIFY_WAITS=0; _theme_verify sonarr.example.test 200 && echo 0 || echo $?')"
check "verify: an answering app is fine"      0 "$(_lib eval '_traefik_probe() { echo 302; }; THEME_VERIFY_WAITS="0 0"; _theme_verify sonarr.example.test 200; echo $?')"
check "verify: an app that answers 404 itself" 0 "$(_lib eval '_traefik_probe() { echo 404; }; THEME_VERIFY_WAITS=0; _theme_verify sonarr.example.test 404; echo $?')"
mv -f "$_TY2.orig" "$_TY2"; rm -f "$_SBD/mine-theme.yml"
rm -f "$_SBD/sonarr.yml" "$_SBD/sonarr-theme.yml" "$WORK/.data/themepark.json"
# a container on the Homarr dashboard (the fake docker says the container and a Homarr exist; no port → the app library)
_HC=$(sab_request GET /containers/IT-Tools/homarr | body_of)
check "homarr card: address from the route" "https://tools.example.test route" "$(jq -r '"\(.target.url) \(.target.source)"' <<< "$_HC" 2>/dev/null)"
check "homarr card: Homarr seen, library"   "true library" "$(jq -r '"\(.homarr.active) \(.homarr.mode)"' <<< "$_HC" 2>/dev/null)"
check "homarr card: not added yet"          false "$(jq -r '.added' <<< "$_HC" 2>/dev/null)"
check "homarr card: a name to show"         yes "$([[ -n "$(jq -r '.target.name // empty' <<< "$_HC" 2>/dev/null)" ]] && echo yes || echo no)"
check "homarr card: unknown container"      404 "$(auth_request GET /containers/nope-zz/homarr | status_of)"
check "homarr card: viewer may look"        404 "$(viewer_request GET /containers/nope-zz/homarr | status_of)"
check "homarr card: viewer may not add"     403 "$(viewer_request POST /containers/IT-Tools/homarr | status_of)"
if command -v sqlite3 >/dev/null 2>&1; then
    _HDB="$WORK/Stacks/zz-proxy/App-Data/Homarr/appdata/db"; mkdir -p "$_HDB"
    sqlite3 "$_HDB/db.sqlite" "CREATE TABLE app (id TEXT PRIMARY KEY, name TEXT, description TEXT, icon_url TEXT, href TEXT, ping_url TEXT);"
    check "homarr card: added to the library"   "true library" "$(sab_request POST /containers/IT-Tools/homarr | body_of | jq -r '"\(.added) \(.result.mode)"' 2>/dev/null)"
    check "homarr card: the app is there"       "https://tools.example.test" "$(sqlite3 "$_HDB/db.sqlite" "SELECT href FROM app;" 2>/dev/null)"
    check "homarr card: seen as added"          "true https://tools.example.test" "$(sab_request GET /containers/IT-Tools/homarr | body_of | jq -r '"\(.added) \(.app.href)"' 2>/dev/null)"
    check "homarr card: never added twice"      "true 1" "$(sab_request POST /containers/IT-Tools/homarr | body_of | jq -r '.already' 2>/dev/null) $(sqlite3 "$_HDB/db.sqlite" "SELECT COUNT(*) FROM app;" 2>/dev/null)"
    rm -rf "$WORK/Stacks/zz-proxy/App-Data/Homarr"
else
    check "homarr card: no database, a reason"  502 "$(sab_request POST /containers/IT-Tools/homarr | status_of)"
fi
PW=$(PATH="$WORK/fakebin:$PATH" UPS_SOURCE=apcupsd _lib _power_sample)
check "power: apcupsd parsed"           apcupsd "$(printf '%s' "$PW" | jq -r '.source')"
check "power: on battery"               true "$(printf '%s' "$PW" | jq -r '.on_battery')"
check "power: charge"                   42 "$(printf '%s' "$PW" | jq -r '.charge')"
check "power: runtime seconds"          1380 "$(printf '%s' "$PW" | jq -r '.runtime_seconds')"
check "power: model"                    'Smoke UPS' "$(printf '%s' "$PW" | jq -r '.model')"
if command -v socat >/dev/null 2>&1; then
    NUTP=$((30000 + RANDOM % 20000))
    printf 'BEGIN LIST VAR ups\nVAR ups ups.status "OB DISCHRG"\nVAR ups battery.charge "42"\nVAR ups battery.runtime "1380"\nVAR ups ups.load "23"\nVAR ups input.voltage "0.0"\nVAR ups ups.model "Smoke UPS"\nEND LIST VAR ups\n' > "$WORK/nut.txt"
    socat "TCP-LISTEN:${NUTP},reuseaddr,fork" SYSTEM:"cat $WORK/nut.txt" >/dev/null 2>&1 &
    NUTPID=$!
    sleep 0.5
    PN=$(UPS_SOURCE=nut UPS_NUT_HOST=127.0.0.1 UPS_NUT_PORT=$NUTP UPS_NAME=ups _lib _power_sample)
    check "power: NUT over TCP"             nut "$(printf '%s' "$PN" | jq -r '.source')"
    check "power: NUT on battery"           true "$(printf '%s' "$PN" | jq -r '.on_battery')"
    check "power: NUT charge"               42 "$(printf '%s' "$PN" | jq -r '.charge')"
    check "power: NUT load"                 23 "$(printf '%s' "$PN" | jq -r '.load')"
    kill "$NUTPID" 2>/dev/null; wait "$NUTPID" 2>/dev/null || true
    PU=$(UPS_SOURCE=nut UPS_NUT_HOST=127.0.0.1 UPS_NUT_PORT=$NUTP UPS_NAME=ups _lib _power_sample)
    check "power: NUT unreachable reported" false "$(printf '%s' "$PU" | jq -r '.ok')"
fi
check "GET /power when off"             false "$(auth_request GET /power | body_of | jq -r '.enabled')"
check "traefik status: switch facts"    true "$(auth_request GET /traefik/status | body_of | jq -r 'has("authelia_middleware") and has("sablier") and has("authelia")')"
check "deploy: on demand needs Sablier" 409 "$(auth_request POST /templates/demo-tpl/deploy '{"target_stack":"demo","on_demand_services":["demo"]}' | status_of)"
check "deploy: protect needs Authelia"  409 "$(auth_request POST /templates/demo-tpl/deploy '{"target_stack":"demo","authelia_services":["demo"]}' | status_of)"
RB=$(auth_request POST /recovery/bundle '{"passphrase":"smoke-pass-123","copy_remote":false}')
check "recovery: bundle written"        200 "$(printf '%s' "$RB" | status_of)"
RBF=$(printf '%s' "$RB" | body_of | jq -r '.file')
check "recovery: file exists"           yes "$([[ -s "$WORK/.data/recovery/$RBF" ]] && echo yes || echo no)"
check "recovery: checksum beside it"    yes "$([[ -s "$WORK/.data/recovery/$RBF.sha256" ]] && echo yes || echo no)"
check "recovery: listed"                1 "$(auth_request GET /recovery | body_of | jq -r '.bundles | length')"
check "recovery: passphrase not stored" false "$(auth_request GET /recovery | body_of | jq -r '.passphrase_set')"
check "recovery: viewer denied"         403 "$(viewer_request GET /recovery | status_of)"
check "recovery: short passphrase"      400 "$(auth_request POST /recovery/bundle '{"passphrase":"short"}' | status_of)"
printf '# changed after the bundle\n' >> "$WORK/Stacks/demo/docker-compose.yml"
check "recovery: wrong passphrase"      400 "$(auth_request POST /recovery/restore "{\"file\":\"$RBF\",\"passphrase\":\"nope-nope-nope\",\"confirm\":true,\"restart\":false}" | status_of)"
check "recovery: change still there"    yes "$(grep -q 'changed after the bundle' "$WORK/Stacks/demo/docker-compose.yml" && echo yes || echo no)"
RR=$(auth_request POST /recovery/restore "{\"file\":\"$RBF\",\"passphrase\":\"smoke-pass-123\",\"confirm\":true,\"restart\":false}")
check "recovery: restore succeeds"      200 "$(printf '%s' "$RR" | status_of)"
check "recovery: stack file restored"   no "$(grep -q 'changed after the bundle' "$WORK/Stacks/demo/docker-compose.yml" && echo yes || echo no)"
check "recovery: users restored count"  yes "$([[ "$(printf '%s' "$RR" | body_of | jq -r '.users')" -ge 1 ]] && echo yes || echo no)"
check "recovery: pre-restore snapshot"  yes "$(ls "$WORK"/.snapshots/pre-restore-*.tar.gz >/dev/null 2>&1 && echo yes || echo no)"
: > "$WORK/.api-auth/.setup-complete"
check "recovery: setup restore refused when set up" 403 "$(request POST /setup/restore '{"content_b64":"AAAA","passphrase":"smoke-pass-123"}' "${AUTH[@]}" | status_of)"
rm -f "$WORK/.api-auth/.setup-complete"
check "recovery: setup restore rejects junk" 400 "$(request POST /setup/restore '{"content_b64":"AAAA","passphrase":"smoke-pass-123"}' "${AUTH[@]}" | status_of)"
UPB=$(base64 -w0 "$WORK/.data/recovery/$RBF")
check "recovery: upload accepted"       200 "$(auth_request POST /recovery/upload "{\"filename\":\"dcs-recovery-smoke-20260101-000000.tar.gz.enc\",\"content_b64\":\"$UPB\"}" | status_of)"
check "recovery: upload name checked"   400 "$(auth_request POST /recovery/upload '{"filename":"../evil.enc","content_b64":"AAAA"}' | status_of)"
check "recovery: two bundles listed"    2 "$(auth_request GET /recovery | body_of | jq -r '.bundles | length')"
check "secret stored for schedules"     200 "$(auth_request POST /secrets '{"key":"RECOVERY_PASSPHRASE","value":"smoke-pass-123"}' | status_of)"
check "recovery: passphrase stored"     true "$(auth_request GET /recovery | body_of | jq -r '.passphrase_set')"
SID=$(auth_request POST /schedules '{"name":"rb","schedule":"@daily","action":"recovery","target":""}' | body_of | jq -r '.id // .schedule.id // empty' 2>/dev/null)
check "schedule: recovery accepted"     yes "$([[ -n "$SID" ]] && echo yes || echo no)"
check "schedule: recovery runs"         200 "$(auth_request POST "/schedules/$SID/run" | status_of)"
check "recovery: schedule made a bundle" 3 "$(auth_request GET /recovery | body_of | jq -r '.bundles | length')"
[[ -n "$SID" ]] && auth_request DELETE "/schedules/$SID" >/dev/null
check "schedule: dcs-update accepted"   200 "$(auth_request POST /schedules '{"name":"su","schedule":"@weekly","action":"dcs-update","target":"images"}' | status_of)"
check "schedule: dcs-update bad target" 400 "$(auth_request POST /schedules '{"name":"su2","schedule":"@weekly","action":"dcs-update","target":"bogus"}' | status_of)"
for _sid in $(auth_request GET /schedules | body_of | jq -r '.schedules[]? | select(.action=="dcs-update") | .id' 2>/dev/null); do auth_request DELETE "/schedules/$_sid" >/dev/null; done
check "automation: dcs_update accepted" 200 "$(auth_request POST /automations '{"name":"u","trigger_type":"schedule","trigger_value":"@weekly","action_type":"dcs_update","action_target":"images"}' | status_of)"
check "automation: dcs_update bad target" 400 "$(auth_request POST /automations '{"name":"u2","trigger_type":"schedule","trigger_value":"@weekly","action_type":"dcs_update","action_target":"bogus"}' | status_of)"
for _aid in $(auth_request GET /automations | body_of | jq -r '.automations[]? | select(.action_type=="dcs_update") | .id' 2>/dev/null); do auth_request DELETE "/automations/$_aid" >/dev/null; done
check "create user: admin creates"      200 "$(auth_request POST /auth/users '{"username":"bot-smoke","password":"Botpass-1234","role":"admin"}' | status_of)"
check "create user: duplicate refused"  409 "$(auth_request POST /auth/users '{"username":"bot-smoke","password":"Botpass-1234"}' | status_of)"
check "create user: bad name refused"   400 "$(auth_request POST /auth/users '{"username":"x!","password":"Botpass-1234"}' | status_of)"
check "create user: viewer denied"      403 "$(viewer_request POST /auth/users '{"username":"nope-zz","password":"Botpass-1234"}' | status_of)"
check "create user: can sign in"        200 "$(request POST /auth/login '{"username":"bot-smoke","password":"Botpass-1234"}' "${AUTH[@]}" | status_of)"
# sign-ins that overlap (each one also removes the expired sessions): no session is lost or doubled, and the file stays valid JSON
auth_request POST /auth/users '{"username":"race-a","password":"Racepass-1234","role":"user"}' >/dev/null
auth_request POST /auth/users '{"username":"race-b","password":"Racepass-1234","role":"user"}' >/dev/null
for _i in 1 2 3 4 5 6; do
    request POST /auth/login '{"username":"race-a","password":"Racepass-1234"}' "${AUTH[@]}" >/dev/null &
    request POST /auth/login '{"username":"race-b","password":"Racepass-1234"}' "${AUTH[@]}" >/dev/null &
done; wait
check "sign-ins that overlap: the token file is valid"   yes "$(jq -e . "$WORK/.api-auth/tokens.json" >/dev/null 2>&1 && echo yes || echo no)"
check "…each of the two users keeps exactly one session" "1 1" "$(jq -r '[([.[] | select(.username == "race-a")] | length), ([.[] | select(.username == "race-b")] | length)] | join(" ")' "$WORK/.api-auth/tokens.json" 2>/dev/null)"
check "homarr register: validation"     400 "$(auth_request POST /homarr/register '{"name":"","url":"nope"}' | status_of)"
check "homarr register: no Homarr here" 409 "$(auth_request POST /homarr/register '{"name":"Smoke","url":"http://127.0.0.1:1/"}' | status_of)"
check "homarr register: viewer denied"  403 "$(viewer_request POST /homarr/register '{"name":"Smoke","url":"http://127.0.0.1:1/"}' | status_of)"
check "update history answers"          array "$(auth_request GET /system/update/history | body_of | jq -r '.entries | type')"
check "update history: viewer denied"   403 "$(viewer_request GET /system/update/history | status_of)"
auth_request DELETE /secrets/RECOVERY_PASSPHRASE >/dev/null

echo "Discord: payloads, generic webhooks, cooldowns, bot accounts, nuke & reinstall"
check "discord payload: fields"          3 "$(_lib _discord_payload "Plex is unhealthy" "msg" urgent container_unhealthy '{"stack":"media","container":"Plex","status":"unhealthy","event":"x","timestamp":"t","hostname":"h"}' | jq '.embeds[0].fields | length')"
check "discord payload: emoji title"     yes "$(_lib _discord_payload "Plex is unhealthy" "m" default container_unhealthy '{}' | jq -r '.embeds[0].title' | grep -q '^🩺 ' && echo yes || echo no)"
check "discord payload: own emoji kept"  "⚡ x" "$(_lib _discord_payload "⚡ x" "m" default power '{}' | jq -r '.embeds[0].title')"
check "discord payload: urgent is rose"  15942494 "$(_lib _discord_payload "t" "m" urgent deploy_complete '{}' | jq '.embeds[0].color')"
check "discord payload: identity"        "DCS Manager" "$(_lib _discord_payload "t" "m" default test '{}' | jq -r '.username')"
check "discord payload: avatar"          yes "$(_lib _discord_payload "t" "m" default test '{}' | jq -r '.avatar_url' | grep -q '^https://' && echo yes || echo no)"
check "discord payload: no pings"        0 "$(_lib _discord_payload "t" "m" default test '{}' | jq '.allowed_mentions.parse | length')"
check "discord payload: bold identifiers" '**media**' "$(_lib _discord_payload "t" "m" default test '{"stack":"media"}' | jq -r '.embeds[0].fields[0].value')"
check "discord payload: message once"    0 "$(_lib _discord_payload "t" "same" default automation_run '{"message":"same"}' | jq '.embeds[0].fields | length')"
check "webhook body: discord embed"      yes "$(_lib _webhook_body https://discord.com/api/webhooks/1/x deploy "d" | jq -e '.embeds[0].title' >/dev/null && echo yes || echo no)"
check "webhook body: slack text"         yes "$(_lib _webhook_body https://hooks.slack.com/services/x stack_stop "d" | jq -e '.text' >/dev/null && echo yes || echo no)"
check "webhook body: json envelope"      backup_complete "$(_lib _webhook_body https://example.com/hook backup_complete "d" | jq -r '.event')"
check "discord hosts: ptb accepted"      0 "$(_lib _discord_is_webhook https://ptb.discord.com/api/webhooks/1/x; echo $?)"
check "discord hosts: other refused"     1 "$(_lib _discord_is_webhook https://example.com/api/webhooks/1/x; echo $?)"
check "event style: label"               "Stack stopped" "$(_lib _discord_event_style stack_down | cut -d'|' -f3)"
check "event style: audit fallback"      "Login ok" "$(_lib _discord_event_style auth.login_ok | cut -d'|' -f3 | sed 's/Signed in/Login ok/')"
check "cooldown: containers default"     60 "$(_lib _notify_default_cooldown container_unhealthy)"
check "cooldown: updates daily"          1440 "$(_lib _notify_default_cooldown update_available)"
check "cooldown: deploys always"         0 "$(_lib _notify_default_cooldown deploy_complete)"
check "cooldown: env override"           5 "$(NOTIFY_COOLDOWN_MINUTES=5 _lib _notify_default_cooldown container_stopped)"
check "default wording: stopped"         "{container} stopped" "$(_lib eval '_notify_default_templates container_stopped; printf %s "$NT_TITLE"')"
check "rule: cooldown stored"            15 "$(auth_request POST /notifications/rules '{"name":"cd","trigger":"container_stopped","cooldown_minutes":15}' | body_of | jq -r '.cooldown_minutes')"
check "rule: cooldown optional"          null "$(auth_request POST /notifications/rules '{"name":"cd0","trigger":"container_stopped"}' | body_of | jq -r '.cooldown_minutes')"
check "rule: bad cooldown"               400 "$(auth_request POST /notifications/rules '{"name":"cd2","trigger":"container_stopped","cooldown_minutes":"soon"}' | status_of)"
check "config: discord name"             "DCS Manager" "$(auth_request GET /config | body_of | jq -r '.discord_webhook_name')"
check "config: cooldown minutes"         60 "$(auth_request GET /config | body_of | jq -r '.notify_cooldown_minutes')"
check "bot role: may restart"            0 "$(_lib _api_bot_allowed POST /containers/Plex/restart; echo $?)"
check "bot role: may deploy"             0 "$(_lib _api_bot_allowed POST /templates/it-tools/deploy; echo $?)"
check "bot role: may unban"              0 "$(_lib _api_bot_allowed DELETE /crowdsec/decisions/1.2.3.4; echo $?)"
check "bot role: may read audit"         0 "$(_lib _api_bot_allowed GET /audit; echo $?)"
check "bot role: no secrets"             1 "$(_lib _api_bot_allowed GET /secrets; echo $?)"
check "bot role: no user changes"        1 "$(_lib _api_bot_allowed POST /auth/users; echo $?)"
check "bot role: no DCS updates"         1 "$(_lib _api_bot_allowed POST /system/update/apply; echo $?)"
check "bot role: no nuke"                1 "$(_lib _api_bot_allowed POST /containers/Plex/reset; echo $?)"
check "create user: bot role"            created "$(auth_request POST /auth/users '{"username":"bot-role","password":"Botpass-1234","role":"bot"}' | body_of | jq -r 'if .success then "created" else .message end')"
check "create user: bad role"            400 "$(auth_request POST /auth/users '{"username":"bot-x","password":"Botpass-1234","role":"root"}' | status_of)"
BOT1=$(request POST /auth/login '{"username":"bot-role","password":"Botpass-1234"}' "${AUTH[@]}" | body_of | jq -r '.token // empty')
BOT2=$(request POST /auth/login '{"username":"bot-role","password":"Botpass-1234"}' "${AUTH[@]}" | body_of | jq -r '.token // empty')
bot_request() { local m="$1" p="$2" b="${3:-}"; printf '%s %s HTTP/1.1\r\nAuthorization: Bearer %s\r\nContent-Length: %d\r\n\r\n%s' "$m" "$p" "$BOT1" "${#b}" "$b" | env DOCKER_COMPOSE_CMD="${DOCKER_COMPOSE_CMD:-docker compose}" "${AUTH[@]}" "$API" --handle-request 2>/dev/null; }
check "bot: first session survives 2nd" 200 "$(bot_request GET /version | status_of)"
check "bot: second session valid too"   yes "$([[ -n "$BOT2" && "$BOT2" != "$BOT1" ]] && echo yes || echo no)"
check "bot: reads the audit log"        200 "$(bot_request GET /audit | status_of)"
check "bot: secrets refused"            403 "$(bot_request GET /secrets | status_of)"
check "bot: user creation refused"      403 "$(bot_request POST /auth/users '{"username":"x","password":"Botpass-1234"}' | status_of)"
check "bot: nuke refused"               403 "$(bot_request POST /containers/x/reset '{"confirm":"x"}' | status_of)"
check "role change: to bot"             bot "$(auth_request POST /auth/users/bot-smoke/role '{"role":"bot"}' | body_of | jq -r '.role')"
check "role change: last admin kept"    400 "$(auth_request POST /auth/users/admin/role '{"role":"user"}' | status_of)"
check "role change: bad role"           400 "$(auth_request POST /auth/users/bot-smoke/role '{"role":"root"}' | status_of)"
check "role change: unknown user"       404 "$(auth_request POST /auth/users/nobody-here/role '{"role":"bot"}' | status_of)"
check "role change: viewer denied"      403 "$(viewer_request POST /auth/users/bot-smoke/role '{"role":"bot"}' | status_of)"
check "nuke: confirm required"          400 "$(auth_request POST /containers/nope-none/reset '{}' | status_of)"
check "nuke: preview viewer denied"     403 "$(viewer_request GET /containers/nope-none/reset | status_of)"
check "crowdsec alerts: no CrowdSec"    404 "$(auth_request POST /crowdsec/notifications '{}' | status_of)"
check "transitions: first poll silent"  0 "$(HEALTH_TRANSITIONS_FILE=$WORK/hb.json _lib _health_transitions "a b" "c" | wc -l | tr -d ' ')"
check "transitions: a new stop"         "stopped d" "$(HEALTH_TRANSITIONS_FILE=$WORK/hb.json _lib _health_transitions "a b d" "c" | head -1)"
check "transitions: a recovery"         "recovered a" "$(HEALTH_TRANSITIONS_FILE=$WORK/hb.json _lib _health_transitions "b d" "c" | grep recovered)"
check "transitions: newly unhealthy"    "unhealthy e" "$(HEALTH_TRANSITIONS_FILE=$WORK/hb.json _lib _health_transitions "b d" "c e" | grep unhealthy)"
check "transitions: quiet when same"    0 "$(HEALTH_TRANSITIONS_FILE=$WORK/hb.json _lib _health_transitions "b d" "c e" | wc -l | tr -d ' ')"
check "intended: a marked container"    0 "$(INTENDED_FILE=$WORK/intended.json _lib eval '_container_mark_intended Plex; _container_intended Plex'; echo $?)"
check "intended: by its stack"          0 "$(INTENDED_FILE=$WORK/intended.json _lib eval '_container_mark_intended stack:media; _container_intended Radarr media'; echo $?)"
check "intended: unknown container"     1 "$(INTENDED_FILE=$WORK/intended.json _lib _container_intended Nope; echo $?)"
check "event style: container stop"     "Container stopped" "$(_lib _discord_event_style container_stop | cut -d'|' -f3)"
check "event style: recovered"          "Container recovered" "$(_lib _discord_event_style container_recovered | cut -d'|' -f3)"
check "event style: lockout"            "Account locked" "$(_lib _discord_event_style auth.lockout | cut -d'|' -f3)"
check "invite: bot role refused"        400 "$(auth_request POST /auth/invite '{"role":"bot"}' | status_of)"
check "users: profile fields present"   yes "$(auth_request GET /auth/users | body_of | jq -e '.users | type == "array"' >/dev/null && echo yes || echo no)"
auth_request GET /stacks >/dev/null
check "cache: stacks answer kept"       yes "$([[ -s "$WORK/.data/cache/stacks.http" ]] && echo yes || echo no)"
check "cache: served again"             200 "$(auth_request GET /stacks | status_of)"
auth_request POST /stacks/nope-none/start '{}' >/dev/null
check "cache: cleared by a write"       no "$([[ -e "$WORK/.data/cache/stacks.http" ]] && echo yes || echo no)"
check "cache: opt-out honoured"         200 "$(API_RESPONSE_CACHE=false auth_request GET /stacks | status_of)"
_cache_state() { grep -i '^X-DCS-Cache:' | tr -d '\r' | awk '{print $2}'; }
_cache_age()   { echo $(( $(date +%s) - $(stat -c %Y "$WORK/.data/cache/stacks.http" 2>/dev/null || echo 0) )); }
auth_request GET /stacks >/dev/null
check "cache: fresh answer is a hit"    hit "$(auth_request GET /stacks | _cache_state)"
touch -d '-30 seconds' "$WORK/.data/cache/stacks.http"
_st=$(auth_request GET /stacks)
check "cache: stale answer served"      stale "$(printf '%s' "$_st" | _cache_state)"
check "cache: stale answer is 200"      200 "$(printf '%s' "$_st" | status_of)"
check "cache: stale answer carries Age" yes "$(printf '%s' "$_st" | grep -qiE '^Age: 3[0-9]' && echo yes || echo no)"
timeout 10 bash -c "until [[ \$(( \$(date +%s) - \$(stat -c %Y '$WORK/.data/cache/stacks.http' 2>/dev/null || echo 0) )) -lt 5 ]]; do sleep 0.2; done" 2>/dev/null
check "cache: refreshed in background"  yes "$([[ $(_cache_age) -lt 5 ]] && echo yes || echo no)"
check "cache: refresh lock released"    no "$([[ -d "$WORK/.data/cache/stacks.http.lock" ]] && echo yes || echo no)"
touch -d '-1000 seconds' "$WORK/.data/cache/stacks.http"
check "cache: too old is a miss"        miss "$(auth_request GET /stacks | _cache_state)"
check "cache: miss rebuilt the file"    yes "$([[ $(_cache_age) -lt 5 ]] && echo yes || echo no)"
check "ping: public"                    200 "$(request GET /ping '' "${AUTH[@]}" | status_of)"
check "ping: says ok"                   true "$(request GET /ping '' "${AUTH[@]}" | body_of | jq -r '.ok' 2>/dev/null)"
check "ping: names a version"           yes "$([[ -n "$(request GET /ping '' "${AUTH[@]}" | body_of | jq -r '.version // empty' 2>/dev/null)" ]] && echo yes || echo no)"

echo "Proxmox (against a stand-in server)"
# Values live in the install's .env (it is data the API loads on every request; the environment
# never overrides it), so the tests write them there and remove them afterwards.
_envset() { sed -i "/^${1}=/d" "$WORK/.env"; printf '%s=%s\n' "$1" "$2" >> "$WORK/.env"; }
_envdel() { sed -i "/^${1}=/d" "$WORK/.env"; }
check "proxmox: not configured"         false "$(auth_request GET /proxmox/status | body_of | jq -r '.configured' 2>/dev/null)"
check "proxmox: vms need config"        503 "$(auth_request GET /proxmox/vms | status_of)"
check "proxmox: environment reported"   yes "$(auth_request GET /proxmox/status | body_of | jq -e '.environment | has("guest")' >/dev/null 2>&1 && echo yes || echo no)"
check "setup defaults: environment"     yes "$(request GET /setup/defaults '' "${NOAUTH[@]}" | body_of | jq -e '.system.proxmox | has("guest")' >/dev/null 2>&1 && echo yes || echo no)"
_PVE_PORT=$(( 20000 + RANDOM % 20000 ))
MOCK_DENY_ARGS_FILE="$WORK/.data/deny-args" python3 "$ROOT/tests/mock-proxmox.py" "$_PVE_PORT" 'dcs@pve!smoke' 'smoke-secret' "$WORK/.data/pve-mock.json" >/dev/null 2>&1 &
_PVE_PID=$!
timeout 10 bash -c "until curl -s -o /dev/null http://127.0.0.1:$_PVE_PORT/api2/json/version; do sleep 0.2; done" 2>/dev/null
_envset PROXMOX_URL "http://127.0.0.1:$_PVE_PORT"; _envset PROXMOX_TOKEN_ID 'dcs@pve!smoke'; _envset PROXMOX_TOKEN_SECRET 'smoke-secret'; _envset API_RESPONSE_CACHE false
check "proxmox: reachable"              true "$(auth_request GET /proxmox/status | body_of | jq -r '.reachable' 2>/dev/null)"
check "proxmox: version seen"           8.3.0 "$(auth_request GET /proxmox/status | body_of | jq -r '.version' 2>/dev/null)"
check "proxmox: templates dropped"      3 "$(auth_request GET /proxmox/vms | body_of | jq -r '.total' 2>/dev/null)"
check "proxmox: running count"          2 "$(auth_request GET /proxmox/vms | body_of | jq -r '.running' 2>/dev/null)"
check "proxmox: tags split"             media "$(auth_request GET /proxmox/vms | body_of | jq -r '.vms[0].tags[1]' 2>/dev/null)"
check "proxmox: nodes"                  pve "$(auth_request GET /proxmox/nodes | body_of | jq -r '.nodes[0].node' 2>/dev/null)"
check "proxmox: http on 8006 made https" https://192.168.2.12:8006 "$(_lib _pve_norm_url 'http://192.168.2.12:8006/')"
check "proxmox: http elsewhere kept"    http://pve.lan "$(_lib _pve_norm_url 'http://pve.lan/')"
check "proxmox: browser address cleaned" https://pve.lan:8006 "$(_lib _pve_norm_url 'pve.lan:8006/#v1:0:18:4:::')"
auth_request POST /config "{\"PROXMOX_URL\":\"http://127.0.0.1:$_PVE_PORT/#v1:0:18\"}" >/dev/null
check "proxmox: saved address cleaned"  "http://127.0.0.1:$_PVE_PORT" "$(grep -m1 '^PROXMOX_URL=' "$WORK/.env" | cut -d= -f2- | tr -d "\"'")"
check "proxmox: reachable after the save" true "$(auth_request GET /proxmox/status | body_of | jq -r '.reachable' 2>/dev/null)"
check "setup defaults: the link is known" true "$(request GET /setup/defaults '' "${NOAUTH[@]}" | body_of | jq -r '.system.proxmox.linked' 2>/dev/null)"
check "setup defaults: linked means hub"  hub "$(request GET /setup/defaults '' "${NOAUTH[@]}" | body_of | jq -r '.system.fleet_role' 2>/dev/null)"
_envset FLEET_ROLE member
check "setup defaults: setup.sh's role"   member "$(request GET /setup/defaults '' "${NOAUTH[@]}" | body_of | jq -r '.system.fleet_role' 2>/dev/null)"
_envdel FLEET_ROLE
check "setup defaults: the account's group" "$(id -g "$(id -un)")" "$(request GET /setup/defaults '' "${NOAUTH[@]}" | body_of | jq -r '.system.pgid' 2>/dev/null)"
check "provision defaults: the node's size" "16 64" "$(auth_request GET /fleet/provision/defaults | body_of | jq -r '"\(.capacity.cores) \(.capacity.memory_gb)"' 2>/dev/null)"
check "provision defaults: firewall state" yes "$(auth_request GET /fleet/provision/defaults | body_of | jq -e '.hub_firewall | has("active") and has("open")' >/dev/null 2>&1 && echo yes || echo no)"
check "proxmox: vm detail"              media-vm "$(auth_request GET /proxmox/vms/pve/qemu/100 | body_of | jq -r '.name' 2>/dev/null)"
check "proxmox: bad type refused"       400 "$(auth_request GET /proxmox/vms/pve/disk/100 | status_of)"
check "proxmox: bad action refused"     400 "$(auth_request POST /proxmox/vms/pve/lxc/200/explode '{}' | status_of)"
# --- the VM this DCS runs in is tagged in Proxmox: dcs, and hub on the hub ---------------------------------------------
_pve_put() { curl -s -o /dev/null -X PUT -H "Authorization: PVEAPIToken=dcs@pve!smoke=smoke-secret" --data-urlencode "$2" "http://127.0.0.1:$_PVE_PORT/api2/json/nodes/pve/qemu/$1/config"; }
_envset FLEET_IDENTITY_UUID 11111111-2222-3333-4444-555555555555        # this server "is" VM 100 (media-vm)
SELF=$(auth_request GET /proxmox/self | body_of)
check "self tags: found by its SMBIOS id"       "100 uuid" "$(jq -r '"\(.guest.vmid) \(.guest.matched_by)"' <<< "$SELF")"
check "self tags: a linked DCS is a hub"        "dcs hub" "$(jq -r '.wanted | join(" ")' <<< "$SELF")"
check "self tags: reading writes nothing"       "docker media" "$(auth_request GET /proxmox/vms | body_of | jq -r '.vms[] | select(.vmid == 100) | .tags | join(" ")')"
check "self tags: what is missing"              "dcs hub" "$(jq -r '.missing | join(" ")' <<< "$SELF")"
TAGGED=$(auth_request POST /proxmox/self/tag '{}' | body_of)
check "self tags: the hub's VM is tagged"       "true true" "$(jq -r '"\(.tagged) \(.changed)"' <<< "$TAGGED")"
check "self tags: it says what it did"          "Tagged VM 100 (media-vm) in Proxmox: dcs, hub" "$(jq -r '.message' <<< "$TAGGED")"
check "self tags: the old tags stay"            "docker media dcs hub" "$(auth_request GET /proxmox/vms | body_of | jq -r '.vms[] | select(.vmid == 100) | .tags | join(" ")')"
check "self tags: again changes nothing"        "true false" "$(auth_request POST /proxmox/self/tag '{}' | body_of | jq -r '"\(.tagged) \(.changed)"')"
check "self tags: a viewer may not tag"         403 "$(viewer_request POST /proxmox/self/tag '{}' | status_of)"
_envset FLEET_ROLE standalone
check "self tags: a standalone DCS wants dcs only" "dcs" "$(auth_request GET /proxmox/self | body_of | jq -r '.wanted | join(" ")')"
_envdel FLEET_ROLE
_envset FLEET_IDENTITY_UUID 22222222-3333-4444-5555-666666666666        # VM 101: the token may not change it
DENIED=$(auth_request POST /proxmox/self/tag '{}' | body_of)
check "self tags: a token without the right is told" "false true" "$(jq -r '"\(.tagged) \(.message | test("VM.Config.Options"))"' <<< "$DENIED")"
check "self tags: nothing was written then"     "docker" "$(auth_request GET /proxmox/vms | body_of | jq -r '.vms[] | select(.vmid == 101) | .tags | join(" ")')"
_envset FLEET_IDENTITY_UUID 99999999-9999-9999-9999-999999999999        # a machine that is no guest of this Proxmox
check "self tags: an unknown machine is left alone" "null false" "$(auth_request POST /proxmox/self/tag '{}' | body_of | jq -r '"\(.guest) \(.tagged)"')"
# the wizard's last call does it as well, and never fails because of it
_pve_put 100 'tags=docker;media'
_envset FLEET_IDENTITY_UUID 11111111-2222-3333-4444-555555555555
rm -f "$WORK/.api-auth/.setup-complete"
WZ=$(auth_request POST /setup/complete '{}' | body_of)
check "wizard: the hub's VM is tagged at the end" "true dcs,hub" "$(jq -r '"\(.proxmox_tag.tagged) \(.proxmox_tag.tags[-2:] | join(","))"' <<< "$WZ")"
check "wizard: setup is complete"               true "$(jq -r '.initialized' <<< "$WZ")"
_envset FLEET_IDENTITY_UUID 99999999-9999-9999-9999-999999999999
rm -f "$WORK/.api-auth/.setup-complete"
check "wizard: a machine Proxmox does not know still completes" "true false" "$(auth_request POST /setup/complete '{}' | body_of | jq -r '"\(.initialized) \(.proxmox_tag.tagged)"')"
_envdel FLEET_IDENTITY_UUID; _pve_put 100 'tags=docker;media'
check "proxmox: reset is qemu-only"     400 "$(auth_request POST /proxmox/vms/pve/lxc/200/reset '{}' | status_of)"
check "proxmox: balloon is qemu-only"   400 "$(auth_request POST /proxmox/vms/pve/lxc/200/balloon '{}' | status_of)"
_BL=$(auth_request POST /proxmox/vms/pve/qemu/100/balloon '{}')
check "proxmox: balloon set"            200 "$(printf '%s' "$_BL" | status_of)"
check "proxmox: balloon keeps three quarters" '7680 8192' "$(printf '%s' "$_BL" | body_of | jq -r '"\(.balloon) \(.memory)"' 2>/dev/null)"
check "proxmox: balloon in the config"  7680 "$(auth_request GET /proxmox/vms/pve/qemu/100 | body_of | jq -r '.balloon' 2>/dev/null)"
check "proxmox: start a container"      true "$(auth_request POST /proxmox/vms/pve/lxc/200/start '{}' | body_of | jq -r '.success' 2>/dev/null)"
check "proxmox: upid returned"          yes "$([[ "$(auth_request POST /proxmox/vms/pve/qemu/101/reboot '{}' | body_of | jq -r '.upid' 2>/dev/null)" == UPID:* ]] && echo yes || echo no)"
check "proxmox: action audited"         yes "$(grep -q '"action":"proxmox_vm_start"' "$WORK/.data/audit.jsonl" 2>/dev/null && echo yes || echo no)"
check "proxmox: marked intended"        true "$(auth_request GET /proxmox/vms | body_of | jq -r '.vms[] | select(.vmid == 200) | .intended' 2>/dev/null)"
check "proxmox: tasks listed"           qmreboot "$(auth_request GET /proxmox/tasks | body_of | jq -r '.tasks[0].type' 2>/dev/null)"
check "proxmox: test with values"       true "$(auth_request POST /proxmox/test "{\"url\":\"http://127.0.0.1:$_PVE_PORT\",\"token_id\":\"dcs@pve!smoke\",\"token_secret\":\"smoke-secret\"}" | body_of | jq -r '.reachable' 2>/dev/null)"
check "proxmox: bad token explained"    false "$(auth_request POST /proxmox/test "{\"url\":\"http://127.0.0.1:$_PVE_PORT\",\"token_id\":\"dcs@pve!smoke\",\"token_secret\":\"nope\"}" | body_of | jq -r '.reachable' 2>/dev/null)"
check "proxmox: bad token hint"         yes "$(auth_request POST /proxmox/test "{\"url\":\"http://127.0.0.1:$_PVE_PORT\",\"token_id\":\"dcs@pve!smoke\",\"token_secret\":\"nope\"}" | body_of | jq -r '.error' 2>/dev/null | grep -q 'rejected the API token' && echo yes || echo no)"
check "proxmox: viewer may look"        200 "$(viewer_request GET /proxmox/status | status_of)"
check "proxmox: viewer may not power"   403 "$(viewer_request POST /proxmox/vms/pve/lxc/200/stop '{}' | status_of)"
check "proxmox: bot may power"          0 "$(_lib _api_bot_allowed POST /proxmox/vms/pve/lxc/200/stop; echo $?)"

echo "Fleet: a hub and a member (two real listeners on loopback)"
# The hub is this WORK copy, also started as a listener; the member is a second copy. Both
# run with auth on so the hub really logs in. Stopped with --stop at the end (and on exit).
HUB_PORT=$(( 20000 + RANDOM % 20000 )); FLEET_PORT=$(( 20000 + RANDOM % 20000 ))
[[ "$FLEET_PORT" == "$HUB_PORT" ]] && FLEET_PORT=$(( FLEET_PORT + 1 ))
MWORK="$WORK-member"; PWORK="$WORK-pending"
rm -rf "$MWORK" "$PWORK"; cp -r "$WORK" "$MWORK"
_fleet_stop_listeners() { for d in "$WORK" "$MWORK"; do [[ -f "$d/.data/api-server.pid" ]] && (cd "$d" && "$d/.scripts/api-server.sh" --stop >/dev/null 2>&1); done; return 0; }
trap '_fleet_stop_listeners; rm -rf "$WORK" "$MWORK" "$PWORK"' EXIT
_menvset() { sed -i "/^${1}=/d" "$MWORK/.env"; printf '%s=%s\n' "$1" "$2" >> "$MWORK/.env"; }
_mlib() { local -a _c=("$@"); ( set --; cd "$MWORK" && source "$MWORK/.scripts/api-server.sh" >/dev/null 2>&1; "${_c[@]}" ) 2>/dev/null; }
_envset API_AUTH_ENABLED true; _envset FLEET_SCAN_PORTS "$FLEET_PORT"; _envset API_PORT "$HUB_PORT"
_menvset API_AUTH_ENABLED true; _menvset API_PORT "$FLEET_PORT"; _menvset SERVER_NAME "Media VM"
sed -i '/^PROXMOX_/d;/^FLEET_SCAN_PORTS=/d' "$MWORK/.env"
rm -f "$MWORK/.data/fleet.json" "$MWORK/.data/api-server.pid" "$WORK/.data/fleet.json"
printf '3.8.99\n' > "$MWORK/VERSION"   # an older member: the hub brings it to its own version further down
(cd "$WORK"  && setsid nohup "$API" --bind 127.0.0.1 --port "$HUB_PORT" > "$WORK/logs/hub-listener.log" 2>&1 < /dev/null &)
(cd "$MWORK" && FLEET_IDENTITY_UUID=11111111-2222-3333-4444-555555555555 setsid nohup "$MWORK/.scripts/api-server.sh" --bind 127.0.0.1 --port "$FLEET_PORT" > "$MWORK/logs/member-listener.log" 2>&1 < /dev/null &)
timeout 30 bash -c "until curl -s -m 1 http://127.0.0.1:$HUB_PORT/ping | grep -q '\"ok\"' && curl -s -m 1 http://127.0.0.1:$FLEET_PORT/ping | grep -q '\"ok\"'; do sleep 0.3; done" 2>/dev/null
check "fleet: hub listener up"          yes "$(curl -s -m 2 http://127.0.0.1:$HUB_PORT/ping | jq -r '.ok' 2>/dev/null | sed 's/true/yes/')"
check "fleet: stream answers with metrics"     yes "$(curl -sN -m 4 "http://127.0.0.1:$HUB_PORT/stream?token=$TOKEN&fleet=1" 2>/dev/null | grep -q '^event: metrics' && echo yes || echo no)"
check "fleet: stream for one member answers"   yes "$(curl -sN -m 4 "http://127.0.0.1:$HUB_PORT/stream?token=$TOKEN&member=nope-zz" 2>/dev/null | grep -q '^event: metrics' && echo yes || echo no)"
check "fleet: member listener up"       yes "$(curl -s -m 2 http://127.0.0.1:$FLEET_PORT/ping | jq -r '.ok' 2>/dev/null | sed 's/true/yes/')"
MTOKEN=$(curl -s -m 5 -X POST "http://127.0.0.1:$FLEET_PORT/auth/login" -H 'Content-Type: application/json' -d '{"username":"admin","password":"correct horse battery"}' | jq -r '.token // empty' 2>/dev/null)
member_request() { local m="$1" p="$2" b="${3:-}"; curl -s -m 20 -X "$m" "http://127.0.0.1:$FLEET_PORT$p" -H "Authorization: Bearer $MTOKEN" -H 'Content-Type: application/json' ${b:+-d "$b"}; }
check "fleet: member login"             yes "$([[ ${#MTOKEN} -ge 32 ]] && echo yes || echo no)"
check "fleet: standalone at first"      standalone "$(auth_request GET /fleet/status | body_of | jq -r '.role' 2>/dev/null)"
check "fleet: identity has ips"         true "$(member_request GET /fleet/identity | jq -r '.ips | type == "array"' 2>/dev/null)"
JT=$(auth_request POST /fleet/join-tokens '{"ttl_hours":1}' | body_of | jq -r '.token // empty' 2>/dev/null)
check "fleet: join code minted"         yes "$([[ "$JT" =~ ^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$ ]] && echo yes || echo no)"
check "fleet: code lists"               1 "$(auth_request GET /fleet/join-tokens | body_of | jq -r '.tokens | length' 2>/dev/null)"
check "fleet: role hub with a code"     hub "$(auth_request GET /fleet/status | body_of | jq -r '.role' 2>/dev/null)"
check "fleet: viewer cannot see codes"  403 "$(viewer_request GET /fleet/join-tokens | status_of)"
check "fleet: bad code refused"         403 "$(request POST /fleet/join '{"token":"NOPE-NOPE-NOPE","url":"http://127.0.0.1:1","username":"admin","password":"x"}' "${AUTH[@]}" | status_of)"
JOIN_OUT=$(cd "$MWORK" && FLEET_IDENTITY_UUID=11111111-2222-3333-4444-555555555555 DCS_MEMBER_URL="http://127.0.0.1:$FLEET_PORT" "$MWORK/.scripts/api-server.sh" --join-hub "http://127.0.0.1:$HUB_PORT" "$JT" media-vm 2>&1)
check "fleet: member joined via CLI"    yes "$(grep -q '^✓ Joined' <<< "$JOIN_OUT" && echo yes || { echo no; echo "$JOIN_OUT" | tail -3 >&2; })"
check "fleet: one member"               1 "$(auth_request GET /fleet/members | body_of | jq -r '.total' 2>/dev/null)"
MID=$(auth_request GET /fleet/members | body_of | jq -r '.members[0].id' 2>/dev/null)
check "fleet: member id from name"      media-vm "$MID"
check "fleet: matched by SMBIOS uuid"   uuid "$(auth_request GET /fleet/members | body_of | jq -r '.members[0].matched_by' 2>/dev/null)"
check "fleet: mapped to VM 100"         100 "$(auth_request GET /fleet/members | body_of | jq -r '.members[0].vmid' 2>/dev/null)"
check "fleet: hub account is dcs-hub"   dcs-hub "$(auth_request GET /fleet/members | body_of | jq -r '.members[0].username' 2>/dev/null)"
check "fleet: password in secret store" yes "$(_lib secrets_exists FLEET_MEMBER_MEDIA_VM_PASSWORD && echo yes || echo no)"
check "fleet: member knows its hub"     member "$(member_request GET /fleet/status | jq -r '.role' 2>/dev/null)"
check "fleet: member records vmid"      100 "$(member_request GET /fleet/status | jq -r '.hub.vmid' 2>/dev/null)"
# events flow to the hub: the join handed the member a relay token, the hub keeps it apart from the member records
check "relay: member holds a token"     yes "$(jq -e '.hub.relay_token | length >= 24' "$MWORK/.data/fleet.json" >/dev/null 2>&1 && echo yes || echo no)"
check "relay: hub keeps it apart"       yes "$(jq -e --arg id "$MID" '.[$id] | length >= 24' "$WORK/.data/fleet-relay.json" >/dev/null 2>&1 && echo yes || echo no)"
check "relay: status hides the token"   null "$(member_request GET /fleet/status | jq -r '.hub.relay_token' 2>/dev/null)"
check "relay: members API hides it"     yes "$(auth_request GET /fleet/members | body_of | grep -q relay_token && echo no || echo yes)"
check "relay: bad token refused"        403 "$(request POST /fleet/relay '{"token":"nope-nope-nope-nope-nope-nope","event":"stack_stopped"}' | status_of)"
_RT=$(jq -r '.hub.relay_token' "$MWORK/.data/fleet.json" 2>/dev/null)
check "relay: event accepted"           true "$(request POST /fleet/relay "{\"token\":\"$_RT\",\"event\":\"stack_stopped\",\"context\":{\"stack\":\"demo\",\"status\":\"stopped\"}}" | body_of | jq -r '.success' 2>/dev/null)"
check "relay: hub activity names the VM" yes "$(grep 'fleet_event' "$WORK/.data/audit.jsonl" 2>/dev/null | tail -1 | grep -q 'from VM media-vm' && echo yes || echo no)"
check "relay: odd event name refused"   400 "$(request POST /fleet/relay "{\"token\":\"$_RT\",\"event\":\"Not Valid\"}" | status_of)"
# a member's context is data: the keys the hub sets itself never come through, and the audit line stays short
check "relay: reserved keys dropped"    "stack=demo" "$(_lib _fleet_relay_args '{"context":{"hostname":"evil","member":"x","relayed":"0","fingerprint":"f","timestamp":"t","stack":"demo"}}' | tr '\n' ' ' | sed 's/ $//')"
request POST /fleet/relay "{\"token\":\"$_RT\",\"event\":\"stack_stopped\",\"context\":{\"stack\":\"$(printf 'x%.0s' $(seq 1 300))\"}}" >/dev/null
check "relay: long values cut in the audit line" yes "$([[ $(tail -1 "$WORK/.data/audit.jsonl" | jq -r '.detail' 2>/dev/null | wc -c) -lt 200 ]] && echo yes || echo no)"
# the hub's own hostname stays on a notification whatever a context says (the notifier is stubbed to write its fields)
[[ -f "$WORK/.api-auth/notifications.json" ]] && cp "$WORK/.api-auth/notifications.json" "$WORK/.api-auth/notifications.json.smoke"
printf '{"rules":[{"id":"smoke-relay","enabled":true,"trigger":"stack_stopped","target":"*","cooldown_minutes":0,"title_template":"{stack} on {hostname}","message_template":"{message}"}],"history":[]}\n' > "$WORK/.api-auth/notifications.json"
rm -f "$WORK/.data/smoke-fields.json"
_lib eval "_ntfy_endpoint() { printf 'http://ntfy.invalid/smoke'; }; _notify_send() { printf '%s' \"\$6\" > '$WORK/.data/smoke-fields.json'; printf 200; }; _fire_notifications stack_stopped hostname=evil stack=demo; sleep 1"
check "relay: hostname cannot be spoofed" "$(hostname)" "$(jq -r '.hostname' "$WORK/.data/smoke-fields.json" 2>/dev/null)"
if [[ -f "$WORK/.api-auth/notifications.json.smoke" ]]; then mv -f "$WORK/.api-auth/notifications.json.smoke" "$WORK/.api-auth/notifications.json"; else rm -f "$WORK/.api-auth/notifications.json"; fi
# an event that came through a relay is not relayed again (two hubs that joined each other would bounce it for ever)
_EV0=$(grep -c '"action":"fleet_event"' "$WORK/.data/audit.jsonl" 2>/dev/null); _EV0=${_EV0:-0}
_mlib eval '_fire_notifications stack_stopped relayed=1 stack=demo; sleep 1'
check "relay: a relayed event stays put" "$_EV0" "$(grep -c '"action":"fleet_event"' "$WORK/.data/audit.jsonl" 2>/dev/null)"
_mlib eval '_fire_notifications stack_stopped stack=demo; sleep 1'
check "relay: a fresh event reaches the hub" $((_EV0 + 1)) "$(grep -c '"action":"fleet_event"' "$WORK/.data/audit.jsonl" 2>/dev/null)"
# a member may post 30 events a minute; the 31st is refused
rm -f "$WORK/.data/rates/relay-$MID"
_RL_OK=0; _RL_LAST=""
for _i in $(seq 1 31); do _RL_LAST=$(request POST /fleet/relay "{\"token\":\"$_RT\",\"event\":\"stack_stopped\",\"context\":{\"stack\":\"demo\"}}" | status_of); [[ "$_RL_LAST" == 200 ]] && _RL_OK=$((_RL_OK + 1)); done
check "relay: 30 events a minute pass"  30 "$_RL_OK"
check "relay: the 31st is refused"      429 "$_RL_LAST"
rm -f "$WORK/.data/rates/relay-$MID"
# a hub does not join its own member; a member does not take its own hub as a member
check "join: a hub refuses its member as hub" yes "$(_lib eval "_fleet_join_hub http://127.0.0.1:$FLEET_PORT AAAA-AAAA-AAAA >/dev/null 2>&1; printf '%s' \"\$FLEET_JOIN_ERR\"" | grep -q 'member of this server' && echo yes || echo no)"
jq '.join_tokens += [{"token":"SMOK-SMOK-SMOK","created_at":0,"expires_at":4102444800,"created_by":"smoke","uses":0}]' "$MWORK/.data/fleet.json" > "$MWORK/.data/fleet.json.tmp" && mv -f "$MWORK/.data/fleet.json.tmp" "$MWORK/.data/fleet.json"
check "join: a member refuses its hub as member" 409 "$(_mlib handle_fleet_join "{\"token\":\"SMOK-SMOK-SMOK\",\"url\":\"http://127.0.0.1:$HUB_PORT\",\"username\":\"admin\",\"password\":\"x\"}" | status_of)"
jq 'del(.join_tokens[] | select(.token == "SMOK-SMOK-SMOK"))' "$MWORK/.data/fleet.json" > "$MWORK/.data/fleet.json.tmp" && mv -f "$MWORK/.data/fleet.json.tmp" "$MWORK/.data/fleet.json"
check "fleet: dcs-hub is a service acct" true "$(jq -r '[.[] | select(.username == "dcs-hub")] | .[0].service' "$MWORK/.api-auth/users.json" 2>/dev/null)"
check "fleet: join audited on hub"      yes "$(grep -q 'fleet_member_joined' "$WORK/.data/audit.jsonl" 2>/dev/null && echo yes || echo no)"
check "fleet: join audited on member"   yes "$(grep -q 'fleet_joined_hub' "$MWORK/.data/audit.jsonl" 2>/dev/null && echo yes || echo no)"
check "fleet: proxy lists stacks"       demo "$(auth_request GET "/fleet/members/$MID/api/stacks" | body_of | jq -r '.stacks[0].name' 2>/dev/null)"
check "fleet: proxy passes status"      404 "$(auth_request GET "/fleet/members/$MID/api/stacks/nope-none" | status_of)"
check "fleet: proxy keeps query"        yes "$(auth_request GET "/fleet/members/$MID/api/templates?category=media" | body_of | jq -e '.templates | type == "array"' >/dev/null 2>&1 && echo yes || echo no)"
check "fleet: proxy blocks auth"        400 "$(auth_request GET "/fleet/members/$MID/api/auth/users" | status_of)"
check "fleet: proxy unknown member"     404 "$(auth_request GET "/fleet/members/nobody/api/stacks" | status_of)"
check "homarr card: a VM's container asked"  404 "$(auth_request GET "/containers/nope-zz/homarr?member=$MID" | status_of)"
check "homarr card: unknown VM"              404 "$(auth_request GET "/containers/nope-zz/homarr?member=nobody" | status_of)"
check "homarr card: bad VM id"               400 "$(auth_request GET "/containers/nope-zz/homarr?member=Bad_Id" | status_of)"
check "homarr card: never forwarded"         1 "$(_lib _fleet_forward_if_remote GET /containers/IT-Tools/homarr ''; echo $?)"
check "theme: never forwarded"               1 "$(_lib _fleet_forward_if_remote GET /containers/IT-Tools/theme ''; echo $?)"
printf '%s' '{"members":[{"id":"vm-a","name":"vm-a","vmid":7,"url":"http://10.9.8.7:9876","reachable":true,"containers":[{"name":"web","ports":"0.0.0.0:8080->80/tcp"}]}]}' > "$WORK/snap-test.json"
check "containers: a VM's row says where it is" "vm-a 10.9.8.7" "$(FLEET_SNAPSHOT="$WORK/snap-test.json" _lib _fleet_remote_containers_json | jq -r '.[0] | "\(.member) \(.member_host)"' 2>/dev/null)"
rm -f "$WORK/snap-test.json"
check "theme: a VM container asked"          false "$(auth_request GET "/containers/nope-zz/theme?member=$MID" | body_of | jq -r '.routed' 2>/dev/null)"
check "fleet: viewer may read proxy"    200 "$(viewer_request GET "/fleet/members/$MID/api/stacks" | status_of)"
check "fleet: viewer proxy inner denied" 403 "$(viewer_request GET "/fleet/members/$MID/api/secrets" | status_of)"
check "fleet: viewer cannot post proxy" 403 "$(viewer_request POST "/fleet/members/$MID/api/stacks/demo/restart" '{}' | status_of)"
check "fleet: bot may drive members"    0 "$(_lib _api_bot_allowed POST "/fleet/members/$MID/api/stacks/demo/start"; echo $?)"
check "fleet: overview reaches member"  true "$(auth_request GET /fleet/overview | body_of | jq -r '.members[0].reachable' 2>/dev/null)"
check "fleet: overview counts stacks"   yes "$([[ "$(auth_request GET /fleet/overview | body_of | jq -r '.totals.stacks' 2>/dev/null)" -ge 1 ]] && echo yes || echo no)"
check "fleet: overview names member"    media-vm "$(auth_request GET /fleet/overview | body_of | jq -r '.members[0].name' 2>/dev/null)"
# a hub's badges add the VM's images, networks and volumes to its own: the overview carries them, per member and in the totals
_OV=$(auth_request GET /fleet/overview | body_of)
check "fleet: overview carries the VM's Docker counts" "number number number" "$(jq -r '[.totals.images, .totals.networks, .totals.volumes] | map(type) | join(" ")' <<< "$_OV" 2>/dev/null)"
check "fleet: …the same the VM reports itself"        "$(auth_request GET "/fleet/members/$MID/api/status" | body_of | jq -r '"\(.docker.images) \(.docker.networks) \(.docker.volumes)"' 2>/dev/null)" "$(jq -r '"\(.totals.images) \(.totals.networks) \(.totals.volumes)"' <<< "$_OV" 2>/dev/null)"
# the Maintenance page's three questions, answered by the hub for the whole fleet in one call each
_MR=$(auth_request GET '/maintenance/report?fleet=1' | body_of)
check "maintenance: fleet report merged" true "$(jq -r '.fleet == true and (.totals.containers.total | type) == "number" and (.members | length) == 2 and .members[0].id == null and .members[1].id == "'"$MID"'" and .members[1].ok == true' <<< "$_MR" 2>/dev/null)"
check "maintenance: fleet sizes add up"  yes "$(jq -r '.totals.app_data_size' <<< "$_MR" 2>/dev/null | grep -qE '^([0-9.]+ [KMGTP]?B|N/A)$' && echo yes || echo no)"
check "maintenance: fleet orphans tagged" true "$(auth_request GET '/maintenance/orphans?fleet=1' | body_of | jq -r '.fleet == true and (.containers | type) == "array" and (.images | type) == "array" and (.members | length) == 2 and ([.members[] | .ok] | all)' 2>/dev/null)"
_MD=$(auth_request GET '/maintenance/disk?fleet=1' | body_of)
check "maintenance: fleet disk merged"   true "$(jq -r '.fleet == true and (.stack_sizes | type) == "array" and (.docker_df | type) == "array" and (.total_app_data | type) == "string" and (.members | length) == 2' <<< "$_MD" 2>/dev/null)"
check "maintenance: fleet rows say where" true "$(jq -r '[.stack_sizes[] | .member] | all(. == null or . == "'"$MID"'")' <<< "$_MD" 2>/dev/null)"
check "maintenance: plain report unchanged" true "$(auth_request GET /maintenance/report | body_of | jq -r 'has("fleet") | not' 2>/dev/null)"
check "maintenance: viewer may read fleet" 200 "$(viewer_request GET '/maintenance/report?fleet=1' | status_of)"
# a shell inside a VM, opened by the hub: its own Terminal session unlocks it, its ssh key carries the command
check "vm terminal: status is an admin's" 403 "$(viewer_request GET "/fleet/members/$MID/terminal" | status_of)"
check "vm terminal: no key yet"          false "$(auth_request GET "/fleet/members/$MID/terminal" | body_of | jq -r '.available' 2>/dev/null)"
check "vm terminal: reason given"        yes "$(auth_request GET "/fleet/members/$MID/terminal" | body_of | jq -r '.reason' 2>/dev/null | grep -q 'ssh key' && echo yes || echo no)"
check "vm terminal: unknown member"      404 "$(auth_request GET "/fleet/members/nobody/terminal" | status_of)"
check "vm terminal: exec needs a session" 401 "$(auth_request POST "/fleet/members/$MID/terminal/exec" '{"command":"id"}' | status_of)"
check "vm terminal: viewer cannot exec"  403 "$(viewer_request POST "/fleet/members/$MID/terminal/exec" '{"command":"id","terminal_token":"x"}' | status_of)"
_TT=smoketermtoken0123456789abcdef0123456789abcdef; _NOW=$(date +%s)
printf '{"sessions":[{"token":"%s","username":"%s","created_at":%s,"expires_at":%s,"auth_method":"smoke"}]}\n' "$_TT" "$(id -un)" "$_NOW" $((_NOW + 3600)) > "$WORK/.api-auth/terminal-sessions.json"
check "vm terminal: exec unknown member" 404 "$(auth_request POST "/fleet/members/nobody/terminal/exec" "{\"command\":\"id\",\"terminal_token\":\"$_TT\"}" | status_of)"
check "vm terminal: exec needs a command" 400 "$(auth_request POST "/fleet/members/$MID/terminal/exec" "{\"terminal_token\":\"$_TT\"}" | status_of)"
check "vm terminal: the guard applies"   403 "$(auth_request POST "/fleet/members/$MID/terminal/exec" "{\"command\":\"rm -rf /\",\"terminal_token\":\"$_TT\"}" | status_of)"
check "vm terminal: traversal refused"   400 "$(auth_request POST "/fleet/members/$MID/terminal/exec" "{\"command\":\"id\",\"cwd\":\"/tmp/../etc\",\"terminal_token\":\"$_TT\"}" | status_of)"
check "vm terminal: exec needs the key"  409 "$(auth_request POST "/fleet/members/$MID/terminal/exec" "{\"command\":\"id\",\"terminal_token\":\"$_TT\"}" | status_of)"
# with a key and an ssh that runs the command here: the answer carries the output, the exit code and the directory
mkdir -p "$WORK/.data/fleet-ssh"; printf 'smoke\n' > "$WORK/.data/fleet-ssh/id_ed25519"
printf '#!/bin/bash\n# the smoke ssh: skip the options and the user@host, run the command here\nwhile [[ $# -gt 0 ]]; do case "$1" in -i|-o) shift 2 ;; *@*) shift; break ;; *) shift ;; esac; done\nexec bash -c "$*"\n' > "$WORK/fake-ssh"; chmod +x "$WORK/fake-ssh"
_VX=$(FLEET_SSH_CMD="$WORK/fake-ssh" auth_request POST "/fleet/members/$MID/terminal/exec" "{\"command\":\"echo hello-from-vm; exit 3\",\"terminal_token\":\"$_TT\"}" | body_of)
check "vm terminal: output comes back"   hello-from-vm "$(jq -r '.output' <<< "$_VX" 2>/dev/null)"
check "vm terminal: exit code kept"      3 "$(jq -r '.exit_code' <<< "$_VX" 2>/dev/null)"
check "vm terminal: answer says where"   "$MID" "$(jq -r 'select(.success == false) | .member' <<< "$_VX" 2>/dev/null)"
check "vm terminal: cwd honoured"        "$WORK" "$(FLEET_SSH_CMD="$WORK/fake-ssh" auth_request POST "/fleet/members/$MID/terminal/exec" "{\"command\":\"pwd\",\"cwd\":\"$WORK\",\"terminal_token\":\"$_TT\"}" | body_of | jq -r '.output' 2>/dev/null)"
check "vm terminal: bad cwd reported"    2 "$(FLEET_SSH_CMD="$WORK/fake-ssh" auth_request POST "/fleet/members/$MID/terminal/exec" "{\"command\":\"pwd\",\"cwd\":\"/nope/none\",\"terminal_token\":\"$_TT\"}" | body_of | jq -r '.exit_code' 2>/dev/null)"
check "vm terminal: home is the default" "$HOME" "$(FLEET_SSH_CMD="$WORK/fake-ssh" auth_request POST "/fleet/members/$MID/terminal/exec" "{\"command\":\"pwd\",\"terminal_token\":\"$_TT\"}" | body_of | jq -r '.cwd' 2>/dev/null)"
check "vm terminal: audited with the VM" yes "$(grep -q "member=$MID" "$WORK/.api-auth/terminal-audit.log" 2>/dev/null && echo yes || echo no)"
check "vm terminal: history shows it"    yes "$(auth_request GET /terminal/history | body_of | jq -r '.commands[0]' 2>/dev/null | grep -q "member=$MID" && echo yes || echo no)"
check "vm terminal: status live"         true "$(FLEET_SSH_CMD="$WORK/fake-ssh" auth_request GET "/fleet/members/$MID/terminal" | body_of | jq -r '.available' 2>/dev/null)"
rm -rf "$WORK/.data/fleet-ssh" "$WORK/fake-ssh" "$WORK/.api-auth/terminal-sessions.json" "$WORK/.api-auth/terminal-rate.log"
check "fleet: scan finds the member"    "http://127.0.0.1:$FLEET_PORT" "$(auth_request GET /fleet/discover | body_of | jq -r '.guests[] | select(.vmid == 100) | .dcs.url' 2>/dev/null)"
check "fleet: scan links the guest"     "$MID" "$(auth_request GET /fleet/discover | body_of | jq -r '.guests[] | select(.vmid == 100) | .member.id' 2>/dev/null)"
check "fleet: scan skips agentless VM"  null "$(auth_request GET /fleet/discover | body_of | jq -r '.guests[] | select(.vmid == 101) | .dcs' 2>/dev/null)"
_envdel PROXMOX_URL
check "fleet: scan without proxmox"     400 "$(auth_request GET /fleet/discover | status_of)"
_envset PROXMOX_URL "http://127.0.0.1:$_PVE_PORT"
check "fleet: scan with values (wizard)" 1 "$(auth_request POST /fleet/discover "{\"url\":\"http://127.0.0.1:$_PVE_PORT\",\"token_id\":\"dcs@pve!smoke\",\"token_secret\":\"smoke-secret\"}" | body_of | jq -r '.found' 2>/dev/null)"
check "fleet: viewer cannot scan"       403 "$(viewer_request GET /fleet/discover | status_of)"
check "fleet: test reports reachable"   true "$(auth_request POST "/fleet/members/$MID/test" '{}' | body_of | jq -r '.reachable' 2>/dev/null)"
check "fleet: test rematches guest"     100 "$(auth_request POST "/fleet/members/$MID/test" '{}' | body_of | jq -r '.match.vmid' 2>/dev/null)"
# the hub brings the member to its own DCS version: the member fetches the hub's bundle, keeps its files and re-executes on the new code
_envset FLEET_SELF_URL "http://127.0.0.1:$HUB_PORT"
_VER=$(tr -d '[:space:]' < "$ROOT/VERSION")
check "update: member reports old version" 3.8.99 "$(curl -s -m 2 "http://127.0.0.1:$FLEET_PORT/ping" | jq -r '.version' 2>/dev/null)"
check "update: versions sees it behind"    1 "$(auth_request GET /fleet/versions | body_of | jq -r '.behind' 2>/dev/null)"
check "update: versions names the member"  "$MID" "$(auth_request GET /fleet/versions | body_of | jq -r '.members[0].id' 2>/dev/null)"
check "update: hub version in the answer"  "$_VER" "$(auth_request GET /fleet/versions | body_of | jq -r '.hub.version' 2>/dev/null)"
check "update: viewer cannot see versions" 403 "$(viewer_request GET /fleet/versions | status_of)"
check "update: viewer cannot run a round"  403 "$(viewer_request POST /fleet/update '{"members":"all"}' | status_of)"
check "update: unknown member reported"    "unknown member" "$(auth_request POST /fleet/update '{"members":["nobody"]}' | body_of | jq -r '.results[0].message' 2>/dev/null)"
_UPD=$(auth_request POST /fleet/update '{"members":"all"}' | body_of)
check "update: round succeeds"             1 "$(jq -r '.updated' <<< "$_UPD" 2>/dev/null)"
check "update: from → to reported"         "3.8.99 → $_VER" "$(jq -r '.results[0] | "\(.from) → \(.to)"' <<< "$_UPD" 2>/dev/null)"
check "update: member restarts in place"   reexec "$(jq -r '.results[0].restart' <<< "$_UPD" 2>/dev/null)"
timeout 30 bash -c "until curl -s -m 1 http://127.0.0.1:$FLEET_PORT/ping | grep -q '\"version\": \"$_VER\"'; do sleep 0.5; done" 2>/dev/null
sleep 3; timeout 20 bash -c "until curl -s -m 1 http://127.0.0.1:$FLEET_PORT/ping | grep -q '\"ok\"'; do sleep 0.3; done" 2>/dev/null   # the re-exec a second after the answer
check "update: member on the hub's version" "$_VER" "$(curl -s -m 2 "http://127.0.0.1:$FLEET_PORT/ping" | jq -r '.version' 2>/dev/null)"
check "update: member has no git → hub"   member "$(member_request GET /system/update/check | jq -r '.state' 2>/dev/null)"
check "update: member names its hub"      yes "$(member_request GET /system/update/check | jq -e '.hub.url | length > 0' >/dev/null 2>&1 && echo yes || echo no)"
check "update: member's last update time" yes "$(member_request GET /system/update/check | jq -e '.last_updated_at | length > 10' >/dev/null 2>&1 && echo yes || echo no)"
check "update: hub without git → manual"  manual "$(auth_request GET /system/update/check | body_of | jq -r '.state' 2>/dev/null)"
check "images: fleet list tags the VM"    "$MID" "$(auth_request GET /fleet/images | body_of | jq -r '[.images[] | select(.member != null)] | .[0].member' 2>/dev/null)"
check "images: fleet list has the hub"    yes "$(auth_request GET /fleet/images | body_of | jq -e '[.images[] | select(.member == null)] | length > 0' >/dev/null 2>&1 && echo yes || echo no)"
check "images: per-DCS counts"            2 "$(auth_request GET /fleet/images | body_of | jq -r '.members | length' 2>/dev/null)"
check "images: totals add up"             yes "$(auth_request GET /fleet/images | body_of | jq -e '.total == (.images | length) and .total == ([.members[].total] | add)' >/dev/null 2>&1 && echo yes || echo no)"
check "images: viewer may read the list"  200 "$(viewer_request GET /fleet/images | status_of)"
check "fleet: /health?fleet=1 merges"     true "$(auth_request GET '/health?fleet=1' | body_of | jq -r '.fleet' 2>/dev/null)"
check "fleet: health lists both DCS"      2 "$(auth_request GET '/health?fleet=1' | body_of | jq -r '.members | length' 2>/dev/null)"
check "fleet: health names the member"    "$MID" "$(auth_request GET '/health?fleet=1' | body_of | jq -r '.members[1].id' 2>/dev/null)"
check "fleet: health summary adds up"     yes "$(auth_request GET '/health?fleet=1' | body_of | jq -e '.summary.total == (.containers | length)' >/dev/null 2>&1 && echo yes || echo no)"
check "fleet: /health plain unchanged"    null "$(auth_request GET /health | body_of | jq -r '.fleet' 2>/dev/null)"
check "fleet: score folds the members in" 2 "$(auth_request GET '/health/score?fleet=1' | body_of | jq -r '.members | length' 2>/dev/null)"
check "fleet: score is well formed"       yes "$(auth_request GET '/health/score?fleet=1' | body_of | jq -e '(.factors.stacks.total | type == "number") and (.score | type == "number") and (.grade | test("^[A-F]$")) and (.stacks | type == "array")' >/dev/null 2>&1 && echo yes || echo no)"
check "fleet: /images?fleet=1 merges"     2 "$(auth_request GET '/images?fleet=1' | body_of | jq -r '.members | length' 2>/dev/null)"
check "fleet: images total adds up"       yes "$(auth_request GET '/images?fleet=1' | body_of | jq -e '.total == (.images | length) and .total == ([.members[].count] | add)' >/dev/null 2>&1 && echo yes || echo no)"
check "fleet: image rows say where"       yes "$(auth_request GET '/images?fleet=1' | body_of | jq -e --arg m "$MID" '([.images[] | select(.member == $m)] | length) == .members[1].count' >/dev/null 2>&1 && echo yes || echo no)"
for _p in networks volumes events snapshots automations schedules; do
    check "fleet: /$_p?fleet=1 lists both DCS" 2 "$(auth_request GET "/$_p?fleet=1" | body_of | jq -r '.members | length' 2>/dev/null)"
done
check "fleet: network rows say where"     yes "$(auth_request GET '/networks?fleet=1' | body_of | jq -e '[.networks[] | select(.member != null)] | length > 0' >/dev/null 2>&1 && echo yes || echo no)"
check "fleet: /audit?fleet=1 merges"      true "$(auth_request GET '/audit?fleet=1' | body_of | jq -r '.fleet' 2>/dev/null)"
check "fleet: /networks plain unchanged"  null "$(auth_request GET /networks | body_of | jq -r '.fleet' 2>/dev/null)"
_FSNAP=$(auth_request POST '/snapshots/create?fleet=1' '{"label":"fleet-smoke"}' | body_of)
check "fleet: snapshot everywhere"        2 "$(jq -r '.taken' <<< "$_FSNAP" 2>/dev/null)"
check "fleet: snapshot names the member"  "$MID" "$(jq -r '.results[1].id' <<< "$_FSNAP" 2>/dev/null)"
check "fleet: snapshots listed together"  yes "$(auth_request GET '/snapshots?fleet=1' | body_of | jq -e --arg m "$MID" '[.snapshots[] | select(.member == $m)] | length >= 1' >/dev/null 2>&1 && echo yes || echo no)"
check "update: member kept its old code"   yes "$(ls "$MWORK"/.snapshots/code/dcs-code-3.8.99-*.tar.gz >/dev/null 2>&1 && echo yes || echo no)"
check "update: old code kept private"      600 "$(stat -c %a "$MWORK"/.snapshots/code/dcs-code-3.8.99-*.tar.gz 2>/dev/null | head -1)"
check "update: member kept its settings"   "Media VM" "$(grep '^SERVER_NAME=' "$MWORK/.env" | cut -d= -f2-)"
check "update: member kept its accounts"   yes "$(jq -e '[.[] | select(.username == "dcs-hub")] | length == 1' "$MWORK/.api-auth/users.json" >/dev/null 2>&1 && echo yes || echo no)"
check "update: member history entry"       updated "$(jq -r '.[-1] | select(.message == "from the hub'"'"'s bundle") | .result' "$MWORK/.api-auth/update-history.json" 2>/dev/null)"
check "update: nobody behind afterwards"   0 "$(auth_request GET /fleet/versions | body_of | jq -r '.behind' 2>/dev/null)"
check "update: last round remembered"      1 "$(auth_request GET /fleet/versions | body_of | jq -r '.last_round.updated' 2>/dev/null)"
check "update: member version recorded"    "$_VER" "$(auth_request GET /fleet/members | body_of | jq -r '.members[0].version' 2>/dev/null)"
check "update: the round's code revoked"   0 "$(auth_request GET /fleet/join-tokens | body_of | jq -r '[.tokens[] | select(.created_by == "update")] | length' 2>/dev/null)"
check "update: audited on the hub"         yes "$(grep -q 'fleet_update' "$WORK/.data/audit.jsonl" 2>/dev/null && echo yes || echo no)"
MTOKEN=$(curl -s -m 5 -X POST "http://127.0.0.1:$FLEET_PORT/auth/login" -H 'Content-Type: application/json' -d '{"username":"admin","password":"correct horse battery"}' | jq -r '.token // empty' 2>/dev/null)
check "update: self-update wants a URL"    400 "$(curl -s -o /dev/null -w '%{http_code}' -m 5 -X POST "http://127.0.0.1:$FLEET_PORT/fleet/self-update" -H "Authorization: Bearer $MTOKEN" -H 'Content-Type: application/json' -d '{"bundle_url":"nope"}')"
check "update: another host is refused"   403 "$(curl -s -o /dev/null -w '%{http_code}' -m 5 -X POST "http://127.0.0.1:$FLEET_PORT/fleet/self-update" -H "Authorization: Bearer $MTOKEN" -H 'Content-Type: application/json' -d '{"bundle_url":"http://127.0.0.1:1/fleet/bundle?token=x"}')"
check "update: self-update wants a bundle" 400 "$(curl -s -o /dev/null -w '%{http_code}' -m 15 -X POST "http://127.0.0.1:$FLEET_PORT/fleet/self-update" -H "Authorization: Bearer $MTOKEN" -H 'Content-Type: application/json' -d "{\"bundle_url\":\"http://127.0.0.1:$HUB_PORT/ping\"}")"
check "update: a bundle code alone is enough" 502 "$(curl -s -o /dev/null -w '%{http_code}' -m 15 -X POST "http://127.0.0.1:$FLEET_PORT/fleet/self-update" -H "Authorization: Bearer $MTOKEN" -H 'Content-Type: application/json' -d '{"token":"NOPE-NOPE-NOPE"}')"
check "update: odd bundle code refused"    400 "$(curl -s -o /dev/null -w '%{http_code}' -m 5 -X POST "http://127.0.0.1:$FLEET_PORT/fleet/self-update" -H "Authorization: Bearer $MTOKEN" -H 'Content-Type: application/json' -d '{"token":"nope/../x"}')"
check "update: old code is not a snapshot" 0 "$(member_request GET /snapshots | jq -r '[.snapshots[] | select(.filename | startswith("dcs-code"))] | length' 2>/dev/null)"
check "update: no bundle code left behind" 0 "$(jq -r '[.join_tokens[] | select(.purpose == "bundle")] | length' "$WORK/.data/fleet.json" 2>/dev/null)"
jq --arg m "$MID" '.join_tokens += [{"token":"BNDL-GOOD-CODE","created_at":0,"expires_at":4102444800,"created_by":"update","uses":0,"purpose":"bundle","member":$m},{"token":"BNDL-NOBO-DY00","created_at":0,"expires_at":4102444800,"created_by":"update","uses":0,"purpose":"bundle","member":"nobody"}]' "$WORK/.data/fleet.json" > "$WORK/.data/fleet.json.tmp" && mv -f "$WORK/.data/fleet.json.tmp" "$WORK/.data/fleet.json"
check "update: a bundle code cannot join"  403 "$(request POST /fleet/join "{\"token\":\"BNDL-GOOD-CODE\",\"url\":\"http://127.0.0.1:1\",\"username\":\"admin\",\"password\":\"x\"}" "${AUTH[@]}" | status_of)"
check "update: a bundle code opens the bundle" 200 "$(request GET '/fleet/bundle?token=BNDL-GOOD-CODE' '' "${AUTH[@]}" | status_of)"
check "update: a bundle code for nobody"   403 "$(request GET '/fleet/bundle?token=BNDL-NOBO-DY00' '' "${AUTH[@]}" | status_of)"
jq 'del(.join_tokens[] | select(.token | startswith("BNDL-")))' "$WORK/.data/fleet.json" > "$WORK/.data/fleet.json.tmp" && mv -f "$WORK/.data/fleet.json.tmp" "$WORK/.data/fleet.json"
# the hub's own update takes the VMs along: {fleet: true} leaves a marker, and the round runs by itself when the hub's API is back on the new code
(cd "$MWORK" && "$MWORK/.scripts/api-server.sh" --stop >/dev/null 2>&1)
timeout 10 bash -c "while curl -s -m 1 http://127.0.0.1:$FLEET_PORT/ping >/dev/null 2>&1; do sleep 0.3; done" 2>/dev/null
printf '3.8.98\n' > "$MWORK/VERSION"
for _i in 1 2 3; do touch -d "-$_i hours" "$MWORK/.snapshots/code/dcs-code-0.0.$_i-2026010100000$_i.tar.gz"; done
(cd "$MWORK" && FLEET_IDENTITY_UUID=11111111-2222-3333-4444-555555555555 setsid nohup "$MWORK/.scripts/api-server.sh" --bind 127.0.0.1 --port "$FLEET_PORT" >> "$MWORK/logs/member-listener.log" 2>&1 < /dev/null &)
timeout 30 bash -c "until curl -s -m 1 http://127.0.0.1:$FLEET_PORT/ping | grep -q '\"3.8.98\"'; do sleep 0.5; done" 2>/dev/null
check "queued: member behind again"        1 "$(auth_request GET /fleet/versions | body_of | jq -r '.behind' 2>/dev/null)"
touch "$WORK/.data/fleet-update-pending"
check "queued: versions says pending"      true "$(auth_request GET /fleet/versions | body_of | jq -r '.pending' 2>/dev/null)"
(cd "$WORK" && "$API" --stop >/dev/null 2>&1)
timeout 10 bash -c "while curl -s -m 1 http://127.0.0.1:$HUB_PORT/ping >/dev/null 2>&1; do sleep 0.3; done" 2>/dev/null
(cd "$WORK" && setsid nohup "$API" --bind 127.0.0.1 --port "$HUB_PORT" >> "$WORK/logs/hub-listener.log" 2>&1 < /dev/null &)
timeout 30 bash -c "until curl -s -m 1 http://127.0.0.1:$HUB_PORT/ping | grep -q '\"ok\"'; do sleep 0.3; done" 2>/dev/null
check "queued: hub back, session kept"     hub "$(auth_request GET /fleet/status | body_of | jq -r '.role' 2>/dev/null)"
timeout 45 bash -c "until curl -s -m 1 http://127.0.0.1:$FLEET_PORT/ping | grep -q '\"$_VER\"'; do sleep 0.5; done" 2>/dev/null
check "queued: round ran at startup"       "$_VER" "$(curl -s -m 2 "http://127.0.0.1:$FLEET_PORT/ping" | jq -r '.version' 2>/dev/null)"
check "queued: marker consumed"            no "$([[ -f "$WORK/.data/fleet-update-pending" ]] && echo yes || echo no)"
check "queued: nobody behind"              0 "$(auth_request GET /fleet/versions | body_of | jq -r '.behind' 2>/dev/null)"
check "queued: round audited as startup"   yes "$(grep 'fleet_update' "$WORK/.data/audit.jsonl" 2>/dev/null | tail -1 | grep -q '(startup)' && echo yes || echo no)"
check "queued: three code snapshots kept"  3 "$(ls "$MWORK"/.snapshots/code/dcs-code-*.tar.gz 2>/dev/null | wc -l)"
check "queued: the oldest snapshot gone"   no "$([[ -f "$MWORK/.snapshots/code/dcs-code-0.0.3-20260101000003.tar.gz" ]] && echo yes || echo no)"
sleep 3; timeout 20 bash -c "until curl -s -m 1 http://127.0.0.1:$FLEET_PORT/ping | grep -q '\"ok\"'; do sleep 0.3; done" 2>/dev/null   # the member re-executes once more
_envdel FLEET_SELF_URL
check "fleet: rename member"            "Media VM" "$(auth_request PUT "/fleet/members/$MID" '{"name":"Media VM"}' | body_of | jq -r '.member.name' 2>/dev/null)"
check "fleet: name cleaned of control chars" "Media VM" "$(auth_request PUT "/fleet/members/$MID" '{"name":"Media\u0007 VM\n"}' | body_of | jq -r '.member.name' 2>/dev/null)"
check "fleet: unprintable name refused" 400 "$(auth_request PUT "/fleet/members/$MID" '{"name":"\u0001\u0002"}' | status_of)"
check "fleet: remap by hand"            manual "$(auth_request PUT "/fleet/members/$MID" '{"vmid":101,"node":"pve","type":"qemu"}' | body_of | jq -r '.member.matched_by' 2>/dev/null)"
check "fleet: bad password refused"     502 "$(auth_request PUT "/fleet/members/$MID" '{"password":"wrong-wrong"}' | status_of)"
check "fleet: unknown member 404"       404 "$(auth_request PUT "/fleet/members/nobody" '{"name":"x"}' | status_of)"
# the member's routes ride along in the hub's Traefik feed
_MROUTES=$(_mlib _find_traefik_routes_dir); [[ -n "$_MROUTES" ]] || _MROUTES="$MWORK/.data/routes"; mkdir -p "$_MROUTES"
printf 'http:\n  routers:\n    fleetwho:\n      rule: "Host(`fleetwho.example.com`)"\n      service: fleetwho\n  services:\n    fleetwho:\n      loadBalancer:\n        servers:\n          - url: "http://127.0.0.1:8080"\n' > "$_MROUTES/fleetwho.yml"
check "fleet: member feed lists route"  yes "$(member_request GET /fleet/feed | jq -e '.http.routers | has("fleetwho-dcs")' >/dev/null 2>&1 && echo yes || echo no)"
_envset TRAEFIK_FEED_ENABLED true; _envset TRAEFIK_FEED_TOKEN fleet-feed-token
check "fleet: hub feed merges member"   yes "$(request GET '/traefik/dynamic?token=fleet-feed-token' '' "${AUTH[@]}" | body_of | jq -e --arg k "${MID}-fleetwho-dcs" '.http.routers | has($k)' >/dev/null 2>&1 && echo yes || echo no)"
check "fleet: merged service renamed"   "${MID}-fleetwho-dcs" "$(request GET '/traefik/dynamic?token=fleet-feed-token' '' "${AUTH[@]}" | body_of | jq -r --arg k "${MID}-fleetwho-dcs" '.http.routers[$k].service' 2>/dev/null)"
check "fleet: feed status counts them"  yes "$([[ "$(auth_request GET /traefik/feed/status | body_of | jq -r '.member_routes' 2>/dev/null)" -ge 1 ]] && echo yes || echo no)"
# the hub's own Traefik gets the members' routes as a file in its custom_routes directory (the file provider watches it)
_lib _fleet_routes_write_local
_HROUTES="$WORK/Stacks/zz-proxy/App-Data/Traefik/custom_routes"
check "fleet: member routes written locally" yes "$(jq -e --arg k "${MID}-fleetwho-dcs" '.http.routers | has($k)' "$_HROUTES/fleet-members.yml" >/dev/null 2>&1 && echo yes || echo no)"
check "fleet: local route points at the VM" yes "$(jq -r --arg k "${MID}-fleetwho-dcs" '.http.services[$k].loadBalancer.servers[0].url' "$_HROUTES/fleet-members.yml" 2>/dev/null | grep -q '127.0.0.1:8080' && echo yes || echo no)"
_MT1=$(stat -c %Y "$_HROUTES/fleet-members.yml" 2>/dev/null); sleep 1; _lib _fleet_routes_write_local
check "fleet: unchanged routes not rewritten" "$_MT1" "$(stat -c %Y "$_HROUTES/fleet-members.yml" 2>/dev/null)"
_envdel TRAEFIK_FEED_ENABLED; _envdel TRAEFIK_FEED_TOKEN; rm -f "$_MROUTES/fleetwho.yml"
_lib _fleet_routes_write_local
check "fleet: removed route leaves the file" no "$(jq -e --arg k "${MID}-fleetwho-dcs" '.http.routers | has($k)' "$_HROUTES/fleet-members.yml" >/dev/null 2>&1 && echo yes || echo no)"
# the watcher: a member that stops answering, then comes back
(cd "$MWORK" && "$MWORK/.scripts/api-server.sh" --stop >/dev/null 2>&1)
timeout 10 bash -c "while curl -s -m 1 http://127.0.0.1:$FLEET_PORT/ping >/dev/null 2>&1; do sleep 0.3; done" 2>/dev/null
touch -d '-2 minutes' "$WORK/.data/fleet-watch.stamp" 2>/dev/null
FLEET_WATCH_STAMP="$WORK/.data/fleet-watch.stamp" _lib _fleet_watch
check "fleet: member down noticed"      yes "$(grep -q 'fleet_member_down' "$WORK/.data/audit.jsonl" 2>/dev/null && echo yes || echo no)"
check "fleet: member marked unreachable" false "$(auth_request GET /fleet/members | body_of | jq -r '.members[0].reachable' 2>/dev/null)"
check "fleet: overview says no answer"  false "$(auth_request GET /fleet/overview | body_of | jq -r '.members[0].reachable' 2>/dev/null)"
check "fleet: health counts the silent VM"  1 "$(auth_request GET '/health?fleet=1' | body_of | jq -r '.unreachable' 2>/dev/null)"
check "fleet: health is not healthy then"   yes "$(auth_request GET '/health?fleet=1' | body_of | jq -e '.status != "healthy"' >/dev/null 2>&1 && echo yes || echo no)"
(cd "$MWORK" && FLEET_IDENTITY_UUID=11111111-2222-3333-4444-555555555555 setsid nohup "$MWORK/.scripts/api-server.sh" --bind 127.0.0.1 --port "$FLEET_PORT" >> "$MWORK/logs/member-listener.log" 2>&1 < /dev/null &)
timeout 30 bash -c "until curl -s -m 1 http://127.0.0.1:$FLEET_PORT/ping | grep -q '\"ok\"'; do sleep 0.3; done" 2>/dev/null
touch -d '-2 minutes' "$WORK/.data/fleet-watch.stamp" 2>/dev/null
FLEET_WATCH_STAMP="$WORK/.data/fleet-watch.stamp" _lib _fleet_watch
check "fleet: member back noticed"      yes "$(grep -q 'fleet_member_up' "$WORK/.data/audit.jsonl" 2>/dev/null && echo yes || echo no)"
check "event style: member down"        "Member stopped answering" "$(_lib _discord_event_style fleet_member_down | cut -d'|' -f3)"
check "notify wording: member joined"   "{member} joined the hub" "$(_lib eval '_notify_default_templates fleet_member_joined; printf %s "$NT_TITLE"')"
# the member leaves; the hub forgets it; a manual add with the member's own account
MTOKEN=$(curl -s -m 5 -X POST "http://127.0.0.1:$FLEET_PORT/auth/login" -H 'Content-Type: application/json' -d '{"username":"admin","password":"correct horse battery"}' | jq -r '.token // empty' 2>/dev/null)
check "fleet: member leaves hub"        true "$(member_request DELETE /fleet/hub | jq -r '.success' 2>/dev/null)"
check "fleet: dcs-hub account removed"  0 "$(jq -r '[.[] | select(.username == "dcs-hub")] | length' "$MWORK/.api-auth/users.json" 2>/dev/null)"
check "fleet: member standalone again"  standalone "$(member_request GET /fleet/status | jq -r '.role' 2>/dev/null)"
check "fleet: hub forgets member"       true "$(auth_request DELETE "/fleet/members/$MID" | body_of | jq -r '.success' 2>/dev/null)"
check "fleet: secret gone"              no "$(_lib secrets_exists FLEET_MEMBER_MEDIA_VM_PASSWORD && echo yes || echo no)"
check "fleet: manual add by account"    manual-vm "$(auth_request POST /fleet/members "{\"name\":\"manual vm\",\"url\":\"http://127.0.0.1:$FLEET_PORT\",\"username\":\"admin\",\"password\":\"correct horse battery\"}" | body_of | jq -r '.member.id' 2>/dev/null)"
check "fleet: manual add wrong password" 502 "$(auth_request POST /fleet/members "{\"url\":\"http://127.0.0.1:$FLEET_PORT\",\"username\":\"admin\",\"password\":\"nope-nope\"}" | status_of)"
check "fleet: refuses itself"           502 "$(auth_request POST /fleet/members "{\"url\":\"http://127.0.0.1:9876\",\"username\":\"admin\",\"password\":\"correct horse battery\"}" | status_of)"
check "fleet: manual add proxies"       demo "$(auth_request GET /fleet/members/manual-vm/api/stacks | body_of | jq -r '.stacks[0].name' 2>/dev/null)"
auth_request DELETE /fleet/members/manual-vm >/dev/null

echo "Fleet: a hostile member (a stand-in that answers whatever it likes)"
# A member is another machine, so everything it answers is data. The stand-in claims the hub's stacks and hostnames, sends
# routers with fields of its own, answers the merged lists in the wrong shapes, and logs every request it receives.
MOCK_PORT=$(( 20000 + RANDOM % 20000 )); [[ "$MOCK_PORT" == "$HUB_PORT" || "$MOCK_PORT" == "$FLEET_PORT" ]] && MOCK_PORT=$(( MOCK_PORT + 7 ))
MOCK_LOG="$WORK/mock-member.log"; : > "$MOCK_LOG"
cat > "$WORK/mock-member.py" <<'MOCK'
#!/usr/bin/env python3
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
PORT, LOG, VER = int(sys.argv[1]), sys.argv[2], sys.argv[3]
FEED = {"http": {"routers": {
    "good": {"rule": "Host(`Good.Example.test`)", "service": "good", "entryPoints": ["websecure", "x y"], "tls": {}, "priority": 9},
    "twin": {"rule": "Host(`good.example.test`)", "service": "good"},
    "hubhost": {"rule": "Host(`tools.example.test`)", "service": "good"},
    "dash": {"rule": "Host(`dash.smoke.test`)", "service": "good"},
    "foreign": {"rule": "Host(`foreign.example.test`)", "service": "foreign"},
    "Bad Name!": {"rule": "Host(`bad.example.test`)", "service": "good"},
    "regex": {"rule": "HostRegexp(`{any:.*}`)", "service": "good"},
    "extra": {"rule": "Host(`extra.example.test`) && PathPrefix(`/api`)", "service": "good", "middlewares": ["auth@file", "x y"],
              "tls": {"certResolver": "le", "domains": [{"main": "*.example.test"}]}, "priority": 10, "observability": {"metrics": True}},
}, "services": {
    "good": {"loadBalancer": {"servers": [{"url": "http://127.0.0.1:8080"}], "passHostHeader": False}},
    "foreign": {"loadBalancer": {"servers": [{"url": "http://10.9.9.9:8080"}]}},
}}}
GET = {
    "/ping": {"ok": True, "version": VER},
    "/fleet/identity": {"hostname": "Hostile\u0007 Member\n", "ips": [], "api_port": PORT, "version": VER, "stacks": ["orphan", "demo", "nofolder", "../etc"]},
    "/stacks": {"stacks": [{"name": "orphan", "status": "running", "running_containers": 1, "containers": 1}], "total": 1},
    "/containers": {"containers": "nope"},
    "/networks": {"networks": "nope", "total": "x"},
    "/volumes": {"volumes": [1, "two", None, {"name": "v"}]},
    "/events": {"events": "nope"}, "/snapshots": {"snapshots": 7}, "/automations": {"automations": None},
    "/schedules": {"schedules": {"x": 1}}, "/secrets": {"secrets": "nope"}, "/audit": {"entries": "nope"},
    "/health": {"status": 5, "summary": "nope", "containers": {"a": 1}},
    "/health/score": {"score": "high", "grade": 1, "factors": "nope", "stacks": "nope"},
    "/images": {"images": "nope", "total": "x"},
    "/images/check-updates": {"images": {"a": 1}, "total": [], "updates_available": "3", "stale": None, "registry_checked_at": 12},
    "/system/docker-engine": {"version": 5, "upgradable": "yes", "source": None, "last_update": "nope"},
    "/fleet/feed": FEED,
}
POST = {
    "/auth/login": {"token": "mock-session-" + "x" * 48, "role": "admin"},
    "/images/check-updates": {"total": "x", "updates_available": None},
    "/fleet/hub/relay-token": {"success": True}, "/fleet/hub/domain": {"success": True},
    "/snapshots/create": {"success": True, "filename": 5},
}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _note(self):
        with open(LOG, "a") as f: f.write(self.command + " " + self.path.split("?")[0] + "\n")
    def _send(self, code, data):
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        self._note(); p = self.path.split("?")[0]
        if p == "/big":
            self.send_response(200); self.send_header("Content-Length", str(9 * 1024 * 1024)); self.end_headers()
            try:
                for _ in range(9): self.wfile.write(b"x" * 1024 * 1024)
            except OSError: pass
            return
        if p in GET: self._send(200, json.dumps(GET[p]).encode()); return
        self._send(404, b'{"error": true, "message": "no such thing here"}')
    def do_POST(self):
        self._note(); p = self.path.split("?")[0]
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if p == "/fleet/self-update": self._send(200, b"{not json at all"); return
        if p == "/fleet/routes": self._send(409, b'{"error": true, "message": "No Traefik runs here"}'); return
        if p in POST: self._send(200, json.dumps(POST[p]).encode()); return
        self._send(404, b'{"error": true}')
    do_PUT = do_POST
    do_DELETE = do_GET
HTTPServer(("127.0.0.1", PORT), H).serve_forever()
MOCK
python3 "$WORK/mock-member.py" "$MOCK_PORT" "$MOCK_LOG" "$(tr -d '[:space:]' < "$ROOT/VERSION")" >/dev/null 2>&1 &
_MOCK_PID=$!
timeout 15 bash -c "until curl -s -m 1 http://127.0.0.1:$MOCK_PORT/ping | grep -q '\"ok\"'; do sleep 0.3; done" 2>/dev/null
mkdir -p "$WORK/Stacks/orphan" && printf 'services:\n  x:\n    image: alpine\n' > "$WORK/Stacks/orphan/docker-compose.yml"
_HM=$(auth_request POST /fleet/members "{\"url\":\"http://127.0.0.1:$MOCK_PORT\",\"username\":\"mock\",\"password\":\"mock-pass\"}" | body_of)
check "hostile: added under its cleaned name" "Hostile Member" "$(jq -r '.member.name' <<< "$_HM" 2>/dev/null)"
HMID=$(jq -r '.member.id' <<< "$_HM" 2>/dev/null)
check "hostile: id from the name"           hostile-member "$HMID"
check "hostile: claims for hub folders dropped" '["nofolder"]' "$(jq -c '.member.stacks' <<< "$_HM" 2>/dev/null)"
# what a member says it runs is shown, never taken as a placement — so it never attracts another stack's requests
check "hostile: overview shows what it runs" orphan "$(auth_request GET /fleet/overview | body_of | jq -r --arg m "$HMID" '.members[] | select(.id == $m) | .stacks[0].name' 2>/dev/null)"
check "hostile: overview shows placements"  '["nofolder"]' "$(auth_request GET /fleet/overview | body_of | jq -c --arg m "$HMID" '.members[] | select(.id == $m) | .placements' 2>/dev/null)"
check "hostile: placements not overwritten" '["nofolder"]' "$(jq -c --arg m "$HMID" '.members[] | select(.id == $m) | .stacks' "$WORK/.data/fleet.json" 2>/dev/null)"
auth_request GET /stacks/orphan >/dev/null
check "hostile: the hub's stack stays here" no "$(grep -q 'GET /stacks/orphan' "$MOCK_LOG" && echo yes || echo no)"
auth_request GET /stacks/nofolder >/dev/null
check "hostile: a placed stack is forwarded" yes "$(grep -q 'GET /stacks/nofolder' "$MOCK_LOG" && echo yes || echo no)"
check "hostile: VM rows say whether placed" false "$(auth_request GET /stacks | body_of | jq -r '.stacks[] | select(.name == "orphan") | .placed' 2>/dev/null)"
# an admin places a stack; a member cannot
check "hostile: bad placement refused"      400 "$(auth_request PUT "/fleet/members/$HMID" '{"stacks":["ok-one","bad name"]}' | status_of)"
check "hostile: a hub stack cannot be placed" 409 "$(auth_request PUT "/fleet/members/$HMID" '{"stacks":["demo"]}' | status_of)"
check "hostile: admin placement kept"       '["nofolder","placed-one"]' "$(auth_request PUT "/fleet/members/$HMID" '{"stacks":["placed-one","nofolder"]}' | body_of | jq -c '.member.stacks' 2>/dev/null)"
auth_request GET /stacks/placed-one >/dev/null
check "hostile: the placed stack is forwarded" yes "$(grep -q 'GET /stacks/placed-one' "$MOCK_LOG" && echo yes || echo no)"
# the merged lists: wrong shapes leave every list a valid answer with the hub's own rows
check "hostile: /networks?fleet=1 still 200" 200 "$(auth_request GET '/networks?fleet=1' | status_of)"
check "hostile: networks stay an array"     array "$(auth_request GET '/networks?fleet=1' | body_of | jq -r '.networks | type' 2>/dev/null)"
check "hostile: its network count is 0"     0 "$(auth_request GET '/networks?fleet=1' | body_of | jq -r --arg m "$HMID" '.members[] | select(.id == $m) | .count' 2>/dev/null)"
for _p in volumes events snapshots automations schedules secrets; do
    check "hostile: /$_p?fleet=1 still 200"  200 "$(auth_request GET "/$_p?fleet=1" | status_of)"
done
check "hostile: /health?fleet=1 still 200"  200 "$(auth_request GET '/health?fleet=1' | status_of)"
check "hostile: health summary numeric"     number "$(auth_request GET '/health?fleet=1' | body_of | jq -r '.summary.total | type' 2>/dev/null)"
check "hostile: /health/score?fleet=1 200"  200 "$(auth_request GET '/health/score?fleet=1' | status_of)"
check "hostile: score well formed"          yes "$(auth_request GET '/health/score?fleet=1' | body_of | jq -e '(.score | type == "number") and (.grade | test("^[A-F]$"))' >/dev/null 2>&1 && echo yes || echo no)"
check "hostile: /images?fleet=1 still 200"  200 "$(auth_request GET '/images?fleet=1' | status_of)"
check "hostile: /fleet/images still 200"    200 "$(auth_request GET /fleet/images | status_of)"
check "hostile: fleet image total numeric"  number "$(auth_request GET /fleet/images | body_of | jq -r '.total | type' 2>/dev/null)"
check "hostile: engine card still 200"      200 "$(auth_request GET '/system/docker-engine?fleet=1' | status_of)"
check "hostile: engine version a string"    string "$(auth_request GET '/system/docker-engine?fleet=1' | body_of | jq -r --arg m "$HMID" '.members[] | select(.id == $m) | .version | type' 2>/dev/null)"
# the feed: routers are rebuilt from a whitelist; the hub's own hosts and foreign addresses never get through
_envset TRAEFIK_FEED_ENABLED true; _envset TRAEFIK_FEED_TOKEN mock-feed-token; _envset DASHBOARD_PUBLIC_URL https://dash.smoke.test
_HF=$(request GET '/traefik/dynamic?token=mock-feed-token' '' "${AUTH[@]}" | body_of)
check "hostile: a clean route passes"       'Host(`good.example.test`)' "$(jq -r --arg k "$HMID-good" '.http.routers[$k].rule' <<< "$_HF" 2>/dev/null)"
check "hostile: its service renamed"        "$HMID-good" "$(jq -r --arg k "$HMID-good" '.http.routers[$k].service' <<< "$_HF" 2>/dev/null)"
check "hostile: priority dropped"           no "$(grep -q priority <<< "$_HF" && echo yes || echo no)"
check "hostile: the hub's host refused"     no "$(jq -e --arg k "$HMID-hubhost" '.http.routers | has($k)' <<< "$_HF" >/dev/null 2>&1 && echo yes || echo no)"
check "hostile: the dashboard host refused" no "$(jq -e --arg k "$HMID-dash" '.http.routers | has($k)' <<< "$_HF" >/dev/null 2>&1 && echo yes || echo no)"
check "hostile: a foreign address refused"  no "$(grep -q '10.9.9.9' <<< "$_HF" && echo yes || echo no)"
check "hostile: a regexp rule refused"      no "$(grep -q 'HostRegexp' <<< "$_HF" && echo yes || echo no)"
check "hostile: unknown fields dropped"     no "$(grep -q -E 'observability|domains|passHostHeader' <<< "$_HF" && echo yes || echo no)"
check "hostile: PathPrefix kept"            'Host(`extra.example.test`) && PathPrefix(`/api`)' "$(jq -r --arg k "$HMID-extra" '.http.routers[$k].rule' <<< "$_HF" 2>/dev/null)"
check "hostile: odd middlewares dropped"    '["auth@file"]' "$(jq -c --arg k "$HMID-extra" '.http.routers[$k].middlewares' <<< "$_HF" 2>/dev/null)"
check "hostile: certResolver alone kept"    '{"certResolver":"le"}' "$(jq -c --arg k "$HMID-extra" '.http.routers[$k].tls' <<< "$_HF" 2>/dev/null)"
check "hostile: a twin host renamed"        'Host(`good-hostile-member.example.test`)' "$(jq -r --arg k "$HMID-twin" '.http.routers[$k].rule' <<< "$_HF" 2>/dev/null)"
_HS=$(auth_request GET /traefik/feed/status | body_of)
check "hostile: refusals reported"          yes "$(jq -e --arg m "$HMID" '[.member_skipped[] | select(.member == $m)] | length >= 5' <<< "$_HS" >/dev/null 2>&1 && echo yes || echo no)"
check "hostile: the hub host names the reason" yes "$(jq -r '.member_skipped[] | select(.service == "hubhost") | .reason' <<< "$_HS" 2>/dev/null | grep -q 'belongs to the hub' && echo yes || echo no)"
check "hostile: the rename names the host"  good-hostile-member.example.test "$(jq -r '.member_skipped[] | select(.service == "twin") | .host' <<< "$_HS" 2>/dev/null)"
_lib _fleet_routes_write_local
check "hostile: local file has the clean route" yes "$(jq -e --arg k "$HMID-good" '.http.routers | has($k)' "$_HROUTES/fleet-members.yml" >/dev/null 2>&1 && echo yes || echo no)"
check "hostile: local file free of the hub host" no "$(grep -q 'tools.example.test' "$_HROUTES/fleet-members.yml" 2>/dev/null && echo yes || echo no)"
_envdel TRAEFIK_FEED_ENABLED; _envdel TRAEFIK_FEED_TOKEN; _envdel DASHBOARD_PUBLIC_URL
# the loop's fleet tick runs in the background under a lock; a stale lock is taken over
touch -d '-2 minutes' "$WORK/.data/fleet-watch.stamp"; mkdir -p "$WORK/.data/fleet-loop.lock"
_lib _fleet_loop_tick; sleep 1
check "tick: a live lock holds the tick"    yes "$([[ $(( $(date +%s) - $(stat -c %Y "$WORK/.data/fleet-watch.stamp") )) -gt 60 ]] && echo yes || echo no)"
touch -d '-11 minutes' "$WORK/.data/fleet-loop.lock"
_lib _fleet_loop_tick
for _i in $(seq 1 30); do [[ -d "$WORK/.data/fleet-loop.lock" ]] || break; sleep 1; done
check "tick: a stale lock is taken over"    yes "$([[ $(( $(date +%s) - $(stat -c %Y "$WORK/.data/fleet-watch.stamp") )) -lt 60 ]] && echo yes || echo no)"
check "tick: the lock is released"          no "$([[ -d "$WORK/.data/fleet-loop.lock" ]] && echo yes || echo no)"
# an update round runs on its own: a member whose answer is not JSON counts as failed and never ends the round, no bundle
# code is left behind, and the answer is 202 when the round outlasts the wait
check "hostile: odd member id refused"      400 "$(auth_request POST /fleet/update '{"members":["Bad Id"]}' | status_of)"
_envset FLEET_UPDATE_WAIT 0
_UR=$(auth_request POST /fleet/update "{\"members\":[\"$HMID\"]}")
check "hostile: round answers 202"          202 "$(status_of <<< "$_UR")"
check "hostile: the answer says running"    true "$(body_of <<< "$_UR" | jq -r '.running' 2>/dev/null)"
_RS=""; for _i in $(seq 1 40); do _RS=$(auth_request GET /fleet/versions | body_of | jq -r '.last_round.status // ""' 2>/dev/null); [[ "$_RS" == "done" ]] && break; sleep 1; done
check "hostile: round finished"             'done' "$_RS"
check "hostile: malformed answer = failed"  1 "$(auth_request GET /fleet/versions | body_of | jq -r '.last_round.failed' 2>/dev/null)"
check "hostile: the reason is named"        yes "$(auth_request GET /fleet/versions | body_of | jq -r '.last_round.results[0].message' 2>/dev/null | grep -q 'malformed' && echo yes || echo no)"
check "hostile: no bundle code left behind" 0 "$(jq -r '[.join_tokens[] | select(.purpose == "bundle")] | length' "$WORK/.data/fleet.json" 2>/dev/null)"
_envdel FLEET_UPDATE_WAIT
check "hostile: an 8 MB answer is refused"  "0|answer larger than 8 MB" "$(_lib eval "_fleet_http _big GET http://127.0.0.1:$MOCK_PORT/big; printf '%s|%s' \"\$_FLEET_HTTP\" \"\$_FLEET_ERR\"")"
auth_request DELETE "/fleet/members/$HMID" >/dev/null
kill $_MOCK_PID 2>/dev/null; wait $_MOCK_PID 2>/dev/null
rm -rf "$WORK/Stacks/orphan" "$WORK/mock-member.py" "$WORK/.data/fleet-loop.lock"
# join saved for later when the member has no admin yet (setup.sh before the wizard)
mkdir -p "$PWORK/.scripts" "$PWORK/.lib" "$PWORK/.config" "$PWORK/.data" "$PWORK/.api-auth" "$PWORK/logs"
cp "$API" "$PWORK/.scripts/"; cp -r "$WORK/.lib/." "$PWORK/.lib/"; cp -r "$WORK/.config/." "$PWORK/.config/"; cp "$WORK/.env" "$PWORK/.env"; printf '[]' > "$PWORK/.api-auth/users.json"
PJ_OUT=$(cd "$PWORK" && "$PWORK/.scripts/api-server.sh" --join-hub "http://127.0.0.1:$HUB_PORT" "$JT" 2>&1)
check "fleet: join deferred w/o admin"  yes "$(grep -q 'Join saved' <<< "$PJ_OUT" && echo yes || echo no)"
check "fleet: pending join recorded"    "http://127.0.0.1:$HUB_PORT" "$(jq -r '.hub_url' "$PWORK/.data/fleet-join-pending.json" 2>/dev/null)"
check "fleet: CLI join code"            yes "$(cd "$WORK" && "$API" --join-token 2 2>/dev/null | grep -q '^Join code: [A-Z2-9]\{4\}-' && echo yes || echo no)"
check "fleet: CLI status is JSON"       true "$(cd "$WORK" && "$API" --fleet-status 2>/dev/null | jq -e 'has("members")' 2>/dev/null)"
check "fleet: revoke code"              200 "$(auth_request DELETE "/fleet/join-tokens/$JT" | status_of)"
check "fleet: revoked code gone"        no "$(auth_request GET /fleet/join-tokens | body_of | jq -e --arg t "$JT" '.tokens[] | select(.token == $t)' >/dev/null 2>&1 && echo yes || echo no)"

echo "Fleet: the hub builds a VM for a stack (mock Proxmox, an ssh stand-in runs the real unattended setup)"
PROV_PORT=$(( 20000 + RANDOM % 20000 )); [[ "$PROV_PORT" == "$HUB_PORT" || "$PROV_PORT" == "$FLEET_PORT" ]] && PROV_PORT=$(( PROV_PORT + 3 ))
VMWORK="$WORK-vm"
cat > "$WORK/ssh-shim.sh" <<'SHIM'
#!/bin/bash
# ssh stand-in: "… dcs@IP true" answers at once; the bootstrap command (script on stdin) runs the member bootstrap here —
# a fresh copy of the repository and the real setup.sh, unattended and API-only, on the port the hub chose.
set -u
while [[ $# -gt 0 ]]; do case "$1" in -i|-o) shift 2 ;; -*) shift ;; *) break ;; esac; done
target="${1:-}"; shift || true
case "$*" in
  true) exit 0 ;;
  "bash -s"|*dcs-bootstrap*)
    script=$(cat)
    eval "$(printf '%s\n' "$script" | grep '^export DCS_')"
    if [[ "${DCS_BAKE:-false}" == "true" ]]; then echo "→ (stand-in) template baked: tools, Docker, agent — powering off"; exit 0; fi
    port="${DCS_MEMBER_URL##*:}"; host=$(sed -E 's#^https?://([^:/]+).*#\1#' <<< "$DCS_MEMBER_URL")
    [[ -f "$SHIM_DIR/.data/api-server.pid" ]] && (cd "$SHIM_DIR" && "$SHIM_DIR/.scripts/api-server.sh" --stop >/dev/null 2>&1)
    rm -rf "$SHIM_DIR"; git clone -q "$SHIM_ROOT" "$SHIM_DIR" || { echo "clone failed"; exit 1; }
    for f in .scripts/api-server.sh setup.sh .lib/setup-checks.sh .env.example VERSION .scripts/fleet-bootstrap.sh; do cat "$SHIM_ROOT/$f" > "$SHIM_DIR/$f"; done
    rm -rf "$SHIM_DIR/Stacks"   # the real bundle carries no stacks: a member starts with only its own
    cd "$SHIM_DIR" || exit 1
    echo "→ (stand-in) unattended member setup on 127.0.0.1:$port for stack $DCS_STACKS as $target"
    DCS_UNATTENDED=true DCS_NO_UI=true DCS_FLEET_ROLE=member DCS_API_PORT="$port" DCS_API_BIND="$host" ./setup.sh 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'FAIL|WARN|Unattended|Joined|Join|Setup complete|API:' | tail -12
    exit "${PIPESTATUS[0]}"
    ;;
  *"tar -xzf -"*)
    # the stack moving in: the VM's install dir is the stand-in's clone
    cmd="${*//\~\/.Docker-Compose-Skeleton-AIO/$SHIM_DIR}"; bash -c "$cmd" ;;
  *) echo "stand-in: unknown command: $*" >&2; exit 1 ;;
esac
SHIM
chmod +x "$WORK/ssh-shim.sh"
_envset FLEET_SSH_CMD "$WORK/ssh-shim.sh"; _envset FLEET_SELF_URL "http://127.0.0.1:$HUB_PORT"; _envset FLEET_MEMBER_PORT "$PROV_PORT"; _envset FLEET_SSH_DIR "$WORK/.data/fleet-ssh"
export SHIM_ROOT="$ROOT" SHIM_DIR="$VMWORK"
_fleet_stop_listeners() { for d in "$WORK" "$MWORK" "$VMWORK"; do [[ -f "$d/.data/api-server.pid" ]] && (cd "$d" && "$d/.scripts/api-server.sh" --stop >/dev/null 2>&1); done; return 0; }
trap '_fleet_stop_listeners; rm -rf "$WORK" "$MWORK" "$PWORK" "$VMWORK"' EXIT
check "provision: defaults answer"      true "$(auth_request GET /fleet/provision/defaults | body_of | jq -r '.proxmox_linked' 2>/dev/null)"
check "provision: default disk storage" local-lvm "$(auth_request GET /fleet/provision/defaults | body_of | jq -r '.storage' 2>/dev/null)"
check "images: catalogue offered"       yes "$(auth_request GET /fleet/provision/defaults | body_of | jq -e '.images.catalogue | length >= 6' >/dev/null 2>&1 && echo yes || echo no)"
check "images: the default first"       dcs-debian-13 "$(auth_request GET /fleet/provision/defaults | body_of | jq -r '.images.catalogue[0].id' 2>/dev/null)"
check "images: the purpose-built ones lead" "dcs-debian-13 dcs-ubuntu-26.04 dcs-fedora-44 dcs-arch debian-13" "$(auth_request GET /fleet/provision/defaults | body_of | jq -r '.images.catalogue[:5] | map(.id) | join(" ")' 2>/dev/null)"
check "images: …marked prebuilt"          "true true true true" "$(auth_request GET /fleet/provision/defaults | body_of | jq -r '[.images.catalogue[:4][] | .prebuilt | tostring] | join(" ")' 2>/dev/null)"
check "images: …each says what its kernel drives" "4 yes" "$(auth_request GET /fleet/provision/defaults | body_of | jq -r '.images.catalogue as $c | "\([$c[:4][] | select((.hardware // "") | length > 0)] | length) \($c[0].hardware | if test("^Virtual hardware only") then "yes" else "no" end)"' 2>/dev/null)"
check "images: …fetched from this version's release" yes "$(auth_request GET /fleet/provision/defaults | body_of | jq -r '.images.catalogue[0].url' 2>/dev/null | grep -q "/releases/download/v$(tr -d '[:space:]' < "$WORK/VERSION")/dcs-node-debian-13.qcow2$" && echo yes || echo no)"
check "images: the release base can move"  "http://mirror.test/dcs/dcs-node-fedora-44.qcow2" "$(_lib eval 'FLEET_DCS_IMAGE_BASE=http://mirror.test/dcs/; _fleet_image_catalogue_json | jq -r ".[2].url"')"
check "images: the resolver reports prebuilt" "dcs-fedora-44|dnf|true|dcs-node-fedora-44.qcow2" "$(_lib eval '_fleet_resolve_image dcs-fedora-44 "" "" ""; echo "$RI_ID|$RI_FAMILY|$RI_PREBUILT|$RI_FILE"')"
check "images: …Arch is pacman, prebuilt" "dcs-arch|pacman|true|dcs-node-arch.qcow2" "$(_lib eval '_fleet_resolve_image dcs-arch "" "" ""; echo "$RI_ID|$RI_FAMILY|$RI_PREBUILT|$RI_FILE"')"
check "images: the list is vm-images/images.json (its default leads)" "dcs-$(jq -r .default "$ROOT/vm-images/images.json")" "$(auth_request GET /fleet/provision/defaults | body_of | jq -r '.images.catalogue[0].id' 2>/dev/null)"
check "images: without the file, Debian alone"  "dcs-debian-13" "$(_lib eval 'BASE_DIR=/nonexistent; _fleet_dcs_images_json http://x | jq -r "map(.id) | join(\" \")"')"

# --- disks and health: a VM with one root file system reports it; a fresh boot is not punished for days
_fakedf="$WORK/fakedf"; mkdir -p "$_fakedf"
printf '%s\n' '#!/bin/bash' 'echo "Filesystem Mounted on Size Used Avail Use%"' 'echo "/dev/sda3 / 7.8G 1.0G 6.4G 14%"' '[[ "${FAKE_DF:-}" == data ]] && echo "/dev/sdb1 /mnt/data 100G 40G 55G 42%"' 'exit 0' > "$_fakedf/df"; chmod +x "$_fakedf/df"
_disks() { PATH="$_fakedf:$PATH" FAKE_DF="$1" _lib eval "_api_success() { printf '%s' \"\$1\"; }; $2" | jq -c "$3" 2>/dev/null; }
check "disks: only /, so /system/metrics reports it"   '["/"]'        "$(_disks root handle_system_metrics '.disks | map(.mount)')"
check "disks: data disk, / stays out of /system/metrics" '["/mnt/data"]' "$(_disks data handle_system_metrics '.disks | map(.mount)')"
check "disks: only /, so /disks reports it"            '[1,["/"]]'    "$(_disks root handle_disks '[.total, [.disks[].mount]]')"
check "disks: data disk, / stays out of /disks"        '[1,["/mnt/data"]]' "$(_disks data handle_disks '[.total, [.disks[].mount]]')"
for _u in "0 50" "599 50" "600 75" "3599 75" "3600 90" "86399 90" "86400 100" "9999999 100"; do
    set -- $_u; check "health score: uptime $1 s scores $2" "$2" "$(_lib _health_uptime_score "$1")"
done
check "images: a cloud image is not prebuilt" false "$(_lib eval '_fleet_resolve_image ubuntu-24.04 "" "" ""; echo "$RI_PREBUILT"')"
check "images: nothing to bake for a DCS image" 400 "$(auth_request POST /fleet/templates '{"node":"pve","storage":"local-lvm","image_storage":"local","gateway":"192.0.2.1","ip_start":"192.0.2.90","image":"dcs-debian-13"}' | status_of)"
check "images: Ubuntu 26.04 in the list" yes "$(auth_request GET /fleet/provision/defaults | body_of | jq -e '.images.catalogue[] | select(.id == "ubuntu-26.04")' >/dev/null 2>&1 && echo yes || echo no)"
check "images: ISOs read from Proxmox"  local:iso/tiny-installer.iso "$(auth_request GET /fleet/provision/defaults | body_of | jq -r '.images.on_proxmox.isos[0].volid' 2>/dev/null)"
check "provision: unknown image refused" 400 "$(auth_request POST /fleet/provision '{"node":"pve","storage":"local-lvm","gateway":"192.0.2.1","ip_start":"192.0.2.70","image":"windows-95","vms":[{"stack":"nope"}]}' | status_of)"
check "provision: bad iso refused"      400 "$(auth_request POST /fleet/provision '{"node":"pve","storage":"local-lvm","gateway":"192.0.2.1","ip_start":"192.0.2.70","iso":"../etc/passwd","vms":[{"stack":"nope"}]}' | status_of)"
check "provision: token may create VMs" true "$(auth_request GET /proxmox/capabilities | body_of | jq -r '.can_provision' 2>/dev/null)"
check "provision: storages listed"      yes "$(auth_request GET /proxmox/storage | body_of | jq -e '.storages | map(.storage) | index("local") != null' >/dev/null 2>&1 && echo yes || echo no)"
check "provision: viewer denied"        403 "$(viewer_request GET /fleet/jobs | status_of)"
check "provision: needs a stack"        400 "$(auth_request POST /fleet/provision '{"node":"pve","storage":"local-lvm","gateway":"192.0.2.1","vms":[]}' | status_of)"
check "provision: bad name refused"     400 "$(auth_request POST /fleet/provision '{"node":"pve","storage":"local-lvm","gateway":"192.0.2.1","vms":[{"stack":"Bad Name"}]}' | status_of)"
check "provision: local stack refused"  409 "$(auth_request POST /fleet/provision '{"node":"pve","storage":"local-lvm","gateway":"192.0.2.1","ip_start":"192.0.2.50","vms":[{"stack":"demo"}]}' | status_of)"
check "provision: same-named guest refused" 409 "$(auth_request POST /fleet/provision '{"node":"pve","storage":"local-lvm","gateway":"192.0.2.1","ip_start":"192.0.2.60","vms":[{"stack":"networking-security"}]}' | status_of)"
check "provision: twin guest named"     yes "$(auth_request POST /fleet/provision '{"node":"pve","storage":"local-lvm","gateway":"192.0.2.1","ip_start":"192.0.2.60","vms":[{"stack":"networking-security"}]}' | body_of | grep -q 'qemu 101 on pve' && echo yes)"
# a request is refused whole: the stacks listed before the bad one are not left queued (they blocked every retry)
_PVJ="$WORK/.data/fleet-jobs"; _pvj() { find "$_PVJ" -name "*$1*" 2>/dev/null | wc -l; }; _PVB='"node":"pve","storage":"local-lvm","gateway":"192.0.2.1","ip_start":"192.0.2.60"'
check "provision: a later refusal is a 409"     409 "$(auth_request POST /fleet/provision "{$_PVB,\"vms\":[{\"stack\":\"zz-first\"},{\"stack\":\"networking-security\"}]}" | status_of)"
check "provision: …and queues nothing"           0 "$(_pvj zz-first)"
check "provision: …no address kept for it"       0 "$(grep -c 'zz-first' "$WORK/.data/fleet.json" 2>/dev/null)"
check "provision: a stack listed twice"        409 "$(auth_request POST /fleet/provision "{$_PVB,\"vms\":[{\"stack\":\"zz-dup\"},{\"stack\":\"zz-dup\"}]}" | status_of)"
check "provision: …queues nothing either"        0 "$(_pvj zz-dup)"
check "provision: one address for two VMs"     409 "$(auth_request POST /fleet/provision "{$_PVB,\"vms\":[{\"stack\":\"zz-a\",\"ip\":\"192.0.2.77\"},{\"stack\":\"zz-b\",\"ip\":\"192.0.2.77\"}]}" | status_of)"
check "provision: …queues nothing as well"       0 "$(( $(_pvj zz-a) + $(_pvj zz-b) ))"
check "provision defaults: the guests Proxmox has" yes "$(auth_request GET /fleet/provision/defaults | body_of | jq -e '(.guests | map(.name)) as $g | ($g | index("networking-security") != null) and ($g | index("template-debian") == null)' >/dev/null 2>&1 && echo yes || echo no)"
check "provision defaults: a guest's memory (for the capacity bar)" 8 "$(auth_request GET /fleet/provision/defaults | body_of | jq -r '.guests[] | select(.name == "media-vm") | .maxmem_gb' 2>/dev/null)"
# stacks with containers up on the hub are reported (they cannot become VMs while they run here)
mkdir -p "$WORK/fakebin2" && printf '#!/bin/bash\n[[ "$1 $2 $3" == "compose ls --format" ]] && { echo "[{\\"Name\\":\\"demo\\",\\"Status\\":\\"running(1)\\"}]"; exit 0; }\nexec "%s/fakebin/docker" "$@"\n' "$WORK" > "$WORK/fakebin2/docker" && chmod +x "$WORK/fakebin2/docker"
check "provision defaults: stacks running on the hub" demo "$(PATH="$WORK/fakebin2:$PATH" auth_request GET /fleet/provision/defaults | body_of | jq -r '.running_stacks | join(" ")' 2>/dev/null)"
# what counts as the hub's own stack: DOCKER_STACKS or containers up — not a folder the repository ships
mkdir -p "$WORK/Stacks/leftover" && printf 'services:\n  x:\n    image: alpine\n' > "$WORK/Stacks/leftover/docker-compose.yml"
check "hub stack: in DOCKER_STACKS"     0 "$(_lib _fleet_stack_is_hub demo; echo $?)"
check "hub stack: a folder alone is not" 1 "$(_lib _fleet_stack_is_hub leftover; echo $?)"
check "hub stack: unknown name"         1 "$(_lib _fleet_stack_is_hub nowhere; echo $?)"
# the hub has a Stacks/smoke-photos folder (not in DOCKER_STACKS): the build moves it into the VM and starts it there
# (the hub and the stand-in share this machine's Docker, so the hub's folder carries another name: a renamed row, source ≠ stack)
mkdir -p "$WORK/Stacks/smoke-photos-src" && printf 'services:\n  x:\n    image: alpine:3\n    command: ["sleep","infinity"]\n' > "$WORK/Stacks/smoke-photos-src/docker-compose.yml" && printf 'SMOKE_PHOTOS=1\nSMOKE_TOKEN=${SECRETS_SMOKE_TRAVEL}\n' > "$WORK/Stacks/smoke-photos-src/.env"
auth_request POST /secrets '{"key":"SMOKE_TRAVEL","value":"travels-with-the-stack"}' >/dev/null   # the stack refers to it: it must follow the stack into the VM
_PROV_BODY="{\"node\":\"pve\",\"storage\":\"local-lvm\",\"image_storage\":\"local\",\"bridge\":\"vmbr0\",\"cidr\":24,\"gateway\":\"192.0.2.1\",\"dns\":\"192.0.2.1\",\"image\":\"ubuntu-24.04\",\"vms\":[{\"stack\":\"smoke-photos\",\"source\":\"smoke-photos-src\",\"cores\":2,\"memory_mb\":2048,\"disk_gb\":16,\"ip\":\"127.0.0.1\"}]}"
PROV=$(auth_request POST /fleet/provision "$_PROV_BODY")
check "provision: job queued"           true "$(body_of <<< "$PROV" | jq -r '.success' 2>/dev/null)"
JOB=$(body_of <<< "$PROV" | jq -r '.jobs[0].id' 2>/dev/null)
check "provision: repeat refused"       409 "$(auth_request POST /fleet/provision "$_PROV_BODY" | status_of)"
check "provision: join code minted"     yes "$(auth_request GET /fleet/join-tokens | body_of | jq -e '.tokens[] | select(.stack == "smoke-photos")' >/dev/null 2>&1 && echo yes || echo no)"
_JST=""; for _i in $(seq 1 150); do _JST=$(auth_request GET "/fleet/jobs/$JOB" | body_of | jq -r '.status' 2>/dev/null); [[ "$_JST" == "done" || "$_JST" == "failed" ]] && break; sleep 2; done
check "provision: job finished"         "done" "$_JST"
[[ "$_JST" == "done" ]] || { echo "  --- job log ---"; auth_request GET "/fleet/jobs/$JOB" | body_of | jq -r '.error, (.steps[] | "\(.id): \(.state) \(.detail)"), (.log[-25:][] | .text)' 2>/dev/null | sed 's/^/  /'; echo "  --- runner log ---"; tail -5 "$WORK/logs/fleet-jobs.log" 2>/dev/null | sed 's/^/  /'; }
check "provision: every step done"      9 "$(auth_request GET "/fleet/jobs/$JOB" | body_of | jq -r '[.steps[] | select(.state == "done")] | length' 2>/dev/null)"
check "provision: the chosen image"     ubuntu-24.04-server-cloudimg-amd64.qcow2 "$(auth_request GET "/fleet/jobs/$JOB" | body_of | jq -r '.image_file' 2>/dev/null)"
check "provision: image family"         apt "$(auth_request GET "/fleet/jobs/$JOB" | body_of | jq -r '.family' 2>/dev/null)"
check "provision: image imported"       yes "$(auth_request GET "/fleet/jobs/$JOB" | body_of | jq -r '.log[].text' 2>/dev/null | grep -q 'image ready on local' && echo yes || echo no)"
check "provision: VM created"           smoke-photos "$(auth_request GET /proxmox/vms | body_of | jq -r '.vms[] | select(.vmid == 105) | .name' 2>/dev/null)"
check "provision: cloud-init address"   yes "$(auth_request GET /proxmox/vms/pve/qemu/105 | body_of | jq -r '.config.ipconfig0 // ""' 2>/dev/null | grep -q '127.0.0.1/24' && echo yes || echo no)"
check "provision: hub key in cloud-init" yes "$(auth_request GET /proxmox/vms/pve/qemu/105 | body_of | jq -r '.config.sshkeys // ""' 2>/dev/null | grep -q 'ssh-ed25519' && echo yes || echo no)"
check "provision: boot menu wait switched off" yes "$(auth_request GET /proxmox/vms/pve/qemu/105 | body_of | jq -r '.config.args // ""' 2>/dev/null | grep -q -e '-boot menu=off' && echo yes || echo no)"
check "provision: …and the log says so"    yes "$(auth_request GET "/fleet/jobs/$JOB" | body_of | jq -r '.log[].text' 2>/dev/null | grep -q 'boot menu wait switched off' && echo yes || echo no)"
# a token that may not set 'args' (only root@pam may): the refusal is logged and remembered, nothing else fails
: > "$WORK/.data/deny-args"
_lib eval "_fleet_vm_fast_boot '$JOB' pve 105" >/dev/null
check "provision: args refused, said in the log" yes "$(auth_request GET "/fleet/jobs/$JOB" | body_of | jq -r '.log[].text' 2>/dev/null | grep -q 'boot menu wait left on' && echo yes || echo no)"
check "provision: …the refusal is remembered"    yes "$([[ -e "$WORK/.data/pve-args-refused" ]] && echo yes || echo no)"
rm -f "$WORK/.data/deny-args"
_bm() { auth_request GET "/fleet/jobs/$JOB" | body_of | jq -r '[.log[].text | select(test("boot menu wait"))] | length' 2>/dev/null; }
_bm_before=$(_bm); _lib eval "_fleet_vm_fast_boot '$JOB' pve 105" >/dev/null
check "provision: …and not asked again"          "$_bm_before" "$(_bm)"
rm -f "$WORK/.data/pve-args-refused"
check "vm info: the guest's own system"       "Debian GNU/Linux 13 (trixie)" "$(auth_request GET /proxmox/vms/pve/qemu/100 | body_of | jq -r '.os.name // ""' 2>/dev/null)"
check "vm info: …and its kernel"                "6.12.111+deb13-cloud-amd64" "$(auth_request GET /proxmox/vms/pve/qemu/100 | body_of | jq -r '.os.kernel // ""' 2>/dev/null)"
check "vm info: a guest without the agent has no system" null "$(auth_request GET /proxmox/vms/pve/qemu/101 | body_of | jq -r '.os | tostring' 2>/dev/null)"
check "vm info: firmware and machine"           "ovmf q35" "$(auth_request GET /proxmox/vms/pve/qemu/100 | body_of | jq -r '"\(.config.bios) \(.config.machine)"' 2>/dev/null)"
check "vm info: creation date"                  1790000000 "$(auth_request GET /proxmox/vms/pve/qemu/100 | body_of | jq -r '.config.created' 2>/dev/null)"
check "vm info: not built by DCS, no image"     null "$(auth_request GET /proxmox/vms/pve/qemu/100 | body_of | jq -r '.image | tostring' 2>/dev/null)"
check "vm info: a built VM names its image"     ubuntu-24.04 "$(auth_request GET /proxmox/vms/pve/qemu/105 | body_of | jq -r '.image.id // ""' 2>/dev/null)"
check "vm info: …with the catalogue's label"    yes "$(auth_request GET /proxmox/vms/pve/qemu/105 | body_of | jq -r '.image.label // ""' 2>/dev/null | grep -q 'Ubuntu Server 24.04' && echo yes || echo no)"
check "vm info: the description names the image" yes "$(auth_request GET /proxmox/vms/pve/qemu/105 | body_of | jq -r '.config.description // ""' 2>/dev/null | grep -q 'image ubuntu-24.04' && echo yes || echo no)"
check "provision: member registered"    105 "$(auth_request GET /fleet/members | body_of | jq -r '.members[] | select(.name == "smoke-photos") | .vmid' 2>/dev/null)"
check "provision: member runs the stack" smoke-photos "$(auth_request GET /fleet/members | body_of | jq -r '.members[] | select(.name == "smoke-photos") | .stacks[0]' 2>/dev/null)"
check "provision: stack moved into the VM" yes "$(auth_request GET "/fleet/jobs/$JOB" | body_of | jq -r '.steps[] | select(.id == "stack") | .detail' 2>/dev/null | grep -q 'started in the VM' && echo yes || echo no)"
check "provision: source folder named"  yes "$(auth_request GET "/fleet/jobs/$JOB" | body_of | jq -r '.log[].text' 2>/dev/null | grep -q 'Stacks/smoke-photos-src from the hub copied into the VM as smoke-photos' && echo yes || echo no)"
check "provision: VM has the compose"   yes "$(auth_request GET /stacks/smoke-photos/compose | body_of | jq -r '.content // .compose // ""' 2>/dev/null | grep -q 'sleep' && echo yes || echo no)"
# the stack was started a moment ago: a slow runner may look before the VM's docker says "running" (or its cached answer expires)
_stk=""; for _i in $(seq 1 30); do _stk=$(auth_request GET /stacks/smoke-photos | body_of | jq -r '.status' 2>/dev/null | cut -d: -f1); [[ "$_stk" == running ]] && break; sleep 1; done
check "provision: stack running in VM"  running "$_stk"
check "provision: the stack's secret travelled" yes "$(auth_request GET /fleet/members/smoke-photos/api/secrets | body_of | jq -e '[.secrets[] | if type == "object" then .key else . end] | index("SMOKE_TRAVEL") != null' >/dev/null 2>&1 && echo yes || echo no)"
check "provision: secret copy logged"   yes "$(auth_request GET "/fleet/jobs/$JOB" | body_of | jq -r '.log[].text' 2>/dev/null | grep -q 'secret(s) the stack uses copied' && echo yes || echo no)"
# the hub's own start.sh never starts a folder that lives in a VM, whatever DOCKER_STACKS says
# shellcheck disable=SC2034  # COMPOSE_DIR is read by the function pulled out of run.sh
_owned() { ( COMPOSE_DIR="$WORK/Stacks"; eval "$(sed -n '/^_fleet_owned_stack()/,/^}/p' "$ROOT/.scripts/run.sh")"; _fleet_owned_stack "$1"; echo $? ); }
check "start.sh: a VM's stack is not the hub's to start" 0 "$(_owned smoke-photos)"
check "start.sh: the hub's own stack is"    1 "$(_owned demo)"
check "provision: member marked built"  true "$(auth_request GET /fleet/members | body_of | jq -r '.members[] | select(.name == "smoke-photos") | .provisioned' 2>/dev/null)"
check "provision: admin password kept"  yes "$(_lib secrets_exists FLEET_MEMBER_SMOKE_PHOTOS_ADMIN_PASSWORD && echo yes || echo no)"
check "provision: audited"              yes "$(grep -q 'fleet_vm_ready' "$WORK/.data/audit.jsonl" 2>/dev/null && echo yes || echo no)"
check "provision: the VM knows its role" member "$(grep -m1 '^FLEET_ROLE=' "$VMWORK/.env" 2>/dev/null | cut -d= -f2)"
_MADM=$(auth_request GET /fleet/members | body_of | jq -r '.members[] | select(.name == "smoke-photos") | .url' 2>/dev/null)
check "member: unattended setup complete" true "$(curl -s -m 5 "$_MADM/setup/status" | jq -r '.initialized' 2>/dev/null)"
check "member: API only, one stack"     smoke-photos "$(curl -s -m 5 -X POST "$_MADM/auth/login" -H 'Content-Type: application/json' -d "{\"username\":\"admin\",\"password\":\"$(_lib secrets_get FLEET_MEMBER_SMOKE_PHOTOS_ADMIN_PASSWORD)\"}" | jq -r '.token' 2>/dev/null | xargs -I{} curl -s -m 5 "$_MADM/stacks" -H 'Authorization: Bearer {}' | jq -r '.stacks | map(.name) | join(",")' 2>/dev/null)"
echo "The hub's API is the fleet API"
check "hub: /stacks lists the VM stack" vm "$(auth_request GET /stacks | body_of | jq -r '.stacks[] | select(.name == "smoke-photos") | .placement' 2>/dev/null)"
check "hub: local stacks tagged hub"    hub "$(auth_request GET /stacks | body_of | jq -r '.stacks[] | select(.name == "demo") | .placement' 2>/dev/null)"
check "hub: remote count"               1 "$(auth_request GET /stacks | body_of | jq -r '.remote' 2>/dev/null)"
check "hub: /stacks/{vm stack} forwarded" smoke-photos "$(auth_request GET /stacks/smoke-photos | body_of | jq -r '.name' 2>/dev/null)"
check "hub: compose of the VM stack"    200 "$(auth_request GET /stacks/smoke-photos/compose | status_of)"
check "hub: unknown stack still 404"    404 "$(auth_request GET /stacks/nope-none | status_of)"
_TPL=$(ls "$ROOT/.templates" | head -1)
check "hub: dry run lands on the VM"    200 "$(auth_request POST "/templates/$_TPL/dry-run" '{"target_stack":"smoke-photos"}' | status_of)"
check "hub: forwarded post audited"     yes "$(grep -q '"action":"fleet_proxy"' "$WORK/.data/audit.jsonl" 2>/dev/null && echo yes || echo no)"
check "hub: /containers has member field" yes "$(auth_request GET /containers | body_of | jq -e 'has("containers")' >/dev/null 2>&1 && echo yes || echo no)"
check "hub: viewer reads the VM stack"  200 "$(viewer_request GET /stacks/smoke-photos | status_of)"
check "hub: viewer cannot start it"     403 "$(viewer_request POST /stacks/smoke-photos/start '{}' | status_of)"
check "jobs: listed"                    1 "$(auth_request GET /fleet/jobs | body_of | jq -r '.total' 2>/dev/null)"
check "jobs: retry only when failed"    409 "$(auth_request POST "/fleet/jobs/$JOB/retry" '{}' | status_of)"
check "destroy: member and VM removed"  true "$(auth_request DELETE '/fleet/members/smoke-photos?destroy=true' | body_of | jq -r '.vm_destroyed' 2>/dev/null)"
check "destroy: VM gone from Proxmox"   "" "$(auth_request GET /proxmox/vms | body_of | jq -r '.vms[] | select(.vmid == 105) | .name' 2>/dev/null)"
check "destroy: audited"                yes "$(grep -q 'fleet_vm_destroyed' "$WORK/.data/audit.jsonl" 2>/dev/null && echo yes || echo no)"
check "jobs: delete"                    200 "$(auth_request DELETE "/fleet/jobs/$JOB" | status_of)"
# an ISO from Proxmox: the hub builds the VM with the installer attached and stops there — the install is by hand
ISOJ=$(auth_request POST /fleet/provision '{"node":"pve","storage":"local-lvm","gateway":"192.0.2.1","ip_start":"192.0.2.80","iso":"local:iso/tiny-installer.iso","vms":[{"stack":"by-hand-box","cores":1,"memory_mb":1024,"disk_gb":12}]}')
check "iso build: queued"               true "$(body_of <<< "$ISOJ" | jq -r '.success' 2>/dev/null)"
IJOB=$(body_of <<< "$ISOJ" | jq -r '.jobs[0].id' 2>/dev/null)
_IST=""; for _i in $(seq 1 60); do _IST=$(auth_request GET "/fleet/jobs/$IJOB" | body_of | jq -r '.status' 2>/dev/null); [[ "$_IST" == "done" || "$_IST" == "failed" ]] && break; sleep 2; done
check "iso build: done at the boot"     "done" "$_IST"
check "iso build: by hand from here"    true "$(auth_request GET "/fleet/jobs/$IJOB" | body_of | jq -r '.manual' 2>/dev/null)"
_IVM=$(auth_request GET "/fleet/jobs/$IJOB" | body_of | jq -r '.vmid' 2>/dev/null)
check "iso build: VM has the ISO"       yes "$(auth_request GET "/proxmox/vms/pve/qemu/$_IVM" | body_of | jq -r '.config.ide2 // ""' 2>/dev/null | grep -q 'tiny-installer.iso' && echo yes || echo no)"
check "iso build: join line in the log" yes "$(auth_request GET "/fleet/jobs/$IJOB" | body_of | jq -r '.log[].text' 2>/dev/null | grep -q 'DCS_JOIN_TOKEN=' && echo yes || echo no)"
check "iso build: dismiss destroys it"  true "$(auth_request DELETE "/fleet/jobs/$IJOB?destroy=true" | body_of | jq -r '.vm_destroyed' 2>/dev/null)"
# a baked DCS template: one bake job (the stand-in installs nothing and "powers off"; the hub shuts the VM down and makes it a template),
# then a build that clones it instead of importing the image
BK=$(auth_request POST /fleet/templates '{"node":"pve","storage":"local-lvm","image_storage":"local","gateway":"192.0.2.1","ip_start":"192.0.2.90","image":"debian-13"}')
check "bake: queued"                    true "$(body_of <<< "$BK" | jq -r '.success' 2>/dev/null)"
BJOB=$(body_of <<< "$BK" | jq -r '.jobs[0].id' 2>/dev/null)
_BST=""; for _i in $(seq 1 90); do _BST=$(auth_request GET "/fleet/jobs/$BJOB" | body_of | jq -r '.status' 2>/dev/null); [[ "$_BST" == "done" || "$_BST" == "failed" ]] && break; sleep 2; done
check "bake: finished"                  "done" "$_BST"
[[ "$_BST" == "done" ]] || auth_request GET "/fleet/jobs/$BJOB" | body_of | jq -r '.error, (.steps[] | "\(.id): \(.state) \(.detail)"), (.log[-12:][] | .text)' 2>/dev/null | sed 's/^/    /'
check "bake: eight steps done"          8 "$(auth_request GET "/fleet/jobs/$BJOB" | body_of | jq -r '[.steps[] | select(.state == "done")] | length' 2>/dev/null)"
TVM=$(auth_request GET /fleet/templates | body_of | jq -r '.templates[0].vmid' 2>/dev/null)
check "bake: template recorded"         debian-13 "$(auth_request GET /fleet/templates | body_of | jq -r '.templates[0].image_id' 2>/dev/null)"
check "bake: twice refused"             409 "$(auth_request POST /fleet/templates '{"node":"pve","storage":"local-lvm","gateway":"192.0.2.1","ip_start":"192.0.2.90","image":"debian-13"}' | status_of)"
check "defaults: template offered"      1 "$(auth_request GET /fleet/provision/defaults | body_of | jq -r '.images.templates | length' 2>/dev/null)"
CL=$(auth_request POST /fleet/provision "{\"node\":\"pve\",\"storage\":\"local-lvm\",\"image_storage\":\"local\",\"bridge\":\"vmbr0\",\"cidr\":24,\"gateway\":\"192.0.2.1\",\"dns\":\"192.0.2.1\",\"ip_start\":\"192.0.2.91\",\"image\":\"debian-13\",\"vms\":[{\"stack\":\"smoke-clone\",\"cores\":1,\"memory_mb\":1024,\"disk_gb\":12,\"ip\":\"127.0.0.1\"}]}")
CJOB=$(body_of <<< "$CL" | jq -r '.jobs[0].id' 2>/dev/null)
_CST=""; for _i in $(seq 1 150); do _CST=$(auth_request GET "/fleet/jobs/$CJOB" | body_of | jq -r '.status' 2>/dev/null); [[ "$_CST" == "done" || "$_CST" == "failed" ]] && break; sleep 2; done
check "clone build: finished"           "done" "$_CST"
[[ "$_CST" == "done" ]] || auth_request GET "/fleet/jobs/$CJOB" | body_of | jq -r '.error, (.steps[] | "\(.id): \(.state) \(.detail)"), (.log[-12:][] | .text)' 2>/dev/null | sed 's/^/    /'
check "clone build: cloned the template" yes "$(auth_request GET "/fleet/jobs/$CJOB" | body_of | jq -r '.log[].text' 2>/dev/null | grep -q 'cloning the DCS template VM' && echo yes || echo no)"
check "clone build: member joined"      smoke-clone "$(auth_request GET /fleet/members | body_of | jq -r '.members[] | select(.name == "smoke-clone") | .id' 2>/dev/null)"
auth_request DELETE '/fleet/members/smoke-clone?destroy=true' >/dev/null; auth_request DELETE "/fleet/jobs/$CJOB" >/dev/null; auth_request DELETE "/fleet/jobs/$BJOB" >/dev/null
check "template: deleted with its VM"   true "$(auth_request DELETE "/fleet/templates/$TVM" | body_of | jq -r '.success' 2>/dev/null)"
(cd "$VMWORK" && "$VMWORK/.scripts/api-server.sh" --stop >/dev/null 2>&1)
(cd "$VMWORK" && "$VMWORK/.scripts/api-server.sh" --stop >/dev/null 2>&1)
(cd "$VMWORK/Stacks/smoke-photos" 2>/dev/null && docker compose -p smoke-photos down --remove-orphans >/dev/null 2>&1) || true
# --stop trusts the pid file only for this installation's own server (a copied .data/ must never stop another one)
mkdir -p "$WORK/stopcheck/.scripts" "$WORK/stopcheck/.data"
cat "$API" > "$WORK/stopcheck/.scripts/api-server.sh"; chmod +x "$WORK/stopcheck/.scripts/api-server.sh"
printf 'API_PORT=1\n' > "$WORK/stopcheck/.env"
sleep 60 & _FOREIGN=$!
printf '%s' "$_FOREIGN" > "$WORK/stopcheck/.data/api-server.pid"
_STOP_OUT=$(cd "$WORK/stopcheck" && ./.scripts/api-server.sh --stop 2>&1)
check "stop: foreign pid file ignored"   yes "$(kill -0 "$_FOREIGN" 2>/dev/null && echo yes || echo no)"
check "stop: foreign pid file reported"  yes "$(grep -q 'not this installation' <<< "$_STOP_OUT" && echo yes || echo no)"
kill "$_FOREIGN" 2>/dev/null; wait "$_FOREIGN" 2>/dev/null
_envdel FLEET_SSH_CMD; _envdel FLEET_SELF_URL; _envdel FLEET_MEMBER_PORT; _envdel FLEET_SSH_DIR; unset SHIM_ROOT SHIM_DIR
rm -rf "$WORK/.data/fleet-jobs" "$WORK/.data/fleet-ssh"

_fleet_stop_listeners
_envdel API_AUTH_ENABLED; _envdel FLEET_SCAN_PORTS; _envset API_PORT 9876
rm -f "$WORK/.data/fleet.json" "$WORK/.data/fleet-watch.stamp"; rm -rf "$WORK/.data/fleet-sessions"
trap '(cd "$VMWORK/Stacks/smoke-photos" 2>/dev/null && docker compose -p smoke-photos down --remove-orphans >/dev/null 2>&1); rm -rf "$WORK" "$MWORK" "$PWORK" "$VMWORK"' EXIT

check "proxmox: watcher silent first"   0 "$(PROXMOX_STATE_FILE="$WORK/.data/pve-state.json" _lib _pve_watch; grep -c 'proxmox_vm_stopped' "$WORK/.data/audit.jsonl" 2>/dev/null)"
auth_request POST /proxmox/vms/pve/qemu/100/stop '{}' >/dev/null   # DCS asked: never an alert
_lib _api_jq_update_file "$WORK/.data/intended.json" 'del(."pve:100")' >/dev/null 2>&1 || true
touch -d '-2 minutes' "$WORK/.data/pve-state.json" 2>/dev/null
PROXMOX_STATE_FILE="$WORK/.data/pve-state.json" _lib _pve_watch
check "proxmox: unexpected stop noticed" 1 "$(grep -c 'proxmox_vm_stopped' "$WORK/.data/audit.jsonl" 2>/dev/null)"
check "event style: vm stopped"         "VM stopped on its own" "$(_lib _discord_event_style proxmox_vm_stopped | cut -d'|' -f3)"
check "notify wording: vm stopped"      "VM {vm} stopped" "$(_lib eval '_notify_default_templates proxmox_vm_stopped; printf %s "$NT_TITLE"')"
kill $_PVE_PID 2>/dev/null; wait $_PVE_PID 2>/dev/null
_envdel PROXMOX_URL; _envdel PROXMOX_TOKEN_ID; _envdel PROXMOX_TOKEN_SECRET
check "proxmox: unlinked again"         false "$(auth_request GET /proxmox/status | body_of | jq -r '.configured' 2>/dev/null)"

echo "Traefik feed"
check "feed: off by default"            401 "$(request GET '/traefik/dynamic?token=x' '' "${AUTH[@]}" | status_of)"
check "feed: status off"                false "$(auth_request GET /traefik/feed/status | body_of | jq -r '.enabled' 2>/dev/null)"
_envset TRAEFIK_FEED_ENABLED true; _envset TRAEFIK_FEED_TOKEN feed-secret; _envset TRAEFIK_FEED_TARGET_HOST 10.0.0.9
_FEED_DIR=$(_lib _find_traefik_routes_dir)
check "feed: routes dir resolved"       yes "$([[ -n "$_FEED_DIR" ]] && echo yes || echo no)"
mkdir -p "$_FEED_DIR/demo"
printf 'http:\n  routers:\n    whoami-router:\n      entryPoints:\n        - "websecure"\n      rule: "Host(`whoami.example.com`)"\n      service: "whoami"\n      middlewares:\n        - "traefik-chain"\n      tls: {}\n  services:\n    whoami:\n      loadBalancer:\n        servers:\n          - url: "http://10.0.0.5:8080"\n' > "$_FEED_DIR/demo/whoami.yml"
check "feed: wrong token"               401 "$(request GET '/traefik/dynamic?token=nope' '' "${AUTH[@]}" | status_of)"
_FD=$(request GET '/traefik/dynamic?token=feed-secret' '' "${AUTH[@]}")
check "feed: token in query works"      200 "$(printf '%s' "$_FD" | status_of)"
check "feed: router served"             'Host(`whoami.example.com`)' "$(printf '%s' "$_FD" | body_of | jq -r '.http.routers["whoami-dcs"].rule' 2>/dev/null)"
check "feed: non-container url kept"    http://10.0.0.5:8080 "$(printf '%s' "$_FD" | body_of | jq -r '.http.services["whoami-dcs"].loadBalancer.servers[0].url' 2>/dev/null)"
check "feed: remote middlewares only"   null "$(printf '%s' "$_FD" | body_of | jq -r '.http.routers["whoami-dcs"].middlewares' 2>/dev/null)"
check "feed: tls on"                    yes "$(printf '%s' "$_FD" | body_of | jq -e '.http.routers["whoami-dcs"].tls' >/dev/null 2>&1 && echo yes || echo no)"
check "feed: bearer token works"        200 "$(printf 'GET /traefik/dynamic HTTP/1.1\r\nHost: test\r\nAuthorization: Bearer feed-secret\r\n\r\n' | env DOCKER_COMPOSE_CMD="${DOCKER_COMPOSE_CMD:-docker compose}" "${AUTH[@]}" "$API" --handle-request 2>/dev/null | status_of)"
check "feed: status counts routes"      yes "$([[ "$(auth_request GET /traefik/feed/status | body_of | jq -r '.routes' 2>/dev/null)" -ge 1 ]] && echo yes || echo no)"
check "feed: status has snippet"        yes "$(auth_request GET /traefik/feed/status | body_of | jq -r '.snippet' 2>/dev/null | grep -q 'providers:' && echo yes || echo no)"
check "feed: last poll recorded"        yes "$([[ "$(auth_request GET /traefik/feed/status | body_of | jq -r '.last_poll' 2>/dev/null)" -gt 0 ]] && echo yes || echo no)"
check "feed: viewer may not see status" 403 "$(viewer_request GET /traefik/feed/status | status_of)"
check "feed: token rotated"             yes "$([[ "$(auth_request POST /traefik/feed/token '{}' | body_of | jq -r '.token' 2>/dev/null | wc -c)" -ge 40 ]] && echo yes || echo no)"
check "feed: old token refused"         401 "$(request GET '/traefik/dynamic?token=feed-secret' '' "${AUTH[@]}" | status_of)"
_envdel TRAEFIK_FEED_ENABLED; _envdel TRAEFIK_FEED_TOKEN; _envdel TRAEFIK_FEED_TARGET_HOST; _envdel API_RESPONSE_CACHE
rm -rf "$_FEED_DIR/demo/whoami.yml"
check "crowdsec alerts: viewer denied"  403 "$(viewer_request POST /crowdsec/notifications '{}' | status_of)"

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
    check "nuke: unknown container"     404 "$(auth_request GET /containers/nope-none/reset | status_of)"
else
    echo "  skip (no Docker daemon)"
fi

echo "Routes: template defaults, Authelia by default, the rebuild; the fleet's domain; the engine card; Cloudflare + DDNS against a stand-in"
# templates: one with a variable default and a published port, one whose apps bring their own clients (auth: bypass)
mkdir -p "$WORK/.templates/routed-tpl" "$WORK/.templates/bypass-tpl" "$WORK/Stacks/demo2"
printf '{"name":"routed-tpl","title":"Routed","category":"other","variables":[{"name":"ROUTED_PORT","label":"Port","default":"8123"}]}\n' > "$WORK/.templates/routed-tpl/template.json"
printf 'services:\n  routed-tpl:\n    image: alpine\n    container_name: Routed\n    ports:\n      - "${ROUTED_PORT}:80"\n' > "$WORK/.templates/routed-tpl/docker-compose.yml"
printf '{"name":"bypass-tpl","title":"Bypass","category":"other","auth":"bypass","variables":[]}\n' > "$WORK/.templates/bypass-tpl/template.json"
printf 'services:\n  bypass-tpl:\n    image: alpine\n    container_name: Bypass\n    ports:\n      - "8124:80"\n' > "$WORK/.templates/bypass-tpl/docker-compose.yml"
printf 'services:\n  placeholder:\n    image: alpine\n' > "$WORK/Stacks/demo2/docker-compose.yml"
# the proxy stack: a domain, and a Traefik that knows the Authelia forward-auth middleware
check "fleet domain: placeholder is none"    "" "$(_lib _fleet_domain)"
printf 'TRAEFIK_DOMAIN=smoke.test\n' >> "$WORK/Stacks/zz-proxy/.env"
_ZZR="$WORK/Stacks/zz-proxy/App-Data/Traefik/custom_routes"
printf 'http:\n  middlewares:\n    traefik-chain:\n      chain:\n        middlewares:\n          - "https-redirect"\n    compress-gzip:\n      compress: {}\n    authelia-forwardauth:\n      forwardAuth:\n        address: "http://Authelia:9091/api/verify?rd=https://auth.smoke.test"\n' > "$_ZZR/core-infrastructure/traefik.yml"
sed -i 's/^DOCKER_STACKS=.*/DOCKER_STACKS="demo demo2 zz-proxy"/' "$WORK/.env"
fake_request() { PATH="$WORK/fakebin:$PATH" auth_request "$@"; }
rm -f "$WORK/fakebin/.authelia"
check "authelia absent: no middleware"      "" "$(PATH="$WORK/fakebin:$PATH" _lib _traefik_authelia_middleware)"
touch "$WORK/fakebin/.authelia"
check "authelia present: middleware found"  authelia-forwardauth "$(PATH="$WORK/fakebin:$PATH" _lib _traefik_authelia_middleware)"
check "bypass template recognised"          0 "$(_lib _authelia_bypass_template bypass-tpl; echo $?)"
check "routed template not bypass"          1 "$(_lib _authelia_bypass_template routed-tpl; echo $?)"
_D1=$(fake_request POST /templates/routed-tpl/deploy '{"target_stack":"demo","auto_start":false}')
check "deploy without variables works"      200 "$(printf '%s' "$_D1" | status_of)"
check "deploy: template default applied"    8123 "$(grep -m1 '^ROUTED_PORT=' "$WORK/Stacks/demo/.env" | cut -d= -f2 | tr -d '"')"
check "deploy: route written"               yes "$([[ -f "$_ZZR/demo/routed-tpl.yml" ]] && echo yes || echo no)"
check "deploy: route host from the domain"  1 "$(grep -c 'Host(`routed-tpl.smoke.test`)' "$_ZZR/demo/routed-tpl.yml")"
check "deploy: route behind Authelia"       1 "$(grep -c '"authelia-forwardauth"' "$_ZZR/demo/routed-tpl.yml")"
check "deploy: chain kept"                  1 "$(grep -c '"traefik-chain"' "$_ZZR/demo/routed-tpl.yml")"
fake_request POST /templates/bypass-tpl/deploy '{"target_stack":"demo","auto_start":false}' >/dev/null
check "deploy: bypass template stays open"  0 "$(grep -c '"authelia-forwardauth"' "$_ZZR/demo/bypass-tpl.yml")"
fake_request POST /templates/routed-tpl/deploy '{"target_stack":"demo2","auto_start":false,"authelia_services":[]}' >/dev/null
check "deploy: explicit none respected"     0 "$(grep -c '"authelia-forwardauth"' "$_ZZR/demo2/routed-tpl.yml")"
check "deploy: explicit none is marked"     1 "$(grep -c '^# authelia: off' "$_ZZR/demo2/routed-tpl.yml")"
# a route written before Authelia arrived
printf 'http:\n  routers:\n    old-router:\n      entryPoints:\n        - "websecure"\n      rule: "Host(`old.smoke.test`)"\n      service: "old"\n      middlewares:\n        - "traefik-chain"\n        - "compress-gzip"\n      tls: {}\n  services:\n    old:\n      loadBalancer:\n        servers:\n          - url: "http://Old:80"\n' > "$_ZZR/demo/old.yml"
check "authelia arrives: old route protected" 1 "$(PATH="$WORK/fakebin:$PATH" _lib _authelia_protect_existing_routes)"
check "authelia arrives: middleware placed"   1 "$(grep -c '"authelia-forwardauth"' "$_ZZR/demo/old.yml")"
check "authelia arrives: not twice"           0 "$(PATH="$WORK/fakebin:$PATH" _lib _authelia_protect_existing_routes)"
check "authelia arrives: bypass untouched"    0 "$(grep -c '"authelia-forwardauth"' "$_ZZR/demo/bypass-tpl.yml")"
check "authelia arrives: explicit none kept"  0 "$(grep -c '"authelia-forwardauth"' "$_ZZR/demo2/routed-tpl.yml")"
# SELinux (a fake getenforce says Enforcing): the stack's own folders get :z, a template that carries
# ",z" already keeps it once (CrowdSec's "…:ro,z" became "…:ro,z:z" and the merge refused it), host paths never
mkdir -p "$WORK/.templates/selinux-tpl" "$WORK/Stacks/demo3"
printf '{"name":"selinux-tpl","title":"SELinux","category":"other","auth":"bypass","variables":[]}\n' > "$WORK/.templates/selinux-tpl/template.json"
printf 'services:\n  selinux-tpl:\n    image: alpine\n    container_name: SeTpl\n    volumes:\n      - ${APP_DATA_DIR:-./App-Data}/SeTpl/logs:/var/log/x:ro,z\n      - ./App-Data/SeTpl/data:/data\n      - ./App-Data/SeTpl/conf:/conf:ro\n      - /var/log:/var/log/host:ro\n      - /srv/media:/media\n' > "$WORK/.templates/selinux-tpl/docker-compose.yml"
printf 'services:\n  placeholder:\n    image: alpine\n' > "$WORK/Stacks/demo3/docker-compose.yml"
printf '#!/bin/bash\necho Enforcing\n' > "$WORK/fakebin/getenforce"; chmod +x "$WORK/fakebin/getenforce"
check "selinux: the template deploys"         200 "$(fake_request POST /templates/selinux-tpl/deploy '{"target_stack":"demo3","auto_start":false}' | status_of)"
check "selinux: a label already there, once"  1 "$(grep -c '/var/log/x:ro,z$' "$WORK/Stacks/demo3/docker-compose.yml")"
check "selinux: the stack's folders labelled" 2 "$(grep -cE 'SeTpl/data:/data:z$|SeTpl/conf:/conf:ro,z$' "$WORK/Stacks/demo3/docker-compose.yml")"
check "selinux: host paths left alone"        2 "$(grep -cE -- '- /var/log:/var/log/host:ro$|- /srv/media:/media$' "$WORK/Stacks/demo3/docker-compose.yml")"
rm -f "$WORK/fakebin/getenforce"
# the rebuild: a compose service with a port and a container gets its route; a placeholder that was never created does not
printf 'services:\n  routed-tpl:\n    image: alpine\n    container_name: Routed\n    ports:\n      - "8123:80"\n  later:\n    image: alpine\n    container_name: Later\n    ports:\n      - "8125:80"\n  ghost:\n    image: alpine\n    container_name: Never\n    ports:\n      - "8126:80"\n' > "$WORK/Stacks/demo/docker-compose.yml"
_RB=$(fake_request POST /traefik/routes/rebuild '{"stack":"demo"}')
check "rebuild answers"                      200 "$(printf '%s' "$_RB" | status_of)"
check "rebuild: one route written"           1 "$(printf '%s' "$_RB" | body_of | jq -r '.routes_written')"
check "rebuild: existing route left alone"   yes "$([[ -f "$_ZZR/demo/later.yml" && -f "$_ZZR/demo/routed-tpl.yml" ]] && echo yes || echo no)"
check "rebuild: never-created service skipped" no "$([[ -f "$_ZZR/demo/ghost.yml" ]] && echo yes || echo no)"
check "rebuild: new route behind Authelia"   1 "$(grep -c '"authelia-forwardauth"' "$_ZZR/demo/later.yml")"
check "rebuild: unknown stack"               404 "$(fake_request POST /traefik/routes/rebuild '{"stack":"nope-zz"}' | status_of)"
check "rebuild: viewer denied"               403 "$(viewer_request POST /traefik/routes/rebuild '{}' | status_of)"
# the fleet chain: a VM's routers get the local chain and Authelia, a bypass template's router does not
_FC=$(PATH="$WORK/fakebin:$PATH" _lib _routes_apply_local_chain '{"http":{"routers":{"m1-routed-tpl-dcs":{"rule":"Host(`a.smoke.test`)","service":"m1-routed-tpl-dcs"},"m1-bypass-tpl-dcs":{"rule":"Host(`b.smoke.test`)","service":"m1-bypass-tpl-dcs"}},"services":{}}}')
check "fleet chain: protected router"        'traefik-chain compress-gzip authelia-forwardauth' "$(printf '%s' "$_FC" | jq -r '.http.routers["m1-routed-tpl-dcs"].middlewares | join(" ")')"
check "fleet chain: bypass router open"      'traefik-chain compress-gzip' "$(printf '%s' "$_FC" | jq -r '.http.routers["m1-bypass-tpl-dcs"].middlewares | join(" ")')"
# a template deployed into a VM through the hub: Authelia is the hub's — the choice is kept here, the VM gets a plain deploy
_lib _fleet_update '.members += [{id: "zz-vm", name: "zz-vm", url: "http://127.0.0.1:9", username: "dcs-hub", role: "admin", source: "manual", added_by: "smoke", added_at: 0, vmid: null, node: null, stacks: []}]'
_MP=/fleet/members/zz-vm/api/templates/routed-tpl/deploy; _FAJ="$WORK/.data/fleet-auth.json"
_fa() { jq -r --arg k "$1" '.[$k] | tostring' "$_FAJ" 2>/dev/null; }
_fchain() { PATH="$WORK/fakebin:$PATH" _lib _routes_apply_local_chain "{\"http\":{\"routers\":{\"$1\":{\"rule\":\"Host(\`a.smoke.test\`)\",\"service\":\"x\"}},\"services\":{}}}" | jq -r --arg k "$1" '.http.routers[$k].middlewares | join(" ")'; }
fake_request POST "$_MP" '{"target_stack":"zz-vm","authelia_services":["routed-tpl"]}' >/dev/null
check "vm deploy: protection kept on the hub"     true "$(_fa zz-vm-routed-tpl-dcs)"
check "vm deploy: the route is behind Authelia"   'traefik-chain compress-gzip authelia-forwardauth' "$(_fchain zz-vm-routed-tpl-dcs)"
fake_request POST "$_MP" '{"target_stack":"zz-vm","authelia_services":[]}' >/dev/null
check "vm deploy: an explicit none is kept"       false "$(_fa zz-vm-routed-tpl-dcs)"
check "vm deploy: that route stays open"          'traefik-chain compress-gzip' "$(_fchain zz-vm-routed-tpl-dcs)"
fake_request POST "$_MP" '{"target_stack":"zz-vm"}' >/dev/null
check "vm deploy: no choice, back to the default" null "$(_fa zz-vm-routed-tpl-dcs)"
check "vm deploy: default is protected"          'traefik-chain compress-gzip authelia-forwardauth' "$(_fchain zz-vm-routed-tpl-dcs)"
PATH="$WORK/fakebin:$PATH" _lib _fleet_auth_set zz-vm bypass-tpl true
check "vm deploy: a bypass template asked for it" 'traefik-chain compress-gzip authelia-forwardauth' "$(_fchain zz-vm-bypass-tpl-dcs)"
PATH="$WORK/fakebin:$PATH" _lib _fleet_auth_set zz-vm bypass-tpl clear
check "vm deploy: …and back to open"              'traefik-chain compress-gzip' "$(_fchain zz-vm-bypass-tpl-dcs)"
check "vm deploy: on demand is the hub's"         409 "$(fake_request POST "$_MP" '{"target_stack":"zz-vm","on_demand_services":["routed-tpl"]}' | status_of)"
rm -f "$WORK/fakebin/.authelia"
check "vm deploy: no Authelia on the hub"         409 "$(fake_request POST "$_MP" '{"target_stack":"zz-vm","authelia_services":["routed-tpl"]}' | status_of)"
_lib _fleet_update '.members |= map(select(.id != "zz-vm"))'; rm -f "$_FAJ"
# the engine card: what this server reports (no update is started here — it would run apt on the machine)
_EN=$(fake_request GET /system/docker-engine)
check "engine: answers"                      200 "$(printf '%s' "$_EN" | status_of)"
check "engine: shape"                        true "$(printf '%s' "$_EN" | body_of | jq -r 'has("version") and has("source") and has("candidate") and has("upgradable") and has("sudo_ready") and has("last_update")')"
check "engine: status idle"                  idle "$(fake_request GET /system/docker-engine/status | body_of | jq -r '.status')"
check "engine: update viewer denied"         403 "$(viewer_request POST /system/docker-engine/update '{}' | status_of)"
check "engine: fleet update needs members"   409 "$(fake_request POST /fleet/docker-engine/update '{"members":"all"}' | status_of)"
# an engine update whose job is gone (the API was restarted under it) must not read "running" for good
_ES="$WORK/.api-auth/docker-engine-status.json"
printf '{"status":"running","started_at":"2026-09-29T10:00:00+00:00","by":"smoke","pid":999999}\n' > "$_ES"
check "engine: a job that is gone reads failed"    "failed -1" "$(fake_request GET /system/docker-engine/status | body_of | jq -r '"\(.status) \(.exit_code)"' 2>/dev/null)"
check "engine: …and says what happened"            yes "$(fake_request GET /system/docker-engine/status | body_of | jq -r '.output' 2>/dev/null | grep -q 'restarted while the update ran' && echo yes || echo no)"
printf '{"status":"running","started_at":"2026-09-29T10:00:00+00:00","by":"smoke","pid":%s}\n' "$$" > "$_ES"
check "engine: a job that runs stays running"      running "$(fake_request GET /system/docker-engine/status | body_of | jq -r '.status' 2>/dev/null)"
printf '{"status":"running","started_at":"2026-09-29T10:00:00+00:00","by":"smoke"}\n' > "$_ES"
check "engine: a job that has no pid yet is young" running "$(fake_request GET /system/docker-engine/status | body_of | jq -r '.status' 2>/dev/null)"
command rm -f "$_ES"
# …on Arch: pacman is asked through a private copy of its databases (and a config of its own), the real /var/lib/pacman is never touched
_AB="$WORK/fakebin-arch"; _AT="$WORK/tmp-arch"; _AF="$WORK/.data/docker-engine-candidate.arch.json"; _AL="$WORK/pacman-calls.log"
mkdir -p "$_AB" "$_AT"; command rm -f "$_AF" "$_AL"
printf '#!/bin/bash\nexit 1\n' > "$_AB/dpkg"; printf '#!/bin/bash\nexit 1\n' > "$_AB/rpm"
printf '#!/bin/bash\n[[ "$1" == -n ]] && shift\nexec "$@"\n' > "$_AB/sudo"
cat > "$_AB/pacman" <<'FAKEPACMAN'
#!/bin/bash
# a pacman that knows docker 1:29.9.0-1 once its database was synchronised into the --dbpath it was given
op=""; db=""
while [[ $# -gt 0 ]]; do case "$1" in --dbpath) db=$2; shift 2 ;; --config|--logfile) shift 2 ;; -Q|-Sy|-Si|-Qu) op=$1; shift ;; *) shift ;; esac; done
[[ -n "${FAKE_PACMAN_LOG:-}" ]] && echo "$op $db" >> "$FAKE_PACMAN_LOG"
case "$op" in
    -Q) exit 0 ;;
    -Sy) [[ -n "${FAKE_PACMAN_FAIL:-}" ]] && exit 1; mkdir -p "$db/sync"; : > "$db/sync/core.db"; exit 0 ;;
    -Si) [[ -f "$db/sync/core.db" ]] || { echo "error: package 'docker' was not found" >&2; exit 1; }; printf 'Name            : docker\nVersion         : 1:29.9.0-1\n'; exit 0 ;;
    -Qu) [[ -f "$db/sync/core.db" ]] && echo "docker 1:29.8.1-1 -> 1:29.9.0-1"; exit 0 ;;
esac
exit 1
FAKEPACMAN
chmod +x "$_AB"/*
check "engine (arch): the package source"          docker-arch "$(PATH="$_AB:$PATH" _lib _docker_engine_source)"
PATH="$_AB:$PATH" TMPDIR="$_AT" FAKE_PACMAN_LOG="$_AL" _lib _docker_engine_candidate_refresh "$_AF"
check "engine (arch): the newest version"          29.9.0 "$(jq -r '.candidate' "$_AF" 2>/dev/null)"
check "engine (arch): synced and asked its copy"   '1 1' "$(printf '%s %s' "$(grep -c '^-Sy /' "$_AL" 2>/dev/null)" "$(grep -c '^-Si /' "$_AL" 2>/dev/null)")"
check "engine (arch): pacman's own database left alone" 0 "$(grep -c ' /var/lib/pacman/*$' "$_AL" 2>/dev/null || true)"
check "engine (arch): the private copy is removed" 0 "$(find "$_AT" -mindepth 1 | wc -l)"
PATH="$_AB:$PATH" TMPDIR="$_AT" FAKE_PACMAN_FAIL=1 _lib _docker_engine_candidate_refresh "$_AF"
check "engine (arch): a refused sync says unknown" 'docker-arch ' "$(jq -r '"\(.source) \(.candidate)"' "$_AF" 2>/dev/null)"
check "engine (arch): …and still cleans up"        0 "$(find "$_AT" -mindepth 1 | wc -l)"
# …and the OS update check on Arch asks a private copy of the databases too ("pacman -Sy" alone leaves the system's own newer than what is installed)
_PB="$WORK/pacman-only-bin"; mkdir -p "$_PB"; ln -sf /usr/bin/* /bin/* "$_PB"/ 2>/dev/null || true
command rm -f "$_PB/apt-get" "$_PB/apt" "$_PB/dnf" "$_PB/yum" "$_PB/pacman" "$_PB/sudo" "$_PB/dpkg" "$_PB/rpm" "$_AL"
_OS=$(PATH="$_AB:$_PB" TMPDIR="$_AT" FAKE_PACMAN_LOG="$_AL" auth_request POST /system/os-update/check '{}' | body_of)
check "os update (arch): what an upgrade would change"   "1 pacman docker 1:29.9.0-1" "$(jq -r '"\(.count) \(.package_manager) \(.packages[0].package) \(.packages[0].version)"' <<< "$_OS" 2>/dev/null)"
check "os update (arch): pacman's own database left alone" 0 "$(grep -c ' /var/lib/pacman/*$' "$_AL" 2>/dev/null || true)"
check "os update (arch): the private copy is removed"    0 "$(find "$_AT" -mindepth 1 | wc -l)"
command rm -rf "$_PB"
command rm -rf "$_AB" "$_AT" "$_AF" "$_AL"
# _run_host (updates): the manager runs the command and its output comes from the journal; where it cannot start a unit, the command runs here
_HB="$WORK/hostrun-bin"; mkdir -p "$_HB"
printf '#!/bin/bash\n[[ "$1" == -n ]] && shift\nexec "$@"\n' > "$_HB/sudo"
printf '#!/bin/bash\necho "Failed to start transient service unit: no bus" >&2; exit 1\n' > "$_HB/systemd-run"
printf '#!/bin/bash\nexit 0\n' > "$_HB/journalctl"; chmod +x "$_HB"/*
check "host run: no unit could start, the command runs here"   direct-run "$(PATH="$_HB:$PATH" _lib _run_host '' '' echo direct-run)"
printf '#!/bin/bash\nexit 0\n' > "$_HB/systemd-run"
printf '#!/bin/bash\n[[ "$*" == *--sync* ]] && exit 0\necho "from the journal"\n' > "$_HB/journalctl"
check "host run: the unit's output is the journal's"           "from the journal" "$(PATH="$_HB:$PATH" _lib _run_host '' '' echo never-printed)"
printf '#!/bin/bash\nexit 3\n' > "$_HB/systemd-run"
check "host run: the unit's exit status is kept"               3 "$(PATH="$_HB:$PATH" _lib eval '_run_host "" "" true >/dev/null || echo $?')"
command rm -rf "$_HB"
# a machine without the hostname and crontab commands: Arch's minimal image has no hostname, and none of the DCS VM images has cron
_NB="$WORK/nocmd-bin"; mkdir -p "$_NB"; ln -sf /usr/bin/* /bin/* "$_NB"/ 2>/dev/null || true; command rm -f "$_NB/hostname" "$_NB/crontab"
command rm -f "$WORK/.data/cache/"*.http
check "no hostname command: the name is still known"   "$(uname -n)" "$(PATH="$_NB" auth_request GET /status | body_of | jq -r '.hostname' 2>/dev/null)"
check "no hostname command: the helper answers"        "$(uname -n)" "$(PATH="$_NB" _lib _hostname)"
check "no crontab command: an empty list, no error line" "0 " "$(PATH="$_NB" auth_request GET /system/crontab | body_of | jq -r '"\(.entries | length) \(.raw)"' 2>/dev/null)"
command rm -rf "$_NB"
# the fleet's proxy domain: what the hub hands over, and what a member does with it
check "fleet domain: from the proxy stack"   smoke.test "$(_lib _fleet_domain)"
check "domain: hostname accepted"            0 "$(_lib _domain_valid home.example.org; echo $?)"
check "domain: garbage refused"              1 "$(_lib _domain_valid 'bad domain'; echo $?)"
check "selinux relabel: harmless everywhere" 0 "$(_lib _selinux_relabel_code; echo $?)"
# a member may only attract requests for containers inside stacks the hub placed on it; two claimants → nobody
_FSNAP="$WORK/.data/fleet-overview.json"; _FFILE_BAK="$WORK/.data/fleet.json.smokebak"; [[ -f "$WORK/.data/fleet.json" ]] && cp "$WORK/.data/fleet.json" "$_FFILE_BAK"
printf '{"members":[{"id":"vm-a","name":"A","url":"http://127.0.0.1:1","stacks":["media"]},{"id":"vm-b","name":"B","url":"http://127.0.0.1:2","stacks":["photos"]}]}\n' > "$WORK/.data/fleet.json"
printf '{"members":[{"id":"vm-a","reachable":true,"containers":[{"name":"Plex","stack":"media"},{"name":"Traefik","stack":"core-infrastructure"},{"name":"Shared","stack":"media"}]},{"id":"vm-b","reachable":true,"containers":[{"name":"Immich","stack":"photos"},{"name":"Shared","stack":"photos"},{"name":"Stolen","stack":"media"}]}]}\n' > "$_FSNAP"
check "forward: container in a placed stack"  vm-a "$(_lib _fleet_member_for_container Plex)"
check "forward: claimed hub stack ignored"    "" "$(_lib _fleet_member_for_container Traefik)"
check "forward: stack placed elsewhere ignored" "" "$(_lib _fleet_member_for_container Stolen)"
check "forward: two claimants → nobody"       "" "$(_lib _fleet_member_for_container Shared)"
check "forward: bad name ignored"             "" "$(_lib _fleet_member_for_container '../x')"
rm -f "$_FSNAP"; if [[ -f "$_FFILE_BAK" ]]; then mv -f "$_FFILE_BAK" "$WORK/.data/fleet.json"; else rm -f "$WORK/.data/fleet.json"; fi
# themes: stored documents every dashboard can follow
_TH='{"schema":1,"name":"smoke-night","title":"Smoke Night","mode":"dark","palette":{"accent":"#34d399","accentSecondary":"#22d3ee","bg":"#020617","surface":"#0f172a","text":"#f1f5f9"},"css":"body{} @import url(evil.css); .x{background:url(https://evil/x.png)}"}'
_TR=$(auth_request POST /themes "$_TH")
check "theme: stored"                        200 "$(printf '%s' "$_TR" | status_of)"
check "theme: css cleaned and reported"      1 "$(printf '%s' "$_TR" | body_of | jq -r '.stripped | length')"
check "theme: file written"                  yes "$([[ -s "$WORK/.config/themes/smoke-night.json" ]] && echo yes || echo no)"
check "theme: @import gone from the file"    0 "$(grep -c '@import url' "$WORK/.config/themes/smoke-night.json")"
check "theme: listed without css"            'smoke-night true' "$(auth_request GET /themes | body_of | jq -r '.themes[0] | "\(.name) \(.has_css)"')"
check "theme: viewer may list"               200 "$(viewer_request GET /themes | status_of)"
check "theme: viewer may not store"          403 "$(viewer_request POST /themes "$_TH" | status_of)"
check "theme: bad name refused"              400 "$(auth_request POST /themes '{"name":"Bad Name","palette":{"accent":"#000000","bg":"#000000","surface":"#000000","text":"#ffffff"}}' | status_of)"
check "theme: bad colour refused"            400 "$(auth_request POST /themes '{"name":"bad-colour","palette":{"accent":"red","bg":"#000000","surface":"#000000","text":"#ffffff"}}' | status_of)"
check "theme: palette needs the basics"      400 "$(auth_request POST /themes '{"name":"thin","palette":{"accent":"#000000"}}' | status_of)"
check "theme: import needs https"            400 "$(auth_request POST /themes/import '{"url":"http://127.0.0.1/x.json"}' | status_of)"
check "theme: active must exist"             404 "$(auth_request PUT /themes/active '{"name":"nope-zz"}' | status_of)"
check "theme: set active"                    smoke-night "$(auth_request PUT /themes/active '{"name":"smoke-night"}' | body_of | jq -r '.active')"
check "theme: list says active"              smoke-night "$(auth_request GET /themes | body_of | jq -r '.active')"
check "theme: get the document"              '#34d399' "$(auth_request GET /themes/smoke-night | body_of | jq -r '.palette.accent')"
# a theme with both looks: palette_dark and palette_light travel with it; a bad one is refused; an older document still works
_TP='{"schema":1,"name":"smoke-pair","title":"Smoke Pair","mode":"dark","palette":{"accent":"#34d399","bg":"#020617","surface":"#0f172a","text":"#f1f5f9"},"palette_dark":{"accent":"#34d399","bg":"#020617","surface":"#0f172a","text":"#f1f5f9"},"palette_light":{"accent":"#047857","bg":"#f8fafc","surface":"#ffffff","text":"#0f172a"}}'
check "theme pair: stored"                   200 "$(auth_request POST /themes "$_TP" | status_of)"
check "theme pair: both looks kept"          "#f8fafc #020617" "$(auth_request GET /themes/smoke-pair | body_of | jq -r '"\(.palette_light.bg) \(.palette_dark.bg)"')"
check "theme pair: listed with both"         "true true" "$(auth_request GET /themes | body_of | jq -r '[.themes[] | select(.name == "smoke-pair")][0] | "\(has("palette_dark")) \(has("palette_light"))"')"
check "theme pair: a bad light colour refused" 400 "$(auth_request POST /themes '{"name":"bad-pair","palette":{"accent":"#000000","bg":"#000000","surface":"#000000","text":"#ffffff"},"palette_light":{"accent":"red","bg":"#ffffff","surface":"#ffffff","text":"#000000"}}' | status_of)"
check "theme pair: the light look needs the basics" 400 "$(auth_request POST /themes '{"name":"thin-pair","palette":{"accent":"#000000","bg":"#000000","surface":"#000000","text":"#ffffff"},"palette_light":{"accent":"#000000"}}' | status_of)"
check "theme pair: a document without them has none" false "$(auth_request GET /themes/smoke-night | body_of | jq -r 'has("palette_light")')"
auth_request DELETE /themes/smoke-pair >/dev/null
check "theme: delete"                        200 "$(auth_request DELETE /themes/smoke-night | status_of)"
check "theme: active cleared with it"        "" "$(auth_request GET /themes | body_of | jq -r '.active')"
check "theme: gone"                          404 "$(auth_request GET /themes/smoke-night | status_of)"
# homarr: the key and the sync need a Homarr here
check "homarr: status shape"                 true "$(auth_request GET /homarr/status | body_of | jq -r 'has("mode") and has("hint") and has("has_api_key")')"
check "homarr: key format checked"           400 "$(auth_request POST /homarr/key '{"key":"short"}' | status_of)"
check "homarr: key needs Homarr"             409 "$(auth_request POST /homarr/key '{"key":"abcdefghijklmnopqrstuvwxyz0123456789"}' | status_of)"
check "homarr: sync needs Homarr"            409 "$(auth_request POST /homarr/sync '{}' | status_of)"
check "homarr: viewer may not set a key"     403 "$(viewer_request POST /homarr/key '{"key":"abcdefghijklmnopqrstuvwxyz0123456789"}' | status_of)"
check "domain hand-off: no hub here"         409 "$(auth_request POST /fleet/hub/domain '{"domain":"x.example.org"}' | status_of)"
# Cloudflare + DDNS against the stand-in: a CNAME for a routed service, then the dynamic A records following the public address
_CFP=$(( 20000 + RANDOM % 20000 )); _CFS="$WORK/.data/cf-mock.json"
python3 "$ROOT/tests/mock-cloudflare.py" "$_CFP" smoke-cf-token "$_CFS" >/dev/null 2>&1 &
_CFPID=$!
for _i in $(seq 1 30); do curl -s -m 1 -o /dev/null "http://127.0.0.1:$_CFP/ip" && break; sleep 0.2; done
_cf() { CF_API_BASE="http://127.0.0.1:$_CFP/client/v4" CF_DNS_API_TOKEN=smoke-cf-token DDNS_IP_URLS="http://127.0.0.1:$_CFP/ip" "$@"; }
_cf _lib _cloudflare_add_dns app smoke.test smoke-cf-token >/dev/null
check "cloudflare: CNAME created"            1 "$(jq -r '[.records["zone-smoke.test"][]? | select(.type == "CNAME" and .name == "app.smoke.test")] | length' "$_CFS" 2>/dev/null)"
check "cloudflare: CNAME proxied to the apex" 'smoke.test true' "$(jq -r '[.records["zone-smoke.test"][]? | select(.name == "app.smoke.test")][0] | "\(.content) \(.proxied)"' "$_CFS" 2>/dev/null)"
_cf _lib _cloudflare_add_dns app smoke.test smoke-cf-token >/dev/null
check "cloudflare: not created twice"        1 "$(jq -r '[.records["zone-smoke.test"][]? | select(.name == "app.smoke.test")] | length' "$_CFS" 2>/dev/null)"
rm -f "$WORK/.api-auth/.cf-zone-cache" "$WORK/.data/ddns-current-ip"
_cf env DDNS_ENABLED=true DDNS_SUBDOMAINS='@,home,app' DDNS_ONCE=true DDNS_INTERVAL=1 TRAEFIK_DOMAIN=smoke.test bash -c "cd '$WORK' && source '$API' >/dev/null 2>&1; _ddns_update_loop" >/dev/null 2>&1
check "ddns: public address noted"           203.0.113.7 "$(cat "$WORK/.data/ddns-current-ip" 2>/dev/null)"
check "ddns: apex A record"                  203.0.113.7 "$(jq -r '[.records["zone-smoke.test"][]? | select(.type == "A" and .name == "smoke.test")][0].content' "$_CFS" 2>/dev/null)"
check "ddns: subdomain A record"             203.0.113.7 "$(jq -r '[.records["zone-smoke.test"][]? | select(.type == "A" and .name == "home.smoke.test")][0].content' "$_CFS" 2>/dev/null)"
check "ddns: routed CNAME left to routing"   0 "$(jq -r '[.records["zone-smoke.test"][]? | select(.type == "A" and .name == "app.smoke.test")] | length' "$_CFS" 2>/dev/null)"
check "ddns: log says updated"               1 "$(grep -c 'IP updated: none → 203.0.113.7' "$WORK/.api-auth/ddns.log" 2>/dev/null)"
curl -s -m 2 -X POST "http://127.0.0.1:$_CFP/ip?set=203.0.113.9" >/dev/null
_cf env DDNS_ENABLED=true DDNS_SUBDOMAINS='@,home' DDNS_ONCE=true DDNS_INTERVAL=1 TRAEFIK_DOMAIN=smoke.test bash -c "cd '$WORK' && source '$API' >/dev/null 2>&1; _ddns_update_loop" >/dev/null 2>&1
check "ddns: address change followed"        203.0.113.9 "$(jq -r '[.records["zone-smoke.test"][]? | select(.type == "A" and .name == "home.smoke.test")][0].content' "$_CFS" 2>/dev/null)"
check "ddns: one A record per name"          1 "$(jq -r '[.records["zone-smoke.test"][]? | select(.type == "A" and .name == "smoke.test")] | length' "$_CFS" 2>/dev/null)"
kill "$_CFPID" 2>/dev/null; wait "$_CFPID" 2>/dev/null || true

echo "Setup checks (what setup.sh looks at before it changes anything)"
_sc() { ( set +eu; source "$ROOT/.lib/setup-checks.sh"; "$@" ); }
check "setup: http:// becomes https://"      https://192.168.2.12:8006 "$(_sc _pve_clean_url 'http://192.168.2.12:8006/')"
check "setup: a bare address gets https"     https://192.168.2.12 "$(_sc _pve_clean_url '192.168.2.12')"
check "setup: the browser's #fragment goes"  https://pve.lan:8006 "$(_sc _pve_clean_url ' https://pve.lan:8006/#v1:0:18:4:::::::: ')"
check "setup: a pasted API path goes"        https://pve.lan:8006 "$(_sc _pve_clean_url 'HTTPS://pve.lan:8006/api2/json/version')"
check "setup: an IPv6 address stays whole"   'https://[fd00::5]:8006' "$(_sc _pve_clean_url 'https://[fd00::5]:8006/')"
check "setup: token ID user@realm!name"      0 "$(_sc _pve_tid_ok 'dcs@pve!dcs'; echo $?)"
check "setup: token ID of an e-mail user"    0 "$(_sc _pve_tid_ok 'jo@example.com@pve!dcs'; echo $?)"
check "setup: token ID without its name"     1 "$(_sc _pve_tid_ok 'dcs@pve'; echo $?)"
check "setup: token ID holding the secret"   1 "$(_sc _pve_tid_ok 'dcs@pve!dcs=0f8fad5b'; echo $?)"
check "setup: a token secret is a UUID"      0 "$(_sc _pve_secret_ok 0f8fad5b-d9cb-469f-a165-70867728950e; echo $?)"
check "setup: other text is not a secret"    1 "$(_sc _pve_secret_ok hunter2; echo $?)"
check "setup: missing tools are named"       "jq curl python3 openssl git socat" "$(PATH=/nonexistent _sc _missing_tools)"
_SCB="$WORK/setup-fakebin"; mkdir -p "$_SCB"
printf '#!/bin/bash\necho "permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock" >&2; exit 1\n' > "$_SCB/docker"; chmod +x "$_SCB/docker"
check "setup: Docker refusing the user"      denied "$(PATH="$_SCB:$PATH" _sc _docker_state)"
printf '#!/bin/bash\necho "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2; exit 1\n' > "$_SCB/docker"
check "setup: Docker not running"            stopped "$(PATH="$_SCB:$PATH" _sc _docker_state)"
printf '#!/bin/bash\nexit 0\n' > "$_SCB/docker"
check "setup: Docker answering"              running "$(PATH="$_SCB:$PATH" _sc _docker_state)"
# the secret prompt: a * per character, Backspace edits, a bracketed paste and an arrow key leave no marks, nothing echoed in clear
_SCSEC=$(python3 - "$ROOT/.lib/setup-checks.sh" <<'PY'
import os, pty, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.execvp('bash', ['bash', '-c', 'source "$0"; _read_secret "S: " v; printf "[%s]" "$v"', sys.argv[1]])
time.sleep(0.4)
for chunk in (b'ab\x7fc', b'\x1b[200~d-e\x1b[201~', b'\x1b[D', b'\r'):
    os.write(fd, chunk); time.sleep(0.15)
out = b''
while True:
    try: d = os.read(fd, 4096)
    except OSError: break
    if not d: break
    out += d
os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors='replace').replace('\r', ''))
PY
)
check "setup: secret read through edits"     '[acd-e]' "$(grep -o '\[[^]]*\]$' <<< "$_SCSEC")"
check "setup: secret shown as stars"         yes "$(grep -q 'S: \*\*' <<< "$_SCSEC" && echo yes || echo no)"
check "setup: secret never in clear"         0 "$(sed 's/\[[^]]*\]$//' <<< "$_SCSEC" | grep -c 'd-e')"
# the Proxmox link against a stand-in that answers like pveproxy on 8006: HTTPS with a self-signed
# certificate, plain HTTP on the same port answered with a 301 to https
_SCP=$(( 20000 + RANDOM % 20000 )); _SCS=0f8fad5b-d9cb-469f-a165-70867728950e
MOCK_PVE_TLS=1 python3 "$ROOT/tests/mock-proxmox.py" "$_SCP" 'dcs@pve!dcs' "$_SCS" >/dev/null 2>&1 & _SCPID=$!
MOCK_PVE_TLS=1 MOCK_PVE_PRIVS=none python3 "$ROOT/tests/mock-proxmox.py" "$((_SCP + 1))" 'dcs@pve!dcs' "$_SCS" >/dev/null 2>&1 & _SCPID2=$!
for _i in $(seq 1 50); do curl -sk -o /dev/null "https://127.0.0.1:$_SCP/" 2>/dev/null && curl -sk -o /dev/null "https://127.0.0.1:$((_SCP + 1))/" 2>/dev/null && break; sleep 0.2; done
_scfind() { ( set +eu; source "$ROOT/.lib/setup-checks.sh"; _pve_find "$@"; echo "$? $PVE_CODE ${PVE_BASE:-none}" ); }
check "setup: plain http gets its redirect"  "301" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$_SCP/api2/json/version")"
check "setup: http:// links over https"      "0 200 https://127.0.0.1:$_SCP" "$(_scfind "http://127.0.0.1:$_SCP/" 'dcs@pve!dcs' "$_SCS")"
check "setup: an address without a scheme"   "0 200 https://127.0.0.1:$_SCP" "$(_scfind "127.0.0.1:$_SCP" 'dcs@pve!dcs' "$_SCS")"
check "setup: a wrong secret is refused"     "0 401 https://127.0.0.1:$_SCP" "$(_scfind "https://127.0.0.1:$_SCP" 'dcs@pve!dcs' 11111111-2222-3333-4444-555555555555)"
check "setup: nothing listening"             "1 000 none" "$(_scfind "https://127.0.0.1:$((_SCP + 2))" 'dcs@pve!dcs' "$_SCS")"
check "setup: says why nothing answered"     yes "$( ( set +eu; source "$ROOT/.lib/setup-checks.sh"; _pve_find "127.0.0.1:$((_SCP + 2))" x y; [[ "$PVE_ERR" == *"$((_SCP + 2))"* ]] ) && echo yes || echo no)"
check "setup: self-signed certificate seen"  1 "$(_sc _pve_tls_verifies "https://127.0.0.1:$_SCP" && echo 0 || echo 1)"
check "setup: a full token lacks nothing"    "" "$(_sc _pve_missing_privs "https://127.0.0.1:$_SCP" 'dcs@pve!dcs' "$_SCS")"
check "setup: a bare token lacks the three"  "VM.Audit VM.PowerMgmt Sys.Audit" "$(_sc _pve_missing_privs "https://127.0.0.1:$((_SCP + 1))" 'dcs@pve!dcs' "$_SCS")"
kill "$_SCPID" "$_SCPID2" 2>/dev/null; wait "$_SCPID" "$_SCPID2" 2>/dev/null || true

echo "The hub's firewall (firewalld stand-ins)"
_FWB="$WORK/fw-bin"; _FWZ="$WORK/fw-zones"; mkdir -p "$_FWB" "$_FWZ"
cat > "$_FWB/systemctl" <<'FW'
#!/bin/bash
[[ "$*" == "is-active --quiet firewalld" ]] && { [[ "${FAKE_FW:-on}" == on ]]; exit $?; }
exit 1
FW
cat > "$_FWB/firewall-cmd" <<'FW'
#!/bin/bash
case "$*" in
  --get-zone-of-interface=*|--get-default-zone) echo "${FAKE_FW_ZONE:-FedoraServer}" ;;
  *--query-port=*) case "${FAKE_FW_Q:-deny}" in yes) echo yes ;; no) echo no; exit 1 ;; *) echo "Authorization failed." >&2; exit 11 ;; esac ;;
esac
FW
printf '#!/bin/bash\nexit 1\n' > "$_FWB/sudo"
chmod +x "$_FWB"/*
printf '<?xml version="1.0" encoding="utf-8"?>\n<zone>\n  <short>Public</short>\n  <service name="ssh"/>\n  <service name="dhcpv6-client"/>\n  <service name="cockpit"/>\n  <forward/>\n</zone>\n' > "$_FWZ/FedoraServer.xml"
printf '<?xml version="1.0" encoding="utf-8"?>\n<zone>\n  <service name="ssh"/>\n  <port protocol="tcp" port="1025-65535"/>\n</zone>\n' > "$_FWZ/FedoraWorkstation.xml"
# (through _lib: the API sourced from a script of another name, so it does not start its listener)
# shellcheck disable=SC2163  # "$@" holds NAME=value pairs to export
_fw() { ( export PATH="$_FWB:$PATH" FIREWALLD_ZONES_DIR="$_FWZ" DCS_API_EFFECTIVE_PORT=9876 "$@"; _lib _hub_firewall_json ) | jq -r '"\(.active) \(.open) \(.certain) \(.zone)"'; }
check "firewall: none running"           "false null false " "$(_fw FAKE_FW=off)"
check "firewall: firewalld says open"    "true true true FedoraServer" "$(_fw FAKE_FW_Q=yes)"
check "firewall: firewalld says closed"  "true false true FedoraServer" "$(_fw FAKE_FW_Q=no)"
check "firewall: a plain user reads the zone" "true false false FedoraServer" "$(_fw FAKE_FW_Q=deny)"
check "firewall: a zone that opens high ports" "true true false FedoraWorkstation" "$(_fw FAKE_FW_Q=deny FAKE_FW_ZONE=FedoraWorkstation)"
check "firewall: the fix names the zone" yes "$( ( export PATH="$_FWB:$PATH" FIREWALLD_ZONES_DIR="$_FWZ" DCS_API_EFFECTIVE_PORT=9876; _lib _hub_firewall_hint ) | grep -q -- '--zone=FedoraServer --add-port=9876/tcp' && echo yes || echo no)"

echo "Stack counts on a hub: a folder left behind by a stack that moved into a VM is not one of the hub's"
_stt() { API_RESPONSE_CACHE=false auth_request GET /status | body_of | jq -r '.stacks.total'; }
_ST0=$(_stt)
mkdir -p "$WORK/Stacks/zz-left" && printf 'services:\n  x:\n    image: alpine:3\n' > "$WORK/Stacks/zz-left/docker-compose.yml"
check "status: a plain folder counts"                "$((_ST0 + 1))" "$(_stt)"
_lib _fleet_update '.members += [{id: "zz-cnt", name: "zz-cnt", url: "http://127.0.0.1:9", username: "dcs-hub", role: "admin", source: "manual", added_by: "smoke", added_at: 0, vmid: null, node: null, stacks: []}]'
check "status: …a VM that runs other stacks changes nothing" "$((_ST0 + 1))" "$(_stt)"
_lib _fleet_update '(.members[] | select(.id == "zz-cnt") | .stacks) += ["zz-left"]'
check "status: …not once a VM runs that stack"       "$_ST0" "$(_stt)"
_lib _fleet_update '(.members[] | select(.id == "zz-cnt") | .stacks) -= ["zz-left"]'
check "status: …and again when no VM does"           "$((_ST0 + 1))" "$(_stt)"
_lib _fleet_update '.members |= map(select(.id != "zz-cnt"))'
rm -rf "$WORK/Stacks/zz-left"

echo "Setup wizard: the stacks the person removed"
SCFG="$WORK-scfg"; mkdir -p "$SCFG/.scripts" "$SCFG/.lib" "$SCFG/.config" "$SCFG/.data" "$SCFG/logs" "$SCFG/.api-auth" "$SCFG/.templates"
cp "$ROOT/.scripts/api-server.sh" "$SCFG/.scripts/"; cp "$ROOT/VERSION" "$SCFG/"; cp -r "$ROOT/.lib/." "$SCFG/.lib/"; cp -r "$ROOT/.config/." "$SCFG/.config/"
grep -vE '^(API_BIND|API_AUTH_ENABLED|API_INSECURE_NO_AUTH|API_TRUSTED_PROXIES|API_IP_WHITELIST|API_PORT)=' "$ROOT/.env.example" > "$SCFG/.env"; printf 'API_PORT=9876\nMETRICS_ENABLED=false\n' >> "$SCFG/.env"
for _n in zz-keep zz-drop zz-data; do mkdir -p "$SCFG/Stacks/$_n/App-Data"; printf 'services:\n  x:\n    image: alpine:3\n' > "$SCFG/Stacks/$_n/docker-compose.yml"; done
: > "$SCFG/Stacks/zz-data/App-Data/keep.txt"
mkdir -p "$SCFG/Stacks/zz-placeholder/App-Data"; printf 'services:\n  # nothing yet\n' > "$SCFG/Stacks/zz-placeholder/docker-compose.yml"
_SCB='{"username":"admin","password":"correct horse battery"}'
_SCTOK=$(printf 'POST /auth/setup HTTP/1.1\r\nContent-Length: %d\r\n\r\n%s' "${#_SCB}" "$_SCB" | env "${AUTH[@]}" "$SCFG/.scripts/api-server.sh" --handle-request 2>/dev/null | body_of | jq -r '.token // empty')
_scfg() { local b="$1"; printf 'POST /setup/configure HTTP/1.1\r\nAuthorization: Bearer %s\r\nContent-Length: %d\r\n\r\n%s' "$_SCTOK" "${#b}" "$b" | env "${AUTH[@]}" "$SCFG/.scripts/api-server.sh" --handle-request 2>/dev/null; }
_SCR=$(_scfg '{"env_vars":{"TZ":"UTC"},"stacks":["zz-keep"],"remove_stacks":["zz-drop","zz-data","zz-keep","../etc","Bad Name"]}')
check "wizard: configure answers"                    200 "$(printf '%s' "$_SCR" | status_of)"
check "wizard: a removed stack's folder goes"        no "$([[ -d "$SCFG/Stacks/zz-drop" ]] && echo yes || echo no)"
check "wizard: …and is reported"                     yes "$(printf '%s' "$_SCR" | body_of | jq -e '.stacks_removed | index("zz-drop") != null' >/dev/null 2>&1 && echo yes || echo no)"
check "wizard: a stack holding data is kept"         yes "$([[ -f "$SCFG/Stacks/zz-data/App-Data/keep.txt" ]] && echo yes || echo no)"
check "wizard: …and reported, once"                  1 "$(printf '%s' "$_SCR" | body_of | jq -r '[.stacks_warned[] | select(. == "zz-data")] | length' 2>/dev/null)"
check "wizard: a listed stack is never removed"      yes "$([[ -d "$SCFG/Stacks/zz-keep" ]] && echo yes || echo no)"
check "wizard: an empty placeholder is still tidied" no "$([[ -d "$SCFG/Stacks/zz-placeholder" ]] && echo yes || echo no)"
rm -rf "$SCFG"

echo "Factory reset (last: it removes the accounts)"
cp "$ROOT/.env.example" "$WORK/.env.example"   # what the reset copies back over .env
_envset FLEET_ROLE hub
check "factory reset: done"              200 "$(auth_request POST /auth/factory-reset '{"confirm":"FACTORY_RESET"}' | status_of)"
check "factory reset: .env from the example" yes "$(grep -q '^PROXMOX_URL=$' "$WORK/.env" && echo yes || echo no)"
check "factory reset: the hub stays a hub" hub "$(grep -m1 '^FLEET_ROLE=' "$WORK/.env" | cut -d= -f2)"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
