import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// BE-173: runs the real global-fixtures step script under pwsh with every HTTP call mocked
// (no GOAL, no Supabase). 10-30 00:57 UTC the hot window store hit 57014 and, with
// $ErrorActionPreference = "Stop", the run ended before the cold calendar expansion.
const workflow = await readFile(new URL('../../.github/workflows/global-fixtures.yml', import.meta.url), 'utf8');
const lines = workflow.split(/\r?\n/);
const start = lines.findIndex((l) => /^\s+run: \|\s*$/.test(l));
const indent = ' '.repeat(lines[start].indexOf('run:') + 2);
const body = [];
for (const l of lines.slice(start + 1)) {
  if (l.trim() !== '' && !l.startsWith(indent)) break;
  body.push(l.slice(indent.length));
}
const pwsh = spawnSync('pwsh', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.Major'], { encoding: 'utf8' });
const skip = pwsh.status === 0 ? false : 'pwsh not available';

// Mock of every Invoke-RestMethod the script makes. GOAL pages consume one call each and
// report X-RateLimit-Remaining; the plan returns MOCK_PLAN on the requested-only call.
const mock = String.raw`
$script:mockRemaining = [int]$env:MOCK_START_REMAINING
function Invoke-RestMethod {
  param([string]$Uri, [string]$Method, $Headers, [string]$ContentType, [string]$Body, [int]$TimeoutSec, [string]$ResponseHeadersVariable)
  if ($Uri -like '*audience=futbeat-global-ingest*') { return [pscustomobject]@{ value = 'oidc-token' } }
  if ($Uri -like 'https://api.goal-api.com/*') {
    $script:mockRemaining -= 1
    Set-Variable -Name $ResponseHeadersVariable -Value @{ 'X-RateLimit-Remaining' = @([string]$script:mockRemaining) } -Scope 1
    $date = ($Uri -split '/date/')[1].Split('?')[0]
    $data = @(1, 2 | ForEach-Object { [pscustomobject]@{ apiId = "$date-$_"; kickoffUtc = "$($date)T18:00:00Z" } })
    return [pscustomobject]@{ success = $true; data = $data; pagination = [pscustomobject]@{ hasMore = $false; limit = 100 } }
  }
  $p = $Body | ConvertFrom-Json
  if ($p.action -eq 'global-quota-plan') {
    return [pscustomobject]@{ status = 'ok'; plan = [pscustomobject]@{ providerRemaining = $script:mockRemaining; reason = 'ok' } }
  }
  if ($p.action -eq 'calendar-plan') {
    $dates = if ($p.requestedOnly -and $env:MOCK_PLAN) { @($env:MOCK_PLAN -split ',') } else { @() }
    return [pscustomobject]@{ dates = $dates }
  }
  if ($p.mode -eq 'hot') {
    Write-Host "MOCK_HOT events=$(@($p.events).Count)"
    if ($env:MOCK_HOT_FAIL -eq '1') { throw 'Response status code does not indicate success: 500 (57014)' }
    return [pscustomobject]@{ accepted = @($p.events).Count }
  }
  if ($p.mode -eq 'calendar') {
    if ($env:MOCK_CAL_FAIL -and @($p.dates | Where-Object { @($env:MOCK_CAL_FAIL -split ',') -contains $_ }).Count -gt 0) { throw 'Response status code does not indicate success: 500' }
    Write-Host "MOCK_CAL dates=$(@($p.dates) -join ',') events=$(@($p.events).Count)"
    if ($env:MOCK_NO_DEFERRED -eq '1') { return [pscustomobject]@{ accepted = @($p.events).Count } }
    return [pscustomobject]@{ accepted = @($p.events).Count; deferredDates = @() }
  }
  throw "unexpected call $Uri $Body"
}
`;

async function run(env) {
  const dir = await mkdtemp(join(tmpdir(), 'futbeat-wf-'));
  try {
    const file = join(dir, 'step.ps1');
    await writeFile(file, mock + '\n' + body.join('\n'), 'utf8');
    const r = spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-Command', `. '${file}'`], {
      encoding: 'utf8',
      timeout: 120000,
      env: {
        ...process.env,
        GOAL_API_KEY: 'test-key',
        ACTIONS_ID_TOKEN_REQUEST_URL: 'https://oidc.invalid/token?x=1',
        ACTIONS_ID_TOKEN_REQUEST_TOKEN: 'test-token',
        GITHUB_EVENT_NAME: 'schedule',
        MOCK_START_REMAINING: '1000',
        MOCK_PLAN: '',
        MOCK_HOT_FAIL: '0',
        MOCK_CAL_FAIL: '',
        ...env,
      },
    });
    const out = `${r.stdout}\n${r.stderr}`;
    const fetched = [...out.matchAll(/CALENDAR_FETCH date=(\S+) .*?remaining=(\d+)/g)].map((m) => ({ date: m[1], remaining: Number(m[2]) }));
    const stored = [...out.matchAll(/MOCK_CAL dates=(\S+)/g)].map((m) => m[1]);
    return { code: r.status, out, fetched, stored };
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

test('a failed hot store no longer blocks the calendar expansion; the run still fails', { skip }, async () => {
  const r = await run({ MOCK_HOT_FAIL: '1', MOCK_PLAN: '2026-10-31,2026-11-01,2026-11-02' });
  assert.match(r.out, /GLOBAL_INGEST_FAILED provider=GOAL_API/);
  assert.match(r.out, /CALENDAR_EXPAND_GATE expand=True/);
  assert.deepEqual(r.stored, ['2026-10-31', '2026-11-01', '2026-11-02'], 'one ingest call per date, in plan order');
  assert.match(r.out, /GLOBAL_RUN_FAILED stage=hot/);
  assert.equal(r.code, 1);
});

test('hot store failure with nothing to expand still exits 1', { skip }, async () => {
  const r = await run({ MOCK_HOT_FAIL: '1' });
  assert.match(r.out, /CALENDAR_EXPAND_OK dates=0/);
  assert.equal(r.code, 1);
});

test('a healthy run exits 0 and expands exactly the planned dates once', { skip }, async () => {
  const r = await run({ MOCK_PLAN: '2026-10-31,2026-11-01' });
  assert.match(r.out, /GLOBAL_INGEST_OK provider=GOAL_API accepted=\d+/);
  assert.doesNotMatch(r.out, /GLOBAL_RUN_FAILED/);
  assert.deepEqual(r.stored, ['2026-10-31', '2026-11-01']);
  assert.deepEqual(r.fetched.map((f) => f.date), ['2026-10-31', '2026-11-01'], 'each date fetched once');
  assert.equal(r.code, 0);
});

test('the expansion stops above the 350 reserve with room for a whole large date', { skip }, async () => {
  const plan = Array.from({ length: 12 }, (_, i) => `2026-11-${String(i + 1).padStart(2, '0')}`);
  const r = await run({ MOCK_START_REMAINING: '380', MOCK_PLAN: plan.join(',') });
  assert.match(r.out, /CALENDAR_EXPAND_GATE expand=False/, '380 left is not a fresh quota');
  assert.match(r.out, /CALENDAR_EXPAND_STOP reason=quota_margin remaining=365/);
  assert.ok(r.fetched.length > 0 && r.fetched.length < plan.length);
  assert.equal(Math.min(...r.fetched.map((f) => f.remaining)), 365);
  assert.deepEqual(r.stored, r.fetched.map((f) => f.date), 'every fetched date is stored, none twice');
  assert.equal(r.code, 0);
});

test('a failing calendar date does not stop the next dates; the run still fails', { skip }, async () => {
  const r = await run({ MOCK_PLAN: '2026-10-31,2026-11-01,2026-11-02', MOCK_CAL_FAIL: '2026-11-01' });
  assert.deepEqual(r.stored, ['2026-10-31', '2026-11-02']);
  assert.deepEqual(r.fetched.map((f) => f.date), ['2026-10-31', '2026-11-01', '2026-11-02']);
  assert.notEqual(r.code, 0);
});

test('a second failure in a row stops the run: no GOAL call after it', { skip }, async () => {
  const r = await run({ MOCK_PLAN: '2026-10-31,2026-11-01,2026-11-02,2026-11-03', MOCK_CAL_FAIL: '2026-10-31,2026-11-01' });
  assert.deepEqual(r.stored, []);
  assert.deepEqual(r.fetched.map((f) => f.date), ['2026-10-31', '2026-11-01']);
  assert.notEqual(r.code, 0);
});

test('a success between two failed dates keeps the run going', { skip }, async () => {
  const r = await run({ MOCK_PLAN: '2026-11-07,2026-11-08,2026-11-14,2026-11-15,2026-11-16', MOCK_CAL_FAIL: '2026-11-07,2026-11-14' });
  assert.deepEqual(r.stored, ['2026-11-08', '2026-11-15', '2026-11-16'], 'two stubborn Saturdays must not freeze the plan');
  assert.equal(r.code, 1);
});

test('a production without deferredDates prints no deferred line', { skip }, async () => {
  const r = await run({ MOCK_PLAN: '2026-11-07', MOCK_NO_DEFERRED: '1' });
  assert.doesNotMatch(r.out, /CALENDAR_INGEST_DEFERRED/);
});

test('inside the margin no date starts', { skip }, async () => {
  const r = await run({ MOCK_START_REMAINING: '362', MOCK_PLAN: '2026-10-31,2026-11-01' });
  assert.deepEqual(r.fetched, []);
  assert.equal(r.code, 0);
});
