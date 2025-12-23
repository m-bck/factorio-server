#!/usr/bin/env bash

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║           FACTORIO DEDICATED SERVER - PROXMOX LXC INSTALLER               ║
# ║                                                                           ║
# ║  Run on Proxmox VE Shell:                                                 ║
# ║  bash -c "$(curl -fsSL https://raw.githubusercontent.com/m-bck/factorio-server/main/proxmox/factorio-standalone.sh)"  ║
# ║                                                                           ║
# ║  This script supports multiple modes of operation:                        ║
# ║    - Full installation (default): Container + Application                 ║
# ║    - Provision only:  ./factorio-standalone.sh provision                  ║
# ║    - Setup only:      ./factorio-standalone.sh setup                      ║
# ║                                                                           ║
# ║  Author: Maximilian Bick                                                  ║
# ║  License: MIT                                                             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Don't use set -e, handle errors explicitly for better debugging
set -uo pipefail

# Determine mode
MODE="${1:-full}"
case "$MODE" in
  provision|setup|full)
    ;;
  *)
    echo "Usage: $0 [provision|setup|full]"
    echo ""
    echo "Modes:"
    echo "  provision - Create and configure container only"
    echo "  setup     - Install Factorio application only (run inside container)"
    echo "  full      - Complete installation (default)"
    exit 1
    ;;
