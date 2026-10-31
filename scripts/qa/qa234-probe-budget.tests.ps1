# Isolated fake-ADB policy checks, including a genuinely slow read pass.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'qa227-development-policy.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('qa234-budget-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory (Join-Path $root 'gates') -Force|Out-Null
$now=[datetimeoffset]::UtcNow;$id='QADEV-QA234-SYNTHETIC-BUDGET';$passed=0
$a=@{schema='qa-development-v1';approved=$true;approved_by='user';session_id=$id;nonce=('a'*32);package='com.futbeat.futbeat.qa';serial='RF8R32GQWGL';apk_sha256=('A'*64);mode='cache_only';approved_at=$now.AddSeconds(-1).ToString('o');expires_at=$now.AddMinutes(2).ToString('o')}
$s=@{};foreach($k in @('session_id','nonce','package','serial','apk_sha256','mode','expires_at')){$s[$k]=$a[$k]}
$s.status='ACTIVE';$s.stop=$false;$s.supervisor_heartbeat_at=$now.ToString('o');$s.http_requests=0;$s.http_in_minute=0;$s.local_network_block_verified=$true
$probe={param($Arguments)
 $script:calls++
 if($script:delay){Start-Sleep -Milliseconds 1600}
 $value=switch -Regex ($Arguments -join ' '){
  'get-state$' {'device';break}
  'ro.product.model$' {'SM-A325M';break}
  'pm path' {'package:/data/app/synthetic/com.futbeat.futbeat.qa/base.apk';break}
  'sha256sum' {('a'*64)+' base.apk';break}
  'wifi_on$|mobile_data$' {'0';break}
  'dumpsys connectivity$' {'Active default network: none';break}
  default {throw 'Unexpected fake request'}
 }
 return @{exit_code=0;output=$value}
}
try {
 $a|ConvertTo-Json|Set-Content (Join-Path $root 'qa227-development-approval.json')
 $s|ConvertTo-Json|Set-Content (Join-Path $root 'qa227-development-state.json')
 $script:calls=0;$script:delay=$true;$clock=[Diagnostics.Stopwatch]::StartNew()
 $r=Get-QaDevelopmentDecision -StateRoot $root -GateDirectory (Join-Path $root 'gates') -Now $now -Probe $probe -IndependentWatchdogVerified $true
 if($r.allowed -or $r.reason-cne'adb_read_budget_exhausted' -or $script:calls-ne4 -or $clock.ElapsedMilliseconds-gt8000){throw 'Slow read pass was not bounded'};$passed++
 $script:qa227Apk=$null;$script:calls=0;$script:delay=$false
 $r=Get-QaDevelopmentDecision -StateRoot $root -GateDirectory (Join-Path $root 'gates') -Now $now -Probe $probe -IndependentWatchdogVerified $true
 if(-not$r.allowed -or $script:calls-ne7){throw "Valid bounded reads rejected: $($r.reason),calls=$script:calls"};$passed++
 $script:calls=0
 $r=Get-QaDevelopmentDecision -StateRoot $root -GateDirectory (Join-Path $root 'gates') -Now $now -Probe {$script:calls++;throw 'adb_unavailable'} -IndependentWatchdogVerified $true
 if($r.allowed -or $r.reason-cne'adb_unavailable' -or $script:calls-ne1){throw 'Disconnected ADB must immediately deny'};$passed++
}finally{
 foreach($f in Get-ChildItem -LiteralPath $root -File){Remove-Item -LiteralPath $f.FullName}
 Remove-Item -LiteralPath (Join-Path $root 'gates');Remove-Item -LiteralPath $root
}
"QA234 probe budget: $passed PASS (fake ADB only)"
