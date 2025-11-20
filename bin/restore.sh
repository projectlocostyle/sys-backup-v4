#!/bin/bash
set -euo pipefail

############################################################
# SYS-BACKUP-V4 – RESTORE AUS NEXTCLOUD
############################################################

REMOTE_NAME="backup"
REMOTE_DIR="Server-Backups"
TMP_BASE="/tmp/sys-backup-v4-restore"
LOG_DIR="/var/log/sys-backup-v4"

SERVICES_DIR="/opt/services"
COMPOSE_FILE="${SERVICES_DIR}/docker-compose.yml"

mkdir -p "$LOG_DIR" "$TMP_BASE"

LOG="${LOG_DIR}/restore.log"

echo "--------------------------------------------------------" | tee -a "$LOG"
echo " SYS-BACKUP-V4 – RESTORE SYSTEM (Nextcloud Cloud Edition)" | tee -a "$LOG"
echo "--------------------------------------------------------" | tee -a "$LOG"
echo "" | tee -a "$LOG"

############################################################
### 1) LISTE DER BACKUPS AUS NEXTCLOUD
############################################################

echo "Lese Backups aus Nextcloud (${REMOTE_NAME}:${REMOTE_DIR})..." | tee -a "$LOG"

mapfile -t REMOTE_LIST < <(rclone lsd "${REMOTE_NAME}:${REMOTE_DIR}" | awk '{print $5}' | sort)

