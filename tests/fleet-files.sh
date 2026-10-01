#!/bin/bash
# =============================================================================
# fleet-files.sh — a VM stack's files are the hub's
#
# Two real listeners on loopback, a hub and a member (the "VM"), auth on. The member runs a stack
# the hub has no files for; the test checks that the hub takes the files over (adoption on a read,
# a pull, a sync), that a save on the hub reaches the member (push after compose, .env and files
# writes), that a rebuilt member gets its files back, that nothing but configuration travels, that
# a path cannot leave the stack folder, and that a member that is off still shows its files from
# the hub's copy.
#
# Usage: tests/fleet-files.sh   (exit status 0 = all passed; needs socat, curl, jq, python3)
# =============================================================================
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for t in socat curl jq python3; do command -v "$t" >/dev/null 2>&1 || { echo "skip: $t is not installed"; exit 0; }; done
# where Docker is absent (a CI container) the API would refuse to start: any command that answers stands in for Compose
if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
    DCS_FAKE_COMPOSE="$(mktemp "${TMPDIR:-/tmp}/dcs-fake-compose-XXXXXX")"; printf '#!/bin/sh\nexit 0\n' > "$DCS_FAKE_COMPOSE"; chmod +x "$DCS_FAKE_COMPOSE"
    export DOCKER_COMPOSE_CMD="$DCS_FAKE_COMPOSE"
fi
PASS=0; FAIL=0
check() { if [[ "$3" == "$2" ]]; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL + 1)); printf '  FAIL %s (expected %s, got %s)\n' "$1" "$2" "$3"; fi; }
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

W="$(mktemp -d "${TMPDIR:-/tmp}/dcs-ff-XXXXXX")"
HUB="$W/hub"; MEM="$W/member"
HP=$(free_port); MP=$(free_port); [[ "$MP" == "$HP" ]] && MP=$(free_port)
cleanup() {
    for d in "$HUB" "$MEM"; do [[ -f "$d/.data/api-server.pid" ]] && (cd "$d" && "$d/.scripts/api-server.sh" --stop >/dev/null 2>&1); done
    pkill -TERM -f -- "$W/" 2>/dev/null
    rm -rf "${W:?}"
}
trap cleanup EXIT

# install DIR PORT NAME — a minimal isolated installation that listens on PORT
install() {
    local d="$1" port="$2" name="$3"
    mkdir -p "$d/.scripts" "$d/.lib" "$d/.config" "$d/.data" "$d/logs" "$d/.api-auth" "$d/Stacks" "$d/vm-images"
    cp "$ROOT/.scripts/api-server.sh" "$ROOT/.scripts/api-dispatch.sh" "$d/.scripts/"; cp "$ROOT/compose.sh" "$ROOT/VERSION" "$d/"
    cp -r "$ROOT/.lib/." "$d/.lib/"; cp -r "$ROOT/.config/." "$d/.config/"; cp "$ROOT/vm-images/images.json" "$d/vm-images/"
    grep -vE '^(API_BIND|API_AUTH_ENABLED|API_INSECURE_NO_AUTH|API_TRUSTED_PROXIES|API_IP_WHITELIST|API_PORT|API_WORKERS|PROXMOX_|FLEET_SCAN_PORTS|SERVER_NAME|DOCKER_STACKS)' "$ROOT/.env.example" > "$d/.env"
    printf 'API_PORT=%s\nAPI_AUTH_ENABLED=true\nMETRICS_ENABLED=false\nDDNS_ENABLED=false\nSERVER_NAME=%s\nAPI_WORKERS=0\n' "$port" "$name" >> "$d/.env"
}
install "$HUB" "$HP" "Hub"
install "$MEM" "$MP" "Media VM"
# the member runs "demo": compose, .env and configuration travel; what it makes while it runs does not
mkdir -p "$MEM/Stacks/demo/config" "$MEM/Stacks/demo/data" "$MEM/Stacks/demo/logs"
printf 'services:\n  demo:\n    image: alpine:3\n    command: ["sleep","infinity"]\n' > "$MEM/Stacks/demo/docker-compose.yml"
printf 'DEMO_PORT=8080\n' > "$MEM/Stacks/demo/.env"
printf 'answer: 42\n' > "$MEM/Stacks/demo/config/app.yml"
printf 'binary\0data\n' > "$MEM/Stacks/demo/data/state.db"
printf 'a line\n' > "$MEM/Stacks/demo/logs/app.log"
printf '{}' > "$MEM/Stacks/demo/config/acme.json"
printf 'old\n' > "$MEM/Stacks/demo/docker-compose.yml.bak"
printf 'older\n' > "$MEM/Stacks/demo/docker-compose.yml.bak.20260101120000"
printf 'DOCKER_STACKS=demo\n' >> "$MEM/.env"

