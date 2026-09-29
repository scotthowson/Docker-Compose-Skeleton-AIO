#!/bin/bash
# =============================================================================
# facts.sh — runs INSIDE a DCS VM (ssh HOST bash -s < facts.sh) and prints what it is as key=value lines.
# Used by boot-test.sh and measure.sh; needs sudo without a password (a DCS VM has it).
# =============================================================================
set -u
echo "os=$(. /etc/os-release; echo "$PRETTY_NAME")"
echo "kernel=$(uname -r)"
echo "hostname=$(hostname)"
echo "user=$(id -un)"
echo "sudo=$(sudo -n true 2>/dev/null && echo yes || echo no)"
echo "dockergroup=$(id -nG | tr " " "\n" | grep -qx docker && echo yes || echo no)"
echo "docker=$(docker version --format "{{.Server.Version}}" 2>/dev/null || echo none)"
echo "compose=$(docker compose version --short 2>/dev/null || echo none)"
echo "failed=$(sudo systemctl --failed --no-legend --plain | awk "{print \$1}" | tr "\n" " ")"
echo "mem_used=$(awk "/^MemTotal/ {t=\$2} /^MemFree/ {f=\$2} /^Buffers/ {b=\$2} /^Cached/ {c=\$2} /^SReclaimable/ {r=\$2} END {printf \"%d\", (t-f-b-c-r)/1024}" /proc/meminfo)"
echo "mem_avail=$(free -m | awk "/^Mem:/ {print \$7}")"
echo "mem_total=$(free -m | awk "/^Mem:/ {print \$2}")"
echo "root_gb=$(df -BG --output=size / | tail -1 | tr -dc 0-9)"
echo "root_used_mb=$(df -BM --output=used / | tail -1 | tr -dc 0-9)"
echo "boot=$(sudo systemd-analyze 2>/dev/null | head -1 | sed "s/Startup finished in //")"
echo "procs=$(ps -e --no-headers | wc -l)"
echo "ip=$(ip -4 -o addr show scope global | awk "{print \$4}" | head -1)"
echo "resolv=$(grep -m1 nameserver /etc/resolv.conf | cut -d" " -f2)"
echo "lsm=$(cat /sys/kernel/security/lsm 2>/dev/null)"
echo "swap=$(swapon --noheadings 2>/dev/null | wc -l)"
echo "agent=$(sudo systemctl is-active qemu-guest-agent 2>/dev/null)"
echo "top=$(ps -eo rss,comm --sort=-rss --no-headers | head -6 | awk "{printf \"%s(%dM) \", \$2, \$1/1024}")"
