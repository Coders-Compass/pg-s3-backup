#!/bin/bash
set -euo pipefail

# =============================================================================
# Retention Cleanup Script
# =============================================================================
# Implements Restic-style time-bucket retention policies for PostgreSQL backups.
# Policies are ORed - a backup matching ANY policy is kept.
#
# Configuration via environment variables:
#   RETENTION_KEEP_LAST     - Keep N most recent backups
#   RETENTION_KEEP_HOURLY   - Keep one per hour for N hours
#   RETENTION_KEEP_DAILY    - Keep one per day for N days
#   RETENTION_KEEP_WEEKLY   - Keep one per week for N weeks
#   RETENTION_KEEP_MONTHLY  - Keep one per month for N months
#   RETENTION_KEEP_YEARLY   - Keep one per year for N years
#   RETENTION_MIN_BACKUPS   - Minimum backups to keep (safety net)
#   RETENTION_DRY_RUN       - Preview mode (true/false)
# =============================================================================

# Configuration with defaults
POSTGRES_DB="${POSTGRES_DB:-myapp}"
S3_ENDPOINT="${S3_ENDPOINT:-http://garage:3900}"
S3_BUCKET="${S3_BUCKET:-backups}"
S3_ACCESS_KEY="${S3_ACCESS_KEY:?S3_ACCESS_KEY is required}"
S3_SECRET_KEY="${S3_SECRET_KEY:?S3_SECRET_KEY is required}"

# Retention policy defaults
RETENTION_KEEP_LAST="${RETENTION_KEEP_LAST:-3}"
RETENTION_KEEP_HOURLY="${RETENTION_KEEP_HOURLY:-24}"
RETENTION_KEEP_DAILY="${RETENTION_KEEP_DAILY:-7}"
RETENTION_KEEP_WEEKLY="${RETENTION_KEEP_WEEKLY:-4}"
RETENTION_KEEP_MONTHLY="${RETENTION_KEEP_MONTHLY:-6}"
RETENTION_KEEP_YEARLY="${RETENTION_KEEP_YEARLY:-2}"
RETENTION_MIN_BACKUPS="${RETENTION_MIN_BACKUPS:-1}"
RETENTION_DRY_RUN="${RETENTION_DRY_RUN:-false}"

# Logging functions
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_keep() {
    log "KEEP: $1 (reason: $2)"
}

log_delete() {
    log "DELETE: $1"
}

# Parse timestamp from backup path: YYYY/MM/DD/dbname_HHMMSS.sql.gz
# Returns epoch timestamp
parse_backup_timestamp() {
    local path="$1"
    # Extract date components from path
    local year month day time_part
    year=$(echo "$path" | cut -d'/' -f1)
    month=$(echo "$path" | cut -d'/' -f2)
    day=$(echo "$path" | cut -d'/' -f3)

    # Extract time from filename (dbname_HHMMSS.sql.gz)
    local filename
    filename=$(basename "$path")
    time_part=$(echo "$filename" | sed -E 's/.*_([0-9]{6})\.sql\.gz$/\1/')

    local hour minute second
    hour="${time_part:0:2}"
    minute="${time_part:2:2}"
    second="${time_part:4:2}"

    # Convert to epoch using BusyBox-compatible date (Alpine)
    # Format: YYYY-MM-DD HH:MM:SS
    local datetime="${year}-${month}-${day} ${hour}:${minute}:${second}"
    date -u -d "$datetime" +%s 2>/dev/null || date -u -D "%Y-%m-%d %H:%M:%S" -d "$datetime" +%s 2>/dev/null || echo "0"
}

# Get bucket key for time period
# Usage: get_bucket <epoch> <period>
# period: hourly, daily, weekly, monthly, yearly
get_bucket() {
    local epoch="$1"
    local period="$2"

    case "$period" in
        hourly)
            # Bucket by hour: YYYY-MM-DD-HH
            date -u -d "@$epoch" "+%Y-%m-%d-%H" 2>/dev/null || date -u -r "$epoch" "+%Y-%m-%d-%H"
            ;;
        daily)
            # Bucket by day: YYYY-MM-DD
            date -u -d "@$epoch" "+%Y-%m-%d" 2>/dev/null || date -u -r "$epoch" "+%Y-%m-%d"
            ;;
        weekly)
            # Bucket by ISO week: YYYY-WNN
            date -u -d "@$epoch" "+%G-W%V" 2>/dev/null || date -u -r "$epoch" "+%G-W%V"
            ;;
        monthly)
            # Bucket by month: YYYY-MM
            date -u -d "@$epoch" "+%Y-%m" 2>/dev/null || date -u -r "$epoch" "+%Y-%m"
            ;;
        yearly)
            # Bucket by year: YYYY
            date -u -d "@$epoch" "+%Y" 2>/dev/null || date -u -r "$epoch" "+%Y"
            ;;
    esac
}