start() { (cd "$1" && setsid nohup "$1/.scripts/api-server.sh" --bind 127.0.0.1 --port "$2" > "$1/logs/listener.log" 2>&1 < /dev/null &); }
wait_up() { local p="$1"; for _ in $(seq 1 120); do curl -s -m 1 "http://127.0.0.1:$p/ping" 2>/dev/null | grep -q '"ok"' && return 0; sleep 0.25; done; return 1; }
start "$HUB" "$HP"; start "$MEM" "$MP"
wait_up "$HP" || { echo "  FAIL the hub did not come up"; cat "$HUB/logs/listener.log"; exit 1; }
wait_up "$MP" || { echo "  FAIL the member did not come up"; cat "$MEM/logs/listener.log"; exit 1; }

hub()    { local m="$1" p="$2" b="${3:-}"; curl -s -m 60 -X "$m" "http://127.0.0.1:$HP$p" -H "Authorization: Bearer ${HT:-}" -H 'Content-Type: application/json' ${b:+-d "$b"}; }
member() { local m="$1" p="$2" b="${3:-}"; curl -s -m 60 -X "$m" "http://127.0.0.1:$MP$p" -H "Authorization: Bearer ${MT:-}" -H 'Content-Type: application/json' ${b:+-d "$b"}; }
hub_code()    { local m="$1" p="$2" b="${3:-}"; curl -s -m 60 -o /dev/null -w '%{http_code}' -X "$m" "http://127.0.0.1:$HP$p" -H "Authorization: Bearer ${HT:-}" -H 'Content-Type: application/json' ${b:+-d "$b"}; }
member_code() { local m="$1" p="$2" b="${3:-}"; curl -s -m 60 -o /dev/null -w '%{http_code}' -X "$m" "http://127.0.0.1:$MP$p" -H "Authorization: Bearer ${MT:-}" -H 'Content-Type: application/json' ${b:+-d "$b"}; }
HT=$(curl -s -m 20 -X POST "http://127.0.0.1:$HP/auth/setup" -H 'Content-Type: application/json' -d '{"username":"admin","password":"correct horse battery"}' | jq -r '.token // empty')
MT=$(curl -s -m 20 -X POST "http://127.0.0.1:$MP/auth/setup" -H 'Content-Type: application/json' -d '{"username":"admin","password":"correct horse battery"}' | jq -r '.token // empty')
check "the hub has an admin"                        yes "$([[ ${#HT} -ge 32 ]] && echo yes || echo no)"
check "the member has an admin"                     yes "$([[ ${#MT} -ge 32 ]] && echo yes || echo no)"

echo "The member's files endpoint"
F=$(member GET /stacks/demo/files)
check "files: lists what travels"                   ".env config/app.yml docker-compose.yml" "$(jq -r '[.files[].path] | sort | join(" ")' <<< "$F" 2>/dev/null)"
check "files: content is the file, base64"          "answer: 42" "$(jq -r '.files[] | select(.path == "config/app.yml") | .content' <<< "$F" 2>/dev/null | base64 -d)"
check "files: a mode travels"                       "$(stat -c %a "$MEM/Stacks/demo/docker-compose.yml")" "$(jq -r '.files[] | select(.path == "docker-compose.yml") | .mode' <<< "$F" 2>/dev/null)"
check "files: unknown stack"                        404 "$(member_code GET /stacks/nope/files)"
check "files: a viewer may not read them"           401 "$(curl -s -m 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$MP/stacks/demo/files")"
B64=$(printf 'evil\n' | base64 -w0)
check "files: a path out of the folder refused"     400 "$(member_code POST /stacks/demo/files "{\"files\":[{\"path\":\"../evil.yml\",\"mode\":\"644\",\"content\":\"$B64\"}]}")"
check "files: …and nothing was written"             no  "$([[ -e "$MEM/Stacks/evil.yml" ]] && echo yes || echo no)"
check "files: a dot segment refused"                400 "$(member_code POST /stacks/demo/files "{\"files\":[{\"path\":\"config/./x.yml\",\"mode\":\"644\",\"content\":\"$B64\"}]}")"
check "files: an absolute path refused"             400 "$(member_code POST /stacks/demo/files "{\"files\":[{\"path\":\"/etc/passwd\",\"mode\":\"644\",\"content\":\"$B64\"}]}")"
ln -s /tmp "$MEM/Stacks/demo/escape"
check "files: a link out of the folder refused"     400 "$(member_code POST /stacks/demo/files "{\"files\":[{\"path\":\"escape/x.yml\",\"mode\":\"644\",\"content\":\"$B64\"}]}")"
rm -f "$MEM/Stacks/demo/escape"
check "files: an empty list refused"                400 "$(member_code POST /stacks/demo/files '{"files":[]}')"
check "files: bad base64 refused"                   400 "$(member_code POST /stacks/demo/files '{"files":[{"path":"config/x.yml","mode":"644","content":"***"}]}')"
R=$(member POST /stacks/demo/files "{\"files\":[{\"path\":\"config/extra.yml\",\"mode\":\"600\",\"content\":\"$B64\"}]}")
check "files: a write lands"                        "1 0" "$(jq -r '"\(.written) \(.removed)"' <<< "$R" 2>/dev/null)"
check "files: …with its mode"                       600 "$(stat -c %a "$MEM/Stacks/demo/config/extra.yml" 2>/dev/null)"
check "files: the same write again is a no-op"      "0 The files are already the same" "$(member POST /stacks/demo/files "{\"files\":[{\"path\":\"config/extra.yml\",\"mode\":\"600\",\"content\":\"$B64\"}]}" | jq -r '"\(.written) \(.message)"' 2>/dev/null)"

