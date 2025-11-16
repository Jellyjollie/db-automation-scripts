#!/bin/bash
set -e
set -o pipefail

# ============================================================================
# PostgreSQL Automated Backup Script with Cloud Integration
# ============================================================================
# Description: Performs full logical and physical backups of PostgreSQL,
#              uploads to Google Drive, sends email notifications, and
#              manages retention policies.
# Author: DBA Team
# Created: 2025-11-03
# ============================================================================

# ----------------------------------------------------------------------------
# CONFIGURATION SECTION
# ----------------------------------------------------------------------------

# Directory Configuration
HOSTNAME=$(hostname)
BACKUP_DIR="${HOME}/Laboratory Exercises/Lab8"
LOG_FILE="/var/log/pg_backup.log"

# Database Configuration
DB_NAME="production_db"
DB_USER="postgres"
PGDATA="/var/lib/postgresql/14/main"  # Adjust version if needed

# Email Configuration
EMAIL_TO="jellianbungaos57@gmail.com"
EMAIL_FROM="postgres-backup@${HOSTNAME}"

# Google Drive Configuration
GDRIVE_REMOTE="gdrive_backups:postgresql_backups"

# Retention Policy (days)
RETENTION_DAYS=7

# Backup Status Flag
BACKUP_FAILED=0

# Timestamp for filenames
TIMESTAMP=$(date +"%Y-%m-%d-%H%M%S")

# Backup Filenames
LOGICAL_BACKUP_FILE="${BACKUP_DIR}/production_db_${TIMESTAMP}.dump"
PHYSICAL_BACKUP_FILE="${BACKUP_DIR}/pg_base_backup_${TIMESTAMP}.tar.gz"

# ----------------------------------------------------------------------------
# LOGGING FUNCTION
# ----------------------------------------------------------------------------

log_message() {
    local MESSAGE="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${MESSAGE}"
}

# ----------------------------------------------------------------------------
# EMAIL NOTIFICATION FUNCTIONS
# ----------------------------------------------------------------------------

send_failure_email() {
    local SUBJECT="$1"
    local BODY="$2"
    
    log_message "Sending failure notification email..."
    
    # Get last 15 lines from log
    local LOG_EXCERPT=$(tail -n 15 "${LOG_FILE}" 2>/dev/null || echo "Log file not available")
    
    # Compose email body
    local FULL_BODY="${BODY}

Recent Log Entries (Last 15 lines):
=====================================
${LOG_EXCERPT}
=====================================

Hostname: ${HOSTNAME}
Timestamp: $(date '+%Y-%m-%d %H:%M:%S')
"
    
    echo "${FULL_BODY}" | mail -s "${SUBJECT}" -r "${EMAIL_FROM}" "${EMAIL_TO}"
    log_message "Failure email sent to ${EMAIL_TO}"
}

