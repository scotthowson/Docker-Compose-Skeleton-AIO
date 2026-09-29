#!/usr/bin/env python3
"""grub-bios-embed — install GRUB's BIOS boot code onto a GPT disk image without root, mounts or loop devices.

grub-install / grub-bios-setup need the target to be a block device GRUB can look up in /dev and /sys, which a plain
image file inside a container is not. What they write is small and fixed, so this writes it directly, exactly as
util/setup.c of GRUB 2.12 does for an install into a BIOS boot partition:

  1. core.img (built by grub-mkimage) is written into the BIOS boot partition, sector after sector;
  2. the first sector of core.img ends with a list of the runs of sectors that follow it (start, length, load segment,
     12 bytes each, growing downwards from the end of the sector, ended by a zero entry): one run, since the BIOS
     boot partition is contiguous;
  3. boot.img (the boot code of sector 0) is patched with the address of core.img's first sector and written to
     sector 0, keeping the disk's own partition table (the GPT's protective MBR) and BPB area.

usage: grub-bios-embed DISK BIOS_BOOT_START_SECTOR BIOS_BOOT_SECTORS BOOT.IMG CORE.IMG
"""
import struct
import sys

SECTOR = 512
KERNEL_SECTOR = 0x5C      # u64: sector (LBA) of core.img's first sector
BOOT_DRIVE = 0x64         # 0xFF: the drive the BIOS booted from
DRIVE_CHECK = 0x66        # two bytes (a jmp for the floppy quirk): NOPs for a hard disk
BPB_START, BPB_END = 0x03, 0x5A
NT_MAGIC, PART_END = 0x1B8, 0x1FE
LIST_SIZE = 12            # start u64, length u16, segment u16
KERNEL_SEG = 0x800        # GRUB_BOOT_I386_PC_KERNEL_SEG; the first listed sector loads one sector (0x20 paragraphs) above it


def install(disk_path, start, room, boot_path, core_path):
    with open(boot_path, 'rb') as f:
        boot = bytearray(f.read())
    with open(core_path, 'rb') as f:
        core = bytearray(f.read())
    if len(boot) != SECTOR:
        raise SystemExit('grub-bios-embed: boot.img is not one sector')
    if len(core) <= SECTOR:
        raise SystemExit('grub-bios-embed: core.img is too small')
    nsec = (len(core) + SECTOR - 1) // SECTOR
    if nsec > room:
        raise SystemExit(f'grub-bios-embed: core.img needs {nsec} sectors, the BIOS boot partition has {room}')
    if nsec - 1 > 0xFFFF:
        raise SystemExit('grub-bios-embed: core.img is too large')
    core += b'\0' * (nsec * SECTOR - len(core))

    # the run of sectors after the first one, and the terminator below it
    first = SECTOR - LIST_SIZE
    struct.pack_into('<QHH', core, first, start + 1, nsec - 1, KERNEL_SEG + (SECTOR >> 4))
    struct.pack_into('<QHH', core, first - LIST_SIZE, 0, 0, 0)

    with open(disk_path, 'r+b') as disk:
        orig = disk.read(SECTOR)
        boot[BPB_START:BPB_END] = orig[BPB_START:BPB_END]
        boot[DRIVE_CHECK:DRIVE_CHECK + 2] = b'\x90\x90'
        boot[NT_MAGIC:PART_END] = orig[NT_MAGIC:PART_END]
        boot[BOOT_DRIVE] = 0xFF
        struct.pack_into('<Q', boot, KERNEL_SECTOR, start)
        disk.seek(start * SECTOR)
        disk.write(core)
        disk.seek(0)
        disk.write(boot)
    print(f'grub-bios-embed: core.img ({nsec} sectors) at sector {start}, boot code in sector 0')


if __name__ == '__main__':
    if len(sys.argv) != 6:
        raise SystemExit(__doc__)
    install(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5])
