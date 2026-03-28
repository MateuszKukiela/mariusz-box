#!/bin/bash
# backup/setup.sh — Idempotent setup for appdata LVM snapshot backups to Storj
#
# Required .env variables:
#   STORJ_ACCESS_KEY     — Storj S3 access key
#   STORJ_SECRET_KEY     — Storj S3 secret key
#   STORJ_ENDPOINT       — Storj S3 endpoint (https://gateway.storjshare.io)
#   STORJ_BUCKET         — Storj bucket name (e.g. mariusz-appdata-backups)
#   BACKUP_RETAIN_DAYS   — space-separated days-ago targets to retain (default: "0 1 7 30")
#   BACKUP_SCHEDULE      — systemd OnCalendar expression (default: *-*-* 03:00:00)
#   LVM_SNAP_SIZE        — LVM snapshot COW size (default: 5G)
#
# Usage:
#   cd /home/mariusz/mariusz-box
#   bash backup/setup.sh          # setup only
#   bash backup/setup.sh --now    # setup + run backup immediately

set -euo pipefail

RUN_NOW=false
for arg in "$@"; do
    [[ "$arg" == "--now" ]] && RUN_NOW=true
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_DIR/.env"
BACKUP_SCRIPT_SRC="$REPO_DIR/backup/backup-appdata.sh"
BACKUP_SCRIPT_DST="/usr/local/bin/backup-appdata"
RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
RCLONE_REMOTE="storj-backup"
CONF_FILE="/etc/backup-appdata.conf"

# ── Load .env ────────────────────────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] || { echo "ERROR: .env not found at $ENV_FILE"; exit 1; }
set -a; source "$ENV_FILE"; set +a

# ── Validate required vars ────────────────────────────────────────────────────
: "${STORJ_ACCESS_KEY:?Add STORJ_ACCESS_KEY to .env}"
: "${STORJ_SECRET_KEY:?Add STORJ_SECRET_KEY to .env}"
: "${STORJ_ENDPOINT:?Add STORJ_ENDPOINT to .env}"
: "${STORJ_BUCKET:?Add STORJ_BUCKET to .env}"
BACKUP_RETAIN_DAYS="${BACKUP_RETAIN_DAYS:-0 1 7 30}"
BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-*-*-* 03:00:00}"
LVM_SNAP_SIZE="${LVM_SNAP_SIZE:-5G}"
LV_PATH="/dev/mariusz-vg/appdata"

echo "══════════════════════════════════════════════"
echo "  appdata backup setup"
echo "══════════════════════════════════════════════"
echo "  LV:       $LV_PATH"
echo "  Bucket:   $RCLONE_REMOTE:$STORJ_BUCKET"
echo "  Retain:   ${BACKUP_RETAIN_DAYS} days ago"
echo "  Schedule: $BACKUP_SCHEDULE"
echo "  Snap COW: $LVM_SNAP_SIZE"
echo "══════════════════════════════════════════════"
echo

# ── 1. Install rclone ─────────────────────────────────────────────────────────
echo "[1/6] rclone"
if command -v rclone &>/dev/null; then
    echo "      already installed: $(rclone --version | head -1)"
else
    echo "      installing..."
    curl -fsSL https://rclone.org/install.sh | sudo bash -s -- --quiet
    echo "      installed: $(rclone --version | head -1)"
fi

# ── 2. Configure Storj remote ─────────────────────────────────────────────────
echo "[2/6] rclone Storj remote"
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
echo "      configured remote '$RCLONE_REMOTE'"

# ── 3. Test connection + ensure bucket exists ─────────────────────────────────
echo "[3/6] Storj connection"
if sudo rclone lsd "$RCLONE_REMOTE:" --config "$RCLONE_CONFIG" 2>/dev/null | grep -q "$STORJ_BUCKET"; then
    echo "      bucket '$STORJ_BUCKET' exists"
else
    echo "      creating bucket '$STORJ_BUCKET'..."
    sudo rclone mkdir "$RCLONE_REMOTE:$STORJ_BUCKET" --config "$RCLONE_CONFIG"
    echo "      created"
fi

# ── 4. Write conf file ────────────────────────────────────────────────────────
echo "[4/6] config file → $CONF_FILE"
sudo tee "$CONF_FILE" > /dev/null <<EOF
RCLONE_REMOTE=$RCLONE_REMOTE
RCLONE_CONFIG=$RCLONE_CONFIG
STORJ_BUCKET=$STORJ_BUCKET
LV_PATH=$LV_PATH
LVM_SNAP_SIZE=$LVM_SNAP_SIZE
BACKUP_RETAIN_DAYS="$BACKUP_RETAIN_DAYS"
EOF
sudo chmod 640 "$CONF_FILE"
echo "      written"

# ── 5. Install backup script ──────────────────────────────────────────────────
echo "[5/6] backup script → $BACKUP_SCRIPT_DST"
sudo cp "$BACKUP_SCRIPT_SRC" "$BACKUP_SCRIPT_DST"
sudo chmod +x "$BACKUP_SCRIPT_DST"
echo "      installed"

# ── 6. systemd service + timer ────────────────────────────────────────────────
echo "[6/6] systemd timer"

sudo tee /etc/systemd/system/backup-appdata.service > /dev/null <<EOF
[Unit]
Description=Backup appdata LVM snapshot to Storj
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$CONF_FILE
ExecStart=$BACKUP_SCRIPT_DST
StandardOutput=journal
StandardError=journal
EOF

sudo tee /etc/systemd/system/backup-appdata.timer > /dev/null <<EOF
[Unit]
Description=Appdata backup timer

[Timer]
OnCalendar=$BACKUP_SCHEDULE
Persistent=true

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now backup-appdata.timer
echo "      enabled — $(sudo systemctl is-active backup-appdata.timer)"

echo
echo "══════════════════════════════════════════════"
echo "  Setup complete!"
echo "  Run now:      bash backup/setup.sh --now"
echo "  Timer status: systemctl list-timers backup-appdata"
echo "  Logs:         journalctl -u backup-appdata"
echo "══════════════════════════════════════════════"

if $RUN_NOW; then
    echo
    echo "  Running backup now..."
    echo "══════════════════════════════════════════════"
    sudo "$BACKUP_SCRIPT_DST"
fi
