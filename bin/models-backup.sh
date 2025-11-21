#!/bin/bash
set -euo pipefail

############################################################
# SYS-BACKUP-V4 – MODEL BACKUP (optional manual script)
############################################################

REMOTE_NAME="backup"
REMOTE_DIR="Server-Backups/models"

LOG_DIR="/var/log/sys-backup-v4"
TMP_BASE="/tmp/sys-backup-v4-models"
mkdir -p "$LOG_DIR" "$TMP_BASE"

TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
BACKUP_NAME="models_${TIMESTAMP}"
TMP_DIR="${TMP_BASE}/${BACKUP_NAME}"

LOG="${LOG_DIR}/models-backup.log"

echo "--------------------------------------------------------" | tee -a "$LOG"
echo "SYS-BACKUP-V4 – MODEL BACKUP gestartet: ${TIMESTAMP}" | tee -a "$LOG"
echo "--------------------------------------------------------" | tee -a "$LOG"

mkdir -p "$TMP_DIR/ollama" "$TMP_DIR/openwebui"

############################################################
### 1) OLLAMA MODELLE SICHERN
############################################################

echo "Sichere Ollama Modelle..." | tee -a "$LOG"

OLLAMA_DIR="/opt/services/ollama/models"

if [[ -d "$OLLAMA_DIR" ]]; then
    tar -I zstd -cf "${TMP_DIR}/ollama/ollama_models.tar.zst" -C "$OLLAMA_DIR" .
else
    echo "⚠️ Ollama-Modellordner nicht gefunden!" | tee -a "$LOG"
fi

############################################################
### 2) OPENWEBUI MODELLE SICHERN
############################################################

echo "Sichere OpenWebUI Modelle..." | tee -a "$LOG"

OPENWEBUI_DIR="/opt/services/openwebui/models"

if [[ -d "$OPENWEBUI_DIR" ]]; then
    tar -I zstd -cf "${TMP_DIR}/openwebui/openwebui_models.tar.zst" -C "$OPENWEBUI_DIR" .
else
    echo "⚠️ OpenWebUI-Modellordner nicht gefunden!" | tee -a "$LOG"
fi

############################################################
### 3) LISTEN ERSTELLEN
############################################################

echo "Scanne Model-Listen..." | tee -a "$LOG"

echo "ollama_models:" > "${TMP_DIR}/model_manifest.yml"
ollama list | awk 'NR>1 {print "  - " $1}' >> "${TMP_DIR}/model_manifest.yml"

echo "" >> "${TMP_DIR}/model_manifest.yml"
echo "openwebui_models:" >> "${TMP_DIR}/model_manifest.yml"
ls "$OPENWEBUI_DIR" 2>/dev/null | awk '{print "  - " $1}' >> "${TMP_DIR}/model_manifest.yml"

############################################################
### 4) HOCHLADEN
############################################################

REMOTE_PATH="${REMOTE_NAME}:${REMOTE_DIR}/${BACKUP_NAME}"

echo "Lade Modelle nach ${REMOTE_PATH} hoch..." | tee -a "$LOG"
rclone copy "$TMP_DIR" "$REMOTE_PATH" -P | tee -a "$LOG"

############################################################
### 5) CLEANUP
############################################################

rm -rf "$TMP_DIR"

echo "--------------------------------------------------------" | tee -a "$LOG"
echo "Model-Backup erfolgreich abgeschlossen!" | tee -a "$LOG"
echo "Name: ${BACKUP_NAME}" | tee -a "$LOG"
echo "--------------------------------------------------------" | tee -a "$LOG"

