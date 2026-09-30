#!/bin/bash
# backup/backup.sh — nightly backup of everything the box needs, to Storj.
# Installed to /usr/local/bin/mariusz-backup by backup/setup.sh and run by
# mariusz-backup.timer, with settings from /etc/mariusz-backup.conf.
#
# The running compose services are stopped while the archive is written (a
# couple of minutes), so every database in it is consistent, and started again
# before the upload. Each file sits at its real path in the archive, so a
# restore is `tar -xf … -C /`.

set -euo pipefail

[[ -f /etc/mariusz-backup.conf ]] && source /etc/mariusz-backup.conf
RCLONE_REMOTE="${RCLONE_REMOTE:-storj-backup}"
RCLONE_CONFIG="${RCLONE_CONFIG:-/root/.config/rclone/rclone.conf}"
STORJ_BUCKET="${STORJ_BUCKET:-appdata}"
REPO_DIR="${REPO_DIR:-/srv/mariusz-box/mariusz-box}"
STAGING="${STAGING:-/srv/mariusz-box/backup-staging}"
# Days ago to keep a backup for: the one closest to each target survives.
BACKUP_RETAIN_DAYS="${BACKUP_RETAIN_DAYS:-0 1 7 30}"
# Optional Uptime Kuma push URL, pinged with the result of every run.
BACKUP_PUSH_URL="${BACKUP_PUSH_URL:-}"
# Paths relative to /. Missing ones are skipped.
BACKUP_PATHS="${BACKUP_PATHS:-srv/mariusz-box/appdata srv/mariusz-box/metadata srv/mariusz-box/mariusz-box var/lib/docker/volumes mariusz/data/media/photos mariusz/ssd etc usr/local root home/mateusz/.ssh}"
# Anchored tar patterns: caches that rebuild themselves, and Docker's own files.
BACKUP_EXCLUDES="${BACKUP_EXCLUDES:-srv/mariusz-box/appdata/lost+found srv/mariusz-box/metadata/jellyfin/cache srv/mariusz-box/metadata/jellyfin/data/transcodes srv/mariusz-box/metadata/jellyfin/data/temp var/lib/docker/volumes/mariusz-box_model-cache var/lib/docker/volumes/backingFsBlockDev var/lib/docker/volumes/metadata.db}"

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

RUNNING=()
STOPPED=false
start_stack() {
    $STOPPED || return 0
    STOPPED=false
    # With no names, compose would start every service, including ones that
    # were stopped on purpose.
    (( ${#RUNNING[@]} )) || return 0
    log "Starting ${#RUNNING[@]} services..."
    (cd "$REPO_DIR" && docker compose start "${RUNNING[@]}") || log "WARNING: docker compose start failed"
}
cleanup() {
    start_stack
    rm -f "$STAGING"/*.partial
}
trap cleanup EXIT

log "══════════════════════════════════════════════"
log "  mariusz-box backup — $TIMESTAMP"
log "══════════════════════════════════════════════"

[[ $EUID -eq 0 ]] || die "Must run as root"
exec 9>/run/mariusz-backup.lock
flock -n 9 || die "Another backup is already running"
[[ -f $REPO_DIR/docker-compose.yml ]] || die "No compose project at $REPO_DIR"
mkdir -p "$STAGING"

paths=()
for p in $BACKUP_PATHS; do
    if [[ -e "/$p" ]]; then paths+=("$p"); else log "Skipping missing /$p"; fi
done
excludes=()
for e in $BACKUP_EXCLUDES; do excludes+=(--exclude="$e"); done

# ── Stop, archive, start ──────────────────────────────────────────────────────
mapfile -t RUNNING < <(cd "$REPO_DIR" && docker compose ps --services --status running)
log "Stopping ${#RUNNING[@]} running services..."
t_stop=$(date +%s)
STOPPED=true
(cd "$REPO_DIR" && docker compose stop) >/dev/null 2>&1

log "Writing $BACKUP_NAME ..."
tar_rc=0
tar --numeric-owner --xattrs --xattrs-include='*' --acls \
    -I 'zstd -T0 -3' --anchored "${excludes[@]}" \
    -cf "$STAGING/$BACKUP_NAME.partial" -C / "${paths[@]}" || tar_rc=$?

start_stack
log "Services were down for $(( $(date +%s) - t_stop ))s"
# 1 means a file changed while it was read, which is fine for the live paths.
(( tar_rc <= 1 )) || die "tar failed with exit code $tar_rc"

zstd -tq "$STAGING/$BACKUP_NAME.partial" || die "archive failed its integrity check"
mv "$STAGING/$BACKUP_NAME.partial" "$STAGING/$BACKUP_NAME"
size=$(stat -c %s "$STAGING/$BACKUP_NAME")
log "Archive ready: $(numfmt --to=iec "$size")"

# ── Upload ────────────────────────────────────────────────────────────────────
log "Uploading to $RCLONE_REMOTE:$STORJ_BUCKET ..."
"${RC[@]}" copyto --s3-chunk-size 64M --s3-upload-concurrency 8 \
    --stats 30s --stats-one-line \
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
