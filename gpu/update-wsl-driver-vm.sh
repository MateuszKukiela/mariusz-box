#!/usr/bin/env bash
# Fix 2 (part B) — swap the refreshed WSL GPU driver libs into place on the VM,
# then recreate the GPU containers. Run ON THE DEBIAN VM after
# update-wsl-driver.ps1 has uploaded to /tmp/wsl_new and /tmp/driverstore_new.
#
#   bash ~/mariusz-box/gpu/update-wsl-driver-vm.sh
#
# Keeps the existing DriverStore folder name so the compose mounts and
# the /usr/lib/wsl/drivers symlink stay valid (contents refreshed in place).

set -euo pipefail

WSL_LIB=/usr/lib/wsl/lib
DRIVERSTORE=/home/mariusz/wsl_drivers_new/nv_dispi.inf_amd64_4bf4c17fa8a478b5
SRC_LIB=/tmp/wsl_new
SRC_DRV=/tmp/driverstore_new
COMPOSE_DIR=/home/mariusz/mariusz-box

[ -d "$SRC_LIB" ] || { echo "Missing $SRC_LIB — run update-wsl-driver.ps1 on the host first"; exit 1; }
[ "$(ls -A "$SRC_DRV" 2>/dev/null)" ] || { echo "Missing/empty $SRC_DRV"; exit 1; }

echo "=== 1. Backup current libs ==="
sudo rm -rf "${WSL_LIB}.bak" "${DRIVERSTORE}.bak" 2>/dev/null || true
sudo cp -a "$WSL_LIB" "${WSL_LIB}.bak"
sudo cp -a "$DRIVERSTORE" "${DRIVERSTORE}.bak"

echo "=== 2. Replace WSL user-mode libs ==="
sudo cp -f "$SRC_LIB"/* "$WSL_LIB"/
sudo chown -R root:root "$WSL_LIB"
sudo chmod -R 755 "$WSL_LIB"

echo "=== 3. Replace DriverStore contents (folder name unchanged) ==="
sudo cp -rf "$SRC_DRV"/* "$DRIVERSTORE"/
sudo chown -R mariusz:mariusz "$DRIVERSTORE"

echo "=== 4. Fix libnvidia-ml.so.1 symlink into DriverStore ==="
sudo ln -sf "$WSL_LIB/libnvidia-ml.so.1" "$DRIVERSTORE/libnvidia-ml.so.1"

echo "=== 5. Ensure /usr/lib/wsl/drivers symlink + ldconfig ==="
sudo mkdir -p /usr/lib/wsl/drivers
sudo ln -sfn "$DRIVERSTORE" "/usr/lib/wsl/drivers/nv_dispi.inf_amd64_4bf4c17fa8a478b5"
echo "$WSL_LIB" | sudo tee /etc/ld.so.conf.d/ld.wsl.conf >/dev/null
sudo ldconfig

echo "=== 6. Host CUDA sanity (expect cuInit: 0) ==="
LD_LIBRARY_PATH="$WSL_LIB" python3 - <<'PY' || true
import ctypes
l = ctypes.CDLL("/usr/lib/wsl/lib/libcuda.so.1")
print("cuInit:", l.cuInit(0))
PY

echo "=== 7. Recreate GPU containers ==="
cd "$COMPOSE_DIR"
docker compose up -d --force-recreate jellyfin whisper-asr

echo "=== 8. In-container CUDA check (expect cuInit: 0) ==="
sleep 6
docker exec whisper-asr sh -c 'LD_LIBRARY_PATH=/usr/lib/wsl/lib python3 -c "import ctypes; l=ctypes.CDLL(\"/usr/lib/wsl/lib/libcuda.so.1\"); print(\"whisper cuInit:\", l.cuInit(0))"' || true

echo "Done. cuInit 0 = GPU working. cuInit 100 = compute partition still 0 (fix HAGS + host reboot)."