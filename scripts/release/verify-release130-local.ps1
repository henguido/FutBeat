param(
    [string]$FlutterSdkPath,
    [ValidateRange(10, 7200)][int]$TestDeadlineSeconds = 1800
)
$ErrorActionPreference = 'Stop'
$releaseRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if (-not $FlutterSdkPath) {
    $FlutterSdkPath = Join-Path $releaseRoot '../release130-sdk'
}
$FlutterSdkPath = (Resolve-Path $FlutterSdkPath).Path
$releaseEvidence = Join-Path $releaseRoot '.local-data/release130-checks'
$releaseTemp = Join-Path $releaseEvidence 'temp'
New-Item -ItemType Directory -Force -Path $releaseTemp | Out-Null
$releaseDart = Join-Path $FlutterSdkPath 'bin/cache/dart-sdk/bin/dart.exe'
$releaseTool = Join-Path $FlutterSdkPath 'bin/cache/flutter_tools.snapshot'
$releaseResults = [System.Collections.Generic.List[object]]::new()
$releaseSavedEnvironment = @{}
foreach ($name in @('APPDATA', 'TEMP', 'TMP', 'PUB_CACHE', 'FLUTTER_SUPPRESS_ANALYTICS', 'DART_SUPPRESS_ANALYTICS')) {
    $releaseSavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

function Invoke-ReleaseCheck {
    param([string]$Name, [string]$Executable, [string[]]$Arguments, [string]$Directory, [int]$Deadline = 40)
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.WorkingDirectory = $Directory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = [DateTimeOffset]::UtcNow
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $timedOut = $false
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while (-not $process.WaitForExit(1000)) {
            if ($timer.Elapsed.TotalSeconds -ge $Deadline) { $timedOut = $true; break }
        }
        if ($timedOut) {
            # Only this invocation's process tree; never other Flutter/QA processes.
            $process.Kill($true)
            $process.WaitForExit()
        }
        $log = $stdout.GetAwaiter().GetResult() + "`n" + $stderr.GetAwaiter().GetResult()
        $logPath = Join-Path $releaseEvidence "$Name.log"
        [IO.File]::WriteAllText($logPath, $log)
        $socketBlocked = $log -match 'errno = 10057|socket.*10013|access permissions|permisos de acceso'
        $status = if ($timedOut -or $socketBlocked) { 'BLOCKED' } elseif ($process.ExitCode -eq 0) { 'PASS' } else { 'FAIL' }
        $result = [ordered]@{
            name = $Name; status = $status; exit_code = $process.ExitCode
            timed_out = $timedOut; socket_blocked = $socketBlocked
            started_utc = $started.ToString('o'); executable = $Executable
            arguments = $Arguments; working_directory = $Directory; log = $logPath
        }
        $releaseResults.Add($result)
        Write-Output "$Name : $status (exit $($process.ExitCode), timeout=$timedOut)"
    } finally { $process.Dispose() }
}

try {
    $env:APPDATA = Join-Path $releaseEvidence 'appdata'
    $env:TEMP = $releaseTemp
    $env:TMP = $releaseTemp
    if (-not $env:PUB_CACHE) { $env:PUB_CACHE = Join-Path $env:LOCALAPPDATA 'Pub/Cache' }
    $env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
    $env:DART_SUPPRESS_ANALYTICS = 'true'
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $listener.Start()
        $accept = $listener.AcceptTcpClientAsync()
        $connect = $client.ConnectAsync('127.0.0.1', $listener.LocalEndpoint.Port)
        if (-not $connect.Wait(3000)) { throw 'Loopback timeout' }
        $accepted = $accept.GetAwaiter().GetResult()
        $accepted.Dispose()
        $probe = @{ status = 'PASS'; detail = 'Local TCP connection succeeded' }
    } catch {
        $cause = $_.Exception.GetBaseException()
        $probe = @{ status = 'BLOCKED'; detail = $_.Exception.ToString() }
        if ($cause -is [Net.Sockets.SocketException]) { $probe.socket_error_code = $cause.NativeErrorCode }
    } finally { $client.Dispose(); $listener.Stop() }
    $probe | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $releaseEvidence 'loopback.json') -Encoding utf8
    Write-Output "loopback : $($probe.status)"
    # A proven socket denial cannot be fixed by waiting for test timeouts.
    # On a normal host allow the entire suite up to the configured deadline.
    if ($probe.status -eq 'BLOCKED') { $TestDeadlineSeconds = [Math]::Min($TestDeadlineSeconds, 30) }

    $mobile = Join-Path $releaseRoot 'apps/mobile'
    $prefix = @($releaseTool, '--suppress-analytics', '--no-version-check')
    Invoke-ReleaseCheck -Name 'analyze' -Executable $releaseDart -Arguments ($prefix + @('analyze', '--no-pub')) -Directory $mobile -Deadline 60
    $focused = @(
        'news_feed_v2_adapter_test.dart', 'news_screen_test.dart', 'news_link_test.dart',
        'news_transfers_v1_test.dart', 'auth_flows_test.dart', 'auth_sheet_test.dart',
        'account_link_test.dart', 'account_lifecycle_test.dart', 'password_reset_cold_start_test.dart',
        'onboarding_test.dart', 'favorites_hub_v2_test.dart', 'flow_test.dart', 'profile_v2_test.dart',
        'match_center_hero_test.dart', 'match_center_player_navigation_test.dart',
        'match_center_team_statistics_test.dart', 'match_detail_e2e_test.dart', 'score_correction_test.dart',
        'live_bootstrap_test.dart', 'public_offline_cache_test.dart', 'ads_test.dart'
    ) | ForEach-Object { "test/$_" }
    Invoke-ReleaseCheck -Name 'focused' -Executable $releaseDart -Arguments ($prefix + @('test', '--no-pub', '--concurrency=2', '--fail-fast', '--reporter=expanded') + $focused) -Directory $mobile -Deadline $TestDeadlineSeconds
    Invoke-ReleaseCheck -Name 'full' -Executable $releaseDart -Arguments ($prefix + @('test', '--no-pub', '--concurrency=2', '--fail-fast', '--reporter=expanded')) -Directory $mobile -Deadline $TestDeadlineSeconds
    Invoke-ReleaseCheck -Name 'news-smoke' -Executable $releaseDart -Arguments @('scripts/release/news_linkout_smoke.dart') -Directory $releaseRoot
    $node = (Get-Command node -ErrorAction Stop).Source
    Invoke-ReleaseCheck -Name 'android-source' -Executable $node -Arguments @('--test', 'backend/test/android_release_hardening.test.mjs') -Directory $releaseRoot
    $summary = [ordered]@{
        schema_version = 1; source_commit = (git -C $releaseRoot rev-parse HEAD)
        runner_sha256 = (Get-FileHash $PSCommandPath -Algorithm SHA256).Hash
        pubspec_lock_sha256 = (Get-FileHash (Join-Path $mobile 'pubspec.lock') -Algorithm SHA256).Hash
        flutter = Get-Content (Join-Path $FlutterSdkPath 'bin/cache/flutter.version.json') -Raw | ConvertFrom-Json
        loopback = $probe; checks = $releaseResults.ToArray()
    }
    $summary | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $releaseEvidence 'summary.json') -Encoding utf8
    Write-Output "Evidence: $releaseEvidence"
} finally {
    foreach ($name in $releaseSavedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $releaseSavedEnvironment[$name], 'Process')
    }
}
if ($releaseResults.status -contains 'FAIL' -or $releaseResults.status -contains 'BLOCKED') { exit 1 }
