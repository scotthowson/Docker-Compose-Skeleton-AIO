#!/bin/bash
# =============================================================================
# boot-test.sh — boots a DCS VM image the way Proxmox does and checks it.
#   legacy BIOS (SeaBIOS, machine pc — Proxmox's default) or UEFI (OVMF, machine q35), a virtio-scsi disk,
#   the cloud-init drive as a CD-ROM labelled cidata, virtio network, balloon and guest agent, the serial
#   port as the only console.
#   usage: boot-test.sh IMAGE.qcow2 [--role node|hub] [--firmware bios|uefi] [--ram MB] [--cpus N] [--grow-to GB]
#                                   [--keep] [--hold] [--no-net] [--no-power-cut]
# A hub image is also checked for its first start: the API and the dashboard answer and the wizard waits for its admin.
# DCS_TEST_REGISTRY=public.ecr.aws/docker/library/ pulls the test containers from a mirror (CI).
# Prints what it measured (time to ssh, memory, disk, failed units); exit status = failed checks.
# The last step (node images) cuts the power the moment a fresh VM first answers and boots it again: the files
# the first boot wrote must have reached the disk. KVM is used when /dev/kvm is writable (GitHub-hosted runners have it),
# otherwise QEMU emulates (slow). --hold leaves the VM running and prints how to log in (for looking around).
# =============================================================================
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IMG=""; RAM=2048; CPUS=2; GROW=8; KEEP=0; NET=1; HOLD=0; FW=bios; CUT=1; ROLE=node; FORCE_CUT=0; UUID=""; SEEDBUS=ide
while [[ $# -gt 0 ]]; do case "$1" in
    --ram) RAM=$2; shift 2 ;; --cpus) CPUS=$2; shift 2 ;; --grow-to) GROW=$2; shift 2 ;;
    --keep) KEEP=1; shift ;; --no-net) NET=0; shift ;; --hold) HOLD=1; KEEP=1; CUT=0; shift ;;
    --firmware) FW=$2; shift 2 ;; --no-power-cut) CUT=0; shift ;; --power-cut) FORCE_CUT=1; shift ;; --role) ROLE=$2; shift 2 ;; --uuid) UUID=$2; shift 2 ;; --seed-bus) SEEDBUS=$2; shift 2 ;;
    -h|--help) sed -n "2,13p" "$0"; exit 0 ;; *) IMG=$1; shift ;;
esac; done
USAGE="usage: $0 IMAGE.qcow2 [--role node|hub] [--firmware bios|uefi] [--ram MB] [--cpus N] [--grow-to GB] [--keep] [--hold] [--no-net] [--no-power-cut]"
[[ -f "$IMG" ]] || { echo "$USAGE" >&2; exit 2; }
[[ "$FW" == bios || "$FW" == uefi ]] || { echo "--firmware is bios or uefi" >&2; exit 2; }
[[ "$ROLE" == node || "$ROLE" == hub ]] || { echo "--role is node or hub" >&2; exit 2; }
[[ $ROLE == hub && $FORCE_CUT == 0 ]] && CUT=0
IMG=$(readlink -f "$IMG")
for c in qemu-system-x86_64 qemu-img ssh ssh-keygen; do command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 2; }; done
MKISO=""; if command -v genisoimage >/dev/null; then MKISO="genisoimage"; elif command -v mkisofs >/dev/null; then MKISO="mkisofs"; elif command -v xorriso >/dev/null; then MKISO="xorriso -as mkisofs"; fi
[[ -n "$MKISO" ]] || { echo "missing: genisoimage (or mkisofs / xorriso)" >&2; exit 2; }
CODE=""; VARS=""
if [[ $FW == uefi ]]; then
    for d in /usr/share/OVMF /usr/share/edk2/ovmf /usr/share/edk2/x64 /usr/share/qemu /usr/share/pve-edk2-firmware; do
        for pair in "OVMF_CODE_4M.fd OVMF_VARS_4M.fd" "OVMF_CODE.4m.fd OVMF_VARS.4m.fd" "OVMF_CODE.fd OVMF_VARS.fd"; do
            set -- $pair; [[ -f $d/$1 && -f $d/$2 ]] && { CODE=$d/$1; VARS=$d/$2; break 2; }
        done
    done
    [[ -n "$CODE" ]] || { echo "missing: OVMF firmware (apt install ovmf)" >&2; exit 2; }
fi

