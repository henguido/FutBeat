# No device, process, task or real approval. Simulate slow probes in memory.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'qa227-development-policy.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('qa229-clock-'+[guid]::NewGuid().ToString('N'))
$gates=Join-Path $root 'gates';New-Item -ItemType Directory -Path $gates -Force|Out-Null
$initial=[datetimeoffset]'2026-10-31T08:00:00Z';$passed=0
$approval=@{schema='qa-development-v1';approved=$true;approved_by='user';session_id='QADEV-CLOCK-TEST-001';nonce=('a'*32);package='com.futbeat.futbeat.qa';serial='RF8R32GQWGL';apk_sha256=('A'*64);mode='cache_only';approved_at=$initial.AddMinutes(-1).ToString('o');expires_at=$initial.AddMinutes(10).ToString('o')}
$state=@{};foreach($key in @('session_id','nonce','package','serial','apk_sha256','mode','expires_at')){$state[$key]=$approval[$key]}
$state.status='ACTIVE';$state.stop=$false;$state.supervisor_heartbeat_at=$initial.ToString('o');$state.http_requests=0;$state.http_in_minute=0;$state.local_network_block_verified=$true
$approvalPath=Join-Path $root 'qa227-development-approval.json';$statePath=Join-Path $root 'qa227-development-state.json';$beatPath=Join-Path $root 'qa227-supervisor-heartbeat.json'
try{
    foreach($case in @('fresh','future','stale','stop-during-probe','revoked-during-probe','mode-changed-during-probe','explicit-now')){
        $approval|ConvertTo-Json|Set-Content $approvalPath;$state|ConvertTo-Json|Set-Content $statePath
        $script:simTime=$initial
        @{status='ACTIVE';utc=$initial.ToString('o');session_id=$approval.session_id;nonce=$approval.nonce}|ConvertTo-Json|Set-Content $beatPath
        $probe={param([string[]]$Arguments)
            $script:simTime=$script:simTime.AddSeconds(5)
            $at=$script:simTime
            if($case -ceq 'future'){$at=$at.AddSeconds(1)}
            if($case -ceq 'stale'){$at=$at.AddSeconds(-16)}
            @{status='ACTIVE';utc=$at.ToString('o');session_id=$approval.session_id;nonce=$approval.nonce}|ConvertTo-Json|Set-Content $beatPath
            $line=$Arguments -join ' '
            $output=switch -Regex ($line){
                'get-state$' {'device';break}
                'ro.product.model$' {'SM-A325M';break}
                'pm path' {'package:/data/app/synthetic/com.futbeat.futbeat.qa/base.apk';break}
                'sha256sum' {('a'*64)+'  /data/app/synthetic/com.futbeat.futbeat.qa/base.apk';break}
                'wifi_on$|mobile_data$' {'0';break}
                'dumpsys connectivity$' {
                    if($case -ceq 'stop-during-probe'){$s=$state.Clone();$s.stop=$true;$s|ConvertTo-Json|Set-Content $statePath}
                    if($case -ceq 'revoked-during-probe'){$a=$approval.Clone();$a.approved=$false;$a|ConvertTo-Json|Set-Content $approvalPath}
                    if($case -ceq 'mode-changed-during-probe'){$a=$approval.Clone();$a.mode='stored_only';$a|ConvertTo-Json|Set-Content $approvalPath}
                    'Active default network: none';break
                }
                default {throw 'Unexpected mock probe'}
            }
            return @{exit_code=0;output=$output}
        }
        $args=@{StateRoot=$root;GateDirectory=$gates;Now=$initial;Probe=$probe;IndependentWatchdogVerified=$true}
        if($case -cne 'explicit-now'){$args.Clock={return $script:simTime}}
        $result=Get-QaDevelopmentDecision @args
        $expectedReason=switch($case){
            'fresh' {'approved_supervised_development'}
            'future' {'supervisor_not_present'}
            'stale' {'supervisor_not_present'}
            'stop-during-probe' {'stop_or_inactive'}
            'revoked-during-probe' {'invalid_approval'}
            'mode-changed-during-probe' {'connected_mode_not_activated'}
            'explicit-now' {'supervisor_not_present'}
        }
        if($result.allowed -ne ($case -ceq 'fresh') -or $result.reason -cne $expectedReason){throw "Case $case refused/allowed incorrectly: $($result.reason)"}
        $passed++
    }
}finally{Remove-Item -LiteralPath $approvalPath,$statePath,$beatPath -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $gates;Remove-Item -LiteralPath $root}
"QA229 decision clock: $passed PASS (synthetic only; no ADB/task changes)"
