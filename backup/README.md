# appdata backup

LVM snapshot of `/dev/mariusz-vg/appdata` streamed as a tar.gz to Storj. No local files kept.

## Retention

Keeps the closest backup to each of these ages:
- today
- yesterday
- 1 week ago
- 1 month ago

Configurable via `BACKUP_RETAIN_DAYS` (space-separated days-ago values, e.g. `0 1 7 30`).

## .env variables

Add these to `/home/mariusz/mariusz-box/.env`:

```
STORJ_ACCESS_KEY=<access key>
STORJ_SECRET_KEY=<secret key>
STORJ_ENDPOINT=https://gateway.storjshare.io
STORJ_BUCKET=appdata
BACKUP_RETAIN_DAYS=0 1 7 30
BACKUP_SCHEDULE=*-*-* 03:00:00
LVM_SNAP_SIZE=5G
```

## Setup

```bash
cd /home/mariusz/mariusz-box
git pull
bash backup/setup.sh
```

Installs rclone, configures the Storj remote, creates a systemd timer. Safe to re-run (idempotent).

## Run a backup now

```bash
sudo backup-appdata
```

## Setup + run immediately

```bash
bash backup/setup.sh --now
```

## Useful commands

```bash
# Check when next backup runs
systemctl list-timers backup-appdata

# Watch backup logs live
journalctl -fu backup-appdata

# List backups on Storj
sudo rclone lsf storj-backup:mariusz-appdata-backups
```