T=$(mktemp -d /tmp/dcs-boot.XXXXXX); PASS=0; FAIL=0; QPID=""
# The disk is read the way Proxmox reads it: uncompressed (the image file is zstd-compressed for the download; QEMU decompresses reads
# in its main loop and the guest's first second of reads stalls, which is not what a Proxmox VM does with the imported copy)
qemu-img convert -f qcow2 -O qcow2 "$IMG" "$T/base.qcow2" || { echo "cannot read $IMG" >&2; rm -rf "$T"; exit 2; }
BASE="$T/base.qcow2"
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

if [[ -w /dev/kvm ]]; then ACCEL=kvm; CPU=host; WAIT=120; else ACCEL=tcg; CPU=max; WAIT=600; fi
PORT=""; for p in $(seq 20022 20122); do (echo >/dev/tcp/127.0.0.1/$p) 2>/dev/null || { PORT=$p; break; }; done
free_port() { local p; for p in $(seq "$1" "$(( $1 + 100 ))"); do (echo >/dev/tcp/127.0.0.1/$p) 2>/dev/null || { echo $p; return; }; done; }
P_UI=$(free_port 23000); P_API=$(free_port $((P_UI + 1)))
SSH=(ssh -i "$T/key" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=2 -o BatchMode=yes dcs@127.0.0.1)

# the cloud-init drive: an IDE CD-ROM the way Proxmox attaches it by default (ide2), or a SCSI one on the disk'\''s virtio-scsi controller (scsi1)
if [[ $SEEDBUS == scsi ]]; then SEEDDEV=scsi-cd; SEEDBUSARG="bus=scsi0.0"; else SEEDDEV=ide-cd; SEEDBUSARG=""; fi
# boot_vm NAME — a throwaway disk on top of the image (larger, so the first boot has to grow into it) and QEMU on it;
# the same NAME again boots the same disk. Sets QPID and T0.
boot_vm() {
    local name=$1 disk="$T/$1.qcow2" machine fwargs=()
    if [[ ! -f "$disk" ]]; then
        qemu-img create -q -f qcow2 -b "$BASE" -F qcow2 "$disk" "${GROW}G"
        [[ $FW == uefi ]] && cp "$VARS" "$T/$name.vars"
    fi
    # shellcheck disable=SC2054  # the commas are QEMU's option syntax, not array separators
    if [[ $FW == uefi ]]; then machine="q35,accel=$ACCEL"; fwargs=(-drive if=pflash,format=raw,readonly=on,file="$CODE" -drive if=pflash,format=raw,file="$T/$name.vars"); else machine="pc,accel=$ACCEL"; fi
    T0=$(now_ms)
    qemu-system-x86_64 -name "dcs-boot-test-$name" ${UUID:+-uuid "$UUID"} -machine "$machine" -cpu $CPU -smp "$CPUS" -m "$RAM" "${fwargs[@]}" \
        -device virtio-scsi-pci,id=scsi0 -drive file="$disk",if=none,id=d0,format=qcow2,discard=unmap -device scsi-hd,drive=d0,bus=scsi0.0,bootindex=1 \
        -drive file="$T/seed.iso",if=none,id=ci,media=cdrom,readonly=on,format=raw -device "$SEEDDEV",drive=ci${SEEDBUSARG:+,$SEEDBUSARG} \
        -netdev user,id=n0,hostfwd=tcp:127.0.0.1:$PORT-:22,hostfwd=tcp:127.0.0.1:$P_UI-:3000,hostfwd=tcp:127.0.0.1:$P_API-:9876 -device virtio-net-pci,netdev=n0,mac=$MAC \
        -device virtio-balloon-pci -device virtio-rng-pci \
        -chardev socket,id=qga0,path="$T/qga.sock",server=on,wait=off -device virtio-serial-pci -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
        -display none -vga none -serial file:"$T/$name.serial" -monitor none \
        -daemonize -pidfile "$T/$name.pid" || return 1
    QPID=$(cat "$T/$name.pid")
}
# wait_ssh — until ssh answers (ms since T0 in T_SSH); 1 when it never does
wait_ssh() {
    while (( $(now_ms) - T0 < WAIT * 1000 )); do
        "${SSH[@]}" true 2>/dev/null && { T_SSH=$(( $(now_ms) - T0 )); return 0; }
        kill -0 "$QPID" 2>/dev/null || break
        sleep 0.2
    done
    T_SSH=$(( $(now_ms) - T0 )); return 1
}

