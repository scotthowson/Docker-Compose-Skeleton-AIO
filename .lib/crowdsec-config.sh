#!/bin/bash
# shellcheck shell=bash
# =============================================================================
# CrowdSec page — the ban profile and the Discord notifications
#
# Two files decide what CrowdSec does with an attack: profiles.yaml (how long a
# ban lasts, which scenario gets its own length, whether repeat offenders are
# banned longer, who is told) and notifications/http.yaml (the Discord message).
# This file writes both from settings the page edits, and does it safely:
#   1. the candidate files are built from the settings (no YAML library needed),
#   2. CrowdSec itself checks them (`crowdsec -t` on an alternate config, and a
#      dry run of the notification plugin against a dead address),
#   3. the live files are backed up, replaced, the container restarted and
#      watched until it is healthy again,
#   4. anything that goes wrong puts the backups back and restarts once more.
# The settings live in .data/crowdsec/{settings,notify}.json; the profile file
# also carries them in its header, so it explains itself.
#
# Sourced on demand by _crowdsec_cfg_lib (api-server.sh), after crowdsec.sh.
# =============================================================================

# shellcheck disable=SC2034  # read by the router (_crowdsec_cfg_lib in api-server.sh)
CROWDSEC_CFG_LOADED=1
CS_PROFILES_PATH="/etc/crowdsec/profiles.yaml"
CS_HTTP_PATH="/etc/crowdsec/notifications/http.yaml"
CS_SETTINGS_FILE="$CROWDSEC_STATE_DIR/settings.json"
CS_NOTIFY_FILE="$CROWDSEC_STATE_DIR/notify.json"
CS_NOTIFY_STATUS="$CROWDSEC_STATE_DIR/notify-status.json"
CS_BACKUP_DIR="$CROWDSEC_STATE_DIR/backups"
CS_WEBHOOK_SECRET="CROWDSEC_DISCORD_WEBHOOK"
# automatic bans may last up to a year; only a person can ban for ten
CS_MAX_AUTO_SECONDS=31536000
CS_CFG_ERR=""

# a JSON object from a file, or the given default
_cs_json_file() {
    local f="$1" d="${2:-\{\}}" j
    if [[ -s "$f" ]] && j=$(jq -c 'if type == "object" then . else empty end' "$f" 2>/dev/null) && [[ -n "$j" ]]; then printf '%s' "$j"; else printf '%s' "$d"; fi
}
# write a JSON object atomically, private
_cs_json_save() {
    local f="$1" tmp
    mkdir -p "$(dirname "$f")" 2>/dev/null
    tmp=$(umask 077; mktemp "$f.XXXXXX") || return 1
    cat > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$f"
}

# =============================================================================
# The live files
# =============================================================================

# _cs_live_file PATH — the file as it is in the container (empty when absent)
_cs_live_file() { timeout 10 docker exec "$CS_NAME" cat "$1" 2>/dev/null </dev/null; }

# =============================================================================
# profiles.yaml: reading what is there
# =============================================================================

