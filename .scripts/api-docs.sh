#!/bin/bash
# =============================================================================
# DCS API reference generator
#
# Reads the router in .scripts/api-server.sh and produces:
#   docs/API.md        — one table per resource group (Method, Path, Access, Description)
#   --json             — the endpoint list as JSON (used by GET /)
#   --check            — exit 1 when docs/API.md is out of date (CI)
#
# Access levels come from the server's own policy functions, so the docs can
# never disagree with the code: the router's public routes are "public",
# routes _api_route_allowed refuses for the "user" role are "admin", the
# rest are "user".
# =============================================================================

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API="$BASE_DIR/.scripts/api-server.sh"
DOC="$BASE_DIR/docs/API.md"

# ── 1. Routes from the router ────────────────────────────────────────────────
# Output: METHOD<TAB>PATTERN<TAB>PUBLIC(0/1)<TAB>HANDLER
extract_routes() {
    awk '
        BEGIN { method=""; public=0; inreq=0 }
        /^handle_request\(\)/ { inreq=1 }
        inreq && /^}/ { inreq=0 }
        !inreq { next }
        /# ── Route: GET/    { method="GET";    public=1; next }
        /# ── Route: POST/   { method="POST";   public=1; next }
        /# ── Route: PUT/    { method="PUT";    public=0; next }
        /# ── Route: DELETE/ { method="DELETE"; public=0; next }
        /if ! _api_check_auth; then/ { public=0; next }
        /^[[:space:]]+\/[^ )]*\)/ {
            line=$0; sub(/^[[:space:]]+/, "", line)
            pat=line; sub(/\).*/, "", pat)
            rest=line; sub(/^[^)]*\)[[:space:]]*/, "", rest)
            n=split(pat, alts, "|")
            h=""
            if (match(rest, /handle_[a-z_]+/)) h=substr(rest, RSTART, RLENGTH)
            if (h != "") { for (i=1;i<=n;i++) print method "\t" alts[i] "\t" public "\t" h; next }
            pending_n=n; for (i=1;i<=n;i++) pending[i]=alts[i]; pending_method=method; pending_public=public
            next
        }
        pending_n > 0 && /handle_[a-z_]+/ {
            match($0, /handle_[a-z_]+/); h=substr($0, RSTART, RLENGTH)
            for (i=1;i<=pending_n;i++) print pending_method "\t" pending[i] "\t" pending_public "\t" h
            pending_n=0
        }
    ' "$API"
}

# ── 2. Descriptions from the "# METHOD /path — text" comments above handlers ──
# Output: HANDLER<TAB>DESCRIPTION
extract_descriptions() {
    awk '
        /^# (GET|POST|PUT|DELETE|PATCH) +\// {
            d=$0; sub(/^# (GET|POST|PUT|DELETE|PATCH) +[^ ]+ +(—|-|–) +/, "", d); last=d; next
        }
        /^# / { if (last == "") { d=$0; sub(/^# /, "", d); hint=d } ; next }
        /^handle_[a-z_]+\(\)/ {
            h=$1; sub(/\(\).*/, "", h)
            if (last != "") print h "\t" last
            last=""; hint=""
            next
        }
        { last=""; hint="" }
    ' "$API"
}

# Fallback description from the handler name: handle_stack_compose_save → "Stack compose save"
name_description() {
    local h="${1#handle_}"
    h="${h//_/ }"
    printf '%s' "${h^}"
}

# Route pattern → documented path with named parameters
doc_path() {
    local p="$1"
    case "$p" in
        "/routes/*/*")                  p="/routes/{stack}/{service}" ;;
        "/plugins/*/cards/*")           p="/plugins/{plugin}/cards/{card}" ;;
        "/plugins/*/hooks/*/test")      p="/plugins/{plugin}/hooks/{hook}/test" ;;
        "/plugins/*/hooks/*/update")    p="/plugins/{plugin}/hooks/{hook}/update" ;;
        "/plugins/*/hooks/*")           p="/plugins/{plugin}/hooks/{hook}" ;;
        "/plugins/*"*)                  p="${p/\*/\{plugin\}}" ;;
        "/rollback/*/snapshots/*")      p="/rollback/{stack}/snapshots/{snapshot}" ;;
        "/rollback/*/diff/*")           p="/rollback/{stack}/diff/{snapshot}" ;;
        "/rollback/*"*)                 p="${p/\*/\{stack\}}" ;;
        "/stacks/*/compose/history/*")  p="/stacks/{stack}/compose/history/{version}" ;;
        "/stacks/*"*)                   p="${p/\*/\{stack\}}" ;;
        "/containers/*"*)               p="${p/\*/\{container\}}" ;;
        "/networks/*"*)                 p="${p/\*/\{network\}}" ;;
        "/volumes/*"*)                  p="${p/\*/\{volume\}}" ;;
        "/images/*"*)                   p="${p/\*/\{image\}}" ;;
        "/templates/*"*)                p="${p/\*/\{template\}}" ;;
        "/snapshots/*"*)                p="${p/\*/\{snapshot\}}" ;;
        "/secrets/*"*)                  p="${p/\*/\{key\}}" ;;
        "/schedules/*"*)                p="${p/\*/\{id\}}" ;;
        "/automations/*"*)              p="${p/\*/\{id\}}" ;;
        "/webhooks/*"*)                 p="${p/\*/\{id\}}" ;;
        "/notifications/rules/*")       p="/notifications/rules/{id}" ;;
        "/auth/sessions/*")             p="/auth/sessions/{token-prefix}" ;;
        "/auth/invite/*")               p="/auth/invite/{code}" ;;
        "/health/score/*")              p="/health/score/{stack}" ;;
        "/export/*")                    p="/export/{health|system|config}" ;;
    esac
    printf '%s' "$p"
}

