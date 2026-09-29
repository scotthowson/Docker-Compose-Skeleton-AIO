# vm-images

Everything that builds, tests and ships the DCS VM images (user documentation: [docs/VM-IMAGES.md](../docs/VM-IMAGES.md)).

```
build.sh DISTRO ROLE [--test] [--firmware bios|uefi|both] [--ref GIT_REF] [--size MB]   DISTRO: debian-13 | ubuntu-26.04 | fedora-44   ROLE: node | hub
```

`build.sh` builds the root file system in Docker, exports it, and assembles a bootable disk **without root** (no mounts,
no loop devices): `out/dcs-ROLE-DISTRO.qcow2` and its `.sha256`. `--test` boots the result the way Proxmox does and checks it.
Needs Docker, and for `--test` QEMU with KVM, OVMF and genisoimage. The tools container runs with `--cap-add SYS_ADMIN`
(Fedora's SELinux labels are written as extended attributes).

## Layout

| Path | What |
|---|---|
| `<distro>/Dockerfile` | The root file system. Target `node`; target `hub` = node + the DCS checkout (build context `dcs`, a clean clone of `--ref`) |
| `common/overlay/` | Files every image gets: `dcs-init` (first boot from the Proxmox seed), `dcs-grubcfg`, units, sysctl, journald, sshd, Docker, growpart config, boot loader settings |
| `hub/overlay/` | The hub only: `dcs-hub-init` and its unit |
| `<distro>/overlay/` | Distribution specifics (Fedora: dracut, the kernel-install plugin) |
| `tools/` | The tools image and `assemble.sh` (tar → ext4 with `mke2fs -d` → GPT with a BIOS boot partition, an ESP and the root → qcow2), `grub-bios-embed.py` (GRUB's BIOS boot code written to a plain file, the work `grub-bios-setup` does on a block device) |
| `tests/` | `boot-test.sh` (the Proxmox-like boot and its checks), `dcs-init-test.sh` (the first-boot script against the seeds Proxmox writes), `measure.sh` (the same numbers for any running VM) |
| `proxmox/dcs-proxmox.sh` | The one-command importer for the Proxmox host |

## How a disk boots

GPT: partition 1 is a 1 MiB **BIOS boot partition** (GRUB's core image, for SeaBIOS), 2 an **EFI system partition** (one
standalone GRUB, for OVMF), 3 the root file system, labelled `dcs-root`. Both loaders find the root by label and read
`/boot/grub/grub.cfg` from it, so a kernel update inside the VM never touches the loaders. The file is written by
`update-grub` on Debian and Ubuntu, and by `dcs-grubcfg` (called from `/etc/kernel/install.d/95-dcs-boot.install`) on Fedora.
The kernel command line comes from `/etc/default/grub.d/*.cfg` in the image (`05-dcs.cfg` common, `10-lsm.cfg` per distribution).

## Adding a distribution

1. `<distro>/Dockerfile` with targets `node` and `hub` (copy the closest one). It must install a kernel with an initramfs
   that finds a virtio SCSI/block disk, systemd, `openssh-server`, `sudo`, `qemu-guest-agent`, Docker with Compose,
   `curl jq git socat openssl python3`, enable `dcs-init.service` and friends **one by one** (fail the build if a unit is missing),
   and write `/etc/default/grub.d/10-lsm.cfg`.
2. `./build.sh <distro> node --test`, then the same for `hub`.
3. Add it to `proxmox/dcs-proxmox.sh`'s list and to `docs/VM-IMAGES.md`.

## Pitfalls we met (so you do not)

- Enable systemd units one at a time and `systemctl is-enabled` each: a missing unit in a batch aborts the whole batch, silently in a pipe.
- AppArmor: keep `/etc/apparmor.d/abi`, Docker's profile includes it.
- Hard power-off right after the first boot leaves 0-byte files (ext4 allocates later): flush before marking a boot done (`dcs-init` does).
- Fedora's `/usr/local/sbin` is a symlink: copy overlays with `tar --keep-directory-symlink`.
- Never kill test VMs with `pkill -f <pattern>` that also appears in your own command line.
