#!/bin/bash
# =============================================================================
# DCS lint: syntax, shellcheck, compose validation, API reference freshness
# Usage: tests/lint.sh          (exit status 0 = clean)
# =============================================================================
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
rc=0

# (the VM images' scripts that run inside the VM have no .sh extension: dcs-init, dcs-hub-init, dcs-grubcfg, the kernel-install plugin)
mapfile -t SCRIPTS < <(git ls-files -co --exclude-standard '*.sh' 'setup.sh' 'start.sh' 'stop.sh' 'restart.sh' 'status.sh' '.config/settings.cfg' 'vm-images/*/sbin/*' 'vm-images/*/install.d/*' 2>/dev/null | sort -u)
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
    # The API script is 25,000 lines: ShellCheck's extended (dataflow) analysis needs about 12 GB on it and
    # killed the CI runner (7 GB). Without it the same warnings come out at 0.6 GB. LINT_FULL=1 turns it back on.
    # shellcheck disable=SC2054  # the comma belongs to the -e code list, it is one element
    SC_OPTS=(-S warning -e SC1090,SC1091)
    if [[ "${LINT_FULL:-0}" != "1" ]] && shellcheck --help 2>&1 | grep -q -- '--extended-analysis'; then SC_OPTS+=(--extended-analysis=false); fi
    if ! shellcheck "${SC_OPTS[@]}" "${SCRIPTS[@]}"; then rc=1; fi
else
    echo "shellcheck not installed — skipped"
fi

echo "API reference freshness"
./.scripts/api-docs.sh --check || rc=1

# One list of VM images (vm-images/images.json) feeds the build, CI, the Proxmox importer, the API catalogue and the documentation:
# a distribution added to one and forgotten in another is a lint error, not a surprise at release time
echo "VM images: one list everywhere"
if [[ -f vm-images/images.json ]]; then
    mapfile -t IMG_IDS < <(jq -r '.images[].id' vm-images/images.json)
    for id in "${IMG_IDS[@]}"; do
        [[ -f "vm-images/$id/Dockerfile" ]] || { echo "  vm-images/images.json lists $id, but vm-images/$id/Dockerfile does not exist"; rc=1; }
        grep -q -i -w -- "$id" docs/VM-IMAGES.md 2>/dev/null || { echo "  docs/VM-IMAGES.md does not mention $id"; rc=1; }
        grep -q -i -w -- "$id" vm-images/README.md || { echo "  vm-images/README.md does not mention $id"; rc=1; }
    done
    for d in vm-images/*/Dockerfile; do
        id=$(basename "$(dirname "$d")")
        [[ "$id" == tools ]] && continue   # the disk assembly tools are not an image
        printf '%s\n' "${IMG_IDS[@]}" | grep -qx -- "$id" || { echo "  $d exists, but $id is not in vm-images/images.json"; rc=1; }
    done
    jq -e '.default as $d | any(.images[]; .id == $d)' vm-images/images.json >/dev/null || { echo "  vm-images/images.json: the default is not in the list"; rc=1; }
    jq -e 'all(.images[]; (.hardware // "") | length > 0)' vm-images/images.json >/dev/null || { echo "  vm-images/images.json: an image has no \"hardware\" line (the New VM sheet shows what the kernel drives)"; rc=1; }
    want=$(printf '%s ' "${IMG_IDS[@]}" | sed 's/ $//')
    have=$(sed -n 's/^KNOWN_DISTROS="\(.*\)"$/\1/p' vm-images/proxmox/dcs-proxmox.sh)
    [[ "$want" == "$have" ]] || { echo "  vm-images/proxmox/dcs-proxmox.sh knows [$have], vm-images/images.json lists [$want]"; rc=1; }
    api_ids=$(bash -c 'set --; source .scripts/api-server.sh >/dev/null 2>&1; _fleet_dcs_images_json x | jq -r "map(.id | ltrimstr(\"dcs-\")) | sort | join(\" \")"' 2>/dev/null)
    [[ "$api_ids" == "$(printf '%s\n' "${IMG_IDS[@]}" | sort | tr '\n' ' ' | sed 's/ $//')" ]] || { echo "  the API catalogue offers [$api_ids], vm-images/images.json lists [$want]"; rc=1; }
fi

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
for f in vm-images/images.json .config/schema.json .config/template-gallery.json .templates/*/template.json .plugins/*/plugin.json .plugins/*/cards/*/card.json .api-auth/*.json; do
    [[ -f "$f" ]] || continue
    jq -e . "$f" >/dev/null 2>&1 || { echo "  invalid JSON: $f"; rc=1; }
done

[[ $rc -eq 0 ]] && echo "lint: clean" || echo "lint: problems found"
exit $rc
