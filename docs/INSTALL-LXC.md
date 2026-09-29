<sub>[← Getting started](GETTING-STARTED.md) · [Docs index](README.md) · Next: [Templates →](TEMPLATES.md)</sub>

# Install the hub in an LXC container

A Proxmox LXC container is the lightest home for a DCS hub: no second kernel, no virtual disk
controller, and it starts in seconds. This page builds one step by step: an unprivileged Debian 13
container with Docker inside, DCS set up as a hub, and boot services so it survives a reboot.

Every command below was run on a real host, and the output quoted is what came back.

| Tested with | |
|---|---|
| Proxmox VE | 9.2.2 (kernel 7.0.2-6-pve), root disk of the container on LVM-thin |
| Template | `debian-13-standard_13.6-1_amd64.tar.zst` |
| Docker | Engine 29.8.1, containerd 2.3.6, runc 1.5.1, Compose v5.5.1 (from get.docker.com) |
| DCS | 3.9.9 |

> [!IMPORTANT]
> Proxmox does not support Docker inside LXC containers itself, and its
> [container documentation](https://pve.proxmox.com/pve-docs/chapter-pct.html) recommends a VM when you
> need the strongest isolation or live migration. It works well, and this guide shows how, but read
> [LXC or VM](#lxc-or-vm) first. For the sturdier setup, use
> [the hub VM image or a VM from an ISO](GETTING-STARTED.md).

## What you will build

| Setting | Value | Why |
|---|---|---|
| Type | Unprivileged container | Root in the container is not root on the host |
| Features | `nesting=1`, `keyctl=1` | Docker needs nesting to mount its layers; keyctl is what Proxmox asks for Docker |
| CPU, memory, swap | 2 cores, 4 GB, 512 MB | Room for the hub and the apps you deploy on it |
| Disk | 32 GB | Images and app data grow over time |
| Network | A fixed address on your bridge | The VMs and the dashboard reach the hub there |
| Start at boot | Yes | The hub is up when the host is |
| Tags | `dcs`, `hub` | Filter the resource tree; DCS uses the same tags |

The examples use container ID `120`, the address `192.168.1.20/24` and the gateway `192.168.1.1`.
Replace them with yours.

## 1. Download the Debian 13 template

On the **Proxmox host** (its shell, or *Shell* in the web UI):

```bash
pveam update
pveam available --section system | grep debian-13
```

```text
system          debian-13-standard_13.6-1_amd64.tar.zst
system          debian-13-standard_13.6-1_arm64.tar.zst
```

Download the `amd64` one. The version in the name changes over time: use the one the list shows.

```bash
pveam download local debian-13-standard_13.6-1_amd64.tar.zst
```

## 2. Create the container

```bash
pct create 120 local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst \
  --hostname dcs-hub \
  --cores 2 --memory 4096 --swap 512 \
  --rootfs local-lvm:32 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.1.20/24,gw=192.168.1.1 \
  --unprivileged 1 --features nesting=1,keyctl=1 \
  --onboot 1 --tags 'dcs;hub' --ostype debian
pct start 120
```

On LVM-thin, `pct create` may warn that the thin volumes add up to more than the pool. That is thin
provisioning at work: the container only takes the space it uses.

<details>
<summary><b>The same in the web UI</b></summary>

*Create CT*:

1. *General*: CT ID and host name, tick **Unprivileged container**, set a root password or an ssh key.
2. *Template*: `local` → the Debian 13 template.
3. *Disks*: 32 GB. *CPU*: 2 cores. *Memory*: 4096 MB, swap 512 MB.
4. *Network*: `eth0` on `vmbr0`, IPv4 **Static** with your address and gateway.
5. *Confirm*: do not start yet.

Then on the container: *Options → Features*: tick **keyctl** and **Nesting**. *Options → Start at boot*: Yes.
*Summary → tags*: add `dcs` and `hub`. Start it.

</details>

## 3. Install Docker

Open a shell in the container from the host:

```bash
pct enter 120
```

You are root inside the container now. Update it, add the tools DCS runs on, then Docker:

```bash
apt-get update && apt-get -y upgrade
apt-get install -y curl ca-certificates git jq socat openssl python3 sudo
curl -fsSL https://get.docker.com | sh
docker run --rm hello-world
```

`hello-world` should print `Hello from Docker!`. Check how Docker runs in here:

```bash
docker info --format 'driver={{.Driver}} cgroup={{.CgroupVersion}} security={{.SecurityOptions}}'
```

```text
driver=overlayfs cgroup=2 security=[name=seccomp,profile=builtin name=cgroupns]
```

Docker uses overlayfs through the containerd snapshotter, and there is no AppArmor in the list: see
[caveats](#caveats).

## 4. Make a user for DCS

DCS runs as a normal user in the `docker` group, not as root: `setup.sh` refuses `sudo`, and the boot
services will not run an install that root owns.

```bash
useradd -m -s /bin/bash dcs
usermod -aG docker,sudo dcs
passwd dcs
```

The password matters: the dashboard's **Terminal** page and the OS updates on the System page ask for
this account's Linux password.

## 5. Install DCS as the hub

Still in the container, switch to the new user and run the setup:

```bash
su - dcs
git clone https://github.com/scotthowson/dcs-orchestrator.git ~/.Docker-Compose-Skeleton-AIO
cd ~/.Docker-Compose-Skeleton-AIO
DCS_UNATTENDED=true DCS_FLEET_ROLE=hub ./setup.sh
```

The setup recognises the container, starts the API, pulls and starts the dashboard, and prints where to
go. From the test run (addresses replaced):

```text
  [INFO]  Operating system: Debian GNU/Linux 13 (trixie)
  [INFO]  Machine         : LXC container — most likely on a Proxmox host
  [OK]    Role: hub — Proxmox is linked here and the other VMs join this DCS
  ...
  [OK]    API server started (PID 4323, listening on 0.0.0.0:9876)
  ...
  [OK]    DCS-UI is healthy
  [WARN]  DCS_ADMIN_PASSWORD is not set — the first account is created in the wizard

  ║   Open your browser to complete setup:                  ║
  ║   Local:   http://localhost:3000                        ║
  ║   Network: http://192.168.1.20:3000                     ║
```

The warning is expected: you create the first admin in the wizard. Without the two `DCS_` variables,
`./setup.sh` asks its questions instead: choose **2) Hub**, and it offers to link Proxmox right away.

Go back to root with `exit`.

## 6. Start at boot

As root in the container. Answer **Y** when it asks to start the API server now.

```bash
/home/dcs/.Docker-Compose-Skeleton-AIO/.scripts/install-service.sh
```

```text
✓ Created dcs-api.service
✓ Created dcs-stacks.service
...
✓ API server started (dcs-api.service, 0.0.0.0:9876)
```

`dcs-api` hands over from the API that the setup started and runs it under systemd. `dcs-stacks` starts
your stacks in order at every boot.

## 7. Check it

In the container:

```bash
curl -s http://127.0.0.1:9876/ping
```

```text
{"ok": true, "version": "3.9.9", "api_version": "1.16.0", "time": 1790699294}
```

From your PC, open the dashboard. It shows the setup wizard, waiting for its first admin:

```text
http://192.168.1.20:3000
```

Leave the container with `exit`. Then go on with [the first ten minutes](GETTING-STARTED.md#the-first-ten-minutes):
link Proxmox in the wizard's *Server* step and the hub can build its first VM.

## What the test showed

- **Reboot.** After `pct reboot 120` the API answered again 8 seconds later. `dcs-stacks` then started
  all ten stacks in order, waiting for each one's health, and was done after about four minutes
  (`Total: 10 | Succeeded: 10 | Failed: 0`).
- **Footprint.** With the dashboard, its Redis and the ten placeholder stacks running, the container
  used about 190 MB of memory and 1.6 GB of disk.
- **The locked door.** Before the first admin exists, the API answers only its setup: `/ping` and
  `/setup/status` work, `/status` answers `401`.
- **The Terminal page** unlocked with the `dcs` account's password and ran commands as `dcs`.
  `GET /system` reported `virtualization: lxc` and no guest agent.

## Caveats

**Nesting is not optional.** Without `nesting=1`, Proxmox warns when the container starts
(`WARN: Systemd 257 detected. You may need to enable nesting.`), and Docker cannot mount any image:

```text
docker: Error response from daemon: failed to mount /tmp/containerd-mount…: mount source: "overlay",
… fstype: overlay … err: permission denied
```

Turn it on with `pct set 120 --features nesting=1,keyctl=1` and restart the container.

**keyctl.** Proxmox's documentation asks for `keyctl=1` to run Docker in an unprivileged container. In
our test `hello-world` and the DCS stacks also ran with nesting alone; keep keyctl on anyway.

**No AppArmor for your containers.** Inside an unprivileged LXC, Docker cannot load its own AppArmor
profile: `docker info` lists only seccomp and cgroupns, and the dashboard's `apparmor=docker-default`
option has no effect. Your apps are still fenced in by the container's own AppArmor profile on the host,
by seccomp and by user namespaces, but they get one layer less than in a VM.

**One kernel for all.** The container shares the host's kernel. Kernel settings some apps ask for (for
example `vm.max_map_count` for search engines) must be set on the Proxmox host: in the container,
`sysctl -w vm.max_map_count=262144` answers `permission denied`.

**No sudo, no guest agent.** The Debian template ships without `sudo` (installed in step 3). There is no
QEMU guest agent in a container: Proxmox reads a container's addresses without one, and the hub finds its
own guest by address or name.

**Tested storage.** The test ran on LVM-thin with ext4. Other storages were not tested for this guide.

## LXC or VM

| | LXC container | VM |
|---|---|---|
| Memory and start-up | Lighter; `pct start` returned in about 2 s | A kernel of its own; boots in seconds |
| Isolation | Shares the host kernel; Docker inside has no AppArmor profile of its own | Its own kernel; Docker's full confinement |
| Proxmox's view | Docker in LXC is not supported by Proxmox | The recommended way to run Docker |
| Kernel settings | Only on the host | Inside the VM |
| Live migration | Restart migration only | Live migration |
| How the hub finds itself | By address or name | By SMBIOS id, address or name, and the guest agent |
| Fits | A small hub that runs the dashboard and a few services | A hub that also runs heavier apps, and every member VM |

The VMs that a hub builds are always VMs. The hub itself can be either.

## Remove it

On the Proxmox host. This deletes the container and its disk.

```bash
pct stop 120
pct destroy 120 --purge
```

The downloaded template stays in `local` for the next container; `pveam remove local:vztmpl/<name>`
deletes it.
