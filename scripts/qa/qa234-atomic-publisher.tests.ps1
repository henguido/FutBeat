# Tests the actual staged publisher; no task, ADB, approval or app operations.
param([string]$PublisherPath='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'qa227-development-policy.ps1')
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$path=Join-Path $repo 'artifacts/qa227/controller-candidate/qa123-launcher.ps1'
if($PublisherPath){$path=$PublisherPath}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
$fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Write-AtomicJson'},$true)
if(-not $fn){throw 'Missing actual generated publisher'}
. ([scriptblock]::Create($fn.Extent.Text))
Add-Type -TypeDefinition @'
using System.IO;
using System.Threading;
using System.Threading.Tasks;
public static class Qa234Reader {
 public static Task ReleaseAfter(FileStream s, int milliseconds) {
  return Task.Run(() => { Thread.Sleep(milliseconds); s.Dispose(); });
 }
}
'@
$root=Join-Path ([IO.Path]::GetTempPath()) ('qa234-atomic-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root | Out-Null
$target=Join-Path $root 'heartbeat.json';$passed=0
try {
 Write-AtomicJson $target @{status='OLD'}
 $reader=[IO.File]::Open($target,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 $release=[Qa234Reader]::ReleaseAfter($reader,120)
 try {Write-AtomicJson $target @{status='READY'}}finally{$release.GetAwaiter().GetResult()}
 if((Get-Content $target -Raw|ConvertFrom-Json).status-cne'READY'){throw 'Transient reader lost publication'};$passed++
 $reader=[IO.File]::Open($target,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 $clock=[Diagnostics.Stopwatch]::StartNew();$denied=$false
 try {Write-AtomicJson $target @{status='MUST_NOT_PUBLISH'}}catch{$denied=$true}finally{$reader.Dispose()}
 if(-not $denied -or $clock.ElapsedMilliseconds-gt1500){throw 'Persistent lock must fail within bounded time'};$passed++
 if((Get-Content $target -Raw|ConvertFrom-Json).status-cne'READY'){throw 'Failed write changed last complete record'};$passed++
 Write-AtomicJson $target @{status='STOP'}
 if((Get-Content $target -Raw|ConvertFrom-Json).status-cne'STOP'){throw 'Subsequent STOP publication failed'};$passed++
} finally {
 foreach($f in Get-ChildItem -LiteralPath $root -File){Remove-Item -LiteralPath $f.FullName}
 Remove-Item -LiteralPath $root
}
"QA234 actual atomic publisher: $passed PASS; no task/device operations"
