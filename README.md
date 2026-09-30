# mariusz-box

Home server: bare-metal Omarchy (Arch) with an RTX 3070. Media lives on the
ZFS pool `mariusz` (3×14 TB) at `/mariusz`; appdata, metadata and Docker's
storage live on a 1 TB NVMe at `/srv/mariusz-box`, and `~/mariusz-box` links to
the repo there. Everything runs as one compose project, fronted by Caddy with
Cloudflare DNS-01 certificates.

SSH: `ssh mateusz@192.168.8.10` on the LAN (port 22), or
`ssh -p 2052 mateusz@ssh.januszex.net` from outside.

## Layout

```
docker-compose.yml    includes every file under compose/
compose/
  infra.yml           caddy, cloudflare-ddns, portainer, uptime-kuma, watchtower
  media.yml           jellyfin, jellyseerr, streamyfin, comicstreamer, stash, filebrowser
  arr.yml             sonarr, radarr, prowlarr, bazarr, profilarr, decluttarr,
                      idiotarr, lingarr (+db), whisper-asr
  downloads.yml       qbittorrent, sabnzbd, metube, debilarr
  sure.yml            sure, sure-worker, sure-db, sure-redis
  apps.yml            searxng, sillytavern, openwebui
  paperless.yml       paperless stack    (profile: paperless, off)
  immich.yml          immich (server, ML, Postgres, Valkey)
caddy/Caddyfile       every public hostname
sure/                 initializer mounted into Sure
backup/               nightly archive of all state to Storj
host/                 OS setup: ZFS, SMART, NVIDIA runtime, SSH, Docker ordering
docs/                 one-off procedures
.env.sample           every variable the stack reads
```

## Hostnames

All `*.januszex.net` names CNAME to the apex, so a new Caddy site needs no DNS
record. Only the apex and `ssh.` are A records, kept current by cloudflare-ddns.

| Host | Service |
|---|---|
| `januszex.net`, `jellyfin.` | Jellyfin |
| `jellyseerr.`, `requests.` | Jellyseerr |
| `streamyfin.` | Streamyfin optimized-versions server |
| `comicstreamer.` | ComicStreamer |
| `stash.` | Stash |
| `filebrowser.` | File Browser (login) |
| `sonarr.`, `radarr.`, `prowlarr.`, `bazarr.`, `profilarr.`, `lingarr.` | the *arrs |
| `qbittorrent.`, `sabnzbd.` | download clients |
| `metube.` | MeTube (login) |
| `search.` | SearXNG (login) |
| `auth.` | tinyauth login page for the "(login)" sites |
| `st.` | SillyTavern |
| `chat.` | Open WebUI |
| `sure.` | Sure |
| `portainer.` | Portainer (login) |
| `uptime.`, `czymariuszlezy.` | Uptime Kuma, and its public status page |
| `photos.` | Immich |
| `paperless.` | Paperless (off) |

Internal only: decluttarr, idiotarr (Prowlarr's indexer proxy), debilarr,
whisper-asr (Bazarr's Whisper provider), the databases, watchtower.

## Running it

```bash
cd ~/mariusz-box
git pull
docker compose up -d
```

Caddy reads the whole `caddy/` directory, so a Caddyfile change only needs a
reload:

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Paperless only starts when its profile is named:

```bash
docker compose --profile paperless up -d
```

Watchtower pulls new images and recreates running containers every night at
04:00. It copies the old container's labels, so the next manual
`docker compose up -d` restarts whatever it updated once; that restart changes
nothing. `docker compose up -d --dry-run` shows what would be recreated.

## Adding a service

1. Put it in the `compose/` file for its stack, on `mariusz-network`, with
   config under `${ROOT_APPDATA}/<name>`.
2. Add a Caddy block with `import tls_cf` if it needs a hostname.
3. Add any new variable to `.env.sample`, and pass containers only the
   variables they read. `env_file: .env` hands them every secret.
4. Pin databases to a major version (`postgres:16`, `mariadb:13`), or
   watchtower will upgrade their data directories unattended.
