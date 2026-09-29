# shellcheck shell=bash
# =============================================================================
# member-check.sh — sourced by boot-test.sh for a node image (never run by itself).
#
# A hub started from this checkout builds a member out of the running VM the way its build step does: the member bootstrap
# (.scripts/fleet-bootstrap.sh) is copied over ssh and run, the VM joins, and the member is used through the hub: its API,
# the host name, the Docker Engine card, a stack with a healthy and an unhealthy container, a Docker restart, and an engine
# update. Everything here failed at some point on some distribution and boot-test.sh saw nothing of it.
#
# Needs socat, jq, curl, git and tar on the machine that runs the test (the hub API listens through socat).
# Uses from boot-test.sh: T, HERE, IMG, SSH, P_API, chk, ok, bad. Sets HUBPID (boot-test.sh's cleanup stops it).
# =============================================================================

member_check() {
    local c repo hubd hport tok jt id s rc expect_src distro fam api_pid1 api_pid2 st n
    for c in socat jq curl git tar openssl; do command -v "$c" >/dev/null || { echo "  skip  the member checks (needs $c on this machine)"; return 0; }; done
    repo=$(cd "$HERE/../.." && pwd)
    distro=$(basename "$IMG" .qcow2); distro=${distro#dcs-node-}; distro=${distro#dcs-hub-}
    fam=$(jq -r --arg id "$distro" '.images[] | select(.id == $id) | .family' "$repo/vm-images/images.json" 2>/dev/null)
    case "$fam" in pacman) expect_src=docker-arch ;; *) expect_src=docker-ce ;; esac

    # a hub: the tracked files of this checkout as they are in the working tree (no images, tests or pictures), its own port and admin
    hubd="$T/hub"; mkdir -p "$hubd/Stacks"
    (cd "$repo" && git ls-files -z -- . ':!vm-images' ':!tests' ':!docs/img' ':!Stacks' 2>/dev/null | tar --null -T - -cf - 2>/dev/null) | tar -x -C "$hubd" 2>/dev/null
    [[ -x "$hubd/.scripts/api-server.sh" ]] || { bad "the member checks: no checkout to start a hub from"; return 0; }
    hport=$(free_port 24000)
    cat > "$hubd/.env" <<ENV
API_PORT=$hport
API_AUTH_ENABLED=true
API_RATE_LIMIT=100000
API_SINGLE_SESSION=false
API_RESPONSE_CACHE=false
METRICS_ENABLED=false
SCHEDULER_ENABLED=false
SERVER_NAME=member-test-hub
FLEET_SELF_URL=http://127.0.0.1:$hport
TZ=UTC
ENV
    mkdir -p "$hubd/.data" "$hubd/logs" "$hubd/.api-auth"
    # a session of its own (exec setsid: the pid is the API's and kill -- -pid ends it and what it started)
    ( cd "$hubd" && exec setsid .scripts/api-server.sh --bind 127.0.0.1 --port "$hport" ) > "$T/hub.log" 2>&1 < /dev/null &
    HUBPID=$!
    for _ in $(seq 1 60); do curl -fsS -m 2 -o /dev/null "http://127.0.0.1:$hport/ping" 2>/dev/null && break; sleep 0.5; done
    local pw; pw="Mt-$(openssl rand -hex 8)-1A"
    tok=$(curl -fsS -m 20 -X POST -H 'Content-Type: application/json' -d "{\"username\":\"member-test\",\"password\":\"$pw\"}" "http://127.0.0.1:$hport/auth/setup" 2>/dev/null | jq -r '.token // empty')
    [[ -n "$tok" ]] || { bad "the member checks: the test hub did not start (see $T/hub.log)"; tail -5 "$T/hub.log"; return 0; }
    curl -fsS -m 20 -X POST -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d '{}' "http://127.0.0.1:$hport/setup/complete" >/dev/null 2>&1
    jt=$(curl -fsS -m 20 -X POST -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d '{"ttl_hours":1}' "http://127.0.0.1:$hport/fleet/join-tokens" 2>/dev/null | jq -r '.token // empty')
    [[ -n "$jt" ]] || { bad "the member checks: the test hub minted no join code"; return 0; }

    # the bootstrap the hub pipes into a fresh VM: its values first, then the script (10.0.2.2 is this machine, seen from the VM)
    s="$T/member-bootstrap.sh"
    {
        printf 'export DCS_HUB_URL=%q DCS_JOIN_TOKEN=%q DCS_STACKS=%q DCS_MEMBER_NAME=%q DCS_MEMBER_URL=%q DCS_API_PORT=%q\n' "http://10.0.2.2:$hport" "$jt" member-test member-test "http://127.0.0.1:$P_API" 9876
        printf 'export DCS_ADMIN_USER=%q DCS_ADMIN_PASSWORD=%q DCS_TZ=%q DCS_PUID=%q DCS_PGID=%q DCS_PROXY_DOMAIN=%q DCS_CF_DNS_API_TOKEN=%q\n' member-test "$pw" UTC 1000 1000 '' ''
        printf 'export DCS_BUNDLE_URL=%q DCS_UNATTENDED=true DCS_NO_UI=true DCS_FLEET_ROLE=member DCS_BAKE=false DCS_PROXY_DOMAIN=%q\n' "http://10.0.2.2:$hport/fleet/bundle?token=$jt" ''
        cat "$repo/.scripts/fleet-bootstrap.sh"
    } > "$s"
    rc=0; "${SSH[@]}" 'f=$(mktemp /tmp/dcs-bootstrap.XXXXXX) && cat > "$f" && bash "$f" </dev/null; rc=$?; rm -f "$f"; exit $rc' < "$s" > "$T/member-bootstrap.log" 2>&1 || rc=$?
    chk "a hub builds a member out of it (the member bootstrap ends well)" [ "$rc" = 0 ]
    if [[ "$rc" != 0 ]]; then echo "--- the bootstrap's last lines"; tail -12 "$T/member-bootstrap.log"; return 0; fi

    hubq() { curl -fsS -m 40 -H "Authorization: Bearer $tok" "http://127.0.0.1:$hport$1" 2>/dev/null; }
    hubp() { curl -fsS -m 120 -X POST -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d "${2:-\{\}}" "http://127.0.0.1:$hport$1" 2>/dev/null; }
    id=$(hubq /fleet/members | jq -r '.members[0].id // empty')
    chk "the member is registered, answers, and runs the hub's version" [ "$(hubq /fleet/members | jq -r '.members[0] | "\(.reachable) \(.version)"')" = "true $(tr -d '[:space:]' < "$repo/VERSION")" ]
    chk "the member reports its host name" [ "$(hubq "/fleet/members/$id/api/status" | jq -r '.hostname // ""')" = bootcheck ]
    chk "the Docker Engine card knows where Docker comes from ($expect_src)" [ "$(hubq "/fleet/members/$id/api/system/docker-engine" | jq -r '.source // ""')" = "$expect_src" ]
    chk "the Cron Jobs page is an empty list (no cron here), not an error" [ "$(hubq "/fleet/members/$id/api/system/crontab" | jq -r '(.entries | length | tostring) + (.raw // "")')" = 0 ]

    # a stack with one healthy and one unhealthy container, started from the hub
    "${SSH[@]}" "cat > ~/.Docker-Compose-Skeleton-AIO/Stacks/member-test/docker-compose.yml" <<YML
