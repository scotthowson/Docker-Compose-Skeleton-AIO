← [README](../README.md) · [Documentation](README.md) · [Proxmox & the fleet](PROXMOX.md)

# VM images

> **New in 4.0.** Purpose-built VM images for Proxmox: a **hub** image that boots straight into the DCS setup wizard, and
> a **node** image the hub clones for every stack. Debian 13, Ubuntu 26.04 LTS and Fedora 44, six images in all.

An ordinary cloud image is a general-purpose server with a package installer bolted on. A DCS image is a **Docker
host and nothing else**: a kernel, systemd, ssh, Docker with Compose, the guest agent and the few tools DCS itself
runs on. No cloud-init, no snap, no desktop, no documentation, no second network manager.

| | Hub image | Node image |
|---|---|---|
| **What it is** | An appliance: import it, start it, open the dashboard | What the hub clones for each stack ("the VM is the stack") |
| **Has DCS inside** | Yes, the current release, started at first boot as a hub | No: a member gets its DCS from the hub when it joins, so versions always match |
| **You do** | Import once, open `http://<address>:3000`, follow the wizard | Nothing by hand: the hub uses it. Import it yourself only to build VMs without a hub |
| **Suggested size** | 2 vCPU · 4 GB RAM · 32 GB disk | 2 vCPU · 2 GB RAM · 16 GB disk (per stack) |

Pick the distribution you like; the three behave the same to DCS:

| Distribution | Kernel | Security modules | Good for |
|---|---|---|---|
| **Debian 13** (trixie) | 6.12 cloud kernel | AppArmor | The smallest and quickest: the default |
| **Ubuntu 26.04 LTS** | 7.0 | AppArmor | If you run Ubuntu everywhere else |
| **Fedora 44** (Cloud Edition) | 7.2 | SELinux, **enforcing** | If you want SELinux confinement on the host |

## What is inside

- **The system:** systemd with `systemd-networkd`, `openssh-server` (keys only, no root login, no passwords), `sudo`,
  `qemu-guest-agent`, `fstrim.timer`, journald capped at 32 MB, kernel settings for a container host (inotify, `vm.max_map_count`).
- **The container stack:** Docker Engine and the Compose plugin from Docker's own repository, `containerd`, json-file
  logs rotated at 3 × 10 MB, `live-restore` on so containers survive a Docker restart.
- **The tools DCS runs on:** `bash`, `curl`, `jq`, `git`, `socat`, `openssl`, `python3`.
- **Not inside:** cloud-init, snapd, flatpak, a desktop, man pages and documentation, extra locales, a firewall manager
  (Docker manages its own rules; use the Proxmox firewall for the rest).
- **First boot in place of cloud-init:** a small script, `dcs-init`, reads the seed Proxmox attaches to the VM (host
  name, user, ssh keys, static or DHCP address, DNS) before the network starts. It is why a VM answers on ssh seconds
  after power-on. It survives a power cut at the worst moment: it flushes what it wrote before it marks the boot done,
  and checks its own files at every boot.
- **Growing the disk:** `qm resize` the disk and reboot; the partition and the file system follow by themselves.
- **Boot loader:** one disk, two ways in: legacy **BIOS** (SeaBIOS, Proxmox's default, and the fastest) and **UEFI**
  (OVMF; Secure Boot is not supported). Kernel updates keep working (`update-grub` on Debian and Ubuntu, a
  kernel-install plugin on Fedora).
- **The hub image adds** a checkout of DCS and one service, `dcs-hub-init`, that runs once: it moves the checkout into
  the home of the VM's user, starts DCS as a hub (the API and the dashboard), installs the boot services and prints the
  dashboard address on the console. If the network is not up yet, it tries again at the next boot.

## How big and how quick

Measured with this repository's own test (`vm-images/tests/boot-test.sh`) on a workstation with KVM, 2 vCPU, and
on a real Proxmox 9.2 node (a 9600K), against the VM the hub built until now (a Debian cloud image with Docker installed).

| Image | Download | On disk (fresh) | RAM at idle¹ | Power-on → ssh² |
|---|---|---|---|---|
| Debian 13 · node | 251 MB | 637 MB | ~145 MB | 2.5 s |
| Debian 13 · hub | 294 MB | 943 MB³ | ~265 MB | 2.5 s |
| Ubuntu 26.04 · node | 388 MB | 817 MB | ~156 MB | 4.7 s |
| Ubuntu 26.04 · hub | 431 MB | 1123 MB³ | ~268 MB | 4.7 s |
| Fedora 44 · node | 396 MB | 829 MB | ~205 MB | 4.7 s |
| Fedora 44 · hub | 439 MB | 1141 MB³ | ~343 MB | 4.7 s |
| *Stock Debian 13 cloud image + Docker (what the hub baked before)* | *341 MB* | *1293 MB* | *~149 MB* | *(11.7 s on Proxmox)* |

¹ Memory in use without the file cache, Docker running. Docker itself (`dockerd` and `containerd`) is about 130 MB of
that on every system: the operating system around it is small, so **the saving is disk and time, not RAM**.
² On the workstation, from starting QEMU. On the Proxmox node the same Debian node image answers on ssh 7.1 to 8.5 s
after `qm start`; the stock template needs 9.8 to 10.9 s. About 5.6 s of both is Proxmox and the firmware, not the image.
³ After the first start: the hub has pulled the dashboard image.

Every image passes 17 checks (hub: 22) before it is published: the seed is applied, Docker and Compose answer, no unit
failed, the guest agent runs, the disk grows, a container runs, reaches the internet and answers on a published port,
the VM powers off in about a second and survives a power cut at its first boot, on both BIOS and UEFI.

## Get an image

Each release carries, next to the code:

```
dcs-hub-debian-13.qcow2     dcs-node-debian-13.qcow2
dcs-hub-ubuntu-26.04.qcow2  dcs-node-ubuntu-26.04.qcow2
dcs-hub-fedora-44.qcow2     dcs-node-fedora-44.qcow2
SHA256SUMS                  dcs-proxmox.sh
```

The images are qcow2 files compressed inside (no `.zst` to unpack). Check a download with `sha256sum -c SHA256SUMS --ignore-missing`.

## Put one on Proxmox

### The one command

On the Proxmox host (the node's shell, as root):

```bash
# a hub, started, with your ssh key for the user "dcs" and a static address
bash dcs-proxmox.sh hub debian-13 --ip 192.168.1.50/24 --gateway 192.168.1.1 --dns 192.168.1.1

# a node template the hub (or you) clone for stacks
bash dcs-proxmox.sh node ubuntu-26.04 --template
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

For UEFI add `--machine q35 --bios ovmf --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0`.

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

- **The system:** `sudo apt update && sudo apt upgrade` (Debian, Ubuntu) or `sudo dnf upgrade` (Fedora). Docker comes
  from Docker's repository, so it updates with everything else. A new kernel is picked at the next boot.
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

## Security notes

- The images hold **no secrets, no ssh keys and no passwords**; host keys are made on each VM's first boot.
- ssh accepts keys only; root cannot log in; the login user has passwordless `sudo` because the hub drives its members with it.
- Fedora runs SELinux enforcing; Debian and Ubuntu run AppArmor. Docker's containers keep Docker's usual default confinement.
- Images are checked against `SHA256SUMS`; a hub verifies the checksum when it downloads an image.