esac

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
  cat <<EOF

    ███████╗ █████╗  ██████╗████████╗ ██████╗ ██████╗ ██╗ ██████╗ 
    ██╔════╝██╔══██╗██╔════╝╚══██╔══╝██╔═══██╗██╔══██╗██║██╔═══██╗
    █████╗  ███████║██║        ██║   ██║   ██║██████╔╝██║██║   ██║
    ██╔══╝  ██╔══██║██║        ██║   ██║   ██║██╔══██╗██║██║   ██║
    ██║     ██║  ██║╚██████╗   ██║   ╚██████╔╝██║  ██║██║╚██████╔╝
    ╚═╝     ╚═╝  ╚═╝ ╚═════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚═╝ ╚═════╝ 
                                                                   
              Dedicated Server - Proxmox LXC Installer            
                    Mode: ${MODE^^}
                                                                   
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
  if [[ "$MODE" != "setup" ]]; then
    if ! command -v pveversion &>/dev/null; then
      msg_error "This script must be run on a Proxmox VE host"
      exit 1
    fi
    PVE_VERSION=$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')
    msg_ok "Proxmox VE $PVE_VERSION detected"
  fi
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

  # SSH Public Key (optional - but allows skipping password)
  echo ""
  echo -e "${BOLD}${BL}SSH Zugriff konfigurieren${CL}"
  echo -e "${DIM}SSH Public Key ermöglicht passwortlosen Zugriff${CL}"
  echo -e "${DIM}(Windows: Get-Content ~/.ssh/id_ed25519.pub | Set-Clipboard)${CL}"
  read -rp "SSH Public Key (Enter to skip): " SSH_PUBLIC_KEY

  # SSH Root Password
  if [[ -n "$SSH_PUBLIC_KEY" ]]; then
    msg_ok "SSH Public Key wird eingerichtet"
    echo ""
    echo -e "${DIM}Passwort ist optional wenn SSH-Key gesetzt (für Proxmox Console nützlich)${CL}"
    read -rsp "Root Password (Enter to skip): " ROOT_PASSWORD
    echo ""
    if [[ -n "$ROOT_PASSWORD" ]]; then
      read -rsp "Root Password (bestätigen): " ROOT_PASSWORD_CONFIRM
      echo ""
      if [[ "$ROOT_PASSWORD" != "$ROOT_PASSWORD_CONFIRM" ]]; then
        msg_warn "Passwörter stimmen nicht überein - kein Passwort gesetzt"
        ROOT_PASSWORD=""
      elif [[ ${#ROOT_PASSWORD} -lt 4 ]]; then
        msg_warn "Passwort zu kurz - kein Passwort gesetzt"
        ROOT_PASSWORD=""
      else
        msg_ok "SSH Passwort gesetzt"
      fi
    else
      msg_info "Kein Passwort - nur SSH-Key Zugriff möglich"
    fi
  else
    # No SSH key - password is required
    echo ""
    echo -e "${YW}SSH Root Password (erforderlich ohne SSH-Key):${CL}"
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
  fi

  # Summary
  echo ""
  echo -e "${BOLD}${GN}Configuration Summary:${CL}"
  echo ""
  echo -e "  ${BOLD}Container:${CL}"
  echo -e "    ID:            ${CT_ID}"
  echo -e "    Hostname:      ${CT_HOSTNAME}"
  echo -e "    Disk Size:     ${DISK_SIZE} GB"
  echo -e "    CPU Cores:     ${CORE_COUNT}"
  echo -e "    RAM:           ${RAM_SIZE} MB"
  echo -e "    Network:       ${BRIDGE} (${NET_CONFIG})"
  echo -e "    Template:      ${TEMPLATE_STORAGE}"
  echo -e "    Storage:       ${CONTAINER_STORAGE}"
  echo ""

  read -rp "Proceed with container creation? [Y/n]: " PROCEED
  PROCEED=${PROCEED:-y}
  
  if [[ ${PROCEED,,} != "y" ]]; then
    msg_warn "Container creation cancelled"
    exit 0
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# FACTORIO SERVER CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

configure_factorio() {
  echo ""
  echo -e "${BOLD}${BL}Factorio Server Configuration${CL}"
  echo -e "${DIM}Press Enter to accept defaults [shown in brackets]${CL}"
  echo ""

  # Server Name
  read -rp "Server Name [Factorio Server]: " SERVER_NAME
  SERVER_NAME=${SERVER_NAME:-Factorio Server}

  # Server Description
  read -rp "Server Description [A Factorio server]: " SERVER_DESCRIPTION
  SERVER_DESCRIPTION=${SERVER_DESCRIPTION:-A Factorio server}

  # Max Players (0 = unlimited)
  read -rp "Max Players (0 = unlimited) [0]: " MAX_PLAYERS
  MAX_PLAYERS=${MAX_PLAYERS:-0}

  # Public Visibility
  echo ""
  read -rp "List server publicly on factorio.com? [y/N]: " PUBLIC_VISIBLE
  PUBLIC_VISIBLE=${PUBLIC_VISIBLE:-n}
  if [[ ${PUBLIC_VISIBLE,,} == "y" ]]; then
    VISIBILITY_PUBLIC="true"
    REQUIRE_USER_VERIFICATION="true"
    msg_info "User verification enabled (required for public servers)"
  else
    VISIBILITY_PUBLIC="false"
    REQUIRE_USER_VERIFICATION="false"
  fi

  # Factorio Account (required for public servers)
  echo ""
  echo -e "${DIM}Factorio account credentials (required for public servers)${CL}"
  echo -e "${DIM}Find these at https://factorio.com/profile or in player-data.json${CL}"
  read -rp "Factorio Username (leave empty if private): " FACTORIO_USERNAME
  
  if [[ -n "$FACTORIO_USERNAME" ]]; then
    echo -e "${YW}Token is more secure than password. Find it at https://factorio.com/profile${CL}"
    read -rsp "Factorio Token (recommended): " FACTORIO_TOKEN
    echo ""
    if [[ -z "$FACTORIO_TOKEN" ]]; then
      echo -e "${RD}Password authentication is not recommended!${CL}"
      read -rsp "Factorio Password (not recommended): " FACTORIO_PASSWORD
      echo ""
    fi
  fi

  # Game Password
  echo ""
  echo -e "${YW}Game Password (players need this to join):${CL}"
  read -rsp "Game Password (leave empty for no password): " GAME_PASSWORD
  echo ""
  if [[ -n "$GAME_PASSWORD" ]]; then
    msg_ok "Game password set"
  else
    msg_warn "No game password - anyone can join!"
  fi

  # Summary
  echo ""
  echo -e "${BOLD}${GN}Factorio Configuration Summary:${CL}"
  echo ""
  echo -e "  ${BOLD}Factorio Server:${CL}"
  echo -e "    Name:          ${SERVER_NAME}"
  echo -e "    Description:   ${SERVER_DESCRIPTION}"
  echo -e "    Max Players:   ${MAX_PLAYERS}"
  if [[ "$VISIBILITY_PUBLIC" == "true" ]]; then
    echo -e "    Public:        ${GN}Yes (listed on factorio.com)${CL}"
  else
    echo -e "    Public:        ${YW}No (LAN only)${CL}"
  fi
  if [[ -n "$FACTORIO_USERNAME" ]]; then
    echo -e "    Account:       ${FACTORIO_USERNAME}"
  fi
  if [[ -n "$GAME_PASSWORD" ]]; then
    echo -e "    Game Password: ****"
  else
    echo -e "    Game Password: ${RD}None${CL}"
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
  msg_info "Creating factorio user"
  
  # Check if running in container or via pct exec
  if [[ "$MODE" == "setup" ]]; then
    # Running inside container
    groupadd -r factorio 2>/dev/null || true
    useradd -r -g factorio -d /opt/factorio -s /bin/bash factorio 2>/dev/null || true
  else
    # Running via pct exec
    pct exec "$CT_ID" -- groupadd -r factorio 2>/dev/null || true
    pct exec "$CT_ID" -- useradd -r -g factorio -d /opt/factorio -s /bin/bash factorio 2>/dev/null || true
  fi
  msg_ok "User created"

  msg_info "Fetching latest Factorio version"
  if [[ "$MODE" == "setup" ]]; then
    FACTORIO_VERSION=$(curl -fsSL 'https://factorio.com/api/latest-releases' | jq -r '.stable.headless // "stable"')
  else
    FACTORIO_VERSION=$(pct exec "$CT_ID" -- sh -c "curl -fsSL 'https://factorio.com/api/latest-releases' | jq -r '.stable.headless // \"stable\"'")
  fi
  if [[ -z "$FACTORIO_VERSION" || "$FACTORIO_VERSION" == "null" ]]; then
    msg_error "Could not fetch Factorio version"
    exit 1
  fi
  msg_ok "Latest version: $FACTORIO_VERSION"

  msg_info "Downloading Factorio Headless Server"
  DOWNLOAD_URL="https://factorio.com/get-download/${FACTORIO_VERSION}/headless/linux64"
  
  if [[ "$MODE" == "setup" ]]; then
    # Running inside container
    if ! curl -L --fail --progress-bar "${DOWNLOAD_URL}" -o /tmp/factorio.tar.xz; then
      msg_error "Failed to download Factorio from: $DOWNLOAD_URL"
      exit 1
    fi
    if ! test -f /tmp/factorio.tar.xz; then
      msg_error "Download file not found after curl"
      exit 1
    fi
    FILESIZE=$(stat -c%s /tmp/factorio.tar.xz 2>/dev/null || echo "0")
  else
    # Running via pct exec
    if ! pct exec "$CT_ID" -- sh -c "curl -L --fail --progress-bar '${DOWNLOAD_URL}' -o /tmp/factorio.tar.xz"; then
      msg_error "Failed to download Factorio from: $DOWNLOAD_URL"
      exit 1
    fi
    if ! pct exec "$CT_ID" -- test -f /tmp/factorio.tar.xz; then
      msg_error "Download file not found after curl"
      exit 1
    fi
    FILESIZE=$(pct exec "$CT_ID" -- stat -c%s /tmp/factorio.tar.xz 2>/dev/null || echo "0")
  fi
  
  if [[ "$FILESIZE" -lt 1000000 ]]; then
    msg_error "Downloaded file too small (${FILESIZE} bytes) - download may have failed"
    exit 1
  fi
  msg_ok "Downloaded Factorio (${FILESIZE} bytes)"

  msg_info "Installing Factorio"
  if [[ "$MODE" == "setup" ]]; then
    TAR_OUTPUT=$(tar -xJf /tmp/factorio.tar.xz -C /opt 2>&1)
    TAR_EXIT=$?
  else
    TAR_OUTPUT=$(pct exec "$CT_ID" -- sh -c "tar -xJf /tmp/factorio.tar.xz -C /opt 2>&1")
    TAR_EXIT=$?
  fi
  if [[ $TAR_EXIT -ne 0 ]]; then
    msg_error "Failed to extract Factorio archive (exit code: $TAR_EXIT)"
    echo "$TAR_OUTPUT"
    exit 1
  fi
  
  if [[ "$MODE" == "setup" ]]; then
    rm -f /tmp/factorio.tar.xz || true
  else
    pct exec "$CT_ID" -- rm -f /tmp/factorio.tar.xz || true
  fi
  msg_ok "Installed Factorio"

  msg_info "Creating directory structure"
  if [[ "$MODE" == "setup" ]]; then
    mkdir -p /opt/factorio/saves /opt/factorio/mods /opt/factorio/config /backup || true
    chown -R factorio:factorio /opt/factorio 2>/dev/null || true
  else
    pct exec "$CT_ID" -- mkdir -p /opt/factorio/saves /opt/factorio/mods /opt/factorio/config /backup || true
    pct exec "$CT_ID" -- chown -R factorio:factorio /opt/factorio 2>/dev/null || true
  fi
  msg_ok "Directories created"

  # Upload configuration files
  msg_info "Creating server configuration"
  cat <<'SERVERCONF' > /tmp/server-settings.json.tmp
{
    "name": "__SERVER_NAME__",
    "description": "__SERVER_DESCRIPTION__",
    "tags": ["game"],
    "max_players": __MAX_PLAYERS__,
    "visibility": {"public": __VISIBILITY_PUBLIC__, "lan": true},
    "username": "__FACTORIO_USERNAME__",
    "password": "__FACTORIO_PASSWORD__",
    "token": "__FACTORIO_TOKEN__",
    "game_password": "__GAME_PASSWORD__",
    "require_user_verification": __REQUIRE_USER_VERIFICATION__,
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
  
  if [[ "$MODE" == "setup" ]]; then
    mv /tmp/server-settings.json.tmp /opt/factorio/config/server-settings.json
  else
    pct push "$CT_ID" /tmp/server-settings.json.tmp /opt/factorio/config/server-settings.json
    rm /tmp/server-settings.json.tmp
  fi
  msg_ok "Server configuration created"

  msg_info "Creating startup script"
  cat <<'STARTSCRIPT' > /tmp/start-server.sh.tmp
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
[ -f "${FACTORIO_DIR}/server-adminlist.json" ] && ARGS+=("--server-adminlist" "${FACTORIO_DIR}/server-adminlist.json")
exec ${BINARY} "${ARGS[@]}"
STARTSCRIPT
  
  if [[ "$MODE" == "setup" ]]; then
    mv /tmp/start-server.sh.tmp /opt/factorio/start-server.sh
    chmod +x /opt/factorio/start-server.sh
    chown factorio:factorio /opt/factorio/start-server.sh
  else
    pct push "$CT_ID" /tmp/start-server.sh.tmp /opt/factorio/start-server.sh
    rm /tmp/start-server.sh.tmp
    pct exec "$CT_ID" -- chmod +x /opt/factorio/start-server.sh
    pct exec "$CT_ID" -- chown factorio:factorio /opt/factorio/start-server.sh
  fi
  msg_ok "Startup script created"

  msg_info "Creating systemd service"
  cat <<'SYSTEMD' > /tmp/factorio.service.tmp
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
ReadWritePaths=/opt/factorio
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SYSTEMD
  
  if [[ "$MODE" == "setup" ]]; then
    mv /tmp/factorio.service.tmp /etc/systemd/system/factorio.service
    systemctl daemon-reload
    systemctl enable factorio
  else
    pct push "$CT_ID" /tmp/factorio.service.tmp /etc/systemd/system/factorio.service
    rm /tmp/factorio.service.tmp
    pct exec "$CT_ID" -- systemctl daemon-reload
    pct exec "$CT_ID" -- systemctl enable factorio
  fi
  msg_ok "Systemd service created"

  # Apply server configuration
  msg_info "Applying server configuration"
  
  # Escape special characters for sed (especially for passwords/tokens)
  escape_sed() {
    echo "$1" | sed -e 's/[\/&]/\\&/g'
  }
  
  # Replace placeholders in server-settings.json
  if [[ "$MODE" == "setup" ]]; then
    sed -i "s/__SERVER_NAME__/$(escape_sed "$SERVER_NAME")/" /opt/factorio/config/server-settings.json
    sed -i "s/__SERVER_DESCRIPTION__/$(escape_sed "$SERVER_DESCRIPTION")/" /opt/factorio/config/server-settings.json
    sed -i "s/__MAX_PLAYERS__/${MAX_PLAYERS}/" /opt/factorio/config/server-settings.json
    sed -i "s/__VISIBILITY_PUBLIC__/${VISIBILITY_PUBLIC}/" /opt/factorio/config/server-settings.json
    sed -i "s/__REQUIRE_USER_VERIFICATION__/${REQUIRE_USER_VERIFICATION}/" /opt/factorio/config/server-settings.json
    sed -i "s/__FACTORIO_USERNAME__/$(escape_sed "${FACTORIO_USERNAME:-}")/" /opt/factorio/config/server-settings.json
    sed -i "s/__FACTORIO_PASSWORD__/$(escape_sed "${FACTORIO_PASSWORD:-}")/" /opt/factorio/config/server-settings.json
    sed -i "s/__FACTORIO_TOKEN__/$(escape_sed "${FACTORIO_TOKEN:-}")/" /opt/factorio/config/server-settings.json
    sed -i "s/__GAME_PASSWORD__/$(escape_sed "${GAME_PASSWORD:-}")/" /opt/factorio/config/server-settings.json
  else
    pct exec "$CT_ID" -- sed -i "s/__SERVER_NAME__/$(escape_sed "$SERVER_NAME")/" /opt/factorio/config/server-settings.json
    pct exec "$CT_ID" -- sed -i "s/__SERVER_DESCRIPTION__/$(escape_sed "$SERVER_DESCRIPTION")/" /opt/factorio/config/server-settings.json
    pct exec "$CT_ID" -- sed -i "s/__MAX_PLAYERS__/${MAX_PLAYERS}/" /opt/factorio/config/server-settings.json
    pct exec "$CT_ID" -- sed -i "s/__VISIBILITY_PUBLIC__/${VISIBILITY_PUBLIC}/" /opt/factorio/config/server-settings.json
    pct exec "$CT_ID" -- sed -i "s/__REQUIRE_USER_VERIFICATION__/${REQUIRE_USER_VERIFICATION}/" /opt/factorio/config/server-settings.json
    pct exec "$CT_ID" -- sed -i "s/__FACTORIO_USERNAME__/$(escape_sed "${FACTORIO_USERNAME:-}")/" /opt/factorio/config/server-settings.json
    pct exec "$CT_ID" -- sed -i "s/__FACTORIO_PASSWORD__/$(escape_sed "${FACTORIO_PASSWORD:-}")/" /opt/factorio/config/server-settings.json
    pct exec "$CT_ID" -- sed -i "s/__FACTORIO_TOKEN__/$(escape_sed "${FACTORIO_TOKEN:-}")/" /opt/factorio/config/server-settings.json
    pct exec "$CT_ID" -- sed -i "s/__GAME_PASSWORD__/$(escape_sed "${GAME_PASSWORD:-}")/" /opt/factorio/config/server-settings.json
  fi
  
  # Create admin list if username is provided
  if [[ -n "$FACTORIO_USERNAME" ]]; then
    if [[ "$MODE" == "setup" ]]; then
      echo "[\"${FACTORIO_USERNAME}\"]" > /opt/factorio/server-adminlist.json
      chown factorio:factorio /opt/factorio/server-adminlist.json
    else
      echo "[\"${FACTORIO_USERNAME}\"]" | pct exec "$CT_ID" -- tee /opt/factorio/server-adminlist.json >/dev/null
      pct exec "$CT_ID" -- chown factorio:factorio /opt/factorio/server-adminlist.json
    fi
    msg_ok "Admin list created (${FACTORIO_USERNAME})"
  fi
  
  msg_ok "Server configuration applied"

  msg_info "Creating dynamic MOTD"
  cat <<'MOTDEOF' > /tmp/10-factorio.tmp
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
  
  if [[ "$MODE" == "setup" ]]; then
    mv /tmp/10-factorio.tmp /etc/update-motd.d/10-factorio
    chmod +x /etc/update-motd.d/10-factorio
    rm -f /etc/motd 2>/dev/null || true
    rm -f /etc/update-motd.d/10-uname 2>/dev/null || true
  else
    pct push "$CT_ID" /tmp/10-factorio.tmp /etc/update-motd.d/10-factorio
    rm /tmp/10-factorio.tmp
    pct exec "$CT_ID" -- chmod +x /etc/update-motd.d/10-factorio
    pct exec "$CT_ID" -- rm -f /etc/motd 2>/dev/null || true
    pct exec "$CT_ID" -- rm -f /etc/update-motd.d/10-uname 2>/dev/null || true
  fi
  msg_ok "Dynamic MOTD created"

  msg_info "Starting Factorio server"
  if [[ "$MODE" == "setup" ]]; then
    systemctl start factorio
  else
    pct exec "$CT_ID" -- systemctl start factorio
  fi
  msg_ok "Factorio server started"

  # Get container IP
  sleep 2
  if [[ "$MODE" == "setup" ]]; then
    CT_IP=$(hostname -I | awk '{print $1}')
  else
    CT_IP=$(pct exec "$CT_ID" -- hostname -I | awk '{print $1}')
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# SYSTEM SETUP (PROVISION MODE)
# ═══════════════════════════════════════════════════════════════════════════

setup_system() {
  if [[ "$MODE" != "setup" ]]; then
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
  fi

  msg_info "Configuring locale"
  if [[ "$MODE" == "setup" ]]; then
    apt-get update -qq || msg_warn "apt-get update had warnings"
    apt-get install -y -qq locales || msg_warn "locales install had warnings"
    echo "en_US.UTF-8 UTF-8" | tee /etc/locale.gen >/dev/null
    locale-gen >/dev/null 2>&1 || true
    update-locale LANG=en_US.UTF-8 >/dev/null 2>&1 || true
  else
    pct exec "$CT_ID" -- apt-get update -qq || msg_warn "apt-get update had warnings"
    pct exec "$CT_ID" -- apt-get install -y -qq locales || msg_warn "locales install had warnings"
    echo "en_US.UTF-8 UTF-8" | pct exec "$CT_ID" -- tee /etc/locale.gen >/dev/null
    pct exec "$CT_ID" -- locale-gen >/dev/null 2>&1 || true
    pct exec "$CT_ID" -- update-locale LANG=en_US.UTF-8 >/dev/null 2>&1 || true
  fi
  msg_ok "Locale configured"

  msg_info "Updating system packages"
  if [[ "$MODE" == "setup" ]]; then
    apt-get upgrade -y -qq || msg_warn "apt-get upgrade had warnings"
  else
    pct exec "$CT_ID" -- apt-get upgrade -y -qq || msg_warn "apt-get upgrade had warnings"
  fi
  msg_ok "System updated"

  msg_info "Installing dependencies"
  if [[ "$MODE" == "setup" ]]; then
    if ! apt-get install -y -qq curl sudo mc xz-utils jq cifs-utils; then
      msg_error "Failed to install dependencies"
      exit 1
    fi
  else
    if ! pct exec "$CT_ID" -- apt-get install -y -qq curl sudo mc xz-utils jq cifs-utils openssh-server; then
      msg_error "Failed to install dependencies"
      exit 1
    fi
  fi
  msg_ok "Dependencies installed"

  if [[ "$MODE" != "setup" ]]; then
    msg_info "Configuring SSH"
    # Set password only if provided
    if [[ -n "$ROOT_PASSWORD" ]]; then
      echo "root:${ROOT_PASSWORD}" | pct exec "$CT_ID" -- chpasswd
    fi
    pct exec "$CT_ID" -- sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config || true
    pct exec "$CT_ID" -- sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config || true
    pct exec "$CT_ID" -- systemctl enable ssh || true
    # Setup SSH public key if provided
    if [[ -n "$SSH_PUBLIC_KEY" ]]; then
      pct exec "$CT_ID" -- mkdir -p /root/.ssh
      pct exec "$CT_ID" -- chmod 700 /root/.ssh
      echo "$SSH_PUBLIC_KEY" | pct exec "$CT_ID" -- tee /root/.ssh/authorized_keys >/dev/null
      pct exec "$CT_ID" -- chmod 600 /root/.ssh/authorized_keys
      msg_ok "SSH Public Key configured"
    fi
    pct exec "$CT_ID" -- systemctl restart ssh
    msg_ok "SSH configured (root login enabled)"

    # Get container IP
    sleep 3
    CT_IP=$(pct exec "$CT_ID" -- hostname -I | awk '{print $1}')
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════

main() {
  header_info
  check_root
  check_pve
  
  case "$MODE" in
    provision)
      # Container provisioning only
      configure_container
      download_template
      create_container
      setup_system
      
      echo ""
      echo -e "${BOLD}${GN}═══════════════════════════════════════════════════════════════${CL}"
      echo -e "${BOLD}${GN}   Container Provisioning Complete!${CL}"
      echo -e "${BOLD}${GN}═══════════════════════════════════════════════════════════════${CL}"
      echo ""
      echo -e "  ${BL}Container ID:${CL}    $CT_ID"
      echo -e "  ${BL}Hostname:${CL}        $CT_HOSTNAME"
      echo -e "  ${BL}IP Address:${CL}      $CT_IP"
      echo ""
      echo -e "  ${YW}Next Steps:${CL}"
      echo -e "    1. Enter the container: ${BOLD}pct enter $CT_ID${CL}"
      echo -e "    2. Run application setup: ${BOLD}bash <(curl -fsSL <URL>) setup${CL}"
      echo -e "       Or copy this script and run: ${BOLD}./factorio-standalone.sh setup${CL}"
      echo ""
      echo -e "  ${BL}SSH Access:${CL}"
      echo -e "    ssh root@$CT_IP"
      echo ""
      echo -e "${BOLD}${GN}═══════════════════════════════════════════════════════════════${CL}"
      ;;
    
    setup)
      # Application setup only (run inside container)
      configure_factorio
      setup_system
      install_factorio
      
      echo ""
      echo -e "${BOLD}${GN}═══════════════════════════════════════════════════════════════${CL}"
      echo -e "${BOLD}${GN}   Factorio Application Setup Complete!${CL}"
      echo -e "${BOLD}${GN}═══════════════════════════════════════════════════════════════${CL}"
      echo ""
      echo -e "  ${BL}Server IP:${CL}       $CT_IP"
      echo -e "  ${BL}Game Port:${CL}       UDP ${GAME_PORT}"
      echo ""
      echo -e "  ${YW}Connect with:${CL}    $CT_IP:${GAME_PORT}"
      echo ""
      echo -e "  ${BL}Server Commands:${CL}"
      echo -e "    systemctl start|stop|restart|status factorio"
      echo ""
      echo -e "  ${BL}Configuration:${CL}"
      echo -e "    /opt/factorio/config/server-settings.json"
      echo ""
      echo -e "  ${BL}Logs:${CL}"
      echo -e "    journalctl -u factorio -f"
      echo ""
      echo -e "${BOLD}${GN}═══════════════════════════════════════════════════════════════${CL}"
      ;;
    
    full)
      # Full installation (container + application)
      configure_container
      configure_factorio
      download_template
      create_container
      setup_system
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
      ;;
  esac
}

main "$@"
