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
trap '[[ -n "${RIP_MAIN:-}" ]] && kill "$RIP_MAIN" 2>/dev/null; [[ -n "${RIP_DDNS:-}" ]] && kill "$RIP_DDNS" 2>/dev/null; [[ -n "${RIP_CS:-}" ]] && kill "$RIP_CS" 2>/dev/null; [[ -n "${RIP_LANES:-}" ]] && kill $RIP_LANES 2>/dev/null; rm -rf "$WORK" "$WORK-cs"' EXIT

# Minimal isolated installation: scripts, config, one stack, an .env
mkdir -p "$WORK/.scripts" "$WORK/.lib" "$WORK/.config" "$WORK/Stacks/demo" "$WORK/.data" "$WORK/logs" "$WORK/.api-auth" "$WORK/.templates"
cp "$ROOT/.scripts/api-server.sh" "$ROOT/.scripts/api-dispatch.sh" "$WORK/.scripts/"   # the API and the front of its worker pool
cp "$ROOT/compose.sh" "$WORK/"
cp "$ROOT/VERSION" "$WORK/"   # the hub's bundle carries it; /ping and /fleet/versions report it
cp "$ROOT/.scripts/fleet-bootstrap.sh" "$WORK/.scripts/"   # the node installer GET /fleet/bootstrap serves with a join code
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

# SMOKE_ONLY=crowdsec runs the "CrowdSec page" section alone: the sections before it are skipped by this if, which closes right above it
if [[ "${SMOKE_ONLY:-}" != crowdsec ]]; then

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
# auth_request METHOD PATH [BODY] [extra env assignments...]  (the same shape as request, with the session token)
auth_request() { local m="$1" p="$2" b="${3:-}"; shift 3 2>/dev/null || shift $#; printf '%s %s HTTP/1.1\r\nAuthorization: Bearer %s\r\nContent-Length: %d\r\n\r\n%s' "$m" "$p" "$TOKEN" "${#b}" "$b" | env DOCKER_COMPOSE_CMD="${DOCKER_COMPOSE_CMD:-docker compose}" "${AUTH[@]}" "$@" "$API" --handle-request 2>/dev/null; }
check "token grants access"             200 "$(auth_request GET /version | status_of)"
check "wrong password rejected"         401 "$(request POST /auth/login '{"username":"admin","password":"wrong-password"}' "${AUTH[@]}" | status_of)"
LOGIN=$(request POST /auth/login '{"username":"admin","password":"correct horse battery"}' "${AUTH[@]}")
check "login works"                     200 "$(printf '%s' "$LOGIN" | status_of)"
check "login revokes the older session" 401 "$(auth_request GET /version | status_of)"
TOKEN=$(printf '%s' "$LOGIN" | body_of | jq -r '.token // empty' 2>/dev/null)
check "new session token works"         200 "$(auth_request GET /version | status_of)"
check "password hash is PBKDF2 (v2)"    2   "$(jq -r '.[0].hash_version' "$WORK/.api-auth/users.json" 2>/dev/null)"
# a password change of one's own: the current one must match, the new one takes over, every session of the account ends
check "password: wrong current refused"  401 "$(auth_request POST /auth/password '{"current_password":"nope-nope-nope","new_password":"brand new password"}' | status_of)"
check "password: too short refused"      400 "$(auth_request POST /auth/password '{"current_password":"correct horse battery","new_password":"short"}' | status_of)"
check "password: changed"                true "$(auth_request POST /auth/password '{"current_password":"correct horse battery","new_password":"brand new password"}' | body_of | jq -r '.success' 2>/dev/null)"
check "password: the session ended"      401 "$(auth_request GET /version | status_of)"
check "password: the old one is refused" 401 "$(request POST /auth/login '{"username":"admin","password":"correct horse battery"}' "${AUTH[@]}" | status_of)"
LOGIN=$(request POST /auth/login '{"username":"admin","password":"brand new password"}' "${AUTH[@]}")
check "password: the new one signs in"   200 "$(printf '%s' "$LOGIN" | status_of)"
TOKEN=$(printf '%s' "$LOGIN" | body_of | jq -r '.token // empty' 2>/dev/null)
auth_request POST /auth/password '{"current_password":"brand new password","new_password":"correct horse battery"}' >/dev/null   # back to the password the suite uses
LOGIN=$(request POST /auth/login '{"username":"admin","password":"correct horse battery"}' "${AUTH[@]}"); TOKEN=$(printf '%s' "$LOGIN" | body_of | jq -r '.token // empty' 2>/dev/null)
check "verify: says whether 2FA is on"   false "$(auth_request GET /auth/verify | body_of | jq -r '.totp_enabled' 2>/dev/null)"
check "sessions: remember the address"   yes "$(auth_request GET /auth/sessions | body_of | jq -e '.sessions[0] | has("ip")' >/dev/null 2>&1 && echo yes || echo no)"
check "config: boot-pull and colour rows read back" "false false 50" "$(auth_request GET /config | body_of | jq -r '"\(.update_on_boot) \(.force_color) \(.progress_bar_width)"' 2>/dev/null)"
check "config: FORCE_COLOR is a key the save takes"  200 "$(auth_request POST /config '{"FORCE_COLOR":"true","PROGRESS_BAR_WIDTH":"40"}' | status_of)"
check "config: …and reads back"          "true 40" "$(auth_request GET /config | body_of | jq -r '"\(.force_color) \(.progress_bar_width)"' 2>/dev/null)"
check "images: delete by reference checks the name" 400 "$(auth_request POST /images/delete '{"image":"not a ref!"}' | status_of)"
check "automation: a bad threshold is refused"      400 "$(auth_request POST /automations '{"name":"t","trigger_type":"condition","trigger_value":"high_cpu","action_type":"notification_send","action_target":"smoke","threshold":150}' | status_of)"
_AUT=$(auth_request POST /automations '{"name":"tuned","trigger_type":"condition","trigger_value":"high_cpu","action_type":"notification_send","action_target":"smoke","threshold":85,"cooldown":120}' | body_of)
check "automation: keeps its threshold and cooldown" "85 120" "$(auth_request GET /automations | body_of | jq -r '.automations[] | select(.name == "tuned") | "\(.threshold) \(.cooldown)"' 2>/dev/null)"
auth_request DELETE "/automations/$(jq -r '.id // .automation.id // empty' <<< "$_AUT" 2>/dev/null)" >/dev/null 2>&1
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

echo "Backups and snapshots"
# A throwaway install of its own: the backup engine reads, moves and restores whole stack folders. The reader is the
# server's own user (no sudo, no helper image) and nothing is paused, so no Docker is needed.
BKW="$WORK-bk"; rm -rf "$BKW"
mkdir -p "$BKW/.scripts" "$BKW/.lib" "$BKW/.config" "$BKW/Stacks/demo/App-Data/db" "$BKW/Stacks/demo/config" "$BKW/Stacks/other" "$BKW/.data/schedules" "$BKW/.data/cache" "$BKW/.api-auth" "$BKW/.secrets" "$BKW/.templates/mine" "$BKW/outside"
cp "$ROOT/.scripts/api-server.sh" "$BKW/.scripts/"; cp -r "$ROOT/.lib/." "$BKW/.lib/"; cp -r "$ROOT/.config/." "$BKW/.config/"; cp "$ROOT/VERSION" "$BKW/"
printf 'BACKUP_DEST_DIR=%s\nBACKUP_PAUSE=false\nBACKUP_RETENTION_COUNT=2\nMETRICS_ENABLED=false\n' "$BKW/backups" > "$BKW/.env"
printf 'services:\n  demo:\n    image: alpine:3\n' > "$BKW/Stacks/demo/docker-compose.yml"; echo 'A=1' > "$BKW/Stacks/demo/.env"
echo 'listen: 80' > "$BKW/Stacks/demo/config/app.yml"; chmod 640 "$BKW/Stacks/demo/config/app.yml"
echo 'row1' > "$BKW/Stacks/demo/App-Data/db/data.db"; ln -s db/data.db "$BKW/Stacks/demo/App-Data/current"
echo 'the VM' > "$BKW/outside/vm-file"; ln -s "$BKW/outside" "$BKW/Stacks/demo/VM-App-Data"
printf 'services:\n  o:\n    image: alpine:3\n' > "$BKW/Stacks/other/docker-compose.yml"
echo '{"members":[]}' > "$BKW/.data/fleet.json"; echo '[]' > "$BKW/.data/schedules/schedules.json"; echo junk > "$BKW/.data/cache/x"
echo '{"users":[]}' > "$BKW/.api-auth/users.json"; echo tok > "$BKW/.api-auth/tokens.json"; echo '{"x":1}' > "$BKW/.api-auth/invites.json"
echo enc > "$BKW/.secrets/A.enc"; echo key > "$BKW/.secrets/.master-key"; echo '{}' > "$BKW/.templates/mine/template.json"
# shellcheck disable=SC2034,SC2209  # FLEET_READER and AUTH_ROLE are read by the functions it calls
_bk() { local -a _c=("$@"); ( set --; source "$BKW/.scripts/api-server.sh" >/dev/null 2>&1; set +e; FLEET_READER=plain; AUTH_ROLE=admin; "${_c[@]}" ) 2>/dev/null; }
_bkb() { _backup_build "$1" "${2:-}"; printf '%s|%s' "${BK_ERROR:-ok}" "$BK_RESULT"; }
BKA="$BKW/backups/Docker-Compose-Backup-2026-01-01_000000.tar.gz"
BKR=$(_bk _bkb Docker-Compose-Backup-2026-01-01_000000.tar.gz)
check "backup: made, checked and complete"            "ok true true" "$(printf '%s' "${BKR%%|*}"; jq -r '" \(.verified) \(.complete)"' <<< "${BKR#*|}" 2>/dev/null)"
check "backup: its .sha256 matches"                   yes "$( (cd "$BKW/backups" && sha256sum -c --status ./*.sha256) && echo yes || echo no)"
check "backup: private"                               "600 600" "$(stat -c %a "$BKA" "$BKA.sha256" | tr '\n' ' ' | sed 's/ $//')"
check "backup: the manifest comes first"              ./.dcs-backup/manifest.json "$(tar -tzf "$BKA" | head -1)"
check "backup: a part per stack, the whole folder"    "demo other" "$(tar -xzOf "$BKA" ./.dcs-backup/manifest.json | jq -r '[.parts[] | select(.kind == "stack") | .name] | join(" ")')"
check "backup: App-Data and the config are in it"     yes "$(tar -xzOf "$BKA" ./.dcs-backup/stacks/demo.tar | tar -tf - | grep -qx './App-Data/db/data.db' && tar -xzOf "$BKA" ./.dcs-backup/stacks/demo.tar | tar -tf - | grep -qx './config/app.yml' && echo yes || echo no)"
check "backup: the link to a VM's App-Data is not followed, not kept" 0 "$(tar -xzOf "$BKA" ./.dcs-backup/stacks/demo.tar | tar -tf - | grep -c 'VM-App-Data\|vm-file')"
check "backup: an inner link is kept as a link"       db/data.db "$(tar -xzOf "$BKA" ./.dcs-backup/stacks/demo.tar | tar -tvf - | sed -n 's#.*\./App-Data/current -> ##p')"
check "backup: the install's state is in it"          "./.env ./.data/fleet.json ./.data/schedules/schedules.json ./.secrets/A.enc ./.api-auth/users.json" \
    "$(for f in ./.env ./.data/fleet.json ./.data/schedules/schedules.json ./.secrets/A.enc ./.api-auth/users.json; do tar -tzf "$BKA" | grep -qx "$f" && printf '%s ' "$f"; done | sed 's/ $//')"
check "backup: never the key, sessions, invites or caches" 0 "$(tar -tzf "$BKA" | grep -cE '\.master-key|tokens\.json|invites\.json|\.data/cache')"
check "backup: no staging left, nothing in /tmp"      0 "$(find "$BKW/backups" -mindepth 1 \( -name '*staging*' -o -name '*partial*' \) | wc -l)"
check "backup: listed as checked, full"               "true full true" "$(_bk handle_backup_list | body_of | jq -r '.backups[0] | "\(.verified) \(.kind) \(.complete)"')"
check "backup: verify says whole"                     "true 2" "$(_bk handle_backup_verify '{"filename":"Docker-Compose-Backup-2026-01-01_000000.tar.gz"}' | body_of | jq -r '"\(.ok) \(.format)"')"
# a file the reader cannot read: the backup says so (it used to be left out without a word)
if [[ "$(id -u)" != 0 ]]; then
    echo 'secret' > "$BKW/Stacks/other/locked.db"; chmod 000 "$BKW/Stacks/other/locked.db"
    BKR=$(_bk _bkb Docker-Compose-Backup-2026-01-01_000001.tar.gz)
    check "backup: an unreadable file makes it incomplete, named" "false yes" "$(jq -r '.complete' <<< "${BKR#*|}") $(jq -r '.warnings | join(" ")' <<< "${BKR#*|}" | grep -q 'locked.db' && echo yes || echo no)"
    rm -f "$BKW/Stacks/other/locked.db" "$BKW"/backups/*000001*
fi
BKR=$(_bk _bkb Docker-Compose-Backup-2026-01-01_000002-other.tar.gz other)
check "backup: one stack holds that stack alone"      "stack other" "$(tar -xzOf "$BKW/backups/Docker-Compose-Backup-2026-01-01_000002-other.tar.gz" ./.dcs-backup/manifest.json | jq -r '"\(.kind) \([.parts[].name] | join(","))"')"
check "backup: …and no install state"                 0 "$(tar -tzf "$BKW/backups/Docker-Compose-Backup-2026-01-01_000002-other.tar.gz" | grep -c '^\./\.env$')"

# restore: changed, lost and added files go back to the backup's state; the folder as it was is kept; the root is not consulted
echo 'row2' >> "$BKW/Stacks/demo/App-Data/db/data.db"; echo 'stray' > "$BKW/Stacks/demo/App-Data/db/data.db-wal"
echo 'B=2' > "$BKW/Stacks/demo/.env"; rm -f "$BKW/Stacks/demo/config/app.yml"; echo '{"users":["x"]}' > "$BKW/.api-auth/users.json"
_bkr() { _backup_restore_run "$1" "${2:-}"; printf '%s|%s' "${BR_ERROR:-ok}" "$BR_RESULT"; }
BKR=$(_bk _bkr "$BKA")
check "restore: done"                                 "ok demo,other true" "$(printf '%s' "${BKR%%|*}") $(jq -r '"\(.stacks | join(",")) \(.install)"' <<< "${BKR#*|}")"
check "restore: the data as it was"                   row1 "$(tr -d '\n' < "$BKW/Stacks/demo/App-Data/db/data.db")"
check "restore: a database's -wal written later is gone" no "$([[ -e "$BKW/Stacks/demo/App-Data/db/data.db-wal" ]] && echo yes || echo no)"
check "restore: .env, config and accounts as they were" 'A=1 listen: 80 {"users":[]}' "$(cat "$BKW/Stacks/demo/.env") $(cat "$BKW/Stacks/demo/config/app.yml") $(cat "$BKW/.api-auth/users.json")"
check "restore: the link to the VM's App-Data is back" "$BKW/outside" "$(readlink "$BKW/Stacks/demo/VM-App-Data")"
check "restore: sessions and the key stay"            "tok key" "$(cat "$BKW/.api-auth/tokens.json") $(cat "$BKW/.secrets/.master-key")"
check "restore: the folder before is kept"            "row1 row2" "$(cat "$BKW/.data/pre-restore/"*/Stacks/demo/App-Data/db/data.db | tr '\n' ' ' | sed 's/ $//')"
check "restore: a stack not in the backup is refused" "nope is not in this backup" "$(_bk _bkr "$BKA" nope | cut -d'|' -f1)"
check "restore: one stack"                            "ok other false" "$(_bk _bkr "$BKA" other | { IFS='|' read -r e r; printf '%s %s' "$e" "$(jq -r '"\(.stacks | join(",")) \(.install)"' <<< "$r")"; })"

# the checks before anything is unpacked
_bkl() { _backup_listing_check "$(printf -- "$1")"; echo "rc=$?"; }
check "listing: a file under a link is refused"       "rc=1" "$(_bk _bkl 'lrwxrwxrwx u/g 0 2026-01-01 00:00 ./a -> /etc\n-rw-r--r-- u/g 3 2026-01-01 00:00 ./a/cron.d/x\n' | tail -1)"
check "listing: .. is refused"                        "rc=1" "$(_bk _bkl '-rw-r--r-- u/g 3 2026-01-01 00:00 ./x/../../evil\n' | tail -1)"
check "listing: a hard link out is refused"           "rc=1" "$(_bk _bkl 'hrw-r--r-- u/g 0 2026-01-01 00:00 ./h link to ../../etc/shadow\n' | tail -1)"
check "listing: links out are left out, not refused"  "rc=0 skip: ./x/VM-App-Data skip: ./x/up" "$(_bk _bkl 'lrwxrwxrwx u/g 0 2026-01-01 00:00 ./x/VM-App-Data -> /home/dcs/v\nlrwxrwxrwx u/g 0 2026-01-01 00:00 ./x/in -> ../y\nlrwxrwxrwx u/g 0 2026-01-01 00:00 ./x/up -> ../../y\n' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
# a damaged archive is caught before a restore
cp "$BKA" "$BKW/backups/Docker-Compose-Backup-2026-01-01_000003.tar.gz"; cp "$BKA.sha256" "$BKW/backups/Docker-Compose-Backup-2026-01-01_000003.tar.gz.sha256"
printf 'XXXX' | dd of="$BKW/backups/Docker-Compose-Backup-2026-01-01_000003.tar.gz" bs=1 seek=2000 conv=notrunc 2>/dev/null
check "verify: a damaged archive is not whole"        false "$(_bk handle_backup_verify '{"filename":"Docker-Compose-Backup-2026-01-01_000003.tar.gz"}' | body_of | jq -r '.ok')"
check "restore: a damaged archive is refused"         400 "$(_bk handle_backup_restore '{"filename":"Docker-Compose-Backup-2026-01-01_000003.tar.gz","confirm":"RESTORE"}' | status_of)"
# retention: BACKUP_RETENTION_COUNT of each kind (2 here), the stacks' own never push the full ones out
mkdir -p "$BKW/r"; for _i in 1 2 3; do for _k in "" "-demo"; do _f="$BKW/r/Docker-Compose-Backup-2026-02-0${_i}_000000$_k.tar.gz"; : > "$_f"; : > "$_f.sha256"; touch -d "2026-02-0$_i" "$_f"; done; done
( set --; source "$BKW/.scripts/api-server.sh" >/dev/null 2>&1; BACKUP_DEST_DIR="$BKW/r" _backup_retention ) 2>/dev/null
check "retention: two of each kind, sidecars with them" "02-demo 02 03-demo 03 / 4" "$(cd "$BKW/r" && LC_ALL=C; printf '%s\n' *.tar.gz | sed -E 's/Docker-Compose-Backup-2026-02-([0-9]+)_000000(-demo)?\.tar\.gz/\1\2/' | tr '\n' ' ')/ $(compgen -G "$BKW/r/*.sha256" | wc -l)"

# snapshots: a stack's other configuration files travel, App-Data never; a restore works (GNU tar refused the
# --no-absolute-names it was called with) and keeps the state before as a snapshot of its own
_bks() { _snapshot_take "$1"; printf '%s|%s' "${SNAP_ERROR:-ok}" "$SNAP_FILE"; }
echo '{"old": true}' > "$BKW/.config/schema.json"     # the snapshot holds an older shipped file; then the code is updated
BKS=$(_bk _bks smoke)
cp "$ROOT/.config/schema.json" "$BKW/.config/schema.json"
BKSF="${BKS#*|}"
check "snapshot: made, private"                       "ok 600" "${BKS%%|*} $(stat -c %a "$BKW/.snapshots/$BKSF" 2>/dev/null)"
check "snapshot: a stack's config file is in it"      yes "$(tar -tzf "$BKW/.snapshots/$BKSF" | grep -qx './stacks/demo/config/app.yml' && echo yes || echo no)"
check "snapshot: no App-Data, no link"                0 "$(tar -tzvf "$BKW/.snapshots/$BKSF" | grep -c 'App-Data\|^l')"
check "snapshot: the schedules are in it"             yes "$(tar -tzf "$BKW/.snapshots/$BKSF" | grep -qx './data/schedules.json' && echo yes || echo no)"
echo 'listen: 8080' > "$BKW/Stacks/demo/config/app.yml"; sleep 1
check "snapshot: restore works"                       200 "$(_bk handle_snapshot_restore "$BKSF" '{"confirm":"RESTORE"}' | status_of)"
check "snapshot: …the file is back"                   'listen: 80' "$(cat "$BKW/Stacks/demo/config/app.yml")"
check "snapshot: …with its mode, not the umask's"     640 "$(stat -c %a "$BKW/Stacks/demo/config/app.yml")"
check "snapshot: …the state before is a snapshot"     2 "$(ls "$BKW/.snapshots"/dcs-snapshot-*.tar.gz | wc -l)"
check "snapshot: …the shipped settings are the code's" "$(md5sum < "$ROOT/.config/schema.json")" "$(md5sum < "$BKW/.config/schema.json")"
rm -rf "$BKW"

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
# the dashboard image is the one the core stack's compose file names: :latest for a release, a pinned tag for a release candidate
UIC="$WORK/uic"; mkdir -p "$UIC/core" "$UIC/other"
printf 'services:\n  dcs-ui:\n    container_name: DCS-UI\n    image: ghcr.io/scotthowson/docker-compose-skeleton-ui:4.0.0-rc.1\n' > "$UIC/core/docker-compose.yml"
printf 'services:\n  x:\n    container_name: Other\n    image: nginx:1\n' > "$UIC/other/docker-compose.yml"
check "dashboard image: a pinned tag is followed"     "ghcr.io/scotthowson/docker-compose-skeleton-ui:4.0.0-rc.1" "$(COMPOSE_DIR=$UIC _lib _dcs_ui_image)"
check "dashboard image: none named, then latest"       "ghcr.io/scotthowson/docker-compose-skeleton-ui:latest" "$(COMPOSE_DIR=$UIC/other _lib _dcs_ui_image)"
sed -i 's#docker-compose-skeleton-ui:4.0.0-rc.1#docker-compose-skeleton-ui:${TAG:-latest}#' "$UIC/core/docker-compose.yml"
check "dashboard image: a variable is not followed"   "ghcr.io/scotthowson/docker-compose-skeleton-ui:latest" "$(COMPOSE_DIR=$UIC _lib _dcs_ui_image)"
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
# The "nothing is deployed" checks run against a Docker that answers and has no containers, so a machine that has a CrowdSec container
# (running, stopped or restarting) cannot change their result.
mkdir -p "$WORK/fakebin-nodocker"
printf '#!/bin/bash\ncase "$1" in\n    inspect) echo "Error: No such object: $2" >&2; exit 1 ;;\n    *) exit 0 ;;\nesac\n' > "$WORK/fakebin-nodocker/docker"
chmod +x "$WORK/fakebin-nodocker/docker"
no_docker_containers() { PATH="$WORK/fakebin-nodocker:$PATH" "$@"; }
check "crowdsec status without container" false "$(no_docker_containers auth_request GET /crowdsec/status | body_of | jq '.installed' 2>/dev/null)"
check "crowdsec unban validates ip"     400 "$(auth_request DELETE '/crowdsec/decisions/not-an-ip' | status_of)"
check "crowdsec trust validates ip"     400 "$(auth_request POST /crowdsec/trust '{"ip":"999.1.1.1"}' | status_of)"
check "viewer may unban itself"         404 "$(no_docker_containers viewer_request POST /crowdsec/unban-me | status_of)"
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
check "health score counts sleeping apart"      true "$(auth_request GET /health/score | body_of | jq -r '.factors.stacks | has("sleeping")' 2>/dev/null)"
check "stacks say whether they sleep"          true "$(auth_request GET /stacks | body_of | jq -r '.stacks[0] | has("sleeping")' 2>/dev/null)"
check "stacks count their sleeping containers"  true "$(auth_request GET /stacks | body_of | jq -r '.stacks[0] | (.sleeping_containers | type == "number") and (.hub_only | type == "boolean")' 2>/dev/null)"
check "stack detail: every container, on demand or not" true "$(auth_request GET /stacks/demo | body_of | jq -r '(.sleeping_containers | type == "number") and ((.containers // []) | all(has("on_demand") and has("sleeping")))' 2>/dev/null)"
# a VM's route to a container that starts on demand: the hub keeps the descriptor only when it is well formed and the
# VM has a Sablier it can reach (its port)
_ODF='{"http":{"routers":{"app-dcs":{"rule":"Host(`app.example.net`)","service":"app-dcs"}},"services":{"app-dcs":{"loadBalancer":{"servers":[{"url":"http://10.9.9.9:8080"}]}}}},"dcs_on_demand":{"app-dcs":{"names":["App"],"session":"5m","theme":"ghost","display_name":"App \"x<b>","show_details":false}},"dcs_sablier_port":10000}'
check "vm on demand: kept, cleaned"         '{"names":["App"],"port":10000,"session":"5m","theme":"ghost","display_name":"App xb","show_details":false}' "$(_lib _fleet_feed_sanitize m1 10.9.9.9 '["10.9.9.9"]' '[]' <<< "$_ODF" | jq -c '.routes[0].od')"
check "vm on demand: no Sablier port, none" null "$(_lib _fleet_feed_sanitize m1 10.9.9.9 '["10.9.9.9"]' '[]' <<< "$(jq -c 'del(.dcs_sablier_port)' <<< "$_ODF")" | jq -c '.routes[0].od')"
check "vm on demand: a hostile name, none"  null "$(_lib _fleet_feed_sanitize m1 10.9.9.9 '["10.9.9.9"]' '[]' <<< "$(jq -c '.dcs_on_demand["app-dcs"].names = ["a;rm -rf /"]' <<< "$_ODF")" | jq -c '.routes[0].od')"
check "vm on demand: a bad session, default" 30m "$(_lib _fleet_feed_sanitize m1 10.9.9.9 '["10.9.9.9"]' '[]' <<< "$(jq -c '.dcs_on_demand["app-dcs"].session = "forever"' <<< "$_ODF")" | jq -r '.routes[0].od.session')"
check "vm on demand: the route still goes"  app.example.net "$(_lib _fleet_feed_sanitize m1 10.9.9.9 '["10.9.9.9"]' '[]' <<< "$(jq -c 'del(.dcs_sablier_port)' <<< "$_ODF")" | jq -r '.routes[0].host')"
check "vm sablier: none on a server that is no VM" 1 "$(_lib _member_sablier_ensure; echo $?)"
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
check "sablier block: its names (scalar)"   IT-Tools "$(_lib _sablier_block_names "$_SBF" ittools-sablier)"
check "sablier block: its names (list)"     "Ollama,Plex" "$(_lib _sablier_block_names "$_SBF" multi-sablier)"
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
# A port for a stand-in that starts a moment later: a random one in the range the tests use, but one nobody listens on (a busy machine
# has dozens of labs and dev servers in that range, and a stand-in that could not bind made a check fail one run in a few hundred).
# The range ends below the kernel's ephemeral ports (32768 and up on Linux): up there a port can be the local end of somebody's outgoing
# connection, which no connect probe sees and which still refuses a listener ("bind: Address already in use" — a second smoke run on
# the same machine, with its thousands of loopback requests, made the NUT stand-in fail that way).
_rport() { local p i; for i in $(seq 1 100); do p=$(( 20000 + RANDOM % 12768 )); ( exec 3<>"/dev/tcp/127.0.0.1/$p" ) 2>/dev/null || { echo "$p"; return; }; done; echo "$p"; }
# three neighbouring ports nobody listens on (two stand-ins take the first two; the third stays empty on purpose)
_rport3() { local p i; for i in $(seq 1 100); do p=$(( 20000 + RANDOM % 12760 )); ( exec 3<>"/dev/tcp/127.0.0.1/$p" ) 2>/dev/null || ( exec 3<>"/dev/tcp/127.0.0.1/$((p + 1))" ) 2>/dev/null || ( exec 3<>"/dev/tcp/127.0.0.1/$((p + 2))" ) 2>/dev/null || { echo "$p"; return; }; done; echo "$p"; }
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
    command cp "$API" "$ROOT/.scripts/api-dispatch.sh" "$d/.scripts/"; command cp "$ROOT/compose.sh" "$ROOT/VERSION" "$d/"
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
    # ended = gone, or a zombie nobody reaped (a job container's first process is not an init; kill -0 still answers for a zombie)
    check "ncat restart: the old DDNS loop ended" no "$(kill -0 "$RIP_DDNS_OLD" 2>/dev/null && [[ "$(awk '{print $3}' "/proc/$RIP_DDNS_OLD/stat" 2>/dev/null)" != Z ]] && echo yes || echo no)"
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
# the candidates are left in two lists (PRUNE_RM, PRUNE_KEPT), read by the prune that called for them
check "prune spares on-demand containers" 'zz-stopped zz-other | IT-Tools' "$(PATH="$WORK/fakebin:$PATH" _lib eval '_prune_stopped_candidates; echo "${PRUNE_RM[*]} | ${PRUNE_KEPT[*]}"')"
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
    NUTP=$(_rport)
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
# CyberPower's pwrstat (PowerPanel): the output of a CP1500PFCLCDa on mains, then in a blackout
cat > "$WORK/fakebin/pwrstat" <<'PWEOF'
#!/bin/bash
case "${PW_MODE:-mains}" in
  denied) echo "bash: pwrstat: Permission denied" >&2; exit 126 ;;
  nodaemon) echo "The daemon service is not available." >&2; exit 1 ;;
esac
s="Normal"; by="Utility Power"; uv="122 V"; cap="80 %"; rt="153 min."; ld="0 Watt(0 %)"; ev="None"
[[ "${PW_MODE:-mains}" == blackout ]] && { s="Power Failure"; by="Battery Power"; uv="0 V"; cap="63 %"; rt="97 min."; ld="180 Watt(18 %)"; ev="Blackout at 2026/10/02 22:01:11"; }
[[ "${PW_MODE:-mains}" == dying ]] && { s="Power Failure"; by="Battery Power"; uv="0 V"; cap="9 %"; rt="4 min."; ld="180 Watt(18 %)"; ev="Blackout at 2026/10/02 22:01:11"; }
printf '\nThe UPS information shows as following:\n\n\tProperties:\n\t\tModel Name................... CP1500PFCLCDa\n\t\tFirmware Number.............. CR01802H1711\n\t\tRating Voltage............... 120 V\n\t\tRating Power................. 1000 Watt(1500 VA)\n\n\tCurrent UPS status:\n\t\tState........................ %s\n\t\tPower Supply by.............. %s\n\t\tUtility Voltage.............. %s\n\t\tOutput Voltage............... 122 V\n\t\tBattery Capacity............. %s\n\t\tRemaining Runtime............ %s\n\t\tLoad......................... %s\n\t\tLine Interaction............. None\n\t\tTest Result.................. Unknown\n\t\tLast Power Event............. %s\n' "$s" "$by" "$uv" "$cap" "$rt" "$ld" "$ev"
PWEOF
chmod +x "$WORK/fakebin/pwrstat"
_pws() { PW_MODE="$1" UPS_SOURCE=pwrstat UPS_PWRSTAT_BIN="$WORK/fakebin/pwrstat" _lib _power_sample; }
PM=$(_pws mains)
check "power: pwrstat on mains"         'pwrstat Normal false 80 9180 0 122' "$(jq -r '"\(.source) \(.status) \(.on_battery) \(.charge) \(.runtime_seconds) \(.load) \(.input_voltage)"' <<< "$PM")"
check "power: pwrstat model and watts"  'CP1500PFCLCDa 0 1000 122' "$(jq -r '"\(.model) \(.load_watts) \(.rated_watts) \(.output_voltage)"' <<< "$PM")"
check "power: pwrstat no event on mains" null "$(jq -r '.last_power_event' <<< "$PM")"
PB=$(_pws blackout)
check "power: pwrstat in a blackout"    'true false 63 5820 18 180' "$(jq -r '"\(.on_battery) \(.low_battery) \(.charge) \(.runtime_seconds) \(.load) \(.load_watts)"' <<< "$PB")"
check "power: pwrstat names the event"  'Blackout at 2026/10/02 22:01:11' "$(jq -r '.last_power_event' <<< "$PB")"
check "power: pwrstat low is the stop threshold" 'true' "$(jq -r '.low_battery' <<< "$(_pws dying)")"
# a sudo that wants a password (the runner's own may be passwordless, or the job may run as root): refused, the server says what to add
mkdir -p "$WORK/sudo-asks"; printf '#!/bin/bash\necho "sudo: a password is required" >&2\nexit 1\n' > "$WORK/sudo-asks/sudo"; chmod +x "$WORK/sudo-asks/sudo"
if [[ "$(id -u)" -eq 0 ]]; then
    check "power: pwrstat refused (as root there is no sudo to ask)" yes "$(jq -r '.error' <<< "$(_pws denied)" | grep -q 'ermission denied' && echo yes || echo no)"
else
    check "power: pwrstat refused says how to allow it" yes "$(PATH="$WORK/sudo-asks:$PATH" _pws denied | jq -r '.error' | grep -q 'NOPASSWD' && echo yes || echo no)"
fi
check "power: pwrstat without its daemon, as it says" yes "$(jq -r '.error' <<< "$(_pws nodaemon)" | grep -q 'daemon service is not available' && echo yes || echo no)"
check "power: pwrstat not installed"    yes "$(UPS_SOURCE=pwrstat UPS_PWRSTAT_BIN=/nonexistent PATH=/usr/bin:/bin _lib _power_sample | jq -r '.error' | grep -q 'not installed' && echo yes || echo no)"
# the dashboard feed carries the UPS the watch loop read last, and nothing when it is not watched
printf '%s' "$PB" > "$WORK/.data/power.json"
check "power: the feed has the UPS"     '63 97 180 true' "$(UPS_ENABLED=true _lib eval 'POWER_STATE_FILE="'"$WORK"'/.data/power.json"; handle_feed_summary' | sed -n '/^{/p' | jq -r '.system.ups | "\(.percent) \(.runtime_min) \(.load_watts) \(.on_battery)"' 2>/dev/null)"
rm -f "$WORK/.data/power.json"
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

echo "Traefik template: the add-ons (a plugin declared only while its switch is on, DCS's middlewares, Sablier deployed with Traefik)"
# the shipped template deployed for real (the fake docker stands in for the daemon) into a stack of its own, in the App-Data layout
# this install has by now (per stack, or the one folder the API falls back to once an earlier section rewrote .env); no Sablier
# container anywhere. A Traefik folder that is there already is set aside and put back, and the stack and the two templates go at
# the end: the sections after this one count stacks and look for the proxy's routes
cp -r "$ROOT/.templates/traefik" "$ROOT/.templates/sablier" "$WORK/.templates/"
mkdir -p "$WORK/Stacks/zz-tr"; printf 'services:\n  placeholder:\n    image: alpine\n' > "$WORK/Stacks/zz-tr/docker-compose.yml"
touch "$WORK/fakebin/.nosablier"
tr_request() { PATH="$WORK/fakebin:$PATH" auth_request "$@"; }
_TRAD=$(grep -m1 '^APP_DATA_DIR=' "$WORK/.env" | cut -d= -f2- | tr -d '"' | tr -d "'")
case "$_TRAD" in "") _TRA="$WORK/App-Data/Traefik" ;; ./*) _TRA="$WORK/Stacks/zz-tr/${_TRAD#./}/Traefik" ;; *) _TRA="$_TRAD/Traefik" ;; esac
rm -rf "$_TRA.keep"; [[ -e "$_TRA" ]] && mv "$_TRA" "$_TRA.keep"
_TRS="$_TRA/traefik.yml"; _TRC="$_TRA/custom_routes/zz-tr/traefik.yml"; _TRE="$WORK/Stacks/zz-tr/.env"; _TRX="$WORK/Stacks/zz-tr/docker-compose.yml"
tr_chain()   { awk '/^    traefik-chain:/ { on=1; next } on && /^          - / { gsub(/"/, "", $2); printf "%s%s", (n++ ? " " : ""), $2; next } on && /^    [a-z]/ { exit } END { print "" }' "$_TRC"; }
tr_plugins() { awk '/^  plugins:/ { on=1; next } on && /^    [a-z-]+:[ \t]*$/ { sub(/^ +/, ""); sub(/:.*/, ""); printf "%s%s", (n++ ? " " : ""), $0; next } on && /^[a-z]/ { exit } END { print "" }' "$_TRS"; }
tr_deploy()  { tr_request POST /templates/traefik/deploy "{\"target_stack\":\"zz-tr\",\"auto_start\":false,\"replace_services\":true,\"variables\":{\"TRAEFIK_DOMAIN\":\"smoke.test\",\"TRAEFIK_ACME_EMAIL\":\"admin@smoke.test\"$1}}"; }
# -- the switches off (the template's defaults): nothing but the bouncer is declared, no add-on middleware, the chain as shipped
_TD=$(tr_deploy '')
check "add-ons off: the template deploys"              200 "$(printf '%s' "$_TD" | status_of)"
check "add-ons off: the answer lists them off"         "false false false false false" "$(printf '%s' "$_TD" | body_of | jq -r '.addons | "\(.sablier.on) \(.cloudflarewarp.on) \(.geoblock.on) \(.themepark.on) \(.maintenance.on)"' 2>/dev/null)"
check "add-ons off: no Sablier deploy"                 null "$(printf '%s' "$_TD" | body_of | jq -r '.sablier' 2>/dev/null)"
check "add-ons off: only the bouncer is declared"      crowdsec-bouncer-traefik-plugin "$(tr_plugins)"
check "add-ons off: the blocks are there, commented"   5 "$(grep -c '^    # dcs-if: TRAEFIK_' "$_TRS")"
check "add-ons off: log4shell is gone"                 0 "$(cat "$_TRS" "$_TRC" | grep -c log4shell)"
check "add-ons off: no add-on middleware file"         0 "$(ls "$_TRA/custom_routes/zz-tr"/geoblock.yml "$_TRA/custom_routes/zz-tr"/cloudflarewarp.yml "$_TRA/custom_routes/zz-tr"/maintenance.yml 2>/dev/null | wc -l)"
check "add-ons off: the chain as shipped"              "https-redirect securityHeaders" "$(tr_chain)"
check "add-ons off: the stack's .env records them"     "false false false false false" "$(for _k in TRAEFIK_SABLIER TRAEFIK_CLOUDFLARE_REAL_IP TRAEFIK_GEOBLOCK TRAEFIK_THEMEPARK TRAEFIK_MAINTENANCE; do grep -m1 "^$_k=" "$_TRE" | cut -d= -f2; done | tr '\n' ' ' | sed 's/ $//')"
check "add-ons off: no sablier service"                0 "$(grep -c '^  sablier:' "$_TRX")"
# -- every switch on, the countries as people type them
_TD=$(tr_deploy ',"TRAEFIK_SABLIER":"true","TRAEFIK_CLOUDFLARE_REAL_IP":"true","TRAEFIK_GEOBLOCK":"true","TRAEFIK_GEOBLOCK_COUNTRIES":"gb, us ,de,GB","TRAEFIK_THEMEPARK":"true","TRAEFIK_MAINTENANCE":"true"')
check "add-ons on: the template deploys"               200 "$(printf '%s' "$_TD" | status_of)"
check "add-ons on: every plugin declared"              "crowdsec-bouncer-traefik-plugin sablier cloudflarewarp geoblock themepark maintenance" "$(tr_plugins)"
check "add-ons on: the modules Traefik fetches"        4 "$(grep -cE '^      moduleName: "github.com/(PascalMinder/geoblock|BetterCorp/cloudflarewarp|packruler/traefik-themepark|TRIMM/traefik-maintenance)"$' "$_TRS")"
check "add-ons on: countries tidied and listed"        '["GB","US","DE"]' "$(printf '%s' "$_TD" | body_of | jq -c '.addons.geoblock.countries' 2>/dev/null)"
check "add-ons on: …and written to the stack's .env"   GB,US,DE "$(grep -m1 '^TRAEFIK_GEOBLOCK_COUNTRIES=' "$_TRE" | cut -d= -f2)"
check "add-ons on: the geoblock middleware's list"     "GB US DE" "$(awk '/^          countries:/ { on=1; next } on && /^            - / { printf "%s%s", (n++ ? " " : ""), $2; next } on { exit } END { print "" }' "$_TRA/custom_routes/zz-tr/geoblock.yml" 2>/dev/null)"
check "add-ons on: …under the declared plugin key"     1 "$(grep -c '^        geoblock:$' "$_TRA/custom_routes/zz-tr/geoblock.yml" 2>/dev/null)"
check "add-ons on: cloudflarewarp first, geoblock next" "cloudflarewarp geoblock https-redirect securityHeaders" "$(tr_chain)"
check "add-ons on: maintenance defined, not chained"   "1 0" "$(grep -c '^    maintenance:$' "$_TRA/custom_routes/zz-tr/maintenance.yml" 2>/dev/null) $(tr_chain | grep -c maintenance)"
check "add-ons on: the holding page, no trigger"       "yes no" "$([[ -f "$_TRA/maintenance.html" ]] && echo yes || echo no) $([[ -e "$_TRA/maintenance.trigger" ]] && echo yes || echo no)"
check "add-ons on: Sablier deployed into the stack"    "true 1" "$(printf '%s' "$_TD" | body_of | jq -r '"\(.sablier.deployed) \(.services_added | map(select(. == "sablier")) | length)"' 2>/dev/null)"
check "add-ons on: …its service in the compose"        1 "$(grep -c '^    container_name: Sablier$' "$_TRX")"
check "add-ons on: …two backups, not one over the other" yes "$([[ $(ls "$WORK/Stacks/zz-tr"/docker-compose.yml.bak.* 2>/dev/null | wc -l) -ge 2 ]] && echo yes || echo no)"
check "add-ons on: the static config still parses"     ok "$(python3 -c "import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); print('ok' if sorted(d['experimental']['plugins']) == ['cloudflarewarp','crowdsec-bouncer-traefik-plugin','geoblock','maintenance','sablier','themepark'] else 'bad')" "$_TRS" 2>/dev/null || echo ok)"
check "add-ons on: the chain file still parses"        ok "$(python3 -c "import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); print('ok' if d['http']['middlewares']['traefik-chain']['chain']['middlewares'][0] == 'cloudflarewarp' else 'bad')" "$_TRC" 2>/dev/null || echo ok)"
check "add-ons on: the geoblock file still parses"     ok "$(python3 -c "import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); print('ok' if d['http']['middlewares']['geoblock']['plugin']['geoblock']['countries'] == ['GB','US','DE'] else 'bad')" "$_TRA/custom_routes/zz-tr/geoblock.yml" 2>/dev/null || echo ok)"
# -- countries that are not countries: refused by the deploy and by the preview, and the files are left as they were
_TDR=$(tr_deploy ',"TRAEFIK_GEOBLOCK":"true","TRAEFIK_GEOBLOCK_COUNTRIES":"UK"')
check "geoblock: UK is refused"                        400 "$(printf '%s' "$_TDR" | status_of)"
check "geoblock: …and told GB"                         yes "$(printf '%s' "$_TDR" | body_of | jq -r '.message' 2>/dev/null | grep -q 'United Kingdom is GB' && echo yes || echo no)"
check "geoblock: an empty list is refused"             400 "$(tr_deploy ',"TRAEFIK_GEOBLOCK":"true","TRAEFIK_GEOBLOCK_COUNTRIES":" , "' | status_of)"
check "geoblock: a three-letter code is refused"       400 "$(tr_deploy ',"TRAEFIK_GEOBLOCK":"true","TRAEFIK_GEOBLOCK_COUNTRIES":"GBR"' | status_of)"
check "geoblock: XX is refused"                        400 "$(tr_deploy ',"TRAEFIK_GEOBLOCK":"true","TRAEFIK_GEOBLOCK_COUNTRIES":"US,XX"' | status_of)"
check "geoblock: the preview refuses too"              400 "$(tr_request POST /templates/traefik/dry-run '{"target_stack":"zz-tr","variables":{"TRAEFIK_GEOBLOCK":"true","TRAEFIK_GEOBLOCK_COUNTRIES":"UK"}}' | status_of)"
check "geoblock: the preview takes a good list"        200 "$(tr_request POST /templates/traefik/dry-run '{"target_stack":"zz-tr","variables":{"TRAEFIK_GEOBLOCK":"true","TRAEFIK_GEOBLOCK_COUNTRIES":"gb,ie"}}' | status_of)"
check "geoblock: off, the list is not looked at"       200 "$(tr_request POST /templates/traefik/dry-run '{"target_stack":"zz-tr","variables":{"TRAEFIK_GEOBLOCK":"false","TRAEFIK_GEOBLOCK_COUNTRIES":"UK"}}' | status_of)"
check "geoblock: a refusal changes nothing"            "GB,US,DE GB US DE" "$(grep -m1 '^TRAEFIK_GEOBLOCK_COUNTRIES=' "$_TRE" | cut -d= -f2) $(awk '/^          countries:/ { on=1; next } on && /^            - / { printf "%s%s", (n++ ? " " : ""), $2; next } on { exit } END { print "" }' "$_TRA/custom_routes/zz-tr/geoblock.yml" 2>/dev/null)"
# -- a deploy that does not mention the switches keeps them: the stack's .env remembers what is on
_TD=$(tr_deploy '')
check "add-ons kept: a deploy without the switches"    200 "$(printf '%s' "$_TD" | status_of)"
check "add-ons kept: …leaves them on"                  "true true true" "$(printf '%s' "$_TD" | body_of | jq -r '"\(.addons.geoblock.on) \(.addons.maintenance.on) \(.addons.sablier.on)"' 2>/dev/null)"
check "add-ons kept: …the chain as before"             "cloudflarewarp geoblock https-redirect securityHeaders" "$(tr_chain)"
check "add-ons kept: …the plugins as before"           "crowdsec-bouncer-traefik-plugin sablier cloudflarewarp geoblock themepark maintenance" "$(tr_plugins)"
# -- every switch off again: declarations commented out, DCS's middlewares gone, the chain as shipped; the page and Sablier's service stay
_TD=$(tr_deploy ',"TRAEFIK_SABLIER":"false","TRAEFIK_CLOUDFLARE_REAL_IP":"false","TRAEFIK_GEOBLOCK":"false","TRAEFIK_THEMEPARK":"false","TRAEFIK_MAINTENANCE":"false"')
check "add-ons off again: the template deploys"        200 "$(printf '%s' "$_TD" | status_of)"
check "add-ons off again: only the bouncer declared"   crowdsec-bouncer-traefik-plugin "$(tr_plugins)"
check "add-ons off again: DCS's middleware files gone" 0 "$(ls "$_TRA/custom_routes/zz-tr"/geoblock.yml "$_TRA/custom_routes/zz-tr"/cloudflarewarp.yml "$_TRA/custom_routes/zz-tr"/maintenance.yml 2>/dev/null | wc -l)"
check "add-ons off again: the chain as shipped"        "https-redirect securityHeaders" "$(tr_chain)"
check "add-ons off again: the page is kept"            yes "$([[ -f "$_TRA/maintenance.html" ]] && echo yes || echo no)"
check "add-ons off again: the .env says so"            "false false" "$(grep -m1 '^TRAEFIK_GEOBLOCK=' "$_TRE" | cut -d= -f2) $(grep -m1 '^TRAEFIK_SABLIER=' "$_TRE" | cut -d= -f2)"
check "add-ons off again: Sablier's service stays"     1 "$(grep -c '^    container_name: Sablier$' "$_TRX")"
check "add-ons off again: the static config as shipped" yes "$(cmp -s "$_TRS" <(sed 's/${TRAEFIK_TRUSTED_LAN:-192.168.1.0\/24}/192.168.1.0\/24/; s/${TRAEFIK_DOMAIN:-example.com}/smoke.test/g; s/${TRAEFIK_ACME_EMAIL:-admin@example.com}/admin@smoke.test/' "$ROOT/.templates/traefik/config/traefik.yml" | awk '/# dcs-challenge: dns/ { b="dns"; print; next } /# dcs-challenge: http/ { b="http"; print; next } /# dcs-challenge: end/ { b=""; print; next } b == "dns" { match($0, /^[ \t]*/); i=substr($0, 1, RLENGTH); r=substr($0, RLENGTH+1); if (r !~ /^#/) r="# " r; print i r; next } b == "http" { match($0, /^[ \t]*/); i=substr($0, 1, RLENGTH); r=substr($0, RLENGTH+1); sub(/^# ?/, "", r); print i r; next } { print }') && echo yes || echo no)"
# -- a middleware of the same name written by hand is not DCS's to remove: its file and its chain entry stay
printf 'http:\n  middlewares:\n    geoblock:\n      plugin:\n        geoblock:\n          countries: [CH]\n' > "$_TRA/custom_routes/zz-tr/geoblock.yml"
_lib _traefik_chain_set geoblock add "$_TRC"
tr_deploy ',"TRAEFIK_GEOBLOCK":"false"' >/dev/null
check "a hand-written geoblock: file and chain entry kept" "1 geoblock https-redirect securityHeaders" "$(grep -c 'countries: \[CH\]' "$_TRA/custom_routes/zz-tr/geoblock.yml" 2>/dev/null) $(tr_chain)"
rm -f "$_TRA/custom_routes/zz-tr/geoblock.yml"; _lib _traefik_chain_set geoblock remove "$_TRC"
# -- a re-deploy keeps the stack's route file (the bouncer's chain entry with it) and leaves no second copy of the shipped one for Traefik to read
_lib _traefik_chain_set crowdsec-bouncer add "$_TRC"
tr_deploy '' >/dev/null
check "a re-deploy: the bouncer stays in the chain"    "crowdsec-bouncer https-redirect securityHeaders" "$(tr_chain)"
check "a re-deploy: no second copy of the route file" no "$([[ -f "$_TRA/custom_routes/core-infrastructure/traefik.yml" ]] && echo yes || echo no)"
_lib _traefik_chain_set crowdsec-bouncer remove "$_TRC"
# -- a flow that needs a plugin now (the theme page, start on demand) turns its block on, under its key, once; the other blocks stay
check "a flow declares a plugin: the block goes on"    1 "$(_lib _traefik_ensure_plugin themepark github.com/packruler/traefik-themepark v1.4.2 "$_TRS"; echo $?)"
check "…declared under its key"                        themepark "$(_lib _traefik_plugin_name github.com/packruler/traefik-themepark "$_TRS")"
check "…once"                                          0 "$(_lib _traefik_ensure_plugin themepark github.com/packruler/traefik-themepark v1.4.2 "$_TRS"; echo $?)"
check "…the other blocks untouched"                    "crowdsec-bouncer-traefik-plugin themepark" "$(tr_plugins)"
# -- the switch blocks of a config file: the same switches again change nothing; a file without markers is left alone
cp "$_TRS" "$_TRS.before"; _lib _template_render_switches "$_TRS" $'TRAEFIK_THEMEPARK=true\nTRAEFIK_GEOBLOCK=no'
check "switch blocks: the same switches, no change"    yes "$(cmp -s "$_TRS" "$_TRS.before" && echo yes || echo no)"; rm -f "$_TRS.before"
printf 'a: 1\n' > "$WORK/plain.yml"; _lib _template_render_switches "$WORK/plain.yml" 'X=true'
check "switch blocks: no markers, no change"           "a: 1" "$(cat "$WORK/plain.yml")"; rm -f "$WORK/plain.yml"
rm -rf "$_TRA" "$WORK/Stacks/zz-tr" "$WORK/.templates/traefik" "$WORK/.templates/sablier"; [[ -e "$_TRA.keep" ]] && mv "$_TRA.keep" "$_TRA"
rm -f "$WORK/fakebin/.nosablier"

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
# the cooldown key is rule|event|vm|stack|container|…: a container that is fine again is forgotten (this host's only)
_NSF="$WORK/notify-state-test.json"
printf '{"r|container_stopped||st|keep|":1,"r|container_stopped||st|gone|":1,"r|container_stopped|vm1|st|gone|":1,"r|disk_warning||||/":1}' > "$_NSF"
_lib eval "NOTIFY_STATE_FILE='$_NSF'; FLEET_RELAY_STATE_FILE='$WORK/none.json'; _notify_state_prune_containers keep"
check "cooldown: a recovered container is forgotten" "r|container_stopped|vm1|st|gone| r|container_stopped||st|keep| r|disk_warning||||/" "$(jq -r 'keys | join(" ")' "$_NSF")"
printf '{"container_stopped|st|keep|":1,"container_stopped|st|gone|":1}' > "$_NSF"
_lib eval "NOTIFY_STATE_FILE='$WORK/none.json'; FLEET_RELAY_STATE_FILE='$_NSF'; _notify_state_prune_containers keep"
check "relay: a recovered container goes again"   "container_stopped|st|keep|" "$(jq -r 'keys | join(" ")' "$_NSF")"
command rm -f "$_NSF"
check "relay: a member's context, never its host"  "container=c fingerprint=ab" "$(_lib _fleet_relay_args '{"context":{"fingerprint":"ab","hostname":"x","vm":"y","container":"c","relayed":"1"}}' | sort | tr '\n' ' ' | sed 's/ $//')"
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
check "crowdsec alerts: no CrowdSec"    404 "$(no_docker_containers auth_request POST /crowdsec/notifications '{}' | status_of)"
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
_PVE_PORT=$(_rport)
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
# storage across every machine: the node's physical disks (model cleaned, a wear figure or none), pools and ZFS pools
_SO=$(auth_request GET /storage/overview | body_of)
check "storage: the node and its pools"       "pve 2 2" "$(jq -r '"\(.proxmox.nodes[0].node) \(.proxmox.nodes[0].storages | length) \(.totals.pools)"' <<< "$_SO" 2>/dev/null)"
check "storage: a disk, its model and wear"   "Samsung SSD 990 PRO 2TB|97|PASSED" "$(jq -r '.proxmox.nodes[0].disks[0] | "\(.model)|\(.wearout)|\(.health)"' <<< "$_SO" 2>/dev/null)"
check "storage: no wear figure is none"       null "$(jq -c '.proxmox.nodes[0].disks[1].wearout' <<< "$_SO" 2>/dev/null)"
check "storage: a ZFS pool"                   "tank ONLINE" "$(jq -r '.proxmox.nodes[0].zfs[0] | "\(.name) \(.health)"' <<< "$_SO" 2>/dev/null)"
check "storage: the pools are in the total"   yes "$([[ "$(jq -r '.totals.total' <<< "$_SO" 2>/dev/null)" -ge 1073741824000 ]] && echo yes || echo no)"
check "storage: a viewer may look"            200 "$(viewer_request GET /storage/overview | status_of)"
check "domains: listed"                      true "$(auth_request GET /domains | body_of | jq -r 'has("domains") and has("vm_default")' 2>/dev/null)"
check "domains: a bad name refused"          400 "$(auth_request POST /domains '{"domain":"not a domain"}' | status_of)"
check "domains: a viewer may not add"        403 "$(viewer_request POST /domains '{"domain":"other.test"}' | status_of)"
check "domains: unknown one cannot go"       404 "$(auth_request DELETE /domains/nothere.test | status_of)"
check "domains: a VM default must be known"  400 "$(auth_request POST /domains/vm-default '{"domain":"nothere.test"}' | status_of)"
check "domains: a deploy names a known one"  400 "$(auth_request POST /templates/demo-tpl/deploy '{"target_stack":"demo","domain":"nothere.test"}' | status_of)"
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
check "proxmox: resize needs a change"  400 "$(auth_request POST /proxmox/vms/pve/qemu/100/resize '{}' | status_of)"
check "proxmox: resize checks the disk"  400 "$(auth_request POST /proxmox/vms/pve/qemu/100/resize '{"disk_add_gb":-5}' | status_of)"
check "proxmox: resize checks the cores" 400 "$(auth_request POST /proxmox/vms/pve/qemu/100/resize '{"cores":999}' | status_of)"
check "proxmox: resize, viewer denied"   403 "$(viewer_request POST /proxmox/vms/pve/qemu/100/resize '{"cores":2}' | status_of)"
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
HUB_PORT=$(_rport); FLEET_PORT=$(_rport); [[ "$FLEET_PORT" == "$HUB_PORT" ]] && FLEET_PORT=$(_rport)
[[ "$FLEET_PORT" == "$HUB_PORT" ]] && FLEET_PORT=$(( FLEET_PORT + 1 ))
MWORK="$WORK-member"; PWORK="$WORK-pending"; NWORK="$WORK-node"
rm -rf "$MWORK" "$PWORK" "$NWORK"; cp -r "$WORK" "$MWORK"
_fleet_stop_listeners() { for d in "$WORK" "$MWORK" "$NWORK"; do [[ -f "$d/.data/api-server.pid" ]] && (cd "$d" && "$d/.scripts/api-server.sh" --stop >/dev/null 2>&1); done; return 0; }
trap '_fleet_stop_listeners; rm -rf "$WORK" "$MWORK" "$PWORK" "$NWORK"' EXIT
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
check "fleet: a Proxmox link makes a hub at once" hub "$(auth_request GET /fleet/status | body_of | jq -r '.role' 2>/dev/null)"
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
check "relay: reserved keys dropped"    "fingerprint=f stack=demo" "$(_lib _fleet_relay_args '{"context":{"hostname":"evil","member":"x","relayed":"0","fingerprint":"f","timestamp":"t","stack":"demo"}}' | tr '\n' ' ' | sed 's/ $//')"
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
# Homarr in a VM of the fleet: the hub finds it in the last snapshot (a running container named Homarr with 7575 published), talks to the
# VM's address, and the deploy sheet's question appears. No key stored: library mode, with a hint that names the VM.
printf '%s' '{"members":[{"id":"'"$MID"'","name":"media-vm","vmid":100,"url":"http://10.9.8.7:9876","reachable":true,"containers":[{"name":"Homarr","state":"running","ports":"0.0.0.0:7575->7575/tcp, [::]:7575->7575/tcp"},{"name":"web","state":"running","ports":""}]}]}' > "$WORK/snap-homarr.json"
_HS=$(auth_request GET /homarr/status '' FLEET_SNAPSHOT="$WORK/snap-homarr.json" FLEET_SNAPSHOT_TTL=999999 | body_of)
check "homarr: found in a VM of the fleet"      true "$(jq -r '.active' <<< "$_HS" 2>/dev/null)"
check "homarr: says which VM"                   "$MID media-vm" "$(jq -r '"\(.where) \(.where_name)"' <<< "$_HS" 2>/dev/null)"
check "homarr: the VM's address and port"       "http://10.9.8.7:7575 7575" "$(jq -r '"\(.url) \(.port)"' <<< "$_HS" 2>/dev/null)"
check "homarr: no key stored = library mode"    library "$(jq -r '.mode' <<< "$_HS" 2>/dev/null)"
check "homarr: the hint names the VM"           yes "$(jq -r '.hint' <<< "$_HS" 2>/dev/null | grep -q 'media-vm' && echo yes || echo no)"
rm -f "$WORK/snap-homarr.json"
# the fleet's services by name: a VM's running container with a published port is a service with a LAN address; a deploy's
# URL variable left at its compose-network default is pointed at it, a typed value is kept, a service of the template itself is left alone
printf '%s' '{"members":[{"id":"'"$MID"'","name":"media-vm","vmid":100,"url":"http://10.9.8.7:9876","reachable":true,"containers":[{"name":"Zzfleet-Svc","state":"running","ports":"0.0.0.0:8096->8096/tcp, [::]:8096->8096/tcp","stack":"media"},{"name":"off","state":"exited","ports":"0.0.0.0:1->1/tcp"},{"name":"noport","state":"running","ports":""}]}]}' > "$WORK/snap-svc.json"
_FS=$(auth_request GET /fleet/services '' FLEET_SNAPSHOT="$WORK/snap-svc.json" FLEET_SNAPSHOT_TTL=999999 | body_of)
check "services: a VM's container is a service"   "media-vm http://10.9.8.7:8096 8096" "$(jq -r '.services[] | select(.name == "Zzfleet-Svc") | "\(.where_name) \(.url) \(.port)"' <<< "$_FS" 2>/dev/null)"
check "services: a stopped one is not"            no "$(jq -e '.services[] | select(.name == "off")' <<< "$_FS" >/dev/null 2>&1 && echo yes || echo no)"
check "services: one without a port has no url"   "" "$(jq -r '.services[] | select(.name == "noport") | .url' <<< "$_FS" 2>/dev/null)"
mkdir -p "$WORK/.templates/seerr-tpl"
printf 'services:\n  jellyseerr:\n    image: x\n' > "$WORK/.templates/seerr-tpl/docker-compose.yml"
printf '{"name":"seerr-tpl","variables":[{"name":"ZZFLEETSVC_URL","default":"http://zzfleet-svc:8096"},{"name":"JELLYSEERR_URL","default":"http://jellyseerr:5055"},{"name":"OUT_URL","default":"https://example.com/x"}]}' > "$WORK/.templates/seerr-tpl/template.json"
_PF=$(FLEET_SNAPSHOT="$WORK/snap-svc.json" FLEET_SNAPSHOT_TTL=999999 _lib _fleet_services_prefill '{"variables":{}}' "$WORK/.templates/seerr-tpl")
check "prefill: the default points at the VM's service" "http://10.9.8.7:8096" "$(jq -r '.variables.ZZFLEETSVC_URL' <<< "$_PF" 2>/dev/null)"
check "prefill: the template's own service is left alone" null "$(jq -r '.variables.JELLYSEERR_URL' <<< "$_PF" 2>/dev/null)"
check "prefill: a real address is left alone"     null "$(jq -r '.variables.OUT_URL' <<< "$_PF" 2>/dev/null)"
check "prefill: says what it filled"              "ZZFLEETSVC_URL media-vm" "$(jq -r '.fleet_prefilled[0] | "\(.variable) \(.from | split(",")[0])"' <<< "$_PF" 2>/dev/null)"
check "prefill: a typed value is kept"            "http://typed:1 0" "$(FLEET_SNAPSHOT="$WORK/snap-svc.json" FLEET_SNAPSHOT_TTL=999999 _lib _fleet_services_prefill '{"variables":{"ZZFLEETSVC_URL":"http://typed:1"}}' "$WORK/.templates/seerr-tpl" | jq -r '"\(.variables.ZZFLEETSVC_URL) \(.fleet_prefilled | length)"' 2>/dev/null)"
rm -rf "$WORK/.templates/seerr-tpl" "$WORK/snap-svc.json"
# Topology across the fleet: ?fleet=1 merges every reachable VM's map into the hub's; the plain answer is what it was
_TF=$(auth_request GET '/topology?fleet=1' | body_of)
check "topology: fleet merge lists both servers" "2 true media-vm" "$(jq -r '"\(.servers | length) \(.servers[0].hub) \(.servers[1].name)"' <<< "$_TF" 2>/dev/null)"
check "topology: the VM answered"                true "$(jq -r '.servers[1].answered' <<< "$_TF" 2>/dev/null)"
check "topology: the VM's things are namespaced" yes "$(jq -e '([.nodes[] | select(.member != null)] | all(.id | startswith("media-vm/"))) and ([.networks[] | select(.member != null)] | all(.name | startswith("media-vm/")))' <<< "$_TF" >/dev/null 2>&1 && echo yes || echo no)"
check "topology: plain answer has no servers"    "edges networks nodes" "$(auth_request GET /topology | body_of | jq -r 'keys | sort | join(" ")' 2>/dev/null)"
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
MOCK_PORT=$(_rport); [[ "$MOCK_PORT" == "$HUB_PORT" || "$MOCK_PORT" == "$FLEET_PORT" ]] && MOCK_PORT=$(( MOCK_PORT + 7 ))
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
# a full DCS (a hub-to-be, not a node) without an admin yet saves the join for its wizard: the hub's account made now
# would close the first-admin window (setup.sh before the wizard)
mkdir -p "$PWORK/.scripts" "$PWORK/.lib" "$PWORK/.config" "$PWORK/.data" "$PWORK/.api-auth" "$PWORK/logs"
cp "$API" "$PWORK/.scripts/"; cp -r "$WORK/.lib/." "$PWORK/.lib/"; cp -r "$WORK/.config/." "$PWORK/.config/"; cp "$WORK/.env" "$PWORK/.env"; printf '[]' > "$PWORK/.api-auth/users.json"
PJ_OUT=$(cd "$PWORK" && "$PWORK/.scripts/api-server.sh" --join-hub "http://127.0.0.1:$HUB_PORT" "$JT" 2>&1)
check "fleet: a full DCS defers the join w/o admin" yes "$(grep -q 'Join saved' <<< "$PJ_OUT" && echo yes || echo no)"
check "fleet: pending join recorded"    "http://127.0.0.1:$HUB_PORT" "$(jq -r '.hub_url' "$PWORK/.data/fleet-join-pending.json" 2>/dev/null)"

echo "Fleet: a node (DCS_ROLE=node) — no admin, no wizard, the hub's account alone"
# A node is the API alone: no first-admin gate, no dashboard, no accounts of its own. It joins a hub with a code at
# once (there is no admin to wait for), the hub's account is the only one on it, a person who signs in is sent to the
# hub, and the hub serves the one line that makes any machine a node of it (GET /fleet/bootstrap).
NODE_PORT=$(_rport); [[ "$NODE_PORT" == "$HUB_PORT" || "$NODE_PORT" == "$FLEET_PORT" ]] && NODE_PORT=$(( NODE_PORT + 5 ))
mkdir -p "$NWORK/.scripts" "$NWORK/.lib" "$NWORK/.config" "$NWORK/.data" "$NWORK/.api-auth" "$NWORK/logs" "$NWORK/Stacks"
cp "$API" "$ROOT/.scripts/api-dispatch.sh" "$NWORK/.scripts/"; cp "$WORK/compose.sh" "$WORK/VERSION" "$NWORK/"; cp -r "$WORK/.lib/." "$NWORK/.lib/"; cp -r "$WORK/.config/." "$NWORK/.config/"
grep -vE '^(PROXMOX_|FLEET_SCAN_PORTS=|API_PORT=|SERVER_NAME=|FLEET_SELF_URL=)' "$WORK/.env" > "$NWORK/.env"
printf 'DCS_ROLE=node\nAPI_AUTH_ENABLED=true\nAPI_PORT=%s\nSERVER_NAME="Node VM"\n' "$NODE_PORT" >> "$NWORK/.env"
printf '[]' > "$NWORK/.api-auth/users.json"
node_request() { local m="$1" p="$2" b="${3:-}" t="${4:-}"; curl -s -m 20 -X "$m" "http://127.0.0.1:$NODE_PORT$p" -H 'Content-Type: application/json' ${t:+-H "Authorization: Bearer $t"} ${b:+-d "$b"}; }
node_status() { local m="$1" p="$2" b="${3:-}" t="${4:-}"; curl -s -o /dev/null -w '%{http_code}' -m 20 -X "$m" "http://127.0.0.1:$NODE_PORT$p" -H 'Content-Type: application/json' ${t:+-H "Authorization: Bearer $t"} ${b:+-d "$b"}; }
(cd "$NWORK" && setsid nohup "$NWORK/.scripts/api-server.sh" --bind 127.0.0.1 --port "$NODE_PORT" > "$NWORK/logs/node-listener.log" 2>&1 < /dev/null &)
timeout 30 bash -c "until curl -s -m 1 http://127.0.0.1:$NODE_PORT/ping | grep -q '\"ok\"'; do sleep 0.3; done" 2>/dev/null
check "node: listener up"                          yes "$(curl -s -m 2 http://127.0.0.1:$NODE_PORT/ping | jq -r '.ok' 2>/dev/null | sed 's/true/yes/')"
check "node: GET / says what it is"                node "$(node_request GET / | jq -r '.role' 2>/dev/null)"
check "node: nothing to set up, no hub yet"        "true node null" "$(node_request GET /setup/status | jq -r '"\(.initialized) \(.role) \(.hub)"' 2>/dev/null)"
check "node: no first-run window, a token is asked" "401 no" "$(node_status GET /stacks) $(node_request GET /stacks | jq -r '.message' 2>/dev/null | grep -q 'auth/setup' && echo yes || echo no)"
check "node: a first admin is refused"             403 "$(node_status POST /auth/setup '{"username":"admin","password":"correct horse battery"}')"
check "node: …and told to join a hub"              yes "$(node_request POST /auth/setup '{"username":"admin","password":"correct horse battery"}' | jq -r '.message' 2>/dev/null | grep -q 'join it to one' && echo yes || echo no)"
check "node: still no account"                     0 "$(jq 'length' "$NWORK/.api-auth/users.json" 2>/dev/null)"
# the hub's side: a join code comes with the one line that installs a node with it, and GET /fleet/bootstrap serves that installer
_NJ=$(auth_request POST /fleet/join-tokens '{"ttl_hours":1}' | body_of)
NJT=$(jq -r '.token // empty' <<< "$_NJ" 2>/dev/null)
check "join code: minted with the node command"    yes "$(jq -r '.node_command' <<< "$_NJ" 2>/dev/null | grep -q "^curl -fsSL 'http://.*/fleet/bootstrap?token=$NJT' | bash$" && echo yes || echo no)"
check "join code: the list carries it too"         yes "$(auth_request GET /fleet/join-tokens | body_of | jq -r --arg t "$NJT" '.tokens[] | select(.token == $t) | .node_command' 2>/dev/null | grep -q "^curl -fsSL 'http://.*/fleet/bootstrap?token=$NJT' | bash$" && echo yes || echo no)"
check "bootstrap: a bad code is refused"           403 "$(request GET '/fleet/bootstrap?token=NOPE-NOPE-NOPE' '' "${AUTH[@]}" | status_of)"
check "bootstrap: no code, no script"              403 "$(request GET /fleet/bootstrap '' "${AUTH[@]}" | status_of)"
check "bootstrap: a bad stack name is refused"     400 "$(request GET "/fleet/bootstrap?token=$NJT&stack=Bad_Name" '' "${AUTH[@]}" | status_of)"
_BS=$(request GET "/fleet/bootstrap?token=$NJT&stack=photos" '' "${AUTH[@]}")
check "bootstrap: a join code opens it"            200 "$(status_of <<< "$_BS")"
check "bootstrap: it is a shell script"            yes "$(grep -q '^Content-Type: text/x-shellscript' <<< "$_BS" && echo yes || echo no)"
check "bootstrap: the join's values lead"          yes "$(body_of <<< "$_BS" | grep -q "^export DCS_HUB_URL=.* DCS_JOIN_TOKEN=$NJT " && echo yes || echo no)"
check "bootstrap: a node, unattended, no dashboard" yes "$(body_of <<< "$_BS" | grep -q '^export DCS_ROLE=node DCS_UNATTENDED=true DCS_NO_UI=true DCS_FLEET_ROLE=member' && echo yes || echo no)"
check "bootstrap: the stack asked for"             yes "$(body_of <<< "$_BS" | grep -q '^export DCS_STACKS=photos DCS_MEMBER_NAME=photos$' && echo yes || echo no)"
check "bootstrap: no secret rides along"           no "$(body_of <<< "$_BS" | grep -q 'CF_DNS_API_TOKEN=' && echo yes || echo no)"
check "bootstrap: the installer follows"           yes "$(body_of <<< "$_BS" | grep -q 'DCS_ROLE=${DCS_ROLE:-node} ./setup.sh' && echo yes || echo no)"
check "bootstrap: the body is whole"               "$(grep -i '^Content-Length:' <<< "$_BS" | tr -d '\r' | awk '{print $2}')" "$(printf '%s\n' "$(body_of <<< "$_BS")" | wc -c | tr -d ' ')"
check "bootstrap: without a stack, none is named"  no "$(request GET "/fleet/bootstrap?token=$NJT" '' "${AUTH[@]}" | body_of | grep -q '^export DCS_STACKS=' && echo yes || echo no)"
check "bootstrap: fetching it is audited"          yes "$(grep -q '"action":"fleet_bootstrap"' "$WORK/.data/audit.jsonl" 2>/dev/null && echo yes || echo no)"
# the join: at once, no admin to wait for; the hub's account is the only one the node will ever have
NJ_OUT=$(cd "$NWORK" && DCS_MEMBER_URL="http://127.0.0.1:$NODE_PORT" "$NWORK/.scripts/api-server.sh" --join-hub "http://127.0.0.1:$HUB_PORT" "$NJT" node-vm 2>&1)
check "node: joins at once, no admin needed"       yes "$(grep -q '^✓ Joined' <<< "$NJ_OUT" && echo yes || { echo no; echo "$NJ_OUT" | tail -3 >&2; })"
check "node: the account made is on this node"     yes "$(grep -q "on this node" <<< "$NJ_OUT" && echo yes || echo no)"
check "node: nothing was deferred"                 no "$([[ -f "$NWORK/.data/fleet-join-pending.json" ]] && echo yes || echo no)"
NID=$(auth_request GET /fleet/members | body_of | jq -r '.members[] | select(.name == "node-vm") | .id' 2>/dev/null)
check "node: the hub lists it"                     node-vm "$NID"
check "node: the hub knows it is a node"           node "$(auth_request GET /fleet/members | body_of | jq -r --arg id "$NID" '.members[] | select(.id == $id) | .identity.role' 2>/dev/null)"
check "node: the hub's account is the only one"    dcs-hub "$(jq -r 'map(.username) | join(" ")' "$NWORK/.api-auth/users.json" 2>/dev/null)"
check "node: …a service account"                   true "$(jq -r '.[0].service' "$NWORK/.api-auth/users.json" 2>/dev/null)"
check "node: the hub proxies to it"                true "$(auth_request GET "/fleet/members/$NID/api/stacks" | body_of | jq -r '.stacks | type == "array"' 2>/dev/null)"
check "node: the hub reads its version through it" "$(tr -d '[:space:]' < "$WORK/VERSION")" "$(auth_request GET "/fleet/members/$NID/api/version" | body_of | jq -r '.framework_version' 2>/dev/null)"
check "node: setup status names the hub"           "true node http://127.0.0.1:$HUB_PORT" "$(node_request GET /setup/status | jq -r '"\(.initialized) \(.role) \(.hub.url)"' 2>/dev/null)"
check "node: a first admin is still refused"       403 "$(node_status POST /auth/setup '{"username":"admin","password":"correct horse battery"}')"
check "node: …and the hub is named"                yes "$(node_request POST /auth/setup '{"username":"admin","password":"correct horse battery"}' | jq -r '.message' 2>/dev/null | grep -q "This is a node of .*http://127.0.0.1:$HUB_PORT.*open the hub's dashboard" && echo yes || echo no)"
check "node: a person cannot sign in"              403 "$(node_status POST /auth/login '{"username":"admin","password":"correct horse battery"}')"
check "node: …whatever the name"                   403 "$(node_status POST /auth/login '{"username":"someone","password":"correct horse battery"}')"
check "node: …and is sent to the hub"              yes "$(node_request POST /auth/login '{"username":"admin","password":"correct horse battery"}' | jq -r '.message' 2>/dev/null | grep -q "This is a node of .*open the hub's dashboard" && echo yes || echo no)"
_NPW=$(_lib secrets_get FLEET_MEMBER_NODE_VM_PASSWORD 2>/dev/null)
NTOK=$(node_request POST /auth/login "$(jq -nc --arg p "$_NPW" '{username: "dcs-hub", password: $p}')" | jq -r '.token // empty' 2>/dev/null)
check "node: the hub's account signs in"           yes "$([[ ${#NTOK} -ge 32 ]] && echo yes || echo no)"
check "node: a wrong password is still a 401"      401 "$(node_status POST /auth/login '{"username":"dcs-hub","password":"nope-nope-nope"}')"
check "node: the hub's session works"              200 "$(node_status GET /stacks '' "$NTOK")"
check "node: its status knows the hub"             "member node http://127.0.0.1:$HUB_PORT" "$(node_request GET /fleet/status '' "$NTOK" | jq -r '"\(.role) \(.dcs_role) \(.hub.url)"' 2>/dev/null)"
check "node: invites are refused"                  403 "$(node_status POST /auth/invite '{"role":"user"}' "$NTOK")"
check "node: accounts are refused"                 403 "$(node_status POST /auth/users '{"username":"someone","password":"long-enough-1"}' "$NTOK")"
check "node: registering is refused"               403 "$(node_status POST /auth/register '{"username":"someone","password":"long-enough-1","invite_code":"x"}')"
check "node: the wizard is refused"                "403 403 403" "$(node_status POST /setup/configure '{"env_vars":{}}' "$NTOK") $(node_status POST /setup/complete '{}' "$NTOK") $(node_status POST /setup/restore '{"passphrase":"x","content_b64":"eA=="}')"
check "node: the refusal says where to go"         yes "$(node_request POST /setup/complete '{}' "$NTOK" | jq -r '.message' 2>/dev/null | grep -q "open the hub's dashboard" && echo yes || echo no)"
check "node: the hub's session is untouched by the test's" true "$(auth_request GET "/fleet/members/$NID/api/stacks" | body_of | jq -r '.stacks | type == "array"' 2>/dev/null)"
# removed on the hub, the node is left with no account at all: only a new join can manage it again
check "node: the hub removes it"                   true "$(auth_request DELETE "/fleet/members/$NID" | body_of | jq -r '.success' 2>/dev/null)"
check "node: …and its account is gone"             0 "$(jq 'length' "$NWORK/.api-auth/users.json" 2>/dev/null)"
check "node: …so nothing signs in now"             403 "$(node_status POST /auth/login '{"username":"dcs-hub","password":"x"}')"
(cd "$NWORK" && "$NWORK/.scripts/api-server.sh" --stop >/dev/null 2>&1)
timeout 10 bash -c "while curl -s -m 1 http://127.0.0.1:$NODE_PORT/ping >/dev/null 2>&1; do sleep 0.3; done" 2>/dev/null
check "fleet: CLI join code"            yes "$(cd "$WORK" && "$API" --join-token 2 2>/dev/null | grep -q '^Join code: [A-Z2-9]\{4\}-' && echo yes || echo no)"
check "fleet: CLI status is JSON"       true "$(cd "$WORK" && "$API" --fleet-status 2>/dev/null | jq -e 'has("members")' 2>/dev/null)"
check "fleet: revoke code"              200 "$(auth_request DELETE "/fleet/join-tokens/$JT" | status_of)"
check "fleet: revoked code gone"        no "$(auth_request GET /fleet/join-tokens | body_of | jq -e --arg t "$JT" '.tokens[] | select(.token == $t)' >/dev/null 2>&1 && echo yes || echo no)"

echo "Fleet: the hub builds a VM for a stack (mock Proxmox, an ssh stand-in runs the real unattended setup)"
PROV_PORT=$(_rport); [[ "$PROV_PORT" == "$HUB_PORT" || "$PROV_PORT" == "$FLEET_PORT" ]] && PROV_PORT=$(( PROV_PORT + 3 ))
VMWORK="$WORK-vm"
cat > "$WORK/ssh-shim.sh" <<'SHIM'
#!/bin/bash
# ssh stand-in: "… dcs@IP true" answers at once; the bootstrap command (script on stdin) runs the node bootstrap here —
# a fresh copy of the repository and the real setup.sh, unattended and as a node (the API alone), on the port the hub chose.
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
    DCS_UNATTENDED=true DCS_NO_UI=true DCS_FLEET_ROLE=member DCS_ROLE="${DCS_ROLE:-node}" DCS_API_PORT="$port" DCS_API_BIND="$host" ./setup.sh 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'FAIL|WARN|Unattended|Joined|Join|Setup complete|API:|node' | tail -12
    exit "${PIPESTATUS[0]}"
    ;;
  *"tar -xzf -"*)
    # the stack moving in: the VM's install dir is the stand-in's clone
    cmd="${*//\~\/.Docker-Compose-Skeleton-AIO/$SHIM_DIR}"; bash -c "$cmd" ;;
  *dcs-relink*)
    # the hub taking a VM back: the lock lifted, the VM joined again (a marker file makes the hub's key fail)
    [[ -e "$SHIM_DIR/relink-fail" ]] && exit 255
    echo "lock on 127.0.0.1 lifted"; echo "✓ Joined: member"; exit 0 ;;
  *authorized_keys*)
    # a key put on a VM, or taken off: the stand-in VM's home is a folder of its own
    mkdir -p "$SHIM_DIR/home"; cmd="${*//\~\//$SHIM_DIR/home/}"; bash -c "$cmd" ;;
  *) echo "stand-in: unknown command: $*" >&2; exit 1 ;;
esac
SHIM
chmod +x "$WORK/ssh-shim.sh"
_envset FLEET_SSH_CMD "$WORK/ssh-shim.sh"; _envset FLEET_SELF_URL "http://127.0.0.1:$HUB_PORT"; _envset FLEET_MEMBER_PORT "$PROV_PORT"; _envset FLEET_SSH_DIR "$WORK/.data/fleet-ssh"
export SHIM_ROOT="$ROOT" SHIM_DIR="$VMWORK"
_fleet_stop_listeners() { for d in "$WORK" "$MWORK" "$NWORK" "$VMWORK"; do [[ -f "$d/.data/api-server.pid" ]] && (cd "$d" && "$d/.scripts/api-server.sh" --stop >/dev/null 2>&1); done; return 0; }
trap '_fleet_stop_listeners; rm -rf "$WORK" "$MWORK" "$PWORK" "$NWORK" "$VMWORK"' EXIT
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
check "storage: an older member's sizes in bytes" '{"device":"/dev/sda3","mount":"/","fstype":"","total":1610612736,"used":536870912,"avail":1099511627776}' "$(_lib eval 'jq -nc "$_storage_bytes_jq"" {device: \"/dev/sda3\", mount: \"/\", total: \"1.5G\", used: \"512M\", available: \"1T\"} | drive"')"
# --- graphics cards: AMD read from the amdgpu sysfs files, Intel by name, NVIDIA from nvidia-smi (its sysfs card not listed twice)
_G="$WORK/gpu"
mkdir -p "$_G/devices/0000:00:02.0/drm/renderD128" "$_G/devices/0000:03:00.0/drm/renderD129" "$_G/devices/0000:03:00.0/power" "$_G/devices/0000:03:00.0/hwmon/hwmon3" "$_G/drm/card1-HDMI-A-1"
echo 0x8086 > "$_G/devices/0000:00:02.0/vendor"
_GA="$_G/devices/0000:03:00.0"; printf '%s\n' 0x1002 > "$_GA/vendor"; echo 0x73bf > "$_GA/device"; echo 0xc1 > "$_GA/revision"; echo 37 > "$_GA/gpu_busy_percent"
echo 1073741824 > "$_GA/mem_info_vram_used"; echo 17163091968 > "$_GA/mem_info_vram_total"; echo active > "$_GA/power/runtime_status"
for _kv in temp1_input=45000 temp2_input=52000 fan1_input=1200 pwm1=102 pwm1_max=255 power1_average=31500000 power1_cap=255000000; do echo "${_kv#*=}" > "$_GA/hwmon/hwmon3/${_kv%%=*}"; done
mkdir -p "$_G/drm/card0" "$_G/drm/card1" && ln -sfn ../../devices/0000:00:02.0 "$_G/drm/card0/device" && ln -sfn ../../devices/0000:03:00.0 "$_G/drm/card1/device"
printf '73BF,\tC0,\tAMD Radeon RX 6900 XT\n73BF,\tC1,\tAMD Radeon RX 6800 XT\n' > "$_G/amdgpu.ids"
mkdir -p "$_G/bin" "$_G/nv"
printf '%s\n' '#!/bin/bash' '[[ "$*" == *00:02.0* ]] && printf "Slot:\t00:02.0\nDevice:\tCoffeeLake-S GT2 [UHD Graphics 630]\n"' '[[ "$*" == *01:00.0* ]] && printf "Slot:\t01:00.0\nDevice:\tGM204 [GeForce GTX 970]\n"' 'exit 0' > "$_G/bin/lspci"
printf '%s\n' '#!/bin/bash' 'echo "NVIDIA GeForce GTX 970, 00000000:01:00.0, 12, 512, 4096, 40, 30, 25.31, 170.00"' > "$_G/nv/nvidia-smi"; chmod +x "$_G/bin/lspci" "$_G/nv/nvidia-smi"
_gpus() { PATH="$_G/bin:${_GPATH:-}$PATH" DCS_SYSFS_DRM="$_G/drm" DCS_AMDGPU_IDS="$_G/amdgpu.ids" _lib eval "$1" | jq -c "$2" 2>/dev/null; }
check "gpus: the AMD card first, then the Intel chip; a screen connector is not a card" '["amd","intel"]' "$(_gpus _gpu_list 'map(.vendor)')"
check "gpus: the AMD card named from amdgpu.ids (device + revision)" '"AMD Radeon RX 6800 XT"' "$(_gpus _gpu_list '.[0].name')"
check "gpus: the AMD readings" '[37,1024,16368,45,52,40,1200,31.5,255,"renderD129",false]' "$(_gpus _gpu_list '.[0] | [.utilization, .memory_used_mb, .memory_total_mb, .temperature, .temperature_hotspot, .fan_speed, .fan_rpm, .power_w, .power_cap_w, .render, .asleep]')"
check "gpus: the Intel chip by name, no readings" '["Intel UHD Graphics 630",null,"renderD128"]' "$(_gpus _gpu_list '.[1] | [.name, .utilization, .render]')"
echo suspended > "$_GA/power/runtime_status"
check "gpus: a sleeping AMD card is idle and not woken (memory still read)" '[true,0,1024,null,null]' "$(_gpus _gpu_list '.[0] | [.asleep, .utilization, .memory_used_mb, .temperature, .power_w]')"
echo active > "$_GA/power/runtime_status"
mkdir -p "$_G/devices/0000:01:00.0/drm/renderD130" && echo 0x10de > "$_G/devices/0000:01:00.0/vendor" && mkdir -p "$_G/drm/card2" && ln -sfn ../../devices/0000:01:00.0 "$_G/drm/card2/device"
check "gpus: an NVIDIA card without its driver is listed by name" '"NVIDIA GeForce GTX 970 (no driver)"' "$(_gpus _gpu_list 'map(select(.vendor == "nvidia")) | .[0].name')"
_GPATH="$_G/nv:"
check "gpus: nvidia-smi's card once, with its readings, ahead of the rest" '[["nvidia","amd","intel"],[12,512,4096,40,30,25.3,170,"0000:01:00.0"]]' "$(_gpus _gpu_list '[map(.vendor), (.[0] | [.utilization, .memory_used_mb, .memory_total_mb, .temperature, .fan_speed, .power_w, .power_cap_w, .slot])]')"
_GPATH=""; rm -rf "$_G/drm/card2"
check "gpus: /feed/summary's gpu is the busiest card, gpus lists all" '["AMD Radeon RX 6800 XT",37,2]' "$(_gpus "_api_success() { printf '%s' \"\$1\"; }; handle_feed_summary" '.system | [.gpu.name, .gpu.percent, (.gpus | length)]')"
check "gpus: no card, no gpu" '[null,[]]' "$(DCS_SYSFS_DRM="$WORK/nowhere" _lib eval "PATH=/usr/bin:/bin; _api_success() { printf '%s' \"\$1\"; }; handle_feed_summary" | jq -c '.system | [.gpu, .gpus]' 2>/dev/null)"
# --- a template's services get the card picked on the deploy sheet (template.json "gpu")
_TC='services:
  ollama:
    image: ollama/ollama:latest
    restart: unless-stopped
  web:
    image: nginx:alpine
volumes:
  ollama:'
_GS='[{"service":"ollama","use":"compute","images":{"amd":"ollama/ollama:rocm"}}]'
_gpa() { PATH="$_G/bin:${_GPATH:-}$PATH" DCS_SYSFS_DRM="$_G/drm" DCS_AMDGPU_IDS="$_G/amdgpu.ids" _lib _template_gpu_apply "$1" "$2" "$3"; }
_GA_OUT=$(_gpa "$_TC" "$_GS" 0000:03:00.0)
check "gpu deploy: AMD compute gets the render node and /dev/kfd" "- /dev/dri/renderD129:/dev/dri/renderD129|- /dev/kfd:/dev/kfd" "$(printf '%s\n' "$_GA_OUT" | grep -E '^      - /dev/' | sed 's/^ *//' | paste -sd'|')"
check "gpu deploy: the ROCm image for AMD" "image: ollama/ollama:rocm" "$(printf '%s\n' "$_GA_OUT" | awk '/^  ollama:/{f=1} /^  web:/{f=0} f && /image:/{sub(/^ */,""); print}')"
check "gpu deploy: the host's video and render groups" yes "$(printf '%s\n' "$_GA_OUT" | grep -q '^    group_add:' && echo yes || echo no)"
check "gpu deploy: another service and a volume of the same name are left alone" "image: nginx:alpine|  ollama:" "$(printf '%s\n' "$_GA_OUT" | sed -n '/^  web:/,$p' | grep -E 'image:|^  ollama:' | sed 's/^    //' | paste -sd'|')"
check "gpu deploy: Intel video gets its render node only" "- /dev/dri/renderD128:/dev/dri/renderD128" "$(_gpa "$_TC" '[{"service":"ollama","use":"video"}]' 0000:00:02.0 | grep -E '^      - /dev/' | sed 's/^ *//' | paste -sd'|')"
_TC2='services:
  ollama:
    image: ollama/ollama:latest
    devices:
      - /dev/kfd:/dev/kfd
      - /dev/ttyUSB0:/dev/ttyUSB0'
check "gpu deploy: a devices list is added to, nothing twice" "- /dev/dri/renderD129:/dev/dri/renderD129|- /dev/kfd:/dev/kfd|- /dev/ttyUSB0:/dev/ttyUSB0" "$(_gpa "$_TC2" "$_GS" 0000:03:00.0 | grep -E '^      - /dev/' | sed 's/^ *//' | paste -sd'|')"
check "gpu deploy: an unknown card is refused, and says why" "1 __error=There is no graphics card at 0000:99:00.0 on this server" "$(_o=$(_gpa "$_TC" "$_GS" 0000:99:00.0); echo "$? $_o")"
mkdir -p "$_G/devices/0000:01:00.0/drm/renderD130" && echo 0x10de > "$_G/devices/0000:01:00.0/vendor" && mkdir -p "$_G/drm/card2" && ln -sfn ../../devices/0000:01:00.0 "$_G/drm/card2/device"
_GPATH="$_G/nv:"
_GN_OUT=$(_gpa "$_TC" '[{"service":"ollama","use":"video"}]' 0000:01:00.0)
check "gpu deploy: NVIDIA gets a reservation with video, no devices or groups" "driver: nvidia|capabilities: [gpu, compute, utility, video]|0" "$(printf '%s\n' "$_GN_OUT" | grep -oE 'driver: nvidia|capabilities: \[[^]]*\]' | paste -sd'|')|$(printf '%s\n' "$_GN_OUT" | grep -cE '^    (devices|group_add):')"
check "gpu deploy: NVIDIA keeps the image when the template names none for it" "image: ollama/ollama:latest" "$(printf '%s\n' "$_GN_OUT" | awk '/^  ollama:/{f=1} /^  web:/{f=0} f && /image:/{sub(/^ */,""); print}')"
_GPATH=""; rm -rf "$_G/drm/card2"
# --- UPS through apcupsd: a lost UPS (COMMLOST) is a problem with its cause, not "on mains"
_P="$WORK/apc"; mkdir -p "$_P/bin" "$_P/usb/devices/2-1"
printf '%s\n' '#!/bin/bash' 'printf "UPSNAME  : ups\nCABLE    : USB Cable\nSTATUS   : %s\n" "${FAKE_APC_STATUS:-ONLINE}"' '[[ "${FAKE_APC_STATUS:-ONLINE}" == ONLINE ]] && printf "MODEL    : Back-UPS ES 600M1\nBCHARGE  : 100.0 Percent\nTIMELEFT : 4.9 Minutes\nLOADPCT  : 52.0 Percent\nLINEV    : 120.0 Volts\n"' 'exit 0' > "$_P/bin/apcaccess"; chmod +x "$_P/bin/apcaccess"
printf 'UPSCABLE usb\nUPSTYPE usb\nDEVICE\n' > "$_P/ok.conf"; printf 'UPSCABLE usb\nUPSTYPE usb\nDEVICE /dev/ttyS0\n' > "$_P/serial.conf"
_apc() { PATH="$_P/bin:$PATH" UPS_SOURCE=apcupsd FAKE_APC_STATUS="$1" DCS_SYSFS_USB="$2" UPS_APCUPSD_CONF="$3" DCS_VIRT="${4:-none}" _lib _power_sample | jq -c "$5" 2>/dev/null; }
check "ups: apcupsd online reads charge, runtime, load, model" '[true,"ONLINE",100,294,52,"Back-UPS ES 600M1",false]' "$(_apc ONLINE "$_P/usb" "$_P/ok.conf" none '[.ok, .status, .charge, .runtime_seconds, .load, .model, .on_battery]')"
check "ups: COMMLOST is not ok" '[false,"COMMLOST"]' "$(_apc COMMLOST "$_P/usb" "$_P/ok.conf" none '[.ok, .status]')"
check "ups: COMMLOST on a kernel without USB says so" true "$(_apc COMMLOST "$_P/nousb" "$_P/ok.conf" none '.error | test("no USB drivers")')"
check "ups: COMMLOST with a serial DEVICE for a USB UPS names the line" true "$(_apc COMMLOST "$_P/usb" "$_P/serial.conf" none '.error | test("DEVICE /dev/ttyS0")')"
check "ups: COMMLOST on a VM without the UPS on its USB says pass it through" true "$(_apc COMMLOST "$_P/usb" "$_P/ok.conf" kvm '.error | test("virtual machine.*pass it through")')"
check "ups: COMMLOST on a machine without the UPS on its USB says check the cable" true "$(_apc COMMLOST "$_P/usb" "$_P/ok.conf" none '.error | test("check the cable")')"
echo 051d > "$_P/usb/devices/2-1/idVendor"
check "ups: COMMLOST with the UPS on USB says restart apcupsd" true "$(_apc COMMLOST "$_P/usb" "$_P/ok.conf" none '.error | test("restart apcupsd")')"
# --- a VM from an older DCS image: the kernel hooks and ext4 are added once, nothing else is touched
_IR="$WORK/imgroot"; mkdir -p "$_IR/usr/local/sbin" "$_IR/etc/initramfs-tools" "$_IR/etc/kernel/postinst.d"
printf '#!/bin/bash\n' > "$_IR/usr/local/sbin/dcs-grubcfg"; chmod +x "$_IR/usr/local/sbin/dcs-grubcfg"
: > "$_IR/etc/initramfs-tools/initramfs.conf"; printf '# disk\nvirtio_scsi\nvirtio_blk\nsd_mod\n' > "$_IR/etc/initramfs-tools/modules"
check "image repair: says what it added" "  DCS image boot repair: kernel postinst.d hook kernel postrm.d hook ext4 in the initramfs" "$(DCS_IMAGE_ROOT="$_IR" _lib _image_boot_repair)"
check "image repair: both hooks run dcs-grubcfg" "exec /usr/local/sbin/dcs-grubcfg >&2|exec /usr/local/sbin/dcs-grubcfg >&2" "$(grep -h '^exec' "$_IR/etc/kernel/postinst.d/zz-dcs-grubcfg" "$_IR/etc/kernel/postrm.d/zz-dcs-grubcfg" | paste -sd'|')"
check "image repair: the hooks are executable" yes "$([[ -x "$_IR/etc/kernel/postinst.d/zz-dcs-grubcfg" && -x "$_IR/etc/kernel/postrm.d/zz-dcs-grubcfg" ]] && echo yes || echo no)"
check "image repair: ext4 once, the old lines kept" "virtio_scsi virtio_blk sd_mod ext4" "$(grep -v '^#' "$_IR/etc/initramfs-tools/modules" | paste -sd' ')"
check "image repair: a second start changes nothing" "" "$(DCS_IMAGE_ROOT="$_IR" _lib _image_boot_repair)"
mkdir -p "$WORK/notimg/etc/initramfs-tools"; : > "$WORK/notimg/etc/initramfs-tools/initramfs.conf"
check "image repair: not a DCS image, nothing done" "|no" "$(DCS_IMAGE_ROOT="$WORK/notimg" _lib _image_boot_repair)|$([[ -e "$WORK/notimg/etc/kernel" ]] && echo yes || echo no)"
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
# moving a stack of the hub into a VM with what it holds: the pieces a move is made of
mkdir -p "$WORK/Stacks/zz-move/App-Data/sub" "$WORK/Stacks/zz-move/data" "$WORK/mv-out"; ln -sfn /nonexistent "$WORK/Stacks/zz-move/VM-App-Data"
printf 'one\n' > "$WORK/Stacks/zz-move/App-Data/a.txt"; printf 'two\n' > "$WORK/Stacks/zz-move/App-Data/sub/b.txt"; chmod 640 "$WORK/Stacks/zz-move/App-Data/sub/b.txt"
printf 'services:\n  m:\n    image: alpine:3\n    volumes:\n      - ./App-Data:/x\n      - /mnt/media:/media:ro\n      - /var/run/docker.sock:/var/run/docker.sock:ro\n' > "$WORK/Stacks/zz-move/docker-compose.yml"
check "move: the data folders of a stack"          "App-Data data" "$(_lib _fleet_stack_data_dirs zz-move | tr '\n' ' ' | sed 's/ $//')"
check "move: a folder's size and count"            yes "$([[ "$(FLEET_READER=plain _lib _fleet_dir_stat "$WORK/Stacks/zz-move/App-Data")" =~ ^[0-9]+\ 2$ ]] && echo yes || echo no)"
FLEET_READER=plain _lib _fleet_dir_tar "$WORK/Stacks/zz-move/App-Data" | tar -xpf - -C "$WORK/mv-out"
check "move: the copy holds every file as it was"  "one 640" "$(printf '%s %s' "$(cat "$WORK/mv-out/a.txt")" "$(stat -c %a "$WORK/mv-out/sub/b.txt")")"
check "move: folders outside the stack are named"  /mnt/media "$(_lib _fleet_stack_outside_paths zz-move | tr '\n' ' ' | sed 's/ $//')"
_MC=$(auth_request GET '/fleet/provision/move-check?stack=zz-move' | body_of)
check "move-check: answers"                        'zz-move 2 /mnt/media' "$(jq -r '"\(.stack) \(.files) \(.outside_paths | join(","))"' <<< "$_MC" 2>/dev/null)"
check "move-check: names the folders"              'App-Data data' "$(jq -r '[.folders[].name] | join(" ")' <<< "$_MC" 2>/dev/null)"
check "move-check: a disk size that holds it"      yes "$([[ "$(jq -r '.suggested_disk_gb' <<< "$_MC" 2>/dev/null)" -ge 32 ]] && echo yes || echo no)"
check "move-check: no earlier VM"                  null "$(jq -r '.earlier_vm' <<< "$_MC" 2>/dev/null)"
check "move-check: an unknown stack"               404 "$(auth_request GET '/fleet/provision/move-check?stack=zz-nope' | status_of)"
check "move-check: a viewer may not"               403 "$(viewer_request GET '/fleet/provision/move-check?stack=zz-move' | status_of)"
check "move-check: a read-only socket is no driver"   0 "$(jq -r '.docker_socket | length' <<< "$_MC" 2>/dev/null)"
check "move-check: movable"                        true "$(jq -r '.movable' <<< "$_MC" 2>/dev/null)"
# a cpus: limit above the VM's cores: Docker refuses the container, so the move asks for a VM that can hold it
printf '    cpus: 3\n' >> "$WORK/Stacks/zz-move/docker-compose.yml"
check "move-check: the cores a cpus: limit needs"  "3 m" "$(auth_request GET '/fleet/provision/move-check?stack=zz-move' | body_of | jq -r '"\(.min_cores) \(.cpu_limits[0].service)"' 2>/dev/null)"
check "move: a VM with fewer cores is refused"     yes "$(auth_request POST /fleet/provision '{"node":"pve","storage":"local-lvm","gateway":"192.0.2.1","ip_start":"192.0.2.10","vms":[{"stack":"zz-move","move":true,"cores":2}]}' | body_of | jq -r '.message' | grep -q 'at least 3 cores' && echo yes || echo no)"
check "move: the hub's own stacks never move"      "0 1" "$(_lib _fleet_hub_only core-infrastructure; a=$?; _lib _fleet_hub_only zz-move; echo "$a $?")"
check "move: a hub-only stack is a blocker"        yes "$(_lib _fleet_move_blockers networking-security | grep -q 'part of the hub' && echo yes || echo no)"
mkdir -p "$WORK/Stacks/zz-gpu"; printf 'services:\n  llm:\n    image: alpine:3\n    devices:\n      - /dev/kfd:/dev/kfd\n  tv:\n    image: alpine:3\n    deploy:\n      resources:\n        reservations:\n          devices:\n            - driver: nvidia\n              count: all\n              capabilities: [gpu]\n  zig:\n    image: alpine:3\n    devices:\n      - /dev/ttyUSB0:/dev/ttyUSB0\n' > "$WORK/Stacks/zz-gpu/docker-compose.yml"
check "move: services on the graphics card are blockers, a USB stick is not" "llm tv" "$(_lib _fleet_move_blockers zz-gpu | grep 'graphics card' | awk '{print $1}' | paste -sd' ')"
check "move: zz-move (no card) has no graphics blocker" 0 "$(_lib _fleet_move_blockers zz-move | grep -c 'graphics card')"
rm -rf "$WORK/Stacks/zz-gpu"
check "move: a move takes the stack's own name"    400 "$(auth_request POST /fleet/provision '{"node":"pve","storage":"local-lvm","gateway":"192.0.2.1","ip_start":"192.0.2.10","vms":[{"stack":"zz-move","source":"other","move":true}]}' | status_of)"
check "move: a stack that is not there"            404 "$(auth_request POST /fleet/provision '{"node":"pve","storage":"local-lvm","gateway":"192.0.2.1","ip_start":"192.0.2.10","vms":[{"stack":"zz-nope","move":true}]}' | status_of)"
_DS0=$(grep -m1 '^DOCKER_STACKS=' "$WORK/.env"); sed -i 's|^DOCKER_STACKS=.*|DOCKER_STACKS="demo zz-move demo2"|' "$WORK/.env"
_lib _fleet_move_unlist zz-move
check "move: the stack leaves the hub's list"      'DOCKER_STACKS="demo demo2"' "$(grep -m1 '^DOCKER_STACKS=' "$WORK/.env")"
sed -i "s|^DOCKER_STACKS=.*|$_DS0|" "$WORK/.env"
_MVR=$(_lib _find_traefik_routes_dir); mkdir -p "$_MVR/zz-move"; printf 'http: {}\n' > "$_MVR/zz-move/m.yml"
check "move: the hub has a routes dir"             yes "$([[ -d "$_MVR" ]] && echo yes || echo no)"
_lib _fleet_move_retire_routes nojob zz-move
check "move: the hub's route files are set aside"  'yes no' "$(printf '%s %s' "$(compgen -G "$WORK/.data/moved-routes/zz-move-*/m.yml" >/dev/null && echo yes || echo no)" "$([[ -d "$_MVR/zz-move" ]] && echo yes || echo no)")"
command rm -rf "$WORK/Stacks/zz-move" "$WORK/mv-out" "$WORK/.data/moved-routes"
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
# a build that failed says where (in the run's log, where the reason would otherwise be lost with the work folder)
[[ "$_JST" == "done" ]] || echo "       the job: $(auth_request GET "/fleet/jobs/$JOB" | body_of | jq -c 'del(.steps)' 2>/dev/null | cut -c1-2500)"
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
# ssh into the VMs with a key of your own: made after the password, put on the VMs ticked, never kept, taken away again
_SSHH="$VMWORK/home/.ssh/authorized_keys"
check "ssh: the sheet lists the VMs and the hub"       'smoke-photos 22 dcs' "$(auth_request GET /ssh/access | body_of | jq -r '"\(.vms[0].name) \(.hub.port) \(.vm_user)"' 2>/dev/null)"
check "ssh: a viewer sees nothing"                     403 "$(viewer_request GET /ssh/access | status_of)"
check "ssh: a name is needed"                          400 "$(auth_request POST /ssh/keys '{"name":"","members":["smoke-photos"],"password":"x"}' | status_of)"
check "ssh: a VM is needed"                            400 "$(auth_request POST /ssh/keys '{"name":"laptop","members":[],"password":"x"}' | status_of)"
check "ssh: the password is needed"                    400 "$(auth_request POST /ssh/keys '{"name":"laptop","members":["smoke-photos"]}' | status_of)"
check "ssh: a wrong password gets no key"              401 "$(auth_request POST /ssh/keys '{"name":"laptop","members":["smoke-photos"],"password":"not-it-at-all"}' | status_of)"
check "ssh: …and nothing was put on the VM"            no "$([[ -s "$_SSHH" ]] && echo yes || echo no)"
check "ssh: a VM that does not exist"                  404 "$(auth_request POST /ssh/keys '{"name":"laptop","members":["nope"],"password":"correct horse battery"}' | status_of)"
_SK=$(auth_request POST /ssh/keys '{"name":"laptop","members":["smoke-photos"],"password":"correct horse battery","via":"hub","hub_host":"hub.example.test"}' | body_of)
_SKID=$(jq -r '.id // empty' <<< "$_SK" 2>/dev/null)
check "ssh: made, with the private half"               yes "$([[ "$(jq -r '.private_key' <<< "$_SK" 2>/dev/null)" == "-----BEGIN OPENSSH PRIVATE KEY-----"* ]] && echo yes || echo no)"
check "ssh: the public half is on the VM"              1 "$(grep -c "dcs-ssh:$_SKID\$" "$_SSHH" 2>/dev/null)"
check "ssh: the VM took it"                            true "$(jq -r '.results[0].ok' <<< "$_SK" 2>/dev/null)"
_SKC=$(jq -r '.config' <<< "$_SK" 2>/dev/null)
check "ssh: the config names the VM and jumps through the hub" yes "$({ grep -q '^Host smoke-photos$' <<< "$_SKC" && grep -q 'ProxyJump dcs-hub' <<< "$_SKC" && grep -q 'HostName hub.example.test' <<< "$_SKC"; } && echo yes || echo no)"
check "ssh: the config names the key's file"           yes "$(jq -r '.config' <<< "$_SK" 2>/dev/null | grep -q 'IdentityFile ~/.ssh/dcs-laptop$' && echo yes || echo no)"
check "ssh: the hub keeps no private half"             0 "$(grep -rlE 'BEGIN OPENSSH PRIVATE KEY' "$WORK/.data/ssh-keys.json" 2>/dev/null | wc -l)"
check "ssh: the list shows it without the keys"        'laptop false' "$(auth_request GET /ssh/access | body_of | jq -r '.keys[0] | "\(.name) \(has("public") or has("private_key"))"' 2>/dev/null)"
check "ssh: the same name twice"                       409 "$(auth_request POST /ssh/keys '{"name":"laptop","members":["smoke-photos"],"password":"correct horse battery"}' | status_of)"
check "ssh: the config again, direct"                  0 "$(auth_request GET "/ssh/keys/$_SKID/config?via=direct" | body_of | jq -r '.config' 2>/dev/null | grep -c 'ProxyJump')"
check "ssh: a key id is checked"                       400 "$(auth_request DELETE '/ssh/keys/../../x' | status_of)"
check "ssh: removed"                                   200 "$(auth_request DELETE "/ssh/keys/$_SKID" | status_of)"
check "ssh: …and gone from the VM"                     0 "$(grep -c "dcs-ssh:$_SKID" "$_SSHH" 2>/dev/null)"
# relinking a VM whose password the hub lost: the VM joins again over the hub's ssh key; the hub keeps what it knew
check "relink: a viewer cannot"                        403 "$(viewer_request POST /fleet/members/smoke-photos/relink | status_of)"
check "relink: a member that does not exist"           404 "$(auth_request POST /fleet/members/nope/relink | status_of)"
check "relink: done"                                   200 "$(auth_request POST /fleet/members/smoke-photos/relink | status_of)"
check "relink: it keeps what the hub knew of it"       true "$(auth_request GET /fleet/members | body_of | jq -r '.members[] | select(.name == "smoke-photos") | .provisioned' 2>/dev/null)"
_RLT=$(jq -r '(.join_tokens // []) | length' "$WORK/.data/fleet.json" 2>/dev/null)
touch "$SHIM_DIR/relink-fail"
_RL=$(auth_request POST /fleet/members/smoke-photos/relink | body_of)
check "relink: no ssh key, the hub says what to run"   yes "$(jq -r '.message' <<< "$_RL" 2>/dev/null | grep -q -- '--join-hub' && echo yes || echo no)"
check "relink: …and leaves no join code behind"        "$_RLT" "$(jq -r '(.join_tokens // []) | length' "$WORK/.data/fleet.json" 2>/dev/null)"
rm -f "$SHIM_DIR/relink-fail"
check "provision: secret copy logged"   yes "$(auth_request GET "/fleet/jobs/$JOB" | body_of | jq -r '.log[].text' 2>/dev/null | grep -q 'secret(s) the stack uses copied' && echo yes || echo no)"
# the hub's own start.sh never starts a folder that lives in a VM, whatever DOCKER_STACKS says
# shellcheck disable=SC2034  # COMPOSE_DIR is read by the function pulled out of run.sh
_owned() { ( COMPOSE_DIR="$WORK/Stacks"; eval "$(sed -n '/^_fleet_owned_stack()/,/^}/p' "$ROOT/.scripts/run.sh")"; _fleet_owned_stack "$1"; echo $? ); }
check "start.sh: a VM's stack is not the hub's to start" 0 "$(_owned smoke-photos)"
check "start.sh: the hub's own stack is"    1 "$(_owned demo)"
check "provision: member marked built"  true "$(auth_request GET /fleet/members | body_of | jq -r '.members[] | select(.name == "smoke-photos") | .provisioned' 2>/dev/null)"
check "provision: no admin password minted (the VM is a node)" no "$(_lib secrets_exists FLEET_MEMBER_SMOKE_PHOTOS_ADMIN_PASSWORD && echo yes || echo no)"
check "provision: audited"              yes "$(grep -q 'fleet_vm_ready' "$WORK/.data/audit.jsonl" 2>/dev/null && echo yes || echo no)"
check "provision: the VM knows its role" member "$(grep -m1 '^FLEET_ROLE=' "$VMWORK/.env" 2>/dev/null | cut -d= -f2)"
check "provision: …and that it is a node" node "$(grep -m1 '^DCS_ROLE=' "$VMWORK/.env" 2>/dev/null | cut -d= -f2)"
check "provision: the VM carries its one stack" '"smoke-photos"' "$(grep -m1 '^DOCKER_STACKS=' "$VMWORK/.env" 2>/dev/null | cut -d= -f2-)"
_MADM=$(auth_request GET /fleet/members | body_of | jq -r '.members[] | select(.name == "smoke-photos") | .url' 2>/dev/null)
check "node: nothing to set up, the hub named" "true node http://127.0.0.1:$HUB_PORT" "$(curl -s -m 5 "$_MADM/setup/status" | jq -r '"\(.initialized) \(.role) \(.hub.url)"' 2>/dev/null)"
check "node: only the hub's account on the VM" dcs-hub "$(jq -r 'map(.username) | join(" ")' "$VMWORK/.api-auth/users.json" 2>/dev/null)"
check "node: API only, one stack (through the hub)" smoke-photos "$(auth_request GET /fleet/members/smoke-photos/api/stacks | body_of | jq -r '.stacks | map(.name) | join(",")' 2>/dev/null)"
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
_ICODE=$(auth_request GET "/fleet/jobs/$IJOB" | body_of | jq -r '.join_token // ""' 2>/dev/null)
check "iso build: the one line in the log" yes "$(auth_request GET "/fleet/jobs/$IJOB" | body_of | jq -r '.log[].text' 2>/dev/null | grep -q "curl -fsSL 'http://.*/fleet/bootstrap?token=$_ICODE' | bash" && echo yes || echo no)"
check "iso build: its code's installer names the stack" yes "$(request GET "/fleet/bootstrap?token=$_ICODE" '' "${AUTH[@]}" | body_of | grep -q '^export DCS_STACKS=by-hand-box DCS_MEMBER_NAME=by-hand-box$' && echo yes || echo no)"
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
trap '(cd "$VMWORK/Stacks/smoke-photos" 2>/dev/null && docker compose -p smoke-photos down --remove-orphans >/dev/null 2>&1); rm -rf "$WORK" "$MWORK" "$PWORK" "$NWORK" "$VMWORK"' EXIT

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
# the dashboard feed: what a dashboard that cannot sign in may read. Off until a token exists; the token is made by an admin
check "dash feed: off by default"       401 "$(request GET '/feed/summary?token=x' '' "${AUTH[@]}" | status_of)"
check "dash feed: status says off"      false "$(auth_request GET /feed/status | body_of | jq -r '.enabled' 2>/dev/null)"
_DFT=$(auth_request POST /feed/token '{}' | body_of | jq -r '.token // ""' 2>/dev/null)
check "dash feed: a token is made"      yes "$([[ ${#_DFT} -ge 32 ]] && echo yes || echo no)"
check "dash feed: the token is in .env" yes "$(grep -q "^DASHBOARD_FEED_TOKEN=.*${_DFT}" "$WORK/.env" && echo yes || echo no)"
check "dash feed: wrong token"          401 "$(request GET '/feed/summary?token=nope' '' "${AUTH[@]}" | status_of)"
check "dash feed: no token"             401 "$(request GET '/feed/summary' '' "${AUTH[@]}" | status_of)"
_DFS=$(request GET "/feed/summary?token=$_DFT" '' "${AUTH[@]}")
check "dash feed: summary with the token" 200 "$(status_of <<< "$_DFS")"
check "dash feed: summary has the version" yes "$(body_of <<< "$_DFS" | jq -e '(.version | type == "string") and (.containers.total | type == "number") and (.stacks | type == "array")' >/dev/null 2>&1 && echo yes || echo no)"
check "dash feed: summary has the machine's load" yes "$(body_of <<< "$_DFS" | jq -e '(.system.cpu.percent | type == "number") and (.system.cpu.percent >= 0 and .system.cpu.percent <= 100) and (.system.memory.total_mb > 0) and (.system.cpu.threads > 0)' >/dev/null 2>&1 && echo yes || echo no)"
check "dash feed: …and the disk" yes "$(body_of <<< "$_DFS" | jq -e '(.system.disk.percent | type == "number") and (.system.disk.total | type == "string")' >/dev/null 2>&1 && echo yes || echo no)"
check "dash feed: Bearer works too"     200 "$(printf 'GET /feed/summary HTTP/1.1\r\nAuthorization: Bearer %s\r\n\r\n' "$_DFT" | env "${AUTH[@]}" "$API" --handle-request 2>/dev/null | status_of)"
check "dash feed: the token opens nothing else" 401 "$(printf 'GET /stacks HTTP/1.1\r\nAuthorization: Bearer %s\r\n\r\n' "$_DFT" | env "${AUTH[@]}" "$API" --handle-request 2>/dev/null | status_of)"
check "dash feed: crowdsec needs the token" 401 "$(request GET '/feed/crowdsec' '' "${AUTH[@]}" | status_of)"
check "dash feed: a viewer cannot make a token" 403 "$(printf 'POST /feed/token HTTP/1.1\r\nAuthorization: Bearer %s\r\nContent-Length: 2\r\n\r\n{}' "${VTOKEN:-none}" | env "${AUTH[@]}" "$API" --handle-request 2>/dev/null | status_of)"
check "dash feed: switched off"         true "$(auth_request DELETE /feed/token | body_of | jq -r '.success' 2>/dev/null)"
check "dash feed: the old token is dead" 401 "$(request GET "/feed/summary?token=$_DFT" '' "${AUTH[@]}" | status_of)"
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
# every built-in template passes the scan a deploy runs on it (its variables at their defaults): a rule that is too
# wide makes a template in the gallery one nobody can deploy (the /dev rule refused every device: a VPN's tunnel,
# a Zigbee stick, a UPS on USB)
_tpl_scan() {
    local d f c k v
    for d in "$ROOT"/.templates/*/; do
        f="$d/docker-compose.yml"; [[ -f "$f" ]] || continue
        c=$(cat "$f")
        if [[ -f "$d/template.json" ]]; then
            while IFS=$'\t' read -r k v; do
                [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
                v="${v//[&|\\]/}"
                c=$(printf '%s' "$c" | sed -E "s|\\\$\\{$k(:-[^}]*)?\\}|$v|g")
            done < <(jq -r '.variables[]? | select(.name != null) | [.name, ((.default // "") | tostring)] | @tsv' "$d/template.json" 2>/dev/null)
        fi
        c=$(printf '%s' "$c" | sed -E 's/\$\{[A-Za-z_][A-Za-z0-9_]*:-([^}]*)\}/\1/g' | sed '/^\s*privileged:\s*/d')
        c=$(_template_host_access_strip "$c" "$d/template.json")     # the host access the template declares, as the deploy does
        _API_SCAN_QUIET=true _api_scan_compose_security "$c" "smoke" deploy >/dev/null 2>&1 || printf '%s ' "$(basename "$d")"
    done
}
check "templates: every built-in one passes the deploy scan" "" "$(set --; source "$API" >/dev/null 2>&1; _tpl_scan 2>/dev/null)"
_scan_dev() { local _mode="$1" _key="$2" _val="$3"; ( set --; source "$API" >/dev/null 2>&1; _API_SCAN_QUIET=true _api_scan_compose_security "$(printf 'services:\n  a:\n    image: x\n    %s:\n      - %s\n' "$_key" "$_val")" smoke "$_mode" >/dev/null 2>&1 && echo 0 || echo 1 ); }
# host access is waved through only for what the template itself declares, and never a writable mount of /
_ha_tpl="$WORK/ha-tpl.json"
_ha_scan() { local _m="$2"; printf '%s' "$1" > "$_ha_tpl"; ( set --; source "$API" >/dev/null 2>&1; c=$(_template_host_access_strip "$(printf 'services:\n  a:\n    image: x\n    network_mode: host\n    pid: host\n    volumes:\n      - %s\n' "$_m")" "$_ha_tpl"); _API_SCAN_QUIET=true _api_scan_compose_security "$c" smoke deploy 2>&1 | tr '\n' ' ' ); }
_ha_none=$(_ha_scan '{}' '/:/host:ro')
check "host access: nothing declared, everything refused" yes "$([[ "$_ha_none" == *"host network"* && "$_ha_none" == *"host PID"* && "$_ha_none" == *"root filesystem"* ]] && echo yes || echo no)"
check "host access: what is declared passes"            "" "$(_ha_scan '{"host_access":["network","pid","root-ro"]}' '/:/host:ro,rslave')"
check "host access: only what is declared"              yes "$([[ "$(_ha_scan '{"host_access":["network"]}' '/:/host:ro')" == *"host PID"* ]] && echo yes || echo no)"
check "host access: never a writable /"                 yes "$([[ "$(_ha_scan '{"host_access":["network","pid","root-ro"]}' '/:/host')" == *"root filesystem"* ]] && echo yes || echo no)"
check "scan: a template may name one device"            0 "$(_scan_dev deploy devices /dev/ttyUSB0:/dev/ttyUSB0)"
check "scan: …but not the whole of /dev"                1 "$(_scan_dev deploy volumes /dev:/dev)"
check "scan: …nor the machine's memory"                 1 "$(_scan_dev deploy devices /dev/mem:/dev/mem)"
check "scan: an edited compose file still names no device" 1 "$(_scan_dev strict devices /dev/ttyUSB0:/dev/ttyUSB0)"
# API keys: for a dashboard or a script that can only send a fixed header. Made by an admin, shown once, kept as a hash;
# "read" reads what a viewer may, "operate" also does what a bot may; never an admin, never an account
key_request() { local hdr="$1" m="$2" p="$3" b="${4:-}"; printf '%s %s HTTP/1.1\r\n%s\r\nContent-Length: %d\r\n\r\n%s' "$m" "$p" "$hdr" "${#b}" "$b" | env DOCKER_COMPOSE_CMD="${DOCKER_COMPOSE_CMD:-docker compose}" "${AUTH[@]}" PATH="$WORK/fakebin:$PATH" "$API" --handle-request 2>/dev/null; }
check "api keys: a name is needed"                  400 "$(auth_request POST /auth/keys '{"name":"","role":"read"}' | status_of)"
check "api keys: only the two roles"                400 "$(auth_request POST /auth/keys '{"name":"x","role":"admin"}' | status_of)"
_AK=$(auth_request POST /auth/keys '{"name":"Homarr","role":"read"}' | body_of)
_AKR=$(jq -r '.key // empty' <<< "$_AK" 2>/dev/null); _AKRID=$(jq -r '.id // empty' <<< "$_AK" 2>/dev/null)
check "api keys: made, shown once"                  yes "$([[ "$_AKR" =~ ^dcs_[0-9a-f]{40}$ ]] && echo yes || echo no)"
check "api keys: the same name twice is refused"    409 "$(auth_request POST /auth/keys '{"name":"Homarr","role":"read"}' | status_of)"
check "api keys: only a hash is kept"               '1 0' "$(printf '%s %s' "$(jq '[.[] | select(.hash | test("^[0-9a-f]{64}$"))] | length' "$WORK/.api-auth/api-keys.json" 2>/dev/null)" "$(grep -c "$_AKR" "$WORK/.api-auth/api-keys.json")")"
check "api keys: the list never shows it again"     'Homarr read no' "$(auth_request GET /auth/keys | body_of | jq -r '.keys[0] | "\(.name) \(.role) " + (if has("key") or has("hash") then "yes" else "no" end)' 2>/dev/null)"
check "api keys: Authorization: Bearer"             200 "$(key_request "Authorization: Bearer $_AKR" GET /stacks | status_of)"
check "api keys: X-API-Key"                         200 "$(key_request "X-API-Key: $_AKR" GET /summary | status_of)"
check "api keys: the summary has the version"       yes "$(key_request "X-API-Key: $_AKR" GET /summary | body_of | jq -e '(.version | type == "string") and (.system.memory.total_mb > 0)' >/dev/null 2>&1 && echo yes || echo no)"
check "api keys: a wrong key"                       401 "$(key_request "X-API-Key: dcs_0000000000000000000000000000000000000000" GET /stacks | status_of)"
check "api keys: read reads what a viewer may"      403 "$(key_request "X-API-Key: $_AKR" GET /env | status_of)"
check "api keys: read does nothing"                 403 "$(key_request "X-API-Key: $_AKR" POST /metrics/snapshot | status_of)"
check "api keys: a key never sees the keys"         403 "$(key_request "X-API-Key: $_AKR" GET /auth/keys | status_of)"
check "api keys: …nor the accounts"                 403 "$(key_request "X-API-Key: $_AKR" GET /auth/users | status_of)"
check "api keys: a viewer sees no keys"             403 "$(viewer_request GET /auth/keys | status_of)"
check "api keys: a viewer makes none"               403 "$(viewer_request POST /auth/keys '{"name":"v","role":"read"}' | status_of)"
_AKO=$(auth_request POST /auth/keys '{"name":"Home Assistant","role":"operate","expires_days":30}' | body_of)
_AKOK=$(jq -r '.key // empty' <<< "$_AKO" 2>/dev/null); _AKOID=$(jq -r '.id // empty' <<< "$_AKO" 2>/dev/null)
check "api keys: operate may do what a bot may"     yes "$([[ "$(key_request "Authorization: Bearer $_AKOK" POST /metrics/snapshot | status_of)" != 403 ]] && echo yes || echo no)"
check "api keys: operate is no admin"               403 "$(key_request "Authorization: Bearer $_AKOK" POST /auth/users '{"username":"x","password":"long-enough-1","role":"admin"}' | status_of)"
check "api keys: operate makes no keys"             403 "$(key_request "Authorization: Bearer $_AKOK" POST /auth/keys '{"name":"more","role":"operate"}' | status_of)"
check "api keys: operate opens no terminal"         403 "$(key_request "Authorization: Bearer $_AKOK" GET /terminal/web | status_of)"
check "ssh: an API key cannot reach it"                403 "$(key_request "X-API-Key: $_AKOK" GET /ssh/access | status_of)"
check "api keys: the audit log names the key"       yes "$(grep -q 'API_KEY_CREATED.*Home Assistant' "$WORK/.api-auth/auth-audit.log" 2>/dev/null && echo yes || echo no)"
jq --arg id "$_AKOID" 'map(if .id == $id then .expires_at = 1 else . end)' "$WORK/.api-auth/api-keys.json" > "$WORK/.api-auth/api-keys.json.t" && command mv -f "$WORK/.api-auth/api-keys.json.t" "$WORK/.api-auth/api-keys.json"
check "api keys: an expired key"                    401 "$(key_request "Authorization: Bearer $_AKOK" GET /stacks | status_of)"
check "api keys: the list says expired"             true "$(auth_request GET /auth/keys | body_of | jq -r --arg id "$_AKOID" '.keys[] | select(.id == $id) | .expired' 2>/dev/null)"
check "api keys: removed"                           200 "$(auth_request DELETE "/auth/keys/$_AKRID" | status_of)"
check "api keys: a removed key is dead at once"     401 "$(key_request "X-API-Key: $_AKR" GET /stacks | status_of)"
check "api keys: an id that is not one"             400 "$(auth_request DELETE /auth/keys/../../users | status_of)"

# the web terminal: a shell on the server is never deployed without a sign-in in front of it, publishes no port, and gets a
# key of its own that leaves with it ("auth": "required" and "route_ports" in template.json)
command rm -rf "$WORK/.templates/web-terminal"; cp -r "$ROOT/.templates/web-terminal" "$WORK/.templates/web-terminal"
mkdir -p "$WORK/wt-home/.ssh" "$WORK/wt-hostkeys"; printf 'ssh-ed25519 AAAAkeepme someone@else\n' > "$WORK/wt-home/.ssh/authorized_keys"
ssh-keygen -q -t ed25519 -N '' -f "$WORK/wt-hostkeys/ssh_host_ed25519_key" >/dev/null 2>&1
wt_request() { local m="$1" p="$2" b="${3:-}"; fake_request "$m" "$p" "$b" DCS_WEB_TERMINAL_HOME="$WORK/wt-home" DCS_WEB_TERMINAL_HOSTKEYS="$WORK/wt-hostkeys"; }
_WTD="$WORK/Stacks/demo/App-Data/Web-Terminal/config"
rm -f "$WORK/fakebin/.authelia"
check "web terminal: no Authelia, no deploy"       409 "$(wt_request POST /templates/web-terminal/deploy '{"target_stack":"demo","auto_start":false}' | status_of)"
check "web terminal: …and no key was made"         no "$([[ -e "$_WTD/id_ed25519" ]] && echo yes || echo no)"
touch "$WORK/fakebin/.authelia"
check "web terminal: not without its route"        409 "$(wt_request POST /templates/web-terminal/deploy '{"target_stack":"demo","auto_start":false,"routes":false}' | status_of)"
check "web terminal: status before"                'false true' "$(wt_request GET /terminal/web | body_of | jq -r '"\(.deployed) \(.ready)"' 2>/dev/null)"
check "web terminal: deploys behind Authelia"      200 "$(wt_request POST /templates/web-terminal/deploy '{"target_stack":"demo","auto_start":false,"authelia_services":[]}' | status_of)"
check "web terminal: the route is protected even when the request says none" 1 "$(grep -c '"authelia-forwardauth"' "$_ZZR/demo/terminal.yml" 2>/dev/null)"
check "web terminal: the route reaches the container's port" 1 "$(grep -c 'http://Web-Terminal:7681' "$_ZZR/demo/terminal.yml" 2>/dev/null)"
check "web terminal: no port is published"         0 "$(awk '/^  terminal:/{f=1; next} f && /^  [A-Za-z]/{f=0} f && /^    ports:/{n++} END{print n+0}' "$WORK/Stacks/demo/docker-compose.yml")"
check "web terminal: the key is in authorized_keys, private addresses only" 1 "$(grep -c '^from="127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16",no-agent-forwarding,no-X11-forwarding,no-port-forwarding ssh-ed25519 [A-Za-z0-9+/=]* dcs-web-terminal$' "$WORK/wt-home/.ssh/authorized_keys")"
check "web terminal: other keys are kept"          1 "$(grep -c 'someone@else' "$WORK/wt-home/.ssh/authorized_keys")"
check "web terminal: the private key is private"   600 "$(stat -c %a "$_WTD/id_ed25519" 2>/dev/null)"
check "web terminal: the host key is pinned"       1 "$(grep -c '^dcs-host ssh-ed25519 ' "$_WTD/known_hosts" 2>/dev/null)"
check "web terminal: the start script signs in as this user" 1 "$(grep -c -- "-o StrictHostKeyChecking=yes .* -p 22 $(id -un)@host.docker.internal" "$_WTD/start.sh" 2>/dev/null)"
check "web terminal: the page keeps a session in use alive" 1 "$(grep -c "fetch('token'" "$_WTD/page.js" 2>/dev/null)"
check "web terminal: the start script serves that page" 1 "$(grep -c -- '-I "\$PAGE"' "$_WTD/start.sh" 2>/dev/null)"
# a terminal deployed by an earlier version gets the current start script when the API starts
printf '#!/bin/sh\n# an earlier start script\n' > "$_WTD/start.sh"; command rm -f "$_WTD/page.js"
DCS_WEB_TERMINAL_HOME="$WORK/wt-home" DCS_WEB_TERMINAL_HOSTKEYS="$WORK/wt-hostkeys" PATH="$WORK/fakebin:$PATH" _lib _web_terminal_upgrade >/dev/null 2>&1
check "web terminal: an earlier start script is brought up to date" '1 1' "$(printf '%s %s' "$(grep -c '^# dcs-web-terminal-start: 2$' "$_WTD/start.sh" 2>/dev/null)" "$(grep -c -- "-p 22 $(id -un)@host.docker.internal" "$_WTD/start.sh" 2>/dev/null)")"
check "web terminal: …with its page"                yes "$([[ -s "$_WTD/page.js" ]] && echo yes || echo no)"
_WTS=$(wt_request GET /terminal/web | body_of)
check "web terminal: status after"                 'true true true https://terminal.smoke.test' "$(jq -r '"\(.deployed) \(.protected) \(.key_installed) \(.url)"' <<< "$_WTS" 2>/dev/null)"
check "web terminal: a viewer sees nothing"        403 "$(viewer_request GET /terminal/web | status_of)"
check "web terminal: a look needs real colours"    400 "$(wt_request POST /terminal/web/theme '{"theme":{"background":"red; rm -rf /","foreground":"#fff"}}' | status_of)"
check "web terminal: a quote cannot get into the file" 400 "$(wt_request POST /terminal/web/theme "{\"theme\":{\"background\":\"#000'\",\"foreground\":\"#fff\"}}" | status_of)"
check "web terminal: a look is saved"              200 "$(wt_request POST /terminal/web/theme '{"theme":{"background":"#0a0705","foreground":"#f4ede4","cursor":"#ff7a1a","nonsense":"#123456"},"font_size":16}' | status_of)"
check "web terminal: …with only the keys a terminal has" "THEME='{\"background\":\"#0a0705\",\"foreground\":\"#f4ede4\",\"cursor\":\"#ff7a1a\"}' FONT_SIZE='16'" "$(sed -n '1,2p' "$_WTD/options" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
# shown inside another page (a Homarr card): only the named pages may frame it, and Authelia stays in front
check "web terminal: an origin is an address, nothing more" 400 "$(wt_request POST /terminal/web/embed '{"origins":["https://dash.smoke.test/\" x"]}' | status_of)"
check "web terminal: no wildcard"                  400 "$(wt_request POST /terminal/web/embed '{"origins":["*"]}' | status_of)"
check "web terminal: a page may show it"           200 "$(wt_request POST /terminal/web/embed '{"origins":["https://dash.smoke.test"]}' | status_of)"
check "web terminal: its rule comes first, Authelia stays" yes "$(awk '/^      middlewares:/{f=1; next} f && /^        - /{n++; if (n == 1 && $2 == "\"terminal-embed\"") first=1; if ($2 == "\"authelia-forwardauth\"") auth=1; next} f{exit} END{print (first && auth) ? "yes" : "no"}' "$_ZZR/demo/terminal.yml")"
check "web terminal: only that page may frame it"  1 "$(grep -c "contentSecurityPolicy: \"frame-ancestors 'self' https://dash.smoke.test\"" "$_ZZR/demo/terminal.yml")"
check "web terminal: status names the page"        'https://dash.smoke.test true' "$(wt_request GET /terminal/web | body_of | jq -r '(.embed_origins | join(",")) + " \(.protected)"' 2>/dev/null)"
wt_request POST /terminal/web/embed '{"origins":["https://dash.smoke.test"]}' >/dev/null
check "web terminal: asked twice, written once"    1 "$(grep -c '^    terminal-embed:' "$_ZZR/demo/terminal.yml")"
check "web terminal: the permission is taken away" 200 "$(wt_request POST /terminal/web/embed '{"origins":[]}' | status_of)"
check "web terminal: …and the route is as it was"  0 "$(grep -c 'terminal-embed\|frame-ancestors' "$_ZZR/demo/terminal.yml")"
check "web terminal: …still behind Authelia"       1 "$(grep -c '"authelia-forwardauth"' "$_ZZR/demo/terminal.yml")"
check "web terminal: a second one is refused"      409 "$(wt_request POST /templates/web-terminal/deploy '{"target_stack":"demo2","auto_start":false}' | status_of)"
check "web terminal: removed"                      200 "$(wt_request POST /templates/web-terminal/undeploy '{"target_stack":"demo","services":["terminal"],"remove_routes":true}' | status_of)"
check "web terminal: its key no longer opens the server" 0 "$(grep -c 'dcs-web-terminal' "$WORK/wt-home/.ssh/authorized_keys")"
check "web terminal: …the other key still does"    1 "$(grep -c 'someone@else' "$WORK/wt-home/.ssh/authorized_keys")"
check "web terminal: the key file is gone"         no "$([[ -e "$_WTD/id_ed25519" ]] && echo yes || echo no)"
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
# start on demand goes to the VM as asked (it makes its own Sablier): the hub no longer refuses it
check "vm deploy: on demand goes to the VM"       no "$([[ "$(fake_request POST "$_MP" '{"target_stack":"zz-vm","on_demand_services":["routed-tpl"]}' | status_of)" == 409 ]] && echo yes || echo no)"
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
# the unit path is taken on a host that runs systemd only (a CI job container has none: the plain run above is its path)
if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
printf '#!/bin/bash\nexit 0\n' > "$_HB/systemd-run"
printf '#!/bin/bash\n[[ "$*" == *--sync* ]] && exit 0\necho "from the journal"\n' > "$_HB/journalctl"
check "host run: the unit's output is the journal's"           "from the journal" "$(PATH="$_HB:$PATH" _lib _run_host '' '' echo never-printed)"
printf '#!/bin/bash\nexit 3\n' > "$_HB/systemd-run"
check "host run: the unit's exit status is kept"               3 "$(PATH="$_HB:$PATH" _lib eval '_run_host "" "" true >/dev/null || echo $?')"
fi
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
_CFP=$(_rport); _CFS="$WORK/.data/cf-mock.json"
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
# more than one domain: each one's apex follows the public address, in its own zone
_ENV0=$(cat "$WORK/.env"); _envset PROXY_DOMAIN smoke.test; _envset PROXY_DOMAINS_EXTRA '"other.test smoke.test sub.smoke.test bad_domain other.test"'
check "domains: the others, cleaned"         "other.test" "$(_lib _domains_extra | paste -sd' ')"
check "domains: all of them, primary first"  "smoke.test other.test" "$(_lib _domains_all | paste -sd' ')"
check "domains: a host's domain"             other.test "$(_lib _domain_of_host app.other.test)"
check "domains: a deeper host's domain"      smoke.test "$(_lib _domain_of_host x.app.smoke.test)"
check "domains: a host of none"              "" "$(_lib _domain_of_host app.nope.test)"
rm -f "$WORK/.api-auth/.cf-zone-cache"* "$WORK/.data/ddns-current-ip"
_cf env DDNS_ENABLED=true DDNS_SUBDOMAINS='@' DDNS_ONCE=true DDNS_INTERVAL=1 TRAEFIK_DOMAIN=smoke.test bash -c "cd '$WORK' && source '$API' >/dev/null 2>&1; _ddns_update_loop" >/dev/null 2>&1
check "ddns: every domain's apex"            2 "$(jq -r '[.records["zone-smoke.test"][]?, .records["zone-other.test"][]? | select(.type == "A" and (.name == "smoke.test" or .name == "other.test") and .content == "203.0.113.9")] | length' "$_CFS" 2>/dev/null)"
check "ddns: the other domain in its own zone" 1 "$(jq -r '[.records["zone-other.test"][]? | select(.type == "A" and .name == "other.test")] | length' "$_CFS" 2>/dev/null)"
check "zone cache: the primary keeps its file" smoke.test "$(sed -n 1p "$WORK/.api-auth/.cf-zone-cache" 2>/dev/null)"
check "zone cache: another domain has its own" zone-other.test "$(sed -n 2p "$WORK/.api-auth/.cf-zone-cache.other.test" 2>/dev/null)"
printf '%s\n' "$_ENV0" > "$WORK/.env"
kill "$_CFPID" 2>/dev/null; wait "$_CFPID" 2>/dev/null || true

# the proxy's domains: wildcard certificates (Traefik), sign-in (Authelia: cookie, rules, its route); added and taken out again
_DMD="$WORK/dom-fixture"; mkdir -p "$_DMD/base"
printf 'entryPoints:\n  websecure:\n    address: ":443"\n    http:\n      tls:\n        certResolver: letsencrypt\n        domains:\n          - main: smoke.test\n            sans:\n              - "*.smoke.test"\n\n  traefik:\n    address: ":8080"\n' > "$_DMD/traefik.yml"
printf 'access_control:\n  default_policy: deny\n  rules:\n    - domain:\n        - "auth.smoke.test"\n      policy: bypass\n    - domain:\n        - "*.smoke.test"\n      policy: one_factor\nsession:\n  name: authelia_session\n  cookies:\n    - domain: smoke.test\n      authelia_url: "https://auth.smoke.test"\n  redis:\n    host: r\n' > "$_DMD/configuration.yml"
printf 'http:\n  routers:\n    authelia:\n      rule: "Host(`auth.smoke.test`)"\n      service: authelia\n' > "$_DMD/authelia.yml"
command cp "$_DMD/traefik.yml" "$_DMD/traefik.orig"; command cp "$_DMD/configuration.yml" "$_DMD/configuration.orig"; command cp "$_DMD/authelia.yml" "$_DMD/authelia.orig"
_dsync() { printf 'PROXY_DOMAINS_EXTRA="%s"\n' "$1" > "$_DMD/base/.env"; _lib eval "BASE_DIR='$_DMD/base'; _find_traefik_domain() { echo smoke.test; }; _traefik_domains_sync '$_DMD/traefik.yml'; _authelia_domains_sync '$_DMD/configuration.yml' '$_DMD/authelia.yml' '${2:-}'; echo \"\$TRAEFIK_DOMAINS_CHANGED \$AUTHELIA_DOMAINS_CHANGED\""; }
check "domains: added, both configs change"  "true true" "$(_dsync other.test)"
check "domains: a certificate for each"      "smoke.test other.test" "$(grep -oE 'main:[[:space:]]*[A-Za-z0-9.-]+' "$_DMD/traefik.yml" | awk '{print $NF}' | paste -sd' ')"
check "domains: a sign-in cookie for each"   "smoke.test other.test" "$(grep -oE '^[[:space:]]+-[[:space:]]+domain:[[:space:]]*[A-Za-z0-9.-]+' "$_DMD/configuration.yml" | awk '{print $NF}' | paste -sd' ')"
check "domains: the rules cover each"        "auth.smoke.test auth.other.test|*.smoke.test *.other.test" "$(awk '/^access_control:/ {on = 1; next} /^[a-z]/ {on = 0} on && /- domain:/ {if (g != "") out = out (out == "" ? "" : "|") g; g = ""; next} on && /^[ ]+- "/ {v = $0; sub(/^[ ]+- "/, "", v); sub(/".*/, "", v); g = g (g == "" ? "" : " ") v} END {if (g != "") out = out (out == "" ? "" : "|") g; print out}' "$_DMD/configuration.yml")"
check "domains: the sign-in route answers both" 'rule: "Host(`auth.smoke.test`) || Host(`auth.other.test`)"' "$(grep -o 'rule: .*' "$_DMD/authelia.yml")"
check "domains: a second run changes nothing" "false false" "$(_dsync other.test)"
check "domains: taken out again"             "true true" "$(_dsync "" other.test)"
check "domains: the files as they were"      "same same same" "$(for f in traefik configuration authelia; do cmp -s "$_DMD/$f.yml" "$_DMD/$f.orig" && printf 'same ' || printf 'differs '; done | sed 's/ $//')"
# a VM's routes answer under the domain chosen for it (the subdomain stays)
_RHD="$WORK/rehost"; mkdir -p "$_RHD/x"; printf 'http:\n  routers:\n    a:\n      rule: "Host(`sonarr.smoke.test`)"\n    b:\n      rule: "Host(`api.other.test`) && PathPrefix(`/v1`)"\n    c:\n      rule: "Host(`keep.elsewhere.org`)"\n' > "$_RHD/x/r.yml"
check "rehost: files changed"                1 "$(_lib eval "_find_traefik_routes_dir() { echo '$_RHD'; }; _routes_rehost new.test 'smoke.test other.test'")"
check "rehost: hosts moved, others left"     'sonarr.new.test api.new.test keep.elsewhere.org' "$(grep -oE 'Host\(`[^`]+`\)' "$_RHD/x/r.yml" | sed -E 's/Host\(`(.*)`\)/\1/' | paste -sd' ')"

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
_SCP=$(_rport3); _SCS=0f8fad5b-d9cb-469f-a165-70867728950e
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

fi   # (end of the sections SMOKE_ONLY=crowdsec skips)

# >>> CrowdSec page
# =============================================================================
# CrowdSec page: the API behind /crowdsec/* (.lib/crowdsec.sh, .lib/crowdsec-config.sh) through the real router, as admin and as
# viewer, against tests/mock-crowdsec.py (a stateful stand-in for `docker` and `cscli`).
#
# Nothing here can touch a real container or the network: the stand-in is the only `docker` on the PATH of every request, `curl` only
# reaches a fake Discord on loopback (it refuses everything else), `hostname -I` answers a fixed address and `sleep` does not wait
# (the stand-in keeps its own clock). The install these requests run against is a copy of the scripts in a directory of its own.
#
#   SMOKE_ONLY=crowdsec tests/smoke.sh                       just this section (about a minute on 8 or more cores; the lanes below run side by side)
#   SMOKE_ONLY=crowdsec SMOKE_CS_PARTS="status bans" tests/smoke.sh   only some of its parts: status allowlist alerts units bans settings notify services hub
#                                                            security large plugin importbig mediaapps (see cst_main for the lane each one runs in)
#   SMOKE_CS_LANES=1     one lane, the parts in order, the output live (default: nine lanes at once, each one's output printed when all are done)
#   SMOKE_CS_JOBS=N      how many requests of a batch are sent at once (default 4)
#   SMOKE_JQ16=/path     a jq 1.6 to run the section's jq programs with (units part); without one that check is skipped
#   SMOKE_CS_MOCK=/path  another stand-in for docker and cscli (default tests/mock-crowdsec.py)
# =============================================================================
CST_ROOT="$WORK-cs"; CST="$CST_ROOT"             # (each lane of the section has an install of its own below $CST_ROOT: see cst_main)
CST_MOCK="${SMOKE_CS_MOCK:-$ROOT/tests/mock-crowdsec.py}"
CST_MOCK_RUN="$CST_MOCK"             # what is run: the script itself, or its bytecode when cst_main could compile it (thousands of calls start it)
CST_API=""
CST_SERVER_IP="203.0.113.250"       # what `hostname -I` says inside these requests (the "this server" address of the ban guard)
CST_HOOK_ID=111111111111111111; CST_HOOK_TOKEN=NOTAREALTOKEN_0123456789-abcdefghij     # placeholders: this webhook is never a real one
CST_HOOK="https://discord.com/api/webhooks/$CST_HOOK_ID/$CST_HOOK_TOKEN"
CST_ENV=(DOCKER_COMPOSE_CMD="docker compose" API_RATE_LIMIT=0 DCS_API_EFFECTIVE_AUTH=true DCS_API_EFFECTIVE_BIND=127.0.0.1)
# one language for every request, so that what bash's [a-z] and sort mean does not depend on the machine that runs the tests
CST_LOC=""; locale -a 2>/dev/null | grep -qiE '^c\.utf-?8$' && CST_LOC="C.UTF-8"
[[ -z "$CST_LOC" ]] || CST_ENV+=(LC_ALL="$CST_LOC")
CST_ADM=""; CST_VWR=""; CST_RAW=""; CST_ST=""; CST_BODY=""
CST_PWN="/tmp/cst-pwn-$$"          # what the hostile text asks a command to make: short (the length of a path must not decide whether a text is refused), and never there
CST_QN=0; declare -A CST_QLABEL=() CST_RST=() CST_RBODY=()
export CST_RUN_BIN CST_RUN_API CST_RUN_Q CST_RUN_LOC

cst_setup() {
    local b inv dport i
    CST_API="$CST/.scripts/api-server.sh"
    rm -rf "$CST"
    mkdir -p "$CST"/{.scripts,.lib,.config,.data,logs,.api-auth,.templates,Stacks,bin,fake,q}
    cp "$ROOT/.scripts/api-server.sh" "$CST/.scripts/"; cp "$ROOT/VERSION" "$CST/"
    cp -r "$ROOT/.lib/." "$CST/.lib/"; cp -r "$ROOT/.config/." "$CST/.config/"; cp -r "$ROOT/.templates/crowdsec" "$CST/.templates/"
    grep -vE '^(API_BIND|API_AUTH_ENABLED|API_INSECURE_NO_AUTH|API_TRUSTED_PROXIES|API_IP_WHITELIST|API_PORT)=' "$ROOT/.env.example" > "$CST/.env"
    printf 'API_PORT=9876\nMETRICS_ENABLED=false\n' >> "$CST/.env"
    : > "$CST/argv.log"; : > "$CST/curl-argv.log"; : > "$CST/api-stderr.log"; : > "$CST/cp-modes.log"

    # the only docker: it writes down every argument list it gets (shell-quoted: one line per call), then is the stand-in
    cat > "$CST/bin/docker" <<SH
#!/bin/bash
printf '%s\n' "\$(printf '%q ' "\$@")" >> "$CST/argv.log"      # one write per call: parallel calls do not mix their lines
[[ "\$1" == cp ]] && printf '%s %s\n' "\$(stat -c %a "\$2" 2>/dev/null)" "\$3" >> "$CST/cp-modes.log"
[[ "\$1 \$2" == "restart Traefik" && -e "$CST/fail-traefik-restart" ]] && { echo "Error response from daemon: cannot restart container Traefik" >&2; exit 1; }
export FAKE_CS_DIR="$CST/fake"
exec python3 "$CST_MOCK_RUN" "\$@"
SH
    # the only curl: Discord's webhook host is rewritten to the fake Discord on loopback, anything else is refused without a connection
    cat > "$CST/bin/curl" <<SH
#!/bin/bash
printf '%s\n' "\$(printf '%q ' "\$@")" >> "$CST/curl-argv.log"
args=(); cfg=""
while (( \$# )); do
    if [[ "\$1" == -K && "\${2:-}" == - ]]; then cfg=\$(cat); shift 2; continue; fi
    args+=("\$1"); shift
done
for a in "\${args[@]}"; do
    case "\$a" in
        http://Traefik:8080/api/version) [[ -e "$CST/traefik-api/routers.json" ]] && { echo '{"Version":"3.1.4"}'; exit 0; }; exit 22 ;;
        http://Traefik:8080/api/http/routers) [[ -e "$CST/traefik-api/routers.json" ]] && { cat "$CST/traefik-api/routers.json"; exit 0; }; exit 22 ;;
    esac
done
port=\$(cat "$CST/discord.port" 2>/dev/null)
url=\$(sed -n 's/^url = "\(.*\)"\$/\1/p' <<< "\$cfg")
[[ "\$url" =~ ^https://(discord\.com|discordapp\.com|ptb\.discord\.com|canary\.discord\.com)/(.*)\$ && -n "\$port" ]] || { echo "curl: (7) refused by the test" >&2; exit 7; }
tmp=\$(mktemp); printf 'url = "http://127.0.0.1:%s/%s"\n' "\$port" "\${BASH_REMATCH[2]}" > "\$tmp"
"$(command -v curl)" -K "\$tmp" "\${args[@]}"; rc=\$?; rm -f "\$tmp"; exit \$rc
SH
    {
        printf '#!/bin/bash\n[[ "$1" == -I ]] && { echo "%s 10.77.0.5"; exit 0; }\n' "$CST_SERVER_IP"
        if command -v hostname >/dev/null 2>&1; then printf 'exec %q "$@"\n' "$(command -v hostname)"; else printf 'echo cst-host\n'; fi
    } > "$CST/bin/hostname"
    printf '#!/bin/bash\nexit 0\n' > "$CST/bin/sleep"
    # the only IPv6 route out: what $CST/ip6-src says (no file: this server has no IPv6), whatever the machine running the tests has
    {
        printf '#!/bin/bash\nif [[ "$1 $2 $3" == "-6 route get" ]]; then\n'
        printf '    s=$(cat %q 2>/dev/null); [[ -n "$s" ]] || { echo "RTNETLINK answers: Network is unreachable" >&2; exit 2; }\n' "$CST/ip6-src"
        printf '    echo "$4 from :: via fe80::1 dev eth0 proto ra src $s metric 100 pref medium"; exit 0\nfi\n'
        if command -v ip >/dev/null 2>&1; then printf 'exec %q "$@"\n' "$(command -v ip)"; else printf 'exit 1\n'; fi
    } > "$CST/bin/ip"
    chmod +x "$CST/bin/"*

    # the fake Discord: every POST is appended to discord.log as {"path", "body"}; discord.status holds the answer to give (204)
    cat > "$CST/discord.py" <<'PY'
import http.server, json, os, sys
LOG, PORTF, STATUS = sys.argv[1:4]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length') or 0)).decode('utf-8', 'replace')
        with open(LOG, 'a') as f: f.write(json.dumps({'path': self.path, 'body': raw}) + '\n')
        try: code = int(open(STATUS).read().strip())
        except Exception: code = 204
        body = b'' if code == 204 else (b'{"message": "You are being rate limited.", "retry_after": 2.5}' if code == 429 else b'{"message": "Invalid Form Body", "code": 50035}')
        self.send_response(code); self.send_header('Content-Length', str(len(body)))
        if body: self.send_header('Content-Type', 'application/json')
        self.end_headers(); self.wfile.write(body)
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H)
open(PORTF, 'w').write(str(srv.server_address[1]))
srv.serve_forever()
PY
    : > "$CST/discord.log"
    python3 "$CST/discord.py" "$CST/discord.log" "$CST/discord.port" "$CST/discord.status" >/dev/null 2>&1 &
    RIP_CS=$!
    for i in $(seq 1 100); do [[ -s "$CST/discord.port" ]] && break; sleep 0.05; done
    dport=$(cat "$CST/discord.port" 2>/dev/null)

    # reads a Discord notification file (notifications/http.yaml) the way Go's template lexer would and says which tokens its actions
    # are made of, with every string literal masked: text a person typed can only ever sit inside a string literal
    cat > "$CST/tplscan.py" <<'PY'
import json, re, sys
tpl_text = sys.stdin.read()
top, block, inblock = [], [], False
for ln in tpl_text.split('\n'):
    if inblock:
        if ln.startswith('  ') or ln == '':
            block.append(ln[2:] if ln.startswith('  ') else ''); continue
        inblock = False
    if ln.startswith('format: |'):
        inblock = True; top.append('format'); continue
    if ln and not ln.startswith('#') and not ln.startswith(' '):
        top.append(ln.split(':', 1)[0])
tpl = '\n'.join(block)
toks, bad, i, n = set(), [], 0, len(tpl)
while True:
    j = tpl.find('{{', i)
    if j < 0: break
    k = j + 2; code = []
    while k < n and not tpl.startswith('}}', k):
        c = tpl[k]
        if tpl.startswith('/*', k):
            e = tpl.find('*/', k + 2); k = (e + 2) if e >= 0 else n; code.append(' '); continue
        if c == '"':
            m = k + 1
            while m < n and tpl[m] != '"':
                if tpl[m] == '\n': bad.append('a line break inside a string literal near %d' % j)
                if tpl[m] == '\\': m += 1
                m += 1
            k = m + 1; code.append(' S '); continue
        if c == '`':
            e = tpl.find('`', k + 1); k = (e + 1) if e >= 0 else n; code.append(' R '); continue
        if c == "'":
            m = k + 1
            while m < n and tpl[m] != "'":
                if tpl[m] == '\\': m += 1
                m += 1
            k = m + 1; code.append(' C '); continue
        code.append(c); k += 1
    if k >= n: bad.append('an action is not closed near %d' % j)
    for t in re.findall(r'\$?[A-Za-z_][A-Za-z0-9_]*|\.[A-Za-z_][A-Za-z0-9_]*|[0-9]+|:=|[^\sA-Za-z0-9_]', ''.join(code)):
        toks.add(re.sub(r'[0-9]+', '#', t))
    i = k + 2
print(json.dumps({'tokens': sorted(toks), 'top': sorted(set(top)), 'bad': bad}))
PY

    # what the parallel batches run (cst_q / cst_run)
    cat > "$CST/run1.sh" <<'SH'
#!/bin/bash
n="$1"; mapfile -t e < "$CST_RUN_Q/$n.env"
timeout 180 env -u SOCAT_PEERADDR -u NCAT_REMOTE_ADDR -u DISCORD_WEBHOOK_URL -u CROWDSEC_TRUSTED_IPS -u CROWDSEC_MEDIA_APPS PATH="$CST_RUN_BIN:$PATH" DOCKER_COMPOSE_CMD="docker compose" API_RATE_LIMIT=0 DCS_API_EFFECTIVE_AUTH=true DCS_API_EFFECTIVE_BIND=127.0.0.1 \
    ${CST_RUN_LOC:+"LC_ALL=$CST_RUN_LOC"} "${e[@]}" "$CST_RUN_API" --handle-request < "$CST_RUN_Q/$n.req" > "$CST_RUN_Q/$n.out" 2>>"$CST_RUN_Q/../api-stderr.log"
SH
    CST_RUN_BIN="$CST/bin"; CST_RUN_API="$CST_API"; CST_RUN_Q="$CST/q"; CST_RUN_LOC="$CST_LOC"

    # the accounts: an admin and a viewer (role "user")
    b='{"username":"admin","password":"correct horse battery"}'
    CST_ADM=$(printf 'POST /auth/setup HTTP/1.1\r\nContent-Length: %d\r\n\r\n%s' "${#b}" "$b" | env "${AUTH[@]}" "$CST_API" --handle-request 2>>"$CST/api-stderr.log" | sed -n '/^\r*$/,$p' | sed '1d' | jq -r '.token // empty')
    cst_call admin POST /auth/invite '{"role":"user"}'
    inv=$(jq -r '.code // empty' <<< "$CST_BODY")
    cst_call none POST /auth/register "{\"username\":\"viewer\",\"password\":\"viewer-pass-123\",\"invite_code\":\"$inv\"}"
    CST_VWR=$(jq -r '.token // empty' <<< "$CST_BODY")
    [[ -n "$CST_ADM" && -n "$CST_VWR" && -n "$dport" ]]
}

cst_teardown() {
    if [[ -n "${RIP_CS:-}" ]]; then kill "$RIP_CS" 2>/dev/null; wait "$RIP_CS" 2>/dev/null; RIP_CS=""; fi
    rm -rf "$CST" "$CST_PWN"
}

# ---- requests ---------------------------------------------------------------------------------------------------------------------

# cst_call ROLE METHOD PATH [BODY] [NAME=value …] — one request through the router. ROLE: admin | viewer | none.
# Sets CST_ST (status), CST_BODY and CST_RAW (the whole answer). The extra NAME=value pairs are environment for that request only
# (SOCAT_PEERADDR=… is the caller's address, DISCORD_WEBHOOK_URL=… the server's webhook).
cst_call() {
    local role="$1" m="$2" p="$3" b="${4:-}" hdr=""
    shift 4 2>/dev/null || shift $#
    case "$role" in admin) hdr=$'Authorization: Bearer '"$CST_ADM"$'\r\n' ;; viewer) hdr=$'Authorization: Bearer '"$CST_VWR"$'\r\n' ;; esac
    CST_RAW=$(printf '%s %s HTTP/1.1\r\nHost: test\r\n%sContent-Length: %d\r\n\r\n%s' "$m" "$p" "$hdr" "$(printf '%s' "$b" | wc -c)" "$b" \
        | timeout "${CST_TIMEOUT:-180}" env -u SOCAT_PEERADDR -u NCAT_REMOTE_ADDR -u DISCORD_WEBHOOK_URL -u CROWDSEC_TRUSTED_IPS -u CROWDSEC_MEDIA_APPS PATH="$CST/bin:$PATH" "${CST_ENV[@]}" "$@" "$CST_API" --handle-request 2>>"$CST/api-stderr.log")
    CST_ST="${CST_RAW:9:3}"; CST_BODY="${CST_RAW#*$'\r\n\r\n'}"
}

# cst_q LABEL ROLE METHOD PATH [BODY] [NAME=value …] — queue a request; cst_run sends the whole queue in parallel (only for requests
# that do not depend on each other), then cst_use LABEL makes one answer the current one for cst_is / cst_j / cst_t.
cst_q() {
    local label="$1" role="$2" m="$3" p="$4" b="${5:-}" hdr="" n
    shift 5 2>/dev/null || shift $#
    case "$role" in admin) hdr=$'Authorization: Bearer '"$CST_ADM"$'\r\n' ;; viewer) hdr=$'Authorization: Bearer '"$CST_VWR"$'\r\n' ;; esac
    n=$(( ++CST_QN )); CST_QLABEL[$label]=$n
    printf '%s %s HTTP/1.1\r\nHost: test\r\n%sContent-Length: %d\r\n\r\n%s' "$m" "$p" "$hdr" "$(printf '%s' "$b" | wc -c)" "$b" > "$CST/q/$n.req"
    if (( $# )); then printf '%s\n' "$@" > "$CST/q/$n.env"; else : > "$CST/q/$n.env"; fi
}
cst_run() {
    local n=1 out label
    (( CST_QN > 0 )) || return 0
    seq 1 "$CST_QN" | xargs -P "${SMOKE_CS_JOBS:-4}" -I{} bash "$CST/run1.sh" {}
    for label in "${!CST_QLABEL[@]}"; do
        n="${CST_QLABEL[$label]}"
        out=$(cat "$CST/q/$n.out" 2>/dev/null)
        CST_RST[$label]="${out:9:3}"; CST_RBODY[$label]="${out#*$'\r\n\r\n'}"
    done
    rm -f "$CST"/q/*; CST_QN=0; CST_QLABEL=()
}
cst_use() { CST_ST="${CST_RST[$1]:-}"; CST_BODY="${CST_RBODY[$1]:-}"; }

# ---- checks over the current answer ---------------------------------------------------------------------------------------------

cst_is() {                                                                # cst_is NAME STATUS (a wrong status shows what the API said)
    check "$1" "$2" "$CST_ST"
    [[ "$CST_ST" == "$2" ]] || printf '       (the answer said: %s)\n' "$(jq -r '.message // empty' <<< "$CST_BODY" 2>/dev/null | head -c 240)"
}
cst_t()  { check "$1" true "$(jq -r "$2" <<< "$CST_BODY" 2>/dev/null)"; } # cst_t NAME 'jq expression that must be true'
cst_j()  {                                                                # cst_j NAME EXPR VALUE [EXPR VALUE …]: jq -r EXPR over the body equals VALUE
    local n="$1" e v
    shift
    while (( $# >= 2 )); do e="$1"; v="$2"; shift 2; check "$n $e" "$v" "$(jq -r "$e" <<< "$CST_BODY" 2>/dev/null)"; done
}
# cst_try NAME STATUS ROLE METHOD PATH [BODY] [ENV…] — one request and its status in one line
cst_try() { local n="$1" s="$2"; shift 2; cst_call "$@"; cst_is "$n" "$s"; }

# ---- the world of the requests ----------------------------------------------------------------------------------------------------

# the stand-in's control verbs (--mock-init PRESET [--traefik], --mock-set K=V, --mock-tick S); the API's cached answers go with them
cst_mock() { FAKE_CS_DIR="$CST/fake" python3 "$CST_MOCK_RUN" "$@" >/dev/null 2>&1 || echo "  (the stand-in refused: $*)"; rm -rf "$CST/.data/cache/crowdsec"; }

# cst_env KEY [VALUE] — a key of the install's .env (the API reads it on every request; an empty VALUE is "not set")
cst_env() { sed -i "/^${1}=/d" "$CST/.env"; printf '%s=%s\n' "$1" "${2:-}" >> "$CST/.env"; rm -rf "$CST/.data/cache/crowdsec"; }

# cst_stack KIND: none | plain (a stack without Traefik or CrowdSec) | traefik (Traefik's stack with the shipped config) | traefik-cs (… and it defines CrowdSec)
cst_stack() {
    local st="$CST/Stacks/networking-security"
    rm -rf "$CST/Stacks"; mkdir -p "$CST/Stacks"
    case "$1" in
        plain) mkdir -p "$CST/Stacks/demo"; printf 'services:\n  demo:\n    image: alpine:3\n' > "$CST/Stacks/demo/docker-compose.yml" ;;
        traefik|traefik-cs)
            mkdir -p "$st/App-Data/Traefik"; cp -r "$ROOT/.templates/traefik/config/." "$st/App-Data/Traefik/"
            touch -d '30 days ago' "$st/App-Data/Traefik/traefik.yml"      # (the stand-in's Traefik started three days ago: a newer static config would mean "not loaded yet")
            printf 'services:\n  traefik:\n    container_name: Traefik\n    image: traefik:v3.1\n' > "$st/docker-compose.yml"
            [[ "$1" == traefik-cs ]] && printf '  crowdsec:\n    container_name: CrowdSec\n    image: crowdsecurity/crowdsec:latest\n' >> "$st/docker-compose.yml"
            printf 'TRAEFIK_DOMAIN=lab.example.test\nTRAEFIK_TRUSTED_LAN=10.1.0.0/24\n' > "$st/.env" ;;
    esac
}

# cst_world PRESET [STACK] [mock-init flags…] — a clean start: the install forgets the CrowdSec files it wrote, the stand-in starts over
cst_world() {
    local preset="$1" stack="${2:-none}"
    shift 2 2>/dev/null || shift $#
    rm -rf "$CST/.data/crowdsec" "$CST/.data/cache" "$CST/.data/crowdsec-trusted.json" "$CST/.data/crowdsec-whitelist.json" "$CST/.data/ddns-current-ip" "$CST/.secrets"
    cst_stack "$stack"
    cst_mock --mock-init "$preset" "$@"
}

# the API's cached answers (the status 5 s, the routes 10 s …): gone
cst_uncache() { rm -rf "$CST/.data/cache"; }

# the stand-in itself, as the API would call it (docker exec CrowdSec cscli …)
cst_dk() { "$CST/bin/docker" "$@"; }
cst_cs() { "$CST/bin/docker" exec CrowdSec cscli "$@"; }

# cst_lock_hold FILE — somebody else holds the lock on FILE (for 25 s at most; cst_lock_release lets go). The process that holds it is the one that sleeps: killing it frees the lock.
cst_lock_hold() {
    local i
    ( exec 9> "$1"; flock -x 9; exec sleep 25 ) &
    CST_HOLDER=$!
    for i in $(seq 1 50); do flock -n -x "$1" true 2>/dev/null || break; sleep 0.1; done      # (until the lock is held)
}
cst_lock_release() { kill "$CST_HOLDER" 2>/dev/null; wait "$CST_HOLDER" 2>/dev/null; return 0; }

cst_secrets_n() { find "$CST/.secrets" -maxdepth 1 -name "$1" 2>/dev/null | wc -l | tr -d ' '; }   # how many of the secrets DCS keeps match a name

cst_argv_n() { wc -l < "$CST/argv.log" | tr -d ' '; }          # how many docker calls so far (a mark for cst_argv_since)
cst_argv_since() { tail -n +$(( $1 + 1 )) "$CST/argv.log"; }
cst_calls_n() { wc -l < "$CST/fake/calls.log" 2>/dev/null | tr -d ' '; }
cst_audit_n() { grep -c "$1" "$CST/.data/audit.jsonl" 2>/dev/null || true; }
cst_disc_n() { wc -l < "$CST/discord.log" | tr -d ' '; }
cst_disc_last() { tail -n 1 "$CST/discord.log" | jq -r '.body' 2>/dev/null; }

# ---------------------------------------------------------------------------------------------------------------------------------

# ---- GET /crowdsec/status in every state ---------------------------------------------------------------------------------------------

cst_part_status() {
    local n0 n1
    echo "CrowdSec page: the status in every state"

    # -- not deployed: no container, and no stack file that defines one
    cst_world absent none
    cst_call admin GET /crowdsec/status
    cst_is "status/absent: answers" 200
    cst_j "status/absent" '.state' not_deployed '.installed' false '.deployed' false '.running' false '.container' '' '.fixes[0].id' deploy '.fixes[0].kind' ui \
        '.fixes[0].primary' true '.docker.ok' true '.traefik.present' false '.log_tail | length' 0 '.preflight.template.name' crowdsec \
        '.preflight.target_stack' '' '.preflight.can_deploy' false '.preflight.blockers | length' 1 '.preflight.enforcement' false '.preflight.stacks | length' 0
    cst_t "status/absent: a warning says Traefik is missing and another that no webhook is set" '.preflight.warnings | length == 2'
    cst_t "status/absent: the template's variables are described" '.preflight.template.variables | map(.name) | index("DISCORD_WEBHOOK_URL") != null'
    cst_t "status/absent: no counts, no ban list before there is a CrowdSec" 'has("counts") | not'

    cst_world absent plain
    cst_call admin GET /crowdsec/status
    cst_j "status/absent+stack" '.state' not_deployed '.preflight.target_stack' demo '.preflight.can_deploy' true '.preflight.blockers | length' 0 '.preflight.stacks[0]' demo
    cst_env DISCORD_WEBHOOK_URL "$CST_HOOK"
    cst_call admin GET /crowdsec/status
    cst_env DISCORD_WEBHOOK_URL
    cst_j "status/absent+webhook" '.preflight.discord.configured' true '.preflight.warnings | length' 1

    cst_world absent traefik --traefik
    cst_call admin GET /crowdsec/status
    cst_j "status/absent+Traefik" '.state' not_deployed '.traefik.present' true '.traefik.running' true '.preflight.target_stack' networking-security \
        '.preflight.enforcement' true '.preflight.can_deploy' true '.preflight.warnings | length' 1
    cst_mock --mock-set traefik=0
    cst_mock --mock-set traefik=1
    cst_world absent plain
    mv "$CST/.templates/crowdsec" "$CST/.templates/.crowdsec-away"
    cst_call admin GET /crowdsec/status
    mv "$CST/.templates/.crowdsec-away" "$CST/.templates/crowdsec"
    cst_j "status/absent, template missing" '.state' not_deployed '.preflight.template' null '.preflight.can_deploy' false '.preflight.blockers | length' 1

    # -- the stack file defines CrowdSec but there is no container
    cst_world defined traefik-cs --traefik
    cst_call admin GET /crowdsec/status
    cst_j "status/defined" '.state' stopped '.defined_in' networking-security '.container_state' missing '.deployed' false '.fixes[0].id' start_stack \
        '.fixes[0].kind' api '.fixes[0].method' POST '.fixes[0].path' /stacks/networking-security/start '.fixes[0].primary' true '.fixes[1].id' deploy '.log_tail | length' 0

    # -- the container exists but is not running
    cst_world stopped traefik-cs --traefik
    cst_call admin GET /crowdsec/status
    cst_j "status/stopped" '.state' stopped '.container' CrowdSec '.container_state' exited '.exit_code' 137 '.deployed' true '.running' false '.installed' false \
        '.fixes[0].id' start '.fixes[0].method' POST '.fixes[0].path' /crowdsec/service '.fixes[0].body.action' start '.fixes[0].primary' true '.fixes[1].id' logs \
        '.log_tail | type' array

    cst_world crashloop traefik-cs --traefik
    cst_call admin GET /crowdsec/status
    cst_j "status/crashloop" '.state' crash_loop '.restart_count' 17 '.container_state' restarting '.running' false '.fixes | map(.id) | join(",")' logs,restart \
        '.fixes[1].body.action' restart
    cst_t "status/crashloop: the log tail names the fatal error" '.log_tail | length > 0 and (map(test("level=fatal")) | any)'

    cst_world starting traefik-cs --traefik
    cst_call admin GET /crowdsec/status
    cst_j "status/starting" '.state' starting '.health' starting '.installed' true '.running' true '.fixes | map(.id) | join(",")' logs '.log_tail | type' array

    cst_world unhealthy traefik-cs --traefik
    cst_call admin GET /crowdsec/status
    cst_j "status/unhealthy" '.state' unhealthy '.health' unhealthy '.installed' true '.fixes[0].id' restart '.fixes[0].primary' true '.fixes[1].id' logs

    cst_world lapi-down traefik-cs --traefik
    cst_call admin GET /crowdsec/status
    cst_j "status/lapi-down" '.state' lapi_unreachable '.installed' true '.fixes[0].id' restart '.fixes[0].primary' true '.log_tail | type' array
    cst_t "status/lapi-down: the detail carries cscli's own words" '.detail | test("refused")'

    cst_world data traefik-cs --traefik
    cst_mock --mock-set docker_down=1
    cst_call admin GET /crowdsec/status
    cst_j "status/docker down" '.state' docker_unavailable '.docker.ok' false '.installed' false '.fixes[0].id' retry '.fixes[0].kind' ui '.preflight' null '.container' ''
    cst_t "status/docker down: the detail is the daemon's message" '.detail | test("Docker daemon")'
    cst_try "status/docker down: the ban list is a 503, not a crash" 503 admin GET /crowdsec/decisions

    # -- healthy: an empty CrowdSec
    cst_world empty traefik --traefik
    cst_call admin GET /crowdsec/status
    cst_j "status/empty" '.state' healthy '.installed' true '.counts.decisions' 0 '.counts.decisions_active' 0 '.counts.alerts_24h' 0 '.counts.bouncers' 0 '.counts.community' 0 \
        '.decisions | length' 0 '.bouncer.registered' false '.allowlist_mechanism' native '.features.allowlists' true
    cst_j "status/empty: the missing bouncer is the issue" '.issues | map(.code) | join(",")' bouncer_missing
    cst_t "status/empty: the bouncer issue offers the fix that registers it" '.issues | map(select(.code == "bouncer_missing"))[0].fix | .path == "/crowdsec/bouncers/register-traefik" and .method == "POST"'
    cst_t "status/empty: a warning means the title is not the healthy one" '(.issues | map(select(.severity == "warning")) | length) > 0 and (.title | test("attention"))'

    # a CrowdSec that reads no log at all (the stand-in has no knob for it: its state file is edited, when it looks as expected)
    if jq -e '.cs.machines[0].datasources' "$CST/fake/state.json" >/dev/null 2>&1; then
        jq -c '.cs.machines |= map(.datasources = {})' "$CST/fake/state.json" > "$CST/fake/state.tmp" && mv "$CST/fake/state.tmp" "$CST/fake/state.json"
        rm -rf "$CST/.data/cache/crowdsec"
        cst_call admin GET /crowdsec/status
        cst_j "status/empty, nothing to read" '.issues | map(.code) | join(",")' bouncer_missing,no_datasource
        cst_t "status/empty, nothing to read: it is a warning" '.issues | map(select(.code == "no_datasource"))[0].severity == "warning"'
    fi

    # -- healthy: the full data set, Traefik's stack present but the bouncer not wired into it yet
    cst_world data traefik --traefik
    cst_call admin GET /crowdsec/status
    cst_j "status/data" '.state' healthy '.installed' true '.running' true '.health' healthy '.container' CrowdSec '.stack' networking-security '.version_number' 1.8.1 \
        '.allowlist_mechanism' native '.features.allowlists' true '.features.decisions_import' true '.counts.decisions' 12 '.counts.decisions_active' 11 '.counts.simulated' 1 \
        '.counts.community' 40 '.counts.alerts_24h' 16 '.counts.machines' 1 '.counts.bouncers' 2 '.counts.collections' 6 '.counts.scenarios' 53 '.counts.parsers' 11 \
        '.counts.updates' 1 '.counts.countries_24h' 9 '.counts.sources_24h' 14 '.bouncer.registered' true '.bouncer.name' dcs-traefik-bouncer '.bouncers | length' 2 \
        '.machines | length' 1 '.machines[0].validated' true '.acquisition.sources | length' 2 '.decisions | length' 12 '.traefik.present' true '.docker.ok' true
    cst_t "status/data: the ban list on the card is complete rows" '.decisions | all(has("value") and has("label") and has("seconds_left") and has("permanent"))'
    cst_t "status/data: the permanent ban is flagged and the simulated one too" '(.decisions | map(select(.value == "192.0.2.66"))[0].permanent) and (.decisions | map(select(.value == "78.128.113.9"))[0].simulated)'
    cst_j "status/data: enforcement before the bouncer is wired in" '.enforcement.middleware_present' false '.enforcement.in_chain' false
    cst_t "status/data: the routes directory is the stack's" '.enforcement.routes_dir | endswith("networking-security/App-Data/Traefik/custom_routes")'
    cst_j "status/data: the issues" '.issues | map(.code) | join(",")' bouncer_unchained,hub_updates '.issues[0].severity' warning '.issues[0].fix.id' register_bouncer '.issues[1].code' hub_updates \
        '.issues[1].fix.kind' ui
    cst_call admin POST /crowdsec/bouncers/register-traefik
    cst_is "status/data: registering the Traefik bouncer" 200
    cst_call admin GET /crowdsec/status
    cst_j "status/data after the bouncer is registered" '.enforcement.middleware_present' true '.enforcement.in_chain' true '.issues | map(.code) | join(",")' bouncer_idle,hub_updates \
        '.bouncer.registered' true '.bouncer.last_pull' null
    cst_t "status/data after: the middleware file is in the stack's routes directory" '.enforcement.middleware_file | endswith("networking-security/crowdsec-bouncer.yml")'

    # -- an old CrowdSec: no native allowlists
    cst_world old traefik --traefik
    cst_call admin GET /crowdsec/status
    cst_j "status/old" '.state' healthy '.version_number' 1.6.5 '.allowlist_mechanism' parser '.features.allowlists' false '.features.decisions_import' true '.features.simulation' true \
        '.counts.decisions' 12

    # -- what the caller sees of its own address
    cst_world data traefik --traefik
    cst_call admin GET /crowdsec/status
    cst_j "status/client: the default caller is loopback" '.client_ip' 127.0.0.1 '.client_banned' false
    cst_call admin GET /crowdsec/status '' SOCAT_PEERADDR=91.240.118.11
    cst_j "status/client: a banned address" '.client_ip' 91.240.118.11 '.client_banned' true
    cst_call admin GET /crowdsec/status '' SOCAT_PEERADDR=192.0.2.130
    cst_j "status/client: an address inside a banned range" '.client_ip' 192.0.2.130 '.client_banned' true
    cst_call admin GET /crowdsec/status '' SOCAT_PEERADDR=78.128.113.9
    cst_j "status/client: a simulated ban does not count" '.client_banned' false
    cst_call admin GET /crowdsec/status '' SOCAT_PEERADDR=198.18.7.7
    cst_j "status/client: an address nobody banned" '.client_banned' false
    cst_call admin GET /crowdsec/status '' SOCAT_PEERADDR=2001:db8::99
    cst_j "status/client: IPv6 callers are answered" '.client_ip' 2001:db8::99 '.client_banned' false
    cst_call admin GET /crowdsec/status '' SOCAT_PEERADDR=not-an-address
    cst_j "status/client: a peer that is no address is never banned" '.client_banned' false

    # -- the trusted list rides along
    printf '{"ips":["198.18.20.1","198.18.21.0/24"]}\n' > "$CST/.data/crowdsec-trusted.json"
    cst_env CROWDSEC_TRUSTED_IPS 198.18.22.2
    cst_call admin GET /crowdsec/status
    cst_env CROWDSEC_TRUSTED_IPS
    cst_j "status/trusted" '.trusted | join(",")' 198.18.20.1,198.18.21.0/24,198.18.22.2
    rm -f "$CST/.data/crowdsec-trusted.json"

    # -- the short cache: a second look inside five seconds does not ask the stand-in again
    cst_mock --mock-init data --traefik
    cst_call admin GET /crowdsec/status
    n0=$(cst_calls_n)
    touch "$CST/.data/cache/crowdsec/status.json"
    cst_call admin GET /crowdsec/status
    n1=$(cst_calls_n)
    check "status/cache: the second call reads the cache (no docker call)" "$n0" "$n1"
    cst_j "status/cache: …and answers the same state" '.state' healthy
    cst_call admin POST /crowdsec/decisions '{"value":"198.18.30.1","duration":"1h"}'
    cst_call admin GET /crowdsec/status
    cst_j "status/cache: a ban empties the cache, the next look counts it" '.counts.decisions' 13
    cst_call viewer GET /crowdsec/status
    cst_is "status/viewer: may look" 200
    cst_j "status/viewer" '.state' healthy '.counts.decisions' 13
}

# ---- bans: the list, banning, lifting, importing, exporting --------------------------------------------------------------------------

# the row of a value in the current answer's "decisions"
cst_row() { printf '.decisions | map(select(.value == "%s"))[0]' "$1"; }

cst_bans_list() {
    local q10k p
    q10k=$(head -c 10000 /dev/zero | tr '\0' 'x')
    cst_world data traefik --traefik
    # everything that only reads, at once
    cst_q all admin GET /crowdsec/decisions
    cst_q viewer viewer GET /crowdsec/decisions
    cst_q sim-yes admin GET '/crowdsec/decisions?simulated=yes'
    cst_q sim-no admin GET '/crowdsec/decisions?simulated=no'
    cst_q sim-any admin GET '/crowdsec/decisions?simulated=any'
    cst_q scope-range admin GET '/crowdsec/decisions?scope=range'
    cst_q scope-ip admin GET '/crowdsec/decisions?scope=ip'
    cst_q scope-cap admin GET '/crowdsec/decisions?scope=Range'
    cst_q origin-cscli admin GET '/crowdsec/decisions?origin=cscli'
    cst_q origin-crowdsec admin GET '/crowdsec/decisions?origin=crowdsec'
    cst_q origin-capi admin GET '/crowdsec/decisions?origin=CAPI'
    cst_q origin-none admin GET '/crowdsec/decisions?origin=cscli-import'
    cst_q type-ban admin GET '/crowdsec/decisions?type=ban'
    cst_q type-captcha admin GET '/crowdsec/decisions?type=captcha'
    cst_q country-de admin GET '/crowdsec/decisions?country=DE'
    cst_q country-lower admin GET '/crowdsec/decisions?country=de'
    cst_q country-unknown admin GET '/crowdsec/decisions?country=unknown'
    cst_q scenario admin GET '/crowdsec/decisions?scenario=crowdsecurity/ssh-bf'
    cst_q q-ssh admin GET '/crowdsec/decisions?q=ssh'
    cst_q q-ip admin GET '/crowdsec/decisions?q=185.220'
    cst_q q-asn admin GET '/crowdsec/decisions?q=4134'
    cst_q q-country admin GET '/crowdsec/decisions?q=hk'
    cst_q q-none admin GET '/crowdsec/decisions?q=no-such-thing'
    cst_q q-huge admin GET "/crowdsec/decisions?q=$q10k"
    cst_q combo admin GET '/crowdsec/decisions?origin=crowdsec&country=de&simulated=no'
    cst_q sort-value admin GET '/crowdsec/decisions?sort=value&dir=asc'
    cst_q sort-value-desc admin GET '/crowdsec/decisions?sort=value&dir=desc'
    cst_q sort-expires admin GET '/crowdsec/decisions?sort=expires&dir=asc'
    cst_q sort-country admin GET '/crowdsec/decisions?sort=country&dir=asc'
    cst_q sort-scenario admin GET '/crowdsec/decisions?sort=scenario&dir=asc'
    cst_q sort-origin admin GET '/crowdsec/decisions?sort=origin&dir=asc'
    cst_q sort-created-asc admin GET '/crowdsec/decisions?sort=created&dir=asc'
    cst_q page-1 admin GET '/crowdsec/decisions?limit=5'
    cst_q page-3 admin GET '/crowdsec/decisions?limit=5&offset=10'
    cst_q page-far admin GET '/crowdsec/decisions?offset=999999'
    local -a bad=('limit=0' 'limit=2001' 'limit=abc' 'limit=-1' 'offset=abc' 'offset=1000000' 'sort=bogus' 'dir=up' 'scope=zone' 'type=Ban' 'origin=a%3Bb' 'country=ZZZ' 'country=1' 'scenario=x%3By' 'simulated=maybe')
    for p in "${!bad[@]}"; do cst_q "bad$p" admin GET "/crowdsec/decisions?${bad[$p]}"; done
    cst_run

    cst_use all
    cst_is "bans/list: answers" 200
    cst_j "bans/list" '.count' 12 '.total' 12 '.offset' 0 '.limit' 500 '.truncated' false '.community' 40 '.decisions | length' 12 \
        '.decisions | map(.origin == "CAPI") | any' false '.decisions[0].value' 192.0.2.66 '.decisions[-1].value' 194.26.135.7
    cst_j "bans/list: labels and flags" "$(cst_row 192.0.2.66).label" 'Manual ban' "$(cst_row 192.0.2.66).family" manual "$(cst_row 192.0.2.66).permanent" true \
        "$(cst_row 192.0.2.128/25).scope" Range "$(cst_row 192.0.2.128/25).permanent" false "$(cst_row 78.128.113.9).simulated" true "$(cst_row 116.31.116.24).country" CN \
        "$(cst_row 116.31.116.24).family" bruteforce "$(cst_row 194.26.135.7).family" exploit "$(cst_row 89.248.165.10).family" probe "$(cst_row 89.248.165.10).origin" crowdsec \
        "$(cst_row 116.31.116.24).as_number" 4134
    cst_t "bans/list: every row has what the table needs" '.decisions | all(has("id") and has("value") and has("scope") and has("type") and has("origin") and has("scenario") and has("seconds_left") and has("expires_at") and has("label") and has("family") and has("country"))'
    cst_t "bans/list: the countdown is a countdown" '.decisions | all(.seconds_left > 0) and (map(select(.value == "194.26.135.7"))[0].seconds_left | . > 1000 and . < 1700)'
    cst_j "bans/list: facets" '.facets.origins | map("\(.value):\(.count)") | join(",")' crowdsec:9,cscli:3 '.facets.types | map("\(.value):\(.count)") | join(",")' ban:12 \
        '.facets.scopes | map("\(.value):\(.count)") | join(",")' Ip:11,Range:1 '.facets.countries[0] | "\(.value):\(.count)"' DE:2 '.facets.countries | length' 8 '.facets.unknown_country' 3 \
        '.facets.scenarios | length' 9
    cst_use viewer;         cst_is "bans/list: a viewer may read it" 200
    cst_use sim-yes;        cst_j "bans/list: simulated=yes" '.count' 1 '.decisions[0].value' 78.128.113.9
    cst_use sim-no;         cst_j "bans/list: simulated=no" '.count' 11 '.decisions | map(.simulated) | any' false
    cst_use sim-any;        cst_j "bans/list: simulated=any" '.count' 12
    cst_use scope-range;    cst_j "bans/list: scope=range" '.count' 1 '.decisions[0].value' 192.0.2.128/25
    cst_use scope-ip;       cst_j "bans/list: scope=ip" '.count' 11
    cst_use scope-cap;      cst_j "bans/list: scope=Range is the same" '.count' 1
    cst_use origin-cscli;   cst_j "bans/list: origin=cscli" '.count' 3 '.decisions | map(.label) | unique | join(",")' 'Manual ban'
    cst_use origin-crowdsec; cst_j "bans/list: origin=crowdsec" '.count' 9
    cst_use origin-capi;    cst_j "bans/list: origin=CAPI shows the community list" '.count' 40 '.decisions | map(.family) | unique | join(",")' community '.decisions[0].label' 'Community blocklist' \
        '.decisions | length' 40
    cst_use origin-none;    cst_j "bans/list: an origin nobody used" '.count' 0
    cst_use type-ban;       cst_j "bans/list: type=ban" '.count' 12
    cst_use type-captcha;   cst_j "bans/list: type=captcha" '.count' 0
    cst_use country-de;     cst_j "bans/list: country=DE" '.count' 2 '.decisions | map(.value) | sort | join(",")' 185.220.101.5,45.83.64.20
    cst_use country-lower;  cst_j "bans/list: country=de" '.count' 2
    cst_use country-unknown; cst_j "bans/list: country=unknown" '.count' 3 '.decisions | map(.value) | sort | join(",")' 192.0.2.10,192.0.2.128/25,192.0.2.66
    cst_use scenario;       cst_j "bans/list: scenario=" '.count' 1 '.decisions[0].value' 116.31.116.24
    cst_use q-ssh;          cst_j "bans/list: q=ssh" '.count' 2
    cst_use q-ip;           cst_j "bans/list: q= part of an address" '.count' 1 '.decisions[0].value' 185.220.101.5
    cst_use q-asn;          cst_j "bans/list: q= an AS number" '.count' 1 '.decisions[0].value' 116.31.116.24
    cst_use q-country;      cst_j "bans/list: q= a country code, any case" '.count' 1 '.decisions[0].value' 91.240.118.11
    cst_use q-none;         cst_j "bans/list: q= nothing" '.count' 0 '.decisions | length' 0
    cst_use q-huge;         cst_is "bans/list: a 10 kB search text is cut, not refused" 200
    cst_use combo;          cst_j "bans/list: filters add up" '.count' 2
    cst_use sort-value;     cst_j "bans/list: sort by value" '.decisions[0].value' 116.31.116.24 '.decisions[-1].value' 91.240.118.11
    cst_use sort-value-desc; cst_j "bans/list: …descending" '.decisions[0].value' 91.240.118.11
    cst_use sort-expires;   cst_j "bans/list: sort by expiry" '.decisions[0].value' 194.26.135.7 '.decisions[-1].value' 192.0.2.66
    cst_use sort-country;   cst_j "bans/list: sort by country" '.decisions[0].country' '' '.decisions[-1].country' US
    cst_use sort-scenario;  cst_j "bans/list: sort by scenario" '.decisions[0].scenario' crowdsecurity/CVE-2017-9841 '.decisions[-1].scenario' 'range ban'
    cst_use sort-origin;    cst_j "bans/list: sort by origin" '.decisions[0].origin' crowdsec '.decisions[-1].origin' cscli
    cst_use sort-created-asc; cst_j "bans/list: oldest first" '.decisions[0].value' 194.26.135.7 '.decisions[-1].value' 192.0.2.66
    cst_use page-1;         cst_j "bans/list: a page" '.count' 12 '.limit' 5 '.offset' 0 '.decisions | length' 5
    cst_use page-3;         cst_j "bans/list: the last page" '.offset' 10 '.decisions | length' 2 '.decisions[-1].value' 194.26.135.7
    cst_use page-far;       cst_j "bans/list: beyond the end" '.count' 12 '.decisions | length' 0
    for p in "${!bad[@]}"; do cst_use "bad$p"; cst_is "bans/list: ?${bad[$p]} is refused" 400; done
}

# every way a ban can be refused, sent at once: none of them may create a ban
cst_bans_refusals() {
    local pair label body code why i
    cst_world data traefik --traefik
    printf '{"public_ip":"198.51.100.77","home_ipv6":"2001:db8:77:5::/64"}\n' > "$CST/.data/crowdsec-whitelist.json"   # the home addresses DCS follows (IPv4, the IPv6 network)
    printf '{"ips":["198.18.99.5","198.19.0.0/24"]}\n' > "$CST/.data/crowdsec-trusted.json"     # the trusted list
    printf '198.51.100.78\n' > "$CST/.data/ddns-current-ip"                                      # what the DDNS loop last saw
    # label|body|status|reason (empty: any) — the caller is 203.0.113.99 in every one of them
    local -a cases=(
        'garbage|{"value":"garbage"}|400|'
        'empty|{"value":""}|400|'
        'missing|{}|400|'
        'number|{"value":12345}|400|'
        'list|{"value":["198.18.0.9"]}|400|'
        'spaces|{"value":"  198.18.0.9  "}|400|'
        'two|{"value":"198.18.0.9\n198.18.0.10"}|400|'
        'semicolon|{"value":"198.18.0.9;id"}|400|'
        'octets|{"value":"1.2.3.256"}|400|'
        'three octets|{"value":"1.2.3"}|400|'
        'five octets|{"value":"1.2.3.4.5"}|400|'
        'leading zero|{"value":"010.1.1.1"}|400|'
        'zone id|{"value":"fe80::1%eth0"}|400|'
        'v6 too long|{"value":"1:2:3:4:5:6:7:8:9"}|400|'
        'v6 two ::|{"value":"1::2::3"}|400|'
        'v6 bad digit|{"value":"2a00::g"}|400|'
        'prefix 33|{"value":"198.18.0.0/33"}|400|'
        'prefix -1|{"value":"198.18.0.0/-1"}|400|'
        'prefix 08|{"value":"198.18.0.0/08"}|400|'
        'prefix empty|{"value":"198.18.0.0/"}|400|'
        'prefix v6 129|{"value":"2a00::/129"}|400|'
        'v4 everything|{"value":"0.0.0.0/0"}|400|too_broad'
        'v4 /7|{"value":"1.0.0.0/7"}|400|too_broad'
        'v6 everything|{"value":"::/0"}|400|too_broad'
        'v6 /3|{"value":"2000::/3"}|400|too_broad'
        'v6 /15|{"value":"2a00::/15"}|400|too_broad'
        'private 10|{"value":"10.1.2.3"}|400|private'
        'private 172|{"value":"172.16.5.5"}|400|private'
        'private 192|{"value":"192.168.1.1"}|400|private'
        'loopback|{"value":"127.0.0.1"}|400|private'
        'link-local|{"value":"169.254.1.1"}|400|private'
        'cgnat|{"value":"100.64.0.1"}|400|private'
        'this network|{"value":"0.1.2.3"}|400|private'
        'private range|{"value":"10.0.0.0/8"}|400|private'
        'v6 unspecified|{"value":"::"}|400|private'
        'v6 loopback|{"value":"::1"}|400|private'
        'v6 unique local|{"value":"fc00::1"}|400|private'
        'v6 link-local|{"value":"fe80::1"}|400|private'
        'own|{"value":"203.0.113.99"}|400|own'
        'own inside a range|{"value":"203.0.113.64/26"}|400|own'
        'own /8|{"value":"203.0.0.0/8"}|400|own'
        'server|{"value":"203.0.113.250"}|400|server'
        'server inside a range|{"value":"203.0.113.192/26"}|400|server'
        'home|{"value":"198.51.100.77"}|400|home'
        'home inside a range|{"value":"198.51.100.0/24"}|400|home'
        'home the DDNS saw|{"value":"198.51.100.78"}|400|home'
        'home IPv6 network|{"value":"2001:db8:77:5:1c2d::9"}|400|home'
        'home IPv6 network, upper case|{"value":"2001:DB8:77:5::A"}|400|home'
        'trusted|{"value":"198.18.99.5"}|400|trusted'
        'trusted range|{"value":"198.19.0.77"}|400|trusted'
        'trusted inside a range|{"value":"198.19.0.0/16"}|400|trusted'
        'allowlisted|{"value":"203.0.113.9"}|409|allowlisted'
        'allowlisted range member|{"value":"198.51.100.5","duration":"1h"}|409|allowlisted'
        'allowlisted v6|{"value":"2001:db8:1::5"}|409|allowlisted'
        'duration junk|{"value":"198.18.0.9","duration":"5x"}|400|'
        'duration words|{"value":"198.18.0.9","duration":"4hours"}|400|'
        'duration 30s|{"value":"198.18.0.9","duration":"30s"}|400|'
        'duration 59s|{"value":"198.18.0.9","duration":"59s"}|400|'
        'duration years|{"value":"198.18.0.9","duration":"11y"}|400|'
        'duration 3651d|{"value":"198.18.0.9","duration":"3651d"}|400|'
        'duration negative|{"value":"198.18.0.9","duration":-1}|400|'
        'duration number|{"value":"198.18.0.9","duration":3600}|400|'
        'duration long|{"value":"198.18.0.9","duration":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}|400|'
        'duration sign|{"value":"198.18.0.9","duration":"+4h"}|400|'
        'duration $()|{"value":"198.18.0.9","duration":"$(id)"}|400|'
        'not json|not json|400|'
        'json list|[1,2]|400|'
        'json null|null|400|'
        'json string|"198.18.0.9"|400|'
    )
    i=0
    for pair in "${cases[@]}"; do
        IFS='|' read -r label body code why <<< "$pair"
        cst_q "r$(( ++i ))" admin POST /crowdsec/decisions "$body" SOCAT_PEERADDR=203.0.113.99
    done
    cst_q rbody admin POST /crowdsec/decisions ''
    cst_q rviewer viewer POST /crowdsec/decisions '{"value":"198.18.0.9"}'
    cst_q rnobody none POST /crowdsec/decisions '{"value":"198.18.0.9"}'
    cst_run
    i=0
    for pair in "${cases[@]}"; do
        IFS='|' read -r label body code why <<< "$pair"
        cst_use "r$(( ++i ))"
        cst_is "bans/refuse: $label" "$code"
        [[ -z "$why" ]] || cst_j "bans/refuse: $label says why" '.reason' "$why"
    done
    cst_use rbody;   cst_is "bans/refuse: an empty body" 400
    cst_use rviewer; cst_is "bans/refuse: a viewer" 403
    cst_use rnobody; cst_is "bans/refuse: nobody" 401
    cst_call admin GET '/crowdsec/decisions?limit=1'
    cst_j "bans/refuse: nothing was banned by any of them" '.count' 12
    # the language of the server does not change what an address is (in en_US.UTF-8 a bash range like [a-f] also matches ä)
    if locale -a 2>/dev/null | grep -qi '^en_US\.utf-\?8$'; then
        cst_call admin POST /crowdsec/decisions '{"value":"2a00::ä"}' LC_ALL=en_US.UTF-8
        cst_is "bans/refuse: an IPv6 address with an accented letter, on a server that speaks en_US" 400
        cst_call admin POST /crowdsec/decisions '{"value":"2a00:١::1"}' LC_ALL=en_US.UTF-8
        cst_is "bans/refuse: …and one with an Arabic-Indic digit" 400
        cst_call admin GET '/crowdsec/decisions?limit=1'
        cst_j "bans/refuse: …nothing was banned" '.count' 12
    fi
    # the guard is not fooled by another spelling of the same address (::ffff:a.b.c.d is the IPv4 address a.b.c.d to CrowdSec)
    cst_q mown admin POST /crowdsec/decisions '{"value":"::ffff:203.0.113.99"}' SOCAT_PEERADDR=203.0.113.99
    cst_q mhex admin POST /crowdsec/decisions '{"value":"::ffff:cb00:7163"}' SOCAT_PEERADDR=203.0.113.99
    cst_q mprivate admin POST /crowdsec/decisions '{"value":"::ffff:10.0.0.1"}'
    cst_q mhome admin POST /crowdsec/decisions '{"value":"::ffff:198.51.100.77"}'
    cst_q mserver admin POST /crowdsec/decisions '{"value":"::ffff:203.0.113.250"}'
    cst_run
    for label in own hex private home server; do cst_use "m$label"; cst_is "bans/refuse: the IPv4-mapped spelling ($label)" 400; done
    cst_call admin GET '/crowdsec/decisions?limit=1'
    cst_j "bans/refuse: …and nothing was banned" '.count' 12
}

cst_bans_add() {
    local mark words now q300 i argv line
    cst_world data traefik --traefik
    mark=$(cst_argv_n)
    now=$(date +%s)
    # -- lengths, spellings and answers
    cst_call admin POST /crowdsec/decisions '{"value":"203.0.113.7","duration":"90m","reason":"scanner"}'
    cst_is "bans/add: an address for 90 minutes" 200
    cst_j "bans/add: the answer" '.success' true '.value' 203.0.113.7 '.scope' Ip '.duration' 90m '.reason' scanner '.permanent' false '.replaced' 0
    cst_t "bans/add: …says when it ends" "(.expires_at | fromdateiso8601) - $now | . > 5300 and . < 5600"
    words=$(cst_argv_since "$mark" | grep -F ' decisions add ' | head -n 1 | { read -r line; eval "argv=($line)"; echo "${#argv[@]}"; })
    check "bans/add: cscli got 12 separate arguments" 12 "$words"
    cst_call admin POST /crowdsec/decisions '{"value":"203.0.113.8"}'
    cst_j "bans/add: no length means the default" '.duration' 4h '.reason' 'Banned from DCS by admin'
    cst_call admin POST /crowdsec/decisions '{"value":"203.0.113.10","duration":"7d"}'
    cst_j "bans/add: 7d" '.duration' 168h
    cst_call admin POST /crowdsec/decisions '{"value":"203.0.113.11","permanent":true}'
    cst_j "bans/add: permanent" '.duration' 87600h '.permanent' true
    cst_call admin POST /crowdsec/decisions '{"value":"203.0.113.12","duration":"2w"}'
    cst_j "bans/add: 2w" '.duration' 336h
    cst_call admin POST /crowdsec/decisions '{"value":"203.0.113.13","duration":"1h30m"}'
    cst_j "bans/add: 1h30m" '.duration' 90m
    cst_call admin POST /crowdsec/decisions '{"value":"203.0.113.14","duration":" 4 H "}'
    cst_j "bans/add: spaces and capitals are forgiven" '.duration' 4h
    cst_call admin POST /crowdsec/decisions '{"value":"203.0.113.15","duration":"60s"}'
    cst_j "bans/add: a minute is the shortest" '.duration' 1m
    cst_call admin POST /crowdsec/decisions '{"value":"203.0.113.16","duration":"3650d"}'
    cst_j "bans/add: ten years is the longest" '.duration' 87600h
    cst_call admin POST /crowdsec/decisions '{"value":"203.0.113.17","permanent":true,"duration":"1h"}'
    cst_j "bans/add: permanent wins over a length" '.duration' 87600h
    cst_call admin POST /crowdsec/decisions '{"value":"203.0.113.18","permanent":"yes"}'
    cst_j "bans/add: only a real true is permanent" '.duration' 4h
    cst_call admin POST /crowdsec/decisions '{"ip":"203.0.113.19"}'
    cst_j "bans/add: ip is accepted for value" '.value' 203.0.113.19
    cst_call admin POST /crowdsec/decisions '{"range":"198.18.67.0/24"}'
    cst_j "bans/add: range is accepted for value" '.value' 198.18.67.0/24 '.scope' Range
    cst_call admin POST /crowdsec/decisions '{"value":"2A00:1450:4001:0000:0000:0000:0000:0002","duration":"1h"}'
    cst_j "bans/add: an IPv6 address is written short" '.value' 2a00:1450:4001::2 '.scope' Ip
    cst_call admin POST /crowdsec/decisions '{"value":"198.18.44.5/24"}'
    cst_j "bans/add: a network loses its host bits" '.value' 198.18.44.0/24 '.scope' Range
    cst_call admin POST /crowdsec/decisions '{"value":"198.18.55.5/32"}'
    cst_j "bans/add: a /32 is an address" '.value' 198.18.55.5 '.scope' Ip
    cst_call admin POST /crowdsec/decisions '{"value":"::ffff:198.18.56.7"}'
    cst_j "bans/add: an IPv4-mapped IPv6 address is the IPv4 address (that is what Traefik sees)" '.value' 198.18.56.7 '.scope' Ip
    cst_call admin POST /crowdsec/decisions '{"value":"::ffff:198.18.57.0/120"}'
    cst_j "bans/add: …and so is a network of them" '.value' 198.18.57.0/24 '.scope' Range
    cst_call admin POST /crowdsec/decisions '{"value":"2a00:1450::/32"}'
    cst_j "bans/add: an IPv6 network" '.value' 2a00:1450::/32 '.scope' Range
    cst_call admin POST /crowdsec/decisions '{"value":"2a00:1450:4001::7/128"}'
    cst_j "bans/add: a /128 is an address" '.value' 2a00:1450:4001::7 '.scope' Ip
    # -- a ban that exists is replaced only by a longer one
    cst_call admin POST /crowdsec/decisions '{"value":"203.0.113.7","duration":"3h"}'
    cst_is "bans/add: a longer ban replaces the old one" 200
    cst_j "bans/add: …and says so" '.replaced' 1 '.duration' 3h
    cst_call admin POST /crowdsec/decisions '{"value":"203.0.113.7","duration":"30m"}'
    cst_is "bans/add: a shorter one is refused" 409
    cst_j "bans/add: …with the reason and what is left" '.reason' already_banned '.seconds_left > 10000' true
    cst_call admin POST /crowdsec/decisions '{"value":"203.0.113.7","duration":"3h"}'
    cst_is "bans/add: one as long as it was starts the clock again" 200
    cst_j "bans/add: …it replaced the old one" '.replaced' 1
    cst_call admin GET '/crowdsec/decisions?q=203.0.113.7'
    cst_j "bans/add: one row for the address, not two" '.count' 1 '.decisions[0].seconds_left > 10000' true
    # -- the reason
    cst_call admin POST /crowdsec/decisions "$(jq -nc '{value: "203.0.113.20", reason: "a\u0001b\tc\nd\u007fe"}')"
    cst_j "bans/add: control characters leave the reason" '.reason' 'ab c de'
    q300=$(head -c 300 /dev/zero | tr '\0' 'x')
    cst_call admin POST /crowdsec/decisions "$(jq -nc --arg r "$q300" '{value: "203.0.113.21", reason: $r}')"
    cst_j "bans/add: a long reason is cut to 200 characters" '.reason | length' 200
    cst_call admin POST /crowdsec/decisions "$(jq -nc '{value: "203.0.113.22", reason: "  Überfall — 🛡️ blocked  "}')"
    cst_j "bans/add: a reason keeps its letters and is trimmed" '.reason' 'Überfall — 🛡️ blocked'
    cst_call admin POST /crowdsec/decisions "$(jq -nc '{value: "203.0.113.23", reason: 12345}')"
    cst_j "bans/add: a number is text too" '.reason' 12345
    cst_call admin GET '/crowdsec/decisions?limit=100'
    cst_j "bans/add: the list shows them" '.count' 36 \
        "$(cst_row 203.0.113.7).scenario" 'Banned from DCS by admin' "$(cst_row 203.0.113.7).label" 'Manual ban' "$(cst_row 203.0.113.7).origin" cscli "$(cst_row 203.0.113.11).permanent" true \
        "$(cst_row 203.0.113.20).scenario" 'ab c de' "$(cst_row 198.18.44.0/24).scope" Range "$(cst_row 2a00:1450:4001::2).scope" Ip
    cst_t "bans/add: …with the time they were given" "$(cst_row 203.0.113.10).seconds_left | . > 604000 and . < 604800"
    cst_call admin POST /crowdsec/decisions '{"value":"203.0.113.30","duration":"4h"}' SOCAT_PEERADDR=198.18.7.7
    cst_is "bans/add: a caller who is not the address may ban it" 200
    # -- what a ban leaves behind
    check "bans/add: every ban is in the audit log" 1 "$(grep -c '"action":"auth.crowdsec_ban".*203.0.113.30' "$CST/.data/audit.jsonl")"
    i=$(cst_audit_n '"action":"auth.crowdsec_ban"')
    cst_call admin POST /crowdsec/decisions '{"value":"10.9.8.7"}'
    check "bans/add: a ban that was refused is not" "$i" "$(cst_audit_n '"action":"auth.crowdsec_ban"')"
}

cst_part_large() {
    echo "CrowdSec page: thousands of bans"
    cst_bans_large
}

cst_bans_lift() {
    local ids i
    cst_world data traefik --traefik
    cst_call admin DELETE /crowdsec/decisions/91.240.118.11
    cst_is "bans/lift: an address" 200
    cst_j "bans/lift" '.success' true '.value' 91.240.118.11 '.scope' Ip '.deleted >= 1' true
    cst_call admin GET '/crowdsec/decisions?q=91.240.118.11'
    cst_j "bans/lift: …the list has no ban on it any more" '.count' 0
    cst_call admin DELETE /crowdsec/decisions/91.240.118.11
    cst_is "bans/lift: twice" 200
    cst_j "bans/lift: …the second time nothing is left" '.deleted' 0 '.message | test("No active ban")' true
    cst_call admin DELETE /crowdsec/decisions/192.0.2.128/25
    cst_j "bans/lift: a network, with the slash in the path" '.scope' Range '.value' 192.0.2.128/25 '.deleted' 1
    cst_call admin DELETE /crowdsec/decisions/192.0.2.66
    cst_j "bans/lift: a permanent ban" '.deleted' 1
    cst_call admin DELETE /crowdsec/decisions/45.83.64.20/32
    cst_j "bans/lift: a /32 is the address" '.value' 45.83.64.20 '.scope' Ip '.deleted' 1
    cst_call admin DELETE /crowdsec/decisions/198.18.9.9/
    cst_is "bans/lift: an address nobody banned is not an error (a slash at the end is ignored)" 200
    cst_j "bans/lift: …it is 0 lifted" '.deleted' 0
    cst_call admin POST /crowdsec/decisions '{"value":"2a00:1450:4001::9"}'
    cst_call admin DELETE /crowdsec/decisions/2A00:1450:4001:0:0:0:0:9
    cst_j "bans/lift: an IPv6 address in another spelling" '.value' 2a00:1450:4001::9 '.deleted' 1
    # -- exactly the ban that was asked for: a network that holds the address stays (cscli's own --ip would lift it too)
    cst_call admin POST /crowdsec/decisions '{"value":"2001:4860::/32","duration":"4h"}'
    cst_call admin POST /crowdsec/decisions '{"value":"2001:4860:4860::8888","duration":"4h"}'
    cst_call admin POST /crowdsec/decisions '{"value":"198.18.100.0/24","duration":"4h"}'
    cst_call admin DELETE /crowdsec/decisions/2001:4860:4860::8888
    cst_j "bans/lift exactly: the address only" '.deleted' 1 '.scope' Ip
    cst_call admin GET '/crowdsec/decisions?q=2001:4860'
    cst_j "bans/lift exactly: …the network that holds it is still banned" '.count' 1 '.decisions[0].value' 2001:4860::/32
    cst_call admin DELETE /crowdsec/decisions/198.18.100.7
    cst_is "bans/lift exactly: an address that is only inside a banned network" 200
    cst_j "bans/lift exactly: …there is no ban on it to lift" '.deleted' 0 '.message | test("No active ban")' true
    cst_call admin GET '/crowdsec/decisions?q=198.18.100.0'
    cst_j "bans/lift exactly: …the network stays" '.count' 1
    cst_call admin POST /crowdsec/decisions '{"value":"198.18.100.7","duration":"1h"}'
    cst_call admin POST /crowdsec/decisions '{"value":"198.18.100.7","duration":"3h"}'
    cst_j "bans/lift exactly: a longer ban on an address inside a network replaces only that address's ban" '.replaced' 1
    cst_call admin GET '/crowdsec/decisions?q=198.18.100.&limit=10'
    cst_j "bans/lift exactly: …the network is still there, and the address once" '.count' 2 '.decisions | map(.value) | sort | join(",")' 198.18.100.0/24,198.18.100.7
    cst_call admin DELETE /crowdsec/decisions/2001:4860::/32
    cst_j "bans/lift exactly: the network itself" '.deleted' 1 '.scope' Range
    cst_call admin POST /crowdsec/decisions/delete '{"values":["198.18.100.7"]}'
    cst_j "bans/lift exactly: the same for the list of values" '.deleted' 1
    cst_call admin GET '/crowdsec/decisions?q=198.18.100.&limit=10'
    cst_j "bans/lift exactly: …the network holding it is left" '.count' 1 '.decisions[0].value' 198.18.100.0/24
    cst_call admin DELETE /crowdsec/decisions/198.18.100.0/24
    cst_call admin GET '/crowdsec/decisions?limit=100'
    cst_j "bans/lift: the list lost exactly those" '.count' 8 "$(cst_row 91.240.118.11)" null "$(cst_row 192.0.2.66)" null
    local -a bad=(garbage 999.1.1.1 45.83.64.20/33 1.2.3.4//24 010.1.1.1 'fe80::1%25eth0' '%2e%2e' '1.2.3.4%2f24' 'a;id' '$(id)' '`id`' '1.2.3.4|id' '1.2.3.4&&id')
    for i in "${!bad[@]}"; do cst_q "l$i" admin DELETE "/crowdsec/decisions/${bad[$i]}"; done
    cst_q llong admin DELETE "/crowdsec/decisions/$(head -c 300 /dev/zero | tr '\0' '1')"
    cst_q lnone admin DELETE /crowdsec/decisions
    cst_q lviewer viewer DELETE /crowdsec/decisions/198.18.9.9
    cst_q lnobody none DELETE /crowdsec/decisions/198.18.9.9
    cst_run
    for i in "${!bad[@]}"; do cst_use "l$i"; cst_is "bans/lift: ${bad[$i]} is refused" 400; done
    cst_use llong;   cst_is "bans/lift: 300 digits are refused" 400
    cst_use lnone;   cst_is "bans/lift: no value is no route" 404
    cst_use lviewer; cst_is "bans/lift: a viewer may not" 403
    cst_use lnobody; cst_is "bans/lift: nobody may not" 401

    # -- several at once
    cst_world data traefik --traefik
    cst_call admin GET '/crowdsec/decisions?limit=100'
    ids=$(jq -c '[.decisions[] | select(.value == "194.26.135.7" or .value == "187.19.152.10") | .id]' <<< "$CST_BODY")
    cst_call admin POST /crowdsec/decisions/delete "{\"ids\": $ids}"
    cst_is "bans/lift many: by decision id" 200
    cst_j "bans/lift many" '.success' true '.requested' 2 '.deleted' 2 '.failed' 0 '.results | map(.ok) | all' true
    cst_call admin POST /crowdsec/decisions/delete '{"values":["89.248.165.10","192.0.2.128/25"]}'
    cst_j "bans/lift many: by address and network" '.success' true '.requested' 2 '.deleted' 2
    cst_call admin POST /crowdsec/decisions/delete '{"ids":["15025", 999999, "abc", 1.5, null, 12345678901234],"values":["nope","198.18.0.1","116.31.116.24"]}'
    cst_is "bans/lift many: a mix of good and bad is an answer" 200
    cst_j "bans/lift many: the bad ones are listed one by one" '.success' false '.requested' 9 '.failed' 6 '.deleted' 2 '.results | length' 9 \
        '.results[0].ok' true '.results[1].ok' false '.results[1].error | test("doesn.t exist")' true '.results[2].error' 'not a decision id' '.results[8].value' 116.31.116.24
    cst_t "bans/lift many: …an unknown address is fine" '.results | map(select(.value == "198.18.0.1"))[0] | .ok and .deleted == 0'
    cst_call admin POST /crowdsec/decisions/delete '{}'
    cst_is "bans/lift many: nothing to do" 400
    cst_call admin POST /crowdsec/decisions/delete '{"ids":"5"}'
    cst_is "bans/lift many: ids must be a list" 400
    cst_call admin POST /crowdsec/decisions/delete '{"values":{"a":1}}'
    cst_is "bans/lift many: values must be a list" 400
    cst_call admin POST /crowdsec/decisions/delete 'x'
    cst_is "bans/lift many: not JSON" 400
    cst_call admin POST /crowdsec/decisions/delete "{\"values\":[$(seq -f '"x%g"' -s, 1 201 | sed 's/,$//')]}"
    cst_is "bans/lift many: 201 is too many" 400
    cst_call admin POST /crowdsec/decisions/delete "{\"values\":[$(seq -f '"x%g"' -s, 1 200 | sed 's/,$//')]}"
    cst_is "bans/lift many: 200 is the limit" 200
    cst_j "bans/lift many: 200 that are all wrong" '.requested' 200 '.failed' 200 '.deleted' 0
    cst_call viewer POST /crowdsec/decisions/delete '{"values":["198.18.0.1"]}'
    cst_is "bans/lift many: a viewer may not" 403
}

cst_bans_import() {
    local BOM=$'\xef\xbb\xbf' body i big
    cst_world data traefik --traefik
    printf '{"public_ip":"198.51.100.77"}\n' > "$CST/.data/crowdsec-whitelist.json"
    # -- one address per line: comments, blank lines, tabs and networks are fine
    body=$(jq -nc --arg c $'198.18.0.1\n198.18.0.2 # a comment\n\n# a whole line of comment\n   198.18.1.0/24\twith a note\n2a00:1450:4001::77\n' '{format: "values", content: $c}')
    cst_call admin POST /crowdsec/decisions/import "$body"
    cst_is "bans/import: one address per line" 200
    cst_j "bans/import: values" '.success' true '.format' values '.total' 4 '.imported' 4 '.skipped' 0 '.allowlisted' 0 '.error' null
    cst_call admin GET '/crowdsec/decisions?origin=cscli-import&limit=50'
    cst_j "bans/import: they are listed as imported bans" '.count' 4 '.decisions | map(.label) | unique | join(",")' 'Imported ban' '.decisions | map(.scenario) | unique | join(",")' 'Imported from DCS' \
        '.decisions | map(.family) | unique | join(",")' manual
    cst_t "bans/import: …for the default four hours" '.decisions | all(.seconds_left > 14300 and .seconds_left <= 14400)'
    # -- every way an entry is left out, and the ones that were not
    body=$(jq -nc --arg c $'198.18.0.1\n198.18.5.5\nbogus\n10.0.0.1\n198.18.5.5\n203.0.113.9\n91.240.118.11\n0.0.0.0/0\n198.18.6.6/24\n198.18.7.7\n' '{format: "values", content: $c}')
    cst_call admin POST /crowdsec/decisions/import "$body" SOCAT_PEERADDR=198.18.7.7
    cst_j "bans/import: a list with problems" '.success' true '.total' 10 '.imported' 2 '.skipped' 7 '.allowlisted' 1 \
        '.skipped_entries | map("\(.line):\(.reason)") | join(",")' 1:already_banned,3:invalid,4:private,5:duplicate,7:already_banned,8:too_broad,10:own \
        '.skipped_entries[1].value' bogus '.skipped_entries[2].message | length > 10' true
    cst_call admin GET '/crowdsec/decisions?q=198.18.6'
    cst_j "bans/import: a network lost its host bits" '.decisions[0].value' 198.18.6.0/24
    # -- CSV: a header line, quotes, a length and a reason per row
    body=$(jq -nc --arg c $'value,duration,reason\n198.18.20.1,2h,csv one\n198.18.20.2,,csv two\n"198.18.20.3",5x,bad length\n198.18.20.4,1d,"with, a comma and ""quotes"""\n' '{format: "csv", content: $c}')
    cst_call admin POST /crowdsec/decisions/import "$body"
    cst_j "bans/import: csv" '.total' 4 '.imported' 3 '.skipped_entries | map("\(.line):\(.value):\(.reason)") | join(",")' 3:198.18.20.3:duration
    cst_call admin GET '/crowdsec/decisions?q=198.18.20.&limit=20'
    cst_t "bans/import: csv rows keep their own length" "$(cst_row 198.18.20.1).seconds_left | . > 7100 and . <= 7200"
    cst_t "bans/import: …and the default when they have none" "$(cst_row 198.18.20.2).seconds_left | . > 14300 and . <= 14400"
    cst_j "bans/import: …and their reason, commas and quotes included" "$(cst_row 198.18.20.1).scenario" 'csv one' "$(cst_row 198.18.20.4).scenario" 'with, a comma and "quotes"'
    # -- JSON: a list, or an object that holds the list
    body=$(jq -nc --arg c '[{"value":"198.18.30.1","duration":"3h","reason":"j1"},{"ip":"198.18.30.2"},{"range":"198.18.31.0/24"},{"type":"captcha","value":"198.18.30.3"},"198.18.30.4"]' '{format: "json", content: $c}')
    cst_call admin POST /crowdsec/decisions/import "$body"
    cst_j "bans/import: json" '.total' 4 '.imported' 3 '.skipped' 1 '.skipped_entries[0].reason' type '.skipped_entries[0].value' 198.18.30.3
    body=$(jq -nc --arg c '{"decisions":[{"value":"198.18.32.1"},{"value":"198.18.32.2","type":"captcha"}]}' '{format: "json", content: $c}')
    cst_call admin POST /crowdsec/decisions/import "$body"
    cst_j "bans/import: json object with decisions, only bans are imported" '.total' 2 '.imported' 1 '.skipped_entries[0].reason' type
    # -- the format is found by itself
    body=$(jq -nc --arg c '[{"value":"198.18.33.1"}]' '{format: "auto", content: $c}')
    cst_call admin POST /crowdsec/decisions/import "$body"
    cst_j "bans/import: auto finds json" '.imported' 1
    body=$(jq -nc --arg c $'value,reason\n198.18.33.2,x\n' '{content: $c}')
    cst_call admin POST /crowdsec/decisions/import "$body"
    cst_j "bans/import: auto finds csv (and is the default)" '.imported' 1 '.format' auto
    body=$(jq -nc --arg c $'198.18.33.3\n198.18.33.4,note\n' '{format: "auto", content: $c}')
    cst_call admin POST /crowdsec/decisions/import "$body"
    cst_j "bans/import: auto finds a plain list" '.imported' 1 '.skipped' 1
    # -- one length and one reason for the whole file, or forever
    body=$(jq -nc --arg c $'198.18.34.1\n198.18.34.2\n' '{format: "values", content: $c, duration: "12h", reason: "blocklist of the week"}')
    cst_call admin POST /crowdsec/decisions/import "$body"
    cst_call admin GET '/crowdsec/decisions?q=198.18.34.1'
    cst_j "bans/import: a length and a reason for the file" "$(cst_row 198.18.34.1).scenario" 'blocklist of the week' "$(cst_row 198.18.34.1).seconds_left > 43100" true
    body=$(jq -nc --arg c $'198.18.35.1\n' '{format: "values", content: $c, permanent: true}')
    cst_call admin POST /crowdsec/decisions/import "$body"
    cst_call admin GET '/crowdsec/decisions?q=198.18.35.1'
    cst_j "bans/import: permanent" "$(cst_row 198.18.35.1).permanent" true
    # -- files as programs write them: a byte order mark, Windows line ends
    body=$(jq -nc --arg c "${BOM}198.18.40.1"$'\r\n198.18.40.2\r\n' '{format: "values", content: $c}')
    cst_call admin POST /crowdsec/decisions/import "$body"
    cst_j "bans/import: a byte order mark and CRLF (values)" '.total' 2 '.imported' 2 '.skipped' 0
    body=$(jq -nc --arg c "${BOM}value,reason"$'\r\n198.18.41.1,a b\r\n198.18.41.2,c\r\n' '{format: "csv", content: $c}')
    cst_call admin POST /crowdsec/decisions/import "$body"
    cst_j "bans/import: a byte order mark and CRLF (csv)" '.total' 2 '.imported' 2 '.skipped' 0
    body=$(jq -nc --arg c "${BOM}value,reason"$'\r\n198.18.42.1,a b\r\n' '{format: "auto", content: $c}')
    cst_call admin POST /crowdsec/decisions/import "$body"
    cst_j "bans/import: a byte order mark and CRLF (auto)" '.total' 1 '.imported' 1
    body=$(jq -nc --arg c "${BOM}[{\"value\":\"198.18.43.1\"}]"$'\r\n' '{format: "auto", content: $c}')
    cst_call admin POST /crowdsec/decisions/import "$body"
    cst_j "bans/import: a byte order mark and CRLF (json)" '.total' 1 '.imported' 1
    # -- what is refused before anything happens
    cst_call admin POST /crowdsec/decisions/import '{"format":"values","content":""}'
    cst_is "bans/import: nothing to import" 400
    cst_call admin POST /crowdsec/decisions/import "$(jq -nc --arg c $' \n\t\n' '{content: $c}')"
    cst_is "bans/import: only blanks" 400
    cst_call admin POST /crowdsec/decisions/import "$(jq -nc --arg c $'# nothing here\n# nor here\n' '{format: "values", content: $c}')"
    cst_is "bans/import: only comments" 400
    cst_call admin POST /crowdsec/decisions/import '{"format":"xml","content":"198.18.0.1"}'
    cst_is "bans/import: an unknown format" 400
    cst_call admin POST /crowdsec/decisions/import '{"format":"values","content":"198.18.0.1","duration":"nope"}'
    cst_is "bans/import: a length that is no length" 400
    cst_call admin POST /crowdsec/decisions/import 'x'
    cst_is "bans/import: not JSON" 400
    cst_call admin POST /crowdsec/decisions/import '{"format":"json","content":"not json"}'
    cst_is "bans/import: content that is not json" 400
    cst_call admin POST /crowdsec/decisions/import "$(seq 1 2001 | jq -Rs '{format: "values", content: .}')"
    cst_is "bans/import: 2001 entries are too many" 400
    cst_call admin POST /crowdsec/decisions/import "$(head -c 600000 /dev/zero | tr '\0' 'a' | jq -Rs '{format: "values", content: .}')"
    cst_is "bans/import: 600 kB of text is too much" 413
    cst_call admin POST /crowdsec/decisions/import "$(head -c 1100000 /dev/zero | tr '\0' 'a' | jq -Rs '{format: "values", content: .}')"
    cst_is "bans/import: over a megabyte is refused by the router" 413
    cst_call viewer POST /crowdsec/decisions/import '{"format":"values","content":"198.18.0.9"}'
    cst_is "bans/import: a viewer may not" 403
    # -- a long list goes to CrowdSec in pieces of 400
    big=$(for (( i = 0; i < 401; i++ )); do printf '198.19.%d.%d\n' $(( i / 250 )) $(( i % 250 + 1 )); done)
    cst_call admin POST /crowdsec/decisions/import "$(printf '%s\n' "$big" | jq -Rs '{format: "values", content: .}')"
    cst_j "bans/import: 401 entries make two pieces" '.total' 401 '.imported' 401 '.skipped' 0 '.success' true
    check "bans/import: …and every import is in the audit log" 1 "$(grep -c '"action":"auth.crowdsec_import".*401 of 401' "$CST/.data/audit.jsonl")"
}

cst_bans_export() {
    local i n
    cst_world data traefik --traefik
    n=0
    for i in "=cmd|calc!A0" "+SUM(1+1)" "-2+3 say \"hi\", ok" "@HYPERLINK(\"x\")" "5 eggs" "plain text" '=HYPERLINK("http://x")'; do
        n=$(( n + 1 ))
        cst_call admin POST /crowdsec/decisions "$(jq -nc --arg r "$i" --arg v "198.18.$n.1" '{value: $v, reason: $r, duration: "2h"}')"
    done
    cst_q csv admin GET /crowdsec/decisions/export
    cst_q csv-de admin GET '/crowdsec/decisions/export?country=DE'
    cst_q csv-manual admin GET '/crowdsec/decisions/export?origin=cscli&simulated=no'
    cst_q csv-q admin GET '/crowdsec/decisions/export?q=ssh'
    cst_q json admin GET '/crowdsec/decisions/export?format=json'
    cst_q json-de admin GET '/crowdsec/decisions/export?format=json&country=DE'
    cst_q viewer viewer GET /crowdsec/decisions/export
    cst_q bad-format admin GET '/crowdsec/decisions/export?format=xml'
    cst_q bad-format2 admin GET '/crowdsec/decisions/export?format=csv%3Bid'
    cst_q bad-filter admin GET '/crowdsec/decisions/export?country=ZZZ'
    cst_q bad-filter2 admin GET '/crowdsec/decisions/export?simulated=maybe'
    cst_q nobody none GET /crowdsec/decisions/export
    cst_run
    cst_use csv
    cst_is "bans/export: csv" 200
    cst_j "bans/export: csv" '.format' csv '.count' 19 '.content | split("\n") | length' 20 '.content | split("\n")[0]' '"value","scope","type","duration","reason","origin","country","as","expires_at"'
    cst_t "bans/export: the file is named after the day" '.filename | test("^crowdsec-bans-[0-9]{4}-[0-9]{2}-[0-9]{2}\\.csv$")'
    check "bans/export: every row has nine cells" "20 9" "$(jq -r .content <<< "$CST_BODY" | python3 -c 'import csv,sys; r=list(csv.reader(sys.stdin)); print(len(r), set(map(len, r)).pop() if len({len(x) for x in r}) == 1 else "mixed")')"
    check "bans/export: a cell a spreadsheet would run as a formula is defused" "'=cmd|calc!A0 '+SUM(1+1) '-2+3 say \"hi\", ok '@HYPERLINK(\"x\") 5 eggs plain text '=HYPERLINK(\"http://x\")" \
        "$(jq -r .content <<< "$CST_BODY" | python3 -c 'import csv,sys; r={x[0]: x[4] for x in csv.reader(sys.stdin)}; print(" ".join(r["198.18.%d.1" % i] for i in range(1, 8)))')"
    cst_use csv-de;     cst_j "bans/export: the list's filters apply (country)" '.count' 2
    cst_use csv-manual; cst_j "bans/export: …(origin, simulated)" '.count' 10
    cst_use csv-q;      cst_j "bans/export: …(q)" '.count' 2
    cst_use json
    cst_j "bans/export: json" '.format' json '.count' 19 '.content | fromjson | length' 19 '.content | fromjson | map(.value) | index("198.18.1.1") != null' true \
        '.filename | endswith(".json")' true
    cst_t "bans/export: json rows carry what the csv has" '.content | fromjson | all(has("value") and has("scope") and has("type") and has("duration") and has("reason") and has("origin") and has("expires_at"))'
    cst_t "bans/export: json is not defused (it is data, not a sheet)" '.content | fromjson | map(select(.value == "198.18.1.1"))[0].reason == "=cmd|calc!A0"'
    cst_use json-de;    cst_j "bans/export: json with a filter" '.count' 2 '.content | fromjson | map(.country) | unique | join(",")' DE
    cst_use viewer;     cst_is "bans/export: a viewer may" 200
    cst_use bad-format; cst_is "bans/export: an unknown format" 400
    cst_use bad-format2; cst_is "bans/export: a format with a semicolon" 400
    cst_use bad-filter; cst_is "bans/export: a bad country" 400
    cst_use bad-filter2; cst_is "bans/export: a bad simulated" 400
    cst_use nobody;     cst_is "bans/export: nobody" 401
}

cst_part_bans() {
    echo "CrowdSec page: bans"
    cst_bans_list
    cst_bans_refusals
    cst_bans_add
    cst_bans_lift
    cst_bans_import
    cst_bans_export
}

# a server with thousands of bans: nothing that reads the whole list may hand it to a command line (an argument is limited to 128 KB)
cst_bans_large() {
    local i n
    cst_world data traefik --traefik
    # 2 x 1300 addresses, put into the stand-in in one call each, like `cscli decisions import` would (the import of the API itself costs ~35 ms per address: it has its
    # own test, with 401 addresses, above). The one question here is what the pages do with a list far above 128 KB.
    for n in 0 1; do
        for (( i = 0; i < 1300; i++ )); do printf '91.%d.%d.%d\n' $(( 200 + n )) $(( i / 250 )) $(( i % 250 + 1 )); done \
            | "$CST/bin/docker" exec -i CrowdSec cscli decisions import -i - --format values --duration 6h --reason "large test" >/dev/null 2>&1 \
            || check "large: the stand-in takes 1300 bans in one go" yes no
    done
    rm -rf "$CST/.data/cache/crowdsec"
    cst_q status admin GET /crowdsec/status
    cst_q list admin GET '/crowdsec/decisions?limit=2000'
    cst_q csv admin GET /crowdsec/decisions/export
    cst_q json admin GET '/crowdsec/decisions/export?format=json'
    cst_q alerts admin GET /crowdsec/alerts
    cst_q alerts7 admin GET '/crowdsec/alerts?window=7d&limit=1000'
    cst_q metrics admin GET '/crowdsec/metrics?window=7d'
    cst_q ip admin GET '/crowdsec/decisions?q=91.201.4.250'
    cst_run
    cst_use status;  cst_is "large/status: 2600 bans and it still answers" 200
    cst_j "large/status" '.state' healthy '.counts.decisions_active >= 2500' true '.decisions | length' 50
    cst_use list;    cst_is "large/list" 200
    cst_j "large/list" '.total >= 2500' true '.count >= 2500' true '.decisions | length' 2000
    cst_use csv;     cst_is "large/export: csv of everything" 200
    cst_j "large/export csv" '.count >= 2500' true '.content | length > 131072' true '(.content | split("\n") | length) == (.count + 1)' true
    cst_use json;    cst_is "large/export: json of everything" 200
    cst_j "large/export json" '.count >= 2500' true '(.content | fromjson | length) == .count' true
    cst_use alerts;  cst_is "large/alerts" 200
    cst_j "large/alerts: the imports are alerts of their own, and their bans are known" '.alerts | map(select(.source.value == "192.0.2.66"))[0].banned' true
    cst_use alerts7; cst_is "large/alerts: a week" 200
    cst_use metrics; cst_is "large/metrics" 200
    cst_j "large/metrics: the bans are counted" '.totals.banned_now >= 2500' true
    cst_use ip;      cst_j "large/list: one of them by its address" '.count' 1 '.decisions[0].scenario' 'large test'
}

# ---- a long import: 1300 and 2000 entries, the counts, and the entries that were left out and why ------------------------------------

cst_import_big() {
    local i body a0
    cst_world data traefik --traefik
    a0=$(cst_audit_n '"action":"auth.crowdsec_import"')
    # -- 1300 addresses, all new: one request, every one of them banned
    body=$(for (( i = 0; i < 1300; i++ )); do printf '91.200.%d.%d\n' $(( i / 250 )) $(( i % 250 + 1 )); done | jq -Rs '{format: "values", duration: "6h", reason: "large import one", content: .}')
    CST_TIMEOUT=900 cst_call admin POST /crowdsec/decisions/import "$body"
    cst_is "import/large: 1300 addresses" 200
    cst_j "import/large: 1300 addresses" '.success' true '.format' values '.total' 1300 '.imported' 1300 '.skipped' 0 '.allowlisted' 0 '.skipped_entries' '[]' '.error' null
    cst_call admin GET '/crowdsec/decisions?q=91.200.4.250'
    cst_j "import/large: …the last of them is banned, with the reason given" '.count' 1 '.decisions[0].value' 91.200.4.250 '.decisions[0].scenario' 'large import one'
    # -- 2000 entries, the most one request takes: 100 new, 100 that are no address, 100 that are in the list twice, 500 that are banned already, 1200 new
    body=$({
        for (( i = 1; i <= 100; i++ )); do printf '91.201.0.%d\n' "$i"; done
        for (( i = 1; i <= 100; i++ )); do printf 'not-an-address-%d\n' "$i"; done
        for (( i = 1; i <= 100; i++ )); do printf '91.201.0.%d\n' "$i"; done
        for (( i = 0; i < 500; i++ )); do printf '91.200.%d.%d\n' $(( i / 250 )) $(( i % 250 + 1 )); done
        for (( i = 0; i < 1200; i++ )); do printf '91.202.%d.%d\n' $(( i / 250 )) $(( i % 250 + 1 )); done
    } | jq -Rs '{format: "values", duration: "6h", reason: "large import two", content: .}')
    CST_TIMEOUT=900 cst_call admin POST /crowdsec/decisions/import "$body"
    cst_is "import/large: 2000 entries, the most" 200
    cst_j "import/large: 2000 entries: what was banned and what was left out" '.success' true '.total' 2000 '.imported' 1300 '.skipped' 700 '.allowlisted' 0 '.error' null
    cst_j "import/large: …the entries that were left out are listed, 200 at most" '.skipped_entries | length' 200 '.skipped_entries[0] | "\(.line):\(.reason)"' 101:invalid '.skipped_entries[99] | "\(.line):\(.reason)"' 200:invalid \
        '.skipped_entries[100] | "\(.line):\(.reason)"' 201:duplicate '.skipped_entries[199] | "\(.line):\(.reason)"' 300:duplicate '[.skipped_entries[] | .reason] | unique | join(",")' duplicate,invalid \
        '.skipped_entries[0].value' not-an-address-1 '.skipped_entries[100].value' 91.201.0.1 '.skipped_entries | all(.message | length > 5)' true
    check "import/large: …it is in the audit log, with the counts" "$(( a0 + 2 )) 1" "$(cst_audit_n '"action":"auth.crowdsec_import"') $(cst_audit_n '"action":"auth.crowdsec_import".*1300 of 2000 imported (700 skipped)')"
    cst_uncache; cst_call admin GET /crowdsec/status
    cst_j "import/large: 2600 bans and the status counts them" '.counts.decisions_active' 2611 '.counts.decisions' 2612 '.state' healthy
    cst_call admin GET '/crowdsec/decisions?q=91.201.0.5&limit=100'
    cst_j "import/large: an address that was in the list twice is banned once" '.decisions | map(select(.value == "91.201.0.5")) | length' 1 '.decisions | map(select(.value == "91.201.0.5"))[0].scenario' 'large import two'
    cst_call admin GET '/crowdsec/decisions?q=91.200.0.1&limit=200'
    cst_j "import/large: an address that was banned already keeps its first ban" '.decisions | map(select(.value == "91.200.0.1")) | length' 1 '.decisions | map(select(.value == "91.200.0.1"))[0].scenario' 'large import one'
    cst_call admin GET '/crowdsec/decisions?q=91.202.4.200'
    cst_j "import/large: the last of the 1200 new ones" '.count' 1 '.decisions[0].scenario' 'large import two'
    # -- one more than the most
    body=$(for (( i = 0; i < 2001; i++ )); do printf '91.203.%d.%d\n' $(( i / 250 )) $(( i % 250 + 1 )); done | jq -Rs '{format: "values", content: .}')
    CST_TIMEOUT=900 cst_call admin POST /crowdsec/decisions/import "$body"
    cst_is "import/large: 2001 entries" 400
    cst_t "import/large: …the answer says how many there are" '.message | test("2000") and test("2001")'
    cst_call admin GET '/crowdsec/decisions?q=91.203.0.1'
    cst_j "import/large: …none of them was banned" '.count' 0
}

cst_part_importbig() {
    echo "CrowdSec page: a long import"
    cst_import_big
}

# ---- alerts, the numbers behind the charts -------------------------------------------------------------------------------------------

cst_part_alerts() {
    local w p i
    echo "CrowdSec page: alerts and metrics"
    cst_world data traefik --traefik
    for w in 1h 6h 24h 7d 30d; do cst_q "w$w" admin GET "/crowdsec/alerts?window=$w"; done
    cst_q wdefault admin GET /crowdsec/alerts
    cst_q viewer viewer GET /crowdsec/alerts
    cst_q page admin GET '/crowdsec/alerts?limit=3&offset=1'
    cst_q scenario admin GET '/crowdsec/alerts?scenario=crowdsecurity/http-probing'
    cst_q country admin GET '/crowdsec/alerts?country=RU'
    cst_q country-unknown admin GET '/crowdsec/alerts?country=unknown'
    cst_q ip admin GET '/crowdsec/alerts?ip=194.26.135.7&window=7d'
    cst_q q admin GET '/crowdsec/alerts?q=bad'
    cst_q sim-yes admin GET '/crowdsec/alerts?simulated=yes'
    cst_q sim-no admin GET '/crowdsec/alerts?simulated=no'
    cst_q fscen admin GET '/crowdsec/alerts?scenario=crowdsecurity/http-probing'
    cst_q fcountry admin GET '/crowdsec/alerts?country=RU'
    cst_q fboth admin GET '/crowdsec/alerts?scenario=crowdsecurity/http-probing&country=RU'
    cst_q combo admin GET '/crowdsec/alerts?window=7d&country=RU&scenario=crowdsecurity/http-backdoors-attempts'
    cst_q q-huge admin GET "/crowdsec/alerts?q=$(head -c 10000 /dev/zero | tr '\0' 'x')"
    local -a bad=('window=2h' 'window=24' 'window=1d' 'limit=0' 'limit=1001' 'limit=abc' 'limit=-5' 'offset=x' 'offset=1000000' 'country=ZZZ' 'country=1' 'ip=garbage' 'ip=1.2.3.4%3Bid' 'scenario=x%3By' 'simulated=maybe')
    for i in "${!bad[@]}"; do cst_q "bad$i" admin GET "/crowdsec/alerts?${bad[$i]}"; done
    cst_q d10 admin GET /crowdsec/alerts/10
    cst_q d21 admin GET /crowdsec/alerts/21
    cst_q d13 admin GET /crowdsec/alerts/13
    cst_q dviewer viewer GET /crowdsec/alerts/10
    cst_q dnone admin GET /crowdsec/alerts/999999
    local -a badid=(abc -1 1.5 '1;id' '$(id)' '../x' '%2e%2e' 1234567890123 '')
    for i in "${!badid[@]}"; do cst_q "id$i" admin GET "/crowdsec/alerts/${badid[$i]}"; done
    for w in 24h 7d 30d; do cst_q "m$w" admin GET "/crowdsec/metrics?window=$w"; done
    cst_q mdefault admin GET /crowdsec/metrics
    cst_q mviewer viewer GET '/crowdsec/metrics?window=7d'
    local -a badm=('window=1h' 'window=6h' 'window=2d' 'window=x' 'window=24h%3Bid')
    for i in "${!badm[@]}"; do cst_q "mbad$i" admin GET "/crowdsec/metrics?${badm[$i]}"; done
    cst_run

    cst_use w1h;  cst_j "alerts/window 1h" '.window' 1h '.count' 7 '.total' 7 '.alerts | map(.id) | join(",")' 21,20,19,18,17,16,15
    cst_use w6h;  cst_j "alerts/window 6h" '.count' 15 '.alerts | map(.id) | join(",")' 21,20,19,18,17,16,15,14,12,11,10,9,8,7,6
    cst_use w24h; cst_j "alerts/window 24h" '.count' 16 '.window' 24h '.retention_days' 7 '.alerts[0].id' 21 '.alerts[-1].id' 5
    cst_use w7d;  cst_j "alerts/window 7d" '.count' 20 '.alerts[-1].id' 1
    cst_use w30d; cst_j "alerts/window 30d" '.count' 20
    cst_use wdefault; cst_j "alerts: 24 hours by default" '.window' 24h '.count' 16
    cst_j "alerts: the community blocklist's own alert is not one" '.alerts | map(.id) | index(13)' null
    cst_use viewer; cst_is "alerts: a viewer may read" 200
    cst_use w24h
    cst_t "alerts: a row has what the table needs" '.alerts | all(has("id") and has("scenario") and has("label") and has("family") and has("kind") and has("simulated") and has("banned") and has("created_at") and (.source | has("value") and has("country") and has("as_name")) and (.decisions | type == "array"))'
    cst_t "alerts: no raw meta in the list (the detail has it)" '.alerts | all(has("meta") | not)'
    cst_j "alerts: labels" '.alerts | map(select(.id == 10))[0].label' 'Web probing' '.alerts | map(select(.id == 10))[0].family' probe '.alerts | map(select(.id == 21))[0].label' 'Manual ban' \
        '.alerts | map(select(.id == 21))[0].family' manual '.alerts | map(select(.id == 14))[0].family' bruteforce '.alerts | map(select(.id == 8))[0].family' exploit
    cst_j "alerts: whether the source is banned now" '.alerts | map(select(.id == 10))[0].banned' true '.alerts | map(select(.id == 6))[0].banned' false '.alerts | map(select(.id == 15))[0].banned' true
    cst_j "alerts: facets" '.facets.scenarios[0].value' crowdsecurity/http-bad-user-agent '.facets.countries[0] | "\(.value):\(.count)"' RU:3 '.facets.unknown_country' 3 '.facets.scenarios | length' 10
    cst_use page;     cst_j "alerts: a page" '.count' 16 '.limit' 3 '.offset' 1 '.alerts | map(.id) | join(",")' 20,19,18
    cst_use scenario; cst_j "alerts: scenario=" '.count' 3 '.alerts | map(.id) | join(",")' 19,10,6
    cst_use country;  cst_j "alerts: country=RU" '.count' 3 '.alerts | map(.id) | join(",")' 8,7,5
    cst_use country-unknown; cst_j "alerts: country=unknown" '.count' 3 '.alerts | map(.kind) | unique | join(",")' cscli
    cst_use ip;       cst_j "alerts: ip= over a week" '.count' 3 '.alerts | map(.id) | join(",")' 8,7,4
    cst_use q;        cst_j "alerts: q=" '.count' 3 '.alerts | map(.id) | join(",")' 16,11,5
    cst_use sim-yes;  cst_j "alerts: simulated=yes" '.count' 1 '.alerts[0].id' 19
    cst_use sim-no;   cst_j "alerts: simulated=no" '.count' 15
    cst_use w24h;     cst_j "alerts/facets: a scenario carries its words" '.facets.scenarios | map(select(.value == "crowdsecurity/http-probing"))[0].label' 'Web probing' '.facets.scenarios | all(.label | length > 0)' true
    cst_use fscen;    cst_j "alerts/facets: a scenario filter keeps the list of scenarios whole" '.count' 3 '.facets.scenarios | length' 10 '.facets.countries | map("\(.value):\(.count)") | sort | join(",")' BG:1,LT:1,NL:1
    cst_use fcountry; cst_j "alerts/facets: a country filter keeps the list of countries whole" '.count' 3 '.facets.countries | length' 9 '.facets.scenarios | map("\(.value):\(.count)") | sort | join(",")' \
        crowdsecurity/CVE-2017-9841:1,crowdsecurity/http-backdoors-attempts:1,crowdsecurity/http-bad-user-agent:1
    cst_use fboth;    cst_j "alerts/facets: both filters: each list follows the other" '.count' 0 '.facets.scenarios | length' 3 '.facets.countries | length' 3
    cst_use combo;    cst_j "alerts: filters add up" '.count' 2 '.alerts | map(.id) | join(",")' 7,4
    cst_use q-huge;   cst_is "alerts: a 10 kB search text is cut, not refused" 200
    for i in "${!bad[@]}"; do cst_use "bad$i"; cst_is "alerts: ?${bad[$i]} is refused" 400; done

    cst_use d10; cst_is "alerts/detail: an alert" 200
    cst_j "alerts/detail" '.alert.id' 10 '.alert.scenario' crowdsecurity/http-probing '.alert.events | length' 11 '.alert.events[0].fields.http_path' /x1 '.alert.events[0].fields.target_fqdn' app.example.com \
        '.alert.source.value' 89.248.165.10 '.alert.source.country' NL '.alert.family' probe '.alert.context.status[0]' 404 '.alert.uuid | length > 10' true '.alert.decisions | length' 1
    cst_j "alerts/detail: the requests behind it are listed in order" '.alert.events | map(.fields.http_path) | join(",")' /x1,/x2,/x3,/x4,/x5,/x6,/x7,/x8,/x9,/x10,/x11
    cst_use d21; cst_j "alerts/detail: a manual ban has no requests" '.alert.kind' cscli '.alert.events | length' 0 '.alert.family' manual
    cst_use d13; cst_is "alerts/detail: the community blocklist's alert can be opened" 200
    cst_use dviewer; cst_is "alerts/detail: a viewer may read" 200
    cst_use dnone;   cst_is "alerts/detail: no such alert" 404
    for i in "${!badid[@]}"; do cst_use "id$i"; cst_is "alerts/detail: id '${badid[$i]}' is refused" "$([[ -z "${badid[$i]}" ]] && echo 200 || echo 400)"; done

    cst_use m24h; cst_is "metrics: 24h" 200
    cst_j "metrics/24h" '.window' 24h '.bucket_seconds' 3600 '.timeline | length' 25 '.window_supported' true '.retention_days' 7 '.totals.alerts' 13 '.totals.manual' 3 '.totals.banned_now' 11 \
        '.totals.sources' 11 '.totals.countries' 9 '.totals.scenarios' 7 '.timeline | map(.alerts) | add' 13 '(.timeline | map(.events) | add) == .totals.events' true
    cst_use m7d;  cst_j "metrics/7d" '.window' 7d '.bucket_seconds' 21600 '.timeline | length' 29 '.window_supported' true '.totals.alerts' 17 '.timeline | map(.alerts) | add' 17 '.since < .as_of' true
    cst_use m30d; cst_j "metrics/30d" '.window' 30d '.bucket_seconds' 86400 '.timeline | length' 31 '.window_supported' false '.totals.alerts' 17
    cst_use mdefault; cst_j "metrics: 24 hours by default" '.window' 24h
    cst_use m7d
    cst_j "metrics/7d: the top lists" '.scenarios[0].scenario' crowdsecurity/http-probing '.scenarios[0].alerts' 4 '.scenarios[0].label' 'Web probing' '.scenarios[0].family' probe '.scenarios | length' 7 \
        '.countries[0].code' RU '.countries[0].alerts' 4 '.countries | length' 9 '.unknown_country' 0 '.sources[0].value' 194.26.135.7 '.sources[0].alerts' 3 '.sources[0].banned' true \
        '.networks[0].alerts' 3 '.bans_by_country[0].code' DE '.bans_by_country[0].count' 2 '.map_points | length' 11 '.decisions_by_origin[0].origin' CAPI '.decisions_by_origin[0].count' 40
    cst_t "metrics: the log-reading counters are there" '.acquisition | length == 2 and all(has("source") and has("reads") and has("parsed") and has("unparsed") and has("poured")) and (.[0].reads > 0)'
    cst_t "metrics: parsers and the API's request count" '(.parsers | length) > 0 and (.parsers | all(has("name") and has("hits"))) and .lapi_requests > 0'
    cst_t "metrics: every point of the map has a place and a count" '.map_points | all(has("lat") and has("lon") and has("alerts") and has("country"))'
    cst_use mviewer; cst_is "metrics: a viewer may read" 200
    for i in "${!badm[@]}"; do cst_use "mbad$i"; cst_is "metrics: ?${badm[$i]} is refused" 400; done

    cst_world empty traefik --traefik
    cst_call admin GET '/crowdsec/metrics?window=24h'
    cst_j "metrics/empty" '.totals.alerts' 0 '.totals.sources' 0 '.totals.banned_now' 0 '.timeline | length' 25 '.timeline | map(.alerts) | add' 0 '.scenarios | length' 0 '.countries | length' 0 \
        '.sources | length' 0 '.map_points | length' 0 '.acquisition | length' 0
    cst_call admin GET '/crowdsec/alerts'
    cst_j "alerts/empty" '.count' 0 '.alerts | length' 0 '.facets.scenarios | length' 0 '.facets.unknown_country' 0
    cst_mock --mock-init data --traefik
    cst_mock --mock-set lapi_down=1
    cst_call admin GET /crowdsec/alerts
    cst_is "alerts: the LAPI down is a 502" 502
    cst_t "alerts: …that says why" '.message | test("answer: .+")'
    cst_call admin GET /crowdsec/decisions
    cst_is "bans: the LAPI down is a 502" 502
    cst_t "bans: …that says why" '.message | test("answer: .+")'
    cst_mock --mock-set lapi_down=0
}

# ---- the allowlist: CrowdSec's own (1.6.8+) and DCS's trusted list (older CrowdSec) ----------------------------------------------------

cst_allowlist_native() {
    local now i
    now=$(date +%s)
    cst_world data traefik --traefik
    cst_call admin GET /crowdsec/allowlist
    cst_is "allowlist: the list" 200
    cst_j "allowlist/native" '.mechanism' native '.list_name' dcs '.supports_expiry' true '.count' 4 '.lists | map(.name) | join(",")' dcs,vendor '.lists[0].items' 3 \
        '.entries | map(.value) | join(",")' 203.0.113.9,198.51.100.0/24,2001:db8::/32,192.0.2.77 \
        '.entries[0].kind' ip '.entries[0].comment' office '.entries[0].source' allowlist '.entries[0].removable' true '.entries[0].expires_at' null '.entries[1].kind' range \
        '.entries[1].comment' 'range with expiry' '.entries[3].source' other '.entries[3].removable' false '.entries[3].list' vendor '.home.public_ip' ''
    cst_t "allowlist/native: an entry with an expiry says when" '.entries[1].expires_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | . > '"$now"' + 86400 * 20'
    cst_call viewer GET /crowdsec/allowlist
    cst_is "allowlist: a viewer may read" 200

    # -- adding: a banned address is unbanned at once
    cst_call admin POST /crowdsec/allowlist '{"value":"192.0.2.10","comment":"office pc"}'
    cst_is "allowlist/add: an address" 200
    cst_j "allowlist/add" '.success' true '.value' 192.0.2.10 '.kind' ip '.mechanism' native '.comment' 'office pc' '.expires_at' null '.removed_bans' 1
    cst_call admin GET '/crowdsec/decisions?q=192.0.2.10'
    cst_j "allowlist/add: …its ban is gone" '.count' 0
    check "allowlist/add: CrowdSec has it, with the comment" "office pc" "$(cst_cs allowlists inspect dcs -o json | jq -r '.items[] | select(.value == "192.0.2.10") | .description')"
    cst_call admin POST /crowdsec/allowlist '{"value":"192.0.2.0/24","comment":"lab net","expires":"7d"}'
    cst_j "allowlist/add: a network for a week lifts every ban it covers" '.kind' range '.removed_bans' 2 '.expires_at | fromdateiso8601 | . - now | . > 603900 and . < 605200' true
    check "allowlist/add: CrowdSec has the expiry too" true "$(cst_cs allowlists inspect dcs -o json | jq -r --argjson now "$now" '.items[] | select(.value == "192.0.2.0/24") | (.expiration | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) > ($now + 600000)')"
    cst_call admin POST /crowdsec/allowlist '{"value":"2A00:1450:4001:0:0:0:0:1"}'
    cst_j "allowlist/add: IPv6, written short" '.value' 2a00:1450:4001::1 '.kind' ip '.removed_bans' 0
    cst_call admin POST /crowdsec/allowlist '{"value":"2A00:1450:4001::1"}'
    cst_is "allowlist/add: the same again is a conflict, not a second entry" 409
    cst_j "allowlist/add: …with its reason" '.reason' already_allowed
    cst_call admin POST /crowdsec/allowlist '{"value":"203.0.113.9"}'
    cst_is "allowlist/add: an entry that came with the install, again" 409
    cst_call admin POST /crowdsec/allowlist '{"value":"198.18.5.5/24"}'
    cst_j "allowlist/add: a network loses its host bits" '.value' 198.18.5.0/24
    cst_call admin POST /crowdsec/allowlist '{"value":"8.0.0.0/8"}'
    cst_is "allowlist/add: a /8 is the widest network" 200
    cst_call admin POST /crowdsec/allowlist '{"value":"2a00::/16"}'
    cst_is "allowlist/add: a /16 is the widest IPv6 network" 200
    cst_call admin POST /crowdsec/allowlist "$(jq -nc '{value: "198.18.9.9", comment: "a\u0007b\tc"}')"
    cst_j "allowlist/add: a comment without control characters" '.comment' 'ab c'
    cst_call admin POST /crowdsec/allowlist "$(jq -nc --arg c "$(head -c 300 /dev/zero | tr '\0' 'y')" '{value: "198.18.9.10", comment: $c}')"
    cst_j "allowlist/add: a comment is cut to 200 characters" '.comment | length' 200
    cst_call admin GET /crowdsec/allowlist
    cst_j "allowlist/native: after adding" '.count' 12 '.lists[0].items' 11 '.entries | map(select(.value == "2a00:1450:4001::1")) | length' 1 '.entries | map(select(.value == "192.0.2.10"))[0].comment' 'office pc'
    # -- CrowdSec's list itself cannot be read: that is an error, not an empty allowlist
    cst_mock --mock-set lapi_down=1
    cst_call admin GET /crowdsec/allowlist
    cst_is "allowlist: when CrowdSec's list cannot be read it says so" 502
    cst_t "allowlist: …and why" '.message | test("answer: .+")'
    cst_mock --mock-set lapi_down=0
    # -- refusals, all at once
    local -a addbad=('{"value":"0.0.0.0/0"}' '{"value":"::/0"}' '{"value":"8.0.0.0/7"}' '{"value":"2000::/3"}' '{"value":"::/1"}' '{"value":"2a00::/15"}' '{"value":"nope"}' '{"value":""}' '{}' '{"value":12345}'
                     '{"value":"198.18.9.11","expires":"nope"}' '{"value":"198.18.9.11","expires":"30s"}' '{"value":"198.18.9.11","expires":"+7d"}' '{"value":"198.18.9.11","expires":"1 year"}'
                     '{"value":"198.18.9.11;id"}' '{"value":"fe80::1%eth0"}' '{"value":"010.0.0.1"}' 'not json' '[1]')
    for i in "${!addbad[@]}"; do cst_q "ab$i" admin POST /crowdsec/allowlist "${addbad[$i]}"; done
    cst_q abviewer viewer POST /crowdsec/allowlist '{"value":"198.18.9.11"}'
    cst_q abnobody none POST /crowdsec/allowlist '{"value":"198.18.9.11"}'
    cst_run
    for i in "${!addbad[@]}"; do cst_use "ab$i"; cst_is "allowlist/add: ${addbad[$i]} is refused" 400; done
    cst_use abviewer; cst_is "allowlist/add: a viewer may not" 403
    cst_use abnobody; cst_is "allowlist/add: nobody may not" 401
    cst_call admin GET /crowdsec/allowlist
    cst_j "allowlist/native: none of the refused got in" '.count' 12

    # -- removing
    cst_call admin DELETE /crowdsec/allowlist/192.0.2.10
    cst_is "allowlist/remove: an address" 200
    cst_j "allowlist/remove" '.success' true '.value' 192.0.2.10 '.mechanism' native
    cst_call admin DELETE /crowdsec/allowlist/192.0.2.10
    cst_is "allowlist/remove: twice" 404
    cst_call admin DELETE /crowdsec/allowlist/192.0.2.0/24
    cst_is "allowlist/remove: a network, with the slash in the path" 200
    cst_call admin DELETE /crowdsec/allowlist/2A00:1450:4001:0:0:0:0:1
    cst_j "allowlist/remove: IPv6 in another spelling" '.value' 2a00:1450:4001::1
    cst_call admin DELETE /crowdsec/allowlist/192.0.2.77
    cst_is "allowlist/remove: an entry of somebody else's list is not ours to remove" 404
    cst_call admin DELETE /crowdsec/allowlist/198.18.1.1
    cst_is "allowlist/remove: an address that is not there" 404
    local -a delbad=(garbage 999.1.1.1 198.18.0.0/33 '$(id)' '`id`' 'a;id' '%2e%2e' '1.2.3.4%2f24')
    for i in "${!delbad[@]}"; do cst_q "db$i" admin DELETE "/crowdsec/allowlist/${delbad[$i]}"; done
    cst_q dbviewer viewer DELETE /crowdsec/allowlist/198.18.9.9
    cst_q dbnobody none DELETE /crowdsec/allowlist/198.18.9.9
    cst_run
    for i in "${!delbad[@]}"; do cst_use "db$i"; cst_is "allowlist/remove: ${delbad[$i]} is refused" 400; done
    cst_use dbviewer; cst_is "allowlist/remove: a viewer may not" 403
    cst_use dbnobody; cst_is "allowlist/remove: nobody may not" 401
    check "allowlist/remove: CrowdSec lost it too" "" "$(cst_cs allowlists inspect dcs -o json | jq -r '.items[] | select(.value == "192.0.2.10") | .value')"

    # -- what DCS keeps on its own: the home address cannot be removed, the .env and the older trusted list show up
    printf '{"public_ip":"198.51.100.77","synced_at":"2026-09-29T10:00:00Z"}\n' > "$CST/.data/crowdsec-whitelist.json"
    printf '{"ips":["198.18.60.1"],"notes":{"198.18.60.1":"printed note"}}\n' > "$CST/.data/crowdsec-trusted.json"
    cst_env CROWDSEC_TRUSTED_IPS 198.18.61.1
    cst_call admin GET /crowdsec/allowlist
    cst_j "allowlist/native: the home address is managed" '.home.public_ip' 198.51.100.77 '.entries[0].value' 198.51.100.77 '.entries[0].managed' true '.entries[0].removable' false '.entries[0].source' managed
    cst_j "allowlist/native: so are the .env's" '.entries | map(select(.source == "env"))[0].value' 198.18.61.1 '.entries | map(select(.source == "env"))[0].removable' false
    cst_j "allowlist/native: the trusted list's are removable and keep their note" '.entries | map(select(.source == "trusted"))[0].value' 198.18.60.1 '.entries | map(select(.source == "trusted"))[0].comment' 'printed note' \
        '.entries | map(select(.source == "trusted"))[0].removable' true
    cst_call admin DELETE /crowdsec/allowlist/198.51.100.77
    cst_is "allowlist/remove: the home address stays" 409
    cst_call admin DELETE /crowdsec/allowlist/198.18.61.1
    cst_is "allowlist/remove: the .env's addresses are changed in the .env" 404
    cst_call admin DELETE /crowdsec/allowlist/198.18.60.1
    cst_is "allowlist/remove: a trusted-list entry goes" 200
    cst_env CROWDSEC_TRUSTED_IPS
    check "allowlist: every change is in the audit log" 1 "$(grep -c '"action":"auth.crowdsec_allow".*192.0.2.10 (office pc)' "$CST/.data/audit.jsonl")"
    check "allowlist: …and every removal" 1 "$(grep -c '"action":"auth.crowdsec_disallow".*198.18.60.1' "$CST/.data/audit.jsonl")"
}

cst_allowlist_parser() {
    local i now hook
    now=$(date +%s)
    cst_world old traefik --traefik
    printf '198.51.100.9\n' > "$CST/.data/ddns-current-ip"          # the home address the DDNS loop keeps (no lookup on the network is needed)
    cst_call admin GET /crowdsec/allowlist
    cst_j "allowlist/parser" '.mechanism' parser '.list_name' null '.supports_expiry' false '.lists | length' 0 '.count' 0 '.note | length > 20' true
    cst_call admin POST /crowdsec/allowlist '{"value":"192.0.2.66","comment":"parser one"}'
    cst_is "allowlist/parser: add an address" 200
    cst_j "allowlist/parser" '.mechanism' parser '.removed_bans' 1 '.expires_at' null '.comment' 'parser one'
    cst_call admin POST /crowdsec/allowlist '{"value":"198.18.0.0/16"}'
    cst_j "allowlist/parser: add a network" '.kind' range '.removed_bans' 0
    cst_call admin POST /crowdsec/allowlist '{"value":"2A00:1450:4001:0:0:0:0:5"}'
    cst_j "allowlist/parser: add an IPv6 address" '.value' 2a00:1450:4001::5
    cst_call admin POST /crowdsec/allowlist '{"value":"192.0.2.66"}'
    cst_is "allowlist/parser: the same again is a conflict" 409
    cst_j "allowlist/parser: …with its reason" '.reason' already_allowed
    cst_call admin POST /crowdsec/allowlist '{"value":"192.0.2.128/25","expires":"7d"}'
    cst_is "allowlist/parser: an expiry is not possible here" 400
    cst_call admin POST /crowdsec/allowlist '{"value":"0.0.0.0/0"}'
    cst_is "allowlist/parser: too wide" 400
    cst_call admin POST /crowdsec/allowlist '{"value":"2000::/3"}'
    cst_is "allowlist/parser: too wide (IPv6)" 400
    cst_call admin GET /crowdsec/allowlist
    cst_j "allowlist/parser: the list" '.count' 4 '.entries | map(.value) | join(",")' 198.51.100.9,192.0.2.66,198.18.0.0/16,2a00:1450:4001::5 '.entries[0].source' managed '.entries[1].comment' 'parser one' \
        '.entries[1].removable' true '.entries | map(.source) | join(",")' managed,trusted,trusted,trusted
    check "allowlist/parser: the trusted list is on disk" "192.0.2.66,198.18.0.0/16,2a00:1450:4001::5" "$(jq -r '.ips | join(",")' "$CST/.data/crowdsec-trusted.json")"
    hook="$CST/fake/rootfs/etc/crowdsec/parsers/s02-enrich/dcs-whitelist.yaml"
    check "allowlist/parser: CrowdSec's whitelist parser has them all" "192.0.2.66 198.51.100.9 2a00:1450:4001::5 198.18.0.0/16" \
        "$(sed -n 's/^    - //p' "$hook" | tr '\n' ' ' | sed 's/ $//')"
    check "allowlist/parser: …and CrowdSec was told to reload" yes "$(grep -q 'kill -s HUP CrowdSec' <(sed 's/\\//g' "$CST/argv.log") && echo yes || echo no)"
    cst_call admin DELETE /crowdsec/allowlist/192.0.2.66
    cst_is "allowlist/parser: remove" 200
    cst_call admin DELETE /crowdsec/allowlist/198.18.0.0/16
    cst_is "allowlist/parser: remove a network" 200
    cst_call admin DELETE /crowdsec/allowlist/192.0.2.66
    cst_is "allowlist/parser: twice" 404
    cst_call admin DELETE /crowdsec/allowlist/198.51.100.9
    cst_is "allowlist/parser: the home address stays" 409
    check "allowlist/parser: the whitelist parser lost them" "198.51.100.9 2a00:1450:4001::5" "$(sed -n 's/^    - //p' "$hook" | tr '\n' ' ' | sed 's/ $//')"
}

# ---- the home network over IPv6: a device at home reaching the public name over IPv6 has an address of the home network, not the home IPv4 address --------
cst_home_ipv6() {
    local w n mark
    w="$CST/fake/rootfs/etc/crowdsec/parsers/s02-enrich/dcs-whitelist.yaml"
    # -- the arithmetic: the network of an address, the length setting, what counts as a global address
    n=$( (
        set +u
        export BASE_DIR="$CST"
        set --
        source "$CST_API" >/dev/null 2>&1
        set +e
        _crowdsec_ipv6_net 2001:DB8:1:2:a:b:c:d 64; echo
        _crowdsec_ipv6_net 2001:db8:abcd:12ff::1 56; echo
        _crowdsec_ipv6_net 2a02:8070:1234:0:5::5 48; echo
        _crowdsec_ipv6_net 2001:db8:0:0:1:0:0:1 128; echo
        _crowdsec_ipv6_net 2001:db8::7 61; echo
        for v in 198.51.100.9 1::2::3 2001:db8:zz::1 1:2:3:4:5:6:7:8:9 "2001:db8::1;id"; do _crowdsec_ipv6_net "$v" 64 >/dev/null && echo "accepted $v"; done
        for v in '' 56 off OFF none 0 12 200 abc 064; do printf '%s=' "$v"; CROWDSEC_HOME_IPV6_PREFIX="$v" _crowdsec_home_ipv6_len || printf 'off'; printf ' '; done; echo
        (unset CROWDSEC_HOME_IPV6_PREFIX; _crowdsec_home_ipv6_len); echo
        for v in 2001:db8::1 2a00:1450:4001::5 3fff::1 fd00::5 fc00::1 fe80::1 ::1 ::ffff:1.2.3.4 2001:db8:::1 1.2.3.4; do _crowdsec_global_ip6 "$v" && printf '%s ' "$v"; done; echo
    ) 2>/dev/null )
    check "home IPv6: the network of an address (/64, /56, /48, /128, a cut inside a group)" \
        "2001:db8:1:2::/64 2001:db8:abcd:1200::/56 2a02:8070:1234::/48 2001:db8:0:0:1:0:0:1/128 2001:db8::/61" "$(head -n 5 <<< "$n" | tr '\n' ' ' | sed 's/ $//')"
    check "home IPv6: …anything that is not an IPv6 address gives no network" "" "$(grep '^accepted' <<< "$n")"
    check "home IPv6: the length: 64 by default, 32 to 128, off turns it off" "=off 56=56 off=off OFF=off none=off 0=off 12=64 200=64 abc=64 064=64 " "$(sed -n 6p <<< "$n")"
    check "home IPv6: …unset is 64" 64 "$(sed -n 7p <<< "$n")"
    check "home IPv6: only global addresses (2000::/3) are the home's" "2001:db8::1 2a00:1450:4001::5 3fff::1 " "$(sed -n 8p <<< "$n")"

    # -- the sync: this server's source address for the internet is in the home network; the whitelist trusts that network
    cst_world data
    printf '198.51.100.9\n' > "$CST/.data/ddns-current-ip"
    cst_env CROWDSEC_HOME_IPV6_PREFIX 64
    printf '2001:db8:77:5:1c2d:3e4f:5a6b:7c8d\n' > "$CST/ip6-src"
    cst_call admin POST /crowdsec/trust '{"ip":"198.18.70.2"}'
    cst_is "home IPv6: a sync" 200
    check "home IPv6: the whitelist trusts the home address and the home IPv6 network" "198.18.70.2 198.51.100.9 2001:db8:77:5::/64" "$(sed -n 's/^    - //p' "$w" | sort | tr '\n' ' ' | sed 's/ $//')"
    check "home IPv6: …the sync remembers it (the ban guard reads it)" "2001:db8:77:5::/64" "$(jq -r '.home_ipv6' "$CST/.data/crowdsec-whitelist.json")"
    cst_call admin GET /crowdsec/allowlist
    cst_j "home IPv6: …the allowlist shows it as managed, not removable" '[.entries[] | select(.value == "2001:db8:77:5::/64") | "\(.kind) \(.source) \(.removable)"] | join(",")' "range managed false"
    # -- the provider hands out a new prefix: the next sync follows it, the old network is gone, CrowdSec reloads once
    printf '2001:db8:99:5:1c2d:3e4f:5a6b:7c8d\n' > "$CST/ip6-src"
    mark=$(cst_argv_n)
    cst_call admin POST /crowdsec/trust '{"ip":"198.18.70.2"}'
    check "home IPv6: a new prefix replaces the old one" "1 0" "$(grep -c '2001:db8:99:5::/64' "$w") $(grep -c '2001:db8:77:5::' "$w")"
    check "home IPv6: …CrowdSec reloads once" 1 "$(cst_argv_since "$mark" | sed 's/\\//g' | grep -c 'kill -s HUP CrowdSec')"
    mark=$(cst_argv_n)
    cst_call admin POST /crowdsec/trust '{"ip":"198.18.70.2"}'
    check "home IPv6: …and the same prefix again changes nothing" 0 "$(cst_argv_since "$mark" | sed 's/\\//g' | grep -c 'kill -s HUP CrowdSec')"
    # -- a router that hands out several /64s: the setting widens the network
    cst_env CROWDSEC_HOME_IPV6_PREFIX 56
    cst_call admin POST /crowdsec/trust '{"ip":"198.18.70.2"}'
    check "home IPv6: CROWDSEC_HOME_IPV6_PREFIX=56 trusts the /56" "2001:db8:99::/56" "$(sed -n 's/^    - //p' "$w" | grep ':')"
    # -- off; and no address to go by: no network at all (a unique local address is not what the world sees, and the internet is not reachable here)
    cst_env CROWDSEC_HOME_IPV6_PREFIX off
    cst_call admin POST /crowdsec/trust '{"ip":"198.18.70.2"}'
    check "home IPv6: off: no IPv6 network is trusted" "" "$(sed -n 's/^    - //p' "$w" | grep ':')"
    cst_env CROWDSEC_HOME_IPV6_PREFIX 64
    printf 'fd00:5::7\n' > "$CST/ip6-src"
    cst_call admin POST /crowdsec/trust '{"ip":"198.18.70.2"}'
    check "home IPv6: a unique local source address (NAT66) and no answer from the internet: none" "" "$(sed -n 's/^    - //p' "$w" | grep ':')"
    rm -f "$CST/ip6-src"
    cst_call admin POST /crowdsec/trust '{"ip":"198.18.70.2"}'
    check "home IPv6: no IPv6 route out: none, and the IPv4 whitelist is as before" "198.18.70.2 198.51.100.9" "$(sed -n 's/^    - //p' "$w" | sort | tr '\n' ' ' | sed 's/ $//')"
    check "home IPv6: …the sync remembers there is none" "" "$(jq -r '.home_ipv6' "$CST/.data/crowdsec-whitelist.json")"
    check "home IPv6: .env.example has it" 1 "$(grep -c '^CROWDSEC_HOME_IPV6_PREFIX=64$' "$ROOT/.env.example")"
    check "home IPv6: docs/CONFIGURATION.md lists it" yes "$(grep -q 'CROWDSEC_HOME_IPV6_PREFIX' "$ROOT/docs/CONFIGURATION.md" && echo yes || echo no)"
}

cst_part_allowlist() {
    echo "CrowdSec page: the allowlist"
    cst_allowlist_native
    cst_allowlist_parser
    cst_home_ipv6
}

# ---- media apps: CROWDSEC_MEDIA_APPS is a parser file beside the whitelist's (what CrowdSec makes of it is tests/crowdsec-media-apps.sh) ----------------

cst_ma_names() { sed -n 's/^.*service_addr) in \[\(.*\)\]$/\1/p' "$1" 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ $//'; }       # the backends a file lists, as written
cst_hups_since() { cst_argv_since "$1" | sed 's/\\//g' | grep -c 'kill -s HUP CrowdSec'; }                                        # how often CrowdSec was told to reload since a mark
cst_ma_sync() { cst_call admin POST /crowdsec/trust '{"ip":"198.18.70.1"}'; }                                                     # (a request that runs the sync)

cst_media_apps() {
    local f w mark ino wino loc bad n
    f="$CST/fake/rootfs/etc/crowdsec/parsers/s02-enrich/dcs-media-apps.yaml"
    w="$CST/fake/rootfs/etc/crowdsec/parsers/s02-enrich/dcs-whitelist.yaml"
    cst_world data
    printf '198.51.100.9\n' > "$CST/.data/ddns-current-ip"            # the home address DDNS keeps (no lookup on the network is needed)

    # -- not set at all: jellyfin is the default; the first sync writes both parser files and CrowdSec reloads once for the two
    sed -i '/^CROWDSEC_MEDIA_APPS=/d' "$CST/.env"
    mark=$(cst_argv_n)
    cst_ma_sync
    cst_is "media apps: a sync" 200
    check "media apps: the file is written (unset means jellyfin)" "'jellyfin'" "$(cst_ma_names "$f")"
    check "media apps: …the three expressions about what reached the app name it" 3 "$(grep -c "service_addr) in \['jellyfin'\]" "$f")"
    check "media apps: …four expressions in all (answered, missing media, the app's own 403, the proxy's 403)" 4 "$(grep -c '^    - >-$' "$f")"
    check "media apps: …a parser of CrowdSec's enrich stage with DCS's name" "custom/dcs-media-apps" "$(sed -n 's/^name: //p' "$f")"
    check "media apps: …one reload covers both files" 1 "$(cst_hups_since "$mark")"
    # -- a sync that finds nothing to do rewrites nothing and reloads nothing (the whitelist's file too: every sync used to rewrite it and reload CrowdSec)
    ino=$(stat -c %i "$f"); wino=$(stat -c %i "$w"); mark=$(cst_argv_n)
    cst_ma_sync
    cst_is "media apps: the same sync again" 200
    check "media apps: …nothing is rewritten" "$ino $wino" "$(stat -c %i "$f") $(stat -c %i "$w")"
    check "media apps: …and CrowdSec is not told to reload" 0 "$(cst_hups_since "$mark")"
    check "media apps: …no temporary file is left behind" 0 "$(find "${f%/*}" -name '*.tmp' | wc -l | tr -d ' ')"

    # -- the setting: any case, spaces, a name twice; a change reloads once, the same names in another spelling are no change
    cst_env CROWDSEC_MEDIA_APPS 'jellyfin, Plex ,plex'
    mark=$(cst_argv_n)
    cst_ma_sync
    check "media apps: two names, sorted, each once, lower case" "'jellyfin', 'plex'" "$(cst_ma_names "$f")"
    check "media apps: …a change reloads CrowdSec once" 1 "$(cst_hups_since "$mark")"
    ino=$(stat -c %i "$f"); mark=$(cst_argv_n)
    cst_env CROWDSEC_MEDIA_APPS 'PLEX,jellyfin'
    cst_ma_sync
    check "media apps: …the same names in another spelling are no change" "$ino 0" "$(stat -c %i "$f") $(cst_hups_since "$mark")"

    # -- a name that is not a plain host name is dropped, and no text of it reaches the file
    cst_env CROWDSEC_MEDIA_APPS "jellyfin,evil'] || true,zz yy,../x,-x,plex:32400,ünï,x\$(id),\`id\`,*,a;b"
    cst_ma_sync
    check "media apps: invalid names are dropped" "'jellyfin'" "$(cst_ma_names "$f")"
    check "media apps: …and nothing of them is in the file" 0 "$(grep -cF -e evil -e '|| true' -e '../x' -e 'plex' -e 'ünï' -e 'x$(id)' -e 'a;b' -e 'zz yy' "$f")"
    cst_env CROWDSEC_MEDIA_APPS "evil'],zz yy"
    mark=$(cst_argv_n)
    cst_ma_sync
    check "media apps: nothing valid left: the file goes, CrowdSec reloads once" "no 1" "$([[ -e "$f" ]] && echo yes || echo no) $(cst_hups_since "$mark")"
    mark=$(cst_argv_n)
    cst_ma_sync
    check "media apps: …and again: nothing to do" "no 0" "$([[ -e "$f" ]] && echo yes || echo no) $(cst_hups_since "$mark")"

    # -- empty turns it off; a hand edit of the managed file is put back
    cst_env CROWDSEC_MEDIA_APPS jellyfin
    cst_ma_sync
    check "media apps: on again" "'jellyfin'" "$(cst_ma_names "$f")"
    cst_env CROWDSEC_MEDIA_APPS
    mark=$(cst_argv_n)
    cst_ma_sync
    check "media apps: empty turns it off: the file goes, CrowdSec reloads once" "no 1" "$([[ -e "$f" ]] && echo yes || echo no) $(cst_hups_since "$mark")"
    check "media apps: …the whitelist's file stays" yes "$([[ -s "$w" ]] && echo yes || echo no)"
    mark=$(cst_argv_n)
    cst_ma_sync
    check "media apps: …switched off again: nothing to do" "no 0" "$([[ -e "$f" ]] && echo yes || echo no) $(cst_hups_since "$mark")"
    cst_env CROWDSEC_MEDIA_APPS jellyfin
    cst_ma_sync
    printf '# a hand edit\n' >> "$f"
    mark=$(cst_argv_n)
    cst_ma_sync
    check "media apps: a hand edit of the file is put back, CrowdSec reloads once" "0 1" "$(grep -c 'a hand edit' "$f") $(cst_hups_since "$mark")"

    # -- the loops that run the sync for ever keep the .env they started with: the sync reads the setting from the file, so it neither misses a change nor undoes it
    cst_env CROWDSEC_MEDIA_APPS plex
    n=$( (
        set +u
        export PATH="$CST/bin:$PATH" BASE_DIR="$CST"
        set --
        source "$CST_API" >/dev/null 2>&1
        set +e
        CROWDSEC_MEDIA_APPS='stale-value'
        _crowdsec_whitelist_sync; echo "rc=$?"
    ) 2>/dev/null | tail -n 1 )
    check "media apps: a process that started with another value follows .env" "rc=0 'plex'" "$n $(cst_ma_names "$f")"
    cst_env CROWDSEC_MEDIA_APPS jellyfin

    # -- no CrowdSec to keep it for (not deployed, or not running): nothing is written and nothing breaks
    for n in absent stopped; do
        cst_world "$n"
        cst_ma_sync
        cst_is "media apps: CrowdSec is $n: the sync still answers" 200
        cst_j "media apps: …and says nothing was synced" '.synced' false
        check "media apps: …no parser file anywhere" 0 "$(find "$CST/fake" -name 'dcs-*.yaml' 2>/dev/null | wc -l | tr -d ' ')"
    done

    # -- the setting through the API reaches the file
    cst_world data
    printf '198.51.100.9\n' > "$CST/.data/ddns-current-ip"
    cst_call admin POST /config '{"CROWDSEC_MEDIA_APPS":"jellyfin,plex"}'
    cst_is "media apps: POST /config takes the setting" 200
    check "media apps: …it is in .env" "CROWDSEC_MEDIA_APPS=jellyfin,plex" "$(grep '^CROWDSEC_MEDIA_APPS=' "$CST/.env")"
    cst_ma_sync
    check "media apps: …and in the parser file" "'jellyfin', 'plex'" "$(cst_ma_names "$f")"
    cst_call viewer POST /config '{"CROWDSEC_MEDIA_APPS":""}'
    cst_is "media apps: …a viewer may not change it" 403
    cst_call admin POST /config '{"CROWDSEC_MEDIA_APPZ":"x"}'
    cst_is "media apps: …and a misspelt key is refused" 400

    # -- a name means ASCII letters and digits only, whatever language the server speaks (in en_US.UTF-8 a range like [a-z] also matches ä)
    bad=""
    for loc in C C.UTF-8 en_US.UTF-8 de_DE.UTF-8 tr_TR.UTF-8 ar_EG.UTF-8 sv_SE.UTF-8 fr_FR.UTF-8; do
        [[ "$loc" == C ]] || locale -a 2>/dev/null | tr 'A-Z' 'a-z' | grep -qx "$(tr 'A-Z' 'a-z' <<< "${loc%%.*}").utf-\?8" || continue
        n=$( (
            set +u
            export LC_ALL="$loc" BASE_DIR="$CST"
            set --
            source "$CST_API" >/dev/null 2>&1
            set +e
            CROWDSEC_MEDIA_APPS=$'jellyfün,ä.lan,İstanbul,\xd9\xa3\xd9\xa3,x\xd9\xa3,jellyfin,Plex'
            _crowdsec_media_apps_list | tr '\n' ' '
        ) 2>/dev/null )
        [[ "$n" == "jellyfin plex " ]] || bad+="$loc: [$n] "
    done
    check "media apps: letters and digits of other alphabets are never part of a name" "" "$bad"
    # the order of the names in the file is one order for every process: a loop that runs in another language must not rewrite the file the requests wrote
    n=$( (
        set +u
        unset LC_ALL
        export LANG=en_US.UTF-8 BASE_DIR="$CST"
        set --
        source "$CST_API" >/dev/null 2>&1
        set +e
        CROWDSEC_MEDIA_APPS='a_b,ab,a.b,a-b'
        _crowdsec_media_apps_list | tr '\n' ' '
    ) 2>/dev/null )
    check "media apps: the names are in the same order whatever language the server speaks" "a-b a.b a_b ab " "$n"

    # -- the routers: a hub reaches Jellyfin in a VM at the VM's address, so the access log names it by router (<member>-<service>-dcs), and a route
    #    renamed by hand keeps its server http://jellyfin:8096 (Austin's hub: every ban of a friend watching came through such a route)
    local mh="$CST/ma-hub" cr
    cr="$mh/Stacks/networking-security/App-Data/Traefik/custom_routes"
    rm -rf "$mh"; mkdir -p "$cr/media-services" "$mh/.data"
    : > "$mh/Stacks/networking-security/docker-compose.yml"
    printf 'http:\n  routers:\n    watch-router:\n      rule: "Host(`watch.example.test`)"\n      service: "watch"   # renamed\n  services:\n    watch:\n      loadBalancer:\n        servers:\n          - url: "http://Jellyfin:8096"\n' > "$cr/media-services/jellyfin.yml"
    printf 'http:\n  middlewares:\n    media-chain:\n      chain:\n        middlewares:\n          - crowdsec-bouncer\n  routers:\n    listen:\n      service: navi@file\n    dash-router:\n      service: homarr\n    "evil'"'"'] || true":\n      service: navi\n  services:\n    navi:\n      loadBalancer:\n        servers:\n        - url: http://navidrome:4533/\n    homarr:\n      loadBalancer:\n        servers:\n          - url: "http://homarr:7575"\n' > "$cr/TraefikRoutes.yml"
    printf '{"http": {"routers": {"stray": {"service": "jellyfin"}}}}\n' > "$cr/fleet-members.yml"
    printf '{"hub": null, "members": [{"id": "media-services"}, {"id": "dev"}]}\n' > "$mh/.data/fleet.json"
    n=$( (
        set +u
        export BASE_DIR="$CST"
        set --
        source "$CST_API" >/dev/null 2>&1
        set +e
        COMPOSE_DIR="$mh/Stacks"; FLEET_FILE="$mh/.data/fleet.json"; unset APP_DATA_DIR
        CROWDSEC_MEDIA_APPS='jellyfin,Navidrome'
        _crowdsec_media_routers_list | tr '\n' ' '; echo
        _crowdsec_media_apps_sync "$mh/cfg"; echo "rc=$?"
        _crowdsec_media_apps_sync "$mh/cfg"; echo "rc=$?"
    ) 2>/dev/null )
    check "media apps: the routers: each name, a renamed route by its server, every VM of the fleet; not another app, not the fleet's own file" \
        "dev-jellyfin-dcs dev-navidrome-dcs jellyfin jellyfin-router listen media-services-jellyfin-dcs media-services-navidrome-dcs navidrome navidrome-router watch-router " \
        "$(head -n 1 <<< "$n")"
    check "media apps: …written once, and a second sync finds nothing to do" "rc=0 rc=1" "$(tail -n 2 <<< "$n" | tr '\n' ' ' | sed 's/ $//')"
    f="$mh/cfg/parsers/s02-enrich/dcs-media-apps.yaml"
    check "media apps: …all four expressions name the routers" 4 "$(grep -c "traefik_router_name, '@')\[0\]) in \['dev-jellyfin-dcs', " "$f")"
    check "media apps: …a router name that is not plain text never reaches the file, nor the fleet's own file" 0 "$(grep -cF -e evil -e stray "$f")"
    check "media apps: …the proxy's 403 needs the media app's router and no backend address" 1 "$(grep -c "evt.Parsed.service_addr == '' && evt.Meta.http_status == '403'" "$f")"
    check "media apps: …the app's own 403 needs its address (it reached the app)" 1 "$(grep -c "evt.Parsed.service_addr != ''" "$f")"
    check "media apps: …the file is YAML" yes "$(python3 -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); print("yes" if len(d["whitelist"]["expression"]) == 4 else "no")' "$f" 2>/dev/null || echo yes)"
    rm -rf "$mh"
    f="$CST/fake/rootfs/etc/crowdsec/parsers/s02-enrich/dcs-media-apps.yaml"

    # -- the setting goes where the others go
    check "media apps: .env.example has it, on by default" 1 "$(grep -c '^CROWDSEC_MEDIA_APPS=jellyfin$' "$ROOT/.env.example")"
    check "media apps: docs/CONFIGURATION.md lists it" yes "$(grep -q 'CROWDSEC_MEDIA_APPS' "$ROOT/docs/CONFIGURATION.md" && echo yes || echo no)"
    check "media apps: docs/CROWDSEC.md explains it" yes "$(grep -q 'CROWDSEC_MEDIA_APPS' "$ROOT/docs/CROWDSEC.md" && echo yes || echo no)"
    cst_env CROWDSEC_MEDIA_APPS jellyfin
}

cst_part_mediaapps() {
    echo "CrowdSec page: the media apps setting"
    cst_media_apps
}

# ---- bouncers, machines, the container, its log, the community list ------------------------------------------------------------------

cst_services_bouncers() {
    local key i mw chain names n0
    cst_world data traefik --traefik
    cst_call admin GET /crowdsec/bouncers
    cst_is "bouncers: the list" 200
    cst_j "bouncers" '.count' 2 '.name' dcs-traefik-bouncer '.dcs_bouncer.name' dcs-traefik-bouncer '.bouncers[0].dcs' true '.bouncers[0].status' active '.bouncers[0].type' crowdsec-traefik-bouncer \
        '.bouncers[1].name' test-bouncer '.bouncers[1].status' never '.bouncers[1].dcs' false '.traefik.present' true '.traefik_registerable' true '.enforcement.middleware_present' false '.enforcement.in_chain' false
    cst_t "bouncers: the routes directory is Traefik's" '.enforcement.routes_dir | endswith("/App-Data/Traefik/custom_routes")'
    cst_mock --mock-tick 1000
    cst_call admin GET /crowdsec/bouncers
    cst_j "bouncers: a bouncer that has not pulled for a quarter of an hour is idle" '.bouncers[0].status' idle
    cst_call viewer GET /crowdsec/bouncers
    cst_is "bouncers: a viewer may look" 200
    cst_call admin GET /crowdsec/machines
    cst_j "machines" '.count' 1 '.machines[0].id' localhost '.machines[0].validated' true '.machines[0].auth_type' password '.machines[0].datasources.file' 2
    cst_call viewer GET /crowdsec/machines
    cst_is "machines: a viewer may look" 200

    # -- a new bouncer: its key is shown once
    cst_world data traefik --traefik
    cst_call admin POST /crowdsec/bouncers '{"name":"my-fw-bouncer"}'
    cst_is "bouncers/add" 200
    cst_j "bouncers/add" '.success' true '.name' my-fw-bouncer '.shown_once' true
    key=$(jq -r '.api_key' <<< "$CST_BODY")
    check "bouncers/add: the key is 43 characters of base64" yes "$([[ "$key" =~ ^[A-Za-z0-9+/]{43}$ ]] && echo yes || echo no)"
    cst_call admin GET /crowdsec/bouncers
    cst_j "bouncers/add: it is in the list" '.count' 3 '.bouncers | map(select(.name == "my-fw-bouncer"))[0].status' never
    check "bouncers/add: …but the key is not" 0 "$(grep -cF -- "$key" <<< "$CST_BODY")"
    cst_call admin GET /crowdsec/status
    check "bouncers/add: …not in the status either" 0 "$(grep -cF -- "$key" <<< "$CST_BODY")"
    check "bouncers/add: …nor in the audit log, nor the API's files" 0 "$(grep -rlF -- "$key" "$CST/.data" "$CST/logs" "$CST/.api-auth" 2>/dev/null | wc -l | tr -d ' ')"
    check "bouncers/add: …nor in any command line" 0 "$(grep -cF -- "$key" "$CST/argv.log")"
    check "bouncers/add: the add is audited" 1 "$(grep -c '"action":"auth.crowdsec_bouncer_add".*my-fw-bouncer' "$CST/.data/audit.jsonl")"
    cst_call admin POST /crowdsec/bouncers '{"name":"my-fw-bouncer"}'
    cst_is "bouncers/add: a name in use" 409
    names=('a' '-x' '.x' '_x' 'x y' 'x;y' 'x|y' '../x' 'x/y' 'x$(id)' 'ünï' "$(head -c 64 /dev/zero | tr '\0' 'b')" '' 'x
y')
    for i in "${!names[@]}"; do cst_q "bn$i" admin POST /crowdsec/bouncers "$(jq -nc --arg n "${names[$i]}" '{name: $n}')"; done
    cst_q bnnone admin POST /crowdsec/bouncers '{}'
    cst_q bnnum admin POST /crowdsec/bouncers '{"name":12345}'
    cst_q bnjson admin POST /crowdsec/bouncers 'no'
    cst_q bnviewer viewer POST /crowdsec/bouncers '{"name":"viewer-made"}'
    cst_q bnnobody none POST /crowdsec/bouncers '{"name":"nobody-made"}'
    cst_run
    for i in "${!names[@]}"; do cst_use "bn$i"; cst_is "bouncers/add: the name '${names[$i]//$'\n'/\\n}' is refused" 400; done
    cst_use bnnone;   cst_is "bouncers/add: no name" 400
    cst_use bnnum;    cst_is "bouncers/add: a number is a name of 5 digits, 2 characters would do (it is allowed)" 200
    cst_use bnjson;   cst_is "bouncers/add: not JSON" 400
    cst_use bnviewer; cst_is "bouncers/add: a viewer may not" 403
    cst_use bnnobody; cst_is "bouncers/add: nobody may not" 401
    cst_call admin POST /crowdsec/bouncers "$(jq -nc --arg n "$(head -c 63 /dev/zero | tr '\0' 'c')" '{name: $n}')"
    cst_is "bouncers/add: 63 characters are fine" 200

    # -- deleting
    cst_call admin DELETE /crowdsec/bouncers/my-fw-bouncer
    cst_is "bouncers/delete" 200
    cst_j "bouncers/delete" '.success' true '.was_dcs_bouncer' false
    cst_call admin DELETE /crowdsec/bouncers/my-fw-bouncer
    cst_is "bouncers/delete: twice" 404
    local -a delbad=(a 'x%20y' 'x;y' '$(id)' '`id`' '..' '%2e%2e' 'x|y' 'ünï' '-x')
    for i in "${!delbad[@]}"; do cst_q "bd$i" admin DELETE "/crowdsec/bouncers/${delbad[$i]}"; done
    cst_q bdviewer viewer DELETE /crowdsec/bouncers/test-bouncer
    cst_q bdnobody none DELETE /crowdsec/bouncers/test-bouncer
    cst_run
    for i in "${!delbad[@]}"; do cst_use "bd$i"; cst_is "bouncers/delete: '${delbad[$i]}' is refused" 400; done
    cst_use bdviewer; cst_is "bouncers/delete: a viewer may not" 403
    cst_use bdnobody; cst_is "bouncers/delete: nobody may not" 401
    cst_call admin GET /crowdsec/bouncers
    cst_j "bouncers/delete: the refused ones changed nothing" '.count' 4
    cst_call admin DELETE /crowdsec/bouncers/dcs-traefik-bouncer
    cst_j "bouncers/delete: the one DCS made for Traefik says what that costs" '.was_dcs_bouncer' true '.message | length > 30' true
    cst_call admin GET /crowdsec/status
    cst_t "bouncers/delete: …and the status notices" '.bouncer.registered | not'
}

cst_services_register() {
    local mw k1 k2 chain a0 mark
    # -- the Traefik bouncer: a key, the middleware file, the chain
    cst_world data traefik --traefik
    a0=$(cst_audit_n '"action":"auth.crowdsec_bouncer_add".*dcs-traefik-bouncer (re-registered)')
    mark=$(cst_argv_n)
    cst_call admin POST /crowdsec/bouncers/register-traefik
    cst_is "register-traefik" 200
    cst_j "register-traefik" '.success' true '.name' dcs-traefik-bouncer
    mw=$(find "$CST/Stacks/networking-security/App-Data/Traefik/custom_routes" -name crowdsec-bouncer.yml | head -n 1)
    check "register-traefik: the middleware file is in the stack's routes" yes "$([[ "$mw" == */custom_routes/networking-security/crowdsec-bouncer.yml ]] && echo yes || echo no)"
    check "register-traefik: …private (it holds a key)" 600 "$(stat -c %a "$mw" 2>/dev/null)"
    k1=$(sed -n 's/^ *crowdsecLapiKey: *//p' "$mw" | tr -d '"')
    check "register-traefik: …with a key" yes "$([[ "$k1" =~ ^[A-Za-z0-9+/=_-]{20,}$ ]] && echo yes || echo no)"
    check "register-traefik: …that CrowdSec knows" 1 "$(cst_cs bouncers list -o json | jq '[.[] | select(.name == "dcs-traefik-bouncer")] | length')"
    check "register-traefik: …and is not in the answer" 0 "$(grep -cF -- "$k1" <<< "$CST_BODY")"
    chain=$(grep -rlE '^    traefik-chain:$' "$CST/Stacks/networking-security/App-Data/Traefik/custom_routes" | head -n 1)
    check "register-traefik: the chain names the middleware once" 1 "$(grep -c 'crowdsec-bouncer' "$chain")"
    cst_call admin POST /crowdsec/bouncers/register-traefik
    cst_is "register-traefik: again" 200
    k2=$(sed -n 's/^ *crowdsecLapiKey: *//p' "$mw" | tr -d '"')
    check "register-traefik: …a new key replaces the old one" yes "$([[ -n "$k2" && "$k2" != "$k1" ]] && echo yes || echo no)"
    check "register-traefik: …the chain still names it once" 1 "$(grep -c 'crowdsec-bouncer' "$chain")"
    check "register-traefik: …and CrowdSec has one bouncer of that name" 1 "$(cst_cs bouncers list -o json | jq '[.[] | select(.name == "dcs-traefik-bouncer")] | length')"
    check "register-traefik: Traefik's plugin was declared already: no restart" 0 "$(cst_argv_since "$mark" | grep -c 'restart Traefik')"
    check "register-traefik: it is audited (twice)" $(( a0 + 2 )) "$(cst_audit_n '"action":"auth.crowdsec_bouncer_add".*dcs-traefik-bouncer (re-registered)')"
    cst_call viewer POST /crowdsec/bouncers/register-traefik
    cst_is "register-traefik: a viewer may not" 403
    cst_call none POST /crowdsec/bouncers/register-traefik
    cst_is "register-traefik: nobody may not" 401
    # -- when there is nothing to register it for
    cst_world data none
    cst_call admin POST /crowdsec/bouncers/register-traefik
    cst_is "register-traefik: no Traefik on the server" 409
    cst_world data none --traefik
    cst_call admin POST /crowdsec/bouncers/register-traefik
    cst_is "register-traefik: Traefik without a routes directory to write to" 502
    cst_t "register-traefik: …says what is missing" '.message | length > 10'
    cst_call admin GET /crowdsec/bouncers
    cst_j "bouncers: Traefik without a routes directory is not registerable" '.traefik.present' true '.traefik_registerable' false
    cst_world stopped traefik --traefik
    cst_call admin POST /crowdsec/bouncers/register-traefik
    cst_is "register-traefik: CrowdSec is stopped" 409
}

cst_services_service() {
    local before a0 mark
    cst_world data traefik --traefik
    a0=$(cst_audit_n '"action":"auth.crowdsec_service".*restart CrowdSec')
    cst_call admin POST /crowdsec/service '{"action":"restart"}'
    cst_is "service: restart" 200
    cst_j "service: restart" '.success' true '.action' restart '.state' running
    mark=$(cst_argv_n)
    cst_call admin POST /crowdsec/service '{"action":"reload"}'
    cst_j "service: reload (a HUP, no restart)" '.action' reload '.state' running
    cst_call admin POST /crowdsec/service '{"action":"start"}'
    cst_j "service: start when it runs already" '.success' true '.state' running
    check "service: reload signalled the container, and restarted nothing" "1 0" "$(cst_argv_since "$mark" | sed 's/\\//g' | grep -c 'kill -s HUP CrowdSec') $(cst_argv_since "$mark" | grep -c 'restart CrowdSec')"
    check "service: it is audited" $(( a0 + 1 )) "$(cst_audit_n '"action":"auth.crowdsec_service".*restart CrowdSec')"
    cst_mock --mock-set status=exited
    cst_call admin POST /crowdsec/service '{"action":"reload"}'
    cst_is "service: reload of a stopped CrowdSec" 409
    cst_call admin POST /crowdsec/service '{"action":"start"}'
    cst_is "service: start a stopped CrowdSec" 200
    cst_j "service: …it is running" '.state' running
    cst_call admin GET /crowdsec/status
    cst_j "service: …and the status agrees" '.state' healthy
    cst_mock --mock-init stopped --traefik
    cst_call admin POST /crowdsec/service '{"action":"restart"}'
    cst_is "service: restart a stopped CrowdSec" 200
    cst_mock --mock-init crashloop --traefik
    cst_call admin POST /crowdsec/service '{"action":"restart"}'
    cst_is "service: restart a crash-looping CrowdSec" 200
    cst_call admin GET /crowdsec/status
    cst_j "service: …once its profiles are fine it runs" '.state' healthy
    cst_mock --mock-init absent --traefik
    cst_call admin POST /crowdsec/service '{"action":"start"}'
    cst_is "service: there is nothing to start" 404
    cst_mock --mock-init data --traefik
    cst_mock --mock-set docker_down=1
    cst_call admin POST /crowdsec/service '{"action":"start"}'
    cst_is "service: Docker does not answer" 503
    cst_mock --mock-set docker_down=0
    local -a bad=('{"action":"stop"}' '{"action":""}' '{}' '{"action":"restart;id"}' '{"action":"RESTART"}' '{"action":["restart"]}' 'nope' '[]')
    for before in "${!bad[@]}"; do cst_q "sv$before" admin POST /crowdsec/service "${bad[$before]}"; done
    cst_q svviewer viewer POST /crowdsec/service '{"action":"restart"}'
    cst_q svnobody none POST /crowdsec/service '{"action":"restart"}'
    cst_run
    for before in "${!bad[@]}"; do cst_use "sv$before"; cst_is "service: ${bad[$before]} is refused" 400; done
    cst_use svviewer; cst_is "service: a viewer may not" 403
    cst_use svnobody; cst_is "service: nobody may not" 401
}

cst_services_logs() {
    local i
    cst_world data traefik --traefik
    cst_q def admin GET /crowdsec/logs
    cst_q lapi admin GET '/crowdsec/logs?lapi=1&lines=500'
    cst_q nolapi admin GET '/crowdsec/logs?lapi=0&lines=500'
    cst_q warn admin GET '/crowdsec/logs?level=warn&lines=500'
    cst_q error admin GET '/crowdsec/logs?level=error&lines=500'
    cst_q q admin GET '/crowdsec/logs?q=STARTING&lines=500'
    cst_q min admin GET '/crowdsec/logs?lines=10'
    cst_q viewer viewer GET /crowdsec/logs
    local -a bad=('lines=9' 'lines=501' 'lines=abc' 'lines=-1' 'lines=1000' 'level=debug' 'level=ERROR' 'lapi=2' 'lapi=yes' 'lines=10%3Bid')
    for i in "${!bad[@]}"; do cst_q "lb$i" admin GET "/crowdsec/logs?${bad[$i]}"; done
    cst_q lnobody none GET /crowdsec/logs
    cst_run
    cst_use def;   cst_is "logs: the tail" 200
    cst_j "logs" '.container' CrowdSec '.state' running '.lapi_included' false '.count > 10' true '(.lines | length) == .count' true '.lines | map(.module == "lapi") | any' false
    cst_t "logs: a line has a time, a level and a message" '(.lines | all(has("time") and has("level") and has("module") and has("message"))) and (.lines | map(.level) | unique | all(. == "info" or . == "warn" or . == "error" or . == "debug"))'
    cst_t "logs: the fields after msg= stay on the line (idx=0)" '.lines | map(.message) | index("Starting parser routine idx=0") != null'
    cst_t "logs: …the module is shown apart, not in the text" '.lines | map(select(.message | test("module="))) | length == 0'
    cst_use lapi;  cst_j "logs: the API's own request lines on request" '.lapi_included' true '.lines | map(.module == "lapi") | any' true
    cst_use nolapi; cst_j "logs: …and left out otherwise" '.lapi_included' false '.lines | map(.module == "lapi") | any' false
    cst_use warn;  cst_j "logs: warnings and errors only" '.lines | map(.level) | unique | map(select(. != "warn" and . != "error")) | length' 0
    cst_use error; cst_j "logs: errors only" '.lines | map(.level) | unique | map(select(. != "error")) | length' 0
    cst_use q;     cst_j "logs: a word to look for" '.count > 0' true '.lines | all(.message | ascii_downcase | contains("starting"))' true
    cst_use min;   cst_is "logs: ten lines" 200
    cst_j "logs: …no more than that" '.lines | length <= 10' true
    cst_use viewer; cst_is "logs: a viewer may read" 200
    for i in "${!bad[@]}"; do cst_use "lb$i"; cst_is "logs: ?${bad[$i]} is refused" 400; done
    cst_use lnobody; cst_is "logs: nobody" 401
    cst_world crashloop traefik --traefik
    cst_call admin GET '/crowdsec/logs?level=error'
    cst_j "logs: a crash loop's errors" '.state' restarting '.count > 5' true
    cst_t "logs: …name the profile that broke it" '.lines | map(.message | test("profiles")) | any'
    cst_world stopped traefik --traefik
    cst_call admin GET /crowdsec/logs
    cst_is "logs: a stopped CrowdSec still has a log" 200
    cst_world absent traefik --traefik
    cst_call admin GET /crowdsec/logs
    cst_is "logs: no CrowdSec, no log" 404
    cst_mock --mock-set docker_down=1
    cst_call admin GET /crowdsec/logs
    cst_is "logs: Docker does not answer" 503
}

cst_services_community() {
    local v
    cst_world data traefik --traefik
    cst_call admin GET /crowdsec/community
    cst_is "community" 200
    cst_j "community" '.capi.registered' true '.capi.reachable' true '.capi.sharing' true '.capi.pulling' true '.capi.error' null '.console.enrolled' false '.console.registered' true '.community_decisions' 40
    cst_call viewer GET /crowdsec/community
    cst_is "community: a viewer may look" 200
    for v in error unregistered disabled; do
        cst_mock --mock-set capi=$v
        cst_call admin GET /crowdsec/community
        cst_j "community/$v" '.capi.reachable' false '.capi.error | length > 10' true '.community_decisions' 40
    done
    cst_j "community/error: a DNS failure is not called a refusal" '.capi.forbidden' null '.capi.error | test("cscli capi register")' false
    cst_mock --mock-set capi=forbidden
    cst_uncache; cst_call admin GET /crowdsec/community
    cst_j "community/forbidden: the 403 is explained, the community list is what is missing" '.capi.reachable' false '.capi.forbidden' true '.capi.error | test("Forbidden")' true \
        '.capi.error | test("cscli capi register")' true '.capi.error | test("keep working")' true '.community_decisions' 40
    cst_mock --mock-set capi=ok
}

cst_part_services() {
    echo "CrowdSec page: bouncers, machines, the container, its log, the community list"
    cst_services_bouncers
    cst_services_register
    cst_services_service
    cst_services_logs
    cst_services_community
}

# ---- the hub and simulation mode -----------------------------------------------------------------------------------------------------

cst_hub_read() {
    local i
    cst_world data traefik --traefik
    cst_q hub admin GET /crowdsec/hub
    cst_q viewer viewer GET /crowdsec/hub
    cst_q coll admin GET '/crowdsec/hub?type=collections&available=1&limit=5'
    cst_q parsers admin GET '/crowdsec/hub?type=parsers&available=1&q=nginx&limit=3'
    cst_q scen admin GET '/crowdsec/hub?type=scenarios&available=1&limit=1'
    cst_q qinj admin GET '/crowdsec/hub?type=collections&available=1&q=%24(id)'
    cst_q qhuge admin GET "/crowdsec/hub?type=collections&available=1&q=$(head -c 10000 /dev/zero | tr '\0' 'x')"
    cst_q qcase admin GET '/crowdsec/hub?type=collections&available=1&q=NGINX'
    local -a bad=('available=1' 'available=2' 'type=bogus' 'type=collections&available=1&limit=0' 'type=collections&available=1&limit=501' 'type=collections%3Bid&available=1' 'available=yes&type=parsers' 'type=Collections')
    for i in "${!bad[@]}"; do cst_q "hb$i" admin GET "/crowdsec/hub?${bad[$i]}"; done
    cst_q hnobody none GET /crowdsec/hub
    cst_run
    cst_use hub; cst_is "hub: installed items" 200
    cst_j "hub" '.counts.collections' 6 '.counts.scenarios' 53 '.counts.parsers' 11 '.counts.updates' 1 '.installed.collections | length' 6 \
        '.installed.collections | map(select(.update)) | map(.name) | join(",")' crowdsecurity/sshd '.installed.collections[0].enabled' true '.installed.collections[0].tainted' false \
        '.suggestions | length' 8 '.suggestions | map(select(.installed)) | length' 6 '.suggestions | map(select(.installed | not)) | map(.name) | join(",")' crowdsecurity/http-dos,crowdsecurity/iptables
    cst_t "hub: an installed item has a name, a version and a status" '.installed.parsers | all(has("name") and has("version") and has("status") and has("description"))'
    cst_t "hub: every suggestion says what it is for" '.suggestions | all((.title | length) > 2 and (.description | length) > 10 and (.group | length) > 2)'
    cst_use viewer; cst_is "hub: a viewer may look" 200
    cst_use coll;   cst_j "hub/available: collections" '.type' collections '.count' 171 '.total' 171 '.items | length' 5 '.items[0].installed' true '.items | map(select(.name == "crowdsecurity/sshd"))[0].update' true
    cst_use parsers; cst_j "hub/available: parsers matching a word" '.count' 3 '.total' 166 '.items | map(.name | test("nginx")) | all' true
    cst_use scen;   cst_j "hub/available: scenarios" '.count' 786 '.items | length' 1
    cst_t "hub/available: an update is only offered for what is installed" '.items | all((.update | not) or .installed)'
    cst_use qinj;   cst_j "hub/available: a search text is only text" '.count' 0
    cst_use qhuge;  cst_is "hub/available: a 10 kB search text is cut, not refused" 200
    cst_use qcase;  cst_t "hub/available: the search ignores case" '.count > 0'
    for i in "${!bad[@]}"; do cst_use "hb$i"; cst_is "hub: ?${bad[$i]} is refused" 400; done
    cst_use hnobody; cst_is "hub: nobody" 401
}

cst_hub_change() {
    local i mark
    cst_world data traefik --traefik
    mark=$(cst_argv_n)
    cst_call admin POST /crowdsec/hub/install '{"type":"collections","name":"crowdsecurity/nginx"}'
    cst_is "hub/install: a collection" 200
    cst_j "hub/install" '.success' true '.action' install '.type' collections '.name' crowdsecurity/nginx '.message | test("crowdsecurity/nginx installed")' true '.message | test("reloaded")' true
    cst_call admin GET /crowdsec/hub
    cst_j "hub/install: it is there, with what it brings" '.counts.collections' 7 '.counts.scenarios' 54 '.counts.parsers' 12 '.installed.collections | map(.name) | index("crowdsecurity/nginx") != null' true
    check "hub/install: CrowdSec was told to reload" 1 "$(cst_argv_since "$mark" | sed 's/\\//g' | grep -c 'kill -s HUP CrowdSec')"
    check "hub/install: it is audited" 1 "$(grep -c '"action":"auth.crowdsec_hub".*install collections crowdsecurity/nginx' "$CST/.data/audit.jsonl")"
    cst_call admin POST /crowdsec/hub/install '{"type":"collections","name":"crowdsecurity/nginx"}'
    cst_is "hub/install: again is not an error" 200
    cst_call admin POST /crowdsec/hub/remove '{"type":"collections","name":"crowdsecurity/nginx"}'
    cst_is "hub/remove: a collection" 200
    cst_j "hub/remove" '.action' remove '.message | test("crowdsecurity/nginx removed")' true
    cst_call admin POST /crowdsec/hub/remove '{"type":"scenarios","name":"crowdsecurity/ssh-bf"}'
    cst_is "hub/remove: a scenario that an installed collection needs stays" 409
    cst_j "hub/remove: …and the answer says so" '.reason' still_installed '.message | test("still installed")' true
    cst_call admin POST /crowdsec/hub/remove '{"type":"collections","name":"crowdsecurity/sshd"}'
    cst_is "hub/remove: so does a collection that another one includes" 409
    check "hub/remove: …the audit log has none of the two (nothing was removed)" 0 "$(grep -c '"action":"auth.crowdsec_hub".*remove .* crowdsecurity/ssh' "$CST/.data/audit.jsonl")"
    cst_call admin GET /crowdsec/hub
    cst_j "hub/remove: gone with what it brought" '.counts.collections' 6 '.counts.scenarios' 53 '.counts.parsers' 11
    cst_call admin POST /crowdsec/hub/install '{"type":"parsers","name":"crowdsecurity/nginx-logs"}'
    cst_is "hub/install: a parser" 200
    cst_call admin POST /crowdsec/hub/install '{"type":"scenarios","name":"crowdsecurity/nginx-req-limit-exceeded"}'
    cst_is "hub/install: a scenario" 200
    cst_call admin POST /crowdsec/hub/install '{"type":"collections","name":"crowdsecurity/nope-nope"}'
    cst_is "hub/install: a name the hub does not have" 404
    local -a bad=('{"type":"bogus","name":"a/b"}' '{"type":"collections","name":"-h"}' '{"type":"collections","name":"--help"}' '{"type":"collections","name":"a;id"}' '{"type":"collections","name":"$(id)"}'
                  '{"type":"collections","name":"a b"}' '{"type":"collections","name":"../x"}' '{"type":"collections","name":""}' '{"type":"collections"}' '{"name":"crowdsecurity/nginx"}'
                  '{"type":"collections;id","name":"a/b"}' '{"type":"appsec-rules","name":"a/b"}' '{"type":["collections"],"name":"a/b"}' 'nope' '[]')
    for i in "${!bad[@]}"; do cst_q "hi$i" admin POST /crowdsec/hub/install "${bad[$i]}"; cst_q "hr$i" admin POST /crowdsec/hub/remove "${bad[$i]}"; done
    cst_q hnm admin POST /crowdsec/hub/install "$(jq -nc --arg n "$(head -c 101 /dev/zero | tr '\0' 'a')" '{type: "collections", name: $n}')"
    cst_q hviewer viewer POST /crowdsec/hub/install '{"type":"collections","name":"crowdsecurity/nginx"}'
    cst_q hviewer2 viewer POST /crowdsec/hub/update
    cst_q hviewer3 viewer POST /crowdsec/hub/upgrade
    cst_q hnobody none POST /crowdsec/hub/remove '{"type":"collections","name":"crowdsecurity/nginx"}'
    cst_run
    for i in "${!bad[@]}"; do
        cst_use "hi$i"; cst_is "hub/install: ${bad[$i]} is refused" 400
        cst_use "hr$i"; cst_is "hub/remove: ${bad[$i]} is refused" 400
    done
    cst_use hnm;      cst_is "hub/install: a name of 101 characters is refused" 400
    cst_use hviewer;  cst_is "hub/install: a viewer may not" 403
    cst_use hviewer2; cst_is "hub/update: a viewer may not" 403
    cst_use hviewer3; cst_is "hub/upgrade: a viewer may not" 403
    cst_use hnobody;  cst_is "hub/remove: nobody may not" 401
    cst_call admin GET /crowdsec/hub
    cst_j "hub: the refused ones changed nothing" '.counts.collections' 6
    cst_call admin POST /crowdsec/hub/update
    cst_is "hub/update: the index" 200
    cst_j "hub/update" '.success' true '.detail | length > 5' true
    cst_call admin POST /crowdsec/hub/upgrade
    cst_is "hub/upgrade: everything installed" 200
    cst_j "hub/upgrade" '.success' true
    cst_call admin GET /crowdsec/hub
    cst_j "hub/upgrade: nothing is outdated now" '.counts.updates' 0
    cst_mock --mock-set docker_down=1
    cst_call admin POST /crowdsec/hub/install '{"type":"collections","name":"crowdsecurity/nginx"}'
    cst_is "hub/install: Docker does not answer" 503
    cst_mock --mock-set docker_down=0
}

cst_simulation() {
    local i
    cst_world data traefik --traefik
    cst_call admin GET /crowdsec/simulation
    cst_is "simulation: the state" 200
    cst_j "simulation" '.global' false '.exclusions | length' 0 '.simulated_count' 0 '.scenarios | length' 53 '.scenarios[0].simulated' false '.scenarios | all(has("name") and has("description"))' true
    cst_call viewer GET /crowdsec/simulation
    cst_is "simulation: a viewer may look" 200
    cst_call admin POST /crowdsec/simulation '{"scenario":"crowdsecurity/http-probing","enabled":true}'
    cst_is "simulation: one scenario only alerts" 200
    cst_j "simulation" '.success' true '.global' false '.exclusions | join(",")' crowdsecurity/http-probing
    cst_call admin GET /crowdsec/simulation
    cst_j "simulation: …the list says so" '.simulated_count' 1 '.scenarios | map(select(.simulated)) | map(.name) | join(",")' crowdsecurity/http-probing
    check "simulation: CrowdSec's file agrees" "crowdsecurity/http-probing" "$(sed -n 's/^ *- //p' "$CST/fake/rootfs/etc/crowdsec/simulation.yaml")"
    cst_call admin POST /crowdsec/simulation '{"scenario":"crowdsecurity/http-probing","enabled":false}'
    cst_j "simulation: …and it bans again" '.exclusions | length' 0
    cst_call admin POST /crowdsec/simulation '{"global":true,"enabled":true}'
    cst_is "simulation: everything only alerts" 200
    cst_call admin GET /crowdsec/simulation
    cst_j "simulation/global" '.global' true '.simulated_count' 53 '.exclusions | length' 0
    cst_call admin POST /crowdsec/simulation '{"scenario":"crowdsecurity/ssh-bf","enabled":false}'
    cst_j "simulation/global: one scenario is taken out" '.global' true '.exclusions | join(",")' crowdsecurity/ssh-bf
    cst_call admin GET /crowdsec/simulation
    cst_j "simulation/global: …52 of 53 alert only" '.simulated_count' 52 '.scenarios | map(select(.name == "crowdsecurity/ssh-bf"))[0].simulated' false
    cst_call admin POST /crowdsec/simulation '{"global":true,"enabled":false}'
    cst_j "simulation/global: off again, the exclusions are cleared with it" '.global' false '.exclusions | length' 0
    check "simulation: it is audited" 1 "$(grep -c '"action":"auth.crowdsec_simulation".*crowdsecurity/http-probing enable' "$CST/.data/audit.jsonl")"
    cst_call admin POST /crowdsec/simulation '{"scenario":"crowdsecurity/nope","enabled":true}'
    cst_is "simulation: a scenario that is not installed" 404
    local -a bad=('{"scenario":"crowdsecurity/ssh*","enabled":true}' '{"scenario":"","enabled":true}' '{"enabled":true}' '{"scenario":"crowdsecurity/ssh-bf"}' '{"scenario":"crowdsecurity/ssh-bf","enabled":"yes"}'
                  '{"scenario":"crowdsecurity/ssh-bf","enabled":1}' '{"scenario":"-h","enabled":true}' '{"scenario":"a;id","enabled":true}' '{"scenario":"$(id)","enabled":true}' '{"scenario":["a"],"enabled":true}' 'nope' '[]')
    for i in "${!bad[@]}"; do cst_q "sb$i" admin POST /crowdsec/simulation "${bad[$i]}"; done
    cst_q sbviewer viewer POST /crowdsec/simulation '{"scenario":"crowdsecurity/ssh-bf","enabled":true}'
    cst_q sbnobody none POST /crowdsec/simulation '{"scenario":"crowdsecurity/ssh-bf","enabled":true}'
    cst_run
    for i in "${!bad[@]}"; do cst_use "sb$i"; cst_is "simulation: ${bad[$i]} is refused" 400; done
    cst_use sbviewer; cst_is "simulation: a viewer may not" 403
    cst_use sbnobody; cst_is "simulation: nobody may not" 401
    cst_call admin GET /crowdsec/simulation
    cst_j "simulation: nothing changed by the refused ones" '.global' false '.exclusions | length' 0
}

cst_part_hub() {
    echo "CrowdSec page: the hub and simulation mode"
    cst_hub_read
    cst_hub_change
    cst_simulation
}

# ---- the Traefik bouncer plugin: what Traefik's own files say about it, its settings, and which routes it checks -----------------------------

cst_tr()  { printf '%s' "$CST/Stacks/networking-security/App-Data/Traefik"; }                 # Traefik's App-Data in the test install
cst_mwf() { printf '%s' "$(cst_tr)/custom_routes/networking-security/crowdsec-bouncer.yml"; }  # the middleware file DCS writes when it registers the bouncer
cst_mw_key() { sed -n 's/^ *crowdsecLapiKey: *//p' "$1" | tr -d '"'; }                        # the bouncer's key, as a middleware file has it

# cst_tf_set BLOCK — the "experimental:" section of Traefik's static config becomes BLOCK (nothing: it is taken out); the file stays older than Traefik's start
cst_tf_set() {
    local tf; tf="$(cst_tr)/traefik.yml"
    cp -f "$ROOT/.templates/traefik/config/traefik.yml" "$tf"          # (always from the shipped file, whatever an earlier call made of it)
    awk -v blk="$1" '/^experimental:/ { if (blk != "") print blk; skip = 1; next } skip && /^[^ \t#]/ { skip = 0 } !skip { print }' "$tf" > "$tf.new" && mv -f "$tf.new" "$tf"
    touch -d '30 days ago' "$tf"; cst_uncache
}

# the paths of every file below Traefik's stack and the state DCS keeps for CrowdSec (a fingerprint: what is there, not what it holds)
cst_files() { find "$CST/Stacks" "$CST/.data/crowdsec" -type f 2>/dev/null | LC_ALL=C sort | sha1sum | cut -c1-40; }

# how many of the files that the arguments name are there (a glob that matches nothing stays as it is, and is not a file)
cst_count() { local f n=0; for f in "$@"; do [[ -e "$f" ]] && n=$(( n + 1 )); done; printf '%s' "$n"; }

# cst_tf_newer — Traefik's static configuration changed after Traefik started (it started ten minutes ago, the file was written now)
cst_tf_newer() {
    local s="$CST/fake/state.json"
    touch "$(cst_tr)/traefik.yml"
    jq --argjson t "$(( $(date +%s) - 600 ))" '.containers.Traefik.started = $t' "$s" > "$s.new" && mv -f "$s.new" "$s"
    cst_uncache
}

# cst_pulled NAME SECONDS — the stand-in says that the bouncer NAME last asked CrowdSec for decisions SECONDS ago
cst_pulled() {
    local s="$CST/fake/state.json"
    jq --arg n "$1" --argjson t "$(( $(date +%s) - $2 ))" '(.cs.bouncers[] | select(.name == $n) | .last_pull) = $t' "$s" > "$s.new" && mv -f "$s.new" "$s"
    cst_uncache
}

# the world of this part: CrowdSec with data, Traefik with the shipped configuration, the bouncer registered (unless "bare")
cst_plugin_world() {
    cst_world data traefik --traefik
    [[ "${1:-}" == bare ]] && return 0
    cst_call admin POST /crowdsec/bouncers/register-traefik
    [[ "$CST_ST" == 200 ]] || check "plugin: the bouncer can be registered in the test world" 200 "$CST_ST"
    cst_uncache
}

# ---- what Traefik's own files say (the status) -------------------------------------------------------------------------------------

cst_plugin_status() {
    local i what block ok name ver crlf mw k mark
    local -a decl=(
        'another name for the module|experimental:\n  plugins:\n    crowdsec:\n      moduleName: github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin\n      version: v1.5.0|true|crowdsec|v1.5.0|no'
        'single quotes, capitals, after another plugin|experimental:\n  plugins:\n    geoblock:\n      moduleName: "github.com/PascalMinder/geoblock"\n      version: "v0.3.3"\n    bouncer:\n      moduleName: \047github.com/MaxLeRebourg/CrowdSec-Bouncer-Traefik-Plugin\047\n      version: \047v1.4.0\047|true|bouncer|v1.4.0|no'
        'other plugins only|experimental:\n  plugins:\n    geoblock:\n      moduleName: "github.com/PascalMinder/geoblock"\n      version: "v0.3.3"|false|||no'
        'the plugin commented out|experimental:\n  plugins:\n    #crowdsec-bouncer-traefik-plugin:\n    #  moduleName: "github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin"\n    #  version: "v1.4.4"\n    geoblock:\n      moduleName: "github.com/PascalMinder/geoblock"\n      version: "v0.3.3"|false|||no'
        'no version|experimental:\n  plugins:\n    crowdsec-bouncer-traefik-plugin:\n      moduleName: "github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin"|true|crowdsec-bouncer-traefik-plugin||no'
        'outside the experimental section|plugins:\n  crowdsec-bouncer-traefik-plugin:\n    moduleName: "github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin"\n    version: "v1.4.4"|false|||no'
        'a module with a longer name|experimental:\n  plugins:\n    crowdsec:\n      moduleName: "github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin-fork"\n      version: "v1"|false|||no'
        'no experimental section at all||false|||no'
        'a comment after experimental:|experimental:  # what Traefik downloads\n  plugins:\n    crowdsec-bouncer-traefik-plugin:\n      moduleName: "github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin"\n      version: "v1.4.4"|true|crowdsec-bouncer-traefik-plugin|v1.4.4|no'
        'comments after the module and the version|experimental:\n  plugins:\n    crowdsec-bouncer-traefik-plugin:\n      moduleName: "github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin"  # the bouncer\n      version: "v1.4.4"  # pinned|true|crowdsec-bouncer-traefik-plugin|v1.4.4|no'
        'Windows line ends|experimental:\n  plugins:\n    crowdsec-bouncer-traefik-plugin:\n      moduleName: "github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin"\n      version: "v1.4.4"|true|crowdsec-bouncer-traefik-plugin|v1.4.4|yes'
    )
    # -- as shipped, the bouncer not registered yet: Traefik knows the plugin, there is no middleware to configure
    cst_plugin_world bare
    cst_call admin GET /crowdsec/status
    cst_is "plugin/status: Traefik's configuration as shipped" 200
    cst_j "plugin/status: the plugin is declared" '.enforcement.plugin.declared' true '.enforcement.plugin.name' crowdsec-bouncer-traefik-plugin '.enforcement.plugin.version' v1.4.4 \
        '.enforcement.plugin.module' github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin '.enforcement.plugin.traefik_running' true '.enforcement.plugin.loaded' true
    cst_j "plugin/status: …there is no middleware file yet" '.enforcement.plugin.settings' '{}' '.enforcement.plugin.mode' null '.enforcement.plugin.managed' false '.enforcement.plugin.key_present' false \
        '.enforcement.middleware_present' false '.enforcement.middleware_mtime' 0 '.issues | map(.code) | join(",")' bouncer_unchained,hub_updates
    # -- registered: what the middleware file says
    cst_call admin POST /crowdsec/bouncers/register-traefik
    cst_is "plugin/status: registering the bouncer" 200
    mw=$(cst_mwf); k=$(cst_mw_key "$mw"); cst_uncache
    cst_call admin GET /crowdsec/status
    cst_j "plugin/status: the middleware file as the template writes it" '.enforcement.plugin.mode' live '.enforcement.plugin.managed' false '.enforcement.plugin.key_present' true '.enforcement.plugin.loaded' true \
        '.enforcement.plugin.settings.enabled' true '.enforcement.plugin.settings.log_level' INFO '.enforcement.plugin.settings.update_interval' 60 '.enforcement.plugin.settings.default_decision_seconds' 60 \
        '.enforcement.plugin.settings.http_timeout' 10 '.enforcement.plugin.settings.mode' live '.enforcement.plugin.settings.has_key' true \
        '.enforcement.plugin.settings.client_trusted_ips | join(",")' 10.1.0.0/24 '.enforcement.plugin.settings.forwarded_headers_trusted_ips | length' 23 \
        '.enforcement.plugin.settings.forwarded_headers_trusted_ips | last' 10.1.0.0/24 '.enforcement.middleware_present' true '.enforcement.in_chain' true
    cst_t "plugin/status: …the middleware's age is the file's" '.enforcement.middleware_mtime > 1700000000 and .enforcement.middleware_mtime <= now'
    check "plugin/status: …and the bouncer's key is nowhere in it" 0 "$(grep -cF -- "$k" <<< "$CST_BODY")"
    cst_j "plugin/status: a bouncer that has not been asked for anything is idle, nothing else is wrong" '.issues | map(.code) | join(",")' bouncer_idle,hub_updates
    cst_call viewer GET /crowdsec/status
    cst_j "plugin/status: a viewer sees the same" '.enforcement.plugin.declared' true '.enforcement.plugin.loaded' true '.enforcement.plugin.key_present' true
    check "plugin/status: …without the key" 0 "$(grep -cF -- "$k" <<< "$CST_BODY")"
    # -- every way Traefik's static configuration may declare the plugin
    for i in "${!decl[@]}"; do
        IFS='|' read -r what block ok name ver crlf <<< "${decl[$i]}"
        block=$(printf '%b' "$block"); [[ "$crlf" != yes ]] || block=$(sed 's/$/\r/' <<< "$block")
        cst_tf_set "$block"
        cst_call admin GET /crowdsec/status
        cst_j "plugin/status/declared ($what)" '.enforcement.plugin.declared' "$ok" '.enforcement.plugin.name' "$name" '.enforcement.plugin.version' "$ver" \
            '.enforcement.plugin.loaded' "$([[ "$ok" == true ]] && echo true || echo null)"
    done
    # -- the plugin is not declared: the middleware would be refused, every route in the chain would answer 404
    cst_plugin_world
    cst_tf_set $'experimental:\n  plugins:\n    geoblock:\n      moduleName: "github.com/PascalMinder/geoblock"\n      version: "v0.3.3"'
    cst_call admin GET /crowdsec/status
    cst_j "plugin/status/undeclared: the warning and its fix" '.issues | map(.code) | join(",")' plugin_undeclared,bouncer_idle,hub_updates '.issues[0].severity' warning '.issues[0].fix.id' register_bouncer \
        '.issues[0].fix.kind' api '.issues[0].fix.method' POST '.issues[0].fix.path' /crowdsec/bouncers/register-traefik '.issues[0].fix.primary' true '.issues[0].title | length > 5' true '.issues[0].detail | test("404")' true
    mark=$(cst_argv_n)
    cst_call admin POST /crowdsec/bouncers/register-traefik
    cst_is "plugin/status/undeclared: the fix" 200
    cst_t "plugin/status/undeclared: …says that Traefik was restarted to load the plugin" '.message | test("Traefik restarted to load the bouncer plugin")'
    cst_t "plugin/status/undeclared: …in plain words (docker's own answer, the name of the container, is not in it)" '.message | test("Traefik Traefik") | not'
    check "plugin/status/undeclared: …the plugin is declared once, in the version the template pins" "1 v1.4.4" "$(grep -c 'moduleName: "github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin"' "$(cst_tr)/traefik.yml") $(sed -n '/crowdsec-bouncer-traefik-plugin"/{n;s/.*version: "\(.*\)"/\1/p}' "$(cst_tr)/traefik.yml")"
    check "plugin/status/undeclared: …and Traefik was restarted once" 1 "$(cst_argv_since "$mark" | grep -c '^restart Traefik')"
    check "plugin/status/undeclared: …the other plugins are still there" 1 "$(grep -c 'PascalMinder/geoblock' "$(cst_tr)/traefik.yml")"
    cst_uncache; cst_call admin GET /crowdsec/status
    cst_j "plugin/status/undeclared: after the fix nothing is wrong" '.enforcement.plugin.declared' true '.enforcement.plugin.loaded' true '.issues | map(.code) | join(",")' bouncer_idle,hub_updates
    # -- declared after Traefik started: Traefik loads plugins only when it starts
    cst_tf_newer
    cst_call admin GET /crowdsec/status
    cst_j "plugin/status/not loaded: the warning and its fix" '.enforcement.plugin.declared' true '.enforcement.plugin.loaded' false '.issues | map(.code) | join(",")' plugin_not_loaded,bouncer_idle,hub_updates \
        '.issues[0].fix.id' restart_traefik '.issues[0].fix.kind' api '.issues[0].fix.method' POST '.issues[0].fix.path' /crowdsec/traefik/restart '.issues[0].fix.primary' true
    cst_call admin POST /crowdsec/traefik/restart
    cst_is "plugin/status/not loaded: the fix" 200
    cst_uncache; cst_call admin GET /crowdsec/status
    cst_j "plugin/status/not loaded: after the restart the plugin is loaded" '.enforcement.plugin.loaded' true '.issues | map(.code) | join(",")' bouncer_idle,hub_updates
    # -- Traefik is not running: nothing can be said about what it loaded, and it is not asked for anything
    cst_tf_newer; cst_dk stop Traefik >/dev/null; cst_uncache
    cst_call admin GET /crowdsec/status
    cst_j "plugin/status/stopped: a Traefik that is not running loaded nothing, and is not blamed" '.enforcement.plugin.traefik_running' false '.enforcement.plugin.loaded' null '.enforcement.plugin.declared' true \
        '.issues | map(.code) | join(",")' bouncer_idle,hub_updates
    cst_dk start Traefik >/dev/null; touch -d '30 days ago' "$(cst_tr)/traefik.yml"; cst_uncache
    # -- the bouncer was registered again after the middleware file was written: the key in the file is a dead one
    touch -d '10 minutes ago' "$mw"; cst_uncache
    cst_call admin GET /crowdsec/status
    cst_j "plugin/status/key stale: the warning and its fix" '.issues | map(.code) | join(",")' bouncer_key_stale,bouncer_idle,hub_updates '.issues[0].fix.id' register_bouncer '.issues[0].severity' warning \
        '.issues[0].detail | test("key")' true '.enforcement.plugin.key_present' true
    touch -d '60 seconds ago' "$mw"; cst_uncache
    cst_call admin GET /crowdsec/status
    cst_j "plugin/status/key stale: a file a minute older than the bouncer is fine (two minutes of grace)" '.issues | map(.code) | join(",")' bouncer_idle,hub_updates
    touch -d '10 minutes ago' "$mw"
    cst_call admin POST /crowdsec/bouncers/register-traefik
    cst_uncache; cst_call admin GET /crowdsec/status
    cst_j "plugin/status/key stale: registering again writes a fresh key and the warning is gone" '.issues | map(.code) | join(",")' bouncer_idle,hub_updates
    check "plugin/status/key stale: …the key changed" yes "$([[ -n "$(cst_mw_key "$mw")" && "$(cst_mw_key "$mw")" != "$k" ]] && echo yes || echo no)"
    # -- Traefik has not asked for a decision for over half an hour
    cst_pulled dcs-traefik-bouncer 2400
    cst_call admin GET /crowdsec/status
    cst_j "plugin/status/stale: the warning" '.issues | map(.code) | join(",")' bouncer_stale,hub_updates '.issues[0].fix.id' register_bouncer '.issues[0].fix.primary' false '.issues[0].severity' warning
    cst_pulled dcs-traefik-bouncer 1700
    cst_call admin GET /crowdsec/status
    cst_j "plugin/status/stale: 28 minutes are not yet" '.issues | map(.code) | join(",")' hub_updates
    cst_pulled dcs-traefik-bouncer 1900
    cst_call admin GET /crowdsec/status
    cst_j "plugin/status/stale: 32 minutes are" '.issues | map(.code) | join(",")' bouncer_stale,hub_updates
    cst_dk stop Traefik >/dev/null; cst_uncache
    cst_call admin GET /crowdsec/status
    cst_j "plugin/status/stale: …but not while Traefik is stopped" '.issues | map(.code) | join(",")' hub_updates
    cst_dk start Traefik >/dev/null; cst_tf_newer
    cst_call admin GET /crowdsec/status
    cst_j "plugin/status: several warnings at once come in a fixed order" '.issues | map(.code) | join(",")' plugin_not_loaded,bouncer_stale,hub_updates
}

# ---- GET /crowdsec/plugin: the settings, the defaults, the limits ------------------------------------------------------------------

cst_plugin_get() {
    local mw k dflt
    cst_world data none
    cst_call admin GET /crowdsec/plugin
    cst_is "plugin/get: no Traefik on this server" 200
    cst_j "plugin/get: …nothing to set up, and why" '.available' false '.reason | test("Traefik was not found")' true '.plugin.declared' false '.plugin.settings' '{}'
    cst_call admin PUT /crowdsec/plugin '{"settings":{"mode":"stream"}}'
    cst_is "plugin/put: no Traefik on this server" 409
    cst_world data traefik --traefik
    cst_call admin GET /crowdsec/plugin
    cst_is "plugin/get: Traefik, the bouncer not registered" 200
    cst_j "plugin/get: …it must be registered first" '.available' false '.reason | test("not registered yet")' true '.plugin.declared' true '.plugin.name' crowdsec-bouncer-traefik-plugin
    cst_call admin PUT /crowdsec/plugin '{"settings":{"mode":"stream"}}'
    cst_is "plugin/put: the bouncer is not registered" 409
    cst_t "plugin/put: …and the answer says to register it first" '.message | test("register it first")'
    cst_call admin PUT /crowdsec/plugin '{"settings":{"mode":"turbo"}}'
    cst_is "plugin/put: …a bad setting is not looked at before that" 409
    cst_call admin PUT /crowdsec/plugin 'nope'
    cst_is "plugin/put: …but a body that is no JSON object is refused first" 400
    check "plugin/put: none of it wrote anything" "0 0" "$(find "$(cst_tr)/custom_routes" -name 'crowdsec-bouncer.yml*' | wc -l | tr -d ' ') $([[ -e "$CST/.data/crowdsec/plugin.json" ]] && echo 1 || echo 0)"
    # -- registered: what the template wrote, what the page shows
    cst_call admin POST /crowdsec/bouncers/register-traefik
    mw=$(cst_mwf); k=$(cst_mw_key "$mw")
    cst_call admin GET /crowdsec/plugin
    cst_is "plugin/get: registered" 200
    cst_j "plugin/get: the file and who manages it" '.available' true '.file | endswith("networking-security/crowdsec-bouncer.yml")' true '.managed' false '.plugin.managed' false '.plugin.key_present' true
    cst_j "plugin/get: the settings the template wrote" '.settings.mode' live '.settings.update_interval' 60 '.settings.default_decision_seconds' 60 '.settings.http_timeout' 10 '.settings.remediation_status_code' 403 \
        '.settings.log_level' INFO '.settings.trust_home' false '.settings.client_trusted_ips | length' 0 '.settings.forwarded_headers_trusted_ips | length' 22 '.settings.forwarded_headers_trusted_ips | index("10.1.0.0/24")' null \
        '.settings.forwarded_headers_trusted_ips | first' 173.245.48.0/20
    cst_j "plugin/get: the defaults" '.defaults.mode' live '.defaults.update_interval' 60 '.defaults.default_decision_seconds' 60 '.defaults.http_timeout' 10 '.defaults.remediation_status_code' 403 \
        '.defaults.log_level' INFO '.defaults.trust_home' true '.defaults.client_trusted_ips | length' 0 '.defaults.forwarded_headers_trusted_ips | length' 22 \
        '(.defaults.forwarded_headers_trusted_ips | sort) == (.settings.forwarded_headers_trusted_ips | sort)' true
    cst_j "plugin/get: the limits" '.limits.update_interval | join("-")' 10-3600 '.limits.default_decision_seconds | join("-")' 10-3600 '.limits.http_timeout | join("-")' 1-60 \
        '.limits.remediation_status_code | join("-")' 400-599 '.limits.list_max' 64 '.limits.forwarded_max' 128
    cst_j "plugin/get: the LAN Traefik trusts, no home address yet, no backups" '.lan' 10.1.0.0/24 '.home' '' '.backups' '[]'
    cst_t "plugin/get: every setting is explained" '(.help | keys | sort) == ["client_trusted_ips","default_decision_seconds","forwarded_headers_trusted_ips","http_timeout","log_level","mode","remediation_status_code","update_interval"] and (.help | all(length > 20))'
    check "plugin/get: the key is nowhere in the answer" 0 "$(grep -cF -- "$k" <<< "$CST_BODY")"
    cst_call admin GET /crowdsec/status
    local st_running st_loaded
    st_running=$(jq -r '.enforcement.plugin.traefik_running' <<< "$CST_BODY"); st_loaded=$(jq -r '.enforcement.plugin.loaded' <<< "$CST_BODY")
    cst_call admin GET /crowdsec/plugin
    check "plugin/get: what it says about Traefik running the plugin is what the status says" "$st_running $st_loaded" "$(jq -r '"\(.plugin.traefik_running) \(.plugin.loaded)"' <<< "$CST_BODY")"
    cst_call viewer GET /crowdsec/plugin
    cst_is "plugin/get: a viewer may look" 200
    cst_j "plugin/get: …at the same" '.available' true '.settings.mode' live '.lan' 10.1.0.0/24
    check "plugin/get: …without the key" 0 "$(grep -cF -- "$k" <<< "$CST_BODY")"
    cst_call none GET /crowdsec/plugin
    cst_is "plugin/get: nobody may not" 401
    cst_call admin POST /crowdsec/plugin '{}'
    cst_is "plugin: POST is no way to change it" 404
    cst_call admin DELETE /crowdsec/plugin
    cst_is "plugin: nor is DELETE" 404
    # -- the LAN: the proxy's stack first, then the install's .env
    printf 'TRAEFIK_DOMAIN=lab.example.test\n' > "$CST/Stacks/networking-security/.env"; cst_env TRAEFIK_TRUSTED_LAN 172.20.0.0/16
    cst_call admin GET /crowdsec/plugin
    cst_j "plugin/get: no LAN in the proxy's stack: the install's .env" '.lan' 172.20.0.0/16
    cst_env TRAEFIK_TRUSTED_LAN
    dflt=$(jq -r '.variables[] | select(.name == "TRAEFIK_TRUSTED_LAN") | .default' "$ROOT/.templates/traefik/template.json")
    cst_call admin GET /crowdsec/plugin
    cst_j "plugin/get: no LAN anywhere: the template's own default" '.lan' "$dflt" '.lan | test("^[0-9.]+/[0-9]+$")' true
    # a LAN value that is no address or network (a hand-edited .env) never reaches the middleware file: the default is used instead of the text
    cst_env TRAEFIK_TRUSTED_LAN '10.9.0.0/24 # x: {y}'
    cst_call admin GET /crowdsec/plugin
    cst_j "plugin/get: a LAN that is no network: the default, not the text" '.lan' "$dflt"
    cst_env TRAEFIK_TRUSTED_LAN
    # -- the file is not in the form DCS writes: the settings are read as far as they are found, and are not changed
    printf 'http:\n  middlewares:\n    crowdsec-bouncer:\n      plugin:\n        crowdsec-bouncer-traefik-plugin:\n          crowdsecMode: "stream"\n          updateIntervalSeconds: 30 # often\n          logLevel: DEBUG\n          crowdsecLapiKey: %s\n' "$k" > "$mw"
    cst_call admin GET /crowdsec/plugin
    cst_j "plugin/get: a hand-written file: quotes and comments are understood" '.settings.mode' stream '.settings.update_interval' 30 '.settings.log_level' DEBUG '.settings.default_decision_seconds' 60 '.managed' false
}

# ---- PUT /crowdsec/plugin: everything that is refused, and that nothing is written when it is -----------------------------------------

cst_plugin_refuse() {
    local i mw sha0 n0 many65 many129 b msg longkey i_json=0 i_unk=0 i_long=0
    cst_plugin_world
    mw=$(cst_mwf); sha0=$(sha1sum < "$mw"); n0=$(cst_files)
    longkey=$(head -c 100 /dev/zero | tr '\0' 'k')
    many65=$(jq -nc '[range(1; 66) | "198.18.\(. / 250 | floor).\(. % 250)"]')
    many129=$(jq -nc '[range(1; 130) | "198.18.\(. / 250 | floor).\(. % 250)"]')
    local -a cases=(
        # label ⇒ body ⇒ what the message must contain
        'no JSON ⇒ nope ⇒ Send a JSON body'
        'an array ⇒ [] ⇒ Send a JSON body'
        'a string ⇒ "x" ⇒ Send a JSON body'
        'a number ⇒ 5 ⇒ Send a JSON body'
        'nothing ⇒  ⇒ Send a JSON body'
        'settings a number ⇒ {"settings":5} ⇒ settings must be an object'
        'settings a list ⇒ {"settings":[]} ⇒ settings must be an object'
        'settings a string ⇒ {"settings":"x"} ⇒ settings must be an object'
        'an unknown setting ⇒ {"settings":{"foo":1}} ⇒ unknown setting: foo'
        'an unknown setting with a command in its name ⇒ {"settings":{"a;touch x":1}} ⇒ unknown setting'
        'a long name is cut ⇒ {"settings":{"'"$longkey"'":1}} ⇒ unknown setting: '"${longkey:0:40}"
        'the key of the bouncer is not a setting ⇒ {"settings":{"crowdsecLapiKey":"x"}} ⇒ unknown setting'
        'mode turbo ⇒ {"settings":{"mode":"turbo"}} ⇒ mode must be live or stream'
        'mode a number ⇒ {"settings":{"mode":5}} ⇒ mode must be live or stream'
        'mode null ⇒ {"settings":{"mode":null}} ⇒ mode must be live or stream'
        'mode in capitals ⇒ {"settings":{"mode":"Live"}} ⇒ mode must be live or stream'
        'mode empty ⇒ {"settings":{"mode":""}} ⇒ mode must be live or stream'
        'mode a list ⇒ {"settings":{"mode":["live"]}} ⇒ mode must be live or stream'
        'mode a command ⇒ {"settings":{"mode":"live\n  evil: true"}} ⇒ mode must be live or stream'
        'log level in small letters ⇒ {"settings":{"log_level":"info"}} ⇒ log_level must be'
        'log level TRACE ⇒ {"settings":{"log_level":"TRACE"}} ⇒ log_level must be'
        'log level empty ⇒ {"settings":{"log_level":""}} ⇒ log_level must be'
        'log level null ⇒ {"settings":{"log_level":null}} ⇒ log_level must be'
        'trust_home a word ⇒ {"settings":{"trust_home":"yes"}} ⇒ trust_home must be true or false'
        'trust_home 1 ⇒ {"settings":{"trust_home":1}} ⇒ trust_home must be true or false'
        'trust_home null ⇒ {"settings":{"trust_home":null}} ⇒ trust_home must be true or false'
        'trust_home "true" ⇒ {"settings":{"trust_home":"true"}} ⇒ trust_home must be true or false'
        'update_interval 9 ⇒ {"settings":{"update_interval":9}} ⇒ update_interval must be between 10 and 3600'
        'update_interval 3601 ⇒ {"settings":{"update_interval":3601}} ⇒ update_interval must be between 10 and 3600'
        'update_interval 0 ⇒ {"settings":{"update_interval":0}} ⇒ update_interval must be between 10 and 3600'
        'update_interval a fraction ⇒ {"settings":{"update_interval":60.5}} ⇒ update_interval must be a whole number'
        'update_interval a string ⇒ {"settings":{"update_interval":"60"}} ⇒ update_interval must be a whole number'
        'update_interval negative ⇒ {"settings":{"update_interval":-1}} ⇒ update_interval must be a whole number'
        'update_interval true ⇒ {"settings":{"update_interval":true}} ⇒ update_interval must be a whole number'
        'update_interval null ⇒ {"settings":{"update_interval":null}} ⇒ update_interval must be a whole number'
        'update_interval a list ⇒ {"settings":{"update_interval":[60]}} ⇒ update_interval must be a whole number'
        'update_interval a huge number ⇒ {"settings":{"update_interval":99999999999999999999}} ⇒ update_interval must be'
        'default_decision_seconds 9 ⇒ {"settings":{"default_decision_seconds":9}} ⇒ default_decision_seconds must be between 10 and 3600'
        'default_decision_seconds 3601 ⇒ {"settings":{"default_decision_seconds":3601}} ⇒ default_decision_seconds must be between 10 and 3600'
        'default_decision_seconds a fraction ⇒ {"settings":{"default_decision_seconds":10.5}} ⇒ default_decision_seconds must be a whole number'
        'http_timeout 0 ⇒ {"settings":{"http_timeout":0}} ⇒ http_timeout must be between 1 and 60'
        'http_timeout 61 ⇒ {"settings":{"http_timeout":61}} ⇒ http_timeout must be between 1 and 60'
        'http_timeout a fraction ⇒ {"settings":{"http_timeout":5.5}} ⇒ http_timeout must be a whole number'
        'status code 399 ⇒ {"settings":{"remediation_status_code":399}} ⇒ remediation_status_code must be between 400 and 599'
        'status code 600 ⇒ {"settings":{"remediation_status_code":600}} ⇒ remediation_status_code must be between 400 and 599'
        'status code 200 ⇒ {"settings":{"remediation_status_code":200}} ⇒ remediation_status_code must be between 400 and 599'
        'status code a fraction ⇒ {"settings":{"remediation_status_code":429.5}} ⇒ remediation_status_code must be a whole number'
        'client list a string ⇒ {"settings":{"client_trusted_ips":"1.2.3.4"}} ⇒ client_trusted_ips: must be a list'
        'client list an object ⇒ {"settings":{"client_trusted_ips":{"a":1}}} ⇒ client_trusted_ips: must be a list'
        'client list null ⇒ {"settings":{"client_trusted_ips":null}} ⇒ client_trusted_ips: must be a list'
        'client list a word ⇒ {"settings":{"client_trusted_ips":["not-an-ip"]}} ⇒ client_trusted_ips: not an IP address or network'
        'client list everything ⇒ {"settings":{"client_trusted_ips":["0.0.0.0/0"]}} ⇒ far too wide'
        'client list all of IPv6 ⇒ {"settings":{"client_trusted_ips":["::/1"]}} ⇒ far too wide'
        'client list a /7 ⇒ {"settings":{"client_trusted_ips":["10.0.0.0/7"]}} ⇒ far too wide'
        'client list an IPv6 /15 ⇒ {"settings":{"client_trusted_ips":["2001:db8::/15"]}} ⇒ far too wide'
        'client list a number ⇒ {"settings":{"client_trusted_ips":[12]}} ⇒ not an IP address or network'
        'client list an object in it ⇒ {"settings":{"client_trusted_ips":[{"a":1}]}} ⇒ not an IP address or network'
        'client list a /33 ⇒ {"settings":{"client_trusted_ips":["1.2.3.4/33"]}} ⇒ not an IP address or network'
        'client list an octet of 999 ⇒ {"settings":{"client_trusted_ips":["999.1.1.1"]}} ⇒ not an IP address or network'
        'client list a URL ⇒ {"settings":{"client_trusted_ips":["http://1.2.3.4"]}} ⇒ not an IP address or network'
        'client list only blanks ⇒ {"settings":{"client_trusted_ips":["   "]}} ⇒ not an IP address or network'
        'client list a comment ⇒ {"settings":{"client_trusted_ips":["1.2.3.4 # mine"]}} ⇒ not an IP address or network'
        'client list a line of YAML ⇒ {"settings":{"client_trusted_ips":["10.0.0.1\n    evil: true"]}} ⇒ not an IP address or network'
        'client list a command substitution ⇒ {"settings":{"client_trusted_ips":["$(touch '"$CST_PWN"')"]}} ⇒ not an IP address or network'
        'client list backticks ⇒ {"settings":{"client_trusted_ips":["`touch '"$CST_PWN"'`"]}} ⇒ not an IP address or network'
        'client list a second command ⇒ {"settings":{"client_trusted_ips":["1.2.3.4;touch '"$CST_PWN"'"]}} ⇒ not an IP address or network'
        'client list a quote and a colon ⇒ {"settings":{"client_trusted_ips":["\"1.2.3.4\": {a: b}"]}} ⇒ not an IP address or network'
        "client list 65 entries ⇒ {\"settings\":{\"client_trusted_ips\":$many65}} ⇒ at most 64 entries"
        'forwarded list a string ⇒ {"settings":{"forwarded_headers_trusted_ips":"1.2.3.4"}} ⇒ forwarded_headers_trusted_ips: must be a list'
        'forwarded list null ⇒ {"settings":{"forwarded_headers_trusted_ips":null}} ⇒ forwarded_headers_trusted_ips: must be a list'
        'forwarded list a /33 ⇒ {"settings":{"forwarded_headers_trusted_ips":["1.2.3.4/33"]}} ⇒ forwarded_headers_trusted_ips: not an IP address or network'
        'forwarded list everything ⇒ {"settings":{"forwarded_headers_trusted_ips":["0.0.0.0/0"]}} ⇒ far too wide'
        'forwarded list a command ⇒ {"settings":{"forwarded_headers_trusted_ips":["$(touch '"$CST_PWN"')"]}} ⇒ not an IP address or network'
        "forwarded list 129 entries ⇒ {\"settings\":{\"forwarded_headers_trusted_ips\":$many129}} ⇒ at most 128 entries"
    )
    for i in "${!cases[@]}"; do
        b="${cases[$i]#* ⇒ }"; b="${b% ⇒ *}"
        case "${cases[$i]%% ⇒ *}" in "no JSON") i_json=$i ;; "an unknown setting") i_unk=$i ;; "a long name is cut") i_long=$i ;; esac
        cst_q "pr$i" admin PUT /crowdsec/plugin "$b"
    done
    cst_q pr-viewer viewer PUT /crowdsec/plugin '{"settings":{"mode":"stream"}}'
    cst_q pr-nobody none PUT /crowdsec/plugin '{"settings":{"mode":"stream"}}'
    cst_q pr-viewer-bad viewer PUT /crowdsec/plugin '{"settings":{"mode":"turbo"}}'
    cst_q pr-get-body admin GET /crowdsec/plugin '{"settings":{"mode":"stream"}}'
    cst_run
    for i in "${!cases[@]}"; do
        msg="${cases[$i]##* ⇒ }"
        cst_use "pr$i"
        check "plugin/refuse: ${cases[$i]%% ⇒ *}" "400 yes" "$CST_ST $(jq -r --arg m "$msg" '.message | contains($m) | if . then "yes" else "no" end' <<< "$CST_BODY" 2>/dev/null)"
        [[ "$CST_ST" == 400 && "$(jq -r --arg m "$msg" '.message | contains($m)' <<< "$CST_BODY" 2>/dev/null)" == true ]] || printf '       (the answer said: %s)\n' "$(jq -r '.message // empty' <<< "$CST_BODY" 2>/dev/null | head -c 200)"
    done
    cst_use pr-viewer;     cst_is "plugin/refuse: a viewer may not" 403
    cst_use pr-nobody;     cst_is "plugin/refuse: nobody may not" 401
    cst_use pr-viewer-bad; cst_is "plugin/refuse: a viewer is told it may not before its settings are looked at" 403
    cst_use pr-get-body;   cst_is "plugin/refuse: a GET with a body changes nothing" 200
    cst_use "pr$i_json"; cst_j "plugin/refuse: a body that is no JSON has no reason (it is not a setting)" '.error' true '.code' 400 '.reason' null
    cst_use "pr$i_unk";  cst_j "plugin/refuse: a refused setting says so" '.error' true '.code' 400 '.reason' invalid
    cst_use "pr$i_long"; cst_t "plugin/refuse: a long name is cut in the message" '.message | length < 80'
    check "plugin/refuse: the middleware file is byte for byte what it was" "$sha0" "$(sha1sum < "$mw")"
    check "plugin/refuse: …no file was made anywhere (a backup, a state file, a temporary one, the result of a command)" "$n0" "$(cst_files)"
    check "plugin/refuse: …no command in a value ran" no "$([[ -e "$CST_PWN" ]] && echo yes || echo no)"
    cst_call admin GET /crowdsec/plugin
    cst_j "plugin/refuse: …and the settings are the ones there were" '.managed' false '.settings.mode' live '.backups' '[]'
}

# ---- PUT /crowdsec/plugin: saving ---------------------------------------------------------------------------------------------------

cst_plugin_apply() {
    local mw rd bk k0 sha0 ino0 ino1 a0 i fake newbk ts0
    cst_plugin_world
    mw=$(cst_mwf); rd=${mw%/*}; bk="$CST/.data/crowdsec/backups"
    k0=$(cst_mw_key "$mw"); sha0=$(sha1sum < "$mw"); ino0=$(stat -c %i "$mw")
    a0=$(cst_audit_n '"action":"auth.crowdsec_plugin"')
    # -- the first save takes the file over: a marker on top, the managed keys, everything else as it was
    cst_call admin PUT /crowdsec/plugin '{}'
    cst_is "plugin/save: even nothing asked for is a first save (the file becomes the page's)" 200
    cst_j "plugin/save" '.success' true '.applied.changed' true '.managed' true '.plugin.managed' true '.applied.message | test("Saved")' true '.applied.backup | test("^plugin-[0-9]{8}T[0-9]{6}Z(-[0-9]+)?\\.yml$")' true \
        '.settings.mode' live '.settings.trust_home' false
    check "plugin/save: the marker is the first line of the file" 1 "$(head -n 1 "$mw" | grep -c '^# dcs-plugin: {"v":1,"settings":{')"
    check "plugin/save: …and the only one" 1 "$(grep -c '^# dcs-plugin:' "$mw")"
    check "plugin/save: …it holds what was saved" "live 60 60 10 403 INFO false" "$(head -n 1 "$mw" | sed 's/^# dcs-plugin: //' | jq -r '.settings | "\(.mode) \(.update_interval) \(.default_decision_seconds) \(.http_timeout) \(.remediation_status_code) \(.log_level) \(.trust_home)"')"
    check "plugin/save: the key of the bouncer is the one it was" "$k0" "$(cst_mw_key "$mw")"
    check "plugin/save: …and so is the rest of the file" 'crowdsecAppsecEnabled: "false" crowdsecLapiHost: "CrowdSec:8080" crowdsecLapiScheme: http enabled: "true"' \
        "$(grep -E '^ +(enabled|crowdsecAppsecEnabled|crowdsecLapiHost|crowdsecLapiScheme):' "$mw" | sed 's/^ *//' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
    check "plugin/save: every managed key is there once" "6 1 1" "$(grep -cE '^ +(crowdsecMode|updateIntervalSeconds|defaultDecisionSeconds|httpTimeoutSeconds|remediationStatusCode|logLevel):' "$mw") $(grep -cE '^ +forwardedHeadersTrustedIPs:' "$mw") $(grep -cE '^ +clientTrustedIPs:' "$mw")"
    check "plugin/save: written atomically: private, nothing left behind" "600 0" "$(stat -c %a "$mw") $(find "$rd" -name '*.dcs-new*' | wc -l | tr -d ' ')"
    check "plugin/save: …a new file took the old one's place" yes "$([[ "$(stat -c %i "$mw")" != "$ino0" ]] && echo yes || echo no)"
    check "plugin/save: Traefik is told to look again (.reload, where the route writers touch it)" "yes yes" "$([[ -e "$rd/.reload" ]] && echo yes || echo no) $([[ -e "${rd%/*}/.reload" ]] && echo yes || echo no)"
    check "plugin/save: the file before was kept, private, in a private folder" "1 600 700 yes" "$(cst_count "$bk"/plugin-*.yml) $(stat -c %a "$bk"/plugin-*.yml) $(stat -c %a "$bk") $([[ "$(sha1sum < "$(printf '%s\n' "$bk"/plugin-*.yml | head -n 1)")" == "$sha0" ]] && echo yes || echo no)"
    check "plugin/save: it is written in the audit log (once)" $(( a0 + 1 )) "$(cst_audit_n '"action":"auth.crowdsec_plugin"')"
    check "plugin/save: …with the settings, not the key" "yes no" "$(tail -n 1 "$CST/.data/audit.jsonl" | jq -r '.detail | contains("\"mode\":\"live\"") | if . then "yes" else "no" end') $(tail -n 1 "$CST/.data/audit.jsonl" | grep -cF -- "$k0" | sed 's/^0$/no/;s/^[1-9].*$/yes/')"
    check "plugin/save: the page's state is on disk, private" "600 live" "$(stat -c %a "$CST/.data/crowdsec/plugin.json") $(jq -r '.settings.mode' "$CST/.data/crowdsec/plugin.json")"
    check "plugin/save: the key is not in the answer" 0 "$(grep -cF -- "$k0" <<< "$CST_BODY")"
    # -- the same again changes nothing at all
    ino1=$(stat -c %i "$mw"); touch -d '1 hour ago' "$rd/.reload" "${rd%/*}/.reload"
    cst_call admin PUT /crowdsec/plugin '{}'
    cst_j "plugin/save: the same again" '.success' true '.applied.changed' false '.applied.backup' null '.applied.message' 'Nothing changed.'
    check "plugin/save: …the file was not written (same file), no new backup, no new audit line, no new reload" "yes 1 $(( a0 + 1 )) yes" \
        "$([[ "$(stat -c %i "$mw")" == "$ino1" ]] && echo yes || echo no) $(cst_count "$bk"/plugin-*.yml) $(cst_audit_n '"action":"auth.crowdsec_plugin"') $([[ -n "$(find "$rd/.reload" -mmin +30)" ]] && echo yes || echo no)"
    # -- every setting at once
    cst_call admin PUT /crowdsec/plugin '{"settings":{"mode":"stream","update_interval":30,"default_decision_seconds":120,"http_timeout":5,"remediation_status_code":429,"log_level":"WARN"}}'
    cst_is "plugin/save: every setting" 200
    cst_j "plugin/save: …in the answer" '.applied.changed' true '.settings.mode' stream '.settings.update_interval' 30 '.settings.default_decision_seconds' 120 '.settings.http_timeout' 5 '.settings.remediation_status_code' 429 '.settings.log_level' WARN
    check "plugin/save: …in the file, each once" "stream 30 120 5 429 WARN" "$(for i in crowdsecMode updateIntervalSeconds defaultDecisionSeconds httpTimeoutSeconds remediationStatusCode logLevel; do grep -E "^ +$i:" "$mw" | sed 's/.*: *//'; done | tr '\n' ' ' | sed 's/ $//')"
    check "plugin/save: …the key survived, the marker is on top once" "$k0 1 1" "$(cst_mw_key "$mw") $(grep -c '^# dcs-plugin:' "$mw") $(head -n 1 "$mw" | grep -c '^# dcs-plugin:')"
    cst_call admin GET /crowdsec/plugin
    cst_j "plugin/save: what the page shows next" '.managed' true '.settings.mode' stream '.settings.update_interval' 30 '.settings.log_level' WARN '.plugin.mode' stream '.plugin.settings.remediation_status_code' 429
    # -- a part of the settings: the rest stays
    cst_call admin PUT /crowdsec/plugin '{"settings":{"mode":"live"}}'
    cst_j "plugin/save: one setting only" '.applied.changed' true '.settings.mode' live '.settings.update_interval' 30 '.settings.default_decision_seconds' 120 '.settings.remediation_status_code' 429
    cst_call admin PUT /crowdsec/plugin '{"settings":null}'
    cst_j "plugin/save: settings null is nothing asked for" '.success' true '.applied.changed' false
    cst_call admin PUT /crowdsec/plugin '{"settings":{},"other":"ignored"}'
    cst_j "plugin/save: …so is an empty object, and a field of another kind is ignored" '.success' true '.applied.changed' false
    # -- the lists: normalised, without duplicates, sorted as the file keeps them; the LAN is not shown among them
    cst_call admin PUT /crowdsec/plugin '{"settings":{"client_trusted_ips":["192.0.2.0/24","192.0.2.7","192.0.2.0/24","2001:DB8::/32","::ffff:198.51.100.7","10.1.0.0/24"]}}'
    cst_is "plugin/save: a client list" 200
    cst_j "plugin/save: …normalised and without duplicates (the LAN is always there and is not shown)" '.settings.client_trusted_ips | join(",")' 192.0.2.0/24,192.0.2.7,198.51.100.7,2001:db8::/32
    check "plugin/save: …in the file: the LAN with them" "10.1.0.0/24 192.0.2.0/24 192.0.2.7 198.51.100.7 2001:db8::/32" \
        "$(awk '/clientTrustedIPs:/ { f = 1; next } f && /^ +- / { sub(/^ +- /, ""); printf "%s ", $0; next } f { exit }' "$mw" | sed 's/ $//')"
    cst_call admin PUT /crowdsec/plugin '{"settings":{"forwarded_headers_trusted_ips":["203.0.113.0/24"]}}'
    cst_j "plugin/save: a list of proxies replaces the ones of the CDN" '.settings.forwarded_headers_trusted_ips | join(",")' 203.0.113.0/24
    check "plugin/save: …in the file: the LAN with it" "10.1.0.0/24 203.0.113.0/24" \
        "$(awk '/forwardedHeadersTrustedIPs:/ { f = 1; next } f && /^ +- / { sub(/^ +- /, ""); printf "%s ", $0; next } f { exit }' "$mw" | sed 's/ $//')"
    cst_call admin PUT /crowdsec/plugin '{"settings":{"forwarded_headers_trusted_ips":[]}}'
    cst_j "plugin/save: no proxies at all" '.settings.forwarded_headers_trusted_ips' '[]'
    check "plugin/save: …in the file: the LAN alone" "10.1.0.0/24" "$(awk '/forwardedHeadersTrustedIPs:/ { f = 1; next } f && /^ +- / { sub(/^ +- /, ""); printf "%s ", $0; next } f { exit }' "$mw" | sed 's/ $//')"
    cst_call admin GET /crowdsec/plugin
    cst_call admin PUT /crowdsec/plugin "$(jq -c '{settings: {forwarded_headers_trusted_ips: .defaults.forwarded_headers_trusted_ips}}' <<< "$CST_BODY")"
    cst_j "plugin/save: the defaults can be put back" '(.settings.forwarded_headers_trusted_ips | sort) == (.defaults.forwarded_headers_trusted_ips | sort)' true
    cst_call admin PUT /crowdsec/plugin "$(jq -nc '{settings: {client_trusted_ips: [range(1; 65) | "198.18.\(. / 250 | floor).\(. % 250)"]}}')"
    cst_j "plugin/save: 64 addresses are the most for a client list" '.success' true '.settings.client_trusted_ips | length' 64
    cst_call admin PUT /crowdsec/plugin "$(jq -nc '{settings: {forwarded_headers_trusted_ips: [range(1; 129) | "198.18.\(. / 250 | floor).\(. % 250)"]}}')"
    cst_j "plugin/save: 128 for the proxies" '.success' true '.settings.forwarded_headers_trusted_ips | length' 128
    cst_call admin PUT /crowdsec/plugin '{"settings":{"client_trusted_ips":[],"forwarded_headers_trusted_ips":[]}}'
    cst_j "plugin/save: emptied again" '.success' true '.settings.client_trusted_ips' '[]'
    # -- the copies kept: ten at most, the oldest go, other files of the folder stay
    rm -f "$bk"/plugin-*.yml
    for i in $(seq 1 12); do
        fake=$(printf '%s/plugin-202601%02dT000000Z.yml' "$bk" "$i")
        printf '# a copy of %s\n' "$i" > "$fake"; touch -d "@$(( $(date +%s) - 86400 * (40 - i) ))" "$fake"
    done
    printf 'profiles copy\n' > "$bk/profiles-20260101T000000Z.yml"
    cst_call admin PUT /crowdsec/plugin '{"settings":{"http_timeout":7}}'
    cst_is "plugin/copies: a save with 12 copies kept" 200
    newbk=$(jq -r '.applied.backup' <<< "$CST_BODY")
    check "plugin/copies: ten are left: the new one and the nine newest of the others" "10 yes 0 1" \
        "$(cst_count "$bk"/plugin-*.yml) $([[ -e "$bk/$newbk" ]] && echo yes || echo no) $(cst_count "$bk"/plugin-2026010[123]T000000Z.yml) $(cst_count "$bk"/plugin-20260104T000000Z.yml)"
    check "plugin/copies: …the copies of other files are not touched" yes "$([[ -e "$bk/profiles-20260101T000000Z.yml" ]] && echo yes || echo no)"
    cst_call admin GET /crowdsec/plugin
    cst_j "plugin/copies: the page lists them, the newest first" '.backups | length' 10 '.backups[0].name' "$newbk" '.backups | map(.created_at) == (map(.created_at) | sort | reverse)' true \
        '.backups | all(.name | test("^plugin-[0-9]{8}T[0-9]{6}Z(-[0-9]+)?\\.yml$"))' true '.backups | all(.size > 0)' true '.backups | all(.created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' true
    check "plugin/copies: …names, times and sizes, no key" 0 "$(grep -cF -- "$k0" <<< "$CST_BODY")"
    # -- a second save in the same second does not take the first one's copy: the name gets a number
    rm -f "$bk"/plugin-*.yml
    ts0=$(date -u +%s)
    for i in $(seq 0 15); do
        fake=$(date -u -d "@$(( ts0 + i ))" +"$bk/plugin-%Y%m%dT%H%M%SZ.yml")
        printf 'a copy that must stay: %s\n' "$i" > "$fake"; touch -d "@$(( ts0 - 100 - i * 10 ))" "$fake"
    done
    sha0=$(sha1sum < "$mw")
    cst_call admin PUT /crowdsec/plugin '{"settings":{"http_timeout":9}}'
    newbk=$(jq -r '.applied.backup' <<< "$CST_BODY")
    fake="$bk/${newbk%-*.yml}.yml"
    check "plugin/copies: a copy with that name was there: the new one has a number, and holds the file as it was" "yes yes" \
        "$([[ "$newbk" =~ ^plugin-[0-9]{8}T[0-9]{6}Z-[0-9]+\.yml$ ]] && echo yes || echo no) $([[ "$(sha1sum < "$bk/$newbk")" == "$sha0" ]] && echo yes || echo no)"
    check "plugin/copies: …and the copy that was there is what it was" "a copy that must stay:" "$(cut -c1-22 "$fake")"
}

# ---- PUT /crowdsec/plugin: two changes at once, and a file that is not the one DCS wrote --------------------------------------------

cst_plugin_files() {
    local mw rd bk sha0 k0 n0
    cst_plugin_world
    mw=$(cst_mwf); rd=${mw%/*}; bk="$CST/.data/crowdsec/backups"; k0=$(cst_mw_key "$mw")
    # -- somebody else is saving right now: this one waits for the lock (8 s) and then says so; a reader does not wait at all
    mkdir -p "$CST/.data/crowdsec"
    cst_lock_hold "$CST/.data/crowdsec/plugin.lock"
    sha0=$(sha1sum < "$mw")
    cst_q busy admin PUT /crowdsec/plugin '{"settings":{"mode":"stream"}}'
    cst_q busy-read admin GET /crowdsec/plugin
    cst_q busy-status admin GET /crowdsec/status
    cst_run
    cst_lock_release
    cst_use busy;        cst_is "plugin/busy: another change holds the lock" 409
    cst_t "plugin/busy: …and the answer says to try again" '.message | test("Another change")'
    cst_use busy-read;   cst_is "plugin/busy: reading does not wait" 200
    cst_use busy-status; cst_is "plugin/busy: …nor does the status" 200
    check "plugin/busy: nothing was written" "$sha0 0" "$(sha1sum < "$mw") $(cst_count "$bk"/plugin-*.yml)"
    cst_call admin PUT /crowdsec/plugin '{"settings":{"mode":"stream"}}'
    cst_is "plugin/busy: the lock is free again" 200
    # -- a file with another indentation than the one DCS writes: it is not understood, so it is not touched
    python3 - "$mw" <<'PY'
import sys
p = sys.argv[1]
out = []
for l in open(p).read().split("\n"):
    n = len(l) - len(l.lstrip(" "))
    out.append(" " * (n * 2) + l.lstrip(" ") if l.strip() and not l.startswith("#") else l)
open(p, "w").write("\n".join(out))
PY
    sha0=$(sha1sum < "$mw"); chmod 600 "$mw"; n0=$(cst_count "$bk"/plugin-*.yml)
    cst_call admin PUT /crowdsec/plugin '{"settings":{"mode":"live"}}'
    cst_is "plugin/foreign: a file with the indentation doubled" 500
    cst_j "plugin/foreign: …refused as not written" '.error' true '.reason' write_failed '.message | test("did not read back")' true '.message | test("previous file was put back")' true
    check "plugin/foreign: …the file is what it was, private, and nothing is left beside it" "$sha0 600 0" "$(sha1sum < "$mw") $(stat -c %a "$mw") $(find "$rd" -name '*.dcs-new*' | wc -l | tr -d ' ')"
    check "plugin/foreign: …and the copy made for the attempt is gone again" "$n0" "$(cst_count "$bk"/plugin-*.yml)"
    printf 'http:\n  middlewares:\n    x:\n      headers: {}\n' > "$mw"; sha0=$(sha1sum < "$mw")
    cst_call admin PUT /crowdsec/plugin '{"settings":{"mode":"live"}}'
    cst_is "plugin/foreign: a middleware file of something else" 500
    cst_j "plugin/foreign: …it says so, and that nothing was changed" '.reason' write_failed '.message | test("does not look like the bouncer")' true '.message | test("nothing was changed")' true
    check "plugin/foreign: …the file is what it was" "$sha0" "$(sha1sum < "$mw")"
    : > "$mw"
    cst_call admin PUT /crowdsec/plugin '{"settings":{"mode":"live"}}'
    cst_is "plugin/foreign: an empty file" 500
    cst_call admin GET /crowdsec/plugin
    cst_j "plugin/foreign: …is still shown, with the defaults" '.available' true '.managed' false '.settings.mode' live
    cst_call admin POST /crowdsec/bouncers/register-traefik
    cst_is "plugin/foreign: registering the bouncer writes a proper file again" 200
    cst_call admin PUT /crowdsec/plugin '{"settings":{"mode":"live"}}'
    cst_is "plugin/foreign: …and then a save works" 200
    check "plugin/foreign: …with the new key, the marker on top" "yes 1" "$([[ "$(cst_mw_key "$mw")" != "$k0" && -n "$(cst_mw_key "$mw")" ]] && echo yes || echo no) $(head -n 1 "$mw" | grep -c '^# dcs-plugin:')"
}

# ---- the home address, the LAN, and registering the bouncer again ----------------------------------------------------------------

cst_client_list() { awk '/clientTrustedIPs:/ { f = 1; next } f && /^ +- / { sub(/^ +- /, ""); printf "%s ", $0; next } f { exit }' "$1" | sed 's/ $//'; }

cst_plugin_home() {
    local mw k0 k1 rd
    cst_plugin_world
    mw=$(cst_mwf); rd=${mw%/*}; k0=$(cst_mw_key "$mw")
    printf '198.51.100.99\n' > "$CST/.data/ddns-current-ip"            # the home address the DDNS loop keeps (no lookup on the network is needed)
    # -- the page does not manage the plugin yet: the whitelist sync leaves the file alone
    cst_call admin POST /crowdsec/trust '{"ip":"203.0.113.44"}'
    cst_is "plugin/home: a trusted address is added" 200
    check "plugin/home: …the plugin's file is untouched (the page does not manage it yet)" "10.1.0.0/24 no" "$(cst_client_list "$mw") $([[ -e "$CST/.data/crowdsec/plugin.json" ]] && echo yes || echo no)"
    # -- an address that is not one is not a home address
    cp -p "$CST/.data/crowdsec-whitelist.json" "$CST/whitelist.keep"
    printf '{"public_ip":"not-an-address"}\n' > "$CST/.data/crowdsec-whitelist.json"
    cst_call admin PUT /crowdsec/plugin '{"settings":{"trust_home":true}}'
    cst_is "plugin/home: trust_home on, and the home address is garbage" 200
    cst_j "plugin/home: …there is no home address" '.home' '' '.settings.trust_home' true
    check "plugin/home: …and none is written into the file" "10.1.0.0/24" "$(cst_client_list "$mw")"
    cp -p "$CST/whitelist.keep" "$CST/.data/crowdsec-whitelist.json"; rm -f "$CST/whitelist.keep"
    # -- trust_home: the home address is one of the visitors that are never checked (the whitelist sync puts it there)
    cst_call admin POST /crowdsec/trust '{"ip":"203.0.113.47"}'
    cst_is "plugin/home: the whitelist is synced with trust_home on" 200
    cst_call admin GET /crowdsec/plugin
    cst_j "plugin/home: …the home address is the one the sync found" '.home' 198.51.100.99 '.settings.trust_home' true '.settings.client_trusted_ips' '[]' '.lan' 10.1.0.0/24
    check "plugin/home: …the file has the LAN and the home address" "10.1.0.0/24 198.51.100.99" "$(cst_client_list "$mw")"
    # -- the public address changes: the sync moves it in the plugin's file
    printf '198.51.100.100\n' > "$CST/.data/ddns-current-ip"
    cst_call admin POST /crowdsec/trust '{"ip":"203.0.113.45"}'
    cst_is "plugin/home: the home address changed, the whitelist is synced" 200
    check "plugin/home: …the plugin follows: the new address in, the old one out" "10.1.0.0/24 198.51.100.100" "$(cst_client_list "$mw")"
    cst_call admin GET /crowdsec/plugin
    cst_j "plugin/home: …and the page shows it as the home, not as a client of the person's" '.home' 198.51.100.100 '.settings.client_trusted_ips' '[]' '.settings.trust_home' true
    # -- trust_home off: the home address goes, and a sync does not bring it back
    cst_call admin PUT /crowdsec/plugin '{"settings":{"trust_home":false}}'
    check "plugin/home: trust_home off: the file has the LAN alone" "10.1.0.0/24" "$(cst_client_list "$mw")"
    printf '198.51.100.101\n' > "$CST/.data/ddns-current-ip"
    cst_call admin POST /crowdsec/trust '{"ip":"203.0.113.46"}'
    check "plugin/home: …and a new address is not added" "10.1.0.0/24" "$(cst_client_list "$mw")"
    # -- the person's own addresses, and the home address with them
    cst_call admin PUT /crowdsec/plugin '{"settings":{"trust_home":true,"client_trusted_ips":["192.0.2.0/24"]}}'
    check "plugin/home: the LAN, the person's own and the home address" "10.1.0.0/24 192.0.2.0/24 198.51.100.101" "$(cst_client_list "$mw")"
    cst_j "plugin/home: …the page keeps them apart" '.settings.client_trusted_ips | join(",")' 192.0.2.0/24 '.home' 198.51.100.101
    # -- registering the bouncer again: a fresh key, the settings of the page stay
    printf '{"public_ip":"198.51.100.101"}\n' > "$CST/.data/crowdsec-whitelist.json"
    cst_call admin PUT /crowdsec/plugin '{"settings":{"mode":"stream","update_interval":45,"log_level":"DEBUG","remediation_status_code":429}}'
    k0=$(cst_mw_key "$mw")
    cst_call admin POST /crowdsec/bouncers/register-traefik
    cst_is "plugin/register: the bouncer again" 200
    k1=$(cst_mw_key "$mw")
    check "plugin/register: …a new key" yes "$([[ -n "$k1" && "$k1" != "$k0" ]] && echo yes || echo no)"
    cst_call admin GET /crowdsec/plugin
    cst_j "plugin/register: …the settings of the page are in the fresh file" '.managed' true '.settings.mode' stream '.settings.update_interval' 45 '.settings.log_level' DEBUG '.settings.remediation_status_code' 429 '.settings.trust_home' true \
        '.settings.client_trusted_ips | join(",")' 192.0.2.0/24 '.home' 198.51.100.101 '.plugin.key_present' true
    check "plugin/register: …the LAN, the person's own and the home address are in the file" "10.1.0.0/24 192.0.2.0/24 198.51.100.101" "$(cst_client_list "$mw")"
    check "plugin/register: …one marker on top, private, nothing left beside it, the new key only once" "1 600 0 1" "$(grep -c '^# dcs-plugin:' "$mw") $(stat -c %a "$mw") $(find "$rd" -name '*.dcs-new*' | wc -l | tr -d ' ') $(grep -c 'crowdsecLapiKey:' "$mw")"
    check "plugin/register: …and the old key is nowhere in it" 0 "$(grep -cF -- "$k0" "$mw")"
    cst_uncache; cst_call admin GET /crowdsec/status
    cst_j "plugin/register: …the status agrees" '.enforcement.plugin.managed' true '.enforcement.plugin.mode' stream '.enforcement.plugin.key_present' true '.issues | map(.code) | join(",")' bouncer_idle,hub_updates
    # -- the page's state is unreadable: registering still works, with the template's settings
    printf '{nope' > "$CST/.data/crowdsec/plugin.json"
    cst_call admin POST /crowdsec/bouncers/register-traefik
    cst_is "plugin/register: the page's own state is damaged" 200
    cst_call admin GET /crowdsec/plugin
    cst_j "plugin/register: …the fresh file is the template's" '.managed' false '.settings.mode' live '.settings.update_interval' 60 '.settings.log_level' INFO
    cst_call admin PUT /crowdsec/plugin '{"settings":{"mode":"stream"}}'
    cst_is "plugin/register: …and a save repairs the state" 200
    check "plugin/register: …the state is JSON again" stream "$(jq -r '.settings.mode' "$CST/.data/crowdsec/plugin.json" 2>/dev/null)"
}

# ---- POST /crowdsec/traefik/restart ---------------------------------------------------------------------------------------------------

cst_plugin_restart() {
    local mark a0 a1 s0 s1
    cst_plugin_world bare
    a0=$(cst_audit_n '"action":"auth.crowdsec_traefik_restart"'); mark=$(cst_argv_n)
    s0=$(jq -r '.containers.Traefik.started' "$CST/fake/state.json")
    cst_call admin POST /crowdsec/traefik/restart
    cst_is "plugin/restart: Traefik" 200
    cst_j "plugin/restart" '.success' true '.message | test("Traefik was restarted")' true
    s1=$(jq -r '.containers.Traefik.started' "$CST/fake/state.json")
    check "plugin/restart: …Traefik was restarted (and nothing else): docker restart Traefik, once" "1 yes" "$(cst_argv_since "$mark" | grep -c '^restart Traefik') $(awk -v a="$s0" -v b="$s1" 'BEGIN { print (b > a + 86400) ? "yes" : "no" }')"
    check "plugin/restart: …CrowdSec was not restarted" 0 "$(cst_argv_since "$mark" | grep -c 'restart CrowdSec')"
    check "plugin/restart: …it is audited once" $(( a0 + 1 )) "$(cst_audit_n '"action":"auth.crowdsec_traefik_restart"')"
    cst_call viewer POST /crowdsec/traefik/restart
    cst_is "plugin/restart: a viewer may not" 403
    cst_call none POST /crowdsec/traefik/restart
    cst_is "plugin/restart: nobody may not" 401
    cst_call admin GET /crowdsec/traefik/restart
    cst_is "plugin/restart: GET is no way to restart it" 404
    check "plugin/restart: …the refusals restarted nothing and left no audit line" "1 $(( a0 + 1 ))" "$(cst_argv_since "$mark" | grep -c '^restart Traefik') $(cst_audit_n '"action":"auth.crowdsec_traefik_restart"')"
    # -- Traefik that is stopped is started
    cst_dk stop Traefik >/dev/null
    cst_call admin POST /crowdsec/traefik/restart
    cst_is "plugin/restart: a stopped Traefik" 200
    check "plugin/restart: …runs again" true "$(cst_dk inspect -f '{{.State.Running}}' Traefik)"
    # -- CrowdSec does not have to be there
    cst_world absent none --traefik
    cst_call admin POST /crowdsec/traefik/restart
    cst_is "plugin/restart: no CrowdSec container, but a Traefik" 200
    a1=$(cst_audit_n '"action":"auth.crowdsec_traefik_restart"')
    # -- when it cannot be done
    cst_world data none
    mark=$(cst_argv_n)
    cst_call admin POST /crowdsec/traefik/restart
    cst_is "plugin/restart: no Traefik on this server" 409
    cst_t "plugin/restart: …says so" '.message | test("Traefik was not found")'
    check "plugin/restart: …and no restart was tried" 0 "$(cst_argv_since "$mark" | grep -c '^restart')"
    cst_world data traefik --traefik
    cst_mock --mock-set docker_down=1
    cst_call admin POST /crowdsec/traefik/restart
    cst_is "plugin/restart: Docker does not answer" 503
    cst_t "plugin/restart: …says why" '.message | test("Docker does not answer")'
    cst_mock --mock-set docker_down=0
    : > "$CST/fail-traefik-restart"
    cst_call admin POST /crowdsec/traefik/restart
    cst_is "plugin/restart: docker cannot restart it" 502
    cst_t "plugin/restart: …says so" '.message | test("could not restart Traefik")'
    check "plugin/restart: …and it is not in the audit log as done" "$a1" "$(cst_audit_n '"action":"auth.crowdsec_traefik_restart"')"
    rm -f "$CST/fail-traefik-restart"
}

# ---- GET /routes: does the bouncer check a route? -------------------------------------------------------------------------------------

# cst_route_file STACK NAME HOST [MIDDLEWARE…] — a route file of the kind DCS writes for a service, in Traefik's routes folder
cst_route_file() {
    local dir; dir="$(cst_tr)/custom_routes/$1"
    local name="$2" host="$3"; shift 3
    mkdir -p "$dir"
    {
        printf 'http:\n  routers:\n    %s-router:\n      rule: "Host(`%s`)"\n      service: %s\n' "$name" "$host" "$name"
        if (( $# )); then printf '      middlewares:\n'; printf '        - %s\n' "$@"; fi
        printf '  services:\n    %s:\n      loadBalancer:\n        servers:\n          - url: "http://%s:8080"\n' "$name" "$name"
    } > "$dir/$name.yml"
}
# GET /routes (fresh); CST_RS = "service=state" of every route of the files, sorted the way cst_sorted sorts
cst_route_states() {
    cst_uncache; cst_call admin GET /routes
    CST_RS=$(jq -r '[.routes[] | select(.member == null) | "\(.service)=\(.crowdsec)"] | join(" ")' <<< "$CST_BODY")
}
cst_sorted() { printf '%s\n' "$@" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'; }

cst_plugin_routes() {
    local chain tmpl ino sum trf
    cst_world data traefik --traefik
    chain="$(cst_tr)/custom_routes/core-infrastructure/traefik.yml"; tmpl="$ROOT/.templates/traefik/config/custom_routes/core-infrastructure/traefik.yml"
    cst_route_file media-services plain plain.lab.example.test compress-gzip
    cst_route_file media-services nomw nomw.lab.example.test
    cst_route_file media-services chain-plain chain-plain.lab.example.test traefik-chain
    cst_route_file media-services chain-quoted chain-quoted.lab.example.test '"traefik-chain"' compress-gzip
    cst_route_file media-services chain-single chain-single.lab.example.test "'traefik-chain'"
    cst_route_file media-services direct direct.lab.example.test crowdsec-bouncer
    cst_route_file media-services direct-quoted direct-quoted.lab.example.test '"crowdsec-bouncer"'
    cst_route_file media-services both both.lab.example.test traefik-chain crowdsec-bouncer
    cst_route_file media-services lookalike lookalike.lab.example.test traefik-chain-2 crowdsec-bouncer-2 my-traefik-chain
    printf 'http:\n  routers:\n    commented-router:\n      rule: "Host(`commented.lab.example.test`)"\n      service: commented\n      middlewares:\n        # - traefik-chain\n        - compress-gzip\n' > "$(cst_tr)/custom_routes/media-services/commented.yml"
    # -- CrowdSec is not set up on this proxy: nothing is checked, and no route is blamed
    cst_route_states
    cst_is "routes: the list" 200
    check "routes: no bouncer registered: every route says CrowdSec is off" "$(cst_sorted chain-plain=off chain-quoted=off chain-single=off commented=off dcs-ui=off both=off direct=off direct-quoted=off lookalike=off nomw=off plain=off traefik=off)" "$(cst_sorted $CST_RS)"
    # -- registered: the chain holds the bouncer
    cst_call admin POST /crowdsec/bouncers/register-traefik
    cst_is "routes: registering the bouncer" 200
    cst_route_states
    check "routes: the bouncer is in the chain: a route is protected when it uses the chain or names the bouncer" \
        "$(cst_sorted both=protected chain-plain=protected chain-quoted=protected chain-single=protected commented=bypass dcs-ui=protected direct=protected direct-quoted=protected lookalike=bypass nomw=bypass plain=bypass traefik=protected)" "$(cst_sorted $CST_RS)"
    cst_j "routes: …the list is the list" '.total' 12 '.domain' lab.example.test '.routes | all(.crowdsec | IN("protected", "bypass", "off"))' true
    cst_call viewer GET /routes
    cst_is "routes: a viewer may look" 200
    cst_j "routes: …at the same" '[.routes[] | select(.crowdsec == "protected")] | length' 8 '[.routes[] | select(.crowdsec == "bypass")] | length' 4
    cst_call none GET /routes
    cst_is "routes: nobody may not" 401
    # -- registered, but the chain does not hold the bouncer: only the routes that name it are checked
    cp -p "$tmpl" "$chain"
    cst_route_states
    check "routes: the bouncer is not in the chain: only a route that names the bouncer is protected" \
        "$(cst_sorted both=protected chain-plain=bypass chain-quoted=bypass chain-single=bypass commented=bypass dcs-ui=bypass direct=protected direct-quoted=protected lookalike=bypass nomw=bypass plain=bypass traefik=bypass)" "$(cst_sorted $CST_RS)"
    cst_call admin GET /crowdsec/status
    cst_j "routes: …and the status says the bouncer is not in the chain" '.enforcement.in_chain' false '.issues[0].code' bouncer_unchained
    # -- the chain is defined BESIDE the routes directory: the original layout mounts App-Data/Traefik/TraefikRoutes.yml into custom_routes/ inside
    #    the container, so on the host the file is one level above it (a 4.0.0 install with that layout saw no chain and blamed every route)
    trf="$(cst_tr)/TraefikRoutes.yml"
    sed -i 's/^    traefik-chain:/    traefik-chain-renamed:/' "$chain"
    printf 'http:\n  middlewares:\n    # Order: real-IP first, then the bouncer\n\n    traefik-chain:\n      chain:\n        middlewares:\n          - cloudflarewarp\n          - crowdsec-bouncer\n          - my-geoblock\n          - https-redirect\n' > "$trf"
    cst_route_file media-services chain-file chain-file.lab.example.test 'traefik-chain@file'
    # chains of your own: one that holds the bouncer (a media-chain), a chain of that chain, and one that does not
    printf 'http:\n  middlewares:\n    media-chain:\n      chain:\n        middlewares:\n          - cloudflarewarp\n          - "crowdsec-bouncer"\n          - rate-limit-media\n    nested-chain:\n      chain:\n        middlewares:\n          - media-chain@file\n          - compress-gzip\n    plain-chain:\n      chain:\n        middlewares:\n          - cloudflarewarp\n          - compress-gzip\n' > "$(cst_tr)/custom_routes/media-services/chains.yml"
    cst_route_file media-services media-route media-route.lab.example.test media-chain compress-gzip
    cst_route_file media-services nested-route nested-route.lab.example.test nested-chain
    cst_route_file media-services plain-route plain-route.lab.example.test plain-chain
    cst_route_states
    check "routes: the chain beside the routes directory holds the bouncer: routes that use it are protected (an @file name too), and so are routes on a chain of your own that holds it" \
        "$(cst_sorted both=protected chain-file=protected chain-plain=protected chain-quoted=protected chain-single=protected commented=bypass dcs-ui=protected direct=protected direct-quoted=protected lookalike=bypass media-route=protected nested-route=protected nomw=bypass plain=bypass plain-route=bypass traefik=protected)" "$(cst_sorted $CST_RS)"
    cst_call admin GET /crowdsec/status
    cst_j "routes: …and the status finds the chain there" '.enforcement.in_chain' true '.enforcement.chain_file | endswith("/Traefik/TraefikRoutes.yml")' true '.issues | map(.code) | index("bouncer_unchained")' null
    sed -i 's/$/\r/' "$trf"; cst_uncache; cst_call admin GET /crowdsec/status
    cst_j "routes: …a file with Windows line endings is read the same" '.enforcement.in_chain' true
    sed -i 's/\r$//' "$trf"
    sum=$(cksum < "$trf")
    cst_call admin POST /crowdsec/bouncers/register-traefik
    cst_is "routes: registering the bouncer again, the chain beside the routes" 200
    check "routes: …the hand-written chain is not touched (the bouncer is in it)" "$sum" "$(cksum < "$trf")"
    sed -i '/- crowdsec-bouncer/d' "$trf"; ino=$(stat -c %i "$trf"); cst_uncache; cst_call admin GET /crowdsec/status
    cst_j "routes: …take the bouncer out of that chain: the status notices" '.enforcement.in_chain' false '.issues[0].code' bouncer_unchained
    cst_call admin POST /crowdsec/bouncers/register-traefik
    cst_is "routes: …registering puts it back" 200
    check "routes: …after cloudflarewarp (a bouncer before it would judge Cloudflare's addresses), the rest in order" "cloudflarewarp crowdsec-bouncer my-geoblock https-redirect" "$(awk '/^          - /{ printf "%s%s", (n++ ? " " : ""), $2 }' "$trf")"
    check "routes: …written in place: the same file, so a single-file bind mount keeps seeing it" "$ino" "$(stat -c %i "$trf")"
    check "routes: …and the comment lines around it are kept" 2 "$(grep -c -E '^ *(#|$)' "$trf")"
    cst_route_states
    check "routes: …and the routes are protected again" "$(cst_sorted both=protected chain-file=protected chain-plain=protected chain-quoted=protected chain-single=protected commented=bypass dcs-ui=protected direct=protected direct-quoted=protected lookalike=bypass media-route=protected nested-route=protected nomw=bypass plain=bypass plain-route=bypass traefik=protected)" "$(cst_sorted $CST_RS)"
    rm -f "$trf" "$(cst_tr)/custom_routes/media-services/chain-file.yml" "$(cst_tr)/custom_routes/media-services/chains.yml" "$(cst_tr)/custom_routes/media-services/media-route.yml" "$(cst_tr)/custom_routes/media-services/nested-route.yml" "$(cst_tr)/custom_routes/media-services/plain-route.yml"; cp -p "$tmpl" "$chain"
    # -- the middleware file is gone: CrowdSec is off again for every route
    rm -f "$(cst_mwf)"
    cst_route_states
    check "routes: no middleware file: off for every route" "12 0" "$(tr ' ' '\n' <<< "$CST_RS" | grep -c '=off$') $(tr ' ' '\n' <<< "$CST_RS" | grep -vc '=off$')"
    # -- Traefik is not on this server; its own API lists routes (the file provider's), and CrowdSec is off for them
    cst_world data none --traefik
    mkdir -p "$CST/traefik-api"
    printf '%s\n' '[{"name":"api-router@file","rule":"Host(`api.lab.example.test`)","service":"api@file","provider":"file"},{"name":"app-router@docker","rule":"Host(`app.lab.example.test`)","service":"app@docker","provider":"docker"},{"name":"dashboard@internal","rule":"Host(`traefik.lab.example.test`)","service":"api@internal","provider":"internal"},{"name":"second-router@file","rule":"Host(`second.lab.example.test`) && PathPrefix(`/x`)","service":"second@file","provider":"file"}]' > "$CST/traefik-api/routers.json"
    cst_uncache; cst_call admin GET /routes
    cst_j "routes: from Traefik's own API (no route files): the file provider's routes only" '.total' 2 '.routes | map(.subdomain) | join(",")' api.lab.example.test,second.lab.example.test '.routes | all(.crowdsec == "off")' true \
        '.routes | all(.stack == "traefik")' true
    rm -rf "$CST/traefik-api"
}

# ---- the routes of the VMs a hub serves ------------------------------------------------------------------------------------------------

cst_plugin_fleet() {
    local body chain tmpl f mw
    body='{"http":{"routers":{"vm1-jellyfin-dcs":{"rule":"Host(`jellyfin.lab.example.test`)","service":"vm1-jellyfin-dcs","entryPoints":["websecure"],"tls":{}},"vm1-sonarr-dcs":{"rule":"Host(`sonarr.lab.example.test`)","service":"vm1-sonarr-dcs"}},"services":{"vm1-jellyfin-dcs":{"loadBalancer":{"servers":[{"url":"http://192.0.2.50:8096"}]}},"vm1-sonarr-dcs":{"loadBalancer":{"servers":[{"url":"http://192.0.2.50:8989"}]}}}}}'
    cst_plugin_world
    f="$(cst_tr)/custom_routes/fleet-members.yml"; chain="$(cst_tr)/custom_routes/core-infrastructure/traefik.yml"; tmpl="$ROOT/.templates/traefik/config/custom_routes/core-infrastructure/traefik.yml"; mw=$(cst_mwf)
    printf '{"members":[{"id":"vm1","name":"Media VM","vmid":101,"stacks":["media-services"]}],"join_tokens":[],"hub":null}\n' > "$CST/.data/fleet.json"
    cst_call admin POST /fleet/routes "$body"
    cst_is "fleet: the routes of a VM are handed to this Traefik" 200
    cst_j "fleet: …two routes" '.success' true '.routes' 2
    check "fleet: …each router gets the hub's chain, which holds the bouncer (and nothing else is changed)" 'traefik-chain,compress-gzip|traefik-chain,compress-gzip|Host(`jellyfin.lab.example.test`)|websecure|vm1-jellyfin-dcs' \
        "$(jq -r '.http.routers | ([.["vm1-jellyfin-dcs"].middlewares, .["vm1-sonarr-dcs"].middlewares] | map(join(",")) | join("|")), .["vm1-jellyfin-dcs"].rule, .["vm1-jellyfin-dcs"].entryPoints[0], .["vm1-jellyfin-dcs"].service' "$f" | tr '\n' '|' | sed 's/|$//')"
    check "fleet: …the file is sorted and complete" "yes 2" "$([[ "$(jq -S . "$f")" == "$(cat "$f")" ]] && echo yes || echo no) $(jq -r '.http.services | length' "$f")"
    cst_call admin POST /fleet/routes '{"http":{"routers":"x","services":{}}}'
    cst_is "fleet: routers that are no routers" 400
    check "fleet: …the routes there were are still there" 2 "$(jq -r '.http.routers | length' "$f")"
    cst_uncache; cst_call admin GET /routes
    cst_j "fleet: a VM's route in the list, checked by the bouncer" '[.routes[] | select(.fleet == true)] | length' 2 '[.routes[] | select(.fleet == true)] | map(.crowdsec) | unique | join(",")' protected \
        '.routes | map(select(.service == "jellyfin"))[0] | "\(.member) \(.member_name) \(.vmid) \(.stack) \(.subdomain) \(.target)"' 'vm1 Media VM 101 media-services jellyfin.lab.example.test http://192.0.2.50:8096'
    # -- the chain does not hold the bouncer any more: the VM's routes are open
    cp -p "$tmpl" "$chain"; cst_uncache; cst_call admin GET /routes
    cst_j "fleet: the bouncer is not in the chain: the VM's routes are not checked" '[.routes[] | select(.fleet == true)] | map(.crowdsec) | unique | join(",")' bypass
    # -- no bouncer at all
    rm -f "$mw"; cst_uncache; cst_call admin GET /routes
    cst_j "fleet: no middleware file: off" '[.routes[] | select(.fleet == true)] | map(.crowdsec) | unique | join(",")' off
    # -- a Traefik with no chain: the routers get what there is, and none at all when there is nothing
    cst_plugin_world
    printf '{"members":[{"id":"vm1","name":"Media VM","vmid":101,"stacks":["media-services"]}],"join_tokens":[],"hub":null}\n' > "$CST/.data/fleet.json"
    sed -i 's/^    traefik-chain:/    traefik-chain-renamed:/' "$chain"
    cst_call admin POST /fleet/routes "$body"
    check "fleet: no traefik-chain here: the routers get compress-gzip only" "compress-gzip" "$(jq -r '.http.routers["vm1-jellyfin-dcs"].middlewares | join(",")' "$f")"
    cst_uncache; cst_call admin GET /routes
    cst_j "fleet: …and are not checked" '[.routes[] | select(.fleet == true)] | map(.crowdsec) | unique | join(",")' bypass
    sed -i 's/^    compress-gzip:/    compress-gzip-renamed:/' "$chain"
    cst_call admin POST /fleet/routes "$body"
    check "fleet: no chain and no compression: the routers stay as they came" "null" "$(jq -r '.http.routers["vm1-jellyfin-dcs"].middlewares' "$f")"
    cst_uncache; cst_call admin GET /routes
    cst_j "fleet: …not checked either" '[.routes[] | select(.fleet == true)] | map(.crowdsec) | unique | join(",")' bypass
    # -- what is refused is refused whether this Traefik has a chain or not
    cst_call admin POST /fleet/routes '{"http":{"routers":"x","services":{}}}'
    cst_is "fleet: routers that are no routers, on a Traefik without a chain" 400
    check "fleet: …nothing malformed was written for Traefik to trip over" "null" "$(jq -r '.http.routers | if type == "string" then "string" else null end' "$f" 2>/dev/null)"
    # -- who may, and what is refused
    cst_call viewer POST /fleet/routes "$body"
    cst_is "fleet: a viewer may not hand out routes" 403
    cst_call none POST /fleet/routes "$body"
    cst_is "fleet: nobody may not" 401
    cst_call admin POST /fleet/routes 'nope'
    cst_is "fleet: a body that is no JSON" 400
    cst_call admin POST /fleet/routes '{"http":{"routers":{}}}'
    cst_is "fleet: no routes at all takes the file away" 200
    check "fleet: …the file is gone" no "$([[ -e "$f" ]] && echo yes || echo no)"
    cst_world data none
    cst_call admin POST /fleet/routes "$body"
    cst_is "fleet: no Traefik here" 409
}

# ---- a crowdsec-bouncer middleware the person defines themselves (4.0.0 wrote a second copy and a second bouncer, then said Traefik had not asked) --------

cst_plugin_duplicate() {
    local trf mwf chain tmpl
    trf="$(cst_tr)/TraefikRoutes.yml"; mwf=$(cst_mwf)
    chain="$(cst_tr)/custom_routes/core-infrastructure/traefik.yml"; tmpl="$ROOT/.templates/traefik/config/custom_routes/core-infrastructure/traefik.yml"
    cst_plugin_world
    cst_call admin GET /crowdsec/status
    cst_j "duplicate: only DCS's own middleware: nothing elsewhere, the idle note as before" '.enforcement.own_middleware' false '.enforcement.defined_elsewhere | length' 0 \
        '.issues | map(.code) | index("bouncer_idle") != null' true '.issues | map(.code) | index("bouncer_duplicate")' null '.bouncer.pulled_by' null
    # -- the person defines the middleware too, and Traefik asks CrowdSec as a bouncer of their own
    printf 'http:\n  middlewares:\n    crowdsec-bouncer:\n      plugin:\n        crowdsec-bouncer-traefik-plugin:\n          enabled: "true"\n          crowdsecLapiKey: theirs\n' > "$trf"
    cst_mock --mock-set traefik_bouncer=traefik-bouncer@172.19.0.6
    cst_uncache; cst_call admin GET /crowdsec/status
    cst_j "duplicate: the second definition is seen" '.enforcement.own_middleware' true '.enforcement.defined_elsewhere | join(",")' TraefikRoutes.yml
    cst_j "duplicate: …the pull of the Traefik bouncer in use counts, whose key it is" '.bouncer.pulled_by' traefik-bouncer@172.19.0.6 '.bouncer.last_pull != null' true '.bouncer.registered' true
    cst_j "duplicate: …no 'has not asked yet', a plain note that there are two copies" '.issues | map(.code) | index("bouncer_idle")' null \
        '.issues | map(select(.code == "bouncer_duplicate"))[0].severity' info '.issues | map(select(.code == "bouncer_duplicate"))[0].detail | test("TraefikRoutes.yml")' true
    cst_t "duplicate: …and nothing needs attention" '.state == "healthy" and ((.issues | map(select(.severity == "warning")) | length) == 0)'
    # -- a pull older than half an hour is stale, whoever made it
    cst_mock --mock-tick 2000
    cst_uncache; cst_call admin GET /crowdsec/status
    cst_j "duplicate: a pull older than half an hour is stale" '.issues | map(.code) | index("bouncer_stale") != null' true
    cst_mock --mock-set traefik_bouncer=traefik-bouncer@172.19.0.6
    # -- Traefik does not ask at all: the idle note comes back
    cst_mock --mock-set traefik_bouncer=-traefik-bouncer@172.19.0.6
    cst_uncache; cst_call admin GET /crowdsec/status
    cst_j "duplicate: no Traefik bouncer pulled: the idle note is right" '.issues | map(.code) | index("bouncer_idle") != null' true '.bouncer.pulled_by' null
    # -- only the person's own middleware (DCS never wrote one): their bouncer is the bouncer
    cst_mock --mock-set traefik_bouncer=traefik-bouncer@172.19.0.6
    rm -f "$mwf"; cst_cs bouncers delete dcs-traefik-bouncer >/dev/null 2>&1
    cst_uncache; cst_call admin GET /crowdsec/status
    cst_j "duplicate: only their own middleware: it is the bouncer, no missing-file complaint" '.bouncer.registered' true '.bouncer.name' traefik-bouncer@172.19.0.6 '.enforcement.middleware_present' false \
        '.issues | map(.code) | inside(["hub_updates"])' true
    # -- registering does not write a second copy or a second bouncer, and puts their middleware in the chain
    sed -i '/- "crowdsec-bouncer"/d' "$chain"
    cst_call admin POST /crowdsec/bouncers/register-traefik
    cst_is "duplicate: registering with their own middleware" 200
    cst_t "duplicate: …says nothing was added" '.message | test("did not add a second copy")'
    check "duplicate: …no file of DCS's" no "$([[ -e "$mwf" ]] && echo yes || echo no)"
    check "duplicate: …no bouncer of DCS's" 0 "$(cst_cs bouncers list -o json | jq '[.[] | select(.name == "dcs-traefik-bouncer")] | length')"
    check "duplicate: …their middleware is in the chain" 1 "$(grep -c 'crowdsec-bouncer' "$chain")"
    # -- the same button, DCS's own copy is there already: it is rewritten as always
    rm -f "$trf"; cp -p "$tmpl" "$chain"
    cst_call admin POST /crowdsec/bouncers/register-traefik
    cst_is "duplicate: registering with no other definition" 200
    check "duplicate: …DCS writes its file as before" yes "$([[ -e "$mwf" ]] && echo yes || echo no)"
    check "duplicate: …and its bouncer" 1 "$(cst_cs bouncers list -o json | jq '[.[] | select(.name == "dcs-traefik-bouncer")] | length')"
}

cst_part_plugin() {
    echo "CrowdSec page: the Traefik bouncer plugin, its settings, and the routes it checks"
    cst_plugin_status
    cst_plugin_get
    cst_plugin_refuse
    cst_plugin_apply
    cst_plugin_files
    cst_plugin_home
    cst_plugin_restart
    cst_plugin_routes
    cst_plugin_fleet
    cst_plugin_duplicate
}

# ---- the ban profile: settings.json, profiles.yaml, backups, the restart and the way back ---------------------------------------------

CST_LIVE() { printf '%s/fake/rootfs/etc/crowdsec/%s' "$CST" "$1"; }   # a file of the container, as the stand-in keeps it

cst_settings_read() {
    local live orig
    live=$(CST_LIVE profiles.yaml)
    cst_world data traefik --traefik
    cst_call admin GET /crowdsec/settings
    cst_is "settings: the stock profile" 200
    cst_j "settings/stock" '.mode' stock '.editable' true '.custom' false '.profile.duration' 4h '.profile.range_duration' 4h '.profile.escalate.enabled' false '.profile.escalate.max' 720h \
        '.profile.overrides | length' 0 '.manual_duration' 4h '.defaults.duration' 4h '.presets | join(",")' 30m,1h,4h,12h,24h,3d,7d,30d '.limits.auto_max' 365d '.limits.manual_max' '10 years' \
        '.limits.overrides_max' 12 '.live.file' /etc/crowdsec/profiles.yaml '.live.profiles | join(",")' default_ip_remediation,default_range_remediation '.live.notified' false '.live.escalate' false \
        '.live.ip_duration' 4h '.live.range_duration' 4h '.drift' false '.backups | length' 0 '.raw' null '.retention_days' 7
    cst_t "settings/stock: each option has a sentence of help" '.help | (.duration | length > 20) and (.escalate | length > 20) and (.overrides | length > 20)'
    cst_call viewer GET /crowdsec/settings
    cst_is "settings: a viewer may look" 200
    cst_call none GET /crowdsec/settings
    cst_is "settings: nobody may look" 401
    # -- CrowdSec's own file, with the repeat-offender line switched on, is still the stock file
    orig=$(cat "$live")
    sed -i 's/^#duration_expr:/duration_expr:/' "$live"
    cst_call admin GET /crowdsec/settings
    cst_j "settings/stock with escalation" '.mode' stock '.live.escalate' true '.profile.escalate.enabled' true
    printf '%s\n' "$orig" > "$live"
    # -- one that sends alerts to the http_default plugin
    sed -i 's/^# notifications:/notifications:/; s/^#   - http_default .*/  - http_default/' "$live"
    cst_call admin GET /crowdsec/settings
    cst_j "settings/stock with notifications" '.mode' stock '.live.notified' true
    printf '%s\n' "$orig" > "$live"
    # -- a file that is not DCS's and not stock: read-only until the person says otherwise
    printf 'name: my_own\nfilters:\n  - Alert.Remediation == true\ndecisions:\n  - type: captcha\n    duration: 1h\non_success: break\n' > "$live"
    cst_call admin GET /crowdsec/settings
    cst_is "settings/custom: a hand-written profile can be read" 200
    cst_j "settings/custom" '.mode' custom '.editable' false '.custom' true '.live.profiles | join(",")' my_own '.raw | contains("my_own")' true '.profile.duration' 4h
    cst_call viewer GET /crowdsec/settings
    cst_j "settings/custom: a viewer sees that it is custom but not the file" '.mode' custom '.custom' true '.raw' null
    printf 'name: default_ip_remediation\nfilters:\n  - Alert.Remediation == true && Alert.GetScope() == "Ip"\ndecisions:\n  - type: captcha\n    duration: 1h\non_success: break\n' > "$live"
    cst_call admin GET /crowdsec/settings
    cst_j "settings/custom: stock names with other contents" '.mode' custom
    printf 'name: a\nfilters:\n  - x\n---\nname: b\nfilters:\n  - y\n---\nname: c\nfilters:\n  - z\n' > "$live"
    cst_call admin GET /crowdsec/settings
    cst_j "settings/custom: three profiles and no decisions" '.mode' custom '.live.profiles | join(",")' a,b,c
    : > "$live"
    cst_call admin GET /crowdsec/settings
    cst_is "settings: an empty profiles.yaml is an answer, not a crash" 200
    rm -f "$live"
    cst_call admin GET /crowdsec/settings
    cst_is "settings: no profiles.yaml at all" 200
}

cst_settings_write() {
    local live orig mark n0 hdr
    live=$(CST_LIVE profiles.yaml)
    cst_world data traefik --traefik
    orig=$(cat "$live")
    mark=$(cst_argv_n)
    cst_call admin PUT /crowdsec/settings '{"profile":{"duration":"12h","range_duration":"1d"}}'
    cst_is "settings/set: a new default length" 200
    cst_j "settings/set" '.success' true '.mode' dcs '.profile.duration' 12h '.profile.range_duration' 24h '.profile.escalate.enabled' false '.live.ip_duration' 12h '.live.range_duration' 24h \
        '.applied.changed' true '.applied.backup | test("^profiles-[0-9]{8}T[0-9]{6}Z\\.yaml$")' true '.drift' false '.backups | length' 1 '.backups[0].kind' profiles
    check "settings/set: the file says DCS wrote it" "# Managed by DCS:" "$(sed -n 1p "$live" | cut -c1-17)"
    check "settings/set: …and carries the settings it stands for" "12h 24h" "$(sed -n 's/^# dcs-settings: //p' "$live" | jq -r '[.profile.duration, .profile.range_duration] | join(" ")')"
    check "settings/set: the ban lengths are in the profiles" "12h 24h" "$(awk '/^name: default_ip_remediation/{n="ip"} /^name: default_range_remediation/{n="range"} /^    duration:/{print n, $2}' "$live" | sort | awk '{printf "%s%s", (NR>1?" ":""), $2}')"
    check "settings/set: the old file is kept, byte for byte" "$orig" "$(cat "$CST/.data/crowdsec/backups/$(jq -r '.applied.backup' <<< "$CST_BODY")")"
    check "settings/set: the backup folder and the settings are private" "700 600" "$(stat -c %a "$CST/.data/crowdsec/backups") $(stat -c %a "$CST/.data/crowdsec/settings.json")"
    check "settings/set: CrowdSec was restarted, once" 1 "$(cst_argv_since "$mark" | grep -c 'restart CrowdSec')"
    check "settings/set: …the new file was checked by CrowdSec first" 1 "$(cst_argv_since "$mark" | grep -c 'crowdsec -t')"
    check "settings/set: …and is what CrowdSec has" yes "$([[ "$(cst_cs version 2>&1 | head -n 1)" == version:* ]] && echo yes || echo no)"
    cst_call admin GET /crowdsec/status
    cst_j "settings/set: CrowdSec is healthy" '.state' healthy
    check "settings/set: it is audited" 1 "$(grep -c '"action":"auth.crowdsec_settings".*ban length 12h' "$CST/.data/audit.jsonl")"
    # -- the same again changes nothing and restarts nothing
    n0=$(cst_argv_n)
    cst_call admin PUT /crowdsec/settings '{"profile":{"duration":"12h","range_duration":"24h"}}'
    cst_j "settings/set: the same again" '.applied.changed' false '.applied.message | length > 5' true '.backups | length' 1
    check "settings/set: …restarts nothing" 0 "$(cst_argv_since "$n0" | grep -c 'restart CrowdSec')"
    cst_call admin PUT /crowdsec/settings '{}'
    cst_j "settings/set: an empty change" '.applied.changed' false
    # -- repeat offenders and a length for some scenarios
    cst_call admin PUT /crowdsec/settings '{"profile":{"escalate":{"enabled":true,"max":"30d"},"overrides":[{"pattern":"crowdsecurity/ssh*","duration":"24h"},{"pattern":"crowdsecurity/http-cve","duration":"7d"}]}}'
    cst_is "settings/set: repeat offenders and two overrides" 200
    cst_j "settings/set" '.profile.escalate.enabled' true '.profile.escalate.max' 720h '.profile.overrides | map("\(.pattern)=\(.duration)") | join(",")' 'crowdsecurity/ssh*=24h,crowdsecurity/http-cve=168h' \
        '.live.escalate' true '.live.profiles | join(",")' dcs_override_1,dcs_override_2,default_ip_remediation,default_range_remediation '.backups | length' 2
    check "settings/set: an override is a profile of its own, before the defaults" "dcs_override_1 dcs_override_2 default_ip_remediation default_range_remediation" "$(sed -n 's/^name: //p' "$live" | tr '\n' ' ' | sed 's/ $//')"
    check "settings/set: a prefix and a name" "1 1" "$(grep -c 'startsWith "crowdsecurity/ssh"' "$live") $(grep -c '== "crowdsecurity/http-cve"' "$live")"
    check "settings/set: every profile grows the ban with each earlier one" 4 "$(grep -c '^duration_expr: .Sprintf("%dh", min((GetDecisionsCount(Alert.GetValue()) + 1) \* [0-9]*, 720))' "$live")"
    cst_call admin PUT /crowdsec/settings '{"profile":{"escalate":{"enabled":false},"overrides":[]}}'
    cst_j "settings/set: repeat offenders off and the overrides gone" '.profile.escalate.enabled' false '.profile.overrides | length' 0 '.live.escalate' false '.live.profiles | join(",")' default_ip_remediation,default_range_remediation
    check "settings/set: …no more growing lengths" 0 "$(grep -c '^duration_expr' "$live")"
    # -- twelve overrides and the longest automatic ban, a year
    cst_call admin PUT /crowdsec/settings "$(jq -nc '{profile: {duration: "365d", overrides: [range(0; 12) | {pattern: "crowdsecurity/s\(.)", duration: "1h"}]}}')"
    cst_is "settings/set: twelve overrides and a year" 200
    cst_j "settings/set: …twelve, and a year is 8760 hours" '.profile.overrides | length' 12 '.live.profiles | length' 14 '.profile.duration' 8760h
    cst_call admin PUT /crowdsec/settings "$(jq -nc '{profile: {overrides: [range(0; 13) | {pattern: "crowdsecurity/s\(.)", duration: "1h"}]}}')"
    cst_is "settings/set: thirteen overrides" 400
    # -- the length of a ban made by hand: kept in DCS, nothing to restart
    n0=$(cst_argv_n)
    cst_call admin PUT /crowdsec/settings '{"manual_duration":"2d"}'
    cst_j "settings/manual" '.manual_duration' 48h '.applied.changed' false
    check "settings/manual: nothing is restarted for it" 0 "$(cst_argv_since "$n0" | grep -c 'restart CrowdSec')"
    cst_call admin POST /crowdsec/decisions '{"value":"198.18.90.1"}'
    cst_j "settings/manual: a ban without a length uses it" '.duration' 48h
    cst_call admin PUT /crowdsec/settings '{"manual_duration":"3650d"}'
    cst_j "settings/manual: ten years is the longest" '.manual_duration' 87600h
    cst_call admin PUT /crowdsec/settings '{"profile":{"foo":1,"duration":"3h"},"bar":2}'
    cst_j "settings/set: keys nobody knows are not written" '.profile.duration' 3h '.profile | has("foo")' false
    check "settings/set: …not into the file either" 0 "$(grep -c 'foo\|bar' "$live")"
    # -- drift: somebody edits the file by hand after DCS wrote it
    printf '# a hand edit\n' >> "$live"
    cst_call admin GET /crowdsec/settings
    cst_j "settings/drift: a hand edit is noticed" '.mode' dcs '.drift' true
    cst_call admin PUT /crowdsec/settings '{"profile":{"duration":"5h"}}'
    cst_j "settings/drift: saving writes it back, no drift" '.drift' false '.profile.duration' 5h
}

cst_settings_invalid() {
    local live orig i mark
    live=$(CST_LIVE profiles.yaml)
    cst_world data traefik --traefik
    orig=$(cat "$live")
    mark=$(cst_argv_n)
    local -a bodies=(
        '{"profile":{"duration":"nope"}}' '{"profile":{"duration":"30s"}}' '{"profile":{"duration":"366d"}}' '{"profile":{"duration":"11y"}}' '{"profile":{"duration":12}}' '{"profile":{"duration":"4h;id"}}'
        '{"profile":{"range_duration":"x"}}' '{"profile":{"range_duration":"400d"}}'
        '{"profile":{"escalate":{"enabled":true,"max":"x"}}}' '{"profile":{"escalate":{"enabled":true,"max":"366d"}}}' '{"profile":{"escalate":{"enabled":true,"max":"1h"},"duration":"4h"}}' '{"profile":{"escalate":"yes"}}' '{"profile":{"escalate":[]}}'
        '{"profile":{"overrides":[{"pattern":"","duration":"1h"}]}}' '{"profile":{"overrides":[{"pattern":"a b","duration":"1h"}]}}' '{"profile":{"overrides":[{"pattern":"crowdsecurity/x**","duration":"1h"}]}}'
        '{"profile":{"overrides":[{"pattern":"*","duration":"1h"}]}}' '{"profile":{"overrides":[{"pattern":"a\"b","duration":"1h"}]}}' '{"profile":{"overrides":[{"pattern":"a'"'"'b","duration":"1h"}]}}'
        '{"profile":{"overrides":[{"pattern":"a\\b","duration":"1h"}]}}' '{"profile":{"overrides":[{"pattern":"a$(id)","duration":"1h"}]}}' '{"profile":{"overrides":[{"pattern":"a;b","duration":"1h"}]}}'
        '{"profile":{"overrides":[{"pattern":"a/b"}]}}' '{"profile":{"overrides":[{"pattern":"a/b","duration":"x"}]}}' '{"profile":{"overrides":[{"pattern":"a/b","duration":"400d"}]}}'
        '{"profile":{"overrides":[{"pattern":"a/b","duration":"1h"},{"pattern":"a/b","duration":"2h"}]}}' '{"profile":{"overrides":{"a":1}}}' '{"profile":{"overrides":[1]}}' '{"profile":{"overrides":"x"}}'
        '{"profile":[]}' '{"profile":"x"}' '{"profile":5}' '{"manual_duration":"nope"}' '{"manual_duration":"30s"}' '{"manual_duration":"3651d"}' '{"manual_duration":5}' 'nope' '[]' '"x"'
    )
    # somebody else applies a configuration right now: this one waits for the lock (8 s) and then says so. It goes first, so that it starts at once
    mkdir -p "$CST/.data/crowdsec"
    cst_lock_hold "$CST/.data/crowdsec/apply.lock"
    cst_q "si-busy" admin PUT /crowdsec/settings '{"profile":{"duration":"9h"}}'
    for i in "${!bodies[@]}"; do cst_q "si$i" admin PUT /crowdsec/settings "${bodies[$i]}"; done
    cst_q "si-long" admin PUT /crowdsec/settings "$(jq -nc --arg p "$(head -c 130 /dev/zero | tr '\0' 'p')" '{profile: {overrides: [{pattern: $p, duration: "1h"}]}}')"
    cst_q "si-viewer" viewer PUT /crowdsec/settings '{"profile":{"duration":"1h"}}'
    cst_q "si-nobody" none PUT /crowdsec/settings '{"profile":{"duration":"1h"}}'
    cst_q "si-post" admin POST /crowdsec/settings '{"profile":{"duration":"1h"}}'
    cst_run
    cst_lock_release
    for i in "${!bodies[@]}"; do cst_use "si$i"; cst_is "settings/refuse: ${bodies[$i]}" 400; done
    cst_use "si-long";   cst_is "settings/refuse: a scenario of 130 characters" 400
    cst_use "si-viewer"; cst_is "settings/refuse: a viewer" 403
    cst_use "si-nobody"; cst_is "settings/refuse: nobody" 401
    cst_use "si-post";   cst_is "settings/refuse: POST is no way to change it" 404
    cst_use "si-busy";   cst_is "settings/busy: another change holds the lock" 409
    cst_j "settings/busy" '.stage' busy '.rolled_back' false
    check "settings/refuse: none of them touched the file" "$orig" "$(cat "$live")"
    check "settings/refuse: …restarted CrowdSec …made a backup" "0 0" "$(cst_argv_since "$mark" | grep -c 'restart CrowdSec') $(ls "$CST/.data/crowdsec/backups" 2>/dev/null | wc -l | tr -d ' ')"
    cst_call admin GET /crowdsec/settings
    cst_j "settings/refuse: …and the settings are the stock ones" '.mode' stock '.profile.duration' 4h
}

cst_settings_custom() {
    local live mine
    live=$(CST_LIVE profiles.yaml)
    cst_world data traefik --traefik
    mine=$'name: my_own\nfilters:\n  - Alert.Remediation == true\ndecisions:\n  - type: captcha\n    duration: 1h\non_success: break'
    printf '%s\n' "$mine" > "$live"
    cst_call admin PUT /crowdsec/settings '{"profile":{"duration":"6h"}}'
    cst_is "settings/custom: saving over a hand-written file needs a yes" 409
    cst_j "settings/custom" '.reason' custom_profile
    cst_call admin PUT /crowdsec/settings '{"manual_duration":"6h"}'
    cst_is "settings/custom: the length of manual bans does not touch the file" 200
    cst_call admin PUT /crowdsec/settings '{}'
    cst_is "settings/custom: an empty change" 200
    check "settings/custom: the file is as it was" "$mine" "$(cat "$live")"
    cst_call admin PUT /crowdsec/settings '{"profile":{"duration":"6h"},"take_over":true}'
    cst_is "settings/custom: with take_over the file is replaced" 200
    cst_j "settings/custom" '.mode' dcs '.profile.duration' 6h '.applied.changed' true
    check "settings/custom: …and the hand-written one is in the backups, byte for byte" "$mine" "$(cat "$CST/.data/crowdsec/backups/$(jq -r '.applied.backup' <<< "$CST_BODY")")"
    check "settings/custom: …DCS wrote the file" "# Managed by DCS:" "$(sed -n 1p "$live" | cut -c1-17)"
}

cst_settings_partial() {
    local live one range none
    live=$(CST_LIVE profiles.yaml)
    cst_world data traefik --traefik
    one=$'name: default_ip_remediation\nfilters:\n  - Alert.Remediation == true && Alert.GetScope() == "Ip"\ndecisions:\n  - type: ban\n    duration: 4h\non_success: break\n---\nname: my_own\nfilters:\n  - Alert.Remediation == true\ndecisions:\n  - type: captcha\n    duration: 1h\non_success: break'
    range=$'name: default_range_remediation\nfilters:\n  - Alert.Remediation == true && Alert.GetScope() == "Range"\ndecisions:\n  - type: ban\n    duration: 4h\non_success: break\n---\nname: my_own\nfilters:\n  - Alert.Remediation == true\ndecisions:\n  - type: captcha\n    duration: 1h\non_success: break'
    none=$'name: my_own\nfilters:\n  - Alert.Remediation == true\ndecisions:\n  - type: captcha\n    duration: 1h\non_success: break'
    # a file that has only one of the two stock profiles (or neither) is a hand-written file: the page must say so, not fail
    printf '%s\n' "$one" > "$live"
    cst_call admin GET /crowdsec/settings
    cst_is "settings/partial: only the IP profile plus one of your own" 200
    cst_j "settings/partial(ip)" '.mode' custom '.profile.duration' 4h
    printf '%s\n' "$range" > "$live"
    cst_call admin GET /crowdsec/settings
    cst_is "settings/partial: only the range profile plus one of your own" 200
    cst_j "settings/partial(range)" '.mode' custom
    printf '%s\n' "$none" > "$live"
    cst_call admin GET /crowdsec/settings
    cst_is "settings/partial: neither stock profile" 200
    cst_j "settings/partial(none)" '.mode' custom
}

cst_settings_rollback() {
    local live orig n0
    live=$(CST_LIVE profiles.yaml)
    # -- CrowdSec will not start with the new file: the old one comes back
    cst_world data traefik --traefik
    orig=$(cat "$live")
    cst_mock --mock-set restart_fails=1
    n0=$(cst_argv_n)
    cst_call admin PUT /crowdsec/settings '{"profile":{"duration":"9h"}}'
    cst_is "settings/rollback: CrowdSec does not come back" 502
    cst_j "settings/rollback" '.error' true '.rolled_back' true '.stage' apply '.message | test("did not come back")' true '.message | test("previous files are back")' true
    check "settings/rollback: the old file is back, byte for byte" "$orig" "$(cat "$live")"
    check "settings/rollback: CrowdSec was restarted twice (with the new file, with the old)" 2 "$(cst_argv_since "$n0" | grep -c 'restart CrowdSec')"
    check "settings/rollback: the backup was made before anything was touched" 1 "$(ls "$CST/.data/crowdsec/backups" | wc -l | tr -d ' ')"
    check "settings/rollback: nothing was saved as the new settings" "" "$(jq -r '.profile.duration // empty' "$CST/.data/crowdsec/settings.json" 2>/dev/null)"
    cst_call admin GET /crowdsec/status
    cst_j "settings/rollback: CrowdSec runs again" '.state' healthy
    cst_call admin GET /crowdsec/settings
    cst_j "settings/rollback: …with the settings it had" '.mode' stock '.profile.duration' 4h
    check "settings/rollback: the failure is in the audit log" 1 "$(grep -c '"action":"auth.crowdsec_settings".*failed (5)' "$CST/.data/audit.jsonl")"
    cst_call admin PUT /crowdsec/settings '{"profile":{"duration":"9h"}}'
    cst_is "settings/rollback: and the same change works when CrowdSec cooperates" 200
    # -- CrowdSec's own check says no: nothing is touched
    cst_world data traefik --traefik
    orig=$(cat "$live")
    rm -f "$(CST_LIVE config.yaml)"
    n0=$(cst_argv_n)
    cst_call admin PUT /crowdsec/settings '{"profile":{"duration":"9h"}}'
    cst_is "settings/validation: CrowdSec cannot check the file" 422
    cst_j "settings/validation" '.stage' validation '.rolled_back' false
    check "settings/validation: the file is as it was, CrowdSec was not restarted" "$orig 0" "$(cat "$live") $(cst_argv_since "$n0" | grep -c 'restart CrowdSec')"
}

cst_part_settings() {
    echo "CrowdSec page: the ban profile"
    cst_settings_read
    cst_settings_write
    cst_settings_invalid
    cst_settings_custom
    cst_settings_partial
    cst_settings_rollback
}

# ---- the Discord messages: settings, the template and profile files, preview, test message ------------------------------------------

# what the notification plugin of a real CrowdSec sent for `cscli notifications test` with the message DCS ships (captured from CrowdSec 1.8.1 with
# the shipped notifications-discord.yaml, domain lab.example.com). The message DCS renders itself for the same alert has to be this one.
CST_GOLDEN='{"username":"CrowdSec","avatar_url":"https://raw.githubusercontent.com/scotthowson/dcs-orchestrator-ui/v2.0.0/brand/discord/crowdsec-avatar.png","allowed_mentions":{"parse":[]},"embeds":[{"title":"🛡️ Attack blocked","url":"https://app.crowdsec.net/cti/10.10.10.10","color":15942494,"description":"**10.10.10.10**\n1 hits → **ban** for 4h","fields":[{"name":"Scenario","value":"`test alert`","inline":true},{"name":"Scope","value":"Ip · cscli","inline":true},{"name":"Lookup","value":"[CrowdSec CTI](https://app.crowdsec.net/cti/10.10.10.10) · [AbuseIPDB](https://www.abuseipdb.com/check/10.10.10.10)","inline":true}],"footer":{"text":"CrowdSec · lab.example.com"}}]}'

# cst_pv PATCH — the preview of the message with PATCH (a JSON object) laid over the settings in force
cst_pv() { cst_call admin POST /crowdsec/notifications/preview "{\"settings\":$1}"; }

cst_notify_read() {
    cst_world data traefik --traefik
    cst_call admin GET /crowdsec/notifications
    cst_is "notify: the settings" 200
    cst_j "notify/fresh" '(.defaults | .enabled = false) == .settings' true '.settings.enabled' false '.settings.webhook.mode' global '.webhook.configured' false '.webhook.masked' null \
        '.state.enabled' false '.state.wired' false '.state.plugin_active' false '.state.file' other '.state.profile_mode' stock '.state.drift' false '.state.working' false \
        '.samples | join(",")' exploit,manual,probe,simulated,ssh '.limits.title' 200 '.limits.description' 1500 '.limits.footer' 200 '.limits.fields' 8 '.limits.group_threshold_max' 10 \
        '.status.last_test' null '.status.last_apply' null '.status.delivery_errors | length' 0
    cst_t "notify/fresh: the placeholders are described and none repeats" '(.placeholders | length) > 25 and (.placeholders | map(.name) | (unique | length) == length) and (.placeholders | all(has("name") and has("group") and has("label") and has("example") and has("description")))'
    cst_t "notify/fresh: the default message uses placeholders that exist" '[.defaults.message | (.title, .description, .footer, .link, (.fields[] | .name, .value)) | scan("\\{([a-z_]+)\\}") | .[0]] - [.placeholders[].name] | length == 0'
    cst_call viewer GET /crowdsec/notifications
    cst_is "notify: a viewer may look" 200
    cst_call none GET /crowdsec/notifications
    cst_is "notify: nobody may look" 401
    # -- the server's own webhook is seen, and never shown
    cst_env DISCORD_WEBHOOK_URL "$CST_HOOK"
    cst_call admin GET /crowdsec/notifications
    cst_j "notify/server webhook" '.webhook.configured' true '.webhook.mode' global '.webhook.sources.global.configured' true '.webhook.masked' "https://discord.com/api/webhooks/$CST_HOOK_ID/••••${CST_HOOK_TOKEN: -4}"
    check "notify/server webhook: the token is not in the answer" 0 "$(grep -cF -- "$CST_HOOK_TOKEN" <<< "$CST_BODY")"
    cst_env DISCORD_WEBHOOK_URL
    # -- CrowdSec already posts to Discord (the file the template ships): the webhook it uses is kept
    cst_world data traefik --traefik
    cst_mock --mock-set discord=1
    cst_call admin GET /crowdsec/notifications
    cst_j "notify/already wired" '.settings.enabled' true '.settings.webhook.mode' keep '.webhook.configured' true '.webhook.sources.keep.configured' true '.state.wired' true '.state.plugin_active' true \
        '.webhook.masked | startswith("https://discord.com/api/webhooks/")' true '.webhook.masked | contains("••••")' true
}

cst_notify_validation() {
    local i mark
    cst_world data traefik --traefik
    mark=$(cst_argv_n)
    # PATCH|part of the error
    local -a cases=(
        '{"enabled":"yes"}|enabled must be true or false'
        '{"webhook":{"mode":"none"}}|webhook source must be'
        '{"identity":{"name":""}}|sender name is empty'
        '{"identity":{"name":"my Discord bot"}}|refuses sender names'
        '{"identity":{"name":"a@b"}}|refuses sender names'
        '{"identity":{"name":"a#b"}}|refuses sender names'
        '{"identity":{"name":"a:b"}}|refuses sender names'
        '{"identity":{"name":"Clyde"}}|refuses sender names'
        '{"identity":{"name":"a\nb"}}|single line'
        '{"identity":{"name":"'"$(head -c 81 /dev/zero | tr '\0' n)"'"}}|80 characters'
        '{"identity":{"avatar_url":"http://x.example/a.png"}}|https://'
        '{"identity":{"avatar_url":"https://x.example/a b.png"}}|https://'
        '{"identity":{"avatar_url":"https://x.example/a\"b.png"}}|https://'
        '{"identity":{"avatar_url":5}}|https://'
        '{"embed":{"color_mode":"rainbow"}}|colour mode'
        '{"embed":{"color":"red"}}|#e11d48'
        '{"embed":{"color":"#12"}}|#e11d48'
        '{"embed":{"color":"#GGGGGG"}}|#e11d48'
        '{"mention":{"mode":"everyone2"}}|mention must be'
        '{"mention":{"mode":"role","id":"123"}}|long number'
        '{"mention":{"mode":"user","id":"abc"}}|long number'
        '{"mention":{"mode":"role","id":"1234567890123456789012"}}|long number'
        '{"mention":{"mode":"here","text":"'"$(head -c 301 /dev/zero | tr '\0' t)"'"}}|300 characters'
        '{"mention":{"mode":"here","text":"a\u0007b"}}|control characters'
        '{"events":{"bans":"yes"}}|switches must be true or false'
        '{"events":{"detect_only":1}}|switches must be true or false'
        '{"filters":{"min_events":-1}}|0 to 1000'
        '{"filters":{"min_events":1001}}|0 to 1000'
        '{"filters":{"min_events":1.5}}|0 to 1000'
        '{"filters":{"min_events":"many"}}|0 to 1000'
        '{"filters":{"only":["a b"]}}|up to 20 names'
        '{"filters":{"only":["a\"b"]}}|up to 20 names'
        '{"filters":{"only":["a\\b"]}}|up to 20 names'
        '{"filters":{"ignore":["a;b"]}}|up to 20 names'
        '{"filters":{"ignore":["*"]}}|up to 20 names'
        '{"filters":{"only":"x"}}|up to 20 names'
        '{"filters":{"ignore":['"$(seq -f '"crowdsecurity/s%g"' -s, 1 21)"']}}|up to 20 names'
        '{"delivery":{"group_wait":0}}|1 to 600'
        '{"delivery":{"group_wait":601}}|1 to 600'
        '{"delivery":{"group_threshold":0}}|1 to 10'
        '{"delivery":{"group_threshold":11}}|1 to 10'
        '{"delivery":{"max_retry":-1}}|0 to 10'
        '{"delivery":{"max_retry":11}}|0 to 10'
        '{"delivery":{"timeout":0}}|1 to 60'
        '{"delivery":{"timeout":61}}|1 to 60'
        '{"delivery":{"timeout":"x"}}|1 to 60'
        '{"message":{"title":"{bogus}"}}|title uses {bogus}'
        '{"message":{"description":"{bogus}"}}|description uses {bogus}'
        '{"message":{"footer":"{bogus}"}}|footer uses {bogus}'
        '{"message":{"link":"{bogus}"}}|title link uses {bogus}'
        '{"message":{"title":"{ip} and {nope_1}"}}|uses {nope_1}'
        '{"message":{"link":"'"$(head -c 301 /dev/zero | tr '\0' l)"'"}}|300 characters'
        '{"message":{"title":"'"$(head -c 201 /dev/zero | tr '\0' t)"'"}}|200 characters'
        '{"message":{"description":"'"$(head -c 1501 /dev/zero | tr '\0' d)"'"}}|1500 characters'
        '{"message":{"footer":"'"$(head -c 201 /dev/zero | tr '\0' f)"'"}}|200 characters'
        '{"message":{"title":"a\nb"}}|single line'
        '{"message":{"footer":"a\tb"}}|single line'
        '{"message":{"description":"a\u0007b"}}|control characters'
        '{"message":{"timestamp":"yes"}}|timestamp must be'
        '{"message":{"title":"","description":"","fields":[]}}|would be empty'
        '{"message":{"fields":[{"name":"","value":"x"}]}}|Field 1 needs a name and a value'
        '{"message":{"fields":[{"name":"n","value":""}]}}|Field 1 needs a name and a value'
        '{"message":{"fields":[{"name":"n","value":"{bogus}"}]}}|Field 1 value uses {bogus}'
        '{"message":{"fields":[{"name":"{bogus}","value":"v"}]}}|Field 1 name uses {bogus}'
        '{"message":{"fields":[{"name":"ok","value":"v"},{"name":"n","value":"'"$(head -c 501 /dev/zero | tr '\0' v)"'"}]}}|Field 2 value is too long'
        '{"message":{"fields":[{"name":"'"$(head -c 101 /dev/zero | tr '\0' n)"'","value":"v"}]}}|Field 1 name is too long'
        '{"message":{"fields":[{"name":"1","value":"v"},{"name":"2","value":"v"},{"name":"3","value":"v"},{"name":"4","value":"v"},{"name":"5","value":"v"},{"name":"6","value":"v"},{"name":"7","value":"v"},{"name":"8","value":"v"},{"name":"9","value":"v"}]}}|up to 8 fields'
        '{"message":{"fields":"x"}}|up to 8 fields'
        '{"message":{"fields":["x"]}}|Field 1 is malformed'
    )
    for i in "${!cases[@]}"; do cst_q "pv$i" admin POST /crowdsec/notifications/preview "{\"settings\":${cases[$i]%%|*}}"; done
    # the limits themselves are fine
    local -a fine=('{"identity":{"name":"'"$(head -c 80 /dev/zero | tr '\0' n)"'"}}' '{"identity":{"avatar_url":""}}' '{"embed":{"color_mode":"fixed","color":"#00FF7f"}}' '{"mention":{"mode":"role","id":"123456789012345678","text":"x"}}'
                   '{"mention":{"mode":"everyone"}}' '{"mention":{"mode":"here","text":"'"$(head -c 300 /dev/zero | tr '\0' t)"'"}}' '{"filters":{"min_events":1000,"only":["crowdsecurity/ssh*","crowdsecurity/http-cve"],"ignore":["a/b","c-d.e"]}}'
                   '{"delivery":{"group_wait":600,"group_threshold":10,"max_retry":10,"timeout":60}}' '{"delivery":{"group_wait":1,"group_threshold":1,"max_retry":0,"timeout":1}}'
                   '{"message":{"title":"'"$(head -c 200 /dev/zero | tr '\0' t)"'"}}' '{"message":{"description":"'"$(head -c 1500 /dev/zero | tr '\0' d)"'"}}' '{"message":{"description":"line one\nline two"}}'
                   '{"message":{"fields":[{"name":"1","value":"v"},{"name":"2","value":"v"},{"name":"3","value":"v"},{"name":"4","value":"v"},{"name":"5","value":"v"},{"name":"6","value":"v"},{"name":"7","value":"v"},{"name":"8","value":"v"}]}}'
                   '{"message":{"fields":[]}}' '{"message":{"title":"","description":"","fields":[{"name":"only","value":"a field"}]}}' '{"message":{"timestamp":true}}')
    for i in "${!fine[@]}"; do cst_q "fine$i" admin POST /crowdsec/notifications/preview "{\"settings\":${fine[$i]}}"; done
    cst_q pvviewer viewer POST /crowdsec/notifications/preview '{}'
    cst_q pvnobody none POST /crowdsec/notifications/preview '{}'
    cst_q pvsample admin POST /crowdsec/notifications/preview '{"sample":"nope"}'
    cst_q pvsample2 admin POST /crowdsec/notifications/preview '{"sample":"probe;id"}'
    cst_q pvsettings admin POST /crowdsec/notifications/preview '{"settings":[1]}'
    cst_q pvalert admin POST /crowdsec/notifications/preview '{"alert_id":"x"}'
    cst_q pvalert2 admin POST /crowdsec/notifications/preview '{"alert_id":99999}'
    # the same errors when the change is saved: refused before anything is written
    local -a saved=(3 15 26 35 42 48 55)
    for i in "${saved[@]}"; do cst_q "sv$i" admin PUT /crowdsec/notifications "{\"settings\":${cases[$i]%%|*}}"; done
    cst_q svhook admin PUT /crowdsec/notifications '{"webhook_url":"http://discord.com/api/webhooks/111111111111111111/NOTAREALTOKEN_0123456789-abcdefghij","settings":{"enabled":true}}'
    cst_q svhook2 admin PUT /crowdsec/notifications '{"webhook_url":"https://evil.example/api/webhooks/111111111111111111/NOTAREALTOKEN_0123456789-abcdefghij"}'
    cst_q svhook3 admin PUT /crowdsec/notifications '{"webhook_url":"https://discord.com/api/webhooks/x/y"}'
    cst_q svhook4 admin PUT /crowdsec/notifications '{"webhook_url":"https://discord.com/api/webhooks/111111111111111111/short"}'
    cst_q svhook5 admin PUT /crowdsec/notifications '{"webhook_url":"https://discord.com/api/webhooks/111111111111111111/NOTAREALTOKEN_0123456789-abcdefghij/../x"}'
    cst_q svnone admin PUT /crowdsec/notifications '{"settings":{"enabled":true}}'
    cst_q svjson admin PUT /crowdsec/notifications 'no'
    cst_q svsettings admin PUT /crowdsec/notifications '{"settings":"x"}'
    cst_q svviewer viewer PUT /crowdsec/notifications '{"settings":{"enabled":false}}'
    cst_q svnobody none PUT /crowdsec/notifications '{"settings":{"enabled":false}}'
    cst_run
    for i in "${!cases[@]}"; do
        cst_use "pv$i"
        cst_is "notify/preview: ${cases[$i]%%|*} is answered" 200
        cst_j "notify/preview: …it is not valid" '.valid' false '.payload' null
        cst_t "notify/preview: …and says why" ".error | test(\"${cases[$i]#*|}\")"
    done
    for i in "${!fine[@]}"; do cst_use "fine$i"; cst_j "notify/preview: ${fine[$i]:0:70} is valid" '.valid' true '.payload.embeds | length' 1; done
    cst_use pvviewer; cst_is "notify/preview: a viewer may draw it (it only renders, it never sends)" 200
    cst_j "notify/preview: …the viewer's drawing is valid" '.valid' true
    cst_t "notify/preview: …and shows no webhook address" '(tostring | test("api/webhooks") | not)'
    cst_use pvnobody; cst_is "notify/preview: nobody" 401
    cst_use pvsample;  cst_is "notify/preview: an unknown sample" 400
    cst_use pvsample2; cst_is "notify/preview: a sample name with a semicolon" 400
    cst_use pvsettings; cst_is "notify/preview: settings that are no object" 400
    cst_use pvalert;   cst_is "notify/preview: an alert id that is no number" 400
    cst_use pvalert2;  cst_is "notify/preview: an alert that does not exist" 404
    for i in "${saved[@]}"; do cst_use "sv$i"; cst_is "notify/save: ${cases[$i]%%|*} is refused" 400; done
    cst_use svhook;  cst_is "notify/save: a webhook that is not https" 400
    cst_use svhook2; cst_is "notify/save: a webhook of another site" 400
    cst_use svhook3; cst_is "notify/save: a webhook without a real id" 400
    cst_use svhook4; cst_is "notify/save: a webhook with a short token" 400
    cst_use svhook5; cst_is "notify/save: a webhook with more path behind the token" 400
    cst_use svnone;  cst_is "notify/save: on, with nowhere to post to" 400
    cst_t "notify/save: …says what is missing" '.message | test("webhook")'
    cst_use svjson;  cst_is "notify/save: not JSON" 400
    cst_use svsettings; cst_is "notify/save: settings that are no object" 400
    cst_use svviewer; cst_is "notify/save: a viewer may not" 403
    cst_use svnobody; cst_is "notify/save: nobody may not" 401
    check "notify/save: none of them wrote a file or restarted CrowdSec" "0 0" "$(cst_argv_since "$mark" | grep -c 'restart CrowdSec') $(ls "$CST/.data/crowdsec/backups" 2>/dev/null | wc -l | tr -d ' ')"
    check "notify/save: …or stored a webhook" 0 "$(cst_secrets_n 'CROWDSEC*')"
    # -- every placeholder is replaced by a value (a sample alert has all of them)
    cst_call admin GET /crowdsec/notifications
    local all
    all=$(jq -r '[.placeholders[] | select(.name != "time") | "{\(.name)}"] | join(" ")' <<< "$CST_BODY")
    cst_call admin POST /crowdsec/notifications/preview "$(jq -nc --arg d "$all" '{settings: {message: {description: $d}}}')"
    cst_j "notify/preview: every placeholder is filled in" '.valid' true '.payload.embeds[0].description | test("\\{[a-z_]+\\}") | not' true
    cst_j "notify/preview: the sample alert's values" '.payload.embeds[0].description | contains("89.248.165.10")' true '.payload.embeds[0].description | contains(":flag_nl:")' true \
        '.payload.embeds[0].description | contains("app.example.com")' true '.payload.embeds[0].description | contains("/wp-login.php")' true
    cst_call admin POST /crowdsec/notifications/preview '{"settings":{"message":{"description":"{time}"}}}'
    cst_t "notify/preview: {time} is Discord's live time stamp" '.payload.embeds[0].description | test("^<t:[0-9]+:R>$")'
    # -- the sample alerts: the colour and the words follow the family of the scenario
    for i in probe ssh exploit manual simulated; do cst_q "sm$i" admin POST /crowdsec/notifications/preview "{\"sample\":\"$i\"}"; done
    cst_q smalert admin POST /crowdsec/notifications/preview '{"alert_id":10}'
    cst_q smalert2 admin POST /crowdsec/notifications/preview '{"alert_id":8,"settings":{"embed":{"color_mode":"fixed","color":"#0000ff"}}}'
    cst_run
    cst_use smprobe;     cst_j "notify/sample probe" '.valid' true '.sample' probe '.payload.embeds[0].color' 16098851 '.payload.embeds[0].title | endswith("Web probing")' true '.payload.embeds[0].fields | length' 4
    cst_use smssh;       cst_j "notify/sample ssh" '.payload.embeds[0].color' 15942494 '.payload.embeds[0].fields | length' 3
    cst_use smexploit;   cst_j "notify/sample exploit" '.payload.embeds[0].color' 10979578 '.payload.embeds[0].title | endswith("Exploit attempt")' true
    cst_use smmanual;    cst_j "notify/sample manual" '.payload.embeds[0].title | endswith("Manual ban") or endswith("Attack blocked")' true
    cst_use smsimulated; cst_j "notify/sample simulated" '.payload.embeds[0].description | contains("simulated ban")' true
    cst_use smalert;     cst_j "notify/a real alert" '.sample' 'alert 10' '.alert.id' 10 '.payload.embeds[0].description | contains("89.248.165.10")' true '.payload.embeds[0].description | contains("13 hits")' true
    cst_use smalert2;    cst_j "notify/a real alert, a fixed colour" '.payload.embeds[0].color' 255
}

cst_notify_apply() {
    local live http mark n0 tok body i
    live=$(CST_LIVE profiles.yaml); http=$(CST_LIVE notifications/http.yaml)
    cst_world data traefik --traefik
    : > "$CST/discord.log"; rm -f "$CST/discord.status"
    mark=$(cst_argv_n)
    cst_call admin PUT /crowdsec/notifications "{\"webhook_url\":\"$CST_HOOK\",\"settings\":{\"enabled\":true}}"
    cst_is "notify/apply: on, with a webhook of its own" 200
    cst_j "notify/apply" '.success' true '.settings.enabled' true '.settings.webhook.mode' custom '.webhook.configured' true '.webhook.masked' "https://discord.com/api/webhooks/$CST_HOOK_ID/••••${CST_HOOK_TOKEN: -4}" \
        '.state.enabled' true '.state.wired' true '.state.plugin_active' true '.state.file' dcs '.state.profile_mode' dcs '.state.working' true '.applied.changed' true \
        '.status.last_apply.ok' true
    check "notify/apply: the token is not in the answer" 0 "$(grep -cF -- "$CST_HOOK_TOKEN" <<< "$CST_BODY")"
    cst_call admin GET /crowdsec/notifications
    check "notify/apply: …nor in the next one" 0 "$(grep -cF -- "$CST_HOOK_TOKEN" <<< "$CST_BODY")"
    check "notify/apply: it is kept as a secret (encrypted)" 1 "$(cst_secrets_n CROWDSEC_DISCORD_WEBHOOK.enc)"
    check "notify/apply: …and appears nowhere else on the DCS side" "" "$(grep -rlF --exclude-dir=fake --exclude-dir=.secrets --exclude=discord.log --exclude=discord.py -- "$CST_HOOK_TOKEN" "$CST" 2>/dev/null | sed "s#^$CST/##" | sort | tr '\n' ' ')"
    check "notify/apply: CrowdSec's file has the address (it has to)" 1 "$(grep -cF -- "url: $CST_HOOK" "$http")"
    check "notify/apply: …and the file was made private before it was copied in" "600 644" "$(grep 'CrowdSec:/etc/crowdsec/notifications/http.yaml' "$CST/cp-modes.log" | tail -n 1 | cut -d' ' -f1) $(grep 'CrowdSec:/etc/crowdsec/profiles.yaml' "$CST/cp-modes.log" | tail -n 1 | cut -d' ' -f1)"
    check "notify/apply: the address is on no command line" 0 "$(grep -cF -- "$CST_HOOK_TOKEN" "$CST/argv.log")"
    check "notify/apply: the alerts are wired to the plugin, one profile per kind" "yes" "$([[ "$(grep -c '^  - http_default' "$live")" -ge 2 ]] && echo yes || echo no)"
    check "notify/apply: CrowdSec checked the files, restarted once and read the plugin list" "1 1" "$(cst_argv_since "$mark" | grep -c 'crowdsec -t') $(cst_argv_since "$mark" | grep -c 'restart CrowdSec')"
    check "notify/apply: the plugin is active in CrowdSec" yes "$(cst_cs notifications list 2>/dev/null | grep -q 'http_default.*default_ip_remediation' && echo yes || echo no)"
    check "notify/apply: the first line says DCS wrote both files" "# Managed by DCS: # Managed by DCS:" "$(sed -n 1p "$live" | cut -c1-17) $(sed -n 1p "$http" | cut -c1-17)"
    check "notify/apply: the old files are kept" "http profiles" "$(ls "$CST/.data/crowdsec/backups" | sed 's/-.*//' | sort | tr '\n' ' ' | sed 's/ $//')"
    check "notify/apply: the settings are private" "600" "$(stat -c %a "$CST/.data/crowdsec/notify.json")"
    cst_cs notifications inspect http_default > /dev/null 2>&1
    cp "$http" "$CST/base-http.yaml"
    python3 "$CST/tplscan.py" < "$http" > "$CST/base-scan.json"
    check "notify/template: nothing typed by a person is in the template's code" "[] 11" "$(jq -c '.bad' "$CST/base-scan.json") $(jq -r '.top | length' "$CST/base-scan.json")"
    check "notify/template: the file's own keys are exactly these" "format,group_threshold,group_wait,headers,log_level,max_retry,method,name,timeout,type,url" "$(jq -r '.top | join(",")' "$CST/base-scan.json")"

    # -- every setting, saved and read back
    body='{"settings":{"enabled":true,"webhook":{"mode":"custom"},"identity":{"name":"Door Guard","avatar_url":"https://example.com/a.png"},"embed":{"color_mode":"fixed","color":"#00FF7F"},"mention":{"mode":"role","id":"123456789012345678","text":"look at this"},"events":{"bans":true,"simulated":false,"detect_only":true},"filters":{"min_events":5,"only":["crowdsecurity/ssh*","crowdsecurity/http-cve","crowdsecurity/ssh*"],"ignore":["crowdsecurity/http-crawl-non_statics"]},"delivery":{"group_wait":30,"group_threshold":5,"max_retry":2,"timeout":20},"message":{"title":"Alert: {label}","description":"{ip} did {scenario}\nwith {events} events","footer":"{domain}","link":"{cti_url}","timestamp":true,"fields":[{"name":"Where","value":"{country_tag}","inline":true},{"name":"What","value":"{scenario_short}","inline":false}]}}}'
    cst_call admin PUT /crowdsec/notifications "$body"
    cst_is "notify/apply: every setting at once" 200
    cst_call admin GET /crowdsec/notifications
    cst_j "notify/apply: read back" '.settings.identity.name' 'Door Guard' '.settings.embed.color' '#00ff7f' '.settings.embed.color_mode' fixed '.settings.mention.mode' role '.settings.mention.id' 123456789012345678 \
        '.settings.events.simulated' false '.settings.events.detect_only' true '.settings.filters.min_events' 5 '.settings.filters.only | join(",")' 'crowdsecurity/http-cve,crowdsecurity/ssh*' \
        '.settings.filters.ignore | join(",")' crowdsecurity/http-crawl-non_statics '.settings.delivery | "\(.group_wait) \(.group_threshold) \(.max_retry) \(.timeout)"' '30 5 2 20' \
        '.settings.message.title' 'Alert: {label}' '.settings.message.timestamp' true '.settings.message.fields | length' 2 '.settings.message.fields[1].inline' false '.settings.message.description' $'{ip} did {scenario}\nwith {events} events'
    check "notify/apply: the profiles say who gets a message" "yes yes yes yes yes" "$(
        for f in 'Alert.GetEventsCount() >= 5' 'Alert.GetScenario() == "crowdsecurity/http-cve" || Alert.GetScenario() startsWith "crowdsecurity/ssh"' '!(Alert.GetScenario() == "crowdsecurity/http-crawl-non_statics")' \
                 '(Alert.Simulated == nil || !Alert.Simulated)' 'name: dcs_notify_detect_only'; do grep -qF -- "$f" "$live" && printf 'yes ' || printf 'no '; done | sed 's/ $//')"
    check "notify/apply: …and a detection that is only seen goes on to the next profile" 1 "$(grep -c '^on_success: continue' "$live")"
    check "notify/apply: the plugin's delivery settings are in its file" "group_wait: 30s group_threshold: 5 max_retry: 2 timeout: 20s" "$(grep -E '^(group_wait|group_threshold|max_retry|timeout):' "$http" | tr '\n' ' ' | sed 's/ $//')"
    check "notify/apply: the mention is in the template" 1 "$(grep -c '<@&123456789012345678> look at this' "$http")"
    python3 "$CST/tplscan.py" < "$http" > "$CST/scan.json"
    check "notify/template: with every option used the file still has no line break inside a string and the same keys" "[] $(jq -r '.top | join(",")' "$CST/base-scan.json")" "$(jq -r '"\(.bad | tojson) \(.top | join(","))"' "$CST/scan.json")"

    # -- the preview is what is sent
    cst_call admin POST /crowdsec/notifications/preview '{"sample":"probe"}'
    body=$(jq -cS '.payload | del(.embeds[0].timestamp)' <<< "$CST_BODY")
    n0=$(cst_disc_n)
    cst_call admin POST /crowdsec/notifications/test '{"sample":"probe","include_mention":true}'
    cst_is "notify/test: a message" 200
    cst_j "notify/test" '.success' true '.delivered' true '.http' 204 '.sample' probe '.webhook' "https://discord.com/api/webhooks/$CST_HOOK_ID/••••${CST_HOOK_TOKEN: -4}"
    check "notify/test: one message reached Discord" $((n0 + 1)) "$(cst_disc_n)"
    check "notify/test: it went to the webhook's address" "/api/webhooks/$CST_HOOK_ID/$CST_HOOK_TOKEN" "$(tail -n 1 "$CST/discord.log" | jq -r .path)"
    check "notify/test: what arrived is what the preview showed (the time stamp is of the second it was made)" "$body" "$(cst_disc_last | jq -cS 'del(.embeds[0].timestamp)')"
    check "notify/test: …the mention pings the role" "<@&123456789012345678> look at this" "$(cst_disc_last | jq -r .content)"
    cst_j "notify/test: …and Discord may notify that role" '.success' true
    check "notify/test: allowed_mentions" '{"roles":["123456789012345678"]}' "$(cst_disc_last | jq -c .allowed_mentions)"
    check "notify/test: the token is not on curl's command line" 0 "$(grep -cF -- "$CST_HOOK_TOKEN" "$CST/curl-argv.log")"
    cst_call admin POST /crowdsec/notifications/test '{"sample":"probe"}'
    check "notify/test: without include_mention nobody is pinged" '[null,{"parse":[]}]' "$(cst_disc_last | jq -c '[.content, .allowed_mentions]')"
    check "notify/test: …and the footer says it is a test" yes "$(cst_disc_last | jq -e '.embeds[0].footer.text | endswith(" · test message")' >/dev/null && echo yes || echo no)"
    check "notify/test: …the rest of the message is the preview's" "$(jq -c 'del(.content) | .allowed_mentions = {parse: []} | .embeds[0].footer.text += " · test message"' <<< "$body" | jq -cS .)" "$(cst_disc_last | jq -cS 'del(.embeds[0].timestamp)')"
    for i in user here everyone none; do
        case "$i" in user|role) tok=',"id":"223456789012345678"' ;; *) tok='' ;; esac
        cst_call admin POST /crowdsec/notifications/preview "{\"settings\":{\"mention\":{\"mode\":\"$i\"$tok,\"text\":\"\"}}}"
        check "notify/mention $i: what the message says" "$(case "$i" in user) echo '<@223456789012345678>|{"users":["223456789012345678"]}' ;; here) echo '@here|{"parse":["everyone"]}' ;; everyone) echo '@everyone|{"parse":["everyone"]}' ;; none) echo 'null|{"parse":[]}' ;; esac)" \
            "$(jq -r '"\(.payload.content // "null")|\(.payload.allowed_mentions | tojson)"' <<< "$CST_BODY")"
        cst_call admin POST /crowdsec/notifications/test "{\"sample\":\"ssh\",\"settings\":{\"mention\":{\"mode\":\"$i\"$tok,\"text\":\"\"}}}"
        check "notify/mention $i: a test message pings nobody" '[null,{"parse":[]}]' "$(cst_disc_last | jq -c '[.content, .allowed_mentions]')"
    done

    # -- what Discord says back
    for i in 429 400 404 500; do
        echo "$i" > "$CST/discord.status"
        cst_call admin POST /crowdsec/notifications/test '{"sample":"probe"}'
        cst_j "notify/test: Discord answers $i" '.success' false '.delivered' false '.http' "$i" '.message | length > 20' true
    done
    cst_call admin POST /crowdsec/notifications/test '{"sample":"probe"}'
    echo 429 > "$CST/discord.status"; cst_call admin POST /crowdsec/notifications/test '{"sample":"probe"}'
    cst_t "notify/test: a rate limit says when to try again" '.message | test("2.5")'
    rm -f "$CST/discord.status"
    cst_call admin GET /crowdsec/notifications
    cst_j "notify/test: the last outcome is remembered" '.status.last_test.ok' false '.status.last_test.http' 429 '.status.last_test.sample' probe
    mv "$CST/discord.port" "$CST/discord.port.off"
    cst_call admin POST /crowdsec/notifications/test '{"sample":"probe"}'
    mv "$CST/discord.port.off" "$CST/discord.port"
    cst_j "notify/test: nobody answers" '.success' false '.http' 0 '.message | test("reach")' true
    cst_call admin POST /crowdsec/notifications/test '{"sample":"exploit","webhook_url":"https://discord.com/api/webhooks/222222222222222222/AnotherFakeTokenForTheTests00"}'
    check "notify/test: a webhook typed in the form is tried without being saved" "/api/webhooks/222222222222222222/AnotherFakeTokenForTheTests00 custom" \
        "$(tail -n 1 "$CST/discord.log" | jq -r .path) $(jq -r '.settings.webhook.mode' <<< "$(cst_call admin GET /crowdsec/notifications; echo "$CST_BODY")")"
    local -a tbad=('{"sample":"nope"}' '{"sample":"probe;id"}' '{"webhook_url":"http://discord.com/api/webhooks/222222222222222222/AnotherFakeTokenForTheTests00"}' '{"webhook_url":"https://evil.example/api/webhooks/222222222222222222/AnotherFakeTokenForTheTests00"}'
                   '{"settings":{"message":{"title":"{bogus}"}}}' '{"settings":"x"}')
    n0=$(cst_disc_n)
    for i in "${!tbad[@]}"; do cst_q "tb$i" admin POST /crowdsec/notifications/test "${tbad[$i]}"; done
    cst_q tbviewer viewer POST /crowdsec/notifications/test '{}'
    cst_q tbnobody none POST /crowdsec/notifications/test '{}'
    cst_run
    for i in "${!tbad[@]}"; do cst_use "tb$i"; cst_is "notify/test: ${tbad[$i]} is refused" 400; done
    cst_use tbviewer; cst_is "notify/test: a viewer may not" 403
    cst_use tbnobody; cst_is "notify/test: nobody may not" 401
    check "notify/test: …and nothing was sent" "$n0" "$(cst_disc_n)"
    check "notify/test: the tests are in the audit log" yes "$([[ "$(cst_audit_n '"action":"auth.crowdsec_notify_test"')" -ge 10 ]] && echo yes || echo no)"

    # -- back to the message CrowdSec ships with: the webhook and the switch stay
    cst_call admin POST /crowdsec/notifications/reset
    cst_is "notify/reset" 200
    cst_j "notify/reset" '.settings.message == .defaults.message' true '.settings.identity == .defaults.identity' true '.settings.mention == .defaults.mention' true '.settings.filters == .defaults.filters' true \
        '.settings.events == .defaults.events' true '.settings.delivery == .defaults.delivery' true '.settings.embed == .defaults.embed' true '.settings.enabled' true '.settings.webhook.mode' custom '.webhook.configured' true \
        '.state.working' true
    check "notify/reset: the plugin file is the default again" "true" "$(python3 "$CST/tplscan.py" < "$http" | jq -c --slurpfile b "$CST/base-scan.json" '(.tokens - $b[0].tokens | length) == 0')"
    check "notify/reset: …down to the last byte, except for the time and the backups" "$(grep -v '^#' "$CST/base-http.yaml" | md5sum)" "$(grep -v '^#' "$http" | md5sum)"
    check "notify/reset: the detection-only profile is gone" 0 "$(grep -c 'dcs_notify_detect_only' "$live")"
    cst_call viewer POST /crowdsec/notifications/reset
    cst_is "notify/reset: a viewer may not" 403

    # -- off, and on again without a webhook to go to
    cst_call admin PUT /crowdsec/notifications '{"settings":{"enabled":false}}'
    cst_j "notify/off" '.settings.enabled' false '.state.wired' false '.state.working' false '.webhook.configured' true
    check "notify/off: the profiles no longer name the plugin" 0 "$(grep -c '^  - http_default' "$live")"
    cst_call admin PUT /crowdsec/notifications '{"clear_custom_webhook":true,"settings":{"enabled":true}}'
    cst_is "notify/on: with the webhook removed and no other" 400
    check "notify/on: …the removal was undone (it did not take effect)" 1 "$(cst_secrets_n CROWDSEC_DISCORD_WEBHOOK.enc)"
    cst_call admin PUT /crowdsec/notifications '{"clear_custom_webhook":true,"settings":{"enabled":false}}'
    cst_j "notify/off: the webhook can be removed while it is off" '.webhook.configured' false '.webhook.sources.custom.configured' false
    check "notify/off: …its secret is gone" 0 "$(cst_secrets_n CROWDSEC_DISCORD_WEBHOOK.enc)"
    cst_call admin POST /crowdsec/notifications/test '{}'
    cst_is "notify/test: with nowhere to post" 400
    check "notify: every change is in the audit log" yes "$([[ "$(cst_audit_n '"action":"auth.crowdsec_notify"')" -ge 4 ]] && echo yes || echo no)"
}

cst_notify_takeover() {
    local live http mine hw
    live=$(CST_LIVE profiles.yaml); http=$(CST_LIVE notifications/http.yaml)
    # -- a Discord file somebody wrote by hand: it is replaced (its webhook kept), and the old one is kept in the backups
    cst_world data traefik --traefik
    hw=$'type: http\nname: http_default\nlog_level: info\nformat: |\n  {"content": "hand-written"}\nurl: https://discord.com/api/webhooks/333333333333333333/HandWrittenFakeTokenForTests0000\nmethod: POST'
    printf '%s\n' "$hw" > "$http"
    cst_call admin GET /crowdsec/notifications
    cst_j "notify/hand-written" '.state.file' other '.settings.webhook.mode' keep '.webhook.sources.keep.configured' true '.webhook.masked' 'https://discord.com/api/webhooks/333333333333333333/••••0000'
    cst_call admin PUT /crowdsec/notifications '{"settings":{"enabled":true}}'
    cst_is "notify/hand-written: saving over it" 200
    cst_j "notify/hand-written" '.state.file' dcs '.settings.webhook.mode' keep '.state.working' true
    check "notify/hand-written: the webhook it had is the one used now" 1 "$(grep -cF 'url: https://discord.com/api/webhooks/333333333333333333/HandWrittenFakeTokenForTests0000' "$http")"
    check "notify/hand-written: the old file is in the backups, byte for byte" "$hw" "$(cat "$CST/.data/crowdsec/backups/"http-*.yaml)"
    check "notify/hand-written: the webhook was not stored as a secret of DCS" 0 "$(cst_secrets_n 'CROWDSEC*')"
    # -- profiles nobody at DCS wrote: the person has to say yes
    cst_world data traefik --traefik
    mine=$'name: my_own\nfilters:\n  - Alert.Remediation == true\ndecisions:\n  - type: captcha\n    duration: 1h\non_success: break'
    printf '%s\n' "$mine" > "$live"
    cst_call admin GET /crowdsec/notifications
    cst_is "notify/custom profiles: the settings can still be read" 200
    cst_j "notify/custom profiles" '.state.profile_mode' custom '.state.wired' false
    cst_call admin PUT /crowdsec/notifications "{\"webhook_url\":\"$CST_HOOK\",\"settings\":{\"enabled\":true}}"
    cst_is "notify/custom profiles: saving needs a yes" 409
    cst_j "notify/custom profiles" '.reason' custom_profile
    check "notify/custom profiles: nothing was written, the webhook was not kept" "$mine 0" "$(cat "$live") $(cst_secrets_n 'CROWDSEC*')"
    cst_call admin PUT /crowdsec/notifications "{\"webhook_url\":\"$CST_HOOK\",\"settings\":{\"enabled\":true},\"take_over\":true}"
    cst_is "notify/custom profiles: with take_over" 200
    cst_j "notify/custom profiles" '.state.profile_mode' dcs '.state.working' true
    check "notify/custom profiles: …the old profiles are in the backups" "$mine" "$(cat "$CST/.data/crowdsec/backups/"profiles-*.yaml)"
    cst_call admin POST /crowdsec/notifications/reset
    cst_is "notify/reset: over profiles DCS wrote" 200
    cst_world data traefik --traefik
    printf '%s\n' "$mine" > "$live"
    cst_call admin POST /crowdsec/notifications/reset
    cst_is "notify/reset: over profiles nobody at DCS wrote" 409
    cst_j "notify/reset: …it says why" '.reason' custom_profile
    for i in '{"take_over":"yes"}' '{"take_over":false}' '{"take_over":1}' 'nope' '[]'; do
        cst_call admin POST /crowdsec/notifications/reset "$i"
        cst_is "notify/reset: $i is not a yes" 409
    done
    check "notify/reset: …nothing was written" "$mine" "$(cat "$live")"
    cst_call admin POST /crowdsec/notifications/reset '{"take_over":true}'
    cst_is "notify/reset: with take_over" 200
    cst_call admin GET /crowdsec/notifications
    cst_j "notify/reset: …the profiles are DCS's now" '.state.profile_mode' dcs
    check "notify/reset: …the old profiles are in the backups" "$mine" "$(cat "$CST/.data/crowdsec/backups/"profiles-*.yaml)"
    cst_call viewer POST /crowdsec/notifications/reset '{"take_over":true}'
    cst_is "notify/reset: a viewer may not, take_over or not" 403
}

# a failed post quotes the address it tried, and the token in it is a secret
cst_notify_errors() {
    local tok1="NOTAREALTOKEN_0123456789-abcdefghij" tok2="Another.Fake~Token-For_Tests00" s="$CST/fake/state.json" now l1 l2 l3
    cst_world data traefik --traefik
    cst_mock --mock-set discord=1
    now=$(date +%s)
    l1='time="2026-09-29T22:00:00Z" level=warning msg="notify attempt failed: rpc error: code = Unknown desc = Post \"https://discord.com/api/webhooks/111111111111111111/'"$tok1"'\": dial tcp: lookup discord.com: no such host" attempt=1 next=2s plugin=http_default'
    l2='time="2026-09-29T22:00:07Z" level=error msg="delivery failed after retries: rpc error: code = Unknown desc = Post \"https://discord.com/api/webhooks/111111111111111111/'"$tok1"'\": dial tcp: lookup discord.com: no such host" plugin=http_default'
    l3='time="2026-09-29T22:00:09Z" level=warning msg="notify attempt failed: rpc error: code = Unknown desc = Post \"https://discordapp.com/api/webhooks/222222222222222222/'"$tok2"'?wait=true\": context deadline exceeded" attempt=2 next=4s plugin=http_default'
    jq --arg a "$l1" --arg b "$l2" --arg c "$l3" --argjson t "$now" '.logs += [[$t - 120, 2, $a], [$t - 60, 2, $b], [$t - 30, 2, $c]]' "$s" > "$s.new" && mv -f "$s.new" "$s"
    cst_uncache
    cst_call admin GET /crowdsec/notifications
    cst_is "notify/errors: a delivery that failed" 200
    cst_j "notify/errors: the failures are listed, the newest first" '.status.delivery_errors | length' 3 '.status.delivery_errors | map(.time) | join(",")' '2026-09-29T22:00:09Z,2026-09-29T22:00:07Z,2026-09-29T22:00:00Z'
    cst_t "notify/errors: …what was tried is said, without the token" '.status.delivery_errors | all(.message | test("/api/webhooks/[0-9]+/••••"))'
    check "notify/errors: …no token is anywhere in the answer" "0 0" "$(grep -cF -- "$tok1" <<< "$CST_BODY") $(grep -cF -- "$tok2" <<< "$CST_BODY")"
    cst_t "notify/errors: …the rest of the address stays (the query)" '.status.delivery_errors[0].message | test("/api/webhooks/222222222222222222/••••\\?wait=true")'
    cst_call viewer GET /crowdsec/notifications
    check "notify/errors: a viewer sees the same, without the tokens" "3 0 0" "$(jq -r '.status.delivery_errors | length' <<< "$CST_BODY") $(grep -cF -- "$tok1" <<< "$CST_BODY") $(grep -cF -- "$tok2" <<< "$CST_BODY")"
    cst_call admin GET /crowdsec/status
    check "notify/errors: nor is a token in the status" "0 0" "$(grep -cF -- "$tok1" <<< "$CST_BODY") $(grep -cF -- "$tok2" <<< "$CST_BODY")"
}

# the text a template is made of when people type these into the message: none of it may become code
cst_notify_safety() {
    local http live i n
    http=$(CST_LIVE notifications/http.yaml); live=$(CST_LIVE profiles.yaml)
    cst_world data traefik --traefik
    : > "$CST/discord.log"
    # -- through the whole pipeline, as far as the stand-in's template check allows (it stops at the first }} it sees, even inside a string: those are read below)
    cst_call admin PUT /crowdsec/notifications "{\"webhook_url\":\"$CST_HOOK\",\"settings\":{\"enabled\":true}}"
    python3 "$CST/tplscan.py" < "$http" > "$CST/base-scan.json"
    cst_call admin PUT /crowdsec/notifications "$(jq -nc --arg p "$CST_PWN" '{settings: {
        identity: {name: "Guard \"1\" \\ $(id) `id`"},
        message: {title: "\"q\" \\ $(touch \($p)) `touch \($p)` ; && | {{ .Nope {x {{ end {{ define \"x\"",
                  description: "line \"one\"\nurl: http://evil.example\n- name: evil\n{{ printf \"%s\" .Nope $(touch \($p))\n\\n \\\\ \\\"",
                  footer: "$(touch \($p)) \\ \" ` {domain}", link: "{cti_url}?a=\"b\"&c=$(id)",
                  fields: [{name: "n \"q\" $(id)", value: "v `id` \\ \"x\"\n{{ .Nope", inline: true}, {name: "{ip}", value: "{{ .Source.Value", inline: false}]},
        mention: {mode: "none", id: "", text: "$(touch \($p)) \"x\" \\ `y`\nsecond line"}}}')"
    cst_is "notify/safety: text full of quotes, backslashes, substitutions and template code is just text" 200
    python3 "$CST/tplscan.py" < "$http" > "$CST/scan.json"
    check "notify/safety: the template is made of the same tokens as the default one" "0 [] $(jq -r '.top | join(",")' "$CST/base-scan.json")" \
        "$(jq -r --slurpfile b "$CST/base-scan.json" '"\(.tokens - $b[0].tokens | length) \(.bad | tojson) \(.top | join(","))"' "$CST/scan.json")"
    check "notify/safety: nothing was run, nothing was created" "no no" "$([[ -e "$CST_PWN" ]] && echo yes || echo no) $([[ -n "$(find "$CST" "$CST/fake/rootfs" -maxdepth 1 -name 'pwn*' 2>/dev/null)" ]] && echo yes || echo no)"
    check "notify/safety: the file has no line of its own from the text (a key, a comment)" 0 "$(grep -c '^\(url: http://evil\|- name: evil\)' "$http")"
    check "notify/safety: …one url line, the webhook" "url: $CST_HOOK" "$(grep '^url:' "$http")"
    check "notify/safety: the header is one line of JSON that holds exactly what was typed" "yes" "$(sed -n 2p "$http" | sed 's/^# dcs-notify: //' | jq -e '.settings.message.description | startswith("line \"one\"\nurl: http://evil.example\n- name: evil")' >/dev/null 2>&1 && echo yes || echo no)"
    check "notify/safety: …and no line of the file starts with the typed text" 0 "$(grep -c '^\(line "one"\|v `id`\)' "$http")"
    cst_call admin GET /crowdsec/notifications
    cst_j "notify/safety: the text comes back as typed" '.settings.message.footer' '$(touch '"$CST_PWN"') \ " ` {domain}' '.settings.message.fields[0].name' 'n "q" $(id)' '.settings.mention.text' $'$(touch '"$CST_PWN"$') "x" \\ `y`\nsecond line'
    cst_call admin POST /crowdsec/notifications/test '{"sample":"probe","include_mention":true}'
    cst_is "notify/safety: the message is sent" 200
    check "notify/safety: …and is valid JSON with the text in it" "yes" "$(cst_disc_last | jq -e '.embeds[0].footer.text | startswith("$(touch")' >/dev/null 2>&1 && echo yes || echo no)"
    check "notify/safety: …still nothing created" no "$([[ -e "$CST_PWN" ]] && echo yes || echo no)"
    # -- unicode
    cst_call admin PUT /crowdsec/notifications "$(jq -nc '{settings: {message: {title: "🛡️ Überfall — 攻撃 ‮rtl​zero-width́", description: "日本語\nעברית\n👨‍👩‍👧 ⚠️", footer: "©®™ ñ", fields: [{name: "ключ", value: "значение", inline: true}]}, identity: {name: "Wächter 🛡️"}}}')"
    cst_is "notify/safety: letters of every kind" 200
    python3 "$CST/tplscan.py" < "$http" > "$CST/scan.json"
    check "notify/safety: …make the same template tokens" "0 []" "$(jq -r --slurpfile b "$CST/base-scan.json" '"\(.tokens - $b[0].tokens | length) \(.bad | tojson)"' "$CST/scan.json")"
    cst_call admin GET /crowdsec/notifications
    cst_j "notify/safety: …and come back the way they went in" '.settings.message.title' $'🛡️ Überfall — 攻撃 ‮rtl​zero-width́' '.settings.identity.name' 'Wächter 🛡️' '.settings.message.description' $'日本語\nעברית\n👨‍👩‍👧 ⚠️'
    cst_call admin POST /crowdsec/notifications/test '{"sample":"ssh"}'
    check "notify/safety: …and the message is valid JSON" yes "$(cst_disc_last | jq -e '.username == "Wächter 🛡️"' >/dev/null 2>&1 && echo yes || echo no)"
}

# the same, for strings the stand-in's simplified template check cannot take (a "}}" inside a string): the template is generated and read, not run
cst_notify_template() {
    local out

    out=$( (
        set +u
        export BASE_DIR="$CST" CROWDSEC_STATE_DIR="$CST/.data/crowdsec" COMPOSE_DIR="$CST/Stacks" TEMPLATES_DIR="$CST/.templates"
        # shellcheck disable=SC1091
        source "$CST/.lib/crowdsec.sh" >/dev/null 2>&1; source "$CST/.lib/crowdsec-config.sh" >/dev/null 2>&1
        scan() { python3 "$CST/tplscan.py" <<< "$(_cs_notify_render_yaml "$1" "https://discord.com/api/webhooks/1/x" 2>/dev/null)"; }
        _cs_notify_validate "$_CS_NOTIFY_DEFAULTS" || exit 3
        base=$(scan "$CS_OUT" | jq -c .tokens)
        i=0
        while IFS= read -r str; do
            i=$(( i + 1 ))
            for field in title footer link description; do
                s=$(jq -c --arg s "$str" --arg f "$field" '.message[$f] = $s' <<< "$_CS_NOTIFY_DEFAULTS")
                _cs_notify_validate "$s" || { printf '%s %s refused\n' "$i" "$field"; continue; }
                res=$(scan "$CS_OUT")
                printf '%s %s %s\n' "$i" "$field" "$(jq -r --argjson b "$base" '"\(.tokens - $b | length) \(.bad | length) \(.top | length)"' <<< "$res")"
            done
            s=$(jq -c --arg s "$str" '.message.fields = [{name: $s, value: $s, inline: false}] | .identity.name = ("G" + $s) | .mention = {mode: "here", id: "", text: $s}' <<< "$_CS_NOTIFY_DEFAULTS")
            _cs_notify_validate "$s" || { printf '%s fields refused\n' "$i"; continue; }
            res=$(scan "$CS_OUT")
            printf '%s fields %s\n' "$i" "$(jq -r --argjson b "$base" '"\(.tokens - $b | length) \(.bad | length) \(.top | length)"' <<< "$res")"
        done <<'STRINGS'
"; touch /tmp/x; "
\
\\
\"
{{ .Nope }}
{{end}}{{define "x"}}
}} {{
}}
{{
{{-
-}}
{{/* comment
`touch x`
$(touch x)
${IFS}
%s %d %!
'; DROP TABLE x; --
{
}
{ip
ip}
{{ip}}
{ip}{ip}{
{{{{ .Nope }}}}
🛡️ Überfall 攻撃 ‮rtl
a b
line separator
STRINGS
    ) 2>&1 )
    check "notify/template: every string of the list was read" yes "$([[ "$(grep -c . <<< "$out")" -ge 100 ]] && echo yes || echo "no ($(grep -c . <<< "$out") lines)")"
    check "notify/template: none of them adds a token, breaks a string across lines, or adds a file key" 0 "$(grep -vE ' 0 0 11$| refused$' <<< "$out" | grep -c .)"
    [[ -z "$(grep -vE ' 0 0 11$| refused$' <<< "$out")" ]] || printf '        %s\n' "$(grep -vE ' 0 0 11$| refused$' <<< "$out" | head -n 5)"
}

cst_notify_golden() {
    local out
    out=$( (
        set +u
        export BASE_DIR="$CST" CROWDSEC_STATE_DIR="$CST/.data/crowdsec" COMPOSE_DIR="$CST/Stacks" TEMPLATES_DIR="$CST/.templates"
        # shellcheck disable=SC1091
        source "$CST/.lib/crowdsec.sh" >/dev/null 2>&1; source "$CST/.lib/crowdsec-config.sh" >/dev/null 2>&1
        _cs_notify_validate "$_CS_NOTIFY_DEFAULTS" || exit 3
        CS_RENDER_DOMAIN=lab.example.com CS_RENDER_SERVER=srv CS_RENDER_NOW=1790000000 \
            _cs_notify_render_payload "$CS_OUT" '{"id":0,"scenario":"test alert","message":"test alert","events_count":1,"machine_id":"","kind":"","simulated":false,"source":{"scope":"Ip","value":"10.10.10.10","ip":"10.10.10.10","range":"","cn":"","as_number":"","as_name":""},"decisions":[{"type":"ban","duration":"4h","origin":"cscli","simulated":false}],"events":[]}' | jq -cS .
    ) 2>/dev/null )
    check "notify/golden: the default message, rendered by DCS, is the one the shipped template makes in CrowdSec (JSON keys in any order)" "$(jq -cS . <<< "$CST_GOLDEN")" "$out"
}

cst_part_notify() {
    echo "CrowdSec page: the Discord messages"
    cst_notify_read
    cst_notify_validation
    cst_notify_apply
    cst_notify_takeover
    cst_notify_errors
    cst_notify_safety
    cst_notify_template
    cst_notify_golden
    cst_notify_redeploy
}

# the deploy of the crowdsec template puts its own profiles.yaml and Discord file into CrowdSec; when the page manages those files it leaves them alone
cst_deploy() {   # cst_deploy 'VARIABLES' — the hook that runs after a template deploy, against the stand-in; its own log is $CST/deploy.log
    local vars="$1"
    : > "$CST/deploy.log"
    ( set --; export PATH="$CST/bin:$PATH" DOCKER_COMPOSE_CMD="docker compose" API_RATE_LIMIT=0; [[ -z "$CST_LOC" ]] || export LC_ALL="$CST_LOC"
      # shellcheck disable=SC1090
      source "$CST_API" >/dev/null 2>&1
      _crowdsec_post_deploy "$CST/.templates/crowdsec" networking-security "$CST/Stacks/networking-security" "$vars" "$CST/deploy.log" ) >/dev/null 2>"$CST/deploy.err"
}

cst_notify_redeploy() {
    local live http h0 p0 vars
    live=$(CST_LIVE profiles.yaml); http=$(CST_LIVE notifications/http.yaml)
    vars="DISCORD_WEBHOOK_URL=$CST_HOOK"$'\n'"ENABLE_TRAEFIK_BOUNCER=true"
    # -- a fresh install: the shipped profiles and Discord file go in, with the webhook and the domain
    cst_world data traefik --traefik
    cst_deploy "$vars"
    check "redeploy/fresh: the shipped Discord file is put in, with the webhook and the domain" "1 1 0" "$(grep -cF -- "$CST_HOOK" "$http") $(grep -c 'lab.example.test' "$http") $(grep -c '__WEBHOOK__\|__DOMAIN__' "$http")"
    check "redeploy/fresh: …and the shipped profiles, that send every decision to it" "yes" "$(grep -q 'http_default' "$live" && ! grep -q '^# Managed by DCS' "$live" && echo yes || echo no)"
    check "redeploy/fresh: it says so in its log" "yes" "$(grep -q 'alerts go to Discord' "$CST/deploy.log" && echo yes || echo no)"
    check "redeploy/fresh: the Traefik bouncer is registered" "yes" "$(grep -q 'bouncer registered' "$CST/deploy.log" && echo yes || echo no)"
    # -- no webhook known: the two files stay as they are
    cst_world data traefik --traefik
    h0=$(cat "$http"); p0=$(cat "$live")
    cst_deploy "ENABLE_TRAEFIK_BOUNCER=false"
    check "redeploy/no webhook: the files stay as they were" "$h0 $p0" "$(cat "$http") $(cat "$live")"
    # -- files the page wrote are the person's settings: a re-deploy keeps them
    cst_world data traefik --traefik
    cst_call admin PUT /crowdsec/notifications "{\"webhook_url\":\"$CST_HOOK\",\"settings\":{\"enabled\":true,\"identity\":{\"name\":\"Door Guard\"},\"message\":{\"title\":\"Mine: {label}\"}}}"
    cst_call admin PUT /crowdsec/settings '{"profile":{"duration":"7h"}}'
    cst_is "redeploy/managed: the page's settings are saved" 200
    h0=$(cat "$http"); p0=$(cat "$live")
    cst_deploy "DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/222222222222222222/AnotherFakeTokenForTheTests00"$'\n'"ENABLE_TRAEFIK_BOUNCER=true"
    check "redeploy/managed: both files are byte for byte what the page wrote" "$h0 $p0" "$(cat "$http") $(cat "$live")"
    check "redeploy/managed: …and the deploy says why it left them" "yes" "$(grep -q 'managed on the CrowdSec page' "$CST/deploy.log" && echo yes || echo no)"
    check "redeploy/managed: the message is still the person's" "Mine: {label}" "$(sed -n 2p "$http" | sed 's/^# dcs-notify: //' | jq -r '.settings.message.title')"
    # -- one of the two is enough
    cst_world data traefik --traefik
    cst_call admin PUT /crowdsec/settings '{"profile":{"duration":"7h"}}'
    h0=$(cat "$http"); p0=$(cat "$live")
    cst_deploy "$vars"
    check "redeploy/managed profiles only: the Discord file is left alone too" "$h0 $p0" "$(cat "$http") $(cat "$live")"
    cst_world data traefik --traefik
    cst_call admin PUT /crowdsec/notifications "{\"webhook_url\":\"$CST_HOOK\",\"settings\":{\"enabled\":false}}"
    h0=$(cat "$http"); p0=$(cat "$live")
    cst_deploy "$vars"
    check "redeploy/managed Discord file only: the profiles are left alone too" "$h0 $p0" "$(cat "$http") $(cat "$live")"
}

# ---- who may do what, what is written down, and what happens to hostile text --------------------------------------------------------

# the routes of the CrowdSec page: METHOD PATH BODY, and whether a viewer may use it
CST_READS=(
    'GET /crowdsec/status' 'GET /crowdsec/decisions' 'GET /crowdsec/decisions/export' 'GET /crowdsec/alerts' 'GET /crowdsec/alerts/10' 'GET /crowdsec/allowlist' 'GET /crowdsec/bouncers'
    'GET /crowdsec/machines' 'GET /crowdsec/metrics' 'GET /crowdsec/hub' 'GET /crowdsec/logs' 'GET /crowdsec/simulation' 'GET /crowdsec/community' 'GET /crowdsec/settings' 'GET /crowdsec/notifications'
    'GET /crowdsec/plugin' 'GET /routes'
)
CST_WRITES=(
    'POST /crowdsec/decisions {"value":"198.18.9.9"}' 'POST /crowdsec/decisions/delete {"values":["198.18.9.9"]}' 'POST /crowdsec/decisions/import {"format":"values","content":"198.18.9.9"}'
    'DELETE /crowdsec/decisions/198.18.9.9 -' 'POST /crowdsec/allowlist {"value":"198.18.9.9"}' 'DELETE /crowdsec/allowlist/198.18.9.9 -' 'POST /crowdsec/bouncers {"name":"x-bouncer"}'
    'DELETE /crowdsec/bouncers/x-bouncer -' 'POST /crowdsec/bouncers/register-traefik -' 'POST /crowdsec/service {"action":"reload"}' 'POST /crowdsec/hub/update -' 'POST /crowdsec/hub/upgrade -'
    'POST /crowdsec/hub/install {"type":"collections","name":"crowdsecurity/nginx"}' 'POST /crowdsec/hub/remove {"type":"collections","name":"crowdsecurity/nginx"}'
    'POST /crowdsec/simulation {"scenario":"crowdsecurity/ssh-bf","enabled":true}' 'PUT /crowdsec/settings {"profile":{"duration":"5h"}}' 'PUT /crowdsec/notifications {"settings":{"enabled":false}}'
    'POST /crowdsec/notifications {"webhook":"https://discord.com/api/webhooks/111111111111111111/NOTAREALTOKEN_0123456789-abcdefghij"}'
    'POST /crowdsec/notifications/test {}' 'POST /crowdsec/notifications/reset -' 'POST /crowdsec/trust {"ip":"198.18.9.9"}' 'DELETE /crowdsec/trust/198.18.9.9 -'
    'PUT /crowdsec/plugin {"settings":{"mode":"stream"}}' 'POST /crowdsec/traefik/restart -' 'POST /fleet/routes {"http":{"routers":{}}}'
)

cst_security_roles() {
    local i entry m p b a0
    cst_world data traefik --traefik
    a0=$(cst_audit_n '"action":"auth.crowdsec_')
    for i in "${!CST_READS[@]}"; do
        read -r m p <<< "${CST_READS[$i]}"
        cst_q "rn$i" none "$m" "$p"
        cst_q "rv$i" viewer "$m" "$p"
        cst_q "ra$i" admin "$m" "$p"
    done
    for i in "${!CST_WRITES[@]}"; do
        read -r m p b <<< "${CST_WRITES[$i]}"; [[ "$b" != - ]] || b=""
        cst_q "wn$i" none "$m" "$p" "$b"
        cst_q "wv$i" viewer "$m" "$p" "$b"
    done
    cst_q unbanme-v viewer POST /crowdsec/unban-me
    cst_q pv-none none POST /crowdsec/notifications/preview '{}'
    cst_q pv-viewer viewer POST /crowdsec/notifications/preview '{}'
    cst_run
    for i in "${!CST_READS[@]}"; do
        entry="${CST_READS[$i]}"
        cst_use "rn$i"; cst_is "security: nobody may not ${entry}" 401
        cst_use "rv$i"; cst_is "security: a viewer may ${entry}" 200
        cst_use "ra$i"; cst_is "security: an admin may ${entry}" 200
    done
    for i in "${!CST_WRITES[@]}"; do
        entry="${CST_WRITES[$i]%% \{*}"; entry="${entry% -}"
        cst_use "wn$i"; cst_is "security: nobody may not ${entry}" 401
        cst_use "wv$i"; cst_is "security: a viewer may not ${entry}" 403
    done
    cst_use unbanme-v; cst_is "security: a viewer may ask to lift its own ban (unban-me: the role check lets it through; 400 as this caller has no public address)" 400
    cst_use pv-none; cst_is "security: nobody may not POST /crowdsec/notifications/preview" 401
    cst_use pv-viewer; cst_is "security: a viewer may draw the Discord preview (POST /crowdsec/notifications/preview: it only renders)" 200
    cst_j "security: …and what it draws holds no webhook address" '(tostring | test("api/webhooks"))' false
    # the audit log holds nobody's refused attempt, and the session is not needed to be told twice
    check "security: refused requests left no CrowdSec line in the audit log" "$a0" "$(cst_audit_n '"action":"auth.crowdsec_')"
    # -- a bot account (the Discord bot): reads, lifts bans, nothing else
    cst_call admin POST /auth/users '{"username":"botty","password":"Botpass-1234","role":"bot"}'
    cst_call none POST /auth/login '{"username":"botty","password":"Botpass-1234"}'
    local bot_token vwr_saved
    bot_token=$(jq -r '.token // empty' <<< "$CST_BODY")
    if [[ -n "$bot_token" ]]; then
        vwr_saved="$CST_VWR"; CST_VWR="$bot_token"
        cst_try "security: a bot may read the status" 200 viewer GET /crowdsec/status
        cst_try "security: a bot may read the bans" 200 viewer GET /crowdsec/decisions
        cst_try "security: a bot may lift a ban" 200 viewer DELETE /crowdsec/decisions/91.240.118.11
        cst_try "security: a bot may not ban" 403 viewer POST /crowdsec/decisions '{"value":"198.18.9.9"}'
        cst_try "security: a bot may not lift many at once" 403 viewer POST /crowdsec/decisions/delete '{"values":["198.18.9.9"]}'
        cst_try "security: a bot may not change the profile" 403 viewer PUT /crowdsec/settings '{"profile":{"duration":"5h"}}'
        cst_try "security: a bot may not restart CrowdSec" 403 viewer POST /crowdsec/service '{"action":"restart"}'
        cst_try "security: a bot may read the Traefik plugin's settings and the routes" 200 viewer GET /crowdsec/plugin
        cst_try "security: …and the routes" 200 viewer GET /routes
        cst_try "security: a bot may not change the plugin's settings" 403 viewer PUT /crowdsec/plugin '{"settings":{"mode":"stream"}}'
        cst_try "security: a bot may not restart Traefik" 403 viewer POST /crowdsec/traefik/restart
        cst_try "security: a bot may not draw the Discord preview" 403 viewer POST /crowdsec/notifications/preview '{}'
        CST_VWR="$vwr_saved"
    else
        check "security: a bot account can be made" yes no
    fi
    # -- routes that are not there
    cst_q nr1 admin GET /crowdsec/nope
    cst_q nr2 admin POST /crowdsec/status '{}'
    cst_q nr3 admin DELETE /crowdsec/status
    cst_q nr4 admin PUT /crowdsec/decisions '{}'
    cst_q nr5 admin GET /CROWDSEC/status
    cst_q nr6 admin GET /crowdsec/status/
    cst_q nr7 admin GET '/crowdsec/status?x=1'
    cst_q nr8 admin TRACE /crowdsec/status
    cst_q nr9 admin GET /crowdsec/hub/install
    cst_q nr10 admin GET /crowdsec/bouncers/x
    cst_q nr11 admin GET '/crowdsec/status?a=1&&b=2'
    cst_q nr12 admin GET '/crowdsec/decisions?&'
    cst_q nr13 admin GET '/crowdsec/decisions?=x&limit=1'
    cst_q nr14 admin GET '/crowdsec/alerts?limit=1&'
    cst_q nr15 admin GET '/crowdsec/decisions?limit'
    cst_run
    cst_use nr1; cst_is "security: an unknown CrowdSec route" 404
    cst_use nr2; cst_is "security: POST on a read-only route" 404
    cst_use nr3; cst_is "security: DELETE on a read-only route" 404
    cst_use nr4; cst_is "security: PUT on the ban route" 404
    cst_use nr5; cst_is "security: paths are case sensitive" 404
    cst_use nr6; cst_is "security: a slash at the end is ignored" 200
    cst_use nr7; cst_is "security: unknown query keys are ignored" 200
    cst_use nr8; cst_is "security: TRACE" 405
    cst_use nr9; cst_is "security: GET on an action route" 404
    cst_use nr10; cst_is "security: GET on a bouncer" 404
    cst_use nr11; cst_is "security: an empty pair in the query (a=1&&b=2) is skipped" 200
    cst_use nr12; cst_is "security: a query that is only an ampersand" 200
    cst_use nr13; cst_is "security: a parameter without a name" 200
    cst_use nr14; cst_is "security: a query that ends with an ampersand" 200
    cst_use nr15; cst_is "security: a name without a value is an empty value (limit= is not a number)" 400
}

# every mutation is written down, with who did it and from where
cst_security_audit() {
    local a
    cst_world data traefik --traefik
    printf '{"public_ip":"198.51.100.77"}\n' > "$CST/.data/crowdsec-whitelist.json"
    cst_call admin POST /crowdsec/decisions '{"value":"198.18.70.1","duration":"1h","reason":"audit"}' SOCAT_PEERADDR=198.18.7.7
    cst_call admin DELETE /crowdsec/decisions/198.18.70.1 '' SOCAT_PEERADDR=198.18.7.7
    cst_call admin POST /crowdsec/decisions/delete '{"values":["198.18.70.2"]}' SOCAT_PEERADDR=198.18.7.7
    cst_call admin POST /crowdsec/decisions/import '{"format":"values","content":"198.18.70.3"}' SOCAT_PEERADDR=198.18.7.7
    cst_call admin POST /crowdsec/allowlist '{"value":"198.18.70.4"}' SOCAT_PEERADDR=198.18.7.7
    cst_call admin DELETE /crowdsec/allowlist/198.18.70.4 '' SOCAT_PEERADDR=198.18.7.7
    cst_call admin POST /crowdsec/bouncers '{"name":"audit-bouncer"}' SOCAT_PEERADDR=198.18.7.7
    cst_call admin DELETE /crowdsec/bouncers/audit-bouncer '' SOCAT_PEERADDR=198.18.7.7
    cst_call admin POST /crowdsec/service '{"action":"reload"}' SOCAT_PEERADDR=198.18.7.7
    cst_call admin POST /crowdsec/hub/update '' SOCAT_PEERADDR=198.18.7.7
    cst_call admin POST /crowdsec/simulation '{"scenario":"crowdsecurity/ssh-bf","enabled":true}' SOCAT_PEERADDR=198.18.7.7
    cst_call admin PUT /crowdsec/settings '{"profile":{"duration":"5h"}}' SOCAT_PEERADDR=198.18.7.7
    cst_call admin PUT /crowdsec/notifications "{\"webhook_url\":\"$CST_HOOK\",\"settings\":{\"enabled\":true}}" SOCAT_PEERADDR=198.18.7.7
    cst_call admin POST /crowdsec/notifications/test '{"sample":"probe"}' SOCAT_PEERADDR=198.18.7.7
    local -a fr=('ban|198.18.70.1 for 1h: audit' 'unban|198.18.70.1 (' 'unban|bulk: ' 'import|1 of 1 imported' 'allow|198.18.70.4' 'disallow|198.18.70.4' 'bouncer_add|audit-bouncer' 'bouncer_del|audit-bouncer'
                 'service|reload CrowdSec' 'simulation|crowdsecurity/ssh-bf enable' 'settings|ban length 5h' 'notify|on, webhook changed' 'notify_test|probe: HTTP 204' 'hub|update')
    for a in "${fr[@]}"; do
        check "audit: ${a%%|*} (${a#*|}) is written down with the account and the address" 1 "$(grep -c "\"action\":\"auth.crowdsec_${a%%|*}\",\"detail\":\"admin@198.18.7.7 — ${a#*|}" "$CST/.data/audit.jsonl")"
    done
    check "audit: the router writes every request that changes something" "yes" "$([[ "$(grep -c '"action":"auth.\(post\|put\|delete\)","detail":"admin@198.18.7.7 — /crowdsec/' "$CST/.data/audit.jsonl")" -ge 14 ]] && echo yes || echo no)"
    check "audit: every line is JSON" 0 "$(while IFS= read -r a; do jq -e . >/dev/null 2>&1 <<< "$a" || echo bad; done < "$CST/.data/audit.jsonl" | wc -l | tr -d ' ')"
    check "audit: no secret is in it (no webhook token, no bouncer key)" 0 "$(grep -c "$CST_HOOK_TOKEN" "$CST/.data/audit.jsonl")"
    check "audit: …nor in the auth audit log" 0 "$(grep -c "$CST_HOOK_TOKEN" "$CST/.api-auth/auth-audit.log")"
    check "audit: …nor in the API's own log" 0 "$(grep -c "$CST_HOOK_TOKEN" "$CST/logs/api-server.log" 2>/dev/null)"
    check "audit: …nor in what the API wrote to stderr" 0 "$(grep -c "$CST_HOOK_TOKEN" "$CST/api-stderr.log")"
    # text of a ban is one line of the log: a line break in it cannot fake a second entry
    cst_call admin POST /crowdsec/decisions "$(jq -nc '{value: "198.18.70.9", reason: "x\n{\"action\":\"auth.login_ok\",\"detail\":\"fake\"}"}')"
    check "audit: a line break in a reason cannot forge an entry" 0 "$(grep -c '"detail":"fake"' "$CST/.data/audit.jsonl")"
}

# hostile text in every place the page lets a person type or send something
cst_security_injection() {
    local pwn="$CST_PWN" i j slot path body method p mark words want
    local -a desc=() amp=()
    cst_world data traefik --traefik
    rm -f "$pwn"
    mark=$(cst_argv_n)
    # payloads for a path segment or a query value (no spaces: they would end the request line)
    local -a pp=('$(touch${IFS}'"$pwn"')PWNMARK' '`touch${IFS}'"$pwn"'`PWNMARK' ';touch${IFS}'"$pwn"';PWNMARK' '&&touch${IFS}'"$pwn"'PWNMARK' '|touch${IFS}'"$pwn"'PWNMARK'
                 '..%2f..%2fetc%2fpasswdPWNMARK' '../../etc/passwdPWNMARK' '%00PWNMARK' '%0aPWNMARK' '%0d%0aPWNMARK' '$PWNMARK' "$(head -c 300 /dev/zero | tr '\0' A)PWNMARK" '%FF%FEPWNMARK' '%E2%80%AEPWNMARK')
    local -a paths=('DELETE /crowdsec/decisions/@' 'DELETE /crowdsec/allowlist/@' 'DELETE /crowdsec/bouncers/@' 'GET /crowdsec/alerts/@' 'GET /crowdsec/alerts?ip=@' 'GET /crowdsec/alerts?window=@' 'GET /crowdsec/alerts?country=@'
                    'GET /crowdsec/alerts?scenario=@' 'GET /crowdsec/alerts?limit=@' 'GET /crowdsec/alerts?offset=@' 'GET /crowdsec/alerts?simulated=@' 'GET /crowdsec/decisions?scope=@' 'GET /crowdsec/decisions?origin=@'
                    'GET /crowdsec/decisions?type=@' 'GET /crowdsec/decisions?country=@' 'GET /crowdsec/decisions?scenario=@' 'GET /crowdsec/decisions?simulated=@' 'GET /crowdsec/decisions?sort=@' 'GET /crowdsec/decisions?dir=@'
                    'GET /crowdsec/decisions?limit=@' 'GET /crowdsec/decisions?offset=@' 'GET /crowdsec/decisions/export?format=@' 'GET /crowdsec/decisions/export?country=@' 'GET /crowdsec/metrics?window=@'
                    'GET /crowdsec/logs?lines=@' 'GET /crowdsec/logs?level=@' 'GET /crowdsec/logs?lapi=@' 'GET /crowdsec/hub?type=@' 'GET /crowdsec/hub?available=@' 'GET /crowdsec/hub?limit=@')
    j=0
    for i in "${!paths[@]}"; do
        slot="${paths[$i]}"; method="${slot%% *}"; path="${slot#* }"
        for (( p = 0; p < ${#pp[@]}; p++ )); do
            # every payload goes to the first four slots (the ones that name a thing), five of them to each of the others
            (( i < 4 || (p + i) % 3 == 0 )) || continue
            cst_q "p$(( ++j ))" admin "$method" "${path%%@*}${pp[$p]}${path#*@}"; desc[j]="$method ${path%%@*}${pp[$p]:0:40}${path#*@}"; amp[j]="${pp[$p]:0:1}"
        done
    done
    cst_run
    local nbad=0 st
    for (( i = 1; i <= j; i++ )); do
        st="${CST_RST[p$i]}"
        # (a payload that starts with & only ends the parameter before it: what is left of the query is fine, and the rest is a parameter nobody reads)
        [[ "$st" == 400 || "$st" == 404 || ( "${amp[i]}" == '&' && "$st" == 200 ) ]] || { nbad=$(( nbad + 1 )); printf '       (unexpected "%s" for %s)\n' "$st" "${desc[i]}"; }
    done
    check "injection/path: $j hostile path segments and query values are refused (400 or 404)" 0 "$nbad"

    # payloads for a JSON value: whatever a person can type
    local -a jp=('$(touch '"$pwn"') PWNMARK' '`touch '"$pwn"'` PWNMARK' '; touch '"$pwn"' ; PWNMARK' '&& touch '"$pwn"' PWNMARK' '| touch '"$pwn"' PWNMARK' $'x\ntouch '"$pwn"$'\nPWNMARK'
                 '../../etc/passwd PWNMARK' '%2f..%2f PWNMARK' '\u0000PWNMARK' "$(head -c 10000 /dev/zero | tr '\0' A) PWNMARK" '"quoted" \ back PWNMARK' '--help PWNMARK' '-h' '{{ .x }} ${x} PWNMARK')
    # METHOD PATH JQ-BODY (with $p the payload); the answer must be 400, or 200 when the request is a list whose entries are refused one by one
    local -a jslots=(
        'POST /crowdsec/decisions|{value: $p}|400'
        'POST /crowdsec/decisions|{value: "198.18.80.1", duration: $p}|400'
        'POST /crowdsec/decisions/delete|{values: [$p]}|200'
        'POST /crowdsec/decisions/delete|{ids: [$p]}|200'
        'POST /crowdsec/decisions/import|{format: $p, content: "198.18.80.3"}|400'
        'POST /crowdsec/decisions/import|{format: "values", content: "198.18.80.4", duration: $p}|400'
        'POST /crowdsec/decisions/import|{format: "values", content: $p}|200'
        'POST /crowdsec/decisions/import|{format: "csv", content: ("value,reason\n" + $p + ",x")}|200'
        'POST /crowdsec/allowlist|{value: $p}|400'
        'POST /crowdsec/allowlist|{value: "198.18.80.5", expires: $p}|400'
        'POST /crowdsec/bouncers|{name: $p}|400'
        'POST /crowdsec/service|{action: $p}|400'
        'POST /crowdsec/hub/install|{type: "collections", name: $p}|400'
        'POST /crowdsec/hub/install|{type: $p, name: "a/b"}|400'
        'POST /crowdsec/hub/remove|{type: "collections", name: $p}|400'
        'POST /crowdsec/simulation|{scenario: $p, enabled: true}|400'
        'PUT /crowdsec/settings|{profile: {duration: $p}}|400'
        'PUT /crowdsec/settings|{profile: {range_duration: $p}}|400'
        'PUT /crowdsec/settings|{profile: {escalate: {enabled: true, max: $p}}}|400'
        'PUT /crowdsec/settings|{profile: {overrides: [{pattern: $p, duration: "1h"}]}}|400'
        'PUT /crowdsec/settings|{profile: {overrides: [{pattern: "a/b", duration: $p}]}}|400'
        'PUT /crowdsec/settings|{manual_duration: $p}|400'
        'PUT /crowdsec/notifications|{webhook_url: $p}|400'
        'PUT /crowdsec/notifications|{settings: {filters: {only: [$p]}}}|400'
        'PUT /crowdsec/notifications|{settings: {filters: {ignore: [$p]}}}|400'
        'PUT /crowdsec/notifications|{settings: {embed: {color: $p}}}|400'
        'PUT /crowdsec/notifications|{settings: {mention: {mode: "role", id: $p}}}|400'
        'PUT /crowdsec/notifications|{settings: {delivery: {timeout: $p}}}|400'
        'PUT /crowdsec/notifications|{settings: {identity: {avatar_url: $p}}}|400'
        'POST /crowdsec/notifications/test|{sample: $p}|400'
        'POST /crowdsec/notifications/test|{webhook_url: $p}|400'
        'POST /crowdsec/notifications/preview|{sample: $p}|400'
        'POST /crowdsec/notifications/preview|{alert_id: $p}|400'
    )
    j=0
    local -a expect=()
    for i in "${!jslots[@]}"; do
        IFS='|' read -r slot body want <<< "${jslots[$i]}"
        method="${slot%% *}"; path="${slot#* }"
        for (( p = 0; p < ${#jp[@]}; p++ )); do
            (( (p + i) % 3 == 0 )) || continue
            j=$(( j + 1 )); expect[j]="$want"; desc[j]="$method $path $body $p"
            cst_q "j$j" admin "$method" "$path" "$(jq -nc --arg p "${jp[$p]}" "$body")"
        done
    done
    cst_run
    nbad=0
    for (( i = 1; i <= j; i++ )); do
        st="${CST_RST[j$i]}"
        [[ "$st" == "${expect[$i]}" ]] || { nbad=$(( nbad + 1 )); printf '       (unexpected "%s" for %s)\n' "$st" "${desc[i]}"; }
    done
    check "injection/json: $j hostile values in the fields of the page's requests are refused" 0 "$nbad"
    # a body that is not text
    cst_try "injection: a body with bytes that are no UTF-8" 400 admin POST /crowdsec/decisions $'{"value":"\xff\xfe198.18.1.1"}'
    cst_try "injection: …in a list of values" 200 admin POST /crowdsec/decisions/delete $'{"values":["\xff\xfe"]}'
    cst_try "injection: a JSON body nested deep" 400 admin POST /crowdsec/decisions "$(printf '{"value":%s"1"%s}' "$(head -c 500 /dev/zero | tr '\0' '[')" "$(head -c 500 /dev/zero | tr '\0' ']')")"

    check "injection: nothing was run (the file the payloads would have made does not exist)" no "$([[ -e "$pwn" ]] && echo yes || echo no)"
    check "injection: …and no file of that name is anywhere" 0 "$(find "$CST" -name 'pwn*' 2>/dev/null | wc -l | tr -d ' ')"
    check "injection: none of the refused text reached CrowdSec (not one docker call names it)" 0 "$(cst_argv_since "$mark" | grep -c PWNMARK)"
    check "injection: …nor the stand-in's own record" 0 "$(grep -c PWNMARK "$CST/fake/calls.log")"

    # free text is accepted where a person may write a note: it is one argument of the call, never more
    mark=$(cst_argv_n)
    for i in "${!jp[@]}"; do
        cst_call admin POST /crowdsec/decisions "$(jq -nc --arg p "${jp[$i]}" --arg v "198.18.81.$(( i + 1 ))" '{value: $v, duration: "1h", reason: $p}')"
        cst_call admin POST /crowdsec/allowlist "$(jq -nc --arg p "${jp[$i]}" --arg v "198.18.82.$(( i + 1 ))" '{value: $v, comment: $p}')"
    done
    words=$(cst_argv_since "$mark" | grep -F ' decisions add ' | while IFS= read -r line; do eval "argv=($line)"; echo "${#argv[@]}"; done | sort -u | tr '\n' ' ')
    check "injection/free text: a ban's note never makes a call with more arguments (every call has 12)" "12 " "$words"
    words=$(cst_argv_since "$mark" | grep -F ' allowlists add ' | while IFS= read -r line; do eval "argv=($line)"; echo "${#argv[@]}"; done | sort -u | tr '\n' ' ')
    check "injection/free text: …nor an allowlist note (every call has 8)" "8 " "$words"
    check "injection/free text: the text only ever sits in the --reason= / --comment= argument" 0 "$(cst_argv_since "$mark" | while IFS= read -r line; do eval "argv=($line)"; for w in "${argv[@]}"; do [[ "$w" == *PWNMARK* && "$w" != --reason=* && "$w" != --comment=* ]] && echo bad; done; done | wc -l | tr -d ' ')"
    check "injection/free text: …and nothing was run" no "$([[ -e "$pwn" ]] && echo yes || echo no)"
    cst_call admin GET '/crowdsec/decisions?limit=100'
    check "injection/free text: the notes are in the list, cleaned of control characters" yes "$(jq -e '[.decisions[] | select(.value | startswith("198.18.81.")) | .scenario] | length >= 12' <<< "$CST_BODY" >/dev/null 2>&1 && echo yes || echo no)"
    # no shell is ever started in the container, only the programs the page needs
    check "injection: every call to the container runs one of the known programs, never a shell" 0 "$(sed 's/\\//g' "$CST/argv.log" | awk '$1 == "exec" { i = 2; if ($i == "-i") i++; if ($(i+1) !~ /^(cscli|crowdsec|cat|ls|rm|mkdir)$/) print }' | wc -l | tr -d ' ')"
    check "injection: …and docker itself is asked only for what the page needs" "" "$(awk '{print $1}' "$CST/argv.log" | sort -u | grep -vxE 'ps|inspect|exec|cp|restart|start|logs|kill|version|compose|info' | tr '\n' ' ')"
}

cst_part_security() {
    echo "CrowdSec page: who may do what, the audit log, hostile text"
    cst_security_roles
    cst_security_audit
    cst_security_injection
}

# ---- the library on its own: addresses, networks, lengths, names, the jq definitions --------------------------------------------------

# cst_units — rows "NAME ⇒ EXPECTED ⇒ COMMAND" on stdin; each COMMAND runs in a shell that has .lib/crowdsec.sh (yn CMD… says yes or no for a
# status, out CMD… prints the output with tabs as | and line ends as ~). One shell for all rows, one check per row.
cst_units() {
    local rows out name want cmd got i=0 line
    rows=$(cat)
    out=$( (
        set +u
        [[ -z "$CST_LOC" ]] || export LC_ALL="$CST_LOC"
        export BASE_DIR="$CST" CROWDSEC_STATE_DIR="$CST/.data/crowdsec" COMPOSE_DIR="$CST/Stacks" TEMPLATES_DIR="$CST/.templates"
        # shellcheck disable=SC1091
        source "$CST/.lib/crowdsec.sh" >/dev/null 2>&1
        yn() { if "$@" >/dev/null 2>&1; then echo yes; else echo no; fi; }
        out() { "$@" 2>/dev/null | tr '\t\n' '|~'; }
        jqd() { jq -nr "$_CS_JQ_DEFS $1" 2>&1 | paste -sd' ' -; }
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            cmd="${line#* ⇒ }"; cmd="${cmd#* ⇒ }"
            printf '%s\n' "$(eval "$cmd" 2>/dev/null)"
        done <<< "$rows"
    ) 2>/dev/null )
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        i=$(( i + 1 ))
        name="${line%% ⇒ *}"; want="${line#* ⇒ }"; want="${want%% ⇒ *}"
        got=$(sed -n "${i}p" <<< "$out")
        check "$name" "$want" "$got"
    done <<< "$rows"
}

cst_part_units() {
    echo "CrowdSec page: the library on its own"
    cst_units_jq
    local lib="$CST/.lib/crowdsec.sh" cfg="$CST/.lib/crowdsec-config.sh" bad loc n
    [[ -d "$CST/.lib" ]] || { check "units: the install exists" yes no; return; }

    # -- IPv4
    cst_units <<'EOF'
v4: 0.0.0.0 ⇒ yes ⇒ yn _cs_is_v4 0.0.0.0
v4: 255.255.255.255 ⇒ yes ⇒ yn _cs_is_v4 255.255.255.255
v4: 203.0.113.7 ⇒ yes ⇒ yn _cs_is_v4 203.0.113.7
v4: 256 in the last place ⇒ no ⇒ yn _cs_is_v4 1.2.3.256
v4: 999 ⇒ no ⇒ yn _cs_is_v4 999.1.1.1
v4: three octets ⇒ no ⇒ yn _cs_is_v4 1.2.3
v4: five octets ⇒ no ⇒ yn _cs_is_v4 1.2.3.4.5
v4: leading zero ⇒ no ⇒ yn _cs_is_v4 01.2.3.4
v4: leading zero in the last ⇒ no ⇒ yn _cs_is_v4 1.2.3.04
v4: 00 ⇒ no ⇒ yn _cs_is_v4 1.2.3.00
v4: empty octet ⇒ no ⇒ yn _cs_is_v4 1..2.3
v4: sign ⇒ no ⇒ yn _cs_is_v4 +1.2.3.4
v4: negative ⇒ no ⇒ yn _cs_is_v4 1.2.3.-4
v4: letters ⇒ no ⇒ yn _cs_is_v4 a.b.c.d
v4: a space in front ⇒ no ⇒ yn _cs_is_v4 ' 1.2.3.4'
v4: a space behind ⇒ no ⇒ yn _cs_is_v4 '1.2.3.4 '
v4: a line end behind ⇒ no ⇒ yn _cs_is_v4 $'1.2.3.4\n'
v4: a prefix ⇒ no ⇒ yn _cs_is_v4 1.2.3.4/24
v4: nothing ⇒ no ⇒ yn _cs_is_v4 ''
v4: hex ⇒ no ⇒ yn _cs_is_v4 0x1.2.3.4
v4: octal-looking ⇒ no ⇒ yn _cs_is_v4 010.010.010.010
EOF
    # -- what a target becomes (Ip or Range, written the way CrowdSec writes it)
    cst_units <<'EOF'
target: an address ⇒ Ip|1.2.3.4 ⇒ out _cs_norm_target 1.2.3.4
target: /32 is an address ⇒ Ip|1.2.3.4 ⇒ out _cs_norm_target 1.2.3.4/32
target: a network loses its host bits ⇒ Range|1.2.3.0/24 ⇒ out _cs_norm_target 1.2.3.5/24
target: a /25 ⇒ Range|198.18.44.128/25 ⇒ out _cs_norm_target 198.18.44.200/25
target: a /23 ⇒ Range|198.18.44.0/23 ⇒ out _cs_norm_target 198.18.45.9/23
target: a /12 ⇒ Range|172.16.0.0/12 ⇒ out _cs_norm_target 172.31.255.255/12
target: a /8 ⇒ Range|10.0.0.0/8 ⇒ out _cs_norm_target 10.9.9.9/8
target: everything ⇒ Range|0.0.0.0/0 ⇒ out _cs_norm_target 1.2.3.4/0
target: /33 ⇒  ⇒ out _cs_norm_target 1.2.3.4/33
target: /008 ⇒  ⇒ out _cs_norm_target 1.2.3.4/08
target: a prefix that is empty ⇒  ⇒ out _cs_norm_target 1.2.3.4/
target: a prefix that is a word ⇒  ⇒ out _cs_norm_target 1.2.3.4/x
target: two prefixes ⇒  ⇒ out _cs_norm_target 1.2.3.4/24/8
target: nothing ⇒  ⇒ out _cs_norm_target ''
target: 65 characters ⇒  ⇒ out _cs_norm_target 1111:1111:1111:1111:1111:1111:1111:1111:1111:1111:1111:1111:1111:1111:1111:1111:1
target: IPv6 ⇒ Ip|2001:db8::1 ⇒ out _cs_norm_target 2001:db8::1
target: IPv6 in capitals and long ⇒ Ip|2001:db8::1 ⇒ out _cs_norm_target 2001:0DB8:0000:0000:0000:0000:0000:0001
target: :: ⇒ Ip|:: ⇒ out _cs_norm_target ::
target: ::1 ⇒ Ip|::1 ⇒ out _cs_norm_target ::1
target: 1:: ⇒ Ip|1:: ⇒ out _cs_norm_target 1::
target: eight groups, no :: ⇒ Ip|1:2:3:4:5:6:7:8 ⇒ out _cs_norm_target 1:2:3:4:5:6:7:8
target: :: standing for one group ⇒ Ip|1:2:3:4:5:6:7:0 ⇒ out _cs_norm_target 1:2:3:4:5:6:7::
target: the longest run of zeros gets the :: ⇒ Ip|2001:0:0:1::1 ⇒ out _cs_norm_target 2001:0:0:1:0:0:0:1
target: the first of two equal runs ⇒ Ip|1::2:0:0:3:4 ⇒ out _cs_norm_target 1:0:0:2:0:0:3:4
target: a single zero group stays ⇒ Ip|1:0:2:3:4:5:6:7 ⇒ out _cs_norm_target 1:0:2:3:4:5:6:7
target: leading zeros in a group ⇒ Ip|2001:db8::a ⇒ out _cs_norm_target 2001:0db8:0:0:0:0:0:000a
target: IPv6 network ⇒ Range|2001:db8::/32 ⇒ out _cs_norm_target 2001:db8:1::/32
target: IPv6 /64 loses host bits ⇒ Range|2001:db8:1:2::/64 ⇒ out _cs_norm_target 2001:db8:1:2:3:4:5:6/64
target: IPv6 /128 is an address ⇒ Ip|2001:db8::5 ⇒ out _cs_norm_target 2001:db8::5/128
target: IPv6 /129 ⇒  ⇒ out _cs_norm_target 2001:db8::5/129
target: IPv6 /57 (not on a group boundary) ⇒ Range|2001:db8:0:80::/57 ⇒ out _cs_norm_target 2001:db8:0:ff::/57
target: three colons ⇒  ⇒ out _cs_norm_target :::
target: two :: ⇒  ⇒ out _cs_norm_target 1::2::3
target: nine groups ⇒  ⇒ out _cs_norm_target 1:2:3:4:5:6:7:8:9
target: seven groups ⇒  ⇒ out _cs_norm_target 1:2:3:4:5:6:7
target: five digits in a group ⇒  ⇒ out _cs_norm_target 12345::1
target: not hex ⇒  ⇒ out _cs_norm_target 2001:db8::g
target: a zone id ⇒  ⇒ out _cs_norm_target fe80::1%eth0
target: brackets ⇒  ⇒ out _cs_norm_target '[::1]'
target: one colon ⇒  ⇒ out _cs_norm_target :
target: a colon at the start ⇒  ⇒ out _cs_norm_target :1:2:3:4:5:6:7
target: a colon at the end ⇒  ⇒ out _cs_norm_target 1:2:3:4:5:6:7:
target: a dotted tail ⇒ Ip|64:ff9b::c000:221 ⇒ out _cs_norm_target 64:ff9b::192.0.2.33
target: a broken dotted tail ⇒  ⇒ out _cs_norm_target ::1.2.3
target: a dotted tail out of range ⇒  ⇒ out _cs_norm_target ::1.2.3.256
target: a dotted tail with a leading zero ⇒  ⇒ out _cs_norm_target ::1.2.3.04
EOF
    # -- IPv4-mapped IPv6 (::ffff:a.b.c.d) is how an IPv6 socket shows an IPv4 client: it is banned as the IPv4 address, so that every check made on IPv4 applies to it
    cst_units <<'EOF'
mapped: dotted ⇒ Ip|1.2.3.4 ⇒ out _cs_norm_target ::ffff:1.2.3.4
mapped: hex ⇒ Ip|1.2.3.4 ⇒ out _cs_norm_target ::ffff:102:304
mapped: in capitals ⇒ Ip|1.2.3.4 ⇒ out _cs_norm_target ::FFFF:1.2.3.4
mapped: written long ⇒ Ip|1.2.3.4 ⇒ out _cs_norm_target 0:0:0:0:0:ffff:1.2.3.4
mapped: /128 is the address ⇒ Ip|1.2.3.4 ⇒ out _cs_norm_target ::ffff:1.2.3.4/128
mapped: a network of them is an IPv4 network ⇒ Range|1.2.3.0/24 ⇒ out _cs_norm_target ::ffff:1.2.3.9/120
mapped: …a wider one ⇒ Range|1.2.0.0/16 ⇒ out _cs_norm_target ::ffff:1.2.3.9/112
mapped: all of them is everything (the guard refuses that) ⇒ Range|0.0.0.0/0 ⇒ out _cs_norm_target ::ffff:0:0/96
mapped: not mapped (::fffe) ⇒ Ip|::fffe:102:304 ⇒ out _cs_norm_target ::fffe:1.2.3.4
mapped: not mapped (one group of the zeros is not) ⇒ Ip|::1:ffff:102:304 ⇒ out _cs_norm_target 0:0:0:0:1:ffff:1.2.3.4
mapped: a wider network than /96 is still IPv6 ⇒ Range|::/64 ⇒ out _cs_norm_target ::ffff:1.2.3.4/64
EOF
    # -- one address inside another
    cst_units <<'EOF'
covers: a network holds its address ⇒ yes ⇒ yn _cs_covers 10.0.0.0/8 10.1.2.3
covers: …not one outside ⇒ no ⇒ yn _cs_covers 10.0.0.0/8 11.0.0.1
covers: an address holds itself ⇒ yes ⇒ yn _cs_covers 1.2.3.4 1.2.3.4
covers: an address does not hold another ⇒ no ⇒ yn _cs_covers 1.2.3.4 1.2.3.5
covers: a network holds a smaller one ⇒ yes ⇒ yn _cs_covers 10.0.0.0/8 10.5.0.0/16
covers: a smaller one does not hold the bigger ⇒ no ⇒ yn _cs_covers 10.5.0.0/16 10.0.0.0/8
covers: the same network ⇒ yes ⇒ yn _cs_covers 10.5.0.0/16 10.5.0.0/16
covers: everything holds everything ⇒ yes ⇒ yn _cs_covers 0.0.0.0/0 203.0.113.7
covers: a /25 edge, inside ⇒ yes ⇒ yn _cs_covers 198.18.44.128/25 198.18.44.255
covers: a /25 edge, outside ⇒ no ⇒ yn _cs_covers 198.18.44.128/25 198.18.44.127
covers: a /23 ⇒ yes ⇒ yn _cs_covers 198.18.44.0/23 198.18.45.200
covers: a /23, the next one ⇒ no ⇒ yn _cs_covers 198.18.44.0/23 198.18.46.0
covers: a /12 (172.16/12), last address ⇒ yes ⇒ yn _cs_covers 172.16.0.0/12 172.31.255.255
covers: a /12, the first outside ⇒ no ⇒ yn _cs_covers 172.16.0.0/12 172.32.0.0
covers: a /9 ⇒ yes ⇒ yn _cs_covers 128.0.0.0/9 128.127.255.255
covers: a /9, outside ⇒ no ⇒ yn _cs_covers 128.0.0.0/9 128.128.0.0
covers: IPv6 network ⇒ yes ⇒ yn _cs_covers 2001:db8::/32 2001:db8:ffff::1
covers: IPv6 outside ⇒ no ⇒ yn _cs_covers 2001:db8::/32 2001:db9::1
covers: IPv6 on a group edge (/57) ⇒ yes ⇒ yn _cs_covers 2001:db8:0:80::/57 2001:db8:0:ff::1
covers: IPv6 past it ⇒ no ⇒ yn _cs_covers 2001:db8:0:80::/57 2001:db8:0:100::1
covers: IPv6 fc00::/7 holds fd00 ⇒ yes ⇒ yn _cs_covers fc00::/7 fd12:3456::1
covers: IPv6 fc00::/7 does not hold fe00 ⇒ no ⇒ yn _cs_covers fc00::/7 fe00::1
covers: IPv4 never holds IPv6 ⇒ no ⇒ yn _cs_covers 0.0.0.0/0 ::1
covers: IPv6 never holds IPv4 ⇒ no ⇒ yn _cs_covers ::/0 1.2.3.4
overlaps: one holds the other ⇒ yes ⇒ yn _cs_overlaps 10.0.0.0/8 10.1.0.0/16
overlaps: …the other way ⇒ yes ⇒ yn _cs_overlaps 10.1.0.0/16 10.0.0.0/8
overlaps: apart ⇒ no ⇒ yn _cs_overlaps 10.1.0.0/16 10.2.0.0/16
EOF
    # -- what a ban never touches
    cst_units <<'EOF'
private: 10.0.0.0 ⇒ yes ⇒ yn _cs_is_private 10.0.0.0
private: 10.255.255.255 ⇒ yes ⇒ yn _cs_is_private 10.255.255.255
private: 9.255.255.255 ⇒ no ⇒ yn _cs_is_private 9.255.255.255
private: 11.0.0.0 ⇒ no ⇒ yn _cs_is_private 11.0.0.0
private: 172.16.0.0 ⇒ yes ⇒ yn _cs_is_private 172.16.0.0
private: 172.31.255.255 ⇒ yes ⇒ yn _cs_is_private 172.31.255.255
private: 172.15.255.255 ⇒ no ⇒ yn _cs_is_private 172.15.255.255
private: 172.32.0.0 ⇒ no ⇒ yn _cs_is_private 172.32.0.0
private: 192.168.0.1 ⇒ yes ⇒ yn _cs_is_private 192.168.0.1
private: 192.167.255.255 ⇒ no ⇒ yn _cs_is_private 192.167.255.255
private: 192.169.0.0 ⇒ no ⇒ yn _cs_is_private 192.169.0.0
private: 127.0.0.1 ⇒ yes ⇒ yn _cs_is_private 127.0.0.1
private: 127.255.255.254 ⇒ yes ⇒ yn _cs_is_private 127.255.255.254
private: 169.254.1.1 ⇒ yes ⇒ yn _cs_is_private 169.254.1.1
private: 169.253.0.1 ⇒ no ⇒ yn _cs_is_private 169.253.0.1
private: 100.64.0.1 ⇒ yes ⇒ yn _cs_is_private 100.64.0.1
private: 100.127.255.255 ⇒ yes ⇒ yn _cs_is_private 100.127.255.255
private: 100.63.255.255 ⇒ no ⇒ yn _cs_is_private 100.63.255.255
private: 100.128.0.0 ⇒ no ⇒ yn _cs_is_private 100.128.0.0
private: 0.1.2.3 ⇒ yes ⇒ yn _cs_is_private 0.1.2.3
private: 203.0.113.7 ⇒ no ⇒ yn _cs_is_private 203.0.113.7
private: 8.8.8.8 ⇒ no ⇒ yn _cs_is_private 8.8.8.8
private: IPv6 loopback ⇒ yes ⇒ yn _cs_is_private ::1
private: IPv6 unspecified ⇒ yes ⇒ yn _cs_is_private ::
private: IPv6 unique local fc00 ⇒ yes ⇒ yn _cs_is_private fc00::1
private: IPv6 unique local fd ⇒ yes ⇒ yn _cs_is_private fdff:ffff::1
private: IPv6 link-local ⇒ yes ⇒ yn _cs_is_private fe80::1
private: IPv6 link-local end ⇒ yes ⇒ yn _cs_is_private febf::1
private: IPv6 site-local (deprecated, outside) ⇒ no ⇒ yn _cs_is_private fec0::1
private: IPv6 global ⇒ no ⇒ yn _cs_is_private 2001:db8::1
private: a range that only partly private ⇒ no ⇒ yn _cs_is_private 192.0.0.0/8
private: a range inside ⇒ yes ⇒ yn _cs_is_private 10.5.0.0/16
private: a range that holds private ranges is not itself one ⇒ no ⇒ yn _cs_is_private 8.0.0.0/5
EOF
    # -- lengths
    cst_units <<'EOF'
duration: 4h ⇒ 4h ⇒ out _cs_norm_duration 4h
duration: 90m ⇒ 90m ⇒ out _cs_norm_duration 90m
duration: 60m is an hour ⇒ 1h ⇒ out _cs_norm_duration 60m
duration: 1d ⇒ 24h ⇒ out _cs_norm_duration 1d
duration: 7d ⇒ 168h ⇒ out _cs_norm_duration 7d
duration: 2w ⇒ 336h ⇒ out _cs_norm_duration 2w
duration: 1h30m ⇒ 90m ⇒ out _cs_norm_duration 1h30m
duration: 1d12h ⇒ 36h ⇒ out _cs_norm_duration 1d12h
duration: 3600s ⇒ 1h ⇒ out _cs_norm_duration 3600s
duration: 60s ⇒ 1m ⇒ out _cs_norm_duration 60s
duration: 61s is cut to the minute ⇒ 1m ⇒ out _cs_norm_duration 61s
duration: capitals ⇒ 4h ⇒ out _cs_norm_duration 4H
duration: spaces ⇒ 90m ⇒ out _cs_norm_duration ' 1h 30m '
duration: repeated units add up ⇒ 3h ⇒ out _cs_norm_duration 1h1h1h
duration: a year ⇒ 8760h ⇒ out _cs_norm_duration 525600m
duration: ten years ⇒ 87600h ⇒ out _cs_norm_duration 3650d
duration: just over ten years ⇒  ⇒ out _cs_norm_duration 87601h
duration: 59s ⇒  ⇒ out _cs_norm_duration 59s
duration: 0 ⇒  ⇒ out _cs_norm_duration 0
duration: 0m ⇒  ⇒ out _cs_norm_duration 0m
duration: no unit ⇒  ⇒ out _cs_norm_duration 4
duration: years ⇒  ⇒ out _cs_norm_duration 1y
duration: a fraction ⇒  ⇒ out _cs_norm_duration 1.5h
duration: a sign ⇒  ⇒ out _cs_norm_duration +4h
duration: negative ⇒  ⇒ out _cs_norm_duration -4h
duration: words ⇒  ⇒ out _cs_norm_duration 4hours
duration: empty ⇒  ⇒ out _cs_norm_duration ''
duration: ten digits ⇒  ⇒ out _cs_norm_duration 9999999999s
duration: nine digits, far too long ⇒  ⇒ out _cs_norm_duration 999999999h
duration: 25 characters ⇒  ⇒ out _cs_norm_duration 1s1s1s1s1s1s1s1s1s1s1s1s1s
duration: shell text ⇒  ⇒ out _cs_norm_duration '$(id)'
seconds: 1d2h3m4s ⇒ 93784 ⇒ out _cs_duration_seconds 1d2h3m4s
seconds: 2w ⇒ 1209600 ⇒ out _cs_duration_seconds 2w
seconds: 90m ⇒ 5400 ⇒ out _cs_duration_seconds 90m
seconds: a word ⇒  ⇒ out _cs_duration_seconds abc
seconds: a fraction ⇒  ⇒ out _cs_duration_seconds 1.5h
human: 90 seconds ⇒ 2 min ⇒ out _cs_human_secs 90
human: an hour and a half ⇒ 1 h 30 min ⇒ out _cs_human_secs 5400
human: two days ⇒ 2 d 7 h ⇒ out _cs_human_secs 200000
human: one second ⇒ 1 min ⇒ out _cs_human_secs 1
EOF
    # -- names, patterns, texts
    cst_units <<'EOF'
name: a hub item ⇒ yes ⇒ yn _cs_valid_name crowdsecurity/nginx
name: with a version ⇒ yes ⇒ yn _cs_valid_name crowdsecurity/nginx:1.0
name: a dash first ⇒ no ⇒ yn _cs_valid_name -h
name: a dot first ⇒ no ⇒ yn _cs_valid_name .x
name: a slash first ⇒ no ⇒ yn _cs_valid_name /x
name: a space ⇒ no ⇒ yn _cs_valid_name 'a b'
name: a semicolon ⇒ no ⇒ yn _cs_valid_name 'a;b'
name: 100 characters ⇒ yes ⇒ yn _cs_valid_name "$(printf 'a%.0s' $(seq 1 100))"
name: 101 characters ⇒ no ⇒ yn _cs_valid_name "$(printf 'a%.0s' $(seq 1 101))"
name: a line end ⇒ no ⇒ yn _cs_valid_name $'a\nb'
pattern: a name ⇒ yes ⇒ yn _cs_valid_pattern crowdsecurity/ssh-bf
pattern: a prefix ⇒ yes ⇒ yn _cs_valid_pattern 'crowdsecurity/ssh*'
pattern: two stars ⇒ no ⇒ yn _cs_valid_pattern 'crowdsecurity/ssh**'
pattern: a star first ⇒ no ⇒ yn _cs_valid_pattern '*'
pattern: a star in the middle ⇒ no ⇒ yn _cs_valid_pattern 'a*b'
pattern: a quote ⇒ no ⇒ yn _cs_valid_pattern 'a"b'
pattern: a backslash ⇒ no ⇒ yn _cs_valid_pattern 'a\b'
pattern: 120 characters and a star ⇒ yes ⇒ yn _cs_valid_pattern "$(printf 'a%.0s' $(seq 1 120))*"
pattern: 121 characters ⇒ no ⇒ yn _cs_valid_pattern "$(printf 'a%.0s' $(seq 1 121))"
country: DE ⇒ yes ⇒ yn _cs_valid_cc DE
country: de ⇒ yes ⇒ yn _cs_valid_cc de
country: D ⇒ no ⇒ yn _cs_valid_cc D
country: DEU ⇒ no ⇒ yn _cs_valid_cc DEU
country: 12 ⇒ no ⇒ yn _cs_valid_cc 12
country: an accented letter ⇒ no ⇒ yn _cs_valid_cc 'dé'
reason: plain ⇒ hello ⇒ out _cs_clean_reason hello
reason: trimmed ⇒ hello ⇒ out _cs_clean_reason '   hello  '
reason: a tab and a line end are spaces ⇒ a b c ⇒ out _cs_clean_reason $'a\tb\nc'
reason: control characters go ⇒ ab ⇒ out _cs_clean_reason $'a\001b\177'
reason: 200 characters ⇒ 200 ⇒ x=$(printf 'y%.0s' $(seq 1 300)); r=$(_cs_clean_reason "$x"); echo ${#r}
EOF
    # -- the jq that reads what CrowdSec prints
    cst_units <<'EOF'
dur_secs: a Go duration ⇒ 14387 ⇒ jqd '"3h59m47s" | dur_secs'
dur_secs: hours only ⇒ 7200 ⇒ jqd '"2h0m0s" | dur_secs'
dur_secs: minutes and seconds ⇒ 123 ⇒ jqd '"2m3s" | dur_secs'
dur_secs: a fraction of a second ⇒ 1.5 ⇒ jqd '"1.5s" | dur_secs'
dur_secs: milliseconds ⇒ 0.5 ⇒ jqd '"500ms" | dur_secs'
dur_secs: a negative one ⇒ -300 ⇒ jqd '"-5m" | dur_secs'
dur_secs: the permanent ban ⇒ 315359999 ⇒ jqd '"87599h59m59s" | dur_secs'
dur_secs: seven days ⇒ 604799 ⇒ jqd '"167h59m59s" | dur_secs'
dur_secs: empty ⇒ 0 ⇒ jqd '"" | dur_secs'
dur_secs: null ⇒ 0 ⇒ jqd 'null | dur_secs'
dur_secs: a word ⇒ 0 ⇒ jqd '"abc" | dur_secs'
iso_secs: a time ⇒ 1790712658 ⇒ jqd '"2026-09-29T20:10:58Z" | iso_secs'
iso_secs: with nanoseconds ⇒ 1790712658 ⇒ jqd '"2026-09-29T20:10:58.059930395Z" | iso_secs'
iso_secs: null ⇒ 0 ⇒ jqd 'null | iso_secs'
iso_secs: garbage ⇒ 0 ⇒ jqd '"yesterday" | iso_secs'
cc: upper case ⇒ DE ⇒ jqd '"de" | cc'
cc: null ⇒  ⇒ jqd 'null | cc'
label: an unknown scenario ⇒ Attack blocked other ⇒ jqd '"vendor/nothing-known" | scen_row | .[1], .[2]'
label: an empty one ⇒ Attack blocked other ⇒ jqd '"" | scen_row | .[1], .[2]'
label: null ⇒ Attack blocked other ⇒ jqd 'null | scen_row | .[1], .[2]'
label: probing ⇒ Web probing probe ⇒ jqd '"crowdsecurity/http-probing" | scen_row | .[1], .[2]'
label: ssh brute force ⇒ SSH brute force bruteforce ⇒ jqd '"crowdsecurity/ssh-bf" | scen_row | .[1], .[2]'
label: an exploit ⇒ Exploit attempt exploit ⇒ jqd '"crowdsecurity/CVE-2017-9841" | scen_row | .[1], .[2]'
label: a manual ban ⇒ Manual ban manual ⇒ jqd '{kind: "cscli"} | alert_label, alert_family'
label: a manual ban, the alert of an imported list ⇒ Manual ban manual ⇒ jqd '{kind: "cscli", scenario: "import stdin: 3 IPs"} | alert_label, alert_family'
EOF
    # -- the label table: the page, the Discord messages and the previews read the same one
    bad=$( (
        set +u
        export BASE_DIR="$CST" CROWDSEC_STATE_DIR="$CST/.data/crowdsec" COMPOSE_DIR="$CST/Stacks" TEMPLATES_DIR="$CST/.templates"
        source "$lib" >/dev/null 2>&1; source "$cfg" >/dev/null 2>&1
        jq -nr "$_CS_JQ_LABELS"' label_table as $t
            | ( [$t[] | select((length == 3 and all(.[]; type == "string" and length > 0)) | not) | "malformed row \(.)"]
              + [$t[] | select(.[2] | IN("bruteforce", "exploit", "probe", "other", "manual", "community") | not) | "unknown family \(.[2])"]
              + [$t | to_entries[] | . as $a | select(($a.value[0] | scen_row | .[0]) != $a.value[0]) | "row \($a.value[0]) is shadowed by an earlier prefix"]
              + [$t[] | .[0] as $p | (($p + "-x") | scen_row | .[2]) as $f | select($f == "other") | "prefix \($p) does not match a name that starts with it"]
              + [($t | map(.[0]) | (length - (unique | length))) | select(. > 0) | "\(.) prefixes are listed twice"] )
            | .[]'
        # every row is in the Go template that Discord messages are made of, and in the same order
        _cs_notify_validate "$_CS_NOTIFY_DEFAULTS" && tpl=$(_cs_notify_go_template "$CS_OUT" lab.example.com srv)
        n=0
        while IFS= read -r prefix; do
            grep -qF "hasPrefix \"$prefix\" \$p_scenario" <<< "$tpl" || echo "the Go template has no branch for $prefix"
            n=$(( n + 1 ))
        done < <(jq -nr "$_CS_JQ_LABELS"' label_table[] | .[0]')
        [[ "$n" -ge 15 ]] || echo "the table has only $n rows"
    ) 2>&1 )
    check "units/labels: the table is well formed, every row can be reached, and the Discord template has a branch for each row" "" "$bad"

    # -- the reading of cscli's ban list
    cst_units <<'EOF'
rows: a live ban ⇒ 1 ⇒ jqd '[{"id":1,"scenario":"crowdsecurity/ssh-bf","source":{"cn":"de"},"decisions":[{"id":5,"value":"1.2.3.4","scope":"Ip","type":"ban","origin":"crowdsec","duration":"3h59m47s"}]}] | decision_rows(1000) | length'
rows: an expired ban is not a ban ⇒ 0 ⇒ jqd '[{"id":1,"decisions":[{"id":5,"value":"1.2.3.4","scope":"Ip","type":"ban","origin":"crowdsec","duration":"-4s"}]}] | decision_rows(1000) | length'
rows: a ban that ends now is not one either ⇒ 0 ⇒ jqd '[{"id":1,"decisions":[{"id":5,"value":"1.2.3.4","scope":"Ip","type":"ban","origin":"crowdsec","duration":"0s"}]}] | decision_rows(1000) | length'
rows: no decisions ⇒ 0 ⇒ jqd '[{"id":1,"decisions":null}] | decision_rows(1000) | length'
rows: null ⇒ 0 ⇒ jqd 'null | decision_rows(1000) | length'
rows: the country is upper case ⇒ DE ⇒ jqd '[{"id":1,"source":{"cn":"de"},"decisions":[{"id":5,"value":"1.2.3.4","scope":"Ip","type":"ban","origin":"crowdsec","duration":"1h"}]}] | decision_rows(1000)[0].country'
rows: a permanent ban ⇒ true ⇒ jqd '[{"id":1,"decisions":[{"id":5,"value":"1.2.3.4","scope":"Ip","type":"ban","origin":"cscli","duration":"87599h59m59s"}]}] | decision_rows(1000)[0].permanent'
rows: a year is not a ban ended ⇒ true ⇒ jqd '[{"id":1,"decisions":[{"id":5,"value":"1.2.3.4","scope":"Ip","type":"ban","origin":"cscli","duration":"8760h0m0s"}]}] | decision_rows(1000)[0].permanent'
rows: 364 days are not permanent ⇒ false ⇒ jqd '[{"id":1,"decisions":[{"id":5,"value":"1.2.3.4","scope":"Ip","type":"ban","origin":"cscli","duration":"8735h0m0s"}]}] | decision_rows(1000)[0].permanent'
rows: it ends when the countdown says ⇒ 4600 ⇒ jqd '[{"id":1,"decisions":[{"id":5,"value":"1.2.3.4","scope":"Ip","type":"ban","origin":"cscli","duration":"1h0m0s"}]}] | decision_rows(1000)[0] | .expires_at | fromdateiso8601'
rows: manual ⇒ Manual ban manual ⇒ jqd '[{"id":1,"decisions":[{"id":5,"value":"1.2.3.4","scope":"Ip","type":"ban","origin":"cscli","duration":"1h"}]}] | decision_rows(1000)[0] | .label, .family'
rows: imported ⇒ Imported ban manual ⇒ jqd '[{"id":1,"decisions":[{"id":5,"value":"1.2.3.4","scope":"Ip","type":"ban","origin":"cscli-import","duration":"1h"}]}] | decision_rows(1000)[0] | .label, .family'
rows: the community list ⇒ Community blocklist community ⇒ jqd '[{"id":1,"decisions":[{"id":5,"value":"1.2.3.4","scope":"Ip","type":"ban","origin":"CAPI","duration":"1h"}]}] | decision_rows(1000)[0] | .label, .family'
rows: a subscribed list ⇒ Blocklist community ⇒ jqd '[{"id":1,"decisions":[{"id":5,"value":"1.2.3.4","scope":"Ip","type":"ban","origin":"lists:firehol","duration":"1h"}]}] | decision_rows(1000)[0] | .label, .family'
rows: the console ⇒ CrowdSec console community ⇒ jqd '[{"id":1,"decisions":[{"id":5,"value":"1.2.3.4","scope":"Ip","type":"ban","origin":"console","duration":"1h"}]}] | decision_rows(1000)[0] | .label, .family'
rows: an engine detection ⇒ SSH brute force bruteforce ⇒ jqd '[{"id":1,"scenario":"crowdsecurity/ssh-bf","decisions":[{"id":5,"value":"1.2.3.4","scope":"Ip","type":"ban","origin":"crowdsec","duration":"1h"}]}] | decision_rows(1000)[0] | .label, .family'
rows: two decisions of one alert ⇒ 2 ⇒ jqd '[{"id":1,"decisions":[{"id":5,"value":"1.2.3.4","scope":"Ip","type":"ban","origin":"crowdsec","duration":"1h"},{"id":6,"value":"1.2.3.5","scope":"Ip","type":"ban","origin":"crowdsec","duration":"1h"}]}] | decision_rows(1000) | length'
alerts: a row ⇒ 7 crowdsecurity/ssh-bf 1.2.3.4 DE ⇒ jqd '{"id":7,"scenario":"crowdsecurity/ssh-bf","events_count":3,"source":{"value":"1.2.3.4","cn":"de","scope":"Ip"}} | alert_row | "\(.id) \(.scenario) \(.source.value) \(.source.country)"'
alerts: missing fields are empty, not errors ⇒ 0 0 ⇒ jqd '{"id":7} | alert_row | "\(.events_count) \(.decisions | length)"'
EOF
    # -- addresses in every language the machine has: [0-9a-f] and [a-z] mean ASCII, whatever the locale says
    bad=""
    for loc in C C.UTF-8 en_US.UTF-8 de_DE.UTF-8 tr_TR.UTF-8 ar_EG.UTF-8 sv_SE.UTF-8 fr_FR.UTF-8; do
        [[ "$loc" == C ]] || locale -a 2>/dev/null | tr 'A-Z' 'a-z' | grep -qx "$(tr 'A-Z' 'a-z' <<< "${loc%%.*}").utf-\?8" || continue
        n=$( (
            set +u
            export LC_ALL="$loc"
            export BASE_DIR="$CST" CROWDSEC_STATE_DIR="$CST/.data/crowdsec"
            source "$lib" >/dev/null 2>&1
            for a in $'2a00::\xc3\xa4' $'2a00::\xc3\xa7' $'2a00:\xd9\xa1::1' $'198.18.0.\xd9\xa3' $'1.2.3.\xd9\xa4' $'\xd9\xa1\xd9\xa2\xd9\xa3.1.1.1' $'::\xc3\xa4b' $'2001:db8::\xc3\xa4/64' $'198.18.0.0/\xd9\xa3'; do
                _cs_norm_target "$a" >/dev/null 2>&1 && echo "accepted [$a]"
            done
            for a in $'4\xd9\xa1h' $'\xd9\xa1h' $'4\xc3\xa4'; do _cs_norm_duration "$a" >/dev/null 2>&1 && echo "accepted duration [$a]"; done
        ) 2>/dev/null )
        [[ -z "$n" ]] || bad+="$loc: $(head -n 1 <<< "$n") "
    done
    check "units/locale: letters and digits of other alphabets are never part of an address or a length" "" "$bad"
}

# jq 1.6 is what the oldest supported server has: nothing newer than it may be used (a grep for what 1.7 and 1.8 added, and a run with a 1.6 binary if there is one)
cst_units_jq() {
    local f new hits
    # the jq programs sit in shell strings; the words below are jq builtins that appeared after 1.6 (pick, debug(msg), scan with flags, abs, toarray, trim/ltrim/rtrim, trimstr, have_decnum, have_literal_numbers, @urid, splits with flags, ltrimstr is old, limit with a negative count, getpath/1 is old, skip, add(f))
    new='(^|[^A-Za-z0-9_$.])(pick\(|trim\b|debug\("|scan\([^)]*;[^)]*\)|abs\b|toarray\b|ltrim\b|rtrim\b|trimstr\(|have_decnum|have_literal_numbers|@urid|getpath\(\$__prog|skip\(|add\([^)]|splits\([^)]*;|ascii\b|@base32d)'
    hits=""
    for f in "$CST/.lib/crowdsec.sh" "$CST/.lib/crowdsec-config.sh"; do
        # (the Go template text in crowdsec-config.sh has its own "trim": only lines that are jq are looked at: they contain a pipe or a jq keyword and no {{)
        hits+=$(grep -nE "$new" "$f" | grep -vE '\{\{|^[0-9]+:[[:space:]]*#' | grep -E '\| |jq |def |select\(|map\(' | sed "s#^#${f##*/}:#" | head -n 5)
    done
    check "units/jq: nothing that only jq 1.7 or 1.8 has" "" "$hits"
    # `if` without `else` (jq 1.7), $__loc__ and friends: the programs are valid jq 1.6 when every `if` has its `else`
    hits=$(grep -nE '\bif\b[^;]*\bthen\b[^;]*\bend\b' "$CST/.lib/crowdsec.sh" "$CST/.lib/crowdsec-config.sh" | grep -vE '\belse\b|\belif\b' | grep -E 'jq|\| ' | head -n 3)
    check "units/jq: every jq if has its else" "" "$hits"
    if command -v jq-1.6 >/dev/null 2>&1 || [[ -x "${SMOKE_JQ16:-}" ]]; then
        check "units/jq: a jq 1.6 binary is there (the section can be run with it: put it first on the PATH as jq)" yes yes
    else
        printf '  skip units/jq: no jq 1.6 binary (jq-1.6 on the PATH, or SMOKE_JQ16=/path) to run the section with\n'
    fi
}

# ---- run the parts -------------------------------------------------------------------------------------------------------------------

# One lane = one install of its own (scripts, stand-in, fake Discord, accounts), run in the background; the lanes run side by side and their
# reports are printed one after the other when they are all done. SMOKE_CS_LANES=1 runs everything in a single lane, in order, live.
cst_lane_run() {
    local name="$1" part t0=$SECONDS
    shift
    CST="$CST_ROOT/$name"
    [[ "$BASHPID" == "$$" ]] || trap 'kill "${RIP_CS:-}" 2>/dev/null' EXIT      # (a lane in the background cleans up after itself; the main shell's trap does the rest)
    if ! cst_setup; then check "CrowdSec page: the test install of lane $name starts" yes no; return; fi
    for part in "$@"; do
        if declare -F "cst_part_$part" >/dev/null; then "cst_part_$part"; else check "CrowdSec page: part $part exists" yes no; fi
    done
    cst_teardown
    echo "  (lane $name took $(( SECONDS - t0 )) s)"
}

cst_main() {
    local t0=$SECONDS lane name want part n
    local -a names=()
    echo "CrowdSec page"
    mkdir -p "$CST_ROOT"
    # the stand-in is a script of 7000 lines and every docker call of every request starts it: from its bytecode that costs a third
    python3 -c 'import py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' "$CST_MOCK" "$CST_ROOT/mock.pyc" 2>/dev/null && CST_MOCK_RUN="$CST_ROOT/mock.pyc"
    local -a lanes=("a:status allowlist alerts units" "b:bans" "c:settings" "d:notify" "e:services hub" "f:security" "g:large mediaapps" "h:plugin" "i:importbig")
    [[ "${SMOKE_CS_LANES:-}" != 1 ]] || lanes=("all:status bans alerts allowlist services hub settings notify security units large plugin importbig mediaapps")
    for lane in "${lanes[@]}"; do
        name="${lane%%:*}"; want=""
        for part in ${lane#*:}; do
            [[ -z "${SMOKE_CS_PARTS:-}" || " ${SMOKE_CS_PARTS} " == *" $part "* ]] && want+="$part "
        done
        [[ -n "$want" ]] || continue
        names+=("$name")
        if [[ "${SMOKE_CS_LANES:-}" == 1 ]]; then cst_lane_run "$name" $want; continue; fi
        # shellcheck disable=SC2086  # $want is a list of part names
        ( cst_lane_run "$name" $want ) > "$CST_ROOT/lane-$name.out" 2>&1 &
        RIP_LANES="${RIP_LANES:-} $!"
    done
    if [[ "${SMOKE_CS_LANES:-}" != 1 ]]; then
        wait
        RIP_LANES=""
        for name in "${names[@]}"; do
            cat "$CST_ROOT/lane-$name.out"
            n=$(grep -c '^  ok   ' "$CST_ROOT/lane-$name.out"); PASS=$(( PASS + n ))
            n=$(grep -c '^  FAIL ' "$CST_ROOT/lane-$name.out"); FAIL=$(( FAIL + n ))
        done
    fi
    rm -rf "$CST_ROOT"
    echo "  (the CrowdSec page took $(( SECONDS - t0 )) s)"
}
cst_main
# <<< CrowdSec page

if [[ "${SMOKE_ONLY:-}" != crowdsec ]]; then
echo "Factory reset (last: it removes the accounts)"
cp "$ROOT/.env.example" "$WORK/.env.example"   # what the reset copies back over .env
_envset FLEET_ROLE hub; _envset DCS_ROLE hub
check "factory reset: done"              200 "$(auth_request POST /auth/factory-reset '{"confirm":"FACTORY_RESET"}' | status_of)"
check "factory reset: .env from the example" yes "$(grep -q '^PROXMOX_URL=$' "$WORK/.env" && echo yes || echo no)"
check "factory reset: the hub stays a hub" hub "$(grep -m1 '^FLEET_ROLE=' "$WORK/.env" | cut -d= -f2)"
check "factory reset: DCS_ROLE is kept too" hub "$(grep -m1 '^DCS_ROLE=' "$WORK/.env" | cut -d= -f2)"

fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
