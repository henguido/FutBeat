[CmdletBinding()]
param(
  [switch]$Build,
  [string]$FlutterSdk='C:/dev/flutter',
  [string]$AndroidSdk="$env:LOCALAPPDATA/Android/Sdk",
  [string]$JavaHome='C:/Program Files/Android/Android Studio/jbr',
  [string]$GradleHome,
  [string]$QaKeyStore="$env:USERPROFILE/.android/debug.keystore",
  [string]$Output
)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path "$PSScriptRoot/../..").Path
# Default is read-only validation. A build requires committed, frozen inputs.
& node (Join-Path $PSScriptRoot 'verify-acceptance-inputs.mjs') $(if($Build){'--require-clean-git'})
if($LASTEXITCODE -ne 0){throw 'Frozen input/Git gate failed'}
$manifest=Get-Content "$PSScriptRoot/acceptance17.sources.json" -Raw | ConvertFrom-Json
$config=Get-Content "$PSScriptRoot/acceptance17.public.json" -Raw | ConvertFrom-Json
if($config.FUTBEAT_PREMIUM_PLAY_QA -ne $false -or
   $config.FUTBEAT_ADMOB_TEST_ADS -ne $true -or
   $config.FUTBEAT_QA_ISOLATED_PACKAGE -ne $true){throw 'QA configuration gate failed'}
$flutter=Join-Path $FlutterSdk 'bin/flutter.bat'
$version=(& $flutter --version --machine | ConvertFrom-Json)
if($version.frameworkRevision -ne $manifest.toolchain.flutter.frameworkRevision -or
   $version.engineRevision -ne $manifest.toolchain.flutter.engineRevision){throw 'Flutter toolchain differs'}
$javaVersion=(& (Join-Path $JavaHome 'bin/java.exe') -version 2>&1 | Out-String)
if($javaVersion -notmatch 'openjdk version "25\.0\.2"'){throw 'Java toolchain differs'}
if(!$Build){Write-Output 'PASS frozen QA inputs; no build, install or remote operation performed'; return}
if(!$Output -or !$GradleHome){throw 'Build needs a new output path and prepared Gradle cache'}
$Output=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Output)
if(Test-Path -LiteralPath $Output){throw 'Preserve existing artifact'}
$env:JAVA_HOME=$JavaHome; $env:ANDROID_HOME=$AndroidSdk; $env:GRADLE_USER_HOME=$GradleHome
$env:GRADLE_OPTS='-Dorg.gradle.daemon=false -Dorg.gradle.workers.max=2'
foreach($name in @('FUTBEAT_BILLING_QA','FUTBEAT_COMMERCIAL_QA','FUTBEAT_QA_ISOLATED_PACKAGE','FUTBEAT_R05_TEST_PACKAGE','FUTBEAT_OFFLINE_PREVIEW','FUTBEAT_PASSIVE_PREVIEW','FUTBEAT_SIGNING_PROPERTIES','FUTBEAT_INTEGRAL_QA')){
  Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
}
$env:FUTBEAT_QA_ISOLATED_PACKAGE='true'
$env:FUTBEAT_COMMERCIAL_UMP_APP_ID='ca-app-pub-8924896982382230~6462208745'
Push-Location (Join-Path $repo 'apps/mobile')
try {
  & $flutter pub get --offline --enforce-lockfile
  if($LASTEXITCODE -ne 0){throw 'Pinned dependency restoration failed'}
  & $flutter build apk --profile --no-pub --target-platform android-arm64 --build-name 1.0.0 --build-number 17 "--dart-define-from-file=$PSScriptRoot/acceptance17.public.json"
  if($LASTEXITCODE -ne 0){throw 'Build failed'}
  & node (Join-Path $PSScriptRoot 'verify-acceptance-inputs.mjs') --require-clean-git
  if($LASTEXITCODE -ne 0){throw 'Build changed frozen inputs'}
  $signer=Join-Path $AndroidSdk 'build-tools/36.0.0/apksigner.bat'
  & $signer sign --ks $QaKeyStore --ks-key-alias androiddebugkey --ks-pass pass:android --key-pass pass:android --v4-signing-enabled false --out $Output build/app/outputs/flutter-apk/app-profile.apk
  if($LASTEXITCODE -ne 0){throw 'QA signing failed'}
  $signature=& $signer verify --verbose --print-certs $Output
  if($LASTEXITCODE -ne 0 -or ($signature -join "`n") -notmatch '6533b820f58ee837e6bbedb29f09b26a8384760ee3de13c5cb6185ad114c0362'){throw 'QA signer differs'}
  Get-FileHash -LiteralPath $Output -Algorithm SHA256
} finally {Pop-Location}
