#!/bin/bash
# shellcheck disable=SC2086
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
COMPOSE_FILES="-f docker-compose.yml -f docker-compose.test.yml"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-myapp}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-changeme}"

log() {
    echo -e "${GREEN}[TEST]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

cleanup() {
    log "Cleaning up..."
    docker compose ${COMPOSE_FILES} down -v --remove-orphans 2>/dev/null || true
}

# Set trap for cleanup on exit
trap cleanup EXIT

log "=== PostgreSQL Backup Integration Test ==="

# Step 1: Verify services are running
log "Step 1: Verifying services are healthy..."

# Check postgres
if ! docker compose ${COMPOSE_FILES} exec -T postgres pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" >/dev/null 2>&1; then
    error "PostgreSQL is not ready"
    exit 1
fi
log "  ✓ PostgreSQL is healthy"

# Check postgres-restore
if ! docker compose ${COMPOSE_FILES} exec -T postgres-restore pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" >/dev/null 2>&1; then
    error "PostgreSQL restore instance is not ready"
    exit 1
fi
log "  ✓ PostgreSQL (restore) is healthy"

# Check garage (use admin API on port 3903)
if ! docker compose ${COMPOSE_FILES} exec -T backup curl -sf -H "Authorization: Bearer admin-token" http://garage:3903/v1/health >/dev/null 2>&1; then
    error "Garage is not ready"
    exit 1
fi
log "  ✓ Garage (S3) is healthy"

# Step 2: Insert test data
log "Step 2: Inserting test data..."
docker compose ${COMPOSE_FILES} exec -T postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" < test/test-data.sql
log "  ✓ Test data inserted"

# Capture original data for verification
ORIGINAL_USER_COUNT=$(docker compose ${COMPOSE_FILES} exec -T postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -t -c "SELECT COUNT(*) FROM users;")
ORIGINAL_POST_COUNT=$(docker compose ${COMPOSE_FILES} exec -T postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -t -c "SELECT COUNT(*) FROM posts;")
ORIGINAL_USER_COUNT=$(echo "${ORIGINAL_USER_COUNT}" | tr -d '[:space:]')
ORIGINAL_POST_COUNT=$(echo "${ORIGINAL_POST_COUNT}" | tr -d '[:space:]')
log "  ✓ Original data: ${ORIGINAL_USER_COUNT} users, ${ORIGINAL_POST_COUNT} posts"

# Step 3: Trigger backup
log "Step 3: Running backup..."
docker compose ${COMPOSE_FILES} exec -T backup /scripts/backup.sh
log "  ✓ Backup completed"

# Step 4: Verify backup exists in S3
log "Step 4: Verifying backup in S3..."
BACKUP_LIST=$(docker compose ${COMPOSE_FILES} exec -T backup mc ls --recursive s3/backups/ 2>/dev/null || echo "")
if [ -z "${BACKUP_LIST}" ]; then
    error "No backups found in S3"
    exit 1
fi
log "  ✓ Backup found in S3:"
echo "${BACKUP_LIST}" | head -5 | while read -r line; do
    echo "      ${line}"
done

# Get the most recent backup path
BACKUP_PATH=$(docker compose ${COMPOSE_FILES} exec -T backup mc ls --recursive s3/backups/ 2>/dev/null | tail -1 | awk '{print $NF}')
if [ -z "${BACKUP_PATH}" ]; then
    error "Could not determine backup path"
    exit 1
fi
log "  ✓ Using backup: ${BACKUP_PATH}"

# Step 5: Restore to second postgres instance
log "Step 5: Restoring backup to test instance..."
docker compose ${COMPOSE_FILES} exec -T backup /scripts/restore.sh "${BACKUP_PATH}"
log "  ✓ Restore completed"

# Step 6: Verify restored data matches original
log "Step 6: Verifying restored data..."

RESTORED_USER_COUNT=$(docker compose ${COMPOSE_FILES} exec -T postgres-restore psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -t -c "SELECT COUNT(*) FROM users;")
RESTORED_POST_COUNT=$(docker compose ${COMPOSE_FILES} exec -T postgres-restore psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -t -c "SELECT COUNT(*) FROM posts;")
RESTORED_USER_COUNT=$(echo "${RESTORED_USER_COUNT}" | tr -d '[:space:]')
RESTORED_POST_COUNT=$(echo "${RESTORED_POST_COUNT}" | tr -d '[:space:]')

log "  ✓ Restored data: ${RESTORED_USER_COUNT} users, ${RESTORED_POST_COUNT} posts"

if [ "${ORIGINAL_USER_COUNT}" != "${RESTORED_USER_COUNT}" ]; then
    error "User count mismatch: original=${ORIGINAL_USER_COUNT}, restored=${RESTORED_USER_COUNT}"
    exit 1
fi

if [ "${ORIGINAL_POST_COUNT}" != "${RESTORED_POST_COUNT}" ]; then
    error "Post count mismatch: original=${ORIGINAL_POST_COUNT}, restored=${RESTORED_POST_COUNT}"
    exit 1
fi

# Verify specific data integrity
ALICE_POSTS=$(docker compose ${COMPOSE_FILES} exec -T postgres-restore psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -t -c "SELECT post_count FROM user_post_counts WHERE username='alice';")
ALICE_POSTS=$(echo "${ALICE_POSTS}" | tr -d '[:space:]')
if [ "${ALICE_POSTS}" != "2" ]; then
    error "Data integrity check failed: alice should have 2 posts, got ${ALICE_POSTS}"
    exit 1
fi
log "  ✓ Data integrity verified"

log ""
log "=== All tests passed! ==="
log ""