# Check if epoch is within N periods from now
# Usage: is_within_window <epoch> <count> <period>
is_within_window() {
    local epoch="$1"
    local count="$2"
    local period="$3"
    local now
    now=$(date +%s)

    local seconds_per_period
    case "$period" in
        hourly)  seconds_per_period=3600 ;;
        daily)   seconds_per_period=86400 ;;
        weekly)  seconds_per_period=604800 ;;
        monthly) seconds_per_period=2592000 ;;  # ~30 days
        yearly)  seconds_per_period=31536000 ;; # 365 days
    esac

    local window=$((count * seconds_per_period))
    local age=$((now - epoch))

    [ "$age" -le "$window" ]
}

# Main cleanup logic
main() {
    log "Starting retention cleanup for database '${POSTGRES_DB}'"
    log "Retention policy:"
    log "  KEEP_LAST=${RETENTION_KEEP_LAST}"
    log "  KEEP_HOURLY=${RETENTION_KEEP_HOURLY}"
    log "  KEEP_DAILY=${RETENTION_KEEP_DAILY}"
    log "  KEEP_WEEKLY=${RETENTION_KEEP_WEEKLY}"
    log "  KEEP_MONTHLY=${RETENTION_KEEP_MONTHLY}"
    log "  KEEP_YEARLY=${RETENTION_KEEP_YEARLY}"
    log "  MIN_BACKUPS=${RETENTION_MIN_BACKUPS}"
    log "  DRY_RUN=${RETENTION_DRY_RUN}"

    # Configure MinIO client
    mc alias set s3 "${S3_ENDPOINT}" "${S3_ACCESS_KEY}" "${S3_SECRET_KEY}" --api S3v4 >/dev/null 2>&1

    # List all backups sorted by path (newest first due to date structure)
    # Filter to only include files matching our backup pattern
    local backup_list
    backup_list=$(mc ls --recursive "s3/${S3_BUCKET}/" 2>/dev/null | \
        grep -E '[0-9]{4}/[0-9]{2}/[0-9]{2}/.*_[0-9]{6}\.sql\.gz$' | \
        awk '{print $NF}' | \
        sort -r || echo "")

    if [ -z "$backup_list" ]; then
        log "No backups found. Nothing to clean up."
        return 0
    fi

    # Convert to array
    local backups=()
    while IFS= read -r line; do
        [ -n "$line" ] && backups+=("$line")
    done <<< "$backup_list"

    local total_backups=${#backups[@]}
    log "Found ${total_backups} backup(s)"

    if [ "$total_backups" -eq 0 ]; then
        log "No backups to process."
        return 0
    fi

    # Track buckets for deduplication (first backup in each bucket wins)
    declare -A hourly_buckets
    declare -A daily_buckets
    declare -A weekly_buckets
    declare -A monthly_buckets
    declare -A yearly_buckets

    # Track which backups to keep and why
    declare -A keep_reasons
    local keep_count=0
    local delete_list=()

    # Process backups (newest first)
    local index=0
    for backup in "${backups[@]}"; do
        local epoch
        epoch=$(parse_backup_timestamp "$backup")

        if [ "$epoch" -eq 0 ]; then
            log "WARNING: Could not parse timestamp from '$backup', skipping"
            continue
        fi

        local reason=""

        # Check keep_last
        if [ "$index" -lt "$RETENTION_KEEP_LAST" ]; then
            reason="keep_last ($((index + 1)) of ${RETENTION_KEEP_LAST})"
        fi

        # Check hourly bucket
        if [ -z "$reason" ] && [ "$RETENTION_KEEP_HOURLY" -gt 0 ]; then
            if is_within_window "$epoch" "$RETENTION_KEEP_HOURLY" "hourly"; then
                local bucket
                bucket=$(get_bucket "$epoch" "hourly")
                if [ -z "${hourly_buckets[$bucket]:-}" ]; then
                    hourly_buckets[$bucket]="$backup"
                    reason="keep_hourly (bucket: $bucket)"
                fi
            fi
        fi

        # Check daily bucket
        if [ -z "$reason" ] && [ "$RETENTION_KEEP_DAILY" -gt 0 ]; then
            if is_within_window "$epoch" "$RETENTION_KEEP_DAILY" "daily"; then
                local bucket
                bucket=$(get_bucket "$epoch" "daily")
                if [ -z "${daily_buckets[$bucket]:-}" ]; then
                    daily_buckets[$bucket]="$backup"
                    reason="keep_daily (bucket: $bucket)"
                fi
            fi
        fi

        # Check weekly bucket
        if [ -z "$reason" ] && [ "$RETENTION_KEEP_WEEKLY" -gt 0 ]; then
            if is_within_window "$epoch" "$RETENTION_KEEP_WEEKLY" "weekly"; then
                local bucket
                bucket=$(get_bucket "$epoch" "weekly")
                if [ -z "${weekly_buckets[$bucket]:-}" ]; then
                    weekly_buckets[$bucket]="$backup"
                    reason="keep_weekly (bucket: $bucket)"
                fi
            fi
        fi

        # Check monthly bucket
        if [ -z "$reason" ] && [ "$RETENTION_KEEP_MONTHLY" -gt 0 ]; then
            if is_within_window "$epoch" "$RETENTION_KEEP_MONTHLY" "monthly"; then
                local bucket
                bucket=$(get_bucket "$epoch" "monthly")
                if [ -z "${monthly_buckets[$bucket]:-}" ]; then
                    monthly_buckets[$bucket]="$backup"
                    reason="keep_monthly (bucket: $bucket)"
                fi
            fi
        fi

        # Check yearly bucket
        if [ -z "$reason" ] && [ "$RETENTION_KEEP_YEARLY" -gt 0 ]; then
            if is_within_window "$epoch" "$RETENTION_KEEP_YEARLY" "yearly"; then
                local bucket
                bucket=$(get_bucket "$epoch" "yearly")
                if [ -z "${yearly_buckets[$bucket]:-}" ]; then
                    yearly_buckets[$bucket]="$backup"
                    reason="keep_yearly (bucket: $bucket)"
                fi
            fi
        fi

        if [ -n "$reason" ]; then
            keep_reasons[$backup]="$reason"
            ((keep_count++))
        else
            delete_list+=("$backup")
        fi

        ((index++))
    done

    # Safety check: ensure MIN_BACKUPS remain
    local delete_count=${#delete_list[@]}
    local final_count=$((total_backups - delete_count))

    if [ "$final_count" -lt "$RETENTION_MIN_BACKUPS" ]; then
        local need_to_save=$((RETENTION_MIN_BACKUPS - final_count))
        log "Safety: Would leave only ${final_count} backup(s), need at least ${RETENTION_MIN_BACKUPS}"
        log "Saving ${need_to_save} additional backup(s) from deletion"

        # Remove items from delete_list to meet minimum
        local new_delete_list=()
        local saved=0
        for i in "${!delete_list[@]}"; do
            if [ "$saved" -lt "$need_to_save" ]; then
                keep_reasons[${delete_list[$i]}]="min_backups safety"
                ((saved++))
                ((keep_count++))
            else
                new_delete_list+=("${delete_list[$i]}")
            fi
        done
        delete_list=("${new_delete_list[@]}")
        delete_count=${#delete_list[@]}
    fi

    # Log decisions
    log "---"
    log "Retention decisions:"

    for backup in "${backups[@]}"; do
        if [ -n "${keep_reasons[$backup]:-}" ]; then
            log_keep "$backup" "${keep_reasons[$backup]}"
        fi
    done

    for backup in "${delete_list[@]}"; do
        log_delete "$backup"
    done

    log "---"
    log "Summary: Keeping ${keep_count}, Deleting ${delete_count}"

    # Perform deletion (unless dry run)
    if [ "$delete_count" -eq 0 ]; then
        log "No backups to delete."
    elif [ "$RETENTION_DRY_RUN" = "true" ]; then
        log "DRY RUN: Would delete ${delete_count} backup(s)"
    else
        log "Deleting ${delete_count} backup(s)..."
        for backup in "${delete_list[@]}"; do
            log "Deleting: s3/${S3_BUCKET}/${backup}"
            mc rm "s3/${S3_BUCKET}/${backup}" >/dev/null 2>&1 || log "WARNING: Failed to delete ${backup}"
        done
        log "Deletion complete."
    fi

    log "Cleanup finished."
}

main "$@"
