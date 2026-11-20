# Run from a normal authorized Windows PowerShell 7 terminal.
# Uses the already-authorized exact SHA. Never prompts for secrets or changes security.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$releaseSha
)
$ErrorActionPreference = 'Stop'
$releaseRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$expectedRemoteSha = '46666f761c77945a96b2ede2d4012fac68bcb0e1'
$releaseBranch = 'codex/release-130-ci-play'
$releaseRepository = 'henguido/FutBeat'
$releaseUrl = 'https://github.com/henguido/FutBeat.git'
Set-Location -LiteralPath $releaseRoot
function Invoke-ReleaseNative {
    param([string]$Executable, [string[]]$Arguments)
    $result = & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed (exit $LASTEXITCODE); stopped without retry." }
    return $result
}
function New-ReleaseArtifactDirectory {
    param([Parameter(Mandatory)][string]$EvidencePath)
    $path = Join-Path $EvidencePath ('downloads/' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -ErrorAction Stop | Out-Null
    return $path
}
$current = Invoke-ReleaseNative 'git' @('rev-parse', 'HEAD')
if ($current -ne $releaseSha) { throw 'Unexpected local HEAD. Stop.' }
$branch = Invoke-ReleaseNative 'git' @('branch', '--show-current')
if ($branch -ne $releaseBranch) { throw 'Unexpected local branch. Stop.' }
$dirty = Invoke-ReleaseNative 'git' @('status', '--porcelain=v1', '--untracked-files=normal')
if ($dirty) { throw 'Worktree is not clean. Stop.' }
$parent = Invoke-ReleaseNative 'git' @('rev-parse', "${releaseSha}^")
if ($parent -ne $expectedRemoteSha) { throw 'Unexpected parent; stop.' }
$changedPaths = Invoke-ReleaseNative 'git' @('diff-tree', '--no-commit-id', '--name-only', '-r', $releaseSha)
$allowedPaths = @('.github/workflows/release-130-flutter.yml', 'scripts/release/Submit-Release130CI.ps1', 'docs/release/RELEASE-130.md')
if (@($changedPaths | Where-Object { $_ -notin $allowedPaths }).Count) { throw 'Unexpected changed path; stop.' }
$workflow = Get-Content '.github/workflows/release-130-flutter.yml' -Raw
if ($workflow -notmatch '(?m)^  push:\r?\n    branches:\r?\n      - codex/release-130-ci-play\r?$' -or
    $workflow -match '(?m)^  (workflow_dispatch|pull_request|schedule):' -or
    $workflow -match 'secrets\.|id-token:|flutter build|--update-goldens') {
    throw 'Unexpected workflow scope. Stop.'
}
# This is a host connectivity check; no DNS/proxy/firewall settings are changed.
[void][Net.Dns]::GetHostAddresses('github.com')
$null = Invoke-ReleaseNative 'curl.exe' @('--head', '--fail', '--silent', '--show-error', '--connect-timeout', '5', '--max-time', '15', 'https://github.com')
$remoteMain = Invoke-ReleaseNative 'gh' @('api', 'repos/henguido/FutBeat/commits/main', '--jq', '.sha')
if ($remoteMain -ne '99da8729660892dac76720a5732885fa039d5709') { throw 'Remote main changed since workflow review. Stop.' }
$prs = Invoke-ReleaseNative 'gh' @('pr', 'list', '--repo', $releaseRepository, '--head', $releaseBranch, '--state', 'open', '--json', 'number')
if (@(($prs -join "`n" | ConvertFrom-Json)).Count -ne 0) { throw 'An open PR could trigger additional CI. Stop.' }
$remote = Invoke-ReleaseNative 'git' @('ls-remote', '--heads', $releaseUrl, "refs/heads/$releaseBranch")
if ($remote) {
    $remoteSha = ($remote -split '\s+')[0]
    if ($remoteSha -eq $releaseSha) {
        Write-Output 'Exact authorized SHA is already remote; no new push.'
    } elseif ($remoteSha -eq $expectedRemoteSha) {
        Invoke-ReleaseNative 'git' @('push', '--no-follow-tags', $releaseUrl, "${releaseSha}:refs/heads/$releaseBranch")
    } else { throw 'Unexpected remote branch commit. Stop; no overwrite.' }
} else {
    throw 'Expected remote branch is missing. Stop.'
}
$confirmed = Invoke-ReleaseNative 'git' @('ls-remote', '--heads', $releaseUrl, "refs/heads/$releaseBranch")
if (($confirmed -split '\s+')[0] -ne $releaseSha) { throw 'Remote SHA confirmation failed. Stop.' }
$run = $null
for ($attempt = 0; $attempt -lt 6; $attempt++) {
    $runs = Invoke-ReleaseNative 'gh' @('run', 'list', '--repo', $releaseRepository, '--branch', $releaseBranch, '--commit', $releaseSha, '--event', 'push', '--limit', '20', '--json', 'databaseId,url,headSha,status,conclusion,workflowName')
    $parsed = @($runs -join "`n" | ConvertFrom-Json)
    if (@($parsed | Where-Object { $_.workflowName -ne 'Release 130 Flutter verification' }).Count) {
        throw 'An unexpected workflow was observed; stop and report its run.'
    }
    $run = $parsed | Where-Object { $_.workflowName -eq 'Release 130 Flutter verification' -and $_.headSha -eq $releaseSha } | Select-Object -First 1
    if ($run) { break }
    Start-Sleep -Seconds 5
}
if (-not $run) { throw 'Push confirmed, but no matching run is visible yet. Do not claim CI passed or push again.' }
$run | Select-Object databaseId,url,headSha,status,conclusion | ConvertTo-Json
Write-Output 'CI started/located. Test results must be collected after completion; this script does not build Android or deploy.'
$evidencePath = Join-Path $releaseRoot ".local-data/ci-$($run.databaseId)"
New-Item -ItemType Directory -Path $evidencePath -Force | Out-Null
& gh run watch $run.databaseId --repo $releaseRepository --exit-status
$watchExit = $LASTEXITCODE
$runEvidence = Invoke-ReleaseNative 'gh' @('run', 'view', "$($run.databaseId)", '--repo', $releaseRepository, '--json', 'headSha,status,conclusion,jobs,url')
$runEvidence | Set-Content -LiteralPath (Join-Path $evidencePath 'result.json') -Encoding utf8
if ((($runEvidence -join "`n") | ConvertFrom-Json).headSha -ne $releaseSha) { throw 'Run SHA mismatch; stop.' }
Invoke-ReleaseNative 'gh' @('run', 'view', "$($run.databaseId)", '--repo', $releaseRepository, '--log') | Set-Content -LiteralPath (Join-Path $evidencePath 'job.log') -Encoding utf8
# gh refuses to overwrite an existing extracted file. Each attempt gets an
# exclusive directory; previous evidence remains intact, including partial ZIPs.
$downloadPath = New-ReleaseArtifactDirectory -EvidencePath $evidencePath
Invoke-ReleaseNative 'gh' @('run', 'download', "$($run.databaseId)", '--repo', $releaseRepository, '--name', "release-130-flutter-$releaseSha", '--dir', $downloadPath)
Write-Output "Artifact extracted without overwrites: $downloadPath"
Write-Output "Evidence saved: $evidencePath"
if ($watchExit -ne 0) { throw 'CI not successful. Evidence saved; do not generate AAB.' }
