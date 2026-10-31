# Generates local review candidates of the EXISTING two QA123 scripts.
# Does not install them, create approvals, start processes or change any task.
param(
    [Parameter(Mandatory)][string]$LauncherPath,
    [Parameter(Mandatory)][string]$FailsafePath
)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$out=Join-Path $repo 'artifacts/qa227/controller-candidate'
New-Item -ItemType Directory -Path $out -Force | Out-Null
function Replace-One([string]$Text,[string]$Needle,[string]$Replacement){
    if($Text.IndexOf($Needle) -lt 0 -or $Text.IndexOf($Needle) -ne $Text.LastIndexOf($Needle)){throw 'Controller baseline changed; do not apply blindly'}
    return $Text.Replace($Needle,$Replacement)
}
$launcher=(Get-Content -LiteralPath $LauncherPath -Raw).Replace("`r",'')
$failsafe=(Get-Content -LiteralPath $FailsafePath -Raw).Replace("`r",'')
$launcher=Replace-One $launcher 'function Invoke-AdbBounded([string[]]$Arguments) {' 'function Invoke-AdbBounded([string[]]$Arguments, [int]$TimeoutMs=8000) {'
$launcher=Replace-One $launcher '$proc.WaitForExit(8000)' '$proc.WaitForExit($TimeoutMs)'
$import=". (Join-Path `$PSScriptRoot 'qa227-development-policy.ps1')`n"
$launcher=Replace-One $launcher ". (Join-Path `$PSScriptRoot 'qa123-coordination-rotate.ps1')" (". (Join-Path `$PSScriptRoot 'qa123-coordination-rotate.ps1')`n"+$import)
$launcher=$launcher.Replace("'^QA12[36]-[A-Za-z0-9-]+$'","'^QA(?:12[36]|DEV)-[A-Za-z0-9-]+$'")
$block=@'
        # QA227 CACHE ONLY. Same launcher, same failsafe, same close recovery.
        # No process exemption is granted before its independent guard starts.
        $dev=Get-QaDevelopmentDecision -StateRoot $StateRoot -GateDirectory $CoordinationDirectory -Now ([datetimeoffset]::UtcNow) -Clock {[datetimeoffset]::UtcNow} -Probe {param($Arguments) Invoke-AdbBounded -Arguments $Arguments} -IndependentWatchdogVerified $true
        if($dev.allowed){
            $devApproval=Read-Json (Join-Path $StateRoot 'qa227-development-approval.json')
            $devPid=Invoke-AdbBounded @('-s','RF8R32GQWGL','shell','pidof','com.futbeat.futbeat.qa')
            # Eligibility above is not an ALLOW: initial ownership requires a
            # closed app. A stray existing process takes normal orphan closure.
            if($devPid.exit_code -eq 1 -and [string]::IsNullOrWhiteSpace($devPid.output)){
                $devBeat=Join-Path $StateRoot 'qa227-supervisor-heartbeat.json'
                $devClose=Join-Path $StateRoot 'qa227-close.json'
                $devEvidence=Join-Path $StateRoot 'qa227-failsafe-evidence.json'
                $devReady=Join-Path $StateRoot 'qa227-failsafe-ready.json'
                $guard=$null
                try {
                    Write-AtomicJson $devBeat @{status='ACTIVE';utc=[datetimeoffset]::UtcNow.ToString('o');session_id=$devApproval.session_id;nonce=$devApproval.nonce}
                    $psi=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
                    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
                    Remove-Item -LiteralPath $devReady -ErrorAction SilentlyContinue
                    foreach($arg in @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'qa123-failsafe.ps1'),'-HeartbeatPath',$devBeat,'-AbsoluteExpiryUtc',$devApproval.expires_at,'-GatePath',(Join-Path $StateRoot 'qa227-development-state.json'),'-ExpectedWindowId',$devApproval.session_id,'-ExpectedNonce',$devApproval.nonce,'-EvidencePath',$devEvidence,'-DevelopmentStateRoot',$StateRoot,'-DevelopmentGateDirectory',$CoordinationDirectory,'-DevelopmentReadyPath',$devReady)){[void]$psi.ArgumentList.Add([string]$arg)}
                    $guard=[Diagnostics.Process]::Start($psi)
                    $guardReady={Test-QaDevelopmentGuardReady -Path $devReady -SessionId $devApproval.session_id -Nonce $devApproval.nonce -GuardPid $guard.Id -Now ([datetimeoffset]::UtcNow) -Clock {[datetimeoffset]::UtcNow}}
                    $ready=Wait-QaDevelopmentGuardReady -Ready $guardReady -Alive {$guard.Refresh();return (-not $guard.HasExited)} -Pulse {
                        Write-AtomicJson $devBeat @{status='ACTIVE';utc=[datetimeoffset]::UtcNow.ToString('o');session_id=$devApproval.session_id;nonce=$devApproval.nonce}
                        Heartbeat 'QADEV_WAITING_FOR_FAILSAFE' $devApproval.session_id
                    } -Wait {Start-Sleep -Milliseconds 250}
                    if(-not $ready){throw 'independent_guard_not_ready'}
                    Write-AtomicJson $activeWindowPath @{window_id=$devApproval.session_id;serial='RF8R32GQWGL';package='com.futbeat.futbeat.qa';close_path=$devClose}
                    Log-Event 'QADEV_STARTED_WITH_INDEPENDENT_FAILSAFE' $devApproval.session_id
                    $result=Invoke-QaDevelopmentSession -Decision {
                        $guard.Refresh()
                        Get-QaDevelopmentDecision -StateRoot $StateRoot -GateDirectory $CoordinationDirectory -Now ([datetimeoffset]::UtcNow) -Clock {[datetimeoffset]::UtcNow} -Probe {param($Arguments) Invoke-AdbBounded -Arguments $Arguments} -IndependentWatchdogVerified ((-not $guard.HasExited) -and (& $guardReady))
                    } -WatchdogAlive {$guard.Refresh();return ((-not $guard.HasExited) -and (& $guardReady))} -Heartbeat {
                        Write-AtomicJson $devBeat @{status='ACTIVE';utc=[datetimeoffset]::UtcNow.ToString('o');session_id=$devApproval.session_id;nonce=$devApproval.nonce}
                        Heartbeat 'QADEV_CACHE_ONLY' $devApproval.session_id
                    } -Wait {Start-Sleep -Seconds 2} -CloseQa {
                        param($reason)
                        $stop=Invoke-AdbBounded -Arguments @('-s','RF8R32GQWGL','shell','am','force-stop','com.futbeat.futbeat.qa') -TimeoutMs 1500
                        $check=Invoke-AdbBounded -Arguments @('-s','RF8R32GQWGL','shell','pidof','com.futbeat.futbeat.qa') -TimeoutMs 1500
                        $device=Invoke-AdbBounded -Arguments @('-s','RF8R32GQWGL','get-state') -TimeoutMs 1500
                        return ($stop.exit_code -eq 0 -and $check.exit_code -eq 1 -and [string]::IsNullOrWhiteSpace($check.output) -and $device.exit_code -eq 0 -and $device.output.Trim() -ceq 'device')
                    }
                    if($result.status -ceq 'CLOSED'){
                        Write-AtomicJson $devClose @{window_id=$devApproval.session_id;status='CLOSED';force_stop_confirmed_at=[datetimeoffset]::UtcNow.ToString('o')}
                        Write-AtomicJson $devBeat @{status='CLOSED';utc=[datetimeoffset]::UtcNow.ToString('o');session_id=$devApproval.session_id;nonce=$devApproval.nonce}
                        if(-not $guard.WaitForExit(8000)){$guard.Kill()} # app already confirmed closed
                        Remove-Item -LiteralPath $activeWindowPath -ErrorAction SilentlyContinue
                    }else{throw ('development_close_not_confirmed:'+$result.reason)}
                    Log-Event ('QADEV_CLOSED_'+$result.reason) $devApproval.session_id
                }catch{
                    # Existing recovery retries through ADB loss/restart. Never
                    # kill the failsafe while app closure remains unconfirmed.
                    Write-AtomicJson $pendingClosePath @{window_id=$devApproval.session_id;serial='RF8R32GQWGL';package='com.futbeat.futbeat.qa';recorded_at=[datetimeoffset]::UtcNow.ToString('o');reason='qa227_controller_error';detail=$_.Exception.Message}
                    Log-Event 'QADEV_PENDING_CLOSE' $devApproval.session_id
                }
                continue
            }
        }