# ── 3. Access level via the server's own policy function ──────────────────────
# Extract _api_route_allowed verbatim and evaluate it for the "user" role.
route_allowed_src=$(sed -n '/^_api_route_allowed() {/,/^}/p' "$API")
eval "$route_allowed_src"

access_for() {
    local method="$1" pattern="$2" public="$3"
    if [[ "$public" == "1" ]]; then printf 'public'; return; fi
    # The policy matches concrete paths; turn the pattern into a representative path
    local probe="${pattern//\*/x}"
    if AUTH_ROLE=user _api_route_allowed "$method" "$probe"; then printf 'user'; else printf 'admin'; fi
}

group_of() {
    local p="$1"
    p="${p#/}"
    case "$p" in
        "") printf 'System' ;;
        auth/*) printf 'Authentication' ;;
        setup/*) printf 'Setup wizard' ;;
        stacks|stacks/*|batch/*) printf 'Stacks' ;;
        containers|containers/*) printf 'Containers' ;;
        images|images/*) printf 'Images' ;;
        networks|networks/*|volumes|volumes/*|topology) printf 'Networks and volumes' ;;
        templates|templates/*|compose/*) printf 'Templates' ;;
        routes|routes/*|dns/*|traefik/*|ddns/*|homarr/*) printf 'Routing and DNS' ;;
        logs|logs/*|events|audit|stream) printf 'Logs and events' ;;
        status|health|health/*|version|system|system/metrics|metrics/*|disks|config|config/*|export/*) printf 'System' ;;
        system/*) printf 'Updates and maintenance' ;;
        maintenance/*|backups|backups/*|snapshots|snapshots/*|rollback/*) printf 'Backups and maintenance' ;;
        env|env/*|settings/*|secrets|secrets/*) printf 'Configuration' ;;
        notifications/*|webhooks|webhooks/*|alerts/*) printf 'Notifications' ;;
        automations|automations/*|schedules|schedules/*) printf 'Automation' ;;
        plugins|plugins/*) printf 'Plugins' ;;
        terminal/*) printf 'Terminal' ;;
        *) printf 'Other' ;;
    esac
}

# ── 4. Assemble ───────────────────────────────────────────────────────────────
declare -A DESC=()
while IFS=$'\t' read -r h d; do DESC["$h"]="$d"; done < <(extract_descriptions)

rows=()   # GROUP<TAB>METHOD<TAB>PATH<TAB>ACCESS<TAB>DESCRIPTION
while IFS=$'\t' read -r method pattern public handler; do
    [[ -z "$method" ]] && continue
    path=$(doc_path "$pattern")
    access=$(access_for "$method" "$pattern" "$public")
    desc="${DESC[$handler]:-$(name_description "$handler")}"
    rows+=("$(group_of "$path")"$'\t'"$method"$'\t'"$path"$'\t'"$access"$'\t'"$desc")
done < <(extract_routes)

emit_markdown() {
    local total=${#rows[@]}
    cat <<HDR
# DCS API reference

Generated from the router in \`.scripts/api-server.sh\` by \`.scripts/api-docs.sh\` — do not edit by hand.
Run \`.scripts/api-docs.sh\` after adding or changing a route; CI fails when this file is stale.

The API listens on \`API_BIND:API_PORT\` (default \`0.0.0.0:9876\`) and answers JSON.
Every endpoint below is \`$total\` in total.

## Access levels

| Level | Meaning |
|-------|---------|
| public | No token needed (setup, login, health of the API itself). |
| user | Any authenticated account. Users are viewers: they read operational data and manage their own session and profile. |
| admin | Accounts with the admin role. Everything that changes the system, runs code or exposes secrets. |

Send the session token as \`Authorization: Bearer <token>\`. \`POST /auth/setup\` creates the first (admin) account on a fresh install; until it exists, only the setup endpoints and \`GET /version\` answer.

HDR
    cat <<'USAGE'
## Usage

```bash
API=http://localhost:9876

# First run: create the admin account (returns a session token)
curl -s -X POST "$API/auth/setup" -H 'Content-Type: application/json' \
     -d '{"username":"admin","password":"correct horse battery staple"}'

# Log in later
TOKEN=$(curl -s -X POST "$API/auth/login" -H 'Content-Type: application/json' \
     -d '{"username":"admin","password":"correct horse battery staple"}' | jq -r .token)
AUTH="Authorization: Bearer $TOKEN"

curl -s -H "$AUTH" "$API/status" | jq .            # host and Docker overview
curl -s -H "$AUTH" "$API/stacks" | jq .            # stacks and their containers
curl -s -H "$AUTH" -X POST "$API/stacks/media-services/start"

# Deploy a template into a stack and start it
curl -s -H "$AUTH" -X POST "$API/templates/jellyfin/deploy" -H 'Content-Type: application/json' \
     -d '{"target_stack":"media-services","auto_start":true,"variables":{"PUID":"1000"}}'

# Preview the same deployment without touching anything
curl -s -H "$AUTH" -X POST "$API/templates/jellyfin/dry-run" -H 'Content-Type: application/json' \
     -d '{"target_stack":"media-services"}' | jq .

# Live events and metrics (Server-Sent Events; EventSource clients pass the token as ?token=)
curl -N -H "$AUTH" "$API/stream"

# Invite a read-only viewer
CODE=$(curl -s -H "$AUTH" -X POST "$API/auth/invite" -d '{"role":"user"}' | jq -r .code)
curl -s -X POST "$API/auth/register" -H 'Content-Type: application/json' \
     -d "{\"username\":\"viewer\",\"password\":\"another strong passphrase\",\"invite_code\":\"$CODE\"}"
```

Errors are JSON too: `{"error": true, "code": 403, "message": "Admin access required"}`.
Rate limiting answers `429`; a fresh install answers `401` with a message pointing at `POST /auth/setup`.

USAGE
    local g
    local IFS_SAVE="$IFS"
    for g in "System" "Authentication" "Setup wizard" "Stacks" "Containers" "Images" "Networks and volumes" "Templates" "Routing and DNS" "Logs and events" "Updates and maintenance" "Backups and maintenance" "Configuration" "Notifications" "Automation" "Plugins" "Terminal" "Other"; do
        local any=0 r
        for r in "${rows[@]}"; do [[ "${r%%$'\t'*}" == "$g" ]] && { any=1; break; }; done
        [[ $any -eq 0 ]] && continue
        printf '## %s\n\n| Method | Path | Access | Description |\n|--------|------|--------|-------------|\n' "$g"
        for r in "${rows[@]}"; do
            IFS=$'\t' read -r rg rm rp ra rd <<< "$r"
            [[ "$rg" == "$g" ]] || continue
            printf '| %s | `%s` | %s | %s |\n' "$rm" "$rp" "$ra" "${rd//|/\\|}"
        done
        printf '\n'
    done
    IFS="$IFS_SAVE"
}

emit_json() {
    local first=1 r
    printf '['
    for r in "${rows[@]}"; do
        IFS=$'\t' read -r rg rm rp ra rd <<< "$r"
        [[ $first -eq 1 ]] && first=0 || printf ','
        jq -nc --arg m "$rm" --arg p "$rp" --arg a "$ra" --arg d "$rd" '{method:$m,path:$p,access:$a,description:$d}'
    done
    printf ']'
}

# Rewrite the endpoint catalogue that GET / serves (embedded in handle_root)
apply_root() {
    local json
    json=$(emit_json | jq -c '.')
    local tmp
    tmp=$(mktemp) || return 1
    awk -v json="$json" '
        /^[[:space:]]*read -r -d .. endpoints <<.DCS_ENDPOINTS. \|\| true$/ { print; print json; skipping=1; next }
        skipping && /^DCS_ENDPOINTS$/ { skipping=0 }
        skipping { next }
        { print }
    ' "$API" > "$tmp" && mv -f "$tmp" "$API"
    chmod +x "$API"
}

root_is_current() {
    local embedded
    embedded=$(awk '/^[[:space:]]*read -r -d .. endpoints <<.DCS_ENDPOINTS. \|\| true$/ { getline; print; exit }' "$API")
    [[ "$(printf '%s' "$embedded" | jq -c '.' 2>/dev/null)" == "$(emit_json | jq -c '.')" ]]
}

case "${1:-}" in
    --json)
        emit_json | jq -c '.'
        ;;
    --root)
        apply_root && echo "Updated the GET / endpoint catalogue in $API (${#rows[@]} endpoints)"
        ;;
    --check)
        if [[ ! -f "$DOC" ]] || ! diff -q <(emit_markdown) "$DOC" >/dev/null; then
            echo "docs/API.md is out of date — run .scripts/api-docs.sh" >&2
            exit 1
        fi
        if ! root_is_current; then
            echo "The GET / endpoint catalogue is out of date — run .scripts/api-docs.sh" >&2
            exit 1
        fi
        echo "docs/API.md and the GET / catalogue are up to date (${#rows[@]} endpoints)"
        ;;
    *)
        mkdir -p "$(dirname "$DOC")"
        emit_markdown > "$DOC"
        apply_root
        echo "Wrote $DOC and updated the GET / catalogue (${#rows[@]} endpoints)"
        ;;
esac
