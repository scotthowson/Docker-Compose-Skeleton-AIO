#!/bin/bash
# shellcheck shell=bash
# =============================================================================
# CrowdSec page — the API behind the dashboard's CrowdSec page
#
# What it does: detects whether CrowdSec is deployed and healthy (one status
# answer that names the state), lists and manages bans, alerts, the allowlist,
# bouncers, the hub, simulation mode and the container itself. The ban profile
# and the Discord notifications live in .lib/crowdsec-config.sh.
#
# How: every call is `docker exec <container> cscli … -o json` with an argument
# ARRAY (user input never reaches a shell), a timeout, and a short file cache
# for the slow ones. Nothing here needs PyYAML or a Python at all.
#
# Loaded on demand by the router (_crowdsec_lib in api-server.sh): a request
# for any other route never parses it. The handlers use the API's own helpers
# (_api_success, _api_error, _api_audit_log, _api_check_admin, QUERY_PARAMS).
# =============================================================================

# shellcheck disable=SC2034  # read by the router (_crowdsec_lib in api-server.sh)
CROWDSEC_LIB_LOADED=1
CROWDSEC_STATE_DIR="${CROWDSEC_STATE_DIR:-$BASE_DIR/.data/crowdsec}"
CROWDSEC_CACHE_DIR="${CROWDSEC_CACHE_DIR:-${API_CACHE_DIR:-$BASE_DIR/.data/cache}/crowdsec}"
# CrowdSec has no ban without an end: "permanent" is ten years
CROWDSEC_PERMANENT_DURATION="87600h"
CROWDSEC_PERMANENT_SECONDS=315360000
# the allowlist DCS keeps in CrowdSec (1.6.8+) and the bouncer it registers for Traefik
CROWDSEC_ALLOWLIST_NAME="dcs"
CROWDSEC_BOUNCER_NAME="dcs-traefik-bouncer"

# the container this request works on, set by _cs_target
CS_NAME=""
CS_ERR=""

# =============================================================================
# Validation — every value that reaches cscli passes one of these first
# =============================================================================

# 1.2.3.4 (no leading zeros: "010" is octal to some parsers)
_cs_is_v4() {
    local LC_ALL=C      # ranges like [0-9] and [a-f] follow the server's language (in en_US.UTF-8 they also match ٣ and ä): here they mean ASCII
    [[ "$1" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]] || return 1
    (( BASH_REMATCH[1] <= 255 && BASH_REMATCH[2] <= 255 && BASH_REMATCH[3] <= 255 && BASH_REMATCH[4] <= 255 ))
}

