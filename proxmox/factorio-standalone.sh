#!/usr/bin/env bash

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║           FACTORIO DEDICATED SERVER - PROXMOX LXC INSTALLER               ║
# ║                                                                           ║
# ║  Run on Proxmox VE Shell:                                                 ║
# ║  bash -c "$(curl -fsSL https://raw.githubusercontent.com/m-bck/factorio-server/main/proxmox/factorio-standalone.sh)"  ║
# ║                                                                           ║
# ║  Author: Maximilian Bick                                                  ║
# ║  License: MIT                                                             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -euo pipefail
shopt -s inherit_errexit nullglob

# ═══════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

APP="Factorio"
NSAPP="factorio"
APP_VERSION="stable"  # or specific version like "1.1.104"

# Default container settings
DEFAULT_CT_ID=""  # Auto-detect next available
DEFAULT_HOSTNAME="factorio"
DEFAULT_DISK_SIZE="8"
DEFAULT_CORE_COUNT="2"
DEFAULT_RAM_SIZE="2048"
DEFAULT_BRIDGE="vmbr0"
DEFAULT_STORAGE=""  # Auto-detect

# OS Template
OS_TYPE="debian"
OS_VERSION="12"
TEMPLATE_SEARCH="debian-12-standard"

# Ports
GAME_PORT="34197"

# ═══════════════════════════════════════════════════════════════════════════
# COLORS & FORMATTING
# ═══════════════════════════════════════════════════════════════════════════

# Terminal colors
RD='\033[01;31m'
GN='\033[01;32m'
YW='\033[01;33m'
BL='\033[01;34m'
CL='\033[m'
BOLD='\033[1m'
DIM='\033[2m'

# Icons
CM='✔'
CROSS='✖'
INFO='ℹ'
WARN='⚠'
GEAR='⚙'

# Message functions
msg_info() { echo -e "${BL}${INFO}${CL} ${1}..."; }
msg_ok() { echo -e "${GN}${CM}${CL} ${1}"; }
msg_error() { echo -e "${RD}${CROSS}${CL} ${1}"; }
msg_warn() { echo -e "${YW}${WARN}${CL} ${1}"; }

# ═══════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

header_info() {
  clear
  cat <<"EOF"

    ███████╗ █████╗  ██████╗████████╗ ██████╗ ██████╗ ██╗ ██████╗ 
    ██╔════╝██╔══██╗██╔════╝╚══██╔══╝██╔═══██╗██╔══██╗██║██╔═══██╗
    █████╗  ███████║██║        ██║   ██║   ██║██████╔╝██║██║   ██║
    ██╔══╝  ██╔══██║██║        ██║   ██║   ██║██╔══██╗██║██║   ██║
    ██║     ██║  ██║╚██████╗   ██║   ╚██████╔╝██║  ██║██║╚██████╔╝
    ╚═╝     ╚═╝  ╚═╝ ╚═════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚═╝ ╚═════╝ 
                                                                   
              Dedicated Server - Proxmox LXC Installer            
                                                                   
EOF
}

error_handler() {
  local exit_code="$?"
  local line_number="$1"
  msg_error "Error on line $line_number (exit code: $exit_code)"
  exit "$exit_code"
}

trap 'error_handler $LINENO' ERR

check_root() {
  if [[ $EUID -ne 0 ]]; then
    msg_error "This script must be run as root"
    exit 1
  fi
}

check_pve() {
  if ! command -v pveversion &>/dev/null; then
    msg_error "This script must be run on a Proxmox VE host"
    exit 1
  fi
  PVE_VERSION=$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')
  msg_ok "Proxmox VE $PVE_VERSION detected"
}

# ═══════════════════════════════════════════════════════════════════════════
# STORAGE SELECTION
# ═══════════════════════════════════════════════════════════════════════════

