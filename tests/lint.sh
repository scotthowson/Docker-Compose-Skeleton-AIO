#!/bin/bash
# =============================================================================
# DCS lint: syntax, shellcheck, compose validation, API reference freshness
# Usage: tests/lint.sh          (exit status 0 = clean)
# =============================================================================
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
rc=0

mapfile -t SCRIPTS < <(git ls-files -co --exclude-standard '*.sh' 'setup.sh' 'start.sh' 'stop.sh' 'restart.sh' 'status.sh' '.config/settings.cfg' 2>/dev/null | sort -u)
# Plugin hooks are bash too
while IFS= read -r hook; do
    head -1 "$hook" | grep -qE '^#!/(usr/)?bin/(env )?bash' && SCRIPTS+=("$hook")
done < <(git ls-files '.plugins/*/hooks/*' 2>/dev/null)   # bundled plugins only, not ones installed by the user

echo "Syntax (bash -n): ${#SCRIPTS[@]} files"
for f in "${SCRIPTS[@]}"; do
    bash -n "$f" || { echo "  syntax error: $f"; rc=1; }
done

if command -v shellcheck >/dev/null 2>&1; then
    echo "shellcheck (warning level)"
    if ! shellcheck -S warning -e SC1090,SC1091 "${SCRIPTS[@]}"; then rc=1; fi
else
    echo "shellcheck not installed — skipped"
fi

echo "API reference freshness"
./.scripts/api-docs.sh --check || rc=1

if docker compose version >/dev/null 2>&1; then
    echo "Compose validation: stacks"
    for d in Stacks/*/; do
        [[ -f "$d/docker-compose.yml" ]] || continue
        if ! (cd "$d" && docker compose --env-file "$ROOT/.env.example" config -q 2>/dev/null || docker compose config -q 2>/dev/null); then
            echo "  invalid compose: $d"; rc=1
        fi
    done
    echo "Compose validation: templates (variables filled from template.json defaults)"
    tmp_env=$(mktemp)
    for d in .templates/*/; do
        [[ -f "$d/docker-compose.yml" ]] || continue
        # Deploy substitutes the template's variables; validate with the same defaults
        # (required variables without a default get a placeholder).
        if [[ -f "$d/template.json" ]]; then
            jq -r '.variables[]? | select(.name != null) | "\(.name)=\(.default // "placeholder")"' "$d/template.json" 2>/dev/null > "$tmp_env"
        else
            : > "$tmp_env"
        fi
        if ! (cd "$d" && docker compose --env-file "$tmp_env" config -q >/dev/null 2>&1); then
            echo "  invalid compose: $d"; rc=1
            (cd "$d" && docker compose --env-file "$tmp_env" config -q 2>&1 | grep -v 'level=warning' | sed 's/^/    /')
        fi
    done
    rm -f "$tmp_env"
else
    echo "docker compose not available — compose validation skipped"
fi

echo "JSON files"
for f in .config/schema.json .config/template-gallery.json .templates/*/template.json .plugins/*/plugin.json .plugins/*/cards/*/card.json .api-auth/*.json; do
    [[ -f "$f" ]] || continue
    jq -e . "$f" >/dev/null 2>&1 || { echo "  invalid JSON: $f"; rc=1; }
done

[[ $rc -eq 0 ]] && echo "lint: clean" || echo "lint: problems found"
exit $rc
