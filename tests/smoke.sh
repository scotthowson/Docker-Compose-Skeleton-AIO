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
check "envfile set: replace"             'FOO=a b' "$(grep '^FOO=' "$_ENVF")"
check "envfile set: append quoted"       'NEW="x#y"' "$(grep '^NEW=' "$_ENVF")"; rm -f "$_ENVF"
check "container env: unknown container" 404 "$(auth_request POST /containers/nope-zz/env '{"set":{"A":"1"}}' | status_of)"
check "container env: viewer denied"     403 "$(viewer_request POST /containers/nope-zz/env '{"set":{"A":"1"}}' | status_of)"

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
