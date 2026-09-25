#!/bin/bash
# =============================================================================
# envfile.sh — keep KEY=value files safe to source and safe to read as data.
#
# The root .env is sourced by start.sh, stop.sh, status.sh and setup.sh and
# read line by line by the API. A value written without quotes but containing
# a space (SERVER_NAME=Howson Server) reads fine as data yet runs "Server" as
# a command when sourced, which broke every stack start after a reboot.
#
#   envfile_quote VALUE [bash|compose]   print VALUE ready to follow KEY=
#   envfile_repair FILE                  quote such values in place (backup kept)
# =============================================================================

# Bare values are left alone; anything else is double-quoted with the escapes
# the reader needs: bash mode escapes \ " $ ` (what `source` interprets),
# compose mode escapes \ and " only, so ${VAR} references keep working in a
# stack .env that docker compose reads.
envfile_quote() {
    local val="$1" mode="${2:-bash}"
    if [[ -n "$val" && "$val" =~ ^[A-Za-z0-9_./:@%+=,-]+$ ]]; then
        printf '%s' "$val"
        return 0
    fi
    local esc="${val//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    if [[ "$mode" == "bash" ]]; then
        esc="${esc//\$/\\\$}"
        esc="${esc//\`/\\\`}"
    fi
    printf '"%s"' "$esc"
}

# Rewrite lines whose unquoted value holds an inner space (and no quote
# character) with proper quotes; a trailing "# comment" stays a comment. Atomic; FILE.bak-repair keeps the
# original; a note goes to stderr. Nothing happens when every line is fine.
envfile_repair() {
    local file="$1"
    [[ -f "$file" && -r "$file" && -w "$file" ]] || return 0
    local q="'"
    local re="^([[:space:]]*(export[[:space:]]+)?)([A-Za-z_][A-Za-z0-9_]*)=([^\"${q}#[:space:]][^\"${q}#]*[[:space:]]+[^\"${q}#[:space:]][^\"${q}#]*)([[:space:]]+#.*)?\$"
    grep -qE "^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=[^\"'#[:space:]][^\"'#]*[[:space:]]+[^\"'#[:space:]]" "$file" 2>/dev/null || return 0
    local line out="" n=0 key val pre
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ $re ]]; then
            pre="${BASH_REMATCH[1]}"; key="${BASH_REMATCH[3]}"; val="${BASH_REMATCH[4]}"
            val="${val%"${val##*[![:space:]]}"}"
            line="${pre}${key}=$(envfile_quote "$val" bash)${BASH_REMATCH[5]}"
            n=$((n + 1))
        fi
        out+="$line"$'\n'
    done < "$file"
    (( n > 0 )) || return 0
    cp -p "$file" "$file.bak-repair" 2>/dev/null
    if printf '%s' "$out" > "$file.tmp.$$"; then
        chmod --reference="$file" "$file.tmp.$$" 2>/dev/null
        mv -f "$file.tmp.$$" "$file" || { rm -f "$file.tmp.$$"; return 1; }
    else
        rm -f "$file.tmp.$$"; return 1
    fi
    printf 'Repaired %d unquoted value(s) in %s (original kept as %s)\n' "$n" "$file" "$file.bak-repair" >&2
}
