# NVIDIA CUDA / NVENC in Hyper-V GPU-P Linux VM

Getting CUDA and NVENC hardware transcoding working on a standard Hyper-V Linux VM
using GPU Paravirtualization (GPU-P). This is NOT WSL2 — it's a full Debian VM.

## Why this is hard

GPU-P normally only exposes DirectX/Direct3D to the VM. CUDA officially only works in
WSL2 via a special Microsoft/NVIDIA kernel integration. However, it IS possible to get
CUDA working in a regular Hyper-V VM by replicating the WSL2 driver stack manually.

The key insight: the WSL2 CUDA stub library (`libcuda.so.1`) communicates with the GPU
via `/dev/dxg` (provided by the `dxgkrnl` kernel module). It then looks for the actual
NVIDIA CUDA driver in a specific path under `/usr/lib/wsl/drivers/`. Most guides only
tell you to copy `lxss\lib` and `WSL\lib` from Windows — but without the DriverStore
folder, `cuInit` silently returns `CUDA_ERROR_NO_DEVICE` and nothing works.

---

## Tested configuration

- Windows 11 host
- NVIDIA GeForce RTX 3070
- Debian 13 (Trixie), kernel 6.12.74+deb13+1-amd64
- dxgkrnl 2.0.3 from `staralt/dxgkrnl-dkms`
- Docker + linuxserver/jellyfin

---

## Prerequisites

Before starting, you need:

1. **Hyper-V GPU-P already configured** — the VM must boot and `dxgkrnl` must be loaded:
   ```bash
   lsmod | grep dxgkrnl   # should show dxgkrnl
   ls /dev/dxg            # should exist
   ```

2. **dxgkrnl-dkms installed** in the VM:
   ```bash
   curl -fsSL https://content.staralt.dev/dxgkrnl-dkms/main/install.sh | sudo bash -es
   ```

3. **WSL2 installed on the Windows host** — this is required because the NVIDIA driver
   files in `C:\Windows\System32\lxss\lib` and `C:\Program Files\WSL\lib` only appear
   after WSL2 is set up. Install via PowerShell:
   ```powershell
   wsl --install
   ```

4. **SSH access to the VM** from Windows (for SCP transfers).

---

## Step 1 — Verify GPU-P partition has compute allocated

The VM's GPU partition must have compute resources allocated, not just encode/decode.
Check in PowerShell while the VM is running:

```powershell
Get-VMGpuPartitionAdapter -VMName "YourVM" | Select-Object CurrentPartitionVRAM, CurrentPartitionEncode, CurrentPartitionDecode, CurrentPartitionCompute
```

You need `CurrentPartitionCompute` to be **1000000000** (not 0). If it's 0:

**Shut down the VM completely** (not sleep/pause), then in PowerShell:

```powershell
$vm = "YourVM"
Remove-VMGpuPartitionAdapter -VMName $vm
Add-VMGpuPartitionAdapter -VMName $vm
Set-VMGpuPartitionAdapter -VMName $vm `
  -MinPartitionVRAM 1 `
  -MaxPartitionVRAM 1200000000 `
  -OptimalPartitionVRAM 1200000000 `
  -MinPartitionEncode 0 `
  -MaxPartitionEncode 18446744073709551615 `
  -OptimalPartitionEncode 18446744073709551615 `
  -MinPartitionDecode 0 `
  -MaxPartitionDecode 1000000000 `
  -OptimalPartitionDecode 1000000000 `
  -MinPartitionCompute 0 `
  -MaxPartitionCompute 1000000000 `
  -OptimalPartitionCompute 1000000000
Set-VM -VMName $vm -GuestControlledCacheTypes $true -LowMemoryMappedIoSpace 1Gb -HighMemoryMappedIoSpace 32Gb
```

Start the VM, then verify `CurrentPartitionCompute` is now 1000000000.

---

## Step 2 — Copy WSL CUDA libraries from Windows to the VM

These are the CUDA stub libraries that WSL2 uses. They communicate with the GPU via
`/dev/dxg`. On Windows PowerShell:

