[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExpectedHead,
    [Parameter(Mandatory)][string]$ActivatedPlaySha256,
    [Parameter(Mandatory)][string]$PublicConfig,
    [Parameter(Mandatory)][string]$FlutterSdk,
    [Parameter(Mandatory)][string]$GradleUserHome,
    [Parameter(Mandatory)][string]$BundletoolJar,
    [Parameter(Mandatory)][string]$Output,
    [Parameter(Mandatory)][switch]$Version16Available
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot/../..").Path
$expected = 'F6:92:F7:0E:52:DC:61:E0:E7:9A:87:23:09:B7:19:C5:62:48:33:E3:2D:E0:3A:E2:17:55:D6:85:98:00:E0:FE'
if (!$Version16Available -or $ActivatedPlaySha256.Trim() -ine $expected) {
    throw 'Confirm the active Play upload fingerprint and versionCode 16 first.'
}
if ((git -C $repo rev-parse HEAD).Trim() -ne $ExpectedHead -or
    (git -C $repo status --porcelain --untracked-files=no)) {
    throw 'The checkout must match the frozen SHA with a clean tracked tree.'
}
$config = (Resolve-Path -LiteralPath $PublicConfig).Path
if ((Get-FileHash -LiteralPath $config).Hash -ne
    '75DE9E727E45BD55DDD7E96D5398B63EFF00746A3A3234BDBFC8922C538E47C4') {
    throw 'Public configuration does not match the frozen release input.'
}
$defines = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json -AsHashtable
$required = @{
    FUTBEAT_R05_ENABLED = $true; FUTBEAT_USER_SESSION_ACCESS = $true
    FUTBEAT_OAUTH_GOOGLE_ENABLED = $true; FUTBEAT_OAUTH_FACEBOOK_ENABLED = $false
    FUTBEAT_PUSH_ENABLED = $false; FUTBEAT_ADS_DISABLED = $true
    FUTBEAT_USE_DEMO = $false; FUTBEAT_QA_LOCAL_CACHE_ONLY = $false
}
foreach ($key in $required.Keys) {
    if ($defines[$key] -isnot [bool] -or $defines[$key] -ne $required[$key]) {
        throw "Unexpected release flag: $key"
    }
}
$allowed = @($required.Keys) + @(
    'FUTBEAT_SUPABASE_PUBLISHABLE_KEY', 'FUTBEAT_SUPABASE_URL', 'FUTBEAT_API_URL'
)
if (@($defines.Keys | Where-Object { $_ -notin $allowed }).Count) {
    throw 'Unexpected fields in the public release configuration.'
}
if ($defines.FUTBEAT_SUPABASE_PUBLISHABLE_KEY -notmatch '^sb_publishable_[A-Za-z0-9_-]+$' -or
    $defines.FUTBEAT_SUPABASE_URL -cne 'https://izlmruqawgagwdcsjhte.supabase.co' -or
    $defines.FUTBEAT_API_URL -cne "$($defines.FUTBEAT_SUPABASE_URL)/functions/v1/futbeat-api") {
    throw 'Unexpected public backend configuration.'
}
$flutter = Join-Path (Resolve-Path $FlutterSdk).Path 'bin/flutter.bat'
$gradleHome = (Resolve-Path $GradleUserHome).Path
$bundletool = (Resolve-Path -LiteralPath $BundletoolJar).Path
$outputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Output)
if (Test-Path -LiteralPath $outputPath) { throw 'Output already exists.' }
$storeDir = 'C:/Users/hen_g/Documents/FutBeat-Secrets/upload-reset-20261113'
$store = Join-Path $storeDir 'futbeat-upload-reset.p12'
$alias = 'futbeat-upload-reset-20261113'
$javaHome = 'C:/Program Files/Android/Android Studio/jbr'
$keytool = Join-Path $javaHome 'bin/keytool.exe'
$jarsigner = Join-Path $javaHome 'bin/jarsigner.exe'
$java = Join-Path $javaHome 'bin/java.exe'
$vars = @{
    JAVA_HOME = $javaHome; GRADLE_USER_HOME = $gradleHome
    ANDROID_HOME = "$env:LOCALAPPDATA/Android/Sdk"
    GRADLE_OPTS = '-Dorg.gradle.daemon=false -Dorg.gradle.workers.max=2'
    FUTBEAT_SIGNING_STORE_FILE = $store; FUTBEAT_SIGNING_ALIAS = $alias
    FUTBEAT_SIGNING_PROPERTIES = $null; FUTBEAT_SIGNING_PASSWORD = $null
    FUTBEAT_QA_ISOLATED_PACKAGE = $null; FUTBEAT_R05_TEST_PACKAGE = $null
    FUTBEAT_OFFLINE_PREVIEW = $null; FUTBEAT_PASSIVE_PREVIEW = $null
}
$saved = @{}
foreach ($key in $vars.Keys) {
    $saved[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
    [Environment]::SetEnvironmentVariable($key, $vars[$key], 'Process')
}
Push-Location "$repo/apps/mobile"
try {
    $secret = Get-Content -LiteralPath (Join-Path $storeDir 'store-password.dpapi') | ConvertTo-SecureString
    $env:FUTBEAT_SIGNING_PASSWORD = [System.Net.NetworkCredential]::new('', $secret).Password
    $cert = & $keytool '-J-Duser.language=en' -list -v -storetype PKCS12 -keystore $store -alias $alias '-storepass:env' FUTBEAT_SIGNING_PASSWORD
    if ($LASTEXITCODE -or !($cert -match 'PrivateKeyEntry') -or
        !($cert | Where-Object { $_.Trim() -eq "SHA256: $expected" })) {
        throw 'The configured private-key entry does not match Play.'
    }
    & $flutter build appbundle --release --build-name 1.0.0 --build-number 16 "--dart-define-from-file=$config"
    if ($LASTEXITCODE) { throw 'Release bundle build failed.' }
    $bundle = 'build/app/outputs/bundle/release/app-release.aab'
    $verification = & $jarsigner '-J-Duser.language=en' -verify $bundle
    if ($LASTEXITCODE -or !($verification -match 'jar verified\.')) {
        throw 'Bundle signature verification failed.'
    }
    $signer = & $keytool '-J-Duser.language=en' -printcert -jarfile $bundle
    if ($LASTEXITCODE -or !($signer | Where-Object { $_.Trim() -eq "SHA256: $expected" })) {
        throw 'Bundle signer differs from the Play upload certificate.'
    }
    & $java -jar $bundletool validate "--bundle=$bundle"
    if ($LASTEXITCODE) { throw 'Bundletool validation failed.' }
    $manifestText = & $java -jar $bundletool dump manifest "--bundle=$bundle" --module=base
    if ($LASTEXITCODE) { throw 'Bundle manifest is not readable.' }
    [xml]$manifest = $manifestText -join "`n"
    $android = 'http://schemas.android.com/apk/res/android'
    $ns = [System.Xml.XmlNamespaceManager]::new($manifest.NameTable)
    $ns.AddNamespace('a', $android)
    if ($manifest.DocumentElement.GetAttribute('package') -cne 'com.futbeat.futbeat' -or
        $manifest.DocumentElement.GetAttribute('versionCode', $android) -cne '16' -or
        $manifest.DocumentElement.GetAttribute('versionName', $android) -cne '1.0.0' -or
        $manifest.SelectSingleNode('/manifest/application[@a:debuggable="true"]', $ns) -or
        !$manifest.SelectSingleNode('//intent-filter/data[@a:scheme="com.futbeat.futbeat" and @a:host="login-callback"]', $ns) -or
        !$manifest.SelectSingleNode('//intent-filter[@a:autoVerify="true"]/data[@a:scheme="https" and @a:host="futbeat.com" and @a:pathPrefix="/auth/reset"]', $ns)) {
        throw 'Unexpected release package, version, OAuth callback, App Link, or debug flag.'
    }
    [IO.File]::Copy((Resolve-Path $bundle).Path, $outputPath, $false)
    Get-FileHash -LiteralPath $outputPath
} finally {
    Pop-Location
    foreach ($key in $saved.Keys) {
        [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process')
    }
}
