# Factorio Proxmox LXC Installer

A Proxmox Helper Script for automatically creating a Factorio Dedicated Server LXC Container.

## 🚀 Quick Start

### Full Installation (Default)

Run on the **Proxmox VE Shell** for a complete installation (container + application):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/m-bck/factorio-server/main/proxmox/factorio-standalone.sh)"
```

The script guides you through an interactive wizard:
- Container ID, Hostname
- CPU, RAM, Disk
- Network (DHCP or static IP)
- Storage selection
- Server name, description
- Public/Private (with Factorio.com credentials)
- Optional game password
- Optional: SSH Public Key for passwordless access

## 📋 Script Modes

The `factorio-standalone.sh` script supports three modes of operation for flexible deployment:

### Mode 1: Full Installation (Default)
Complete installation - provisions container and installs application:

```bash
./factorio-standalone.sh
# or
./factorio-standalone.sh full
```

### Mode 2: Container Provisioning Only
Creates and configures the LXC container without installing Factorio:

```bash
./factorio-standalone.sh provision
```

**What it does:**
- Creates LXC container with specified resources
- Configures networking (DHCP or static IP)
- Sets up SSH access
- Installs system dependencies
- Updates and configures OS

### Mode 3: Application Setup Only
Installs Factorio on an existing container (run inside the container):

```bash
./factorio-standalone.sh setup
```

**What it does:**
- Creates factorio user and directories
- Downloads and installs Factorio headless server
- Configures server settings
- Creates systemd service for auto-start
- Sets up dynamic MOTD

## 🔧 Usage Scenarios

### Scenario 1: Quick Full Installation
Use this when you want everything done in one go:

```bash
# On Proxmox host
bash -c "$(curl -fsSL https://raw.githubusercontent.com/m-bck/factorio-server/main/proxmox/factorio-standalone.sh)"
```

### Scenario 2: Separate Provisioning and Setup
Use this when you want to provision multiple containers first, then install applications later:

```bash
# Step 1: On Proxmox host - create container
./factorio-standalone.sh provision

# Step 2: Enter the container
pct enter <CT_ID>

# Step 3: Inside container - install Factorio
./factorio-standalone.sh setup
```

### Scenario 3: Existing Container Setup
Use this when you already have a VM or container and only want to install Factorio:

```bash
# Inside container/VM - install Factorio only
./factorio-standalone.sh setup

## 📁 Project Structure

```
proxmox/
├── factorio-standalone.sh    # Multi-mode installer script
└── README.md                 # German documentation
└── README.en.md              # English documentation
```

## 🔍 Requirements

- Proxmox VE 7.x or 8.x
- Internet connection for template and Factorio download
- Minimum 2GB RAM, 2 CPU cores, 8GB disk space
- Root access on Proxmox host (for provisioning modes)

## ⚙️ After Installation

### Server Management

```bash
# Enter the container
pct enter <CTID>

# Control the server
systemctl start factorio
systemctl stop factorio
systemctl restart factorio
systemctl status factorio

# View logs
journalctl -u factorio -f
```

### Modify Configuration

```bash
# Server settings
nano /opt/factorio/config/server-settings.json

# Restart after changes
systemctl restart factorio
```

### Important Files

| Path | Description |
|------|-------------|
| `/opt/factorio/saves/` | Savegames (including autosaves) |
| `/opt/factorio/mods/` | Mods |
| `/opt/factorio/config/server-settings.json` | Server configuration |
| `/opt/factorio/server-adminlist.json` | Admin list |

## 🔄 Updates

Run inside the container:

```bash
# Inside the container
systemctl stop factorio
cd /tmp
curl -fsSL "https://factorio.com/get-download/stable/headless/linux64" -o factorio.tar.xz
tar -xJf factorio.tar.xz -C /opt --overwrite
chown -R factorio:factorio /opt/factorio
systemctl start factorio
```

## 🔥 Firewall

If a firewall is active, open port 34197/UDP:

### Proxmox Firewall (Datacenter)

```bash
# /etc/pve/firewall/cluster.fw
[RULES]
IN UDP -p 34197 -j ACCEPT
```

### Container Firewall

```bash
# Inside the container
ufw allow 34197/udp
```

### Router Port Forwarding

| Protocol | External | Internal | Target |
|----------|----------|----------|--------|
| UDP | 34197 | 34197 | Container IP |

## 💾 Backup

### Factorio Autosave

Factorio automatically creates autosaves (default every 5 minutes) in `/opt/factorio/saves/`.

### Proxmox Container Backup (recommended)

Use the integrated Proxmox Backup for the entire container:

**Via GUI:**
1. Datacenter → Backup → Add
2. Select storage, schedule and container
3. Configure retention policy

**Via Command Line:**
```bash
# One-time backup
vzdump <CTID> --storage <backup-storage> --mode snapshot

# Scheduled backup (cron)
echo "0 3 * * * root vzdump <CTID> --storage local --mode snapshot --prune-backups keep-last=7" > /etc/cron.d/factorio-backup
```

## 🐛 Troubleshooting

### Server won't start

```bash
# Check logs
journalctl -u factorio --no-pager -n 50

# Start manually for debugging
sudo -u factorio /opt/factorio/bin/x64/factorio --start-server /opt/factorio/saves/world.zip
```

### No savegame available

```bash
# Create new savegame
sudo -u factorio /opt/factorio/bin/x64/factorio --create /opt/factorio/saves/world.zip
```

### Players cannot join

1. Check firewall rules
2. Check port forwarding in router
3. `visibility.lan: true` in server-settings.json

### Container has no IP

```bash
# On Proxmox host
pct exec <CTID> -- ip addr
pct exec <CTID> -- cat /etc/network/interfaces
pct exec <CTID> -- systemctl restart networking
```

## 📄 License

MIT License