```powershell
# Replace port, user, and IP with your VM's SSH details
scp -P 2052 -r "C:\Windows\System32\lxss\lib\*" mariusz@192.168.8.10:/tmp/wsl_lxss/
scp -P 2052 -r "C:\Program Files\WSL\lib\*" mariusz@192.168.8.10:/tmp/wsl_lib/
```

On the Linux VM, merge both into `/usr/lib/wsl/lib/`:

```bash
sudo mkdir -p /usr/lib/wsl/lib
sudo cp /tmp/wsl_lxss/* /usr/lib/wsl/lib/
sudo cp /tmp/wsl_lib/* /usr/lib/wsl/lib/
sudo chown -R root:root /usr/lib/wsl/lib/
sudo chmod -R 755 /usr/lib/wsl/lib/
```

Add to ldconfig so the libs are found system-wide:

```bash
echo "/usr/lib/wsl/lib" | sudo tee /etc/ld.so.conf.d/ld.wsl.conf
sudo ldconfig
```

Verify the key files exist:

```bash
ls /usr/lib/wsl/lib/libcuda.so.1    # ~183KB stub
ls /usr/lib/wsl/lib/libdxcore.so    # DX core
ls /usr/lib/wsl/lib/libnvidia-encode.so.1  # NVENC
```

---

## Step 3 — Copy the NVIDIA DriverStore folder (the critical missing step)

The CUDA stub (`libcuda.so.1`) looks for the actual NVIDIA driver at this path:
```
/usr/lib/wsl/drivers/<nv_dispi_folder_name>/libcuda.so.1.1
```

Without this, `cuInit` returns 100 (`CUDA_ERROR_NO_DEVICE`) even though everything
else looks fine.

**Find the DriverStore folder name on Windows:**

```powershell
ls "C:\Windows\System32\DriverStore\FileRepository\" | Where-Object { $_.Name -like "nv_dispi*" }
```

You'll see something like `nv_dispi.inf_amd64_4bf4c17fa8a478b5`. Note the exact name.

**Copy the entire folder to the VM** (~2.6GB):

```powershell
scp -P 2052 -r "C:\Windows\System32\DriverStore\FileRepository\nv_dispi.inf_amd64_4bf4c17fa8a478b5" mariusz@192.168.8.10:/home/mariusz/wsl_drivers_new/
```

**On the Linux VM**, symlink it into the expected location:

```bash
sudo mkdir -p /usr/lib/wsl/drivers
sudo ln -sf /home/mariusz/wsl_drivers_new/nv_dispi.inf_amd64_4bf4c17fa8a478b5 \
  /usr/lib/wsl/drivers/nv_dispi.inf_amd64_4bf4c17fa8a478b5
```

---

## Step 4 — Verify CUDA works on the host

```bash
LD_LIBRARY_PATH=/usr/lib/wsl/lib python3 -c \
  'import ctypes; lib=ctypes.CDLL("/usr/lib/wsl/lib/libcuda.so.1"); print("cuInit:", lib.cuInit(0))'
```

Expected: `cuInit: 0`

- `0` = CUDA_SUCCESS ✅
- `100` = CUDA_ERROR_NO_DEVICE — DriverStore folder missing or wrong path
- `500` = DriverStore folder found but other libs missing — check the folder was fully copied

