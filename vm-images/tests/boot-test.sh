#!/bin/bash
# =============================================================================
# boot-test.sh — boots a DCS VM image the way Proxmox does and checks it.
#   UEFI (OVMF), q35, a virtio-scsi disk, the cloud-init drive as a CD-ROM labelled cidata,
#   virtio network, balloon and guest agent, the serial port as the only console.
#   usage: boot-test.sh IMAGE.qcow2 [--ram MB] [--cpus N] [--grow-to GB] [--keep] [--hold] [--no-net]
#   --hold leaves the VM running after the checks and prints how to log in (for looking around by hand)
# Prints what it measured (time to ssh, memory, disk, failed units); exit status = failed checks.
# KVM is used when /dev/kvm is writable (GitHub-hosted runners have it), otherwise QEMU emulates (slow).
# =============================================================================
set -u
IMG=""; RAM=2048; CPUS=2; GROW=8; KEEP=0; NET=1; HOLD=0
while [[ $# -gt 0 ]]; do case "$1" in
    --ram) RAM=$2; shift 2 ;; --cpus) CPUS=$2; shift 2 ;; --grow-to) GROW=$2; shift 2 ;;
    --keep) KEEP=1; shift ;; --no-net) NET=0; shift ;; --hold) HOLD=1; KEEP=1; shift ;;
    -h|--help) sed -n "2,9p" "$0"; exit 0 ;; *) IMG=$1; shift ;;
esac; done
[[ -f "$IMG" ]] || { echo "usage: $0 IMAGE.qcow2 [--ram MB] [--cpus N] [--grow-to GB] [--keep] [--no-net]" >&2; exit 2; }
IMG=$(readlink -f "$IMG")
for c in qemu-system-x86_64 qemu-img ssh ssh-keygen; do command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 2; }; done
MKISO=""; if command -v genisoimage >/dev/null; then MKISO="genisoimage"; elif command -v mkisofs >/dev/null; then MKISO="mkisofs"; elif command -v xorriso >/dev/null; then MKISO="xorriso -as mkisofs"; fi
[[ -n "$MKISO" ]] || { echo "missing: genisoimage (or mkisofs / xorriso)" >&2; exit 2; }
CODE=""; VARS=""
for d in /usr/share/OVMF /usr/share/edk2/ovmf /usr/share/edk2/x64 /usr/share/qemu /usr/share/pve-edk2-firmware; do
    for pair in "OVMF_CODE_4M.fd OVMF_VARS_4M.fd" "OVMF_CODE.4m.fd OVMF_VARS.4m.fd" "OVMF_CODE.fd OVMF_VARS.fd"; do
        set -- $pair; [[ -f $d/$1 && -f $d/$2 ]] && { CODE=$d/$1; VARS=$d/$2; break 2; }
    done
done
[[ -n "$CODE" ]] || { echo "missing: OVMF firmware (apt install ovmf)" >&2; exit 2; }

T=$(mktemp -d /tmp/dcs-boot.XXXXXX); PASS=0; FAIL=0; QPID=""
cleanup() { [[ $HOLD == 1 ]] && return; [[ -n "$QPID" ]] && kill -0 "$QPID" 2>/dev/null && kill "$QPID" 2>/dev/null; [[ $KEEP == 1 ]] && echo "kept: $T" || rm -rf "$T"; }
trap cleanup EXIT
ok()  { PASS=$((PASS+1)); printf "  ok    %s\n" "$*"; }
bad() { FAIL=$((FAIL+1)); printf "  FAIL  %s\n" "$*"; }
chk() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
now_ms() { local t=${EPOCHREALTIME/./}; echo $((t / 1000)); }

# --- the seed Proxmox would attach ------------------------------------------------------------------------
MAC=52:54:00:12:34:56
ssh-keygen -q -t ed25519 -N "" -f "$T/key" -C dcs-boot-test
mkdir -p "$T/seed"
cat > "$T/seed/user-data" <<UD
#cloud-config
hostname: bootcheck
manage_etc_hosts: true
fqdn: bootcheck
user: dcs
ssh_authorized_keys:
  - $(cat "$T/key.pub")
