# Creates a dynamically expanding VHDX on whichever fixed NTFS volume has the
# most free space, formats it as a ReFS Dev Drive (falling back to plain ReFS
# where the OS has no Dev Drive support), marks it trusted so Defender uses its
# performance mode on it, and exports:
#   REFS_ROOT  - a directory on the new volume (Windows path)
#   REFS_KIND  - "ReFS Dev Drive" or "ReFS"
# Everything here needs the virtual disk / storage stack, which a plain
# container does not have, so callers should expect this to fail there and
# treat that as a result in its own right.
$ErrorActionPreference = 'Stop'

$vol = Get-Volume |
  Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.FileSystemType -eq 'NTFS' } |
  Sort-Object SizeRemaining -Descending | Select-Object -First 1
if (-not $vol) { throw 'no fixed NTFS volume found to host the VHDX' }
$freeGB = [math]::Floor($vol.SizeRemaining / 1GB)
$sizeGB = [math]::Min(256, $freeGB - 20)
if ($sizeGB -lt 60) { throw "only ${freeGB} GB free on $($vol.DriveLetter): - need ~60 GB for the extraction runs" }

$vhdx = "$($vol.DriveLetter):\extract-bench.vhdx"
Write-Host "host volume $($vol.DriveLetter): has ${freeGB} GB free; creating ${sizeGB} GB expandable VHDX at $vhdx"
if (Test-Path $vhdx) {
  Dismount-DiskImage -ImagePath $vhdx -ErrorAction SilentlyContinue | Out-Null
  Remove-Item $vhdx -Force
}

# diskpart can create a VHDX without the Hyper-V PowerShell module; the
# Storage module can then mount, partition and format it.
$script = Join-Path $env:RUNNER_TEMP 'extract-bench-vhdx.txt'
"create vdisk file=`"$vhdx`" maximum=$($sizeGB * 1024) type=expandable" | Out-File -Encoding ascii $script
diskpart /s $script | Write-Host
if ($LASTEXITCODE -ne 0) { throw "diskpart exited with $LASTEXITCODE" }

Mount-DiskImage -ImagePath $vhdx | Out-Null
$disk = Get-DiskImage -ImagePath $vhdx | Get-Disk
$disk | Initialize-Disk -PartitionStyle GPT
$part = $disk | New-Partition -UseMaximumSize -AssignDriveLetter
$letter = $part.DriveLetter
try {
  Format-Volume -DriveLetter $letter -DevDrive -NewFileSystemLabel bench -Confirm:$false -Force | Out-Null
  $kind = 'ReFS Dev Drive'
} catch {
  Write-Host "Format-Volume -DevDrive failed ($($_.Exception.Message)); formatting as plain ReFS"
  Format-Volume -DriveLetter $letter -FileSystem ReFS -NewFileSystemLabel bench -Confirm:$false -Force | Out-Null
  $kind = 'ReFS'
}
# Trusted dev drives get Defender's asynchronous "performance mode". Best effort.
fsutil devdrv trust "${letter}:" 2>&1 | Write-Host
fsutil devdrv query "${letter}:" 2>&1 | Write-Host
$global:LASTEXITCODE = 0

Get-Volume -DriveLetter $letter | Format-List DriveLetter, FileSystemType, Size, SizeRemaining | Out-String | Write-Host
New-Item -ItemType Directory -Path "${letter}:\bench" | Out-Null
Write-Host "$kind mounted at ${letter}:"
"REFS_ROOT=${letter}:\bench" | Out-File -Append -Encoding utf8 $env:GITHUB_ENV
"REFS_KIND=$kind" | Out-File -Append -Encoding utf8 $env:GITHUB_ENV
