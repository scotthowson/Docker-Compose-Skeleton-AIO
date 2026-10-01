#!/bin/bash
# =============================================================================
# fleet-files.sh — a VM stack's files are the hub's
#
# Two real listeners on loopback, a hub and a member (the "VM"), auth on. The member runs a stack
# the hub has no files for; the test checks that the hub takes the files over (adoption on a read,
# a pull, a sync), that a save on the hub reaches the member (push after compose, .env and files
# writes), that a rebuilt member gets its files back, that nothing but configuration travels, that
# a path cannot leave the stack folder, and that a member that is off still shows its files from
# the hub's copy. The VM's App-Data is shown on the hub through a link to a mount: ssh, sshfs and the
# unmount helper are stood in for (no FUSE, no second machine), so what is checked is everything
# around the mount itself — when it is made, what the link points at, what a delete leaves alone.
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
    # one small template on both: a deploy the hub forwards into the member
    mkdir -p "$d/.templates/tiny"
    printf 'services:\n  tiny:\n    image: alpine:3\n    container_name: tiny\n    command: ["sleep","infinity"]\n' > "$d/.templates/tiny/docker-compose.yml"
    printf '{"name":"tiny","description":"a test template","category":"other","tags":[],"variables":[]}\n' > "$d/.templates/tiny/template.json"
}
install "$HUB" "$HP" "Hub"
install "$MEM" "$MP" "Media VM"
# the hub's view of a VM's App-Data: ssh runs the far side's command here, sshfs writes a line into a mount table of the
# test's own (and fails on demand), the unmount helper takes the line out again
FAKE="$W/fake"; VMDATA="$W/vm-data"; mkdir -p "$FAKE" "$HUB/.data/fleet-ssh"; : > "$FAKE/mountinfo"; printf 'not a real key\n' > "$HUB/.data/fleet-ssh/id_ed25519"
cat > "$FAKE/ssh" <<'FAKESSH'
#!/bin/bash
# the last word is the command for the far side; what it finds of sftp-server and sudo depends on this machine, so both are pinned
bash -c "${@: -1}" | sed -e 's#^sftp=.*#sftp=/usr/lib/openssh/sftp-server#' -e 's#^sudo=.*#sudo=#'
FAKESSH
cat > "$FAKE/sshfs" <<'FAKESSHFS'
#!/bin/bash
d="$(dirname "$0")"; mp="${@: -1}"; remote="${@: -2:1}"
printf '%s\n' "$*" >> "$d/sshfs.log"
[[ -f "$d/sshfs-fail" ]] && { echo "read: Connection reset by peer" >&2; exit 1; }
[[ -d "$mp" && -w "$mp" ]] || { echo "fusermount3: user has no write access to mountpoint $mp" >&2; exit 1; }
printf '900 1 0:90 / %s rw,nosuid,nodev,relatime - fuse.sshfs %s rw,user_id=0,group_id=0\n' "$mp" "$remote" >> "$d/mountinfo"
FAKESSHFS
cat > "$FAKE/fusermount3" <<'FAKEFUM'
#!/bin/bash
d="$(dirname "$0")"; mp="${@: -1}"
awk -v mp="$mp" '$5 != mp' "$d/mountinfo" > "$d/mountinfo.new" && mv -f "$d/mountinfo.new" "$d/mountinfo"
FAKEFUM
chmod +x "$FAKE/ssh" "$FAKE/sshfs" "$FAKE/fusermount3"
# off until its own section below: after a start or a deploy it forwards, the hub looks for the VM's App-Data in the
# background for a few minutes, at moments of its own choosing — the checks before that section must not meet it
printf 'FLEET_APPDATA_MOUNT=false\n' >> "$HUB/.env"
printf 'FLEET_SSH_CMD=%s\nFLEET_SSHFS_CMD=%s\nFLEET_FUSERMOUNT_CMD=%s\nFLEET_MOUNTINFO=%s\nFLEET_APPDATA_RUNNER=direct\nFLEET_APPDATA_INSTALL=false\nFLEET_MOUNT_DIR=%s\n' \
    "$FAKE/ssh" "$FAKE/sshfs" "$FAKE/fusermount3" "$FAKE/mountinfo" "$VMDATA" >> "$HUB/.env"
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
check "hub: a note says where the stack and its data are" yes "$(grep -q 'runs in the VM "media-vm"' "$HUB/Stacks/demo/RUNS-IN-A-VM.txt" 2>/dev/null && grep -q 'App-Data' "$HUB/Stacks/demo/RUNS-IN-A-VM.txt" && echo yes || echo no)"
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
check "hub: the note is not one of the files"        no "$(hub GET /stacks/demo/files | jq -e '[.files[].path] | index("RUNS-IN-A-VM.txt") != null' >/dev/null 2>&1 && echo yes || echo no)"
check "hub: …and never reaches the VM"              no "$([[ -e "$MEM/Stacks/demo/RUNS-IN-A-VM.txt" ]] && echo yes || echo no)"

