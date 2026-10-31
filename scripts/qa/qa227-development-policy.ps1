# Candidate library only. Not loaded by the installed QA123 launcher.
# One explicit approval per supervised development session, not per screen.
$script:qa227Apk=$null

# A newly created OS process is not evidence that its guard loop has started.
# The independent failsafe writes this record only after a full successful pass.
function Test-QaDevelopmentGuardReady {
    param([string]$Path,[string]$SessionId,[string]$Nonce,[int]$GuardPid,[datetimeoffset]$Now,[scriptblock]$Clock)
    try {
        $r=Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop
        if($Clock){$Now=[datetimeoffset](& $Clock)}
        $at=[datetimeoffset]::Parse($r.utc)
        return ($r.schema -ceq 'qa-development-guard-v1' -and $r.status -ceq 'READY' -and
            $r.session_id -ceq $SessionId -and $r.nonce -ceq $Nonce -and
            $r.process_id -eq $GuardPid -and $at -le $Now -and ($Now-$at).TotalSeconds -le 15)
    } catch { return $false }
}

function Wait-QaDevelopmentGuardReady {
    param([scriptblock]$Ready,[scriptblock]$Alive,[scriptblock]$Pulse,[scriptblock]$Wait,[ValidateRange(1,720)][int]$MaxChecks=720)
    # Bound startup to 180 seconds at 250 ms intervals, always with the app closed.
    for($i=0;$i -lt $MaxChecks;$i++) {
        if((& $Alive) -cne $true){return $false}
        & $Pulse | Out-Null
        if((& $Ready) -ceq $true){return $true}
        & $Wait | Out-Null
    }
    return $false
}

