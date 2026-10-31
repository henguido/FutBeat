# Actual staged ADB wrapper with an isolated fake executable; no device/task.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'qa227-development-policy.ps1')
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'artifacts/qa227/controller-candidate/qa123-launcher.ps1'),[ref]$null,[ref]$null)
$fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq'Invoke-AdbBounded'},$true)
if(-not$fn){throw 'Actual wrapper absent'}
. ([scriptblock]::Create($fn.Extent.Text))
$root=Join-Path ([IO.Path]::GetTempPath()) ('qa234-process-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root|Out-Null
$source=Join-Path $root 'fake.cs';$adb=Join-Path $root 'fake.exe';$ledger=Join-Path $root 'child.txt';$passed=0
@'
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
public class Fake {
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct SI {
  public int cb; public string reserved,desktop,title; public int x,y,xs,ys,xc,yc,fill,flags;
  public short show,reserved2; public IntPtr bytes,input,output,error;
 }
 [StructLayout(LayoutKind.Sequential)] struct PI {public IntPtr process,thread;public int pid,tid;}
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcess(string app,string command,IntPtr pa,IntPtr ta,bool inherit,int flags,IntPtr env,string dir,ref SI si,out PI pi);
 [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 public static int Main(string[] args) {
  if(args[0]=="child") {Thread.Sleep(6000);return 0;}
  if(args[0]=="sleep") {Thread.Sleep(6000);return 0;}
  if(args[0]=="normal") {Console.WriteLine("device");Console.Error.WriteLine("diagnostic");return 0;}
  if(args[0]=="empty") {return 1;}
  if(args[0]=="inherited") {
   string exe=Process.GetCurrentProcess().MainModule.FileName;
   SI si=new SI();si.cb=Marshal.SizeOf(si);si.flags=0x100;si.input=GetStdHandle(-10);si.output=GetStdHandle(-11);si.error=GetStdHandle(-12);
   PI pi;if(!CreateProcess(null,"\""+exe+"\" child",IntPtr.Zero,IntPtr.Zero,true,0x08000000,IntPtr.Zero,null,ref si,out pi))throw new Exception("CreateProcess "+Marshal.GetLastWin32Error());
   using(Process child=Process.GetProcessById(pi.pid)){File.WriteAllText(args[1],pi.pid+"|"+child.StartTime.ToUniversalTime().Ticks);}
   CloseHandle(pi.thread);CloseHandle(pi.process);Console.WriteLine("device");return 0;
  }
  return 7;
 }
}
'@|Set-Content $source
try {
 & 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe' /nologo /out:$adb $source
 if($LASTEXITCODE-ne0){throw 'Fake compilation failed'}
 $r=Invoke-AdbBounded -Arguments @('normal') -TimeoutMs 5000
 if($r.exit_code-ne0 -or $r.output.Trim()-cne'device'){throw 'Normal response lost'};$passed++
 $r=Invoke-AdbBounded -Arguments @('empty') -TimeoutMs 5000
 if($r.exit_code-ne1 -or $r.output){throw 'Legitimate pidof absence lost'};$passed++
 $failure=''
 try{$null=Invoke-AdbBounded -Arguments @('invalid') -TimeoutMs 5000}catch{$failure=$_.Exception.Message}
 if($failure-cne'adb_failed'){throw 'Unexpected ADB exit must fail closed'};$passed++
 $clock=[Diagnostics.Stopwatch]::StartNew();$failure=''
 try{$null=Invoke-AdbBounded -Arguments @('inherited',$ledger) -TimeoutMs 2000}catch{$failure=$_.Exception.Message}
 if($failure-notmatch'adb_stream_timeout' -or $clock.ElapsedMilliseconds-gt3000){throw "Unbounded inherited output: $($clock.ElapsedMilliseconds) ms, '$failure'"};$passed++
 $parts=(Get-Content $ledger -Raw).Split('|');$child=Get-Process -Id ([int]$parts[0]) -ErrorAction Stop
 if($child.StartTime.ToUniversalTime().Ticks-ne[long]$parts[1] -or $child.Path-cne$adb){throw 'Descendant identity mismatch'};$passed++
 $clock.Restart();$failure=''
 try{$null=Invoke-AdbBounded -Arguments @('sleep') -TimeoutMs 800}catch{$failure=$_.Exception.Message}
 if($failure-notmatch'adb_process_timeout' -or $clock.ElapsedMilliseconds-gt1800){throw 'Process timeout not bounded'};$passed++
}finally{
 if(Test-Path $ledger){$parts=(Get-Content $ledger -Raw).Split('|');$child=Get-Process -Id ([int]$parts[0]) -ErrorAction SilentlyContinue;if($child -and $child.Path-ceq$adb -and $child.StartTime.ToUniversalTime().Ticks-eq[long]$parts[1]){Stop-Process -Id $child.Id;$null=$child.WaitForExit(1000)}}
 # Windows may briefly retain the image mapping after the verified child
 # exits. Retry only cleanup of this test's exact files, never skip checks.
 foreach($f in Get-ChildItem -LiteralPath $root -File){
  $cleanupClock=[Diagnostics.Stopwatch]::StartNew()
  while($true){
   try{Remove-Item -LiteralPath $f.FullName -ErrorAction Stop;break}
   catch{if($cleanupClock.ElapsedMilliseconds-ge2000){throw};Start-Sleep -Milliseconds 100}
  }
 }
 Remove-Item -LiteralPath $root
}
"MOBILE234 actual process wrapper: $passed PASS; no ADB/task operations"
