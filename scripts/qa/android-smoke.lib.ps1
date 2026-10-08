Set-StrictMode -Version Latest

$script:FutBeatPackage = 'com.futbeat.futbeat'
$script:FutBeatActivity = 'com.futbeat.futbeat/.MainActivity'

function ConvertFrom-AdbDevices {
    param([Parameter(Mandatory)][string[]]$Lines)
    $devices = @()
    foreach ($line in $Lines) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed -match '^List of devices attached' -or $trimmed -match '^\* daemon') { continue }
        if ($trimmed -match '^(?<Id>\S+)\s+(?<State>\S+)(?<Details>.*)$') {
            $devices += [pscustomobject]@{ Id = $Matches.Id; State = $Matches.State; Details = $Matches.Details.Trim() }
        }
    }
    return @($devices)
}

function Resolve-AdbDevice {
    param([Parameter(Mandatory)][object[]]$Devices, [string]$DeviceId)
    if ($DeviceId) {
        $selected = @($Devices | Where-Object { $_.Id -eq $DeviceId })
        if ($selected.Count -eq 0) { throw "No se encontró el dispositivo '$DeviceId'." }
        if ($selected[0].State -ne 'device') { throw "El dispositivo '$DeviceId' está en estado '$($selected[0].State)'; desbloquéalo y autoriza ADB." }
        return $selected[0]
    }
    if ($Devices.Count -eq 0) { throw 'No hay dispositivos Android conectados por ADB.' }
    $ready = @($Devices | Where-Object { $_.State -eq 'device' })
    if ($Devices.Count -eq 1 -and $ready.Count -eq 0) { throw "El dispositivo está en estado '$($Devices[0].State)'; desbloquéalo y autoriza ADB." }
    if ($ready.Count -ne 1 -or $Devices.Count -ne 1) { throw 'Hay varios dispositivos o destinos ADB. Usa -DeviceId con el identificador exacto.' }
    return $ready[0]
}

function Resolve-AdbPath {
    param([string]$AdbPath)
    if ($AdbPath) {
        $candidate = [System.IO.Path]::GetFullPath($AdbPath)
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw "ADB no existe en '$candidate'." }
        return $candidate
    }
    $candidate = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    $command = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw 'No se encontró adb.exe. Instala Android SDK Platform-Tools o usa -AdbPath.'
}

