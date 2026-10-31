# Pure readiness/state tests. No task, ADB, app or approval modifications.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'qa227-development-policy.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('qa229-ready-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$path=Join-Path $root 'ready.json';$now=[datetimeoffset]::UtcNow;$passed=0
$session='QADEV-SYNTHETIC-READY-001';$nonce='b'*32;$guard=12345
function Assert([bool]$Condition,[string]$Name){if(-not $Condition){throw "FAIL: $Name"};$script:passed++}
try {
    Assert (-not (Test-QaDevelopmentGuardReady -Path $path -SessionId $session -Nonce $nonce -GuardPid $guard -Now $now)) 'process exists but no readiness'
    foreach($case in @('valid','wrong-session','wrong-nonce','wrong-pid','stale','future','stopping')){
        $r=@{schema='qa-development-guard-v1';status='READY';session_id=$session;nonce=$nonce;process_id=$guard;utc=$now.ToString('o')}
        switch($case){
            'wrong-session' {$r.session_id='QADEV-OTHER'}
            'wrong-nonce' {$r.nonce='c'*32}
            'wrong-pid' {$r.process_id=12346}
            'stale' {$r.utc=$now.AddSeconds(-16).ToString('o')}
            'future' {$r.utc=$now.AddSeconds(1).ToString('o')}
            'stopping' {$r.status='STOPPING'}
        }
        $r|ConvertTo-Json|Set-Content $path
        $actual=Test-QaDevelopmentGuardReady -Path $path -SessionId $session -Nonce $nonce -GuardPid $guard -Now $now
        Assert ($actual -eq ($case -ceq 'valid')) $case
    }
    $script:pulses=0;$script:waits=0
    $ready=Wait-QaDevelopmentGuardReady -Ready {$script:pulses -ge 3} -Alive {$true} -Pulse {$script:pulses++} -Wait {$script:waits++} -MaxChecks 5
    Assert ($ready -and $script:pulses -eq 3 -and $script:waits -eq 2) 'slow-start only grants after real ready'
    $script:pulses=0
    $ready=Wait-QaDevelopmentGuardReady -Ready {$true} -Alive {$false} -Pulse {$script:pulses++} -Wait {} -MaxChecks 3
    Assert (-not $ready -and $script:pulses -eq 0) 'dead guard never grants even if stale ready file exists'
    $script:pulses=0
    $ready=Wait-QaDevelopmentGuardReady -Ready {$false} -Alive {$true} -Pulse {$script:pulses++} -Wait {} -MaxChecks 3
    Assert (-not $ready -and $script:pulses -eq 3) 'alive but not initialized is bounded NO-GO'
}finally{Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $root}
"QA229 guard readiness: $passed PASS (synthetic only; no task/ADB changes)"