function Get-QaDevelopmentDecision {
    param(
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$GateDirectory,
        [Parameter(Mandatory)][datetimeoffset]$Now,
        [Parameter(Mandatory)][scriptblock]$Probe,
        [bool]$IndependentWatchdogVerified = $false,
        [scriptblock]$Clock
    )
    try {
        $a = Get-Content -LiteralPath (Join-Path $StateRoot 'qa227-development-approval.json') -Raw -ErrorAction Stop |
            ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop
        $s = Get-Content -LiteralPath (Join-Path $StateRoot 'qa227-development-state.json') -Raw -ErrorAction Stop |
            ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop
        $beatPath=Join-Path $StateRoot 'qa227-supervisor-heartbeat.json'
        if (Test-Path -LiteralPath $beatPath) {
            $beat=Get-Content -LiteralPath $beatPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop
            if ($beat.session_id -cne $a.session_id -or $beat.nonce -cne $a.nonce -or $beat.status -cne 'ACTIVE') { throw 'supervisor_heartbeat_identity_invalid' }
            $s.supervisor_heartbeat_at=$beat.utc
        }
        # Initial integration is CACHE ONLY. Connected policy cannot be enabled
        # by editing an approval file: it needs a separately reviewed adapter.
        if ($a.mode -cne 'cache_only') { throw 'connected_mode_not_activated' }
        $other = $false
        $ledgerPath=Join-Path $StateRoot 'qa123-active-window.json'
        if (Test-Path -LiteralPath $ledgerPath) {
            $ledger=Get-Content -LiteralPath $ledgerPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop
            $other=$ledger.window_id -cne $a.session_id -or $ledger.serial -cne $a.serial -or $ledger.package -cne $a.package
        }
        foreach ($file in Get-ChildItem -LiteralPath $GateDirectory -Filter '*GATE-STATUS.json' -File -ErrorAction Stop) {
            $g = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop
            if ($g.status -cnotin @('GO','PENDING','STOP','CLOSED','EXPIRED','RESTORE_FAILED')) { throw 'other_window_state_unknown' }
            if ($g.status -ceq 'RESTORE_FAILED') { throw 'prior_restore_failed' }
            if ($g.status -ceq 'GO' -and [datetimeoffset]::Parse($g.expires_utc) -gt $Now) { $other=$true }
            if ($g.status -ceq 'PENDING' -and [datetimeoffset]::Parse($g.go_by_utc) -gt $Now) { $other=$true }
        }
        $device = & $Probe -Arguments @('-s','RF8R32GQWGL','get-state')
        if ($device.exit_code -ne 0 -or $device.output.Trim() -cne 'device') { throw 'adb_unavailable' }
        $model = & $Probe -Arguments @('-s','RF8R32GQWGL','shell','getprop','ro.product.model')
        if ($model.exit_code -ne 0 -or $model.output.Trim() -cne 'SM-A325M') { throw 'wrong_device' }
        $path = & $Probe -Arguments @('-s','RF8R32GQWGL','shell','pm','path','com.futbeat.futbeat.qa')
        if ($path.exit_code -ne 0 -or $path.output.Trim() -cnotmatch '^package:(/data/app/[^\r\n]+/base\.apk)$') { throw 'apk_path_unknown' }
        $apkPath=$Matches[1]
        # Package replacement changes this path. Cache only the digest of that
        # exact installed path, never a versionCode or a filename supplied by QA.
        if (-not $script:qa227Apk -or $script:qa227Apk.path -cne $apkPath) {
            $digest = & $Probe -Arguments @('-s','RF8R32GQWGL','shell','sha256sum',$apkPath)
            if ($digest.exit_code -ne 0) { throw 'apk_hash_unavailable' }
            $script:qa227Apk=@{path=$apkPath;sha=($digest.output.Trim() -split '\s+')[0].ToUpperInvariant()}
        }
        $wifi = & $Probe -Arguments @('-s','RF8R32GQWGL','shell','settings','get','global','wifi_on')
        $data = & $Probe -Arguments @('-s','RF8R32GQWGL','shell','settings','get','global','mobile_data')
        $network = & $Probe -Arguments @('-s','RF8R32GQWGL','shell','dumpsys','connectivity')
        $offline=$wifi.exit_code -eq 0 -and $data.exit_code -eq 0 -and $wifi.output.Trim() -ceq '0' -and $data.output.Trim() -ceq '0' -and $network.exit_code -eq 0 -and $network.output -match 'Active default network:\s*(?:none|null|-1)(?:\s|$)'
        # Slow host/ADB probes may outlive the first state snapshot. Re-read
        # STOP, revocation and the latest beat before sampling the actual clock.
        # Explicit -Now remains deterministic for existing synthetic callers.
        $a=Get-Content -LiteralPath (Join-Path $StateRoot 'qa227-development-approval.json') -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop
        $s=Get-Content -LiteralPath (Join-Path $StateRoot 'qa227-development-state.json') -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop
        if($a.mode -cne 'cache_only'){throw 'connected_mode_not_activated'}
        if(Test-Path -LiteralPath $beatPath){
            $beat=Get-Content -LiteralPath $beatPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop
            if($beat.session_id -cne $a.session_id -or $beat.nonce -cne $a.nonce -or $beat.status -cne 'ACTIVE'){throw 'supervisor_heartbeat_identity_invalid'}
            $s.supervisor_heartbeat_at=$beat.utc
        }
        if($Clock){$Now=[datetimeoffset](& $Clock)}
        $result=Test-QaDevelopmentLease -Approval $a -State $s -Now $Now -InstalledSha256 $script:qa227Apk.sha -DeviceOffline $offline -OtherWindowActive $other -IndependentWatchdogVerified $IndependentWatchdogVerified
        $result.session_id=$a.session_id
        return $result
    } catch { return @{allowed=$false;reason=$_.Exception.Message} }
}

