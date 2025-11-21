#!/bin/bash
set -euo pipefail

############################################################
# SYS-BACKUP-V4 – RESTORE AUS NEXTCLOUD (AUTO MODEL RESTORE)
############################################################

REMOTE_NAME="backup"
REMOTE_DIR="Server-Backups"
MODEL_DIR="Server-Backups/models"

TMP_BASE="/tmp/sys-backup-v4-restore"
LOG_DIR="/var/log/sys-backup-v4"

SERVICES_DIR="/opt/services"
COMPOSE_FILE="${SERVICES_DIR}/docker-compose.yml"

mkdir -p "$LOG_DIR" "$TMP_BASE"

LOG="${LOG_DIR}/restore.log"

echo "--------------------------------------------------------" | tee -a "$LOG"
echo " SYS-BACKUP-V4 – RESTORE SYSTEM" | tee -a "$LOG"
echo "--------------------------------------------------------" | tee -a "$LOG"
echo "" | tee -a "$LOG"

############################################################
### 1) LISTE DER BACKUPS AUS NEXTCLOUD
############################################################

echo "Lese Backups aus Nextcloud..." | tee -a "$LOG"

mapfile -t BACKUPS < <(rclone lsd "${REMOTE_NAME}:${REMOTE_DIR}" | awk '{print $5}' | sort)

