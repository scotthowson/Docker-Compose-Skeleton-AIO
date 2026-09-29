#!/bin/bash
# shellcheck disable=SC2034  # PVE_CODE, PVE_BASE, PVE_REDIRECT and PVE_ERR are results for the caller
# =============================================================================
# What setup.sh looks at before it changes anything: the tools the API server
# runs on, whether this user may use Docker, and the Proxmox link (where
# Proxmox answers, whether it takes the token, what the token may do).
# Nothing here prints or asks; setup.sh does that. Sourced by setup.sh, and by
# tests/smoke.sh on its own. (The package manager comes from environment.sh.)
# =============================================================================

# The tools the API server needs that are not installed, as package names (space
# separated, empty: none) — the list start.sh checks: python3 hashes the passwords,
# socat (or ncat) is the listener
_missing_tools() {
    local t out=()
    for t in jq curl python3 openssl git; do command -v "$t" >/dev/null 2>&1 || out+=("$t"); done
    command -v socat >/dev/null 2>&1 || command -v ncat >/dev/null 2>&1 || out+=(socat)
    echo "${out[*]}"
}

# running | denied (the daemon answers, this user may not use it) | stopped
_docker_state() {
    local err
    err=$(timeout 20 docker info 2>&1 >/dev/null) && { echo running; return 0; }
    if [[ "${err,,}" == *"permission denied"* ]]; then echo denied; else echo stopped; fi
}

# _in_docker_group USER — USER is in the docker group in the group database (a login
# that started before USER was added does not have it yet)
_in_docker_group() { id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qx docker; }

# _read_secret PROMPT VAR — hidden entry that prints a * for every character, so
# typing and pasting both show. Backspace and Ctrl-U edit; Enter ends it.
_read_secret() {
    local __s="" __c="" __n=""
    printf '%s' "$1" >&2
    while IFS= read -r -s -n 1 __c; do
        case "$__c" in
            "") break ;;
            $'\x7f'|$'\b') if [[ -n "$__s" ]]; then __s="${__s%?}"; printf '\b \b' >&2; fi ;;
            $'\x15') while [[ -n "$__s" ]]; do __s="${__s%?}"; printf '\b \b' >&2; done ;;
            $'\e')
                # arrow keys and the marks some terminals put around a paste are not part of the secret
                IFS= read -r -s -n 1 -t 0.05 __n || true
                if [[ "$__n" == "[" ]]; then
                    while IFS= read -r -s -n 1 -t 0.05 __n; do case "$__n" in [0-9]|";") ;; *) break ;; esac; done
                elif [[ "$__n" == "O" ]]; then
                    IFS= read -r -s -n 1 -t 0.05 __n || true
                fi ;;
            [[:print:]]) __s+="$__c"; printf '*' >&2 ;;
        esac
    done
    printf '\n' >&2
    printf -v "$2" '%s' "$__s"
}

# A Proxmox token secret is the UUID Proxmox shows once, when the token is made
_pve_secret_ok() { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }

# A token ID is user@realm!name (the user part may itself hold an @, as in an e-mail address)
_pve_tid_ok() { local re='^[^[:space:]!=:/]+@[A-Za-z][A-Za-z0-9._-]*![A-Za-z][A-Za-z0-9._-]*$'; [[ "$1" =~ $re ]]; }

