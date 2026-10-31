# Temporary rollback guard for the owner-authorized QA228 offline trial.
# Reuses the QA225 ordering: close QA -> verify PID/device -> restore QA123.
# No new scheduled task, no remote operation, no app launch.
param([Parameter(Mandatory)][ValidateSet('Backup','Guard','Restore','Verify')][string]$Mode)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$runRoot=Join-Path $repo 'artifacts/qa228'
$backup=Join-Path $runRoot 'backup'
$q='C:\Users\hen_g\.codex\visualizations\2026\10\08\01a11d81-14eb-7170-966a-ead982b2856f\qa123'
$adb='C:\Users\hen_g\AppData\Local\Android\Sdk\platform-tools\adb.exe'
$taskName='FutBeat-QA123-Launcher'
$manifestPath=Join-Path $runRoot 'rollback-manifest.json'
function Adb([string[]]$Arguments){
    $si=[Diagnostics.ProcessStartInfo]::new($adb);$si.UseShellExecute=$false;$si.CreateNoWindow=$true
    $si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
    foreach($arg in $Arguments){[void]$si.ArgumentList.Add($arg)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$si
    try{[void]$p.Start();$o=$p.StandardOutput.ReadToEndAsync();$e=$p.StandardError.ReadToEndAsync()
        if(-not $p.WaitForExit(5000)){$p.Kill($true);throw 'ADB timeout'}
        return @{code=$p.ExitCode;output=$o.GetAwaiter().GetResult().Trim();error=$e.GetAwaiter().GetResult().Trim()}
    }finally{$p.Dispose()}
}
function Log([string]$Message){[IO.File]::AppendAllText((Join-Path $runRoot 'rollback.log'),[datetimeoffset]::UtcNow.ToString('o')+' '+$Message+[Environment]::NewLine)}
function Xml { ((Export-ScheduledTask -TaskName $taskName) -replace "`r",'').TrimEnd() }
function SaveJson([string]$Path,[object]$Value){$tmp="$Path.tmp.$PID";[IO.File]::WriteAllText($tmp,($Value|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false));[IO.File]::Move($tmp,$Path,$true)}
if($Mode -eq 'Backup'){
    if(Test-Path $manifestPath){throw 'Existing QA228 backup: preserve it; do not overwrite'}
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    if((Adb @('-s','RF8R32GQWGL','get-state')).output -ne 'device'){throw 'Device unavailable'}
    $app=Adb @('-s','RF8R32GQWGL','shell','pidof','com.futbeat.futbeat.qa')
    if($app.code -ne 1 -or $app.output){throw 'QA not confirmed closed'}
    foreach($name in @('qa123-active-window.json','qa123-pending-close.json','qa227-development-approval.json','qa227-development-state.json','qa227-supervisor-heartbeat.json')){if(Test-Path (Join-Path $q $name)){throw "Existing operational state: $name"}}
    $files=@();foreach($name in @('qa123-launcher.ps1','qa123-failsafe.ps1','qa227-development-policy.ps1')){
        $path=Join-Path $q $name;$exists=Test-Path $path
        if($exists){Copy-Item -LiteralPath $path -Destination (Join-Path $backup $name)}
        $files+=@{name=$name;existed=$exists;hash=$(if($exists){(Get-FileHash $path -Algorithm SHA256).Hash}else{''});sddl=$(if($exists){(Get-Acl $path).Sddl}else{''})}
    }
    Xml | Set-Content (Join-Path $backup 'task.xml') -Encoding utf8NoBOM
    $m=@{qa_root=$q;files=$files;task_state=(Get-ScheduledTask -TaskName $taskName).State.ToString();created_at=[datetimeoffset]::UtcNow.ToString('o');expires_at=[datetimeoffset]::UtcNow.AddMinutes(45).ToString('o');wifi=(Adb @('-s','RF8R32GQWGL','shell','settings','get','global','wifi_on')).output;mobile_data=(Adb @('-s','RF8R32GQWGL','shell','settings','get','global','mobile_data')).output;airplane=(Adb @('-s','RF8R32GQWGL','shell','settings','get','global','airplane_mode_on')).output}
    SaveJson $manifestPath $m;Log 'BACKUP_CREATED';$m|ConvertTo-Json -Depth 6;exit
}
$m=Get-Content $manifestPath -Raw | ConvertFrom-Json
if($m.qa_root -cne $q){throw 'Rollback target mismatch'}
function Verify {
    $same=$true;foreach($f in $m.files){$path=Join-Path $q $f.name;if($f.existed){$same=$same -and (Test-Path $path) -and ((Get-FileHash $path -Algorithm SHA256).Hash -ceq $f.hash) -and ((Get-Acl $path).Sddl -ceq $f.sddl)}else{$same=$same -and -not (Test-Path $path)}}
    $xmlSame=(Xml) -ceq ((Get-Content (Join-Path $backup 'task.xml') -Raw) -replace "`r",'').TrimEnd()
    $hb=Get-Content (Join-Path $q 'qa123-launcher-heartbeat.json') -Raw | ConvertFrom-Json
    $age=([datetimeoffset]::UtcNow-[datetimeoffset]::Parse($hb.updated_at)).TotalSeconds
    $state=(Get-ScheduledTask -TaskName $taskName).State.ToString()
    $app=Adb @('-s','RF8R32GQWGL','shell','pidof','com.futbeat.futbeat.qa');$device=Adb @('-s','RF8R32GQWGL','get-state')
    return @{files_same=$same;task_xml_same=$xmlSame;task_state=$state;heartbeat=$hb.status;heartbeat_age_s=[int]$age;app_closed=($app.code -eq 1 -and -not $app.output -and $device.code -eq 0 -and $device.output -eq 'device');ok=($same -and $xmlSame -and $state -eq $m.task_state -and $hb.status -like 'DISARMED*' -and $age -le 15 -and $app.code -eq 1 -and -not $app.output -and $device.output -eq 'device')}
}
function Restore {
    $mutex=[Threading.Mutex]::new($false,'Local\FutBeatQa228Rollback')
    if(-not $mutex.WaitOne(0)){$mutex.Dispose();return $false}
    try{
        foreach($f in $m.files){if($f.existed -and ((Get-FileHash (Join-Path $backup $f.name) -Algorithm SHA256).Hash -cne $f.hash)){throw 'Backup hash mismatch'}}
        $stop=Adb @('-s','RF8R32GQWGL','shell','am','force-stop','com.futbeat.futbeat.qa');$app=Adb @('-s','RF8R32GQWGL','shell','pidof','com.futbeat.futbeat.qa');$device=Adb @('-s','RF8R32GQWGL','get-state')
        if($stop.code -ne 0 -or $app.code -ne 1 -or $app.output -or $device.code -ne 0 -or $device.output -ne 'device'){Log 'CLOSE_NOT_CONFIRMED: leaving safety scripts in place';return $false}
        Stop-ScheduledTask -TaskName $taskName
        for($i=0;$i -lt 15 -and (Get-ScheduledTask -TaskName $taskName).State -eq 'Running';$i++){Start-Sleep 1}
        if((Get-ScheduledTask -TaskName $taskName).State -eq 'Running'){throw 'Task did not stop'}
        # A child failsafe may survive the launcher. Only our QADEV-QA228 guard
        # can be stopped, and only after physical app closure was confirmed.
        Get-CimInstance Win32_Process | Where-Object {$_.CommandLine -match 'qa123-failsafe\.ps1' -and $_.CommandLine -match 'QADEV-QA228-' -and $_.CommandLine -match '\-DevelopmentStateRoot'} | ForEach-Object {Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue}
        foreach($f in $m.files){$path=Join-Path $q $f.name;if($f.existed){Copy-Item -LiteralPath (Join-Path $backup $f.name) -Destination $path -Force;$acl=Get-Acl $path;$acl.SetSecurityDescriptorSddlForm($f.sddl);Set-Acl -LiteralPath $path -AclObject $acl}else{Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue}}
        foreach($name in @('qa227-development-approval.json','qa227-development-state.json','qa227-supervisor-heartbeat.json','qa227-close.json','qa227-failsafe-evidence.json','qa123-active-window.json','qa123-pending-close.json')){
            $path=Join-Path $q $name;if(-not (Test-Path $path)){continue}
            $record=Get-Content $path -Raw | ConvertFrom-Json
            if($record.session_id -like 'QADEV-QA228-*' -or $record.window_id -like 'QADEV-QA228-*'){
                Copy-Item -LiteralPath $path -Destination (Join-Path $runRoot ('final-'+$name)) -Force
                Remove-Item -LiteralPath $path
            }else{throw "Foreign operational state preserved: $name"}
        }
        if($m.task_state -eq 'Running'){Start-ScheduledTask -TaskName $taskName}
        for($i=0;$i -lt 30;$i++){Start-Sleep 1;$hb=Get-Content (Join-Path $q 'qa123-launcher-heartbeat.json') -Raw | ConvertFrom-Json;if($hb.status -like 'DISARMED*' -and ([datetimeoffset]::UtcNow-[datetimeoffset]::Parse($hb.updated_at)).TotalSeconds -lt 8){break}}
        # Network restoration is after app closure, never while QA is active.
        $airplane=if($m.airplane -eq '1'){'enable'}else{'disable'}
        Adb @('-s','RF8R32GQWGL','shell','cmd','connectivity','airplane-mode',$airplane) | Out-Null
        $wifi=if($m.wifi -eq '1'){'enable'}else{'disable'};$data=if($m.mobile_data -eq '1'){'enable'}else{'disable'}
        Adb @('-s','RF8R32GQWGL','shell','svc','wifi',$wifi) | Out-Null;Adb @('-s','RF8R32GQWGL','shell','svc','data',$data) | Out-Null
        $result=Verify;SaveJson (Join-Path $runRoot 'restore-result.json') $result;Log ('RESTORED '+($result|ConvertTo-Json -Compress));return $true
    }finally{$mutex.ReleaseMutex();$mutex.Dispose()}
}
if($Mode -eq 'Verify'){Verify|ConvertTo-Json;exit}
if($Mode -eq 'Restore'){if(-not (Restore)){exit 2};exit}
Log 'GUARD_STARTED'
$controllerLostAt=$null
while(-not (Test-Path (Join-Path $runRoot 'restore-result.json'))){
    [IO.File]::WriteAllText((Join-Path $runRoot 'guard-heartbeat.txt'),[datetimeoffset]::UtcNow.ToString('o'))
    $expired=[datetimeoffset]::UtcNow -ge [datetimeoffset]::Parse($m.expires_at)
    $controllerLost=$false
    if(Test-Path (Join-Path $runRoot 'ARMED')){
        try{$hb=Get-Content (Join-Path $q 'qa123-launcher-heartbeat.json') -Raw|ConvertFrom-Json;$controllerLost=(Get-ScheduledTask -TaskName $taskName).State -ne 'Running' -or ([datetimeoffset]::UtcNow-[datetimeoffset]::Parse($hb.updated_at)).TotalSeconds -gt 20}catch{$controllerLost=$true}
    }
    if($controllerLost -and -not $controllerLostAt){$controllerLostAt=[datetimeoffset]::UtcNow;Log 'CONTROLLER_LOST: allowing independent failsafe up to 10 s before rollback fallback'}
    $emergency=$controllerLostAt -and ([datetimeoffset]::UtcNow-$controllerLostAt).TotalSeconds -ge 10
    $testMarker=Join-Path $runRoot 'FAILSAFE-TEST-STARTED.json'
    if(Test-Path $testMarker){
        $test=Get-Content $testMarker -Raw|ConvertFrom-Json -DateKind String
        $session=Get-Content (Join-Path $runRoot 'current-session.json') -Raw|ConvertFrom-Json -DateKind String
        if($test.session_id -ceq $session.session_id -and $test.session_id -like 'QADEV-QA228-*' -and ([datetimeoffset]::UtcNow-[datetimeoffset]::Parse($test.started_at)).TotalSeconds -ge 12){$emergency=$true}
    }
    if($expired -or $emergency -or (Test-Path (Join-Path $runRoot 'REQUEST-RESTORE'))){
        Log 'GUARD_RESTORE_REQUESTED';try{if(Restore){break}}catch{Log ('RESTORE_ERROR '+$_.Exception.Message)}
    }
    Start-Sleep -Seconds 2
}
Log 'GUARD_EXITED'