echo "A deploy into the VM is in the hub's history"
D=$(hub POST /templates/tiny/deploy '{"target_stack":"demo","auto_start":false,"routes":false}')
check "deploy: forwarded into the VM"               "true demo" "$(jq -r '"\(.success) \(.target_stack)"' <<< "$D" 2>/dev/null)"
check "deploy: the VM's compose has the service"    yes "$(grep -q '^  tiny:' "$MEM/Stacks/demo/docker-compose.yml" && echo yes || echo no)"
check "deploy: the hub's copy followed"             yes "$(grep -q '^  tiny:' "$HUB/Stacks/demo/docker-compose.yml" 2>/dev/null && echo yes || echo no)"
check "deploy: in the hub's Deploy history"         "deploy tiny demo $MID" "$(hub GET /templates/deploy-history | jq -r '.history[0] | "\(.action) \(.template) \(.target_stack) \(.member)"' 2>/dev/null)"
U=$(hub POST /templates/tiny/undeploy '{"target_stack":"demo","services":["tiny"],"remove_containers":false}')
check "undeploy: forwarded"                         true "$(jq -r '.success' <<< "$U" 2>/dev/null)"
check "undeploy: in the hub's Deploy history"       "undeploy tiny demo $MID" "$(hub GET /templates/deploy-history | jq -r '.history[0] | "\(.action) \(.template) \(.target_stack) \(.member)"' 2>/dev/null)"

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

