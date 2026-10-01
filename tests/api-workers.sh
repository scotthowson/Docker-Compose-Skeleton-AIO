#!/bin/bash
# =============================================================================
# The API's worker pool (API_WORKERS): a real listener on a loopback port, an
# isolated copy of the installation, no Docker daemon needed.
#   - the front hands every connection to a pre-read worker: answers, headers and
#     the client's address are the same as with one process per connection
#   - a burst of parallel requests is all answered; a worker renews itself in
#     place after API_WORKER_REQUESTS answers; a killed worker is replaced
#   - --stop ends the workers and removes their sockets; API_WORKERS=0 is the
#     old transport
# Usage: tests/api-workers.sh      (exit status 0 = all passed)
# =============================================================================
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for t in socat curl jq ss python3; do command -v "$t" >/dev/null 2>&1 || { echo "skip: $t is not installed"; exit 0; }; done
# where Docker is absent (a CI container) the API would refuse to start: any command that answers stands in for Compose
if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
    DCS_FAKE_COMPOSE="$(mktemp "${TMPDIR:-/tmp}/dcs-fake-compose-XXXXXX")"; printf '#!/bin/sh\nexit 0\n' > "$DCS_FAKE_COMPOSE"; chmod +x "$DCS_FAKE_COMPOSE"
    export DOCKER_COMPOSE_CMD="$DCS_FAKE_COMPOSE"
fi
PASS=0; FAIL=0
check() { if [[ "$3" == "$2" ]]; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL + 1)); printf '  FAIL %s (expected %s, got %s)\n' "$1" "$2" "$3"; fi; }
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
alive() { [[ -d "/proc/$1" && "$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null)" != Z ]]; }

