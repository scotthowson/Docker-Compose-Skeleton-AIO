← [README](../README.md) · [Documentation](README.md) · [Proxmox & the fleet](PROXMOX.md)

# VM images

> **New in 4.0.** Purpose-built VM images for Proxmox: a **hub** image that boots straight into the DCS setup wizard, and
> a **node** image the hub clones for every stack. Debian 13, Ubuntu 26.04 LTS, Fedora 44 and Arch Linux, eight images in all.

An ordinary cloud image is a general-purpose server with a package installer bolted on. A DCS image is a **Docker
host and nothing else**: a kernel, systemd, ssh, Docker with Compose, the guest agent and the few tools DCS itself
runs on. No cloud-init, no snap, no desktop, no documentation, no second network manager.

| | Hub image | Node image |
|---|---|---|
| **What it is** | An appliance: import it, start it, open the dashboard | What the hub clones for each stack ("the VM is the stack") |
| **Has DCS inside** | Yes, the current release, started at first boot as a hub | No: a member gets its DCS from the hub when it joins, so versions always match |
| **You do** | Import once, open `http://<address>:3000`, follow the wizard | Nothing by hand: the hub uses it. Import it yourself only to build VMs without a hub |
| **Suggested size** | 2 vCPU · 4 GB RAM · 32 GB disk | 2 vCPU · 2 GB RAM · 16 GB disk (per stack) |

Pick the distribution you like; the four behave the same to DCS (which one the hub builds new VMs from is a setting of the *New VM* sheet):

