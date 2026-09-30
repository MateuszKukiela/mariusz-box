# Fix Hyper-V GPU-P compute partition for VM "Mariusz"
# Run on the Windows host in an ELEVATED PowerShell (Run as Administrator).
# Recovers CUDA/NVENC in the VM (jellyfin transcode + whisper-asr).

$vm = "Mariusz"

# --- 1. Check current compute allocation (VM can be running) ---
Write-Host "Current compute:" -ForegroundColor Cyan
Get-VMGpuPartitionAdapter -VMName $vm | Select-Object CurrentPartitionCompute | Out-Host

# If CurrentPartitionCompute is 1000000000 the compute partition is fine -> stop here.
# If it is 0, continue to re-provision below.

# --- 2. Shut VM down fully (not save/pause) ---
Stop-VM -Name $vm

# --- 3. Re-add the GPU partition adapter ---
Remove-VMGpuPartitionAdapter -VMName $vm
Add-VMGpuPartitionAdapter -VMName $vm

# --- 4. Set partition resources (compute included) ---
Set-VMGpuPartitionAdapter -VMName $vm -MinPartitionVRAM 1 -MaxPartitionVRAM 1200000000 -OptimalPartitionVRAM 1200000000 -MinPartitionEncode 0 -MaxPartitionEncode 18446744073709551615 -OptimalPartitionEncode 18446744073709551615 -MinPartitionDecode 0 -MaxPartitionDecode 1000000000 -OptimalPartitionDecode 1000000000 -MinPartitionCompute 0 -MaxPartitionCompute 1000000000 -OptimalPartitionCompute 1000000000

# --- 5. MMIO space for the GPU ---
Set-VM -VMName $vm -GuestControlledCacheTypes $true -LowMemoryMappedIoSpace 1Gb -HighMemoryMappedIoSpace 32Gb

# --- 6. Start VM ---
Start-VM -Name $vm

# --- 7. Verify compute is now allocated ---
Start-Sleep -Seconds 5
Write-Host "New compute (expect 1000000000):" -ForegroundColor Green
Get-VMGpuPartitionAdapter -VMName $vm | Select-Object CurrentPartitionCompute | Out-Host

Write-Host ""
Read-Host "Done. Press Enter to close"