echo "The hub takes the member's files over"
JT=$(hub POST /fleet/join-tokens '{"ttl_hours":1}' | jq -r '.token // empty')
check "a join code"                                 yes "$([[ -n "$JT" ]] && echo yes || echo no)"
JOIN_OUT=$(cd "$MEM" && FLEET_IDENTITY_UUID=11111111-2222-3333-4444-555555555555 DCS_MEMBER_URL="http://127.0.0.1:$MP" "$MEM/.scripts/api-server.sh" --join-hub "http://127.0.0.1:$HP" "$JT" media-vm 2>&1)
check "the member joined"                           yes "$(grep -q '^✓ Joined' <<< "$JOIN_OUT" && echo yes || { echo no; tail -3 <<< "$JOIN_OUT" >&2; })"
MID=$(hub GET /fleet/members | jq -r '.members[0].id // empty')
check "one member"                                  media-vm "$MID"
check "the hub lists the VM's stack"                vm "$(hub GET /stacks | jq -r '.stacks[] | select(.name == "demo") | .placement' 2>/dev/null)"
# a stack that is deleted takes its routes along (on a member they live in the feed directory the hub reads)
member POST /stacks '{"name":"tmpstack"}' >/dev/null
mkdir -p "$MEM/.data/routes/tmpstack"; printf 'http:\n  routers:\n    x:\n      rule: "Host(`x.example.org`)"\n' > "$MEM/.data/routes/tmpstack/x.yml"
check "delete: a stack's routes go with it"          "true no" "$(member POST /stacks/tmpstack/delete | jq -r '.success' 2>/dev/null) $([[ -e "$MEM/.data/routes/tmpstack" ]] && echo yes || echo no)"
# a read of a stack the hub has no files for adopts them
rm -rf "${HUB:?}/Stacks/demo"
check "hub: a VM stack's compose reads through"     200 "$(hub_code GET /stacks/demo/compose)"
sleep 1
check "hub: …and its files were adopted"            yes "$([[ -f "$HUB/Stacks/demo/docker-compose.yml" && -f "$HUB/Stacks/demo/.env" && -f "$HUB/Stacks/demo/config/app.yml" ]] && echo yes || echo no)"
check "hub: the copy is the member's"               "$(cat "$MEM/Stacks/demo/docker-compose.yml")" "$(cat "$HUB/Stacks/demo/docker-compose.yml" 2>/dev/null)"
check "hub: runtime data did not travel"            no "$([[ -e "$HUB/Stacks/demo/data/state.db" || -e "$HUB/Stacks/demo/logs/app.log" || -e "$HUB/Stacks/demo/config/acme.json" || -e "$HUB/Stacks/demo/docker-compose.yml.bak" ]] && echo yes || echo no)"
check "hub: the next read is the hub's own copy"    "$(cat "$HUB/Stacks/demo/docker-compose.yml")" "$(hub GET /stacks/demo/compose | jq -r '.content' 2>/dev/null)"
check "hub: audit says the files were adopted"      yes "$(grep -q 'fleet_stack_adopted' "$HUB/.data/audit.jsonl" 2>/dev/null && echo yes || echo no)"

