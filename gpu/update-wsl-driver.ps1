# Fix 2 (part A) — refresh WSL GPU driver libs in the Debian VM after a
# Windows-host NVIDIA driver update. Run on the WINDOWS HOST in PowerShell.
#
# It auto-detects the new nv_dispi DriverStore folder, then SCPs the WSL
# user-mode libs + the DriverStore contents to the VM. Afterwards run
# update-wsl-driver-vm.sh ON THE VM to swap them in and recreate containers.

$ErrorActionPreference = "Stop"

# --- VM SSH target. Local LAN for the big/fast copy (host -> VM directly).
#     Swap to "mariusz@ssh.januszex.net" / 2052 if the LAN address differs. ---
$VM   = "mariusz@192.168.8.10"
$PORT = 2052

# --- 1. Find the new NVIDIA DriverStore folder ---
$repo = "C:\Windows\System32\DriverStore\FileRepository"
$folder = Get-ChildItem $repo | Where-Object { $_.Name -like "nv_dispi*" } |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $folder) { throw "No nv_dispi* folder found in $repo" }
Write-Host "DriverStore folder: $($folder.Name)" -ForegroundColor Cyan
Write-Host "  (record this name — pass it to the VM script)" -ForegroundColor Yellow

# --- 2. Copy WSL user-mode libs (stub libcuda, dxcore, nvidia-ml, nvenc, etc) ---
Write-Host "Copying WSL libs -> VM:/tmp/wsl_new/ ..." -ForegroundColor Cyan
ssh -p $PORT $VM "rm -rf /tmp/wsl_new /tmp/driverstore_new && mkdir -p /tmp/wsl_new /tmp/driverstore_new"
scp -P $PORT -r "C:\Windows\System32\lxss\lib\*"  "${VM}:/tmp/wsl_new/"
scp -P $PORT -r "C:\Program Files\WSL\lib\*"       "${VM}:/tmp/wsl_new/"

# --- 3. Copy the DriverStore folder contents (the real driver, ~2.6GB) ---
Write-Host "Copying DriverStore contents -> VM:/tmp/driverstore_new/ (large, be patient) ..." -ForegroundColor Cyan
scp -P $PORT -r "$repo\$($folder.Name)\*" "${VM}:/tmp/driverstore_new/"

Write-Host ""
Write-Host "Upload done." -ForegroundColor Green
Write-Host "Now run on the VM:  bash ~/mariusz-box/gpu/update-wsl-driver-vm.sh" -ForegroundColor Green
Read-Host "Press Enter to close"