echo "== $(basename "$IMG"): $(du -h "$IMG" | cut -f1) qcow2, $(qemu-img info "$IMG" | awk "/virtual size/ {print \$3, \$4}") virtual · $FW · $ACCEL · ${CPUS} vCPU · ${RAM} MB"
boot_vm main || { bad "qemu did not start"; exit 1; }
if ! wait_ssh; then bad "ssh never answered (${WAIT}s)"; echo "--- serial console, last 40 lines"; tail -40 "$T/main.serial"; exit 1; fi
ok "ssh answers after $(awk "BEGIN {printf \"%.1f\", $T_SSH/1000}") s (power-on, firmware, kernel, first boot, sshd)"
T_MAIN=$T_SSH
sleep 8   # let the services settle before memory is read

FACTS=$("${SSH[@]}" "bash -s" < "$HERE/facts.sh" 2>/dev/null)
get() { sed -n "s/^$1=//p" <<<"$FACTS" | head -1; }

chk "the host name comes from the seed"        [ "$(get hostname)" = bootcheck ]
chk "the user comes from the seed, with sudo and the docker group" [ "$(get user)" = dcs ] && [ "$(get sudo)" = yes ] && [ "$(get dockergroup)" = yes ]
chk "the address comes from the seed"          [ "$(get ip)" = 10.0.2.15/24 ]
chk "the DNS server comes from the seed"       [ "$(get resolv)" = 10.0.2.3 ]
chk "Docker Engine answers ($(get docker))"    [ "$(get docker)" != none ] && [ -n "$(get docker)" ]
chk "Docker Compose answers ($(get compose))"  [ "$(get compose)" != none ] && [ -n "$(get compose)" ]
chk "no failed units${FACTS:+ ($(get failed))}" [ -z "$(get failed | tr -d " ")" ]
chk "the guest agent runs"                     [ "$(get agent)" = active ]
chk "the VGA console (noVNC) has a login prompt" [ "$(get getty_vga)" = active ]
chk "the kernel logged no errors"              [ "$(get kernel_errors)" = 0 ]
chk "ssh takes keys only, root cannot log in"  [ "$(get ssh_keys_only)" = yes ]
chk "ssh has the one ed25519 host key"         [ "$(get ssh_hostkeys | tr -d " ")" = ssh_host_ed25519_key ]
chk "the root account has no password"         [ "$(get root_locked)" = L ]
chk "the disk grew into the larger virtual disk (${GROW} GB → $(get root_gb) GB)" [ "$(get root_gb)" -ge $((GROW - 1)) ]
if [[ $NET == 1 ]]; then
    HW=$("${SSH[@]}" "timeout 120 docker run --rm ${DCS_TEST_REGISTRY:-}hello-world 2>&1 | grep -c 'Hello from Docker'" 2>/dev/null)
    chk "a container runs (hello-world pulled and started)" [ "${HW:-0}" -ge 1 ]
    OUTB=$("${SSH[@]}" "timeout 90 docker run --rm ${DCS_TEST_REGISTRY:-}alpine:3 wget -q -O- -T 10 https://example.com 2>&1 | grep -c 'Example Domain'" 2>/dev/null)
    chk "a container reaches the internet (outbound NAT)" [ "${OUTB:-0}" -ge 1 ]
    PUB=$("${SSH[@]}" "DCS_TEST_REGISTRY='${DCS_TEST_REGISTRY:-}' bash -s" 2>/dev/null <<'PUBTEST'
mkdir -p /tmp/pubtest && cd /tmp/pubtest
printf 'services:\n  web:\n    image: ${DCS_TEST_REGISTRY:-}nginx:alpine\n    ports: ["18080:80"]\n' > compose.yml
docker compose up -d >/dev/null 2>&1
c=000; for i in 1 2 3 4 5 6 7 8 9 10; do c=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/); [ "$c" = 200 ] && break; sleep 1; done
echo "$c"
docker compose down >/dev/null 2>&1
PUBTEST
)
    chk "a published port answers (docker compose up, port 18080)" [ "${PUB:-0}" = 200 ]
fi

