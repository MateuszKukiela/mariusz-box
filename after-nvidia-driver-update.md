# After NVIDIA Driver Update on Windows Host

Run these on your Mac to copy new driver libs to the Debian VM.

## 1. Copy WSL libs from Windows to Mac

Open PowerShell on Windows and SCP the files to Mac:

```powershell
scp -r "C:\Windows\System32\lxss\lib" mateuszkukiela@<mac-ip>:/tmp/wsl_lib
scp -r "C:\Program Files\WSL\lib\*" mateuszkukiela@<mac-ip>:/tmp/wsl_lib/
```

## 2. Copy libs from Mac to Debian VM

```bash
scp -P 2052 -r /tmp/wsl_lib/* mariusz@192.168.8.10:/tmp/wsl_lib_new/
```

## 3. On Debian VM — replace the libs

```bash
ssh -p 2052 mariusz@192.168.8.10
```

```bash
sudo cp /tmp/wsl_lib_new/* /usr/lib/wsl/lib/
sudo cp /tmp/wsl_lib_new/* /usr/lib/wsl/drivers/  # if any updated there too
sudo ldconfig
```

## 4. Fix the libnvidia-ml.so.1 symlink

The driver folder name may change with new driver version. Find the new folder:

```bash
ls /usr/lib/wsl/drivers/
```

Then recreate the symlink (replace folder name):

```bash
sudo ln -sf /usr/lib/wsl/lib/libnvidia-ml.so.1 \
  '/usr/lib/wsl/drivers/<new_folder_name>/libnvidia-ml.so.1'
```

## 5. Verify

```bash
nvidia-smi
```

Should show GPU info with the new driver version.

## 6. Restart Docker containers (if nvidia-smi was broken)

```bash
cd /home/mariusz/mariusz-box
docker compose restart jellyfin
```

---

**Note:** GPU-P assignment in Hyper-V and dxgkrnl kernel module do NOT need to be redone.
