#!/bin/bash
# lib-measure.sh — prints the facts a VM reported (facts.sh) the same way for a local boot test and for a real Proxmox VM
fact() { sed -n "s/^$1=//p" <<<"$FACTS_TEXT" | head -1; }
# measure_print "<facts text>" [ms until ssh answered] [image file]
measure_print() {
    local FACTS_TEXT=$1 t_ssh=${2:-} img=${3:-}
    echo
    echo "== measured"
    printf "  %-22s %s\n" "system" "$(fact os) · kernel $(fact kernel)"
    [[ -n "$t_ssh" ]] && printf "  %-22s %s\n" "boot to ssh" "$(awk "BEGIN {printf \"%.1f s\", $t_ssh/1000}") (guest: $(fact boot); multi-user after $(fact target))"
    printf "  %-22s %s\n" "memory in use" "$(fact mem_used) MB (without the file cache) of $(fact mem_total) MB · $(fact procs) processes"
    printf "  %-22s %s\n" "biggest processes" "$(fact top)"
    printf "  %-22s %s\n" "disk" "$(fact root_used_mb) MB used of $(fact root_gb) GB${img:+ · image file $(du -h "$img" | cut -f1)}"
    printf "  %-22s %s\n" "security modules" "$(fact lsm)"
}
