# Factorio Dedicated Server - Proxmox LXC

Ein automatisierter Installer für einen Factorio Dedicated Server als Proxmox LXC Container.

## 🚀 Schnellstart

Auf der **Proxmox VE Shell** ausführen:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/m-bck/factorio-server/main/proxmox/factorio-standalone.sh)"
```

Das Script führt dich durch einen interaktiven Wizard und erledigt alles automatisch.

## ✨ Features

- **Ein-Befehl-Installation** – Wie die bekannten [Proxmox VE Helper Scripts](https://community-scripts.github.io/ProxmoxVE/)
- **Interaktiver Wizard** – Konfiguration von Container, Netzwerk und Factorio Server
- **Automatische Updates** – Factorio lässt sich einfach aktualisieren
- **Public/Private Server** – Wahl zwischen öffentlicher Listung oder privatem LAN-Server
- **Systemd Service** – Automatischer Start, einfache Verwaltung

## 📋 Voraussetzungen

- Proxmox VE 7.x oder 8.x
- Internetzugang für Template-Download
- Optional: Factorio.com Account für öffentliche Server

## 🔧 Was der Installer konfiguriert

| Komponente | Details |
|------------|---------|
| OS | Debian 12 (Bookworm) |
| Default CPU | 2 Cores |
| Default RAM | 2048 MB |
| Default Disk | 8 GB |
| Game Port | UDP 34197 |
| User | `factorio` (non-root) |
| Service | systemd (`factorio.service`) |
| Container | Unprivilegiert (sicher) |

## 📁 Projektstruktur

```
factorio-server/
├── proxmox/
│   ├── factorio-standalone.sh    # ⭐ Hauptinstaller
│   └── README.md                 # Ausführliche Doku
├── upload-save.ps1               # Save Upload (Windows)
├── upload-save.sh                # Save Upload (Linux/Mac)
├── .gitignore
└── README.md                     # Diese Datei
```

## 📤 Eigenen Speicherstand hochladen

### Windows (PowerShell)

```powershell
.\upload-save.ps1
```

### Linux / Mac

```bash
chmod +x upload-save.sh
./upload-save.sh
```

Das Script:
1. Fragt nach Server-IP und Save-Datei
2. Lädt die Datei per SCP hoch
3. Benennt optional zu `world.zip` um
4. Startet den Server neu

## ⚙️ Nach der Installation

### Server verwalten

```bash
# In den Container wechseln
pct enter <CTID>

# Server steuern
systemctl start factorio
systemctl stop factorio
systemctl restart factorio
systemctl status factorio

# Logs live anzeigen
journalctl -u factorio -f
```

### Konfiguration anpassen

Im Container:

```bash
# Server-Einstellungen bearbeiten
nano /opt/factorio/config/server-settings.json

# Nach Änderungen neu starten
systemctl restart factorio
```

### Wichtige Pfade im Container

| Pfad | Beschreibung |
|------|--------------|
| `/opt/factorio/saves/` | Savegames |
| `/opt/factorio/mods/` | Mods |
| `/opt/factorio/config/server-settings.json` | Server-Konfiguration |
| `/opt/factorio/config/server-adminlist.json` | Admin-Liste |
| `/backup/` | Backup-Verzeichnis |

## 🔄 Server updaten

Im Container:

```bash
# Aktuellen Status prüfen
cat /opt/factorio/data/base/info.json | jq '.version'

# Update durchführen
systemctl stop factorio
curl -fsSL "https://factorio.com/get-download/stable/headless/linux64" -o /tmp/factorio.tar.xz
tar -xJf /tmp/factorio.tar.xz -C /opt --overwrite
chown -R factorio:factorio /opt/factorio
systemctl start factorio
```

## 🔥 Firewall & Port-Forwarding

### Proxmox Firewall

Falls aktiv, Port freigeben:

```bash
# In /etc/pve/firewall/cluster.fw oder per GUI
[RULES]
IN UDP -p 34197 -j ACCEPT
```

### Router Port-Forwarding

| Protokoll | Extern | Intern | Ziel |
|-----------|--------|--------|------|
| UDP | 34197 | 34197 | Container-IP |

## 💾 Backup

### Manuelles Backup

```bash
/opt/factorio/backup.sh
```

### Automatisches Backup

Wird per Cron täglich um 4:00 Uhr ausgeführt.

### Samba Backup nachträglich einrichten

```bash
# Credentials speichern
echo "username=backup_user" > /root/.smbcredentials
echo "password=backup_pass" >> /root/.smbcredentials
chmod 600 /root/.smbcredentials

# Mount konfigurieren
echo "//192.168.1.100/backup/factorio /backup cifs credentials=/root/.smbcredentials,uid=factorio,gid=factorio 0 0" >> /etc/fstab
mount -a
```

## 🐛 Troubleshooting

### Server startet nicht

```bash
journalctl -u factorio --no-pager -n 50
```

### Kein Savegame vorhanden

```bash
sudo -u factorio /opt/factorio/bin/x64/factorio --create /opt/factorio/saves/world.zip
```

### Spieler können nicht beitreten

1. Firewall-Regeln prüfen
2. Port-Forwarding im Router prüfen
3. In `server-settings.json`: `"visibility": {"lan": true}`

## 📖 Weitere Dokumentation

Ausführliche Dokumentation: [proxmox/README.md](proxmox/README.md)

## 📜 Lizenz

MIT License - Factorio ist ein Produkt von Wube Software.