echo "The VM's App-Data is shown on the hub"
# function level on the hub's own folder, with the hub's settings
_hublib() { ( cd "$HUB" && set -a && . "$HUB/.env" && set +a && source "$HUB/.scripts/api-server.sh" >/dev/null 2>&1; _audit_log() { :; }; "$@" ); }
_mounts() { grep -c " $VMDATA/demo " "$FAKE/mountinfo" 2>/dev/null; }
sed -i '/^FLEET_APPDATA_MOUNT=false$/d' "$HUB/.env"   # on from here
A=$(member GET /stacks/demo/appdata)
check "appdata: a server names its own folder"      "local $MEM/Stacks/demo/App-Data false" "$(jq -r '"\(.placement) \(.path) \(.exists)"' <<< "$A" 2>/dev/null)"
check "appdata: nothing to mount on the server that runs the stack" 400 "$(member_code POST /stacks/demo/appdata/mount)"
check "appdata: unknown stack"                      404 "$(hub_code GET /stacks/nope/appdata)"
check "appdata: a viewer may not"                   401 "$(curl -s -m 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$HP/stacks/demo/appdata")"
A=$(hub GET /stacks/demo/appdata)
check "appdata: the hub answers for a VM's stack"   "vm $MID Stacks/demo/VM-App-Data false" "$(jq -r '"\(.placement) \(.member) \(.link) \(.mounted)"' <<< "$A" 2>/dev/null)"
# the stack has no App-Data in the VM yet: Mount says so, and so does the folder the link shows
R=$(hub POST /stacks/demo/appdata/mount)
check "appdata: no App-Data in the VM yet is said"  yes "$(jq -r '.message // .error' <<< "$R" 2>/dev/null | grep -q 'has no App-Data in media-vm yet' && echo yes || echo no)"
check "appdata: …the state is waiting"              "waiting false" "$(hub GET /stacks/demo/appdata | jq -r '"\(.state) \(.mounted)"' 2>/dev/null)"
check "appdata: …the link shows why"                yes "$([[ -L "$HUB/Stacks/demo/VM-App-Data" ]] && grep -q 'has no App-Data in media-vm yet' "$HUB/Stacks/demo/VM-App-Data/NOT-MOUNTED.txt" 2>/dev/null && echo yes || echo no)"
# (the folder and its file are read-only; root, which the Debian job runs as, writes past any mode, so the modes are what is checked)
check "appdata: …and nothing can be written there"  "555 444" "$(stat -c %a "$VMDATA/.not-mounted/demo" 2>/dev/null) $(stat -c %a "$VMDATA/.not-mounted/demo/NOT-MOUNTED.txt" 2>/dev/null)"
# the VM makes its App-Data; an App-Data someone made by hand in the hub's copy holds nothing
mkdir -p "$MEM/Stacks/demo/App-Data/Jellyfin/config" "$HUB/Stacks/demo/App-Data/Jellyfin/config" "$HUB/Stacks/demo/App-Data/Jellyfin/cache"
printf '<xml/>\n' > "$MEM/Stacks/demo/App-Data/Jellyfin/config/system.xml"
R=$(hub POST /stacks/demo/appdata/mount)
check "appdata: Mount mounts"                       "true mounted true" "$(jq -r '"\(.success) \(.state) \(.mounted)"' <<< "$R" 2>/dev/null)"
check "appdata: …from the VM's own folder"          "dcs@127.0.0.1:$MEM/Stacks/demo/App-Data account" "$(jq -r '"\(.remote) \(.access)"' <<< "$R" 2>/dev/null)"
check "appdata: …sshfs got the far side's server and the hub's key" yes "$(tail -1 "$FAKE/sshfs.log" | grep -q "sftp_server=/usr/lib/openssh/sftp-server .*IdentityFile=$HUB/.data/fleet-ssh/id_ed25519\|IdentityFile=$HUB/.data/fleet-ssh/id_ed25519 .*sftp_server=/usr/lib/openssh/sftp-server" && echo yes || echo no)"
check "appdata: …a far side that goes away takes the mount with it" yes "$(tail -1 "$FAKE/sshfs.log" | grep -q 'ServerAliveInterval=5 .*ServerAliveCountMax=3' && tail -1 "$FAKE/sshfs.log" | grep -q 'auto_unmount' && echo yes || echo no)"
check "appdata: the link points at the mount"       "$VMDATA/demo" "$(readlink "$HUB/Stacks/demo/VM-App-Data" 2>/dev/null)"
check "appdata: the mount is outside the DCS folder" no "$([[ "$VMDATA/" == "$HUB/"* ]] && echo yes || echo no)"
check "appdata: the empty App-Data made by hand is gone" no "$([[ -e "$HUB/Stacks/demo/App-Data" ]] && echo yes || echo no)"
check "appdata: the note names the link"            yes "$(grep -q '^VM-App-Data in this folder is that App-Data, live' "$HUB/Stacks/demo/RUNS-IN-A-VM.txt" 2>/dev/null && echo yes || echo no)"
check "appdata: audited"                            yes "$(grep -q 'fleet_appdata_mounted' "$HUB/.data/audit.jsonl" 2>/dev/null && echo yes || echo no)"
check "appdata: Mount again is the same mount"      "true 1" "$(hub POST /stacks/demo/appdata/mount | jq -r '.success' 2>/dev/null) $(_mounts)"
check "appdata: the link is not one of the stack's files" no "$(hub GET /stacks/demo/files | jq -e '[.files[].path] | map(select(test("VM-App-Data"))) | length > 0' >/dev/null 2>&1 && echo yes || echo no)"
hub POST /stacks/demo/pull >/dev/null
check "appdata: a pull leaves the link alone"       "$VMDATA/demo" "$(readlink "$HUB/Stacks/demo/VM-App-Data" 2>/dev/null)"
hub POST /stacks/demo/push >/dev/null
check "appdata: a push never carries it into the VM" no "$([[ -e "$MEM/Stacks/demo/VM-App-Data" || -L "$MEM/Stacks/demo/VM-App-Data" ]] && echo yes || echo no)"
# an App-Data in the hub's copy that holds a file (what a stack had on the hub before it moved into its VM) is not touched
mkdir -p "$HUB/Stacks/demo/App-Data/Old"; printf 'kept\n' > "$HUB/Stacks/demo/App-Data/Old/data.db"
_hublib _fleet_appdata_tidy demo
check "appdata: an App-Data with a file in it stays" kept "$(cat "$HUB/Stacks/demo/App-Data/Old/data.db" 2>/dev/null)"
rm -rf "${HUB:?}/Stacks/demo/App-Data"
# unmounted on purpose: it stays down until Mount
R=$(hub POST /stacks/demo/appdata/unmount)
check "appdata: Unmount takes it down"              "true held false 0" "$(jq -r '"\(.success) \(.state) \(.mounted)"' <<< "$R" 2>/dev/null) $(_mounts)"
check "appdata: …the link shows why"                yes "$(grep -q 'unmounted on purpose' "$HUB/Stacks/demo/VM-App-Data/NOT-MOUNTED.txt" 2>/dev/null && echo yes || echo no)"
check "appdata: …the mountpoint is read-only meanwhile" 555 "$(stat -c %a "$VMDATA/demo" 2>/dev/null)"
_hublib _fleet_appdata_round
check "appdata: …the hub's own round leaves it down" "held 0" "$(hub GET /stacks/demo/appdata | jq -r '.state' 2>/dev/null) $(_mounts)"
check "appdata: Mount brings it back"               "true 1" "$(hub POST /stacks/demo/appdata/mount | jq -r '.success' 2>/dev/null) $(_mounts)"
# the far side goes away (the mount with it): the hub's round makes it again
"$FAKE/fusermount3" -uz "$VMDATA/demo"
check "appdata: a mount that went away is seen"     "waiting false" "$(hub GET /stacks/demo/appdata | jq -r '"\(.state) \(.mounted)"' 2>/dev/null)"
_hublib _fleet_appdata_round
check "appdata: the round mounts it again"          "mounted 1" "$(hub GET /stacks/demo/appdata | jq -r '.state' 2>/dev/null) $(_mounts)"
# a deploy the hub forwards into the VM brings the mount by itself, a moment later (nothing is started: auto_start is off)
"$FAKE/fusermount3" -uz "$VMDATA/demo"
hub POST /templates/tiny/deploy '{"target_stack":"demo","auto_start":false,"routes":false}' >/dev/null
for _ in $(seq 1 40); do [[ "$(_mounts)" == 1 ]] && break; sleep 0.5; done
check "appdata: a deploy into the VM brings the mount by itself" "1 mounted" "$(_mounts) $(hub GET /stacks/demo/appdata | jq -r '.state' 2>/dev/null)"
hub POST /templates/tiny/undeploy '{"target_stack":"demo","services":["tiny"],"remove_containers":false}' >/dev/null
for _ in $(seq 1 20); do [[ -e "$HUB/.data/fleet-appdata/demo.soon" ]] || break; sleep 0.5; done
check "appdata: …and nobody keeps looking once it is there" no "$([[ -e "$HUB/.data/fleet-appdata/demo.soon" ]] && echo yes || echo no)"
# a VM that stops answering: nothing is tried and nothing is spaced out, so its App-Data is back with the first round after the VM is
"$FAKE/fusermount3" -uz "$VMDATA/demo"
_reach() { ( cd "$HUB" && set -a && . "$HUB/.env" && set +a && source "$HUB/.scripts/api-server.sh" >/dev/null 2>&1; _fleet_update --arg id "$MID" --argjson r "$1" '.members = [.members[] | if .id == $id then .reachable = $r else . end]' ); }
_reach false; N0=$(wc -l < "$FAKE/sshfs.log"); _hublib _fleet_appdata_round
check "appdata: a VM that does not answer is said, and not tried" "waiting yes $N0 no" "$(hub GET /stacks/demo/appdata | jq -r '.state' 2>/dev/null) $(hub GET /stacks/demo/appdata | jq -r '.reason' 2>/dev/null | grep -q 'is not answering the hub' && echo yes || echo no) $(wc -l < "$FAKE/sshfs.log") $([[ -e "$HUB/.data/fleet-appdata/demo.retry" ]] && echo yes || echo no)"
_reach true; _hublib _fleet_appdata_round
check "appdata: …it answers again: the next round mounts" "mounted 1" "$(hub GET /stacks/demo/appdata | jq -r '.state' 2>/dev/null) $(_mounts)"
# a mount that fails says the mount helper's own words, and is not hammered: the next automatic try waits
"$FAKE/fusermount3" -uz "$VMDATA/demo"; : > "$FAKE/sshfs-fail"
R=$(hub POST /stacks/demo/appdata/mount)
check "appdata: a mount that fails says why"        yes "$(jq -r '.message // .error' <<< "$R" 2>/dev/null | grep -q 'Connection reset by peer' && echo yes || echo no)"
check "appdata: …409, the state is unavailable"     "409 unavailable" "$(hub_code POST /stacks/demo/appdata/mount) $(hub GET /stacks/demo/appdata | jq -r '.state' 2>/dev/null)"
N0=$(wc -l < "$FAKE/sshfs.log"); _hublib _fleet_appdata_round; _hublib _fleet_appdata_round
check "appdata: …the round does not try again at once" "$N0" "$(wc -l < "$FAKE/sshfs.log")"
rm -f "$FAKE/sshfs-fail"
check "appdata: Mount does, and it is back"         "true 1" "$(hub POST /stacks/demo/appdata/mount | jq -r '.success' 2>/dev/null) $(_mounts)"
# a folder of the hub's own in the link's place is left alone
hub POST /stacks/demo/appdata/unmount >/dev/null; rm -f "$HUB/Stacks/demo/VM-App-Data"; mkdir -p "$HUB/Stacks/demo/VM-App-Data"; printf 'mine\n' > "$HUB/Stacks/demo/VM-App-Data/own.txt"
R=$(hub POST /stacks/demo/appdata/mount)
check "appdata: a folder of that name is left alone" "mine yes" "$(cat "$HUB/Stacks/demo/VM-App-Data/own.txt" 2>/dev/null) $(jq -r '.message // .error' <<< "$R" 2>/dev/null | grep -q 'not the link DCS makes' && echo yes || echo no)"
rm -rf "${HUB:?}/Stacks/demo/VM-App-Data"
check "appdata: …moved away, Mount links again"     "true $VMDATA/demo" "$(hub POST /stacks/demo/appdata/mount | jq -r '.success' 2>/dev/null) $(readlink "$HUB/Stacks/demo/VM-App-Data" 2>/dev/null)"
# switched off in .env: everything of it goes, and comes back when it is switched on
printf 'FLEET_APPDATA_MOUNT=false\n' >> "$HUB/.env"
check "appdata: off in .env is said"                "off false" "$(hub GET /stacks/demo/appdata | jq -r '"\(.state) \(.enabled)"' 2>/dev/null)"
check "appdata: …Mount is refused"                  409 "$(hub_code POST /stacks/demo/appdata/mount)"
_hublib _fleet_appdata_round
check "appdata: …the round takes mount and link away" "0 no no" "$(_mounts) $([[ -L "$HUB/Stacks/demo/VM-App-Data" ]] && echo yes || echo no) $([[ -e "$VMDATA/demo" ]] && echo yes || echo no)"
sed -i '/^FLEET_APPDATA_MOUNT=false$/d' "$HUB/.env"
_hublib _fleet_appdata_round
check "appdata: on again, the round mounts"         "mounted 1 $VMDATA/demo" "$(hub GET /stacks/demo/appdata | jq -r '.state' 2>/dev/null) $(_mounts) $(readlink "$HUB/Stacks/demo/VM-App-Data" 2>/dev/null)"
# whatever is below a mountpoint is never removed: a file stands in for the VM's data showing through
mkdir -p "$VMDATA/ghost"; printf 'the VM'"'"'s\n' > "$VMDATA/ghost/library.db"; printf '900 1 0:91 / %s rw - fuse.sshfs x rw\n' "$VMDATA/ghost" >> "$FAKE/mountinfo"
_hublib _fleet_appdata_release ghost forget
check "appdata: forgetting never removes below the mountpoint" "the VM's" "$(cat "$VMDATA/ghost/library.db" 2>/dev/null)"
chmod 755 "$VMDATA/ghost" 2>/dev/null; rm -rf "${VMDATA:?}/ghost"

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
check "forget: the mount of its App-Data went first" "0 no no" "$(_mounts) $([[ -e "$VMDATA/demo" ]] && echo yes || echo no) $([[ -e "$HUB/.data/fleet-appdata/demo.json" ]] && echo yes || echo no)"
check "forget: the VM's data is where it was"       "<xml/>" "$(cat "$MEM/Stacks/demo/App-Data/Jellyfin/config/system.xml" 2>/dev/null)"

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