if [[ ${#BACKUPS[@]} -eq 0 ]]; then
  echo "❌ Keine Backups gefunden!" | tee -a "$LOG"
  exit 1
fi

echo "Verfügbare Backups:" | tee -a "$LOG"
i=1
declare -A OPT
for B in "${BACKUPS[@]}"; do
  OPT[$i]="$B"
  echo "  $i) $B" | tee -a "$LOG"
  ((i++))
done

echo ""
read -p "Bitte Backup-Nummer wählen: " CHOICE

SELECTED="${OPT[$CHOICE]:-}"
if [[ -z "$SELECTED" ]]; then
  echo "❌ Ungültige Auswahl!" | tee -a "$LOG"
  exit 1
fi

BACKUP_NAME="$SELECTED"
REMOTE_PATH="${REMOTE_NAME}:${REMOTE_DIR}/${BACKUP_NAME}"

echo ""
echo "Backup gewählt: ${BACKUP_NAME}" | tee -a "$LOG"

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
  echo "❌ Manifest fehlt!" | tee -a "$LOG"
  exit 1
fi

echo "Manifest gefunden." | tee -a "$LOG"

############################################################
### 3) MANIFEST PARSEN (V4)
############################################################

BACKUP_HOST=$(awk -F': ' '/^host:/ {print $2}' "$MANIFEST" | tr -d '"')
BACKUP_IP=$(awk -F': ' '/^ip:/ {print $2}' "$MANIFEST" | tr -d '"')
MODELS_EXCLUDED=$(awk -F': ' '/models_excluded:/ {print $2}' "$MANIFEST")

echo ""
echo "Backup Informationen:" | tee -a "$LOG"
echo "  Host:   ${BACKUP_HOST}" | tee -a "$LOG"
echo "  IP:     ${BACKUP_IP}" | tee -a "$LOG"
echo "  Modelle excluded: ${MODELS_EXCLUDED}" | tee -a "$LOG"
echo "" | tee -a "$LOG"

############################################################
### 4) SYSTEM VORBEREITEN
############################################################

echo "Stoppe laufende Docker-Container..." | tee -a "$LOG"
docker stop $(docker ps -q) >/dev/null 2>&1 || true

############################################################
### 5) VOLUMES RESTORE
############################################################

echo ""
echo "Starte Volume-Restore..." | tee -a "$LOG"

VOL_LIST=$(awk '
/^volumes:/ {read; while ($0 ~ /^[[:space:]]+- /) {gsub(/^[[:space:]]+- /,""); print; getline}}
' "$MANIFEST")

for VOL in $VOL_LIST; do
  TAR="${TMP_DIR}/volumes/${VOL}.tar.zst"

  if [[ ! -f "$TAR" ]]; then
    echo "⚠️ Volume fehlt: $TAR" | tee -a "$LOG"
    continue
  fi

  echo "  Restore Volume: ${VOL}" | tee -a "$LOG"
  docker volume create "$VOL" >/dev/null

  docker run --rm \
    -v "${VOL}":/restore \
    -v "${TAR}":/backup.tar.zst \
    alpine sh -c "rm -rf /restore/* && zstd -d < /backup.tar.zst | tar -xf - -C /restore"

done

############################################################
### 6) BIND MOUNTS RESTORE
############################################################

echo ""
echo "Starte Bind-Mount Restore..." | tee -a "$LOG"

BM_LIST=$(awk '
/^bind_mounts:/ {read; while ($0 ~ /^[[:space:]]+- /) {gsub(/^[[:space:]]+- /,""); print; getline}}
' "$MANIFEST")

for SRC in $BM_LIST; do
  NAME="$(echo "$SRC" | sed 's#/#_#g')"
  TAR="${TMP_DIR}/bind_mounts/${NAME}.tar.zst"

  if [[ ! -f "$TAR" ]]; then
    echo "⚠️ Bind-Mount fehlt: $TAR" | tee -a "$LOG"
    continue
  fi

  echo "  Restore: ${SRC}" | tee -a "$LOG"
  mkdir -p "$SRC"
  zstd -d < "$TAR" | tar -xf - -C /
done

############################################################
### 7) DOCKER WIEDER STARTEN
############################################################

if [[ -f "$COMPOSE_FILE" ]]; then
  echo "Starte Docker Services..." | tee -a "$LOG"
  cd "$SERVICES_DIR"
  docker compose up -d | tee -a "$LOG"
else
  echo "⚠️ docker-compose.yml NICHT gefunden!" | tee -a "$LOG"
fi

############################################################
### 8) MODEL RESTORE (AUTO-DOWNLOAD)
############################################################

echo ""
echo "Überprüfe Modell-Status..." | tee -a "$LOG"

if [[ "$MODELS_EXCLUDED" == "true" ]]; then
  echo "Modelle wurden im Backup ausgeschlossen. Lade Modelle automatisch nach..." | tee -a "$LOG"

  OLLAMA_LIST=$(awk '
/^ollama_models:/ {read; while ($0 ~ /^[[:space:]]+- /) {gsub(/^[[:space:]]+- /,""); print; getline}}
' "$MANIFEST")

  for M in $OLLAMA_LIST; do
    echo "  💾 Lade Ollama Modell: $M" | tee -a "$LOG"
    ollama pull "$M" | tee -a "$LOG"
  done

  OPENWEBUI_LIST=$(awk '
/^openwebui_models:/ {read; while ($0 ~ /^[[:space:]]+- /) {gsub(/^[[:space:]]+- /,""); print; getline}}
' "$MANIFEST")

  for M in $OPENWEBUI_LIST; do
    echo "  💾 Stelle OpenWebUI Modell wieder her: $M" | tee -a "$LOG"
    mkdir -p "/opt/services/openwebui/models/$M"
    # Modelle werden NICHT gesichert – nur Ordner angelegt
  done

fi

############################################################
### 9) CADDY NEU LADEN
############################################################

echo "Lade Caddy neu..." | tee -a "$LOG"
systemctl reload caddy || systemctl restart caddy

############################################################
### 10) TEMP-DATEN LÖSCHEN
############################################################

rm -rf "$TMP_DIR"

############################################################
### 11) ABSCHLUSS
############################################################

echo ""
echo "--------------------------------------------------------" | tee -a "$LOG"
echo "RESTORE ERFOLGREICH!" | tee -a "$LOG"
echo "Backup: ${BACKUP_NAME}" | tee -a "$LOG"
echo "--------------------------------------------------------" | tee -a "$LOG"
echo ""
