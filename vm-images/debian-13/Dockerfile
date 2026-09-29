# =============================================================================
# DCS VM images — Debian 13 (trixie): a single-purpose Docker host, nothing else.
# Two targets: `node` (what the hub clones for every stack) and `hub` (node + the DCS checkout and its first start).
# This builds the root file system; ../build.sh turns it into a bootable disk.
# =============================================================================
FROM debian:trixie-slim AS node
ARG DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# No documentation, man pages or translations (the copyright files stay); no recommended or suggested packages
RUN set -eux; \
    { echo 'path-exclude /usr/share/doc/*'; echo 'path-include /usr/share/doc/*/copyright'; \
      echo 'path-exclude /usr/share/man/*'; echo 'path-exclude /usr/share/groff/*'; echo 'path-exclude /usr/share/info/*'; \
      echo 'path-exclude /usr/share/lintian/*'; echo 'path-exclude /usr/share/locale/*'; echo 'path-include /usr/share/locale/locale.alias'; \
    } > /etc/dpkg/dpkg.cfg.d/01-dcs-slim; \
    printf 'APT::Install-Recommends "false";\nAPT::Install-Suggests "false";\nAcquire::Languages "none";\nDPkg::Options { "--force-confdef"; };\n' > /etc/apt/apt.conf.d/01-dcs; \
    apt-get update; \
    apt-get install -y ca-certificates curl gnupg; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc; \
    echo "deb [signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian trixie stable" > /etc/apt/sources.list.d/docker.list; \
    apt-get update

# The kernel first (its hooks must not meet a half-installed boot loader), with a compact initramfs
COPY common/overlay/etc/initramfs-tools/ /etc/initramfs-tools/
RUN set -eux; \
    apt-get install -y initramfs-tools zstd; \
    sed -i 's/^COMPRESS=.*/COMPRESS=zstd/; s/^MODULES=.*/MODULES=list/' /etc/initramfs-tools/initramfs.conf; \
    apt-get install -y linux-image-cloud-amd64

# The system: systemd with its own networking, ssh, sudo, the tools DCS itself runs on, the guest agent
RUN set -eux; apt-get install -y \
    systemd systemd-sysv systemd-timesyncd systemd-repart udev kmod \
    iproute2 iputils-ping netbase iptables \
    openssh-server sudo tzdata apparmor dbus-daemon dbus-system-bus-common libpam-systemd \
    procps util-linux e2fsprogs fdisk \
    curl jq git socat openssl python3 \
    qemu-guest-agent

# Docker from Docker's repository (the hub's Docker Engine card updates it like any package)
RUN set -eux; apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# The boot loader's config tool: kernel upgrades in the running VM regenerate /boot/grub/grub.cfg by themselves
RUN set -eux; apt-get install -y grub-common

COPY common/overlay/ /
RUN echo 'GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX} apparmor=1 security=apparmor"' > /etc/default/grub.d/10-lsm.cfg
RUN set -eux; \
    chmod 755 /usr/local/sbin/dcs-init; chmod 440 /etc/sudoers.d/* 2>/dev/null || true; \
    for u in dcs-init.service systemd-networkd.service systemd-timesyncd.service systemd-repart.service ssh.service \
             qemu-guest-agent.service docker.service containerd.service fstrim.timer serial-getty@ttyS0.service getty@tty1.service; do \
        systemctl enable "$u" >/dev/null 2>&1 || { echo "cannot enable $u" >&2; systemctl enable "$u"; exit 1; }; \
        systemctl is-enabled "$u" >/dev/null 2>&1 || [ "$u" = systemd-repart.service ] || { echo "$u is not enabled" >&2; exit 1; }; \
    done; \
    systemctl mask apt-daily.timer apt-daily-upgrade.timer systemd-binfmt.service proc-sys-fs-binfmt_misc.automount var-lib-machines.mount >/dev/null 2>&1; \
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime; echo UTC > /etc/timezone; \
    echo "LANG=C.UTF-8" > /etc/default/locale; \
    : > /etc/machine-id; : > /etc/motd; \
    rm -f /etc/ssh/ssh_host_*

# A single-purpose host loads no desktop profiles into the kernel (Docker brings and loads its own), and needs no vsock ssh listener
RUN set -eux; \
    find /etc/apparmor.d -mindepth 1 -maxdepth 1 ! -name abi ! -name abstractions ! -name tunables ! -name local ! -name disable ! -name force-complain ! -name cache ! -name .git -exec rm -rf {} +; \
    rm -f /usr/lib/systemd/system-generators/systemd-ssh-generator

# Leave nothing behind that the running VM does not need
RUN set -eux; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/* /var/cache/debconf/*-old /var/log/* /tmp/* /root/.cache \
           /usr/share/doc/*/changelog* /usr/share/doc/*/NEWS* /usr/share/common-licenses/Apache-2.0 2>/dev/null || true; \
    find /usr /var -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true; \
    rm -f /var/lib/dpkg/*-old /var/lib/systemd/random-seed

# =============================================================================
# The hub image: the same system, the DCS checkout (the build context "dcs") and the service that starts it at the
# first boot. Members never carry DCS code: the hub gives them its own at join time, so versions always match.
# =============================================================================
FROM node AS hub
COPY hub/overlay/ /
COPY --from=dcs . /opt/dcs
RUN set -eux; \
    chmod 755 /usr/local/sbin/dcs-hub-init; \
    systemctl enable dcs-hub-init.service; systemctl is-enabled dcs-hub-init.service; \
    rm -f /opt/dcs/.git/hooks/*.sample