echo "The hub's DNS follows the VMs' routes"
# function level, with the Cloudflare calls stood in for: which hosts lose their record when the routes file is rewritten
printf '{"members":[{"id":"vmx","name":"vmx","url":"http://127.0.0.1:1","reachable":false,"stacks":[]},{"id":"vmy","name":"vmy","url":"http://127.0.0.1:1","reachable":true,"stacks":[]}],"join_tokens":[],"hub":null}\n' > "$W/fleet-dns.json"
_departed() {   # OLD MERGED -> the hosts whose record would be removed
    local _old="$1" _new="$2"; : > "$W/dns-del"
    ( set --; cd "$HUB" && export FLEET_FILE="$W/fleet-dns.json" && source "$HUB/.scripts/api-server.sh" >/dev/null 2>&1
      _find_cf_token() { echo tok; }; _fleet_domain() { echo example.org; }; _fleet_hub_hosts_json() { echo '["hubown.example.org"]'; }
      _cloudflare_delete_dns() { printf '%s ' "$1" >> "$W/dns-del"; }; _audit_log() { :; }
      _fleet_routes_departed "$_old" "$_new" ) >/dev/null 2>&1
    cat "$W/dns-del"
}
_r() { jq -nc --arg r "$1" '{http: {routers: ($r | split(" ") | map(select(length > 0) | split("=")) | map({key: .[0], value: {rule: ("Host(`" + .[1] + "`)")}}) | from_entries)}}'; }
_o() { _r "$1" | jq -c '.http.routers | with_entries(.value = .value.rule)'; }
check "dns: a renamed route lets go of the old host" "watch " "$(_departed "$(_o 'vmy-jf-dcs=watch.example.org')" "$(_r 'vmy-jf-dcs=jellyfin.example.org')")"
check "dns: an unchanged route keeps its record"     "" "$(_departed "$(_o 'vmy-jf-dcs=watch.example.org')" "$(_r 'vmy-jf-dcs=watch.example.org')")"
check "dns: a removed app's host goes"               "gone " "$(_departed "$(_o 'vmy-a-dcs=gone.example.org vmy-b-dcs=stay.example.org')" "$(_r 'vmy-b-dcs=stay.example.org')")"
check "dns: a member that left takes its hosts"      "left " "$(_departed "$(_o 'old-vm-a-dcs=left.example.org')" "$(_r '')")"
check "dns: a VM that is only off keeps its record"  "" "$(_departed "$(_o 'vmx-a-dcs=keep.example.org')" "$(_r '')")"
check "dns: a host another route took over stays"    "" "$(_departed "$(_o 'vmy-a-dcs=app.example.org')" "$(_r 'vmy-b-dcs=app.example.org')")"
check "dns: a host the hub serves itself stays"      "" "$(_departed "$(_o 'vmy-a-dcs=hubown.example.org')" "$(_r '')")"