if [[ ${#REMOTE_LIST[@]} -eq 0 ]]; then
  echo "❌ Keine Backups in Nextcloud gefunden!" | tee -a "$LOG"
  exit 1
fi

echo "Verfügbare Backups:" | tee -a "$LOG"
echo ""

i=1
declare -A OPTIONS
for B in "${REMOTE_LIST[@]}"; do
  OPTIONS[$i]="$B"
  echo "  ${i}) ${B}" | tee -a "$LOG"
  ((i++))
done

echo ""
read -p "Bitte Backup-Nummer wählen: " CHOICE

SELECTED="${OPTIONS[$CHOICE]:-}"

if [[ -z "$SELECTED" ]]; then
  echo "❌ Ungültige Auswahl!" | tee -a "$LOG"
  exit 1
fi

BACKUP_NAME="$SELECTED"
REMOTE_PATH="${REMOTE_NAME}:${REMOTE_DIR}/${BACKUP_NAME}"

echo "" | tee -a "$LOG"
echo "Backup gewählt: ${BACKUP_NAME}" | tee -a "$LOG"
echo "Remote-Pfad   : ${REMOTE_PATH}" | tee -a "$LOG"
echo "" | tee -a "$LOG"

############################################################
### 2) BACKUP HERUNTERLADEN
############################################################

TMP_DIR="${TMP_BASE}/${BACKUP_NAME}"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

echo "Lade Backup nach ${TMP_DIR}..." | tee -a "$LOG"
rclone copy "${REMOTE_PATH}" "$TMP_DIR" -P | tee -a "$LOG"

MANIFEST="${TMP_DIR}/manifest.yml"

if [[ ! -f "$MANIFEST" ]]; then
  echo "❌ Manifest nicht gefunden: ${MANIFEST}" | tee -a "$LOG"
  exit 1
fi

echo "" | tee -a "$LOG"
echo "Manifest gefunden!" | tee -a "$LOG"

############################################################
### 3) MANIFEST PARSEN
############################################################

BACKUP_HOST=$(grep '^host:' "$MANIFEST" | awk -F': ' '{print $2}' | tr -d '"')
BACKUP_IP=$(grep '^ip:' "$MANIFEST" | awk -F': ' '{print $2}' | tr -d '"')
BACKUP_TS=$(grep '^timestamp:' "$MANIFEST" | awk -F': ' '{print $2}' | tr -d '"')

echo "" | tee -a "$LOG"
echo "Backup Infos:" | tee -a "$LOG"
echo "  Host: ${BACKUP_HOST}" | tee -a "$LOG"
echo "  IP:   ${BACKUP_IP}" | tee -a "$LOG"
echo "  Zeit: ${BACKUP_TS}" | tee -a "$LOG"
echo "" | tee -a "$LOG"

############################################################
### 4) DOCKER STOPPEN
############################################################

echo "Stoppe Docker-Container..." | tee -a "$LOG"
docker stop $(docker ps -q) 2>/dev/null || true
echo "" | tee -a "$LOG"

############################################################
### 5) VOLUME RESTORE
############################################################

echo "Starte Volume-Restore..." | tee -a "$LOG"
echo "" | tee -a "$LOG"

VOL_LIST=$(awk '
/^volumes:/ {in_vol=1; next}
in_vol && /^bind_mounts:/ {in_vol=0}
in_vol && /^  - / {gsub(/^  - /, ""); print}
' "$MANIFEST")

for VOL in $VOL_LIST; do
  TAR="${TMP_DIR}/volumes/${VOL}.tar.gz"
  if [[ ! -f "$TAR" ]]; then
    echo "⚠️ Volume fehlt: ${TAR}" | tee -a "$LOG"
    continue
  fi
  echo "  Restore Volume: ${VOL}" | tee -a "$LOG"
  docker volume create "$VOL" >/dev/null
  docker run --rm \
    -v "${VOL}":/restore \
    -v "${TAR}":/backup.tar.gz \
    alpine sh -c "rm -rf /restore/* && tar -xzf /backup.tar.gz -C /restore"
  echo "  ✔ Erfolgreich: ${VOL}" | tee -a "$LOG"
done

echo "" | tee -a "$LOG"

############################################################
### 6) BIND-MOUNTS RESTORE
############################################################

echo "Starte Bind-Mount Restore..." | tee -a "$LOG"
echo "" | tee -a "$LOG"

BIND_LIST=$(awk '
/^bind_mounts:/ {in_bm=1; next}
in_bm && /^[^ ]/ {in_bm=0}
in_bm && /^  - / {gsub(/^  - /, ""); print}
' "$MANIFEST")

for SRC in $BIND_LIST; do
  NAME="$(echo "$SRC" | sed 's#/#_#g')"
  TAR="${TMP_DIR}/bind_mounts/${NAME}.tar.gz"
  if [[ ! -f "$TAR" ]]; then
    echo "⚠️ Bind-Mount fehlt: ${TAR}" | tee -a "$LOG"
    continue
  fi
  echo "  Restore Bind-Mount: ${SRC}" | tee -a "$LOG"
  mkdir -p "$SRC"
  tar -xzf "$TAR" -C / >/dev/null 2>&1 || tar -xzf "$TAR" -C "$SRC"
  echo "  ✔ Erfolgreich: ${SRC}" | tee -a "$LOG"
done

echo "" | tee -a "$LOG"

############################################################
### 7) DOCKER WIEDER STARTEN
############################################################

if [[ -f "$COMPOSE_FILE" ]]; then
  echo "Starte Docker-Services..." | tee -a "$LOG"
  cd "$SERVICES_DIR"
  docker compose up -d | tee -a "$LOG"
else
  echo "⚠️ docker-compose.yml NICHT gefunden unter ${COMPOSE_FILE}!" | tee -a "$LOG"
fi

echo "" | tee -a "$LOG"

############################################################
### 8) CADDY NEU LADEN
############################################################

echo "Lade Caddy neu..." | tee -a "$LOG"
systemctl reload caddy || systemctl restart caddy || true
echo "" | tee -a "$LOG"

############################################################
### 9) TEMP DATEN LÖSCHEN
############################################################

echo "Bereinige temporäre Restore-Daten..." | tee -a "$LOG"
rm -rf "$TMP_DIR"
echo "" | tee -a "$LOG"

############################################################
### 10) ABSCHLUSS
############################################################

echo "--------------------------------------------------------" | tee -a "$LOG"
echo "Restore erfolgreich abgeschlossen!" | tee -a "$LOG"
echo "Backup: ${BACKUP_NAME}" | tee -a "$LOG"
echo "--------------------------------------------------------" | tee -a "$LOG"
echo "" | tee -a "$LOG"
