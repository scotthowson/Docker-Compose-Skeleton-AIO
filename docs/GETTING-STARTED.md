<sub>[← README](../README.md) · [Docs index](README.md) · Next: [Hub in an LXC container →](INSTALL-LXC.md)</sub>

# Getting started

There are four ways to run DCS. Pick one, install, then read
[the first ten minutes](#the-first-ten-minutes).

<p align="center">
  <img src="img/install-paths.svg" alt="Four ways to install: the hub VM image, an LXC container, any Docker host, or a VM from an installer ISO" width="100%">
</p>

| | A · Hub VM image | B · LXC container | C · Any Docker host | D · VM from an ISO |
|---|---|---|---|---|
| **Best for** | A new Proxmox fleet | The lightest hub on Proxmox | A single server, a NAS, a cloud VM | Proxmox, your own OS install |
| **You need** | Proxmox, a machine with Docker to build the image | Proxmox | Linux and Docker | Proxmox and a Debian or Ubuntu ISO |
| **Docker comes from** | The image | You install it | You install it | You install it |
| **Status** | New in 4.0 | Tested on Proxmox 9.2 | The classic install | Standard |

> [!TIP]
> Not sure? On Proxmox, take **A** or **D**: a VM is the sturdier home for Docker. Anywhere else, take **C**.

## Before you start

- **An address for the server.** Give the hub a fixed IP address on your LAN. The examples here use
  `192.168.1.20` for the hub and `192.168.1.2` for Proxmox; use your own.
- **A domain (optional).** For `https://app.your-domain` addresses you need a domain on Cloudflare and an
  API token with *Zone → DNS → Edit*. Without a token, Traefik uses the HTTP challenge on port 80 instead.
  You can add both later.
- **A Proxmox API token (for the fleet).** The wizard asks for it. [Link Proxmox](#2-link-proxmox) below
  shows how to make one.

## A. The hub VM image on Proxmox

*New in 4.0.* A ready VM with Docker and DCS inside. It starts DCS as a hub on its first boot, and
you finish in the browser.

> [!NOTE]
> Coming with 4.0: a download link for the image and a one-line importer for the Proxmox shell.
> Until then, build the image yourself and import it by hand, as shown below.

**1. Build the image.** On any Linux machine with Docker and git. No root needed; the tools run in containers.

```bash
git clone https://github.com/scotthowson/dcs-orchestrator.git
cd dcs-orchestrator
vm-images/build.sh debian-13 hub
```

This writes `vm-images/out/dcs-hub-debian-13.qcow2` and its `.sha256`. Add `--test` to boot the image
in QEMU and check it the way Proxmox runs it (this needs `qemu-system-x86_64`, `qemu-img` and `genisoimage`).

**2. Copy it to Proxmox.** The `local` storage keeps imports in `/var/lib/vz/import/`.

```bash
scp vm-images/out/dcs-hub-debian-13.qcow2 root@192.168.1.2:/var/lib/vz/import/
```

If Proxmox later says the storage cannot hold imports, tick **Import** under
*Datacenter → Storage → local → Content*.

**3. Create the VM.** On the Proxmox shell. These are the settings the hub itself uses for the VMs it
builds. Change the VM ID (`120`), the storages, the bridge and the addresses to match your host.

```bash
qm create 120 --name dcs-hub --cores 2 --cpu host --memory 4096 --balloon 3072 \
  --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-single \
  --scsi0 local-lvm:0,import-from=local:import/dcs-hub-debian-13.qcow2,discard=on \
  --ide2 local-lvm:cloudinit --boot order=scsi0 --serial0 socket --vga serial0 \
  --agent enabled=1 --ostype l26 --onboot 1 --tags 'dcs;hub'

qm disk resize 120 scsi0 32G
```

**4. Give it a user, a key and an address** through cloud-init, then start it. `--sshkeys` takes a file
on the Proxmox host that holds your public ssh key.

```bash
qm set 120 --ciuser dcs --sshkeys /root/my-key.pub \
  --ipconfig0 ip=192.168.1.20/24,gw=192.168.1.1 --nameserver 1.1.1.1 --ciupgrade 0
qm start 120
```

The image reads the cloud-init drive with its own small first-boot service: it sets the host name, the
user (with the docker group and passwordless sudo), your key and the address. Password logins over ssh
are off. The disk grows to the size you gave it.

**5. Open the dashboard.** The first boot pulls the dashboard image, so give it a minute. The VM's console
(*Console* in Proxmox) prints the address when DCS is up. Then open:

```text
http://192.168.1.20:3000
```

The wizard waits for its first admin. Carry on with [the first ten minutes](#the-first-ten-minutes).

<details>
<summary><b>What the image does on its first boot</b></summary>

1. `dcs-init` reads the cloud-init drive Proxmox attaches: host name, user, ssh keys, network and DNS.
2. `dcs-hub-init` moves the DCS checkout that came with the image into
   `/home/<user>/.Docker-Compose-Skeleton-AIO` and runs
   `DCS_UNATTENDED=true DCS_FLEET_ROLE=hub ./setup.sh` as that user.
3. It installs the boot services (`dcs-api`, `dcs-stacks`), so DCS comes back after every reboot.
4. It writes the dashboard address to the console and marks itself done. If something was not ready
   (the network, a registry), it tries again at the next boot.

</details>

## B. A hub in an LXC container

An unprivileged Debian 13 container with `nesting=1` and `keyctl=1`, Docker inside, and DCS set up as
a hub. It uses the least memory of the four paths. The full, tested walk-through is its own page:

**→ [Install the hub in an LXC container](INSTALL-LXC.md)**

## C. Any Docker host

Any Linux machine with Docker Engine and the Compose plugin: a spare PC, a NAS, a cloud VM or a VM
you made yourself.

**1. Install Docker** if the machine does not have it yet, and let your user run it:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"
```

Log out and back in (or run `newgrp docker`) so the new group applies.

**2. Get DCS and run the setup** as your normal user, not with `sudo`:

```bash
git clone https://github.com/scotthowson/dcs-orchestrator.git ~/.Docker-Compose-Skeleton-AIO
cd ~/.Docker-Compose-Skeleton-AIO
./setup.sh
```

Keep the install in `~/.Docker-Compose-Skeleton-AIO`: the VMs a hub builds use the same path, and
the guides assume it.

**3. Answer its questions.** `setup.sh` first checks the machine, then:

- asks how this DCS will be used: **Standalone** (the default), **Hub** (link Proxmox here) or
  **Member** (a hub's address and a join code);
- offers to install missing tools (`jq`, `socat`, `curl` and friends), to start Docker and to add you
  to the `docker` group, and carries on in the same run;
- on a Proxmox guest, looks for the Proxmox API and offers to link it;
- creates `.env`, the stack folders and the logs folder, starts the API on port 9876 and the dashboard
  on port 3000;
- offers the boot services, so DCS starts by itself after a reboot.

When it finishes it prints the dashboard's address:

```text
  ║   Open your browser to complete setup:                  ║
  ║                                                         ║
  ║   Local:   http://localhost:3000                        ║
  ║   Network: http://192.168.1.20:3000                     ║
```

<details>
<summary><b>Unattended install (no questions)</b></summary>

For scripts and images, `setup.sh` takes its answers from the environment. This starts a hub and
leaves the first admin to the wizard:

```bash
DCS_UNATTENDED=true DCS_FLEET_ROLE=hub ./setup.sh
```

This creates the admin as well and finishes the setup without the wizard:

```bash
DCS_UNATTENDED=true DCS_ADMIN_USER=admin DCS_ADMIN_PASSWORD='choose-a-long-one' \
  DCS_TZ=Europe/London DCS_PROXY_DOMAIN=example.com ./setup.sh
```

Unattended runs never change the system without being told: they do not install tools or packages,
and they do not install the boot services (run `sudo .scripts/install-service.sh` afterwards).
Every variable is listed in `./setup.sh --help` and in [Configuration](CONFIGURATION.md#setup-variables).

</details>

## D. A VM from an installer ISO

The classic way on Proxmox: a VM you install yourself, then path C inside it.

1. **Get the ISO.** In Proxmox: *Datacenter → your node → local → ISO Images → Download from URL*, and paste
   the Debian 13 netinst link from [debian.org](https://www.debian.org/distrib/netinst) (or an Ubuntu Server ISO).
2. **Create the VM** (*Create VM*):
   - *OS*: the ISO, type Linux.
   - *System*: SCSI controller **VirtIO SCSI single**, tick **QEMU Agent**.
   - *Disks*: 32 GB, tick **Discard**.
   - *CPU*: 2 cores, type **host**. *Memory*: 4096 MB.
   - *Network*: **VirtIO** on your bridge (`vmbr0`).
   - *Confirm*: tick **Start after created**. Later, under *Options*, set **Start at boot** to Yes.
3. **Install the OS.** Choose *SSH server* and *standard system utilities*, no desktop. Create your user.
4. **Prepare it** as root in the VM's console:

   ```bash
   apt-get update && apt-get install -y sudo qemu-guest-agent curl git
   usermod -aG sudo youruser
   systemctl enable --now qemu-guest-agent
   ```

   The guest agent lets Proxmox read the VM's address, shut it down cleanly and freeze the file system
   for backups; the hub also uses it to find VMs.
5. **Install Docker and DCS** as your user: follow [C. Any Docker host](#c-any-docker-host) from step 1.

With Proxmox linked, DCS tags its own VM `dcs` and `hub` in Proxmox when the wizard finishes *(new in 4.0)*.

## The first ten minutes

### 1. Walk through the wizard

Open `http://<server>:3000`. The setup wizard has five steps.

| Step | What you do |
|---|---|
| **Connect** | The dashboard finds its API by itself and shows what it detected: host name, time zone, Docker and Compose versions, user and group IDs. |
| **Admin** | Create the first admin account (at least 8 characters, with an uppercase letter and a number). Moving house? *Restore a recovery bundle* here instead. |
| **Server** | Name, time zone, domain, data folder, user and group IDs. Notifications (ntfy, Discord), Traefik with Authelia and CrowdSec, dynamic DNS. On a Proxmox guest a **Proxmox** section opens by itself; on a member, *Join a DCS hub*. |
| **Stacks** | The stacks to create and their start order. On a hub with Proxmox linked, each stack has a **Hub / VM** switch with its size, and a VM settings panel. |
| **Review** | Check everything, then **Complete Setup**. The wizard deploys the proxy services, makes the DNS records, starts the core stack and, on a hub, hands the VM plan over. |

You land on the dashboard. Everything the wizard set is in *Server Config* and can be changed later.

### 2. Link Proxmox

Skip this without Proxmox. DCS talks to Proxmox with an **API token**, never a password. On the
Proxmox shell:

```bash
pveum role add DCS -privs "VM.Audit VM.PowerMgmt Sys.Audit"
pveum user add dcs@pve
pveum aclmod / -user dcs@pve -role DCS
pveum user token add dcs@pve dcs -privsep 0      # prints the secret once
```

In the wizard's Proxmox section, or later in *Server Config → Proxmox*, enter the address
(`https://192.168.1.2:8006`), the token ID `dcs@pve!dcs` and the secret, then press **Test connection**.
The secret goes into the encrypted secret store.

This token sees and powers guests. **To build VMs**, the token also needs the roles *PVEVMAdmin*,
*PVEDatastoreAdmin* and *PVESDNUser* on `/`:

```bash
pveum aclmod / -user dcs@pve -role PVEVMAdmin
pveum aclmod / -user dcs@pve -role PVEDatastoreAdmin
pveum aclmod / -user dcs@pve -role PVESDNUser
```

[Proxmox guide → token](PROXMOX.md#1-make-an-api-token-on-proxmox) covers the web UI way and every
privilege. The Proxmox page says what the token may do (`GET /proxmox/capabilities`).

### 3. Deploy your first app

1. Open **Templates** and pick one, for example *Uptime Kuma*.
2. Press **Deploy**. Choose the stack it lands in, check the variables (ports, paths, passwords), and
   decide per route whether it sits behind Authelia and whether it starts on demand.
3. Watch the progress: pull, create, start, health check. When it is healthy, open it at its port or at
   `https://<name>.<your-domain>`.

The same from the API:

```bash
curl -s -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -X POST http://localhost:9876/templates/uptime-kuma/deploy \
  -d '{"target_stack":"monitoring-management","auto_start":true}'
```

[Templates](TEMPLATES.md) lists every template and explains what a deploy does.

### 4. Build your first VM

On a hub with Proxmox linked (and a token that may build VMs):

1. Open the **Proxmox** page and choose **New VM stack** (on a hub the Stacks page reads *VMs* and has
   **New VM** too).
2. Name the stack, pick a size (*Small* to *X-Large*, or set cores, memory and disk) and the operating
   system. Keep **Bake a DCS template first** ticked: the first build makes a template, and every later
   VM is a quick clone of it.
3. Follow the build card: *Image → Create → Cloud-init → Boot → SSH → Install → Join → Stack → Ready*.
   A failed step says why and has a **Retry**.

The new VM shows up as a stack on the VMs page, its containers on the Containers page, and its routes
behind the hub's Traefik. [Proxmox guide → the fleet](PROXMOX.md#5-the-fleet-the-vm-is-the-stack)
explains every step.

### 5. Make it survive a reboot

If you skipped it during setup, install the boot services:

```bash
sudo ~/.Docker-Compose-Skeleton-AIO/.scripts/install-service.sh
```

`dcs-api` starts the API after Docker; `dcs-stacks` starts your stacks in order, checks their health and
repairs Traefik's routes after a power cut.

## Where next

- [Operations](OPERATIONS.md): updates, backups, health, notifications, users and roles
- [Configuration](CONFIGURATION.md): the `.env` settings that matter
- [Proxmox and the fleet](PROXMOX.md): everything about the hub and its VMs
- [Troubleshooting](TROUBLESHOOTING.md): when something does not work