Also verify nvidia-smi works (though CUDA Version may still show ERR — that's cosmetic):

```bash
LD_LIBRARY_PATH=/usr/lib/wsl/lib /usr/lib/wsl/lib/nvidia-smi
```

---

## Step 5 — Configure Docker for Jellyfin

In `docker-compose.yml`, the Jellyfin service needs these additions.

**Environment:**
```yaml
environment:
    - LD_LIBRARY_PATH=/usr/lib/wsl/lib
    - NVIDIA_DRIVER_CAPABILITIES=compute,video,utility
    - NVIDIA_VISIBLE_DEVICES=all
```

**Volumes** (add alongside existing config volume):
```yaml
volumes:
    - /usr/lib/wsl/lib:/usr/lib/wsl/lib:ro
    - /home/mariusz/wsl_drivers_new/nv_dispi.inf_amd64_4bf4c17fa8a478b5:/usr/lib/wsl/drivers/nv_dispi.inf_amd64_4bf4c17fa8a478b5:ro
```

**Devices:**
```yaml
devices:
    - /dev/dri:/dev/dri
    - /dev/dxg:/dev/dxg
```

> ⚠️ **Do NOT add** `deploy.resources.reservations.devices` with `driver: nvidia`.
> The NVIDIA Container Toolkit detects the dxg environment as WSL and fails with:
> `nvidia-container-cli: initialization error: WSL environment detected but no adapters were found`
> Manual volume mounts are sufficient — the toolkit is not needed.

---

## Step 6 — Verify CUDA and NVENC in the container

```bash
# Test CUDA init
docker exec jellyfin sh -c \
  'LD_LIBRARY_PATH=/usr/lib/wsl/lib /usr/lib/jellyfin-ffmpeg/ffmpeg \
   -init_hw_device cuda=cu:0 -f lavfi -i nullsrc -frames:v 1 -f null - 2>&1 | tail -3'

# Test NVENC encoding
docker exec jellyfin sh -c \
  'LD_LIBRARY_PATH=/usr/lib/wsl/lib /usr/lib/jellyfin-ffmpeg/ffmpeg \
   -init_hw_device cuda=cu:0 -f lavfi -i nullsrc=s=1280x720 \
   -frames:v 1 -c:v h264_nvenc -f null - 2>&1 | tail -3'
```

CUDA test success: no errors, clean exit.
NVENC test success: output includes `encoder: Lavc... h264_nvenc`.

---

## Step 7 — Configure Jellyfin transcoding

In Jellyfin web UI:
**Dashboard → Playback → Transcoding**
- Hardware acceleration: **NVIDIA NVENC**
- Enable hardware encoding: **checked**
- Save and restart Jellyfin if needed

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `cuInit: 100` (CUDA_ERROR_NO_DEVICE) | DriverStore folder missing | Step 3 |
| `cuInit: 500` | DriverStore folder found but partially copied | Re-copy DriverStore folder |
| `cu->cuInit(0) failed` in ffmpeg | `LD_LIBRARY_PATH` not set in container | Add env var to docker-compose |
| `WSL environment detected but no adapters` | NVIDIA Container Toolkit interfering | Remove `deploy.resources.reservations.devices: nvidia` |
| `CurrentPartitionCompute: 0` | Compute not allocated in GPU-P partition | Step 1 — re-add GPU adapter |
| `CUDA Version: ERR!` in nvidia-smi | Cosmetic only in GPU-P — CUDA can still work | Ignore |

---

## After updating NVIDIA drivers on Windows host

The DriverStore folder name changes with each driver version. After updating:

1. Find the new folder name: `ls "C:\Windows\System32\DriverStore\FileRepository\" | Where-Object { $_.Name -like "nv_dispi*" }`
2. SCP the new folder to the VM
3. Update the symlink in `/usr/lib/wsl/drivers/`
4. Re-copy WSL libs from `lxss\lib` and `WSL\lib`
5. Run `sudo ldconfig`
6. Recreate the Jellyfin container with the updated volume path in docker-compose

See `after-nvidia-driver-update.md` for the full procedure.

---

## How it works (technical)

```
Jellyfin ffmpeg
    → loads /usr/lib/wsl/lib/libcuda.so.1 (183KB stub, via LD_LIBRARY_PATH)
    → stub opens /dev/dxg (dxgkrnl kernel module ↔ Hyper-V VMBus ↔ Windows GPU driver)
    → stub loads /usr/lib/wsl/drivers/nv_dispi_.../libcuda.so.1.1 (real NVIDIA driver)
    → cuInit() succeeds, CUDA context created
    → NVENC encoder initialized via CUDA context
    → hardware transcoding works
```

The `dxgkrnl` module is a Linux port of the DirectX kernel driver. It creates `/dev/dxg`
which acts as a bridge to the actual Windows WDDM GPU driver running on the host. All
GPU compute and encode operations ultimately execute on the Windows side via this bridge.
