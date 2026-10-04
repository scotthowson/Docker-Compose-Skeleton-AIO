#!/bin/bash
# =============================================================================
# dcs-grubcfg against fake /boot directories (no root, no VM): the newest kernel is the default, on every distribution's naming.
# Usage: vm-images/tests/dcs-grubcfg-test.sh   (exit status 0 = all passed)
# =============================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$HERE/../common/overlay/usr/local/sbin/dcs-grubcfg"
CONF="$HERE/../common/overlay/etc/default/grub.d"
PASS=0; FAIL=0
check() { if [[ "$3" == "$2" ]]; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL + 1)); printf '  FAIL %s (expected %s, got %s)\n' "$1" "$2" "$3"; fi; }
T=$(mktemp -d); trap 'command rm -rf "$T"' EXIT
# mk ROOT kernel-file... : kernels with an initramfs each (initrd.img-X or initramfs-X.img by the name style)
mk() { local r=$1; shift; mkdir -p "$r/boot" "$r/etc/default"; cp -r "$CONF" "$r/etc/default/grub.d"; for k in "$@"; do : > "$r/boot/vmlinuz-$k"; if [[ $k == [0-9]* && $r == *deb* ]]; then : > "$r/boot/initrd.img-$k"; else : > "$r/boot/initramfs-$k.img"; fi; done; }
gen() { DCS_ROOT="$1" bash "$GEN" >/dev/null 2>&1; echo $?; }
first() { grep -m1 'linux /boot/vmlinuz-' "$1/boot/grub/grub.cfg" | sed 's|.*/boot/vmlinuz-\([^ ]*\) .*|\1|'; }
titles() { grep -o "^menuentry '[^']*'" "$1/boot/grub/grub.cfg" | sed "s/menuentry //" | tr '\n' ' ' | sed 's/ $//'; }

echo "dcs-grubcfg: Debian names (the version is in the file name)"
mk "$T/deb" 6.12.41+deb13-cloud-amd64 6.12.48+deb13-cloud-amd64 6.1.0-9-amd64
check "exits 0"                          0 "$(gen "$T/deb")"
check "the newest kernel is the default" 6.12.48+deb13-cloud-amd64 "$(first "$T/deb")"
check "one entry per kernel"             3 "$(grep -c '^menuentry' "$T/deb/boot/grub/grub.cfg")"
check "the older ones are named"         "'DCS' 'DCS (kernel 6.12.41+deb13-cloud-amd64)' 'DCS (kernel 6.1.0-9-amd64)'" "$(titles "$T/deb")"
check "boots by label"                   1 "$(grep -c 'root=LABEL=dcs-root ro' "$T/deb/boot/grub/grub.cfg" | awk '$1 > 0 {print 1}')"
check "the serial console is set up"     1 "$(grep -c 'serial --unit=0 --speed=115200' "$T/deb/boot/grub/grub.cfg" | awk '$1 > 0 {print 1}')"

echo "dcs-grubcfg: Debian's standard kernel next to the cloud one (how a VM gets USB and GPU drivers)"
mk "$T/deb2" 6.12.111+deb13-cloud-amd64 6.12.111+deb13-amd64
gen "$T/deb2" >/dev/null
check "same version: the standard kernel is the default" 6.12.111+deb13-amd64 "$(first "$T/deb2")"
check "the cloud kernel stays as the second entry" "'DCS' 'DCS (kernel 6.12.111+deb13-cloud-amd64)'" "$(titles "$T/deb2")"
mk "$T/deb3" 6.12.111+deb13-amd64 6.12.115+deb13-cloud-amd64
gen "$T/deb3" >/dev/null
check "a newer cloud kernel still wins over an older standard one" 6.12.115+deb13-cloud-amd64 "$(first "$T/deb3")"

echo "dcs-grubcfg: Fedora names, a two-digit version against a one-digit one"
mk "$T/fed" 6.9.12-200.fc44.x86_64 6.19.7-200.fc44.x86_64
gen "$T/fed" >/dev/null
check "6.19 is newer than 6.9"           6.19.7-200.fc44.x86_64 "$(first "$T/fed")"

echo "dcs-grubcfg: Arch names (the package, not the version), the newest first"
mk "$T/arch" linux linux-lts
mkdir -p "$T/arch/usr/lib/modules/7.2.7-arch1-1" "$T/arch/usr/lib/modules/6.18.54-1-lts"
echo linux > "$T/arch/usr/lib/modules/7.2.7-arch1-1/pkgbase"; echo linux-lts > "$T/arch/usr/lib/modules/6.18.54-1-lts/pkgbase"
check "exits 0"                          0 "$(gen "$T/arch")"
check "linux 7.2 is the default over linux-lts 6.18" linux "$(first "$T/arch")"
check "the LTS kernel is the second entry" "'DCS' 'DCS (kernel linux-lts)'" "$(titles "$T/arch")"
mkdir -p "$T/arch2/usr/lib/modules/7.2.7-arch1-1" "$T/arch2/usr/lib/modules/6.18.54-1-lts"
mk "$T/arch2" linux-lts linux
echo linux > "$T/arch2/usr/lib/modules/7.2.7-arch1-1/pkgbase"; echo linux-lts > "$T/arch2/usr/lib/modules/6.18.54-1-lts/pkgbase"
gen "$T/arch2" >/dev/null
check "the order does not depend on the file names' order" linux "$(first "$T/arch2")"
mk "$T/arch3" linux
check "one Arch kernel, the fallback initramfs is not an entry" 1 "$(gen "$T/arch3" >/dev/null; grep -c '^menuentry' "$T/arch3/boot/grub/grub.cfg")"

echo "dcs-grubcfg: no kernel"
mkdir -p "$T/none/boot" "$T/none/etc/default"
check "fails without a kernel"           1 "$(gen "$T/none")"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
