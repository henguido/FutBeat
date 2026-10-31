# No task or ADB operations. A running but disarmed launcher is not protection.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'qa228-trial-validation.ps1')
$now=[datetimeoffset]::UtcNow;$passed=0
foreach($case in @('valid','disarmed','wrong-window','wrong-owner','stale','future','expired','malformed')){
 $session=@{session_id='QADEV-QA234-SYNTHETIC';launcher_pid=123;expires_at=$now.AddMinutes(1).ToString('o')}
 $hb=@{status='QADEV_CACHE_ONLY';window_id=$session.session_id;launcher_pid=123;updated_at=$now.ToString('o')}
 switch($case){
  'disarmed' {$hb.status='DISARMED'}
  'wrong-window' {$hb.window_id='QADEV-OTHER'}
  'wrong-owner' {$hb.launcher_pid=124}
  'stale' {$hb.updated_at=$now.AddSeconds(-21).ToString('o')}
  'future' {$hb.updated_at=$now.AddSeconds(4).ToString('o')}
  'expired' {$session.expires_at=$now.ToString('o')}
  'malformed' {$hb.updated_at='invalid'}
 }
 if((Test-QaTrialActiveHeartbeat -Heartbeat $hb -Session $session -Now $now) -ne ($case-ceq'valid')){throw "FAIL $case"}
 $passed++
}
"QA234 active ownership: $passed PASS (synthetic only)"