W="$(mktemp -d "${TMPDIR:-/tmp}/dcs-workers-XXXXXX")"
MAIN=""
cleanup() { [[ -n "$MAIN" ]] && alive "$MAIN" && { (cd "$W" && "$W/.scripts/api-server.sh" --stop >/dev/null 2>&1); sleep 0.5; kill -TERM "$MAIN" 2>/dev/null; }; pkill -TERM -f -- "$W/.scripts/api-server.sh" 2>/dev/null; pkill -TERM -f -- "UNIX-LISTEN:$W/.data/run/" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT

install() {
    mkdir -p "$W/.scripts" "$W/.lib" "$W/.config" "$W/.data" "$W/logs" "$W/.api-auth" "$W/Stacks/demo"
    cp "$ROOT/.scripts/api-server.sh" "$ROOT/.scripts/api-dispatch.sh" "$W/.scripts/"; cp "$ROOT/compose.sh" "$ROOT/VERSION" "$W/"
    cp -r "$ROOT/.lib/." "$W/.lib/"; cp -r "$ROOT/.config/." "$W/.config/"
    grep -vE '^(API_BIND|API_AUTH_ENABLED|API_INSECURE_NO_AUTH|API_TRUSTED_PROXIES|API_IP_WHITELIST|API_PORT|API_WORKERS)=' "$ROOT/.env.example" > "$W/.env"
    printf 'services:\n  demo:\n    image: alpine:3\n    command: ["sleep","infinity"]\n' > "$W/Stacks/demo/docker-compose.yml"
    printf 'API_PORT=%s\nMETRICS_ENABLED=false\nDDNS_ENABLED=false\nAPI_AUTH_ENABLED=true\n' "$PORT" >> "$W/.env"
}
ping_ok() { [[ "$(curl -s -m 2 "http://127.0.0.1:$PORT/ping" 2>/dev/null)" == *'"ok": true'* ]]; }
wait_up() { local i; for ((i = 0; i < ${1:-80}; i++)); do ping_ok && return 0; sleep 0.25; done; return 1; }
workers() { pgrep -f -- "$W/.scripts/api-server.sh --worker " 2>/dev/null | sort | tr '\n' ' '; }
log_plain() { sed 's/\x1b\[[0-9;]*m//g' "$W/logs/listener.log"; }

echo "API worker pool"
# the front alone, with a stand-in worker that answers after 2 s: the answer must arrive whole (socat's half-close wait on the front)
FD="$W/front"; mkdir -p "$FD"
cat > "$FD/standin.sh" <<'STANDIN'
#!/bin/bash
IFS= read -r peer; IFS= read -r line; peer="${peer%$'\r'}"
sleep 2
body="{\"slow\": \"${peer#DCS-PEER }\"}"
printf 'HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' "${#body}" "$body"
STANDIN
( exec socat -t 900 "UNIX-LISTEN:$FD/w1.sock,unlink-early" EXEC:"bash $FD/standin.sh" ) &
STANDIN=$!; sleep 0.5
SLOW=$(printf 'GET /slow HTTP/1.1\r\nHost: x\r\n\r\n' | DCS_API_RUN_DIR="$FD" SOCAT_PEERADDR=10.9.8.7 timeout 20 bash "$ROOT/.scripts/api-dispatch.sh" 2>/dev/null)
check "front: a slow answer arrives whole"            yes "$(grep -q '"slow": "10.9.8.7"' <<< "$SLOW" && echo yes || echo no)"
kill "$STANDIN" 2>/dev/null; wait "$STANDIN" 2>/dev/null; rm -rf "$FD"
PORT=$(free_port); install
(cd "$W" && API_WORKERS=2 API_WORKER_REQUESTS=6 setsid nohup "$W/.scripts/api-server.sh" --bind 127.0.0.1 --port "$PORT" > "$W/logs/listener.log" 2>&1 < /dev/null &)
wait_up 80 || { echo "  FAIL the API did not come up"; log_plain | tail -20; exit 1; }
MAIN=$(cat "$W/.data/api-server.pid" 2>/dev/null)
check "served through socat"                       socat "$(log_plain | awk '/Transport/{print $2; exit}')"
check "two workers announced"                      "2" "$(log_plain | sed -n 's/^API workers: \([0-9]*\).*/\1/p' | head -1)"
check "two worker processes run"                   2 "$(workers | wc -w)"
# a worker's socket file is away for a moment between two connections: the count is taken once both are back
for _ in $(seq 1 50); do [[ "$(ls "$W/.data/run"/w*.sock 2>/dev/null | wc -l)" -eq 2 ]] && break; sleep 0.2; done
check "two sockets in the run dir"                 2 "$(ls "$W/.data/run"/w*.sock 2>/dev/null | wc -l)"
W1=$(workers)
# the same answers as the one-process transport: status line, JSON body, CORS and security headers
H=$(curl -s -m 5 -D - -o /dev/null -H 'Origin: http://localhost:3000' "http://127.0.0.1:$PORT/ping")
check "/ping: 200"                                 "HTTP/1.1 200" "$(head -1 <<< "$H" | tr -d '\r' | cut -d' ' -f1,2)"
check "/ping: the usual headers"                   yes "$(grep -qi '^X-Content-Type-Options: nosniff' <<< "$H" && grep -qi '^Access-Control-Allow-Origin:' <<< "$H" && echo yes || echo no)"
check "unknown route, no token: 401 as always"     401 "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/nope")"
check "setup status answers"                       true "$(curl -s -m 5 "http://127.0.0.1:$PORT/setup/status" | jq -r '.needs_admin' 2>/dev/null)"
# the first admin, through the worker: a POST with a body
SET=$(curl -s -m 10 -X POST -H 'Content-Type: application/json' -d '{"username":"admin","password":"correct horse battery staple"}' "http://127.0.0.1:$PORT/auth/setup")
TOKEN=$(jq -r '.token // empty' <<< "$SET" 2>/dev/null)
check "the first admin is created (POST body arrives whole)" yes "$([[ -n "$TOKEN" ]] && echo yes || echo no)"
check "an authenticated GET answers"               200 "$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/version")"
check "unknown route through a worker"             404 "$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/nope")"
check "the client's address reaches the handler"   127.0.0.1 "$(curl -s -m 5 -X POST -H 'Content-Type: application/json' -d '{"username":"admin","password":"wrong"}' "http://127.0.0.1:$PORT/auth/login" >/dev/null; grep -h 'admin' "$W/.api-auth/auth-audit.log" 2>/dev/null | tail -1 | grep -oE '(^|[^0-9.])127\.0\.0\.1' | tr -d ' |' | tail -1)"
# a burst: 16 requests at once, every one answered 200 (the front waits for a free worker instead of refusing)
codes=$(for i in $(seq 1 16); do curl -s -m 20 -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/version" & done; wait)
check "16 parallel requests all answered"          16 "$(grep -c '^200$' <<< "$codes")"
# renewal: after API_WORKER_REQUESTS answers a worker execs itself in place (same pids, fresh process) and keeps answering
for i in $(seq 1 10); do curl -s -m 5 -o /dev/null "http://127.0.0.1:$PORT/ping"; done
sleep 1
check "workers renewed in place (same pids)"       "$W1" "$(workers)"
check "…and still answer"                          yes "$(ping_ok && echo yes || echo no)"
# a killed worker is replaced
victim=$(workers | awk '{print $1}')
kill -KILL "$victim" 2>/dev/null; sleep 4
check "a killed worker is replaced"                2 "$(workers | wc -w)"
check "…and the pool still answers"                200 "$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/version")"
# a request line that never comes: the front gives up after its 10 s, the worker is not held
check "an idle connection does not hold a worker"  200 "$( (exec 3<>"/dev/tcp/127.0.0.1/$PORT"; sleep 0.3; exec 3>&-) ; curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/ping")"
# stop: the workers end and their sockets go
(cd "$W" && "$W/.scripts/api-server.sh" --stop >/dev/null 2>&1)
for i in $(seq 1 40); do alive "$MAIN" || break; sleep 0.25; done
check "stop: the listener ends"                    no "$(alive "$MAIN" && echo yes || echo no)"
sleep 1
check "stop: no worker is left"                    0 "$(workers | wc -w)"
check "stop: the run dir is removed"               no "$([[ -d "$W/.data/run" ]] && echo yes || echo no)"
check "stop: no socat keeps a worker socket"       0 "$(pgrep -fc -- "UNIX-LISTEN:$W/.data/run/" 2>/dev/null || true)"
check "stop: the port is free"                     "" "$(ss -Hltn "sport = :$PORT" 2>/dev/null)"
MAIN=""
# API_WORKERS=0: the old transport, one process per connection
(cd "$W" && API_WORKERS=0 setsid nohup "$W/.scripts/api-server.sh" --bind 127.0.0.1 --port "$PORT" > "$W/logs/listener.log" 2>&1 < /dev/null &)
wait_up 80 || { echo "  FAIL the API did not come up with API_WORKERS=0"; exit 1; }
MAIN=$(cat "$W/.data/api-server.pid" 2>/dev/null)
check "API_WORKERS=0: no worker process"           0 "$(workers | wc -w)"
check "API_WORKERS=0: answers as before"           200 "$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/version")"
(cd "$W" && "$W/.scripts/api-server.sh" --stop >/dev/null 2>&1); MAIN=""

echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
