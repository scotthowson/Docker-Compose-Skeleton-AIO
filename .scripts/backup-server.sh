#!/bin/bash
# =============================================================================
# Docker Services Backup Script
#
# Makes the same backup as the Backup page (POST /backups/trigger), in the
# foreground: every stack's folder with its App-Data and named volumes, read
# as root, with sudo or through a read-only helper container, the stack's
# containers paused while they are read, plus the install's own state; checked
# and written with a .sha256 beside it. See docs/OPERATIONS.md#backups-and-snapshots.
#
# Usage: .scripts/backup-server.sh [STACK]        (exit status 0 = done and complete)
#
# Environment variables (from .env):
#   $BACKUP_DEST_DIR         -- where to store archives (required)
#   $BACKUP_SOURCE_DIR       -- an extra folder to back up (default: none, the install)
#   $BACKUP_RETENTION_COUNT  -- archives kept of each kind (default: 6)
#   $BACKUP_PAUSE            -- false: never pause a stack's containers (default: true)
# =============================================================================

case "${1:-}" in
    -h|--help)
        sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
esac

_BS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_BS_STACK="${1:-}"
set --
# shellcheck source=/dev/null
source "$_BS_DIR/api-server.sh" >/dev/null 2>&1 || { echo "[ERROR]   could not load $_BS_DIR/api-server.sh" >&2; exit 1; }
set +e

if [[ -n "$_BS_STACK" ]] && { [[ ! "$_BS_STACK" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || [[ ! -d "$COMPOSE_DIR/$_BS_STACK" ]]; }; then
    echo "[ERROR]   no stack named $_BS_STACK" >&2; exit 1
fi
if [[ -z "${BACKUP_DEST_DIR:-}" ]]; then
    echo "[ERROR]   BACKUP_DEST_DIR is not set. Configure it in .env to enable backups." >&2; exit 1
fi
if _backup_pid_alive "$BACKUP_PID_FILE" || _backup_pid_alive "$BACKUP_RESTORE_PID_FILE"; then
    echo "[ERROR]   a backup or a restore is already running" >&2; exit 1
fi

umask 077
BK_FILE="Docker-Compose-Backup-$(date '+%Y-%m-%d_%H%M%S')${_BS_STACK:+-$_BS_STACK}.tar.gz"
# shellcheck disable=SC2034  # read by the status writer of api-server.sh
BK_STARTED="$(date -Iseconds)" BK_PID=$$
echo "$$" > "$BACKUP_PID_FILE"
trap '_backup_unpause_all; rm -rf -- "${BACKUP_DEST_DIR%/}/.dcs-backup-staging-${BK_FILE%.tar.gz}"; rm -f -- "${BACKUP_DEST_DIR%/}/$BK_FILE.partial" "$BACKUP_PID_FILE"' EXIT
trap 'exit 143' TERM INT

echo "[INFO]    Backup $BK_FILE into $BACKUP_DEST_DIR"
_start=$(date +%s)
if ! _backup_run "$BK_FILE" "$_BS_STACK" "backup-server.sh"; then
    echo "[ERROR]   $BK_ERROR" >&2
    exit 1
fi
echo "[INFO]    $(jq -r '"\(.size), \(.stacks) stacks, \(.volumes) volumes, \(.files) files, sha256 \(.sha256)"' <<< "$BK_RESULT")"
if [[ "$(jq -r '.complete' <<< "$BK_RESULT")" != true ]]; then
    jq -r '.warnings[] | "[WARNING] " + .' <<< "$BK_RESULT" >&2
    echo "[ERROR]   the backup is incomplete" >&2
    exit 1
fi
echo "[SUCCESS] Backup completed in $(( $(date +%s) - _start )) seconds"
exit 0
