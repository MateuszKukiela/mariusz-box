#!/bin/bash
# backup/backup.sh — nightly backup of everything the box needs, to Storj.
# Installed to /usr/local/bin/mariusz-backup by backup/setup.sh and run by
# mariusz-backup.timer, with settings from /etc/mariusz-backup.conf.
#
# Nothing is stopped. The archive is read from snapshots: one read-only btrfs
# snapshot of the KIOXIA's top level (appdata, metadata and the repo, taken
# atomically), one of its docker subvolume (for the volumes), and one of the
# ZFS pool (photos, /mariusz/ssd). Databases in them are crash-consistent,
# which Postgres, MariaDB and SQLite recover from like a power cut. Each file
# sits at its real path in the archive, so a restore is `tar -xf … -C /`.

set -euo pipefail

[[ -f /etc/mariusz-backup.conf ]] && source /etc/mariusz-backup.conf
RCLONE_REMOTE="${RCLONE_REMOTE:-storj-backup}"
RCLONE_CONFIG="${RCLONE_CONFIG:-/root/.config/rclone/rclone.conf}"
STORJ_BUCKET="${STORJ_BUCKET:-appdata}"
STAGING="${STAGING:-/srv/mariusz-box/backup-staging}"
# btrfs top level of the KIOXIA, its docker subvolume, and where snapshots go.
BTRFS_TOP="${BTRFS_TOP:-/srv/mariusz-box}"
BTRFS_DOCKER="${BTRFS_DOCKER:-/srv/mariusz-box/docker}"
SNAP_DIR="${SNAP_DIR:-/srv/mariusz-box/.snapshots}"
# How many nightly top-level snapshots to keep on the KIOXIA for quick rollback.
KEEP_LOCAL_SNAPSHOTS="${KEEP_LOCAL_SNAPSHOTS:-3}"
ZFS_DATASET="${ZFS_DATASET:-mariusz}"
# Days ago to keep a backup for: the one closest to each target survives.
BACKUP_RETAIN_DAYS="${BACKUP_RETAIN_DAYS:-0 1 7 30}"
# Optional Uptime Kuma push URL, pinged with the result of every run.
BACKUP_PUSH_URL="${BACKUP_PUSH_URL:-}"
# Paths relative to /. Missing ones are skipped.
BACKUP_PATHS="${BACKUP_PATHS:-srv/mariusz-box/appdata srv/mariusz-box/metadata srv/mariusz-box/mariusz-box var/lib/docker/volumes mariusz/data/media/photos mariusz/ssd etc usr/local root home/mateusz/.ssh}"
# Anchored tar patterns: caches that rebuild themselves, and Docker's own files.
BACKUP_EXCLUDES="${BACKUP_EXCLUDES:-srv/mariusz-box/appdata/lost+found srv/mariusz-box/metadata/jellyfin/cache srv/mariusz-box/metadata/jellyfin/data/transcodes srv/mariusz-box/metadata/jellyfin/data/temp var/lib/docker/volumes/mariusz-box_model-cache var/lib/docker/volumes/backingFsBlockDev var/lib/docker/volumes/metadata.db mariusz/data/media/photos/encoded-video}"

TIMESTAMP="$(date +%Y-%m-%dT%H-%M-%S)"
BACKUP_NAME="mariusz-box-${TIMESTAMP}.tar.zst"
RC=(rclone --config "$RCLONE_CONFIG")

log()  { echo "[$(date +%H:%M:%S)] $*"; }
push() {
    [[ -n $BACKUP_PUSH_URL ]] || return 0
    curl -fsS -m 15 -o /dev/null -G "$BACKUP_PUSH_URL" \
        --data-urlencode "status=$1" --data-urlencode "msg=$2" --data-urlencode "ping=" || true
}
die()  { log "ERROR: $*" >&2; push down "$*"; exit 1; }

SNAP="$SNAP_DIR/$TIMESTAMP"
SNAP_DOCKER="$SNAP_DIR/$TIMESTAMP-docker"
ZFS_SNAP="$ZFS_DATASET@backup-$TIMESTAMP"
VIEW="/run/mariusz-backup/view"
ZFS_MOUNT=""

