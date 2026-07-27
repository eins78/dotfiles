#!/bin/bash
#
# Auto Time Machine Backup & Eject — outcome-based version.
# Triggered by launchd when /Volumes changes.
#
# Strategy: poll until a backup completes, then eject.
# We do NOT trust `tmutil startbackup`'s return code (silent 0 when backupd
# isn't ready). Completion is detected via Running: 0→1→0 in `tmutil status`
# — the only tmutil command that works without Full Disk Access in launchd.
#

export PATH="/usr/sbin:/usr/bin:/bin:/sbin"

BACKUP_DISK_NAME="Time Machine"
LOG_FILE="$HOME/Library/Logs/auto-backup.log"
LOCK_FILE="/tmp/tm-backup.lock"

POLL_INTERVAL=180                  # check every 3 min
TRIGGER_INTERVAL=600               # re-issue startbackup at most every 10 min
MAX_WAIT_SECONDS=$((6 * 60 * 60))  # give up after 6h with no fresh backup
INITIAL_MOUNT_WAIT=10              # let the mount settle before first check

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" >> "$LOG_FILE"
}

notify() {
    osascript -e "display notification \"$1\" with title \"Time Machine\""
}

# tmutil latestbackup requires Full Disk Access, which a launchd user agent
# doesn't have — so we can't read backup timestamps. Instead we watch for the
# Running: 0 → 1 → 0 transition in tmutil status, which needs no FDA.

eject_disk() {
    log "Waiting 2 min for backupd to release the disk..."
    # Do NOT call tmutil disable/stopbackup here — it interrupts in-flight
    # APFS snapshot work and creates corrupted .interrupted folders.
    sleep 120

    log "Attempting eject (up to ~13 min for mds to release)..."
    for attempt in $(seq 1 26); do
        if diskutil eject "/Volumes/$BACKUP_DISK_NAME" 2>/dev/null; then
            log "Disk ejected (attempt $attempt)."
            notify "Backup complete. Disk ejected."
            return 0
        fi
        [ $((attempt % 5)) -eq 0 ] && log "Still waiting to eject (attempt $attempt/26)..."
        sleep 30
    done

    log "Eject still failing — killing mds and retrying."
    sudo killall -HUP mds 2>/dev/null
    if diskutil eject "/Volumes/$BACKUP_DISK_NAME" 2>/dev/null; then
        log "Ejected after mds kill."
        notify "Backup complete. Disk ejected."
        return 0
    fi

    log "Trying force unmount of parent device."
    PARENT_DISK=$(diskutil info "/Volumes/$BACKUP_DISK_NAME" 2>/dev/null \
        | awk -F': *' '/Part of Whole/ {print "/dev/"$2}')
    if [ -n "$PARENT_DISK" ] && diskutil unmountDisk force "$PARENT_DISK" 2>/dev/null; then
        diskutil eject "$PARENT_DISK" 2>/dev/null
        log "Force-unmounted parent + ejected."
        notify "Backup complete. Disk ejected."
        return 0
    fi

    log "Manual eject required. Open file handles:"
    lsof "/Volumes/$BACKUP_DISK_NAME" 2>/dev/null >> "$LOG_FILE"
    notify "Backup done but eject failed. Eject the disk manually."
    return 1
}

# --- pre-checks ---

if [ ! -d "/Volumes/$BACKUP_DISK_NAME" ]; then
    exit 0
fi

if [ -f "$LOCK_FILE" ]; then
    if [ $(($(date +%s) - $(stat -f %m "$LOCK_FILE"))) -lt $((MAX_WAIT_SECONDS + 600)) ]; then
        log "Another backup process running (lock present), skipping."
        exit 0
    fi
    log "Removing stale lock."
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

START_TS=$(date +%s)
log "Backup disk '$BACKUP_DISK_NAME' detected. Polling for fresh backup (max $((MAX_WAIT_SECONDS / 3600))h)."
sleep "$INITIAL_MOUNT_WAIT"

# --- main poll loop ---

LAST_TRIGGER=0
BACKUP_OBSERVED=false   # flips true when we see Running=1; eject on 1→0

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TS))

    if [ ! -d "/Volumes/$BACKUP_DISK_NAME" ]; then
        log "Disk no longer mounted — exiting (elapsed ${ELAPSED}s)."
        exit 0
    fi

    if [ "$ELAPSED" -ge "$MAX_WAIT_SECONDS" ]; then
        log "ERROR: No backup completed within $((MAX_WAIT_SECONDS / 3600))h. Leaving disk mounted."
        notify "Time Machine backup did not complete in $((MAX_WAIT_SECONDS / 3600))h. Check TM."
        exit 1
    fi

    if tmutil status 2>/dev/null | grep -q "Running = 1"; then
        if [ "$BACKUP_OBSERVED" = false ]; then
            log "Backup started — watching for completion (elapsed $((ELAPSED / 60))m)."
            BACKUP_OBSERVED=true
        else
            log "Backup in progress (elapsed $((ELAPSED / 60))m)."
        fi
        sleep "$POLL_INTERVAL"
        continue
    fi

    # Running = 0: if we watched a full backup run, eject now.
    if [ "$BACKUP_OBSERVED" = true ]; then
        log "Backup completed (elapsed $((ELAPSED / 60))m). Ejecting."
        eject_disk
        exit $?
    fi

    # Idle, no backup observed yet — nudge backupd.
    if [ $((NOW - LAST_TRIGGER)) -ge "$TRIGGER_INTERVAL" ]; then
        log "Idle — triggering tmutil startbackup (elapsed $((ELAPSED / 60))m)."
        tmutil startbackup >/dev/null 2>&1 &
        LAST_TRIGGER=$NOW
    fi

    sleep "$POLL_INTERVAL"
done
