# Runs Flutter from an existing installation or the SDK prepared beside this repo.
$ErrorActionPreference = 'Stop'
$taskSdk = Join-Path $PSScriptRoot '../../.tools/flutter/bin/flutter.bat'
$taskFlutter = Get-Command flutter -ErrorAction SilentlyContinue
if ($taskFlutter) { $taskSdk = $taskFlutter.Source }
if (-not (Test-Path -LiteralPath $taskSdk)) { throw 'Instala Flutter 3.47.4 o añádelo al PATH.' }
$taskArguments = $args
if ($taskArguments.Count -eq 0) { $taskArguments = @('run') }
$taskTrust = Join-Path $PSScriptRoot '../../.tools/java-cacerts'
$taskPreviousJavaOptions = $env:JAVA_TOOL_OPTIONS
Push-Location (Join-Path $PSScriptRoot '../apps/mobile')
try {
  if (Test-Path -LiteralPath $taskTrust) {
    $taskTrustPath = (Resolve-Path -LiteralPath $taskTrust).Path
    $env:JAVA_TOOL_OPTIONS = "$taskPreviousJavaOptions -Djavax.net.ssl.trustStore=$taskTrustPath -Djavax.net.ssl.trustStorePassword=changeit"
  }
  & $taskSdk @taskArguments
  if ($LASTEXITCODE -ne 0) { throw "Flutter terminó con código $LASTEXITCODE" }
} finally {
  $env:JAVA_TOOL_OPTIONS = $taskPreviousJavaOptions
  Pop-Location
}
