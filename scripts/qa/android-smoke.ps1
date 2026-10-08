param(
    [Parameter(Mandatory)][string]$ApkPath,
    [string]$AdbPath,
    [string]$DeviceId,
    [string]$OutputDir,
    [switch]$SkipInstall,
    [switch]$SkipScreenshots,
    [switch]$TestAds,
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'android-smoke.lib.ps1')

$package = 'com.futbeat.futbeat'
$activity = 'com.futbeat.futbeat/.MainActivity'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $OutputDir) { $OutputDir = Join-Path $repoRoot "artifacts\qa\$timestamp" }
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
$screensDir = Join-Path $OutputDir 'screenshots'
$logcatPath = Join-Path $OutputDir 'logcat.txt'
$reportPath = Join-Path $OutputDir 'REPORT.md'
$warnings = [System.Collections.Generic.List[string]]::new()
$screenshots = [System.Collections.Generic.List[string]]::new()
$deepLinks = [System.Collections.Generic.List[object]]::new()

function Write-Detail([string]$Message) { if ($Verbose) { Write-Host "[detalle] $Message" -ForegroundColor DarkGray } }
function Get-Prop([string]$Name) {
    $result = Invoke-AdbText -AdbPath $resolvedAdb -DeviceId $selectedDevice.Id -Arguments @('shell', 'getprop', $Name) -AllowFailure
    if ($result.ExitCode -ne 0 -or $result.Output.Count -eq 0) { return 'No disponible' }
    $value = ($result.Output -join '').Trim()
    if ($value) { return $value }
    return 'No disponible'
}
function Get-AppPid {
    $result = Invoke-AdbText -AdbPath $resolvedAdb -DeviceId $selectedDevice.Id -Arguments @('shell', 'pidof', '-s', $package) -AllowFailure
    if ($result.ExitCode -ne 0) { return $null }
    $value = ($result.Output -join '').Trim()
    if ($value -match '^\d+$') { return $value }
    return $null
}
function Save-Screen([string]$Name) {
    if ($SkipScreenshots) { return }
    [void](New-Item -ItemType Directory -Force -Path $screensDir)
    $path = Join-Path $screensDir "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$Name.png"
    Invoke-AdbBinary -AdbPath $resolvedAdb -DeviceId $selectedDevice.Id -Arguments @('exec-out', 'screencap', '-p') -OutputPath $path
    if ((Get-Item -LiteralPath $path).Length -eq 0) { throw "La captura '$Name' quedó vacía." }
    $screenshots.Add($path)
}
function Start-FutBeat([string]$Label) {
    $result = Invoke-AdbText -AdbPath $resolvedAdb -DeviceId $selectedDevice.Id -Arguments @('shell', 'am', 'start', '-W', '-n', $activity) -AllowFailure
    if ($result.ExitCode -ne 0 -or ($result.Output -join "`n") -match '(?i)error:|exception') { return 'FAIL' }
    Start-Sleep -Seconds 3
    $firstPid = Get-AppPid
    if (-not $firstPid) { return 'FAIL: proceso ausente' }
    Start-Sleep -Seconds 2
    if (-not (Get-AppPid)) { return 'FAIL: proceso desapareció' }
    Write-Detail "$Label activo con PID $firstPid"
    return 'PASS'
}

[void](New-Item -ItemType Directory -Force -Path $OutputDir)
$data = @{
    Result = 'FAIL'; ApkPath = $ApkPath; Sha256 = 'No calculado'; Package = $package
    VersionName = 'No disponible'; VersionCode = 'No disponible'; InstallResult = 'No ejecutada'
    InstallDuration = 'No disponible'; Manufacturer = 'No disponible'; Model = 'No disponible'
    AndroidVersion = 'No disponible'; ApiLevel = 'No disponible'; Resolution = 'No disponible'
    Density = 'No disponible'; Locale = 'No disponible'; TimeZone = 'No disponible'
    LaunchResult = 'No ejecutado'; RelaunchResult = 'No ejecutado'; CrashCount = 0
    AdsQaMode = $(if ($TestAds) { 'TEST' } else { 'NORMAL' })
    AdConfigurationExpected = $(if ($TestAds) { 'enabled' } else { 'not asserted (fail-closed allowed)' })
    AdsArtifactVerification = $(if ($TestAds) { 'Pendiente' } else { 'No requerida' })
    DeepLinks = $deepLinks; Screenshots = $screenshots; LogcatPath = $logcatPath; Warnings = $warnings
}

