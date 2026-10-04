# vm-images

Everything that builds, tests and ships the DCS VM images (user documentation: [docs/VM-IMAGES.md](../docs/VM-IMAGES.md)).

**[`images.json`](images.json) is the one list of images.** The build (`build.sh`), CI (the matrix of `.github/workflows/vm-images.yml`),
the Proxmox importer, the API's image catalogue (`_fleet_dcs_images_json`) and the documentation all read it or are checked against
it: `tests/lint.sh` fails when a distribution is in one place and not in another.

```
build.sh DISTRO ROLE [--test] [--firmware bios|uefi|both] [--ref GIT_REF] [--size MB]   DISTRO: debian-13 | ubuntu-26.04 | fedora-44 | arch   ROLE: node | hub
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
| `<distro>/overlay/` | Distribution specifics (Fedora: dracut, the kernel-install plugin. Arch: the mkinitcpio settings, the pacman hook that writes `grub.cfg`, the keyring timer) |
| `tools/` | The tools image and `assemble.sh` (tar → ext4 with `mke2fs -d` → GPT with a BIOS boot partition, an ESP and the root → qcow2), `grub-bios-embed.py` (GRUB's BIOS boot code written to a plain file, the work `grub-bios-setup` does on a block device) |
| `tests/` | `boot-test.sh` (the Proxmox-like boot and its checks; `--seed-bus scsi` puts the cloud-init drive on SCSI), `member-check.sh` (a node image's BIOS run also makes it a member of a hub started from this checkout; `--no-member` skips it), `dcs-init-test.sh` (the first-boot script against the seeds Proxmox writes), `dcs-grubcfg-test.sh` (the boot menu writer against every distribution's kernel names), `measure.sh` (the same numbers for any running VM) |
| `proxmox/dcs-proxmox.sh` | The one-command importer for the Proxmox host |

## How a disk boots

GPT: partition 1 is a 1 MiB **BIOS boot partition** (GRUB's core image, for SeaBIOS), 2 an **EFI system partition** (one
standalone GRUB, for OVMF), 3 the root file system, labelled `dcs-root`. Both loaders find the root by label and read
`/boot/grub/grub.cfg` from it, so a kernel update inside the VM never touches the loaders. The file is written by
`dcs-grubcfg` everywhere: on Debian and Ubuntu from the kernel hooks `/etc/kernel/postinst.d/zz-dcs-grubcfg` and `postrm.d/zz-dcs-grubcfg` (`grub-common` has no `update-grub`), on Fedora (called from `/etc/kernel/install.d/95-dcs-boot.install`) and on Arch (called from the pacman hook `99-dcs-grubcfg.hook`, after mkinitcpio's own hook has copied the kernel to `/boot`). The newest kernel is the default entry on every distribution.
The kernel command line comes from `/etc/default/grub.d/*.cfg` in the image (`05-dcs.cfg` common, `10-lsm.cfg` per distribution).

## Adding a distribution

1. An entry in [`images.json`](images.json) (id, name, family, one-line summary) and `<distro>/Dockerfile` with targets `node` and `hub` (copy the closest one). It must install a kernel with an initramfs
   that finds a virtio SCSI/block disk, systemd, `openssh-server`, `sudo`, `qemu-guest-agent`, Docker with Compose,
   `curl jq git socat openssl python3`, enable `dcs-init.service` and friends **one by one** (fail the build if a unit is missing),
   and write `/etc/default/grub.d/10-lsm.cfg`.
2. `./build.sh <distro> node --test`, then the same for `hub`.
3. `KNOWN_DISTROS` in `proxmox/dcs-proxmox.sh` and the distribution in `docs/VM-IMAGES.md` and this file: `tests/lint.sh` names whatever is missing.

## Pitfalls we met (so you do not)

- Enable systemd units one at a time and `systemctl is-enabled` each: a missing unit in a batch aborts the whole batch, silently in a pipe.
- AppArmor: keep `/etc/apparmor.d/abi`, Docker's profile includes it.
- Hard power-off right after the first boot leaves 0-byte files (ext4 allocates later): flush before marking a boot done (`dcs-init` does).
- Fedora's `/usr/local/sbin` is a symlink: copy overlays with `tar --keep-directory-symlink`.
- Never kill test VMs with `pkill -f <pattern>` that also appears in your own command line.
- **A drop-in cannot take a dependency away.** `After=` (empty) and then a new list in a drop-in does not remove what the vendor unit lists (systemd 257 to 262
  all keep it). Docker's unit waits for `network-online.target`; what makes that quick is that the card gets no IPv6 link-local address
  (`LinkLocalAddressing=no` in the `.network` file `dcs-init` writes, unless the seed asks for IPv6), whose duplicate-address check kept
  `systemd-networkd-wait-online` busy for one to two seconds.
- **systemd 259 and later ask the console for its size at boot** (a cursor-position query) and wait a third of a second per answer. A VM's
  serial line answers nothing. `systemd.tty.term.console=dumb systemd.tty.term.ttyS0=vt220` on the kernel command line (`05-dcs.cfg`) ends the questions
  without turning the serial login into a dumb terminal.
- **`var-lib-machines.mount` holds `local-fs.target` back by a second** on those systemd versions (its start waits for the rate-limited mount
  monitor). Nothing here uses `/var/lib/machines.raw`, so the unit is masked.
- **`/etc/.updated` and `/var/.updated`** (written by `assemble.sh`) tell systemd that `/etc` and `/var` are up to date; without them every
  `ConditionNeedsUpdate=` unit (hwdb, ldconfig, sysusers, the journal catalog) runs once at the first boot of every VM.
- **Host keys are ed25519 only.** A RSA key takes 0.2 to 0.8 s to make at every first boot; `sshd_config.d/10-dcs.conf` names the one key, and
  the units that would make the others (`sshdgenkeys.service` on Arch, `sshd-keygen@rsa/ecdsa` on Fedora) are masked.
- **The test disk is read uncompressed** (`boot-test.sh` converts the image first): QEMU decompresses a compressed qcow2 in its main loop and
  the guest stalls for a second on its first reads, which Proxmox's imported copy never does.
- Arch: `sshd -T` prints option names in CamelCase (the others in lower case); `hostname` is not installed (`dcs-init` writes
  `/proc/sys/kernel/hostname`); the pacman keyring is made by every VM about a minute after its boot (`dcs-pacman-keyring.timer`), not by the image.
- Tried and dropped, measured: the cloud-init CD-ROM's drivers (`ata_piix sr_mod isofs`) in the initramfs make Debian slower (initramfs-tools waits
  for the devices to settle) and change nothing on Ubuntu, Fedora and Arch.
