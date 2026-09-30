# Host setup

Everything the stack needs from the OS, on bare-metal Omarchy (Arch). The files
next to this README are the live copies; the paths below say where each goes.

## Disks

| Disk | Holds | Mounted |
|---|---|---|
| Samsung 980 1 TB (LUKS, btrfs) | the OS | `/` |
| KIOXIA EXCERIA G2 1 TB (btrfs) | appdata, metadata, the repo, Docker and containerd storage | `/srv/mariusz-box`, bind-mounted to `/var/lib/docker` and `/var/lib/containerd` |
| 3× 14 TB Exos, ZFS raidz1 pool `mariusz` | media, downloads, photos, MeTube, Stash blobs, `archive/` | `/mariusz` |

The fstab entries for the KIOXIA and its two bind mounts use `nofail`, and
Docker `RequiresMountsFor` all three, so a missing NVMe keeps Docker down.

The KIOXIA is btrfs so backups can snapshot it without stopping anything
(`backup/README.md`). appdata, metadata and the repo sit in the top-level
subvolume, so one snapshot captures them together; everything that shouldn't be
in that snapshot is its own subvolume:

| Subvolume | Why separate |
|---|---|
| `docker`, `containerd` | image layers don't belong in backups; `docker` is snapshotted on its own for the volumes |
| `backup-staging` | tonight's archive shouldn't be pinned by tonight's snapshot |
| `.snapshots` | where the snapshots go |

```
UUID=<uuid>  /srv/mariusz-box  btrfs  noatime,compress=zstd:1,nofail,x-systemd.device-timeout=10s  0 0
/srv/mariusz-box/docker      /var/lib/docker      none  bind,nofail,x-systemd.requires-mounts-for=/srv/mariusz-box  0 0
/srv/mariusz-box/containerd  /var/lib/containerd  none  bind,nofail,x-systemd.requires-mounts-for=/srv/mariusz-box  0 0
```

## ZFS

`zfs-dkms` and `zfs-utils` come from the AUR (`yay -S zfs-dkms zfs-utils`).

```bash
sudo zgenhostid -f "$(hostid)"                         # pin the hostid; otherwise it follows the IP
sudo zpool set cachefile=/etc/zfs/zpool.cache mariusz
sudo systemctl enable --now zfs-import-cache zfs-mount zfs.target zfs-zed
sudo systemctl enable --now zfs-scrub-weekly@mariusz.timer
```

- **ARC** is capped at 16 GiB (`modprobe-zfs.conf` → `/etc/modprobe.d/zfs.conf`).
  The default lets it take almost all 62 GB, which starves the containers and the
  desktop. Change it live with
  `echo $((16<<30)) | sudo tee /sys/module/zfs/parameters/zfs_arc_max`.
- **Dataset properties** (set once, kept in the pool): `compression=lz4`,
  `atime=off`, `recordsize=1M`, `xattr=sa`, `dnodesize=auto`.
- **Scrub** runs weekly (Monday ~00:20). `zpool status mariusz` shows progress.
- **Kernel updates.** zfs-dkms only builds for the kernels its release supports
  (`Linux-Maximum` in `/usr/src/zfs-*/META`). `zfs-kernel-guard` (→
  `/usr/local/bin/`) and `00-zfs-kernel-guard.hook` (→ `/etc/pacman.d/hooks/`)
  make pacman refuse a `linux-omarchy` newer than that. When it fires, update
  ZFS first (`yay -S zfs-dkms zfs-utils`), or `sudo touch
  /etc/zfs/allow-kernel-upgrade` to let one upgrade through.
- The pool's features are not all enabled. Leave `zpool upgrade` alone unless a
  feature is needed; it stops older ZFS (a rescue USB, say) from importing it.

## Docker

`docker-50-mariusz-box.conf` → `/etc/systemd/system/docker.service.d/`. Docker
waits for the pool and the KIOXIA, and does not start at all unless `/mariusz`
is mounted, so containers never write into an empty `/mariusz` on the OS disk.

GPU: the NVIDIA container toolkit registers an `nvidia` runtime.

```bash
sudo pacman -S nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
docker run --rm --runtime=nvidia -e NVIDIA_VISIBLE_DEVICES=all ubuntu:24.04 nvidia-smi
```

Jellyfin (NVENC, capabilities `compute,video,utility`) and whisper-asr (CUDA)
use `runtime: nvidia`; stash and Immich add a GPU reservation. Without `video`
in `NVIDIA_DRIVER_CAPABILITIES` Jellyfin falls back to software encoding. A
driver update needs nothing here; restart the GPU containers after rebooting
into it.

## SMART

`smartd.conf` → `/etc/smartd.conf`, then `sudo systemctl enable --now smartd`.
All disks are monitored, with a short self-test every Sunday 03:00, a long one
on the 1st at 04:00, and warnings above 45 °C. Results land in
`journalctl -u smartd`.

## SSH and firewall

The drop-ins in `sshd/` → `/etc/ssh/sshd_config.d/`:

- `20-ports.conf`: sshd listens on 22 (LAN) and 2052 (the router forwards it
  for `ssh.januszex.net`).
- `99-wan-keys-only.conf`: passwords only from the LAN (`192.168.8.0/24`,
  localhost, the LAN's IPv6 ranges); everything else is keys only. Connecting
  through `ssh.januszex.net` from home counts as WAN, because the router's
  hairpin NAT makes it arrive from the public IP.
- `10-no-per-source-penalties.conf`: no per-IP penalties after failed logins.

Check a change with `sudo sshd -t`, and see what a given source gets with
`sudo sshd -T -C user=mateusz,host=x,addr=8.8.8.8 | grep -i passwordauth`.

ufw allows both ports without rate limiting:

```bash
sudo ufw allow 22/tcp
sudo ufw allow 2052/tcp
```
