#!/bin/bash
#
# Auto Time Machine Backup & Eject
# Triggered by launchd when /Volumes changes
#

# launchd provides a minimal PATH, so set it explicitly
export PATH="/usr/sbin:/usr/bin:/bin:/sbin"

BACKUP_DISK_NAME="Time Machine"
LOG_FILE="$HOME/Library/Logs/auto-backup.log"
LOCK_FILE="/tmp/tm-backup.lock"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" >> "$LOG_FILE"
}

notify() {
    osascript -e "display notification \"$1\" with title \"Time Machine\""
}

# Check if our backup disk is mounted
if [ ! -d "/Volumes/$BACKUP_DISK_NAME" ]; then
    exit 0
fi

# Prevent concurrent runs using lock file
if [ -f "$LOCK_FILE" ]; then
    # Check if lock is stale (older than 4 hours)
    if [ $(($(date +%s) - $(stat -f %m "$LOCK_FILE"))) -lt 14400 ]; then
        log "Another backup process is running (lock file exists), skipping."
        exit 0
    fi
    log "Removing stale lock file."
    rm -f "$LOCK_FILE"
fi

# Also check if TM backup is already in progress
if tmutil status | grep -q "Running = 1"; then
    log "Backup already in progress, skipping."
    exit 0
fi

# Create lock file
echo $$ > "$LOCK_FILE"
trap "rm -f $LOCK_FILE" EXIT

log "Backup disk '$BACKUP_DISK_NAME' detected, starting Time Machine..."

# Small delay to let the disk fully mount
sleep 5

# Run Time Machine backup and wait for completion
tmutil startbackup --auto --block
BACKUP_EXIT_CODE=$?

if [ $BACKUP_EXIT_CODE -eq 0 ]; then
    log "Backup completed successfully."
else
    log "Backup finished with exit code $BACKUP_EXIT_CODE"
fi

# Release disk from system services
log "Releasing disk from system services..."
tmutil disable 2>/dev/null
tmutil stopbackup 2>/dev/null

# Wait for initial settling
sleep 120

# Wait for Spotlight to finish indexing, try unmount every 30s for ~13 min
log "Waiting for disk to become idle (up to 15 min)..."
MAX_ATTEMPTS=26  # 26 attempts × 30s = ~13 min (15 min total with initial 2 min wait)
for attempt in $(seq 1 $MAX_ATTEMPTS); do
    if diskutil unmount "/Volumes/$BACKUP_DISK_NAME" 2>/dev/null; then
        log "Disk unmounted successfully (attempt $attempt)."
        tmutil enable 2>/dev/null
        notify "Backup complete. Disk ejected."
        exit 0
    fi

    if [ $((attempt % 5)) -eq 0 ]; then
        log "Still waiting to unmount (attempt $attempt/$MAX_ATTEMPTS)..."
    fi

    sleep 30
done

# Kill mds (Spotlight) and unmount in the brief window before launchd respawns it.
# mds holds open file handles on TM volumes and vetoes unmount via Disk Arbitration.
# See: http://plasmasturm.org/log/apfs-timemachine-killall-mds/
log "Killing mds and trying unmount..."
sudo killall -HUP mds 2>/dev/null
if diskutil unmount "/Volumes/$BACKUP_DISK_NAME" 2>/dev/null; then
    log "Disk unmounted successfully after mds kill."
    tmutil enable 2>/dev/null
    notify "Backup complete. Disk ejected."
    exit 0
fi

# Force unmount as final fallback
log "Trying force unmount..."
sudo killall -HUP mds 2>/dev/null
if diskutil unmount force "/Volumes/$BACKUP_DISK_NAME" 2>/dev/null; then
    log "Disk force-unmounted successfully."
    tmutil enable 2>/dev/null
    notify "Backup complete. Disk ejected."
    exit 0
fi

tmutil enable 2>/dev/null
log "Failed to unmount - manual eject needed. Processes holding disk:"
lsof "/Volumes/$BACKUP_DISK_NAME" 2>/dev/null >> "$LOG_FILE"
notify "Backup complete. Please eject disk manually."