echo "A save on the hub reaches the member"
NEW=$'services:\n  demo:\n    image: alpine:3.20\n    command: ["sleep","infinity"]\n'
R=$(hub POST /stacks/demo/compose "$(jq -nc --arg c "$NEW" '{content: $c}')")
check "compose save: ok and pushed"                 "true vm media-vm true" "$(jq -r '"\(.success) \(.placement) \(.member) \(.pushed)"' <<< "$R" 2>/dev/null)"
check "compose save: the member has it"             "${NEW%$'\n'}" "$(cat "$MEM/Stacks/demo/docker-compose.yml")"
check "compose save: the hub kept a version"        yes "$(v=$(hub GET /stacks/demo/compose/history | jq -r '.versions | length' 2>/dev/null); [[ "$v" =~ ^[0-9]+$ && "$v" -ge 1 ]] && echo yes || echo no)"
R=$(hub POST /stacks/demo/env "$(jq -nc --arg c $'DEMO_PORT=9090\n' '{content: $c}')")
check "env save: ok and pushed"                     "true true" "$(jq -r '"\(.success) \(.pushed)"' <<< "$R" 2>/dev/null)"
check "env save: the member has it"                 "DEMO_PORT=9090" "$(cat "$MEM/Stacks/demo/.env")"
R=$(hub POST /stacks/demo/files "{\"files\":[{\"path\":\"config/hub-made.yml\",\"mode\":\"644\",\"content\":\"$B64\"}]}")
check "files save on the hub: written and pushed"   "1 true" "$(jq -r '"\(.written) \(.pushed)"' <<< "$R" 2>/dev/null)"
check "files save on the hub: the member has it"    evil "$(cat "$MEM/Stacks/demo/config/hub-made.yml" 2>/dev/null)"
check "hub: files of a VM stack are the hub's copy" yes "$(hub GET /stacks/demo/files | jq -e '[.files[].path] | index("config/hub-made.yml") != null' >/dev/null 2>&1 && echo yes || echo no)"

echo "Push and pull by hand"
rm -f "$MEM/Stacks/demo/docker-compose.yml" "$MEM/Stacks/demo/config/app.yml"
R=$(hub POST /stacks/demo/push)
check "push: the member gets its files back"        yes "$([[ -f "$MEM/Stacks/demo/docker-compose.yml" && -f "$MEM/Stacks/demo/config/app.yml" ]] && echo yes || echo no)"
check "push: the answer counts"                     yes "$(v=$(jq -r '.pushed' <<< "$R" 2>/dev/null); [[ "$v" =~ ^[0-9]+$ && "$v" -ge 2 ]] && echo yes || echo no)"
check "push: a hub stack is refused"                404 "$(hub_code POST /stacks/nope/push)"
printf 'made: on-the-vm\n' > "$MEM/Stacks/demo/config/vm-made.yml"
R=$(hub POST /stacks/demo/pull)
check "pull: the hub gets what the VM made"         "made: on-the-vm" "$(cat "$HUB/Stacks/demo/config/vm-made.yml" 2>/dev/null)"
check "pull: the answer counts"                     yes "$(v=$(jq -r '.written' <<< "$R" 2>/dev/null); [[ "$v" =~ ^[0-9]+$ && "$v" -ge 1 ]] && echo yes || echo no)"
check "pull: the same again is nothing"             "The hub already had these files" "$(hub POST /stacks/demo/pull | jq -r '.message' 2>/dev/null)"
rm -f "$MEM/Stacks/demo/config/vm-made.yml"
hub POST /stacks/demo/pull >/dev/null
check "pull: a file the VM lost goes on the hub too" no "$([[ -e "$HUB/Stacks/demo/config/vm-made.yml" ]] && echo yes || echo no)"
R=$(hub POST "/fleet/members/$MID/sync" '{}')
check "sync: pulls every stack of the member"       "true pull demo" "$(jq -r '"\(.success) \(.direction) \(.stacks | map(.name) | join(" "))"' <<< "$R" 2>/dev/null)"
printf 'from: the-hub\n' > "$HUB/Stacks/demo/config/hub-hand.yml"
R=$(hub POST "/fleet/members/$MID/sync" '{"direction":"push"}')
check "sync: push sends the hub's copies"           "true push" "$(jq -r '"\(.success) \(.direction)"' <<< "$R" 2>/dev/null)"
check "sync: …the member has the hand-made file"    "from: the-hub" "$(cat "$MEM/Stacks/demo/config/hub-hand.yml" 2>/dev/null)"
check "sync: unknown member"                        404 "$(hub_code POST /fleet/members/nobody/sync '{}')"
check "sync: a viewer may not"                      401 "$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$HP/fleet/members/$MID/sync" -H 'Content-Type: application/json' -d '{}')"

