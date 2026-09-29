# =============================================================================
# DCS VM images — Arch Linux (rolling): a single-purpose Docker host, nothing else.
# Two targets: `node` (what the hub clones for every stack) and `hub` (node + the DCS checkout and its first start).
# This builds the root file system; ../build.sh turns it into a bootable disk.
# Arch has no releases: an image is what the repositories hold the day it is built (the date is in /etc/os-release).
# =============================================================================
FROM archlinux:base AS node
ENV LANG=C.UTF-8
ARG KERNEL=linux

# The whole system up to date first (Arch has no partial upgrades)
RUN set -eux; \
    sed -i 's/^ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf; \
    pacman -Syu --noconfirm

# The kernel, with a tiny initramfs (its settings first: the hook that builds it reads them) and the hook that writes grub.cfg
COPY arch/overlay/etc/mkinitcpio.conf.d/ /etc/mkinitcpio.conf.d/
COPY arch/overlay/etc/pacman.d/hooks/ /etc/pacman.d/hooks/
COPY common/overlay/usr/local/sbin/dcs-grubcfg /usr/local/sbin/dcs-grubcfg
COPY common/overlay/etc/default/grub.d/ /etc/default/grub.d/
RUN set -eux; \
    echo 'GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX}"' > /etc/default/grub.d/10-lsm.cfg; \
    chmod 755 /usr/local/sbin/dcs-grubcfg; \
    pacman -S --noconfirm "$KERNEL" mkinitcpio; \
    sed -i "s/^PRESETS=.*/PRESETS=('default')/" "/etc/mkinitcpio.d/$KERNEL.preset"; \
    rm -f /boot/initramfs-*-fallback.img; \
    ls -la /boot; test -f "/boot/vmlinuz-$KERNEL" && test -f "/boot/initramfs-$KERNEL.img" && test -f /boot/grub/grub.cfg

# The system: ssh, sudo, the tools DCS itself runs on, the guest agent, Docker (systemd, its networking, iproute2, kmod, curl and
# openssl are in the base already)
RUN set -eux; pacman -S --noconfirm --needed openssh sudo qemu-guest-agent jq git socat python docker docker-compose

COPY common/overlay/ /
COPY arch/overlay/etc/systemd/ /etc/systemd/
RUN set -eux; \
    chmod 755 /usr/local/sbin/dcs-init; chmod 440 /etc/sudoers.d/* 2>/dev/null || true; \
    rm -rf /etc/initramfs-tools; \
    for u in dcs-init.service dcs-pacman-keyring.timer systemd-networkd.service systemd-timesyncd.service systemd-repart.service sshd.service \
             qemu-guest-agent.service docker.service containerd.service fstrim.timer serial-getty@ttyS0.service getty@tty1.service; do \
        systemctl enable "$u" >/dev/null 2>&1 || { echo "cannot enable $u" >&2; systemctl enable "$u"; exit 1; }; \
        systemctl is-enabled "$u" >/dev/null 2>&1 || [ "$u" = systemd-repart.service ] || { echo "$u is not enabled" >&2; exit 1; }; \
    done; \
    systemctl mask systemd-binfmt.service proc-sys-fs-binfmt_misc.automount systemd-firstboot.service var-lib-machines.mount sshdgenkeys.service >/dev/null 2>&1; \
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime; echo 'LANG=C.UTF-8' > /etc/locale.conf; \
    : > /etc/machine-id; : > /etc/motd; \
    rm -f /etc/ssh/ssh_host_*

# Leave nothing behind that the running VM does not need: the package cache, the sync databases (pacman -Sy fetches them), the keyring
# of the build (every VM makes its own: dcs-pacman-keyring.service), headers and introspection data no VM compiles against, containerd's load
# tester, Python's static library, and the kernel's second copy (mkinitcpio's hook keeps the one in /boot; a kernel package brings it back)
# (Arch's pacman hook builds the hardware database when a package brings hwdb sources; the container image has none, and systemd 262's
# imds generator complains about it at every boot.)
RUN set -eux; \
    systemd-hwdb --usr update; \
    pacman -Scc --noconfirm >/dev/null 2>&1 || true; \
    rm -rf /var/cache/pacman/pkg/* /var/lib/pacman/sync/* /etc/pacman.d/gnupg /var/log/* /tmp/* /root/.cache /var/lib/systemd/random-seed \
           /usr/include /usr/share/gir-1.0 /usr/lib/python3*/test /usr/lib/python3*/idlelib /usr/lib/python3*/tkinter /usr/lib/python3*/turtledemo \
           /usr/lib/python3*/lib2to3 /usr/lib/python3*/config-*/libpython*.a \
           /usr/bin/containerd-stress /usr/lib/modules/*/vmlinuz /usr/lib/systemd/system-generators/systemd-ssh-generator

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
