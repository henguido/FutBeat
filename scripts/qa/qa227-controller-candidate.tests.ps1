# Execute the staged EXISTING failsafe branch with fake ADB and -DryRun.
# This verifies integration, not physical closure. No installed script is run.
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$candidate=Join-Path $repo 'artifacts/qa227/controller-candidate/qa123-failsafe.ps1'
$text=(Get-Content -LiteralPath $candidate -Raw).Replace("`r",'')
$text=$text.Replace(". (Join-Path `$PSScriptRoot 'qa81-contract-v2.ps1')",'')
$text=$text.Replace(". (Join-Path (Split-Path `$PSScriptRoot -Parent) 'qa125\qa125-core.ps1')",'')
$start=$text.IndexOf('function Invoke-AdbBounded(');$end=$text.IndexOf('function Stop-Qa(', $start)
if($start -lt 0 -or $end -le $start){throw 'candidate baseline invalid'}
$mock=@'
function Invoke-AdbBounded([string[]]$Arguments) {
    $line=$Arguments -join ' '
    $output=switch -Regex ($line) {
        'get-state$' {'device';break}
        'ro.product.model$' {'SM-A325M';break}
        'pm path' {'package:/data/app/synthetic/com.futbeat.futbeat.qa/base.apk';break}
        'sha256sum' {('a'*64)+'  synthetic';break}
        'wifi_on$|mobile_data$' {'0';break}
        'dumpsys connectivity$' {'Active default network: __NETWORK__';break}
        default {throw 'unexpected mock request'}
    }
    return @{exit_code=0;output=$output}
}
'@
$prefix=$text.Substring(0,$start);$suffix=$text.Substring($end)
$root=Join-Path ([IO.Path]::GetTempPath()) ('qa227-controller-synthetic-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $root 'gates') -Force | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'qa227-development-policy.ps1') $root
$passed=0
try {
    foreach($case in @('valid','missing-heartbeat','stop','network-active')){
        $now=[datetimeoffset]::UtcNow;$id='QADEV-SYNTHETIC-CANDIDATE-001';$nonce='a'*32
        $approval=@{schema='qa-development-v1';approved=$true;approved_by='user';session_id=$id;nonce=$nonce;package='com.futbeat.futbeat.qa';serial='RF8R32GQWGL';apk_sha256=('A'*64);mode='cache_only';approved_at=$now.AddSeconds(-1).ToString('o');expires_at=$now.AddMinutes(2).ToString('o')}
        $state=@{};foreach($key in @('session_id','nonce','package','serial','apk_sha256','mode','expires_at')){$state[$key]=$approval[$key]}
        $state.status='ACTIVE';$state.stop=($case -eq 'stop');$state.supervisor_heartbeat_at=$now.ToString('o');$state.http_requests=0;$state.http_in_minute=0;$state.local_network_block_verified=$true
        $approval | ConvertTo-Json | Set-Content (Join-Path $root 'qa227-development-approval.json')
        $state | ConvertTo-Json | Set-Content (Join-Path $root 'qa227-development-state.json')
        $beat=Join-Path $root 'controller-heartbeat.json';Remove-Item -LiteralPath $beat -ErrorAction SilentlyContinue
        if($case -ne 'missing-heartbeat'){@{status='ACTIVE';utc=$now.ToString('o')} | ConvertTo-Json | Set-Content $beat}
        $fixture=Join-Path $root 'failsafe-fixture.ps1'
        $network=if($case -eq 'network-active'){'129'}else{'none'}
        [IO.File]::WriteAllText($fixture,$prefix+$mock.Replace('__NETWORK__',$network)+"`n"+$suffix,[Text.UTF8Encoding]::new($false))
        $evidence=Join-Path $root 'evidence.json';Remove-Item -LiteralPath $evidence -ErrorAction SilentlyContinue
        $ready=Join-Path $root 'qa227-failsafe-ready.json';Remove-Item -LiteralPath $ready -ErrorAction SilentlyContinue
        $log=& (Get-Process -Id $PID).Path -NoProfile -File $fixture -HeartbeatPath $beat -AbsoluteExpiryUtc $approval.expires_at -GatePath (Join-Path $root 'unused-gate.json') -ExpectedWindowId $id -ExpectedNonce $nonce -EvidencePath $evidence -DevelopmentStateRoot $root -DevelopmentGateDirectory (Join-Path $root 'gates') -DevelopmentReadyPath $ready -DryRun -DryRunMaxSeconds 1 -PollSeconds 1 2>&1
        if($LASTEXITCODE -ne 0){throw "candidate fixture failed: $log"}
        if($case -eq 'valid'){
            if(($log -join '') -notmatch 'DRYRUN_FAILSAFE_EXIT_NO_APP_ACTION'){throw "valid fixture refused: $log"}
            $ack=Get-Content $ready -Raw|ConvertFrom-Json
            if($ack.status -cne 'READY' -or $ack.session_id -cne $id -or $ack.nonce -cne $nonce -or $ack.process_id -le 0){throw 'guard did not publish identity-bound readiness'}
        }else{
            $record=Get-Content $evidence -Raw | ConvertFrom-Json
            if($record.status -cne 'SIMULATED_ONLY' -or ($log -join '') -notmatch 'SIMULATED_FORCE_STOP'){throw "unsafe fixture not rejected: $case"}
            if(Test-Path $ready){throw 'unsafe guard published readiness'}
        }
        $passed++
    }
}finally{
    if((Split-Path $root -Leaf) -notlike 'qa227-controller-synthetic-*'){throw 'bad cleanup target'}
    Remove-Item -LiteralPath $root -Recurse
}
"QA227 staged failsafe: $passed PASS (mock ADB, DryRun; NOT physical closure)"
