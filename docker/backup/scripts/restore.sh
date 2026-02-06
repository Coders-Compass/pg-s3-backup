#!/bin/bash
set -euo pipefail

# Configuration
POSTGRES_HOST="${RESTORE_POSTGRES_HOST:-${POSTGRES_HOST:-postgres}}"
POSTGRES_PORT="${RESTORE_POSTGRES_PORT:-${POSTGRES_PORT:-5432}}"
POSTGRES_DB="${POSTGRES_DB:-myapp}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
S3_ENDPOINT="${S3_ENDPOINT:-http://garage:3900}"
S3_BUCKET="${S3_BUCKET:-backups}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:?S3_ACCESS_KEY is required}"
S3_SECRET_KEY="${S3_SECRET_KEY:?S3_SECRET_KEY is required}"

# Backup file path is required
BACKUP_PATH="${1:-}"

if [ -z "${BACKUP_PATH}" ]; then
    echo "Usage: $0 <backup-path>"
    echo "Example: $0 2024/01/15/myapp_120000.sql.gz"
    exit 1
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "Starting restore of '${BACKUP_PATH}' to database '${POSTGRES_DB}' on host '${POSTGRES_HOST}'"

# Set PostgreSQL password for non-interactive authentication
export PGPASSWORD="${POSTGRES_PASSWORD}"

# Configure MinIO client
mc alias set s3 "${S3_ENDPOINT}" "${S3_ACCESS_KEY}" "${S3_SECRET_KEY}" --api S3v4 >/dev/null 2>&1

# Download backup
TEMP_FILE="/tmp/restore_$(date +%s).sql.gz"
log "Downloading from s3://${S3_BUCKET}/${BACKUP_PATH}..."
mc cp "s3/${S3_BUCKET}/${BACKUP_PATH}" "${TEMP_FILE}"

# Get file size for logging
FILE_SIZE=$(du -h "${TEMP_FILE}" | cut -f1)
log "Downloaded backup: ${FILE_SIZE}"

# Restore database
log "Restoring to ${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}..."

# Drop and recreate database connections, then restore
gunzip -c "${TEMP_FILE}" | psql \
    -h "${POSTGRES_HOST}" \
    -p "${POSTGRES_PORT}" \
    -U "${POSTGRES_USER}" \
    -d "${POSTGRES_DB}" \
    -v ON_ERROR_STOP=1

# Cleanup temp file
rm -f "${TEMP_FILE}"

log "Restore completed successfully!"