echo "A member that is off"
(cd "$MEM" && "$MEM/.scripts/api-server.sh" --stop >/dev/null 2>&1)
for _ in $(seq 1 40); do curl -s -m 1 "http://127.0.0.1:$MP/ping" >/dev/null 2>&1 || break; sleep 0.25; done
check "off: the hub still shows the compose"        "$(cat "$HUB/Stacks/demo/docker-compose.yml")" "$(hub GET /stacks/demo/compose | jq -r '.content' 2>/dev/null)"
check "off: the hub still shows the .env"           "DEMO_PORT=9090" "$(hub GET /stacks/demo/env | jq -r '.raw' 2>/dev/null)"
R=$(hub POST /stacks/demo/compose "$(jq -nc --arg c "$NEW" '{content: $c}')")
check "off: a save is kept on the hub"              "true false" "$(jq -r '"\(.success) \(.pushed)"' <<< "$R" 2>/dev/null)"
check "off: …and says the VM did not take it"       yes "$(jq -r '.message' <<< "$R" 2>/dev/null | grep -q 'did not take it' && echo yes || echo no)"
check "off: a push says why"                        502 "$(hub_code POST /stacks/demo/push)"


echo "Deleting a stack whose VM is gone"
# the member is off and Proxmox is not linked here, so the hub cannot ask about the guest: Delete forgets the stack
R=$(hub POST /stacks/demo/delete)
check "forget: the delete answers"                  "true true" "$(jq -r '"\(.success) \(.forgotten)"' <<< "$R" 2>/dev/null)"
check "forget: the hub's copy is gone"              no "$([[ -e "$HUB/Stacks/demo" ]] && echo yes || echo no)"
check "forget: the placement is gone"               0 "$(hub GET /fleet/members | jq -r '[.members[] | select(.id == "'"$MID"'") | (.stacks // [])[] | select(. == "demo")] | length' 2>/dev/null)"
check "forget: audited"                             yes "$(grep -q 'fleet_stack_forgotten' "$HUB/.data/audit.jsonl" 2>/dev/null && echo yes || echo no)"

echo "A member that leaves takes everything of it along"
# the last update round names this member and one that is long gone: the Updates page reads only who is still in the fleet
printf '{"status":"done","at":1,"started_at":1,"finished_at":2,"hub_version":"9.9.9","results":[{"id":"%s","success":false,"message":"did not answer"},{"id":"gone-vm","success":false,"message":"did not answer"}],"updated":0,"failed":2}\n' "$MID" > "$HUB/.data/fleet-update-last.json"
V=$(hub GET /fleet/versions)
check "round: a member that is gone is not in the report" "$MID 1" "$(jq -r '"\(.last_round.results | map(.id) | join(" ")) \(.last_round.failed)"' <<< "$V" 2>/dev/null)"
check "leave: the member had a relay token"          yes "$(jq -e --arg id "$MID" '.[$id] | length >= 24' "$HUB/.data/fleet-relay.json" >/dev/null 2>&1 && echo yes || echo no)"
check "leave: the hub held a session for it"         yes "$([[ -n "$(ls "$HUB/.data/fleet-sessions/$MID".* 2>/dev/null)" ]] && echo yes || echo no)"
check "leave: removed from the fleet"                true "$(hub DELETE "/fleet/members/$MID" | jq -r '.success' 2>/dev/null)"
check "leave: its relay token is gone"               no "$(jq -e --arg id "$MID" 'has($id)' "$HUB/.data/fleet-relay.json" >/dev/null 2>&1 && echo yes || echo no)"
check "leave: its session and stamps are gone"       0 "$(ls "$HUB/.data/fleet-sessions/$MID".* "$HUB/.data/fleet-pull/$MID--"* 2>/dev/null | wc -l)"
check "leave: the round's report went with it"       null "$(hub GET /fleet/versions | jq -r '.last_round | tostring' 2>/dev/null)"
check "leave: …on disk too"                          no "$([[ -e "$HUB/.data/fleet-update-last.json" ]] && echo yes || echo no)"

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