# JSON view of a profiles file: which profiles, what durations, who is notified, and whether DCS wrote it or it is untouched stock
#   mode: dcs (written here) | stock (CrowdSec's or DCS's shipped file, nothing else) | custom (anything else) | missing
_cs_profile_inspect() {
    local raw="$1" hdr
    if [[ -z "${raw//[[:space:]]/}" ]]; then printf '{"mode":"missing","profiles":[],"ip_duration":null,"range_duration":null,"escalate":false,"notified":false,"header":null}'; return; fi
    hdr=$(printf '%s\n' "$raw" | sed -n '1,6s/^# dcs-settings: //p' | head -n 1)
    printf '%s\n' "$raw" | awk '
        BEGIN { doc = 0 }
        /^---[[:space:]]*$/ { doc++; sect=""; next }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        /^[A-Za-z_]+:/ { key=$0; sub(/:.*/, "", key); val=$0; sub(/^[A-Za-z_]+:[[:space:]]*/, "", val); sub(/[[:space:]]+#.*$/, "", val); sect=key; print doc "\tkey\t" key "\t" val; next }
        sect != "" && /^[[:space:]]+-[[:space:]]+/ { item=$0; sub(/^[[:space:]]+-[[:space:]]+/, "", item); sub(/[[:space:]]+#.*$/, "", item); print doc "\titem\t" sect "\t" item; next }
        sect == "decisions" && /^[[:space:]]+[A-Za-z_]+:/ { k=$0; sub(/^[[:space:]]+/, "", k); v=k; sub(/:.*/, "", k); sub(/^[^:]*:[[:space:]]*/, "", v); sub(/[[:space:]]+#.*$/, "", v); print doc "\tdec\t" k "\t" v; next }
        { print doc "\tother\t" sect "\t" $0 }' \
        | jq -Rsc --arg hdr "${hdr:-null}" '
            def unq: if (startswith("\"") and endswith("\"")) or (startswith("'"'"'") and endswith("'"'"'")) then .[1:-1] else . end;
            [ split("\n")[] | select(length > 0) | split("\t") ] as $rows
            | ([ $rows[] | .[0] | tonumber ] | unique) as $docs
            | [ $docs[] | . as $d | ($rows | map(select(.[0] == ($d | tostring)))) as $r
                | { keys: ($r | map(select(.[1] == "key")) | map({key: .[2], value: (.[3] // "")}) ),
                    filters: ($r | map(select(.[1] == "item" and .[2] == "filters")) | map(.[3] | unq)),
                    notifications: ($r | map(select(.[1] == "item" and .[2] == "notifications")) | map(.[3] | unq)),
                    types: ($r | map(select(.[1] == "item" and .[2] == "decisions" and (.[3] | startswith("type:")))) | map(.[3] | sub("^type:[[:space:]]*"; "") | unq)
                             + ($r | map(select(.[1] == "dec" and .[2] == "type")) | map(.[3] | unq))),
                    durations: ($r | map(select(.[1] == "item" and .[2] == "decisions" and (.[3] | startswith("duration:")))) | map(.[3] | sub("^duration:[[:space:]]*"; "") | unq)
                               + ($r | map(select(.[1] == "dec" and .[2] == "duration")) | map(.[3] | unq))),
                    others: ($r | map(select(.[1] == "other" or (.[1] == "dec" and (.[2] != "type" and .[2] != "duration"))))| length) } ] as $p
            | ($p | map(.keys | map(select(.key == "name")) | .[0].value // "" | unq)) as $names
            | ("default_ip_remediation" ) as $ipn | ("default_range_remediation") as $rgn
            | ($p | map(select((.keys | map(select(.key == "name")) | .[0].value // "" | unq) == $ipn)) | .[0]) as $ip
            | ($p | map(select((.keys | map(select(.key == "name")) | .[0].value // "" | unq) == $rgn)) | .[0]) as $rg
            | def keyset: (.keys | map(.key));
              def expr_of: (.keys | map(select(.key == "duration_expr")) | .[0].value // "" | unq);
              def stock_ok($f):
                (.filters == [$f]) and (.types == ["ban"]) and ((.durations | length) == 1) and (.others == 0)
                and ((keyset - ["name", "filters", "decisions", "notifications", "on_success", "duration_expr"]) == [])
                and (((.keys | map(select(.key == "on_success")) | .[0].value // "break") | unq) == "break")
                and ((.notifications - ["http_default"]) == [])
                and ((expr_of == "") or (expr_of | test("^Sprintf\\((\"|'"'"')%dh(\"|'"'"'), \\(GetDecisionsCount\\(Alert\\.GetValue\\(\\)\\) \\+ 1\\) \\* [0-9]+\\)$")));
              ($hdr != "null") as $hasdcs
            | { profiles: $names,
                mode: (if $hasdcs then "dcs"
                       elif ($p | length) >= 1 and ($p | length) <= 2 and (($names - [$ipn, $rgn]) == [])
                            and (if $ip != null then ($ip | stock_ok("Alert.Remediation == true && Alert.GetScope() == \"Ip\"")) else true end)
                            and (if $rg != null then ($rg | stock_ok("Alert.Remediation == true && Alert.GetScope() == \"Range\"")) else true end)
                       then "stock" else "custom" end),
                ip_duration: ($ip.durations[0] // null), range_duration: ($rg.durations[0] // null),
                escalate: ((($ip // {keys: []}) | expr_of) != "" or (($rg // {keys: []}) | expr_of) != ""),
                notified: ($p | map(.notifications | index("http_default") != null) | any),
                header: (if $hasdcs then ($hdr | fromjson? // null) else null end) }'
}

# =============================================================================
# profiles.yaml: the settings, and the file they make
# =============================================================================

_CS_PROFILE_DEFAULTS='{"duration":"4h","range_duration":"4h","escalate":{"enabled":false,"max":"720h"},"overrides":[]}'
_CS_NOTIFY_FILTER_DEFAULTS='{"enabled":true,"events":{"bans":true,"simulated":true,"detect_only":false},"filters":{"min_events":0,"only":[],"ignore":[]}}'

# The settings the live file stands for: DCS's own header, or what the stock/shipped file says. $1 = _cs_profile_inspect JSON
_cs_profile_live_settings() {
    jq -c --argjson d "$_CS_PROFILE_DEFAULTS" '
        if .header != null and (.header.profile // null) != null then ($d * .header.profile)
        else . as $i | $d
             | (if $i.ip_duration != null then .duration = $i.ip_duration else . end)
             | (if $i.range_duration != null then .range_duration = $i.range_duration else . end)
             | (if $i.escalate then .escalate.enabled = true else . end) end' <<< "$1"
}

# _cs_profile_merge BASE PATCH — the patch over the base (escalate merges key by key, overrides are replaced as a list)
_cs_profile_merge() {
    jq -nc --argjson b "$1" --argjson p "$2" '
        $b * ($p | del(.escalate, .overrides))
        | .escalate = (($b.escalate // {}) * ($p.escalate // {}))
        | .overrides = (if ($p | has("overrides")) then $p.overrides else ($b.overrides // []) end)'
}

# _cs_profile_validate JSON — the normalised settings land in CS_OUT (not on stdout: a subshell would lose CS_CFG_ERR); a problem sets CS_CFG_ERR and returns 1
_cs_profile_validate() {
    local j="$1" v secs i n pat dur out
    CS_CFG_ERR=""
    jq -e 'type == "object" and (.escalate | type == "object") and (.overrides | type == "array")' >/dev/null 2>&1 <<< "$j" || { CS_CFG_ERR="The ban profile settings are malformed"; return 1; }
    local d rd
    d=$(_cs_norm_duration "$(jq -r '.duration | tostring' <<< "$j")") || { CS_CFG_ERR="The default ban duration is not valid: use 30m, 4h, 7d or 2w"; return 1; }
    rd=$(jq -r '(.range_duration // .duration) | tostring' <<< "$j")
    rd=$(_cs_norm_duration "$rd") || { CS_CFG_ERR="The range ban duration is not valid: use 30m, 4h, 7d or 2w"; return 1; }
    for v in "$d" "$rd"; do
        secs=$(_cs_duration_seconds "$v")
        (( secs <= CS_MAX_AUTO_SECONDS )) || { CS_CFG_ERR="Automatic bans can last at most a year (365d). Use a manual ban for longer."; return 1; }
    done
    local esc_on esc_max
    esc_on=$(jq -r 'if .escalate.enabled == true then "true" else "false" end' <<< "$j")
    esc_max=$(_cs_norm_duration "$(jq -r '(.escalate.max // "720h") | tostring' <<< "$j")") || { CS_CFG_ERR="The longest repeat-offender ban is not valid: use 7d, 30d or 90d"; return 1; }
    secs=$(_cs_duration_seconds "$esc_max")
    (( secs <= CS_MAX_AUTO_SECONDS )) || { CS_CFG_ERR="The longest repeat-offender ban can be a year (365d) at most"; return 1; }
    n=$(jq '.overrides | length' <<< "$j")
    (( n <= 12 )) || { CS_CFG_ERR="At most 12 scenario overrides"; return 1; }
    local -a ovr=(); local -A seen=()
    for (( i = 0; i < n; i++ )); do
        pat=$(jq -r ".overrides[$i].pattern | tostring" <<< "$j")
        _cs_valid_pattern "$pat" || { CS_CFG_ERR="Override $(( i + 1 )): the scenario \"${pat:0:60}\" is not valid. Use a name like crowdsecurity/ssh-bf or a prefix like crowdsecurity/ssh*"; return 1; }
        [[ -z "${seen[$pat]:-}" ]] || { CS_CFG_ERR="The scenario $pat has two overrides"; return 1; }
        seen[$pat]=1
        dur=$(_cs_norm_duration "$(jq -r ".overrides[$i].duration | tostring" <<< "$j")") || { CS_CFG_ERR="Override $(( i + 1 )) ($pat): the duration is not valid: use 30m, 4h, 7d or 2w"; return 1; }
        secs=$(_cs_duration_seconds "$dur")
        (( secs <= CS_MAX_AUTO_SECONDS )) || { CS_CFG_ERR="Override $(( i + 1 )) ($pat): automatic bans can last at most a year"; return 1; }
        ovr+=("$(jq -nc --arg p "$pat" --arg d "$dur" '{pattern: $p, duration: $d}')")
    done
    if [[ "$esc_on" == true ]]; then
        (( $(_cs_duration_seconds "$esc_max") >= $(_cs_duration_seconds "$d") )) || { CS_CFG_ERR="The longest repeat-offender ban ($esc_max) is shorter than the default ban ($d)"; return 1; }
    fi
    out=$( ( [[ ${#ovr[@]} -gt 0 ]] && printf '%s\n' "${ovr[@]}" || true ) | jq -sc --arg d "$d" --arg rd "$rd" --argjson eo "$esc_on" --arg em "$esc_max" '{duration: $d, range_duration: $rd, escalate: {enabled: $eo, max: $em}, overrides: .}')
    CS_OUT="$out"
}

# The jq that turns (settings, notify) into profiles.yaml. Filters are single-quoted YAML scalars; the header carries the settings.
_CS_JQ_PROFILES='
def sq: "'"'"'" + gsub("'"'"'"; "'"'"''"'"'") + "'"'"'";
def secs($d): ($d | capture("^(?<n>[0-9]+)(?<u>[mh])$") | (.n | tonumber) * (if .u == "h" then 3600 else 60 end));
def scen_match($p): if ($p | endswith("*")) then "Alert.GetScenario() startsWith " + ($p | rtrimstr("*") | @json) else "Alert.GetScenario() == " + ($p | @json) end;
def any_match($ps): "(" + ($ps | map(scen_match(.)) | join(" || ")) + ")";
def dur_expr($d; $max):
  (secs($d)) as $b | (secs($max)) as $m
  | if $b % 3600 == 0 and $m % 3600 == 0
    then "Sprintf(\"%dh\", min((GetDecisionsCount(Alert.GetValue()) + 1) * \($b / 3600), \($m / 3600)))"
    else "Sprintf(\"%ds\", min((GetDecisionsCount(Alert.GetValue()) + 1) * \($b), \($m)))" end;
def emit($name; $cond; $dur; $expr; $notify; $on_success):
  "name: " + $name + "\nfilters:\n  - " + ($cond | sq) + "\ndecisions:\n  - type: ban\n    duration: " + $dur + "\n"
  + (if $expr != "" then "duration_expr: " + ($expr | sq) + "\n" else "" end)
  + (if $notify then "notifications:\n  - http_default\n" else "" end)
  + "on_success: " + $on_success + "\n";
. as $in
| $in.profile as $p | $in.notify as $n | $in.notify_on as $on
| ([ (if ($n.filters.min_events // 0) > 1 then "Alert.GetEventsCount() >= \($n.filters.min_events)" else empty end),
     (if (($n.filters.only // []) | length) > 0 then any_match($n.filters.only) else empty end),
     (if (($n.filters.ignore // []) | length) > 0 then "!" + any_match($n.filters.ignore) else empty end) ]) as $base_nf
| ($base_nf + (if $n.events.simulated == false then ["(Alert.Simulated == nil || !Alert.Simulated)"] else [] end) | join(" && ")) as $nf
| ($base_nf | join(" && ")) as $nf_detect
| [ ($p.overrides // [])[] | . as $o | {name: ("dcs_override_" + (($p.overrides | map(.pattern) | index($o.pattern)) + 1 | tostring)), cond: ("Alert.Remediation == true && " + scen_match($o.pattern)), dur: $o.duration} ]
  + [ {name: "default_ip_remediation", cond: "Alert.Remediation == true && Alert.GetScope() == \"Ip\"", dur: $p.duration},
      {name: "default_range_remediation", cond: "Alert.Remediation == true && Alert.GetScope() == \"Range\"", dur: $p.range_duration} ] as $groups
| [ $groups[] | . as $g
    | (if $p.escalate.enabled then dur_expr($g.dur; $p.escalate.max) else "" end) as $expr
    | if $on and ($n.events.bans != false) then
        (if $nf != "" then emit($g.name + "_notify"; $g.cond + " && " + $nf; $g.dur; $expr; true; "break") + "---\n" + emit($g.name; $g.cond; $g.dur; $expr; false; "break")
         else emit($g.name; $g.cond; $g.dur; $expr; true; "break") end)
      else emit($g.name; $g.cond; $g.dur; $expr; false; "break") end ] as $blocks
| ($blocks + (if $on and ($n.events.detect_only == true) then
      ["name: dcs_notify_detect_only\nfilters:\n  - " + (("Alert.Remediation == false" + (if $nf_detect != "" then " && " + $nf_detect else "" end)) | sq) + "\nnotifications:\n  - http_default\non_success: continue\n"] else [] end)) as $all
| "# Managed by DCS: the CrowdSec page writes this file (Settings and Discord tabs). Change it there; a backup of the previous file is kept.\n"
  + "# dcs-settings: " + ({v: 1, profile: $p, notify: {enabled: $n.enabled, events: $n.events, filters: $n.filters}} | tojson) + "\n"
  + ($all | join("---\n"))
'

# _cs_profiles_render PROFILE_JSON NOTIFY_JSON NOTIFY_ON(true|false) — the profiles.yaml text
_cs_profiles_render() {
    jq -nc --argjson profile "$1" --argjson notify "$2" --argjson notify_on "$3" '{profile: $profile, notify: $notify, notify_on: $notify_on}' \
        | jq -j "$_CS_JQ_PROFILES"
}

# =============================================================================
# Trying a candidate before it goes live
# =============================================================================

# _cs_validate_candidates PROFILES_TEXT HTTP_TEXT — CrowdSec's own verdict on candidate files, in a scratch directory of the container.
# PROFILES_TEXT / HTTP_TEXT may be empty (that file is unchanged). Sets CS_CFG_ERR and returns 1 when CrowdSec would not accept them.
_cs_validate_candidates() {
    local prof="$1" http="$2" tmp out rc cfg="/tmp/dcs-vtest"
    CS_CFG_ERR=""
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/dcs-cs-val.XXXXXX") || { CS_CFG_ERR="no temporary directory"; return 1; }
    # two plain commands, never a shell string
    { timeout 10 docker exec "$CS_NAME" rm -rf "$cfg" && timeout 10 docker exec "$CS_NAME" mkdir -p "$cfg/notifications"; } >/dev/null 2>&1 </dev/null || { CS_CFG_ERR="could not prepare a scratch directory in the container"; rm -rf "$tmp"; return 1; }
    local live_cfg
    live_cfg=$(_cs_live_file /etc/crowdsec/config.yaml)
    [[ -n "$live_cfg" ]] || { CS_CFG_ERR="could not read CrowdSec's config.yaml"; rm -rf "$tmp"; return 1; }
    [[ -n "$prof" ]] || prof=$(_cs_live_file "$CS_PROFILES_PATH")
    printf '%s\n' "$prof" > "$tmp/profiles.yaml"
    printf '%s\n' "$live_cfg" | sed -e "s#^\([[:space:]]*profiles_path:\).*#\1 $cfg/profiles.yaml#" -e "s#^\([[:space:]]*notification_dir:\).*#\1 $cfg/notifications/#" > "$tmp/config.yaml"
    # the other plugin files stay as they are; the candidate http.yaml points at a dead address with short timeouts (a dry run must never post anything)
    local f
    while IFS= read -r f; do
        [[ "$f" == http.yaml ]] && continue
        [[ "$f" =~ ^[a-z_]+\.yaml$ ]] || continue
        _cs_live_file "/etc/crowdsec/notifications/$f" > "$tmp/notifications-$f"
        timeout 10 docker cp "$tmp/notifications-$f" "$CS_NAME:$cfg/notifications/$f" >/dev/null 2>&1 || true
    done < <(timeout 10 docker exec "$CS_NAME" ls -1 /etc/crowdsec/notifications 2>/dev/null </dev/null)
    if [[ -z "$http" ]]; then http=$(_cs_live_file "$CS_HTTP_PATH"); fi
    if [[ -n "$http" ]]; then
        printf '%s\n' "$http" | sed -e 's#^url:.*#url: http://127.0.0.1:9/dcs-validate#' -e 's#^max_retry:.*#max_retry: 1#' -e 's#^timeout:.*#timeout: 2s#' -e '/^group_wait:/d' -e 's#^group_threshold:.*#group_threshold: 1#' > "$tmp/http.yaml"
        timeout 10 docker cp "$tmp/http.yaml" "$CS_NAME:$cfg/notifications/http.yaml" >/dev/null 2>&1 || { CS_CFG_ERR="could not stage the notification file"; rm -rf "$tmp"; return 1; }
    fi
    timeout 10 docker cp "$tmp/profiles.yaml" "$CS_NAME:$cfg/profiles.yaml" >/dev/null 2>&1 || { CS_CFG_ERR="could not stage the profiles file"; rm -rf "$tmp"; return 1; }
    timeout 10 docker cp "$tmp/config.yaml" "$CS_NAME:$cfg/config.yaml" >/dev/null 2>&1 || { CS_CFG_ERR="could not stage the test configuration"; rm -rf "$tmp"; return 1; }
    out=$(timeout 60 docker exec "$CS_NAME" crowdsec -t -c "$cfg/config.yaml" 2>&1 </dev/null); rc=$?
    if (( rc != 0 )); then
        CS_CFG_ERR=$(printf '%s\n' "$out" | grep -E 'level=(fatal|error)' | tail -n 1 | sed -e 's/.*msg="//' -e 's/"[^"]*$//' -e 's/\\"/"/g' -e 's/\\n.*//' | cut -c1-400)
        [[ -n "$CS_CFG_ERR" ]] || CS_CFG_ERR="CrowdSec's configuration test failed"
        CS_CFG_ERR="CrowdSec would not accept the profiles: $CS_CFG_ERR"
    elif [[ -n "$http" ]] && grep -q '^type: http' <<< "$http"; then
        # The plugin dry run. A template that does not compile is reported as "format alerts for notification"; one that does is seen
        # trying the (dead) address. cscli sometimes leaves before the plugin has said either, so an unclear run is repeated.
        local verdict=""
        for _ in 1 2 3 4; do
            out=$(timeout 60 docker exec "$CS_NAME" cscli -c "$cfg/config.yaml" notifications test http_default 2>&1 </dev/null)
            if grep -q 'format alerts for notification' <<< "$out"; then
                CS_CFG_ERR="The Discord message template does not compile: $(printf '%s\n' "$out" | grep 'format alerts for notification' | head -n 1 | sed -e 's/.*format alerts for notification: //' -e 's/ plugin:=.*//' -e 's/"$//' | cut -c1-300)"
                verdict=bad; break
            elif grep -qE 'Failed to make HTTP request|connection refused|non 200 status|delivery failed|notify attempt failed' <<< "$out"; then
                verdict=good; break
            fi
            sleep 1
        done
        if [[ "$verdict" == bad ]]; then rc=1
        elif [[ "$verdict" != good ]]; then CS_CFG_ERR="Could not verify the Discord message template (the notification plugin did not answer)"; rc=1; fi
    fi
    timeout 10 docker exec "$CS_NAME" rm -rf "$cfg" >/dev/null 2>&1 </dev/null
    rm -rf "$tmp"
    return $(( rc != 0 ))
}

# =============================================================================
# Putting a candidate live: back up, write, restart, watch, roll back
# =============================================================================

# _cs_wait_healthy SECONDS — 0 when the container is running, healthy and the local API answers
_cs_wait_healthy() {
    local limit="${1:-90}" i st out
    for (( i = 0; i < limit; i += 2 )); do
        st=$(timeout 8 docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CS_NAME" 2>/dev/null </dev/null)
        if [[ "$st" == "running|healthy" || "$st" == "running|none" ]]; then
            if _cs_run out lapi status; then return 0; fi
        fi
        sleep 2
    done
    return 1
}

# keep the newest N backups of one kind
_cs_prune_backups() {
    local kind="$1" keep="${2:-10}" f i=0
    while IFS= read -r f; do
        i=$(( i + 1 ))
        (( i > keep )) && rm -f "$f"
    done < <(ls -1t "$CS_BACKUP_DIR/$kind"-*.yaml 2>/dev/null)
}

# _cs_copy_in TEXT DEST MODE — write TEXT to DEST inside the container (docker cp of a private temp file)
_cs_copy_in() {
    local text="$1" dest="$2" mode="$3" tmp rc
    tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/dcs-cs-cp.XXXXXX") || return 1
    printf '%s\n' "$text" > "$tmp"; chmod "$mode" "$tmp"
    timeout 20 docker cp "$tmp" "$CS_NAME:$dest" >/dev/null 2>&1; rc=$?
    rm -f "$tmp"
    return $rc
}

# The locked part of _cs_config_apply
CS_APPLY_MSG=""; CS_APPLY_CHANGED=0; CS_APPLY_ROLLED_BACK=0; CS_APPLY_BACKUP=""
_cs_config_apply_locked() {
    local prof="$1" http="$2" live_p live_h cp=0 ch=0 ts hexist=0 pexist=0 failed=""
    CS_APPLY_MSG=""; CS_APPLY_CHANGED=0; CS_APPLY_ROLLED_BACK=0; CS_APPLY_BACKUP=""
    live_p=$(_cs_live_file "$CS_PROFILES_PATH"); live_h=$(_cs_live_file "$CS_HTTP_PATH")
    [[ -n "$live_p" ]] && pexist=1; [[ -n "$live_h" ]] && hexist=1
    if [[ -n "$prof" && "$prof" != "$live_p" ]]; then cp=1; else prof=""; fi
    if [[ -n "$http" && "$http" != "$live_h" ]]; then ch=1; else http=""; fi
    if (( cp + ch == 0 )); then CS_APPLY_MSG="CrowdSec already has these settings"; return 0; fi
    # CrowdSec's own verdict first: nothing is touched when it says no
    if ! _cs_validate_candidates "$prof" "$http"; then CS_APPLY_MSG="$CS_CFG_ERR"; return 4; fi
    # the way back
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    mkdir -p "$CS_BACKUP_DIR" && chmod 700 "$CS_BACKUP_DIR" 2>/dev/null
    (( cp )) && [[ $pexist == 1 ]] && { printf '%s\n' "$live_p" > "$CS_BACKUP_DIR/profiles-$ts.yaml"; chmod 600 "$CS_BACKUP_DIR/profiles-$ts.yaml"; CS_APPLY_BACKUP="profiles-$ts.yaml"; }
    (( ch )) && [[ $hexist == 1 ]] && { printf '%s\n' "$live_h" > "$CS_BACKUP_DIR/http-$ts.yaml"; chmod 600 "$CS_BACKUP_DIR/http-$ts.yaml"; }
    # write, restart, watch
    if (( cp )); then _cs_copy_in "$prof" "$CS_PROFILES_PATH" 644 || failed="could not write $CS_PROFILES_PATH"; fi
    if [[ -z "$failed" ]] && (( ch )); then _cs_copy_in "$http" "$CS_HTTP_PATH" 600 || failed="could not write $CS_HTTP_PATH"; fi
    if [[ -z "$failed" ]]; then
        timeout 120 docker restart "$CS_NAME" >/dev/null 2>&1 </dev/null || failed="docker could not restart the container"
    fi
    if [[ -z "$failed" ]] && ! _cs_wait_healthy 90; then failed="CrowdSec did not come back healthy within 90 seconds"; fi
    if [[ -z "$failed" ]]; then
        # the files must read back exactly as written, and the notification plugin must have picked http.yaml up
        if (( cp )) && [[ "$(_cs_live_file "$CS_PROFILES_PATH")" != "$prof" ]]; then failed="the profiles file did not read back as written"; fi
        if [[ -z "$failed" ]] && (( ch )) && [[ "$(_cs_live_file "$CS_HTTP_PATH")" != "$http" ]]; then failed="the notification file did not read back as written"; fi
    fi
    if [[ -z "$failed" ]]; then CS_APPLY_CHANGED=1; CS_APPLY_MSG="Applied. CrowdSec restarted and is healthy."; return 0; fi
    # something went wrong: put the old files back and restart once more
    local log; log=$(_cs_log_tail 6 | tr '\n' ' ' | cut -c1-500)
    (( cp )) && { if [[ $pexist == 1 ]]; then _cs_copy_in "$live_p" "$CS_PROFILES_PATH" 644; else timeout 10 docker exec "$CS_NAME" rm -f "$CS_PROFILES_PATH" >/dev/null 2>&1; fi; }
    (( ch )) && { if [[ $hexist == 1 ]]; then _cs_copy_in "$live_h" "$CS_HTTP_PATH" 600; else timeout 10 docker exec "$CS_NAME" rm -f "$CS_HTTP_PATH" >/dev/null 2>&1; fi; }
    timeout 120 docker restart "$CS_NAME" >/dev/null 2>&1 </dev/null
    if _cs_wait_healthy 90; then
        CS_APPLY_ROLLED_BACK=1; CS_APPLY_MSG="$failed. The previous files are back and CrowdSec is healthy again.${log:+ Log: $log}"; return 5
    fi
    CS_APPLY_MSG="$failed, and CrowdSec did not come back after the previous files were restored. Look at the log on the CrowdSec page.${log:+ Log: $log}"
    return 6
}

# _cs_config_apply PROFILES_TEXT HTTP_TEXT — see above. Returns 0 ok · 3 busy · 4 CrowdSec rejected the files (nothing changed) · 5 failed, rolled back · 6 failed, could not roll back
_cs_config_apply() {
    local rc
    mkdir -p "$CROWDSEC_STATE_DIR" 2>/dev/null
    {
        flock -w 8 9 || { CS_APPLY_MSG="Another CrowdSec configuration change is running. Try again in a minute."; return 3; }
        _cs_config_apply_locked "$1" "$2"; rc=$?
    } 9>"$CROWDSEC_STATE_DIR/apply.lock"
    _cs_cache_clear
    return $rc
}

# the HTTP status a failed apply maps to
_cs_apply_http() { case "$1" in 3) echo 409 ;; 4) echo 422 ;; *) echo 502 ;; esac; }
# _cs_fail CODE MESSAGE [EXTRA_JSON] — record an error for the caller to send (returns 1)
CS_ERR_CODE=500; CS_ERR_BODY=""
_cs_fail() {
    local extra="${3:-}"; [[ -n "$extra" ]] || extra='{}'
    CS_ERR_CODE="$1"
    CS_ERR_BODY=$(jq -nc --arg m "$2" --argjson c "$1" --argjson x "$extra" '{error: true, code: $c, message: $m} + $x')
    return 1
}
# _cs_apply_error RC — record the failure of a _cs_config_apply (returns 1)
_cs_apply_error() {
    local rc="$1"
    _cs_fail "$(_cs_apply_http "$rc")" "$CS_APPLY_MSG" "$(jq -nc --argjson rb "$CS_APPLY_ROLLED_BACK" --argjson rc "$rc" '{rolled_back: ($rb == 1), stage: (if $rc == 4 then "validation" elif $rc == 3 then "busy" else "apply" end)}')"
}
_cs_apply_fail() { _cs_apply_error "$1"; _api_response "$CS_ERR_CODE" "$CS_ERR_BODY"; }

# GET-side view of the backups DCS kept: [{name, kind, created_at, size}]
_cs_backups_json() {
    local f name kind ts
    [[ -d "$CS_BACKUP_DIR" ]] || { printf '[]'; return; }
    for f in "$CS_BACKUP_DIR"/profiles-*.yaml "$CS_BACKUP_DIR"/http-*.yaml; do
        [[ -f "$f" ]] || continue
        name="${f##*/}"; kind="${name%%-*}"; ts="${name#*-}"; ts="${ts%.yaml}"
        jq -nc --arg n "$name" --arg k "$kind" --arg t "$ts" --argjson s "$(stat -c %s "$f" 2>/dev/null || echo 0)" '{name: $n, kind: $k, created_at: ($t | sub("^(?<d>[0-9]{4})(?<m>[0-9]{2})(?<dd>[0-9]{2})T(?<h>[0-9]{2})(?<mi>[0-9]{2})(?<s>[0-9]{2})Z$"; "\(.d)-\(.m)-\(.dd)T\(.h):\(.mi):\(.s)Z")), size: $s}'
    done | jq -sc 'sort_by(.created_at) | reverse | .[0:20]'
}

# =============================================================================
# Discord notifications: the settings
# =============================================================================

# What an untouched install sends (the same message as the shipped notifications-discord.yaml)
_CS_NOTIFY_DEFAULTS='{
 "v": 1, "enabled": true,
 "webhook": {"mode": "global"},
 "identity": {"name": "CrowdSec", "avatar_url": "https://raw.githubusercontent.com/scotthowson/Docker-Compose-Skeleton-UI/v2.0.0/brand/discord/crowdsec-avatar.png"},
 "embed": {"color_mode": "auto", "color": "#e11d48"},
 "mention": {"mode": "none", "id": "", "text": ""},
 "events": {"bans": true, "simulated": true, "detect_only": false},
 "filters": {"min_events": 0, "only": [], "ignore": []},
 "delivery": {"group_wait": 5, "group_threshold": 10, "max_retry": 3, "timeout": 10},
 "message": {
   "title": "🛡️ {label}",
   "description": "**{ip}**{country_tag}{as_tag}\n{events} hits → **{decision}**{for_duration}{target_tag}",
   "footer": "CrowdSec · {domain}{machine_tag}",
   "link": "{cti_url}",
   "timestamp": false,
   "fields": [
     {"name": "Scenario", "value": "`{scenario_short}`", "inline": true},
     {"name": "Scope", "value": "{scope}{origin_tag}", "inline": true},
     {"name": "Lookup", "value": "[CrowdSec CTI]({cti_url}) · [AbuseIPDB]({abuseipdb_url})", "inline": true},
     {"name": "First request", "value": "{path_code}", "inline": false}
   ]
 }
}'

# The placeholders a message may use: name, group, meaning, an example. Anything else in braces is refused.
_CS_PLACEHOLDERS='[
 {"name":"ip","group":"Source","label":"Address","example":"89.248.165.10","description":"The address (or network) that was banned."},
 {"name":"scope","group":"Source","label":"Scope","example":"Ip","description":"Ip for a single address, Range for a network."},
 {"name":"range","group":"Source","label":"Network","example":"89.248.165.0/24","description":"The network the address belongs to (empty when unknown)."},
 {"name":"country","group":"Source","label":"Country code","example":"NL","description":"Two-letter country code (empty when unknown)."},
 {"name":"flag","group":"Source","label":"Flag","example":":flag_nl:","description":"The Discord flag emoji of the country (empty when unknown)."},
 {"name":"country_tag","group":"Source","label":"Flag and country","example":" :flag_nl: NL","description":"Flag and code with a space in front; empty when the country is unknown, so no stray separators."},
 {"name":"as_number","group":"Source","label":"AS number","example":"202425","description":"Autonomous system number (empty when unknown)."},
 {"name":"as_name","group":"Source","label":"Network name","example":"IP Volume inc","description":"Who runs the network the address is in (empty when unknown)."},
 {"name":"as_tag","group":"Source","label":"Network name (with separator)","example":" · IP Volume inc","description":"The network name with a dot in front; empty when unknown."},
 {"name":"scenario","group":"Detection","label":"Scenario","example":"crowdsecurity/http-probing","description":"The full scenario name."},
 {"name":"scenario_short","group":"Detection","label":"Scenario (short)","example":"http-probing","description":"The scenario without the crowdsecurity/ prefix."},
 {"name":"label","group":"Detection","label":"Attack type","example":"Web probing","description":"The scenario in plain words (SSH brute force, Exploit attempt, Web probing …)."},
 {"name":"events","group":"Detection","label":"Events","example":"13","description":"How many log lines added up to the detection."},
 {"name":"alert_id","group":"Detection","label":"Alert id","example":"42","description":"CrowdSec'"'"'s alert number (see the Alerts tab)."},
 {"name":"message","group":"Detection","label":"CrowdSec message","example":"Ip 89.248.165.10 performed crowdsecurity/http-probing (13 events over 4s)","description":"CrowdSec'"'"'s own one-line summary of the alert."},
 {"name":"sim_tag","group":"Detection","label":"Simulation marker","example":" (simulation)","description":"\" (simulation)\" when the scenario only alerts without banning; empty otherwise."},
 {"name":"decision","group":"Decision","label":"Decision","example":"ban","description":"What was decided: ban (or simulated ban when the scenario is in simulation mode)."},
 {"name":"duration","group":"Decision","label":"Duration","example":"4h","description":"How long the ban lasts (empty when there is no decision)."},
 {"name":"for_duration","group":"Decision","label":"\"for 4h\"","example":" for 4h","description":"\" for <duration>\", empty when there is none."},
 {"name":"origin","group":"Decision","label":"Origin","example":"crowdsec","description":"Where the decision came from: crowdsec (a detection) or cscli (a manual ban)."},
 {"name":"origin_tag","group":"Decision","label":"Origin (with separator)","example":" · crowdsec","description":"The origin with a dot in front; empty when unknown."},
 {"name":"target","group":"Request","label":"Host attacked","example":"app.example.com","description":"The site the first request was aimed at (from Traefik'"'"'s log; empty otherwise)."},
 {"name":"target_tag","group":"Request","label":"\"aimed at …\"","example":" · aimed at **app.example.com**","description":"\" · aimed at <site>\", empty when unknown."},
 {"name":"path","group":"Request","label":"First request path","example":"/wp-login.php","description":"The path of the first request (empty for non-web detections)."},
 {"name":"path_code","group":"Request","label":"First request path (as code)","example":"`/wp-login.php`","description":"The path between backticks so Discord shows it as code; empty (so the field is left out) when there is none."},
 {"name":"user_agent","group":"Request","label":"User agent","example":"Mozilla/5.0 (compatible; scanner/1.0)","description":"The user agent of the first request (empty when unknown)."},
 {"name":"machine","group":"Where and when","label":"Engine","example":"localhost","description":"The CrowdSec engine that raised the alert."},
 {"name":"machine_tag","group":"Where and when","label":"Engine (with separator)","example":" · localhost","description":"The engine with a dot in front; empty when unknown."},
 {"name":"domain","group":"Where and when","label":"Your domain","example":"example.com","description":"Your DCS domain (or DCS when none is set)."},
 {"name":"server","group":"Where and when","label":"Server name","example":"home-server","description":"The name of this DCS server."},
 {"name":"time","group":"Where and when","label":"Time","example":"<t:1790705765:R>","description":"Discord'"'"'s live \"x minutes ago\" stamp of when the message was made (works in the description and in fields, not in the title)."},
 {"name":"cti_url","group":"Links","label":"CrowdSec CTI link","example":"https://app.crowdsec.net/cti/89.248.165.10","description":"The address'"'"'s page on CrowdSec'"'"'s threat intelligence."},
 {"name":"abuseipdb_url","group":"Links","label":"AbuseIPDB link","example":"https://www.abuseipdb.com/check/89.248.165.10","description":"The address'"'"'s page on AbuseIPDB."}
]'

# Sample alerts, in the shape CrowdSec hands a notification plugin (and cscli alerts inspect -d prints)
_CS_NOTIFY_SAMPLES='{
 "probe": {"id": 42, "scenario": "crowdsecurity/http-probing", "message": "Ip 89.248.165.10 performed crowdsecurity/http-probing (13 events over 4s)", "events_count": 13, "machine_id": "localhost", "kind": "crowdsec", "simulated": false,
   "source": {"scope": "Ip", "value": "89.248.165.10", "ip": "89.248.165.10", "range": "89.248.165.0/24", "cn": "NL", "as_number": "202425", "as_name": "IP Volume inc"},
   "decisions": [{"type": "ban", "duration": "4h", "origin": "crowdsec", "simulated": false}],
   "events": [{"meta": [{"key": "target_fqdn", "value": "app.example.com"}, {"key": "http_path", "value": "/wp-login.php"}, {"key": "http_user_agent", "value": "Mozilla/5.0 (compatible; scanner/1.0)"}]}]},
 "ssh": {"id": 43, "scenario": "crowdsecurity/ssh-bf", "message": "Ip 61.177.172.128 performed crowdsecurity/ssh-bf (6 events over 19s)", "events_count": 6, "machine_id": "localhost", "kind": "crowdsec", "simulated": false,
   "source": {"scope": "Ip", "value": "61.177.172.128", "ip": "61.177.172.128", "range": "61.177.172.0/24", "cn": "CN", "as_number": "4134", "as_name": "CHINANET-BACKBONE"},
   "decisions": [{"type": "ban", "duration": "4h", "origin": "crowdsec", "simulated": false}], "events": []},
 "exploit": {"id": 44, "scenario": "crowdsecurity/CVE-2017-9841", "message": "Ip 194.26.135.7 performed crowdsecurity/CVE-2017-9841 (1 events over 0s)", "events_count": 1, "machine_id": "localhost", "kind": "crowdsec", "simulated": false,
   "source": {"scope": "Ip", "value": "194.26.135.7", "ip": "194.26.135.7", "range": "194.26.135.0/24", "cn": "RU", "as_number": "216368", "as_name": "Petersburg Internet Network ltd."},
   "decisions": [{"type": "ban", "duration": "4h", "origin": "crowdsec", "simulated": false}],
   "events": [{"meta": [{"key": "target_fqdn", "value": "cloud.example.com"}, {"key": "http_path", "value": "/vendor/phpunit/phpunit/src/Util/PHP/eval-stdin.php"}, {"key": "http_user_agent", "value": "python-requests/2.28"}]}]},
 "manual": {"id": 45, "scenario": "Banned from DCS by admin", "message": "", "events_count": 1, "machine_id": "localhost", "kind": "cscli", "simulated": false,
   "source": {"scope": "Ip", "value": "198.51.100.7", "ip": "198.51.100.7", "range": "", "cn": "", "as_number": "", "as_name": ""},
   "decisions": [{"type": "ban", "duration": "24h", "origin": "cscli", "simulated": false}], "events": []},
 "simulated": {"id": 46, "scenario": "crowdsecurity/http-crawl-non_statics", "message": "Ip 185.220.101.5 performed crowdsecurity/http-crawl-non_statics (40 events over 9s)", "events_count": 40, "machine_id": "localhost", "kind": "crowdsec", "simulated": true,
   "source": {"scope": "Ip", "value": "185.220.101.5", "ip": "185.220.101.5", "range": "185.220.101.0/24", "cn": "DE", "as_number": "60729", "as_name": "Stiftung Erneuerbare Freiheit"},
   "decisions": [{"type": "ban", "duration": "4h", "origin": "crowdsec", "simulated": true}],
   "events": [{"meta": [{"key": "target_fqdn", "value": "app.example.com"}, {"key": "http_path", "value": "/"}]}]}
}'

# The validation, in jq: prints the normalised settings, or {"error": "…"}
_CS_JQ_NOTIFY_VALIDATE='
def bad($m): error($m);
def num($v; $lo; $hi; $what): (if ($v | type) == "string" and ($v | test("^[0-9]+$")) then ($v | tonumber) else $v end) as $n
  | if ($n | type) == "number" and $n == ($n | floor) and $n >= $lo and $n <= $hi then $n else bad($what + " must be a whole number from " + ($lo | tostring) + " to " + ($hi | tostring)) end;
def oneline($s; $what; $max): if ($s | type) != "string" then bad($what + " must be text")
  elif ($s | test("[\\x00-\\x1f\\x7f]")) then bad($what + " must be a single line without control characters")
  elif ($s | length) > $max then bad($what + " is too long (" + ($max | tostring) + " characters at most)") else $s end;
def multiline($s; $what; $max): if ($s | type) != "string" then bad($what + " must be text")
  elif ($s | test("[\\x00-\\x08\\x0b\\x0c\\x0e-\\x1f\\x7f]")) then bad($what + " must not contain control characters")
  elif ($s | length) > $max then bad($what + " is too long (" + ($max | tostring) + " characters at most)") else $s end;
def placeholders($s): [ $s | match("\\{([A-Za-z0-9_]+)\\}"; "g") | .captures[0].string ];
def check_ph($s; $what): (placeholders($s) - $known) as $u | if ($u | length) > 0 then bad($what + " uses {" + $u[0] + "}, which is not a placeholder. Pick one from the list.") else $s end;
def pattern_ok: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._/@:+-]{0,119}\\*?$");
. as $s
| try (
    if ($s.enabled | type) != "boolean" then bad("enabled must be true or false") else . end
    | if (["global", "custom", "keep"] | index($s.webhook.mode)) == null then bad("The webhook source must be global, custom or keep") else . end
    | (oneline($s.identity.name; "The sender name"; 80)) as $name
    | if ($name | length) < 1 then bad("The sender name is empty") elif ($name | test("discord|clyde|[@#:]|```"; "i")) then bad("Discord refuses sender names that contain \"discord\", \"clyde\", @, # or :") else . end
    | if ($s.identity.avatar_url | type) != "string" or ($s.identity.avatar_url != "" and ($s.identity.avatar_url | test("^https://[^\\s\"\\\\<>]{1,300}$") | not)) then bad("The avatar must be an https:// address (or empty)") else . end
    | if (["auto", "fixed"] | index($s.embed.color_mode)) == null then bad("The colour mode must be auto or fixed") else . end
    | if ($s.embed.color | type) != "string" or ($s.embed.color | test("^#[0-9a-fA-F]{6}$") | not) then bad("The colour must look like #e11d48") else . end
    | if (["none", "role", "user", "here", "everyone"] | index($s.mention.mode)) == null then bad("The mention must be none, role, user, here or everyone") else . end
    | if (($s.mention.mode == "role" or $s.mention.mode == "user") and (($s.mention.id | tostring) | test("^[0-9]{15,21}$") | not)) then bad("The role or user id is the long number Discord shows in developer mode (17-19 digits)") else . end
    | multiline(($s.mention.text | tostring); "The text next to the mention"; 300) as $mt
    | if ([$s.events.bans, $s.events.simulated, $s.events.detect_only] | map(type == "boolean") | all | not) then bad("The event switches must be true or false") else . end
    | num($s.filters.min_events; 0; 1000; "The minimum number of events") as $me
    | if ([$s.filters.only, $s.filters.ignore] | map(type == "array" and length <= 20 and all(.[]; pattern_ok)) | all | not) then bad("The scenario lists take up to 20 names such as crowdsecurity/ssh-bf or a prefix such as crowdsecurity/ssh*") else . end
    | num($s.delivery.group_wait; 1; 600; "The grouping wait (seconds)") as $gw
    | num($s.delivery.group_threshold; 1; 10; "The group size (Discord shows at most 10 embeds in a message)") as $gt
    | num($s.delivery.max_retry; 0; 10; "The number of retries") as $mr
    | num($s.delivery.timeout; 1; 60; "The request timeout (seconds)") as $to
    | oneline($s.message.title; "The title"; 200) as $title | check_ph($title; "The title") as $_t
    | multiline($s.message.description; "The description"; 1500) as $desc | check_ph($desc; "The description") as $_d
    | oneline($s.message.footer; "The footer"; 200) as $footer | check_ph($footer; "The footer") as $_f
    | oneline($s.message.link; "The title link"; 300) as $link | check_ph($link; "The title link") as $_l
    | if ($s.message.timestamp | type) != "boolean" then bad("timestamp must be true or false") else . end
    | if ($s.message.fields | type) != "array" or ($s.message.fields | length) > 8 then bad("A message has up to 8 fields") else . end
    | ($s.message.fields | to_entries | map(
          .key as $i | .value as $f
          | if ($f | type) != "object" then bad("Field " + (($i + 1) | tostring) + " is malformed") else . end
          | oneline($f.name; "Field " + (($i + 1) | tostring) + " name"; 100) as $fn
          | multiline($f.value; "Field " + (($i + 1) | tostring) + " value"; 500) as $fv
          | if ($fn | length) == 0 or ($fv | length) == 0 then bad("Field " + (($i + 1) | tostring) + " needs a name and a value (empty fields are left out of the message)") else . end
          | check_ph($fn; "Field " + (($i + 1) | tostring) + " name") | check_ph($fv; "Field " + (($i + 1) | tostring) + " value")
          | {name: $fn, value: $fv, inline: ($f.inline == true)} )) as $fields
    | if ($title | length) == 0 and ($desc | length) == 0 and ($fields | length) == 0 then bad("The message would be empty: give it a title, a description or a field") else . end
    | {v: 1, enabled: $s.enabled, webhook: {mode: $s.webhook.mode}, identity: {name: $name, avatar_url: $s.identity.avatar_url},
       embed: {color_mode: $s.embed.color_mode, color: ($s.embed.color | ascii_downcase)}, mention: {mode: $s.mention.mode, id: (if ($s.mention.mode == "role" or $s.mention.mode == "user") then ($s.mention.id | tostring) else "" end), text: $mt},
       events: {bans: $s.events.bans, simulated: $s.events.simulated, detect_only: $s.events.detect_only},
       filters: {min_events: $me, only: ($s.filters.only | unique), ignore: ($s.filters.ignore | unique)},
       delivery: {group_wait: $gw, group_threshold: $gt, max_retry: $mr, timeout: $to},
       message: {title: $title, description: $desc, footer: $footer, link: $link, timestamp: $s.message.timestamp, fields: $fields}}
  ) catch {error: (if type == "string" then . else "The notification settings are not valid" end)}
'

# _cs_notify_merge BASE PATCH — the patch over the base, section by section (lists are replaced whole)
_cs_notify_merge() { jq -nc --argjson b "$1" --argjson p "$2" '$b * $p'; }

# _cs_notify_validate JSON — the normalised settings land in CS_OUT, or CS_CFG_ERR is set and the status is 1. The known placeholders are the ones in the table.
_cs_notify_validate() {
    local out
    out=$(jq -c --argjson known "$(jq -c 'map(.name)' <<< "$_CS_PLACEHOLDERS")" "$_CS_JQ_NOTIFY_VALIDATE" <<< "$1" 2>&1) || { CS_CFG_ERR="The notification settings could not be checked"; return 1; }
    if jq -e 'type == "object" and has("error")' >/dev/null 2>&1 <<< "$out"; then CS_CFG_ERR=$(jq -r '.error' <<< "$out"); return 1; fi
    CS_OUT="$out"
}

# The settings in force: the defaults, then what was saved. (Without a saved file the live state decides, see _cs_notify_effective.)
_cs_notify_saved() { _cs_notify_merge "$_CS_NOTIFY_DEFAULTS" "$(_cs_json_file "$CS_NOTIFY_FILE" '{}')"; }

# =============================================================================
# The webhook: never shown in full
# =============================================================================

# …/api/webhooks/<id>/<token> → …/api/webhooks/<id>/••••<last four of the token>
_cs_webhook_mask() {
    local u="$1" id tok
    [[ "$u" =~ ^(https://[a-z.]*discord(app)?\.com/api/webhooks/)([0-9]+)/([A-Za-z0-9_-]+)$ ]] || { [[ -n "$u" ]] && printf '(a webhook)'; return; }
    id="${BASH_REMATCH[3]}"; tok="${BASH_REMATCH[4]}"
    printf '%s%s/••••%s' "${BASH_REMATCH[1]}" "$id" "${tok: -4}"
}

# the URL CrowdSec posts to right now (from the live file); empty when there is none
_cs_webhook_live() { _cs_live_file "$CS_HTTP_PATH" | sed -n 's/^url:[[:space:]]*//p' | head -n 1 | tr -d '"'"'"' \r'; }

# _cs_webhook_resolve MODE — the URL that mode stands for (secret: keep it out of answers and logs)
_cs_webhook_resolve() {
    local mode="$1" u=""
    case "$mode" in
        custom) u=$(secrets_get "$CS_WEBHOOK_SECRET" 2>/dev/null) || u="" ;;
        global) u=$(_discord_webhook 2>/dev/null) || u="" ;;
        keep) u=$(_cs_webhook_live) ;;
    esac
    [[ "$u" =~ ^\$\{SECRETS[._]([A-Za-z_][A-Za-z0-9_]*)\}$ ]] && u=$(secrets_get "${BASH_REMATCH[1]}" 2>/dev/null)
    _discord_is_webhook "$u" && printf '%s' "$u"
    return 0
}

# =============================================================================
# Discord notifications: the Go template CrowdSec's http plugin renders
#
# The message is built from the settings by concatenation: text you typed only
# ever becomes a Go *string literal* (never template code), the placeholders
# become variables, and every value goes through toJson — so a quote or a brace
# in an attacker's user agent cannot break the message, and nothing you type
# can inject template code.
# =============================================================================

# The fixed part of the template. @@NAME@@ marks what is filled in below (jq split/join: no regex, no & surprises).
_CS_GOTPL_HEAD='{{- /* Managed by DCS: the CrowdSec page writes this file. Change the message on the Discord tab. */ -}}
@@STATICVARS@@
{
  "username": @@USERNAME@@,
  @@AVATAR@@
  @@CONTENT@@
  "allowed_mentions": @@MENTIONS@@,
  "embeds": [
    {{- range $i, $alert := . }}
    {{- $p_ip := "" }}{{ with $alert.Source }}{{ with .Value }}{{ $p_ip = (. | trim) }}{{ end }}{{ end }}
    {{- $p_scope := "" }}{{ with $alert.Source }}{{ with .Scope }}{{ $p_scope = (. | trim) }}{{ end }}{{ end }}
    {{- $p_range := "" }}{{ with $alert.Source }}{{ with .Range }}{{ $p_range = (. | trim) }}{{ end }}{{ end }}
    {{- $p_country := "" }}{{ with $alert.Source }}{{ with .Cn }}{{ $p_country = (. | trim) }}{{ end }}{{ end }}
    {{- $p_as_number := "" }}{{ with $alert.Source }}{{ with .AsNumber }}{{ $p_as_number = (. | trim) }}{{ end }}{{ end }}
    {{- $p_as_name := "" }}{{ with $alert.Source }}{{ with .AsName }}{{ $p_as_name = (. | trim | replace "@" "@​") }}{{ end }}{{ end }}
    {{- $p_scenario := "" }}{{ with $alert.Scenario }}{{ $p_scenario = (. | trim | replace "@" "@​") }}{{ end }}
    {{- $p_machine := "" }}{{ with $alert.MachineID }}{{ $p_machine = (. | trim) }}{{ end }}
    {{- $p_message := "" }}{{ with $alert.Message }}{{ $p_message = (. | trim | replace "@" "@​") }}{{ end }}
    {{- $p_events := "0" }}{{ with $alert.EventsCount }}{{ $p_events = (printf "%d" (. | int)) }}{{ end }}
    {{- $p_alert_id := printf "%d" ($alert.ID | int) }}
    {{- $sim := "" }}{{ with $alert.Simulated }}{{ $sim = (ternary "1" "" .) }}{{ end }}
    {{- $dtype := "ban" }}{{ $p_duration := "" }}{{ $p_origin := "" }}
    {{- with $alert.Decisions }}{{ with index . 0 }}
      {{- with .Type }}{{ $dtype = (. | trim) }}{{ end }}
      {{- with .Duration }}{{ $p_duration = (. | trim) }}{{ end }}
      {{- with .Origin }}{{ $p_origin = (. | trim) }}{{ end }}
      {{- with .Simulated }}{{ if ternary "1" "" . }}{{ $sim = "1" }}{{ end }}{{ end }}
    {{- end }}{{ end }}
    {{- $p_target := "" }}{{ $p_path := "" }}{{ $p_user_agent := "" }}
    {{- range $e := $alert.Events }}{{ range $m := $e.Meta }}{{ with $m.Key }}{{ $k := (. | trim) }}
      {{- if and (eq $k "target_fqdn") (eq $p_target "") }}{{ with $m.Value }}{{ $p_target = (. | trim | trunc 200 | replace "@" "@​") }}{{ end }}
      {{- else if and (eq $k "http_path") (eq $p_path "") }}{{ with $m.Value }}{{ $p_path = (. | trim | trunc 200 | replace "@" "@​") }}{{ end }}
      {{- else if and (eq $k "http_user_agent") (eq $p_user_agent "") }}{{ with $m.Value }}{{ $p_user_agent = (. | trim | trunc 200 | replace "@" "@​") }}{{ end }}
      {{- end }}
    {{- end }}{{ end }}{{ end }}
    {{- $p_scenario_short := trimPrefix "crowdsecurity/" $p_scenario }}
    {{- $p_label := "Attack blocked" }}{{ $color := 15942494 }}
    @@CHAIN@@
    {{- if eq $dtype "captcha" }}{{ $color = 2282478 }}{{ end }}
    {{- $p_decision := $dtype }}{{ if $sim }}{{ $p_decision = print "simulated " $dtype }}{{ end }}
    {{- $p_sim_tag := "" }}{{ if $sim }}{{ $p_sim_tag = " (simulation)" }}{{ end }}
    {{- $p_flag := "" }}{{ $p_country_tag := "" }}{{ if eq (len $p_country) 2 }}{{ $p_flag = print ":flag_" (lower $p_country) ":" }}{{ $p_country_tag = print " " $p_flag " " $p_country }}{{ end }}
    {{- $p_as_tag := "" }}{{ if $p_as_name }}{{ $p_as_tag = print " · " $p_as_name }}{{ end }}
    {{- $p_for_duration := "" }}{{ if $p_duration }}{{ $p_for_duration = print " for " $p_duration }}{{ end }}
    {{- $p_target_tag := "" }}{{ if $p_target }}{{ $p_target_tag = print " · aimed at **" $p_target "**" }}{{ end }}
    {{- $p_origin_tag := "" }}{{ if $p_origin }}{{ $p_origin_tag = print " · " $p_origin }}{{ end }}
    {{- $p_machine_tag := "" }}{{ if $p_machine }}{{ $p_machine_tag = print " · " $p_machine }}{{ end }}
    {{- $p_path_code := "" }}{{ if $p_path }}{{ $p_path_code = print "`" (replace "`" "'"'"'" $p_path) "`" }}{{ end }}
    {{- $p_cti_url := print "https://app.crowdsec.net/cti/" $p_ip }}
    {{- $p_abuseipdb_url := print "https://www.abuseipdb.com/check/" $p_ip }}
    {{- $p_time := print "<t:" (now | unixEpoch) ":R>" }}
    {{- $title := @@TITLE@@ }}
    {{- $desc := @@DESC@@ }}
    {{- $footer := @@FOOTER@@ }}
    {{- $link := @@LINK@@ }}
    {{- if $i }},{{ end }}
    {
      "title": {{ $title | toJson }},
      "color": @@COLOR@@,
      "description": {{ $desc | toJson }},
      "fields": [
        {{- $sep := "" }}
        @@FIELDS@@
      ]
      {{- if $link }},
      "url": {{ $link | toJson }}
      {{- end }}
      {{- if $footer }},
      "footer": {"text": {{ $footer | toJson }}}
      {{- end }}
      @@TIMESTAMP@@
    }
    {{- end }}
  ]
}'

# _cs_notify_go_template SETTINGS DOMAIN SERVER — the template text
_cs_notify_go_template() {
    local s="$1" domain="$2" server="$3" ph
    ph=$(jq -c 'map(.name)' <<< "$_CS_PLACEHOLDERS")
    jq -nr --argjson s "$s" --arg domain "$domain" --arg server "$server" --arg head "$_CS_GOTPL_HEAD" --argjson known "$ph" "$_CS_JQ_LABELS"'
        def gostr: @json;
        def toks($str): [ ($str // "") | scan("\\{[a-z_]+\\}|[^{]+|\\{") ];
        def gexpr($str):
          (toks($str) | map(if test("^\\{[a-z_]+\\}$") and ((.[1:-1]) as $n | $known | index($n)) != null then "$p_" + .[1:-1] else gostr end)) as $parts
          | if ($parts | length) == 0 then "\"\"" elif ($parts | length) == 1 then $parts[0] else "(print " + ($parts | join(" ")) + ")" end;
        def lit($v): "{{ " + ($v | gostr) + " | toJson }}";
        ( [ label_table | to_entries[] | .key as $i | .value as $r
            | (if $i == 0 then "{{- if hasPrefix " else "{{- else if hasPrefix " end) + ($r[0] | gostr) + " $p_scenario }}{{ $p_label = " + ($r[1] | gostr) + " }}{{ $color = "
              + ({"bruteforce": 15942494, "exploit": 10979578, "probe": 16098851}[$r[2]] | tostring) + " }}" ] + ["{{- end }}"] | join("\n    ") ) as $chain
        | ( [ $s.message.fields | to_entries[] | .key as $i | .value as $f
              | "{{- $fn\($i) := \(gexpr($f.name)) }}{{ $fv\($i) := \(gexpr($f.value)) }}{{ if and (ne (trim $fn\($i)) \"\") (ne (trim $fv\($i)) \"\") }}{{ $sep }}\n        {\"name\": {{ $fn\($i) | toJson }}, \"value\": {{ $fv\($i) | toJson }}, \"inline\": \(if $f.inline then "true" else "false" end)}{{ $sep = \",\" }}{{ end }}" ] | join("\n        ") ) as $fields
        | ( if $s.mention.mode == "role" then "<@&" + $s.mention.id + ">" elif $s.mention.mode == "user" then "<@" + $s.mention.id + ">"
            elif $s.mention.mode == "here" then "@here" elif $s.mention.mode == "everyone" then "@everyone" else "" end ) as $mtag
        | ( [$mtag, $s.mention.text] | map(select(length > 0)) | join(" ") ) as $content
        | ( if $s.mention.mode == "role" then "{\"roles\": [" + ($s.mention.id | @json) + "]}" elif $s.mention.mode == "user" then "{\"users\": [" + ($s.mention.id | @json) + "]}"
            elif $s.mention.mode == "here" or $s.mention.mode == "everyone" then "{\"parse\": [\"everyone\"]}" else "{\"parse\": []}" end ) as $mentions
        | ( $s.embed.color | ltrimstr("#") | explode | map(if . >= 97 then . - 87 elif . >= 65 then . - 55 else . - 48 end) | reduce .[] as $d (0; . * 16 + $d) ) as $color_int
        | $head
        | split("@@STATICVARS@@") | join("{{- $p_domain := \($domain | gostr) }}{{ $p_server := \($server | gostr) }}")
        | split("@@USERNAME@@") | join(lit($s.identity.name))
        | split("@@AVATAR@@") | join(if $s.identity.avatar_url != "" then "\"avatar_url\": " + lit($s.identity.avatar_url) + "," else "" end)
        | split("@@CONTENT@@") | join(if $content != "" then "\"content\": " + lit($content) + "," else "" end)
        | split("@@MENTIONS@@") | join($mentions)
        | split("@@CHAIN@@") | join($chain)
        | split("@@TITLE@@") | join(gexpr($s.message.title))
        | split("@@DESC@@") | join(gexpr($s.message.description))
        | split("@@FOOTER@@") | join(gexpr($s.message.footer))
        | split("@@LINK@@") | join(gexpr($s.message.link))
        | split("@@COLOR@@") | join(if $s.embed.color_mode == "fixed" then ($color_int | tostring) else "{{ $color }}" end)
        | split("@@FIELDS@@") | join($fields)
        | split("@@TIMESTAMP@@") | join(if $s.message.timestamp then "{{- if true }},\n      \"timestamp\": {{ dateInZone \"2006-01-02T15:04:05Z\" now \"UTC\" | toJson }}\n      {{- end }}" else "" end)'
}

# _cs_notify_render_yaml SETTINGS URL — the whole notifications/http.yaml
_cs_notify_render_yaml() {
    local s="$1" url="$2" domain server tpl
    domain=$(_find_traefik_domain 2>/dev/null); [[ -n "$domain" ]] || domain="${PROXY_DOMAIN:-DCS}"
    server="${SERVER_NAME:-}"; [[ -n "$server" ]] || server=$(hostname 2>/dev/null || echo DCS)
    tpl=$(_cs_notify_go_template "$s" "$domain" "$server") || return 1
    jq -nr --argjson s "$s" --arg url "$url" --arg tpl "$tpl" '
        "# Managed by DCS: the CrowdSec page writes this file (Discord tab). Change it there; a backup of the previous file is kept.\n"
        + "# dcs-notify: " + ({v: 1, settings: $s} | tojson) + "\n"
        + "type: http\nname: http_default\nlog_level: info\n"
        + "group_wait: \($s.delivery.group_wait)s\ngroup_threshold: \($s.delivery.group_threshold)\nmax_retry: \($s.delivery.max_retry)\ntimeout: \($s.delivery.timeout)s\n"
        + "format: |\n" + ($tpl | split("\n") | map("  " + .) | join("\n")) + "\n"
        + "url: " + $url + "\nmethod: POST\nheaders:\n  Content-Type: application/json"'
}

# =============================================================================
# Discord notifications: the same message rendered by DCS (preview and test message)
#
# CrowdSec renders the Go template above when a real alert fires. The preview
# and the test message need the same result without an alert, so this jq
# program builds the identical payload from an alert in the shape
# `cscli alerts inspect -d -o json` prints. tests/smoke.sh pins the two
# together with a payload captured from a real CrowdSec.
# =============================================================================

_CS_JQ_RENDER='
def san: gsub("@"; "@​");
def trm: gsub("^\\s+|\\s+$"; "");
def first_meta($metas; $k): ([ $metas[] | select(.key == $k) | .value | tostring | trm | select(length > 0) ] | .[0]) // "";
def vals($a; $domain; $server; $now):
  ($a.source // {}) as $src
  | (($a.decisions // [])[0] // {}) as $d
  | ([ ($a.events // [])[] | (.meta // [])[] ]) as $metas
  | ($a.scenario // "" | tostring | trm | san) as $scenario
  | ($scenario | scen_row) as $row
  | (($d.type // "ban") | tostring | trm) as $dtype
  | ((($a.simulated // false) or ($d.simulated // false))) as $sim
  | (first_meta($metas; "target_fqdn") | .[0:200] | san) as $target
  | (first_meta($metas; "http_path") | .[0:200] | san) as $path
  | (first_meta($metas; "http_user_agent") | .[0:200] | san) as $ua
  | (($src.cn // "") | tostring | trm) as $cn
  | (($src.as_name // "") | tostring | trm | san) as $asname
  | (($src.value // $src.ip // "") | tostring | trm) as $ip
  | (($d.duration // "") | tostring | trm) as $dur
  | (($d.origin // "") | tostring | trm) as $origin
  | (($a.machine_id // "") | tostring | trm) as $machine
  | { ip: $ip, scope: (($src.scope // "") | tostring | trm), range: (($src.range // "") | tostring | trm), country: $cn,
      flag: (if ($cn | length) == 2 then ":flag_" + ($cn | ascii_downcase) + ":" else "" end),
      country_tag: (if ($cn | length) == 2 then " :flag_" + ($cn | ascii_downcase) + ": " + $cn else "" end),
      as_number: (($src.as_number // "") | tostring | trm), as_name: $asname, as_tag: (if $asname != "" then " · " + $asname else "" end),
      scenario: $scenario, scenario_short: ($scenario | ltrimstr("crowdsecurity/")), label: $row[1], events: (($a.events_count // 0) | tostring), alert_id: (($a.id // 0) | tostring),
      message: (($a.message // "") | tostring | trm | san), sim_tag: (if $sim then " (simulation)" else "" end),
      decision: (if $sim then "simulated " + $dtype else $dtype end), duration: $dur, for_duration: (if $dur != "" then " for " + $dur else "" end),
      origin: $origin, origin_tag: (if $origin != "" then " · " + $origin else "" end),
      target: $target, target_tag: (if $target != "" then " · aimed at **" + $target + "**" else "" end),
      path: $path, path_code: (if $path != "" then "`" + ($path | gsub("`"; "'"'"'")) + "`" else "" end), user_agent: $ua,
      machine: $machine, machine_tag: (if $machine != "" then " · " + $machine else "" end),
      domain: $domain, server: $server, time: ("<t:" + ($now | tostring) + ":R>"),
      cti_url: ("https://app.crowdsec.net/cti/" + $ip), abuseipdb_url: ("https://www.abuseipdb.com/check/" + $ip) };
def fill($t; $v): ($t // "") | gsub("\\{(?<k>[a-z_]+)\\}"; ($v[.k]) // ("{" + .k + "}"));
def color_of($s; $a; $v):
  if $s.embed.color_mode == "fixed" then ($s.embed.color | ltrimstr("#") | explode | map(if . >= 97 then . - 87 elif . >= 65 then . - 55 else . - 48 end) | reduce .[] as $d (0; . * 16 + $d))
  elif ((($a.decisions // [])[0].type // "ban") | tostring | trm) == "captcha" then 2282478
  else ({"bruteforce": 15942494, "exploit": 10979578, "probe": 16098851}[($a.scenario // "" | tostring | trm | scen_row | .[2])] // 15942494) end;
def payload($s; $a; $domain; $server; $now):
  vals($a; $domain; $server; $now) as $v
  | ( if $s.mention.mode == "role" then "<@&" + $s.mention.id + ">" elif $s.mention.mode == "user" then "<@" + $s.mention.id + ">"
      elif $s.mention.mode == "here" then "@here" elif $s.mention.mode == "everyone" then "@everyone" else "" end ) as $mtag
  | ( [$mtag, $s.mention.text] | map(select(length > 0)) | join(" ") ) as $content
  | fill($s.message.link; $v) as $link | fill($s.message.footer; $v) as $footer
  | [ $s.message.fields[] | {name: fill(.name; $v), value: fill(.value; $v), inline: .inline} | select((.name | trm | length) > 0 and (.value | trm | length) > 0) ] as $fields
  | { username: $s.identity.name }
    + (if $s.identity.avatar_url != "" then {avatar_url: $s.identity.avatar_url} else {} end)
    + (if $content != "" then {content: $content} else {} end)
    + { allowed_mentions: (if $s.mention.mode == "role" then {roles: [$s.mention.id]} elif $s.mention.mode == "user" then {users: [$s.mention.id]}
                           elif $s.mention.mode == "here" or $s.mention.mode == "everyone" then {parse: ["everyone"]} else {parse: []} end),
        embeds: [ { title: fill($s.message.title; $v), color: color_of($s; $a; $v), description: fill($s.message.description; $v), fields: $fields }
                  + (if $link != "" then {url: $link} else {} end)
                  + (if $footer != "" then {footer: {text: $footer}} else {} end)
                  + (if $s.message.timestamp then {timestamp: ($now | todate)} else {} end) ] };
'

# _cs_notify_render_payload SETTINGS ALERT_JSON — the Discord payload for one alert (JSON on stdout)
_cs_notify_render_payload() {
    local domain server
    domain=$(_find_traefik_domain 2>/dev/null); [[ -n "$domain" ]] || domain="${PROXY_DOMAIN:-DCS}"
    server="${SERVER_NAME:-}"; [[ -n "$server" ]] || server=$(hostname 2>/dev/null || echo DCS)
    jq -nc --argjson s "$1" --argjson a "$2" --arg domain "${CS_RENDER_DOMAIN:-$domain}" --arg server "${CS_RENDER_SERVER:-$server}" --argjson now "${CS_RENDER_NOW:-$(date +%s)}" \
        "$_CS_JQ_LABELS$_CS_JQ_RENDER"' payload($s; $a; $domain; $server; $now)'
}

# =============================================================================
# Handlers: the ban profile
# =============================================================================

_CS_DURATION_PRESETS='["30m","1h","4h","12h","24h","3d","7d","30d"]'

# Everything the profile handlers need to know about the live state, as globals:
# CS_LIVE_PROFILES (text), CS_INSPECT (JSON), CS_LIVE_SETTINGS (JSON), CS_NOTIFY_EFF (JSON, effective, not validated for a webhook)
_cs_profile_state() {
    CS_LIVE_PROFILES=$(_cs_live_file "$CS_PROFILES_PATH")
    CS_INSPECT=$(_cs_profile_inspect "$CS_LIVE_PROFILES")
    CS_LIVE_SETTINGS=$(_cs_profile_live_settings "$CS_INSPECT")
    CS_NOTIFY_EFF=$(_cs_notify_effective "$CS_INSPECT")
}

# sha256 of a text (drift detection)
_cs_sha() { printf '%s\n' "$1" | sha256sum | cut -d' ' -f1; }

# The notification settings in force: saved ones over the defaults; without a saved file the live profiles decide whether they are on
_cs_notify_effective() {
    local insp="$1" saved
    if [[ -s "$CS_NOTIFY_FILE" ]]; then
        _cs_notify_saved
    else
        saved="$_CS_NOTIFY_DEFAULTS"
        saved=$(jq -c --argjson on "$(jq '.notified' <<< "$insp")" '.enabled = $on' <<< "$saved")
        # an install whose Discord alerts already work keeps posting where it posts: the live URL, unless a server-wide webhook exists
        if [[ -z "$(_cs_webhook_resolve global)" && -n "$(_cs_webhook_resolve keep)" ]]; then saved=$(jq -c '.webhook.mode = "keep"' <<< "$saved"); fi
        printf '%s' "$saved"
    fi
}

# GET-side view of the ban profile
_cs_settings_view() {
    local drift=false saved raw=""
    saved=$(_cs_json_file "$CS_SETTINGS_FILE" '{}')
    if [[ "$(jq -r '.mode' <<< "$CS_INSPECT")" == dcs ]]; then
        local want; want=$(jq -r '.applied_profile_sha // ""' <<< "$saved")
        [[ -n "$want" && "$want" != "$(_cs_sha "$CS_LIVE_PROFILES")" ]] && drift=true
    fi
    # a hand-written profile file is shown to admins only (it can hold anything, including notification wiring)
    if [[ "$(jq -r '.mode' <<< "$CS_INSPECT")" == custom ]] && _api_check_admin; then raw="${CS_LIVE_PROFILES:0:20000}"; fi
    jq -nc --argjson insp "$CS_INSPECT" --argjson live "$CS_LIVE_SETTINGS" --argjson saved "$saved" --argjson presets "$_CS_DURATION_PRESETS" --argjson defaults "$_CS_PROFILE_DEFAULTS" \
        --argjson drift "$drift" --arg raw "$raw" --arg manual "$(_cs_manual_default_duration)" --argjson backups "$(_cs_backups_json)" --argjson ret "$(_cs_retention_days)" '
        { mode: $insp.mode, editable: ($insp.mode != "custom"), custom: ($insp.mode == "custom"), profile: $live, manual_duration: $manual, defaults: $defaults, presets: $presets,
          limits: {auto_max: "365d", manual_max: "10 years", overrides_max: 12},
          live: {file: "/etc/crowdsec/profiles.yaml", profiles: $insp.profiles, notified: $insp.notified, escalate: $insp.escalate, ip_duration: $insp.ip_duration, range_duration: $insp.range_duration},
          drift: $drift, backups: $backups, raw: (if $raw == "" then null else $raw end), retention_days: $ret,
          help: { duration: "How long CrowdSec bans an address it caught by itself. Bans you add by hand choose their own length.",
                  escalate: "Repeat offenders are banned longer each time: the length is the default times (number of earlier bans + 1), up to the cap. CrowdSec remembers earlier bans for its alert retention time.",
                  overrides: "A scenario can have its own length: SSH brute force for a day, known exploits for a week. The first matching row wins; a * at the end matches a prefix." } }'
}

# GET /crowdsec/settings — The default ban length CrowdSec uses, repeat-offender escalation and per-scenario lengths; says whether DCS can edit the file safely
handle_crowdsec_settings() {
    _cs_target || return
    _cs_profile_state
    _api_success "$(_cs_settings_view)"
}

# PUT /crowdsec/settings — Change the ban profile: {profile: {duration, range_duration, escalate: {enabled, max}, overrides: [{pattern, duration}]}, manual_duration, take_over}; validates with CrowdSec, restarts it and rolls back on failure
handle_crowdsec_settings_set() {
    _api_check_admin || { _api_error 403 "Admin access required"; return; }
    local body="$1" patch base merged norm md take notify_on new_prof rc mode saved
    [[ "$body" == \{* ]] && jq -e . >/dev/null 2>&1 <<< "$body" || { _api_error 400 "Send a JSON body: {\"profile\": {\"duration\": \"12h\"}}"; return; }
    patch=$(jq -c '(.profile // {})' <<< "$body"); jq -e 'type == "object"' >/dev/null 2>&1 <<< "$patch" || { _api_error 400 "profile must be an object"; return; }
    take=$(jq -r 'if .take_over == true then "yes" else "no" end' <<< "$body")
    md=$(jq -r '(.manual_duration // "") | tostring' <<< "$body")
    if [[ -n "$md" ]]; then md=$(_cs_norm_duration "$md") || { _api_error 400 "The default length for manual bans is not valid: use 30m, 4h, 7d or 2w"; return; }; fi
    _cs_target || return
    _cs_profile_state
    mode=$(jq -r '.mode' <<< "$CS_INSPECT")
    if [[ "$patch" != '{}' && "$mode" == custom && "$take" != yes ]]; then
        _api_response 409 "$(jq -nc '{error: true, code: 409, reason: "custom_profile", message: "profiles.yaml has profiles DCS did not write. Saving here would replace the whole file (a backup is kept). Send take_over: true to do that."}')"; return
    fi
    base="$CS_LIVE_SETTINGS"; [[ "$mode" == custom ]] && base="$_CS_PROFILE_DEFAULTS"
    merged=$(_cs_profile_merge "$base" "$patch")
    _cs_profile_validate "$merged" || { _api_error 400 "$CS_CFG_ERR"; return; }
    norm="$CS_OUT"
    local applied='{"changed":false}'
    if [[ "$patch" != '{}' ]]; then
        notify_on=false
        [[ "$(jq -r '.enabled' <<< "$CS_NOTIFY_EFF")" == true && -n "$(_cs_webhook_resolve "$(jq -r '.webhook.mode' <<< "$CS_NOTIFY_EFF")")" ]] && notify_on=true
        new_prof=$(_cs_profiles_render "$norm" "$CS_NOTIFY_EFF" "$notify_on")
        _cs_config_apply "$new_prof" ""; rc=$?
        applied=$(jq -nc --argjson rc "$rc" --arg m "$CS_APPLY_MSG" --argjson ch "$CS_APPLY_CHANGED" --arg b "$CS_APPLY_BACKUP" '{changed: ($ch == 1), message: $m, backup: (if $b == "" then null else $b end)}')
        if (( rc != 0 )); then
            _api_audit_log "${CLIENT_IP:-unknown}" "CROWDSEC_SETTINGS" "${AUTH_USERNAME:-}" "failed ($rc): ${CS_APPLY_MSG:0:120}"
            _cs_apply_fail "$rc"
            return
        fi
    fi
    saved=$(_cs_json_file "$CS_SETTINGS_FILE" '{}')
    saved=$(jq -c --argjson p "$norm" --arg md "$md" --arg sha "$(_cs_sha "$(_cs_live_file "$CS_PROFILES_PATH")")" --argjson touched "$([[ "$patch" != '{}' ]] && echo true || echo false)" \
        '.v = 1 | .profile = $p | (if $md != "" then .manual_duration = $md else . end) | (if $touched then .applied_profile_sha = $sha else . end)' <<< "$saved")
    printf '%s' "$saved" | _cs_json_save "$CS_SETTINGS_FILE"
    _cs_cache_clear
    _api_audit_log "${CLIENT_IP:-unknown}" "CROWDSEC_SETTINGS" "${AUTH_USERNAME:-}" "ban length $(jq -r '.duration' <<< "$norm")${md:+, manual $md}: ${CS_APPLY_MSG:-saved}"
    _cs_profile_state
    _api_success "$(_cs_settings_view | jq -c --argjson a "$applied" '. + {success: true, applied: $a}')"
}

# =============================================================================
# Handlers: Discord notifications
# =============================================================================

# _cs_status_set KEY JSON — remember the last test / apply outcome
_cs_status_set() {
    local key="$1" val="$2" cur
    cur=$(_cs_json_file "$CS_NOTIFY_STATUS" '{}')
    jq -c --arg k "$key" --argjson v "$val" '.[$k] = $v' <<< "$cur" | _cs_json_save "$CS_NOTIFY_STATUS"
}

# delivery problems the running plugin reported (CrowdSec logs failures, not successes): [{time, message}]
_cs_delivery_errors() {
    local raw out
    [[ -n "$CS_NAME" ]] || { printf '[]'; return; }
    raw=$(timeout 15 docker logs --since 24h --tail 3000 "$CS_NAME" 2>&1 </dev/null | grep -E 'http-plugin|http_default|delivery failed|notify attempt failed|format alerts for notification' | grep -E 'level=(warning|error)' | tail -n 40)
    out=$(printf '%s\n' "$raw" | jq -Rsc '[ split("\n")[] | select(length > 0) | capture("^time=\"(?<t>[^\"]+)\" level=(?<l>[a-z]+) msg=\"(?<m>(?:\\\\.|[^\"\\\\])*)\"")? | {time: .t, message: (.m | gsub("\\\\\""; "\""))} ] | reverse | unique_by(.message) | sort_by(.time) | reverse | .[0:5]' 2>/dev/null)
    [[ "$out" == \[* ]] || out='[]'
    printf '%s' "$out"
}

# The webhook as the page may see it: never the URL
_cs_webhook_view() {
    local mode="$1" g c k eff="none" u
    g=$(_cs_webhook_resolve global); c=$(_cs_webhook_resolve custom); k=$(_cs_webhook_resolve keep)
    u=$(_cs_webhook_resolve "$mode"); [[ -n "$u" ]] && eff="$mode"
    jq -nc --arg mode "$mode" --arg eff "$eff" --arg gm "$(_cs_webhook_mask "$g")" --arg cm "$(_cs_webhook_mask "$c")" --arg km "$(_cs_webhook_mask "$k")" --arg um "$(_cs_webhook_mask "$u")" \
        '{mode: $mode, configured: ($um != ""), masked: (if $um == "" then null else $um end),
          sources: {global: {configured: ($gm != ""), masked: (if $gm == "" then null else $gm end)}, custom: {configured: ($cm != ""), masked: (if $cm == "" then null else $cm end)}, keep: {configured: ($km != ""), masked: (if $km == "" then null else $km end)}}}'
}

# GET-side view of the notifications: settings in force, what is wired, the placeholders, the last outcomes
_cs_notify_view() {
    local eff="$1" insp="$2" status wired plugin drift=false mode file_mode hraw sha_want errs
    status=$(_cs_json_file "$CS_NOTIFY_STATUS" '{}')
    hraw=$(_cs_live_file "$CS_HTTP_PATH")
    file_mode=missing
    if [[ -n "$hraw" ]]; then
        if grep -q '^# dcs-notify:' <<< "$hraw"; then file_mode=dcs; else file_mode=other; fi
    fi
    sha_want=$(jq -r '.applied_http_sha // ""' <<< "$status")
    [[ "$file_mode" == dcs && -n "$sha_want" && "$sha_want" != "$(_cs_sha "$hraw")" ]] && drift=true
    wired=$(jq -r '.notified' <<< "$insp")
    plugin=false
    timeout 15 docker exec "$CS_NAME" cscli notifications list 2>/dev/null </dev/null | grep -E '^[[:space:]]*[^[:space:]]+[[:space:]]+http_default[[:space:]]' | grep -q '✔' && plugin=true
    errs=$(_cs_delivery_errors)
    jq -nc --argjson eff "$eff" --argjson insp "$insp" --argjson status "$status" --argjson wired "$wired" --argjson plugin "$plugin" --arg fm "$file_mode" --argjson drift "$drift" \
        --argjson webhook "$(_cs_webhook_view "$(jq -r '.webhook.mode' <<< "$eff")")" --argjson ph "$_CS_PLACEHOLDERS" --argjson defaults "$_CS_NOTIFY_DEFAULTS" --argjson errs "$errs" \
        --argjson samples "$(jq -c 'keys' <<< "$_CS_NOTIFY_SAMPLES")" --arg profmode "$(jq -r '.mode' <<< "$insp")" '
        { settings: $eff, webhook: $webhook, defaults: $defaults, placeholders: $ph, samples: $samples,
          state: { enabled: $eff.enabled, wired: $wired, plugin_active: $plugin, file: $fm, profile_mode: $profmode, drift: $drift,
                   working: ($eff.enabled and $wired and $plugin and $webhook.configured) },
          status: { last_test: ($status.last_test // null), last_apply: ($status.last_apply // null), delivery_errors: $errs,
                    note: "CrowdSec logs a failed delivery but not a successful one, so DCS can only show the problems the plugin reports and the result of the last test message." },
          limits: { title: 200, description: 1500, footer: 200, fields: 8, group_threshold_max: 10 },
          info: { unban: "CrowdSec cannot announce a lifted ban. Unbans made from DCS raise the crowdsec_unban event: add a rule for it on the Notifications page to hear about them." } }'
}

# GET /crowdsec/notifications — The Discord alert settings in force (webhook masked), what is wired, the placeholders for the message, and the last test/delivery outcome
handle_crowdsec_notify_get() {
    _cs_target || return
    _cs_profile_state
    _api_success "$(_cs_notify_view "$CS_NOTIFY_EFF" "$CS_INSPECT")"
}

# _cs_notify_apply EFFECTIVE_SETTINGS PROFILE_SETTINGS INSPECT — render both files from the settings and put them live. Returns _cs_config_apply's status.
_cs_notify_apply() {
    local eff="$1" prof="$2" insp="$3" url notify_on=false http_text="" prof_text rc
    url=$(_cs_webhook_resolve "$(jq -r '.webhook.mode' <<< "$eff")")
    if [[ "$(jq -r '.enabled' <<< "$eff")" == true && -n "$url" ]]; then notify_on=true; http_text=$(_cs_notify_render_yaml "$eff" "$url"); fi
    prof_text=$(_cs_profiles_render "$prof" "$eff" "$notify_on")
    _cs_config_apply "$prof_text" "$http_text"; rc=$?
    CS_APPLY_HTTP_SHA=""; [[ -n "$http_text" ]] && CS_APPLY_HTTP_SHA=$(_cs_sha "$http_text")
    CS_APPLY_PROF_SHA=$(_cs_sha "$prof_text")
    return $rc
}
CS_APPLY_HTTP_SHA=""; CS_APPLY_PROF_SHA=""

# _cs_notify_set_core BODY — save and apply the Discord alert settings. 0 = done (CS_RESULT holds the view), 1 = refused (CS_ERR_CODE / CS_ERR_BODY)
CS_RESULT=""
_cs_notify_set_core() {
    local body="$1" patch eff merged url_in prof mode take rc clear had_custom=""
    [[ "$body" == \{* ]] && jq -e . >/dev/null 2>&1 <<< "$body" || { _cs_fail 400 "Send a JSON body: {\"settings\": {\"enabled\": true}}"; return 1; }
    patch=$(jq -c '(.settings // {})' <<< "$body"); jq -e 'type == "object"' >/dev/null 2>&1 <<< "$patch" || { _cs_fail 400 "settings must be an object"; return 1; }
    url_in=$(jq -r '(.webhook_url // "") | tostring' <<< "$body"); clear=$(jq -r 'if .clear_custom_webhook == true then "yes" else "no" end' <<< "$body")
    take=$(jq -r 'if .take_over == true then "yes" else "no" end' <<< "$body")
    if [[ -n "$url_in" ]]; then
        [[ "$url_in" =~ ^https://[A-Za-z0-9.]+/api/webhooks/[0-9]{5,25}/[A-Za-z0-9_-]{10,200}$ ]] && _discord_is_webhook "$url_in" || { _cs_fail 400 "That is not a Discord webhook address (https://discord.com/api/webhooks/<id>/<token>)"; return 1; }
    fi
    CS_NAME=$(_crowdsec_container) || CS_NAME=""
    [[ -n "$CS_NAME" ]] || { _cs_fail 404 "CrowdSec is not running"; return 1; }
    _cs_profile_state
    mode=$(jq -r '.mode' <<< "$CS_INSPECT")
    if [[ "$mode" == custom && "$take" != yes ]]; then
        _cs_fail 409 "profiles.yaml has profiles DCS did not write. Saving here would replace the whole file (a backup is kept). Send take_over: true to do that." '{"reason":"custom_profile"}'; return 1
    fi
    merged=$(_cs_notify_merge "$CS_NOTIFY_EFF" "$patch")
    [[ -n "$url_in" ]] && merged=$(jq -c '.webhook.mode = "custom"' <<< "$merged")
    _cs_notify_validate "$merged" || { _cs_fail 400 "$CS_CFG_ERR"; return 1; }
    eff="$CS_OUT"
    prof="$CS_LIVE_SETTINGS"; [[ "$mode" == custom ]] && prof="$_CS_PROFILE_DEFAULTS"
    _cs_profile_validate "$prof" || { _cs_fail 500 "The ban profile in force is not valid: $CS_CFG_ERR"; return 1; }
    prof="$CS_OUT"
    # the webhook: a new custom one is stored first (and put back if the change fails)
    had_custom=$(secrets_get "$CS_WEBHOOK_SECRET" 2>/dev/null) || had_custom=""
    if [[ "$clear" == yes ]]; then secrets_delete "$CS_WEBHOOK_SECRET" >/dev/null 2>&1 || true; fi
    if [[ -n "$url_in" ]]; then secrets_set "$CS_WEBHOOK_SECRET" "$url_in" || { _cs_fail 500 "Could not store the webhook"; return 1; }; fi
    _cs_webhook_undo() {
        if [[ -n "$url_in" || "$clear" == yes ]]; then
            if [[ -n "$had_custom" ]]; then secrets_set "$CS_WEBHOOK_SECRET" "$had_custom" >/dev/null 2>&1; else secrets_delete "$CS_WEBHOOK_SECRET" >/dev/null 2>&1 || true; fi
        fi
    }
    if [[ "$(jq -r '.enabled' <<< "$eff")" == true && -z "$(_cs_webhook_resolve "$(jq -r '.webhook.mode' <<< "$eff")")" ]]; then
        _cs_webhook_undo
        _cs_fail 400 "There is no Discord webhook to post to: add one here, or set DISCORD_WEBHOOK_URL under Server Config → Notifications"; return 1
    fi
    _cs_notify_apply "$eff" "$prof" "$CS_INSPECT"; rc=$?
    if (( rc != 0 )); then
        _cs_webhook_undo
        _cs_status_set last_apply "$(jq -nc --arg m "$CS_APPLY_MSG" --argjson at "$(date +%s)" '{at: $at, ok: false, message: $m}')"
        _api_audit_log "${CLIENT_IP:-unknown}" "CROWDSEC_NOTIFY" "${AUTH_USERNAME:-}" "failed ($rc): ${CS_APPLY_MSG:0:120}"
        _cs_apply_error "$rc"; return 1
    fi
    printf '%s' "$eff" | _cs_json_save "$CS_NOTIFY_FILE"
    local st; st=$(_cs_json_file "$CS_SETTINGS_FILE" '{}')
    jq -c --argjson p "$prof" --arg sha "$CS_APPLY_PROF_SHA" '.v = 1 | .profile = $p | .applied_profile_sha = $sha' <<< "$st" | _cs_json_save "$CS_SETTINGS_FILE"
    _cs_status_set last_apply "$(jq -nc --arg m "$CS_APPLY_MSG" --argjson at "$(date +%s)" '{at: $at, ok: true, message: $m}')"
    if [[ -n "$CS_APPLY_HTTP_SHA" ]]; then
        jq -c --arg sha "$CS_APPLY_HTTP_SHA" '.applied_http_sha = $sha' <<< "$(_cs_json_file "$CS_NOTIFY_STATUS" '{}')" | _cs_json_save "$CS_NOTIFY_STATUS"
    fi
    _cs_cache_clear
    _api_audit_log "${CLIENT_IP:-unknown}" "CROWDSEC_NOTIFY" "${AUTH_USERNAME:-}" "$( [[ "$(jq -r '.enabled' <<< "$eff")" == true ]] && echo on || echo off )${url_in:+, webhook changed}: ${CS_APPLY_MSG:0:100}"
    _cs_profile_state
    CS_RESULT=$(_cs_notify_view "$CS_NOTIFY_EFF" "$CS_INSPECT" | jq -c --arg m "$CS_APPLY_MSG" --argjson ch "$CS_APPLY_CHANGED" '. + {success: true, applied: {changed: ($ch == 1), message: $m}}')
    return 0
}

# PUT /crowdsec/notifications — Save and apply the Discord alert settings: {settings: {…any part…}, webhook_url?: "https://discord.com/api/webhooks/…", clear_custom_webhook?: true}; the URL is stored as a secret and never sent back
handle_crowdsec_notify_set() {
    _api_check_admin || { _api_error 403 "Admin access required"; return; }
    if _cs_notify_set_core "$1"; then _api_success "$CS_RESULT"; else _api_response "$CS_ERR_CODE" "$CS_ERR_BODY"; fi
}

# POST /crowdsec/notifications/preview — Render the message for a sample alert (probe, ssh, exploit, manual, simulated) or a real one (alert_id) with the settings you are editing: {settings?, sample?, alert_id?}
handle_crowdsec_notify_preview() {
    local body="$1" patch sample alert_id alert merged out eff
    [[ "$body" == \{* ]] && jq -e . >/dev/null 2>&1 <<< "$body" || body='{}'
    patch=$(jq -c '(.settings // {})' <<< "$body"); jq -e 'type == "object"' >/dev/null 2>&1 <<< "$patch" || { _api_error 400 "settings must be an object"; return; }
    sample=$(jq -r '(.sample // "probe") | tostring' <<< "$body"); alert_id=$(jq -r '(.alert_id // "") | tostring' <<< "$body")
    _cs_target || return
    _cs_profile_state
    merged=$(_cs_notify_merge "$CS_NOTIFY_EFF" "$patch")
    if ! _cs_notify_validate "$merged"; then
        _api_success "$(jq -nc --arg m "$CS_CFG_ERR" '{valid: false, error: $m, payload: null}')"; return
    fi
    eff="$CS_OUT"
    if [[ -n "$alert_id" ]]; then
        [[ "$alert_id" =~ ^[0-9]{1,12}$ ]] || { _api_error 400 "alert_id must be a number"; return; }
        _cs_run out alerts inspect "$alert_id" -d -o json || { _api_error 404 "No alert $alert_id"; return; }
        alert=$(jq -c '.' <<< "$out")
        sample="alert $alert_id"
    else
        [[ "$sample" =~ ^[a-z]{3,12}$ ]] && jq -e --arg s "$sample" 'has($s)' >/dev/null 2>&1 <<< "$_CS_NOTIFY_SAMPLES" || { _api_error 400 "sample must be one of: $(jq -r 'keys | join(", ")' <<< "$_CS_NOTIFY_SAMPLES")"; return; }
        alert=$(jq -c --arg s "$sample" '.[$s]' <<< "$_CS_NOTIFY_SAMPLES")
    fi
    _api_success "$(jq -nc --arg s "$sample" --argjson p "$(_cs_notify_render_payload "$eff" "$alert")" --argjson a "$alert" '{valid: true, sample: $s, payload: $p, alert: {id: $a.id, scenario: $a.scenario}}')"
}

# _cs_discord_post URL PAYLOAD — post to a Discord webhook; the address travels on curl's standard input, not its command line.
# Sets CS_HTTP_CODE (000 when nothing answered), CS_HTTP_BODY, CS_CURL_ERR.
CS_HTTP_CODE=000; CS_HTTP_BODY=""; CS_CURL_ERR=""
_cs_discord_post() {
    local url="$1" payload="$2" body errf pf
    body=$(mktemp "${TMPDIR:-/tmp}/dcs-cs-http.XXXXXX"); errf=$(mktemp "${TMPDIR:-/tmp}/dcs-cs-http.XXXXXX"); pf=$(mktemp "${TMPDIR:-/tmp}/dcs-cs-http.XXXXXX")
    printf '%s' "$payload" > "$pf"
    CS_HTTP_CODE=$(printf 'url = "%s"\n' "$url" | curl -sS -K - -o "$body" -w '%{http_code}' --max-time 15 -H 'Content-Type: application/json' --data-binary "@$pf" 2>"$errf")
    [[ "$CS_HTTP_CODE" =~ ^[0-9]{3}$ ]] || CS_HTTP_CODE=000
    CS_HTTP_BODY=$(head -c 2000 "$body" 2>/dev/null); CS_CURL_ERR=$(head -c 300 "$errf" 2>/dev/null | tr '\n' ' ')
    rm -f "$body" "$errf" "$pf"
    [[ "$CS_HTTP_CODE" =~ ^2 ]]
}

# what Discord's answer means
_cs_discord_explain() {
    local code="$1" body="$2" m ra
    m=$(jq -r '.message // empty' <<< "$body" 2>/dev/null)
    case "$code" in
        2??) printf 'Delivered (Discord answered %s).' "$code" ;;
        400) printf 'Discord rejected the message (400)%s. Check the mention, the sender name and the field texts.' "${m:+: $m}" ;;
        401|403|404) printf 'Discord says this webhook does not exist (%s): it was deleted, or the address is wrong. Create a new webhook in the channel settings.' "$code" ;;
        429) ra=$(jq -r '.retry_after // empty' <<< "$body" 2>/dev/null); printf 'Discord is rate limiting this webhook (429)%s. Try again in a moment.' "${ra:+, retry after ${ra}s}" ;;
        5??) printf 'Discord is having trouble right now (%s). Try again later.' "$code" ;;
        000) printf 'Could not reach Discord%s.' "${CS_CURL_ERR:+ ($CS_CURL_ERR)}" ;;
        *) printf 'Discord answered %s%s.' "$code" "${m:+: $m}" ;;
    esac
}

# _cs_notify_test_core BODY — post the sample. 0 = the message was sent (delivered or not: CS_RESULT says which), 1 = refused (CS_ERR_*)
_cs_notify_test_core() {
    local body="$1" patch sample url_in url merged eff alert payload ok=false msg inc
    [[ "$body" == \{* ]] && jq -e . >/dev/null 2>&1 <<< "$body" || body='{}'
    patch=$(jq -c '(.settings // {})' <<< "$body"); jq -e 'type == "object"' >/dev/null 2>&1 <<< "$patch" || { _cs_fail 400 "settings must be an object"; return 1; }
    sample=$(jq -r '(.sample // "probe") | tostring' <<< "$body"); url_in=$(jq -r '(.webhook_url // "") | tostring' <<< "$body"); inc=$(jq -r 'if .include_mention == true then "yes" else "no" end' <<< "$body")
    [[ "$sample" =~ ^[a-z]{3,12}$ ]] && jq -e --arg s "$sample" 'has($s)' >/dev/null 2>&1 <<< "$_CS_NOTIFY_SAMPLES" || { _cs_fail 400 "sample must be one of: $(jq -r 'keys | join(", ")' <<< "$_CS_NOTIFY_SAMPLES")"; return 1; }
    if [[ -n "$url_in" ]]; then [[ "$url_in" =~ ^https://[A-Za-z0-9.]+/api/webhooks/[0-9]{5,25}/[A-Za-z0-9_-]{10,200}$ ]] && _discord_is_webhook "$url_in" || { _cs_fail 400 "That is not a Discord webhook address"; return 1; }; fi
    CS_NAME=$(_crowdsec_container) || CS_NAME=""
    [[ -n "$CS_NAME" ]] || { _cs_fail 404 "CrowdSec is not running"; return 1; }
    _cs_profile_state
    merged=$(_cs_notify_merge "$CS_NOTIFY_EFF" "$patch")
    _cs_notify_validate "$merged" || { _cs_fail 400 "$CS_CFG_ERR"; return 1; }
    eff="$CS_OUT"
    url="$url_in"; [[ -n "$url" ]] || url=$(_cs_webhook_resolve "$(jq -r '.webhook.mode' <<< "$eff")")
    [[ -n "$url" ]] || { _cs_fail 400 "There is no Discord webhook to post to: add one first"; return 1; }
    alert=$(jq -c --arg s "$sample" '.[$s]' <<< "$_CS_NOTIFY_SAMPLES")
    payload=$(_cs_notify_render_payload "$eff" "$alert")
    if [[ "$inc" != yes ]]; then payload=$(jq -c 'del(.content) | .allowed_mentions = {parse: []} | .embeds[0].footer.text = ((.embeds[0].footer.text // "") + " · test message")' <<< "$payload"); fi
    if _cs_discord_post "$url" "$payload"; then ok=true; fi
    msg=$(_cs_discord_explain "$CS_HTTP_CODE" "$CS_HTTP_BODY")
    _cs_status_set last_test "$(jq -nc --argjson at "$(date +%s)" --argjson ok "$ok" --argjson c "${CS_HTTP_CODE:-0}" --arg m "$msg" --arg s "$sample" '{at: $at, ok: $ok, http: $c, message: $m, sample: $s}')"
    _api_audit_log "${CLIENT_IP:-unknown}" "CROWDSEC_NOTIFY_TEST" "${AUTH_USERNAME:-}" "$sample: HTTP $CS_HTTP_CODE"
    CS_RESULT=$(jq -nc --argjson ok "$ok" --argjson c "${CS_HTTP_CODE:-0}" --arg m "$msg" --arg s "$sample" --argjson at "$(date +%s)" --arg masked "$(_cs_webhook_mask "$url")" '{success: $ok, delivered: $ok, http: $c, message: $m, sample: $s, at: $at, webhook: $masked}')
    return 0
}

# POST /crowdsec/notifications/test — Post a real sample message to Discord and say what Discord answered: {sample?, settings?, webhook_url?, include_mention?}; a test never pings anyone unless include_mention is true
handle_crowdsec_notify_test() {
    _api_check_admin || { _api_error 403 "Admin access required"; return; }
    if _cs_notify_test_core "$1"; then _api_success "$CS_RESULT"; else _api_response "$CS_ERR_CODE" "$CS_ERR_BODY"; fi
}

# POST /crowdsec/notifications/reset — Back to the message CrowdSec ships with (title, text, fields, colours, delivery); the webhook and the on/off switch stay
handle_crowdsec_notify_reset() {
    _api_check_admin || { _api_error 403 "Admin access required"; return; }
    _cs_target || return
    _cs_profile_state
    local keep_enabled keep_webhook
    keep_enabled=$(jq -c '.enabled' <<< "$CS_NOTIFY_EFF"); keep_webhook=$(jq -c '.webhook' <<< "$CS_NOTIFY_EFF")
    if _cs_notify_set_core "$(jq -nc --argjson d "$_CS_NOTIFY_DEFAULTS" --argjson e "$keep_enabled" --argjson w "$keep_webhook" '{settings: ($d | .enabled = $e | .webhook = $w)}')"; then
        _api_success "$CS_RESULT"
    else _api_response "$CS_ERR_CODE" "$CS_ERR_BODY"; fi
}

# POST /crowdsec/notifications — Send CrowdSec's alerts to Discord: {webhook?, test?}. Turns the alerts on with the message settings in force (the shipped message on a fresh install), stores a webhook you pass, restarts CrowdSec and optionally posts a test message.
handle_crowdsec_notifications_apply() {
    if ! _api_check_admin; then _api_error 403 "Admin access required"; return; fi
    local body="$1" webhook test domain req
    [[ "$body" == \{* ]] || body='{}'
    webhook=$(jq -r '(.webhook // "") | tostring' <<< "$body" 2>/dev/null); test=$(jq -r 'if .test == true then "true" else "false" end' <<< "$body" 2>/dev/null)
    _cs_target || return
    if [[ -z "$webhook" ]] && [[ -z "$(_cs_webhook_resolve global)" && -z "$(_cs_webhook_resolve custom)" ]]; then
        # the webhook the template was deployed with, else the one CrowdSec already posts to
        local proj; proj=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$CS_NAME" 2>/dev/null)
        [[ -n "$proj" && -f "$proj/.env" ]] && webhook=$(sed -n 's/^DISCORD_WEBHOOK_URL=//p' "$proj/.env" | head -1 | tr -d '"'"'"'')
        [[ "$webhook" =~ ^\$\{SECRETS[._]([A-Za-z_][A-Za-z0-9_]*)\}$ ]] && webhook=$(secrets_get "${BASH_REMATCH[1]}" 2>/dev/null || true)
        _discord_is_webhook "$webhook" || webhook=""
        [[ -n "$webhook" || -n "$(_cs_webhook_resolve keep)" ]] || { _api_error 400 "No Discord webhook: pass {\"webhook\": \"https://discord.com/api/webhooks/…\"}, set one under Server Config → Notifications, or deploy the crowdsec template with one"; return; }
    fi
    req=$(jq -nc --arg w "$webhook" '{settings: {enabled: true}} + (if $w != "" then {webhook_url: $w} else {} end)')
    if ! _cs_notify_set_core "$req"; then _api_response "$CS_ERR_CODE" "$CS_ERR_BODY"; return; fi
    domain=$(_find_traefik_domain); [[ -n "$domain" ]] || domain="${PROXY_DOMAIN:-DCS}"
    local tested=false test_out=""
    if [[ "$test" == "true" ]]; then
        if _cs_notify_test_core '{}'; then tested=$(jq -r '.delivered' <<< "$CS_RESULT"); test_out=$(jq -r '.message' <<< "$CS_RESULT"); fi
    fi
    _audit_log "CROWDSEC_NOTIFICATIONS" "Discord alerts configured on $CS_NAME for $domain${tested:+ (test message sent)}"
    _api_success "$(jq -nc --arg c "$CS_NAME" --arg d "$domain" --argjson t "${tested:-false}" --arg o "$test_out" '{success: true, container: $c, domain: $d, restarted: true, tested: $t, test_output: $o}')"
}