send_success_email() {
    local SUBJECT="SUCCESS: PostgreSQL Backup and Upload"
    local BODY="Successfully created and uploaded: 
- ${LOGICAL_BACKUP_FILE##*/}
- ${PHYSICAL_BACKUP_FILE##*/}

Backup Details:
- Database: ${DB_NAME}
- Backup Time: ${TIMESTAMP}
- Hostname: ${HOSTNAME}
- Upload Destination: ${GDRIVE_REMOTE}

All backups completed successfully and uploaded to Google Drive."
    
    echo "${BODY}" | mail -s "${SUBJECT}" -r "${EMAIL_FROM}" "${EMAIL_TO}"
    log_message "Success email sent to ${EMAIL_TO}"
}

# ----------------------------------------------------------------------------
# BACKUP FUNCTIONS
# ----------------------------------------------------------------------------

perform_logical_backup() {
    log_message "Starting logical backup of ${DB_NAME}..."
    
    if sudo -u postgres pg_dump -Fc -d "${DB_NAME}" > "${LOGICAL_BACKUP_FILE}"; then
        log_message "Logical backup completed successfully: ${LOGICAL_BACKUP_FILE}"
        log_message "Backup size: $(du -h "${LOGICAL_BACKUP_FILE}" | cut -f1)"
        return 0
    else
        log_message "ERROR: Logical backup failed!"
        BACKUP_FAILED=1
        return 1
    fi
}

perform_physical_backup() {
    log_message "Starting physical base backup..."
    TIMESTAMP=$(date +"%Y-%m-%d-%H%M%S")
    
    # Use /tmp for temp directory (postgres can write here)
    TEMP_DIR="/tmp/pg_base_backup_temp_${TIMESTAMP}"
    sudo -u postgres mkdir -p "${TEMP_DIR}"
    
    PHYSICAL_BACKUP_FILE="${BACKUP_DIR}/pg_base_backup_${TIMESTAMP}.tar.gz"
    
    if sudo -u postgres pg_basebackup \
        -D "${TEMP_DIR}" \
        -Ft \
        -Z 9 \
        -X stream \
        -P; then
        
        log_message "pg_basebackup completed. Compressing into single tar.gz file..."
        
        # Compress and move to final location
        sudo tar -czf "${PHYSICAL_BACKUP_FILE}" -C "${TEMP_DIR}" .
        sudo chown ${USER}:${USER} "${PHYSICAL_BACKUP_FILE}"
        
        # Clean up
        sudo rm -rf "${TEMP_DIR}"
        
        log_message "Physical backup completed successfully: ${PHYSICAL_BACKUP_FILE}"
        log_message "Backup size: $(du -h "${PHYSICAL_BACKUP_FILE}" | cut -f1)"
        return 0
    else
        log_message "ERROR: Physical backup failed!"
        BACKUP_FAILED=1
        sudo rm -rf "${TEMP_DIR}"
        return 1
    fi
}



# ----------------------------------------------------------------------------
# UPLOAD FUNCTION
# ----------------------------------------------------------------------------
upload_to_gdrive() {
    log_message "Starting upload to Google Drive..."
    
    # Upload logical backup
    if ! rclone copy "${LOGICAL_BACKUP_FILE}" "${GDRIVE_REMOTE}" --progress; then
        log_message "ERROR: Failed to upload logical backup to Google Drive"
        send_failure_email "FAILURE: PostgreSQL Backup Upload" \
            "Backups were created locally but failed to upload to Google Drive. Check rclone logs.
            
Failed file: ${LOGICAL_BACKUP_FILE##*/}"
        return 1
    fi
    log_message "Logical backup uploaded successfully"
    
    # Upload physical backup
    if ! rclone copy "${PHYSICAL_BACKUP_FILE}" "${GDRIVE_REMOTE}" --progress; then
        log_message "ERROR: Failed to upload physical backup to Google Drive"
        send_failure_email "FAILURE: PostgreSQL Backup Upload" \
            "Backups were created locally but failed to upload to Google Drive. Check rclone logs.
            
Failed file: ${PHYSICAL_BACKUP_FILE##*/}"
        return 1
    fi
    log_message "Physical backup uploaded successfully"
    
    log_message "All backups uploaded to Google Drive successfully"
    return 0
}

# ----------------------------------------------------------------------------
# CLEANUP FUNCTION
# ----------------------------------------------------------------------------

cleanup_old_backups() {
    log_message "Starting cleanup of backups older than ${RETENTION_DAYS} days..."
    
    local DELETED_COUNT=$(find "${BACKUP_DIR}" -name "*.dump" -o -name "*.tar.gz" -type f -mtime +${RETENTION_DAYS} | wc -l)
    
    if [ "${DELETED_COUNT}" -gt 0 ]; then
        find "${BACKUP_DIR}" \( -name "*.dump" -o -name "*.tar.gz" \) -type f -mtime +${RETENTION_DAYS} -delete
        log_message "Deleted ${DELETED_COUNT} old backup file(s)"
    else
        log_message "No old backup files to delete"
    fi
}

# ----------------------------------------------------------------------------
# MAIN EXECUTION
# ----------------------------------------------------------------------------

main() {
    log_message "============================================================"
    log_message "PostgreSQL Backup Process Started"
    log_message "============================================================"
    
    # Create backup directory if it doesn't exist
    mkdir -p "${BACKUP_DIR}"
    
    # Perform logical backup
    if ! perform_logical_backup; then
        send_failure_email "FAILURE: PostgreSQL Backup Task" \
            "Logical backup of ${DB_NAME} failed. Please investigate immediately."
        log_message "Backup process terminated due to logical backup failure"
        exit 1
    fi
    
    # Perform physical backup
    if ! perform_physical_backup; then
        send_failure_email "FAILURE: PostgreSQL Backup Task" \
            "Physical base backup failed. Please investigate immediately."
        log_message "Backup process terminated due to physical backup failure"
        exit 1
    fi
    
    # Check if any backup failed
    if [ "${BACKUP_FAILED}" -eq 1 ]; then
        log_message "Backup failed. Skipping upload and cleanup."
        exit 1
    fi
    
    # Upload to Google Drive
    if upload_to_gdrive; then
        send_success_email
        
        # Cleanup old backups only after successful upload
        cleanup_old_backups
        
        log_message "============================================================"
        log_message "PostgreSQL Backup Process Completed Successfully"
        log_message "============================================================"
    else
        log_message "Upload failed. Keeping local backups."
        exit 1
    fi
}

# Redirect all output to log file
exec 1>> "${LOG_FILE}" 2>&1

# Run main function
main

exit 0
