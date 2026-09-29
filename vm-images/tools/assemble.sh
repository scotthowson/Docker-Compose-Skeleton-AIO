#!/bin/bash
# =============================================================================
# assemble.sh — runs INSIDE the tools container (no mounts, no loop devices, no /dev):
#   /in/rootfs.tar  ->  /out/<name>.raw  (GPT: BIOS boot partition + EFI system partition + root)  ->  /out/<name>.qcow2
# usage: assemble.sh NAME [DISK_MB]
# One disk that boots both ways: legacy BIOS (SeaBIOS, Proxmox's default and fast) through GRUB in the BIOS boot
# partition, and UEFI (OVMF) through a standalone GRUB EFI file on the ESP. Either one finds the root partition by
# label and reads /boot/grub/grub.cfg from it, so kernel upgrades inside the VM (update-grub) never touch the
# boot loader.
# =============================================================================
set -euo pipefail
NAME="${1:?name}"; DISK_MB="${2:-4096}"; ESP_MB=48
IN=/in/rootfs.tar; OUT=/out; W=$(mktemp -d /tmp/assemble.XXXXXX); HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
die() { echo "assemble: $*" >&2; exit 1; }
[[ -f "$IN" ]] || die "no $IN"
mkdir -p "$W/rootfs" "$OUT"

echo "assemble: unpacking the root file system"
tar -xpf "$IN" -C "$W/rootfs" --numeric-owner

# docker export adds its own runtime files; the VM sets these up itself at boot
rm -f "$W/rootfs/.dockerenv"

K=$(ls "$W"/rootfs/boot/vmlinuz-* 2>/dev/null | sort -V | tail -1); [[ -n "$K" ]] || die "no kernel in /boot"
KV=${K##*/vmlinuz-}
[[ -f "$W/rootfs/boot/initrd.img-$KV" ]] || die "no initramfs for $KV"
echo "assemble: kernel $KV"

# what mounts: the root by label, growing with the disk; the ESP stays unmounted unless asked for
cat > "$W/rootfs/etc/fstab" <<FSTAB
LABEL=dcs-root / ext4 defaults,noatime,discard,x-systemd.growfs 0 1
LABEL=DCS-ESP /boot/efi vfat umask=0077,noauto,nofail 0 2
FSTAB
mkdir -p "$W/rootfs/boot/efi" "$W/rootfs/boot/grub"

# the boot loader settings live in the image (/etc/default/grub.d/dcs.cfg), so update-grub in the VM and this first grub.cfg agree
GRUB_CMDLINE_LINUX=""; GRUB_CMDLINE_LINUX_DEFAULT=""; GRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200"
# shellcheck disable=SC1090
. "$W/rootfs/etc/default/grub.d/dcs.cfg"
CMDLINE="root=LABEL=dcs-root ro $GRUB_CMDLINE_LINUX_DEFAULT $GRUB_CMDLINE_LINUX"
cat > "$W/rootfs/boot/grub/grub.cfg" <<CFG
set default=0
set timeout=0
if $GRUB_SERIAL_COMMAND; then
    terminal_input serial console
    terminal_output serial console
fi
menuentry 'DCS' {
    search --no-floppy --label --set=root dcs-root
    linux /boot/vmlinuz-$KV $CMDLINE
    initrd /boot/initrd.img-$KV
}
CFG

echo "assemble: root file system image"
ROOT_MB=$((DISK_MB - ESP_MB - 3))
mke2fs -q -t ext4 -L dcs-root -m 1 -E lazy_itable_init=1,lazy_journal_init=1 -d "$W/rootfs" "$W/root.img" "${ROOT_MB}M"

echo "assemble: EFI system partition with a standalone GRUB"
truncate -s "${ESP_MB}M" "$W/esp.img"
mkfs.vfat -F 32 -n DCS-ESP "$W/esp.img" >/dev/null
cat > "$W/embedded.cfg" <<EMB
search --no-floppy --label --set=root dcs-root
configfile (\$root)/boot/grub/grub.cfg
EMB
grub-mkstandalone -O x86_64-efi -o "$W/BOOTX64.EFI" --modules="part_gpt part_msdos fat ext2 normal configfile linux search search_label echo test all_video efi_gop gzio" \
    "boot/grub/grub.cfg=$W/embedded.cfg" >/dev/null 2>&1
mmd -i "$W/esp.img" ::/EFI ::/EFI/BOOT
mcopy -i "$W/esp.img" "$W/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI

echo "assemble: BIOS boot code (GRUB core image for the BIOS boot partition)"
cat > "$W/bios.cfg" <<EMB
search --no-floppy --label --set=root dcs-root
set prefix=(\$root)/boot/grub
configfile \$prefix/grub.cfg
EMB
grub-mkimage -O i386-pc -d /usr/lib/grub/i386-pc -o "$W/core.img" -c "$W/bios.cfg" -p /boot/grub \
    biosdisk part_gpt part_msdos ext2 normal boot linux configfile search search_label echo test gzio all_video serial terminal

echo "assemble: the disk"
BIOS_START=2048; BIOS_SECT=2048                       # 1 MiB at 1 MiB
ESP_START=$((BIOS_START + BIOS_SECT)); ESP_SECT=$((ESP_MB * 2048))
ROOT_START=$((ESP_START + ESP_SECT))
truncate -s "${DISK_MB}M" "$W/disk.raw"
printf 'label: gpt\nstart=%d, size=%d, type=21686148-6449-6E6F-744E-656564454649, name="BIOS"\nstart=%d, size=%d, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="DCS-ESP"\nstart=%d, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, name="dcs-root"\n' \
    "$BIOS_START" "$BIOS_SECT" "$ESP_START" "$ESP_SECT" "$ROOT_START" | sfdisk -q "$W/disk.raw"
dd if="$W/esp.img" of="$W/disk.raw" bs=512 seek="$ESP_START" conv=notrunc,sparse status=none
dd if="$W/root.img" of="$W/disk.raw" bs=512 seek="$ROOT_START" conv=notrunc,sparse status=none
python3 "$HERE/grub-bios-embed.py" "$W/disk.raw" "$BIOS_START" "$BIOS_SECT" /usr/lib/grub/i386-pc/boot.img "$W/core.img"
[[ "${DCS_KEEP_RAW:-0}" == 1 ]] && cp --sparse=always "$W/disk.raw" "$OUT/$NAME.raw"

echo "assemble: qcow2"
qemu-img convert -f raw -O qcow2 -c -o compression_type=zstd "$W/disk.raw" "$OUT/$NAME.qcow2"
( cd "$OUT" && sha256sum "$NAME.qcow2" > "$NAME.qcow2.sha256" )
echo "assemble: done — $(du -h "$OUT/$NAME.qcow2" | cut -f1) qcow2, $(du -h "$W/disk.raw" | cut -f1) as a raw disk"
