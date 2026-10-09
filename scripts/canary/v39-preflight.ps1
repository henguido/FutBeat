param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^[a-z]{20}$')]
  [string]$StagingProjectRef,
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^\d{4}-\d{2}-\d{2}$')]
  [string]$Date,
  [ValidateSet('goal_api')]
  [string]$Provider = 'goal_api',
  [ValidateRange(1, 5000)]
  [int]$MaxFixtures = 2000,
  [ValidateRange(1, 300)]
  [int]$StatementTimeoutSeconds = 90,
  [string]$ManifestPath
)

$ErrorActionPreference = 'Stop'
$productionRef = 'izlmruqawgagwdcsjhte'
$startedAt = [DateTimeOffset]::UtcNow

if ($StagingProjectRef -eq $productionRef) {
  throw 'REFUSED: the requested project ref is production.'
}

$parsedDate = [DateTime]::MinValue
if (-not [DateTime]::TryParseExact(
    $Date,
    'yyyy-MM-dd',
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::None,
    [ref]$parsedDate
  )) {
  throw 'REFUSED: Date must be a real UTC calendar date in yyyy-MM-dd format.'
}

$linkedRefPath = Join-Path $PSScriptRoot '..\..\supabase\.temp\project-ref'
$linkedRef = $null
if (Test-Path -LiteralPath $linkedRefPath) {
  $linkedRef = (Get-Content -LiteralPath $linkedRefPath -Raw).Trim()
  if ($linkedRef -eq $productionRef) {
    throw 'REFUSED: the local Supabase link points to production. Unlink it before staging work.'
  }
  if ($linkedRef -and $linkedRef -ne $StagingProjectRef) {
    throw 'REFUSED: the local Supabase link does not match the expected staging ref.'
  }
}

$finishedAt = [DateTimeOffset]::UtcNow
$manifest = [ordered]@{
  schemaVersion = 1
  status = 'SAFE_LOCAL_PREFLIGHT_ONLY'
  expectedProjectRef = $StagingProjectRef
  productionRefRejected = $true
  linkedProject = if ($linkedRef) { 'matching-staging' } else { 'not-linked' }
  provider = $Provider
  dateUtc = $parsedDate.ToString('yyyy-MM-dd')
  maxFixtures = $MaxFixtures
  statementTimeoutSeconds = $StatementTimeoutSeconds
  startedAtUtc = $startedAt.ToString('o')
  finishedAtUtc = $finishedAt.ToString('o')
  remoteOperationExecuted = $false
}

$json = $manifest | ConvertTo-Json -Depth 4
if ($ManifestPath) {
  $parent = Split-Path -Parent $ManifestPath
  if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent | Out-Null
  }
  Set-Content -LiteralPath $ManifestPath -Value $json -Encoding utf8
}
$json