try {
    $ApkPath = [System.IO.Path]::GetFullPath($ApkPath)
    if (-not (Test-Path -LiteralPath $ApkPath -PathType Leaf)) { throw "El APK no existe: '$ApkPath'." }
    $data.ApkPath = $ApkPath
    $data.Sha256 = Get-FileSha256 -Path $ApkPath
    if ($TestAds) {
        [void](Assert-QaAdsTestArtifact -ApkPath $ApkPath)
        $data.AdsArtifactVerification = 'PASS (marca de build y SHA-256 coinciden)'
    }
    $resolvedAdb = Resolve-AdbPath -AdbPath $AdbPath
    Write-Detail "ADB: $resolvedAdb"

    $deviceLines = (Invoke-AdbText -AdbPath $resolvedAdb -Arguments @('devices', '-l')).Output
    $selectedDevice = Resolve-AdbDevice -Devices @(ConvertFrom-AdbDevices -Lines $deviceLines) -DeviceId $DeviceId
    Write-Host "Dispositivo: $($selectedDevice.Id)"

    $sdkRoot = Split-Path (Split-Path $resolvedAdb -Parent) -Parent
    $buildToolsRoot = Join-Path $sdkRoot 'build-tools'
    $aapt = $null
    if (Test-Path -LiteralPath $buildToolsRoot) {
        $aapt = Get-ChildItem -LiteralPath $buildToolsRoot -Directory | Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'aapt.exe' } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
    if (-not $aapt) { throw 'No se encontró aapt.exe en Android SDK build-tools; no se puede verificar con seguridad el package del APK.' }
    $badging = @(& $aapt dump badging $ApkPath 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) { throw "aapt no pudo leer el APK: $($badging -join ' ')" }
    $packageLine = $badging | Where-Object { $_ -match '^package:' } | Select-Object -First 1
    if ($packageLine -notmatch "name='$([regex]::Escape($package))'") { throw "El APK no pertenece a $package. Detalle: $packageLine" }
    if ($packageLine -match "versionName='([^']+)'" ) { $data.VersionName = $Matches[1] }
    if ($packageLine -match "versionCode='([^']+)'" ) { $data.VersionCode = $Matches[1] }

    $data.Manufacturer = Get-Prop 'ro.product.manufacturer'
    $data.Model = Get-Prop 'ro.product.model'
    $data.AndroidVersion = Get-Prop 'ro.build.version.release'
    $data.ApiLevel = Get-Prop 'ro.build.version.sdk'
    $data.Locale = Get-Prop 'persist.sys.locale'
    $data.TimeZone = Get-Prop 'persist.sys.timezone'
    $sizeResult = Invoke-AdbText -AdbPath $resolvedAdb -DeviceId $selectedDevice.Id -Arguments @('shell', 'wm', 'size') -AllowFailure
    $densityResult = Invoke-AdbText -AdbPath $resolvedAdb -DeviceId $selectedDevice.Id -Arguments @('shell', 'wm', 'density') -AllowFailure
    $data.Resolution = (($sizeResult.Output | Select-Object -Last 1) -replace '^.*?:\s*', '').Trim()
    $data.Density = (($densityResult.Output | Select-Object -Last 1) -replace '^.*?:\s*', '').Trim()

    $df = Invoke-AdbText -AdbPath $resolvedAdb -DeviceId $selectedDevice.Id -Arguments @('shell', 'df', '-k', '/data') -AllowFailure
    if ($df.ExitCode -eq 0 -and $df.Output.Count -ge 2) {
        $columns = @($df.Output[-1] -split '\s+' | Where-Object { $_ })
        if ($columns.Count -ge 4 -and $columns[3] -match '^\d+$') {
            $availableBytes = [int64]$columns[3] * 1KB
            if ($availableBytes -lt ((Get-Item -LiteralPath $ApkPath).Length * 2)) { throw 'El dispositivo no parece tener espacio suficiente para instalar el APK.' }
        } else { $warnings.Add('No se pudo interpretar el espacio disponible de /data.') }
    } else { $warnings.Add('ADB no pudo verificar el espacio disponible de /data.') }

    if ($SkipInstall) {
        $data.InstallResult = 'SKIPPED'
    } else {
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $install = Invoke-AdbText -AdbPath $resolvedAdb -DeviceId $selectedDevice.Id -Arguments @('install', '-r', $ApkPath) -AllowFailure
        $timer.Stop()
        $data.InstallDuration = ('{0:n1}s' -f $timer.Elapsed.TotalSeconds)
        if ($install.ExitCode -ne 0 -or ($install.Output -join "`n") -notmatch '(?m)^Success\s*$') { throw "Falló adb install -r: $($install.Output -join ' ')" }
        $data.InstallResult = 'PASS'
    }

    $pathCheck = Invoke-AdbText -AdbPath $resolvedAdb -DeviceId $selectedDevice.Id -Arguments @('shell', 'pm', 'path', $package) -AllowFailure
    if ($pathCheck.ExitCode -ne 0 -or ($pathCheck.Output -join '') -notmatch '^package:') { throw "El package $package no está instalado." }
    $packageDump = Invoke-AdbText -AdbPath $resolvedAdb -DeviceId $selectedDevice.Id -Arguments @('shell', 'dumpsys', 'package', $package) -AllowFailure
    $dumpText = $packageDump.Output -join "`n"
    if ($dumpText -match '(?m)versionName=([^\s]+)') { $data.VersionName = $Matches[1] }
    if ($dumpText -match '(?m)versionCode=(\d+)') { $data.VersionCode = $Matches[1] }

    [void](Invoke-AdbText -AdbPath $resolvedAdb -DeviceId $selectedDevice.Id -Arguments @('logcat', '-c'))
    [void](Invoke-AdbText -AdbPath $resolvedAdb -DeviceId $selectedDevice.Id -Arguments @('shell', 'am', 'force-stop', $package))
    $data.LaunchResult = Start-FutBeat 'Primer arranque'
    if ($data.LaunchResult -ne 'PASS') { throw "El primer arranque falló: $($data.LaunchResult)" }
    Save-Screen 'launch'
    [void](Invoke-AdbText -AdbPath $resolvedAdb -DeviceId $selectedDevice.Id -Arguments @('shell', 'am', 'force-stop', $package))
    $data.RelaunchResult = Start-FutBeat 'Segundo arranque'
    if ($data.RelaunchResult -ne 'PASS') { throw "El segundo arranque falló: $($data.RelaunchResult)" }

    $safeLinks = @(
        @{ Name = 'App Link reset sin token'; Uri = 'https://futbeat.com/auth/reset' },
        @{ Name = 'Fallback reset sin token'; Uri = 'com.futbeat.futbeat://password-reset' }
    )
    foreach ($link in $safeLinks) {
        $result = Invoke-AdbText -AdbPath $resolvedAdb -DeviceId $selectedDevice.Id -Arguments (Get-AdbDeepLinkArguments -Uri $link.Uri -Package $package) -AllowFailure
        Start-Sleep -Seconds 2
        $ok = $result.ExitCode -eq 0 -and ($result.Output -join "`n") -notmatch '(?i)error:|exception' -and (Get-AppPid)
        $deepLinks.Add([pscustomobject]@{ Name = $link.Name; Result = $(if ($ok) { 'PASS' } else { 'FAIL' }) })
        if (-not $ok) { throw "Falló el deep link seguro: $($link.Name)." }
        Save-Screen (($link.Name -replace '[^A-Za-z0-9]', '-').ToLowerInvariant())
    }

    $rawLog = (Invoke-AdbText -AdbPath $resolvedAdb -DeviceId $selectedDevice.Id -Arguments @('logcat', '-d', '-v', 'threadtime')).Output -join "`n"
    $filtered = ($rawLog -split "`r?`n" | Where-Object { $_ -match 'com\.futbeat\.futbeat|AndroidRuntime|FATAL EXCEPTION|flutter|Supabase|Firebase' }) -join "`n"
    $sanitized = Protect-QaLog -Text $filtered
    Set-Content -LiteralPath $logcatPath -Value $sanitized -Encoding utf8
    $fatalMatches = [regex]::Matches(
        $sanitized,
        '(?ims)FATAL EXCEPTION.{0,1200}Process:\s*com\.futbeat\.futbeat|Process:\s*com\.futbeat\.futbeat.*has died|Fatal signal[^\r\n]*com\.futbeat\.futbeat'
    )
    $data.CrashCount = $fatalMatches.Count
    if ($data.CrashCount -gt 0) { throw "Logcat contiene $($data.CrashCount) indicio(s) de crash." }
    if ($sanitized -match '(?im)FATAL EXCEPTION' -and $data.CrashCount -eq 0) { $warnings.Add('Logcat contiene un FATAL EXCEPTION no atribuido a FutBeat.') }
    if ($sanitized -match '(?im)\bE/(flutter|AndroidRuntime)') { $warnings.Add('Logcat contiene errores no fatales; revisar logcat.txt.') }
    $data.Result = $(if ($warnings.Count -gt 0) { 'PASS_WITH_WARNINGS' } else { 'PASS' })
}
catch {
    $warnings.Add($_.Exception.Message)
    $data.Result = 'FAIL'
    Write-Error $_.Exception.Message -ErrorAction Continue
}
finally {
    $data.DeepLinks = @($deepLinks)
    $data.Screenshots = @($screenshots)
    $data.Warnings = @($warnings)
    Set-Content -LiteralPath $reportPath -Value (New-QaReport -Data $data) -Encoding utf8
    Write-Host "Reporte: $reportPath"
}

if ($data.Result -eq 'FAIL') { exit 1 }
Write-Host "Resultado: $($data.Result)" -ForegroundColor Green
