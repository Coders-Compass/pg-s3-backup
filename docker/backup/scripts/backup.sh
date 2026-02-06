#!/bin/bash
set -euo pipefail

# Configuration
POSTGRES_HOST="${POSTGRES_HOST:-postgres}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DB="${POSTGRES_DB:-myapp}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
S3_ENDPOINT="${S3_ENDPOINT:-http://garage:3900}"
S3_BUCKET="${S3_BUCKET:-backups}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:?S3_ACCESS_KEY is required}"
S3_SECRET_KEY="${S3_SECRET_KEY:?S3_SECRET_KEY is required}"

# Generate timestamp-based path
TIMESTAMP=$(date +%Y/%m/%d)
FILENAME="${POSTGRES_DB}_$(date +%H%M%S).sql.gz"
S3_PATH="${TIMESTAMP}/${FILENAME}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "Starting backup of database '${POSTGRES_DB}'"

# Set PostgreSQL password for non-interactive authentication
export PGPASSWORD="${POSTGRES_PASSWORD}"

# Configure MinIO client
mc alias set s3 "${S3_ENDPOINT}" "${S3_ACCESS_KEY}" "${S3_SECRET_KEY}" --api S3v4 >/dev/null 2>&1

# Create backup with pg_dump and compress
log "Running pg_dump..."
TEMP_FILE="/tmp/${FILENAME}"

pg_dump \
    -h "${POSTGRES_HOST}" \
    -p "${POSTGRES_PORT}" \
    -U "${POSTGRES_USER}" \
    -d "${POSTGRES_DB}" \
    --no-owner \
    --no-acl \
    | gzip > "${TEMP_FILE}"

# Get file size for logging
FILE_SIZE=$(du -h "${TEMP_FILE}" | cut -f1)
log "Backup created: ${FILE_SIZE}"

# Upload to S3
log "Uploading to s3://${S3_BUCKET}/${S3_PATH}..."
mc cp "${TEMP_FILE}" "s3/${S3_BUCKET}/${S3_PATH}"

# Cleanup temp file
rm -f "${TEMP_FILE}"

log "Backup completed successfully: ${S3_PATH}"
