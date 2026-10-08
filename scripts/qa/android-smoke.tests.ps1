$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'android-smoke.lib.ps1')

$script:Passed = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT: $Message" }
    $script:Passed++
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action; throw 'ASSERT: se esperaba una excepción.' }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "ASSERT: '$($_.Exception.Message)' no coincide con '$Pattern'." }
        $script:Passed++
    }
}

$parsed = @(ConvertFrom-AdbDevices -Lines @(
    'List of devices attached',
    'R58M123456 device product:a32 model:SM_A325M transport_id:1',
    'emulator-5554 unauthorized transport_id:2'
))
Assert-True ($parsed.Count -eq 2) 'parse adb devices conserva ambos destinos'
Assert-True ($parsed[0].Id -eq 'R58M123456' -and $parsed[0].State -eq 'device') 'parse dispositivo listo'
Assert-True ($parsed[1].State -eq 'unauthorized') 'parse dispositivo unauthorized'
Assert-Throws { Resolve-AdbDevice -Devices $parsed } 'varios dispositivos'
Assert-Throws { Resolve-AdbDevice -Devices @($parsed[1]) } 'unauthorized'
Assert-True ((Resolve-AdbDevice -Devices $parsed -DeviceId 'R58M123456').Id -eq 'R58M123456') 'DeviceId selecciona destino exacto'

$missing = Join-Path ([System.IO.Path]::GetTempPath()) "futbeat-missing-$([guid]::NewGuid()).apk"
Assert-Throws { Get-FileSha256 -Path $missing } 'No existe'

$secretLog = 'Authorization: Bearer abc123 access_token=secret token_hash=hash eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.signature'
$safeLog = Protect-QaLog -Text $secretLog
Assert-True ($safeLog -notmatch 'abc123|secret|token_hash=hash|eyJhbGci') 'sanitizer elimina bearer, tokens y JWT'
Assert-True ($safeLog -match '\[REDACTED') 'sanitizer deja marca de redacción'

$deepLink = Get-AdbDeepLinkArguments -Uri 'https://futbeat.com/auth/reset'
Assert-True (($deepLink -join ' ') -eq 'shell am start -W -a android.intent.action.VIEW -d https://futbeat.com/auth/reset com.futbeat.futbeat') 'comando deep link seguro y limitado al package'

$tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "futbeat-sha-$([guid]::NewGuid()).txt"
[System.IO.File]::WriteAllText($tempFile, 'FutBeat')
try {
    Assert-True ((Get-FileSha256 -Path $tempFile) -eq 'ffa6f2f1b4c439c21557d69ec750d7a983a103b9cb7de8f32a1a5fa725ab408d') 'SHA-256 determinista'
} finally { Remove-Item -LiteralPath $tempFile -Force }

$report = New-QaReport -Data @{
    Result = 'PASS_WITH_WARNINGS'; ApkPath = 'app.apk'; Sha256 = 'abc'; Package = 'com.futbeat.futbeat'
    VersionName = '1.0.0'; VersionCode = '1'; InstallResult = 'PASS'; InstallDuration = '2.0s'
    Manufacturer = 'samsung'; Model = 'SM-A325M'; AndroidVersion = '13'; ApiLevel = '33'
    Resolution = '1080x2400'; Density = '420'; Locale = 'es-CR'; TimeZone = 'America/Costa_Rica'
    LaunchResult = 'PASS'; RelaunchResult = 'PASS'; CrashCount = 0
    DeepLinks = @([pscustomobject]@{ Name = 'reset'; Result = 'PASS' })
    Screenshots = @('launch.png'); LogcatPath = 'logcat.txt'; Warnings = @('revisar')
}
Assert-True ($report -match 'PASS_WITH_WARNINGS' -and $report -match 'SM-A325M') 'reporte incluye resultado y dispositivo'
Assert-True ($report -match 'No certifica login, OAuth, compras') 'reporte delimita alcance automático'

Write-Host "PASS: $script:Passed assertions" -ForegroundColor Green