echo "A stack in a VM joins the proxy network"
# a third install that is a member of a hub, driven over stdin with a docker that only records what it is asked: a
# template with a port is deployed, the service joins "proxy" and the network is made when it is missing
NODE="$W/node"; install "$NODE" 1 "Node"; mkdir -p "$NODE/Stacks/demo" "$NODE/fake" "$NODE/.templates/webby"
printf 'services:\n  demo:\n    image: alpine:3\n' > "$NODE/Stacks/demo/docker-compose.yml"
printf 'services:\n  webby:\n    image: alpine:3\n    container_name: webby\n    ports:\n      - "18080:80"\n' > "$NODE/.templates/webby/docker-compose.yml"
printf '{"name":"webby","description":"a test template","category":"other","tags":[],"variables":[]}\n' > "$NODE/.templates/webby/template.json"
sed -i '/^PROXY_DOMAIN=/d;/^TRAEFIK_DOMAIN=/d' "$NODE/.env"; printf 'PROXY_DOMAIN=lab.test\n' >> "$NODE/.env"
printf '{"members":[],"join_tokens":[],"hub":{"url":"http://127.0.0.1:1","name":"hub"}}\n' > "$NODE/.data/fleet.json"
cat > "$NODE/fake/docker" <<'FAKEDOCKER'
#!/bin/sh
st="$(dirname "$0")"; root="$(cd "$st/.." && pwd)"
case "$*" in
    "compose version"*) echo "Docker Compose version v2.99.0"; exit 0 ;;
    *"network inspect proxy"*) [ -f "$st/proxy-net" ] && exit 0; exit 1 ;;
    *"network create"*) : > "$st/proxy-net"; echo "$*" >> "$st/calls"; exit 0 ;;
    # the container "webby" of the stack "demo", for a nuke: its Compose labels, what is bound into it, who else there is
    inspect*compose.project.working_dir*) echo "$root/Stacks/demo" ;;
    inspect*compose.service*) echo webby ;;
    inspect*'compose.project"'*) echo demo ;;
    inspect*.Config.Image*) echo alpine:3 ;;
    inspect*'"bind"'*webby) printf '%s\n' "$root/Stacks/demo/App-Data/Webby/config/nested" "$root/Stacks/demo/App-Data/Webby/config" "$root/Stacks/demo/App-Data/WebbyData" /var/run/docker.sock /srv/media ;;
    inspect*'"bind"'*other) printf '%s\t' "$root/Stacks/demo/App-Data/Shared" ;;
    inspect*'"volume"'*) ;;
    "ps -a --format {{.Names}}") echo webby; echo other ;;
    compose*" up "*|compose*" rm "*|compose*" pull "*) echo "$*" >> "$st/calls"; exit 0 ;;
    *) exit 0 ;;