if [[ $ROLE == hub ]]; then
    # the first start pulls the dashboard image: give it time, then look at what it started
    for _ in $(seq 1 180); do "${SSH[@]}" 'test -e /var/lib/dcs-init/hub-done' 2>/dev/null && break; sleep 2; done
    chk "the hub's first start finished"                     "${SSH[@]}" 'test -e /var/lib/dcs-init/hub-done'
    chk "the API answers (/ping)"                            "${SSH[@]}" 'curl -fsS -m 5 http://127.0.0.1:9876/ping'
    chk "the boot services are installed"                    "${SSH[@]}" 'systemctl is-enabled dcs-api dcs-stacks'
    chk "the dashboard container runs"                       "${SSH[@]}" 'docker ps --format "{{.Names}}" | grep -qx DCS-UI'
    UIOK=0; for _ in $(seq 1 30); do curl -fsS -m 3 -o /dev/null "http://127.0.0.1:$P_UI/" 2>/dev/null && { UIOK=1; break; }; sleep 2; done
    chk "the dashboard answers from outside the VM (port 3000)" [ "$UIOK" = 1 ]
    chk "the wizard is waiting for its first admin"          [ "$(curl -fsS -m 5 "http://127.0.0.1:$P_API/setup/status" 2>/dev/null | jq -r '(.initialized == false) and (.needs_admin == true)' 2>/dev/null)" = true ]
    chk "the console banner names the dashboard"             "${SSH[@]}" 'grep -q Dashboard /etc/issue.d/30-dcs-hub.issue'
    chk "the hub role is set"                                "${SSH[@]}" 'grep -q "^FLEET_ROLE=hub" ~/.Docker-Compose-Skeleton-AIO/.env'
    FACTS=$("${SSH[@]}" "bash -s" < "$HERE/facts.sh" 2>/dev/null)   # the numbers of a hub at work
fi

. "$HERE/lib-measure.sh"
measure_print "$FACTS" "$T_MAIN" "$IMG"

if [[ $HOLD == 1 ]]; then echo; [[ $ROLE == hub ]] && echo "Dashboard: http://127.0.0.1:$P_UI   API: http://127.0.0.1:$P_API"; echo "VM left running (pid $QPID). Log in:  ssh -i $T/key -p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null dcs@127.0.0.1"; echo "Stop it:  kill $QPID   (files in $T)"; exit "$FAIL"; fi
# --- power off the way Proxmox does and time it -----------------------------------------------------------------
T1=$(now_ms); "${SSH[@]}" "sudo systemctl poweroff" 2>/dev/null
for _ in $(seq 1 120); do kill -0 "$QPID" 2>/dev/null || break; sleep 0.25; done
if kill -0 "$QPID" 2>/dev/null; then bad "the VM did not power off within 30 s"; else ok "powers off in $(awk "BEGIN {printf \"%.1f\", ($(now_ms) - $T1)/1000}") s"; fi

# --- a power cut the moment a fresh VM first answers: what its first boot wrote has to be on the disk ------------
if [[ $CUT == 1 ]]; then
    echo "instance-id: bootcheck-$RANDOM$RANDOM" > "$T/seed/meta-data"   # a new machine, so the first boot happens again
    $MKISO -quiet -output "$T/seed.iso" -volid cidata -joliet -rock "$T/seed/user-data" "$T/seed/meta-data" "$T/seed/network-config" 2>/dev/null
    if boot_vm cut && wait_ssh; then
        kill -9 "$QPID" 2>/dev/null; wait_gone=0; while kill -0 "$QPID" 2>/dev/null && (( wait_gone++ < 40 )); do sleep 0.1; done
        if boot_vm cut && wait_ssh; then
            CUTFACTS=$("${SSH[@]}" "echo host=\$(uname -n); echo ip=\$(ip -4 -o addr show eth0 | awk '{print \$4}'); sudo sshd -t && echo sshd=ok" 2>/dev/null)
            chk "after a power cut at the first boot: the host name is still the seed's"  grep -q '^host=bootcheck$' <<<"$CUTFACTS"
            chk "after a power cut at the first boot: the address is still the seed's"    grep -q '^ip=10.0.2.15/24$' <<<"$CUTFACTS"
            chk "after a power cut at the first boot: ssh has its host keys"              grep -q '^sshd=ok$' <<<"$CUTFACTS"
            "${SSH[@]}" "sudo systemctl poweroff" 2>/dev/null; for _ in $(seq 1 120); do kill -0 "$QPID" 2>/dev/null || break; sleep 0.25; done
        else bad "after a power cut at the first boot the VM never answered again"; tail -15 "$T/cut.serial"; fi
    else bad "the second machine never answered"; fi
fi
echo; echo "$PASS passed, $FAIL failed"
exit "$FAIL"
