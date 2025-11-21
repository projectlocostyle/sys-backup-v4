#!/bin/bash
set -euo pipefail

############################################################
# SYS-BACKUP-V4 – BACKUP SCRIPT (Vollständig funktionierend)
############################################################

TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
BACKUP_NAME="backup_${TIMESTAMP}"

BASE="/opt/sys-backup-v4"
LOG_DIR="/var/log/sys-backup-v4"
TMP_BASE="/tmp/sys-backup-v4"
BACKUP_TMP="${TMP_BASE}/${BACKUP_NAME}"

REMOTE_NAME="backup"
REMOTE_DIR="Server-Backups/${BACKUP_NAME}"

mkdir -p "$LOG_DIR"
mkdir -p "$BACKUP_TMP/volumes"
mkdir -p "$BACKUP_TMP/bind_mounts"

LOG="${LOG_DIR}/backup.log"

echo "--------------------------------------------------------" | tee "$LOG"
echo "SYS-BACKUP-V4 BACKUP gestartet: ${TIMESTAMP}" | tee -a "$LOG"
echo "--------------------------------------------------------" | tee -a "$LOG"
echo "" | tee -a "$LOG"

############################################################
# 1) MODEL-LISTEN (keine Model-Daten!)
############################################################

echo "Erfasse Modell-Listen..." | tee -a "$LOG"

echo "models:" > "${BACKUP_TMP}/model_manifest.yml"
echo "  ollama: Docker-Modus (keine Modelldaten im Backup)" >> "${BACKUP_TMP}/model_manifest.yml"

if [[ -d /opt/services/openwebui/models ]]; then
    echo "  openwebui:" >> "${BACKUP_TMP}/model_manifest.yml"
    ls /opt/services/openwebui/models | awk '{print "    - " $1}' >> "${BACKUP_TMP}/model_manifest.yml"
else
    echo "  openwebui: kein Modellordner" >> "${BACKUP_TMP}/model_manifest.yml"
fi

echo "ℹ️ Ollama läuft im Docker – Modelle werden NICHT im normalen Backup gesichert." | tee -a "$LOG"

############################################################
# 2) DOCKER VOLUME BACKUP
############################################################

echo "Starte Volume-Backup..." | tee -a "$LOG"

VOLUMES=$(docker volume ls --format '{{.Name}}' | grep '^services_')

mkdir -p "$BACKUP_TMP/volumes"

for VOL in $VOLUMES; do
    echo "  Volume: $VOL" | tee -a "$LOG"

    ARCHIVE="${BACKUP_TMP}/volumes/${VOL}.tar.gz"

    docker run --rm \
        -v "${VOL}:/data:ro" \
        -v "${BACKUP_TMP}/volumes:/out" \
        alpine sh -c "cd /data && tar -czf /out/${VOL}.tar.gz ."

    echo "    ✔ Gesichert: $ARCHIVE" | tee -a "$LOG"
done

############################################################
# 3) BIND-MOUNT BACKUP
############################################################

echo "Starte Bind-Mount-Backup..." | tee -a "$LOG"

MOUNTS=(
    "/etc/caddy"
    "/opt/services"
    "/opt/sys-backup-v4"
    "/root/.config/rclone"
    "/var/lib/caddy"
)

for SRC in "${MOUNTS[@]}"; do
    SAFE=$(echo "$SRC" | sed 's/\//_/g')
    ARCHIVE="${BACKUP_TMP}/bind_mounts/${SAFE}.tar.gz"

    echo "  Bind-Mount: $SRC" | tee -a "$LOG"

    tar -czf "$ARCHIVE" -C "$SRC" .

    echo "    ✔ Gesichert: $ARCHIVE" | tee -a "$LOG"
done

############################################################
# 4) HASH-BERECHNUNG
############################################################

HASHFILE="${BACKUP_TMP}/hashes.sha256"
find "$BACKUP_TMP" -type f -exec sha256sum {} \; > "$HASHFILE"
echo "✔ Hashes gespeichert unter: $HASHFILE" | tee -a "$LOG"

############################################################
# 5) MANIFEST ERZEUGEN
############################################################

MANIFEST="${BACKUP_TMP}/manifest.yml"

cat <<EOF > "$MANIFEST"
backup_name: "$BACKUP_NAME"
timestamp: "$TIMESTAMP"
host: "$(hostname)"
ip: "$(hostname -I | awk '{print $1}')"
volumes:
$(echo "$VOLUMES" | sed 's/^/  - /')
bind_mounts:
$(printf "%s\n" "${MOUNTS[@]}" | sed 's/^/  - /')
EOF

echo "✔ Manifest erstellt: $MANIFEST" | tee -a "$LOG"

############################################################
# 6) UPLOAD
############################################################

echo "Starte Upload zu Nextcloud..." | tee -a "$LOG"

rclone copy "$BACKUP_TMP" "${REMOTE_NAME}:${REMOTE_DIR}" -P | tee -a "$LOG"

echo "✔ Upload abgeschlossen." | tee -a "$LOG"

############################################################
# 7) CLEANUP
############################################################

rm -rf "$BACKUP_TMP"

echo "--------------------------------------------------------" | tee -a "$LOG"
echo "Backup erfolgreich abgeschlossen!" | tee -a "$LOG"
echo "Name: ${BACKUP_NAME}" | tee -a "$LOG"
echo "Remote: ${REMOTE_NAME}:${REMOTE_DIR}" | tee -a "$LOG"
echo "--------------------------------------------------------" | tee -a "$LOG"