services:
  good:
    image: ${DCS_TEST_REGISTRY:-}alpine:3
    container_name: mt-good
    command: ["sh","-c","trap 'exit 0' TERM; sleep 100000 & wait"]
    healthcheck: {test: ["CMD","true"], interval: 2s, timeout: 2s, retries: 1, start_period: 0s}
  bad:
    image: ${DCS_TEST_REGISTRY:-}alpine:3
    container_name: mt-bad
    command: ["sh","-c","trap 'exit 0' TERM; sleep 100000 & wait"]
    healthcheck: {test: ["CMD","false"], interval: 2s, timeout: 2s, retries: 1, start_period: 0s}
YML
    hubp "/fleet/members/$id/api/stacks/member-test/start" >/dev/null
    st=""; for _ in $(seq 1 45); do
        st=$(hubq "/fleet/members/$id/api/containers" | jq -r '[.containers[] | select(.stack == "member-test") | "\(.name):\(.health)"] | sort | join(" ")')
        [[ "$st" == "mt-bad:unhealthy mt-good:healthy" ]] && break; sleep 2
    done
    chk "a stack starts from the hub; its healthy and its unhealthy container are told apart ($st)" [ "$st" = "mt-bad:unhealthy mt-good:healthy" ]

    # a Docker restart (what an engine update does) leaves the API running
    api_pid1=$("${SSH[@]}" 'systemctl show -p MainPID --value dcs-api' 2>/dev/null)
    "${SSH[@]}" 'sudo systemctl restart docker' >/dev/null 2>&1; sleep 4
    api_pid2=$("${SSH[@]}" 'systemctl show -p MainPID --value dcs-api' 2>/dev/null)
    chk "a Docker restart leaves the API service running" [ -n "$api_pid1" ] && [ "$api_pid1" = "$api_pid2" ]

    # the one-click engine update, for real (nothing to upgrade is fine; the job has to finish and say so)
    # (a mirror that hiccups gets one more try: the point is that the job runs and ends, not that a mirror is up)
    for _try in 1 2; do
        hubp "/fleet/members/$id/api/system/docker-engine/update" >/dev/null
        st=running; n=0; while [[ "$st" == running ]] && (( n < 90 )); do sleep 4; n=$((n + 1)); st=$(hubq "/fleet/members/$id/api/system/docker-engine/status" | jq -r '.status // "running"'); done
        [[ "$st" == "done" ]] && break
    done
    chk "the Docker Engine update runs to the end and succeeds ($st)" [ "$st" = "done" ]
    if [[ "$st" != "done" ]]; then hubq "/fleet/members/$id/api/system/docker-engine/status" | jq -r '.output // ""' | tail -8; fi
    kill -- -"$HUBPID" 2>/dev/null; HUBPID=""
    return 0
}