drop_zfs_snapshot() {
    zfs list -H -t snapshot "$ZFS_SNAP" &>/dev/null || return 0
    # Reading it automounted the snapshot under .zfs; unmount before destroying.
    [[ -n $ZFS_MOUNT ]] && umount "$ZFS_MOUNT/.zfs/snapshot/backup-$TIMESTAMP" 2>/dev/null || true
    zfs destroy "$ZFS_SNAP"
}
cleanup() {
    mountpoint -q "$VIEW" && { umount -R "$VIEW" || umount -Rl "$VIEW" || true; }
    rm -rf /run/mariusz-backup
    drop_zfs_snapshot || log "WARNING: could not destroy $ZFS_SNAP"
    [[ -d "$SNAP_DOCKER" ]] && { btrfs -q subvolume delete "$SNAP_DOCKER" || log "WARNING: could not delete $SNAP_DOCKER"; }
    rm -f "$STAGING"/*.partial
}
trap cleanup EXIT

log "══════════════════════════════════════════════"
log "  mariusz-box backup — $TIMESTAMP"
log "══════════════════════════════════════════════"

[[ $EUID -eq 0 ]] || die "Must run as root"
exec 9>/run/mariusz-backup.lock
flock -n 9 || die "Another backup is already running"
btrfs subvolume show "$BTRFS_TOP" &>/dev/null || die "$BTRFS_TOP is not a btrfs subvolume"
mkdir -p "$STAGING" "$SNAP_DIR"

# ── Snapshots (instant, nothing stops) ────────────────────────────────────────
log "Snapshotting $BTRFS_TOP, $BTRFS_DOCKER and $ZFS_DATASET ..."
btrfs -q subvolume snapshot -r "$BTRFS_TOP" "$SNAP"
btrfs -q subvolume snapshot -r "$BTRFS_DOCKER" "$SNAP_DOCKER"
zfs snapshot "$ZFS_SNAP"
ZFS_MOUNT=$(zfs get -H -o value mountpoint "$ZFS_DATASET")

# Where each path is read from: the snapshot that holds it, or the live system
# for host config that no service writes to.
source_for() {
    local p="/$1"
    case "$p" in
        "$BTRFS_DOCKER"/*) echo "$SNAP_DOCKER/${p#"$BTRFS_DOCKER"/}" ;;
        /var/lib/docker/*) echo "$SNAP_DOCKER/${p#/var/lib/docker/}" ;;
        "$BTRFS_TOP"/*)    echo "$SNAP/${p#"$BTRFS_TOP"/}" ;;
        "$ZFS_MOUNT"/*)    echo "$ZFS_MOUNT/.zfs/snapshot/backup-$TIMESTAMP/${p#"$ZFS_MOUNT"/}" ;;
        *)                 echo "$p" ;;
    esac
}

# Bind every source, read-only, at its real path under $VIEW, so the archive
# holds real paths no matter where each one was read from. $VIEW is a tmpfs, so
# the placeholder directories never touch a real disk.
mkdir -p "$VIEW"
mount -t tmpfs -o size=1m,mode=755 mariusz-backup "$VIEW"
paths=()
for p in $BACKUP_PATHS; do
    src=$(source_for "$p")
    if [[ ! -e "$src" ]]; then log "Skipping missing /$p"; continue; fi
    if [[ -d "$src" ]]; then mkdir -p "$VIEW/$p"; else mkdir -p "$(dirname "$VIEW/$p")"; touch "$VIEW/$p"; fi
    mount --bind "$src" "$VIEW/$p"
    mount -o remount,bind,ro "$VIEW/$p"
    paths+=("$p")
done
excludes=()
for e in $BACKUP_EXCLUDES; do excludes+=(--exclude="$e"); done

log "Writing $BACKUP_NAME ..."
tar_rc=0
tar --numeric-owner --xattrs --xattrs-include='*' --acls \
    -I 'zstd -T0 -3' --anchored "${excludes[@]}" \
    -cf "$STAGING/$BACKUP_NAME.partial" -C "$VIEW" "${paths[@]}" || tar_rc=$?
# 1 means a live host file changed while it was read, which is fine.
(( tar_rc <= 1 )) || die "tar failed with exit code $tar_rc"

# The pool and docker snapshots were only needed for the tar.
umount -R "$VIEW"; rm -rf /run/mariusz-backup
drop_zfs_snapshot
btrfs -q subvolume delete "$SNAP_DOCKER"

# Keep the newest top-level snapshots for a local rollback, drop the rest.
mapfile -t old < <(find "$SNAP_DIR" -mindepth 1 -maxdepth 1 -name '20*' ! -name '*-docker' | sort | head -n "-$KEEP_LOCAL_SNAPSHOTS")
for o in "${old[@]}"; do btrfs -q subvolume delete "$o" && log "Dropped local snapshot $(basename "$o")"; done

zstd -tq "$STAGING/$BACKUP_NAME.partial" || die "archive failed its integrity check"
mv "$STAGING/$BACKUP_NAME.partial" "$STAGING/$BACKUP_NAME"
size=$(stat -c %s "$STAGING/$BACKUP_NAME")
log "Archive ready: $(numfmt --to=iec "$size")"

# ── Upload ────────────────────────────────────────────────────────────────────
log "Uploading to $RCLONE_REMOTE:$STORJ_BUCKET ..."
"${RC[@]}" copyto --s3-chunk-size 64M --s3-upload-concurrency 8 \
    --stats 30s --stats-one-line --stats-log-level NOTICE \
    "$STAGING/$BACKUP_NAME" "$RCLONE_REMOTE:$STORJ_BUCKET/$BACKUP_NAME" \
    || die "upload failed"
remote_size=$("${RC[@]}" lsjson "$RCLONE_REMOTE:$STORJ_BUCKET/$BACKUP_NAME" | grep -oE '"Size":[0-9]+' | cut -d: -f2)
[[ "$remote_size" == "$size" ]] || die "remote size $remote_size != local size $size"
log "Upload complete and verified"

# Keep only this run's archive locally, for a restore without a download.
find "$STAGING" -maxdepth 1 -name 'mariusz-box-*.tar.zst' ! -name "$BACKUP_NAME" -delete

# ── Prune old backups (GFS retention) ────────────────────────────────────────
# Keep the backup closest to each target age (today, yesterday, 1w, 1m, etc.)
# Everything else is deleted. appdata-*.tar.gz are the old VM's backups; they
# take part in the same rotation and age out on their own.
log "Pruning — GFS retention targets: ${BACKUP_RETAIN_DAYS} days ago"

declare -A KEEP

BACKUPS=$("${RC[@]}" lsf "$RCLONE_REMOTE:$STORJ_BUCKET" \
    | grep -E '^(mariusz-box|appdata)-' | sort || true)

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
            # Extract timestamp: mariusz-box-2026-03-28T18-16-46.tar.zst → 2026-03-28T18:16:46
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
            "${RC[@]}" deletefile "$RCLONE_REMOTE:$STORJ_BUCKET/$f"
            (( PRUNED++ )) || true
        fi
    done <<< "$BACKUPS"
    log "Pruned $PRUNED backup(s), kept ${#KEEP[@]}"
fi

push up "OK $(numfmt --to=iec "$size")"
log "══════════════════════════════════════════════"
log "  Done! Backup stored as $BACKUP_NAME"
log "══════════════════════════════════════════════"
