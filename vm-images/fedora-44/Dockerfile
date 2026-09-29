# =============================================================================
# DCS VM images — Fedora 44: a single-purpose Docker host, nothing else.
# Two targets: `node` (what the hub clones for every stack) and `hub` (node + the DCS checkout and its first start).
# This builds the root file system; ../build.sh turns it into a bootable disk.
# SELinux stays enforcing (as on a Fedora server), its labels are written by the build (tools/relabel).
# =============================================================================
FROM fedora:44 AS node
ENV LANG=C.UTF-8

# No documentation, one locale, no weak dependencies; Docker's repository for Fedora
RUN set -eux; \
    printf 'install_weak_deps=False\ntsflags=nodocs\nkeepcache=False\nmax_parallel_downloads=10\n' >> /etc/dnf/dnf.conf; \
    printf '%%_install_langs C\n%%_excludedocs 1\n' > /usr/lib/rpm/macros.d/macros.dcs; \
    curl -fsSL https://download.docker.com/linux/fedora/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo

# The kernel first (its install hooks find the plugin and the small initramfs settings already in place)
COPY fedora-44/overlay/etc/dracut.conf.d/ /etc/dracut.conf.d/
COPY fedora-44/overlay/etc/kernel/install.d/ /etc/kernel/install.d/
COPY common/overlay/usr/local/sbin/dcs-grubcfg /usr/local/sbin/dcs-grubcfg
COPY common/overlay/etc/default/grub.d/ /etc/default/grub.d/
RUN set -eux; \
    echo 'GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX} selinux=1 enforcing=1"' > /etc/default/grub.d/10-lsm.cfg; \
    mkdir -p /boot /etc/kernel; echo 'root=LABEL=dcs-root ro quiet' > /etc/kernel/cmdline; \
    dnf -y install kernel-core kernel-modules-core kernel-modules dracut; \
    ls -la /boot; test -f /boot/grub/grub.cfg

# The system: systemd with its own networking, ssh, sudo, the tools DCS itself runs on, SELinux policy, the guest agent
RUN set -eux; dnf -y install \
    systemd systemd-udev systemd-networkd systemd-pam dbus-broker openssh-server sudo qemu-guest-agent \
    iproute iputils iptables-nft nftables kmod procps-ng util-linux-core e2fsprogs shadow-utils passwd hostname findutils \
    curl jq git socat openssl python3 tar gzip xz zstd \
    selinux-policy-targeted policycoreutils policycoreutils-python-utils container-selinux; \
    (dnf -y install systemd-timesyncd || dnf -y install chrony)

# It is a VM, not a container image: the release package says so (os-release: Fedora Linux 44 (Cloud Edition))
RUN set -eux; dnf -y install --allowerasing fedora-release-cloud fedora-release-identity-cloud; grep PRETTY_NAME /etc/os-release

# Docker from Docker's repository
RUN set -eux; dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin

# (/usr/local/sbin is a symlink to bin on Fedora: the overlay goes in through tar, which keeps a directory symlink as it is)
COPY common/overlay/ /tmp/overlay/
RUN tar -C /tmp/overlay -cf - . | tar --keep-directory-symlink -C / -xf - && rm -rf /tmp/overlay
RUN set -eux; \
    chmod 755 /usr/local/sbin/dcs-init /usr/local/sbin/dcs-grubcfg; chmod 440 /etc/sudoers.d/* 2>/dev/null || true; rm -rf /etc/initramfs-tools; \
    for u in dcs-init.service systemd-networkd.service systemd-repart.service sshd.service qemu-guest-agent.service \
             docker.service containerd.service dcs-container-stop.service fstrim.timer serial-getty@ttyS0.service getty@tty1.service; do \
        systemctl enable "$u" >/dev/null 2>&1 || { echo "cannot enable $u" >&2; systemctl enable "$u"; exit 1; }; \
    done; \
    (systemctl enable systemd-timesyncd.service || systemctl enable chronyd.service) >/dev/null 2>&1; \
    systemctl mask systemd-binfmt.service proc-sys-fs-binfmt_misc.automount dnf-makecache.timer var-lib-machines.mount sshd-keygen@rsa.service sshd-keygen@ecdsa.service >/dev/null 2>&1; \
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime; echo 'LANG=C.UTF-8' > /etc/locale.conf; \
    : > /etc/machine-id; : > /etc/motd; rm -f /etc/ssh/ssh_host_*; \
    sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config

# Leave nothing behind that the running VM does not need
RUN set -eux; \
    dnf clean all; rm -rf /var/cache/dnf /var/lib/dnf/repos /var/log/* /tmp/* /root/.cache /usr/share/doc /usr/share/man /usr/share/info /usr/share/locale \
        /usr/share/licenses 2>/dev/null || true; \
    rm -f /usr/lib/systemd/system-generators/systemd-ssh-generator; \
    find /usr /var -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true

# =============================================================================
# The hub image: the same system, the DCS checkout (the build context "dcs") and the service that starts it at the
# first boot. Members never carry DCS code: the hub gives them its own at join time, so versions always match.
# =============================================================================
FROM node AS hub
COPY hub/overlay/ /tmp/overlay/
RUN tar -C /tmp/overlay -cf - . | tar --keep-directory-symlink -C / -xf - && rm -rf /tmp/overlay
COPY --from=dcs . /opt/dcs
RUN set -eux; \
    chmod 755 /usr/local/sbin/dcs-hub-init; \
    systemctl enable dcs-hub-init.service; systemctl is-enabled dcs-hub-init.service; \
    rm -f /opt/dcs/.git/hooks/*.sample
