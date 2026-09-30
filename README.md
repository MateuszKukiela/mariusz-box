# mariusz-box

Home server: a Debian VM on Hyper-V (GPU-P for NVENC/CUDA), with the ZFS pool
`mariusz` at `/mariusz` and appdata on its own LVM volume. Everything runs as
one compose project from `~/mariusz-box`, fronted by Caddy with Cloudflare
DNS-01 certificates.

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
  immich.yml          immich stack       (profile: immich, off)
caddy/Caddyfile       every public hostname
sure/                 initializer mounted into Sure
backup/               nightly LVM snapshot of appdata to Storj
gpu/                  GPU-P CUDA setup and driver-update scripts
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
| `filebrowser.` | File Browser |
| `sonarr.`, `radarr.`, `prowlarr.`, `bazarr.`, `profilarr.`, `lingarr.` | the *arrs |
| `qbittorrent.`, `sabnzbd.` | download clients |
| `metube.` | MeTube (basic auth) |
| `search.` | SearXNG (basic auth) |
| `st.` | SillyTavern |
| `chat.` | Open WebUI |
| `sure.` | Sure |
| `portainer.` | Portainer |
| `uptime.`, `czymariuszlezy.` | Uptime Kuma, and its public status page |
| `paperless.`, `photos.` | Paperless, Immich (both off) |

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

Paperless and Immich only start when their profile is named:

```bash
docker compose --profile paperless up -d
```

Watchtower updates running containers to their latest image on its own.

## Adding a service

1. Put it in the `compose/` file for its stack, on `mariusz-network`, with
   config under `${ROOT_APPDATA}/<name>`.
2. Add a Caddy block with `import tls_cf` if it needs a hostname.
3. Add any new variable to `.env.sample`, and pass containers only the
   variables they read. `env_file: .env` hands them every secret.