function Invoke-AdbText {
    param([Parameter(Mandatory)][string]$AdbPath, [string]$DeviceId, [Parameter(Mandatory)][string[]]$Arguments, [switch]$AllowFailure)
    $allArguments = @()
    if ($DeviceId) { $allArguments += @('-s', $DeviceId) }
    $allArguments += $Arguments
    $output = @(& $AdbPath @allArguments 2>&1 | ForEach-Object { "$_" })
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) { throw "ADB falló ($exitCode): adb $($allArguments -join ' ')`n$($output -join "`n")" }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = @($output) }
}

function Invoke-AdbBinary {
    param([Parameter(Mandatory)][string]$AdbPath, [Parameter(Mandatory)][string]$DeviceId, [Parameter(Mandatory)][string[]]$Arguments, [Parameter(Mandatory)][string]$OutputPath)
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $AdbPath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $quotedArguments = @('-s', $DeviceId) + $Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }
    $startInfo.Arguments = $quotedArguments -join ' '
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stream = [System.IO.File]::Create($OutputPath)
    try { $process.StandardOutput.BaseStream.CopyTo($stream) } finally { $stream.Dispose() }
    $errorText = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        Remove-Item -LiteralPath $OutputPath -ErrorAction SilentlyContinue
        throw "ADB falló al capturar datos binarios ($($process.ExitCode)): $errorText"
    }
}

function Get-AdbDeepLinkArguments {
    param([Parameter(Mandatory)][string]$Uri, [string]$Package = $script:FutBeatPackage)
    return @('shell', 'am', 'start', '-W', '-a', 'android.intent.action.VIEW', '-d', $Uri, $Package)
}

function Protect-QaLog {
    param([AllowEmptyString()][string]$Text)
    if ($null -eq $Text) { return '' }
    $clean = [regex]::Replace($Text, '(?i)(authorization\s*[:=]\s*bearer\s+)[^\s,;]+', '$1[REDACTED]')
    $clean = [regex]::Replace($clean, '(?i)(access_token|refresh_token|token_hash|id_token|apikey)(\s*[:=]\s*|%3[dD])([^\s&;,"''}]+)', '$1$2[REDACTED]')
    return [regex]::Replace($clean, '(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', '[REDACTED_JWT]')
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "No existe el archivo '$Path'." }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-QaArtifactManifestPath {
    param([Parameter(Mandatory)][string]$ApkPath)
    return "$([System.IO.Path]::GetFullPath($ApkPath)).qa.json"
}

function Assert-QaAdsTestArtifact {
    param([Parameter(Mandatory)][string]$ApkPath)
    $manifestPath = Get-QaArtifactManifestPath -ApkPath $ApkPath
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "No se encontró la marca Ads TEST '$manifestPath'. Genera el APK con scripts/qa/build-android-qa.ps1 -TestAds."
    }
    try { $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json }
    catch { throw "La marca Ads TEST no es JSON válido: '$manifestPath'." }
    if ($manifest.schemaVersion -ne 1 -or $manifest.package -ne $script:FutBeatPackage) {
        throw 'La marca Ads TEST no corresponde al formato/package esperado.'
    }
    if ($manifest.qaMode -ne 'TEST' -or $manifest.adsExpected -ne $true) {
        throw 'El APK no está marcado como una compilación Ads TEST habilitada.'
    }
    $actualSha = Get-FileSha256 -Path $ApkPath
    if ($manifest.sha256 -ne $actualSha) {
        throw 'La huella del APK no coincide con su marca Ads TEST; el artefacto pudo ser reemplazado.'
    }
    return $manifest
}

function New-QaReport {
    param([Parameter(Mandatory)][hashtable]$Data)
    $screenshots = if ($Data.Screenshots -and @($Data.Screenshots).Count -gt 0) { (@($Data.Screenshots) | ForEach-Object { "- `$_" }) -join "`n" } else { '- Ninguna' }
    $links = if ($Data.DeepLinks -and @($Data.DeepLinks).Count -gt 0) { (@($Data.DeepLinks) | ForEach-Object { "- $($_.Name): $($_.Result)" }) -join "`n" } else { '- No ejecutados' }
    $warnings = if ($Data.Warnings -and @($Data.Warnings).Count -gt 0) { (@($Data.Warnings) | ForEach-Object { "- $_" }) -join "`n" } else { '- Ninguno detectado' }
    return @"
# FutBeat Android smoke report

**Resultado global:** $($Data.Result)

> Este resultado cubre exclusivamente las comprobaciones automáticas descritas aquí. No certifica login, OAuth, compras, anuncios ni el checklist manual.

## APK

- Ruta: $($Data.ApkPath)
- SHA-256: $($Data.Sha256)
- Package esperado: $($Data.Package)
- Version name: $($Data.VersionName)
- Version code: $($Data.VersionCode)
- Instalación: $($Data.InstallResult)
- Duración instalación: $($Data.InstallDuration)

## Publicidad QA

- Ads QA mode: $($Data.AdsQaMode)
- Ad configuration expected: $($Data.AdConfigurationExpected)
- Verificación del artefacto: $($Data.AdsArtifactVerification)

## Dispositivo

- Fabricante: $($Data.Manufacturer)
- Modelo: $($Data.Model)
- Android: $($Data.AndroidVersion)
- API: $($Data.ApiLevel)
- Resolución: $($Data.Resolution)
- Densidad: $($Data.Density)
- Locale: $($Data.Locale)
- Zona horaria: $($Data.TimeZone)

## Ciclo de vida

- Primer arranque: $($Data.LaunchResult)
- Segundo arranque: $($Data.RelaunchResult)
- Crashes detectados: $($Data.CrashCount)

## Deep links seguros

$links

## Evidencias

### Screenshots

$screenshots

- Logcat sanitizado: $($Data.LogcatPath)

## Advertencias

$warnings

## Pendiente manual

Completar docs/qa/ANDROID-SMOKE-CHECKLIST.md. Ninguna comprobación manual se marca como aprobada automáticamente.
"@
}
