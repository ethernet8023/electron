# Records what kind of machine/filesystem stack the benchmark ran on.
param([string]$out = "bench/probe.md")
$ErrorActionPreference = 'Continue'
function Section($t) { Add-Content $out "`n### $t`n"; Add-Content $out '```' }
function EndSection { Add-Content $out '```' }
Section "host"
Add-Content $out ("workspace: " + $env:GITHUB_WORKSPACE)
Add-Content $out ("cpus: " + [Environment]::ProcessorCount)
Add-Content $out ((Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, TotalVisibleMemorySize, FreePhysicalMemory) | Format-List | Out-String)
Add-Content $out ("user: " + [Security.Principal.WindowsIdentity]::GetCurrent().Name)
Add-Content $out ("in container: " + (Test-Path Env:CONTAINER_SANDBOX_MOUNT_POINT))
EndSection
Section "volumes"
Add-Content $out (Get-PSDrive -PSProvider FileSystem | Format-Table Name, @{n='UsedGB';e={[math]::Round($_.Used/1GB,1)}}, @{n='FreeGB';e={[math]::Round($_.Free/1GB,1)}}, Root | Out-String)
$drive = (Get-Item $env:GITHUB_WORKSPACE).PSDrive.Name + ":"
Add-Content $out ((Get-Volume | Where-Object DriveLetter | Format-Table DriveLetter, FileSystemType, DriveType, @{n='SizeGB';e={[math]::Round($_.Size/1GB)}}, @{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB)}} | Out-String))
Add-Content $out (fsutil fsinfo volumeinfo $drive 2>&1 | Out-String)
Add-Content $out (fsutil 8dot3name query $drive 2>&1 | Out-String)
Add-Content $out ("global 8dot3 setting: " + (fsutil 8dot3name query 2>&1 | Out-String))
Add-Content $out ("workspace volume as seen from inside: " + (fsutil fsinfo volumeinfo $drive 2>&1 | Select-String 'File System Name|Volume Name' | Out-String))
EndSection
Section "filter drivers (fltmc) - bindflt/wcifs = container bind-mount layer"
Add-Content $out (fltmc filters 2>&1 | Out-String)
Add-Content $out (fltmc instances -v $drive 2>&1 | Out-String)
EndSection
Section "defender"
try { Add-Content $out (Get-MpComputerStatus | Select-Object AMServiceEnabled, RealTimeProtectionEnabled, AntivirusEnabled | Format-List | Out-String) } catch { Add-Content $out ("Get-MpComputerStatus failed: " + $_) }
Add-Content $out ((Get-Service -Name WinDefend, MsMpEng -ErrorAction SilentlyContinue | Format-Table Name, Status | Out-String))
EndSection
Section "tools"
Add-Content $out (& "$env:SystemRoot\System32\tar.exe" --version 2>&1 | Out-String)
Add-Content $out (zstd --version 2>&1 | Out-String)
Add-Content $out ("msys tar: " + (bash -lc 'tar --version | head -1' 2>&1 | Out-String))
foreach ($c in @('7z', 'C:\Program Files\7-Zip\7z.exe')) { if (Get-Command $c -ErrorAction SilentlyContinue) { Add-Content $out ("7z: " + $c + " " + ((& $c 2>&1 | Select-Object -First 2) -join ' ')) } }
foreach ($c in @('python3', 'python', 'py')) { $cmd = Get-Command $c -ErrorAction SilentlyContinue; if ($cmd) { Add-Content $out ("$c -> " + $cmd.Source + " : " + ((& $c --version 2>&1) -join ' ')) } else { Add-Content $out ("$c: not found") } }
Add-Content $out ("bash python3: " + (bash -c 'command -v python3 python; true' 2>&1 | Out-String))
EndSection
Section "vhd mount capability (VHDX-based cache idea)"
try { Add-Content $out ((Get-Service -Name vds, vhdmp -ErrorAction SilentlyContinue | Format-Table Name, Status | Out-String)); Add-Content $out ((Get-Command Mount-DiskImage -ErrorAction Stop).Name) } catch { Add-Content $out ("Mount-DiskImage unavailable: " + $_) }
Add-Content $out (fsutil devdrv query 2>&1 | Out-String)
EndSection
Get-Content $out
