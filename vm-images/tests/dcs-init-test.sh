#!/bin/bash
# =============================================================================
# dcs-init against the seeds Proxmox really writes (fixtures/): no root, no VM.
# Usage: vm-images/tests/dcs-init-test.sh   (exit status 0 = all passed)
# =============================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT="$HERE/../common/overlay/usr/local/sbin/dcs-init"
PASS=0; FAIL=0
check() { if [[ "$3" == "$2" ]]; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL + 1)); printf '  FAIL %s (expected %s, got %s)\n' "$1" "$2" "$3"; fi; }
run() { DCS_ROOT="$1" DCS_SEED_DIR="$HERE/fixtures/$2" bash "$INIT" >/dev/null 2>&1; echo $?; }

echo "dcs-init: a static address, the way Proxmox writes it"
T=$(mktemp -d); trap 'command rm -rf "$T"' EXIT
R=$T/static
check "exits 0"                       0 "$(run "$R" static)"
check "hostname"                      monitoring-management "$(cat "$R/etc/hostname")"
check "hosts names the machine"       "127.0.1.1 monitoring-management monitoring-management" "$(grep '^127.0.1.1' "$R/etc/hosts")"
check "one ssh key for the user"      1 "$(grep -c '^ssh-ed25519 ' "$R/home/dcs/.ssh/authorized_keys")"
check "ssh dir is private"            700 "$(stat -c %a "$R/home/dcs/.ssh")"
check "keys file is private"          600 "$(stat -c %a "$R/home/dcs/.ssh/authorized_keys")"
check "passwordless sudo"             "dcs ALL=(ALL) NOPASSWD:ALL" "$(cat "$R/etc/sudoers.d/90-dcs-user")"
check "sudoers file mode"             440 "$(stat -c %a "$R/etc/sudoers.d/90-dcs-user")"
N=$(ls "$R"/etc/systemd/network/10-dcs-*.network 2>/dev/null | head -1)
check "one network file"              1 "$(ls "$R"/etc/systemd/network/10-dcs-*.network | wc -l)"
check "matched by MAC"                "MACAddress=bc:24:11:71:6f:be" "$(grep '^MACAddress=' "$N")"
check "address with prefix"           "Address=192.168.2.100/24" "$(grep '^Address=' "$N")"
check "gateway"                       "Gateway=192.168.2.1" "$(grep '^Gateway=' "$N")"
check "no DHCP when static"           0 "$(grep -c '^DHCP=' "$N")"
check "dns server"                    "nameserver 192.168.2.1" "$(grep '^nameserver' "$R/etc/resolv.conf")"
check "search domain"                 "search howson.dev" "$(grep '^search' "$R/etc/resolv.conf")"
check "the user is remembered"            dcs "$(cat "$R/var/lib/dcs-init/user")"
check "instance id remembered"        3ba902022cccfb5339400f70bf82ad87da79c87b "$(cat "$R/var/lib/dcs-init/instance-id")"
# the same instance again: nothing is rewritten
echo "kept" > "$R/etc/hostname"
check "same instance: exits 0"        0 "$(run "$R" static)"
check "same instance: nothing redone" kept "$(cat "$R/etc/hostname")"
# a new instance (the config changed): applied again
rm "$R/var/lib/dcs-init/instance-id"; run "$R" static >/dev/null
check "new instance: applied again"   monitoring-management "$(cat "$R/etc/hostname")"
# a hard power-off right after the first boot leaves empty files behind: the next boot must not trust the marker
: > "$N"
check "empty network file: run exits 0"    0 "$(run "$R" static)"
check "empty network file: written again"  "Address=192.168.2.100/24" "$(grep '^Address=' "$N")"
: > "$R/etc/hostname"; run "$R" static >/dev/null
check "empty host name: written again"     monitoring-management "$(cat "$R/etc/hostname")"
check "network files are numbered from 0"  10-dcs-0.network "$(basename "$N")"

echo "dcs-init: DHCP, two keys, two DNS servers"
R=$T/dhcp; run "$R" dhcp >/dev/null
N=$(ls "$R"/etc/systemd/network/10-dcs-*.network | head -1)
check "dhcp requested"                "DHCP=ipv4" "$(grep '^DHCP=' "$N")"
check "no static address"             0 "$(grep -c '^Address=' "$N")"
check "lower-case mac"                "MACAddress=bc:24:11:aa:bb:cc" "$(grep '^MACAddress=' "$N")"
check "two keys"                      2 "$(grep -c -E '^ssh-(ed25519|rsa) ' "$R/home/dcs/.ssh/authorized_keys")"
check "two dns servers"               "nameserver 9.9.9.9 nameserver 1.1.1.1" "$(grep '^nameserver' "$R/etc/resolv.conf" | tr '\n' ' ' | sed 's/ $//')"
check "no search line"                0 "$(grep -c '^search' "$R/etc/resolv.conf")"

echo "dcs-init: two cards, a /16 and a /26, two search domains"
R=$T/two; run "$R" two-nics >/dev/null
check "one file per card"             2 "$(ls "$R"/etc/systemd/network/10-dcs-*.network | wc -l)"
check "first card /16"                "Address=10.0.0.5/16" "$(grep -h '^Address=10.0' "$R"/etc/systemd/network/10-dcs-*.network)"
check "first card: MAC lower-cased"   "MACAddress=bc:24:11:00:00:01" "$(grep -h '^MACAddress=bc:24:11:00:00:01' "$R"/etc/systemd/network/10-dcs-*.network)"
check "second card /26"               "Address=172.16.4.9/26" "$(grep -h '^Address=172' "$R"/etc/systemd/network/10-dcs-*.network)"
check "second card has no gateway"    1 "$(grep -L '^Gateway=' "$R"/etc/systemd/network/10-dcs-*.network | wc -l)"
check "one search line, both domains" "search lab.test corp.test" "$(grep '^search' "$R/etc/resolv.conf")"
check "a single search line"          1 "$(grep -c '^search' "$R/etc/resolv.conf")"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
