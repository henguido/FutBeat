param(
    [switch]$TestAds,
    [string]$FlutterPath = 'flutter'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'android-smoke.lib.ps1')

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$mobileRoot = Join-Path $repoRoot 'apps\mobile'
$apkPath = Join-Path $mobileRoot 'build\app\outputs\flutter-apk\app-debug.apk'
$arguments = @('build', 'apk', '--debug')
if ($TestAds) { $arguments += '--dart-define=FUTBEAT_ADMOB_TEST_ADS=true' }

Write-Host "QA mode: $(if ($TestAds) { 'Ads TEST' } else { 'NORMAL' })"
Push-Location $mobileRoot
try {
    & $FlutterPath @arguments
    if ($LASTEXITCODE -ne 0) { throw "Flutter build falló con código $LASTEXITCODE." }
} finally { Pop-Location }

if (-not (Test-Path -LiteralPath $apkPath -PathType Leaf)) { throw "Flutter no generó el APK esperado: '$apkPath'." }
$sha256 = Get-FileSha256 -Path $apkPath
$manifestPath = Get-QaArtifactManifestPath -ApkPath $apkPath
@{
    schemaVersion = 1
    package = $script:FutBeatPackage
    qaMode = $(if ($TestAds) { 'TEST' } else { 'NORMAL' })
    adsExpected = [bool]$TestAds
    sha256 = $sha256
    builtAtUtc = [DateTime]::UtcNow.ToString('o')
    command = "flutter $($arguments -join ' ')"
} | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding utf8

Write-Host "APK: $apkPath"
Write-Host "SHA-256: $sha256"
Write-Host "Marca QA: $manifestPath"