chpasswd:
  expire: False
users:
  - default
UD
cat > "$T/seed/network-config" <<NC
version: 1
config:
    - type: physical
      name: eth0
      mac_address: "$MAC"
      subnets:
      - type: static
        address: "10.0.2.15"
        netmask: "255.255.255.0"
        gateway: "10.0.2.2"
    - type: nameserver
      address:
      - "10.0.2.3"
      search:
      - "lab.test"
NC
echo "instance-id: bootcheck-$RANDOM$RANDOM" > "$T/seed/meta-data"
$MKISO -quiet -output "$T/seed.iso" -volid cidata -joliet -rock "$T/seed/user-data" "$T/seed/meta-data" "$T/seed/network-config" 2>/dev/null

# --- a throwaway disk on top of the image, larger than it: the first boot has to grow into it ------------
qemu-img create -q -f qcow2 -b "$IMG" -F qcow2 "$T/disk.qcow2" "${GROW}G"
cp "$VARS" "$T/vars.fd"

if [[ -w /dev/kvm ]]; then ACCEL=kvm; CPU=host; WAIT=120; else ACCEL=tcg; CPU=max; WAIT=600; fi
PORT=""; for p in $(seq 20022 20122); do (echo >/dev/tcp/127.0.0.1/$p) 2>/dev/null || { PORT=$p; break; }; done

echo "== $(basename "$IMG"): $(du -h "$IMG" | cut -f1) qcow2, $(qemu-img info "$IMG" | awk "/virtual size/ {print \$3, \$4}") virtual · $ACCEL · ${CPUS} vCPU · ${RAM} MB"
T0=$(now_ms)
qemu-system-x86_64 -name dcs-boot-test -machine q35,accel=$ACCEL -cpu $CPU -smp "$CPUS" -m "$RAM" \
    -drive if=pflash,format=raw,readonly=on,file="$CODE" -drive if=pflash,format=raw,file="$T/vars.fd" \
    -device virtio-scsi-pci,id=scsi0 -drive file="$T/disk.qcow2",if=none,id=d0,format=qcow2,discard=unmap -device scsi-hd,drive=d0,bus=scsi0.0 \
    -drive file="$T/seed.iso",if=none,id=ci,media=cdrom,readonly=on,format=raw -device ide-cd,drive=ci \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:$PORT-:22 -device virtio-net-pci,netdev=n0,mac=$MAC \
    -device virtio-balloon-pci -device virtio-rng-pci \
    -chardev socket,id=qga0,path="$T/qga.sock",server=on,wait=off -device virtio-serial-pci -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
    -display none -vga none -serial file:"$T/serial.log" -monitor none \
    -daemonize -pidfile "$T/qemu.pid" || { bad "qemu did not start"; exit 1; }
QPID=$(cat "$T/qemu.pid")

SSH=(ssh -i "$T/key" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=2 -o BatchMode=yes dcs@127.0.0.1)
up=0; while (( $(now_ms) - T0 < WAIT * 1000 )); do
    "${SSH[@]}" true 2>/dev/null && { up=1; break; }
    kill -0 "$QPID" 2>/dev/null || break
    sleep 0.25
done
T_SSH=$(( $(now_ms) - T0 ))
if [[ $up != 1 ]]; then bad "ssh never answered (${WAIT}s)"; echo "--- serial console, last 40 lines"; tail -40 "$T/serial.log"; exit 1; fi
ok "ssh answers after $(awk "BEGIN {printf \"%.1f\", $T_SSH/1000}") s (power-on, firmware, kernel, first boot, sshd)"
sleep 8   # let the services settle before memory is read

FACTS=$("${SSH[@]}" "bash -s" <<"REMOTE" 2>/dev/null
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
REMOTE
)
get() { sed -n "s/^$1=//p" <<<"$FACTS" | head -1; }

