# Backups

Every night at 05:00 (after watchtower's 04:00 run) `mariusz-backup` writes one
archive of everything the box needs and uploads it to Storj.

1. The running compose services are stopped, so every database is consistent.
2. `mariusz-box-<timestamp>.tar.zst` is written to `/srv/mariusz-box/backup-staging`.
3. The same services are started again. They are down for a couple of minutes.
4. The archive goes to Storj, and the remote size is checked against the local one.
5. The previous local archive is deleted, so the newest one stays on the KIOXIA
   for a restore without a download.
6. Old backups are pruned.

A failure anywhere still starts the services again, and the run shows as failed
in `systemctl status mariusz-backup`.

## What's in it

Every path is stored relative to `/`, with numeric owners, ACLs and xattrs.

| Path | What |
|---|---|
| `/srv/mariusz-box/appdata` | every service's config and database |
| `/srv/mariusz-box/metadata` | Jellyfin's database, plugins and artwork; *arr backups (caches left out) |
| `/srv/mariusz-box/mariusz-box` | this repo, with `.env` |
| `/var/lib/docker/volumes` | named volumes such as Paperless's database (Immich's model cache left out) |
| `/mariusz/data/media/photos`, `/mariusz/ssd` | photos and Stash blobs from the pool |
| `/etc`, `/usr/local`, `/root`, `/home/mateusz/.ssh` | host config: ufw, sshd, Docker, ZFS, smartd, the backup itself |

The rest of the pool (media, downloads) isn't backed up. Change the lists with
`BACKUP_PATHS` / `BACKUP_EXCLUDES` in `.env` (see `backup.sh` for the defaults).

## Retention

Keeps the backup closest to each of these ages: today, yesterday, 1 week ago,
1 month ago (`BACKUP_RETAIN_DAYS`, default `0 1 7 30`). The old VM's
`appdata-*.tar.gz` backups take part in the same rotation and age out on their
own.

## Setup

Add to `.env`:

```
STORJ_ACCESS_KEY=<access key>
STORJ_SECRET_KEY=<secret key>
STORJ_ENDPOINT=https://gateway.storjshare.io
STORJ_BUCKET=appdata
BACKUP_RETAIN_DAYS="0 1 7 30"
BACKUP_SCHEDULE="*-*-* 05:00:00"
# Optional: an Uptime Kuma push monitor's URL, pinged up/down after every run
BACKUP_PUSH_URL=https://uptime.januszex.net/api/push/<token>
```

Then install, or refresh after a `git pull` (safe to re-run):

```bash
bash backup/setup.sh          # add --now to also start a backup
```

It installs rclone, writes the Storj remote to `/root/.config/rclone/rclone.conf`,
the settings to `/etc/mariusz-backup.conf`, the script to
`/usr/local/bin/mariusz-backup`, and enables `mariusz-backup.timer`.

## Restore

```bash
# newest local copy, or pull one from Storj
ls /srv/mariusz-box/backup-staging
sudo rclone --config /root/.config/rclone/rclone.conf lsf storj-backup:appdata
sudo rclone --config /root/.config/rclone/rclone.conf copy storj-backup:appdata/<file> .

cd ~/mariusz-box && docker compose down
# everything:
sudo tar --numeric-owner -I zstd -xpf <file> -C /
# or one service:
sudo tar --numeric-owner -I zstd -xpf <file> -C / srv/mariusz-box/appdata/radarr
docker compose up -d
```

Unpack `etc/` into a scratch directory rather than over a different OS install.

## Useful commands

```bash
systemctl list-timers mariusz-backup     # next run
sudo systemctl start mariusz-backup      # run now
journalctl -u mariusz-backup -f          # watch a run
```