esac
FAKEDOCKER
chmod +x "$NODE/fake/docker"
ND=$(printf 'POST /templates/webby/deploy HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s' 42 '{"target_stack":"demo","auto_start":false}' | env PATH="$NODE/fake:$PATH" DOCKER_COMPOSE_CMD="docker compose" DCS_API_EFFECTIVE_AUTH=false DCS_API_EFFECTIVE_BIND=127.0.0.1 "$NODE/.scripts/api-server.sh" --handle-request 2>/dev/null | sed -n '/^\r*$/,$p' | sed '1d')
check "proxy: the deploy went through"              true "$(jq -r '.success' <<< "$ND" 2>/dev/null)"
check "proxy: the route is in the feed directory"   'Host(`webby.lab.test`)' "$(grep -o 'Host([^)]*)' "$NODE/.data/routes/demo/webby.yml" 2>/dev/null | head -1)"
check "proxy: the network was made, with Compose's label" yes "$(grep -q -- '--label com.docker.compose.network=proxy' "$NODE/fake/calls" 2>/dev/null && echo yes || echo no)"
check "proxy: the service joins it"                 yes "$(awk '/^  webby:/{f=1} f && /- proxy/{print "yes"; exit}' "$NODE/Stacks/demo/docker-compose.yml" | grep -q yes && echo yes || echo no)"
check "proxy: the compose declares it external"     yes "$(grep -A3 '^networks:' "$NODE/Stacks/demo/docker-compose.yml" | tr -d '\n' | grep -q 'proxy:.*name: proxy.*external: true' && echo yes || echo no)"