# Expand an IPv6 address (with "::" and an optional dotted tail) to 32 lowercase hex digits
_cs_v6_expand() {
    local LC_ALL=C      # (see _cs_is_v4: 2a00::ä must not read as 2a00::)
    local a="${1,,}" head tail n pad
    [[ "$a" =~ ^[0-9a-f:.]+$ && "$a" == *:* && "$a" != *:::* ]] || return 1
    if [[ "$a" =~ ^(.*:)([0-9.]+)$ && "${BASH_REMATCH[2]}" == *.* ]]; then
        local v4="${BASH_REMATCH[2]}" pre="${BASH_REMATCH[1]}"
        _cs_is_v4 "$v4" || return 1
        local -a o; IFS=. read -ra o <<< "$v4"
        a="${pre}$(printf '%x:%x' $(( (o[0] << 8) | o[1] )) $(( (o[2] << 8) | o[3] )))"
    fi
    if [[ "$a" == *::* ]]; then
        [[ "${a#*::}" != *::* ]] || return 1
        head="${a%%::*}"; tail="${a#*::}"
        local -a hgrp=() tgrp=() g; local out=""
        [[ -n "$head" ]] && IFS=: read -ra hgrp <<< "$head"
        [[ -n "$tail" ]] && IFS=: read -ra tgrp <<< "$tail"
        n=$(( ${#hgrp[@]} + ${#tgrp[@]} ))
        (( n <= 7 )) || return 1
        for g in "${hgrp[@]}"; do [[ "$g" =~ ^[0-9a-f]{1,4}$ ]] || return 1; printf -v g '%04x' "0x$g"; out+="$g"; done
        for (( pad = 0; pad < 8 - n; pad++ )); do out+="0000"; done
        for g in "${tgrp[@]}"; do [[ "$g" =~ ^[0-9a-f]{1,4}$ ]] || return 1; printf -v g '%04x' "0x$g"; out+="$g"; done
        printf '%s' "$out"
    else
        local -a all; local out="" g
        IFS=: read -ra all <<< "$a"
        (( ${#all[@]} == 8 )) || return 1
        for g in "${all[@]}"; do [[ "$g" =~ ^[0-9a-f]{1,4}$ ]] || return 1; printf -v g '%04x' "0x$g"; out+="$g"; done
        printf '%s' "$out"
    fi
}
_cs_is_v6() { _cs_v6_expand "$1" >/dev/null; }

# hex digits (8 for IPv4, 32 for IPv6) of an address
_cs_addr_hex() {
    if _cs_is_v4 "$1"; then
        local -a o; IFS=. read -ra o <<< "$1"
        printf '%02x%02x%02x%02x' "${o[0]}" "${o[1]}" "${o[2]}" "${o[3]}"
    else
        _cs_v6_expand "$1"
    fi
}

# Zero the host bits of an address given as hex digits: _cs_mask_hex HEX BITS
_cs_mask_hex() {
    local hex="$1" bits="$2" full rem out i d
    full=$(( bits / 4 )); rem=$(( bits % 4 )); out="${hex:0:full}"
    if (( rem > 0 )); then
        d=$(( 0x${hex:full:1} & (0xF << (4 - rem) & 0xF) ))
        printf -v d '%x' "$d"; out+="$d"; full=$(( full + 1 ))
    fi
    for (( i = full; i < ${#hex}; i++ )); do out+="0"; done
    printf '%s' "$out"
}

# hex → dotted quad, or IPv6 text with the longest run of zero groups written "::"
_cs_hex_to_addr() {
    local hex="$1" i x left="" right="" best_s=-1 best_l=0 cur_s=-1 cur_l=0
    if (( ${#hex} == 8 )); then
        printf '%d.%d.%d.%d' "0x${hex:0:2}" "0x${hex:2:2}" "0x${hex:4:2}" "0x${hex:6:2}"
        return
    fi
    local -a g=()
    for (( i = 0; i < 32; i += 4 )); do printf -v x '%x' "$(( 16#${hex:i:4} ))"; g+=("$x"); done
    for (( i = 0; i < 8; i++ )); do
        if [[ "${g[i]}" == 0 ]]; then
            if (( cur_s < 0 )); then cur_s=$i; cur_l=1; else cur_l=$(( cur_l + 1 )); fi
            if (( cur_l > best_l )); then best_s=$cur_s; best_l=$cur_l; fi
        else
            cur_s=-1; cur_l=0
        fi
    done
    if (( best_l >= 2 )); then
        for (( i = 0; i < best_s; i++ )); do left+="${left:+:}${g[i]}"; done
        for (( i = best_s + best_l; i < 8; i++ )); do right+="${right:+:}${g[i]}"; done
        printf '%s::%s' "$left" "$right"
    else
        left="${g[0]}"; for (( i = 1; i < 8; i++ )); do left+=":${g[i]}"; done
        printf '%s' "$left"
    fi
}

# Normalise a ban target. Prints "Ip<TAB>value" or "Range<TAB>network/bits"; fails for anything else.
_cs_norm_target() {
    local v="$1" addr bits max hex v4
    [[ ${#v} -le 64 && -n "$v" ]] || return 1
    if [[ "$v" == */* ]]; then
        addr="${v%%/*}"; bits="${v#*/}"
        [[ "$bits" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
    else
        addr="$v"; bits=""
    fi
    if _cs_is_v4 "$addr"; then max=32; elif _cs_is_v6 "$addr"; then max=128; else return 1; fi
    if [[ -z "$bits" ]]; then
        if [[ $max -eq 32 ]]; then printf 'Ip\t%s' "$addr"; return 0; fi
        hex=$(_cs_addr_hex "$addr")
        # ::ffff:8.8.4.4 is the IPv4 address 8.8.4.4 as an IPv6 socket sees it; Traefik's clients come as IPv4, so that is what a ban must name
        if [[ "${hex:0:24}" == 00000000000000000000ffff ]]; then printf 'Ip\t%s' "$(_cs_hex_to_addr "${hex:24:8}")"; return 0; fi
        printf 'Ip\t%s' "$(_cs_hex_to_addr "$hex")"
        return 0
    fi
    (( bits <= max )) || return 1
    hex=$(_cs_mask_hex "$(_cs_addr_hex "$addr")" "$bits")
    if [[ $max -eq 128 && "${hex:0:24}" == 00000000000000000000ffff ]] && (( bits >= 96 )); then
        v4=$(_cs_hex_to_addr "${hex:24:8}"); bits=$(( bits - 96 ))
        if (( bits == 32 )); then printf 'Ip\t%s' "$v4"; else printf 'Range\t%s/%s' "$v4" "$bits"; fi
        return 0
    fi
    if (( bits == max )); then printf 'Ip\t%s' "$(_cs_hex_to_addr "$hex")"; else printf 'Range\t%s/%s' "$(_cs_hex_to_addr "$hex")" "$bits"; fi
}

# Does network CIDR (or single address) A cover B (an address or a network)? Same family only.
_cs_covers() {
    local a="$1" b="$2" aa ab ba bb ha hb fam_a fam_b full rem
    aa="${a%%/*}"; ba="${b%%/*}"
    _cs_is_v4 "$aa" && fam_a=4 || fam_a=6
    _cs_is_v4 "$ba" && fam_b=4 || fam_b=6
    [[ $fam_a == "$fam_b" ]] || return 1
    ha=$(_cs_addr_hex "$aa") || return 1; hb=$(_cs_addr_hex "$ba") || return 1
    if [[ "$a" == */* ]]; then ab="${a#*/}"; else ab=$(( ${#ha} * 4 )); fi
    if [[ "$b" == */* ]]; then bb="${b#*/}"; else bb=$(( ${#hb} * 4 )); fi
    (( ab <= bb )) || return 1
    full=$(( ab / 4 )); rem=$(( ab % 4 ))
    [[ "${ha:0:full}" == "${hb:0:full}" ]] || return 1
    if (( rem > 0 )); then
        (( ((0x${ha:full:1} ^ 0x${hb:full:1}) >> (4 - rem)) == 0 )) || return 1
    fi
    return 0
}
# Do two networks share an address? (one covers the other)
_cs_overlaps() { _cs_covers "$1" "$2" || _cs_covers "$2" "$1"; }

# The same questions asked thousands of times (an import checks every entry against the private ranges and the protected addresses) without starting a process:
# _cs_prep turns an address or network into hex digits (CS_PH: 8 for IPv4, 32 for IPv6) and a prefix length (CS_PB), _cs_cover_hex compares two such pairs.
CS_PH=""; CS_PB=0
_cs_prep() {
    local t="$1" a="${1%%/*}" o1 o2 o3 o4
    if _cs_is_v4 "$a"; then
        IFS=. read -r o1 o2 o3 o4 <<< "$a"
        printf -v CS_PH '%02x%02x%02x%02x' "$o1" "$o2" "$o3" "$o4"
    else
        CS_PH=$(_cs_v6_expand "$a") || return 1
    fi
    if [[ "$t" == */* ]]; then
        CS_PB="${t#*/}"; [[ "$CS_PB" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
    else
        CS_PB=$(( ${#CS_PH} * 4 ))
    fi
    (( CS_PB <= ${#CS_PH} * 4 ))
}
# _cs_cover_hex HEX_A BITS_A HEX_B BITS_B — does network A cover B? Same family only (the hex lengths differ between IPv4 and IPv6); the answer _cs_covers gives
_cs_cover_hex() {
    local ha="$1" ab="$2" hb="$3" bb="$4" full rem
    (( ${#ha} == ${#hb} && ab <= bb )) || return 1
    full=$(( ab / 4 )); rem=$(( ab % 4 ))
    [[ "${ha:0:full}" == "${hb:0:full}" ]] || return 1
    if (( rem > 0 )); then
        (( ((0x${ha:full:1} ^ 0x${hb:full:1}) >> (4 - rem)) == 0 )) || return 1
    fi
    return 0
}

# What a ban must never touch: LAN, loopback, link-local, CGNAT, the unspecified addresses
_CS_PRIVATE_NETS=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 169.254.0.0/16 100.64.0.0/10 0.0.0.0/8 fc00::/7 fe80::/10 ::1/128 ::/128)
_cs_is_private() {
    local n
    for n in "${_CS_PRIVATE_NETS[@]}"; do _cs_covers "$n" "$1" && return 0; done
    return 1
}

# A ban length: 90m, 4h, 7d, 2w, 1h30m … → canonical minutes-or-hours text ("90m", "4h", "168h"); 1 minute … 10 years
_cs_norm_duration() {
    local v="${1,,}" total=0 rest part n u
    v="${v// /}"
    [[ -n "$v" && ${#v} -le 24 && "$v" =~ ^([0-9]+[smhdw])+$ ]] || return 1
    rest="$v"
    while [[ -n "$rest" ]]; do
        [[ "$rest" =~ ^([0-9]{1,9})([smhdw])(.*)$ ]] || return 1
        n="${BASH_REMATCH[1]}"; u="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[3]}"
        case "$u" in
            s) total=$(( total + n )) ;; m) total=$(( total + n * 60 )) ;; h) total=$(( total + n * 3600 )) ;;
            d) total=$(( total + n * 86400 )) ;; w) total=$(( total + n * 604800 )) ;;
        esac
    done
    (( total >= 60 && total <= CROWDSEC_PERMANENT_SECONDS )) || return 1
    part=$(( total / 60 ))
    if (( total % 3600 == 0 )); then printf '%dh' $(( total / 3600 )); else printf '%dm' "$part"; fi
}

# seconds of a duration text (for comparing); empty when invalid
_cs_duration_seconds() {
    local v="${1,,}" total=0 rest n u
    [[ "$v" =~ ^([0-9]+[smhdw])+$ ]] || return 1
    rest="$v"
    while [[ -n "$rest" ]]; do
        [[ "$rest" =~ ^([0-9]{1,9})([smhdw])(.*)$ ]] || return 1
        n="${BASH_REMATCH[1]}"; u="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[3]}"
        case "$u" in s) total=$(( total + n )) ;; m) total=$(( total + n * 60 )) ;; h) total=$(( total + n * 3600 )) ;; d) total=$(( total + n * 86400 )) ;; w) total=$(( total + n * 604800 )) ;; esac
    done
    printf '%d' "$total"
}

# A free-text reason: one line, no control characters, 200 characters
_cs_clean_reason() {
    local r="$1"
    r="${r//[$'\r\n\t']/ }"
    if [[ "$r" =~ [^[:print:]] ]]; then r=$(printf '%s' "$r" | tr -d '\000-\010\013\014\016-\037\177'); fi   # (only text with something unprintable in it needs the filter)
    r="${r#"${r%%[![:space:]]*}"}"; r="${r%"${r##*[![:space:]]}"}"
    printf '%s' "${r:0:200}"
}

# hub item / bouncer / list names: what CrowdSec itself accepts, and nothing that starts with a dash
_cs_valid_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/@:+-]{0,99}$ ]]; }
# a scenario name or a "prefix*" pattern
_cs_valid_pattern() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/@:+-]{0,119}\*?$ ]]; }
# an ISO country code
_cs_valid_cc() { [[ "$1" =~ ^[A-Za-z]{2}$ ]]; }

# =============================================================================
# Running cscli: argument arrays only, always with a timeout
# =============================================================================

# _cs_run OUTVAR ARGS… — cscli's stdout into OUTVAR, its stderr (trimmed) into CS_ERR; returns cscli's status
_cs_run() {
    local -n _cs_out="$1"; shift
    local errf rc
    errf=$(mktemp "${TMPDIR:-/tmp}/dcs-cs-err.XXXXXX" 2>/dev/null) || errf=/dev/null
    _cs_out=$(timeout "${CS_TIMEOUT:-25}" docker exec "$CS_NAME" cscli "$@" 2>"$errf" </dev/null); rc=$?
    CS_ERR=$(head -c 3000 "$errf" 2>/dev/null); [[ "$errf" == /dev/null ]] || rm -f "$errf"
    [[ $rc -eq 124 ]] && CS_ERR="cscli did not answer in ${CS_TIMEOUT:-25} s"
    return $rc
}

# _cs_pipe STDIN_TEXT ARGS… — the same, with text on cscli's standard input (decisions import)
_cs_pipe() {
    local -n _cs_pout="$1"; local input="$2"; shift 2
    local errf rc
    errf=$(mktemp "${TMPDIR:-/tmp}/dcs-cs-err.XXXXXX" 2>/dev/null) || errf=/dev/null
    _cs_pout=$(printf '%s' "$input" | timeout "${CS_TIMEOUT:-60}" docker exec -i "$CS_NAME" cscli "$@" 2>"$errf"); rc=$?
    CS_ERR=$(head -c 3000 "$errf" 2>/dev/null); [[ "$errf" == /dev/null ]] || rm -f "$errf"
    return $rc
}

# The message worth showing from cscli's stderr: the last "Error:" or fatal line, without the wrapping
# shellcheck disable=SC2120  # the argument is optional (the text to read; CS_ERR by default)
_cs_errline() {
    local e="${1:-$CS_ERR}" line probe
    # what failed inside a $( … ) (the cached readers run in one) left nothing in CS_ERR here: ask CrowdSec what is wrong with its API
    if [[ -z "$e" && -z "${1:-}" && -n "$CS_NAME" ]]; then _cs_run probe lapi status || e="$CS_ERR"; fi
    line=$(printf '%s\n' "$e" | grep -E '^Error:|level=(fatal|error)' | tail -n 1)
    [[ -n "$line" ]] || line=$(printf '%s\n' "$e" | grep -v '^[[:space:]]*$' | tail -n 1)
    line="${line#Error: }"
    if [[ "$line" =~ msg=\"(.*)\"([[:space:]]|$) ]]; then line="${BASH_REMATCH[1]}"; fi
    # "cscli decisions add: 1.2.3.4 is allowlisted …" → the part after the command
    [[ "$line" =~ ^cscli\ [a-z]+(\ [a-z-]+)?:\ (.*)$ ]] && line="${BASH_REMATCH[2]}"
    line="${line//\\\"/\"}"
    printf '%s' "${line:0:300}"
}

# =============================================================================
# The short cache for the slow calls (files, so it works across requests)
# =============================================================================

_cs_cache_file() { printf '%s/%s.json' "$CROWDSEC_CACHE_DIR" "${1//[^A-Za-z0-9_.-]/_}"; }

# _cs_cache_get KEY TTL — prints a fresh entry; returns 1 when there is none
_cs_cache_get() {
    local f age
    f=$(_cs_cache_file "$1")
    [[ -s "$f" ]] || return 1
    age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
    (( age < $2 )) || return 1
    cat "$f"
}
# _cs_cache_age KEY — seconds since the entry was written (999999 when absent)
_cs_cache_age() {
    local f; f=$(_cs_cache_file "$1")
    [[ -s "$f" ]] || { printf '999999'; return; }
    printf '%d' $(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
}
# _cs_cache_put KEY — stores stdin atomically
_cs_cache_put() {
    local f tmp; f=$(_cs_cache_file "$1")
    mkdir -p "$CROWDSEC_CACHE_DIR" 2>/dev/null
    tmp="$f.$$.tmp"
    cat > "$tmp" && mv -f "$tmp" "$f"
}
# every mutation drops the cached answers, so the next look is the truth
_cs_cache_clear() { rm -f "$CROWDSEC_CACHE_DIR"/*.json 2>/dev/null; return 0; }

# _cs_json KEY TTL ARGS… — `cscli ARGS -o json`, kept TTL seconds. "null" (an empty list for older cscli) becomes []. When cscli fails and an
# older answer (< 5 min) exists, that answer is served instead.
_cs_json() {
    local key="$1" ttl="$2" out rc f
    shift 2
    if out=$(_cs_cache_get "$key" "$ttl"); then printf '%s' "$out"; return 0; fi
    _cs_run out "$@" -o json; rc=$?
    if (( rc == 0 )) && jq -e . >/dev/null 2>&1 <<< "$out"; then
        [[ "$out" == null ]] && out='[]'
        printf '%s' "$out" | _cs_cache_put "$key"
        printf '%s' "$out"
        return 0
    fi
    f=$(_cs_cache_file "$key")
    if [[ -s "$f" ]] && (( $(_cs_cache_age "$key") < 300 )); then cat "$f"; return 0; fi
    return 1
}

# =============================================================================
# Finding the container, and what Docker says about it
# =============================================================================

# _cs_probe — one look at Docker: is it up, is there a CrowdSec container (in any state), where is Traefik. Sets
# CS_DOCKER (1/0) CS_DOCKER_ERR CS_NAME CS_RSTATE CS_HEALTH CS_IMAGE CS_EXIT CS_RESTARTS CS_PROJECT CS_WORKDIR CS_STARTED CS_TRAEFIK (JSON)
CS_DOCKER=1; CS_DOCKER_ERR=""; CS_RSTATE=""; CS_HEALTH=""; CS_IMAGE=""; CS_EXIT=0; CS_RESTARTS=0; CS_PROJECT=""; CS_WORKDIR=""; CS_STARTED=""
CS_TRAEFIK='{"present":false}'
_cs_probe() {
    local ps errf rc row insp
    CS_DOCKER=1; CS_DOCKER_ERR=""; CS_NAME=""; CS_RSTATE=""; CS_HEALTH=""; CS_IMAGE=""; CS_EXIT=0; CS_RESTARTS=0; CS_PROJECT=""; CS_WORKDIR=""; CS_STARTED=""
    CS_TRAEFIK='{"present":false}'
    errf=$(mktemp "${TMPDIR:-/tmp}/dcs-cs-ps.XXXXXX" 2>/dev/null) || errf=/dev/null
    ps=$(timeout 10 docker ps -a --format '{{json .}}' 2>"$errf" </dev/null); rc=$?
    if (( rc != 0 )); then
        CS_DOCKER=0; CS_DOCKER_ERR=$(tail -n 1 "$errf" 2>/dev/null | cut -c1-300); [[ -n "$CS_DOCKER_ERR" ]] || CS_DOCKER_ERR="docker did not answer"
        [[ "$errf" == /dev/null ]] || rm -f "$errf"
        return 1
    fi
    [[ "$errf" == /dev/null ]] || rm -f "$errf"
    # the CrowdSec row (a running one first) and the Traefik row, as tab-separated fields
    row=$(jq -rs '
        def lab($k): ((.Labels // "") | capture("(^|,)" + $k + "=(?<v>[^,]*)") | .v) // "";
        def isb($s): ((.Names // "") | ascii_downcase) == $s or lab("com.docker.compose.service") == $s;
        ( [ .[] | select(isb("crowdsec")) ] | sort_by(if .State == "running" then 0 else 1 end) | .[0] // null ) as $c
        | ( [ .[] | select(isb("traefik") or ((.Image // "") | test("(^|/)traefik(:|$)"))) ] | sort_by(if .State == "running" then 0 else 1 end) | .[0] // null ) as $t
        | [ ($c.Names // ""), ($c.State // ""), ($t.Names // ""), ($t.State // ""), ($t | if . == null then "" else lab("com.docker.compose.project") end), ($t | if . == null then "" else lab("com.docker.compose.project.working_dir") end) ] | join("\u001f")' <<< "$ps" 2>/dev/null)
    local tname tstate tproj twork
    IFS=$'\x1f' read -r CS_NAME CS_RSTATE tname tstate tproj twork <<< "$row"
    CS_TRAEFIK=$(jq -nc --arg n "${tname:-}" --arg s "${tstate:-}" --arg p "${tproj:-}" --arg w "${twork:-}" \
        'if $n == "" then {present: false} else {present: true, container: $n, state: $s, running: ($s == "running"), project: $p, workdir: $w} end')
    [[ -n "$CS_NAME" ]] || return 0
    insp=$(timeout 10 docker inspect "$CS_NAME" 2>/dev/null </dev/null | jq -r '.[0] | [ (.State.Status // ""), (.State.Health.Status // ""), (.Config.Image // ""), (.State.ExitCode // 0), (.RestartCount // 0),
            (.Config.Labels["com.docker.compose.project"] // ""), (.Config.Labels["com.docker.compose.project.working_dir"] // ""), (.State.StartedAt // "") ] | join("\u001f")' 2>/dev/null)
    if [[ -n "$insp" ]]; then
        IFS=$'\x1f' read -r CS_RSTATE CS_HEALTH CS_IMAGE CS_EXIT CS_RESTARTS CS_PROJECT CS_WORKDIR CS_STARTED <<< "$insp"
    fi
    return 0
}

# _cs_target — point CS_NAME at the running CrowdSec container, or answer the request with the reason and return 1
_cs_target() {
    CS_NAME=$(_crowdsec_container) || CS_NAME=""
    [[ -n "$CS_NAME" ]] && return 0
    _cs_probe
    if (( CS_DOCKER == 0 )); then _api_error 503 "Docker does not answer: $CS_DOCKER_ERR"; return 1; fi
    if [[ -n "$CS_NAME" ]]; then _api_error 409 "CrowdSec is not running (the container $CS_NAME is $CS_RSTATE). Start it from the CrowdSec page."; return 1; fi
    _api_error 404 "CrowdSec is not deployed. Deploy it from the CrowdSec page."
    return 1
}

# 5399 → "1 h 29 min", 90 → "1 min", 200000 → "2 d 7 h"
_cs_human_secs() {
    local s="$1"
    if (( s >= 86400 )); then printf '%d d %d h' $(( s / 86400 )) $(( s % 86400 / 3600 ))
    elif (( s >= 3600 )); then printf '%d h %d min' $(( s / 3600 )) $(( s % 3600 / 60 ))
    else printf '%d min' $(( (s + 59) / 60 )); fi
}

# the version of the running CrowdSec, "1.8.1" ("" when unknown); cached a minute
_cs_version_number() {
    local out v
    out=$(_cs_cache_get version 60) || {
        _cs_run out version || true
        out=$(printf '%s\n' "$out" | sed -n 's/^version:[[:space:]]*//p' | head -n 1)
        [[ -n "$out" ]] && printf '%s' "$out" | _cs_cache_put version
    }
    v="${out#v}"; v="${v%%-*}"
    [[ "$v" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] && printf '%s' "$v"
    return 0
}
_cs_version_full() { _cs_cache_get version 3600 2>/dev/null || true; }
# _cs_version_ge A B — dotted versions, numeric
_cs_version_ge() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" == "$2" ]]; }

# =============================================================================
# jq building blocks shared by the readers
# =============================================================================

# What a scenario is called in plain words, and which family it belongs to. ONE table: the page, the Discord messages
# (crowdsec-config.sh builds the Go template's if/else chain from it) and the previews all read it. First match wins.
_CS_LABEL_TABLE='[["crowdsecurity/ssh-slow-bf","SSH slow brute force","bruteforce"],["crowdsecurity/ssh-cve","SSH exploit attempt","exploit"],["crowdsecurity/ssh","SSH brute force","bruteforce"],["crowdsecurity/http-cve","Exploit attempt","exploit"],["crowdsecurity/CVE","Exploit attempt","exploit"],
 ["crowdsecurity/http-sqli","SQL injection probe","probe"],["crowdsecurity/http-xss","Cross-site scripting probe","probe"],["crowdsecurity/http-path-traversal","Path traversal probe","probe"],
 ["crowdsecurity/http-backdoors","Backdoor probe","exploit"],["crowdsecurity/http-admin-interface","Admin panel probe","probe"],["crowdsecurity/http-bad-user-agent","Known bad scanner","probe"],
 ["crowdsecurity/http-probing","Web probing","probe"],["crowdsecurity/http-sensitive-files","Sensitive file probe","probe"],["crowdsecurity/http-crawl","Aggressive crawler","probe"],
 ["crowdsecurity/http-generic-bf","Web login brute force","bruteforce"],["crowdsecurity/http-open-proxy","Open proxy probe","probe"],["crowdsecurity/http-wordpress","WordPress attack","probe"],
 ["crowdsecurity/http-dos","HTTP flood","bruteforce"],["crowdsecurity/nginx-req-limit","Request flood","bruteforce"],["LePresidente/","Application brute force","bruteforce"],
 ["crowdsecurity/traefik","Traefik abuse","probe"]]'
_CS_JQ_LABELS='
def label_table: '"$_CS_LABEL_TABLE"';
def scen_row: (. // "") as $s | ((label_table | map(. as $r | select($s | startswith($r[0]))) | .[0])
    // (if ($s | test("cve"; "i")) then ["", "Exploit attempt", "exploit"]
        elif ($s | test("(^|[-_/])bf($|[-_])|brute"; "i")) then ["", "Brute force", "bruteforce"]
        elif ($s | test("spam"; "i")) then ["", "Spam", "other"]
        else ["", "Attack blocked", "other"] end));
def scen_label: scen_row | .[1];
def scen_family: scen_row | .[2];
def alert_label: if (.kind // "") == "cscli" then (if ((.decisions // []) | map(.origin // "") | index("cscli-import")) != null then "Imported list" else "Manual ban" end) else ((.scenario // "") | scen_label) end;
def alert_family: if (.kind // "") == "cscli" then "manual" else ((.scenario // "") | scen_family) end;
'

# Go durations ("3h59m47s", "167h59m59s", "1.5s", "-5m") → seconds; ISO stamps with fractions → epoch seconds
_CS_JQ_DEFS="$_CS_JQ_LABELS"'
def dur_secs:
  if . == null or . == "" then 0
  else (tostring) as $s
    | ($s | startswith("-")) as $neg
    | ($s | ltrimstr("-") | [scan("([0-9]+(?:\\.[0-9]+)?)(ns|us|µs|ms|s|m|h)")]
        | map((.[0] | tonumber) * ({"ns": 0.000000001, "us": 0.000001, "µs": 0.000001, "ms": 0.001, "s": 1, "m": 60, "h": 3600}[.[1]]))
        | add // 0) as $v
    | if $neg then -$v else $v end
  end;
def iso_secs: if . == null or . == "" then 0 else (tostring | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch 0) end;
def cc: ((. // "") | tostring | ascii_upcase);
def decision_rows($asof):
  [ (. // [])[] as $a | ($a.decisions // [])[]
    | (.duration | dur_secs) as $left
    | select($left > 0)
    | { id: .id, value: .value, ip: .value, scope: .scope, type: .type, origin: (.origin // ""),
        scenario: (.scenario // $a.scenario // ""), simulated: (.simulated // false),
        duration: .duration, seconds_left: ($left | floor), expires_at: (($asof + $left) | floor | todate),
        permanent: ($left >= 31536000),
        created_at: ($a.created_at // ""), since: ($a.created_at // ""), alert_id: $a.id, events: ($a.events_count // 0),
        country: ($a.source.cn | cc), as_number: (($a.source.as_number // "") | tostring), as_name: ($a.source.as_name // ""),
        latitude: ($a.source.latitude // null), longitude: ($a.source.longitude // null),
        machine: ($a.machine_id // ""), kind: ($a.kind // ""),
        label: (if .origin == "cscli" then "Manual ban" elif .origin == "cscli-import" then "Imported ban" elif .origin == "CAPI" then "Community blocklist"
                elif (.origin | startswith("lists")) then "Blocklist" elif .origin == "console" then "CrowdSec console" else ((.scenario // $a.scenario // "") | scen_label) end),
        family: (if .origin == "cscli" or .origin == "cscli-import" then "manual" elif .origin == "CAPI" or (.origin | startswith("lists")) or .origin == "console" then "community" else ((.scenario // $a.scenario // "") | scen_family) end) } ];
def alert_row:
  { id: .id, scenario: (.scenario // ""), message: (.message // ""), events_count: (.events_count // 0),
    created_at: (.created_at // ""), start_at: (.start_at // ""), stop_at: (.stop_at // ""),
    machine: (.machine_id // ""), kind: (.kind // ""), simulated: (.simulated // false), remediation: (.remediation // false),
    capacity: (.capacity // 0), leakspeed: (.leakspeed // ""),
    # an imported list has no source of its own: its first address stands for it
    source: { value: (if (.source.value // "") == "" then ((.decisions // [])[0].value // "") else .source.value end), ip: (.source.ip // .source.value // ""),
              scope: (if (.source.scope // "") == "" then ((.decisions // [])[0].scope // "") else .source.scope end), range: (.source.range // ""),
              country: (.source.cn | cc), as_number: ((.source.as_number // "") | tostring), as_name: (.source.as_name // ""),
              latitude: (.source.latitude // null), longitude: (.source.longitude // null) },
    decisions: [ (.decisions // [])[] | { id: .id, type: .type, value: .value, scope: .scope, origin: (.origin // ""), duration: .duration, simulated: (.simulated // false) } ],
    meta: ((.meta // []) | map({key: .key, value: .value})) };
'

# =============================================================================
# Traefik side of the bouncer: the middleware file and the chain
# =============================================================================

# The bouncer plugin as Traefik's static config declares it: "name<TAB>version" (nothing when it is not declared there)
_CS_PLUGIN_MODULE="github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin"
_cs_plugin_declared() {
    local line ad cfg
    line=$(_traefik_stack_appdata 2>/dev/null) || return 0
    ad="${line#*$'\t'}"; cfg="$ad/Traefik/traefik.yml"; [[ -f "$cfg" ]] || return 0
    awk -v mod="$_CS_PLUGIN_MODULE" '
        function indent(l) { match(l, /^[ \t]*/); return RLENGTH }
        function flush() { if (cur != "" && tolower(m) == tolower(mod)) { print cur "\t" v; found = 1 } cur = ""; m = ""; v = "" }
        { sub(/\r$/, ""); sub(/[ \t]+#.*$/, "") }
        /^[ \t]*(#.*)?$/ { next }
        indent($0) == 0 { flush(); inx = ($0 ~ /^experimental:[ \t]*$/); inp = 0; next }
        inx && /^[ \t]+plugins:[ \t]*$/ { inp = 1; pind = indent($0); nind = 0; next }
        inp && indent($0) <= pind { flush(); inp = 0 }
        inp && nind == 0 { nind = indent($0) }
        inp && indent($0) == nind && /:[ \t]*$/ { flush(); n = $0; sub(/^[ \t]+/, "", n); sub(/:[ \t]*$/, "", n); gsub(/["\x27]/, "", n); cur = n; next }
        inp && tolower($0) ~ /^[ \t]+modulename:/ { x = $0; sub(/^[^:]*:[ \t]*/, "", x); gsub(/["\x27 \t]/, "", x); m = x; next }
        inp && tolower($0) ~ /^[ \t]+version:/ { x = $0; sub(/^[^:]*:[ \t]*/, "", x); gsub(/["\x27 \t]/, "", x); v = x; next }
        END { flush() }' "$cfg" 2>/dev/null | head -n 1
}

# The plugin's settings as the middleware file has them, as JSON (keys the way the page names them). Lists are arrays; a value the file does not carry is left out.
# $1 = the middleware file
_cs_plugin_read_file() {
    local f="$1"
    [[ -f "$f" ]] || { printf '{}'; return 0; }
    awk '
        function val(l,   x) { x = l; sub(/^[^:]*:[ \t]*/, "", x); sub(/[ \t]+#.*$/, "", x); gsub(/^["\x27]|["\x27]$/, "", x); return x }
        /^[ \t]{10}[A-Za-z]+:/ && !/^[ \t]{12}/ {
            key = $0; sub(/^[ \t]+/, "", key); sub(/:.*$/, "", key); list = ""
            if (key == "forwardedHeadersTrustedIPs" || key == "clientTrustedIPs") { list = key; next }
            v = val($0)
            if (key == "crowdsecMode") print "S\tmode\t" v
            else if (key == "updateIntervalSeconds") print "S\tupdate_interval\t" v
            else if (key == "defaultDecisionSeconds") print "S\tdefault_decision_seconds\t" v
            else if (key == "httpTimeoutSeconds") print "S\thttp_timeout\t" v
            else if (key == "remediationStatusCode") print "S\tremediation_status_code\t" v
            else if (key == "logLevel") print "S\tlog_level\t" v
            else if (key == "enabled") print "S\tenabled\t" v
            else if (key == "crowdsecLapiKey") print "S\thas_key\t" (v != "" && v !~ /^__/ ? "true" : "false")
            next
        }
        list != "" && /^[ \t]{12}-[ \t]*/ { x = $0; sub(/^[ \t]*-[ \t]*/, "", x); sub(/[ \t]+#.*$/, "", x); gsub(/^["\x27]|["\x27]$/, "", x); if (x != "") print "L\t" (list == "clientTrustedIPs" ? "client_trusted_ips" : "forwarded_headers_trusted_ips") "\t" x; next }
        /^[ \t]{10}[A-Za-z]/ { list = "" }
        /^#[ \t]*dcs-plugin:[ \t]/ { x = $0; sub(/^#[ \t]*dcs-plugin:[ \t]*/, "", x); print "M\tmarker\t" x }' "$f" 2>/dev/null \
    | jq -Rsc '
        split("\n") | map(select(length > 0) | split("\t")) as $rows
        | reduce $rows[] as $r ({}; if $r[0] == "S" then .[$r[1]] = ($r[2] | if test("^[0-9]+$") then tonumber elif . == "true" then true elif . == "false" then false else . end)
                                    elif $r[0] == "L" then .[$r[1]] = ((.[$r[1]] // []) + [$r[2]])
                                    elif $r[0] == "M" then .marker = ($r[2] | try fromjson catch null)
                                    else . end)
        | . + {managed: (.marker != null)} | del(.marker)' 2>/dev/null || printf '{}'
}

# JSON: {routes_dir, middleware_file, in_chain, plugin: {...}} — what DCS wrote when it registered the bouncer, and what Traefik's own files say about the plugin
_cs_enforcement_json() {
    local dir mw="" chain_file="" in_chain=false decl="" pname="" pver="" mtime=0 settings='{}' loaded=null tr_running=false own='[]'
    dir=$(_find_traefik_routes_dir 2>/dev/null) || dir=""
    if [[ -n "$dir" && -d "$dir" ]]; then
        mw=$(find "$dir" -maxdepth 2 -name 'crowdsec-bouncer.yml' 2>/dev/null | head -n 1)
        chain_file=$(_traefik_chain_file "$dir")
        if [[ -n "$chain_file" ]] && _traefik_chain_has "$chain_file" crowdsec-bouncer; then in_chain=true; fi
        # the person's own definition of the middleware (in TraefikRoutes.yml, say): every file that defines it except the one DCS wrote
        local f base own_files=()
        base="$(dirname "$dir")/"
        while IFS= read -r f; do [[ -n "$f" && "$f" != "$mw" ]] && own_files+=("${f#"$base"}"); done < <(_traefik_mw_files crowdsec-bouncer "$dir")
        (( ${#own_files[@]} )) && own=$(printf '%s\n' "${own_files[@]}" | jq -R . | jq -sc .)
    fi
    if [[ -n "$mw" ]]; then mtime=$(stat -c %Y "$mw" 2>/dev/null || echo 0); settings=$(_cs_plugin_read_file "$mw"); fi
    decl=$(_cs_plugin_declared); pname="${decl%%$'\t'*}"; pver="${decl#*$'\t'}"; [[ -n "$decl" ]] || { pname=""; pver=""; }
    local trj="${CS_TRAEFIK:-}"; [[ "$trj" == \{* ]] || trj='{}'
    if [[ "$(jq -r '.running // false' <<< "$trj" 2>/dev/null)" == true ]]; then
        tr_running=true
        if [[ -n "$decl" ]]; then if _traefik_static_newer 2>/dev/null; then loaded=false; else loaded=true; fi; fi
    fi
    jq -nc --arg d "$dir" --arg m "$mw" --argjson c "$in_chain" --arg cf "$chain_file" --argjson mt "$mtime" --arg pn "$pname" --arg pv "$pver" --argjson set "$settings" --argjson loaded "$loaded" --argjson run "$tr_running" --argjson own "$own" \
        '{routes_dir: $d, middleware_file: $m, middleware_present: ($m != ""), middleware_mtime: $mt, in_chain: $c, chain_file: $cf, defined_elsewhere: $own, own_middleware: ($own | length > 0),
          plugin: {declared: ($pn != ""), name: $pn, version: $pv, module: "github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin", traefik_running: $run, loaded: $loaded,
                   settings: $set, mode: ($set.mode // null), managed: ($set.managed // false), key_present: ($set.has_key // false)}}'
}

# =============================================================================
# The status: which state is CrowdSec in, and what to do about it
# =============================================================================

# JSON for one fix button. kind api = the UI calls the endpoint; kind ui = the UI goes somewhere
_cs_fix() { jq -nc --arg id "$1" --arg label "$2" --arg kind "$3" --arg method "${4:-}" --arg path "${5:-}" --argjson body "${6:-null}" --argjson primary "${7:-false}" \
    '{id: $id, label: $label, kind: $kind, method: $method, path: $path, body: $body, primary: $primary}'; }

# the last lines of the container's log (for the states where something is wrong)
_cs_log_tail() {
    local n="${1:-25}"
    [[ -n "$CS_NAME" ]] || return 0
    timeout 8 docker logs --tail "$((n * 4))" "$CS_NAME" 2>&1 </dev/null | grep -v 'module=lapi' | tail -n "$n" | cut -c1-400
}

# stacks that define a CrowdSec service in their compose file (a container that was removed)
_cs_defined_in() {
    local f
    for f in "$COMPOSE_DIR"/*/docker-compose.yml; do
        [[ -f "$f" ]] || continue
        if grep -qiE '^[[:space:]]+container_name:[[:space:]]*crowdsec[[:space:]]*$' "$f" 2>/dev/null; then basename "$(dirname "$f")"; return 0; fi
    done
    return 1
}

# The pre-flight for the "not deployed" page: what deploying would do and whether it can
_cs_preflight_json() {
    local tdir="$TEMPLATES_DIR/crowdsec" tmpl=false title="CrowdSec" tstack="" ttarget="" tmeta='null' stacks="" traefik_stack="" s
    local -a blockers=() warnings=()
    [[ -f "$tdir/template.json" && -f "$tdir/docker-compose.yml" ]] && tmpl=true
    if [[ "$tmpl" == true ]]; then
        title=$(jq -r '.title // "CrowdSec"' "$tdir/template.json" 2>/dev/null)
        ttarget=$(jq -r '.target_stack // ""' "$tdir/template.json" 2>/dev/null)
        tmeta=$(jq -c '{name, title, description, target_stack, variables: [(.variables // [])[] | {name, label, description, default, required}]}' "$tdir/template.json" 2>/dev/null) || tmeta='null'
    else
        blockers+=("The crowdsec template is missing from this DCS install")
    fi
    stacks=$(_api_get_stacks 2>/dev/null | tr '\n' ' ')
    # the stack Traefik lives in: the bouncer's compose and Traefik's access log are mounted from the same stack
    if [[ "$(jq -r '.present' <<< "$CS_TRAEFIK")" == true ]]; then
        traefik_stack=$(jq -r '.workdir // ""' <<< "$CS_TRAEFIK"); traefik_stack="${traefik_stack##*/}"
        [[ -n "$traefik_stack" && -d "$COMPOSE_DIR/$traefik_stack" ]] || traefik_stack=$(jq -r '.project // ""' <<< "$CS_TRAEFIK")
        [[ -n "$traefik_stack" && -d "$COMPOSE_DIR/$traefik_stack" ]] || traefik_stack=""
        [[ "$(jq -r '.running' <<< "$CS_TRAEFIK")" == true ]] || warnings+=("Traefik exists but is not running: bans cannot be enforced until it is")
    else
        warnings+=("Traefik was not found on this server: CrowdSec will detect attacks and can alert you, but nothing will block them at the door")
    fi
    if [[ -n "$traefik_stack" ]]; then tstack="$traefik_stack"
    elif [[ -n "$ttarget" && -d "$COMPOSE_DIR/$ttarget" ]]; then tstack="$ttarget"
    else for s in $stacks; do tstack="$s"; break; done; fi
    [[ -n "$tstack" ]] || blockers+=("There is no stack to deploy into. Create a stack first")
    local discord=false
    _discord_webhook >/dev/null 2>&1 && discord=true
    [[ "$discord" == true ]] || warnings+=("No Discord webhook is set: CrowdSec will not send alerts anywhere until you add one on the Discord tab")
    jq -nc --argjson template "$tmeta" --argjson traefik "$CS_TRAEFIK" --arg target "$tstack" --arg stacks "$stacks" --argjson discord "$discord" \
        --arg blockers "$(printf '%s\n' "${blockers[@]}")" --arg warnings "$(printf '%s\n' "${warnings[@]}")" --arg dockerv "$(timeout 5 docker version --format '{{.Server.Version}}' 2>/dev/null)" \
        --argjson enforce "$([[ -n "$traefik_stack" ]] && echo true || echo false)" '
        { docker: {ok: true, version: $dockerv}, traefik: $traefik, template: $template, target_stack: $target,
          target_reason: (if $enforce then "Traefik lives in this stack, and CrowdSec reads its access log from there" else "the stack the template is made for" end),
          stacks: ($stacks | split(" ") | map(select(length > 0))), discord: {configured: $discord},
          enforcement: $enforce, blockers: ($blockers | split("\n") | map(select(length > 0))), warnings: ($warnings | split("\n") | map(select(length > 0))),
          can_deploy: (($blockers | split("\n") | map(select(length > 0)) | length) == 0) }'
}

# JSON of the fragments a healthy CrowdSec adds to the status (several cscli calls at once)
_cs_gather() {
    local d rc_allow
    d=$(mktemp -d "${TMPDIR:-/tmp}/dcs-cs-g.XXXXXX") || return 1
    local -a pids=()
    ( _cs_json decisions 6 decisions list --limit 2000 > "$d/decisions" 2>/dev/null ) & pids+=($!)
    ( _cs_json alerts_24h 15 alerts list --since 24h --limit 0 > "$d/alerts" 2>/dev/null ) & pids+=($!)
    ( _cs_json bouncers 8 bouncers list > "$d/bouncers" 2>/dev/null ) & pids+=($!)
    ( _cs_json machines 15 machines list > "$d/machines" 2>/dev/null ) & pids+=($!)
    ( _cs_json metrics 10 metrics > "$d/metrics" 2>/dev/null ) & pids+=($!)
    ( _cs_json hub 90 hub list > "$d/hub" 2>/dev/null ) & pids+=($!)
    ( _cs_json allowlists 8 allowlists list > "$d/allowlists" 2>/dev/null; echo $? > "$d/allowlists.rc"; printf '%s' "$CS_ERR" > "$d/allowlists.err" ) & pids+=($!)
    ( _cs_version_number > "$d/version" 2>/dev/null ) & pids+=($!)
    wait "${pids[@]}" 2>/dev/null
    rc_allow=$(cat "$d/allowlists.rc" 2>/dev/null || echo 1)
    local mech="unknown"
    if [[ "$rc_allow" == 0 ]]; then mech=native
    elif grep -qi 'unknown command' "$d/allowlists.err" 2>/dev/null; then mech=parser; fi
    local asof; asof=$(date +%s)
    local f
    for f in decisions alerts bouncers machines metrics hub allowlists; do [[ -s "$d/$f" ]] || printf '[]' > "$d/$f"; done
    [[ -s "$d/metrics" && "$(head -c 1 "$d/metrics")" == "{" ]] || printf '{}' > "$d/metrics"
    [[ "$(head -c 1 "$d/hub")" == "{" ]] || printf '{}' > "$d/hub"
    jq -nc --slurpfile dec "$d/decisions" --slurpfile al "$d/alerts" --slurpfile bo "$d/bouncers" --slurpfile ma "$d/machines" --slurpfile me "$d/metrics" \
        --slurpfile hb "$d/hub" --slurpfile alw "$d/allowlists" --arg mech "$mech" --arg ver "$(cat "$d/version" 2>/dev/null)" --argjson asof "$asof" \
        --arg bname "$CROWDSEC_BOUNCER_NAME" "$_CS_JQ_DEFS"'
        ($dec[0] | decision_rows($asof)) as $rows
        | ($me[0].acquisition // {}) as $acq
        | ([$acq | to_entries[] | {name: .key, reads: (.value.reads // 0), parsed: (.value.parsed // 0), unparsed: (.value.unparsed // 0), pour: (.value.pour // 0)}]) as $sources
        | ($sources | map(.reads) | add // 0) as $reads | ($sources | map(.parsed) | add // 0) as $parsed
        | ($me[0].decisions // {}) as $md
        | ([$md | to_entries[] | .value | to_entries[] | select(.key == "CAPI" or (.key | startswith("lists"))) | .value | to_entries[] | .value] | add // 0) as $community
        | ([$md | to_entries[] | .value | to_entries[] | .value | to_entries[] | .value] | add // 0) as $active_all
        | ($bo[0] // []) as $bouncers
        | ($bouncers | map(select(.name == $bname)) | .[0] // null) as $dcsb
        | ($hb[0] // {}) as $hub
        | { rows: $rows[0:50],
            version_number: $ver,
            allowlist_mechanism: $mech,
            counts: { decisions: ($rows | length), decisions_active: ($rows | map(select(.simulated | not)) | length), simulated: ($rows | map(select(.simulated)) | length),
                      community: $community, alerts_24h: ($al[0] | length), machines: ($ma[0] | length), bouncers: ($bouncers | length),
                      collections: (($hub.collections // []) | length), scenarios: (($hub.scenarios // []) | length), parsers: (($hub.parsers // []) | length),
                      updates: ([($hub | to_entries[] | .value | if type == "array" then .[] else empty end) | select((.status // "") | contains("update-available"))] | length),
                      countries_24h: ([$al[0][] | .source.cn | select(. != null and . != "")] | unique | length),
                      sources_24h: ([$al[0][] | .source.value] | unique | length) },
            bouncers: ($bouncers | map({name, type: (.type // ""), version: (.version // ""), ip_address: (.ip_address // ""), last_pull: (.last_pull // null), created_at: (.created_at // ""), revoked: (.revoked // false)})),
            bouncer: (if $dcsb == null then {registered: false, name: $bname} else {registered: true, name: $bname, last_pull: ($dcsb.last_pull // null), type: ($dcsb.type // ""), version: ($dcsb.version // ""), ip_address: ($dcsb.ip_address // ""), created_at: ($dcsb.created_at // "")} end),
            machines: ($ma[0] | map({id: (.machineId // ""), ip_address: (.ipAddress // ""), version: (.version // ""), validated: (.isValidated // false), last_push: (.last_push // null), last_heartbeat: (.last_heartbeat // null), os: (.os // ""), datasources: (.datasources // {})})),
            acquisition: {sources: $sources, reads: $reads, parsed: $parsed, unparsed: ($sources | map(.unparsed) | add // 0), parse_rate: (if $reads > 0 then (($parsed / $reads * 1000 | round) / 1000) else null end)},
            active_all: $active_all }' 2>/dev/null
    rm -rf "$d"
}

# The client-independent status (cached a few seconds by the handler). Prints one JSON object.
_cs_status_core() {
    local now state title detail extra='{}' fixes='[]' issues='[]' logs='[]' details='null' pre='null' defined=""
    now=$(date +%s)
    _cs_probe
    if (( CS_DOCKER == 0 )); then
        state=docker_unavailable; title="Docker is not answering"; detail="$CS_DOCKER_ERR"
        fixes="[$(_cs_fix retry "Check again" ui "" "" null true)]"
    elif [[ -z "$CS_NAME" ]]; then
        defined=$(_cs_defined_in) || defined=""
        if [[ -n "$defined" ]]; then
            state=stopped; title="CrowdSec is defined in the $defined stack but has no container"
            detail="The stack file describes CrowdSec, yet the container is gone (a docker compose down, or a failed start). Start the stack to bring it back."
            fixes="[$(_cs_fix start_stack "Start the $defined stack" api POST "/stacks/$defined/start" null true), $(_cs_fix deploy "Deploy again" ui "" "" null false)]"
            CS_RSTATE=missing
        else
            state=not_deployed; title="CrowdSec is not deployed"
            detail="CrowdSec reads Traefik's access log, recognises attackers and bans them. Deploy it to use this page."
            pre=$(_cs_preflight_json)
            fixes="[$(_cs_fix deploy "Deploy CrowdSec" ui "" "" null true)]"
        fi
    else
        case "$CS_RSTATE" in
            running) ;;
            restarting)
                state=crash_loop; title="CrowdSec keeps restarting"
                detail="The container starts and dies again (restarted $CS_RESTARTS times). That is almost always a configuration error; the log says which."
                fixes="[$(_cs_fix logs "Show the log" ui "" "" null true), $(_cs_fix restart "Restart" api POST /crowdsec/service '{"action":"restart"}' false)]" ;;
            *)
                state=stopped; title="CrowdSec is stopped"
                detail="The container $CS_NAME is $CS_RSTATE${CS_EXIT:+ (exit code $CS_EXIT)}. While it is down nothing watches the logs and the bouncer keeps the bans it already has."
                fixes="[$(_cs_fix start "Start CrowdSec" api POST /crowdsec/service '{"action":"start"}' true), $(_cs_fix logs "Show the log" ui "" "" null false)]" ;;
        esac
        if [[ -z "${state:-}" ]]; then
            case "$CS_HEALTH" in
                unhealthy)
                    state=unhealthy; title="CrowdSec is running but unhealthy"
                    detail="Docker's health check (cscli version) is failing. A restart usually clears it; if it comes back, the log will say why."
                    fixes="[$(_cs_fix restart "Restart" api POST /crowdsec/service '{"action":"restart"}' true), $(_cs_fix logs "Show the log" ui "" "" null false)]" ;;
                starting)
                    state=starting; title="CrowdSec is starting"
                    detail="The container is up and Docker is still waiting for its first health check. This takes up to a minute after a deploy or a restart."
                    fixes="[$(_cs_fix logs "Show the log" ui "" "" null false)]" ;;
            esac
        fi
        if [[ -z "${state:-}" ]]; then
            local lapi_out
            # shellcheck disable=SC2034  # only the exit status of `cscli lapi status` matters
            if _cs_run lapi_out lapi status; then
                state=healthy
            else
                state=lapi_unreachable; title="The CrowdSec API is not answering"
                detail="The container runs but cscli cannot reach its local API: $(_cs_errline). Bans cannot be listed or changed until it answers."
                fixes="[$(_cs_fix restart "Restart" api POST /crowdsec/service '{"action":"restart"}' true), $(_cs_fix logs "Show the log" ui "" "" null false)]"
            fi
        fi
    fi
    if [[ "$state" != healthy && "$state" != not_deployed && "$state" != docker_unavailable && -n "$CS_NAME" ]]; then
        logs=$(_cs_log_tail 25 | jq -R . | jq -sc .)
        [[ "$logs" == \[* ]] || logs='[]'
    fi
    if [[ "$state" == healthy ]]; then
        details=$(_cs_gather) || details='null'
        [[ "$details" == \{* ]] || details='null'
        title="CrowdSec is protecting this server"; detail=""
        local enf; enf=$(_cs_enforcement_json)
        extra=$(jq -nc --argjson d "$details" --argjson tr "$CS_TRAEFIK" --argjson enf "$enf" --arg wd "$CS_WORKDIR" "$_CS_JQ_DEFS"'
            ($d.bouncers | map(select((.type | test("traefik"; "i")) or (.name | test("traefik"; "i")))) | length) as $tb
            # When the person defines the crowdsec-bouncer middleware themselves, Traefik uses their key and not the bouncer DCS registered: the newest pull of any Traefik bouncer is the one that counts
            | ($d.bouncers | map(select(((.type // "") | test("traefik"; "i")) or ((.name // "") | test("traefik"; "i"))) | select(.last_pull != null)) | sort_by(.last_pull | iso_secs) | last // null) as $live
            | (if ($enf.own_middleware // false) and $live != null and (($d.bouncer.registered | not) or ($d.bouncer.last_pull == null) or (($live.last_pull | iso_secs) > ($d.bouncer.last_pull | iso_secs)))
                 then ($d.bouncer + {registered: true, last_pull: $live.last_pull, pulled_by: $live.name} + (if $d.bouncer.registered then {} else {name: $live.name} end))
                 else $d.bouncer end) as $b
            | (($enf.middleware_present or ($enf.own_middleware // false))) as $mwok
            | ( []
              + (if $tr.present and ($d.bouncers | length) == 0 then [{code: "bouncer_missing", severity: "warning", title: "Bans are not enforced at your proxy",
                    detail: "No bouncer is registered, so Traefik never hears about a ban: CrowdSec decides, nothing blocks. Registering the Traefik bouncer fixes it.",
                    fix: {id: "register_bouncer", label: "Register the Traefik bouncer", kind: "api", method: "POST", path: "/crowdsec/bouncers/register-traefik", body: null, primary: true}}] else [] end)
              + (if $tr.present and $b.registered and $enf.routes_dir != "" and (($mwok | not) or ($enf.in_chain | not)) then [{code: "bouncer_unchained", severity: "warning", title: "Traefik is not using the bouncer",
                    detail: ("The bouncer is registered in CrowdSec, but its middleware is not in Traefik'"'"'s chain (" + (if $mwok then "the chain does not list it" else "the middleware file is missing" end) + "). Registering again " + (if $enf.own_middleware then "adds it to the chain." else "rewrites both." end)),
                    fix: {id: "register_bouncer", label: "Register again", kind: "api", method: "POST", path: "/crowdsec/bouncers/register-traefik", body: null, primary: true}}] else [] end)
              + (if $tr.present and $b.registered and $mwok and ($enf.plugin.declared | not) then [{code: "plugin_undeclared", severity: "warning", title: "Traefik does not know the bouncer plugin",
                    detail: "The middleware file is there, but Traefik'"'"'s static configuration does not declare the CrowdSec bouncer plugin, so Traefik refuses the middleware and every route that uses the chain answers 404. Registering again declares it and restarts Traefik once.",
                    fix: {id: "register_bouncer", label: "Register again", kind: "api", method: "POST", path: "/crowdsec/bouncers/register-traefik", body: null, primary: true}}] else [] end)
              + (if $tr.present and $enf.plugin.declared and ($enf.plugin.loaded == false) and $b.registered then [{code: "plugin_not_loaded", severity: "warning", title: "Traefik has not loaded the bouncer plugin yet",
                    detail: "The plugin was declared after Traefik started, and Traefik only loads plugins at start. Until it is restarted the middleware is refused and the routes that use the chain answer 404.",
                    fix: {id: "restart_traefik", label: "Restart Traefik", kind: "api", method: "POST", path: "/crowdsec/traefik/restart", body: null, primary: true}}] else [] end)
              + (if $tr.present and $d.bouncer.registered and $enf.middleware_present and (($enf.own_middleware // false) | not) and (($d.bouncer.created_at // "") != "") and (($d.bouncer.created_at | iso_secs) > ($enf.middleware_mtime + 120)) then [{code: "bouncer_key_stale", severity: "warning", title: "Traefik'"'"'s key for the bouncer is out of date",
                    detail: "The bouncer was registered again after the middleware file was written, so the key in that file no longer opens CrowdSec'"'"'s API and nothing is enforced. Registering again writes a fresh key.",
                    fix: {id: "register_bouncer", label: "Register again", kind: "api", method: "POST", path: "/crowdsec/bouncers/register-traefik", body: null, primary: true}}] else [] end)
              + (if $tr.present and ($tr.running // false) and $enf.in_chain and $b.registered and $b.last_pull != null and ((now - ($b.last_pull | iso_secs)) > 1800) then [{code: "bouncer_stale", severity: "warning", title: "Traefik has not asked the bouncer for a long time",
                    detail: "The plugin reports in to CrowdSec at least every ten minutes while Traefik runs it. Nothing for over half an hour means Traefik is not running the plugin (or cannot reach CrowdSec). Look at Traefik'"'"'s log; registering again rewrites the key and the middleware.",
                    fix: {id: "register_bouncer", label: "Register again", kind: "api", method: "POST", path: "/crowdsec/bouncers/register-traefik", body: null, primary: false}}] else [] end)
              + (if $b.registered and $b.last_pull == null and $tr.present then [{code: "bouncer_idle", severity: "info", title: "Traefik has not asked the bouncer yet",
                    detail: "The bouncer is registered but has never pulled a decision. It starts pulling with the first request that goes through the crowdsec-bouncer middleware.", fix: null}] else [] end)
              + (if $tr.present and $enf.middleware_present and ($enf.own_middleware // false) then [{code: "bouncer_duplicate", severity: "info", title: "The bouncer middleware is defined twice",
                    detail: ("Traefik reads crowdsec-bouncer from " + ($enf.defined_elsewhere | join(", ")) + " and skips the copy DCS wrote (" + ($enf.middleware_file | split("/") | .[-2:] | join("/")) + "), so the bouncer DCS registered (" + $d.bouncer.name + ") is not the one in use"
                      + (if $b.pulled_by then ": Traefik asks CrowdSec as " + $b.pulled_by else "" end) + ". Protection is not affected. Delete DCS'"'"'s copy and its bouncer to tidy up, or keep them as a spare."), fix: null}] else [] end)
              + (if ($d.machines | map((.datasources // {}) | to_entries | map(.value) | add // 0) | add // 0) == 0 then [{code: "no_datasource", severity: "warning", title: "CrowdSec is not reading any log",
                    detail: "No acquisition source is configured, so nothing is analysed and no attack can be detected. The Traefik access log should be listed in /etc/crowdsec/acquis.d.", fix: null}] else [] end)
              + (if $d.counts.updates > 0 then [{code: "hub_updates", severity: "info", title: (($d.counts.updates | tostring) + " hub item(s) can be updated"),
                    detail: "Newer versions of installed collections, scenarios or parsers exist. Updating keeps the detections current.",
                    fix: {id: "open_hub", label: "Open the hub", kind: "ui", method: "", path: "", body: null, primary: false}}] else [] end) ) as $issues
            | {issues: $issues, enforcement: $enf, bouncer: $b}')
        issues=$(jq -c '.issues' <<< "$extra")
        if [[ "$(jq 'map(select(.severity == "warning")) | length' <<< "$issues")" -gt 0 ]]; then title="CrowdSec is running, but needs attention"; fi
    fi
    jq -nc --arg state "${state:-unknown}" --arg title "$title" --arg detail "$detail" --argjson fixes "$fixes" --argjson logs "$logs" --argjson pre "$pre" \
        --argjson d "$details" --argjson extra "$extra" --arg name "$CS_NAME" --arg rstate "$CS_RSTATE" --arg health "$CS_HEALTH" --arg image "$CS_IMAGE" \
        --argjson restarts "${CS_RESTARTS:-0}" --argjson exit "${CS_EXIT:-0}" --arg started "$CS_STARTED" --argjson traefik "$CS_TRAEFIK" --arg defined "$defined" \
        --arg proj "$CS_PROJECT" --argjson now "$now" --arg ver "$(_cs_version_full)" --arg dockerv "$([[ "$CS_DOCKER" == 1 ]] && timeout 5 docker version --format '{{.Server.Version}}' 2>/dev/null)" '
        { state: $state, title: $title, detail: $detail, fixes: $fixes,
          installed: ($state == "healthy" or $state == "unhealthy" or $state == "starting" or $state == "lapi_unreachable"),
          running: ($rstate == "running"), deployed: ($name != ""), container: $name, container_state: $rstate, health: $health, image: $image,
          restart_count: $restarts, exit_code: $exit, started_at: $started, stack: (if $proj != "" then $proj else null end), defined_in: (if $defined != "" then $defined else null end),
          docker: {ok: ($state != "docker_unavailable"), version: $dockerv}, traefik: $traefik,
          version: ($ver | sub("^v"; "")), log_tail: $logs, preflight: $pre, generated_at: $now }
        + (if $d == null then {} else {
            version_number: $d.version_number, allowlist_mechanism: $d.allowlist_mechanism, counts: $d.counts, bouncer: $d.bouncer, bouncers: $d.bouncers, machines: $d.machines,
            acquisition: $d.acquisition, decisions: $d.rows[0:50], features: {allowlists: ($d.allowlist_mechanism == "native"), decisions_import: true, simulation: true}
          } end)
        + $extra + (if $extra.issues == null then {issues: []} else {} end)' 2>/dev/null
}

# GET /crowdsec/status — Which state CrowdSec is in (not deployed, stopped, unhealthy, healthy …), what is wrong and the one-click fixes, plus the numbers for the status strip; the ban list is included for the dashboard card
handle_crowdsec_status() {
    local core client="${CLIENT_IP:-}" banned=false v
    if ! core=$(_cs_cache_get status 5); then
        core=$(_cs_status_core)
        if [[ "$core" != \{* ]]; then _api_error 500 "Could not work out the CrowdSec state"; return; fi
        printf '%s' "$core" | _cs_cache_put status
    fi
    if [[ -n "$client" ]] && _crowdsec_valid_ip "$client"; then
        while IFS= read -r v; do
            [[ -n "$v" ]] || continue
            if [[ "$v" == "$client" ]] || { [[ "$v" == */* ]] && _cs_covers "$v" "$client"; }; then banned=true; break; fi
        done < <(jq -r '(.decisions // [])[] | select(.simulated | not) | .value' <<< "$core")
    fi
    local trusted state='{}'
    trusted=$(_crowdsec_trusted_list | jq -R . | jq -sc .)
    [[ -f "$CROWDSEC_SYNC_STATE" ]] && state=$(cat "$CROWDSEC_SYNC_STATE" 2>/dev/null)
    [[ "$state" == \{* ]] || state='{}'
    _api_success "$(jq -c --arg ip "$client" --argjson banned "$banned" --argjson trusted "$trusted" --argjson wl "$state" \
        '. + {client_ip: $ip, client_banned: $banned, trusted: $trusted, whitelist: $wl, decision_count: ((.decisions // []) | length), message: (if .state == "not_deployed" then "CrowdSec is not running. Deploy it from the CrowdSec page to enable protection." else .title end)}' <<< "$core")"
}

# =============================================================================
# Bans (decisions)
# =============================================================================

# a scenario as it appears in filters: hub names, and the free text of a manual ban (which may hold quotes)
_CS_SCENARIO_RE="^[A-Za-z0-9][A-Za-z0-9._/:@ +'()-]{0,119}\$"

# The addresses a ban must never take down: the caller, this server, the home address, the trusted list.
# Prints "code<TAB>address" lines.
_cs_protected_addresses() {
    local a ip
    [[ -n "${CLIENT_IP:-}" ]] && _crowdsec_valid_ip "$CLIENT_IP" && printf 'own\t%s\n' "$CLIENT_IP"
    for a in $(hostname -I 2>/dev/null); do printf 'server\t%s\n' "$a"; done
    ip=""
    [[ -f "$CROWDSEC_SYNC_STATE" ]] && ip=$(jq -r '.public_ip // ""' "$CROWDSEC_SYNC_STATE" 2>/dev/null)
    [[ -n "$ip" ]] && printf 'home\t%s\n' "$ip"
    ip=""
    [[ -f "$CROWDSEC_SYNC_STATE" ]] && ip=$(jq -r '.home_ipv6 // ""' "$CROWDSEC_SYNC_STATE" 2>/dev/null)
    [[ -n "$ip" ]] && _crowdsec_valid_ip "$ip" && printf 'home\t%s\n' "$ip"
    if [[ -f "${DDNS_IP_FILE:-}" ]]; then ip=$(head -c 64 "$DDNS_IP_FILE" 2>/dev/null | tr -d '[:space:]'); _crowdsec_valid_ip "$ip" && printf 'home\t%s\n' "$ip"; fi
    while IFS= read -r a; do [[ -n "$a" ]] && _crowdsec_valid_ip "$a" && printf 'trusted\t%s\n' "$a"; done < <(_crowdsec_trusted_list)
    return 0
}

# _cs_ban_guard VALUE — the self-lockout guard for a normalised target. Returns 1 with CS_GUARD_CODE / CS_GUARD_MSG set when it must not be banned.
# (the private ranges and the protected addresses are collected and turned into hex once per request: an import checks thousands of entries)
CS_GUARD_CODE=""; CS_GUARD_MSG=""; CS_PROT_LOADED=0; CS_PROT_LINES=""
CS_PRIV_H=(); CS_PRIV_B=(); CS_PROT_C=(); CS_PROT_A=(); CS_PROT_H=(); CS_PROT_B=()
_cs_guard_load() {
    local n code addr
    CS_PROT_LINES=$(_cs_protected_addresses); CS_PROT_LOADED=1
    CS_PRIV_H=(); CS_PRIV_B=(); CS_PROT_C=(); CS_PROT_A=(); CS_PROT_H=(); CS_PROT_B=()
    for n in "${_CS_PRIVATE_NETS[@]}"; do
        if _cs_prep "$n"; then CS_PRIV_H+=("$CS_PH"); CS_PRIV_B+=("$CS_PB"); fi
    done
    while IFS=$'\t' read -r code addr; do
        [[ -n "$addr" ]] || continue
        if _cs_prep "$addr"; then CS_PROT_C+=("$code"); CS_PROT_A+=("$addr"); CS_PROT_H+=("$CS_PH"); CS_PROT_B+=("$CS_PB"); fi
    done <<< "$CS_PROT_LINES"
}
_cs_ban_guard() {
    local v="$1" bits="" code addr i vh vb
    CS_GUARD_CODE=""; CS_GUARD_MSG=""
    if (( CS_PROT_LOADED == 0 )); then _cs_guard_load; fi
    if [[ "$v" == */* ]]; then
        bits="${v#*/}"
        if { _cs_is_v4 "${v%%/*}" && (( bits < 8 )); } || { ! _cs_is_v4 "${v%%/*}" && (( bits < 16 )); }; then
            CS_GUARD_CODE=too_broad; CS_GUARD_MSG="$v is far too wide a range: it would ban a large part of the internet. Use a narrower network (a /8 or smaller for IPv4, a /16 or smaller for IPv6)."; return 1
        fi
    fi
    _cs_prep "$v" || return 0         # something that is no address or network covers nothing (the callers have normalised it already)
    vh="$CS_PH"; vb="$CS_PB"
    for i in "${!CS_PRIV_H[@]}"; do
        if _cs_cover_hex "${CS_PRIV_H[i]}" "${CS_PRIV_B[i]}" "$vh" "$vb"; then
            CS_GUARD_CODE=private; CS_GUARD_MSG="$v is a private, loopback or link-local address. The Traefik bouncer trusts your LAN, so this ban could never block anything and could confuse other tools."; return 1
        fi
    done
    for i in "${!CS_PROT_H[@]}"; do
        if _cs_cover_hex "$vh" "$vb" "${CS_PROT_H[i]}" "${CS_PROT_B[i]}" || _cs_cover_hex "${CS_PROT_H[i]}" "${CS_PROT_B[i]}" "$vh" "$vb"; then
            code="${CS_PROT_C[i]}"; addr="${CS_PROT_A[i]}"
            case "$code" in
                own) CS_GUARD_MSG="$v is your own address ($addr): banning it would lock you out of the sites behind Traefik." ;;
                server) CS_GUARD_MSG="$v covers this server's own address ($addr): the server would ban itself." ;;
                home) CS_GUARD_MSG="$v covers your home address ($addr): DCS keeps that address allowed so you can never lock yourself out." ;;
                *) CS_GUARD_MSG="$v covers $addr, which is on the trusted list. Remove it from the allowlist first if you really mean it." ;;
            esac
            CS_GUARD_CODE="$code"; return 1
        fi
    done
    return 0
}

# _cs_decision_rows [origin] — the active decisions as normalised rows (cached a few seconds); community entries only on request
_cs_decision_rows() {
    local origin="${1:-}" raw asof key="decisions"
    case "$origin" in
        CAPI|lists*|console)
            key="decisions_${origin//[^A-Za-z0-9]/_}"
            raw=$(_cs_json "$key" 30 decisions list -a --origin "$origin" --limit 1000) || return 1 ;;
        *) raw=$(_cs_json decisions 6 decisions list --limit 2000) || return 1 ;;
    esac
    asof=$(( $(date +%s) - $(_cs_cache_age "$key") ))
    jq -c --argjson asof "$asof" "$_CS_JQ_DEFS"' decision_rows($asof)' <<< "$raw"
}

# the jq program of the ban list: filters, facets, sort and page
_CS_JQ_DECISION_LIST='
def facet(f): group_by(f) | map({value: (.[0] | f), count: length}) | sort_by(-.count);
. as $all
| ($q | ascii_downcase) as $ql
| [ .[] | select(
      ($scope == "" or (.scope | ascii_downcase) == $scope)
      and ($origin == "" or .origin == $origin or (.origin | startswith($origin + ":")))
      and ($type == "" or .type == $type)
      and ($country == "" or (if $country == "UNKNOWN" then .country == "" else .country == $country end))
      and ($scenario == "" or .scenario == $scenario)
      and ($sim == "any" or (if $sim == "yes" then .simulated else (.simulated | not) end))
      and ($ql == "" or ((.value + " " + .scenario + " " + .country + " " + .as_name + " " + .as_number + " " + .origin) | ascii_downcase | contains($ql)))
  ) ] as $f
| ($f | sort_by(if $sort == "expires" then .seconds_left elif $sort == "value" then .value elif $sort == "country" then .country elif $sort == "scenario" then .scenario elif $sort == "origin" then .origin else (.created_at | iso_secs) end)) as $s
| (if $dir == "desc" then ($s | reverse) else $s end) as $ordered
| { decisions: $ordered[$offset:($offset + $limit)], count: ($f | length), total: ($all | length), offset: $offset, limit: $limit, as_of: $asof,
    truncated: (($all | length) >= 2000), community: $community,
    facets: { origins: ($all | facet(.origin)), scenarios: ($all | facet(.scenario)), countries: ($all | map(select(.country != "")) | facet(.country)), types: ($all | facet(.type)),
              scopes: ($all | facet(.scope)), unknown_country: ($all | map(select(.country == "")) | length) } }'

# validate the filter parameters shared by the list and the export; sets the variables of the caller (Q SCOPE ORIGIN TYPE COUNTRY SCENARIO SIM)
_cs_decision_filters() {
    Q="${QUERY_PARAMS[q]:-}"; Q="${Q:0:100}"
    SCOPE="${QUERY_PARAMS[scope]:-}"; ORIGIN="${QUERY_PARAMS[origin]:-}"; TYPE="${QUERY_PARAMS[type]:-}"
    COUNTRY="${QUERY_PARAMS[country]:-}"; SCENARIO="${QUERY_PARAMS[scenario]:-}"; SIM="${QUERY_PARAMS[simulated]:-any}"
    [[ -z "$SCOPE" || "$SCOPE" =~ ^(ip|range|Ip|Range)$ ]] || { _api_error 400 "scope must be ip or range"; return 1; }
    [[ -z "$ORIGIN" || "$ORIGIN" =~ ^[A-Za-z0-9:_.-]{1,60}$ ]] || { _api_error 400 "Invalid origin"; return 1; }
    [[ -z "$TYPE" || "$TYPE" =~ ^[a-z]{1,20}$ ]] || { _api_error 400 "Invalid type"; return 1; }
    [[ -z "$COUNTRY" || "${COUNTRY,,}" == unknown ]] || _cs_valid_cc "$COUNTRY" || { _api_error 400 "country must be a two-letter code"; return 1; }
    [[ -z "$SCENARIO" || "$SCENARIO" =~ $_CS_SCENARIO_RE ]] || { _api_error 400 "Invalid scenario"; return 1; }
    [[ "$SIM" =~ ^(any|yes|no)$ ]] || { _api_error 400 "simulated must be any, yes or no"; return 1; }
    SCOPE="${SCOPE,,}"; COUNTRY="${COUNTRY^^}"
    return 0
}

# GET /crowdsec/decisions — Active bans, filtered (q, scope, origin, type, country, scenario, simulated, sort, dir, limit, offset), with the facets for the filter chips
handle_crowdsec_decisions() {
    _cs_target || return
    local Q SCOPE ORIGIN TYPE COUNTRY SCENARIO SIM
    _cs_decision_filters || return
    local sort="${QUERY_PARAMS[sort]:-created}" dir="${QUERY_PARAMS[dir]:-desc}" limit="${QUERY_PARAMS[limit]:-500}" offset="${QUERY_PARAMS[offset]:-0}" rows community
    [[ "$sort" =~ ^(created|expires|value|country|scenario|origin)$ ]] || { _api_error 400 "Unknown sort"; return; }
    [[ "$dir" =~ ^(asc|desc)$ ]] || { _api_error 400 "dir must be asc or desc"; return; }
    [[ "$limit" =~ ^[0-9]{1,4}$ ]] && (( limit >= 1 && limit <= 2000 )) || { _api_error 400 "limit must be 1-2000"; return; }
    [[ "$offset" =~ ^[0-9]{1,6}$ ]] || { _api_error 400 "Invalid offset"; return; }
    rows=$(_cs_decision_rows "$ORIGIN") || { _api_error 502 "CrowdSec did not answer: $(_cs_errline)"; return; }
    community=$(_cs_community_count); [[ "$community" =~ ^[0-9]+$ ]] || community=0
    _api_success "$(jq -c --arg q "$Q" --arg scope "$SCOPE" --arg origin "$ORIGIN" --arg type "$TYPE" --arg country "$COUNTRY" --arg scenario "$SCENARIO" --arg sim "$SIM" \
        --arg sort "$sort" --arg dir "$dir" --argjson limit "$limit" --argjson offset "$offset" --argjson asof "$(date +%s)" --argjson community "$community" \
        "$_CS_JQ_DEFS$_CS_JQ_DECISION_LIST" <<< "$rows")"
}

# the ban length the form starts with (Settings can change it); 4 h until then
_cs_manual_default_duration() {
    local d=""
    [[ -f "$CROWDSEC_STATE_DIR/settings.json" ]] && d=$(jq -r '.manual_duration // ""' "$CROWDSEC_STATE_DIR/settings.json" 2>/dev/null)
    d=$(_cs_norm_duration "$d") || d=4h
    printf '%s' "$d"
}

# "N decision(s) deleted" in cscli's messages
_cs_deleted_count() {
    local n
    n=$(printf '%s\n' "$1" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) decision(s) deleted.*/\1/p' | tail -n 1)
    printf '%s' "${n:-0}"
}

# _cs_unban_value VALUE — remove the active decisions for exactly this address or network. CS_DELETED holds the count. Return 2: not a valid target.
# cscli's `delete --ip X` also removes a wider network that contains X, which would silently lift bans nobody asked about: the decisions are found by
# value and removed by id. `decisions list` shows only the longest of several decisions on one address, so the look-and-delete goes round until none is left.
CS_DELETED=0
_cs_unban_value() {
    local tgt scope val out raw ids id rc=0 n=0 round filter
    tgt=$(_cs_norm_target "$1") || return 2
    scope="${tgt%%$'\t'*}"; val="${tgt#*$'\t'}"
    CS_DELETED=0
    if [[ "$scope" == Range ]]; then filter=(--range "$val"); else filter=(--ip "$val"); fi
    for round in 1 2 3 4 5 6; do
        _cs_run raw decisions list "${filter[@]}" --limit 0 -o json || { (( round == 1 )) && return 1; break; }
        ids=$(printf '%s\n' "$raw" | jq -r --arg v "${val,,}" --arg s "${scope,,}" '(. // [])[] | .decisions[]? | select((.value | ascii_downcase) == $v and (.scope | ascii_downcase) == $s and ((.duration // "") | startswith("-") | not)) | .id' 2>/dev/null)
        [[ -n "$ids" ]] || break
        while IFS= read -r id; do
            [[ "$id" =~ ^[0-9]+$ ]] || continue
            _cs_run out decisions delete --id "$id" || { rc=$?; continue; }
            n=$(( n + $(_cs_deleted_count "$CS_ERR$out") ))
        done <<< "$ids"
    done
    CS_DELETED=$n
    return $rc
}

# DELETE /crowdsec/decisions/{value} — Lift the ban on one address or network (the value may be an IP or a CIDR range such as 192.0.2.0/24)
handle_crowdsec_unban() {
    local value="$1" tgt scope val
    tgt=$(_cs_norm_target "$value") || { _api_error 400 "Invalid IP address or range: ${value:0:80}"; return; }
    scope="${tgt%%$'\t'*}"; val="${tgt#*$'\t'}"
    _cs_target || return
    if ! _cs_unban_value "$val"; then _api_error 502 "cscli failed: $(_cs_errline)"; return; fi
    _cs_cache_clear
    _api_audit_log "${CLIENT_IP:-unknown}" "CROWDSEC_UNBAN" "${AUTH_USERNAME:-}" "$val ($CS_DELETED)"
    _api_success "$(jq -nc --arg v "$val" --arg s "$scope" --argjson n "$CS_DELETED" \
        '{success: true, ip: $v, value: $v, scope: $s, deleted: $n, message: (if $n > 0 then "Lifted the ban on " + $v else "No active ban for " + $v end)}')"
}

# POST /crowdsec/decisions/delete — Lift several bans at once: {ids: [decision ids], values: [addresses or networks]} (at most 200)
handle_crowdsec_decisions_delete() {
    _api_check_admin || { _api_error 403 "Admin access required"; return; }
    local body="$1" item n=0 deleted=0 out rc
    [[ "$body" == \{* ]] && jq -e . >/dev/null 2>&1 <<< "$body" || { _api_error 400 "Send a JSON body: {\"ids\": [1, 2], \"values\": [\"203.0.113.7\"]}"; return; }
    jq -e '((.ids // []) | type == "array") and ((.values // []) | type == "array")' >/dev/null 2>&1 <<< "$body" || { _api_error 400 "ids and values must be lists"; return; }
    n=$(jq '((.ids // []) | length) + ((.values // []) | length)' <<< "$body")
    (( n >= 1 )) || { _api_error 400 "Nothing to delete: send ids or values"; return; }
    (( n <= 200 )) || { _api_error 400 "At most 200 bans per request"; return; }
    _cs_target || return
    local -a results=()
    while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        if [[ ! "$item" =~ ^[0-9]{1,12}$ ]]; then results+=("$(jq -nc --arg i "${item:0:60}" '{id: $i, ok: false, deleted: 0, error: "not a decision id"}')"); continue; fi
        _cs_run out decisions delete --id "$item"; rc=$?
        if (( rc == 0 )); then
            item=$(( 10#$item )); results+=("$(jq -nc --argjson i "$item" --argjson n "$(_cs_deleted_count "$CS_ERR$out")" '{id: $i, ok: true, deleted: $n}')"); deleted=$(( deleted + $(_cs_deleted_count "$CS_ERR$out") ))
        else
            results+=("$(jq -nc --arg i "$item" --arg e "$(_cs_errline)" '{id: ($i | tonumber), ok: false, deleted: 0, error: $e}')")
        fi
    done < <(jq -r '(.ids // [])[] | tostring' <<< "$body")
    while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        _cs_unban_value "$item"; rc=$?
        if (( rc == 0 )); then
            results+=("$(jq -nc --arg v "$item" --argjson n "$CS_DELETED" '{value: $v, ok: true, deleted: $n}')"); deleted=$(( deleted + CS_DELETED ))
        else
            results+=("$(jq -nc --arg v "${item:0:80}" --arg e "$( (( rc == 2 )) && echo 'not an IP address or range' || _cs_errline )" '{value: $v, ok: false, deleted: 0, error: $e}')")
        fi
    done < <(jq -r '(.values // [])[] | tostring' <<< "$body")
    _cs_cache_clear
    _api_audit_log "${CLIENT_IP:-unknown}" "CROWDSEC_UNBAN" "${AUTH_USERNAME:-}" "bulk: $deleted of $n"
    _api_success "$(printf '%s\n' "${results[@]}" | jq -sc --argjson n "$n" --argjson d "$deleted" '{success: (map(select(.ok | not)) | length == 0), requested: $n, deleted: $d, failed: (map(select(.ok | not)) | length), results: .}')"
}

# _cs_existing_seconds VALUE SCOPE — seconds left on an active ban of exactly this value (0 when none)
_cs_existing_seconds() {
    local out flag=--ip
    [[ "$2" == Range ]] && flag=--range
    _cs_run out decisions list "$flag" "$1" -o json || { printf '0'; return; }
    jq -r --arg v "$1" "$_CS_JQ_DEFS"' [ (. // [])[] | (.decisions // [])[] | select(.value == $v) | (.duration | dur_secs) ] | max // 0 | floor' <<< "$out" 2>/dev/null || printf '0'
}

# POST /crowdsec/decisions — Ban an address or a network: {value, duration (90m, 4h, 7d …) or permanent: true, reason}; refuses your own address, this server, the home address, private and far too wide networks
handle_crowdsec_decision_add() {
    _api_check_admin || { _api_error 403 "Admin access required"; return; }
    local body="$1" value dur perm reason tgt scope val user
    [[ "$body" == \{* ]] && jq -e . >/dev/null 2>&1 <<< "$body" || { _api_error 400 "Send a JSON body: {\"value\": \"203.0.113.7\", \"duration\": \"24h\", \"reason\": \"scanner\"}"; return; }
    value=$(jq -r '(.value // .ip // .range // "") | tostring' <<< "$body")
    dur=$(jq -r '(.duration // "") | tostring' <<< "$body")
    perm=$(jq -r 'if .permanent == true then "yes" else "no" end' <<< "$body")
    reason=$(_cs_clean_reason "$(jq -r '(.reason // "") | tostring' <<< "$body")")
    tgt=$(_cs_norm_target "$value") || { _api_error 400 "Not an IP address or network: ${value:0:80}"; return; }
    scope="${tgt%%$'\t'*}"; val="${tgt#*$'\t'}"
    if [[ "$perm" == yes ]]; then dur="$CROWDSEC_PERMANENT_DURATION"
    elif [[ -z "$dur" ]]; then dur=$(_cs_manual_default_duration)
    else dur=$(_cs_norm_duration "$dur") || { _api_error 400 "Invalid duration: use 30m, 4h, 7d or 2w (1 minute to 10 years)"; return; }
    fi
    if ! _cs_ban_guard "$val"; then
        _api_response 400 "$(jq -nc --arg m "$CS_GUARD_MSG" --arg c "$CS_GUARD_CODE" '{error: true, code: 400, message: $m, reason: $c}')"
        return
    fi
    _cs_target || return
    user=$(printf '%s' "${AUTH_USERNAME:-admin}" | tr -cd 'A-Za-z0-9._-')
    [[ -n "$reason" ]] || reason="Banned from DCS by ${user:-admin}"
    # a ban that already exists is replaced only by a longer one (two rows for one address would mislead)
    local have want replaced=0 out
    have=$(_cs_existing_seconds "$val" "$scope"); want=$(_cs_duration_seconds "$dur")
    if (( have > 0 )); then
        if (( have >= want )); then
            _api_response 409 "$(jq -nc --arg v "$val" --argjson h "$have" --arg human "$(_cs_human_secs "$have")" '{error: true, code: 409, message: ($v + " is already banned for another " + $human + ". Lift that ban first if you want a shorter one."), reason: "already_banned", seconds_left: $h}')"
            return
        fi
        _cs_unban_value "$val" && replaced=$CS_DELETED
    fi
    local -a args=(decisions add)
    if [[ "$scope" == Range ]]; then args+=(--range "$val"); else args+=(--ip "$val"); fi
    args+=(--duration "$dur" "--reason=$reason" --type ban)
    if ! _cs_run out "${args[@]}"; then
        local e; e=$(_cs_errline)
        if [[ "$e" == *allowlisted* ]]; then
            # cscli's advice is a command-line flag; on the page the way out is the allowlist
            if [[ "$e" =~ ^(.+)\ is\ allowlisted\ by\ item\ (.+)\ from\ ([^\ ,]+) ]]; then
                e="${BASH_REMATCH[1]} is on the allowlist (${BASH_REMATCH[2]}, list ${BASH_REMATCH[3]}), so it is never banned. Take it off the allowlist first if you really want to ban it."
            fi
            _api_response 409 "$(jq -nc --arg m "$e" '{error: true, code: 409, message: $m, reason: "allowlisted"}')"; return
        fi
        _api_error 502 "CrowdSec refused the ban: $e"; return
    fi
    _cs_cache_clear
    _api_audit_log "${CLIENT_IP:-unknown}" "CROWDSEC_BAN" "${AUTH_USERNAME:-}" "$val for $dur: $reason"
    _api_success "$(jq -nc --arg v "$val" --arg s "$scope" --arg d "$dur" --arg r "$reason" --argjson p "$([[ "$perm" == yes ]] && echo true || echo false)" --argjson rep "$replaced" \
        --argjson secs "$(_cs_duration_seconds "$dur")" --argjson now "$(date +%s)" \
        '{success: true, value: $v, scope: $s, duration: $d, reason: $r, permanent: $p, replaced: $rep, expires_at: (($now + $secs) | todate),
          message: (if $p then $v + " is banned permanently (ten years)" else $v + " is banned for " + $d end)}')"
}

# -----------------------------------------------------------------------------
# Export and import of bans (CSV / JSON / one address per line)
# -----------------------------------------------------------------------------

# GET /crowdsec/decisions/export — The active bans as CSV or JSON (format=csv|json, the list's filters apply): {format, filename, count, content}
handle_crowdsec_decisions_export() {
    _cs_target || return
    local Q SCOPE ORIGIN TYPE COUNTRY SCENARIO SIM fmt="${QUERY_PARAMS[format]:-csv}" rows content n
    _cs_decision_filters || return
    [[ "$fmt" =~ ^(csv|json)$ ]] || { _api_error 400 "format must be csv or json"; return; }
    rows=$(_cs_decision_rows "$ORIGIN") || { _api_error 502 "CrowdSec did not answer: $(_cs_errline)"; return; }
    rows=$(jq -c --arg q "$Q" --arg scope "$SCOPE" --arg origin "$ORIGIN" --arg type "$TYPE" --arg country "$COUNTRY" --arg scenario "$SCENARIO" --arg sim "$SIM" "$_CS_JQ_DEFS"'
        ($q | ascii_downcase) as $ql
        | [ .[] | select(
              ($scope == "" or (.scope | ascii_downcase) == $scope) and ($origin == "" or .origin == $origin or (.origin | startswith($origin + ":"))) and ($type == "" or .type == $type)
              and ($country == "" or (if $country == "UNKNOWN" then .country == "" else .country == $country end)) and ($scenario == "" or .scenario == $scenario)
              and ($sim == "any" or (if $sim == "yes" then .simulated else (.simulated | not) end))
              and ($ql == "" or ((.value + " " + .scenario + " " + .country + " " + .as_name + " " + .as_number + " " + .origin) | ascii_downcase | contains($ql))) ) ]' <<< "$rows")
    n=$(jq 'length' <<< "$rows")
    if [[ "$fmt" == json ]]; then
        content=$(jq '[ .[] | {value, scope, type, duration, reason: .scenario, origin, country, as_number, as_name, expires_at} ]' <<< "$rows")
    else
        # a cell that starts with = + - @ (or a tab or CR) would be run as a formula by a spreadsheet: an apostrophe keeps it text
        content=$(jq -r 'def cell: if type == "string" and test("^[=+@\\t\\r-]") then "\u0027" + . else . end;
            (["value","scope","type","duration","reason","origin","country","as","expires_at"] | @csv),
            (.[] | [.value, .scope, .type, .duration, .scenario, .origin, .country, (if .as_number != "" then "AS" + .as_number + " " + .as_name else "" end), .expires_at] | map(cell) | @csv)' <<< "$rows")
    fi
    # (the content can be far larger than one command-line argument may be: it goes in on stdin)
    local out
    out=$(printf '%s' "$content" | jq -Rsc --arg f "$fmt" --arg name "crowdsec-bans-$(date -u +%Y-%m-%d).$fmt" --argjson n "$n" --argjson now "$(date +%s)" \
        '{format: $f, filename: $name, count: $n, content: ., generated_at: $now}' 2>/dev/null)
    [[ "$out" == \{* ]] || { _api_error 500 "Could not build the export"; return; }
    _api_success "$out"
}

# CSV (with a header line) → one "\037"-joined line per row, quotes and doubled quotes honoured
_cs_csv_rows() {
    awk '
    {
        line = $0; sub(/\r$/, "", line)
        if (line ~ /^[[:space:]]*$/) next
        n = 0; field = ""; inq = 0; out = ""; len = length(line)
        for (i = 1; i <= len; i++) {
            c = substr(line, i, 1)
            if (inq) {
                if (c == "\"") { if (substr(line, i + 1, 1) == "\"") { field = field "\""; i++ } else inq = 0 }
                else field = field c
            } else if (c == "\"") inq = 1
            else if (c == ",") { out = out (n++ ? "\037" : "") field; field = "" }
            else field = field c
        }
        out = out (n++ ? "\037" : "") field
        print out
    }'
}

# _cs_import_parse FORMAT TEXT — prints a JSON array of raw entries {value, duration, reason, type} (nothing is trusted yet)
_cs_import_parse() {
    local fmt="$1" text="$2" first
    if [[ "$fmt" == auto ]]; then
        first=$(printf '%s' "$text" | sed -n '/[^[:space:]]/{p;q}')
        case "$first" in
            \[*|\{*) fmt=json ;;
            *,*) if printf '%s' "$first" | grep -qiE '(^|,)"?(value|ip|range|address)"?(,|$)'; then fmt=csv; else fmt=values; fi ;;
            *) fmt=values ;;
        esac
    fi
    case "$fmt" in
        json)
            jq -c 'if type == "array" then . elif type == "object" then (.decisions // .bans // .items // []) else [] end
                   | map(select(type == "object") | {value: ((.value // .ip // .range // .address // "") | tostring), duration: ((.duration // "") | tostring), reason: ((.reason // .scenario // "") | tostring), type: ((.type // "ban") | tostring)})' <<< "$text" 2>/dev/null ;;
        csv)
            printf '%s\n' "$text" | _cs_csv_rows | jq -nRc '[inputs | split("\u001f")] as $r | if ($r | length) < 2 then [] else
                ($r[0] | map(ascii_downcase | gsub("^\\s+|\\s+$"; ""))) as $h
                | [ $r[1:][] | . as $row | reduce range(0; $h | length) as $i ({}; .[$h[$i]] = ($row[$i] // "")) ]
                | map({value: (.value // .ip // .range // .address // ""), duration: (.duration // ""), reason: (.reason // .scenario // ""), type: (.type // "ban")}) end' 2>/dev/null ;;
        values)
            printf '%s\n' "$text" | sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]].*$//' | grep -v '^$' \
                | jq -nRc '[inputs | {value: ., duration: "", reason: "", type: "ban"}]' 2>/dev/null ;;
        *) return 1 ;;
    esac
}

# POST /crowdsec/decisions/import — Ban many addresses at once: {format: auto|csv|json|values, content, duration?, reason?, permanent?}; every entry is checked like a single ban, refused ones are listed
handle_crowdsec_decisions_import() {
    _api_check_admin || { _api_error 403 "Admin access required"; return; }
    local body="$1" fmt content defdur defreason perm entries n
    [[ "$body" == \{* ]] && jq -e . >/dev/null 2>&1 <<< "$body" || { _api_error 400 "Send a JSON body: {\"format\": \"auto\", \"content\": \"203.0.113.7\\n198.51.100.0/24\"}"; return; }
    fmt=$(jq -r '(.format // "auto") | tostring' <<< "$body"); content=$(jq -r '(.content // "") | tostring' <<< "$body")
    content="${content#$'\xef\xbb\xbf'}"     # a byte order mark: the first line of a file saved by a Windows program would otherwise not be an address (or a header)
    [[ "$fmt" =~ ^(auto|csv|json|values)$ ]] || { _api_error 400 "format must be auto, csv, json or values"; return; }
    [[ -n "${content//[[:space:]]/}" ]] || { _api_error 400 "content is empty"; return; }
    (( ${#content} <= 524288 )) || { _api_error 413 "Too much to import at once (512 KB at most)"; return; }
    perm=$(jq -r 'if .permanent == true then "yes" else "no" end' <<< "$body")
    defdur=$(jq -r '(.duration // "") | tostring' <<< "$body")
    if [[ "$perm" == yes ]]; then defdur="$CROWDSEC_PERMANENT_DURATION"
    elif [[ -z "$defdur" ]]; then defdur=$(_cs_manual_default_duration)
    else defdur=$(_cs_norm_duration "$defdur") || { _api_error 400 "Invalid default duration: use 30m, 4h, 7d or 2w"; return; }
    fi
    defreason=$(_cs_clean_reason "$(jq -r '(.reason // "") | tostring' <<< "$body")"); [[ -n "$defreason" ]] || defreason="Imported from DCS"
    entries=$(_cs_import_parse "$fmt" "$content") || entries=""
    [[ "$entries" == \[* ]] || { _api_error 400 "Could not read the content as $fmt"; return; }
    n=$(jq 'length' <<< "$entries")
    (( n >= 1 )) || { _api_error 400 "No addresses found in the content"; return; }
    (( n <= 2000 )) || { _api_error 400 "At most 2000 entries per import (this has $n)"; return; }
    _cs_target || return
    # thousands of entries are checked here: everything below is plain shell without a process per entry (an address lookup, the guard on hex digits), the JSON is built in two passes at the end
    local -A active=() seen=() durs=()
    local v
    while IFS= read -r v; do [[ -z "$v" ]] || active[$v]=1; done < <(_cs_decision_rows | jq -r '.[] | select(.simulated | not) | .value' 2>/dev/null)
    local -a good=() skipped=()
    local value dur reason type line=0 tgt scope val norm US=$'\x1f'
    while IFS=$'\x1f' read -r value dur reason type; do
        line=$(( line + 1 ))
        if _cs_is_v4 "$value"; then
            scope=Ip; val="$value"
        else
            tgt=$(_cs_norm_target "$value") || { skipped+=("$line$US${value:0:80}${US}invalid${US}not an IP address or network"); continue; }
            scope="${tgt%%$'\t'*}"; val="${tgt#*$'\t'}"
        fi
        if [[ -n "${seen[$val]:-}" ]]; then skipped+=("$line$US$val${US}duplicate${US}listed twice"); continue; fi
        seen[$val]=1
        if [[ -n "$type" && "${type,,}" != ban ]]; then skipped+=("$line$US$val${US}type${US}only bans can be imported, not ${type:0:20}"); continue; fi
        if [[ -n "$dur" ]]; then
            norm="-"
            if [[ "$dur" =~ ^[0-9smhdwSMHDW\ ]{1,24}$ ]]; then      # (the same length written twice is worked out once; anything with other characters cannot be a duration)
                if [[ -z "${durs[$dur]:-}" ]]; then durs[$dur]=$(_cs_norm_duration "$dur") || durs[$dur]="-"; fi
                norm="${durs[$dur]}"
            fi
            if [[ "$norm" == "-" ]]; then skipped+=("$line$US$val${US}duration${US}invalid duration ${dur:0:30}"); continue; fi
        else norm="$defdur"; fi
        if [[ -n "${active[$val]:-}" ]]; then skipped+=("$line$US$val${US}already_banned${US}already banned"); continue; fi
        if ! _cs_ban_guard "$val"; then skipped+=("$line$US$val$US$CS_GUARD_CODE$US$CS_GUARD_MSG"); continue; fi
        if [[ -n "$reason" ]]; then reason=$(_cs_clean_reason "$reason"); fi
        [[ -n "$reason" ]] || reason="$defreason"
        good+=("$val$US$scope$US$norm$US$reason")
    done < <(jq -r '.[] | [.value, .duration, .reason, .type] | join("\u001f")' <<< "$entries")
    local imported=0 chunk out i=0 allowlisted=0 failed=""
    while (( i < ${#good[@]} )); do
        chunk=$(printf '%s\n' "${good[@]:i:400}" | jq -Rsc 'split("\n") | map(select(length > 0) | split("\u001f") | {value: .[0], scope: (.[1] | ascii_downcase), duration: .[2], reason: .[3], type: "ban"})')
        if _cs_pipe out "$chunk" decisions import -i - --format json; then
            imported=$(( imported + $(printf '%s\n' "$out" | sed -n 's/.*Imported \([0-9][0-9]*\) decisions.*/\1/p' | tail -n 1 | grep -E '^[0-9]+$' || echo 0) ))
            allowlisted=$(( allowlisted + $(printf '%s\n' "$out" | grep -c 'is allowlisted by') ))
        else
            failed=$(_cs_errline)
            break
        fi
        i=$(( i + 400 ))
    done
    _cs_cache_clear
    _api_audit_log "${CLIENT_IP:-unknown}" "CROWDSEC_IMPORT" "${AUTH_USERNAME:-}" "$imported of $n imported (${#skipped[@]} skipped)"
    if [[ -n "$failed" && $imported -eq 0 ]]; then _api_error 502 "CrowdSec refused the import: $failed"; return; fi
    _api_success "$( ( [[ ${#skipped[@]} -gt 0 ]] && printf '%s\n' "${skipped[@]}" || true ) | jq -Rsc --argjson n "$n" --argjson im "$imported" --argjson al "$allowlisted" --arg fmt "$fmt" --arg f "$failed" \
        '(split("\n") | map(select(length > 0) | split("\u001f") | {line: (.[0] | tonumber), value: .[1], reason: .[2], message: .[3]})) as $sk
        | {success: ($f == ""), format: $fmt, total: $n, imported: $im, skipped: ($sk | length), allowlisted: $al, skipped_entries: ($sk[0:200]), error: (if $f == "" then null else $f end)}')"
}

# =============================================================================
# Alerts, and the numbers behind the charts
# =============================================================================

# active community-blocklist decisions (origin CAPI or lists:*), from the metrics; 0 when unknown
_cs_community_count() {
    local m
    m=$(_cs_json metrics 30 metrics 2>/dev/null) || { printf '0'; return; }
    jq -r '[ (.decisions // {}) | to_entries[] | .value | to_entries[] | select(.key == "CAPI" or (.key | startswith("lists"))) | .value | to_entries[] | .value ] | add // 0' <<< "$m" 2>/dev/null || printf '0'
}

# how long CrowdSec keeps alerts (db_config.flush.max_age of its config), in days; 7 when unknown
_cs_retention_days() {
    local v
    v=$(_cs_cache_get retention 600) || {
        v=$(timeout 8 docker exec "$CS_NAME" cat /etc/crowdsec/config.yaml 2>/dev/null </dev/null | awk '/^[[:space:]]*max_age:/ { print $2; exit }')
        [[ -n "$v" ]] && printf '%s' "$v" | _cs_cache_put retention
    }
    if [[ "$v" =~ ^([0-9]+)d$ ]]; then printf '%d' "${BASH_REMATCH[1]}"
    elif [[ "$v" =~ ^([0-9]+)h$ ]]; then printf '%d' $(( (BASH_REMATCH[1] + 23) / 24 ))
    else printf '7'; fi
}

# _cs_alerts_window WINDOW — the alerts of the last 1h/6h/24h/7d/30d, raw (cached)
_cs_alerts_raw() {
    local w="$1" ttl=15
    [[ "$w" == 24h || "$w" == 1h || "$w" == 6h ]] || ttl=60
    [[ "$w" == 24h ]] && { _cs_json alerts_24h 15 alerts list --since 24h --limit 0; return; }
    _cs_json "alerts_$w" "$ttl" alerts list --since "$w" --limit 0
}

# GET /crowdsec/alerts — Recent detections (window 1h/6h/24h/7d/30d, q, scenario, country, ip, simulated, limit, offset) with facets; each row says whether its source is banned now
handle_crowdsec_alerts() {
    _cs_target || return
    local w="${QUERY_PARAMS[window]:-24h}" q="${QUERY_PARAMS[q]:-}" scenario="${QUERY_PARAMS[scenario]:-}" country="${QUERY_PARAMS[country]:-}" ip="${QUERY_PARAMS[ip]:-}"
    local sim="${QUERY_PARAMS[simulated]:-any}" limit="${QUERY_PARAMS[limit]:-100}" offset="${QUERY_PARAMS[offset]:-0}" raw rows
    q="${q:0:100}"
    [[ "$w" =~ ^(1h|6h|24h|7d|30d)$ ]] || { _api_error 400 "window must be 1h, 6h, 24h, 7d or 30d"; return; }
    [[ -z "$scenario" || "$scenario" =~ $_CS_SCENARIO_RE ]] || { _api_error 400 "Invalid scenario"; return; }
    [[ -z "$country" || "${country,,}" == unknown ]] || _cs_valid_cc "$country" || { _api_error 400 "country must be a two-letter code"; return; }
    [[ -z "$ip" ]] || _cs_norm_target "$ip" >/dev/null || { _api_error 400 "ip must be an address or network"; return; }
    [[ "$sim" =~ ^(any|yes|no)$ ]] || { _api_error 400 "simulated must be any, yes or no"; return; }
    [[ "$limit" =~ ^[0-9]{1,4}$ ]] && (( limit >= 1 && limit <= 1000 )) || { _api_error 400 "limit must be 1-1000"; return; }
    [[ "$offset" =~ ^[0-9]{1,6}$ ]] || { _api_error 400 "Invalid offset"; return; }
    raw=$(_cs_alerts_raw "$w") || { _api_error 502 "CrowdSec did not answer: $(_cs_errline)"; return; }
    rows=$(_cs_decision_rows 2>/dev/null | jq -c '[.[] | select(.simulated | not) | .value]' 2>/dev/null); [[ "$rows" == \[* ]] || rows='[]'
    _api_success "$(jq -c --arg q "$q" --arg scenario "$scenario" --arg country "${country^^}" --arg ip "$ip" --arg sim "$sim" --arg w "$w" --argjson limit "$limit" --argjson offset "$offset" \
        --slurpfile banned_f <(printf '%s' "$rows") --argjson asof "$(date +%s)" --argjson ret "$(_cs_retention_days)" "$_CS_JQ_DEFS$_CS_JQ_LABELS"'
        def facet(f): group_by(f) | map({value: (.[0] | f), count: length}) | sort_by(-.count);
        (. // []) as $all
        | ($banned_f[0] | map({key: ., value: true}) | from_entries) as $banned
        | ($q | ascii_downcase) as $ql
        # each facet is counted with every filter except its own, so choosing a scenario does not empty the list of scenarios
        | def ok_scenario: ($scenario == "" or .scenario == $scenario);
        def ok_country: ($country == "" or (if $country == "UNKNOWN" then .source.country == "" else .source.country == $country end));
        def ok_rest: ($ip == "" or .source.value == $ip)
                and ($sim == "any" or (if $sim == "yes" then .simulated else (.simulated | not) end))
                and ($ql == "" or ((.source.value + " " + .scenario + " " + .label + " " + .source.country + " " + .source.as_name + " " + .message) | ascii_downcase | contains($ql)));
        [ $all[] | . as $raw | alert_row | . + {kind: ($raw.kind // ""), label: ($raw | alert_label), family: ($raw | alert_family), banned: ($banned[.source.value] // false)} ] as $rows
        | ($rows | map(select(ok_rest and ok_scenario and ok_country))) as $f
        | ($f | sort_by(.id) | reverse) as $ordered
        | ($rows | map(select(ok_rest and ok_scenario))) as $for_countries
        | { alerts: ($ordered[$offset:($offset + $limit)] | map(del(.meta))), count: ($f | length), total: ($all | length), window: $w, offset: $offset, limit: $limit, as_of: $asof, retention_days: $ret,
            facets: { scenarios: ($rows | map(select(ok_rest and ok_country)) | group_by(.scenario) | map({value: .[0].scenario, label: .[0].label, count: length}) | sort_by(-.count)),
                      countries: ($for_countries | map(select(.source.country != "")) | facet(.source.country)),
                      unknown_country: ($for_countries | map(select(.source.country == "")) | length) } }' <<< "$raw")"
}

# GET /crowdsec/alerts/{id} — One alert with the requests that raised it (path, status, user agent, target …)
handle_crowdsec_alert_detail() {
    local id="$1" out
    [[ "$id" =~ ^[0-9]{1,12}$ ]] || { _api_error 400 "Invalid alert id"; return; }
    _cs_target || return
    if ! _cs_run out alerts inspect "$id" -d -o json; then
        if [[ "$(_cs_errline)" == *"not found"* || "$(_cs_errline)" == *"unable to get alert"* ]]; then _api_error 404 "No alert $id (CrowdSec keeps alerts for a limited time)"; else _api_error 502 "cscli failed: $(_cs_errline)"; fi
        return
    fi
    jq -e 'type == "object"' >/dev/null 2>&1 <<< "$out" || { _api_error 502 "CrowdSec answered something unexpected"; return; }
    _api_success "$(jq -c "$_CS_JQ_DEFS$_CS_JQ_LABELS"'
        def metaobj: (reduce ((. // [])[]) as $m ({}; .[$m.key] = $m.value));
        def unjson: if type == "string" and (startswith("[") or startswith("{")) then (try fromjson catch .) else . end;
        { alert: (. as $raw | alert_row | . + {label: ($raw | alert_label), family: ($raw | alert_family), uuid: ($uuid // "")}
                  | .context = (($ctx | metaobj) | with_entries(.value |= unjson))
                  | .events = $events) }' --argjson uuid "$(jq '.uuid // ""' <<< "$out")" --argjson ctx "$(jq -c '.meta // []' <<< "$out")" \
        --argjson events "$(jq -c '[ (.events // [])[] | {timestamp: .timestamp, fields: ((.meta // []) | reduce .[] as $m ({}; .[$m.key] = $m.value))} ] | .[0:200]' <<< "$out")" <<< "$out")"
}

# GET /crowdsec/metrics — What has been happening: alerts over time, top scenarios, top countries, top sources and networks, the map points, log-reading counters (window=24h|7d|30d)
handle_crowdsec_metrics() {
    _cs_target || return
    local w="${QUERY_PARAMS[window]:-24h}" raw rows metrics ret bucket span
    [[ "$w" =~ ^(24h|7d|30d)$ ]] || { _api_error 400 "window must be 24h, 7d or 30d"; return; }
    case "$w" in 24h) bucket=3600; span=86400 ;; 7d) bucket=21600; span=604800 ;; *) bucket=86400; span=2592000 ;; esac
    raw=$(_cs_alerts_raw "$w") || { _api_error 502 "CrowdSec did not answer: $(_cs_errline)"; return; }
    rows=$(_cs_decision_rows 2>/dev/null); [[ "$rows" == \[* ]] || rows='[]'
    metrics=$(_cs_json metrics 10 metrics 2>/dev/null); [[ "$metrics" == \{* ]] || metrics='{}'
    ret=$(_cs_retention_days)
    _api_success "$(jq -nc --slurpfile al <(printf '%s' "$raw") --slurpfile dec <(printf '%s' "$rows") --slurpfile me <(printf '%s' "$metrics") --arg w "$w" --argjson bucket "$bucket" --argjson span "$span" \
        --argjson now "$(date +%s)" --argjson ret "$ret" "$_CS_JQ_DEFS$_CS_JQ_LABELS"'
        def top($n): sort_by(-(.alerts // 0), -(.events // 0)) | .[0:$n];
        ($al[0] // []) as $alerts | ($dec[0] // []) as $bans | ($me[0] // {}) as $m
        | ($now - $span) as $since
        # only engine detections have a source; manual and imported bans carry none and stay out of the geography
        | [ $alerts[] | select((.kind // "") != "cscli") | {t: (.created_at | iso_secs), scenario: (.scenario // ""), events: (.events_count // 0), value: (.source.value // ""), cn: (.source.cn | cc), as_number: ((.source.as_number // "") | tostring),
              as_name: (.source.as_name // ""), lat: (.source.latitude // null), lon: (.source.longitude // null), simulated: (.simulated // false)} ] as $a
        | ($a | length) as $n
        | { window: $w, since: $since, retention_days: $ret,
            window_supported: ((($w | if . == "24h" then 1 elif . == "7d" then 7 else 30 end)) <= $ret),
            totals: { alerts: $n, events: ($a | map(.events) | add // 0), sources: ($a | map(.value) | unique | length), countries: ($a | map(.cn) | map(select(. != "")) | unique | length),
                      scenarios: ($a | map(.scenario) | unique | length), banned_now: ($bans | map(select(.simulated | not)) | length), manual: (($alerts | length) - $n) },
            bucket_seconds: $bucket,
            timeline: ( ((($since / $bucket) | floor) * $bucket) as $start | (($now / $bucket) | floor * $bucket) as $end
                        | [ range($start; $end + 1; $bucket) as $t | {t: $t, alerts: ([$a[] | select(.t >= $t and .t < $t + $bucket)] | length), events: ([$a[] | select(.t >= $t and .t < $t + $bucket) | .events] | add // 0)} ] ),
            scenarios: ($a | group_by(.scenario) | map({scenario: .[0].scenario, label: (.[0].scenario | scen_label), family: (.[0].scenario | scen_family), alerts: length, events: (map(.events) | add // 0), sources: (map(.value) | unique | length)}) | top(10)),
            countries: ($a | map(select(.cn != "")) | group_by(.cn) | map({code: .[0].cn, alerts: length, events: (map(.events) | add // 0), sources: (map(.value) | unique | length)}) | top(15)),
            unknown_country: ($a | map(select(.cn == "")) | length),
            sources: ($a | map(select(.value != "")) | group_by(.value) | map({value: .[0].value, country: .[0].cn, as_number: .[0].as_number, as_name: .[0].as_name, alerts: length, events: (map(.events) | add // 0),
                        last_seen: (map(.t) | max), scenarios: (map(.scenario) | unique | map(scen_label) | unique), banned: ((.[0].value as $v | $bans | map(select(.value == $v and (.simulated | not))) | length) > 0)}) | top(10)),
            networks: ($a | map(select(.as_number != "")) | group_by(.as_number) | map({as_number: .[0].as_number, as_name: .[0].as_name, alerts: length, sources: (map(.value) | unique | length)}) | top(8)),
            bans_by_country: ($bans | map(select((.simulated | not) and .country != "")) | group_by(.country) | map({code: .[0].country, count: length}) | sort_by(-.count) | .[0:15]),
            map_points: ($a | map(select(.lat != null and .lon != null)) | group_by([(.lat * 2 | round), (.lon * 2 | round)]) | map({lat: (map(.lat) | add / length), lon: (map(.lon) | add / length), country: .[0].cn, alerts: length, sources: (map(.value) | unique | length)}) | sort_by(-.alerts) | .[0:150]),
            acquisition: [ ($m.acquisition // {}) | to_entries[] | {source: .key, reads: (.value.reads // 0), parsed: (.value.parsed // 0), unparsed: (.value.unparsed // 0), poured: (.value.pour // 0)} ],
            parsers: [ ($m.parsers // {}) | to_entries[] | select(.key | startswith("child-") | not) | {name: .key, hits: (.value.hits // 0), parsed: (.value.parsed // 0), unparsed: (.value.unparsed // 0)} ] | sort_by(-.hits) | .[0:10],
            decisions_by_origin: ( [ ($m.decisions // {}) | to_entries[] | .value | to_entries[] | {origin: .key, count: ([.value | to_entries[] | .value] | add // 0)} ] | group_by(.origin) | map({origin: .[0].origin, count: (map(.count) | add)}) | sort_by(-.count) ),
            lapi_requests: ( [ ($m.lapi // {}) | to_entries[] | .value | to_entries[] | .value ] | add // 0 ),
            as_of: $now }')"
}

# =============================================================================
# Allowlist: CrowdSec's own (1.6.8+, applies at once) or the DCS trusted list (a parser whitelist, reloaded)
# =============================================================================

# native | parser — does this CrowdSec have `cscli allowlists`?
_cs_allowlist_mechanism() {
    local out
    if out=$(_cs_json allowlists 8 allowlists list 2>/dev/null); then printf 'native'; return; fi
    _cs_run out allowlists list -o json >/dev/null 2>&1
    if grep -qi 'unknown command' <<< "$CS_ERR"; then printf 'parser'; else printf 'native'; fi
}

# the DCS trusted list, with the notes people left; prints a JSON array of {value, comment, added_at}
_cs_trusted_entries() {
    local f="$CROWDSEC_TRUSTED_FILE" j='{}'
    [[ -s "$f" ]] && j=$(jq -c . "$f" 2>/dev/null); [[ "$j" == \{* ]] || j='{}'
    jq -c '(.notes // {}) as $n | (.added // {}) as $a | [ (.ips // [])[] | {value: ., comment: ($n[.] // ""), added_at: ($a[.] // null)} ]' <<< "$j"
}

# an entry expires when its expiration is in the future; cscli writes the zero time for "never"
_CS_JQ_ALLOW='
def allow_entries($mine):
  [ (. // [])[] as $l | ($l.items // [])[]
    | { value: .value, kind: (if (.value | contains("/")) then "range" else "ip" end), comment: (.description // ""), created_at: (.created_at // ""),
        expires_at: (if (.expiration // "") == "" or ((.expiration // "") | startswith("0001")) then null else .expiration end),
        list: $l.name, source: (if $l.name == $mine then "allowlist" else "other" end), managed: false, removable: ($l.name == $mine) } ];
'

# GET /crowdsec/allowlist — Everything that is never banned: entries with comment and expiry, which are managed by DCS (the home address) and which can be removed; says which mechanism is in use
handle_crowdsec_allowlist() {
    _cs_target || return
    local mech raw='[]' native trusted state='{}' home="" envs client="${CLIENT_IP:-}"
    mech=$(_cs_allowlist_mechanism)
    if [[ "$mech" == native ]]; then raw=$(_cs_json allowlists 8 allowlists list) || { _api_error 502 "CrowdSec did not answer: $(_cs_errline)"; return; }; fi
    native=$(jq -c --arg mine "$CROWDSEC_ALLOWLIST_NAME" "$_CS_JQ_ALLOW"' allow_entries($mine)' <<< "$raw" 2>/dev/null); [[ "$native" == \[* ]] || native='[]'
    trusted=$(_cs_trusted_entries)
    [[ -f "$CROWDSEC_SYNC_STATE" ]] && state=$(jq -c . "$CROWDSEC_SYNC_STATE" 2>/dev/null); [[ "$state" == \{* ]] || state='{}'
    home=$(jq -r '.public_ip // ""' <<< "$state")
    envs=$(IFS=',' read -ra _e <<< "${CROWDSEC_TRUSTED_IPS:-}"; for x in "${_e[@]}"; do x="${x// /}"; [[ -n "$x" ]] && _crowdsec_valid_ip "$x" && echo "$x"; done | jq -R . | jq -sc .)
    local out
    out=$(jq -nc --arg mech "$mech" --argjson native "$native" --argjson trusted "$trusted" --arg home "$home" --argjson envs "$envs" --argjson state "$state" --arg client "$client" --arg mine "$CROWDSEC_ALLOWLIST_NAME" \
        --argjson lists "$(jq -c '[ (. // [])[] | {name, description: (.description // ""), items: ((.items // []) | length), created_at: (.created_at // ""), updated_at: (.updated_at // "")} ]' <<< "$raw" 2>/dev/null || echo '[]')" '
        ( [ if $home != "" then {value: $home, kind: "ip", comment: "Your home address. DCS follows it as it changes, so you can never ban yourself.", created_at: ($state.synced_at // ""), expires_at: null, list: null, source: "managed", managed: true, removable: false} else empty end ]
          + [ ($state.home_ipv6 // "") | strings | select(test("^[0-9a-f:]+/[0-9]{1,3}$")) | {value: ., kind: "range", comment: "Your home network over IPv6 (CROWDSEC_HOME_IPV6_PREFIX). DCS follows the prefix as your provider changes it.", created_at: ($state.synced_at // ""), expires_at: null, list: null, source: "managed", managed: true, removable: false} ]
          + [ $envs[] | {value: ., kind: (if contains("/") then "range" else "ip" end), comment: "Set in .env (CROWDSEC_TRUSTED_IPS)", created_at: "", expires_at: null, list: null, source: "env", managed: true, removable: false} ]
          + $native
          + [ $trusted[] | {value: .value, kind: (if (.value | contains("/")) then "range" else "ip" end), comment: .comment, created_at: (.added_at // ""), expires_at: null, list: null, source: "trusted", managed: false, removable: true} ] ) as $entries
        | { mechanism: $mech, list_name: (if $mech == "native" then $mine else null end), supports_expiry: ($mech == "native"),
            note: (if $mech == "native" then "CrowdSec allowlist \"" + $mine + "\": entries apply at once and expire on their own when you set an expiry."
                   else "This CrowdSec is older than 1.6.8 and has no allowlists. DCS keeps a parser whitelist instead and reloads CrowdSec when it changes; entries never expire." end),
            entries: $entries, lists: $lists, count: ($entries | length), client_ip: $client, home: {public_ip: $home, synced_at: ($state.synced_at // null)} }')
    _api_success "$out"
}

# the trusted list: add and remove a value (the legacy mechanism, also used when CrowdSec is old)
_cs_trust_add() {
    local v="$1" comment="$2" now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    mkdir -p "$(dirname "$CROWDSEC_TRUSTED_FILE")" 2>/dev/null
    [[ -s "$CROWDSEC_TRUSTED_FILE" ]] || echo '{"ips": []}' > "$CROWDSEC_TRUSTED_FILE"
    _api_jq_update_file "$CROWDSEC_TRUSTED_FILE" --arg ip "$v" --arg ts "$now" --arg c "$comment" \
        '.ips = ((.ips // []) + [$ip] | unique) | .updated = $ts | .notes = ((.notes // {}) + (if $c != "" then {($ip): $c} else {} end)) | .added = ((.added // {}) + {($ip): ((.added // {})[$ip] // $ts)})' >/dev/null 2>&1
    _crowdsec_whitelist_sync || return 0
}
_cs_trust_remove() {
    local v="$1"
    _api_jq_update_file "$CROWDSEC_TRUSTED_FILE" --arg ip "$v" '.ips = ((.ips // []) - [$ip]) | .notes = ((.notes // {}) | del(.[$ip])) | .added = ((.added // {}) | del(.[$ip]))' >/dev/null 2>&1
    _crowdsec_whitelist_sync || return 0
}

# lift the active bans that an allowlist entry now covers; prints the number
_cs_unban_covered() {
    local entry="$1" rows v n=0
    rows=$(_cs_decision_rows 2>/dev/null | jq -r '.[].value' 2>/dev/null)
    while IFS= read -r v; do
        [[ -n "$v" ]] || continue
        if _cs_covers "$entry" "$v"; then _cs_unban_value "$v" && n=$(( n + CS_DELETED )); fi
    done <<< "$rows"
    printf '%d' "$n"
}

# POST /crowdsec/allowlist — Never ban an address or network: {value, comment?, expires? (30m, 12h, 7d …; CrowdSec 1.6.8+)}; lifts any ban it covers
handle_crowdsec_allowlist_add() {
    _api_check_admin || { _api_error 403 "Admin access required"; return; }
    local body="$1" value comment expires tgt scope val mech out removed=0 exp_norm=""
    [[ "$body" == \{* ]] && jq -e . >/dev/null 2>&1 <<< "$body" || { _api_error 400 "Send a JSON body: {\"value\": \"203.0.113.7\", \"comment\": \"office\", \"expires\": \"30d\"}"; return; }
    value=$(jq -r '(.value // .ip // "") | tostring' <<< "$body")
    comment=$(_cs_clean_reason "$(jq -r '(.comment // "") | tostring' <<< "$body")")
    expires=$(jq -r '(.expires // "") | tostring' <<< "$body")
    tgt=$(_cs_norm_target "$value") || { _api_error 400 "Not an IP address or network: ${value:0:80}"; return; }
    scope="${tgt%%$'\t'*}"; val="${tgt#*$'\t'}"
    # (a network wider than a /8 of IPv4, or than a /16 of IPv6 - the same limits as for a ban)
    if [[ "$scope" == Range ]] && { [[ "$val" == *:* && "${val#*/}" -lt 16 ]] || [[ "$val" != *:* && "${val#*/}" -lt 8 ]]; }; then
        _api_error 400 "$val is far too wide: it would switch CrowdSec off for a large part of the internet"; return
    fi
    if [[ -n "$expires" ]]; then exp_norm=$(_cs_norm_duration "$expires") || { _api_error 400 "Invalid expiry: use 30m, 12h, 7d or 2w"; return; }; fi
    _cs_target || return
    mech=$(_cs_allowlist_mechanism)
    if [[ "$mech" == native ]]; then
        local lists
        lists=$(_cs_json allowlists 0 allowlists list 2>/dev/null) || lists='[]'
        if [[ "$(jq -r --arg n "$CROWDSEC_ALLOWLIST_NAME" 'map(select(.name == $n)) | length' <<< "$lists" 2>/dev/null)" != 1 ]]; then
            _cs_run out allowlists create "$CROWDSEC_ALLOWLIST_NAME" -d "Managed from the CrowdSec page of DCS" || { _api_error 502 "Could not create the allowlist: $(_cs_errline)"; return; }
        fi
        if jq -e --arg n "$CROWDSEC_ALLOWLIST_NAME" --arg v "$val" 'map(select(.name == $n)) | (.[0].items // []) | map(.value) | index($v) != null' >/dev/null 2>&1 <<< "$lists"; then
            _api_response 409 "$(jq -nc --arg v "$val" '{error: true, code: 409, reason: "already_allowed", message: ($v + " is already on the allowlist")}')"; return
        fi
        local -a args=(allowlists add "$CROWDSEC_ALLOWLIST_NAME" "$val" "--comment=$comment")
        [[ -n "$exp_norm" ]] && args+=("--expiration=$exp_norm")
        if ! _cs_run out "${args[@]}"; then _api_error 502 "CrowdSec refused the entry: $(_cs_errline)"; return; fi
        removed=$(printf '%s\n%s\n' "$CS_ERR" "$out" | sed -n 's/^[^0-9]*\([0-9][0-9]*\) decisions\{0,1\} deleted by allowlists.*/\1/p' | tail -n 1); removed="${removed:-0}"
    else
        [[ -z "$exp_norm" ]] || { _api_error 400 "Expiry needs CrowdSec 1.6.8 or newer; this one only supports the permanent trusted list"; return; }
        if _cs_trusted_entries | jq -e --arg v "$val" 'map(.value) | index($v) != null' >/dev/null 2>&1; then
            _api_response 409 "$(jq -nc --arg v "$val" '{error: true, code: 409, reason: "already_allowed", message: ($v + " is already on the allowlist")}')"; return
        fi
        _cs_trust_add "$val" "$comment"
        removed=$(_cs_unban_covered "$val")
    fi
    _cs_cache_clear
    _api_audit_log "${CLIENT_IP:-unknown}" "CROWDSEC_ALLOW" "${AUTH_USERNAME:-}" "$val${comment:+ ($comment)}${exp_norm:+ for $exp_norm}"
    _api_success "$(jq -nc --arg v "$val" --arg s "$scope" --arg m "$mech" --arg c "$comment" --arg e "$exp_norm" --argjson r "${removed:-0}" --argjson now "$(date +%s)" --argjson secs "$(_cs_duration_seconds "${exp_norm:-0s}" || echo 0)" \
        '{success: true, value: $v, kind: (if $s == "Range" then "range" else "ip" end), mechanism: $m, comment: $c, expires_at: (if $e == "" then null else (($now + $secs) | todate) end), removed_bans: $r,
          message: ($v + " will never be banned" + (if $r > 0 then " (lifted " + ($r | tostring) + " active ban" + (if $r == 1 then "" else "s" end) + ")" else "" end))}')"
}

# DELETE /crowdsec/allowlist/{value} — Take an entry off the allowlist (the home address DCS keeps in sync cannot be removed here)
handle_crowdsec_allowlist_remove() {
    _api_check_admin || { _api_error 403 "Admin access required"; return; }
    local value="$1" tgt val mech out home=""
    tgt=$(_cs_norm_target "$value") || { _api_error 400 "Not an IP address or network: ${value:0:80}"; return; }
    val="${tgt#*$'\t'}"
    _cs_target || return
    [[ -f "$CROWDSEC_SYNC_STATE" ]] && home=$(jq -r '.public_ip // ""' "$CROWDSEC_SYNC_STATE" 2>/dev/null)
    if [[ -n "$home" && "$val" == "$home" ]] && ! _cs_trusted_entries | jq -e --arg v "$val" 'map(.value) | index($v) != null' >/dev/null 2>&1; then
        _api_error 409 "$val is your home address: DCS keeps it allowed on its own and it cannot be removed here"; return
    fi
    mech=$(_cs_allowlist_mechanism)
    local removed=false
    if [[ "$mech" == native ]]; then
        local lists
        lists=$(_cs_json allowlists 0 allowlists list 2>/dev/null) || lists='[]'
        if jq -e --arg n "$CROWDSEC_ALLOWLIST_NAME" --arg v "$val" 'map(select(.name == $n) | (.items // []) | map(.value)) | flatten | index($v) != null' >/dev/null 2>&1 <<< "$lists"; then
            _cs_run out allowlists remove "$CROWDSEC_ALLOWLIST_NAME" "$val" || { _api_error 502 "CrowdSec refused: $(_cs_errline)"; return; }
            removed=true
        fi
    fi
    if [[ "$removed" == false ]] && _cs_trusted_entries | jq -e --arg v "$val" 'map(.value) | index($v) != null' >/dev/null 2>&1; then
        _cs_trust_remove "$val"; removed=true
    fi
    if [[ "$removed" == false ]]; then _api_error 404 "$val is not on the allowlist DCS manages"; return; fi
    _cs_cache_clear
    _api_audit_log "${CLIENT_IP:-unknown}" "CROWDSEC_DISALLOW" "${AUTH_USERNAME:-}" "$val"
    _api_success "$(jq -nc --arg v "$val" --arg m "$mech" '{success: true, value: $v, mechanism: $m, message: ($v + " is no longer allowlisted")}')"
}

# =============================================================================
# Bouncers and machines
# =============================================================================

# GET /crowdsec/bouncers — The programs that enforce bans (Traefik's plugin, a firewall …): last pull, type, version, and what DCS registered for Traefik
handle_crowdsec_bouncers() {
    _cs_target || return
    local raw enf
    raw=$(_cs_json bouncers 5 bouncers list) || { _api_error 502 "CrowdSec did not answer: $(_cs_errline)"; return; }
    enf=$(_cs_enforcement_json)
    _cs_probe
    _api_success "$(jq -c --argjson enf "$enf" --argjson tr "$CS_TRAEFIK" --arg mine "$CROWDSEC_BOUNCER_NAME" --argjson now "$(date +%s)" "$_CS_JQ_DEFS"'
        [ (. // [])[] | (.last_pull // null) as $lp | ($lp | if . == null then null else iso_secs end) as $lps
          | { name, type: (.type // ""), version: (.version // ""), ip_address: (.ip_address // ""), last_pull: $lp, created_at: (.created_at // ""), revoked: (.revoked // false),
              auto_created: (.auto_created // false), dcs: (.name == $mine),
              status: (if .revoked then "revoked" elif $lps == null then "never" elif ($now - $lps) < 900 then "active" else "idle" end) } ] as $b
        | { bouncers: $b, count: ($b | length), dcs_bouncer: ($b | map(select(.dcs)) | .[0] // null), name: $mine, enforcement: $enf, traefik: $tr,
            traefik_registerable: ($tr.present and $enf.routes_dir != "") }' <<< "$raw")"
}

# GET /crowdsec/machines — The engines that report to this CrowdSec (this container's own agent, others you enrolled)
handle_crowdsec_machines() {
    _cs_target || return
    local raw
    raw=$(_cs_json machines 10 machines list) || { _api_error 502 "CrowdSec did not answer: $(_cs_errline)"; return; }
    _api_success "$(jq -c '[ (. // [])[] | {id: (.machineId // ""), ip_address: (.ipAddress // ""), version: (.version // ""), validated: (.isValidated // false), last_push: (.last_push // null),
        last_heartbeat: (.last_heartbeat // null), os: (.os // ""), auth_type: (.auth_type // ""), datasources: (.datasources // {})} ] | {machines: ., count: length}' <<< "$raw")"
}

# POST /crowdsec/bouncers — Register a bouncer and show its API key ONCE: {name}
handle_crowdsec_bouncer_add() {
    _api_check_admin || { _api_error 403 "Admin access required"; return; }
    local body="$1" name out key
    [[ "$body" == \{* ]] && jq -e . >/dev/null 2>&1 <<< "$body" || { _api_error 400 "Send a JSON body: {\"name\": \"my-firewall-bouncer\"}"; return; }
    name=$(jq -r '(.name // "") | tostring' <<< "$body")
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{1,62}$ ]] || { _api_error 400 "A bouncer name is 2-63 letters, digits, dots, dashes or underscores"; return; }
    _cs_target || return
    if ! _cs_run out bouncers add "$name" -o raw; then
        local e; e=$(_cs_errline)
        if [[ "$e" == *"already exists"* ]]; then _api_error 409 "A bouncer called $name already exists"; else _api_error 502 "CrowdSec refused: $e"; fi
        return
    fi
    key=$(printf '%s\n' "$out" | tail -n 1 | tr -d '\r\n ')
    [[ "$key" =~ ^[A-Za-z0-9+/=_-]{16,}$ ]] || { _api_error 502 "CrowdSec did not return a key"; return; }
    _cs_cache_clear
    _api_audit_log "${CLIENT_IP:-unknown}" "CROWDSEC_BOUNCER_ADD" "${AUTH_USERNAME:-}" "$name"
    _api_success "$(jq -nc --arg n "$name" --arg k "$key" '{success: true, name: $n, api_key: $k, shown_once: true, message: ("Bouncer " + $n + " registered. Copy its API key now: it is never shown again.")}')"
}

# DELETE /crowdsec/bouncers/{name} — Unregister a bouncer (its API key stops working at once)
handle_crowdsec_bouncer_delete() {
    _api_check_admin || { _api_error 403 "Admin access required"; return; }
    local name="$1" out
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{1,62}$ ]] || { _api_error 400 "Invalid bouncer name"; return; }
    _cs_target || return
    if ! _cs_run out bouncers delete "$name"; then
        local e; e=$(_cs_errline)
        if [[ "$e" == *"does not exist"* || "$e" == *"not found"* ]]; then _api_error 404 "No bouncer called $name"; else _api_error 502 "CrowdSec refused: $e"; fi
        return
    fi
    _cs_cache_clear
    _api_audit_log "${CLIENT_IP:-unknown}" "CROWDSEC_BOUNCER_DEL" "${AUTH_USERNAME:-}" "$name"
    _api_success "$(jq -nc --arg n "$name" --arg mine "$CROWDSEC_BOUNCER_NAME" '{success: true, name: $n, was_dcs_bouncer: ($n == $mine), message: ("Bouncer " + $n + " removed" + (if $n == $mine then ". Traefik no longer hears about bans until you register the Traefik bouncer again." else "" end))}')"
}

# Register the bouncer Traefik uses: a LAPI key, the middleware file, the chain, the plugin declaration. Shared by the deploy hook and the
# "register again" button. Usage: _cs_bouncer_register CONTAINER TEMPLATE_DIR TARGET_STACK TARGET_DIR LOGFILE
_cs_bouncer_register() {
    local container="$1" tdir="$2" target_stack="$3" target_dir="$4" log="$5" dir key lan bk
    dir=$(_find_traefik_routes_dir) || dir=""
    if [[ -z "$dir" ]]; then echo "[dcs] no Traefik routes directory found, the bouncer was not registered" >> "$log"; return 1; fi
    [[ -f "$tdir/files/bouncer-middleware.yml" ]] || { echo "[dcs] the crowdsec template's bouncer-middleware.yml is missing" >> "$log"; return 1; }
    # A crowdsec-bouncer middleware the person defined themselves (in TraefikRoutes.yml, say) is the one Traefik uses: it keeps the first definition it reads
    # and skips the rest, so a second copy would only add an unused key and a second bouncer. Use theirs: put it in the chain and stop.
    local own mine="$dir/$target_stack/crowdsec-bouncer.yml"
    own=$(_traefik_mw_files crowdsec-bouncer "$dir" | grep -vxF "$mine" | head -n 1)
    if [[ -n "$own" && ! -f "$mine" ]]; then
        _traefik_chain_set crowdsec-bouncer add
        echo "[dcs] crowdsec-bouncer is defined in ${own#"$(dirname "$dir")/"} already: DCS did not add a second copy or a second bouncer, and it is in traefik-chain" >> "$log"
        if ! _traefik_ensure_plugin crowdsec-bouncer-traefik-plugin "github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin" "v1.4.4"; then
            docker restart Traefik >/dev/null 2>>"$log" && echo "[dcs] Traefik restarted to load the bouncer plugin" >> "$log"
        fi
        return 0
    fi
    docker exec "$container" cscli bouncers delete "$CROWDSEC_BOUNCER_NAME" >/dev/null 2>&1 || true
    key=$(docker exec "$container" cscli bouncers add "$CROWDSEC_BOUNCER_NAME" -o raw 2>>"$log" | tail -1 | tr -d '\r\n ')
    if [[ ! "$key" =~ ^[A-Za-z0-9+/=_-]{20,}$ ]]; then echo "[dcs] could not register the Traefik bouncer (cscli gave no key)" >> "$log"; return 1; fi
    lan=$(grep -m1 '^TRAEFIK_TRUSTED_LAN=' "$target_dir/.env" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'")
    if [[ -z "$lan" ]]; then
        local ef; for ef in "$COMPOSE_DIR"/*/.env "$BASE_DIR/.env"; do
            [[ -f "$ef" ]] || continue
            lan=$(grep -m1 '^TRAEFIK_TRUSTED_LAN=' "$ef" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'"); [[ -n "$lan" ]] && break
        done
    fi
    [[ -n "$lan" ]] || lan="192.168.1.0/24"
    mkdir -p "$dir/$target_stack"
    # the plugin key is the one this Traefik declares the bouncer under (a middleware under another name is refused)
    bk=$(_traefik_plugin_name "github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin" 2>/dev/null); [[ -n "$bk" ]] || bk=crowdsec-bouncer-traefik-plugin
    K="$key" L="$lan" B="$bk" awk '{ gsub(/__LAPI_KEY__/, ENVIRON["K"]); gsub(/__TRUSTED_LAN__/, ENVIRON["L"]); if ($0 ~ /^        crowdsec-bouncer-traefik-plugin:[ \t]*$/) $0 = "        " ENVIRON["B"] ":"; print }' "$tdir/files/bouncer-middleware.yml" > "$dir/$target_stack/crowdsec-bouncer.yml"
    chmod 600 "$dir/$target_stack/crowdsec-bouncer.yml" 2>/dev/null || true
    # what was set on the CrowdSec page (mode, timings, trusted networks) goes into the fresh file; the key stays the new one
    if [[ -s "$CROWDSEC_STATE_DIR/plugin.json" ]]; then _crowdsec_cfg_lib; _cs_plugin_apply_saved "$dir/$target_stack/crowdsec-bouncer.yml"; fi
    _traefik_chain_set crowdsec-bouncer add
    echo "[dcs] Traefik bouncer registered; crowdsec-bouncer added to traefik-chain" >> "$log"
    # An install whose traefik.yml predates the plugin list would drop every route in the chain: declare the plugin and restart Traefik once
    if ! _traefik_ensure_plugin crowdsec-bouncer-traefik-plugin "github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin" "v1.4.4"; then
        docker restart Traefik >/dev/null 2>>"$log" && echo "[dcs] Traefik restarted to load the bouncer plugin" >> "$log"
    fi
    return 0
}

# POST /crowdsec/bouncers/register-traefik — Register the Traefik bouncer again: a fresh key, the middleware file and the chain entry (the fix for "bans are not enforced")
handle_crowdsec_bouncer_register() {
    _api_check_admin || { _api_error 403 "Admin access required"; return; }
    _cs_target || return
    _cs_probe
    if [[ "$(jq -r '.present' <<< "$CS_TRAEFIK")" != true ]]; then _api_error 409 "Traefik was not found on this server, so there is nothing to register a bouncer for"; return; fi
    local stack="" wd="" log
    wd="$CS_WORKDIR"; [[ -n "$wd" && -d "$wd" ]] && stack="${wd##*/}"
    [[ -n "$stack" && -d "$COMPOSE_DIR/$stack" ]] || stack=$(jq -r '.project // ""' <<< "$CS_TRAEFIK")
    [[ -n "$stack" && -d "$COMPOSE_DIR/$stack" ]] || stack="${CS_PROJECT:-networking-security}"
    log=$(mktemp "${TMPDIR:-/tmp}/dcs-cs-bouncer.XXXXXX")
    if ! _cs_bouncer_register "$CS_NAME" "$TEMPLATES_DIR/crowdsec" "$stack" "$COMPOSE_DIR/$stack" "$log"; then
        _api_error 502 "$(grep '^\[dcs\]' "$log" | tail -n 1 | sed 's/^\[dcs\] //')"; rm -f "$log"; return
    fi
    local said; said=$(sed 's/^\[dcs\] //' "$log" | tr '\n' ' '); rm -f "$log"
    _cs_cache_clear
    _api_audit_log "${CLIENT_IP:-unknown}" "CROWDSEC_BOUNCER_ADD" "${AUTH_USERNAME:-}" "$CROWDSEC_BOUNCER_NAME (re-registered)"
    local lead="The Traefik bouncer is registered again. "
    [[ "$said" == *"did not add a second copy"* ]] && lead="Nothing new to register. "
    _api_success "$(jq -nc --arg m "$said" --arg lead "$lead" '{success: true, name: "'"$CROWDSEC_BOUNCER_NAME"'", message: ($lead + $m)}')"
}

# =============================================================================
# The container itself
# =============================================================================

# POST /crowdsec/traefik/restart — Restart Traefik (it loads a plugin declared in its static configuration only when it starts) and wait until it runs again
handle_crowdsec_traefik_restart() {
    _api_check_admin || { _api_error 403 "Admin access required"; return; }
    local i
    _cs_probe
    (( CS_DOCKER == 1 )) || { _api_error 503 "Docker does not answer: $CS_DOCKER_ERR"; return; }
    [[ "$(jq -r '.present' <<< "$CS_TRAEFIK")" == true ]] || { _api_error 409 "Traefik was not found on this server"; return; }
    timeout 90 docker restart Traefik >/dev/null 2>&1 || { _api_error 502 "docker could not restart Traefik"; return; }
    for i in $(seq 1 20); do [[ "$(docker inspect -f '{{.State.Running}}' Traefik 2>/dev/null)" == true ]] && break; sleep 1; done
    _cs_cache_clear
    _api_audit_log "${CLIENT_IP:-unknown}" "CROWDSEC_TRAEFIK_RESTART" "${AUTH_USERNAME:-}" "Traefik restarted"
    _api_success "$(jq -nc '{success: true, message: "Traefik was restarted. It loads the bouncer plugin as it starts."}')"
}

# POST /crowdsec/service — Start, restart or reload CrowdSec: {action: start|restart|reload}
handle_crowdsec_service() {
    _api_check_admin || { _api_error 403 "Admin access required"; return; }
    local body="$1" action i st
    [[ "$body" == \{* ]] && jq -e . >/dev/null 2>&1 <<< "$body" || { _api_error 400 "Send a JSON body: {\"action\": \"restart\"}"; return; }
    action=$(jq -r '(.action // "") | tostring' <<< "$body")
    [[ "$action" =~ ^(start|restart|reload)$ ]] || { _api_error 400 "action must be start, restart or reload"; return; }
    _cs_probe
    (( CS_DOCKER == 1 )) || { _api_error 503 "Docker does not answer: $CS_DOCKER_ERR"; return; }
    [[ -n "$CS_NAME" ]] || { _api_error 404 "CrowdSec is not deployed"; return; }
    case "$action" in
        start)
            if [[ "$CS_RSTATE" == running ]]; then _api_success "$(jq -nc '{success: true, action: "start", state: "running", message: "CrowdSec is already running"}')"; return; fi
            timeout 60 docker start "$CS_NAME" >/dev/null 2>&1 || { _api_error 502 "docker could not start $CS_NAME"; return; } ;;
        restart)
            timeout 120 docker restart "$CS_NAME" >/dev/null 2>&1 || { _api_error 502 "docker could not restart $CS_NAME"; return; } ;;
        reload)
            [[ "$CS_RSTATE" == running ]] || { _api_error 409 "CrowdSec is not running"; return; }
            timeout 20 docker kill -s HUP "$CS_NAME" >/dev/null 2>&1 || { _api_error 502 "docker could not signal $CS_NAME"; return; } ;;
    esac
    # a moment for the container to be up (health follows on its own; the page polls)
    for i in 1 2 3 4 5 6 7 8 9 10; do
        st=$(timeout 5 docker inspect -f '{{.State.Status}}' "$CS_NAME" 2>/dev/null)
        [[ "$st" == running ]] && break
        sleep 1
    done
    _cs_cache_clear
    _api_audit_log "${CLIENT_IP:-unknown}" "CROWDSEC_SERVICE" "${AUTH_USERNAME:-}" "$action $CS_NAME"
    _api_success "$(jq -nc --arg a "$action" --arg s "${st:-unknown}" '{success: true, action: $a, state: $s, message: (if $a == "reload" then "CrowdSec reloaded its parsers, scenarios and allowlists" elif $a == "start" then "CrowdSec is starting" else "CrowdSec restarted" end)}')"
}

# GET /crowdsec/logs — The tail of the container's log: lines (10-500), level (all|warn|error), q (text), lapi=1 to include the noisy API request lines
handle_crowdsec_logs() {
    _cs_probe
    (( CS_DOCKER == 1 )) || { _api_error 503 "Docker does not answer: $CS_DOCKER_ERR"; return; }
    [[ -n "$CS_NAME" ]] || { _api_error 404 "CrowdSec is not deployed"; return; }
    local n="${QUERY_PARAMS[lines]:-200}" level="${QUERY_PARAMS[level]:-all}" q="${QUERY_PARAMS[q]:-}" lapi="${QUERY_PARAMS[lapi]:-0}" raw
    [[ "$n" =~ ^[0-9]{1,3}$ ]] && (( n >= 10 && n <= 500 )) || { _api_error 400 "lines must be 10-500"; return; }
    [[ "$level" =~ ^(all|warn|error)$ ]] || { _api_error 400 "level must be all, warn or error"; return; }
    [[ "$lapi" =~ ^[01]$ ]] || { _api_error 400 "lapi must be 0 or 1"; return; }
    q="${q:0:100}"
    raw=$(timeout 15 docker logs --tail $(( n * 6 )) "$CS_NAME" 2>&1 </dev/null | tail -c 400000)
    _api_success "$(printf '%s\n' "$raw" | jq -Rsc --arg level "$level" --arg q "$q" --argjson lapi "$lapi" --argjson n "$n" --arg name "$CS_NAME" --arg state "$CS_RSTATE" '
        def unq: gsub("\\\\\""; "\"") | gsub("\\\\\\\\"; "\\");
        [ split("\n")[] | select(length > 0) | . as $l
          | ($l | capture("^time=\"(?<time>[^\"]+)\" level=(?<level>[a-z]+) msg=\"(?<msg>(?:\\\\.|[^\"\\\\])*)\"(?<rest>.*)$")? // null) as $p
          | if $p == null then {time: "", level: "info", module: "", message: $l}
            else {time: $p.time, level: (if $p.level == "warning" then "warn" elif $p.level == "fatal" or $p.level == "panic" then "error" else $p.level end),
                  module: (($p.rest | capture("module=(?<m>[A-Za-z0-9_.-]+)")? // {m: ""}) | .m),
                  # the fields after msg= (ip=…, duration=…, error="…") stay on the line, without the module the chip already shows
                  message: (($p.msg | unq) + ($p.rest | gsub("^\\s+|\\s+$"; "") | sub("(^| )module=[A-Za-z0-9_.-]+"; "") | gsub("^\\s+|\\s+$"; "") | if length > 0 then " " + . else "" end))} end
          | select($lapi == 1 or .module != "lapi")
          | select($level == "all" or (if $level == "warn" then (.level == "warn" or .level == "error") else .level == "error" end))
          | select($q == "" or (.message | ascii_downcase | contains($q | ascii_downcase))) ] as $all
        | {container: $name, state: $state, lines: ($all | .[-$n:]), count: ($all | length), lapi_included: ($lapi == 1)}')"
}

# =============================================================================
# The hub: collections, scenarios and parsers
# =============================================================================

# Curated for a Traefik + SSH server. Every entry works from the logs CrowdSec already reads (Traefik's access log, the host's syslog).
_CS_HUB_SUGGESTIONS='[
 {"name":"crowdsecurity/traefik","group":"Web","title":"Traefik","description":"Reads Traefik'"'"'s access log and flags scanners, probing and abuse."},
 {"name":"crowdsecurity/base-http-scenarios","group":"Web","title":"Web scanners","description":"Probing, bad user agents, sensitive files, crawlers, path traversal, SQL injection and XSS attempts."},
 {"name":"crowdsecurity/http-cve","group":"Web","title":"Known exploits","description":"Exploit attempts for known vulnerabilities (Log4Shell, Spring4Shell, Confluence and many more)."},
 {"name":"crowdsecurity/http-dos","group":"Web","title":"HTTP floods","description":"Detects request floods aimed at your sites."},
 {"name":"crowdsecurity/whitelist-good-actors","group":"Web","title":"Good actors","description":"Never bans search engines, CDNs and public DNS resolvers."},
 {"name":"crowdsecurity/linux","group":"System","title":"Linux and SSH","description":"Parses the syslog and catches SSH brute force."},
 {"name":"crowdsecurity/sshd","group":"System","title":"SSH daemon","description":"Dedicated SSH brute-force and slow-brute-force detection."},
 {"name":"crowdsecurity/iptables","group":"System","title":"Port scans","description":"Port scans seen in iptables logs."}
]'

# JSON of the installed hub items by kind, plus the upgradable count
_cs_hub_installed() {
    local raw
    raw=$(_cs_json hub 90 hub list) || return 1
    jq -c '{collections: (.collections // []), scenarios: (.scenarios // []), parsers: (.parsers // [])}
           | map_values(map({name, version: (.local_version // ""), description: (.description // ""), status: (.status // ""), enabled: ((.status // "") | startswith("enabled")), update: ((.status // "") | contains("update-available")), tainted: ((.status // "") | contains("tainted")), local: ((.status // "") | contains("local"))}) | sort_by(.name))' <<< "$raw"
}

# GET /crowdsec/hub — Installed collections, scenarios and parsers (with which have updates) and a short list of suggestions; ?type=collections|scenarios|parsers&available=1&q= lists what can be installed
handle_crowdsec_hub() {
    _cs_target || return
    local kind="${QUERY_PARAMS[type]:-}" avail="${QUERY_PARAMS[available]:-0}" q="${QUERY_PARAMS[q]:-}" limit="${QUERY_PARAMS[limit]:-60}" inst raw
    q="${q:0:80}"
    [[ "$avail" =~ ^[01]$ ]] || { _api_error 400 "available must be 0 or 1"; return; }
    [[ -z "$kind" || "$kind" =~ ^(collections|scenarios|parsers)$ ]] || { _api_error 400 "type must be collections, scenarios or parsers"; return; }
    [[ "$limit" =~ ^[0-9]{1,3}$ ]] && (( limit >= 1 && limit <= 500 )) || { _api_error 400 "limit must be 1-500"; return; }
    if [[ "$avail" == 1 ]]; then
        [[ -n "$kind" ]] || { _api_error 400 "type is needed with available=1"; return; }
        raw=$(_cs_json "hub_available_$kind" 120 "$kind" list -a) || { _api_error 502 "CrowdSec did not answer: $(_cs_errline)"; return; }
        _api_success "$(jq -c --arg k "$kind" --arg q "$q" --argjson limit "$limit" '
            (.[$k] // []) as $all | ($q | ascii_downcase) as $ql
            | [ $all[] | {name, description: (.description // ""), version: (.local_version // ""), installed: ((.status // "") | startswith("enabled")), update: (((.status // "") | startswith("enabled")) and ((.status // "") | contains("update-available")))}
                | select($ql == "" or ((.name + " " + .description) | ascii_downcase | contains($ql))) ] as $f
            | {type: $k, items: ($f | sort_by([(.installed | not), .name]) | .[0:$limit]), count: ($f | length), total: ($all | length)}' <<< "$raw")"
        return
    fi
    inst=$(_cs_hub_installed) || { _api_error 502 "CrowdSec did not answer: $(_cs_errline)"; return; }
    _api_success "$(jq -c --argjson sug "$_CS_HUB_SUGGESTIONS" '
        . as $i | ($i.collections | map(.name)) as $have
        | { installed: $i, counts: {collections: ($i.collections | length), scenarios: ($i.scenarios | length), parsers: ($i.parsers | length),
                                     updates: ([$i[] | .[] | select(.update)] | length)},
            suggestions: [ $sug[] | . + {installed: (.name as $n | $have | index($n) != null)} ] }' <<< "$inst")"
}

# _cs_hub_reload — make CrowdSec pick up hub changes (SIGHUP reloads parsers, scenarios and profiles)
_cs_hub_reload() { timeout 20 docker kill -s HUP "$CS_NAME" >/dev/null 2>&1 || true; sleep 2; }

# POST /crowdsec/hub/update — Fetch the newest hub index (needs internet on the server)
handle_crowdsec_hub_update() {
    _api_check_admin || { _api_error 403 "Admin access required"; return; }
    _cs_target || return
    local out
    if ! CS_TIMEOUT=120 _cs_run out hub update; then _api_error 502 "The hub did not answer: $(_cs_errline)"; return; fi
    _cs_cache_clear
    _api_audit_log "${CLIENT_IP:-unknown}" "CROWDSEC_HUB" "${AUTH_USERNAME:-}" "update"
    _api_success "$(jq -nc --arg o "$(printf '%s\n%s\n' "$CS_ERR" "$out" | grep -v '^[[:space:]]*$' | tail -n 3 | tr '\n' ' ')" '{success: true, message: "The hub index is up to date", detail: $o}')"
}

# POST /crowdsec/hub/upgrade — Upgrade every installed collection, scenario and parser, then reload
handle_crowdsec_hub_upgrade() {
    _api_check_admin || { _api_error 403 "Admin access required"; return; }
    _cs_target || return
    local out
    if ! CS_TIMEOUT=180 _cs_run out hub upgrade; then _api_error 502 "The upgrade failed: $(_cs_errline)"; return; fi
    _cs_hub_reload
    _cs_cache_clear
    _api_audit_log "${CLIENT_IP:-unknown}" "CROWDSEC_HUB" "${AUTH_USERNAME:-}" "upgrade"
    _api_success "$(jq -nc --arg o "$(printf '%s\n%s\n' "$CS_ERR" "$out" | grep -v '^[[:space:]]*$' | grep -vi 'systemctl' | tail -n 6 | cut -c1-200 | tr '\n' ' ')" '{success: true, message: "Hub items upgraded and CrowdSec reloaded", detail: $o}')"
}

# Install or remove one hub item: {type: collections|scenarios|parsers, name}; CrowdSec reloads afterwards
_cs_hub_change() {
    local verb="$1" body="$2" kind name out ev
    _api_check_admin || { _api_error 403 "Admin access required"; return; }
    [[ "$body" == \{* ]] && jq -e . >/dev/null 2>&1 <<< "$body" || { _api_error 400 "Send a JSON body: {\"type\": \"collections\", \"name\": \"crowdsecurity/nginx\"}"; return; }
    kind=$(jq -r '(.type // "") | tostring' <<< "$body"); name=$(jq -r '(.name // "") | tostring' <<< "$body")
    [[ "$kind" =~ ^(collections|scenarios|parsers)$ ]] || { _api_error 400 "type must be collections, scenarios or parsers"; return; }
    _cs_valid_name "$name" || { _api_error 400 "Invalid hub item name"; return; }
    _cs_target || return
    if ! CS_TIMEOUT=150 _cs_run out "$kind" "$verb" "$name"; then
        local e; e=$(_cs_errline)
        if [[ "$e" == *"can't find"* || "$e" == *"not found"* ]]; then _api_error 404 "$name is not in the hub"; else _api_error 502 "CrowdSec refused: $e"; fi
        return
    fi
    # cscli exits 0 when it did nothing (an item another collection still needs stays installed): look at the result
    local said="$CS_ERR$out" after here=no
    if _cs_run after "$kind" list -o json; then
        jq -e --arg k "$kind" --arg n "$name" '(.[$k] // []) | map(select(.name == $n and ((.status // "") | startswith("enabled")))) | length > 0' >/dev/null 2>&1 <<< "$after" && here=yes
    else
        here=unknown
    fi
    _cs_cache_clear
    if [[ "$verb" == remove && "$here" == yes ]]; then
        local why; why=$(printf '%s\n' "$said" | grep -i -E 'cannot|can.t|used by|required|depend|still' | head -n 1 | cut -c1-200)
        _api_response 409 "$(jq -nc --arg n "$name" --arg w "$why" '{error: true, code: 409, reason: "still_installed", message: ($n + " is still installed: CrowdSec keeps it because another installed collection needs it. Remove that collection instead." + (if $w != "" then " (" + $w + ")" else "" end))}')"
        return
    fi
    if [[ "$verb" == install && "$here" == no ]]; then _api_error 502 "CrowdSec did not install $name"; return; fi
    _cs_hub_reload
    ev="CROWDSEC_HUB"
    _api_audit_log "${CLIENT_IP:-unknown}" "$ev" "${AUTH_USERNAME:-}" "$verb $kind $name"
    _api_success "$(jq -nc --arg v "$verb" --arg k "$kind" --arg n "$name" '{success: true, action: $v, type: $k, name: $n, message: ($n + (if $v == "install" then " installed" else " removed" end) + " and CrowdSec reloaded")}')"
}
# POST /crowdsec/hub/install — Install a collection, scenario or parser from the hub: {type: collections|scenarios|parsers, name}; CrowdSec reloads afterwards
handle_crowdsec_hub_install() { _cs_hub_change install "$1"; }
# POST /crowdsec/hub/remove — Remove an installed collection, scenario or parser: {type: collections|scenarios|parsers, name}; CrowdSec reloads afterwards
handle_crowdsec_hub_remove() { _cs_hub_change remove "$1"; }

# =============================================================================
# Simulation mode: a scenario that alerts without banning
# =============================================================================

# JSON {global, exclusions} from simulation.yaml in the container
_cs_simulation_file() {
    local raw
    raw=$(timeout 8 docker exec "$CS_NAME" cat /etc/crowdsec/simulation.yaml 2>/dev/null </dev/null) || raw=""
    printf '%s\n' "$raw" | awk '
        /^simulation:/ { g = ($2 == "true") ? "true" : "false" }
        /^exclusions:/ { inex = 1; next }
        inex && /^[[:space:]]*-[[:space:]]+/ { line = $0; sub(/^[[:space:]]*-[[:space:]]+/, "", line); sub(/[[:space:]]+#.*$/, "", line); gsub(/["'"'"']/, "", line); ex[++n] = line; next }
        inex && /^[^[:space:]#]/ { inex = 0 }
        END { printf "%s\n", (g == "" ? "false" : g); for (i = 1; i <= n; i++) print ex[i] }' \
        | jq -Rsc 'split("\n") | map(select(length > 0)) | {global: (.[0] == "true"), exclusions: .[1:]}'
}

# GET /crowdsec/simulation — Which scenarios only alert (simulation mode) and which ban
handle_crowdsec_simulation() {
    _cs_target || return
    local st inst
    st=$(_cs_simulation_file); [[ "$st" == \{* ]] || st='{"global":false,"exclusions":[]}'
    inst=$(_cs_hub_installed | jq -c '.scenarios // []' 2>/dev/null); [[ "$inst" == \[* ]] || inst='[]'
    _api_success "$(jq -nc --argjson st "$st" --argjson sc "$inst" '
        ($st.exclusions) as $ex
        | [ $sc[] | .name as $n | {name: $n, description: .description, simulated: (if $st.global then (($ex | index($n)) == null) else (($ex | index($n)) != null) end)} ] as $rows
        | {global: $st.global, exclusions: $ex, scenarios: $rows, simulated_count: ($rows | map(select(.simulated)) | length),
           note: (if $st.global then "Everything only raises alerts, except the scenarios listed as excluded." else "Only the scenarios listed here raise alerts without banning; all the others ban." end)}')"
}

# POST /crowdsec/simulation — {scenario, enabled}: make one scenario alert-only (enabled true) or ban again; {global: true, enabled} switches the whole engine
handle_crowdsec_simulation_set() {
    _api_check_admin || { _api_error 403 "Admin access required"; return; }
    local body="$1" scenario enabled global out st gl ex
    [[ "$body" == \{* ]] && jq -e . >/dev/null 2>&1 <<< "$body" || { _api_error 400 "Send a JSON body: {\"scenario\": \"crowdsecurity/http-probing\", \"enabled\": true}"; return; }
    jq -e '.enabled | type == "boolean"' >/dev/null 2>&1 <<< "$body" || { _api_error 400 "enabled must be true or false"; return; }
    enabled=$(jq -r '.enabled' <<< "$body"); global=$(jq -r 'if .global == true then "yes" else "no" end' <<< "$body")
    scenario=$(jq -r '(.scenario // "") | tostring' <<< "$body")
    _cs_target || return
    local verb=disable; [[ "$enabled" == true ]] && verb=enable
    if [[ "$global" == yes ]]; then
        # the meaning of the exclusion list flips with the mode: clear it first so nothing changes behind the switch
        st=$(_cs_simulation_file); gl=$(jq -r '.global' <<< "$st")
        if [[ "$gl" != "$enabled" ]]; then
            local cverb=disable; [[ "$gl" == true ]] && cverb=enable
            while IFS= read -r ex; do [[ -n "$ex" ]] && _cs_valid_pattern "$ex" && _cs_run out simulation "$cverb" "$ex" >/dev/null; done < <(jq -r '.exclusions[]' <<< "$st")
            _cs_run out simulation "$verb" --global || { _api_error 502 "CrowdSec refused: $(_cs_errline)"; return; }
        fi
    else
        _cs_valid_pattern "$scenario" && [[ "$scenario" != *'*' ]] || { _api_error 400 "Name the scenario, e.g. crowdsecurity/http-probing"; return; }
        _cs_hub_installed | jq -e --arg s "$scenario" '.scenarios | map(.name) | index($s) != null' >/dev/null 2>&1 || { _api_error 404 "$scenario is not an installed scenario"; return; }
        if ! _cs_run out simulation "$verb" "$scenario"; then _api_error 502 "CrowdSec refused: $(_cs_errline)"; return; fi
        # cscli exits 0 even when it refuses: the file says what really happened
        st=$(_cs_simulation_file)
        if ! jq -e --arg s "$scenario" --argjson want "$enabled" '(.global) as $g | (.exclusions | index($s) != null) as $in | (if $g then ($in | not) else $in end) == $want' >/dev/null 2>&1 <<< "$st"; then
            _api_error 502 "CrowdSec did not change $scenario: $(printf '%s\n%s\n' "$CS_ERR" "$out" | grep -E 'level=(error|warning)' | tail -n 1 | cut -c1-200)"; return
        fi
    fi
    _cs_hub_reload
    _cs_cache_clear
    _api_audit_log "${CLIENT_IP:-unknown}" "CROWDSEC_SIMULATION" "${AUTH_USERNAME:-}" "${scenario:-global} $verb"
    st=$(_cs_simulation_file)
    _api_success "$(jq -nc --argjson st "$st" --arg s "$scenario" --arg g "$global" --arg v "$verb" '{success: true, global: $st.global, exclusions: $st.exclusions,
        message: (if $g == "yes" then (if $v == "enable" then "Everything now raises alerts without banning" else "Scenarios ban again" end) else ($s + (if $v == "enable" then " now only raises alerts" else " bans again" end)) end)}')"
}

# =============================================================================
# Community blocklist and console
# =============================================================================

# GET /crowdsec/community — Is the community blocklist (CAPI) pulled, are signals shared, is the machine enrolled in the CrowdSec console
handle_crowdsec_community() {
    _cs_target || return
    local out capi console cached
    if cached=$(_cs_cache_get community 120); then _api_success "$cached"; return; fi
    CS_TIMEOUT=25 _cs_run out capi status; local rc=$?
    capi=$(printf '%s\n%s\n' "$CS_ERR" "$out" | jq -Rsc --argjson rc "$rc" '
        . as $t | { registered: (($t | test("Loaded credentials|You can successfully interact")) ),
                    reachable: ($t | test("successfully interact with Central API")),
                    sharing: ($t | test("Sharing signals is enabled")), pulling: ($t | test("Pulling community blocklist is enabled")),
                    console_blocklists: ($t | test("Pulling blocklists from the console is enabled")),
                    error: (if $rc == 0 then null else ($t | split("\n") | map(select(test("^Error|level=(fatal|error)"))) | .[-1] // "CAPI did not answer") end) }')
    [[ "$capi" == \{* ]] || capi='{"registered":false,"reachable":false,"sharing":false,"pulling":false,"console_blocklists":false,"error":"could not read CAPI status"}'
    # HTTP 403 from the Central API is CrowdSec refusing this server, either its login or its address; the message alone reads like a broken install
    local hint="HTTP 403: CrowdSec's Central API is refusing this server. It either no longer accepts the login or refuses the server's address. Run: docker exec CrowdSec cscli capi register, then restart CrowdSec. If that is refused with 403 as well, it is the address: that usually clears by itself, and CrowdSec can lift it. Detections, bans and alerts here keep working; only the shared blocklist is missing."
    capi=$(jq -c --arg hint "$hint" 'if ((.error // "") | test("Forbidden|403")) then .error += " " + $hint | .forbidden = true else . end' <<< "$capi")
    _cs_run out console status -o json || true
    console=$(jq -c '{authenticated: (.console.authenticated // false), enrolled: (.console.enrolled // false), registered: (.console.registered // false), decision_management: (.console.decision_management // false), plan: (.console.plan // ""),
                      sharing: (.sharing_options // {})}' <<< "$out" 2>/dev/null); [[ "$console" == \{* ]] || console='{"authenticated":false,"enrolled":false,"registered":false,"decision_management":false,"plan":"","sharing":{}}'
    local res
    res=$(jq -nc --argjson capi "$capi" --argjson console "$console" --argjson community "$(_cs_community_count)" \
        '{capi: $capi, console: $console, community_decisions: $community,
          note: (if $console.enrolled then "This engine is enrolled in the CrowdSec console." else "Not enrolled in the CrowdSec console. Enrolling is optional: it adds a web dashboard and extra blocklists (cscli console enroll <key>)." end)}')
    printf '%s' "$res" | _cs_cache_put community
    _api_success "$res"
}