# _pve_clean_url TEXT — the address typed or pasted from the browser, as a base URL: the
# web UI's #fragment, a query and an /api2/json path dropped. http:// becomes https://: on
# 8006 Proxmox answers plain HTTP with a redirect and nothing else (_pve_find still tries
# plain http when that is what was typed and https finds nothing).
_pve_clean_url() {
    local u="${1//[[:space:]]/}" scheme rest
    [[ -n "$u" ]] || return 0
    [[ "$u" == *://* ]] || u="https://$u"
    u="${u%%#*}"; u="${u%%\?*}"; u="${u%%/api2/json*}"
    while [[ "$u" == */ ]]; do u="${u%/}"; done
    scheme="${u%%://*}"; scheme="${scheme,,}"; rest="${u#*://}"
    [[ "$scheme" == "http" ]] && scheme="https"
    printf '%s://%s' "$scheme" "$rest"
}

# _pve_probe BASE TOKEN_ID SECRET — asks BASE/api2/json/version with the token. Sets
# PVE_CODE (000 when nothing answered), PVE_REDIRECT (where a 3xx points) and PVE_ERR
# (curl's reason). The token reaches curl on stdin, never on its command line.
_pve_probe() {
    local out
    out=$(printf 'Authorization: PVEAPIToken=%s=%s\n' "$2" "$3" \
        | curl -sSk -o /dev/null --max-time 8 -H @- -w '\n%{http_code}\t%{redirect_url}' "$1/api2/json/version" 2>&1) || true
    PVE_ERR="${out%$'\n'*}"; PVE_ERR="${PVE_ERR%%$'\n'*}"; PVE_ERR="${PVE_ERR#curl: }"
    [[ "$PVE_ERR" =~ ^\([0-9]+\)\ (.*)$ ]] && PVE_ERR="${BASH_REMATCH[1]}"
    out="${out##*$'\n'}"; PVE_CODE="${out%%$'\t'*}"; PVE_REDIRECT="${out#*$'\t'}"
    [[ "$PVE_CODE" =~ ^[0-9]{3}$ ]] || PVE_CODE="000"
}

# _pve_find TYPED TOKEN_ID SECRET — sets PVE_BASE to the first address where Proxmox
# answers (200, 401 or 403) and PVE_CODE to its answer; 1 when none did. Tried in turn:
# the address typed (as https), with :8006 when no port was given, then plain http when
# that is what was typed. One redirect is followed. On failure PVE_CODE and PVE_ERR
# describe the address as typed.
_pve_find() {
    local typed="$1" clean c r first_code="" first_err="" cands=()
    PVE_BASE=""
    clean=$(_pve_clean_url "$typed"); [[ -n "$clean" ]] || { PVE_CODE="000"; PVE_ERR="no address"; return 1; }
    cands=("$clean")
    r="${clean#*://}"; r="${r%%/*}"
    [[ "$r" =~ :[0-9]+$ ]] || cands+=("${clean%%://*}://$r:8006${clean#*://"$r"}")
    [[ "${typed,,}" == http://* ]] && cands+=("http://${clean#*://}")
    for c in "${cands[@]}"; do
        _pve_probe "$c" "$2" "$3"
        if [[ "$PVE_CODE" =~ ^30[1278]$ && "$PVE_REDIRECT" == http*://* ]]; then
            r="${PVE_REDIRECT#*://}"; c="${PVE_REDIRECT%%://*}://${r%%/*}"
            _pve_probe "$c" "$2" "$3"
        fi
        [[ -n "$first_code" ]] || { first_code="$PVE_CODE"; first_err="$PVE_ERR"; }
        case "$PVE_CODE" in 200|401|403) PVE_BASE="$c"; return 0 ;; esac
    done
    PVE_CODE="$first_code"; PVE_ERR="$first_err"
    return 1
}

# _pve_tls_verifies BASE — 0 when BASE's certificate checks out (the 401 without a token is fine)
_pve_tls_verifies() { curl -s -o /dev/null --max-time 8 "$1/api2/json/version" >/dev/null 2>&1; }

# _pve_missing_privs BASE TOKEN_ID SECRET — the privileges DCS uses that the token lacks on /
# (space separated; empty when all are there or Proxmox did not say)
_pve_missing_privs() {
    local perms
    perms=$(printf 'Authorization: PVEAPIToken=%s=%s\n' "$2" "$3" \
        | curl -sk --max-time 8 -H @- "$1/api2/json/access/permissions?path=/" 2>/dev/null) || return 0
    jq -r 'if (.data | type) == "object" then (.data["/"] // {}) as $p | ["VM.Audit", "VM.PowerMgmt", "Sys.Audit"] | map(select(. as $k | $p | has($k) | not)) | join(" ") else empty end' <<< "$perms" 2>/dev/null || true
}
