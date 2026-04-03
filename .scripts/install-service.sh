#!/bin/bash
# =============================================================================
# DCS Service Installer — Sets up systemd services for auto-start on boot
# =============================================================================
# Usage: sudo .scripts/install-service.sh [--uninstall]
#
# Installs two systemd services:
#   dcs-api.service     — Starts the API server (socat HTTP)
#   dcs-stacks.service  — Runs start.sh for ordered stack startup + health checks
#
# The API service starts after Docker is ready.
# The stacks service is optional — Docker restart policies handle most cases,
# but this ensures dependency-ordered startup and runs health checks.
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RST='\033[0m'

# Detect DCS base directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Check root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error:${RST} This script must be run as root (sudo)"
    echo "  sudo $0 $*"
    exit 1
fi

# Detect the user who owns the DCS directory (don't run services as root)
DCS_USER=$(stat -c '%U' "$BASE_DIR" 2>/dev/null || ls -ld "$BASE_DIR" | awk '{print $3}')
DCS_GROUP=$(stat -c '%G' "$BASE_DIR" 2>/dev/null || ls -ld "$BASE_DIR" | awk '{print $4}')

# Read API bind address from .env if available
API_BIND="0.0.0.0"
if [[ -f "$BASE_DIR/.env" ]]; then
    _bind=$(grep -m1 '^API_BIND=' "$BASE_DIR/.env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    [[ -n "$_bind" ]] && API_BIND="$_bind"
fi

# ── Uninstall ──
if [[ "${1:-}" == "--uninstall" ]]; then
    echo -e "${CYAN}Removing DCS services...${RST}"
    systemctl stop dcs-api.service 2>/dev/null || true
    systemctl stop dcs-stacks.service 2>/dev/null || true
    systemctl disable dcs-api.service 2>/dev/null || true
    systemctl disable dcs-stacks.service 2>/dev/null || true
    rm -f /etc/systemd/system/dcs-api.service
    rm -f /etc/systemd/system/dcs-stacks.service
    systemctl daemon-reload
    echo -e "${GREEN}DCS services removed.${RST}"
    exit 0
fi

echo -e "${BOLD}${CYAN}DCS Service Installer${RST}"
echo -e "  Base directory: ${BOLD}$BASE_DIR${RST}"
echo -e "  Run as user:    ${BOLD}$DCS_USER${RST}"
echo -e "  API bind:       ${BOLD}$API_BIND${RST}"
echo ""

# ── API Server Service ──
cat > /etc/systemd/system/dcs-api.service << EOF
[Unit]
Description=DCS API Server
Documentation=https://github.com/scotthowson/Docker-Compose-Skeleton
After=network-online.target docker.service
Requires=docker.service
Wants=network-online.target

[Service]
Type=forking
User=$DCS_USER
Group=$DCS_GROUP
WorkingDirectory=$BASE_DIR
PIDFile=$BASE_DIR/.data/api-server.pid
ExecStart=$BASE_DIR/.scripts/api-server.sh --bind $API_BIND
ExecStop=$BASE_DIR/.scripts/api-server.sh --stop
Restart=on-failure
RestartSec=10
TimeoutStartSec=30
TimeoutStopSec=15

# Environment
Environment="HOME=/home/$DCS_USER"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
WantedBy=multi-user.target
EOF

echo -e "${GREEN}✓${RST} Created dcs-api.service"

# ── Stacks Startup Service (one-shot) ──
cat > /etc/systemd/system/dcs-stacks.service << EOF
[Unit]
Description=DCS Stack Startup (ordered start + health check)
Documentation=https://github.com/scotthowson/Docker-Compose-Skeleton
After=docker.service dcs-api.service
Requires=docker.service

[Service]
Type=oneshot
User=$DCS_USER
Group=$DCS_GROUP
WorkingDirectory=$BASE_DIR
ExecStart=$BASE_DIR/start.sh
RemainAfterExit=yes
TimeoutStartSec=300

# Environment
Environment="HOME=/home/$DCS_USER"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
WantedBy=multi-user.target
EOF

echo -e "${GREEN}✓${RST} Created dcs-stacks.service"

# ── Enable and start ──
systemctl daemon-reload
systemctl enable dcs-api.service
systemctl enable dcs-stacks.service

# Configure SELinux contexts if enforcing
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
    echo -e "${CYAN}  Configuring SELinux contexts...${RST}"
    # Restore contexts on scripts and service files
    restorecon -Rv "$BASE_DIR/.scripts/" 2>/dev/null || true
    restorecon -Rv "$BASE_DIR/start.sh" "$BASE_DIR/stop.sh" "$BASE_DIR/restart.sh" 2>/dev/null || true
    restorecon -Rv /etc/systemd/system/dcs-*.service 2>/dev/null || true
    echo -e "${GREEN}  ✓${RST} SELinux contexts restored"
fi

echo ""
echo -e "${GREEN}${BOLD}Services installed and enabled.${RST}"
echo ""
echo -e "  ${BOLD}Commands:${RST}"
echo -e "    systemctl status dcs-api         ${CYAN}# Check API server status${RST}"
echo -e "    systemctl restart dcs-api         ${CYAN}# Restart API server${RST}"
echo -e "    journalctl -u dcs-api -f          ${CYAN}# Follow API logs${RST}"
echo -e "    systemctl status dcs-stacks       ${CYAN}# Check stacks startup status${RST}"
echo -e "    sudo $0 --uninstall     ${CYAN}# Remove services${RST}"
echo ""
echo -e "  ${BOLD}On next boot:${RST}"
echo -e "    1. Docker starts"
echo -e "    2. dcs-api.service starts the API server"
echo -e "    3. dcs-stacks.service runs start.sh (ordered startup + health checks)"
echo -e "    4. Containers with restart policies are also started by Docker"
echo ""

# ── Offer to start now ──
if ! systemctl is-active --quiet dcs-api.service; then
    read -rp "Start the API server now? [Y/n] " _start
    if [[ "${_start,,}" != "n" ]]; then
        systemctl start dcs-api.service
        echo -e "${GREEN}✓${RST} API server started"
    fi
fi
