#!/bin/bash
# backup/backup-appdata.sh — LVM snapshot backup of appdata to Storj
# Installed to /usr/local/bin/backup-appdata by setup.sh
# Runs as root via systemd (EnvironmentFile=/etc/backup-appdata.conf)

set -euo pipefail

# ── Config (injected by systemd EnvironmentFile or hardcoded defaults) ────────
RCLONE_REMOTE="${RCLONE_REMOTE:-storj-backup}"
RCLONE_CONFIG="${RCLONE_CONFIG:-/root/.config/rclone/rclone.conf}"
STORJ_BUCKET="${STORJ_BUCKET:-mariusz-appdata-backups}"
LV_PATH="${LV_PATH:-/dev/mariusz-vg/appdata}"
LVM_SNAP_SIZE="${LVM_SNAP_SIZE:-5G}"
BACKUP_KEEP="${BACKUP_KEEP:-7}"

SNAP_NAME="appdata-snap"
SNAP_PATH="/dev/mariusz-vg/$SNAP_NAME"
MOUNT_POINT="/mnt/backup-snap"
TIMESTAMP="$(date +%Y-%m-%dT%H-%M-%S)"
BACKUP_NAME="appdata-${TIMESTAMP}.tar.gz"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
die()  { log "ERROR: $*" >&2; exit 1; }

cleanup() {
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        log "Unmounting snapshot..."
        umount "$MOUNT_POINT" || true
    fi
    if lvs "$SNAP_PATH" &>/dev/null; then
        log "Removing snapshot..."
        lvremove -f "$SNAP_PATH" || true
    fi
}
trap cleanup EXIT

log "══════════════════════════════════════════════"
log "  appdata backup — $TIMESTAMP"
log "══════════════════════════════════════════════"

# ── Sanity checks ─────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Must run as root"
lvs "$LV_PATH" &>/dev/null || die "LV $LV_PATH not found"
if lvs "$SNAP_PATH" &>/dev/null; then
    die "Snapshot $SNAP_PATH already exists — previous backup may have crashed. Remove it manually: lvremove -f $SNAP_PATH"
fi

# ── Create LVM snapshot ───────────────────────────────────────────────────────
log "Creating snapshot ($LVM_SNAP_SIZE COW space)..."
lvcreate -L"$LVM_SNAP_SIZE" -s -n "$SNAP_NAME" "$LV_PATH"
log "Snapshot ready: $SNAP_PATH"

# ── Mount snapshot (read-only) ────────────────────────────────────────────────
mkdir -p "$MOUNT_POINT"
mount -o ro "$SNAP_PATH" "$MOUNT_POINT"
log "Snapshot mounted at $MOUNT_POINT"

# ── Stream tar → rclone → Storj ───────────────────────────────────────────────
log "Uploading $BACKUP_NAME to $RCLONE_REMOTE:$STORJ_BUCKET ..."
tar \
    -C "$MOUNT_POINT" \
    --exclude='./lost+found' \
    -czf - . \
    | rclone rcat \
        --config "$RCLONE_CONFIG" \
        "$RCLONE_REMOTE:$STORJ_BUCKET/$BACKUP_NAME"
log "Upload complete"

# ── Prune old backups ─────────────────────────────────────────────────────────
log "Pruning old backups (keeping $BACKUP_KEEP)..."
BACKUPS=$(rclone lsf --config "$RCLONE_CONFIG" "$RCLONE_REMOTE:$STORJ_BUCKET" \
    | grep '^appdata-' | sort || true)
COUNT=$(echo "$BACKUPS" | grep -c . || echo 0)
TO_DELETE=$(( COUNT - BACKUP_KEEP ))

if [[ $TO_DELETE -gt 0 ]]; then
    echo "$BACKUPS" | head -n "$TO_DELETE" | while read -r f; do
        [[ -z "$f" ]] && continue
        log "  Deleting: $f"
        rclone deletefile --config "$RCLONE_CONFIG" "$RCLONE_REMOTE:$STORJ_BUCKET/$f"
    done
    log "Pruned $TO_DELETE old backup(s)"
else
    log "No pruning needed ($COUNT / $BACKUP_KEEP slots used)"
fi

log "══════════════════════════════════════════════"
log "  Done! Backup stored as $BACKUP_NAME"
log "══════════════════════════════════════════════"