select_storage() {
  local content_type="$1"
  local storage_list

  storage_list=$(pvesm status -content "$content_type" 2>/dev/null | awk 'NR>1 {print $1}')
  
  if [[ -z "$storage_list" ]]; then
    msg_error "No storage found for content type: $content_type"
    exit 1
  fi

  local storage_count
  storage_count=$(echo "$storage_list" | wc -l)

  if [[ $storage_count -eq 1 ]]; then
    echo "$storage_list"
    return
  fi

  echo -e "\n${BL}Available storage for $content_type:${CL}"
  local i=1
  while read -r storage; do
    local info
    info=$(pvesm status | awk -v s="$storage" '$1==s {printf "Used: %.1fG / %.1fG", $5/1024/1024, $4/1024/1024}')
    echo "  [$i] $storage ($info)"
    ((i++))
  done <<< "$storage_list"

  local choice
  read -rp "Select storage [1]: " choice
  choice=${choice:-1}

  echo "$storage_list" | sed -n "${choice}p"
}

# ═══════════════════════════════════════════════════════════════════════════
# CONFIGURATION WIZARD
# ═══════════════════════════════════════════════════════════════════════════

configure_container() {
  echo ""
  echo -e "${BOLD}${BL}Container Configuration${CL}"
  echo -e "${DIM}Press Enter to accept defaults [shown in brackets]${CL}"
  echo ""

  # Container ID
  NEXT_ID=$(pvesh get /cluster/nextid)
  read -rp "Container ID [$NEXT_ID]: " CT_ID
  CT_ID=${CT_ID:-$NEXT_ID}

  # Verify ID is available
  if pct status "$CT_ID" &>/dev/null || qm status "$CT_ID" &>/dev/null; then
    msg_error "ID $CT_ID is already in use"
    exit 1
  fi

  # Hostname
  read -rp "Hostname [$DEFAULT_HOSTNAME]: " CT_HOSTNAME
  CT_HOSTNAME=${CT_HOSTNAME:-$DEFAULT_HOSTNAME}

  # Resources
  read -rp "Disk Size in GB [$DEFAULT_DISK_SIZE]: " DISK_SIZE
  DISK_SIZE=${DISK_SIZE:-$DEFAULT_DISK_SIZE}

  read -rp "CPU Cores [$DEFAULT_CORE_COUNT]: " CORE_COUNT
  CORE_COUNT=${CORE_COUNT:-$DEFAULT_CORE_COUNT}

  read -rp "RAM in MB [$DEFAULT_RAM_SIZE]: " RAM_SIZE
  RAM_SIZE=${RAM_SIZE:-$DEFAULT_RAM_SIZE}

  # Network
  read -rp "Network Bridge [$DEFAULT_BRIDGE]: " BRIDGE
  BRIDGE=${BRIDGE:-$DEFAULT_BRIDGE}

  echo ""
  read -rp "Use DHCP for IP? [Y/n]: " USE_DHCP
  USE_DHCP=${USE_DHCP:-y}

  if [[ ${USE_DHCP,,} == "n" ]]; then
    read -rp "Static IP (CIDR, e.g. 192.168.1.100/24): " STATIC_IP
    read -rp "Gateway IP: " GATEWAY_IP
    NET_CONFIG="ip=${STATIC_IP},gw=${GATEWAY_IP}"
  else
    NET_CONFIG="ip=dhcp"
  fi

  # Storage
  echo ""
  TEMPLATE_STORAGE=$(select_storage "vztmpl")
  CONTAINER_STORAGE=$(select_storage "rootdir")

  # SSH Root Password
  echo ""
  echo -e "${YW}SSH Root Password für Remote-Zugriff:${CL}"
  while true; do
    read -rsp "Root Password: " ROOT_PASSWORD
    echo ""
    read -rsp "Root Password (bestätigen): " ROOT_PASSWORD_CONFIRM
    echo ""
    if [[ "$ROOT_PASSWORD" == "$ROOT_PASSWORD_CONFIRM" ]]; then
      if [[ ${#ROOT_PASSWORD} -lt 4 ]]; then
        msg_warn "Passwort muss mindestens 4 Zeichen haben"
      else
        break
      fi
    else
      msg_warn "Passwörter stimmen nicht überein"
    fi
  done
  msg_ok "SSH Passwort gesetzt"

  # Game Password (for public servers)
  echo ""
  echo -e "${YW}Game Password (optional, recommended for public servers):${CL}"
  read -rsp "Game Password (leave empty for no password): " GAME_PASSWORD
  echo ""
  if [[ -n "$GAME_PASSWORD" ]]; then
    msg_ok "Game password set"
  else
    msg_warn "No game password - server will be open to anyone!"
  fi

  # Summary
  echo ""
  echo -e "${BOLD}${GN}Configuration Summary:${CL}"
  echo -e "  Container ID:    ${CT_ID}"
  echo -e "  Hostname:        ${CT_HOSTNAME}"
  echo -e "  Disk Size:       ${DISK_SIZE} GB"
  echo -e "  CPU Cores:       ${CORE_COUNT}"
  echo -e "  RAM:             ${RAM_SIZE} MB"
  echo -e "  Network:         ${BRIDGE} (${NET_CONFIG})"
  echo -e "  Template Store:  ${TEMPLATE_STORAGE}"
  echo -e "  Container Store: ${CONTAINER_STORAGE}"
  if [[ -n "$GAME_PASSWORD" ]]; then
    echo -e "  Game Password:   ****"
  else
    echo -e "  Game Password:   ${RD}None (open server)${CL}"
  fi
  echo ""

  read -rp "Proceed with installation? [Y/n]: " PROCEED
  PROCEED=${PROCEED:-y}
  
  if [[ ${PROCEED,,} != "y" ]]; then
    msg_warn "Installation cancelled"
    exit 0
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# TEMPLATE MANAGEMENT
# ═══════════════════════════════════════════════════════════════════════════

download_template() {
  msg_info "Checking for OS template"

  # Update template list
  pveam update &>/dev/null || true

  # Find template (format: "system          debian-12-standard_12.x-x_amd64.tar.zst")
  TEMPLATE=$(pveam available -section system 2>/dev/null | awk '{print $2}' | grep -E "^${TEMPLATE_SEARCH}" | sort -V | tail -n1)

  if [[ -z "$TEMPLATE" ]]; then
    msg_error "Could not find template matching: $TEMPLATE_SEARCH"
    exit 1
  fi

  # Check if already downloaded
  if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE"; then
    msg_ok "Template already available: $TEMPLATE"
    return
  fi

  msg_info "Downloading template: $TEMPLATE"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" &>/dev/null
  msg_ok "Template downloaded"
}

# ═══════════════════════════════════════════════════════════════════════════
# CONTAINER CREATION
# ═══════════════════════════════════════════════════════════════════════════

create_container() {
  msg_info "Creating LXC Container $CT_ID"

  # Build pct create command
  pct create "$CT_ID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    -hostname "$CT_HOSTNAME" \
    -rootfs "${CONTAINER_STORAGE}:${DISK_SIZE}" \
    -cores "$CORE_COUNT" \
    -memory "$RAM_SIZE" \
    -net0 "name=eth0,bridge=${BRIDGE},${NET_CONFIG}" \
    -onboot 1 \
    -features "nesting=1,keyctl=1" \
    -unprivileged 1 \
    -tags "factorio;gameserver;community-script" \
    &>/dev/null

  msg_ok "Created LXC Container $CT_ID"
}

# ═══════════════════════════════════════════════════════════════════════════
# SOFTWARE INSTALLATION
# ═══════════════════════════════════════════════════════════════════════════

install_factorio() {
  msg_info "Starting Container"
  pct start "$CT_ID"
  sleep 5
  msg_ok "Container started"

  msg_info "Waiting for network"
  for i in {1..30}; do
    if pct exec "$CT_ID" -- ping -c1 -W1 1.1.1.1 &>/dev/null; then
      break
    fi
    sleep 1
  done
  msg_ok "Network ready"

  msg_info "Configuring locale"
  pct exec "$CT_ID" -- apt-get update -qq
  pct exec "$CT_ID" -- apt-get install -y -qq locales
  echo "en_US.UTF-8 UTF-8" | pct exec "$CT_ID" -- tee /etc/locale.gen >/dev/null
  pct exec "$CT_ID" -- locale-gen >/dev/null 2>&1
  pct exec "$CT_ID" -- update-locale LANG=en_US.UTF-8 >/dev/null 2>&1
  msg_ok "Locale configured"

  msg_info "Updating system packages"
  pct exec "$CT_ID" -- apt-get upgrade -y -qq
  msg_ok "System updated"

  msg_info "Installing dependencies"
  pct exec "$CT_ID" -- apt-get install -y -qq curl sudo mc xz-utils jq cifs-utils openssh-server
  msg_ok "Dependencies installed"

  msg_info "Configuring SSH"
  echo "root:${ROOT_PASSWORD}" | pct exec "$CT_ID" -- chpasswd
  pct exec "$CT_ID" -- sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  pct exec "$CT_ID" -- sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
  pct exec "$CT_ID" -- systemctl enable ssh
  pct exec "$CT_ID" -- systemctl restart ssh
  msg_ok "SSH configured (root login enabled)"

  msg_info "Creating factorio user"
  pct exec "$CT_ID" -- groupadd -r factorio 2>/dev/null || true
  pct exec "$CT_ID" -- useradd -r -g factorio -d /opt/factorio -s /bin/bash factorio 2>/dev/null || true
  msg_ok "User created"

  msg_info "Fetching latest Factorio version"
  FACTORIO_VERSION=$(pct exec "$CT_ID" -- sh -c "curl -fsSL 'https://factorio.com/api/latest-releases' | jq -r '.stable.headless // \"stable\"'")
  if [[ -z "$FACTORIO_VERSION" || "$FACTORIO_VERSION" == "null" ]]; then
    msg_error "Could not fetch Factorio version"
    exit 1
  fi
  msg_ok "Latest version: $FACTORIO_VERSION"

  msg_info "Downloading Factorio Headless Server"
  DOWNLOAD_URL="https://factorio.com/get-download/${FACTORIO_VERSION}/headless/linux64"
  # Use sh -c to ensure output redirection happens inside container
  if ! pct exec "$CT_ID" -- sh -c "curl -L --fail --progress-bar '${DOWNLOAD_URL}' -o /tmp/factorio.tar.xz"; then
    msg_error "Failed to download Factorio from: $DOWNLOAD_URL"
    exit 1
  fi
  # Verify download
  if ! pct exec "$CT_ID" -- test -f /tmp/factorio.tar.xz; then
    msg_error "Download file not found after curl"
    exit 1
  fi
  FILESIZE=$(pct exec "$CT_ID" -- stat -c%s /tmp/factorio.tar.xz 2>/dev/null || echo "0")
  if [[ "$FILESIZE" -lt 1000000 ]]; then
    msg_error "Downloaded file too small (${FILESIZE} bytes) - download may have failed"
    pct exec "$CT_ID" -- cat /tmp/factorio.tar.xz 2>/dev/null || true
    exit 1
  fi
  msg_ok "Downloaded Factorio (${FILESIZE} bytes)"

  msg_info "Installing Factorio"
  TAR_OUTPUT=$(pct exec "$CT_ID" -- sh -c "tar -xJf /tmp/factorio.tar.xz -C /opt 2>&1") || {
    msg_error "Failed to extract Factorio archive"
    echo "$TAR_OUTPUT"
    exit 1
  }
  pct exec "$CT_ID" -- rm -f /tmp/factorio.tar.xz
  msg_ok "Installed Factorio"

  msg_info "Creating directory structure"
  pct exec "$CT_ID" -- mkdir -p /opt/factorio/saves /opt/factorio/mods /opt/factorio/config /backup
  pct exec "$CT_ID" -- chown -R factorio:factorio /opt/factorio /backup
  msg_ok "Directories created"

  # Upload configuration files
  msg_info "Creating server configuration"
  cat <<'SERVERCONF' | pct exec "$CT_ID" -- tee /opt/factorio/config/server-settings.json >/dev/null
{
    "name": "Factorio Server",
    "description": "A Factorio server running on Proxmox LXC",
    "tags": ["game"],
    "max_players": 0,
    "visibility": {"public": true, "lan": true},
    "username": "",
    "password": "",
    "token": "",
    "game_password": "__GAME_PASSWORD__",
    "require_user_verification": false,
    "max_upload_in_kilobytes_per_second": 0,
    "max_upload_slots": 5,
    "minimum_latency_in_ticks": 0,
    "max_heartbeats_per_second": 60,
    "ignore_player_limit_for_returning_players": false,
    "allow_commands": "admins-only",
    "autosave_interval": 10,
    "autosave_slots": 5,
    "afk_autokick_interval": 0,
    "auto_pause": true,
    "only_admins_can_pause_the_game": true,
    "autosave_only_on_server": true,
    "non_blocking_saving": false,
    "minimum_segment_size": 25,
    "minimum_segment_size_peer_count": 20,
    "maximum_segment_size": 100,
    "maximum_segment_size_peer_count": 10
}
SERVERCONF
  msg_ok "Server configuration created"

  msg_info "Creating startup script"
  cat <<'STARTSCRIPT' | pct exec "$CT_ID" -- tee /opt/factorio/start-server.sh >/dev/null
#!/bin/bash
set -e
FACTORIO_DIR="/opt/factorio"
SAVES_DIR="${FACTORIO_DIR}/saves"
CONFIG_DIR="${FACTORIO_DIR}/config"
BINARY="${FACTORIO_DIR}/bin/x64/factorio"
SAVE_NAME="${SAVE_NAME:-world}"
SAVE_FILE="${SAVES_DIR}/${SAVE_NAME}.zip"

if [ ! -f "${SAVE_FILE}" ]; then
    echo "Creating new map: ${SAVE_NAME}..."
    MAP_GEN_ARGS=""
    [ -f "${CONFIG_DIR}/map-gen-settings.json" ] && MAP_GEN_ARGS="--map-gen-settings ${CONFIG_DIR}/map-gen-settings.json"
    ${BINARY} --create "${SAVE_FILE}" ${MAP_GEN_ARGS}
fi

ARGS=("--start-server" "${SAVE_FILE}" "--server-settings" "${CONFIG_DIR}/server-settings.json")
[ -f "${CONFIG_DIR}/server-adminlist.json" ] && ARGS+=("--server-adminlist" "${CONFIG_DIR}/server-adminlist.json")
exec ${BINARY} "${ARGS[@]}"
STARTSCRIPT
  pct exec "$CT_ID" -- chmod +x /opt/factorio/start-server.sh
  pct exec "$CT_ID" -- chown factorio:factorio /opt/factorio/start-server.sh
  msg_ok "Startup script created"

  msg_info "Creating systemd service"
  cat <<'SYSTEMD' | pct exec "$CT_ID" -- tee /etc/systemd/system/factorio.service >/dev/null
[Unit]
Description=Factorio Dedicated Server
After=network.target

[Service]
Type=simple
User=factorio
Group=factorio
WorkingDirectory=/opt/factorio
ExecStart=/opt/factorio/start-server.sh
ExecStop=/bin/kill -SIGINT $MAINPID
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/factorio/saves /opt/factorio/config /opt/factorio/mods /backup
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SYSTEMD
  pct exec "$CT_ID" -- systemctl daemon-reload
  pct exec "$CT_ID" -- systemctl enable factorio
  msg_ok "Systemd service created"

  # Set game password in config
  if [[ -n "$GAME_PASSWORD" ]]; then
    pct exec "$CT_ID" -- sed -i "s/__GAME_PASSWORD__/${GAME_PASSWORD}/" /opt/factorio/config/server-settings.json
  else
    pct exec "$CT_ID" -- sed -i 's/__GAME_PASSWORD__//' /opt/factorio/config/server-settings.json
  fi

  msg_info "Creating dynamic MOTD"
  cat <<'MOTDEOF' | pct exec "$CT_ID" -- tee /etc/update-motd.d/10-factorio >/dev/null
#!/bin/bash

# Colors
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
NC="\033[0m"
BOLD="\033[1m"

# Get server status
if systemctl is-active --quiet factorio; then
    STATUS="${GREEN}● RUNNING${NC}"
    UPTIME=$(systemctl show factorio --property=ActiveEnterTimestamp --value)
    if [[ -n "$UPTIME" ]]; then
        UPTIME_SECS=$(($(date +%s) - $(date -d "$UPTIME" +%s)))
        UPTIME_STR=$(printf "%dd %dh %dm" $((UPTIME_SECS/86400)) $((UPTIME_SECS%86400/3600)) $((UPTIME_SECS%3600/60)))
    fi
else
    STATUS="${RED}● STOPPED${NC}"
    UPTIME_STR="-"
fi

# Get Factorio version
FACTORIO_VERSION=$(cat /opt/factorio/data/base/info.json 2>/dev/null | jq -r ".version // \"unknown\"")

# Get IP
IP=$(hostname -I | awk "{print \$1}")

# Get save file info
SAVE_FILE="/opt/factorio/saves/world.zip"
if [[ -f "$SAVE_FILE" ]]; then
    SAVE_SIZE=$(du -h "$SAVE_FILE" | cut -f1)
    SAVE_DATE=$(date -r "$SAVE_FILE" "+%Y-%m-%d %H:%M")
else
    SAVE_SIZE="-"
    SAVE_DATE="No save yet"
fi

echo ""
echo -e "${BOLD}${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║${NC}  ${BOLD}FACTORIO DEDICATED SERVER${NC}                              ${BOLD}${BLUE}║${NC}"
echo -e "${BOLD}${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Server Status:${NC}  $STATUS"
echo -e "  ${BOLD}Uptime:${NC}         $UPTIME_STR"
echo -e "  ${BOLD}Version:${NC}        $FACTORIO_VERSION"
echo ""
echo -e "  ${BOLD}Connect:${NC}        ${YELLOW}${IP}:34197${NC} (UDP)"
echo -e "  ${BOLD}Save File:${NC}      $SAVE_SIZE ($SAVE_DATE)"
echo ""
echo -e "  ${BOLD}Commands:${NC}"
echo -e "    systemctl ${GREEN}start${NC}|${RED}stop${NC}|${YELLOW}restart${NC}|status factorio"
echo -e "    journalctl -u factorio -f"
echo ""
MOTDEOF
  pct exec "$CT_ID" -- chmod +x /etc/update-motd.d/10-factorio
  pct exec "$CT_ID" -- rm -f /etc/motd 2>/dev/null || true
  pct exec "$CT_ID" -- rm -f /etc/update-motd.d/10-uname 2>/dev/null || true
  msg_ok "Dynamic MOTD created"

  msg_info "Starting Factorio server"
  pct exec "$CT_ID" -- systemctl start factorio
  msg_ok "Factorio server started"

  # Get container IP
  sleep 3
  CT_IP=$(pct exec "$CT_ID" -- hostname -I | awk '{print $1}')
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════

main() {
  header_info
  check_root
  check_pve
  configure_container
  download_template
  create_container
  install_factorio

  echo ""
  echo -e "${BOLD}${GN}═══════════════════════════════════════════════════════════════${CL}"
  echo -e "${BOLD}${GN}   Factorio Server Installation Complete!${CL}"
  echo -e "${BOLD}${GN}═══════════════════════════════════════════════════════════════${CL}"
  echo ""
  echo -e "  ${BL}Container ID:${CL}    $CT_ID"
  echo -e "  ${BL}Hostname:${CL}        $CT_HOSTNAME"
  echo -e "  ${BL}IP Address:${CL}      $CT_IP"
  echo -e "  ${BL}Game Port:${CL}       UDP ${GAME_PORT}"
  echo ""
  echo -e "  ${YW}Connect with:${CL}    $CT_IP:${GAME_PORT}"
  echo ""
  echo -e "  ${BL}Server Commands:${CL}"
  echo -e "    pct enter $CT_ID"
  echo -e "    systemctl start|stop|restart|status factorio"
  echo ""
  echo -e "  ${BL}Configuration:${CL}"
  echo -e "    /opt/factorio/config/server-settings.json"
  echo ""
  echo -e "  ${BL}Logs:${CL}"
  echo -e "    journalctl -u factorio -f"
  echo ""
  echo -e "  ${BL}SSH Access:${CL}"
  echo -e "    ssh root@$CT_IP"
  echo ""
  echo -e "${BOLD}${GN}═══════════════════════════════════════════════════════════════${CL}"
}

main "$@"
