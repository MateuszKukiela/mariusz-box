# GPU

The box runs on bare metal with an RTX 3070 and the distro's NVIDIA driver.
Containers reach it through the NVIDIA Container Toolkit, which registers an
`nvidia` Docker runtime:

```bash
sudo pacman -S nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker   # adds "runtimes.nvidia" to /etc/docker/daemon.json
sudo systemctl restart docker
```

Check it from a throwaway container:

```bash
docker run --rm --runtime=nvidia -e NVIDIA_VISIBLE_DEVICES=all ubuntu:24.04 nvidia-smi
```

Services that use it:

| Service | How | For |
|---|---|---|
| jellyfin | `runtime: nvidia`, capabilities `compute,video,utility` | NVENC/NVDEC transcoding |
| whisper-asr | `runtime: nvidia`, capabilities `compute,utility` | CUDA Whisper for Bazarr |
| stash | `runtime: nvidia` + a GPU reservation | hardware-accelerated previews |
| immich (off) | `runtime: nvidia` + a GPU reservation | CUDA machine learning |

`video` in `NVIDIA_DRIVER_CAPABILITIES` is what mounts the NVENC libraries; without
it Jellyfin falls back to software encoding. In Jellyfin, Dashboard > Playback >
Transcoding stays on NVIDIA NVENC.

A driver update needs no change here: the toolkit mounts whatever driver the
host runs. Restart the GPU containers after rebooting into a new driver.
