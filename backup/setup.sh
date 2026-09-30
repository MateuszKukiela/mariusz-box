#!/bin/bash
# backup/setup.sh — install or refresh the nightly Storj backup. Safe to re-run.
#
# Required .env variables:
#   STORJ_ACCESS_KEY     — Storj S3 access key
#   STORJ_SECRET_KEY     — Storj S3 secret key
#   STORJ_ENDPOINT       — Storj S3 endpoint (https://gateway.storjshare.io)
#   STORJ_BUCKET         — Storj bucket name
# Optional:
#   BACKUP_RETAIN_DAYS   — space-separated days-ago targets to retain (default: "0 1 7 30")
#   BACKUP_SCHEDULE      — systemd OnCalendar expression (default: *-*-* 05:00:00)
#   BACKUP_PUSH_URL      — Uptime Kuma push URL, pinged after every run
#   BACKUP_PATHS, BACKUP_EXCLUDES — override what goes in (see backup.sh)
#
# Usage:
#   bash backup/setup.sh          # install/refresh
#   bash backup/setup.sh --now    # ...and start a backup right away

set -euo pipefail

RUN_NOW=false
[[ "${1:-}" == "--now" ]] && RUN_NOW=true

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ENV_FILE="$REPO_DIR/.env"
SCRIPT_DST="/usr/local/bin/mariusz-backup"
CONF_FILE="/etc/mariusz-backup.conf"
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
RCLONE_REMOTE="storj-backup"

[[ -f "$ENV_FILE" ]] || { echo "ERROR: .env not found at $ENV_FILE"; exit 1; }
# Read only the keys this needs: sourcing all of .env would expand the $ in the
# bcrypt hashes.
env_get() {
    local v
    v=$(grep -m1 "^$1=" "$ENV_FILE" | cut -d= -f2-) || true
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    printf '%s' "$v"
}
for k in STORJ_ACCESS_KEY STORJ_SECRET_KEY STORJ_ENDPOINT STORJ_BUCKET \
         BACKUP_RETAIN_DAYS BACKUP_SCHEDULE BACKUP_PUSH_URL BACKUP_PATHS BACKUP_EXCLUDES; do
    v=$(env_get "$k")
    [[ -n "$v" ]] && printf -v "$k" '%s' "$v"
done

: "${STORJ_ACCESS_KEY:?Add STORJ_ACCESS_KEY to .env}"
: "${STORJ_SECRET_KEY:?Add STORJ_SECRET_KEY to .env}"
: "${STORJ_ENDPOINT:?Add STORJ_ENDPOINT to .env}"
: "${STORJ_BUCKET:?Add STORJ_BUCKET to .env}"
BACKUP_RETAIN_DAYS="${BACKUP_RETAIN_DAYS:-0 1 7 30}"
BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-*-*-* 05:00:00}"

echo "[1/5] rclone"
command -v rclone &>/dev/null || sudo pacman -S --needed --noconfirm rclone
echo "      $(rclone --version | head -1)"

echo "[2/5] Storj remote"
sudo mkdir -p "$(dirname "$RCLONE_CONFIG")"
sudo tee "$RCLONE_CONFIG" > /dev/null <<EOF
[$RCLONE_REMOTE]
type = s3
provider = Other
access_key_id = $STORJ_ACCESS_KEY
secret_access_key = $STORJ_SECRET_KEY
endpoint = $STORJ_ENDPOINT
EOF
sudo chmod 600 "$RCLONE_CONFIG"
if sudo rclone lsd "$RCLONE_REMOTE:" --config "$RCLONE_CONFIG" | grep -qw "$STORJ_BUCKET"; then
    echo "      bucket '$STORJ_BUCKET' exists"
else
    sudo rclone mkdir "$RCLONE_REMOTE:$STORJ_BUCKET" --config "$RCLONE_CONFIG"
    echo "      created bucket '$STORJ_BUCKET'"
fi

echo "[3/5] $CONF_FILE"
{
    echo "RCLONE_REMOTE=$RCLONE_REMOTE"
    echo "RCLONE_CONFIG=$RCLONE_CONFIG"
    echo "STORJ_BUCKET=$STORJ_BUCKET"
    echo "REPO_DIR=$REPO_DIR"
    echo "BACKUP_RETAIN_DAYS=\"$BACKUP_RETAIN_DAYS\""
    [[ -n "${BACKUP_PUSH_URL:-}" ]] && echo "BACKUP_PUSH_URL=\"$BACKUP_PUSH_URL\""
    [[ -n "${BACKUP_PATHS:-}" ]] && echo "BACKUP_PATHS=\"$BACKUP_PATHS\""
    [[ -n "${BACKUP_EXCLUDES:-}" ]] && echo "BACKUP_EXCLUDES=\"$BACKUP_EXCLUDES\""
    true
} | sudo tee "$CONF_FILE" > /dev/null
sudo chmod 600 "$CONF_FILE"

echo "[4/5] $SCRIPT_DST"
sudo install -m 755 "$REPO_DIR/backup/backup.sh" "$SCRIPT_DST"

echo "[5/5] systemd timer ($BACKUP_SCHEDULE)"
sudo tee /etc/systemd/system/mariusz-backup.service > /dev/null <<EOF
[Unit]
Description=Back up mariusz-box to Storj
Wants=network-online.target
After=network-online.target docker.service zfs-mount.service

[Service]
Type=oneshot
ExecStart=$SCRIPT_DST
TimeoutStartSec=6h
EOF
sudo tee /etc/systemd/system/mariusz-backup.timer > /dev/null <<EOF
[Unit]
Description=Nightly mariusz-box backup

[Timer]
OnCalendar=$BACKUP_SCHEDULE
Persistent=true

[Install]
WantedBy=timers.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now mariusz-backup.timer >/dev/null
systemctl list-timers mariusz-backup.timer --no-pager --no-legend | awk '{print "      next run:", $1, $2, $3}'

if $RUN_NOW; then
    echo "Starting a backup now (journalctl -fu mariusz-backup to watch)"
    sudo systemctl start --no-block mariusz-backup.service
fi
