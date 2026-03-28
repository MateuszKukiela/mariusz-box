# NVIDIA CUDA / NVENC in Hyper-V GPU-P Linux VM

Getting CUDA and NVENC hardware transcoding working on a standard Hyper-V Linux VM
using GPU Paravirtualization (GPU-P). This is NOT WSL2 — it's a full Debian VM.

## Why this is hard

GPU-P normally only exposes DirectX/Direct3D to the VM. CUDA officially only works in
WSL2 via a special Microsoft/NVIDIA kernel integration. However, it IS possible to get
CUDA working in a regular Hyper-V VM by replicating the WSL2 driver stack manually.

---

## Prerequisites

- Windows 11 host with Hyper-V
- NVIDIA GPU (tested with RTX 3070)
- GPU-P configured on the VM (dxgkrnl loaded, /dev/dxg exists)
- WSL2 installed on the Windows host (needed to get the right driver libs)
- `staralt/dxgkrnl-dkms` installed in the Linux VM

---

## Step 1 — Verify GPU-P compute is allocated

On Windows PowerShell:

```powershell
Get-VMGpuPartitionAdapter -VMName "YourVM" | Select-Object CurrentPartitionCompute, CurrentPartitionEncode, CurrentPartitionDecode
```

If `CurrentPartitionCompute` is 0, shut down the VM and re-add the GPU adapter:

```powershell
$vm = "YourVM"
Remove-VMGpuPartitionAdapter -VMName $vm
Add-VMGpuPartitionAdapter -VMName $vm
Set-VMGpuPartitionAdapter -VMName $vm `
  -MinPartitionVRAM 1 -MaxPartitionVRAM 1200000000 -OptimalPartitionVRAM 1200000000 `
  -MinPartitionEncode 0 -MaxPartitionEncode 18446744073709551615 -OptimalPartitionEncode 18446744073709551615 `
  -MinPartitionDecode 0 -MaxPartitionDecode 1000000000 -OptimalPartitionDecode 1000000000 `
  -MinPartitionCompute 0 -MaxPartitionCompute 1000000000 -OptimalPartitionCompute 1000000000
Set-VM -VMName $vm -GuestControlledCacheTypes $true -LowMemoryMappedIoSpace 1Gb -HighMemoryMappedIoSpace 32Gb
```

Start the VM and verify `CurrentPartitionCompute` is now 1000000000.

---

## Step 2 — Copy WSL libs to the VM

On Windows PowerShell, SCP these two directories to the Linux VM:

```powershell
scp -P 2052 -r "C:\Windows\System32\lxss\lib" mariusz@192.168.8.10:/tmp/wsl_lxss/
scp -P 2052 -r "C:\Program Files\WSL\lib" mariusz@192.168.8.10:/tmp/wsl_lib/
```

On the Linux VM:

```bash
sudo mkdir -p /usr/lib/wsl/lib
sudo cp /tmp/wsl_lxss/* /usr/lib/wsl/lib/
sudo cp /tmp/wsl_lib/* /usr/lib/wsl/lib/
sudo chmod -R 755 /usr/lib/wsl/lib/
sudo chown -R root:root /usr/lib/wsl/lib/
```

Create ldconfig entry:

```bash
echo "/usr/lib/wsl/lib" | sudo tee /etc/ld.so.conf.d/ld.wsl.conf
sudo ldconfig
```

---

## Step 3 — Copy the NVIDIA DriverStore folder to the VM

This is the critical step that most guides miss. The WSL2 CUDA stub (`libcuda.so.1`)
looks for the actual NVIDIA driver in a specific DriverStore path. Without it, cuInit
returns `CUDA_ERROR_NO_DEVICE`.

Find the driver folder name on Windows:

```powershell
ls "C:\Windows\System32\DriverStore\FileRepository\" | Where-Object { $_.Name -like "nv_dispi*" }
```

Copy the entire folder to the VM (replace the folder name with yours):

```powershell
scp -P 2052 -r "C:\Windows\System32\DriverStore\FileRepository\nv_dispi.inf_amd64_4bf4c17fa8a478b5" mariusz@192.168.8.10:/home/mariusz/wsl_drivers_new/
```

On the Linux VM, symlink it into the wsl drivers path:

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

Expected output: `cuInit: 0` (0 = CUDA_SUCCESS)

---

## Step 5 — Configure Docker / Jellyfin

In `docker-compose.yml`, add to the Jellyfin service:

```yaml
environment:
    - LD_LIBRARY_PATH=/usr/lib/wsl/lib

volumes:
    - /usr/lib/wsl/lib:/usr/lib/wsl/lib:ro
    - /home/mariusz/wsl_drivers_new/nv_dispi.inf_amd64_4bf4c17fa8a478b5:/usr/lib/wsl/drivers/nv_dispi.inf_amd64_4bf4c17fa8a478b5:ro

devices:
    - /dev/dri:/dev/dri
    - /dev/dxg:/dev/dxg
```

**Do NOT use the NVIDIA device reservation** (`deploy.resources.reservations.devices: nvidia`).
It triggers the NVIDIA Container Toolkit which detects a WSL environment and fails.
Manual mounts are sufficient.

---

## Step 6 — Verify CUDA and NVENC in the container

```bash
# Test CUDA
docker exec jellyfin sh -c \
  'LD_LIBRARY_PATH=/usr/lib/wsl/lib /usr/lib/jellyfin-ffmpeg/ffmpeg \
   -init_hw_device cuda=cu:0 -f lavfi -i nullsrc -frames:v 1 -f null - 2>&1 | tail -3'

# Test NVENC
docker exec jellyfin sh -c \
  'LD_LIBRARY_PATH=/usr/lib/wsl/lib /usr/lib/jellyfin-ffmpeg/ffmpeg \
   -init_hw_device cuda=cu:0 -f lavfi -i nullsrc=s=1280x720 -frames:v 1 -c:v h264_nvenc -f null - 2>&1 | tail -3'
```

Both should complete without errors. NVENC output will show `encoder: Lavc h264_nvenc`.

---

## Step 7 — Configure Jellyfin

In Jellyfin Dashboard → Playback → Transcoding:
- Hardware acceleration: **NVIDIA NVENC**
- Enable hardware encoding checked

---

## After updating NVIDIA drivers on Windows host

See `after-nvidia-driver-update.md` — you'll need to re-copy the WSL libs and
recreate the DriverStore symlink with the new folder name.

---

## How it works

The WSL2 CUDA stub (`libcuda.so.1`, ~183KB) in `/usr/lib/wsl/lib/` communicates
with the GPU via `/dev/dxg` (the dxgkrnl kernel module). When cuInit is called, the
stub looks for the real NVIDIA driver at:

```
/usr/lib/wsl/drivers/<nv_dispi_folder>/libcuda.so.1.1
```

This is the actual NVIDIA CUDA driver from Windows' DriverStore. Without it, cuInit
fails with `CUDA_ERROR_NO_DEVICE` even though the GPU and dxgkrnl are working fine.
Once found, the stub delegates all CUDA operations to the Windows GPU driver via
the VMBus `/dev/dxg` interface.