'@
$block=$block.Replace('Invoke-AdbBounded -Arguments $Arguments','Invoke-AdbBounded -Arguments $Arguments -TimeoutMs 1500')
$launcher=Replace-One $launcher '        # No controller owns the QA package outside an active-window ledger.' ($block+"`n        # No controller owns the QA package outside an active-window ledger.")
$failsafe=Replace-One $failsafe "    [string]`$EvidencePath = ''," "    [string]`$DevelopmentStateRoot = '',`n    [string]`$DevelopmentGateDirectory = '',`n    [string]`$DevelopmentReadyPath = '',`n    [string]`$EvidencePath = '',"
$failsafe=Replace-One $failsafe ". (Join-Path `$PSScriptRoot 'qa81-contract-v2.ps1')" (". (Join-Path `$PSScriptRoot 'qa81-contract-v2.ps1')`n"+$import)
$failsafe=Replace-One $failsafe 'function Invoke-AdbBounded([string[]]$Arguments) {' ('function Invoke-AdbBounded([string[]]$Arguments) {'+"`n"+'    $commandTimeout=if($DevelopmentStateRoot){1500}else{8000}')
$failsafe=Replace-One $failsafe '$process.WaitForExit(8000)' '$process.WaitForExit($commandTimeout)'
$failsafe=Replace-One $failsafe '        [void]$process.Start()' ('        [void]$process.Start()'+"`n"+'        $stdoutTask=$process.StandardOutput.ReadToEndAsync()'+"`n"+'        $stderrTask=$process.StandardError.ReadToEndAsync()')
$failsafe=Replace-One $failsafe 'output = $process.StandardOutput.ReadToEnd()' 'output = $stdoutTask.GetAwaiter().GetResult()'
$start=$failsafe.IndexOf('        $gate = Get-Content -LiteralPath $GatePath')
$end=$failsafe.IndexOf('        if (-not (Test-Path -LiteralPath $HeartbeatPath', $start)
if($start -lt 0 -or $end -le $start){throw 'Failsafe baseline changed'}
$original=$failsafe.Substring($start,$end-$start)
$devGuard=@'
        if($DevelopmentStateRoot){
            if($ExpectedWindowId -cnotmatch '^QADEV-[A-Za-z0-9-]{8,80}$' -or [string]::IsNullOrWhiteSpace($DevelopmentGateDirectory)){throw 'development_guard_identity_invalid'}
            $dev=Get-QaDevelopmentDecision -StateRoot $DevelopmentStateRoot -GateDirectory $DevelopmentGateDirectory -Now $now -Clock {[datetimeoffset]::UtcNow} -Probe {param($Arguments) Invoke-AdbBounded -Arguments $Arguments} -IndependentWatchdogVerified $true
            $a=Get-Content -LiteralPath (Join-Path $DevelopmentStateRoot 'qa227-development-approval.json') -Raw | ConvertFrom-Json -AsHashtable -DateKind String
            if(-not $dev.allowed -or $dev.session_id -cne $ExpectedWindowId -or $a.nonce -cne $ExpectedNonce){throw ('development_policy_'+$dev.reason)}
        }else{
'@
$failsafe=$failsafe.Substring(0,$start)+$devGuard+"`n"+$original+"        }`n"+$failsafe.Substring($end)
# Slow policy/ADB checks must not compare a new beat with a timestamp captured
# before those checks; that produces a false future-heartbeat STOP.
$failsafe=Replace-One $failsafe '        if (-not (Test-Path -LiteralPath $HeartbeatPath' ('        $now=[datetimeoffset]::UtcNow'+"`n"+'        if (-not (Test-Path -LiteralPath $HeartbeatPath')
$readyWrite=@'
    if($DevelopmentStateRoot -and $DevelopmentReadyPath){
        $expectedReady=Join-Path $DevelopmentStateRoot 'qa227-failsafe-ready.json'
        if([IO.Path]::GetFullPath($DevelopmentReadyPath) -cne [IO.Path]::GetFullPath($expectedReady)){throw 'development_ready_path_invalid'}
        $ready=@{schema='qa-development-guard-v1';status='READY';utc=[datetimeoffset]::UtcNow.ToString('o');session_id=$ExpectedWindowId;nonce=$ExpectedNonce;process_id=$PID}
        $tmp="$DevelopmentReadyPath.tmp.$PID"
        [IO.File]::WriteAllText($tmp,($ready|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
        [IO.File]::Move($tmp,$DevelopmentReadyPath,$true)
    }
'@
$failsafe=Replace-One $failsafe '    if ($DryRun -and $DryRunMaxSeconds' ($readyWrite+"`n"+'    if ($DryRun -and $DryRunMaxSeconds')
foreach($item in @(@{name='qa123-launcher.ps1';text=$launcher},@{name='qa123-failsafe.ps1';text=$failsafe})){
    $path=Join-Path $out $item.name
    [IO.File]::WriteAllText($path,$item.text,[Text.UTF8Encoding]::new($false))
    $parseErrors=$null
    [Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$parseErrors) | Out-Null
    if($parseErrors){throw $parseErrors}
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'qa227-development-policy.ps1') -Destination $out -Force
Get-FileHash -LiteralPath $LauncherPath,$FailsafePath -Algorithm SHA256 |
    Select-Object Path,Hash | ConvertTo-Json | Set-Content (Join-Path $out 'BASELINE-HASHES.json')
"Staged paired controller candidates at $out; NOT INSTALLED"