chk "the host name comes from the seed"        [ "$(get hostname)" = bootcheck ]
chk "the user comes from the seed, with sudo and the docker group" [ "$(get user)" = dcs ] && [ "$(get sudo)" = yes ] && [ "$(get dockergroup)" = yes ]
chk "the address comes from the seed"          [ "$(get ip)" = 10.0.2.15/24 ]
chk "the DNS server comes from the seed"       [ "$(get resolv)" = 10.0.2.3 ]
chk "Docker Engine answers ($(get docker))"    [ "$(get docker)" != none ] && [ -n "$(get docker)" ]
chk "Docker Compose answers ($(get compose))"  [ "$(get compose)" != none ] && [ -n "$(get compose)" ]
chk "no failed units${FACTS:+ ($(get failed))}" [ -z "$(get failed | tr -d " ")" ]
chk "the guest agent runs"                     [ "$(get agent)" = active ]
chk "the disk grew into the larger virtual disk (${GROW} GB → $(get root_gb) GB)" [ "$(get root_gb)" -ge $((GROW - 1)) ]
if [[ $NET == 1 ]]; then
    HW=$("${SSH[@]}" "timeout 120 docker run --rm hello-world 2>&1 | grep -c 'Hello from Docker'" 2>/dev/null)
    chk "a container runs (hello-world pulled and started)" [ "${HW:-0}" -ge 1 ]
    OUTB=$("${SSH[@]}" "timeout 90 docker run --rm alpine:3 wget -q -O- -T 10 https://example.com 2>&1 | grep -c 'Example Domain'" 2>/dev/null)
    chk "a container reaches the internet (outbound NAT)" [ "${OUTB:-0}" -ge 1 ]
    PUB=$("${SSH[@]}" "bash -s" 2>/dev/null <<'PUBTEST'
mkdir -p /tmp/pubtest && cd /tmp/pubtest
printf 'services:\n  web:\n    image: nginx:alpine\n    ports: ["18080:80"]\n' > compose.yml
docker compose up -d >/dev/null 2>&1
c=000; for i in 1 2 3 4 5 6 7 8 9 10; do c=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/); [ "$c" = 200 ] && break; sleep 1; done
echo "$c"
docker compose down >/dev/null 2>&1
PUBTEST
)
    chk "a published port answers (docker compose up, port 18080)" [ "${PUB:-0}" = 200 ]
fi

echo
echo "== measured"
printf "  %-22s %s\n" "system" "$(get os) · kernel $(get kernel)"
printf "  %-22s %s\n" "boot to ssh" "$(awk "BEGIN {printf \"%.1f s\", $T_SSH/1000}") (guest: $(get boot))"
printf "  %-22s %s\n" "memory in use" "$(get mem_used) MB (without the file cache) of $(get mem_total) MB · $(get procs) processes"
printf "  %-22s %s\n" "biggest processes" "$(get top)"
printf "  %-22s %s\n" "disk" "$(get root_used_mb) MB used of $(get root_gb) GB · image file $(du -h "$IMG" | cut -f1)"
printf "  %-22s %s\n" "security modules" "$(get lsm)"

if [[ $HOLD == 1 ]]; then echo; echo "VM left running (pid $QPID). Log in:  ssh -i $T/key -p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null dcs@127.0.0.1"; echo "Stop it:  kill $QPID   (files in $T)"; exit "$FAIL"; fi
# --- power off the way Proxmox does and time it -----------------------------------------------------------------
T1=$(now_ms); "${SSH[@]}" "sudo systemctl poweroff" 2>/dev/null
for _ in $(seq 1 120); do kill -0 "$QPID" 2>/dev/null || break; sleep 0.25; done
if kill -0 "$QPID" 2>/dev/null; then bad "the VM did not power off within 30 s"; else ok "powers off in $(awk "BEGIN {printf \"%.1f\", ($(now_ms) - $T1)/1000}") s"; fi
echo; echo "$PASS passed, $FAIL failed"
exit "$FAIL"
