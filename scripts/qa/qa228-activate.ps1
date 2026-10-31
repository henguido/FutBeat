# Reusable owner-authorized offline trial (QA228 defaults). No new task or app launch.
param([Parameter(Mandatory)][ValidateSet('Deploy','Arm')][string]$Mode,[ValidateSet('NORMAL','FAILSAFE')][string]$SessionSuffix='NORMAL', [ValidatePattern('^QA[0-9]{3}$')][string]$TrialName='QA228', [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedApkSha256='56785DC431B0706E349639AF1AE35610DF99964225D5A04C798331862DD22280')
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $PSScriptRoot 'qa228-trial-validation.ps1')
$root=Join-Path $repo ('artifacts/'+$TrialName.ToLowerInvariant());$candidate=Join-Path $repo 'artifacts/qa227/controller-candidate'
$m=Get-Content (Join-Path $root 'rollback-manifest.json') -Raw|ConvertFrom-Json
$q=$m.qa_root;$task='FutBeat-QA123-Launcher';$adb='C:\Users\hen_g\AppData\Local\Android\Sdk\platform-tools\adb.exe'
$expected=$ExpectedApkSha256.ToUpperInvariant()
function AtomicPrivate([string]$Path,[object]$Value){
    $tmp="$Path.qa228.tmp";[IO.File]::WriteAllText($tmp,($Value|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
    $acl=[Security.AccessControl.FileSecurity]::new();$acl.SetAccessRuleProtection($true,$false)
    $owner=[Security.Principal.WindowsIdentity]::GetCurrent().User;$acl.SetOwner($owner)
    foreach($sid in @($owner,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'),[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','Allow'))}
    Set-Acl -LiteralPath $tmp -AclObject $acl;[IO.File]::Move($tmp,$Path,$true)
}
function Check {
    if(Test-Path (Join-Path $root 'restore-result.json')){throw 'Trial already restored'}
    $guard=Get-Content (Join-Path $root 'guard-process.json') -Raw|ConvertFrom-Json -DateKind String
    $gp=Get-Process -Id $guard.pid -ErrorAction Stop
    if([Math]::Abs(($gp.StartTime.ToUniversalTime()-[datetime]::Parse($guard.started_at).ToUniversalTime()).TotalSeconds) -gt 1){throw 'Rollback process identity changed'}
    $at=[datetimeoffset]::Parse((Get-Content (Join-Path $root 'guard-heartbeat.txt') -Raw).Trim())
    if(([datetimeoffset]::UtcNow-$at).TotalSeconds -gt 8){throw 'Rollback heartbeat stale'}
    if(((& $adb -s RF8R32GQWGL get-state) -join '').Trim() -ne 'device'){throw 'ADB unavailable'}
    if(((& $adb -s RF8R32GQWGL shell getprop ro.product.model) -join '').Trim() -ne 'SM-A325M'){throw 'Wrong device'}
    $qaPid=((& $adb -s RF8R32GQWGL shell pidof com.futbeat.futbeat.qa)-join'').Trim();if($qaPid){throw 'QA active before activation'}
    $net=(& $adb -s RF8R32GQWGL shell dumpsys connectivity)-join"`n";if($net -notmatch 'Active default network:\s*none'){throw 'Phone has a network'}
    $path=((& $adb -s RF8R32GQWGL shell pm path com.futbeat.futbeat.qa)-join'').Trim().Replace('package:','')
    $sha=((& $adb -s RF8R32GQWGL shell sha256sum $path)-split' ')[0].ToUpperInvariant();if($sha -cne $expected){throw 'Wrong installed offline APK'}
}
Check
try{
    if($Mode -eq 'Deploy'){
        foreach($f in $m.files){if($f.existed -and ((Get-FileHash (Join-Path $q $f.name) -Algorithm SHA256).Hash -cne $f.hash)){throw 'QA123 baseline changed'}}
        Stop-ScheduledTask -TaskName $task
        for($i=0;$i -lt 15 -and (Get-ScheduledTask -TaskName $task).State -eq 'Running';$i++){Start-Sleep 1}
        if((Get-ScheduledTask -TaskName $task).State -eq 'Running'){throw 'Original task did not stop'}
        foreach($name in @('qa123-launcher.ps1','qa123-failsafe.ps1','qa227-development-policy.ps1')){Copy-Item -LiteralPath (Join-Path $candidate $name) -Destination (Join-Path $q $name) -Force}
        $started=[datetimeoffset]::UtcNow;Start-ScheduledTask -TaskName $task
        for($i=0;$i -lt 180;$i++){Start-Sleep 1;$hb=Get-Content (Join-Path $q 'qa123-launcher-heartbeat.json') -Raw|ConvertFrom-Json;$owner=Get-Process -Id ([int]$hb.launcher_pid) -ErrorAction SilentlyContinue;if(Test-QaTrialLauncherHeartbeat -Heartbeat $hb -Process $owner -TaskStarted $started -Now ([datetimeoffset]::UtcNow)){break}}
        if(-not (Test-QaTrialLauncherHeartbeat -Heartbeat $hb -Process (Get-Process -Id ([int]$hb.launcher_pid) -ErrorAction SilentlyContinue) -TaskStarted $started -Now ([datetimeoffset]::UtcNow))){throw 'Candidate did not start disarmed'}
        "DEPLOYED_TEMPORARILY status=$($hb.status) pid=$($hb.launcher_pid)";exit
    }
    foreach($name in @('qa123-launcher.ps1','qa123-failsafe.ps1','qa227-development-policy.ps1')){if((Get-FileHash (Join-Path $q $name) -Algorithm SHA256).Hash -cne (Get-FileHash (Join-Path $candidate $name) -Algorithm SHA256).Hash){throw 'Candidate source mismatch'}}
    if(Test-Path (Join-Path $q 'qa123-active-window.json')){throw 'An active ledger exists'}
    foreach($name in @('qa227-development-approval.json','qa227-development-state.json','qa227-supervisor-heartbeat.json','qa227-close.json','qa227-failsafe-evidence.json','qa227-failsafe-ready.json')){
        $path=Join-Path $q $name;if(Test-Path $path){$record=Get-Content $path -Raw|ConvertFrom-Json;if($record.session_id -like ('QADEV-'+$TrialName+'-*') -or $record.window_id -like ('QADEV-'+$TrialName+'-*')){Copy-Item $path (Join-Path $root ('prior-'+$name)) -Force;Remove-Item -LiteralPath $path}else{throw "Foreign state: $name"}}
    }
    $now=[datetimeoffset]::UtcNow;$id='QADEV-'+$TrialName+'-'+$now.ToString('yyyyMMddTHHmmssZ')+'-'+$SessionSuffix
    $nonce=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16)).ToLowerInvariant()
    $a=@{schema='qa-development-v1';approved=$true;approved_by='user';session_id=$id;nonce=$nonce;package='com.futbeat.futbeat.qa';serial='RF8R32GQWGL';apk_sha256=$expected;mode='cache_only';approved_at=$now.ToString('o');expires_at=$now.AddMinutes(20).ToString('o')}
    $s=@{};foreach($key in @('session_id','nonce','package','serial','apk_sha256','mode','expires_at')){$s[$key]=$a[$key]}
    $s.status='ACTIVE';$s.stop=$false;$s.supervisor_heartbeat_at=$now.ToString('o');$s.http_requests=0;$s.http_in_minute=0;$s.local_network_block_verified=$true
    AtomicPrivate (Join-Path $q 'qa227-development-approval.json') $a
    AtomicPrivate (Join-Path $q 'qa227-development-state.json') $s
    for($i=0;$i -lt 180;$i++){Start-Sleep 1;$hb=Get-Content (Join-Path $q 'qa123-launcher-heartbeat.json') -Raw|ConvertFrom-Json;if($hb.status -ceq 'QADEV_CACHE_ONLY' -and $hb.window_id -ceq $id){break}}
    if($hb.status -cne 'QADEV_CACHE_ONLY' -or $hb.window_id -cne $id){throw "Candidate did not own session: $($hb.status)"}
    $guards=@(Get-CimInstance Win32_Process|Where-Object{$_.CommandLine -match 'qa123-failsafe\.ps1' -and $_.CommandLine -match [regex]::Escape($id)})
    if($guards.Count -ne 1){throw "Expected one independent failsafe, got $($guards.Count)"}
    $session=@{session_id=$id;apk_sha=$expected;expires_at=$a.expires_at;watchdog_pid=$guards[0].ProcessId;launcher_pid=$hb.launcher_pid}
    $session|ConvertTo-Json|Set-Content (Join-Path $root 'current-session.json')
    $id|Set-Content (Join-Path $root 'ARMED');$session|ConvertTo-Json
}catch{
    'activation_failed'|Set-Content (Join-Path $root 'REQUEST-RESTORE')
    throw
}