echo "Nuke & reinstall finds the stack's own App-Data"
# the compose file says ./App-Data/… (what a template leaves) and .env keeps APP_DATA_DIR at its default ./App-Data: both
# mean the stack's folder. The same container also binds a folder one level down, a folder inside one it already binds,
# a folder another container shares, the Docker socket and a media folder outside: only what is the stack's own App-Data
# may be emptied, each folder once.
_node() { local m="$1" p="$2" b="${3:-}"; printf '%s %s HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s' "$m" "$p" "${#b}" "$b" | env PATH="$NODE/fake:$PATH" DOCKER_COMPOSE_CMD="docker compose" DCS_API_EFFECTIVE_AUTH=false DCS_API_EFFECTIVE_BIND=127.0.0.1 "$NODE/.scripts/api-server.sh" --handle-request 2>/dev/null | sed -n '/^\r*$/,$p' | sed '1d'; }
NA="$NODE/Stacks/demo/App-Data"
printf 'services:\n  webby:\n    image: alpine:3\n    container_name: webby\n    volumes:\n      - ./App-Data/Webby/config:/config\n      - ${APP_DATA_DIR:-./App-Data}/Webby/cache:/cache\n      - ./App-Data/Shared:/shared\n      - /srv/media:/media\n' > "$NODE/Stacks/demo/docker-compose.yml"
mkdir -p "$NA/Webby/config/nested" "$NA/Webby/cache" "$NA/WebbyData" "$NA/Shared"; printf 'old settings\n' > "$NA/Webby/config/app.conf"; printf 'c\n' > "$NA/Webby/cache/blob"; printf 'd\n' > "$NA/WebbyData/db"; printf 'theirs\n' > "$NA/Shared/keep.txt"
check "nuke: the node keeps APP_DATA_DIR at ./App-Data" './App-Data' "$(sed -n 's/^APP_DATA_DIR=//p' "$NODE/.env" | tr -d '"' | tail -1)"
P=$(_node GET /containers/webby/reset)
check "nuke: the preview names the stack's own folders, each once" "$NA/Webby/cache $NA/Webby/config $NA/WebbyData" "$(jq -r '[.app_data[].path] | sort | join(" ")' <<< "$P" 2>/dev/null)"
check "nuke: …and finds them"                       "true true true" "$(jq -r '[.app_data[].exists] | map(tostring) | join(" ")' <<< "$P" 2>/dev/null)"
check "nuke: a folder another container uses is kept" "$NA/Shared other" "$(jq -r '.kept_shared[] | "\(.path) \(.shared_with)"' <<< "$P" 2>/dev/null)"
check "nuke: nothing outside App-Data is listed"    no "$(jq -r '[.app_data[].path, .kept_shared[].path] | join(" ")' <<< "$P" 2>/dev/null | grep -q 'docker.sock\|/srv/media' && echo yes || echo no)"
check "nuke: the trash is the stack's own"          "$NA/.trash/demo" "$(jq -r '.trash_dir' <<< "$P" 2>/dev/null)"
N=$(_node POST /containers/webby/reset '{"confirm":"webby","pull":false}')
check "nuke: it runs"                               true "$(jq -r '.success' <<< "$N" 2>/dev/null)"
check "nuke: the folders are empty again"           "0 0 0" "$(find "$NA/Webby/config" -mindepth 1 2>/dev/null | wc -l) $(find "$NA/Webby/cache" -mindepth 1 2>/dev/null | wc -l) $(find "$NA/WebbyData" -mindepth 1 2>/dev/null | wc -l)"
check "nuke: what was in them is in the trash"      "old settings" "$(cat "$NA"/.trash/demo/webby-*/config/app.conf 2>/dev/null)"
check "nuke: the shared folder was not touched"     theirs "$(cat "$NA/Shared/keep.txt" 2>/dev/null)"
check "nuke: the service was created again"         yes "$(grep -q 'compose .* up -d --force-recreate --no-deps webby' "$NODE/fake/calls" 2>/dev/null && echo yes || echo no)"
check "nuke: the preview lists the reset"           1 "$(_node GET /containers/webby/reset | jq -r '.previous_resets | length' 2>/dev/null)"
# an absolute APP_DATA_DIR is one root for every stack: only what lies two levels down is a container's own
sed -i '/^APP_DATA_DIR=/d' "$NODE/.env"; printf 'APP_DATA_DIR=%s\n' "$NODE/AD" >> "$NODE/.env"
_rootof() { ( cd "$NODE" && set -a && . "$NODE/.env" && set +a && source "$NODE/.scripts/api-server.sh" >/dev/null 2>&1; RST_PROJ_DIR="$NODE/Stacks/demo"; RST_ROOTS=("$(_stack_appdata_root "$RST_PROJ_DIR")" "$RST_PROJ_DIR/App-Data"); _container_reset_root_of "$1" || echo none ); }
check "nuke: a shared root is used as it is"        "$NODE/AD" "$(_rootof "$NODE/AD/demo/Webby")"
check "nuke: …its first level is never a container's" none "$(_rootof "$NODE/AD/demo")"
check "nuke: …the stack's own App-Data still counts" "$NA" "$(_rootof "$NA/Webby")"
check "nuke: the trash is never emptied into itself" none "$(_rootof "$NA/.trash/demo/webby-1")"

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
