#!/bin/bash
# =============================================================================
# compose.sh — docker compose for one stack, the way the dashboard runs it:
# root .env, the stack's .env and the encrypted secret store all applied.
#
# Usage:  ./compose.sh <stack> [docker compose arguments...]
#         ./compose.sh networking-security up -d --force-recreate --no-deps cloudflare-ddns
#         ./compose.sh media-services logs -f plex
#         ./compose.sh --list
#
# Everything in Stacks/<stack>/ is plain Compose, but ${SECRETS_name} references
# are resolved from the store only by DCS itself. A bare `docker compose` in the
# stack directory prints 'The "SECRETS_..." variable is not set' and starts the
# container with blank secrets; this wrapper does not.
# =============================================================================
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BASE_DIR
COMPOSE_DIR="$BASE_DIR/Stacks"

_usage() {
    sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
    ""|-h|--help) _usage; exit 0 ;;
    --list)
        for d in "$COMPOSE_DIR"/*/; do
            [[ -f "$d/docker-compose.yml" ]] && basename "$d"
        done
        exit 0 ;;
esac

stack="$1"; shift
if [[ ! "$stack" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
    echo "compose.sh: invalid stack name '$stack'" >&2; exit 2
fi
compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
if [[ ! -f "$compose_file" ]]; then
    echo "compose.sh: no such stack '$stack' (see ./compose.sh --list)" >&2; exit 2
fi
if [[ $# -eq 0 ]]; then
    echo "compose.sh: give docker compose something to do, e.g. ./compose.sh $stack ps" >&2; exit 2
fi

# Root .env (repaired first if a value was saved without quotes), then the libs
if [[ -f "$BASE_DIR/.lib/envfile.sh" ]]; then
    source "$BASE_DIR/.lib/envfile.sh"
    envfile_repair "$BASE_DIR/.env" || true
fi
if [[ -f "$BASE_DIR/.env" ]]; then
    set -a
    source "$BASE_DIR/.env"
    set +a
fi
source "$BASE_DIR/.lib/secrets.sh"
secrets_init >/dev/null 2>&1 || true

compose_with_secrets "$compose_file" "$COMPOSE_DIR/$stack/.env" "$@"
