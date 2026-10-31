$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'qa227-development-policy.ps1')
$now=[datetimeoffset]'2026-10-31T03:00:00Z'
$approval=@{schema='qa-development-v1';approved=$true;approved_by='user';session_id='QADEV-LOCAL-TEST-001';nonce=('a'*32);package='com.futbeat.futbeat.qa';serial='RF8R32GQWGL';apk_sha256=('A'*64);mode='cache_only';approved_at='2026-10-31T02:00:00Z';expires_at='2026-10-31T05:00:00Z'}
$state=@{}; foreach($key in @('session_id','nonce','package','serial','apk_sha256','mode','expires_at')){$state[$key]=$approval[$key]}
$state.status='ACTIVE';$state.stop=$false;$state.supervisor_heartbeat_at=$now.ToString('o');$state.http_requests=0;$state.http_in_minute=0;$state.local_network_block_verified=$true
$passed=0
function Check($a,$s,[bool]$expected,[bool]$offline=$true,[bool]$other=$false){
    $r=Test-QaDevelopmentLease -Approval $a -State $s -Now $now -InstalledSha256 ('A'*64) -DeviceOffline $offline -OtherWindowActive $other -IndependentWatchdogVerified $true
    if($r.allowed -ne $expected){throw "Unexpected decision: $($r.reason)"};$script:passed++
}
Check $approval $state $true
$unprotected=Test-QaDevelopmentLease -Approval $approval -State $state -Now $now -InstalledSha256 ('A'*64) -DeviceOffline $true
if($unprotected.allowed -or $unprotected.reason -cne 'independent_watchdog_unverified'){throw 'unguarded session accepted'};$passed++
Check $approval $state $false $false
Check $approval $state $false $true $true
foreach($change in @(
    @{stop=$true}, @{status='STOP'}, @{supervisor_heartbeat_at='2026-10-31T02:59:44Z'},
    @{supervisor_heartbeat_at='2026-10-31T03:00:01Z'}, @{nonce=('b'*32)}, @{apk_sha256=('B'*64)},
    @{http_requests=1}, @{http_requests=61}, @{http_in_minute=13}, @{http_requests='0'},
    @{local_network_block_verified=$false}, @{package='com.futbeat.futbeat'}
)){ $s=$state.Clone();foreach($key in $change.Keys){$s[$key]=$change[$key]};Check $approval $s $false }
foreach($change in @(@{approved=$false},@{approved_by='codex'},@{expires_at='2026-10-31T02:59:00Z'},@{expires_at='2026-10-31T11:00:00Z'})){
    $a=$approval.Clone();$s=$state.Clone();foreach($key in $change.Keys){$a[$key]=$change[$key];if($s.ContainsKey($key)){$s[$key]=$change[$key]}};Check $a $s $false
}
$a=$approval.Clone();$s=$state.Clone();$a.mode='stored_only';$s.mode='stored_only';$s.qa_stored_contract='v1';$s.production_health='GREEN';$s.production_health_at=$now.ToString('o')
Check $a $s $true $false
foreach($change in @(@{production_health='UNKNOWN'},@{production_health='RED'},@{production_health_at='2026-10-31T02:57:59Z'},@{qa_stored_contract=$null},@{http_requests=61})){
    $t=$s.Clone();foreach($key in $change.Keys){$t[$key]=$change[$key]};Check $a $t $false $false
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('qa227-synthetic-'+[guid]::NewGuid().ToString('N'))
$gates=Join-Path $root 'gates';New-Item -ItemType Directory -Path $gates -Force | Out-Null
try {
    $approval | ConvertTo-Json | Set-Content (Join-Path $root 'qa227-development-approval.json')
    $state | ConvertTo-Json | Set-Content (Join-Path $root 'qa227-development-state.json')
    $probe={ param([string[]]$Arguments)
        $line=$Arguments -join ' '
        $output=switch -Regex ($line) {
            'get-state$' {'device';break}
            'ro.product.model$' {'SM-A325M';break}
            'pm path' {'package:/data/app/synthetic/com.futbeat.futbeat.qa/base.apk';break}
            'sha256sum' {('a'*64)+'  /data/app/synthetic/com.futbeat.futbeat.qa/base.apk';break}
            'wifi_on$|mobile_data$' {'0';break}
            default {throw "unexpected probe: $line"}
        }
        return @{exit_code=0;output=$output}
    }
    $r=Get-QaDevelopmentDecision -StateRoot $root -GateDirectory $gates -Now $now -Probe $probe -IndependentWatchdogVerified $true
    if(-not $r.allowed){throw "file cycle refused: $($r.reason)"};$passed++
    @{status='GO';expires_utc='2026-10-31T03:15:00Z'} | ConvertTo-Json | Set-Content (Join-Path $gates 'OTHER-GATE-STATUS.json')
    $r=Get-QaDevelopmentDecision -StateRoot $root -GateDirectory $gates -Now $now -Probe $probe -IndependentWatchdogVerified $true
    if($r.allowed -or $r.reason -ne 'other_window_active'){throw 'concurrent file gate accepted'};$passed++
    foreach($status in @('RESTORE_FAILED','BROKEN')){
        @{status=$status} | ConvertTo-Json | Set-Content (Join-Path $gates 'OTHER-GATE-STATUS.json')
        $r=Get-QaDevelopmentDecision -StateRoot $root -GateDirectory $gates -Now $now -Probe $probe -IndependentWatchdogVerified $true
        if($r.allowed){throw 'unknown or un-restored gate accepted'};$passed++
    }
    @{status='CLOSED'} | ConvertTo-Json | Set-Content (Join-Path $gates 'OTHER-GATE-STATUS.json')
    $r=Get-QaDevelopmentDecision -StateRoot $root -GateDirectory $gates -Now $now -Probe {return @{exit_code=1;output=''}} -IndependentWatchdogVerified $true
    if($r.allowed -or $r.reason -ne 'adb_unavailable'){throw 'lost ADB accepted'};$passed++
} finally { if((Split-Path $root -Leaf) -notlike 'qa227-synthetic-*'){throw 'bad cleanup target'};Remove-Item -LiteralPath $root -Recurse }
foreach($failure in @('STOP','EXPIRED','supervisor_not_present','budget_exhausted','other_window_active','adb_unavailable')){
    $ctx=@{steps=0;closed=0}
    $r=Invoke-QaDevelopmentSession -Decision {if($ctx.steps -eq 0){return @{allowed=$true}};return @{allowed=$false;reason=$failure}} -WatchdogAlive {return $true} -Heartbeat {} -Wait {$ctx.steps++} -CloseQa {param($reason);$ctx.closed++;return $true}
    if($r.status -ne 'CLOSED' -or $r.reason -ne $failure -or $ctx.closed -ne 1 -or $ctx.steps -ne 1){throw 'session did not stop exactly once'};$passed++
}
foreach($closeConfirmed in @($true,$false)){
    $r=Invoke-QaDevelopmentSession -Decision {return @{allowed=$true}} -WatchdogAlive {return $false} -Heartbeat {throw 'must not navigate'} -Wait {throw 'must not navigate'} -CloseQa {return $closeConfirmed}
    $expected=if($closeConfirmed){'CLOSED'}else{'CLOSE_NOT_CONFIRMED'}
    if($r.status -ne $expected -or $r.reason -ne 'independent_watchdog_lost'){throw 'watchdog-loss outcome wrong'};$passed++
}
$r=Invoke-QaDevelopmentSession -Decision {throw 'executor died'} -WatchdogAlive {return $true} -Heartbeat {} -Wait {} -CloseQa {return $true}
if($r.status -ne 'CLOSED' -or $r.reason -notlike 'controller_error:*'){throw 'controller crash did not close'};$passed++
"QA227 policy: $passed PASS (synthetic decisions only; no task/ADB changes)"
