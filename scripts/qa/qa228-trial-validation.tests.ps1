$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'qa228-trial-validation.ps1')
$now=[datetimeoffset]::Parse('2026-10-31T06:00:00Z')
$task=$now.AddSeconds(-10)
$process=[pscustomobject]@{Id=12;StartTime=$now.AddSeconds(-9).UtcDateTime}
$hb=[pscustomobject]@{launcher_pid=12;status='DISARMED';updated_at=$now.AddSeconds(-1).ToString('o')}
$count=0
function Check([bool]$actual,[bool]$expected,[string]$name){if($actual -ne $expected){throw $name};$script:count++}
Check (Test-QaTrialLauncherHeartbeat $hb $process $task $now) $true 'valid current process'
Check (Test-QaTrialLauncherHeartbeat $hb $null $task $now) $false 'dead process'
Check (Test-QaTrialLauncherHeartbeat $hb ([pscustomobject]@{Id=13;StartTime=$process.StartTime}) $task $now) $false 'other process'
Check (Test-QaTrialLauncherHeartbeat $hb ([pscustomobject]@{Id=12;StartTime=$now.AddMinutes(-3).UtcDateTime}) $task $now) $false 'previous task invocation'
$hb.updated_at=$now.AddSeconds(-16).ToString('o')
Check (Test-QaTrialLauncherHeartbeat $hb $process $task $now) $false 'stale heartbeat'
$hb.updated_at=$now.AddSeconds(4).ToString('o')
Check (Test-QaTrialLauncherHeartbeat $hb $process $task $now) $false 'future heartbeat'
$hb.updated_at=$now.AddSeconds(-1).ToString('o');$hb.status='CONTROLLER_ACTIVE'
Check (Test-QaTrialLauncherHeartbeat $hb $process $task $now) $false 'not disarmed'
$hb.status='DISARMED';$hb.updated_at='invalid'
Check (Test-QaTrialLauncherHeartbeat $hb $process $task $now) $false 'corrupt timestamp'
$hb.updated_at=$now.AddSeconds(-14).ToString('o')
Check (Test-QaTrialLauncherHeartbeat $hb $process $task $now) $false 'old timestamp from previous run'
"QA trial heartbeat ownership: $count PASS (pure synthetic checks)"