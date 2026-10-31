# Pure heartbeat ownership check shared by the bounded offline trial helpers.
function Test-QaTrialActiveHeartbeat {
    param([object]$Heartbeat,[object]$Session,[datetimeoffset]$Now)
    try {
        $at=[datetimeoffset]::Parse([string]$Heartbeat.updated_at)
        return ($Heartbeat.status -ceq 'QADEV_CACHE_ONLY' -and
            $Heartbeat.window_id -ceq $Session.session_id -and
            [int]$Heartbeat.launcher_pid -eq [int]$Session.launcher_pid -and
            [datetimeoffset]::Parse([string]$Session.expires_at) -gt $Now -and
            $at -le $Now.AddSeconds(3) -and ($Now-$at).TotalSeconds -le 20)
    }catch{return $false}
}

function Test-QaTrialLauncherHeartbeat {
    param([object]$Heartbeat,[object]$Process,[datetimeoffset]$TaskStarted,[datetimeoffset]$Now,[string]$StatusPattern='DISARMED*')
    try {
        if($null -eq $Process -or [int]$Heartbeat.launcher_pid -ne [int]$Process.Id){return $false}
        $at=[datetimeoffset]::Parse([string]$Heartbeat.updated_at)
        $start=[datetimeoffset]$Process.StartTime.ToUniversalTime()
        $age=($Now-$at).TotalSeconds
        return ($Heartbeat.status -like $StatusPattern -and $age -ge -3 -and $age -le 15 -and
            $at -ge $TaskStarted.AddSeconds(-2) -and $start -ge $TaskStarted.AddSeconds(-2))
    }catch{return $false}
}
