# Clear Media Libraries (Clean Slate)

Removes all movies/series/requests from Radarr, Sonarr, and Jellyseerr.
Keeps all settings, quality profiles, API keys, users, plugins intact.
Does NOT delete any files.

**Do NOT touch Jellyfin** — messing with its databases causes migration failures when the container image version differs from the backup. Jellyfin will show empty libraries naturally once Radarr/Sonarr are cleared.

## 1. Radarr — delete all movies

```bash
RADARR_KEY=f95239f6c555493a8de66f8108f31e4f
IDS=$(curl -s -H "X-Api-Key: $RADARR_KEY" http://localhost:7878/api/v3/movie | python3 -c 'import sys,json; ids=[m["id"] for m in json.load(sys.stdin)]; print(json.dumps(ids))')
echo "Found $(echo $IDS | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))') movies"
curl -s -X DELETE -H "X-Api-Key: $RADARR_KEY" -H 'Content-Type: application/json' \
  http://localhost:7878/api/v3/movie/editor \
  -d "{\"movieIds\": $IDS, \"deleteFiles\": false}"
```

## 2. Sonarr — delete all series

```bash
SONARR_KEY=a55f5371fde044639270b32080ebdd98
IDS=$(curl -s -H "X-Api-Key: $SONARR_KEY" http://localhost:8989/api/v3/series | python3 -c 'import sys,json; ids=[s["id"] for s in json.load(sys.stdin)]; print(json.dumps(ids))')
echo "Found $(echo $IDS | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))') series"
curl -s -X DELETE -H "X-Api-Key: $SONARR_KEY" -H 'Content-Type: application/json' \
  http://localhost:8989/api/v3/series/editor \
  -d "{\"seriesIds\": $IDS, \"deleteFiles\": false}"
```

## 3. Jellyseerr — delete all requests

```bash
SEERR_KEY=$(python3 -c "import json; d=json.load(open('/home/mariusz/appdata/jellyseerr/settings.json')); print(d['main']['apiKey'])")
TOTAL=$(curl -s -H "X-Api-Key: $SEERR_KEY" 'http://localhost:5055/api/v1/request?take=1&skip=0' | python3 -c 'import sys,json; print(json.load(sys.stdin)["pageInfo"]["results"])')
echo "Found $TOTAL requests"
curl -s -H "X-Api-Key: $SEERR_KEY" "http://localhost:5055/api/v1/request?take=$TOTAL&skip=0" \
  | python3 -c 'import sys,json; [print(r["id"]) for r in json.load(sys.stdin)["results"]]' \
  | while read id; do
    curl -s -X DELETE -H "X-Api-Key: $SEERR_KEY" "http://localhost:5055/api/v1/request/$id" > /dev/null
  done
echo done
```

## 4. Jellyfin

Do nothing. Jellyfin will show empty libraries since there are no files on disk. Content will be picked up automatically when files appear and a library scan runs.
