#!/bin/bash
# backup/backup-appdata.sh — LVM snapshot backup of appdata to Storj
# Installed to /usr/local/bin/backup-appdata by setup.sh
# Runs as root via systemd (EnvironmentFile=/etc/backup-appdata.conf)

set -euo pipefail

# ── Config (from conf file, systemd EnvironmentFile, or hardcoded defaults) ───
[[ -f /etc/backup-appdata.conf ]] && source /etc/backup-appdata.conf
RCLONE_REMOTE="${RCLONE_REMOTE:-storj-backup}"
RCLONE_CONFIG="${RCLONE_CONFIG:-/root/.config/rclone/rclone.conf}"
STORJ_BUCKET="${STORJ_BUCKET:-mariusz-appdata-backups}"
LV_PATH="${LV_PATH:-/dev/mariusz-vg/appdata}"
LVM_SNAP_SIZE="${LVM_SNAP_SIZE:-5G}"
# Days ago to retain a backup for — keep the closest backup to each target
# Default: today, yesterday, 1 week ago, 1 month ago
BACKUP_RETAIN_DAYS="${BACKUP_RETAIN_DAYS:-0 1 7 30}"

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

# ── Prune old backups (GFS retention) ────────────────────────────────────────
# Keep the backup closest to each target age (today, yesterday, 1w, 1m, etc.)
# Everything else is deleted.
log "Pruning — GFS retention targets: ${BACKUP_RETAIN_DAYS} days ago"

declare -A KEEP

BACKUPS=$(rclone lsf --config "$RCLONE_CONFIG" "$RCLONE_REMOTE:$STORJ_BUCKET" \
    | grep '^appdata-' | sort || true)

if [[ -z "$BACKUPS" ]]; then
    log "No backups found to prune"
else
    # For each retention target, find the backup closest to that date
    for days_ago in $BACKUP_RETAIN_DAYS; do
        target_ts=$(date -d "$days_ago days ago" +%s)
        best=""
        best_diff=999999999
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            # Extract timestamp: appdata-2026-03-28T18-16-46.tar.gz → 2026-03-28T18:16:46
            raw=$(echo "$f" | grep -oP '\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}') || continue
            fdate="${raw:0:10}T${raw:11:2}:${raw:14:2}:${raw:17:2}"
            fts=$(date -d "$fdate" +%s 2>/dev/null) || continue
            diff=$(( fts - target_ts ))
            [[ $diff -lt 0 ]] && diff=$(( -diff ))
            if [[ $diff -lt $best_diff ]]; then
                best_diff=$diff
                best="$f"
            fi
        done <<< "$BACKUPS"
        if [[ -n "$best" ]]; then
            KEEP["$best"]=1
            log "  Keep (${days_ago}d ago target): $best"
        fi
    done

    # Delete anything not in the keep set
    PRUNED=0
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if [[ -z "${KEEP[$f]+x}" ]]; then
            log "  Delete: $f"
            rclone deletefile --config "$RCLONE_CONFIG" "$RCLONE_REMOTE:$STORJ_BUCKET/$f"
            (( PRUNED++ )) || true
        fi
    done <<< "$BACKUPS"
    log "Pruned $PRUNED backup(s), kept ${#KEEP[@]}"
fi

log "══════════════════════════════════════════════"
log "  Done! Backup stored as $BACKUP_NAME"
log "══════════════════════════════════════════════"
