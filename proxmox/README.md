# Factorio Proxmox LXC Installer

Ein Proxmox Helper Script zum automatischen Erstellen eines Factorio Dedicated Server LXC Containers.

## 🚀 Schnellstart

### Vollständige Installation (Standard)

Auf der **Proxmox VE Shell** ausführen für eine vollständige Installation (Container + Anwendung):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/m-bck/factorio-server/main/proxmox/factorio-standalone.sh)"
```

Das Script führt dich durch einen interaktiven Wizard:
- Container ID, Hostname
- CPU, RAM, Disk
- Netzwerk (DHCP oder statische IP)
- Storage-Auswahl
- Server-Name, Beschreibung
- Öffentlich/Privat (mit Factorio.com Credentials)
- Optionales Spiel-Passwort
- Optional: SSH Public Key für passwortlosen Zugriff

## 📋 Script-Modi

Das `factorio-standalone.sh` Script unterstützt drei Betriebsmodi für flexible Bereitstellung:

### Modus 1: Vollständige Installation (Standard)
Komplette Installation - erstellt Container und installiert Anwendung:

```bash
./factorio-standalone.sh
# oder
./factorio-standalone.sh full
```

### Modus 2: Nur Container-Bereitstellung
Erstellt und konfiguriert den LXC Container ohne Factorio zu installieren:

```bash
./factorio-standalone.sh provision
```

**Was es macht:**
- Erstellt LXC Container mit angegebenen Ressourcen
- Konfiguriert Netzwerk (DHCP oder statische IP)
- Richtet SSH-Zugriff ein
- Installiert System-Abhängigkeiten
- Aktualisiert und konfiguriert das OS

### Modus 3: Nur Anwendungs-Setup
Installiert Factorio auf einem existierenden Container (im Container ausführen):

```bash
./factorio-standalone.sh setup
```

**Was es macht:**
- Erstellt factorio Benutzer und Verzeichnisse
- Lädt Factorio Headless Server herunter und installiert ihn
- Konfiguriert Server-Einstellungen
- Erstellt systemd Service für Auto-Start
- Richtet dynamisches MOTD ein

## 🔧 Nutzungsszenarien

### Szenario 1: Schnelle Vollinstallation
Verwende dies, wenn du alles auf einmal erledigen möchtest:

```bash
# Auf Proxmox Host
bash -c "$(curl -fsSL https://raw.githubusercontent.com/m-bck/factorio-server/main/proxmox/factorio-standalone.sh)"
```

### Szenario 2: Getrennte Bereitstellung und Setup
Verwende dies, wenn du zunächst mehrere Container bereitstellen und später Anwendungen installieren möchtest:

```bash
# Schritt 1: Auf Proxmox Host - Container erstellen
./factorio-standalone.sh provision

# Schritt 2: In den Container wechseln
pct enter <CT_ID>

# Schritt 3: Im Container - Factorio installieren
./factorio-standalone.sh setup
```

### Szenario 3: Setup auf existierendem Container
Verwende dies, wenn du bereits eine VM oder einen Container hast und nur Factorio installieren möchtest:

```bash
# Im Container/VM - Nur Factorio installieren
./factorio-standalone.sh setup
```

## 💡 Warum separate Modi?

1. **Flexibilität**: Container in Stapeln bereitstellen, Apps einzeln installieren
2. **Fehlerbehebung**: Nur die fehlerhafte Phase erneut ausführen
3. **Wiederverwendbarkeit**: Container-Bereitstellung für andere Game-Server nutzen
4. **Testen**: Container-Setup separat von Anwendungs-Deployment testen
5. **Automatisierung**: Einfachere Integration in CI/CD-Pipelines

## 📁 Projektstruktur

```
proxmox/
├── factorio-standalone.sh    # Multi-Modus Installer Script
└── README.md                 # Deutsche Dokumentation
└── README.en.md              # Englische Dokumentation
```

## 🔍 Anforderungen

- Proxmox VE 7.x oder 8.x
- Internetverbindung für Template- und Factorio-Download
- Minimum 2GB RAM, 2 CPU-Kerne, 8GB Disk-Speicher
- Root-Zugriff auf Proxmox Host (für Bereitstellungs-Modi)

## ⚙️ Nach der Installation

### Server-Verwaltung

```bash
# In den Container wechseln
pct enter <CTID>

# Server steuern
systemctl start factorio
systemctl stop factorio
systemctl restart factorio
systemctl status factorio

# Logs anzeigen
journalctl -u factorio -f
```

### Konfiguration anpassen

```bash
# Server-Einstellungen
nano /opt/factorio/config/server-settings.json

# Nach Änderungen neu starten
systemctl restart factorio
```

### Wichtige Dateien

| Pfad | Beschreibung |
|------|--------------|
| `/opt/factorio/saves/` | Savegames (inkl. Autosaves) |
| `/opt/factorio/mods/` | Mods |
| `/opt/factorio/config/server-settings.json` | Server-Konfiguration |
| `/opt/factorio/server-adminlist.json` | Admin-Liste |

## 🔄 Updates

Im Container ausführen:

```bash
# Im Container
systemctl stop factorio
cd /tmp
curl -fsSL "https://factorio.com/get-download/stable/headless/linux64" -o factorio.tar.xz
tar -xJf factorio.tar.xz -C /opt --overwrite
chown -R factorio:factorio /opt/factorio
systemctl start factorio
```

## 🔥 Firewall

Falls eine Firewall aktiv ist, Port 34197/UDP freigeben:

### Proxmox Firewall (Datacenter)

```bash
# /etc/pve/firewall/cluster.fw
[RULES]
IN UDP -p 34197 -j ACCEPT
```

### Container Firewall

```bash
# Im Container
ufw allow 34197/udp
```

### Router Port-Forwarding

| Protokoll | Extern | Intern | Ziel |
|-----------|--------|--------|------|
| UDP | 34197 | 34197 | Container-IP |

## 💾 Backup

### Factorio Autosave

Factorio erstellt automatisch Autosaves (default alle 5 Minuten) in `/opt/factorio/saves/`.

### Proxmox Container Backup (empfohlen)

Nutze das integrierte Proxmox Backup für den gesamten Container:

**Über die GUI:**
1. Datacenter → Backup → Add
2. Storage, Schedule und Container auswählen
3. Retention Policy konfigurieren

**Per Kommandozeile:**
```bash
# Einmaliges Backup
vzdump <CTID> --storage <backup-storage> --mode snapshot

# Geplantes Backup (cron)
echo "0 3 * * * root vzdump <CTID> --storage local --mode snapshot --prune-backups keep-last=7" > /etc/cron.d/factorio-backup
```

## 🐛 Troubleshooting

### Server startet nicht

```bash
# Logs prüfen
journalctl -u factorio --no-pager -n 50

# Manuell starten zum Debuggen
sudo -u factorio /opt/factorio/bin/x64/factorio --start-server /opt/factorio/saves/world.zip
```

### Kein Savegame vorhanden

```bash
# Neues Savegame erstellen
sudo -u factorio /opt/factorio/bin/x64/factorio --create /opt/factorio/saves/world.zip
```

### Spieler können nicht beitreten

1. Firewall-Regeln prüfen
2. Port-Forwarding im Router prüfen
3. `visibility.lan: true` in server-settings.json

### Container hat keine IP

```bash
# Im Proxmox Host
pct exec <CTID> -- ip addr
pct exec <CTID> -- cat /etc/network/interfaces
pct exec <CTID> -- systemctl restart networking
```

## 📄 Lizenz

MIT License
