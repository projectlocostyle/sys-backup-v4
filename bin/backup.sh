#!/bin/bash
set -euo pipefail

############################################################
# SYS-BACKUP-V4 – CLOUD-ONLY BACKUP
############################################################

REMOTE_NAME="backup"
REMOTE_DIR="Server-Backups"

LOG_DIR="/var/log/sys-backup-v4"
TMP_BASE="/tmp/sys-backup-v4"
mkdir -p "$LOG_DIR" "$TMP_BASE"

TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
BACKUP_NAME="backup_${TIMESTAMP}"
TMP_DIR="${TMP_BASE}/${BACKUP_NAME}"

LOG="${LOG_DIR}/backup.log"

echo "--------------------------------------------------------" | tee -a "$LOG"
echo "SYS-BACKUP-V4 BACKUP gestartet: ${TIMESTAMP}" | tee -a "$LOG"
echo "--------------------------------------------------------" | tee -a "$LOG"

mkdir -p "${TMP_DIR}/volumes" "${TMP_DIR}/bind_mounts"

############################################################
### 1) DOCKER VOLUMES SICHERN
############################################################

echo "Starte Volume-Backup..." | tee -a "$LOG"

if command -v docker &>/dev/null; then
    docker volume ls -q | while read -r VOL; do
        [ -z "$VOL" ] && continue
        ARCHIVE="${TMP_DIR}/volumes/${VOL}.tar.gz"
        echo "  Volume: ${VOL}" | tee -a "$LOG"

        docker run --rm \
            -v "${VOL}":/data \
            -v "${TMP_DIR}/volumes":/backup \
            alpine sh -c "cd /data && tar -czf /backup/$(basename "$ARCHIVE") ."
    done
else
    echo "⚠️ Docker nicht installiert, überspringe Volume-Backup." | tee -a "$LOG"
fi

############################################################
### 2) WICHTIGE HOST-PFADE SICHERN
############################################################

echo "Starte Bind-Mount / Host-Pfad Backup..." | tee -a "$LOG"

BIND_PATHS=(
    "/etc/caddy"
    "/var/lib/caddy"
    "/opt/services"
    "/root/.config/rclone"
    "/opt/sys-backup-v4"
)

for SRC in "${BIND_PATHS[@]}"; do
    NAME="$(echo "$SRC" | sed 's#/#_#g')"
    ARCHIVE="${TMP_DIR}/bind_mounts/${NAME}.tar.gz"

    echo "  Pfad: ${SRC}" | tee -a "$LOG"

    if [ -d "$SRC" ] || [ -f "$SRC" ]; then
        tar -czf "$ARCHIVE" -C / "${SRC#/}"
    else
        echo "  ⚠️ Pfad existiert nicht: ${SRC}" | tee -a "$LOG"
    fi
done

############################################################
### 3) HASHES ERZEUGEN
############################################################

echo "Erzeuge Hashes..." | tee -a "$LOG"

(
    cd "$TMP_DIR"
    find . -type f -name '*.tar.gz' -print0 | sort -z | xargs -0 sha256sum > hashes.sha256
)

echo "Hash-Datei erstellt: ${TMP_DIR}/hashes.sha256" | tee -a "$LOG"

############################################################
### 4) MANIFEST ERZEUGEN
############################################################

HOSTNAME="$(hostname)"
IP_ADDR="$(hostname -I | awk '{print $1}')"

MANIFEST="${TMP_DIR}/manifest.yml"

echo "Erzeuge Manifest..." | tee -a "$LOG"

{
    echo "host: \"${HOSTNAME}\""
    echo "ip: \"${IP_ADDR}\""
    echo "timestamp: \"${TIMESTAMP}\""
    echo "backup_name: \"${BACKUP_NAME}\""
    echo ""
    echo "volumes:"
    for F in "${TMP_DIR}/volumes"/*.tar.gz; do
        [ -e "$F" ] || continue
        VOLNAME="$(basename "$F" .tar.gz)"
        echo "  - ${VOLNAME}"
    done
    echo ""
    echo "bind_mounts:"
    for SRC in "${BIND_PATHS[@]}"; do
        echo "  - ${SRC}"
    done
} > "$MANIFEST"

############################################################
### 5) UPLOAD ZU NEXTCLOUD
############################################################

REMOTE_PATH="${REMOTE_NAME}:${REMOTE_DIR}/${BACKUP_NAME}"

echo "Starte Upload zu Nextcloud: ${REMOTE_PATH}" | tee -a "$LOG"
rclone copy "$TMP_DIR" "$REMOTE_PATH" -P | tee -a "$LOG"

echo "✔️ Upload abgeschlossen." | tee -a "$LOG"

############################################################
### 6) TEMP-DATEN LÖSCHEN
############################################################

echo "Bereinige temporäre Backup-Daten..." | tee -a "$LOG"
rm -rf "$TMP_DIR"

echo "--------------------------------------------------------" | tee -a "$LOG"
echo "Backup erfolgreich abgeschlossen!" | tee -a "$LOG"
echo "Name: $BACKUP_NAME" | tee -a "$LOG"
echo "Remote: $REMOTE_PATH" | tee -a "$LOG"
echo "--------------------------------------------------------" | tee -a "$LOG"