| Distribution | Kernel | Security modules | Docker from | Good for |
|---|---|---|---|---|
| **Debian 13** (trixie) | 6.12, Debian's *cloud* kernel | AppArmor | Docker's repository | The smallest and quickest: the default. Virtual hardware only, see [hardware you pass through](#hardware-you-pass-through) |
| **Ubuntu 26.04 LTS** | 7.0 | AppArmor | Docker's repository | Long-term support, and the drivers for passed-through hardware |
| **Fedora 44** (Cloud Edition) | 7.2 | SELinux, **enforcing** | Docker's repository | SELinux confinement on the host; the drivers for passed-through hardware |
| **Arch Linux** (rolling) | 7.2, the newest there is | none by default (landlock, yama) | Arch's own `docker` package | The newest kernel and Docker on the day the image was built; you keep it current with `pacman -Syu` |

Which one? If you have no opinion, take **Debian**: it is the smallest, and on Proxmox all four start as quickly. If a VM gets a
GPU, a Zigbee/Z-Wave stick, a Coral or a physical network card by passthrough, take **Ubuntu**, **Fedora** or **Arch**.

## What is inside

- **The system:** systemd with `systemd-networkd`, `openssh-server` (keys only, no root login, no passwords), `sudo`,
  `qemu-guest-agent`, `fstrim.timer`, journald capped at 32 MB, kernel settings for a container host (inotify, `vm.max_map_count`).
- **The container stack:** Docker Engine and the Compose plugin from Docker's own repository (Arch: from Arch's), `containerd`,
  json-file logs rotated at 3 × 10 MB, `live-restore` on so containers survive a Docker restart (`dcs-container-stop.service` stops them, with `docker stop`'s ten seconds, when the VM powers off, so a container that ignores SIGTERM cannot hold the shutdown for 90 s).
- **The tools DCS runs on:** `bash`, `curl`, `jq`, `git`, `socat`, `openssl`, `python3`.
- **Not inside:** cloud-init, snapd, flatpak, a desktop, man pages and documentation, extra locales, a firewall manager
  (Docker manages its own rules; use the Proxmox firewall for the rest).
- **First boot in place of cloud-init:** a small script, `dcs-init`, reads the seed Proxmox attaches to the VM (host
  name, user, ssh keys, static or DHCP address, DNS) before the network starts. It is why a VM answers on ssh seconds
  after power-on. It survives a power cut at the worst moment: it flushes what it wrote before it marks the boot done,
  and checks its own files at every boot.
- **Growing the disk:** `qm resize` the disk and reboot; the partition and the file system follow by themselves.
- **Boot loader:** one disk, two ways in: legacy **BIOS** (SeaBIOS, Proxmox's default) and **UEFI** (OVMF; Secure Boot
  is not supported). Kernel updates keep working (`update-grub` on Debian and Ubuntu, a kernel-install plugin on Fedora, a
  pacman hook on Arch); the newest kernel is always the default entry.
- **Consoles:** the VGA console (Proxmox's *Console*, noVNC) shows the login prompt, and on a hub the address of the
  dashboard; the serial console (`qm terminal`, or a VM with a serial display) works too.
- **Arch:** the pacman keyring is made by each VM about a minute after its boot (never shipped in the image), so `pacman -Syu`
  works from then on. The image is what Arch's repositories held the day it was built: update it as you would any Arch system.
- **The hub image adds** a checkout of DCS and one service, `dcs-hub-init`, that runs once: it moves the checkout into
  the home of the VM's user, starts DCS as a hub (the API and the dashboard), installs the boot services and prints the
  dashboard address on the console. If the network is not up yet, it tries again at the next boot.

## How big and how quick

Measured with this repository's own test (`vm-images/tests/boot-test.sh`: KVM, 2 vCPU, 2 GB) and on a real Proxmox 9.2 node
(an i5-9600K running the rest of a small fleet), against the VM the hub built until now (a Debian cloud image with Docker installed).

| Image | Download | On disk (fresh) | RAM at idle¹ | Kernel + userspace² |
|---|---|---|---|---|
| Debian 13 · node | 236 MB | 635 MB | ~140 MB | 0.4 s + 1.5 s |
| Debian 13 · hub | 283 MB | 946 MB³ | ~270 MB | 0.3 s + 13 s⁴ |
| Ubuntu 26.04 · node | 373 MB | 815 MB | ~190 MB | 0.5 s + 0.7 s |
| Ubuntu 26.04 · hub | 420 MB | 1127 MB³ | ~275 MB | 0.5 s + 12 s⁴ |
| Fedora 44 · node | 383 MB | 829 MB | ~210 MB | 0.6 s + 1.3 s |
| Fedora 44 · hub | 430 MB | 1147 MB³ | ~335 MB | 0.6 s + 15 s⁴ |
| Arch Linux · node | 419 MB | 975 MB | ~180 MB | 0.2 s + 1.6 s |
| Arch Linux · hub | 466 MB | 1287 MB³ | ~310 MB | 0.2 s + 12 s⁴ |
| *Stock Debian 13 cloud image + Docker (what the hub baked before)* | *341 MB* | *1293 MB* | *~149 MB* | *(about 10 s on Proxmox)* |

¹ Memory in use without the file cache, Docker running. Docker itself (`dockerd` and `containerd`) is about 130 MB of that on every
system: the operating system around it is small, so **the saving is disk and time, not RAM**.
² Time from the kernel starting (the firmware's part comes on top) until the system is up and sshd answers.
³ After the first start: the hub has pulled the dashboard image.
⁴ A hub's first boot includes its own first start (setup, the dashboard image); later boots are as quick as a node's.

On the real node, from `qm start` until sshd answers a connection (a VM with 1 GB, 2 cores, an ordinary cloud-init drive):

| Image | Proxmox's defaults | With the boot menu wait off⁵ |
|---|---|---|
| Debian 13 | 7.9 s | **4.7 s** |
| Ubuntu 26.04 | 6.8 s | **4.7 s** |
| Fedora 44 | 7.9 s | **4.8 s** |
| Arch Linux | 6.8 s | **4.7 s** |

⁵ See [faster boots](#faster-boots-on-proxmox). Median of five boots on an i5-9600K node (Proxmox 9.2), measured in steps of about a second; about 1.5 s of every figure is `qm start` itself, before the VM exists. The first boot of a new VM takes about a second longer (it makes the host key).

The four are as quick as each other on Proxmox: what they differ in is disk, RAM and what their kernels can drive.

Every image passes 22 checks (hub: 27) before it is published, on both BIOS and UEFI: the seed is applied, Docker and Compose
answer, no unit failed and the kernel logged no error, the guest agent runs, the login prompt is on the VGA console, ssh takes
keys only and root has no password, the disk grows, a container runs, reaches the internet and answers on a published port,
the VM powers off in about a second and survives a power cut at its first boot. A node image also passes 8 more on BIOS, as the
member of a hub: a hub started from the repository runs the same member bootstrap the dashboard runs, the VM joins and reports its
host name, the Docker Engine card names where Docker comes from, a stack with a healthy and an unhealthy container starts from the
hub, a Docker restart leaves the API running, and the one-click engine update runs to its end (`vm-images/tests/member-check.sh`).

### Hardware you pass through

Debian's *cloud* kernel is the smallest there is, and it drives virtual hardware only. Ubuntu's, Fedora's and Arch's kernels carry
the drivers of real devices. If you pass a device through to a VM, check this table first:

| Driver for … | Debian 13 | Ubuntu 26.04 | Fedora 44 | Arch |
|---|:-:|:-:|:-:|:-:|
| Intel and AMD GPUs (`i915`, `xe`, `amdgpu`, `nouveau`): video transcoding, machine learning | – | ✓ | ✓ | ✓ |
| USB serial adapters (`cp210x`, `ftdi_sio`, `ch341`, `cdc_acm`): Zigbee, Z-Wave, Coral | – | ✓ | ✓ | ✓ |
| USB storage | – | ✓ | ✓ | ✓ |
| Physical network cards (`igb`, `ixgbe`, `e1000e`, `r8169`, `mlx5`) | `mlx5` | ✓ | ✓ | ✓ |
| Wi-Fi, Bluetooth, sound, TV tuners | – | ✓ | ✓ | ✓ |
| VirtIO, `vfio`, WireGuard, Btrfs, XFS, NFS, SMB, overlayfs, netfilter | ✓ | ✓ | ✓ | ✓ |

A Debian VM that needs one of these can switch kernels (`sudo apt install linux-image-amd64`, reboot); the image stays otherwise as it is. The *New VM* sheet of the dashboard shows the same fact under the operating system, from the `hardware` line of each image in `vm-images/images.json`.

### Faster boots on Proxmox

Proxmox starts every VM with `-boot menu=on`, and SeaBIOS as well as OVMF then wait about **2.6 seconds** at every boot for an
ESC key nobody presses. That wait is the largest single part of a DCS VM's start, it is the same for every operating system, and
it is not in the image: it is a setting of the VM, and only `root@pam` may change it (an API token cannot).

- `dcs-proxmox.sh` runs as root and switches it off for the VMs it makes (`--boot-menu` keeps Proxmox's default).
- The hub tries to switch it off for the VMs it builds. A token that may not is told so once, in the build's log, and the VM
  is left as it was; the VM's *Info* sheet on the Proxmox page shows the state and the one line to run on the node:

  ```bash
  qm set <vmid> --args '-boot menu=off,strict=on,reboot-timeout=1000'
  ```

  (`FLEET_VM_FAST_BOOT=false` stops the hub from trying.)
- Already-running VMs take it after the next stop and start (not a reboot from inside).

The images do their part: no wait for the console's size (systemd 259 and later ask the serial line, and wait), no
IPv6 duplicate-address check before "online", one ed25519 host key, no first-boot database rebuilds, and a cloud-init drive that
is not waited for when the VM has none. `vm-images/README.md` lists what was measured and what was tried and dropped.

## Get an image

Each release carries, next to the code:

```
dcs-hub-debian-13.qcow2     dcs-node-debian-13.qcow2
dcs-hub-ubuntu-26.04.qcow2  dcs-node-ubuntu-26.04.qcow2
dcs-hub-fedora-44.qcow2     dcs-node-fedora-44.qcow2
dcs-hub-arch.qcow2          dcs-node-arch.qcow2
SHA256SUMS                  images.json                  dcs-proxmox.sh
```

`images.json` is the list of images the release carries (the importer and the hub read it).

The images are qcow2 files compressed inside (no `.zst` to unpack). Check a download with `sha256sum -c SHA256SUMS --ignore-missing`.

**A release candidate** (a version with a dash, like `X.Y.Z-rc.N`) is a GitHub pre-release, and GitHub never calls a pre-release the
"latest release", so `dcs-proxmox.sh` does not find its images by itself. Name the release, and download the script from that release's
page first:

```bash
DCS_RELEASE_URL=https://github.com/scotthowson/dcs-orchestrator/releases/download/vX.Y.Z-rc.N bash dcs-proxmox.sh hub debian-13
```

A hub that runs the release candidate builds its VMs from the same release without being told, and shows the dashboard of the same version.

## Put one on Proxmox

### The one command

On the Proxmox host (the node's shell, as root):

```bash
# a hub, started, with your ssh key for the user "dcs" and a static address
bash dcs-proxmox.sh hub debian-13 --ip 192.168.1.50/24 --gateway 192.168.1.1 --dns 192.168.1.1

# a node template the hub (or you) clone for stacks
bash dcs-proxmox.sh node ubuntu-26.04 --template

# the same on Arch Linux
bash dcs-proxmox.sh hub arch
```

It downloads the image and checks it against `SHA256SUMS`, makes the VM with the settings below, and starts it. Useful options:

| Option | Meaning |
|---|---|
| `--vmid`, `--name` | The VM's id and name (default: the next free id; `dcs-hub` or `dcs-node-<distro>`) |
| `--storage`, `--bridge` | Disk storage (default `local-lvm`) and network bridge (default `vmbr0`) |
| `--cores`, `--memory`, `--disk` | Hub: 2 · 4096 MB · 32 GB. Node: 2 · 2048 MB · 16 GB |
| `--ip CIDR --gateway IP --dns IP` | A static address (default: DHCP) |
| `--user`, `--ssh-key FILE`, `--password` | The login: default user `dcs`, keys from `/root/.ssh/*.pub` of the host |
| `--firmware uefi` | UEFI instead of BIOS (q35 + OVMF) |
| `--boot-menu` | Keep Proxmox's boot menu wait (about 2.6 s at every boot); by default the script switches it off |
| `--template` | Make a template (tags `dcs;template`) instead of a VM |
| `--file PATH`, `--base-url URL` | An image you already have, or another place to download from |
| `--dry-run` | Show every command, change nothing |

The hub VM is tagged `dcs;hub` in Proxmox, starts with the host (`onboot`), and prints where to go next.

### By hand

```bash
# 1. the image where Proxmox looks for imports (a directory storage with the "Import" content type; "local" by default)
cp dcs-hub-debian-13.qcow2 /var/lib/vz/import/

# 2. the VM: the image becomes its disk, a cloud-init drive carries your login and address
qm create 200 --name dcs-hub --tags "dcs;hub" --ostype l26 --cores 2 --memory 4096 --cpu host \
  --scsihw virtio-scsi-single --scsi0 local-lvm:0,import-from=local:import/dcs-hub-debian-13.qcow2,discard=on,iothread=1,ssd=1 \
  --boot order=scsi0 --net0 virtio,bridge=vmbr0 --serial0 socket --agent enabled=1 --onboot 1 \
  --ide2 local-lvm:cloudinit --ciuser dcs --sshkeys ~/.ssh/id_ed25519.pub --ipconfig0 ip=dhcp
qm resize 200 scsi0 32G
qm start 200
```

For UEFI add `--machine q35 --bios ovmf --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0`; to skip the boot menu wait add
`--args '-boot menu=off,strict=on,reboot-timeout=1000'` ([faster boots](#faster-boots-on-proxmox)).

## The first ten seconds, and the first minute

1. **Power-on → ssh (seconds).** The firmware finds GRUB, GRUB loads the kernel, `dcs-init` reads the cloud-init seed
   (host name, user, keys, address), sshd starts. `ssh dcs@<address>` works from here.
2. **A hub's first start (about a minute).** `dcs-hub-init` moves DCS into `~/.Docker-Compose-Skeleton-AIO`, runs
   `setup.sh` as a hub, pulls the dashboard image and starts the API and the dashboard, installs the `dcs-api` and
   `dcs-stacks` services, and writes the address to the console. Watch it with `journalctl -u dcs-hub-init -f`.
3. **Open the dashboard.** `http://<the VM's address>:3000` opens the setup wizard: your admin account, the server
   settings, the Proxmox link (an API token), the stacks. It is on the console too (Proxmox → the VM → Console), and the
   guest agent shows the address in Proxmox's Summary.

From the hub, **New VM stack** and the wizard's VM step build the other VMs, and they offer the DCS node images first
(recommended): the hub has Proxmox download the one you pick from the release of its own version, checks it against
`SHA256SUMS`, and creates each VM from it directly. There is nothing to install and no template to bake, so a stack's VM is
up in about a minute. The cloud images stay in the list for anything else.

## Keeping an image current

- **The system:** `sudo apt update && sudo apt upgrade` (Debian, Ubuntu), `sudo dnf upgrade` (Fedora) or `sudo pacman -Syu`
  (Arch: always the whole system, never a single package; Docker's update button does the same there). Docker comes
  from its repository, so it updates with everything else. A new kernel is picked at the next boot (on Arch, reboot before
  loading modules you did not load before: the running kernel's module directory is gone after its update).
- **DCS:** the dashboard's Updates page, as before. Each release also publishes fresh images; an existing VM never needs to be rebuilt.
- **Rebuilding an image** from source: see [`vm-images/README.md`](../vm-images/README.md).

## Troubleshooting

| Symptom | Look here |
|---|---|
| No address on the console / ssh does not answer | The cloud-init drive is `ide2`? The bridge is right? `qm terminal <id>` shows the serial console (press Enter); `journalctl -u dcs-init` inside |
| *"no cloud-init drive"* in the log | The VM has no cloud-init drive: `qm set <id> --ide2 local-lvm:cloudinit`, then reboot; it falls back to DHCP meanwhile |
| The hub's dashboard does not open | `journalctl -u dcs-hub-init` (no internet to pull the dashboard image? it retries at every boot); `docker ps` should show `DCS-UI` |
| Fedora: something is denied | `sudo ausearch -m avc -ts recent`; the image runs SELinux enforcing. Docker's containers are not confined by SELinux (as on a standard Fedora Docker install) |
| A VM made from a template has the same host keys | It does not: keys are generated at each VM's first boot |
| The disk did not grow | `qm resize` first, then reboot: the partition grows at boot, the file system right after |
| The Console shows nothing after *Booting `DCS'* | Older images (before 4.0 final) had no login on the VGA console: use `qm terminal <id>`, or update the image |
| Arch: *pacman: signature is unknown trust* right after the first boot | The keyring is made about a minute after boot: wait, or `sudo systemctl start dcs-pacman-keyring.service` |

## Security notes

- The images hold **no secrets, no ssh keys and no passwords**; the host key (ed25519) is made on each VM's first boot, and Arch's package keyring about a minute after.
- ssh accepts keys only; root cannot log in; the login user has passwordless `sudo` because the hub drives its members with it.
- Fedora runs SELinux enforcing; Debian and Ubuntu run AppArmor; Arch has no mandatory access control beyond the kernel's defaults.
  Docker's containers keep Docker's usual default confinement.
- Images are checked against `SHA256SUMS`; a hub verifies the checksum when it downloads an image.
