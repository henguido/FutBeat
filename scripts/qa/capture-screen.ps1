param(
    [string]$AdbPath,
    [string]$DeviceId,
    [string]$OutputDir = (Join-Path (Get-Location) 'artifacts\qa\screenshots'),
    [string]$Name = 'screen'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'android-smoke.lib.ps1')
$resolvedAdb = Resolve-AdbPath -AdbPath $AdbPath
$devicesResult = Invoke-AdbText -AdbPath $resolvedAdb -Arguments @('devices', '-l')
$device = Resolve-AdbDevice -Devices @(ConvertFrom-AdbDevices -Lines $devicesResult.Output) -DeviceId $DeviceId
[void](New-Item -ItemType Directory -Force -Path $OutputDir)
$safeName = $Name -replace '[^A-Za-z0-9_.-]', '-'
$path = Join-Path ([System.IO.Path]::GetFullPath($OutputDir)) "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$safeName.png"
Invoke-AdbBinary -AdbPath $resolvedAdb -DeviceId $device.Id -Arguments @('exec-out', 'screencap', '-p') -OutputPath $path
if ((Get-Item -LiteralPath $path).Length -eq 0) { throw 'ADB generó una captura vacía.' }
Write-Output $path