function Test-QaDevelopmentLease {
    param(
        [Parameter(Mandatory)][hashtable]$Approval,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][datetimeoffset]$Now,
        [Parameter(Mandatory)][string]$InstalledSha256,
        [bool]$DeviceOffline = $false,
        [bool]$OtherWindowActive = $false,
        [bool]$IndependentWatchdogVerified = $false
    )
    $deny = 'invalid_contract'
    try {
        if (-not $IndependentWatchdogVerified) { throw 'independent_watchdog_unverified' }
        if ($OtherWindowActive) { throw 'other_window_active' }
        if ($Approval.schema -cne 'qa-development-v1' -or $Approval.approved -isnot [bool] -or $Approval.approved -cne $true -or
            $Approval.approved_by -cne 'user' -or $Approval.session_id -cnotmatch '^QADEV-[A-Za-z0-9-]{8,80}$' -or
            $Approval.nonce -cnotmatch '^[a-f0-9]{32,64}$' -or
            $Approval.package -cne 'com.futbeat.futbeat.qa' -or $Approval.serial -cne 'RF8R32GQWGL' -or
            $Approval.apk_sha256 -cnotmatch '^[A-F0-9]{64}$') { throw 'invalid_approval' }
        foreach ($key in @('session_id','nonce','package','serial','apk_sha256','mode','expires_at')) {
            if ($State[$key] -cne $Approval[$key]) { throw 'state_approval_mismatch' }
        }
        if ($InstalledSha256 -cne $Approval.apk_sha256) { throw 'installed_apk_mismatch' }
        $approved = [datetimeoffset]::Parse($Approval.approved_at)
        $expires = [datetimeoffset]::Parse($Approval.expires_at)
        if ($approved -gt $Now -or $expires -le $Now -or $expires -le $approved -or
            ($expires-$approved).TotalHours -gt 3) { throw 'approval_expired_or_invalid' }
        if ($State.status -cne 'ACTIVE' -or $State.stop -isnot [bool] -or $State.stop -cne $false) { throw 'stop_or_inactive' }
        $heartbeat = [datetimeoffset]::Parse($State.supervisor_heartbeat_at)
        if ($heartbeat -gt $Now -or ($Now-$heartbeat).TotalSeconds -gt 15) { throw 'supervisor_not_present' }
        if (($State.http_requests -isnot [int] -and $State.http_requests -isnot [long]) -or $State.http_requests -lt 0 -or
            $State.http_requests -gt 60 -or ($State.http_in_minute -isnot [int] -and $State.http_in_minute -isnot [long]) -or
            $State.http_in_minute -lt 0 -or $State.http_in_minute -gt 12) { throw 'traffic_budget_invalid' }
        if ($Approval.mode -ceq 'cache_only') {
            if (-not $DeviceOffline -or $State.local_network_block_verified -isnot [bool] -or $State.local_network_block_verified -cne $true -or
                $State.http_requests -ne 0) { throw 'offline_isolation_missing' }
        } elseif ($Approval.mode -ceq 'stored_only') {
            if ($State.qa_stored_contract -cne 'v1' -or $State.production_health -cne 'GREEN') { throw 'stored_contract_or_health_unknown' }
            $healthAt = [datetimeoffset]::Parse($State.production_health_at)
            if ($healthAt -gt $Now -or ($Now-$healthAt).TotalSeconds -gt 120) { throw 'health_expired' }
        } else { throw 'mode_not_allowed' }
        return @{ allowed=$true; reason='approved_supervised_development' }
    } catch { $deny = $_.Exception.Message }
    return @{ allowed=$false; reason=$deny }
}

# Local integration seam for the EXISTING launcher + independent failsafe.
# No scheduler registration, process launch, approval creation or ADB here.
# Caller supplies the existing close-and-pid-confirm implementation. A crash,
# STOP or watchdog loss always takes the same final close path.
function Invoke-QaDevelopmentSession {
    param(
        [Parameter(Mandatory)][scriptblock]$Decision,
        [Parameter(Mandatory)][scriptblock]$WatchdogAlive,
        [Parameter(Mandatory)][scriptblock]$Heartbeat,
        [Parameter(Mandatory)][scriptblock]$Wait,
        [Parameter(Mandatory)][scriptblock]$CloseQa
    )
    $reason='session_ended';$closed=$false
    try {
        while ($true) {
            $d=& $Decision
            if ($d.allowed -cne $true) { $reason=$d.reason;break }
            if ((& $WatchdogAlive) -cne $true) { $reason='independent_watchdog_lost';break }
            & $Heartbeat | Out-Null
            & $Wait | Out-Null
        }
    } catch { $reason='controller_error: '+$_.Exception.Message }
    finally {
        try { $closed=((& $CloseQa $reason) -ceq $true) } catch { $closed=$false }
    }
    return @{status=$(if($closed){'CLOSED'}else{'CLOSE_NOT_CONFIRMED'});reason=$reason}
}
