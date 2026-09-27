#!/bin/bash
# =============================================================================
# DCS member bootstrap — the hub pipes this into a fresh VM over ssh (bash -s),
# with the DCS_* values exported in front of it. Runs as the cloud-init user.
# Installs Docker and the tools, fetches the hub's own DCS code and runs an
# unattended member setup that joins the hub. Every line it prints lands in
# the hub's job log, so it says what matters and checks results rather than
# trusting package managers' exit codes (a half-configured grub must not stop
# a working Docker).
# =============================================================================
set -u
say() { echo "→ $*"; }
die() { echo "✗ $*"; exit 1; }
export DEBIAN_FRONTEND=noninteractive
: "${DCS_HUB_URL:?}" "${DCS_JOIN_TOKEN:?}" "${DCS_STACKS:?}" "${DCS_BUNDLE_URL:?}"
DIR="$HOME/.Docker-Compose-Skeleton-AIO"
have() { command -v "$1" >/dev/null 2>&1; }

APT_OPTS=(-o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 -o Acquire::Retries=2 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
pkg_install() {   # best effort, bounded in time, quiet; the caller checks what it needed
    if have apt-get; then
        [[ "${APT_UPDATED:-}" == 1 ]] || { sudo -n timeout 600 apt-get -qq "${APT_OPTS[@]}" update >/dev/null 2>&1 || true; APT_UPDATED=1; }
        sudo -n timeout 1200 apt-get -qq -y "${APT_OPTS[@]}" install "$@" >/dev/null 2>&1 || true
    elif have dnf; then
        sudo -n timeout 1200 dnf -q -y install "$@" >/dev/null 2>&1 || true
    fi
}

# Nothing works without a way out: say so at once instead of letting apt wait
gw=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}'); dns=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf 2>/dev/null)
say "Checking the VM's network (gateway ${gw:-none}, DNS ${dns:-none})…"
if ! curl -sS -m 12 -o /dev/null https://deb.debian.org/ 2>/dev/null && ! curl -sS -m 12 -o /dev/null https://get.docker.com/ 2>/dev/null; then
    ping -c1 -W3 "${gw:-127.0.0.1}" >/dev/null 2>&1 && gwok="answers" || gwok="does not answer"
    die "the VM cannot reach the internet: the gateway ${gw:-?} $gwok, DNS ${dns:-?} — check the bridge, the address range, the gateway and the DNS given for the VMs (the hub reaches this VM over ssh, so the bridge itself works)"
fi

say "Installing curl, git, jq, socat, openssl, python3 and the QEMU guest agent…"
pkg_install curl git jq socat openssl python3 ca-certificates gnupg qemu-guest-agent
for t in curl git jq socat openssl python3; do have "$t" || die "$t did not install — no internet from the VM, or the package manager is broken (check the VM's console)"; done
sudo -n systemctl enable --now qemu-guest-agent >/dev/null 2>&1 && say "QEMU guest agent running" || say "QEMU guest agent not started (Proxmox still works; the agent gives it the VM's address)"

if ! have docker; then
    say "Installing Docker (get.docker.com)…"
    if curl -fsSL https://get.docker.com -o /tmp/get-docker.sh; then sudo -n sh /tmp/get-docker.sh >/dev/null 2>&1 || true; rm -f /tmp/get-docker.sh; fi
    have docker || { say "Docker's installer did not finish; trying the distribution's package…"; pkg_install docker.io docker-compose; }
    have docker || die "Docker did not install"
fi
sudo -n systemctl enable --now docker >/dev/null 2>&1 || true
sudo -n usermod -aG docker "$USER" >/dev/null 2>&1 || true
if ! sg docker -c "docker compose version" >/dev/null 2>&1; then
    say "Adding the Docker Compose plugin…"
    pkg_install docker-compose-plugin
    sg docker -c "docker compose version" >/dev/null 2>&1 || pkg_install docker-compose
    if ! sg docker -c "docker compose version" >/dev/null 2>&1; then
        arch=$(uname -m); case "$arch" in aarch64) arch=aarch64 ;; *) arch=x86_64 ;; esac
        sudo -n mkdir -p /usr/local/lib/docker/cli-plugins
        curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$arch" -o /tmp/docker-compose && sudo -n install -m 755 /tmp/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose && rm -f /tmp/docker-compose
    fi
fi
sg docker -c "docker compose version" >/dev/null 2>&1 || die "Docker Compose is not available (docker compose version fails)"
say "Docker: $(docker --version 2>/dev/null | head -1) · $(sg docker -c 'docker compose version' 2>/dev/null | head -1)"

say "Fetching DCS from the hub…"
rm -rf "$DIR" && mkdir -p "$DIR"
curl -fsSL "$DCS_BUNDLE_URL" | tar -xz -C "$DIR" || die "could not fetch the DCS bundle from the hub ($DCS_HUB_URL)"
cd "$DIR" || die "no $DIR"
# the VM's SMBIOS uuid is root-only in sysfs: keep a copy the API's user can read (the hub matches guests by it)
mkdir -p .data && { sudo -n cat /sys/class/dmi/id/product_uuid 2>/dev/null | tr -d ' \n' > .data/product_uuid; } || true
[[ -s .data/product_uuid ]] || rm -f .data/product_uuid
chmod +x setup.sh start.sh stop.sh compose.sh .scripts/*.sh 2>/dev/null
say "DCS $(cat VERSION 2>/dev/null) unpacked; running the unattended member setup for stack $DCS_STACKS…"
# the docker group is new to this session: run setup under it
sg docker -c "DCS_UNATTENDED=true DCS_NO_UI=true DCS_FLEET_ROLE=member ./setup.sh" 2>&1 | sed -u 's/\x1b\[[0-9;]*m//g' | grep -v '^\s*$'
rc=${PIPESTATUS[0]}
[[ $rc -eq 0 ]] || die "setup.sh exited with $rc"
if [[ -x .scripts/install-service.sh ]]; then
    # the log is written by this user on purpose (root need not own a file in /tmp)
    # shellcheck disable=SC2024
    sudo -n env DCS_UNATTENDED=true .scripts/install-service.sh </dev/null >/tmp/dcs-install-service.log 2>&1 && say "DCS starts at boot (dcs-api, dcs-stacks services)" || say "boot services not installed (run: sudo .scripts/install-service.sh)"
fi
say "Member ready: $DCS_STACKS on $(hostname) ($(hostname -I 2>/dev/null | awk '{print $1}'))"
exit 0
