#!/bin/bash
# =============================================================================
# measure.sh [-i KEY] [-p PORT] USER@HOST — what a running VM is: memory without the file cache, disk, boot time, processes
# Same numbers as boot-test.sh, for a VM on a real Proxmox node or a stock image to compare with.
# =============================================================================
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ARGS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=5)
while getopts "i:p:" o; do case $o in i) ARGS+=(-i "$OPTARG") ;; p) ARGS+=(-p "$OPTARG") ;; *) exit 2 ;; esac; done
shift $((OPTIND - 1)); [[ $# -eq 1 ]] || { echo "usage: $0 [-i KEY] [-p PORT] USER@HOST" >&2; exit 2; }
. "$HERE/lib-measure.sh"
FACTS=$(ssh "${ARGS[@]}" "$1" "bash -s" < "$HERE/facts.sh") || { echo "cannot reach $1" >&2; exit 1; }
measure_print "$FACTS"
