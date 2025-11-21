#!/bin/bash
set -euo pipefail

echo "===================================================="
echo "  SYS-BACKUP-V4 – INSTALLATION (Cloud Edition)"
echo "===================================================="

############################################
### 0) INSTALL KONSTANTEN
############################################

NC_URL="https://nextcloud.r-server.ch/remote.php/dav/files/backup/"
NC_USER="backup"
REMOTE_NAME="backup"
REMOTE_BACKUP_DIR="Server-Backups"

SERVICES_DIR="/opt/services"
COMPOSE_FILE="${SERVICES_DIR}/docker-compose.yml"

LOG_DIR="/var/log/sys-backup-v4"
mkdir -p "$LOG_DIR"

############################################
### 1) SYSTEM UPDATES
############################################

echo "[1/7] System aktualisieren..."
apt update -y
apt install -y curl git unzip ca-certificates gnupg lsb-release rclone

############################################
### 2) DOCKER INSTALLATION
############################################

echo "[2/7] Docker prüfen..."
if ! command -v docker &> /dev/null; then
    echo "❌ Docker nicht gefunden – Installation..."
    curl -fsSL https://get.docker.com | sh
else
    echo "✔️ Docker ist bereits installiert."
fi

############################################
### 3) DOCKER COMPOSE
############################################

echo "[3/7] docker compose prüfen..."
if ! docker compose version &> /dev/null; then
    echo "❌ docker compose fehlt – Installation docker-compose (Standalone)..."
    LATEST_COMPOSE=$(curl -s https://api.github.com/repos/docker/compose/releases/latest \
        | grep browser_download_url | grep linux-x86_64 | cut -d '"' -f 4)
    curl -L "$LATEST_COMPOSE" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
else
    echo "✔️ docker compose ist verfügbar."
fi

############################################
### 4) CADDY INSTALLATION (NEU & STABIL!)
############################################

echo "[4/7] Caddy installieren..."

if ! command -v caddy &> /dev/null; then
    echo "✔️ Installiere Caddy direkt von caddyserver.com (ohne Cloudsmith)..."

    apt install -y debian-keyring debian-archive-keyring apt-transport-https

    # GPG Key installieren
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/caddy.gpg

    # Richtige Repository-Datei
    echo "deb [signed-by=/usr/share/keyrings/caddy.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
        > /etc/apt/sources.list.d/caddy.list

    apt update
    apt install -y caddy
else
    echo "✔️ Caddy ist bereits installiert."
fi

systemctl enable caddy
systemctl restart caddy

############################################
### 5) RCLONE REMOTE EINRICHTEN
############################################

echo "[5/7] rclone Remote '${REMOTE_NAME}' einrichten..."

if rclone listremotes | grep -q "^${REMOTE_NAME}:"; then
    echo "✔️ Remote '${REMOTE_NAME}' existiert bereits."
else
    echo ""
    echo "Nextcloud URL : ${NC_URL}"
    echo "Nextcloud User: ${NC_USER}"
    read -s -p "Bitte Nextcloud Passwort eingeben: " NC_PASS
    echo ""

    rclone config create "${REMOTE_NAME}" webdav \
        url="${NC_URL}" \
        vendor="nextcloud" \
        user="${NC_USER}" \
        pass="${NC_PASS}" \
        --non-interactive

    echo "✔️ Remote '${REMOTE_NAME}' wurde erstellt."
fi

echo "Teste Nextcloud-Verbindung..."

if ! rclone ls "${REMOTE_NAME}:${REMOTE_BACKUP_DIR}" >/dev/null 2>&1; then
    echo "⚠️ Ordner '${REMOTE_BACKUP_DIR}' existiert nicht – wird erzeugt..."
    rclone mkdir "${REMOTE_NAME}:${REMOTE_BACKUP_DIR}"
else
    echo "✔️ Nextcloud erreichbar."
fi

############################################
### 6) DOCKER-COMPOSE ANLEGEN
############################################

echo "[6/7] Erzeuge Docker-Umgebung..."

mkdir -p "$SERVICES_DIR"

cat > "$COMPOSE_FILE" << 'EOF'
version: "3.9"
services:
  portainer:
    image: portainer/portainer-ce:2.21.4
    container_name: portainer
    ports:
      - "9000:9000"
    volumes:
      - services_portainer_data:/data
      - /var/run/docker.sock:/var/run/docker.sock

  openwebui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: openwebui
    ports:
      - "3000:8080"
    volumes:
      - services_openwebui_data:/app/backend/data

  n8n:
    image: docker.n8n.io/n8nio/n8n
    container_name: n8n
    ports:
      - "5678:5678"
    volumes:
      - services_n8n_data:/home/node/.n8n

  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    ports:
      - "11434:11434"
    volumes:
      - services_ollama_data:/root/.ollama

  watchtower:
    image: containrrr/watchtower
    container_name: watchtower
    command: --cleanup --interval 3600
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock

volumes:
  services_portainer_data:
  services_openwebui_data:
  services_n8n_data:
  services_ollama_data:
EOF

############################################
### 7) DOCKER STARTEN
############################################

echo "[7/7] Starte Docker-Dienste..."
docker compose -f "$COMPOSE_FILE" up -d

echo "===================================================="
echo " Installation abgeschlossen!"
echo "===================================================="
