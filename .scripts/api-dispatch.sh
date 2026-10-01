#!/bin/bash
# =============================================================================
# api-dispatch.sh — the front of the API when it runs with worker processes.
#
# socat starts this for every connection, with the client on stdin / stdout.
# It reads the request (the line, the headers, the body the Content-Length
# announces: what the API reads itself, with the same 10 s patience), then
# hands it to one of the worker processes the server keeps — each one is
# api-server.sh, read once, listening on its own unix socket — with the
# client's address in front. A busy worker refuses the connection at once, so
# the next one is tried with the same request, and when every worker is busy
# it keeps trying for a few seconds. Written to be tiny: bash reads it in a
# millisecond, where the API script takes a tenth of a second on a small VM.
# =============================================================================
d="${DCS_API_RUN_DIR:-}"
answer() { printf 'HTTP/1.1 %s\r\nContent-Type: application/json\r\nConnection: close\r\n%s\r\n{"error": true, "code": %s, "message": "%s"}\r\n' "$1" "$2" "${1%% *}" "$3"; exit 0; }
[[ -n "$d" && -d "$d" ]] || answer "503 Service Unavailable" $'Retry-After: 2\r\n' "The API is starting"
peer="${SOCAT_PEERADDR:-${NCAT_REMOTE_ADDR:-}}"
tmp=$(mktemp "${TMPDIR:-/tmp}/dcs-req-XXXXXX") || answer "503 Service Unavailable" "" "No room for the request"
trap 'rm -f "$tmp"' EXIT
# the request, buffered: the line and the headers (up to the blank line), then the body
cl=0; n=0; req=""
IFS= read -r -t 10 line || exit 0
req="$line"$'\n'
while IFS= read -r -t 10 h; do
    req+="$h"$'\n'
    hl="${h%%$'\r'}"
    [[ -z "$hl" ]] && break
    (( ++n > 200 )) && answer "431 Request Header Fields Too Large" "" "Too many headers"
    if [[ "${hl,,}" == content-length:* ]]; then cl="${hl#*:}"; cl="${cl//[[:space:]]/}"; [[ "$cl" =~ ^[0-9]{1,9}$ ]] || cl=0; fi
done
(( cl <= 134217728 )) || answer "413 Content Too Large" "" "The body is larger than 128 MB"
{ printf 'DCS-PEER %s\r\n' "$peer"; printf '%s' "$req"; (( cl > 0 )) && head -c "$cl"; } > "$tmp"
# A worker's socket file is away for a moment between two connections (socat removes it on close, the next one binds it
# again), so the list is read on every round and an empty one is just "all busy" until the rounds run out.
start=$RANDOM
for (( round = 0; round < 100; round++ )); do
    socks=("$d"/w*.sock); nw=${#socks[@]}
    for (( i = 0; i < nw; i++ )); do
        s="${socks[(start + i) % nw]}"
        [[ -S "$s" ]] || continue
        t0=$(date +%s%N)
        # -t: the request is sent at once (EOF on the file), then socat must wait for the answer; its default is half a second
        socat -t 900 -T 900 STDIO "UNIX-CONNECT:$s" < "$tmp" 2>/dev/null && exit 0
        # a refusal (the worker is busy, or between two connections) ends in a few milliseconds and nothing was exchanged: try the next;
        # anything that took longer had the worker's attention and is not sent again (a POST must not run twice)
        (( ($(date +%s%N) - t0) / 1000000 < 150 )) || exit 0
    done
    sleep 0.05
done
answer "503 Service Unavailable" $'Retry-After: 2\r\n' "Every API worker is busy: try again in a moment"
