#!/bin/bash
# shellcheck disable=SC2086
set -euo pipefail

# =============================================================================
# Retention Policy Test Suite
# =============================================================================
# Creates mock backups with specific timestamps and verifies cleanup decisions.
# Designed for CI with deterministic, repeatable results.
# =============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
COMPOSE_FILES="-f docker-compose.yml -f docker-compose.test.yml"
DB_NAME="${POSTGRES_DB:-myapp}"
S3_BUCKET="${S3_BUCKET:-backups}"

log() {
    echo -e "${GREEN}[TEST]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Helper: Create mock backup at specific S3 path
create_mock_backup() {
    local path="$1"
    echo "-- Mock backup created at $(date)" | gzip | \
        docker compose ${COMPOSE_FILES} exec -T backup sh -c "cat > /tmp/mock.sql.gz && mc cp /tmp/mock.sql.gz s3/${S3_BUCKET}/${path}"
}

# Helper: Check if backup exists in S3
backup_exists() {
    local path="$1"
    docker compose ${COMPOSE_FILES} exec -T backup mc ls "s3/${S3_BUCKET}/${path}" >/dev/null 2>&1
}

# Helper: Count backups in S3
count_backups() {
    docker compose ${COMPOSE_FILES} exec -T backup mc ls --recursive "s3/${S3_BUCKET}/" 2>/dev/null | \
        grep -c '\.sql\.gz$' || echo "0"
}

# Helper: Clear all backups
clear_backups() {
    docker compose ${COMPOSE_FILES} exec -T backup mc rm --recursive --force "s3/${S3_BUCKET}/" >/dev/null 2>&1 || true
}

# Helper: Setup mc alias (must be called before using mc commands)
setup_mc_alias() {
    docker compose ${COMPOSE_FILES} exec -T backup sh -c '
        mc alias set s3 "${S3_ENDPOINT}" "${S3_ACCESS_KEY}" "${S3_SECRET_KEY}" --api S3v4
    ' >/dev/null 2>&1
}

# Helper: Get date string for N days ago (cross-platform)
days_ago() {
    local n="$1"
    if date -v-${n}d +%Y/%m/%d 2>/dev/null; then
        : # macOS
    else
        date -d "${n} days ago" +%Y/%m/%d # Linux
    fi
}

# Helper: Get date string for N weeks ago
weeks_ago() {
    local n="$1"
    local days=$((n * 7))
    days_ago "$days"
}

# Helper: Get date string for N months ago
months_ago() {
    local n="$1"
    if date -v-${n}m +%Y/%m/%d 2>/dev/null; then
        : # macOS
    else
        date -d "${n} months ago" +%Y/%m/%d # Linux
    fi
}

# Helper: Get date string for N years ago
years_ago() {
    local n="$1"
    if date -v-${n}y +%Y/%m/%d 2>/dev/null; then
        : # macOS
    else
        date -d "${n} years ago" +%Y/%m/%d # Linux
    fi
}

# Helper: Get date string for N hours ago
hours_ago() {
    local n="$1"
    if date -v-${n}H +%Y/%m/%d 2>/dev/null; then
        : # macOS - just get date part
    else
        date -d "${n} hours ago" +%Y/%m/%d # Linux
    fi
}

# Helper: Get time string for N hours ago (HHMMSS format)
hours_ago_time() {
    local n="$1"
    if date -v-${n}H +%H%M%S 2>/dev/null; then
        : # macOS
    else
        date -d "${n} hours ago" +%H%M%S # Linux
    fi
}

# Run cleanup with dry-run and capture output
run_cleanup_dry() {
    docker compose ${COMPOSE_FILES} exec -T \
        -e RETENTION_DRY_RUN=true \
        -e RETENTION_KEEP_LAST="${RETENTION_KEEP_LAST:-3}" \
        -e RETENTION_KEEP_HOURLY="${RETENTION_KEEP_HOURLY:-24}" \
        -e RETENTION_KEEP_DAILY="${RETENTION_KEEP_DAILY:-7}" \
        -e RETENTION_KEEP_WEEKLY="${RETENTION_KEEP_WEEKLY:-4}" \
        -e RETENTION_KEEP_MONTHLY="${RETENTION_KEEP_MONTHLY:-6}" \
        -e RETENTION_KEEP_YEARLY="${RETENTION_KEEP_YEARLY:-2}" \
        -e RETENTION_MIN_BACKUPS="${RETENTION_MIN_BACKUPS:-1}" \
        backup /scripts/cleanup.sh 2>&1
}

# Run actual cleanup
run_cleanup() {
    docker compose ${COMPOSE_FILES} exec -T \
        -e RETENTION_DRY_RUN=false \
        -e RETENTION_KEEP_LAST="${RETENTION_KEEP_LAST:-3}" \
        -e RETENTION_KEEP_HOURLY="${RETENTION_KEEP_HOURLY:-24}" \
        -e RETENTION_KEEP_DAILY="${RETENTION_KEEP_DAILY:-7}" \
        -e RETENTION_KEEP_WEEKLY="${RETENTION_KEEP_WEEKLY:-4}" \
        -e RETENTION_KEEP_MONTHLY="${RETENTION_KEEP_MONTHLY:-6}" \
        -e RETENTION_KEEP_YEARLY="${RETENTION_KEEP_YEARLY:-2}" \
        -e RETENTION_MIN_BACKUPS="${RETENTION_MIN_BACKUPS:-1}" \
        backup /scripts/cleanup.sh 2>&1
}

# Assert backup was marked for keeping
assert_kept() {
    local path="$1"
    local output="$2"
    if echo "$output" | grep -q "KEEP: ${path}"; then
        log "  ✓ Correctly kept: ${path}"
        return 0
    else
        error "  ✗ Expected KEEP for: ${path}"
        return 1
    fi
}

# Assert backup was marked for deletion
assert_deleted() {
    local path="$1"
    local output="$2"
    if echo "$output" | grep -q "DELETE: ${path}"; then
        log "  ✓ Correctly marked for deletion: ${path}"
        return 0
    else
        error "  ✗ Expected DELETE for: ${path}"
        return 1
    fi
}

# =============================================================================
# Test Cases
# =============================================================================

test_empty_bucket() {
    log "Test: Empty bucket handling"
    clear_backups

    local output
    output=$(run_cleanup_dry)

    if echo "$output" | grep -q "No backups found"; then
        log "  ✓ Correctly handles empty bucket"
        return 0
    else
        error "  ✗ Did not handle empty bucket correctly"
        echo "$output"
        return 1
    fi
}

test_single_backup() {
    log "Test: Single backup (should keep due to MIN_BACKUPS)"
    clear_backups

    local today
    today=$(days_ago 0)
    create_mock_backup "${today}/${DB_NAME}_120000.sql.gz"

    export RETENTION_MIN_BACKUPS=1
    local output
    output=$(run_cleanup_dry)

    if echo "$output" | grep -q "KEEP:"; then
        log "  ✓ Single backup kept"
        return 0
    else
        error "  ✗ Single backup not kept"
        echo "$output"
        return 1
    fi
}

test_keep_last() {
    log "Test: KEEP_LAST policy"
    clear_backups

    local today
    today=$(days_ago 0)

    # Create 5 backups today
    create_mock_backup "${today}/${DB_NAME}_100000.sql.gz"
    create_mock_backup "${today}/${DB_NAME}_090000.sql.gz"
    create_mock_backup "${today}/${DB_NAME}_080000.sql.gz"
    create_mock_backup "${today}/${DB_NAME}_070000.sql.gz"
    create_mock_backup "${today}/${DB_NAME}_060000.sql.gz"

    export RETENTION_KEEP_LAST=3
    export RETENTION_KEEP_HOURLY=0
    export RETENTION_KEEP_DAILY=0
    export RETENTION_KEEP_WEEKLY=0
    export RETENTION_KEEP_MONTHLY=0
    export RETENTION_KEEP_YEARLY=0

    local output
    output=$(run_cleanup_dry)

    local failures=0

    # Should keep the 3 most recent
    assert_kept "${today}/${DB_NAME}_100000.sql.gz" "$output" || ((failures++))
    assert_kept "${today}/${DB_NAME}_090000.sql.gz" "$output" || ((failures++))
    assert_kept "${today}/${DB_NAME}_080000.sql.gz" "$output" || ((failures++))

    # Should delete older ones
    assert_deleted "${today}/${DB_NAME}_070000.sql.gz" "$output" || ((failures++))
    assert_deleted "${today}/${DB_NAME}_060000.sql.gz" "$output" || ((failures++))

    return "$failures"
}

test_keep_hourly() {
    log "Test: KEEP_HOURLY policy"
    clear_backups

    # Create backups at different hours
    # We'll use fixed times to ensure predictable bucket assignment
    local today
    today=$(days_ago 0)
    local yesterday
    yesterday=$(days_ago 1)

    # Multiple backups in same hour (newest should be kept for hourly - script processes newest first)
    create_mock_backup "${today}/${DB_NAME}_100000.sql.gz"
    create_mock_backup "${today}/${DB_NAME}_103000.sql.gz"  # Same hour as above, but newer

    # Different hours
    create_mock_backup "${today}/${DB_NAME}_090000.sql.gz"
    create_mock_backup "${today}/${DB_NAME}_080000.sql.gz"

    export RETENTION_KEEP_LAST=0
    export RETENTION_KEEP_HOURLY=24
    export RETENTION_KEEP_DAILY=0
    export RETENTION_KEEP_WEEKLY=0
    export RETENTION_KEEP_MONTHLY=0
    export RETENTION_KEEP_YEARLY=0

    local output
    output=$(run_cleanup_dry)

    local failures=0

    # Newest backup in each hour should be kept (script processes newest first)
    assert_kept "${today}/${DB_NAME}_103000.sql.gz" "$output" || ((failures++))  # Newest in hour 10
    assert_kept "${today}/${DB_NAME}_090000.sql.gz" "$output" || ((failures++))
    assert_kept "${today}/${DB_NAME}_080000.sql.gz" "$output" || ((failures++))

    # Older backup in same hour should be deleted
    assert_deleted "${today}/${DB_NAME}_100000.sql.gz" "$output" || ((failures++))

    return "$failures"
}

test_keep_daily() {
    log "Test: KEEP_DAILY policy"
    clear_backups

    # Create backups across multiple days
    local day0 day1 day2 day3 day8
    day0=$(days_ago 0)
    day1=$(days_ago 1)
    day2=$(days_ago 2)
    day3=$(days_ago 3)
    day8=$(days_ago 8)  # Outside 7-day window

    create_mock_backup "${day0}/${DB_NAME}_060000.sql.gz"
    create_mock_backup "${day1}/${DB_NAME}_060000.sql.gz"
    create_mock_backup "${day2}/${DB_NAME}_060000.sql.gz"
    create_mock_backup "${day3}/${DB_NAME}_060000.sql.gz"
    create_mock_backup "${day8}/${DB_NAME}_060000.sql.gz"

    export RETENTION_KEEP_LAST=0
    export RETENTION_KEEP_HOURLY=0
    export RETENTION_KEEP_DAILY=7
    export RETENTION_KEEP_WEEKLY=0
    export RETENTION_KEEP_MONTHLY=0
    export RETENTION_KEEP_YEARLY=0

    local output
    output=$(run_cleanup_dry)

    local failures=0

    # Days within window should be kept
    assert_kept "${day0}/${DB_NAME}_060000.sql.gz" "$output" || ((failures++))
    assert_kept "${day1}/${DB_NAME}_060000.sql.gz" "$output" || ((failures++))
    assert_kept "${day2}/${DB_NAME}_060000.sql.gz" "$output" || ((failures++))
    assert_kept "${day3}/${DB_NAME}_060000.sql.gz" "$output" || ((failures++))

    # Day outside window should be deleted
    assert_deleted "${day8}/${DB_NAME}_060000.sql.gz" "$output" || ((failures++))

    return "$failures"
}

test_keep_weekly() {
    log "Test: KEEP_WEEKLY policy"
    clear_backups

    local week0 week1 week2 week5
    week0=$(weeks_ago 0)
    week1=$(weeks_ago 1)
    week2=$(weeks_ago 2)
    week5=$(weeks_ago 5)  # Outside 4-week window

    create_mock_backup "${week0}/${DB_NAME}_060000.sql.gz"
    create_mock_backup "${week1}/${DB_NAME}_060000.sql.gz"
    create_mock_backup "${week2}/${DB_NAME}_060000.sql.gz"
    create_mock_backup "${week5}/${DB_NAME}_060000.sql.gz"

    export RETENTION_KEEP_LAST=0
    export RETENTION_KEEP_HOURLY=0
    export RETENTION_KEEP_DAILY=0
    export RETENTION_KEEP_WEEKLY=4
    export RETENTION_KEEP_MONTHLY=0
    export RETENTION_KEEP_YEARLY=0

    local output
    output=$(run_cleanup_dry)

    local failures=0

    # Weeks within window should be kept
    assert_kept "${week0}/${DB_NAME}_060000.sql.gz" "$output" || ((failures++))
    assert_kept "${week1}/${DB_NAME}_060000.sql.gz" "$output" || ((failures++))
    assert_kept "${week2}/${DB_NAME}_060000.sql.gz" "$output" || ((failures++))

    # Week outside window should be deleted
    assert_deleted "${week5}/${DB_NAME}_060000.sql.gz" "$output" || ((failures++))

    return "$failures"
}

test_keep_monthly() {
    log "Test: KEEP_MONTHLY policy"
    clear_backups

    local month0 month1 month2 month7
    month0=$(months_ago 0)
    month1=$(months_ago 1)
    month2=$(months_ago 2)
    month7=$(months_ago 7)  # Outside 6-month window

    create_mock_backup "${month0}/${DB_NAME}_060000.sql.gz"
    create_mock_backup "${month1}/${DB_NAME}_060000.sql.gz"
    create_mock_backup "${month2}/${DB_NAME}_060000.sql.gz"
    create_mock_backup "${month7}/${DB_NAME}_060000.sql.gz"

    export RETENTION_KEEP_LAST=0
    export RETENTION_KEEP_HOURLY=0
    export RETENTION_KEEP_DAILY=0
    export RETENTION_KEEP_WEEKLY=0
    export RETENTION_KEEP_MONTHLY=6
    export RETENTION_KEEP_YEARLY=0

    local output
    output=$(run_cleanup_dry)

    local failures=0

    # Months within window should be kept
    assert_kept "${month0}/${DB_NAME}_060000.sql.gz" "$output" || ((failures++))
    assert_kept "${month1}/${DB_NAME}_060000.sql.gz" "$output" || ((failures++))
    assert_kept "${month2}/${DB_NAME}_060000.sql.gz" "$output" || ((failures++))

    # Month outside window should be deleted
    assert_deleted "${month7}/${DB_NAME}_060000.sql.gz" "$output" || ((failures++))

    return "$failures"
}

test_keep_yearly() {
    log "Test: KEEP_YEARLY policy"
    clear_backups

    local year0 year1 year3
    year0=$(years_ago 0)
    year1=$(years_ago 1)
    year3=$(years_ago 3)  # Outside 2-year window

    create_mock_backup "${year0}/${DB_NAME}_060000.sql.gz"
    create_mock_backup "${year1}/${DB_NAME}_060000.sql.gz"
    create_mock_backup "${year3}/${DB_NAME}_060000.sql.gz"

    export RETENTION_KEEP_LAST=0
    export RETENTION_KEEP_HOURLY=0
    export RETENTION_KEEP_DAILY=0
    export RETENTION_KEEP_WEEKLY=0
    export RETENTION_KEEP_MONTHLY=0
    export RETENTION_KEEP_YEARLY=2

    local output
    output=$(run_cleanup_dry)

    local failures=0

    # Years within window should be kept
    assert_kept "${year0}/${DB_NAME}_060000.sql.gz" "$output" || ((failures++))
    assert_kept "${year1}/${DB_NAME}_060000.sql.gz" "$output" || ((failures++))

    # Year outside window should be deleted
    assert_deleted "${year3}/${DB_NAME}_060000.sql.gz" "$output" || ((failures++))

    return "$failures"
}

test_min_backups_safety() {
    log "Test: MIN_BACKUPS safety mechanism"
    clear_backups

    # Create old backups that would normally be deleted
    local old_date
    old_date=$(years_ago 5)

    create_mock_backup "${old_date}/${DB_NAME}_060000.sql.gz"
    create_mock_backup "${old_date}/${DB_NAME}_070000.sql.gz"
    create_mock_backup "${old_date}/${DB_NAME}_080000.sql.gz"

    export RETENTION_KEEP_LAST=0
    export RETENTION_KEEP_HOURLY=0
    export RETENTION_KEEP_DAILY=0
    export RETENTION_KEEP_WEEKLY=0
    export RETENTION_KEEP_MONTHLY=0
    export RETENTION_KEEP_YEARLY=0
    export RETENTION_MIN_BACKUPS=2

    local output
    output=$(run_cleanup_dry)

    # Should keep at least 2 due to MIN_BACKUPS
    if echo "$output" | grep -q "min_backups safety"; then
        log "  ✓ MIN_BACKUPS safety triggered"
    else
        error "  ✗ MIN_BACKUPS safety did not trigger"
        echo "$output"
        return 1
    fi

    # Count KEEPs - should have at least 2
    local keep_count
    keep_count=$(echo "$output" | grep -c "KEEP:" || echo "0")
    if [ "$keep_count" -ge 2 ]; then
        log "  ✓ At least ${keep_count} backups kept"
        return 0
    else
        error "  ✗ Only ${keep_count} backups kept, expected at least 2"
        return 1
    fi
}

test_actual_deletion() {
    log "Test: Actual deletion (not dry-run)"
    clear_backups

    local today old_date
    today=$(days_ago 0)
    old_date=$(years_ago 5)

    # Create backups
    create_mock_backup "${today}/${DB_NAME}_100000.sql.gz"
    create_mock_backup "${old_date}/${DB_NAME}_060000.sql.gz"

    local before_count
    before_count=$(count_backups)
    log "  Backups before cleanup: ${before_count}"

    export RETENTION_KEEP_LAST=1
    export RETENTION_KEEP_HOURLY=0
    export RETENTION_KEEP_DAILY=0
    export RETENTION_KEEP_WEEKLY=0
    export RETENTION_KEEP_MONTHLY=0
    export RETENTION_KEEP_YEARLY=0
    export RETENTION_MIN_BACKUPS=1

    # Run actual cleanup
    run_cleanup >/dev/null 2>&1

    local after_count
    after_count=$(count_backups)
    log "  Backups after cleanup: ${after_count}"

    if [ "$after_count" -eq 1 ]; then
        log "  ✓ Correct number of backups after deletion"
    else
        error "  ✗ Expected 1 backup, found ${after_count}"
        return 1
    fi

    # Verify the right backup was kept
    if backup_exists "${today}/${DB_NAME}_100000.sql.gz"; then
        log "  ✓ Correct backup retained"
        return 0
    else
        error "  ✗ Wrong backup retained"
        return 1
    fi
}

test_combined_policies() {
    log "Test: Combined policies (OR behavior)"
    clear_backups

    local today yesterday week2 month3
    today=$(days_ago 0)
    yesterday=$(days_ago 1)
    week2=$(weeks_ago 2)
    month3=$(months_ago 3)

    create_mock_backup "${today}/${DB_NAME}_100000.sql.gz"     # keep_last + hourly + daily
    create_mock_backup "${yesterday}/${DB_NAME}_060000.sql.gz" # daily
    create_mock_backup "${week2}/${DB_NAME}_060000.sql.gz"     # weekly
    create_mock_backup "${month3}/${DB_NAME}_060000.sql.gz"    # monthly

    # Use default policy values
    export RETENTION_KEEP_LAST=3
    export RETENTION_KEEP_HOURLY=24
    export RETENTION_KEEP_DAILY=7
    export RETENTION_KEEP_WEEKLY=4
    export RETENTION_KEEP_MONTHLY=6
    export RETENTION_KEEP_YEARLY=2

    local output
    output=$(run_cleanup_dry)

    local failures=0

    # All should be kept by at least one policy
    assert_kept "${today}/${DB_NAME}_100000.sql.gz" "$output" || ((failures++))
    assert_kept "${yesterday}/${DB_NAME}_060000.sql.gz" "$output" || ((failures++))
    assert_kept "${week2}/${DB_NAME}_060000.sql.gz" "$output" || ((failures++))
    assert_kept "${month3}/${DB_NAME}_060000.sql.gz" "$output" || ((failures++))

    return "$failures"
}

# =============================================================================
# Main
# =============================================================================

main() {
    log "=== Retention Policy Test Suite ==="
    log ""

    # Verify services are running
    log "Verifying services..."
    if ! docker compose ${COMPOSE_FILES} exec -T backup curl -sf -H "Authorization: Bearer admin-token" http://garage:3903/v2/GetClusterHealth >/dev/null 2>&1; then
        error "Cannot connect to S3. Are services running?"
        exit 1
    fi
    log "  ✓ Services ready"

    # Setup mc alias for test helper functions
    log "Setting up S3 client..."
    if ! setup_mc_alias; then
        error "Failed to configure S3 client"
        exit 1
    fi
    log "  ✓ S3 client configured"

    # Clear any leftover backups from previous runs
    log "Clearing existing backups..."
    clear_backups
    log "  ✓ Bucket cleared"
    log ""

    local total_tests=0
    local failed_tests=0

    # Run tests
    for test_func in \
        test_empty_bucket \
        test_single_backup \
        test_keep_last \
        test_keep_hourly \
        test_keep_daily \
        test_keep_weekly \
        test_keep_monthly \
        test_keep_yearly \
        test_min_backups_safety \
        test_combined_policies \
        test_actual_deletion
    do
        total_tests=$((total_tests + 1))
        if ! $test_func; then
            failed_tests=$((failed_tests + 1))
        fi
        log ""
    done

    # Clean up
    clear_backups

    # Summary
    log "=== Test Results ==="
    log "Total: ${total_tests}, Passed: $((total_tests - failed_tests)), Failed: ${failed_tests}"

    if [ "$failed_tests" -gt 0 ]; then
        error "Some tests failed!"
        exit 1
    fi

    log "All tests passed!"
}

main "$@"
